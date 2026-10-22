# Keycloak pré-augmenté (« optimized »).
#
# Sans cette image, le conteneur démarre avec `--optimized=false` et rejoue un
# `kc.sh build` à CHAQUE démarrage : ~10 min sur ce matériel, pendant lesquelles
# le SSO est indisponible. Un changement de KC_FEATURES rallonge encore, au point
# d'avoir déjà dépassé les sondes et bouclé en CrashLoop.
#
# Ici l'augmentation est faite une fois, à la construction de l'image. Le
# conteneur démarre alors en quelques secondes avec `start --optimized`.
#
# ⚠ Les options ci-dessous sont des options de BUILD : elles sont gravées dans
# l'image. Le Deployment (system/sso/20-keycloak.yaml) doit déclarer exactement
# les mêmes valeurs, sinon Keycloak refuse de démarrer en `--optimized` (« build
# time option differs »). Les options de RUNTIME (KC_DB_URL, identifiants,
# KC_HOSTNAME, KC_PROXY_HEADERS, compte bootstrap) restent des variables
# d'environnement du Deployment.

FROM quay.io/keycloak/keycloak:26.0 AS builder

ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_HTTP_ENABLED=true

# `organization` (au SINGULIER) : SSO par tenant via Keycloak Organizations.
# Le pluriel fait échouer le démarrage (« unrecognized feature »).
RUN /opt/keycloak/bin/kc.sh build --features=organization

FROM quay.io/keycloak/keycloak:26.0

COPY --from=builder /opt/keycloak/ /opt/keycloak/

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
