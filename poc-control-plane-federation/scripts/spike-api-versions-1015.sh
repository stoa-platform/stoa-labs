#!/usr/bin/env bash
# spike-api-versions-1015.sh — MESURE (jamais suppose) le comportement de
# POST /apis/{id}/versions sur la vraie gateway wM 10.15 du lab.
#
# Protocole F4 : tout objet créé porte le suffixe p3spike et meurt dans le
# trap EXIT (teardown vérifié, jamais forcé). Les APIs qui servent du trafic
# (accounts-read, payments-initiation, …) ne sont JAMAIS lues en écriture ni
# modifiées — seules des APIs JETABLES sont créées et versionnées.
#
# bash 3.2 (macOS par défaut, comme le reste des spikes de ce dépôt) : pas de
# tableaux associatifs — quatre variantes fixes, quatre jeux de variables.
#
# DÉCOUVERTE EN COURS DE ROUTE (run #1, gardée pour mémoire, corrigée ici) :
# la gateway refuse TOUT POST /apis/{id}/versions dont {id} n'est plus la
# DERNIÈRE version connue ("Versioning is allowed only from latest version",
# HTTP 400) — y compris un DEUXIÈME appel sur le MÊME id après un premier
# succès. On ne peut donc PAS isoler l'effet de retainApplications en enchaînant
# plusieurs /versions sur une seule lignée : ce script mint UNE version par API
# de base, sur QUATRE APIs de base indépendantes (une par variante du flag).
#
# Questions auxquelles ce script répond par des mesures :
#   M1. Quel corps accepte /versions ? {newApiVersion} seul suffit-il ?
#       retainApplications existe-t-il (nom exact, type, effet) ?
#   M2. La nouvelle version porte-t-elle les policies de la base, et dans
#       quel état (isActive) naît-elle ?
#   M3. Une app souscrite à la base est-elle souscrite à la nouvelle version
#       après duplication — et le flag change-t-il la réponse ? (le piège
#       multi-version qui a déjà mordu ce lab — bug labctl tracké)
#   BONUS. Que rend un POST /versions vers un numéro de version qui existe déjà,
#          appelé sur la DERNIÈRE version (pour isoler "déjà existant" de
#          "pas la dernière") ?
#
#   WM_GATEWAY_URL=http://localhost:5555 WM_ADMIN_CREDS='Administrator:manage' \
#     bash scripts/spike-api-versions-1015.sh
set -uo pipefail
WM="${WM_GATEWAY_URL:?WM_GATEWAY_URL requis — dire sa cible est volontaire}"
A="${WM_ADMIN_CREDS:?WM_ADMIN_CREDS requis (user:pass)}"
GW="$WM/rest/apigateway"
WORK="$(mktemp -d /tmp/p3spike.XXXXXX)"
PASS=0; FAIL=0
APP="p3spike-app"
APP_ID=""

# Quatre lignées indépendantes, une par variante du flag testée.
BARE_NAME=p3spike-bare;   BARE_BASE_ID="";  BARE_NEW_ID="";  BARE_CODE=""
TRUE_NAME=p3spike-true;   TRUE_BASE_ID="";  TRUE_NEW_ID="";  TRUE_CODE=""
FALSE_NAME=p3spike-false; FALSE_BASE_ID=""; FALSE_NEW_ID=""; FALSE_CODE=""
CASE_NAME=p3spike-case;   CASE_BASE_ID="";  CASE_NEW_ID="";  CASE_CODE=""

declare -a ALL_API_IDS=()   # bases + versions minées, pour le teardown

say()  { printf '\n== %s ==\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  OK  %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  KO  %s\n' "$*"; }
info() { printf '  .   %s\n' "$*"; }
fact() { printf '\nM%s: %s\n' "$1" "$2"; }
adm()  { curl -sS -u "$A" -H "Accept: application/json" "$@"; }

