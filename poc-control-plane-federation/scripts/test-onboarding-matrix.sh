#!/usr/bin/env bash
# test-onboarding-matrix.sh — LIVE end-to-end matrix for the SECURED
# onboarding-api (OAuth2/OIDC + RBAC multi-tenant + audit OpenSearch).
#
# It does NOT cry victory on a green build: it boots the real binary against a
# throwaway governance repo + the live Keycloak (real RS256 tokens) + the live
# OpenSearch, and asserts the full authz matrix AND that a fresh audit document
# (ACCEPT and DENY) landed in the per-tenant index, correlated by trace_id.
#
#   A) banking token + body banking-demo   -> 201 + audit ACCEPT  (banking-demo)
#   B) banking token + body payments-team  -> 403 tenant_mismatch + audit DENY
#   C) client_credentials (no role)        -> 403 missing_role   (or 401 if no aud)
#   D) no token                            -> 401 no_token       + audit DENY (unknown)
#
# Re-runnable, self-cleaning. Air-gapped build (GOPROXY=off, vendored). No secret
# is printed; the disposable PoC passwords are supplied via the environment
# (see poc-control-plane-federation/.env.example), never hardcoded in this
# PoC's scripts.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC_BASE="${KC_BASE:-http://localhost:8480}"
REALM="${REALM:-stoa-lab}"
OS_URL="${OPENSEARCH_URL:-https://localhost:9201}"
OS_USER="${OPENSEARCH_USER:-admin}"
OS_PASS="${OPENSEARCH_PASSWORD:?Variable OPENSEARCH_PASSWORD absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
DEV_CLIENT="${DEV_CLIENT:-onboarding-dev}"
DEV_SECRET="${DEV_SECRET:?Variable DEV_SECRET absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
PORT="${PORT:-8788}"
API="http://localhost:${PORT}"
PASS=0; FAIL=0

say() { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# --- throwaway governance repo ----------------------------------------------
REPO="$(mktemp -d)/governance-repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name seed; git -C "$REPO" config user.email seed@test.local
git -C "$REPO" config commit.gpgsign false
printf '# governance (throwaway)\n' > "$REPO/README.md"
git -C "$REPO" add README.md; git -C "$REPO" commit -q -m "seed: init"

# --- build + boot the real binary -------------------------------------------
BIN="$(mktemp -d)/onboarding-api"
say "building onboarding-api (air-gapped)…"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" ./cmd/onboarding-api ) || { say "build failed"; exit 1; }

LOG="$(mktemp)"
GOVERNANCE_REPO="$REPO" KEYCLOAK_URL="$KC_BASE" KEYCLOAK_REALM="$REALM" \
  ONBOARDING_AUDIENCE=onboarding-api \
  OPENSEARCH_URL="$OS_URL" OPENSEARCH_USER="$OS_USER" OPENSEARCH_PASSWORD="$OS_PASS" \
  OPENSEARCH_INSECURE=true LISTEN=":${PORT}" \
  "$BIN" >"$LOG" 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }
trap cleanup EXIT

# wait for liveness
for _ in $(seq 1 50); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/healthz" 2>/dev/null)" = "200" ] && break
  sleep 0.2
done
[ "$(curl -s -o /dev/null -w '%{http_code}' "$API/healthz")" = "200" ] || { say "server did not come up; log:"; cat "$LOG"; exit 1; }
say "onboarding-api up on $API (repo=$REPO)"

# --- mint real tokens --------------------------------------------------------
TOK_BANK="$(bash "$ROOT/scripts/setup-onboarding-rbac.sh" --mint banking 2>/dev/null | tail -1)"
TOK_PAY="$(bash "$ROOT/scripts/setup-onboarding-rbac.sh" --mint payments 2>/dev/null | tail -1)"
TOK_CC="$(curl -s -X POST "$KC_BASE/realms/$REALM/protocol/openid-connect/token" \
  -d client_id="$DEV_CLIENT" -d client_secret="$DEV_SECRET" -d grant_type=client_credentials \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')"
