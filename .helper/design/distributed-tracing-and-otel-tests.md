# 分布式调用链 / OpenTelemetry 文档自动化测试方案（v2：独立测试仓库）

> **适用范围**
>
> - `distributed-tracing-docs/docs/en/installing/installing-distributed-tracing.mdx` —— 分布式调用链安装
> - `distributed-tracing-docs/docs/en/uninstalling/uninstalling-distributed-tracing.mdx` —— 分布式调用链卸载
> - `opentelemetry-docs/docs/en/installing/install-opentelemetry.mdx` 的「Installing the Alauda Build of OpenTelemetry v2 Operator」章节 —— 既作为独立的 OTel Operator 安装测试，也是分布式调用链安装的前置依赖
>
> **v2 相比 v1 的核心变化**：测试框架从 `servicemesh2-docs/tests/` 抽离为**独立的兄弟仓库 `docs-runme-tests`**。v1 方案（框架留在 servicemesh2-docs、兄弟仓库反向 source、`EXTRA_DOC_REPOS` 环境变量）整体作废，由本文档取代。

## 0. 设计原则

1. **框架独立成仓**：新建 `docs-runme-tests` 仓库，与 `servicemesh2-docs` / `distributed-tracing-docs` / `opentelemetry-docs` 平级（同一父目录下的兄弟目录）。所有文档项目对它是对等关系，不再有「特权仓库」。
2. **测试脚本仍与文档同仓同目录**：`runme-test_*.sh` 必须和被测 `.mdx` 在同一仓库、同一目录。原因有二 ——
   - **runme 约束**：`runme run/print <block>` 按「CWD 所在 git 仓库」递归扫描 `.mdx` 查找带 `{name=...}` 的代码块，测试运行时 CWD 必须落在被测文档所在的仓库内；
   - **工程约束**：文档改动与它的测试改动应在同一个 PR 里一起评审、一起演进。
3. **引擎通用、项目专属隔离**：`docs-runme-tests` 内部明确划分 `framework/`（通用引擎，不含任何 mesh/otel/tracing 知识）与 `projects/<name>/`（各项目专属的初始化与辅助函数）。
4. **唯一编排入口集中在框架仓库**：`run.sh`（单测执行引擎）+ `run-mesh-all.sh` / `run-otel-all.sh` / `run-tracing-all.sh`（按项目分的全量编排脚本）。
5. **最大化复用**：现有 mesh 测试框架的通用部分（日志、验证、kubeconfig、`install_operator`、各类 `_wait_*`）原样复用；otel / tracing 不复制任何脚本，只调用框架提供的通用函数。

## 1. 独立测试仓库 docs-runme-tests

### 1.1 为什么独立成仓

v1 方案把框架留在 `servicemesh2-docs/tests/`，让 `distributed-tracing-docs` 的测试脚本反向 `source ../servicemesh2-docs/tests/util/`。这造成一个**不对称依赖**：`servicemesh2-docs` 本是与其它文档平级的「网格文档仓库」，却被迫成为所有兄弟仓库的测试基础设施宿主——任何文档仓库要跑测试都得 clone `servicemesh2-docs`，框架代码的归属语义也含糊不清。

独立成 `docs-runme-tests` 后：所有文档仓库对称地依赖一个**职责单一的测试仓库**；框架的版本、CI、Issue 有独立归属；新增文档项目只需在框架仓库登记一行。

### 1.2 目录布局（四仓库全景）

```
/home/vscode/repo/
├── docs-runme-tests/                # 【新建】独立测试框架仓库
│   ├── run.sh                       # 单测执行引擎（项目感知）
│   ├── run-mesh-all.sh              # mesh 全量编排（由 servicemesh2-docs/tests/run-all.sh 迁移）
│   ├── run-otel-all.sh              # otel 全量编排（新增）
│   ├── run-tracing-all.sh           # tracing 全量编排（新增）
│   ├── repos.conf                   # 文档仓库注册表
│   ├── README.md                    # 框架文档（由 tests/README.md 迁移并改写）
│   ├── .gitignore                   # 忽略 bin/ package/ .kubeconfig/
│   ├── bin/                         # 工具缓存：runme / violet / istioctl（gitignore）
│   ├── package/                     # 插件包缓存（gitignore）
│   ├── .kubeconfig/                 # kubeconfig 缓存（gitignore）
│   ├── framework/                   # 通用引擎，零项目耦合
│   │   ├── common.sh                # 日志 / 结果统计 / install_operator / _wait_* / kubectl_apply_runme_block
│   │   ├── verify.sh                # __cmp_* 输出比对（原样迁移）
│   │   ├── kubeconfig.sh            # ACP kubeconfig 拉取 / 合并 / 复用
│   │   └── tools.sh                 # check_tools / 工具安装 / 通用插件包上传
│   └── projects/                    # 各项目专属逻辑
│       ├── mesh/project.sh          # mesh 钩子 + install_istioctl / upload_all_packages /
│       │                            #   install_all_servicemesh_operators / kubectl_apply_with_mirror / fetch_platform_ca
│       ├── otel/project.sh          # otel 钩子（安装 OTel Operator）
│       └── tracing/project.sh       # tracing 钩子（依赖 OTel Operator）
│
├── servicemesh2-docs/               # tests/ 目录删除，仅保留与文档同目录的测试脚本
│   └── docs/en/.../runme-test_*.sh  # 20 个 mesh 测试脚本，改 bootstrap 指向 docs-runme-tests
│
├── distributed-tracing-docs/
│   └── docs/en/
│       ├── installing/
│       │   ├── installing-distributed-tracing.mdx             # 改：加 name 属性
│       │   └── runme-test_installing-distributed-tracing.sh   # 新增
│       └── uninstalling/
│           ├── uninstalling-distributed-tracing.mdx           # 改：加 name 属性
│           └── runme-test_uninstalling-distributed-tracing.sh # 新增
│
└── opentelemetry-docs/
    └── docs/en/installing/
        ├── install-opentelemetry.mdx              # 改：3 个 block 重命名
        └── runme-test_install-opentelemetry.sh    # 新增（OTel Operator 安装测试）
```

