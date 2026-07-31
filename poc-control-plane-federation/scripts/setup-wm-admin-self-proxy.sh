#!/usr/bin/env bash
# setup-wm-admin-self-proxy.sh — SELF-PROXY OAuth2 de l'API d'admin (modèle CLIENT).
#
# Chez le client, les outils (Jenkins/Ansible) n'attaquent pas l'API d'admin de la
# gateway en direct : elle est PROXIFIÉE SUR LA GATEWAY ELLE-MÊME avec OAuth2
# devant. Ce script reproduit le montage au lab et le PROUVE :
#
#   1. Keycloak : client scope `admin:self` créé et attaché en DEFAULT scope du
#      client ci-horsprod (client_credentials — aucun humain là-dedans : c'est le
#      credential OAuth2 DU PIPELINE, pas l'identité nominative Vault)
#   2. labctl apply de gateways/webmethods/admin-proxy/targets.wm-admin-self.yaml :
#      API sœur wm-admin-self v1.0, routée vers la gateway ELLE-MÊME (localhost
#      dans le conteneur), Basic sortant via credential alias (valeurs Vault),
#      OAuth2 entrant (JWT Keycloak, scope admin:self)
#   3. binding application ci-horsprod (azp + authStrategyIds) sur TOUTES les
#      wm-admin-* — converge le set complet, idempotent
#   4. seed Vault TENANT-scopé secret/stoa/deploy/banking-demo/admin-oauth
#      ({token_url, client_id, client_secret, scope}) : c'est LE secret que le
#      rôle Ansible lit en mode oauth2 — sous le périmètre du token nominatif
#      (policy deploy-banking-demo), PAS sous gateways/* (hors périmètre)
#   5. matrice de preuve : sans token 401 · token sans scope ≠200 · token
#      ci-horsprod 200 (health + GET /apis) · /users 404 · DELETE 405
#
# Ensuite, côté pipeline : lancer selfservice/publish avec ADMIN_VIA=proxy-oauth2
# → le rôle obtient un Bearer (client_credentials) et passe par le proxy.
#
# Prereqs : setup-vault.sh + setup-vault-approle.sh + setup-ci-horsprod.sh joués.
set -uo pipefail
cd "$(dirname "$0")/.."

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
VAULT_ADMIN_TOKEN="${VAULT_TOKEN:?Variable VAULT_TOKEN absente — définissez-la (voir poc-control-plane-federation/.env.example)}"   # seed KV + lecture stoa/ci (bootstrap, PoC)
KC_BASE="${KC_BASE:-http://localhost:8480}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"; KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"
WM="${WM_GATEWAY_URL:-http://localhost:5555}"
TENANT="${TENANT:-banking-demo}"
SELF_SCOPE="admin:self"
MANIFEST_DIR="gateways/webmethods/admin-proxy"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

