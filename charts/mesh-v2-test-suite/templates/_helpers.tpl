{{- define "mesh-v2-test-suite.name" -}}
mesh-v2-test-suite
{{- end -}}

{{- define "mesh-v2-test-suite.labels" -}}
cpaas.io/module-name: mesh-v2-test-suite
cpaas.io/module-type: plugin
app.kubernetes.io/name: mesh-v2-test-suite
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
镜像清单从 .Values.global.images 动态生成，每行一个 registry/repository:tag 完整地址。
新增或调整镜像时只需修改 values.yaml 的 global.images，无需改动模板。
registry 地址来自 .Values.global.registry.address，在 ACP 安装时由 plugin-config.yaml
的 valuesTemplates 重写为平台内置镜像仓库，因此运行时这里的地址就是用户可拉取的地址。
*/}}
{{- define "mesh-v2-test-suite.imageList" -}}
{{- $registry := .Values.global.registry.address -}}
{{- $items := list -}}
{{- range $name, $img := .Values.global.images -}}
{{- $items = append $items (printf "%s/%s:%s" $registry $img.repository $img.tag) -}}
{{- end -}}
{{ $items | sortAlpha | join "\n" }}
{{- end -}}
