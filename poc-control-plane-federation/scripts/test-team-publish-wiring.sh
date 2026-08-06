#!/usr/bin/env bash
# test-team-publish-wiring.sh — preuve X/X du CÂBLAGE du job team-publish.
# Analyse statique : ni Jenkins, ni Gitea.
#
# ── CE QUI A CHANGÉ (conversion en Jenkinsfile déclaratif) ───────────────────
# Le pipeline ne vit PLUS en Groovy inline dans ci/jenkins/team-publish.job.xml
# (<script>…</script>) : il est dans ci/Jenkinsfile.team-publish, DÉCLARATIF, et
# le XML n'est plus qu'une coquille « Pipeline from SCM ». Ce test suit :
#   - $JF  (le Jenkinsfile)  porte désormais les gardes du PIPELINE ;
#   - $JOB (le XML)          ne porte plus que le déclencheur + le pointeur SCM,
#                            et doit prouver l'ABSENCE de tout Groovy inline.
# Les sections qui visent scripts/team-publish.sh et le rôle Ansible (§10, §11,
# §14 à §21, §23, §24) sont inchangées : ce moteur-là n'a pas bougé.
#
# Les constructions Groovy vérifiées avant (try/finally d'entrée, node{} de
# secours, if(publishResult!=SUCCESS)) ont un ÉQUIVALENT DÉCLARATIF vérifié à
# leur place, jamais un simple abandon de contrôle :
#   try d'entrée + finally  →  `post { always { … } }` de niveau PIPELINE
#                              (couvre STRICTEMENT plus : succès, échec, ET
#                              pause abandonnée/expirée, ET refus de garde) ;
#   input() hors de node{}  →  `agent none` + directive `input` de stage
#                              (évaluée AVANT l'allocation de l'agent) ;
#   if (!ref.startsWith)    →  `when { beforeInput true; expression … }`
#                              (la condition passe AVANT la pause : une PR hors
#                              api/* ne réveille personne) ;
#   if(publishResult!=…)    →  `case "$BUILD_RESULT"` à trois branches
#                              (SUCCESS / ABORTED / échec).
#
# FIX ROUND 1 (panel, §F) : durcissement anti « vert vacant ». Les greps NUS
# (motif présent n'importe où, y compris dans un COMMENTAIRE Groovy/bash qui
# nomme la chose sans jamais l'appeler) ont été remplacés par des ancres sur
# le CODE réel — soit une syntaxe d'invocation précise (`fail "TOKEN :`,
# `bash scripts/...`), soit une exclusion explicite des lignes de commentaire.
#
#   ./scripts/test-team-publish-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/team-publish.job.xml"
JF="$REPO/ci/Jenkinsfile.team-publish"
JOB_APPLY="$REPO/ci/jenkins/team-apply.job.xml"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# [Important, panel §F point 5] Total ATTENDU, ÉCRIT EN DUR — indépendant de
# PASS+FAIL (qui devient vrai par construction, quel que soit le nombre de
# contrôles réellement exécutés : une section entière sautée silencieusement
# ferait baisser le total affiché SANS jamais faire échouer ce script). Toute
# section ajoutée/retirée DOIT mettre à jour ce nombre à la main — un oubli
# fait virer le §26 au rouge, ce qui EST le comportement voulu (un rappel,
# pas un bug).
EXPECTED_CHECKS=114

[ -f "$JOB" ] || { echo "job introuvable : $JOB"; exit 2; }
[ -f "$JF" ]  || { echo "Jenkinsfile introuvable : $JF"; exit 2; }

# Lecture NORMALISÉE du Jenkinsfile : les espaces d'ALIGNEMENT (colonnes de
# `key:`/`=`) sont cosmétiques — un reformatage ne doit pas faire virer un
# contrôle au rouge, alors que la disparition d'une clé le doit.
JF_N="$(tr -s ' ' < "$JF")"
jf(){ printf '%s\n' "$JF_N" | grep -qF "$1"; }

echo "== 1. le XML reste bien formé, et le Jenkinsfile est bien un pipeline DÉCLARATIF =="
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "XML parsable" || ko "XML cassé"
grep -qE '^pipeline \{' "$JF" \
  && ok "le Jenkinsfile ouvre sur \`pipeline {\` (déclaratif, pas un script Groovy libre)" \
  || ko "le Jenkinsfile n'ouvre pas sur \`pipeline {\` — ce n'est pas un pipeline déclaratif"
grep -qE '^  stages \{' "$JF" \
  && ok "bloc \`stages\` de niveau pipeline présent" || ko "aucun bloc \`stages\` de niveau pipeline"

echo
echo "== 2. le webhook capte le DÉPÔT déclencheur, QUI a validé, QUI a demandé, et le SHA de merge =="
# Les deux fichiers portent le déclencheur ; c'est le XML qui GAGNE (§3). On
# vérifie ici le Jenkinsfile — le seul actif quand le job est posé sans XML —
# puis le XML en MIROIR juste après.
jf "[key: 'WEBHOOK_REPO', value: '\$.repository.full_name']" \
  && ok "WEBHOOK_REPO mappé sur repository.full_name (autorité par topologie)" \
  || ko "WEBHOOK_REPO absent ou mal mappé — team-publish.sh ne pourrait pas dériver l'équipe"
jf "[key: 'PR_MERGED_BY', value: '\$.pull_request.merged_by.login']" \
  && ok "merged_by.login capté" || ko "merged_by absent — la garde ne pourrait rien vérifier"
jf "[key: 'PR_REQUESTER', value: '\$.pull_request.user.login']" \
  && ok "user.login capté (quatre yeux)" || ko "requester absent"
jf "[key: 'MERGE_SHA', value: '\$.pull_request.merge_commit_sha']" \
  && ok "MERGE_SHA mappé sur merge_commit_sha" || ko "MERGE_SHA absent ou mal mappé — team-publish.sh l'exige (anti-TOCTOU)"
jf "[key: 'PR_BRANCH', value: '\$.pull_request.head.ref']" \
  && ok "PR_BRANCH capté" || ko "PR_BRANCH absent"
jf "[key: 'PR_NUMBER', value: '\$.pull_request.number']" \
  && ok "PR_NUMBER capté" || ko "PR_NUMBER absent"
# ANTI-ÉLARGISSEMENT : aucun bloc `parameters {}`. Exposer PR_MERGED_BY en
# paramètre de build permettrait à quiconque peut lancer le job de saisir
# lui-même l'identité du valideur et de passer sa propre garde d'identité.
grep -qE '^  parameters \{' "$JF" \
  && ko "un bloc \`parameters {}\` de niveau pipeline expose les clés du webhook en saisie libre — auto-validation possible" \
  || ok "aucun bloc \`parameters {}\` : les clés du webhook ne viennent QUE du webhook (un build manuel échoue sur \${VAR:?})"

