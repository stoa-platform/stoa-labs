#!/usr/bin/env bash
# test-integrity-enforce.sh — PREUVE LIVE du gate « sécurité = f(intégrité) »
# (ADR-076 Phase 3, goal A1) contre le webMethods RÉEL (apigateway-trial:10.15).
#
# Ce que ce script prouve, avec contre-épreuves :
#   1. VH sans jambe mTLS dans le manifeste  -> apply REFUSÉ [INTEGRITY_UNFULFILLED],
#      RIEN n'est écrit (l'API n'existe pas sur la gateway après le refus).
#   2. VH conforme -> apply OK ; verdicts read-back: oauth2/mtls/rate-limit/audit-log
#      = enforced (audience annotée 3/4 sur le trial), ip-allowlist = degraded ;
#      le JSON porte le bloc enforcement (contrat CI additif).
#   3. Re-apply idempotent -> OK (le gate relit, ne re-écrit pas).
#   4. CONTRE-ÉPREUVE READ-BACK : sabotage hors-bande de l'action IAM AND partagée
#      (allowAnonymous -> "true", PUT ENVELOPPÉ + assert-stuck) — un drift que le
#      projecteur ne corrige JAMAIS (l'action AND est réutilisée telle quelle,
#      mtls.go) -> re-apply REFUSÉ [ENFORCEMENT_UNCONFIRMED] ; restore assert-stuck
#      -> re-apply OK.
#      ⚠ L'action AND est PARTAGÉE entre les APIs VH (accounts-read incluse) : le
#      sabotage dure le temps d'un apply live et le restore est PROUVÉ par
#      read-back. Un `trap EXIT/INT/TERM` posé AVANT le sabotage garantit le
#      restore même sur Ctrl-C/crash ; un restore raté fait échouer le script
#      (exit 1) avec un message CRITIQUE.
#   5. H sans inboundAuth -> [INTEGRITY_UNFULFILLED] (pré-check).
#   6. VH sur un target apisix -> [INTEGRITY_UNFULFILLED] (mtls/rate-limit non
#      projetables sur apisix en A1 — fail-closed honnête, goal A3/B1).
#   7. M + auth-exception:apikey + exposure external -> [INTEGRITY_INCONSISTENT]
#      (bundle non dérivable, même code que le gate validate).
#
# Env : WM_ADMIN_URL (def http://localhost:5555), WM_ADMIN_USER/PASSWORD
# (def Administrator/manage). Aucune dépendance Vault (creds littéraux PoC).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WM="${WM_ADMIN_URL:-http://localhost:5555}"
WMU="${WM_ADMIN_USER:-Administrator}"
WMP="${WM_ADMIN_PASSWORD:-manage}"
API_NAME="integrity-enforce-check"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

wm() { curl -s -u "$WMU:$WMP" -H 'Accept: application/json' "$@"; }

echo "=== 0. Prérequis (live) ==="
# NB: /health renvoie du HTML sur ce build trial — la sonde de vie est /apis (200).
if [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 -u "$WMU:$WMP" "$WM/rest/apigateway/apis")" != "200" ]; then
  echo "webMethods réel injoignable sur $WM — ./scripts/up.sh d'abord"; exit 2
fi
ok "gateway joignable ($WM)"

BIN="$(mktemp -d)/labctl"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" . ) || { echo "build failed"; exit 1; }
chmod +x "$BIN"
ok "labctl build (vendored, hermétique)"

# --- Workspace : contrat + manifestes ---------------------------------------
WS="$(mktemp -d)"
cat > "$WS/openapi.yaml" <<EOF
openapi: 3.0.3
info:
  title: Integrity Enforce Check
  version: 1.0.0
servers:
  - url: /$API_NAME/v1
paths:
  /ping:
    get:
      operationId: ping
      responses:
        "200":
          description: ok
EOF

uac() { # $1=classification $2=exposure [$3=tag]
  { echo "name: $API_NAME"
    echo "version: 1.0.0"
    echo "tenant_id: banking-demo"
    echo "classification: $1"
    [ -n "$2" ] && echo "exposure: $2"
    [ -n "${3:-}" ] && printf 'tags:\n  - %s\n' "$3"
    echo "status: draft"; } > "$WS/api.yaml"
}

manifest_vh_full() {
  cat > "$WS/target.yaml" <<EOF
apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: $API_NAME
contract: ./openapi.yaml
backendUrl: http://microcks:8080/rest/Accounts+Read+API/1.0.0
targets:
  - name: webmethods
    type: webmethods
    adminUrl: $WM
    gatewayUrl: $WM
    inboundAuth:
      issuer: http://localhost:8480/realms/stoa-lab
      jwksUri: http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs
      aliasName: KeycloakStoaLab
      audience: accounts-read
      scope: accounts.read
      clientId: accounts-read-consumer
      mtls: true
    rateLimit:
      requests: 1000
      interval: 1
      unit: minutes
    transportProtocol: https
    credentials:
      username: $WMU
      password: $WMP
EOF
}

