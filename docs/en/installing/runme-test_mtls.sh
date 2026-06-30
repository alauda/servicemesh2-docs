#!/usr/bin/env bash
# mTLS 严格模式测试脚本
# 测试范围：docs/en/installing/mtls.mdx「Enabling strict mTLS mode by using the namespace」
#           小节（第 39-48 行），为 bookinfo 命名空间下发 PeerAuthentication(STRICT)。
#
# 说明：取文档中 {name=mtls:peerauthentication-strict} 代码块（runme print），
#       将占位符 <namespace> 替换为 bookinfo、去除 # [!code callout] 渲染标记后下发。
#       本脚本作为编排中 bookinfo 生命周期的「启用严格 mTLS / 清理」配套步骤，
#       由 run-mesh-all.sh 的 Case 3（sidecar）与 Case 5（ambient）以
#       --no-cleanup / --cleanup-only 方式调用。

set -e

# FRAMEWORK_ROOT 由 docs-runme-tests/run.sh 引擎注入
: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

test_mtls() {
    # 目标命名空间默认 bookinfo，允许通过环境变量覆盖
    local ns="${MTLS_TEST_NAMESPACE:-bookinfo}"

    log_info "=========================================="
    log_info "开始 mTLS 严格模式测试（命名空间: $ns）"
    log_info "=========================================="

    # 前置检查：目标命名空间必须存在（由编排中的 bookinfo 部署步骤保证）
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        log_error "命名空间 $ns 不存在，请先部署 bookinfo 应用再启用严格 mTLS"
        return 1
    fi

    # 步骤 1：渲染文档代码块并下发 PeerAuthentication(STRICT)
    # 取 mtls.mdx 的 {name=mtls:peerauthentication-strict} 块（第 39-48 行），
    # 将占位符 <namespace> 替换为 $ns，并去除行尾 # [!code callout] 文档渲染标记。
    log_info "步骤 1: 渲染并下发 PeerAuthentication(STRICT) 到命名空间 $ns"
    local manifest
    manifest=$(runme print mtls:peerauthentication-strict \
        | sed -e "s|<namespace>|${ns}|g" -e 's/[[:space:]]*# \[!code callout\]//')
    if [ -z "$manifest" ]; then
        log_error "获取 PeerAuthentication 模板失败（runme print mtls:peerauthentication-strict 为空）"
        return 1
    fi
    if ! printf '%s\n' "$manifest" | kubectl apply -f -; then
        log_error "下发 PeerAuthentication(STRICT) 失败"
        return 1
    fi

    # 步骤 2：校验 PeerAuthentication 已生效且模式为 STRICT
    log_info "步骤 2: 校验 PeerAuthentication 模式为 STRICT"
    local mode
    mode=$(kubectl -n "$ns" get peerauthentication default -o jsonpath='{.spec.mtls.mode}' 2>&1)
    if ! __cmp_same "$mode" "STRICT"; then
        log_error "PeerAuthentication 模式校验失败，期望 STRICT，实际: $mode"
        return 1
    fi
    log_success "PeerAuthentication(STRICT) 已在命名空间 $ns 生效"

    log_success "=========================================="
    log_success "mTLS 严格模式测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

cleanup_mtls() {
    local ns="${MTLS_TEST_NAMESPACE:-bookinfo}"

    log_info "=========================================="
    log_info "清理 mTLS 严格模式测试资源（命名空间: $ns）"
    log_info "=========================================="

    # 网格卸载后 PeerAuthentication CRD 可能已不存在（如 ambient 编排中先卸网格再清 bookinfo），
    # 此时直接 delete 会因资源类型缺失而报错，故先探测 CRD 是否存在再删除。
    if ! kubectl get crd peerauthentications.security.istio.io >/dev/null 2>&1; then
        log_warn "PeerAuthentication CRD 不存在（网格可能已卸载），跳过清理"
        return 0
    fi

    kubectl -n "$ns" delete peerauthentication default --ignore-not-found=true || {
        log_error "删除 PeerAuthentication 失败"
        return 1
    }

    log_success "mTLS 严格模式测试资源清理完成"
    return 0
}
