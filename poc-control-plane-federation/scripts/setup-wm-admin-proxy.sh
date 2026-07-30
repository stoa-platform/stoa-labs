#!/usr/bin/env bash
# setup-wm-admin-proxy.sh — pose les 3 APIs proxy admin wm-admin-{dev,rec,int}
# sur le wM RÉEL (ADR-075) puis PROUVE la barrière par une matrice de tests.
#
# IDEMPOTENT (labctl apply converge, read-back-assert) ; relançable à volonté.
#
# Flux :
#   1. login AppRole `proxy-provision` (VAULT_ADDR) → token éphémère, policy
#      stoa-proxy-provision (envs/+/wm-admin + gateways/webmethods, RIEN d'autre)
#   2. lit les creds admin du mock de CHAQUE env (secret/stoa/envs/{env}/wm-admin)
#   3. génère les manifests TEMPORAIRES (0600, trap rm) en substituant les
#      placeholders __FROM_VAULT__ — les vraies valeurs ne sont JAMAIS commitées
#   4. ./labctl apply -f par env (le wM réel importe le contrat allowlist,
#      l'${alias} route vers le mock de l'env, le credential alias porte le
#      Basic sortant, l'OAuth2 entrant exige scope deploy:{env})
#   5. matrice de vérification par env (PASS/FAIL, récap final) :
#        - sans token                    → 401
#        - token SANS le scope de l'env  → refus (≠200)
#        - token ci-horsprod avec scope  → 200 (GET health via le proxy)
#        - chemin HORS allowlist (/rest/apigateway/users) → 404
#        - DELETE (jamais dans le contrat) → 405/404
#
# Prereqs : socle + docker-compose.wm.yml + docker-compose.envs.yml up ;
#   scripts/setup-vault.sh + setup-vault-envs.sh + setup-vault-approle.sh ;
#   scripts/setup-ci-horsprod.sh (client + scopes deploy:{env}).
set -uo pipefail
cd "$(dirname "$0")/.."

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
KC_BASE="${KC_BASE:-http://localhost:8480}"
WM="${WM_GATEWAY_URL:-http://localhost:5555}"   # data-plane du wM réel (host)
ENVS=(dev rec int)
MANIFEST_DIR="gateways/webmethods/admin-proxy"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

