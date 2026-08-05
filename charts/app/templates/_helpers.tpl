{{/*
The convention lives here. Every other template derives its names from these,
so changing a rule changes it everywhere at once.
*/}}

{{- define "app.name" -}}
{{- required "set `name` — it drives the namespace, secret path and ingress" .Values.name -}}
{{- end -}}

{{/* Namespace, app name and Infisical folder are all the same string. */}}
{{- define "app.namespace" -}}
{{- include "app.name" . -}}
{{- end -}}

{{- define "app.secretName" -}}
{{- printf "%s-secrets" (include "app.name" .) -}}
{{- end -}}

{{- define "app.tlsSecretName" -}}
{{- printf "%s-tls" (include "app.name" .) -}}
{{- end -}}

{{/* Infisical folder: /<name> unless explicitly overridden. */}}
{{- define "app.secretsPath" -}}
{{- if .Values.secrets.path -}}
{{- .Values.secrets.path -}}
{{- else -}}
{{- printf "/%s" (include "app.name" .) -}}
{{- end -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
{{- end -}}