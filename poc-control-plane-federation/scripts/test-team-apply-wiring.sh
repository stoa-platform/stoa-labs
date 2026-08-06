#!/usr/bin/env bash
# test-team-apply-wiring.sh — preuve X/X du CÂBLAGE du job team-apply. Analyse
# statique du XML : ni Jenkins, ni Gitea. Motif copié de
# test-provision-apply-wiring.sh (Task 2), étendu pour MERGE_SHA et
# team-apply.sh (anti-TOCTOU propre à l'onboarding équipe).
#
#   ./scripts/test-team-apply-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/team-apply.job.xml"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

[ -f "$JOB" ] || { echo "job introuvable : $JOB"; exit 2; }

echo "== 1. le XML reste bien formé =="
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "parsable" || ko "XML cassé"

echo
echo "== 2. le webhook capte QUI a validé, QUI a demandé, et le SHA de merge =="
grep -q 'pull_request.merged_by.login' "$JOB" \
  && ok "merged_by.login capté" || ko "merged_by absent — la garde ne pourrait rien vérifier"
grep -q 'pull_request.user.login' "$JOB" \
  && ok "user.login capté (quatre yeux)" || ko "requester absent"
grep -q '<key>MERGE_SHA</key><value>\$.pull_request.merge_commit_sha</value>' "$JOB" \
  && ok "MERGE_SHA mappé sur merge_commit_sha" || ko "MERGE_SHA absent ou mal mappé — team-apply.sh l'exige (anti-TOCTOU)"

echo
echo "== 3. le filtre GWT est exact (fusion, pas juste fermeture) =="
grep -q '<regexpFilterText>\$PR_ACTION|\$PR_MERGED</regexpFilterText>' "$JOB" \
  && ok "filterText = \$PR_ACTION|\$PR_MERGED" || ko "filterText inattendu"
grep -q '<regexpFilterExpression>\^closed\\|true\$</regexpFilterExpression>' "$JOB" \
  && ok "filterExpression = ^closed\\|true\$" || ko "filterExpression inattendue — laisserait passer une fermeture SANS merge"

echo
echo "== 4. la branche est gardée à onboard/* =="
grep -q "ref.startsWith('onboard/')" "$JOB" \
  && ok "garde de branche onboard/* présente" || ko "garde de branche absente — appliquerait sur n'importe quelle PR fermée"

echo
echo "== 5. la garde d'identité est réellement appelée, AVANT l'apply =="
grep -q 'assert-merge-identity.sh' "$JOB" \
  && ok "assert-merge-identity.sh invoquée" || ko "garde non appelée"
for a in --merged-by --requester --vault-user; do
  grep -q -- "$a" "$JOB" && ok "argument $a passé" || ko "argument $a manquant"
done
L_GUARD=$(grep -n 'assert-merge-identity.sh' "$JOB" | head -1 | cut -d: -f1)
L_APPLY=$(grep -n 'bash scripts/team-apply\.sh' "$JOB" | head -1 | cut -d: -f1)
if [ -n "$L_GUARD" ] && [ -n "$L_APPLY" ] && [ "$L_GUARD" -lt "$L_APPLY" ]; then
  ok "garde ligne $L_GUARD, apply ligne $L_APPLY"
else
  ko "garde APRÈS l'apply (ou introuvable) : garde=$L_GUARD apply=$L_APPLY"
fi

echo
echo "== 6. team-apply.sh est bien invoqué =="
grep -q 'bash scripts/team-apply\.sh' "$JOB" \
  && ok "scripts/team-apply.sh invoqué" || ko "team-apply.sh non invoqué — job mort"

