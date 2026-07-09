# Mesh v1 → Mesh v2 迁移产品文档撰写实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `docs/en/migrating/` 落地 17 个 MDX（中文正文）+ sites.yaml 一处修改，交付「Mesh v1 迁移到 Mesh v2」客户操作文档。

**Architecture:** 顶层 migrating/ 分区（weight 75）+ 单集群/多集群两个二级目录；每篇 = 骨架（H2/H3）+ 产品化命令块 + 阶段收尾「验证」小节；内容取材自权威源材料并执行产品化红线（参数化、去内部编号、10.1 修订融入）。

**Tech Stack:** doom/MDX（frontmatter 仅 weight、`<Steps>`/`<Callouts>`/`<Directive>`/`<Overview>`、`:::` 告警指令）；静态自检用 bash/grep/awk（本地无 yarn/构建环境）。

## Global Constraints

**必读输入（每个任务动笔前）：**

1. 设计 spec：`docs/en/development/specs/2026-07-09-meshv1-to-v2-migration-docs-design.md`（本计划的权威需求；各任务标注的 spec §6.x 为该篇内容要点与源材料指针）。
2. 源材料（按 spec §2 的引用规则使用）：
   - `/home/vscode/repo/my-tasks/task-meshv1-migration-design/Mesh v1 迁移到 Mesh v2 设计方案.md`（**10.1 优先于正文；8.1 为未实机演练的设计推演**）
   - 同目录 `验证总结报告.md`、`evidence/single/deviations.md`、`evidence/multi/deviations.md`
3. 范本与惯例参考：`docs/en/integration/observability/distributed-tracing/migrating-to-jaeger-v2.mdx`（口吻）、`/home/vscode/repo/opentelemetry-docs/docs/en/migrating/migrating-to-v2.mdx`（完整结构）、`docs/en/installing/installing-service-mesh/install-mesh.mdx`（组件用法）。

**产品化红线（每篇生效，违者任务不得通过自检）：**

- 读者为客户平台管理员/SRE；隐去全部内部演练叙事与环境事实（IP、演练资源名按占位符/通用示例处理）。
- 环境特定值一律占位符或「发现命令」；不出现 V-x/D-x/R-x/Confluence/源码路径。
- 版本适用性：ACP v4.3.x · Mesh v1 (ASM) v4.3.5 / istio 1.22.x · Mesh v2 (servicemesh-operator2) v2.1.x / istio 1.28.x（仅 overview 页首声明）。
- 中文行文：术语/资源名/命令保留英文，中英文间空格；本次**不加** `{name=}` 代码块属性。
- frontmatter 仅 `weight`；目录 index 用「H1 + 一句话 + `<Overview overviewHeaders={[]} />`」骨架；步骤用 `<Steps>` + H3；列表内告警用 `<Directive type="...">`。

**全书统一阶段术语**（overview 定义后各页直接使用）：P0 迁移准备 · P1 准备可观测性 · P2 并存安装 v2 控制面 · P3 迁移工作负载 · P4 迁移网关 · P5 下线 Mesh v1 · P6 完成迁移。

**全书占位符表**（overview「约定」小节定义，各页一致使用）：

| 占位符 | 含义 | 发现命令（正文按需给出） |
|---|---|---|
| `<cluster-name>` | 业务集群名 | — |
| `<v2-revision>` | v2 活动修订名（示例 `default-v1-28-6`） | `kubectl get istiorevisions.sailoperator.io` |
| `<mesh-namespace>` | 参与网格的业务命名空间 | `kubectl get ns -l istio.io/rev=1-22` |
| `<gateway-namespace>` / `<gateway-name>` | 网关所在 ns / 网关名 | `kubectl get gatewaydeploys.asm.alauda.io -A` |
| `<control-plane-iop>` | v1 控制面 IstioOperator CR 名 | `kubectl -n istio-system get istiooperators.install.istio.io` |
| `<global-kubeconfig>` | global 集群访问配置 | — |
| `<network-1>` / `<network-2>` | 多网络模式下两集群 network 名 | 见拓扑判定采集命令 |

**统一告警文案**（下列文案为定稿措辞，任务中逐字使用；核心句加粗部分三处必须一致）：

- 【danger-A：UI 删网格红线】用于 overview（预告）、installing-the-v2-control-plane.mdx 页末（生效）、decommissioning-mesh-v1.mdx 页首（重申）：

  ```
  :::danger 严禁通过平台 UI 删除 Mesh v1 网格
  **v2 `Istio` CR 创建后，严禁通过平台 UI 删除 Mesh v1 网格，或删除 `ServiceMesh` CR 后等待控制器处理。** Mesh v1 的删除流程会删除整个 istio-system 命名空间，v2 控制面与网格配置将随之一并被摧毁。Mesh v1 的下线必须按照 [下线 Mesh v1](<相对路径>/decommissioning-mesh-v1.mdx) 的手工序列执行。
  :::
  ```

  （三处仅链接相对路径与前后过渡句可不同；P5 页首版本将链接句改为「必须按照本文手工序列执行」。）

