#!/bin/sh
# Rejoue la logique exacte injectee dans les deux Jenkinsfile, sous `set -eu`,
# avec un curl simule. Verifie composition de la base proxy + preflight optionnel.
#
# CE QUE CE TEST LIT VRAIMENT — et ne code plus en dur :
#   - le point de comparaison (BASE_REF) = derive par `git merge-base` avec la
#     branche par defaut (origin/main, ou main), jamais un SHA fige ;
#   - l'ANCIEN defaut = l'URL entiere ecrite dans le Jenkinsfile a ce point,
#     relue par `git show <base>:<fichier>` ;
#   - les defauts APIM_PROXY_* = extraits par sed sur CHAQUE Jenkinsfile REEL ;
#   - la ligne de composition elle-meme = extraite de CHAQUE Jenkinsfile REEL ;
#   - les defauts du preflight (codes de preuve de vie, nombre d'essais) = idem ;
#   - les garde-fous (validation de APIM_PREFLIGHT_TRIES, casse de
#     APIM_PREFLIGHT) = leur PRESENCE ET leur ordre sont verifies par lecture
#     litterale (grep) du Jenkinsfile REEL, pas seulement rejoues dans le
#     harnais de simulation ci-dessous ;
#   - le trim d'APIM_PROXY_BASE = extrait du job XML REEL.
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
JENKINSFILES="Jenkinsfile.publish-api Jenkinsfile.selfservice"

KO=0
ok(){ printf '  ok   %s\n' "$1"; }
ko(){ printf '  KO   %s\n     attendu=[%s]\n     obtenu =[%s]\n' "$1" "$2" "$3"; KO=$((KO+1)); }
cmp_(){ [ "$2" = "$3" ] && ok "$1" || ko "$1" "$2" "$3"; }
# Vrai si $2 (sous-chaine fixe) apparait litteralement dans le fichier $3 —
# pour verifier qu'un garde-fou est bien ECRIT dans le fichier REEL, sans
# recopier sa logique dans le test (meme piege que l'ancien defaut fige).
contient(){ grep -qF -- "$2" "$3" && ok "$1" || ko "$1" "present dans $3" "absent de $3"; }
# Vrai si le motif $2 apparait a une ligne strictement avant le motif $3 dans
# le fichier $4 — un garde-fou pose APRES la boucle qu'il est cense proteger
# ne protege rien.
avant(){
  L1="$(grep -nF -- "$2" "$4" | head -1 | cut -d: -f1)"
  L2="$(grep -nF -- "$3" "$4" | head -1 | cut -d: -f1)"
  if [ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ]; then ok "$1"
  else ko "$1" "ligne($2) < ligne($3)" "L1=$L1 L2=$L2 dans $4"; fi
}
# Un prerequis manquant n'est PAS un test qui passe : le test s'arrete en 2.
fatal(){ printf '  !!   %s\n' "$1" >&2; exit 2; }

# Commit de base : le point de comparaison d'AVANT la proxification par
# morceaux. STOA_BASE_REF reste l'echappatoire explicite (poser n'importe
# quelle ref). Le defaut NORMAL ne fige plus un SHA : cet historique a deja
# ete purge une fois (handoff carto), et une seconde reecriture ferait
# disparaitre un SHA fige, rendant le PLAN rouge pour une raison etrangere au
# changement examine (le point de comparaison est mort, pas le changement).
# Le defaut derive donc le point de divergence avec la branche par defaut
# (origin/main, ou main en son absence) : stable meme apres une purge, tant
# que la relation « cette branche descend de main » reste vraie.
BASE_REF="${STOA_BASE_REF:-}"
if [ -z "$BASE_REF" ]; then
  if git -C "$RACINE" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    BASE_REF="$(git -C "$RACINE" merge-base HEAD origin/main 2>/dev/null || true)"
  elif git -C "$RACINE" rev-parse --verify -q main >/dev/null 2>&1; then
    BASE_REF="$(git -C "$RACINE" merge-base HEAD main 2>/dev/null || true)"
  fi
fi
[ -n "$BASE_REF" ] || fatal "point de comparaison introuvable : ni STOA_BASE_REF, ni origin/main, ni main ne sont resolvables depuis ce clone (clone superficiel ? branche de base absente ?) — poser STOA_BASE_REF=<sha-ou-ref> explicitement pour rejouer le test."

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

  echo "== $JF : garde-fous du preflight (lus dans le fichier reel) =="
  # APIM_PREFLIGHT_TRIES non numerique : sous sh, `[ "$i" -ge "abc" ]` rend 2
  # (ni vrai ni faux) — la branche de sortie n'est jamais prise, boucle a
  # l'infini. Le garde-fou doit exister ET s'executer AVANT la boucle.
  contient "$JF : le garde-fou PF_MAX existe (case sur un entier)" 'case "$PF_MAX" in' "$F"
  contient "$JF : rejette le non-numerique" '*[!0-9]*' "$F"
  contient "$JF : rejette aussi zero (pas un entier POSITIF)" '|0)' "$F"
  contient "$JF : replie explicitement sur le defaut 60" 'PF_MAX=60' "$F"
  avant "$JF : le garde-fou PF_MAX est pose avant la boucle, pas apres" \
    'case "$PF_MAX" in' 'while :; do' "$F"
  # APIM_PREFLIGHT sensible a la casse : 'Off' ne doit pas etre pris pour 'off'.
  contient "$JF : APIM_PREFLIGHT est compare apres mise en minuscules" \
    "tr '[:upper:]' '[:lower:]'" "$F"
  contient "$JF : le test 'off' porte sur la variable normalisee" \
    'if [ "$APIM_PREFLIGHT_LC" = "off" ]; then' "$F"
