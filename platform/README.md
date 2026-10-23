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
- `postgres-backup-s3` (ns `postgres`) — `access-key` / `secret-key` d'un
  utilisateur MinIO ayant accès au seau `postgres-backups` (sauvegarde CNPG).
- Par application, à sa migration (ns `api-<app>`) : `<app>-pg-provisioner`,
  `<app>-minio-provisioner`, et `<app>-vault-provisioner` si chemin dynamique.

## Sauvegarde CNPG (hors-bande, une fois ; prérequis au retrait de `database/`)

La sauvegarde/PITR barman de CNPG écrit dans le MinIO mutualisé. Elle remplace
la sauvegarde du chart maison `database/` — à activer et **vérifier avant** de
retirer celui-ci (phase 5). `postgres.backup.enabled: true` dans
`instance.yaml`. Une fois :

```bash
# 1. Seau + utilisateur MinIO dédié à la sauvegarde (via un pod mc, cf. runbook
#    de bascule) : seau `postgres-backups`, user `postgres-backup` + policy.
# 2. Secret des clés S3 dans le ns postgres (scellé) :
kubectl -n postgres create secret generic postgres-backup-s3 \
  --from-literal=access-key=postgres-backup --from-literal=secret-key='<clé>' \
  --dry-run=client -o yaml | kubeseal --controller-namespace kube-system --format yaml > sealed/postgres-backup-s3.yaml
# 2b. ⚠ Le ns `postgres` doit devenir CLIENT du MinIO mutualisé pour y écrire :
#     sans ce label, la NetworkPolicy du MinIO refuse la connexion et le Backup
#     échoue (« Could not connect to the endpoint URL »). Le chart `platform` ne
#     le pose pas (le ns postgres n'est pas un client minio dans son modèle) —
#     cf. issue platform-patterns. À poser à la main :
kubectl label ns postgres platform-patterns.io/minio-client=true --overwrite
# 3. Après synchro Argo : déclencher un Backup à la demande et vérifier qu'il
#    arrive dans le seau.
kubectl -n postgres apply -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: verif-backup, namespace: postgres }
spec: { cluster: { name: postgres } }
YAML
kubectl -n postgres get backup verif-backup -w   # phase → completed
```

Tant que ce Backup n'est pas `completed`, ne PAS retirer la sauvegarde maison.

## Bootstrap Vault (hors-bande, une fois)

`vault operator init` + unseal, puis activer l'auth Kubernetes et le moteur de
secrets base de données. Le chart livre Vault mais ne détient aucun secret.

## Bootstrap Argo CD (hors-bande, une fois)

Deux réglages d'Argo, posés une fois sur le cluster — sans eux l'opérateur
CloudNativePG reste bloqué (OutOfSync puis échec de sync). Ce sont des réglages
du *cluster*, pas du chart.

1. **Ignorer le `.status` au calcul de diff.** En Server-Side Apply, Argo
   reconstruit un objet typé depuis la ressource vivante ; le `.status` du
   Deployment de l'opérateur porte des champs récents (`terminatingReplicas`,
   K8s ≥ 1.33) absents du schéma embarqué d'Argo → la comparaison échoue
   (`field not declared in schema`, statut `Unknown`). On retire le `.status`
   du diff (il appartient au cluster, pas à l'état désiré) :

   ```bash
   kubectl -n argocd patch configmap argocd-cm --type merge -p \
     '{"data":{"resource.compareoptions":"ignoreResourceStatusField: all\n"}}'
   kubectl -n argocd rollout restart statefulset argocd-application-controller
   ```

2. **Purger le résidu `last-applied-configuration` sur les CRD CNPG.** Les
   anciens apply client-side (helm/Argo) ont posé sur les CRD une annotation
   contenant le manifeste complet — énorme. Même en SSA, l'API server valide
   l'objet entier et rejette l'écriture (`metadata.annotations: Too long`) tant
   que ce résidu est là. À faire **une fois**, après être passé en SSA (le SSA
   ne la réécrit jamais) :

   ```bash
   for crd in $(kubectl get crd -o name | grep postgresql.cnpg.io); do
     kubectl annotate "$crd" kubectl.kubernetes.io/last-applied-configuration-
   done
   kubectl -n argocd patch application platform-cnpg-operator --type merge -p \
     '{"operation":{"initiatedBy":{"username":"manual"},"sync":{"prune":true,"syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}'
   ```

   (Le `patch .operation` force un sync immédiat sans la CLI `argocd` ; le
   controller surveille ce champ.)

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

# 2b. CoreDNS : repointer la résolution interne *.crealcs.com vers le NOUVEL edge.
#     Le ConfigMap coredns-custom (kube-system) réécrit *.crealcs.com vers le
#     Service du contrôleur ; sa cible doit nommer le ns du nouvel edge (`ingress`).
#     Oublié, *.crealcs.com = NXDOMAIN en interne → TOUT self-check ACME échoue et
#     les nouveaux certs restent `pending` (piège vécu : les certs .system bloqués).
kubectl -n kube-system patch configmap coredns-custom --type merge -p \
  '{"data":{"crealcs.override":"rewrite name regex (.+)\\.crealcs\\.com platform-ingress-ingress-nginx-controller.ingress.svc.cluster.local answer auto\n"}}'
kubectl -n kube-system rollout restart deployment coredns
# vérif depuis un pod : nslookup <hôte>.crealcs.com → ClusterIP de l'edge, pas NXDOMAIN

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
