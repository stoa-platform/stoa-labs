#!/usr/bin/env bash
# test-provision-apply-wiring.sh — preuve X/X du CÂBLAGE de la garde d'identité
# dans le job provision-apply. Analyse statique du XML : ni Jenkins, ni Gitea.
#
# CE QUE CE TEST DÉFEND. scripts/test-merge-identity.sh prouve que la garde
# REFUSE ce qu'elle doit refuser. Il ne prouve pas qu'on l'APPELLE, ni qu'on
# l'appelle AVANT d'appliquer. Une garde correcte branchée après l'écriture, ou
# débranchée par une édition ultérieure, est une garde inexistante — et c'est le
# genre de régression qu'aucun test de logique n'attrape.
#
#   ./scripts/test-provision-apply-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/provision-apply.job.xml"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

[ -f "$JOB" ] || { echo "job introuvable : $JOB"; exit 2; }

echo "== 1. le XML reste bien formé =="
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "parsable" || ko "XML cassé"

echo
echo "== 2. le webhook capte QUI a validé et QUI a demandé =="
grep -q 'pull_request.merged_by.login' "$JOB" \
  && ok "merged_by.login capté" || ko "merged_by absent — la garde ne pourrait rien vérifier"
grep -q 'pull_request.user.login' "$JOB" \
  && ok "user.login capté (quatre yeux)" || ko "requester absent"

echo
echo "== 3. la garde est réellement appelée =="
grep -q 'assert-merge-identity.sh' "$JOB" \
  && ok "assert-merge-identity.sh invoquée" || ko "garde non appelée"
for a in --merged-by --requester --vault-user; do
  grep -q -- "$a" "$JOB" && ok "argument $a passé" || ko "argument $a manquant"
done

echo
echo "== 4. elle tourne AVANT l'apply (l'ordre EST la garde) =="
L_GUARD=$(grep -n 'assert-merge-identity.sh' "$JOB" | head -1 | cut -d: -f1)
L_BUILD=$(grep -n "build job: 'selfservice-app-deploy'" "$JOB" | head -1 | cut -d: -f1)
if [ -n "$L_GUARD" ] && [ -n "$L_BUILD" ] && [ "$L_GUARD" -lt "$L_BUILD" ]; then
  ok "garde ligne $L_GUARD, apply ligne $L_BUILD"
else
  ko "garde APRÈS l'apply (ou introuvable) : garde=$L_GUARD apply=$L_BUILD"
fi

echo
echo "== 5. pas d'injection : les valeurs passent par l'ENVIRONNEMENT =="
# merged_by vient d'un webhook, vault_user d'une saisie humaine : deux tiers.
# Interpolés par Groovy dans la chaîne sh, ils exécuteraient du shell arbitraire
# sur l'agent. La chaîne doit être en quotes SIMPLES et lire des variables.
grep -q "withEnv(\[\"G_MERGED_BY=" "$JOB" \
  && ok "valeurs exportées via withEnv" || ko "valeurs non passées par l'environnement"
if grep 'assert-merge-identity.sh' "$JOB" | grep -q '\${'; then
  ko "interpolation Groovy dans la commande sh — injection possible"
else
  ok "aucune interpolation Groovy dans la commande sh"
fi
grep 'assert-merge-identity.sh' "$JOB" | grep -q "^ *sh '" \
  && ok "chaîne sh en quotes simples" || ko "chaîne sh en quotes doubles (Groovy interpolerait)"

echo
echo "== 6. la garde appelée existe et est exécutable =="
[ -f "$REPO/scripts/lib/assert-merge-identity.sh" ] \
  && ok "scripts/lib/assert-merge-identity.sh présent" || ko "script absent — appel mort"
sh -n "$REPO/scripts/lib/assert-merge-identity.sh" 2>/dev/null \
  && ok "syntaxe shell valide" || ko "script non parsable"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
