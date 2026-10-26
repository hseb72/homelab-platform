#!/usr/bin/env bash
# Dérive entre le cluster et ce dépôt, pour ce qu'Argo ne surveille PAS.
#
# Depuis le retrait des moteurs CLI-Helm (phase 5), l'edge (ingress-nginx, Kong)
# et les datastores mutualisés sont instanciés par `charts/platform` et
# réconciliés par Argo (selfHeal) : leur dérive est l'affaire d'Argo, pas de ce
# script. Ne reste hors Argo qu'UN manifeste appliqué à la main — l'Ingress des
# hôtes d'API centralisés (`edge/api-hosts.yaml`). Ce script :
#   • compare ce fichier à l'état du cluster (`kubectl diff`) ;
#   • liste les releases Helm présentes — le socle ne devrait plus en avoir (il
#     est tout en Argo) ; une release inattendue mérite un œil.
#
# Aucune IA : une comparaison. Lecture seule. Code de sortie = nombre d'écarts.
# Usage : scripts/drift.sh
set -uo pipefail

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
command -v kubectl >/dev/null || { echo "✗ kubectl requis"; exit 2; }

ECARTS=0
ko() { echo "  ✗ $*"; ECARTS=$((ECARTS + 1)); }
ok() { echo "  ✓ $*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "→ Ingress des hôtes d'API (edge/api-hosts.yaml, appliqué à la main)"
kubectl diff -f "$RACINE/edge/api-hosts.yaml" > "$TMP/diff" 2>&1
case $? in
  0) ok "conforme au cluster" ;;
  1) ko "diffère du cluster :"
     grep -E '^[-+] ' "$TMP/diff" | grep -vE 'generation|resourceVersion|managedFields' | sed 's/^/      /' | head -30 ;;
  *) ko "kubectl diff a échoué ($(head -1 "$TMP/diff"))" ;;
esac

echo "→ releases Helm présentes (le socle ne devrait plus en avoir)"
if command -v helm >/dev/null; then
  helm list -A -o json > "$TMP/releases.json" 2>/dev/null || { ko "helm list a échoué"; }
  if [ -s "$TMP/releases.json" ]; then
    python3 - "$TMP/releases.json" <<'PY'
import json, sys
releases = json.load(open(sys.argv[1]))
if not releases:
    print("  ✓ aucune release Helm")
for r in releases:
    print(f"  · {r['name']} ({r['namespace']}) — {r['chart']}")
PY
  fi
else
  echo "  ⚠ helm absent — listing ignoré"
fi

echo
[ "$ECARTS" -eq 0 ] && echo "✓ aucune dérive" || echo "✗ $ECARTS écart(s)"
exit "$ECARTS"
