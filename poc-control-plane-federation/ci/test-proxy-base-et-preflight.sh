#!/bin/sh
# Rejoue la logique exacte injectee dans les deux Jenkinsfile, sous `set -eu`,
# avec un curl simule. Verifie composition de la base proxy + preflight optionnel.
set -eu

ANCIEN_DEFAUT="http://webmethods-real:5555/gateway/wm-admin-self/1.0/rest/apigateway"
KO=0
ok(){ printf '  ok   %s\n' "$1"; }
ko(){ printf '  KO   %s\n     attendu=[%s]\n     obtenu =[%s]\n' "$1" "$2" "$3"; KO=$((KO+1)); }
cmp_(){ [ "$2" = "$3" ] && ok "$1" || ko "$1" "$2" "$3"; }

# ---- bloc 1 : composition de la base du proxy (copie conforme) ----
compose(){
  PROXY_BASE="${APIM_PROXY_BASE:-}"
  if [ -z "$PROXY_BASE" ]; then
    PROXY_BASE="${APIM_PROXY_HOST}/gateway/${APIM_PROXY_API}/${APIM_PROXY_VER}${APIM_PROXY_PATH}"
  fi
  printf '%s' "$PROXY_BASE"
}
defauts(){
  APIM_PROXY_HOST=http://webmethods-real:5555
  APIM_PROXY_API=wm-admin-self
  APIM_PROXY_VER=1.0
  APIM_PROXY_PATH=/rest/apigateway
  unset APIM_PROXY_BASE 2>/dev/null || true
}

echo "== composition de la base proxy =="
defauts
cmp_ "defauts => identique a l'ancien defaut" "$ANCIEN_DEFAUT" "$(compose)"

defauts; APIM_PROXY_API=wm-admin-prod
cmp_ "le NOM seul est surchargeable" \
  "http://webmethods-real:5555/gateway/wm-admin-prod/1.0/rest/apigateway" "$(compose)"

defauts; APIM_PROXY_HOST=https://apim.vip.interne:5543; APIM_PROXY_API=admin-proxy; APIM_PROXY_VER=2
cmp_ "hote + nom + version" \
  "https://apim.vip.interne:5543/gateway/admin-proxy/2/rest/apigateway" "$(compose)"

defauts; APIM_PROXY_BASE=https://edge.client/adm/v1
cmp_ "override complet gagne" "https://edge.client/adm/v1" "$(compose)"

defauts; APIM_PROXY_BASE=""
cmp_ "override VIDE (Jenkins n'exporte pas) => retombe sur la composition" \
  "$ANCIEN_DEFAUT" "$(compose)"

# ---- bloc 2 : preflight (copie conforme, curl simule) ----
# Le compteur passe par FICHIER : curl est appele dans $( ), donc dans un
# sous-shell, ou une variable ne survivrait pas (piege du premier jet).
CURL_SEQ=""; CNT="$(mktemp)"; trap "rm -f $CNT" EXIT
curl(){
  N=$(( $(cat $CNT 2>/dev/null || echo 0) + 1 )); echo "$N" > $CNT
  printf '%s' "$(echo "$CURL_SEQ" | cut -d, -f$N)"
}

preflight(){
  echo 0 > $CNT
  APIM_API_BASE="http://gw/rest/apigateway"
  if [ "${APIM_PREFLIGHT:-on}" = "off" ]; then
    echo "SKIP"; return 0
  fi
  PF_URL="${APIM_PREFLIGHT_URL:-}"
  [ -n "$PF_URL" ] || PF_URL="$APIM_API_BASE/health"
  PF_CODES="${APIM_PREFLIGHT_CODES:-200 401}"
  PF_MAX="${APIM_PREFLIGHT_TRIES:-60}"
  i=0
  while :; do
    HC="$(curl || true)"
    for C in $PF_CODES; do
      if [ "$HC" = "$C" ]; then break 2; fi
    done
    i=$((i+1))
    if [ "$i" -ge "$PF_MAX" ]; then echo "FAIL:$PF_URL:$HC"; return 1; fi
    if [ "$i" -eq 1 ]; then :; fi
  done
  echo "UP:$PF_URL:apres $i tentative(s)"
}

echo "== preflight =="
unset APIM_PREFLIGHT APIM_PREFLIGHT_URL APIM_PREFLIGHT_CODES APIM_PREFLIGHT_TRIES 2>/dev/null || true

CURL_SEQ="200"
cmp_ "200 direct => passe" "UP:http://gw/rest/apigateway/health:apres 0 tentative(s)" "$(preflight)"

CURL_SEQ="401"
cmp_ "401 (proxy OAuth2 enforce) => preuve de vie" \
  "UP:http://gw/rest/apigateway/health:apres 0 tentative(s)" "$(preflight)"

CURL_SEQ="000,000,200"; APIM_PREFLIGHT_TRIES=5
cmp_ "gateway qui revient au 3e essai" \
  "UP:http://gw/rest/apigateway/health:apres 2 tentative(s)" "$(preflight)"
unset APIM_PREFLIGHT_TRIES

CURL_SEQ="000,000,000"; APIM_PREFLIGHT_TRIES=3
R="$(preflight || true)"
cmp_ "epuisement => echec explicite" "FAIL:http://gw/rest/apigateway/health:000" "$R"
if ( CURL_SEQ="000,000,000"; APIM_PREFLIGHT_TRIES=3; preflight >/dev/null 2>&1 ); then
  ko "epuisement => code retour non nul" "!=0" "0"; else ok "epuisement => code retour non nul"; fi
unset APIM_PREFLIGHT_TRIES

APIM_PREFLIGHT=off
cmp_ "APIM_PREFLIGHT=off => saute, ne sonde pas" "SKIP" "$(preflight)"
unset APIM_PREFLIGHT

CURL_SEQ="204"; APIM_PREFLIGHT_URL="https://vip/ping"; APIM_PREFLIGHT_CODES="204 200"
cmp_ "sonde de vie alternative + codes personnalises" \
  "UP:https://vip/ping:apres 0 tentative(s)" "$(preflight)"
unset APIM_PREFLIGHT_URL APIM_PREFLIGHT_CODES

CURL_SEQ="503"; APIM_PREFLIGHT_TRIES=2
R="$(preflight || true)"
cmp_ "code non attendu => n'est PAS pris pour une preuve de vie" \
  "FAIL:http://gw/rest/apigateway/health:503" "$R"

echo
[ "$KO" -eq 0 ] && echo "TOUT PASSE" || { echo "$KO ECHEC(S)"; exit 1; }
