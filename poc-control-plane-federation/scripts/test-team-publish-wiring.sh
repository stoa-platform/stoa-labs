#!/usr/bin/env bash
# test-team-publish-wiring.sh — preuve X/X du CÂBLAGE du job team-publish.
# Analyse statique du XML : ni Jenkins, ni Gitea. Motif copié de
# test-team-apply-wiring.sh (palier 2), étendu pour WEBHOOK_REPO (autorité par
# topologie) et le finally D'ENTRÉE (dette I3 du palier 2, réglée ici).
#
#   ./scripts/test-team-publish-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/team-publish.job.xml"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

[ -f "$JOB" ] || { echo "job introuvable : $JOB"; exit 2; }

echo "== 1. le XML reste bien formé =="
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "parsable" || ko "XML cassé"

echo
echo "== 2. le webhook capte le DÉPÔT déclencheur, QUI a validé, QUI a demandé, et le SHA de merge =="
grep -q '<key>WEBHOOK_REPO</key><value>\$.repository.full_name</value>' "$JOB" \
  && ok "WEBHOOK_REPO mappé sur repository.full_name (autorité par topologie)" \
  || ko "WEBHOOK_REPO absent ou mal mappé — team-publish.sh ne pourrait pas dériver l'équipe"
grep -q 'pull_request.merged_by.login' "$JOB" \
  && ok "merged_by.login capté" || ko "merged_by absent — la garde ne pourrait rien vérifier"
grep -q 'pull_request.user.login' "$JOB" \
  && ok "user.login capté (quatre yeux)" || ko "requester absent"
grep -q '<key>MERGE_SHA</key><value>\$.pull_request.merge_commit_sha</value>' "$JOB" \
  && ok "MERGE_SHA mappé sur merge_commit_sha" || ko "MERGE_SHA absent ou mal mappé — team-publish.sh l'exige (anti-TOCTOU)"

echo
echo "== 3. le filtre GWT est exact (fusion, pas juste fermeture) =="
grep -q '<regexpFilterText>\$PR_ACTION|\$PR_MERGED</regexpFilterText>' "$JOB" \
  && ok "filterText = \$PR_ACTION|\$PR_MERGED" || ko "filterText inattendu"
grep -q '<regexpFilterExpression>\^closed\\|true\$</regexpFilterExpression>' "$JOB" \
  && ok "filterExpression = ^closed\\|true\$" || ko "filterExpression inattendue — laisserait passer une fermeture SANS merge"

echo
echo "== 4. la branche est gardée à api/* =="
grep -q "ref.startsWith('api/')" "$JOB" \
  && ok "garde de branche api/* présente" || ko "garde de branche absente — appliquerait sur n'importe quelle PR fermée d'un dépôt d'équipe"

echo
echo "== 5. la garde d'identité est réellement appelée, AVANT team-publish.sh =="
grep -q 'assert-merge-identity.sh' "$JOB" \
  && ok "assert-merge-identity.sh invoquée" || ko "garde non appelée"
for a in --merged-by --requester --vault-user; do
  grep -q -- "$a" "$JOB" && ok "argument $a passé" || ko "argument $a manquant"
done
L_GUARD=$(grep -n 'assert-merge-identity.sh' "$JOB" | head -1 | cut -d: -f1)
L_APPLY=$(grep -n 'bash scripts/team-publish\.sh' "$JOB" | head -1 | cut -d: -f1)
if [ -n "$L_GUARD" ] && [ -n "$L_APPLY" ] && [ "$L_GUARD" -lt "$L_APPLY" ]; then
  ok "garde ligne $L_GUARD, apply ligne $L_APPLY"
else
  ko "garde APRÈS l'apply (ou introuvable) : garde=$L_GUARD apply=$L_APPLY"
fi

