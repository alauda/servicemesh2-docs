# 设计文档：Mesh v1 迁移到 Mesh v2 产品文档

- 日期：2026-07-09
- 状态：已与任务方确认（brainstorm 决策全部落定）
- 性质：内部设计文档（位于 internalRoutes 忽略路径，不进正式构建）
- 交付物：`docs/en/migrating/` 分区（17 个 MDX + sites.yaml 一处修改），正文中文撰写，文件名/frontmatter/目录结构按仓库英文惯例，英文翻译后续单独进行

## 1. 背景与目标

为 ACP Service Mesh 编写「Mesh v1 迁移到 Mesh v2」官方产品文档。迁移方案已在两套真实 ACP v4.3.2 环境（单集群 + 多集群多网络）完成 P0–P6 全流程验证。本文档站读者为**客户的平台管理员/SRE**（仅有平台与 kubectl 权限），必须把内部工程方案产品化改写为客户可执行的操作文档。

**版本适用性声明**（概览页页首 `:::info`，各页不重复）：

- ACP v4.3.x
- 源：Mesh v1 (ASM) v4.3.5 / istio 1.22.x
- 目标：Mesh v2 (servicemesh-operator2) v2.1.x / istio 1.28.x

## 2. 权威源材料与引用规则

| 材料 | 路径 | 引用规则 |
|---|---|---|
| 设计方案 | `/home/vscode/repo/my-tasks/task-meshv1-migration-design/Mesh v1 迁移到 Mesh v2 设计方案.md` | 正文与 **10.1 节实测修订**冲突时，一律以 10.1 为准；**8.1 节（多集群单网络变体）为设计推演、未实机演练**，引用时必须区分性质（其余正文均经两环境实测） |
| 验证总结报告 | 同目录 `验证总结报告.md` | V-1~V-17 结论、探测统计、遗留风险；用于支撑「已验证」表述与中断预期数据 |
| 偏差记录 | `evidence/single/deviations.md`（D-1~D-14）、`evidence/multi/deviations.md`（D-M1~D-M2） | 教训改写为前置检查、`:::warning` 告警或排障条目；不照抄演练叙事 |

**产品化红线**（对全部 17 篇生效）：

1. 隐去全部内部演练叙事（环境 IP、mesh-demo/mesh-gw 等演练资源名按需改为通用示例或占位符）。
2. 环境特定值全部参数化：IP/集群名/网关名/revision 一律占位符（`<cluster-name>`、`<v2-revision>` 等）或给出「发现命令」（如监控地址与授权从 Feature CR 的 `spec.accessInfo.database.address`/`basicAuth.secretName` 获取）。
3. 不出现内部编号（V-x/D-x/R-x/P0–P6 编号可在文档内作为「阶段」概念重新定义后使用，但不引用内部验证项编号）与内部链接（Confluence、mesh-v1 源码路径）。
4. 10.1 节实测修订必须融入对应步骤正文（详见 §6 各篇要点）。
5. 每个阶段末尾给出客户可执行的验证检查点（命令 + 期望输出）。
6. 中文行文遵循技术文档规范：术语/资源名/命令保留英文，中英文之间留空格。

## 3. 已确认决策（brainstorm 结论）

| # | 决策项 | 结论 |
|---|---|---|
| 1 | 位置与形态 | 顶层 `docs/en/migrating/` 分区（weight 75），多页 + 二级目录；不挂 updating/ 下 |
| 2 | 停机卸载重装（设计附录 A） | 收录为独立页 `migrating-with-downtime.mdx` |
| 3 | runme 命名 | 本次**不加** `{name=prefix:action}`（与「有测试脚本才命名」的仓库惯例一致；待测试框架具备 v1 环境初始化能力后由 auto-test-creator 补加） |
| 4 | 单网络变体口径 | 独立页面，与多网络页并列；「单转多切换」再独立一页 |
| 5 | 未演练内容免责规格 | 页首 `:::warning` 性质声明 + 正文事故级禁令用 `:::danger`（danger 保持稀缺） |
| 6 | 单网络终态口径 | **中性判据式**：需要认证形态/UI 纳管 → 迁移完成后切多网络；接受手工 CR 形态且看重单网络优势 → 联系支持确认支持口径后可保持。不替客户拍板 |
| 7 | 中文正文位置 | 仓库无 zh 树；中文正文直接写入 `docs/en/migrating/` 英文命名文件，翻译时原地替换 |
| 8 | 提交方式 | 分篇撰写、分篇提交（新 commit，禁止 amend） |

## 4. 目录结构与导航

导航机制：frontmatter 仅 `weight`，标题取正文 H1；目录 `index.mdx` 用「weight → H1 → 一句话简介 → `<Overview overviewHeaders={[]} />`」骨架。顶层分区排序：about(10) installing(30) integration(40) gateways(60) updating(70) **migrating(75)** uninstalling(80) apis(1000)。

