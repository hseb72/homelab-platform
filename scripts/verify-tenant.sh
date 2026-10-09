#!/usr/bin/env bash
# Vérifier un locataire après synchronisation — la checklist d'onboarding de
# CONSUMING.md, exécutée plutôt que relue.
#
# Pour chaque service où le locataire est déclaré :
#   • Application Argo synchronisée et saine ;
#   • clé présente dans le Secret de locataires ;
#   • provisionnement passé pour ce locataire (logs du Job provision-1) ;
#   • namespace de l'application porteur de l'étiquette `*-client` ;
#   • CLOISONNEMENT : sa ressource lui est ouverte, celle d'un voisin refusée.
# Plus, une fois : l'AppProject du cluster conforme au fichier (piège connu :
# il n'est pas synchronisé par les Applications).
#
# Lecture seule, à une exception près : une clé Redis `<locataire>:verify-tenant`
# écrite puis effacée. Les clés ne sont ni affichées ni passées en argument —
# elles entrent dans les pods par l'entrée standard.
#
# Usage : scripts/verify-tenant.sh <locataire> [--app-namespace <ns>]
# Code de sortie : le nombre d'échecs (0 = tout est vert).
set -uo pipefail

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] || { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
NOM="$1"; shift
NS="$NOM"
[ "${1:-}" = "--app-namespace" ] && NS="$2"
[[ "$NOM" =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ ]] || { echo "✗ nom invalide : $NOM"; exit 2; }

ECHECS=0
ok()   { echo "  ✓ $*"; }
ko()   { echo "  ✗ $*"; ECHECS=$((ECHECS + 1)); }
note() { echo "  ⚠ $*"; }

# Locataire tel que déclaré : « base » pour database, liste des seaux pour
# object-store, rien pour cache. Plus un voisin à qui se heurter.
lire() {  # <service> → lignes : "moi <valeur>" puis "voisin <valeur>"
  python3 - "$RACINE/$1/values.yaml" "$NOM" "$1" <<'PY'
import sys, yaml
chemin, nom, service = sys.argv[1:]
tenants = yaml.safe_load(open(chemin)).get("tenants") or []
moi = [t for t in tenants if t.get("name") == nom]
if not moi:
    sys.exit(1)
autres = [t for t in tenants if t.get("name") != nom]
if service == "database":
    print("moi", moi[0]["database"])
    print("voisin", autres[0]["database"] if autres else "postgres_inexistante")
elif service == "object-store":
    print("moi", moi[0]["buckets"][0])
    seaux = [b for t in autres for b in t.get("buckets", [])]
    print("voisin", seaux[0] if seaux else "seau-inexistant")
else:
    print("moi", nom)
    print("voisin", autres[0]["name"] if autres else "intrus")
PY
}

cle() { kubectl -n "$1" get secret "$1-tenant-keys" -o "jsonpath={.data.$NOM}" 2>/dev/null | base64 -d 2>/dev/null; }

echo "→ AppProject"
kubectl diff -f "$RACINE/object-store/argocd/project.yaml" >/dev/null 2>&1
case $? in
  0) ok "conforme à object-store/argocd/project.yaml" ;;
  1) ko "l'AppProject du cluster diffère du fichier : kubectl apply -f object-store/argocd/project.yaml" ;;
  *) ko "kubectl diff a échoué sur l'AppProject (droits ? contexte kubectl ?)" ;;
esac

echo "→ namespace $NS"
if kubectl get ns "$NS" >/dev/null 2>&1; then ok "présent"; else ko "absent"; fi

