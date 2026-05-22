#!/usr/bin/env bash
# Istio CNI 升级文档测试脚本
# 依赖：上游 update-inplace --no-cleanup 已铺垫好 IstioCNI v1.26.3 + Istio 控制平面 v1.28.6
# 清理：由下游 update-inplace --cleanup-only 统一回收，故本脚本无 cleanup 函数

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

test_istio_cni() {
    log_info "=========================================="
    log_info "开始 Istio CNI 升级测试"
    log_info "=========================================="

    local output

    # 1. 升级 IstioCNI 版本到 v1.28.6
    log_info "步骤 1: 升级 IstioCNI 版本到 v1.28.6"
    runme run update-istio-cni:patch-version || {
        log_error "升级 IstioCNI 版本失败"
        return 1
    }
    sleep 0.5

    # 2. 等待 IstioCNI DaemonSet Ready
    log_info "步骤 2: 等待 IstioCNI DaemonSet 就绪"
    runme run update-istio-cni:wait-ready || {
        log_error "等待 IstioCNI DaemonSet 就绪失败"
        return 1
    }

    # 3. 验证 IstioCNI 状态（输出包含动态 AGE 值，使用 __cmp_lines 验证关键字段）
    log_info "步骤 3: 验证 IstioCNI 状态"
    output=$(runme run update-istio-cni:get-istiocni 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ default
+ istio-cni
+ True
+ Healthy
+ v1.28.6
EOF
    )"; then
        log_error "验证 IstioCNI 状态失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "IstioCNI 状态验证通过"

    # 4. 验证 istio-cni-node Pod 状态（输出包含动态 pod 名后缀和 AGE，使用 __cmp_lines 验证关键字段）
    log_info "步骤 4: 验证 istio-cni-node Pod 状态"
    output=$(runme run update-istio-cni:get-pods 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ istio-cni-node
+ 1/1
+ Running
EOF
    )"; then
        log_error "验证 istio-cni-node Pod 状态失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "istio-cni-node Pod 状态验证通过"

    log_success "=========================================="
    log_success "Istio CNI 升级测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