echo
echo "== 3. le filtre GWT est exact (fusion, pas juste fermeture) — et le XML est le MIROIR du Jenkinsfile =="
jf "regexpFilterText: '\$PR_ACTION|\$PR_MERGED'" \
  && ok "filterText = \$PR_ACTION|\$PR_MERGED (Jenkinsfile)" || ko "filterText inattendu dans le Jenkinsfile"
jf "regexpFilterExpression: '^closed\\\\|true\$'" \
  && ok "filterExpression = ^closed\\|true\$ (Jenkinsfile)" \
  || ko "filterExpression inattendue dans le Jenkinsfile — laisserait passer une fermeture SANS merge"
jf "token: 'stoa-team-publish'" \
  && ok "token de déclenchement = stoa-team-publish (Jenkinsfile)" || ko "token de déclenchement absent/inattendu"
# Le XML doit porter le MÊME déclencheur, et c'est LUI qui fait foi :
# Declarative ne remplace que les déclencheurs qu'il a lui-même posés
# (DeclarativeJobPropertyTrackerAction) — celui d'un config.xml est préservé
# indéfiniment (mesuré sur le lab 2026-08-06 : 4 builds, token du XML jamais
# écrasé ; le même XML privé de ses <triggers> a bien laissé le Jenkinsfile
# poser le sien). Une divergence serait donc SILENCIEUSE : c'est ce que les
# quatre contrôles suivants interdisent.
grep -q '<regexpFilterText>\$PR_ACTION|\$PR_MERGED</regexpFilterText>' "$JOB" \
  && ok "filterText identique dans le XML (déclencheur vivant dès la pose du job)" || ko "filterText du XML divergent"
grep -q '<regexpFilterExpression>\^closed\\|true\$</regexpFilterExpression>' "$JOB" \
  && ok "filterExpression identique dans le XML" || ko "filterExpression du XML divergente"
grep -q '<token>stoa-team-publish</token>' "$JOB" \
  && ok "token identique dans le XML" || ko "token du XML divergent"
MIRROR_KO=""
for K in WEBHOOK_REPO PR_BRANCH PR_NUMBER PR_ACTION PR_MERGED PR_MERGED_BY PR_REQUESTER MERGE_SHA; do
  grep -q "<key>${K}</key>" "$JOB" || MIRROR_KO="${MIRROR_KO} ${K}"
done
[ -z "$MIRROR_KO" ] \
  && ok "les 8 genericVariables du Jenkinsfile sont présentes à l'identique dans le XML" \
  || ko "clés absentes du XML :${MIRROR_KO} — le webhook serait borgne jusqu'au premier build"

echo
echo "== 4. la branche est gardée à api/*, AVANT la pause (personne n'est réveillé pour rien) =="
jf "expression { (env.PR_BRANCH ?: '').startsWith('api/') }" \
  && ok "garde de branche api/* présente (condition \`when\`)" \
  || ko "garde de branche absente — appliquerait sur n'importe quelle PR fermée d'un dépôt d'équipe"
jf "beforeInput true" \
  && ok "\`beforeInput true\` : la condition est évaluée AVANT la demande en attente — une PR hors api/* ne réveille personne" \
  || ko "\`beforeInput true\` absent — une PR hors api/* ouvrirait quand même une demande en attente (la directive \`input\` passe AVANT \`when\` par défaut)"

echo
echo "== 5. la garde d'identité est réellement appelée, AVANT team-publish.sh =="
grep -q 'assert-merge-identity.sh' "$JF" \
  && ok "assert-merge-identity.sh invoquée" || ko "garde non appelée"
for a in --merged-by --requester --vault-user; do
  grep -q -- "$a" "$JF" && ok "argument $a passé" || ko "argument $a manquant"