done

# ---- bloc 1bis : trim du parametre APIM_PROXY_BASE dans les job XML ----
# APIM_PROXY_BASE est l'echappatoire (override complet, cf. commentaire du
# Jenkinsfile) : c'est justement celle qui ne doit PAS laisser passer un
# espace colle en debut/fin — sinon l'URL composee est invalide, et l'erreur
# est difficile a voir (un espace ne se distingue pas a l'oeil dans un log).
# Valeur LUE dans le XML reel : jamais une constante du test.
JOBXMLS="jenkins/publish-api-deploy.job.xml jenkins/selfservice-app-deploy.job.xml"
# Extrait le <trim> du bloc <hudson.model.StringParameterDefinition> dont le
# <name> vaut $2, dans le fichier $1 (les blocs ne s'imbriquent pas dans ces XML).
trim_de(){
  awk -v nom="$2" '
    /<hudson\.model\.StringParameterDefinition>/ { buf=""; dans=1 }
    dans { buf = buf $0 "\n" }
    /<\/hudson\.model\.StringParameterDefinition>/ {
      dans=0
      if (buf ~ ("<name>" nom "</name>")) {
        if (match(buf, /<trim>[a-z]*<\/trim>/)) {
          s = substr(buf, RSTART, RLENGTH); gsub(/<\/?trim>/, "", s); print s; exit
        }
      }
    }
  ' "$1"
}

for X in $JOBXMLS; do
  XF="$POC/ci/$X"
  [ -f "$XF" ] || fatal "$XF introuvable"
  echo "== $X : trim d'APIM_PROXY_BASE =="
  TR="$(trim_de "$XF" APIM_PROXY_BASE)"
  [ -n "$TR" ] || fatal "APIM_PROXY_BASE : aucun <trim> lisible dans $XF"
  cmp_ "$X : APIM_PROXY_BASE n'est plus la seule echappatoire non rognee (trim=true)" "true" "$TR"

  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$XF" >"$TMPD/xmlok" 2>&1; then
      ok "$X : XML bien forme"
    else
      ko "$X : XML bien forme" "0" "$(cat "$TMPD/xmlok")"
    fi
  fi
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
  APIM_PREFLIGHT_LC="$(printf '%s' "${APIM_PREFLIGHT:-on}" | tr '[:upper:]' '[:lower:]')"
  if [ "$APIM_PREFLIGHT_LC" = "off" ]; then
    echo "SKIP"; return 0
  fi
  PF_URL="${APIM_PREFLIGHT_URL:-}"
  [ -n "$PF_URL" ] || PF_URL="$APIM_API_BASE/health"
  PF_CODES="${APIM_PREFLIGHT_CODES:-200 401}"
  PF_MAX="${APIM_PREFLIGHT_TRIES:-60}"
  case "$PF_MAX" in
    ''|*[!0-9]*|0) PF_MAX=60 ;;
  esac
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

# APIM_PREFLIGHT_TRIES non numerique : preuve QUANTITATIVE de non-bouclage —
# pas seulement « ca finit par sortir », mais « ca sort au bout d'exactement
# PF_MAX(=60, le defaut) appels curl », donc borne et pas un hasard de sequence.
CURL_SEQ="000"; APIM_PREFLIGHT_TRIES="abc"
R="$(preflight || true)"
cmp_ "APIM_PREFLIGHT_TRIES='abc' => ne boucle plus a l'infini (replie sur 60)" \
  "FAIL:http://gw/rest/apigateway/health:000" "$R"
cmp_ "  … et le nombre d'essais reellement effectues est borne au defaut (60)" "60" "$(cat "$CNT")"
unset APIM_PREFLIGHT_TRIES

CURL_SEQ="000"; APIM_PREFLIGHT_TRIES="0"
preflight >/dev/null || true
cmp_ "APIM_PREFLIGHT_TRIES=0 n'est pas un entier POSITIF => replie aussi sur 60" "60" "$(cat "$CNT")"
unset APIM_PREFLIGHT_TRIES

CURL_SEQ="000"; APIM_PREFLIGHT_TRIES="-3"
preflight >/dev/null || true
cmp_ "APIM_PREFLIGHT_TRIES negatif => replie aussi sur 60" "60" "$(cat "$CNT")"
unset APIM_PREFLIGHT_TRIES

APIM_PREFLIGHT=off
cmp_ "APIM_PREFLIGHT=off => saute, ne sonde pas" "SKIP" "$(preflight)"
unset APIM_PREFLIGHT

APIM_PREFLIGHT=Off
cmp_ "APIM_PREFLIGHT=Off (casse mixte) => desactive aussi, insensible a la casse" "SKIP" "$(preflight)"
unset APIM_PREFLIGHT

APIM_PREFLIGHT=OFF
cmp_ "APIM_PREFLIGHT=OFF (tout majuscule) => desactive aussi" "SKIP" "$(preflight)"
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
