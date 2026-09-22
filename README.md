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

| Composant | Namespace | État |
|---|---|---|
| [`object-store/`](object-store/) — MinIO mutualisé (stockage objet) | `object-store` | à installer |
| [`database/`](database/) — PostgreSQL mutualisé (données) | `database` | à installer |
| [`cache/`](cache/) — Redis mutualisé (cache) | `cache` | à installer |

Chacun suit le même patron : une instance partagée, et pour chaque application
**une ressource isolée avec son compte** — un seau et sa clé pour MinIO, une
base et son rôle pour PostgreSQL, un préfixe de clés et son compte ACL pour
Redis. L'application déclare son besoin chez elle (étiquette de namespace) et le
locataire est déclaré ici, en une entrée relue en revue de code ; un Job de
provisionnement idempotent applique le reste. C'est le « portail de services »
sous sa forme la plus simple : GitOps plutôt qu'une interface, pour l'instant.

D'autres pourront rejoindre à mesure qu'ils se formalisent : la passerelle Kong
(`gateway`) et l'ingress en frontal, cert-manager, la supervision. Ils tournent
aujourd'hui sur le cluster sans être décrits ici ; les reprendre n'a d'intérêt
que si on le fait sans interruption de service — un pas à part, avec son plan de
bascule.

## Principes

- **Un chart par composant**, dans son répertoire, avec son `README.md`, ses
  valeurs de production et ses manifestes Argo CD.
- **Chaque application déclare son besoin chez elle.** Un composant mutualisé
  admet ses clients par une **étiquette de namespace**, jamais par une liste
  tenue ici — sinon chaque arrivée impose une modification de ce dépôt, et
  l'écart avec la réalité s'installe.
- **Aucun secret dans Git.** Les secrets sont créés hors chart et scellés.
- **Pod Security `restricted`** sur les namespaces, conteneurs non privilégiés,
  refus réseau par défaut.
