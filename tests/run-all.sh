#!/usr/bin/env bash
# 自动化测试执行总入口脚本
# 该脚本按照预定义顺序执行所有测试任务

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTIL_DIR="$SCRIPT_DIR/util"

# 加载公共函数
source "$UTIL_DIR/common.sh"

# 确保在脚本所在目录执行
cd "$SCRIPT_DIR"

# 注册退出时的回调函数，无论成功还是因错误退出，都会打印测试总结
trap print_test_summary EXIT

log_header "开始执行所有测试任务"

# ------------------------------------------------------------------
# Case 1: 环境初始化
# ------------------------------------------------------------------
log_header "Case 1: 环境初始化"

if (
    set -e
    ./run.sh --init-only
); then
    record_test_result 0
else
    record_test_result 1
    # 失败则直接退出
    exit 1
fi

# ------------------------------------------------------------------
# Case 2: 双栈网格安装
# ------------------------------------------------------------------
if [ "${IS_DUAL_STACK:-false}" == "true" ]; then
    log_header "Case 2: 双栈网格安装测试 (Dual Stack)"
    if (
        set -e
        ./run.sh --file install-mesh-in-dual-stack-mode --no-cleanup
        ./run.sh --file install-mesh-in-dual-stack-mode --cleanup-only
    ); then
        record_test_result 0
    else
        record_test_result 1
        exit 1
    fi
else
    log_header "Case 2: 跳过双栈网格安装测试 (IS_DUAL_STACK != true)"
fi

# ------------------------------------------------------------------
# Case 3: 单网格安装与应用测试
# ------------------------------------------------------------------
log_header "Case 3: 单网格安装与应用测试 (Single Mesh & App)"

# 使用子 shell ( cmds ) 将多个命令组合为一个原子 case
# 任何一个命令失败都会导致整个 block 返回非 0 状态
if (
    set -e
    # 安装网格和应用
    ./run.sh --file install-mesh
    ./run.sh --file metrics-and-mesh
    ./run.sh --file deploying-the-bookinfo-application --no-cleanup
    ./run.sh --file kiali
    # 清理
    ./run.sh --file uninstalling-alauda-build-of-kiali
    ./run.sh --file deploying-the-bookinfo-application --cleanup-only
    ./run.sh --file uninstalling-alauda-service-mesh
); then
    record_test_result 0
else
    record_test_result 1
    exit 1
fi

# ------------------------------------------------------------------
# Case 4: 其他测试任务 (TODO)
# ------------------------------------------------------------------
log_header "Case 4: 其他测试任务 (TODO)"
log_info "TODO: 可以在此处添加更多测试任务"

log_header "所有测试任务执行完成！"

# 注意：print_test_summary 已通过 trap 注册，脚本退出时会自动执行，此处无需再次调用
