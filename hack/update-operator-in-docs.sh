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
# 参考脚本：hack/update-kiali-in-docs.sh
#
# 说明：
#   此脚本仅更新 docs/en/installing/installing-service-mesh/install-mesh.mdx
#   中 servicemesh-operator2 Operator 的安装版本，涉及三类内容：
#     - CSV 名称：servicemesh-operator2.v<OLD_VERSION> -> servicemesh-operator2.v<NEW_VERSION>
#     - 示例输出里的 VERSION 列：<OLD_VERSION> -> <NEW_VERSION>
#     - 版本化订阅通道：stable-<旧主.次> -> stable-<新主.次>
#       通道名由版本号推断，不需要额外参数（如 2.2.0-r1 推断出 stable-2.2）。
#
#   替换只在版本号两侧都不是版本号字符时生效，因此文档里 `stable-<version>`、
#   `2.0.x` 这类泛化示例不会被改动。
#
#   版本号长度变化（如 2.1.0 -> 2.2.0-r1）会让示例输出的表格错位，因此替换后会
#   按原有列间距重新对齐受影响的表格代码块。
#
# 用法：
#   ./hack/update-operator-in-docs.sh <NEW_VERSION> <OLD_VERSION>
#
# 示例：
#   ./hack/update-operator-in-docs.sh 2.2.0-r1 2.1.0
#   ./hack/update-operator-in-docs.sh 2.2.0-r2 2.2.0-r1
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

# 版本格式校验：x.y.z，后面可带由字母、数字、点或连字符组成的后缀（如 -r1、-rc.0）
VERSION_REGEX='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'
if ! [[ "$NEW_VERSION" =~ $VERSION_REGEX ]]; then
    echo "Error: New version '$NEW_VERSION' does not match the expected operator version format." >&2
    exit 1
fi

if ! [[ "$OLD_VERSION" =~ $VERSION_REGEX ]]; then
    echo "Error: Old version '$OLD_VERSION' does not match the expected operator version format." >&2
    exit 1
fi

if [ "$NEW_VERSION" = "$OLD_VERSION" ]; then
    echo "Error: New version and old version are identical ('$NEW_VERSION')." >&2
    exit 1
fi