```
docs/en/migrating/
├── index.mdx                                    w:75   骨架
├── migration-overview.mdx                       w:10
├── preparing-for-migration.mdx                  w:20
├── migrating-a-single-cluster-mesh/
│   ├── index.mdx                                w:30   骨架 + 阶段流程与回滚点示意
│   ├── installing-the-v2-control-plane.mdx      w:10
│   ├── migrating-workloads.mdx                  w:20
│   ├── migrating-gateways.mdx                   w:30
│   ├── decommissioning-mesh-v1.mdx              w:40
│   └── finalizing-the-migration.mdx             w:50
├── migrating-a-multi-cluster-mesh/
│   ├── index.mdx                                w:40   带实质内容：拓扑判定门（有 upgrade-kiali/index.mdx 先例）
│   ├── migrating-a-multi-network-mesh.mdx       w:10
│   ├── migrating-a-single-network-mesh.mdx      w:20
│   └── switching-to-multi-network.mdx           w:30
├── migrating-observability.mdx                  w:50
├── migrating-with-downtime.mdx                  w:60
├── rollback.mdx                                 w:70
└── troubleshooting.mdx                          w:80
```

配套改动：`sites.yaml` 新增 `opentelemetry` 站点条目（供 `<ExternalSiteLink>` 引用 OTel v1→v2 迁移文档；base 路径与 version 以 opentelemetry-docs 实际发布配置为准，实施时核对）。

## 5. 页面 H1（中文暂定）

| 文件 | H1 |
|---|---|
| index.mdx | 从 Mesh v1 迁移到 Mesh v2 |
| migration-overview.mdx | 迁移概览 |
| preparing-for-migration.mdx | 迁移准备与前置检查 |
| single-cluster/index.mdx | 单集群网格迁移 |
| installing-the-v2-control-plane.mdx | 安装 v2 控制面（并存部署） |
| migrating-workloads.mdx | 迁移工作负载 |
| migrating-gateways.mdx | 迁移网关 |
| decommissioning-mesh-v1.mdx | 下线 Mesh v1 |
| finalizing-the-migration.mdx | 完成迁移（收编与 CA 交接） |
| multi-cluster/index.mdx | 多集群网格迁移 |
| migrating-a-multi-network-mesh.mdx | 迁移多网络多集群网格 |
| migrating-a-single-network-mesh.mdx | 迁移单网络多集群网格 |
| switching-to-multi-network.mdx | 切换到多网络拓扑 |
| migrating-observability.mdx | 迁移可观测栈 |
| migrating-with-downtime.mdx | 停机卸载重装迁移 |
| rollback.mdx | 回滚指引 |
| troubleshooting.mdx | 故障排查与常见问题 |

## 6. 各篇章节要点与源材料指针

> 「源」列为撰写取材指针（内部编号仅在本设计文档出现，产品正文严禁出现）。

### 6.1 migration-overview.mdx —— 源：设计 §1–§5、§4 功能映射表

1. 页首 `:::info` 版本适用性表（见 §1）。
2. 为什么迁移：v1 基于社区已废弃的 istio-operator，将于 ACP 4.4 下线；v2 基于 Sail Operator（servicemesh-operator2）。
3. v1/v2 架构对比表：控制面、注入机制（istio-init vs IstioCNI + native sidecar）、网关形态、可观测栈、多集群、管理入口（UI+自研 CR vs YAML/kubectl 原生 CR）。
4. 功能对照与替代方案（设计 §4 产品化）：自研治理 CR → 原生资源对照；CanaryDelivery → Argo Rollouts 集成；GlobalRateLimiter → istio 官方 ratelimit 方案；IsolatePod/APIAttribute → 替代说明；`ASM_MS_NAME`/`asm.cpaas.io/msname` 不复存在（业务感知项）。外链 istio 官方文档。
5. 迁移策略选择：并存灰度（主推，业务不中断，已在单集群与多集群环境全流程验证）vs 停机卸载重装（测试/非生产，链接 §6.14 页）。
6. 迁移路线图：P0–P6 阶段图（ASCII 或列表 + 每阶段一句话），标注回滚点与不可回退点（链接 rollback.mdx）。阶段编号 P0–P6 在本文档站内重新定义为「迁移阶段」术语后全书使用。
7. 并存为什么是安全的（设计 §5 四支柱产品化，剥离验证项编号）：同根 CA（v1 的 cacerts 即标准 istio 插件 CA 格式，v2 istiod 直接加载 → mTLS 全程互通）、revision 隔离（v1 本身就是 rev=1-22 的 revision 化部署）、webhook 错峰（共存期不建 default IstioRevisionTag）、CNI 互斥（istio-cni 自动跳过含 istio-init 的 pod）。
8. `:::danger` 红线预告：v2 `Istio` CR 创建之后，严禁通过平台 UI 删除 Mesh v1 网格 / 删除 `ServiceMesh` CR 交由控制器处理（v1 删除流程会删除整个 istio-system 命名空间，v2 控制面同在其中）。
9. 占位符与「发现命令」约定：`<cluster-name>`、`<v2-revision>`（示例 default-v1-28-6）、`<gateway-name>`、`<mesh-namespace>` 等；凡环境特定值，正文均给读取命令。

### 6.2 preparing-for-migration.mdx —— 源：设计 §6 P0、10.1 相关前置化、D-1/D-4/D-5/D-6/D-9/D-11

