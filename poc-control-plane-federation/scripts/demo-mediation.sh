#!/usr/bin/env bash
# demo-mediation.sh — the COMPLETE control-plane mediation demo (ADR-072), live,
# two tenants, two planes, on a SHARED gateway fleet. It proves end-to-end that a
# developer NEVER touches the gateway directly; the control plane mediates —
# authenticates (OAuth2), authorizes scoped-to-tenant (RBAC), applies with the
# platform credential, audits every change (per-tenant OpenSearch + trace_id),
# and rate-limits — so even holding platform creds, one tenant cannot touch
# another's resources, and every change is attributable.
#
#   WRITE plane (onboarding-api):
#     - banking dev onboards (token banking)            -> 201 + audit-onboarding-banking-demo
#     - payments dev onboards (token payments)          -> 201 + audit-onboarding-payments-team
#     - cross-tenant write (banking token, payments body)-> 403
#   APPLY plane (labctl apply-uac, cp-applier tokens, platform gateway creds):
#     - CI applies banking-demo  -> accounts-read on 3 gw  + audit-apply-banking-demo
#     - CI applies payments-team -> payments-initiation on 3 gw + audit-apply-payments-team
#     - cross-tenant apply (cp-banking -> payments)     -> DENY (audited)
#   ISOLATION (OpenSearch RBAC):
#     - each tenant viewer reads ONLY its own audit indices (200 own / 403 other)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC=http://localhost:8480
OS_URL="${OPENSEARCH_URL:-https://localhost:9201}"
OS_PASS="${OPENSEARCH_PASSWORD:?Variable OPENSEARCH_PASSWORD absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
VPASS="${AUDIT_VIEWER_PASS:?Variable AUDIT_VIEWER_PASS absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
PORT="${PORT:-8790}"; API="http://localhost:${PORT}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
osq() { curl -s -k -u "admin:$OS_PASS" "$@"; }
hits(){ python3 -c 'import sys,json
try: print(json.load(sys.stdin)["hits"]["total"]["value"])
except Exception: print(0)'; }

# --- build both binaries -----------------------------------------------------
BD="$(mktemp -d)"; OAPI="$BD/onboarding-api"; LABCTL="$BD/labctl"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$OAPI" ./cmd/onboarding-api && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$LABCTL" . ) || { echo build failed; exit 1; }
chmod +x "$OAPI" "$LABCTL"

