#!/usr/bin/env bash
# 主-远多网络 (Primary-Remote Multi-Network) 拓扑测试脚本
# 合并 configuration-overview 与 install-primary-remote-multi-network 的全流程

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# 跨函数共享的工作目录,在 test_*() 与 cleanup_*() 间复用
WORK_DIR=""

_setup_env() {
    if [ -z "${EAST_CLUSTER_NAME:-}" ] || [ -z "${WEST_CLUSTER_NAME:-}" ]; then
        log_error "EAST_CLUSTER_NAME 与 WEST_CLUSTER_NAME 必须设置 (来自 multi-cluster 双集群环境)"
        return 1
    fi

    export CTX_CLUSTER1="$EAST_CLUSTER_NAME"
    export CTX_CLUSTER2="$WEST_CLUSTER_NAME"

    eval "$(runme print primary-remote-multi-network:set-istio-version)"

    log_info "环境: CTX_CLUSTER1=$CTX_CLUSTER1  CTX_CLUSTER2=$CTX_CLUSTER2  ISTIO_VERSION=$ISTIO_VERSION"
    return 0
}

_run_block_in_workdir() {
    local block_name="$1"
    local cmd_content
    cmd_content=$(runme print "$block_name" 2>/dev/null)
    if [ -z "$cmd_content" ]; then
        log_error "无法获取代码块内容: $block_name"
        return 1
    fi
    pushd "$WORK_DIR" > /dev/null || return 1
    eval "$cmd_content"
    local rc=$?
    popd > /dev/null
    return $rc
}

