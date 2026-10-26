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

**Backends applicatifs — retirés (phase 5).** Les datastores mutualisés maison
(MinIO `object-store/`, PostgreSQL `database/`, Redis `cache/`) et leur tooling
d'onboarding ont tous été retirés. Les applications consomment désormais
directement les datastores mutualisés de
[`charts/platform`](https://github.com/hseb72/platform-patterns) — PostgreSQL
CloudNativePG (ns `postgres`), MinIO (ns `minio`), Redis (ns `redis`) —,
provisionnés par application et instanciés ici dans [`platform/`](platform/).
Chaque application porte sa propre `Application` Argo pointant `charts/app` ; il
n'y a plus de liste de « locataires » tenue dans ce dépôt.

**Moteur d'edge — instancié par `charts/platform`.** Le frontal ingress-nginx
(classe `nginx`, TLS, WAF ModSecurity) et la gateway Kong DB-less sont désormais
rendus par `charts/platform` via l'app-of-apps [`platform/`](platform/) (ns
`ingress` et `kong`), et non plus par des charts maison installés en CLI-Helm
(phase 5 — les anciens `platform-ingress/` et `gateway/` ont été retirés).

| Composant | Namespace | Où |
|---|---|---|
| Frontal ingress-nginx (TLS, WAF) | `ingress` | [`platform/`](platform/) (`charts/platform`) |
| Kong OSS DB-less (API gateway) | `kong` | [`platform/`](platform/) (`charts/platform`) |

Il reste à CE dépôt **deux responsabilités d'edge**, dans [`edge/`](edge/) :
l'Ingress des hôtes d'API centralisés (`edge/api-hosts.yaml`, appliqué à la
main, hors Argo) et le runbook du WAF (`edge/WAF.md`).

## Déployer, consommer

- **[`DEPLOY.md`](DEPLOY.md)** — où se fait quoi aujourd'hui (socle via
  `charts/platform` dans [`platform/`](platform/), provisioning par application
  via `charts/app`). En transition — réécriture autour de `charts/platform` en
  cours (phase 5).
- **[`CONSUMING.md`](CONSUMING.md)** — le protocole de consommation. La partie
  **exposition d'API** (Ingress d'hôte dans `edge/`, routes Kong chez l'app)
  reste d'actualité ; le reste (ancien modèle locataire) est en cours de
  réécriture autour de `charts/app`.

## Évoluer

- **[`docs/alignement-patterns-1.0.0.md`](docs/alignement-patterns-1.0.0.md)** —
  le plan d'alignement sur [`platform-patterns`](https://github.com/hseb72/platform-patterns)
  1.0.0 (adoption de `charts/platform`, Vault, CloudNativePG) et la procédure de
  migration des applications. Scaffolding dans [`platform/`](platform/).

## Automatiser

- **[`AGENTS.md`](AGENTS.md)** — la veille de versions, la dérive, le
  dépouillement du WAF. Le script d'abord ; l'IA en exception, plafonnée. (En
  phase 5, le guichet d'onboarding et l'épreuve de restauration maison ont été
  retirés : les apps consomment le socle via `charts/app`, et la sauvegarde est
  assurée par CloudNativePG.)

## Principes

- **Un composant par répertoire**, avec son `README.md`. Le socle (datastores,
  edge, supervision) est instancié par `charts/platform` depuis
  [`platform/`](platform/) ; [`edge/`](edge/) porte les manifestes d'edge
  appliqués à la main.
- **Chaque application déclare son besoin chez elle.** Un composant mutualisé
  admet ses clients par une **étiquette de namespace**, jamais par une liste
  tenue ici — sinon chaque arrivée impose une modification de ce dépôt, et
  l'écart avec la réalité s'installe. (Une exception assumée : les hôtes d'API
  vivent dans un Ingress centralisé du namespace `kong`
  [`edge/api-hosts.yaml`](edge/api-hosts.yaml), un Ingress ne pouvant référencer
  qu'un Service de son propre namespace.)
- **Aucun secret dans Git.** Les secrets sont créés hors chart et scellés.
- **Pod Security `restricted`** sur les namespaces des backends, conteneurs non
  privilégiés, refus réseau par défaut.
