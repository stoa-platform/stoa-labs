#!/usr/bin/env bash
# test-apply-audit.sh — LIVE proof of apply-plane attribution + audit (It.3):
# every gateway mutation a `labctl apply-uac` run performs lands as a per-tenant
# audit-apply-{tenant} document, Git-attributed (actor = the manifest's commit
# author, ADR-069) and carrying the cp-applier CI principal + a trace_id pivot
# (ADR-070). A cross-tenant attempt is audited as a DENY. Tenant viewers read
# ONLY their own apply-audit index.
#
# It dispatches the REAL accounts-read contract to the REAL gateways (idempotent),
# so the audit docs are produced by genuine mutations, not a simulation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS_URL="${OPENSEARCH_URL:-https://localhost:9201}"
OS_PASS="${OPENSEARCH_PASSWORD:-Stoa!Passw0rd2026}"
AUDIT_VIEWER_PASS="${AUDIT_VIEWER_PASS:-Stoa!Audit2026}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
osq() { curl -s -k -u "admin:$OS_PASS" "$@"; }

BIN="$(mktemp -d)/labctl"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" . ) || { echo "build failed"; exit 1; }
chmod +x "$BIN"

# --- real git governance repo, accounts-read authored by a named dev ---------
REPO="$(mktemp -d)/gov"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Alice Banking"; git -C "$REPO" config user.email alice@bank.example
git -C "$REPO" config commit.gpgsign false
mk() { mkdir -p "$(dirname "$REPO/$1")"; cat > "$REPO/$1"; }
mk tenants/banking-demo/apis/accounts-read/api.yaml <<'Y'
name: accounts-read
version: 1.0.0
tenant_id: banking-demo
status: published
endpoints:
  - path: /accounts
    methods: [GET]
    backend_url: http://microcks:8080/rest/Accounts+Read+API/1.0.0
Y
mk tenants/banking-demo/apis/accounts-read/deploy.dev.yaml <<'Y'
version: 1.0.0
enabled: true
promoted_by: alice
message: it3 audit proof
Y
# a second tenant contract that must be scope-skipped (never audited as a mutation)
mk tenants/payments-team/apis/payments-initiation/api.yaml <<'Y'
name: payments-initiation
version: 0.3.0
tenant_id: payments-team
status: published
Y
git -C "$REPO" add -A
git -C "$REPO" -c user.name="Alice Banking" -c user.email=alice@bank.example commit -q -m "feat(banking): accounts-read v1"
SHA_SHORT="$(git -C "$REPO" log -1 --format=%h)"

TOK="$(bash "$ROOT/scripts/setup-onboarding-rbac.sh" --mint banking 2>/dev/null | tail -1)"
[ -n "$TOK" ] || { echo "could not mint banking token"; exit 1; }

echo "=== APPLY-PLANE AUDIT (live gateways + live OpenSearch) ==="

# 1) scoped apply that REALLY mutates the gateways -> ACCEPT audit docs
ERR="$(mktemp)"
OUT="$(cd "$ROOT" && OPENSEARCH_URL="$OS_URL" OPENSEARCH_USER=admin OPENSEARCH_PASSWORD="$OS_PASS" \
  OPENSEARCH_INSECURE=true LABCTL_TOKEN="$TOK" \
  "$BIN" apply-uac --repo "$REPO" -f targets.yaml --tenant banking-demo 2>"$ERR")"
RC=$?
[ "$RC" = "0" ] && ok "1 scoped apply -> exit 0" || bad "1 apply exit $RC: $(tail -3 "$ERR")"

# fresh ACCEPT docs, Git-attributed, with the cp-applier principal
DOCS="$(osq "$OS_URL/audit-apply-banking-demo/_search?size=20" -H 'Content-Type: application/json' \
  -d '{"query":{"bool":{"must":[{"term":{"action":"api.publish"}},{"term":{"resource":"accounts-read"}},{"term":{"decision":"ACCEPT"}}]}},"sort":[{"timestamp":"desc"}]}')"
NACC="$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["hits"]["hits"]))' "$DOCS" 2>/dev/null || echo 0)"
[ "${NACC:-0}" -ge 1 ] && ok "1 $NACC ACCEPT audit-apply docs for accounts-read" || bad "1 no ACCEPT apply-audit docs"

