#!/usr/bin/env bash
# Dérive entre le cluster et ce dépôt, pour ce qu'Argo ne surveille pas.
#
# Les moteurs d'infra (platform-ingress, gateway) sont installés en CLI-Helm,
# hors Argo : personne ne voit un `helm upgrade` fait à la main avec d'autres
# valeurs, ni un manifeste brut modifié par `kubectl edit`. Ce script compare :
#   • les valeurs de chaque release Helm à leur fichier versionné ;
#   • la version de chart installée à celle épinglée dans le README du dossier
#     (`--version x.y.z` de la commande d'installation : le runbook fait foi) ;
#   • les manifestes bruts (gateway/NN-*.yaml) à l'état du cluster ;
#   • et liste les releases Helm du cluster qu'aucun dossier ne décrit.
#
# Aucune IA : une comparaison. Lecture seule. Code de sortie = nombre d'écarts.
# Usage : scripts/drift.sh
set -uo pipefail

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
command -v helm >/dev/null && command -v kubectl >/dev/null \
  || { echo "✗ helm et kubectl requis"; exit 2; }

# release  namespace  fichier de valeurs  runbook
MOTEURS=(
  "platform-ingress platform-ingress platform-ingress/values-ingress-nginx.yaml platform-ingress/README.md"
  "kong gateway gateway/values-kong.yaml gateway/README.md"
)

ECARTS=0
ko()   { echo "  ✗ $*"; ECARTS=$((ECARTS + 1)); }
ok()   { echo "  ✓ $*"; }
note() { echo "  ⚠ $*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

normaliser() {  # YAML ou JSON sur l'entrée → YAML trié sur la sortie
  python3 -c 'import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin) or {}, sort_keys=True, allow_unicode=True))'
}

helm list -A -o json > "$TMP/releases.json" 2>/dev/null || { echo "✗ helm list a échoué"; exit 2; }

for ligne in "${MOTEURS[@]}"; do
  read -r rel ns valeurs runbook <<<"$ligne"
  echo "→ $rel ($ns)"

  installee="$(python3 - "$TMP/releases.json" "$rel" "$ns" <<'PY'
import json, sys
for r in json.load(open(sys.argv[1])):
    if r["name"] == sys.argv[2] and r["namespace"] == sys.argv[3]:
        print(r["chart"])
PY
)"
  if [ -z "$installee" ]; then ko "release absente du cluster"; continue; fi

  # La version épinglée : le `--version` qui suit `helm upgrade --install <rel>`.
  epinglee="$(awk -v rel="$rel" '
    $0 ~ "helm upgrade --install " rel " " { dedans = 1 }
    dedans && match($0, /--version [^ \\]+/) { print substr($0, RSTART + 10, RLENGTH - 10); exit }
    dedans && $0 !~ /\\$/ { dedans = 0 }' "$RACINE/$runbook")"
  version="${installee##*-}"
  if [ -z "$epinglee" ]; then
    note "chart $installee installé, aucune version épinglée dans $runbook — ajouter --version $version"
  elif [ "$epinglee" = "$version" ]; then
    ok "chart $installee = version épinglée"
  else
    ko "chart $installee installé, $epinglee épinglé dans $runbook"
  fi

  helm -n "$ns" get values "$rel" -o json 2>/dev/null | normaliser > "$TMP/vivant.yaml"
  normaliser < "$RACINE/$valeurs" > "$TMP/depot.yaml"
  if diff -q "$TMP/depot.yaml" "$TMP/vivant.yaml" >/dev/null; then
    ok "valeurs conformes à $valeurs"
  else
    ko "valeurs du cluster ≠ $valeurs :"
    diff -u --label "dépôt" --label "cluster" "$TMP/depot.yaml" "$TMP/vivant.yaml" | sed 's/^/      /' | head -40
  fi
done

echo "→ manifestes bruts"
shopt -s nullglob
for f in "$RACINE"/gateway/[0-9]*-*.yaml; do
  kubectl diff -f "$f" > "$TMP/diff" 2>&1
  case $? in
    0) ok "${f#"$RACINE"/} conforme" ;;
    1) ko "${f#"$RACINE"/} diffère du cluster :"
       grep -E '^[-+] ' "$TMP/diff" | grep -vE 'generation|resourceVersion|managedFields' | sed 's/^/      /' | head -20 ;;
    *) ko "${f#"$RACINE"/} : kubectl diff a échoué ($(head -1 "$TMP/diff"))" ;;
  esac
done

echo "→ releases non décrites ici"
python3 - "$TMP/releases.json" "${MOTEURS[@]}" <<'PY'
import json, sys
connues = {tuple(m.split()[:2]) for m in sys.argv[2:]}
for r in json.load(open(sys.argv[1])):
    if (r["name"], r["namespace"]) not in connues:
        print(f"  · {r['name']} ({r['namespace']}) — {r['chart']}")
PY

echo
[ "$ECARTS" -eq 0 ] && echo "✓ aucune dérive" || echo "✗ $ECARTS écart(s)"
exit "$ECARTS"
