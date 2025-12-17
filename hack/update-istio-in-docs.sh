#!/bin/bash

# Copyright Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0 
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ============================================================================
# Original script: https://github.com/istio-ecosystem/sail-operator/blob/main/hack/update-istio-in-docs.sh
#
# Description:
#   This script updates Istio version references in MDX documentation files.
#   It replaces all occurrences of the old version with the new version in both
#   standard format (x.y.z) and revision format (x-y-z).
#
# Usage:
#   ./update-istio-in-docs.sh <NEW_VERSION> <OLD_VERSION>
# 
# Example:
#   ./hack/update-istio-in-docs.sh 1.28.0 1.26.3
#   ./hack/update-istio-in-docs.sh 1.26.3 1.24.6
# ============================================================================

set -euo pipefail

# 参数校验
if [ $# -ne 2 ]; then
    echo "Error: Incorrect number of arguments." >&2
    echo "Usage: $0 <NEW_VERSION> <OLD_VERSION>" >&2
    exit 1
fi

NEW_VERSION="$1"
OLD_VERSION="$2"

# 版本格式校验 (x.y.z)
VERSION_REGEX="^[0-9]+\.[0-9]+\.[0-9]+$"
if ! [[ "$NEW_VERSION" =~ $VERSION_REGEX ]]; then
    echo "Error: New version '$NEW_VERSION' does not match expected format (x.y.z)" >&2
    exit 1
fi

if ! [[ "$OLD_VERSION" =~ $VERSION_REGEX ]]; then
    echo "Error: Old version '$OLD_VERSION' does not match expected format (x.y.z)" >&2
    exit 1
fi

# 转换为修订格式 (x-y-z)
NEW_VERSION_REVISION_FORMAT=$(echo "$NEW_VERSION" | tr '.' '-')
OLD_VERSION_REVISION_FORMAT=$(echo "$OLD_VERSION" | tr '.' '-')

echo "The versions to update are:"
echo "NEW_VERSION: $NEW_VERSION"
echo "NEW_VERSION_REVISION_FORMAT: $NEW_VERSION_REVISION_FORMAT"
echo "OLD_VERSION: $OLD_VERSION"
echo "OLD_VERSION_REVISION_FORMAT: $OLD_VERSION_REVISION_FORMAT"

# 设置 sed 命令以兼容 macOS
SED_CMD="sed"
if [[ "$(uname)" == "Darwin" ]]; then
  SED_CMD="gsed"
fi

# 检查 sed/gsed 是否可用
if ! command -v "$SED_CMD" &> /dev/null; then
    echo "Error: '$SED_CMD' command not found." >&2
    if [[ "$SED_CMD" == "gsed" ]]; then
        echo "Please install gnu-sed (e.g., 'brew install gnu-sed')." >&2
    else
        echo "Please install sed." >&2
    fi
    exit 1
fi

# 为 sed 转义特殊字符 (点号是正则特殊字符)
ESCAPED_OLD_VERSION=$(echo "$OLD_VERSION" | sed 's/\./\\./g')
ESCAPED_NEW_VERSION=$(echo "$NEW_VERSION" | sed 's/\./\\./g')

# 查找并更新所有 .mdx 文件（排除 docs/en/about/release-notes/）
echo "Searching for .mdx files in docs/en/ (excluding docs/en/about/release-notes)..."

file_count=0
while IFS= read -r -d '' file; do
    echo "Updating file: $file"
    
    # 替换 VERSION 格式 (x.y.z)
    "$SED_CMD" -i -E "s/$ESCAPED_OLD_VERSION/$ESCAPED_NEW_VERSION/g" "$file"
    
    # 替换 REVISION_FORMAT 格式 (x-y-z)
    "$SED_CMD" -i -E "s/$OLD_VERSION_REVISION_FORMAT/$NEW_VERSION_REVISION_FORMAT/g" "$file"
    
    ((file_count++))
done < <(find docs/en -type f -name '*.mdx' ! -path 'docs/en/about/release-notes/*' -print0)

echo "Updated $file_count documentation files successfully."
