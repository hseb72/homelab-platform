# Bord du cluster (edge)

Le **moteur** d'edge — le frontal ingress-nginx (classe `nginx`, Service
LoadBalancer sur l'IP du nœud, WAF ModSecurity) et la gateway Kong DB-less — ne
vit plus ici : il est instancié par
[`charts/platform`](https://github.com/hseb72/platform-patterns) via l'app-of-apps
[`platform/`](../platform/) (ns `ingress` et `kong`). Ce dossier ne porte que les
**deux responsabilités d'edge qui restent à CE dépôt**.

## 1. `api-hosts.yaml` — les hôtes d'API centralisés

Un Ingress de classe `nginx`, **dans le namespace `kong`**, par hôte
`api.<app>.crealcs.com` → `kong-proxy:80`. C'est l'unique ressource d'edge
centralisée du dispositif, et la seule « exception assumée » au principe « chaque
application déclare son besoin chez elle » :

> Un Ingress ne peut référencer qu'un Service de **son propre** namespace, et
> `kong-proxy` vit dans `kong` (socle `charts/platform`). L'hôte doit donc être
> déclaré dans `kong`, que le socle possède — une application n'écrit pas chez
> lui. Chaque application pose, elle, ses **routes Kong** (classe `kong`) dans son
> propre namespace ; seul l'hôte vit ici.

Ce fichier grandit d'une entrée (un bloc `Ingress`) par application. Il est
**appliqué à la main, hors Argo** (comme l'était l'edge CLI-Helm qu'il
remplace) :

```bash
kubectl apply -f edge/api-hosts.yaml
```

> ⚠ **Aucune annotation touchant l'en-tête `Host`** (pas d'`upstream-vhost`, pas
> de réécriture) : la résolution de tenant en dépend, une normalisation ferait
> répondre 404 à tous les sites. La taille de corps (`proxy-body-size`) est
> réglée par application.

## 2. `WAF.md` — le pare-feu applicatif

Le WAF (ModSecurity + CRS OWASP) tourne sur le frontal, **en observation**
(`SecRuleEngine DetectionOnly`). Sa configuration vit désormais dans
[`platform/instance.yaml`](../platform/instance.yaml) (bloc `ingress.values…
config`), mais son **runbook** — comment lire les alertes, bâtir les exclusions,
passer de `DetectionOnly` à `On` — reste ici : [`WAF.md`](WAF.md). C'est l'entrée
de l'agent de dépouillement du WAF (cf. [`AGENTS.md`](../AGENTS.md)).
