#!/usr/bin/env bash
# setup-provisioning-api.sh — L'API qui fronte Jenkins sur la gateway (E2E câblé).
#
# Matérialise le point de bascule du design (mémoire oracle-idp-gateway-sync) :
# OIG et CLI2 sont des APPLICATIONS de la gateway ; ils n'attaquent jamais Jenkins
# en direct — ils appellent une API `provisioning` qui route vers le Generic
# Webhook Trigger de Jenkins avec un credential porté PAR la gateway.
#
#   app (Bearer KC, aud=provisioning, scope=provision, azp=son clientId)
#     └─ POST http://<gw>/gateway/provisioning/1.0/applications
#          IAM strict/oAuth2Token + SCOPE provision  (barrière opposable trial)
#          └─ routing FIXE → http://jenkins:8080/generic-webhook-trigger/invoke?token=…
#               └─ Jenkins déclenche provisioning-webhook (inoffensif, echo caller)
#
# CÂBLAGE = labctl (pas du REST nu — qui laissait le JWT non validé) :
#   apply     -f <manifest>  : publie le contrat + câble l'inbound-auth (authServer
#                              alias KeycloakStoaLab + IAM strict/oAuth2Token)
#   subscribe -f <manifest>  : par appelant, mint KC client + audience mapper +
#                              default scope `provision` + stratégie OAUTH2 + app
#                              + identifier azp + souscription
# Puis archive-patch du routing → GWT invoke?token= (le token GWT vit en query,
# hors contrat) ; l'API route sinon vers backendUrl nu.
#
# BARRIÈRE (spike-claim-runtime R2bis) : sur le trial 10.15 l'AUDIENCE est
# fail-open (introspection distante INERTE, cf. targets.yaml). La barrière qui
# TIENT = le SCOPE `provision`, accordé aux SEULS appelants : un token valide
# d'une autre API (aud=accounts-read, sans ce scope) est rejeté 401. Hors trial,
# l'introspection ferme AUSSI l'audience — sans changer une ligne du manifeste.
#
# Idempotent (apply/subscribe convergent, le job se crée s'il manque).
#
#   ./scripts/setup-provisioning-api.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

WM="${WM:-http://localhost:5555}"
GW="$WM/rest/apigateway"
DP="$WM/gateway"
AUTH="${WM_USER:-Administrator}:${WM_PASS:-manage}"
KC="${KC_BASE:-http://localhost:8480}"
REALM="${REALM:-stoa-lab}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"; KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
JENKINS_UI="${JENKINS_UI:-http://localhost:18080}"
JENKINS_INCLUSTER="${JENKINS_INCLUSTER:-http://jenkins:8080}"
# Cible RÉELLE : le job self-service (webhook stoa-selfservice-plan = PLAN-only,
# lecture seule, identité de job — l'apply nominatif reste un build paramétré
# séparé, ADR-078 §2 : un webhook ne porte AUCUN humain). Le job de preuve
# inoffensif `provisioning-webhook` (token stoa-provisioning) reste disponible
# pour un smoke-test isolé : GWT_TOKEN=stoa-provisioning TARGET_JOB=provisioning-webhook.
GWT_TOKEN="${GWT_TOKEN:-stoa-selfservice-plan}"
TARGET_JOB="${TARGET_JOB:-selfservice-app-deploy}"
# Manifeste porté par le body de la demande (mappé $.manifest -> MANIFEST par le
# GWT du job) : en réel, l'appelant (OIG/CLI2) POSTe SA demande.
PROOF_MANIFEST="${PROOF_MANIFEST:-clients/_example/applications/demo-consumer-idp.ansible.yml}"
API_NAME=provisioning; API_VER=1.0
MANIFEST="${MANIFEST:-gateways/webmethods/provisioning/targets.provisioning.yaml}"
OIG_CID="${OIG_CID:-oig-provisioner}"
CLI2_CID="${CLI2_CID:-cli2-provisioner}"
THIRD_CID="${THIRD_CID:-accounts-read-consumer}"   # tiers légitime d'une AUTRE API

WORK="$(mktemp -d /tmp/provapi.XXXXXX)"
PASS=0; FAIL=0
say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok(){ PASS=$((PASS+1)); printf '  \033[32m✅\033[0m %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  \033[31m❌\033[0m %s\n' "$*"; }
info(){ printf '  ·  %s\n' "$*"; }
adm(){ curl -sS -u "$AUTH" -H "Accept: application/json" "$@"; }
trap 'rm -rf "$WORK"' EXIT

