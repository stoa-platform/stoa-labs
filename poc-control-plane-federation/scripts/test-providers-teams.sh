#!/usr/bin/env bash
# test-providers-teams.sh — L'APPARTENANCE D'ÉQUIPE SE LIT EN YAML, PAS EN TEXTE.
#
# CE QU'ELLE EMPÊCHE (mesuré le 2026-09-09, CI client `ci-app-request`).
# Le client, après avoir passé PROVIDERS_MISSING, meurt :
#   REFUS: TEAM_NOT_DECLARED : 'fbi' absent de providers.dev.yml
# sur un fichier qui DÉCLARE l'équipe. Cause : trois scripts décidaient
# l'appartenance par un grep TEXTUEL sur la forme exacte de la ligne —
#   provision-request.sh : grep -Fxq -- "  - team: ${REQ_TEAM}"
#   team-request.sh      : grep -Eq  "^  - team: ${TEAM}\$"
#   team-apply.sh        : grep -Eq  "^  - team: ${TEAM}\$"
# — c'est-à-dire : EXACTEMENT deux espaces d'indentation, valeur nue, rien
# après. Six autres scripts du MÊME dépôt lisent CE MÊME fichier par
# `yaml.safe_load` (api-request.sh, team-publish.sh, team-promote.sh,
# api-promote-request.sh, api-promote-export.sh, generate-choices.sh). Deux
# autorités sur la même question, et c'est la textuelle qui décidait.
#
# Tout ceci est du YAML VALIDE qui déclare l'équipe, et que le grep refusait :
#   indentation à 4 espaces · liste non indentée sous la clé · valeur entre
#   guillemets · commentaire en fin de ligne · espace en fin de ligne ·
#   FINS DE LIGNE CRLF (une banque édite sous Windows) · style « flow ».
#
# CE QU'ELLE DOIT AUSSI TENIR — le grep n'était pas gratuit, il fermait deux
# portes qu'une lecture YAML doit garder fermées :
#   1. la valeur de l'équipe n'est JAMAIS une expression (`.*`, `(a|b)`) ;
#      `team-apply.sh` et `team-request.sh` l'interpolaient dans une ERE.
#   2. `fb` ne doit pas matcher `fbi` (préfixe), ni `FBI` (casse).
#
# ET FAIL-CLOSED : un fichier illisible ou du YAML cassé est un REFUS NOMMÉ
# (PROVIDERS_PARSE), jamais « équipe absente » — les deux ne se soignent pas
# pareil, et les confondre a déjà coûté une journée sur ce dépôt.
#
# HORS LIGNE intégralement. Aucun réseau, aucune forge, aucun Jenkins.
#
#   bash scripts/test-providers-teams.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
LIB="$REPO/scripts/lib/providers-teams.sh"
TMP="$(mktemp -d /tmp/provteams.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

if [ -f "$LIB" ] || { echo "!! bibliothèque absente : $LIB"; echo "RÉSULTAT : 0/1"; exit 1; }
# shellcheck source=scripts/lib/providers-teams.sh
. "$LIB" || { echo "!! bibliothèque illisible : $LIB"; exit 1; }

# f <nom> <contenu> → chemin du fichier écrit
f(){ printf '%s' "$2" > "$TMP/$1.yml"; printf '%s' "$TMP/$1.yml"; }

# declare_ok <fichier> <équipe> — rc de providers_team_declared, capturé
dec(){ providers_team_declared "$1" "$2" >"$TMP/dec.out" 2>&1; echo $?; }

echo "═══ A. les formes de YAML VALIDE que le grep textuel refusait ═══"

