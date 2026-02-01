#!/usr/bin/env bash
# 网格卸载文档测试脚本（仅测试 Uninstalling via the CLI 部分）

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

# 测试函数：执行文档中的代码块并验证
test_uninstalling_alauda_service_mesh() {
    log_info "=========================================="
    log_info "开始网格卸载测试 (CLI 方式)"
    log_info "=========================================="

    # 1. 获取 Istio 资源名称
    log_info "步骤 1: 获取 Istio 资源名称"
    local istio_output
    istio_output=$(runme run uninstall-mesh:get-istio 2>&1) || {
        log_error "获取 Istio 资源失败"
        log_error "输出: $istio_output"
        return 1
    }

    # 从输出中提取 Istio 资源名称（第二行第一列）
    local istio_name
    istio_name=$(echo "$istio_output" | awk 'NR==2 {print $1}')
    if [ -z "$istio_name" ]; then
        log_error "无法解析 Istio 资源名称"
        return 1
    fi
    log_info "Istio 资源名称: $istio_name"

    # 2. 删除 Istio 资源（使用 runme print 获取命令模板，替换为实际名称后执行）
    log_info "步骤 2: 删除 Istio 资源"
    local delete_istio_cmd
    delete_istio_cmd=$(runme print uninstall-mesh:delete-istio)
    # 将模板中的占位符替换为实际资源名称
    delete_istio_cmd="${delete_istio_cmd//<name_of_custom_resource>/$istio_name}"
    log_info "执行命令: $delete_istio_cmd"

    local delete_istio_output
    delete_istio_output=$(eval "$delete_istio_cmd" 2>&1) || {
        log_error "删除 Istio 资源失败"
        log_error "输出: $delete_istio_output"
        return 1
    }

    # 验证删除输出
    local expected_delete_istio_output
    expected_delete_istio_output=$(runme print uninstall-mesh:delete-istio-output)
    expected_delete_istio_output="${expected_delete_istio_output//<name_of_custom_resource>/$istio_name}"
    if ! __cmp_contains "$delete_istio_output" "$expected_delete_istio_output"; then
        log_error "删除 Istio 资源验证失败"
        log_error "期待输出: $expected_delete_istio_output"
        log_error "实际输出: $delete_istio_output"
        return 1
    fi
    log_success "删除 Istio 资源成功"

    # 3. 获取 IstioCNI 资源
    log_info "步骤 3: 获取 IstioCNI 资源"
    local istiocni_output
    istiocni_output=$(runme run uninstall-mesh:get-istiocni 2>&1) || {
        log_error "获取 IstioCNI 资源失败"
        log_error "输出: $istiocni_output"
        return 1
    }

    # 验证 IstioCNI 资源存在
    if ! __cmp_contains "$istiocni_output" "default"; then
        log_error "未找到 IstioCNI 资源"
        log_error "实际输出: $istiocni_output"
        return 1
    fi
    log_success "获取 IstioCNI 资源成功"

    # 4. 删除 IstioCNI 资源
    log_info "步骤 4: 删除 IstioCNI 资源"
    local delete_istiocni_output
    delete_istiocni_output=$(runme run uninstall-mesh:delete-istiocni 2>&1) || {
        log_error "删除 IstioCNI 资源失败"
        log_error "输出: $delete_istiocni_output"
        return 1
    }

    # 验证删除输出
    local expected_istiocni_output
    expected_istiocni_output=$(runme print uninstall-mesh:delete-istiocni-output)
    if ! __cmp_contains "$delete_istiocni_output" "$expected_istiocni_output"; then
        log_error "删除 IstioCNI 资源验证失败"
        log_error "期待包含: $expected_istiocni_output"
        log_error "实际输出: $delete_istiocni_output"
        return 1
    fi
    log_success "删除 IstioCNI 资源成功"

    # 5. 删除 istio-system 命名空间
    log_info "步骤 5: 删除 istio-system 命名空间"
    local delete_ns_istio_system_output
    delete_ns_istio_system_output=$(runme run uninstall-mesh:delete-ns-istio-system 2>&1) || {
        log_error "删除 istio-system 命名空间失败"
        log_error "输出: $delete_ns_istio_system_output"
        return 1
    }

    # 验证删除输出
    local expected_ns_istio_system_output
    expected_ns_istio_system_output=$(runme print uninstall-mesh:delete-ns-istio-system-output)
    if ! __cmp_contains "$delete_ns_istio_system_output" "$expected_ns_istio_system_output"; then
        log_error "删除 istio-system 命名空间验证失败"
        log_error "期待输出: $expected_ns_istio_system_output"
        log_error "实际输出: $delete_ns_istio_system_output"
        return 1
    fi
    log_success "删除 istio-system 命名空间成功"

    # 6. 删除 istio-cni 命名空间
    log_info "步骤 6: 删除 istio-cni 命名空间"
    local delete_ns_istio_cni_output
    delete_ns_istio_cni_output=$(runme run uninstall-mesh:delete-ns-istio-cni 2>&1) || {
        log_error "删除 istio-cni 命名空间失败"
        log_error "输出: $delete_ns_istio_cni_output"
        return 1
    }

    # 验证删除输出
    local expected_ns_istio_cni_output
    expected_ns_istio_cni_output=$(runme print uninstall-mesh:delete-ns-istio-cni-output)
    if ! __cmp_contains "$delete_ns_istio_cni_output" "$expected_ns_istio_cni_output"; then
        log_error "删除 istio-cni 命名空间验证失败"
        log_error "期待输出: $expected_ns_istio_cni_output"
        log_error "实际输出: $delete_ns_istio_cni_output"
        return 1
    fi
    log_success "删除 istio-cni 命名空间成功"

    # 7. 删除 servicemesh-operator2 subscription
    log_info "步骤 7: 删除 servicemesh-operator2 subscription"
    local delete_subscription_output
    delete_subscription_output=$(runme run uninstall-mesh:delete-subscription 2>&1) || {
        log_error "删除 subscription 失败"
        log_error "输出: $delete_subscription_output"
        return 1
    }

    # 验证删除输出
    local expected_subscription_output
    expected_subscription_output=$(runme print uninstall-mesh:delete-subscription-output)
    if ! __cmp_contains "$delete_subscription_output" "$expected_subscription_output"; then
        log_error "删除 subscription 验证失败"
        log_error "期待输出: $expected_subscription_output"
        log_error "实际输出: $delete_subscription_output"
        return 1
    fi
    log_success "删除 subscription 成功"

    # 8. 删除 Istio CRDs
    log_info "步骤 8: 删除 Istio CRDs"
    local delete_crds_output
    delete_crds_output=$(runme run uninstall-mesh:delete-crds 2>&1) || {
        log_error "删除 Istio CRDs 失败"
        log_error "输出: $delete_crds_output"
        return 1
    }
    log_success "删除 Istio CRDs 成功"

    log_success "=========================================="
    log_success "网格卸载测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