# attribution: actor == commit author, principal == cp-applier SA, commit_sha set, gateways named
python3 - "$DOCS" "$SHA_SHORT" <<'PY'
import sys,json
docs=json.loads(sys.argv[1])["hits"]["hits"]; short=sys.argv[2]
src=[d["_source"] for d in docs]
actors={s.get("actor") for s in src}; prin={s.get("principal") for s in src}
gws={s.get("gateway") for s in src}; shas={ (s.get("commit_sha") or "")[:7] for s in src}
traces={s.get("trace_id") for s in src}
def check(cond,msg):
    print(("  \033[32mPASS\033[0m " if cond else "  \033[31mFAIL\033[0m ")+msg)
    return 0 if cond else 1
rc=0
rc+=check("Alice Banking" in actors, f"1 actor = Git commit author (got {actors})")
rc+=check("onboarder-banking" in prin, f"1 principal = cp-applier SA (got {prin})")
rc+=check(any(s for s in shas), f"1 commit_sha recorded (got {shas})")
rc+=check(short in shas, f"1 commit_sha == HEAD {short} (got {shas})")
rc+=check(len(gws)>=1 and None not in gws, f"1 gateways named: {gws}")
rc+=check(all(t for t in traces), f"1 trace_id present on every doc")
# stash one trace id for the stdout-pivot check
open("/tmp/it3_trace","w").write(next(iter(traces)) or "")
sys.exit(rc)
PY
[ $? -eq 0 ] && PASS=$((PASS+6)) || FAIL=$((FAIL+1))

# trace_id pivot: the same id appears on the stdout (OTel bridge) line
TID="$(cat /tmp/it3_trace 2>/dev/null)"
if [ -n "$TID" ] && grep -q "\"event\":\"audit.apply\"" "$ERR" && grep -q "$TID" "$ERR"; then
  ok "2 trace_id pivot: stdout audit.apply line carries the doc trace_id"
else
  bad "2 trace_id pivot missing (tid=$TID)"
fi

# payments-team contract was scope-skipped, never audited as a mutation
NPAY="$(osq "$OS_URL/audit-apply-payments-team/_search?q=resource:payments-initiation+AND+action:api.publish" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["hits"]["total"]["value"])
except Exception: print(0)')"
[ "${NPAY:-0}" = "0" ] && ok "3 out-of-scope contract NOT audited as a mutation" || bad "3 payments-initiation leaked a mutation doc"

# 4) cross-tenant attempt is audited as a DENY (under the principal tenant)
cd "$ROOT" && OPENSEARCH_URL="$OS_URL" OPENSEARCH_USER=admin OPENSEARCH_PASSWORD="$OS_PASS" \
  OPENSEARCH_INSECURE=true LABCTL_TOKEN="$TOK" \
  "$BIN" apply-uac --repo "$REPO" -f targets.yaml --tenant payments-team >/dev/null 2>&1
NDENY="$(osq "$OS_URL/audit-apply-banking-demo/_search?q=reason:cross_tenant+AND+decision:DENY" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["hits"]["total"]["value"])
except Exception: print(0)')"
[ "${NDENY:-0}" -ge 1 ] && ok "4 cross-tenant DENY audited (reason=cross_tenant)" || bad "4 no cross-tenant DENY doc"

# 5) tenant viewer isolation on the apply-audit index
C1="$(curl -s -k -o /dev/null -w '%{http_code}' -u "banking-audit-viewer:$AUDIT_VIEWER_PASS" "$OS_URL/audit-apply-banking-demo/_search")"
C2="$(curl -s -k -o /dev/null -w '%{http_code}' -u "banking-audit-viewer:$AUDIT_VIEWER_PASS" "$OS_URL/audit-apply-payments-team/_search")"
[ "$C1" = "200" ] && ok "5 banking viewer reads audit-apply-banking-demo (200)" || bad "5 banking viewer own index -> $C1"
[ "$C2" = "403" ] && ok "5 banking viewer DENIED audit-apply-payments-team (403)" || bad "5 banking viewer cross-tenant -> $C2 (want 403)"

echo ""; echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
