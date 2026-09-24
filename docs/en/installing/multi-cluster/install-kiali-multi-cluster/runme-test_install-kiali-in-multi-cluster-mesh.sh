#!/usr/bin/env bash
# Kiali 多集群服务网格文档测试脚本
#
# 前提（由 run-mesh-all.sh Case 6/7 铺垫）:
#   1. 双集群网格已就绪并保留（install-multi-primary-multi-network 或
#      install-primary-remote-multi-network 的 --no-cleanup），含 sample 命名空间
#   2. 两个集群都已执行 metrics-and-mesh（--cluster 分别指定）
#   3. East 集群已装好 Kiali server（--file kiali --cluster "$EAST_CLUSTER_NAME"）
# West 集群的 kiali-operator 由本脚本补齐——文档前提要求「每个集群都装 Operator」，
# 而 --file kiali 只会作用于 East。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/framework/assets.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# 文档固定用 cluster1 / cluster2 作为 Istio 侧集群名（两篇多集群安装文档一致：
# 多主在各自 Istio CR 的 multiCluster.clusterName，主-远在 istiodRemote.injectionPath）
_MC_ISTIO_CLUSTER2="cluster2"
_MC_REMOTE_SECRET="kiali-remote-cluster-secret-${_MC_ISTIO_CLUSTER2}"

# 解析文档的 context 变量块（占位符换成实际集群名）
_mc_setup_env() {
    if [ -z "${EAST_CLUSTER_NAME:-}" ] || [ -z "${WEST_CLUSTER_NAME:-}" ]; then
        log_error "EAST_CLUSTER_NAME 与 WEST_CLUSTER_NAME 必须设置 (来自 multi-cluster 双集群环境)"
        return 1
    fi

    local cmd
    cmd=$(runme print install-kiali-mc:set-contexts) || {
        log_error "获取 install-kiali-mc:set-contexts 失败"
        return 1
    }
    cmd="${cmd//<your cluster1 context>/$EAST_CLUSTER_NAME}"
    cmd="${cmd//<your cluster2 context>/$WEST_CLUSTER_NAME}"
    eval "$cmd" || return 1

    log_info "环境: CTX_CLUSTER1=${CTX_CLUSTER1}  CTX_CLUSTER2=${CTX_CLUSTER2}"
    return 0
}

# East 必须已有 Kiali server（本篇是在它之上做多集群接入，不重复安装流程）
_mc_check_kiali_server() {
    if ! kubectl --context "$CTX_CLUSTER1" -n istio-system get kiali kiali > /dev/null 2>&1; then
        log_error "East 集群 istio-system 下没有 Kiali 资源"
        log_error "请先执行: ./run.sh --project mesh --file kiali --cluster \"\$EAST_CLUSTER_NAME\""
        return 1
    fi
    log_success "前置检查通过: East 集群 Kiali server 已就绪"
    return 0
}

# 文档前提「所有集群上报到同一个 VictoriaMetrics Center」——两边读出的地址必须一致，
# 否则 Kiali 只能看到 East 的指标，本篇的多集群图形没有意义。
# 地址不同属环境不满足前提，记 env 跳过而不是判失败。
_mc_check_shared_monitoring() {
    local kc_east="$KUBECONFIG_DIR/${EAST_CLUSTER_NAME}.yaml"
    local kc_west="$KUBECONFIG_DIR/${WEST_CLUSTER_NAME}.yaml"
    if [ ! -f "$kc_east" ] || [ ! -f "$kc_west" ]; then
        log_error "缺少单集群 kubeconfig (${kc_east} / ${kc_west})"
        log_error "请先执行: ./run.sh --project mesh --init-only --cluster \"\$EAST_CLUSTER_NAME\" --cluster \"\$WEST_CLUSTER_NAME\""
        return 1
    fi

    local addr_east addr_west
    addr_east=$(_run_runme_block_isolated install-kiali-mc:get-monitoring-address "$kc_east")
    addr_west=$(_run_runme_block_isolated install-kiali-mc:get-monitoring-address "$kc_west")
    if [ -z "$addr_east" ] || [ -z "$addr_west" ]; then
        log_error "读取监控存储地址失败 (East=${addr_east:-空}  West=${addr_west:-空})"
        log_error "确认两个集群都已开启 ACP 监控（feature monitoring 的 .spec.accessInfo.database.address）"
        return 1
    fi

    log_info "监控存储地址: East=${addr_east}  West=${addr_west}"
    if [ "$addr_east" != "$addr_west" ]; then
        skip_test_env "两个集群的监控存储地址不同 (${addr_east} != ${addr_west})，不满足单一聚合端点前提"
        return 2
    fi
    log_success "前置检查通过: 两个集群共用同一监控存储端点"
    return 0
}

