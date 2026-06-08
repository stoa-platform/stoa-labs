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
echo "════════ 4/4  data-plane probe (each gateway from one contract) ════════"
# Host-mapped data-plane ports (see .env). webMethods mock has no auth → 200 synthetic.
# WSO2/APISIX enforce auth after subscribe → expect 401 unauthenticated (proves the
# policy is live); authenticated end-to-end calls are the Phase 3 / EVIDENCE step.
probe() { # name url
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$2" 2>/dev/null || echo 000)
  printf "  %-12s %s -> HTTP %s\n" "$1" "$2" "$code"
}
probe "webmethods" "http://localhost:${PORT_WEBMETHODS:-8090}/gateway/accounts-read/v1/accounts"
probe "apisix"     "http://localhost:${PORT_APISIX:-9080}/accounts-read/v1/accounts"
probe "wso2"       "https://localhost:${PORT_WSO2_GATEWAY:-8243}/accounts-read/v1/accounts"

echo ""
echo "✓ Phase 2 demo complete — one OpenAPI contract, three heterogeneous gateways."
echo "  Grafana (traces of the calls above): http://localhost:${PORT_GRAFANA:-3000}"
echo "  Full synthetic credentials: ./labctl-credentials.txt (gitignored)"
