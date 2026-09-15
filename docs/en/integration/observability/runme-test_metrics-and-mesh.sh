#!/usr/bin/env bash
# 指标与服务网格文档测试脚本

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# runme 命令可以在项目的任意目录中执行

# 当前集群是否跑着 Istio 控制面
# 说明: 主-远拓扑的远端集群没有本地控制面，其 istiod Service 无 endpoints，
#       apply Telemetry 会被 istiod-default-validator webhook 拒绝
#       （failed calling webhook "validation.istio.io" ... certificate signed by unknown authority）。
#       文档也写明 Telemetry 只需建在跑控制面的集群上（sidecar 的指标配置由配置它的
#       控制面下发），因此远端集群跳过该步骤而不是判失败。
_metrics_mesh_has_control_plane() {
    kubectl -n istio-system get pods -l app=istiod -o name 2>/dev/null | grep -q .
}

# 按 CRD 存在性保护的删除（--ignore-not-found 不覆盖「资源类型不存在」）
# 用法: _metrics_mesh_delete <crd> <kind> <name>
_metrics_mesh_delete() {
    local crd="$1" kind="$2" name="$3"
    if ! kubectl get crd "$crd" > /dev/null 2>&1; then
        log_info "CRD ${crd} 不存在，跳过删除 ${kind}/${name}"
        return 0
    fi
    kubectl -n istio-system delete "$kind" "$name" --ignore-not-found=true || return 1
    return 0
}

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

    # 3. 创建 Telemetry（仅跑控制面的集群）
    if ! _metrics_mesh_has_control_plane; then
        log_warn "当前集群没有 istiod（主-远拓扑的远端集群），按文档跳过 Telemetry 创建"
        log_success "=========================================="
        log_success "指标与服务网格测试完成（远端集群仅创建监控对象）"
        log_success "=========================================="
        return 0
    fi

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

# 清理：文档没有卸载章节，这里按文档创建的三个对象逆序删除（名称取自文档的 YAML 块）。
# 多集群编排要在两个集群上分别 --no-cleanup 建、--cleanup-only 收，故需要本函数。
cleanup_metrics_mesh() {
    log_info "=========================================="
    log_info "清理指标与服务网格集成对象"
    log_info "=========================================="

    local rc=0
    _metrics_mesh_delete telemetries.telemetry.istio.io telemetry asm-default || rc=1
    _metrics_mesh_delete podmonitors.monitoring.coreos.com podmonitor istio-proxies-monitor || rc=1
    _metrics_mesh_delete servicemonitors.monitoring.coreos.com servicemonitor istiod-monitor || rc=1

    if [ "$rc" -eq 0 ]; then
        log_success "指标与服务网格集成对象清理完成"
    else
        log_warn "部分对象清理失败 (上方已记录)"
    fi
    return 0
}
