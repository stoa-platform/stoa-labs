#!/bin/sh
# Rejoue la logique exacte injectee dans les deux Jenkinsfile, sous `set -eu`,
# avec un curl simule. Verifie composition de la base proxy + preflight optionnel.
#
# CE QUE CE TEST LIT VRAIMENT — et ne code plus en dur :
#   - l'ANCIEN defaut = l'URL entiere ecrite dans le Jenkinsfile AVANT cette
#     branche, relue par `git show <base>:<fichier>` ;
#   - les defauts APIM_PROXY_* = extraits par sed sur CHAQUE Jenkinsfile REEL ;
#   - la ligne de composition elle-meme = extraite de CHAQUE Jenkinsfile REEL ;
#   - les defauts du preflight (codes de preuve de vie, nombre d'essais) = idem.
# Le premier jet codait les DEUX cotes de l'assertion « defauts => identique a
# l'ancien defaut » dans le test : il comparait deux constantes du test entre
# elles et restait VERT alors qu'un defaut du Jenkinsfile avait rompu la
# retro-compatibilite. Un test qui ne lit pas son sujet ne teste rien.
#
# Boucle sur les DEUX Jenkinsfile : rien ne garantit qu'ils restent alignes.
set -eu

ICI="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"   # .../poc-control-plane-federation/ci
POC="$(dirname "$ICI")"                                 # .../poc-control-plane-federation
RACINE="$(dirname "$POC")"                              # racine du depot
SOUS_POC="$(basename "$POC")"
# Commit de base de la branche : l'etat d'AVANT la proxification par morceaux.
# Surchargeable pour rejouer le test contre un autre point de comparaison.
BASE_REF="${STOA_BASE_REF:-92b846f}"
JENKINSFILES="Jenkinsfile.publish-api Jenkinsfile.selfservice"