1. 前置条件：ACP 与 Mesh 版本、servicemesh-operator2 可安装/已安装、ACP Networking for Multus 插件（IstioCNI 需要 `cniConfDir: /etc/cni/multus/net.d`）、kubectl 权限、维护窗口与干系人确认。
2. 兼容性与风险检查（命令 + 判据逐项给出）：
   - ServiceEntry 1.28 schema 审计（缺 port / hosts 超限的 jq 检查）；
   - EnvoyFilter 审计：重点检查带 `proxyVersion` 版本锁（如 `^1\.22.*`）的过滤器——v2 数据面为 1.28，这些过滤器将不再生效；甄别业务是否依赖（黑白名单/API 属性类为 v1 自研功能，随 v1 下线，如仍需要须在 v2 以原生资源重建）；
   - `cacerts` 中间 CA 剩余有效期检查（背景：v1 中间 CA 60 天有效、由 v1 控制器自动续期，迁移会终止该续期链）：剩余有效期必须 ≥ 计划迁移窗口；
   - 单节点/istiod 节点重合集群识别（v1 istiod 带硬反亲和，会阻塞 v2 istiod 调度；处理动作在控制面安装页的条件步骤）；
   - 参与切换的服务副本数 ≥2 且配置 PDB（否则每服务接受一次秒级中断）；
   - 业务对 `ASM_MS_NAME`/`asm.cpaas.io/msname` 的依赖排查；
   - 「带 `istio.io/rev` 标签但实际无 sidecar」的命名空间甄别（记录在案，下线阶段摘标而非切换）。
3. 资源盘点与备份（分组命令）：网格 ns 与工作负载、MicroService 等自研 CR、网关（IstioOperator CR、GatewayDeploy、**网关 Service YAML 必须单独备份**——应急重建生命线）、istio 原生资源全量、OTel/Jaeger/Instrumentation、OLM 订阅与 CSV、global 侧 ServiceMesh/ServiceMeshGroup/根证书、`cacerts` 与 remote secret。
4. 变更冻结约定：迁移期间不通过 v1 UI 做任何网格变更；暂停相关 operator 升级审批。
5. 业务探测器就位：探测点覆盖（网格内调用 + 网关入口 + 出口 + 多集群跨集群路径）；探测源位置要求（网格外或最后迁移的稳定 ns，避免探测源自身滚动造成误判）；示例 curl 循环脚本。
6. 验证检查点：盘点产物与备份清单齐备性核对。

### 6.3 migrating-a-single-cluster-mesh/index.mdx

骨架 + 阶段流程简述（P1→P6 顺序、每阶段一句话、回滚点标注、不可回退点位置）+ Overview。

### 6.4 installing-the-v2-control-plane.mdx —— 源：设计 §6 P1+P2、10.1 P2 修订（D-4）、D-3/D-M1 闭环

结构：H2「准备可观测性」（P1）+ H2「安装 v2 控制面」（P2）。

P1 要点：
1. 安装 kiali-operator（OLM）；创建 Kiali CR：
   - 数据源权威获取方式：读业务集群 `Feature`（`infrastructure.alauda.io/v1alpha1`，name=monitoring）的 `spec.accessInfo.database.address`（→ `prometheus.url`）与 `spec.accessInfo.database.basicAuth.secretName`（cpaas-system 下 basic auth secret）；secret 复制到 Kiali 部署 ns，凭据用 `secret:<name>:username/password` 引用语法；
   - 单集群 Prometheus 或 VictoriaMetrics 皆可；多集群必须 VictoriaMetrics（VM 时 `thanos_proxy.enabled: true`）；
   - `auth.strategy: openid` 细节链接 `integration/observability/kiali.mdx`；
   - tracing 数据源暂指向 v1 Jaeger（终态翻转，链接可观测页）。
2. v2 指标采集：istiod ServiceMonitor + Envoy PodMonitor（`metadata.labels.prometheus: kube-prometheus`；PodMonitor 覆盖所有 mesh ns）。
3. 验证：Kiali 可见现有 v1 网格流量拓扑。

P2 要点：
1. 前置确认：Multus 插件与 servicemesh-operator2 就绪。
2. **条件步骤（单节点/节点重合集群）**：先将 v1 istiod 反亲和降级——对 IOP `spec.components.pilot.k8s.affinity` 执行 JSON-patch **replace**（必须 replace，merge 会保留原 required 条目）为 preferred，同时 strategy 设 `rollingUpdate: {maxSurge: 0, maxUnavailable: 1}`；说明：v1 istiod 将滚动一次，数据面无扰动；多节点集群跳过。
3. 创建 IstioCNI CR（name=default、namespace istio-cni、`cniConfDir: /etc/cni/multus/net.d`、excludeNamespaces）。
4. 创建 Istio CR：RevisionBased；`spec.values.global.meshID` 用发现命令对齐 v1 实测值（`kubectl -n istio-system get cm istio-1-22 -o jsonpath='{.data.mesh}'` 读取 meshId/trustDomain）；`inactiveRevisionDeletionGracePeriodSeconds` 迁移期加大；`meshConfig.extensionProviders` 暂指向 v1 现存 collector（`asm-otel-collector.cpaas-system` 4317）保证调用链连续；采样率对齐 v1。
5. `:::warning`：共存期间不得创建 default `IstioRevisionTag`（v1 占用 `istio-revision-tag-default` webhook，冲突会造成注入行为异常；终态收编阶段才创建）。
6. 创建 rootNamespace 级 Telemetry CR（`tracing.providers: [otel]`）。
7. 获取 v2 revision 名（`kubectl get istiorevisions`，链接 `identifying-the-revision-name.mdx`）。
8. 验证检查点：istiod Ready；**加载同一 cacerts 的证据**（istiod 日志 `Use root cert from etc/cacerts` / 对比新旧 istiod 根证书）；`kubectl get istiorevisions` 正常；v1 数据面与业务探测零扰动。
9. 页末 `:::danger`：自 v2 Istio CR 创建起，严禁 UI 删除网格（红线正式生效，语句与 overview 一致）。

