#!/usr/bin/env bash
# Démarre le socle PoC (Phase 1). Profil light par défaut.
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f docker-compose.poc.yml"

if [[ ! -f .env ]]; then
  echo "→ .env absent, copie depuis .env.example"
  cp .env.example .env
fi

echo "→ build du mock webMethods + pull des images"
$COMPOSE build webmethods-mock
$COMPOSE up -d

echo "→ attente des healthchecks (peut prendre quelques minutes : WSO2 démarre lentement)…"
deadline=$(( $(date +%s) + 420 ))
while :; do
  unhealthy=$($COMPOSE ps --format '{{.Name}} {{.Health}}' | awk '$2!="" && $2!="healthy"{print $1}')
  if [[ -z "$unhealthy" ]]; then
    echo "✓ tous les services healthy"
    break
  fi
  if (( $(date +%s) > deadline )); then
    echo "✗ timeout — services non healthy :"; echo "$unhealthy"
    $COMPOSE ps
    exit 1
  fi
  sleep 10
done

$COMPOSE ps
cat <<EOF

PoC up. Accès :
  WSO2 Publisher/Devportal : https://localhost:${PORT_WSO2_CONSOLE:-9443}/publisher  (admin/admin)
  APISIX data-plane        : http://localhost:${PORT_APISIX:-9080}
  webMethods mock          : http://localhost:${PORT_WEBMETHODS:-8090}/rest/apigateway/is/health
  Keycloak                 : http://localhost:8480  (admin/admin)
  Dex (mock Oracle)        : http://localhost:${PORT_DEX:-5556}/dex/.well-known/openid-configuration
  Grafana (otel-lgtm)      : http://localhost:${PORT_GRAFANA:-3000}
  Microcks                 : http://localhost:${PORT_MICROCKS:-8585}

Prochain : ./scripts/smoke-test.sh
EOF
