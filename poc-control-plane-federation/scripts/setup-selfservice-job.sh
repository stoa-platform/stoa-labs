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

# TOUT est surchargeable par env : le MÊME script pose le job frère publish-api-deploy —
#   JOB=publish-api-deploy TRIGGER_TOKEN=stoa-publish-api-plan \
#   SCRIPT_PATH=poc-control-plane-federation/ci/Jenkinsfile.publish-api \
#   MANIFEST_DEFAULT=clients/_example/apis/accounts-read.publish.yml \
#   JOB_DESC="publication d'API (PRODUCTEUR)" bash scripts/setup-selfservice-job.sh
JENKINS="${JENKINS:-http://localhost:18080}"
JOB="${JOB:-selfservice-app-deploy}"
TRIGGER_TOKEN="${TRIGGER_TOKEN:-stoa-selfservice-plan}"
GIT_URL="${GIT_URL:-http://gitea:3000/ci/stoa-labs.git}"   # vu DEPUIS l'agent (réseau docker)
# G4 (M2) : défaut sur main — un pipeline qui ride encore une branche de
# feature après merge est éditable HORS revue (quiconque pousse sur cette
# branche change le pipeline sans passer par une PR sur main).
BRANCH="${BRANCH:-main}"
SCRIPT_PATH="${SCRIPT_PATH:-poc-control-plane-federation/ci/Jenkinsfile.selfservice}"
MANIFEST_DEFAULT="${MANIFEST_DEFAULT:-clients/_example/applications/demo-consumer.ansible.yml}"
JOB_DESC="${JOB_DESC:-self-service creation d application - CONSOMMATEUR}"

say()  { printf '\033[1;36m[selfservice-job]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[selfservice-job]\033[0m %s\n' "$*"; exit 1; }

XML="$(mktemp)"; CK="$(mktemp)"; trap 'rm -f "$XML" "$CK"' EXIT
cat > "$XML" <<JOBXML
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>ADR-078 — ${JOB_DESC} via son r&#244;le Ansible. PLAN (webhook stoa-selfservice-plan, lecture seule, identit&#233; de job) / APPLY (build param&#233;tr&#233;, identit&#233; nominative USER_VAULT_JWT &#8594; Vault &#8594; convergence + verify fail-closed).</description>
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
            <string>homol</string>
          </choices>
        </hudson.model.ChoiceParameterDefinition>
        <!-- A2 : la RÉFÉRENCE. Déclarée ICI aussi (pas seulement dans le
             Jenkinsfile) : un paramètre absent de la définition du job est
             RETIRÉ EN SILENCE d'un `build job:` amont (SECURITY-170) — l'aval
             appliquerait HEAD et provision-apply rougirait SHA_NON_CONFIRME.
             La pose du job doit donc le porter dès le premier build. -->
        <hudson.model.StringParameterDefinition>
          <name>MERGE_SHA</name>
          <description>A2 &#8212; SHA de merge &#224; projeter (40 hex, anc&#234;tre de main). Vide = HEAD du checkout SCM. Pos&#233; par provision-apply.</description>
          <defaultValue></defaultValue>
          <trim>true</trim>
        </hudson.model.StringParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>ADMIN_VIA</name>
          <description>Acc&#232;s &#224; l'API d'admin : direct (lab, Basic) ou proxy-oauth2 (mod&#232;le client).</description>
          <choices>
            <string>direct</string>
            <string>proxy-oauth2</string>
          </choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.BooleanParameterDefinition>
          <name>DEBUG</name>
          <description>Trace d&#233;taill&#233;e (appels, codes HTTP, erreurs redact&#233;es) &#8212; aucun secret expos&#233;.</description>
          <defaultValue>false</defaultValue>
        </hudson.model.BooleanParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>VAULT_USER</name>
          <description>VOIE A &#8212; identit&#233; NOMINATIVE : votre login annuaire (sAMAccountName, UPN user@domaine, ou DOMAIN\user). Vide sur le PLAN.</description>
          <trim>true</trim>
        </hudson.model.StringParameterDefinition>
        <hudson.model.PasswordParameterDefinition>
          <name>VAULT_USER_PASSWORD</name>
          <description>VOIE A &#8212; mot de passe annuaire, saisi &#224; CHAQUE apply, jamais persist&#233; hors du build. &#9888; Ne pas relancer en boucle apr&#232;s un refus (lockout AD). NB : le bouton &#171; Change Password &#187; est un libell&#233; Jenkins &#8212; il signifie &#171; saisir la valeur &#187;, RIEN ne modifie votre mot de passe annuaire.</description>
          <defaultValue></defaultValue>
        </hudson.model.PasswordParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>USER_VAULT_JWT</name>
          <description>VOIE B &#8212; identit&#233; NOMINATIVE : JWT court aud=vault. Prioritaire sur la voie A. Vide sur le PLAN.</description>
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