### 6.5 migrating-workloads.mdx —— 源：设计 §6 P3、10.1 P3 修订（V-6/V-7/D-5/D-6）

1. 原理：`istio.io/rev` 精确匹配，改标签即切换注入归属；实测 v1 控制器不调和该标签 → 无需冻结控制器即可切换。
2. 可选小节「冻结 v1 控制器」：适用场景（发现标签被回写/副本数被调和时）+ 三件套 scale 命令（global-asm-controller → asm-operator → asm-controller）+ 回滚时恢复副本数。
3. 逐 ns 切换（一次一个，验证后再下一个）：`kubectl label ns <ns> istio.io/rev=<v2-revision> --overwrite` → `rollout restart` → `rollout status` → `istioctl proxy-status --revision <v2-revision>`（ISTIOD 列应指向 v2 istiod；RevisionBased 下 istioctl 需带 `--revision`）。
4. `:::note` native sidecar 形态说明：v2 注入的 istio-proxy 是 `restartPolicy: Always` 的 initContainer，`kubectl get pod` 的容器计数变化属预期。
5. `cpaas.io/serviceMesh=enabled` 标签本阶段保留（回滚需要；v1 webhook 对 v2 pod 的追加配置无害），下线阶段统一清除。
6. 跨控制面互通验证：已迁 ns ↔ 未迁 ns 互调 + mTLS 证书链同根（`istioctl proxy-config secret` 的 ROOTCA subject 为 `ASM Istio Root CA`）。
7. 中断预期：副本 ≥2 + PDB 为零中断；单副本每服务一次秒级中断（`:::note`）。
8. 纯 OTel（无 sidecar）ns 本阶段不动，链接可观测页。
9. 验证检查点：目标 ns 全部 proxy 指向 v2 istiod、业务探测正常、Kiali 流量正常。

### 6.6 migrating-gateways.mdx —— 源：设计 §6 P4、10.1 P4 修订（D-8 三教训）、V-9/V-10

1. 顺序总则：**先将网关 ns 的 `istio.io/rev` 切到 v2，再部署 v2 金丝雀网关**（ns 仍为 v1 rev 时，v2 网关 Deployment 会被 v1 webhook 注入 1.22 proxy）；网关 ns 的 rev 切换不触碰在跑 pod，安全。
2. `:::warning` 单向门：网关 ns rev 切到 v2 后，v1 旧网关**不可再重建**（其 pod 模板的 `inject.istio.io/templates: asm-gateway` 在 v2 无对应模板，pod 创建被拒）；v2 网关就绪验证是缩容 v1 旧网关（切流）的前置门槛；ns rev 切换后应立即部署并验证 v2 网关，缩短 v1 不可重建的暴露窗口；回滚预案不能依赖旧网关扩容（详见 rollback 页）。
3. 前置：检查网关 Service ownerReferences（属主可能为 GatewayDeploy）；采集 Service selector 与 Gateway CR selector（两条发现命令）。
4. 部署 v2 金丝雀网关 Deployment：`inject.istio.io/templates: gateway` + `image: auto` + `istio.io/rev: <v2-revision>`；**pod 标签必须取 Service selector 与 Gateway CR selector 的并集**（缺 Gateway CR selector 标签 → listener 不绑定 → 404），用 `<Callouts>` 标注模板关键字段；ServiceAccount/RBAC 链接 `installing-a-gateway-via-injection.mdx`。
5. 金丝雀切流：v2 扩容 → 验证 listener 绑定与实际流量 → 旧网关逐步缩容 → 缩 0 **保留**（回滚用，下线阶段才删）。
6. egress 网关同法；istio-system 默认网关（istio-ingressgateway）：有流量同法处理，无流量记录后随下线阶段移除。
7. 外部服务绑定自动生成的 Gateway/VirtualService 打 `asm.cpaas.io/user-managed: "true"` 注解（防 v1 清理时 GC）。
8. 验证检查点：v2 网关承载 100% 流量、探测 0 中断、Gateway/VirtualService 原生资源未改动。

### 6.7 decommissioning-mesh-v1.mdx —— 源：10.1 P5 序列重写（全量）、D-9/D-10/D-11/D-12、V-11/V-12

