{{/*
Expand the name of the chart.
*/}}
{{- define "blue-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.

We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec). If release name contains chart name it will be used as a full name.
*/}}
{{- define "blue-agent.fullname" -}}
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
{{- define "blue-agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "blue-agent.labels" -}}
helm.sh/chart: {{ include "blue-agent.chart" . }}
app.kubernetes.io/component: agent
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
{{ include "blue-agent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "blue-agent.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "blue-agent.name" . }}
{{- end }}

{{/*
Create the name of the ServiceAccount to use.
*/}}
{{- define "blue-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "blue-agent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the Secret to use.
*/}}
{{- define "blue-agent.secretName" -}}
{{- if .Values.secret.create }}
{{- default (include "blue-agent.fullname" .) .Values.secret.name }}
{{- else }}
{{- default "default" .Values.secret.name }}
{{- end }}
{{- end }}

{{/*
Default PodSecurytyContext object to apply to containers.

Can be overriden by setting ".Values.podSecurityContext".

See: https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.27/#podsecuritycontext-v1-core
*/}}
{{- define "blue-agent.defaultPodSecurityContext" -}}
# All volumes are owned bu group 0 (root), same as the default user
fsGroup: 0
{{- end }}

{{/*
Default SecurytyContext object to apply to containers.

Can be overriden by setting ".Values.securityContext".

See: https://kubernetes.io/docs/concepts/windows/intro/#compatibility-v1-pod-spec-containers
*/}}
{{- define "blue-agent.defaultSecurityContext" -}}
runAsNonRoot: false
readOnlyRootFilesystem: false
{{- if .Values.image.isWindows }}
windowsOptions:
  runAsUserName: ContainerAdministrator
{{- else }}
allowPrivilegeEscalation: false
runAsUser: 0
capabilities:
  # Add enough default capabilities to allow the agent to unzip files and change file ownership
  # See: https://github.com/clemlesne/blue-agent/issues/23#issuecomment-2444929885
  add:
    - CHOWN
    - FOWNER
  # Remove all default root capabilities to ensure the container is running with the least privileges
  drop: ["ALL"]
{{- end }}
{{- end }}

{{/*
Common definition for Pod object.

Usage example:

{{- $data := dict
  "azpAgentName" (dict "value" (include "blue-agent.fullname" .))
  "isTemplateJob" "1"
  "restartPolicy" "Always"
}}
{{- include "blue-agent.podSharedTemplate" (merge (dict "Args" $data) . ) | nindent 6 }}
*/}}
{{- define "blue-agent.podSharedTemplate" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
serviceAccountName: {{ include "blue-agent.serviceAccountName" . }}
securityContext:
  {{- toYaml (mustMergeOverwrite (include "blue-agent.defaultPodSecurityContext" . | fromYaml) .Values.podSecurityContext) | nindent 2 }}
{{- with .Values.initContainers }}
initContainers:
  {{- toYaml . | nindent 2 }}
{{- end }}
terminationGracePeriodSeconds: {{ .Values.pipelines.timeout | int | required "A value for .Values.pipelines.timeout is required" }}
restartPolicy: {{ .Args.restartPolicy }}
containers:
  {{- if .Values.sidecarContainers -}}
  {{- toYaml .Values.sidecarContainers | trim | nindent 2 }}
  {{- end}}
  - name: azp-agent
    securityContext:
      {{- toYaml (mustMergeOverwrite (include "blue-agent.defaultSecurityContext" . | fromYaml) .Values.securityContext) | nindent 6 }}
    image: "{{ .Values.image.repository | required "A value for .Values.image.repository is required" }}:{{ .Values.image.flavor | required "A value for .Values.image.flavor is required" }}-{{ default .Chart.Version .Values.image.version }}"
    imagePullPolicy: {{ .Values.image.pullPolicy }}
    {{- if .Values.image.isWindows }}
    {{- if not .Values.pipelines.cache.volumeEnabled }}
    lifecycle:
      preStop:
        exec:
          command:
            - powershell
            - -Command
            - |
              # For security reasons, force clean the pipeline workspace at restart -- Sharing data bewteen pipelines is a security risk
              Remove-Item -Recurse -Force $Env:AZP_WORK;
    {{- end }}
    {{- else if or (not .Values.pipelines.cache.volumeEnabled) (not .Values.pipelines.tmpdir.volumeEnabled)}}
    lifecycle:
      preStop:
        exec:
          command:
            {{- if not .Values.pipelines.cache.volumeEnabled }}
            - bash
            - -c
            - |
              # For security reasons, force clean the pipeline workspace at restart -- Sharing data bewteen pipelines is a security risk
              rm -rf ${AZP_WORK};
            {{- end }}
            {{- if not .Values.pipelines.tmpdir.volumeEnabled }}
            - bash
            - -c
            - |
              # For security reasons, force clean the tmpdir at restart -- Sharing data bewteen pipelines is a security risk
              rm -rf ${TMPDIR};
            {{- end }}
    {{- end }}
    env:
      - name: AGENT_DIAGLOGPATH
        {{- if .Values.image.isWindows }}
        value: C:\\app-root\\azp-logs
        {{- else }}
        value: /app-root/azp-logs
        {{- end }}
      - name: VSO_AGENT_IGNORE
        value: AZP_TOKEN
      {{- if not .Values.image.isWindows }}
      - name: AGENT_ALLOW_RUNASROOT
        value: "1"
      {{- end }}
      - name: AZP_AGENT_NAME
        {{- toYaml .Args.azpAgentName | nindent 8 }}
      - name: AZP_URL
        valueFrom:
          secretKeyRef:
            name: {{ include "blue-agent.secretName" . }}
            key: organizationURL
      - name: AZP_POOL
        value: {{ .Values.pipelines.poolName | quote | required "A value for .Values.pipelines.poolName is required" }}
      - name: AZP_TOKEN
        valueFrom:
          secretKeyRef:
            name: {{ include "blue-agent.secretName" . }}
            key: personalAccessToken
      - name: AZP_TEMPLATE_JOB
        value: {{ .Args.isTemplateJob }}
      # Agent capabilities
      - name: flavor_{{ .Values.image.flavor | required "A value for .Values.image.flavor is required" }}
      - name: version_{{ default .Chart.Version .Values.image.version }}
      {{- range .Values.pipelines.capabilities }}
      - name: {{ . }}
      {{- end }}
      {{- with .Values.extraEnv }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    resources:
      {{- toYaml .Values.resources | nindent 6 | required "A value for .Values.resources is required" }}
    volumeMounts:
      - name: azp-logs
        {{- if .Values.image.isWindows }}
        mountPath: C:\\app-root\\azp-logs
        {{- else }}
        mountPath: /app-root/azp-logs
        {{- end }}
      - name: azp-work
        {{- if .Values.image.isWindows }}
        mountPath: C:\\app-root\\azp-work
        {{- else }}
        mountPath: /app-root/azp-work
        {{- end }}
      {{- if not .Values.image.isWindows }}
      - name: local-tmp
        mountPath: /app-root/.local/tmp
      {{- end }}
      {{- with .Values.extraVolumeMounts }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
volumes:
  - name: azp-logs
    emptyDir:
      sizeLimit: 1Gi
  - name: azp-work
    {{- if .Values.pipelines.cache.volumeEnabled }}
    ephemeral:
      volumeClaimTemplate:
        spec:
          accessModes: [ "ReadWriteOnce" ]
          storageClassName: {{ .Values.pipelines.cache.type | required "A value for .Values.pipelines.cache.type is required" }}
          resources:
            requests:
              storage: {{ .Values.pipelines.cache.size | required "A value for .Values.pipelines.cache.size is required" }}
    {{- else }}
    emptyDir:
      sizeLimit: {{ .Values.pipelines.cache.size | required "A value for .Values.pipelines.cache.size is required" }}
    {{- end }}
  {{- if not .Values.image.isWindows }}
  - name: local-tmp
    {{- if .Values.pipelines.tmpdir.volumeEnabled }}
    ephemeral:
      volumeClaimTemplate:
        spec:
          accessModes: [ "ReadWriteOnce" ]
          storageClassName: {{ .Values.pipelines.tmpdir.type | required "A value for .Values.pipelines.tmpdir.type is required" }}
          resources:
            requests:
              storage: {{ .Values.pipelines.tmpdir.size | required "A value for .Values.pipelines.tmpdir.size is required" }}
    {{- else }}
    emptyDir:
      sizeLimit: {{ .Values.pipelines.tmpdir.size | required "A value for .Values.pipelines.tmpdir.size is required" }}
    {{- end }}
  {{- end }}
  {{- with .Values.extraVolumes }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
nodeSelector:
  {{- if .Values.image.isWindows }}
  kubernetes.io/os: windows
  {{- else }}
  kubernetes.io/os: linux
  {{- end }}
  {{- with .Values.extraNodeSelectors }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
