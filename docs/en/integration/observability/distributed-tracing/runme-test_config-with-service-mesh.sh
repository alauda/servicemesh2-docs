#!/usr/bin/env bash
# 网格调用链集成配置测试脚本
# 对应文档: docs/en/integration/observability/distributed-tracing/config-with-service-mesh.mdx
# 覆盖范围: 「Configuring distributed tracing data collection with Service Mesh」与
#           「Removing the Service Mesh tracing configuration」章节。
#
# 前置依赖: 已安装 Istio (install-mesh)、Telemetry asm-default (metrics-and-mesh)、
#           以及 jaeger-system 中的 otel-collector (installing-distributed-tracing)。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

test_config_with_service_mesh() {
    log_info "=========================================="
    log_info "开始网格调用链集成配置测试"
    log_info "=========================================="

    # 步骤 1: Patch Istio resource，启用 tracing 并配置 OpenTelemetry extensionProvider
    log_info "步骤 1: Patch Istio 启用 tracing 与 otel extensionProvider"
    local output
    output=$(runme run mesh-tracing:patch-istio-config 2>&1) || {
        log_error "Patch Istio 失败"
        log_error "输出: $output"
        return 1
    }
    if ! __cmp_contains "$output" "patched"; then
        log_error "Istio patch 输出未包含 'patched': $output"
        return 1
    fi
    log_success "Istio tracing 配置已应用"

    # 步骤 2: Patch Telemetry asm-default，启用 otel provider
    log_info "步骤 2: Patch Telemetry asm-default 启用 otel provider"
    output=$(runme run mesh-tracing:patch-telemetry-config 2>&1) || {
        log_error "Patch Telemetry 失败"
        log_error "输出: $output"
        return 1
    }
    if ! __cmp_contains "$output" "patched"; then
        log_error "Telemetry patch 输出未包含 'patched': $output"
        return 1
    fi
    log_success "Telemetry otel provider 已配置"

    log_success "=========================================="
    log_success "网格调用链集成配置测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

cleanup_config_with_service_mesh() {
    log_info "=========================================="
    log_info "清理网格调用链集成配置"
    log_info "=========================================="

    # 步骤 1: 移除 Telemetry asm-default 的 tracing 配置
    log_info "步骤 1: 移除 Telemetry asm-default tracing 配置"
    local output
    output=$(runme run mesh-tracing:remove-telemetry-tracing-config 2>&1) || {
        log_warn "移除 Telemetry tracing 失败（可能已被移除）: $output"
    }

    # 步骤 2: 在 Istio 中关闭 enableTracing
    log_info "步骤 2: 关闭 Istio enableTracing"
    output=$(runme run mesh-tracing:disable-istio-tracing 2>&1) || {
        log_warn "关闭 Istio enableTracing 失败: $output"
    }

    log_success "网格调用链集成配置清理完成"
    return 0
}
