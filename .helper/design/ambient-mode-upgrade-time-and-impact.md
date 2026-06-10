# Ambient 模式服务网格升级时间与影响评估（mesh v2.1.1 → v2.1.2）

> 适用场景：客户按照 `docs/en/installing/ambient-mode/` 文档部署了 ambient 模式服务网格（Alauda Service Mesh Operator 2.1.1），
> 现计划按照 `docs/en/updating/update-ambient-mode/` 文档升级到 mesh v2.1.2。
> 对应的 Istio 组件版本路径以升级文档示例为准：**v1.28.3 → v1.28.6**（patch 级升级，实际版本以 Release Notes 为准）。

## 1. 升级范围与顺序

Ambient 模式仅支持 `InPlace` 更新策略（ZTunnel 为集群级单例，无法两版本并存，故不支持 `RevisionBased` 金丝雀升级）。升级按固定顺序执行，顺序由版本偏差规则决定：数据面组件（CNI/ZTunnel/waypoint）不得领先控制面。

| 阶段 | 操作对象 | 操作方式 | 对应文档 |
|------|----------|----------|----------|
| 0 | Alauda Service Mesh Operator | OLM 升级请求 + 管理员审批，Operator Pod 滚动替换 | `updating/update-mesh/index.mdx`（Operator updates and channels） |
| 1 | Istio 控制平面（istiod） | `kubectl patch istio default` 修改 `spec.version` | `update-ambient-mode/updating-ambient-components.mdx` |
| 1a | Waypoint 代理（如有部署） | **无需操作**，istiod 在控制面升级后自动滚动 waypoint Deployment | `update-ambient-mode/updating-waypoint-proxies.mdx` |
| 2 | Istio CNI（istio-cni-node DaemonSet） | `kubectl patch istiocni default`，DaemonSet 逐节点滚动 | 同上 + `update-mesh/istio-cni.mdx` |
| 3 | ZTunnel（ztunnel DaemonSet） | `kubectl patch ztunnel default`，DaemonSet 逐节点滚动 | 同上 + `update-ambient-mode/ztunnel-update-process.mdx` |
| 4 | 验证 | 组件版本/状态、HBONE 工作负载、网格连通性、waypoint 版本与 L7 行为 | `updating-ambient-components.mdx`、`updating-waypoint-proxies.mdx` |

注意：Operator 升级本身**不会**自动升级 Istio 控制平面（除非 `Istio` 资源使用了 `vX.Y-latest` 版本别名）。阶段 1–3 必须按序手工执行，且每一步都要等上一组件 Ready 后再进行。

## 2. 预计升级时间

### 2.1 分阶段耗时

下表中"文档等待上限"是升级文档中 `kubectl wait --timeout` 编码的最坏预期，正常情况远低于此；"典型耗时"按镜像已可快速拉取、集群健康的前提估算。N 为集群节点数。

| 阶段 | 典型耗时 | 文档等待上限 | 耗时构成 |
|------|----------|--------------|----------|
| Operator 升级（v2.1.1→v2.1.2） | 3–5 分钟 | — | OLM 审批 + CSV 安装 + Operator Pod 替换；不影响运行中的网格组件 |
| Istio 控制平面 | 1–3 分钟 | `--timeout=3m` | istiod Deployment 滚动（默认先起新副本再停旧副本） |
| Waypoint 自动滚动（如有） | 每个 waypoint 约 30–60 秒 | — | 与后续阶段并行进行，通常不增加总时长 |
| Istio CNI | 约 N × (20–60 秒) | `--timeout=5m` | DaemonSet 逐节点滚动；首次拉取新镜像的节点偏慢 |
| ZTunnel | 约 N × (40–90 秒) | `--timeout=10m` | 逐节点滚动；每节点 = 新 Pod 就绪（10–30 秒）+ 旧 Pod 排水（0 秒至 `terminationGracePeriodSeconds`，默认 30 秒） |
| 验证 | 5–10 分钟 | — | 三组件版本/Healthy、bookinfo Pod、`ztunnel-config workloads`（HBONE）、连通性 curl；如有 waypoint 再加 proxy-status、L7 路由与授权验证 |

### 2.2 按集群规模估算总时长

总时长 ≈ Operator（5 分钟）+ 控制面（3 分钟）+ N × 1 分钟（CNI）+ N × 1.5 分钟（ZTunnel）+ 验证（10 分钟），向上取整：

