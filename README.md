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
| [`object-store/`](object-store/) — MinIO mutualisé | `object-store` | à installer |

D'autres pourront le rejoindre à mesure qu'ils se formalisent : la passerelle
Kong (`gateway`), cert-manager, la supervision. Ils tournent aujourd'hui sur le
cluster sans être décrits ici ; les reprendre n'a d'intérêt que si on le fait
sans interruption de service.

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