1. 页首 `:::danger`：严禁 UI 删除网格 / 删除 ServiceMesh CR 交给控制器（会删除整个 istio-system；本页全部为手工序列）。
2. Go/No-Go 检查单：全部业务 ns rev 指向 v2、无 proxy 连接 v1 istiod、网关全部 v2 承载、备份齐备、干系人确认；**例外清单**概念：v1 自有 istio-ingressgateway（无业务 listener）豁免；「带 rev 标签但从未注入」的 ns 摘标即可。
3. `:::warning` 不可回退点：过此点回滚 = 按备份重装 v1（灾难恢复级，链接 rollback 页）。
4. 手工下线序列（`<Steps>` 组织，每步含验证）：
   1. 备份复核：网关（多集群含东西向）Service YAML 单独在手；
   2. global 集群：**先删 3 个 asm webhook 配置**（servicemesh-v1alpha1-mutation、servicemeshgroup-v1alpha1-mutation、global-asm-controller-validating-webhook-configuration）→ 冻结 global-asm-controller（replicas=0 并确认）→ 删 ServiceMesh CR（`--wait=false`）→ patch 摘 finalizer → 断言 CR 消失且 **istio-system 保留**；`:::warning` 顺序不可颠倒：控制器冻结后其 failurePolicy=Fail 的 webhook 拦截一切 patch；且严禁拉起控制器解锁（CR 带 deletionTimestamp 时控制器复活即执行删除流程）；
   3. global 卸载 Service Mesh Essentials 插件（Marketplace UI；CLI 等效：删 moduleplugin/asm-global + apprelease/asm）；
   4. 业务集群：先删 asm webhook 配置（asm-pod-v1-mutate、gatewaydeploy-v1alpha1-*、microservicepolicy-* 等）→ 冻结 asm-controller → 摘网关 Service ownerReferences → **`kubectl get svc -o jsonpath='{.metadata.ownerReferences}'` 验证为空**（patch 返回成功不可信）→ 删自研治理 CR（finalizer 卡滞逐个 patch）→ **立即断言网关 Service 在位**；
   5. asm CR（cluster-scoped）：delete 后必卡 pre-uninstall hook（其按「pod 带 sidecar」清点而非实际 xDS 连接，v2 已接管场景必然误判、无限重试）→ 摘 finalizer 旁路 → operator 自行清理 helm release 资源；未清理项按 release manifest 手工删除；flagger CR 可正常删除；
   6. 删 v1 系 OLM 订阅与 CSV（asm/flagger-operator/jaeger-operator/opentelemetry-operator v1）；
   7. 删网关 IstioOperator CR（说明：`--cascade=orphan` 不能阻止 istio-operator finalizer 删除其管理资源——旧网关残壳正好随之清理；Service 已摘 ownerRef/归属标签故保留）→ 删控制面 IstioOperator CR（联动回收 istiod-1-22、istio-ingressgateway、1-22 系 webhook）→ 删 istio-operator Deployment 及 RBAC；
   8. 残留清理：default 位 webhook（istio-revision-tag-default、istiod-default-validator，若未随 IOP 回收）、ns 的 `cpaas.io/serviceMesh` 标签、asm CRD（确认无实例后）；**istio CRD（networking/security/telemetry.istio.io）保留**——已由 v2 operator 接管。
5. 终局断言：asm CRD 为零、istio-system 仅剩 v2 组件与 Kiali、业务探测 0 中断、global 无 asm 组件。
6. 多集群叠加项提示框：global 部分（步骤 2、3）一次性处理全部业务集群的 ServiceMesh CR 与 ServiceMeshGroup，业务集群部分（步骤 1、4–8）逐集群执行；东西向网关 Service 的归属标签须在删除该集群任何 IstioOperator CR 之前摘除，摘标步骤见多网络页。

### 6.8 finalizing-the-migration.mdx —— 源：设计 §6 P6、10.1 P6 修订（D-13、V-13）

1. default 收编：前置——为 v1 遗留 `istio-reader-service-account` 补 Helm 元数据（`app.kubernetes.io/managed-by=Helm` 标签 + `meta.helm.sh/release-name=default-base`、`meta.helm.sh/release-namespace=sail-operator` 注解；否则 default IstioRevisionTag 首次调和报 Helm ownership 冲突）→ 创建 default IstioRevisionTag →（可选）逐 ns 回归 `istio-injection=enabled` + 摘 rev 标签 + 滚动（链接 sidecar-injection-with-istiorevisiontag.mdx）。
2. CA 生命周期交接（根不变、换长期中间 CA）：背景说明（v1 的 60 天中间 CA 自动续期链已随控制器下线）→ 从 global 导出根 CA（root key 离线保管，不落业务集群）→ openssl 用同一根签发长期中间 CA（有效期按客户策略，建议 1–2 年并建立轮换 SOP；流程链接 multi-cluster/configuration-overview.mdx 证书章节）→ 重建 cacerts 四件套 secret → istiod 热加载 → 验证：istiod 日志 `Update Istiod cacerts`、新 pod 证书 issuer 为新中间 CA、存量 pod 零重启；`:::note` 存量工作负载证书 90 秒内未轮换属正常（24h TTL 内自然轮换；滚动单个 deploy 即可验证新链）。
3. 可观测终态：链接 migrating-observability.mdx（时序说明：v1 下线完成后即可进行）。
4. 终态验收清单：`kubectl get istio,istiocni,istiorevisiontag` 全 Healthy、Kiali 拓扑、Jaeger v2 调用链、残留扫描为零、探测器撤除与备份归档。

### 6.9 migrating-a-multi-cluster-mesh/index.mdx —— 源：设计 §8 P0+、8.1 判定特征

1. 适用性说明：以单集群流程为基线，本目录为多集群叠加项；多集群迁移按**网络拓扑**分两条路径。
2. **拓扑判定（进入任一路径前必做）**：采集两集群网格标识（`kubectl -n istio-system get cm istio-1-22 -o jsonpath='{.data.mesh}'` 读 meshId/network/clusterName；东西向网关 `topology.istio.io/network` 标签）→ 跨集群 pod IP 直连检查命令 → 判定表：两集群 network 同名 + pod IP 直连可达 + 无东西向网关 → 单网络路径；network 不同名 + 有东西向网关 → 多网络路径。
3. Overview 子页列表。

### 6.10 migrating-a-multi-network-mesh.mdx —— 源：设计 §8（实测基线）、D-M1/D-M2

