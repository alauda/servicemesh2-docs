#!/usr/bin/env bash
# Kiali 卸载文档测试脚本（仅测试 Uninstalling via the CLI 部分）

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

# 测试函数：执行文档中的代码块并验证
test_uninstalling_alauda_build_of_kiali() {
    log_info "=========================================="
    log_info "开始 Kiali 卸载测试 (CLI 方式)"
    log_info "=========================================="

    # 1. 获取 Kiali 资源名称
    log_info "步骤 1: 获取 Kiali 资源名称"
    local kiali_output
    kiali_output=$(runme run uninstall-kiali:get-kiali 2>&1) || {
        log_error "获取 Kiali 资源失败"
        log_error "输出: $kiali_output"
        return 1
    }

    # 从输出中提取 Kiali 资源名称和命名空间（第二行）
    local kiali_namespace kiali_name
    kiali_namespace=$(echo "$kiali_output" | awk 'NR==2 {print $1}')
    kiali_name=$(echo "$kiali_output" | awk 'NR==2 {print $2}')
    if [ -z "$kiali_name" ] || [ -z "$kiali_namespace" ]; then
        log_error "无法解析 Kiali 资源名称或命名空间"
        return 1
    fi
    log_info "Kiali 资源: $kiali_namespace/$kiali_name"

    # 2. 删除 Kiali 资源（使用 runme print 获取命令模板，替换为实际名称后执行）
    log_info "步骤 2: 删除 Kiali 资源"
    local delete_kiali_cmd
    delete_kiali_cmd=$(runme print uninstall-kiali:delete-kiali)
    # 将模板中的占位符替换为实际资源名称和命名空间
    delete_kiali_cmd="${delete_kiali_cmd//<name_of_custom_resource>/$kiali_name}"
    delete_kiali_cmd="${delete_kiali_cmd//<namespace>/$kiali_namespace}"
    log_info "执行命令: $delete_kiali_cmd"

    local delete_kiali_output
    delete_kiali_output=$(eval "$delete_kiali_cmd" 2>&1) || {
        log_error "删除 Kiali 资源失败"
        log_error "输出: $delete_kiali_output"
        return 1
    }

    # 验证删除输出
    local expected_delete_kiali_output
    expected_delete_kiali_output=$(runme print uninstall-kiali:delete-kiali-output)
    expected_delete_kiali_output="${expected_delete_kiali_output//<name_of_custom_resource>/$kiali_name}"
    if ! __cmp_contains "$delete_kiali_output" "$expected_delete_kiali_output"; then
        log_error "删除 Kiali 资源验证失败"
        log_error "期待输出: $expected_delete_kiali_output"
        log_error "实际输出: $delete_kiali_output"
        return 1
    fi
    log_success "删除 Kiali 资源成功"

    # 3. 删除 kiali-operator subscription
    log_info "步骤 3: 删除 kiali-operator subscription"
    local delete_subscription_output
    delete_subscription_output=$(runme run uninstall-kiali:delete-subscription 2>&1) || {
        log_error "删除 subscription 失败"
        log_error "输出: $delete_subscription_output"
        return 1
    }

    # 验证删除输出
    local expected_subscription_output
    expected_subscription_output=$(runme print uninstall-kiali:delete-subscription-output)
    if ! __cmp_contains "$delete_subscription_output" "$expected_subscription_output"; then
        log_error "删除 subscription 验证失败"
        log_error "期待输出: $expected_subscription_output"
        log_error "实际输出: $delete_subscription_output"
        return 1
    fi
    log_success "删除 subscription 成功"

    # 4. 删除 Kiali CRDs
    log_info "步骤 4: 删除 Kiali CRDs"
    local delete_crds_output
    delete_crds_output=$(runme run uninstall-kiali:delete-crds 2>&1) || {
        log_error "删除 Kiali CRDs 失败"
        log_error "输出: $delete_crds_output"
        return 1
    }
    log_success "删除 Kiali CRDs 成功"

    log_success "=========================================="
    log_success "Kiali 卸载测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
