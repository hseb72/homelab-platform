# Alignement du socle sur platform-patterns 1.0.0

Ce document décrit **comment mettre le socle en conformité** avec
[`platform-patterns`](https://github.com/hseb72/platform-patterns) **1.0.0**
(pattern `shared`), et **comment migrer les applications** avec le moins de
friction possible. Les arrêts de service sont acceptés pendant la bascule.

> État : plan accepté (stratégie A, cf. §2). Exécution par PR, une brique par
> phase. Rien dans ce document n'est encore appliqué au cluster.

## 1. Pourquoi

À sa création, ce dépôt était la **seule** implémentation du socle partagé :
des charts maison (`object-store`, `database`, `cache`, `gateway`,
`platform-ingress`), un provisionnement piloté par une **liste de locataires**,
des secrets statiques scellés, un guichet d'onboarding.

`platform-patterns` 1.0.0 fournit désormais une implémentation **canonique** du
même rôle : un chart `platform` (app-of-apps) qui *livre et maintient* les
outils, et un chart **unique** `app` que chaque application consomme — le plus souvent
en `mode: shared`, xpms en `mode: dedicated` (cf. §2). Le dépôt des patterns dit explicitement qu'une instance se
déploie « depuis un repo d'ops, à partir de `charts/platform` **ou par tout
autre moyen qui honore le contrat** ».

Notre socle est donc une implémentation *maison, antérieure* qui a **divergé**
du modèle. On le réaligne.

## 2. Décisions

- **Stratégie A — adopter `charts/platform`.** `homelab-platform` devient le
  **repo d'ops** : il instancie `charts/platform` (app-of-apps, épinglé
  `1.0.0`) et retire les charts maison. C'est le seul choix qui aligne
  nativement noms/labels/DNS sur les défauts du chart `app` — donc où migrer
  une application revient à pointer une `Application` sur `charts/app`, sans
  réécrire de coordonnées.
- **Namespace de l'edge : `ingress`** (et non `front`, jugé source de
  confusion). C'est un nom de valeur, pas un invariant du contrat : les apps le
  désignent par `shared.webIngress.controllerNamespace: ingress` — **la seule
  surcharge** qu'impose notre nommage. Tous les autres namespaces suivent les
  défauts des patterns : `kong`, `vault`, `postgres`, `minio`, `redis`,
  `cnpg-system`, `route-report`.
- **Vault livré tôt, dynamique ensuite.** La plateforme livre Vault + l'injector
  dès la phase 1 (le bootstrap init/unseal + moteur DB reste hors-bande, une
  fois). Les applications migrent d'abord sur le chemin **statique + Reloader**,
  puis basculent au **dynamique par pod** quand elles savent relire
  `/vault/secrets/db` et se reconnecter. On ne bloque pas une migration sur la
  coopération applicative.
- **PostgreSQL : CloudNativePG.** Le `Cluster` CNPG remplace le StatefulSet
  maison ; il apporte réplicas, bascule et sauvegarde/PITR natifs — ce qui rend
  **caducs** la sauvegarde maison et l'épreuve de restauration (remplacées par
  l'équivalent CNPG), pas perdus.
- **Provisionnement côté application.** Chaque app porte des Jobs PreSync
  (chart `app`) qui créent *sa* base / *son* seau avec un **credential d'admin
  émis par le socle** (référencé par nom). La liste `tenants` du socle et le
  guichet disparaissent : l'app déclare tout chez elle.
- **xpms (rental) reste en `mode: dedicated`, pas `shared`.** Contrairement
  aux autres apps, xpms garde ses propres moteurs de données (PostgreSQL CNPG,
  Redis, MinIO) **embarqués dans sa release**, dans son namespace. Il ne
  consomme pas les datastores mutualisés (`postgres`/`minio`/`redis`) et n'a
  donc **ni provisioning vers le partagé, ni `pg_dump`/`mc mirror` vers le
  socle**. Le reste du contrat (edge `ingress`/`kong`, labels, Vault) lui
  s'applique normalement. Toute phase qui parle de « migration vers le
  mutualisé » ou de « retrait des datastores » exclut xpms : ses données ne
  bougent pas.

## 3. Écarts (socle actuel → contrat 1.0.0)

