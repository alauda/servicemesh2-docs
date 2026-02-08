#!/usr/bin/env bash
# 公共函数库

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志输出函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_header() {
    echo ""
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
    echo ""
}

# 检查必要工具是否存在
check_required_tools() {
    local missing_tools=()
    
    for tool in "$@"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "缺少必要工具: ${missing_tools[*]}"
        log_error "请安装缺少的工具后再试"
        return 1
    fi
    
    return 0
}

# 使用镜像加速地址执行 kubectl apply
# 用法: kubectl_apply_with_mirror <runme-block-name>
# 说明: 
#   - 使用 runme print 获取代码块内容
#   - 如果设置了 REGISTRY_MIRROR_ADDRESS，则替换默认镜像地址为镜像加速地址
#   - 执行 kubectl apply
kubectl_apply_with_mirror() {
    local block_name="$1"
    
    # 使用 runme print 获取命令内容
    local cmd_content
    cmd_content=$(runme print "$block_name" 2>/dev/null)
    
    if [ -z "$cmd_content" ]; then
        log_error "无法获取代码块内容: $block_name"
        return 1
    fi
    
    # 如果设置了镜像加速地址，则替换镜像
    if [ -n "$REGISTRY_MIRROR_ADDRESS" ]; then
        log_info "使用镜像加速地址: $REGISTRY_MIRROR_ADDRESS"
        
        # 从命令中提取 URL
        local url
        url=$(echo "$cmd_content" | grep -oE 'https://[^ ]+\.yaml' | head -n 1)
        
        if [ -z "$url" ]; then
            log_error "无法从命令中提取 YAML 文件 URL"
            return 1
        fi
        
        # 下载 YAML 文件，替换镜像地址，然后应用
        log_info "下载并替换镜像地址: $url"
        curl -sSL "$url" | sed "s|docker\.io|${REGISTRY_MIRROR_ADDRESS}|g" | eval "${cmd_content//-f $url/-f -}"
    else
        # 没有设置镜像加速，直接执行原命令
        eval "$cmd_content"
    fi
}

# 切换到指定目录执行 runme block，然后再切换回来
# 用法: kubectl_apply_runme_block <block_name> [resource_dir]
kubectl_apply_runme_block() {
    local block_name="$1"
    local resource_dir="${2:-/tmp/}"
    
    # 使用 runme print 获取命令内容
    local cmd_content
    cmd_content=$(runme print "$block_name" 2>/dev/null)

    # 使用 pushd/popd 更安全
    pushd "$resource_dir" > /dev/null || return 1
    
    if [ -z "$cmd_content" ]; then
        log_error "无法获取代码块内容: $block_name"
        popd > /dev/null
        return 1
    fi
    
    # 执行命令
    eval "$cmd_content" || {
        log_error "应用 $block_name 失败"
        popd > /dev/null
        return 1
    }
    
    popd > /dev/null
    return 0
}

# 从插件包 URL 解析出 ArtifactVersion 名称
# 用法: parse_artifact_version_from_package <package_url>
# 例如: servicemesh-operator2.stable.ALL.v2.1.0.tgz -> servicemesh-operator2.v2.1.0
parse_artifact_version_from_package() {
    local package_url="$1"
    local filename
    filename=$(basename "$package_url")
    
    # 移除 .stable/.alpha/.beta 和 .ALL/.amd64/.arm64 部分,保留版本号
    echo "$filename" | sed -E 's/\.(stable|alpha|beta)\.(ALL|amd64|arm64)\.v/\.v/' | sed 's/\.tgz$//'
}

# 从插件包 URL 解析出插件 CSV name
# 注意: 当前实现与 parse_artifact_version_from_package 逻辑相同,直接复用
parse_csv_name_from_package() {
    parse_artifact_version_from_package "$1"
}

# 测试结果统计
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

