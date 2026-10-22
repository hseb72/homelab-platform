# `system/` — outillage de plateforme, isolé des applications

L'outillage transverse (SSO, CI/CD, monitoring) vivait **dans** l'install xpms
(`rental-platform/k8s/{argocd,monitoring,sso}`) — une erreur de conception
d'origine : son cycle de vie était accroché à celui de l'appli xpms (d'où « SSO ko
faute de mise à jour de xpms »). On le **sort** ici, chacun avec son **Application
Argo propre** (projet `system`), son namespace dédié, et un frontal en
**`<nom>.system.crealcs.com`**.

## État de l'extraction

| Outil | Namespace | Hôte cible | Statut |
|---|---|---|---|
| **SSO** (Keycloak) | `sso` | `sso.crealcs.com` (canonique, issuer OIDC) + `sso.system.crealcs.com` (alias) | **extrait** → `system/sso/` |
| **Argo CD** | `argocd` | `argocd.system.crealcs.com` | **extrait** (ingress UI en GitOps ; install = bootstrap manuel) → `system/argocd/` |
| **Monitoring** (Grafana/VictoriaMetrics) | `monitoring` | `grafana.system.crealcs.com` | **extrait (Helm CLI)** → `system/monitoring/` |

> Le SSO garde `sso.crealcs.com` comme hôte **canonique** : c'est l'issuer OIDC codé
> dans tous les clients. Le schéma `.system` ne s'y applique qu'en **alias**. Pour
> argocd/grafana (UIs d'admin), `.system` est l'hôte principal.

## Principe

- **Un projet Argo `system`** (`project.yaml`), distinct de `platform` (le socle) et
  des projets applicatifs. Il ne gouverne que les namespaces d'outillage.
- **Une Application Argo par outil**, possédée par homelab-platform. Bootstrap : on
  applique le projet puis l'Application une fois (`kubectl apply -f`), Argo gère la
  suite. Argo **adopte** l'existant sans coupure.
- **Pas de dépendance croisée non voulue** : chaque outil a sa base/son stockage à lui
  (le SSO a son propre `Cluster` CNPG). Les seules dépendances légitimes restent
  apps → SSO (OIDC) et monitoring → tout (scrape en lecture).

## Prochaines étapes

1. **SSO — fait.** `system/sso/` (cf. son README). Image Keycloak : build déplacé
   ici (`Dockerfile` + `build-keycloak.yml`) → publier puis repointer l'image dans
   `20-keycloak.yaml` (séquence dans le README SSO).
2. **Argo CD — fait (partiel).** `system/argocd/` : frontal UI repris en GitOps
   (`argocd.system.crealcs.com`). L'install d'Argo CD reste un bootstrap manuel
   (version épinglée) — le passer en self-managed est une amélioration possible.
3. **Monitoring — fait.** `system/monitoring/` (release Helm CLI, valeurs ici,
   hôte `grafana.system.crealcs.com`). Les dashboards/scrapes spécifiques à une
   appli restent chez elle.
4. **Nettoyage xpms.** Retirer `tools`/`monitoring` des destinations du projet Argo
   de xpms ; retirer `k8s/{argocd,monitoring,sso,gateway}` de rental-platform une
   fois chaque outil repris ici (le `gateway` est déjà remplacé par le socle, ns `kong`).