[ -n "$TOK_BANK" ] || { say "could not mint banking token"; exit 1; }

# call <name> <token-or-empty> <tenant-in-body> -> sets RC / RTRACE / RREASON
call() {
  local name slug tok tenant hdr body
  name="$1"; tok="$2"; tenant="$3"
  slug="acme-$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"   # DNS-safe slug (no uppercase)
  hdr="$(mktemp)"
  body='{"name":"'"$slug"'","tenant":"'"$tenant"'","clientId":"'"$slug"'-client","apis":["accounts-read"],"ipAllowlist":["203.0.113.10"]}'
  local auth=(); [ -n "$tok" ] && auth=(-H "Authorization: Bearer $tok")
  RC="$(curl -s -o /tmp/obm_body.$$ -D "$hdr" -w '%{http_code}' \
        ${auth[@]+"${auth[@]}"} -H 'Content-Type: application/json' -d "$body" "$API/applications")"
  RTRACE="$(grep -i '^X-Trace-Id:' "$hdr" | tr -d '\r' | awk '{print $2}')"
  RREASON="$(python3 -c 'import sys,json
try:
  d=json.load(open("/tmp/obm_body.'"$$"'"))
  print(d.get("reason") or d.get("error") or "")
except Exception: print("")')"
  rm -f "$hdr" "/tmp/obm_body.$$"
}

# audit_has <index> <trace_id> <decision> <reason>
audit_has() {
  local idx="$1" tid="$2" dec="$3" rsn="$4"
  [ -z "$tid" ] && { bad "audit[$idx]: no trace_id from response"; return; }
  local n; n="$(curl -sk -u "$OS_USER:$OS_PASS" \
    "$OS_URL/$idx/_search?q=trace_id:$tid" 2>/dev/null \
    | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); hits=d.get("hits",{}).get("hits",[])
  m=[h for h in hits if h["_source"].get("decision")=="'"$dec"'" and "'"$rsn"'" in (h["_source"].get("reason") or "")]
  print(len(m))
except Exception: print(0)')"
  if [ "${n:-0}" -ge 1 ]; then ok "audit[$idx] trace=$tid decision=$dec reason~$rsn (fresh doc)"; else bad "audit[$idx] trace=$tid: no $dec/$rsn doc"; fi
}

say ""; say "=== AUTHZ MATRIX (live Keycloak tokens, live OpenSearch audit) ==="

# A) same-tenant write
call A "$TOK_BANK" banking-demo
{ [ "$RC" = "201" ] || [ "$RC" = "200" ]; } && ok "A same-tenant banking -> $RC" || bad "A same-tenant -> $RC (want 201)"
audit_has audit-onboarding-banking-demo "$RTRACE" ACCEPT ok

# B) cross-tenant write (banking token, payments body)
call B "$TOK_BANK" payments-team
[ "$RC" = "403" ] && ok "B cross-tenant -> 403 ($RREASON)" || bad "B cross-tenant -> $RC (want 403)"
[ "$RREASON" = "FORBIDDEN" ] || [ "$RREASON" = "tenant_mismatch" ] && ok "B reason=$RREASON" || bad "B reason=$RREASON"
audit_has audit-onboarding-banking-demo "$RTRACE" DENY tenant_mismatch

# C) token without the role (client_credentials)
if [ -n "$TOK_CC" ]; then
  call C "$TOK_CC" banking-demo
  { [ "$RC" = "403" ] || [ "$RC" = "401" ]; } && ok "C no-role token -> $RC ($RREASON)" || bad "C no-role -> $RC (want 403/401)"
else
  say "  (skip C: no client_credentials token)"
fi

# D) no token
call D "" banking-demo
[ "$RC" = "401" ] && ok "D no-token -> 401 ($RREASON)" || bad "D no-token -> $RC (want 401)"
audit_has audit-onboarding-unknown "$RTRACE" DENY no_token

say ""; say "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