# La forme du lab : deux espaces, valeur nue. Le témoin — si celle-ci casse,
# c'est la lecture qui est fausse, pas la tolérance.
A_LAB=$(f lab 'providers:
  - team: fbi
    repo: eq/fbi
')
[ "$(dec "$A_LAB" fbi)" = 0 ]; then
  ok "A.1 témoin : la forme du lab (2 espaces, valeur nue) est déclarée"
else ko "A.1 la forme du lab n'est plus reconnue — la lecture est fausse"; fi

A_4=$(f indent4 'providers:
    - team: fbi
      repo: eq/fbi
')
if [ "$(dec "$A_4" fbi)" = 0 ]; then
  ok "A.2 indentation à 4 espaces (YAML valide) ⇒ déclarée"
else ko "A.2 indentation à 4 espaces refusée — c'est le défaut client"; fi

A_0=$(f indent0 'providers:
- team: fbi
  repo: eq/fbi
')
if [ "$(dec "$A_0" fbi)" = 0 ]; then
  ok "A.3 liste NON indentée sous la clé (forme la plus courante hors de ce dépôt) ⇒ déclarée"
else ko "A.3 liste non indentée refusée"; fi

A_Q=$(f quoted 'providers:
  - team: "fbi"
    repo: eq/fbi
')
if [ "$(dec "$A_Q" fbi)" = 0 ]; then
  ok "A.4 valeur entre guillemets ⇒ déclarée (le YAML ne distingue pas)"
else ko "A.4 valeur entre guillemets refusée"; fi

A_C=$(f commented 'providers:
  - team: fbi   # equipe reprise du referentiel interne
    repo: eq/fbi
')
if [ "$(dec "$A_C" fbi)" = 0 ]; then
  ok "A.5 commentaire en fin de ligne ⇒ déclarée"
else ko "A.5 commentaire en fin de ligne refusé"; fi

# Espaces en fin de ligne écrits en $'…' À DESSEIN : dans une chaîne ordinaire
# ils sont invisibles, et un éditeur qui « nettoie » les rendrait identiques à
# A.1 — la fixture serait vacante sans que rien ne le dise.
A_T=$(f trailing $'providers:\n  - team: fbi   \n    repo: eq/fbi\n')
if [ "$(dec "$A_T" fbi)" = 0 ]; then
  ok "A.6 espace en fin de ligne ⇒ déclarée (invisible à la relecture humaine)"
else ko "A.6 espace en fin de ligne refusé"; fi

# CRLF : le plus probable des sept chez un client bancaire, et le plus
# invisible — `cat` et l'affichage d'une PR le montrent identique au lab.
A_CRLF=$(f crlf $'providers:\r\n  - team: fbi\r\n    repo: eq/fbi\r\n')
if [ "$(dec "$A_CRLF" fbi)" = 0 ]; then
  ok "A.7 fins de ligne CRLF ⇒ déclarée (édition sous Windows)"
else ko "A.7 CRLF refusé — le plus invisible des sept"; fi

A_F=$(f flow 'providers: [{team: fbi, repo: eq/fbi}]
')
if [ "$(dec "$A_F" fbi)" = 0 ]; then
  ok "A.8 style « flow » (JSON ⊂ YAML) ⇒ déclarée"
else ko "A.8 style flow refusé"; fi

echo "═══ B. la porte reste FERMÉE — ce que le grep tenait, la lecture le tient ═══"

B=$(f base 'providers:
  - team: fbi
    repo: eq/fbi
  - team: banking-demo
    repo: eq/bd
')
if [ "$(dec "$B" absente)" = 1 ]; then
  ok "B.1 équipe réellement absente ⇒ refus (rc 1)"
else ko "B.1 une équipe absente est passée : rc $(dec "$B" absente)"; fi

if [ "$(dec "$B" fb)" = 1 ]; then
  ok "B.2 'fb' ne matche pas 'fbi' — comparaison de VALEUR, pas de préfixe"
else ko "B.2 un préfixe a matché"; fi

if [ "$(dec "$B" FBI)" = 1 ]; then
  ok "B.3 la casse compte : 'FBI' ≠ 'fbi'"
else ko "B.3 la comparaison est devenue insensible à la casse"; fi

# ANTI-INJECTION : c'est ce que `-F` protégeait dans provision-request.sh, et
# ce que `-Eq` NE protégeait PAS dans team-request.sh / team-apply.sh — une
# équipe nommée `.*` y matchait n'importe quelle déclaration.
if [ "$(dec "$B" '.*')" = 1 ]; then
  ok "B.4 anti-injection : '.*' ne matche rien (une valeur n'est jamais une expression)"
else ko "B.4 '.*' a matché — la valeur est interprétée comme motif"; fi

if [ "$(dec "$B" '(fbi|banking-demo)')" = 1 ]; then
  ok "B.5 anti-injection : une alternance ERE ne matche rien"
else ko "B.5 une alternance a matché"; fi

B_VIDE=$(f vide 'providers: []
')
if [ "$(dec "$B_VIDE" fbi)" = 1 ]; then
  ok "B.6 liste vide ⇒ refus, pas une erreur"
else ko "B.6 liste vide mal traitée : rc $(dec "$B_VIDE" fbi)"; fi

B_NULL=$(f null 'providers:
')
if [ "$(dec "$B_NULL" fbi)" = 1 ]; then
  ok "B.7 clé providers nulle ⇒ refus, pas une erreur"
else ko "B.7 providers null mal traité : rc $(dec "$B_NULL" fbi)"; fi

# Une équipe déclarée avec la clé mais SANS valeur n'est pas une équipe : la
# confondre avec la chaîne vide ferait passer une demande sans team.
B_SANSVAL=$(f sansval 'providers:
  - team:
    repo: eq/x
')
if [ "$(dec "$B_SANSVAL" '')" = 1 ]; then
  ok "B.8 une équipe VIDE ne se déclare pas (team: sans valeur ≠ team '')"
else ko "B.8 la chaîne vide a été acceptée comme équipe"; fi

echo "═══ C. fail-closed : un fichier qu'on ne sait pas lire n'est pas « équipe absente » ═══"

C_CASSE=$(f casse 'providers:
  - team: fbi
   repo: mauvaise indentation
	tab: interdit en YAML
')
RC_C=$(dec "$C_CASSE" fbi)
if [ "$RC_C" = 2 ] && grep -q 'PROVIDERS_PARSE' "$TMP/dec.out"; then
  ok "C.1 YAML cassé ⇒ rc 2 + PROVIDERS_PARSE (jamais « équipe absente »)"
else ko "C.1 YAML cassé rendu comme rc $RC_C : $(head -1 "$TMP/dec.out")"; fi

RC_C2=$(dec "$TMP/nexiste-pas.yml" fbi)
if [ "$RC_C2" = 2 ]; then
  ok "C.2 fichier absent ⇒ rc 2 (le refus d'existence appartient à l'appelant, pas un « absent »)"
else ko "C.2 fichier absent rendu comme rc $RC_C2"; fi

C_SCALAIRE=$(f scalaire 'providers: "une chaine, pas une liste"
')
RC_C3=$(dec "$C_SCALAIRE" fbi)
if [ "$RC_C3" = 2 ] && grep -q 'PROVIDERS_PARSE' "$TMP/dec.out"; then
  ok "C.3 providers scalaire (ni liste ni null) ⇒ PROVIDERS_PARSE, pas un refus d'équipe"
else ko "C.3 providers scalaire rendu comme rc $RC_C3 : $(head -1 "$TMP/dec.out")"; fi

echo "═══ D. le refus est AUTO-DIAGNOSTIQUE : il dit ce que le fichier contient ═══"

# C'est CE point qui a coûté le second aller-retour client : « 'fbi' absent de
# providers.dev.yml » ne dit pas si le fichier lu est le fichier pensé. La
# liste des équipes réellement déclarées tranche en une lecture.
LISTE=$(providers_teams_list "$B" 2>/dev/null)
if [ "$LISTE" = "fbi
banking-demo" ]; then
  ok "D.1 providers_teams_list rend les équipes déclarées, dans l'ordre du fichier"
else ko "D.1 liste inattendue : $(printf '%s' "$LISTE" | tr '\n' ',')"; fi

if [ "$(providers_teams_list "$B_VIDE" 2>/dev/null)" = "" ] \
   && providers_teams_list "$B_VIDE" >/dev/null 2>&1; then
  ok "D.2 liste vide sur une liste vide ⇒ rc 0 et sortie vide (ce n'est pas une panne)"
else ko "D.2 une liste vide est traitée comme une panne"; fi

if ! providers_teams_list "$C_CASSE" >/dev/null 2>&1; then
  ok "D.3 la liste refuse aussi sur du YAML cassé (même fail-closed que la décision)"
else ko "D.3 la liste rend 0 sur du YAML cassé"; fi

echo "═══ E. UNE SEULE AUTORITÉ : plus aucun script ne décide par le texte ═══"

# Assertion de FORME, doublée d'une mutation plus bas. Le fond : le jour où un
# quatrième script réintroduit un grep sur `- team:`, cette porte le dit.
E_SCRIPTS="provision-request team-request team-apply"
for s in $E_SCRIPTS; do
  # On retire les commentaires : ce fichier-ci CITE les greps supprimés, et
  # une assertion satisfaite par la prose d'un commentaire est un vert vacant
  # (piège déjà mesuré sur test-deploy-pin.sh).
  sed 's/[[:space:]]*#.*$//' "$REPO/scripts/$s.sh" > "$TMP/code-$s.sh"
  if grep -qE 'grep [^|]*- team:' "$TMP/code-$s.sh"; then
    ko "E.$s décide encore l'appartenance par un grep textuel"
  elif grep -q 'providers_team_declared\|providers_teams_list' "$TMP/code-$s.sh"; then
    ok "E.$s délègue à la lecture YAML (providers-teams.sh), plus au texte"
  else ko "E.$s ne consulte plus l'appartenance du tout — régression"; fi
done

echo "═══ M. mutations : chaque assertion attrape bien ce qu'elle prétend attraper ═══"

# M1 — une lecture qui compare la ligne ENTIÈRE (le défaut d'origine) doit
# faire rougir A.2..A.8 sans toucher A.1. On le prouve en rejouant la décision
# par le grep supprimé, sur les mêmes fixtures.
grep_decide(){ grep -Fxq -- "  - team: $2" "$1"; }
MUT_ROUGE=0; MUT_VERT=0
for fic in "$A_4" "$A_0" "$A_Q" "$A_C" "$A_T" "$A_CRLF" "$A_F"; do
  grep_decide "$fic" fbi && MUT_VERT=$((MUT_VERT+1)) || MUT_ROUGE=$((MUT_ROUGE+1))
done
if [ "$MUT_ROUGE" = 7 ] && grep_decide "$A_LAB" fbi; then
  ok "M1 le grep supprimé refuse les 7 formes valides et n'accepte que celle du lab — le défaut est bien celui-là"
else ko "M1 le grep supprimé accepte $MUT_VERT/7 formes : la section A ne prouve pas ce qu'elle dit"; fi

# M2 — une lecture qui matcherait par SOUS-CHAÎNE (le raccourci tentant :
# `grep -q "team: $T"`) passerait B.2. On le vérifie sur la fixture de B.
if grep -q "team: fb" "$B"; then
  ok "M2 la sous-chaîne 'fb' EST présente dans le fichier — B.2 sépare donc bien valeur et sous-chaîne"
else ko "M2 fixture inadéquate : B.2 serait vraie même d'une lecture par sous-chaîne"; fi

# M3 — la casse : `FBI` ne doit pas non plus apparaître, sinon B.3 est vacante.
if ! grep -qi "team: FBI\$" "$B" || grep -q "team: fbi" "$B"; then
  ok "M3 B.3 porte bien sur la comparaison, pas sur l'absence du texte"
else ko "M3 B.3 vacante"; fi

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
