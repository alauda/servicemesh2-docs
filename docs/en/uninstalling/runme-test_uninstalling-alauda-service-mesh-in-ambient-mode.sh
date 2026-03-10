#!/usr/bin/env bash
# Ambient 模式网格卸载文档测试脚本（仅测试 Uninstalling via the CLI 和 Deleting Istio CRDs 部分）

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

# 测试函数：执行文档中的代码块并验证
test_uninstalling_alauda_service_mesh_in_ambient_mode() {
    log_info "=========================================="
    log_info "开始 Ambient 模式网格卸载测试 (CLI 方式)"
    log_info "=========================================="

    # 1. 列出 waypoint Gateway 资源
    log_info "步骤 1: 列出 waypoint Gateway 资源"
    local list_waypoints_output
    list_waypoints_output=$(runme run uninstall-ambient:list-waypoints 2>&1) || {
        log_error "列出 waypoint Gateway 失败"
        log_error "输出: $list_waypoints_output"
        return 1
    }

    # 输出包含动态值（IP、AGE 等），使用 __cmp_lines 验证关键字段
    if ! __cmp_lines "$list_waypoints_output" "$(cat <<'EOF'
+ waypoint
+ istio-waypoint
EOF
)"; then
        log_error "列出 waypoint Gateway 验证失败"
        log_error "实际输出: $list_waypoints_output"
        return 1
    fi
    log_success "列出 waypoint Gateway 成功"

    # 2. 删除 waypoint Gateway 资源
    log_info "步骤 2: 删除 waypoint Gateway 资源"
    local delete_waypoints_output
    delete_waypoints_output=$(runme run uninstall-ambient:delete-waypoints 2>&1) || {
        log_error "删除 waypoint Gateway 失败"
        log_error "输出: $delete_waypoints_output"
        return 1
    }

    # 删除输出中的 gateway 名称和命名空间可能因环境而异，验证关键字段
    if ! __cmp_lines "$delete_waypoints_output" "$(cat <<'EOF'
+ deleted
EOF
)"; then
        log_error "删除 waypoint Gateway 验证失败"
        log_error "实际输出: $delete_waypoints_output"
        return 1
    fi
    log_success "删除 waypoint Gateway 成功"

    # 3. 列出 ambient 命名空间
    log_info "步骤 3: 列出 ambient 命名空间"
    local list_ambient_ns_output
    list_ambient_ns_output=$(runme run uninstall-ambient:list-ambient-ns 2>&1) || {
        log_error "列出 ambient 命名空间失败"
        log_error "输出: $list_ambient_ns_output"
        return 1
    }

    # 输出包含动态值（AGE 等），使用 __cmp_lines 验证关键字段
    if ! __cmp_lines "$list_ambient_ns_output" "$(cat <<'EOF'
+ Active
EOF
)"; then
        log_error "列出 ambient 命名空间验证失败"
        log_error "实际输出: $list_ambient_ns_output"
        return 1
    fi
    log_success "列出 ambient 命名空间成功"

    # 4. 移除 ambient 标签
    log_info "步骤 4: 移除 ambient 数据面标签"
    runme run uninstall-ambient:remove-ambient-label || {
        log_error "移除 ambient 标签失败"
        return 1
    }
    log_success "移除 ambient 标签成功"

    # 5. 获取 ZTunnel 资源
    log_info "步骤 5: 获取 ZTunnel 资源"
    local get_ztunnel_output
    get_ztunnel_output=$(runme run uninstall-ambient:get-ztunnel 2>&1) || {
        log_error "获取 ZTunnel 资源失败"
        log_error "输出: $get_ztunnel_output"
        return 1
    }

    # 输出包含动态值（VERSION、AGE 等），使用 __cmp_lines 验证关键字段
    if ! __cmp_lines "$get_ztunnel_output" "$(cat <<'EOF'
