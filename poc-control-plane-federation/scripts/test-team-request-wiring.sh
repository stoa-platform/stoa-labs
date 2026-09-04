#!/usr/bin/env bash
# test-team-request-wiring.sh — preuve X/X du CÂBLAGE du job team-request.
# Analyse statique : ni Jenkins, ni Gitea, aucun effet de bord.
#
# ── POURQUOI CE FICHIER EXISTE ───────────────────────────────────────────────
# Le pipeline ne vit PLUS en Groovy inline dans ci/jenkins/team-request.job.xml
# (<script>…</script>) : il est dans ci/Jenkinsfile.team-request, DÉCLARATIF, et
# le XML n'est plus qu'une coquille « Pipeline from SCM ». La conversion a
# introduit une jointure NOUVELLE et SILENCIEUSE si elle dérive : le formulaire
# est décrit DEUX FOIS (parameterDefinitions du XML, bloc `parameters` du
# Jenkinsfile) et c'est le XML qui gagne — Declarative ne remplace que les
# propriétés qu'il a lui-même posées (DeclarativeJobPropertyTrackerAction), un
# paramètre venu d'un config.xml est préservé indéfiniment et l'emporte à nom
# égal. §2 et §3 sont exactement là pour ça.
#
# Les constructions du job Groovy ont un ÉQUIVALENT DÉCLARATIF vérifié à leur
# place, jamais un simple abandon de contrôle :
#   node { }                →  `agent any` de niveau pipeline ;
#   stage('checkout')+git   →  checkout implicite de Declarative, dont l'URL et
#                              la branche vivent dans <scm> du XML (§12) ;
#   withEnv([params…])      →  les paramètres de build SONT déjà des variables
#                              d'environnement du step `sh` — ce que le withEnv
#                              cherchait à obtenir ; la garde réelle (aucune
#                              interpolation Groovy) est vérifiée au §7 ;
#   withCredentials(…)      →  conservé, mais avec un credentialsId
#                              SURCHARGEABLE (§6).
#
# Ancres sur le CODE réel (syntaxe d'invocation précise, ou exclusion explicite
# des lignes de commentaire) et jamais sur une simple mention en prose : un
# commentaire qui NOMME une garde ne doit pas suffire à faire virer un contrôle
# au vert (leçon du panel, cf. test-team-publish-wiring.sh §F).
#
#   ./scripts/test-team-request-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/team-request.job.xml"
JF="$REPO/ci/Jenkinsfile.team-request"
SCRIPT="$REPO/scripts/team-request.sh"
SETUP="$REPO/scripts/setup-team-onboard-jobs.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# Total ATTENDU, ÉCRIT EN DUR — indépendant de PASS+FAIL (qui devient vrai par
# construction : une section entière sautée silencieusement ferait baisser le
# total affiché SANS jamais faire échouer ce script). Toute section
# ajoutée/retirée DOIT mettre à jour ce nombre à la main — un oubli fait virer
# le §13 au rouge, ce qui EST le comportement voulu (un rappel, pas un bug).
EXPECTED_CHECKS=65

[ -f "$JOB" ] || { echo "job introuvable : $JOB"; exit 2; }
[ -f "$JF" ]  || { echo "Jenkinsfile introuvable : $JF"; exit 2; }

# Lecture NORMALISÉE du Jenkinsfile : les espaces d'ALIGNEMENT (colonnes de `=`)
# sont cosmétiques — un reformatage ne doit pas faire virer un contrôle au
# rouge, alors que la disparition d'une clé le doit.
JF_N="$(tr -s ' ' < "$JF")"
jf(){ printf '%s\n' "$JF_N" | grep -qF "$1"; }
# Corps du bloc `sh '''…'''` UNIQUEMENT (entre les deux délimiteurs) : sert aux
# contrôles qui doivent porter sur le shell RÉELLEMENT exécuté, pas sur le
# Groovy qui l'entoure ni sur les commentaires du fichier.
SH_BODY="$(awk "/sh '''/{f=1;next} f&&/'''/{exit} f" "$JF")"
# Le même corps SANS ses commentaires shell : une ceinture doit être EXÉCUTÉE,
# pas citée (même règle que JF_CODE pour le Groovy, juste en dessous).
SH_CODE="$(printf '%s\n' "$SH_BODY" | grep -vE '^[[:space:]]*#')"
# Lignes de CODE du Jenkinsfile (commentaires Groovy retirés) : un motif cité
# dans un commentaire ne doit jamais suffire à un vert.
JF_CODE="$(grep -vE '^[[:space:]]*//' "$JF")"
# Lignes de CODE de team-request.sh (commentaires pleine ligne retirés) : depuis
# G4, ce fichier PARLE d'ENV_NOT_OPEN dans un commentaire — pour dire que le
# refus a disparu avec l'axe env. Un grep sur le fichier brut prendrait cette
# prose pour la garde elle-même : c'est exactement le vert vacant que ce dépôt a
# mesuré trois fois sur ce jalon. Vérifié : aucun commentaire de FIN DE LIGNE de
# ce fichier ne cite REQ_ENV ni ENV_NOT_OPEN.
SCRIPT_CODE="$(grep -vE '^[[:space:]]*#' "$SCRIPT")"