done
L_GUARD=$(grep -n 'assert-merge-identity.sh' "$JF" | head -1 | cut -d: -f1)
L_APPLY=$(grep -n 'bash scripts/team-publish\.sh' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_GUARD" ] && [ -n "$L_APPLY" ] && [ "$L_GUARD" -lt "$L_APPLY" ]; then
  ok "garde ligne $L_GUARD, apply ligne $L_APPLY"
else
  ko "garde APRÈS l'apply (ou introuvable) : garde=$L_GUARD apply=$L_APPLY"
fi

echo
echo "== 6. team-publish.sh est bien invoqué =="
grep -q 'bash scripts/team-publish\.sh' "$JF" \
  && ok "scripts/team-publish.sh invoqué" || ko "team-publish.sh non invoqué — job mort"
# Le pipeline reste MINCE : il ROUTE, il ne réimplémente pas. Aucun appel
# direct à l'API de la gateway ni à Ansible ne doit apparaître ici.
if grep -qE '^\s*(curl|ansible-playbook) ' "$JF"; then
  ko "le Jenkinsfile appelle directement curl/ansible-playbook — la substance doit rester dans scripts/ et ansible/roles/"
else
  ok "aucun curl/ansible-playbook direct : le pipeline route, le moteur reste dans scripts/ et ansible/roles/"
fi

echo
echo "== 7. pas d'injection : les valeurs sont lues par le SHELL, jamais interpolées par Groovy =="
# En déclaratif, les variables du webhook sont DÉJÀ dans l'environnement du
# step (contribuées par GenericTrigger) et celles de la pause y sont posées par
# la directive `input` — d'où la disparition des withEnv() explicites. Ce qui
# doit être prouvé n'a pas changé : AUCUNE valeur d'origine externe ne doit
# traverser une interpolation Groovy pour atterrir dans une chaîne shell.
grep -q "sh '''" "$JF" \
  && ok "le bloc login+apply est en triple quotes SIMPLES (Groovy n'y interpole rien)" \
  || ko "aucun bloc \`sh '''\` — vérifier comment le bloc d'apply est écrit"
if grep -q 'sh """' "$JF"; then
  ko "un bloc \`sh \"\"\"\` (triple quotes DOUBLES) existe — Groovy y interpolerait le mot de passe et les champs du webhook"
else
  ok "aucun bloc \`sh \"\"\"\` : impossible d'interpoler un secret dans une chaîne shell"
fi
grep 'assert-merge-identity.sh' "$JF" | grep -q "^ *sh '" \
  && ok "chaîne sh de la garde en quotes simples" || ko "chaîne sh de la garde en quotes doubles (Groovy interpolerait)"
grep -q "password(name: 'V_PASS'" "$JF" \
  && ok "le mot de passe de la pause est un paramètre \`password\` (masqué), pas un \`string\`" \
  || ko "V_PASS n'est pas déclaré en paramètre \`password\` — il s'afficherait en clair dans l'UI et les logs"
grep -q "string(name: 'V_USER'" "$JF" \
  && ok "le login de la pause est un paramètre \`string\` nommé V_USER" || ko "V_USER non déclaré en paramètre de la pause"
# Le nom V_PASS (et non VAULT_USER_PASSWORD) est CE QUI PERMET le §18 : la
# valeur est recopiée puis `unset` dans le seul sh qui en a besoin.
if grep -q "password(name: 'VAULT_USER_PASSWORD'" "$JF"; then
  ko "la pause expose directement VAULT_USER_PASSWORD — la variable resterait dans l'environnement de TOUTE l'étape, l'unset du §18 deviendrait inopérant"
else
  ok "la pause n'expose pas VAULT_USER_PASSWORD directement (nom intermédiaire V_PASS, cf. §18)"
fi

echo
echo "== 8. le mot de passe ne transite jamais par argv (login sourcé, pas exec direct) =="
grep -q '\. ci/lib/vault-login\.sh' "$JF" \
  && ok "ci/lib/vault-login.sh sourcé (motif établi, jamais un appel direct qui mettrait le mot de passe en argv)" \
  || ko "vault-login.sh non sourcé — vérifier comment le login est fait"
grep -q 'trap vault_trap_revoke EXIT' "$JF" \
  && ok "révocation du token armée (trap EXIT) avant tout appel réseau" \
  || ko "aucun trap de révocation — le token nominatif pourrait survivre au build"

echo
echo "== 9. login et l'appel à team-publish.sh se suivent TEXTUELLEMENT (login précède l'appel) =="
# Les motifs sont ANCRÉS sur la syntaxe RÉELLE d'invocation
# (`. ci/lib/vault-login.sh`, `bash scripts/team-publish.sh`), pas une mention
# en prose, pour ne pas matcher un simple commentaire qui NOMME l'un ou l'autre
# sans jamais les appeler.
if awk '/\. ci\/lib\/vault-login\.sh/{f=1} f&&/bash scripts\/team-publish\.sh/{print "same"; exit}' "$JF" | grep -q same; then
  ok "vault-login.sh (source réelle) précède textuellement l'appel réel à team-publish.sh"
else
  ko "vault-login.sh et l'appel réel à team-publish.sh ne se suivent pas dans cet ordre — le trap de révocation pourrait tuer le token avant l'apply"
fi
# UN SEUL step `sh` pour le login ET l'apply : deux steps rouvriraient un
# process par step, et le trap du premier révoquerait le token AVANT que le
# second ne le consomme. Preuve : entre la source de la lib et l'appel au
# script, aucune fermeture de bloc `sh` (`'''`) ne doit s'intercaler.
BETWEEN=$(awk "NR>$(grep -n '\. ci/lib/vault-login\.sh' "$JF" | head -1 | cut -d: -f1) && NR<$(grep -n 'bash scripts/team-publish\.sh' "$JF" | head -1 | cut -d: -f1)" "$JF" | grep -c "'''")
[ "$BETWEEN" -eq 0 ] \
  && ok "aucune fermeture de bloc sh entre le login et l'apply — ils sont dans LE MÊME step \`sh\`" \
  || ko "un bloc \`sh\` se ferme entre le login et l'apply (${BETWEEN} occurrence(s) de ''') — le trap révoquerait le token avant sa consommation"

echo
echo "== 10. la garde et team-publish.sh appelés existent et sont exécutables =="
[ -f "$REPO/scripts/lib/assert-merge-identity.sh" ] \
  && ok "scripts/lib/assert-merge-identity.sh présent" || ko "script absent — appel mort"
sh -n "$REPO/scripts/lib/assert-merge-identity.sh" 2>/dev/null \
  && ok "assert-merge-identity.sh : syntaxe shell valide" || ko "assert-merge-identity.sh non parsable"
[ -f "$REPO/scripts/team-publish.sh" ] \
  && ok "scripts/team-publish.sh présent" || ko "team-publish.sh absent — appel mort"
bash -n "$REPO/scripts/team-publish.sh" 2>/dev/null \
  && ok "team-publish.sh : syntaxe shell valide" || ko "team-publish.sh non parsable"
[ -f "$REPO/ci/lib/vault-login.sh" ] \
  && ok "ci/lib/vault-login.sh présent" || ko "vault-login.sh absent — appel mort"
[ -f "$REPO/scripts/lib/gitea-pr-comment.sh" ] \
  && ok "scripts/lib/gitea-pr-comment.sh présent" || ko "gitea-pr-comment.sh absent — le commentaire idempotent est mort"
bash -n "$REPO/scripts/lib/gitea-pr-comment.sh" 2>/dev/null \
  && ok "gitea-pr-comment.sh : syntaxe shell valide" || ko "gitea-pr-comment.sh non parsable"

echo
echo "== 11. le job est bien posé par setup-team-onboard-jobs.sh =="
grep -q 'team-publish' "$REPO/scripts/setup-team-onboard-jobs.sh" \
  && ok "team-publish listé dans JOBS de setup-team-onboard-jobs.sh" || ko "team-publish absent de JOBS"

echo
echo "== 12. VAULT_USER_AUTH_MOUNT, APIM_API_BASE et JENKINS_UI posés dans \`environment\` — présence ET valeur =="
# Les exports shell du job d'origine sont devenus des entrées du bloc
# `environment {}` (déclaratif) : Jenkins les exporte au step `sh`, donc
# VAULT_USER_AUTH_MOUNT est dans l'environnement AVANT que vault-login.sh ne
# soit sourcé — c'est l'invariant qui comptait (leçon du palier 2, Task 8 :
# sans lui le login retombe sur le défaut `ldap` de la lib).
grep -qE '^  environment \{' "$JF" \
  && ok "bloc \`environment\` de niveau pipeline présent" || ko "aucun bloc \`environment\` de niveau pipeline"
jf 'VAULT_USER_AUTH_MOUNT = "${env.VAULT_USER_AUTH_MOUNT ?: '"'"'userpass'"'"'}"' \
  && ok "valeur littérale de VAULT_USER_AUTH_MOUNT = userpass (défaut nominatif du lab, surchargeable en ldap chez le client)" \
  || ko "VAULT_USER_AUTH_MOUNT : valeur par défaut inattendue ou absente"
jf 'APIM_API_BASE = "${env.APIM_API_BASE ?: '"'"'http://webmethods-mock:8080/rest/apigateway'"'"'}"' \
  && ok "valeur littérale de APIM_API_BASE = mock in-cluster (jamais 5555)" \
  || ko "APIM_API_BASE : valeur par défaut inattendue ou absente — team-publish.sh refuse de démarrer sans lui (\${APIM_API_BASE:?...})"
# JENKINS_UI : fix mesuré (Task 7) — "localhost" depuis le conteneur du job ne
# désigne PAS Jenkins ; sans lui, la re-pose d'app-request échoue
# systématiquement en job réel (curl "000"), jamais vu en test depuis un poste.
jf 'JENKINS_UI = "${env.JENKINS_UI ?: '"'"'http://jenkins:8080'"'"'}"' \
  && ok "valeur littérale de JENKINS_UI = http://jenkins:8080 (sinon : re-pose injoignable en job réel)" \
  || ko "JENKINS_UI : valeur par défaut inattendue ou absente"
jf 'VAULT_ADDR = "${env.VAULT_ADDR ?: '"'"'http://vault:8200'"'"'}"' \
  && ok "valeur littérale de VAULT_ADDR = http://vault:8200 (alias in-cluster)" \
  || ko "VAULT_ADDR : valeur par défaut inattendue ou absente"
jf 'GIT_HOST = "${env.GIT_HOST ?: '"'"'http://gitea:3000'"'"'}"' \
  && ok "valeur littérale de GIT_HOST = http://gitea:3000 (alias in-cluster)" \
  || ko "GIT_HOST : valeur par défaut inattendue ou absente"
# L'ordre compte : le bloc `environment` doit précéder les `stages` pour que
# les valeurs soient dans l'environnement de TOUS les steps, pause comprise.
L_ENV=$(grep -n '^  environment {' "$JF" | head -1 | cut -d: -f1)
L_STAGES=$(grep -n '^  stages {' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_ENV" ] && [ -n "$L_STAGES" ] && [ "$L_ENV" -lt "$L_STAGES" ]; then
  ok "\`environment\` (ligne $L_ENV) précède \`stages\` (ligne $L_STAGES) — exporté avant que vault-login.sh ne soit sourcé"
else
  ko "ordre environment/stages non confirmé (environment=$L_ENV stages=$L_STAGES)"
fi

echo
echo "== 13. le statut de build est commenté DANS TOUS LES CAS — et son marqueur est DISTINCT de celui du script =="
# Le `try d'entrée` + `finally` du job Groovy est devenu un `post { always }` de
# niveau PIPELINE. C'est ce NIVEAU qui fait la garde : un post de niveau STAGE
# ne couvrirait ni une pause abandonnée avant l'entrée dans l'étape, ni un
# refus de la condition `when`. La dette I3 du palier 2 (try n'entourant que
# l'apply, un refus de garde ne laissant AUCUNE trace sur la PR) reste fermée.
L_POST=$(grep -n '^  post {' "$JF" | head -1 | cut -d: -f1)
[ -n "$L_POST" ] \
  && ok "bloc \`post\` de niveau PIPELINE présent (ligne $L_POST) — couvre succès, échec, abandon ET refus de garde" \
  || ko "aucun \`post\` de niveau pipeline — un refus de garde ou une pause abandonnée resterait muet sur la PR (dette I3 reproduite)"
POST_CODE=$(awk '/^  post \{/{f=1} f{print}' "$JF" | grep -vE '^[[:space:]]*(//|#)')
printf '%s\n' "$POST_CODE" | grep -q 'always {' \
  && ok "\`always\` : le bloc tourne sur SUCCÈS COMME SUR ÉCHEC (un run vert derrière un run rouge remplace le ⚠ au lieu de le laisser à côté d'un ✅)" \
  || ko "le \`post\` n'est pas en \`always\` — un verdict contradictoire pourrait subsister sur la PR"
printf '%s\n' "$POST_CODE" | grep -q 'bash scripts/lib/gitea-pr-comment\.sh' \
  && ok "le post poste bien un commentaire sur la PR (appel RÉEL à gitea-pr-comment.sh, commentaires exclus)" \
  || ko "le post ne contient aucun appel RÉEL à gitea-pr-comment.sh (une mention en commentaire ne suffit pas)"
# Checkout PROPRE : `agent none` ⇒ le post n'a ni exécuteur ni workspace, et
# peut tourner sur un AUTRE exécuteur que l'étape d'apply. Rien n'est hérité.
printf '%s\n' "$POST_CODE" | grep -q 'checkout scm' \
  && ok "le post fait son propre \`checkout scm\` (aucune hypothèse de workspace hérité)" \
  || ko "le post ne checkoute pas — il supposerait un workspace hérité, faux avec \`agent none\`"
printf '%s\n' "$POST_CODE" | grep -qE 'node\(' \
  && ok "le post alloue explicitement un \`node\` (obligatoire sous \`agent none\`)" \
  || ko "le post n'alloue aucun \`node\` — ses steps échoueraient faute de workspace"
# Marqueur : comparaison LITTÉRALE, et DISTINCTION du marqueur du script
# (quand les deux commentaires partageaient le même marqueur, ce bloc écrasait,
# via PATCH, la cause nommée que team-publish.sh venait de poster).
SCRIPT_MARKER=$(grep -oE "TEAM_PUBLISH_MARKER='[^']*'" "$REPO/scripts/team-publish.sh" | sed -E "s/^TEAM_PUBLISH_MARKER='//; s/'\$//")
POST_MARKER=$(printf '%s\n' "$POST_CODE" | grep -oE 'COMMENT_MARKER="[^"]*"' | head -1 | sed -E 's/^COMMENT_MARKER="//; s/"$//')
EXPECTED_POST_MARKER='<!-- team-publish-build -->'
if [ "$POST_MARKER" = "$EXPECTED_POST_MARKER" ]; then
  ok "marqueur du post = littéralement ${EXPECTED_POST_MARKER}"
else
  ko "marqueur du post inattendu : '${POST_MARKER}' (attendu '${EXPECTED_POST_MARKER}')"
fi
if [ -n "$POST_MARKER" ] && [ "$POST_MARKER" != "$SCRIPT_MARKER" ]; then
  ok "marqueur du post (${POST_MARKER}) DISTINCT du marqueur du script (${SCRIPT_MARKER}) — plus d'écrasement croisé"
else
  ko "marqueur du post identique à celui du script ('${POST_MARKER}') — un échec IN-SCRIPT verrait sa cause nommée écrasée par le statut générique"
fi
# Le commentaire de statut doit cibler WEBHOOK_REPO (le dépôt de l'ÉQUIPE),
# jamais GIT_REPO (le dépôt plateforme, sans rapport avec CETTE PR).
printf '%s\n' "$POST_CODE" | grep -q 'GIT_REPO="\$WEBHOOK_REPO"' \
  && ok "le commentaire de statut cible WEBHOOK_REPO (le dépôt de l'équipe, pas la plateforme)" \
  || ko "le commentaire de statut ne cible pas WEBHOOK_REPO — risque de commenter le mauvais dépôt"
# Une PR hors api/* n'a RIEN déclenché (étape sautée) : la commenter serait un
# faux signal. Le job Groovy sortait par `return` avant le try ; ici l'étape est
# sautée mais le `post` tourne quand même — d'où cette garde explicite.
printf '%s\n' "$POST_CODE" | grep -q 'api/\*)' \
  && ok "le post se tait sur une PR hors api/* (étape SAUTÉE, rien publié — pas de faux signal)" \
  || ko "le post commenterait une PR hors api/* alors que l'étape a été sautée"

echo
echo "== 14. les gardes d'intégrité de team-publish.sh sont réellement câblées =="
# Statique (grep), pas fonctionnel — le comportement rouge/vert de chacune est
# prouvé par contre-épreuve à l'exécution (rapport de tâche), pas ici.
grep -q 'merge-base --is-ancestor' "$REPO/scripts/team-publish.sh" \
  && ok "garde d'atteignabilité merge-base --is-ancestor présente (MERGE_SHA doit être un ANCÊTRE de main, pas juste un objet existant)" \
  || ko "aucune garde d'atteignabilité — un SHA valide mais non fusionné sur main serait accepté"
grep -qF 'fail "REPO_AMBIGU :' "$REPO/scripts/team-publish.sh" \
  && ok "REPO_AMBIGU réellement appelé (fail nommé, pas juste mentionné en commentaire)" \
  || ko "REPO_AMBIGU absent de tout fail() réel — un dépôt déclaré deux fois choisirait la première équipe rencontrée en silence"
grep -qF 'fail "CONTRAT_ABSENT :' "$REPO/scripts/team-publish.sh" \
  && ok "CONTRAT_ABSENT réellement appelé (fail nommé, pas juste mentionné en commentaire)" \
  || ko "CONTRAT_ABSENT absent de tout fail() réel — un contrat manquant échouerait loin de sa cause réelle"
grep -qF 'fail "WEBHOOK_REPO_INVALIDE :' "$REPO/scripts/team-publish.sh" \
  && ok "WEBHOOK_REPO validé en forme AVANT tout argv git/curl" \
  || ko "WEBHOOK_REPO jamais validé en forme — une valeur de webhook mal formée atteindrait argv sans avoir été regardée"
grep -qF 'fail "MERGE_SHA_INVALIDE :' "$REPO/scripts/team-publish.sh" \
  && ok "MERGE_SHA validé en forme (40 hex) AVANT tout argv git" \
  || ko "MERGE_SHA jamais validé en forme"
grep -qF 'fail "PR_NUMBER_INVALIDE :' "$REPO/scripts/team-publish.sh" \
  && ok "PR_NUMBER validé en forme (entier positif) AVANT de servir de segment d'URL API Gitea" \
  || ko "PR_NUMBER jamais validé en forme — folded minor du panel non tenu"
grep -qF 'fail "API_NAME_INVALIDE :' "$REPO/scripts/team-publish.sh" \
  && ok "API_NAME (dérivé de la branche) validé en forme — devient un segment de CHEMIN (apis/<name>.publish.yml)" \
  || ko "API_NAME jamais validé en forme — évasion de chemin possible via une branche malformée"
L_CASE=$(grep -n '\*\[!a-z0-9-\]\*' "$REPO/scripts/team-publish.sh" | head -1 | cut -d: -f1)
L_GREPQ=$(grep -n "API_NAME_INVALIDE" "$REPO/scripts/team-publish.sh" | tail -1 | cut -d: -f1)
if [ -n "$L_CASE" ] && [ -n "$L_GREPQ" ] && [ "$L_CASE" -lt "$L_GREPQ" ]; then
  ok "le refus de classe (case, ligne $L_CASE) précède le refus de forme complète (ligne $L_GREPQ) pour API_NAME"
else
  ko "ordre case/grep pour API_NAME non confirmé (case=$L_CASE forme=$L_GREPQ)"
fi

echo
echo "== 15. la réconciliation Gitea est réellement câblée — le payload webhook n'est jamais la vérité seule =="
grep -qF 'fail "GITEA_RECONCILE_ECHEC :' "$REPO/scripts/team-publish.sh" \
  && ok "GITEA_RECONCILE_ECHEC présent (échec de lecture Gitea = refus, jamais un continue silencieux)" \
  || ko "GITEA_RECONCILE_ECHEC absent — un échec de lecture Gitea ne serait pas nommé"
grep -qF 'fail "PAYLOAD_PERIME :' "$REPO/scripts/team-publish.sh" \
  && ok "PAYLOAD_PERIME présent (divergence webhook/Gitea = refus)" \
  || ko "PAYLOAD_PERIME absent — un payload rejoué/périmé ne serait pas détecté"
grep -qF 'd.get("merged") is True' "$REPO/scripts/team-publish.sh" \
  && ok "merged relu chez Gitea (pas déduit du payload)" || ko "merged non revérifié chez Gitea"
grep -qF 'd.get("merge_commit_sha") == os.environ["MERGE_SHA"]' "$REPO/scripts/team-publish.sh" \
  && ok "merge_commit_sha comparé au MERGE_SHA du webhook" || ko "merge_commit_sha non comparé"
grep -qF '.get("ref") == os.environ["PR_BRANCH"]' "$REPO/scripts/team-publish.sh" \
  && ok "head.ref comparé à PR_BRANCH du webhook" || ko "head.ref non comparé"
grep -qF '.get("ref") == "main"' "$REPO/scripts/team-publish.sh" \
  && ok "base.ref comparé à main" || ko "base.ref non comparé"

echo
echo "== 16. contract (liste blanche EXACTE) + MANIFEST_UNSAFE (scan du reste) =="
grep -qF 'fail "MANIFEST_CONTRACT_INVALIDE :' "$REPO/scripts/team-publish.sh" \
  && ok "MANIFEST_CONTRACT_INVALIDE réellement appelé (fail nommé) — refuse tout contract qui diverge du gabarit, Jinja injecté OU chemin absolu" \
  || ko "MANIFEST_CONTRACT_INVALIDE absent de tout fail() réel"
grep -qF 'fail "MANIFEST_UNSAFE :' "$REPO/scripts/team-publish.sh" \
  && ok "MANIFEST_UNSAFE réellement appelé (fail nommé)" || ko "MANIFEST_UNSAFE absent de tout fail() réel"
grep -qF 'a.pop("contract", None)' "$REPO/scripts/team-publish.sh" \
  && ok "le scan MANIFEST_UNSAFE EXCLUT réellement le champ contract (sinon : le gabarit légitime échouerait toujours ici)" \
  || ko "aucune exclusion réelle de contract trouvée dans le scan — MANIFEST_UNSAFE pourrait refuser tout manifeste légitime"
grep -qF 'EXPECTED_CONTRACT="{{ (pub_manifest_path | dirname) }}/${API_NAME}.openapi.yaml"' "$REPO/scripts/team-publish.sh" \
  && ok "la liste blanche cible EXACTEMENT le gabarit paramétré par API_NAME" \
  || ko "EXPECTED_CONTRACT absent ou construit différemment — la liste blanche pourrait avoir dérivé du vrai gabarit"
TMPL="$REPO/gateways/templates/publish.yml.tmpl"
if [ -f "$TMPL" ]; then
  TMPL_CONTRACT_LINE=$(grep -E '^\s*contract:' "$TMPL" | head -1)
  case "$TMPL_CONTRACT_LINE" in
    *'{{ (pub_manifest_path | dirname) }}'*)
      ok "le préfixe Jinja de la liste blanche correspond au VRAI gabarit (gateways/templates/publish.yml.tmpl)" ;;
    *)
      ko "le gabarit réel ne porte plus '{{ (pub_manifest_path | dirname) }}' dans son champ contract — la liste blanche de team-publish.sh a dérivé (ligne lue : '${TMPL_CONTRACT_LINE}')" ;;
  esac
