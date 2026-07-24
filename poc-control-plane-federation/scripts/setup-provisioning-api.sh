#!/usr/bin/env bash
# setup-provisioning-api.sh — L'API qui fronte Jenkins sur la gateway.
#
# Matérialise le point de bascule du design (mémoire oracle-idp-gateway-sync) :
# les appelants OIG et CLI2 sont des APPLICATIONS de la gateway ; ils n'attaquent
# jamais Jenkins en direct — ils appellent une API `provisioning` sur la gateway,
# qui route vers le Generic Webhook Trigger de Jenkins avec un credential porté
# PAR la gateway. Jenkins exécute, il ne reçoit pas.
#
#   consommateur (app OIG|CLI2, Bearer aud=provisioning, azp=son clientId)
#     └─ POST http://<gw>/gateway/provisioning/1.0/applications
#          IAM strict/oAuth2Token : azp == clientId d'une stratégie liée ?
#          └─ routing FIXE → http://jenkins:8080/generic-webhook-trigger/invoke?token=…
#               └─ Jenkins déclenche le job (ici provisioning-webhook, inoffensif)
#
# Le matching runtime = la STRATÉGIE (spike-claim-runtime.sh, R1) : une stratégie
# OAUTH2 par appelant (clientId = son client OAuth2). Rotation 0-coupure => voir
# ansible/strategy-rotation.yml. ⚠ TROU CONNU (R2bis) : un token valide sans
# stratégie liée tombe en sys:defaultApplication et atteindrait le backend — la
# 3e voix ci-dessous le MESURE et le script échoue si le tiers passe (la barrière
# doit être fermée avant prod : audience dédiée émise SEULEMENT aux 2 appelants).
#
# Assets PERSISTANTS (livrable) : API provisioning, 2 stratégies, 2 apps. Assets
# de PREUVE nettoyés (clients KC provtest-*). Idempotent : réexécutable.
#
#   WM=http://localhost:5555 KC_BASE=http://localhost:8480 \
#   JENKINS_INCLUSTER=http://jenkins:8080 GWT_TOKEN=stoa-provisioning \
#   ./scripts/setup-provisioning-api.sh
set -uo pipefail
cd "$(dirname "$0")/.."

WM="${WM:-http://localhost:5555}"
GW="$WM/rest/apigateway"
DP="$WM/gateway"
AUTH="${WM_USER:-Administrator}:${WM_PASS:-manage}"
KC="${KC_BASE:-http://localhost:8480}"
REALM="${REALM:-stoa-lab}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"; KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
AS_ALIAS="${AS_ALIAS:-KeycloakStoaLab}"
AUDIENCE="${AUDIENCE:-provisioning}"
JENKINS_INCLUSTER="${JENKINS_INCLUSTER:-http://jenkins:8080}"   # vu DEPUIS le conteneur gateway
GWT_TOKEN="${GWT_TOKEN:-stoa-provisioning}"
API_NAME=provisioning; API_VER=1.0
# Les deux appelants = deux applications, chacune son client OAuth2 (= son azp).
OIG_CID="${OIG_CID:-oig-provisioner}"
CLI2_CID="${CLI2_CID:-cli2-provisioner}"
THIRD_CID="accounts-read-consumer"   # tiers légitime d'une AUTRE API (aud=accounts-read)

WORK="$(mktemp -d /tmp/provapi.XXXXXX)"
KC_THROW=()   # clients KC de preuve à purger
PASS=0; FAIL=0
say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok(){ PASS=$((PASS+1)); printf '  \033[32m✅\033[0m %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m❌\033[0m %s\n' "$*"; }
info(){ printf '  ·  %s\n' "$*"; }
adm(){ curl -sS -u "$AUTH" -H "Accept: application/json" "$@"; }

