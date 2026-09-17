# Mesh v1 Jaeger ES 数据迁移方案

> 对应 `Mesh v1 迁移到 Mesh v2 设计方案.md` 的风险项 **R7（老 Jaeger 历史 trace 查询断层）** 与 **附录 C**，本文取代原附录 C 的粗略描述。

## 1. 结论

**Jaeger v2 可以复用 Mesh v1 的 ES 索引数据，历史索引也可以纳入 ES ILM 管理。** 但有一处必须注意：

| 问题 | 结论 |
| :--- | :--- |
| Jaeger v2.20 能否读 Jaeger 1.60 写入的 span/service 索引 | ✅ 能。服务列表、操作列表、trace 搜索、traceID 精确查询、span/process 标签检索全部实测通过 |
| 能否在 Mesh v2 的 rollover 别名体系下统一查询新旧数据 | ✅ 能。把历史日期索引挂到 v2 的 `*-read` 别名即可，新旧数据在同一个 Jaeger UI 中连续可查 |
| 新数据会不会写进历史索引 | ❌ 不会。写入只走 `*-write` 别名指向的 `-000001` 索引，历史索引实测零新增 |
| **Mesh v2 的 `jaeger-ilm-policy` 能否直接管理历史索引** | ❌ **不能**。该策略含 `rollover` 动作，套到日期索引上 ILM 直接报错（见 5.3） |
| 历史索引能否被 ILM 管理 | ✅ 能，但必须**另建一个只含 `delete` 阶段的策略**（见 6.5 方案 A） |
| 是否需要 reindex / 重写数据 | ❌ 不需要。文档格式天然兼容，原地挂别名即可 |

**前提条件：Mesh v1 与 Mesh v2 的 Jaeger 必须使用同一个 ES 集群。** 若分属不同 ES 集群，则只能走 snapshot/restore 或 reindex-from-remote，不在本方案范围内。

**对设计方案的影响**：R7 由"历史查询断层"降级为"可连续查询"；但新增一项**必做动作**——Mesh v1 下线会连带回收其 `jaeger-prod-es-index-cleaner` CronJob，历史索引将无人清理，必须在下线前后接管保留策略（见 6.5）。

## 2. 事实基线

实测环境（平台 v4.3.1，ES 8.19.14）：

| | Mesh v1（global 集群） | Mesh v2（business-1 集群） |
| :--- | :--- | :--- |
| Jaeger 版本 | 1.60.0（`Jaeger` CR `istio-system/jaeger-prod`） | 2.20.0（`OpenTelemetryCollector` CR `jaeger-system/jaeger`） |
| 索引前缀 | `asm-mesh-<meshID>`，本环境为 `asm-mesh-mesh-global` | `acp-<cluster>`，本环境为 `acp-business-1` |
| 索引布局 | 按天的日期索引 `<prefix>-jaeger-span-2026-09-16` | rollover 编号索引 `<prefix>-jaeger-span-000001` + `*-read` / `*-write` 别名 |
| 轮转方式 | 时间索引（未启用 `es.use-aliases`/`es.use-ilm`） | `rotation.auto_rollover` |
| 保留机制 | `jaeger-prod-es-index-cleaner` CronJob，`numberOfDays=7` | ILM 策略 `jaeger-ilm-policy`（hot: `max_age 1d`/`max_primary_shard_size 50gb`；delete: `min_age 7d`） |
| 查询回看 | `es.max-span-age=168h` | 别名轮转下 `max_span_age` 被忽略（Jaeger 内部置为 50 年） |
| 索引类型 | 仅 span、service（`storage.dependencies.enabled: false`，无 dependencies/sampling 索引） | span、service、dependencies、sampling 四类 |

## 3. 文档格式兼容性

`asm-mesh-*` 与 `acp-*` 两族索引的 span 文档结构一致，核心字段 `traceID` / `spanID` / `operationName` / `startTime` / `startTimeMillis` / `duration` / `tags[]` / `logs[]` / `process` / `references[]` 同名同义，取值类型也相同。

**唯一差异在 mapping 而非文档本身**：