### 1.3 通用 / 项目专属 代码拆分

这是抽离工作的**核心**——搬文件容易，难在把现有 `tests/util/` 里交织的通用逻辑与 mesh 专属逻辑分开。下表逐函数给出归属：

| 现位置 | 函数 / 内容 | 新位置 | 归类 |
| --- | --- | --- | --- |
| `util/common.sh` | `log_*`、`check_required_tools` | `framework/common.sh` | 通用 |
| `util/common.sh` | `record_test_result`、`print_test_summary`、`TESTS_*` 计数 | `framework/common.sh` | 通用 |
| `util/common.sh` | `install_operator`（带 `runme_prefix` 参数的通用 OLM 安装器） | `framework/common.sh` | 通用 |
| `util/common.sh` | `parse_artifact_version_from_package`、`parse_csv_name_from_package` | `framework/common.sh` | 通用 |
| `util/common.sh` | `kubectl_apply_runme_block` | `framework/common.sh` | 通用 |
| `util/common.sh` | `_wait_for_resource`、`_wait_for_deployment`、`_wait_for_ingress_lb`、`_create_namespace_safe`、`_wait_for_pod_count`、`retry_command` | `framework/common.sh` | 通用 |
| `util/common.sh` | **`kubectl_apply_with_mirror`**（写死 `docker.io`→`asm`、`registry.istio.io/release`→`asm/istio`，读 `mesh-v2-test-suite-manifest`） | `projects/mesh/project.sh` | **mesh 专属** |
| `util/verify.sh` | 全部 `__cmp_*` | `framework/verify.sh` | 通用（原样迁移） |
| `util/kubeconfig.sh` | `fetch_cluster_kubeconfig`、`setup_kubeconfig`、`ensure_kubeconfig`、`load_kubeconfig`、`_compute_kubeconfig_fingerprint`、`_check_kubeconfig_env`、`_run_runme_block_isolated` | `framework/kubeconfig.sh` | 通用（ACP 平台逻辑） |
| `util/kubeconfig.sh` | **`fetch_platform_ca`**（执行 `config-kiali:*` 块，该块仅存在于 servicemesh2-docs） | `projects/mesh/project.sh` | **mesh 专属** |
| `util/init.sh` | `check_tools`、`_detect_os_arch`、`_install_tool`、`install_runme`、`install_violet` | `framework/tools.sh` | 通用 |
| `util/init.sh` | `download_package`、`check_package_uploaded`、`upload_package` | `framework/tools.sh` | 通用（ACP 插件包机制） |
| `util/init.sh` | **`install_istioctl`**（读 `multi-primary-multi-network:set-istio-version` 块） | `projects/mesh/project.sh` | **mesh 专属** |
| `util/init.sh` | **`upload_all_packages`**（写死 5 个 mesh 套件包列表） | `projects/mesh/project.sh` | **mesh 专属** |
| `util/init.sh` | **`install_all_servicemesh_operators`** | `projects/mesh/project.sh` | **mesh 专属** |
| `util/init.sh` | **`main`**（mesh 初始化编排） | `projects/mesh/project.sh` 的 `project_init` | **mesh 专属** |
| `tests/run.sh` | 参数解析 / 脚本发现 / 执行 / 总结 | `run.sh`（引擎，重写为项目感知） | 通用 |
| `tests/run-all.sh` | 全部内容（Case 1-8，全是网格/Ambient/多集群） | `run-mesh-all.sh` | **mesh 专属** |

**结论**：`framework/` 下 `common.sh` / `verify.sh` / `kubeconfig.sh` / `tools.sh` 拆出后是干净的通用引擎；mesh 专属的 6 处（`kubectl_apply_with_mirror`、`fetch_platform_ca`、`install_istioctl`、`upload_all_packages`、`install_all_servicemesh_operators`、`run-all.sh`）全部收敛到 `projects/mesh/`。

### 1.4 测试脚本如何定位框架（bootstrap）

引擎 `run.sh` 在 source 测试脚本之前，会 **export 一组路径环境变量**，测试脚本不再自己计算路径：

| 变量 | 含义 | 由谁设置 |
| --- | --- | --- |
| `FRAMEWORK_ROOT` | `docs-runme-tests` 仓库根 | `run.sh` 自解析 |
| `DOC_REPO_ROOT` | 当前被测脚本所在的文档仓库根 | `run.sh` 根据脚本路径解析 |
| `MESH_REPO_ROOT` / `OTEL_REPO_ROOT` / `TRACING_REPO_ROOT` | 各文档仓库根（按 `repos.conf` 注册项导出，大写项目名 + `_REPO_ROOT`） | `run.sh` 读 `repos.conf` |

因此**所有文档仓库的所有 `runme-test_*.sh` 使用统一 bootstrap**，不再有按目录深度写死的 `cd ../../../..`：

```bash
#!/usr/bin/env bash
set -e

# FRAMEWORK_ROOT 由 run.sh 注入；缺失说明未经引擎运行
: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
# mesh 脚本额外引入（otel/tracing 不需要）：
# source "$FRAMEWORK_ROOT/projects/mesh/project.sh"   # 为使用 kubectl_apply_with_mirror
```

