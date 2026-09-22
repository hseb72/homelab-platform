# Gabarits — application consommatrice

Le squelette minimal d'une application qui consomme le socle. À **copier**,
remplacer `mon-appli` partout, et ne garder que les ressources utiles. Le
protocole complet — ce qui se passe côté socle, et pourquoi — est dans
[`CONSUMING.md`](../../CONSUMING.md).

| Fichier | Rôle |
|---|---|
| [`namespace.yaml`](namespace.yaml) | Le namespace et ses **étiquettes `*-client`** : c'est là que l'application déclare quels services elle joint. |
| [`create-secrets.sh`](create-secrets.sh) | Dépose côté application les identifiants fournis par l'admin du socle. À sceller (kubeseal). |
| [`deployment.example.yaml`](deployment.example.yaml) | Un déploiement montrant le **câblage** des trois ressources par variables d'environnement. |
| [`networkpolicy.yaml`](networkpolicy.yaml) | Refus par défaut + sorties vers les services utilisés (+ entrée depuis la gateway si API exposée). |
| [`api-ingress.yaml`](api-ingress.yaml) | Exposition d'une API via Kong — les deux ressources (hôte centralisé + routes de classe `kong`). |

## Ordre

1. `namespace.yaml` — poser le namespace **avec les bonnes étiquettes**.
2. Faire provisionner les ressources côté socle (l'admin déclare le locataire et
   la clé — cf. le README de chaque service) et récupérer les identifiants.
3. `create-secrets.sh` — déposer et sceller les secrets d'accès.
4. `networkpolicy.yaml` puis `deployment.example.yaml` — déployer l'application.
5. `api-ingress.yaml` (+ l'entrée d'hôte dans le socle) — si l'application
   expose une API.

Rien de tout cela ne modifie le socle, à une exception près, inhérente à la
gateway : l'hôte d'API s'ajoute à `gateway/10-ingress-api-hosts.yaml` (un Ingress
ne référence qu'un Service de son namespace, et `kong-proxy` vit dans `gateway`).
