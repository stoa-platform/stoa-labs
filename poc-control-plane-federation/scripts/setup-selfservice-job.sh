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
#
# ── A0 dettes (2026-09-02) : LE XML NE PORTE PLUS LE FORMULAIRE ─────────────
# ci/Jenkinsfile.selfservice pose ses huit paramètres LUI-MÊME
# (properties([parameters([…])]), paliers dérivés de la chaîne à chaque build).
# FAIT 6 MESURÉ : si le XML porte déjà une <hudson.model.ParametersDefinitionProperty>,
# properties() en AJOUTE une seconde et le job CASSE (buildWithParameters ⇒ 500).
# D'où le knob XML_PARAMS :
#   auto (défaut) : `no` quand SCRIPT_PATH est Jenkinsfile.selfservice, `yes` sinon
#   no            : AUCUNE propriété dans le XML (ni paramètre, ni trigger, ni
#                   option — fait 10 : un XML avec trigger + properties() scripté
#                   = doublon sur un job neuf, PERTE au premier build d'un job
#                   re-posé) ; le Jenkinsfile pose tout ; amorçage par POST /build (201)
#   yes           : les huit <parameterDefinitions> restent (publish-api-deploy garde
#                   son bloc parameters{} déclaratif — ceinture SECURITY-170 entre
#                   la pose et l'amorçage), la liste ENVIRONMENT étant DÉRIVÉE À LA
#                   POSE de env_chain_nonprod (plus aucun littéral) ; amorçage par
#                   buildWithParameters.
# La CONVERSION d'un job existant passe par ce script (POST config.xml efface
# paramètres ET trackers), JAMAIS par un simple push du Jenkinsfile — sinon le
# doublon du fait 6. Après l'amorçage, la config est RELUE : exactement UNE
# propriété de paramètres, et (mode no) ENVIRONMENT == env_chain_nonprod.
#   --print        : rend le XML sur stdout, zéro réseau (épreuves hors ligne).
#   BOOTSTRAP_WAIT : attente de l'amorçage (défaut 360 s — le préflight gateway
#                   de l'aval peut durer 300 s pendant un recyclage keepalive) ;
#                   « encore en cours » est distingué d'un échec : NE PAS re-poser.
# Résiduel nommé : ce poseur n'a ni auth Jenkins ni portail (parité avec
# setup-provision-jobs.sh à faire le jour du rollout client).
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
BOOTSTRAP_WAIT="${BOOTSTRAP_WAIT:-360}"

say()  { printf '\033[1;36m[selfservice-job]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[selfservice-job]\033[0m %s\n' "$*" >&2; exit 1; }   # stderr : --print rend le XML SEUL sur stdout
# Temporaires : UN trap, posé avant le premier mktemp (revue 2026-09-02).
XML="$(mktemp)"; CK="$(mktemp)"; PARAMS_TMP=""; trap 'rm -f "$XML" "$CK" "$XML.relu" "${PARAMS_TMP:-}"' EXIT

# ── XML_PARAMS (A0 dettes, cf. en-tête) ──────────────────────────────────────
XML_PARAMS="${XML_PARAMS:-auto}"
case "$XML_PARAMS" in
  auto) case "$SCRIPT_PATH" in *Jenkinsfile.selfservice) XML_PARAMS=no;; *) XML_PARAMS=yes;; esac;;
  yes|no) ;;
  *) fail "XML_PARAMS='$XML_PARAMS' : attendu auto|yes|no";;
esac
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$XML_PARAMS" = yes ]; then
  # La liste ENVIRONMENT est DÉRIVÉE de la chaîne (plus aucun littéral) ; chaque
  # palier est validé avant d'entrer dans du XML (jamais une valeur libre).
  # shellcheck source=scripts/lib/env-chain.sh
  . "$SELF_DIR/lib/env-chain.sh" || fail "LIB_ABSENTE : $SELF_DIR/lib/env-chain.sh"
  # A7 : la chaîne ENTIÈRE (le dispatch de prod par `build job:` exige que le
  # terminus soit listé — mesuré) ; les portes décident.
  ENVS="$(env_chain)" || fail "CHAINE_ILLISIBLE : env_chain"
  ENV_CHOICES_XML=""
  for e in $ENVS; do
    case "$e" in ''|*[!a-z0-9]*) fail "PALIER_INVALIDE : '$e' hors de ^[a-z0-9]+$";; esac
    ENV_CHOICES_XML="${ENV_CHOICES_XML}            <string>${e}</string>
