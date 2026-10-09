#!/usr/bin/env python3
"""Déclarer un locataire dans le socle — sans IA, sans deviner.

Ce que fait le script, et lui seul :
  • ajoute l'entrée `tenants` dans le values.yaml de chaque service demandé
    (database, object-store, cache), juste avant le bloc « Exemples à
    décommenter », en retirant l'exemple commenté s'il portait le même nom ;
  • ajoute l'Ingress d'hôte d'API à gateway/10-ingress-api-hosts.yaml ;
  • génère le kit côté application (namespace, NetworkPolicies, routes Kong),
    limité aux services réellement utilisés ;
  • écrit un résumé Markdown (corps de PR) avec les gestes restants côté admin.

Ce qu'il ne fait PAS : toucher à un secret. Les clés sont générées et déposées
par scripts/tenant-keys.sh, sur le poste de l'admin, sans jamais transiter par
la CI ni par un modèle.

Les fichiers sont édités comme du texte (insertion de lignes) et non
re-sérialisés : les commentaires, qui portent le « pourquoi » de chaque entrée,
restent intacts. Le résultat est ensuite relu en YAML pour vérification.

Usage :
  scripts/add-tenant.py --name mon-appli --label "Mon appli" \
      --repo https://github.com/hseb72/mon-appli \
      --database --bucket mon-appli --cache \
      --api-host api.mon-appli.crealcs.com --body-size 2m \
      --kit-dir /tmp/kit --summary /tmp/resume.md
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

RACINE = Path(__file__).resolve().parent.parent

NOM = re.compile(r"^[a-z][a-z0-9-]{0,30}[a-z0-9]$")
BASE = re.compile(r"^[a-z][a-z0-9_]{0,62}$")
SEAU = re.compile(r"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")
HOTE = re.compile(r"^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$")
TAILLE = re.compile(r"^[0-9]{1,3}[km]$")
DEPOT = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class Refus(Exception):
    """Une demande que le script ne sait pas traiter sans jugement humain."""


# ── Édition des listes `tenants` ─────────────────────────────────────────────

def bloc_tenants(lignes: list[str]) -> tuple[int, int]:
    """Bornes [début, fin) du bloc `tenants:` de premier niveau."""
    try:
        debut = next(i for i, l in enumerate(lignes) if l.rstrip() == "tenants:")
    except StopIteration:
        raise Refus("aucune clé `tenants:` de premier niveau")
    fin = len(lignes)
    for i in range(debut + 1, len(lignes)):
        l = lignes[i]
        if l.strip() and not l.startswith((" ", "#")):
            fin = i
            break
    # Les lignes vides qui précèdent la clé suivante n'appartiennent pas au bloc.
    while fin > debut + 1 and not lignes[fin - 1].strip():
        fin -= 1
    return debut, fin


def retirer_exemple(lignes: list[str], debut: int, fin: int, nom: str) -> int:
    """Retire l'exemple commenté `# - name: <nom>` (et ses lignes filles).

    Renvoie le nombre de lignes retirées.
    """
    motif = re.compile(rf"^  # - name: {re.escape(nom)}\s*$")
    for i in range(debut, fin):
        if motif.match(lignes[i]):
            j = i + 1
            while j < fin and re.match(r"^  #   \S", lignes[j]):
                j += 1
            del lignes[i:j]
            return j - i
    return 0


def inserer_locataire(chemin: Path, nom: str, entree: list[str]) -> str:
    texte = chemin.read_text(encoding="utf-8")
    existants = [t.get("name") for t in (yaml.safe_load(texte).get("tenants") or [])]
    if nom in existants:
        raise Refus(f"{chemin.relative_to(RACINE)} : le locataire « {nom} » existe déjà")

    lignes = texte.splitlines(keepends=True)
    debut, fin = bloc_tenants(lignes)
    fin -= retirer_exemple(lignes, debut, fin, nom)

    # Point d'insertion : avant le bloc d'exemples s'il existe, sinon en fin de
    # liste.
    point = fin
    for i in range(debut + 1, fin):
        if lignes[i].lstrip().startswith("# Exemples à décommenter"):
            point = i
            break
    # Si le bloc d'exemples a été vidé par le retrait, son titre aussi.
    if point < fin and not any(
        re.match(r"^  # - name: ", l) for l in lignes[point + 1:fin]
    ):
        del lignes[point]
        fin -= 1

    lignes[point:point] = [l + "\n" for l in entree]
    nouveau = "".join(lignes)

    relu = [t.get("name") for t in yaml.safe_load(nouveau).get("tenants") or []]
    if relu.count(nom) != 1:
        raise Refus(f"{chemin.relative_to(RACINE)} : l'insertion ne se relit pas")
    return nouveau


def entete(args, suffixe: str = "") -> list[str]:
    return [f"  # {args.label} — {args.repo} (ns `{args.namespace}`){suffixe}"]


# ── Gateway ──────────────────────────────────────────────────────────────────

INGRESS_HOTE = """\