- 【danger-B：单网络拓扑禁令】仅用于 migrating-a-single-network-mesh.mdx：

  ```
  :::danger 严禁在迁移过程中变更网络拓扑配置
  迁移全程，v2 的 network 相关配置必须逐字段对齐 v1 实测值。**严禁在迁移中途为 istio-system 命名空间添加 `topology.istio.io/network` 标签，或为 v2 单独设置 `values.global.network`。**否则两个控制面将对「端点属于哪个网络」产生认知分裂：v2 会把远端端点改写为尚未就位的东西向网关地址，造成跨集群路由黑洞。切换到多网络拓扑只能在迁移完成后作为独立变更进行，见 [切换到多网络拓扑](./switching-to-multi-network.mdx)。
  :::
  ```

- 【danger-C：停机路径禁入条件】仅用于 migrating-with-downtime.mdx：

  ```
  :::danger 仅适用于尚未安装 v2 控制面的集群
  本路径仅适用于**尚未创建 v2 `Istio` CR** 的集群。如果 istio-system 中已存在 v2 控制面，严禁通过 UI 删除网格（删除流程会删除整个 istio-system 命名空间），必须改用并存灰度路径的 [下线 Mesh v1](./migrating-a-single-cluster-mesh/decommissioning-mesh-v1.mdx) 手工序列。
  :::
  ```

- 【warning-D：未演练性质声明】用于 migrating-a-single-network-mesh.mdx 与 switching-to-multi-network.mdx 页首（第二页把首句换为括注句）：

  ```
  :::warning 本文步骤未经端到端实机演练
  本文步骤基于已完整实测验证的多网络迁移基线推演适配（切换页首句改为：本文所述为迁移完成后的独立变更操作，基于多网络部署的标准做法整理）。执行前，应先在与生产同形态的测试环境中完整演练一轮并确认结果符合预期。
  :::
  ```

- 【warning-E：停机路径适用范围】仅用于 migrating-with-downtime.mdx 页首：

  ```
  :::warning 适用范围与验证状态
  本路径仅适用于测试或非生产环境，前提是可接受整段网格流量与遥测中断。本路径基于产品删除流程的行为分析整理，未经全流程演练验证。生产环境请使用并存灰度迁移路径。
  :::
  ```

**每篇通用自检（shared self-check）**——每个任务的自检步骤运行以下脚本（`F` 换成当篇文件），全部达标才允许 commit：

```bash
F=docs/en/migrating/<file>.mdx
# 1) 内部信息泄漏扫描 —— 期望：无输出
grep -nE 'V-[0-9]+|D-M?[0-9]+|R-[0-9]+|[Cc]onfluence|pageId|192\.168\.|my-tasks|mesh-v1/|global-asm-controller/pkg' "$F"
# 2) frontmatter —— 期望：仅 ---/weight: N/--- 三行
head -3 "$F"
# 3) 告警 fence 配对 —— 期望：OK
awk '/^[[:space:]]*:::/{c++} END{print (c%2==0) ? "OK" : "UNBALANCED"}' "$F"
# 4) 相对内链存在性 —— 期望：无 MISSING
grep -oE '\]\(\.[^)#]*\.mdx' "$F" | sed 's/](//' | while read -r p; do [ -f "$(dirname "$F")/$p" ] || echo "MISSING: $p"; done
# 5) 中英文空格抽检（数字/字母紧贴汉字）—— 期望：输出为空或逐条人工确认为误报（如「v2 的」为正确）
grep -nP '[\x{4e00}-\x{9fff}][A-Za-z0-9]|[A-Za-z0-9][\x{4e00}-\x{9fff}]' "$F" | head -20
```

> 注：检查 4 只覆盖当篇指向已存在文件的链接；指向**后续任务**文件的链接允许暂时 MISSING，但必须记录在 Task 14 终检清单中复核（本计划各任务已按依赖排序，正常不会出现）。前向链接一律使用本计划 §File Structure 中的最终文件名。

**提交规范：** 每任务一个独立 commit（禁止 amend）；message 见各任务；结尾统一加 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。

## File Structure（最终态，任务中链接一律以此为准）

```
docs/en/migrating/
├── index.mdx                                    w:75
├── migration-overview.mdx                       w:10
├── preparing-for-migration.mdx                  w:20
├── migrating-a-single-cluster-mesh/
│   ├── index.mdx                                w:30
│   ├── installing-the-v2-control-plane.mdx      w:10
│   ├── migrating-workloads.mdx                  w:20
│   ├── migrating-gateways.mdx                   w:30
│   ├── decommissioning-mesh-v1.mdx              w:40
│   └── finalizing-the-migration.mdx             w:50
├── migrating-a-multi-cluster-mesh/
│   ├── index.mdx                                w:40
│   ├── migrating-a-multi-network-mesh.mdx       w:10
│   ├── migrating-a-single-network-mesh.mdx      w:20
│   └── switching-to-multi-network.mdx           w:30
├── migrating-observability.mdx                  w:50
├── migrating-with-downtime.mdx                  w:60
├── rollback.mdx                                 w:70
└── troubleshooting.mdx                          w:80
sites.yaml                                        （追加 opentelemetry 条目）
```

