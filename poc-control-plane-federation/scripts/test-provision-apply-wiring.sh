#!/usr/bin/env bash
# test-provision-apply-wiring.sh — preuve X/X du CÂBLAGE du job provision-apply
# (A2, GOAL cd-applications). Analyse statique : ni Jenkins, ni Gitea.
#
# ── CE QUI A CHANGÉ (A2) ─────────────────────────────────────────────────────
# Le pipeline ne vit PLUS en Groovy inline dans ci/jenkins/provision-apply.job.xml
# (<script>…</script>) : il est dans ci/Jenkinsfile.provision-apply, DÉCLARATIF,
# et le XML n'est plus qu'une coquille « Pipeline from SCM » (contrainte du
# GOAL : aucun job.xml porteur de logique). Ce test suit :
#   - $JF   (le Jenkinsfile amont)  porte les gardes du PIPELINE ;
#   - $JOB  (le XML)                 ne porte plus que déclencheur + pointeur SCM,
#                                    et doit prouver l'ABSENCE de tout Groovy ;
#   - $JFD  (Jenkinsfile.selfservice, l'aval) porte le checkout du SHA mergé.
#
# CE QUE CE TEST DÉFEND. test-provision-apply-a2.sh prouve que la réconciliation
# REFUSE ce qu'elle doit refuser et que la lib DIGÈRE le bon manifeste. Il ne
# prouve pas qu'on les APPELLE, ni dans le bon ORDRE : réconciliation AVANT la
# pause, garde d'identité AVANT l'apply, nourrie par les identités RÉCONCILIÉES
# (pas le payload), MERGE_SHA PASSÉ à l'aval, l'aval qui REFUSE un appel amont
# sans référence, l'annonce de l'aval CONFRONTÉE à la demande (mode pinned ET
# SHA égal), le statut de PR gaté par la FORGE. Une garde correcte branchée au
# mauvais endroit — ou débranchée par une édition ultérieure — est une garde
# inexistante.
#
# Motif anti « vert vacant » : TOUTES les ancres portent sur une vue CODE des
# Jenkinsfile — les lignes de commentaire `//` (Groovy) et `#` (shell embarqué)
# sont blanchies, numérotation conservée. Un motif présent dans un COMMENTAIRE
# qui NOMME la chose sans l'appeler ne verdit rien, et les ORDRES sont vérifiés
# par numéros de ligne (critique adverse de la spec A2, 2026-09-02).
#
#   ./scripts/test-provision-apply-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/provision-apply.job.xml"
JF="$REPO/ci/Jenkinsfile.provision-apply"
JFD="$REPO/ci/Jenkinsfile.selfservice"
CMT="$REPO/scripts/provision-apply-comment.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
TMP="$(mktemp -d /tmp/pa-wiring.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

# Total ATTENDU, ÉCRIT EN DUR — indépendant de PASS+FAIL (vrai par construction
# quel que soit le nombre de contrôles exécutés : une section sautée en silence
# ferait baisser le total SANS rougir). Toute section ajoutée/retirée DOIT le
# mettre à jour à la main. Le contrôle final n'est pas compté dedans.
EXPECTED_CHECKS=140

[ -f "$JOB" ] || { echo "job introuvable : $JOB"; exit 2; }
[ -f "$JF" ]  || { echo "Jenkinsfile introuvable : $JF"; exit 2; }
[ -f "$JFD" ] || { echo "Jenkinsfile aval introuvable : $JFD"; exit 2; }

# Vue CODE : commentaires `//` et `#` blanchis (numérotation conservée), espaces
# d'alignement écrasés pour les recherches par motif (un reformatage ne rougit
# pas, la disparition d'une clé, si).
code_view(){ awk '{ if ($0 ~ /^[[:space:]]*(\/\/|#)/) print ""; else print }' "$1"; }
code_view "$JF"  > "$TMP/jf.code";  tr -s ' ' < "$TMP/jf.code"  > "$TMP/jf.norm"
code_view "$JFD" > "$TMP/jfd.code"; tr -s ' ' < "$TMP/jfd.code" > "$TMP/jfd.norm"
jf(){  grep -qF "$1" "$TMP/jf.norm"; }
jfd(){ grep -qF "$1" "$TMP/jfd.norm"; }
# Numéro de la première ligne de CODE qui contient un motif (fichier code_view).
code_line(){ grep -n -F "$2" "$1" | head -1 | cut -d: -f1; }
indent_of(){ sed -n "${2}p" "$1" | sed 's/^\( *\).*/\1/' | awk '{ print length($0) }'; }

echo "== 1. le XML est une coquille, le Jenkinsfile un pipeline DÉCLARATIF =="
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "XML parsable" || ko "XML cassé"
grep -q '<script>' "$JOB" \
  && ko "le XML porte encore un <script> — du Groovy inline hors Git (contrainte du GOAL violée)" \
  || ok "AUCUN <script> dans le XML : zéro Groovy inline"
grep -q 'CpsScmFlowDefinition' "$JOB" \
  && ok "définition CpsScmFlowDefinition (pipeline from SCM)" || ko "pas de CpsScmFlowDefinition"
grep -q 'CpsFlowDefinition"' "$JOB" \
  && ko "une CpsFlowDefinition (inline) subsiste" || ok "aucune CpsFlowDefinition inline"
