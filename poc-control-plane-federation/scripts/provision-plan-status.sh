#!/usr/bin/env bash
# provision-plan-status.sh — le STATUT DE BUILD de provision-plan sur la PR
# (A0 dettes, 2026-09-02 — parité avec le post{always} de provision-apply et
# de team-apply, dette I3) : une PR provision/* n'est jamais MUETTE quand le
# build de plan a été abandonné, a échoué avant le verdict, ou a IGNORÉ la
# demande. Marqueur DISTINCT du verdict :
#     <!-- provision-plan -->        le VERDICT (provision-plan.sh, ✅/❌)
#     <!-- provision-plan-build -->  le STATUT du build (ce script)
#
# ── D'OÙ VIENT LA VÉRITÉ ────────────────────────────────────────────────────
# Le payload du webhook (PR_NUMBER, PR_BRANCH) ne fait pas foi. Ce script lit
# d'abord le FICHIER DE FAITS écrit par provision-plan.sh (PLAN_FACTS :
# GITEA_HEAD_REF relu sur la forge, PLAN_VERDICT, PLAN_REASON) — une seule
# relecture, pas de TOCTOU. Si les faits sont ABSENTS (le stage n'a pas tourné :
# agent injoignable, clone du dépôt plateforme raté, pause abandonnée avant),
# il relit la forge lui-même par la MÊME lib (scripts/lib/gitea-pr-confirm.sh).
# Forge non confirmée dans les deux cas ⇒ AUCUN commentaire (rc 0) : jamais un
# geste du compte de service sur une PR seulement nommée.
#
# ── QUAND IL PARLE, ET QUAND IL SE TAIT ─────────────────────────────────────
#   SUCCESS + verdict ok   ⇒ upsert SEULEMENT si un statut existe déjà (efface
#                            un rouge périmé) — le verdict ✅ est déjà là, un
#                            troisième commentaire n'apprendrait rien ;
#   SUCCESS + ignore       ⇒ « demande IGNOREE (<raison>) : aucun verdict » —
#                            c'est l'information que le vert cachait ;
#   ABORTED                ⇒ « abandonne : aucun verdict, rejouer » ;
#   * + fail               ⇒ « verdict NEGATIF, voir provision-plan » ;
#   ABORTED/FAILURE + ok   ⇒ « verdict RENDU, build termine <resultat> apres coup » ;
#   FAILURE + refus        ⇒ « refus avant le verdict : <raison> » (la forge a
#                            confirmé la PR, le clone/checkout a refusé) ;
#   FAILURE sans faits     ⇒ « echec avant le plan (agent ?), voir le log ».
# Corps SANS accents : ils traversent l'agent, un POST JSON et Gitea.
#
# Entrées (env) : PR_NUMBER, PR_BRANCH, BUILD_RESULT (req) ; FORGE_SECRET (req) ;
#   PLAN_FACTS (chemin du fichier de faits, optionnel) OU les mêmes faits en
#   env (GITEA_HEAD_REF, PLAN_VERDICT, PLAN_REASON — chargés par le post de
#   stage du Jenkinsfile) ; GIT_HOST, GIT_REPO,
#   GIT_BASE ; BUILD_URL ou JOB_NAME + BUILD_NUMBER (repli textuel : sans URL
#   racine Jenkins, BUILD_URL est vide — mesuré A2).
# Sortie : rc 0 dans tous les cas « rien à dire » ; rc du commentaire sinon.
set -uo pipefail
set +x
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PR_NUMBER="${PR_NUMBER:-}"; PR_BRANCH="${PR_BRANCH:-}"
BUILD_RESULT="${BUILD_RESULT:?BUILD_RESULT requis}"
# 2026-09-04 : le pipeline pose FORGE_SECRET depuis forgeCreds(). Sans cet alias,
# ce script refusait, et l'appelant avalait le refus (`|| echo AVERTISSEMENT`) :
# build vert, statut de build jamais poste. Defaut ACTIF, corrige ici.
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN" >&2; exit 2; }
GIT_HOST="${GIT_HOST:-http://gitea:3000}"; GIT_REPO="${GIT_REPO:-ci/stoa-labs}"; GIT_BASE="${GIT_BASE:-main}"
PLAN_FACTS="${PLAN_FACTS:-}"

