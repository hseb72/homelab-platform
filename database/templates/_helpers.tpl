{{- define "database.labels" -}}
app.kubernetes.io/part-of: homelab-platform
app.kubernetes.io/component: database
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Référence d'image, tag obligatoire — mieux vaut un rendu qui échoue qu'un pod qui ne démarre pas. */}}
{{- define "database.image" -}}
{{- $tag := required (printf "%s : renseigner le tag de l'image (cf. database/README.md §0)" .Values.postgres.image.repository) .Values.postgres.image.tag -}}
{{- printf "%s:%s" .Values.postgres.image.repository $tag -}}
{{- end -}}

{{- define "database.service" -}}
{{- printf "postgres.%s.svc.cluster.local" .Values.namespace -}}
{{- end -}}
