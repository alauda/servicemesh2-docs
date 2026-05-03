# 文档自动化测试框架

基于 runme 工具的 MDX 文档自动化测试框架，用于验证文档中的命令和步骤是否正确可执行。

## 目录结构

```
tests/
├── run.sh                 # 单个测试执行脚本
├── run-all.sh             # 所有测试任务编排脚本
├── README.md              # 本文档
├── bin/                   # 工具存放目录 (runme, violet)
├── package/               # 插件包缓存目录
└── util/                  # 工具函数库
    ├── init.sh            # 环境初始化脚本
    ├── common.sh          # 公共函数库
    └── verify.sh          # 验证工具函数

docs/en/installing/dual-stack/
├── install-mesh-in-dual-stack-mode.mdx
└── runme-test_install-mesh-in-dual-stack-mode.sh  # 测试脚本与文档同目录
```

## 环境准备

### 1. 系统要求

**注**：执行测试脚本的机器（不是 k8s 集群）必须能访问 Github。

测试框架会自动检查并安装必要的工具，但以下工具需要预先安装：

- `kubectl` - Kubernetes 命令行工具
- `curl` - 用于下载工具和插件包
- `jq` - JSON 处理工具

### 2. 安装 `Multus` 集群插件

TODO: 后续由脚本执行初始化时自动安装

### 3. 设置环境变量

在执行测试前，需要设置以下环境变量：

```bash
# ──────────────────────────────────────────────────────────────────
# 集群名称（按文档归属选择）
# ──────────────────────────────────────────────────────────────────
# 单集群（multi-cluster 文档以外的所有测试默认使用此集群）
export SINGLE_CLUSTER_NAME=my-cluster

# 仅 docs/en/installing/multi-cluster 下的文档使用以下两个变量
export EAST_CLUSTER_NAME=east-cluster
export WEST_CLUSTER_NAME=west-cluster

# ──────────────────────────────────────────────────────────────────
# 平台信息
# ──────────────────────────────────────────────────────────────────
export PLATFORM_ADDRESS=https://xxx
export PLATFORM_USERNAME='your-username'
export PLATFORM_PASSWORD='your-password'

# ACP 平台 API token（用于自动获取集群 kubeconfig）
# 获取方式：在 ACP UI （账号的 Profile 页面）上生成 API token
export ACP_API_TOKEN='your-acp-api-token'

# 选择集群连接模式（可选，默认 direct）
# - proxy:  通过 ACP 平台代理访问 K8s API（默认，对网络隔离友好）
# - direct: 直接访问 K8s API Server（要求测试机能直连 Master 节点）
# 注：多集群服务网格必须选择 `direct`
export ACP_KUBECONFIG_MODE=direct

# ACP 平台 CA 证书（base64 编码，可选）
# - 已设置: 直接使用该值
# - 未设置: 框架会在 kubeconfig 就绪后自动从 Global 集群拉取
# export PLATFORM_CA='base64-encoded-ca-certificate'

# Global 集群名（可选，默认 'global'）
# 框架会在 init 时自动追加到集群列表末尾，用于获取 PLATFORM_CA 等平台资源
# export GLOBAL_CLUSTER_NAME=global

# ──────────────────────────────────────────────────────────────────
# 测试行为开关（可选）
# ──────────────────────────────────────────────────────────────────
# 双栈环境标识（设置为 true 时才会执行双栈文档测试）
export IS_DUAL_STACK=false
# Bookinfo 流量生成（设置为 true 时，Bookinfo 部署完成后会自动生成访问流量）
export AUTO_GEN_BOOKINFO_TRAFFIC=true

# ──────────────────────────────────────────────────────────────────
# 工具与插件包
# ──────────────────────────────────────────────────────────────────
export RUNME_VERSION=3.16.11

# 镜像加速地址（可选，用于替换默认镜像地址；留空表示不使用）
export REGISTRY_MIRROR_ADDRESS=docker-mirrors.alauda.cn

# 插件包下载地址
export PKG_SERVICEMESH_OPERATOR2_URL=xxx
export PKG_KIALI_OPERATOR_URL=xxx
export PKG_JAEGER_OPERATOR_URL=xxx
export PKG_OPENTELEMETRY_OPERATOR_URL=xxx
export PKG_METALLB_OPERATOR_URL=xxx
```