grep -q '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.provision-apply</scriptPath>' "$JOB" \
  && ok "scriptPath = poc-control-plane-federation/ci/Jenkinsfile.provision-apply" || ko "scriptPath divergent"
grep -q '<url>http://gitea:3000/ci/stoa-labs.git</url>' "$JOB" \
  && ok "dépôt plateforme vu de l'agent (http://gitea:3000/ci/stoa-labs.git)" || ko "URL SCM inattendue"
grep -q '<name>\*/main</name>' "$JOB" \
  && ok "branche */main (un pipeline sur une branche de feature serait éditable hors revue)" || ko "branche SCM ≠ */main"
grep -q '<lightweight>false</lightweight>' "$JOB" \
  && ok "lightweight=false (le workspace porte scripts/ et ci/lib/)" || ko "lightweight absent ou true"
grep -q 'DisableConcurrentBuildsJobProperty' "$JOB" \
  && ok "un apply à la fois (DisableConcurrentBuilds dans le XML)" || ko "concurrence non interdite dans le XML"
grep -qE '^pipeline \{' "$TMP/jf.code" \
  && ok "le Jenkinsfile ouvre sur \`pipeline {\` (déclaratif)" || ko "pas un pipeline déclaratif"
grep -qE '^  stages \{' "$TMP/jf.code" && ok "bloc \`stages\` présent" || ko "aucun bloc \`stages\`"
jf "options { disableConcurrentBuilds() }" \
  && ok "disableConcurrentBuilds() dans le Jenkinsfile aussi" || ko "disableConcurrentBuilds absent du Jenkinsfile"
grep -qE '^  agent none' "$TMP/jf.code" && ok "\`agent none\` au niveau pipeline" || ko "agent none absent"

echo
echo "== 2. le webhook capte les 7 clés, dont MERGE_SHA — Jenkinsfile ET XML (miroir, le XML gagne) =="
for K in PR_BRANCH PR_NUMBER PR_ACTION PR_MERGED PR_MERGED_BY PR_REQUESTER MERGE_SHA; do
  jf "[key: '$K'," && ok "clé $K dans le Jenkinsfile" || ko "clé $K absente du Jenkinsfile"
done
jf "[key: 'MERGE_SHA', value: '\$.pull_request.merge_commit_sha']" \
  && ok "MERGE_SHA = \$.pull_request.merge_commit_sha (la référence vient du webhook, puis est réconciliée)" \
  || ko "MERGE_SHA ne pointe pas merge_commit_sha"
jf "token: 'stoa-provision-apply'" && ok "token stoa-provision-apply (Jenkinsfile)" || ko "token inattendu"
jf "regexpFilterText: '\$PR_ACTION|\$PR_MERGED'" && ok "filterText (Jenkinsfile)" || ko "filterText inattendu"
jf "regexpFilterExpression: '^closed\\\\|true\$'" && ok "filterExpression ^closed\\|true\$ (Jenkinsfile)" || ko "filterExpression inattendue — laisserait passer une fermeture SANS merge"
MIRROR_KO=""
for K in PR_BRANCH PR_NUMBER PR_ACTION PR_MERGED PR_MERGED_BY PR_REQUESTER MERGE_SHA; do
  grep -q "<key>${K}</key>" "$JOB" || MIRROR_KO="${MIRROR_KO} ${K}"
done
[ -z "$MIRROR_KO" ] && ok "les 7 genericVariables sont dans le XML à l'identique" || ko "clés absentes du XML :${MIRROR_KO}"
grep -q '<key>MERGE_SHA</key><value>$.pull_request.merge_commit_sha</value>' "$JOB" \
  && ok "MERGE_SHA = merge_commit_sha dans le XML (le webhook n'est pas borgne dès la pose)" || ko "MERGE_SHA du XML divergent"
grep -q '<token>stoa-provision-apply</token>' "$JOB" && ok "token identique dans le XML" || ko "token du XML divergent"
grep -q '<regexpFilterText>\$PR_ACTION|\$PR_MERGED</regexpFilterText>' "$JOB" && ok "filterText identique dans le XML" || ko "filterText du XML divergent"
grep -q '<regexpFilterExpression>\^closed\\|true\$</regexpFilterExpression>' "$JOB" && ok "filterExpression identique dans le XML" || ko "filterExpression du XML divergente"
grep -qE '^  parameters \{' "$TMP/jf.code" \
  && ko "un bloc \`parameters {}\` de niveau pipeline existe — un lanceur manuel pourrait nommer MERGE_SHA/PR_NUMBER lui-même" \
  || ok "aucun bloc \`parameters {}\` : ces valeurs ne viennent QUE du webhook"

echo
echo "== 3. la RÉCONCILIATION : appelée AVANT la pause, agent propre, faits relus, sans interpolation =="
L_REC=$(code_line "$TMP/jf.code" 'bash scripts/provision-apply-reconcile.sh')
[ -n "$L_REC" ] && ok "provision-apply-reconcile.sh réellement invoqué (ligne $L_REC, vue code)" || ko "réconciliation non appelée"
L_INPUT=$(code_line "$TMP/jf.code" 'def creds = input(')
[ -n "$L_INPUT" ] && ok "pause nominative = \`input()\` SCRIPTÉ (ligne $L_INPUT) : rend le mot de passe en Secret, transmissible au build aval" || ko "aucun input() scripté — plus de pause nominative (ou directive déclarative : String, intransmissible en PasswordParameterValue)"
grep -qE '^\s*input \{' "$TMP/jf.code" && ko "une directive \`input {\` déclarative subsiste — son V_PASS serait une String d'environnement (ClassCastException au build aval, mesuré #75)" || ok "aucune directive input déclarative (le mot de passe ne devient jamais une variable d'environnement)"
if [ -n "$L_REC" ] && [ -n "$L_INPUT" ] && [ "$L_REC" -lt "$L_INPUT" ]; then
  ok "réconciliation (ligne $L_REC) AVANT la pause (ligne $L_INPUT) : personne n'est réveillé pour un payload forgé ou périmé"
