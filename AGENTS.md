# Agents du socle

L'outillage qui fait à la place de l'admin ce qui se répète, ou ce que la doc
demande et que personne ne fait. **Un principe le gouverne : le script
d'abord, l'IA en exception.** Ce qui se décide mécaniquement (insérer une
entrée, comparer deux états, rejouer un dump) est un script : rien sur le
quota. Claude n'intervient que là où il faut lire et juger, et toujours :

- **Sonnet**, jamais Opus, pour ces tâches de routine ;
- **`--max-turns` plafonné** (3 à 8 selon la tâche) ;
- **en lecture seule**, avec pour seule sortie un commentaire ;
- **sur une entrée bornée** (un digest, un diff, un journal d'erreur), jamais
  sur des logs bruts ;
- **une fois par événement** (à l'ouverture d'une PR, pas à chaque rebase).

La fusion d'une PR reste le seul point de passage vers le cluster.

## Ce qui est en place

| # | Agent | Déclencheur | Le script | L'IA | Quota estimé |
|---|---|---|---|---|---|
| 1 | **Guichet d'onboarding** | issue « Nouveau locataire » | [`add-tenant.py`](scripts/add-tenant.py) via [`tenant-onboarding.yml`](.github/workflows/tenant-onboarding.yml) : values, hôte d'API, kit côté appli, PR | **repli seulement**, si le script refuse : explique le refus (Sonnet, 6 tours) | ~0 |
| 2 | **Clés et vérification** | après fusion, par l'admin | [`tenant-keys.sh`](scripts/tenant-keys.sh) (clés, synchro Argo, SealedSecrets) puis [`verify-tenant.sh`](scripts/verify-tenant.sh) (checklist + cloisonnement) | aucune | 0 |
| 4 | **Épreuve de restauration** | CronJob, dimanche 4 h 40 | [`restore-check`](database/templates/backup/restore-check-cronjob.yaml) : dernier dump rejoué dans un PostgreSQL jetable, comparé à la prod | aucune ; l'échec du Job **est** l'alerte ([règles vmalert](database/README.md#épreuve-automatique-chaque-dimanche)) | 0 |
| 5 | **Veille de versions** | Renovate, lundi matin | [`renovate.json`](renovate.json) : PR de montée pour chaque tag épinglé | **avis** sur chaque PR Renovate : ce qui touche CE dépôt, verdict (Sonnet, 8 tours, [`version-review.yml`](.github/workflows/version-review.yml)) | ~0,3 session/PR |
| 7 | **Dérive** | à la main ou cron du poste admin, hebdo | [`drift.sh`](scripts/drift.sh) : valeurs et version des moteurs CLI-Helm, manifestes bruts, releases non décrites | aucune | 0 |
| 3 | **Dépouillement du WAF** | à la main, quotidien pendant la phase DetectionOnly | [`waf-digest.py`](scripts/waf-digest.py) : alertes condensées, sans données personnelles | **`--ask`** : tri faux positifs / suspects, exclusions au format de WAF.md (Sonnet, 3 tours) | ~0,1 session/jour, 1 à 2 semaines |

## Mise en service (une fois)

1. **Étiquette** : `gh label create nouveau-locataire` (le formulaire la pose).
2. **Settings → Actions → General** : cocher *Allow GitHub Actions to create and
   approve pull requests* (le guichet ouvre la PR).
3. **Secret `CLAUDE_CODE_OAUTH_TOKEN`** : `claude setup-token` sur ton poste,
   puis `gh secret set CLAUDE_CODE_OAUTH_TOKEN`. Sans lui, le guichet marche
   (le repli est sauté et le refus est posté tel quel) ; seul l'avis de version
   en dépend.
4. **App Claude** sur le dépôt (`/install-github-app` dans Claude Code) : elle
   fournit au workflow le jeton qui poste les commentaires.
5. **Renovate** : installer l'app *Mend Renovate* sur le dépôt. Sa PR
   d'accueil valide `renovate.json` — à relire avant de la fusionner.
6. **Alertes** : poser les deux règles vmalert de l'épreuve de restauration
   (database/README.md §4). Sans elles, l'épreuve échoue en silence.

## Le parcours d'un nouveau locataire

```
issue « Nouveau locataire »  ──►  PR (script, 0 quota)  ──►  revue, fusion
                                                              │
     scripts/tenant-keys.sh <nom> --database … --out ./sealed ◄┘   (poste admin)
     scripts/verify-tenant.sh <nom>                                 (tout vert ?)
     kit + SealedSecrets → dépôt de l'application
```

## Pas encore en place

**6 — Premier diagnostic d'alerte.** Une alerte vmalert réveillerait un agent
qui rassemble événements, `describe`, logs et derniers commits, puis pousse un
diagnostic. Elle demande ce que les autres n'ont pas : un composant dans le
cluster qui appelle Claude, donc un jeton d'accès **dans** le cluster, et un
`ServiceAccount` en lecture seule (sans accès aux Secrets). À poser seulement
une fois les alertes de base en place et leur bruit connu — un agent branché
sur une alerte qui oscille consomme en boucle. Garde-fous prévus :
déduplication par empreinte d'alerte, au plus N diagnostics par jour, Sonnet,
5 tours.

## Mesurer

Après une semaine : `/usage` dans Claude Code, et l'onglet Actions pour le
nombre d'exécutions des deux workflows à repli ou avis. Si un poste dépasse
l'estimation, c'est presque toujours l'entrée qui a grossi — réduire l'entrée,
pas le plafond.
