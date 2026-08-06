#!/usr/bin/env bash
# test-app-request-wiring.sh — preuve X/X du CÂBLAGE du job app-request après sa
# conversion en Jenkinsfile déclaratif. Analyse statique : ni Jenkins, ni Gitea.
#
# Pendant de test-team-publish-wiring.sh / test-api-request-wiring.sh /
# test-team-request-wiring.sh, pour le dernier des cinq jobs self-service.
# Complémentaire de test-app-request-v2.sh (qui, lui, prouve les GARDES de
# provision-request.sh et la substitution des listes déroulantes) : ici on ne
# vérifie que le CÂBLAGE — le pipeline est-il bien sorti du XML sans rien perdre.
#
#   ./scripts/test-app-request-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/app-request.job.xml"
JF="$REPO/ci/Jenkinsfile.app-request"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# Total ATTENDU, ÉCRIT EN DUR — indépendant de PASS+FAIL (auto-référentiel, donc
# vrai par construction). Toute section ajoutée/retirée DOIT mettre ce nombre à
# jour : un oubli fait virer le §9 au rouge, ce qui EST le comportement voulu.
EXPECTED_CHECKS=34

[ -f "$JOB" ] || { echo "job introuvable : $JOB"; exit 2; }
[ -f "$JF" ]  || { echo "Jenkinsfile introuvable : $JF"; exit 2; }

# Le CODE seul (commentaires Groovy retirés) : une garde NOMMÉE dans un
# commentaire mais jamais appelée ne doit pas faire passer un contrôle au vert.
JF_CODE="$(grep -vE '^[[:space:]]*//' "$JF")"
jfc(){ printf '%s\n' "$JF_CODE" | grep -qF "$1"; }

echo "== 1. le XML est bien formé, et le Jenkinsfile est un pipeline DÉCLARATIF =="
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "XML parsable" || ko "XML cassé"
grep -qE '^pipeline \{' "$JF" \
  && ok "le Jenkinsfile ouvre sur \`pipeline {\` (déclaratif, pas un script Groovy libre)" \
  || ko "le Jenkinsfile n'ouvre pas sur \`pipeline {\`"
grep -qE '^  stages \{' "$JF" \
  && ok "bloc \`stages\` de niveau pipeline présent" || ko "aucun bloc \`stages\` de niveau pipeline"

echo
echo "== 2. plus AUCUN Groovy inline dans le job : c'est un Pipeline from SCM =="
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
grep -qF '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.app-request</scriptPath>' "$JOB" \
  && ok "scriptPath pointe sur ci/Jenkinsfile.app-request" || ko "scriptPath absent ou divergent"
grep -qF '<lightweight>false</lightweight>' "$JOB" \
  && ok "lightweight=false : le workspace porte tout le dépôt (scripts/, ansible/), pas seulement le Jenkinsfile" \
  || ko "lightweight absent ou true — les appels scripts/ mourraient"
if grep -qE '^\s*(try \{|\} catch)' "$JF"; then
  ko "le Jenkinsfile contient un try/catch — la gestion d'erreur doit passer par \`post\`"
else
  ok "aucun try/catch"
fi

echo
echo "== 3. LES LISTES DÉROULANTES RESTENT DANS LE XML (le point qui casse le plus vite) =="
# setup-team-onboard-jobs.sh substitue ces marqueurs par les <string>…</string>
# RÉELLEMENT trouvés sur Gitea main, AU MOMENT DE LA POSE. Déplacer ces
# paramètres dans le Jenkinsfile (bloc `parameters {}`) tuerait la substitution :
# les menus seraient vides ou figés. Ils DOIVENT rester ici.
grep -q '<!--CHOICES:TEAMS-->' "$JOB" \
  && ok "marqueur <!--CHOICES:TEAMS--> toujours présent dans le XML" \
  || ko "marqueur CHOICES:TEAMS disparu — la liste des équipes ne serait plus générée"
grep -q '<!--CHOICES:APIS-->' "$JOB" \
  && ok "marqueur <!--CHOICES:APIS--> toujours présent dans le XML" \
  || ko "marqueur CHOICES:APIS disparu — la liste des APIs ne serait plus générée"
MISSING_P=""
for P in APP REQ_ENV API CLIENT_ID MODE TEAM IP_ALLOWLIST CERT_PEM CERT_ROTATION; do
  grep -q "<name>${P}</name>" "$JOB" || MISSING_P="${MISSING_P} ${P}"