### 4. kubeconfig 自动管理

执行 `./run.sh --init-only` 时，框架会通过 ACP 平台 API 自动获取集群 kubeconfig，**无需手动下载**：

- API 入口：`${PLATFORM_ADDRESS}/auth/v1/clusters/<cluster-name>/kubeconfig`
- 认证：HTTP Header `Authorization: Bearer ${ACP_API_TOKEN}`
- 处理后的 kubeconfig 缓存于 `tests/.kubeconfig/`（已加入 `.gitignore`）：
  - `tests/.kubeconfig/<cluster-name>.yaml` — 单集群 kubeconfig（每个集群独立一份，便于子任务隔离使用）
  - `tests/.kubeconfig/merged.yaml` — 合并后的最终 KUBECONFIG
  - `tests/.kubeconfig/.fingerprint` — 配置指纹（PLATFORM_ADDRESS / ACP_KUBECONFIG_MODE / ACP_API_TOKEN / 集群列表 的 sha256）
- context 命名规则：每个集群的 context 名重命名为集群名本身（如 `my-cluster`），与 `SINGLE_CLUSTER_NAME` / `EAST_CLUSTER_NAME` / `WEST_CLUSTER_NAME` 保持一致
- **Global 集群自动追加**：无论用户传入什么集群列表，框架都会在末尾自动追加 Global 集群（默认名 `global`，可通过 `GLOBAL_CLUSTER_NAME` 覆盖）。该集群仅用于：
  - 自动获取 `PLATFORM_CA`（执行 `config-kiali:get-ca-certificate` runme 块）
  - 后续可能新增的其他平台级资源访问
  - 不会被纳入 `upload_all_packages` / `install_all_servicemesh_operators` 等业务集群操作
- 多集群（multi-cluster 文档场景）需显式传入：

  ```bash
  ./run.sh --init-only --cluster "$EAST_CLUSTER_NAME" --cluster "$WEST_CLUSTER_NAME"
  ```

  合并后默认 `current-context` 为传入的第一个集群（即 `$EAST_CLUSTER_NAME`），Global 集群对应的 context 也会出现在 `merged.yaml` 中（名为 `global`），便于按需切换。

- 当 `ACP_API_TOKEN`、`PLATFORM_ADDRESS`、`ACP_KUBECONFIG_MODE` 或集群列表任一发生变更，再次执行 `--init-only` 会自动重新拉取。

### 5. PLATFORM_CA 自动获取

`./run.sh` 在 kubeconfig 就绪后会统一解析 `PLATFORM_CA`：

| 情况                             | 行为                                                                 |
| -------------------------------- | -------------------------------------------------------------------- |
| `PLATFORM_CA` 已通过环境变量设置 | 直接使用，不访问 Global 集群                                         |
| `PLATFORM_CA` 为空               | 通过 Global 集群独立 kubeconfig 自动拉取，结果 export 给后续测试脚本 |

自动获取流程：

1. 使用 `$KUBECONFIG_DIR/global.yaml` 作为 runme 子进程的 KUBECONFIG（仅作用于子进程，**不污染调用方上下文**）
2. 执行 `runme run config-kiali:get-ca-certificate`（来自 `docs/en/integration/observability/kiali.mdx`），结果非空则使用
3. 否则回退 `runme run config-kiali:get-ca-certificate-alternative`
4. 仍为空则报错退出，提示检查 `cpaas-system/dex.tls` Secret 或显式 `export PLATFORM_CA`

## 使用方法

### 基本命令

```bash
cd tests

# 查看帮助信息
./run.sh --help

# 只执行环境初始化（默认使用 SINGLE_CLUSTER_NAME）
./run.sh --init-only

# 显式指定要初始化的集群（与上一条等价）
./run.sh --init-only --cluster "$SINGLE_CLUSTER_NAME"

# 多集群初始化（仅 multi-cluster 文档场景需要）
./run.sh --init-only --cluster "$EAST_CLUSTER_NAME" --cluster "$WEST_CLUSTER_NAME"

# 测试所有文档（自动执行初始化，按预定义顺序执行）
./run-all.sh

# 测试指定文档（默认不执行初始化，复用现有 kubeconfig）
./run.sh --file install-mesh-in-dual-stack-mode

# 测试指定文档并强制执行初始化
./run.sh --file install-mesh-in-dual-stack-mode --force-init

# 不执行 cleanup（保留测试资源）
./run.sh --file install-mesh-in-dual-stack-mode --no-cleanup

# 只执行 cleanup（清理之前的测试资源）
./run.sh --file install-mesh-in-dual-stack-mode --cleanup-only
```

