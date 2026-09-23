# Cache mutualisé — Redis

Une instance Redis pour les petites applications du cluster. Chacune reçoit un
**compte ACL** qui n'ouvre **que ses propres clés** (préfixe `<nom>:`) : le
partage porte sur l'instance, jamais sur les données.

## 0. Avant tout — le tag d'image

Le chart **refuse de se rendre** tant que `redis.image.tag` est vide. C'est
voulu : un tag inventé donnerait un `ImagePullBackOff` sans rapport apparent
avec la cause.

```bash
docker run --rm redis:latest redis-server --version   # → Redis server v=7.4.2 …
```

Reporter le numéro dans [`values-prod.yaml`](values-prod.yaml). Le
provisionnement se fait avec le `redis-cli` livré dans cette même image : un
seul tag à tenir. **Redis ≥ 7** est requis pour les ACL par sélecteurs de clés.

## 1. Les secrets (hors chart)

```bash
kubectl create namespace cache --dry-run=client -o yaml | kubectl apply -f -

# Administrateur ACL. Aucune application ne l'utilise : il ne sert qu'au Job de
# provisionnement.
kubectl -n cache create secret generic cache-admin \
  --from-literal=adminPassword="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"

# Mots de passe des locataires — UN SEUL Secret pour tous, une entrée
# `--from-literal` par locataire (nom du locataire → son mot de passe). C'est la
# source de vérité de ces identifiants. Un locataire de plus = une ligne de plus
# dans CE Secret (cf. §3), jamais un second Secret du même nom.
kubectl -n cache create secret generic cache-tenant-keys \
  --from-literal=findout="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
```

Les sceller ensuite avec `kubeseal`, comme les autres secrets du cluster.

> Les identifiants sont produits sans caractères spéciaux (`tr -d '/+='`) : ils
> voyagent tels quels dans la commande `ACL SETUSER`.

## 2. Installation

```bash
# Le projet Argo CD partagé est livré avec object-store ; l'appliquer une fois
# suffit pour tout le socle.
kubectl apply -f object-store/argocd/project.yaml
kubectl apply -f cache/argocd/application.yaml
kubectl -n argocd get application cache -w
```

Ou, pour un amorçage à la main :

```bash
helm upgrade --install cache cache/ \
  --namespace cache --create-namespace \
  --values cache/values.yaml \
  --values cache/values-prod.yaml
```

## 3. Ajouter une application

Deux gestes, et **un seul fichier à modifier ici**.

**a. Déclarer le locataire** dans [`values.yaml`](values.yaml) :

```yaml
tenants:
  - name: findout
  - name: mon-appli          # ← la nouvelle
```

puis **ajouter son entrée au Secret** `cache-tenant-keys` — le même Secret pour
tous les locataires, une clé par locataire (la clé porte le nom du locataire).
Comme ce Secret est scellé, on régénère l'ensemble et on re-scelle, en
**conservant les mots de passe des locataires déjà en place** (les régénérer les
ferait tourner) :

```bash
kubectl -n cache create secret generic cache-tenant-keys \
  --from-literal=findout="…mot de passe existant, inchangé…" \
  --from-literal=mon-appli="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)" \
  --dry-run=client -o yaml | kubeseal -o yaml > cache-tenant-keys.sealed.yaml
# committer le SealedSecret, puis l'appliquer.
```

Le Job de provisionnement, rejoué à chaque synchronisation, (re)crée le compte
ACL borné à `mon-appli:*` — et réapplique le mot de passe, si bien qu'une
rotation se propage d'elle-même.

**b. Côté application**, étiqueter le namespace qui doit joindre le cache :

```yaml
metadata:
  labels:
    cache-client: "true"
```

C'est cette étiquette que sélectionne la NetworkPolicy. **Rien à ajouter ici
pour donner l'accès** : l'application déclare son besoin chez elle, et personne
n'écrit dans le namespace d'un autre.

Il reste à créer, côté application, le secret qui porte l'hôte
(`redis.cache.svc.cluster.local`), l'utilisateur (le nom du locataire) et son
mot de passe. **Toutes les clés de l'application doivent être préfixées
`<nom>:`** — c'est ce préfixe que l'ACL autorise.

## 4. Vérification

```bash
kubectl -n cache get pods
kubectl -n cache logs job/provision-1        # le détail du provisionnement

# Le cache, sans l'exposer sur Internet :
kubectl -n cache port-forward svc/redis 6379:6379
```

Éprouver le cloisonnement, qui est tout l'objet du dispositif :

```bash
# Avec le compte d'un locataire, ses propres clés sont ouvertes…
redis-cli -h localhost --user findout -a "$CLE" SET findout:essai ok
#   → OK

# …mais une clé hors de son préfixe lui est refusée.
redis-cli -h localhost --user findout -a "$CLE" SET rental:essai ko
#   → NOPERM this user has no permissions to access one of the keys …

# et l'utilisateur `default` est coupé.
redis-cli -h localhost PING
#   → NOAUTH Authentication required.
```

## 5. Ce que je n'ai pas pu éprouver

Le chart a été écrit dans un environnement d'où l'image Redis est inaccessible.
Points à confirmer au premier déploiement :

- **`readOnlyRootFilesystem: true`** et **`runAsUser: 999`** (l'utilisateur
  `redis` de l'image) avec `fsGroup` pour le volume. Redis n'écrit en principe
  que dans `/data`. Si le pod ne démarre pas, relâcher d'abord
  `readOnlyRootFilesystem`.
- **La fenêtre d'amorçage.** À la toute première installation, l'utilisateur
  `default` de Redis est ouvert jusqu'à ce que le Job de provisionnement pose
  l'administrateur et le referme. Cette fenêtre est étroite et confinée par les
  NetworkPolicies (seuls les namespaces adhérents joignent le cache), mais elle
  existe. Le Job grave ensuite l'ACL sur le volume (`ACL SAVE`), si bien qu'un
  redémarrage repart `default` déjà coupé.

Le script de provisionnement est idempotent : `ACL SETUSER … reset` réécrit
chaque compte à partir de l'état déclaré, et la clé du secret fait foi.
