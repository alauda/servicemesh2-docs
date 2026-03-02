---
name: auto-test-creator
description: >
  为 MDX 文档创建自动化测试脚本。当用户需要为文档编写测试、创建 runme 测试脚本、
  或提到"文档测试"、"自动化测试"、"测试脚本"时使用此 skill。
  适用于：为 docs/en/ 目录下的 MDX 文档创建 runme-test_*.sh 测试脚本、
  为 MDX 代码块添加 name 属性、更新测试文档表格和测试编排脚本。
---

# auto-test-creator: MDX 文档自动化测试脚本生成器

为项目中的 MDX 文档生成自动化测试脚本，确保文档中的命令和步骤可执行且输出正确。

## 工作流程

### 第一步：分析目标 MDX 文档

1. 读取用户指定的 MDX 文档文件
2. 提取所有代码块，分析哪些需要测试
3. 确认代码块是否已有 `{name=prefix:action}` 属性
4. 如果代码块缺少 name 属性，需要先添加

### 第二步：为 MDX 代码块添加 name 属性

**命名规范：**

- 格式：`{name=前缀:操作名}`
- 前缀从文档功能模块派生，使用连字符连接（如 `dual-stack`、`install-mesh`、`config-kiali`）
- 操作名描述代码块的具体操作（如 `create-istio`、`verify-config`、`deploy-application`）
- 同一文档中所有代码块使用相同前缀
- **输出验证代码块**：名称以 `-output` 结尾，与对应命令块配对

**示例：**

```markdown
<!-- 命令代码块 -->
```bash {name=my-feature:create-resource}
kubectl create namespace test
\```

<!-- 对应的期望输出代码块 -->
```text {name=my-feature:create-resource-output}
namespace/test created
\```
```

**重要注意事项：**
- 每个需要测试的代码块都必须有 name 属性
- 需要验证输出的命令，必须有配对的 `-output` 代码块
- 代码块类型可以是 `bash`、`shell`、`yaml`、`text`、`html` 等
- YAML 文件内容代码块可以用 `name` 标记以便 `runme print` 获取内容

### 第三步：创建测试脚本

在 MDX 文档同目录下创建 `runme-test_<文档名>.sh` 文件。

**脚本模板：**

```bash
#!/usr/bin/env bash
# <文档描述>测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/<相对路径>" && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

test_<feature_name>() {
    log_info "=========================================="
    log_info "开始 <功能名称> 测试"
    log_info "=========================================="

    # 测试步骤...

    log_success "=========================================="
    log_success "<功能名称> 测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# 仅在文档包含清理步骤时才添加 cleanup 函数
cleanup_<feature_name>() {
    log_info "=========================================="
    log_info "清理 <功能名称> 测试资源"
    log_info "=========================================="

    runme run <prefix>:cleanup || {
        log_error "清理资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
```

### 关键规则

#### REPO_ROOT 路径计算

根据脚本在项目中的深度计算相对路径（从 `docs/en/` 开始算起）：

| 脚本目录深度 | 示例路径 | REPO_ROOT |
|------------|---------|-----------|
| 3 级 | `docs/en/uninstalling/` | `$SCRIPT_DIR/../../..` |
| 4 级 | `docs/en/installing/dual-stack/` | `$SCRIPT_DIR/../../../..` |
| 5 级 | `docs/en/installing/.../application-deployment/` | `$SCRIPT_DIR/../../../../..` |

**计算方法**：从脚本所在目录数回到仓库根目录需要几层 `..`。

#### 测试步骤模式

**模式 A - 执行命令并检查返回值：**

```bash
log_info "步骤 X: <步骤描述>"
runme run <prefix>:<action> || {
    log_error "<操作>失败"
    return 1
}
```

**模式 B - 执行命令并验证输出（使用 -output 配对代码块）：**

```bash
log_info "步骤 X: <步骤描述>"
local output expected
output=$(runme run <prefix>:<action>)
expected=$(runme print <prefix>:<action>-output)

if ! __cmp_contains "$output" "$expected"; then
    log_error "<验证>失败"
    log_error "期待输出: $expected"
    log_error "实际输出: $output"
    return 1
fi
log_success "<验证>通过"
```

**模式 C - 获取模板内容并写入文件：**

```bash
log_info "步骤 X: 生成配置文件"
runme print <prefix>:<template-name> > "/tmp/<filename>" || {
    log_error "获取模板失败"
    return 1
}
```

**模式 D - 使用 kubectl_apply_with_mirror（部署含镜像的资源）：**

```bash
log_info "步骤 X: 部署应用"
kubectl_apply_with_mirror <prefix>:<deploy-action> || {
    log_error "部署失败"
    return 1
}
```

**模式 E - 使用 kubectl_apply_runme_block（在指定目录执行）：**

```bash
log_info "步骤 X: 应用配置"
kubectl_apply_runme_block "<prefix>:<apply-action>" "/tmp/" || {
    log_error "应用配置失败"
    return 1
}
```

**模式 F - 使用 eval 执行设置环境变量：**

```bash
log_info "步骤 X: 获取配置"
eval "$(runme print <prefix>:<get-config>)" || {
    log_error "获取配置失败"
    return 1
}
```

**模式 G - 使用 install_operator 安装 Operator：**

```bash
install_operator \
    "<operator-name>" \
    "<namespace>" \
    "$PKG_<OPERATOR>_URL" \
    "<runme-prefix>"
```

#### 可用的公共工具函数

来自 `tests/util/common.sh`：

