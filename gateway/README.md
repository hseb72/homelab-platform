# API gateway — Kong OSS, mutualisé

Kong n'appartient à aucune application. C'est un composant d'**infrastructure**,
au même titre que ingress-nginx, cert-manager, CloudNativePG et VictoriaMetrics :
installé une fois, dans son propre namespace `gateway`, avec sa propre release
Helm. Toute application déployée sur le serveur expose son API à travers lui.

```
Internet
   │
   ▼
ingress-nginx  ── TLS (cert-manager) + WAF (ModSecurity/CRS) ── entrée unique 80/443
   │
   ├──▶ fronts, portails, consoles ................ direct, Kong n'apporterait rien
   │
   └──▶ kong-proxy (namespace gateway) ............ TOUS les hôtes d'API
             │   quotas, rate limiting, clés d'API, rejet précoce des JWT, observabilité
             ├──▶ API rental          (namespace backend)
             ├──▶ API application 2    (son namespace)
             └──▶ API application N    (son namespace)
```

**Pourquoi nginx reste au bord** : il porte ModSecurity et le CRS OWASP, dont
Kong OSS n'a pas d'équivalent. Deux couches, deux familles de menaces —
injections et scanners pour l'une, abus d'usage et quotas pour l'autre.

## Palier d'installation — CLI-Helm, hors Argo

Comme ingress-nginx et les autres moteurs d'infra, Kong n'est pas piloté par
Argo CD. Chart amont, valeurs versionnées ici, install en ligne de commande :

```bash
kubectl apply -f gateway/00-namespace.yaml

helm repo add kong https://charts.konghq.com
helm repo update
helm upgrade --install kong kong/kong -n gateway \
  -f gateway/values-kong.yaml

kubectl -n gateway get pods
kubectl get ingressclass kong
```

> Confronter les clés à `helm show values kong/kong --version <x>` avant la
> première installation : le nom de certaines options a bougé entre versions
> majeures du chart. `values-kong.yaml` vise la série **2.4x** ; l'image Kong
> est épinglée à **3.9** (un tag mobile ferait varier le comportement de la
> gateway au gré des redémarrages de pod).

## Mode : Ingress Controller, sans base de données

Kong tourne **sans base** (`env.database: "off"`) : le contrôleur d'Ingress
pousse la configuration en mémoire depuis les ressources Kubernetes — rien à
sauvegarder, rien à opérer. La configuration vient des **ressources par
namespace**, pas d'un fichier central : chaque application déclare ses routes
chez elle, et la gateway passe à l'échelle linéairement plutôt que de faire du
fichier partagé un point de contention.

## Ajouter une application — deux ressources

**1. Amener l'hôte jusqu'à Kong** — un `Ingress` de classe `nginx`, **dans le
namespace `gateway`**, ajouté à [`10-ingress-api-hosts.yaml`](10-ingress-api-hosts.yaml).
Un Ingress ne peut référencer qu'un Service de son propre namespace, et
`kong-proxy` vit ici : c'est donc la **seule ressource centralisée** du
dispositif, et elle ne contient que des noms d'hôtes. C'est aussi elle qui porte
le certificat (annotation cert-manager).

**2. Décrire les routes** — un `Ingress` de classe `kong`, **dans le namespace de
l'application**, pointant vers son Service. Kong route directement vers les pods,
sans contrainte de namespace. Cette ressource **vit dans le dépôt de
l'application**, pas ici : c'est là que l'application déclare son besoin.
Le manifeste `rental-api` (namespace `backend`, dans le dépôt rental) sert de
gabarit — hôtes de validation puis de production, plus l'hôte interne
`kong-proxy.gateway.svc.cluster.local` pour les appels de rendu serveur.

## L'en-tête `Host` — contrainte non négociable

La résolution de tenant repose sur le `Host` (`/public/tenant/resolve?domain=…`).
Une réécriture casse le routage de **tous** les sites tenants (404, ou mauvais
tenant servi). D'où, dans les manifestes :

- côté Kong : `preserve_host: true` (annotation `konghq.com/preserve-host`) ;
- côté nginx : aucune annotation `upstream-vhost` ni réécriture de `Host`.

## Appels internes — ils passent aussi par Kong

Les fronts Next.js rendent côté serveur : ils appellent l'API depuis l'intérieur
du cluster. Laissés en direct sur le Service de l'API, ils contourneraient la
gateway et interdiraient toute NetworkPolicy stricte. Ils pointent donc vers Kong
dans le cluster :

```yaml
API_URL: http://kong-proxy.gateway.svc.cluster.local
```

Le trafic ne sort pas de la machine, ne repasse ni par TLS ni par le WAF, et
traverse la gateway comme le reste.

> ⚠ **Rate limiting et rendu serveur.** Ces appels viennent d'un petit nombre
> d'IP de pods et sont nombreux par nature : un quota par IP se déclencherait
> contre toi. Les routes internes doivent rester **exemptées** — séparer les
> hôtes internes dans un Ingress sans annotation de plugin. Ne pas activer de
> plugin de blocage (rate limiting, clés d'API) avant d'avoir observé le trafic
> réel : le `KongPlugin` de rate limiting existe en gabarit mais `disabled: true`.

## Vérifications

```bash
# Kong répond et préserve le Host (depuis la VM, forcer --resolve) :
curl -ksI --resolve <hôte-api>:443:<IP> https://<hôte-api>/health
curl -ks  --resolve <hôte-api>:443:<IP> https://<hôte-api>/api/v1/auth/sso/config

# l'en-tête Host arrive intact jusqu'à l'API
kubectl -n backend logs -l app.kubernetes.io/name=api --tail=20 | grep -i host
```

Le second `curl` est le plus parlant : il traverse nginx, Kong, l'API et
PostgreSQL, et renvoie une configuration lue en base.

> ⚠ **D'où l'on teste change le résultat.** Le shell de la VM n'est pas un pod :
> il résout les noms publics vers l'IP publique et le paquet part dans le hairpin
> (les règles DNAT sont en `-i vmbr0`). Un `curl` par nom depuis la VM échoue en
> « Couldn't connect » alors que le service va très bien.
>
> - depuis la VM : `curl -k --resolve <hôte>:443:<IP nœud> https://<hôte>/…`
> - depuis un pod : le nom suffit (CoreDNS)
> - depuis l'extérieur : le seul test qui dit ce que voient les utilisateurs.
