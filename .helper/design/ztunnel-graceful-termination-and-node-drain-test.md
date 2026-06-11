# ZTunnel 长连接更新测试（B 层行为验证）：优雅连接终止 与 节点排空

> 适用场景：在 k8s 上**实测验证** `docs/en/updating/update-ambient-mode/ztunnel-update-process.mdx` 的两节缓解措施
> ——「Configuring graceful connection termination」（调大排水期）与「Safely updating ZTunnel by draining nodes」（节点排空）——
> 是否真的按文档描述生效。
>
> 本文是**动手 runbook（B 层 = 行为/效果验证）**，与 `ambient-mode-upgrade-time-and-impact.md`（概念与影响分析）互补：那篇讲"是什么、影响多大"，本篇讲"怎么在集群里复现并观测到"。
>
> 组件版本路径沿用升级文档示例：Istio **v1.28.3 → v1.28.6**；`Istio`/`IstioCNI`/`ZTunnel` 资源均名为 `default`，ZTunnel 在 `ztunnel` 命名空间。

## 1. 目标与待验证断言

ZTunnel 工作在 L4，已建立的 TCP 连接**无法在新旧 ztunnel 进程间移交**。替换某节点的 ztunnel 时，旧进程收到 `SIGTERM` 后关闭监听、只处理存量连接，到 `terminationGracePeriodSeconds`（排水期，默认 **30 秒**）结束仍未关闭的连接会被**强制重置（RST）**。本测试要复现并验证以下三个断言：

| # | 断言 | 对应文档章节 | 预期观测 |
|---|------|--------------|----------|
| A | 默认 30s 排水期下，寿命超过排水期的长连接在 ztunnel 替换后被强制 **RST** | （问题本身） | 替换后约 30s，连接被 reset |
| B | 把排水期调大到覆盖连接寿命后，**有限寿命**的长连接能在排水期内自然结束，**不被 RST** | Configuring graceful connection termination | 连接正常跑完，无 reset |
| C | 改用 `OnDelete` + 逐节点 drain：应用按**自身**优雅终止流程关闭连接（**FIN**），随后空节点上的 ztunnel 替换不波及任何连接 | Safely updating ZTunnel by draining nodes | 连接随应用迁移优雅关闭，ztunnel 替换零影响 |

### 1.1 关键概念：有限寿命 vs 常驻长连接（决定测法）

- **断言 B（调大排水期）只能保护"有限寿命"的长连接**——即连接寿命 < 排水期，能在排水期内自然结束。
- **常驻/无限长连接**（如一直不关闭的连接池、长期 gRPC stream），排水期调多大最终都会在排水期满时被 RST，只能靠**断言 C（节点排空）**——先把应用优雅迁走、再换空节点的 ztunnel——来保护。

因此场景一用**有限寿命连接**（`iperf3 -t 60`，跑 60 秒后自然结束），场景二用**常驻连接**（`socat` 心跳，永不主动关闭）。

## 2. 测试原理与 RST/FIN 判定标准

核心是区分连接的两种死法：

- **RST（强制重置）** = ztunnel 排水期满后强行掐断（断言 A），或排水期太短（断言 A 基线）。
- **FIN / 优雅关闭** = 连接由**应用端**主动、有序关闭（断言 B 自然结束、断言 C 应用迁移）。

三种判定信号，从快到准：

1. **`socat` 退出码（最易读）**：客户端 `socat` 进程
   - 退出码 `0` —— 对端优雅关闭（收到 FIN/EOF）。
   - 退出码非 `0`（通常 `1`）且 stderr 出现 `Connection reset by peer` —— 被 **RST**。
2. **`iperf3` 完成与否（场景一量化）**：
   - 跑满 `-t` 指定秒数并打印完整 summary、退出 `0` —— 连接存活到自然结束。
   - 中途报错退出（如 `iperf3: error - ... Connection reset by peer` / `control socket has closed unexpectedly`）—— 被 RST。
3. **`tcpdump` 抓标志包（最权威，可选）**：在连接端的 Pod 内抓含 `R`(RST) 或 `F`(FIN) 标志的包，直接看内核层发生了哪种关闭。

> 说明：ambient 模式下应用与本节点 ztunnel 之间是明文短链路，ztunnel 强制关闭时应用侧连接会收到 RST，优雅关闭时收到 FIN——因此在应用 Pod 内即可观测到这两种信号。

### 2.1 连接路径与两个场景的触发点

