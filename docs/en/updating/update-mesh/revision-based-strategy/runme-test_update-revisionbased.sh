#!/usr/bin/env bash
# RevisionBased 更新策略文档测试脚本

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

test_update_revisionbased() {
    log_info "=========================================="
    log_info "开始 RevisionBased 更新策略测试"
    log_info "=========================================="

    local output REV NEW_REV i ps_cmd

    # ===== 安装 =====

    # 1. 创建命名空间
    log_info "步骤 1: 创建 istio-cni 和 istio-system 命名空间"
    _create_namespace_safe update-revisionbased:create-namespaces "istio-cni istio-system" || {
        log_error "创建命名空间失败"
        return 1
    }

    # 2. 安装 IstioCNI（YAML 代码块）
    log_info "步骤 2: 安装 IstioCNI"
    kubectl_apply_runme_block "update-revisionbased:create-istio-cni" "/tmp/" || {
        log_error "安装 IstioCNI 失败"
        return 1
    }

    # 3. 部署 Istio 控制面（RevisionBased 策略）
    log_info "步骤 3: 部署 Istio 控制面 (RevisionBased 策略)"
    kubectl_apply_runme_block "update-revisionbased:create-istio" "/tmp/" || {
        log_error "部署 Istio 控制面失败"
        return 1
    }

    # 4. 等待初始控制面就绪
    log_info "步骤 4: 等待 Istio 控制面就绪"
    kubectl wait --for=condition=Ready istio/default --timeout=5m || {
        log_error "等待 Istio 控制面就绪失败"
        return 1
    }

    # 5. 获取并验证 IstioRevision（输出含动态 AGE，使用 __cmp_lines）
    log_info "步骤 5: 获取 IstioRevision 名称"
    output=$(runme run update-revisionbased:get-istiorevision 2>&1)
    if ! __cmp_lines "$output" "$(cat <<EOF
+ default-v1-26-3
+ Healthy
+ v1.26.3
EOF
    )"; then
        log_error "IstioRevision 状态验证失败"
        log_error "实际输出: $output"
        return 1
    fi
    REV=$(echo "$output" | grep -oE 'default-v[0-9]+-[0-9]+-[0-9]+' | head -1 || true)
    if [ -z "$REV" ]; then
        log_error "无法解析 IstioRevision 名称"
        return 1
    fi
    log_success "IstioRevision: $REV"

    # 6. 创建 bookinfo 命名空间
    log_info "步骤 6: 创建 bookinfo 命名空间"
    _create_namespace_safe update-revisionbased:create-bookinfo-ns "bookinfo" || {
        log_error "创建 bookinfo 命名空间失败"
        return 1
    }

    # 7. 为 bookinfo 命名空间打 revision 标签（替换占位符 <revision_name>）
    log_info "步骤 7: 为 bookinfo 命名空间打 revision 标签 ($REV)"
    local label_cmd
    label_cmd=$(runme print update-revisionbased:label-bookinfo-ns)
    label_cmd="${label_cmd//<revision_name>/$REV}"
    eval "$label_cmd" || {
        log_error "为 bookinfo 命名空间打标签失败"
        return 1
    }

    # 8. 部署 bookinfo 应用
    log_info "步骤 8: 部署 bookinfo 应用"
    kubectl_apply_with_mirror update-revisionbased:deploy-bookinfo || {
        log_error "部署 bookinfo 应用失败"
        return 1
    }

    # 9. 等待 bookinfo deployments 就绪
    log_info "步骤 9: 等待 bookinfo deployments 就绪"
    _wait_for_deployment bookinfo details-v1
    _wait_for_deployment bookinfo productpage-v1
    _wait_for_deployment bookinfo ratings-v1
    _wait_for_deployment bookinfo reviews-v1
    _wait_for_deployment bookinfo reviews-v2
    _wait_for_deployment bookinfo reviews-v3
    log_success "所有 bookinfo deployments 已就绪"

    # 10. 检查 Istio 资源状态（安装后）
    log_info "步骤 10: 检查 Istio 资源状态（安装后）"
    output=$(runme run update-revisionbased:get-istio-install 2>&1)
    if ! __cmp_lines "$output" "$(cat <<EOF