case "$PR_NUMBER" in ''|*[!0-9]*) echo "(PR_NUMBER non numerique — aucun statut a commenter)"; exit 0;; esac
case "$PR_BRANCH" in provision/*) ;; *) echo "(branche hors provision/* — aucun statut a commenter)"; exit 0;; esac

# ── la vérité : les faits du plan, sinon la forge ────────────────────────────
HEAD_REF=""; VERDICT=""; REASON=""; SOURCE=""; FACTS_PR=""
if [ -n "$PLAN_FACTS" ] && [ -f "$PLAN_FACTS" ]; then
  HEAD_REF="$(sed -n 's/^GITEA_HEAD_REF=//p' "$PLAN_FACTS" | head -1)"
  VERDICT="$(sed -n 's/^PLAN_VERDICT=//p' "$PLAN_FACTS" | head -1)"
  REASON="$(sed -n 's/^PLAN_REASON=//p' "$PLAN_FACTS" | head -1)"
  FACTS_PR="$(sed -n 's/^PLAN_PR_NUMBER=//p' "$PLAN_FACTS" | head -1)"
  SOURCE="faits du plan (fichier)"
  # Des faits qui ne nomment pas CETTE PR sont ceux d'un autre build (workspace
  # persistant) : on ne parle pas sur leur foi.
  if [ -n "$FACTS_PR" ] && [ "$FACTS_PR" != "$PR_NUMBER" ]; then
    echo "(faits d'une autre PR (#$FACTS_PR) — perimes, aucun statut a commenter)"; exit 0
  fi
  if [ -z "$HEAD_REF" ]; then
    echo "(le plan n'a pas obtenu la confirmation de la forge — ${VERDICT:-?} : ${REASON:-?} — aucun statut a commenter)"; exit 0
  fi
elif [ -n "${PLAN_VERDICT:-}" ]; then
  # Les faits chargés dans l'ENVIRONNEMENT par le post{always} du STAGE de plan
  # (ci/Jenkinsfile.provision-plan) : le nœud du post de pipeline n'a pas
  # forcement le workspace du stage, mais il a son environnement.
  HEAD_REF="${GITEA_HEAD_REF:-}"; VERDICT="$PLAN_VERDICT"; REASON="${PLAN_REASON:-}"; FACTS_PR="${PLAN_PR_NUMBER:-}"
  SOURCE="faits du plan (environnement)"
  if [ -n "$FACTS_PR" ] && [ "$FACTS_PR" != "$PR_NUMBER" ]; then
    echo "(faits d'une autre PR (#$FACTS_PR) — perimes, aucun statut a commenter)"; exit 0
  fi
  if [ -z "$HEAD_REF" ]; then
    echo "(le plan n'a pas obtenu la confirmation de la forge — ${VERDICT} : ${REASON:-?} — aucun statut a commenter)"; exit 0
  fi
else
  # shellcheck source=scripts/lib/gitea-pr-confirm.sh
  . "$SELF_DIR/lib/gitea-pr-confirm.sh" || { echo "AVERTISSEMENT: lib gitea-pr-confirm.sh introuvable — aucun statut"; exit 0; }
  if ! CONFIRM="$(gitea_pr_confirm "$PR_NUMBER" "$PR_BRANCH" "$GIT_BASE" 2>&1)"; then
    echo "(forge non confirmee : $(printf '%s' "$CONFIRM" | tr '\n' ' ') — aucun statut a commenter)"; exit 0
  fi
  HEAD_REF="$(printf '%s\n' "$CONFIRM" | sed -n 's/^GITEA_HEAD_REF=//p')"
  SOURCE="forge relue (faits absents : le stage de plan n'a pas tourne)"
fi
[ "$HEAD_REF" = "$PR_BRANCH" ] || { echo "(tete confirmee '$HEAD_REF' != payload '$PR_BRANCH' — aucun statut a commenter)"; exit 0; }

BUILD_REF="${BUILD_URL:-}"
[ -n "$BUILD_REF" ] || BUILD_REF="${JOB_NAME:-provision-plan} #${BUILD_NUMBER:-?}"

# ── le corps : le VERDICT d'abord (s'il existe), le résultat du build ensuite ──
# (revue 2026-09-02 : ABORTED/FAILURE/UNSTABLE APRÈS un verdict rendu ne doivent
# jamais dire « aucun verdict » ni « agent injoignable » à côté d'un ✅/❌.)
ONLY_IF_EXISTS=0
BODYFILE="$(mktemp)"; trap 'rm -f "$BODYFILE"' EXIT
case "${VERDICT}:${BUILD_RESULT}" in
  ok:SUCCESS)
    ONLY_IF_EXISTS=1
    printf 'provision-plan (statut build) : build termine sans erreur -- le verdict est dans le commentaire provision-plan ci-dessus. Build : %s\n' "$BUILD_REF" > "$BODYFILE" ;;
  ok:*)
    printf 'provision-plan (statut build) : le verdict a ete RENDU (voir le commentaire provision-plan ci-dessus), puis le build s est termine %s apres coup -- le verdict reste valable. Build : %s\n' "$BUILD_RESULT" "$BUILD_REF" > "$BODYFILE" ;;
  fail:*)
    printf 'provision-plan (statut build) : le plan a rendu un verdict NEGATIF -- voir le commentaire provision-plan ci-dessus et corriger la demande avant validation. Build : %s\n' "$BUILD_REF" > "$BODYFILE" ;;
  ignore:*)
    printf 'provision-plan (statut build) : demande IGNOREE -- %s. AUCUN verdict n a ete rendu : rien a valider sur cette PR en l etat (build %s). Build : %s\n' "${REASON:-raison inconnue}" "$BUILD_RESULT" "$BUILD_REF" > "$BODYFILE" ;;
  refus:*)
    printf 'provision-plan (statut build) : REFUS avant le verdict -- %s. Aucun verdict n a ete pose. Build : %s\n' "${REASON:-raison inconnue}" "$BUILD_REF" > "$BODYFILE" ;;
  :ABORTED)
    printf 'provision-plan (statut build) : le build de plan a ete ABANDONNE (ou a expire) -- AUCUN verdict. Rejouer le webhook (ou pousser sur la branche) pour obtenir un plan. Build : %s\n' "$BUILD_REF" > "$BODYFILE" ;;
  :SUCCESS)
    ONLY_IF_EXISTS=1
    printf 'provision-plan (statut build) : build termine sans erreur, sans faits de plan (source : %s). Build : %s\n' "$SOURCE" "$BUILD_REF" > "$BODYFILE" ;;
  *)
    printf 'provision-plan (statut build) : le build a ECHOUE (%s) avant le plan (agent injoignable, depot plateforme non clonable) -- AUCUN verdict. Source : %s. Voir le log : %s\n' "$BUILD_RESULT" "$SOURCE" "$BUILD_REF" > "$BODYFILE" ;;
esac

GIT_REPO="$GIT_REPO" FORGE_SECRET="$FORGE_SECRET" PR_NUMBER="$PR_NUMBER" GIT_HOST="$GIT_HOST" \
  COMMENT_MARKER="<!-- provision-plan-build -->" COMMENT_BODY_FILE="$BODYFILE" COMMENT_ONLY_IF_EXISTS="$ONLY_IF_EXISTS" \
  bash "$SELF_DIR/lib/gitea-pr-comment.sh"
