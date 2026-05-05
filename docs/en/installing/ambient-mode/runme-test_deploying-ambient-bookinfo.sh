#!/usr/bin/env bash
# Ambient 模式下 Bookinfo 应用部署文档测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

test_deploying_bookinfo() {
    log_info "=========================================="
    log_info "开始 Ambient 模式 Bookinfo 应用部署测试"
    log_info "=========================================="

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

    # 5. 等待 bookinfo deployments 就绪
    log_info "步骤 5: 等待 bookinfo deployments 就绪"
    _wait_for_deployment bookinfo details-v1
    _wait_for_deployment bookinfo productpage-v1
    _wait_for_deployment bookinfo ratings-v1
    _wait_for_deployment bookinfo reviews-v1
    _wait_for_deployment bookinfo reviews-v2
    _wait_for_deployment bookinfo reviews-v3
    log_success "所有 bookinfo deployments 已就绪"

    # 6. 验证 pods 运行状态
    # 输出包含动态值（pod 名称后缀、AGE），使用 __cmp_lines 验证关键字段
    log_info "步骤 6: 验证 pods 运行状态"
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

    # 7. 验证应用响应
    log_info "步骤 7: 验证应用响应"
    local app_output expected_app
    app_output=$(runme run ambient-bookinfo:verify-application 2>&1)
    expected_app=$(runme print ambient-bookinfo:verify-application-output)

    if ! __cmp_contains "$app_output" "$expected_app"; then
        log_error "应用验证失败"
        log_error "期待输出: $expected_app"
        log_error "实际输出: $app_output"
        return 1
    fi
    log_success "应用运行验证通过"

    # 8. 加入 ambient mesh
    log_info "步骤 8: 加入 ambient mesh"
    runme run ambient-bookinfo:enroll-ambient || {
        log_error "加入 ambient mesh 失败"
        return 1
    }

    # 9. 验证 ztunnel 代理
    # 输出包含动态值（IP、pod 名称后缀），使用 __cmp_lines 验证关键字段
    log_info "步骤 9: 验证 ztunnel 代理"
    local ztunnel_output
    ztunnel_output=$(runme run ambient-bookinfo:verify-ztunnel 2>&1)

    if ! __cmp_lines "$ztunnel_output" "$(cat <<'EOF'
+ details-v1
+ productpage-v1
+ ratings-v1
+ reviews-v1
+ reviews-v2
+ reviews-v3
+ HBONE
EOF
    )"; then
        log_error "ZTunnel 验证失败"
        log_error "实际输出: $ztunnel_output"
        return 1
    fi
    log_success "ZTunnel 代理验证通过"

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

    runme run ambient-bookinfo:cleanup || {
        log_error "清理资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