+ default-v1-26-3
+ Healthy
+ v1.26.3
EOF
    )"; then
        log_error "Istio 资源状态验证失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "Istio 资源状态验证通过（安装后）"

    # 11. 验证 sidecar 代理版本与控制面一致（安装后）
    log_info "步骤 11: 验证 sidecar 代理状态（安装后）"
    ps_cmd=$(runme print update-revisionbased:verify-proxy-install)
    ps_cmd="${ps_cmd//<revision_name>/$REV}"
    output=$(eval "$ps_cmd" 2>&1)
    if ! __cmp_lines "$output" "$(cat <<EOF
+ 1.26.3
+ details-v1
+ productpage-v1
+ ratings-v1
+ reviews-v1
+ reviews-v2
+ reviews-v3
EOF
    )"; then
        log_error "sidecar 代理状态验证失败（安装后）"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "sidecar 代理状态验证通过（安装后）"

    # ===== 更新 =====

    # 12. 更新 Istio 版本至 v1.28.6
    log_info "步骤 12: 更新 Istio 版本至 v1.28.6"
    runme run update-revisionbased:patch-istio-version || {
        log_error "更新 Istio 版本失败"
        return 1
    }

    # 13. 解析新 revision 名称并等待新控制面就绪
    log_info "步骤 13: 等待新版本控制面就绪"
    for i in $(seq 1 12); do
        NEW_REV=$(runme run update-revisionbased:get-istiorevision-update 2>&1 \
            | grep 'v1.28.6' | grep -oE 'default-v[0-9]+-[0-9]+-[0-9]+' | head -1 || true)
        [ -n "$NEW_REV" ] && break
        sleep 5
    done
    if [ -z "$NEW_REV" ]; then
        log_error "无法解析新 IstioRevision 名称"
        return 1
    fi
    log_info "新 IstioRevision: $NEW_REV"
    _wait_for_deployment istio-system "istiod-$NEW_REV"

    # 14. 确认 Istio 资源已就绪（新版本）
    log_info "步骤 14: 确认 Istio 资源就绪（新版本）"
    output=$(runme run update-revisionbased:get-istio-update 2>&1)
    if ! __cmp_lines "$output" "$(cat <<EOF
+ default-v1-28-6
+ Healthy
+ v1.28.6
EOF
    )"; then
        log_error "Istio 更新状态验证失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "Istio 更新状态验证通过"

    # 15. 确认新旧 IstioRevision 并存
    log_info "步骤 15: 确认新旧 IstioRevision 并存"
    output=$(runme run update-revisionbased:get-istiorevision-update 2>&1)
    if ! __cmp_lines "$output" "$(cat <<EOF
+ default-v1-26-3
+ default-v1-28-6
+ v1.26.3
+ v1.28.6
EOF
    )"; then
        log_error "新旧 IstioRevision 并存验证失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "新旧 IstioRevision 并存验证通过"

    # 16. 确认两个控制面 Pod 并存
    log_info "步骤 16: 确认两个控制面 Pod 并存"
    output=$(runme run update-revisionbased:get-pods-update 2>&1)
    if ! __cmp_lines "$output" "$(cat <<EOF
+ istiod-default-v1-26-3
+ istiod-default-v1-28-6
+ Running
EOF
    )"; then
        log_error "控制面 Pod 验证失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "两个控制面 Pod 验证通过"

    # 17. 确认 sidecar 仍连接旧控制面
    log_info "步骤 17: 确认 sidecar 仍连接旧控制面"
    ps_cmd=$(runme print update-revisionbased:verify-proxy-old)
    ps_cmd="${ps_cmd//<revision_name>/$REV}"
    output=$(eval "$ps_cmd" 2>&1)
    if ! __cmp_lines "$output" "$(cat <<EOF