# DÉCOUVERTE teardown (mesurée pendant ce spike, pas supposée) : sur cette
# gateway, un GET vers une API/application DÉJÀ SUPPRIMÉE (ou un GUID qui n'a
# JAMAIS existé) ne rend PAS 404 mais 401 {"errorDetails":"User doesn't have
# permission to manage this API"} — vérifié avec un GUID aléatoire jamais créé.
# Le teardown ci-dessous vérifie donc 401, pas 404.
TEARDOWN_CLEAN=1
cleanup() {
  say "teardown (F4 : objets p3spike, trap EXIT — jamais de force)"
  if [ -n "$APP_ID" ]; then
    C=$(adm -o /dev/null -w '%{http_code}' -X DELETE "$GW/applications/$APP_ID")
    info "DELETE application $APP_ID -> HTTP $C"
  fi
  for ID in ${ALL_API_IDS[@]+"${ALL_API_IDS[@]}"}; do
    [ -n "$ID" ] || continue
    adm -X PUT "$GW/apis/$ID/deactivate" -o /dev/null
    C=$(adm -o /dev/null -w '%{http_code}' -X DELETE "$GW/apis/$ID")
    info "DELETE api $ID -> HTTP $C"
  done
  # Vérification — re-GET sur TOUT ce qui a été créé. Sur CETTE gateway le
  # signal de "disparu" est 401 (mesuré ci-dessus), pas 404.
  for ID in ${ALL_API_IDS[@]+"${ALL_API_IDS[@]}"}; do
    [ -n "$ID" ] || continue
    C=$(adm -o /dev/null -w '%{http_code}' "$GW/apis/$ID")
    if [ "$C" = "401" ]; then
      ok "teardown vérifié : api $ID -> 401 (disparu)"
    else
      ko "teardown INCOMPLET : api $ID -> HTTP $C (ARRÊT — état exact ci-dessus, PAS de force)"
      TEARDOWN_CLEAN=0
    fi
  done
  if [ -n "$APP_ID" ]; then
    C=$(adm -o /dev/null -w '%{http_code}' "$GW/applications/$APP_ID")
    if [ "$C" = "401" ]; then
      ok "teardown vérifié : application $APP_ID -> 401 (disparue)"
    else
      ko "teardown INCOMPLET : application $APP_ID -> HTTP $C (ARRÊT — état exact ci-dessus, PAS de force)"
      TEARDOWN_CLEAN=0
    fi
  fi
  rm -rf "$WORK"
  say "RÉSULTAT : $PASS/$((PASS+FAIL))  |  teardown $( [ "$TEARDOWN_CLEAN" = 1 ] && echo VÉRIFIÉ || echo INCOMPLET )"
}
trap cleanup EXIT

# ------------------------------------------------------------- helpers JSON --
apiId()       { jq -r '.apiResponse.api.id // empty'; }
appId()       { jq -r '.id // .application.id // (.applications // [])[0].id // empty'; }
apiIsActive() { adm "$GW/apis/$1" | jq -r '.apiResponse.api.isActive'; }
apiPolicies() { adm "$GW/apis/$1" | jq -c '.apiResponse.api.policies // []'; }
appConsumingAPIs() { adm "$GW/applications/$APP_ID" | jq -c '[(.applications // [])[0].consumingAPIs[]?] | sort'; }
hasID() {  # $1 = état JSON (array trié), $2 = id à chercher -> "true"/"false"/"n/a" si $2 vide
  [ -n "$2" ] || { echo "n/a"; return; }
  echo "$1" | jq --arg id "$2" 'index($id) != null'
}

# createBase <name> -> imprime l'id créé sur stdout (vide si échec)
createBase() {
  local N="$1"
  cat > "$WORK/$N.yaml" <<EOF
openapi: 3.0.0
info: { title: $N, version: "1.0" }
servers: [ { url: "http://poc-token-echo:8080" } ]
paths: { /ping: { get: { operationId: ping, responses: { '200': { description: ok } } } } }
EOF
  adm -F "file=@$WORK/$N.yaml;type=application/x-yaml" -F type=openapi \
    -F "apiName=$N" -F apiVersion=1.0 "$GW/apis" | apiId
}

# ---------------------------------------------------------- préambule -------
say "préambule : gateway joignable, noms jetables disponibles"
PING=$(adm -o /dev/null -w '%{http_code}' "$GW/apis")
[ "$PING" = "200" ] || { ko "gateway injoignable sur $GW (HTTP $PING)"; exit 1; }
ok "gateway joignable ($GW)"

EXISTING=$(adm "$GW/apis")
COLLISION=0
for N in "$BARE_NAME" "$TRUE_NAME" "$FALSE_NAME" "$CASE_NAME"; do
  C=$(echo "$EXISTING" | jq --arg n "$N" '[.apiResponse[] | (.api // .) | select(.apiName==$n)] | length')
  [ "$C" = "0" ] || { ko "collision : une API '$N' existe déjà"; COLLISION=1; }
