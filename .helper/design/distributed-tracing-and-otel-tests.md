# 分布式调用链 / OpenTelemetry 文档自动化测试方案

> 适用范围：
>
> - `../distributed-tracing-docs/docs/en/installing/installing-distributed-tracing.mdx`
> - `../distributed-tracing-docs/docs/en/uninstalling/uninstalling-distributed-tracing.mdx`
> - `../opentelemetry-docs/docs/en/installing/install-opentelemetry.mdx` 的「Installing the Alauda Build of OpenTelemetry v2 Operator」章节（作为安装文档的前置依赖）

## 0. 设计原则

**最大化复用，不做物理复制**：现有 `servicemesh2-docs/tests/` 下的所有框架代码（`run.sh`、`run-all.sh`、`util/common.sh`、`util/verify.sh`、`util/init.sh`、`util/kubeconfig.sh`）作为唯一权威实现，不向兄弟项目仓库复制。

- **新增测试脚本**放置在它们对应的 MDX 文档同目录（保持与现有项目「脚本与文档同目录」的惯例）：
  - `distributed-tracing-docs/docs/en/installing/runme-test_installing-distributed-tracing.sh`
  - `distributed-tracing-docs/docs/en/uninstalling/runme-test_uninstalling-distributed-tracing.sh`
- **测试脚本通过相对路径反向 source**（向上跨越 4 级 + 兄弟仓库）引用 `servicemesh2-docs/tests/util/common.sh` 和 `verify.sh`。
- **唯一编排入口**仍是 `servicemesh2-docs/tests/run.sh` / `run-all.sh`。`run.sh` 增加跨项目搜索能力（受白名单约束），不破坏现有单仓库测试行为。

## 1. 跨项目复用架构

### 1.1 目录布局

```
/home/vscode/repo/
├── servicemesh2-docs/              # 测试框架权威所在
│   ├── tests/
│   │   ├── run.sh                  # 扩展：支持搜索 EXTRA_DOC_REPOS
│   │   ├── run-all.sh              # 扩展：新增 Case 9
│   │   ├── README.md               # 扩展：新增测试表条目 + 文档
│   │   └── util/                   # 不变
│   └── .helper/design/
│       └── distributed-tracing-and-otel-tests.md   # 本文档
│
├── distributed-tracing-docs/       # 测试脚本反向引用 servicemesh2-docs 的工具
│   └── docs/en/
│       ├── installing/
│       │   ├── installing-distributed-tracing.mdx              # 改：加 name 属性
│       │   └── runme-test_installing-distributed-tracing.sh    # 新增
│       └── uninstalling/
│           ├── uninstalling-distributed-tracing.mdx            # 改：加 name 属性
│           └── runme-test_uninstalling-distributed-tracing.sh  # 新增
│
└── opentelemetry-docs/             # 仅改 MDX，不增脚本
    └── docs/en/installing/
        └── install-opentelemetry.mdx  # 改：3 个 block 重命名以兼容 install_operator
```

### 1.2 测试脚本骨架（跨项目通用模板）

```bash
#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 自身项目根（如 .../distributed-tracing-docs/）
DOC_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# 跨仓库定位 servicemesh2-docs 作为框架根
FRAMEWORK_ROOT="$(cd "$DOC_REPO_ROOT/../servicemesh2-docs" && pwd)"

source "$FRAMEWORK_ROOT/tests/util/common.sh"
source "$FRAMEWORK_ROOT/tests/util/verify.sh"
```

### 1.3 runme 的工作目录约定

`runme run/print <block-name>` 默认在 CWD 所在的 git 项目内递归扫描 `.mdx` 文件查找带 `{name=...}` 属性的代码块。**当测试需要执行跨项目代码块时，必须先 `pushd` 到对应项目根**，否则 runme 找不到块。

约定：

