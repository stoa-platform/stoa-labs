#!/usr/bin/env bash
# test-apply-scope.sh — LIVE proof of the apply-plane tenant mediation (It.2):
# on a SHARED gateway, an apply run is BOUND to one tenant and cannot mutate
# another tenant's resources, even holding the platform gateway credential.
#
# Hermetic by design: both throwaway contracts are `published` but carry NO
# enabled deploy, so the tenant-SCOPE decision is observable in the narration
# WITHOUT any gateway dispatch (the scope gate fires before the env gate). The
# only network touch is the IdP (JWKS) when verifying a cp-applier LABCTL_TOKEN —
# the apply plane's sole control egress besides the gateways.
#
#   1. --tenant banking-demo      -> payments-team contract skipped "out of scope"
#   2. tampered tenant_id         -> load fails (anti-spoof), no dispatch
#   3. cp-applier token + foreign --tenant -> cross-tenant DENY, before dispatch
#   4. cp-applier token alone     -> scope BOUND to token tenant
#   5. no token, no --tenant      -> UNSCOPED warning
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

BIN="$(mktemp -d)/labctl"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" . ) || { echo "build failed"; exit 1; }
chmod +x "$BIN"   # the sandboxed `go build -o` can drop the exec bit

# --- two-tenant throwaway governance repo (published, NO active deploy) -------
REPO="$(mktemp -d)/gov"
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
mk tenants/payments-team/apis/payments-initiation/api.yaml <<'Y'
name: payments-initiation
version: 0.3.0
tenant_id: payments-team
status: published
endpoints:
  - path: /payments
    methods: [POST]
    backend_url: http://microcks:8080/rest/payments/0.3.0
Y

# tampered repo: a published contract under banking-demo that CLAIMS evil-corp
TREPO="$(mktemp -d)/gov"
mkdir -p "$TREPO/tenants/banking-demo/apis/accounts-read"
cat > "$TREPO/tenants/banking-demo/apis/accounts-read/api.yaml" <<'Y'
name: accounts-read
version: 1.0.0
tenant_id: evil-corp
status: published
endpoints:
  - path: /accounts
    methods: [GET]
    backend_url: http://microcks:8080/rest/Accounts+Read+API/1.0.0
Y

TOK_BANK="$(bash "$ROOT/scripts/setup-onboarding-rbac.sh" --mint banking 2>/dev/null | tail -1)"

run() { # run <ENV...> -- <args...>  -> sets OUT / RC
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  OUT="$(cd "$ROOT" && env ${envs[@]+"${envs[@]}"} "$BIN" "$@" 2>&1)"; RC=$?
}

echo "=== APPLY-PLANE TENANT MEDIATION (live) ==="

# 1) operator scope filter: payments skipped out of scope, banking in scope
run -- apply-uac --repo "$REPO" -f targets.yaml --tenant banking-demo
[ "$RC" = "0" ] && ok "1 --tenant banking-demo -> exit 0" || bad "1 exit $RC"
grep -q 'payments-team/payments-initiation skipped: out of tenant scope' <<<"$OUT" \
  && ok "1 payments-team skipped out of scope" || bad "1 payments not scope-skipped: $(grep -i payments <<<"$OUT" | head -1)"
grep -q 'banking-demo/accounts-read skipped: out of tenant scope' <<<"$OUT" \
  && bad "1 banking-demo wrongly scope-skipped" || ok "1 banking-demo IN scope (not scope-skipped)"

# 2) anti-spoof: tampered tenant_id fails the load, before any dispatch
run -- apply-uac --repo "$TREPO" -f targets.yaml --tenant banking-demo
[ "$RC" != "0" ] && ok "2 tampered tenant_id -> non-zero exit" || bad "2 tampered accepted (exit 0)"
grep -q 'does not match its path tenant' <<<"$OUT" \
  && ok "2 anti-spoof message present" || bad "2 no anti-spoof message: $OUT"

# 3) cross-tenant DENY: cp-applier(banking) cannot target payments
run "LABCTL_TOKEN=$TOK_BANK" -- apply-uac --repo "$REPO" -f targets.yaml --tenant payments-team
[ "$RC" != "0" ] && ok "3 cross-tenant -> non-zero exit (DENY)" || bad "3 cross-tenant allowed (exit 0)"
grep -qE 'cross-tenant denied.*may not apply tenant "payments-team"' <<<"$OUT" \
  && ok "3 cross-tenant DENY message" || bad "3 no DENY message: $(grep -i cross <<<"$OUT" | head -1)"

# 4) token binds scope: cp-applier(banking) with NO --tenant -> scope banking-demo
run "LABCTL_TOKEN=$TOK_BANK" -- apply-uac --repo "$REPO" -f targets.yaml
[ "$RC" = "0" ] && ok "4 token-bound run -> exit 0" || bad "4 exit $RC: $OUT"
grep -q 'principal: onboarder-banking (cp-applier, tenant banking-demo)' <<<"$OUT" \
  && ok "4 principal attributed" || bad "4 no principal line: $(grep -i principal <<<"$OUT" | head -1)"
grep -q 'payments-team/payments-initiation skipped: out of tenant scope' <<<"$OUT" \
  && ok "4 payments skipped under token scope" || bad "4 payments not skipped under token"

# 5) unscoped warning when neither token nor --tenant
run -- apply-uac --repo "$REPO" -f targets.yaml
grep -q 'UNSCOPED' <<<"$OUT" && ok "5 UNSCOPED warning emitted" || bad "5 no unscoped warning"

echo ""; echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
