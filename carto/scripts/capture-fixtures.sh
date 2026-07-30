#!/usr/bin/env bash
# Capture des réponses réelles du Gateway en fixtures de test. LECTURE SEULE.
# Chemins mesurés à la source (Swagger d'administration livré dans le conteneur,
# packages/WmAPIGateway/resources/apigatewayservices/APIGatewayServiceManagement.json
# et APIGatewayApplication.json) — voir carto/TERRAIN.md, section V3.
#
# Usage : WM_ADMIN_URL=... WM_USER=... WM_PASS=... ./capture-fixtures.sh <destdir>
set -euo pipefail
DEST="${1:?destdir requis}"; mkdir -p "$DEST"
get() { curl -sS -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' "$WM_ADMIN_URL$1"; }

get /apis         > "$DEST/apis.json"
get /applications > "$DEST/applications.json"

echo "capturé dans $DEST — RELIRE ces fichiers et retirer toute donnée sensible"