echo "== 1. le XML reste bien formé, et le Jenkinsfile est bien un pipeline DÉCLARATIF =="
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "XML parsable" || ko "XML cassé"
grep -qE '^pipeline \{' "$JF" \
  && ok "le Jenkinsfile ouvre sur \`pipeline {\` (déclaratif, pas un script Groovy libre)" \
  || ko "le Jenkinsfile n'ouvre pas sur \`pipeline {\` — ce n'est pas un pipeline déclaratif"
grep -qE '^  stages \{' "$JF" \
  && ok "bloc \`stages\` de niveau pipeline présent" || ko "aucun bloc \`stages\` de niveau pipeline"
# `agent any` (et non `agent none`) : ce job n'a AUCUNE demande en attente, donc
# rien n'immobilise un exécuteur — et il lui FAUT un workspace dès le premier
# step (le job d'origine ouvrait directement sur `node { }`).
grep -qE '^  agent any$' "$JF" \
  && ok "\`agent any\` de niveau pipeline — workspace disponible pour tous les steps" \
  || ko "pas d'\`agent any\` de niveau pipeline — les steps n'auraient pas de workspace"
if grep -qE '^      input \{' "$JF"; then
  ko "une directive \`input\` est apparue — ce job DÉPOSE une demande, il n'en autorise aucune (la décision est le MERGE, ADR-081)"
else
  ok "aucune directive \`input\` : rien à autoriser ici, la décision reste le MERGE (ADR-081)"
fi

echo
echo "== 2. le formulaire est décrit des DEUX côtés, avec exactement les MÊMES champs =="
# Le XML est la source de vérité à l'exécution (il gagne) ; le Jenkinsfile est
# le seul formulaire quand le job est posé SANS XML. Les deux doivent coïncider.
grep -qE '^  parameters \{' "$JF" \
  && ok "bloc \`parameters\` de niveau pipeline présent (le formulaire survit à une pose sans XML)" \
  || ko "aucun bloc \`parameters\` — un job créé depuis le seul dépôt n'aurait aucun champ"
MIRROR_KO=""
for P in TEAM DESCRIPTION APPROVERS REPO; do
  grep -q "<name>${P}</name>" "$JOB" || MIRROR_KO="${MIRROR_KO} XML:${P}"
  jf "(name: '${P}'" || MIRROR_KO="${MIRROR_KO} JF:${P}"
done
[ -z "$MIRROR_KO" ] \
  && ok "les 4 champs (TEAM, DESCRIPTION, APPROVERS, REPO) sont présents dans le XML ET dans le Jenkinsfile" \
  || ko "champ(s) manquant(s) :${MIRROR_KO} — divergence SILENCIEUSE entre le formulaire posé et le formulaire versionné"
# ANTI-ÉLARGISSEMENT : pas UN champ de plus d'un côté que de l'autre. Un champ
# surnuméraire dans le Jenkinsfile serait ajouté au formulaire réel (il n'entre
# pas en collision de nom, donc rien ne l'écrase) sans que le XML — ce que
# l'ops relit — en porte la trace.
N_XML_STR=$(grep -c '<hudson.model.StringParameterDefinition>' "$JOB")
N_XML_CHO=$(grep -c '<hudson.model.ChoiceParameterDefinition>' "$JOB")
N_XML=$((N_XML_STR + N_XML_CHO))
N_JF=$(printf '%s\n' "$JF_N" | grep -cE "^ *(string|choice)\(name: '")
[ "$N_XML" -eq 4 ] && ok "le XML déclare exactement 4 paramètres (4 string, 0 choice — l'axe env est parti, G4/ADR-082 D5)" \
  || ko "le XML déclare ${N_XML} paramètres, attendu 4"
