#!/usr/bin/env bash
# Déposer les clés d'un locataire — sur le poste de l'admin, jamais en CI.
#
# Pour chaque service demandé :
#   1. génère la clé (ou reprend celle qui existe : l'opération est rejouable),
#      et l'ajoute au Secret de locataires du service ;
#   2. déclenche la synchronisation Argo de ce service — un patch de Secret n'en
#      déclenche aucune (cf. database/README.md §3), et sans elle la clé
#      n'atteint jamais le service ;
#   3. scelle les secrets d'accès CÔTÉ APPLICATION (kubeseal), prêts à committer
#      dans le dépôt de l'application.
#
# Aucune clé n'est affichée ni passée en argument de commande : elles transitent
# par des fichiers temporaires en 0600, effacés à la sortie.
#
# Usage :
#   scripts/tenant-keys.sh <locataire> [--database] [--object-store] [--cache]
#                          [--app-namespace <ns>] [--out <dossier>]
#                          [--rotate] [--no-sync]
set -euo pipefail

RACINE="$(cd "$(dirname "$0")/.." && pwd)"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ $# -ge 1 ] || usage
NOM="$1"; shift
NS="$NOM"; OUT=""; ROTATE=0; SYNC=1; SERVICES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --database|--object-store|--cache) SERVICES+=("${1#--}") ;;
    --app-namespace) NS="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --rotate) ROTATE=1 ;;
    --no-sync) SYNC=0 ;;
    *) usage ;;
  esac
  shift
done
[[ "$NOM" =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ ]] || { echo "✗ nom invalide : $NOM"; exit 2; }
[ ${#SERVICES[@]} -gt 0 ] || { echo "✗ aucun service (--database, --object-store, --cache)"; exit 2; }
command -v kubectl >/dev/null || { echo "✗ kubectl introuvable"; exit 2; }
if [ -n "$OUT" ]; then
  command -v kubeseal >/dev/null || { echo "✗ kubeseal introuvable (requis par --out)"; exit 2; }
  mkdir -p "$OUT"
fi

TMP="$(mktemp -d)"; chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# Le locataire doit être déclaré dans le values.yaml du service (PR fusionnée).
declare_dans() {
  python3 - "$RACINE/$1/values.yaml" "$NOM" <<'PY'
import sys, yaml
t = [x for x in yaml.safe_load(open(sys.argv[1])).get("tenants") or [] if x.get("name") == sys.argv[2]]
if not t:
    sys.exit(1)
print(t[0].get("database", ""))
PY
}

cle() {  # <service> → écrit la clé dans $TMP/<service>.cle
  local service="$1" secret="$1-tenant-keys" existante
  existante="$(kubectl -n "$service" get secret "$secret" -o "jsonpath={.data.$NOM}" 2>/dev/null || true)"
  if [ -n "$existante" ] && [ "$ROTATE" -eq 0 ]; then
    printf '%s' "$existante" | base64 -d > "$TMP/$service.cle"
    echo "  clé existante reprise (--rotate pour la changer)"
    return
  fi
  # 32 caractères alphanumériques : sans caractère à échapper dans une URL.
  python3 -c 'import secrets, string, sys
sys.stdout.write("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)))' \
    > "$TMP/$service.cle"
  python3 - "$NOM" "$TMP/$service.cle" > "$TMP/$service.patch" <<'PY'
import json, sys
print(json.dumps({"stringData": {sys.argv[1]: open(sys.argv[2]).read()}}))
PY
  kubectl -n "$service" patch secret "$secret" --type merge --patch-file "$TMP/$service.patch" >/dev/null
  echo "  clé $( [ -n "$existante" ] && echo tournée || echo créée ) dans $service/$secret"
}

synchroniser() {
  [ "$SYNC" -eq 1 ] || { echo "  synchro sautée (--no-sync) : la lancer avant toute vérification"; return; }
  if command -v argocd >/dev/null && argocd app get "$1" >/dev/null 2>&1; then
    argocd app sync "$1" >/dev/null && echo "  synchro Argo lancée (argocd)"
  else
    # Sans CLI argocd : une opération posée sur l'Application fait le même effet.
    kubectl -n argocd patch application "$1" --type merge \
      -p '{"operation":{"initiatedBy":{"username":"tenant-keys"},"sync":{}}}' >/dev/null
    echo "  synchro Argo lancée (opération sur l'Application)"
  fi
}

sceller() {  # <nom du secret> <args kubectl create secret…>
  local nom="$1"; shift
  kubectl -n "$NS" create secret generic "$nom" --dry-run=client -o yaml "$@" \
    | kubeseal -o yaml --namespace "$NS" > "$OUT/$nom.sealed.yaml"
  echo "  scellé : $OUT/$nom.sealed.yaml"
}

for service in "${SERVICES[@]}"; do
  echo "→ $service"
  base="$(declare_dans "$service")" || {
    echo "✗ $NOM n'est pas déclaré dans $service/values.yaml — PR fusionnée et dépôt à jour ?"; exit 1; }
  cle "$service"
  synchroniser "$service"
  [ -n "$OUT" ] || continue
  f="$TMP/$service.cle"
  case "$service" in
    object-store)
      sceller object-store-access \
        --from-literal=endpoint=minio.object-store.svc.cluster.local:9000 \
        --from-literal=access-key="$NOM" --from-file=secret-key="$f" ;;
    database)
      printf 'postgresql://%s:%s@postgres.database.svc.cluster.local:5432/%s?sslmode=prefer' \
        "$NOM" "$(cat "$f")" "$base" > "$TMP/db.url"
      sceller database-access \
        --from-literal=host=postgres.database.svc.cluster.local --from-literal=port=5432 \
        --from-literal=dbname="$base" --from-literal=user="$NOM" \
        --from-file=password="$f" --from-file=url="$TMP/db.url" ;;
    cache)
      printf 'redis://%s:%s@redis.cache.svc.cluster.local:6379' "$NOM" "$(cat "$f")" > "$TMP/cache.url"
      sceller cache-access \
        --from-literal=host=redis.cache.svc.cluster.local --from-literal=port=6379 \
        --from-literal=user="$NOM" --from-file=password="$f" \
        --from-file=url="$TMP/cache.url" --from-literal=key-prefix="$NOM:" ;;
  esac
done

echo
echo "✓ clés en place. Ensuite : scripts/verify-tenant.sh $NOM --app-namespace $NS"
[ -z "$OUT" ] || echo "  et committer $OUT/*.sealed.yaml dans le dépôt de l'application."