else
  ko "réconciliation APRÈS la pause (ou introuvable) : rec=$L_REC input=$L_INPUT"
fi
REC_LINE=$(sed -n "${L_REC:-0}p" "$TMP/jf.code")
printf '%s' "$REC_LINE" | grep -q "^ *sh '" \
  && ok "chaîne sh de la réconciliation en quotes SIMPLES (PR_BRANCH/PR_NUMBER/MERGE_SHA lus par le shell)" \
  || ko "chaîne sh de la réconciliation en quotes doubles — Groovy interpolerait des valeurs du webhook"
printf '%s' "$REC_LINE" | grep -q 'RECONCILE_OUT="$WORKSPACE/.a2-reconcile.env"' \
  && ok "RECONCILE_OUT posé vers \$WORKSPACE/.a2-reconcile.env" || ko "RECONCILE_OUT absent ou autre chemin"
printf '%s' "$REC_LINE" | grep -q 'RECONCILE_FACTS="$WORKSPACE/.a2-reconcile.facts"' \
  && ok "RECONCILE_FACTS posé (les faits relus sur la forge, écrits succès comme échec)" || ko "RECONCILE_FACTS absent — le post{always} n'aurait que le payload"
jf 'readFile("${env.WORKSPACE}/.a2-reconcile.env")' \
  && ok "le fichier réconcilié est RELU (readFile ; pas de readProperties, plugin absent du lab)" || ko "le fichier réconcilié n'est pas relu"
for K in GITEA_MERGED_BY GITEA_REQUESTER APP_NAME ENV_NAME MANIFEST MERGED_DIGEST; do
  jf "env.$K = kv.$K" && ok "assignation EXPLICITE env.$K = kv.$K (pas de env.\"\$k\" dynamique)" || ko "env.$K non assigné explicitement"
done
grep -q 'env\."\$' "$TMP/jf.code" || grep -q 'env.setProperty' "$TMP/jf.code" \
  && ko "assignation dynamique d'env (env.\"\$k\" / setProperty) présente" || ok "aucune assignation dynamique d'env"
jf "withCredentials([string(credentialsId: env.GITEA_CREDENTIALS_ID, variable: 'GITEA_TOKEN')])" \
  && ok "token Gitea lu via env.GITEA_CREDENTIALS_ID, exposé en GITEA_TOKEN (jamais en argv)" || ko "withCredentials n'utilise pas env.GITEA_CREDENTIALS_ID"
jf "beforeAgent true" && ok "\`beforeAgent true\` : une PR hors provision/* n'alloue pas d'agent pour rien" || ko "beforeAgent absent"
[ "$(grep -c 'beforeAgent true' "$TMP/jf.norm")" -ge 2 ] && ok "\`beforeAgent true\` sur les DEUX stages gardés (pause scriptée sans agent : la condition passe avant toute allocation)" || ko "beforeAgent true absent d'un des deux stages gardés"
[ "$(grep -cF "expression { (env.PR_BRANCH ?: '').startsWith('provision/') }" "$TMP/jf.norm")" -ge 2 ] \
  && ok "garde de branche provision/* sur les DEUX stages (réconciliation et apply)" || ko "garde de branche provision/* absente d'un stage"
L_ST_REC=$(code_line "$TMP/jf.code" "stage('Réconciliation")
L_AG_REC=$(awk "NR>${L_ST_REC:-0} && /^ *agent any/ {print NR; exit}" "$TMP/jf.code")
[ -n "$L_AG_REC" ] && [ -n "$L_INPUT" ] && [ "$L_AG_REC" -lt "$L_INPUT" ] \
  && ok "le stage de réconciliation a son propre \`agent any\` (ligne $L_AG_REC), libéré avant la pause" || ko "agent du stage de réconciliation introuvable avant la pause"
jf "GITEA_HEAD_REF=" && jf "env.GITEA_HEAD_REF = line.substring" \
  && ok "les FAITS (GITEA_HEAD_REF) sont chargés dans env. par un post{always} de stage" || ko "GITEA_HEAD_REF non chargé depuis les faits"
L_FACTS=$(code_line "$TMP/jf.code" 'env.GITEA_HEAD_REF = line.substring')
[ -n "$L_FACTS" ] && [ -n "$L_INPUT" ] && [ "$L_FACTS" -lt "$L_INPUT" ] && ok "faits chargés (ligne $L_FACTS) avant la pause" || ko "faits chargés après la pause"