---

### Task 1: 分区骨架 + 迁移概览 + sites.yaml

**Files:**
- Modify: `sites.yaml`
- Create: `docs/en/migrating/index.mdx`
- Create: `docs/en/migrating/migration-overview.mdx`

**Interfaces:**
- Produces: migrating/ 分区目录；占位符表与 P0–P6 阶段术语的正文定义（overview「约定」小节）；danger-A 首处（预告版）。后续所有页面依赖这两个约定，不得另造术语。

- [ ] **Step 1: 读输入** —— spec §6.1、设计方案 §1–§5 与 §4 功能映射表、`migrating-to-v2.mdx`（otel）的 Overview 章组织方式。
- [ ] **Step 2: 修改 sites.yaml** —— 查看现有两条目的字段结构（name/base/version），追加 `opentelemetry` 条目；base/version 从 `/home/vscode/repo/opentelemetry-docs` 的发布配置推断（查其 `doom.config.yaml`、`package.json`、release-notes 中的当前版本号；如无法确证，base 取 `/opentelemetry`、version 取其 release-notes 最新版本，并在 commit message 注明待发布侧核对）。
- [ ] **Step 3: 写 index.mdx**（完整内容）：

  ```mdx
  ---
  weight: 75
  ---

  # 从 Mesh v1 迁移到 Mesh v2

  本章介绍如何将 Alauda Service Mesh v1 (ASM) 在线迁移到 Alauda Service Mesh v2，包括单集群与多集群场景、可观测栈迁移、回滚指引与故障排查。

  <Overview overviewHeaders={[]} />
  ```

- [ ] **Step 4: 写 migration-overview.mdx** —— frontmatter `weight: 10`，H1「迁移概览」，H2 骨架与要点按 spec §6.1 的 9 条逐一落实：版本适用性 `:::info` 表 → 为什么迁移 → 架构对比表 → 功能对照与替代方案（含 istio 官方 ratelimit / Classifying Metrics 外链、Argo Rollouts 指引、`ASM_MS_NAME` 感知项）→ 迁移策略选择（并存灰度 vs [停机卸载重装迁移](./migrating-with-downtime.mdx)）→ 迁移路线图（P0–P6 定义表 + 回滚点标注 + 各阶段页链接）→ 并存为什么是安全的（四点，剥离编号）→ 【danger-A 预告版】→ 约定（占位符表 + 发现命令模式说明）。
- [ ] **Step 5: 自检** —— 对两个新文件运行 shared self-check；额外核对：danger-A 文案与全局约束逐字一致（链接指向 `./migrating-a-single-cluster-mesh/decommissioning-mesh-v1.mdx`，本任务时点该文件未创建，记录到 Task 14 复核项）。
- [ ] **Step 6: Commit** —— `docs: add migrating section skeleton and migration overview`

### Task 2: 迁移准备与前置检查（P0）

**Files:**
- Create: `docs/en/migrating/preparing-for-migration.mdx`（weight 20，H1「迁移准备与前置检查」）

**Interfaces:**
- Consumes: overview 的占位符与阶段术语。
- Produces: 「盘点与备份」小节锚点（P5/回滚页引用其备份清单）。

- [ ] **Step 1: 读输入** —— spec §6.2、设计方案 §6 P0、10.1 中 D-1/D-4/D-5/D-6/D-9/D-11 的前置化要点。
- [ ] **Step 2: 写页面** —— H2 骨架：前置条件 / 兼容性与风险检查 / 资源盘点与备份 / 变更冻结 / 业务探测器 / 验证。关键命令块（产品化定稿，直接使用）：

  ```bash
  # ServiceEntry 1.28 兼容性审计（期望无输出；有输出的条目需先修复）
  kubectl get serviceentries -A -o json | jq -r '.items[] | select((.spec.ports | not) or ((.spec.hosts | length) > 256)) | "\(.metadata.namespace)/\(.metadata.name)"'

  # EnvoyFilter 版本锁审计（列出带 proxyVersion 匹配的过滤器，评估 1.28 下是否失效）
  kubectl get envoyfilters -A -o json | jq -r '.items[] | select([.. | objects | has("proxyVersion")] | any) | "\(.metadata.namespace)/\(.metadata.name)"'

  # 中间 CA 剩余有效期（必须晚于计划迁移窗口结束时间）
  kubectl -n istio-system get secret cacerts -o jsonpath='{.data.ca-cert\.pem}' | base64 -d | openssl x509 -noout -enddate
  ```

  盘点/备份命令组按设计 P0.1/P0.2 产品化（资源类别齐全：ns 标签、MicroService、IstioOperator、GatewayDeploy/IngressGateway、istio 原生资源、asm.alauda.io 全部 CRD 实例、OTel/Jaeger、Subscription/CSV、global 侧 CR 与根证书、cacerts、remote secret）；**网关 Service 单独备份**给独立命令与 `:::warning`（CA 有效期与 Service 备份属 warning 级）。副本数 ≥2+PDB、`ASM_MS_NAME` 排查、「带 rev 标签无 sidecar 的 ns」甄别命令（`kubectl get ns -l istio.io/rev=1-22` 与逐 ns `kubectl get pod -o jsonpath` 容器数比对）逐项落实。
