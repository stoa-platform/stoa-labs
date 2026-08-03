#!/usr/bin/env bash
# provision-apply-comment.sh — remonter le RÉSULTAT DE L'APPLY sur la PR
# (ADR-081, corollaire 2).
#
# POURQUOI. Le plan commente déjà la PR ; l'apply, lui, ne laissait aucune trace
# ailleurs que dans un log de build. Le demandeur devait aller la chercher dans
# un troisième endroit, et l'auditeur ne trouvait dans la PR que la moitié de
# l'histoire : ce qui allait être fait, jamais ce qui a été fait.
#
# En commentant ici, la PR devient le TABLEAU DE BORD de la demande — le plan, la
# décision (le merge) et le résultat au même endroit, pour le demandeur, le
# valideur et l'auditeur. C'est ce qui traite le besoin d'ergonomie SANS déplacer
# la décision hors de Git (ADR-081).
#
# CE SCRIPT NE DÉCIDE RIEN et ne doit JAMAIS faire échouer un apply réussi : il
# rapporte. L'appelant l'invoque en fin de build, succès comme échec, et ignore
# son code retour (cf. le job) — un commentaire qui ne part pas ne doit pas
# transformer un apply vert en build rouge.
#
# Entrées (env) :
#   PR_NUMBER    (req) numéro de la PR fusionnée
#   APPLY_RESULT (req) SUCCESS | FAILURE | ABORTED — résultat du build aval
#   APP_NAME     (req) application appliquée
#   ENV_NAME     (req) environnement cible
#   VALIDATOR    (req) identité NOMINATIVE qui a validé et appliqué
#   BUILD_URL    (opt) lien du build (Jenkins le fournit)
#   GIT_REPO / GITEA_TOKEN / GIT_HOST — cf. lib/gitea-pr-comment.sh
set -uo pipefail
set +x

PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
APPLY_RESULT="${APPLY_RESULT:?APPLY_RESULT requis}"
APP_NAME="${APP_NAME:?APP_NAME requis}"
ENV_NAME="${ENV_NAME:?ENV_NAME requis}"
VALIDATOR="${VALIDATOR:?VALIDATOR requis}"
BUILD_URL="${BUILD_URL:-}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/applycmt.XXXXXX)"; trap 'rm -rf "$WORK"' EXIT

APPLY_RESULT="$APPLY_RESULT" APP_NAME="$APP_NAME" ENV_NAME="$ENV_NAME" \
VALIDATOR="$VALIDATOR" BUILD_URL="$BUILD_URL" BODY_OUT="$WORK/comment.md" python3 - <<'PY'
import os
res = os.environ["APPLY_RESULT"].upper()
head = {
    "SUCCESS": "✅ **Apply nominatif RÉUSSI**",
    "FAILURE": "❌ **Apply nominatif EN ÉCHEC**",
    "ABORTED": "⚠️ **Apply INTERROMPU**",
}.get(res, f"⚠️ **Apply — résultat `{res}`**")
# L'identité est NOMINATIVE et c'est le point : elle relie l'acte à un humain,
# pas au compte de service du CI. C'est ce que l'auditeur vient chercher.
lines = [
    f"{head}\n",
    f"- application : `{os.environ['APP_NAME']}`",
    f"- environnement : `{os.environ['ENV_NAME']}`",
    f"- appliqué sous l'identité de : **{os.environ['VALIDATOR']}**",
]
if os.environ.get("BUILD_URL"):
    lines.append(f"- build : {os.environ['BUILD_URL']}")
lines.append("")
if res == "SUCCESS":
    lines.append("La convergence et le `verify` fail-closed sont passés. "
                 "Cette PR porte désormais l'historique complet : plan, décision (merge), résultat.")
else:
    lines.append("**L'application n'est PAS déployée.** Le merge a eu lieu, l'apply non — "
                 "corriger puis relancer l'apply ; inutile de rouvrir une demande.")
open(os.environ["BODY_OUT"], "w").write("\n".join(lines) + "\n")
PY

GIT_REPO="${GIT_REPO:-ci/stoa-labs}" GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}" \
PR_NUMBER="$PR_NUMBER" GIT_HOST="${GIT_HOST:-http://gitea:3000}" \
COMMENT_MARKER='<!-- provision-apply -->' COMMENT_BODY_FILE="$WORK/comment.md" \
  bash "$SELF_DIR/lib/gitea-pr-comment.sh"