> 现有 20 个 mesh 测试脚本目前的写法是 `REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"` + `source "$REPO_ROOT/tests/util/common.sh"`，且 `../../../..` 的层数随文档目录深度不同而不同。迁移时统一替换为上面的 bootstrap（详见第 8 节）。

### 1.5 引擎工作目录约定与跨项目 runme

由于 `run.sh` 现在位于 `docs-runme-tests`（一个**独立的 git 仓库**），直接在框架仓库内执行 runme 会扫不到任何 `.mdx`。约定：

1. **引擎在执行 `project_init` / `project_prepare` / `test_*` / `cleanup_*` 前，统一 `cd` 进当前被测脚本的 `DOC_REPO_ROOT`**，使该文档仓库内的 runme 块可被解析。
2. 当某测试需要执行**另一个仓库**的代码块时，由测试脚本/钩子自己 `pushd` 到对应仓库根。最典型的是 tracing 安装依赖 otel 的 Operator：

| 调用对象 | 工作目录 |
| --- | --- |
| `install-mesh:*` / `install-tracing:*` / `uninstall-tracing:*` | 各自 `DOC_REPO_ROOT`（引擎已 `cd`） |
| `install-otel:*` / `uninstall-otel:*` 块 | `pushd "$OTEL_REPO_ROOT"` |

测试脚本中提供小封装：

```bash
_in_otel_repo() { pushd "$OTEL_REPO_ROOT" >/dev/null; "$@"; local rc=$?; popd >/dev/null; return $rc; }
```

## 2. 测试引擎 run.sh

### 2.1 文档仓库注册表 repos.conf

`docs-runme-tests/repos.conf` 登记每个项目对应的文档仓库路径：

```
# <project>:<doc-repo-path>
# 路径相对 FRAMEWORK_ROOT，或绝对路径；可用环境变量 <PROJECT>_REPO_ROOT 覆盖
mesh:../servicemesh2-docs
otel:../opentelemetry-docs
tracing:../distributed-tracing-docs
```

- 路径不存在的条目静默跳过（兼容只 clone 了部分仓库的场景）。
- 环境变量覆盖：如 `TRACING_REPO_ROOT=/abs/path` 可让 CI 在非兄弟目录布局下工作。
- 新增文档项目 = 新增一行 + 新增 `projects/<name>/project.sh` + 新增 `run-<name>-all.sh`。

### 2.2 `--project` 参数与自动查找

`run.sh` 新增 `--project <name>` 参数，并扩展 `--file` 的脚本发现逻辑：

- **带 `--project`**：搜索范围限定为该项目的仓库（`find "$repo/docs" -name "runme-test_<file>.sh"`），明确、无歧义、最快。
- **不带 `--project`（自动查找）**：遍历 `repos.conf` 所有仓库逐个 `find`：
  - 恰好命中 1 个 → 使用之，并**反查出所属项目**（用于选择 `project_*` 钩子）；
  - 命中 0 个 → 报错退出「未找到测试脚本」；
  - 命中 ≥2 个 → 报错并提示「测试脚本在多个项目中重名，请用 `--project` 指定」。
- `--init-only` 必须显式带 `--project`（引擎需知道执行哪个项目的初始化）。

> 即「能自动找到，且仍保留 `--project` 作显式覆盖」。各 `run-*-all.sh` 内部一律显式带 `--project`。

### 2.3 项目钩子契约

每个项目在 `projects/<name>/project.sh` 中实现三个标准函数，引擎按约定调用。`framework/*.sh` 的通用函数对钩子可见。

| 钩子函数 | 调用时机 | 职责 | mesh 实现 | otel 实现 | tracing 实现 |
| --- | --- | --- | --- | --- | --- |
| `project_check_env` | 每次运行开头 | 校验该项目专属环境变量，缺失则返回非 0 | 校验 5 个 `PKG_*` | 校验 `PKG_OPENTELEMETRY_OPERATOR2_URL` | 校验 `PKG_OPENTELEMETRY_OPERATOR2_URL`；`TRACING_ES_*` 缺失只 warn（测试脚本内 SKIPPED） |
| `project_init <clusters...>` | 仅 `--init-only` / `--force-init` | 重量级初始化 | `ensure_kubeconfig "$@" global` → `upload_all_packages` → `install_all_servicemesh_operators` → `install_istioctl` | `ensure_kubeconfig "$@"` → 上传并 `install_operator` 安装 OTel Operator | `ensure_kubeconfig "$@"` → `pushd $OTEL_REPO_ROOT` 上传并安装 OTel Operator |
| `project_prepare` | 每次运行（`--init-only` 后或 `--file` 模式） | 轻量级准备 | `load_kubeconfig` → `fetch_platform_ca` 并 `export PLATFORM_CA` | `load_kubeconfig` | `load_kubeconfig` |

- 通用工具安装（`check_tools` / `install_runme` / `install_violet`）由引擎在 `project_init` 之前统一执行（runme、violet 三个项目都需要）。
- `install_istioctl` 仅 mesh 需要，故归入 mesh 的 `project_init`。
- mesh 的「集群列表末尾自动追加 `global` 集群」逻辑随 `project_init` 一并迁入 `projects/mesh/`——`global` 集群仅服务于 `fetch_platform_ca`，是 mesh 专属需求。

### 2.4 引擎主流程