"
  done
  # Heredoc rendu dans un FICHIER puis relu : un heredoc DANS `$( )` casse le
  # parseur de bash 3.2 (macOS) sur les apostrophes du texte (mesuré ici).
  PARAMS_TMP="$(mktemp)"   # couvert par le trap ci-dessus
  cat > "$PARAMS_TMP" <<PARAMS
    <!-- XML_PARAMS=yes : ce job garde ses parametres dans le XML (bloc
         parameters{} declaratif cote Jenkinsfile, fusion par nom) ; la liste
         ENVIRONMENT est DERIVEE A LA POSE de env_chain (A0 dettes ; A7 : chaine entiere). -->
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
          <description>Environnement cible (identit&#233; IP/cert par env + header X-Environment) &#8212; liste d&#233;riv&#233;e de la cha&#238;ne &#224; la pose.</description>
          <choices>
${ENV_CHOICES_XML}          </choices>
        </hudson.model.ChoiceParameterDefinition>
        <!-- A2 : la RÉFÉRENCE. Déclarée ICI aussi (pas seulement dans le
             Jenkinsfile) : un paramètre absent de la définition du job est
             RETIRÉ EN SILENCE d'un « build job: » amont (SECURITY-170). -->
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
          <description>VOIE A &#8212; identit&#233; NOMINATIVE : votre login annuaire (sAMAccountName, UPN user@domaine, ou DOMAIN\\user). Vide sur le PLAN.</description>
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
PARAMS
  PARAMS_XML="$(cat "$PARAMS_TMP")"; rm -f "$PARAMS_TMP"
else
  PARAMS_XML=""
fi

# ── <properties> : TOUT ou RIEN (fait 10, mesuré 2026-09-02) ────────────────
# Mode yes (publish-api-deploy) : trigger + disableConcurrentBuilds + les huit
# parametres — le job garde son bloc declaratif. Mode no (selfservice-app-deploy) :
# AUCUNE propriete dans le XML : le Jenkinsfile les pose TOUTES par properties()
# au premier stage (trigger compris). Un XML qui en porterait une seule ferait
# soit un DOUBLON (job neuf), soit une PERTE au premier build (job re-pose).
if [ "$XML_PARAMS" = yes ]; then
  PROPS_TMP="$(mktemp)"
  cat > "$PROPS_TMP" <<PROPS
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
${PARAMS_XML}
  </properties>
PROPS
  PROPS_XML="$(cat "$PROPS_TMP")"; rm -f "$PROPS_TMP"
else
  PROPS_XML="  <!-- XML_PARAMS=no (A0 dettes, faits 6 et 10) : AUCUNE propriete ici — ni
       parametre, ni trigger, ni option. Le Jenkinsfile les pose TOUTES par
       properties() au premier stage ; le webhook PLAN n'existe qu'apres
       l'amorcage (enchaine par le poseur). -->
  <properties/>"
fi
cat > "$XML" <<JOBXML
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>ADR-078 — ${JOB_DESC} via son r&#244;le Ansible. PLAN (webhook stoa-selfservice-plan, lecture seule, identit&#233; de job) / APPLY (build param&#233;tr&#233;, identit&#233; nominative USER_VAULT_JWT &#8594; Vault &#8594; convergence + verify fail-closed).</description>
  <keepDependencies>false</keepDependencies>
${PROPS_XML}
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

python3 -c "import sys,xml.etree.ElementTree as T; T.parse(sys.argv[1])" "$XML" || fail "XML rendu mal forme (rien n'a ete envoye)"
if [ "${1:-}" = "--print" ]; then cat "$XML"; exit 0; fi

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
[ -n "$N" ] || fail "nextBuildNumber illisible ($JENKINS/job/$JOB/api/json)"
say "build d'amorçage #$N (PLAN-only, enregistre le trigger $TRIGGER_TOKEN, XML_PARAMS=$XML_PARAMS)"
# XML sans paramètre (mode no) → POST /build (201 ; buildWithParameters serait
# aussi accepté, /build est le geste d'un job non paramétré) ; XML paramétré
# (mode yes) → buildWithParameters (POST /build renvoie 400 sur un job
# paramétré, mesuré). Sans USER_VAULT_JWT (défaut vide) l'apply se saute → PLAN-only.
if [ "$XML_PARAMS" = no ]; then BUILD_EP="build"; else BUILD_EP="buildWithParameters"; fi
HC=$(curl -s -b "$CK" -X POST "$JENKINS/job/$JOB/$BUILD_EP" -H "$F: $C" -o /dev/null -w '%{http_code}')
[ "$HC" = 201 ] || fail "POST /$BUILD_EP KO (HTTP $HC)"
R=""
for _ in $(seq 1 "$((BOOTSTRAP_WAIT / 2))"); do
  R=$(curl -sf "$JENKINS/job/$JOB/$N/api/json" 2>/dev/null |
    python3 -c 'import sys,json;b=json.load(sys.stdin);print(b.get("result") or "")' 2>/dev/null || true)
  [ -n "$R" ] && break
  sleep 2
done
if [ -z "$R" ]; then
  fail "build d'amorçage #$N ENCORE EN COURS après ${BOOTSTRAP_WAIT} s (préflight gateway ? recyclage keepalive ?) — NE PAS re-poser (la re-pose effacerait le formulaire) : attendre sa fin sur $JENKINS/job/$JOB/$N/console, puis relire la config"
fi
# --- relecture (fait 6) : UNE propriété de paramètres, et la liste attendue ---
# Relue QUEL QUE SOIT le résultat de l'amorçage : le stage Formulaire est le
# premier ; un rouge plus loin (préflight gateway, sonde cert) laisse le
# formulaire POSÉ — re-poser effacerait ce qui est bon (revue 2026-09-02).
curl -sf "$JENKINS/job/$JOB/config.xml" > "$XML.relu" || fail "config.xml illisible après l'amorçage (HTTP ≠ 200)"
NPROP=$(python3 -c "import sys,xml.etree.ElementTree as T; r=T.parse(sys.argv[1]).getroot(); print(sum(1 for e in r.iter() if e.tag.endswith('ParametersDefinitionProperty')))" "$XML.relu")
if [ "$R" != "SUCCESS" ]; then
  if [ "$NPROP" = 1 ]; then
    fail "build d'amorçage #$N : $R — mais le FORMULAIRE EST POSÉ (1 propriété) : l'échec vient d'un stage ultérieur (préflight gateway ? sonde cert ?), voir $JENKINS/job/$JOB/$N/console — NE PAS re-poser"
  fi
  fail "build d'amorçage #$N : $R et aucun formulaire posé — voir $JENKINS/job/$JOB/$N/console"
fi
say "build d'amorçage #$N : SUCCESS (trigger enregistré, params matérialisés)"
[ "$NPROP" = 1 ] || fail "le job porte $NPROP proprietes de parametres apres l'amorcage (fait 6 : un push sans re-pose sur un XML parametre ?) — re-poser par CE script"
if [ "$XML_PARAMS" = no ]; then
  # shellcheck source=scripts/lib/env-chain.sh
  . "$SELF_DIR/lib/env-chain.sh" || fail "LIB_ABSENTE : $SELF_DIR/lib/env-chain.sh"
  WANT="$(env_chain)" || fail "CHAINE_ILLISIBLE"
  GOT=$(python3 -c "
import sys, xml.etree.ElementTree as T
r = T.parse(sys.argv[1]).getroot()
for p in r.iter():
    if p.tag.endswith('ChoiceParameterDefinition') and p.findtext('name') == 'ENVIRONMENT':
        print(' '.join(s.text or '' for s in p.iter('string')))" "$XML.relu")
  [ "$GOT" = "$WANT" ] || fail "ENVIRONMENT pose par le build = [$GOT], chaine locale = [$WANT] — le build derive la liste de gitea main : pousser le depot, ou relire apres le prochain build"
  TRIG=$(python3 -c "import sys,xml.etree.ElementTree as T; r=T.parse(sys.argv[1]).getroot(); print(','.join(t.findtext('token') or '' for t in r.iter() if t.tag.endswith('GenericTrigger')))" "$XML.relu")
  NDIS=$(python3 -c "import sys,xml.etree.ElementTree as T; r=T.parse(sys.argv[1]).getroot(); print(sum(1 for e in r.iter() if e.tag.endswith('DisableConcurrentBuildsJobProperty')))" "$XML.relu")
  [ "$TRIG" = "$TRIGGER_TOKEN" ] && [ "$NDIS" = 1 ] || fail "apres l'amorcage : trigger=[$TRIG] disableConcurrentBuilds=$NDIS — attendu UN trigger $TRIGGER_TOKEN et UNE option, poses par properties() (fait 10)"
  say "relecture : 1 propriete de parametres, trigger $TRIGGER_TOKEN + disableConcurrentBuilds poses par le Jenkinsfile, ENVIRONMENT == env_chain [$GOT]"
else
  say "relecture : 1 propriete de parametres (XML_PARAMS=yes)"
fi
say "OK — webhook PLAN : POST $JENKINS/generic-webhook-trigger/invoke?token=$TRIGGER_TOKEN  body {\"manifest\":\"<chemin>\"}"
say "     APPLY manuel : $JENKINS/job/$JOB/build?delay=0sec (fournir USER_VAULT_JWT via scripts/mint-selfservice-jwt.sh)"
