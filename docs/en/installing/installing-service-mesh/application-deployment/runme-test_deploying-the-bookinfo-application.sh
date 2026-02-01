#!/usr/bin/env bash
# Bookinfo 应用部署文档测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

# 测试函数:执行文档中的代码块并验证
test_deploying_bookinfo() {
    log_info "=========================================="
    log_info "开始 Bookinfo 应用部署测试"
    log_info "=========================================="
    
    # 1. 创建 bookinfo 命名空间
    log_info "步骤 1: 创建 bookinfo 命名空间"
    runme run bookinfo:create-namespace || {
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

    # 9. (可选) 生成请求流量
    if [ "${AUTO_GEN_BOOKINFO_TRAFFIC:-false}" == "true" ]; then
        log_info "步骤 8: 生成请求流量"
        local ratings_pod
        ratings_pod=$(kubectl get pod -l app=ratings -n bookinfo -o jsonpath='{.items[0].metadata.name}')
        if [ -n "$ratings_pod" ]; then
            log_info "在 ratings pod ($ratings_pod) 中启动流量生成..."
            kubectl exec "$ratings_pod" -c ratings -n bookinfo -- bash -lc "(while true; do curl -sS productpage:9080/productpage >/dev/null; sleep 9.9; done) >/dev/null 2>&1 & disown"
            log_success "流量生成已启动"
        else
            log_warn "未找到 ratings pod, 跳过流量生成"
        fi
    fi
        
    # TODO: 网关部分测试
    # 注:网关部分的测试需要根据实际部署方式(Gateway Injection 或 Gateway API)来实现
    # 可以参考文档中的两种方式分别实现测试
    
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
    
    # TODO: 等待文档补充清理步骤
    # 临时清理方案:删除 bookinfo 命名空间
    log_info "删除 bookinfo 命名空间"
    kubectl delete namespace bookinfo --ignore-not-found=true || {
        log_warn "删除 bookinfo 命名空间失败"
    }
    
    log_success "Bookinfo 测试资源清理完成"
    return 0
}