echo
echo "== 4. la garde d'identité : sous node, sans V_PASS, AVANT l'apply, nourrie par les identités RÉCONCILIÉES =="
L_GUARD=$(code_line "$TMP/jf.code" 'sh scripts/lib/assert-merge-identity.sh')
GUARD_LINE=$(sed -n "${L_GUARD:-0}p" "$TMP/jf.code")
[ -n "$L_GUARD" ] && ok "assert-merge-identity.sh réellement invoquée (ligne $L_GUARD)" || ko "garde d'identité non appelée"
printf '%s' "$GUARD_LINE" | grep -qF -- '--merged-by "${GITEA_MERGED_BY:-}"' \
  && ok "--merged-by alimenté par GITEA_MERGED_BY (relu sur la forge)" || ko "--merged-by non alimenté par GITEA_MERGED_BY"
printf '%s' "$GUARD_LINE" | grep -qF -- '--requester "${GITEA_REQUESTER:-}"' \
  && ok "--requester alimenté par GITEA_REQUESTER (relu sur la forge)" || ko "--requester non alimenté par GITEA_REQUESTER"
printf '%s' "$GUARD_LINE" | grep -qF -- '--vault-user "${V_USER:-}"' \
  && ok "--vault-user alimenté par V_USER (la saisie de la pause)" || ko "--vault-user non alimenté par V_USER"
if printf '%s' "$GUARD_LINE" | grep -qE 'PR_MERGED_BY|PR_REQUESTER'; then
  ko "la garde lit encore PR_MERGED_BY/PR_REQUESTER du PAYLOAD — un porteur du token GWT se déclarerait mergeur"
else
  ok "la garde ne lit PAS les identités du payload (PR_MERGED_BY/PR_REQUESTER)"
fi
printf '%s' "$GUARD_LINE" | grep -q "sh '" && ok "chaîne sh de la garde en quotes simples" || ko "chaîne sh de la garde en quotes doubles"
L_BUILD=$(code_line "$TMP/jf.code" 'def b = build(job: env.APPLY_JOB')
[ -n "$L_BUILD" ] && ok "build(job: env.APPLY_JOB…) présent (ligne $L_BUILD)" || ko "aucun build de l'aval"
if [ -n "$L_GUARD" ] && [ -n "$L_BUILD" ] && [ "$L_GUARD" -lt "$L_BUILD" ]; then
  ok "garde ligne $L_GUARD, apply ligne $L_BUILD (l'ordre EST la garde)"
else
  ko "garde APRÈS l'apply (ou introuvable) : garde=$L_GUARD apply=$L_BUILD"
fi
if [ -n "$L_INPUT" ] && [ -n "$L_GUARD" ] && [ "$L_INPUT" -lt "$L_GUARD" ]; then
  ok "pause (ligne $L_INPUT) avant la garde (ligne $L_GUARD) : la garde compare une identité SAISIE"
else
  ko "la garde précède la pause : elle n'aurait rien à comparer"
fi
# La garde tourne SOUS un node ouvert entre la pause et elle, et sous withEnv(['V_PASS=']).
L_NODE1=$(awk "NR>${L_INPUT:-0} && NR<${L_GUARD:-0} && /node\(\"\\\$\{env.POST_AGENT_LABEL/ {n=NR} END {print n}" "$TMP/jf.code")
[ -n "$L_NODE1" ] && ok "la garde tourne sous un \`node(\` ouvert après la pause (ligne $L_NODE1)" || ko "aucun node( entre la pause et la garde — le sh de la garde n'aurait pas de workspace"
L_WE1=$(awk "NR>${L_INPUT:-0} && NR<${L_GUARD:-0} && /withEnv\(\[\"V_USER=/ {n=NR} END {print n}" "$TMP/jf.code")
[ -n "$L_WE1" ] && ok "…et sous withEnv([\"V_USER=…\"]) (ligne $L_WE1) : seul le LOGIN entre dans l'environnement du shell" || ko "la garde ne reçoit pas V_USER par withEnv"
if grep -E 'withEnv|^\s*sh ' "$TMP/jf.code" | grep -q 'V_PASS'; then
  ko "V_PASS apparaît dans un withEnv ou un sh — le mot de passe entrerait dans l'environnement d'un process shell"
else
  ok "V_PASS n'apparaît dans AUCUN withEnv ni sh : le Secret ne traverse que Groovy, de input() au build aval"
fi
grep -q "password(name: 'V_PASS'" "$TMP/jf.code" && ok "le mot de passe de la pause est un paramètre \`password\` nommé V_PASS" || ko "V_PASS non déclaré en \`password\`"
grep -q "string(name: 'V_USER'" "$TMP/jf.code" && ok "le login de la pause est un paramètre \`string\` nommé V_USER" || ko "V_USER absent"
grep -q 'Secret.fromString' "$TMP/jf.code" \
  && ko "Secret.fromString utilisé — NON whitelisté dans le sandbox (mesuré build #78)" \
  || ok "aucun Secret.fromString (non whitelisté) : le Secret vient de input() lui-même"

echo
echo "== 5. l'apply : HORS nœud, passe MERGE_SHA, CONFRONTE mode+SHA, rapporte puis rend le verdict =="
L_ST_APPLY=$(code_line "$TMP/jf.code" "stage('Appliquer au SHA mergé")
if awk "NR>${L_ST_APPLY:-0} && NR<${L_BUILD:-0}" "$TMP/jf.code" | grep -qE '^ *agent (any|\{|none)'; then
  ko "le stage d'apply déclare un \`agent\` — un exécuteur serait tenu pendant TOUT l'apply aval (le lab en a deux)"
