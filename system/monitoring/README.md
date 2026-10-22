# Monitoring — VictoriaMetrics + Grafana (ns `monitoring`)

Stack d'observabilité légère (~300-500 Mo) : opérateur VictoriaMetrics + vmagent
+ vmsingle + Grafana + exporters, en **release Helm CLI** `monitoring`. Les
**valeurs sont désormais ici** (plus dans l'install xpms). Grafana sur
**`grafana.system.crealcs.com`** (ex-`grafana.xpms`), via l'edge du socle.

```
Apps (ServiceMonitor, chez elles) ──▶ opérateur VM ──▶ VMServiceScrape
node-exporter, kube-state-metrics ──▶ vmagent ──▶ vmsingle ──▶ Grafana
                                                   vmalert ──▶ alertmanager ──▶ Slack
```

> **Méthode : Helm CLI**, pas Argo. Le stack est déjà une release live à CRD
> lourdes ; l'adopter dans Argo est risqué. L'isolation visée (valeurs possédées
> ici, hôte `.system`, ns dédié) est atteinte sans ça. Conversion en Application
> Argo possible plus tard, si on veut uniformiser avec le SSO.

## Prérequis (hors Git, ns `monitoring`)

```bash
kubectl create namespace monitoring 2>/dev/null || true
# 1. admin Grafana
kubectl -n monitoring get secret grafana-admin || \
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
# 2. webhook Slack pour alertmanager (clé `url`)
kubectl -n monitoring get secret alertmanager-slack || \
kubectl -n monitoring create secret generic alertmanager-slack \
  --from-literal=url='https://hooks.slack.com/services/XXX/YYY/ZZZ'
```

- **DNS** : `grafana.system.crealcs.com` doit résoudre vers l'IP publique, + une
  entrée `template` CoreDNS (`coredns-custom`, kube-system) pour le hairpin
  (sinon le self-check ACME échoue, cert `grafana-tls` en `pending`).
- `ClusterIssuer letsencrypt-http01` en place (socle).

## Déploiement / mise à jour

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/ && helm repo update

# Reprise de la release existante avec LES VALEURS D'ICI (change juste leur
# source + l'hôte Grafana → system). Épingle la version actuellement installée :
helm -n monitoring list        # relève la CHART version de `monitoring`
helm upgrade --install monitoring vm/victoria-metrics-k8s-stack \
  -n monitoring --create-namespace \
  --version <CHART_VERSION_ÉPINGLÉE> \
  -f system/monitoring/values.yaml

kubectl -n monitoring get pods
kubectl get certificate -n monitoring grafana-tls      # READY=True après ACME
```

> ⚠ **Épingler `--version`** : l'install d'origine ne le faisait pas. Relève la
> version en place (`helm -n monitoring list`) et fige-la ici pour des mises à
> jour reproductibles.

## Accès

- Grafana : `https://grafana.system.crealcs.com` (login = secret `grafana-admin`).
- Datasource VictoriaMetrics branchée automatiquement ; dashboards k8s inclus.

## Notes

- **Dashboards/scrapes spécifiques à une appli** (ex. `rental-api.json`, scrape
  GHA runner) **restent chez l'appli concernée** — ils émettent leurs
  `ServiceMonitor`/`VMRule` chez eux, convertis/scrapés sans config ici.
- **Canal Slack `#xpms`** historique dans `values.yaml` : à renommer en canal de
  plateforme quand tu veux (l'URL vient du secret `alertmanager-slack`).
- **Durcir Grafana** : `nginx.ingress.kubernetes.io/whitelist-source-range` sur
  l'ingress si tu veux le restreindre par IP.
