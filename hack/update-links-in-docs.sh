#!/bin/bash

# ============================================================================
# 说明：
#   更新 docs/en 下所有 .mdx 文档中 Istio 和 Sail Operator GitHub 链接的
#   release 分支版本。脚本仅修改以下两个仓库的目标版本链接：
#   - istio/istio
#   - alauda-mesh/sail-operator
#
# 用法：
#   ./hack/update-links-in-docs.sh \
#     <NEW_ISTIO_VERSION> <OLD_ISTIO_VERSION> \
#     <NEW_SAIL_VERSION> <OLD_SAIL_VERSION>
#
# 示例：
#   ./hack/update-links-in-docs.sh 1.31 1.30 2.3 2.2
# ============================================================================

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "错误：参数数量不正确。" >&2
    echo "用法：$0 <NEW_ISTIO_VERSION> <OLD_ISTIO_VERSION> <NEW_SAIL_VERSION> <OLD_SAIL_VERSION>" >&2
    exit 1
fi

NEW_ISTIO_VERSION="$1"
OLD_ISTIO_VERSION="$2"
NEW_SAIL_VERSION="$3"
OLD_SAIL_VERSION="$4"

# release 分支版本格式为 x.y，例如 1.30 或 2.2。
VERSION_REGEX='^[0-9]+\.[0-9]+$'
for version_name in \
    NEW_ISTIO_VERSION \
    OLD_ISTIO_VERSION \
    NEW_SAIL_VERSION \
    OLD_SAIL_VERSION; do
    version_value="${!version_name}"
    if ! [[ "$version_value" =~ $VERSION_REGEX ]]; then
        echo "错误：$version_name 的值 '$version_value' 不符合 x.y 格式。" >&2
        exit 1
    fi
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DOCS_DIR="$REPO_ROOT/docs/en"

if [ ! -d "$DOCS_DIR" ]; then
    echo "错误：文档目录 '$DOCS_DIR' 不存在。" >&2
    exit 1
fi

OLD_ISTIO_LINK_PREFIX="https://raw.githubusercontent.com/istio/istio/refs/heads/release-${OLD_ISTIO_VERSION}/"
NEW_ISTIO_LINK_PREFIX="https://raw.githubusercontent.com/istio/istio/refs/heads/release-${NEW_ISTIO_VERSION}/"

# Sail Operator 文档中同时存在三种分支链接格式，需要逐一匹配。
OLD_SAIL_LINK_PREFIXES=(
    "https://raw.githubusercontent.com/alauda-mesh/sail-operator/refs/heads/release-${OLD_SAIL_VERSION}/"
    "https://raw.githubusercontent.com/alauda-mesh/sail-operator/release-${OLD_SAIL_VERSION}/"
    "https://github.com/alauda-mesh/sail-operator/blob/release-${OLD_SAIL_VERSION}/"
)
NEW_SAIL_LINK_PREFIXES=(
    "https://raw.githubusercontent.com/alauda-mesh/sail-operator/refs/heads/release-${NEW_SAIL_VERSION}/"
    "https://raw.githubusercontent.com/alauda-mesh/sail-operator/release-${NEW_SAIL_VERSION}/"
    "https://github.com/alauda-mesh/sail-operator/blob/release-${NEW_SAIL_VERSION}/"
)

# 转义 sed 搜索表达式中的点号；版本参数已限制为数字和点号。
OLD_ISTIO_VERSION_PATTERN=${OLD_ISTIO_VERSION//./\\.}
OLD_SAIL_VERSION_PATTERN=${OLD_SAIL_VERSION//./\\.}
ISTIO_SED_EXPRESSION="s|https://raw\\.githubusercontent\\.com/istio/istio/refs/heads/release-${OLD_ISTIO_VERSION_PATTERN}/|${NEW_ISTIO_LINK_PREFIX}|g"
SAIL_SED_EXPRESSIONS=(
    "s|https://raw\\.githubusercontent\\.com/alauda-mesh/sail-operator/refs/heads/release-${OLD_SAIL_VERSION_PATTERN}/|${NEW_SAIL_LINK_PREFIXES[0]}|g"
    "s|https://raw\\.githubusercontent\\.com/alauda-mesh/sail-operator/release-${OLD_SAIL_VERSION_PATTERN}/|${NEW_SAIL_LINK_PREFIXES[1]}|g"
    "s|https://github\\.com/alauda-mesh/sail-operator/blob/release-${OLD_SAIL_VERSION_PATTERN}/|${NEW_SAIL_LINK_PREFIXES[2]}|g"
)

# 兼容 GNU sed 和 macOS 自带的 BSD sed。
SED_IN_PLACE=(-i)
if [[ "$(uname -s)" == "Darwin" ]]; then
    SED_IN_PLACE=(-i '')
fi

updated_file_count=0
istio_link_count=0
sail_link_count=0

while IFS= read -r -d '' file; do
    sed_expressions=()

    if [[ "$NEW_ISTIO_VERSION" != "$OLD_ISTIO_VERSION" ]] && grep -Fq -- "$OLD_ISTIO_LINK_PREFIX" "$file"; then
        match_count=$(grep -Fo -- "$OLD_ISTIO_LINK_PREFIX" "$file" | wc -l | tr -d '[:space:]')
        istio_link_count=$((istio_link_count + match_count))
        sed_expressions+=(-e "$ISTIO_SED_EXPRESSION")
    fi

    if [[ "$NEW_SAIL_VERSION" != "$OLD_SAIL_VERSION" ]]; then
        for index in "${!OLD_SAIL_LINK_PREFIXES[@]}"; do
            old_sail_link_prefix=${OLD_SAIL_LINK_PREFIXES[$index]}
            if ! grep -Fq -- "$old_sail_link_prefix" "$file"; then
                continue
            fi

            match_count=$(grep -Fo -- "$old_sail_link_prefix" "$file" | wc -l | tr -d '[:space:]')
            sail_link_count=$((sail_link_count + match_count))
            sed_expressions+=(-e "${SAIL_SED_EXPRESSIONS[$index]}")
        done
    fi

    if [ "${#sed_expressions[@]}" -eq 0 ]; then
        continue
    fi

    relative_file=${file#"$REPO_ROOT/"}
    echo "正在更新：$relative_file"
    sed "${SED_IN_PLACE[@]}" "${sed_expressions[@]}" "$file"
    updated_file_count=$((updated_file_count + 1))
done < <(find "$DOCS_DIR" -type f -name '*.mdx' -print0)

echo "更新完成：共修改 $updated_file_count 个文档、$istio_link_count 个 Istio 链接和 $sail_link_count 个 Sail Operator 链接。"