```
run.sh 解析参数
  ├─ 解析 --project / --file / --cluster / --init-only / --force-init / --no-cleanup / --cleanup-only / --skip-operator-and-crds
  ├─ 校验通用环境变量：RUNME_VERSION / PLATFORM_ADDRESS / ACP_API_TOKEN / PLATFORM_USERNAME / PLATFORM_PASSWORD
  ├─ 读 repos.conf，export FRAMEWORK_ROOT 及各 *_REPO_ROOT
  ├─ 确定 project：--project 显式指定，或由 --file 自动查找反推
  ├─ source framework/{common,verify,kubeconfig,tools}.sh + projects/<project>/project.sh
  ├─ project_check_env                         # 项目专属环境变量校验
  ├─ cd "$DOC_REPO_ROOT"                       # 使 runme 能解析该仓库的块
  ├─ if 初始化模式（--init-only / --force-init）：
  │     check_tools; install_runme; install_violet
  │     project_init <clusters>                # 重量级初始化
  ├─ project_prepare                           # 轻量级准备（kubeconfig / PLATFORM_CA）
  ├─ if --init-only：打印总结并退出
  └─ 对每个 --file：定位脚本 → source → 执行 test_* →（按开关）执行 cleanup_*
        print_test_summary
```

`--file` 模式默认不初始化（复用既有 kubeconfig），`--force-init` 强制初始化——与 v1 行为一致。

### 2.5 run-mesh-all.sh / run-otel-all.sh / run-tracing-all.sh

三个全量编排脚本都放在 `docs-runme-tests/` 根，开头 `cd` 到框架目录、`trap print_test_summary EXIT`。

**`run-mesh-all.sh`**：即现 `servicemesh2-docs/tests/run-all.sh`，逐条 `./run.sh` 调用加 `--project mesh`（如 `./run.sh --project mesh --file install-mesh`、`./run.sh --project mesh --init-only --cluster "$EAST_CLUSTER_NAME" --cluster "$WEST_CLUSTER_NAME"`）。Case 编号与内容不变。

**`run-otel-all.sh`**（新增）：

```bash
log_header "Case 1: OTel Operator 安装测试"
if ( set -e
    ./run.sh --project otel --file install-opentelemetry --force-init
); then record_test_result 0; else record_test_result 1; exit 1; fi
```

**`run-tracing-all.sh`**（新增）：

```bash
log_header "Case 1: 分布式调用链安装与卸载测试"
# 要求：TRACING_ES_ENDPOINT / TRACING_ES_USER / TRACING_ES_PASS 已设置，否则各测试 SKIPPED
if ( set -e
    ./run.sh --project tracing --file installing-distributed-tracing --force-init
    ./run.sh --project tracing --file uninstalling-distributed-tracing
); then record_test_result 0; else record_test_result 1; exit 1; fi
```

> `--force-init` 触发 tracing 的 `project_init`：自动上传并安装 OTel Operator（tracing 安装的前置依赖），无需先跑 `run-otel-all.sh`。三者相互独立、可单独运行。

## 3. MDX 文档改动

> 本节与框架抽离无关，是 otel / tracing 文档本身需要的改动；内容与 v1 一致。

### 3.1 `opentelemetry-docs` —— 3 处 block 重命名

`install_operator()` 对块名有固定约定。`install-opentelemetry.mdx` 的「Installing the Alauda Build of OpenTelemetry v2 Operator」章节需重命名 3 个块：

| 期望块名 | 当前块名 |
| --- | --- |
| `install-otel:create-namespace-opentelemetry-operator2` | `install-otel:create-namespace-operator` |
| `install-otel:create-subscription-opentelemetry-operator2` | `install-otel:create-subscription` |
| `install-otel:approve-installplan-manual` | `install-otel:approve-installplan` |

其它块（`check-packagemanifest-versions`、`confirm-catalogsource`(+`-output`)、`wait-installplan-pending`、`wait-csv-succeeded`、`check-csv-status`）命名已符合约定，无需改动。

### 3.2 `distributed-tracing-docs` —— `installing-distributed-tracing.mdx`

按 `install-tracing:` 前缀给需要测试的代码块加 name 属性：

| # | 步骤 | 拟定 name | 类型 |
| --- | --- | --- | --- |
| 1 | 设置 ES 环境变量（占位符） | （**不加 name**，测试脚本从环境变量注入） | bash |
| 2 | 拉取平台配置 + Jaeger 镜像 | `install-tracing:get-platform-config` | bash |
| 3 | 设置 Jaeger 默认环境变量 | `install-tracing:set-jaeger-defaults` | bash |
| 4 | 创建 jaeger 命名空间 + ES Secret | `install-tracing:create-jaeger-ns-and-es-secret` | bash |
| 4 | 验证 ES Secret | `install-tracing:verify-es-secret` | bash |
| 5 | 创建 ILM Policy | `install-tracing:create-ilm-policy` | bash |
| 5 | 验证 ILM Policy | `install-tracing:verify-ilm-policy` | bash |
| 6 | 创建 jaeger-es-rollover-init Job | `install-tracing:create-rollover-init-job` | bash |
| 6 | 等待 Job 完成 + 验证模板/别名 | `install-tracing:verify-rollover-init` | bash |
| 7 | 清理 init Job | `install-tracing:delete-rollover-init-job` | bash |
| 8 | 创建 OAuth2 Proxy Secret | `install-tracing:create-oauth2-proxy-secret` | bash |
| 9 | jaeger.yaml 模板 | `install-tracing:jaeger-yaml` | yaml |
| 10 | envsubst 渲染并 apply | `install-tracing:apply-jaeger` | bash |
| 11 | 等待 jaeger collector deployment 就绪 | `install-tracing:wait-jaeger-rollout` | bash |
| 12 | 给 namespace 打 cpaas.io/project 标签 | `install-tracing:label-jaeger-ns` | bash |
| 12 | 创建 jaeger Ingress | `install-tracing:create-jaeger-ingress` | bash |
| 12 | 等待 Ingress 就绪 | `install-tracing:wait-jaeger-ingress` | bash |
| - | 打印 Jaeger UI URL | `install-tracing:print-jaeger-url` | bash |
| - | 创建 otel OpenTelemetryCollector | `install-tracing:create-otel-collector` | bash |
| - | 等待 otel collector deployment 就绪 | `install-tracing:wait-otel-rollout` | bash |
| - | 部署 telemetrygen 生成测试 trace | `install-tracing:deploy-telemetrygen` | bash |