| 差异 | v1（Jaeger 1.60） | v2（Jaeger 2.20） | 影响 |
| :--- | :--- | :--- | :--- |
| 标签类型字段名 | mapping 声明为 `tagType` | mapping 声明为 `type` | 见下方说明 |
| 新增字段 | 无 | `scopeTag` / `scopeTags`、`references.flags` / `references.tags` / `references.traceState` | 仅 v2 新写入的数据才有，读旧数据不涉及 |

关于 `tagType`：这是 Jaeger 1.60 索引模板中的历史遗留——**文档里实际写的键名是 `type`**，只有 mapping 声明成了 `tagType`。由于 `tags` 这类 nested 对象带 `dynamic: false`，v1 索引中的 `tags.type` 只存在于 `_source` 而**未建倒排索引**。

这不影响 Jaeger：**Jaeger 的标签检索只用 `tags.key` + `tags.value`，从不查 `tags.type`**，而这两个字段在 v1 索引中都已正常建索引。

```
tags.key + tags.value 检索   → v1 mapping 命中 732 ；v2 mapping 命中 732   ← Jaeger 实际走的路径
tags.key + tags.type  检索   → v1 mapping 命中   0 ；v2 mapping 命中 732   ← Jaeger 不走这条路径
```

因此**无需 reindex**。若出于其他目的确实要统一 mapping，reindex 也是可行的（732 条 `failures: 0`），但对查询功能没有增益。

## 4. 推荐方案

**把 Mesh v1 的历史日期索引挂载到 Mesh v2 Jaeger 的 `*-read` 别名上，并为其单独配置一份只含 `delete` 阶段的 ILM 策略。**

```
                       ┌─ acp-<prefix>-jaeger-span-write ─→ acp-<prefix>-jaeger-span-000001 ─┐
Jaeger v2 写入 ────────┘                                                                      │ jaeger-ilm-policy
                                                                                              │ (rollover + delete)
                       ┌─ acp-<prefix>-jaeger-span-read ──┬─ acp-<prefix>-jaeger-span-000001 ─┘
Jaeger v2 查询 ────────┘                                  │
                                                          └─ asm-mesh-<meshID>-jaeger-span-2026-09-xx
                                                             (Mesh v1 历史索引，只读)
                                                             jaeger-legacy-ilm-policy (仅 delete)
```

选择理由：

- **零数据搬迁**：不 reindex、不重命名、不改 mapping，历史索引原地只读复用，失败可秒级回退（摘别名即可）。
- **查询连续**：新旧数据在同一个 Jaeger UI 中检索，用户无需切换到旧 UI；别名轮转下不受 `max_span_age` 限制，历史数据可查到索引被删除为止。
- **与官方升级路径一致**：这正是 `distributed-tracing-docs` 中 `upgrading-distributed-tracing-opensearch.mdx`「Attach the existing date-suffixed indices to the read alias」所用的手法，只是把「同一部署的旧日期索引」换成了「Mesh v1 的旧日期索引」。
- **写入天然隔离**：ES rollover 别名要求 `is_write_index` 唯一，历史索引只挂 read 别名，不可能被写入。

## 5. 实测验证

所有实验在 global 集群完成：以 `<registry-address>/asm/jaeger:2.20.0-2.1.0-r0` 镜像独立部署 Jaeger v2.20（不经 Operator），指向平台 ES。

测试数据：`demo-meshv1` 命名空间下 `asm-client` / `asm-first-server` / `asm-second-server` 三个服务产生的真实调用链；另构造一批 10 天前的历史数据（时间戳前移 864000s、traceID 前缀改写、服务名改为 `legacy-only-svc.demo-meshv1`），落在 `asm-mesh-mesh-global-jaeger-span-2026-09-06` 中，用于验证历史深度。

### 5.1 POC-A：Jaeger v2 直接指向 v1 索引前缀

配置 `index_prefix: asm-mesh-mesh-global` + 默认时间索引轮转 + `create_mappings: false`。