| 调用对象             | 工作目录                                                |
| -------------------- | ------------------------------------------------------- |
| `install-otel:*` 块  | `pushd $OTEL_REPO_ROOT`（= `/home/vscode/repo/opentelemetry-docs`）|
| `install-tracing:*` 块 | `pushd $DOC_REPO_ROOT`（= `/home/vscode/repo/distributed-tracing-docs`）|
| `uninstall-tracing:*` 块 | `pushd $DOC_REPO_ROOT` 同上                           |
| `uninstall-otel:*` 块（可选清理 Operator） | `pushd $OTEL_REPO_ROOT`                  |

为简化代码，会在测试脚本中提供两个小封装：

```bash
_in_otel_repo()  { pushd "$OTEL_REPO_ROOT"  >/dev/null && "$@"; local rc=$?; popd >/dev/null; return $rc; }
_in_doc_repo()   { pushd "$DOC_REPO_ROOT"   >/dev/null && "$@"; local rc=$?; popd >/dev/null; return $rc; }
```

### 1.4 `run.sh` 扩展点

在 `find $REPO_ROOT/docs/en -name "runme-test_${file}.sh"` 之外，追加搜索环境变量 `EXTRA_DOC_REPOS`（以 `:` 分隔的路径列表）所列项目的 `docs/en/`。默认值为：

```bash
EXTRA_DOC_REPOS="${EXTRA_DOC_REPOS:-$REPO_ROOT/../distributed-tracing-docs:$REPO_ROOT/../opentelemetry-docs}"
```

- 只在路径存在时纳入搜索，不存在则静默跳过（保持 servicemesh2-docs 单仓克隆场景的兼容性）。
- 不改变现有测试发现优先级（先在主仓 `docs/en/` 找，再在 EXTRA_DOC_REPOS 找），避免命名冲突。

## 2. MDX 文档改动

### 2.1 `opentelemetry-docs` —— 仅 3 处块名重命名

`install_operator()` 函数对块名有固定约定：

| 期望块名                                                | 当前块名                       |
| ------------------------------------------------------- | ------------------------------ |
| `install-otel:create-namespace-opentelemetry-operator2` | `install-otel:create-namespace-operator` |
| `install-otel:create-subscription-opentelemetry-operator2` | `install-otel:create-subscription`   |
| `install-otel:approve-installplan-manual`               | `install-otel:approve-installplan` |

其它块（`check-packagemanifest-versions`、`confirm-catalogsource`、`wait-installplan-pending`、`wait-csv-succeeded`、`check-csv-status` 及对应 `-output` 块）命名已符合 `install_operator` 约定，无需改动。

### 2.2 `distributed-tracing-docs` —— `installing-distributed-tracing.mdx`

文档共 12 个步骤，按 `install-tracing:` 前缀给所有需要测试的 bash/yaml 代码块加 name 属性：

| #   | 步骤                                | 拟定 name                                          | 类型 |
| --- | ----------------------------------- | -------------------------------------------------- | ---- |
| 1   | 设置 ES 环境变量（占位符）          | （**不加 name**，测试脚本从环境变量注入）          | bash |
| 2   | 拉取平台配置 + Jaeger 镜像           | `install-tracing:get-platform-config`              | bash |
| 3   | 设置 Jaeger 默认环境变量             | `install-tracing:set-jaeger-defaults`              | bash |
| 4   | 创建 jaeger 命名空间 + ES Secret     | `install-tracing:create-jaeger-ns-and-es-secret`   | bash |
| 4   | 验证 ES Secret                       | `install-tracing:verify-es-secret`                 | bash |
| 5   | 创建 ILM Policy                      | `install-tracing:create-ilm-policy`                | bash |
| 5   | 验证 ILM Policy                      | `install-tracing:verify-ilm-policy`                | bash |
| 6   | 创建 jaeger-es-rollover-init Job     | `install-tracing:create-rollover-init-job`         | bash |
| 6   | 等待 Job 完成 + 验证模板/别名         | `install-tracing:verify-rollover-init`             | bash |
| 7   | 清理 init Job                        | `install-tracing:delete-rollover-init-job`         | bash |
| 8   | 创建 OAuth2 Proxy Secret             | `install-tracing:create-oauth2-proxy-secret`       | bash |
| 9   | jaeger.yaml 模板                     | `install-tracing:jaeger-yaml`                      | yaml |
| 10  | envsubst 渲染并 apply                | `install-tracing:apply-jaeger`                     | bash |
| 11  | 等待 jaeger collector deployment 就绪 | `install-tracing:wait-jaeger-rollout`              | bash |
| 12  | 给 namespace 打 cpaas.io/project 标签 | `install-tracing:label-jaeger-ns`                  | bash |
| 12  | 创建 jaeger Ingress                  | `install-tracing:create-jaeger-ingress`            | bash |
| 12  | 等待 Ingress 就绪                    | `install-tracing:wait-jaeger-ingress`              | bash |
| -   | 打印 Jaeger UI URL（Verification）   | `install-tracing:print-jaeger-url`                 | bash |
| -   | 创建 otel OpenTelemetryCollector     | `install-tracing:create-otel-collector`            | bash |
| -   | 等待 otel collector deployment 就绪   | `install-tracing:wait-otel-rollout`                | bash |
| -   | 部署 telemetrygen 生成测试 trace      | `install-tracing:deploy-telemetrygen`              | bash |