「(Optional) Enabling Service Performance Monitoring (SPM)」整节首期不纳入测试。

### 3.3 `distributed-tracing-docs` —— `uninstalling-distributed-tracing.mdx`

「Uninstalling via the CLI」章节加 name 属性：

| # | 步骤 | 拟定 name | 类型 |
| --- | --- | --- | --- |
| 1 | 设置环境变量（JAEGER_NS、INSTANCE_NAME） | `uninstall-tracing:set-env` | bash |
| 2 | 删除 otel OpenTelemetryCollector | `uninstall-tracing:delete-otel-collector`(+`-output`) | bash/text |
| 3 | 删除 jaeger OpenTelemetryCollector | `uninstall-tracing:delete-jaeger-collector`(+`-output`) | bash/text |
| 4 | 删除 jaeger 命名空间 | `uninstall-tracing:delete-jaeger-ns`(+`-output`) | bash/text |
| 5 | （可选）删除 OTel Operator subscription | `uninstall-tracing:delete-otel-subscription`(+`-output`) | bash/text |

「Uninstalling via the web console」为 UI 操作，不可自动化，脚本日志中说明跳过。

## 4. 测试脚本规划

### 4.1 `runme-test_install-opentelemetry.sh`（新增，opentelemetry-docs）

位置：`opentelemetry-docs/docs/en/installing/runme-test_install-opentelemetry.sh`。范围限定「Installing the Alauda Build of OpenTelemetry v2 Operator」章节——既是 `run-otel-all.sh` 的唯一 Case，也验证 tracing 所依赖的 Operator 安装路径。

| 步骤 | 描述 | 模式 | 涉及 |
| --- | --- | --- | --- |
| 1 | 调用通用 `install_operator` 安装 OTel Operator | G | `install-otel:*`（全套） |

核心实现：

```bash
test_install_opentelemetry() {
    install_operator \
        "opentelemetry-operator2" \
        "opentelemetry-operator2" \
        "$PKG_OPENTELEMETRY_OPERATOR2_URL" \
        "install-otel"
}
```

无 `cleanup_*`（安装类测试不内嵌清理；OTel Operator 故意保留以供 tracing 复用）。`install_operator` 自带「已安装则跳过」的幂等逻辑。

### 4.2 `runme-test_installing-distributed-tracing.sh`（新增，distributed-tracing-docs）

**前置依赖**（运行前需 export）：

| 环境变量 | 说明 |
| --- | --- |
| `TRACING_ES_ENDPOINT` | Elasticsearch 端点 URL |
| `TRACING_ES_USER` | Elasticsearch 用户名 |
| `TRACING_ES_PASS` | Elasticsearch 密码 |

未设置时测试以「SKIPPED — 缺少 ES 依赖」退出并 `record_test_result` 为通过（避免 CI 红线）。

**步骤规划**（模式 A-I 对应 `auto-test-creator` SKILL.md 模式表）：

| 步骤 | 描述 | 模式 | 涉及 runme 块 |
| --- | --- | --- | --- |
| 0 | 检查 ES 环境变量（缺失则 SKIPPED） | 纯 bash | - |
| 1 | `pushd $OTEL_REPO_ROOT` 调用 `install_operator` 安装 OTel Operator | G + pushd | `install-otel:*` |
| 2 | `export ES_ENDPOINT/ES_USER/ES_PASS`（替代文档步骤 1 占位符） | 纯 bash | - |
| 3 | 拉取平台配置 | F | `install-tracing:get-platform-config` |
| 4 | 设置 Jaeger 默认变量 | F | `install-tracing:set-jaeger-defaults` |
| 5 | 创建 namespace + ES Secret | A | `install-tracing:create-jaeger-ns-and-es-secret` |
| 5.1 | 验证 ES Secret | A | `install-tracing:verify-es-secret` |
| 6 | 创建 ILM Policy | A | `install-tracing:create-ilm-policy` |
| 6.1 | 验证 ILM Policy | A | `install-tracing:verify-ilm-policy` |
| 7 | 创建 rollover-init Job | A | `install-tracing:create-rollover-init-job` |
| 7.1 | 等待 Job 完成并验证 | A | `install-tracing:verify-rollover-init` |
| 8 | 清理 init Job | A | `install-tracing:delete-rollover-init-job` |
| 9 | 创建 OAuth2 Proxy Secret | A | `install-tracing:create-oauth2-proxy-secret` |
| 10 | `runme print` 生成 `/tmp/jaeger.yaml` | C | `install-tracing:jaeger-yaml` |
| 11 | envsubst + apply（`kubectl_apply_runme_block` 切到 `/tmp`） | E | `install-tracing:apply-jaeger` |
| 12 | 等待 collector deployment 就绪 | A | `install-tracing:wait-jaeger-rollout` |
| 13 | label namespace | A | `install-tracing:label-jaeger-ns` |
| 14 | 创建 Ingress | A | `install-tracing:create-jaeger-ingress` |
| 14.1 | 等待 Ingress LB 就绪 | A | `install-tracing:wait-jaeger-ingress` |
| 15 | 打印 Jaeger UI URL | A | `install-tracing:print-jaeger-url` |
| 16 | 创建 otel OpenTelemetryCollector | A | `install-tracing:create-otel-collector` |
| 17 | 等待 otel collector deployment 就绪 | A | `install-tracing:wait-otel-rollout` |
| 18 | 部署 telemetrygen 生成 trace 并 wait/delete | A | `install-tracing:deploy-telemetrygen` |