# --- governance repo: BOTH tenants, each authored by a distinct dev -----------
REPO="$(mktemp -d)/gov"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main; git -C "$REPO" config commit.gpgsign false
mkf() { mkdir -p "$(dirname "$REPO/$1")"; cat > "$REPO/$1"; }
mkf tenants/banking-demo/apis/accounts-read/api.yaml <<'Y'
name: accounts-read
version: 1.0.0
tenant_id: banking-demo
status: published
endpoints: [{path: /accounts, methods: [GET], backend_url: http://microcks:8080/rest/Accounts+Read+API/1.0.0}]
Y
echo $'version: 1.0.0\nenabled: true\npromoted_by: alice' > "$REPO/tenants/banking-demo/apis/accounts-read/deploy.dev.yaml"
mkf tenants/payments-team/apis/payments-initiation/api.yaml <<'Y'
name: payments-initiation
version: 0.3.0
tenant_id: payments-team
status: published
endpoints: [{path: /payments, methods: [POST], backend_url: http://microcks:8080/rest/payments/0.3.0}]
Y
echo $'version: 0.3.0\nenabled: true\npromoted_by: bob' > "$REPO/tenants/payments-team/apis/payments-initiation/deploy.dev.yaml"
git -C "$REPO" add tenants/banking-demo
git -C "$REPO" -c user.name="Alice Banking" -c user.email=alice@bank.example commit -q -m "feat(banking): accounts-read"
git -C "$REPO" add tenants/payments-team
git -C "$REPO" -c user.name="Bob Payments" -c user.email=bob@bank.example commit -q -m "feat(payments): payments-initiation"

# --- tokens ------------------------------------------------------------------
TBANK="$(bash "$ROOT/scripts/setup-onboarding-rbac.sh" --mint banking 2>/dev/null | tail -1)"
TPAY="$(bash "$ROOT/scripts/setup-onboarding-rbac.sh" --mint payments 2>/dev/null | tail -1)"

# --- boot onboarding-api -----------------------------------------------------
SEED="$(mktemp -d)/g"; mkdir -p "$SEED"; git -C "$SEED" init -q -b main; git -C "$SEED" config commit.gpgsign false
printf '# g\n' > "$SEED/README.md"; git -C "$SEED" add -A; git -C "$SEED" -c user.name=s -c user.email=s@s commit -q -m s
GOVERNANCE_REPO="$SEED" KEYCLOAK_URL="$KC" KEYCLOAK_REALM=stoa-lab ONBOARDING_AUDIENCE=onboarding-api \
  OPENSEARCH_URL="$OS_URL" OPENSEARCH_USER=admin OPENSEARCH_PASSWORD="$OS_PASS" OPENSEARCH_INSECURE=true \
  LISTEN=":${PORT}" "$OAPI" >/tmp/demo_oapi.log 2>&1 &
SRV=$!; trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null' EXIT
for _ in $(seq 1 50); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/healthz")" = 200 ] && break; sleep 0.2; done

onboard() { # onboard <token> <bodytenant> <name>
  curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d '{"name":"'"$3"'","tenant":"'"$2"'","clientId":"'"$3"'","apis":["accounts-read"]}' "$API/applications"
}
apply() { # apply <token> <tenant> ; echoes nothing, returns rc
  ( cd "$ROOT" && OPENSEARCH_URL="$OS_URL" OPENSEARCH_USER=admin OPENSEARCH_PASSWORD="$OS_PASS" OPENSEARCH_INSECURE=true \
    LABCTL_TOKEN="$1" "$LABCTL" apply-uac --repo "$REPO" -f targets.yaml --tenant "$2" >/dev/null 2>&1 )
}

echo "════════ WRITE plane (onboarding-api) ════════"
[ "$(onboard "$TBANK" banking-demo acme-bank)" = "201" ] && ok "banking dev onboards -> 201" || bad "banking onboard"
[ "$(onboard "$TPAY" payments-team acme-pay)" = "201" ] && ok "payments dev onboards -> 201" || bad "payments onboard"
[ "$(onboard "$TBANK" payments-team evil)" = "403" ] && ok "cross-tenant write -> 403" || bad "cross-tenant write not blocked"

echo "════════ APPLY plane (labctl, platform gateway creds, cp-applier tokens) ════════"
apply "$TBANK" banking-demo && ok "CI applies banking-demo -> exit 0" || bad "banking apply failed"
apply "$TPAY" payments-team  && ok "CI applies payments-team -> exit 0" || bad "payments apply failed"
apply "$TBANK" payments-team && bad "cross-tenant apply NOT denied" || ok "cross-tenant apply -> DENY (non-zero)"

# audit docs landed in the RIGHT per-tenant index
NB="$(osq "$OS_URL/audit-apply-banking-demo/_search?q=resource:accounts-read+AND+decision:ACCEPT" | hits)"
NP="$(osq "$OS_URL/audit-apply-payments-team/_search?q=resource:payments-initiation+AND+decision:ACCEPT" | hits)"
ND="$(osq "$OS_URL/audit-apply-banking-demo/_search?q=reason:cross_tenant+AND+decision:DENY" | hits)"
[ "${NB:-0}" -ge 1 ] && ok "banking apply audited in audit-apply-banking-demo ($NB)" || bad "no banking apply audit"
[ "${NP:-0}" -ge 1 ] && ok "payments apply audited in audit-apply-payments-team ($NP)" || bad "no payments apply audit"
[ "${ND:-0}" -ge 1 ] && ok "cross-tenant apply audited as DENY ($ND)" || bad "no cross-tenant DENY audit"

echo "════════ ISOLATION (OpenSearch per-tenant RBAC) ════════"
bb="$(curl -s -k -o /dev/null -w '%{http_code}' -u "banking-audit-viewer:$VPASS" "$OS_URL/audit-apply-banking-demo/_search")"
bp="$(curl -s -k -o /dev/null -w '%{http_code}' -u "banking-audit-viewer:$VPASS" "$OS_URL/audit-apply-payments-team/_search")"
pp="$(curl -s -k -o /dev/null -w '%{http_code}' -u "payments-audit-viewer:$VPASS" "$OS_URL/audit-apply-payments-team/_search")"
pb="$(curl -s -k -o /dev/null -w '%{http_code}' -u "payments-audit-viewer:$VPASS" "$OS_URL/audit-apply-banking-demo/_search")"
[ "$bb" = 200 ] && [ "$bp" = 403 ] && ok "banking viewer: own 200 / payments 403" || bad "banking viewer iso ($bb/$bp)"
[ "$pp" = 200 ] && [ "$pb" = 403 ] && ok "payments viewer: own 200 / banking 403" || bad "payments viewer iso ($pp/$pb)"

echo ""; echo "════════ RESULT: $PASS passed, $FAIL failed ════════"
[ "$FAIL" -eq 0 ]
