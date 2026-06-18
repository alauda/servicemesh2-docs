#!/usr/bin/env bash
# Istio APIs（gateway injection 网关）路由 Egress 流量测试脚本

set -e

# FRAMEWORK_ROOT 由 docs-runme-tests/run.sh 引擎注入
: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# runme 命令可以在项目的任意目录中执行

# egress 注入网关名 / 命名空间（文档中以 <gateway_name>/<gateway_namespace> 占位，测试统一取此值）
GW_NAME=egressgateway
GW_NS=istio-egress

test_routing_egress_traffic_via_istio_apis() {
    log_info "=========================================="
    log_info "开始 Istio APIs Egress 流量路由测试"
    log_info "=========================================="

    # ==========================================
    # 前置：通过 gateway injection 安装 egress 网关（文档前置条件）
    # ==========================================

    # 步骤 1: (仅 ENABLE_GW_LINUX_KERNEL_COMPAT=true 生效) egress 网关监听 80 特权端口，
    #         先按 Scenario 2 修补 mesh 级注入模板（去 sysctls + root），须在装网关前完成
    apply_kernel_compat_istio_gateway true || return 1

    # 步骤 2: 通过 gateway injection 安装 egress 网关（含去 infra 调度；内核兼容时 Deployment 以 root 运行）
    install_gateway_via_injection "$GW_NAME" "$GW_NS" || return 1

    # ==========================================
    # Section 1: Procedure（配置 ServiceEntry / Gateway / DestinationRule / VirtualService）
    # ==========================================

    # 步骤 3: 创建 curl 命名空间
    log_info "步骤 3: 创建 curl 命名空间"
    _create_namespace_safe istio-egress:create-curl-ns curl || {
        log_error "创建 curl 命名空间失败"
        return 1
    }

    # 步骤 4: 为 curl 命名空间启用 sidecar 注入（InPlace 升级策略）
    log_info "步骤 4: 启用 sidecar 注入"
    runme run istio-egress:label-injection || {
        log_error "启用 sidecar 注入失败"
        return 1
    }

    # 步骤 5: 部署 curl 应用
    log_info "步骤 5: 部署 curl 应用"
    kubectl_apply_with_mirror istio-egress:deploy-curl || {
        log_error "部署 curl 应用失败"
        return 1
    }
    _wait_for_deployment curl curl

    # 步骤 6: 获取 curl pod 名称（文档块已 export，eval 后即为导出变量）
    log_info "步骤 6: 获取 curl pod 名称"
    eval "$(runme print istio-egress:get-curl-pod)" || {
        log_error "获取 curl pod 名称失败"
        return 1
    }
    export CURL_POD
    log_info "CURL_POD=$CURL_POD"

    # 步骤 7: 写入 ServiceEntry YAML（无占位符）+ 应用
    log_info "步骤 7: 部署 ServiceEntry"
    runme print istio-egress:service-entry-yaml > /tmp/http-se.yaml || {
        log_error "生成 ServiceEntry YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "istio-egress:apply-service-entry" "/tmp/" || {
        log_error "应用 ServiceEntry 失败"
        return 1
    }

    # 步骤 8: 验证 ServiceEntry 已生效（curl 经 sidecar 直连外部主机，期望返回 HTTP 状态）
    # 访问外部网络，可能受波动影响，使用 retry_command 重试
    log_info "步骤 8: 验证 ServiceEntry 直连外部主机"
    local se_output
    se_output=$(retry_command "runme run istio-egress:verify-se-direct 2>&1" 10 5)
    if ! __cmp_lines "$se_output" "$(cat <<'EOF'
+ HTTP/
EOF
    )"; then
        log_error "ServiceEntry 直连验证失败"
        log_error "实际输出: $se_output"
        return 1
    fi
    log_success "ServiceEntry 直连验证通过"

    # 步骤 9: 写入 Gateway + DestinationRule YAML（替换占位符）+ 应用
    log_info "步骤 9: 部署 egress Gateway 与 DestinationRule"
    _gw_render_block istio-egress:gateway-yaml "$GW_NAME" "$GW_NS" > /tmp/http-egress-gw.yaml || {
        log_error "生成 Gateway/DestinationRule YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "istio-egress:apply-gateway" "/tmp/" || {
        log_error "应用 Gateway/DestinationRule 失败"
        return 1
    }

    # 步骤 10: 写入 VirtualService YAML（替换占位符）+ 应用
    log_info "步骤 10: 部署 VirtualService"
    _gw_render_block istio-egress:virtualservice-yaml "$GW_NAME" "$GW_NS" > /tmp/http-egress-vs.yaml || {
        log_error "生成 VirtualService YAML 失败"
        return 1
    }
    kubectl_apply_runme_block "istio-egress:apply-virtualservice" "/tmp/" || {
        log_error "应用 VirtualService 失败"
        return 1
    }

    # 步骤 11: 应用 Telemetry 启用 egress 网关访问日志（文档步骤 13 的前置；占位符渲染后 eval）
    #          须在重发请求前启用，网关日志方能捕获该请求
    log_info "步骤 11: 启用 egress 网关访问日志 (Telemetry)"
    eval "$(_gw_render_block istio-egress:telemetry "$GW_NAME" "$GW_NS")" || {
        log_error "应用 Telemetry 失败"
        return 1
    }

    # ==========================================
    # Section 2: Verification（经 egress 网关访问外部主机）
    # ==========================================

    # 步骤 12: 重发请求，经 egress 网关访问外部主机（期望 302→200；外部网络，重试）
    # 输出含动态值（location 等），使用 __cmp_lines 校验关键稳定行
    log_info "步骤 12: 经 egress 网关访问外部主机"
    local egress_output
    egress_output=$(retry_command "runme run istio-egress:verify-egress 2>&1" 10 5)
    if ! __cmp_lines "$egress_output" "$(cat <<'EOF'
