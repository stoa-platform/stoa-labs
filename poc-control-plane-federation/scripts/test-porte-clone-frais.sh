#!/usr/bin/env bash
# test-porte-clone-frais.sh — LA PORTE DOIT TOURNER SUR UN CLONE FRAIS.
#
# CE QU'ELLE EMPÊCHE. `make lint-ci` mourait à son étape 2 sur tout clone frais
# du dépôt — donc chez un client, donc en CI — et personne ne le voyait, parce
# que sur le poste de développement le fichier qui manque est PRÉSENT.
# Six suites `-live` lisent les mots de passe du lab dans `./.env.lab-users`,
# un fichier 0600 délibérément HORS Git. Absent, `shellcheck -x` rend SC1091
# (« Not following ») et la porte s'arrête là. Mesuré le 2026-09-09 : à
# e1f4254 comme à 4a1b88d, worktree détaché propre, rc=2 à l'étape [2/…] ;
# le même worktree avec un `.env.lab-users` VIDE posé à la main rend rc=0.
#
# LA CAUSE, et c'est elle qu'il faut retenir. Les six fichiers portaient DÉJÀ
# leur directive de suppression — `# shellcheck disable=SC1091`, ou
# `source=/dev/null` pour p7. Elle ne servait à RIEN : une directive shellcheck
# s'attache à la PREMIÈRE commande de la ligne qui suit, et la ligne était la
# LISTE `set -a; . ./.env.lab-users; set +a`. La directive couvrait donc
# `set -a`, jamais le `.`. Un silencieux qui ne silencie rien — l'inverse d'un
# vert vacant : une assertion de confort que tout le monde croyait active.
# Le correctif éclate la liste sur quatre lignes, la directive juste avant le
# point. AUCUN changement de comportement : `set -a` … `set +a` exporte
# toujours ce que le fichier définit (vérifié).
#
# POURQUOI CETTE SUITE PLUTÔT QU'UNE RELECTURE. Le défaut est INVISIBLE à
# l'étape 2 elle-même dès qu'on la joue là où le fichier existe : recoller les
# trois commandes sur une ligne laisse `make lint-ci` VERT sur le poste et
# rouge chez le client. Il faut donc mesurer sous ABSENCE FORCÉE du fichier,
# ce qu'aucune porte existante ne fait. La suite bâtit un bac à sable dont le
# `.env.lab-users` ne peut pas exister (répertoire neuf ; `scripts/lib` est
# LIÉ pour que `-x` suive encore les bibliothèques, les six scripts sont
# COPIÉS pour que la mutation n'écrive jamais dans le dépôt), et y relit les
# six. shellcheck résout `./fichier` depuis le RÉPERTOIRE COURANT, pas depuis
# celui du script — c'est ce qui rend le bac à sable possible (mesuré).
#
# TERRAIN : hors ligne, aucune écriture dans le dépôt.
#
#   bash scripts/test-porte-clone-frais.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

command -v shellcheck >/dev/null || { echo "!! shellcheck absent — \`brew install shellcheck\`"; exit 2; }

# Les six suites qui lisent le fichier hors-Git. La liste est EN DUR : un
# septième script qui prendrait l'habitude doit être ajouté ici sciemment.
SUITES="test-a3-live test-a4-live test-a5-live test-a6-live test-a7-live test-p7-bout-en-bout"

SB="$(mktemp -d /tmp/clonefrais.XXXXXX)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/scripts"
ln -s "$REPO/scripts/lib" "$SB/scripts/lib"
for f in $SUITES; do cp "$REPO/scripts/$f.sh" "$SB/scripts/$f.sh"; done
[ -e "$SB/.env.lab-users" ] && { echo "!! bac à sable pollué"; exit 2; }

# sc1091 <fichier> → nombre de SC1091 rendus, lu DEPUIS le bac à sable.
sc1091(){ ( cd "$SB" && shellcheck -x "scripts/$1.sh" 2>&1 | grep -c 'SC1091 (' ); }
scall(){  ( cd "$SB" && shellcheck -x "scripts/$1.sh" 2>&1 | grep -cE 'SC[0-9]+ \('  ); }

echo "═══ C. sous ABSENCE du fichier hors-Git, les six suites passent shellcheck ═══"
for f in $SUITES; do
  n=$(sc1091 "$f"); t=$(scall "$f")
  if [ "$n" = 0 ] && [ "$t" = 0 ]; then
    ok "C.$f : 0 SC1091, 0 constat — la directive atteint bien le point"
  else
    ko "C.$f : SC1091=$n, constats=$t (la porte mourrait sur un clone frais)"
  fi
done

echo "═══ D. la forme est tenue : la directive précède IMMÉDIATEMENT le point ═══"
# Contrôle de FORME, complémentaire du précédent : il nomme le défaut au lieu
# de le constater, et il tient même si un jour shellcheck cesse de rendre SC1091.
for f in $SUITES; do
  if grep -qE '^[[:space:]]*set -a; \.' "$REPO/scripts/$f.sh"; then
    ko "D.$f : la liste « set -a; . fichier; set +a » est recollée sur une ligne — la directive n'atteint plus le point"
  elif grep -A1 -E '^[[:space:]]*# shellcheck (disable=SC1091|source=/dev/null)' "$REPO/scripts/$f.sh" \
       | grep -qE '^[[:space:]]*\. \./\.env\.lab-users[[:space:]]*$'; then
    ok "D.$f : directive puis point, chacun sur sa ligne"
  else
    ko "D.$f : la directive ne précède pas immédiatement « . ./.env.lab-users »"
  fi
done

echo "═══ E. mutation : l'épreuve attrape bien ce qu'elle prétend attraper ═══"
# On recolle la liste sur une ligne DANS LE BAC À SABLE (le dépôt n'est jamais
# touché) et on vérifie que C rougit. Sans cette mutation, C serait un vert
# vacant de plus : il passerait aussi si shellcheck ne rendait plus rien.
MUT="$SB/scripts/test-a4-live.sh"
cp "$REPO/scripts/test-a4-live.sh" "$MUT"
perl -0pi -e 's/set -a\n\s*(# shellcheck [^\n]*)\n\s*\. \.\/\.env\.lab-users\n\s*set \+a/set -a; . .\/.env.lab-users; set +a/' "$MUT"
if grep -qE '^[[:space:]]*set -a; \.' "$MUT"; then
  if [ "$(sc1091 test-a4-live)" -ge 1 ]; then
    ok "E.1 liste recollée ⇒ SC1091 revient (le défaut du 2026-09-09 reproduit, C rougirait)"
  else
    ko "E.1 le mutant passe encore : C ne prouve rien"
  fi
else
  ko "E.1 mutant no-op — le correctif a-t-il changé de forme ? (la mutation n'a rien recollé)"
fi
cp "$REPO/scripts/test-a4-live.sh" "$MUT"

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