| 查询 | 结果 |
| :--- | :--- |
| `GET /api/services` | ✅ `["asm-client.demo-meshv1","asm-first-server.demo-meshv1","asm-second-server.demo-meshv1"]` |
| `GET /api/operations?service=asm-second-server.demo-meshv1` | ✅ 返回 `asm-second-server.demo-meshv1.svc.cluster.local:80/*` |
| `GET /api/traces?service=asm-client.demo-meshv1` | ✅ 3 条 trace，每条 6 个 span、3 个 process |
| `GET /api/traces/<traceID>` | ✅ 6 个 span |
| span 标签检索 `{"http.status_code":"200"}` | ✅ 命中；`{"http.status_code":"599"}` 正确返回 0 |
| process 标签检索 `{"cluster.name":"global"}` | ✅ 命中 |
| `GET /api/dependencies` | 空（Mesh v1 未启用依赖分析，无 dependencies 索引，符合预期） |

**限制**：时间索引轮转下 `max_span_age`（v1 为 168h）仍然生效，会限制"不带显式时间范围"的查询——服务列表与 traceID 精确查询。实测 `max_span_age=168h` 时 10 天前的 `legacy-only-svc` 不出现在服务列表中、traceID 查询返回 404；调到 `720h` 后两者立即恢复正常。

该方案要为旧前缀单独跑一个 Jaeger v2 实例，用户仍需切换 UI，**不推荐**，仅作为兼容性佐证。

### 5.2 POC-B：v2 前缀 + rollover 别名 + 挂载历史索引（推荐方案）

配置 `index_prefix: acp-global` + `rotation.auto_rollover` + `create_mappings: false`，并把历史索引挂到 `acp-global-jaeger-{span,service}-read`。

| 验证项 | 结果 |
| :--- | :--- |
| 服务列表含历史服务 | ✅ `["jaeger","asm-client.demo-meshv1","asm-first-server.demo-meshv1","asm-second-server.demo-meshv1","legacy-only-svc.demo-meshv1"]` |
| 10 天前的 traceID 精确查询 | ✅ 6 个 span（POC-A 在 `max_span_age=168h` 下为 404） |
| 10 天前的 trace 搜索（显式 `start`=now-11d） | ✅ 5 条；`start`=now-7d 正确返回 0 |
| 新数据写入位置 | ✅ 仅 `acp-global-jaeger-span-000001`（`is_write_index: true`）；历史索引中 `process.serviceName=jaeger` 的新 span 数为 **0** |
| v1 索引模板是否被改写 | ✅ 未改写，`tags` 字段仍为 `["key","tagType","value"]`（`create_mappings: false` 生效） |
| v1 索引是否被附加 ILM | ✅ 未附加，`index.lifecycle` 为 `null` |
| v2 写索引 ILM 状态 | ✅ `jaeger-ilm-policy` / `hot` / `rollover` / 无报错 |

> **注意**：Jaeger v2 的 HTTP API 会**忽略 `lookback` 查询参数**，改用固定默认窗口；Jaeger UI 实际发送的是显式 `start`/`end`。用 curl 验证历史数据时必须传显式 `start`/`end`，否则会误判为"查不到"。

### 5.3 ILM 实验：v2 策略无法管理历史索引

构造与 v1 同构的日期索引，逐级施加策略：

| 实验 | 操作 | 结果 |
| :--- | :--- | :--- |
| ILM-1 | `PUT <idx>/_settings {"index.lifecycle.name":"jaeger-ilm-policy"}` | ❌ 卡在 `hot/rollover/check-rollover-ready` 反复重试：<br>`setting [index.lifecycle.rollover_alias] for index [...] is empty or not defined` |
| ILM-2 | 追加 `"index.lifecycle.rollover_alias":"acp-global-jaeger-span-write"` 并 `_ilm/retry` | ❌ 仍失败：<br>`index.lifecycle.rollover_alias [acp-global-jaeger-span-write] does not point to index [...]` |
| ILM-3 | 另建只含 `delete` 阶段的 `jaeger-legacy-ilm-policy` 并施加 | ✅ `managed=true` → `new` → `delete` → 索引被删除，且**别名成员自动移除** |
| ILM-4 | `PUT /asm-mesh-mesh-global-jaeger-*/_settings` 通配符批量挂载 delete-only 策略 | ✅ 5 个索引全部 `managed=true`，无报错 |

