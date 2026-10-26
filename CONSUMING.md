# Protocole de consommation du socle

> **Phase 5 — modèle en transition.** Ce document décrit le « guichet » des
> datastores maison (locataires déclarés ici, Job de provisionnement, clés de
> locataires). Ces backends ont été retirés : une application consomme désormais
> les datastores mutualisés de `charts/platform` (PostgreSQL `postgres`, MinIO
> `minio`, Redis `redis`) via sa propre `Application` `charts/app`, et se
> provisionne elle-même à partir de credentials d'admin émis une fois côté socle
> (cf. [`docs/alignement-patterns-1.0.0.md`](docs/alignement-patterns-1.0.0.md)
> §6). Seule la partie **exposition d'API** (Kong + ingress) ci-dessous reste
> d'actualité ; le reste sera réécrit autour de `charts/app`.

Comment une application obtient et utilise les ressources mutualisées du cluster.
Le principe est le même pour toutes : **l'instance est partagée, mais chaque
application reçoit une ressource isolée avec son propre compte** — un seau et sa
clé, une base et son rôle, un préfixe de clés et son compte ACL. Aucune
application ne voit les données d'une autre.

> Ce protocole a vocation à rejoindre `platform-patterns` (patterns applicatifs)
> quand sa première version sera en place ; il vit ici en attendant, au plus près
> des services qu'il décrit. Les gabarits sont dans
> [`examples/consumer-app/`](examples/consumer-app/).

## Deux rôles

- **Admin du socle** — déclare le locataire dans le `values.yaml` du service (une
  entrée, relue en revue de code), ajoute la clé au Secret de locataires, laisse
  le Job de provisionnement créer la ressource et le compte. C'est le « guichet ».
- **Équipe applicative** — étiquette son namespace pour déclarer son besoin,
  reçoit les identifiants, dépose ses secrets d'accès, câble son application.

Ni l'un ni l'autre n'écrit dans le namespace de quelqu'un d'autre. C'est ce qui
rend le partage tenable.

## Les quatre ressources

| Ressource | Le service | On la demande… | On la joint à… | Isolation | Contrainte |
|---|---|---|---|---|---|
| **Exposition d'API** | Kong + ingress | hôte dans [`gateway/10-ingress-api-hosts.yaml`](gateway/) + Ingress classe `kong` chez soi | `kong-proxy.gateway.svc.cluster.local` (interne) | classe `kong` dédiée, routes par namespace | préserver l'en-tête `Host` |

Le détail de chaque service — et le « pourquoi » de ses choix — est dans son
propre `README.md`.

## La procédure, de bout en bout

Pour une application `mon-appli` (adapter le nom partout).

**1. Poser le namespace, avec ses étiquettes d'adhésion.**
Copier [`examples/consumer-app/namespace.yaml`](examples/consumer-app/namespace.yaml).
L'étiquette `database-client` est ce que sélectionne la NetworkPolicy du
service : la porter, c'est ouvrir la porte. (Le stockage objet maison et le
cache ayant été retirés en phase 5, leurs étiquettes `object-store-client` /
`cache-client` n'ont plus d'effet ici.)

**2. Demander les ressources (côté admin du socle).**
Pour chaque service utilisé, à la main :
Pour chaque service utilisé, ajouter une entrée `tenants` dans son `values.yaml`
et une clé dans son Secret de locataires (cf. la section « Ajouter une
application » du README du service). À la synchronisation suivante, le Job de
provisionnement crée la ressource, le compte et les droits — et **réapplique la
clé, si bien qu'une rotation se propage d'elle-même**.

**3. Déposer les secrets d'accès (côté application).**
Avec les identifiants fournis, remplir et exécuter
[`create-secrets.sh`](examples/consumer-app/create-secrets.sh), puis **sceller**
les secrets (kubeseal) — aucun secret en clair dans Git. La source de vérité des
identifiants reste le Secret de locataires du service ; on ne fait ici qu'en
redéposer une copie côté application.

**4. Câbler l'application.**
[`deployment.example.yaml`](examples/consumer-app/deployment.example.yaml) montre
le montage : l'application ne connaît que des **noms de service internes** et lit
ses identifiants depuis les secrets. Poser aussi
[`networkpolicy.yaml`](examples/consumer-app/networkpolicy.yaml) (refus par
défaut + sorties vers les services utilisés).

**5. Exposer l'API, si besoin.**
Deux ressources (cf. [`gateway/README.md`](gateway/)) :
[`api-ingress.yaml`](examples/consumer-app/api-ingress.yaml) pour les routes de
classe `kong` chez soi, **et** une entrée d'hôte à ajouter à
`gateway/10-ingress-api-hosts.yaml`. Ajouter au namespace la règle d'entrée
depuis `gateway` (fournie dans `networkpolicy.yaml`).

## Ce dont l'application n'a PAS à s'occuper

- **Les sauvegardes.** Chaque service mutualisé sauvegarde ce qu'il porte, pour
  tous ses locataires à la fois. Une application n'a ni à archiver sa base, ni
  les droits pour le faire. Ce qui lui revient, en revanche, c'est de **vérifier
  qu'une restauration fonctionne** avant d'en avoir besoin.

## Ce que l'application doit respecter

- **Redis** — préfixer **toutes** les clés par `<locataire>:`. L'ACL ne
  reconnaît que ce préfixe ; une clé nue est refusée (`NOPERM`).
- **PostgreSQL** — se connecter à **sa** base avec **son** rôle. Les autres bases
  refusent la connexion (`permission denied`).
- **MinIO** — n'écrire que dans **ses** seaux (ceux déclarés pour le locataire) ;
  la politique refuse le reste (`Access Denied`).
- **API** — ne jamais réécrire l'en-tête `Host` si la logique applicative en
  dépend ; passer les appels internes par `kong-proxy.gateway.svc`, pas en direct.

## Checklist d'onboarding

- [ ] Namespace posé avec les étiquettes `*-client` utiles.
- [ ] Locataire déclaré dans le `values.yaml` de chaque service + clé au Secret.
- [ ] Provisionnement passé au vert (logs du Job `provision-*`).
- [ ] Secrets d'accès déposés côté application **et scellés**.
- [ ] NetworkPolicies de l'application posées (refus par défaut + sorties).
- [ ] Application déployée, connexions vérifiées.
- [ ] (Si API) hôte ajouté au socle + Ingress `kong` + règle d'entrée `gateway`.
- [ ] Cloisonnement éprouvé (une ressource voisine doit être refusée — cf. la
      section « Vérification » du README de chaque service).
