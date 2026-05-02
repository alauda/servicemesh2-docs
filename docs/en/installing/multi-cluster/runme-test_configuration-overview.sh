#!/usr/bin/env bash
# 多集群通用 CA 证书生成与下发测试脚本
# 对应文档: docs/en/installing/multi-cluster/configuration-overview.mdx
# 作为 install-multi-primary-multi-network / install-primary-remote-multi-network 的共同前置

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# 工作目录,用于存放生成的证书文件
WORK_DIR=""

_setup_env() {
    if [ -z "${EAST_CLUSTER_NAME:-}" ] || [ -z "${WEST_CLUSTER_NAME:-}" ]; then
        log_error "EAST_CLUSTER_NAME 与 WEST_CLUSTER_NAME 必须设置 (来自 multi-cluster 双集群环境)"
        return 1
    fi
    export CTX_CLUSTER1="$EAST_CLUSTER_NAME"
    export CTX_CLUSTER2="$WEST_CLUSTER_NAME"
    log_info "环境: CTX_CLUSTER1=$CTX_CLUSTER1  CTX_CLUSTER2=$CTX_CLUSTER2"
    return 0
}

# 在 WORK_DIR 中执行 runme 代码块 (用于 openssl / cacerts 等依赖 cwd 的操作)
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

test_configuration_overview() {
    log_info "=========================================="
    log_info "开始多集群通用 CA 证书测试"
    log_info "=========================================="

    _setup_env || return 1

    if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
        WORK_DIR=$(mktemp -d -t mc-config-XXXXXX)
        log_info "工作目录: $WORK_DIR"
    fi

    # ============================================================
    # Phase 1: 生成跨集群通用 CA 证书
    # ============================================================
    log_info "=== Phase 1: 生成跨集群通用 CA 证书 ==="

    log_info "步骤 1.1: 生成 root key"
    _run_block_in_workdir multi-cluster-config:create-root-key || {
        log_error "生成 root key 失败"; return 1
    }

    log_info "步骤 1.2: 写入 root-ca.conf"
    runme print multi-cluster-config:root-ca-conf > "$WORK_DIR/root-ca.conf" || {
        log_error "写入 root-ca.conf 失败"; return 1
    }

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
    # Phase 2: 在两个集群上下发 cacerts
    # ============================================================
    log_info "=== Phase 2: 在两个集群上下发 cacerts ==="

    log_info "步骤 2.1: 在 East 创建 istio-system 命名空间"
    _create_namespace_safe multi-cluster-config:create-east-ns istio-system "$CTX_CLUSTER1" || return 1

    log_info "步骤 2.2: 在 East 下发 cacerts"
    _run_block_in_workdir multi-cluster-config:create-east-cacerts || return 1

    log_info "步骤 2.3: 在 West 创建 istio-system 命名空间"
    _create_namespace_safe multi-cluster-config:create-west-ns istio-system "$CTX_CLUSTER2" || return 1

    log_info "步骤 2.4: 在 West 下发 cacerts"
    _run_block_in_workdir multi-cluster-config:create-west-cacerts || return 1

    log_info "步骤 2.5: 验证两个集群的 cacerts secret"
    kubectl --context "$CTX_CLUSTER1" -n istio-system get secret cacerts >/dev/null 2>&1 || {
        log_error "East cacerts secret 未找到"; return 1
    }
    kubectl --context "$CTX_CLUSTER2" -n istio-system get secret cacerts >/dev/null 2>&1 || {
        log_error "West cacerts secret 未找到"; return 1
    }

    log_success "=========================================="
    log_success "多集群通用 CA 证书测试完成,所有验证通过！"
    log_success "WORK_DIR=$WORK_DIR (留作后续 install 测试若需复用)"
    log_success "=========================================="
    return 0
}

# 注: 文档中无清理步骤,且 cacerts 由后续 install 测试的 cleanup 通过删除
# istio-system 命名空间间接清理。本脚本不定义 cleanup_*() 函数。