+ default
+ ztunnel
EOF
)"; then
        log_error "获取 ZTunnel 资源验证失败"
        log_error "实际输出: $get_ztunnel_output"
        return 1
    fi
    log_success "获取 ZTunnel 资源成功"

    # 6. 删除 ZTunnel 资源
    log_info "步骤 6: 删除 ZTunnel 资源"
    local delete_ztunnel_output
    delete_ztunnel_output=$(runme run uninstall-ambient:delete-ztunnel 2>&1) || {
        log_error "删除 ZTunnel 资源失败"
        log_error "输出: $delete_ztunnel_output"
        return 1
    }

    local expected_delete_ztunnel_output
    expected_delete_ztunnel_output=$(runme print uninstall-ambient:delete-ztunnel-output)
    if ! __cmp_contains "$delete_ztunnel_output" "$expected_delete_ztunnel_output"; then
        log_error "删除 ZTunnel 资源验证失败"
        log_error "期待输出: $expected_delete_ztunnel_output"
        log_error "实际输出: $delete_ztunnel_output"
        return 1
    fi
    log_success "删除 ZTunnel 资源成功"

    # 7. 获取 Istio 资源名称
    log_info "步骤 7: 获取 Istio 资源名称"
    local istio_output
    istio_output=$(runme run uninstall-ambient:get-istio 2>&1) || {
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

    # 8. 删除 Istio 资源（使用 runme print 获取命令模板，替换为实际名称后执行）
    log_info "步骤 8: 删除 Istio 资源"
    local delete_istio_cmd
    delete_istio_cmd=$(runme print uninstall-ambient:delete-istio)
    # 将模板中的占位符替换为实际资源名称
    delete_istio_cmd="${delete_istio_cmd//<name_of_custom_resource>/$istio_name}"
    log_info "执行命令: $delete_istio_cmd"

    local delete_istio_output
    delete_istio_output=$(eval "$delete_istio_cmd" 2>&1) || {
        log_error "删除 Istio 资源失败"
        log_error "输出: $delete_istio_output"
        return 1
    }

    # 验证删除输出（输出模板中的占位符也需要替换）
    local expected_delete_istio_output
    expected_delete_istio_output=$(runme print uninstall-ambient:delete-istio-output)
    expected_delete_istio_output="${expected_delete_istio_output//<name_of_custom_resource>/$istio_name}"
    if ! __cmp_contains "$delete_istio_output" "$expected_delete_istio_output"; then
        log_error "删除 Istio 资源验证失败"
        log_error "期待输出: $expected_delete_istio_output"
        log_error "实际输出: $delete_istio_output"
        return 1
    fi
    log_success "删除 Istio 资源成功"

    # 9. 获取 IstioCNI 资源
    log_info "步骤 9: 获取 IstioCNI 资源"
    local istiocni_output
    istiocni_output=$(runme run uninstall-ambient:get-istiocni 2>&1) || {
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

    # 10. 删除 IstioCNI 资源
    log_info "步骤 10: 删除 IstioCNI 资源"
    local delete_istiocni_output
    delete_istiocni_output=$(runme run uninstall-ambient:delete-istiocni 2>&1) || {
        log_error "删除 IstioCNI 资源失败"
        log_error "输出: $delete_istiocni_output"
        return 1
    }

    local expected_istiocni_output
    expected_istiocni_output=$(runme print uninstall-ambient:delete-istiocni-output)
    if ! __cmp_contains "$delete_istiocni_output" "$expected_istiocni_output"; then
        log_error "删除 IstioCNI 资源验证失败"
        log_error "期待输出: $expected_istiocni_output"
        log_error "实际输出: $delete_istiocni_output"
        return 1
    fi
    log_success "删除 IstioCNI 资源成功"

    # 11. 删除 ztunnel 命名空间
    log_info "步骤 11: 删除 ztunnel 命名空间"
    local delete_ns_ztunnel_output
    delete_ns_ztunnel_output=$(runme run uninstall-ambient:delete-ns-ztunnel 2>&1) || {
        log_error "删除 ztunnel 命名空间失败"
        log_error "输出: $delete_ns_ztunnel_output"
        return 1
    }

    local expected_ns_ztunnel_output
    expected_ns_ztunnel_output=$(runme print uninstall-ambient:delete-ns-ztunnel-output)
    if ! __cmp_contains "$delete_ns_ztunnel_output" "$expected_ns_ztunnel_output"; then
        log_error "删除 ztunnel 命名空间验证失败"
        log_error "期待输出: $expected_ns_ztunnel_output"
        log_error "实际输出: $delete_ns_ztunnel_output"
        return 1
    fi
    log_success "删除 ztunnel 命名空间成功"

    # 12. 删除 istio-system 命名空间
    log_info "步骤 12: 删除 istio-system 命名空间"
    local delete_ns_istio_system_output
    delete_ns_istio_system_output=$(runme run uninstall-ambient:delete-ns-istio-system 2>&1) || {
        log_error "删除 istio-system 命名空间失败"
        log_error "输出: $delete_ns_istio_system_output"
        return 1
    }

    local expected_ns_istio_system_output
    expected_ns_istio_system_output=$(runme print uninstall-ambient:delete-ns-istio-system-output)
    if ! __cmp_contains "$delete_ns_istio_system_output" "$expected_ns_istio_system_output"; then
        log_error "删除 istio-system 命名空间验证失败"
        log_error "期待输出: $expected_ns_istio_system_output"
        log_error "实际输出: $delete_ns_istio_system_output"
        return 1
    fi
    log_success "删除 istio-system 命名空间成功"

    # 13. 删除 istio-cni 命名空间
    log_info "步骤 13: 删除 istio-cni 命名空间"
    local delete_ns_istio_cni_output
    delete_ns_istio_cni_output=$(runme run uninstall-ambient:delete-ns-istio-cni 2>&1) || {
        log_error "删除 istio-cni 命名空间失败"
        log_error "输出: $delete_ns_istio_cni_output"
        return 1
    }

    local expected_ns_istio_cni_output
    expected_ns_istio_cni_output=$(runme print uninstall-ambient:delete-ns-istio-cni-output)
    if ! __cmp_contains "$delete_ns_istio_cni_output" "$expected_ns_istio_cni_output"; then
        log_error "删除 istio-cni 命名空间验证失败"
        log_error "期待输出: $expected_ns_istio_cni_output"
        log_error "实际输出: $delete_ns_istio_cni_output"
        return 1
    fi
    log_success "删除 istio-cni 命名空间成功"

    # 14. 删除 servicemesh-operator2 subscription
    log_info "步骤 14: 删除 servicemesh-operator2 subscription"
    local delete_subscription_output
    delete_subscription_output=$(runme run uninstall-ambient:delete-subscription 2>&1) || {
        log_error "删除 subscription 失败"
        log_error "输出: $delete_subscription_output"
        return 1
    }

    local expected_subscription_output
    expected_subscription_output=$(runme print uninstall-ambient:delete-subscription-output)
    if ! __cmp_contains "$delete_subscription_output" "$expected_subscription_output"; then
        log_error "删除 subscription 验证失败"
        log_error "期待输出: $expected_subscription_output"
        log_error "实际输出: $delete_subscription_output"
        return 1
    fi
    log_success "删除 subscription 成功"

    # 15. 删除 Istio CRDs
    log_info "步骤 15: 删除 Istio CRDs"
    local delete_crds_output
    delete_crds_output=$(runme run uninstall-ambient:delete-crds 2>&1) || {
        log_error "删除 Istio CRDs 失败"
        log_error "输出: $delete_crds_output"
        return 1
    }
    log_success "删除 Istio CRDs 成功"

    log_success "=========================================="
    log_success "Ambient 模式网格卸载测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
