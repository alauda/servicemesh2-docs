#!/usr/bin/env bash
# Sidecar 模式 Kubernetes Gateway API 暴露服务测试脚本

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# runme 命令可以在项目的任意目录中执行

test_exposing_a_service_via_k8s_gateway_api_in_sidecar_mode() {
    log_info "=========================================="
    log_info "开始 Sidecar 模式 Gateway API 暴露服务测试"
    log_info "=========================================="

    # 步骤 0: (仅 ENABLE_METALLB=true 生效) 为单集群创建外部 IP 地址池，供后续 LoadBalancer 取址
    setup_external_ip_pools "$SINGLE_CLUSTER_NAME" || return 1

    # ==========================================
    # Section 1: Procedure（配置网关与路由）
    # ==========================================

    # 步骤 1: 创建 httpbin 命名空间
    log_info "步骤 1: 创建 httpbin 命名空间"
    _create_namespace_safe sidecar-gw-api:create-httpbin-ns httpbin || {
        log_error "创建 httpbin 命名空间失败"
        return 1
    }

    # 步骤 2: 部署 httpbin 应用
    log_info "步骤 2: 部署 httpbin 应用"
    kubectl_apply_with_mirror sidecar-gw-api:deploy-httpbin || {
        log_error "部署 httpbin 应用失败"
        return 1
    }
    _wait_for_deployment httpbin httpbin

    # 步骤 3: 写入 gateway YAML + 应用
    log_info "步骤 3: 部署 ingress gateway"
    runme print sidecar-gw-api:gateway-yaml > /tmp/httpbin-k8s-gw.yaml || {
        log_error "生成 gateway YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "sidecar-gw-api:apply-gateway" "/tmp/" || {
        log_error "应用 gateway 失败"
        return 1
    }

    # 步骤 3a: (仅 ENABLE_GW_LINUX_KERNEL_COMPAT=true 生效) ingress gateway 监听 80 特权端口，按 Scenario 2 以 root 处理
    apply_kernel_compat_k8s_gateway_api httpbin httpbin-gateway || return 1

    # 步骤 4: 写入 HTTPRoute YAML + 应用
    log_info "步骤 4: 部署 HTTPRoute"
    runme print sidecar-gw-api:httproute-yaml > /tmp/httpbin-hr.yaml || {
        log_error "生成 HTTPRoute YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "sidecar-gw-api:apply-httproute" "/tmp/" || {
        log_error "应用 HTTPRoute 失败"
        return 1
    }

    # 步骤 5: 等待 gateway 就绪
    log_info "步骤 5: 等待 gateway 就绪"
    runme run sidecar-gw-api:wait-programmed || {
        log_error "等待 gateway 就绪失败"
        return 1
    }

    # ==========================================
    # Section 2: Verification（验证流量路由）
    # ==========================================

    # 步骤 6: 创建 curl 命名空间
    log_info "步骤 6: 创建 curl 命名空间"
    _create_namespace_safe sidecar-gw-api:create-curl-ns curl || {
        log_error "创建 curl 命名空间失败"
        return 1
    }

    # 步骤 7: 部署 curl 客户端
    log_info "步骤 7: 部署 curl 客户端"
    kubectl_apply_with_mirror sidecar-gw-api:deploy-curl || {
        log_error "部署 curl 客户端失败"
        return 1
    }
    _wait_for_deployment curl curl

    # 步骤 8: 获取 curl pod 名称（设置环境变量）
    log_info "步骤 8: 获取 curl pod 名称"
    eval "$(runme print sidecar-gw-api:get-curl-pod)" || {
        log_error "获取 curl pod 名称失败"
        return 1
    }
    export CURL_POD
    log_info "CURL_POD=$CURL_POD"

    # 步骤 9: 测试 /headers 端点（期望 200 OK）
    log_info "步骤 9: 测试 /headers 端点"
    local headers_output headers_expected
    headers_output=$(eval "$(runme print sidecar-gw-api:test-headers)" 2>&1) || {
        log_error "测试 /headers 端点失败"
        log_error "输出: $headers_output"
        return 1
    }
    headers_expected=$(runme print sidecar-gw-api:test-headers-output)
    if ! __cmp_elided "$headers_output" "$headers_expected"; then
        log_error "/headers 端点验证失败"
        log_error "期待输出: $headers_expected"
        log_error "实际输出: $headers_output"
        return 1
    fi
    log_success "/headers 端点验证通过（HTTP 200 OK）"

    # 步骤 10: 测试 /get 端点（期望 404 Not Found）
    log_info "步骤 10: 测试 /get 端点"
    local get_output get_expected
    get_output=$(eval "$(runme print sidecar-gw-api:test-get)" 2>&1) || true
    get_expected=$(runme print sidecar-gw-api:test-get-output)
    if ! __cmp_elided "$get_output" "$get_expected"; then
        log_error "/get 端点验证失败"
        log_error "期待输出: $get_expected"
        log_error "实际输出: $get_output"
        return 1
    fi
    log_success "/get 端点验证通过（HTTP 404 Not Found）"

    # 步骤 11: 暴露 gateway 为 LoadBalancer
    log_info "步骤 11: 暴露 gateway 为 LoadBalancer"
    runme run sidecar-gw-api:expose-lb || {
        log_error "暴露 gateway 为 LoadBalancer 失败"
        return 1
    }
    # 等待 svc 的 LoadBalancer ingress 可用
    _wait_for_ingress_lb httpbin httpbin-gateway-istio || return 1

    # 步骤 12: 获取 INGRESS_HOST
    log_info "步骤 12: 获取 INGRESS_HOST"
    eval "$(runme print sidecar-gw-api:get-ingress-host)" || {
        log_error "获取 INGRESS_HOST 失败"
        return 1
    }
    export INGRESS_HOST
    log_info "INGRESS_HOST=$INGRESS_HOST"

    # 步骤 13: 获取 INGRESS_PORT
    log_info "步骤 13: 获取 INGRESS_PORT"
    eval "$(runme print sidecar-gw-api:get-ingress-port)" || {
        log_error "获取 INGRESS_PORT 失败"
        return 1
    }
    export INGRESS_PORT
    log_info "INGRESS_PORT=$INGRESS_PORT"

    # 步骤 14: 外部访问测试
    # 根据 INGRESS_HOST 是否为 IPv6 地址（含冒号）选择 IPv4 / IPv6 测试命令；
    # 文档示例由本地终端执行，测试改为经 curl pod 在集群内发起，避免本地代理等干扰。
    # 文档对外部访问无 -output 块，使用 __cmp_lines 校验关键行（对响应头顺序免疫）。
    log_info "步骤 14: 外部访问测试"
    local external_cmd external_output
    if [[ "$INGRESS_HOST" == *:* ]]; then
        log_info "检测到 IPv6 地址，使用 IPv6 测试命令"
        external_cmd=$(runme print sidecar-gw-api:test-external-ipv6)
    else
        log_info "检测到 IPv4 地址，使用 IPv4 测试命令"
        external_cmd=$(runme print sidecar-gw-api:test-external)
    fi
    external_output=$(eval "kubectl exec $CURL_POD -n curl -- $external_cmd" 2>&1) || {
        log_error "外部访问测试失败"
        log_error "输出: $external_output"
        return 1
    }
    if ! __cmp_lines "$external_output" "$(cat <<'EOF'
+ HTTP/1.1 200 OK
+ server: istio-envoy
EOF
    )"; then
        log_error "外部访问测试验证失败"
        log_error "实际输出: $external_output"
        return 1
    fi
    log_success "外部访问测试通过"

    log_success "=========================================="
    log_success "Sidecar 模式 Gateway API 暴露服务测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源
cleanup_exposing_a_service_via_k8s_gateway_api_in_sidecar_mode() {
    log_info "=========================================="
    log_info "清理 Sidecar 模式 Gateway API 测试资源"
    log_info "=========================================="

    local rc=0

    # 删除 httpbin / curl 命名空间（文档块驱动）
    runme run sidecar-gw-api:cleanup || {
        log_error "清理命名空间失败"
        rc=1
    }

    # 回收外部 IP 地址池（仅 ENABLE_METALLB=true 生效）
    teardown_external_ip_pools "$SINGLE_CLUSTER_NAME" || rc=1

    [ "$rc" -eq 0 ] && log_success "测试资源清理完成"
    return "$rc"
}
