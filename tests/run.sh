#!/usr/bin/env bash
# 测试执行入口脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UTIL_DIR="$SCRIPT_DIR/util"
BIN_DIR="$SCRIPT_DIR/bin"

# 加载公共函数
source "$UTIL_DIR/common.sh"

# 将 bin 目录添加到 PATH
export PATH="$BIN_DIR:$PATH"

# 默认参数
RUN_FILES=()
NO_CLEANUP=false
CLEANUP_ONLY=false
INIT_ONLY=false
FORCE_INIT=false

# 双栈环境标识，默认为 false
IS_DUAL_STACK=${IS_DUAL_STACK:-false}

# 使用说明
usage() {
    cat <<EOF
使用方法: $0 [选项]

选项:
  --file <name>         测试指定文档（可指定多次，默认不执行初始化）
  --no-cleanup          不执行 cleanup 操作
  --cleanup-only        只执行 cleanup 操作
  --init-only           只执行环境初始化，不运行测试
  --force-init          强制执行环境初始化（用于 --file 模式）
  -h, --help            显示此帮助信息

  # 测试指定文档（不执行初始化）
  $0 --file install-mesh-in-dual-stack-mode

  # 测试指定文档并强制执行初始化
  $0 --file install-mesh-in-dual-stack-mode --force-init

  # 测试多篇文档
  $0 --file install-mesh-in-dual-stack-mode --file another-doc

  # 不执行 cleanup
  $0 --file install-mesh-in-dual-stack-mode --no-cleanup

  # 只执行 cleanup
  $0 --file install-mesh-in-dual-stack-mode --cleanup-only

  # 只初始化环境
  $0 --init-only

环境变量:
  必须设置以下环境变量:
    KUBECONFIG
    SINGLE_CLUSTER_NAME (可选)
    EAST_CLUSTER_NAME (可选)
    WEST_CLUSTER_NAME (可选)
    PLATFORM_ADDRESS
    PLATFORM_USERNAME
    PLATFORM_PASSWORD
    RUNME_VERSION
    PKG_SERVICEMESH_OPERATOR2_URL
    PKG_KIALI_OPERATOR_URL
    PKG_JAEGER_OPERATOR_URL
    PKG_OPENTELEMETRY_OPERATOR_URL
    PKG_METALLB_OPERATOR_URL
    IS_DUAL_STACK (可选，默认为 false，设置为 true 表示双栈环境)
EOF
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in

            --file)
                RUN_FILES+=("$2")
                shift 2
                ;;
            --no-cleanup)
                NO_CLEANUP=true
                shift
                ;;
            --cleanup-only)
                CLEANUP_ONLY=true
                shift
                ;;
            --init-only)
                INIT_ONLY=true
                shift
                ;;
            --force-init)
                FORCE_INIT=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# 检查必要的环境变量
check_env() {
    local required_vars=(
        "RUNME_VERSION"
        "PLATFORM_ADDRESS"
        "PLATFORM_USERNAME"
        "PLATFORM_PASSWORD"
        "PKG_SERVICEMESH_OPERATOR2_URL"
        "PKG_KIALI_OPERATOR_URL"
        "PKG_JAEGER_OPERATOR_URL"
        "PKG_OPENTELEMETRY_OPERATOR_URL"
        "PKG_METALLB_OPERATOR_URL"
    )
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    # 检查集群配置
    if [ -z "$SINGLE_CLUSTER_NAME" ] && [ -z "$EAST_CLUSTER_NAME" ] && [ -z "$WEST_CLUSTER_NAME" ]; then
        log_warn "未配置任何集群 (SINGLE_CLUSTER_NAME, EAST_CLUSTER_NAME, WEST_CLUSTER_NAME)"
    fi
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        log_error "缺少必要的环境变量: ${missing_vars[*]}"
        log_error "请参考 --help 了解所需环境变量"
        exit 1
    fi
}

# 查找所有测试脚本
find_all_test_scripts() {
    find "$REPO_ROOT/docs/en" -type f -name "runme-test_*.sh"
}

# 执行单个测试脚本
run_test_script() {
    local test_script="$1"
    local script_name
    script_name=$(basename "$test_script")
    
    log_header "执行测试: $script_name"
    
    # 加载测试脚本
    source "$test_script"
    
    # 查找测试函数和 cleanup 函数
    local test_func cleanup_func
    test_func=$(declare -F | awk '$3 ~ /^test_[a-z_]+$/ && $3 !~ /test_scripts/ {print $3; exit}')
    cleanup_func=$(declare -F | awk '$3 ~ /^cleanup_[a-z_]+$/ {print $3; exit}')
    
    if [ -z "$test_func" ]; then
        log_error "在 $script_name 中未找到测试函数 (test_*)"
        record_test_result 1
        return 1
    fi
    
    # 只执行 cleanup
    if [ "$CLEANUP_ONLY" = true ]; then
        if [ -n "$cleanup_func" ]; then
            log_info "执行 cleanup: $cleanup_func"
            if $cleanup_func; then
                log_success "Cleanup 成功"
                record_test_result 0
                return 0
            else
                log_error "Cleanup 失败"
                record_test_result 1
                return 1
            fi
        else
            log_warn "未找到 cleanup 函数"
            return 0
        fi
    fi
    
    # 执行测试
    log_info "执行测试函数: $test_func"
    local test_result=0
    if ! $test_func; then
        log_error "测试失败: $test_func"
        test_result=1
    else
        log_success "测试通过: $test_func"
    fi
    
    # 执行 cleanup
    if [ "$NO_CLEANUP" = false ] && [ -n "$cleanup_func" ]; then
        log_info "执行 cleanup: $cleanup_func"
        if ! $cleanup_func; then
            log_warn "Cleanup 失败，但不影响测试结果"
        fi
    fi
    
    record_test_result "$test_result"
    return "$test_result"
}

# 主函数
main() {
    parse_args "$@"
    
    log_info "文档自动化测试框架"
    echo ""
    
    # 检查环境变量
    check_env
    
    # 环境初始化
    # --file 模式默认不执行初始化
    local should_init=false
    
    if [ "$INIT_ONLY" = true ]; then
        should_init=true
    elif [ "$FORCE_INIT" = true ]; then
        # --file 模式且指定了 --force-init
        should_init=true
    fi
    
    if [ "$should_init" = true ]; then
        log_info "执行环境初始化..."
        source "$UTIL_DIR/init.sh"
        main  # 调用 init.sh 的 main 函数
        
        if [ "$INIT_ONLY" = true ]; then
            log_success "环境初始化完成，退出（--init-only）"
            exit 0
        fi
    else
        log_info "跳过环境初始化（默认不执行，可使用 --force-init 强制执行）"
    fi
    
    # 确定要运行的测试
    local test_scripts=()
    
    if [ ${#RUN_FILES[@]} -gt 0 ]; then
        for file in "${RUN_FILES[@]}"; do
            local script_path
            script_path=$(find "$REPO_ROOT/docs/en" -type f -name "runme-test_${file}.sh" | head -n 1)
            
            if [ -z "$script_path" ]; then
                log_error "未找到测试脚本: runme-test_${file}.sh"
                exit 1
            fi
            
            test_scripts+=("$script_path")
        done
    else
        log_error "请指定 --file 参数"
        usage
        exit 1
    fi
    
    # 执行测试
    echo ""
    log_info "开始执行测试..."
    echo ""
    
    for script in "${test_scripts[@]}"; do
        run_test_script "$script"
        echo ""
    done
    
    # 打印测试总结
    print_test_summary
}

# 执行主函数
main "$@"
