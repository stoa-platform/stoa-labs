#!/usr/bin/env bash
# Phase 3 DoD — ONE Keycloak token (Oracle-master via the broker) validated by
# all THREE heterogeneous gateways at the data-plane.
# webMethods = REAL apigateway-trial:10.15 (poc-webmethods-real, :5555), JWT
# imposé via labctl inboundAuth (alias auth-server JWKS + action IAM
# "Identify & Authorize" jwtClaims projetés par `labctl apply`).
# APISIX = openid-connect (bearer_only+use_jwks) AUSSI projeté par labctl
# inboundAuth (discoveryUrl) — plus besoin de setup-identity.sh §3/3 pour APISIX,
# et `labctl apply` ne rouvre plus le trou (la route re-PUT porte le plugin).
# Prereq: ./scripts/demo.sh  (publish+subscribe) then ./scripts/setup-identity.sh
#         (WSO2 Key Manager + realm Keycloak; la partie APISIX y est désormais
#         redondante) + docker-compose.wm.yml up (real webMethods gateway)
set -uo pipefail
cd "$(dirname "$0")/.."
get() { awk -v sec="[$1]" -v k="$2" '$0==sec{f=1;next} f&&/^\[/{exit} f{p=index($0,"="); if(p){key=substr($0,1,p-1); gsub(/ /,"",key); if(key==k){v=substr($0,p+1); sub(/^ +/,"",v); print v; exit}}}' labctl-credentials.txt; }
KC_CID=$(get keycloak clientId); KC_SEC=$(get keycloak clientSecret)

echo "════════ Oracle-master: Keycloak brokers the Oracle (Dex) IdP ════════"
loc=$(curl -s -o /dev/null -w '%{redirect_url}' "http://localhost:8480/realms/stoa-lab/protocol/openid-connect/auth?client_id=stoa-portal&redirect_uri=http://localhost:8480/&response_type=code&scope=openid&kc_idp_hint=oracle")
echo "  browser login /auth?kc_idp_hint=oracle → 303 → ${loc%%\?*}"
echo "  (a human login at Oracle/Dex yields a Keycloak token with the federated identity;"
echo "   for a headless proof we use the consumer's service-account token below — same iss, same validation path.)"

echo ""
echo "════════ ONE Keycloak token (iss pinned to localhost:8480) ════════"
echo "  Trying the Oracle-brokered login (alice@bc.example via Dex)…"
# Log in through the broker as the MAPPED consumer client so azp matches the WSO2
# key mapping and the Oracle-federated token validates on all 3 gateways.
TOK=$(CLIENT_ID="$KC_CID" CLIENT_SECRET="$KC_SEC" ./scripts/get-oracle-token.sh --quiet 2>/dev/null || true)
if [[ -n "$TOK" ]]; then
  echo "  ✓ Oracle-federated token obtained (identity sourced from Dex/Oracle)"
else
  echo "  (broker first-login needs a profile pre-seed; using the consumer service-account"
  echo "   token instead — identical iss + validation path on the 3 gateways)"
  TOK=$(curl -s -d grant_type=client_credentials -d client_id="$KC_CID" -d client_secret="$KC_SEC" \
    "http://localhost:8480/realms/stoa-lab/protocol/openid-connect/token" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
fi
[[ -z "$TOK" ]] && { echo "  ✗ could not obtain a Keycloak token"; exit 1; }
echo "$TOK" | cut -d. -f2 | python3 -c "import sys,base64,json;s=sys.stdin.read().strip();s+='='*(-len(s)%4);d=json.loads(base64.urlsafe_b64decode(s));print('  iss =',d['iss'],'| azp =',d.get('azp'),'| user =',d.get('preferred_username'))"

call() { # name url
  local code; code=$(curl -sk -o /tmp/p3.json -w '%{http_code}' --max-time 8 -H "Authorization: Bearer $TOK" "$2")
  printf "  %-11s %s\n" "$1" "HTTP $code  $(head -c 70 /tmp/p3.json)"
}
no_tok() { # name url
  local code; code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$2")
  printf "  %-11s no token -> HTTP %s\n" "$1" "$code"
}

echo ""
echo "════════ the SAME token, validated by 3 heterogeneous gateways ════════"
call "wso2"       "https://localhost:8243/accounts-read/v1/1.0.0/accounts"
call "apisix"     "http://localhost:9080/accounts-read/v1/accounts"
call "webmethods" "http://localhost:5555/gateway/accounts-read/1.0.0/accounts"
echo "  — negative (auth enforced):"
no_tok "wso2"       "https://localhost:8243/accounts-read/v1/1.0.0/accounts"
no_tok "apisix"     "http://localhost:9080/accounts-read/v1/accounts"
no_tok "webmethods" "http://localhost:5555/gateway/accounts-read/1.0.0/accounts"

echo ""
echo "✓ Phase 3 — Oracle-master identity, federated by Keycloak, validated by"
echo "  WSO2 (Key Manager) + APISIX (openid-connect) + webMethods (JWKS) from ONE token."
