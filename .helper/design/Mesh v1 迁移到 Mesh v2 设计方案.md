# ACP Mesh v1 迁移到 Mesh v2 设计方案

## 0. 参考资料

- OCP [Migrating from Service Mesh 2 to Service Mesh 3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.0/html-single/migrating_from_service_mesh_2_to_service_mesh_3/index)
- [OTel v1→v2 迁移文档](https://docs.alauda.cn/opentelemetry/2.0/migrating/migrating-to-v2.html)
- [Alauda Service Mesh v1 功能列表以及 v2 不兼容改动](https://confluence.alauda.cn/pages/viewpage.action?pageId=301727839)
- [kiali 的 UI 能力表格（包含和 Mesh v1 的对比）](https://confluence.alauda.cn/pages/viewpage.action?pageId=407797966)

## 1. 背景与目标

ACP 当前处于 4.3 版本，Mesh v1（Alauda Service Mesh，基于社区已废弃的 istio-operator + 自研管控面）将于 4.4 下线，需要在 4.3 版本周期内把存量网格迁移到 Mesh v2（基于 Sail-Operator 的 servicemesh-operator2）。

**终态目标**：

- 业务集群运行 Mesh v2：`servicemesh-operator2` + `Istio`/`IstioCNI` CR（istio v1.28.x，RevisionBased）+ Kiali + OTel v2 + Jaeger v2；
- Mesh v1 全栈下线：global 集群的 Service Mesh Essentials 插件（global-asm-controller/hermes/mephisto）与业务集群的 asm 全家桶（asm-operator/asm-controller/asm-core/flagger/istio-operator/istiod-1-22/OTel v1/Jaeger v1）全部移除；
- 工作负载 sidecar、入口/出口网关、可观测管道全部切换到 v2；
- 根信任链保持同一根 CA（"ASM Istio Root CA"）不变，业务证书链在迁移前后可互相验证。

**方案取向**：主推「并存灰度」（业务流量尽量不中断），同时提供「停机卸载重装」作为测试/非生产环境的简化路径（附录 A）（TODO: 待定）。

---

## 2. Mesh v1 现状架构（含环境实测）

### 2.1 双层架构

```
global 集群 (cpaas-system)                     业务集群
┌─────────────────────────────┐               ┌──────────────────────────────────────────┐
│ Essentials 插件 (ModulePlugin │   下发/编排   │ istio-system:                             │
│  asm-global):                │ ────────────► │   asm-operator(OLM) → helm 装 cluster-asm │
│  - global-asm-controller     │               │   istio-operator-122 → 按 IstioOperator CR│
│  - hermes   (聚合 API)       │               │     部署 istiod-1-22(rev=1-22)、网关       │
│  - mephisto (自研 UI)        │               │   flagger + flagger-operator              │
│  - cert-manager 根证书        │               │   jaeger-operator + jaeger-prod-*(1.60)   │
│    asm-istio-rootca (100年)  │               │   opentelemetry-operator (v1, 0.108.0)    │
│ CR: ServiceMesh(per cluster) │               │ cpaas-system:                             │
│     ServiceMeshGroup(多集群) │               │   asm-controller、asm-core                │
│                              │               │   asm-otel-collector / -backend (CR 形态) │
└─────────────────────────────┘               └──────────────────────────────────────────┘
```

- **Istio 部署链**：`ServiceMesh` CR（global）→ global-asm-controller 渲染下发 → 业务集群 `asms.operator.alauda.io/asm` CR + `IstioOperator` CR（`install.istio.io/v1alpha1`）→ istio-operator（社区已废弃）→ `istiod-1-22`。每个 ASM 网关也是一个独立的 `IstioOperator` CR（实测：`istio-122`、`ingress-gw-1`、`egrees-gw-1` 三个 IOP CR）。
- **注入机制**：命名空间打 `istio.io/rev: 1-22`（istio 原生 revision 注入，实测 mesh-demo 即如此）+ `cpaas.io/serviceMesh: enabled`（触发自研 webhook `asm-pod-v1-mutate` 追加 ASM 专属配置）。v1 数据面用 **istio-init** 容器做 iptables 劫持（实测，无 istio-cni）。
- **根证书**：global cert-manager 维护根 `asm-istio-rootca`（O=Istio, CN=ASM Istio Root CA，实测有效期至 2126 年）→ 每业务集群签发中间 CA `asm-istio-cacerts-<cluster>`（**60 天有效、提前 15 天续期**，CN=ASM Istio Intermediate CA）→ global-asm-controller 转换为业务集群 istio-system 的 **`cacerts`** secret（标准 istio 插件 CA 四件套格式）并持续同步。源码：`global-asm-controller/pkg/istioca/certmanager/ca.go`、`pkg/meshGroup/remoteSecret.go:162 EnsureCACerts`。
- **网格标识**（单集群环境实测 `istio-1-22` configmap）：`meshId: mesh-business1`、`trustDomain: cluster.local`、`rootNamespace: istio-system`。
- **多集群**（多集群环境实测）：multi-primary 多网络拓扑；每集群各有 istiod-1-22 + `istio-eastwestgateway`（LoadBalancer, 15443 等端口）+ 对端 `istio-remote-secret-<cluster>`（label `istio/multiCluster=true`）；`ServiceMeshGroup/multi-cluster-mesh`：clusters=[business-1,business-2]、isMultiNetwork=true、monitorType=victoriametrics、ES/VM 均经 global 入口。
- **可观测**：sidecar/OTel Java Agent → asm-otel-collector（cpaas-system, OTLP 4317/4318/9411）→ jaeger-prod-collector → Elasticsearch（索引前缀 `asm-mesh-<meshID>`）；指标经 Prometheus/VictoriaMetrics；自研 Tracing UI + 拓扑（hermes servicegraph 聚合 istio 与 otel 两路指标）。
- **OLM 订阅**（业务集群 istio-system）：`asm`、`flagger-operator`、`jaeger-operator`、`opentelemetry-operator`（v1）。

### 2.2 v1 占用的关键"公共位置"（迁移冲突源）

环境实测 v1 拥有以下 mutating/validating webhook：

| Webhook                                                             | 归属                                                   | 对 v2 的影响                                               |
| ------------------------------------------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------- |
| `istio-sidecar-injector-1-22` / `istio-validator-1-22-istio-system` | v1 istiod（rev 1-22）                                  | 无冲突（按 rev 隔离）                                      |
| **`istio-revision-tag-default`**（4 条 webhook）                    | v1 把 rev 1-22 设为 default tag                        | v2 共存期**不能**创建 default `IstioRevisionTag`，否则打架 |
| **`istiod-default-validator`**                                      | v1 istio-operator                                      | 同上；v1 下线后由 v2 收编                                  |
| `asm-pod-v1-mutate`（`asm.ms-pod-inject.cpaas.io`）                 | asm-controller，按 `cpaas.io/serviceMesh=enabled` 匹配 | 对已切换 ns 的残留影响 → 风险 R4                           |

### 2.3 环境清单

**单集群环境**（平台 v4.3.2，https://192.168.132.61）：global + business-1；`mesh-demo`（asm-client / asm-first-server / asm-second-server 三个 MicroService，rev 1-22）、`mesh-gw`（ingress-gw-1、egrees-gw-1，另有原生 Gateway `http-gw`/`https-gw` 及外部服务 httpbingo.org 绑定出口网关自动生成的 Gateway/VS）、`otel-java`（consumer-ms/provider-ms，OTel Java Agent 注入，Instrumentation `cpaas-system/asm-common-java`）。**注意：该环境已预装 servicemesh-operator2 v2.1.2（sail-operator 命名空间），尚未创建任何 Istio CR** —— 双 operator 共存已是既成事实且两个 CSV 均 Succeeded。

**多集群环境**（平台 v4.3.2，https://192.168.136.43）：global + business-1 + business-2，两业务集群 mesh-demo 均有注入 sidecar 的服务，multi-primary 多网络。

---

## 3. Mesh v2 目标架构

- **Operator**：`servicemesh-operator2`（OLM，`sail-operator` 命名空间，channel `stable`），集群级；管理 `sailoperator.io/v1` 的 `Istio`/`IstioRevision`/`IstioRevisionTag`/`IstioCNI`/`ZTunnel`（全部 Cluster scope）。
- **控制面**：`Istio` CR（`spec.namespace: istio-system` 不可变、`version: v1.28.6`、`updateStrategy.type: RevisionBased`、`spec.values` 透传 Helm values）。RevisionBased 下 IstioRevision 名 = `<Istio名>-v1-28-6`。
- **CNI**：`IstioCNI` CR（name 必须 `default`，namespace `istio-cni`；ACP 4.1+ `cniConfDir: /etc/cni/multus/net.d`）。前置：ACP Networking for Multus 插件（单集群环境实测已装 kube-multus-ds，kube-ovn v1.15.17）。
- **注入**：ns 标签 `istio.io/rev=<revision>`（或 default tag 后用 `istio-injection=enabled`）；pod 级 `sidecar.istio.io/inject`。
- **网关**：gateway injection（`inject.istio.io/templates: gateway` + `image: auto`）或 K8s Gateway API；operator 不管理网关。
- **可观测**：Kiali（`kiali-operator` + `Kiali` CR，istio-system）；OTel v2（`opentelemetry-operator2`）+ Jaeger v2（`jaeger-system`，Jaeger 以 OpenTelemetryCollector CR 形态部署）；指标用带 `prometheus: kube-prometheus` 标签的 ServiceMonitor/PodMonitor 对接平台监控。
- **多集群**：multi-primary / primary-remote（多网络经东西向网关），共享 `cacerts` + `istioctl create-remote-secret`。

---

## 4. 差异与功能映射表

（依据内部评估页 pageId=301727839、Kiali 对比页 pageId=407797966，结合源码/环境核实）

| v1 功能点                                                                                                 | v1 实现                                                                                 | v2 对应                                                                      | 迁移动作                                                                           |
| --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| 网格创建/管理                                                                                             | `ServiceMesh` CR + 自研 UI                                                              | `Istio`/`IstioCNI` CR（YAML/kubectl）                                        | 本方案 P2                                                                          |
| 微服务纳管                                                                                                | `MicroService` CR + UI                                                                  | 无此概念；原生 ns/pod 标签注入                                               | P3 切换后 CR 随 v1 下线删除                                                        |
| Sidecar 注入                                                                                              | ns `istio.io/rev=1-22` + `cpaas.io/serviceMesh` webhook                                 | ns `istio.io/rev=<v2 rev>`（终态可 default tag + `istio-injection=enabled`） | P3 改标签+重启                                                                     |
| 入口/出口网关                                                                                             | `GatewayDeploy`/`IngressGateway` CR → 每网关一个 IstioOperator CR                       | gateway injection Deployment（自管）或 Gateway API                           | P4 双网关金丝雀                                                                    |
| `Gateway`<br>`VirtualService`<br>`DestinationRule`<br>`ServiceEntry`<br>`Sidecar`<br>`PeerAuthentication` | istio 原生资源                                                                          | **原样复用**（1.28 schema 兼容性检查除外）                                   | P0 审计，默认不动                                                                  |
| 流量策略（熔断/连接池/负载均衡）                                                                          | `ConnectionPool`<br>`OutlierDetection`<br>`LoadBalancer` 自研 CR → 生成 DestinationRule | 直接写原生 DestinationRule（Kiali 向导可配）                                 | 盘点自研 CR，确认生成的原生资源保留（`asm.cpaas.io/user-managed` 标注）后删自研 CR |
| 灰度发布                                                                                                  | `CanaryDelivery`（内置 fork 版 Flagger）                                                | 无内置；集成 ACP Argo Rollouts                                               | 给替代方案文档；存量 Canary 需在迁移前终止                                         |
| 全局限流                                                                                                  | `GlobalRateLimiter` + asm-core(RLS) + Redis                                             | 无内置；istio 官方 ratelimit 方案（EnvoyFilter + RLS 服务）                  | 替代方案文档（两环境均未启用 Redis，实测无存量，但客户环境有存量）                 |
| 本地限流                                                                                                  | istio 官方 EnvoyFilter 方案                                                             | 相同                                                                         | 原样保留（注意 1.28 兼容）                                                         |
| 安全策略/黑白名单/JWT                                                                                     | `Whitelist`/`JWTPolicy` CR                                                              | 原生 AuthorizationPolicy / RequestAuthentication                             | 转换后删自研 CR                                                                    |
| 实例隔离                                                                                                  | `IsolatePod`（readinessGate）                                                           | 无对等（属容器能力）                                                         | 需在迁移前取消实例隔离。替代说明：手工摘除 endpoints/labels                        |
| API 管理/API 流量监控                                                                                     | `APIAttribute` + WasmPlugin                                                             | 无对等；istio 官方 Classifying Metrics 方案                                  | 替代说明                                                                           |
| 调用链/拓扑/监控 UI                                                                                       | mephisto + hermes + 自研 Tracing UI                                                     | Kiali（+ Jaeger UI）                                                         | P1 装 Kiali，P6 终态切换                                                           |
| 调用链管道                                                                                                | OTel v1(0.108) collector → Jaeger 1.60 → ES                                             | OTel v2(0.147) + Jaeger v2（jaeger-system）                                  | P6（OTel v1/v2 CRD 属主互斥，不能共存）                                            |
| JVM 监控/Java Agent                                                                                       | v1 内置 agent 镜像，`Instrumentation` 可省 image                                        | v2 必须显式 `spec.java.image`；默认 http/protobuf(4318)                      | P6 按 OTel 官方迁移文档重建                                                        |
| 多集群                                                                                                    | ServiceMeshGroup + global 编排                                                          | 原生 multi-primary（手工/脚本配置）                                          | 第 8 章                                                                            |
| EnvoyFilterTemplate                                                                                       | 4.0 已下线                                                                              | —                                                                            | 不涉及                                                                             |

---

## 5. 并存可行性论证（四支柱 + 证据）

Mesh v2 文档虽警告"不要在同一集群同时安装 v1 和 v2"（`servicemesh2-docs/docs/en/installing/installing-service-mesh/install-mesh.mdx`），但该警告针对的是**无约束共存**。本方案论证：在下述四个约束下，共存是安全的（OCP 官方 2→3 迁移即同构方案）：

1. **CA 支柱 —— 共享根证书天然成立**：v1 的 `cacerts`（istio-system）就是标准 istio 插件 CA 格式（实测：中间 CA "ASM Istio Intermediate CA" ← 根 "ASM Istio Root CA"）。上游 istiod 的行为是：所在命名空间存在 `cacerts` secret 即加载为签发 CA。v2 istiod 装进同一 istio-system 后与 v1 istiod 同根签发工作负载证书，且双方 `trustDomain` 均为默认 `cluster.local` → 新旧数据面 mTLS 全程互通。对应 OCP 文档 4.1.1.1"3.0 控制面必须与 2.6 同命名空间以共享根证书"。**【V-1：v2 istiod 加载同一 cacerts、双面互通实测】**
2. **Webhook 支柱 —— default 位置错峰**：v1 占用 `istio-revision-tag-default` 与 `istiod-default-validator`。v2 用 **RevisionBased** 且共存期**不创建 default `IstioRevisionTag`**，其 injector/validator 均带 revision 后缀（如 `default-v1-28-6`），与 v1 的 `*-1-22` 互不重叠；`istio.io/rev` 标签是精确匹配，一个 ns 同一时刻只会被一个控制面注入（OCP 需要 `maistra.io/ignore-namespace` 是因为 Maistra 有 SMMR 成员机制；ACP v1 本身就是原生 rev 注入，改掉标签即天然脱离 v1 注入范围，无需等价物）。**【V-2：切换后 v1 webhook 不再对该 ns 生效】**
3. **CNI 支柱 —— 流量劫持不打架**：v1 数据面 istio-init（实测），v2 用 IstioCNI；上游 istio-cni 插件对含 `istio-init` 容器的 pod 自动跳过。且 IstioCNI 按 rev/注解只处理 v2 注入的 pod。kube-ovn + Multus 链式插件的历史问题（Confluence 323289121）在新版 kube-ovn 已修复。**【V-3：v1/v2 pod 同节点混跑，重启后流量劫持均正常】**
4. **Revision 支柱 —— v1 本身就是 revision 化的**：istiod-1-22 即 revision "1-22"，与 v2 revision "default-v1-28-6" 是 istio 原生多修订并存模型，等价于一次跨大版本的金丝雀升级（sail-operator RevisionBased 明确支持跨多个 minor）。istio CRD 由 v2 operator 升级到 1.28 schema，上游保证向后兼容（1.22 istiod 可继续消费）。**【V-4：CRD 升级后 v1 控制面行为无回归】**

**必须规避的两个雷区**（源码实锤）：

- ⛔ **v1 的删除流程会删除整个 istio-system 命名空间**：`global-asm-controller/pkg/mesh/manage.go` 删除序列 = 删业务集群 `asm` CR → **显式删除 istio-system namespace 并等待终结**（L477-511）→ 清理孤儿 operator 资源。因此 v2 就位后，v1 下线**绝不能走 UI「删除网格」/删除 ServiceMesh CR 由控制器处理**，必须用第 6 章 P5 的手工序列。
- ⛔ **中间 CA 60 天有效期依赖 v1 控制器续期**：cert-manager Certificate（60d/renewBefore 15d）续期后由 global-asm-controller 同步到业务集群。冻结/下线 v1 控制器后续期链断裂 → P0/P3 前置检查 cacerts 剩余有效期 ≥ 迁移窗口（R6），P6 完成 CA 交接。

---

## 6. 迁移方案（主推：并存灰度，P0–P6）

> 以下命令以单集群环境为例（业务集群 business-1）；`$V2REV` 指 v2 活动修订名（如 `default-v1-28-6`）。多集群叠加项见第 8 章。每阶段末尾为该阶段验证断言。

### P0 盘点、备份与冻结

1. **清点**（脚本化，输出存 evidence）：
   ```bash
   # 网格纳管命名空间与工作负载
   kubectl get ns -l istio.io/rev=1-22
   kubectl get microservices.asm.alauda.io -A
   # 网关（含 istio-system 里的默认网关/东西向网关）
   kubectl get istiooperators.install.istio.io -n istio-system
   kubectl get gatewaydeploys,ingressgateways.asm.alauda.io -A
   # istio 原生资源【2026-07-11 修订（问题4）：按 CRD 全量遍历 *.istio.io 四个组
   #（networking/security/telemetry/extensions），勿手列常用类型——原清单漏掉的 Telemetry
   # 恰是实测被 GC/残留的资源】与自研治理 CR
   for crd in $(kubectl get crd -o name | grep -E '\.istio\.io' | sed 's|.*/||'); do kubectl get $crd -A 2>/dev/null; done
   for crd in $(kubectl get crd -o name | grep asm.alauda.io); do kubectl get ${crd#*/} -A 2>/dev/null; done
   # 网关 TLS 证书 secret（Gateway spec 里全部 credentialName 引用；不属 istio 资源，单独清点）
   kubectl get gateways.networking.istio.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{range .spec.servers[*]}{.tls.credentialName}{" "}{end}{"\n"}{end}' | awk 'NF>1'
   # OTel / Jaeger / 订阅
   kubectl get opentelemetrycollectors,instrumentations -A
   kubectl get subscription,csv -A | grep -Ei "asm|flagger|jaeger|opentelemetry|servicemesh"
   ```
2. **备份**：上述所有资源 `-o yaml` 全量导出；ns 标签快照；`cacerts`、`istio-remote-secret-*`；global 侧 `ServiceMesh`/`ServiceMeshGroup`/`asm-istio-rootca`；**网关 TLS secret 全量导出**（credentialName 引用的 secret 含私钥且 UI 侧无留存，被 GC 后不可再生——D-16 实测教训）。
   **派生资源属主审计**（D-16）：v1 会给 UI 功能派生的原生资源设 `ownerReferences → asm CR`（实锤：访问日志 Telemetry→GatewayDeploy/MicroService、网关 Service→GatewayDeploy、TLS secret 同模式），P5 删自研 CR 时会被 K8s GC 级联删除。P0 全量导出下述清单，供 P5 摘 owner 或事后重建：
   ```bash
   # 列出所有 owner 为 asm CR 的 istio 资源与 secret（重点：Telemetry/Secret/Service）
   for kind in $(kubectl get crd -o name | grep -E '\.istio\.io' | sed 's|.*/||') secrets services; do
     kubectl get $kind -A -o json 2>/dev/null | jq -r --arg k "$kind" \
       '.items[] | select(.metadata.ownerReferences[]?.apiVersion | strings | test("asm.alauda.io")) | "\($k) \(.metadata.namespace)/\(.metadata.name) <- \(.metadata.ownerReferences[0].kind)/\(.metadata.ownerReferences[0].name)"'
   done
   ```
3. **兼容性审计**：
   - ServiceEntry 1.28 schema 检查（缺 port / hosts>256，OCP premigration 同款 jq 脚本）；
   - EnvoyFilter 1.22→1.28 审计（含 asm 生成的限流/模板 EnvoyFilter，proxy 版本敏感）；
   - 检查 `cacerts` 剩余有效期 ≥ 计划迁移窗口（R6）。
4. **冻结约定**：迁移期间不通过 v1 UI 做网格变更（不加服务/不建网关/不改策略）；平台侧暂停 v1 相关 operator 的升级审批。
5. **业务探测器就位**：`curl` 循环（1s）打 ingress 网关域名 + 网格内 client→server 调用，全程记录中断秒数。

### P1 可观测准备（Kiali + v2 指标采集）

1. 安装 `kiali-operator`（OLM，`kiali-operator` 命名空间，source `platform`）。
2. 创建 `Kiali` CR（istio-system）：`auth.strategy: openid`（对接 ACP dex）；`external_services.prometheus.url` 指向平台监控 —— **单集群：ACP 的 Prometheus 或 VictoriaMetrics 皆可（本环境为 Prometheus）；多集群：必须 VictoriaMetrics**（与 v1 多集群约束一致），VM 时开 `thanos_proxy.enabled: true`；`external_services.grafana.enabled: false`；tracing 暂配 v1 Jaeger（`http://jaeger-prod-query...`，P6 翻转到 Jaeger v2）。
3. 创建 v2 指标采集：istiod ServiceMonitor + Envoy PodMonitor（`metadata.labels.prometheus: kube-prometheus`；PodMonitor 需覆盖所有 mesh 命名空间）。
4. ✅ 断言：Kiali 可见 v1 网格流量拓扑（同一份 Prometheus 数据）。**【V-5】**

### P2 安装 v2 控制面（对 v1 零扰动）

1. 前置：确认 Multus 插件与 kube-ovn 版本满足要求；`servicemesh-operator2` 已装（两环境实测 v2.1.2 已装，否则按 Subscription 流程安装并 Manual 审批）。
2. `IstioCNI`：
   ```yaml
   apiVersion: sailoperator.io/v1
   kind: IstioCNI
   metadata: { name: default }
   spec:
     namespace: istio-cni
     values:
       cni:
         cniConfDir: /etc/cni/multus/net.d
         excludeNamespaces: [istio-cni, kube-system]
   ```
3. `Istio`：
   ```yaml
   apiVersion: sailoperator.io/v1
   kind: Istio
   metadata: { name: default }
   spec:
     namespace: istio-system
     version: v1.28.6
     updateStrategy:
       type: RevisionBased
       inactiveRevisionDeletionGracePeriodSeconds: 2592000 # 迁移期加大宽限，防误删
     values:
       global:
         meshID: mesh-business1 # 对齐 v1 实测值
       meshConfig:
         enableTracing: true
         extensionProviders: # 过渡期指向 v1 现存 collector，保证调用链连续
           - name: otel
             opentelemetry:
               port: 4317
               service: asm-otel-collector.cpaas-system.svc.cluster.local
   ```
   > 不创建 default `IstioRevisionTag`（雷区见第 5 章支柱 2）。
4. 在 istio-system 创建 `Telemetry`（rootNamespace 级，`tracing.providers: [otel]`，采样率对齐 v1 的 traceSampling 实测值）。
5. ✅ 断言：`istiod-default-v1-28-6` Ready；**加载同一 cacerts**（对比新旧 istiod 的 root cert：`istioctl proxy-config secret` 或 istiod 日志）；`kubectl get istiorevisions` 正常；v1 数据面/探测器零扰动。**【V-1/V-4】**

### P3 工作负载逐命名空间切换

1. **冻结 v1 控制器**（**V-6 已实测：两环境 v1 控制器均不在 120s 内调和 ns 的 `istio.io/rev` 标签，本步骤定为可选**；保留命令供需冻结副本数的场景使用）：
   ```bash
   # global 集群（先冻编排源头，防止其重建业务集群组件）
   kubectl -n cpaas-system scale deploy global-asm-controller --replicas=0
   # 业务集群：先冻 asm-operator（helm-operator 会调和 cluster-asm release 的副本数），再冻 asm-controller
   kubectl -n istio-system scale deploy asm-operator --replicas=0
   kubectl -n cpaas-system scale deploy asm-controller --replicas=0
   ```
   > 保留 MicroService 等 CR 不删，回滚时恢复副本数即可。注意各层调和链（global 插件 operator → global-asm-controller → asm CR → asm-operator → asm-controller）都可能把下游副本数调回，冻结的完整层级以实测为准。**【V-6：冻结后改标签，观察是否被调和回 1-22 / 副本数是否被拉起】**
2. **逐 ns 切换**（一次一个 ns，验证后再下一个）：

   ```bash
   kubectl label ns mesh-demo istio.io/rev=default-v1-28-6 --overwrite
   kubectl -n mesh-demo rollout restart deploy
   kubectl -n mesh-demo rollout status deploy --timeout=300s
   istioctl ps -n mesh-demo    # ISTIOD 列应指向 istiod-default-v1-28-6-*
   ```

   - `cpaas.io/serviceMesh=enabled` 标签暂**保留**（回滚需要），`asm-pod-v1-mutate` 的追加配置对 v2 无害性由 V-7 验证；v1 下线时统一清除。**【V-7】**

3. **跨控制面互通验证**：已迁 ns（v2 sidecar）↔ 未迁 ns（v1 sidecar）互调 + mTLS 生效（`istioctl proxy-config secret` 证书链同根）。**【V-8】**
4. `otel-java` 命名空间（仅 OTel Agent、无 mesh sidecar）本阶段不动，P6 处理。

### P4 网关切换（同命名空间双 Deployment 金丝雀）

1. **前置——Service 属主处理**：检查网关 Service 是否被 IstioOperator CR/网关 Deployment 持有 ownerReferences；如有，后续删除 v1 网关 CR 时统一用 `--cascade=orphan`，并提前验证删除不连带 Service。**【V-9】**
2. 以 `ingress-gw-1` 为例，读取现有 Service selector，在 mesh-gw 新建 v2 网关：
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: ingress-gw-1-v2, namespace: mesh-gw }
   spec:
     selector:
       { matchLabels: { asm.cpaas.io/gateway: ingress-gw-1, gwrev: v2 } }
     template:
       metadata:
         annotations: { inject.istio.io/templates: gateway }
         labels:
           # 必须包含现有 Service 的完整 selector 标签集（P0 实测采集），叠加：
           asm.cpaas.io/gateway: ingress-gw-1
           gwrev: v2
           istio.io/rev: default-v1-28-6
       spec:
         containers: [{ name: istio-proxy, image: auto }]
   ```
   > 具体 selector 标签以环境实测为准（验证阶段回填）。
   >
   > **配套 RBAC 必须落实（D-15 实测教训，不可只建 ServiceAccount）**：istiod 对 Gateway `credentialName` 的 SDS 请求会校验**网关 SA 是否有读所在 ns secrets 的权限**，缺失时 istiod 报 `proxy ... is not authorized to read secrets`、证书停在 `WARMING`，HTTPS 握手失败且不影响 80 端口——纯 http 探测发现不了。每个网关 ns 一次性创建：
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata: { name: gateway-sds-reader, namespace: mesh-gw }
   rules:
     - apiGroups: [""]
       resources: ["secrets"]
       verbs: ["get", "watch", "list"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata: { name: gateway-sds-reader, namespace: mesh-gw }
   roleRef:
     {
       apiGroup: rbac.authorization.k8s.io,
       kind: Role,
       name: gateway-sds-reader,
     }
   subjects:
     - { kind: ServiceAccount, name: ingress-gw-1-v2, namespace: mesh-gw }
     - { kind: ServiceAccount, name: egrees-gw-1-v2, namespace: mesh-gw }
   ```
3. 切流：`kubectl -n mesh-gw scale deploy ingress-gw-1-v2 --replicas=N`（升）/ 旧网关逐步降；探测器全程观察；完成后旧网关缩 0 **保留**（回滚用）。egress（egrees-gw-1）同法。istio-system 内的 `istio-ingressgateway`（v1 默认网关/tier2）若承载流量，同法处理；未承载则记录后随 v1 下线。
4. **外部服务绑定资源保护**：istio-system 中 asm 自动生成的 `*--mesh-gw--egrees-gw-1--*` Gateway/VS 打 `asm.cpaas.io/user-managed: "true"` 注解（脱离 controller 托管），防 v1 清理时 GC。**【V-10】**
5. ✅ 断言：新网关承载 100% 流量，探测 0 中断；`Gateway`/`VirtualService` 未改动。**HTTPS 网关必须逐个验证 TLS 链路**（V-18）：`istioctl pc secret <v2网关pod>` 中每个 `kubernetes://<credentialName>` 均 `ACTIVE`（`WARMING` 即 D-15 的 RBAC 缺失）+ curl https 打通任一 TLS 域名；探测器脚本必须包含 https 探测项，纯 http 探测无法暴露证书链路问题。**【V-18】**

### P5 v1 手工下线（不可回退点）

**Go/No-Go 检查单**（全部通过才进入）：

- [x] 所有业务 ns 的 `istio.io/rev` 均指向 v2 修订；`istioctl ps` 无任何 proxy 连接 `istiod-1-22`；
- [x] 所有网关（含 egress/东西向/istio-system 默认网关）已由 v2 承载或确认无流量；
- [x] 备份完整（P0 清单全量 + 增量）；
- [x] 干系人确认：过此点后回滚 = 灾难恢复级重装 v1。

**下线序列**（每步后跑探测器 + 残留检查）：

```bash
# ① global 侧：确认编排已冻结，再清 global CR（此时控制器副本=0，删除流程永不执行）
kubectl -n cpaas-system get deploy global-asm-controller -o jsonpath='{.spec.replicas}'   # 必须为 0
kubectl -n cpaas-system delete servicemesh business-1 --wait=false
kubectl -n cpaas-system patch servicemesh business-1 --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
# （多集群：ServiceMeshGroup 同法）
# 卸载 global Essentials 插件（Marketplace UI），移除 global-asm-controller/hermes/mephisto

# ② 业务集群：删自研治理 CR（asm-controller 已停，必要时逐类 patch 掉 finalizers）
#    ⚠️ 删除前先按 P0 属主审计清单，把要保留的派生资源摘掉 ownerReferences（D-16）：
#    网关/微服务的访问日志 Telemetry、网关 TLS secret、网关 Service（D-11）等都
#    ownerRef → asm CR，不摘 owner 会在 CR 删除瞬间被 K8s GC 级联删除。
#    kubectl -n <ns> patch <kind>/<name> --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]'
for crd in $(kubectl get crd -o name | grep asm.alauda.io | sed 's|.*/||'); do
  kubectl delete $crd --all -A --wait=false 2>/dev/null
done   # finalizer 残留的用 patch 清
# 摘过 owner 的资源逐个断言在位（get 验证），Telemetry 的 selector 适配见 10.2（D-16）

# ③ 删 asm CR → asm-operator（还在运行）执行 helm 卸载 cluster-asm
#    （移除 asm-controller/asm-core/asm-otel collectors/jaeger CR/asm webhooks/oauth2-proxy 等）
kubectl delete asms.operator.alauda.io asm
kubectl delete flaggers.operator.alauda.io --all -A

# ④ 删 v1 系 OLM 订阅与 CSV（istio-system）
for s in asm flagger-operator-alpha-system-cpaas-system jaeger-operator-stable-platform-cpaas-system \
         opentelemetry-operator-alpha-platform-cpaas-system; do
  kubectl -n istio-system delete subscription $s
done
kubectl -n istio-system get csv -o name \
  | grep -E "/(asm|flagger|jaeger-operator|opentelemetry-operator)\.v" \
  | xargs -r kubectl -n istio-system delete

# ⑤ 删网关 IstioOperator CR（orphan 防连带删 Service），再删旧网关 Deployment 残壳
kubectl -n istio-system delete istiooperator ingress-gw-1 egrees-gw-1 --cascade=orphan
kubectl -n mesh-gw delete deploy ingress-gw-1 egrees-gw-1        # 已缩 0 的旧网关

# ⑥ 删控制面 IstioOperator CR（istio-operator 移除 istiod-1-22 与 1-22 系 webhook），再删 operator 本体
kubectl -n istio-system delete istiooperator istio-122
kubectl -n istio-system delete deploy istio-operator-122   # + 其 SA/ClusterRole(Binding)

# ⑦ 清残留 default 位 webhook（若 ⑥ 未带走）
kubectl delete mutatingwebhookconfiguration istio-revision-tag-default 2>/dev/null
kubectl delete validatingwebhookconfiguration istiod-default-validator 2>/dev/null

# ⑧ 清 ns 上的 v1 标签 与 asm CRD（确认无实例后）
kubectl label ns mesh-demo cpaas.io/serviceMesh- 2>/dev/null
kubectl get crd -o name | grep asm.alauda.io | xargs kubectl delete
# ⑨ 清 v1 控制面 IOP 渲染的 istio 配置残留（D-17）：istio-operator 删除 IOP 时不回收
#    Telemetry 等配置类资源（实测全局 Telemetry asm-mesh-default--1-22 三集群均残留，
#    其 zipkin provider/ASM_MS_NAME customTags/istio_operation tagOverrides 在 v2 均为死配置，
#    且与 v2 的 root ns Telemetry 产生不受控合并）。按标签扫全部 *.istio.io 资源并删除：
for crd in $(kubectl get crd -o name | grep -E '\.istio\.io' | sed 's|.*/||'); do
  kubectl get $crd -A -l 'install.operator.istio.io/owning-resource' 2>/dev/null | grep -v "^NAMESPACE" || true
done   # 逐个确认属 v1（owning-resource=istio-122 等）后删除；至少含 istio-system/asm-mesh-default--1-22
```

> ②③ 的精确顺序与 finalizer 行为以验证演练实测为准（**V-11**），⑥ 删除 IOP 后 istio-operator 对 istiod/webhook 的回收范围同样以实测回填（**V-12**）。istio CRD（networking/security/telemetry.istio.io）**保留**——已由 v2 operator 接管。

✅ 断言：`kubectl get crd | grep asm.alauda.io` 为空；istio-system 内仅剩 v2 istiod 与 Kiali；探测器全程 0 中断（**含 https 探测项**）；global 集群无 asm 组件；**保留清单核对**——网关 TLS secret、访问日志 Telemetry、网关 Service 逐个 `get` 在位（D-16），全 `*.istio.io` 资源无 `install.operator.istio.io/owning-resource` 残留（D-17）。

### P6 收编与可观测终态

1. **default 收编**：
   ```yaml
   apiVersion: sailoperator.io/v1
   kind: IstioRevisionTag
   metadata: { name: default }
   spec: { targetRef: { kind: Istio, name: default } }
   ```
   可选：逐 ns `kubectl label ns <ns> istio-injection=enabled istio.io/rev-` + 重启，回归最简注入模型（也可长期保留 rev 标签）。
2. **CA 生命周期交接**（根不变，换长期中间 CA）：
   - 从 global 导出根：`kubectl -n cpaas-system get secret asm-istio-rootca -o yaml`（root key **离线保管**，不落业务集群）；
   - 按 v2 多集群文档 openssl 流程，用同一根签发新的每集群中间 CA（有效期按公司策略，建议 1–2 年并建立轮换 SOP）；
   - 重建 `cacerts` 四件套 secret 替换 → istiod 热加载 → `istioctl proxy-config secret` 验证工作负载证书链根不变、pod 无重启。**【V-13】**
3. **可观测终态**（存在遥测中断窗口，与 OTel 官方迁移一致）：
   - v1 下线已随带移除 OTel v1 operator/collectors/Jaeger v1（P5 ③④）；
   - 安装 `opentelemetry-operator2`（`opentelemetry-operator2` ns）+ Jaeger v2 + collector（`jaeger-system`，按 servicemesh2-docs distributed-tracing 文档；ES 索引前缀按 meshID 规划，与旧索引 `asm-mesh-*` 区分）；
   - 翻转 Istio CR `extensionProviders[].opentelemetry.service` → `otel-collector.jaeger-system.svc.cluster.local`；若用 discoverySelectors 需给 jaeger-system 打标；
   - `otel-java` 场景按 [OTel v1→v2 迁移文档](https://docs.alauda.cn/opentelemetry/2.0/migrating/migrating-to-v2.html)重建 `Instrumentation`（显式 `spec.java.image`、4317→4318 或声明 grpc 协议）+ 滚动重启；
   - Kiali `external_services.tracing` 切到 Jaeger v2（16685/gRPC）。
4. **运维参数回调**（D-18）：迁移完成并稳定运行 1–2 周后，把 Istio CR 的 `inactiveRevisionDeletionGracePeriodSeconds: 2592000`（迁移期防误删的 30 天保险）**删除恢复默认 30 秒**，或设分钟级（如 600）。该字段只影响 RevisionBased 下「已无工作负载引用的 inactive 修订」的删除等待，保留 30 天的代价是未来每次 v2 版本升级旧 istiod 都滞留 30 天；修改不触发 istiod 滚动（operator 行为参数，不进 helm values）。
5. ✅ 终态验收：mesh-demo 全链路调用在 Kiali 拓扑可见、调用链在 Jaeger v2 可查、otel-java JVM 指标恢复、`kubectl get istio,istiocni,istiorevisiontag` 全 Healthy、残留扫描为零。**【V-14】**

---

## 7. 回滚设计

| 阶段           | 回滚动作                                                                                                                | 前提                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| P1–P2 后       | `kubectl delete istio default && kubectl delete istiocni default`（Kiali 可保留）                                       | 无                                           |
| P3 中（单 ns） | `kubectl label ns <ns> istio.io/rev=1-22 --overwrite && kubectl -n <ns> rollout restart deploy`                         | v1 istiod/webhook 未动、MicroService CR 未删 |
| P3 整体        | 全部 ns 标签改回 + 恢复 `global-asm-controller`/`asm-controller` 副本数                                                 | 同上                                         |
| P4             | 旧网关副本调回、v2 网关缩 0                                                                                             | 旧网关 Deployment 未删（P5 前都保留）        |
| P5 之后        | **灾难恢复级**：按 P0 备份重装 v1（Essentials 插件 → operator 上传 → 恢复 ServiceMesh CR → 恢复治理 CR），附录 B 给清单 | 备份完整                                     |

回滚触发标准：探测器出现持续中断、mTLS 校验失败、或任一 Go/No-Go 断言失败且 30 分钟内无法定位。

---

## 8. 多集群迁移设计（叠加项）

在单集群 P0–P6 之上，多集群环境（business-1/business-2，multi-primary 多网络）叠加以下步骤。**本章基线为多网络拓扑（已实机验证）；单网络（single network）客户的变体适配见 8.1 节**：

1. **P0+**：实测采集两集群 istiod 的 `meshId`/`network`/`clusterName`（`kubectl -n istio-system get cm istio-1-22 -o jsonpath='{.data.mesh}'` 及东西向网关的 `topology.istio.io/network` 标签），v2 Istio CR 必须逐字段对齐。**【V-15】**
2. **P2+**：两集群各建 IstioCNI + Istio CR，`values.global` 增加：

   ```yaml
   global:
     meshID: <实测值>
     network: <本集群实测 network>
     multiCluster: { clusterName: <本集群名> }
   ```

   - **复用共享 CA**：两集群 cacerts 同根（global 签发），v2 istiod 直接加载 → 跨集群 mTLS 互信平移；
   - **复用 remote secret**：`istio-remote-secret-<peer>`（label `istio/multiCluster=true`）对 v2 istiod 同样生效（istiod 按 label 发现），`istioctl remote-clusters` 断言 synced。**【V-16】**

3. **P2.5 东西向网关**：每集群以 gateway injection 部署 v2 版 eastwest gateway（`istio.io/rev=$V2REV`、`topology.istio.io/network=<network>`，15443 AUTO_PASSTHROUGH），沿用/新建 expose-services `Gateway`。过渡期 v1/v2 东西向网关并存（SNI passthrough 与控制面版本解耦）。**【V-17：跨集群跨版本调用矩阵】**
4. **P3+**：按集群逐 ns 切换；持续探测矩阵：v1(c1)↔v1(c2)、v1(c1)↔v2(c2)、v2(c1)↔v2(c2)。
5. **P5+**：两集群都完成数据面/网关切换后，先逐业务集群执行下线序列，最后处理 global（ServiceMeshGroup finalizer patch → Essentials 卸载）。
6. **Kiali 多集群**：`prometheus/tracing.query_scope.mesh_id` 对齐 `meshID`；监控**必须 VictoriaMetrics**（两集群数据汇聚 global vmselect，环境实测已满足）；Kiali 多集群 kubeconfig secret（`kiali.io/kiali-multi-cluster-secret`）按内部遗留问题页配置。

### 8.1 变体：多集群单网络模式（single network）的迁移适配

> **适用对象**：v1 多集群采用单网络模式的客户——判定特征：跨集群 pod IP 直接互通（底层扁平网络）、无东西向网关、两集群 `network` 同名。
> **性质**：本节为基于多网络实测结论的**设计推演，未实机演练**（2026-07-08 两环境演练均为多网络拓扑）；执行前应在同形态测试环境先走一轮 P0→P6。
> **结论**：迁移期间与迁移终态均**保持单网络**（istio 上游完整支持 same-network multi-primary，sail-operator 未削减该能力）；切换为多网络（ACP Mesh v2 / OCP OSSM 3.x 的产品认证形态）是迁移完成后的**独立第二阶段变更**，两者严禁耦合。

**8.1.1 为什么迁移期间必须保持单网络（正确性硬约束，非偏好）**

1. 双控制面共存期间（P2~P5），v1/v2 istiod 对「端点属于哪个 network」的认知必须一致。network 的判定来源（istiod 的 `values.global.network`、istio-system ns 与 pod 的 `topology.istio.io/network` 标签）在 v1(1.22)/v2(1.28) 语义相同，且 **istio-system ns 标签是两个控制面共享的配置点**——迁移中途为 v2 打 network 标签等于同时改变 v1 的拓扑认知，v1 数据面行为在灰度半途漂移。
2. 若 v2 配为多网络而 v1 保持单网络：v2 sidecar 的远端端点会被 istiod 改写为「对端东西向网关地址」——一个迁移中才新建的组件，任何一步未就位即黑洞路由；而 v1 sidecar 仍走 pod IP 直连。同一张网格两套转发认知，故障在灰度窗口内不可收敛排查。迁移（控制面换代）与拓扑变更（单网 → 多网）是两个高风险变更，必须一次只做一件。
3. 本章 P0+ 的「网格标识逐字段对齐」原则（V-15）天然覆盖本场景：network 属于网格标识，v1 实测同名，v2 照抄即得单网络。

**8.1.2 对 P0–P6 的差异化调整（相对本章多网络基线）**

| 阶段            | 多网络基线（已验证）                                      | 单网络变体                                                                                                                                                            |
| --------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P0+             | 采集 meshId/network/clusterName 及东西向网关 network 标签 | 同左，预期 `network` 两集群同名（以实测为准，两集群必须一致）；无东西向网关可采，备份清单相应减项；**新增前置检查：跨集群 pod IP 直连连通性探测**（单网络的物理前提） |
| P2+             | Istio CR 写 meshID/network/clusterName                    | 同左；`network` 照抄 v1 实测值（同名则同名，两集群一致）；remote secret 复用逻辑不变（**V-16 同样适用**——单网络的跨集群端点发现同样依赖 remote secret）               |
| P2.5 东西向网关 | 部署 v2 版 eastwest gateway（15443 AUTO_PASSTHROUGH）     | **整步跳过**（单网络无东西向网关）                                                                                                                                    |
| P3+             | 跨集群矩阵 v1↔v1 / v2↔v1 / v2↔v2 经网关                   | 同矩阵，预期路径全程 pod IP 直连；新增单网络专属断言：`istioctl proxy-config endpoints` 确认远端端点为**对端 pod IP**（而非网关地址）                                 |
| P5+             | 【D-M2】删 IOP 前摘东西向 Service 归属标签                | **不适用**（无东西向 Service）；南北向网关 Service 保护（D-7/D-11）照旧执行                                                                                           |
| V-17            | 三阶段矩阵验证                                            | 同样必须执行，验收标准不变（矩阵全通），路径预期改为直连                                                                                                              |

其余步骤（webhook 下线序列、asm CR finalizer 旁路、CA 交接、Kiali/VictoriaMetrics 对接）与多网络路径完全同构，按第 10.1 节实测修订执行。整体上单网络变体**少一个组件域**（东西向网关），P4/P5 比多网络更简单。

**8.1.3 终态选择与（可选的）第二阶段：单网络 → 多网络切换**（TODO: 待定）

- **产品背景**：istio 上游四种多集群拓扑（multi-primary / primary-remote × same / different networks）齐全；OCP OSSM 3.x 概念文档承认单网络模型，但**安装步骤与支持矩阵仅覆盖多网络**（ambient 模式明确 multi-primary multi-network 为唯一支持形态）——原因是单网络的前提（跨集群 pod 网络互通）依赖 Submariner/扁平网络等产品外基础设施，不在其认证范围。ACP Mesh v2 对标 OCP，同样仅认证多网络。因此单网络终态**技术成立但落在产品支持矩阵之外**（与本方案「手工 CR」形态性质相同），需与产品团队确认支持口径。
- **决策判据**：客户需要产品 UI 纳管、回到官方支持矩阵 → 迁移完成后追加本切换；客户接受手工 CR 形态、看重单网络优势（跨集群少一跳网关、少一组网关组件与故障域）→ 与产品确认口径后可长期保持单网络终态。
- **切换步骤概要**（独立变更窗口 + 全程业务探测）：
  1. 每集群部署 v2 东西向网关（`istio.io/rev=$V2REV`、15443 AUTO_PASSTHROUGH + expose-services `Gateway`，即本章 P2.5 的做法），确认网关对外地址（LB/NodePort）跨集群可达；
  2. 两集群 Istio CR 分别设 `values.global.network=<net1|net2>`（触发 istiod 滚动）、istio-system ns 打 `topology.istio.io/network` 标签、东西向网关 pod 带对应 network 标签；
  3. istiod 重新下发端点：远端端点由 pod IP 整体切换为对端网关地址；随后滚动业务工作负载，使 pod 获得注入期 network 标签（滚动前 istiod 按集群级配置推断存量 pod 归属，功能可用但不如标签显式）；
  4. 验收：跨集群调用矩阵全通 + `istioctl proxy-config endpoints` 断言远端端点已为对端网关地址；mTLS 信任链不受影响（AUTO_PASSTHROUGH 为 SNI 透传，端到端 mTLS 与同根 CA 均不变）；
  5. 回滚：撤销两集群 network 值与标签（恢复空/同名）即回到 pod IP 直连。
- **不要反向操作**（先在 v1 上切多网络再迁移）：在即将退役的 v1 栈上做全网格端点重算的高风险变更不值得；v1 东西向网关为 asm 形态，迁移时还要按 P4/P5 再迁一遍网关；在 v2 上切换用的是上游标准做法，工具链与文档齐全。

---

## 9. 风险清单与缓解

| #   | 风险                                                                                                                                                                                         | 缓解                                                                                                                         | 验证项     |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------- |
| R1  | asm-controller/global-asm-controller 调和 ns 标签，切换被打回                                                                                                                                | P3 冻结控制器（缩 0，可恢复）；实测若不调和则降为可选                                                                        | V-6        |
| R2  | EnvoyFilter 1.22→1.28 不兼容导致代理配置拒绝                                                                                                                                                 | P0 审计全部 EnvoyFilter（含 asm 生成的），不兼容项改造或随功能替代下线                                                       | P0         |
| R3  | istio-cni 与 kube-ovn/Multus 链式插件冲突（历史已知）                                                                                                                                        | 环境 kube-ovn 版本核对；IstioCNI excludeNamespaces；节点重启场景专项验证                                                     | V-3        |
| R4  | `asm-pod-v1-mutate` 对已切换 ns 注入残留配置                                                                                                                                                 | 实测其影响（预期仅 env 追加，无害）；P5 统一清除 `cpaas.io/serviceMesh` 标签                                                 | V-7        |
| R5  | 删网关 IstioOperator CR 连带删 Service 断流                                                                                                                                                  | `--cascade=orphan` + 删前 ownerReferences 审计                                                                               | V-9        |
| R6  | 中间 CA（60 天）在冻结后无人续期而过期                                                                                                                                                       | P0/P3 前置检查剩余有效期 ≥ 迁移窗口；P6 完成 CA 交接；窗口不足先手动轮换一次                                                 | V-13       |
| R7  | 老 Jaeger 历史 trace 查询断层                                                                                                                                                                | 老 ES 索引（`asm-mesh-*`）保留至过期；如需查询，附录 C 给 Jaeger v2 读老索引的临时配置                                       | —          |
| R8  | 多集群东西向网关跨版本兼容问题                                                                                                                                                               | 过渡期新旧东西向网关并存 + 调用矩阵持续探测；异常即回切                                                                      | V-17       |
| R9  | istio CRD 升级到 1.28 schema 后 v1 出现回归                                                                                                                                                  | P2 后先全量回归探测再进入 P3；CRD 向后兼容为上游承诺                                                                         | V-4        |
| R10 | （单网络变体）迁移期间为 v2 配置 network / 给 istio-system 打网络标签，导致双控制面拓扑认知分裂、跨集群路由黑洞                                                                              | 迁移全程保持单网络（8.1 硬约束），network 逐字段对齐 v1；切多网络仅作为迁移完成后的独立第二阶段变更                          | 8.1        |
| R11 | asm 派生资源（访问日志 Telemetry、网关 TLS secret、网关 Service 等 ownerRef→asm CR）在 P5 删 CR 时被 GC 级联删除；v1 IOP 渲染的 Telemetry 等配置残留污染 v2（**两者均已实际发生，见 10.2**） | P0 属主审计+TLS secret 全量备份；P5 ② 前摘 ownerReferences 并断言在位、⑨ 按 owning-resource 标签清残留；HTTPS 探测纳入探测器 | V-18、10.2 |
| R12 | v2 金丝雀网关缺 SDS RBAC（Role/RoleBinding 读 secrets），HTTPS 证书 WARMING、握手失败，纯 http 探测无法暴露（**已实际发生，见 D-15**）                                                       | P4 按模板落实 gateway-sds-reader RBAC；V-18 断言 `istioctl pc secret` 全 ACTIVE + curl https                                 | V-18       |

---

## 附录

### 附录 A：备选方案——停机卸载重装（测试/非生产）（TODO: 待定）

前提：可接受整段网格流量与遥测中断（sidecar 在 istiod 消失后存量连接仍可短时工作，但无新配置/新证书，网关重启即断）。**适用于尚未创建 v2 `Istio` CR 的集群**；若 v2 控制面已在 istio-system，严禁走 UI 删网格（回到 P5 手工序列）。

**「删除网格」行为的源码结论**（`global-asm-controller`，回应带服务/网关删除的疑问）：

- **前置校验**：「网格内没有任何服务」是产品文档/UI 层约定；CR 层无强校验——`meshinstaller_controller.go` 见 DeletionTimestamp 直接进入 `DeleteServiceMesh`，删除流程仅三步（WasmModuleInstall → `asm` CR → 删除 istio-system 命名空间），带着服务和网关也会照删（未定义路径，不推荐）。
- **istiod 删除不会被已连接的 sidecar 阻断**：istio 没有"仍有 proxy 连接则拒删"的机制，已注入 pod 只是失去 xDS（存量流量短期可用、证书 24 小时内有效、无新配置下发）。可能的阻塞点只有 IstioOperator CR 的 operator finalizer——若 istio-operator 在命名空间终结中先被杀掉，finalizer 无人处理；对此删除流程有兜底：`cleanOrphanOperatorResources` 会**强制剥离 istio-system 内 IstioOperator/Flagger CR 的 finalizer**（`IstioCrSpec.Gvr = istiooperators.install.istio.io`），命名空间删除不会卡死。
- **删除网格对网关的影响（竞态，不保证清理）**：网关的 IstioOperator CR 在 istio-system 内随命名空间删除；但 mesh-gw 中的网关 Deployment/Service 是 istio-operator 跨命名空间渲染的（无 ownerReference），只有 operator 存活并处理 IOP finalizer 剪枝时才会被删——若 finalizer 被上述兜底强剥，**网关工作负载残留为孤儿**（继续运行、无控制面）。因此网关必须在删网格**之前**通过 UI 删除（此时 asm-controller/istio-operator 均存活，GatewayDeploy → 网关 IOP → 网关 Deployment/Service 的级联清理是确定性的）。

步骤：

1. P0 同款盘点+备份（istio 原生资源 yaml 是恢复的生命线）；
2. **UI 移除全部微服务**（去注入并滚动重启一次，满足产品删除前置）→ **UI 删除全部网关**（确定性清理 mesh-gw 工作负载）→ 复核外部服务绑定等自动生成资源已处置；
3. UI「删除网格」（此时网格内无服务无网关；其会删除 istio-system——正好清场），确认命名空间删除完成、无 Terminating 卡滞与孤儿资源；卸载 v1 operator 订阅残留 + global Essentials 插件；
4. 按 servicemesh2-docs 全新安装 v2（operator → IstioCNI → Istio → Kiali → OTel v2/Jaeger v2）；
5. 恢复 istio 原生资源备份（剥离 server 端字段与 asm 属主标签）；
6. ns 打 v2 注入标签 + 全量重启（连同第 2 步共两次重启）；网关按 v2 形态重建；
7. 终态验收同 P6。

> 本附录路径不在两套环境演练范围内（环境用于主路径全流程验证），删除行为结论基于源码推导；如需实证可在单集群环境完成主路径验证并恢复 v1 后追加演练。

### 附录 B：P5 之后的灾难恢复（重装 v1）清单

Essentials 插件包与 4 个 operator 包（版本 v4.3.5 系）、ServiceMesh/ServiceMeshGroup CR 备份、治理 CR 备份、ns 标签快照、cacerts/根证书备份、ES 索引未动即可恢复历史。恢复顺序 = 安装文档正序 + CR 回放，恢复后按 P0 探测器验证。

### 附录 C：Jaeger v2 查询老索引（可选）

Jaeger v2（OpenTelemetryCollector 形态）ES 存储配置临时增加老索引前缀 `asm-mesh-<meshID>` 的只读查询源，或保留一个只读的旧 jaeger-query 实例直至索引过期（默认 ES ILM/清理策略 7 天–N 天，以环境为准）。

### 附录 D：功能替代方案索引

- 灰度发布：ACP Argo Rollouts 集成文档（TODO: servicemesh2-docs integration 章节或者 ACP Argo Rollouts 相关章节）
- 全局限流：istio 官方 [ratelimit 方案](https://istio.io/latest/docs/tasks/policy-enforcement/rate-limit/)（EnvoyFilter + RLS + Redis 自建）
- API 指标分类：istio 官方 [Classifying Metrics](https://istio.io/latest/docs/tasks/observability/metrics/classify-metrics/)
- 实例隔离：K8s 原生（改 label 使其脱离 Service selector / `kubectl cordon` 类操作）说明
- 日志级别：`sidecar.istio.io/logLevel` 注解（Kiali 可视化编辑）

### 附录 E：证据与引用

- v1 删除流程删 istio-system：`mesh-v1/monorepo/global-asm-controller/pkg/mesh/manage.go`（delete istio-system 段）
- v1 CA 机制：`mesh-v1/monorepo/global-asm-controller/pkg/istioca/certmanager/ca.go`、`charts/global-asm/templates/istio/istio-ca.yaml`
- v1 IstioOperator 渲染：`mesh-v1/monorepo/global-asm-controller/pkg/iopcr/templates/cr-1-22.yaml`
- remote secret 生成：`mesh-v1/monorepo/global-asm-controller/pkg/meshGroup/remoteSecret.go`
- v2 CR 语义：`sail-operator/api/v1/*.go`、`servicemesh2-docs/docs/en/`（installing/updating/gateways/integration/uninstalling）
- OCP 迁移方法论：本目录 `evidence/ocp-mesh2to3-migration.md`（全文提炼版）
- 内部评估：Confluence pageId=301727839（功能列表与不兼容改动）、323289121（遗留问题：CNI/CA/Kiali 多集群）、407797966（Kiali UI 对比）、358711407/358711409（v1/v2 资料索引）
- 环境实测记录：本设计第 2 章（2026-07-08 采集）

## TODO

- [ ] 将迁移过程脚本化，但迁移过程比较复杂，涉及单集群多集群等多种场景，建议不做
- [ ] Mesh v2 文档 Kiali 支持多集群
- [ ] Mesh v2 文档支持多集群单网络模式（待定）
  - [ ] Mesh v1 的单网络是否要迁移到多网络模式？
- [ ] 设计方案确定后
  - [ ] 编写单集群、多集群单网络和多网络的迁移文档
  - [ ] 测试迁移文档