manifest_vh_sans_mtls() {
  manifest_vh_full
  # Retire la jambe mTLS + le transport https : le pré-check doit refuser.
  python3 - "$WS/target.yaml" <<'PY'
import sys
p = sys.argv[1]
out = []
for line in open(p):
    if line.strip() == "mtls: true": continue
    if line.strip() == 'transportProtocol: https': continue
    out.append(line)
open(p, "w").writelines(out)
PY
}

manifest_h_sans_auth() {
  cat > "$WS/target.yaml" <<EOF
apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: $API_NAME
contract: ./openapi.yaml
backendUrl: http://microcks:8080/rest/Accounts+Read+API/1.0.0
targets:
  - name: webmethods
    type: webmethods
    adminUrl: $WM
    gatewayUrl: $WM
    rateLimit: {requests: 1000}
    credentials:
      username: $WMU
      password: $WMP
EOF
}

manifest_vh_apisix() {
  cat > "$WS/target.yaml" <<EOF
apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: $API_NAME
contract: ./openapi.yaml
backendUrl: http://microcks:8080/rest/Accounts+Read+API/1.0.0
targets:
  - name: apisix
    type: apisix
    adminUrl: http://localhost:9180
    gatewayUrl: http://localhost:9080
    inboundAuth:
      discoveryUrl: http://keycloak:8080/realms/stoa-lab/.well-known/openid-configuration
    credentials:
      adminKey: unused
EOF
}

applies() { ( cd "$WS" && VAULT_ADDR= "$BIN" apply -f target.yaml 2>&1 ); }
applies_json() { ( cd "$WS" && VAULT_ADDR= "$BIN" apply -f target.yaml -o json 2>/dev/null ); }

api_exists() {
  wm "$WM/rest/apigateway/apis" | python3 -c "
import json,sys
doc=json.load(sys.stdin)
items=[i.get('api',i) for i in doc.get('apiResponse',[])]
print(sum(1 for a in items if a.get('apiName')=='$API_NAME'))"
}

echo ""
echo "=== 1. VH sans jambe mTLS -> [INTEGRITY_UNFULFILLED], RIEN n'est écrit ==="
uac VH external
manifest_vh_sans_mtls
BEFORE_COUNT="$(api_exists)"
OUT="$(applies)"; RC=$?
[ "$RC" != "0" ] && ok "apply refusé (rc=$RC)" || bad "apply a réussi alors que le manifeste n'implémente pas le bundle VH"
grep -q "INTEGRITY_UNFULFILLED" <<<"$OUT" && ok "code [INTEGRITY_UNFULFILLED] présent" || bad "code INTEGRITY_UNFULFILLED absent: $OUT"
grep -q "mtls" <<<"$OUT" && ok "la violation nomme la jambe mtls" || bad "violation mtls absente du rapport"
AFTER_COUNT="$(api_exists)"
[ "$BEFORE_COUNT" = "$AFTER_COUNT" ] && ok "rien n'a été écrit (API $API_NAME: $BEFORE_COUNT avant / $AFTER_COUNT après)" || bad "des écritures ont eu lieu malgré le refus pré-check"

echo ""
echo "=== 2. VH conforme -> apply OK + verdicts read-back (jamais l'intention) ==="
uac VH external
manifest_vh_full
OUT="$(applies)"; RC=$?
[ "$RC" = "0" ] && ok "apply VH conforme (rc=0)" || { bad "apply VH conforme a échoué: $OUT"; }
grep -q "Enforcement (read-back" <<<"$OUT" && ok "table de verdicts présente" || bad "table de verdicts absente"
for leg in "oauth2.*enforced" "mtls.*enforced" "rate-limit.*enforced" "audit-log.*enforced" "ip-allowlist.*degraded"; do
  grep -Eq "$leg" <<<"$OUT" && ok "verdict: $leg" || bad "verdict manquant: $leg ($OUT)"
done
grep -q "3/4" <<<"$OUT" && ok "audience annotée fail-open trial (3/4 barrières) — jamais surclamée" || bad "annotation 3/4 absente"
JSON="$(applies_json)"; RC=$?
[ "$RC" = "0" ] && ok "apply -o json (rc=0)" || bad "apply json a échoué"
python3 - <<PY && ok "bloc enforcement additif dans le JSON (contrat CI intact: ok/created/api_id)" || bad "bloc enforcement absent/invalide du JSON"
import json,sys
rep=json.loads('''$JSON''')
assert rep["ok"] is True
t=rep["targets"][0]
assert t["api_id"], "api_id manquant"
assert "created" in t
enf={v["policy"]: v["status"] for v in t.get("enforcement",[])}
assert enf.get("oauth2")=="enforced", enf
assert enf.get("mtls")=="enforced", enf
assert enf.get("ip-allowlist")=="degraded", enf
PY