**根因**：`jaeger-ilm-policy` 的 hot 阶段带 `rollover` 动作，而 ES 的 rollover 要求索引必须是某个 rollover 别名的写索引（`is_write_index: true`）。历史日期索引不满足，也不应该满足——让它成为写索引就意味着把 v2 格式的新数据写进 v1 mapping 的索引里。因此**历史索引必须用独立的 delete-only 策略**，这不是缺陷，是设计使然。

### 5.4 index-cleaner 路线验证

Jaeger v2.20 的 `jaeger-es-index-cleaner` 同样可用于历史索引。构造三个同前缀日期索引运行 `NUM_OF_DAYS=0`：

| 索引 | 别名情况 | 结果 |
| :--- | :--- | :--- |
| `poccl-jaeger-span-2026-09-01` | 无别名 | 删除 |
| `poccl-jaeger-span-2026-09-02` | 挂 **read** 别名 | **删除** |
| `poccl-jaeger-span-2026-09-03` | 挂 **write** 别名 | **保留** |

两个关键结论：
1. **挂了 read 别名不影响清理**，所以本方案的别名挂载与 index-cleaner 保留机制可以共存。
2. **write 别名索引被跳过**，所以清理器绝不会误删 Mesh v2 正在写的 `-000001` 索引。

另外，清理日志 `Indices before this date will be deleted / CreationTime: ...` 表明 **v2.20 的清理器按索引创建时间筛选，而非索引名里的日期**——与 ILM 的 `min_age` 基准一致。对按天创建的索引两者等价。

## 6. 实施步骤

变量约定（在目标集群执行）：

```bash
export ES_ENDPOINT="<address>"
export ES_USER="<user>"
export ES_PASS="<password>"

# Mesh v1 旧索引前缀：等于 Jaeger CR 的 spec.storage.options["es.index-prefix"]
export LEGACY_PREFIX="asm-mesh-mesh-global"
# Mesh v2 新索引前缀：等于 Jaeger v2 的 indices.index_prefix
export JAEGER_ES_INDEX_PREFIX="acp-global"
# Mesh v1 的保留天数：等于 Jaeger CR 的 spec.storage.esIndexCleaner.numberOfDays
export LEGACY_RETENTION_DAYS="7"
```

### 6.1 前置检查

```bash
# 1. 确认新旧 Jaeger 指向同一个 ES（两条输出必须一致）
kubectl -nistio-system get jaeger jaeger-prod \
  -o jsonpath='{.spec.storage.options.es\.server-urls}{"\n"}'
kubectl -njaeger-system get opentelemetrycollector jaeger \
  -o jsonpath='{.spec.config.extensions.jaeger_storage.backends.es_storage.elasticsearch.server_urls[0]}{"\n"}'

# 2. 读取旧前缀与保留天数并记录
kubectl -nistio-system get jaeger jaeger-prod \
  -o jsonpath='{.spec.storage.options.es\.index-prefix}{"\t"}{.spec.storage.esIndexCleaner.numberOfDays}{"\n"}'

# 3. 盘点历史索引规模（决定是否需要限制挂载范围）
curl -k -sS -u "${ES_USER}:${ES_PASS}" \
  "${ES_ENDPOINT}/_cat/indices/${LEGACY_PREFIX}-jaeger-*?v&h=index,docs.count,store.size,pri&s=index"
```

### 6.2 部署 Mesh v2 的 Jaeger v2

按 `distributed-tracing-docs` 的 `installing-distributed-tracing-elasticsearch.mdx` 正常安装，无需为本方案做任何特殊改动。只需确认两点：

- `create_mappings: false`（安装文档默认如此）。**这一项必须保证**：若为 `true`，Jaeger 启动时会重写索引模板，把模板里的 read 别名和 ILM rollover 别名一起抹掉，写入仍然成功，直到第一次 rollover 才暴露问题。
- 四类索引均使用 `rotation.auto_rollover: {}`。

