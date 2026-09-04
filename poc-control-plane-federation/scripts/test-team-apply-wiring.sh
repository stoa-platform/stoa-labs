#!/usr/bin/env bash
# test-team-apply-wiring.sh — preuve X/X du CÂBLAGE du job team-apply.
# Analyse statique : ni Jenkins, ni Gitea.
#
# ── CE QUI A CHANGÉ (conversion en Jenkinsfile déclaratif) ───────────────────
# Le pipeline ne vit PLUS en Groovy inline dans ci/jenkins/team-apply.job.xml
# (<script>…</script>) : il est dans ci/Jenkinsfile.team-apply, DÉCLARATIF, et
# le XML n'est plus qu'une coquille « Pipeline from SCM ». Ce test suit :
#   - $JF  (le Jenkinsfile)  porte désormais les gardes du PIPELINE ;
#   - $JOB (le XML)          ne porte plus que le déclencheur + le pointeur SCM,
#                            et doit prouver l'ABSENCE de tout Groovy inline.
# Les sections qui visent scripts/team-apply.sh et la garde d'identité (§10,
# §11) sont inchangées : ce moteur-là n'a pas bougé d'une ligne.
#
# Les constructions Groovy vérifiées avant ont un ÉQUIVALENT DÉCLARATIF vérifié
# à leur place, jamais un simple abandon de contrôle :
#   if (!ref.startsWith('onboard/')) { return }
#                           →  `when { beforeInput true; expression … }`
#                              (la condition passe AVANT la pause : une PR hors
#                              onboard/* ne réveille personne) ;
#   input() hors de node{}  →  `agent none` + directive `input` de stage
#                              (évaluée AVANT l'allocation de l'agent : la pause
#                              ne réserve AUCUN exécuteur) ;
#   withEnv([G_MERGED_BY…]) →  variables DÉJÀ dans l'environnement (contribuées
#                              par GenericTrigger) + paramètres de la directive
#                              `input` ; ce qui comptait — aucune interpolation
#                              Groovy dans une chaîne shell — est vérifié §7 ;
#   export VAR=… dans le sh →  bloc `environment {}` de niveau pipeline, dont
#                              l'ordre (avant `stages`) est vérifié §12.
#
# Motif anti « vert vacant » repris de test-team-publish-wiring.sh (panel, §F) :
# pas de grep NU (un motif présent dans un COMMENTAIRE qui NOMME la chose sans
# jamais l'appeler suffirait à verdir). Les ancres portent sur le CODE réel —
# syntaxe d'invocation précise (`sh scripts/lib/assert-merge-identity.sh`,
# `bash scripts/team-apply.sh`) ou paire complète option/variable.
#
#   ./scripts/test-team-apply-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/team-apply.job.xml"
JF="$REPO/ci/Jenkinsfile.team-apply"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# [Important, panel §F point 5] Total ATTENDU, ÉCRIT EN DUR — indépendant de
# PASS+FAIL (qui devient vrai par construction, quel que soit le nombre de
# contrôles réellement exécutés : une section entière sautée silencieusement
# ferait baisser le total affiché SANS jamais faire échouer ce script). Toute
# section ajoutée/retirée DOIT mettre à jour ce nombre à la main — un oubli
# fait virer le §16 au rouge, ce qui EST le comportement voulu (un rappel,
# pas un bug).
# NB : ce total compte les contrôles exécutés AVANT le §16 lui-même (le sien
# n'est pas encore compté quand la comparaison a lieu) — le `RÉSULTAT` final
# affiche donc EXPECTED_CHECKS+1. Même convention que test-team-publish-wiring.sh.
EXPECTED_CHECKS=71

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
echo "== 2. le webhook capte QUI a validé, QUI a demandé, et le SHA de merge =="
# Les deux fichiers portent le déclencheur ; c'est le XML qui GAGNE (§3). On
# vérifie ici le Jenkinsfile — le seul actif quand le job est posé sans XML —
# puis le XML en MIROIR juste après.
jf "[key: 'PR_BRANCH', value: '\$.pull_request.head.ref']" \
  && ok "PR_BRANCH capté (c'est lui qui porte équipe et env)" || ko "PR_BRANCH absent ou mal mappé"
