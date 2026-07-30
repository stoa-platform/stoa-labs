#!/usr/bin/env bash
# Capture des réponses réelles du Gateway en fixtures de test. LECTURE SEULE.
# Chemins mesurés à la source (Swagger d'administration livré dans le conteneur,
# packages/WmAPIGateway/resources/apigatewayservices/APIGatewayServiceManagement.json
# et APIGatewayApplication.json) — voir carto/TERRAIN.md, section V3.
#
# Capture les QUATRE fixtures de la suite, pas seulement l'inventaire :
#   apis.json, applications.json      (API d'administration)
#   aggregation-d90.json              (agrégation du trafic, API Data Store)
#   oldest-event.json                 (profondeur réellement couverte)
#
# Usage :
#   export WM_ADMIN_URL=... WM_USER=... WM_PASS=...
#   export WM_ES_URL=...    WM_ES_INDEX='gateway_default_analytics_transactionalevents*'
#   ./capture-fixtures.sh <destdir>
#
# ⚠ ES_INDEX : étoile COLLÉE au nom du type, jamais de tiret avant
#   (`..._transactionalevents*`). Un tiret ne matche aucun index et produit
#   une capture vide qui a l'air valide — voir carto/TERRAIN.md V3.
set -euo pipefail
DEST="${1:?destdir requis}"; mkdir -p "$DEST"
: "${WM_ADMIN_URL:?WM_ADMIN_URL requis}" "${WM_USER:?WM_USER requis}" "${WM_PASS:?WM_PASS requis}"
: "${WM_ES_URL:?WM_ES_URL requis}" "${WM_ES_INDEX:?WM_ES_INDEX requis}"

# Les identifiants passent par l'entrée standard de curl (`--config -`), jamais
# par `-u` : un argument de ligne de commande est lisible par n'importe qui dans
# la table des processus de la machine pendant toute la durée de l'appel.
get() {
  printf 'user = "%s:%s"\n' "$WM_USER" "$WM_PASS" \
    | curl -sS --config - -H 'Accept: application/json' "$WM_ADMIN_URL$1"
}

es() {
  curl -sS -H 'Content-Type: application/json' \
    "${WM_ES_URL%/}/${WM_ES_INDEX}/_search" -d "$1"
}

get /apis         > "$DEST/apis.json"
get /applications > "$DEST/applications.json"

# Mêmes corps de requête que carto/collect/analytics.py — les garder alignés.
es '{"size":0,
     "query":{"range":{"creationDate":{"gte":"now-90d"}}},
     "aggs":{"api":{"terms":{"field":"apiId","size":5000},
       "aggs":{"consumer":{"terms":{"field":"applicationId","size":5000},
         "aggs":{"last":{"max":{"field":"creationDate"}},
                 "errors":{"filter":{"range":{"responseCode":{"gte":400}}}}}}}}}}' \
  > "$DEST/aggregation-d90.json"

es '{"size":0,"aggs":{"oldest":{"min":{"field":"creationDate"}}}}' \
  > "$DEST/oldest-event.json"

cat <<'FIN'
capturé — RELIRE ces fichiers et retirer toute donnée sensible avant de les
copier sur carto/tests/fixtures/.

En particulier, aggregation-d90.json de la suite de tests n'est PAS une
capture brute : il porte en tête un bloc `_meta` qui distingue ce qui est
mesuré de ce qui est substitué (les identifiants de consommateur, la gateway
de mesure ayant renseigné "Unknown" à 100 % — voir carto/TERRAIN.md V5). Ce
bloc doit être réécrit à la main sur la nouvelle capture, et son contenu
re-vérifié : le remplacer par une capture brute ferait passer pour mesuré ce
qui ne l'est pas.
FIN