- [ ] **Step 3: 自检** —— shared self-check；核对 spec §6.2 的 6 个 H2 全部在场。
- [ ] **Step 4: Commit** —— `docs: add migration preparation and precheck guide`

### Task 3: 单集群目录 + 安装 v2 控制面（P1+P2）

**Files:**
- Create: `docs/en/migrating/migrating-a-single-cluster-mesh/index.mdx`（weight 30，H1「单集群网格迁移」：一句话 + P1→P6 流程列表〔每项一句话+页链接+回滚点标注〕+ `<Overview overviewHeaders={[]} />`）
- Create: `docs/en/migrating/migrating-a-single-cluster-mesh/installing-the-v2-control-plane.mdx`（weight 10，H1「安装 v2 控制面（并存部署）」）

**Interfaces:**
- Consumes: 占位符表；kiali.mdx / identifying-the-revision-name.mdx 链接目标。
- Produces: danger-A 第二处（生效版，页末）；`<v2-revision>` 获取小节（后续页引用）。

- [ ] **Step 1: 读输入** —— spec §6.4、设计 §6 P1/P2、10.1 P2 修订（D-4）、D-3/D-M1 闭环（Feature CR 数据源）、`install-mesh.mdx` 与 `kiali.mdx` 现有写法。
- [ ] **Step 2: 写页面** —— 两个 H2（准备可观测性 / 安装 v2 控制面），各含 `<Steps>`。必含代码块（产品化定稿）：

  Kiali 数据源发现（P1）：

  ```bash
  kubectl get feature monitoring -o jsonpath='{.spec.accessInfo.database.address}'
  kubectl get feature monitoring -o jsonpath='{.spec.accessInfo.database.basicAuth.secretName}'
  ```

  单节点条件步骤（P2，`<Steps>` 内用 `<Directive type="warning">` 说明适用条件与「v1 istiod 将滚动一次、数据面无扰动」）：

  ```bash
  kubectl -n istio-system patch istiooperator <control-plane-iop> --type=json -p='[
    {"op":"replace","path":"/spec/components/pilot/k8s/affinity","value":{"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":100,"podAffinityTerm":{"labelSelector":{"matchExpressions":[{"key":"istio","operator":"In","values":["istiod"]}]},"topologyKey":"kubernetes.io/hostname"}}]}},
    {"op":"add","path":"/spec/components/pilot/k8s/strategy","value":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}
  ]'
  ```

  （callout 标注：必须 JSON-patch replace，merge 会保留原 required 反亲和。）

  IstioCNI 与 Istio CR YAML：以设计 P2 的两个 YAML 为基础做占位符化（meshID 值改为「发现命令读取」：`kubectl -n istio-system get cm istio-1-22 -o jsonpath='{.data.mesh}'`，callout 指到 meshID/extensionProviders/inactiveRevisionDeletionGracePeriodSeconds 三处）；`:::warning` 共存期禁建 default `IstioRevisionTag`；Telemetry CR；revision 获取（`kubectl get istiorevisions.sailoperator.io`，链接 `../../installing/sidecar-injection/identifying-the-revision-name.mdx`）。
  验证小节：istiod Ready、cacerts 同源证据（`kubectl -n istio-system logs deploy/istiod-<v2-revision> | grep -i "root cert"` 期望含 `Use root cert from etc/cacerts`）、`kubectl get istiorevisions` 输出、业务探测无变化。页末【danger-A 生效版】（链接 `./decommissioning-mesh-v1.mdx`）。
- [ ] **Step 3: 自检** —— shared self-check ×2 文件；danger-A 核心句与 Task 1 逐字 diff（`grep -F '严禁通过平台 UI 删除 Mesh v1 网格' -A2`）。
- [ ] **Step 4: Commit** —— `docs: add single-cluster index and v2 control plane installation guide`

### Task 4: 迁移工作负载（P3）

**Files:**
- Create: `docs/en/migrating/migrating-a-single-cluster-mesh/migrating-workloads.mdx`（weight 20，H1「迁移工作负载」）

**Interfaces:**
- Consumes: `<v2-revision>`；Task 3 页面链接。
- Produces: 「跨控制面互通验证」小节（多集群页引用同款验证思路）。

- [ ] **Step 1: 读输入** —— spec §6.5、设计 §6 P3、10.1 P3 修订（V-6 冻结可选、V-7 native sidecar、D-5/D-6）。
- [ ] **Step 2: 写页面** —— 骨架：原理（rev 精确匹配 + 实测 v1 控制器不调和标签）→ 可选小节「冻结 v1 控制器」（适用场景 + 三件套 scale 命令 + 恢复命令）→ `<Steps>` 逐 ns 切换：

  ```bash
  kubectl label ns <mesh-namespace> istio.io/rev=<v2-revision> --overwrite
  kubectl -n <mesh-namespace> rollout restart deploy
  kubectl -n <mesh-namespace> rollout status deploy --timeout=300s
  istioctl proxy-status --revision <v2-revision> -n <mesh-namespace>
  ```

  （期望输出块：ISTIOD 列为 `istiod-<v2-revision>-*`；`:::note` RevisionBased 下 istioctl 必须带 `--revision`。）
  `:::note` native sidecar 形态；`cpaas.io/serviceMesh` 标签保留说明；跨控制面互通验证（互调 + `istioctl proxy-config secret <pod> -n <ns> -o json` 查 ROOTCA subject 含 `ASM Istio Root CA`）；中断预期（副本≥2+PDB 零中断/单副本秒级）；纯 OTel ns 不动（链接 `../migrating-observability.mdx`）；验证小节。