[ "$N_JF" -eq 4 ] && ok "le Jenkinsfile déclare exactement 4 paramètres" \
  || ko "le Jenkinsfile déclare ${N_JF} paramètres, attendu 4"
# ANTI-RETOUR DE L'AXE : le seul `choice` qu'ait jamais porté ce formulaire était
# l'environnement. Zéro liste fermée est donc la forme la plus tenace de
# l'assertion — elle rougit même si l'axe revient sous un AUTRE nom.
[ "$N_XML_CHO" -eq 0 ] \
  && ok "aucune ChoiceParameterDefinition dans le XML : plus une seule liste fermée à ce formulaire" \
  || ko "${N_XML_CHO} liste(s) fermée(s) dans le XML — la seule qu'il ait eue était l'axe env (et le XML GAGNE)"
[ "$N_XML" -eq "$N_JF" ] && ok "même NOMBRE de paramètres des deux côtés (aucun champ surnuméraire d'un seul côté)" \
  || ko "XML=${N_XML} paramètres, Jenkinsfile=${N_JF} — l'un des deux formulaires est plus large que l'autre"

echo
echo "== 3. les TYPES concordent, et l'axe env a disparu des deux côtés =="
# Un `string` là où le XML met un `choice` (ou l'inverse) passerait le §2 : le
# nom serait bien des deux côtés, mais le formulaire posé sans XML offrirait une
# saisie libre là où le XML impose une liste fermée.
TYPE_KO=""
for P in TEAM DESCRIPTION APPROVERS REPO; do
  grep -A1 '<hudson.model.StringParameterDefinition>' "$JOB" | grep -q "<name>${P}</name>" \
    || TYPE_KO="${TYPE_KO} XML:${P}(pas string)"
  jf "string(name: '${P}'" || TYPE_KO="${TYPE_KO} JF:${P}(pas string)"
done
[ -z "$TYPE_KO" ] \
  && ok "TEAM/DESCRIPTION/APPROVERS/REPO sont des champs texte des DEUX côtés" \
  || ko "type(s) divergent(s) :${TYPE_KO}"
# L'AXE ENV A QUITTÉ LE FORMULAIRE (G4, ADR-082, D5). Absence lue par
# ElementTree et non par grep : la LISTE ORDONNÉE des noms prouve que le parse a
# bien eu lieu — un fichier renommé ou un XML vidé rendrait une liste vide, qui
# ne ressemble à rien d'attendu. Une assertion d'absence seule (« REQ_ENV n'y est
# pas ») serait vraie de n'importe quel fichier, y compris inexistant.
XML_PARAMS=$(python3 - "$JOB" <<'PY'
import sys, xml.etree.ElementTree as T
root = T.parse(sys.argv[1]).getroot()
names = [p.findtext('name') or ''
         for p in root.iter()
         if p.tag.startswith('hudson.model.') and p.tag.endswith('ParameterDefinition')]
print(','.join(names))
PY
)
[ "$XML_PARAMS" = "TEAM,DESCRIPTION,APPROVERS,REPO" ] \
  && ok "le formulaire XML est exactement TEAM,DESCRIPTION,APPROVERS,REPO — aucun axe env (et c'est le XML qui GAGNE)" \
  || ko "formulaire XML inattendu : '${XML_PARAMS}' (attendu TEAM,DESCRIPTION,APPROVERS,REPO)"
if printf '%s\n' "$JF_CODE" | grep -q 'choice(name:'; then
  ko "un \`choice(name: …)\` subsiste dans le CODE du Jenkinsfile — le seul qu'ait eu ce formulaire était l'axe env"
else
  ok "aucun \`choice(name: …)\` dans le code du Jenkinsfile : le formulaire versionné a perdu le même champ que le XML"
fi
# Le champ n'est pas seulement retiré : sa valeur est SCELLÉE côté script, sur la
# constante d'authoring — sans quoi le retrait ne ferait que déplacer la décision
# vers une variable d'environnement du nœud (les paramètres d'un build Jenkins
# atterrissent dans l'environnement du process : fait mesuré, 2026-08-06).
printf '%s\n' "$SCRIPT_CODE" | grep -q 'REQ_ENV="\$DEPLOY_PIN_AUTHORING_ENV"' \
  && ok "team-request.sh scelle REQ_ENV sur la constante d'authoring (affectation sèche, pas un défaut)" \
  || ko "team-request.sh ne scelle pas REQ_ENV sur DEPLOY_PIN_AUTHORING_ENV — le retrait du champ ne garantirait rien"