### 6.3 挂载历史索引到 read 别名

在 Jaeger v2 跑起来、`*-read` / `*-write` 别名已由 `jaeger-es-rollover init` 创建之后执行：

```bash
for TYPE in span service dependencies sampling; do
  echo -n "${TYPE}: "
  curl -k -sS -u "${ES_USER}:${ES_PASS}" -X POST \
    "${ES_ENDPOINT}/_aliases" -H 'Content-Type: application/json' \
    -d "{\"actions\":[{\"add\":{\"index\":\"${LEGACY_PREFIX}-jaeger-${TYPE}-2*\",\"alias\":\"${JAEGER_ES_INDEX_PREFIX}-jaeger-${TYPE}-read\"}}]}"
  echo
done
```

说明：

- `-2*` 只匹配日期索引（`-2026-09-16`），不会匹配 rollover 的 `-000001` 编号索引。
- Mesh v1 通常只有 span 和 service 两类索引，`dependencies` 与 `sampling` 会返回 `index_not_found_exception`，属正常。
- 若历史索引很多而只需保留近期若干天，把 `-2*` 换成具体日期模式（如 `-2026-09-1*`）按需挂载。read 别名下的每个索引都会参与查询扫描，挂得越多查询越慢。

### 6.4 校验

```bash
# 别名成员应同时包含 -000001 与历史日期索引
curl -k -sS -u "${ES_USER}:${ES_PASS}" \
  "${ES_ENDPOINT}/_cat/aliases/${JAEGER_ES_INDEX_PREFIX}-jaeger-*?v&h=alias,index,is_write_index&s=alias"

# 起一个本地端口转发访问 Jaeger 查询 API
kubectl -njaeger-system port-forward deploy/jaeger-collector 16686:16686 &

# 历史服务应出现在服务列表中
curl -s http://127.0.0.1:16686/api/services

# 历史 trace 搜索：必须用显式 start/end（微秒），lookback 参数不生效
NOW=$(( $(date +%s) * 1000000 ))
curl -s "http://127.0.0.1:16686/api/traces?service=<历史服务名>&limit=5&start=$(( NOW - 7*86400*1000000 ))&end=${NOW}"
```

界面上打开 Jaeger UI，确认一个"迁移前最后上报"的服务仍可检索到调用链，即说明历史索引已通过 read 别名接通。

### 6.5 接管历史索引的保留策略 ⚠️ 必做

Mesh v1 的 `jaeger-prod-es-index-cleaner` CronJob 的 `ownerReferences` 指向 `Jaeger/jaeger-prod`，**Mesh v1 下线删除 asm CR 时会被级联回收**。若不接管，历史索引将永久堆积。二选一：

#### 方案 A：delete-only ILM 策略（推荐）

纯 ES 侧操作，无需 CronJob，与 Mesh v2 的 ILM 心智一致。

```bash
# 1. 创建只含 delete 阶段的策略，min_age 对齐 Mesh v1 原保留天数
curl -k -sS -u "${ES_USER}:${ES_PASS}" -X PUT \
  "${ES_ENDPOINT}/_ilm/policy/jaeger-legacy-ilm-policy" \
  -H 'Content-Type: application/json' --data-binary @- << EOF
{
  "policy": {
    "phases": {
      "delete": {
        "min_age": "${LEGACY_RETENTION_DAYS}d",
        "actions": { "delete": {} }
      }
    }
  }
}
EOF

# 2. 批量施加到历史索引族
curl -k -sS -u "${ES_USER}:${ES_PASS}" -X PUT \
  "${ES_ENDPOINT}/${LEGACY_PREFIX}-jaeger-*/_settings" \
  -H 'Content-Type: application/json' \
  -d '{"index.lifecycle.name":"jaeger-legacy-ilm-policy"}'

# 3. 确认全部 managed 且无 ERROR（ILM 默认 10 分钟轮询一次）
curl -k -sS -u "${ES_USER}:${ES_PASS}" \
  "${ES_ENDPOINT}/${LEGACY_PREFIX}-jaeger-*/_ilm/explain?pretty" \
  | grep -E '"index"|"managed"|"phase"|"step"|"reason"'
```