else
  ok "le stage d'apply n'a PAS d'agent : ni la pause ni l'apply aval ne tiennent un exécuteur"
fi
I_BUILD=$(indent_of "$TMP/jf.code" "$L_BUILD"); I_WE=$(indent_of "$TMP/jf.code" "${L_WE1:-1}")
[ -n "$L_BUILD" ] && [ "$I_BUILD" = "$I_WE" ] \
  && ok "\`def b = build(\` est au même niveau que les blocs withEnv/node (indentation $I_BUILD) : HORS de tout node, comme le Groovy d'origine" \
  || ko "\`def b = build(\` semble imbriqué dans un node (indentation $I_BUILD vs $I_WE)"
jf "string(name: 'MERGE_SHA', value: env.MERGE_SHA)" \
  && ok "MERGE_SHA passé en paramètre de l'aval" || ko "MERGE_SHA n'est pas passé à l'aval — l'aval appliquerait HEAD"
jf "string(name: 'MANIFEST', value: env.MANIFEST)" && ok "MANIFEST passé (celui dérivé par la réconciliation)" || ko "MANIFEST non passé"
jf "string(name: 'ENVIRONMENT', value: env.ENV_NAME)" && ok "ENVIRONMENT passé (ENV_NAME réconcilié)" || ko "ENVIRONMENT non passé"
jf "string(name: 'ADMIN_VIA', value: env.APPLY_ADMIN_VIA)" && ok "ADMIN_VIA passé depuis APPLY_ADMIN_VIA (point de config, plus une constante)" || ko "ADMIN_VIA non passé depuis APPLY_ADMIN_VIA"
jf "string(name: 'VAULT_USER', value: vUser)" && ok "VAULT_USER = le login saisi à la pause (vUser)" || ko "VAULT_USER non passé"
jf "[\$class: 'PasswordParameterValue', name: 'VAULT_USER_PASSWORD', value: creds.V_PASS]" \
  && ok "mot de passe passé en PasswordParameterValue avec le Secret rendu par input() (String nue = ClassCastException #75, Secret.fromString = sandbox #78)" || ko "VAULT_USER_PASSWORD non passé depuis creds.V_PASS (le Secret d'input())"
jf "propagate: false" && ok "propagate: false — le verdict est rendu par l'amont après confrontation" || ko "propagate absent/true : l'amont ne confronterait rien"
grep -q 'absoluteUrl' "$TMP/jf.code" && ko "b.absoluteUrl utilisé — lève IllegalStateException sans URL racine Jenkins (mesuré #81, APRÈS l'apply)" || ok "aucun b.absoluteUrl (sans URL racine Jenkins il lève après l'apply — mesuré #81) : repli JENKINS_URL/textuel"
jf "env.APPLIED_SHA = vars.APPLIED_SHA" && ok "APPLIED_SHA relu dans buildVariables de l'aval" || ko "APPLIED_SHA non relu"
jf "env.APPLIED_MODE = vars.APPLIED_MODE" && ok "APPLIED_MODE relu dans buildVariables de l'aval" || ko "APPLIED_MODE non relu"
jf "env.APPLIED_DIGEST = vars.APPLIED_DIGEST" && ok "APPLIED_DIGEST relu dans buildVariables de l'aval" || ko "APPLIED_DIGEST non relu"
jf "!(env.APPLIED_MODE == 'pinned' && env.APPLIED_SHA == env.MERGE_SHA)" \
  && ok "confrontation : mode \`pinned\` ET SHA égal (un HEAD == MERGE_SHA « par coïncidence » sans paramètre ne passe pas)" \
  || ko "confrontation incomplète (mode pinned et/ou égalité des SHA absents)"
jf "env.REFUSAL = 'SHA_NON_CONFIRME'" && ok "refus nommé SHA_NON_CONFIRME" || ko "SHA_NON_CONFIRME absent"
jf "env.APPLY_RESULT = 'FAILURE'" && ok "un aval vert non confirmé devient FAILURE" || ko "un aval vert non confirmé resterait vert"
L_CMT=$(code_line "$TMP/jf.code" 'bash scripts/provision-apply-comment.sh')
CMT_LINE=$(sed -n "${L_CMT:-0}p" "$TMP/jf.code")
[ -n "$L_CMT" ] && ok "provision-apply-comment.sh appelé (ligne $L_CMT)" || ko "rapport de PR non câblé"
printf '%s' "$CMT_LINE" | grep -q '|| true' && ok "|| true : une forge en panne ne rougit pas un apply vert" || ko "le rapport peut faire échouer un apply réussi"
printf '%s' "$CMT_LINE" | grep -q 'VALIDATOR="${V_USER:-}"' && ok "VALIDATOR lu par le shell depuis V_USER (pas d'interpolation Groovy)" || ko "VALIDATOR non alimenté depuis V_USER par le shell"
printf '%s' "$CMT_LINE" | grep -q 'EXPECTED_SHA="${MERGE_SHA:-}"' && ok "EXPECTED_SHA = MERGE_SHA transmis au rapport (la référence DEMANDÉE est écrite à côté de celle projetée)" || ko "EXPECTED_SHA non transmis"
L_WE2=$(awk "NR>${L_BUILD:-0} && NR<${L_CMT:-0} && /withEnv\(\[\"V_USER=/ {n=NR} END {print n}" "$TMP/jf.code")
L_NODE2=$(awk "NR>${L_BUILD:-0} && NR<${L_CMT:-0} && /node\(\"\\\$\{env.POST_AGENT_LABEL/ {n=NR} END {print n}" "$TMP/jf.code")
[ -n "$L_WE2" ] && [ -n "$L_NODE2" ] && ok "le rapport tourne sous withEnv([\"V_USER=…\"]) (ligne $L_WE2) et un node( (ligne $L_NODE2)" || ko "le rapport ne tourne pas sous withEnv(V_USER) + node("
L_ERR=$(code_line "$TMP/jf.code" 'error("Apply nominatif en échec')
if [ -n "$L_CMT" ] && [ -n "$L_ERR" ] && [ "$L_CMT" -lt "$L_ERR" ]; then
  ok "le rapport (ligne $L_CMT) précède le verdict error() (ligne $L_ERR) : commenté PUIS rouge"