jf "[key: 'PR_NUMBER', value: '\$.pull_request.number']" \
  && ok "PR_NUMBER capté" || ko "PR_NUMBER absent ou mal mappé"
jf "[key: 'PR_ACTION', value: '\$.action']" \
  && ok "PR_ACTION capté (moitié gauche du filtre GWT)" || ko "PR_ACTION absent — le filtre ne pourrait rien comparer"
jf "[key: 'PR_MERGED', value: '\$.pull_request.merged']" \
  && ok "PR_MERGED capté (moitié droite du filtre GWT)" || ko "PR_MERGED absent — une fermeture SANS merge passerait"
jf "[key: 'PR_MERGED_BY', value: '\$.pull_request.merged_by.login']" \
  && ok "merged_by.login capté" || ko "merged_by absent — la garde ne pourrait rien vérifier"
jf "[key: 'PR_REQUESTER', value: '\$.pull_request.user.login']" \
  && ok "user.login capté (quatre yeux)" || ko "requester absent"
jf "[key: 'MERGE_SHA', value: '\$.pull_request.merge_commit_sha']" \
  && ok "MERGE_SHA mappé sur merge_commit_sha" || ko "MERGE_SHA absent ou mal mappé — team-apply.sh l'exige (anti-TOCTOU)"
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
jf "token: 'stoa-team-apply'" \
  && ok "token de déclenchement = stoa-team-apply (Jenkinsfile)" || ko "token de déclenchement absent/inattendu"
# Le XML doit porter le MÊME déclencheur, et c'est LUI qui fait foi :
# Declarative ne remplace que les déclencheurs qu'il a lui-même posés
# (DeclarativeJobPropertyTrackerAction) — celui d'un config.xml est préservé
# indéfiniment (mesuré sur le lab 2026-08-06, sur le jumeau team-publish : 4
# builds, token du XML jamais écrasé ; le même XML privé de ses <triggers> a
# bien laissé le Jenkinsfile poser le sien). Une divergence serait donc
# SILENCIEUSE : c'est ce que les quatre contrôles suivants interdisent.
grep -q '<regexpFilterText>\$PR_ACTION|\$PR_MERGED</regexpFilterText>' "$JOB" \
  && ok "filterText identique dans le XML (déclencheur vivant dès la pose du job)" || ko "filterText du XML divergent"
grep -q '<regexpFilterExpression>\^closed\\|true\$</regexpFilterExpression>' "$JOB" \
  && ok "filterExpression identique dans le XML" || ko "filterExpression du XML divergente"
grep -q '<token>stoa-team-apply</token>' "$JOB" \
  && ok "token identique dans le XML" || ko "token du XML divergent"
MIRROR_KO=""
for K in PR_BRANCH PR_NUMBER PR_ACTION PR_MERGED PR_MERGED_BY PR_REQUESTER MERGE_SHA; do
  grep -q "<key>${K}</key>" "$JOB" || MIRROR_KO="${MIRROR_KO} ${K}"
done
[ -z "$MIRROR_KO" ] \
  && ok "les 7 genericVariables du Jenkinsfile sont présentes à l'identique dans le XML" \
  || ko "clés absentes du XML :${MIRROR_KO} — le webhook serait borgne jusqu'au premier build"

echo
echo "== 4. la branche est gardée à onboard/*, AVANT la pause (personne n'est réveillé pour rien) =="
jf "expression { (env.PR_BRANCH ?: '').startsWith('onboard/') }" \
  && ok "garde de branche onboard/* présente (condition \`when\`)" \
  || ko "garde de branche absente — appliquerait sur n'importe quelle PR fermée du dépôt plateforme"
jf "beforeInput true" \
  && ok "\`beforeInput true\` : la condition est évaluée AVANT la demande en attente — une PR hors onboard/* ne réveille personne" \
  || ko "\`beforeInput true\` absent — une PR hors onboard/* ouvrirait quand même une demande en attente (la directive \`input\` passe AVANT \`when\` par défaut)"