echo ""
echo "=== 3. Re-apply idempotent (le gate relit, ne re-écrit pas) ==="
OUT="$(applies)"; RC=$?
[ "$RC" = "0" ] && ok "re-apply idempotent (rc=0)" || bad "re-apply a échoué: $OUT"

echo ""
echo "=== 4. CONTRE-ÉPREUVE — sabotage hors-bande, le read-back attrape ce que le projecteur ne corrige pas ==="
# L'action IAM AND (oAuth2Token + httpsCertificate) est trouvée par empreinte et
# RÉUTILISÉE TELLE QUELLE par le projecteur (jamais convergée) : un drift
# allowAnonymous n'est corrigé par AUCUN re-apply — seul le gate A1 le voit.
ACTION_JSON="$(wm "$WM/rest/apigateway/policyActions" | python3 -c "
import json,sys
doc=json.load(sys.stdin)
acts=doc.get('policyAction',[])
def rules(a):
    out=[]
    for p in a.get('parameters',[]):
        if p.get('templateKey')=='IdentificationRule':
            for n in p.get('parameters',[]):
                if n.get('templateKey')=='identificationType': out += n.get('values',[])
    return out
for a in acts:
    if a.get('templateKey')=='evaluatePolicy' and 'httpsCertificate' in rules(a):
        print(json.dumps(a)); break
")"
if [ -z "$ACTION_JSON" ]; then bad "action IAM AND introuvable (impossible de jouer la contre-épreuve)"; else
  ACTION_ID="$(python3 -c "import json;print(json.loads('''$ACTION_JSON''')['id'])")"
  ok "action IAM AND partagée localisée ($ACTION_ID) — record original sauvegardé"

  # TRAP DE RESTORE (posé AVANT le sabotage) : l'action est PARTAGÉE — un Ctrl-C,
  # un crash ou un apply qui pend entre sabotage et restore ne doit JAMAIS la
  # laisser affaiblie. Best-effort + read-back ; désarmé après le restore nominal.
  restore_and_check() {
    curl -s -o /dev/null -u "$WMU:$WMP" -H 'Content-Type: application/json' \
      -X PUT "$WM/rest/apigateway/policyActions/$ACTION_ID" -d "{\"policyAction\":$ACTION_JSON}" || true
    wm "$WM/rest/apigateway/policyActions/$ACTION_ID" | grep -q '"allowAnonymous"' || true
  }
  trap 'echo "  [trap] restore de l action IAM AND partagée…"; restore_and_check' EXIT INT TERM

  SABOTAGED="$(python3 -c "
import json
a=json.loads('''$ACTION_JSON''')
for p in a.get('parameters',[]):
    if p.get('templateKey')=='allowAnonymous': p['values']=['true']
print(json.dumps({'policyAction':a}))")"
  CODE="$(curl -s -o /tmp/sab.out -w '%{http_code}' -u "$WMU:$WMP" -H 'Content-Type: application/json' \
    -X PUT "$WM/rest/apigateway/policyActions/$ACTION_ID" -d "$SABOTAGED")"
  # assert-stuck APRÈS sabotage (PUT nu = 200 no-op silencieux : on VÉRIFIE)
  STUCK="$(wm "$WM/rest/apigateway/policyActions/$ACTION_ID" | python3 -c "
import json,sys
doc=json.load(sys.stdin); a=doc.get('policyAction',doc)
print([p.get('values') for p in a.get('parameters',[]) if p.get('templateKey')=='allowAnonymous'])")"
  if [ "$CODE" = "200" ] && grep -q "true" <<<"$STUCK"; then
    ok "sabotage posé et PROUVÉ par read-back (allowAnonymous=true, HTTP $CODE)"

    OUT="$(applies)"; RC=$?
    [ "$RC" != "0" ] && ok "re-apply REFUSÉ sur l'état saboté (rc=$RC)" || bad "re-apply a validé un état saboté (faux négatif du gate !)"
    grep -q "ENFORCEMENT_UNCONFIRMED" <<<"$OUT" && ok "code [ENFORCEMENT_UNCONFIRMED] présent" || bad "code ENFORCEMENT_UNCONFIRMED absent: $OUT"
    grep -Eq "mtls.*missing" <<<"$OUT" && ok "le verdict nomme la jambe mtls tombée" || bad "verdict mtls=missing absent"
  else
    bad "sabotage non posé (HTTP $CODE, allowAnonymous relu: $STUCK) — contre-épreuve non jouée"
  fi

  # RESTORE (enveloppé) + assert-stuck : un restore raté laisserait l'action
  # PARTAGÉE affaiblie en permanence -> échec CRITIQUE du script.
  CODE="$(curl -s -o /tmp/rst.out -w '%{http_code}' -u "$WMU:$WMP" -H 'Content-Type: application/json' \
    -X PUT "$WM/rest/apigateway/policyActions/$ACTION_ID" -d "{\"policyAction\":$ACTION_JSON}")"
  RESTORED="$(wm "$WM/rest/apigateway/policyActions/$ACTION_ID" | python3 -c "
