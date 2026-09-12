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
# Seconde autorité, ÉTROITE et NOMMÉE : le transport binaire des paquets
# (l'adaptateur python ne parle que JSON). Elle a le droit à /api/packages et à
# l'en-tête écrit par forge_auth_write — et à rien d'autre.
AUTORITE_PAQUETS='scripts/lib/archive-store.sh'
# Les fichiers routés — la liste qui ne fait que grandir.
ROUTES='scripts/provision-request.sh
scripts/lib/gitea-pr-confirm.sh
scripts/lib/gitea-pr-comment.sh
scripts/provision-apply-reconcile.sh
scripts/app-rollback-request.sh
scripts/provision-plan.sh
scripts/provision-plan-status.sh
scripts/team-request.sh
scripts/api-request.sh
scripts/api-promote-request.sh
scripts/api-promote-export.sh
scripts/team-apply.sh
scripts/team-publish.sh
scripts/team-promote.sh'
# Phase 2 (2026-09-12) : les fichiers de la chaîne producteur EN COURS de routage.
# Rapportés (« dette »), jamais rouges : chaque tâche du plan L5 phase 2 retire
# son fichier d'ici et l'ajoute à ROUTES — la liste doit être VIDE à la fin.
# Task 9 (2026-09-12) : team-publish.sh et team-promote.sh routés (pr_get par
# l'autorité) — la liste est désormais VIDE, la phase 2 est close.
EN_ROUTAGE=''
# Exemptés NOMMÉMENT, avec la raison — un outil hors chaîne n'est pas une seconde
# autorité de la chaîne, mais on le dit plutôt que de le taire.
EXEMPTS='scripts/lib/repo-protection.sh|outil d exploitant Gitea seul (protection nominative, ADR-082 §3) — hors chaîne depuis D10
scripts/setup-repo-protections.sh|outil d exploitant Gitea seul — refuse PROTECTION_GITEA_SEULEMENT sur un autre visage
scripts/seed-governance-chain.sh|outil de lab (lint-branch-literals l exempte déjà)
scripts/setup-team-repos.sh|outil de poste du lab : pré-crée les dépôts d équipe que la chaîne ne crée plus (D10)
scripts/setup-gitlab-lab.sh|outil de lab : monte la forge GitLab elle-même'
MOTIFS='/api/v1
api/v4
Authorization: token
"token "
PRIVATE-TOKEN
urllib.request.urlopen
urlopen(
/api/packages
/pulls/
/src/commit/'

motifs_dans(){ # <fichier> → les motifs présents dans le CODE (commentaires retirés), un par ligne
  local f="$1" code m
  code="$(sed 's/[[:space:]]*#.*$//' "$f")"
  while IFS= read -r m; do printf '%s\n' "$code" | grep -qF -- "$m" && printf '%s\n' "$m"; done <<< "$MOTIFS"
  # json.load( n'est un motif de FORGE que sur une ligne qui parle à la forge (GIT_HOST,
  # FORGE_, urlopen, api/v) — pas une lecture de Vault, d'ITSM ou d'un payload local.
  printf '%s\n' "$code" | grep -F 'json.load(' | grep -qE 'GIT_HOST|FORGE_|urlopen|api/v' && printf '%s\n' 'json.load( (sur une ligne de forge)'
  return 0
}

echo "═══ A. aucun littéral de forge hors des autorités, dans les fichiers routés ═══"
# On retire les commentaires AVANT de chercher : ce dépôt commente ses
# correctifs en citant le motif interdit — une assertion satisfaite par la
# prose d'un commentaire est un vert vacant (piège mesuré sur test-deploy-pin.sh).
n=0
for f in $ROUTES; do
  [ -f "$f" ] || { ko "A.0 $f absent de l'arbre — la liste ROUTES est fausse"; continue; }
  while IFS= read -r m; do [ -n "$m" ] && { ko "A.$f porte encore « $m » — une seconde autorité sur la forge"; n=$((n+1)); }; done <<< "$(motifs_dans "$f")"
done
[ "$n" -eq 0 ] && ok "A.1 $(printf '%s\n' "$ROUTES" | wc -l | tr -d ' ') fichiers routés : aucun littéral de forge (API, en-tête, urlopen, paquets, liens Gitea)"
# archive-store : /api/packages et l'en-tête délégué lui sont permis ; le reste, non.
for f in $AUTORITE_PAQUETS; do
  [ -f "$f" ] || { ko "A.2 $f absent de l'arbre — la seconde autorité des paquets a disparu (liste AUTORITE_PAQUETS fausse)"; continue; }
  reste="$(motifs_dans "$f" | grep -vE '^/api/packages$' || true)"
  if [ -z "$reste" ]; then ok "A.2 $f (seconde autorité, paquets) ne porte que /api/packages"
  else ko "A.2 $f porte : $(printf '%s' "$reste" | tr '\n' ' ')"; fi
done

echo "═══ B. les autorités, elles, portent bien le vocabulaire (sinon la porte A est vacante) ═══"
# shellcheck disable=SC2086
if grep -lF '/api/v1' $AUTORITES >/dev/null 2>&1 && grep -lF 'api/v4' scripts/lib/forge-api.py >/dev/null 2>&1; then
  ok "B.1 forge-api.py connaît /api/v1 ET /api/v4 — les littéraux ont un seul foyer"
else ko "B.1 les autorités ne portent pas le vocabulaire : la porte A ne prouverait rien"; fi

echo "═══ D. la dette de phase 2 est NOMMÉE, jamais tue ═══"
for f in $EN_ROUTAGE; do
  [ -f "$f" ] || { ko "D.0 $f absent — la liste EN_ROUTAGE est fausse"; continue; }
  mm="$(motifs_dans "$f" | tr '\n' ' ')"
  printf '  ⚠ en routage : %s — motifs : %s\n' "$f" "${mm:-aucun (à passer dans ROUTES)}"
done
if [ -n "$EN_ROUTAGE" ]; then ok "D.1 $(printf '%s\n' "$EN_ROUTAGE" | wc -l | tr -d ' ') fichier(s) en routage, rapportés (la liste doit être VIDE à la fin de L5 phase 2)"
else ok "D.1 aucun fichier en routage : la phase 2 est close"; fi
while IFS='|' read -r f raison; do
  [ -n "$f" ] || continue
  printf '  ℹ exempté : %s — %s\n' "$f" "$raison"
done <<< "$EXEMPTS"
ok "D.2 $(printf '%s\n' "$EXEMPTS" | grep -c '|') fichiers exemptés avec leur raison (outils hors chaîne)"

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
# shellcheck disable=SC2016  # le mutant DOIT porter ${GIT_HOST} littéral : c'est le motif des paquets
printf '#!/usr/bin/env bash\nurl="${GIT_HOST}/api/packages/ci/generic/x/1/a.zip"\n' > "$MT/paquets.sh"
if [ -n "$(motifs_dans "$MT/paquets.sh")" ]; then ok "M3 /api/packages hors d'archive-store EST signalé"
else ko "M3 le motif des paquets n'est pas vu"; fi
# shellcheck disable=SC2016  # le mutant DOIT porter ${GIT_WEB_HOST}/${GIT_REPO} littéraux : c'est le lien composé
printf '#!/usr/bin/env bash\necho "${GIT_WEB_HOST}/${GIT_REPO}/pulls/${N}"\n' > "$MT/lien.sh"
if [ -n "$(motifs_dans "$MT/lien.sh")" ]; then ok "M4 un lien composé à la forme Gitea (/pulls/) EST signalé"
else ko "M4 le lien Gitea n'est pas vu"; fi
# shellcheck disable=SC2016  # littéral voulu : un json.load hors ligne de forge, jamais signalé
printf '#!/usr/bin/env bash\nd=$(python3 -c "import json;print(json.load(open(\\"vault.json\\")))")\n' > "$MT/vault.sh"
if [ -z "$(motifs_dans "$MT/vault.sh")" ]; then ok "M5 un json.load qui ne parle pas à la forge n'est PAS signalé (Vault, ITSM, payload local)"
else ko "M5 faux positif json.load"; fi

ATTENDU=10; TOTAL=$((PASS + FAIL))
[ "$TOTAL" -ge "$ATTENDU" ] || { printf '  ❌ %d assertions jouées, au moins %d attendues\n' "$TOTAL" "$ATTENDU"; FAIL=$((FAIL+1)); }
echo
if [ "$FAIL" -eq 0 ]; then printf 'PORTE VERTE : une seule autorité de forge (%d/%d)\n' "$PASS" "$TOTAL"
else printf 'PORTE ROUGE : %d/%d\n' "$PASS" "$TOTAL"; fi
[ "$FAIL" -eq 0 ]