| 集群规模 | 纯变更耗时（典型） | 含验证总耗时 | 建议维护窗口 |
|----------|--------------------|--------------|--------------|
| 3 节点 | 10–15 分钟 | 20–25 分钟 | 1 小时 |
| 10 节点 | 20–35 分钟 | 30–45 分钟 | 1.5 小时 |
| 30 节点 | 45–90 分钟 | 1–1.5 小时 | 3 小时 |

维护窗口预留约 2 倍余量，覆盖镜像拉取偏慢、个别节点重试、以及失败时按原版本回退的时间。

### 2.3 影响时长的关键因素

- **节点数量**：CNI 与 ZTunnel 均为 DaemonSet 逐节点滚动，耗时与节点数线性相关，这是大集群的主要耗时项。
- **镜像拉取**：每个节点需拉取新版 istio-cni 与 ztunnel 镜像（各约 100 MB 量级）。registry 带宽不足或跨网络拉取会显著拉长每节点耗时；条件允许时建议提前预热镜像。
- **`terminationGracePeriodSeconds`**：若按 `ztunnel-update-process.mdx` 将 ZTunnel 排水期调大（例如 300 秒）以保护长连接，每个持有存量连接的节点最坏会多等一个排水期——30 节点 × 5 分钟即最坏 +2.5 小时，需在"保护长连接"与"总时长"之间权衡。
- **节点排空方案**：若对长连接敏感的工作负载选择 `OnDelete` + 逐节点排空（drain）方案，耗时由应用自身的优雅终止与重新调度主导，通常需要按节点数 × (5–15 分钟) 单独评估，建议分批跨多个窗口执行。

## 3. 升级影响分析

### 3.1 总体结论

- **应用 Pod 全程不重启、不重新调度**。这是 ambient 模式与 sidecar 模式最大的差别：xDS 连接由每节点的 ZTunnel（而非每个应用 Pod）持有，应用无感切换到新代理。
- **不存在整集群断流窗口**。各组件滚动期间，数据面始终保留 L4 转发与 mTLS 能力；任一时刻最多影响一个节点。
- **唯一可能影响业务流量的环节是 ZTunnel 替换**：ZTunnel 工作在 L4，已建立的 TCP 连接无法移交给新进程，超过排水期的长连接会被强制断开（reset）。

### 3.2 分组件影响

| 阶段 | 对存量流量 | 对新建连接 | 其他影响 |
|------|------------|------------|----------|
| Operator 升级 | 无 | 无 | 仅 Operator 调和能力短暂不可用，运行中组件不受影响 |
| 控制平面（istiod） | 无（数据面持有最后下发的配置继续转发） | 无 | 配置下发短暂中断：新路由/策略生效、新 Pod 进入网格会延迟到新 istiod 就绪（默认单副本下约数十秒）；ZTunnel/waypoint 自动重连 |
| Waypoint 自动滚动 | 经旧 waypoint 的在途 L7 请求在排水期内完成；长连接会断开重连 | 新 waypoint Pod 就绪后才接管，基本无失败窗口 | L7 路由（HTTPRoute 权重）与 AuthorizationPolicy 持续生效 |
| Istio CNI | **无**（CNI 插件只在 Pod 创建/加入网格时起作用） | 无 | 每节点 agent 重启的几十秒内，该节点**新调度** Pod 的网格初始化会延迟（CNI ADD 重试）；`reconcileIptablesOnStartup: true`（安装文档已配置）保证 agent 重启后自动修复存量 ambient Pod 的 iptables 规则 |
| ZTunnel | **该节点上超过排水期的长连接被 reset**（详见 3.3） | 无中断：新旧 ZTunnel 通过 `SO_REUSEPORT` 短暂并存，节点上任一时刻都有监听者 | 逐节点滚动，影响面始终限定在单个节点 |

### 3.3 ZTunnel 替换的流量影响（重点向客户说明）

每个节点上的替换过程：新 Pod 启动并就绪 → 新旧并存（均可接受新连接）→ 旧 Pod 收到 SIGTERM 后关闭监听、只处理存量连接 → 排水期（默认 30 秒）结束后仍未关闭的连接被强制断开。

对业务的实际含义：

