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
# 用法: apply_with_mirror <runme-block-name>
# 说明: 
#   - 使用 runme print 获取代码块内容
#   - 如果设置了 REGISTRY_MIRROR_ADDRESS，则替换默认镜像地址为镜像加速地址
#   - 执行 kubectl apply
apply_with_mirror() {
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
}