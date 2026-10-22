# `platform/` — instance du socle partagé (platform-patterns 1.1.0)

Ce dépôt est le **repo d'ops** : il instancie le chart `platform` de
[`platform-patterns`](https://github.com/hseb72/platform-patterns) **1.1.0** en
app-of-apps. Le plan d'ensemble et la procédure de migration des applications
sont dans [`../docs/alignement-patterns-1.0.0.md`](../docs/alignement-patterns-1.0.0.md).

| Fichier | Rôle |
|---|---|
| [`instance.yaml`](instance.yaml) | Nos valeurs pour `charts/platform` (namespaces, versions, tailles). Edge (`ingress`/`kong`/`routeReport`) **activé** — phase 3. |
| [`application.yaml`](application.yaml) | L'`Application` app-of-apps (chart OCI `1.1.0` + ces valeurs). |
| [`project.yaml`](project.yaml) | L'`AppProject` qui admet les namespaces et ressources du socle. |

## Première application (phase 1 — fait)

```bash
kubectl apply -f platform/project.yaml
kubectl apply -f platform/application.yaml
kubectl -n argocd get applications -w
```

Monte l'opérateur CNPG, le `Cluster` PostgreSQL, MinIO, Redis, Vault et les
NetworkPolicies. Laisser l'opérateur CNPG devenir sain avant que le `Cluster` ne
se réconcilie.

## Secrets attendus (hors chart, scellés)

- `platform-minio` (ns `minio`) — `root-user` / `root-password` de MinIO.
- Par application, à sa migration (ns `api-<app>`) : `<app>-pg-provisioner`,
  `<app>-minio-provisioner`, et `<app>-vault-provisioner` si chemin dynamique.

## Bootstrap Vault (hors-bande, une fois)

`vault operator init` + unseal, puis activer l'auth Kubernetes et le moteur de
secrets base de données. Le chart livre Vault mais ne détient aucun secret.

## Phase 3 — bascule de l'edge (fenêtre big-bang, une seule IP)

`ingress`, `kong` et `routeReport` sont activés dans `instance.yaml`, avec les
valeurs WAF/Kong portées de l'ancien edge (`platform-ingress/`, `gateway/`). Le
cluster n'a **qu'une IP publique** : deux Services LoadBalancer ne peuvent pas
tenir `:80/:443` en même temps → il faut **retirer l'ancien edge avant** que le
nouveau ne prenne l'IP.

> Pré-requis : `platform-patterns` releasé en **`platform-1.1.0`** (OCI), sinon
> l'`Application` ne résout pas le chart. Annoncer la fenêtre (quelques secondes
> d'indisponibilité le temps de la reprise des ports).

```bash
# 1. Retirer l'ancien edge (releases CLI-Helm) → libère :80/:443 + la classe nginx
helm uninstall platform-ingress -n platform-ingress
helm uninstall kong -n gateway
kubectl get ingressclass nginx            # doit répondre NotFound (ports libérés)

# 2. Laisser Argo monter le nouvel edge (ingress/kong activés)
argocd app sync platform
kubectl -n ingress get deploy,svc         # LoadBalancer, EXTERNAL-IP = IP du nœud
kubectl -n kong get pods,svc              # kong-proxy (ClusterIP)

# 3. Vérifier (depuis l'extérieur de préférence)
curl -kI https://<hôte-public>/           # UI servie directement par l'edge
curl -kI https://<hôte-api>/api/…         # /api acheminé par Kong
kubectl -n argocd get applications        # platform-ingress, platform-kong : Synced/Healthy
```

La même classe `nginx` + le même Service LoadBalancer font que **tous les
Ingress existants sont repris sans modification ni changement DNS** (invariant
de la reprise, cf. `platform-ingress/WAF.md`). Le `routeReport` devient utile
dès que des routes de classe `kong` existent.

**Rollback** (tant qu'aucune app n'a migré) : repasser `ingress`/`kong` à
`enabled: false` dans `instance.yaml`, puis réinstaller l'ancien edge
(`helm upgrade --install platform-ingress …` + `kong …`).