**「(Optional) Enabling Service Performance Monitoring (SPM)」整节**首期不纳入测试（属于扩展场景），后续可补 `install-tracing-spm:` 前缀的独立测试。

### 2.3 `distributed-tracing-docs` —— `uninstalling-distributed-tracing.mdx`

「Uninstalling via the CLI」章节加 name 属性：

| #   | 步骤                                  | 拟定 name                                         | 类型 |
| --- | ------------------------------------- | ------------------------------------------------- | ---- |
| 1   | 设置环境变量（JAEGER_NS、INSTANCE_NAME） | `uninstall-tracing:set-env`                       | bash |
| 2   | 删除 otel OpenTelemetryCollector       | `uninstall-tracing:delete-otel-collector`         | bash |
| 2   | 期望输出                              | `uninstall-tracing:delete-otel-collector-output`  | text |
| 3   | 删除 jaeger OpenTelemetryCollector     | `uninstall-tracing:delete-jaeger-collector`       | bash |
| 3   | 期望输出                              | `uninstall-tracing:delete-jaeger-collector-output`| text |
| 4   | 删除 jaeger 命名空间                  | `uninstall-tracing:delete-jaeger-ns`              | bash |
| 4   | 期望输出                              | `uninstall-tracing:delete-jaeger-ns-output`       | text |
| 5   | （可选）删除 OTel Operator subscription | `uninstall-tracing:delete-otel-subscription`      | bash |
| 5   | 期望输出                              | `uninstall-tracing:delete-otel-subscription-output` | text |

**「Uninstalling via the web console」**章节为 UI 操作步骤，不可自动化，仅在测试日志中说明跳过。

## 3. 测试脚本步骤规划

### 3.1 `runme-test_installing-distributed-tracing.sh`

**前置依赖**（在 `run.sh` 启动前必须 export）：

| 环境变量              | 说明                                              |
| --------------------- | ------------------------------------------------- |
| `TRACING_ES_ENDPOINT` | Elasticsearch 端点 URL（如 `https://es.xx:9200`） |
| `TRACING_ES_USER`     | Elasticsearch 用户名                              |
| `TRACING_ES_PASS`     | Elasticsearch 密码                                |

如果未设置，测试脚本会以「`SKIPPED — 缺少 ES 依赖`」退出并 `record_test_result` 为通过（避免 CI 红线），并打印明确日志。

**步骤编号与测试模式（A-I 对应 SKILL.md 中的模式表）**：