> 步骤 1 的 OTel Operator 安装在功能上与 `runme-test_install-opentelemetry.sh` 重复，但二者走同一个通用 `install_operator`（幂等），互不干扰。`PKG_OPENTELEMETRY_OPERATOR2_URL` 是已有环境变量。
>
> 步骤 11：`install-tracing:apply-jaeger` 内容为 `envsubst < jaeger.yaml | kubectl apply -f -`，依赖 cwd 存在 `jaeger.yaml`。先 `runme print install-tracing:jaeger-yaml > /tmp/jaeger.yaml`，再 `kubectl_apply_runme_block "install-tracing:apply-jaeger" "/tmp/"`。

### 4.3 `runme-test_uninstalling-distributed-tracing.sh`（新增，distributed-tracing-docs）

| 步骤 | 描述 | 模式 | 涉及 runme 块 |
| --- | --- | --- | --- |
| 0 | 检查 ES 环境变量（与 install 一致；未设置则 SKIPPED） | 纯 bash | - |
| 1 | 设置 JAEGER_NS / INSTANCE_NAME 环境变量 | F | `uninstall-tracing:set-env` |
| 2 | 删除 otel Collector + 验证输出 | B | `uninstall-tracing:delete-otel-collector`(+`-output`) |
| 3 | 删除 jaeger Collector + 验证输出 | B | `uninstall-tracing:delete-jaeger-collector`(+`-output`) |
| 4 | 删除 jaeger 命名空间 + 验证输出 | B | `uninstall-tracing:delete-jaeger-ns`(+`-output`) |
| 5 | （可选）删除 OTel Operator subscription + 验证 | B | `uninstall-tracing:delete-otel-subscription`(+`-output`) |
| 6 | `pushd $OTEL_REPO_ROOT` 删除 OTel Operator CRDs | A + pushd | `uninstall-otel:delete-crds` |

**步骤 5/6 受 `--skip-operator-and-crds` 控制**：参照现有 `uninstalling-alauda-service-mesh` 测试的 `SKIP_OPERATOR_AND_CRDS` 模式，仅在传 `--skip-operator-and-crds` 时跳过这两步，让 Operator 留存以便后续测试复用。

## 5. 缺失步骤分析

### 5.1 ES（Elasticsearch）依赖未在文档/框架内自动化

`installing-distributed-tracing.mdx` 第一步要求用户手填 `ES_ENDPOINT/USER/PASS`，是外部强依赖。处理：测试脚本通过 `TRACING_ES_*` 环境变量注入，缺失则 SKIPPED 并标记为通过。后续可在 `framework/` 增 `_ensure_es_for_tests()` 在集群内拉临时 ES，不属本次范围。

### 5.2 步骤 12 namespace 标签的副作用

给 `${JAEGER_NS}` 打 `cpaas.io/project=cpaas-system` 标签后，该命名空间纳入 cpaas-system 项目；卸载文档的 `kubectl delete namespace ${JAEGER_NS}` 会一并清理，无需额外处理。

### 5.3 OTel Operator 共享生命周期

`installing-distributed-tracing.mdx` 显式依赖「OTel Operator 已安装」，但安装/卸载文档未声明谁负责其生命周期。处理：

- install 测试在 `project_init` 中**自动安装 OTel Operator**；
- uninstall 测试默认**保留 Operator**（仅清理 Collector + namespace），不传 `--skip-operator-and-crds` 时才删除 subscription + CRDs。
- 建议（不在本次自动改文档范围）：在 MDX 中补一句「Uninstalling the OTel Operator is the inverse of installation step 1」。

### 5.4 步骤 11 `kubectl rollout status` 已含等待语义

文档使用 `kubectl rollout status deployment/jaeger-collector --timeout=180s`，本身即等待，测试直接 `runme run` 即可。

### 5.5 `telemetrygen` 验证步骤内嵌 wait/delete

文档步骤里 `kubectl wait Succeeded` 和 `kubectl delete pod telemetrygen` 与 `kubectl apply` 同块，单块执行即可；`--duration=150s` 决定该步骤至少 150 秒。

## 6. cleanup 函数判断

| 测试脚本 | cleanup 函数 | 依据 |
| --- | --- | --- |
| `runme-test_install-opentelemetry.sh` | **无** | 安装类，无内嵌清理 |
| `runme-test_installing-distributed-tracing.sh` | **无** | 文档无内嵌清理块；由 uninstall 测试负责清理 |
| `runme-test_uninstalling-distributed-tracing.sh` | **无** | 文档本身就是清理过程，测试自身即 cleanup |

`run-tracing-all.sh` 中 install → uninstall 顺序串联，无需 `--no-cleanup`/`--cleanup-only` 拆分。

## 7. 环境变量

