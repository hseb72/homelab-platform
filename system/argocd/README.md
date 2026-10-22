# Argo CD (ns `argocd`)

Le CD GitOps du cluster. **L'install d'Argo CD est un bootstrap manuel** (manifeste
upstream épinglé) ; seul le **frontal UI** (`argocd.system.crealcs.com`) est repris
ici en GitOps (`ingress.yaml` + `../argocd-application.yaml`).

> Ce qui **reste côté appli** : l'`Application` et l'`AppProject` *de xpms*
> (`rental-platform/k8s/argocd/{application,project}.yaml`) déploient xpms — ce ne
> sont pas de l'outillage, ils restent là-bas. Chaque appli possède sa propre
> `Application`.

## Install (bootstrap manuel, une fois)

```bash
kubectl create namespace argocd 2>/dev/null || true
# Version ÉPINGLÉE (relever/figer la version réellement installée) :
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

Allègement RAM (nœud chargé) — scaler à 0 les composants optionnels inutilisés :
```bash
kubectl -n argocd scale deploy/argocd-dex-server \
  argocd-applicationset-controller argocd-notifications-controller --replicas=0
```

TLS terminé à l'edge → argocd-server en `--insecure` :
```bash
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deploy/argocd-server
```

Réglage socle déjà en place (cf. `platform/README.md` « Bootstrap Argo CD ») :
`resource.compareoptions: ignoreResourceStatusField: all` dans `argocd-cm`.

## Frontal UI (GitOps, repris ici)

```bash
kubectl apply -f system/project.yaml            # AppProject `system` (admet le ns argocd)
kubectl apply -f system/argocd-application.yaml # Application `argocd` → gère l'ingress
kubectl -n argocd get application argocd        # Synced/Healthy (adopte l'ingress existant)
kubectl -n argocd get certificate argocd-server-tls   # READY=True (DNS argocd.system requis)
```

Mot de passe admin initial :
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```
UI : `https://argocd.system.crealcs.com`.

## Piège connu (Argo, général)

L'**`AppProject` n'est PAS synchronisé par une Application** : toute modif de
`project.yaml` (nouvelle destination/namespace) n'a d'effet qu'après un
`kubectl apply -f system/project.yaml` explicite. Oublié → sync qui échoue sur
`namespace <x> is not permitted in project`, santé inchangée (GitOps cassé en
silence).

## Prérequis DNS

`argocd.system.crealcs.com` : couvert par le wildcard `*.system.crealcs.com` + la
réécriture CoreDNS `crealcs.override` (qui doit viser le ns du **nouvel** edge,
`ingress` — cf. `platform/README.md` phase 3). Sans ça le cert reste `pending`.