ambient L4 下，连接两端各自经所在节点的 ztunnel 转发，**替换任一端节点的 ztunnel 都会影响该连接**。本测试固定 client 在节点 B（始终在线、充当观察者），server 在节点 A：

```
   client Pod (节点 B, 观察者)
        │  明文 TCP
        ▼
   ztunnel(节点 B)  ◄── 【场景一】在此替换 ztunnel（应用不动）
        │                 → 旧进程排水期满后 RST 此连接
        │                 · grace=30s ：60s 连接被 RST（断言 A）
        │  HBONE/mTLS      · grace=120s：60s 连接跑完无 RST（断言 B）
        ▼
   ztunnel(节点 A)  ◄── 【场景二】drain 节点 A：server 先优雅迁走→FIN、
        │                 连接由应用关闭；再换此时已空的 ztunnel，零影响（断言 C）
        ▼
   server Pod (节点 A)
```

要点：场景一**替换 client 节点（B）的 ztunnel**、应用不动，让 ztunnel 成为强制断连的一方；场景二**排空 server 节点（A）**、让应用先优雅迁走，client 始终在节点 B 上观察连接的死法。

## 3. 环境前提

- 已按 `docs/en/installing/ambient-mode/` 部署 ambient 模式服务网格，`Istio`/`IstioCNI`/`ZTunnel` 三资源 `Healthy`，起步版本 **v1.28.3**。
- 集群有 **≥3 个可调度 worker 节点**（场景二 drain 一个节点后，被驱逐的工作负载需在不违反反亲和的前提下落到第三个节点）。
- 具备集群管理员权限（需 `kubectl drain` / `cordon` / 删除 `ztunnel` 命名空间下的 Pod / patch `ZTunnel` CR）。
- 测试镜像：[`nicolaka/netshoot`](https://hub.docker.com/r/nicolaka/netshoot)（k8s 网络排障标准工具箱，内置 `socat`、`iperf3`、`nc`(netcat-openbsd)、`tcpdump` 等，一镜像即可同时充当 server / client / 抓包端；**注意该镜像不含 `ncat`**，本测试改用 `socat`）。
- 集群可拉取该镜像；若处于离线环境，请先把镜像同步到内部 registry 并替换下文 manifest 中的 `image`。

> 选择 `nicolaka/netshoot` 的理由：本测试的目的就是**观测** RST/FIN，`socat`/`iperf3` 能精确控制连接寿命并给出清晰的关闭原因，`tcpdump` 可做包级佐证，全部在同一个广泛使用的镜像里，无需引入额外的应用或 broker。

## 4. 部署长连接测试应用

**先确认拉取到的镜像确实带本测试用到的工具**（避免再次遇到 `command not found`——netshoot 的工具集随版本会变）：

```bash
kubectl run nettool-check --rm -i --restart=Never --image=nicolaka/netshoot -- \
  sh -c 'for b in socat iperf3 tcpdump; do command -v "$b" || echo "MISSING: $b"; done'
```

三者都打印出路径、无 `MISSING` 即可继续。本测试用 `socat`（netshoot 自带），**不依赖 `ncat`**（该镜像未安装）。

### 4.1 创建并启用 ambient 的命名空间

```bash
kubectl create namespace conntest
# 让控制面发现该命名空间
kubectl label namespace conntest istio-discovery=enabled
# 把命名空间纳入 ambient 数据面（流量经 ztunnel 重定向）
kubectl label namespace conntest istio.io/dataplane-mode=ambient
```

### 4.2 部署 server 与 client

两个工作负载用**互斥的 `podAntiAffinity`** 保证被调度到**不同节点**（这样连接必然跨节点、两端各自依赖所在节点的 ztunnel），但**不锁定具体节点**（便于场景二 drain 时自由迁移）。

`conntest-apps.yaml`：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: conn-server
  namespace: conntest
spec:
  replicas: 1
  selector:
    matchLabels:
      app: conn-server
  template:
    metadata:
      labels:
        app: conn-server
    spec:
      terminationGracePeriodSeconds: 30   # 应用自身的优雅终止期（场景二中由它主导关闭）
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: conn-client
              topologyKey: kubernetes.io/hostname
      containers:
        - name: net
          image: nicolaka/netshoot:latest
          command: ["/bin/bash", "-lc"]
          args:
            - |
              echo "[server] iperf3 -s :5201 + socat echo :8080"
              iperf3 -s -p 5201 &
              # socat 回显：fork=每个连接独立子进程，reuseaddr=快速重绑，EXEC:cat=回显
              exec socat -d -d TCP-LISTEN:8080,fork,reuseaddr EXEC:cat
---
apiVersion: v1
kind: Service
metadata:
  name: conn-server
  namespace: conntest
spec:
  selector:
    app: conn-server
  ports:
    - name: echo
      port: 8080
      targetPort: 8080
    - name: iperf3
      port: 5201
      targetPort: 5201
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: conn-client
  namespace: conntest
spec:
  replicas: 1
  selector:
    matchLabels:
      app: conn-client
  template:
    metadata:
      labels:
        app: conn-client
    spec:
      terminationGracePeriodSeconds: 30
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: conn-server
              topologyKey: kubernetes.io/hostname
      containers:
        - name: net
          image: nicolaka/netshoot:latest
          command: ["/bin/bash", "-lc"]
          args:
            - |
              SERVER=conn-server.conntest.svc.cluster.local
              PORT=8080
              # 常驻长连接：每 2 秒发一次心跳并读取回显；连接断开后记录退出码再重连。
              # 外层重连模拟"带重试能力的应用"；判定单条连接的死法只看每次 socat 的退出码与 -d -d 日志。
              while true; do
                echo "===== [$(date '+%F %T')] OPEN long-lived TCP -> ${SERVER}:${PORT} ====="
                # socat -d -d 把连接建立/关闭/错误（含 Connection reset by peer / EOF）打到 stderr，被 kubectl logs 捕获
                ( while true; do echo "ping $(date '+%T')"; sleep 2; done ) | socat -d -d - TCP:${SERVER}:${PORT}
                echo "===== [$(date '+%F %T')] CLOSED (socat exit=$?) — 见上方 -d -d 日志判定 RST/FIN；3 秒后重连 ====="
                sleep 3
              done
```

```bash
kubectl apply -f conntest-apps.yaml
kubectl -n conntest rollout status deploy/conn-server
kubectl -n conntest rollout status deploy/conn-client
```

### 4.3 校验拓扑与入网

```bash
# 两个 Pod 应在不同节点上
kubectl -n conntest get pod -o wide

# 确认已被 ztunnel 纳管（如集群已装 istioctl；命令与安装文档一致）
istioctl ztunnel-config workloads | grep conntest

# 确认常驻连接已建立：client 日志应持续打印从 server 回显的 ping
kubectl -n conntest logs deploy/conn-client --tail=10
```

> 下面每个场景的命令块都会在用到时**自行取所需的节点名**（如 `NODE_CLIENT=$(kubectl ...)`），可逐块复制运行，无需依赖跨终端持久的变量；其中替换 ztunnel 的触发命令更进一步内联了节点定位，复制即可在任意终端执行。场景二涉及 drain 后 server Pod 迁移，相关变量只在 drain 前取一次（块内已注明）。

## 5. 场景一：验证「Configuring graceful connection termination」

用 `iperf3 -t 60`（寿命 60 秒的有限连接）作主角；client 在 `$NODE_CLIENT`，连接经 `$NODE_CLIENT` 的 ztunnel，因此**替换 `$NODE_CLIENT` 的 ztunnel** 即可触发。

### 5.1 负向基线：默认 30s 排水期 → 连接被 RST（验证断言 A）

1. 确认当前排水期为默认值（30 秒）：

   ```bash
   NODE_CLIENT=$(kubectl -n conntest get pod -l app=conn-client -o jsonpath='{.items[0].spec.nodeName}')
   POD=$(kubectl -n ztunnel get pod --field-selector spec.nodeName=$NODE_CLIENT -o jsonpath='{.items[0].metadata.name}')
   kubectl -n ztunnel get pod "$POD" -o jsonpath='{.spec.terminationGracePeriodSeconds}{"\n"}'   # 期望 30
   ```

2. **终端 1** —— 启动 60 秒 iperf3 流：

   ```bash
   kubectl -n conntest exec -it deploy/conn-client -- \
     iperf3 -c conn-server.conntest.svc.cluster.local -p 5201 -t 60 -i 5
   ```

3. **终端 2** —— iperf3 起跑约 5 秒后，替换 client 所在节点的 ztunnel（最快、版本无关的触发方式）：

   ```bash
   # 自动定位 client 所在节点（复制即可在任意终端运行）
   kubectl -n ztunnel delete pod \
     --field-selector spec.nodeName=$(kubectl -n conntest get pod -l app=conn-client -o jsonpath='{.items[0].spec.nodeName}')
   ```

4. 观测终端 1：约 **30 秒**后（排水期满），iperf3 在跑满 60 秒前被中止并报错退出（`Connection reset by peer` / `control socket has closed unexpectedly`）。同时 client 日志里常驻 `socat` 也会出现一次 `exit≠0` + `Connection reset by peer`。

   **结论**：默认 30s 排水期下，寿命（60s）超过排水期（30s）的连接被强制 RST。

### 5.2 正向：排水期调到 120s → 有限连接自然结束、无 RST（验证断言 B）

> 测试用 **120 秒**（足够覆盖 60 秒的测试连接即可；生产环境请按实际最长连接寿命设置，文档示例用的是 300 秒）。

1. 在 `ZTunnel` CR 设置排水期：

   ```bash
   kubectl patch ztunnel default --type merge \
     -p '{"spec":{"values":{"ztunnel":{"terminationGracePeriodSeconds":120}}}}'
   ```

2. 等 DaemonSet 滚动完（改 Pod 模板会触发一次 `RollingUpdate`），并确认新 ztunnel Pod 已采用 120：

   ```bash
   kubectl rollout status daemonset/ztunnel -n ztunnel
   NODE_CLIENT=$(kubectl -n conntest get pod -l app=conn-client -o jsonpath='{.items[0].spec.nodeName}')
   POD=$(kubectl -n ztunnel get pod --field-selector spec.nodeName=$NODE_CLIENT -o jsonpath='{.items[0].metadata.name}')
   kubectl -n ztunnel get pod "$POD" -o jsonpath='{.spec.terminationGracePeriodSeconds}{"\n"}'   # 期望 120
   ```

   > 若个别 Pod 未自动滚动到新模板，可手动删除让其重建：`kubectl -n ztunnel delete pod "$POD"`。

3. **终端 1** —— 再次启动 60 秒 iperf3 流（同 5.1 步骤 2）。

4. **终端 2** —— 起跑约 5 秒后，再次替换 client 节点 ztunnel：

   ```bash
   # 自动定位 client 所在节点（复制即可在任意终端运行）
   kubectl -n ztunnel delete pod \
     --field-selector spec.nodeName=$(kubectl -n conntest get pod -l app=conn-client -o jsonpath='{.items[0].spec.nodeName}')
   ```

5. 观测终端 1：旧 ztunnel 在排水期（120s）内持续服务该连接，iperf3 在 **60 秒**时正常跑完、打印完整 summary、退出 `0`，**全程无 reset**（因 60s < 120s）。

   **结论**：把排水期调到覆盖连接寿命，有限寿命长连接在排水期内自然结束，不被 RST。

   > 教学点：此时 client 那条**常驻** `socat` 连接仍会在替换后第 120 秒被 RST——因为它是无限寿命连接，排水期再大也救不了。这正是为什么需要场景二。

6. 复位排水期（进入场景二前建议恢复默认，避免干扰；也可留到第 8 节统一清理）：

   ```bash
   kubectl patch ztunnel default --type json \
     -p '[{"op":"remove","path":"/spec/values/ztunnel/terminationGracePeriodSeconds"}]'
   ```

## 6. 场景二：验证「Safely updating ZTunnel by draining nodes」

用常驻 `socat` 连接（无限寿命，场景一证明它靠调大排水期救不了）。这次**排空 server 所在节点 `$NODE_SERVER`**：server 被优雅驱逐 → 连接由应用端关闭（FIN）→ client 在 `$NODE_CLIENT` 上始终在线，充当观察者见证"优雅关闭而非 RST"。ztunnel 排水期在本场景**不起作用**（换 ztunnel 前节点上已无工作负载）。

1. 切换 ztunnel 更新策略为 `OnDelete`：

   ```bash
   kubectl patch ztunnel default --type merge \
     -p '{"spec":{"values":{"ztunnel":{"updateStrategy":{"type":"OnDelete"}}}}}'
   ```

2. 设目标版本，并确认现有 ztunnel Pod **未被自动替换**（`OnDelete` 生效的证据）：

   ```bash
   kubectl patch ztunnel default --type merge -p '{"spec":{"version":"v1.28.6"}}'
   # 现有 ztunnel Pod 的 AGE 不应被重置——说明改版本没有自动滚动任何 Pod
   kubectl -n ztunnel get pod -o wide
   ```

3. 确认常驻连接在跑（client 日志持续回显 ping），记录当前 server Pod 名以便观测它被驱逐：

   ```bash
   # 取 server 当前所在节点；本场景全程用这个值，且步骤 4 drain 后不要重新取（server Pod 会迁走）
   NODE_SERVER=$(kubectl -n conntest get pod -l app=conn-server -o jsonpath='{.items[0].spec.nodeName}')
   echo "本轮将排空节点：$NODE_SERVER"
   kubectl -n conntest logs deploy/conn-client --tail=5
   kubectl -n conntest get pod -l app=conn-server -o wide
   ```

4. 排空 server 所在节点。`--ignore-daemonsets` 让 ztunnel / istio-cni 等 DaemonSet 保留在节点上（预期行为）：

   ```bash
   kubectl cordon "$NODE_SERVER"
   kubectl drain "$NODE_SERVER" --ignore-daemonsets --delete-emptydir-data
   ```

   观测 client 日志：在 server 被驱逐的瞬间，常驻连接关闭，且 **`socat exit=0`、无 `Connection reset by peer`**（日志显示 EOF）——即对端（应用）优雅关闭（FIN）。随后 server Pod 因反亲和被重新调度到第三个节点，client 自动重连成功。

   > 这与场景一形成对照：同一条常驻连接，在场景一里是被 **ztunnel 在排水期满时 RST**（应用还在跑）；这里是被**应用自身的优雅终止关闭**（ztunnel 未动）。

5. 此刻 `$NODE_SERVER` 上已无 mesh 工作负载，替换它的 ztunnel 对流量零风险：

   ```bash
   kubectl -n ztunnel delete pod --field-selector spec.nodeName=$NODE_SERVER
   # 新 ztunnel Pod 起来并就绪，且为 v1.28.6
   kubectl -n ztunnel get pod --field-selector spec.nodeName=$NODE_SERVER -o wide
   ```

6. 恢复节点可调度：

   ```bash
   kubectl uncordon "$NODE_SERVER"
   ```

7. 对集群中其余每个节点重复步骤 4–6（逐节点排空 → 删旧 ztunnel Pod → uncordon）。每轮先把 `NODE_SERVER` 设为该轮要排空的节点名（`NODE_SERVER=<节点名>`），步骤 4–6 在同一终端按序执行即可。直到所有节点的 ztunnel 都更新到目标版本：

   ```bash
   kubectl wait --for=condition=Ready ztunnel/default --timeout=10m
   kubectl get ztunnel default          # 期望版本 v1.28.6、Healthy
   kubectl -n ztunnel get pod -o wide    # 期望所有 ztunnel Pod 均为新建
   ```

   **结论**：`OnDelete` + 逐节点 drain 全程没有任何连接被 ztunnel 强制 RST——存量连接都由应用按自身优雅终止关闭，空节点上的 ztunnel 替换零影响。

8. 复位更新策略（恢复默认 `RollingUpdate`）：

   ```bash
   kubectl patch ztunnel default --type merge \
     -p '{"spec":{"values":{"ztunnel":{"updateStrategy":{"type":"RollingUpdate"}}}}}'
   ```

## 7. （可选）tcpdump 包级佐证

需要内核层确证 RST/FIN 时，在连接端 Pod 内抓标志包。建议在**未被 drain 的那一端**抓（场景一在 client，场景二在 client）：

```bash
kubectl -n conntest exec -it deploy/conn-client -- \
  tcpdump -ni eth0 -tttt 'tcp port 8080 and (tcp[tcpflags] & (tcp-rst|tcp-fin) != 0)'
```

- 抓到带 `R`（Reset）的包 = 被强制重置（场景一基线）。
- 抓到带 `F`（Fin）的包 = 优雅关闭（场景一正向、场景二）。

> 注意：`tcp[tcpflags]` 过滤式对 `-i any` 或 IPv6 可能不解析，故指定具体网卡 `eth0`；若 Pod 主网卡名不同，先用 `ip -br link` 查。

## 8. 结果记录模板

| 场景 | 排水期 grace | 连接类型 | 触发方式 | client 观测（exit / 消息） | swap→断开耗时 | 是否符合预期 |
|------|--------------|----------|----------|---------------------------|----------------|--------------|
| 5.1 负向基线 | 30s（默认） | 有限 60s (iperf3) | 删 client 节点 ztunnel | exit=1 / reset by peer | ≈ 30s | ☐ |
| 5.2 正向 | 120s | 有限 60s (iperf3) | 删 client 节点 ztunnel | exit=0 / 跑满 60s 无 reset | 不断开 | ☐ |
| 6 节点排空 | 不涉及 | 常驻 (socat) | drain server 节点 | exit=0 / 无 reset（FIN） | 随 drain 即时、应用优雅 | ☐ |

## 9. 清理

```bash
# 删除测试应用
kubectl delete namespace conntest

# 复位 ZTunnel CR（按需）：恢复默认更新策略、移除排水期覆盖
kubectl patch ztunnel default --type merge \
  -p '{"spec":{"values":{"ztunnel":{"updateStrategy":{"type":"RollingUpdate"}}}}}'
kubectl patch ztunnel default --type json \
  -p '[{"op":"remove","path":"/spec/values/ztunnel/terminationGracePeriodSeconds"}]' 2>/dev/null || true
# 版本：若已完成更新可保留 v1.28.6；如为回退测试，再 patch 回 v1.28.3
```

## 10. 故障排查与注意事项

- **用 `socat` 而非 `ncat`**：`nicolaka/netshoot` 默认**不安装** `ncat`（Alpine 的 `ncat` 在独立的 `nmap-ncat` 包里，netshoot 只装了 `nmap` / `nmap-nping` / `nmap-scripts`），直接用 `ncat` 会报 `command not found`。`socat` 是 netshoot 自带工具，语法跨版本稳定、`-d -d` 能清晰打印关闭原因（`Connection reset by peer` vs EOF），是本测试首选。镜像里也有 `nc`(netcat-openbsd) 可作备选，但其 `-l` / `-k` 监听语法在不同版本间有差异、关闭原因不如 `socat` 直观。
- **客户端自动重连会"掩盖"reset**：本测试客户端外层有重连循环（模拟带重试的应用），判定单条连接的死法**只看每次 `socat` 的退出码与 `-d -d` 日志**，不要被"很快又连上了"误导。要模拟脆弱的单连接应用，只观察第一条连接的结局即可。
- **优雅关闭却看到 RST？** 进程被杀时若 socket 接收缓冲区仍有未读数据，内核可能发 RST 而非 FIN。本测试心跳间隔 2s 且客户端持续读取回显，缓冲区基本为空，正常会是 FIN；若仍偶发 RST，适当拉长心跳间隔或确认应用在 `SIGTERM` 时有序关闭。场景二的**主要判据是关闭的时机与起因**（随 drain 发生、由应用优雅终止主导），FIN/RST 为辅证。
- **ambient 下连接两端的节点 ztunnel 都在路径上**：替换任一端所在节点的 ztunnel 都会影响该连接。本测试固定让 client 跨节点常驻、并明确指定要替换/排空的节点，就是为了让观测端稳定、结论无歧义。
- **改排水期会触发一次滚动**：在默认 `RollingUpdate` 下 patch `terminationGracePeriodSeconds` 本身就会逐节点重建 ztunnel Pod；务必先等滚动完成、确认新值已生效，再开始计时实验。
- **`kubectl drain` 相关**：`--ignore-daemonsets` 是必须的（ztunnel/istio-cni 为 DaemonSet）；用到 emptyDir 时加 `--delete-emptydir-data`；若存在 PodDisruptionBudget 可能阻塞 drain，需评估后处理。
- **排水期调大会拉长整体更新时长**：每个持有存量连接的节点最坏多等一个排水期，详见 `ambient-mode-upgrade-time-and-impact.md` 第 2.3 / 5 节，需在"保护长连接"与"总时长"间权衡。

## 11. 参考文档

- `docs/en/updating/update-ambient-mode/ztunnel-update-process.mdx` — 被验证的两节缓解措施与 ZTunnel 滚动机制
- `docs/en/updating/update-ambient-mode/updating-ambient-components.mdx` — 三组件（含 ZTunnel）实际更新与验证命令
- `.helper/design/ambient-mode-upgrade-time-and-impact.md` — ambient 升级的时间与影响分析（本文的概念互补篇）
- `docs/en/installing/ambient-mode/deploying-ambient-bookinfo.mdx` — ambient 入网标签（`istio-discovery` / `istio.io/dataplane-mode`）参考
- [nicolaka/netshoot](https://hub.docker.com/r/nicolaka/netshoot) — 测试镜像（含 socat / iperf3 / nc / tcpdump；**不含** ncat）