done
[ "$COLLISION" = "0" ] || { ko "ARRÊT — noms jetables déjà pris, aucune écriture"; exit 1; }
ok "les 4 noms jetables sont disponibles (aucune collision)"

# ---------------------------------------------- setup : 4 bases indépendantes
say "setup : 4 APIs jetables v1.0 indépendantes (une par variante du flag)"
BARE_BASE_ID=$(createBase "$BARE_NAME")
[ -n "$BARE_BASE_ID" ] && { ALL_API_IDS+=("$BARE_BASE_ID"); adm -X PUT "$GW/apis/$BARE_BASE_ID/activate" -o /dev/null; ok "$BARE_NAME v1.0 créée et activée ($BARE_BASE_ID)"; } || ko "création de $BARE_NAME v1.0"
TRUE_BASE_ID=$(createBase "$TRUE_NAME")
[ -n "$TRUE_BASE_ID" ] && { ALL_API_IDS+=("$TRUE_BASE_ID"); adm -X PUT "$GW/apis/$TRUE_BASE_ID/activate" -o /dev/null; ok "$TRUE_NAME v1.0 créée et activée ($TRUE_BASE_ID)"; } || ko "création de $TRUE_NAME v1.0"
FALSE_BASE_ID=$(createBase "$FALSE_NAME")
[ -n "$FALSE_BASE_ID" ] && { ALL_API_IDS+=("$FALSE_BASE_ID"); adm -X PUT "$GW/apis/$FALSE_BASE_ID/activate" -o /dev/null; ok "$FALSE_NAME v1.0 créée et activée ($FALSE_BASE_ID)"; } || ko "création de $FALSE_NAME v1.0"
CASE_BASE_ID=$(createBase "$CASE_NAME")
[ -n "$CASE_BASE_ID" ] && { ALL_API_IDS+=("$CASE_BASE_ID"); adm -X PUT "$GW/apis/$CASE_BASE_ID/activate" -o /dev/null; ok "$CASE_NAME v1.0 créée et activée ($CASE_BASE_ID)"; } || ko "création de $CASE_NAME v1.0"

[ -n "$BARE_BASE_ID" ] || { ko "ARRÊT — base 'bare' absente, mesures impossibles"; exit 1; }
BASE_POLICIES=$(apiPolicies "$BARE_BASE_ID")
info "policies de la base 'bare' (référence pour M2) : $BASE_POLICIES"

say "setup : UNE application jetable, souscrite aux 4 bases v1.0"
APP_ID=$(adm -H "Content-Type: application/json" -X POST "$GW/applications" \
  -d "{\"name\":\"$APP\",\"description\":\"spike p3 versions/souscriptions (jetable, F4)\",\"contactEmails\":[]}" \
  | appId)