echo "═══ 0/4 Build labctl (air-gapped, vendored) + login AppRole proxy-provision"
BIN="$(mktemp -d)/labctl"
( cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" . ) || { echo "✗ build labctl"; exit 1; }
chmod +x "$BIN"

# tmpfiles 0600 créés EN AMONT pour que le trap ne référence jamais un var unset
VTOKFILE="$(mktemp)"; TMPDIR_MANIFESTS="$(mktemp -d)"
trap 'rm -rf "$VTOKFILE" "$TMPDIR_MANIFESTS"' EXIT
chmod 0600 "$VTOKFILE"; chmod 0700 "$TMPDIR_MANIFESTS"

# role_id/secret_id : fournis par l'opérateur (VAULT_ROLE_ID/VAULT_SECRET_ID) ou
# mintés ici via le token admin de bootstrap (PoC — en prod : opérateur Vault).
if [ -z "${VAULT_ROLE_ID:-}" ] || [ -z "${VAULT_SECRET_ID:-}" ]; then
  IFS=$'\t' read -r VAULT_ROLE_ID VAULT_SECRET_ID < <(bash scripts/setup-vault-approle.sh --mint proxy-provision) \
    || { echo "✗ mint proxy-provision (lancer scripts/setup-vault-approle.sh d'abord ?)"; exit 1; }
fi
VTOK="$(curl -sf -X POST "$VAULT_ADDR/v1/auth/approle/login" \
  -d "{\"role_id\":\"$VAULT_ROLE_ID\",\"secret_id\":\"$VAULT_SECRET_ID\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')"
[ -n "$VTOK" ] || { echo "✗ vault approle login failed"; exit 1; }
printf %s "$VTOK" > "$VTOKFILE"
echo "  ✓ token éphémère proxy-provision (policy stoa-proxy-provision)"

# vread <env> <field> — lit secret/stoa/envs/{env}/wm-admin avec le token éphémère
vread() {
  curl -sf -H "X-Vault-Token: $VTOK" "$VAULT_ADDR/v1/secret/data/stoa/envs/$1/wm-admin" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['data']['$2'])"
}

echo "═══ 1/4 Apply des 3 proxies (manifests temporaires 0600, creds depuis Vault)"
# Le contrat est référencé en RELATIF par les manifests (contract: ./wm-admin-
# proxy.openapi.yaml, résolu vs le manifest) — il doit donc accompagner les
# manifests substitués dans le tmpdir.
cp "$MANIFEST_DIR/wm-admin-proxy.openapi.yaml" "$TMPDIR_MANIFESTS/"
for E in "${ENVS[@]}"; do
  BU="$(vread "$E" username)"; BP="$(vread "$E" password)"
  [ -n "$BU" ] && [ -n "$BP" ] || { echo "✗ secret envs/$E/wm-admin illisible (setup-vault-envs.sh ?)"; exit 1; }
  M="$TMPDIR_MANIFESTS/targets.wm-admin-$E.yaml"
  ( umask 077
    # double substitution ordonnée : backendUsername d'abord (1re occurrence),
    # backendPassword ensuite — le manifest ne porte que ces 2 placeholders.
    sed -e "s|backendUsername: __FROM_VAULT__|backendUsername: $BU|" \
        -e "s|backendPassword: __FROM_VAULT__|backendPassword: $BP|" \
        "$MANIFEST_DIR/targets.wm-admin-$E.yaml" > "$M" )
  # VAULT_TOKEN_FILE : labctl résout l'admin du wM réel (gateways/webmethods)
  # avec le MÊME token éphémère (ADR-074) — aucun secret en argv/env/log.
  if VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VTOKFILE" "$BIN" apply -f "$M"; then
    echo "  ✓ wm-admin-$E appliqué"
  else
    echo "  ✗ apply wm-admin-$E KO"; FAIL=$((FAIL+1))
  fi
done

echo "═══ 1bis/4 Application wM ci-horsprod (le pendant subscribe d'un client KC existant)"
# Le path OAuth2 strict (applicationLookup=strict) exige une APPLICATION côté
# gateway qui mappe le azp du token (identifier openIdClaims) ET porte les
# stratégies des APIs (authStrategyIds). Pour un consumer métier c'est `labctl
# subscribe` qui la pose (avec le client Keycloak) ; ici le client ci-horsprod
# existe déjà (setup-ci-horsprod.sh) — on converge UNIQUEMENT l'application,
# payloads identiques à consumer.go (identifiers azp/openIdClaims, PUT du
# record entier, association /applications/{id}/apis).
WMU="$(curl -sf -H "X-Vault-Token: $VTOK" "$VAULT_ADDR/v1/secret/data/stoa/gateways/webmethods" \
  | python3 -c "import sys,json;d=json.load(sys.stdin)['data']['data'];print(d['username'])")"
WMP="$(curl -sf -H "X-Vault-Token: $VTOK" "$VAULT_ADDR/v1/secret/data/stoa/gateways/webmethods" \
  | python3 -c "import sys,json;d=json.load(sys.stdin)['data']['data'];print(d['password'])")"
[ -n "$WMU" ] && [ -n "$WMP" ] || { echo "✗ creds admin wM illisibles (gateways/webmethods)"; exit 1; }
ADMIN=(-u "$WMU:$WMP" -H 'Accept: application/json')

# id de l'application ci-horsprod (créée si absente)
APP_ID="$(curl -sf "${ADMIN[@]}" "$WM/rest/apigateway/applications" | python3 -c "
import sys,json
for a in json.load(sys.stdin).get('applications',[]):
    if a.get('name')=='ci-horsprod': print(a['id']); break")"
if [ -z "$APP_ID" ]; then
  APP_ID="$(curl -sf "${ADMIN[@]}" -X POST "$WM/rest/apigateway/applications" -H 'Content-Type: application/json' \
    -d '{"name":"ci-horsprod","description":"CI hors-prod: deploiement via les proxies wm-admin-{env} (ADR-075)"}' \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('id') or d.get('applications',[{}])[0].get('id',''))")"
fi
[ -n "$APP_ID" ] || { echo "✗ application ci-horsprod introuvable/incréable"; exit 1; }

# ids des 3 APIs proxy + des 3 stratégies OIDC-wm-admin-{env}
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
# association APIs + binding azp/strategies (PUT du record entier, consumer.go)
curl -sf "${ADMIN[@]}" -X PUT "$WM/rest/apigateway/applications/$APP_ID/apis" \
  -H 'Content-Type: application/json' -d "{\"apiIDs\":$API_IDS}" -o /dev/null \
  && echo "  ✓ application associée aux 3 proxies" || { echo "  ✗ association APIs"; FAIL=$((FAIL+1)); }