else
  ko "gateways/templates/publish.yml.tmpl introuvable — impossible de prouver l'absence de dérive"
fi
L_CONTRACT_CHECK=$(grep -n 'fail "MANIFEST_CONTRACT_INVALIDE :' "$REPO/scripts/team-publish.sh" | head -1 | cut -d: -f1)
L_SCAN=$(grep -n 'fail "MANIFEST_UNSAFE :' "$REPO/scripts/team-publish.sh" | head -1 | cut -d: -f1)
L_ANSIBLE=$(grep -n 'ansible-playbook -i' "$REPO/scripts/team-publish.sh" | head -1 | cut -d: -f1)
if [ -n "$L_CONTRACT_CHECK" ] && [ -n "$L_ANSIBLE" ] && [ "$L_CONTRACT_CHECK" -lt "$L_ANSIBLE" ]; then
  ok "la liste blanche contract a lieu AVANT l'invocation du rôle Ansible (ligne $L_CONTRACT_CHECK puis $L_ANSIBLE)"
else
  ko "ordre contract/apply non confirmé (contract=$L_CONTRACT_CHECK apply=$L_ANSIBLE) — le manifeste pourrait être appliqué avant d'être vérifié"
fi
if [ -n "$L_SCAN" ] && [ -n "$L_ANSIBLE" ] && [ "$L_SCAN" -lt "$L_ANSIBLE" ]; then
  ok "le scan MANIFEST_UNSAFE a lieu AVANT l'invocation du rôle Ansible (ligne $L_SCAN puis $L_ANSIBLE)"
