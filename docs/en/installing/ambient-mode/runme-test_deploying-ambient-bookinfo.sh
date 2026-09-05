#!/usr/bin/env bash
# Ambient 模式下 Bookinfo 应用部署文档测试脚本

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# runme 命令可以在项目的任意目录中执行

# 经 bookinfo 的 ratings pod 在集群内执行「文档 curl 验证命令」并断言包含 expected（带重试）
# 用法: _verify_gateway_via_ratings_pod <doc_curl_grep_cmd> <expected_title>
# 说明:
#   - doc_curl_grep_cmd 为文档验证块原文（形如 curl ... "URL" | grep -o "<title>..."）；
#   - 复用文档既有 ratings-pod curl 手法（ambient-bookinfo:verify-application），并与本仓
#     directing-traffic-into-the-mesh/*.sh 一致——对外访问经集群内 pod 发起：将命令开头的 curl
#     重定位进 ratings pod 执行（`-- curl ...`），`| grep` 仍留宿主侧（不依赖 ratings 容器带 grep），
#     避开宿主到网关 / LoadBalancer 地址的可达性与本地代理干扰；命令中的 ${GATEWAY_URL} 等由本 shell 展开；
#   - Gateway/HTTPRoute 配置下发到数据面有短延迟，故重试若干次。
_verify_gateway_via_ratings_pod() {
    local doc_cmd="$1" expected="$2"
    local ratings_pod output="" attempt
    for ((attempt=1; attempt<=12; attempt++)); do
        ratings_pod=$(kubectl get pod -l app=ratings -n bookinfo \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
        if [ -n "$ratings_pod" ]; then
            output=$(eval "kubectl exec \"$ratings_pod\" -c ratings -n bookinfo -- ${doc_cmd}" 2>/dev/null || true)
            if __cmp_contains "$output" "$expected"; then
                return 0
            fi
        fi
        log_warn "网关访问验证未通过，重试中 ($attempt/12): 实际=[$output]"
        sleep 5
    done
    log_error "网关访问验证最终失败: 期待包含=[$expected] 实际=[$output]"
    return 1
}

test_deploying_bookinfo() {
    log_info "=========================================="
    log_info "开始 Ambient 模式 Bookinfo 应用部署测试"
    log_info "=========================================="

    # ==========================================
    # Section 1: Deploying the Bookinfo Application - Procedure
    # ==========================================

    # 1. 创建 bookinfo 命名空间
    log_info "步骤 1: 创建 bookinfo 命名空间"
    _create_namespace_safe ambient-bookinfo:create-namespace bookinfo || {
        log_error "创建 bookinfo 命名空间失败"
        return 1
    }

    # 2. 添加 istio-discovery 标签
    log_info "步骤 2: 添加 istio-discovery=enabled 标签"
    runme run ambient-bookinfo:label-discovery || {
        log_error "添加 istio-discovery 标签失败"
        return 1
    }

    # 3. 部署 bookinfo 应用
    log_info "步骤 3: 部署 bookinfo 应用"
    kubectl_apply_with_mirror ambient-bookinfo:deploy-application || {
        log_error "部署 bookinfo 应用失败"
        return 1
    }

    # 4. 部署 bookinfo-versions
    log_info "步骤 4: 部署 bookinfo-versions"
    kubectl_apply_with_mirror ambient-bookinfo:deploy-versions || {
        log_error "部署 bookinfo-versions 失败"
        return 1
    }

    # 5. 等待 bookinfo deployments 就绪（框架补充，文档不含此步）
    log_info "步骤 5: 等待 bookinfo deployments 就绪"
    _wait_for_deployment bookinfo details-v1
    _wait_for_deployment bookinfo productpage-v1
    _wait_for_deployment bookinfo ratings-v1
    _wait_for_deployment bookinfo reviews-v1
    _wait_for_deployment bookinfo reviews-v2
    _wait_for_deployment bookinfo reviews-v3
    log_success "所有 bookinfo deployments 已就绪"

    # 6. 加入 ambient mesh
    log_info "步骤 6: 加入 ambient mesh"
    runme run ambient-bookinfo:enroll-ambient || {
        log_error "加入 ambient mesh 失败"
        return 1
    }

    # ==========================================
    # Section 2: Deploying the Bookinfo Application - Verification
    # ==========================================

    # 7. 验证 services
    # 输出包含动态值（ClusterIP、AGE），使用 __cmp_lines 验证关键字段
    log_info "步骤 7: 验证 services"
    local services_output
    services_output=$(runme run ambient-bookinfo:verify-services 2>&1)

    if ! __cmp_lines "$services_output" "$(cat <<'EOF'
+ details
+ details-v1
+ productpage
+ productpage-v1
+ ratings
+ ratings-v1
+ reviews
+ reviews-v1
+ reviews-v2
+ reviews-v3
EOF
    )"; then
        log_error "Services 验证失败"
        log_error "实际输出: $services_output"
        return 1
    fi
    log_success "所有 services 验证通过"

    # 8. 验证 pods 运行状态
    # 输出包含动态值（pod 名称后缀、AGE），使用 __cmp_lines 验证关键字段
    log_info "步骤 8: 验证 pods 运行状态"
    local pods_output
    pods_output=$(runme run ambient-bookinfo:verify-pods 2>&1)

    if ! __cmp_lines "$pods_output" "$(cat <<'EOF'
+ details-v1
+ productpage-v1
+ ratings-v1
+ reviews-v1
+ reviews-v2
+ reviews-v3
EOF
    )"; then
        log_error "Pods 验证失败"
        log_error "实际输出: $pods_output"
        return 1
    fi
    log_success "所有 pods 验证通过"

    # 9. 验证应用响应
    log_info "步骤 9: 验证应用响应"
    local expected_app
    expected_app=$(runme print ambient-bookinfo:verify-application-output)

    # NOTE: 同上——ambient 纳管后 kubelet 探针会杀 ratings 容器，退避期内 exec 报
    # `container not found`，故按块重试 24×5s。
    if ! retry_runme_verify ambient-bookinfo:verify-application __cmp_contains "$expected_app" 24 5; then
        log_error "应用验证失败"
        log_error "期待输出: $expected_app"
        log_error "实际输出: $RETRY_RUNME_OUTPUT"
        return 1
    fi
    log_success "应用运行验证通过"

    # 10. 验证 ztunnel 代理
    # 输出包含动态值（IP、pod 名称后缀），使用 __cmp_lines 验证关键字段。
    #
    # 必须按内容重试：步骤 6 给命名空间打上 ambient 标签后，ztunnel 要过一小会儿
    # 才把已有 pod 纳管，这期间 `istioctl ztunnel-config workload` 的 PROTOCOL 列
    # 仍是 TCP，要等纳管完成才变成 HBONE。命令本身退出码一直是 0，所以只重试
    # 退出码没用。已在 ACP 4.3.1 单节点环境实测：同一份镜像连跑两次，一次赶上
    # 一次没赶上，是典型竞态。
    log_info "步骤 10: 验证 ztunnel 代理"
    local ztunnel_output=""
    local ztunnel_expected
    ztunnel_expected="$(cat <<'EOF'
