#!/usr/bin/env python3
"""Condenser les alertes ModSecurity en un digest — le dépouillement de WAF.md.

Lit les logs du contrôleur ingress-nginx sur l'entrée standard, ne garde que
les entrées d'audit ModSecurity (JSON), et produit un tableau compact : règles
les plus déclenchées, hôtes et chemins concernés, codes de réponse.

C'est ce digest — quelques centaines de lignes au plus — qu'on soumet à un
modèle, jamais les logs bruts : le coût est borné quel que soit le trafic, et
rien de personnel ne sort. Les chaînes de requête sont coupées, les adresses IP
seulement comptées.

  kubectl -n platform-ingress logs deploy/platform-ingress-ingress-nginx-controller --since=24h \\
    | scripts/waf-digest.py > digest.md

Avec --ask, le digest est soumis à Claude (une seule requête, Sonnet, 3 tours au
plus), qui propose les exclusions au format de WAF.md :

  … | scripts/waf-digest.py --ask
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
# Règles de synthèse du CRS (score d'anomalie) : elles suivent les autres, les
# compter à part évite qu'elles dominent le classement.
SYNTHESE = {"949110", "959100", "980130", "980140", "980170"}


def entrees(flux):
    for ligne in flux:
        debut = ligne.find("{")
        if debut < 0 or '"transaction"' not in ligne:
            continue
        try:
            yield json.loads(ligne[debut:])["transaction"]
        except (ValueError, KeyError, TypeError):
            continue


def regles(t):
    for m in t.get("messages") or []:
        d = m.get("details") or {}
        rid = str(d.get("ruleId") or d.get("id") or "")
        if rid:
            yield rid, (m.get("message") or "")[:90].replace("|", "/")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--top", type=int, default=25, help="nombre de règles détaillées")
    p.add_argument("--ask", action="store_true", help="soumettre le digest à Claude")
    a = p.parse_args()

    par_regle = Counter()
    libelle = {}
    chemins = defaultdict(Counter)
    hotes = defaultdict(Counter)
    codes = Counter()
    ips = set()
    synthese = Counter()
    total = 0

    for t in entrees(sys.stdin):
        total += 1
        req = t.get("request") or {}
        entetes = {k.lower(): v for k, v in (req.get("headers") or {}).items()}
        hote = entetes.get("host", "?")
        # Sans chaîne de requête (données personnelles) ; les segments
        # numériques regroupés, pour qu'un même chemin ne compte qu'une fois.
        chemin = re.sub(r"/[0-9]+(?=/|$)", "/{n}", (req.get("uri") or "?").split("?", 1)[0])[:80]
        codes[str((t.get("response") or {}).get("http_code", "?"))] += 1
        ips.add(t.get("client_ip"))
        for rid, msg in set(regles(t)):
            if rid in SYNTHESE:
                synthese[rid] += 1
                continue
            par_regle[rid] += 1
            libelle.setdefault(rid, msg)
            chemins[rid][f"{hote}{chemin}".replace("|", "/")] += 1
            hotes[rid][hote] += 1

    out = [f"# Digest WAF — {total} transactions alertées, {len(ips)} IP distinctes", "",
           "Codes de réponse : " + ", ".join(f"{c} × {n}" for c, n in codes.most_common()), "",
           "| Règle | Alertes | Hôtes | Message | Chemins principaux |",
           "|---|---|---|---|---|"]
    for rid, n in par_regle.most_common(a.top):
        top = "<br>".join(f"`{c}` × {k}" for c, k in chemins[rid].most_common(4))
        out.append(f"| {rid} | {n} | {len(hotes[rid])} | {libelle[rid]} | {top} |")
    if synthese:
        out += ["", "Règles de synthèse (score d'anomalie) : "
                + ", ".join(f"{r} × {n}" for r, n in synthese.most_common())]
    digest = "\n".join(out) + "\n"

    if not a.ask:
        sys.stdout.write(digest)
        return 0

    consigne = (
        "Voici le digest des alertes du WAF ModSecurity (CRS) en DetectionOnly, et le "
        "runbook platform-ingress/WAF.md. Pour chaque règle du digest, dis : faux positif "
        "probable (trafic légitime de la plateforme) ou trafic réellement suspect, en une "
        "ligne. Puis propose les exclusions à ajouter au modsecurity-snippet, au format "
        "de WAF.md : ciblées par chemin, ids locaux à partir de 1000, SANS apostrophe, "
        "SANS commentaire ni guillemet dans le fragment. Ne propose jamais d'exclure une "
        "règle globalement. Termine par : prêt ou non pour SecRuleEngine On. En français, "
        "court.\n\n"
        + digest + "\n---\n" + (RACINE / "platform-ingress/WAF.md").read_text(encoding="utf-8")
    )
    return subprocess.run(
        ["claude", "-p", "--model", "sonnet", "--max-turns", "3"],
        input=consigne, text=True,
    ).returncode


if __name__ == "__main__":
    sys.exit(main())
