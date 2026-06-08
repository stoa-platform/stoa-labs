#!/usr/bin/env bash
# Arrête le socle PoC (conserve les volumes).
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose -f docker-compose.poc.yml down
echo "✓ stack arrêtée (volumes conservés — utiliser teardown.sh pour tout détruire)"
