#!/usr/bin/env bash
# Bookinfo 应用部署文档测试脚本

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
#   - 复用文档既有 ratings-pod curl 手法（bookinfo:verify-application），并与本仓
#     directing-traffic-into-the-mesh/*.sh 一致——对外访问经集群内 pod 发起：将命令开头的 curl
#     重定位进 ratings pod 执行（`-- curl ...`），`| grep` 仍留宿主侧（不依赖 ratings 容器带 grep），
#     避开宿主到网关 / LoadBalancer 地址的可达性与本地代理干扰；命令中的 ${GATEWAY_URL} 等由本 shell 展开；
#   - 网关 Gateway/VirtualService/HTTPRoute 配置下发到数据面有短延迟，故重试若干次。
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

# 测试函数:执行文档中的代码块并验证
test_deploying_bookinfo() {
    log_info "=========================================="
    log_info "开始 Bookinfo 应用部署测试"
    log_info "=========================================="

    # 1. 创建 bookinfo 命名空间
    log_info "步骤 1: 创建 bookinfo 命名空间"
    _create_namespace_safe bookinfo:create-namespace bookinfo || {
        log_error "创建 bookinfo 命名空间失败"
        return 1
    }

    # 2. 启用 sidecar 注入
    # 注:这里使用 InPlace 策略,如果需要测试 RevisionBased 策略,
    # 可以修改为使用 bookinfo:enable-sidecar-injection-revision
    log_info "步骤 2: 启用 sidecar 注入 (InPlace 策略)"
    runme run bookinfo:enable-sidecar-injection-inplace || {
        log_error "启用 sidecar 注入失败"
        return 1
    }

    # 3. (可选) 应用 discovery selector
    # 注:如果集群配置了 discoverySelectors,需要执行此步骤
    # log_info "步骤 3: 应用 discovery selector"
    # runme run bookinfo:apply-discovery-selector || {
    #     log_error "应用 discovery selector 失败"
    #     return 1
    # }

    # 4. 部署 bookinfo 应用
    log_info "步骤 3: 部署 bookinfo 应用"
    kubectl_apply_with_mirror bookinfo:deploy-application || {
        log_error "部署 bookinfo 应用失败"
        return 1
    }

    # 5. 等待 bookinfo deployments 就绪
    log_info "步骤 4: 等待 bookinfo deployments 就绪"
    _wait_for_deployment bookinfo details-v1
    _wait_for_deployment bookinfo productpage-v1
    _wait_for_deployment bookinfo ratings-v1
    _wait_for_deployment bookinfo reviews-v1
    _wait_for_deployment bookinfo reviews-v2
    _wait_for_deployment bookinfo reviews-v3
    log_success "所有 bookinfo deployments 已就绪"

    # 6. 验证服务
    log_info "步骤 5: 验证服务"
    local services_output
    services_output=$(runme run bookinfo:verify-services)

    local missing_services=()
    for svc in "details" "productpage" "ratings" "reviews"; do
        if ! echo "$services_output" | grep -q "$svc"; then
            missing_services+=("$svc")
        fi
    done

    if [ ${#missing_services[@]} -ne 0 ]; then
        log_error "服务验证失败,以下服务未找到:"
        printf '  - %s\n' "${missing_services[@]}"
        log_error "实际输出:"
        echo "$services_output"
        return 1
    fi
    log_success "所有服务验证通过"

    # 7. 验证 pods
    log_info "步骤 6: 验证 pods"
    local pods_output
    pods_output=$(runme run bookinfo:verify-pods)

    # TODO: 使用 __cmp_like 公共函数进行比较（现在测试时，发现该函数执行失败）
    local missing_pods=()
    for pod in "details-v1" "productpage-v1" "ratings-v1" "reviews-v1" "reviews-v2" "reviews-v3"; do
        if ! echo "$pods_output" | grep -q "$pod"; then
            missing_pods+=("$pod")
        fi
    done

    if [ ${#missing_pods[@]} -ne 0 ]; then
        log_error "Pods 验证失败,以下 Pods 未找到:"
        printf '  - %s\n' "${missing_pods[@]}"
        log_error "实际输出:"
        echo "$pods_output"
        return 1
    fi
    log_success "所有 pods 验证通过"

    # 8. 验证应用运行
    log_info "步骤 7: 验证应用运行"
    local app_output expected_app
    app_output=$(runme run bookinfo:verify-application)
    expected_app=$(runme print bookinfo:verify-application-output)

    if ! __cmp_contains "$app_output" "$expected_app"; then
        log_error "应用验证失败"
        log_error "期待输出: $expected_app"
        log_error "实际输出: $app_output"
        return 1
    fi
    log_success "应用运行验证通过"

    # 9. (可选) 生成请求流量（AUTO_GEN_BOOKINFO_TRAFFIC=true 时在 ratings pod 后台起流量）
    maybe_gen_bookinfo_traffic

    # ==========================================
    # 网关部分一：Istio Gateway Injection（注入网关）
    # 注入网关 Service 为 ClusterIP，文档面向人工使用 port-forward；
    # 按要求改为经本文档的 ratings 服务在集群内 curl 网关 Service 验证，不使用 port-forward。
    # ==========================================

    # 步骤 8: 内核兼容（CentOS7/kernel<4.11，注入网关监听 80 特权端口）——注入前先修补 mesh 级网关注入模板
    #         （受 ENABLE_GW_LINUX_KERNEL_COMPAT 门控，关闭时为 no-op）
    log_info "步骤 8: 注入网关内核兼容处理（如启用）"
    apply_kernel_compat_istio_gateway true || {
        log_error "注入网关内核兼容处理失败"
        return 1
    }

    # 步骤 9: 创建 istio-ingressgateway（Deployment + Service）
    log_info "步骤 9: 创建 istio-ingressgateway"
    kubectl_apply_with_mirror bookinfo:gw-inject-create-gateway || {
        log_error "创建 istio-ingressgateway 失败"
        return 1
    }

    # 步骤 10: 等待 istio-ingressgateway 就绪（要求：脚本内 wait，文档不补此步）
    log_info "步骤 10: 等待 istio-ingressgateway deployment 就绪"
    _wait_for_deployment bookinfo istio-ingressgateway || {
        log_error "istio-ingressgateway 未就绪"
        return 1
    }

    # 步骤 11: 配置 bookinfo 使用注入网关（Gateway + VirtualService）
    log_info "步骤 11: 配置 bookinfo 网关（Gateway + VirtualService）"
    kubectl_apply_with_mirror bookinfo:gw-inject-configure || {
        log_error "配置 bookinfo 网关失败"
        return 1
    }

    # 步骤 12: 应用 HPA（Optional：基于入口流量自动伸缩，scaleTargetRef 指向 istio-ingressgateway）
    log_info "步骤 12: 应用 HorizontalPodAutoscaler"
    runme print bookinfo:gw-inject-hpa-yaml | kubectl apply -f - || {
        log_error "应用 HPA 失败"
        return 1
    }

    # 步骤 13: 应用 PDB（Optional：节点上最小可用副本数）
    log_info "步骤 13: 应用 PodDisruptionBudget"
    runme print bookinfo:gw-inject-pdb-yaml | kubectl apply -f - || {
        log_error "应用 PDB 失败"
        return 1
    }

    # 步骤 14: 验证——经 ratings 服务在集群内 curl 注入网关 Service（istio-ingressgateway:80），
    #          流量经网关 → Gateway/VirtualService → productpage，验证网关链路；
    #          断言复用文档既有 bookinfo:verify-application-output（<title>Simple Bookstore App</title>）
    log_info "步骤 14: 经 ratings 服务验证注入网关访问"
    # 文档注入网关验证用 port-forward（面向人工）；按要求改为经 ratings 服务在集群内 curl 网关 Service，
    # 命令沿用文档既有 ratings-curl 手法（bookinfo:verify-application），目标改为注入网关 istio-ingressgateway:80，
    # 流量经 istio-ingressgateway → Gateway/VirtualService → productpage，验证网关链路。
    local inject_cmd inject_expected
    inject_cmd='curl -sS -g "http://istio-ingressgateway:80/productpage" | grep -o "<title>.*</title>"'
    inject_expected=$(runme print bookinfo:verify-application-output)
    if ! _verify_gateway_via_ratings_pod "$inject_cmd" "$inject_expected"; then
        log_error "注入网关访问验证失败"
        return 1
    fi
    log_success "注入网关访问验证通过"

    # ==========================================
    # 网关部分二：Kubernetes Gateway API
    # Gateway 会生成 LoadBalancer 类型 Service，需要外部地址池；
    # 按要求：ENABLE_METALLB != true 时跳过整节。
    # ==========================================
    if [ "${ENABLE_METALLB:-false}" = "true" ]; then
        # 步骤 15: 创建外部 IP 地址池（供 Gateway 生成的 LoadBalancer Service 取址）
        log_info "步骤 15: 创建外部 IP 地址池（MetalLB）"
        setup_external_ip_pools "$SINGLE_CLUSTER_NAME" || return 1

        # 步骤 16: 创建 Gateway + HTTPRoute
        log_info "步骤 16: 创建 Gateway 与 HTTPRoute"
        kubectl_apply_with_mirror bookinfo:gw-api-create-gateway || {
            log_error "创建 Gateway/HTTPRoute 失败"
            return 1
        }

        # 步骤 17: 内核兼容——给 Gateway 挂 parametersRef 并等待生成的 Deployment 重建就绪
        #          （监听 80 特权端口，run_as_root=true；门控关闭时 no-op）
        log_info "步骤 17: Gateway API 内核兼容处理（如启用）"
        apply_kernel_compat_k8s_gateway_api bookinfo bookinfo-gateway true || {
            log_error "Gateway API 内核兼容处理失败"
            return 1
        }

        # 步骤 18: 等待 Gateway programmed（LoadBalancer 地址就绪、配置下发完成）
        log_info "步骤 18: 等待 Gateway programmed"
        runme run bookinfo:gw-api-wait-programmed || {
            log_error "等待 Gateway programmed 失败"
            return 1
        }

        # 步骤 19: 获取 INGRESS_HOST（LoadBalancer 地址）
        log_info "步骤 19: 获取 INGRESS_HOST"
        eval "$(runme print bookinfo:gw-api-get-host)" || {
            log_error "获取 INGRESS_HOST 失败"
            return 1
        }
        export INGRESS_HOST
        if [ -z "$INGRESS_HOST" ]; then
            log_error "INGRESS_HOST 为空（Gateway 未分配到 LoadBalancer 地址）"
            return 1
        fi
        log_info "INGRESS_HOST=$INGRESS_HOST"

        # 步骤 20: 获取 INGRESS_PORT
        log_info "步骤 20: 获取 INGRESS_PORT"
        eval "$(runme print bookinfo:gw-api-get-port)" || {
            log_error "获取 INGRESS_PORT 失败"
            return 1
        }
        export INGRESS_PORT
        log_info "INGRESS_PORT=$INGRESS_PORT"

        # 步骤 21: 获取 GATEWAY_URL（按 INGRESS_HOST 是否为 IPv6 选择对应代码块）
        log_info "步骤 21: 获取 GATEWAY_URL"
        if [[ "$INGRESS_HOST" == *:* ]]; then
            log_info "检测到 IPv6 地址，使用 IPv6 GATEWAY_URL 代码块"
            eval "$(runme print bookinfo:gw-api-get-url-ipv6)" || {
                log_error "获取 GATEWAY_URL (IPv6) 失败"
                return 1
            }
        else
            eval "$(runme print bookinfo:gw-api-get-url)" || {
                log_error "获取 GATEWAY_URL 失败"
                return 1
            }
        fi
        export GATEWAY_URL
        log_info "GATEWAY_URL=$GATEWAY_URL"

        # 步骤 22: 打印 productpage 完整 URL（覆盖文档 echo 代码块）
        log_info "步骤 22: 打印 productpage 完整 URL"
        runme run bookinfo:gw-api-echo-url || {
            log_error "打印完整 URL 失败"
            return 1
        }

        # 步骤 23: 验证——取文档验证命令（bookinfo:gw-api-verify），经 ratings 服务在集群内执行，
        #          断言 bookinfo:gw-api-verify-output（命令内 ${GATEWAY_URL} 由本 shell 展开）
        log_info "步骤 23: 经 ratings 服务验证 Gateway API 访问"
        local gwapi_cmd gwapi_expected
        gwapi_cmd=$(runme print bookinfo:gw-api-verify)
        gwapi_expected=$(runme print bookinfo:gw-api-verify-output)
        if ! _verify_gateway_via_ratings_pod "$gwapi_cmd" "$gwapi_expected"; then
            log_error "Gateway API 访问验证失败"
            return 1
        fi
        log_success "Gateway API 访问验证通过"
    else
        log_warn "ENABLE_METALLB != true，跳过 Gateway API 网关测试"
    fi

    log_success "=========================================="
    log_success "Bookinfo 应用部署测试完成,所有验证通过!"
    log_success "=========================================="
    return 0
}

# cleanup 函数:清理测试资源
cleanup_deploying_bookinfo() {
    log_info "=========================================="
    log_info "清理 Bookinfo 测试资源"
    log_info "=========================================="

    local rc=0

    # 删除 bookinfo 命名空间（回收应用、注入网关与 Gateway API 的全部命名空间内资源）
    runme run bookinfo:cleanup || {
        log_error "删除 bookinfo 命名空间失败"
        rc=1
    }

    # 回收外部 IP 地址池（仅 ENABLE_METALLB=true 生效，否则 no-op）
    teardown_external_ip_pools "$SINGLE_CLUSTER_NAME" || rc=1

    [ "$rc" -eq 0 ] && log_success "Bookinfo 测试资源清理完成"
    return "$rc"
}