+ 1.26.3
+ details-v1
+ productpage-v1
+ ratings-v1
+ reviews-v1
+ reviews-v2
+ reviews-v3
EOF
    )"; then
        log_error "旧控制面 sidecar 验证失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "sidecar 仍连接旧控制面，验证通过"

    # 18. 迁移工作负载到新 revision（替换占位符 <new_revision_name>）
    log_info "步骤 18: 迁移 bookinfo 工作负载到新 revision ($NEW_REV)"
    local migrate_cmd
    migrate_cmd=$(runme print update-revisionbased:migrate-workloads)
    migrate_cmd="${migrate_cmd//<new_revision_name>/$NEW_REV}"
    eval "$migrate_cmd" || {
        log_error "迁移工作负载失败"
        return 1
    }

    # 19. 重启应用工作负载
    log_info "步骤 19: 重启 bookinfo 工作负载"
    runme run update-revisionbased:restart-workloads || {
        log_error "重启工作负载失败"
        return 1
    }

    # 20. 等待 bookinfo deployments 就绪（重启后）
    log_info "步骤 20: 等待 bookinfo deployments 就绪（重启后）"
    _wait_for_deployment bookinfo details-v1
    _wait_for_deployment bookinfo productpage-v1
    _wait_for_deployment bookinfo ratings-v1
    _wait_for_deployment bookinfo reviews-v1
    _wait_for_deployment bookinfo reviews-v2
    _wait_for_deployment bookinfo reviews-v3
    log_success "所有 bookinfo deployments 已就绪（重启后）"

    # ===== 验证 =====

    # 21. 验证 sidecar 已切换到新版本
    log_info "步骤 21: 验证 sidecar 已切换到新版本"
    ps_cmd=$(runme print update-revisionbased:verify-proxy-new)
    ps_cmd="${ps_cmd//<new_revision_name>/$NEW_REV}"
    output=$(eval "$ps_cmd" 2>&1)
    if ! __cmp_lines "$output" "$(cat <<EOF
+ 1.28.6
+ details-v1
+ productpage-v1
+ ratings-v1
+ reviews-v1
+ reviews-v2
+ reviews-v3
EOF
    )"; then
        log_error "新版本 sidecar 验证失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "新版本 sidecar 验证通过"

    # 22. 等待旧 revision 及其控制面被回收（grace period 默认 30s）
    log_info "步骤 22: 等待旧 revision ($REV) 被回收"
    retry_command "! kubectl get istiorevision 2>/dev/null | grep -q '$REV'" 20 5 || {
        log_error "旧 revision 未在预期时间内被回收"
        return 1
    }

    # 23. 验证旧控制面 Pod 已删除
    log_info "步骤 23: 验证旧控制面 Pod 已删除"
    output=$(runme run update-revisionbased:verify-pods 2>&1)
    if ! __cmp_lines "$output" "$(cat <<EOF
+ istiod-$NEW_REV
- istiod-$REV
EOF
    )"; then
        log_error "旧控制面 Pod 删除验证失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "旧控制面 Pod 已删除，验证通过"

    # 24. 检查 Istio 资源
    log_info "步骤 24: 检查 Istio 资源"
    runme run update-revisionbased:verify-istio || {
        log_error "检查 Istio 资源失败"
        return 1
    }

    # 25. 验证旧 IstioRevision 已删除
    log_info "步骤 25: 验证旧 IstioRevision 已删除"
    output=$(runme run update-revisionbased:verify-istiorevision 2>&1)
    if ! __cmp_lines "$output" "$(cat <<EOF
+ $NEW_REV
- $REV
EOF
    )"; then
        log_error "旧 IstioRevision 删除验证失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "旧 IstioRevision 已删除，验证通过"

    log_success "=========================================="
    log_success "RevisionBased 更新策略测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源
cleanup_update_revisionbased() {
    log_info "=========================================="
    log_info "清理 RevisionBased 更新策略测试资源"
    log_info "=========================================="

    runme run update-revisionbased:cleanup || {
        log_error "清理资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