- [ ] **Step 3: 自检** —— shared self-check。
- [ ] **Step 4: Commit** —— `docs: add workload migration guide`

### Task 5: 迁移网关（P4）

**Files:**
- Create: `docs/en/migrating/migrating-a-single-cluster-mesh/migrating-gateways.mdx`（weight 30，H1「迁移网关」）

**Interfaces:**
- Consumes: `<gateway-namespace>`/`<gateway-name>` 占位符；`installing-a-gateway-via-injection.mdx` 链接。
- Produces: 「单向门」warning（rollback 页引用同一结论）。

- [ ] **Step 1: 读输入** —— spec §6.6、设计 §6 P4、10.1 P4 修订（D-8 三教训）、V-9/V-10。
- [ ] **Step 2: 写页面** —— 骨架：顺序总则（**先切网关 ns rev，再部署 v2 网关**，说明为什么安全）→ `:::warning` 单向门（v1 网关自此不可重建、切换前必须完成 v2 就绪验证、回滚方式改变——链接 `../rollback.mdx`）→ `<Steps>`：前置采集（两条 selector 发现命令）：

  ```bash
  kubectl -n <gateway-namespace> get svc <gateway-name> -o jsonpath='{.spec.selector}'
  kubectl -n <gateway-namespace> get gateways.networking.istio.io -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.selector}{"\n"}{end}'
  ```

  → 切网关 ns rev 标签 → 部署 v2 金丝雀网关（完整 Deployment YAML：`inject.istio.io/templates: gateway` 注解、`image: auto`、labels 含**两个 selector 的并集** + `istio.io/rev: <v2-revision>` + 金丝雀区分标签；callout 指到并集标签与注入注解；ServiceAccount/RBAC 链接 `../../gateways/gateway-installation/installing-a-gateway-via-injection.mdx`）→ 就绪验证（`istioctl proxy-config listeners` 绑定 + 实际请求打通）→ 金丝雀切流（v2 扩容/旧网关分步缩容至 0 并保留）→ egress 与默认网关处置 → 自动生成资源打 `asm.cpaas.io/user-managed: "true"` 注解命令 → 验证小节（100% 流量 + 探测 0 中断 + Gateway/VS 未变更）。
- [ ] **Step 3: 自检** —— shared self-check；核对 Deployment YAML 的 labels 注释明确「并集」语义。
- [ ] **Step 4: Commit** —— `docs: add gateway migration guide`

### Task 6: 下线 Mesh v1（P5）

**Files:**
- Create: `docs/en/migrating/migrating-a-single-cluster-mesh/decommissioning-mesh-v1.mdx`（weight 40，H1「下线 Mesh v1」）

**Interfaces:**
- Consumes: preparing 页备份小节；Task 1/3 的 danger-A 链接目标即本页。
- Produces: 手工下线序列（downtime 页 danger-C、多网络页 P5+ 均链接本页）。

- [ ] **Step 1: 读输入** —— spec §6.7、10.1 P5 序列重写全文（含 D-9/D-10/D-11/D-12）、验证报告 V-11/V-12 行。
- [ ] **Step 2: 写页面** —— 页首【danger-A 重申版】→ H2 Go/No-Go 检查单（复选列表 + 例外清单说明）→ `:::warning` 不可回退点（链接 `../rollback.mdx`）→ H2 手工下线序列 `<Steps>` 八步（每步：目的一句话 + 命令块 + 该步验证命令与期望输出）。命令产品化要点（按 spec §6.7 第 4 条逐步落实，全部给出实际命令）：
  - 步 2（global）删 webhook 三件套（逐名列出）→ `kubectl -n cpaas-system scale deploy global-asm-controller --replicas=0` 并 get 确认 → `kubectl -n cpaas-system delete servicemesh <cluster-name> --wait=false` → finalizer patch → 断言（`get servicemesh` NotFound 且 `get ns istio-system` 存在）；`<Directive type="warning">` 顺序不可颠倒 + 严禁复活控制器；
  - 步 4（业务集群）webhook 发现命令（`kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations | grep -Ei 'asm|gatewaydeploy|microservice'`）→ 逐个删除 → 冻结 asm-controller → 摘 ownerReferences 的 patch 命令 + **`kubectl -n <gateway-namespace> get svc <gateway-name> -o jsonpath='{.metadata.ownerReferences}'` 期望输出为空** → 删治理 CR 循环 + finalizer patch 模板 → 立即 `get svc` 断言在位；
  - 步 5 asm CR：`kubectl delete asms.operator.alauda.io asm --wait=false` → 说明 hook 误判机理（一句话，不出现内部编号）→ finalizer patch → 残留清理指引（helm release manifest 定位命令 `kubectl -n cpaas-system get secret -l owner=helm,name=asm`）；
  - 步 6/7/8 订阅与 CSV 删除（发现式命令，不硬编码环境订阅名）、网关 IOP → 控制面 IOP → operator 本体、残留清理（default 位 webhook 两条、`kubectl label ns <mesh-namespace> cpaas.io/serviceMesh-`、asm CRD 删除；`:::note` istio CRD 保留）。
  → H2 验证（终局断言四条命令+期望）→ 结尾多集群提示框（链接 `../migrating-a-multi-cluster-mesh/index.mdx`）。