| Axe | Contrat 1.0.0 | Socle actuel | Action |
|---|---|---|---|
| Namespaces socle | `ingress`*, `kong`, `vault`, `postgres`, `minio`, `redis`, `cnpg-system`, `route-report` | `platform-ingress`, `gateway`, `database`, `object-store`, `cache` ; pas de Vault | re-stand-up via `charts/platform` |
| Labels client | `platform-patterns.io/<svc>-client` | `object-store-client` / `database-client` / `cache-client` | portés par `charts/app` (défauts) |
| Namespaces app | `ui-<app>` + `api-<app>` | un seul ns | portés par `charts/app` |
| PostgreSQL | CNPG `Cluster`, svc `postgres-rw.postgres` | StatefulSet `postgres.database` | migration de données |
| Secrets | Vault dynamique (+ statique/Reloader pour MinIO) | `*-tenant-keys` statiques | Vault + bascule progressive |
| Provisionnement | Jobs PreSync **côté app** + cred d'admin émis par le socle | Jobs **côté socle** + liste `tenants` | inversion |
| Routage | UI direct par l'edge (`nginx`) ; **seul `/api`** par Kong (`kong`) | Kong pour l'API | conserver, formaliser l'UI |
| Report de routes | CronJob → page HTML privée | absent | fourni par `charts/platform` |
| Consommation | chart `app` OCI épinglé | gabarits copiables | chaque app pointe `charts/app` |

\* `front` dans les patterns ; renommé `ingress` chez nous (cf. §2).

## 4. Architecture cible

```
                    ┌──────── ns: ingress (edge ingress-nginx, TLS + WAF) ───────┐
 navigateur ─ host ►│  "/"    ───────────────────────────────────────► ui-<app> │
                    │  "/api" ─► ns: kong (Kong) ─► api-<app>                     │
                    └─────────────────────────────────────────────────────────────┘
 api-<app> ─► postgres-rw.postgres | minio.minio | redis.redis   +   vault (secrets)
            (CNPG)                  (seau par app)  (préfixe par app)  (creds dynamiques)

 ns: postgres ─► minio.minio   ◄─ UNIQUEMENT pour la SAUVEGARDE CNPG (barman →
                 (seau postgres-backups)   seau postgres-backups) ; PAS un accès
                                           applicatif. Cf. note ci-dessous.
```

Coordonnées que les applications visent (défauts des patterns — **aucune
surcharge sauf l'edge**) :

| Service | Hôte interne | Label à porter sur `api-<app>` |
|---|---|---|
| PostgreSQL | `postgres-rw.postgres.svc.cluster.local:5432` | `platform-patterns.io/postgres-client` |
| MinIO | `minio.minio.svc.cluster.local:9000` | `platform-patterns.io/minio-client` |
| Redis | `redis.redis.svc.cluster.local:6379` | `platform-patterns.io/redis-client` |
| Vault | `ns: vault` | `platform-patterns.io/vault-client` |
| Kong (data-plane) | `ns: kong` | `platform-patterns.io/kong-client` (BFF) |
| Edge ingress | `ns: ingress` | — (`webIngress.controllerNamespace: ingress`) |

> **Arête hors-modèle : `postgres → minio` pour la sauvegarde.** Quand la
> sauvegarde CNPG (`postgres.backup.enabled`) vise le MinIO mutualisé, le pod
> PostgreSQL écrit dans le seau `postgres-backups` — le ns `postgres` doit donc
> être admis par la NetworkPolicy du MinIO. Ce n'est **pas** un accès applicatif :
> `postgres` n'est pas « locataire » du MinIO, il y dépose ses sauvegardes. Le
> contournement actuel réutilise l'étiquette générique
> `platform-patterns.io/minio-client` sur le ns `postgres`, ce qui est imprécis
> (il ouvre tout MinIO, pas seulement le backup). Le correctif propre est amont
> (platform-patterns#23) : que le chart exprime cette arête comme **spécifique à
> la sauvegarde**. En attendant, étiquetage hors-bande documenté dans
> `platform/README.md` (§Sauvegarde CNPG, étape 2b).

## 5. Plan de mise à jour du socle

Chaque phase est une (ou quelques) PR. Les moteurs `ingress`/`kong` ne bougent
qu'en phase 3 : jusque-là le socle canonique monte **à côté** de l'existant,
sans toucher à la production.

### Phase 0 — Scaffolding (ce dépôt devient repo d'ops)
- `platform/instance.yaml` — valeurs de `charts/platform` (nos namespaces,
  versions amont déjà en prod, tailles de volumes). `ingress`/`kong`/report
  **désactivés** (phase 3).
- `platform/application.yaml` — l'`Application` app-of-apps (multi-source :
  chart OCI `platform` 1.0.0 + ces valeurs).
- `platform/project.yaml` — l'`AppProject` qui admet les namespaces du socle.
- Rien n'est appliqué : revue d'abord.

### Phase 1 — Socle canonique à côté de l'existant
- Appliquer l'app-of-apps : `cnpg-system` (opérateur), puis `postgres` (Cluster
  CNPG), `minio`, `redis`, `vault`, NetworkPolicies. Vérifier que l'opérateur
  CNPG est sain **avant** que le `Cluster` ne se réconcilie.
