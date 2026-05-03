#!/usr/bin/env bash
# Ambient 模式 Kubernetes Gateway API 暴露服务测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

test_exposing_a_service_via_k8s_gateway_api_in_ambient_mode() {
    log_info "=========================================="
    log_info "开始 Ambient Gateway API 暴露服务测试"
    log_info "=========================================="

    # ==========================================
    # Section 1: Procedure（配置命名空间和部署服务）
    # ==========================================

    # 步骤 1: 创建 httpbin 命名空间
    log_info "步骤 1: 创建 httpbin 命名空间"
    _create_namespace_safe ambient-gw-api:create-httpbin-ns httpbin || {
        log_error "创建 httpbin 命名空间失败"
        return 1
    }

    # 步骤 2: 标记 httpbin discovery
    log_info "步骤 2: 标记 httpbin discovery"
    runme run ambient-gw-api:label-httpbin-discovery || {
        log_error "标记 httpbin discovery 失败"
        return 1
    }

    # 步骤 3: 启用 httpbin ambient 模式
    log_info "步骤 3: 启用 httpbin ambient 模式"
    runme run ambient-gw-api:label-httpbin-ambient || {
        log_error "启用 httpbin ambient 模式失败"
        return 1
    }

    # 步骤 4: 部署 httpbin 应用
    log_info "步骤 4: 部署 httpbin 应用"
    kubectl_apply_with_mirror ambient-gw-api:deploy-httpbin || {
        log_error "部署 httpbin 应用失败"
        return 1
    }
    _wait_for_deployment httpbin httpbin

    # 步骤 5: 写入 waypoint YAML + 应用
    log_info "步骤 5: 部署 waypoint 代理"
    runme print ambient-gw-api:waypoint-yaml > /tmp/httpbin-waypoint.yaml || {
        log_error "生成 waypoint YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "ambient-gw-api:apply-waypoint" "/tmp/" || {
        log_error "应用 waypoint 代理失败"
        return 1
    }

    # 步骤 6: 标记 service 走 waypoint
    log_info "步骤 6: 标记 httpbin service 走 waypoint"
    runme run ambient-gw-api:label-svc-waypoint || {
        log_error "标记 service 走 waypoint 失败"
        return 1
    }

    # 步骤 7: 标记 namespace 走 waypoint
    log_info "步骤 7: 标记 httpbin namespace 走 waypoint"
    runme run ambient-gw-api:label-ns-waypoint || {
        log_error "标记 namespace 走 waypoint 失败"
        return 1
    }

    # 步骤 8: 写入 gateway YAML + 应用
    log_info "步骤 8: 部署 ingress gateway"
    runme print ambient-gw-api:gateway-yaml > /tmp/httpbin-gw.yaml || {
        log_error "生成 gateway YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "ambient-gw-api:apply-gateway" "/tmp/" || {
        log_error "应用 gateway 失败"
        return 1
    }

    # 步骤 9: 写入 ingress HTTPRoute YAML + 应用
    log_info "步骤 9: 部署 ingress HTTPRoute"
    runme print ambient-gw-api:ingress-hr-yaml > /tmp/httpbin-ingress-hr.yaml || {
        log_error "生成 ingress HTTPRoute YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "ambient-gw-api:apply-ingress-hr" "/tmp/" || {
        log_error "应用 ingress HTTPRoute 失败"
        return 1
    }

    # 步骤 10: 写入 waypoint HTTPRoute YAML + 应用
    log_info "步骤 10: 部署 waypoint HTTPRoute"
    runme print ambient-gw-api:waypoint-hr-yaml > /tmp/httpbin-waypoint-hr.yaml || {
        log_error "生成 waypoint HTTPRoute YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "ambient-gw-api:apply-waypoint-hr" "/tmp/" || {
        log_error "应用 waypoint HTTPRoute 失败"
        return 1
    }

    # 步骤 11: 等待 waypoint 就绪
    log_info "步骤 11: 等待 waypoint 代理就绪"
    runme run ambient-gw-api:wait-waypoint || {
        log_error "等待 waypoint 代理就绪失败"
        return 1
    }

    # ==========================================
    # Section 2: Verification（验证流量路由）
    # ==========================================

    # 步骤 12: 创建 curl 命名空间
    log_info "步骤 12: 创建 curl 命名空间"
    _create_namespace_safe ambient-gw-api:create-curl-ns curl || {
        log_error "创建 curl 命名空间失败"
        return 1
    }

    # 步骤 13: 部署 curl 客户端
    log_info "步骤 13: 部署 curl 客户端"
    kubectl_apply_with_mirror ambient-gw-api:deploy-curl || {
        log_error "部署 curl 客户端失败"
        return 1
    }

    # 步骤 14: 标记 curl discovery
    log_info "步骤 14: 标记 curl discovery"
    runme run ambient-gw-api:label-curl-discovery || {
        log_error "标记 curl discovery 失败"
        return 1
    }

    # 步骤 15: 启用 curl ambient 模式
    log_info "步骤 15: 启用 curl ambient 模式"
    runme run ambient-gw-api:label-curl-ambient || {
        log_error "启用 curl ambient 模式失败"
        return 1
    }

    # 等待 curl deployment 就绪
    _wait_for_deployment curl curl

    # 步骤 16: 获取 curl pod 名称（设置环境变量）
    log_info "步骤 16: 获取 curl pod 名称"
    eval "$(runme print ambient-gw-api:get-curl-pod)" || {
        log_error "获取 curl pod 名称失败"
        return 1
    }
    export CURL_POD
    log_info "CURL_POD=$CURL_POD"

    # 步骤 17: 测试 /headers 端点（期望 200 OK）
    log_info "步骤 17: 测试 /headers 端点"
    local headers_output headers_expected
    headers_output=$(eval "$(runme print ambient-gw-api:test-headers)" 2>&1) || {
        log_error "测试 /headers 端点失败"
        log_error "输出: $headers_output"
        return 1
    }
    headers_expected=$(runme print ambient-gw-api:test-headers-output)
    if ! __cmp_elided "$headers_output" "$headers_expected"; then
        log_error "/headers 端点验证失败"
        log_error "期待输出: $headers_expected"
        log_error "实际输出: $headers_output"
        return 1
    fi
    log_success "/headers 端点验证通过（HTTP 200 OK）"

    # 步骤 18: 测试 /get 端点（期望 404 Not Found）
    log_info "步骤 18: 测试 /get 端点"
    local get_output get_expected
    get_output=$(eval "$(runme print ambient-gw-api:test-get)" 2>&1) || true
    get_expected=$(runme print ambient-gw-api:test-get-output)
    if ! __cmp_elided "$get_output" "$get_expected"; then
        log_error "/get 端点验证失败"
        log_error "期待输出: $get_expected"
        log_error "实际输出: $get_output"
        return 1
    fi
    log_success "/get 端点验证通过（HTTP 404 Not Found）"

    # 步骤 19: 暴露为 LoadBalancer
    log_info "步骤 19: 暴露 gateway 为 LoadBalancer"
    runme run ambient-gw-api:expose-lb || {
        log_error "暴露 gateway 为 LoadBalancer 失败"
        return 1
    }
    # 等待 svc 的 LoadBalancer 可用
    _wait_for_ingress_lb httpbin httpbin-gateway-istio || return 1

    # 步骤 20: 获取 INGRESS_HOST
    log_info "步骤 20: 获取 INGRESS_HOST"
    eval "$(runme print ambient-gw-api:get-ingress-host)" || {
        log_error "获取 INGRESS_HOST 失败"
        return 1
    }
    export INGRESS_HOST
    log_info "INGRESS_HOST=$INGRESS_HOST"

    # 步骤 21: 获取 INGRESS_PORT
    log_info "步骤 21: 获取 INGRESS_PORT"
    eval "$(runme print ambient-gw-api:get-ingress-port)" || {
        log_error "获取 INGRESS_PORT 失败"
        return 1
    }
    export INGRESS_PORT
    log_info "INGRESS_PORT=$INGRESS_PORT"

    # 步骤 22: 外部访问测试
    # 根据 INGRESS_HOST 是否为 IPv6 地址（含冒号）选择 IPv4 / IPv6 测试命令
    # 文档示例由测试者本地终端执行，但本地终端可能存在代理等不稳定因素，
    # 因此测试脚本改为通过 curl pod 在集群内部发起请求，避免环境干扰
    log_info "步骤 22: 外部访问测试"
    local external_cmd external_output external_expected
    if [[ "$INGRESS_HOST" == *:* ]]; then
        log_info "检测到 IPv6 地址，使用 IPv6 测试命令"
        external_cmd=$(runme print ambient-gw-api:test-external-ipv6)
    else
        log_info "检测到 IPv4 地址，使用 IPv4 测试命令"
        external_cmd=$(runme print ambient-gw-api:test-external)
    fi
    external_output=$(eval "kubectl exec $CURL_POD -n curl -- $external_cmd" 2>&1) || {
        log_error "外部访问测试失败"
        log_error "输出: $external_output"
        return 1
    }
    external_expected=$(runme print ambient-gw-api:test-external-output)
    if ! __cmp_elided "$external_output" "$external_expected"; then
        log_error "/headers 端点验证失败"
        log_error "期待输出: $external_expected"
        log_error "实际输出: $external_output"
        return 1
    fi
    log_success "外部访问测试通过"

    log_success "=========================================="
    log_success "Ambient Gateway API 暴露服务测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源
cleanup_exposing_a_service_via_k8s_gateway_api_in_ambient_mode() {
    log_info "=========================================="
    log_info "清理 Ambient Gateway API 测试资源"
    log_info "=========================================="

    runme run ambient-gw-api:cleanup || {
        log_error "清理资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
