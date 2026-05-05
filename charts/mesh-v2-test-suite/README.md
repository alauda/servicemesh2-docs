# mesh-v2-test-suite

Mesh v2 测试套件——一个仅用于分发测试镜像的 ACP 集群插件。

## 插件作用

将一组用于 Mesh v2 验证、教程和回归测试的容器镜像打包随插件下发。用户在 ACP 上安装本插件后，这些镜像会被同步到平台内置镜像仓库，业务工作负载可直接引用，无需再从外部公网拉取。

本插件**不部署任何工作负载**，仅创建一个占位 ConfigMap 用于声明插件已安装并提供镜像清单。

## 包含的镜像

镜像清单维护在 [`values.yaml`](./values.yaml) 的 `global.images` 字段。当前版本包含：

| 名称                    | 仓库路径                                     | 版本      |
| ----------------------- | -------------------------------------------- | --------- |
| curl                    | `asm/curlimages/curl`                        | `8.16.0`  |
| go-httpbin              | `asm/mccutchen/go-httpbin`                   | `v2.15.0` |
| bookinfo-details-v1     | `asm/istio/examples-bookinfo-details-v1`     | `1.20.3`  |
| bookinfo-ratings-v1     | `asm/istio/examples-bookinfo-ratings-v1`     | `1.20.3`  |
| bookinfo-reviews-v1     | `asm/istio/examples-bookinfo-reviews-v1`     | `1.20.3`  |
| bookinfo-reviews-v2     | `asm/istio/examples-bookinfo-reviews-v2`     | `1.20.3`  |
| bookinfo-reviews-v3     | `asm/istio/examples-bookinfo-reviews-v3`     | `1.20.3`  |
| bookinfo-productpage-v1 | `asm/istio/examples-bookinfo-productpage-v1` | `1.20.3`  |
| tcp-echo-server         | `asm/istio/tcp-echo-server`                  | `1.3`     |

镜像源 registry 由 `global.registry.address` 配置，默认 `build-harbor.alauda.cn`。

## 目录结构

```
mesh-v2-test-suite/
├── Chart.yaml                     Helm chart 元信息
├── README.md                      本文件
├── module-plugin.yaml             ACP 插件声明（ModulePlugin CR）
├── values.yaml                    镜像清单及全局变量
├── scripts/
│   └── plugin-config.yaml         插件配置（无可调参数的最小版本）
└── templates/
    ├── _helpers.tpl               含 imageList helper，从 values.yaml 动态读取镜像
    └── configmap.yaml             占位 ConfigMap，仅用作插件已安装的标识
```

## 如何打包与上架

详细背景请参考根目录 [docs/plugin-build-guide.md](../docs/plugin-build-guide.md)。

### 1. 推送 chart 到 OCI 仓库

```bash
helm package mesh-v2-test-suite/
helm registry login build-harbor.alauda.cn
helm push mesh-v2-test-suite-<chart-version>.tgz oci://build-harbor.alauda.cn/asm
```

### 2. 用 violet 打包

#### 流水线打包

详见：https://edge.alauda.cn/console-devops/workspace/asm/ci?buildName=artifacts-plugin&cluster=business-build&namespace=asm-dev

#### 本地打包测试

```bash
violet create mesh-v2-test-suite \
  --artifact build-harbor.alauda.cn/asm/mesh-v2-test-suite:<chart-version> \
  --platforms linux/amd64,linux/arm64 \
  --username <harbor-user> \
  --password <harbor-pass>

violet package mesh-v2-test-suite \
  --username <harbor-user> \
  --password <harbor-pass>
```

执行后在当前目录生成 `mesh-v2-test-suite-<chart-version>.tgz`。

### 3. 上架到 ACP

```bash
violet push mesh-v2-test-suite-v1.0.0.tgz \
  --platform-address https://<acp-host> \
  --platform-username <acp-user> \
  --platform-password <acp-pass>
```

## 安装与卸载

平台管理 → 集群管理 → 选择目标集群 → 插件 → 找到 `Mesh v2 测试套件` → 部署 / 卸载。

## 安装后如何使用镜像

插件安装完成后，9 个镜像已被同步到 ACP 内置镜像仓库。可通过以下方式确认：

```bash
kubectl get configmap mesh-v2-test-suite-manifest -n cpaas-system -o yaml
```

`data.images` 字段会列出所有镜像的**完整可拉取地址**（含 registry 前缀）。registry 部分由 `scripts/plugin-config.yaml` 的 valuesTemplates 在安装时通过 `<< .RegistryAddress >>` 自动重写为当前集群对应的 ACP 内置镜像仓库地址，因此 ConfigMap 中列出的地址就是用户在工作负载里可直接引用的地址。

```yaml
spec:
  containers:
    - name: curl
      image: <acp-registry>/asm/curlimages/curl:8.16.0
```

> 用 `helm template` 在本地渲染时，registry 字段还是 `values.yaml` 默认值 `build-harbor.alauda.cn`（即镜像源地址），属正常现象。该字段只有在 ACP 安装时才会被 valuesTemplates 重写为平台内置 registry。

## 如何新增或更新镜像

1. 编辑 [`values.yaml`](./values.yaml) 的 `global.images`，新增条目或调整 `repository`/`tag`。
2. 按 [如何更新插件版本](#如何更新插件版本) 递增 chart 版本号。
3. 重新执行打包流程（推 chart → violet create / package / push）。

`templates/_helpers.tpl` 中的 `imageList` helper 会自动从 `values.yaml` 渲染清单到 ConfigMap，模板本身无需修改。

## 如何更新插件版本

chart 版本号同时记录在两个文件中，且必须保持一致：

- [`Chart.yaml`](./Chart.yaml) 的 `version` 字段
- [`module-plugin.yaml`](./module-plugin.yaml) 的 `spec.appReleases[0].chartVersions[0].version` 字段

直接使用 [`hack/update-version.sh`](./hack/update-version.sh) 一次性同步这两处：

```bash
./hack/update-version.sh <NEW_VERSION>
```

示例：

```bash
./hack/update-version.sh v1.0.0-rc.2
./hack/update-version.sh v1.0.0
```

脚本同时兼容 Linux（GNU sed）和 macOS（BSD sed），无需额外安装 `gnu-sed`。执行完成后请用 `git diff` 确认两个文件的 `version` 行都已更新，再继续打包流程。

## 约束

- 所有镜像必须与主 chart 在同一个 registry domain（即 `global.registry.address`）。violet 在打包时会用主 chart 的 OCI artifact 地址作为唯一 domain 拼装镜像 URL（参见 violet 源码 `pkg/artifact/chart/chart.go` 的 `seekImagesFromValues`）。
- `values.yaml` 中 `global.images.<name>.repository` 必须是仓库相对路径，**不能**包含 registry 前缀，否则会被拼成错误的双域名地址。