1. 开篇：本路径已在多集群环境全流程验证；相对单集群各阶段的叠加点总览表。
2. P0+：网格标识采集（meshId/network/clusterName、东西向网关标签），v2 Istio CR 必须逐字段对齐。
3. P2+：每集群 Istio CR 增加 `global.meshID/network/multiCluster.clusterName`；共享 CA 直接复用（两集群 cacerts 同根）；remote secret 复用（`istio-remote-secret-<peer>` 对 v2 istiod 直接生效，`istioctl remote-clusters` 断言 synced）。
4. P2.5 东西向网关：每集群以 gateway injection 部署 v2 版 eastwest gateway（`istio.io/rev=<v2-revision>`、`topology.istio.io/network=<network>`、15443 AUTO_PASSTHROUGH）；沿用/新建 expose-services Gateway；过渡期 v1/v2 东西向网关并存（SNI 透传与控制面版本解耦）。
5. P3+：按集群逐 ns 切换；跨集群三态调用矩阵持续探测（v1↔v1、v1↔v2、v2↔v2）。
6. P5+：global 编排源头先行（删 webhook→冻结→删全部 ServiceMesh CR 与 SMG→摘 finalizer→卸插件），随后逐业务集群执行下线序列；**删 IOP 前先摘东西向网关 Service 的 operator 归属标签**（`install.operator.istio.io/owning-resource-`、`operator.istio.io/managed-`），建议进入序列前统一摘除。
7. P6+：每集群独立中间 CA（同根，subject 以集群区分）；Kiali 多集群（必须 VictoriaMetrics、`query_scope.mesh_id` 对齐 meshID、多集群 kubeconfig secret `kiali.io/kiali-multi-cluster-secret`）；Jaeger 索引前缀按集群区分。
8. 验证检查点：跨集群矩阵全通、`istioctl remote-clusters` synced、CA 轮换后跨集群 mTLS 正常。

### 6.11 migrating-a-single-network-mesh.mdx —— 源：设计 §8.1（推演，性质必须区分）

1. 页首 `:::warning` 性质声明：本文步骤基于已验证的多网络迁移基线推演适配，未经端到端实机演练；执行前应先在同形态测试环境完整演练一轮。
2. 适用判定（回指 index 判定节）：跨集群 pod IP 直接互通、无东西向网关、两集群 network 同名。
3. 核心原则 `:::danger`：迁移全程 v2 的 network 配置**逐字段照抄 v1 实测值**（同名则同名、两集群一致）；**严禁**迁移中途给 istio-system 打 `topology.istio.io/network` 标签或为 v2 单独设置 network——双控制面对「端点属于哪个网络」认知分裂，v2 会把远端端点改写为尚未就位的网关地址，造成跨集群路由黑洞。
4. 原理简述（为什么这是硬约束）：network 判定来源（`values.global.network`、istio-system ns 与 pod 标签）是两个控制面**共享**的配置点；控制面换代与拓扑变更是两个高风险变更，一次只做一件。
5. 相对多网络路径的差异表：P0+ 新增跨集群 pod IP 直连前置检查、无东西向网关可采集；P2+ network 照抄（remote secret 复用不变）；P2.5 **整步跳过**；P3+ 矩阵相同 + 单网络专属断言（`istioctl proxy-config endpoints` 确认远端端点为对端 pod IP 而非网关地址）；P5+ 无东西向 Service 摘标步骤（南北向网关 Service 保护照旧）；其余步骤与多网络完全同构。
6. 终态选择（中性判据式）：需要产品 UI 纳管/回到产品认证形态 → 迁移完成后按「切换到多网络拓扑」页执行；接受手工 CR 形态、看重单网络架构优势（跨集群少一跳网关、少一组网关组件与故障域）→ 联系支持确认支持口径后可保持单网络终态。
7. `:::note` 不要反向操作：不要先在 v1 上切换为多网络再迁移（在即将退役的栈上做全网格端点重算，且 v1 东西向网关迁移时还要再迁一遍）。

### 6.12 switching-to-multi-network.mdx —— 源：设计 §8.1.3（推演）

1. 页首 `:::warning`：本页为迁移完成后的**独立变更**，须在独立变更窗口执行、全程业务探测，禁止与迁移步骤混排；同为推演性质（声明与单网络页同规格）。
2. 前提：迁移已完成且稳定运行；东西向网关对外地址（LB/NodePort）跨集群可达性预检。
3. 步骤：每集群部署 v2 东西向网关（同多网络页 P2.5 做法）→ 两集群 Istio CR 分别设 `values.global.network=<net-1|net-2>`（触发 istiod 滚动）+ istio-system ns 打 `topology.istio.io/network` 标签 + 东西向网关 pod 带对应 network 标签 → 滚动业务工作负载（使 pod 获得注入期 network 标签；滚动前 istiod 按集群级配置推断，功能可用）。
4. 验证：跨集群矩阵全通 + `istioctl proxy-config endpoints` 断言远端端点已为对端网关地址 + mTLS 不受影响（AUTO_PASSTHROUGH 为 SNI 透传，端到端 mTLS 与同根 CA 不变）。
5. 回滚：撤销两集群 network 值与标签（恢复原状）即回到 pod IP 直连。

### 6.13 migrating-observability.mdx —— 源：设计 §6 P6.3、10.1 P6 修订（D-14 及补记、D-3/D-M1 闭环）、附录 C

