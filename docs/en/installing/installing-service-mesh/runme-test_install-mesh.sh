#!/usr/bin/env bash
# 网格安装文档测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

# 测试函数:执行文档中的代码块并验证
test_install_mesh() {
    log_info "=========================================="
    log_info "开始网格安装测试"
    log_info "=========================================="
    
    # 1. 创建 IstioCNI 命名空间
    log_info "步骤 1: 创建 IstioCNI 命名空间"
    runme run install-mesh:create-namespace-istio-cni || {
        log_error "创建 IstioCNI 命名空间失败"
        return 1
    }
    
    # 2. 创建 IstioCNI 资源
    log_info "步骤 2: 创建 IstioCNI 资源"
    runme run install-mesh:create-istiocni || {
        log_error "创建 IstioCNI 资源失败"
        return 1
    }
    
    # 3. 等待 IstioCNI 就绪
    log_info "步骤 3: 等待 IstioCNI 就绪"
    runme run install-mesh:wait-istiocni-ready || {
        log_error "等待 IstioCNI 就绪失败"
        return 1
    }
    
    # 4. 创建 Istio 命名空间
    log_info "步骤 4: 创建 Istio 命名空间"
    runme run install-mesh:create-namespace-istio-system || {
        log_error "创建 Istio 命名空间失败"
        return 1
    }
    
    # 5. 创建 Istio 资源
    log_info "步骤 5: 创建 Istio 资源"
    runme run install-mesh:create-istio || {
        log_error "创建 Istio 资源失败"
        return 1
    }
    
    # 6. 等待 Istio 就绪
    log_info "步骤 6: 等待 Istio 就绪"
    runme run install-mesh:wait-istio-ready || {
        log_error "等待 Istio 就绪失败"
        return 1
    }
    
    # 7. 验证 IstioCNI 状态
    log_info "步骤 7: 验证 IstioCNI 状态"
    local istiocni_state
    istiocni_state=$(kubectl get istiocni default -o jsonpath='{.status.state}')
    
    if [ "$istiocni_state" != "Healthy" ]; then
        log_error "IstioCNI 状态验证失败"
        log_error "期待状态: Healthy"
        log_error "实际状态: $istiocni_state"
        return 1
    fi
    log_success "IstioCNI 状态验证通过"
    
    # 8. 验证 Istio 状态
    log_info "步骤 8: 验证 Istio 状态"
    local istio_state
    istio_state=$(kubectl get istio default -o jsonpath='{.status.state}')
    
    if [ "$istio_state" != "Healthy" ]; then
        log_error "Istio 状态验证失败"
        log_error "期待状态: Healthy"
        log_error "实际状态: $istio_state"
        return 1
    fi
    log_success "Istio 状态验证通过"
    
    log_success "=========================================="
    log_success "网格安装测试完成,所有验证通过!"
    log_success "=========================================="
    return 0
}