echo "═══ 0/5 Build labctl + login AppRole proxy-provision"
BIN="$(mktemp -d)/labctl"
( cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" . ) || { echo "✗ build labctl"; exit 1; }
VTOKFILE="$(mktemp)"; TMPD="$(mktemp -d)"
trap 'rm -rf "$VTOKFILE" "$TMPD"' EXIT
chmod 0600 "$VTOKFILE"; chmod 0700 "$TMPD"
if [ -z "${VAULT_ROLE_ID:-}" ] || [ -z "${VAULT_SECRET_ID:-}" ]; then
  IFS=$'\t' read -r VAULT_ROLE_ID VAULT_SECRET_ID < <(bash scripts/setup-vault-approle.sh --mint proxy-provision) \
    || { echo "✗ mint proxy-provision"; exit 1; }
fi
VTOK="$(curl -sf -X POST "$VAULT_ADDR/v1/auth/approle/login" \
  -d "{\"role_id\":\"$VAULT_ROLE_ID\",\"secret_id\":\"$VAULT_SECRET_ID\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')"
[ -n "$VTOK" ] || { echo "✗ vault approle login failed"; exit 1; }
printf %s "$VTOK" > "$VTOKFILE"
echo "  ✓ token éphémère proxy-provision"

echo "═══ 1/5 Keycloak : client scope $SELF_SCOPE en DEFAULT scope de ci-horsprod"
AT=$(curl -sf "$KC_BASE/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d grant_type=password -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASSWORD" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
API="$KC_BASE/admin/realms/stoa-lab"
kc() { curl -s -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' "$@"; }
SCID="$(kc "$API/client-scopes" | python3 -c "
import sys,json
print(next((s['id'] for s in json.load(sys.stdin) if s['name']=='$SELF_SCOPE'),''))")"
if [ -z "$SCID" ]; then
  # include.in.token.scope=true : le claim `scope` du jeton DOIT porter admin:self —
  # c'est ce que la scope-barrière du proxy vérifie.
  kc -X POST "$API/client-scopes" -d "{\"name\":\"$SELF_SCOPE\",\"protocol\":\"openid-connect\",
    \"attributes\":{\"include.in.token.scope\":\"true\",\"display.on.consent.screen\":\"false\"}}" -o /dev/null
  SCID="$(kc "$API/client-scopes" | python3 -c "
import sys,json
print(next((s['id'] for s in json.load(sys.stdin) if s['name']=='$SELF_SCOPE'),''))")"
fi
[ -n "$SCID" ] || { echo "✗ client scope $SELF_SCOPE incréable"; exit 1; }
CID="$(kc "$API/clients?clientId=ci-horsprod" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")')"
[ -n "$CID" ] || { echo "✗ client ci-horsprod introuvable (setup-ci-horsprod.sh ?)"; exit 1; }
RC=$(kc -X PUT "$API/clients/$CID/default-client-scopes/$SCID" -o /dev/null -w '%{http_code}')
case "$RC" in 200|204) echo "  ✓ $SELF_SCOPE attaché (DEFAULT) à ci-horsprod";;
              *) echo "✗ attache scope KO (HTTP $RC)"; exit 1;; esac

echo "═══ 2/5 Apply du self-proxy (manifest temporaire 0600, creds depuis Vault)"
WMU="$(curl -sf -H "X-Vault-Token: $VTOK" "$VAULT_ADDR/v1/secret/data/stoa/gateways/webmethods" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['data']['username'])")"
WMP="$(curl -sf -H "X-Vault-Token: $VTOK" "$VAULT_ADDR/v1/secret/data/stoa/gateways/webmethods" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['data']['password'])")"
[ -n "$WMU" ] && [ -n "$WMP" ] || { echo "✗ creds gateways/webmethods illisibles"; exit 1; }
cp "$MANIFEST_DIR/wm-admin-proxy.openapi.yaml" "$TMPD/"
( umask 077
  sed -e "s|backendUsername: __FROM_VAULT__|backendUsername: $WMU|" \
      -e "s|backendPassword: __FROM_VAULT__|backendPassword: $WMP|" \
      "$MANIFEST_DIR/targets.wm-admin-self.yaml" > "$TMPD/targets.wm-admin-self.yaml" )
if VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VTOKFILE" "$BIN" apply -f "$TMPD/targets.wm-admin-self.yaml"; then
  echo "  ✓ wm-admin-self appliqué (self-referencing, OAuth2 entrant, Basic sortant par alias)"
else
  echo "  ✗ apply wm-admin-self KO"; exit 1
fi

echo "═══ 3/5 Binding application ci-horsprod (azp + stratégies) sur TOUTES les wm-admin-*"
ADMIN=(-u "$WMU:$WMP" -H 'Accept: application/json')
APP_ID="$(curl -sf "${ADMIN[@]}" "$WM/rest/apigateway/applications" | python3 -c "
import sys,json
for a in json.load(sys.stdin).get('applications',[]):
    if a.get('name')=='ci-horsprod': print(a['id']); break")"
[ -n "$APP_ID" ] || { echo "✗ application ci-horsprod absente (setup-wm-admin-proxy.sh d'abord)"; exit 1; }
API_IDS="$(curl -sf "${ADMIN[@]}" "$WM/rest/apigateway/apis" | python3 -c "
import sys,json
ids=[]
for it in json.load(sys.stdin).get('apiResponse',[]):
    a=it.get('api',it)
    if a.get('apiName','').startswith('wm-admin-'): ids.append(a['id'])
print(json.dumps(ids))")"
STRAT_IDS="$(curl -sf "${ADMIN[@]}" "$WM/rest/apigateway/strategies" | python3 -c "
import sys,json
d=json.load(sys.stdin)
lst=d if isinstance(d,list) else d.get('strategies',d.get('strategy',[]))
print(json.dumps([s['id'] for s in lst if s.get('name','').startswith('OIDC-wm-admin-')]))")"
curl -sf "${ADMIN[@]}" -X PUT "$WM/rest/apigateway/applications/$APP_ID/apis" \
  -H 'Content-Type: application/json' -d "{\"apiIDs\":$API_IDS}" -o /dev/null \
  && echo "  ✓ application associée à $(python3 -c "import json;print(len(json.loads('$API_IDS')))") APIs wm-admin-*" \
  || { echo "  ✗ association APIs"; FAIL=$((FAIL+1)); }
curl -sf "${ADMIN[@]}" "$WM/rest/apigateway/applications/$APP_ID" | python3 -c "
import sys,json
d=json.load(sys.stdin)
app=(d.get('applications') or [d])[0] if isinstance(d,dict) else d
app['identifiers']=[{'key':'openIdClaims','name':'azp','value':['ci-horsprod']}]
app['authStrategyIds']=json.loads('$STRAT_IDS')
print(json.dumps(app))" > "$TMPD/app.json"
curl -sf "${ADMIN[@]}" -X PUT "$WM/rest/apigateway/applications/$APP_ID" \
  -H 'Content-Type: application/json' --data-binary @"$TMPD/app.json" -o /dev/null \
  && echo "  ✓ identifier azp + $(python3 -c "import json;print(len(json.loads('$STRAT_IDS')))") stratégies (dont OIDC-wm-admin-self)" \
  || { echo "  ✗ binding OAuth2 application"; FAIL=$((FAIL+1)); }
