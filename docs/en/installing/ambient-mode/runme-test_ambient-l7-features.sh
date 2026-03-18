#!/usr/bin/env bash
# Ambient 模式 L7 特性（流量路由 + 授权策略）测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

test_ambient_l7_features() {
    log_info "=========================================="
    log_info "开始 Ambient 模式 L7 特性测试"
    log_info "=========================================="

    # ==========================================
    # Section 1: 流量路由（Traffic Routing）
    # ==========================================

    # 步骤 1.1: 保存 HTTPRoute YAML 到 /tmp
    log_info "步骤 1.1: 生成 traffic-route.yaml 文件"
    runme print ambient-l7-features:traffic-route-yaml > /tmp/traffic-route.yaml || {
        log_error "生成 traffic-route.yaml 失败"
        return 1
    }

    # 步骤 1.2: 在 /tmp 目录执行 kubectl apply
    log_info "步骤 1.2: 应用流量路由配置"
    kubectl_apply_runme_block "ambient-l7-features:apply-traffic-route" "/tmp/" || {
        log_error "应用流量路由配置失败"
        return 1
    }

    kubectl wait \
      --for=jsonpath='{.status.parents[?(@.parentRef.name=="reviews")].conditions[?(@.type=="Accepted")].status}'=True \
      httproute/reviews -n bookinfo --timeout=60s || {
        log_error "等待 HTTPRoute 被接受失败"
        return 1
    }
    log_success "HTTPRoute 已被接受"

    # 步骤 1.3: 验证流量分发（概率性输出，检查 reviews-v1 和 reviews-v2 都出现）
    log_info "步骤 1.3: 验证流量分发"
    local split_output
    split_output=$(runme run ambient-l7-features:verify-traffic-split 2>&1) || {
        log_error "执行流量分发验证失败"
        log_error "输出: $split_output"
        return 1
    }

    if ! __cmp_lines "$split_output" "$(cat <<'EOF'
+ reviews-v1
+ reviews-v2
EOF
    )"; then
        log_error "流量分发验证失败：期望同时出现 reviews-v1 和 reviews-v2"
        log_error "实际输出: $split_output"
        return 1
    fi
    log_success "流量分发验证通过（reviews-v1 和 reviews-v2 均出现）"

    # ==========================================
    # Section 2: 授权策略（Authorization Policy）
    # ==========================================

    # 步骤 2.1: 保存 AuthorizationPolicy YAML 到 /tmp
    log_info "步骤 2.1: 生成 authorization-policy.yaml 文件"
    runme print ambient-l7-features:authz-policy-yaml > /tmp/authorization-policy.yaml || {
        log_error "生成 authorization-policy.yaml 失败"
        return 1
    }

    # 步骤 2.2: 在 /tmp 目录执行 kubectl apply
    log_info "步骤 2.2: 应用授权策略"
    kubectl_apply_runme_block "ambient-l7-features:apply-authz-policy" "/tmp/" || {
        log_error "应用授权策略失败"
        return 1
    }

    # 步骤 2.3: 创建 curl 命名空间
    log_info "步骤 2.3: 创建 curl 命名空间"
    runme run ambient-l7-features:create-ns-curl || {
        log_error "创建 curl 命名空间失败"
        return 1
    }

    # 步骤 2.4: 部署 curl 客户端
    log_info "步骤 2.4: 部署 curl 客户端"
    kubectl_apply_with_mirror ambient-l7-features:deploy-curl || {
        log_error "部署 curl 客户端失败"
        return 1
    }

    # 步骤 2.5: 标记 discovery 标签
    log_info "步骤 2.5: 标记 istio-discovery=enabled 标签"
    runme run ambient-l7-features:label-curl-discovery || {
        log_error "标记 discovery 标签失败"
        return 1
    }

    # 步骤 2.6: 标记 ambient 标签
    log_info "步骤 2.6: 启用 curl 命名空间的 ambient 模式"
    runme run ambient-l7-features:label-curl-ambient || {
        log_error "标记 ambient 标签失败"
        return 1
    }

    # 步骤 2.7: 等待 curl deployment 就绪
    log_info "步骤 2.7: 等待 curl deployment 就绪"
    _wait_for_deployment curl curl

    # 步骤 2.8: 验证 GET 请求返回 HTTP 200
    log_info "步骤 2.8: 验证 GET 请求被允许（HTTP 200）"
    local get_output get_expected
    get_output=$(runme run ambient-l7-features:verify-get-allowed 2>&1)
    get_expected=$(runme print ambient-l7-features:verify-get-allowed-output)

    if ! __cmp_contains "$get_output" "$get_expected"; then
        log_error "GET 请求验证失败"
        log_error "期待输出: $get_expected"
        log_error "实际输出: $get_output"
        return 1
    fi
    log_success "GET 请求验证通过（HTTP 200）"

    # 步骤 2.9: 验证 POST 请求返回 HTTP 403
    log_info "步骤 2.9: 验证 POST 请求被拒绝（HTTP 403）"
    local post_output post_expected
    post_output=$(runme run ambient-l7-features:verify-post-denied 2>&1)
    post_expected=$(runme print ambient-l7-features:verify-post-denied-output)

    if ! __cmp_contains "$post_output" "$post_expected"; then
        log_error "POST 请求验证失败"
        log_error "期待输出: $post_expected"
        log_error "实际输出: $post_output"
        return 1
    fi
    log_success "POST 请求验证通过（HTTP 403）"

    # 步骤 2.10: 验证其他服务 GET 被 RBAC 拒绝
    log_info "步骤 2.10: 验证其他服务 GET 请求被 RBAC 拒绝"
    local rbac_output rbac_expected
    rbac_output=$(runme run ambient-l7-features:verify-get-denied 2>&1)
    rbac_expected=$(runme print ambient-l7-features:verify-get-denied-output)

    if ! __cmp_contains "$rbac_output" "$rbac_expected"; then
        log_error "RBAC 拒绝验证失败"
        log_error "期待输出: $rbac_expected"
        log_error "实际输出: $rbac_output"
        return 1
    fi
    log_success "RBAC 拒绝验证通过"

    log_success "=========================================="
    log_success "Ambient 模式 L7 特性测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源（兜底清理，容错处理）
cleanup_ambient_l7_features() {
    log_info "=========================================="
    log_info "清理 L7 特性测试资源"
    log_info "=========================================="

    # 清理流量路由
    runme run ambient-l7-features:cleanup-traffic-route || {
        log_error "清理流量路由失败"
        return 1
    }

    # 清理授权策略资源
    runme run ambient-l7-features:cleanup-authorization-policy || {
        log_error "清理授权策略资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