| 步骤 | 描述                                          | 模式             | 涉及 runme 块                                                  |
| ---- | --------------------------------------------- | ---------------- | -------------------------------------------------------------- |
| 0    | 检查 ES 环境变量（缺失则 SKIPPED）            | 纯 bash          | -                                                              |
| 1    | 在 `opentelemetry-docs` 仓库内调用 `install_operator` 安装 OTel Operator | G + pushd | `install-otel:*`（全套）                                       |
| 2    | 在测试脚本中 `export ES_ENDPOINT/ES_USER/ES_PASS`（替代文档步骤 1） | 纯 bash          | -                                                              |
| 3    | 拉取平台配置                                  | F (eval runme print) | `install-tracing:get-platform-config`                          |
| 4    | 设置 Jaeger 默认变量                          | F                | `install-tracing:set-jaeger-defaults`                          |
| 5    | 创建 namespace + ES Secret                    | A                | `install-tracing:create-jaeger-ns-and-es-secret`               |
| 5.1  | 验证 ES Secret                                | A                | `install-tracing:verify-es-secret`                             |
| 6    | 创建 ILM Policy                               | A                | `install-tracing:create-ilm-policy`                            |
| 6.1  | 验证 ILM Policy                               | A                | `install-tracing:verify-ilm-policy`                            |
| 7    | 创建 rollover-init Job                        | A                | `install-tracing:create-rollover-init-job`                     |
| 7.1  | 等待 Job 完成并验证                           | A                | `install-tracing:verify-rollover-init`                         |
| 8    | 清理 init Job                                 | A                | `install-tracing:delete-rollover-init-job`                     |
| 9    | 创建 OAuth2 Proxy Secret                      | A                | `install-tracing:create-oauth2-proxy-secret`                   |
| 10   | runme print 生成 `/tmp/jaeger.yaml`            | C                | `install-tracing:jaeger-yaml`                                  |
| 11   | envsubst + apply（需在 `/tmp` cwd）           | E (`kubectl_apply_runme_block`) | `install-tracing:apply-jaeger`                |
| 12   | 等待 collector deployment 就绪                | A                | `install-tracing:wait-jaeger-rollout`                          |
| 13   | label namespace                               | A                | `install-tracing:label-jaeger-ns`                              |
| 14   | 创建 Ingress                                  | A                | `install-tracing:create-jaeger-ingress`                        |
| 14.1 | 等待 Ingress LB 就绪                          | A                | `install-tracing:wait-jaeger-ingress`                          |
| 15   | 打印 Jaeger UI URL                            | A                | `install-tracing:print-jaeger-url`                             |
| 16   | 创建 otel OpenTelemetryCollector              | A                | `install-tracing:create-otel-collector`                        |
| 17   | 等待 otel collector deployment 就绪           | A                | `install-tracing:wait-otel-rollout`                            |
| 18   | 部署 telemetrygen 生成 trace 并 wait/delete   | A                | `install-tracing:deploy-telemetrygen`                          |

**步骤 1（OTel Operator 安装）实现细节**：

```bash
# 切换到 opentelemetry-docs 仓库根，使 runme 能定位 install-otel:* 块
pushd "$OTEL_REPO_ROOT" >/dev/null
install_operator \
    "opentelemetry-operator2" \
    "opentelemetry-operator2" \
    "$PKG_OPENTELEMETRY_OPERATOR_URL" \
    "install-otel"
popd >/dev/null
```

`PKG_OPENTELEMETRY_OPERATOR_URL` 已在现有 `tests/run.sh` 的必需环境变量列表中，无需新增。

**步骤 11（apply jaeger.yaml）实现细节**：

`install-tracing:apply-jaeger` 块内容是 `envsubst < jaeger.yaml | kubectl apply -f -`，它依赖 cwd 中存在 `jaeger.yaml`。需要先 `runme print install-tracing:jaeger-yaml > /tmp/jaeger.yaml`，再用 `kubectl_apply_runme_block "install-tracing:apply-jaeger" "/tmp/"`。

### 3.2 `runme-test_uninstalling-distributed-tracing.sh`

