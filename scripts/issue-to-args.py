#!/usr/bin/env python3
"""Traduire le formulaire d'issue « Nouveau locataire » en appel à add-tenant.py.

Lit le corps de l'issue dans la variable d'environnement CORPS (jamais par
interpolation dans le shell : c'est du texte saisi), en extrait les champs, et
appelle add-tenant.main() avec une liste d'arguments — aucune ligne de commande
n'est reconstruite, donc rien à échapper.

Les options restantes (--kit-dir, --summary) sont transmises telles quelles.
Écrit `name=<locataire>` dans $GITHUB_OUTPUT s'il est défini.
"""
from __future__ import annotations

import importlib.util
import os
import re
import sys
from pathlib import Path

ICI = Path(__file__).resolve().parent

# Libellés du formulaire (.github/ISSUE_TEMPLATE/nouveau-locataire.yml).
CHAMPS = {
    "Nom du locataire": "nom",
    "Libellé": "libelle",
    "Dépôt": "depot",
    "Namespace": "namespace",
    "Services": "services",
    "Nom de la base": "base",
    "Seaux MinIO": "seaux",
    "Usage des seaux": "note_seaux",
    "Hôte d'API": "hote",
    "Port des pods d'API": "port",
    "Taille maximale du corps de requête": "taille",
}


def lire(corps: str) -> dict[str, str]:
    """Découpe le corps en sections `### Libellé` → valeur."""
    valeurs: dict[str, str] = {}
    for bloc in re.split(r"^### ", corps.replace("\r\n", "\n"), flags=re.M)[1:]:
        titre, _, reste = bloc.partition("\n")
        cle = CHAMPS.get(titre.strip())
        if cle is None:
            continue
        reste = reste.strip()
        valeurs[cle] = "" if reste == "_No response_" else reste
    return valeurs


def arguments(v: dict[str, str]) -> list[str]:
    a = ["--name", v.get("nom", ""), "--label", v.get("libelle", ""),
         "--repo", v.get("depot", "")]
    if v.get("namespace"):
        a += ["--namespace", v["namespace"]]
    coches = re.findall(r"^- \[[xX]\] (.+)$", v.get("services", ""), flags=re.M)
    if "Base PostgreSQL" in coches:
        a += ["--database", v["base"]] if v.get("base") else ["--database"]
    if "Cache Redis" in coches:
        a.append("--cache")
    for seau in filter(None, (s.strip() for s in v.get("seaux", "").split(","))):
        a += ["--bucket", seau]
    if v.get("note_seaux"):
        a += ["--bucket-note", v["note_seaux"]]
    if v.get("hote"):
        a += ["--api-host", v["hote"]]
    if v.get("port"):
        a += ["--api-port", v["port"]]
    if v.get("taille"):
        a += ["--body-size", v["taille"]]
    return a


def main() -> int:
    v = lire(os.environ.get("CORPS", ""))
    args = arguments(v) + sys.argv[1:]

    spec = importlib.util.spec_from_file_location("add_tenant", ICI / "add-tenant.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    rc = module.main(args)

    sortie = os.environ.get("GITHUB_OUTPUT")
    if rc == 0 and sortie:
        with open(sortie, "a", encoding="utf-8") as f:
            f.write(f"name={v['nom']}\n")
    return rc


if __name__ == "__main__":
    sys.exit(main())
