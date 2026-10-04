{{- define "customer-dotnet-sample.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "customer-dotnet-sample.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "customer-dotnet-sample.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "customer-dotnet-sample.labels" -}}
app.kubernetes.io/name: {{ include "customer-dotnet-sample.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