| 步骤 | 描述                                          | 模式 | 涉及 runme 块                                       |
| ---- | --------------------------------------------- | ---- | --------------------------------------------------- |
| 0    | 检查 ES 环境变量是否设置（与 install 一致；若未设置则 SKIPPED） | 纯 bash | - |
| 1    | 设置 JAEGER_NS / JAEGER_INSTANCE_NAME 环境变量 | F    | `uninstall-tracing:set-env`                         |
| 2    | 删除 otel Collector + 验证输出                 | B    | `uninstall-tracing:delete-otel-collector` (+ `-output`) |
| 3    | 删除 jaeger Collector + 验证输出               | B    | `uninstall-tracing:delete-jaeger-collector` (+ `-output`) |
| 4    | 删除 jaeger 命名空间 + 验证输出                | B    | `uninstall-tracing:delete-jaeger-ns` (+ `-output`)  |
| 5    | （可选）删除 OTel Operator subscription + 验证 | B    | `uninstall-tracing:delete-otel-subscription` (+ `-output`) |
| 6    | 在 `opentelemetry-docs` 仓库内删除 OTel Operator namespace 和 CRDs（参考 `uninstall-otel:delete-crds`） | A + pushd | `uninstall-otel:delete-crds` |

**步骤 5/6 受 `--skip-operator-and-crds` 控制**：参照现有 `uninstall-mesh` 测试的 `SKIP_OPERATOR_AND_CRDS` 模式，仅在调用 `--skip-operator-and-crds` 时跳过这两步，让 Operator 留存以便后续测试复用。

## 4. 缺失步骤分析

### 4.1 ES（Elasticsearch）依赖未在文档/测试框架内自动化

- **现状**：`installing-distributed-tracing.mdx` 第一步要求用户手填 `ES_ENDPOINT/ES_USER/ES_PASS`，这是外部强依赖。
- **处理方式**：测试脚本通过环境变量 `TRACING_ES_ENDPOINT/USER/PASS` 注入，缺失时输出 SKIPPED 警告并标记测试为通过，避免因 ES 缺失阻断其它测试。
- **后续可优化**：考虑在 `tests/util/` 中新增 `_ensure_es_for_tests()` 工具，按需在集群内拉起一个临时 ES（如 quickwit/elasticsearch helm chart），但不属于本次任务范围。

### 4.2 `installing-distributed-tracing.mdx` 步骤 12 中 namespace 标签的副作用

- 给 `${JAEGER_NS}` 打 `cpaas.io/project=cpaas-system` 标签后，该命名空间会被纳入 cpaas-system 项目；卸载文档的 `kubectl delete namespace ${JAEGER_NS}` 会一并清理，无需额外处理。

### 4.3 文档之间的隐性依赖：OTel Operator 共享生命周期

- `installing-distributed-tracing.mdx` 显式依赖「OTel Operator 已安装」，但安装/卸载文档并未声明谁负责 Operator 生命周期。
- **处理方式**：
  - install 测试**自动安装 OTel Operator**（步骤 1）。
  - uninstall 测试默认**保留 Operator**（仅清理 Collector + namespace），传 `--skip-operator-and-crds` 时维持现状（与 mesh 测试一致），不传时会删除 Operator subscription + CRDs。
- 建议同步在 MDX 文档中补充一句「Uninstalling the OTel Operator is the inverse of step 1 of installation; see `uninstalling-opentelemetry.mdx`」以消除文档层的歧义。**该项不在本次任务范围内自动改文档，仅在设计文档中记录建议。**

### 4.4 文档步骤 11 `kubectl rollout status` 隐含的「就绪信号」

- 文档使用 `kubectl rollout status deployment/jaeger-collector --timeout=180s`，本身已包含等待语义。测试脚本直接 `runme run` 即可，无需额外等待。

### 4.5 `telemetrygen` 验证步骤的内嵌 wait/delete

- 文档步骤里 `kubectl wait Succeeded` 和 `kubectl delete pod telemetrygen` 与 `kubectl apply` 在同一块中（`# Wait for telemetrygen to complete, then clean up the test Pod` 注释下），可作为单块执行。`--duration=150s` 决定整个步骤至少 150 秒。

## 5. cleanup 函数判断

| 测试脚本                                          | cleanup 函数 | 依据                                               |
| ------------------------------------------------- | ------------ | -------------------------------------------------- |
| `runme-test_installing-distributed-tracing.sh`    | **无**       | 文档无内嵌清理代码块；由 uninstall 测试负责清理     |
| `runme-test_uninstalling-distributed-tracing.sh`  | **无**       | 文档本身就是清理过程，测试自身就是 cleanup          |

