# Stockage objet mutualisé — MinIO

Une instance MinIO pour les petites applications du cluster. Chacune reçoit ses
**seaux** et un **compte qui n'ouvre que ces seaux** : le partage porte sur
l'instance, jamais sur les données.

## 0. Avant tout — les deux tags d'image

Le chart **refuse de se rendre** tant que `minio.image.tag` et
`provision.image.tag` sont vides. C'est voulu : un tag inventé donnerait un
`ImagePullBackOff` sans rapport apparent avec la cause.

```bash
docker run --rm quay.io/minio/minio:latest --version   # → RELEASE.…
docker run --rm quay.io/minio/mc:latest --version      # → RELEASE.…
```

Reporter les deux dans [`values-prod.yaml`](values-prod.yaml).

## 1. Les secrets (hors chart)

```bash
kubectl create namespace object-store --dry-run=client -o yaml | kubectl apply -f -

# Compte d'administration. Aucune application ne l'utilise : il ne sert qu'à
# MinIO lui-même et au Job de provisionnement.
kubectl -n object-store create secret generic minio-root \
  --from-literal=rootUser=admin \
  --from-literal=rootPassword="$(openssl rand -base64 32)"

# Une entrée par locataire : le nom du locataire → sa clé secrète.
# C'est la source de vérité de ces identifiants.
kubectl -n object-store create secret generic object-store-tenant-keys \
  --from-literal=database="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
```

Les sceller ensuite avec `kubeseal`, comme les autres secrets du cluster.

## 2. Installation

```bash
kubectl apply -f object-store/argocd/project.yaml
kubectl apply -f object-store/argocd/application.yaml
kubectl -n argocd get application object-store -w
```

Ou, pour un amorçage à la main :

```bash
helm upgrade --install object-store object-store/ \
  --namespace object-store --create-namespace \
  --values object-store/values.yaml \
  --values object-store/values-prod.yaml
```

## 3. Ajouter une application

Deux gestes, et **un seul fichier à modifier ici**.

**a. Déclarer le locataire** dans [`values.yaml`](values.yaml) :

```yaml
tenants:
  - name: database           # le socle lui-même : sauvegardes des bases
    buckets: [database-backups]
  - name: mon-appli          # ← la nouvelle
    buckets: [mon-appli-backups]
```

puis ajouter sa clé au secret `object-store-tenant-keys`. Le Job de
provisionnement, rejoué à chaque synchronisation, crée le seau, la politique et
le compte — et réapplique la clé, si bien qu'une rotation se propage d'elle-même.

**b. Côté application**, étiqueter le namespace qui doit joindre le stockage :

```yaml
metadata:
  labels:
    object-store-client: "true"
```

C'est cette étiquette que sélectionne la NetworkPolicy. **Rien à ajouter ici
pour donner l'accès** : l'application déclare son besoin chez elle, et personne
n'écrit dans le namespace d'un autre.

Il reste à créer, côté application, le secret qui porte `access-key` (le nom du
locataire) et `secret-key` (sa clé).

## 4. Vérification

```bash
kubectl -n object-store get pods
kubectl -n object-store logs job/provision-1        # le détail du provisionnement

# La console, sans l'exposer sur Internet :
kubectl -n object-store port-forward svc/minio 9001:9001
```

Éprouver le cloisonnement, qui est tout l'objet du dispositif :

```bash
# Avec le compte d'un locataire, un seau qui ne lui appartient pas doit être refusé.
mc alias set essai http://localhost:9000 findout "$CLE"
mc ls essai/findout-backups     # autorisé
mc ls essai/rental-backups      # doit échouer : Access Denied
```

## 5. Ce que je n'ai pas pu éprouver

Le chart a été écrit dans un environnement d'où l'image MinIO est inaccessible.
Deux points restent donc à confirmer au premier déploiement :

- **`readOnlyRootFilesystem: true`** sur le conteneur MinIO. Il n'écrit en
  principe que dans `/data`, et `/tmp` est monté. Si le pod ne démarre pas,
  c'est le premier bouton à relâcher :
  `security.containerSecurityContext.readOnlyRootFilesystem: false`.
- **`runAsUser: 1000`** avec `fsGroup` pour le volume. MinIO documente cette
  configuration, mais elle n'a pas été jouée ici.

Le script de provisionnement, lui, a été exécuté contre un `mc` simulé : les
seaux, la politique et le compte sont créés dans le bon ordre, et la politique
est bien bornée aux seuls seaux du locataire.