注意事项：
- **`min_age` 以索引创建时间为基准**，不是索引名里的日期，也不是数据时间戳。对按天创建的 v1 索引两者等价；若历史索引曾被 reindex/restore 过，创建时间会被刷新，需要重新评估。
- 策略**不能**含 `rollover` 动作，否则必然 ERROR（见 5.3）。
- 建议在 **Mesh v1 完全下线之后**再执行，避免 Jaeger 1.60 重启时重写索引模板带来的干扰。
- 索引被 ILM 删除后，read 别名成员会自动移除，无需手工维护。

#### 方案 B：沿用 index-cleaner CronJob

与 Mesh v1 的行为完全一致，适合希望保持原有运维习惯的场景。用 Jaeger v2 插件提供的镜像，指向旧前缀：

```bash
export JAEGER_ES_INDEX_CLEANER_IMAGE=$(kubectl -ncpaas-system get configmap jaeger-cluster-plugin-manifest \
  -o jsonpath='{.data.jaeger-es-index-cleaner-image}')

kubectl apply -n jaeger-system -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: jaeger-legacy-es-index-cleaner
spec:
  schedule: "55 23 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: cleaner
            image: "${JAEGER_ES_INDEX_CLEANER_IMAGE}"
            args: ["${LEGACY_RETENTION_DAYS}", "${ES_ENDPOINT}"]
            env:
            - {name: INDEX_PREFIX,           value: "${LEGACY_PREFIX}"}   # 指向旧前缀
            - {name: ES_TLS_ENABLED,         value: "true"}
            - {name: ES_TLS_SKIP_HOST_VERIFY, value: "true"}
            - {name: ES_USERNAME,            value: "${ES_USER}"}
            - name: ES_PASSWORD
              valueFrom: {secretKeyRef: {name: es-credentials, key: ES_PASS}}
          restartPolicy: Never
EOF
```

该清理器跳过挂在 write 别名上的索引，不会误删 Mesh v2 的 `-000001`（见 5.4）。

### 6.6 收尾

历史索引全部过期后：

```bash
# 1. 确认已无历史索引
curl -k -sS -u "${ES_USER}:${ES_PASS}" \
  "${ES_ENDPOINT}/_cat/indices/${LEGACY_PREFIX}-jaeger-*?h=index&s=index"

# 2. 清理残留资源
curl -k -sS -u "${ES_USER}:${ES_PASS}" -X DELETE "${ES_ENDPOINT}/_ilm/policy/jaeger-legacy-ilm-policy"   # 方案 A
kubectl -njaeger-system delete cronjob jaeger-legacy-es-index-cleaner                                     # 方案 B
curl -k -sS -u "${ES_USER}:${ES_PASS}" -X DELETE "${ES_ENDPOINT}/_index_template/${LEGACY_PREFIX}-jaeger-span"
curl -k -sS -u "${ES_USER}:${ES_PASS}" -X DELETE "${ES_ENDPOINT}/_index_template/${LEGACY_PREFIX}-jaeger-service"
```

## 7. 风险与注意事项