done
[ -z "$MISSING_P" ] \
  && ok "les 9 paramètres du formulaire sont toujours déclarés dans le XML" \
  || ko "paramètres absents du XML :${MISSING_P}"
if grep -qE '^  parameters \{' "$JF"; then
  ko "le Jenkinsfile déclare un bloc \`parameters {}\` — il entrerait en concurrence avec ceux du XML, qui portent les marqueurs de liste"
else
  ok "le Jenkinsfile ne déclare AUCUN paramètre : le formulaire reste défini par le XML substitué"
fi

echo
echo "== 4. les valeurs BRUTES sont ré-injectées avant le shell (garde non évidente) =="
# MESURÉ sur ce Jenkins (sonde jetable, 2026-08-06) : un paramètre de build
# valant `RAW>${JENKINS_HOME}<FIN` arrive au step `sh` en
# `RAW>/var/jenkins_home<FIN` — Jenkins applique EnvVars.resolve() aux valeurs
# de ParametersAction avant de composer l'environnement. `params.X` est le SEUL
# accès à la valeur littérale. Sans cette ré-injection, CERT_PEM (PEM
# multi-lignes collé par le demandeur) et IP_ALLOWLIST seraient réécrits en
# silence, et coller `${JENKINS_HOME}` deviendrait une lecture de
# l'environnement du contrôleur. C'est exactement ce que faisait le withEnv du
# job Groovy : il n'était pas décoratif.
jfc 'withEnv(["REQ_APP=${params.APP}"' \
  && ok "ré-injection des valeurs BRUTES via withEnv([...params...]) présente" \
  || ko "le withEnv([...params...]) de ré-injection a disparu — Jenkins résoudrait les \${…} de CERT_PEM/IP_ALLOWLIST avant le script"
MISSING_RAW=""
for M in "REQ_APP=\${params.APP}" "REQ_ENV=\${params.REQ_ENV}" "REQ_CLIENT_ID=\${params.CLIENT_ID" \
         "REQ_MODE=\${params.MODE}" "REQ_TEAM=\${params.TEAM" "REQ_IP_ALLOWLIST=\${params.IP_ALLOWLIST" \
         "REQ_CERT_PEM=\${params.CERT_PEM" "REQ_CERT_ROTATION=\${params.CERT_ROTATION"; do
  jfc "$M" || MISSING_RAW="${MISSING_RAW} ${M%%=*}"
done
[ -z "$MISSING_RAW" ] \
  && ok "les 8 champs de formulaire consommés par le script sont ré-injectés en valeur brute" \
  || ko "champs NON ré-injectés en brut :${MISSING_RAW} — ceux-là subiraient EnvVars.resolve()"
# REQ_API / REQ_API_VER / REQ_CALLER ne viennent PAS du formulaire : le job
# Groovy les calculait en variables locales puis les passait dans le MÊME
# withEnv. En déclaratif ils sont posés dans `env` par l'étape de dérivation —
# donc exportés à tout step `sh` du build. Leurs valeurs sont dérivées d'un
# choix généré et de l'identité du déclencheur, jamais de texte libre.
for V in REQ_API REQ_API_VER REQ_CALLER; do
  jfc "env.${V}" && ok "${V} dérivé et posé dans env (hors formulaire)" \
    || ko "${V} n'est plus posé — provision-request.sh le réclame (\${${V}:?})"
done

echo
echo "== 5. les gardes du job Groovy sont tenues =="
jfc 'API_FORMAT_INVALIDE' \
  && ok "refus loud API_FORMAT_INVALIDE présent (pas de repli silencieux sur la version 1.0.0)" \
  || ko "API_FORMAT_INVALIDE absent — une valeur sans '@' retomberait silencieusement sur 1.0.0"
jfc "error(" \
  && ok "le refus est un \`error(\` réel (build rouge), pas un simple echo" \
  || ko "aucun \`error(\` : le refus ne ferait pas échouer le build"
jfc "'anonymous'" \
  && ok "repli 'anonymous' sur l'identité du déclencheur conservé (REQ_CALLER toujours renseigné)" \
  || ko "le repli 'anonymous' a disparu — REQ_CALLER pourrait valoir 'null'"
