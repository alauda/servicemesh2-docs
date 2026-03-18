#!/usr/bin/env bash
# Ambient Mode 安装文档测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 加载工具函数
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"

# runme 命令可以在项目的任意目录中执行

test_installing_ambient_mode() {
    log_info "=========================================="
    log_info "开始 Ambient Mode 安装测试"
    log_info "=========================================="

    # ==========================================
    # 安装 Istio CNI
    # ==========================================

    # 步骤 1: 创建 istio-cni 命名空间并打标签
    log_info "步骤 1: 创建 istio-cni 命名空间"
    runme run ambient-install:create-ns-istio-cni || {
        log_error "创建 istio-cni 命名空间失败"
        return 1
    }

    # 步骤 2: 生成 IstioCNI YAML 到 /tmp
    log_info "步骤 2: 生成 IstioCNI YAML 文件"
    runme print ambient-install:istiocni-yaml > /tmp/istio-cni.yaml || {
        log_error "生成 IstioCNI YAML 失败"
        return 1
    }

    # 步骤 3: 应用 IstioCNI CR
    log_info "步骤 3: 应用 IstioCNI CR"
    kubectl_apply_runme_block "ambient-install:apply-istiocni" "/tmp/" || {
        log_error "应用 IstioCNI CR 失败"
        return 1
    }

    # 步骤 4: 等待 IstioCNI 就绪
    log_info "步骤 4: 等待 IstioCNI 就绪"
    runme run ambient-install:wait-istiocni || {
        log_error "等待 IstioCNI 就绪失败"
        return 1
    }

    # ==========================================
    # 安装 Istio 控制面
    # ==========================================

    # 步骤 5: 创建 istio-system 命名空间并打标签
    log_info "步骤 5: 创建 istio-system 命名空间"
    runme run ambient-install:create-ns-istio-system || {
        log_error "创建 istio-system 命名空间失败"
        return 1
    }

    # 步骤 6: 生成 Istio YAML 到 /tmp
    log_info "步骤 6: 生成 Istio YAML 文件"
    runme print ambient-install:istio-yaml > /tmp/istio.yaml || {
        log_error "生成 Istio YAML 失败"
        return 1
    }

    # 步骤 7: 应用 Istio CR
    log_info "步骤 7: 应用 Istio CR"
    kubectl_apply_runme_block "ambient-install:apply-istio" "/tmp/" || {
        log_error "应用 Istio CR 失败"
        return 1
    }

    # 步骤 8: 等待 Istio 控制面就绪
    log_info "步骤 8: 等待 Istio 控制面就绪"
    runme run ambient-install:wait-istio || {
        log_error "等待 Istio 控制面就绪失败"
        return 1
    }

    # ==========================================
    # 安装 ZTunnel
    # ==========================================

    # 步骤 9: 创建 ztunnel 命名空间并打标签
    log_info "步骤 9: 创建 ztunnel 命名空间"
    runme run ambient-install:create-ns-ztunnel || {
        log_error "创建 ztunnel 命名空间失败"
        return 1
    }

    # 步骤 10: 生成 ZTunnel YAML 到 /tmp
    log_info "步骤 10: 生成 ZTunnel YAML 文件"
    runme print ambient-install:ztunnel-yaml > /tmp/ztunnel.yaml || {
        log_error "生成 ZTunnel YAML 失败"
        return 1
    }

    # 步骤 11: 应用 ZTunnel CR
    log_info "步骤 11: 应用 ZTunnel CR"
    kubectl_apply_runme_block "ambient-install:apply-ztunnel" "/tmp/" || {
        log_error "应用 ZTunnel CR 失败"
        return 1
    }

    # 步骤 12: 等待 ZTunnel 就绪
    log_info "步骤 12: 等待 ZTunnel 就绪"
    runme run ambient-install:wait-ztunnel || {
        log_error "等待 ZTunnel 就绪失败"
        return 1
    }

    log_success "=========================================="
    log_success "Ambient Mode 安装测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