+ details-v1
+ productpage-v1
+ ratings-v1
+ reviews-v1
+ reviews-v2
+ reviews-v3
+ HBONE
EOF
    )"
    _verify_ztunnel_enrolled() {
        ztunnel_output="$(runme run ambient-bookinfo:verify-ztunnel 2>&1)"
        __cmp_lines "$ztunnel_output" "$ztunnel_expected"
    }
    if ! retry_command _verify_ztunnel_enrolled 30 5; then
        log_error "ZTunnel 验证失败"
        log_error "实际输出: $ztunnel_output"
        return 1
    fi
    log_success "ZTunnel 代理验证通过"

    # 11. (可选) 生成请求流量（AUTO_GEN_BOOKINFO_TRAFFIC=true 时在 ratings pod 后台起流量）
    maybe_gen_bookinfo_traffic

    # ==========================================
    # Section 3: Accessing the Bookinfo Application via a Gateway
    # ambient 模式只支持 Gateway API（不使用注入网关 / Istio Gateway + VirtualService）。
    # Gateway 会生成 LoadBalancer 类型 Service，需要外部地址池；
    # 与 sidecar 版 bookinfo 测试一致：ENABLE_METALLB != true 时跳过整节。
    # ==========================================
    if [ "${ENABLE_METALLB:-false}" = "true" ]; then
        # 步骤 12: 创建外部 IP 地址池（供 Gateway 生成的 LoadBalancer Service 取址）
        log_info "步骤 12: 创建外部 IP 地址池（MetalLB）"
        setup_external_ip_pools "$SINGLE_CLUSTER_NAME" || return 1

        # 步骤 13: 为 istio 网关类打 seccompProfile overlay
        # bookinfo 命名空间启用 Restricted PSA，网关 pod 需要 RuntimeDefault seccomp 才能准入；
        # 必须在创建 Gateway 之前打，否则网关 Deployment 会被准入控制拒绝
        log_info "步骤 13: 为 istio 网关类打 seccompProfile overlay"
        runme run ambient-bookinfo:gw-api-patch-gatewayclass || {
            log_error "配置 istio 网关类 seccompProfile 失败"
            return 1
        }

        # 步骤 14: 创建 Gateway + HTTPRoute
        log_info "步骤 14: 创建 Gateway 与 HTTPRoute"
        kubectl_apply_with_mirror ambient-bookinfo:gw-api-create-gateway || {
            log_error "创建 Gateway/HTTPRoute 失败"
            return 1
        }

        # 步骤 15: 内核兼容——给 Gateway 挂 parametersRef 并等待生成的 Deployment 重建就绪
        #          （监听 80 特权端口，run_as_root=true；门控关闭时 no-op）
        log_info "步骤 15: Gateway API 内核兼容处理（如启用）"
        apply_kernel_compat_k8s_gateway_api bookinfo bookinfo-gateway true || {
            log_error "Gateway API 内核兼容处理失败"
            return 1
        }

        # 步骤 16: 等待 Gateway programmed（LoadBalancer 地址就绪、配置下发完成）
        log_info "步骤 16: 等待 Gateway programmed"
        runme run ambient-bookinfo:gw-api-wait-programmed || {
            log_error "等待 Gateway programmed 失败"
            return 1
        }
        # Gateway 生成的 Service 名为 <gateway-name>-istio；再确认 LoadBalancer 地址已下发，
        # 避免下一步取到空的 INGRESS_HOST
        _wait_for_ingress_lb bookinfo bookinfo-gateway-istio || return 1

        # 步骤 17: 获取 INGRESS_HOST（LoadBalancer 地址）
        log_info "步骤 17: 获取 INGRESS_HOST"
        eval "$(runme print ambient-bookinfo:gw-api-get-host)" || {
            log_error "获取 INGRESS_HOST 失败"
            return 1
        }
        export INGRESS_HOST
        if [ -z "$INGRESS_HOST" ]; then
            log_error "INGRESS_HOST 为空（Gateway 未分配到 LoadBalancer 地址）"
            return 1
        fi
        log_info "INGRESS_HOST=$INGRESS_HOST"

        # 步骤 18: 获取 INGRESS_PORT
        log_info "步骤 18: 获取 INGRESS_PORT"
        eval "$(runme print ambient-bookinfo:gw-api-get-port)" || {
            log_error "获取 INGRESS_PORT 失败"
            return 1
        }
        export INGRESS_PORT
        log_info "INGRESS_PORT=$INGRESS_PORT"

        # 步骤 19: 获取 GATEWAY_URL（按 INGRESS_HOST 是否为 IPv6 选择对应代码块）
        log_info "步骤 19: 获取 GATEWAY_URL"
        if [[ "$INGRESS_HOST" == *:* ]]; then
            log_info "检测到 IPv6 地址，使用 IPv6 GATEWAY_URL 代码块"
            eval "$(runme print ambient-bookinfo:gw-api-get-url-ipv6)" || {
                log_error "获取 GATEWAY_URL (IPv6) 失败"
                return 1
            }
        else
            eval "$(runme print ambient-bookinfo:gw-api-get-url)" || {
                log_error "获取 GATEWAY_URL 失败"
                return 1
            }
        fi
        export GATEWAY_URL
        log_info "GATEWAY_URL=$GATEWAY_URL"

        # 步骤 20: 打印 productpage 完整 URL（覆盖文档 echo 代码块）
        log_info "步骤 20: 打印 productpage 完整 URL"
        runme run ambient-bookinfo:gw-api-echo-url || {
            log_error "打印完整 URL 失败"
            return 1
        }

        # 步骤 21: 验证——取文档验证命令（ambient-bookinfo:gw-api-verify），经 ratings 服务在集群内执行，
        #          断言 ambient-bookinfo:gw-api-verify-output（命令内 ${GATEWAY_URL} 由本 shell 展开）
        log_info "步骤 21: 经 ratings 服务验证 Gateway API 访问"
        local gwapi_cmd gwapi_expected
        gwapi_cmd=$(runme print ambient-bookinfo:gw-api-verify)
        gwapi_expected=$(runme print ambient-bookinfo:gw-api-verify-output)
        if ! _verify_gateway_via_ratings_pod "$gwapi_cmd" "$gwapi_expected"; then
            log_error "Gateway API 访问验证失败"
            return 1
        fi
        log_success "Gateway API 访问验证通过"
    else
        log_warn "ENABLE_METALLB != true，跳过 Gateway API 网关测试"
    fi

    log_success "=========================================="
    log_success "Ambient 模式 Bookinfo 应用部署测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源
cleanup_deploying_bookinfo() {
    log_info "=========================================="
    log_info "清理 Ambient Bookinfo 测试资源"
    log_info "=========================================="

    local rc=0

    # 删除 bookinfo 命名空间（回收应用与 Gateway API 的全部命名空间内资源）
    runme run ambient-bookinfo:cleanup || {
        log_error "清理资源失败"
        rc=1
    }

    # 回收外部 IP 地址池（仅 ENABLE_METALLB=true 生效，否则 no-op）
    teardown_external_ip_pools "$SINGLE_CLUSTER_NAME" || rc=1

    [ "$rc" -eq 0 ] && log_success "测试资源清理完成"
    return "$rc"
}
