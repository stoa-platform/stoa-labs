#!/usr/bin/env bash
# smoke.sh — e2e du mock webMethods 10.15 avec le VRAI labctl.
#
# Le module mock ne peut pas importer l'adapter labctl (il vit sous
# labctl/internal/*, non importable hors module), donc la preuve e2e passe par
# le BINAIRE labctl + curl — exactement ce que fera le pipeline CI multi-env:
#
#   1. labctl apply      (contrat OpenAPI -> import + activate + inbound-auth)
#   2. labctl apply      (re-run: idempotent, created=false)
#   3. labctl apply-uac  (repo de gouvernance UAC -> meme moteur de dispatch)
#   4. converge multi-env ${alias}: POST alias endpoint, PUT policyAction
#      ENVELOPPE (avec read-back assert — le PUT nu est un no-op silencieux),
#      resolution data-plane par requete (dev -> rec sans reactivation).
#
# Prereqs: go, curl, python3. Aucun service externe (mock all-in-one).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PORT="${WM_MOCK_PORT:-18555}"
BASE="http://127.0.0.1:$PORT"
ADMIN="-u Administrator:manage"
TMP="$(mktemp -d)"
MOCK_PID=""

cleanup() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }

# jpath FILE PYEXPR — extrait une valeur d'un document JSON (python3 stdlib).
jpath() {
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"doc": doc}))' "$1" "$2"
}

echo "== build (mock + labctl)"
(cd "$SCRIPT_DIR" && go build -o "$TMP/webmethods-mock" .)
(cd "$REPO_ROOT/labctl" && go build -o "$TMP/labctl" .)

echo "== start mock on :$PORT"
LISTEN_ADDR=":$PORT" JWT_ISSUER="" OTEL_EXPORTER_OTLP_ENDPOINT="" \
  "$TMP/webmethods-mock" >"$TMP/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "$BASE/health" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS "$BASE/health" >/dev/null || fail "mock did not come up (see $TMP/mock.log)"
ok "mock up"

# --- fixtures: contrat OpenAPI + manifeste labctl + repo de gouvernance UAC ---
cat >"$TMP/smoke-accounts.openapi.yaml" <<'EOF'
openapi: 3.0.3
info:
  title: Smoke Accounts API
  version: 1.0.0
servers:
  - url: /smoke-accounts/v1
paths:
  /accounts:
    get:
      operationId: listAccounts
      responses:
        "200":
          description: ok
EOF

cat >"$TMP/targets.smoke.yaml" <<EOF
apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: smoke-accounts
contract: ./smoke-accounts.openapi.yaml
backendUrl: http://upstream.internal:8080/smoke
targets:
  - name: webmethods
    type: webmethods
    adminUrl: $BASE
    gatewayUrl: $BASE
    inboundAuth:
      issuer: http://localhost:8480/realms/stoa-lab
      jwksUri: http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs
      aliasName: KeycloakStoaLab
    credentials:
      username: Administrator
      password: manage
EOF

mkdir -p "$TMP/governance/tenants/banking-demo/apis/smoke-payments"
cat >"$TMP/governance/tenants/banking-demo/apis/smoke-payments/api.yaml" <<'EOF'
name: smoke-payments
version: 1.0.0
tenant_id: banking-demo
display_name: Smoke Payments
description: UAC smoke contract for the webMethods 10.15 mock
status: published
endpoints:
  - path: /payments
    methods: [GET]
    backend_url: http://upstream.internal:8080/payments
EOF
cat >"$TMP/governance/tenants/banking-demo/apis/smoke-payments/deploy.dev.yaml" <<'EOF'
version: 1.0.0
enabled: true
promoted_by: smoke
message: smoke deploy marker
EOF

echo "== labctl apply (import + activate + inbound-auth projection)"
"$TMP/labctl" apply -f "$TMP/targets.smoke.yaml" -o json >"$TMP/apply1.json" 2>"$TMP/apply1.log" \
  || fail "labctl apply failed: $(cat "$TMP/apply1.log")"
[ "$(jpath "$TMP/apply1.json" 'doc["ok"]')" = "True" ] || fail "apply report not ok"
[ "$(jpath "$TMP/apply1.json" 'doc["targets"][0]["created"]')" = "True" ] || fail "first apply should create"
ok "apply #1 created"

echo "== labctl apply (re-run, idempotent)"
"$TMP/labctl" apply -f "$TMP/targets.smoke.yaml" -o json >"$TMP/apply2.json" 2>/dev/null \
  || fail "labctl re-apply failed"
[ "$(jpath "$TMP/apply2.json" 'doc["ok"]')" = "True" ] || fail "re-apply report not ok"
[ "$(jpath "$TMP/apply2.json" 'doc["targets"][0]["created"]')" = "False" ] || fail "re-apply should converge, not create"
ok "apply #2 reused (idempotent)"

echo "== labctl apply-uac (governance repo -> same dispatch engine)"
"$TMP/labctl" apply-uac --repo "$TMP/governance" --env dev \
  -f "$TMP/targets.smoke.yaml" -o json >"$TMP/uac.json" 2>"$TMP/uac.log" \
  || fail "labctl apply-uac failed: $(cat "$TMP/uac.log")"