else
  ko "verdict avant le rapport, ou verdict absent : cmt=$L_CMT err=$L_ERR"
fi
jf "if (env.APPLY_RESULT != 'SUCCESS') {" && ok "l'échec réel est réaffirmé (error) hors du rapport" || ko "un apply en échec finirait vert"
[ -n "$L_BUILD" ] && [ -n "$L_CMT" ] && [ "$L_BUILD" -lt "$L_CMT" ] && ok "apply (ligne $L_BUILD) puis rapport (ligne $L_CMT)" || ko "rapport avant l'apply"

echo
echo "== 6. pas d'injection : aucun bloc sh en triple quotes DOUBLES, valeurs externes lues par le shell =="
grep -q 'sh """' "$TMP/jf.code" && ko "un bloc \`sh \"\"\"\` existe — Groovy y interpolerait des champs du webhook" || ok "aucun bloc \`sh \"\"\"\`"
grep -q "sh '''" "$TMP/jf.code" && ok "le bloc de statut (post) est en triple quotes SIMPLES" || ko "aucun bloc sh ''' — vérifier le post"
grep -E "^\s*sh " "$TMP/jf.code" | grep -q '\${env\.' && ko "une commande sh interpole \${env.…} en Groovy" || ok "aucune commande sh n'interpole \${env.…}"
grep -qE '^\s*(curl|ansible-playbook) ' "$TMP/jf.code" && ko "le Jenkinsfile appelle curl/ansible-playbook directement" || ok "aucun curl/ansible-playbook direct : le pipeline route"

echo
echo "== 7. points de config : présence ET valeur littérale, environment avant stages =="
grep -qE '^  environment \{' "$TMP/jf.code" && ok "bloc \`environment\` de niveau pipeline" || ko "aucun bloc environment"
jf 'GIT_HOST = "${env.GIT_HOST ?: '"'"'http://gitea:3000'"'"'}"' && ok "GIT_HOST = http://gitea:3000" || ko "GIT_HOST inattendu"
jf 'GIT_REPO = "${env.GIT_REPO ?: '"'"'ci/stoa-labs'"'"'}"' && ok "GIT_REPO = ci/stoa-labs" || ko "GIT_REPO inattendu"
jf 'GIT_WEB_HOST = "${env.GIT_WEB_HOST ?: '"'"'http://localhost:13000'"'"'}"' && ok "GIT_WEB_HOST = http://localhost:13000 (lien cliquable du commentaire)" || ko "GIT_WEB_HOST inattendu"
jf 'GITEA_CREDENTIALS_ID = "${env.GITEA_CREDENTIALS_ID ?: '"'"'gitea-provision-token'"'"'}"' && ok "GITEA_CREDENTIALS_ID = gitea-provision-token" || ko "GITEA_CREDENTIALS_ID inattendu"
jf 'APPLY_JOB = "${env.APPLY_JOB ?: '"'"'selfservice-app-deploy'"'"'}"' && ok "APPLY_JOB = selfservice-app-deploy" || ko "APPLY_JOB inattendu"
jf 'APPLY_ADMIN_VIA = "${env.APPLY_ADMIN_VIA ?: '"'"'proxy-oauth2'"'"'}"' \
  && ok "APPLY_ADMIN_VIA = proxy-oauth2 par défaut (le modèle client, celui que le Groovy codait en dur ; lab = direct par variable globale)" \
  || ko "APPLY_ADMIN_VIA : défaut inattendu — le modèle client doit rester le défaut"
L_ENV=$(grep -n '^  environment {' "$TMP/jf.code" | head -1 | cut -d: -f1)
L_STAGES=$(grep -n '^  stages {' "$TMP/jf.code" | head -1 | cut -d: -f1)
[ -n "$L_ENV" ] && [ -n "$L_STAGES" ] && [ "$L_ENV" -lt "$L_STAGES" ] && ok "environment (ligne $L_ENV) précède stages (ligne $L_STAGES)" || ko "ordre environment/stages non confirmé"