_wait_for_lb_ip() {
    local context="$1"
    local namespace="$2"
    local service="$3"
    local max_retries=60
    local count=0
    local ip=""
    log_info "等待 LoadBalancer Service $service 拿到外部 IP (context=$context)"
    while [ $count -lt $max_retries ]; do
        ip=$(kubectl --context "$context" -n "$namespace" get svc "$service" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$ip" ]; then
            log_success "LoadBalancer IP 就绪: $ip ($service)"
            return 0
        fi
        count=$((count + 1))
        sleep 5
    done
    log_error "等待 LoadBalancer IP 超时 (5 min): context=$context svc=$service"
    return 1
}

_create_namespace_safe() {
    local block_name="$1"
    local context="$2"
    local namespace="$3"

    runme run "$block_name" 2>&1 || true
    if ! kubectl --context "$context" get namespace "$namespace" >/dev/null 2>&1; then
        log_error "$context 上的 $namespace 命名空间创建失败"
        return 1
    fi
    return 0
}

test_install_primary_remote_multi_network() {
    log_info "=========================================="
    log_info "开始主-远多网络网格测试"
    log_info "=========================================="

    _setup_env || return 1

    if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
        WORK_DIR=$(mktemp -d -t pr-mn-certs-XXXXXX)
        log_info "工作目录: $WORK_DIR"
    fi

    # ============================================================
    # Phase 1: 生成跨集群通用 CA 证书 (来自 configuration-overview)
    # ============================================================
    log_info "=== Phase 1: 生成跨集群通用 CA 证书 ==="

    log_info "步骤 1.1: 生成 root key"
    _run_block_in_workdir multi-cluster-config:create-root-key || return 1

    log_info "步骤 1.2: 写入 root-ca.conf"
    runme print multi-cluster-config:root-ca-conf > "$WORK_DIR/root-ca.conf" || return 1

    log_info "步骤 1.3: 生成 root CSR"
    _run_block_in_workdir multi-cluster-config:create-root-csr || return 1

    log_info "步骤 1.4: 签发 root 证书"
    _run_block_in_workdir multi-cluster-config:create-root-cert || return 1

    log_info "步骤 1.5: 创建 east 目录"
    _run_block_in_workdir multi-cluster-config:mkdir-east || return 1

    log_info "步骤 1.6: 生成 east ca-key"
    _run_block_in_workdir multi-cluster-config:create-east-ca-key || return 1

    log_info "步骤 1.7: 写入 east/intermediate.conf"
    runme print multi-cluster-config:east-intermediate-conf > "$WORK_DIR/east/intermediate.conf" || return 1

    log_info "步骤 1.8: 生成 east CSR"
    _run_block_in_workdir multi-cluster-config:create-east-csr || return 1

    log_info "步骤 1.9: 签发 east 中间 CA 证书"
    _run_block_in_workdir multi-cluster-config:create-east-cert || return 1

    log_info "步骤 1.10: 拼接 east cert chain"
    _run_block_in_workdir multi-cluster-config:create-east-chain || return 1

    log_info "步骤 1.11: 创建 west 目录"
    _run_block_in_workdir multi-cluster-config:mkdir-west || return 1

    log_info "步骤 1.12: 生成 west ca-key"
    _run_block_in_workdir multi-cluster-config:create-west-ca-key || return 1

    log_info "步骤 1.13: 写入 west/intermediate.conf"
    runme print multi-cluster-config:west-intermediate-conf > "$WORK_DIR/west/intermediate.conf" || return 1

    log_info "步骤 1.14: 生成 west CSR"
    _run_block_in_workdir multi-cluster-config:create-west-csr || return 1

    log_info "步骤 1.15: 签发 west 中间 CA 证书"
    _run_block_in_workdir multi-cluster-config:create-west-cert || return 1

    log_info "步骤 1.16: 拼接 west cert chain"
    _run_block_in_workdir multi-cluster-config:create-west-chain || return 1

    log_success "Phase 1 完成: CA 证书已生成"

    # ============================================================
    # Phase 2: 在两个集群上下发 cacerts (来自 configuration-overview)
    # ============================================================
    log_info "=== Phase 2: 在两个集群上下发 cacerts ==="

    log_info "步骤 2.1: 在 East 创建 istio-system 命名空间"
    _create_namespace_safe multi-cluster-config:create-east-ns "$CTX_CLUSTER1" istio-system || return 1

    log_info "步骤 2.2: 在 East 下发 cacerts"
    _run_block_in_workdir multi-cluster-config:create-east-cacerts || return 1

    log_info "步骤 2.3: 在 West 创建 istio-system 命名空间"
    _create_namespace_safe multi-cluster-config:create-west-ns "$CTX_CLUSTER2" istio-system || return 1

    log_info "步骤 2.4: 在 West 下发 cacerts"
    _run_block_in_workdir multi-cluster-config:create-west-cacerts || return 1

    log_info "步骤 2.5: 验证两个集群的 cacerts secret"
    kubectl --context "$CTX_CLUSTER1" -n istio-system get secret cacerts >/dev/null 2>&1 || {
        log_error "East cacerts secret 未找到"; return 1
    }
    kubectl --context "$CTX_CLUSTER2" -n istio-system get secret cacerts >/dev/null 2>&1 || {
        log_error "West cacerts secret 未找到"; return 1
    }
    log_success "Phase 2 完成: cacerts 已下发到两个集群"

    # ============================================================
    # Phase 3: 安装 Istio 主-远拓扑 (来自 install-pr-mn 文档)
    # ============================================================
    log_info "=== Phase 3: 安装 Istio 主-远多网络拓扑 ==="

    # ---- East (Primary) ----
    log_info "步骤 3.1: East 安装 IstioCNI"
    runme run primary-remote-multi-network:install-istio-cni-east || {
        log_error "East IstioCNI 安装失败"; return 1
    }

    log_info "步骤 3.2: 写入 istio-external.yaml 到工作目录"
    runme print primary-remote-multi-network:istio-external-yaml > "$WORK_DIR/istio-external.yaml" || {
        log_error "写入 istio-external.yaml 失败"; return 1
    }

    log_info "步骤 3.3: East 通过 envsubst 应用 Istio CR"
    _run_block_in_workdir primary-remote-multi-network:apply-istio-east || {
        log_error "East Istio CR 应用失败"; return 1
    }

    log_info "步骤 3.4: East 等待 Istio Ready"
    runme run primary-remote-multi-network:wait-istio-east || {
        log_error "East Istio 等待 Ready 失败"; return 1
    }

    log_info "步骤 3.5: East 部署东西向网关"
    runme run primary-remote-multi-network:create-eastwest-gw-east || {
        log_error "East 东西向网关部署失败"; return 1
    }

    _wait_for_lb_ip "$CTX_CLUSTER1" istio-system istio-eastwestgateway || return 1

    log_info "步骤 3.6: East 暴露 istiod 控制面"
    runme run primary-remote-multi-network:expose-istiod-east || {
        log_error "East 暴露 istiod 失败"; return 1
    }

    log_info "步骤 3.7: East 暴露应用服务"
    runme run primary-remote-multi-network:expose-services-east || {
        log_error "East 暴露应用服务失败"; return 1
    }

    # ---- West (Remote) ----
    log_info "步骤 3.8: West 安装 IstioCNI"
    runme run primary-remote-multi-network:install-istio-cni-west || {
        log_error "West IstioCNI 安装失败"; return 1
    }

    log_info "步骤 3.9: 获取 East 东西向网关 IP 并 export DISCOVERY_ADDRESS"
    # 文档中此 block 用 export DISCOVERY_ADDRESS=...,但 runme 子 shell 的 export 不会传到调用 shell;
    # 通过 eval print 让变量在测试 shell 中持续生效,后续 install-istio-west 才能引用 ${DISCOVERY_ADDRESS}
    eval "$(runme print primary-remote-multi-network:get-discovery-address)"
    if [ -z "${DISCOVERY_ADDRESS:-}" ]; then
        log_error "DISCOVERY_ADDRESS 未获取到"; return 1
    fi
    log_success "DISCOVERY_ADDRESS=$DISCOVERY_ADDRESS"

    log_info "步骤 3.10: West 安装 Istio CR (profile=remote)"
    runme run primary-remote-multi-network:install-istio-west || {
        log_error "West Istio CR 创建失败"; return 1
    }

    log_info "步骤 3.11: West 给 istio-system 命名空间打 controlPlaneClusters 注解"
    runme run primary-remote-multi-network:annotate-istio-system-west || {
        log_error "annotate istio-system 失败"; return 1
    }

    log_info "步骤 3.12: 在 East 上安装 cluster2 remote secret"
    runme run primary-remote-multi-network:install-remote-secret-cluster2-on-east || {
        log_error "cluster2 remote secret 安装失败"; return 1
    }

    log_info "步骤 3.13: West 等待 Istio Ready"
    runme run primary-remote-multi-network:wait-istio-west || {
        log_error "West Istio 等待 Ready 失败"; return 1
    }

    log_info "步骤 3.14: West 部署东西向网关"
    runme run primary-remote-multi-network:create-eastwest-gw-west || {
        log_error "West 东西向网关部署失败"; return 1
    }

    _wait_for_lb_ip "$CTX_CLUSTER2" istio-system istio-eastwestgateway || return 1

    log_success "Phase 3 完成: 主-远多网络网格已安装"

    # ============================================================
    # Phase 4: 部署示例应用
    # ============================================================
    log_info "=== Phase 4: 部署示例应用 ==="

    log_info "步骤 4.1: East 创建 sample 命名空间"
    runme run primary-remote-multi-network:create-sample-ns-east || return 1

    log_info "步骤 4.2: East 启用 sidecar 注入"
    runme run primary-remote-multi-network:label-sample-ns-east || return 1

    log_info "步骤 4.3: East 部署 helloworld service"
    runme run primary-remote-multi-network:deploy-helloworld-svc-east || return 1

    log_info "步骤 4.4: East 部署 helloworld v1"
    runme run primary-remote-multi-network:deploy-helloworld-v1-east || return 1

    log_info "步骤 4.5: East 部署 sleep"
    runme run primary-remote-multi-network:deploy-sleep-east || return 1

    log_info "步骤 4.6: East 等待 helloworld-v1 就绪"
    runme run primary-remote-multi-network:wait-helloworld-v1-east || return 1

    log_info "步骤 4.7: East 等待 sleep 就绪"
    runme run primary-remote-multi-network:wait-sleep-east || return 1

    log_info "步骤 4.8: West 创建 sample 命名空间"
    runme run primary-remote-multi-network:create-sample-ns-west || return 1

    log_info "步骤 4.9: West 启用 sidecar 注入"
    runme run primary-remote-multi-network:label-sample-ns-west || return 1

    log_info "步骤 4.10: West 部署 helloworld service"
    runme run primary-remote-multi-network:deploy-helloworld-svc-west || return 1

    log_info "步骤 4.11: West 部署 helloworld v2"
    runme run primary-remote-multi-network:deploy-helloworld-v2-west || return 1

    log_info "步骤 4.12: West 部署 sleep"
    runme run primary-remote-multi-network:deploy-sleep-west || return 1

    log_info "步骤 4.13: West 等待 helloworld-v2 就绪"
    runme run primary-remote-multi-network:wait-helloworld-v2-west || return 1

    log_info "步骤 4.14: West 等待 sleep 就绪"
    runme run primary-remote-multi-network:wait-sleep-west || return 1

    # ============================================================
    # Phase 5: 验证跨集群流量
    # ============================================================
    log_info "=== Phase 5: 验证跨集群流量 ==="

    log_info "步骤 5.1: 从 East 验证流量负载均衡 (期望同时观察到 v1 与 v2)"
    local output_east
    output_east=$(runme run primary-remote-multi-network:test-traffic-east 2>&1) || {
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

    log_info "步骤 5.2: 从 West 验证流量负载均衡"
    local output_west
    output_west=$(runme run primary-remote-multi-network:test-traffic-west 2>&1) || {
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

    runme print primary-remote-multi-network:test-traffic-east-output >/dev/null 2>&1 || true

    log_success "=========================================="
    log_success "主-远多网络网格测试完成,所有验证通过！"
    log_success "=========================================="
    return 0
}

cleanup_install_primary_remote_multi_network() {
    log_info "=========================================="
    log_info "清理主-远多网络测试资源"
    log_info "=========================================="

    if [ -n "${EAST_CLUSTER_NAME:-}" ]; then
        export CTX_CLUSTER1="$EAST_CLUSTER_NAME"
    fi
    if [ -n "${WEST_CLUSTER_NAME:-}" ]; then
        export CTX_CLUSTER2="$WEST_CLUSTER_NAME"
    fi

    local rc=0

    log_info "卸载 East 集群资源"
    runme run primary-remote-multi-network:cleanup-east || {
        log_warn "East 卸载命令返回非零 (可能资源已不存在)"
        rc=1
    }

    log_info "卸载 West 集群资源"
    runme run primary-remote-multi-network:cleanup-west || {
        log_warn "West 卸载命令返回非零 (可能资源已不存在)"
        rc=1
    }

    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        log_info "删除工作目录 $WORK_DIR"
        rm -rf "$WORK_DIR"
        WORK_DIR=""
    fi

    if [ "$rc" -eq 0 ]; then
        log_success "测试资源清理完成"
    else
        log_warn "部分资源清理失败 (上方已记录)"
    fi
    return 0
}
