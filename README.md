# Alauda Service Mesh v2 Docs

This repository contains the documentation for the Alauda Service Mesh v2.

## Getting Started

### Prerequisites

Before you begin, make sure you have the following installed on your system:

- **[Node.js](https://nodejs.org/en/)** (version 14 or higher recommended)
- **[npm](https://www.npmjs.com/)** (comes with Node.js)
- **[Yarn](https://yarnpkg.com/)** package manager

### Installation

1. Clone this repository and navigate to the project directory
2. Install project dependencies:

```bash
yarn install
```

### Recommended Development Setup

For the best development experience, we recommend:

- **Editor**: [Visual Studio Code](https://code.visualstudio.com/)
- **Extension**: [MDX extension](https://marketplace.visualstudio.com/items?itemName=unifiedjs.vscode-mdx) for enhanced markdown editing

## Development Commands

| Command      | Description                              |
| ------------ | ---------------------------------------- |
| `yarn dev`   | Start development server with hot reload |
| `yarn build` | Build production-ready static files      |
| `yarn serve` | Preview built files locally              |

### Development Workflow

1. **Start development**: Run `yarn dev` to launch the local server
2. **Edit content**: Make changes to your markdown files - they'll update automatically
3. **Navigation changes**: If you modify the sidebar navigation, restart the development server
4. **Preview production**: Use `yarn build` followed by `yarn serve` to test the final build

> **💡 Tip**: The development server supports hot reloading for most changes, making your workflow smooth and efficient!

## Kiali 版本更新

### 更新 Kiali 版本

使用如下脚本更新 `docs/en/integration/observability/kiali.mdx` 中的 Kiali 版本：

```bash
# 用法: ./hack/update-kiali-in-docs.sh <NEW_VERSION> <OLD_VERSION>
./hack/update-kiali-in-docs.sh 2.27.1-rc.0 2.22.2
./hack/update-kiali-in-docs.sh 2.27.1-r0 2.27.1-rc.0
```

### Kiali 新版本内容同步更新

让 AI 读取当前版本到新版本更新的内容：https://kiali.io/news/release-notes/。
然后分析当前文档是否有需要同步更新的部分，review 后执行更新。

## Istio 版本更新

### 更新 Istio 版本

因为 Mesh 维护两个 Istio 大版本，所以使用如下脚本先修改最新版本，然后是次新版本：

```bash
# 用法: ./update-istio-in-docs.sh <NEW_VERSION> <OLD_VERSION>
./hack/update-istio-in-docs.sh 1.28.1 1.26.3
./hack/update-istio-in-docs.sh 1.26.3 1.24.6
```

### 更新文档中的版本链接

使用如下脚本更新 `docs/en` 下 `.mdx` 文档中 Istio 和 Sail Operator raw GitHub 链接的 release 分支版本。版本参数不需要包含 `release-` 前缀：

```bash
# 用法: ./hack/update-links-in-docs.sh <NEW_ISTIO_VERSION> <OLD_ISTIO_VERSION> <NEW_SAIL_VERSION> <OLD_SAIL_VERSION>
./hack/update-links-in-docs.sh 1.31 1.30 2.3 2.2
```

### Sail Operator 和 Istio 新版本内容同步更新

让 AI 读取当前版本到新版本更新的内容：

- https://github.com/istio-ecosystem/sail-operator/releases
- `https://istio.io/latest/news/releases/1.<version>.x/announcing-1.<version>/` (修改为对应版本)

然后分析当前文档是否有需要同步更新的部分，review 后执行更新。

### sites.yaml 更新

更新 [sites.yaml](./sites.yaml) 中的最新外链站点。
