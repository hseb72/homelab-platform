# SSO — Keycloak (ns `sso`)

Keycloak Quarkus géré en **GitOps par homelab-platform** (plus par l'install xpms).
Base PostgreSQL dédiée (CloudNativePG, opérateur du socle), ingress + cert-manager
via l'edge du socle. Issuer OIDC canonique : **`sso.crealcs.com`**.

```
Client ──443──▶ edge ingress-nginx (ns ingress, termine TLS, cert-manager)
                        └──▶ Service keycloak:8080 ──▶ Pod Keycloak
                                                         └──▶ sso-db (CNPG, ns sso)
```

| Fichier | Rôle |
|---|---|
| `10-postgres.yaml` | `Cluster` CNPG `sso-db` (base `keycloak`, secret `sso-db-app` auto-généré). |
| `20-keycloak.yaml` | Deployment + Service Keycloak (image pré-augmentée, `start --optimized`). |
| `30-ingress.yaml` | Ingress 2 hôtes : `sso.crealcs.com` (canonique) + `sso.system.crealcs.com` (alias). |
| `../sso-application.yaml` | L'`Application` Argo `sso` (projet `system`). |
| `../project.yaml` | L'`AppProject` `system`. |

## Prérequis (hors Git, dans le ns `sso`)

1. **Secret admin** (bootstrap du compte admin) :
   ```bash
   kubectl create namespace sso 2>/dev/null || true
   kubectl -n sso create secret generic keycloak-admin \
     --from-literal=username=admin \
     --from-literal=password="$(openssl rand -base64 24)"
   ```
   (À sceller/soumettre à SealedSecrets selon ta convention.)
2. **`sso-db-app`** : généré automatiquement par CNPG à la création du `Cluster`.
3. **Image GHCR** : auth au niveau nœud (`/etc/rancher/k3s/registries.yaml`) — aucun
   `ghcr-pull` requis sur ce cluster (l'`imagePullSecrets` du Deployment est toléré).

## Bootstrap (une fois)

```bash
kubectl apply -f system/project.yaml
kubectl apply -f system/sso-application.yaml
kubectl -n argocd get application sso -w        # Synced/Healthy
kubectl -n sso get cluster sso-db               # "Cluster in healthy state"
kubectl -n sso get certificate                  # keycloak-crealcs-tls → READY=True
```

Argo **adopte** les ressources déjà en place (mêmes noms, même ns) sans coupure, et
les met à jour vers cette version du dépôt — c'est précisément ce qui décorrèle le
SSO de la mise à jour de xpms.

## Vérifier

```bash
curl -sI https://sso.crealcs.com/realms/master | head -1        # 200/301
# alias system (requiert DNS sso.system.crealcs.com) :
curl -sI https://sso.system.crealcs.com/realms/master | head -1
```
Console admin : `https://sso.crealcs.com/admin/` (login = secret `keycloak-admin`).

## Points durs

- **`sso.crealcs.com` est l'issuer OIDC** (`KC_HOSTNAME`), codé dans tous les clients
  (callbacks Google/Keycloak). **Ne jamais le renommer.** Le `.system` ne s'applique
  qu'à l'alias.
- **Options de build gravées dans l'image** (`KC_DB`, `KC_FEATURES=organization`,
  `KC_HEALTH_ENABLED`, `KC_METRICS_ENABLED`, `KC_HTTP_ENABLED`) : en `--optimized`,
  Keycloak refuse de démarrer si le manifeste diverge de l'image. Toute modif passe
  par le Dockerfile **et** le manifeste, ensemble.
- **Hairpin / CoreDNS** : le self-check ACME résout le nom public depuis le cluster ;
  `sso.crealcs.com` (et `sso.system.crealcs.com`) doivent avoir une entrée `template`
  dans le ConfigMap `coredns-custom` (kube-system) pointant l'IP interne, sinon le
  cert reste `pending`.

## Image Keycloak (build ici)

L'image pré-augmentée est désormais construite **dans ce dépôt** :
[`Dockerfile`](Dockerfile) + workflow [`build-keycloak.yml`](../../.github/workflows/build-keycloak.yml)
→ publie `ghcr.io/hseb72/homelab-platform/keycloak:26.0`. Plus de dépendance au
dépôt rental-platform.

Bascule (pour éviter toute coupure SSO — le Deployment est en `strategy: Recreate`) :
1. Publier l'image ici (merge du Dockerfile sur `main`, ou *Run workflow*) et
   **attendre** qu'elle soit disponible dans GHCR.
2. Repointer `image:` dans `20-keycloak.yaml` vers
   `ghcr.io/hseb72/homelab-platform/keycloak:26.0`.
3. Retirer le `Dockerfile` + workflow de rental-platform.

> ⚠ Runner : le workflow cible le runner self-hosted `[self-hosted, proxmox]` de
> l'org. S'il n'est pas disponible pour ce dépôt, basculer sur `ubuntu-latest`
> (simple docker build).