- **Bootstrap Vault** (hors-bande, une fois) : init + unseal, méthode d'auth
  Kubernetes, moteur de secrets base de données.
- Éprouver le cloisonnement par labels `platform-patterns.io/<svc>-client`.

### Phase 2 — Migration des données (par datastore, arrêt court)
- **PostgreSQL** — par base : `pg_dump` depuis `postgres.database` → `restore`
  dans `postgres-rw.postgres` (CNPG). Script par base.
- **MinIO** — `mc mirror object-store/<seau> minio/<seau>` (nouveau namespace).
- **Redis** — cache : on repart vide, rien à migrer.

### Phase 3 — Bascule de l'edge (fenêtre big-bang, une seule IP publique)
- Activer `ingress`/`kong`/`route-report` dans `platform/instance.yaml`.
- Déplacer l'edge de `platform-ingress` → `ingress` et Kong de `gateway` →
  `kong` (même classe `nginx`/`kong`, même Service LoadBalancer → même IP
  nœud ; retirer les anciens). C'est la mécanique du runbook `platform-ingress`
  — quelques secondes d'indisponibilité.

### Phase 4 — Migration des applications
Voir §6. Ordre conseillé : un cobaye (treasurehunters ou mtgwars), puis
prolearning (×3), wh4chars, findout, enfin rental.

> **rental (xpms) = `mode: dedicated`** (cf. §2) : il suit §6 **sans** les
> étapes de provisioning et de migration de données vers le mutualisé (6.a et
> 6.c). Ses datastores restent embarqués dans sa release ; seuls l'edge, les
> labels et Vault s'alignent. Le mettre en dernier reste conseillé, mais c'est
> la migration la plus légère côté données (rien à déplacer).

### Phase 5 — Retrait du socle maison
- Supprimer `object-store/`, `database/`, `cache/`, `gateway/`,
  `platform-ingress/`, le guichet (`scripts/`, workflows), la liste `tenants`.
  > Ces charts maison sont les **datastores mutualisés du socle** et le
  > tooling d'onboarding. Les retirer suppose que **toutes les apps `shared`**
  > ont migré leurs données (phase 4). **xpms (dedicated) n'y stocke rien** :
  > ses moteurs vivent dans sa propre release, leur suppression ici ne le
  > concerne pas et ne doit pas attendre après lui.
- Réécrire `README`, `CONSUMING.md`, `DEPLOY.md`, `AGENTS.md` autour de
  `charts/platform` (ops) et `charts/app` (apps). Archiver l'ancien.

## 6. Procédure de migration d'une application

Procédure du **pattern `shared`** (le cas par défaut). **xpms (rental) est en
`dedicated`** : voir l'encart en fin de section pour ce qui change.

Pour une application `monapp` (release → namespaces `ui-monapp` / `api-monapp`).

