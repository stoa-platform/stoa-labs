#!/usr/bin/env bash
# test-merge-identity.sh — preuve X/X de la garde assert-merge-identity.sh.
# HORS LIGNE : ni Jenkins, ni Gitea, ni Vault. Pur shell.
#
# `A && B || C` (SC2015) est l'idiome des scripts de preuve de ce dépôt (même
# pragma et même raison que scripts/lib/archive-store.sh:10-15) : `ok`/`ko` ne
# produisent aucun effet de bord qui rendrait la branche C ambiguë — seul un
# `printf` sur un tube fermé pourrait échouer. Sans ce pragma, shellcheck rend
# 1 sur dix-neuf informations qui décrivent toutes la même construction voulue.
# shellcheck disable=SC2015
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
echo "== 2bis. FAIL-CLOSED : le DEMANDEUR absent — le quatre-yeux ne se saute pas =="
# LE TROU QUE CETTE SECTION FERME (trouvé le 2026-09-12). Le contrôle des quatre
# yeux était écrit `elif [ -n "$N_REQ" ] && [ "$N_REQ" = "$N_MERGER" ]` : un
# demandeur VIDE ne le faisait pas échouer, il le faisait SAUTER — et la garde
# imprimait MERGE_IDENTITY_OK. C'était latent tant que le seul visage de forge
# remplissait toujours le champ (Gitea : `$.pull_request.user.login`). Le GitLab
# Plugin, lui, n'expose AUCUN champ d'auteur : brancher ce visage sans fermer ce
# trou aurait permis à quelqu'un de valider sa propre demande d'onboarding, sans
# une ligne pour le dire. Un demandeur inconnu est donc un REFUS
# (REQUESTER_UNKNOWN — le même vocabulaire qu'A7), jamais un contrôle sauté.
run --merged-by alice --requester "" --vault-user alice
[ $RC -ne 0 ] && ok "demandeur vide ⇒ REFUSÉ (et non : quatre-yeux sauté en silence)" \
  || ko "FAIL-OPEN : la garde a dit OK sans pouvoir vérifier les quatre yeux — c'est le trou du 2026-09-12"
grep -q "REQUESTER_UNKNOWN" <<<"$OUT" && ok "REQUESTER_UNKNOWN : le code dit lequel des deux champs manque" \
  || ko "refus non nommé : $(printf '%s' "$OUT" | head -1)"
grep -q "MERGE_IDENTITY_OK" <<<"$OUT" && ko "la garde a AUSSI imprimé MERGE_IDENTITY_OK — un lecteur croirait le contrôle fait" \
  || ok "aucun MERGE_IDENTITY_OK dans la sortie du refus"
# … SAUF quand la porte du palier admet l'auto-approbation : là, les quatre yeux
# ne sont pas exigés, donc l'identité du demandeur n'est pas nécessaire — et
# l'identité du RÉPONDANT reste vérifiée, elle.
run --merged-by alice --requester "" --vault-user alice --allow-self-approval
[ $RC -eq 0 ] && grep -q "MERGE_IDENTITY_OK" <<<"$OUT" \
  && ok "avec --allow-self-approval : demandeur vide ADMIS (le quatre-yeux n'est pas exigé pour ce palier), et le répondant reste vérifié" \
  || ko "auto-approbation refusée à tort (rc=$RC) : $(printf '%s' "$OUT" | head -1)"
run --merged-by alice --requester "" --vault-user carol --allow-self-approval
[ $RC -ne 0 ] && grep -q "MERGER_MISMATCH" <<<"$OUT" \
  && ok "et --allow-self-approval n'ouvre PAS la porte au reste : un répondant qui n'a pas validé est toujours refusé" \
  || ko "auto-approbation a laissé passer un répondant étranger (rc=$RC)"

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
echo "== 10. --allow-self-approval : la porte relâche les QUATRE YEUX, rien d'autre =="
# Un drapeau dont le métier est de relâcher une garde de sécurité est le dernier
# qu'on laisse sans épreuve. Les cas encodent la frontière EXACTE, et chacun tue
# une MUTATION précise (leçon G3 : une assertion se règle par mutation, pas par
# intention) :
#   (a)     le drapeau ne fait RIEN         -> rougit
#   (a bis) il relâche EN SILENCE           -> rougit
#   (b)     il est actif PAR DÉFAUT         -> rougit
#   (c)     il court-circuite MERGER_MISMATCH -> rougit
#   (c bis) il court-circuite MERGER_UNKNOWN  -> rougit
# Vérifié par DEUX mutations réelles, et les comptes ne sont pas les mêmes — ce
# qui est justement la preuve que les cas mesurent des choses distinctes :
#   `[ "$ALLOW_SELF" = 1 ] && exit 0` placé AVANT les comparaisons  -> 16/19
#     (a, a bis, c rougissent ; c bis reste vert : MERGER_UNKNOWN est évalué
#      plus haut, la mutation ne l'atteint pas)
#   la même ligne placée avant MERGER_UNKNOWN, tout en haut          -> 15/19
#     (c bis rougit à son tour)
# (b) reste vert dans les deux : il ne mesure PAS le drapeau, il mesure que le
# défaut est resté fermé — c'est son rôle, et c'est pour ça qu'il y est.
run --merged-by alice --requester alice --vault-user alice --allow-self-approval
[ $RC -eq 0 ] && grep -q "MERGE_IDENTITY_OK" <<<"$OUT" \
  && ok "(a) auto-approbation ACCEPTÉE quand la porte l'admet" \
  || ko "(a) le drapeau ne relâche pas les quatre yeux (rc=$RC) : $OUT"
grep -q "selfApproval" <<<"$OUT" \
  && ok "(a bis) le relâchement est DIT dans le log (pas une garde oubliée en silence)" \
  || ko "(a bis) auto-approbation silencieuse — indiscernable d'une garde absente"

run --merged-by alice --requester alice --vault-user alice
[ $RC -ne 0 ] && grep -q "FOUR_EYES_VIOLATION" <<<"$OUT" \
  && ok "(b) MÊME triplet SANS le drapeau : FOUR_EYES_VIOLATION (le défaut reste OFF)" \
  || ko "(b) auto-approbation acceptée sans drapeau — le défaut n'est pas fermé"

run --merged-by alice --requester bob --vault-user carol --allow-self-approval
[ $RC -ne 0 ] && grep -q "MERGER_MISMATCH" <<<"$OUT" \
  && ok "(c) le drapeau ne dispense PAS de MERGER_MISMATCH" \
  || ko "(c) FAIL-OPEN : le drapeau laisse passer une identité qui n'a pas mergé"

run --merged-by "" --requester bob --vault-user carol --allow-self-approval
[ $RC -ne 0 ] && grep -q "MERGER_UNKNOWN" <<<"$OUT" \
  && ok "(c bis) le drapeau ne dispense PAS de MERGER_UNKNOWN" \
  || ko "(c bis) FAIL-OPEN : le drapeau laisse passer un mergeur inconnu"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