1. 时序说明 + `:::warning` 遥测中断窗口：v1 OTel/Jaeger 已随 v1 下线阶段移除，中断自该时点起，本页完成后恢复（与 OTel 官方迁移路径一致）。
2. 安装 v2 tracing 栈：opentelemetry-operator2 + Jaeger v2（jaeger-system，OpenTelemetryCollector 形态）——差异化引用 distributed-tracing 站（ExternalSiteLink）；本迁移特有：ES 索引前缀按 meshID 规划、与旧 `asm-mesh-*` 索引区分；多集群每集群独立实例共享存储、索引前缀分集群。
3. 翻转 Istio CR `extensionProviders[].opentelemetry.service` → `otel-collector.jaeger-system.svc.cluster.local`；若用 discoverySelectors 需给 jaeger-system 打标。
4. Java Agent（OTel 注入）迁移：
   - `:::warning` 关键差异：v1 的 `instrumentation.opentelemetry.io/inject-java` 注解由 asm webhook 动态打在 pod 上（deployment template 是干净的），该 webhook 已随 v1 下线——必须把 `inject-java` 与 `java-container-names` 注解**显式补到 deployment template**；
   - Instrumentation CR 重建（工作负载 ns）：**显式** `spec.java.image`（`registry.alauda.cn:60070/asm/opentelemetry-operator/autoinstrumentation-java:2.26.1`）+ `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` + endpoint `http://otel-collector.jaeger-system:4318`；`:::note` 镜像仓库可达性/凭据先行确认；
   - 滚动重启 + 验证：新 trace 携带 `telemetry.distro.version=2.26.1`；
   - 细节引用 OTel v1→v2 迁移文档（ExternalSiteLink，依赖 sites.yaml 新条目）。
5. Kiali tracing 数据源翻转到 Jaeger v2（16685/gRPC）。
6. 历史 trace 处置小节：旧 ES 索引保留至过期；如需查询给出 Jaeger v2 增加旧索引只读源/保留只读旧 query 实例的思路（简述）。
7. 验证检查点：全链路在 Kiali 拓扑可见、调用链在 Jaeger v2 可查、JVM 指标恢复。

### 6.14 migrating-with-downtime.mdx —— 源：设计附录 A（源码推导，未演练）

1. 页首 `:::warning`：适用范围（测试/非生产、可接受全网格流量与遥测中断）+ 性质声明（本路径基于产品删除流程的行为分析，未做全流程演练验证）。
2. `:::danger`：仅适用于**尚未创建 v2 Istio CR** 的集群；v2 控制面已在 istio-system 的集群严禁走 UI 删除网格（回到并存灰度路径的手工下线序列）。
3. 步骤：P0 同款盘点备份（istio 原生资源 YAML 是恢复生命线）→ UI 移除全部微服务（去注入+滚动）→ **UI 删除全部网关**（必须在删网格之前——此时级联清理是确定性的；删网格后网关工作负载可能残留为孤儿）→ 复核外部服务绑定等自动生成资源已处置 → UI 删除网格（会删除 istio-system，本路径下属预期清场）→ 确认命名空间删除完成、无 Terminating 卡滞 → 卸载 v1 订阅残留 + global Essentials 插件 → 按安装文档全新安装 v2（operator → IstioCNI → Istio → Kiali → OTel v2/Jaeger v2，链接 installing/）→ 恢复 istio 原生资源备份（剥离 server 端字段与 asm 属主标注）→ ns 打 v2 注入标签 + 全量重启 → 网关按 v2 形态重建 → 终态验收同「完成迁移」页。

### 6.15 rollback.mdx —— 源：设计 §7、10.1 P4 修订（D-8.2）、附录 B

1. 回滚总则：v1 下线（不可回退点)之前皆可回滚；之后为灾难恢复级。
2. 分阶段回滚表：
   - 控制面并存后：删 v2 Istio/IstioCNI CR（Kiali 可保留）；
   - 工作负载切换中（单 ns / 整体）：rev 标签改回 + 滚动；若曾冻结控制器则恢复副本数；前提：v1 istiod/webhook 未动、MicroService CR 未删；
   - 网关切换后：**若网关 ns rev 已切 v2，旧网关不可扩容重建**（asm-gateway 模板已无效）——回滚 = ns rev 标签切回 + 删 v2 网关 pod，或修复 v2 网关；旧网关 Deployment 在下线阶段前始终保留；
   - v1 下线后：按备份重装 v1 清单（Essentials 插件包与 operator 包、ServiceMesh/ServiceMeshGroup CR、治理 CR、ns 标签快照、cacerts/根证书；恢复顺序 = 安装正序 + CR 回放 + 探测验证）。
3. 回滚触发判据：探测持续中断、mTLS 校验失败、任一验证断言失败且 30 分钟内无法定位。

### 6.16 troubleshooting.mdx —— 源：deviations 全量产品化 + memory 条目

