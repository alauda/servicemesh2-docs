#!/usr/bin/env bash
# Waypoint 代理部署文档测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

test_waypoint_proxies() {
    log_info "=========================================="
    log_info "开始 Waypoint 代理部署测试"
    log_info "=========================================="

    # 步骤 1: 生成 Gateway YAML 到 /tmp
    log_info "步骤 1: 生成 Gateway YAML 文件"
    runme print ambient-waypoint:gateway-yaml > /tmp/waypoint.yaml || {
        log_error "生成 Gateway YAML 失败"
        return 1
    }

    # 步骤 2: 应用 Gateway CR
    log_info "步骤 2: 应用 Gateway CR"
    kubectl_apply_runme_block "ambient-waypoint:apply-gateway" "/tmp/" || {
        log_error "应用 Gateway CR 失败"
        return 1
    }

    # 步骤 3: 等待 waypoint deployment 就绪
    log_info "步骤 3: 等待 waypoint deployment 就绪"
    _wait_for_deployment bookinfo waypoint

    # 步骤 4: 标记命名空间使用 waypoint
    log_info "步骤 4: 标记命名空间使用 waypoint"
    runme run ambient-waypoint:label-namespace || {
        log_error "标记命名空间使用 waypoint 失败"
        return 1
    }

    # 步骤 5: 验证 ztunnel services
    # 输出包含动态 VIP 地址，使用 __cmp_lines 验证关键字段
    log_info "步骤 5: 验证 ztunnel services"
    local services_output
    services_output=$(runme run ambient-waypoint:verify-services 2>&1)

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
+ waypoint
EOF
    )"; then
        log_error "Waypoint 服务验证失败"
        log_error "实际输出: $services_output"
        return 1
    fi
    log_success "所有 bookinfo 服务已关联 waypoint 代理"

    log_success "=========================================="
    log_success "Waypoint 代理部署测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