else
  ko "ordre scan/apply non confirmé (scan=$L_SCAN apply=$L_ANSIBLE) — le manifeste pourrait être appliqué avant d'être scanné"
fi

echo
echo "== 17. apim_ss_contract_pin épingle le contract — câblé côté script ET côté rôle, dans le bon ordre =="
grep -qF -- '-e apim_ss_contract_pin="$SPEC_PATH"' "$REPO/scripts/team-publish.sh" \
  && ok "team-publish.sh passe apim_ss_contract_pin=SPEC_PATH (le chemin déjà VÉRIFIÉ, jamais celui du manifeste) en extra-var" \
  || ko "apim_ss_contract_pin non passé par team-publish.sh — le manifeste resterait maître du contract"
RESOLVE_ENV="$REPO/ansible/roles/apim_publish_api/tasks/resolve-env.yml"
[ -f "$RESOLVE_ENV" ] && grep -qF "apim_api | combine({'contract': apim_ss_contract_pin})" "$RESOLVE_ENV" \
  && ok "le rôle applique réellement le pin (set_fact combine sur contract, pas juste une variable déclarée dans defaults/main.yml sans jamais être lue)" \
  || ko "aucune application réelle du pin côté rôle — la variable pourrait n'être qu'un defaults mort"
L_PEREN=$(grep -n 'apim_api_base_m | combine(apim_api_over_m' "$RESOLVE_ENV" 2>/dev/null | head -1 | cut -d: -f1)
L_PIN=$(grep -n "apim_api | combine({'contract': apim_ss_contract_pin})" "$RESOLVE_ENV" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$L_PEREN" ] && [ -n "$L_PIN" ] && [ "$L_PEREN" -lt "$L_PIN" ]; then
  ok "le pin est posé APRÈS la fusion per_env (ligne ${L_PEREN} puis ${L_PIN}) — un contract caché sous per_env.<env>.contract ne peut pas contourner le pin"
else
  ko "ordre pin/per_env non confirmé (per_env=${L_PEREN} pin=${L_PIN}) — un contract sous per_env pourrait écraser le pin"
fi

echo
echo "== 18. V_PASS ne survit pas dans l'environnement du step sh, dans LES DEUX jobs =="
L_EXPORT_PUB=$(grep -n 'export VAULT_USER_PASSWORD="\${V_PASS:-}"' "$JF" | head -1 | cut -d: -f1)
L_UNSET_PUB=$(grep -n '^ *unset V_PASS$' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_EXPORT_PUB" ] && [ -n "$L_UNSET_PUB" ] && [ "$L_EXPORT_PUB" -lt "$L_UNSET_PUB" ]; then
  ok "Jenkinsfile.team-publish : unset V_PASS après l'export (ligne ${L_EXPORT_PUB} puis ${L_UNSET_PUB})"
else
  ko "Jenkinsfile.team-publish : unset V_PASS absent ou avant l'export (export=${L_EXPORT_PUB} unset=${L_UNSET_PUB}) — le mot de passe resterait lisible dans /proc/PID/environ"
fi
# L'unset doit précéder TOUT appel réseau (le login inclus) : après, le mot de
# passe aurait déjà été visible dans l'environnement d'un process fils.
L_SOURCE=$(grep -n '\. ci/lib/vault-login\.sh' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_UNSET_PUB" ] && [ -n "$L_SOURCE" ] && [ "$L_UNSET_PUB" -lt "$L_SOURCE" ]; then
  ok "unset V_PASS (ligne ${L_UNSET_PUB}) AVANT la source de vault-login.sh (ligne ${L_SOURCE}) — donc avant tout appel réseau"
else
  ko "unset V_PASS après le login (unset=${L_UNSET_PUB} source=${L_SOURCE})"
fi
if [ -f "$JOB_APPLY" ]; then
  L_EXPORT_APL=$(grep -n 'export VAULT_USER_PASSWORD="\$V_PASS"' "$JOB_APPLY" | head -1 | cut -d: -f1)
  L_UNSET_APL=$(grep -n '^ *unset V_PASS$' "$JOB_APPLY" | head -1 | cut -d: -f1)
  if [ -n "$L_EXPORT_APL" ] && [ -n "$L_UNSET_APL" ] && [ "$L_EXPORT_APL" -lt "$L_UNSET_APL" ]; then
    ok "team-apply.job.xml : unset V_PASS après l'export (ligne ${L_EXPORT_APL} puis ${L_UNSET_APL}) — même correction, miroir"
  else
    ko "team-apply.job.xml : unset V_PASS absent ou avant l'export (export=${L_EXPORT_APL} unset=${L_UNSET_APL})"
  fi
else
  ko "team-apply.job.xml introuvable — impossible de vérifier le miroir de la correction D"
fi

echo
echo "== 19. la re-pose après succès couvre app-request ET api-request =="
grep -qF 'JOBS="app-request api-request"' "$REPO/scripts/team-publish.sh" \
  && ok "JOBS=\"app-request api-request\" — la liste API_BASE d'api-request est aussi rafraîchie (sinon : stale après chaque publication)" \
  || ko "JOBS ne couvre pas api-request — sa liste API_BASE resterait périmée après chaque publication"

echo
echo "== 20. le secret HMAC est proposé à l'enregistrement du hook (limite documentée : non vérifiable côté GWT 2.4.2) =="
grep -qF "cfg['secret'] = secret" "$REPO/scripts/team-apply.sh" \
  && ok "le hook Gitea peut porter un secret HMAC (TEAM_PUBLISH_WEBHOOK_SECRET, si fourni) — Gitea signe alors ses envois" \
  || ko "aucun mécanisme de secret dans l'enregistrement du hook"

echo
echo "== 21. les DEUX clones (dépôt plateforme ET dépôt d'équipe) sont authentifiés, pas seulement les push =="
NONCOMMENT_GITCLONE=$(grep -vE '^\s*#' "$REPO/scripts/team-publish.sh" | grep -c 'git clone')
[ "$NONCOMMENT_GITCLONE" -eq 1 ] \
  && ok "un seul \`git clone\` brut dans le script, celui enveloppé par gclone() (aucun clone anonyme parallèle)" \
  || ko "nombre de \`git clone\` bruts inattendu (${NONCOMMENT_GITCLONE}, attendu 1 — celui interne à gclone())"
GCLONE_CALLS=$(grep -cE '^gclone ' "$REPO/scripts/team-publish.sh")
[ "$GCLONE_CALLS" -eq 2 ] \
  && ok "gclone (authentifiée) appelée exactement 2 fois — dépôt plateforme ET dépôt d'équipe" \
  || ko "gclone appelée ${GCLONE_CALLS} fois, attendu 2 — un clone pourrait être resté anonyme"

echo
echo "== 22. la pause ne réserve AUCUN exécuteur, et son abandon est couvert =="
# `agent none` au niveau pipeline + directive `input` de stage : la pause est
# évaluée AVANT l'allocation de l'agent de l'étape. Un `agent any` de niveau
# pipeline gâcherait un slot pendant toute l'attente d'une réponse humaine —
# c'est la raison pour laquelle l'input() du job Groovy était déjà HORS de
# tout node{}.
grep -qE '^  agent none$' "$JF" \
  && ok "\`agent none\` au niveau pipeline — la pause ne réserve aucun exécuteur" \
  || ko "pas d'\`agent none\` au niveau pipeline — un exécuteur serait réservé pendant toute l'attente humaine"
L_INPUT=$(grep -nE '^      input \{' "$JF" | head -1 | cut -d: -f1)
[ -n "$L_INPUT" ] \
  && ok "directive \`input\` de stage présente (ligne ${L_INPUT}) — évaluée avant l'agent de l'étape" \
  || ko "aucune directive \`input\` de stage — la pause nominative a disparu, ou est devenue un step (qui, lui, réserve un exécuteur)"
grep -qE '^      agent any$' "$JF" \
  && ok "l'étape d'apply déclare son propre \`agent any\` (alloué APRÈS la réponse)" \
  || ko "l'étape d'apply ne déclare aucun agent — sous \`agent none\` elle n'aurait pas de workspace"
if [ -n "$L_INPUT" ] && [ -n "$L_POST" ] && [ "$L_INPUT" -lt "$L_POST" ]; then
  ok "la pause (ligne ${L_INPUT}) est couverte par le \`post\` de niveau pipeline (ligne ${L_POST}) — un abandon/timeout EST commenté"
else
  ko "la pause n'est pas couverte par le post (input=${L_INPUT} post=${L_POST}) — un abandon resterait muet sur la PR"
fi

echo
echo "== 23. pas de second rempart côté rôle — retiré plutôt que rafistolé sous pression =="
# CE CONTRÔLE PROUVE L'ABSENCE, pas la présence — s'il devient rouge un jour
# parce que le fichier existe de nouveau, c'est un SIGNAL (une éventuelle
# réintroduction doit être une décision consciente, documentée, pas un oubli
# de merge), pas nécessairement une régression en soi.
[ ! -e "$REPO/ansible/roles/apim_publish_api/files/scan-manifest-jinja.sh" ] \
  && ok "scan-manifest-jinja.sh absent (revert tenu)" \
  || ko "scan-manifest-jinja.sh existe de nouveau — réintroduction du rempart contournable retiré au round 3 ?"
grep -qF 'scan-manifest-jinja.sh' "$REPO/ansible/roles/apim_publish_api/tasks/manifest-guard.yml" \
  && ko "manifest-guard.yml référence encore scan-manifest-jinja.sh alors que le fichier a été retiré" \
  || ok "manifest-guard.yml ne référence plus scan-manifest-jinja.sh"
grep -qF "team-publish.sh §4" "$RESOLVE_ENV" \
  && ok "resolve-env.yml documente team-publish.sh §4 comme la SEULE fermeture (pas de faux « en seconde couche »)" \
  || ko "resolve-env.yml ne documente plus la fermeture réelle — le commentaire pourrait avoir dérivé"

echo
echo "== 24. le pin ne revendique plus une défense RCE qu'il n'assure pas =="
grep -qF "GARANTIT L'INTÉGRITÉ du contract final" "$RESOLVE_ENV" \
  && ok "resolve-env.yml : commentaire corrigé (intégrité, pas défense RCE)" \
  || ko "resolve-env.yml : correction du commentaire du pin absente ou reformulée différemment"
grep -qF "CE N'EST PAS UNE DÉFENSE" "$RESOLVE_ENV" \
  && ok "resolve-env.yml : la non-défense RCE est dite explicitement" \
  || ko "resolve-env.yml : absence de la clarification explicite"
DEFAULTS_MAIN="$REPO/ansible/roles/apim_publish_api/defaults/main.yml"
grep -qF "INTÉGRITÉ, PAS une défense RCE" "$DEFAULTS_MAIN" \
  && ok "defaults/main.yml : commentaire corrigé (miroir de resolve-env.yml)" \
  || ko "defaults/main.yml : correction du commentaire absente"

echo
echo "== 25. le statut de build ne laisse plus un ⚠ contredire un ✅, et NOMME l'abandon =="
# Le job Groovy nestait son node{} dans `if (publishResult != 'SUCCESS')` : il
# ne tournait JAMAIS sur le chemin succès, laissant le ⚠ d'un run précédent à
# côté du ✅ du script. En déclaratif, `post { always }` tourne toujours, et le
# message est choisi par un `case` à TROIS branches (l'abandon de la pause,
# noyé dans « échec » auparavant, est désormais nommé).
printf '%s\n' "$POST_CODE" | grep -qF 'case "${BUILD_RESULT:-FAILURE}" in' \
  && ok "le bloc sh du post branche réellement sur BUILD_RESULT" \
  || ko "aucun branchement réel sur BUILD_RESULT dans le bloc sh"
# Alimenté par currentBuild.currentResult (succès/échec/ABANDON réels) et
# passé par l'ENVIRONNEMENT — jamais interpolé dans la chaîne shell, qui est
# en quotes simples (§7) et où un `${…}` Groovy ne serait de toute façon pas
# évalué : le passer autrement que par withEnv le rendrait simplement vide.
printf '%s\n' "$POST_CODE" | grep -qF 'withEnv(["BUILD_RESULT=${currentBuild.currentResult}"])' \
  && ok "BUILD_RESULT alimenté par currentBuild.currentResult et passé par withEnv (environnement), pas par interpolation dans le sh" \
  || ko "BUILD_RESULT non passé par withEnv depuis currentBuild.currentResult — le post ne pourrait pas distinguer succès/échec/abandon"
printf '%s\n' "$POST_CODE" | grep -qF 'team-publish (statut build) : build termine sans erreur' \
  && ok "message NEUTRE posé sur le chemin succès (efface un ⚠ précédent au lieu de le laisser trainer)" \
  || ko "aucun message de succès trouvé — un ⚠ antérieur resterait affiché à côté d'un ✅"
printf '%s\n' "$POST_CODE" | grep -qF 'team-publish (statut build) : le build a echoue avant ou pendant' \
  && ok "message d'échec toujours présent (branche par défaut conservée)" \
  || ko "message d'échec introuvable — régression du comportement d'origine"
printf '%s\n' "$POST_CODE" | grep -qF 'ABANDONNEE' \
  && ok "l'abandon/expiration de la pause a son propre message (RIEN publié, dit explicitement)" \
  || ko "aucun message dédié à l'abandon de la pause — il serait rapporté comme un échec de publication"

echo
echo "== 26. plus AUCUN Groovy inline dans le job : c'est un Pipeline from SCM =="
# LA demande client : des Jenkinsfile versionnés, pas un pipeline en dur dans
# un config.xml. Ce contrôle est la preuve que la conversion a bien eu lieu et
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
grep -qF '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.team-publish</scriptPath>' "$JOB" \
  && ok "scriptPath pointe sur ci/Jenkinsfile.team-publish" || ko "scriptPath absent ou divergent"
grep -qF '<lightweight>false</lightweight>' "$JOB" \
  && ok "lightweight=false : le workspace de l'agent porte tout le dépôt (scripts/, ansible/, ci/lib/), pas seulement le Jenkinsfile" \
  || ko "lightweight absent ou true — le workspace n'aurait que le Jenkinsfile, tous les appels scripts/ mourraient"
# Le Jenkinsfile lui-même doit rester déclaratif : ni try/catch, ni pipeline
# scripté déguisé. Le seul `node` toléré est celui du post (obligatoire sous
# `agent none`), compté explicitement.
if grep -qE '^\s*(try \{|\} catch)' "$JF"; then
  ko "le Jenkinsfile contient un try/catch — la gestion d'erreur doit passer par \`post\`"
else
  ok "aucun try/catch : la gestion d'erreur est déléguée à \`post\`"
fi
NODE_COUNT=$(grep -cE '^\s*node\(' "$JF")
[ "$NODE_COUNT" -eq 1 ] \
  && ok "un seul \`node(...)\` dans tout le fichier, celui du post (obligatoire sous \`agent none\`)" \
  || ko "nombre de \`node(...)\` inattendu (${NODE_COUNT}, attendu 1) — le pipeline redevient scripté"
SCRIPT_BLOCKS=$(grep -cE '^\s*script \{' "$JF")
[ "$SCRIPT_BLOCKS" -le 1 ] \
  && ok "au plus un bloc \`script {}\` (le nommage du build) — le reste est déclaratif" \
  || ko "${SCRIPT_BLOCKS} blocs \`script {}\` — le Groovy revient par la fenêtre"

echo
echo "== 27. le total de contrôles exécutés correspond au total ATTENDU, écrit en dur =="
# Le `RÉSULTAT : %d/%d` final ci-dessous imprime PASS/(PASS+FAIL) — une
# formule auto-référentielle qui devient vraie par construction. CE contrôle
# compare plutôt contre EXPECTED_CHECKS, une CONSTANTE écrite en tête de ce
# fichier, indépendante de ce qui vient de tourner.
ACTUAL_CHECKS=$((PASS+FAIL))
if [ "$ACTUAL_CHECKS" -eq "$EXPECTED_CHECKS" ]; then
  ok "nombre de contrôles exécutés = ${EXPECTED_CHECKS} (attendu, écrit en dur en tête de ce fichier)"
else
  ko "nombre de contrôles exécutés = ${ACTUAL_CHECKS}, attendu ${EXPECTED_CHECKS} (écrit en dur) — une section a peut-être été sautée silencieusement (branche jamais évaluée, boucle vide, etc.)"
fi

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
