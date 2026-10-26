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
| 5 | **Veille de versions** | Renovate, lundi matin | [`renovate.json`](renovate.json) : PR de montée pour chaque tag épinglé | **avis** sur chaque PR Renovate : ce qui touche CE dépôt, verdict (Sonnet, 8 tours, [`version-review.yml`](.github/workflows/version-review.yml)) | ~0,3 session/PR |
| 7 | **Dérive** | à la main ou cron du poste admin, hebdo | [`drift.sh`](scripts/drift.sh) : valeurs et version des moteurs CLI-Helm, manifestes bruts, releases non décrites | aucune | 0 |
| 3 | **Dépouillement du WAF** | à la main, quotidien pendant la phase DetectionOnly | [`waf-digest.py`](scripts/waf-digest.py) : alertes condensées, sans données personnelles | **`--ask`** : tri faux positifs / suspects, exclusions au format de WAF.md (Sonnet, 3 tours) | ~0,1 session/jour, 1 à 2 semaines |

> **Retraits de phase 5.** Les applications ne sont plus des « locataires »
> déclarés ici : chacune consomme le socle `platform-patterns` via `charts/app`
> depuis SON dépôt (une `Application` Argo). Les agents 1 (guichet) et 2
> (clés/vérification) et leurs scripts/workflows n'existent plus. L'agent 4
> (**épreuve de restauration**) est parti avec le chart `database/` : la
> sauvegarde et le PITR sont désormais assurés par CloudNativePG (`charts/platform`,
> ns `postgres`) ; l'épreuve de restauration côté socle mutualisé reste à
> réoutiller là-bas.

## Mise en service (une fois)

1. **Secret `CLAUDE_CODE_OAUTH_TOKEN`** : `claude setup-token` sur ton poste,
   puis `gh secret set CLAUDE_CODE_OAUTH_TOKEN`. Requis par l'avis de version
   (le seul agent qui appelle Claude).
2. **App Claude** sur le dépôt (`/install-github-app` dans Claude Code) : elle
   fournit au workflow le jeton qui poste les commentaires.
3. **Renovate** : installer l'app *Mend Renovate* sur le dépôt. Sa PR
   d'accueil valide `renovate.json` — à relire avant de la fusionner.

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
