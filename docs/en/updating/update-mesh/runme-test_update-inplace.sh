#!/usr/bin/env bash
# InPlace 更新策略文档测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

test_update_inplace() {
    log_info "=========================================="
    log_info "开始 InPlace 更新策略测试"
    log_info "=========================================="

    # 1. 创建命名空间
    log_info "步骤 1: 创建 istio-cni 和 istio-system 命名空间"
    runme run update-inplace:create-namespaces || {
        log_error "创建命名空间失败"
        return 1
    }

    # 2. 安装 IstioCNI（YAML 代码块，使用 kubectl_apply_runme_block）
    log_info "步骤 2: 安装 IstioCNI"
    kubectl_apply_runme_block "update-inplace:create-istio-cni" "/tmp/" || {
        log_error "安装 IstioCNI 失败"
        return 1
    }

    # 3. 部署 Istio 控制面（YAML 代码块，使用 kubectl_apply_runme_block）
    log_info "步骤 3: 部署 Istio 控制面 (InPlace 策略)"
    kubectl_apply_runme_block "update-inplace:create-istio" "/tmp/" || {
        log_error "部署 Istio 控制面失败"
        return 1
    }

    # 4. 等待 Istio 控制面就绪
    log_info "步骤 4: 等待 Istio 控制面就绪"
    runme run update-inplace:wait-istio-ready || {
        log_error "等待 Istio 控制面就绪失败"
        return 1
    }

    # 5. 创建 bookinfo 命名空间
    log_info "步骤 5: 创建 bookinfo 命名空间"
    runme run update-inplace:create-bookinfo-ns || {
        log_error "创建 bookinfo 命名空间失败"
        return 1
    }

    # 6. 为 bookinfo 命名空间启用 sidecar 注入
    log_info "步骤 6: 为 bookinfo 命名空间启用 sidecar 注入"
    runme run update-inplace:label-bookinfo-ns || {
        log_error "启用 sidecar 注入失败"
        return 1
    }

    # 7. 部署 bookinfo 应用
    log_info "步骤 7: 部署 bookinfo 应用"
    kubectl_apply_with_mirror update-inplace:deploy-bookinfo || {
        log_error "部署 bookinfo 应用失败"
        return 1
    }

    # 8. 等待 bookinfo deployments 就绪
    log_info "步骤 8: 等待 bookinfo deployments 就绪"
    _wait_for_deployment bookinfo details-v1
    _wait_for_deployment bookinfo productpage-v1
    _wait_for_deployment bookinfo ratings-v1
    _wait_for_deployment bookinfo reviews-v1
    _wait_for_deployment bookinfo reviews-v2
    _wait_for_deployment bookinfo reviews-v3
    log_success "所有 bookinfo deployments 已就绪"

    # 9. 检查 Istio 资源状态并验证输出（输出包含动态 AGE 值，使用 __cmp_lines 验证关键字段）
    log_info "步骤 9: 检查 Istio 资源状态（安装后）"
    local output
    output=$(runme run update-inplace:get-istio-install 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ Healthy
+ v1.26.3
+ IN USE
EOF
    )"; then
        log_error "检查 Istio 资源状态失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "Istio 资源状态验证通过（安装后）"

    # 10. 更新 Istio 版本
    log_info "步骤 10: 更新 Istio 版本至 v1.28.6"
    runme run update-inplace:patch-istio-version || {
        log_error "更新 Istio 版本失败"
        return 1
    }
    sleep 5  # 等待 patch 生效

    # 11. 等待 Istio 更新后的控制面就绪
    log_info "步骤 11: 等待 Istio 更新后的控制面就绪"
    runme run update-inplace:wait-istio-update-ready || {
        log_error "等待 Istio 更新后的控制面就绪失败"
        return 1
    }

    # 12. 确认新版本控制面就绪（输出包含动态 AGE 值，使用 __cmp_lines 验证关键字段）
    log_info "步骤 12: 确认新版本控制面就绪"
    output=$(runme run update-inplace:get-istio-update 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ Healthy
+ v1.28.6
EOF
    )"; then
        log_error "检查 Istio 更新状态失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "Istio 更新状态验证通过"

    # 13. 重启应用工作负载
    log_info "步骤 13: 重启应用工作负载"
    runme run update-inplace:restart-workloads || {
        log_error "重启应用工作负载失败"
        return 1
    }

    # 14. 等待 bookinfo deployments 就绪（重启后）
    log_info "步骤 14: 等待 bookinfo deployments 就绪（重启后）"
    _wait_for_deployment bookinfo details-v1
    _wait_for_deployment bookinfo productpage-v1
    _wait_for_deployment bookinfo ratings-v1
    _wait_for_deployment bookinfo reviews-v1
    _wait_for_deployment bookinfo reviews-v2
    _wait_for_deployment bookinfo reviews-v3
    log_success "所有 bookinfo deployments 已就绪（重启后）"

    # 15. 验证 sidecar 代理状态（输出包含动态 pod 名和时间戳，使用 __cmp_lines 验证关键内容）
    log_info "步骤 15: 验证 sidecar 代理状态"
    output=$(runme run update-inplace:verify-proxy-status 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ 1.28.6
+ bookinfo
+ details-v1
+ productpage-v1
+ ratings-v1
+ reviews-v1
+ reviews-v2
+ reviews-v3
EOF
    )"; then
        log_error "验证 sidecar 代理状态失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "sidecar 代理状态验证通过"

    log_success "=========================================="
    log_success "InPlace 更新策略测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源
cleanup_update_inplace() {
    log_info "=========================================="
    log_info "清理 InPlace 更新策略测试资源"
    log_info "=========================================="

    runme run update-inplace:cleanup || {
        log_error "清理资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