### 测试多个文档

```bash
# 测试多篇指定文档
./run.sh --file install-mesh-in-dual-stack-mode --file another-doc
```

### run-all.sh 说明

`run-all.sh` 脚本按照预定义的顺序执行所有测试任务，适合 CI/CD 或全量回归测试。

**执行流程**：

1. **环境初始化**：自动执行 `./run.sh --init-only`
2. **双栈测试**：如果 `IS_DUAL_STACK=true`，执行 `install-mesh-in-dual-stack-mode` 测试
3. **单网格安装与应用测试**：
   - 安装网格：`./run.sh --file install-mesh`
   - 部署 Bookinfo：`./run.sh --file deploying-the-bookinfo-application --no-cleanup`
   - 指标验证：`./run.sh --file metrics-and-mesh`
4. **其他测试**：预留位置，后续可添加更多测试任务

**添加新的测试任务**：

编辑 `run-all.sh` 文件，在相应阶段添加新的测试命令：

```bash
# 在 run-all.sh 中添加
./run.sh --file your-new-test-task
```

## 当前已有的测试文档

| 文档名称                     | 测试脚本                                                                                                                                                                                            | 执行命令                                                                     |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| 双栈网格安装                 | [runme-test_install-mesh-in-dual-stack-mode.sh](../docs/en/installing/dual-stack/runme-test_install-mesh-in-dual-stack-mode.sh)                                                                     | `./run.sh --file install-mesh-in-dual-stack-mode`                            |
| 网格安装                     | [runme-test_install-mesh.sh](../docs/en/installing/installing-service-mesh/runme-test_install-mesh.sh)                                                                                              | `./run.sh --file install-mesh`                                               |
| 指标与服务网格集成           | [runme-test_metrics-and-mesh.sh](../docs/en/integration/observability/runme-test_metrics-and-mesh.sh)                                                                                               | `./run.sh --file metrics-and-mesh`                                           |
| Kiali 安装与配置             | [runme-test_kiali.sh](../docs/en/integration/observability/runme-test_kiali.sh)                                                                                                                     | `./run.sh --file kiali`                                                      |
| Bookinfo 应用部署            | [runme-test_deploying-the-bookinfo-application.sh](../docs/en/installing/installing-service-mesh/application-deployment/runme-test_deploying-the-bookinfo-application.sh)                           | `./run.sh --file deploying-the-bookinfo-application`                         |
| Kiali 卸载                   | [runme-test_uninstalling-alauda-build-of-kiali.sh](../docs/en/uninstalling/runme-test_uninstalling-alauda-build-of-kiali.sh)                                                                        | `./run.sh --file uninstalling-alauda-build-of-kiali`                         |
| 网格卸载                     | [runme-test_uninstalling-alauda-service-mesh.sh](../docs/en/uninstalling/runme-test_uninstalling-alauda-service-mesh.sh)                                                                            | `./run.sh --file uninstalling-alauda-service-mesh`                           |
| InPlace 更新策略             | [runme-test_update-inplace.sh](../docs/en/updating/update-mesh/runme-test_update-inplace.sh)                                                                                                        | `./run.sh --file update-inplace`                                             |
| Ambient Mode 安装            | [runme-test_installing-ambient-mode.sh](../docs/en/installing/ambient-mode/runme-test_installing-ambient-mode.sh)                                                                                   | `./run.sh --file installing-ambient-mode`                                    |
| Ambient Bookinfo 部署        | [runme-test_deploying-ambient-bookinfo.sh](../docs/en/installing/ambient-mode/runme-test_deploying-ambient-bookinfo.sh)                                                                             | `./run.sh --file deploying-ambient-bookinfo`                                 |
| Waypoint 代理部署            | [runme-test_waypoint-proxies.sh](../docs/en/installing/ambient-mode/runme-test_waypoint-proxies.sh)                                                                                                 | `./run.sh --file waypoint-proxies`                                           |
| Ambient L7 特性              | [runme-test_ambient-l7-features.sh](../docs/en/installing/ambient-mode/runme-test_ambient-l7-features.sh)                                                                                           | `./run.sh --file ambient-l7-features`                                        |
| Ambient Gateway API          | [runme-test_exposing-a-service-via-k8s-gateway-api-in-ambient-mode.sh](../docs/en/gateways/directing-traffic-into-the-mesh/runme-test_exposing-a-service-via-k8s-gateway-api-in-ambient-mode.sh)    | `./run.sh --file exposing-a-service-via-k8s-gateway-api-in-ambient-mode`     |
| Ambient Egress Gateway       | [runme-test_routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode.sh](../docs/en/gateways/directing-outbound-traffic/runme-test_routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode.sh) | `./run.sh --file routing-egress-traffic-via-k8s-gateway-api-in-ambient-mode` |
| Ambient 模式网格卸载         | [runme-test_uninstalling-alauda-service-mesh-in-ambient-mode.sh](../docs/en/uninstalling/runme-test_uninstalling-alauda-service-mesh-in-ambient-mode.sh)                                            | `./run.sh --file uninstalling-alauda-service-mesh-in-ambient-mode`           |
| 多集群 - 配置概述（CA 证书） | [runme-test_configuration-overview.sh](../docs/en/installing/multi-cluster/runme-test_configuration-overview.sh)                                                                                    | `./run.sh --file configuration-overview`                                     |
| 多集群 - 多主多网络          | [runme-test_install-multi-primary-multi-network.sh](../docs/en/installing/multi-cluster/runme-test_install-multi-primary-multi-network.sh)                                                          | `./run.sh --file install-multi-primary-multi-network`                        |
| 多集群 - 主-远多网络         | [runme-test_install-primary-remote-multi-network.sh](../docs/en/installing/multi-cluster/runme-test_install-primary-remote-multi-network.sh)                                                        | `./run.sh --file install-primary-remote-multi-network`                       |