if printf '%s\n' "$SCRIPT_CODE" | grep -q 'REQ_ENV="\${REQ_ENV:-'; then
  ko "team-request.sh garde un défaut surchargeable \`REQ_ENV:-\` — une variable de nœud rouvrirait l'axe que le formulaire vient de perdre"
else
  ok "aucun défaut surchargeable \`REQ_ENV:-\` : l'axe ne peut pas rentrer par l'environnement"
fi
# ENV_NOT_OPEN a disparu AVEC l'axe : ce refus gardait un CHOIX du formulaire, et
# il n'y a plus de choix à refuser (REQ_ENV ne peut plus valoir que la
# constante). Le garder aurait été une garde structurellement invérifiable —
# aucune saisie ne pouvant plus la déclencher. L'équivalent côté APPLY, lui,
# reste nécessaire et s'appelle désormais ENV_MISMATCH : la branche
# onboard/<team>-<env> traverse Git, où un suffixe peut être FORGÉ.
if printf '%s\n' "$SCRIPT_CODE" | grep -q 'ENV_NOT_OPEN'; then
  ko "ENV_NOT_OPEN subsiste dans le CODE de team-request.sh — un refus sans objet depuis que l'axe est scellé (G4 D5)"
else
  ok "ENV_NOT_OPEN a disparu du code de team-request.sh : plus de choix d'env, donc plus de choix à refuser"
fi

echo
echo "== 4. aucun déclencheur, des deux côtés : ce job est un FORMULAIRE, pas un webhook =="
if grep -qE '^  triggers \{' "$JF"; then
  ko "un bloc \`triggers {}\` est apparu dans le Jenkinsfile — ce job ne doit se déclencher que par saisie humaine"
else
  ok "aucun bloc \`triggers {}\` dans le Jenkinsfile"
fi
grep -q '<triggers/>' "$JOB" \
  && ok "<triggers/> vide dans le XML — miroir exact de l'absence côté Jenkinsfile" \
  || ko "le XML ne porte plus <triggers/> vide : un déclencheur venu du config.xml serait préservé indéfiniment (il GAGNE sur le Jenkinsfile) et lancerait ce formulaire tout seul"
if grep -q 'GenericTrigger' "$JOB"; then
  ko "un GenericTrigger (webhook) est apparu dans le XML"
else
  ok "aucun GenericTrigger dans le XML"
fi

echo
echo "== 5. les points de config client sont dans \`environment\` — présence ET valeur =="
grep -qE '^  environment \{' "$JF" \
  && ok "bloc \`environment\` de niveau pipeline présent" || ko "aucun bloc \`environment\` de niveau pipeline"
# GIT_HOST/GIT_REPO : mêmes défauts que ceux que team-request.sh s'applique à
# lui-même (donc aucun changement de comportement), mais rendus VISIBLES et
# surchargeables, et alignés sur l'URL du <scm> du job.
jf 'GIT_HOST = "${env.GIT_HOST ?: '"'"'http://gitea:3000'"'"'}"' \
  && ok "valeur littérale de GIT_HOST = http://gitea:3000 (alias in-cluster ; « localhost » depuis le conteneur ne désigne PAS Gitea)" \
  || ko "GIT_HOST : valeur par défaut inattendue ou absente"
jf 'GIT_REPO = "${env.GIT_REPO ?: '"'"'ci/stoa-labs'"'"'}"' \
  && ok "valeur littérale de GIT_REPO = ci/stoa-labs (dépôt plateforme, celui qui porte providers.<env>.yml)" \
  || ko "GIT_REPO : valeur par défaut inattendue ou absente"
# GIT_WEB_HOST : c'était une valeur EN DUR du withEnv du job Groovy. Sans elle,
# team-request.sh retombe sur GIT_HOST (nom interne au réseau docker) et le lien
# annoncé sur la PR est mort pour un humain.
jf 'GIT_WEB_HOST = "${env.GIT_WEB_HOST ?: '"'"'http://localhost:13000'"'"'}"' \
  && ok "valeur littérale de GIT_WEB_HOST = http://localhost:13000 (lien de PR cliquable depuis un poste)" \
  || ko "GIT_WEB_HOST : valeur par défaut inattendue ou absente — le lien posté sur la PR pointerait sur gitea:3000, non résolu hors des conteneurs"
grep -qF 'GIT_WEB_HOST' "$SCRIPT" \
  && ok "team-request.sh lit réellement GIT_WEB_HOST (le knob n'est pas décoratif)" \
  || ko "team-request.sh ne lit plus GIT_WEB_HOST — le knob serait mort"