import json,sys
doc=json.load(sys.stdin); a=doc.get('policyAction',doc)
print([p.get('values') for p in a.get('parameters',[]) if p.get('templateKey')=='allowAnonymous'])")"
  if [ "$CODE" = "200" ] && grep -q "false" <<<"$RESTORED"; then
    ok "restore PROUVÉ par read-back (allowAnonymous=false)"
    trap - EXIT INT TERM   # restore nominal confirmé → trap désarmé
  else
    bad "CRITIQUE: restore non confirmé (HTTP $CODE, relu: $RESTORED) — l'action IAM AND partagée est peut-être affaiblie, REMÉDIER MANUELLEMENT (le trap retentera à l'exit)"
  fi
  OUT="$(applies)"; RC=$?
  [ "$RC" = "0" ] && ok "re-apply post-restore reconfirme le bundle (rc=0)" || bad "re-apply post-restore échoue encore: $OUT"
fi

echo ""
echo "=== 5. H sans inboundAuth -> [INTEGRITY_UNFULFILLED] (pré-check oauth2) ==="
uac H ""
manifest_h_sans_auth
OUT="$(applies)"; RC=$?
[ "$RC" != "0" ] && ok "apply refusé (rc=$RC)" || bad "H sans OAuth2 a été accepté"
grep -q "INTEGRITY_UNFULFILLED" <<<"$OUT" && ok "code présent" || bad "code absent: $OUT"
grep -q "oauth2" <<<"$OUT" && ok "la violation nomme oauth2" || bad "violation oauth2 absente"

echo ""
echo "=== 6. VH sur apisix -> [INTEGRITY_UNFULFILLED] (fail-closed honnête, A3/B1) ==="
uac VH external
manifest_vh_apisix
OUT="$(applies)"; RC=$?
[ "$RC" != "0" ] && ok "apply refusé (rc=$RC)" || bad "VH sur apisix accepté alors que mtls/rate-limit n'y sont pas projetables"
grep -q "INTEGRITY_UNFULFILLED" <<<"$OUT" && ok "code présent" || bad "code absent: $OUT"

echo ""
echo "=== 7. M + auth-exception:apikey + external -> [INTEGRITY_INCONSISTENT] ==="
uac M external auth-exception:apikey
manifest_vh_full
OUT="$(applies)"; RC=$?
[ "$RC" != "0" ] && ok "apply refusé (rc=$RC)" || bad "bundle non dérivable accepté"
grep -q "INTEGRITY_INCONSISTENT" <<<"$OUT" && ok "code [INTEGRITY_INCONSISTENT] (même code que le gate validate)" || bad "code absent: $OUT"

echo ""
echo "=== Cleanup (best-effort) : API + strategy de test ==="
API_ID="$(wm "$WM/rest/apigateway/apis" | python3 -c "
import json,sys
doc=json.load(sys.stdin)
items=[i.get('api',i) for i in doc.get('apiResponse',[])]
ids=[a['id'] for a in items if a.get('apiName')=='$API_NAME']
print(ids[0] if ids else '')")"
if [ -n "$API_ID" ]; then
  wm -X PUT "$WM/rest/apigateway/apis/$API_ID/deactivate" >/dev/null 2>&1
  wm -X DELETE "$WM/rest/apigateway/apis/$API_ID" >/dev/null 2>&1
  echo "  API $API_NAME ($API_ID) supprimée (best-effort)"
fi
STRAT_ID="$(wm "$WM/rest/apigateway/strategies" | python3 -c "
import json,sys
doc=json.load(sys.stdin)
items=doc if isinstance(doc,list) else doc.get('strategies',[])
ids=[s['id'] for s in items if s.get('name')=='OIDC-$API_NAME']
print(ids[0] if ids else '')")"
[ -n "$STRAT_ID" ] && { wm -X DELETE "$WM/rest/apigateway/strategies/$STRAT_ID" >/dev/null 2>&1; echo "  strategy OIDC-$API_NAME supprimée (best-effort)"; }
rm -rf "$WS"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
