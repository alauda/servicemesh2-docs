#!/usr/bin/env bash
# Istio Gateway + VirtualService（gateway injection 网关）暴露服务测试脚本

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# runme 命令可以在项目的任意目录中执行

# 注入网关名 / 命名空间（文档中以 <gateway_name>/<gateway_namespace> 占位，测试统一取此值）
GW_NAME=ingressgateway
GW_NS=istio-ingress

test_exposing_a_service_via_istio_gateway() {
    log_info "=========================================="
    log_info "开始 Istio Gateway + VirtualService 暴露服务测试"
    log_info "=========================================="

    # 步骤 0: (仅 ENABLE_METALLB=true 生效) 为单集群创建外部 IP 地址池，供后续 LoadBalancer 取址
    setup_external_ip_pools "$SINGLE_CLUSTER_NAME" || return 1

    # ==========================================
    # 前置：通过 gateway injection 安装网关（文档前置条件）
    # ==========================================

    # 通过 gateway injection 安装网关（忠实下发文档 YAML）。注入网关监听 80 特权端口，
    # 故传 run_as_root=true：install_gateway_via_injection 内部按 Scenario 2 处理内核 < 4.11 兼容
    # （开关开时先修补 mesh 级 gateway 注入模板再装网关，关时为 no-op）。
    install_gateway_via_injection "$GW_NAME" "$GW_NS" true || return 1

    # ==========================================
    # Section 1: Procedure（配置 Gateway 与 VirtualService）
    # ==========================================

    # 步骤 3: 创建 httpbin 命名空间
    log_info "步骤 3: 创建 httpbin 命名空间"
    _create_namespace_safe istio-gw:create-httpbin-ns httpbin || {
        log_error "创建 httpbin 命名空间失败"
        return 1
    }

    # 步骤 4: 为 httpbin 命名空间启用 sidecar 注入（InPlace 升级策略）
    log_info "步骤 4: 启用 sidecar 注入"
    runme run istio-gw:label-injection || {
        log_error "启用 sidecar 注入失败"
        return 1
    }

    # 步骤 5: 部署 httpbin 应用
    log_info "步骤 5: 部署 httpbin 应用"
    kubectl_apply_with_mirror istio-gw:deploy-httpbin || {
        log_error "部署 httpbin 应用失败"
        return 1
    }
    _wait_for_deployment httpbin httpbin

    # 步骤 6: 写入 Gateway YAML（替换占位符）+ 应用
    log_info "步骤 6: 部署 Istio Gateway"
    _gw_render_block istio-gw:gateway-yaml "$GW_NAME" "$GW_NS" > /tmp/httpbin-gw.yaml || {
        log_error "生成 Gateway YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "istio-gw:apply-gateway" "/tmp/" || {
        log_error "应用 Gateway 失败"
        return 1
    }

    # 步骤 7: 写入 VirtualService YAML + 应用
    log_info "步骤 7: 部署 VirtualService"
    runme print istio-gw:virtualservice-yaml > /tmp/httpbin-vs.yaml || {
        log_error "生成 VirtualService YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "istio-gw:apply-virtualservice" "/tmp/" || {
        log_error "应用 VirtualService 失败"
        return 1
    }

    # ==========================================
    # Section 2: Verification（验证流量路由）
    # ==========================================

    # 步骤 8: 创建 curl 命名空间
    log_info "步骤 8: 创建 curl 命名空间"
    _create_namespace_safe istio-gw:create-curl-ns curl || {
        log_error "创建 curl 命名空间失败"
        return 1
    }

    # 步骤 9: 部署 curl 客户端
    log_info "步骤 9: 部署 curl 客户端"
    kubectl_apply_with_mirror istio-gw:deploy-curl || {
        log_error "部署 curl 客户端失败"
        return 1
    }
    _wait_for_deployment curl curl

    # 步骤 10: 获取 curl pod 名称（设置环境变量）
    log_info "步骤 10: 获取 curl pod 名称"
    eval "$(runme print istio-gw:get-curl-pod)" || {
        log_error "获取 curl pod 名称失败"
        return 1
    }
    export CURL_POD
    log_info "CURL_POD=$CURL_POD"

    # 步骤 11: 测试 /headers 端点（期望 200 OK；命令含网关占位符，先渲染再 eval）
    log_info "步骤 11: 测试 /headers 端点"
    local headers_cmd headers_output headers_expected
    headers_cmd=$(_gw_render_block istio-gw:test-headers "$GW_NAME" "$GW_NS")
    headers_output=$(eval "$headers_cmd" 2>&1) || {
        log_error "测试 /headers 端点失败"
        log_error "输出: $headers_output"
        return 1
    }
    headers_expected=$(runme print istio-gw:test-headers-output)
    if ! __cmp_elided "$headers_output" "$headers_expected"; then
        log_error "/headers 端点验证失败"
        log_error "期待输出: $headers_expected"
        log_error "实际输出: $headers_output"
        return 1
    fi
    log_success "/headers 端点验证通过（HTTP 200 OK）"

    # 步骤 12: 测试 /get 端点（期望 404 Not Found）
    log_info "步骤 12: 测试 /get 端点"
    local get_cmd get_output get_expected
    get_cmd=$(_gw_render_block istio-gw:test-get "$GW_NAME" "$GW_NS")
    get_output=$(eval "$get_cmd" 2>&1) || true
    get_expected=$(runme print istio-gw:test-get-output)
    if ! __cmp_elided "$get_output" "$get_expected"; then
        log_error "/get 端点验证失败"
        log_error "期待输出: $get_expected"
        log_error "实际输出: $get_output"
        return 1
    fi
    log_success "/get 端点验证通过（HTTP 404 Not Found）"

    # 步骤 13: 暴露 gateway service 为 LoadBalancer（命令含占位符，渲染后 eval）
    log_info "步骤 13: 暴露 gateway 为 LoadBalancer"
    local lb_cmd
    lb_cmd=$(_gw_render_block istio-gw:expose-lb "$GW_NAME" "$GW_NS")
    eval "$lb_cmd" || {
        log_error "暴露 gateway 为 LoadBalancer 失败"
        return 1
    }
    # 等待 svc 的 LoadBalancer ingress 可用
    _wait_for_ingress_lb "$GW_NS" "$GW_NAME" || return 1

    # 步骤 14: 获取 INGRESS_HOST（先取 ingress[0].ip，为空再回退取 hostname）
    log_info "步骤 14: 获取 INGRESS_HOST"
    eval "$(_gw_render_block istio-gw:get-ingress-host "$GW_NAME" "$GW_NS")" || {
        log_error "获取 INGRESS_HOST (ip) 失败"
        return 1
    }
    export INGRESS_HOST
    if [ -z "$INGRESS_HOST" ]; then
        log_info "loadBalancer ingress[0].ip 为空，回退取 hostname"
        eval "$(_gw_render_block istio-gw:get-ingress-host-fallback "$GW_NAME" "$GW_NS")" || {
            log_error "获取 INGRESS_HOST (hostname) 失败"
            return 1
        }
        export INGRESS_HOST
    fi
    log_info "INGRESS_HOST=$INGRESS_HOST"

    # 步骤 15: 外部访问测试
    # 根据 INGRESS_HOST 是否为 IPv6 地址（含冒号）选择 IPv4 / IPv6 测试命令；
    # 文档示例由本地终端执行，测试改为经 curl pod 在集群内发起，避免本地代理等干扰。
    # 文档对外部访问无 -output 块，使用 __cmp_lines 校验关键行（对响应头顺序免疫）。
    log_info "步骤 15: 外部访问测试"
    local external_cmd external_output
    if [[ "$INGRESS_HOST" == *:* ]]; then
        log_info "检测到 IPv6 地址，使用 IPv6 测试命令"
        external_cmd=$(runme print istio-gw:test-external-ipv6)
    else
        log_info "检测到 IPv4 地址，使用 IPv4 测试命令"
        external_cmd=$(runme print istio-gw:test-external)
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
    log_success "Istio Gateway + VirtualService 暴露服务测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源
cleanup_exposing_a_service_via_istio_gateway() {
    log_info "=========================================="
    log_info "清理 Istio Gateway + VirtualService 测试资源"
    log_info "=========================================="

    local rc=0

    # 删除 httpbin / curl 命名空间（文档块驱动）
    runme run istio-gw:cleanup || {
        log_error "清理命名空间失败"
        rc=1
    }

    # 删除注入网关命名空间（install_gateway_via_injection 所建，测试基建）
    kubectl delete namespace "$GW_NS" --ignore-not-found || rc=1

    # 回收外部 IP 地址池（仅 ENABLE_METALLB=true 生效）
    teardown_external_ip_pools "$SINGLE_CLUSTER_NAME" || rc=1

    [ "$rc" -eq 0 ] && log_success "测试资源清理完成"
    return "$rc"
}
