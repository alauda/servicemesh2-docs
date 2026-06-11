#!/usr/bin/env bash
# Istio CNI 升级文档测试脚本（独立入口）
# 实际步骤封装在同目录 istio-cni-update-steps.sh 的 update_istio_cni_and_verify，
# 三个更新策略测试脚本（update-inplace / update-revisionbased /
# update-revisionbased-and-istiorevisiontag）按各自文档的 CNI 更新步骤复用同一函数
# 依赖：环境中已存在旧版本 IstioCNI 且控制面已升级到 v1.28.6
#       （单独运行时可由 update-inplace --no-cleanup 铺垫）
# 清理：资源由上游铺垫测试统一回收，故本脚本无 cleanup 函数

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# 加载 Istio CNI 升级公共步骤
source "$DOC_REPO_ROOT/docs/en/updating/update-mesh/istio-cni-update-steps.sh"

test_istio_cni() {
    log_info "=========================================="
    log_info "开始 Istio CNI 升级测试"
    log_info "=========================================="

    update_istio_cni_and_verify || return 1

    log_success "=========================================="
    log_success "Istio CNI 升级测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}
