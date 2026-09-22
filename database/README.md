# Base de données mutualisée — PostgreSQL

Une instance PostgreSQL pour les petites applications du cluster. Chacune reçoit
**sa base** et un **rôle qui n'ouvre que cette base** : le partage porte sur
l'instance, jamais sur les données.

## 0. Avant tout — le tag d'image

Le chart **refuse de se rendre** tant que `postgres.image.tag` est vide. C'est
voulu : un tag inventé donnerait un `ImagePullBackOff` sans rapport apparent
avec la cause.

```bash
docker run --rm postgres:latest postgres --version   # → postgres (PostgreSQL) 17.5 …
```

Reporter le numéro dans [`values-prod.yaml`](values-prod.yaml). Le
provisionnement se fait avec le `psql` livré dans cette même image : un seul tag
à tenir.

## 1. Les secrets (hors chart)

```bash
kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -

# Superutilisateur. Aucune application ne l'utilise : il ne sert qu'à
# PostgreSQL lui-même et au Job de provisionnement.
kubectl -n database create secret generic postgres-superuser \
  --from-literal=username=postgres \
  --from-literal=password="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"

# Une entrée par locataire : le nom du locataire → son mot de passe.
# C'est la source de vérité de ces identifiants.
kubectl -n database create secret generic database-tenant-keys \
  --from-literal=findout="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
```

Les sceller ensuite avec `kubeseal`, comme les autres secrets du cluster.

> Les identifiants sont produits sans caractères spéciaux (`tr -d '/+='`) pour
> rester lisibles dans une chaîne de connexion. Le script transmet quand même
> le mot de passe à PostgreSQL par une variable liée, jamais concaténé au SQL :
> une clé arbitraire ne peut ni casser ni injecter l'ordre.

## 2. Installation

```bash
# Le projet Argo CD partagé est livré avec object-store ; l'appliquer une fois
# suffit pour tout le socle.
kubectl apply -f object-store/argocd/project.yaml
kubectl apply -f database/argocd/application.yaml
kubectl -n argocd get application database -w
```

Ou, pour un amorçage à la main :

```bash
helm upgrade --install database database/ \
  --namespace database --create-namespace \
  --values database/values.yaml \
  --values database/values-prod.yaml
```

## 3. Ajouter une application

Deux gestes, et **un seul fichier à modifier ici**.

**a. Déclarer le locataire** dans [`values.yaml`](values.yaml) :

```yaml
tenants:
  - name: findout
    database: findout
  - name: mon-appli          # ← la nouvelle
    database: mon_appli
```

puis ajouter son mot de passe au secret `database-tenant-keys`. Le Job de
provisionnement, rejoué à chaque synchronisation, crée le rôle, la base et les
droits — et réapplique le mot de passe, si bien qu'une rotation se propage
d'elle-même.

**b. Côté application**, étiqueter le namespace qui doit joindre la base :

```yaml
metadata:
  labels:
    database-client: "true"
```

C'est cette étiquette que sélectionne la NetworkPolicy. **Rien à ajouter ici
pour donner l'accès** : l'application déclare son besoin chez elle, et personne
n'écrit dans le namespace d'un autre.

Il reste à créer, côté application, le secret qui porte l'hôte
(`postgres.database.svc.cluster.local`), le nom de la base, l'utilisateur (le
nom du locataire) et son mot de passe.

## 4. Vérification

```bash
kubectl -n database get pods
kubectl -n database logs job/provision-1        # le détail du provisionnement

# La base, sans l'exposer sur Internet :
kubectl -n database port-forward svc/postgres 5432:5432
```

Éprouver le cloisonnement, qui est tout l'objet du dispositif :

```bash
# Avec le compte d'un locataire, sa base est ouverte…
PGPASSWORD="$CLE" psql -h localhost -U findout -d findout -c '\conninfo'

# …mais celle d'un autre lui est refusée.
PGPASSWORD="$CLE" psql -h localhost -U findout -d rental -c '\conninfo'
#   → FATAL: permission denied for database "rental"
```

## 5. Ce que je n'ai pas pu éprouver

Le chart a été écrit dans un environnement d'où l'image PostgreSQL est
inaccessible. Deux points restent donc à confirmer au premier déploiement :

- **`readOnlyRootFilesystem: true`** sur le conteneur. L'image n'écrit en
  principe que dans son volume de données, dans `/var/run/postgresql` (la
  socket) et dans `/tmp`, tous montés. Si le pod ne démarre pas, c'est le
  premier bouton à relâcher :
  `security.containerSecurityContext.readOnlyRootFilesystem: false`.
- **`runAsUser: 999`** (l'utilisateur `postgres` de l'image) avec `fsGroup` pour
  le volume. C'est la configuration documentée, mais elle n'a pas été jouée ici.

Le script de provisionnement, lui, suit l'ordre attendu — rôle, base,
cloisonnement — et est idempotent : rôle et base sont créés s'ils manquent, le
mot de passe et le propriétaire réappliqués sinon, et le `CONNECT` n'est ouvert
qu'au propriétaire.
