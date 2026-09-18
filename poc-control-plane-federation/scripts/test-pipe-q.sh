#!/usr/bin/env bash
# scripts/test-pipe-q.sh — l'épreuve de `pipe_q` et de sa porte.
#
# CE QU'ELLE PROUVE, et pourquoi chaque point est nécessaire :
#   D  LE DISCRIMINANT : sur un flux assez gros, `grep -q` REND 141 (SIGPIPE) là où
#      `pipe_q` rend 0. Sans lui, rien ne distingue l'avant de l'après : une
#      épreuve qui passe dans les deux états ne mesure pas le lot.
#   E  L'ÉQUIVALENCE DE STATUT partout ailleurs (présent 0, absent 1, erreur 2).
#      C'est ce qui rend la conversion SÛRE : si les statuts divergeaient, 726
#      substitutions auraient changé 726 verdicts.
#   G  LA PORTE rougit sur chacun de ses invariants, par MUTATION. Une porte
#      qu'aucun mutant ne fait rougir n'est pas éprouvée, elle est seulement
#      présente.
#
#   bash scripts/test-pipe-q.sh
set -uo pipefail

# shellcheck disable=SC2329  # MESURÉ : shellcheck 0.11.0 ne voit pas l'invocation
# en PIPELINE de cette fonction dans ces fichiers (0 signalement à HEAD, donc le
# défaut vient bien d'ici), alors qu'il l'accepte sur un script minimal. On perd
# ce signal — et on le REMPLACE : ci/lint-pipe-grepq.sh exige que tout fichier qui
# DÉFINIT pipe_q l'INVOQUE, ce que SC2329 prétend vérifier et fait ici à tort.
pipe_q() { grep -c "$@" >/dev/null; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PORTE="$REPO/ci/lint-pipe-grepq.sh"
TMP="$(mktemp -d /tmp/pipeq.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# rougit_sur <fichier-de-sortie> <règle> — la porte a-t-elle rendu un VERDICT rouge
# nommant cette règle ?
# ⚠ ÉCRITE APRÈS UN FAUX VERT : la première version cherchait seulement le nom de la
# règle dans la sortie. Quand la porte avait une erreur de SYNTAXE, bash imprimait la
# LIGNE FAUTIVE — laquelle contenait le nom de la règle — et l'épreuve concluait
# « la porte a bien rougi ». Elle mesurait le message d'erreur, pas le verdict. On
# exige donc le verdict ET le marqueur d'échec de CETTE règle.
# ⚠ ON DÉCOLORE AVANT DE CHERCHER. La porte imprime « ESC[31m❌ESC[0m R1 » : le code
# de remise à zéro s'intercale ENTRE le marqueur et le nom de la règle, donc la
# chaîne littérale « ❌ R1 » n'existe nulle part et une recherche naïve échoue
# TOUJOURS — y compris quand la porte a parfaitement fait son travail. C'est la
# même famille que le compteur d'échecs aveugle au vocabulaire d'une suite : un
# oracle qui ignore la mise en forme mesure la mise en forme, pas le verdict.
ESC=$(printf '\033')
rougit_sur(){
  sed "s/${ESC}\\[[0-9;]*m//g" "$1" > "$1.plain"
  grep -qF 'PORTE ROUGE' "$1.plain" && grep -qF "❌ $2" "$1.plain"
}

echo "═══ D. LE DISCRIMINANT : grep -q s'inverse, pipe_q non ═══"
# Un flux DÉPASSANT le tampon du tuyau (64 Ko), motif en TÊTE : grep -q part au
# premier match alors que l'écrivain écrit encore ⇒ SIGPIPE ⇒ 141.
seq 1 40000 > "$TMP/gros"     # ~ 270 Ko
S_Q=$( ( set -o pipefail; cat "$TMP/gros" | grep -q '^1$'; echo $? ) )
S_P=$( ( set -o pipefail; cat "$TMP/gros" | pipe_q '^1$'; echo $? ) )
if [ "$S_Q" = 141 ] && [ "$S_P" = 0 ]; then
  ok "D.1 flux de $(wc -c < "$TMP/gros" | tr -d ' ') octets, motif en tête : grep -q rend $S_Q (SIGPIPE, verdict INVERSÉ), pipe_q rend $S_P"
elif [ "$S_P" = 0 ]; then
  ok "D.1 pipe_q rend 0 ; grep -q rend $S_Q sur ce poste (le SIGPIPE dépend de l'ordonnancement — la propriété de pipe_q, elle, ne dépend de rien)"
else
  ko "D.1 pipe_q rend $S_P au lieu de 0 — le remède ne tient pas"
fi

echo "═══ E. ÉQUIVALENCE DE STATUT : aucune conversion ne change un verdict ═══"
printf 'alpha\nbeta\n' > "$TMP/p"
E_KO=''
for cas in 'alpha:0' 'zeta:1'; do
  m=${cas%%:*}; att=${cas##*:}
  a=$( ( cat "$TMP/p" | grep -q "$m"; echo $? ) ); b=$( ( cat "$TMP/p" | pipe_q "$m"; echo $? ) )
  { [ "$a" = "$att" ] && [ "$b" = "$att" ]; } || E_KO="$E_KO [$m:grep=$a,pipe=$b,attendu=$att]"
done
a=$( ( grep -q x "$TMP/absent" 2>/dev/null; echo $? ) ); b=$( ( pipe_q x "$TMP/absent" 2>/dev/null; echo $? ) )
{ [ "$a" = 2 ] && [ "$b" = 2 ]; } || E_KO="$E_KO [fichier absent:grep=$a,pipe=$b,attendu=2]"
[ -z "$E_KO" ] && ok "E.1 statuts identiques : motif présent 0, absent 1, fichier illisible 2 — y compris l'erreur, que grep -c aurait pu perdre" \
               || ko "E.1 divergence de statut :$E_KO"

echo "═══ G. LA PORTE rougit sur chacun de ses invariants ═══"
[ -f "$PORTE" ] || ko "G.0 $PORTE introuvable — tout ce qui suit est ROUGE par construction"

# La porte doit d'abord être VERTE sur le dépôt réel : sans ça, ses mutants ne
# prouveraient rien (un rouge de plus sur un rouge ne discrimine pas).
( cd "$REPO" && bash "$PORTE" >"$TMP/porte.out" 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok "G.1 la porte est VERTE sur le dépôt tel qu'il est" \
                || ko "G.1 la porte est déjà rouge (rc=$RC) : $(tail -2 "$TMP/porte.out" | tr '\n' ' ' | cut -c1-110)"

# ⚠ LES MUTATIONS VIVENT DANS UN DÉPÔT DE FIXTURE, PAS DANS L'ARBRE PARTAGÉ, et
# cette écriture-ci corrige un TEST VACANT. La première version déposait le mutant
# dans `$REPO/scripts/` : or la porte dérive sa portée de `git ls-files`, qui ne
# liste que les fichiers SUIVIS. Un fichier neuf lui était donc INVISIBLE — les
# trois mutations ne mesuraient RIEN, et elles « passaient » uniquement parce que la
# porte, cassée à ce moment-là, rendait un rc non nul. Un test vacant dans la suite
# même qui doit prouver que la porte ne l'est pas.
# Un dépôt jetable règle les deux problèmes d'un coup : le mutant y est SUIVI, et
# l'index de l'arbre partagé n'est jamais touché (règle du dépôt : ne jamais
# `git add` sous un voisin).
FIX="$TMP/fix"
mkdir -p "$FIX/ci" "$FIX/scripts"
git init -q "$FIX" 2>/dev/null
cp "$PORTE" "$FIX/ci/"
sain(){ # un fichier CONFORME, pour que la fixture soit verte AVANT toute mutation
  { printf '#!/usr/bin/env bash\nset -uo pipefail\n'
    printf 'pipe_q() { grep -c "$@" >/dev/null; }\n'
    printf 'printf %%s x | pipe_q x\n'; } > "$FIX/scripts/sain.sh"
}
sain; git -C "$FIX" add -A >/dev/null 2>&1
( cd "$FIX" && bash ci/lint-pipe-grepq.sh >"$TMP/fix0.out" 2>&1 ); RCF=$?
[ "$RCF" -eq 0 ] && ok "G.1b la fixture est VERTE avant mutation — les rouges qui suivent viennent donc du MUTANT" \
                 || ko "G.1b la fixture est déjà rouge (rc=$RCF) : $(grep -E '❌' "$TMP/fix0.out" | head -1 | cut -c1-110)"

mute_fix(){ # <étiquette> <règle> <contenu du mutant>
  printf '%s' "$3" > "$FIX/scripts/mutant.sh"
  git -C "$FIX" add -A >/dev/null 2>&1
  ( cd "$FIX" && bash ci/lint-pipe-grepq.sh >"$TMP/$1.out" 2>&1 ); R=$?
  if [ "$R" -ne 0 ] && rougit_sur "$TMP/$1.out" "$2"; then return 0; fi
  return 1
}

mute_fix m1 R1 '#!/usr/bin/env bash
set -uo pipefail
printf %s x | grep -q x
' && ok "G.2 mutation « un « | grep -q » réapparaît » ⇒ la porte ROUGIT en nommant R1" \
  || ko "G.2 la forme réintroduite passe — R1 est vacante"

mute_fix m2 R3 '#!/usr/bin/env bash
set -uo pipefail
pipe_q() { grep -c "$@" > /dev/null; }
printf %s x | pipe_q x
' && ok "G.3 mutation « une définition diverge d'un octet » ⇒ ROUGE (R3) : la duplication reste MESURÉE" \
  || ko "G.3 une définition divergente passe — R3 est vacante"

mute_fix m3 R5 '#!/usr/bin/env bash
set -uo pipefail
pipe_q() { grep -c "$@" >/dev/null; }
printf %s x | pipe_q x
bash <<_MUT_EOF
printf %s x | pipe_q x
_MUT_EOF
' && ok "G.4 mutation « pipe_q dans un corps de heredoc » ⇒ ROUGE (R5) : le shell enfant n'hérite d'aucune fonction" \
  || ko "G.4 un usage en shell enfant passe — R5 est vacante, et c'est le trou du design"

mute_fix m4 R4 '#!/usr/bin/env bash
set -uo pipefail
printf %s x | pipe_q x
pipe_q() { grep -c "$@" >/dev/null; }
' && ok "G.5 mutation « la définition APRÈS le premier usage » ⇒ ROUGE (R4) : 127 à l'exécution" \
  || ko "G.5 une définition posée après son usage passe — R4 est vacante"

rm -f "$FIX/scripts/mutant.sh"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
