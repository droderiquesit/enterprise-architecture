{{/*
hello-service helpers. Resource names default to the release name (release name == workload name).
*/}}

{{- define "hello-service.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hello-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hello-service.serviceAccountName" -}}
{{- default (include "hello-service.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{- define "hello-service.image" -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- end -}}

{{- define "hello-service.isHttp" -}}
{{- if eq .Values.kind "deployment" }}true{{ end -}}
{{- end -}}

{{- define "hello-service.portName" -}}
{{- if eq .Values.kind "worker" }}health{{ else }}http{{ end -}}
{{- end -}}

{{/* Selector labels: ONLY app.kubernetes.io/name (immutable selector; matches pre-Helm objects for adoption). */}}
{{- define "hello-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hello-service.fullname" . }}
{{- end -}}

{{/* Datadog unified service tagging + ADR-0001 §7 tags (shared by workload metadata and pod template). */}}
{{- define "hello-service.ustLabels" -}}
tags.datadoghq.com/env: {{ .Values.service.env | quote }}
tags.datadoghq.com/service: {{ .Values.service.name | quote }}
tags.datadoghq.com/version: {{ .Values.service.version | quote }}
{{- with .Values.service.team }}
team: {{ . | quote }}
{{- end }}
{{- with .Values.service.domain }}
domain: {{ . | quote }}
{{- end }}
{{- with .Values.service.tier }}
tier: {{ . | quote }}
{{- end }}
{{- with .Values.service.logsSource }}
logs.datadoghq.com/source: {{ . | quote }}
{{- end }}
{{- end -}}

{{- define "hello-service.labels" -}}
{{ include "hello-service.selectorLabels" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.service.version | quote }}
app.kubernetes.io/component: {{ .Values.kind }}
app.kubernetes.io/part-of: {{ .Values.service.partOf }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "hello-service.chart" . }}
{{ include "hello-service.ustLabels" . }}
{{- end -}}

{{/* Pod securityContext; OpenShift: the SCC assigns UID/GID/fsGroup, never pin them. */}}
{{- define "hello-service.podSecurityContext" -}}
{{- $psc := deepCopy .Values.podSecurityContext -}}
{{- if .Values.openshift.enabled -}}
{{- $psc = omit $psc "runAsUser" "runAsGroup" "fsGroup" "fsGroupChangePolicy" -}}
{{- end -}}
{{- toYaml $psc -}}
{{- end -}}

{{/* secretsMode=synced: secretEnv is read from the Kubernetes Secret maintained by the Delinea dsv-k8s syncer. */}}
{{- define "hello-service.syncedSecretName" -}}
{{- default (printf "%s-dsv" (include "hello-service.fullname" .)) .Values.secretsSync.secretName -}}
{{- end -}}

{{/*
Container env. Order matters: DD_AGENT_HOST first so later values can use $(DD_AGENT_HOST).
Chart-owned keys next (incl. the DSV runtime env), then the sorted env, then secret settings: in the default
secretsMode=dsv their VALUE is the dsv:// reference the app resolves at start-up with its workload identity;
in secretsMode=synced they come from the dsv-k8s syncer Secret via secretKeyRef. Never secret values.
*/}}
{{- define "hello-service.env" -}}
{{- if .Values.telemetry.agentHostFromHostIP }}
- name: DD_AGENT_HOST
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
{{- end }}
- name: DD_ENV
  value: {{ .Values.service.env | quote }}
- name: DD_SERVICE
  value: {{ .Values.service.name | quote }}
- name: DD_VERSION
  value: {{ .Values.service.version | quote }}
- name: AZURE_CLIENT_ID
  value: {{ .Values.identity.clientId | quote }}
- name: FAULTS_ENABLED
  value: {{ ternary "true" "false" .Values.faults.enabled | quote }}
{{- with .Values.dsv }}
{{- if .tenant }}
- name: DSV_TENANT
  value: {{ .tenant | quote }}
{{- end }}
{{- if .tld }}
- name: DSV_TLD
  value: {{ .tld | quote }}
{{- end }}
{{- if .baseUrl }}
- name: DSV_BASE_URL
  value: {{ .baseUrl | quote }}
{{- end }}
- name: DSV_AUTH
  value: {{ default "azure" .auth | quote }}
{{- end }}
{{- if ne .Values.kind "cronjob" }}
- name: PORT
  value: {{ .Values.port | quote }}
{{- end }}
{{- if .Values.logFile.enabled }}
- name: LOG_FILE_PATH
  value: {{ .Values.logFile.path | quote }}
{{- end }}
{{- range $k := keys .Values.env | sortAlpha }}
- name: {{ $k }}
  value: {{ index $.Values.env $k | quote }}
{{- end }}
{{- range $k := keys .Values.secretEnv | sortAlpha }}
- name: {{ $k }}
{{- if eq $.Values.secretsMode "synced" }}
  valueFrom:
    secretKeyRef:
      name: {{ include "hello-service.syncedSecretName" $ }}
      key: {{ $k }}
{{- else }}
  value: {{ index $.Values.secretEnv $k | quote }}
{{- end }}
{{- end }}
{{- range $k := keys .Values.existingSecretEnv | sortAlpha }}
{{- $ref := index $.Values.existingSecretEnv $k }}
- name: {{ $k }}
  valueFrom:
    secretKeyRef:
      name: {{ $ref.secretName }}
      key: {{ $ref.key }}
{{- end }}
{{- end -}}

{{/* Pod template (shared by Deployment and CronJob). */}}
{{- define "hello-service.podTemplate" -}}
{{- $name := include "hello-service.fullname" . -}}
{{- $port := include "hello-service.portName" . -}}
metadata:
  labels:
    {{- include "hello-service.labels" . | nindent 4 }}
    {{- if .Values.identity.workloadIdentity }}
    azure.workload.identity/use: "true"
    {{- end }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- if or .Values.telemetry.disableAgentLogCollection .Values.podAnnotations }}
  annotations:
    {{- if .Values.telemetry.disableAgentLogCollection }}
    # Logs are collected by the Fluent Bit DaemonSet only; the Datadog Agent must not ship them too.
    ad.datadoghq.com/{{ $name }}.logs: "[]"
    {{- end }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
spec:
  serviceAccountName: {{ include "hello-service.serviceAccountName" . }}
  # Projected service account token only where workload identity needs it.
  automountServiceAccountToken: {{ .Values.identity.workloadIdentity }}
  enableServiceLinks: false
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  {{- if eq .Values.kind "cronjob" }}
  restartPolicy: Never
  {{- end }}
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- include "hello-service.podSecurityContext" . | nindent 4 }}
  {{- if and .Values.topologySpread.enabled (ne .Values.kind "cronjob") }}
  topologySpreadConstraints:
    - maxSkew: {{ .Values.topologySpread.hostnameSkew }}
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          {{- include "hello-service.selectorLabels" . | nindent 10 }}
    {{- if .Values.topologySpread.zoneSpread }}
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          {{- include "hello-service.selectorLabels" . | nindent 10 }}
    {{- end }}
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: {{ $name }}
      image: {{ include "hello-service.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- with .Values.command }}
      command:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.args }}
      args:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if ne .Values.kind "cronjob" }}
      ports:
        - name: {{ $port }}
          containerPort: {{ .Values.port }}
          protocol: TCP
      {{- end }}
      env:
        {{- include "hello-service.env" . | trim | nindent 8 }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      {{- if ne .Values.kind "cronjob" }}
      {{- if .Values.probes.startup.enabled }}
      startupProbe:
        httpGet:
          path: {{ .Values.probes.startup.path }}
          port: {{ $port }}
        periodSeconds: {{ .Values.probes.startup.periodSeconds }}
        failureThreshold: {{ .Values.probes.startup.failureThreshold }}
      {{- end }}
      livenessProbe:
        httpGet:
          path: {{ .Values.probes.liveness.path }}
          port: {{ $port }}
        periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.liveness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.liveness.failureThreshold }}
      readinessProbe:
        httpGet:
          path: {{ .Values.probes.readiness.path }}
          port: {{ $port }}
        periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.readiness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.readiness.failureThreshold }}
      {{- end }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        {{- if .Values.logFile.enabled }}
        - name: app-logs
          mountPath: {{ dir .Values.logFile.path }}
        {{- end }}
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: {{ .Values.tmp.sizeLimit }}
    {{- if .Values.logFile.enabled }}
    - name: app-logs
      emptyDir:
        sizeLimit: {{ .Values.logFile.sizeLimit }}
    {{- end }}
{{- end -}}

{{/* Fail fast on cross-field rules the JSON schema cannot express. */}}
{{- define "hello-service.validate" -}}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) -}}
{{- fail "autoscaling.minReplicas must be <= autoscaling.maxReplicas" -}}
{{- end -}}
{{- if and .Values.ingress.enabled (ne .Values.kind "deployment") -}}
{{- fail "ingress.enabled is only valid for kind=deployment" -}}
{{- end -}}
{{- if and .Values.openshift.route.enabled (ne .Values.kind "deployment") -}}
{{- fail "openshift.route.enabled is only valid for kind=deployment" -}}
{{- end -}}
{{- if and (eq .Values.secretsMode "dsv") (gt (len .Values.secretEnv) 0) (not .Values.dsv.baseUrl) (not .Values.dsv.tenant) -}}
{{- fail "secretEnv (dsv:// references) needs dsv.tenant or dsv.baseUrl so the app can reach Delinea DSV" -}}
{{- end -}}
{{- if and (eq .Values.secretsMode "dsv") (gt (len .Values.secretEnv) 0) (not .Values.identity.workloadIdentity) -}}
{{- fail "secretsMode=dsv needs identity.workloadIdentity=true (the app authenticates to DSV with its workload identity); use secretsMode=synced otherwise" -}}
{{- end -}}
{{- end -}}
