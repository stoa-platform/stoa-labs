#!/usr/bin/env bash
# setup-vault.sh — idempotent provisioning des secrets du PoC dans Vault (ADR-074).
# Concrétise le gap (d) d'ADR-072 : les secrets ne vivent plus en placeholders
# targets.yaml / env / credentials Jenkins, mais dans Vault, LUS à l'exécution
# (labctl / onboarding-api / CI) et rotables sans rebuild.
#
# Vault dev-mode : KV v2 déjà monté sous secret/, unsealed, root token jetable.
# Écriture KV v2 = upsert (POST .../data/<path>) → re-run = converge.
#
# Les VALEURS ci-dessous sont PoC-JETABLES (identiques aux placeholders déjà en
# Git) — surchargeables par env. En prod : valeurs émises par Vault, rotées,
# jamais dans un script. Lancer : bash scripts/setup-vault.sh
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-stoa-root-token}"
MOUNT="${VAULT_KV_MOUNT:-secret}"
PREFIX="${VAULT_PREFIX:-stoa}"
CURL=(/usr/bin/curl -s -H "X-Vault-Token: $VAULT_TOKEN")

# put <subpath> <json-data-object>
put() {
  local sub="$1" data="$2"
  "${CURL[@]}" -X POST "$VAULT_ADDR/v1/$MOUNT/data/$PREFIX/$sub" \
    -H 'Content-Type: application/json' -d "{\"data\":$data}" -o /dev/null -w "  $PREFIX/$sub -> HTTP %{http_code}\n"
}

# Secret values (PoC-disposable; override via env to inject real ones out-of-band)
WSO2_USER="${WSO2_USER:-admin}";            WSO2_PASS="${WSO2_PASS:-admin}"
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-poc-apisix-admin-key}"
WM_USER="${WM_USER:-Administrator}";        WM_PASS="${WM_PASS:-manage}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}";    KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
KC_CONSUMER_SECRET="${KC_CONSUMER_SECRET:-}"
CI_APPLIER_SECRET="${CI_APPLIER_SECRET:-ci-applier-secret}"
OS_ADMIN_PASS="${OS_ADMIN_PASS:-Stoa!Passw0rd2026}"

echo "Vault $VAULT_ADDR — provisioning secret/$PREFIX/* (KV v2)"
put gateways/wso2       "{\"username\":\"$WSO2_USER\",\"password\":\"$WSO2_PASS\"}"
put gateways/apisix     "{\"adminKey\":\"$APISIX_ADMIN_KEY\"}"
put gateways/webmethods "{\"username\":\"$WM_USER\",\"password\":\"$WM_PASS\"}"
put keycloak            "{\"adminUsername\":\"$KC_ADMIN_USER\",\"adminPassword\":\"$KC_ADMIN_PASS\",\"consumerClientSecret\":\"$KC_CONSUMER_SECRET\"}"
put ci                  "{\"ciApplierSecret\":\"$CI_APPLIER_SECRET\"}"
put opensearch          "{\"adminPassword\":\"$OS_ADMIN_PASS\"}"

echo "done. Vérif (re-lecture d'un secret) :"
"${CURL[@]}" "$VAULT_ADDR/v1/$MOUNT/data/$PREFIX/gateways/apisix" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  apisix.adminKey =", d["data"]["data"].get("adminKey"))' 2>/dev/null \
  || echo "  (lecture KO — Vault joignable ?)"
