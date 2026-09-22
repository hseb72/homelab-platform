{{- define "cache.labels" -}}
app.kubernetes.io/part-of: homelab-platform
app.kubernetes.io/component: cache
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Référence d'image, tag obligatoire — mieux vaut un rendu qui échoue qu'un pod qui ne démarre pas. */}}
{{- define "cache.image" -}}
{{- $tag := required (printf "%s : renseigner le tag de l'image (cf. cache/README.md §0)" .Values.redis.image.repository) .Values.redis.image.tag -}}
{{- printf "%s:%s" .Values.redis.image.repository $tag -}}
{{- end -}}

{{- define "cache.service" -}}
{{- printf "redis.%s.svc.cluster.local" .Values.namespace -}}
{{- end -}}
