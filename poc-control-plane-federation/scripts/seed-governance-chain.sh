#!/usr/bin/env bash
# seed-governance-chain.sh — pose la chaîne de promotion dans le dépôt
# GOVERNANCE du lab, depuis le gabarit livrable (jalon G1).
#
#   clients/_example/environments.yaml  ──▶  ci/governance:main/environments.yaml
#
# UNE SEULE SOURCE. Le gabarit est ce qui part chez le client (couche CONFIG
# CLIENT, DELIVERY-PROCESS.md §3) ; le dépôt governance du lab en est une
# INSTANCE. Les faire diverger à la main, c'est se garantir que la chaîne
# prouvée par scripts/test-env-chain.sh n'est pas celle que le CI exécute.
#
# ⚠ ORDRE IMPOSÉ (et c'est pour ça que ce script existe avant toute
# dérivation) : le fichier doit atterrir dans governance AVANT que quoi que ce
# soit n'en dérive sa liste d'environnements. Sinon la dérivation retombe sur
# la chaîne PAR DÉFAUT `dev → staging → production` (store.go:24) et casse la
# chaîne qui tourne.
#
# ⚠ PRÉREQUIS FONCTIONNEL : la porte `homol` et la porte `prod` nomment le
# groupe Keycloak `release-team`. Tant que scripts/setup-release-team.sh n'a
# pas tourné, ces deux sauts sont INAPPROUVABLES — fail-closed, donc sans
# danger, mais bloquant. Lancer les deux scripts dans cet ordre :
#     bash scripts/setup-release-team.sh
#     bash scripts/seed-governance-chain.sh
#
# Usage :
#   GITEA_TOKEN=<token write:repository> bash scripts/seed-governance-chain.sh
#
# Frapper un token si besoin (le lab n'en garde pas : Vault est en dev-mode,
# donc en MÉMOIRE — il perd ses secrets à chaque redémarrage) :
#   docker exec -u git poc-gitea gitea admin user generate-access-token \
#     --username ci --token-name seed-chain --scopes write:repository
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/clients/_example/environments.yaml"
GIT_HOST="${GIT_HOST:-http://localhost:13000}"
GIT_REPO="${GIT_REPO:-ci/governance}"
# ⚠ PAS d'apostrophe dans ce message : bash lit le corps de ${VAR:?...} comme
# du texte à quoter, et une apostrophe française y ouvre une chaîne qui ne se
# ferme jamais — le script entier devient un « unexpected EOF » signalé à la
# DERNIÈRE ligne, très loin de la vraie faute (mesuré ici même le 2026-08-26).
GITEA_TOKEN="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis (write:repository) — voir l en-tete de ce script}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

[ -f "$SRC" ] || { echo "gabarit absent : $SRC"; exit 1; }

echo "① le gabarit est conforme AVANT de le pousser"
if bash "$ROOT/scripts/test-env-chain.sh" >/dev/null 2>&1; then
  ok "test-env-chain.sh vert — on ne pousse jamais une chaîne non prouvée"
else
  bad "test-env-chain.sh ROUGE — refus de pousser"; printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"; exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Le token ne touche NI l'URL (il finirait dans .git/config et dans les logs),
# NI argv (visible en `ps`) : il passe par un header, comme dans team-apply.sh.
AUTH="Authorization: token $GITEA_TOKEN"

echo "② clone de $GIT_REPO"
if git -c http.extraHeader="$AUTH" clone -q "$GIT_HOST/$GIT_REPO.git" "$TMP/gov" 2>"$TMP/err"; then
  ok "cloné"
else
  bad "clone KO : $(head -2 "$TMP/err")"; printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"; exit 1
fi

echo "③ application du gabarit"
cp "$SRC" "$TMP/gov/environments.yaml"
cd "$TMP/gov" || exit 1
if git diff --quiet; then
  ok "déjà à jour — rien à pousser (idempotent)"
else
  git add environments.yaml
  git -c user.name="stoa-ci" -c user.email="ci@bc.example" \
      commit -q -m "gov(chain): chaine de promotion depuis clients/_example/environments.yaml

Source unique : le gabarit livrable du depot plateforme. Pose par
scripts/seed-governance-chain.sh, gate = scripts/test-env-chain.sh."
  if git -c http.extraHeader="$AUTH" push -q origin HEAD:main 2>"$TMP/perr"; then
    ok "poussé sur main"
  else
    bad "push KO : $(head -2 "$TMP/perr")"; printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"; exit 1
  fi
fi

# READ-BACK depuis Gitea, pas depuis le clone local : on vérifie ce que le CI
# LIRA, pas ce qu'on croit avoir écrit.
echo "④ read-back depuis Gitea (ce que le CI lira sur main)"
RAW=$(curl -s -H "$AUTH" "$GIT_HOST/$GIT_REPO/raw/branch/main/environments.yaml")
GOT=$(printf '%s' "$RAW" | python3 -c "import sys,yaml
d=yaml.safe_load(sys.stdin) or {}
print(','.join(d.get('environments') or []))" 2>/dev/null)
WANT=$(python3 -c "import yaml
print(','.join(yaml.safe_load(open('$SRC'))['environments']))")
[ "$GOT" = "$WANT" ] && ok "chaîne sur main = $GOT" \
                     || bad "chaîne sur main = '${GOT:-<illisible>}', attendu '$WANT'"

# Les portes aussi : une chaîne au bon nombre de paliers dont les portes sont
# tombées serait le pire des verts.
for E in homol prod; do
  G=$(printf '%s' "$RAW" | python3 -c "import sys,yaml
d=yaml.safe_load(sys.stdin) or {}
print(next((g.get('approverGroup','') for g in (d.get('gates') or []) if g.get('to')=='$E'), ''))" 2>/dev/null)
  [ -n "$G" ] && ok "porte $E : approverGroup=$G" || bad "porte $E : approverGroup ABSENT sur main"
done

# L'AUTRE axe de la porte (G2/ADR-084) : `deployerGroup` dit QUI PORTE l'apply,
# et il se lit dans l'ANNUAIRE LDAP → policy Vault, jamais dans la claim
# Keycloak de `approverGroup`. Il se relit ici pour exactement la même raison
# que l'approbateur : une chaîne au bon nombre de paliers dont l'axe déployeur
# serait tombé passerait pour verte alors que plus personne n'est nommé pour
# déployer — et le refus, lui, n'arriverait qu'au dispatch.
#
# ⚠ LES VALEURS ATTENDUES SONT ÉCRITES ICI, EN DUR, ET C'EST LE POINT. Les
# comparer au gabarit local (comme la chaîne juste au-dessus) resterait VERT si
# quelqu'un retirait `deployerGroup` du gabarit : c'est LUI qu'on pousse, les
# deux côtés bougeraient ensemble. Une attente indépendante de la source est la
# seule qui survive à une régression de la source.
for PAIR in int:apim-apply-int homol:apim-apply-homol prod:apim-operator-prod; do
  E="${PAIR%%:*}"; WANT_D="${PAIR#*:}"
  D=$(printf '%s' "$RAW" | python3 -c "import sys,yaml
d=yaml.safe_load(sys.stdin) or {}
print(next((g.get('deployerGroup','') or '' for g in (d.get('gates') or []) if g.get('to')=='$E'), ''))" 2>/dev/null)
  [ "$D" = "$WANT_D" ] && ok "porte $E : deployerGroup=$D" \
                       || bad "porte $E : deployerGroup='${D:-<absent>}' sur main, attendu '$WANT_D'"
done

printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
