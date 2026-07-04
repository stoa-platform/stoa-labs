#!/usr/bin/env bash
# Invocation DATA-PLANE de bout en bout : token Oracle-master (alice via
# Dex→Keycloak broker) → appel des APIs projetées À TRAVERS chaque gateway
# réelle → réponses du backend (Microcks). Contraste avec/sans token.
set -uo pipefail
POC="$(cd "$(dirname "$0")/../../poc-control-plane-federation" && pwd)"
EV="$(cd "$(dirname "$0")/.." && pwd)/evidence/ci/invocation-e2e.txt"
: > "$EV"
say() { echo "$@" | tee -a "$EV"; }

say "=== Invocation E2E — $(date '+%Y-%m-%d %H:%M') ==="
say ""
say "[1] Token Oracle-master (alice@bc.example via Dex → broker Keycloak)"
TOKEN=$(bash "$POC/scripts/get-oracle-token.sh" --quiet 2>/dev/null)
if [ -z "$TOKEN" ]; then say "ERREUR: pas de token"; exit 1; fi
printf '%s' "$TOKEN" | python3 -c '
import sys,base64,json
p=sys.stdin.read().split(".")[1]; p+="="*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
print(f"    iss={c.get(\"iss\")}")
print(f"    user={c.get(\"preferred_username\")} (identité Oracle, token émis par Keycloak)")' | tee -a "$EV"

invoke() { # invoke <gateway> <url> [token]
  local gw="$1" url="$2" tok="${3:-}"
  local args=(-sk -o /tmp/inv.out -w '%{http_code}')
  [ -n "$tok" ] && args+=(-H "Authorization: Bearer $tok")
  local code; code=$(curl "${args[@]}" "$url")
  local body; body=$(head -c 160 /tmp/inv.out | tr '\n' ' ')
  printf '    %-12s %-4s %s\n' "$gw" "$code" "$url" | tee -a "$EV"
  if [ "$code" = "200" ]; then printf '                 ↳ %s…\n' "$body" | tee -a "$EV"; fi
}

say ""
say "[2] accounts-read — AVEC token (attendu : 200, données du backend à travers la gateway)"
invoke "APISIX"     "http://localhost:9080/accounts-read/v1/accounts" "$TOKEN"
invoke "WSO2"       "https://localhost:8243/accounts-read/v1/1.0.0/accounts" "$TOKEN"
invoke "webMethods" "http://localhost:5555/gateway/accounts-read/1.0.0/accounts" "$TOKEN"

say ""
say "[3] customer-referential — AVEC token (contrat publié ce matin DEPUIS LA CONSOLE)"
invoke "APISIX"     "http://localhost:9080/customer-referential/v1/customers" "$TOKEN"
invoke "WSO2"       "https://localhost:8243/customer-referential/v1/1.2.0/customers" "$TOKEN"
invoke "webMethods" "http://localhost:5555/gateway/customer-referential/1.2.0/customers" "$TOKEN"

say ""
say "[4] SANS token (contraste sécurité — attendu : 401 là où la policy JWT est posée)"
invoke "APISIX"     "http://localhost:9080/accounts-read/v1/accounts"
invoke "WSO2"       "https://localhost:8243/accounts-read/v1/1.0.0/accounts"
invoke "webMethods" "http://localhost:5555/gateway/accounts-read/1.0.0/accounts"

say ""
say "[5] payments-initiation — NON invoquée volontairement : endpoint destructif,"
say "    requires_human_approval=true (la gouvernance interdit l'appel machine direct)."
say ""
say "=== fin — evidence: $EV ==="