# ── Jenkins : job cible ─────────────────────────────────────────────────────
# Le vrai job (selfservice-app-deploy) DOIT préexister — on ne le crée pas ici.
# Le job de preuve inoffensif (provisioning-webhook) est créé à la demande.
ensure_jenkins_job(){
  if [ "$TARGET_JOB" != "provisioning-webhook" ]; then
    curl -sf "$JENKINS_UI/job/$TARGET_JOB/api/json" >/dev/null 2>&1 && return 0
    printf '  job cible %s absent — le créer d abord\n' "$TARGET_JOB" >&2; return 1
  fi
  curl -sf "$JENKINS_UI/job/provisioning-webhook/api/json" >/dev/null 2>&1 && return 0
  local ck cj f c xml; ck=$(mktemp)
  cj=$(curl -sf -c "$ck" "$JENKINS_UI/crumbIssuer/api/json") || { rm -f "$ck"; return 1; }
  f=$(printf '%s' "$cj" | jq -r '.crumbRequestField'); c=$(printf '%s' "$cj" | jq -r '.crumb')
  xml="$WORK/prov-job.xml"
  cat > "$xml" <<'JOBXML'
<?xml version='1.1' encoding='UTF-8'?>
<project>
  <description>Cible de preuve de l'API provisioning (gateway -> Jenkins GWT). Inoffensif : echo du caller.</description>
  <keepDependencies>false</keepDependencies><properties/>
  <scm class="hudson.scm.NullSCM"/><canRoam>true</canRoam><disabled>false</disabled>
  <triggers>
    <org.jenkinsci.plugins.gwt.GenericTrigger plugin="generic-webhook-trigger@2.4.2">
      <spec></spec>
      <genericVariables>
        <org.jenkinsci.plugins.gwt.GenericVariable><key>caller</key><value>$.caller</value></org.jenkinsci.plugins.gwt.GenericVariable>
      </genericVariables>
      <printPostContent>true</printPostContent><printContributedVariables>true</printContributedVariables>
      <token>stoa-provisioning</token><silentResponse>false</silentResponse>
      <overrideQuietPeriod>false</overrideQuietPeriod><shouldNotFlattern>false</shouldNotFlattern>
      <allowSeveralTriggersPerBuild>false</allowSeveralTriggersPerBuild>
    </org.jenkinsci.plugins.gwt.GenericTrigger>
  </triggers>
  <builders><hudson.tasks.Shell><command>echo "PROVISIONING build ok - caller=${caller}"</command></hudson.tasks.Shell></builders>
  <publishers/><buildWrappers/>
</project>
JOBXML
  curl -s -b "$ck" -X POST "$JENKINS_UI/createItem?name=provisioning-webhook" -H "$f: $c" \
    -H "Content-Type: application/xml" --data-binary @"$xml" -o /dev/null -w '%{http_code}' | grep -q 200
  local rc=$?; rm -f "$ck"; return $rc
}

# routing FIXE → GWT invoke?token= (le token GWT vit en query, hors contrat labctl)
patch_routing(){
  local api_id="$1" endpoint="$JENKINS_INCLUSTER/generic-webhook-trigger/invoke?token=$GWT_TOKEN"
  adm "$GW/archive?apis=$api_id" -o "$WORK/a.zip" >/dev/null
  ( cd "$WORK" && rm -rf a && mkdir a && unzip -qo a.zip -d a )
  local rpa; rpa=$(grep -rl straightThroughRouting "$WORK/a/API" 2>/dev/null | head -1)
  [ -n "$rpa" ] || return 1
  local cur; cur=$(jq -r '(.parameters[]|select(.templateKey=="endpointUri")|.values[0]) // empty' "$rpa")
  [ "$cur" = "$endpoint" ] && { echo "unchanged"; return 0; }
  jq --arg u "$endpoint" '(.parameters[]|select(.templateKey=="endpointUri")|.values)=[$u]' "$rpa" > "$rpa.n" && mv "$rpa.n" "$rpa"
  ( cd "$WORK/a" && zip -qrX ../a2.zip APIGatewayAssets.acdl API )
  local r; r=$(adm -F "file=@$WORK/a2.zip;type=application/zip" "$GW/archive?overwrite=apis,policies,policyactions" \
      | jq -r '[.ArchiveResult[]|to_entries[]|select(.value.status!="Success")]|length')
  [ "$r" = "0" ] && echo "patched" || return 1
}

