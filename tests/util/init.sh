#!/usr/bin/env bash
# 环境初始化脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$TESTS_DIR/bin"
PKG_DIR="$TESTS_DIR/package"

# 加载公共函数
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/verify.sh"
source "$SCRIPT_DIR/kubeconfig.sh"

# 创建必要的目录
mkdir -p "$BIN_DIR"
mkdir -p "$PKG_DIR"

# 检查必要工具
check_tools() {
    log_info "检查必要工具..."

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 工具未找到，请先安装 kubectl"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        log_error "curl 工具未找到，请先安装 curl"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq 工具未找到，请先安装 jq"
        exit 1
    fi

    log_success "所有必要工具检查通过"
}

# 安装 runme 工具
install_runme() {
    log_info "检查 runme 工具..."

    if [ -f "$BIN_DIR/runme" ]; then
        local version_output
        version_output=$("$BIN_DIR/runme" --version 2>&1 || echo "")

        if echo "$version_output" | grep -q "runme version ${RUNME_VERSION}"; then
            log_success "runme $RUNME_VERSION 已安装"
            return 0
        else
            log_warn "runme 版本不匹配，重新安装"
        fi
    fi

    log_info "安装 runme $RUNME_VERSION ..."

    # 检测操作系统和架构
    local os arch url
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        *)
            log_error "不支持的操作系统: $(uname -s)"
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64" ;;
        arm64|aarch64) arch="arm64" ;;
        *)
            log_error "不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac

    url="https://downloads.runme.dev/runme/${RUNME_VERSION}/runme_${os}_${arch}.tar.gz"

    log_info "下载 runme: $url"
    curl -sSL "$url" -o "$BIN_DIR/runme.tar.gz" || {
        log_error "下载 runme 失败"
        exit 1
    }

    log_info "解压 runme..."
    tar -xzf "$BIN_DIR/runme.tar.gz" -C "$BIN_DIR" || {
        log_error "解压 runme 失败"
        exit 1
    }

    rm -f "$BIN_DIR/runme.tar.gz"
    chmod +x "$BIN_DIR/runme"

    # 验证安装
    if "$BIN_DIR/runme" --version | grep -q "runme version ${RUNME_VERSION}"; then
        log_success "runme $RUNME_VERSION 安装成功"
    else
        log_error "runme 安装验证失败"
        exit 1
    fi
}

# 安装 violet 工具
install_violet() {
    log_info "检查 violet 工具..."

    if [ -f "$BIN_DIR/violet" ]; then
        local version_output
        version_output=$("$BIN_DIR/violet" version 2>&1 || echo "")

        if echo "$version_output" | grep -q "Version: v"; then
            log_success "violet 已安装"
            return 0
        else
            log_warn "violet 验证失败，重新安装"
        fi
    fi

    log_info "安装 violet ..."

    # 检测操作系统和架构
    local os arch url
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        *)
            log_error "不支持的操作系统: $(uname -s)"
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *)
            log_error "不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac

    url="http://package-minio.alauda.cn:9199/packages/violet/latest/violet_${os}_${arch}"

    log_info "下载 violet: $url"
    curl -sSL "$url" -o "$BIN_DIR/violet" || {
        log_error "下载 violet 失败"
        exit 1
    }

    chmod +x "$BIN_DIR/violet"

    # 验证安装
    if "$BIN_DIR/violet" version | grep -q "Version: v"; then
        log_success "violet 安装成功"
    else
        log_error "violet 安装验证失败"
        exit 1
    fi
}

# 安装 istioctl 工具
# 版本号通过 runme print 从 install-multi-primary-multi-network.mdx 的
#   multi-primary-multi-network:set-istio-version
# 代码块中读取 (例: export ISTIO_VERSION=1.28.6 → 1.28.6)
# 验证: istioctl version --remote=false 输出形如 "client version: 1.28.6"
install_istioctl() {
    log_info "检查 istioctl 工具..."

    # 从 runme 块中提取 istio 版本号
    local istio_version
    istio_version=$("$BIN_DIR/runme" print multi-primary-multi-network:set-istio-version 2>/dev/null \
        | grep -oE 'ISTIO_VERSION=[0-9]+\.[0-9]+\.[0-9]+' \
        | head -n 1 \
        | cut -d= -f2)

    if [ -z "$istio_version" ]; then
        log_error "无法从 multi-primary-multi-network:set-istio-version 块中提取 ISTIO_VERSION"
        exit 1
    fi
    log_info "目标 istioctl 版本: $istio_version"

    # 检查已安装版本
    if [ -f "$BIN_DIR/istioctl" ]; then
        local version_output
        version_output=$("$BIN_DIR/istioctl" version --remote=false 2>&1 || echo "")

        if echo "$version_output" | grep -q "client version: $istio_version"; then
            log_success "istioctl $istio_version 已安装"
            return 0
        else
            log_warn "istioctl 版本不匹配 (当前: ${version_output:-未知}, 期望: $istio_version),重新安装"
        fi
    fi

    log_info "安装 istioctl $istio_version ..."

    # 检测操作系统和架构 (istioctl 发布包命名: osx/linux + amd64/arm64)
    local os arch url
    case "$(uname -s)" in
        Darwin) os="osx" ;;
        Linux)  os="linux" ;;
        *)
            log_error "不支持的操作系统: $(uname -s)"
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *)
            log_error "不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac

    url="https://github.com/istio/istio/releases/download/${istio_version}/istioctl-${istio_version}-${os}-${arch}.tar.gz"

    log_info "下载 istioctl: $url"
    curl -fsSL "$url" -o "$BIN_DIR/istioctl.tar.gz" || {
        log_error "下载 istioctl 失败: $url"
        exit 1
    }

    log_info "解压 istioctl..."
    tar -xzf "$BIN_DIR/istioctl.tar.gz" -C "$BIN_DIR" || {
        log_error "解压 istioctl 失败"
        exit 1
    }

    rm -f "$BIN_DIR/istioctl.tar.gz"
    chmod +x "$BIN_DIR/istioctl"

    # 验证安装: istioctl version --remote=false 输出形如 "client version: 1.28.6"
    local actual_version
    actual_version=$("$BIN_DIR/istioctl" version --remote=false 2>&1 || echo "")
    if echo "$actual_version" | grep -q "client version: $istio_version"; then
        log_success "istioctl $istio_version 安装成功"
    else
        log_error "istioctl 安装验证失败 (输出: $actual_version)"
        exit 1
    fi
}