TROUVE=0
for service in database object-store cache; do
  decl="$(lire "$service")" || continue
  TROUVE=1
  moi="$(sed -n 's/^moi //p' <<<"$decl")"
  voisin="$(sed -n 's/^voisin //p' <<<"$decl")"
  echo "→ $service"

  etat="$(kubectl -n argocd get application "$service" \
          -o 'jsonpath={.status.sync.status}/{.status.health.status}' 2>/dev/null)"
  [ "$etat" = "Synced/Healthy" ] && ok "Argo : $etat" || ko "Argo : ${etat:-introuvable}"

  CLE="$(cle "$service")"
  [ -n "$CLE" ] && ok "clé présente dans $service-tenant-keys" \
                || ko "aucune clé « $NOM » dans $service-tenant-keys — scripts/tenant-keys.sh"

  logs="$(kubectl -n "$service" logs job/provision-1 2>/dev/null)"
  if grep -q "^→ locataire $NOM\$" <<<"$logs" && grep -q "✓ provisionnement terminé" <<<"$logs" \
     && ! grep -q "✗ $NOM " <<<"$logs"; then
    ok "provisionné (job/provision-1)"
  else
    ko "provisionnement non constaté — kubectl -n $service logs job/provision-1 (synchro lancée après la clé ?)"
  fi

  etiquette="$(kubectl get ns "$NS" -o "jsonpath={.metadata.labels.$service-client}" 2>/dev/null)"
  [ "$etiquette" = "true" ] && ok "étiquette $service-client sur $NS" \
                            || ko "étiquette $service-client absente de $NS : le service lui est fermé"

  [ -n "$CLE" ] || continue
  case "$service" in
    database)
      r="$(kubectl -n database exec -i postgres-0 -- sh -c \
            'read -r PGPASSWORD; export PGPASSWORD
             psql -h 127.0.0.1 -U "$1" -d "$2" -tAc "select 1" 2>&1 | head -1
             psql -h 127.0.0.1 -U "$1" -d "$3" -tAc "select 1" 2>&1 | head -1' \
            _ "$NOM" "$moi" "$voisin" <<<"$CLE" 2>&1)"
      [ "$(sed -n 1p <<<"$r")" = "1" ] && ok "base $moi ouverte" || ko "base $moi : $(sed -n 1p <<<"$r")"
      grep -q "permission denied\|does not exist" <<<"$(sed -n 2p <<<"$r")" \
        && ok "base voisine $voisin refusée" || ko "base voisine $voisin : $(sed -n 2p <<<"$r")" ;;
    cache)
      r="$(kubectl -n cache exec -i redis-0 -- sh -c \
            'read -r REDISCLI_AUTH; export REDISCLI_AUTH
             redis-cli --no-auth-warning --user "$1" SET "$1:verify-tenant" ok 2>&1
             redis-cli --no-auth-warning --user "$1" SET "$2:verify-tenant" ko 2>&1
             redis-cli --no-auth-warning --user "$1" DEL "$1:verify-tenant" >/dev/null 2>&1' \
            _ "$NOM" "$voisin" <<<"$CLE" 2>&1)"
      [ "$(sed -n 1p <<<"$r")" = "OK" ] && ok "clés $NOM:* ouvertes" || ko "clés $NOM:* : $(sed -n 1p <<<"$r")"
      grep -q NOPERM <<<"$(sed -n 2p <<<"$r")" \
        && ok "clés $voisin:* refusées" || ko "clés $voisin:* : $(sed -n 2p <<<"$r")" ;;
    object-store)
      r="$(kubectl -n object-store exec -i minio-0 -- sh -c \
            'command -v mc >/dev/null || { echo SANS_MC; exit 0; }
             read -r K; export MC_CONFIG_DIR=/tmp/.mc-verify
             mc alias set v http://127.0.0.1:9000 "$1" "$K" >/dev/null 2>&1 || echo ALIAS_KO
             mc ls "v/$2" >/dev/null 2>&1 && echo MOI_OK || echo MOI_KO
             mc ls "v/$3" >/dev/null 2>&1 && echo VOISIN_OUVERT || echo VOISIN_REFUSE
             rm -rf /tmp/.mc-verify' \
            _ "$NOM" "$moi" "$voisin" <<<"$CLE" 2>&1)"
      if grep -q SANS_MC <<<"$r"; then
        note "mc absent de l'image MinIO : cloisonnement à éprouver à la main (object-store/README.md §4)"
      else
        grep -q MOI_OK <<<"$r" && ok "seau $moi ouvert" || ko "seau $moi inaccessible avec la clé du locataire"
        grep -q VOISIN_REFUSE <<<"$r" && ok "seau voisin $voisin refusé" || ko "seau voisin $voisin OUVERT"
      fi ;;
  esac
done

[ "$TROUVE" -eq 1 ] || { echo "✗ $NOM n'est déclaré dans aucun service"; exit 1; }
echo
[ "$ECHECS" -eq 0 ] && echo "✓ $NOM : tout est vert" || echo "✗ $NOM : $ECHECS échec(s)"
exit "$ECHECS"