echo
echo "== 5. la garde d'identité est réellement appelée, AVANT team-apply.sh =="
# Ancre sur l'INVOCATION (`sh scripts/lib/assert-merge-identity.sh`), jamais sur
# la mention du nom : l'en-tête du Jenkinsfile cite le script en prose.
GUARD_LINE=$(grep -n 'sh scripts/lib/assert-merge-identity\.sh' "$JF" | head -1)
L_GUARD=${GUARD_LINE%%:*}
[ -n "$GUARD_LINE" ] \
  && ok "assert-merge-identity.sh réellement invoquée (ligne ${L_GUARD}, appel réel — pas une mention en commentaire)" \
  || ko "aucun appel RÉEL à scripts/lib/assert-merge-identity.sh — la garde d'identité a disparu"
# Les PAIRES option/variable, pas seulement les noms d'options : c'est le
# CÂBLAGE (quelle valeur alimente quel drapeau) qui doit survivre au passage de
# withEnv(G_*) aux variables déjà présentes dans l'environnement du step.
printf '%s' "$GUARD_LINE" | grep -qF -- '--merged-by "${PR_MERGED_BY:-}"' \
  && ok "--merged-by alimenté par PR_MERGED_BY (webhook)" || ko "--merged-by non alimenté par PR_MERGED_BY"
printf '%s' "$GUARD_LINE" | grep -qF -- '--requester "${PR_REQUESTER:-}"' \
  && ok "--requester alimenté par PR_REQUESTER (quatre yeux)" || ko "--requester non alimenté par PR_REQUESTER"
printf '%s' "$GUARD_LINE" | grep -qF -- '--vault-user "${V_USER:-}"' \
  && ok "--vault-user alimenté par V_USER (la saisie de la pause)" || ko "--vault-user non alimenté par V_USER"