> **注意**：后续会逐步添加更多文档的自动化测试。
>
> **Waypoint 代理部署**测试暂未覆盖 "Enabling cross-namespace waypoint usage" 部分，后续补充。
>
> **多集群 multi-cluster 测试** 需要 `EAST_CLUSTER_NAME` 与 `WEST_CLUSTER_NAME` 双集群环境。运行前需先用 `./run.sh --init-only --cluster "$EAST_CLUSTER_NAME" --cluster "$WEST_CLUSTER_NAME"` 初始化双集群 kubeconfig；并需先执行 `./run.sh --file configuration-overview` 完成两个集群上的 cacerts 下发，然后才能运行 `install-multi-primary-multi-network` 或 `install-primary-remote-multi-network`。

## 工作原理

### 1. runme 工具

测试框架使用 [runme](https://runme.dev) 工具来执行 MDX 文档中的代码块。runme 可以：

- 解析 MDX 文件中带有 `{name=xxx}` 属性的代码块
- 通过 `runme run <block-name>` 执行指定代码块
- 通过 `runme print <block-name>` 获取代码块内容（用于期待输出）

### 2. 测试脚本结构

每个测试脚本包含两个主要函数：

- `test_<name>()` - 执行测试步骤和验证
- `cleanup_<name>()` - 清理测试资源

### 3. 验证工具

测试脚本使用 `tests/util/verify.sh` 中的验证函数来比较输出：

- `__cmp_same` - 精确匹配
- `__cmp_contains` - 包含子串
- `__cmp_like` - 模糊匹配（忽略动态值如 IP、时间等，目前有问题，暂时不要使用）
- `__cmp_regex` - 正则表达式匹配
- 更多函数请查看 [verify.sh](./util/verify.sh)

## 编写新的测试脚本

推荐使用 Claude Code 的 `/auto-test-creator` skill 来自动生成测试脚本。该 skill 会自动完成以下所有步骤：

1. 分析目标 MDX 文档中的代码块
2. 为代码块添加 `{name=prefix:action}` 属性（如缺失）
3. 生成测试脚本（覆盖所有命名代码块）
4. 更新本文档的测试文档表格
5. 更新 `run-all.sh` 编排脚本
6. 设置可执行权限

### 使用方法

在 Claude Code 中，指定要测试的 MDX 文档路径即可：

```
/auto-test-creator 为 docs/en/path/to/your-doc.mdx 创建自动化测试
```

Skill 定义文件位于 `.claude/skills/auto-test-creator/SKILL.md`，其中包含完整的命名规范、测试模式和公共函数说明。

## 故障排除

### 问题：找不到 runme 或 violet 命令

**解决方法**：执行环境初始化

```bash
./run.sh --init-only
```

### 问题：插件包上传失败

**可能原因**：

1. 网络连接问题
2. 平台凭据错误
3. 集群配置错误

**解决方法**：

1. 检查网络连接
2. 验证 `PLATFORM_ADDRESS`、`PLATFORM_USERNAME`、`PLATFORM_PASSWORD` 环境变量
3. 验证集群配置

### 问题：kubeconfig 获取失败 / 401 Unauthorized

**可能原因**：

1. `ACP_API_TOKEN` 未设置或已过期
2. `PLATFORM_ADDRESS` 不可访问
3. 集群名称错误（需要与 ACP 平台中的集群名一致）
4. `ACP_KUBECONFIG_MODE=direct` 但测试机无法直连 K8s API Server

**解决方法**：

1. 在 ACP UI 上重新生成 API token，更新 `ACP_API_TOKEN` 环境变量
2. 验证 `curl -k -H "Authorization: Bearer $ACP_API_TOKEN" "$PLATFORM_ADDRESS/auth/v1/clusters/$SINGLE_CLUSTER_NAME/kubeconfig"` 是否能正常返回 JSON
3. 切换到 `ACP_KUBECONFIG_MODE=proxy` 重试

### 问题：kubectl 找不到 context

**可能原因**：集群名称变量（`SINGLE_CLUSTER_NAME` / `EAST_CLUSTER_NAME` / `WEST_CLUSTER_NAME`）变更后未重新初始化。

**解决方法**：再次执行 `./run.sh --init-only`（或 `--cluster <name>`），框架会通过 fingerprint 检测到变更并自动重拉。

### 问题：测试执行失败

**调试步骤**：

1. 查看详细错误信息
2. 手动执行失败的 runme 命令：
   ```bash
   runme run <block-name>
   ```
3. 检查 Kubernetes 集群状态
4. 查看相关资源的日志

### 问题：cleanup 失败

**解决方法**：

手动清理资源或使用 `--cleanup-only` 重试：

```bash
./run.sh --file install-mesh-in-dual-stack-mode --cleanup-only
```

## 最佳实践

1. **首次运行**：先执行 `--init-only` 初始化环境
2. **测试所有文档**：使用 `./run-all.sh` 脚本（自动执行初始化并按顺序测试）
3. **测试单个文档**：
   - 如果环境已初始化，直接使用 `--file` 参数（默认不重新初始化）
   - 如果需要重新初始化，添加 `--force-init` 参数
4. **开发调试**：使用 `--no-cleanup` 保留资源以便调试
5. **CI/CD 集成**：
   - 使用 `./run-all.sh` 测试所有文档
   - 双栈环境设置 `IS_DUAL_STACK=true`

## 参考资料

- [runme 官方文档](https://runme.dev)
- [Istio 文档测试](https://github.com/istio/istio.io/blob/master/tests/README.md)
- [Sail Operator 文档测试](https://github.com/istio-ecosystem/sail-operator/blob/main/docs/README.adoc)

## TODO

- [x] 通过 ACP API 自动获取 kubeconfig（替代手动下载）
- [x] PLATFORM_CA 自动获取（init 时从 Global 集群拉取 cpaas-system/dex.tls）
- [ ] Multus 集群插件自动安装
- [ ] MetalLB 集群插件自动安装
- [x] multi-cluster 文档自动化测试
- [ ] 逐步补充其他测试文档
- [ ] 优化测试 case 结果统计