echo
echo "== 8. post{always} : statut build sur la PR, marqueur DISTINCT, gaté par la FORGE (GITEA_HEAD_REF) =="
L_POST=$(grep -n '^  post {' "$TMP/jf.code" | head -1 | cut -d: -f1)
[ -n "$L_POST" ] && ok "bloc post de niveau pipeline (ligne $L_POST)" || ko "aucun bloc post de niveau pipeline"
awk "NR>${L_POST:-0}" "$TMP/jf.code" > "$TMP/post.code"
grep -q 'always {' "$TMP/post.code" && ok "post { always }" || ko "post sans always"
grep -q 'node("${env.POST_AGENT_LABEL ?: '"'"''"'"'}")' "$TMP/post.code" && ok "node explicite dans le post (agent none au niveau pipeline)" || ko "pas de node dans le post"
grep -q 'checkout scm' "$TMP/post.code" && ok "checkout scm dans le post (le workspace n'est pas hérité)" || ko "pas de checkout scm dans le post"
grep -q 'COMMENT_MARKER="<!-- provision-apply-build -->"' "$TMP/post.code" && ok "marqueur distinct provision-apply-build (ne remplace ni le rapport ni le refus)" || ko "marqueur du post absent ou identique"
grep -q 'bash scripts/lib/gitea-pr-comment.sh' "$TMP/post.code" && ok "gitea-pr-comment.sh (upsert idempotent) utilisé dans le post" || ko "le post ne passe pas par gitea-pr-comment.sh"
grep -q 'case "${GITEA_HEAD_REF:-}" in' "$TMP/post.code" && ok "le post ne parle que si la FORGE a confirmé une PR provision/* (GITEA_HEAD_REF)" || ko "le post n'est pas gaté par GITEA_HEAD_REF"
grep -q 'case "${PR_BRANCH:-}" in' "$TMP/post.code" && ko "le post se fie encore au PR_BRANCH du payload" || ok "le post ne se fie pas au PR_BRANCH du payload (forgeable)"
grep -q 'BUILD_RESULT=${currentBuild.currentResult}' "$TMP/post.code" && ok "BUILD_RESULT exporté via withEnv depuis currentBuild.currentResult" || ko "BUILD_RESULT non exporté"

echo
echo "== 9. l'AVAL (Jenkinsfile.selfservice) : MERGE_SHA_REQUIS, ancrage, lignée, checkout AVANT le plan, annonce APRÈS verify =="
jfd "string(name: 'MERGE_SHA', defaultValue: ''," && ok "paramètre MERGE_SHA déclaré dans l'aval (défaut vide = HEAD)" || ko "paramètre MERGE_SHA absent de l'aval"
L_REQ=$(code_line "$TMP/jfd.code" 'MERGE_SHA_REQUIS')
jfd "!currentBuild.upstreamBuilds.isEmpty() && !((params.MERGE_SHA ?: '').trim())" \
  && ok "garde MERGE_SHA_REQUIS : appelé par un amont (upstreamBuilds, attrape BuildUpstreamCause) SANS MERGE_SHA ⇒ error" \
  || ko "garde MERGE_SHA_REQUIS absente ou fondée sur getBuildCauses('…UpstreamCause') (nom exact : ne verrait pas BuildUpstreamCause)"
L_FETCH=$(code_line "$TMP/jfd.code" 'git fetch -q origin main')
L_ANC=$(code_line "$TMP/jfd.code" 'git merge-base --is-ancestor "$REF" origin/main')
L_FP=$(code_line "$TMP/jfd.code" 'git rev-list --first-parent origin/main | grep -qx "$REF"')
L_CO=$(code_line "$TMP/jfd.code" 'git checkout -q "$REF"')
L_RP=$(code_line "$TMP/jfd.code" 'REF="$(git rev-parse HEAD)"')
L_PLAN=$(code_line "$TMP/jfd.code" "stage('Plan")
L_APPLY=$(code_line "$TMP/jfd.code" "stage('Apply")
L_VERIFY=$(code_line "$TMP/jfd.code" 'ansible/selfservice-app-verify.yml')
L_CP=$(code_line "$TMP/jfd.code" 'cp .a2-reference-sha .a2-applied-sha')
[ -n "$L_REQ" ] && [ -n "$L_PLAN" ] && [ "$L_REQ" -lt "$L_PLAN" ] && ok "MERGE_SHA_REQUIS (ligne $L_REQ) avant le stage Plan (ligne $L_PLAN)" || ko "MERGE_SHA_REQUIS absent ou après le plan"
[ -n "$L_FETCH" ] && ok "git fetch origin main (ligne $L_FETCH)" || ko "aucun fetch de main"
[ -n "$L_ANC" ] && ok "garde d'atteignabilité merge-base --is-ancestor (ligne $L_ANC)" || ko "aucun merge-base --is-ancestor — un SHA hors main serait appliqué"
[ -n "$L_FP" ] && ok "garde de LIGNÉE first-parent (ligne $L_FP) : un commit intérieur à une branche de PR est refusé" || ko "aucune garde first-parent"
[ -n "$L_CO" ] && ok "git checkout du SHA (ligne $L_CO)" || ko "aucun checkout du SHA"
[ -n "$L_ANC" ] && [ -n "$L_FP" ] && [ -n "$L_CO" ] && [ "$L_ANC" -lt "$L_FP" ] && [ "$L_FP" -lt "$L_CO" ] && ok "ancrage, puis lignée, puis checkout" || ko "ordre ancrage/lignée/checkout non respecté"
[ -n "$L_RP" ] && [ -n "$L_CO" ] && [ "$L_CO" -lt "$L_RP" ] && ok "REF = git rev-parse HEAD (ligne $L_RP) APRÈS le checkout : l'annonce est l'arbre en place, pas l'écho du paramètre" || ko "APPLIED_SHA n'est pas dérivé de rev-parse HEAD après le checkout"
[ -n "$L_CO" ] && [ -n "$L_PLAN" ] && [ "$L_CO" -lt "$L_PLAN" ] && ok "checkout (ligne $L_CO) AVANT le stage Plan (ligne $L_PLAN) : le plan lit l'arbre mergé" || ko "le checkout n'est pas avant le plan"
[ -n "$L_CO" ] && [ -n "$L_APPLY" ] && [ "$L_CO" -lt "$L_APPLY" ] && ok "checkout AVANT le stage Apply" || ko "checkout après l'apply"
jfd "REFUS: MERGE_SHA_NON_ANCETRE" && ok "refus nommé MERGE_SHA_NON_ANCETRE" || ko "MERGE_SHA_NON_ANCETRE absent"
jfd "REFUS: MERGE_SHA_HORS_LIGNEE" && ok "refus nommé MERGE_SHA_HORS_LIGNEE" || ko "MERGE_SHA_HORS_LIGNEE absent"
jfd "REFUS: MERGE_SHA_INVALIDE" && ok "refus nommé MERGE_SHA_INVALIDE (forme)" || ko "MERGE_SHA_INVALIDE absent"
jfd "app_manifest_digest_env" && ok "digest du palier calculé par la lib (app_manifest_digest_env)" || ko "digest non calculé"
jfd "MODE=pinned" && ok "mode \`pinned\` posé seulement quand MERGE_SHA a été checkouté" || ko "APPLIED_MODE=pinned absent"
[ -n "$L_CP" ] && [ -n "$L_VERIFY" ] && [ "$L_VERIFY" -lt "$L_CP" ] \
  && ok "les fichiers .a2-applied-* sont écrits (ligne $L_CP) APRÈS le verify (ligne $L_VERIFY) : un plan-only ou un échec n'annonce rien" \
  || ko "l'annonce APPLIED_* n'est pas après le verify (cp=$L_CP verify=$L_VERIFY)"
