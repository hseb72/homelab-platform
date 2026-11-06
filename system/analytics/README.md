# Mesure d'audience — Matomo (ns `matomo`)

Matomo auto-hébergé, **mutualisé**, sur `stats.system.crealcs.com` : une seule instance, **un site par application**
(ludi-tabulares, xpms…). Géré en GitOps par homelab-platform (Application Argo
`analytics`, projet `system`). Base MariaDB dédiée : Matomo ne fonctionne pas sur
PostgreSQL et le socle n'a pas de MySQL.

```
Navigateur ──443──▶ edge ingress-nginx (ns ingress, TLS, cert-manager)
  matomo.js / matomo.php     └──▶ Service matomo:80 ──▶ Pod matomo ─┬─ apache (Matomo)
                                                                    └─ archiver (core:archive /h)
                                                        └──▶ mariadb-0 (MariaDB 11.4 + mysqld-exporter)
CronJob mariadb-backup (2 h 17) ──▶ MinIO mutualisé, seau matomo-backups (30 j)
monitoring (VictoriaMetrics) ──scrape──▶ mysqld-exporter ; VMRule ──▶ alertmanager ──▶ Slack
```

| Fichier | Rôle |
|---|---|
| `10-mariadb.yaml` | StatefulSet MariaDB (5 Gi), utilisateur `exporter`, mysqld-exporter. |
| `20-matomo.yaml` | Deployment Matomo (volume 5 Gi : code, config, plugins) + conteneur d'archivage horaire. |
| `30-ingress.yaml` | Ingress de l'hôte unique `stats.system.crealcs.com` (suivi et administration). |
| `40-backup.yaml` | Sauvegarde quotidienne (`mariadb-dump` → MinIO, rclone), rétention 30 jours. |
| `50-network.yaml` | NetworkPolicies : MariaDB réservée au ns ; Matomo joignable depuis l'edge seulement. |
| `60-monitoring.yaml` | `VMServiceScrape` (MariaDB) + `VMRule` (Matomo indisponible, base injoignable, sauvegarde en échec). |
| `../analytics-application.yaml` | L'`Application` Argo `analytics` ; pose l'étiquette `platform-patterns.io/minio-client` sur le ns. |

## Prérequis (hors Git)

1. **DNS** : `stats.system.crealcs.com` vers l'IP publique (ou le wildcard
   `*.system.crealcs.com`). La réécriture CoreDNS `crealcs.override`
   couvre déjà `*.crealcs.com` (self-check ACME et archivage interne).
2. **Secrets** dans le ns `matomo` (à sceller selon ta convention). Mots de passe
   en base64 : jamais d'apostrophe (le script d'init les insère en SQL).
   ```bash
   kubectl create namespace matomo 2>/dev/null || true
   kubectl label namespace matomo platform-patterns.io/minio-client=true --overwrite
   kubectl -n matomo create secret generic matomo-db \
     --from-literal=root-password="$(openssl rand -base64 24)" \
     --from-literal=password="$(openssl rand -base64 24)" \
     --from-literal=exporter-password="$(openssl rand -base64 24)"
   ```
3. **Seau de sauvegarde** sur le MinIO mutualisé (comme `postgres-backups`) : un seau
   `matomo-backups` et un utilisateur limité à ce seau, puis :
   ```bash
   kubectl -n matomo create secret generic matomo-backup-s3 \
     --from-literal=access-key='<utilisateur_minio>' \
     --from-literal=secret-key='<mot_de_passe_minio>'
   ```

## Bootstrap (une fois)

```bash
kubectl apply -f system/project.yaml
kubectl apply -f system/analytics-application.yaml
kubectl -n argocd get application analytics -w      # Synced/Healthy
kubectl -n matomo get pods                          # mariadb-0 et matomo-… Running
kubectl -n matomo get certificate                   # matomo-crealcs-tls → READY=True
```

**Base existante** (MariaDB installée avant ce dépôt, volume déjà initialisé) : le
script d'init ne rejoue pas ; créer l'utilisateur de l'exporter à la main :

```bash
kubectl -n matomo exec -it mariadb-0 -c mariadb -- sh -c \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "CREATE USER IF NOT EXISTS '\''exporter'\''@'\''localhost'\'' IDENTIFIED BY '\''$EXPORTER_PASSWORD'\''; GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '\''exporter'\''@'\''localhost'\'';"'
```

## Installation de Matomo (assistant web, une fois)

Ouvrir `https://stats.system.crealcs.com` :

1. **Base de données** : préremplie (hôte `mariadb.matomo.svc.cluster.local`, base et
   utilisateur `matomo`). Garder le préfixe `matomo_`.
2. **Super-utilisateur** : compte de secours (mot de passe fort, gardé hors cluster) —
   la connexion courante passe ensuite par le SSO.
3. **Premier site** : celui de la première application (voir « Ajouter une
   application »).

Puis, réglages derrière l'edge (en `www-data`, dans le conteneur `matomo`) :

