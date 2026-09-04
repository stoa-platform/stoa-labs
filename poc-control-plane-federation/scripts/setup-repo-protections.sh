#!/usr/bin/env bash
# setup-repo-protections.sh — G4 (ADR-082, M2/M3) : pose les protections de
# branche sur les dépôts que le PIPELINE LIT — la définition de pipeline et la
# référence de déploiement sortent du périmètre d'écriture du demandeur.
#   - ci/stoa-labs@main   (plateforme : Jenkinsfiles, scripts/, ansible/)
#   - ci/governance@main  (chaîne d'environnements : environments.yaml)
#   - chaque dépôt d'équipe DÉCLARÉ dans UN SEUL fichier providers — celui de
#     $PROVIDERS_FILE, par défaut ansible/providers.dev.yml — champ `repo` non
#     vide. Ce script ne balaie PAS tous les paliers : un `repo` d'équipe est
#     le même quel que soit l'env, la chaîne d'envs est une affaire de branches.
#
# Baseline : push whitelist = ${PROTECT_PUSH_WHITELIST:-ci} ; tout le reste
# passe par PR. PROTECT_FILE_PATTERNS (optionnel) n'est posé QUE si l'exploitant
# le fournit.
#
# VERDICTS DE MESURE — test-repo-protections-live.sh, Gitea 1.22.6, 2026-08-27 :
#   (a) protected_file_patterns est un gate de CONTENU, indépendant du rôle :
#       il rejette le push direct du fichier couvert pour TOUT pousseur
#       (whitelisté ET admin de site) et bloque le MERGE d'une PR qui le touche
#       (HTTP 405 « Changed protected files »), admin compris. Un push d'un
#       fichier NON couvert par un pousseur whitelisté passe. ⇒ une fois posé,
#       PROTECT_FILE_PATTERNS est une garantie RÉELLE, pas décorative.
#   (b) le PATCH branch_protection 1.22 FUSIONNE : un champ ABSENT du corps est
#       PRÉSERVÉ. Re-passer cette baseline (sans patterns) sur un dépôt porteur
#       d'options posées à la main NE LES EFFACE PAS ⇒ re-passage NON destructif.
#       Corollaire : pour EFFACER un champ, il faut l'envoyer explicitement vide.
#   (c) l'admin de site N'EST PAS exempté du push_whitelist : non whitelisté, il
#       est rejeté (« Not allowed to push to protected branch »). ⇒ le défaut
#       PROTECT_PUSH_WHITELIST=ci DOIT rester aligné sur GITEA_ADMIN_USER : c'est
#       ce qui laisse le chemin de réparation de team-apply pousser. PORTANT.
#
#   bash scripts/setup-repo-protections.sh --print   # hors ligne : ce qui SERAIT posé
#   FORGE_SECRET=… bash scripts/setup-repo-protections.sh
#
# ÉCART AU BRIEF (ajout justifié) : `--print`/`--help`. Sans eux, ce script
# n'avait AUCUN chemin exécutable sans token ni réseau, et sa seule logique
# propre — la DÉRIVATION de la liste des dépôts depuis providers — restait
# entièrement non prouvée par la porte hors-ligne. `--print` l'émet sans rien
# poser ; la sémantique LIVE de la protection reste la Task 9.
set -euo pipefail
# shellcheck source=scripts/lib/forge-identity.sh
. scripts/lib/forge-identity.sh || { echo "ERREUR: scripts/lib/forge-identity.sh introuvable ou illisible" >&2; exit 1; }
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/repo-protection.sh
. "scripts/lib/repo-protection.sh"

usage() {
  # REVUE round 1 (Minor 6) : plage ANCRÉE, plus `sed -n '2,18p'`. Le numéro
  # figé coupait en pleine phrase et aurait dérivé à la première ligne ajoutée
  # à l'en-tête. Ici on imprime le bloc de commentaire de tête ENTIER : de la
  # ligne 2 jusqu'à la première ligne qui n'est pas un commentaire (`set -e…`).
  awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print; next } exit }' "$0"
}

MODE=pose
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --print)   MODE=print ;;
  "")        ;;
  *)         echo "argument inconnu : $1" >&2; usage >&2; exit 2 ;;
esac

GIT_HOST="${GIT_HOST:-http://localhost:13000}"
WL="${PROTECT_PUSH_WHITELIST:-ci}"
PATTERNS="${PROTECT_FILE_PATTERNS:-}"
BRANCH="${PROTECT_BRANCH:-main}"
PROVIDERS_FILE="${PROVIDERS_FILE:-ansible/providers.dev.yml}"

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT INT TERM; umask 077

# Dépôts de PLATEFORME : codés ici et pas dérivés, parce que ce sont eux qui
# PORTENT la dérivation — les lire depuis un fichier qu'ils protègent serait
# circulaire.
REPOS="${PROTECT_PLATFORM_REPOS:-ci/stoa-labs ci/governance}"
# Dépôts d'ÉQUIPE : dérivés de providers, jamais recopiés. Un `repo` vide
# (payments-team : inconnu, cf. le commentaire du fichier) est ÉCARTÉ — pas
# transformé en cible vide qui viserait `…/repos//branch_protections`.
[ -f "$PROVIDERS_FILE" ] \
  || { echo "PROVIDERS_INTROUVABLE : $PROVIDERS_FILE" >&2; exit 1; }
TEAM_REPOS="$(python3 - "$PROVIDERS_FILE" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for p in d.get("providers", []) or []:
    r = (p.get("repo") or "").strip()
    if r:
        print(r)
PY
)" || { echo "PROVIDERS_ILLISIBLE : $PROVIDERS_FILE (yaml.safe_load en échec)" >&2; exit 1; }

repo_protection_payload "$BRANCH" "$WL" "$PATTERNS" > "$TMPD/payload.json" \
  || { echo "PAYLOAD_NON_FORME : whitelist='$WL' branche='$BRANCH'" >&2; exit 1; }

if [ "$MODE" = print ]; then
  # Format volontairement plat et grep-able (motif de setup-vault-paliers.sh
  # --print) : la porte hors-ligne assied ses assertions dessus.
  echo "MODE=print"
  echo "HOST=$GIT_HOST"
  echo "BRANCH=$BRANCH"
  echo "PAYLOAD=$(cat "$TMPD/payload.json")"
  for repo in $REPOS $TEAM_REPOS; do echo "REPO=$repo"; done
  exit 0
fi

FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
FORGE_SECRET="${GITEA_TOKEN:?FORGE_SECRET requis (write:repository sur les dépôts visés) — ou --print pour voir ce qui serait posé}"
forge_auth_write "$FORGE_SECRET" "$TMPD/hdr" || exit 2

RC=0
for repo in $REPOS $TEAM_REPOS; do
  if pose_branch_protection "$GIT_HOST" "$TMPD/hdr" "$repo" "$TMPD/payload.json"; then
    echo "  ✅ $repo@$BRANCH protégé (push whitelist: $WL${PATTERNS:+ ; patterns: $PATTERNS})"
  else
    echo "  ❌ $repo@$BRANCH NON protégé (voir PROTECTION_NON_POSEE ci-dessus)"; RC=1
  fi
done
exit "$RC"