[ "$(jpath "$TMP/uac.json" 'doc["ok"]')" = "True" ] || fail "apply-uac report not ok"
ok "apply-uac published smoke-payments"

echo "== multi-env \${alias} routing converge (the CI demo sequence)"
# 1. Localiser l'API publiee par apply-uac, sa policy et son action de routage.
curl -fsS $ADMIN "$BASE/rest/apigateway/apis" >"$TMP/apis.json"
API_ID="$(jpath "$TMP/apis.json" '[i["api"]["id"] for i in doc["apiResponse"] if i["api"]["apiName"]=="smoke-payments"][0]')"
curl -fsS $ADMIN "$BASE/rest/apigateway/apis/$API_ID" >"$TMP/api.json"
POL_ID="$(jpath "$TMP/api.json" 'doc["apiResponse"]["api"]["policies"][0]')"
curl -fsS $ADMIN "$BASE/rest/apigateway/policies/$POL_ID" >"$TMP/policy.json"
ACT_ID="$(jpath "$TMP/policy.json" '[s for s in doc["policy"]["policyEnforcements"] if s["stageKey"]=="routing"][0]["enforcements"][0]["enforcementObjectId"]')"
ok "api=$API_ID policy=$POL_ID routing-action=$ACT_ID"

# 2. POST l'alias endpoint (body NU, casse EXACTE endPointURI).
curl -fsS $ADMIN -X POST -H 'Content-Type: application/json' \
  -d '{"name":"smoke-env-backend","type":"endpoint","endPointURI":"http://dev.payments.internal:8081/v1","optimizationTechnique":"None","passSecurityHeaders":true}' \
  "$BASE/rest/apigateway/alias" >"$TMP/alias.json"
ALIAS_ID="$(jpath "$TMP/alias.json" 'doc["alias"]["id"]')"
ok "endpoint alias $ALIAS_ID"

# 3. PUT ENVELOPPE du record relu, endpointUri seul modifie (les params
#    inconnus, p.ex. method=CUSTOM, doivent survivre) + read-back assert.
curl -fsS $ADMIN "$BASE/rest/apigateway/policyActions/$ACT_ID" >"$TMP/action.json"
python3 - "$TMP/action.json" >"$TMP/action.put.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
act = doc["policyAction"]
for p in act["parameters"]:
    if p.get("templateKey") == "endpointUri":
        p["values"] = ["${smoke-env-backend}/${sys:resource_path}"]
print(json.dumps({"policyAction": act}))
EOF
curl -fsS $ADMIN -X PUT -H 'Content-Type: application/json' \
  -d @"$TMP/action.put.json" "$BASE/rest/apigateway/policyActions/$ACT_ID" >/dev/null
curl -fsS $ADMIN "$BASE/rest/apigateway/policyActions/$ACT_ID" >"$TMP/action.after.json"
URI="$(jpath "$TMP/action.after.json" '[p for p in doc["policyAction"]["parameters"] if p["templateKey"]=="endpointUri"][0]["values"][0]')"
[ "$URI" = '${smoke-env-backend}/${sys:resource_path}' ] || fail "routing PUT did not stick (read-back: $URI)"
ok "routing re-pointed at \${smoke-env-backend} (read-back asserted)"

# 4. Resolution data-plane PAR REQUETE: dev, puis bascule rec via UN PUT alias.
curl -fsS "$BASE/gateway/smoke-payments/1.0.0/payments" >"$TMP/dp-dev.json"
RES="$(jpath "$TMP/dp-dev.json" 'doc["resolved_url"]')"
[ "$RES" = "http://dev.payments.internal:8081/v1/payments" ] || fail "dev resolve: $RES"
[ "$(jpath "$TMP/dp-dev.json" 'doc["alias_resolved"]')" = "True" ] || fail "alias not resolved"
ok "data-plane resolves dev: $RES"

curl -fsS $ADMIN -X PUT -H 'Content-Type: application/json' \
  -d '{"name":"smoke-env-backend","type":"endpoint","endPointURI":"http://rec.payments.internal:8082/v1","optimizationTechnique":"None","passSecurityHeaders":true}' \
  "$BASE/rest/apigateway/alias/$ALIAS_ID" >/dev/null
curl -fsS "$BASE/gateway/smoke-payments/1.0.0/payments" >"$TMP/dp-rec.json"
RES="$(jpath "$TMP/dp-rec.json" 'doc["resolved_url"]')"
[ "$RES" = "http://rec.payments.internal:8082/v1/payments" ] || fail "rec resolve: $RES"
ok "one alias PUT re-routed dev -> rec (no reactivation): $RES"

# 5. Allowlist: hors contrat -> 404.
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/gateway/smoke-payments/1.0.0/not-in-contract")"
[ "$CODE" = "404" ] || fail "out-of-contract returned $CODE, want 404"
ok "out-of-contract resource is 404 (allowlist)"

echo
echo "SMOKE OK — apply + apply-uac + multi-env \${alias} routing all green against the mock."
