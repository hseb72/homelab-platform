{{- define "objectstore.labels" -}}
app.kubernetes.io/part-of: homelab-platform
app.kubernetes.io/component: object-store
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Référence d'image, tag obligatoire — mieux vaut un rendu qui échoue qu'un pod qui ne démarre pas. */}}
{{- define "objectstore.image" -}}
{{- $tag := required (printf "%s : renseigner le tag de l'image (cf. object-store/README.md §0)" .repository) .tag -}}
{{- printf "%s:%s" .repository $tag -}}
{{- end -}}

{{- define "objectstore.minioService" -}}
{{- printf "minio.%s.svc.cluster.local" .Values.namespace -}}
{{- end -}}
