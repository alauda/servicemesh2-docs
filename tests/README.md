# 文档自动化测试框架

基于 runme 工具的 MDX 文档自动化测试框架，用于验证文档中的命令和步骤是否正确可执行。

## 目录结构

```
tests/
├── run.sh                 # 测试执行入口脚本
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

测试框架会自动检查并安装必要的工具，但以下工具需要预先安装：

- `kubectl` - Kubernetes 命令行工具
- `curl` - 用于下载工具和插件包
- `jq` - JSON 处理工具

### 2. 设置 kubectl 环境

```bash
# 从 ACP 平台下载集群 kubeconfig 文件

# 修改 kubeconfig 文件中的 context 名称（必须和集群名称相同 ）
kubectl --kubeconfig=/path/to/kubeconfig.yaml config rename-context proxy-connect <cluster-name>

# 设置 Kubernetes 环境变量（多个文件以英文冒号分隔）
export KUBECONFIG=/path/to/kubeconfig.yaml
```

### 3. 设置环境变量

在执行测试前，需要设置以下环境变量：

```bash
# 集群名称（根据实际情况设置，可选）
export SINGLE_CLUSTER_NAME=my-cluster      # 单集群网格的集群名称
export EAST_CLUSTER_NAME=east-cluster      # 多集群网格的 East 集群名称
export WEST_CLUSTER_NAME=west-cluster      # 多集群网格的 West 集群名称

# 平台信息
export PLATFORM_ADDRESS=https://xxx
export PLATFORM_USERNAME='your-username'
export PLATFORM_PASSWORD='your-password'

# 双栈环境标识（可选，默认为 false）
export IS_DUAL_STACK=false  # 设置为 true 表示双栈环境

# 工具版本
export RUNME_VERSION=3.16.4

# 镜像加速地址（可选，用于替换默认镜像地址）
export REGISTRY_MIRROR_ADDRESS=  # 留空表示不使用镜像加速

# 插件包下载地址
export PKG_SERVICEMESH_OPERATOR2_URL=xxx
export PKG_KIALI_OPERATOR_URL=xxx
export PKG_JAEGER_OPERATOR_URL=xxx
export PKG_OPENTELEMETRY_OPERATOR_URL=xxx
export PKG_METALLB_OPERATOR_URL=xxx
```

## 使用方法

### 基本命令

```bash
cd tests

# 查看帮助信息
./run.sh --help

# 只执行环境初始化（首次运行或环境变更时）
./run.sh --init-only

# 测试所有文档（自动执行初始化，按预定义顺序执行）
./run.sh --all

# 测试指定文档（默认不执行初始化）
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

### --all 参数说明

`--all` 参数会按照预定义的顺序执行所有测试任务，而不是自动查找所有测试脚本。这样可以更好地控制测试执行顺序。

**执行流程**：

1. **环境初始化**：自动执行环境初始化（无需手动指定 `--force-init`）
2. **双栈测试**：如果 `IS_DUAL_STACK=true`，执行 `install-mesh-in-dual-stack-mode` 测试
3. **网格安装测试**：如果 `IS_DUAL_STACK!=true`，执行 `install-mesh` 测试
4. **其他测试**：预留位置，后续可添加更多测试任务

**添加新的测试任务**：

编辑 `run.sh` 文件，在 `--all` 参数处理部分添加新的测试任务：

```bash
# 在 run.sh 的 test_files 数组中添加
test_files+=(\"your-new-test-task\")
```

## 当前已有的测试文档

| 文档名称     | 测试脚本                                                                                                                        | 执行命令                                          |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| 网格安装     | [runme-test_install-mesh.sh](../docs/en/installing/installing-service-mesh/runme-test_install-mesh.sh)                          | `./run.sh --file install-mesh`                    |
| 双栈网格安装 | [runme-test_install-mesh-in-dual-stack-mode.sh](../docs/en/installing/dual-stack/runme-test_install-mesh-in-dual-stack-mode.sh) | `./run.sh --file install-mesh-in-dual-stack-mode` |

> **注意**：后续会逐步添加更多文档的自动化测试。

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
- `__cmp_like` - 模糊匹配（忽略动态值如 IP、时间等）
- `__cmp_regex` - 正则表达式匹配
- 更多函数请查看 [verify.sh](./util/verify.sh)

## 编写新的测试脚本

### 1. 确保文档中的代码块有名称

在 MDX 文档中，为需要测试的代码块添加 `{name=xxx}` 属性：

````markdown
```bash {name=my-test:create-resource}
kubectl create namespace test
```
````

### 2. 创建测试脚本

在文档同目录下创建 `runme-test_<文档名>.sh` 文件：

```bash
#!/usr/bin/env bash
# 测试脚本描述

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# 测试函数
test_my_feature() {
    log_info "开始测试..."

    # 执行文档中的代码块
    runme run my-test:create-resource || {
        log_error "创建资源失败"
        return 1
    }

    # 验证输出
    local output expected
    output=$(runme run my-test:verify)
    expected=$(runme print my-test:verify-output)

    if ! __cmp_contains "$output" "$expected"; then
        log_error "验证失败"
        return 1
    fi
    log_success "测试通过"
    return 0
}

# cleanup 函数
cleanup_my_feature() {
    log_info "清理资源..."
    runme run my-test:cleanup
    return 0
}
```

### 3. 添加可执行权限

```bash
chmod +x runme-test_<文档名>.sh
```

### 4. 更新 README.md

在"当前已有的测试文档"表格中添加新的测试条目。

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
2. **测试所有文档**：使用 `--all` 参数（自动执行初始化并按顺序测试）
3. **测试单个文档**：
   - 如果环境已初始化，直接使用 `--file` 参数（默认不重新初始化）
   - 如果需要重新初始化，添加 `--force-init` 参数
4. **开发调试**：使用 `--no-cleanup` 保留资源以便调试
5. **CI/CD 集成**：
   - 使用 `--all` 测试所有文档
   - 双栈环境设置 `IS_DUAL_STACK=true`

## 参考资料

- [runme 官方文档](https://runme.dev)
- [Istio 文档测试](https://github.com/istio/istio.io/blob/master/tests/README.md)
- [Sail Operator 文档测试](https://github.com/istio-ecosystem/sail-operator/blob/main/docs/README.adoc)

## TODO

- [ ] 多集群 kubecontext 管理
- [ ] Multus 集群插件自动安装
- [ ] MetalLB 集群插件自动安装
- [ ] 逐步补充其他测试文档
