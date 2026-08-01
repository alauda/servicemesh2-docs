#!/usr/bin/env bash
# Ambient 模式组件升级文档测试脚本
# 流程：铺垫安装 v1.28.6 ambient 环境（Istio/IstioCNI/ZTunnel + bookinfo）
#       → 按 控制面 → IstioCNI → ZTunnel 顺序升级到 v1.30.3 → 验证工作负载
# 清理：cleanup 函数执行文档 update-ambient:cleanup 块（含 bookinfo 与三组件回收）

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# runme 命令可以在项目的任意目录中执行

test_updating_ambient_components() {
    log_info "=========================================="
    log_info "开始 Ambient 模式组件升级测试"
    log_info "=========================================="

    local output

    # ==========================================
    # Section 1: 铺垫安装（pin v1.28.6 的 ambient 环境）
    # ==========================================

    # 1. 创建 istio-cni / istio-system / ztunnel 命名空间并打 istio-discovery 标签
    log_info "步骤 1: 创建 istio-cni / istio-system / ztunnel 命名空间"
    _create_namespace_safe update-ambient:create-namespaces "istio-cni istio-system ztunnel" || {
        log_error "创建命名空间失败"
        return 1
    }

    # 2. 安装 IstioCNI v1.28.6（YAML heredoc 代码块，使用 kubectl_apply_runme_block）
    log_info "步骤 2: 安装 IstioCNI v1.28.6 (ambient profile)"
    kubectl_apply_runme_block "update-ambient:create-istio-cni" "/tmp/" || {
        log_error "安装 IstioCNI 失败"
        return 1
    }

    # 3. 等待 IstioCNI 就绪
    log_info "步骤 3: 等待 IstioCNI 就绪"
    runme run update-ambient:wait-istiocni-install || {
        log_error "等待 IstioCNI 就绪失败"
        return 1
    }

    # 4. 安装 Istio 控制面 v1.28.6
    log_info "步骤 4: 安装 Istio 控制面 v1.28.6 (ambient profile, InPlace)"
    kubectl_apply_runme_block "update-ambient:create-istio" "/tmp/" || {
        log_error "安装 Istio 控制面失败"
        return 1
    }

    # 5. 等待 Istio 控制面就绪
    log_info "步骤 5: 等待 Istio 控制面就绪"
    runme run update-ambient:wait-istio-install || {
        log_error "等待 Istio 控制面就绪失败"
        return 1
    }

    # 6. 安装 ZTunnel v1.28.6
    log_info "步骤 6: 安装 ZTunnel v1.28.6"
    kubectl_apply_runme_block "update-ambient:create-ztunnel" "/tmp/" || {
        log_error "安装 ZTunnel 失败"
        return 1
    }

    # 7. 等待 ZTunnel 就绪
    log_info "步骤 7: 等待 ZTunnel 就绪"
    runme run update-ambient:wait-ztunnel-install || {
        log_error "等待 ZTunnel 就绪失败"
        return 1
    }

    # 8. 创建 bookinfo 命名空间并打 istio-discovery 标签
    log_info "步骤 8: 创建 bookinfo 命名空间"
    _create_namespace_safe update-ambient:create-bookinfo-ns "bookinfo" || {
        log_error "创建 bookinfo 命名空间失败"
        return 1
    }

    # 9. 部署 bookinfo 应用（镜像加速）
    log_info "步骤 9: 部署 bookinfo 应用"
    kubectl_apply_with_mirror update-ambient:deploy-bookinfo || {
        log_error "部署 bookinfo 应用失败"
        return 1
    }

    # 10. 部署 bookinfo-versions
    log_info "步骤 10: 部署 bookinfo-versions"
    kubectl_apply_with_mirror update-ambient:deploy-bookinfo-versions || {
        log_error "部署 bookinfo-versions 失败"
        return 1
    }

    # 11. 等待 bookinfo deployments 就绪（文档无显式等待步骤，脚本兜底）
    log_info "步骤 11: 等待 bookinfo deployments 就绪"
    _wait_for_deployment bookinfo details-v1
    _wait_for_deployment bookinfo productpage-v1
    _wait_for_deployment bookinfo ratings-v1
    _wait_for_deployment bookinfo reviews-v1
    _wait_for_deployment bookinfo reviews-v2
    _wait_for_deployment bookinfo reviews-v3
    log_success "所有 bookinfo deployments 已就绪"

    # 12. 将 bookinfo 命名空间纳入 ambient 网格
    log_info "步骤 12: 将 bookinfo 命名空间纳入 ambient 网格"
    runme run update-ambient:enroll-bookinfo || {
        log_error "纳入 ambient 网格失败"
        return 1
    }

    # (可选) 纳入 ambient 网格后生成 bookinfo 请求流量（仅 AUTO_GEN_BOOKINFO_TRAFFIC=true）
    # ambient 模式数据面为 per-node ztunnel，组件升级不会重启 bookinfo 应用 pod，故无需重启后重新生成
    maybe_gen_bookinfo_traffic

    # ==========================================
    # Section 2: 升级 Istio 控制面 → v1.30.3
    # ==========================================

    # 13. 升级控制面版本
    log_info "步骤 13: 升级 Istio 控制面版本至 v1.30.3"
    runme run update-ambient:patch-istio-version || {
        log_error "升级 Istio 控制面版本失败"
        return 1
    }
    sleep 5  # 等待 operator 开始 reconcile

    # 14. 等待控制面就绪
    log_info "步骤 14: 等待升级后的控制面就绪"
    runme run update-ambient:wait-istio-update || {
        log_error "等待升级后的控制面就绪失败"
        return 1
    }

    # 15. 验证控制面版本（输出含动态 AGE 值，使用 __cmp_lines 验证关键字段）
    log_info "步骤 15: 验证控制面已升级到 v1.30.3"
    output=$(runme run update-ambient:get-istio-update 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ default
+ ambient
+ Healthy
+ v1.30.3
EOF
    )"; then
        log_error "验证控制面版本失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "控制面版本验证通过 (v1.30.3)"

    # ==========================================
    # Section 3: 升级 IstioCNI → v1.30.3
    # ==========================================

    # 16. 升级 IstioCNI 版本
    log_info "步骤 16: 升级 IstioCNI 版本至 v1.30.3"
    runme run update-ambient:patch-istiocni-version || {
        log_error "升级 IstioCNI 版本失败"
        return 1
    }
    sleep 5  # 等待 operator 改写 DaemonSet 模板

    # 17. 观察 istio-cni-node DaemonSet 滚动
    log_info "步骤 17: 观察 istio-cni-node DaemonSet 滚动"
    runme run update-ambient:rollout-istiocni || {
        log_error "istio-cni-node DaemonSet 滚动失败"
        return 1
    }

    # 18. 等待 IstioCNI Ready
    log_info "步骤 18: 等待 IstioCNI 资源 Ready"
    runme run update-ambient:wait-istiocni-update || {
        log_error "等待 IstioCNI Ready 失败"
        return 1
    }

    # 19. 验证 IstioCNI 版本（输出含动态 AGE 值，使用 __cmp_lines 验证关键字段）
    log_info "步骤 19: 验证 IstioCNI 已升级到 v1.30.3"
    output=$(runme run update-ambient:get-istiocni-update 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ default
+ istio-cni
+ True
+ Healthy
+ v1.30.3
EOF
    )"; then
        log_error "验证 IstioCNI 版本失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "IstioCNI 版本验证通过 (v1.30.3)"

    # ==========================================
    # Section 4: 升级 ZTunnel → v1.30.3
    # ==========================================

    # 20. 升级 ZTunnel 版本
    log_info "步骤 20: 升级 ZTunnel 版本至 v1.30.3"
    runme run update-ambient:patch-ztunnel-version || {
        log_error "升级 ZTunnel 版本失败"
        return 1
    }
    sleep 5  # 等待 operator 改写 DaemonSet 模板

    # 21. 观察 ztunnel DaemonSet 逐节点滚动
    log_info "步骤 21: 观察 ztunnel DaemonSet 滚动"
    runme run update-ambient:rollout-ztunnel || {
        log_error "ztunnel DaemonSet 滚动失败"
        return 1
    }

    # 22. 等待 ZTunnel Ready
    log_info "步骤 22: 等待 ZTunnel 资源 Ready"
    runme run update-ambient:wait-ztunnel-update || {
        log_error "等待 ZTunnel Ready 失败"
        return 1
    }

    # 23. 验证 ZTunnel 版本（输出含动态 AGE 值，使用 __cmp_lines 验证关键字段）
    log_info "步骤 23: 验证 ZTunnel 已升级到 v1.30.3"
    output=$(runme run update-ambient:get-ztunnel-update 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ default
+ ztunnel
+ True
+ Healthy
+ v1.30.3
EOF
    )"; then
        log_error "验证 ZTunnel 版本失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "ZTunnel 版本验证通过 (v1.30.3)"

    # 24. 验证 ztunnel pods（输出含动态 pod 名/IP/AGE，使用 __cmp_lines 验证关键字段）
    log_info "步骤 24: 验证 ztunnel pods 运行状态"
    output=$(runme run update-ambient:get-ztunnel-pods 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ ztunnel-
+ 1/1
+ Running
EOF
    )"; then
        log_error "验证 ztunnel pods 失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "ztunnel pods 验证通过"

    # ==========================================
    # Section 5: 验证 ambient 工作负载
    # ==========================================

    # 25. 验证 bookinfo pods 运行状态（输出含动态 pod 名后缀和 AGE，使用 __cmp_lines）
    log_info "步骤 25: 验证 bookinfo pods 运行状态"
    output=$(runme run update-ambient:verify-bookinfo-pods 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ details-v1
+ productpage-v1
+ ratings-v1
+ reviews-v1
+ reviews-v2
+ reviews-v3
+ Running
EOF
    )"; then
        log_error "验证 bookinfo pods 失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "bookinfo pods 验证通过"

    # 26. 验证 ztunnel 仍代理工作负载（HBONE 协议；输出含动态 IP/pod 名，使用 __cmp_lines）
    log_info "步骤 26: 验证 ztunnel workloads (HBONE)"
    output=$(runme run update-ambient:verify-ztunnel-workloads 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ bookinfo
+ details-v1
+ productpage-v1
+ ratings-v1
+ reviews-v1
+ reviews-v2
+ reviews-v3
+ HBONE
EOF
    )"; then
        log_error "验证 ztunnel workloads 失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "ztunnel workloads 验证通过 (HBONE)"

    # 27. 验证网格内连通性
    log_info "步骤 27: 验证网格内连通性"
    local conn_output conn_expected
    conn_output=$(runme run update-ambient:verify-connectivity 2>&1)
    conn_expected=$(runme print update-ambient:verify-connectivity-output)

    if ! __cmp_contains "$conn_output" "$conn_expected"; then
        log_error "网格连通性验证失败"
        log_error "期待输出: $conn_expected"
        log_error "实际输出: $conn_output"
        return 1
    fi
    log_success "网格连通性验证通过"

    # ==========================================
    # Section 6: 升级后 Kiali tracing 配置（use_waypoint_name）
    # ==========================================
    # Istio 1.30 起 waypoint 将所有 span 上报在自身服务名 waypoint.<ns> 下，
    # Kiali 必须开启 use_waypoint_name 才能查到 ambient 工作负载的调用链。
    # 文档该步骤以"已安装 Kiali 并集成 tracing"为前提；本测试流程不安装 Kiali，
    # 故先守卫 Kiali CR 是否存在（参照 runme-test_kiali.sh 对 jaeger 的守卫方式），
    # 不存在时跳过，避免 patch 不存在的资源导致误报失败。

    # 28. 开启 use_waypoint_name（仅在 istio-system/kiali CR 存在时执行）
    if kubectl -nistio-system get kiali kiali >/dev/null 2>&1; then
        log_info "步骤 28: 开启 Kiali use_waypoint_name"
        local kiali_patch_output kiali_patch_expected
        kiali_patch_output=$(runme run update-ambient:enable-kiali-waypoint-tracing 2>&1) || {
            log_error "开启 use_waypoint_name 失败"
            log_error "输出: $kiali_patch_output"
            return 1
        }
        kiali_patch_expected=$(runme print update-ambient:enable-kiali-waypoint-tracing-output)
        if ! __cmp_contains "$kiali_patch_output" "$kiali_patch_expected"; then
            log_error "开启 use_waypoint_name 输出验证失败"
            log_error "期待输出: $kiali_patch_expected"
            log_error "实际输出: $kiali_patch_output"
            return 1
        fi
        log_success "use_waypoint_name 已开启"

        # 29. 等待 Kiali Operator 调和并滚动重启 Kiali
        log_info "步骤 29: 等待 Kiali CR 就绪与 Deployment 滚动完成"
        runme run update-ambient:wait-kiali-waypoint-tracing || {
            log_error "等待 Kiali 调和/滚动失败"
            return 1
        }
        log_success "Kiali tracing 配置更新完成"
    else
        log_warn "未检测到 istio-system/kiali CR，跳过 Kiali use_waypoint_name 配置步骤"
    fi

    log_success "=========================================="
    log_success "Ambient 模式组件升级测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# cleanup 函数：清理测试资源（bookinfo + 三组件 CR + 三命名空间）
cleanup_updating_ambient_components() {
    log_info "=========================================="
    log_info "清理 Ambient 模式组件升级测试资源"
    log_info "=========================================="

    runme run update-ambient:cleanup || {
        log_error "清理资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
