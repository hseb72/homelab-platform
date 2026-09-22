# Protocole de consommation du socle

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
| **Stockage objet** | MinIO | entrée `tenants` dans [`object-store/values.yaml`](object-store/) + clé dans `object-store-tenant-keys` | `minio.object-store.svc.cluster.local:9000` | politique bornée aux seuls seaux du locataire | compte = `access-key`, clé = `secret-key` |
| **Base de données** | PostgreSQL | entrée `tenants` dans [`database/values.yaml`](database/) + mot de passe dans `database-tenant-keys` | `postgres.database.svc.cluster.local:5432` | `CONNECT` réservé au propriétaire de la base | se connecter avec `user=<locataire>`, `dbname=<base>` |
| **Cache** | Redis | entrée `tenants` dans [`cache/values.yaml`](cache/) + mot de passe dans `cache-tenant-keys` | `redis.cache.svc.cluster.local:6379` | ACL bornée au préfixe `<locataire>:*` | **toutes les clés préfixées `<locataire>:`** |
| **Exposition d'API** | Kong + ingress | hôte dans [`gateway/10-ingress-api-hosts.yaml`](gateway/) + Ingress classe `kong` chez soi | `kong-proxy.gateway.svc.cluster.local` (interne) | classe `kong` dédiée, routes par namespace | préserver l'en-tête `Host` |

Le détail de chaque service — et le « pourquoi » de ses choix — est dans son
propre `README.md`.

## La procédure, de bout en bout

Pour une application `mon-appli` (adapter le nom partout).

**1. Poser le namespace, avec ses étiquettes d'adhésion.**
Copier [`examples/consumer-app/namespace.yaml`](examples/consumer-app/namespace.yaml).
Les étiquettes `object-store-client`, `database-client`, `cache-client` sont ce
que sélectionnent les NetworkPolicies des services : les porter, c'est ouvrir la
porte ; ne garder que celles des services réellement utilisés.

**2. Demander les ressources (côté admin du socle).**
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