jfd "if (fileExists('.a2-applied-sha')) {" && jfd "env.APPLIED_SHA = readFile('.a2-applied-sha').trim()" && jfd "env.APPLIED_MODE = readFile('.a2-applied-mode').trim()" \
  && ok "APPLIED_SHA/APPLIED_MODE/APPLIED_DIGEST chargés dans env. seulement si le fichier existe" || ko "chargement des APPLIED_* absent ou inconditionnel"
jfd "rm -f .a2-applied-sha .a2-applied-digest .a2-applied-mode" && ok "les APPLIED_* d'un build précédent sont purgés au stage Référence (pas de fichier périmé)" || ko "pas de purge des fichiers .a2-applied-* périmés"
grep -n 'MERGE_SHA' "$TMP/jfd.code" | grep -q 'sh "' && ko "MERGE_SHA interpolé par Groovy dans une chaîne sh de l'aval" || ok "MERGE_SHA lu par le shell dans l'aval (jamais interpolé par Groovy)"
grep -q 'MERGE_SHA' "$REPO/scripts/setup-selfservice-job.sh" \
  && ok "setup-selfservice-job.sh déclare MERGE_SHA (une pose fraîche du job le porte dès le premier build)" \
  || ko "setup-selfservice-job.sh ne déclare pas MERGE_SHA — un build job: amont le retirerait en silence"

echo
echo "== 10. les scripts appelés existent, sont parsables, et le rapport porte les DEUX marqueurs =="
for s in scripts/provision-apply-reconcile.sh scripts/provision-apply-comment.sh scripts/lib/gitea-pr-comment.sh scripts/lib/app-manifest.sh; do
  [ -f "$REPO/$s" ] && bash -n "$REPO/$s" 2>/dev/null && ok "$s présent et parsable" || ko "$s absent ou non parsable"
done
[ -f "$REPO/scripts/lib/assert-merge-identity.sh" ] && sh -n "$REPO/scripts/lib/assert-merge-identity.sh" 2>/dev/null \
  && ok "scripts/lib/assert-merge-identity.sh présent et parsable" || ko "assert-merge-identity.sh absent ou non parsable"
grep -q "MARKER='<!-- provision-apply-refus -->'" "$CMT" && grep -q "MARKER='<!-- provision-apply -->'" "$CMT" \
  && ok "provision-apply-comment.sh choisit le marqueur selon APPLY_RESULT (refus ≠ résultat)" || ko "un seul marqueur dans le rapport — un refus forgé PATCHerait le résultat d'un apply réel"
grep -q 'provision-apply' "$REPO/scripts/setup-provision-jobs.sh" && ok "provision-apply posé par setup-provision-jobs.sh" || ko "provision-apply absent de setup-provision-jobs.sh"

echo
echo "== 11. total attendu =="
TOTAL=$((PASS+FAIL))
if [ "$TOTAL" -eq "$EXPECTED_CHECKS" ]; then
  ok "$TOTAL contrôles exécutés = $EXPECTED_CHECKS attendus (aucune section sautée)"
else
  ko "$TOTAL contrôles exécutés, $EXPECTED_CHECKS attendus — une section a été sautée ou ajoutée sans mettre EXPECTED_CHECKS à jour"
fi

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