| 变量 | 是否新增 | 用途 | 缺失行为 |
| --- | --- | --- | --- |
| `FRAMEWORK_ROOT` | 新增 | 覆盖框架仓库根（默认自解析） | 自解析 |
| `<PROJECT>_REPO_ROOT` | 新增 | 覆盖某文档仓库路径（如 `TRACING_REPO_ROOT`） | 用 `repos.conf` 相对路径 |
| `TRACING_ES_ENDPOINT` | 新增 | Elasticsearch endpoint | tracing 测试 SKIPPED |
| `TRACING_ES_USER` | 新增 | Elasticsearch 用户 | tracing 测试 SKIPPED |
| `TRACING_ES_PASS` | 新增 | Elasticsearch 密码 | tracing 测试 SKIPPED |
| `RUNME_VERSION` / `PLATFORM_ADDRESS` / `ACP_API_TOKEN` / `PLATFORM_USERNAME` / `PLATFORM_PASSWORD` | 复用 | 引擎通用必需 | 引擎 `check_env` 报错 |
| `PKG_OPENTELEMETRY_OPERATOR2_URL` | 复用 | otel / tracing 的 OTel Operator 安装包 | `project_check_env` 报错 |
| `PKG_SERVICEMESH_OPERATOR2_URL` / `PKG_KIALI_OPERATOR_URL` / `PKG_METALLB_OPERATOR_URL` | 复用 | 仅 mesh 项目需要 | mesh `project_check_env` 报错 |

> v1 的 `EXTRA_DOC_REPOS` 取消，由 `repos.conf` + `<PROJECT>_REPO_ROOT` 取代。引擎通用 `check_env` 只校验通用 5 项；`PKG_*` 下放到各项目 `project_check_env`；`TRACING_ES_*` 不进必需列表，仅软检查。

## 8. 迁移计划（现有 mesh 测试 + 框架搬迁）

抽离涉及对**现有 mesh 测试**的迁移，必须保证迁移后 mesh 全量回归不退化。

### 8.1 新建 `docs-runme-tests` 仓库

`git init` 一个与三个文档仓库平级的新仓库，加 `.gitignore`（`bin/`、`package/`、`.kubeconfig/`、`*.tar.gz`）。

### 8.2 框架文件搬迁与拆分

| 源（servicemesh2-docs） | 目标（docs-runme-tests） | 操作 |
| --- | --- | --- |
| `tests/run.sh` | `run.sh` | 重写为项目感知引擎（§2） |
| `tests/run-all.sh` | `run-mesh-all.sh` | 迁移，`./run.sh` 调用加 `--project mesh` |
| `tests/util/common.sh` | `framework/common.sh` + `projects/mesh/project.sh` | 按 §1.3 拆分（`kubectl_apply_with_mirror` 归 mesh） |
| `tests/util/verify.sh` | `framework/verify.sh` | 原样迁移 |
| `tests/util/kubeconfig.sh` | `framework/kubeconfig.sh` + `projects/mesh/project.sh` | 拆分（`fetch_platform_ca` 归 mesh） |
| `tests/util/init.sh` | `framework/tools.sh` + `projects/mesh/project.sh` | 拆分（mesh 编排归 `project_init`） |
| `tests/README.md` | `README.md` | 迁移并按新架构改写 |
| `tests/bin/` `tests/package/` | `bin/` `package/` | 缓存目录，不入库 |

新增：`repos.conf`、`projects/otel/project.sh`、`projects/tracing/project.sh`（后两者在阶段 1/2 添加）。

### 8.3 改写 20 个 mesh 测试脚本的 bootstrap