| 函数 | 用途 |
|------|------|
| `log_info/warn/error/success` | 日志输出 |
| `kubectl_apply_with_mirror` | 带镜像加速的 kubectl apply |
| `kubectl_apply_runme_block` | 在指定目录中执行 runme block |
| `_wait_for_deployment` | 等待 Deployment 就绪 |
| `_wait_for_resource` | 等待资源创建 |
| `retry_command` | 重试执行命令 |
| `install_operator` | 通用 Operator 安装 |

来自 `tests/util/verify.sh`：

| 函数 | 用途 |
|------|------|
| `__cmp_same` | 精确匹配 |
| `__cmp_contains` | 包含子串 |
| `__cmp_not_contains` | 不包含子串 |
| `__cmp_elided` | 模糊匹配（支持 `...` 通配符） |
| `__cmp_regex` | 正则匹配 |
| `__cmp_first_line` | 首行匹配 |
| `__cmp_lines` | 逐行验证（`+` 必须包含，`-` 不能包含） |

**注意**：`__cmp_like` 目前有问题，不要使用。

#### 100% 测试覆盖率

测试脚本必须覆盖 MDX 文档中所有带 `{name=}` 属性的代码块：
- 所有命令代码块都必须通过 `runme run` 执行
- 所有输出代码块都必须通过 `runme print` 获取并用于验证
- 不能遗漏任何代码块

**严格遵守文档边界**：测试脚本只测试文档中存在的代码块，不要自行添加额外的验证步骤（如额外的 kubectl get 命令）。测试的目的是验证文档中的命令是否可执行且输出正确，而不是编写端到端测试。

#### cleanup 函数判断

只有当 MDX 文档中明确包含清理/卸载步骤的代码块（如名为 `<prefix>:cleanup` 的代码块），或者文档本身就是清理类文档时，才在测试脚本中添加 `cleanup_*` 函数。不要自行编写清理逻辑。

#### 处理动态占位符

某些文档中的命令包含动态占位符（如 `<name_of_custom_resource>`），需要在测试脚本中动态替换。

**模式 H - 动态占位符替换：**

当文档中的命令包含占位符（如 `<xxx>`），需要先从前序命令的输出中提取实际值，然后替换模板中的占位符再执行：

```bash
# 1. 执行前序命令获取实际值
log_info "步骤 X: 获取资源名称"
local resource_output
resource_output=$(runme run <prefix>:get-resource 2>&1) || {
    log_error "获取资源失败"
    return 1
}

# 2. 从输出中提取实际资源名称
local resource_name
resource_name=$(echo "$resource_output" | awk 'NR==2 {print $1}')

# 3. 获取命令模板，替换占位符后执行
log_info "步骤 Y: 删除资源"
local delete_cmd
delete_cmd=$(runme print <prefix>:delete-resource)
delete_cmd="${delete_cmd//<placeholder>/$resource_name}"
local delete_output
delete_output=$(eval "$delete_cmd" 2>&1) || {
    log_error "删除资源失败"
    return 1
}

# 4. 验证输出（输出模板中的占位符也需要替换）
local expected_output
expected_output=$(runme print <prefix>:delete-resource-output)
expected_output="${expected_output//<placeholder>/$resource_name}"
if ! __cmp_contains "$delete_output" "$expected_output"; then
    log_error "验证失败"
    return 1
fi
```

**识别占位符的方法**：阅读 MDX 文档时，注意命令中用尖括号 `<>` 包裹的内容。如果文档说"用前一步的输出替换 `<xxx>`"，则需要在脚本中实现动态替换。

#### 捕获 stderr

对于可能输出到 stderr 的命令（如 kubectl），使用 `2>&1` 确保完整捕获输出：

```bash
output=$(runme run <prefix>:<action> 2>&1) || {
    log_error "操作失败"
    log_error "输出: $output"
    return 1
}
```

### 第四步：更新测试文档表格

编辑 `tests/README.md`，在 "当前已有的测试文档" 表格中添加新条目：

```markdown
| <文档名称> | [runme-test_<文档名>.sh](<相对路径>) | `./run.sh --file <文档名>` |
```

### 第五步：更新测试编排脚本

编辑 `tests/run-all.sh`，在合适的位置添加新的测试 case 或加入已有 case。

**添加到已有 case（如 Case 3）：**

```bash
# 在 Case 3 的 if ( ... ) 块中添加
./run.sh --file <new-test-name>
```

**创建新的 case：**

```bash
# ------------------------------------------------------------------
# Case N: <测试描述>
# ------------------------------------------------------------------
log_header "Case N: <测试描述>"

if (
    set -e
    ./run.sh --file <test-name>
); then
    record_test_result 0
else
    record_test_result 1
    exit 1
fi
```

### 第六步：设置可执行权限

```bash
chmod +x <测试脚本路径>
```

## 参考文件

如需更详细的信息，请参阅：

- `tests/README.md` - 测试框架完整说明
- `tests/util/common.sh` - 公共工具函数源码
- `tests/util/verify.sh` - 验证函数源码
- `tests/run.sh` - 测试执行器
- `tests/run-all.sh` - 测试编排脚本

## 已有测试脚本参考

以下是项目中已有的测试脚本，可作为编写新脚本的参考：

- `docs/en/installing/dual-stack/runme-test_install-mesh-in-dual-stack-mode.sh`
- `docs/en/installing/installing-service-mesh/runme-test_install-mesh.sh`
- `docs/en/installing/installing-service-mesh/application-deployment/runme-test_deploying-the-bookinfo-application.sh`
- `docs/en/integration/observability/runme-test_metrics-and-mesh.sh`
- `docs/en/integration/observability/runme-test_kiali.sh`
- `docs/en/uninstalling/runme-test_uninstalling-alauda-build-of-kiali.sh`
- `docs/en/uninstalling/runme-test_uninstalling-alauda-service-mesh.sh`
