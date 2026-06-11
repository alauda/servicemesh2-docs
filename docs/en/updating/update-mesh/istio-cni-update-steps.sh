#!/usr/bin/env bash
# Istio CNI 升级公共步骤库（对应 istio-cni.mdx 的 update-istio-cni:* 代码块）
#
# 被以下测试脚本 source 复用：
#   - runme-test_istio-cni.sh（独立测试入口）
#   - runme-test_update-inplace.sh（文档步骤 4）
#   - revision-based-strategy/runme-test_update-revisionbased.sh（文档步骤 5）
#   - revision-based-strategy/runme-test_update-revisionbased-and-istiorevisiontag.sh（文档步骤 5）
#
# 注意：
# - 本文件是 source 库，不是独立测试脚本；函数名不带 test_ 前缀
#   （run.sh 按字母序取第一个 test_* 函数作为测试入口，带前缀会被误选）。
# - 调用方需先 source framework/common.sh 与 framework/verify.sh。

# 执行 istio-cni.mdx 的完整升级步骤：
# patch 版本 → 观察 DaemonSet 滚动 → 等待 Ready → 验证资源状态与 Pod 状态
update_istio_cni_and_verify() {
    local output

    # 1. 升级 IstioCNI 版本到 v1.28.6
    log_info "IstioCNI 升级: patch 版本至 v1.28.6"
    runme run update-istio-cni:patch-version || {
        log_error "升级 IstioCNI 版本失败"
        return 1
    }
    sleep 5  # 等待 operator 改写 DaemonSet 模板

    # 2. 观察 istio-cni-node DaemonSet 滚动
    log_info "IstioCNI 升级: 观察 istio-cni-node DaemonSet 滚动"
    runme run update-istio-cni:rollout-status || {
        log_error "istio-cni-node DaemonSet 滚动失败"
        return 1
    }

    # 3. 等待 IstioCNI 资源 Ready
    log_info "IstioCNI 升级: 等待 IstioCNI 资源就绪"
    runme run update-istio-cni:wait-ready || {
        log_error "等待 IstioCNI 资源就绪失败"
        return 1
    }

    # 4. 验证 IstioCNI 状态（输出包含动态 AGE 值，使用 __cmp_lines 验证关键字段）
    log_info "IstioCNI 升级: 验证 IstioCNI 状态"
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

    # 5. 验证 istio-cni-node Pod 状态（输出包含动态 pod 名后缀和 AGE，使用 __cmp_lines 验证关键字段）
    log_info "IstioCNI 升级: 验证 istio-cni-node Pod 状态"
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

    return 0
}
