#!/usr/bin/env bash
# DoD Phase 2 — "Define Once, Expose Everywhere".
# Drives labctl end-to-end against the running socle (run ./scripts/up.sh first):
#   1. apply     : 1 OpenAPI contract -> published on WSO2 + APISIX + webMethods
#   2. get apis  : the unified federated catalog across the 3 runtimes
#   3. subscribe : 1 Keycloak client -> a consumer on each gateway
#   4. data-plane probe on each gateway's invocation URL
set -uo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && set -a && . ./.env && set +a

echo "→ building labctl"
( cd labctl && go build -o /tmp/labctl . ) || { echo "build failed"; exit 1; }

echo "→ seeding the synthetic backend: importing the contract into Microcks"
# Microcks mocks the backend from the same OpenAPI (examples -> responses).
# Idempotent: re-uploading updates the service. The gateways proxy to
# http://microcks:8080/rest/Accounts+Read+API/1.0.0 (see targets.yaml backendUrl).
if curl -s --max-time 15 -F "file=@apis/accounts-read.openapi.yaml" \
     "http://localhost:${PORT_MICROCKS:-8585}/api/artifact/upload" | grep -q "Accounts Read API"; then
  echo "  ✓ accounts-read imported into Microcks"
else
  echo "  ⚠ Microcks import failed — data-plane calls may 404 (is Microcks up?)"
fi

echo ""
echo "════════ 1/4  labctl apply — Define Once, Expose Everywhere ════════"
/tmp/labctl apply -f targets.yaml || { echo "apply failed (is the socle up? ./scripts/up.sh)"; exit 1; }

echo ""
echo "════════ 2/4  labctl get apis — unified federated catalog ════════"
/tmp/labctl get apis -f targets.yaml

echo ""
echo "════════ 3/4  labctl subscribe — self-service consumer + Keycloak client ════════"
/tmp/labctl subscribe -f targets.yaml

echo ""
echo "════════ 4/4  AUTHENTICATED data-plane call through each gateway ════════"
# After subscribe, WSO2 + APISIX enforce auth (unauth -> 401). Each gateway uses
# its NATIVE credential model — that heterogeneity is the whole point.
# get <section> <key> : read a value from the 0600 credentials file. Splits on
# the first '=' and trims, so it tolerates the column alignment and '='-bearing values.
get() { awk -v sec="[$1]" -v k="$2" '
  $0==sec{f=1;next} f&&/^\[/{exit}
  f{p=index($0,"="); if(p){key=substr($0,1,p-1); gsub(/ /,"",key); if(key==k){v=substr($0,p+1); sub(/^ +/,"",v); print v; exit}}}
' labctl-credentials.txt; }

echo "— webMethods (legacy mock, no auth):"
curl -s --max-time 6 -w '\n  HTTP %{http_code}\n' \
  "http://localhost:${PORT_WEBMETHODS:-8090}/gateway/accounts-read/v1/accounts" | head -c 240

echo "— APISIX (key-auth, native apikey header):"
APIKEY=$(get apisix consumerKey)
curl -s -o /dev/null -w "  no key  -> HTTP %{http_code}\n" --max-time 6 "http://localhost:${PORT_APISIX:-9080}/accounts-read/v1/accounts"
curl -s --max-time 6 -H "apikey: $APIKEY" -w '\n  apikey  -> HTTP %{http_code}\n' \
  "http://localhost:${PORT_APISIX:-9080}/accounts-read/v1/accounts" | head -c 240

echo "— WSO2 (OAuth2 client_credentials -> Bearer):"
WK=$(get wso2 consumerKey); WS=$(get wso2 consumerSecret)
WTOK=$(curl -sk -u "$WK:$WS" -d grant_type=client_credentials "https://localhost:${PORT_WSO2_CONSOLE:-9443}/oauth2/token" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
curl -sk -o /dev/null -w "  no token-> HTTP %{http_code}\n" --max-time 6 "https://localhost:${PORT_WSO2_GATEWAY:-8243}/accounts-read/v1/1.0.0/accounts"
curl -sk --max-time 6 -H "Authorization: Bearer $WTOK" -w '\n  bearer  -> HTTP %{http_code}\n' \
  "https://localhost:${PORT_WSO2_GATEWAY:-8243}/accounts-read/v1/1.0.0/accounts" | head -c 240

echo ""
echo "✓ Phase 2 complete — ONE OpenAPI contract, THREE heterogeneous gateways,"
echo "  each serving the same synthetic data under its own native auth."
echo "  Grafana (OTel traces of these calls): http://localhost:${PORT_GRAFANA:-3000}"
echo "  Full synthetic credentials: ./labctl-credentials.txt (gitignored)"
