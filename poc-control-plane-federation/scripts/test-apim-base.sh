#!/usr/bin/env bash
# test-apim-base.sh — preuve X/X de scripts/lib/apim-base.sh : composition de
# la base d'admin, dérivation de la voie et du mode d'auth, et les quatre
# refus nommés. TOUT EN LOCAL, aucun réseau.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO/scripts/lib/apim-base.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# run <VAR=val…> -- appelle apim_base_resolve dans un sous-shell propre et
# imprime "rc|BASE|VIA|AUTH" sur stdout, le refus sur stderr.
run(){
  env -i PATH="$PATH" HOME="$HOME" "$@" bash -c '
    . "'"$LIB"'" || exit 9
    if apim_base_resolve; then printf "0|%s|%s|%s\n" "$APIM_BASE" "$APIM_EFFECTIVE_VIA" "$APIM_AUTH_MODE"
    else printf "1|||\n"; fi' 2>"$ERRF"
}
ERRF="$(mktemp)"; trap 'rm -f "$ERRF"' EXIT

echo "== 1. composition proxy =="
R="$(run ENVIRONMENT=dev ADMIN_VIA=proxy-oauth2 APIM_TERMINUS=prod \
      APIM_PROXY_HOST=https://apim.vip:5543 APIM_PROXY_API=wm-admin-__ENV__ \
      APIM_PROXY_VER=1.0 APIM_PROXY_PATH=/rest/apigateway)"
[ "$R" = "0|https://apim.vip:5543/gateway/wm-admin-dev/1.0/rest/apigateway|proxy-oauth2|oauth2" ] \
  && ok "proxy : base composée, __ENV__ substitué, auth dérivée oauth2" \
  || ko "proxy : rendu '$R'"

echo "== 2. APIM_PROXY_BASE écrase les quatre morceaux =="
R="$(run ENVIRONMENT=rec ADMIN_VIA=proxy-oauth2 APIM_TERMINUS=prod \
      APIM_PROXY_BASE=https://autre/__ENV__/adm APIM_PROXY_HOST=https://ignore \
      APIM_PROXY_API=x APIM_PROXY_VER=9 APIM_PROXY_PATH=/z)"
[ "$R" = "0|https://autre/rec/adm|proxy-oauth2|oauth2" ] \
  && ok "APIM_PROXY_BASE gagne, et __ENV__ y est substitué aussi" || ko "override : rendu '$R'"

echo "== 3. le terminus force la voie directe =="
R="$(run ENVIRONMENT=prod ADMIN_VIA=proxy-oauth2 APIM_TERMINUS=prod \
      APIM_TERMINUS_BASE=https://prod.adm/rest/apigateway)"
[ "$R" = "0|https://prod.adm/rest/apigateway|direct|basic" ] \
  && ok "terminus : direct/basic malgré ADMIN_VIA=proxy-oauth2" || ko "terminus : rendu '$R'"

echo "== 4. les quatre refus nommés =="
run ADMIN_VIA=direct APIM_TERMINUS=prod >/dev/null
grep -q '^REFUS: ENV_REQUIS' "$ERRF" && ok "ENVIRONMENT absent ⇒ ENV_REQUIS (vert vacant fermé)" \
  || ko "ENVIRONMENT absent : stderr='$(cat "$ERRF")'"

run ENVIRONMENT=dev ADMIN_VIA= APIM_TERMINUS=prod >/dev/null
grep -q '^REFUS: VIA_INCONNU' "$ERRF" && ok "ADMIN_VIA vide ⇒ VIA_INCONNU (aucun repli silencieux)" \
  || ko "ADMIN_VIA vide : stderr='$(cat "$ERRF")'"

run ENVIRONMENT=prod ADMIN_VIA=direct APIM_TERMINUS=prod >/dev/null
grep -q '^REFUS: TERMINUS_SANS_VOIE' "$ERRF" && ok "terminus sans APIM_TERMINUS_BASE ⇒ TERMINUS_SANS_VOIE" \
  || ko "terminus sans base : stderr='$(cat "$ERRF")'"

run ENVIRONMENT=dev ADMIN_VIA=proxy-oauth2 APIM_TERMINUS=prod \
    APIM_PROXY_HOST=https://h APIM_PROXY_API= APIM_PROXY_VER=1.0 APIM_PROXY_PATH=/p >/dev/null
grep -q '^REFUS: APIM_BASE_INVALIDE' "$ERRF" && ok "un composant VIDE ⇒ APIM_BASE_INVALIDE (jamais '//' accepté)" \
  || ko "composant vide : stderr='$(cat "$ERRF")'"

run ENVIRONMENT=dev ADMIN_VIA=direct APIM_TERMINUS=prod APIM_API_BASE=pas-une-url >/dev/null
grep -q '^REFUS: APIM_BASE_INVALIDE' "$ERRF" && ok "base non http(s) ⇒ APIM_BASE_INVALIDE" \
  || ko "base non http : stderr='$(cat "$ERRF")'"

printf '\n%d ✅  %d ❌\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
