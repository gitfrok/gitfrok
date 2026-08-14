{{/* T-0031: shared labels for the BYO data-plane chart. */}}
{{- define "gitfrok-dataplane.labels" -}}
app.kubernetes.io/name: gitfrok-dataplane
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "gitfrok-dataplane.selectorLabels" -}}
app.kubernetes.io/name: gitfrok-dataplane
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