L_APPLY=$(grep -n 'bash scripts/team-apply\.sh' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_GUARD" ] && [ -n "$L_APPLY" ] && [ "$L_GUARD" -lt "$L_APPLY" ]; then
  ok "garde ligne $L_GUARD, apply ligne $L_APPLY"
else
  ko "garde APRÈS l'apply (ou introuvable) : garde=$L_GUARD apply=$L_APPLY"
fi

echo
echo "== 6. team-apply.sh est bien invoqué, et le pipeline reste MINCE =="
grep -q 'bash scripts/team-apply\.sh' "$JF" \
  && ok "scripts/team-apply.sh invoqué" || ko "team-apply.sh non invoqué — job mort"
# Le pipeline ROUTE, il ne réimplémente pas. Aucun appel direct à l'API de la
# gateway ni à Ansible ne doit apparaître ici.
if grep -qE '^\s*(curl|ansible-playbook) ' "$JF"; then
  ko "le Jenkinsfile appelle directement curl/ansible-playbook — la substance doit rester dans scripts/ et ansible/roles/"
else
  ok "aucun curl/ansible-playbook direct : le pipeline route, le moteur reste dans scripts/ et ansible/roles/"
fi

echo
echo "== 7. pas d'injection : les valeurs sont lues par le SHELL, jamais interpolées par Groovy =="
# merged_by vient d'un webhook, V_USER/V_PASS d'une saisie humaine : trois
# tiers. Interpolés par Groovy DANS la chaîne sh, ils exécuteraient du shell
# arbitraire sur l'agent. En déclaratif les valeurs du webhook sont DÉJÀ dans
# l'environnement du step (contribuées par GenericTrigger) et celles de la pause
# y sont posées par la directive `input` — d'où la disparition des withEnv()
# explicites. Ce qui doit être prouvé n'a pas changé.
grep -q "sh '''" "$JF" \
  && ok "le bloc login+apply est en triple quotes SIMPLES (Groovy n'y interpole rien)" \
  || ko "aucun bloc \`sh '''\` — vérifier comment le bloc d'apply est écrit"
if grep -q 'sh """' "$JF"; then
  ko "un bloc \`sh \"\"\"\` (triple quotes DOUBLES) existe — Groovy y interpolerait le mot de passe et les champs du webhook"
else
  ok "aucun bloc \`sh \"\"\"\` : impossible d'interpoler un secret dans une chaîne shell"
fi
printf '%s' "$GUARD_LINE" | grep -q "sh '" \
  && ok "chaîne sh de la garde en quotes simples (les \${…} y sont du SHELL, pas du Groovy)" \
  || ko "chaîne sh de la garde en quotes doubles (Groovy interpolerait)"
grep -q "password(name: 'V_PASS'" "$JF" \
  && ok "le mot de passe de la pause est un paramètre \`password\` (masqué), pas un \`string\`" \
  || ko "V_PASS n'est pas déclaré en paramètre \`password\` — il s'afficherait en clair dans l'UI et les logs"
grep -q "string(name: 'V_USER'" "$JF" \
  && ok "le login de la pause est un paramètre \`string\` nommé V_USER" || ko "V_USER non déclaré en paramètre de la pause"
# Le nom V_PASS (et non VAULT_USER_PASSWORD) est CE QUI PERMET le §13 : la
# valeur est recopiée puis `unset` dans le seul sh qui en a besoin.
if grep -q "password(name: 'VAULT_USER_PASSWORD'" "$JF"; then
  ko "la pause expose directement VAULT_USER_PASSWORD — la variable resterait dans l'environnement de TOUTE l'étape, l'unset du §13 deviendrait inopérant"
else
  ok "la pause n'expose pas VAULT_USER_PASSWORD directement (nom intermédiaire V_PASS, cf. §13)"
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
echo "== 9. login et l'appel à team-apply.sh se suivent TEXTUELLEMENT (login précède l'appel) =="
if awk '/\. ci\/lib\/vault-login\.sh/{f=1} f&&/bash scripts\/team-apply\.sh/{print "same"; exit}' "$JF" | grep -q same; then
  ok "vault-login.sh (source réelle) précède textuellement l'appel réel à team-apply.sh"
else
  ko "vault-login.sh et l'appel réel à team-apply.sh ne se suivent pas dans cet ordre — le trap de révocation pourrait tuer le token avant l'apply"
fi
# UN SEUL step `sh` pour le login ET l'apply : deux steps rouvriraient un
# process par step, et le trap du premier révoquerait le token AVANT que le
# second ne le consomme. Preuve : entre la source de la lib et l'appel au
# script, aucune fermeture de bloc `sh` (`'''`) ne doit s'intercaler.
BETWEEN=$(awk "NR>$(grep -n '\. ci/lib/vault-login\.sh' "$JF" | head -1 | cut -d: -f1) && NR<$(grep -n 'bash scripts/team-apply\.sh' "$JF" | head -1 | cut -d: -f1)" "$JF" | grep -c "'''")
[ "$BETWEEN" -eq 0 ] \
  && ok "aucune fermeture de bloc sh entre le login et l'apply — ils sont dans LE MÊME step \`sh\`" \
  || ko "un bloc \`sh\` se ferme entre le login et l'apply (${BETWEEN} occurrence(s) de ''') — le trap révoquerait le token avant sa consommation"

echo
echo "== 10. la garde et team-apply.sh appelés existent et sont parsables =="
[ -f "$REPO/scripts/lib/assert-merge-identity.sh" ] \
  && ok "scripts/lib/assert-merge-identity.sh présent" || ko "script absent — appel mort"
sh -n "$REPO/scripts/lib/assert-merge-identity.sh" 2>/dev/null \
  && ok "assert-merge-identity.sh : syntaxe shell valide" || ko "assert-merge-identity.sh non parsable"
[ -f "$REPO/scripts/team-apply.sh" ] \
  && ok "scripts/team-apply.sh présent" || ko "team-apply.sh absent — appel mort"
bash -n "$REPO/scripts/team-apply.sh" 2>/dev/null \
  && ok "team-apply.sh : syntaxe shell valide" || ko "team-apply.sh non parsable"
[ -f "$REPO/ci/lib/vault-login.sh" ] \
  && ok "ci/lib/vault-login.sh présent" || ko "vault-login.sh absent — appel mort"

echo
echo "== 11. le job est bien posé par setup-team-onboard-jobs.sh =="
grep -q 'team-apply' "$REPO/scripts/setup-team-onboard-jobs.sh" \
  && ok "team-apply listé dans JOBS de setup-team-onboard-jobs.sh" || ko "team-apply absent de JOBS"

echo
echo "== 12. les \`export VAR=\` du bloc sh sont devenus des entrées de \`environment\` — présence ET valeur =="
# FILET STATIQUE (revue finale de branche) contre la régression qui a coûté
# deux rounds de la Task 8 : VAULT_USER_AUTH_MOUNT absent du job faisait
# retomber ci/lib/vault-login.sh sur son défaut ldap (la convention CLIENT)
# alors que ce lab authentifie ses opérateurs en userpass — login refusé,
# jamais détecté par une revue statique puisque ce filet n'existait pas.
# On vérifie la VALEUR LITTÉRALE, pas seulement le nom (un grep nu matcherait
# aussi les commentaires qui citent la variable — ils la citent 4 fois).
grep -qE '^  environment \{' "$JF" \
  && ok "bloc \`environment\` de niveau pipeline présent" || ko "aucun bloc \`environment\` de niveau pipeline"
jf 'VAULT_USER_AUTH_MOUNT = "${env.VAULT_USER_AUTH_MOUNT ?: '"'"'userpass'"'"'}"' \
  && ok "valeur littérale de VAULT_USER_AUTH_MOUNT = userpass (défaut nominatif du lab, surchargeable en ldap chez le client)" \
  || ko "VAULT_USER_AUTH_MOUNT : valeur par défaut inattendue ou absente — régression connue (Task 8, deux rounds pour la trouver en réel)"
jf 'APIM_API_BASE = "${env.APIM_API_BASE ?: '"'"'http://webmethods-mock:8080/rest/apigateway'"'"'}"' \
  && ok "valeur littérale de APIM_API_BASE = mock in-cluster (jamais 5555)" \
  || ko "APIM_API_BASE : valeur par défaut inattendue ou absente — team-apply.sh refuse de démarrer sans lui (\${APIM_API_BASE:?…}, team-apply.sh:32)"
# JENKINS_UI : fix mesuré (Task 7) — "localhost" depuis le conteneur du job ne
# désigne PAS Jenkins ; sans lui, la re-pose événementielle des listes échoue
# systématiquement en job réel (curl "000"), jamais vu en test depuis un poste.
jf 'JENKINS_UI = "${env.JENKINS_UI ?: '"'"'http://jenkins:8080'"'"'}"' \
  && ok "valeur littérale de JENKINS_UI = http://jenkins:8080 (sinon : re-pose injoignable en job réel)" \
  || ko "JENKINS_UI : valeur par défaut inattendue ou absente"
jf 'VAULT_ADDR = "${env.VAULT_ADDR ?: '"'"'http://vault:8200'"'"'}"' \
  && ok "valeur littérale de VAULT_ADDR = http://vault:8200 (alias in-cluster)" \
  || ko "VAULT_ADDR : valeur par défaut inattendue ou absente"
jf 'GIT_WEB_HOST = "${env.GIT_WEB_HOST ?: '"'"'http://localhost:13000'"'"'}"' \
  && ok "valeur littérale de GIT_WEB_HOST = http://localhost:13000 (lien CLIQUABLE du commentaire de PR, vu d'un poste — pas l'alias interne)" \
  || ko "GIT_WEB_HOST : valeur par défaut inattendue ou absente — le lien du commentaire retomberait sur GIT_HOST, non résolu hors des conteneurs"
jf 'GIT_HOST = "${env.GIT_HOST ?: '"'"'http://gitea:3000'"'"'}"' \
  && ok "valeur littérale de GIT_HOST = http://gitea:3000 (alias in-cluster)" \
  || ko "GIT_HOST : valeur par défaut inattendue ou absente"
jf 'GITEA_CREDENTIALS_ID = "${env.GITEA_CREDENTIALS_ID ?: '"'"'gitea-provision-token'"'"'}"' \
  && ok "valeur littérale de GITEA_CREDENTIALS_ID = gitea-provision-token (point de config client, plus en dur dans le pipeline)" \
  || ko "GITEA_CREDENTIALS_ID : valeur par défaut inattendue ou absente"
jf "withCredentials(forgeCreds())" \
  && ok "le credential Gitea est réellement lu via env.GITEA_CREDENTIALS_ID et exposé en GITEA_TOKEN (jamais en argv)" \
  || ko "withCredentials n'utilise pas env.GITEA_CREDENTIALS_ID — la surcharge client serait décorative"
# L'ordre compte : le bloc `environment` doit précéder les `stages` pour que
# les valeurs soient dans l'environnement de TOUS les steps — en particulier
# VAULT_USER_AUTH_MOUNT AVANT que vault-login.sh ne soit sourcé (la lib la lit
# au moment du login, pas après).
L_ENV=$(grep -n '^  environment {' "$JF" | head -1 | cut -d: -f1)
L_STAGES=$(grep -n '^  stages {' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_ENV" ] && [ -n "$L_STAGES" ] && [ "$L_ENV" -lt "$L_STAGES" ]; then
  ok "\`environment\` (ligne $L_ENV) précède \`stages\` (ligne $L_STAGES) — exporté avant que vault-login.sh ne soit sourcé"
else
  ko "ordre environment/stages non confirmé (environment=$L_ENV stages=$L_STAGES)"
fi

echo
echo "== 13. V_PASS ne survit pas dans l'environnement du step sh =="
L_EXPORT_USER=$(grep -n 'export VAULT_USER="\${V_USER:-}"' "$JF" | head -1 | cut -d: -f1)
[ -n "$L_EXPORT_USER" ] \
  && ok "VAULT_USER alimenté depuis V_USER dans le bloc sh (ligne ${L_EXPORT_USER})" \
  || ko "VAULT_USER non alimenté depuis V_USER — le login nominatif n'aurait pas d'identité"
L_EXPORT_PASS=$(grep -n 'export VAULT_USER_PASSWORD="\${V_PASS:-}"' "$JF" | head -1 | cut -d: -f1)
L_UNSET=$(grep -n '^ *unset V_PASS$' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_EXPORT_PASS" ] && [ -n "$L_UNSET" ] && [ "$L_EXPORT_PASS" -lt "$L_UNSET" ]; then
  ok "unset V_PASS après l'export (ligne ${L_EXPORT_PASS} puis ${L_UNSET}) — le mot de passe ne reste pas lisible dans /proc/PID/environ"
else
  ko "unset V_PASS absent ou avant l'export (export=${L_EXPORT_PASS} unset=${L_UNSET}) — le mot de passe resterait lisible dans /proc/PID/environ"
fi
# L'unset doit précéder TOUT appel réseau (le login inclus) : après, le mot de
# passe aurait déjà été visible dans l'environnement d'un process fils.
L_SOURCE=$(grep -n '\. ci/lib/vault-login\.sh' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_UNSET" ] && [ -n "$L_SOURCE" ] && [ "$L_UNSET" -lt "$L_SOURCE" ]; then
  ok "unset V_PASS (ligne ${L_UNSET}) AVANT la source de vault-login.sh (ligne ${L_SOURCE}) — donc avant tout appel réseau"
else
  ko "unset V_PASS après le login (unset=${L_UNSET} source=${L_SOURCE})"
fi

echo
echo "== 14. la pause ne réserve AUCUN exécuteur =="
# `agent none` au niveau pipeline + directive `input` de stage : la pause est
# évaluée AVANT l'allocation de l'agent de l'étape. Un `agent any` de niveau
# pipeline gâcherait un slot pendant toute l'attente d'une réponse humaine —
# c'est la raison pour laquelle l'input() du job Groovy était déjà HORS du
# node{}.
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

echo
echo "== 15. plus AUCUN Groovy inline dans le job : c'est un Pipeline from SCM =="
# LA demande client : des Jenkinsfile versionnés, pas un pipeline en dur dans
# un config.xml. Ce contrôle est la preuve que la conversion a bien eu lieu et
# ne peut pas régresser en silence.
grep -q 'CpsScmFlowDefinition' "$JOB" \
  && ok "définition = CpsScmFlowDefinition (Pipeline from SCM)" || ko "le job n'est pas un Pipeline from SCM"
if grep -q '>org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition<\|class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition"' "$JOB"; then
  ko "le job contient encore une CpsFlowDefinition (pipeline en dur dans le XML)"
else
  ok "aucune CpsFlowDefinition résiduelle"
fi
if grep -q '<script>' "$JOB"; then
  ko "le job contient encore un bloc <script> (Groovy inline)"
else
  ok "aucun bloc <script> : le XML ne porte plus une ligne de Groovy"
fi
grep -qF '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.team-apply</scriptPath>' "$JOB" \
  && ok "scriptPath pointe sur ci/Jenkinsfile.team-apply" || ko "scriptPath absent ou divergent"
grep -qF '<lightweight>false</lightweight>' "$JOB" \
  && ok "lightweight=false : le workspace de l'agent porte tout le dépôt (scripts/, ansible/, ci/lib/), pas seulement le Jenkinsfile" \
  || ko "lightweight absent ou true — le workspace n'aurait que le Jenkinsfile, tous les appels scripts/ mourraient"
# Le Jenkinsfile lui-même doit rester déclaratif : ni try/catch, ni pipeline
# scripté déguisé. AUCUN `node(…)` n'est toléré ici (à la différence de
# team-publish, dont le `post` en exige un) : ce job n'a pas de bloc `post`.
if grep -qE '^\s*(try \{|\} catch)' "$JF"; then
  ko "le Jenkinsfile contient un try/catch — la gestion d'erreur doit passer par les codes de retour et \`post\`"
else
  ok "aucun try/catch : le pipeline reste déclaratif"
fi
NODE_COUNT=$(grep -cE '^\s*node\(' "$JF")
# Exactement 1 `node(...)` attendu : celui du `post{always}` (parité team-publish).
# Avec `agent none`, le post n'a ni exécuteur ni workspace → un `node` explicite y
# est OBLIGATOIRE (pas du pipeline scripté qui revient). Ailleurs qu'au post = 0.
[ "$NODE_COUNT" -eq 1 ] \
  && ok "exactement un \`node(...)\` — celui du \`post{always}\` (agent none l'exige), pas du Groovy scripté ailleurs" \
  || ko "nombre de \`node(...)\` inattendu (${NODE_COUNT}, attendu 1 = celui du post) — le pipeline redevient scripté OU le post a perdu son node"
POST_NODE=$(awk "NR>=${L_POST:-0}" "$JF" | grep -cE '^\s*node\(')
[ "$POST_NODE" -eq 1 ] \
  && ok "le seul \`node(...)\` est bien DANS le \`post{}\` — le corps du pipeline reste 100% déclaratif" \
  || ko "le \`node(...)\` n'est pas dans le post (${POST_NODE} trouvé au post) — Groovy scripté hors post"
SCRIPT_BLOCKS=$(grep -cE '^\s*script \{' "$JF")
[ "$SCRIPT_BLOCKS" -le 1 ] \
  && ok "au plus un bloc \`script {}\` (le nommage du build) — le reste est déclaratif" \
  || ko "${SCRIPT_BLOCKS} blocs \`script {}\` — le Groovy revient par la fenêtre"

echo
echo "== 15b. post{always} de STATUT BUILD sur la PR (parité team-publish, dette I3 fermée) =="
# team-apply.sh commente DÉJÀ la PR (✅/❌) mais SEULEMENT s'il tourne : un échec
# AVANT lui (garde d'identité refusée, pause abandonnée/expirée, agent injoignable)
# laissait la PR d'onboarding MUETTE — c'est la dette I3, longtemps ouverte pour
# team-apply. Ce bloc `post{always}` de niveau PIPELINE la ferme.
L_POST=$(grep -n '^  post {' "$JF" | head -1 | cut -d: -f1)
[ -n "$L_POST" ] \
  && ok "bloc \`post\` de niveau PIPELINE présent (ligne $L_POST) — un refus de garde ou une pause abandonnée est désormais commenté sur la PR (dette I3 FERMÉE)" \
  || ko "aucun \`post\` de niveau pipeline — un refus de garde ou une pause abandonnée resterait muet sur la PR (dette I3 reproduite)"
grep -qF 'COMMENT_MARKER="<!-- team-apply-build -->"' "$JF" \
  && ok "marqueur DISTINCT \`team-apply-build\` — le statut build ne peut pas écraser le commentaire détaillé de team-apply.sh (chacun idempotent sous son marqueur)" \
  || ko "marqueur de statut build absent ou non distinct — risque d'écrasement du commentaire de team-apply.sh"
{ awk "NR>=${L_POST:-0}" "$JF" | grep -q 'gitea-pr-comment.sh' \
  && awk "NR>=${L_POST:-0}" "$JF" | grep -q 'onboard/\*)'; } \
  && ok "le post{} filtre \`onboard/*\` ET commente via gitea-pr-comment.sh (idempotent, une PR hors onboard/* n'est pas commentée)" \
  || ko "le post{} ne filtre pas onboard/* ou n'appelle pas gitea-pr-comment.sh"

echo
echo "== 16. le total de contrôles exécutés correspond au total ATTENDU, écrit en dur =="
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
