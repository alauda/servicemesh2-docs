#!/usr/bin/env bash
# 使用固定副本数配置 Istio 高可用文档测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

_wait_for_istiod_pods_ready() {
    local block_name="$1"
    local min_pod_count="$2"
    local max_retries="${3:-18}"
    local interval="${4:-10}"
    local attempt output pod_count running_count

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        output=$(runme run "$block_name" 2>&1 || true)
        pod_count=$(printf '%s\n' "$output" | awk '/^istiod-/{count++} END{print count+0}')
        running_count=$(printf '%s\n' "$output" | awk '/^istiod-/ && /Running/{count++} END{print count+0}')

        if [ "$pod_count" -ge "$min_pod_count" ] && [ "$running_count" -ge "$min_pod_count" ]; then
            return 0
        fi

        if [ "$attempt" -lt "$max_retries" ]; then
            log_warn "istiod Pod 尚未全部就绪，${interval} 秒后重试 (${attempt}/${max_retries})"
            sleep "$interval"
        fi
    done

    return 1
}

test_configuring_istio_ha_by_using_replica_count() {
    log_info "=========================================="
    log_info "开始使用固定副本数配置 Istio 高可用测试"
    log_info "=========================================="

    # 1. 校验 Web 控制台示例 YAML
    log_info "步骤 1: 校验 Web 控制台示例 YAML"
    local console_yaml
    console_yaml=$(runme print istio-ha-replica-count:console-yaml 2>&1) || {
        log_error "获取示例 YAML 失败"
        log_error "输出: $console_yaml"
        return 1
    }

    if ! __cmp_lines "$console_yaml" "$(cat <<'EOF'
+ autoscaleEnabled: false
+ replicaCount: 2
EOF
    )"; then
        log_error "示例 YAML 校验失败"
        log_error "实际输出: $console_yaml"
        return 1
    fi
    log_success "示例 YAML 校验通过"

    # 2. 获取 Istio 资源名称并校验输出
    log_info "步骤 2: 获取 Istio 资源名称"
    local istio_output expected_istio_output expected_name expected_namespace expected_status expected_version istio_name
    istio_output=$(runme run istio-ha-replica-count:get-istio 2>&1) || {
        log_error "获取 Istio 资源失败"
        log_error "输出: $istio_output"
        return 1
    }
    expected_istio_output=$(runme print istio-ha-replica-count:get-istio-output 2>&1) || {
        log_error "获取预期输出失败"
        log_error "输出: $expected_istio_output"
        return 1
    }
    expected_name=$(echo "$expected_istio_output" | awk 'NR==2 {print $1}')
    expected_namespace=$(echo "$expected_istio_output" | awk 'NR==2 {print $2}')
    expected_status=$(echo "$expected_istio_output" | awk 'NR==2 {print $(NF-2)}')
    expected_version=$(echo "$expected_istio_output" | awk 'NR==2 {print $(NF-1)}')

    if ! __cmp_lines "$istio_output" "$(cat <<EOF
+ NAME
+ ${expected_name}
+ ${expected_namespace}
+ ${expected_status}
+ ${expected_version}
EOF
    )"; then
        log_error "Istio 资源输出校验失败"
        log_error "实际输出: $istio_output"
        return 1
    }

    istio_name=$(echo "$istio_output" | awk 'NR==2 {print $1}')
    if [ -z "$istio_name" ]; then
        log_error "无法解析 Istio 资源名称"
        return 1
    fi
    log_success "Istio 资源输出校验通过，资源名为: $istio_name"

    # 3. 执行 patch 命令
    log_info "步骤 3: 为 Istio 控制面设置固定副本数"
    local patch_output
    patch_output=$(runme run istio-ha-replica-count:patch-istio 2>&1) || {
        log_error "执行 patch 失败"
        log_error "输出: $patch_output"
        return 1
    }
    log_success "Patch 执行成功"

    # 4. 等待 Istio 控制面达到预期副本数
    log_info "步骤 4: 等待至少 2 个 istiod Pod 就绪"
    local expected_verify_output expected_pod_count
    expected_verify_output=$(runme print istio-ha-replica-count:verify-istiod-pods-output 2>&1) || {
        log_error "获取验证预期输出失败"
        log_error "输出: $expected_verify_output"
        return 1
    }
    expected_pod_count=$(printf '%s\n' "$expected_verify_output" | awk '/^istiod-/{count++} END{print count+0}')
    if [ "$expected_pod_count" -lt 2 ]; then
        log_error "验证输出中的预期 Pod 数异常: $expected_pod_count"
        return 1
    fi

    if ! _wait_for_istiod_pods_ready "istio-ha-replica-count:verify-istiod-pods" "$expected_pod_count"; then
        log_error "等待 istiod Pod 就绪超时"
        return 1
    fi
    log_success "istiod Pod 已达到预期副本数"

    # 5. 校验验证步骤输出
    log_info "步骤 5: 校验 istiod Pod 状态"
    local verify_output actual_pod_count
    verify_output=$(runme run istio-ha-replica-count:verify-istiod-pods 2>&1) || {
        log_error "查询 istiod Pod 状态失败"
        log_error "输出: $verify_output"
        return 1
    }

    if ! __cmp_lines "$verify_output" "$(cat <<'EOF'
+ NAME
+ READY
+ STATUS
+ 1/1
+ Running
EOF
    )"; then
        log_error "istiod Pod 状态校验失败"
        log_error "实际输出: $verify_output"
        return 1
    fi

    actual_pod_count=$(printf '%s\n' "$verify_output" | awk '/^istiod-/{count++} END{print count+0}')
    if [ "$actual_pod_count" -lt "$expected_pod_count" ]; then
        log_error "istiod Pod 数量不足"
        log_error "预期至少: $expected_pod_count"
        log_error "实际数量: $actual_pod_count"
        log_error "实际输出: $verify_output"
        return 1
    fi
    log_success "istiod Pod 状态校验通过"

    log_success "=========================================="
    log_success "使用固定副本数配置 Istio 高可用测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