record_test_result() {
    local result=$1
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    
    if [ "$result" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

print_test_summary() {
    echo ""
    echo "========================================"
    echo "测试总结"
    echo "========================================"
    echo "总计: $TESTS_TOTAL"
    echo -e "${GREEN}通过: $TESTS_PASSED${NC}"
    echo -e "${RED}失败: $TESTS_FAILED${NC}"
    echo "========================================"
    
    if [ "$TESTS_FAILED" -eq 0 ]; then
        log_success "所有测试通过!"
        return 0
    else
        log_error "有 $TESTS_FAILED 个测试失败"
        return 1
    fi
}

# Wait for resource to be created
# usage: _wait_for_resource <kind> <namespace> <name>
# refer: https://github.com/istio/istio.io/blob/master/tests/util/helpers.sh#L108
_wait_for_resource() {
    local kind="$1"
    local namespace="$2"
    local name="$3"
    local start_time=$(date +%s)
    if ! kubectl wait --for=create -n "$namespace" "$kind/$name" --timeout 30s; then
        local end_time=$(date +%s)
        echo "Timed out waiting for $kind $name in namespace $namespace to be created."
        echo "Duration: $(( end_time - start_time )) seconds"
        return 1
    fi
    return 0
}

# Wait for rollout of named deployment
# usage: _wait_for_deployment <namespace> <deployment name> <optional: context>
_wait_for_deployment() {
    local namespace="$1"
    local name="$2"
    local context="${3:-}"
    if ! kubectl --context="$context" -n "$namespace" rollout status deployment "$name" --timeout 5m; then
        echo "Failed rollout of deployment $name in namespace $namespace"
        return 1
    fi
    return 0
}

# 重试执行命令
# 用法: retry_command <command> [max_retries] [interval]
retry_command() {
    local command="$1"
    local max_retries="${2:-5}"
    local interval="${3:-10}"
    local count=0
    
    while [ $count -lt $max_retries ]; do
        if eval "$command"; then
            return 0
        fi
        
        count=$((count + 1))
        if [ $count -lt $max_retries ]; then
            log_warn "命令执行失败，等待 ${interval} 秒后重试 ($((count + 1))/$max_retries)..."
            sleep "$interval"
        fi
    done
    
    log_error "命令执行失败，已重试 $max_retries 次"
    return 1
}

# 通用 operator 安装函数
# 用法: install_operator <operator_name> <namespace> <package_url> <runme_prefix>
# 参数:
#   operator_name  - operator 名称 (如 servicemesh-operator2, kiali-operator)
#   namespace      - 安装的 namespace (如 sail-operator, kiali-operator)
#   package_url    - 插件包 URL (用于解析 CSV 名称)
#   runme_prefix   - runme block 前缀 (如 install-mesh, install-kiali)
# NOTE: 调用该函数前请确保已切换到正确的 kubectl context
install_operator() {
    local operator_name="$1"
    local namespace="$2"
    local package_url="$3"
    local runme_prefix="$4"

    # 参数校验
    if [ -z "$operator_name" ] || [ -z "$namespace" ] || [ -z "$package_url" ] || [ -z "$runme_prefix" ]; then
        log_error "install_operator: 缺少必要参数"
        log_error "用法: install_operator <operator_name> <namespace> <package_url> <runme_prefix>"
        return 1
    fi

    log_info "=========================================="
    log_info "安装 $operator_name 到 namespace $namespace"
    log_info "=========================================="

    local csv_name
    csv_name=$(parse_csv_name_from_package "$package_url")

    # 检查是否已经安装
    if kubectl -n "$namespace" get csv "$csv_name" 2>/dev/null; then
        local csv_phase
        csv_phase=$(kubectl -n "$namespace" get csv "$csv_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [ "$csv_phase" = "Succeeded" ]; then
            log_success "$operator_name 已安装"
            return 0
        else
            log_error "$operator_name 存在但状态不是 Succeeded，当前状态: $csv_phase"
            return 1
        fi
    fi

    # 定义 check_packagemanifest_version 内部函数
    _check_packagemanifest_version() {
        local target_csv="$1"
        local prefix="$2"
        local versions_output
        versions_output=$(runme run "${prefix}:check-packagemanifest-versions" 2>/dev/null || echo "")

        if [ -n "$versions_output" ] && echo "$versions_output" | grep -q "$target_csv"; then
            log_success "找到匹配的版本: $target_csv"
            echo "$versions_output"
            return 0
        fi
        return 1
    }

    # 0.1 检查可用版本
    log_info "步骤 0.1: 检查可用版本"
    if ! retry_command "_check_packagemanifest_version $csv_name $runme_prefix" 20 5; then
        log_error "无法找到预期 PackageManifest 资源中的 CSV 内容: $csv_name"
        return 1
    fi

    # 0.2 确认 catalogSource
    log_info "步骤 0.2: 确认 catalogSource"
    local output expected
    output=$(runme run "${runme_prefix}:confirm-catalogsource" 2>/dev/null)
    expected=$(runme print "${runme_prefix}:confirm-catalogsource-output" 2>/dev/null)
    if ! __cmp_contains "$output" "$expected"; then
        log_error "CatalogSource 不匹配,期待: $expected, 实际: $output"
        return 1
    fi
    log_success "CatalogSource 验证通过: $output"

    # 1. 创建命名空间
    log_info "步骤 1: 创建 $namespace 命名空间"
    runme run "${runme_prefix}:create-namespace-${namespace}" || {
        log_error "创建命名空间失败"
        return 1
    }
    log_success "命名空间创建成功"

    # 2. 创建 Subscription
    log_info "步骤 2: 创建 Subscription"
    local subscription_yaml
    subscription_yaml=$(runme print "${runme_prefix}:create-subscription-${operator_name}" 2>/dev/null | \
        sed -E "s/startingCSV: ${operator_name}\\.v.+/startingCSV: $csv_name/")
    if [ -z "$subscription_yaml" ]; then
        log_error "无法获取 Subscription 模板"
        return 1
    fi
    echo "$subscription_yaml" | bash || {
        log_error "创建 Subscription 失败"
        return 1
    }
    log_success "Subscription 创建成功"

    # 3. 等待 InstallPlan 准备就绪
    log_info "步骤 3: 等待 InstallPlan 准备就绪"
    runme run "${runme_prefix}:wait-installplan-pending" || {
        log_error "等待 InstallPlan 超时"
        return 1
    }
    log_success "InstallPlan 已准备就绪"

    # 4. 批准 InstallPlan
    log_info "步骤 4: 批准 InstallPlan"
    runme run "${runme_prefix}:approve-installplan-manual" || {
        log_error "批准 InstallPlan 失败"
        return 1
    }
    log_success "InstallPlan 批准成功"

    # 等待 CSV 资源被创建
    log_info "等待 CSV 资源创建..."
    _wait_for_resource "csv" "$namespace" "$csv_name" || {
        log_warn "等待 CSV 资源创建超时,继续执行..."
    }

    # 5. 等待 CSV 安装完成
    log_info "步骤 5: 等待 CSV 安装完成"
    runme run "${runme_prefix}:wait-csv-succeeded" || {
        log_error "CSV 安装超时或失败"
        log_info "当前 CSV 状态:"
        kubectl -n "$namespace" get csv
        return 1
    }
    log_success "CSV 安装成功"

    # 6. 验证安装
    log_info "步骤 6: 验证安装"
    local csv_output
    csv_output=$(runme run "${runme_prefix}:check-csv-status" 2>/dev/null || echo "")

    if [ -n "$csv_output" ]; then
        log_success "$operator_name 安装验证通过"
        echo "$csv_output"
    else
        log_error "无法获取 CSV 状态"
        return 1
    fi

    log_success "=========================================="
    log_success "$operator_name 安装完成"
    log_success "=========================================="
    return 0
}
