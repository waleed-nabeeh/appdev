{{- define "mofa-dotnet-sample.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mofa-dotnet-sample.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "mofa-dotnet-sample.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mofa-dotnet-sample.labels" -}}
app.kubernetes.io/name: {{ include "mofa-dotnet-sample.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