- [ ] **Step 3: 自检** —— shared self-check；额外：`grep -c ':::danger' F` 期望 1（仅页首）；八步每步都有验证命令。
- [ ] **Step 4: Commit** —— `docs: add mesh v1 decommissioning guide`

### Task 7: 完成迁移（P6）

**Files:**
- Create: `docs/en/migrating/migrating-a-single-cluster-mesh/finalizing-the-migration.mdx`（weight 50，H1「完成迁移（收编与 CA 交接）」）

**Interfaces:**
- Consumes: sidecar-injection-with-istiorevisiontag.mdx、multi-cluster/configuration-overview.mdx 证书章节、migrating-observability.mdx 链接。
- Produces: 终态验收清单（downtime 页复用其标准）。

- [ ] **Step 1: 读输入** —— spec §6.8、设计 §6 P6、10.1 P6 修订（D-13、V-13）。
- [ ] **Step 2: 写页面** —— H2 default 收编（前置 Helm 元数据两条命令：`kubectl -n istio-system label sa istio-reader-service-account app.kubernetes.io/managed-by=Helm` 与 `kubectl -n istio-system annotate sa istio-reader-service-account meta.helm.sh/release-name=default-base meta.helm.sh/release-namespace=sail-operator`；IstioRevisionTag YAML；可选回归 `istio-injection=enabled` 流程链接）→ H2 CA 生命周期交接（背景一段 + `<Steps>`：导出根〔global `asm-istio-rootca`，root key 离线保管 warning〕→ openssl 签发长期中间 CA〔链接 `../../installing/multi-cluster/configuration-overview.mdx` 流程，给 cacerts 四件套重建 `kubectl create secret generic cacerts --from-file=...` 模板〕→ 热加载验证：istiod 日志 `Update Istiod cacerts`、新 pod issuer、`:::note` 存量 90 秒未轮换属正常〔24h TTL〕、滚动单个 deploy 验证新链）→ H2 可观测终态（链接 `../migrating-observability.mdx` + 时序说明）→ H2 终态验收（`kubectl get istio,istiocni,istiorevisiontag` 全 Healthy 等四条 + 收尾动作）。
- [ ] **Step 3: 自检** —— shared self-check。
- [ ] **Step 4: Commit** —— `docs: add migration finalization guide`

### Task 8: 多集群目录（拓扑判定）+ 多网络路径

**Files:**
- Create: `docs/en/migrating/migrating-a-multi-cluster-mesh/index.mdx`（weight 40，H1「多集群网格迁移」）
- Create: `docs/en/migrating/migrating-a-multi-cluster-mesh/migrating-a-multi-network-mesh.mdx`（weight 10，H1「迁移多网络多集群网格」）

**Interfaces:**
- Produces: 拓扑判定小节（单网络页回指）；东西向网关部署小节（switching 页复用做法）。

- [ ] **Step 1: 读输入** —— spec §6.9/§6.10、设计 §8（含 P0+~P6+）、8.1 判定特征、D-M1/D-M2。
- [ ] **Step 2: 写 index.mdx** —— 一句话 + H2「判定网络拓扑」（采集命令：两集群 `kubectl -n istio-system get cm istio-1-22 -o jsonpath='{.data.mesh}'`、东西向网关标签 `kubectl -n istio-system get svc istio-eastwestgateway -o jsonpath='{.metadata.labels.topology\.istio\.io/network}'`、跨集群 pod IP 直连检查〔在 A 集群 pod exec curl B 集群 pod IP〕+ 判定表）+ `<Overview overviewHeaders={[]} />`。
- [ ] **Step 3: 写 multi-network.mdx** —— 开篇（已实测声明 + 叠加点总览表）→ 按 P0+/P2+/P2.5/P3+/P5+/P6+ 组 H2，按 spec §6.10 逐条落实；关键命令块：Istio CR 多集群字段（meshID/network/clusterName callout）、`istioctl remote-clusters` 期望输出、v2 eastwest gateway Deployment 要点（`topology.istio.io/network` 标签 + 15443 AUTO_PASSTHROUGH Gateway YAML）、**P5+ 摘归属标签命令**：

  ```bash
  kubectl -n istio-system label svc istio-eastwestgateway install.operator.istio.io/owning-resource- operator.istio.io/managed-
  ```

  → Kiali 多集群（VictoriaMetrics 必须 + query_scope + multi-cluster secret）→ 验证小节（三态矩阵 + remote-clusters synced + CA 轮换后跨集群 mTLS）。