echo
echo "== 6. team-publish.sh est bien invoqué =="
grep -q 'bash scripts/team-publish\.sh' "$JOB" \
  && ok "scripts/team-publish.sh invoqué" || ko "team-publish.sh non invoqué — job mort"

echo
echo "== 7. pas d'injection : les valeurs passent par l'ENVIRONNEMENT ==="
grep -q "withEnv(\[\"G_MERGED_BY=" "$JOB" \
  && ok "identité du valideur exportée via withEnv" || ko "G_MERGED_BY non passé par l'environnement"
grep -q "withEnv(\[\"V_USER=" "$JOB" \
  && ok "VAULT_USER exporté via withEnv" || ko "V_USER non passé par l'environnement"
grep -q '"V_PASS=\${creds\.VAULT_USER_PASSWORD' "$JOB" \
  && ok "VAULT_USER_PASSWORD exporté via withEnv (jamais interpolé dans la chaîne sh)" \
  || ko "V_PASS non passé par l'environnement — le mot de passe risque une interpolation Groovy directe"
if grep 'assert-merge-identity.sh' "$JOB" | grep -q '\${'; then
  ko "interpolation Groovy dans la commande sh de la garde — injection possible"
else
  ok "aucune interpolation Groovy dans la commande sh de la garde"
fi
grep 'assert-merge-identity.sh' "$JOB" | grep -q "^ *sh '" \
  && ok "chaîne sh de la garde en quotes simples" || ko "chaîne sh de la garde en quotes doubles (Groovy interpolerait)"
if grep -A3 "sh '''" "$JOB" | grep -q '\${V_PASS}\|\${V_USER}'; then
  ko "V_PASS/V_USER référencés en syntaxe Groovy (\${...}) dans le bloc sh — vérifier l'absence d'interpolation"
else
  ok "bloc login+apply en triple quotes simples, variables lues par le shell (\$VAR), pas par Groovy"
fi

echo
echo "== 8. le mot de passe ne transite jamais par argv (login sourcé, pas exec direct) =="
grep -q '\. ci/lib/vault-login\.sh' "$JOB" \
  && ok "ci/lib/vault-login.sh sourcé (motif établi, jamais un appel direct qui mettrait le mot de passe en argv)" \
  || ko "vault-login.sh non sourcé — vérifier comment le login est fait"
grep -q 'trap vault_trap_revoke EXIT' "$JOB" \
  && ok "révocation du token armée (trap EXIT) avant tout appel réseau" \
  || ko "aucun trap de révocation — le token nominatif pourrait survivre au build"

echo
echo "== 9. login et apply dans le MÊME step sh (le trap ne doit pas tuer le token avant team-publish.sh) =="
if awk '/\. ci\/lib\/vault-login\.sh/{f=1} f&&/team-publish\.sh/{print "same"; exit}' "$JOB" | grep -q same; then
  ok "vault-login.sh et team-publish.sh dans le même bloc sh (VAULT_TOKEN_FILE hérité par team-publish.sh avant révocation)"
else
  ko "vault-login.sh et team-publish.sh semblent être dans des steps sh séparés — le trap de révocation tuerait le token avant l'apply"
fi

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
echo "== 12. VAULT_USER_AUTH_MOUNT et APIM_API_BASE exportés dans le bloc sh =="
# ANCRÉ sur la ligne \`export VAR=\`, PAS un grep nu (leçon du palier 2, Task 8,
# deux rounds pour la trouver en réel : un grep -q 'VAULT_USER_AUTH_MOUNT' nu
# matche AUSSI les COMMENTAIRES qui nomment la variable — filet « vert vacant »
# sinon). L'ancre \`^ *export VAR=\` ne matche QUE l'export réel.
grep -qE '^ *export VAULT_USER_AUTH_MOUNT=' "$JOB" \
  && ok "VAULT_USER_AUTH_MOUNT exporté (sinon : login retombe sur le défaut ldap de la lib)" \
  || ko "VAULT_USER_AUTH_MOUNT absent — régression connue (palier 2, Task 8)"