- **短连接（HTTP 请求/响应、定期轮询）**：基本无感。请求要么在排水期内完成，要么由客户端正常重试。
- **长连接（数据库连接池、gRPC stream、WebSocket、消息队列消费者）**：若连接生命周期超过排水期会被 reset，应用必须依赖自身重连机制恢复。受影响范围 = 正在滚动的那个节点上的 ambient 工作负载所持有的连接。
- **跨节点流量**：仅当连接的某一端位于正在滚动的节点上才受影响，其余节点流量不受波及。

缓解选项（按代价从低到高）：

1. **确认应用具备重连/重试能力**（连接池自动重建、gRPC 重试策略、合理的 keepalive）——多数场景下默认 30 秒排水期即可接受。
2. **调大 `terminationGracePeriodSeconds`**（ZTunnel CR 中配置，如 300 秒），让连接在排水期内自然结束；代价是拉长升级总时长。
3. **对长连接敏感的关键工作负载使用 `OnDelete` + 节点排空**：先 drain 节点让应用按自身优雅终止流程迁走，再替换空节点上的 ZTunnel，全程无连接被强制断开；代价是耗时最长、涉及工作负载迁移。

### 3.4 升级期间的版本兼容性保障

升级顺序（控制面 → CNI → ZTunnel）保证过程中出现的所有版本组合都在支持范围内：1.x 版本的 CNI/ZTunnel/waypoint 可以与 1.x 或 1.x+1 的控制面配合（数据面不领先控制面即可）。本次为同一 minor（1.28.x）内的 patch 升级，不触及 minor 级偏差边界，组件间允许短暂版本不一致，阶段之间可以暂停观察。

## 4. 风险与注意事项

- **Ambient 模式当前为技术预览（Technology Preview）特性**。升级文档明确建议：先在非生产环境验证目标版本组合，再升级生产集群。`updating-ambient-components.mdx` 的"Installing ambient mode with a specific version"一节即为此演练设计（从 v1.28.3 起步完整走一遍升级）。
- **顺序不可颠倒、不可并行 patch 三个 CR**。每一步必须等待上一组件 `Ready`（文档提供了对应的 `kubectl wait` 与 `kubectl rollout status` 命令）。
- **istiod 默认单副本**。控制面替换期间配置下发有短暂空窗；对配置变更频繁的环境，建议参照 Istio High Availability 文档先配置多副本。
- **回退方案**：`InPlace` 策略下回退即把各 CR 的 `spec.version` 改回 v1.28.3，建议按升级的逆序执行（ZTunnel → CNI → 控制面）。回退时 ZTunnel 会再次逐节点滚动，长连接影响与升级相同，估算窗口时应把"一次完整回退"计入。
- **超时不代表失败**：`kubectl wait` 超时（如大集群 ZTunnel 超过 10 分钟）通常只需重新执行 wait/rollout status 继续观察；先确认 DaemonSet 事件与节点镜像拉取情况，不要急于回退。

## 5. 升级前检查清单

1. 确认当前组件健康：`kubectl get istio,istiocni,ztunnel`，三者均为 `Healthy`，版本为 v1.28.3。
2. 确认 Operator 升级通道与审批策略，新版本（2.1.2 / Istio v1.28.6）在 Operator 中可用。
3. 备份三个 CR：`kubectl get istio,istiocni,ztunnel default -o yaml`，留作回退参照。
4. 统计集群节点数，按本文 2.2 节估算时长并申请维护窗口。
5. 梳理网格内长连接型工作负载，确定 ZTunnel 排水策略（默认 / 调大排水期 / 节点排空），必要时提前修改 ZTunnel CR。
6. 选择业务低峰期执行；提前通知依赖长连接的业务方升级窗口内可能出现一次连接重建。
7. （建议）在非生产集群按文档完整演练一遍，记录实际耗时用于校准生产窗口。

## 6. 参考文档

- `docs/en/updating/update-ambient-mode/index.mdx` — 升级顺序、连接处理、版本兼容性
- `docs/en/updating/update-ambient-mode/updating-ambient-components.mdx` — 三组件升级与验证步骤
- `docs/en/updating/update-ambient-mode/updating-waypoint-proxies.mdx` — waypoint 版本与 L7 行为验证
- `docs/en/updating/update-ambient-mode/ztunnel-update-process.mdx` — ZTunnel 滚动机制、排水配置、节点排空流程
- `docs/en/updating/update-mesh/index.mdx` — Operator 升级通道与审批流程
- `docs/en/installing/ambient-mode/installing-ambient-mode.mdx` — 客户现有部署的基线配置