# L'ordre compte : `environment` doit précéder `stages` pour que les valeurs
# soient dans l'environnement de TOUS les steps.
L_ENV=$(grep -n '^  environment {' "$JF" | head -1 | cut -d: -f1)
L_STAGES=$(grep -n '^  stages {' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_ENV" ] && [ -n "$L_STAGES" ] && [ "$L_ENV" -lt "$L_STAGES" ]; then
  ok "\`environment\` (ligne $L_ENV) précède \`stages\` (ligne $L_STAGES)"
else
  ko "ordre environment/stages non confirmé (environment=$L_ENV stages=$L_STAGES)"
fi

echo
echo "== 6. le credential Gitea : knob surchargeable, et JAMAIS en argv =="
jf 'GITEA_CREDENTIALS_ID = "${env.GITEA_CREDENTIALS_ID ?: '"'"'gitea-provision-token'"'"'}"' \
  && ok "GITEA_CREDENTIALS_ID surchargeable, défaut = gitea-provision-token (le credentialsId en dur du job Groovy devient un point de config client)" \
  || ko "GITEA_CREDENTIALS_ID absent ou de valeur inattendue"
jf "withCredentials(forgeCreds())" \
  && ok "withCredentials lie le credential au knob (pas un identifiant en dur au milieu du pipeline)" \
  || ko "withCredentials absent ou n'utilise pas env.GITEA_CREDENTIALS_ID"
if printf '%s\n' "$SH_BODY" | grep -q 'GITEA_TOKEN'; then
  ko "le corps du \`sh\` mentionne GITEA_TOKEN — le token doit rester dans l'ENVIRONNEMENT (lu par le script), jamais écrit dans la ligne de commande"
else
  ok "le corps du \`sh\` ne touche jamais GITEA_TOKEN : il est hérité par l'environnement et lu par team-request.sh (\${GITEA_TOKEN:?})"
fi
# 2026-09-04 : le secret de la forge porte un nom NEUTRE (un gestionnaire
# d'identité rend un jeton OU un couple). La PROPRIÉTÉ mesurée reste la même :
# sans secret, le script refuse en le nommant, il ne part pas travailler.
grep -qF 'GITEA_TOKEN="${FORGE_SECRET:-${GITEA_TOKEN:-}}"' "$SCRIPT" \
  && grep -qF 'SECRET_FORGE_REQUIS' "$SCRIPT" \
  && ok "team-request.sh exige réellement un secret de forge (FORGE_SECRET ou son alias) — refus nommé s'il manque" \
  || ko "team-request.sh n'exige plus de secret — un build sans credential échouerait loin de sa cause"

echo
echo "== 7. pas d'injection : les valeurs saisies sont lues par le SHELL, jamais interpolées par Groovy =="
# La saisie humaine est une donnée de tiers. En déclaratif, les paramètres de
# build sont DÉJÀ des variables d'environnement du step — d'où la disparition du
# withEnv() explicite. Ce qui doit être prouvé n'a pas changé : aucune valeur
# saisie ne doit traverser une interpolation Groovy pour atterrir dans une
# chaîne shell.
grep -q "sh '''" "$JF" \
  && ok "le bloc d'exécution est en triple quotes SIMPLES (Groovy n'y interpole rien)" \
  || ko "aucun bloc \`sh '''\` — vérifier comment la commande est écrite"
if grep -q 'sh """' "$JF"; then
  ko "un bloc \`sh \"\"\"\` (triple quotes DOUBLES) existe — Groovy y interpolerait les champs du formulaire"
else
  ok "aucun bloc \`sh \"\"\"\` : impossible d'interpoler une saisie dans une chaîne shell"
fi
# Le vrai danger n'est PAS `params.` en soi — c'est `params.` INTERPOLÉ DANS UNE
# CHAÎNE SHELL. Le `withEnv([... params.X ...])` est OBLIGATOIRE : MESURÉ sur ce
# Jenkins (sonde jetable, 2026-08-06), un paramètre de build valant
# `RAW>${JENKINS_HOME}<FIN` arrive au step `sh` en `RAW>/var/jenkins_home<FIN`
# (EnvVars.resolve() sur les valeurs de ParametersAction). `params.X` est le
# SEUL accès à la valeur littérale. Ici DESCRIPTION et APPROVERS finissent
# ÉCRITS dans providers.<env>.yml puis committés : sans ré-injection, l'entrée
# déclarée ne serait plus celle demandée, et `${JENKINS_HOME}` saisi dans une
# description deviendrait une lecture de l'env du contrôleur vers un dépôt Git.
if printf '%s\n' "$JF_CODE" | grep -q 'withEnv(\["TEAM=\${params\.TEAM}'; then
  ok "ré-injection des valeurs BRUTES via withEnv([...params...]) présente — les \${…} d'une saisie ne sont pas expansés par Jenkins"
else
  ko "le withEnv([...params...]) de ré-injection a disparu — Jenkins résoudrait les \${…} de DESCRIPTION/APPROVERS avant le script (corruption silencieuse + lecture de l'env du contrôleur)"
fi
MISSING_RAW=""
for P in TEAM DESCRIPTION APPROVERS REPO; do
  printf '%s\n' "$JF_CODE" | grep -q "${P}=\${params\.${P}" || MISSING_RAW="${MISSING_RAW} ${P}"
done
[ -z "$MISSING_RAW" ] \
  && ok "les 4 champs du formulaire sont ré-injectés en valeur brute" \
  || ko "champs NON ré-injectés en brut :${MISSING_RAW} — ceux-là subiraient EnvVars.resolve()"
if [ -n "$SH_BODY" ] && printf '%s\n' "$SH_BODY" | grep -q 'params\.'; then
  ko "un \`params.\` apparaît DANS la chaîne sh — la saisie traverserait une interpolation Groovy"
else
  ok "aucun \`params.\` dans la chaîne sh : la saisie n'y traverse aucune interpolation Groovy"
fi
[ -n "$SH_BODY" ] \
  && ok "le corps du bloc \`sh\` est bien extractible (les contrôles suivants portent sur le shell réellement exécuté)" \
  || ko "corps du bloc \`sh\` introuvable — les contrôles de shell ci-dessous seraient vides (vert vacant)"

echo
echo "== 8. les ceintures du shell survivent (REPO vide, dry-run désarmé), et AVANT l'appel au script =="
# `if [ -z \"\$REPO\" ]; then unset REPO; fi` : reprise TELLE QUELLE du job
# d'origine. Le `\${REPO:-<team>/apis}` du script couvre déjà la chaîne vide,
# mais l'unset rend l'intention explicite et resterait correct même si le script
# passait à `\${REPO-…}` (sans deux-points), qui ne traite PAS la chaîne vide
# comme une absence.
printf '%s\n' "$SH_BODY" | grep -qF 'if [ -z "$REPO" ]; then unset REPO; fi' \
  && ok "la garde \`unset REPO\` est présente dans le shell (pas seulement citée en commentaire)" \
  || ko "garde \`unset REPO\` absente du corps du \`sh\` — REPO vide pourrait être pris pour un choix explicite"
grep -qF 'REPO="${REPO:-${TEAM}/apis}"' "$SCRIPT" \
  && ok "team-request.sh calcule bien le défaut <team>/apis quand REPO est absent" \
  || ko "le défaut REPO de team-request.sh a changé — la garde du pipeline ne correspond plus"
L_UNSET=$(grep -n 'unset REPO' "$JF" | head -1 | cut -d: -f1)
L_RUN=$(grep -n 'bash scripts/team-request\.sh' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_UNSET" ] && [ -n "$L_RUN" ] && [ "$L_UNSET" -lt "$L_RUN" ]; then
  ok "unset ligne $L_UNSET, appel ligne $L_RUN (la garde précède l'appel)"
else
  ko "garde APRÈS l'appel (ou introuvable) : unset=$L_UNSET appel=$L_RUN"
fi
# LE DRY-RUN EST UN CONTRAT D'ÉPREUVE, PAS UN MODE DU JOB. team-request.sh sort 0
# sur `DRY_RUN=1` après ses gardes et AVANT le clone — c'est la surface
# qu'éprouve test-palier-retention.sh ⑱. Mais les variables d'un nœud Jenkins
# atterrissent dans l'environnement du step `sh` : sans ce désarmement, poser
# DRY_RUN=1 sur le nœud rendrait le formulaire MUET — build VERT, `GARDES_OK`
# dans le log, aucune PR ouverte. C'est la classe de contournement que le
# scellement de l'axe env ferme par ailleurs. Présence ET position : un `unset`
# placé après l'appel ne désarmerait plus rien.
L_DRY=$(grep -n 'unset DRY_RUN' "$JF" | head -1 | cut -d: -f1)
if printf '%s\n' "$SH_CODE" | grep -qF 'unset DRY_RUN' \
   && [ -n "$L_DRY" ] && [ -n "$L_RUN" ] && [ "$L_DRY" -lt "$L_RUN" ]; then
  ok "\`unset DRY_RUN\` dans le code du shell (ligne $L_DRY), avant l'appel (ligne $L_RUN) : une variable de nœud ne peut pas rendre le formulaire muet"
else
  ko "\`unset DRY_RUN\` absent du code du \`sh\` (ou placé après l'appel : dry=$L_DRY appel=$L_RUN) — DRY_RUN=1 sur le nœud donnerait un build VERT sans aucune PR"
fi
printf '%s\n' "$SH_BODY" | grep -qE '^ *set \+x' \
  && ok "\`set +x\` en tête du bloc shell : aucune trace d'exécution (le token du credential ne doit jamais être tracé)" \
  || ko "\`set +x\` absent du bloc shell"

echo
echo "== 9. team-request.sh est invoqué, depuis le bon dossier, et le pipeline reste MINCE =="
printf '%s\n' "$SH_BODY" | grep -qF 'bash scripts/team-request.sh' \
  && ok "scripts/team-request.sh réellement invoqué (dans le corps du \`sh\`, pas en commentaire)" \
  || ko "team-request.sh non invoqué — job mort"
jf "dir(env.GIT_SUBDIR)" \
  && ok "l'appel a lieu dans dir(env.GIT_SUBDIR) — le chemin relatif scripts/… existe" \
  || ko "dir(env.GIT_SUBDIR) absent : \`bash scripts/team-request.sh\` ne trouverait rien"
L_DIR=$(grep -n "dir(env.GIT_SUBDIR)" "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_DIR" ] && [ -n "$L_RUN" ] && [ "$L_DIR" -lt "$L_RUN" ]; then
  ok "dir (ligne $L_DIR) enveloppe bien l'appel (ligne $L_RUN)"
else
  ko "dir ne précède pas l'appel (dir=$L_DIR appel=$L_RUN)"
fi
# Le pipeline ROUTE, il ne réimplémente pas : aucun appel direct à Git, à
# Ansible ou à l'API Gitea ne doit apparaître ici.
if printf '%s\n' "$JF_CODE" | grep -qE '^\s*(curl|ansible-playbook|git) '; then
  ko "le Jenkinsfile appelle directement curl/ansible-playbook/git — la substance doit rester dans scripts/ et ansible/roles/"
else
  ok "aucun curl/ansible-playbook/git direct : le pipeline route, le moteur reste dans scripts/ et ansible/roles/"
fi
if printf '%s\n' "$SH_BODY" | grep -qE '^ *(curl|git|python3|ansible-playbook) '; then
  ko "le corps du \`sh\` fait autre chose que router vers le script (curl/git/python3/ansible-playbook)"
else
  ok "le corps du \`sh\` ne fait QUE préparer l'environnement et appeler le script"
fi

echo
echo "== 10. les cibles appelées existent et sont parsables =="
[ -f "$SCRIPT" ] && ok "scripts/team-request.sh présent" || ko "team-request.sh absent — appel mort"
bash -n "$SCRIPT" 2>/dev/null && ok "team-request.sh : syntaxe shell valide" || ko "team-request.sh non parsable"
[ -f "$REPO/ansible/team-plan.yml" ] \
  && ok "ansible/team-plan.yml présent (le plan commenté sur la PR)" || ko "ansible/team-plan.yml absent — le plan de team-request.sh serait mort"
[ -f "$REPO/ansible/providers.dev.yml" ] \
  && ok "ansible/providers.dev.yml présent (le fichier que la PR modifie)" || ko "ansible/providers.dev.yml absent"

echo
echo "== 11. le job est posé par setup-team-onboard-jobs.sh, SANS substitution de listes =="
grep -q 'team-request' "$SETUP" \
  && ok "team-request listé dans JOBS de setup-team-onboard-jobs.sh" || ko "team-request absent de JOBS"
# NO-OP DE SUBSTITUTION : la détection des listes dynamiques est un grep sur le
# FICHIER ENTIER (setup-team-onboard-jobs.sh §1). Un marqueur écrit ici — même
# à l'intérieur d'un commentaire XML — ferait basculer ce job en mode
# substitution et lui imposerait un Gitea joignable + un token à chaque pose,
# et casserait la preuve « octet pour octet » de test-generate-choices.sh §5.
if grep -Eq '<!--CHOICES:(TEAMS|APIS)-->' "$JOB"; then
  ko "un marqueur de liste dynamique est présent dans le XML — ce job dépendrait désormais de Gitea à chaque pose, et la preuve octet pour octet de test-generate-choices.sh §5 tomberait"
else
  ok "aucun marqueur de liste dynamique : le XML est copié tel quel, sans sed, sans Gitea, sans token"
fi
# Un commentaire XML ne peut pas contenir « -- » (xmllint le refuse) : la
# réécriture de l'en-tête est aussi une porte à laquelle on se cogne.
python3 - "$JOB" <<'PY' && ok "aucun commentaire XML malformé (pas de '--' interne)" || ko "commentaire XML contenant '--' : le fichier ne serait plus parsable"
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
sys.exit(0 if all('--' not in c for c in re.findall(r'<!--(.*?)-->', src, re.S)) else 1)
PY

echo
echo "== 12. plus AUCUN Groovy inline dans le job : c'est un Pipeline from SCM =="
# LA demande client : des Jenkinsfile versionnés, pas un pipeline en dur dans un
# config.xml. Ce contrôle est la preuve que la conversion a eu lieu et qu'elle
# ne peut pas régresser en silence.
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
grep -qF '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.team-request</scriptPath>' "$JOB" \
  && ok "scriptPath pointe sur ci/Jenkinsfile.team-request" || ko "scriptPath absent ou divergent"
grep -qF '<lightweight>false</lightweight>' "$JOB" \
  && ok "lightweight=false : le workspace porte tout le dépôt (scripts/, ansible/), pas seulement le Jenkinsfile" \
  || ko "lightweight absent ou true — le workspace n'aurait que le Jenkinsfile, l'appel scripts/ mourrait"
# L'URL et la branche du `stage('checkout') { git url: … }` d'origine ne sont
# pas perdues : elles vivent dans <scm>, et c'est ce que Declarative checkoute.
grep -qF '<url>http://gitea:3000/ci/stoa-labs.git</url>' "$JOB" \
  && ok "l'URL du checkout d'origine survit dans <scm> (http://gitea:3000/ci/stoa-labs.git)" \
  || ko "URL du <scm> absente ou divergente de celle du job Groovy"
grep -qF '<name>*/main</name>' "$JOB" \
  && ok "branche */main dans <scm> — même branche que le \`git branch: 'main'\` d'origine" \
  || ko "branche du <scm> absente ou divergente"
if printf '%s\n' "$JF_CODE" | grep -q 'git url:'; then
  ko "un \`git url:\` explicite subsiste dans le Jenkinsfile — le checkout doit rester celui, implicite, de Declarative"
else
  ok "aucun \`git url:\` explicite : le checkout est celui, implicite, de Declarative (piloté par <scm>)"
fi
# Le Jenkinsfile lui-même doit rester déclaratif : ni try/catch, ni pipeline
# scripté déguisé. Ce job n'ayant pas de `post`, il n'a besoin d'AUCUN `node()`.
if grep -qE '^\s*(try \{|\} catch)' "$JF"; then
  ko "le Jenkinsfile contient un try/catch — la gestion d'erreur doit passer par \`post\`"
else
  ok "aucun try/catch : un échec est un build rouge, comme dans le job d'origine"
fi
NODE_COUNT=$(grep -cE '^\s*node\(' "$JF")
[ "$NODE_COUNT" -eq 0 ] \
  && ok "aucun \`node(...)\` : pas de \`post\` ici, donc rien à allouer à la main (le pipeline reste déclaratif de bout en bout)" \
  || ko "${NODE_COUNT} \`node(...)\` trouvé(s), attendu 0 — le pipeline redevient scripté"
SCRIPT_BLOCKS=$(grep -cE '^\s*script \{' "$JF")
[ "$SCRIPT_BLOCKS" -eq 0 ] \
  && ok "aucun bloc \`script {}\` — 100% déclaratif" \
  || ko "${SCRIPT_BLOCKS} bloc(s) \`script {}\` — le Groovy revient par la fenêtre"
STAGE_COUNT=$(grep -cE "^    stage\('" "$JF")
[ "$STAGE_COUNT" -eq 1 ] \
  && ok "une seule étape (team-request) : le \`stage('checkout')\` d'origine est devenu le checkout implicite" \
  || ko "${STAGE_COUNT} étapes, attendu 1"

echo
echo "== 13. le total de contrôles exécutés correspond au total ATTENDU, écrit en dur =="
# Le `RÉSULTAT : %d/%d` final imprime PASS/(PASS+FAIL) — une formule
# auto-référentielle, vraie par construction. CE contrôle compare contre
# EXPECTED_CHECKS, une CONSTANTE écrite en tête de ce fichier.
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
