#!/usr/bin/env bash
# test-api-request-wiring.sh — preuve X/X du CÂBLAGE du job api-request.
# Analyse statique : ni Jenkins, ni Gitea, ni écriture nulle part.
#
# ── POURQUOI CE FICHIER EXISTE ───────────────────────────────────────────────
# scripts/test-api-request.sh prouve le MOTEUR (scripts/api-request.sh) : ses
# gardes d'entrée, la résolution équipe -> dépôt, la collision cross-team, le
# nominal E2E contre le VRAI Gitea du lab. Il ne regarde JAMAIS le job Jenkins
# (son en-tête le laissait pourtant croire — corrigé). Or c'est précisément le
# job qui vient de changer de nature :
#
#   le pipeline ne vit PLUS en Groovy inline dans ci/jenkins/api-request.job.xml
#   (<script>…</script>) : il est dans ci/Jenkinsfile.api-request, DÉCLARATIF,
#   et le XML n'est plus qu'une coquille « Pipeline from SCM » qui porte le
#   FORMULAIRE (ses paramètres, marqueurs de listes déroulantes compris).
#
# Ce test couvre donc exactement ce que le test moteur ne couvre pas, et il est
# 100% hors ligne — il peut tourner partout, tout le temps, sans lab.
#
# Équivalences vérifiées (jamais un simple abandon de contrôle) :
#   node { }                 →  `agent any` de niveau pipeline (aucune pause
#                               humaine dans ce job : rien n'attend un humain) ;
#   stage('checkout')        →  checkout IMPLICITE de Declarative, piloté par le
#     + git url:/branch         bloc <scm> du XML (même dépôt, même branche) —
#                               d'où l'interdiction de skipDefaultCheckout ;
#   withEnv([params…])       →  export NATIF des paramètres de build par Jenkins
#                               (même canal, sans aller-retour par Groovy) : ce
#                               qui se vérifie ici est que PLUS AUCUN `params.`
#                               ne subsiste dans le fichier, et que le formulaire
#                               est resté intact côté XML, marqueurs compris.
#
# Méthode (leçon du panel, §F) : pas de grep NU qui matcherait un motif cité
# dans un COMMENTAIRE sans jamais être appelé — les ancres visent le CODE réel
# (syntaxe d'invocation exacte, ou exclusion explicite des lignes de commentaire).
#
#   ./scripts/test-api-request-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/api-request.job.xml"
JF="$REPO/ci/Jenkinsfile.api-request"
SETUP="$REPO/scripts/setup-team-onboard-jobs.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# [Important, panel §F point 5] Total ATTENDU, ÉCRIT EN DUR — indépendant de
# PASS+FAIL (qui devient vrai par construction : une section entière sautée
# silencieusement ferait baisser le total affiché SANS jamais faire échouer ce
# script). Toute section ajoutée/retirée DOIT mettre à jour ce nombre à la main.
EXPECTED_CHECKS=51

