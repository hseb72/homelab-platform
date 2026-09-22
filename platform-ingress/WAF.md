# WAF ModSecurity — mise en service et dépouillement

Le WAF tourne dans ingress-nginx, activé par
[`values-ingress-nginx.yaml`](values-ingress-nginx.yaml) (drapeaux
`enable-modsecurity` / `enable-owasp-modsecurity-crs` et le `modsecurity-snippet`).
Aucun composant supplémentaire : le contrôleur embarque le moteur, le CRS OWASP
s'active par un drapeau.

**Il est en `DetectionOnly` : il journalise, il ne bloque rien.** C'est
délibéré — cette phase dure une à deux semaines, le temps de dépouiller les faux
positifs avant de passer en blocage.

> Toutes les commandes ci-dessous visent le contrôleur mutualisé dans son
> namespace d'infra `platform-ingress` (deploy
> `platform-ingress-ingress-nginx-controller`). Avant le rapatriement, il vivait
> dans le namespace applicatif `backend` — les vieux runbooks qui pointent là
> sont périmés.

## Vérifier qu'il est actif

```bash
kubectl -n platform-ingress get pods -l app.kubernetes.io/name=ingress-nginx
kubectl -n platform-ingress exec deploy/platform-ingress-ingress-nginx-controller -- \
  grep -iE 'modsecurity|SecRuleEngine' /etc/nginx/nginx.conf | head
```

> ⚠ `modsecurity-snippet` **remplace** le fragment par défaut du contrôleur au
> lieu de s'y ajouter. Vérifier que `SecRuleEngine DetectionOnly` figure bien
> dans la configuration générée : si le fragment n'est pas pris en compte, le
> moteur peut tourner avec le réglage par défaut de l'image — donc
> potentiellement en blocage, ce qu'on ne veut surtout pas à ce stade.

Un test inoffensif qui doit produire une entrée de journal **sans être bloqué**
(réponse normale de l'application, pas un 403) :

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  'https://api.xpms.crealcs.com/health?x=%3Cscript%3Ealert(1)%3C/script%3E'
# attendu : 200 — en DetectionOnly, la requête passe et l'alerte est journalisée
```

## Dépouiller

Les alertes sortent en JSON sur la sortie standard du contrôleur.

```bash
# règles les plus déclenchées, sur les 5000 dernières lignes
kubectl -n platform-ingress logs deploy/platform-ingress-ingress-nginx-controller --tail=5000 \
  | grep -o '"id":"9[0-9]*"' | sort | uniq -c | sort -rn | head -20

# URI concernées pour une règle donnée
kubectl -n platform-ingress logs deploy/platform-ingress-ingress-nginx-controller --tail=5000 \
  | grep '"id":"942100"' | grep -o '"uri":"[^"]*"' | sort | uniq -c | sort -rn
```

La question à se poser pour chaque règle qui remonte : **est-ce du trafic
légitime de la plateforme ?** Si oui, il faut l'écarter avant de passer en
blocage — sinon le passage à `SecRuleEngine On` cassera cette fonction.

## Faux positifs attendus

| Symptôme | Règles | Origine |
|---|---|---|
| Corps JSON volumineux (création de bien, import de tarifs) | 200002, 200003 | limites de corps |
| Téléversement d'images et de documents | limites de taille | `SecRequestBodyLimit` |
| Descriptions et modèles d'email riches en HTML | 941xxx (XSS) | contenu légitime |
| Jetons JWT longs en en-tête | limites d'en-tête | taille d'`Authorization` |

## Chemins à ne jamais bloquer

Un blocage ici casse des fonctions entières :

- `/api/v1/public/tenant/resolve` — **critique**, toute la résolution
  multi-tenant en dépend ; un blocage fait tomber tous les sites tenants ;
- `/api/v1/platform-marketing/*` — pages publiques ;
- `/api/v1/storage/*` — images publiques.

## ⚠ Le fragment ne tolère ni apostrophe ni commentaire

ingress-nginx insère `modsecurity-snippet` dans `nginx.conf` **entouré
d'apostrophes**. La première apostrophe du contenu ferme la chaîne, et nginx
lit la suite comme des directives :

```
nginx: [emerg] unexpected "a" in /tmp/nginx/nginx-cfg… :48
nginx: configuration file test failed
```

Le pod ne devient jamais prêt et le rollout reste bloqué — sans coupure, car
l'ancien pod conserve sa dernière configuration valide. Un commentaire français
anodin (« cause d'abandon ») suffit à déclencher cela.

**Écrire le fragment sans apostrophe, sans commentaire, sans guillemet.** Les
explications vont en commentaires YAML, hors du fragment.

## Écarter une règle

Ajouter au `modsecurity-snippet` de
[`values-ingress-nginx.yaml`](values-ingress-nginx.yaml), avant de passer en
blocage — et sans apostrophe dans le commentaire, cf. ci-dessus :

```
# Exemple : descriptions HTML legitimes sur la mise a jour d un bien
SecRule REQUEST_URI "@beginsWith /api/v1/properties" \
  "id:1000,phase:1,pass,nolog,ctl:ruleRemoveById=941100"
```

Numéroter les règles locales à partir de 1000 pour ne pas heurter le CRS.
Après modification, réappliquer les valeurs (`helm upgrade --install`, cf.
[README](README.md)).

## Passer en blocage

Quand les journaux ne montrent plus que du trafic réellement suspect, dans le
`modsecurity-snippet` :

```
SecRuleEngine On
```

Réappliquer, puis **surveiller les 403** de près pendant quelques heures :

```bash
kubectl -n platform-ingress logs deploy/platform-ingress-ingress-nginx-controller -f \
  | grep ' 403 '
```

Retour arrière immédiat : repasser à `DetectionOnly` et réappliquer.

## Le journal ne doit pas contenir de données personnelles

`SecAuditLogParts` est volontairement réglé à **`ABFHZ`**, sans `E` (corps de
réponse) ni `I`/`C` (corps de requête).

Avec `E`, chaque requête déclenchant une règle écrit la **réponse complète de
l'API** dans les logs — donc les données des clients. Avec `I`, un
`POST /api/v1/auth/login` qui déclencherait une règle écrirait le **mot de passe
en clair**. Ces logs partent ensuite dans la stack de monitoring, où ils sont
conservés : la fuite serait durable et difficile à rattraper.

Le détail nécessaire au dépouillement — règle déclenchée, URI, fragment ayant
provoqué la détection — se trouve dans `messages`, que ce réglage n'affecte pas.

## Ressources

Le CRS charge quelques milliers de règles par worker.
`values-ingress-nginx.yaml` porte le contrôleur à 512 Mi / 1 Gi : un plafond
trop bas provoque un OOM, c'est-à-dire une coupure totale du site — fronts
compris —, pas une simple dégradation du WAF. Surveiller après activation :

```bash
kubectl -n platform-ingress top pod -l app.kubernetes.io/name=ingress-nginx
```