**a. Côté socle — émettre les credentials d'admin de provisioning** dans
`api-monapp` (le seul geste du socle par app), scellés :
- `monapp-pg-provisioner` — rôle PostgreSQL `CREATEDB` (crée la base de l'app) ;
- `monapp-minio-provisioner` — compte MinIO admin (crée le seau) ;
- `monapp-vault-provisioner` — jeton Vault (configure le rôle dynamique) — si
  chemin dynamique.

**b. Côté dépôt de l'application — un fichier `deploy/application.yaml`** : une
`Application` Argo pointant le chart `app` OCI épinglé `1.0.0`, `mode: shared`.
Valeurs (gabarit prêt dans
[`examples/consumer/`](https://github.com/hseb72/platform-patterns/tree/main/examples/consumer)
des patterns) ; **la seule coordonnée à adapter à notre socle est l'edge** :

```yaml
shared:
  namespaces: { create: true }
  front: { type: spa }                 # ou bff
  clients: { postgres: true, minio: true, redis: true, vault: true }
  gatewayDataplaneNamespace: kong
  webIngress:
    className: nginx
    controllerNamespace: ingress        # ← seule surcharge due à notre nommage
    hosts: [monapp.example.tld]
    tls: { enabled: true, clusterIssuer: <notre-issuer> }
  kongIngress:
    className: kong
    hosts: [monapp.example.tld]
    rules: [ { path: /api, service: api } ]
  provisioning:
    enabled: true
    postgres: { host: postgres-rw.postgres.svc.cluster.local, adminSecret: monapp-pg-provisioner }
    minio:    { endpoint: http://minio.minio.svc.cluster.local:9000, bucket: monapp, adminSecret: monapp-minio-provisioner }
api:
  env:
    S3_ENDPOINT: http://minio.minio.svc.cluster.local:9000
    S3_BUCKET: monapp
    REDIS_ADDR: redis.redis.svc.cluster.local:6379
    REDIS_PREFIX: "monapp:"
```

**c. Migrer les données** (arrêt court de l'app) :
- base : `pg_dump` ancien → `psql`/`pg_restore` dans CNPG (la base est créée par
  le Job de provisionnement de l'app) ;
- seau(x) : `mc mirror` de l'ancien MinIO vers le nouveau ;
- cache : rien (repart vide).

**d. Basculer et nettoyer** : retirer l'entrée de l'app des `values.yaml` du
socle maison (jusqu'au retrait complet, phase 5), vérifier UI + `/api`,
cloisonnement.

**Pourquoi c'est simple** : une `Application`, une surcharge (`ingress`), des
Jobs de provisionnement qui créent la tranche tout seuls. L'app ne modifie plus
jamais le repo de socle.

> **Variante `dedicated` — xpms (rental).** L'`Application` pointe `charts/app`
> en `mode: dedicated` : le chart monte les datastores (CNPG, Redis, MinIO)
> **dans la release de l'app**, pas de consommation du mutualisé. Donc :
> - **6.a (credentials de provisioning du socle)** → *sans objet* : rien à
>   émettre côté socle, l'app gère ses propres secrets de données.
> - **6.b** → `mode: dedicated` ; les clés `provisioning` et les `S3_ENDPOINT`/
>   `REDIS_ADDR` pointant le mutualisé n'ont pas lieu d'être (le chart câble les
>   services internes de la release). Seul l'edge (`webIngress.controllerNamespace:
>   ingress`, `kongIngress`) reste à surcharger, comme pour `shared`.
> - **6.c (migration de données)** → *sans objet* : les données **restent en
>   place**, on ne `pg_dump`/`mc mirror` rien vers le socle.
> - **6.d** → identique (bascule de l'edge, vérif UI + `/api`, cloisonnement).

## 7. Ce qui est retiré / conservé

- **Retiré** : charts maison des cinq composants, liste `tenants`, guichet
  (`add-tenant.py`, workflows), sauvegarde & épreuve de restauration maison
  (remplacées par CNPG), gabarits `examples/consumer-app/`.
- **Conservé / repris** : l'IP publique unique et sa mécanique de cutover, le
  WAF ModSecurity (valeurs de l'edge), les versions amont déjà éprouvées, la
  veille Renovate et le dépouillement WAF (réoutillés sur les nouveaux charts),
  l'exigence « aucun secret dans Git » (Vault + SealedSecrets).

## 8. Journal des décisions

- **A** plutôt que retrofit : source de vérité unique (patterns), migration
  d'app triviale.
- Edge nommé **`ingress`** (pas `front`) : lisibilité ; coûte une surcharge
  `controllerNamespace` par app, assumée.
- Vault **livré tôt**, bascule dynamique **par app ensuite** : ne bloque pas une
  migration sur la coopération applicative.
- Postgres **CNPG** : réplicas + sauvegarde/PITR natifs, remplace l'outillage
  maison.