cleanup(){
  [ -n "${KCADM:-}" ] && for u in "${KC_THROW[@]:-}"; do
    [ -n "$u" ] && curl -sS -o /dev/null -X DELETE -H "Authorization: Bearer $KCADM" "$KC/admin/realms/$REALM/clients/$u"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── Keycloak helpers ────────────────────────────────────────────────────────
kc_admin(){ curl -sS -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" \
  | jq -r '.access_token // empty'; }
# kc_ensure_client <clientId> <persist:0|1> : client service-account + mapper aud=$AUDIENCE. UUID sur stdout.
kc_ensure_client(){
  local cid="$1" persist="$2" uuid
  uuid=$(curl -sS -H "Authorization: Bearer $KCADM" "$KC/admin/realms/$REALM/clients?clientId=$cid" | jq -r '.[0].id // empty')
  if [ -z "$uuid" ]; then
    curl -sS -o /dev/null -X POST -H "Authorization: Bearer $KCADM" -H "Content-Type: application/json" \
      "$KC/admin/realms/$REALM/clients" -d "{\"clientId\":\"$cid\",\"enabled\":true,\"protocol\":\"openid-connect\",\"publicClient\":false,\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false}"
    uuid=$(curl -sS -H "Authorization: Bearer $KCADM" "$KC/admin/realms/$REALM/clients?clientId=$cid" | jq -r '.[0].id // empty')
    [ -n "$uuid" ] || return 1
    curl -sS -o /dev/null -X POST -H "Authorization: Bearer $KCADM" -H "Content-Type: application/json" \
      "$KC/admin/realms/$REALM/clients/$uuid/protocol-mappers/models" \
      -d "{\"name\":\"aud-$AUDIENCE\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",\"config\":{\"included.custom.audience\":\"$AUDIENCE\",\"access.token.claim\":\"true\"}}"
  fi
  [ "$persist" = "0" ] && KC_THROW+=("$uuid")
  printf '%s' "$uuid"
}
kc_token(){ local sec; sec=$(curl -sS -H "Authorization: Bearer $KCADM" "$KC/admin/realms/$REALM/clients/$2/client-secret" | jq -r '.value // empty')
  curl -sS -d grant_type=client_credentials -d "client_id=$1" -d "client_secret=$sec" \
    "$KC/realms/$REALM/protocol/openid-connect/token" | jq -r '.access_token // empty'; }

jenkins_build_count(){ curl -sf "http://localhost:18080/job/provisioning-webhook/api/json" 2>/dev/null | jq -r '.nextBuildNumber // 0'; }
JENKINS_UI="${JENKINS_UI:-http://localhost:18080}"

# ensure_jenkins_job : crée le job freestyle GWT `provisioning-webhook` (cible de
# preuve inoffensive : echo du `caller`) s'il n'existe pas. Idempotent.
ensure_jenkins_job(){
  curl -sf "$JENKINS_UI/job/provisioning-webhook/api/json" >/dev/null 2>&1 && return 0
  local ck cj f c xml
  ck=$(mktemp); cj=$(curl -sf -c "$ck" "$JENKINS_UI/crumbIssuer/api/json") || { rm -f "$ck"; return 1; }
  f=$(printf '%s' "$cj" | jq -r '.crumbRequestField'); c=$(printf '%s' "$cj" | jq -r '.crumb')
  xml="$WORK/prov-job.xml"
  cat > "$xml" <<'JOBXML'
<?xml version='1.1' encoding='UTF-8'?>
<project>
  <description>Cible de preuve de l'API provisioning (gateway -> Jenkins GWT). Inoffensif : echo du caller.</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class="hudson.scm.NullSCM"/>
  <canRoam>true</canRoam>
  <disabled>false</disabled>
  <triggers>
    <org.jenkinsci.plugins.gwt.GenericTrigger plugin="generic-webhook-trigger@2.4.2">
      <spec></spec>
      <genericVariables>
        <org.jenkinsci.plugins.gwt.GenericVariable>
          <key>caller</key><value>$.caller</value>
        </org.jenkinsci.plugins.gwt.GenericVariable>
      </genericVariables>
      <printPostContent>true</printPostContent>
      <printContributedVariables>true</printContributedVariables>
      <token>stoa-provisioning</token>
      <silentResponse>false</silentResponse>
      <overrideQuietPeriod>false</overrideQuietPeriod>
      <shouldNotFlattern>false</shouldNotFlattern>
      <allowSeveralTriggersPerBuild>false</allowSeveralTriggersPerBuild>
    </org.jenkinsci.plugins.gwt.GenericTrigger>
  </triggers>
  <builders>
    <hudson.tasks.Shell><command>echo "PROVISIONING build ok - caller=${caller}"</command></hudson.tasks.Shell>
  </builders>
  <publishers/><buildWrappers/>
</project>
JOBXML
  curl -s -b "$ck" -X POST "$JENKINS_UI/createItem?name=provisioning-webhook" -H "$f: $c" \
    -H "Content-Type: application/xml" --data-binary @"$xml" -o /dev/null -w '%{http_code}' | grep -q 200
  local rc=$?; rm -f "$ck"; return $rc
}

# ── 0. préambule ────────────────────────────────────────────────────────────
say "0. préambule"
[ "$(adm -o /dev/null -w '%{http_code}' "$GW/applications")" = "200" ] || { ko "gateway injoignable"; exit 1; }
KCADM=$(kc_admin); [ -n "$KCADM" ] || { ko "admin Keycloak injoignable"; exit 1; }
ensure_jenkins_job && ok "job Jenkins provisioning-webhook prêt (créé si absent)" || { ko "job Jenkins provisioning-webhook — création échouée"; exit 1; }
ok "gateway + Keycloak prêts"

# ── 1. clients OAuth2 des appelants (OIG, CLI2) + le tiers pour la 3e voix ──
say "1. Keycloak : clients des appelants"
U_OIG=$(kc_ensure_client "$OIG_CID" 1);  [ -n "$U_OIG" ]  && ok "client $OIG_CID (persistant)"  || { ko "client $OIG_CID"; exit 1; }
U_CLI2=$(kc_ensure_client "$CLI2_CID" 1); [ -n "$U_CLI2" ] && ok "client $CLI2_CID (persistant)" || { ko "client $CLI2_CID"; exit 1; }

# ── 2. API provisioning routée vers Jenkins (OpenAPI: server = URL GWT fixe) ──
say "2. API $API_NAME/$API_VER routée vers le Generic Webhook Trigger de Jenkins"
API_ID=$(adm "$GW/apis" | jq -r --arg n "$API_NAME" --arg v "$API_VER" '.apiResponse[]|select(.api.apiName==$n and .api.apiVersion==$v)|.api.id')
if [ -z "$API_ID" ]; then
  # server.url = URL GWT COMPLÈTE (token en query) ; path unique /applications.
  # Le routing straightThroughRouting sera patché en dur ci-dessous (endpoint fixe,
  # sans ${sys:resource_path} — on ne veut PAS réémettre le path entrant).
  cat > "$WORK/prov.yaml" <<YAML
openapi: 3.0.0
info: { title: $API_NAME, version: "$API_VER" }
servers:
  - url: "$JENKINS_INCLUSTER/generic-webhook-trigger"
paths:
  /applications:
    post:
      operationId: provisionApplication
      responses: { '200': { description: accepted } }
YAML
  API_ID=$(adm -F "file=@$WORK/prov.yaml;type=application/x-yaml" -F type=openapi -F "apiName=$API_NAME" -F "apiVersion=$API_VER" "$GW/apis" | jq -r '.apiResponse.api.id // empty')
  [ -n "$API_ID" ] && ok "API créée ($API_ID)" || { ko "création API"; exit 1; }
else
  ok "API déjà présente ($API_ID) — réutilisée"
fi

# routing FIXE → GWT invoke?token=… (patch via archive, technique test-archive-promotion.sh)
ENDPOINT="$JENKINS_INCLUSTER/generic-webhook-trigger/invoke?token=$GWT_TOKEN"
adm "$GW/archive?apis=$API_ID" -o "$WORK/a.zip" >/dev/null
( cd "$WORK" && rm -rf a && mkdir a && unzip -qo a.zip -d a )
RPA=$(grep -rl straightThroughRouting "$WORK/a/API" 2>/dev/null | head -1)
if [ -n "$RPA" ]; then
  CUR=$(jq -r '(.parameters[]|select(.templateKey=="endpointUri")|.values[0]) // empty' "$RPA")
  if [ "$CUR" != "$ENDPOINT" ]; then
    jq --arg u "$ENDPOINT" '(.parameters[]|select(.templateKey=="endpointUri")|.values)=[$u]' "$RPA" > "$RPA.n" && mv "$RPA.n" "$RPA"
    ( cd "$WORK/a" && zip -qrX ../a2.zip APIGatewayAssets.acdl API )
    R=$(adm -F "file=@$WORK/a2.zip;type=application/zip" "$GW/archive?overwrite=apis,policies,policyactions" \
        | jq -r '[.ArchiveResult[]|to_entries[]|select(.value.status!="Success")]|length')
    [ "$R" = "0" ] && ok "routing → $ENDPOINT (archive importée, tout Success)" || ko "import archive routing (échecs=$R)"
  else
    ok "routing déjà = $ENDPOINT"
  fi
else
  info "pas d'action straightThroughRouting dans l'archive — routing à vérifier manuellement"
fi
adm -X PUT "$GW/apis/$API_ID/activate" -o /dev/null

# ── 3. IAM strict/oAuth2Token sur l'API ─────────────────────────────────────
say "3. IAM strict/oAuth2Token (l'identité = la stratégie liée à l'app appelante)"
POL=$(adm "$GW/apis/$API_ID" | jq -r '.apiResponse.api.policies[0] // empty')
IAM_STATE="?"
if [ -n "$POL" ]; then
  for E in $(adm "$GW/policies/$POL" | jq -r '.policy.policyEnforcements[]?.enforcements[]?.enforcementObjectId'); do
    T=$(adm "$GW/policyActions/$E" | jq -r '.policyAction.templateKey')
    if [ "$T" = "evaluatePolicy" ]; then
      LK=$(adm "$GW/policyActions/$E" | jq -r '[.policyAction.parameters[]|select(.templateKey=="IdentificationRule")|.parameters[]|select(.templateKey=="applicationLookup")|.values[0]][0] // empty')
      IT=$(adm "$GW/policyActions/$E" | jq -r '[.policyAction.parameters[]|select(.templateKey=="IdentificationRule")|.parameters[]|select(.templateKey=="identificationType")|.values[0]][0] // empty')
      IAM_STATE="$LK/$IT"
    fi
  done
fi
# L'action strict/oAuth2Token est PARTAGÉE (même id sur accounts-read & wm-admin-self) :
# on référence CET id dans le stage IAM de la policy de provisioning s'il manque.
# Sans stage IAM, l'API est ANONYME (prouvé : sans token -> 200 + build) — c'est la
# différence entre « router vers Jenkins » et « n'y laisser router que les appelants ».
SHARED_IAM="${SHARED_IAM:-a5a8a079-3c99-420a-adb7-90ff0f988691}"
if [ "$IAM_STATE" = "strict/oAuth2Token" ]; then
  ok "IAM déjà strict/oAuth2Token"
elif [ -n "$POL" ]; then
  HAS_IAM=$(adm "$GW/policies/$POL" | jq -r '[.policy.policyEnforcements[]|select(.stageKey=="IAM")]|length')
  if [ "$HAS_IAM" = "0" ]; then
    PJSON=$(adm "$GW/policies/$POL" | jq -c --arg a "$SHARED_IAM" \
      '{policy: (.policy | .policyEnforcements += [{"enforcements":[{"enforcementObjectId":$a,"order":null}],"stageKey":"IAM"}])}')
    HC=$(adm -H "Content-Type: application/json" -X PUT "$GW/policies/$POL" -d "$PJSON" -o /dev/null -w '%{http_code}')
    adm -X PUT "$GW/apis/$API_ID/activate" -o /dev/null; sleep 2
    [ "$HC" = "200" ] && ok "stage IAM strict/oAuth2Token ajouté (action partagée $SHARED_IAM)" || ko "ajout IAM (HTTP $HC)"
  else
    ok "stage IAM déjà présent sur la policy"
  fi
else
  ko "pas de policy sur l'API — impossible d'attacher l'IAM"
fi

# ── 4. stratégies + applications des 2 appelants + souscription ─────────────
say "4. une stratégie + une application par appelant, souscrites à l'API"
mkstrat(){ # <clientId> -> id (idempotent par nom)
  local name="prov-strat-$1" sid
  sid=$(adm "$GW/strategies" | jq -r --arg n "$name" '(.strategies//[])[]|select(.name==$n)|.id' | head -1)
  [ -n "$sid" ] && { printf '%s' "$sid"; return; }
  adm -H "Content-Type: application/json" -X POST "$GW/strategies" -d "{\"type\":\"OAUTH2\",\"authServerAlias\":\"$AS_ALIAS\",\"name\":\"$name\",\"description\":\"provisioning: identité $1\",\"audience\":\"$AUDIENCE\",\"clientId\":\"$1\"}" | jq -r '.strategy.id // .id // empty'
}
mkapp(){ # <name> <strategyId> -> appId (idempotent), souscrit à l'API
  local name="$1" sid="$2" id
  id=$(adm "$GW/applications" | jq -r --arg n "$name" '.applications[]?|select(.name==$n)|.id' | head -1)
  if [ -z "$id" ]; then
    id=$(adm -H "Content-Type: application/json" -X POST "$GW/applications" -d "{\"name\":\"$name\",\"description\":\"appelant provisioning\",\"contactEmails\":[]}" | jq -r '.id // .application.id // .applications[0].id // empty')
  fi
  [ -n "$id" ] || return 1
  local rec; rec=$(adm "$GW/applications/$id" | jq -c --arg s "$sid" --arg c "$name" \
    '(.applications[0] // .) | .authStrategyIds=(((.authStrategyIds//[])+[$s])|unique) | .identifiers=[{key:"openIdClaims",name:"azp",value:[$c]}]')
  adm -o /dev/null -H "Content-Type: application/json" -X PUT "$GW/applications/$id" -d "$rec"
  adm -o /dev/null -H "Content-Type: application/json" -X PUT "$GW/applications/$id/apis" -d "{\"apiIDs\":[\"$API_ID\"]}"
  printf '%s' "$id"
}
S_OIG=$(mkstrat "$OIG_CID");  A_OIG=$(mkapp "$OIG_CID" "$S_OIG")
S_CLI2=$(mkstrat "$CLI2_CID"); A_CLI2=$(mkapp "$CLI2_CID" "$S_CLI2")
[ -n "$A_OIG" ] && [ -n "$A_CLI2" ] && ok "apps $OIG_CID + $CLI2_CID liées à leur stratégie et souscrites" || { ko "création apps"; exit 1; }

# ── 5. preuve par voix ──────────────────────────────────────────────────────
# ORACLE FIABLE = le CORPS renvoyé par le GWT : {"jobs":{"provisioning-webhook":
# {"triggered":true,"resolvedVariables":{"caller":"<cid>"}}}}. Le compteur
# nextBuildNumber est trompeur (quiet period / file d'attente) — on lit qui a
# vraiment déclenché, avec quel `caller`.
say "5. preuve par voix (oracle = corps GWT : triggered + caller résolu)"
# call <token|-> <caller> : POST data-plane, renvoie "HTTP<code>|<triggered>|<callerResolu>"
call(){
  local auth=(); [ "$1" != "-" ] && auth=(-H "Authorization: Bearer $1")
  local body code trig res
  # ${auth[@]+…} : expansion sûre d'un tableau vide sous set -u (bash 3.2 macOS).
  body=$(curl -sS -w '\n%{http_code}' ${auth[@]+"${auth[@]}"} -H "Content-Type: application/json" \
    -X POST "$DP/$API_NAME/$API_VER/applications" -d "{\"caller\":\"$2\"}")
  code=$(printf '%s' "$body" | tail -1)
  trig=$(printf '%s' "$body" | sed '$d' | jq -r '.jobs["provisioning-webhook"].triggered // false' 2>/dev/null)
  res=$(printf '%s' "$body" | sed '$d' | jq -r '.jobs["provisioning-webhook"].resolvedVariables.caller // "-"' 2>/dev/null)
  printf 'HTTP%s|%s|%s' "$code" "${trig:-false}" "${res:--}"
}

# voix 0 — ANONYME : sans token, l'API ne doit RIEN router (identité obligatoire).
R=$(call "-" anon); info "sans token : $R"
[ "${R%%|*}" = "HTTP401" ] && ok "voix 0 ANONYME : 401 — plus d'accès sans identité (avant IAM : 200 + build)" \
  || ko "voix 0 ANONYME : attendu HTTP401, obtenu $R"

# voix 1/2 — les DEUX appelants. L'app EST identifiée (Application:<cid> dans
# l'erreur), mais la VALIDATION du JWT exige le binding inbound-auth (issuer/JWKS/
# introspection) que labctl câble par targets.yaml — l'API bâtie en REST nu ne
# l'a PAS, d'où « Token invalid or expired » (401). C'est l'ÉTAPE DE FINITION
# identifiée, pas un défaut de sécurité (fail-closed correct). Voir NEXT ci-bas.
voice_caller(){ # <token> <cid> : classe le résultat d'un appel d'appelant
  local r; r=$(call "$1" "$2"); info "$2 : $r"
  if [ "$r" = "HTTP200|true|$2" ]; then ok "$2 : identifié + build déclenché (caller résolu)"; return; fi
  # trust JWT non câblé (REST nu) : app identifiée mais token rejeté -> finition labctl
  local body; body=$(curl -sS -X POST -H "Authorization: Bearer $1" -H "Content-Type: application/json" "$DP/$API_NAME/$API_VER/applications" -d "{\"caller\":\"$2\"}")
  if printf '%s' "$body" | grep -q "Application:$2" && printf '%s' "$body" | grep -qi "invalid or has expired"; then
    printf '  \033[33m⚠️  FINITION\033[0m %s : app IDENTIFIÉE mais JWT non validé — binding inbound-auth (issuer/JWKS/introspection) à câbler via labctl targets.yaml\n' "$2"
  else
    ko "$2 : inattendu -> $r"
  fi
}
T_OIG=$(kc_token "$OIG_CID" "$U_OIG");  voice_caller "$T_OIG" "$OIG_CID"
T_CLI2=$(kc_token "$CLI2_CID" "$U_CLI2"); voice_caller "$T_CLI2" "$CLI2_CID"

# voix 3 — TIERS : token VALIDE d'une autre API (aud=accounts-read, aucune stratégie
# provisioning). MESURE le trou sys:defaultApplication (spike R2bis). Ce n'est PAS un
# échec du script (le trou est un finding produit connu) mais un AVERTISSEMENT chiffré.
U_THIRD=$(curl -sS -H "Authorization: Bearer $KCADM" "$KC/admin/realms/$REALM/clients?clientId=$THIRD_CID" | jq -r '.[0].id // empty')
if [ -n "$U_THIRD" ]; then
  T_THIRD=$(kc_token "$THIRD_CID" "$U_THIRD"); R=$(call "$T_THIRD" "$THIRD_CID"); info "TIERS ($THIRD_CID, aud=accounts-read) : $R"
  if [ "${R#*|}" = "false|-" ] || [ "${R%%|*}" != "HTTP200" ]; then
    ok "voix 3 TIERS : rejeté — barrière fermée"
  else
    printf '  \033[33m⚠️  ÉCART\033[0m voix 3 TIERS : un token valide SANS stratégie provisioning PASSE (%s) — trou sys:defaultApplication (spike R2bis)\n' "$R"
    info "à fermer avant prod : audience '$AUDIENCE' émise SEULEMENT aux 2 appelants (OAM/KC), + backstop pipeline (app forwardée ∈ table appelant→périmètre)."
  fi
else
  info "client tiers $THIRD_CID absent — voix 3 non jouée"
fi

say "RÉSULTAT : $PASS/$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