grep -qE '^ *export APIM_API_BASE=' "$JOB" \
  && ok "APIM_API_BASE exporté (cible gateway explicite requise)" \
  || ko "APIM_API_BASE absent — team-publish.sh refuse de démarrer sans lui (\${APIM_API_BASE:?...})"
# JENKINS_UI : fix mesuré (Task 7) — "localhost" depuis le conteneur du job ne
# désigne PAS Jenkins ; sans cet export, la re-pose d'app-request échoue
# systématiquement en job réel (curl "000"), jamais vu en test depuis un poste.
grep -qE '^ *export JENKINS_UI=' "$JOB" \
  && ok "JENKINS_UI exporté vers l'alias in-cluster (sinon : re-pose injoignable en job réel)" \
  || ko "JENKINS_UI absent — la re-pose d'app-request échouera systématiquement une fois joué en job (défaut localhost:18080 invalide depuis le conteneur)"

echo
echo "== 13. le finally est pris D'ENTRÉE (dette I3 du palier 2, pas reproduite ici) =="
# LE point que team-apply.job.xml/provision-apply.job.xml manquent (I3) : leur
# try/finally n'entoure QUE l'apply, jamais la garde d'identité — un refus de
# garde n'y laisse donc AUCUNE trace sur la PR. Ici le \`try {\` doit apparaître
# AVANT la garde, pas seulement avant l'apply.
L_TRY=$(grep -n '^try {' "$JOB" | head -1 | cut -d: -f1)
L_GUARD2=$(grep -n "stage('garde identite du valideur')" "$JOB" | head -1 | cut -d: -f1)
L_FINALLY=$(grep -n '^} finally {' "$JOB" | head -1 | cut -d: -f1)
if [ -n "$L_TRY" ] && [ -n "$L_GUARD2" ] && [ "$L_TRY" -lt "$L_GUARD2" ]; then
  ok "try (ligne $L_TRY) commence AVANT la garde d'identité (ligne $L_GUARD2) — un refus de garde EST couvert"
else
  ko "try absent ou APRÈS la garde d'identité (try=$L_TRY garde=$L_GUARD2) — un refus de garde ne serait PAS commenté (dette I3 reproduite)"
fi
[ -n "$L_FINALLY" ] && ok "bloc finally présent (ligne $L_FINALLY)" || ko "aucun bloc finally — rien ne commente un échec"
# Le finally délègue à gitea-pr-comment.sh (idempotent par marqueur), pas un
# appel API inline — vérifier SA présence, pas un motif d'URL qui n'existe
# plus depuis ce refactor.
if [ -n "$L_FINALLY" ] && grep -A40 '^} finally {' "$JOB" | grep -q 'gitea-pr-comment\.sh'; then
  ok "le finally poste bien un commentaire sur la PR (via scripts/lib/gitea-pr-comment.sh)"
else
  ko "le finally ne semble poster aucun commentaire — vérifier l'appel à gitea-pr-comment.sh dans le bloc finally"
fi
# Même marqueur que team-publish.sh : sinon le commentaire de secours du
# finally et celui du script s'empileraient au lieu de se mettre à jour l'un
# l'autre (idempotence cassée par divergence de marqueur).
if [ -n "$L_FINALLY" ] && grep -A40 '^} finally {' "$JOB" | grep -q -- '--&gt;'; then
  ok "le finally utilise le même marqueur d'idempotence que team-publish.sh (<!-- team-publish -->)"
else
  ko "le finally ne semble pas utiliser le marqueur <!-- team-publish --> — idempotence rompue avec team-publish.sh"
