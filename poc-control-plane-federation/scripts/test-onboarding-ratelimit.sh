#!/usr/bin/env bash
# test-onboarding-ratelimit.sh — LIVE proof of the management-plane rate limit
# (It.4): the SHARED onboarding-api throttles per authenticated principal
# (actor+tenant), so one tenant's developer cannot flood it. Over the limit ->
# HTTP 429 + an audited DENY (reason=rate_limited); under it -> 201.
#
# Boots the real binary with ONBOARDING_RATE_PER_MIN=3 against a throwaway repo
# + live Keycloak (real token) + live OpenSearch, then bursts 5 requests.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC_BASE="${KC_BASE:-http://localhost:8480}"
OS_URL="${OPENSEARCH_URL:-https://localhost:9201}"
OS_PASS="${OPENSEARCH_PASSWORD:-Stoa!Passw0rd2026}"
PORT="${PORT:-8789}"
API="http://localhost:${PORT}"
LIMIT=3
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

REPO="$(mktemp -d)/gov"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name seed; git -C "$REPO" config user.email seed@test.local
git -C "$REPO" config commit.gpgsign false
printf '# gov\n' > "$REPO/README.md"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m seed

BIN="$(mktemp -d)/onboarding-api"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" ./cmd/onboarding-api ) || { echo build failed; exit 1; }
chmod +x "$BIN"

GOVERNANCE_REPO="$REPO" KEYCLOAK_URL="$KC_BASE" KEYCLOAK_REALM=stoa-lab ONBOARDING_AUDIENCE=onboarding-api \
  OPENSEARCH_URL="$OS_URL" OPENSEARCH_USER=admin OPENSEARCH_PASSWORD="$OS_PASS" OPENSEARCH_INSECURE=true \
  ONBOARDING_RATE_PER_MIN="$LIMIT" LISTEN=":${PORT}" "$BIN" >/tmp/obrl.log 2>&1 &
SRV=$!; trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null' EXIT
for _ in $(seq 1 50); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/healthz")" = 200 ] && break; sleep 0.2; done

TOK="$(bash "$ROOT/scripts/setup-onboarding-rbac.sh" --mint banking 2>/dev/null | tail -1)"

post() { # post <n> -> RC / RTRACE
  local n="$1" hdr; hdr="$(mktemp)"
  RC="$(curl -s -o /dev/null -D "$hdr" -w '%{http_code}' \
    -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
    -d '{"name":"rl-'"$n"'","tenant":"banking-demo","clientId":"rl-'"$n"'","apis":["accounts-read"]}' \
    "$API/applications")"
  RTRACE="$(grep -i '^X-Trace-Id:' "$hdr" | tr -d '\r' | awk '{print $2}')"; rm -f "$hdr"
}

echo "=== MANAGEMENT-PLANE RATE LIMIT (live, limit=${LIMIT}/min) ==="
created=0; limited=0; deny_trace=""
for i in 1 2 3 4 5; do
  post "$i"
  if [ "$RC" = "201" ] || [ "$RC" = "200" ]; then created=$((created+1)); fi
  if [ "$RC" = "429" ]; then limited=$((limited+1)); deny_trace="$RTRACE"; fi
  echo "  req $i -> $RC"
done

[ "$created" = "$LIMIT" ] && ok "first $LIMIT requests admitted (201/200)" || bad "admitted=$created, want $LIMIT"
[ "$limited" -ge 1 ] && ok "burst over limit -> 429 ($limited refused)" || bad "no 429 returned"

# the 429 is audited as a DENY reason=rate_limited (per-tenant index)
if [ -n "$deny_trace" ]; then
  n="$(curl -s -k -u "admin:$OS_PASS" "$OS_URL/audit-onboarding-banking-demo/_search?q=trace_id:$deny_trace+AND+reason:rate_limited+AND+decision:DENY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["hits"]["total"]["value"])
except Exception: print(0)')"
  [ "${n:-0}" -ge 1 ] && ok "429 audited as DENY reason=rate_limited (trace $deny_trace)" || bad "no rate_limited audit doc"
else
  bad "no trace id captured from a 429 response"
fi

echo ""; echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