# 由版本号推断版本化订阅通道名（取主.次）
NEW_CHANNEL="stable-$(printf '%s' "$NEW_VERSION" | cut -d. -f1,2)"
OLD_CHANNEL="stable-$(printf '%s' "$OLD_VERSION" | cut -d. -f1,2)"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET_FILE="$REPO_ROOT/docs/en/installing/installing-service-mesh/install-mesh.mdx"
RELATIVE_TARGET_FILE=${TARGET_FILE#"$REPO_ROOT/"}

if [ ! -f "$TARGET_FILE" ]; then
    echo "Error: Target file '$TARGET_FILE' does not exist." >&2
    exit 1
fi

if ! command -v awk &> /dev/null; then
    echo "Error: 'awk' command not found." >&2
    exit 1
fi

echo "The servicemesh-operator2 versions to update are:"
echo "NEW_VERSION: $NEW_VERSION (channel: $NEW_CHANNEL)"
echo "OLD_VERSION: $OLD_VERSION (channel: $OLD_CHANNEL)"

TMP_FILE=$(mktemp)
SUMMARY_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE" "$SUMMARY_FILE"' EXIT

awk \
    -v OLD="$OLD_VERSION" \
    -v NEW="$NEW_VERSION" \
    -v OLD_CHANNEL="$OLD_CHANNEL" \
    -v NEW_CHANNEL="$NEW_CHANNEL" \
    -v SUMMARY="$SUMMARY_FILE" \
    '
# 判断字符是否为版本号边界（不属于版本号字面量的字符）
function is_boundary(c) {
    return (c == "" || c !~ /[0-9A-Za-z._-]/)
}

# 字面量替换：仅当匹配处两侧都是边界字符时才替换，
# 避免 servicemesh-operator2.v2.1.0 里的 2.1.0 被单独替换一次
function replace_token(s, from, to,    out, pos, from_len, before, after) {
    out = ""
    from_len = length(from)
    while ((pos = index(s, from)) > 0) {
        if (pos > 1) {
            before = substr(s, pos - 1, 1)
        } else if (length(out) > 0) {
            before = substr(out, length(out), 1)
        } else {
            before = ""
        }
        after = substr(s, pos + from_len, 1)
        if (is_boundary(before) && is_boundary(after)) {
            out = out substr(s, 1, pos - 1) to
        } else {
            out = out substr(s, 1, pos + from_len - 1)
        }
        s = substr(s, pos + from_len)
    }
    return out s
}

# 对一段文本执行三类替换；has_csv 表示所在行是否与 servicemesh-operator2 有关，
# 只有这样的行才替换裸版本号（示例输出中的 VERSION 列）
function apply_subs(s, has_csv,    out) {
    out = replace_token(s, "servicemesh-operator2.v" OLD, "servicemesh-operator2.v" NEW)
    if (has_csv) {
        out = replace_token(out, OLD, NEW)
    }
    if (OLD_CHANNEL != NEW_CHANNEL) {
        out = replace_token(out, OLD_CHANNEL, NEW_CHANNEL)
    }
    return out
}

function rtrim(s) {
    sub(/[ \t]+$/, "", s)
    return s
}

function trim(s) {
    sub(/^[ \t]+/, "", s)
    sub(/[ \t]+$/, "", s)
    return s
}

# 重新对齐 [first,last] 范围内的表格代码块。
# 列边界取自表头（第一行）中「两个及以上空格 + 非空格」的位置，因此空单元格
# （如 kubectl get csv 的 REPLACES 列）也能被正确切分。
# 任何一行只要在列边界处会切断内容，就判定为非表格并原样保留。
function realign(first, last,    i, c, r, indent, min_indent, prefix, text, col_count, offset,
                                 stripped, has_change, guard_ok, field, old_field,
                                 old_width, new_width, gutter, gap, row_has_csv, line_out, pad) {
    if (last - first < 1) {
        return
    }

    has_change = 0
    for (i = first; i <= last; i++) {
        if (i in changed) {
            has_change = 1
        }
    }
    if (!has_change) {
        return
    }

    # 统一去掉代码块的公共缩进
    min_indent = -1
    for (i = first; i <= last; i++) {
        if (trim(orig[i]) == "") {
            return
        }
        text = orig[i]
        indent = match(text, /[^ ]/) - 1
        if (min_indent < 0 || indent < min_indent) {
            min_indent = indent
        }
    }
    for (i = first; i <= last; i++) {
        stripped[i] = substr(orig[i], min_indent + 1)
    }

    # 解析表头列边界
    col_count = 1
    offset[1] = 1
    text = stripped[first]
    for (c = 3; c <= length(text); c++) {
        if (substr(text, c, 1) != " " && substr(text, c - 1, 1) == " " && substr(text, c - 2, 1) == " ") {
            col_count++
            offset[col_count] = c
        }
    }
    if (col_count < 2) {
        return
    }

    # 校验每一行都能在列边界处安全切分
    guard_ok = 1
    for (r = first; r <= last; r++) {
        if (substr(stripped[r], 1, 1) == " ") {
            guard_ok = 0
            break
        }
        for (c = 2; c <= col_count; c++) {
            if (length(stripped[r]) >= offset[c] && substr(stripped[r], offset[c] - 1, 1) != " ") {
                guard_ok = 0
                break
            }
        }
        if (!guard_ok) {
            break
        }
    }
    if (!guard_ok) {
        return
    }

    # 切分单元格并逐格替换，同时记录替换前后的列宽
    for (c = 1; c <= col_count; c++) {
        old_width[c] = 0
        new_width[c] = 0
    }
    for (r = first; r <= last; r++) {
        row_has_csv = (index(orig[r], "servicemesh-operator2") > 0)
        for (c = 1; c <= col_count; c++) {
            if (c < col_count) {
                old_field = trim(substr(stripped[r], offset[c], offset[c + 1] - offset[c]))
            } else {
                old_field = trim(substr(stripped[r], offset[c]))
            }
            field[r, c] = apply_subs(old_field, row_has_csv)
            if (length(old_field) > old_width[c]) {
                old_width[c] = length(old_field)
            }
            if (length(field[r, c]) > new_width[c]) {
                new_width[c] = length(field[r, c])
            }
        }
    }

    # 沿用原表格的列间距
    gutter = 0
    for (c = 1; c < col_count; c++) {
        gap = offset[c + 1] - offset[c] - old_width[c]
        if (gutter == 0 || gap < gutter) {
            gutter = gap
        }
    }
    if (gutter < 1) {
        gutter = 2
    }

    prefix = ""
    for (c = 1; c <= min_indent; c++) {
        prefix = prefix " "
    }
    for (r = first; r <= last; r++) {
        line_out = ""
        for (c = 1; c <= col_count; c++) {
            line_out = line_out field[r, c]
            if (c < col_count) {
                pad = new_width[c] + gutter - length(field[r, c])
                while (pad-- > 0) {
                    line_out = line_out " "
                }
            }
        }
        line[r] = rtrim(prefix line_out)
    }
    realigned_blocks++
}

{
    orig[NR] = $0
    line[NR] = $0
}

END {
    total = NR
    changed_lines = 0
    realigned_blocks = 0

    for (i = 1; i <= total; i++) {
        line[i] = apply_subs(orig[i], index(orig[i], "servicemesh-operator2") > 0)
        if (line[i] != orig[i]) {
            changed[i] = 1
            changed_lines++
        }
    }

    # 定位围栏代码块，对改动过的表格重新对齐
    in_block = 0
    block_start = 0
    for (i = 1; i <= total; i++) {
        text = orig[i]
        sub(/^[ \t]+/, "", text)
        if (substr(text, 1, 3) == "```") {
            if (in_block == 0) {
                in_block = 1
                block_start = i
            } else {
                in_block = 0
                realign(block_start + 1, i - 1)
            }
        }
    }

    for (i = 1; i <= total; i++) {
        print line[i]
    }

    printf("CHANGED_LINES=%d\nREALIGNED_BLOCKS=%d\n", changed_lines, realigned_blocks) > SUMMARY
}
' "$TARGET_FILE" > "$TMP_FILE"

# shellcheck source=/dev/null
. "$SUMMARY_FILE"

if [ "$CHANGED_LINES" -eq 0 ]; then
    echo "Updated 0 servicemesh-operator2 version references in $RELATIVE_TARGET_FILE."
    exit 0
fi

cat "$TMP_FILE" > "$TARGET_FILE"

echo "Updated $CHANGED_LINES lines (realigned $REALIGNED_BLOCKS example output tables) in $RELATIVE_TARGET_FILE."
