#!/usr/bin/env bash
# get-oracle-token.sh — Oracle-master token path (Option A).
#
# Proves "Oracle stays master, Keycloak emits the token": scripts the OIDC
# authorization_code flow through the Keycloak broker (alias "oracle") whose
# upstream is Dex (the mock Oracle IdP). A single browserless curl chain logs
# alice@bc.example into Dex and returns a Keycloak-issued RS256 access token
# carrying the Dex-sourced identity. The token is JWKS-validatable by the
# 3 data-plane gateways (WSO2 / APISIX / webMethods).
#
# Why not the alternatives (verified live 2026-06-08):
#   - password grant via broker: Dex returns unsupported_grant_type -> impossible.
#   - token-exchange: absent from KC realm grant_types (feature off); even enabled
#     it still needs a Dex user token first (Dex only mints via auth_code/device_code).
#
# Prereq (one-time, already applied): identity/dex/config.yaml staticPasswords
# hash must be a real bcrypt of "password", and Dex must be RESTARTED after any
# config edit (storage:memory reads config once at startup).
set -euo pipefail

KC_BASE="${KC_BASE:-http://localhost:8480}"
REALM="${REALM:-stoa-lab}"
DEX_BASE="${DEX_BASE:-http://localhost:5556}"
CLIENT_ID="${CLIENT_ID:-stoa-portal}"        # public client, standardFlow + redirectUris '*'
REDIRECT_URI="${REDIRECT_URI:-http://localhost:8480}"
IDP_HINT="${IDP_HINT:-oracle}"
DEX_USER="${DEX_USER:-alice@bc.example}"
DEX_PASS="${DEX_PASS:-password}"
KC="${KC_BASE}/realms/${REALM}"
STATE="poc$(date +%s)"

# --quiet: emit ONLY the raw access token on stdout (logs go to stderr).
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
log(){ if [ "$QUIET" = 1 ]; then echo "$@" >&2; else echo "$@"; fi; }
JAR="$(mktemp)"; trap 'rm -f "$JAR" "$JAR".a1 "$JAR".a2 "$JAR".hdr' EXIT

log "[1/4] KC /auth?kc_idp_hint=${IDP_HINT}  -> follow broker redirect to Dex login form"
curl -s -c "$JAR" -b "$JAR" -L -o "$JAR".a1 \
  "${KC}/protocol/openid-connect/auth?client_id=${CLIENT_ID}&response_type=code&scope=openid&redirect_uri=${REDIRECT_URI}&state=${STATE}&kc_idp_hint=${IDP_HINT}"
FORM_ACTION=$(grep -oE 'action="[^"]*"' "$JAR".a1 | head -1 | sed 's/action="//;s/"$//;s/&amp;/\&/g')
[ -n "$FORM_ACTION" ] || { echo "ERROR: no Dex login form (check redirect_uri is registered in Dex AND that Dex was restarted after config edits)" >&2; exit 1; }

log "[2/4] POST Dex credentials (${DEX_USER}) -> Dex code -> KC broker endpoint -> app callback"
curl -s -c "$JAR" -b "$JAR" -L -o "$JAR".a2 -D "$JAR".hdr \
  --data-urlencode "login=${DEX_USER}" \
  --data-urlencode "password=${DEX_PASS}" \
  "${DEX_BASE}${FORM_ACTION}"
if grep -qiE 'Invalid Email Address and password' "$JAR".a2; then
  echo "ERROR: Dex rejected credentials. The staticPasswords bcrypt hash likely does not match '${DEX_PASS}'." >&2; exit 1; fi
# NOTE: on the FIRST ever login for this user, KC runs first-broker-login and
# renders a 'Review Profile' page (kc-idp-review-profile-form). This script's
# -L ride handles the happy path once the user is provisioned; if you hit that
# form, POST it back once (fields username/email/firstName/lastName) or pre-seed
# the federated user in the realm. After the first login it is skipped.

# Pick the app callback Location (carries OUR state AND code=), not the later
# host-root -> /admin/master/console redirects.
CODE=$(grep -i '^location:' "$JAR".hdr | grep "state=${STATE}" | grep 'code=' | head -1 \
       | grep -oE 'code=[A-Za-z0-9._-]+' | head -1 | cut -d= -f2 || true)
[ -n "$CODE" ] || { echo "ERROR: no authorization code in callback. Locations seen:" >&2; grep -i '^location:' "$JAR".hdr >&2; exit 1; }
log "      got authorization code: ${CODE:0:24}..."

log "[3/4] Exchange code -> Keycloak token"
TOK=$(curl -s -X POST "${KC}/protocol/openid-connect/token" \
  -d grant_type=authorization_code -d "client_id=${CLIENT_ID}" \
  -d "code=${CODE}" --data-urlencode "redirect_uri=${REDIRECT_URI}")
ACCESS=$(printf '%s' "$TOK" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
[ -n "$ACCESS" ] || { echo "ERROR token exchange:" >&2; echo "$TOK" >&2; exit 1; }

log "[4/4] OK. Keycloak-issued token (Oracle-sourced identity):"
if [ "$QUIET" = 0 ]; then
  printf '%s' "$ACCESS" | python3 -c '
import sys,base64,json
p=sys.stdin.read().split(".")[1]; p+="="*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
for k in ("iss","preferred_username","email","azp","scope","typ"):
    if k in c: print(f"      {k} = {c[k]}")
print("      (iss = Keycloak realm  =>  KC EMITS;  username/email from Dex  =>  ORACLE is MASTER)")'
  echo
  echo "Use it against the data plane, e.g.:"
  echo "  curl -H \"Authorization: Bearer \$TOKEN\" http://localhost:9080/<basePath>   # APISIX"
fi

# --quiet: ONLY the raw token on stdout (so: TOKEN=\$(scripts/get-oracle-token.sh --quiet))
if [ "$QUIET" = 1 ]; then printf '%s\n' "$ACCESS"; fi
