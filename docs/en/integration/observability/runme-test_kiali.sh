#!/usr/bin/env bash
# Kiali 文档测试脚本
# 测试范围：Installing via the CLI 和 Configuring Monitoring with Kiali

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
source "$FRAMEWORK_ROOT/projects/mesh/project.sh"

# runme 命令可以在项目的任意目录中执行

test_kiali() {
    log_info "=========================================="
    log_info "开始 Kiali 文档测试"
    log_info "=========================================="
    
    log_info "开始安装 Kiali Operator"
    # 使用通用 install_operator 函数安装 kiali-operator
    install_operator \
        "kiali-operator" \
        "kiali-operator" \
        "$PKG_KIALI_OPERATOR_URL" \
        "install-kiali"
    log_success "Kiali Operator 安装测试完成"

    log_info "=========================================="
    log_info "开始配置 Kiali 与监控集成"
    log_info "=========================================="

    # 检查 PLATFORM_CA 环境变量
    # 正常情况下由 run.sh 在 kubeconfig 就绪后从 Global 集群自动注入；
    # 此处仍做一次防御性检查，避免直接 source 该脚本的场景下误报到下游。
    if [ -z "$PLATFORM_CA" ]; then
        log_error "PLATFORM_CA 未设置（应由 run.sh 自动获取或显式 export）"
        return 1
    fi
    log_success "PLATFORM_CA 已就绪"

    # 1. 获取平台配置
    log_info "步骤 1: 获取平台配置"
    # 使用 eval 执行 runme print 的内容，以便在当前 shell 中设置环境变量
    eval "$(runme print config-kiali:get-platform-config)" || {
        log_error "获取平台配置失败"
        return 1
    }

    # 验证必要的环境变量
    if [ -z "$PLATFORM_URL" ] || [ -z "$CLUSTER_NAME" ] || [ -z "$OIDC_CLIENT_SECRET" ]; then
        log_error "无法获取必要的平台配置"
        log_error "PLATFORM_URL: $PLATFORM_URL"
        log_error "CLUSTER_NAME: $CLUSTER_NAME"
        return 1
    fi
    log_success "平台配置获取成功"
    log_info "PLATFORM_URL: $PLATFORM_URL"
    log_info "CLUSTER_NAME: $CLUSTER_NAME"

    local output expected
    # 2. 创建 kiali secret
    log_info "步骤 2: 创建 kiali Secret"
    kubectl -n istio-system delete secret kiali --ignore-not-found=true
    
    output=$(runme run config-kiali:create-secret-kiali)
    expected=$(runme print config-kiali:create-secret-kiali-output)
    if ! __cmp_contains "$output" "$expected"; then
        log_error "创建 kiali Secret 失败"
        log_error "期待输出: $expected"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "kiali Secret 创建成功"

    # 3. 创建 monitoring basic auth secret
    log_info "步骤 3: 创建 kiali-monitoring-basic-auth Secret"
    kubectl -n istio-system delete secret kiali-monitoring-basic-auth --ignore-not-found=true
    
    output=$(runme run config-kiali:create-secret-monitoring-basic-auth)
    expected=$(runme print config-kiali:create-secret-monitoring-basic-auth-output)
    if ! __cmp_contains "$output" "$expected"; then
        log_error "创建 kiali-monitoring-basic-auth Secret 失败"
        log_error "期待输出: $expected"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "kiali-monitoring-basic-auth Secret 创建成功"

    # 4. Label istio-system namespace with project label
    log_info "步骤 4: Label istio-system namespace with project label"
    runme run config-kiali:label-istio-system-project-label || {
        log_error "Label istio-system namespace 失败"
        return 1
    }
    log_success "istio-system namespace 已打项目标签"

    # 5. 生成 kiali.yaml 文件
    log_info "步骤 5: 生成 kiali.yaml 文件"
    runme print config-kiali:kiali-yaml > "/tmp/kiali.yaml" || {
        log_error "获取 kiali.yaml 模板失败"
        return 1
    }
    log_success "kiali.yaml 文件生成成功"

    # 6. 应用 Kiali 配置
    log_info "步骤 6: 应用 Kiali 配置"
    kubectl_apply_runme_block "config-kiali:apply-kiali" "/tmp/" || {
        log_error "应用 Kiali 配置失败"
        return 1
    }
    log_success "Kiali 配置应用成功"

    # 7. 等待 Kiali CR 就绪
    log_info "步骤 7: 等待 Kiali CR 就绪"
    kubectl -nistio-system wait --for=condition=Successful kiali/kiali --timeout=3m || {
        log_warn "等待 Kiali CR 就绪超时，继续执行..."
    }

    log_info "等待 Kiali Deployment 就绪"
    _wait_for_deployment istio-system kiali || {
        log_error "等待 Kiali Deployment 就绪超时"
        return 1
    }

    # 组合 Kiali 访问地址
    log_info "Kiali 访问地址: $PLATFORM_URL/clusters/$CLUSTER_NAME/kiali"

    log_success "Kiali 配置测试完成"

    # ==========================================================================
    # 调用链集成配置（仅在 jaeger-system/jaeger-collector svc 存在时执行）
    # ==========================================================================
    log_info "=========================================="
    log_info "检查是否启用 Kiali 调用链集成"
    log_info "=========================================="

    if ! kubectl -n jaeger-system get svc jaeger-collector >/dev/null 2>&1; then
        log_warn "未检测到 jaeger-system/jaeger-collector，跳过 Kiali 调用链集成测试"
        log_success "=========================================="
        log_success "Kiali 文档测试完成（未启用调用链集成）"
        log_success "=========================================="
        return 0
    fi
    log_info "检测到 jaeger-collector svc，继续执行调用链集成测试"

    # 步骤 8: 计算 external_url
    # 沿用 install-tracing:set-jaeger-defaults 中的 JAEGER_BASEPATH 约定：
    #   JAEGER_BASEPATH="/clusters/${CLUSTER_NAME}/jaeger"
    local jaeger_basepath="/clusters/${CLUSTER_NAME}/jaeger"
    local external_url="${PLATFORM_URL}${jaeger_basepath}"
    log_info "步骤 8: external_url = $external_url"

    # 步骤 9: 获取调用链集成 YAML 模板
    log_info "步骤 9: 获取 config-kiali:tracing-yaml 模板"
    runme print config-kiali:tracing-yaml > /tmp/kiali_cr.yaml || {
        log_error "获取 tracing-yaml 模板失败"
        return 1
    }

    # 步骤 10: 改写 YAML
    #   - disable_version_check: true -> false（启用 external_url 后允许版本探测）
    #   - 将注释行 `# external_url: "<platform-url>/clusters/<cluster-name>/jaeger"`
    #     替换为实际可用的 `external_url: "${PLATFORM_URL}${JAEGER_BASEPATH}"` 值
    log_info "步骤 10: 改写 disable_version_check / external_url"
    sed -i 's/disable_version_check: true/disable_version_check: false/' /tmp/kiali_cr.yaml || {
        log_error "改写 disable_version_check 失败"
        return 1
    }
    sed -i "s|# external_url: \"<platform-url>/clusters/<cluster-name>/jaeger\"|external_url: \"${external_url}\"|" /tmp/kiali_cr.yaml || {
        log_error "改写 external_url 失败"
        return 1
    }

    # 校验 sed 改写结果
    if ! grep -q "disable_version_check: false" /tmp/kiali_cr.yaml; then
        log_error "disable_version_check 未改写为 false"
        cat /tmp/kiali_cr.yaml
        return 1
    fi
    if ! grep -qE "^[[:space:]]*external_url:" /tmp/kiali_cr.yaml; then
        log_error "external_url 注释未被放开"
        cat /tmp/kiali_cr.yaml
        return 1
    fi
    log_success "kiali_cr.yaml 改写完成"

    # 步骤 11: 在 /tmp 下应用 patch（命令使用 `cat kiali_cr.yaml` 相对路径）
    log_info "步骤 11: 应用 Kiali 调用链集成 patch"
    local patch_cmd patch_output expected_patch
    patch_cmd=$(runme print config-kiali:apply-tracing-patch)
    patch_output=$(cd /tmp && eval "$patch_cmd" 2>&1) || {
        log_error "应用调用链集成 patch 失败: $patch_output"
        return 1
    }

    expected_patch=$(runme print config-kiali:apply-tracing-patch-output)
    if ! __cmp_contains "$patch_output" "$expected_patch"; then
        log_error "调用链集成 patch 输出验证失败"
        log_error "期待包含: $expected_patch"
        log_error "实际输出: $patch_output"
        return 1
    fi
    log_success "Kiali 调用链集成配置完成"

    log_success "=========================================="
    log_success "Kiali 文档测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
