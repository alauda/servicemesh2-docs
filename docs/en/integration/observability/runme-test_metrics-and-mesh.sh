#!/usr/bin/env bash
# 指标与服务网格文档测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

# 测试函数：执行文档中的代码块并验证
test_metrics_mesh() {
    log_info "=========================================="
    log_info "开始指标与服务网格测试"
    log_info "=========================================="

    # 1. 创建 ServiceMonitor
    log_info "步骤 1: 创建 ServiceMonitor"
    runme print metrics-mesh:servicemonitor-yaml > "/tmp/servicemonitor.yaml" || {
        log_error "获取 ServiceMonitor YAML 失败"
        return 1
    }

    kubectl_apply_runme_block "metrics-mesh:apply-servicemonitor" "/tmp/" || return 1
    log_success "ServiceMonitor 创建成功"

    # 2. 创建 PodMonitor
    log_info "步骤 2: 创建 PodMonitor"
    runme print metrics-mesh:podmonitor-yaml > "/tmp/podmonitor.yaml" || {
        log_error "获取 PodMonitor YAML 失败"
        return 1
    }

    kubectl_apply_runme_block "metrics-mesh:apply-podmonitor" "/tmp/" || return 1
    log_success "PodMonitor 创建成功"

    # 3. 创建 Telemetry
    log_info "步骤 3: 创建 Telemetry"
    runme print metrics-mesh:telemetry-yaml > "/tmp/asm-telemetry.yaml" || {
        log_error "获取 Telemetry YAML 失败"
        return 1
    }

    kubectl_apply_runme_block "metrics-mesh:apply-telemetry" "/tmp/" || return 1
    log_success "Telemetry 创建成功"

    log_success "=========================================="
    log_success "指标与服务网格测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
