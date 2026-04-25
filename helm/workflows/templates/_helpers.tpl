{{/*
Expand the name of the chart.
*/}}
{{- define "workflows.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "workflows.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "workflows.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "workflows.labels" -}}
helm.sh/chart: {{ include "workflows.chart" . }}
{{ include "workflows.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "workflows.selectorLabels" -}}
app.kubernetes.io/name: {{ include "workflows.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "workflows.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "workflows.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Get the image registry (removes trailing slash if present, then adds one)
*/}}
{{- define "workflows.imageRegistry" -}}
{{- if .Values.global.imageRegistry }}
{{- .Values.global.imageRegistry | trimSuffix "/" }}/
{{- end }}
{{- end }}

{{/*
Get the secrets name
*/}}
{{- define "workflows.secretsName" -}}
{{- if .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- include "workflows.fullname" . }}-secrets
{{- end }}
{{- end }}

{{/*
Database URL
*/}}
{{- define "workflows.databaseUrl" -}}
{{- if .Values.database.external.enabled }}
postgresql://{{ .Values.database.external.username }}:$(DATABASE_PASSWORD)@{{ .Values.database.external.host }}:{{ .Values.database.external.port }}/{{ .Values.database.external.database }}?sslmode={{ .Values.database.external.sslMode }}
{{- end }}
{{- end }}