+ HTTP/2 200
+ server: envoy
EOF
    )"; then
        log_error "egress 访问验证失败"
        log_error "实际输出: $egress_output"
        return 1
    fi
    log_success "egress 访问验证通过"

    # 步骤 13: 校验请求确实经 egress 网关转发（网关访问日志含外部主机与 outbound 集群名）
    # 每轮重发请求确保访问日志产生，再取网关最后一行日志；外部网络 + 日志刷新滞后，手动重试
    log_info "步骤 13: 校验 egress 网关访问日志"
    local log_cmd log_output ok=1 i
    log_cmd=$(_gw_render_block istio-egress:verify-gateway-log "$GW_NAME" "$GW_NS")
    for i in $(seq 1 10); do
        runme run istio-egress:verify-egress >/dev/null 2>&1 || true
        sleep 2
        log_output=$(eval "$log_cmd" 2>&1 || true)
        if echo "$log_output" | grep -q 'outbound|80||docs.alauda.io'; then
            ok=0
            break
        fi
        sleep 3
    done
    if [ "$ok" -ne 0 ]; then
        log_error "egress 网关访问日志校验失败（重试后日志仍无 docs.alauda.io 记录）"
        log_error "实际输出: $log_output"
        return 1
    fi
    if ! __cmp_lines "$log_output" "$(cat <<'EOF'
+ GET
+ docs.alauda.io
+ outbound|80||docs.alauda.io
EOF
    )"; then
        log_error "egress 网关访问日志校验失败"
        log_error "实际输出: $log_output"
        return 1
    fi
    log_success "egress 网关访问日志校验通过"

    log_success "=========================================="
    log_success "Istio APIs Egress 流量路由测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源
cleanup_routing_egress_traffic_via_istio_apis() {
    log_info "=========================================="
    log_info "清理 Istio APIs Egress 流量路由测试资源"
    log_info "=========================================="

    local rc=0

    # 删除 curl 命名空间（文档块驱动；连带 ServiceEntry / VirtualService / curl）
    runme run istio-egress:cleanup || {
        log_error "清理 curl 命名空间失败"
        rc=1
    }

    # 删除 egress 注入网关命名空间（install_gateway_via_injection 所建，测试基建；
    # 连带 Gateway / DestinationRule / Telemetry）
    kubectl delete namespace "$GW_NS" --ignore-not-found || rc=1

    [ "$rc" -eq 0 ] && log_success "测试资源清理完成"
    return "$rc"
}
