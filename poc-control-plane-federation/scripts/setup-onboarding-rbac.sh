#!/usr/bin/env bash
# setup-onboarding-rbac.sh — idempotent Keycloak setup for the SECURED
# onboarding-api (OAuth2/OIDC + RBAC multi-tenant).
#
# It provisions, in realm stoa-lab, everything a developer needs to mint a REAL
# token that the onboarding-api will accept:
#
#   1. realm role  'partner-onboarder'                 (the RBAC capability)
#   2. confidential client 'onboarding-dev'            (the DEV token minter)
#        - directAccessGrants ON  (ROPC password grant -> a token from CLI)
#        - protocol mappers:
#            * audience      -> aud=onboarding-api      (the API's expected aud)
#            * user-attribute 'tenant' -> claim 'tenant'(RBAC tenant scope)
#            * group-membership (full path)             (alt /tenants/{t} path)
#   3. dev users carrying role + tenant attribute:
#            * onboarder-banking   tenant=banking-demo
#            * onboarder-payments  tenant=payments-team
#      and group '/tenants/banking-demo' (proves the group-based tenant path)
#
# Re-running converges (look-up-then-create / PUT). Nothing here is a production
# secret: DEV_SECRET and the user passwords are DISPOSABLE PoC material,
# fournies par l'environnement (voir poc-control-plane-federation/.env.example),
# jamais committées en dur.
#
# Mint a token (the EXACT dev command), then call the API:
#
#   TOKEN=$(scripts/setup-onboarding-rbac.sh --mint banking)
#   curl -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
#        -d '{"name":"acme","tenant":"banking-demo","clientId":"acme",...}' \
#        http://localhost:8788/applications
set -euo pipefail

KC_BASE="${KC_BASE:-http://localhost:8480}"
REALM="${REALM:-stoa-lab}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
ROLE="${ROLE:-partner-onboarder}"
APPLIER_ROLE="${APPLIER_ROLE:-cp-applier}"   # gates the apply/converge plane (labctl apply-uac)
DEV_CLIENT="${DEV_CLIENT:-onboarding-dev}"
DEV_SECRET="${DEV_SECRET:?Variable DEV_SECRET absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
AUDIENCE="${AUDIENCE:-onboarding-api}"
DEV_PASS="${DEV_PASS:-password}"
CURL=(/usr/bin/curl -s)

admin_token() {
  "${CURL[@]}" -X POST "$KC_BASE/realms/master/protocol/openid-connect/token" \
    -d client_id=admin-cli -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    -d grant_type=password \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'
}

# --mint [banking|payments]: print ONLY a raw access token for that tenant's dev
# user (role partner-onboarder + tenant claim + aud=onboarding-api). Logs none.
if [ "${1:-}" = "--mint" ]; then
  WHICH="${2:-banking}"
  case "$WHICH" in
    banking)  MUSER="onboarder-banking" ;;
    payments) MUSER="onboarder-payments" ;;
    *) echo "usage: $0 --mint [banking|payments]" >&2; exit 2 ;;
  esac
  "${CURL[@]}" -X POST "$KC_BASE/realms/$REALM/protocol/openid-connect/token" \
    -d "client_id=$DEV_CLIENT" -d "client_secret=$DEV_SECRET" \
    -d grant_type=password -d "username=$MUSER" -d "password=$DEV_PASS" \
    -d scope=openid \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token") or sys.exit("mint failed: "+json.dumps(d)))'
  exit 0
fi

TOK="$(admin_token)"
AUTH=(-H "Authorization: Bearer $TOK")
API="$KC_BASE/admin/realms/$REALM"
JSON=(-H 'Content-Type: application/json')

echo "[1/7] realm role $ROLE"
if "${CURL[@]}" "${AUTH[@]}" "$API/roles/$ROLE" | grep -q '"name"'; then
  echo "  role exists"