KCADM(){ curl -sS -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" | jq -r '.access_token // empty'; }
kc_token(){ # <clientId> [scope]
  local adm_t u sec; adm_t=$(KCADM)
  u=$(curl -sS -H "Authorization: Bearer $adm_t" "$KC/admin/realms/$REALM/clients?clientId=$1" | jq -r '.[0].id // empty')
  [ -n "$u" ] || return 1
  sec=$(curl -sS -H "Authorization: Bearer $adm_t" "$KC/admin/realms/$REALM/clients/$u/client-secret" | jq -r '.value // empty')
  curl -sS -d grant_type=client_credentials -d "client_id=$1" -d "client_secret=$sec" ${2:+-d "scope=$2"} \
    "$KC/realms/$REALM/protocol/openid-connect/token" | jq -r '.access_token // empty'
}

# ── 0. préambule ────────────────────────────────────────────────────────────
say "0. préambule"
[ "$(adm -o /dev/null -w '%{http_code}' "$GW/applications")" = "200" ] || { ko "gateway injoignable"; exit 1; }
[ -n "$(KCADM)" ] || { ko "admin Keycloak injoignable"; exit 1; }
ensure_jenkins_job && ok "job Jenkins cible '$TARGET_JOB' prêt" || { ko "job Jenkins '$TARGET_JOB' absent/échec"; exit 1; }
[ -f "$MANIFEST" ] || { ko "manifeste absent : $MANIFEST"; exit 1; }
ok "gateway + Keycloak + manifeste prêts"

# ── 1. labctl : build + apply (câble l'inbound-auth) ────────────────────────
say "1. labctl apply — publie le contrat + câble l'inbound-auth (authServer + IAM strict)"
LABCTL="$WORK/labctl"
( cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$LABCTL" . ) || { ko "build labctl"; exit 1; }
VAULT_ADDR= "$LABCTL" apply -f "$MANIFEST" >/dev/null 2>&1 && ok "apply OK (API publiée/convergée)" || { ko "labctl apply"; exit 1; }
API_ID=$(adm "$GW/apis" | jq -r --arg n "$API_NAME" --arg v "$API_VER" '.apiResponse[]|select(.api.apiName==$n and .api.apiVersion==$v)|.api.id')
[ -n "$API_ID" ] || { ko "API introuvable après apply"; exit 1; }

# ── 2. labctl : subscribe des 2 appelants (scope provision + stratégie + app) ─
say "2. labctl subscribe — les 2 appelants (KC client + scope provision + stratégie + app)"
for CID in "$OIG_CID" "$CLI2_CID"; do
  M="$WORK/sub-$CID.yaml"; sed "s/consumerClientId: .*/consumerClientId: $CID/" "$MANIFEST" > "$M"
  # le contrat du manifeste est relatif au fichier ; on garde le manifeste dans son dossier
  cp "$M" "$(dirname "$MANIFEST")/.sub.yaml"
  VAULT_ADDR= "$LABCTL" subscribe -f "$(dirname "$MANIFEST")/.sub.yaml" >/dev/null 2>&1 \
    && ok "subscribe $CID (scope provision accordé)" || ko "subscribe $CID"
  rm -f "$(dirname "$MANIFEST")/.sub.yaml"
done

# ── 3. routing → Jenkins GWT (query token, hors contrat) ────────────────────
say "3. routing → Generic Webhook Trigger de Jenkins"
R=$(patch_routing "$API_ID") && ok "routing = $JENKINS_INCLUSTER/generic-webhook-trigger/invoke?token=$GWT_TOKEN ($R)" || ko "patch routing"
adm -X PUT "$GW/apis/$API_ID/activate" -o /dev/null; sleep 2

# ── 4. preuve 4 voix ────────────────────────────────────────────────────────
say "4. preuve 4 voix (oracle = corps GWT : $TARGET_JOB triggered + MANIFEST résolu)"
# La demande porte le manifeste (mappé $.manifest -> MANIFEST par le GWT du job).
call(){ # <token|-> <caller> -> "HTTP<code>|<triggered>"
  local auth=(); [ "$1" != "-" ] && auth=(-H "Authorization: Bearer $1")
  local b code trig
  b=$(curl -sS -w '\n%{http_code}' ${auth[@]+"${auth[@]}"} -H "Content-Type: application/json" \
    -X POST "$DP/$API_NAME/$API_VER/applications" -d "{\"manifest\":\"$PROOF_MANIFEST\",\"caller\":\"$2\"}")
  code=$(printf '%s' "$b" | tail -1)
  trig=$(printf '%s' "$b" | sed '$d' | jq -r --arg j "$TARGET_JOB" '.jobs[$j].triggered // false' 2>/dev/null)
  printf 'HTTP%s|%s' "$code" "${trig:-false}"
}
R=$(call "-" anon); info "sans token : $R"
[ "${R%%|*}" = "HTTP401" ] && ok "voix 0 ANONYME : 401 — identité obligatoire" || ko "voix 0 : attendu HTTP401, obtenu $R"

R=$(call "$(kc_token "$OIG_CID" provision)" "$OIG_CID"); info "OIG : $R"
[ "$R" = "HTTP200|true" ] && ok "voix 1 OIG : identifié + $TARGET_JOB déclenché (MANIFEST porté)" || ko "voix 1 OIG : attendu HTTP200|true, obtenu $R"

R=$(call "$(kc_token "$CLI2_CID" provision)" "$CLI2_CID"); info "CLI2 : $R"
[ "$R" = "HTTP200|true" ] && ok "voix 2 CLI2 : identifié + $TARGET_JOB déclenché (MANIFEST porté)" || ko "voix 2 CLI2 : attendu HTTP200|true, obtenu $R"

# voix 3 : tiers LÉGITIME d'une AUTRE API, sans le scope provision → doit être rejeté.
T3=$(kc_token "$THIRD_CID" 2>/dev/null || true)
if [ -n "$T3" ]; then
  R=$(call "$T3" "$THIRD_CID"); info "TIERS ($THIRD_CID, sans scope provision) : $R"
  [ "${R%%|*}" != "HTTP200" ] && ok "voix 3 TIERS : rejeté — barrière SCOPE fermée (R2bis clos sur trial)" \
    || ko "voix 3 TIERS : PASSE ($R) — barrière scope non effective"
else
  info "tiers $THIRD_CID absent — voix 3 non jouée"
fi

say "RÉSULTAT : $PASS/$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