```bash
kubectl -n matomo exec deploy/matomo -c matomo -- su -s /bin/sh www-data -c '
  cd /var/www/html &&
  ./console config:set "General.trusted_hosts[]=\"stats.system.crealcs.com\"" &&
  ./console config:set "General.assume_secure_protocol=1" &&
  ./console config:set "General.force_ssl=1" &&
  ./console config:set "General.proxy_client_headers[]=\"HTTP_X_FORWARDED_FOR\"" &&
  ./console config:set "General.proxy_host_headers[]=\"HTTP_X_FORWARDED_HOST\"" &&
  ./console config:set "General.enable_browser_archiving_triggering=0"'
```

(`enable_browser_archiving_triggering=0` : l'archivage est fait par le conteneur
`archiver`, pas pendant la consultation des rapports.)

## Exemption de consentement (CNIL) — par site

Pour qu'une application puisse mesurer son audience **sans bandeau** (ex. DEC-080
de ludi-tabulares), dans Matomo › Administration :

- **Confidentialité › Anonymiser les données** : masquer **2 octets** de l'IP, et
  utiliser l'IP anonymisée pour la géolocalisation ;
- **Confidentialité › Supprimer les anciennes données brutes** : au plus **25 mois**
  (recommandation CNIL ; 13 mois si l'on veut être prudent) ;
- **Ne pas activer** User ID, suivi multi-domaines ou inter-appareils, import d'autres
  données : ils font perdre l'exemption.

Côté application : suivi sans cookie (`disableCookies`), pas de mesure des espaces
connectés, lien d'opposition — c'est l'application qui le porte.

## Connexion par le SSO (Keycloak)

1. Dans Keycloak (realm de la plateforme) : client OIDC `matomo`, confidentiel,
   URL de retour `https://stats.system.crealcs.com/index.php?module=LoginOIDC&action=callback&provider=oidc`.
2. Dans Matomo › Administration › Marketplace : installer le plugin **LoginOIDC**
   (gratuit), puis Administration › Système › Paramètres généraux › LoginOIDC :
   - Authorize URL : `https://sso.crealcs.com/realms/<realm>/protocol/openid-connect/auth`
   - Token URL : `https://sso.crealcs.com/realms/<realm>/protocol/openid-connect/token`
   - Userinfo URL : `https://sso.crealcs.com/realms/<realm>/protocol/openid-connect/userinfo`
   - Client ID / secret : ceux du client `matomo` ; attribut d'identifiant : `preferred_username`.
3. Le plugin est stocké sur le volume `matomo-html` : il survit aux redémarrages et aux
   montées de version de l'image.

## Ajouter une application

1. Matomo › Administration › Sites › Ajouter : nom, URL publique, fuseau
   Europe/Paris ; appliquer les réglages d'exemption ci-dessus. Relever
   l'**identifiant du site**.
2. Chez l'application, renseigner l'adresse `https://stats.system.crealcs.com` et
   l'identifiant (ludi-tabulares : Gestion du site › Boutique & audience).
3. Vérifier : Matomo › Visiteurs › Journal des visites (en temps réel) ; les rapports
   agrégés suivent au prochain archivage (dans l'heure).

## Vérifier

```bash
curl -sI https://stats.system.crealcs.com/matomo.js | head -1                 # 200
kubectl -n matomo logs deploy/matomo -c archiver --tail=5               # « archivage terminé »
kubectl -n matomo get cronjob,job                                       # mariadb-backup
kubectl -n matomo create job --from=cronjob/mariadb-backup backup-essai # sauvegarde à la demande
```

## Restaurer

```bash
# 1. Suspendre la synchro auto (sinon Argo relance Matomo pendant la restauration)
kubectl -n argocd patch application analytics --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n matomo scale deploy/matomo --replicas=0
# 2. Récupérer le fichier (mc, rclone ou console MinIO) puis l'injecter
gunzip -c matomo-AAAA-MM-JJ.sql.gz | kubectl -n matomo exec -i mariadb-0 -c mariadb -- \
  sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" matomo'
# 3. Relancer et rendre la main à Argo
kubectl -n matomo scale deploy/matomo --replicas=1
kubectl -n argocd patch application analytics --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

## Points durs

- **`stats.system.crealcs.com` est inscrit chez chaque application** (et dans les pages déjà
  en cache des navigateurs) : ne pas le renommer.
- **WAF** : les appels `matomo.php` portent beaucoup de paramètres encodés ; ils sont
  listés dans les faux positifs attendus de [`edge/WAF.md`](../../edge/WAF.md), à
  écarter avant de passer le WAF en blocage.
- **Montée de version Matomo** : Renovate met à jour les deux conteneurs ensemble.
  Après le déploiement, Matomo peut demander une mise à jour de base
  (`./console core:update --yes` en `www-data`).
- **Tableau Grafana** : importer le tableau communautaire « MySQL Exporter
  Quickstart » (ID 14057) sur la datasource VictoriaMetrics.