else
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/roles" \
    -d "{\"name\":\"$ROLE\",\"description\":\"Onboard partners as-code (onboarding-api)\"}"
  echo "  role created"
fi
ROLE_REP="$("${CURL[@]}" "${AUTH[@]}" "$API/roles/$ROLE")"

echo "[1b/7] realm role $APPLIER_ROLE (apply/converge plane)"
if "${CURL[@]}" "${AUTH[@]}" "$API/roles/$APPLIER_ROLE" | grep -q '"name"'; then
  echo "  role exists"
else
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/roles" \
    -d "{\"name\":\"$APPLIER_ROLE\",\"description\":\"Apply UAC contracts to gateways scoped to one tenant (labctl apply-uac)\"}"
  echo "  role created"
fi
APPLIER_REP="$("${CURL[@]}" "${AUTH[@]}" "$API/roles/$APPLIER_ROLE")"

echo "[2/7] confidential dev client $DEV_CLIENT"
CID="$("${CURL[@]}" "${AUTH[@]}" "$API/clients?clientId=$DEV_CLIENT" \
  | python3 -c 'import sys,json;c=json.load(sys.stdin);print(c[0]["id"] if c else "")')"
if [ -z "$CID" ]; then
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/clients" -d "{
    \"clientId\":\"$DEV_CLIENT\",\"secret\":\"$DEV_SECRET\",
    \"publicClient\":false,\"standardFlowEnabled\":false,
    \"directAccessGrantsEnabled\":true,\"serviceAccountsEnabled\":true,
    \"protocol\":\"openid-connect\"}"
  CID="$("${CURL[@]}" "${AUTH[@]}" "$API/clients?clientId=$DEV_CLIENT" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
  echo "  client created ($CID)"
else
  echo "  client exists ($CID)"
fi

echo "[3/7] protocol mappers on $DEV_CLIENT (audience + tenant + groups)"
ensure_mapper() {  # name json
  local name="$1" payload="$2"
  if "${CURL[@]}" "${AUTH[@]}" "$API/clients/$CID/protocol-mappers/models" \
       | python3 -c "import sys,json;ms=json.load(sys.stdin);sys.exit(0 if any(m['name']=='$name' for m in ms) else 1)"; then
    echo "  mapper $name exists"
  else
    "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/clients/$CID/protocol-mappers/models" -d "$payload"
    echo "  mapper $name created"
  fi
}
ensure_mapper "aud-onboarding-api" "{
  \"name\":\"aud-onboarding-api\",\"protocol\":\"openid-connect\",
  \"protocolMapper\":\"oidc-audience-mapper\",
  \"config\":{\"included.custom.audience\":\"$AUDIENCE\",
    \"access.token.claim\":\"true\",\"id.token.claim\":\"false\",
    \"introspection.token.claim\":\"true\"}}"
ensure_mapper "tenant" "{
  \"name\":\"tenant\",\"protocol\":\"openid-connect\",
  \"protocolMapper\":\"oidc-usermodel-attribute-mapper\",
  \"config\":{\"user.attribute\":\"tenant\",\"claim.name\":\"tenant\",
    \"jsonType.label\":\"String\",\"access.token.claim\":\"true\",
    \"id.token.claim\":\"true\",\"userinfo.token.claim\":\"true\",
    \"introspection.token.claim\":\"true\"}}"
ensure_mapper "groups" "{
  \"name\":\"groups\",\"protocol\":\"openid-connect\",
  \"protocolMapper\":\"oidc-group-membership-mapper\",
  \"config\":{\"claim.name\":\"groups\",\"full.path\":\"true\",
    \"access.token.claim\":\"true\",\"id.token.claim\":\"true\",
    \"introspection.token.claim\":\"true\"}}"

echo "[4/7] group /tenants/banking-demo (proves the group-based tenant path)"
PARENT_ID="$("${CURL[@]}" "${AUTH[@]}" "$API/groups?search=tenants" \
  | python3 -c 'import sys,json
gs=json.load(sys.stdin)
print(next((g["id"] for g in gs if g["name"]=="tenants"),""))')"
if [ -z "$PARENT_ID" ]; then
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/groups" -d '{"name":"tenants"}'
  PARENT_ID="$("${CURL[@]}" "${AUTH[@]}" "$API/groups?search=tenants" \
    | python3 -c 'import sys,json
gs=json.load(sys.stdin);print(next((g["id"] for g in gs if g["name"]=="tenants"),""))')"
fi
# child banking-demo
CHILD="$("${CURL[@]}" "${AUTH[@]}" "$API/groups/$PARENT_ID/children" 2>/dev/null \
  | python3 -c 'import sys,json
try: gs=json.load(sys.stdin)
except Exception: gs=[]
print(next((g["id"] for g in gs if g["name"]=="banking-demo"),""))' || true)"
if [ -z "$CHILD" ]; then
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/groups/$PARENT_ID/children" -d '{"name":"banking-demo"}' >/dev/null 2>&1 || true
fi
echo "  group /tenants/banking-demo ready"

# create_dev_user NAME TENANT
create_dev_user() {
  local uname="$1" tenant="$2"
  local uid
  uid="$("${CURL[@]}" "${AUTH[@]}" "$API/users?username=$uname&exact=true" \
    | python3 -c 'import sys,json;u=json.load(sys.stdin);print(u[0]["id"] if u else "")')"
  if [ -z "$uid" ]; then
    "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/users" -d "{
      \"username\":\"$uname\",\"enabled\":true,\"emailVerified\":true,
      \"email\":\"$uname@bank.example\",\"firstName\":\"$uname\",\"lastName\":\"dev\",
      \"attributes\":{\"tenant\":[\"$tenant\"]}}"
    uid="$("${CURL[@]}" "${AUTH[@]}" "$API/users?username=$uname&exact=true" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')"
  else
    # converge the tenant attribute on an existing user
    "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X PUT "$API/users/$uid" -d "{
      \"attributes\":{\"tenant\":[\"$tenant\"]}}" >/dev/null
  fi
  # set password (non-temporary)
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X PUT "$API/users/$uid/reset-password" -d "{
    \"type\":\"password\",\"value\":\"$DEV_PASS\",\"temporary\":false}"
  # assign BOTH realm roles (idempotent: POST of an already-held role is a no-op).
  # The same dev identity may onboard (write plane) AND, as the CI service account,
  # apply within its tenant (apply plane) — tenant scope binds both.
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/users/$uid/role-mappings/realm" \
    -d "[$ROLE_REP]" >/dev/null 2>&1 || true
  "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X POST "$API/users/$uid/role-mappings/realm" \
    -d "[$APPLIER_REP]" >/dev/null 2>&1 || true
  echo "  user $uname (tenant=$tenant, roles=$ROLE,$APPLIER_ROLE) ready ($uid)"
  echo "$uid"
}

echo "[5/7] dev user onboarder-banking (tenant=banking-demo)"
BANK_UID="$(create_dev_user onboarder-banking banking-demo | tail -1)"
# also add onboarder-banking to /tenants/banking-demo (group-based tenant path)
if [ -n "${PARENT_ID:-}" ]; then
  CHILD="$("${CURL[@]}" "${AUTH[@]}" "$API/groups/$PARENT_ID/children" 2>/dev/null \
    | python3 -c 'import sys,json
try: gs=json.load(sys.stdin)
except Exception: gs=[]
print(next((g["id"] for g in gs if g["name"]=="banking-demo"),""))' || true)"
  [ -n "$CHILD" ] && "${CURL[@]}" "${AUTH[@]}" "${JSON[@]}" -X PUT "$API/users/$BANK_UID/groups/$CHILD" >/dev/null 2>&1 || true
fi

echo "[6/7] dev user onboarder-payments (tenant=payments-team)"
create_dev_user onboarder-payments payments-team >/dev/null

echo "[7/7] done. Mint a token with:"
echo "    TOKEN=\$($0 --mint banking)     # role=$ROLE tenant=banking-demo aud=$AUDIENCE"
echo "    TOKEN=\$($0 --mint payments)    # role=$ROLE tenant=payments-team aud=$AUDIENCE"