「症状 / 原因 / 处理」条目（每条含定位命令）：
1. v2 istiod 长期 Pending（anti-affinity 消息）→ 单节点集群 v1 istiod 硬反亲和 → 链接控制面页条件步骤；
2. 对 ServiceMesh/治理 CR 的 patch 报 InternalError（webhook connection refused）→ 控制器已冻结但 failurePolicy=Fail 的 webhook 还在 → 先删对应 webhook 配置；严禁拉起控制器解锁；
3. asm CR 删除卡住、operator 反复报 proxies still pointing → pre-uninstall hook 按 sidecar 清点误判 → 摘 finalizer + 手工清理 helm release 资源；
4. default IstioRevisionTag ReconcileError（Helm ownership）→ 补 istio-reader-service-account 元数据；
5. 金丝雀网关 404 / listener 不绑定 → pod 标签缺 Gateway CR selector → 补并集标签；
6. v1 旧网关 pod 创建被拒（template "asm-gateway" not found）→ 网关 ns rev 已切 v2 的单向门 → 出路说明；
7. 网关 Service 意外消失（DNS 无解析、探测 exit 6）→ ownerReferences 级联 GC → 按备份应急重建 Service（endpoints 立即命中 v2 网关 pod）；
8. 切换后部分 EnvoyFilter 不生效 → `proxyVersion` 1.22 版本锁 → 评估以原生资源重建或随功能下线；
9. Java 应用无新 trace → 注解未显式补到 template / 镜像不可达 / 协议端口不匹配（http/protobuf↔4318）→ 逐项排查；
10. Kiali 无数据 → 数据源地址/凭据错误（用 Feature CR 权威获取方式核对）；多集群未用 VictoriaMetrics；
11. `istioctl proxy-status` 看不到任何 pod（"no running Istio pods"）→ RevisionBased 需带 `--revision <v2-revision>`。

FAQ：是否必须冻结 v1 控制器（不必，实测不调和 rev 标签；何时需要）；`cpaas.io/serviceMesh` 标签何时清（下线阶段统一清除，此前保留供回滚）；istio CRD 升级到 1.28 对 v1 的影响（向后兼容，实测无回归）；迁移窗口与遥测中断窗口预期；单副本服务的中断预期与规避。

## 7. 告警分级规范（全书统一）

| 级别 | 使用场景（穷举） |
|---|---|
| `:::danger` | ① UI 删除网格禁令（overview 预告 / 控制面页末生效 / 下线页首重申，三处措辞一致）② 单网络迁移中途设置 network/打网络标签禁令 ③ 停机路径「v2 已就位禁入」 |
| `:::warning` | 未演练性质声明（单网络页/切换页/停机页页首）、网关单向门、不可回退点、webhook 删除顺序、共存期禁建 default tag、遥测中断窗口、CA 有效期风险 |
| `:::note` / `:::tip` | native sidecar 形态、可选步骤说明、中断预期、镜像可达性提示 |
| `<Directive type="...">` | 以上任何告警出现在列表/`<Steps>` 缩进内时改用组件形式 |

## 8. MDX 与行文规范

- frontmatter 仅 `weight`；H1 即标题；目录 index 用 Overview 骨架。
- 步骤用 `<Steps>` + H3；代码关键字段用 `# [!code callout]` + `<Callouts>`；命令与期望输出分开成块（本次不加 `{name=}`）。
- 每阶段固定收尾 H2/H3「验证」小节：命令 + 期望输出。
- 内链：相对路径 + `.mdx` 后缀（+锚点）；跨站一律 `<ExternalSiteLink name="acp|distributed-tracing|opentelemetry">`；页尾按需 `## 相关文档`（对应现有 Additional resources 惯例）。
- 中文正文：术语/资源名/命令/组件名保留英文；中英文之间空格；标题动宾式；不出现 V-x/D-x/R-x 内部编号与内部链接。
- 占位符统一 `<angle-bracket-kebab>` 风格；凡环境特定值给「发现命令」。

## 9. 主要交叉链接

| 目标 | 用途 |
|---|---|
| installing/installing-service-mesh/install-mesh.mdx | v2 安装正典（停机路径、operator 安装细节） |
| installing/sidecar-injection/*（3 篇） | revision 识别、IstioRevisionTag 收编 |
| installing/multi-cluster/configuration-overview.mdx | openssl 证书/中间 CA 流程 |
| gateways/gateway-installation/installing-a-gateway-via-injection.mdx | 网关 RBAC 与形态 |
| integration/observability/kiali.mdx | openid 配置 |
| integration/observability/distributed-tracing/*（3 篇） | Jaeger v2 部署与既有迁移文档 |
| ExternalSiteLink → acp | Multus 插件、Marketplace 操作 |
| ExternalSiteLink → distributed-tracing | tracing 栈细节 |
| ExternalSiteLink → opentelemetry（**新增 sites.yaml 条目**） | Java Agent / OTel v1→v2 细节 |

## 10. 撰写与提交顺序（分篇 commit，禁止 amend）

1. 分区骨架：index.mdx + migration-overview.mdx（+ sites.yaml 条目）
2. preparing-for-migration.mdx
3. 单集群 5 篇（含目录 index，逐篇或按 2+2+2 分批提交）
4. 多集群 4 篇
5. migrating-observability.mdx
6. migrating-with-downtime.mdx
7. rollback.mdx
8. troubleshooting.mdx

每篇完成后的静态自检（本地无 yarn/构建环境）：MDX 语法与告警框闭合、frontmatter/weight、内链目标存在性、占位符一致性、10.1 修订融入核对、无内部编号泄漏（grep `V-\d|D-\d|R-\d|Confluence|192\.168\.|mesh-v1/`）。

## 11. 验收标准

1. 17 个 MDX 齐备、weight 正确、导航层级与本设计一致；`:::danger` 全书仅上述 3 类场景。
2. 10.1 全部实测修订可在对应页面找到对应步骤/告警（对照 §6 源指针逐项核对）。
3. 单网络/切换/停机 3 页页首均有性质声明；单网络页含拓扑判定回指、network 对齐硬约束、差异表、中性判据终态。
4. 全文 grep 无内部编号、内部链接、环境 IP、演练资源名残留。
5. 每阶段页有「验证」收尾小节；三处 UI 删网格红线措辞一致。
