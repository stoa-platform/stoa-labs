#!/usr/bin/env bash
# setup-selfservice-job.sh — (re)crée le job Jenkins `selfservice-app-deploy`
# (ADR-078, self-service « création d'application » CONSOMMATEUR).
#
# Le job est un PIPELINE FROM SCM (pas de pipeline inline) : il checkoute le
# super-repo gitea `ci/stoa-labs.git` et exécute
# `poc-control-plane-federation/ci/Jenkinsfile.selfservice`. Modèle PLAN/APPLY :
#   - webhook (token stoa-selfservice-plan) → PLAN, lecture seule, identité de job ;
#   - build paramétré (USER_VAULT_JWT) → APPLY nominatif → Vault → rôle Ansible.
#
# Config MIROIR du job frère `publish-api-deploy` (mêmes SCM/branche/params), à
# 3 différences près : token de trigger, defaultValue de MANIFEST, scriptPath.
#
# Idempotent — même mécanique crumb/createItem/config.xml que setup-user-deploy-job.sh.
set -uo pipefail

JENKINS="${JENKINS:-http://localhost:18080}"
JOB="${JOB:-selfservice-app-deploy}"
TRIGGER_TOKEN="stoa-selfservice-plan"
GIT_URL="${GIT_URL:-http://gitea:3000/ci/stoa-labs.git}"   # vu DEPUIS l'agent (réseau docker)
BRANCH="${BRANCH:-feat/selfservice-app-adr078}"
SCRIPT_PATH="poc-control-plane-federation/ci/Jenkinsfile.selfservice"
MANIFEST_DEFAULT="clients/_example/applications/demo-consumer.ansible.yml"

say()  { printf '\033[1;36m[selfservice-job]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[selfservice-job]\033[0m %s\n' "$*"; exit 1; }

XML="$(mktemp)"; CK="$(mktemp)"; trap 'rm -f "$XML" "$CK"' EXIT
cat > "$XML" <<JOBXML
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>ADR-078 — self-service &#171; cr&#233;ation d'application &#187; (CONSOMMATEUR) via le r&#244;le Ansible apim_selfservice_app. PLAN (webhook stoa-selfservice-plan, lecture seule, identit&#233; de job) / APPLY (build param&#233;tr&#233;, identit&#233; nominative USER_VAULT_JWT &#8594; Vault &#8594; convergence + verify fail-closed).</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <org.jenkinsci.plugins.gwt.GenericTrigger plugin="generic-webhook-trigger">
          <spec></spec>
          <genericVariables>
            <org.jenkinsci.plugins.gwt.GenericVariable>
              <key>MANIFEST</key>
              <value>\$.manifest</value>
            </org.jenkinsci.plugins.gwt.GenericVariable>
          </genericVariables>
          <printPostContent>false</printPostContent>
          <printContributedVariables>false</printContributedVariables>
          <token>${TRIGGER_TOKEN}</token>
          <silentResponse>false</silentResponse>
          <overrideQuietPeriod>false</overrideQuietPeriod>
          <shouldNotFlattern>false</shouldNotFlattern>
          <allowSeveralTriggersPerBuild>false</allowSeveralTriggersPerBuild>
        </org.jenkinsci.plugins.gwt.GenericTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
    <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty>
      <abortPrevious>false</abortPrevious>
    </org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>MANIFEST</name>
          <description>Manifeste de demande (vars du r&#244;le : apim_ss_app).</description>
          <defaultValue>${MANIFEST_DEFAULT}</defaultValue>
          <trim>false</trim>
        </hudson.model.StringParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>ENVIRONMENT</name>
          <description>Environnement cible (identit&#233; IP/cert par env + header X-Environment).</description>
          <choices>
            <string>dev</string>
            <string>rec</string>
            <string>int</string>
            <string>prod</string>
          </choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>USER_VAULT_JWT</name>
          <description>Identit&#233; NOMINATIVE : JWT court aud=vault. Vide sur le PLAN.</description>
          <trim>false</trim>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>${GIT_URL}</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/${BRANCH}</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>${SCRIPT_PATH}</scriptPath>
    <lightweight>false</lightweight>
  </definition>
  <disabled>false</disabled>
</flow-definition>
JOBXML

# --- crumb CSRF + create/update (pattern setup-user-deploy-job.sh) ------------
CJ=$(curl -sf -c "$CK" "$JENKINS/crumbIssuer/api/json") || fail "crumbIssuer KO ($JENKINS joignable ?)"
F=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])')
C=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumb"])')
# charset=utf-8 OBLIGATOIRE : sinon config.xml relit le body en ISO-8859-1 → 500.
CT='Content-Type: application/xml; charset=utf-8'
if curl -sf -b "$CK" "$JENKINS/job/$JOB/api/json" >/dev/null 2>&1; then
  say "job $JOB existe — config mise à jour"
  HC=$(curl -s -b "$CK" -X POST "$JENKINS/job/$JOB/config.xml" -H "$F: $C" \
    -H "$CT" --data-binary @"$XML" -o /dev/null -w '%{http_code}')
else
  say "création du job $JOB (Pipeline from SCM → $SCRIPT_PATH @ $BRANCH)"
  HC=$(curl -s -b "$CK" -X POST "$JENKINS/createItem?name=$JOB" -H "$F: $C" \
    -H "$CT" --data-binary @"$XML" -o /dev/null -w '%{http_code}')
fi
[ "$HC" = 200 ] || fail "POST job KO (HTTP $HC)"

# --- build d'amorçage : checkoute le Jenkinsfile, matérialise trigger+params --
# Sans USER_VAULT_JWT → PLAN-only (syntax-check), aucune mutation, doit finir SUCCESS.
N=$(curl -sf "$JENKINS/job/$JOB/api/json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])')
say "build d'amorçage #$N (PLAN-only, enregistre le trigger $TRIGGER_TOKEN)"
# Job paramétré → buildWithParameters (POST /build renvoie 400). Sans USER_VAULT_JWT
# (défaut vide) l'apply se saute → PLAN-only.
HC=$(curl -s -b "$CK" -X POST "$JENKINS/job/$JOB/buildWithParameters" -H "$F: $C" -o /dev/null -w '%{http_code}')
[ "$HC" = 201 ] || fail "POST /build KO (HTTP $HC)"
R=""
for _ in $(seq 1 45); do
  R=$(curl -sf "$JENKINS/job/$JOB/$N/api/json" 2>/dev/null |
    python3 -c 'import sys,json;b=json.load(sys.stdin);print(b.get("result") or "")' 2>/dev/null || true)
  [ -n "$R" ] && break
  sleep 2
done
[ "$R" = "SUCCESS" ] || fail "build d'amorçage #$N : ${R:-pas de résultat en 90 s} — voir $JENKINS/job/$JOB/$N/console"
say "build d'amorçage #$N : SUCCESS (trigger enregistré, params matérialisés)"
say "OK — webhook PLAN : POST $JENKINS/generic-webhook-trigger/invoke?token=$TRIGGER_TOKEN  body {\"manifest\":\"<chemin>\"}"
say "     APPLY manuel : $JENKINS/job/$JOB/build?delay=0sec (fournir USER_VAULT_JWT via scripts/mint-selfservice-jwt.sh)"