jfc 'getBuildCauses' \
  && ok "l'identité du déclencheur est lue sur la CAUSE du build (UserIdCause), pas sur un champ saisissable" \
  || ko "getBuildCauses absent — REQ_CALLER ne serait plus dérivé de l'utilisateur réel"

echo
echo "== 6. pas d'injection : la saisie ne traverse aucune interpolation Groovy vers le shell =="
grep -q "sh '''" "$JF" \
  && ok "le bloc d'exécution est en triple quotes SIMPLES (Groovy n'y interpole rien)" \
  || ko "aucun bloc \`sh '''\` — vérifier comment la commande est écrite"
if grep -q 'sh """' "$JF"; then
  ko "un bloc \`sh \"\"\"\` (triple quotes DOUBLES) existe — Groovy y interpolerait la saisie et le token"
else
  ok "aucun bloc \`sh \"\"\"\` : impossible d'interpoler une saisie dans une chaîne shell"
fi
SH_BODY="$(awk "/sh '''/{f=1;next} f&&/'''/{exit} f" "$JF")"
if [ -n "$SH_BODY" ] && printf '%s\n' "$SH_BODY" | grep -q 'params\.'; then
  ko "un \`params.\` apparaît DANS la chaîne sh — la saisie traverserait une interpolation Groovy"
else
  ok "aucun \`params.\` dans la chaîne sh"
fi

echo
echo "== 7. le moteur est bien invoqué, et le pipeline reste MINCE =="
jfc 'bash scripts/provision-request.sh' \
  && ok "scripts/provision-request.sh invoqué" || ko "provision-request.sh non invoqué — job mort"
jfc "dir('poc-control-plane-federation')" \
  && ok "le step tourne dans poc-control-plane-federation/ (le dépôt est checkouté à la racine)" \
  || ko "dir('poc-control-plane-federation') absent — tous les chemins relatifs seraient faux"
if grep -qE '^\s*(curl|ansible-playbook) ' "$JF"; then
  ko "le Jenkinsfile appelle directement curl/ansible-playbook — la substance doit rester dans scripts/"
else
  ok "aucun curl/ansible-playbook direct : le pipeline route, le moteur reste dans scripts/"
fi
if grep -q 'skipDefaultCheckout' "$JF"; then
  ko "skipDefaultCheckout : le dépôt ne serait pas reposé dans le workspace"
else
  ok "pas de skipDefaultCheckout : le checkout implicite repose bien le dépôt"
fi
if jfc "git url:"; then
  ko "un \`git url:\` explicite subsiste — le checkout doit venir du <scm> de la coquille, source unique"
else
  ok "aucun \`git url:\` explicite : le dépôt et la branche sont déclarés une seule fois, dans le XML"
fi

echo
echo "== 8. le credential Gitea : même identité qu'avant, mais surchargeable =="
jfc 'withCredentials([string(credentialsId: env.GITEA_CREDENTIALS_ID' \
  && ok "withCredentials réellement appelé, credentialsId surchargeable" \
  || ko "withCredentials absent ou credentialsId figé"
jfc "GITEA_CREDENTIALS_ID" \
  && ok "GITEA_CREDENTIALS_ID exposé en point de config client" || ko "GITEA_CREDENTIALS_ID absent"
grep -qF "?: 'gitea-provision-token'" "$JF" \
  && ok "défaut du credentialsId = gitea-provision-token (identique au job d'origine)" \
  || ko "défaut du credentialsId inattendu — le job perdrait son token"
grep -q 'app-request' "$REPO/scripts/setup-team-onboard-jobs.sh" \
  && ok "app-request toujours listé dans JOBS de setup-team-onboard-jobs.sh" || ko "app-request absent de JOBS"

echo
echo "== 9. le total de contrôles exécutés correspond au total ATTENDU, écrit en dur =="
ACTUAL_CHECKS=$((PASS+FAIL))
if [ "$ACTUAL_CHECKS" -eq "$EXPECTED_CHECKS" ]; then
  ok "nombre de contrôles exécutés = ${EXPECTED_CHECKS} (attendu, écrit en dur en tête de ce fichier)"
else
  ko "nombre de contrôles exécutés = ${ACTUAL_CHECKS}, attendu ${EXPECTED_CHECKS} — une section a peut-être été sautée silencieusement"
fi

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
