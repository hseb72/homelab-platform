# Contrôleur ingress mutualisé — ingress-nginx

Le contrôleur ingress-nginx sert **toutes** les applications du cluster (rental,
ESN, futures apps) : c'est l'entrée unique `:80/:443`, avec la terminaison TLS
(cert-manager) et le WAF (ModSecurity + CRS OWASP). Une brique d'infrastructure,
au même titre que Kong, cert-manager, CNPG et VictoriaMetrics.

## Palier d'installation — CLI-Helm, hors Argo

Comme les autres **moteurs d'infra**, ce contrôleur n'est pas piloté par Argo CD.
Il est installé une fois, en ligne de commande, à partir du **chart amont** et
des **valeurs versionnées ici**. Argo gère les applications ; ce palier-ci porte
ce dont Argo lui-même dépend, et se tient volontairement en dessous.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install platform-ingress ingress-nginx/ingress-nginx \
  -n platform-ingress --create-namespace --version 4.12.1 \
  -f platform-ingress/values-ingress-nginx.yaml

kubectl -n platform-ingress rollout status deploy/platform-ingress-ingress-nginx-controller
```

> Version épinglée à `4.12.1` — la même que l'ancien sous-chart, pour ne rien
> changer d'autre au passage. La relever est un geste délibéré, pas un effet de
> bord d'un `helm repo update`.

## Invariants — à ne JAMAIS casser (sinon toutes les apps tombent)

1. **Même IngressClass `nginx`** (`ingressClassResource.name` +
   `controllerValue` inchangés) → aucun objet Ingress d'aucune app à modifier,
   aucun changement DNS.
2. **Même Service LoadBalancer** → k3s ServiceLB rebinde `:80/:443` sur l'IP du
   nœud (unique IP publique via DNAT). Un seul contrôleur lié à la fois.
3. **Un seul contrôleur sur `:80/:443`** simultanément (sinon conflit de port :
   le 2ᵉ `svclb` reste `Pending`).

Le WAF (ModSecurity + CRS) est **en observation** (`SecRuleEngine DetectionOnly`) :
il journalise sans bloquer. Passer à `On` après dépouillement des journaux — même
principe que pour les quotas de Kong, observer d'abord, contraindre ensuite. Mise
en service, dépouillement et passage en blocage : voir [`WAF.md`](WAF.md).

> ⚠ Le fragment `modsecurity-snippet` ne tolère **ni commentaire ni apostrophe** :
> ingress-nginx l'insère dans `nginx.conf` entouré d'apostrophes ; la première
> apostrophe fermerait la chaîne et nginx lirait la suite comme des directives
> (pod jamais prêt, `unexpected "a"`). Les explications restent en commentaires
> YAML.

## Contrainte structurante — pas de bascule progressive

Le cluster n'a **qu'une seule IP publique** : impossible de faire tourner deux
contrôleurs sur `:80/:443` en parallèle. Tout changement de contrôleur est un
**cutover big-bang**, quelques secondes d'indisponibilité le temps que le
nouveau pod reprenne les ports sur la même IP nœud.

## Historique de reprise

Ce contrôleur était, à tort, un **sous-chart de l'umbrella rental**, dans le
namespace applicatif `backend` — une brique transverse coincée dans le backend
d'une seule application. Le chantier `platform-ingress` l'a sorti en release Helm
autonome, dans un namespace d'infra neutre, puis l'a rapatrié ici. La bascule a
été coordonnée avec ESN (les deux apps partagent le contrôleur) :

1. Les NetworkPolicies des deux apps ont d'abord toléré `backend` **et**
   `platform-ingress` comme source (additif, sans effet tant que le contrôleur
   ne bougeait pas).
2. **Cutover** : Argo prune l'ancien sous-chart de `backend` (Deployment,
   Service, RBAC, ConfigMap et l'IngressClass `nginx` cluster-scoped) — ce qui
   évite l'IngressClass en double — puis `helm upgrade --install` du nouveau
   contrôleur dans `platform-ingress` (même classe, même LoadBalancer → même IP).
3. Vérifications conjointes, puis resserrage des NP sur `platform-ingress` seul.

## Rollback

Tant que les NetworkPolicies des apps tolèrent encore `backend`, revenir en
arrière restaure l'état antérieur :

```bash
helm uninstall platform-ingress -n platform-ingress      # libère :80/443
# rétablir le contrôleur dans son emplacement d'origine, puis re-synchroniser
```

## Vérifications

```bash
kubectl -n platform-ingress get pods           # contrôleur Ready
kubectl get ingressclass                       # `nginx`, une seule
kubectl get validatingwebhookconfigurations | grep -i ingress   # AUCUNE (webhook désactivé)
kubectl -n platform-ingress get svc            # LoadBalancer, EXTERNAL-IP = IP du nœud
```

> Depuis la VM, le hairpin fausse un `curl` par nom : forcer
> `--resolve <hôte>:443:<IP nœud>`, ou tester depuis l'extérieur — seul test qui
> reflète ce que voient les utilisateurs.
