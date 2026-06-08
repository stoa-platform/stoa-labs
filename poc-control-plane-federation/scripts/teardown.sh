#!/usr/bin/env bash
# Destruction contrôlée : conteneurs + volumes + image locale du mock.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose -f docker-compose.poc.yml down -v --remove-orphans
docker image rm stoa-labs/webmethods-mock:dev 2>/dev/null || true
echo "✓ environnement détruit (conteneurs, volumes, image mock)"