curl -sf "${ADMIN[@]}" "$WM/rest/apigateway/applications/$APP_ID" | python3 -c "
import sys,json
d=json.load(sys.stdin)
app=(d.get('applications') or [d])[0] if isinstance(d,dict) else d
app['identifiers']=[{'key':'openIdClaims','name':'azp','value':['ci-horsprod']}]
app['authStrategyIds']=json.loads('$STRAT_IDS')
print(json.dumps(app))" > "$TMPDIR_MANIFESTS/app.json"
curl -sf "${ADMIN[@]}" -X PUT "$WM/rest/apigateway/applications/$APP_ID" \
  -H 'Content-Type: application/json' --data-binary @"$TMPDIR_MANIFESTS/app.json" -o /dev/null \
  && echo "  ✓ identifier azp=ci-horsprod + authStrategyIds ($(python3 -c "import json;print(len(json.loads('$STRAT_IDS')))" ) stratégies)" \
  || { echo "  ✗ binding OAuth2 application"; FAIL=$((FAIL+1)); }
unset WMU WMP

echo "═══ 2/4 Tokens de test (client_credentials — aucun mot de passe utilisateur)"
# ci-horsprod : scopes deploy:dev+rec+int par défaut (setup-ci-horsprod.sh).
TOK_OK="$(bash scripts/setup-ci-horsprod.sh --mint 2>/dev/null)"
[ -n "$TOK_OK" ] || { echo "✗ mint ci-horsprod (setup-ci-horsprod.sh ?)"; exit 1; }
# ci-applier : client de la médiation ADR-072 — AUCUN scope deploy:{env} → sert
# de contre-épreuve « bon issuer, bonne signature, MAUVAIS scope ». Contre-preuve
# OPTIONNELLE : pas de secret par défaut (dépôt public) ; si CI_APPLIER_SECRET
# n'est pas fourni, ce test annexe est simplement SAUTÉ (pas de repli silencieux).
TOK_NOSCOPE=""
if [ -n "${CI_APPLIER_SECRET:-}" ]; then
  TOK_NOSCOPE="$(curl -s -X POST "$KC_BASE/realms/stoa-lab/protocol/openid-connect/token" \
    -d client_id=ci-applier -d "client_secret=$CI_APPLIER_SECRET" -d grant_type=client_credentials \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')"
fi
[ -n "$TOK_NOSCOPE" ] || echo "  (ci-applier non mintable — test 'sans scope' sera SKIP ; définir CI_APPLIER_SECRET pour l'activer, voir poc-control-plane-federation/.env.example)"

code() { # code METHOD URL [TOKEN] -> http_code
  local m="$1" u="$2" t="${3:-}"
  if [ -n "$t" ]; then
    curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -X "$m" -H "Authorization: Bearer $t" "$u"
  else
    curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -X "$m" "$u"
  fi
}

echo "═══ 3/4 Matrice de vérification (la contrainte EST la preuve)"
for E in "${ENVS[@]}"; do
  BASE="$WM/gateway/wm-admin-$E/1.0"
  echo "  — wm-admin-$E —"
  c="$(code GET "$BASE/rest/apigateway/health")"
  [ "$c" = 401 ] && ok "[$E] sans token → 401" || bad "[$E] sans token → $c (attendu 401)"
  if [ -n "$TOK_NOSCOPE" ]; then
    c="$(code GET "$BASE/rest/apigateway/health" "$TOK_NOSCOPE")"
    [ "$c" != 200 ] && ok "[$E] token sans scope deploy:$E → $c (refus)" || bad "[$E] token sans scope → 200 (la barrière scope ne tient pas)"
  fi
  c="$(code GET "$BASE/rest/apigateway/health" "$TOK_OK")"
  [ "$c" = 200 ] && ok "[$E] token ci-horsprod (deploy:$E) → 200 health via proxy" || bad "[$E] token ci-horsprod → $c (attendu 200)"
  c="$(code GET "$BASE/rest/apigateway/users" "$TOK_OK")"
  [ "$c" = 404 ] && ok "[$E] hors allowlist /users → 404" || bad "[$E] hors allowlist /users → $c (attendu 404)"
  c="$(code DELETE "$BASE/rest/apigateway/apis/whatever" "$TOK_OK")"
  case "$c" in 405|404) ok "[$E] DELETE → $c (jamais de suppression via le proxy)" ;;
    *) bad "[$E] DELETE → $c (attendu 405/404)" ;; esac
done

echo "═══ 4/4 Récap"
echo "  $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "✓ proxies admin multi-env posés et prouvés (ADR-075)."
else
  echo "✗ matrice incomplète — voir les FAIL ci-dessus."
  exit 1
fi
