{{/* Common labels: every object says which stack, tier and region it belongs to. */}}
{{- define "app.labels" -}}
app.kubernetes.io/part-of: zero-downtime-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
zdp/stack: {{ .Values.stack.name }}
zdp/tier: {{ .Values.stack.tier }}
zdp/region: {{ .Values.stack.region }}
{{- end -}}

{{- define "app.selector" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Values.stack.name }}
{{- end -}}

{{/* Images are always referenced by digest: the promoted artifact is exact. */}}
{{- define "app.image" -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- end -}}

{{- define "app.size" -}}
{{- $s := index .Values.sizes .Values.stack.size -}}
{{- if not $s }}{{ fail (printf "unknown stack.size %q" .Values.stack.size) }}{{ end -}}
{{- toYaml $s -}}
{{- end -}}

{{- define "app.hosts" -}}
{{- if .Values.ingress.hosts -}}
{{- toYaml .Values.ingress.hosts -}}
{{- else -}}
- {{ printf "%s.localtest.me" .Values.stack.name }}
{{- end -}}
{{- end -}}

{{/* nodeSelector + tolerations for one component ("api" | "worker"); with
     nodePool.enabled both are pinned to the stack's own tainted pool. */}}
{{- define "app.scheduling" -}}
{{- $c := index .root.Values .component -}}
{{- $sel := deepCopy ($c.nodeSelector | default dict) -}}
{{- $tol := $c.tolerations | default list -}}
{{- if .root.Values.nodePool.enabled -}}
{{- $_ := set $sel "zdp/tenant" .root.Values.stack.name -}}
{{- $tol = append $tol (dict "key" "zdp/tenant" "operator" "Equal" "value" .root.Values.stack.name "effect" "NoSchedule") -}}
{{- end -}}
{{- with $sel }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $tol }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* "99.95" -> 0.9995 ; error budget = 1 - objective */}}
{{- define "app.objective" -}}
{{- divf (float64 .Values.stack.slo) 100 -}}
{{- end -}}

{{/* Traefik labels each weighted child service <namespace>-<service>-<port>@kubernetescrd. */}}
{{- define "app.traefikServices" -}}
{{- printf "%s-api-(stable|canary)-.*" .Values.stack.namespace -}}
{{- end -}}
{{- define "app.traefikCanary" -}}
{{- printf "%s-api-canary-.*" .Values.stack.namespace -}}
{{- end -}}

{{/* Pod Security "restricted" + read-only root filesystem. */}}
{{- define "app.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop: [ALL]
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "app.podSecurity" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}
