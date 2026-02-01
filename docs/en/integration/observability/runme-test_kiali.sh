#!/usr/bin/env bash
# Kiali 文档测试脚本
# 测试范围：Installing via the CLI 和 Configuring Monitoring with Kiali

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

test_kiali() {
    log_info "=========================================="
    log_info "开始 Kiali 文档测试"
    log_info "=========================================="
    
    log_info "开始安装 Kiali Operator"
    # 使用通用 install_operator 函数安装 kiali-operator
    install_operator \
        "kiali-operator" \
        "kiali-operator" \
        "$PKG_KIALI_OPERATOR_URL" \
        "install-kiali"
    log_success "Kiali Operator 安装测试完成"

    log_info "=========================================="
    log_info "开始配置 Kiali 与监控集成"
    log_info "=========================================="

    # 检查 PLATFORM_CA 环境变量
    # TODO: 后续会自动从 Global 集群获取 CA 证书
    if [ -z "$PLATFORM_CA" ]; then
        log_error "PLATFORM_CA 环境变量未设置"
        return 1
    fi
    log_success "PLATFORM_CA 环境变量已设置"

    # 1. 获取平台配置
    log_info "步骤 1: 获取平台配置"
    # 使用 eval 执行 runme print 的内容，以便在当前 shell 中设置环境变量
    eval "$(runme print config-kiali:get-platform-config)" || {
        log_error "获取平台配置失败"
        return 1
    }

    # 验证必要的环境变量
    if [ -z "$PLATFORM_URL" ] || [ -z "$CLUSTER_NAME" ] || [ -z "$OIDC_CLIENT_SECRET" ]; then
        log_error "无法获取必要的平台配置"
        log_error "PLATFORM_URL: $PLATFORM_URL"
        log_error "CLUSTER_NAME: $CLUSTER_NAME"
        return 1
    fi
    log_success "平台配置获取成功"
    log_info "PLATFORM_URL: $PLATFORM_URL"
    log_info "CLUSTER_NAME: $CLUSTER_NAME"

    local output expected
    # 2. 创建 kiali secret
    log_info "步骤 2: 创建 kiali Secret"
    kubectl -n istio-system delete secret kiali --ignore-not-found=true
    
    output=$(runme run config-kiali:create-secret-kiali)
    expected=$(runme print config-kiali:create-secret-kiali-output)
    if ! __cmp_contains "$output" "$expected"; then
        log_error "创建 kiali Secret 失败"
        log_error "期待输出: $expected"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "kiali Secret 创建成功"

    # 3. 创建 monitoring basic auth secret
    log_info "步骤 3: 创建 kiali-monitoring-basic-auth Secret"
    kubectl -n istio-system delete secret kiali-monitoring-basic-auth --ignore-not-found=true
    
    output=$(runme run config-kiali:create-secret-monitoring-basic-auth)
    expected=$(runme print config-kiali:create-secret-monitoring-basic-auth-output)
    if ! __cmp_contains "$output" "$expected"; then
        log_error "创建 kiali-monitoring-basic-auth Secret 失败"
        log_error "期待输出: $expected"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "kiali-monitoring-basic-auth Secret 创建成功"

    # 4. 生成 kiali.yaml 文件
    log_info "步骤 4: 生成 kiali.yaml 文件"
    runme print config-kiali:kiali-yaml > "/tmp/kiali.yaml" || {
        log_error "获取 kiali.yaml 模板失败"
        return 1
    }
    log_success "kiali.yaml 文件生成成功"

    # 5. 应用 Kiali 配置
    log_info "步骤 5: 应用 Kiali 配置"
    kubectl_apply_runme_block "config-kiali:apply-kiali" "/tmp/" || {
        log_error "应用 Kiali 配置失败"
        return 1
    }
    log_success "Kiali 配置应用成功"

    # 6. 等待 Kiali CR 就绪
    log_info "步骤 6: 等待 Kiali CR 就绪"
    kubectl -nistio-system wait --for=condition=Successful kiali/kiali --timeout=3m || {
        log_warn "等待 Kiali CR 就绪超时，继续执行..."
    }

    log_info "等待 Kiali Deployment 就绪"
    _wait_for_deployment istio-system kiali || {
        log_error "等待 Kiali Deployment 就绪超时"
        return 1
    }

    # 7. Kiali 访问地址
    log_info "Kiali 访问地址: $PLATFORM_URL/clusters/$CLUSTER_NAME/kiali"

    log_success "Kiali 配置测试完成"

    log_success "=========================================="
    log_success "Kiali 文档测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
