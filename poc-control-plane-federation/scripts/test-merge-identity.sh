#!/usr/bin/env bash
# test-merge-identity.sh — preuve X/X de la garde assert-merge-identity.sh.
# HORS LIGNE : ni Jenkins, ni Gitea, ni Vault. Pur shell.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
G="$REPO/scripts/lib/assert-merge-identity.sh"
TMP="$(mktemp -d /tmp/mergeid.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

run(){ OUT="$(sh "$G" "$@" 2>&1)"; RC=$?; }

echo "== 1. cas nominal : le valideur répond, et ce n'est pas le demandeur =="
run --merged-by alice --requester bob --vault-user alice
[ $RC -eq 0 ] && grep -q "MERGE_IDENTITY_OK" <<<"$OUT" && ok "accepté" || ko "refus inattendu (rc=$RC) : $OUT"

echo
echo "== 2. FAIL-CLOSED : merged_by absent (le webhook ne le fournit pas) =="
# Le piège : deux chaînes vides comparées naïvement seraient ÉGALES, et la garde
# passerait au vert sans rien vérifier.
run --merged-by "" --requester bob --vault-user alice
[ $RC -ne 0 ] && ok "refusé" || ko "garde passée avec merged_by vide — FAIL-OPEN"
grep -q "MERGER_UNKNOWN" <<<"$OUT" && ok "MERGER_UNKNOWN" || ko "code absent"

echo
echo "== 3. FAIL-CLOSED : les deux vides (le pire cas du même piège) =="
run --merged-by "" --requester "" --vault-user ""
[ $RC -ne 0 ] && grep -q "MERGER_UNKNOWN" <<<"$OUT" \
  && ok "refusé (pas d'égalité de vides)" || ko "FAIL-OPEN sur deux vides"

echo
echo "== 4. le répondant n'est pas celui qui a mergé =="
run --merged-by alice --requester bob --vault-user carol
[ $RC -ne 0 ] && grep -q "MERGER_MISMATCH" <<<"$OUT" \
  && ok "MERGER_MISMATCH" || ko "identité tierce acceptée"

echo
echo "== 5. quatre yeux : le valideur est le demandeur =="
run --merged-by bob --requester bob --vault-user bob
[ $RC -ne 0 ] && grep -q "FOUR_EYES_VIOLATION" <<<"$OUT" \
  && ok "FOUR_EYES_VIOLATION" || ko "auto-validation acceptée"

echo
echo "== 6. formes d'identité de la voie A (UPN, DOMAIN\\user, casse) =="
run --merged-by alice --requester bob --vault-user "alice@banque.fr"
[ $RC -eq 0 ] && ok "UPN accepté" || ko "UPN refusé : $OUT"
run --merged-by alice --requester bob --vault-user 'BANQUE\alice'
[ $RC -eq 0 ] && ok "DOMAIN\\user accepté" || ko "DOMAIN\\user refusé : $OUT"
run --merged-by Alice --requester bob --vault-user "ALICE"
[ $RC -eq 0 ] && ok "casse ignorée" || ko "casse bloquante : $OUT"

echo
echo "== 7. la normalisation ne confond pas deux personnes distinctes =="
run --merged-by alice --requester bob --vault-user "alice2"
[ $RC -ne 0 ] && ok "'alice2' ≠ 'alice'" || ko "normalisation trop permissive"
run --merged-by "alice@banque.fr" --requester bob --vault-user "alice@autre.fr"
[ $RC -eq 0 ] && ok "même compte, deux domaines : accepté (compte = clé)" \
  || ko "refus alors que le nom de compte est le même"

echo
echo "== 8. correspondance Gitea → annuaire quand les logins diffèrent =="
printf '# gitea:annuaire\nalice-git:alice\nbob-git:bob\n' > "$TMP/map"
run --merged-by alice-git --requester bob-git --vault-user alice --map "$TMP/map"
[ $RC -eq 0 ] && ok "table appliquée" || ko "table ignorée : $OUT"
run --merged-by alice-git --requester alice-git --vault-user alice --map "$TMP/map"
[ $RC -ne 0 ] && grep -q "FOUR_EYES_VIOLATION" <<<"$OUT" \
  && ok "quatre yeux évalués APRÈS la table" || ko "auto-validation non détectée via la table"

echo
echo "== 9. table absente ou illisible : on ne triche pas, on compare brut =="
run --merged-by alice --requester bob --vault-user alice --map "$TMP/nexiste-pas"
[ $RC -eq 0 ] && ok "table absente = comparaison directe" || ko "échec sur table absente"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