# 下载插件包
download_package() {
    local url="$1"
    local filename
    filename=$(basename "$url")

    if [ -f "$PKG_DIR/$filename" ]; then
        log_info "插件包已存在: $filename"
        return 0
    fi

    log_info "下载插件包: $filename"
    curl -sSL "$url" -o "$PKG_DIR/$filename" || {
        log_error "下载插件包失败: $url"
        return 1
    }

    log_success "下载完成: $filename"
}

# 检查插件是否已上传
check_package_uploaded() {
    local cluster="$1"
    local package_url="$2"

    # 解析 ArtifactVersion 名称
    local artifact_version
    artifact_version=$(parse_artifact_version_from_package "$package_url")

    # 两种可能的名称：原始名称 和 带 operatorhub- 前缀的名称
    local artifact_version_prefixed="operatorhub-${artifact_version}"

    log_info "检查插件是否已上传到集群 $cluster: $artifact_version 或 $artifact_version_prefixed"

    # 依次检查两种名称
    local name
    for name in "$artifact_version" "$artifact_version_prefixed"; do
        # 检查资源是否存在
        if ! kubectl --context="$cluster" get artifactversion -n cpaas-system "$name" &> /dev/null; then
            continue
        fi

        # 检查状态
        local reason
        reason=$(kubectl --context="$cluster" get artifactversion -n cpaas-system "$name" -o jsonpath='{.status.reason}' 2>/dev/null || echo "")

        if [ "$reason" = "Success" ]; then
            log_success "插件已上传: $name"
            return 0
        fi
    done

    return 1
}

# 上传插件包到集群
upload_package() {
    local cluster="$1"
    local package_url="$2"
    local filename
    filename=$(basename "$package_url")

    log_info "上传插件包到集群 $cluster: $filename"

    "$BIN_DIR/violet" push "$PKG_DIR/$filename" \
        --platform-address="$PLATFORM_ADDRESS" \
        --platform-username="$PLATFORM_USERNAME" \
        --platform-password="$PLATFORM_PASSWORD" \
        --clusters="$cluster" || {
        log_error "上传插件包失败: $filename -> $cluster"
        return 1
    }

    log_success "上传成功: $filename -> $cluster"
}

# 上传所有插件包到指定集群列表
# 用法: upload_all_packages <cluster>...
upload_all_packages() {
    log_info "开始上传插件包..."

    local clusters=("$@")
    if [ ${#clusters[@]} -eq 0 ]; then
        log_warn "没有传入集群，跳过插件包上传"
        return 0
    fi

    local packages=(
        "$PKG_SERVICEMESH_OPERATOR2_URL"
        "$PKG_KIALI_OPERATOR_URL"
        "$PKG_JAEGER_OPERATOR_URL"
        "$PKG_OPENTELEMETRY_OPERATOR_URL"
        "$PKG_METALLB_OPERATOR_URL"
    )

    # 下载所有插件包
    for pkg_url in "${packages[@]}"; do
        download_package "$pkg_url"
    done

    # 上传插件包到各集群
    for cluster in "${clusters[@]}"; do
        log_info "处理集群: $cluster"

        for pkg_url in "${packages[@]}"; do
            if ! check_package_uploaded "$cluster" "$pkg_url"; then
                upload_package "$cluster" "$pkg_url"
            fi
        done
    done

    log_success "所有插件包上传完成"
}

# 在指定集群列表上安装 servicemesh-operator2
# 用法: install_all_servicemesh_operators <cluster>...
install_all_servicemesh_operators() {
    log_info "开始安装 servicemesh-operator2 ..."

    local clusters=("$@")
    if [ ${#clusters[@]} -eq 0 ]; then
        log_warn "没有传入集群，跳过 servicemesh-operator2 安装"
        return 0
    fi

    for cluster in "${clusters[@]}"; do
        # 设置 kubectl context
        kubectl config use-context "$cluster"

        log_info "安装 servicemesh-operator2 到集群: $cluster"
        install_operator \
            "servicemesh-operator2" \
            "sail-operator" \
            "$PKG_SERVICEMESH_OPERATOR2_URL" \
            "install-mesh"
    done

    log_success "所有集群的 servicemesh-operator2 安装完成"
}

# 主函数
# 用法: main <cluster>...
# 集群列表由调用方（通常是 run.sh 解析 --cluster / SINGLE_CLUSTER_NAME 后）传入
main() {
    if [ $# -eq 0 ]; then
        log_error "init.sh main: 至少需要一个集群参数"
        log_error "用法: main <cluster>..."
        return 1
    fi

    local clusters=("$@")
    log_info "开始环境初始化（集群: ${clusters[*]}）..."

    check_tools
    install_runme
    install_violet
    install_istioctl
    setup_kubeconfig "${clusters[@]}" || return 1
    upload_all_packages "${clusters[@]}" || return 1
    install_all_servicemesh_operators "${clusters[@]}" || return 1

    log_success "环境初始化完成!"
}

# 如果直接执行该脚本，要求显式传入集群参数
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
