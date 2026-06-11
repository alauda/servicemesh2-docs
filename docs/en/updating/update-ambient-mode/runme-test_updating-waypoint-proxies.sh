#!/usr/bin/env bash
# Waypoint 代理升级验证文档测试脚本
# 依赖：上游 updating-ambient-components --no-cleanup 已完成 v1.28.6 升级（含 ambient bookinfo），
#       且 waypoint-proxies 测试已在 bookinfo 命名空间部署 waypoint
# 前置：curl 客户端为文档 Prerequisites（指向 ambient-l7-features.mdx），
#       由本脚本步骤 0 跨文档复用 ambient-l7-features:* 代码块部署，cleanup 时回收

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# runme 命令可以在项目的任意目录中执行

test_updating_waypoint_proxies() {
    log_info "=========================================="
    log_info "开始 Waypoint 代理升级验证测试"
    log_info "=========================================="

    local output

    # 0. 前置：部署 curl 客户端（复用 ambient-l7-features 文档代码块）
    log_info "步骤 0.1: 创建 curl 命名空间"
    _create_namespace_safe ambient-l7-features:create-ns-curl "curl" || {
        log_error "创建 curl 命名空间失败"
        return 1
    }

    log_info "步骤 0.2: 部署 curl 客户端"
    kubectl_apply_with_mirror ambient-l7-features:deploy-curl || {
        log_error "部署 curl 客户端失败"
        return 1
    }

    log_info "步骤 0.3: 为 curl 命名空间打 istio-discovery=enabled 标签"
    runme run ambient-l7-features:label-curl-discovery || {
        log_error "打 discovery 标签失败"
        return 1
    }

    log_info "步骤 0.4: 将 curl 命名空间纳入 ambient 网格"
    runme run ambient-l7-features:label-curl-ambient || {
        log_error "打 ambient 标签失败"
        return 1
    }

    log_info "步骤 0.5: 等待 curl deployment 就绪"
    _wait_for_deployment curl curl

    # 1. 验证 waypoint 代理已连接新控制面并运行新版本
    #    （输出含动态 pod 名/同步时间，使用 __cmp_lines 验证关键字段）
    log_info "步骤 1: 验证 waypoint 代理版本"
    output=$(runme run update-waypoint:verify-proxy-status 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ waypoint
+ 1.28.6
EOF
    )"; then
        log_error "验证 waypoint 代理版本失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "waypoint 代理版本验证通过 (1.28.6)"

    # 2. 创建 HTTPRoute（YAML heredoc 代码块，使用 kubectl_apply_runme_block）
    log_info "步骤 2: 创建 HTTPRoute (reviews 80/20)"
    kubectl_apply_runme_block "update-waypoint:create-httproute" "/tmp/" || {
        log_error "创建 HTTPRoute 失败"
        return 1
    }

    kubectl wait \
      --for=jsonpath='{.status.parents[?(@.parentRef.name=="reviews")].conditions[?(@.type=="Accepted")].status}'=True \
      httproute/reviews -n bookinfo --timeout=60s || {
        log_error "等待 HTTPRoute 被接受失败"
        return 1
    }
    log_success "HTTPRoute 已被接受"

    # 3. 验证流量分发（概率性输出，检查 reviews-v1 和 reviews-v2 都出现）
    log_info "步骤 3: 验证流量分发 (80/20)"
    output=$(runme run update-waypoint:verify-traffic-split 2>&1) || {
        log_error "执行流量分发验证失败"
        log_error "输出: $output"
        return 1
    }

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ reviews-v1
+ reviews-v2
EOF
    )"; then
        log_error "流量分发验证失败：期望同时出现 reviews-v1 和 reviews-v2"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "流量分发验证通过（reviews-v1 和 reviews-v2 均出现）"

    # 4. 创建 AuthorizationPolicy（YAML heredoc 代码块）
    log_info "步骤 4: 创建 AuthorizationPolicy (productpage-waypoint)"
    kubectl_apply_runme_block "update-waypoint:create-authz-policy" "/tmp/" || {
        log_error "创建 AuthorizationPolicy 失败"
        return 1
    }

    # 5. 验证允许的 GET 请求返回 HTTP 200
    log_info "步骤 5: 验证 curl 客户端 GET 请求被允许（HTTP 200）"
    local get_output get_expected
    get_output=$(runme run update-waypoint:verify-get-allowed 2>&1)
    get_expected=$(runme print update-waypoint:verify-get-allowed-output)

    if ! __cmp_contains "$get_output" "$get_expected"; then
        log_error "GET 请求验证失败"
        log_error "期待输出: $get_expected"
        log_error "实际输出: $get_output"
        return 1
    fi
    log_success "GET 请求验证通过（HTTP 200）"

    # 6. 验证 allow list 之外的 ratings 服务被 RBAC 拒绝
    log_info "步骤 6: 验证 ratings 服务 GET 请求被 RBAC 拒绝"
    local rbac_output rbac_expected
    rbac_output=$(runme run update-waypoint:verify-get-denied 2>&1)
    rbac_expected=$(runme print update-waypoint:verify-get-denied-output)

    if ! __cmp_contains "$rbac_output" "$rbac_expected"; then
        log_error "RBAC 拒绝验证失败"
        log_error "期待输出: $rbac_expected"
        log_error "实际输出: $rbac_output"
        return 1
    fi
    log_success "RBAC 拒绝验证通过"

    log_success "=========================================="
    log_success "Waypoint 代理升级验证测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理验证资源（HTTPRoute + AuthorizationPolicy）及脚本级 curl 前置
cleanup_updating_waypoint_proxies() {
    log_info "=========================================="
    log_info "清理 Waypoint 升级验证测试资源"
    log_info "=========================================="

    runme run update-waypoint:cleanup || {
        log_error "清理 HTTPRoute / AuthorizationPolicy 失败"
        return 1
    }

    # 回收步骤 0 部署的 curl 前置（脚本级资源，归本脚本管理；
    # 不复用 ambient-l7-features:cleanup-authorization-policy 块——其包含
    # authzpolicy 删除，与上面的 update-waypoint:cleanup 双删冲突）
    log_info "回收 curl 客户端命名空间"
    kubectl delete namespace curl --ignore-not-found || {
        log_error "删除 curl 命名空间失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
