#!/usr/bin/env bash
# spike-claim-runtime.sh — VOLET B du spike claim/identifier : le MATCHING
# RUNTIME sur wM 10.15. Suite de CARACTÉRISATION : chaque test épingle le
# comportement OBSERVÉ live (2026-07-24) — si un test casse un jour, c'est que
# le produit a changé et que le design doit être re-examiné.
#
# CE QUE LA CAMPAGNE D'ISOLATION A ÉTABLI (et que ce script rejoue) :
#
#   1. Sur le chemin strict/oAuth2Token (le chemin OAuth2 réel du lab), c'est la
#      STRATÉGIE qui identifie l'application : token.azp/client_id == strategy.clientId.
#      L'identifier openIdClaims est DÉCORATIF au runtime (stocké, jamais évalué).
#      → Le volet A (stockage 11/11) ne suffisait pas : stockage ≠ évaluation.
#   2. Un nom de claim ARBITRAIRE (x-spike-claim) n'est évalué NI via un identifier
#      openIdClaims NI via un identifier jwtClaims — ni sur strict/oAuth2Token ni
#      sur open/jwtClaims. « La claim est un paramètre » est donc FAUX au runtime
#      en 10.15 : l'identité, c'est azp/client_id, point.
#   3. La ROTATION 0-coupure est possible — mais par les STRATÉGIES : deux
#      stratégies (clientId ancien + nouveau) attachées à la même application
#      matchent TOUTES LES DEUX simultanément. Ancien et nouveau client vivent
#      ensemble le temps de la bascule.
#   4. PIÈGE D'EXPLOITATION : le RETRAIT n'est pas immédiat. Détacher PUIS
#      supprimer la stratégie laisse le token — MÊME UN TOKEN FRAIS — matcher
#      encore (cache/registre côté gateway). Le cache token->application survit
#      aussi ~quelques secondes à la SUPPRESSION de l'application (rejouer un
#      token déjà présenté rend Application:null). La révocation effective passe par
#      la désactivation du client sur l'IdP ou la suspension de l'application,
#      PAS par le retrait de la stratégie.
#   5. OBSERVATION SÉCURITÉ : en strict/oAuth2Token, un token VALIDE (signature
#      + audience OK) qui ne matche AUCUNE stratégie n'est pas rejeté 401 : il
#      atteint le backend en Application:sys:defaultApplication.
#
# BANC D'ESSAI : l'API accounts-read/1.0.0 (déjà en strict/oAuth2Token, alias
# KeycloakStoaLab) — JAMAIS modifiée, on ne fait qu'y souscrire des applications
# jetables. ORACLE d'identification : le backend mock 404 et la gateway enveloppe
# l'erreur avec Application:<nom identifié> → on lit QUI a matché dans le body.
#
# Assets JETABLES : 3 clients Keycloak spikeclaimb-* + apps/stratégies
# spikeclaimb-* sur la gateway ; tout est détruit en sortie (trap).
#
#   GW_ADMIN=http://localhost:5555/rest/apigateway GW_DATA=http://localhost:5555/gateway \
#   WM_USER=Administrator WM_PASS=manage \
#   KC_BASE=http://localhost:8480 KC_ADMIN_USER=admin KC_ADMIN_PASS=admin \
#   ./scripts/spike-claim-runtime.sh
set -u
GW="${GW_ADMIN:-http://localhost:5555/rest/apigateway}"
DP="${GW_DATA:-http://localhost:5555/gateway}"
AUTH="${WM_USER:-Administrator}:${WM_PASS:-manage}"
KC="${KC_BASE:-http://localhost:8480}"
REALM="${REALM:-stoa-lab}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
AS_ALIAS="${AS_ALIAS:-KeycloakStoaLab}"
API_NAME="${API_NAME:-accounts-read}"
API_VERSION="${API_VERSION:-1.0.0}"
AUDIENCE="${AUDIENCE:-accounts-read}"

CLAIM_NAME=x-spike-claim
CLAIM_VALUE=spikeclaimb-id
C_OLD=spikeclaimb-old      # identité historique (azp=spikeclaimb-old)
C_CLAIM=spikeclaimb-new    # porte la claim custom ; azp ne matche RIEN
C_NEWID=spikeclaimb-id     # azp == clientId de la NOUVELLE stratégie (rotation)
# clientId VIERGE À SUFFIXE UNIQUE pour R2 : le registre runtime garde un mapping
# fantôme azp->app pour tout clientId ayant UN JOUR porté une stratégie supprimée
# (pollution durable, elle survit aux runs précédents — cf. R5). Seul un clientId
# jamais vu garantit d'observer le comportement de l'identifier PUR.
C_VIRGIN="spikeclaimb-virgin-$(date +%s)"

