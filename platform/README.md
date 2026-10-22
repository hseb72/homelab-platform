# `platform/` — instance du socle partagé (platform-patterns 1.0.0)

Ce dépôt est le **repo d'ops** : il instancie le chart `platform` de
[`platform-patterns`](https://github.com/hseb72/platform-patterns) **1.0.0** en
app-of-apps. Le plan d'ensemble et la procédure de migration des applications
sont dans [`../docs/alignement-patterns-1.0.0.md`](../docs/alignement-patterns-1.0.0.md).

| Fichier | Rôle |
|---|---|
| [`instance.yaml`](instance.yaml) | Nos valeurs pour `charts/platform` (namespaces, versions, tailles). Flags `ingress`/`kong`/`routeReport` **désactivés** jusqu'à la phase 3. |
| [`application.yaml`](application.yaml) | L'`Application` app-of-apps (chart OCI `1.0.0` + ces valeurs). |
| [`project.yaml`](project.yaml) | L'`AppProject` qui admet les namespaces et ressources du socle. |

## Appliquer (phase 1 — après revue)

```bash
kubectl apply -f platform/project.yaml
kubectl apply -f platform/application.yaml
kubectl -n argocd get applications -w
```

Ceci monte, **à côté de l'existant** (namespaces neufs, sans toucher à la
prod) : l'opérateur CNPG, le `Cluster` PostgreSQL, MinIO, Redis, Vault, et les
NetworkPolicies. Laisser l'**opérateur CNPG** devenir sain avant que le
`Cluster` ne se réconcilie.

## Secrets attendus (hors chart, scellés)

- `platform-minio` (ns `minio`) — `root-user` / `root-password` de MinIO.
- Par application, au moment de sa migration (ns `api-<app>`) :
  `<app>-pg-provisioner`, `<app>-minio-provisioner`, et `<app>-vault-provisioner`
  si chemin dynamique (cf. doc §6).

## Bootstrap Vault (hors-bande, une fois)

Après la première synchro : `vault operator init` + unseal, activer la méthode
d'auth Kubernetes et le moteur de secrets base de données. Le chart livre Vault
mais ne détient aucun secret.

## Phase 3 — bascule de l'edge

Passer `ingress`, `kong` et `routeReport` à `enabled: true` dans
`instance.yaml`, reprendre les valeurs WAF/proxy-protocol de l'edge, puis
basculer `platform-ingress` → `ingress` et `gateway` → `kong` sur la même IP
(fenêtre big-bang). Cf. doc §5 phase 3.