- [ ] **Step 4: 自检** —— shared self-check ×2。
- [ ] **Step 5: Commit** —— `docs: add multi-cluster index and multi-network migration guide`

### Task 9: 单网络路径 + 单转多切换

**Files:**
- Create: `docs/en/migrating/migrating-a-multi-cluster-mesh/migrating-a-single-network-mesh.mdx`（weight 20，H1「迁移单网络多集群网格」）
- Create: `docs/en/migrating/migrating-a-multi-cluster-mesh/switching-to-multi-network.mdx`（weight 30，H1「切换到多网络拓扑」）

**Interfaces:**
- Consumes: index 判定节、multi-network 页各小节（差异表逐行对应）。

- [ ] **Step 1: 读输入** —— spec §6.11/§6.12、设计 §8.1 全文（**注意：推演性质贯穿两页**）。
- [ ] **Step 2: 写 single-network.mdx** —— 页首【warning-D】→ 适用判定（回指 `./index.mdx#判定网络拓扑` 锚，实际锚名以 index 成文为准）→ 【danger-B】+ 原理段（共享配置点/一次只做一个高风险变更）→ H2 与多网络路径的差异（表格：P0+/P2+/P2.5/P3+/P5+ 五行，含「P2.5 整步跳过」「南北向网关 Service 保护照旧」）→ 单网络专属验证（`istioctl proxy-config endpoints <pod> -n <ns> | grep <peer-svc>` 期望远端为对端 pod IP 而非网关地址）→ H2 迁移完成后的拓扑选择（中性判据两条 + 保持单网络须联系支持确认支持口径）→ `:::note` 不要反向操作。
- [ ] **Step 3: 写 switching-to-multi-network.mdx** —— 页首【warning-D 切换页变体】→ 前提 → `<Steps>`：部署东西向网关（引用 multi-network 页做法 + 跨集群可达预检）→ 设 network（两集群 Istio CR patch + istio-system ns 标签 + 网关 pod 标签）→ 滚动业务工作负载 → 验证（矩阵 + endpoints 已为网关地址 + mTLS 不变说明）→ H2 回滚（撤配置回直连）。
- [ ] **Step 4: 自检** —— shared self-check ×2；额外：两页 warning-D 首句差异符合全局约束定义；danger-B 仅出现在 single-network 页。
- [ ] **Step 5: Commit** —— `docs: add single-network migration and multi-network switching guides`

### Task 10: 迁移可观测栈

**Files:**
- Create: `docs/en/migrating/migrating-observability.mdx`（weight 50，H1「迁移可观测栈」）

**Interfaces:**
- Consumes: sites.yaml 的 opentelemetry/distributed-tracing 条目（ExternalSiteLink）；finalizing 页时序衔接。

- [ ] **Step 1: 读输入** —— spec §6.13、设计 §6 P6.3、10.1 P6 修订（D-14 及补记、D-3/D-M1 闭环）、附录 C；范本 `migrating-to-jaeger-v2.mdx` 与 otel `migrating-to-v2.mdx` 的对应段落（避免重复其内容，差异化引用）。
- [ ] **Step 2: 写页面** —— 时序说明 + `:::warning` 遥测中断窗口 → H2 部署 v2 tracing 栈（ExternalSiteLink 引用 + 本迁移特有：索引前缀规划、多集群分集群）→ H2 翻转 Istio tracing 出口（Istio CR merge-patch extensionProviders 指向 `otel-collector.jaeger-system.svc.cluster.local:4318` 或 4317 按 provider 类型、discoverySelectors 注意）→ H2 迁移 Java Agent 注入（`:::warning` 注解显式化背景；deployment template 注解补丁 YAML：`instrumentation.opentelemetry.io/inject-java: "true"` + `instrumentation.opentelemetry.io/container-names`；Instrumentation CR 完整 YAML：`spec.java.image: registry.alauda.cn:60070/asm/opentelemetry-operator/autoinstrumentation-java:2.26.1`、`OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`、endpoint `http://otel-collector.jaeger-system:4318`；`:::note` 镜像可达性；滚动 + 验证 `telemetry.distro.version=2.26.1`；ExternalSiteLink → opentelemetry 迁移文档）→ H2 翻转 Kiali tracing 数据源（16685/gRPC）→ H2 历史调用链数据 → 验证小节。
- [ ] **Step 3: 自检** —— shared self-check；镜像地址逐字核对（`2.26.1`）。
- [ ] **Step 4: Commit** —— `docs: add observability stack migration guide`

### Task 11: 停机卸载重装迁移

**Files:**
- Create: `docs/en/migrating/migrating-with-downtime.mdx`（weight 60，H1「停机卸载重装迁移」）

**Interfaces:**
- Consumes: install-mesh.mdx、decommissioning 页（danger-C 链接）、finalizing 页验收标准。

