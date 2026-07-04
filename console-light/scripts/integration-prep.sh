#!/usr/bin/env bash
# Console Light — prépa d'intégration autonome (un seul lancement, tout en interne).
# Écrit sa progression dans var/prep.log et son verdict dans var/prep.status.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
POC="$(cd "$HERE/../poc-control-plane-federation" && pwd)"
LOG="$HERE/var/prep.log"
STATUS="$HERE/var/prep.status"
mkdir -p "$HERE/var"
: > "$LOG"
echo "RUNNING" > "$STATUS"

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }
fail() { log "ÉCHEC: $*"; echo "FAILED: $*" > "$STATUS"; exit 1; }

log "=== Environnement ==="
log "node: $(node --version 2>&1)"
log "npm:  $(npm --version 2>&1)"
log "go:   $(go version 2>&1)"
log "docker: $(docker info --format 'v{{.ServerVersion}} NCPU={{.NCPU}} RAM={{.MemTotal}}' 2>&1 | head -1)"
log "RAM machine: $(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GB", $1/1073741824}')"
log "containers existants:"
docker ps -a --format '  {{.Names}} | {{.Status}}' >> "$LOG" 2>&1

log "=== Boot identité (dex + keycloak, force-recreate pour réimport realm) ==="
cd "$POC"
if ! docker compose -f docker-compose.poc.yml up -d --force-recreate dex keycloak >> "$LOG" 2>&1; then
  log "compose a échoué — tentative avec images par défaut (variables .env manquantes ?)"
  DEX_IMAGE="${DEX_IMAGE:-ghcr.io/dexidp/dex:v2.41.1}" \
  KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.0}" \
    docker compose -f docker-compose.poc.yml up -d --force-recreate dex keycloak >> "$LOG" 2>&1 \
    || fail "docker compose dex+keycloak"
fi

log "Attente Keycloak (jusqu'à 3 min)…"
KC_OK=0
for i in $(seq 1 90); do
  if curl -sf http://localhost:8480/realms/stoa-lab/.well-known/openid-configuration >/dev/null 2>&1; then KC_OK=1; break; fi
  sleep 2
done
[ "$KC_OK" = 1 ] || fail "Keycloak ne répond pas sur :8480"
log "Keycloak prêt."

log "=== Vérification import realm (client console-light + rôles) ==="
TOKEN=$(curl -sf -X POST http://localhost:8480/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])' 2>>"$LOG") || fail "token admin KC"
CL=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  'http://localhost:8480/admin/realms/stoa-lab/clients?clientId=console-light' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')
log "client console-light importé: ${CL} (attendu 1)"
ROLES=$(curl -sf -H "Authorization: Bearer $TOKEN" http://localhost:8480/admin/realms/stoa-lab/roles \
  | python3 -c 'import sys,json;print(",".join(sorted(r["name"] for r in json.load(sys.stdin) if r["name"] in ("cpi-admin","tenant-admin","devops","viewer"))))')
log "rôles importés: ${ROLES}"
[ "$CL" = "1" ] || fail "client console-light absent du realm"

log "=== Dex ==="
curl -sf http://localhost:5556/dex/healthz >/dev/null 2>&1 && log "dex OK" || log "dex KO (non bloquant, vérifier)"

log "=== Seed repo de gouvernance ==="
bash "$HERE/scripts/seed-governance-repo.sh" >> "$LOG" 2>&1 || fail "seed-governance-repo.sh"
git -C "$HERE/var/governance-repo" log --format='%h %G? %s' | head -3 >> "$LOG" 2>&1

log "=== Gateways légères (pour l'écran cibles — non bloquant) ==="
docker compose -f docker-compose.poc.yml up -d etcd apisix webmethods-mock >> "$LOG" 2>&1 \
  && log "etcd+apisix+webmethods-mock demandés" || log "gateways légères non démarrées (non bloquant)"

log "=== TERMINÉ ==="
echo "OK" > "$STATUS"
echo "PREP_DONE"