[ -f "$JOB" ] || { echo "job introuvable : $JOB"; exit 2; }
[ -f "$JF" ]  || { echo "Jenkinsfile introuvable : $JF"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Lecture NORMALISÉE du Jenkinsfile : les espaces d'ALIGNEMENT (colonnes de
# `=`) sont cosmétiques — un reformatage ne doit pas faire virer un contrôle au
# rouge, alors que la disparition d'une clé le doit.
JF_N="$(tr -s ' ' < "$JF")"
jf(){ printf '%s\n' "$JF_N" | grep -qF "$1"; }
# Le Jenkinsfile PRIVÉ DE SES COMMENTAIRES : toute vérification « ceci est
# réellement appelé » passe par lui, jamais par le fichier brut.
JF_CODE="$(grep -vE '^[[:space:]]*//' "$JF")"
jfc(){ printf '%s\n' "$JF_CODE" | grep -qF "$1"; }

echo "== 1. le XML reste bien formé, et le Jenkinsfile est un pipeline DÉCLARATIF =="
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "XML parsable" || ko "XML cassé"
grep -qE '^pipeline \{' "$JF" \
  && ok "le Jenkinsfile ouvre sur \`pipeline {\` (déclaratif, pas un script Groovy libre)" \
  || ko "le Jenkinsfile n'ouvre pas sur \`pipeline {\` — ce n'est pas un pipeline déclaratif"
grep -qE '^  stages \{' "$JF" \
  && ok "bloc \`stages\` de niveau pipeline présent" || ko "aucun bloc \`stages\` de niveau pipeline"
grep -qE "^    stage\('api-request'\) \{" "$JF" \
  && ok "l'étape porte toujours le nom 'api-request' (ce que l'ops lit dans l'UI et les logs)" \
  || ko "l'étape 'api-request' a été renommée — les logs et l'UI ne parlent plus la même langue que le job d'origine"

echo
echo "== 2. plus AUCUN Groovy inline dans le job : c'est un Pipeline from SCM =="
# LA demande client : des Jenkinsfile versionnés, pas un pipeline en dur dans un
# config.xml. Ce contrôle est la preuve que la conversion a eu lieu et ne peut
# pas régresser en silence.
grep -q 'CpsScmFlowDefinition' "$JOB" \
  && ok "définition = CpsScmFlowDefinition (Pipeline from SCM)" || ko "le job n'est pas un Pipeline from SCM"
if grep -q 'CpsFlowDefinition' "$JOB"; then
  ko "le job contient encore une CpsFlowDefinition (pipeline en dur dans le XML)"
else
  ok "aucune CpsFlowDefinition résiduelle"
fi
if grep -q '<script>' "$JOB"; then
  ko "le job contient encore un bloc <script> (Groovy inline)"
else
  ok "aucun bloc <script> : le XML ne porte plus une ligne de Groovy"
fi
grep -qF '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.api-request</scriptPath>' "$JOB" \
  && ok "scriptPath pointe sur ci/Jenkinsfile.api-request" || ko "scriptPath absent ou divergent"
grep -qF '<lightweight>false</lightweight>' "$JOB" \
  && ok "lightweight=false : le workspace porte tout le dépôt (scripts/, ansible/, gateways/templates/), pas seulement le Jenkinsfile" \
  || ko "lightweight absent ou true — le workspace n'aurait que le Jenkinsfile, api-request.sh et son gabarit mourraient"
grep -qF '<url>http://gitea:3000/ci/stoa-labs.git</url>' "$JOB" \
  && ok "SCM = dépôt plateforme vu depuis l'agent (gitea:3000, jamais localhost)" \
  || ko "URL SCM absente ou divergente — 'localhost' depuis le conteneur ne désigne PAS Gitea"
grep -qF '<name>*/main</name>' "$JOB" \
  && ok "branche SCM = */main (miroir du \`branch: 'main'\` du job Groovy)" || ko "branche SCM absente ou divergente"
# Le Jenkinsfile lui-même doit rester déclaratif : ni try/catch, ni pipeline
# scripté déguisé. Ce job n'ayant AUCUN bloc `post`, il n'a besoin d'AUCUN
# `node(...)` explicite — contrairement à team-publish (post sous `agent none`).
if grep -qE '^\s*(try \{|\} catch)' "$JF"; then
  ko "le Jenkinsfile contient un try/catch — le job d'origine n'en avait pas"
else
  ok "aucun try/catch (le job d'origine n'en portait aucun : rien à rattraper ici)"
fi
NODE_COUNT=$(printf '%s\n' "$JF_CODE" | grep -cE '^\s*node\(')
[ "$NODE_COUNT" -eq 0 ] \
  && ok "aucun \`node(...)\` : l'allocation passe par \`agent\`, le pipeline n'est pas redevenu scripté" \
  || ko "${NODE_COUNT} \`node(...)\` dans le Jenkinsfile — le pipeline redevient scripté"
SCRIPT_BLOCKS=$(printf '%s\n' "$JF_CODE" | grep -cE '^\s*script \{')
[ "$SCRIPT_BLOCKS" -eq 0 ] \
  && ok "aucun bloc \`script {}\` : « pas de Groovy à foison » tenu à la lettre" \
  || ko "${SCRIPT_BLOCKS} bloc(s) \`script {}\` — le Groovy revient par la fenêtre"

echo
echo "== 3. le FORMULAIRE reste dans le XML, marqueurs de listes intacts =="
# Les paramètres NE PEUVENT PAS migrer dans le Jenkinsfile : deux d'entre eux
# portent les marqueurs que setup-team-onboard-jobs.sh substitue À LA POSE par
# les équipes/APIs réellement présentes sur Gitea main. Les figer dans Git
# viderait ou périmerait le formulaire.
PARAM_KO=""
for P in ACTION TEAM API_NAME API_VERSION API_BASE NEW_VERSION OPENAPI_SPEC INBOUND_MODE; do
  grep -q "<name>${P}</name>" "$JOB" || PARAM_KO="${PARAM_KO} ${P}"
done
[ -z "$PARAM_KO" ] \
  && ok "les 8 paramètres du formulaire sont toujours déclarés dans le XML" \
  || ko "paramètres absents du XML :${PARAM_KO} — le formulaire serait borgne"
grep -q '<!--CHOICES:TEAMS-->' "$JOB" \
  && ok "marqueur CHOICES:TEAMS présent (liste des équipes générée à la pose)" \
  || ko "marqueur CHOICES:TEAMS perdu — la liste des équipes ne serait plus jamais substituée"
grep -q '<!--CHOICES:APIS-->' "$JOB" \
  && ok "marqueur CHOICES:APIS présent (liste des APIs générée à la pose)" \
  || ko "marqueur CHOICES:APIS perdu — API_BASE resterait vide en mode new-version"
# ANTI-DOUBLON : un `parameters {}` dans le Jenkinsfile figerait des listes dans
# Git face à des listes générées — au mieux un doublon qui pourrit, au pire des
# choix écrasés.
grep -qE '^  parameters \{' "$JF" \
  && ko "un bloc \`parameters {}\` de niveau pipeline duplique le formulaire du XML — les listes dynamiques (CHOICES) seraient figées ou écrasées" \
  || ok "aucun bloc \`parameters {}\` dans le Jenkinsfile : le formulaire n'a qu'UNE source, le XML substitué à la pose"
# Preuve DYNAMIQUE (toujours hors ligne) que la coquille reste SUBSTITUABLE :
# on rejoue la sed exacte de setup-team-onboard-jobs.sh sur une copie.
printf '<string>banking-demo</string>\n' > "$TMP/teams.frag"
printf '<string>accounts-read@1.0.0</string>\n' > "$TMP/apis.frag"
cp "$JOB" "$TMP/posed.xml"
sed -i '' \
  -e "/<!--CHOICES:TEAMS-->/r ${TMP}/teams.frag" -e "/<!--CHOICES:TEAMS-->/d" \
  -e "/<!--CHOICES:APIS-->/r ${TMP}/apis.frag"   -e "/<!--CHOICES:APIS-->/d" \
  "$TMP/posed.xml" 2>/dev/null \
|| sed -i \
  -e "/<!--CHOICES:TEAMS-->/r ${TMP}/teams.frag" -e "/<!--CHOICES:TEAMS-->/d" \
  -e "/<!--CHOICES:APIS-->/r ${TMP}/apis.frag"   -e "/<!--CHOICES:APIS-->/d" \
  "$TMP/posed.xml"
if grep -q '<string>banking-demo</string>' "$TMP/posed.xml" \
   && grep -q '<string>accounts-read@1.0.0</string>' "$TMP/posed.xml" \
   && ! grep -qE '<!--CHOICES:(TEAMS|APIS)-->' "$TMP/posed.xml"; then
  ok "substitution rejouée sur une copie : les deux fragments sont injectés, aucun marqueur résiduel"
else
  ko "la substitution des listes ne produit plus le résultat attendu sur cette coquille"
fi
python3 -c "import xml.etree.ElementTree as T; T.parse('$TMP/posed.xml')" 2>/dev/null \
  && ok "le XML SUBSTITUÉ (ce que Jenkins reçoit réellement) reste parsable" \
  || ko "le XML substitué ne parse plus — Jenkins refuserait la pose"
grep -q 'api-request' "$SETUP" \
  && ok "api-request toujours listé dans JOBS de setup-team-onboard-jobs.sh" || ko "api-request absent de JOBS"

echo
echo "== 4. le checkout : implicite, et jamais désactivé =="
# Le `stage('checkout') { git url: … }` du job Groovy a disparu du fichier : le
# checkout est fait par Declarative depuis le <scm> du XML. Deux façons de
# casser ça en silence : réintroduire un `git url:` (deux checkouts divergents)
# ou poser skipDefaultCheckout (workspace VIDE, tous les `bash scripts/…` morts).
if printf '%s\n' "$JF_CODE" | grep -q 'git url:'; then
  ko "un \`git url:\` explicite subsiste — il doublerait (et pourrait contredire) le checkout implicite piloté par le XML"
else
  ok "aucun \`git url:\` explicite : le checkout vient du <scm> de la coquille, source unique"
fi
if printf '%s\n' "$JF_CODE" | grep -q 'skipDefaultCheckout'; then
  ko "skipDefaultCheckout présent — le workspace serait VIDE et chaque \`bash scripts/…\` mourrait"
else
  ok "pas de skipDefaultCheckout : le dépôt est bien reposé dans le workspace"
fi
jfc "dir(env.GIT_SUBDIR)" \
  && ok "le step tourne dans poc-control-plane-federation/ (le dépôt plateforme est checkouté à la racine)" \
  || ko "\`dir(env.GIT_SUBDIR)\` absent — les chemins scripts/… ne résoudraient pas"

echo
echo "== 5. le credential Gitea : même identité qu'avant, mais surchargeable =="
jfc "withCredentials(forgeCreds())" \
  && ok "withCredentials réellement appelé, GITEA_TOKEN injecté par credential Jenkins (jamais en clair dans le dépôt)" \
  || ko "withCredentials absent ou remanié — api-request.sh refuserait sur \${GITEA_TOKEN:?}"
jf "GITEA_CREDENTIALS_ID = \"\${env.GITEA_CREDENTIALS_ID ?: 'gitea-provision-token'}\"" \
  && ok "défaut du credentialsId = gitea-provision-token (identique au job d'origine), surchargeable chez le client" \
  || ko "GITEA_CREDENTIALS_ID : valeur par défaut inattendue ou absente — le job d'origine utilisait 'gitea-provision-token'"

echo
echo "== 6. points de config client : présence ET valeur littérale =="
grep -qE '^  environment \{' "$JF" \
  && ok "bloc \`environment\` de niveau pipeline présent" || ko "aucun bloc \`environment\` de niveau pipeline"
# GIT_WEB_HOST : la SEULE valeur que le job Groovy posait lui-même. Sans elle,
# api-request.sh retombe sur GIT_HOST (nom interne au cluster) et le lien de la
# PR est mort pour le demandeur.
jf "GIT_WEB_HOST = \"\${env.GIT_WEB_HOST ?: 'http://localhost:13000'}\"" \
  && ok "valeur littérale de GIT_WEB_HOST = http://localhost:13000 (lien de PR cliquable par un HUMAIN, hors conteneurs)" \
  || ko "GIT_WEB_HOST : valeur par défaut inattendue ou absente — le lien de la PR retomberait sur un nom interne au cluster"
jf "GIT_HOST = \"\${env.GIT_HOST ?: 'http://gitea:3000'}\"" \
  && ok "valeur littérale de GIT_HOST = http://gitea:3000 (alias in-cluster ; 'localhost' ne désigne PAS Gitea depuis l'agent)" \
  || ko "GIT_HOST : valeur par défaut inattendue ou absente"
jf "GIT_REPO = \"\${env.GIT_REPO ?: 'ci/stoa-labs'}\"" \
  && ok "valeur littérale de GIT_REPO = ci/stoa-labs (dépôt plateforme : providers.<env>.yml + gardes du plan)" \
  || ko "GIT_REPO : valeur par défaut inattendue ou absente"
# G4 (ADR-082) : le Jenkinsfile ne route PLUS d'axe env — le script scelle ENVN
# sur la constante d'authoring. L'épreuve garde le remplacement, des deux côtés.
sed 's|[[:space:]]*//.*$||' "$JF" > "$TMP/jf_envn"
grep -q 'ENVN' "$TMP/jf_envn" \
  && ko "le Jenkinsfile route encore un axe ENVN — G4 l'a scellé dans le script" \
  || ok "aucun axe ENVN routé par le Jenkinsfile (scellé côté script, G4)"
sed 's/[[:space:]]*#.*$//' "$REPO/scripts/api-request.sh" > "$TMP/ar_envn"
grep -q 'ENVN="\$DEPLOY_PIN_AUTHORING_ENV"' "$TMP/ar_envn" \
  && ok "api-request.sh scelle ENVN sur DEPLOY_PIN_AUTHORING_ENV" \
  || ko "api-request.sh ne scelle pas ENVN"
# L'ordre compte : `environment` doit précéder `stages` pour que les valeurs
# soient dans l'environnement de TOUS les steps.
L_ENV=$(grep -n '^  environment {' "$JF" | head -1 | cut -d: -f1)
L_STAGES=$(grep -n '^  stages {' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_ENV" ] && [ -n "$L_STAGES" ] && [ "$L_ENV" -lt "$L_STAGES" ]; then
  ok "\`environment\` (ligne $L_ENV) précède \`stages\` (ligne $L_STAGES) — exporté avant tout step"
else
  ko "ordre environment/stages non confirmé (environment=$L_ENV stages=$L_STAGES)"
fi

echo
echo "== 7. pas d'injection : la saisie humaine ne traverse AUCUNE interpolation Groovy =="
# Le vrai danger n'est PAS `params.` en soi — c'est `params.` (ou toute autre
# valeur) INTERPOLÉ DANS UNE CHAÎNE SHELL. Le `withEnv([... params.X ...])`,
# lui, est OBLIGATOIRE : MESURÉ sur ce Jenkins (sonde jetable, 2026-08-06), un
# paramètre de build valant `RAW>${JENKINS_HOME}<FIN` arrive au step `sh` en
# `RAW>/var/jenkins_home<FIN` — Jenkins applique EnvVars.resolve() aux valeurs
# de ParametersAction. `params.X` est le SEUL accès à la valeur littérale.
# Sans cette ré-injection, OPENAPI_SPEC (multi-lignes, contrôlé par le
# demandeur, committé tel quel dans apis/<name>.openapi.yaml) serait réécrit en
# silence, et coller `${JENKINS_HOME}` deviendrait une primitive de lecture de
# l'environnement du contrôleur vers un dépôt d'équipe.
if printf '%s\n' "$JF_CODE" | grep -q 'withEnv(\["ACTION=\${params\.ACTION}'; then
  ok "ré-injection des valeurs BRUTES via withEnv([...params...]) présente — les \${…} d'une saisie ne sont pas expansés par Jenkins"
else
  ko "le withEnv([...params...]) de ré-injection a disparu — Jenkins résoudrait les \${…} de OPENAPI_SPEC/API_NAME avant le script (corruption silencieuse + lecture de l'env du contrôleur)"
fi
MISSING_RAW=""
for P in ACTION TEAM API_NAME API_VERSION API_BASE NEW_VERSION OPENAPI_SPEC INBOUND_MODE; do
  printf '%s\n' "$JF_CODE" | grep -q "${P}=\${params\.${P}" || MISSING_RAW="${MISSING_RAW} ${P}"
done
[ -z "$MISSING_RAW" ] \
  && ok "les 8 paramètres du formulaire sont ré-injectés en valeur brute" \
  || ko "paramètres NON ré-injectés en brut :${MISSING_RAW} — ceux-là subiraient EnvVars.resolve()"
# L'invocation est un `sh` d'UNE ligne : c'est elle, et elle seule, qui ne doit
# porter aucune interpolation Groovy (ni params., ni ${…}).
if printf '%s\n' "$JF_CODE" | grep -E "^[[:space:]]*sh '" | grep -q 'params\.\|\${'; then
  ko "la chaîne sh porte une interpolation Groovy (params. ou \${…}) — la saisie la traverserait"
else
  ok "la chaîne sh ne porte aucune interpolation Groovy : c'est le shell qui lit l'environnement posé par withEnv"
fi
if grep -q 'sh """' "$JF"; then
  ko "un bloc \`sh \"\"\"\` (triple quotes DOUBLES) existe — Groovy y interpolerait la saisie et le token"
else
  ok "aucun bloc \`sh \"\"\"\` : impossible d'interpoler une valeur externe dans une chaîne shell"
fi
if printf '%s\n' "$JF_CODE" | grep -qE '^\s*sh "'; then
  ko "une chaîne \`sh \"…\"\` (quotes doubles) existe — même risque d'interpolation"
else
  ok "aucune chaîne \`sh \"…\"\` : tout ce qui va au shell est en quotes simples"
fi
jfc "sh 'set +x; bash scripts/api-request.sh'" \
  && ok "l'invocation RÉELLE est \`sh 'set +x; bash scripts/api-request.sh'\` — à l'octet près celle du job d'origine (set +x compris : aucune trace shell)" \
  || ko "l'invocation d'api-request.sh a changé de forme — vérifier le \`set +x\` et les quotes simples"

echo
echo "== 8. le pipeline reste MINCE : il route, le moteur ne bouge pas =="
if printf '%s\n' "$JF_CODE" | grep -qE '^\s*(curl|ansible-playbook) '; then
  ko "le Jenkinsfile appelle directement curl/ansible-playbook — la substance doit rester dans scripts/ et ansible/"
else
  ok "aucun curl/ansible-playbook direct : le pipeline route, le moteur reste dans scripts/ et ansible/"
fi
[ -f "$REPO/scripts/api-request.sh" ] \
  && ok "scripts/api-request.sh présent" || ko "scripts/api-request.sh absent — appel mort"
bash -n "$REPO/scripts/api-request.sh" 2>/dev/null \
  && ok "api-request.sh : syntaxe shell valide" || ko "api-request.sh non parsable"
# Ce que le script lit DANS LE WORKSPACE — donc ce que lightweight=false doit
# ramener. Un lightweight=true les ferait tous disparaître d'un coup.
[ -f "$REPO/gateways/templates/publish.yml.tmpl" ] \
  && ok "gateways/templates/publish.yml.tmpl présent (gabarit du manifeste, lu depuis le workspace)" \
  || ko "gabarit publish.yml.tmpl absent — le rendu du manifeste mourrait"
[ -f "$REPO/ansible/test-publish-guards.yml" ] \
  && ok "ansible/test-publish-guards.yml présent (plan hors ligne : manifest-guard + team-name)" \
  || ko "ansible/test-publish-guards.yml absent — le PLAN commenté sur la PR mourrait"
[ -f "$REPO/ansible/publish-api.yml" ] \
  && ok "ansible/publish-api.yml présent (syntax-check du plan)" || ko "ansible/publish-api.yml absent"

echo
echo "== 9. l'agent : alloué, et aucune pause inventée =="
grep -qE '^  agent any$' "$JF" \
  && ok "\`agent any\` de niveau pipeline (équivalent du \`node { }\` d'origine : ce job n'attend jamais un humain)" \
  || ko "pas d'\`agent any\` de niveau pipeline — les steps n'auraient pas de workspace"
if grep -qE '^  agent none$' "$JF"; then
  ko "\`agent none\` de niveau pipeline sans étape qui déclare le sien — les steps n'auraient aucun exécuteur"
else
  ok "pas d'\`agent none\` : inutile ici, il n'y a aucune demande en attente à couvrir"
fi
if printf '%s\n' "$JF_CODE" | grep -qE '^\s*input[ (\{]'; then
  ko "une directive/step \`input\` a été introduite — le job d'origine ne demandait AUCUNE validation : ce serait un changement de comportement, pas une conversion"
else
  ok "aucun \`input\` : la décision reste le MERGE de la PR (ADR-081), jamais une pause dans ce job"
fi

echo
echo "== 10. le déclencheur : aucun des deux côtés n'en invente un =="
# Mesuré sur le lab (2026-08-06) : Declarative ne remplace QUE les déclencheurs
# qu'il a lui-même posés (DeclarativeJobPropertyTrackerAction) — un <triggers>
# venu d'un config.xml est préservé indéfiniment et GAGNE. Ici les deux doivent
# rester VIDES : ce formulaire est lancé à la main par un humain.
if grep -qE '^  triggers \{' "$JF"; then
  ko "un bloc \`triggers {}\` est apparu dans le Jenkinsfile — ce formulaire se lance à la main, rien ne doit le déclencher"
else
  ok "aucun \`triggers {}\` dans le Jenkinsfile (formulaire lancé à la main)"
fi
if grep -q '<triggers/>' "$JOB"; then
  ok "<triggers/> vide dans le XML : miroir exact du Jenkinsfile (et c'est le XML qui gagnerait)"
else
  ko "le XML ne porte plus un <triggers/> vide — vérifier qu'aucun déclencheur n'y a été ajouté (il gagnerait en silence sur le Jenkinsfile)"
fi
if grep -q 'GenericTrigger' "$JOB"; then
  ko "un GenericTrigger est apparu dans le XML — ce job n'est pas déclenché par webhook"
else
  ok "aucun GenericTrigger dans le XML"
fi

echo
echo "== 11. le total de contrôles exécutés correspond au total ATTENDU, écrit en dur =="
# Le `RÉSULTAT : %d/%d` final imprime PASS/(PASS+FAIL) — formule
# auto-référentielle, vraie par construction. CE contrôle compare contre
# EXPECTED_CHECKS, une CONSTANTE écrite en tête, indépendante du run.
ACTUAL_CHECKS=$((PASS+FAIL))
if [ "$ACTUAL_CHECKS" -eq "$EXPECTED_CHECKS" ]; then
  ok "nombre de contrôles exécutés = ${EXPECTED_CHECKS} (attendu, écrit en dur en tête de ce fichier)"
else
  ko "nombre de contrôles exécutés = ${ACTUAL_CHECKS}, attendu ${EXPECTED_CHECKS} (écrit en dur) — une section a peut-être été sautée silencieusement"
fi

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
