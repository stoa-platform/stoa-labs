#!/usr/bin/env bash
# test-otlp-traces.sh — LIVE proof that the audit trace_id is a REAL span in
# Tempo (not just a correlation key). A scoped apply-uac runs with the OTLP
# exporter on; the same trace_id that lands in the OpenSearch audit doc is then
# queried back from Tempo (inside otel-lgtm). Stdlib OTLP/HTTP-JSON, no OTel SDK.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OTLP="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4318}"
OS_PASS="${OPENSEARCH_PASSWORD:?Variable OPENSEARCH_PASSWORD absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

BIN="$(mktemp -d)/labctl"; ( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" . ) || { echo build failed; exit 1; }
chmod +x "$BIN"
REPO="$(mktemp -d)/gov"; mkdir -p "$REPO/tenants/banking-demo/apis/accounts-read"
git -C "$REPO" init -q -b main; git -C "$REPO" config commit.gpgsign false
cat > "$REPO/tenants/banking-demo/apis/accounts-read/api.yaml" <<'Y'
name: accounts-read
version: 1.0.0
tenant_id: banking-demo
status: published
endpoints: [{path: /accounts, methods: [GET], backend_url: http://microcks:8080/rest/Accounts+Read+API/1.0.0}]
Y
printf 'version: 1.0.0\nenabled: true\npromoted_by: alice\n' > "$REPO/tenants/banking-demo/apis/accounts-read/deploy.dev.yaml"
git -C "$REPO" add -A; git -C "$REPO" -c user.name="Alice Banking" -c user.email=alice@bank.example commit -q -m feat
TOK="$(bash "$ROOT/scripts/setup-onboarding-rbac.sh" --mint banking 2>/dev/null | tail -1)"

ERR="$(mktemp)"
( cd "$ROOT" && OPENSEARCH_URL=https://localhost:9201 OPENSEARCH_USER=admin OPENSEARCH_PASSWORD="$OS_PASS" OPENSEARCH_INSECURE=true \
  OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP" LABCTL_TOKEN="$TOK" \
  "$BIN" apply-uac --repo "$REPO" -f targets.yaml --tenant banking-demo >/dev/null 2>"$ERR" )
[ "$(grep -c otlp_error "$ERR")" = "0" ] && ok "OTLP export had no errors" || bad "otlp_error in stderr"
TID="$(grep -o '"trace_id":"[a-f0-9]\{32\}"' "$ERR" | head -1 | grep -o '[a-f0-9]\{32\}')"
[ -n "$TID" ] && ok "captured trace_id $TID" || bad "no trace_id captured"

# the SAME trace_id is in the OpenSearch audit doc
NB="$(curl -s -k -u "admin:$OS_PASS" "https://localhost:9201/audit-apply-banking-demo/_search?q=trace_id:$TID" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["hits"]["total"]["value"])
except Exception: print(0)')"
[ "${NB:-0}" -ge 1 ] && ok "trace_id present in audit-apply OpenSearch doc" || bad "trace_id not in audit doc"

# and is a REAL span queryable in Tempo (inside otel-lgtm; :3200 not host-exposed)
HIT=""
for _ in $(seq 1 12); do
  R="$(docker exec poc-otel-lgtm curl -s "localhost:3200/api/traces/$TID" 2>/dev/null)"
  echo "$R" | grep -q '"spans"' && { HIT="$R"; break; }
  sleep 1
done
if [ -n "$HIT" ]; then
  NAME="$(echo "$HIT" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["batches"][0]["scopeSpans"][0]["spans"][0]["name"])' 2>/dev/null)"
  ok "Tempo returns the trace as a real span (name=$NAME)"
else
  bad "trace not found in Tempo"
fi

echo ""; echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