# ─────────────────────────────────────────────────────────────────────────────
# {nom} — {repo}
#
# Routes Kong dans le namespace de l'application (`{ns}`). L'hôte, lui, vit
# ici : c'est le socle qui possède le namespace `gateway`.
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {nom}-api
  namespace: gateway
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-http01
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-body-size: "{taille}"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - {hote}
      secretName: {nom}-api-tls
  rules:
    - host: {hote}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kong-proxy
                port:
                  number: 80
"""


def ajouter_hote(chemin: Path, args) -> str:
    texte = chemin.read_text(encoding="utf-8")
    for doc in yaml.safe_load_all(texte):
        if not doc:
            continue
        if doc["metadata"]["name"] == f"{args.name}-api":
            raise Refus(f"l'Ingress {args.name}-api existe déjà")
        for regle in doc["spec"].get("rules", []):
            if regle.get("host") == args.api_host:
                raise Refus(f"l'hôte {args.api_host} est déjà routé")
    nouveau = texte.rstrip("\n") + "\n" + INGRESS_HOTE.format(
        nom=args.name, repo=args.repo, ns=args.namespace,
        taille=args.body_size, hote=args.api_host,
    )
    hotes = [r.get("host") for d in yaml.safe_load_all(nouveau) if d
             for r in d["spec"].get("rules", [])]
    if hotes.count(args.api_host) != 1:
        raise Refus("l'Ingress ajouté ne se relit pas")
    return nouveau


# ── Kit côté application ─────────────────────────────────────────────────────

def kit(args, dossier: Path) -> list[str]:
    dossier.mkdir(parents=True, exist_ok=True)
    ns = args.namespace
    etiquettes = []
    sorties = []
    if args.bucket:
        etiquettes.append('    object-store-client: "true"')
        sorties.append(("MinIO — stockage objet.", "object-store", 9000))
    if args.database:
        etiquettes.append('    database-client: "true"')
        sorties.append(("PostgreSQL — base de données.", "database", 5432))
    if args.cache:
        etiquettes.append('    cache-client: "true"')
        sorties.append(("Redis — cache.", "cache", 6379))

    (dossier / "namespace.yaml").write_text(
        "# Généré par homelab-platform/scripts/add-tenant.py — à committer dans le\n"
        "# dépôt de l'application. Les étiquettes `*-client` ouvrent l'accès aux\n"
        "# services mutualisés ; n'y figurent que ceux demandés.\n"
        "apiVersion: v1\nkind: Namespace\nmetadata:\n"
        f"  name: {ns}\n  labels:\n    name: {ns}\n"
        + "".join(e + "\n" for e in etiquettes)
        + "    pod-security.kubernetes.io/enforce: baseline\n"
        "    pod-security.kubernetes.io/warn: restricted\n",
        encoding="utf-8",
    )

    np = [
        "# Généré par homelab-platform/scripts/add-tenant.py — refus par défaut,",
        "# DNS, sorties vers les seuls services demandés"
        + (", entrée depuis la gateway." if args.api_host else "."),
        "apiVersion: networking.k8s.io/v1", "kind: NetworkPolicy",
        "metadata:", "  name: default-deny", f"  namespace: {ns}",
        "spec:", "  podSelector: {}", "  policyTypes: [Ingress, Egress]",
        "---",
        "apiVersion: networking.k8s.io/v1", "kind: NetworkPolicy",
        "metadata:", "  name: allow-dns", f"  namespace: {ns}",
        "spec:", "  podSelector: {}", "  policyTypes: [Egress]", "  egress:",
        "    - to:", "        - namespaceSelector:", "            matchLabels:",
        "              kubernetes.io/metadata.name: kube-system",
        "      ports:", "        - { port: 53, protocol: UDP }",
        "        - { port: 53, protocol: TCP }",
    ]
    if sorties:
        np += ["---", "apiVersion: networking.k8s.io/v1", "kind: NetworkPolicy",
               "metadata:", "  name: allow-egress-platform", f"  namespace: {ns}",
               "spec:", "  podSelector: {}", "  policyTypes: [Egress]", "  egress:"]
        for titre, cible, port in sorties:
            np += [f"    # {titre}", "    - to:", "        - namespaceSelector:",
                   "            matchLabels:",
                   f"              kubernetes.io/metadata.name: {cible}",
                   "      ports:", f"        - {{ port: {port}, protocol: TCP }}"]
    if args.api_host:
        np += ["---", "# À ajuster : le sélecteur des pods d'API et leur port.",
               "apiVersion: networking.k8s.io/v1", "kind: NetworkPolicy",
               "metadata:", "  name: allow-ingress-from-gateway", f"  namespace: {ns}",
               "spec:", "  podSelector:", "    matchLabels:",
               "      app.kubernetes.io/name: api", "  policyTypes: [Ingress]",
               "  ingress:", "    - from:", "        - namespaceSelector:",
               "            matchLabels:", "              name: gateway",
               "      ports:", f"        - {{ port: {args.api_port}, protocol: TCP }}"]
    (dossier / "networkpolicy.yaml").write_text("\n".join(np) + "\n", encoding="utf-8")

    fichiers = ["namespace.yaml", "networkpolicy.yaml"]
    if args.api_host:
        (dossier / "api-kong-ingress.yaml").write_text(
            "# Généré par homelab-platform/scripts/add-tenant.py — routes Kong, dans le\n"
            "# namespace de l'application. L'hôte public est déjà déclaré dans le socle\n"
            "# (gateway/10-ingress-api-hosts.yaml). Ne jamais réécrire l'en-tête Host.\n"
            "apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n"
            f"  name: {args.name}-api\n  namespace: {ns}\n  annotations:\n"
            '    konghq.com/preserve-host: "true"\n'
            '    konghq.com/strip-path: "false"\n'
            "spec:\n  ingressClassName: kong\n  rules:\n"
            + "".join(
                f"    - host: {h}\n      http:\n        paths:\n"
                "          - path: /\n            pathType: ImplementationSpecific\n"
                "            backend:\n              service:\n                name: api\n"
                f"                port:\n                  number: {args.api_port}\n"
                for h in (args.api_host, "kong-proxy.gateway.svc.cluster.local")
            ),
            encoding="utf-8",
        )
        fichiers.append("api-kong-ingress.yaml")
    for f in fichiers:
        list(yaml.safe_load_all((dossier / f).read_text(encoding="utf-8")))
    return fichiers


# ── Résumé ───────────────────────────────────────────────────────────────────

def resume(args, modifies: list[str], kit_fichiers: list[str], dossier: Path | None) -> str:
    services = []
    if args.database:
        services.append("database")
    if args.bucket:
        services.append("object-store")
    if args.cache:
        services.append("cache")
    drapeaux = " ".join(f"--{s}" for s in services)

    l = [f"## Locataire `{args.name}` — {args.label}", "",
         f"Dépôt : {args.repo} · namespace `{args.namespace}`", "",
         "### Ce que change cette PR", ""]
    if args.database:
        l.append(f"- **PostgreSQL** : base `{args.database}`, rôle `{args.name}`")
    if args.bucket:
        l.append(f"- **MinIO** : seau(x) {', '.join(f'`{b}`' for b in args.bucket)}")
    if args.cache:
        l.append(f"- **Redis** : compte `{args.name}`, clés préfixées `{args.name}:`")
    if args.api_host:
        l.append(f"- **API** : hôte `{args.api_host}` → kong-proxy (corps ≤ {args.body_size})")
    l += ["", "Fichiers : " + ", ".join(f"`{m}`" for m in modifies), ""]
    if services:
        l += ["### Après fusion — côté admin du socle", "",
              "Sur le poste qui a `kubectl` (aucune clé ne passe par la CI ni par un modèle) :",
              "", "```bash",
              f"scripts/tenant-keys.sh {args.name} {drapeaux} --app-namespace {args.namespace} --out ./sealed-{args.name}",
              "# → dépose les clés dans les Secrets de locataires, lance la synchro Argo,",
              f"#   et scelle les secrets d'accès côté appli dans ./sealed-{args.name}/",
              f"scripts/verify-tenant.sh {args.name} --app-namespace {args.namespace}",
              "```", ""]
    if kit_fichiers:
        l += ["### Côté application", "",
              f"À committer dans {args.repo} (`deploy/manifests/` ou équivalent) :", ""]
        for f in kit_fichiers:
            contenu = (dossier / f).read_text(encoding="utf-8") if dossier else ""
            l += [f"<details><summary><code>{f}</code></summary>", "", "```yaml",
                  contenu.rstrip(), "```", "", "</details>", ""]
        if services:
            l.append(f"+ les SealedSecrets produits dans `./sealed-{args.name}/`.")
        if args.cache:
            l.append(f"\n⚠ Toutes les clés Redis de l'application doivent être préfixées `{args.name}:`.")
    return "\n".join(l) + "\n"


# ── Entrée ───────────────────────────────────────────────────────────────────

def analyser(argv: list[str]):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--name", required=True, help="nom du locataire (compte, rôle)")
    p.add_argument("--label", required=True, help="nom lisible de l'application")
    p.add_argument("--repo", required=True, help="URL GitHub du dépôt applicatif")
    p.add_argument("--namespace", help="namespace de l'application (défaut : --name)")
    p.add_argument("--database", nargs="?", const="", default=None,
                   help="une base PostgreSQL (nom optionnel ; défaut : --name avec _)")
    p.add_argument("--bucket", action="append", default=[], help="un seau MinIO (répétable)")
    p.add_argument("--bucket-note", default="", help="à quoi servent les seaux (commentaire)")
    p.add_argument("--cache", action="store_true", help="un compte Redis")
    p.add_argument("--api-host", help="hôte public de l'API")
    p.add_argument("--api-port", type=int, default=3000, help="port des pods d'API (kit)")
    p.add_argument("--body-size", default="1m", help="taille maximale du corps (nginx)")
    p.add_argument("--kit-dir", type=Path, help="où écrire le kit côté application")
    p.add_argument("--summary", type=Path, help="où écrire le résumé Markdown")
    a = p.parse_args(argv)

    a.namespace = a.namespace or a.name
    if a.database == "":
        a.database = a.name.replace("-", "_")
    a.label = " ".join(a.label.split())
    a.bucket_note = " ".join(a.bucket_note.split())

    erreurs = []
    if not NOM.match(a.name):
        erreurs.append(f"nom « {a.name} » : minuscules, chiffres et tirets, 2 à 32 caractères")
    if not NOM.match(a.namespace):
        erreurs.append(f"namespace « {a.namespace} » invalide")
    if a.database is not None and not BASE.match(a.database):
        erreurs.append(f"base « {a.database} » : minuscules, chiffres et _")
    for b in a.bucket:
        if not SEAU.match(b):
            erreurs.append(f"seau « {b} » invalide")
    if a.api_host and not HOTE.match(a.api_host):
        erreurs.append(f"hôte « {a.api_host} » invalide")
    if not TAILLE.match(a.body_size):
        erreurs.append(f"taille « {a.body_size} » : p. ex. 1m, 512k")
    if not DEPOT.match(a.repo):
        erreurs.append(f"dépôt « {a.repo} » : URL https://github.com/<owner>/<repo> attendue")
    if not (1 <= a.api_port <= 65535):
        erreurs.append("port d'API hors bornes")
    if any(c in a.label + a.bucket_note for c in "\n\r`$\\"):
        erreurs.append("libellé ou note : caractères interdits")
    if a.database is None and not a.bucket and not a.cache and not a.api_host:
        erreurs.append("aucun service demandé")
    if erreurs:
        raise Refus("; ".join(erreurs))
    return a


def main(argv: list[str]) -> int:
    try:
        args = analyser(argv)
        # Tout est calculé avant d'écrire quoi que ce soit : un refus sur le
        # troisième fichier ne laisse pas les deux premiers à moitié modifiés.
        a_ecrire: dict[str, str] = {}
        if args.database is not None:
            a_ecrire["database/values.yaml"] = inserer_locataire(
                RACINE / "database/values.yaml", args.name, entete(args) + [
                    f"  - name: {args.name}", f"    database: {args.database}"])
        if args.bucket:
            note = [f"  # {args.bucket_note}"] if args.bucket_note else []
            a_ecrire["object-store/values.yaml"] = inserer_locataire(
                RACINE / "object-store/values.yaml", args.name,
                entete(args, " :" if note else "") + note
                + [f"  - name: {args.name}", "    buckets:"]
                + [f"      - {b}" for b in args.bucket])
        if args.cache:
            a_ecrire["cache/values.yaml"] = inserer_locataire(
                RACINE / "cache/values.yaml", args.name,
                entete(args) + [f"  - name: {args.name}"])
        if args.api_host:
            a_ecrire["gateway/10-ingress-api-hosts.yaml"] = ajouter_hote(
                RACINE / "gateway/10-ingress-api-hosts.yaml", args)
        for chemin, texte in a_ecrire.items():
            (RACINE / chemin).write_text(texte, encoding="utf-8")
        modifies = list(a_ecrire)
        fichiers = kit(args, args.kit_dir) if args.kit_dir else []
        texte = resume(args, modifies, fichiers, args.kit_dir)
        if args.summary:
            args.summary.write_text(texte, encoding="utf-8")
        else:
            sys.stdout.write(texte)
    except Refus as e:
        print(f"✗ {e}", file=sys.stderr)
        return 2
    print(f"✓ locataire {args.name} : {', '.join(modifies)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