run-all.sh 中两者按「install → uninstall」顺序串联，无需 `--no-cleanup`/`--cleanup-only` 拆分（参考现有 `kiali` / `uninstalling-alauda-build-of-kiali` 的组合）。

## 6. 框架（`servicemesh2-docs/tests/`）改动

### 6.1 `tests/run.sh` —— 跨项目脚本发现

变更范围：约 10 行新增，位于查找 `test_scripts` 的 for 循环。

```bash
# 新增：解析 EXTRA_DOC_REPOS 环境变量（默认指向兄弟项目）
EXTRA_DOC_REPOS="${EXTRA_DOC_REPOS:-$REPO_ROOT/../distributed-tracing-docs:$REPO_ROOT/../opentelemetry-docs}"

_find_test_script() {
    local file="$1" path

    # 主仓库（原有行为）
    path=$(find "$REPO_ROOT/docs/en" -type f -name "runme-test_${file}.sh" | head -n 1)
    if [ -n "$path" ]; then echo "$path"; return 0; fi

    # 兄弟仓库（新增）
    IFS=':' read -r -a _extra_repos <<< "$EXTRA_DOC_REPOS"
    for repo in "${_extra_repos[@]}"; do
        [ -d "$repo/docs/en" ] || continue
        path=$(find "$repo/docs/en" -type f -name "runme-test_${file}.sh" | head -n 1)
        if [ -n "$path" ]; then echo "$path"; return 0; fi
    done

    return 1
}
```

并把循环里 `find ... | head -n 1` 替换为 `_find_test_script "$file"`。

### 6.2 `tests/run-all.sh` —— 新增 Case

在 Case 6 (Ambient) 之后、Case 7 (多集群) 之前插入：

```bash
# ------------------------------------------------------------------
# Case 7: 分布式调用链（跨仓库：distributed-tracing-docs + opentelemetry-docs）
# 要求: TRACING_ES_ENDPOINT / TRACING_ES_USER / TRACING_ES_PASS 已设置
# ------------------------------------------------------------------
log_header "Case 7: 分布式调用链安装与卸载测试 (Distributed Tracing)"

if (
    set -e
    ./run.sh --file installing-distributed-tracing --force-init
    ./run.sh --file uninstalling-distributed-tracing
); then
    record_test_result 0
else
    record_test_result 1
    exit 1
fi
```

由于插入位置在原 Case 7（多集群）之前，**原多集群 case 编号顺延为 Case 8/9**。

### 6.3 `tests/README.md` —— 文档更新

「当前已有的测试文档」表格新增 2 行：

```markdown
| 分布式调用链安装             | [runme-test_installing-distributed-tracing.sh](../../distributed-tracing-docs/docs/en/installing/runme-test_installing-distributed-tracing.sh)   | `./run.sh --file installing-distributed-tracing`   |
| 分布式调用链卸载             | [runme-test_uninstalling-distributed-tracing.sh](../../distributed-tracing-docs/docs/en/uninstalling/runme-test_uninstalling-distributed-tracing.sh) | `./run.sh --file uninstalling-distributed-tracing` |
```

并在「环境变量」章节新增「分布式调用链测试专用」小节，说明 `TRACING_ES_ENDPOINT/USER/PASS` 和 `EXTRA_DOC_REPOS` 的语义、默认值与跳过逻辑。

「TODO」清单中追加：

- [ ] 分布式调用链 SPM (Service Performance Monitoring) 扩展测试

## 7. 新增 / 复用环境变量

