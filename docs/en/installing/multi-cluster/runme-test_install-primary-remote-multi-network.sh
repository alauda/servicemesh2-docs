#!/usr/bin/env bash
# 主-远多网络 (Primary-Remote Multi-Network) 拓扑测试脚本
# 前提: 先执行 ./run.sh --file configuration-overview 完成 cacerts 下发

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# 用于存放 istio-external.yaml 的工作目录 (envsubst apply 依赖文件)
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

# 在 WORK_DIR 中执行 runme 代码块 (用于 envsubst < istio-external.yaml 等依赖 cwd 的命令)
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

# 跨集群流量验证：要求 10 次调用里同时出现 v1（East）与 v2（West），带重试
# 用法: _verify_cross_cluster_traffic <runme 块名> <发起端名称>
# 重试原因：helloworld 就绪、istiod 推下对端端点后，跨网络数据面（本集群 → 对端东西向网关
# LoadBalancer）未必已通，一次性采样会踩中这个窗口。RET-1036（2026-09-29 dailybuild，
# ctyun MicroOS）多主多网络用例：East istiod 23:04:45.6 推下 v2 端点，随即采样失败；那是 West
# 东西向网关 VIP 的首次宣告，两分钟后主-远用例同样的验证即通过。始终不通时重试耗尽仍如实失败。
# 窗口 24 次 × 5 秒（每次另含 10 次 exec，合计约 3.5 分钟）：那次从首次采样到主-远用例验证
# 通过约 3 分钟，这是已知的收敛上界；默认 12 次只覆盖不到 2 分钟。
_verify_cross_cluster_traffic() {
    local block="$1" side="$2"
    if ! retry_runme_verify "$block" __cmp_lines "$(cat <<'EOF'
+ Hello version: v1
+ Hello version: v2
EOF
)" 24 5; then
        log_error "${side} 端流量验证失败：重试耗尽仍未同时观察到 v1 与 v2"
        log_error "最后一次输出: ${RETRY_RUNME_OUTPUT:-}"
        return 1
    fi
    log_success "${side} 端流量验证通过 (v1+v2 均出现)"
    return 0
}