unset WMU WMP

echo "═══ 4/5 Seed Vault TENANT-scopé : deploy/$TENANT/admin-oauth (lu par le rôle en mode oauth2)"
CHS="$(curl -sf -H "X-Vault-Token: $VAULT_ADMIN_TOKEN" "$VAULT_ADDR/v1/secret/data/stoa/ci" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['data'].get('ciHorsprodSecret',''))")"
[ -n "$CHS" ] || { echo "✗ ciHorsprodSecret absent de stoa/ci (setup-vault.sh ?)"; exit 1; }
python3 - "$CHS" > "$TMPD/oauth.json" <<'PY'
import json, sys
json.dump({"data": {
  # token_url VU DEPUIS L'AGENT Jenkins (réseau compose) — même split-horizon
  # que le reste du lab.
  "token_url": "http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/token",
  "client_id": "ci-horsprod",
  "client_secret": sys.argv[1],
  # scope vide : admin:self est un DEFAULT scope du client — présent d'office.
  "scope": ""
}}, sys.stdout)
PY
RC=$(curl -s -H "X-Vault-Token: $VAULT_ADMIN_TOKEN" -X POST \
  "$VAULT_ADDR/v1/secret/data/stoa/deploy/$TENANT/admin-oauth" \
  -H 'Content-Type: application/json' --data-binary @"$TMPD/oauth.json" -o /dev/null -w '%{http_code}')
case "$RC" in 200|204) echo "  ✓ secret/stoa/deploy/$TENANT/admin-oauth écrit (périmètre du token nominatif)";;
              *) echo "✗ seed admin-oauth KO (HTTP $RC)"; exit 1;; esac

echo "═══ 5/5 Matrice de preuve"
TOK_OK="$(bash scripts/setup-ci-horsprod.sh --mint 2>/dev/null)"
[ -n "$TOK_OK" ] || { echo "✗ mint ci-horsprod"; exit 1; }
CI_APPLIER_SECRET="$(curl -sf -H "X-Vault-Token: $VAULT_ADMIN_TOKEN" "$VAULT_ADDR/v1/secret/data/stoa/ci" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['data']['ciApplierSecret'])")"
TOK_NOSCOPE="$(curl -s -X POST "$KC_BASE/realms/stoa-lab/protocol/openid-connect/token" \
  -d client_id=ci-applier -d "client_secret=$CI_APPLIER_SECRET" -d grant_type=client_credentials \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')"
code() { local m="$1" u="$2" t="${3:-}"
  if [ -n "$t" ]; then curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -X "$m" -H "Authorization: Bearer $t" "$u"
  else curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -X "$m" "$u"; fi; }
BASE="$WM/gateway/wm-admin-self/1.0"
c="$(code GET "$BASE/rest/apigateway/health")"
[ "$c" = 401 ] && ok "sans token → 401" || bad "sans token → $c (attendu 401)"
if [ -n "$TOK_NOSCOPE" ]; then
  c="$(code GET "$BASE/rest/apigateway/health" "$TOK_NOSCOPE")"
  [ "$c" != 200 ] && ok "token sans scope $SELF_SCOPE → $c (refus)" || bad "token sans scope → 200 (barrière scope KO)"
fi
c="$(code GET "$BASE/rest/apigateway/health" "$TOK_OK")"
[ "$c" = 200 ] && ok "token ci-horsprod → 200 health via le SELF-proxy" || bad "token ci-horsprod health → $c"
c="$(code GET "$BASE/rest/apigateway/apis" "$TOK_OK")"
[ "$c" = 200 ] && ok "GET /apis via le self-proxy → 200 (l'admin répond À TRAVERS elle-même)" || bad "GET /apis → $c"
c="$(code GET "$BASE/rest/apigateway/users" "$TOK_OK")"
[ "$c" = 404 ] && ok "hors allowlist /users → 404" || bad "/users → $c (attendu 404)"
c="$(code DELETE "$BASE/rest/apigateway/apis/whatever" "$TOK_OK")"
case "$c" in 405|404) ok "DELETE → $c (jamais de suppression via le proxy)" ;;
  *) bad "DELETE → $c (attendu 405/404)" ;; esac

echo "═══ Récap : $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "✓ self-proxy OAuth2 posé et prouvé. Pipeline : ADMIN_VIA=proxy-oauth2."
else
  echo "✗ matrice incomplète."; exit 1
fi