| 变量                          | 是否新增 | 用途                                  | 缺失行为              |
| ----------------------------- | -------- | ------------------------------------- | --------------------- |
| `TRACING_ES_ENDPOINT`         | 新增     | Elasticsearch endpoint                | 测试 SKIPPED          |
| `TRACING_ES_USER`             | 新增     | Elasticsearch 用户                    | 测试 SKIPPED          |
| `TRACING_ES_PASS`             | 新增     | Elasticsearch 密码                    | 测试 SKIPPED          |
| `EXTRA_DOC_REPOS`             | 新增     | run.sh 跨项目搜索路径（`:` 分隔）     | 使用默认值（兄弟项目） |
| `PKG_OPENTELEMETRY_OPERATOR_URL` | 复用  | install_operator 安装包 URL            | 现有 check_env 报错   |
| `PKG_JAEGER_OPERATOR_URL`     | 复用     | （当前 distributed-tracing 用的是 OTel Operator 而非 Jaeger Operator，此变量保留不强依赖） | -                     |

`run.sh` 的 `check_env` **不**把 `TRACING_ES_*` 加进必需列表，仅在测试脚本里做软检查（缺失则 SKIPPED）。

## 8. 风险与限制

1. **ES 依赖**：测试需要可达的 ES 集群，无法在测试机本地自启动。建议在 CI 环境维护一个共享 ES 实例。
2. **跨仓库相对路径**：测试脚本以 `$DOC_REPO_ROOT/../servicemesh2-docs` 定位框架，**要求 3 个仓库必须为同一父目录下的兄弟目录**。若布局不符，需通过 `FRAMEWORK_ROOT` 环境变量覆盖（脚本会优先读取该变量）。
3. **runme 全局块名空间**：`install-tracing:*`、`uninstall-tracing:*`、`install-otel:*`、`uninstall-otel:*` 是新增 / 已有命名空间，需保证全局唯一（已通过前缀命名空间天然规避冲突）。
4. **Operator 共享**：install 测试每次都会重装 OTel Operator（`install_operator` 内部有「已安装则跳过」逻辑，幂等），但 uninstall 测试默认会删 Operator，若与其它 OTel 相关测试组合执行，需要按顺序设计或加 `--skip-operator-and-crds`。
5. **可选 SPM 部分**首期不覆盖，后续如需要可独立增 `installing-distributed-tracing-spm` 测试（不影响主流程）。
6. **Web Console 章节**：两份文档的「Uninstalling/Installing via the web console」均为 UI 步骤，纯 CLI 测试无法覆盖，会在脚本日志中明确说明跳过。

## 9. 实施步骤（拟分两个 PR 提交，便于审阅）

### PR-1（框架与 OTel 文档）—— 在 servicemesh2-docs 仓库
1. 改 `opentelemetry-docs/docs/en/installing/install-opentelemetry.mdx`：重命名 3 个 block（即使没有 PR-2，该改动也是兼容性更新，不影响现有渲染）。
2. 改 `servicemesh2-docs/tests/run.sh`：加 `EXTRA_DOC_REPOS` 支持。

### PR-2（分布式调用链测试本体）
1. 改 `distributed-tracing-docs/docs/en/installing/installing-distributed-tracing.mdx`：加 `{name=install-tracing:*}` 属性。
2. 改 `distributed-tracing-docs/docs/en/uninstalling/uninstalling-distributed-tracing.mdx`：加 `{name=uninstall-tracing:*}` 属性。
3. 新增 `distributed-tracing-docs/docs/en/installing/runme-test_installing-distributed-tracing.sh`。
4. 新增 `distributed-tracing-docs/docs/en/uninstalling/runme-test_uninstalling-distributed-tracing.sh`。
5. 改 `servicemesh2-docs/tests/run-all.sh`：新增 Case 7。
6. 改 `servicemesh2-docs/tests/README.md`：更新测试表 + 环境变量 + TODO。

> 三个仓库分别提交各自的改动，每个仓库的 PR 自包含。

## 10. 验收标准

1. 在已设置 `TRACING_ES_*` 的环境下：
   - `./run.sh --file installing-distributed-tracing --force-init` 成功，Jaeger UI Ingress 可访问，telemetrygen pod 完成。
   - `./run.sh --file uninstalling-distributed-tracing` 成功，jaeger-system namespace 被删除。
