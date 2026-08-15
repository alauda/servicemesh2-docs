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
# 参考脚本：hack/update-istio-in-docs.sh
#
# 说明：
#   此脚本仅更新 docs/en/integration/observability/kiali.mdx 中的 Kiali 版本。
#   支持标准版本（x.y.z）以及带预发布或发行后缀的版本（如 x.y.z-rc.0、
#   x.y.z-r0）。
#
# 用法：
#   ./hack/update-kiali-in-docs.sh <NEW_VERSION> <OLD_VERSION>
#
# 示例：
#   ./hack/update-kiali-in-docs.sh 2.27.1-rc.0 2.22.2
#   ./hack/update-kiali-in-docs.sh 2.27.1-r0 2.27.1-rc.0
# ============================================================================

set -euo pipefail

# 参数校验
if [ "$#" -ne 2 ]; then
    echo "Error: Incorrect number of arguments." >&2
    echo "Usage: $0 <NEW_VERSION> <OLD_VERSION>" >&2
    exit 1
fi

NEW_VERSION="$1"
OLD_VERSION="$2"

# 版本格式校验：x.y.z，后面可带由字母、数字、点或连字符组成的后缀
VERSION_REGEX='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'
if ! [[ "$NEW_VERSION" =~ $VERSION_REGEX ]]; then
    echo "Error: New version '$NEW_VERSION' does not match the expected Kiali version format." >&2
    exit 1
fi

if ! [[ "$OLD_VERSION" =~ $VERSION_REGEX ]]; then
    echo "Error: Old version '$OLD_VERSION' does not match the expected Kiali version format." >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET_FILE="$REPO_ROOT/docs/en/integration/observability/kiali.mdx"

if [ ! -f "$TARGET_FILE" ]; then
    echo "Error: Target file '$TARGET_FILE' does not exist." >&2
    exit 1
fi

# 设置 sed 命令以兼容 macOS
SED_CMD="sed"
if [[ "$(uname)" == "Darwin" ]]; then
    SED_CMD="gsed"
fi

# 检查 sed/gsed 是否可用
if ! command -v "$SED_CMD" &> /dev/null; then
    echo "Error: '$SED_CMD' command not found." >&2
    if [[ "$SED_CMD" == "gsed" ]]; then
        echo "Please install GNU sed (for example, run 'brew install gnu-sed')." >&2
    else
        echo "Please install sed." >&2
    fi
    exit 1
fi

echo "The Kiali versions to update are:"
echo "NEW_VERSION: $NEW_VERSION"
echo "OLD_VERSION: $OLD_VERSION"

if ! grep -Fq -- "$OLD_VERSION" "$TARGET_FILE"; then
    echo "Updated 0 Kiali version references in docs/en/integration/observability/kiali.mdx."
    exit 0
fi

# 为 sed 正则表达式转义版本号中的点号和加号
ESCAPED_OLD_VERSION=$(printf '%s' "$OLD_VERSION" | sed 's/[.+]/\\&/g')
MATCH_COUNT=$(grep -Fo -- "$OLD_VERSION" "$TARGET_FILE" | wc -l | tr -d ' ')

"$SED_CMD" -i -E "s/$ESCAPED_OLD_VERSION/$NEW_VERSION/g" "$TARGET_FILE"

echo "Updated $MATCH_COUNT Kiali version references in docs/en/integration/observability/kiali.mdx."
