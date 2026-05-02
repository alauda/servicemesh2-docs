#!/usr/bin/env bash
# kubeconfig 管理工具函数库
#
# 通过 ACP 平台 API 自动获取集群 kubeconfig，并生成合并后的 KUBECONFIG。
# 依赖环境变量:
#   - PLATFORM_ADDRESS         必填，ACP 平台地址
#   - ACP_API_TOKEN            必填，ACP 平台 API token
#   - ACP_KUBECONFIG_MODE      可选，proxy(默认) | direct，决定使用 proxy-connect 还是 direct-connect context
#
# 暴露函数:
#   - fetch_cluster_kubeconfig <cluster> <output>     拉取单集群 kubeconfig 并规整
#   - setup_kubeconfig         <cluster>...           强制拉取多集群 kubeconfig，合并并 export KUBECONFIG
#   - ensure_kubeconfig        <cluster>...           按 fingerprint 比对，必要时重新拉取
#   - load_kubeconfig                                 仅复用已存在的合并 kubeconfig，找不到则报错

# 防止重复 source
if [ -n "${__KUBECONFIG_SH_LOADED:-}" ]; then
    return 0
fi
__KUBECONFIG_SH_LOADED=1

# 解析自身目录，定位 kubeconfig 缓存目录
__KUBECONFIG_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_DIR="${KUBECONFIG_DIR:-$(cd "$__KUBECONFIG_SH_DIR/.." && pwd)/.kubeconfig}"
KUBECONFIG_MERGED_FILE="$KUBECONFIG_DIR/merged.yaml"
KUBECONFIG_FINGERPRINT_FILE="$KUBECONFIG_DIR/.fingerprint"

# 加载日志函数（如果尚未加载）
if ! declare -f log_info > /dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$__KUBECONFIG_SH_DIR/common.sh"
fi

# 计算 kubeconfig 配置指纹
# 基于 PLATFORM_ADDRESS、ACP_KUBECONFIG_MODE、ACP_API_TOKEN、去重排序后的集群列表
# 用法: _compute_kubeconfig_fingerprint <cluster>...
_compute_kubeconfig_fingerprint() {
    local mode="${ACP_KUBECONFIG_MODE:-proxy}"
    local sorted_clusters
    sorted_clusters=$(printf '%s\n' "$@" | sort -u | tr '\n' ',')

    printf '%s|%s|%s|%s' \
        "${PLATFORM_ADDRESS:-}" \
        "$mode" \
        "${ACP_API_TOKEN:-}" \
        "$sorted_clusters" \
        | sha256sum | awk '{print $1}'
}

# 校验 kubeconfig 拉取所需的环境变量
_check_kubeconfig_env() {
    local missing=()
    [ -z "${PLATFORM_ADDRESS:-}" ] && missing+=("PLATFORM_ADDRESS")
    [ -z "${ACP_API_TOKEN:-}" ] && missing+=("ACP_API_TOKEN")

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "缺少必要环境变量: ${missing[*]}"
        return 1
    fi
    return 0
}

