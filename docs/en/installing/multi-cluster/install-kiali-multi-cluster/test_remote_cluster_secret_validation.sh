#!/usr/bin/env bash
# Kiali 多集群远端 Secret 验证回归测试

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${FRAMEWORK_ROOT:?请设置 FRAMEWORK_ROOT 后运行该回归测试}"
export FRAMEWORK_ROOT

# 只加载被测脚本的函数；kubectl 用函数替身返回固定的 Secret JSON。
export PLATFORM_ADDRESS=https://platform.example
export CTX_CLUSTER1=business-1
export CTX_CLUSTER2=business-2
source "$SCRIPT_DIR/runme-test_install-kiali-in-multi-cluster-mesh.sh"

MOCK_SECRET_JSON='{"metadata":{"labels":{"kiali.io/multiCluster":"true"}},"data":{"cluster2":"a3Via2Vjb25maWc="}}'

kubectl() {
    if [ "${MOCK_KUBECTL_RC:-0}" -ne 0 ]; then
        return "$MOCK_KUBECTL_RC"
    fi
    printf '%s\n' "$MOCK_SECRET_JSON"
}

assert_pass() {
    local name="$1" output="$2"
    if ! _mc_validate_remote_secret \
        "https://platform.example/kubernetes/business-2" "$output"; then
        printf 'FAIL: %s\n' "$name" >&2
        exit 1
    fi
}

assert_fail() {
    local name="$1" server="$2" output="$3"
    if _mc_validate_remote_secret "$server" "$output"; then
        printf 'FAIL: %s 应该失败\n' "$name" >&2
        exit 1
    fi
}

_MC_REMOTE_SECRET=kiali-remote-cluster-secret-cluster2

assert_pass "created 输出" $'INFO: remote_cluster_server_url=https://platform.example/kubernetes/business-2\nsecret/kiali-remote-cluster-secret-cluster2 created'
assert_pass "configured 输出" $'INFO: remote_cluster_server_url=https://platform.example/kubernetes/business-2\nsecret/kiali-remote-cluster-secret-cluster2 configured'
assert_pass "serverside-applied 输出" $'INFO: remote_cluster_server_url=https://platform.example/kubernetes/business-2\nsecret/kiali-remote-cluster-secret-cluster2 serverside-applied'

assert_fail "平台代理地址错误" \
    "https://platform.example/kubernetes/business-2" \
    $'INFO: remote_cluster_server_url=https://10.0.0.2:6443'

MOCK_KUBECTL_RC=1
assert_fail "Secret 不存在" \
    "https://platform.example/kubernetes/business-2" \
    $'INFO: remote_cluster_server_url=https://platform.example/kubernetes/business-2'
MOCK_KUBECTL_RC=0

MOCK_SECRET_JSON='{"metadata":{"labels":{}},"data":{"cluster2":"a3Via2Vjb25maWc="}}'
assert_fail "缺少 Kiali 自动发现标签" \
    "https://platform.example/kubernetes/business-2" \
    $'INFO: remote_cluster_server_url=https://platform.example/kubernetes/business-2'

MOCK_SECRET_JSON='{"metadata":{"labels":{"kiali.io/multiCluster":"true"}},"data":{}}'
assert_fail "缺少 cluster2 kubeconfig" \
    "https://platform.example/kubernetes/business-2" \
    $'INFO: remote_cluster_server_url=https://platform.example/kubernetes/business-2'

printf '远端 Secret 验证回归测试通过\n'