fi
# Le commentaire de secours du finally doit cibler WEBHOOK_REPO (le dépôt de
# l'ÉQUIPE), jamais GIT_REPO (le dépôt plateforme, sans rapport avec CETTE PR).
if [ -n "$L_FINALLY" ] && grep -A40 '^} finally {' "$JOB" | grep -q "WEBHOOK_REPO="; then
  ok "le commentaire de secours cible WEBHOOK_REPO (le dépôt de l'équipe, pas la plateforme)"
else
  ko "le commentaire de secours ne référence pas WEBHOOK_REPO — risque de cibler le mauvais dépôt"
fi

echo
echo "== 14. les gardes d'intégrité de team-publish.sh sont réellement câblées =="
# Statique (grep), pas fonctionnel — le comportement rouge/vert de chacune est
# prouvé par contre-épreuve à l'exécution (rapport de tâche), pas ici.
grep -q 'merge-base --is-ancestor' "$REPO/scripts/team-publish.sh" \
  && ok "garde d'atteignabilité merge-base --is-ancestor présente (MERGE_SHA doit être un ANCÊTRE de main, pas juste un objet existant)" \
  || ko "aucune garde d'atteignabilité — un SHA valide mais non fusionné sur main serait accepté"
grep -q 'REPO_AMBIGU' "$REPO/scripts/team-publish.sh" \
  && ok "REPO_AMBIGU présent (refuse si le dépôt est déclaré par plusieurs équipes, jamais un choix arbitraire)" \
  || ko "REPO_AMBIGU absent — un dépôt déclaré deux fois choisirait la première équipe rencontrée en silence"
grep -q 'CONTRAT_ABSENT' "$REPO/scripts/team-publish.sh" \
  && ok "CONTRAT_ABSENT présent (le contrat OpenAPI est vérifié tôt, pas laissé échouer au fond du rôle Ansible)" \
  || ko "CONTRAT_ABSENT absent — un contrat manquant échouerait loin de sa cause réelle"
# Validation de FORME (leçon \Z du palier 1 : refus de CLASSE avant tout argv
# git/curl) — WEBHOOK_REPO et MERGE_SHA viennent d'un webhook (un tiers).
grep -q 'WEBHOOK_REPO_INVALIDE' "$REPO/scripts/team-publish.sh" \
  && ok "WEBHOOK_REPO validé en forme AVANT tout argv git/curl" \
  || ko "WEBHOOK_REPO jamais validé en forme — une valeur de webhook mal formée atteindrait argv sans avoir été regardée"
grep -q 'MERGE_SHA_INVALIDE' "$REPO/scripts/team-publish.sh" \
  && ok "MERGE_SHA validé en forme (40 hex) AVANT tout argv git" \
  || ko "MERGE_SHA jamais validé en forme"
grep -q 'API_NAME_INVALIDE' "$REPO/scripts/team-publish.sh" \
  && ok "API_NAME (dérivé de la branche) validé en forme — devient un segment de CHEMIN (apis/<name>.publish.yml)" \
  || ko "API_NAME jamais validé en forme — évasion de chemin possible via une branche malformée"
# Ordre : le refus de CLASSE (case) doit précéder le refus de FORME complète
# (grep ancré), même discipline que resolve.yml (palier 1) — sinon un \n final
# passerait le grep ancré (piège \Z déjà documenté ailleurs dans ce dépôt).
L_CASE=$(grep -n '\*\[!a-z0-9-\]\*' "$REPO/scripts/team-publish.sh" | head -1 | cut -d: -f1)
L_GREPQ=$(grep -n "API_NAME_INVALIDE" "$REPO/scripts/team-publish.sh" | tail -1 | cut -d: -f1)
if [ -n "$L_CASE" ] && [ -n "$L_GREPQ" ] && [ "$L_CASE" -lt "$L_GREPQ" ]; then
  ok "le refus de classe (case, ligne $L_CASE) précède le refus de forme complète (ligne $L_GREPQ) pour API_NAME"
else
  ko "ordre case/grep pour API_NAME non confirmé (case=$L_CASE forme=$L_GREPQ)"
fi

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
