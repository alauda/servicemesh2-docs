#!/usr/bin/env bash
# 双栈网格文档测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

# 测试函数：执行文档中的代码块并验证
test_dual_stack() {
    log_info "=========================================="
    log_info "开始双栈网格测试"
    log_info "=========================================="
    
    # 1. 创建 IstioCNI
    log_info "步骤 1: 创建 IstioCNI"
    runme run dual-stack:create-istio-cni || {
        log_error "创建 IstioCNI 失败"
        return 1
    }
    
    # 2. 创建 Istio
    log_info "步骤 2: 创建 Istio"
    runme run dual-stack:create-istio || {
        log_error "创建 Istio 失败"
        return 1
    }
    
    # 3. 等待 Istio 就绪
    log_info "步骤 3: 等待 Istio 就绪"
    runme run dual-stack:wait-istio-ready || {
        log_error "等待 Istio 就绪失败"
        return 1
    }
    
    # 4. 创建命名空间
    log_info "步骤 4: 创建测试命名空间"
    runme run dual-stack:create-namespaces || {
        log_error "创建命名空间失败"
        return 1
    }
    
    # 5. 启用 sidecar 注入
    log_info "步骤 5: 启用 sidecar 注入"
    runme run dual-stack:enable-sidecar-injection || {
        log_error "启用 sidecar 注入失败"
        return 1
    }
    
    # 6. 部署 tcp-echo dual-stack
    log_info "步骤 6: 部署 tcp-echo (dual-stack)"
    kubectl_apply_with_mirror dual-stack:deploy-tcp-echo-dual-stack || {
        log_error "部署 tcp-echo (dual-stack) 失败"
        return 1
    }
    
    # 7. 部署 tcp-echo IPv4
    log_info "步骤 7: 部署 tcp-echo (IPv4)"
    kubectl_apply_with_mirror dual-stack:deploy-tcp-echo-ipv4 || {
        log_error "部署 tcp-echo (IPv4) 失败"
        return 1
    }
    
    # 8. 部署 tcp-echo IPv6
    log_info "步骤 8: 部署 tcp-echo (IPv6)"
    kubectl_apply_with_mirror dual-stack:deploy-tcp-echo-ipv6 || {
        log_error "部署 tcp-echo (IPv6) 失败"
        return 1
    }
    
    # 9. 部署 sleep 应用
    log_info "步骤 9: 部署 sleep 应用"
    kubectl_apply_with_mirror dual-stack:deploy-sleep || {
        log_error "部署 sleep 应用失败"
        return 1
    }
    
    # 10. 等待所有部署就绪
    log_info "步骤 10: 等待所有部署就绪"
    runme run dual-stack:wait-deployments-ready || {
        log_error "等待部署就绪失败"
        return 1
    }
    
    # 11. 验证双栈服务配置
    log_info "步骤 11: 验证双栈服务配置"
    local output expected
    output=$(runme run dual-stack:verify-config)
    expected=$(runme print dual-stack:verify-config-output)
    
    if ! __cmp_contains "$output" "$expected"; then
        log_error "验证双栈配置失败"
        log_error "期待输出: $expected"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "双栈配置验证通过"
    
    # 12. 验证双栈服务连接性
    log_info "步骤 12: 验证双栈服务连接性"
    output=$(runme run dual-stack:test-connectivity)
    expected=$(runme print dual-stack:test-connectivity-output)
    
    if ! __cmp_contains "$output" "$expected"; then
        log_error "验证双栈连接性失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "双栈连接性验证通过"
    
    # 13. 验证 IPv4 连接性
    log_info "步骤 13: 验证 IPv4 连接性"
    output=$(runme run dual-stack:test-ipv4-connectivity)
    expected=$(runme print dual-stack:test-ipv4-connectivity-output)
    
    if ! __cmp_contains "$output" "$expected"; then
        log_error "验证 IPv4 连接性失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "IPv4 连接性验证通过"
    
    # 14. 验证 IPv6 连接性
    log_info "步骤 14: 验证 IPv6 连接性"
    output=$(runme run dual-stack:test-ipv6-connectivity)
    expected=$(runme print dual-stack:test-ipv6-connectivity-output)
    
    if ! __cmp_contains "$output" "$expected"; then
        log_error "验证 IPv6 连接性失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "IPv6 连接性验证通过"
    
    log_success "=========================================="
    log_success "双栈网格测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源
cleanup_dual_stack() {
    log_info "=========================================="
    log_info "清理双栈测试资源"
    log_info "=========================================="
    
    runme run dual-stack:cleanup || {
        log_error "清理双栈资源失败"
        return 1
    }
    
    log_success "双栈测试资源清理完成"
    return 0
}
