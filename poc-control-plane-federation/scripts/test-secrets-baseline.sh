#!/usr/bin/env bash
# test-secrets-baseline.sh — preuve X/X que la base de référence de
# check-no-plaintext-secrets.sh ACCEPTE le connu sans AMNISTIER le reste.
#
# CE QUE CE TEST DÉFEND. Une base de référence est un compromis dangereux : elle
# éteint le bruit, et si elle est mal faite elle éteint aussi l'alarme. Le pire
# résultat serait une garde verte qui n'attrape plus rien — exactement ce qu'on
# cherchait à sortir, puisque le point de départ était une garde toujours ROUGE
# que plus personne ne lisait.
#
# Le test tourne sur une COPIE JETABLE (ROOT = dirname du script/..), jamais sur
# l'arborescence réelle : un test qui modifie le dépôt pour se vérifier finit
# tôt ou tard par y laisser quelque chose.
#
#   ./scripts/test-secrets-baseline.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d /tmp/secbase.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# ── arborescence jetable : la garde s'ancre sur dirname($0)/.. ────────────────
mkdir -p "$TMP/root/scripts" "$TMP/root/ci"
cp "$SRC/check-no-plaintext-secrets.sh" "$TMP/root/scripts/"
G="$TMP/root/scripts/check-no-plaintext-secrets.sh"
B="$TMP/root/scripts/secrets-baseline.txt"

# Fixture : un secret CONNU (référencé) et rien d'autre. "hunter2" est une valeur
# de test, jamais un secret réel — même convention que l'auto-test de la garde.
printf '#!/bin/sh\nCONNU_PASS="${CONNU_PASS:-hunter2}"\n' > "$TMP/root/scripts/connu.sh"
printf '# base de test\nscripts/connu.sh|CONNU_PASS|valeur de test assumée\n' > "$B"

run(){ OUT="$(sh "$G" 2>&1)"; RC=$?; }

echo "== 1. occurrence RÉFÉRENCÉE : acceptée, la garde est verte =="
run
[ $RC -eq 0 ] && ok "code retour 0" || ko "échec sur une occurrence pourtant référencée (rc=$RC) : $OUT"
grep -q "1 occurrence" <<<"$OUT" && ok "le compte des occurrences assumées est affiché" || ko "compte absent"

echo
echo "== 2. secret NOUVEAU dans un fichier DÉJÀ référencé : ÉCHEC =="
# Le cas le plus vicieux : le fichier est connu, on pourrait croire qu'il est
# couvert en bloc. La clé est (fichier, VARIABLE), pas le fichier seul.
printf 'AUTRE_PASS="hunter2"\n' >> "$TMP/root/scripts/connu.sh"
run
[ $RC -ne 0 ] && ok "refusé" || ko "AMNISTIE PAR FICHIER — un secret neuf est passé"
grep -q "AUTRE_PASS" <<<"$OUT" && ok "la variable fautive est nommée" || ko "diagnostic muet"
grep -q "secrets-baseline.txt" <<<"$OUT" && ok "dit comment régulariser" || ko "aucune issue proposée"
sed -i.bak '/AUTRE_PASS/d' "$TMP/root/scripts/connu.sh"

echo
echo "== 3. secret NOUVEAU dans un fichier INCONNU : ÉCHEC =="
printf '#!/bin/sh\nNEUF_SECRET="hunter2"\n' > "$TMP/root/scripts/neuf.sh"
run
[ $RC -ne 0 ] && grep -q "NEUF_SECRET" <<<"$OUT" \
  && ok "refusé et nommé" || ko "secret d'un fichier inconnu accepté"
rm -f "$TMP/root/scripts/neuf.sh"

echo
echo "== 4. entrée de base DEVENUE INUTILE : avertit, sans bloquer =="
# Une base qui ne se purge pas finit par absoudre des fichiers disparus : le
# jour où le fichier revient, il est couvert d'avance. D'où l'avertissement.
printf '#!/bin/sh\nCONNU_PASS="${CONNU_PASS:?à fournir}"\n' > "$TMP/root/scripts/connu.sh"
run
[ $RC -eq 0 ] && ok "non bloquant (le dépôt est plus propre, pas moins)" || ko "bloque à tort (rc=$RC)"
grep -q "AVERTISSEMENT" <<<"$OUT" && ok "avertissement émis" || ko "purge nécessaire non signalée"
grep -q "CONNU_PASS" <<<"$OUT" && ok "l'entrée périmée est nommée" || ko "avertissement sans détail"

echo
echo "== 5. base de référence ABSENTE : on ne devient pas permissif =="
# Le pire mode de défaillance : la base disparaît et tout devient « nouveau »…
# ou tout devient accepté. C'est la seconde qui serait grave.
printf '#!/bin/sh\nCONNU_PASS="${CONNU_PASS:-hunter2}"\n' > "$TMP/root/scripts/connu.sh"
mv "$B" "$B.hidden"
run
[ $RC -ne 0 ] && ok "sans base, un secret littéral échoue" || ko "l'absence de base rend la garde PERMISSIVE"
mv "$B.hidden" "$B"

echo
echo "== 6. les commentaires de la base ne comptent pas comme des entrées =="
printf '# ligne|de|commentaire\nscripts/connu.sh|CONNU_PASS|assumée\n' > "$B"
run
[ $RC -eq 0 ] && grep -q "1 occurrence" <<<"$OUT" \
  && ok "1 entrée comptée, pas 2" || ko "les commentaires sont comptés comme des entrées"

echo
echo "== 7. l'auto-test interne de la garde tourne toujours =="
grep -q "AUTO-TEST DE LA GARDE" "$G" && ok "présent" || ko "auto-test retiré par la refonte"
run
grep -q "AUTO-TEST DE LA GARDE EN ÉCHEC" <<<"$OUT" && ko "l'auto-test de la garde échoue" || ok "auto-test vert"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || { echo "--- dernière sortie ---"; echo "$OUT"; exit 1; }