KO=0
ok(){ printf '  ok   %s\n' "$1"; }
ko(){ printf '  KO   %s\n     attendu=[%s]\n     obtenu =[%s]\n' "$1" "$2" "$3"; KO=$((KO+1)); }
cmp_(){ [ "$2" = "$3" ] && ok "$1" || ko "$1" "$2" "$3"; }
# Un prerequis manquant n'est PAS un test qui passe : le test s'arrete en 2.
fatal(){ printf '  !!   %s\n' "$1" >&2; exit 2; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# ---- lecture des Jenkinsfile ---------------------------------------------
# Defaut Groovy d'une variable d'environnement : `X = "${env.X ?: 'valeur'}"`.
# Prefixe '=' dans la sortie pour distinguer « absent » (sortie vide) de
# « present et vide » (sortie '='), le cas d'APIM_PROXY_BASE.
defaut_env(){ sed -n "s/^[[:space:]]*$2[[:space:]]*=.*?:[[:space:]]*'\([^']*\)'.*/=\1/p" "$1" | head -1; }
lire_defaut(){
  V="$(defaut_env "$1" "$2")"
  [ -n "$V" ] || fatal "$2 : aucun defaut Groovy dans $1 — le test ne peut rien affirmer"
  printf '%s' "${V#=}"
}
# Defaut shell d'une variable du corps du pipeline : `X="${ENV_VAR:-valeur}"`.
defaut_sh(){ sed -n "s/^[[:space:]]*$2=\"[\$]{$3:-\(.*\)}\".*/=\1/p" "$1" | head -1; }
lire_defaut_sh(){
  V="$(defaut_sh "$1" "$2" "$3")"
  [ -n "$V" ] || fatal "$2 (\${$3:-...}) : introuvable dans $1 — le test ne peut rien affirmer"
  printf '%s' "${V#=}"
}
# Les lignes d'affectation de PROXY_BASE, telles qu'elles sont ecrites.
ligne_pb(){ sed -n 's/^[[:space:]]*\(PROXY_BASE=.*\)$/\1/p' "$1" | grep -F "$2" | head -1; }

# ---- l'ANCIEN defaut : relu dans le Jenkinsfile d'AVANT la branche --------
git -C "$RACINE" show "$BASE_REF:$SOUS_POC/ci/Jenkinsfile.publish-api" > "$TMPD/base.groovy" 2>/dev/null \
  || fatal "impossible de lire $BASE_REF:$SOUS_POC/ci/Jenkinsfile.publish-api (clone superficiel ? commit absent ?) — poser STOA_BASE_REF"
ANCIEN_DEFAUT="$(lire_defaut "$TMPD/base.groovy" APIM_PROXY_BASE)"
printf 'ancien defaut (%s) : %s\n\n' "$BASE_REF" "$ANCIEN_DEFAUT"

# ---- bloc 1 : composition de la base du proxy (copie conforme) ----
compose(){
  PROXY_BASE="${APIM_PROXY_BASE:-}"
  if [ -z "$PROXY_BASE" ]; then
    PROXY_BASE="${APIM_PROXY_HOST}/gateway/${APIM_PROXY_API}/${APIM_PROXY_VER}${APIM_PROXY_PATH}"
  fi
  printf '%s' "$PROXY_BASE"
}
# Les deux lignes que `compose()` transcrit. Comparees LITTERALEMENT a celles du
# Jenkinsfile : sans quoi la « copie conforme » peut diverger sans que rien ne
# le dise, et le reste du bloc ne mesurerait plus le pipeline reel.
COMPO_ATTENDUE='PROXY_BASE="${APIM_PROXY_HOST}/gateway/${APIM_PROXY_API}/${APIM_PROXY_VER}${APIM_PROXY_PATH}"'
OVERRIDE_ATTENDU='PROXY_BASE="${APIM_PROXY_BASE:-}"'
# Defauts du preflight transcrits dans `preflight()` ci-dessous.
PF_CODES_REJOUES='200 401'
PF_MAX_REJOUE='60'

for JF in $JENKINSFILES; do
  F="$POC/ci/$JF"
  [ -f "$F" ] || fatal "$F introuvable"
  echo "== $JF : composition de la base proxy =="

  # Defauts LUS dans ce Jenkinsfile — plus aucune valeur codee dans le test.
  D_HOST="$(lire_defaut "$F" APIM_PROXY_HOST)"
  D_API="$(lire_defaut  "$F" APIM_PROXY_API)"
  D_VER="$(lire_defaut  "$F" APIM_PROXY_VER)"
  D_PATH="$(lire_defaut "$F" APIM_PROXY_PATH)"
  D_BASE="$(defaut_env  "$F" APIM_PROXY_BASE)"
  [ -n "$D_BASE" ] || fatal "APIM_PROXY_BASE : aucun defaut Groovy dans $F"
  D_BASE="${D_BASE#=}"

  defauts(){
    APIM_PROXY_HOST="$D_HOST"; APIM_PROXY_API="$D_API"
    APIM_PROXY_VER="$D_VER";   APIM_PROXY_PATH="$D_PATH"
    APIM_PROXY_BASE="$D_BASE"
  }

  cmp_ "la ligne d'override est bien celle rejouee" "$OVERRIDE_ATTENDU" "$(ligne_pb "$F" 'APIM_PROXY_BASE')"
  cmp_ "la ligne de composition est bien celle rejouee" "$COMPO_ATTENDUE" "$(ligne_pb "$F" 'APIM_PROXY_HOST')"
  cmp_ "APIM_PROXY_BASE par defaut VIDE (sinon la composition ne sert jamais)" "" "$D_BASE"

  defauts
  cmp_ "defauts du Jenkinsfile => identique a l'ancien defaut" "$ANCIEN_DEFAUT" "$(compose)"

  defauts; APIM_PROXY_API=wm-admin-prod
  cmp_ "le NOM seul est surchargeable" \
    "${D_HOST}/gateway/wm-admin-prod/${D_VER}${D_PATH}" "$(compose)"

  defauts; APIM_PROXY_HOST=https://apim.vip.interne:5543; APIM_PROXY_API=admin-proxy; APIM_PROXY_VER=2
  cmp_ "hote + nom + version" \
    "https://apim.vip.interne:5543/gateway/admin-proxy/2${D_PATH}" "$(compose)"

  defauts; APIM_PROXY_BASE=https://edge.client/adm/v1
  cmp_ "override complet gagne" "https://edge.client/adm/v1" "$(compose)"

  defauts; APIM_PROXY_BASE=""
  cmp_ "override VIDE (Jenkins n'exporte pas) => retombe sur la composition" \
    "$ANCIEN_DEFAUT" "$(compose)"

  echo "== $JF : defauts du preflight =="
  cmp_ "codes de preuve de vie" "$PF_CODES_REJOUES" "$(lire_defaut_sh "$F" PF_CODES APIM_PREFLIGHT_CODES)"
  cmp_ "nombre d'essais"        "$PF_MAX_REJOUE"    "$(lire_defaut_sh "$F" PF_MAX   APIM_PREFLIGHT_TRIES)"
done

# ---- bloc 2 : preflight (copie conforme, curl simule) ----
# Le compteur passe par FICHIER : curl est appele dans $( ), donc dans un
# sous-shell, ou une variable ne survivrait pas (piege du premier jet).
CURL_SEQ=""; CNT="$TMPD/cnt"
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