echo
echo "== 7. pas d'injection : les valeurs passent par l'ENVIRONNEMENT ==="
# merged_by vient d'un webhook, vault_user/vault_user_password d'une saisie
# humaine : trois tiers. Interpolés par Groovy DANS la chaîne sh, ils
# exécuteraient du shell arbitraire sur l'agent. La chaîne sh doit être en
# quotes SIMPLES et lire des variables déjà posées par withEnv.
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
# Le bloc login+apply est un sh triple-quotes (''' ... ''') : Groovy ne
# l'interpole PAS (GString nécessiterait des guillemets doubles) — seul le
# shell résout $V_PASS/$V_USER/... à l'intérieur.
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
  && ok "revocation du token armée (trap EXIT) avant tout appel réseau" \
  || ko "aucun trap de révocation — le token nominatif pourrait survivre au build"

echo
echo "== 9. login et apply dans le MÊME step sh (le trap ne doit pas tuer le token avant team-apply.sh) =="
if awk '/\. ci\/lib\/vault-login\.sh/{f=1} f&&/team-apply\.sh/{print "same"; exit}' "$JOB" | grep -q same; then
  ok "vault-login.sh et team-apply.sh dans le même bloc sh (VAULT_TOKEN_FILE hérité par team-apply.sh avant révocation)"
else
  ko "vault-login.sh et team-apply.sh semblent être dans des steps sh séparés — le trap de révocation tuerait le token avant l'apply"
fi

echo
echo "== 10. la garde et team-apply.sh appelés existent et sont exécutables =="
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
echo "== 12. VAULT_USER_AUTH_MOUNT et APIM_API_BASE exportés dans le bloc sh =="
# FILET STATIQUE (revue finale de branche) contre la régression qui a coûté
# deux rounds de la Task 8 : VAULT_USER_AUTH_MOUNT absent du job faisait
# retomber ci/lib/vault-login.sh sur son défaut ldap (la convention CLIENT)
# alors que ce lab authentifie ses opérateurs en userpass — login refusé,
# jamais détecté par une revue XML statique puisque ce filet n'existait pas.
#
# ANCRÉ sur la ligne `export VAR=`, PAS un grep nu (re-revue, Important) : un
# grep -q 'VAULT_USER_AUTH_MOUNT' matche AUSSI les COMMENTAIRES qui nomment
# la variable (le bloc juste au-dessus la cite 4 fois) — contre-épreuve du
# relecteur : amputer les deux lignes `export` en laissant les commentaires
# rendait quand même 30/30. Même classe de « vert vacant » que la preuve 8
# du harnais (LINES>0 sans contrôle positif). L'ancre `^ *export VAR=` ne
# matche QUE l'export réel, jamais sa mention en prose.
grep -qE '^ *export VAULT_USER_AUTH_MOUNT=' "$JOB" \
  && ok "VAULT_USER_AUTH_MOUNT exporté (sinon : login retombe sur le défaut ldap de la lib)" \
  || ko "VAULT_USER_AUTH_MOUNT absent — régression connue (Task 8, deux rounds pour la trouver en réel)"
grep -qE '^ *export APIM_API_BASE=' "$JOB" \
  && ok "APIM_API_BASE exporté (cible gateway explicite requise)" \
  || ko "APIM_API_BASE absent — le job doit le poser explicitement, sans lui team-apply.sh refuse de démarrer (\${APIM_API_BASE:?...}, team-apply.sh:32)"
# JENKINS_UI : fix mesuré (Task 7) — "localhost" depuis le conteneur du job ne
# désigne PAS Jenkins ; sans cet export, la re-pose événementielle (app-request/
# api-request, Task 3) échoue systématiquement en job réel (curl "000"),
# jamais vu en test depuis un poste (où "localhost" désigne bien Jenkins publié).
grep -qE '^ *export JENKINS_UI=' "$JOB" \
  && ok "JENKINS_UI exporté vers l'alias in-cluster (sinon : re-pose injoignable en job réel)" \
  || ko "JENKINS_UI absent — la re-pose événementielle échouera systématiquement une fois jouée en job (défaut localhost:18080 invalide depuis le conteneur)"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
