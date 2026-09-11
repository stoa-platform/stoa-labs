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
#   stage du Jenkinsfile) ; GIT_HOST (REQUIS, avec son schéma, aucun repli :
#   le défaut http://gitea:3000 d'avant 2026-09-11 remplaçait en silence une
#   variable non transmise chez un client) ; GIT_REPO ;
#   GIT_BASE (AUCUN défaut : vide, absente ou « auto » = découverte de la HEAD
#   du dépôt, cf. scripts/lib/git-base.sh) ; BUILD_URL ou JOB_NAME +
#   BUILD_NUMBER (repli textuel : sans URL racine Jenkins, BUILD_URL est vide —
#   mesuré A2).
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
# GIT_HOST : plus de défaut de site (L2, 2026-09-11 — la même ligne que
# provision-plan.sh, provision-request.sh et app-rollback-request.sh). Absent
# ou vide ⇒ mort nommée ici, AVANT tout appel — et rc 1, que l'appelant
# (`|| echo AVERTISSEMENT`) affiche : c'est un câblage manquant, pas un
# « rien à dire ». Chez un client, « http://gitea:3000 » remplaçait la variable
# non transmise et la panne sortait sous BRANCHE_PAR_DEFAUT_INCONNUE.
GIT_HOST="${GIT_HOST:?GIT_HOST requis (base de la forge, ex. https://forge.client) — aucun repli}"; GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
# GIT_BASE n'a plus de défaut « main » (L3, 2026-09-10) : il est POSÉ, plus bas et
# SEULEMENT sur la voie qui en a besoin, par scripts/lib/git-base.sh.
# GIT_REPO garde le sien : un défaut de SITE, dette datée de
# ci/lint-config-knobs.exempt (entrée du 2026-09-11 : la porte ne le voyait pas
# derrière GIT_HOST sur la même ligne — il tombera avec celui de provision-plan.sh).
# shellcheck source=scripts/lib/git-base.sh
. "$SELF_DIR/lib/git-base.sh" || { echo "AVERTISSEMENT: lib git-base.sh introuvable — aucun statut"; exit 0; }
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
  # LA BASE, sur cette voie SEULEMENT : quand les faits du plan existent, ce
  # script ne parle a personne — il ne doit pas non plus interroger un depot.
  #
  # L'ENVELOPPE, DITE JUSTE (revue 2026-09-10). Ce script ne clone JAMAIS : il
  # n'y a donc, contrairement aux quatre autres sites, aucun geste git anonyme
  # voisin dont heriter. Le voisin honnete est l'appel d'API, et lui est
  # AUTHENTIFIE (forge-api, FORGE_SECRET, rendu obligatoire l. 51-52). Un
  # `git ls-remote` nu serait ANONYME : sur un depot PRIVE — le cas normal — il
  # echouerait, et une decouverte ratee effacerait le statut de build. Le meme
  # secret voyage donc en Basic dans http.extraheader, pose en PREFIXE D'ENV sur
  # l'appel de fonction (bash le passe aux enfants et ne le laisse pas persister
  # apres le retour, mesure) : jamais en argv, jamais dans l'URL. Meme motif que
  # scripts/lib/generate-choices.sh (_gc_auth_b64). GIT_USER/FORGE_USER : Gitea
  # accepte n'importe quel utilisateur avec un jeton, GitLab et Bitbucket NON.
  case "$GIT_HOST" in http://*|https://*|file://*) SB="${GIT_HOST%/}";; *) SB="http://${GIT_HOST%/}";; esac
  SB_AUTH="$(printf '%s:%s' "${FORGE_USER:-${GIT_USER:-x}}" "$FORGE_SECRET" | base64 | tr -d '\n')"
  # ET IL REFUSE BRUYAMMENT. Un `exit 0` ici serait le defaut que les l. 48-50 de
  # ce fichier consignent comme corrige le 2026-09-04 : build vert, statut de
  # build jamais poste, personne ne sait pourquoi. rc 2, refus nomme, sur stderr.
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${SB_AUTH}" \
    git_base_init "${SB}/${GIT_REPO}.git" \
    || { echo "REFUS: BRANCHE_PAR_DEFAUT_INCONNUE : branche par defaut de ${GIT_REPO} indeterminable (cause ci-dessus) — sans elle la PR ne peut pas etre confirmee, et AUCUN statut de build n'a ete poste" >&2; exit 2; }
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