PASS=0; FAIL=0

say()  { printf '\n== %s ==\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
info() { printf '  ·  %s\n' "$*"; }
adm()  { curl -sS -u "$AUTH" -H "Accept: application/json" "$@"; }

# Cleanup AUTO-DÉCOUVRANT par préfixe (pas de tableaux : mkapp/mkstrat tournent
# en sous-shell de command substitution, un ID+= n'atteindrait jamais le parent —
# et la découverte couvre aussi les reliquats d'un run tué en plein vol).
cleanup() {
  say "cleanup (assets jetables, découverte par préfixe spikeclaimb-)"
  adm "$GW/applications" | jq -r '.applications[]? | select(.name|startswith("spikeclaimb-")) | .id + " " + .name' \
  | while read -r ID NAME; do
      C=$(adm -o /dev/null -w '%{http_code}' -X DELETE "$GW/applications/$ID"); info "DELETE app $NAME -> HTTP $C"
    done
  adm "$GW/strategies" | jq -r '(.strategies // [])[] | select(.name|startswith("spikeclaimb-")) | .id + " " + .name' \
  | while read -r ID NAME; do
      C=$(adm -o /dev/null -w '%{http_code}' -X DELETE "$GW/strategies/$ID"); info "DELETE stratégie $NAME -> HTTP $C"
    done
  if [ -n "${KCADM:-}" ]; then
    curl -sS -H "Authorization: Bearer $KCADM" "$KC/admin/realms/$REALM/clients?max=200" \
    | jq -r '.[] | select(.clientId|startswith("spikeclaimb-")) | .id + " " + .clientId' \
    | while read -r U CID; do
        C=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $KCADM" "$KC/admin/realms/$REALM/clients/$U")
        info "DELETE client KC $CID -> HTTP $C"
      done
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- Keycloak ----
# kc_client <clientId> [claimName claimValue] : client confidentiel service-account
# + mapper audience -> $AUDIENCE (+ hardcoded-claim si demandé). UUID sur stdout.
kc_client() {
  local cid="$1" cname="${2:-}" cval="${3:-}" uuid
  uuid=$(curl -sS -H "Authorization: Bearer $KCADM" "$KC/admin/realms/$REALM/clients?clientId=$cid" | jq -r '.[0].id // empty')
  if [ -z "$uuid" ]; then
    curl -sS -o /dev/null -X POST -H "Authorization: Bearer $KCADM" -H "Content-Type: application/json" \
      "$KC/admin/realms/$REALM/clients" -d "{
        \"clientId\": \"$cid\", \"enabled\": true, \"protocol\": \"openid-connect\",
        \"publicClient\": false, \"serviceAccountsEnabled\": true,
        \"standardFlowEnabled\": false, \"directAccessGrantsEnabled\": false}"
    uuid=$(curl -sS -H "Authorization: Bearer $KCADM" "$KC/admin/realms/$REALM/clients?clientId=$cid" | jq -r '.[0].id // empty')
    [ -n "$uuid" ] || return 1
    curl -sS -o /dev/null -X POST -H "Authorization: Bearer $KCADM" -H "Content-Type: application/json" \
      "$KC/admin/realms/$REALM/clients/$uuid/protocol-mappers/models" -d "{
        \"name\": \"aud-$AUDIENCE\", \"protocol\": \"openid-connect\",
        \"protocolMapper\": \"oidc-audience-mapper\",
        \"config\": {\"included.custom.audience\": \"$AUDIENCE\", \"access.token.claim\": \"true\"}}"
    if [ -n "$cname" ]; then
      curl -sS -o /dev/null -X POST -H "Authorization: Bearer $KCADM" -H "Content-Type: application/json" \
        "$KC/admin/realms/$REALM/clients/$uuid/protocol-mappers/models" -d "{
          \"name\": \"hard-$cname\", \"protocol\": \"openid-connect\",
          \"protocolMapper\": \"oidc-hardcoded-claim-mapper\",
          \"config\": {\"claim.name\": \"$cname\", \"claim.value\": \"$cval\",
                       \"jsonType.label\": \"String\", \"access.token.claim\": \"true\"}}"
    fi
  fi
  printf '%s' "$uuid"
}
kc_token() {
  local sec
  sec=$(curl -sS -H "Authorization: Bearer $KCADM" "$KC/admin/realms/$REALM/clients/$2/client-secret" | jq -r '.value // empty')
  curl -sS -d grant_type=client_credentials -d "client_id=$1" -d "client_secret=$sec" \
    "$KC/realms/$REALM/protocol/openid-connect/token" | jq -r '.access_token // empty'
}

# --------------------------------------------------------------- data-plane ---
# ident <token> [api] : « QUI la gateway a-t-elle identifié ? »
#   "app:<nom complet>" (peut être sys:defaultApplication) ou "http:<code>".
ident() {
  local api="${2:-$API_NAME}" body code
  body=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $1" "$DP/$api/$API_VERSION/accounts")
  code=$(printf '%s' "$body" | tail -1)
  local full; full=$(printf '%s' "$body" | grep -oE 'Application:[^",]*' | head -1)
  if [ -n "$full" ]; then printf 'app:%s' "${full#Application:}"; else printf 'http:%s' "$code"; fi
}

# ------------------------------------------------------------------ gateway ---
mkapp() { # mkapp <name> <identifiers-json> <strategyIds-json> <apiId> -> appId
  local id
  id=$(adm -H "Content-Type: application/json" -X POST "$GW/applications" \
    -d "{\"name\":\"$1\",\"description\":\"spike claim runtime (jetable)\",\"contactEmails\":[]}" \
    | jq -r '.id // .application.id // .applications[0].id // empty')
  [ -n "$id" ] || return 1
  local rec
  rec=$(adm "$GW/applications/$id" | jq -c --argjson ids "$2" --argjson s "$3" \
    '(.applications[0] // .) | .identifiers=$ids | .authStrategyIds=$s')
  adm -o /dev/null -H "Content-Type: application/json" -X PUT "$GW/applications/$id" -d "$rec"
  adm -o /dev/null -H "Content-Type: application/json" -X PUT "$GW/applications/$id/apis" -d "{\"apiIDs\":[\"$4\"]}"
  printf '%s' "$id"
}
mkstrat() { # mkstrat <name> <clientId> -> strategyId   (patron du rôle Ansible, mode idp)
  local sid
  sid=$(adm -H "Content-Type: application/json" -X POST "$GW/strategies" -d "{
    \"type\": \"OAUTH2\", \"authServerAlias\": \"$AS_ALIAS\",
    \"name\": \"$1\", \"description\": \"spike claim runtime (jetable)\",
    \"audience\": \"$AUDIENCE\", \"clientId\": \"$2\"}" \
    | jq -r '.strategy.id // .id // empty')
  [ -n "$sid" ] || return 1
  printf '%s' "$sid"
}

# ---------------------------------------------------------------- préambule ---
say "préambule : gateway + Keycloak + banc d'essai strict/oAuth2Token"
[ "$(adm -o /dev/null -w '%{http_code}' "$GW/applications")" = "200" ] || { ko "gateway injoignable ($GW)"; exit 1; }
KCADM=$(curl -sS -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" \
  | jq -r '.access_token // empty')
[ -n "$KCADM" ] || { ko "admin Keycloak injoignable ($KC)"; exit 1; }
API_ID=$(adm "$GW/apis" | jq -r --arg n "$API_NAME" --arg v "$API_VERSION" \
  '.apiResponse[] | select(.api.apiName==$n and .api.apiVersion==$v) | .api.id')
[ -n "$API_ID" ] || { ko "API $API_NAME/$API_VERSION introuvable"; exit 1; }
POL=$(adm "$GW/apis/$API_ID" | jq -r '.apiResponse.api.policies[0] // empty')
IAM=$(adm "$GW/policies/$POL" | jq -r '.policy.policyEnforcements[] | select(.stageKey=="IAM") | .enforcements[0].enforcementObjectId')
CFG=$(adm "$GW/policyActions/$IAM" | jq -c '[.policyAction.parameters[] | select(.templateKey=="IdentificationRule") | .parameters[] | {(.templateKey): .values[0]}] | add')
info "IAM de $API_NAME/$API_VERSION : $CFG"
printf '%s' "$CFG" | grep -q '"applicationLookup":"strict"' && printf '%s' "$CFG" | grep -q '"identificationType":"oAuth2Token"' \
  && ok "banc d'essai valide (strict + oAuth2Token — l'API n'est jamais modifiée)" \
  || { ko "l'API n'est pas en strict/oAuth2Token"; exit 1; }

say "setup KC : 4 clients jetables"
U_OLD=$(kc_client "$C_OLD")
U_CLAIM=$(kc_client "$C_CLAIM" "$CLAIM_NAME" "$CLAIM_VALUE")
U_NEWID=$(kc_client "$C_NEWID")
U_VIRGIN=$(kc_client "$C_VIRGIN")
[ -n "$U_OLD" ] && [ -n "$U_CLAIM" ] && [ -n "$U_NEWID" ] && [ -n "$U_VIRGIN" ] || { ko "création clients KC"; exit 1; }
T_OLD=$(kc_token "$C_OLD" "$U_OLD"); T_CLAIM=$(kc_token "$C_CLAIM" "$U_CLAIM"); T_NEWID=$(kc_token "$C_NEWID" "$U_NEWID"); T_VIRGIN=$(kc_token "$C_VIRGIN" "$U_VIRGIN")
[ -n "$T_OLD" ] && [ -n "$T_CLAIM" ] && [ -n "$T_NEWID" ] && [ -n "$T_VIRGIN" ] || { ko "obtention des tokens"; exit 1; }
HASCLAIM=$(printf '%s' "$T_CLAIM" | cut -d. -f2 | tr '_-' '/+' \
  | { P=$(cat); L=$(( ${#P} % 4 )); [ $L -gt 0 ] && P="$P$(printf '=%.0s' $(seq $((4-L))))"; printf '%s' "$P"; } \
  | base64 -d 2>/dev/null | jq -r --arg c "$CLAIM_NAME" '.[$c] // empty')
[ "$HASCLAIM" = "$CLAIM_VALUE" ] && ok "clients OK ($C_OLD ; $C_CLAIM porte $CLAIM_NAME=$CLAIM_VALUE ; $C_NEWID)" \
  || { ko "le token $C_CLAIM ne porte pas la claim custom"; exit 1; }

# ---- R2 : l'identifier openIdClaims SEUL est décoratif + fallthrough sys ------
# JOUÉ EN PREMIER, AVANT toute création de stratégie sur ce clientId : une
# stratégie SUPPRIMÉE laisse un mapping fantôme azp->app dans le registre
# runtime (rend "Application:null", même avec un token frais — cf. R5). Le seul
# moyen d'observer l'identifier PUR est un clientId encore vierge de stratégie.
say "R2 — identifier openIdClaims/azp SEUL (aucune stratégie, clientId vierge) : token azp=$C_VIRGIN"
A2=$(mkapp spikeclaimb-r2 "[{\"key\":\"openIdClaims\",\"name\":\"azp\",\"value\":[\"$C_VIRGIN\"]}]" '[]' "$API_ID"); sleep 2
R=$(ident "$T_VIRGIN"); info "verdict : $R"
if [ "$R" = "app:sys:defaultApplication" ]; then
  ok "R2 l'identifier seul n'identifie PAS (décoratif au runtime — le volet A ne le voyait pas)"
  ok "R2bis OBSERVATION SÉCURITÉ : token valide non matché -> backend en sys:defaultApplication (pas de 401, strict ou pas)"
else
  ko "R2 attendu app:sys:defaultApplication, obtenu $R — le comportement du produit a changé, re-caractériser"
fi
adm -o /dev/null -X DELETE "$GW/applications/$A2"

# ---- R1 : le mécanisme réel — la STRATÉGIE identifie, sans aucun identifier ---
say "R1 — stratégie SEULE (aucun identifier) : token azp=$C_OLD"
S1=$(mkstrat spikeclaimb-strat-r1 "$C_OLD")
A1=$(mkapp spikeclaimb-r1 '[]' "[\"$S1\"]" "$API_ID"); sleep 2
R=$(ident "$T_OLD"); info "verdict : $R"
[ "$R" = "app:spikeclaimb-r1" ] \
  && ok "R1 identifiée par la SEULE stratégie — le matching est token.azp/client_id == strategy.clientId" \
  || ko "R1 attendu app:spikeclaimb-r1, obtenu $R"
adm -o /dev/null -X DELETE "$GW/applications/$A1"; adm -o /dev/null -X DELETE "$GW/strategies/$S1"


# ---- R3 : un nom de claim arbitraire n'est JAMAIS évalué ----------------------
say "R3 — claim custom $CLAIM_NAME : identifiers openIdClaims PUIS jwtClaims (token la portant)"
for KEY in openIdClaims jwtClaims; do
  A3=$(mkapp "spikeclaimb-r3-$KEY" "[{\"key\":\"$KEY\",\"name\":\"$CLAIM_NAME\",\"value\":[\"$CLAIM_VALUE\"]}]" '[]' "$API_ID"); sleep 2
  T_R3=$(kc_token "$C_CLAIM" "$U_CLAIM")   # frais : jamais rejouer un token à travers une suppression
  R=$(ident "$T_R3"); info "identifier $KEY/$CLAIM_NAME : $R"
  [ "$R" = "app:sys:defaultApplication" ] \
    && ok "R3 clé $KEY : la claim custom n'est PAS évaluée — « la claim est un paramètre » est FAUX au runtime 10.15" \
    || ko "R3 clé $KEY : attendu app:sys:defaultApplication, obtenu $R"
  adm -o /dev/null -X DELETE "$GW/applications/$A3"
done

# ---- R4 : la rotation 0-coupure RÉELLE — deux stratégies simultanées ----------
say "R4 — rotation ADDITIVE : stratégies clientId=$C_OLD ET clientId=$C_NEWID sur la même app"
S_A=$(mkstrat spikeclaimb-strat-old "$C_OLD")
S_B=$(mkstrat spikeclaimb-strat-new "$C_NEWID")
A4=$(mkapp spikeclaimb-r4 '[]' "[\"$S_A\",\"$S_B\"]" "$API_ID"); sleep 2
T_OLD=$(kc_token "$C_OLD" "$U_OLD"); T_NEWID=$(kc_token "$C_NEWID" "$U_NEWID")   # frais (cf. R2)
R=$(ident "$T_OLD");   info "token ANCIEN  (azp=$C_OLD)  : $R"
[ "$R" = "app:spikeclaimb-r4" ] && ok "R4a l'ANCIENNE identité matche" || ko "R4a attendu app:spikeclaimb-r4, obtenu $R"
R=$(ident "$T_NEWID"); info "token NOUVEAU (azp=$C_NEWID) : $R"
[ "$R" = "app:spikeclaimb-r4" ] && ok "R4b la NOUVELLE identité matche AUSSI — recouvrement actif, bascule 0-coupure possible" \
  || ko "R4b attendu app:spikeclaimb-r4, obtenu $R"

# ---- R5 : le PIÈGE du retrait — pas de révocation immédiate -------------------
say "R5 — retrait : détacher + SUPPRIMER la stratégie ancienne, puis token FRAIS"
REC=$(adm "$GW/applications/$A4" | jq -c --arg s "$S_B" '(.applications[0] // .) | .authStrategyIds=[$s]')
adm -o /dev/null -H "Content-Type: application/json" -X PUT "$GW/applications/$A4" -d "$REC"
adm -o /dev/null -X DELETE "$GW/strategies/$S_A"
sleep 3
T_FRESH=$(kc_token "$C_OLD" "$U_OLD")
R=$(ident "$T_FRESH"); info "token FRAIS azp=$C_OLD après détach+DELETE : $R"
if [ "$R" = "app:spikeclaimb-r4" ]; then
  ok "R5 PIÈGE CONFIRMÉ : même un token FRAIS matche encore (cache/registre) — le retrait de stratégie N'EST PAS une révocation"
  info "   → révocation effective = désactiver le client sur l'IdP, ou suspendre l'application (PATCH)"
else
  ko "R5 attendu app:spikeclaimb-r4 (cache), obtenu $R — le produit invalide désormais ? re-caractériser la fenêtre"
fi
R=$(ident "$T_NEWID"); info "token NOUVEAU après retrait de l'ancienne : $R"
[ "$R" = "app:spikeclaimb-r4" ] && ok "R5bis la nouvelle identité survit au retrait de l'ancienne" \
  || ko "R5bis attendu app:spikeclaimb-r4, obtenu $R"

# -------------------------------------------------------------------- verdict -
say "VERDICT (runtime, à rapprocher du volet A stockage)"
cat <<'TXT'
  1. L'identité runtime d'une application OAuth2 externe = la STRATÉGIE
     (token.azp/client_id == strategy.clientId). L'identifier openIdClaims est
     décoratif ; un nom de claim custom n'est jamais évalué (ni openIdClaims ni
     jwtClaims). « La claim est un paramètre » ne vaut que pour le STOCKAGE.
  2. Bascule/rotation 0-coupure : par DEUX STRATÉGIES simultanées (ancien +
     nouveau clientId), pas par les identifiers. Additif prouvé.
  3. Retrait ≠ révocation : après détach+DELETE de la stratégie, un token frais
     matche encore (cache). Révoquer = désactiver le client IdP / suspendre l'app.
  4. Sécurité : token valide non matché -> sys:defaultApplication atteint le
     backend (pas de 401). L'opposabilité par app exige de fermer ce défaut.
TXT

say "RÉSULTAT : $PASS/$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
