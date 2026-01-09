#!/bin/bash

set -euo pipefail

# 第一阶段：安装 Istio
runme run dual-stack:create-istio-cni
runme run dual-stack:create-istio
runme run dual-stack:wait-istio-ready

# 第二阶段：部署测试应用
runme run dual-stack:create-namespaces
runme run dual-stack:enable-sidecar-injection
runme run dual-stack:deploy-tcp-echo-dual-stack
runme run dual-stack:deploy-tcp-echo-ipv4
runme run dual-stack:deploy-tcp-echo-ipv6
runme run dual-stack:deploy-sleep

# Patch 镜像地址：docker.io -> docker-mirrors.alauda.cn
patch_deployment_image() {
    local ns=$1
    local name=$2
    
    # 获取 deployment 的副本数和 image
    local deploy_json
    deploy_json=$(kubectl get deployment "${name}" -n "${ns}" -o json)
    local replicas
    replicas=$(echo "${deploy_json}" | jq '.spec.replicas')
    local image
    image=$(echo "${deploy_json}" | jq -r '.spec.template.spec.containers[0].image')
    
    echo "Patching ${ns}/${name}: replicas=${replicas}, image=${image}"
    
    # 缩容到 0
    kubectl scale deployment "${name}" -n "${ns}" --replicas=0
    
    # 替换镜像中的 docker.io 为 docker-mirrors.alauda.cn
    local new_image
    new_image=$(echo "${image}" | sed 's|docker.io|docker-mirrors.alauda.cn|')
    kubectl patch deployment "${name}" -n "${ns}" --type='json' \
        -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"${new_image}\"}]"
    
    # 恢复副本数
    kubectl scale deployment "${name}" -n "${ns}" --replicas="${replicas}"
    
    echo "Patched ${ns}/${name}: new_image=${new_image}"
}

patch_deployment_image dual-stack tcp-echo
patch_deployment_image ipv4 tcp-echo
patch_deployment_image ipv6 tcp-echo
patch_deployment_image sleep sleep

runme run dual-stack:wait-deployments-ready

# 第三阶段：验证配置和连接性

# 验证 ipFamilyPolicy
runme run dual-stack:verify-config
expected=$(runme print dual-stack:verify-config-output)
actual=$(kubectl get service tcp-echo -n dual-stack -o=jsonpath='{.spec.ipFamilyPolicy}')
[[ "${actual}" == "${expected}" ]] || { echo "验证失败: ipFamilyPolicy 期望 ${expected}，实际 ${actual}"; exit 1; }

# 验证双栈连接
runme run dual-stack:test-connectivity
expected=$(runme print dual-stack:test-connectivity-output)
actual=$(kubectl exec -n sleep deploy/sleep -- sh -c "echo dualstack | nc tcp-echo.dual-stack 9000")
[[ "${actual}" =~ "hello dualstack" ]] || { echo "验证失败: 双栈连接期望包含 'hello dualstack'"; exit 1; }

# 验证 IPv4 连接
runme run dual-stack:test-ipv4-connectivity
actual=$(kubectl exec -n sleep deploy/sleep -- sh -c "echo ipv4 | nc tcp-echo.ipv4 9000")
[[ "${actual}" =~ "hello ipv4" ]] || { echo "验证失败: IPv4 连接期望包含 'hello ipv4'"; exit 1; }

# 验证 IPv6 连接
runme run dual-stack:test-ipv6-connectivity
actual=$(kubectl exec -n sleep deploy/sleep -- sh -c "echo ipv6 | nc tcp-echo.ipv6 9000")
[[ "${actual}" =~ "hello ipv6" ]] || { echo "验证失败: IPv6 连接期望包含 'hello ipv6'"; exit 1; }

# 第四阶段：清理
runme run dual-stack:cleanup

echo "所有测试通过！"
