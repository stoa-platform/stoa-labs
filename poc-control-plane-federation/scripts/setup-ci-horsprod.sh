#!/usr/bin/env bash
# setup-ci-horsprod.sh — idempotent Keycloak setup for the NON-PROD deploy
# service account (ADR-075). Clone exact du pattern setup-ci-applier.sh : le
# pipeline hors-prod ne porte NI mot de passe utilisateur NI credential admin
# des mocks — il détient UN client confidentiel (client_credentials only) dont
# le token Bearer est présenté aux proxies admin wm-admin-{env} du wM réel.
#
# Provisioned in realm stoa-lab:
#   1. confidential client `ci-horsprod` (serviceAccounts ON, client_credentials
#      ONLY — directAccessGrants OFF, standardFlow OFF) avec un audience mapper
#      -> aud=wm-admin (custom audience ; NB : l'audience est fail-OPEN sur le
#      trial 10.15 — la barrière OPPOSABLE est le SCOPE, cf. ADR-075)
#   2. client scopes deploy:dev / deploy:rec / deploy:int créés au realm et
#      attachés en DEFAULT scopes du client — chaque proxy wm-admin-{env}
#      exige SON deploy:{env}. PAS de deploy:prod : ce client ne peut JAMAIS
#      franchir la barrière prod, même volé (le scope manque, 401/403).
#
#   Mint the CI token (client_credentials — no user, no password):
#     TOKEN=$(scripts/setup-ci-horsprod.sh --mint)
#   In prod: secret émis depuis Vault (ciHorsprodSecret), roté.
set -euo pipefail
KC_BASE="${KC_BASE:-http://localhost:8480}"
REALM="${REALM:-stoa-lab}"
ADMIN_USER="${ADMIN_USER:-admin}"; ADMIN_PASS="${ADMIN_PASS:-admin}"
CLIENT="${CI_CLIENT:-ci-horsprod}"; SECRET="${CI_SECRET:-ci-horsprod-secret}"
AUD="${AUDIENCE:-wm-admin}"
SCOPES=(deploy:dev deploy:rec deploy:int)   # PAS deploy:prod (barrière)
CURL=(/usr/bin/curl -s); JSON=(-H 'Content-Type: application/json')

admin_token() {
  "${CURL[@]}" -X POST "$KC_BASE/realms/master/protocol/openid-connect/token" \
    -d client_id=admin-cli -d grant_type=password -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'
}

if [ "${1:-}" = "--mint" ]; then
  "${CURL[@]}" -X POST "$KC_BASE/realms/$REALM/protocol/openid-connect/token" \
    -d "client_id=$CLIENT" -d "client_secret=$SECRET" -d grant_type=client_credentials \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token") or sys.exit("mint failed: "+json.dumps(d)))'
  exit 0
fi

TOK="$(admin_token)"; AUTH=(-H "Authorization: Bearer $TOK")
API="$KC_BASE/admin/realms/$REALM"

echo "[1/3] confidential client $CLIENT (client_credentials only)"
CID="$("${CURL[@]}" "${AUTH[@]}" "$API/clients?clientId=$CLIENT" | python3 -c 'import sys,json;c=json.load(sys.stdin);print(c[0]["id"] if c else "")')"
if [ -z "$CID" ]; then
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/clients" -d "{
    \"clientId\":\"$CLIENT\",\"secret\":\"$SECRET\",\"publicClient\":false,
    \"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false,
    \"serviceAccountsEnabled\":true,\"protocol\":\"openid-connect\"}"
  CID="$("${CURL[@]}" "${AUTH[@]}" "$API/clients?clientId=$CLIENT" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
  echo "  created ($CID)"
else echo "  exists ($CID)"; fi

echo "[2/3] audience mapper (aud=$AUD — custom audience, fail-open sur le trial, cf. ADR-075)"
add_mapper() { # add_mapper <name> <json-config>
  local name="$1" cfg="$2"
  if "${CURL[@]}" "${AUTH[@]}" "$API/clients/$CID/protocol-mappers/models" | grep -q "\"name\":\"$name\""; then echo "  mapper $name exists"; return; fi
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/clients/$CID/protocol-mappers/models" -d "$cfg" && echo "  mapper $name created"
}
add_mapper aud-wm-admin '{"name":"aud-wm-admin","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.custom.audience":"'"$AUD"'","id.token.claim":"false","access.token.claim":"true"}}'

echo "[3/3] client scopes ${SCOPES[*]} -> DEFAULT scopes du client (PAS deploy:prod)"
for SC in "${SCOPES[@]}"; do
  # create-or-get le client scope au realm (include.in.token.scope=true : le
  # claim `scope` du token DOIT porter deploy:{env} — c'est ce que la scope
  # mapping wM du proxy exige).
  SCID="$("${CURL[@]}" "${AUTH[@]}" "$API/client-scopes" | python3 -c '
import sys,json
for s in json.load(sys.stdin):
    if s.get("name") == "'"$SC"'":
        print(s["id"]); break')"
  if [ -z "$SCID" ]; then
    "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/client-scopes" -d "{
      \"name\":\"$SC\",\"protocol\":\"openid-connect\",
      \"attributes\":{\"include.in.token.scope\":\"true\",\"display.on.consent.screen\":\"false\"}}"
    SCID="$("${CURL[@]}" "${AUTH[@]}" "$API/client-scopes" | python3 -c '
import sys,json
for s in json.load(sys.stdin):
    if s.get("name") == "'"$SC"'":
        print(s["id"]); break')"
    echo "  client scope $SC created ($SCID)"
  else echo "  client scope $SC exists ($SCID)"; fi
  # DEFAULT scope : présent dans CHAQUE token client_credentials du client
  # (PUT idempotent — 204 même si déjà attaché).
  "${CURL[@]}" "${AUTH[@]}" -X PUT "$API/clients/$CID/default-client-scopes/$SCID" -o /dev/null
  echo "  $SC -> default scope of $CLIENT"
done

echo "done. Non-prod CI service account ready. Mint: $0 --mint  (client_credentials, scopes: ${SCOPES[*]})"
