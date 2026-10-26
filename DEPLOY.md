# Déploiement du socle

> **Phase 5 — en cours.** Les backends applicatifs maison (`object-store`,
> `database`, `cache`) ont été retirés. Les applications ne déploient plus de
> datastore ici : elles consomment directement les datastores mutualisés de
> `charts/platform` — PostgreSQL CloudNativePG (ns `postgres`), MinIO (ns
> `minio`), Redis (ns `redis`) —, provisionnés par application. Ce runbook, qui
> séquençait l'installation des backends maison, n'a donc plus d'objet sous sa
> forme actuelle ; il sera réécrit autour de `charts/platform` (ops du socle) et
> `charts/app` (côté applications). Cf.
> [`docs/alignement-patterns-1.0.0.md`](docs/alignement-patterns-1.0.0.md) §5.

## Où se fait quoi, aujourd'hui

- **Socle mutualisé (datastores, edge, supervision)** — instancié par
  `charts/platform` via l'app-of-apps [`platform/`](platform/) (chart OCI
  épinglé, valeurs dans `platform/instance.yaml`). Runbook et invariants :
  [`platform/README.md`](platform/README.md).
- **Provisioning par application** (base + rôle, seau + compte, préfixe Redis)
  — géré par l'application elle-même via `charts/app`, à partir des credentials
  d'admin de provisioning émis une fois côté socle. Procédure :
  [`docs/alignement-patterns-1.0.0.md`](docs/alignement-patterns-1.0.0.md) §6.

## Edge

Le frontal ingress-nginx (ns `ingress`) et Kong (ns `kong`) sont instanciés par
`charts/platform` ([`platform/`](platform/)) — plus de chart maison ni
d'install CLI-Helm. Il reste deux manifestes d'edge propres à ce dépôt, dans
[`edge/`](edge/), appliqués à la main :

```bash
kubectl apply -f edge/api-hosts.yaml   # hôtes d'API centralisés (Ingress nginx → kong-proxy)
```

Le WAF (ModSecurity, en observation) est configuré dans `platform/instance.yaml` ;
son runbook est dans [`edge/WAF.md`](edge/WAF.md).