# West 集群安装 kiali-operator（复用 kiali.mdx 的 install-kiali:* 代码块）
# 用临时覆盖 KUBECONFIG 的方式切集群，不改写 merged.yaml 的 current-context
_mc_install_west_operator() {
    local kc="$KUBECONFIG_DIR/${WEST_CLUSTER_NAME}.yaml"
    log_info "在 West 集群安装 kiali-operator (文档前提: 每个集群都要装 Operator)"
    KUBECONFIG="$kc" install_operator \
        "kiali-operator" \
        "kiali-operator" \
        "$PKG_KIALI_OPERATOR_URL" \
        "install-kiali" || {
        log_error "West 集群 kiali-operator 安装失败"
        return 1
    }
    return 0
}

# 校验 East 上的远端集群 Secret。
# kiali-prepare-remote-cluster.sh 使用 kubectl apply --server-side，kubectl 的
# 状态词会随 kubectl / apply 模式变化（created、configured、serverside-applied），
# 因此只校验稳定的业务结果：平台代理地址、Kiali 自动发现标签和 cluster2 kubeconfig。
_mc_validate_remote_secret() {
    local proxy_server="$1"
    local output="$2"
    local expected_server="INFO: remote_cluster_server_url=${proxy_server}"
    local secret_json

    if ! __cmp_contains "$output" "$expected_server"; then
        log_error "remote cluster server 地址验证失败"
        log_error "期待包含: $expected_server"
        log_error "实际输出: $output"
        return 1
    fi

    secret_json=$(kubectl --context "$CTX_CLUSTER1" -n istio-system \
        get secret "$_MC_REMOTE_SECRET" -o json 2>/dev/null) || {
        log_error "远端集群 Secret 不存在: istio-system/$_MC_REMOTE_SECRET"
        return 1
    }

    if ! jq -e --arg cluster "$_MC_ISTIO_CLUSTER2" '
        (.metadata.labels["kiali.io/multiCluster"] == "true")
        and ((.data[$cluster] // "") | length > 0)
    ' <<<"$secret_json" >/dev/null; then
        log_error "远端集群 Secret 缺少 Kiali 自动发现标签或 cluster2 kubeconfig"
        return 1
    fi

    return 0
}

# 把 West 的 proxy-connect kubeconfig 并入框架的 merged.yaml，供
# kiali-prepare-remote-cluster.sh 同时读两个 context
# 用法: _mc_merge_proxy_kubeconfig <work_dir>
# 说明: 文档 note 要求合并前先重命名 context 以免冲突；这里连 cluster / user 一起
#       加集群名前缀，避免与 merged.yaml 里的同名条目互相覆盖（覆盖后 server 地址
#       会悄悄变成另一个集群的，属于最难查的一类错）
_mc_merge_proxy_kubeconfig() {
    local work="$1"
    local prefix="${WEST_CLUSTER_NAME}-"

    jq --arg p "$prefix" '
        (.clusters  |= map(.name = $p + .name))
        | (.users   |= map(.name = $p + .name))
        | (.contexts |= map(.name = $p + .name
                            | .context.cluster = $p + .context.cluster
                            | .context.user    = $p + .context.user))
        | ."current-context" = $p + ."current-context"
    ' "$work/west-kubeconfig.yaml.json" > "$work/west-renamed.json" 2>/dev/null || {
        log_error "重命名 West kubeconfig 的 context 失败"
        return 1
    }

    KUBECONFIG="$work/west-renamed.json" kubectl config view --raw --flatten \
        > "$work/west-renamed.yaml" 2>/dev/null || {
        log_error "转换重命名后的 West kubeconfig 失败"
        return 1
    }

    KUBECONFIG="${KUBECONFIG_MERGED_FILE}:$work/west-renamed.yaml" \
        kubectl config view --raw --flatten > "$work/kubeconfig-mc.yaml" 2>/dev/null || {
        log_error "合并双集群 kubeconfig 失败"
        return 1
    }
    chmod 600 "$work/kubeconfig-mc.yaml"
    export KUBECONFIG="$work/kubeconfig-mc.yaml"
    return 0
}

# 测试主体（工作目录由 test_ 函数准备与清理）
# 用法: _mc_test_impl <work_dir>
_mc_test_impl() {
    local work="$1"
    local cmd output expected

    # ============================================================
    # 前置
    # ============================================================
    _mc_check_kiali_server || return 1
    local rc=0
    _mc_check_shared_monitoring || rc=$?
    if [ "$rc" -eq 2 ]; then
        return 0   # 环境不满足前提，已记 env 跳过
    elif [ "$rc" -ne 0 ]; then
        return 1
    fi
    _mc_install_west_operator || return 1

    # ============================================================
    # 步骤 1: East 给 Kiali server 加查询范围（query_scope.mesh_id）
    # ============================================================
    log_info "步骤 1: East 配置 query_scope.mesh_id"
    runme print install-kiali-mc:query-scope-yaml > "$work/kiali-query-scope.yaml" || {
        log_error "获取 query-scope-yaml 模板失败"
        return 1
    }
    # 文档示例用 mesh1；实际 meshID 不同时按 Istio CR 的值改写（文档要求两者一致）
    local mesh_id
    mesh_id=$(kubectl --context "$CTX_CLUSTER1" get istio default \
        -o jsonpath='{.spec.values.global.meshID}' 2>/dev/null || echo "")
    if [ -n "$mesh_id" ] && [ "$mesh_id" != "mesh1" ]; then
        log_info "实际 meshID=${mesh_id}，改写模板中的 mesh1"
        sed "s|mesh_id: mesh1|mesh_id: ${mesh_id}|" "$work/kiali-query-scope.yaml" \
            > "$work/kiali-query-scope.yaml.new" || return 1
        mv "$work/kiali-query-scope.yaml.new" "$work/kiali-query-scope.yaml"
    fi

    kubectl_apply_runme_block "install-kiali-mc:apply-query-scope" "$work/" || {
        log_error "应用 query_scope 失败"
        return 1
    }
    log_success "query_scope 配置完成"

    # ============================================================
    # 步骤 2: West 创建仅含远端资源的 Kiali CR
    # ============================================================
    log_info "步骤 2: West 创建 remote_cluster_resources_only 的 Kiali CR"
    runme print install-kiali-mc:kiali-remote-yaml > "$work/kiali-remote.yaml" || {
        log_error "获取 kiali-remote-yaml 模板失败"
        return 1
    }
    kubectl_apply_runme_block "install-kiali-mc:apply-kiali-remote" "$work/" || {
        log_error "应用 West Kiali CR 失败"
        return 1
    }

    log_info "步骤 2.1: 等待 West Kiali CR 调和完成"
    runme run install-kiali-mc:wait-kiali-remote || {
        log_error "West Kiali CR 未在超时内就绪"
        return 1
    }
    log_success "West Kiali CR 已就绪"

    # ============================================================
    # 步骤 3: West 创建长期有效的 ServiceAccount token Secret
    # ============================================================
    log_info "步骤 3: West 创建长期 SA token Secret"
    runme print install-kiali-mc:svc-account-token-yaml > "$work/kiali-svc-account-token.yaml" || {
        log_error "获取 svc-account-token-yaml 模板失败"
        return 1
    }
    kubectl_apply_runme_block "install-kiali-mc:apply-svc-account-token" "$work/" || {
        log_error "创建长期 SA token Secret 失败"
        return 1
    }
    log_success "长期 SA token Secret 创建完成"

    # ============================================================
    # 步骤 4: 获取 West 的平台代理 kubeconfig
    # ============================================================
    log_info "步骤 4: 下载 West 集群 kubeconfig (平台 API)"
    if [ -z "${ACP_API_TOKEN:-}" ]; then
        log_error "步骤 4 需要 ACP_API_TOKEN (引擎会用平台账号自动获取)"
        return 1
    fi
    cmd=$(runme print install-kiali-mc:download-west-kubeconfig) || return 1
    cmd="${cmd//<your-platform-api-token>/$ACP_API_TOKEN}"
    cmd="${cmd//<platform-url>/${PLATFORM_ADDRESS%/}}"
    cmd="${cmd//<west-cluster-name>/$WEST_CLUSTER_NAME}"
    ( cd "$work" && bash -ec "$cmd" ) || {
        log_error "下载 West kubeconfig 失败"
        return 1
    }

    log_info "步骤 4.1: 规整 West kubeconfig (PEM 字段 base64 + 转 YAML)"
    cmd=$(runme print install-kiali-mc:normalize-west-kubeconfig) || return 1
    ( cd "$work" && bash -ec "$cmd" ) || {
        log_error "规整 West kubeconfig 失败"
        return 1
    }
    chmod 600 "$work"/west-kubeconfig*.json "$work/west-kubeconfig.yaml" 2>/dev/null || true

    log_info "步骤 4.2: 校验 proxy-connect context 指向平台代理地址"
    local proxy_server
    proxy_server=$(jq -r '
        (.contexts[] | select(.name == "proxy-connect") | .context.cluster) as $c
        | .clusters[] | select(.name == $c) | .cluster.server
    ' "$work/west-kubeconfig-fixed.json" 2>/dev/null || echo "")
    # 只断言路径部分：平台代理是 <platform-url>/kubernetes/<cluster>，裸 API Server 是
    # https://<node>:6443，路径足以区分两者；主机形态随平台地址的配置方式而异
    #（域名 / IP / 带端口），不参与比对
    expected=$(runme print install-kiali-mc:proxy-server-url) || return 1
    expected="${expected//<west-cluster-name>/$WEST_CLUSTER_NAME}"
    expected="${expected#<platform-url>}"
    if ! __cmp_contains "$proxy_server" "$expected"; then
        log_error "proxy-connect 的 server 地址不是平台代理地址"
        log_error "期待包含: $expected"
        log_error "实际: $proxy_server"
        return 1
    fi
    log_success "proxy-connect server = $proxy_server"

    log_info "步骤 4.3: 合并 West proxy-connect context 并导出 CTX_CLUSTER2_PROXY"
    # 合并前先把 YAML 转回 JSON 交给 jq 改名（kubectl config 没有重命名 cluster/user 的子命令）
    KUBECONFIG="$work/west-kubeconfig.yaml" kubectl config view --raw -o json \
        > "$work/west-kubeconfig.yaml.json" 2>/dev/null || {
        log_error "读取 West kubeconfig 失败"
        return 1
    }
    _mc_merge_proxy_kubeconfig "$work" || return 1

    cmd=$(runme print install-kiali-mc:set-proxy-context) || return 1
    cmd="${cmd//<your cluster2 proxy-connect context>/${WEST_CLUSTER_NAME}-proxy-connect}"
    eval "$cmd" || return 1
    log_info "CTX_CLUSTER2_PROXY=${CTX_CLUSTER2_PROXY}"

    # ============================================================
    # 步骤 5: East 创建 remote cluster secret
    # ============================================================
    log_info "步骤 5: 下载 kiali-prepare-remote-cluster.sh"
    runme_run_curl_with_assets install-kiali-mc:download-prepare-script "$work" || {
        log_error "下载 kiali-prepare-remote-cluster.sh 失败"
        return 1
    }

    # 删除旧 Secret，保证本次测试验证的是当前命令生成的内容。
    kubectl --context "$CTX_CLUSTER1" -n istio-system \
        delete secret "$_MC_REMOTE_SECRET" --ignore-not-found=true > /dev/null 2>&1 || true

    log_info "步骤 5.1: 执行 kiali-prepare-remote-cluster.sh"
    cmd=$(runme print install-kiali-mc:run-prepare-script) || return 1
    output=$( cd "$work" && eval "$cmd" 2>&1 ) || {
        log_error "kiali-prepare-remote-cluster.sh 执行失败"
        log_error "实际输出: $output"
        return 1
    }

    if ! _mc_validate_remote_secret "$proxy_server" "$output"; then
        log_error "remote cluster secret 生成结果验证失败"
        return 1
    fi
    log_success "remote cluster secret 已生成且内容可供 Kiali 使用"

    # ============================================================
    # 步骤 6: 触发 Kiali server 调和
    # ============================================================
    log_info "步骤 6: 触发 East Kiali server 调和"
    runme run install-kiali-mc:trigger-reconcile || {
        log_error "触发调和失败"
        return 1
    }

    log_info "步骤 6.1: 等待 Kiali CR 与 Deployment 就绪"
    # 两条命令的块：用独立 bash -e 子进程执行，首条失败即中断
    cmd=$(runme print install-kiali-mc:wait-kiali-server) || return 1
    bash -ec "$cmd" || {
        log_error "Kiali server 未在超时内就绪"
        return 1
    }
    log_success "Kiali server 已就绪"

    # ============================================================
    # 步骤 7: 验证两个集群都被发现且可达
    # ============================================================
    log_info "步骤 7: 验证 Kiali 已发现全部集群"
    # 期待输出里的 ApiEndpoint（East 的 ClusterIP）是动态值，截掉后按行断言
    expected=$(runme print install-kiali-mc:verify-discovered-clusters-output \
        | sed -e 's|, ApiEndpoint=.*||' -e 's|^INF |+ |') || return 1
    if ! retry_runme_verify install-kiali-mc:verify-discovered-clusters \
            __cmp_lines "$expected" 12 10; then
        log_error "Kiali 未发现全部集群或集群不可达"
        log_error "期待包含: $expected"
        log_error "实际输出: $RETRY_RUNME_OUTPUT"
        return 1
    fi
    log_success "Kiali 已发现全部集群且均可达"

    log_info "Kiali 控制台地址: ${PLATFORM_ADDRESS%/}/clusters/${EAST_CLUSTER_NAME}/kiali"
    log_info "文档验证步骤 2-4（Namespaces / Mesh / Traffic Graph 页面）为控制台操作，不含代码块"

    return 0
}

test_install_kiali_in_multi_cluster_mesh() {
    log_info "=========================================="
    log_info "开始 Kiali 多集群服务网格测试"
    log_info "=========================================="

    _mc_setup_env || return 1

    # 工作目录里会落 West 集群的 kubeconfig（含凭据），用完即删
    local work rc=0
    work=$(mktemp -d) || return 1
    chmod 700 "$work"
    _mc_test_impl "$work" || rc=$?
    # 工作目录里的合并 kubeconfig 随目录一起删，先把 KUBECONFIG 还原回框架的 merged.yaml
    export KUBECONFIG="$KUBECONFIG_MERGED_FILE"
    rm -rf "$work"

    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi

    log_success "=========================================="
    log_success "Kiali 多集群服务网格测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# 清理：文档的「Removing a cluster from Kiali」+「Cleaning up Kiali」两节
cleanup_install_kiali_in_multi_cluster_mesh() {
    log_info "=========================================="
    log_info "清理 Kiali 多集群配置"
    log_info "=========================================="

    _mc_setup_env || return 1

    local rc=0 output expected

    # 移除集群 步骤 1: 删除 East 上的 remote cluster secret
    log_info "步骤 1: 删除 remote cluster secret"
    runme run install-kiali-mc:delete-remote-secret || {
        log_warn "删除 remote cluster secret 返回非零 (可能已不存在)"
    }

    # 移除集群 步骤 2: 删除 West 的 Kiali CR（连带回收 SA 与长期 token Secret）
    log_info "步骤 2: 删除 West 的 Kiali CR"
    runme run install-kiali-mc:delete-remote-kiali || {
        log_warn "删除 West Kiali CR 返回非零 (可能已不存在)"
    }

    # 移除集群 步骤 3: 触发调和，让 Kiali server 不再找已删除的 secret
    log_info "步骤 3: 触发 East Kiali server 调和"
    runme run install-kiali-mc:reconcile-after-removal || {
        log_warn "触发调和返回非零"
        rc=1
    }

    # 移除集群 步骤 4: 重建 Deployment，卸掉已删除 secret 的卷
    log_info "步骤 4: 重建 Kiali Deployment 并确认卷已移除"
    local cmd
    cmd=$(runme print install-kiali-mc:recreate-kiali-deployment) || return 1
    bash -ec "$cmd" || {
        log_warn "重建 Kiali Deployment 未完全成功"
        rc=1
    }

    output=$(runme run install-kiali-mc:verify-volumes 2>&1) || {
        log_warn "读取 Kiali Deployment 卷列表失败"
        rc=1
    }
    if [ -n "$output" ] && ! __cmp_not_contains "$output" "$_MC_ISTIO_CLUSTER2"; then
        log_error "Kiali Deployment 仍挂载已删除集群的卷"
        log_error "实际卷列表: $output"
        return 1
    fi
    log_success "已删除集群的卷不再挂载"

    # 清理 Kiali 步骤 2: 删除 East 的 Kiali CR（步骤 1 已在上面完成）
    log_info "步骤 5: 删除 East 的 Kiali 资源"
    runme run install-kiali-mc:delete-kiali-server || {
        log_warn "删除 East Kiali CR 返回非零 (可能已不存在)"
    }

    log_info "步骤 6: 确认 Kiali server 已被移除"
    expected=$(runme print install-kiali-mc:verify-kiali-server-removed-output) || return 1
    # Deployment 不存在时 kubectl 返回非零，retry_cmd_verify 要求命令 rc=0，故补 || true
    if ! retry_cmd_verify \
            "runme run install-kiali-mc:verify-kiali-server-removed || true" \
            __cmp_contains "$expected" 12 5; then
        log_error "Kiali server Deployment 仍存在"
        log_error "期待包含: $expected"
        log_error "实际输出: $RETRY_CMD_OUTPUT"
        return 1
    fi
    log_success "Kiali server 已被移除"

    if [ "$rc" -eq 0 ]; then
        log_success "Kiali 多集群配置清理完成"
    else
        log_warn "部分清理步骤失败 (上方已记录)"
    fi
    return 0
}