# 拉取单集群 kubeconfig 并规整为以集群名命名的 context
# 用法: fetch_cluster_kubeconfig <cluster-name> <output-path>
fetch_cluster_kubeconfig() {
    local cluster="$1"
    local output="$2"

    if [ -z "$cluster" ] || [ -z "$output" ]; then
        log_error "fetch_cluster_kubeconfig: 缺少参数 (cluster=$cluster, output=$output)"
        return 1
    fi

    _check_kubeconfig_env || return 1

    local mode="${ACP_KUBECONFIG_MODE:-proxy}"
    local target_context="${mode}-connect"
    local url="${PLATFORM_ADDRESS%/}/auth/v1/clusters/${cluster}/kubeconfig"

    log_info "拉取集群 kubeconfig: $cluster (mode=$mode)"

    # 调用 API
    local response http_code body
    response=$(curl -k -sS -o /tmp/kubeconfig-resp.$$.json -w "%{http_code}" \
        -H "Authorization: Bearer ${ACP_API_TOKEN}" \
        "$url" 2>&1) || {
        log_error "调用 kubeconfig API 失败: $url"
        log_error "curl 输出: $response"
        rm -f /tmp/kubeconfig-resp.$$.json
        return 1
    }

    http_code="$response"
    body=$(cat /tmp/kubeconfig-resp.$$.json 2>/dev/null || echo "")
    rm -f /tmp/kubeconfig-resp.$$.json

    if [ "$http_code" != "200" ]; then
        log_error "kubeconfig API 返回非 200: HTTP $http_code"
        log_error "响应: $body"
        return 1
    fi

    if [ -z "$body" ] || ! echo "$body" | jq empty 2>/dev/null; then
        log_error "kubeconfig API 响应不是有效 JSON"
        log_error "响应: $body"
        return 1
    fi

    # 规整 JSON:
    # - 仅保留 ${mode}-connect 这一个 context
    # - 仅保留对应的 cluster
    # - 重命名 user 为 ${cluster}-user，避免多集群合并时同名冲突
    # - 重命名 cluster 为 ${cluster}
    # - context 名设为 ${cluster}
    # - current-context 设为 ${cluster}
    local processed
    processed=$(echo "$body" | jq --arg ctx "$target_context" --arg cluster "$cluster" '
        (.contexts[]? | select(.name == $ctx)) as $target |
        if $target == null then
            error("API 响应中未找到 context: " + $ctx)
        else . end |
        ($target.context.cluster) as $cluster_ref |
        ($target.context.user) as $user_ref |
        ($cluster + "-user") as $new_user |
        {
            "preferences": (.preferences // {}),
            "apiVersion": (.apiVersion // "v1"),
            "kind": (.kind // "Config"),
            "clusters": [
                .clusters[]? | select(.name == $cluster_ref) | .name = $cluster
            ],
            "users": [
                .users[]? | select(.name == $user_ref) | .name = $new_user
            ],
            "contexts": [{
                "name": $cluster,
                "context": {
                    "cluster": $cluster,
                    "user": $new_user
                }
            }],
            "current-context": $cluster
        }
    ' 2>&1) || {
        log_error "处理 kubeconfig JSON 失败: $processed"
        return 1
    }

    # 写入临时 JSON 后用 kubectl 转换为标准 YAML 格式
    mkdir -p "$(dirname "$output")"
    local tmp_json
    tmp_json=$(mktemp)
    echo "$processed" > "$tmp_json"
    chmod 600 "$tmp_json"

    if ! KUBECONFIG="$tmp_json" kubectl config view --raw --flatten > "$output" 2>/dev/null; then
        log_error "转换 kubeconfig 格式失败 (kubectl 无法解析 API 响应)"
        log_error "原始 JSON: $processed"
        rm -f "$tmp_json"
        return 1
    fi
    rm -f "$tmp_json"
    chmod 600 "$output"

    log_success "已写入 kubeconfig: $output (context=$cluster)"
    return 0
}

# 强制拉取所有集群 kubeconfig，合并并 export KUBECONFIG
# 用法: setup_kubeconfig <cluster-name>...
# 说明:
#   - 集群列表会去重（处理 SINGLE/EAST/WEST 重名情况）
#   - 合并后的 KUBECONFIG 默认 current-context 设为传入的第一个集群
#   - 写入 fingerprint 供 ensure_kubeconfig 比对
setup_kubeconfig() {
    if [ $# -eq 0 ]; then
        log_error "setup_kubeconfig: 至少需要一个集群名称"
        return 1
    fi

    _check_kubeconfig_env || return 1

    # 校验 jq / kubectl 工具
    if ! command -v jq > /dev/null 2>&1; then
        log_error "缺少 jq 工具"
        return 1
    fi
    if ! command -v kubectl > /dev/null 2>&1; then
        log_error "缺少 kubectl 工具"
        return 1
    fi

    # 去重并保持顺序（处理 SINGLE/EAST/WEST 重名的情况）
    local clusters=()
    local seen=","
    local c
    for c in "$@"; do
        [ -z "$c" ] && continue
        case "$seen" in
            *",${c},"*) continue ;;
        esac
        clusters+=("$c")
        seen="${seen}${c},"
    done

    if [ ${#clusters[@]} -eq 0 ]; then
        log_error "去重后集群列表为空"
        return 1
    fi

    log_info "初始化 kubeconfig (集群: ${clusters[*]})"

    # 重建缓存目录
    rm -rf "$KUBECONFIG_DIR"
    mkdir -p "$KUBECONFIG_DIR"
    chmod 700 "$KUBECONFIG_DIR"

    # 拉取每个集群
    local files=()
    for c in "${clusters[@]}"; do
        local out="$KUBECONFIG_DIR/${c}.yaml"
        fetch_cluster_kubeconfig "$c" "$out" || return 1
        files+=("$out")
    done

    # 合并
    if [ ${#files[@]} -eq 1 ]; then
        cp "${files[0]}" "$KUBECONFIG_MERGED_FILE"
    else
        local kc
        kc=$(IFS=:; echo "${files[*]}")
        if ! KUBECONFIG="$kc" kubectl config view --raw --flatten > "$KUBECONFIG_MERGED_FILE" 2>/dev/null; then
            log_error "合并多集群 kubeconfig 失败"
            return 1
        fi
    fi
    chmod 600 "$KUBECONFIG_MERGED_FILE"

    # 设置默认 current-context 为第一个集群
    if ! kubectl --kubeconfig="$KUBECONFIG_MERGED_FILE" config use-context "${clusters[0]}" > /dev/null 2>&1; then
        log_error "设置 current-context 失败: ${clusters[0]}"
        return 1
    fi

    # 写入 fingerprint
    _compute_kubeconfig_fingerprint "${clusters[@]}" > "$KUBECONFIG_FINGERPRINT_FILE"
    chmod 600 "$KUBECONFIG_FINGERPRINT_FILE"

    export KUBECONFIG="$KUBECONFIG_MERGED_FILE"

    log_success "KUBECONFIG 已设置: $KUBECONFIG_MERGED_FILE"
    log_success "可用 contexts: ${clusters[*]}"
    log_success "默认 context: ${clusters[0]}"
    return 0
}

# 按 fingerprint 比对，确保 kubeconfig 与传入集群列表一致
# 一致则复用现有合并文件并 export KUBECONFIG，不一致则重新拉取
# 用法: ensure_kubeconfig <cluster-name>...
ensure_kubeconfig() {
    if [ $# -eq 0 ]; then
        log_error "ensure_kubeconfig: 至少需要一个集群名称"
        return 1
    fi

    # 文件不存在 -> 拉取
    if [ ! -f "$KUBECONFIG_MERGED_FILE" ] || [ ! -f "$KUBECONFIG_FINGERPRINT_FILE" ]; then
        log_info "kubeconfig 不存在，自动拉取..."
        setup_kubeconfig "$@"
        return $?
    fi

    # fingerprint 比对
    local current expected
    current=$(_compute_kubeconfig_fingerprint "$@")
    expected=$(cat "$KUBECONFIG_FINGERPRINT_FILE" 2>/dev/null || echo "")

    if [ "$current" != "$expected" ]; then
        log_warn "检测到 kubeconfig 配置变更 (PLATFORM_ADDRESS / ACP_KUBECONFIG_MODE / ACP_API_TOKEN / 集群列表 中有变化)"
        log_info "重新拉取 kubeconfig..."
        setup_kubeconfig "$@"
        return $?
    fi

    export KUBECONFIG="$KUBECONFIG_MERGED_FILE"
    log_info "复用现有 kubeconfig: $KUBECONFIG_MERGED_FILE"
    return 0
}

# 仅 export 已存在的合并 kubeconfig，找不到则报错
# 用法: load_kubeconfig
load_kubeconfig() {
    if [ ! -f "$KUBECONFIG_MERGED_FILE" ]; then
        log_error "未找到 kubeconfig: $KUBECONFIG_MERGED_FILE"
        log_error "请先执行 './run.sh --init-only' 进行初始化"
        return 1
    fi

    export KUBECONFIG="$KUBECONFIG_MERGED_FILE"
    return 0
}
