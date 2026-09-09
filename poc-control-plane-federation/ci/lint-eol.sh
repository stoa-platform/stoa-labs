#!/usr/bin/env bash
# ci/lint-eol.sh — LE LIVRABLE EST EN LF, ET CE N'EST PAS LE POSTE QUI EN DÉCIDE.
#
# CE QU'ELLE EMPÊCHE (mesuré le 2026-09-09, CI client `ci-app-request`) :
#   scripts/lib/providers-teams.sh: line 48: $'\r': command not found
#   scripts/lib/providers-teams.sh: line 50: syntax error near unexpected token `$'{\r''
#   ERREUR: scripts/lib/providers-teams.sh introuvable ou illisible
# Le fichier était LF dans le dépôt et CRLF dans la copie de travail du client :
# sans `.gitattributes`, c'est `core.autocrlf` du POSTE qui décide, et le même
# dépôt produit deux arbres différents. Le message de bash désigne en plus la
# mauvaise cause — « introuvable ou illisible » pour un fichier présent et lisible.
#
# DEUX PROPRIÉTÉS, ET LA SECONDE EST CELLE QUI TIENT DANS LE TEMPS :
#   A. l'ÉTAT — aucun fichier suivi de type interprété ne contient de CR ;
#   B. le MÉCANISME — chacun de ces fichiers est couvert par une règle `eol=lf`,
#      mesuré par `git check-attr` (donc par git lui-même, pas par une relecture
#      de `.gitattributes`). Sans B, A redeviendrait vrai par chance au prochain
#      clone sur un poste Windows.
# La mutation ferme la vacuité de A : un fichier CRLF fabriqué DOIT être signalé.
#
#   bash ci/lint-eol.sh
set -uo pipefail
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # racine du DÉPÔT
cd "$RACINE" || exit 1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
# `mapfile` n'existe pas en bash 3.2 (défaut macOS) : la 1re version de cette
# porte mourait dessus ET rendait quand même « PORTE VERTE », parce que seules
# les mutations avaient tourné. Un vert vacant dans la porte anti-vert-vacant.
# D'où : aucun tableau, et un contrôle explicite que chaque section a MESURÉ.

# Les types INTERPRÉTÉS — la même liste que `.gitattributes`, et c'est
# volontairement une liste et non `*` : normaliser tout le dépôt obligerait à
# recenser chaque binaire sous peine de le corrompre.
git ls-files -- '*.sh' '*.bash' 'Jenkinsfile' 'Jenkinsfile.*' '*.groovy' '*.job.xml' \
  '*.yml' '*.yaml' '*.json' '*.ini' '*.cfg' '*.py' 'Makefile' '*.mk' \
  '*.go' 'go.mod' 'go.sum' '*.md' > "$TMP/fichiers" 2>/dev/null
N=$(wc -l < "$TMP/fichiers" | tr -d ' ')
if [ "${N:-0}" -lt 100 ]; then
  echo "!! seulement ${N:-0} fichiers suivis recensés — la porte ne mesure rien de crédible" >&2
  echo "PORTE ROUGE : recensement invraisemblable"; exit 2
fi

echo "═══ A. l'état : aucun CR dans les fichiers interprétés suivis ═══"
# `grep -Il` : -I saute les binaires, -l ne rend que les noms.
tr '\n' '\0' < "$TMP/fichiers" | xargs -0 grep -Il "$(printf '\r')" > "$TMP/coupables" 2>/dev/null
NC=$(wc -l < "$TMP/coupables" | tr -d ' ')
if [ "${NC:-0}" -eq 0 ]; then
  ok "A.1 $N fichiers suivis, aucun CR"
else
  ko "A.1 $NC fichier(s) en CRLF :"
  sed 's/^/        /' "$TMP/coupables" | head -10
fi

echo "═══ B. le mécanisme : chaque fichier est ÉPINGLÉ en eol=lf ═══"
# Mesuré par `git check-attr`, donc par git lui-même : relire `.gitattributes`
# prouverait qu'on sait le lire, pas que git l'applique à ces chemins-là.
tr '\n' '\0' < "$TMP/fichiers" | xargs -0 git check-attr eol -- 2>/dev/null > "$TMP/attrs"
NA=$(wc -l < "$TMP/attrs" | tr -d ' ')
if [ "${NA:-0}" -ne "$N" ]; then
  ko "B.0 check-attr a rendu $NA lignes pour $N fichiers — mesure incomplète, verdict refusé"
else
  grep -v ': eol: lf$' "$TMP/attrs" | cut -d: -f1 | sort -u > "$TMP/non_epingles"
  NE=$(wc -l < "$TMP/non_epingles" | tr -d ' ')
  if [ "${NE:-0}" -eq 0 ]; then
    ok "B.1 les $N fichiers résolvent tous eol=lf (git check-attr)"
  else
    ko "B.1 $NE fichier(s) sans règle eol=lf — leur checkout dépend du poste :"
    sed 's/^/        /' "$TMP/non_epingles" | head -10
  fi
fi

echo "═══ M. mutation : la porte attrape bien un CRLF ═══"
printf '#!/usr/bin/env bash\r\necho bonjour\r\n' > "$TMP/mutant.sh"
if grep -Il "$(printf '\r')" "$TMP/mutant.sh" >/dev/null 2>&1; then
  ok "M1 un fichier CRLF fabriqué EST signalé — A.1 n'est pas verte par vacuité"
else
  ko "M1 le prédicat ne voit pas un CRLF évident : A.1 ne prouve rien"
fi
printf '#!/usr/bin/env bash\necho bonjour\n' > "$TMP/temoin.sh"
if grep -Il "$(printf '\r')" "$TMP/temoin.sh" >/dev/null 2>&1; then
  ko "M2 un fichier LF est signalé à tort — la porte rendrait tout le dépôt rouge"
else
  ok "M2 un fichier LF n'est PAS signalé (le prédicat discrimine)"
fi

# Le compte ATTENDU : 4 assertions, pas « celles qui ont bien voulu tourner ».
ATTENDU=4
TOTAL=$((PASS + FAIL))
if [ "$TOTAL" -ne "$ATTENDU" ]; then
  printf '  ❌ %d assertions jouées, %d attendues — une section a été sautée\n' "$TOTAL" "$ATTENDU"
  FAIL=$((FAIL + 1))
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PORTE VERTE : fins de ligne LF épinglées (%d/%d)\n' "$PASS" "$ATTENDU"
else
  printf 'PORTE ROUGE : %d/%d\n' "$PASS" "$TOTAL"
  printf '  Remède : ajouter le type à .gitattributes (eol=lf), puis\n'
  printf '           git add --renormalize . && git commit\n'
fi
[ "$FAIL" -eq 0 ]
