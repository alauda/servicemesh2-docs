#!/bin/bash
# ============================================================================

# Description:
#   更新 Sail Operator 的 Custom Resource Definitions (CRDs) 文件
#   从指定的 upstream branch 下载最新的 CRD 文件并保存到本地目录

# Usage:
#   ./update-sail-operator-crds.sh <upstream-branch>

# Example:
#   ./hack/update-sail-operator-crds.sh main
#   ./hack/update-sail-operator-crds.sh release-2.1

# ============================================================================

# 检查参数数量
if [ $# -ne 1 ]; then
    echo "错误: 需要指定 upstream branch 参数"
    echo "用法: $0 <upstream-branch>"
    echo "示例: $0 main"
    echo "示例: $0 release-2.1"
    exit 1
fi

# 获取 upstream branch 参数
UPSTREAM_BRANCH="$1"

# 定义 CRD 文件列表
CRD_FILES=(
    "sailoperator.io_istiocnis.yaml"
    "sailoperator.io_istiorevisions.yaml"
    "sailoperator.io_istiorevisiontags.yaml"
    "sailoperator.io_istios.yaml"
    "sailoperator.io_ztunnels.yaml"
)

# 目标目录
TARGET_DIR="./docs/shared/crds"

# 基础 URL
BASE_URL="https://raw.githubusercontent.com/alauda-mesh/sail-operator/refs/heads/${UPSTREAM_BRANCH}/chart/crds"

echo "开始更新 Sail Operator CRDs..."
echo "上游分支: ${UPSTREAM_BRANCH}"
echo "目标目录: ${TARGET_DIR}"
echo "----------------------------------------"

# 下载每个 CRD 文件
for file in "${CRD_FILES[@]}"; do
    echo "下载: ${file}"
    url="${BASE_URL}/${file}"
    
    # 使用 curl 下载文件，检查 HTTP 状态码
    if curl -f -s -o "${TARGET_DIR}/${file}" "$url"; then
        echo "✓ 成功下载 ${file}"
    else
        echo "✗ 下载失败: ${file}"
        echo "  URL: ${url}"
        echo "  请检查分支名称是否正确，或网络连接是否正常"
        exit 1
    fi
done

echo "----------------------------------------"
echo "所有 CRD 文件已成功更新！"
echo "共下载了 ${#CRD_FILES[@]} 个文件"
echo "文件保存在: ${TARGET_DIR}"