[ -n "$APP_ID" ] && ok "application jetable $APP ($APP_ID)" || { ko "création application"; exit 1; }
IDS_JSON=$(printf '%s\n' "$BARE_BASE_ID" "$TRUE_BASE_ID" "$FALSE_BASE_ID" "$CASE_BASE_ID" | jq -R 'select(length>0)' | jq -s .)
C=$(adm -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" \
  -X PUT "$GW/applications/$APP_ID/apis" -d "{\"apiIDs\":$IDS_JSON}")
[[ "$C" =~ ^(200|201|204)$ ]] && ok "app associée aux bases (HTTP $C)" || { ko "association bases (HTTP $C)"; exit 1; }
STATE0=$(appConsumingAPIs)
EXPECT0=$(echo "$IDS_JSON" | jq -c 'sort')
info "témoin — consumingAPIs juste après association : $STATE0"
[ "$STATE0" = "$EXPECT0" ] && ok "témoin bien formé : les bases associées, rien d'autre, avant toute mutation" \
  || ko "témoin inattendu avant mutation : $STATE0 (attendu $EXPECT0)"

# =============================================================== M1 =========
say "M1 — forme du corps de POST /apis/{id}/versions (une variante par base)"

# mintVersion <baseID> <corps JSON> -> écrit "<code> <id-ou-vide>" sur stdout
# mintVersion <baseID> <corps JSON> — écrit le résultat dans les GLOBALES
# MINT_CODE / MINT_ID (jamais un echo-retour : info()/ok()/ko() écrivent sur
# stdout, un echo final serait pollué si la fonction était capturée par $()).
MINT_CODE=""; MINT_ID=""
mintVersion() {
  local BASEID="$1" BODYREQ="$2" F="$WORK/mint.$$.json"
  MINT_CODE=$(adm -o "$F" -w '%{http_code}' -H "Content-Type: application/json" \
    -X POST "$GW/apis/$BASEID/versions" -d "$BODYREQ")
  info "POST /apis/$BASEID/versions $BODYREQ -> HTTP $MINT_CODE"
  info "corps : $(head -c 300 "$F")"
  MINT_ID=""
  if [ "$MINT_CODE" = "200" ] || [ "$MINT_CODE" = "201" ]; then
    MINT_ID=$(jq -r '.apiResponse.api.id // empty' < "$F")
  fi
  rm -f "$F"
}

if [ -n "$BARE_BASE_ID" ]; then
  mintVersion "$BARE_BASE_ID" '{"newApiVersion":"2.0"}'
  BARE_CODE="$MINT_CODE"; BARE_NEW_ID="$MINT_ID"
  [ -n "$BARE_NEW_ID" ] && { ALL_API_IDS+=("$BARE_NEW_ID"); ok "bare -> version mintée ($BARE_NEW_ID)"; } || ko "bare : version refusée (HTTP $BARE_CODE)"
fi
if [ -n "$TRUE_BASE_ID" ]; then
  mintVersion "$TRUE_BASE_ID" '{"newApiVersion":"2.0","retainApplications":true}'
  TRUE_CODE="$MINT_CODE"; TRUE_NEW_ID="$MINT_ID"
  [ -n "$TRUE_NEW_ID" ] && { ALL_API_IDS+=("$TRUE_NEW_ID"); ok "retainApplications=true -> version mintée ($TRUE_NEW_ID)"; } || ko "retainApplications=true : version refusée (HTTP $TRUE_CODE)"
fi
if [ -n "$FALSE_BASE_ID" ]; then
  mintVersion "$FALSE_BASE_ID" '{"newApiVersion":"2.0","retainApplications":false}'
  FALSE_CODE="$MINT_CODE"; FALSE_NEW_ID="$MINT_ID"
  [ -n "$FALSE_NEW_ID" ] && { ALL_API_IDS+=("$FALSE_NEW_ID"); ok "retainApplications=false -> version mintée ($FALSE_NEW_ID)"; } || ko "retainApplications=false : version refusée (HTTP $FALSE_CODE)"
fi
if [ -n "$CASE_BASE_ID" ]; then
  mintVersion "$CASE_BASE_ID" '{"newApiVersion":"2.0","RetainApplications":true}'
  CASE_CODE="$MINT_CODE"; CASE_NEW_ID="$MINT_ID"
  [ -n "$CASE_NEW_ID" ] && { ALL_API_IDS+=("$CASE_NEW_ID"); ok "RetainApplications (casse capitale)=true -> version mintée ($CASE_NEW_ID)"; } || ko "RetainApplications (casse) : version refusée (HTTP $CASE_CODE)"
fi

fact 1 "bare{newApiVersion} seul=HTTP $BARE_CODE ; retainApplications:true=HTTP $TRUE_CODE ; retainApplications:false=HTTP $FALSE_CODE ; RetainApplications(casse capitale):true=HTTP $CASE_CODE — 4 lignées INDÉPENDANTES (1 seul appel /versions par base, cf. contrainte 'latest version only' notée en tête de script) ; corps complets ci-dessus"

# =============================================================== M2 =========
say "M2 — policies[] et isActive de la nouvelle version (variante 'bare')"
P20="n/a"; ACT20="n/a"
if [ -n "$BARE_NEW_ID" ]; then
  P20=$(apiPolicies "$BARE_NEW_ID"); ACT20=$(apiIsActive "$BARE_NEW_ID")
  info "v2.0 (bare) : policies=$P20 isActive=$ACT20"
  [ "$P20" = "$BASE_POLICIES" ] && ok "v2.0 : mêmes IDs de policy que la base (partage)" \
    || info "v2.0 : IDs de policy DIFFÉRENTS de la base (clone, pas partage) : base=$BASE_POLICIES v2.0=$P20"
fi
fact 2 "policies de la base=$BASE_POLICIES ; v2.0(bare) policies=$P20 isActive=$ACT20"

# =============================================================== M3 =========
say "M3 — la souscription de l'app à chaque base survit-elle à SA duplication ? [DÉCISIF]"
STATE_FINAL=$(appConsumingAPIs)
info "consumingAPIs final (après les 4 mints) : $STATE_FINAL"
HAS_BARE=$(hasID "$STATE_FINAL" "$BARE_NEW_ID")
HAS_TRUE=$(hasID "$STATE_FINAL" "$TRUE_NEW_ID")
HAS_FALSE=$(hasID "$STATE_FINAL" "$FALSE_NEW_ID")
HAS_CASE=$(hasID "$STATE_FINAL" "$CASE_NEW_ID")
info "  bare (pas de flag)      : nouvelle version $BARE_NEW_ID portée par l'app = $HAS_BARE"
info "  retainApplications=true : nouvelle version $TRUE_NEW_ID portée par l'app = $HAS_TRUE"
info "  retainApplications=false: nouvelle version $FALSE_NEW_ID portée par l'app = $HAS_FALSE"
info "  RetainApplications(casse): nouvelle version $CASE_NEW_ID portée par l'app = $HAS_CASE"
for ORIG in "$BARE_BASE_ID" "$TRUE_BASE_ID" "$FALSE_BASE_ID" "$CASE_BASE_ID"; do
  [ -n "$ORIG" ] || continue
  H=$(hasID "$STATE_FINAL" "$ORIG")
  [ "$H" = "true" ] && ok "la base $ORIG reste souscrite (attendu : /versions ne DÉSABONNE pas la base)" \
    || ko "la base $ORIG a DISPARU de consumingAPIs après le mint (inattendu)"
done
fact 3 "bare(pas de flag) porte la nouvelle version=$HAS_BARE ; retainApplications:true porte=$HAS_TRUE ; retainApplications:false porte=$HAS_FALSE ; RetainApplications(casse):true porte=$HAS_CASE — état final consumingAPIs=$STATE_FINAL"

# ============================================================ BONUS =========
# Isoler "numéro déjà existant" de "pas la dernière version" (run #1 avait
# mélangé les deux) : on rappelle /versions sur la DERNIÈRE version connue
# (celle qu'on vient de minter, 2.0) avec un newApiVersion qui existe déjà (2.0
# lui-même) — la vraie forme du cas ambigu que le rôle devra refuser.
say "BONUS — POST /versions sur la DERNIÈRE version, vers un numéro déjà existant"
if [ -n "$BARE_NEW_ID" ]; then
  mintVersion "$BARE_NEW_ID" '{"newApiVersion":"2.0"}'
  BONUS_CODE="$MINT_CODE"; BONUS_ID="$MINT_ID"
  if [ -n "$BONUS_ID" ]; then
    ALL_API_IDS+=("$BONUS_ID")
    ko "BONUS : la gateway accepte un doublon exact de numéro de version (id=$BONUS_ID) — le rôle DOIT refuser lui-même l'ambigu"
    fact "bonus" "POST /versions (depuis la dernière) vers un numéro déjà existant -> HTTP $BONUS_CODE ACCEPTÉ (id=$BONUS_ID) — doublon possible côté produit"
  else
    ok "BONUS : la gateway refuse un numéro de version déjà existant, même appelé depuis la dernière (HTTP $BONUS_CODE)"
    fact "bonus" "POST /versions (depuis la dernière) vers un numéro déjà existant -> HTTP $BONUS_CODE refusé"
  fi
else
  ko "BONUS : sauté — pas de version 'bare' à rappeler"
fi

say "RÉCAPITULATIF des objets créés (teardown dans le trap)"
info "bare  : base=$BARE_BASE_ID  -> version=${BARE_NEW_ID:-refusée}"
info "true  : base=$TRUE_BASE_ID  -> version=${TRUE_NEW_ID:-refusée}"
info "false : base=$FALSE_BASE_ID -> version=${FALSE_NEW_ID:-refusée}"
info "case  : base=$CASE_BASE_ID  -> version=${CASE_NEW_ID:-refusée}"

[ "$FAIL" -eq 0 ] || exit 1
