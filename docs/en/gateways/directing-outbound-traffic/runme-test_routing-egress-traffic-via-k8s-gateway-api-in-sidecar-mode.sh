#!/usr/bin/env bash
# Sidecar 模式下通过 K8s Gateway API 路由 Egress 流量测试脚本

set -e

# FRAMEWORK_ROOT 由 docs-runme-tests/run.sh 引擎注入
: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# runme 命令可以在项目的任意目录中执行

test_routing_egress_traffic_via_k8s_gateway_api_in_sidecar_mode() {
    log_info "=========================================="
    log_info "开始 Sidecar 模式 K8s Gateway API Egress 流量路由测试"
    log_info "=========================================="

    # ==========================================
    # Section 1: Procedure（部署 egress 网关）
    # ==========================================

    # 步骤 1: 创建 egress-gateway 命名空间
    log_info "步骤 1: 创建 egress-gateway 命名空间"
    _create_namespace_safe sidecar-egress:create-namespace egress-gateway || {
        log_error "创建 egress-gateway 命名空间失败"
        return 1
    }

    # 步骤 2: 写入 egress 网关 CR YAML（ServiceEntry + Gateway + 2×HTTPRoute；无占位符）+ 应用
    log_info "步骤 2: 部署 egress 网关 CR (ServiceEntry/Gateway/HTTPRoute)"
    runme print sidecar-egress:gateway-cr-yaml > /tmp/egress-gateway-cr.yaml || {
        log_error "生成 egress 网关 CR YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "sidecar-egress:apply-gateway-cr" "/tmp/" || {
        log_error "应用 egress 网关 CR 失败"
        return 1
    }

    # 步骤 3: (仅 ENABLE_GW_LINUX_KERNEL_COMPAT=true 生效) egress 网关监听 80 特权端口，
    #         按 Scenario 2 (root) 为 K8s Gateway API 网关挂 asm-kube-gateway-options
    apply_kernel_compat_k8s_gateway_api egress-gateway httpbin-egress-gateway || return 1

    # 步骤 4: 等待 K8s Gateway API 自动置备的 egress 网关 Deployment 就绪
    log_info "步骤 4: 等待 egress 网关 Deployment 就绪"
    _wait_for_deployment egress-gateway httpbin-egress-gateway-istio

    # 步骤 5: 验证 Gateway 状态（PROGRAMMED=True）
    # 输出含动态值（ADDRESS、AGE），使用 __cmp_lines 校验关键字段
    log_info "步骤 5: 验证 Gateway 状态"
    local gw_output
    gw_output=$(runme run sidecar-egress:verify-gateway 2>&1)
    if ! __cmp_lines "$gw_output" "$(cat <<'EOF'
+ httpbin-egress-gateway
+ True
EOF
    )"; then
        log_error "Gateway 状态验证失败"
        log_error "实际输出: $gw_output"
        return 1
    fi
    log_success "Gateway 状态验证通过"

    # ==========================================
    # Section 2: Verification（经 egress 网关访问外部主机）
    # ==========================================

    # 步骤 6: 创建 curl 命名空间
    log_info "步骤 6: 创建 curl 命名空间"
    _create_namespace_safe sidecar-egress:create-curl-ns curl || {
        log_error "创建 curl 命名空间失败"
        return 1
    }

    # 步骤 7: 为 curl 命名空间启用 sidecar 注入（InPlace 升级策略）
    log_info "步骤 7: 启用 sidecar 注入"
    runme run sidecar-egress:label-injection || {
        log_error "启用 sidecar 注入失败"
        return 1
    }

    # 步骤 8: 部署 curl 应用
    log_info "步骤 8: 部署 curl 应用"
    kubectl_apply_with_mirror sidecar-egress:deploy-curl || {
        log_error "部署 curl 应用失败"
        return 1
    }
    _wait_for_deployment curl curl

    # 步骤 9: 获取 curl pod 名称（文档块已 export，eval 后即为导出变量）
    log_info "步骤 9: 获取 curl pod 名称"
    eval "$(runme print sidecar-egress:get-curl-pod)" || {
        log_error "获取 curl pod 名称失败"
        return 1
    }
    export CURL_POD
    log_info "CURL_POD=$CURL_POD"

    # 步骤 10: 验证经 egress 网关访问外部主机
    # curl -v 输出含动态值（X-Envoy-Peer-Metadata-Id 含网关 pod 名）；外部网络，使用 retry_command 重试
    # __cmp_lines 校验：200 OK + server: envoy + 响应回显含 egress 网关 pod 前缀（egress 路由的强证据）
    log_info "步骤 10: 验证 egress 连通性"
    local egress_output
    egress_output=$(retry_command "runme run sidecar-egress:verify-egress 2>&1" 10 5)
    if ! __cmp_lines "$egress_output" "$(cat <<'EOF'
+ < HTTP/1.1 200 OK
+ < server: envoy
+ httpbin-egress-gateway-istio
EOF
    )"; then
        log_error "egress 连通性验证失败"
        log_error "实际输出: $egress_output"
        return 1
    fi
    log_success "egress 连通性验证通过"

    log_success "=========================================="
    log_success "Sidecar 模式 K8s Gateway API Egress 流量路由测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源
cleanup_routing_egress_traffic_via_k8s_gateway_api_in_sidecar_mode() {
    log_info "=========================================="
    log_info "清理 Sidecar 模式 K8s Gateway API Egress 测试资源"
    log_info "=========================================="

    # 删除 curl 与 egress-gateway 两个命名空间（文档块驱动；
    # 连带 Gateway / ServiceEntry / HTTPRoute / 自动置备网关 / asm-kube-gateway-options ConfigMap）
    runme run sidecar-egress:cleanup || {
        log_error "清理资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
