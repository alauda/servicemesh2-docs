#!/usr/bin/env bash
# 多主多网络 (Multi-Primary Multi-Network) 拓扑测试脚本
# 前提: 先执行 ./run.sh --file configuration-overview 完成 cacerts 下发

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

_setup_env() {
    if [ -z "${EAST_CLUSTER_NAME:-}" ] || [ -z "${WEST_CLUSTER_NAME:-}" ]; then
        log_error "EAST_CLUSTER_NAME 与 WEST_CLUSTER_NAME 必须设置 (来自 multi-cluster 双集群环境)"
        return 1
    fi

    export CTX_CLUSTER1="$EAST_CLUSTER_NAME"
    export CTX_CLUSTER2="$WEST_CLUSTER_NAME"

    # 文档中的 export ISTIO_VERSION=... 块需要 eval 才能让变量在调用 shell 中存活
    eval "$(runme print multi-primary-multi-network:set-istio-version)"

    log_info "环境: CTX_CLUSTER1=$CTX_CLUSTER1  CTX_CLUSTER2=$CTX_CLUSTER2  ISTIO_VERSION=$ISTIO_VERSION"
    return 0
}

# 验证两个集群上的 cacerts secret 已就绪 (configuration-overview 的产物)
_check_cacerts_prerequisite() {
    local rc=0
    if ! kubectl --context "$CTX_CLUSTER1" -n istio-system get secret cacerts >/dev/null 2>&1; then
        log_error "East 集群上 istio-system/cacerts 不存在"
        rc=1
    fi
    if ! kubectl --context "$CTX_CLUSTER2" -n istio-system get secret cacerts >/dev/null 2>&1; then
        log_error "West 集群上 istio-system/cacerts 不存在"
        rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        log_error "请先执行: ./run.sh --file configuration-overview"
        return 1
    fi
    log_success "前置检查通过: 两个集群的 cacerts 已就绪"
    return 0
}

