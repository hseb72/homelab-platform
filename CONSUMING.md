# Protocole de consommation du socle

Comment une application obtient et utilise les ressources mutualisées du cluster.
Le principe n'a pas changé : **l'instance est partagée, mais chaque application
reçoit une ressource isolée avec son propre compte** — un seau et sa clé, une
base et son rôle, un préfixe de clés et son compte ACL. Aucune application ne
voit les données d'une autre.

> **Depuis la phase 5, la mécanique a changé.** Les datastores maison et leur
> « guichet » (locataires déclarés ici, Job de provisionnement, clés de
> locataires) ont été retirés. Une application consomme désormais les datastores
> mutualisés de `charts/platform` (PostgreSQL CNPG `postgres`, MinIO `minio`,
> Redis `redis`, Vault `vault`) **via `charts/app`**, depuis SON dépôt — une
> `Application` Argo et un fichier de valeurs. Elle **se provisionne elle-même**
> (base + rôle, seau + compte, préfixe Redis) à partir de credentials d'admin
> émis une seule fois côté socle. Procédure complète :
> [`docs/alignement-patterns-1.0.0.md`](docs/alignement-patterns-1.0.0.md) §6 ;
> gabarits chez les patterns
> ([`examples/consumer/`](https://github.com/hseb72/platform-patterns/tree/main/examples/consumer)).

Ce document ne garde que ce qui reste **propre à CE dépôt** : l'exposition d'API
par l'edge. Le reste — provisioning, câblage, cloisonnement des datastores — est
porté par `charts/app` et documenté chez les patterns.

## Deux rôles

- **Admin du socle** — émet, une fois par application, les credentials d'admin de
  provisioning (rôle PostgreSQL `CREATEDB`, compte MinIO admin, jeton Vault),
  scellés dans le namespace de l'app. C'est le seul geste du socle par app ; il
  n'écrit rien d'autre chez elle. Et il pose l'hôte d'API (ci-dessous).
- **Équipe applicative** — porte son `Application` `charts/app`, étiquette ses
  namespaces, laisse le chart provisionner et câbler.

Ni l'un ni l'autre n'écrit dans le namespace de quelqu'un d'autre. C'est ce qui
rend le partage tenable.

## Exposition d'API — l'exception de ce dépôt

Un Ingress ne peut référencer qu'un Service de **son propre** namespace, et
`kong-proxy` vit dans `kong` (socle). L'hôte d'API d'une application doit donc
être déclaré **là**, pas chez elle : c'est la seule ressource centralisée du
dispositif. Deux ressources, à deux endroits :

| Ressource | Où | Qui la pose |
|---|---|---|
| **Hôte d'API** `api.<app>.crealcs.com` — Ingress classe `nginx` → `kong-proxy` | [`edge/api-hosts.yaml`](edge/api-hosts.yaml) (ns `kong`) | **admin du socle** (une entrée) |
| **Routes Kong** — Ingress classe `kong` | namespace de l'application | l'application (rendu par `charts/app`) |

- Joindre Kong en interne : `kong-proxy.kong.svc.cluster.local`.
- ⚠ **Ne jamais réécrire l'en-tête `Host`** (pas d'`upstream-vhost`, pas de
  normalisation) : la résolution de tenant en dépend, sinon 404 pour tous les
  sites. Détail, invariants et taille de corps par app : [`edge/README.md`](edge/).

## Ce que l'application doit respecter

- **PostgreSQL** — se connecter à **sa** base avec **son** rôle ; les autres bases
  refusent la connexion (`permission denied`).
- **MinIO** — n'écrire que dans **ses** seaux ; la politique refuse le reste
  (`Access Denied`).
- **Redis** — préfixer **toutes** les clés par son préfixe ; une clé nue est
  refusée (`NOPERM`).
- **API** — préserver l'en-tête `Host` ; passer les appels internes par
  `kong-proxy.kong.svc`, pas en direct.

## Ce dont l'application n'a PAS à s'occuper

- **Les sauvegardes.** CloudNativePG sauvegarde PostgreSQL (base backup
  hebdomadaire + archivage WAL continu) pour tous, vers le MinIO mutualisé
  (cf. [`platform/README.md`](platform/)). Une application n'a ni à archiver sa
  base, ni les droits pour le faire — mais il lui revient de **vérifier qu'une
  restauration fonctionne** avant d'en avoir besoin.
