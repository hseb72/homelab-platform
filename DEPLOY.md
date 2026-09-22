# Déploiement du socle

L'ordre et les prérequis pour installer les composants sur le cluster k3s. Le
détail de chaque composant reste dans son `README.md` ; ce document ne fait que
les **séquencer**.

## Deux paliers, deux modes

- **Backends applicatifs** (`object-store`, `database`, `cache`) — pilotés par
  **Argo CD** depuis Git. C'est l'objet de ce runbook.
- **Moteurs d'infra** (`platform-ingress`, `gateway`) — installés en **CLI-Helm**
  (`helm upgrade --install`), hors Argo. Déjà en service ; commandes dans leur
  `README.md`. Rien à refaire pour un déploiement des backends.

## Prérequis

- k3s en marche, `kubectl` pointant dessus.
- **Argo CD** installé dans le namespace `argocd`.
- **kubeseal** (SealedSecrets) configuré, comme pour le reste du cluster.
- Accès aux images pour relever les tags (poste avec `docker`, ou un registre
  miroir).

## 1. Le projet Argo CD partagé (une fois)

Un seul `AppProject`, `homelab-platform`, gouverne les trois namespaces. Il est
livré avec `object-store` et **doit être appliqué avant** toute Application.

```bash
kubectl apply -f object-store/argocd/project.yaml
```

> Rappel Argo : l'`AppProject` n'est pas synchronisé par les Applications.
> Toute évolution (nouveau namespace admis) exige un `kubectl apply` explicite de
> ce fichier — sinon le sync échoue sur « namespace … is not permitted in
> project », sans que la santé de l'app bouge.

## 2. Chaque backend (répéter pour object-store, database, cache)

L'ordre entre les trois est libre ; ils sont indépendants. Pour chacun :

**a. Renseigner le tag d'image** dans son `values-prod.yaml`. Le chart **refuse
de se rendre** tant qu'il est vide (garde-fou volontaire). La commande exacte
pour relever la version est en §0 du README du composant, p. ex. :

```bash
docker run --rm postgres:latest postgres --version   # → reporter dans database/values-prod.yaml
```

**b. Créer et sceller les secrets** (hors chart — §1 du README). Chaque service
attend deux Secret : un compte d'administration (jamais utilisé par les
applications) et un Secret de **clés de locataires** (la source de vérité des
identifiants). Exemple pour la base :

```bash
kubectl -n database create secret generic postgres-superuser \
  --from-literal=username=postgres \
  --from-literal=password="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
kubectl -n database create secret generic database-tenant-keys \
  --from-literal=findout="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
# puis kubeseal sur chacun.
```

(object-store : `minio-root` + `object-store-tenant-keys` ; cache : `cache-admin`
+ `cache-tenant-keys`. Détail et clés exactes en §1 de chaque README.)

**c. Appliquer l'Application** :

```bash
kubectl apply -f object-store/argocd/application.yaml
kubectl apply -f database/argocd/application.yaml
kubectl apply -f cache/argocd/application.yaml
kubectl -n argocd get applications -w
```

## 3. Vérifier

Pour chaque service, confirmer la synchro puis **éprouver le cloisonnement** —
c'est la seule vérification qui compte vraiment (un compte de locataire doit se
voir refuser une ressource voisine). Les commandes sont en §4 de chaque README.

```bash
kubectl -n object-store logs job/provision-1   # provisionnement des locataires
kubectl -n database     logs job/provision-1
kubectl -n cache        logs job/provision-1
```

## Ordre de bascule (récapitulatif)

1. `object-store/argocd/project.yaml` (le projet partagé) — **d'abord**.
2. Pour chaque backend : tag d'image → secrets scellés → `application.yaml`.
3. Vérifier synchro + cloisonnement.

Ajouter une application ensuite ne touche presque pas à ce dépôt : une entrée
`tenants` et une clé par service. Le parcours complet côté application est dans
[`CONSUMING.md`](CONSUMING.md).
