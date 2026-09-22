#!/bin/sh
# Création des secrets d'accès CÔTÉ APPLICATION — GABARIT.
#
# Les identifiants sont fournis par l'administrateur du socle au moment du
# provisionnement (cf. la section « Ajouter une application » du README de chaque
# service). La SOURCE DE VÉRITÉ reste le secret de locataires du service ; ici on
# ne fait que redéposer la même valeur, côté application, pour que ses pods la
# lisent.
#
# ⚠ Ne jamais committer ces secrets en clair. Les sceller ensuite avec kubeseal,
# comme le reste du cluster (cf. plus bas).
set -eu

NS=mon-appli

# ── MinIO ────────────────────────────────────────────────────────────────────
# access-key = le NOM du locataire ; secret-key = sa clé (celle du secret
# object-store-tenant-keys). Endpoint : minio.object-store.svc.cluster.local:9000
kubectl -n "$NS" create secret generic object-store-access \
  --from-literal=endpoint=minio.object-store.svc.cluster.local:9000 \
  --from-literal=access-key=mon-appli \
  --from-literal=secret-key="LA_CLE_FOURNIE"

# ── PostgreSQL ───────────────────────────────────────────────────────────────
# user = nom du locataire ; dbname = sa base ; password = clé fournie
# (database-tenant-keys). Hôte : postgres.database.svc.cluster.local:5432
kubectl -n "$NS" create secret generic database-access \
  --from-literal=host=postgres.database.svc.cluster.local \
  --from-literal=port=5432 \
  --from-literal=dbname=mon_appli \
  --from-literal=user=mon-appli \
  --from-literal=password="LE_MOT_DE_PASSE_FOURNI" \
  --from-literal=url="postgresql://mon-appli:LE_MOT_DE_PASSE_FOURNI@postgres.database.svc.cluster.local:5432/mon_appli?sslmode=prefer"

# ── Redis ────────────────────────────────────────────────────────────────────
# user = nom du locataire ; password = clé fournie (cache-tenant-keys).
# ⚠ TOUTES les clés de l'application DOIVENT être préfixées « mon-appli: » —
# c'est ce préfixe, et lui seul, que l'ACL du compte autorise.
kubectl -n "$NS" create secret generic cache-access \
  --from-literal=host=redis.cache.svc.cluster.local \
  --from-literal=port=6379 \
  --from-literal=user=mon-appli \
  --from-literal=password="LE_MOT_DE_PASSE_FOURNI" \
  --from-literal=url="redis://mon-appli:LE_MOT_DE_PASSE_FOURNI@redis.cache.svc.cluster.local:6379" \
  --from-literal=key-prefix="mon-appli:"

# ── Sceller (recommandé) ─────────────────────────────────────────────────────
# Reprendre chaque secret ci-dessus en le passant à kubeseal plutôt qu'à
# kubectl apply, p. ex. :
#   kubectl -n "$NS" create secret generic database-access --dry-run=client -o yaml \
#     --from-literal=... | kubeseal -o yaml > database-access.sealed.yaml
# puis committer le SealedSecret (chiffré), jamais le Secret en clair.
