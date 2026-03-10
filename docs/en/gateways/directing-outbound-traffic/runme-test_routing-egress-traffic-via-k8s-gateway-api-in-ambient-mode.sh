#!/usr/bin/env bash
# Ambient 模式下通过 K8s Gateway API 路由 Egress 流量测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

test_ambient_egress_gateway() {
    log_info "=========================================="
    log_info "开始 Ambient 模式 Egress Gateway 测试"
    log_info "=========================================="

    # 步骤 1: 创建 egress-gateway 命名空间
    log_info "步骤 1: 创建 egress-gateway 命名空间"
    runme run ambient-egress:create-namespace || {
        log_error "创建 egress-gateway 命名空间失败"
        return 1
    }

    # 步骤 2: 添加 istio-discovery 标签
    log_info "步骤 2: 添加 istio-discovery=enabled 标签"
    runme run ambient-egress:label-discovery || {
        log_error "添加 istio-discovery 标签失败"
        return 1
    }

    # 步骤 3: 启用 ambient 模式
    log_info "步骤 3: 启用 ambient 模式"
    runme run ambient-egress:label-ambient || {
        log_error "启用 ambient 模式失败"
        return 1
    }

    # 步骤 4: 生成 egress-se.yaml 文件
    log_info "步骤 4: 生成 egress-se.yaml 文件"
    runme print ambient-egress:service-entry-yaml > /tmp/egress-se.yaml || {
        log_error "生成 egress-se.yaml 失败"
        return 1
    }

    # 步骤 5: 应用 ServiceEntry
    log_info "步骤 5: 应用 ServiceEntry"
    kubectl_apply_runme_block "ambient-egress:apply-service-entry" "/tmp/" || {
        log_error "应用 ServiceEntry 失败"
        return 1
    }

    # 步骤 6: 生成 waypoint.yaml 文件
    log_info "步骤 6: 生成 waypoint.yaml 文件"
    runme print ambient-egress:waypoint-yaml > /tmp/waypoint.yaml || {
        log_error "生成 waypoint.yaml 失败"
        return 1
    }

    # 步骤 7: 应用 waypoint 配置
    log_info "步骤 7: 应用 waypoint 配置"
    kubectl_apply_runme_block "ambient-egress:apply-waypoint" "/tmp/" || {
        log_error "应用 waypoint 失败"
        return 1
    }

    # 步骤 8: 等待 waypoint 部署就绪
    log_info "步骤 8: 等待 waypoint 部署就绪"
    _wait_for_deployment egress-gateway waypoint

    # 步骤 9: 验证 Gateway 状态
    # 输出包含动态值（ADDRESS、AGE），使用 __cmp_lines 验证关键字段
    log_info "步骤 9: 验证 Gateway 状态"
    local gw_output
    gw_output=$(runme run ambient-egress:verify-gateway 2>&1)

    if ! __cmp_lines "$gw_output" "$(cat <<'EOF'
+ waypoint
+ istio-waypoint
+ True
EOF
    )"; then
        log_error "Gateway 状态验证失败"
        log_error "实际输出: $gw_output"
        return 1
    fi
    log_success "Gateway 状态验证通过"

    # 步骤 10: 部署 curl 客户端
    log_info "步骤 10: 部署 curl 客户端"
    kubectl_apply_with_mirror ambient-egress:deploy-curl || {
        log_error "部署 curl 客户端失败"
        return 1
    }

    # 步骤 11: 等待 curl 部署就绪
    log_info "步骤 11: 等待 curl 部署就绪"
    _wait_for_deployment egress-gateway curl

    # 步骤 12: 获取 curl pod 名称
    log_info "步骤 12: 获取 curl pod 名称"
    eval "$(runme print ambient-egress:get-curl-pod)" || {
        log_error "获取 curl pod 名称失败"
        return 1
    }
    log_info "CURL_POD=$CURL_POD"

    # 步骤 13: 验证 egress 连通性
    # 请求外部服务 httpbin.org，可能受网络波动影响，使用 retry_command 重试
    # 输出包含动态值，使用 __cmp_lines 验证关键字段
    log_info "步骤 13: 验证 egress 连通性"
    local egress_output
    egress_output=$(retry_command "runme run ambient-egress:verify-egress 2>&1" 10 5)

    if ! __cmp_lines "$egress_output" "$(cat <<'EOF'
+ < HTTP/1.1 200 OK
+ < server: istio-envoy
EOF
    )"; then
        log_error "Egress 连通性验证失败"
        log_error "实际输出: $egress_output"
        return 1
    fi
    log_success "Egress 连通性验证通过"

    log_success "=========================================="
    log_success "Ambient 模式 Egress Gateway 测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源
cleanup_ambient_egress_gateway() {
    log_info "=========================================="
    log_info "清理 Ambient Egress Gateway 测试资源"
    log_info "=========================================="

    runme run ambient-egress:cleanup || {
        log_error "清理资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
