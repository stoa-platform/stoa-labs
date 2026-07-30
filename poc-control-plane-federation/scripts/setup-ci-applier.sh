#!/usr/bin/env bash
# setup-ci-applier.sh — idempotent Keycloak setup for the CI APPLY service
# account (ADR-072). This is the secure answer to "le compte de service est-il
# sûr ? c'est mieux que de l'OAuth2 ?": the CI pipeline does NOT carry a user
# password nor a gateway admin credential — it holds ONE confidential client
# (client_credentials grant only) whose token carries the realm role cp-applier
# and a tenant. labctl apply-uac then BINDS the apply scope to that tenant.
#
# Provisioned in realm stoa-lab:
#   1. confidential client `ci-applier` (serviceAccounts ON, client_credentials
#      ONLY — directAccessGrants OFF, standardFlow OFF) with mappers:
#        - audience -> aud=onboarding-api
#        - user-attribute tenant -> claim tenant
#   2. its service-account user: realm role cp-applier + attribute tenant=<TENANT>
#
#   Mint the CI token (client_credentials — no user, no password):
#     TOKEN=$(scripts/setup-ci-applier.sh --mint)
#   In prod: one ci-applier client PER tenant, secret issued from Vault, rotated.
set -euo pipefail
KC_BASE="${KC_BASE:-http://localhost:8480}"
REALM="${REALM:-stoa-lab}"
ADMIN_USER="${ADMIN_USER:-admin}"; ADMIN_PASS="${ADMIN_PASS:-admin}"
# CI_SECRET prioritaire (appel ponctuel explicite) ; sinon CI_APPLIER_SECRET,
# LA MÊME variable que lit setup-vault.sh / setup-vault-envs.sh pour écrire ce
# secret dans Vault — évite la dérive silencieuse entre le secret avec lequel
# CE script crée le client Keycloak et celui que Vault distribue ensuite.
CLIENT="${CI_CLIENT:-ci-applier}"; SECRET="${CI_SECRET:-${CI_APPLIER_SECRET:?Variable CI_SECRET (ou CI_APPLIER_SECRET) absente — définissez-la (voir poc-control-plane-federation/.env.example)}}"
TENANT="${CI_TENANT:-banking-demo}"; AUD="${AUDIENCE:-onboarding-api}"
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

echo "[1/4] confidential client $CLIENT (client_credentials only)"
CID="$("${CURL[@]}" "${AUTH[@]}" "$API/clients?clientId=$CLIENT" | python3 -c 'import sys,json;c=json.load(sys.stdin);print(c[0]["id"] if c else "")')"
if [ -z "$CID" ]; then
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/clients" -d "{
    \"clientId\":\"$CLIENT\",\"secret\":\"$SECRET\",\"publicClient\":false,
    \"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false,
    \"serviceAccountsEnabled\":true,\"protocol\":\"openid-connect\"}"
  CID="$("${CURL[@]}" "${AUTH[@]}" "$API/clients?clientId=$CLIENT" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
  echo "  created ($CID)"
else echo "  exists ($CID)"; fi

echo "[2/4] mappers (audience -> $AUD ; user attribute tenant -> claim tenant)"
add_mapper() { # add_mapper <name> <json-config>
  local name="$1" cfg="$2"
  if "${CURL[@]}" "${AUTH[@]}" "$API/clients/$CID/protocol-mappers/models" | grep -q "\"name\":\"$name\""; then echo "  mapper $name exists"; return; fi
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/clients/$CID/protocol-mappers/models" -d "$cfg" && echo "  mapper $name created"
}
add_mapper aud-onboarding '{"name":"aud-onboarding","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"'"$AUD"'","id.token.claim":"false","access.token.claim":"true"}}'
add_mapper tenant '{"name":"tenant","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"user.attribute":"tenant","claim.name":"tenant","jsonType.label":"String","id.token.claim":"false","access.token.claim":"true","userinfo.token.claim":"true"}}'

echo "[3/4] service-account user: attribute tenant=$TENANT"
SAID="$("${CURL[@]}" "${AUTH[@]}" "$API/clients/$CID/service-account-user" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
"${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X PUT "$API/users/$SAID" -d "{\"attributes\":{\"tenant\":[\"$TENANT\"]}}"
echo "  service-account-$CLIENT tenant=$TENANT ($SAID)"

echo "[4/4] assign realm role cp-applier to the service account"
ROLE_REP="$("${CURL[@]}" "${AUTH[@]}" "$API/roles/cp-applier")"
echo "$ROLE_REP" | grep -q '"name"' || { echo "  ERROR: role cp-applier missing — run setup-onboarding-rbac.sh first"; exit 1; }
"${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/users/$SAID/role-mappings/realm" -d "[$ROLE_REP]" >/dev/null 2>&1 || true
echo "  cp-applier assigned"

echo "done. CI service account ready. Mint: $0 --mint  (client_credentials, tenant=$TENANT, role cp-applier)"