| # | 项 | 说明与应对 |
| :-- | :--- | :--- |
| 1 | **`create_mappings` 必须为 `false`** | 为 `true` 时 Jaeger 启动会重写索引模板，抹掉 read 别名与 ILM rollover 别名。写入仍成功，直到第一次 rollover 才暴露为"新数据查不到"。若误触，重跑 `jaeger-es-rollover init` 恢复模板 |
| 2 | **查询成本上升** | 别名轮转下 Jaeger 不做 `max_span_age` 裁剪，每次查询扫描 read 别名下的全部索引。历史索引多时按需挂载（限定日期模式），不要无脑 `-2*` |
| 3 | **shard 配额** | v1 索引为 5 shard × 1 replica，一天一套。若保留期长、集群小，挂载前先核对 ES 的 shard 上限 |
| 4 | **保留基准是索引创建时间** | ILM `min_age` 与 v2 index-cleaner 都按索引创建时间判定，不看索引名。reindex/restore 过的索引会被"续命" |
| 5 | **不要让历史索引成为写索引** | 那会把 v2 格式数据写进 v1 mapping 的索引（`scopeTags`、`references.traceState` 等字段无映射）。read 别名挂载天然规避 |
| 6 | **多集群前缀规划** | Mesh v1 按 meshID 分前缀（`asm-mesh-<meshID>`），一个网格内多集群共用一套索引；Mesh v2 安装文档默认按集群（`acp-<cluster>`）。若 v2 按集群拆前缀，一个网格的历史数据只有一份，挂到哪个集群的 read 别名需要额外决策。**建议 v2 也按 meshID 用统一前缀**（与 `My-TODO.md` 的结论一致） |
| 7 | **依赖图不回溯** | Mesh v1 未启用依赖分析（`storage.dependencies.enabled: false`），无 dependencies 索引，Jaeger UI 的 System Architecture 对历史时段为空。这是 v1 侧的既有状态，非迁移引入 |
| 8 | **Mesh v1 存活期间的干扰** | Jaeger 1.60 重启会重写 `asm-mesh-*` 索引模板。建议在 Mesh v1 完全下线后再施加 delete-only ILM 策略 |
| 9 | **验证时的 `lookback` 陷阱** | Jaeger v2 HTTP API 忽略 `lookback`，用固定默认窗口。curl 验证历史数据必须传显式 `start`/`end`（微秒），否则会误判 |

## 8. 回滚

本方案对历史数据是只读的，回滚无数据损失：

```bash
# 1. 摘除 read 别名挂载（Jaeger v2 立即回到只看新数据的状态）
for TYPE in span service; do
  curl -k -sS -u "${ES_USER}:${ES_PASS}" -X POST "${ES_ENDPOINT}/_aliases" \
    -H 'Content-Type: application/json' \
    -d "{\"actions\":[{\"remove\":{\"index\":\"${LEGACY_PREFIX}-jaeger-${TYPE}-2*\",\"alias\":\"${JAEGER_ES_INDEX_PREFIX}-jaeger-${TYPE}-read\"}}]}"
done

# 2. 摘除 delete-only ILM 策略（历史索引恢复为无保留策略，不会被自动删除）
curl -k -sS -u "${ES_USER}:${ES_PASS}" -X PUT \
  "${ES_ENDPOINT}/${LEGACY_PREFIX}-jaeger-*/_settings" \
  -H 'Content-Type: application/json' -d '{"index.lifecycle.name":null}'
```

若已执行到 Mesh v1 下线，历史数据仍可通过临时部署一个只读 Jaeger v2 实例（`index_prefix` 指向旧前缀，`max_span_age` 调到覆盖保留期，见 5.1 POC-A）单独查询。

## 9. 未采用的方案

| 方案 | 不采用的原因 |
| :--- | :--- |
| reindex 历史数据到 v2 索引族 | 文档格式本就兼容，reindex 对查询功能零增益；且 reindex 后的索引仍无法被含 `rollover` 的 `jaeger-ilm-policy` 管理，问题未解决，反而多一次全量 IO 与一倍存储 |
| 把历史索引设为 rollover 写索引 | 会让 v2 格式的新数据写进 v1 mapping 的索引，`scopeTags`、`references.traceState` 等字段无映射；且 rollover 后旧索引立即脱管，收益为零 |
| 配置为 Jaeger 的 archive storage | archive 只在 traceID 精确查询未命中时兜底，不支持搜索与服务列表，功能覆盖远不及 read 别名挂载 |
| 保留一个只读的 Jaeger 1.60 query 实例 | 需要把整套 `Alauda Build of Jaeger` Operator + CRD 留到保留期结束，与"Mesh v1 全栈下线"冲突；用户还要切换两个 UI |
| 双写（同时写新旧两套索引） | 只解决切换后的数据，不解决切换前的历史数据；且不适用于本场景（v1 collector 随 Mesh v1 一起下线） |