test_install_primary_remote_multi_network() {
    log_info "=========================================="
    log_info "开始主-远多网络网格测试"
    log_info "=========================================="

    _setup_env || return 1
    _check_cacerts_prerequisite || return 1

    # 创建外部 IP 地址池 (仅 ENABLE_METALLB=true 时生效): 东西向网关 LoadBalancer 依赖其可用地址
    setup_external_ip_pools "$EAST_CLUSTER_NAME" "$WEST_CLUSTER_NAME" || return 1

    if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
        WORK_DIR=$(mktemp -d -t pr-mn-XXXXXX)
        log_info "工作目录: $WORK_DIR (用于 istio-external.yaml)"
    fi

    # ============================================================
    # Phase 1: 安装 Istio 主-远多网络拓扑
    # ============================================================
    log_info "=== Phase 1: 安装 Istio 主-远多网络拓扑 ==="

    log_info "步骤 1.1: East 安装 IstioCNI"
    runme run primary-remote-multi-network:install-istio-cni-east || {
        log_error "East IstioCNI 安装失败"; return 1
    }

    log_info "步骤 1.2: 写入 istio-external.yaml 到工作目录"
    runme print primary-remote-multi-network:istio-external-yaml > "$WORK_DIR/istio-external.yaml" || {
        log_error "写入 istio-external.yaml 失败"; return 1
    }

    log_info "步骤 1.3: East 通过 envsubst 应用 Istio CR"
    _run_block_in_workdir primary-remote-multi-network:apply-istio-east || {
        log_error "East Istio CR 应用失败"; return 1
    }

    log_info "步骤 1.4: East 等待 Istio Ready"
    runme run primary-remote-multi-network:wait-istio-east || {
        log_error "East Istio 等待 Ready 失败"; return 1
    }

    log_info "步骤 1.4a: East 应用 Linux 内核兼容处理 (仅 ENABLE_GW_LINUX_KERNEL_COMPAT=true 生效；东西向网关高端口，非 root)"
    apply_kernel_compat_istio_gateway false "$CTX_CLUSTER1" || return 1
    sleep 3

    log_info "步骤 1.5: East 部署东西向网关"
    runme_run_with_assets primary-remote-multi-network:create-eastwest-gw-east || {
        log_error "East 东西向网关部署失败"; return 1
    }

    _wait_for_ingress_lb istio-system istio-eastwestgateway "$CTX_CLUSTER1" || return 1

    log_info "步骤 1.6: East 暴露 istiod 控制面"
    runme_run_with_assets primary-remote-multi-network:expose-istiod-east || {
        log_error "East 暴露 istiod 失败"; return 1
    }

    log_info "步骤 1.7: East 暴露应用服务"
    runme_run_with_assets primary-remote-multi-network:expose-services-east || {
        log_error "East 暴露应用服务失败"; return 1
    }

    log_info "步骤 1.8: West 安装 IstioCNI"
    runme run primary-remote-multi-network:install-istio-cni-west || {
        log_error "West IstioCNI 安装失败"; return 1
    }

    log_info "步骤 1.9: 获取 East 东西向网关 IP 并 export DISCOVERY_ADDRESS"
    # 文档中此 block 用 export DISCOVERY_ADDRESS=...,但 runme 子 shell 的 export 不会传到调用 shell;
    # 通过 eval print 让变量在测试 shell 中持续生效,后续 install-istio-west 才能引用 ${DISCOVERY_ADDRESS}
    eval "$(runme print primary-remote-multi-network:get-discovery-address)"
    if [ -z "${DISCOVERY_ADDRESS:-}" ]; then
        log_error "DISCOVERY_ADDRESS 未获取到"; return 1
    fi
    log_success "DISCOVERY_ADDRESS=$DISCOVERY_ADDRESS"

    log_info "步骤 1.10: West 安装 Istio CR (profile=remote)"
    runme run primary-remote-multi-network:install-istio-west || {
        log_error "West Istio CR 创建失败"; return 1
    }

    log_info "步骤 1.11: West 给 istio-system 命名空间打 controlPlaneClusters 注解"
    runme run primary-remote-multi-network:annotate-istio-system-west || {
        log_error "annotate istio-system 失败"; return 1
    }

    log_info "步骤 1.12: 在 East 上安装 cluster2 remote secret"
    runme run primary-remote-multi-network:install-remote-secret-cluster2-on-east || {
        log_error "cluster2 remote secret 安装失败"; return 1
    }

    log_info "步骤 1.13: West 等待 Istio Ready"
    runme run primary-remote-multi-network:wait-istio-west || {
        log_error "West Istio 等待 Ready 失败"; return 1
    }

    log_info "步骤 1.13a: West 应用 Linux 内核兼容处理 (仅 ENABLE_GW_LINUX_KERNEL_COMPAT=true 生效；东西向网关高端口，非 root)"
    apply_kernel_compat_istio_gateway false "$CTX_CLUSTER2" || return 1
    sleep 3

    log_info "步骤 1.14: West 部署东西向网关"
    runme_run_with_assets primary-remote-multi-network:create-eastwest-gw-west || {
        log_error "West 东西向网关部署失败"; return 1
    }

    _wait_for_ingress_lb istio-system istio-eastwestgateway "$CTX_CLUSTER2" || return 1

    log_success "Phase 1 完成: 主-远多网络网格已安装"

    # ============================================================
    # Phase 2: 部署示例应用
    # ============================================================
    log_info "=== Phase 2: 部署示例应用 ==="

    log_info "步骤 2.1: East 创建 sample 命名空间"
    _create_namespace_safe primary-remote-multi-network:create-sample-ns-east sample "$CTX_CLUSTER1" || return 1

    log_info "步骤 2.2: East 启用 sidecar 注入"
    runme run primary-remote-multi-network:label-sample-ns-east || return 1

    log_info "步骤 2.3: East 部署 helloworld service"
    kubectl_apply_with_mirror primary-remote-multi-network:deploy-helloworld-svc-east || return 1

    log_info "步骤 2.4: East 部署 helloworld v1"
    kubectl_apply_with_mirror primary-remote-multi-network:deploy-helloworld-v1-east || return 1

    log_info "步骤 2.5: East 部署 sleep"
    kubectl_apply_with_mirror primary-remote-multi-network:deploy-sleep-east || return 1

    log_info "步骤 2.6: East 等待 helloworld-v1 就绪"
    runme run primary-remote-multi-network:wait-helloworld-v1-east || return 1

    log_info "步骤 2.7: East 等待 sleep 就绪"
    runme run primary-remote-multi-network:wait-sleep-east || return 1

    log_info "步骤 2.8: West 创建 sample 命名空间"
    _create_namespace_safe primary-remote-multi-network:create-sample-ns-west sample "$CTX_CLUSTER2" || return 1

    log_info "步骤 2.9: West 启用 sidecar 注入"
    runme run primary-remote-multi-network:label-sample-ns-west || return 1

    log_info "步骤 2.10: West 部署 helloworld service"
    kubectl_apply_with_mirror primary-remote-multi-network:deploy-helloworld-svc-west || return 1

    log_info "步骤 2.11: West 部署 helloworld v2"
    kubectl_apply_with_mirror primary-remote-multi-network:deploy-helloworld-v2-west || return 1

    log_info "步骤 2.12: West 部署 sleep"
    kubectl_apply_with_mirror primary-remote-multi-network:deploy-sleep-west || return 1

    log_info "步骤 2.13: West 等待 helloworld-v2 就绪"
    runme run primary-remote-multi-network:wait-helloworld-v2-west || return 1

    log_info "步骤 2.14: West 等待 sleep 就绪"
    runme run primary-remote-multi-network:wait-sleep-west || return 1

    # 启动两个集群的 sleep 后台流量（AUTO_GEN_SAMPLE_TRAFFIC / AUTO_GEN_BOOKINFO_TRAFFIC=true 时生效）
    # 供后续 Kiali 多集群用例验证跨集群流量图，与 bookinfo 场景的自动打流量对应
    maybe_gen_sample_traffic sample "$CTX_CLUSTER1" "$CTX_CLUSTER2"

    # ============================================================
    # Phase 3: 验证跨集群流量
    # ============================================================
    log_info "=== Phase 3: 验证跨集群流量 ==="

    log_info "步骤 3.1: 从 East 验证流量负载均衡 (期望同时观察到 v1 与 v2)"
    _verify_cross_cluster_traffic primary-remote-multi-network:test-traffic-east East || return 1

    log_info "步骤 3.2: 从 West 验证流量负载均衡"
    _verify_cross_cluster_traffic primary-remote-multi-network:test-traffic-west West || return 1

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

    # 删除外部 IP 地址池 (仅 ENABLE_METALLB=true 时生效)
    teardown_external_ip_pools "$EAST_CLUSTER_NAME" "$WEST_CLUSTER_NAME" || rc=1

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