test_install_multi_primary_multi_network() {
    log_info "=========================================="
    log_info "开始多主多网络网格测试"
    log_info "=========================================="

    _setup_env || return 1
    _check_cacerts_prerequisite || return 1

    # ============================================================
    # Phase 1: 安装 Istio 多主多网络拓扑
    # ============================================================
    log_info "=== Phase 1: 安装 Istio 多主多网络拓扑 ==="

    log_info "步骤 1.1: East 安装 IstioCNI"
    runme run multi-primary-multi-network:install-istio-cni-east || {
        log_error "East IstioCNI 安装失败"; return 1
    }

    log_info "步骤 1.2: East 安装 Istio CR"
    runme run multi-primary-multi-network:install-istio-east || {
        log_error "East Istio CR 创建失败"; return 1
    }

    log_info "步骤 1.3: East 等待 Istio Ready"
    runme run multi-primary-multi-network:wait-istio-east || {
        log_error "East Istio 等待 Ready 失败"; return 1
    }

    log_info "步骤 1.4: East 部署东西向网关"
    runme run multi-primary-multi-network:create-eastwest-gw-east || {
        log_error "East 东西向网关部署失败"; return 1
    }

    # 文档未显式等待 LB ingress,由脚本辅助等待
    _wait_for_ingress_lb istio-system istio-eastwestgateway "$CTX_CLUSTER1" || return 1

    log_info "步骤 1.5: East 暴露服务"
    runme run multi-primary-multi-network:expose-services-east || {
        log_error "East 暴露服务失败"; return 1
    }

    log_info "步骤 1.6: West 安装 IstioCNI"
    runme run multi-primary-multi-network:install-istio-cni-west || {
        log_error "West IstioCNI 安装失败"; return 1
    }

    log_info "步骤 1.7: West 安装 Istio CR"
    runme run multi-primary-multi-network:install-istio-west || {
        log_error "West Istio CR 创建失败"; return 1
    }

    log_info "步骤 1.8: West 等待 Istio Ready"
    runme run multi-primary-multi-network:wait-istio-west || {
        log_error "West Istio 等待 Ready 失败"; return 1
    }

    log_info "步骤 1.9: West 部署东西向网关"
    runme run multi-primary-multi-network:create-eastwest-gw-west || {
        log_error "West 东西向网关部署失败"; return 1
    }

    _wait_for_ingress_lb istio-system istio-eastwestgateway "$CTX_CLUSTER2" || return 1

    log_info "步骤 1.10: West 暴露服务"
    runme run multi-primary-multi-network:expose-services-west || {
        log_error "West 暴露服务失败"; return 1
    }

    log_info "步骤 1.11: 在 East 上安装 cluster2 remote secret"
    runme run multi-primary-multi-network:install-remote-secret-cluster2-on-east || {
        log_error "cluster2 remote secret 安装失败"; return 1
    }

    log_info "步骤 1.12: 在 West 上安装 cluster1 remote secret"
    runme run multi-primary-multi-network:install-remote-secret-cluster1-on-west || {
        log_error "cluster1 remote secret 安装失败"; return 1
    }

    log_success "Phase 1 完成: 多主多网络网格已安装"

    # ============================================================
    # Phase 2: 部署示例应用
    # ============================================================
    log_info "=== Phase 2: 部署示例应用 ==="

    log_info "步骤 2.1: East 创建 sample 命名空间"
    runme run multi-primary-multi-network:create-sample-ns-east || return 1

    log_info "步骤 2.2: East 启用 sidecar 注入"
    runme run multi-primary-multi-network:label-sample-ns-east || return 1

    log_info "步骤 2.3: East 部署 helloworld service"
    runme run multi-primary-multi-network:deploy-helloworld-svc-east || return 1

    log_info "步骤 2.4: East 部署 helloworld v1"
    runme run multi-primary-multi-network:deploy-helloworld-v1-east || return 1

    log_info "步骤 2.5: East 部署 sleep"
    runme run multi-primary-multi-network:deploy-sleep-east || return 1

    log_info "步骤 2.6: East 等待 helloworld-v1 就绪"
    runme run multi-primary-multi-network:wait-helloworld-v1-east || return 1

    log_info "步骤 2.7: East 等待 sleep 就绪"
    runme run multi-primary-multi-network:wait-sleep-east || return 1

    log_info "步骤 2.8: West 创建 sample 命名空间"
    runme run multi-primary-multi-network:create-sample-ns-west || return 1

    log_info "步骤 2.9: West 启用 sidecar 注入"
    runme run multi-primary-multi-network:label-sample-ns-west || return 1

    log_info "步骤 2.10: West 部署 helloworld service"
    runme run multi-primary-multi-network:deploy-helloworld-svc-west || return 1

    log_info "步骤 2.11: West 部署 helloworld v2"
    runme run multi-primary-multi-network:deploy-helloworld-v2-west || return 1

    log_info "步骤 2.12: West 部署 sleep"
    runme run multi-primary-multi-network:deploy-sleep-west || return 1

    log_info "步骤 2.13: West 等待 helloworld-v2 就绪"
    runme run multi-primary-multi-network:wait-helloworld-v2-west || return 1

    log_info "步骤 2.14: West 等待 sleep 就绪"
    runme run multi-primary-multi-network:wait-sleep-west || return 1

    # ============================================================
    # Phase 3: 验证跨集群流量
    # ============================================================
    log_info "=== Phase 3: 验证跨集群流量 ==="

    log_info "步骤 3.1: 从 East 验证流量负载均衡 (期望同时观察到 v1 与 v2)"
    local output_east
    output_east=$(runme run multi-primary-multi-network:test-traffic-east 2>&1) || {
        log_error "East 端 curl 调用失败"
        log_error "实际输出: $output_east"
        return 1
    }
    if ! __cmp_lines "$output_east" "$(cat <<'EOF'
+ Hello version: v1
+ Hello version: v2
EOF
)"; then
        log_error "East 端流量验证失败,缺少 v1 或 v2 响应"
        log_error "实际输出: $output_east"
        return 1
    fi
    log_success "East 端流量验证通过 (v1+v2 均出现)"

    log_info "步骤 3.2: 从 West 验证流量负载均衡"
    local output_west
    output_west=$(runme run multi-primary-multi-network:test-traffic-west 2>&1) || {
        log_error "West 端 curl 调用失败"
        log_error "实际输出: $output_west"
        return 1
    }
    if ! __cmp_lines "$output_west" "$(cat <<'EOF'
+ Hello version: v1
+ Hello version: v2
EOF
)"; then
        log_error "West 端流量验证失败,缺少 v1 或 v2 响应"
        log_error "实际输出: $output_west"
        return 1
    fi
    log_success "West 端流量验证通过 (v1+v2 均出现)"

    # 文档示例输出 (-output 块) 仅用于覆盖率,通过 print 触发,不做精确比对
    runme print multi-primary-multi-network:test-traffic-east-output >/dev/null 2>&1 || true

    log_success "=========================================="
    log_success "多主多网络网格测试完成,所有验证通过！"
    log_success "=========================================="
    return 0
}

cleanup_install_multi_primary_multi_network() {
    log_info "=========================================="
    log_info "清理多主多网络测试资源"
    log_info "=========================================="

    # cleanup 可能在独立调用时执行,确保 context 变量已设置
    if [ -n "${EAST_CLUSTER_NAME:-}" ]; then
        export CTX_CLUSTER1="$EAST_CLUSTER_NAME"
    fi
    if [ -n "${WEST_CLUSTER_NAME:-}" ]; then
        export CTX_CLUSTER2="$WEST_CLUSTER_NAME"
    fi

    local rc=0

    log_info "卸载 East 集群资源"
    runme run multi-primary-multi-network:cleanup-east || {
        log_warn "East 卸载命令返回非零 (可能资源已不存在)"
        rc=1
    }

    log_info "卸载 West 集群资源"
    runme run multi-primary-multi-network:cleanup-west || {
        log_warn "West 卸载命令返回非零 (可能资源已不存在)"
        rc=1
    }

    if [ "$rc" -eq 0 ]; then
        log_success "测试资源清理完成"
    else
        log_warn "部分资源清理失败 (上方已记录)"
    fi
    return 0
}
