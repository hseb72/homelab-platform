# homelab-platform

Les composants **mutualisés** du cluster k3s : ce que plusieurs applications
partagent, et qui n'appartient donc à aucune d'elles.

## Pourquoi ce dépôt

Un composant partagé qui vit dans le dépôt d'une application finit par lui
appartenir. On s'en aperçoit au moment où une deuxième application veut s'en
servir : il faut alors écrire une règle dans le namespace de la première, et
toute évolution demande un aller-retour dans un dépôt qui n'a rien à voir.

C'est arrivé avec le stockage objet, déployé au départ comme sous-chart de
l'application de gestion immobilière. D'où ce dépôt.

## Composants

Deux paliers, selon ce dont dépend le composant.

**Backends applicatifs — pilotés par Argo CD.** Un chart maison par composant,
synchronisé depuis Git. Une instance partagée, et pour chaque application **une
ressource isolée avec son compte** — un seau et sa clé pour MinIO, une base et
son rôle pour PostgreSQL, un préfixe de clés et son compte ACL pour Redis.
L'application déclare son besoin chez elle (étiquette de namespace) et le
locataire est déclaré ici, en une entrée relue en revue de code ; un Job de
provisionnement idempotent applique le reste. C'est le « portail de services »
sous sa forme la plus simple : GitOps plutôt qu'une interface, pour l'instant.

| Composant | Namespace | État |
|---|---|---|
| [`object-store/`](object-store/) — MinIO mutualisé (stockage objet) | `object-store` | à installer |
| [`database/`](database/) — PostgreSQL mutualisé (données) | `database` | à installer |
| [`cache/`](cache/) — Redis mutualisé (cache) | `cache` | à installer |

**Moteurs d'infra — installés en CLI-Helm, hors Argo.** Le frontal et la
gateway portent ce dont Argo lui-même dépend : ils se tiennent volontairement en
dessous. Chart **amont** épinglé, **valeurs versionnées ici**, install par
`helm upgrade --install` en ligne de commande — comme cert-manager, CNPG et
VictoriaMetrics. Le README de chaque dossier porte le runbook et les invariants.

| Composant | Namespace | Chart amont | État |
|---|---|---|---|
| [`platform-ingress/`](platform-ingress/) — ingress-nginx (frontal, TLS, WAF) | `platform-ingress` | `ingress-nginx/ingress-nginx` | en service, rapatrié |
| [`gateway/`](gateway/) — Kong OSS DB-less (API gateway) | `gateway` | `kong/kong` | en service, rapatrié |

D'autres moteurs tournent aujourd'hui sur le cluster sans être encore décrits
ici (cert-manager, la supervision) ; les rapatrier n'a d'intérêt que si on le
fait sans interruption de service.

## Principes

- **Un composant par répertoire**, avec son `README.md`. Les backends applicatifs
  ajoutent leurs valeurs de production et leurs manifestes Argo CD ; les moteurs
  d'infra, leurs valeurs de chart amont et leur runbook d'installation.
- **Chaque application déclare son besoin chez elle.** Un composant mutualisé
  admet ses clients par une **étiquette de namespace**, jamais par une liste
  tenue ici — sinon chaque arrivée impose une modification de ce dépôt, et
  l'écart avec la réalité s'installe. (La gateway a une exception assumée : les
  hôtes d'API vivent dans un Ingress centralisé du namespace `gateway`, un
  Ingress ne pouvant référencer qu'un Service de son propre namespace.)
- **Aucun secret dans Git.** Les secrets sont créés hors chart et scellés.
- **Pod Security `restricted`** sur les namespaces des backends, conteneurs non
  privilégiés, refus réseau par défaut.
