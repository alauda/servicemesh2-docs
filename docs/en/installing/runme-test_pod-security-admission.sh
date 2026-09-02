#!/usr/bin/env bash
# Pod Security Admission 文档测试脚本
#
# 覆盖 pod-security-admission.mdx 的「Gateway API gateways and waypoint proxies」章节：
# 给 Istio 资源打 gatewayClasses overlay，使 Gateway API 网关与 waypoint 的 pod
# 携带 RuntimeDefault seccomp profile，从而能被 Restricted PSA 命名空间准入。
#
# 说明：
#   - 「Injected sidecars」章节只有一段示意性的 Istio CR 片段（无 name），
#     其配置由 install-mesh 文档的 Istio CR 承载并测试，本脚本不重复覆盖。
#   - overlay 是集群级期望状态，文档未给清理步骤，故本脚本无 cleanup 函数。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# runme 命令可以在项目的任意目录中执行

test_pod_security_admission() {
    log_info "=========================================="
    log_info "开始 Pod Security Admission 测试"
    log_info "=========================================="

    # 步骤 1: 为 istio 网关类打 seccompProfile overlay
    log_info "步骤 1: 为 istio 网关类打 seccompProfile overlay"
    runme run psa:patch-gatewayclass-istio || {
        log_error "配置 istio 网关类 seccompProfile 失败"
        return 1
    }

    # 步骤 2: 为 istio-waypoint 网关类打 seccompProfile overlay
    log_info "步骤 2: 为 istio-waypoint 网关类打 seccompProfile overlay"
    runme run psa:patch-gatewayclass-waypoint || {
        log_error "配置 istio-waypoint 网关类 seccompProfile 失败"
        return 1
    }

    # 步骤 3: 验证控制面为两个网关类各生成了一个 ConfigMap
    # 期望名称取自文档的示例输出块（跳过表头、只取 NAME 列），保持与文档同一事实源；
    # 实际输出的 AGE 列是动态的，故同样只比对 NAME 列，且用 grep -qx 做整行精确匹配——
    # istio-default-gatewayclass-istio 是 ...-istio-waypoint 的前缀，子串匹配会误判
    log_info "步骤 3: 验证网关类 ConfigMap 已生成"
    local expected_names
    expected_names=$(runme print psa:verify-gatewayclass-configmaps-output | awk 'NR > 1 && NF { print $1 }')
    if [ -z "$expected_names" ]; then
        log_error "无法从文档示例输出块解析期望的 ConfigMap 名称"
        return 1
    fi

    # 注: `kubectl get configmap -l ...` 无匹配时打印 "No resources found" 但仍退出 0，
    #     不能用 retry_command 重试命令本身，须按断言结果自行轮询；
    #     ConfigMap 由 istiod 重新渲染后才出现，故给足重试次数
    local cm_output="" missing="" name attempt
    for ((attempt = 1; attempt <= 12; attempt++)); do
        cm_output=$(runme run psa:verify-gatewayclass-configmaps 2>&1)
        missing=""
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            printf '%s\n' "$cm_output" | awk 'NR > 1 && NF { print $1 }' | grep -qx "$name" \
                || missing="$missing $name"
        done <<< "$expected_names"
        [ -z "$missing" ] && break
        if [ "$attempt" -lt 12 ]; then sleep 5; fi
    done
    if [ -n "$missing" ]; then
        log_error "网关类 ConfigMap 验证失败，缺少:$missing"
        log_error "实际输出: $cm_output"
        return 1
    fi
    log_success "istio 与 istio-waypoint 网关类的 ConfigMap 均已生成"

    log_success "=========================================="
    log_success "Pod Security Admission 测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
