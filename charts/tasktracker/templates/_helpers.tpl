{{/*
=============================================================================
File        : charts/tasktracker/templates/_helpers.tpl
Assignment  : DSO202 Assignment 4 (from Assignment 3, prefix renamed)
Descriptor  : Unit III 3.2 - Helm named templates
Purpose     : Names, labels and image strings shared by every template. Files
              whose names begin with "_" never produce Kubernetes objects.
=============================================================================
*/}}

{{/* tasktracker.name: chart name, or nameOverride. */}}
{{- define "tasktracker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
tasktracker.fullname: base name of every object (63-character DNS limit).
With release name "tasktracker" and chart name "tasktracker" this is simply
"tasktracker", so objects are tasktracker-db, tasktracker-backend, ...
*/}}
{{- define "tasktracker.fullname" -}}
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

{{/* tasktracker.chart: "<name>-<version>" for the helm.sh/chart label. */}}
{{- define "tasktracker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* tasktracker.environment: required - no object renders without it. */}}
{{- define "tasktracker.environment" -}}
{{- required "environment must be set (dev or staging)" .Values.environment }}
{{- end }}

{{/*
tasktracker.selectorLabels: STABLE labels used by selectors. Never add a
changing label here - Deployment.spec.selector is immutable.
Call with (dict "ctx" $ "component" "backend").
*/}}
{{- define "tasktracker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tasktracker.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- with .component }}
app.kubernetes.io/component: {{ . }}
{{- end }}
{{- end }}

{{/* tasktracker.labels: full recommended label set for every object. */}}
{{- define "tasktracker.labels" -}}
helm.sh/chart: {{ include "tasktracker.chart" .ctx }}
{{ include "tasktracker.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/part-of: tasktracker
dso202/environment: {{ include "tasktracker.environment" .ctx | quote }}
{{- end }}

{{/*
tasktracker.image (C1): "<repository>:<tag>" from one tier's values.
Call with the tier's image map, e.g. (include "tasktracker.image" .Values.backend.image).
Both keys are required: a missing tag must stop rendering, never fall back.
*/}}
{{- define "tasktracker.image" -}}
{{- printf "%s:%s" (required "image.repository is required" .repository) (required "image.tag is required" .tag | toString) }}
{{- end }}

{{/*
tasktracker.env (C2): renders a map of extra environment variables as
name/value pairs, sorted by name so the output is stable between renders.
*/}}
{{- define "tasktracker.env" -}}
{{- range $k, $v := . }}
- name: {{ $k }}
  value: {{ $v | toString | quote }}
{{- end }}
{{- end }}

{{/* Object names. */}}
{{- define "tasktracker.dbName" -}}{{ include "tasktracker.fullname" . }}-db{{- end }}
{{- define "tasktracker.backendName" -}}{{ include "tasktracker.fullname" . }}-backend{{- end }}
{{- define "tasktracker.frontendName" -}}{{ include "tasktracker.fullname" . }}-frontend{{- end }}
{{- define "tasktracker.configName" -}}{{ include "tasktracker.fullname" . }}-config{{- end }}
{{- define "tasktracker.nginxName" -}}{{ include "tasktracker.fullname" . }}-frontend-nginx{{- end }}

{{/* C3: the credentials Secret is always an existing one, never rendered here. */}}
{{- define "tasktracker.secretName" -}}
{{- required "existingSecret must name the Secret created from the SealedSecret" .Values.existingSecret }}
{{- end }}