- [ ] **Step 1: 读输入** —— spec §6.14、设计附录 A（**源码推导、未演练——正文表述为「基于产品删除流程的行为分析」**）。
- [ ] **Step 2: 写页面** —— 页首【warning-E】+【danger-C】→ H2 路径说明（何时选它 + 与并存灰度对比一行表）→ `<Steps>` 十步（按 spec §6.14 第 3 条顺序；「UI 删除全部网关必须在删除网格之前」用 `<Directive type="warning">` 说明孤儿残留机理一句话）→ 恢复阶段（安装链接 `../installing/installing-service-mesh/install-mesh.mdx`、原生资源备份恢复要点：剥离 status/resourceVersion 等 server 端字段与 asm 属主标注）→ 验收（链接 finalizing 页验收清单）。
- [ ] **Step 3: 自检** —— shared self-check；danger-C 与 warning-E 逐字核对。
- [ ] **Step 4: Commit** —— `docs: add downtime reinstall migration path`

### Task 12: 回滚指引

**Files:**
- Create: `docs/en/migrating/rollback.mdx`（weight 70，H1「回滚指引」）

- [ ] **Step 1: 读输入** —— spec §6.15、设计 §7、10.1 P4 修订（单向门对回滚的影响）、附录 B。
- [ ] **Step 2: 写页面** —— 回滚总则（不可回退点前/后）→ H2 分阶段回滚（表格 + 每行给命令要点；**P4 行必须体现**：网关 ns rev 已切 v2 时旧网关不可扩容，回滚 = ns rev 回切 + 删 v2 网关 pod，或修复 v2 网关）→ H2 v1 下线后的恢复（灾难恢复清单式：所需备份物料清单 + 恢复顺序 + 恢复后验证）→ H2 回滚触发判据。
- [ ] **Step 3: 自检** —— shared self-check；与 Task 5 单向门表述一致性（同一结论、无矛盾）。
- [ ] **Step 4: Commit** —— `docs: add rollback guide`

### Task 13: 故障排查与常见问题

**Files:**
- Create: `docs/en/migrating/troubleshooting.mdx`（weight 80，H1「故障排查与常见问题」）

- [ ] **Step 1: 读输入** —— spec §6.16（11 条症状/原因/处理 + 4 条 FAQ 的完整清单）、两份 deviations 原文（改写素材）。
- [ ] **Step 2: 写页面** —— H2 故障排查：11 个 H3（每个含「症状」「原因」「处理」三段 + 定位命令；处理段链接对应正文页），逐条对照 spec §6.16 编号 1–11，不得缺项 → H2 常见问题：4 个 FAQ（冻结控制器、`cpaas.io/serviceMesh` 标签、CRD 升级影响、中断窗口预期）。
- [ ] **Step 3: 自检** —— shared self-check；条目计数 `grep -c '^### ' F` ≥ 15。
- [ ] **Step 4: Commit** —— `docs: add migration troubleshooting and FAQ`

### Task 14: 全书终检

**Files:**
- Modify: 前 13 个任务产出中发现问题的任意文件（预期少量措辞/链接修正）

- [ ] **Step 1: 结构核对** —— `find docs/en/migrating -name '*.mdx' | wc -l` 期望 17；逐文件 `head -3` 核对 weight 与 File Structure 表一致。
- [ ] **Step 2: 全书泄漏扫描** —— 对整个目录运行 shared self-check 第 1 项：`grep -rnE 'V-[0-9]+|D-M?[0-9]+|R-[0-9]+|[Cc]onfluence|pageId|192\.168\.|my-tasks|mesh-v1/' docs/en/migrating/` 期望无输出。
- [ ] **Step 3: danger 穷举核对** —— `grep -rn ':::danger' docs/en/migrating/` 期望恰好 5 处（overview、installing-the-v2-control-plane、decommissioning、single-network、downtime），且 danger-A 三处核心句逐字一致（提取比对）。
- [ ] **Step 4: 内链全量校验** —— 对 17 文件运行 shared self-check 第 4 项（此时全部文件已存在，任何 MISSING 都是缺陷）；Task 1 记录的前向链接复核。
- [ ] **Step 5: spec 验收标准逐条走查** —— spec §11 的 5 条验收标准逐条核对（特别是 10.1 修订融入性：以 spec §6 各任务源指针为 checklist 抽查 D-4/D-8/D-10/D-11/D-12/D-13/D-14 是否都能在成文中找到对应步骤或告警）。
- [ ] **Step 6: 修复与提交** —— 发现的问题就地修复；`git add -A && git commit -m "docs: consistency fixes across migrating section"`（若无修复则跳过本 commit）。

## Self-Review 记录

- Spec 覆盖：spec §4 目录 17 文件 ↔ Task 1–13 全覆盖；§6.1–§6.16 每节都有对应任务；sites.yaml（Task 1）、告警规范（全局约束文案 A–E + Task 14 穷举核对）、验收标准（Task 14 Step 5）均有落点。
- 占位符扫描：无 TBD/「适当处理」类空话；所有关键命令给出实际内容或精确源指针 + 产品化规则。
- 一致性：文件名/weight 在 File Structure、各任务 Files、Task 14 核对三处一致；danger 计数（5 处）与 spec §7 的 3 类场景一致（danger-A ×3 + danger-B ×1 + danger-C ×1）。
