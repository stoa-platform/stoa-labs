#!/usr/bin/env bash
# DoD Phase 1 : vérifie que les 3 gateways + identité + observabilité répondent.
set -uo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && set -a && . ./.env && set +a

fail=0
check() {
  local name="$1" url="$2" expect="${3:-200}"
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo 000)
  if [[ "$code" == "$expect" || ( "$expect" == "2xx" && "$code" =~ ^2 ) ]]; then
    printf "  ✓ %-26s %s (%s)\n" "$name" "$url" "$code"
  else
    printf "  ✗ %-26s %s (got %s, want %s)\n" "$name" "$url" "$code" "$expect"
    fail=1
  fi
}

echo "Smoke test — socle PoC fédération"
check "webMethods mock"  "http://localhost:${PORT_WEBMETHODS:-8090}/rest/apigateway/is/health" 200
check "APISIX status"    "http://localhost:${PORT_APISIX:-9080}/apisix/status" 200
check "WSO2 (gateway)"   "https://localhost:${PORT_WSO2_CONSOLE:-9443}/services/Version" 200
check "Keycloak realm"   "http://localhost:8480/realms/stoa-lab/.well-known/openid-configuration" 200
check "Dex (mock Oracle)" "http://localhost:${PORT_DEX:-5556}/dex/.well-known/openid-configuration" 200
check "Grafana"          "http://localhost:${PORT_GRAFANA:-3000}/api/health" 200
check "Microcks"         "http://localhost:${PORT_MICROCKS:-8585}/api/health" 200

if [[ $fail -eq 0 ]]; then
  echo "✓ DoD Phase 1 : tous les endpoints répondent."
else
  echo "✗ certains endpoints ne répondent pas (voir ci-dessus)."
  exit 1
fi
