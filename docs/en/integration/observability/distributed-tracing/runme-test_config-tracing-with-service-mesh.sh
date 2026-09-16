#!/usr/bin/env bash
# 网格调用链集成配置测试脚本
# 对应文档: docs/en/integration/observability/distributed-tracing/config-tracing-with-service-mesh.mdx
# 覆盖范围: 「Configuring distributed tracing data collection with Service Mesh」与
#           「Removing the Service Mesh tracing configuration」章节。
#
# 前置依赖: 已安装 Istio (install-mesh)、Telemetry asm-default (metrics-and-mesh)、
#           以及 jaeger-system 中的 otel-collector (installing-distributed-tracing)。
#
# 多集群:   ./run.sh --project mesh --file config-tracing-with-service-mesh --cluster <name>
#           指定执行目标集群。网格侧配置按控制面走（见 _mesh_tracing_has_control_plane）：
#           多主拓扑两个集群各配一遍；主-远拓扑只配主集群，远端集群只做步骤 1。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# 当前集群是否跑着 Istio 控制面
# 说明: 主-远拓扑的远端集群没有本地 istiod，其 sidecar 的 tracing 配置由主集群的
#       istiod 下发——远端集群 Istio CR 的 meshConfig 不参与，Telemetry 也只读主
#       （config）集群的，asm-default 在远端集群根本不存在（metrics-and-mesh 按文档
#       在远端集群跳过创建），patch 必然 NotFound。故远端集群只做步骤 1（给
#       jaeger-system 打服务发现标签，让主集群 istiod 能发现该集群的 Collector
#       Service），步骤 2/3 跳过而不是判失败。判定方式与 metrics-and-mesh 一致。
_mesh_tracing_has_control_plane() {
    kubectl -n istio-system get pods -l app=istiod -o name 2>/dev/null | grep -q .
}

test_config_tracing_with_service_mesh() {
    log_info "=========================================="
    log_info "开始网格调用链集成配置测试"
    log_info "=========================================="

    # 步骤 1: (可选) 为 jaeger-system 命名空间打服务发现标签。
    # 仅当 Istio 启用了 discoverySelectors 时该步骤才必须；未启用时打标签也无副作用，
    # jaeger-system 不存在时跳过。命名空间已带相同标签时 kubectl 以非 0 退出，
    # 属幂等场景需容忍。
    log_info "步骤 1: (可选) 为 jaeger-system 命名空间打 istio-discovery 标签"
    local output
    if ! kubectl get namespace jaeger-system >/dev/null 2>&1; then
        log_warn "未检测到 jaeger-system 命名空间，跳过步骤 1"
    else
        output=$(runme run mesh-tracing:label-jaeger-system-discovery 2>&1) || {
            if __cmp_contains "$output" "already has a value"; then
                log_warn "jaeger-system 已存在 istio-discovery 标签，跳过（幂等场景）"
            else
                log_error "为 jaeger-system 打服务发现标签失败"
                log_error "输出: $output"
                return 1
            fi
        }
        log_success "jaeger-system 服务发现标签已就绪"
    fi

    # 网格侧配置（步骤 2/3）只在跑控制面的集群上做
    if ! _mesh_tracing_has_control_plane; then
        log_warn "当前集群没有 istiod（主-远拓扑的远端集群），跳过 Istio 与 Telemetry 的网格侧配置"
        log_success "=========================================="
        log_success "网格调用链集成配置测试完成（远端集群仅处理服务发现标签）"
        log_success "=========================================="
        return 0
    fi

    # 步骤 2: Patch Istio resource，启用 tracing 并配置 OpenTelemetry extensionProvider
    log_info "步骤 2: Patch Istio 启用 tracing 与 otel extensionProvider"
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

    # 步骤 3: Patch Telemetry asm-default，启用 otel provider
    log_info "步骤 3: Patch Telemetry asm-default 启用 otel provider"
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

cleanup_config_tracing_with_service_mesh() {
    log_info "=========================================="
    log_info "清理网格调用链集成配置"
    log_info "=========================================="

    # 远端集群上没做过网格侧配置，无需清理（同上方门控）
    if ! _mesh_tracing_has_control_plane; then
        log_warn "当前集群没有 istiod（主-远拓扑的远端集群），无网格侧配置需要清理"
        return 0
    fi

    # 步骤 1: 移除 Telemetry asm-default 的 tracing 配置
    log_info "步骤 1: 移除 Telemetry asm-default tracing 配置"
    local output
    output=$(runme run mesh-tracing:remove-telemetry-tracing-config 2>&1) || {
        log_warn "移除 Telemetry tracing 失败（可能已被移除）: $output"
    }

    # 步骤 2: 在 Istio 中关闭 enableTracing
    log_info "步骤 2: 关闭 Istio enableTracing"
    output=$(runme run mesh-tracing:disable-istio-tracing-config 2>&1) || {
        log_warn "关闭 Istio enableTracing 失败: $output"
    }

    log_success "网格调用链集成配置清理完成"
    return 0
}