每个 `servicemesh2-docs/docs/en/.../runme-test_*.sh` 头部，把

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"   # 层数随目录深度不同
source "$REPO_ROOT/tests/util/common.sh"
source "$REPO_ROOT/tests/util/verify.sh"
```

统一替换为 §1.4 的 bootstrap（`FRAMEWORK_ROOT` 由引擎注入 + `source "$FRAMEWORK_ROOT/projects/mesh/project.sh"`）。这一步消除了原来按目录深度写死的 `../../../..`。

### 8.4 清理 servicemesh2-docs

- 删除 `servicemesh2-docs/tests/` 整个目录；
- 更新 `servicemesh2-docs/.gitignore`（移除 `tests/.kubeconfig` 等条目）；
- 更新 `.claude/skills/auto-test-creator/SKILL.md` 中对 `tests/` 路径的引用，指向 `docs-runme-tests`；
- 本设计文档（`.helper/design/`）建议在 `docs-runme-tests` 成仓后迁移过去，本次先就地重写。

## 9. 实施阶段与 PR 划分

### 阶段 0 —— 框架抽离 + mesh 迁移（基础，必须先做）

- 新仓库 `docs-runme-tests`：初始提交（§8.1 / §8.2，含 `run-mesh-all.sh`、`framework/`、`projects/mesh/`、`run.sh`、`repos.conf`）。
- `servicemesh2-docs` 1 个 PR：删 `tests/`、改 20 个测试脚本 bootstrap、更新 `.gitignore` 与 skill。
- **验收**：`docs-runme-tests/run-mesh-all.sh` 跑通，mesh 全量回归与迁移前一致。

### 阶段 1 —— OTel Operator 测试

- `opentelemetry-docs` 1 个 PR：3 个 block 重命名（§3.1）+ 新增 `runme-test_install-opentelemetry.sh`（§4.1）。
- `docs-runme-tests` 1 个 PR：新增 `projects/otel/project.sh` + `run-otel-all.sh` + `repos.conf` 的 otel 条目。

### 阶段 2 —— 分布式调用链测试

- `distributed-tracing-docs` 1 个 PR：两份 MDX 加 name 属性（§3.2/3.3）+ 新增 2 个测试脚本（§4.2/4.3）。
- `docs-runme-tests` 1 个 PR：新增 `projects/tracing/project.sh` + `run-tracing-all.sh` + `repos.conf` 的 tracing 条目。

> 每个仓库的改动各自提交、PR 自包含；阶段 1、2 对 `docs-runme-tests` 是纯增量。

## 10. 风险与限制

1. **阶段 0 是最大风险点**：框架搬迁 + 20 脚本改 bootstrap，任何遗漏都会让 mesh 回归失败。必须以「mesh 全量回归通过」为硬验收。
2. **多仓库布局假设**：引擎默认按兄弟目录定位文档仓库。布局不符时需通过 `<PROJECT>_REPO_ROOT` / `FRAMEWORK_ROOT` 覆盖。
3. **多仓库版本同步**：`docs-runme-tests` 与文档仓库各自演进，CI 需 checkout 配套版本；建议各文档仓库 CI 固定/锁定框架仓库 ref。
4. **ES 依赖**：tracing 测试需可达 ES 集群，无法本地自启动，建议 CI 维护共享 ES 实例。
5. **runme 全局块名空间**：`install-tracing:*`、`uninstall-tracing:*`、`install-otel:*`、`uninstall-otel:*` 靠前缀命名空间天然规避冲突。
6. **OTel Operator 共享**：install 测试每次重装（幂等），uninstall 测试默认会删；与其它 OTel 相关测试组合时按顺序设计或加 `--skip-operator-and-crds`。
7. **可选 SPM 部分 / Web Console 章节**首期不覆盖，脚本日志中说明跳过。

## 11. 验收标准

1. **阶段 0**：`docs-runme-tests/run-mesh-all.sh` 在与现状相同的环境下，mesh 全量测试结果与迁移前一致；`./run.sh --project mesh --file install-mesh` 等单测正常。
2. **阶段 1**：`./run.sh --project otel --file install-opentelemetry --force-init` 成功安装 OTel Operator；`run-otel-all.sh` 通过。
3. **阶段 2**：已设置 `TRACING_ES_*` 时，`./run.sh --project tracing --file installing-distributed-tracing --force-init` 成功（Jaeger UI Ingress 可访问、telemetrygen pod 完成），`uninstalling-distributed-tracing` 成功（jaeger namespace 删除）；未设置时两条测试 SKIPPED 不阻塞。
4. **自动查找**：`./run.sh --file install-mesh`（不带 `--project`）能跨 `repos.conf` 自动定位；重名时报错提示加 `--project`。
5. **部分克隆兼容**：只 clone `docs-runme-tests` + `servicemesh2-docs` 时，mesh 测试正常，tracing 测试报「未找到测试脚本」而非崩溃。

## 附录 A：`projects/<name>/project.sh` 骨架

```bash
#!/usr/bin/env bash
# projects/tracing/project.sh

project_check_env() {
    [ -n "$PKG_OPENTELEMETRY_OPERATOR2_URL" ] || { log_error "缺少 PKG_OPENTELEMETRY_OPERATOR2_URL"; return 1; }
    if [ -z "${TRACING_ES_ENDPOINT:-}" ]; then
        log_warn "未设置 TRACING_ES_*，tracing 测试将 SKIPPED"
    fi
}

project_init() {                       # 仅 --init-only / --force-init
    local clusters=("$@")
    ensure_kubeconfig "${clusters[@]}" || return 1
    # 安装 tracing 的前置依赖：OTel Operator（块在 opentelemetry-docs）
    for c in "${clusters[@]}"; do
        upload_package "$c" "$PKG_OPENTELEMETRY_OPERATOR2_URL"
    done
    pushd "$OTEL_REPO_ROOT" >/dev/null
    install_operator "opentelemetry-operator2" "opentelemetry-operator2" \
        "$PKG_OPENTELEMETRY_OPERATOR2_URL" "install-otel"
    popd >/dev/null
}

project_prepare() {                    # 每次运行
    load_kubeconfig || return 1
}
```

## 附录 B：`runme-test_installing-distributed-tracing.sh` 骨架

```bash
#!/usr/bin/env bash
set -e
: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"
# $DOC_REPO_ROOT / $OTEL_REPO_ROOT 由 run.sh 注入

_in_otel_repo() { pushd "$OTEL_REPO_ROOT" >/dev/null; "$@"; local rc=$?; popd >/dev/null; return $rc; }

test_installing_distributed_tracing() {
    # 步骤 0：检查 ES 依赖
    if [ -z "${TRACING_ES_ENDPOINT:-}" ] || [ -z "${TRACING_ES_USER:-}" ] || [ -z "${TRACING_ES_PASS:-}" ]; then
        log_warn "SKIPPED: 未设置 TRACING_ES_ENDPOINT/USER/PASS"
        return 0
    fi
    export ES_ENDPOINT="$TRACING_ES_ENDPOINT" ES_USER="$TRACING_ES_USER" ES_PASS="$TRACING_ES_PASS"

    # 步骤 1：安装 OTel Operator（跨仓库，幂等）
    _in_otel_repo install_operator "opentelemetry-operator2" "opentelemetry-operator2" \
        "$PKG_OPENTELEMETRY_OPERATOR2_URL" "install-otel"

    # 步骤 3-18：在 distributed-tracing-docs 内逐步执行（引擎已 cd 到 $DOC_REPO_ROOT）
    eval "$(runme print install-tracing:get-platform-config)"
    eval "$(runme print install-tracing:set-jaeger-defaults)"
    # ... 其余步骤拆为 step-by-step 调用，便于失败定位，详见 §4.2
}
```

---

**本文档版本**：v2（2026-05-20），取代 v1。
