#!/usr/bin/env bash
# ci/lint-forge-literals.sh — UNE SEULE AUTORITÉ POUR PARLER À LA FORGE.
#
# CE QU'ELLE INTERDIT (mesuré le 2026-09-09, CI client sur GitLab). La chaîne
# parlait l'API de Gitea en dur : 26 compositions de « /api/v1 » dans 14
# fichiers, 16 en-têtes « Authorization: token », 15 json.load sur des réponses
# de forge. Sur GitLab, tout mourait au premier appel. L'autorité est désormais
# scripts/lib/forge-api.py (+ .sh) : visage, base d'API, en-tête, garde.
#
# LA RÈGLE, et pourquoi elle est formulée ainsi : INTERDIRE le littéral, jamais
# l'EXIGER. Une porte écrite dans le vocabulaire de ce qu'elle garde finit par
# garantir ce vocabulaire au lieu de la propriété (trois cas le 2026-09-09).
# Ici la porte ne sait rien de la bonne forme ; elle sait seulement qu'un
# littéral de Gitea hors des deux libs est une seconde autorité — et c'est tout.
#
# PORTÉE : les fichiers ROUTÉS (phase 1, chaîne app-request). La liste s'ÉTEND
# à chaque routage (phase 2 : chaîne producteur) ; elle ne se réduit jamais.
# Un fichier hors liste n'est pas contrôlé — dette nommée, pas silence.
#
#   bash ci/lint-forge-literals.sh
set -uo pipefail
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RACINE" || exit 1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# Les deux seuls fichiers qui ont le DROIT d'écrire ces littéraux.
AUTORITES='scripts/lib/forge-api.py scripts/lib/forge-api.sh scripts/lib/forge-identity.sh'
# Les fichiers routés — la liste qui ne fait que grandir.
ROUTES='scripts/provision-request.sh
scripts/lib/gitea-pr-confirm.sh
scripts/lib/gitea-pr-comment.sh
scripts/provision-apply-reconcile.sh
scripts/app-rollback-request.sh
scripts/provision-plan.sh
scripts/provision-plan-status.sh'

echo "═══ A. aucun littéral de forge hors des autorités, dans les fichiers routés ═══"
# On retire les commentaires AVANT de chercher : ce dépôt commente ses
# correctifs en citant le motif interdit — une assertion satisfaite par la
# prose d'un commentaire est un vert vacant (piège mesuré sur test-deploy-pin.sh).
n=0
for f in $ROUTES; do
  [ -f "$f" ] || { ko "A.0 $f absent de l'arbre — la liste ROUTES est fausse"; continue; }
  code="$(sed 's/[[:space:]]*#.*$//' "$f")"
  for motif in '/api/v1' 'api/v4' 'Authorization: token' '"token "' 'PRIVATE-TOKEN' 'json.load(' 'urllib.request.urlopen' 'urlopen('; do
    if printf '%s\n' "$code" | grep -qF -- "$motif"; then
      ko "A.$f porte encore « $motif » — une seconde autorité sur la forge"; n=$((n+1))
    fi
  done
done
[ "$n" -eq 0 ] && ok "A.1 $(printf '%s\n' "$ROUTES" | wc -l | tr -d ' ') fichiers routés : aucun /api/v1, /api/v4, en-tête d'auth, json.load ni urlopen"

echo "═══ B. les autorités, elles, portent bien le vocabulaire (sinon la porte A est vacante) ═══"
# shellcheck disable=SC2086
if grep -lF '/api/v1' $AUTORITES >/dev/null 2>&1 && grep -lF 'api/v4' scripts/lib/forge-api.py >/dev/null 2>&1; then
  ok "B.1 forge-api.py connaît /api/v1 ET /api/v4 — les littéraux ont un seul foyer"
else ko "B.1 les autorités ne portent pas le vocabulaire : la porte A ne prouverait rien"; fi

echo "═══ M. mutation : la porte attrape bien un littéral réintroduit ═══"
MT="$(mktemp -d)"; trap 'rm -rf "$MT"' EXIT
# shellcheck disable=SC2016  # le mutant DOIT porter ${GIT_HOST} littéral : c'est le motif interdit
printf '#!/usr/bin/env bash\nAPI="${GIT_HOST}/api/v1"\ncurl -H "Authorization: token $T" "$API/user"\n' > "$MT/mutant.sh"
code="$(sed 's/[[:space:]]*#.*$//' "$MT/mutant.sh")"
if printf '%s\n' "$code" | grep -qF -- '/api/v1' && printf '%s\n' "$code" | grep -qF -- 'Authorization: token'; then
  ok "M1 un script qui recompose /api/v1 et l'en-tête de Gitea EST signalé"
else ko "M1 le prédicat ne voit pas un littéral évident"; fi
# shellcheck disable=SC2016  # idem, en commentaire
printf '#!/usr/bin/env bash\n# ancien : API="${GIT_HOST}/api/v1" (retiré le 2026-09-09)\nforge whoami\n' > "$MT/temoin.sh"
code="$(sed 's/[[:space:]]*#.*$//' "$MT/temoin.sh")"
if printf '%s\n' "$code" | grep -qF -- '/api/v1'; then
  ko "M2 un littéral qui ne vit qu'en COMMENTAIRE est signalé à tort (la porte rougirait sur sa propre prose)"
else ok "M2 un littéral en commentaire n'est PAS signalé — la porte lit le code, pas la prose"; fi

ATTENDU=4; TOTAL=$((PASS + FAIL))
[ "$TOTAL" -ge "$ATTENDU" ] || { printf '  ❌ %d assertions jouées, au moins %d attendues\n' "$TOTAL" "$ATTENDU"; FAIL=$((FAIL+1)); }
echo
if [ "$FAIL" -eq 0 ]; then printf 'PORTE VERTE : une seule autorité de forge (%d/%d)\n' "$PASS" "$TOTAL"
else printf 'PORTE ROUGE : %d/%d\n' "$PASS" "$TOTAL"; fi
[ "$FAIL" -eq 0 ]