2. 未设置 `TRACING_ES_*` 时：两条测试均 SKIPPED 不阻塞 CI。
3. 仅克隆 `servicemesh2-docs` 而无兄弟仓库的场景：`./run.sh --file install-mesh`（原有测试）正常工作，`./run.sh --file installing-distributed-tracing` 报「未找到测试脚本」并退出。
4. 全量回归：`./run-all.sh` 在 IS_DUAL_STACK=false、未设置多集群的环境下能按顺序执行所有 case（含跳过逻辑）。

## 附录 A：测试脚本伪代码（节选）

### A.1 `runme-test_installing-distributed-tracing.sh`

```bash
#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAMEWORK_ROOT="${FRAMEWORK_ROOT:-$(cd "$DOC_REPO_ROOT/../servicemesh2-docs" && pwd)}"
OTEL_REPO_ROOT="$(cd "$DOC_REPO_ROOT/../opentelemetry-docs" && pwd)"

source "$FRAMEWORK_ROOT/tests/util/common.sh"
source "$FRAMEWORK_ROOT/tests/util/verify.sh"

_in_otel_repo() { pushd "$OTEL_REPO_ROOT" >/dev/null; "$@"; local rc=$?; popd >/dev/null; return $rc; }
_in_doc_repo()  { pushd "$DOC_REPO_ROOT"  >/dev/null; "$@"; local rc=$?; popd >/dev/null; return $rc; }

test_installing_distributed_tracing() {
    # 步骤 0: 检查 ES 依赖
    if [ -z "${TRACING_ES_ENDPOINT:-}" ] || [ -z "${TRACING_ES_USER:-}" ] || [ -z "${TRACING_ES_PASS:-}" ]; then
        log_warn "SKIPPED: 未设置 TRACING_ES_ENDPOINT/USER/PASS"
        return 0
    fi
    export ES_ENDPOINT="$TRACING_ES_ENDPOINT" ES_USER="$TRACING_ES_USER" ES_PASS="$TRACING_ES_PASS"

    # 步骤 1: 安装 OTel Operator (跨仓库)
    _in_otel_repo install_operator \
        "opentelemetry-operator2" \
        "opentelemetry-operator2" \
        "$PKG_OPENTELEMETRY_OPERATOR_URL" \
        "install-otel"

    # 步骤 3-18: 在 distributed-tracing-docs 内执行
    _in_doc_repo bash -c '
        eval "$(runme print install-tracing:get-platform-config)"
        eval "$(runme print install-tracing:set-jaeger-defaults)"
        # ... 详见正文
    '
    # 实际代码会拆为 step-by-step 调用，便于失败定位
}
```

### A.2 `runme-test_uninstalling-distributed-tracing.sh`

```bash
#!/usr/bin/env bash
set -e
# ... 同上的 SCRIPT_DIR / FRAMEWORK_ROOT / OTEL_REPO_ROOT 设置 ...

test_uninstalling_distributed_tracing() {
    if [ -z "${TRACING_ES_ENDPOINT:-}" ]; then
        log_warn "SKIPPED: 未设置 TRACING_ES_ENDPOINT"
        return 0
    fi

    pushd "$DOC_REPO_ROOT" >/dev/null

    # 步骤 1: 设置环境变量
    eval "$(runme print uninstall-tracing:set-env)"

    # 步骤 2-4: 删除 collector / jaeger / namespace + 验证输出（模式 B）
    local output expected
    output=$(runme run uninstall-tracing:delete-otel-collector 2>&1)
    expected=$(runme print uninstall-tracing:delete-otel-collector-output)
    __cmp_contains "$output" "$expected" || { log_error "..."; popd >/dev/null; return 1; }
    # ... 其余步骤类似 ...

    popd >/dev/null

    # 步骤 5/6: 可选删除 OTel Operator subscription + CRDs (受 SKIP_OPERATOR_AND_CRDS 控制)
    if [ "${SKIP_OPERATOR_AND_CRDS:-false}" != "true" ]; then
        pushd "$DOC_REPO_ROOT" >/dev/null
        runme run uninstall-tracing:delete-otel-subscription
        popd >/dev/null

        _in_otel_repo runme run uninstall-otel:delete-crds || true
    fi
}
```

---

**本文档版本**：v1（2026-05-20）
