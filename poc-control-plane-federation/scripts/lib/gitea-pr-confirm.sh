#!/usr/bin/env bash
# scripts/lib/gitea-pr-confirm.sh — CONFIRMER une PR auprès de la FORGE avant
# d'agir en son nom. À SOURCER, jamais exécuté seul.
#
# LE NOM EST HISTORIQUE (2026-09-09). Il date du lab, où la forge était Gitea.
# La lib ne parle plus l'API de Gitea : elle demande `pr_get` à
# scripts/lib/forge-api.sh — la SEULE autorité sur le visage (FORGE_KIND=
# gitea|gitlab), la base d'API, l'en-tête d'auth et la garde de réponse — et ne
# garde ici que les VERDICTS. Le nom du fichier, celui de la fonction et les
# quatre lignes GITEA_* restent tels quels : provision-plan.sh et
# provision-plan-status.sh les sourcent et les lisent.
#
# POURQUOI CETTE LIB EXISTE (A0 dettes, 2026-09-02 — critique adverse, constat
# BLOQUANT). Un webhook generic-webhook-trigger porte un jeton partagé et aucun
# HMAC vérifié : son payload est une AFFIRMATION. Jusqu'ici, provision-plan.sh
# clonait la branche PR_BRANCH et commentait la PR PR_NUMBER TELS QUE NOMMÉS
# par le payload — un payload forgé (branche réelle de la PR A, numéro de la
# PR B) faisait poser au compte de service un VERDICT sur une PR étrangère.
# provision-apply, lui, relit la forge avant tout (provision-apply-reconcile.sh).
# Cette lib porte la même règle, en UN endroit, pour le plan ET son statut :
#
#   « jamais un geste du compte de service sur une PR seulement NOMMÉE. »
#
# gitea_pr_confirm <numéro> <head_ref attendu> <base_ref attendue>
#   `forge pr_get <numéro>` (secret PAR ENV — jamais en argv —, timeout
#   FORGE_TIMEOUT 30 s, aucune redirection suivie). rc 0 et, sur stdout, quatre
#   lignes
#     GITEA_STATE=open
#     GITEA_HEAD_REF=<tête>     (head.ref sur Gitea, source_branch sur GitLab)
#     GITEA_HEAD_SHA=<sha>      (head.sha / sha)
#     GITEA_BASE_REF=<base>     (base.ref / target_branch)
#   SEULEMENT si : STATE == open, tête == attendue, tête ~ ^provision/,
#   base == base attendue, la PR vient du dépôt lui-même (SAME_REPO=1), et
#   aucune valeur ne porte de retour-ligne (forge-api refuse d'en rendre).
#   Sinon rc 1 et `FORGE_NON_CONFIRMEE : <raison>` sur stderr — 404 (PR
#   inconnue), 5xx, timeout, redirection, réponse non-objet, champ absent,
#   head.sha non hexadécimal (jamais un argument libre pour git), PR depuis un
#   FORK (sa tête n'est pas dans le clone), PR fermée ou mergée (une branche
#   provision/<app>-<env> RÉUTILISÉE après merge ne doit pas faire commenter la
#   PR mergée), tête ou base divergente. Quand c'est la FORGE qui refuse, la
#   CAUSE auto-diagnostique de forge-api (statut, type, URL, début du corps
#   expurgé du secret) précède la ligne FORGE_NON_CONFIRMEE sur stderr.
#   Le numéro est validé ^[0-9]+$ et la tête attendue ^provision/ AVANT tout
#   contact avec la forge (jamais un chemin forgé) ; rc 1 sans appel réseau sinon.
#
# Entrées (env) : GIT_HOST (REQUIS, avec son schéma — AUCUN repli : le défaut
# http://gitea:3000 d'avant 2026-09-09 remplaçait en silence une variable non
# transmise chez un client, et la panne sortait plus loin sous un autre nom),
# GIT_REPO (REQUIS, owner/repo), FORGE_SECRET (requis ; alias historique
# GITEA_TOKEN), FORGE_KIND (gitea par défaut, ou gitlab).
# STOA_DEBUG (L2, 2026-09-11) : sous ce mode, UNE ligne de debug après la
# relecture — « PR #n relue : state=… head=… sha=… base=… same_repo=… (attendu
# head=… base=…) », sur stderr, rédigée par ci/lib/dbg.sh, sous le nom du
# script qui source cette lib — c'est la ligne que le client lira quand
# FORGE_NON_CONFIRMEE tombe (test-a0-wiring §9 (c ter).1k, .2a). Les verdicts,
# leurs tags et leur ordre ne changent pas ; stdout (CLÉ=VALEUR) non plus.

# shellcheck source=scripts/lib/forge-api.sh
. "$(dirname "${BASH_SOURCE[0]}")/forge-api.sh" || { echo "ERREUR: scripts/lib/forge-api.sh introuvable a cote de gitea-pr-confirm.sh" >&2; return 1; }
# ci/lib/dbg.sh : le répertoire de CE fichier puis ../../ci/lib (le `..` est
# résolu par le noyau derrière un lien symbolique), repli $PWD/ci/lib. Sourcée
# ici même si forge-api.sh la porte déjà : une lib ne dépend pas d'un import
# transitif pour se dire. Absente ⇒ ERREUR nommée et return 1, comme toute lib
# manquante — jamais une lib qui marcherait sans pouvoir se dire.
_PC_DBG="$(dirname "${BASH_SOURCE[0]}")/../../ci/lib/dbg.sh"
[ -f "$_PC_DBG" ] || _PC_DBG="$PWD/ci/lib/dbg.sh"
[ -f "$_PC_DBG" ] \
  || { echo "ERREUR: ci/lib/dbg.sh introuvable (cherché : $(dirname "${BASH_SOURCE[0]}")/../../ci/lib/dbg.sh, $PWD/ci/lib/dbg.sh)" >&2; return 1; }
# shellcheck source=ci/lib/dbg.sh
. "$_PC_DBG"

gitea_pr_confirm(){
  local n="${1:-}" want_head="${2:-}" want_base="${3:-}"
  # Validations d'entrée : aucun appel réseau avant qu'elles passent.
  case "$n" in ''|*[!0-9]*) echo "FORGE_NON_CONFIRMEE : numero de PR non numerique ('$n')" >&2; return 1;; esac
  [ -n "$want_head" ] || { echo "FORGE_NON_CONFIRMEE : head_ref attendu vide" >&2; return 1; }
  # LA BASE ATTENDUE EST OBLIGATOIRE (L3, 2026-09-10). Son défaut « main »
  # était un défaut de SITE invisible à ci/lint-config-knobs.sh : chez un client
  # dont la branche est `master`, un appelant qui oubliait l'argument faisait
  # refuser FORGE_NON_CONFIRMEE toutes ses PR, en accusant la PR. Fail-closed :
  # l'appelant pose la base (scripts/lib/git-base.sh la lui donne).
  [ -n "$want_base" ] || { echo "FORGE_NON_CONFIRMEE : base_ref attendue vide — la branche de base est un ARGUMENT obligatoire, aucun defaut (cf. scripts/lib/git-base.sh)" >&2; return 1; }
  case "$want_head" in provision/*) ;; *) echo "FORGE_NON_CONFIRMEE : head_ref attendu hors provision/* ('$want_head')" >&2; return 1;; esac
  FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
  [ -n "$FORGE_SECRET" ] || { echo "FORGE_NON_CONFIRMEE : ni FORGE_SECRET ni son alias GITEA_TOKEN" >&2; return 1; }
  # Aucun défaut de site : une base ou un dépôt non transmis est un REFUS nommé,
  # pas un repli vers le lab (les mêmes tags que forge_api_init, sous le nôtre).
  [ -n "${GIT_HOST:-}" ] || { echo "FORGE_NON_CONFIRMEE : GIT_HOST_REQUIS — base de la forge non transmise, aucun repli" >&2; return 1; }
  [ -n "${GIT_REPO:-}" ] || { echo "FORGE_NON_CONFIRMEE : GIT_REPO_REQUIS — owner/repo non transmis, aucun repli" >&2; return 1; }
  forge_api_init || { echo "FORGE_NON_CONFIRMEE : forge non initialisee (cause ci-dessus)" >&2; return 1; }

  # Les faits de la PR, normalisés par forge-api quel que soit le visage. Locaux :
  # forge_kv les pose ici (portée dynamique), rien ne fuit chez l'appelant.
  local PC_STATE="" PC_HEAD_REF="" PC_HEAD_SHA="" PC_BASE_REF="" PC_SAME_REPO=""
  forge_kv PC pr_get "$n" || { echo "FORGE_NON_CONFIRMEE : la forge n'a pas rendu la PR #${n} (cause ci-dessus)" >&2; return 1; }
  # Ce que la forge a rendu, en UNE ligne, AVANT les verdicts, avec ce qui était
  # attendu : un refus qui suit se lit avec ses données. Des valeurs de forge,
  # jamais un secret ; forge-api refuse de rendre un retour-ligne. dbg rend le
  # rc reçu : rien ne change pour l'appelant.
  dbg "PR #${n} relue : state=${PC_STATE} head=${PC_HEAD_REF} sha=${PC_HEAD_SHA} base=${PC_BASE_REF} same_repo=${PC_SAME_REPO} (attendu head=${want_head} base=${want_base})"

  # Les MÊMES verdicts qu'avant le routage, dans le même ordre.
  [ -n "$PC_STATE" ]    || { echo "FORGE_NON_CONFIRMEE : champ state absent de la PR #${n}" >&2; return 1; }
  [ -n "$PC_HEAD_REF" ] || { echo "FORGE_NON_CONFIRMEE : champ head.ref absent de la PR #${n}" >&2; return 1; }
  [ -n "$PC_HEAD_SHA" ] || { echo "FORGE_NON_CONFIRMEE : champ head.sha absent de la PR #${n}" >&2; return 1; }
  [ -n "$PC_BASE_REF" ] || { echo "FORGE_NON_CONFIRMEE : champ base.ref absent de la PR #${n}" >&2; return 1; }
  # Le SHA ira à `git checkout --detach` : 40 hexadécimaux, jamais une option.
  case "$PC_HEAD_SHA" in *[!0-9a-f]*) PC_HEAD_SHA="";; esac
  [ "${#PC_HEAD_SHA}" -eq 40 ] || { echo "FORGE_NON_CONFIRMEE : head.sha de la PR #${n} n'est pas un SHA hexadecimal de 40 caracteres" >&2; return 1; }
  [ "$PC_SAME_REPO" = 1 ] || { echo "FORGE_NON_CONFIRMEE : PR #${n} vient d'un FORK — sa tete n'est pas dans le depot ${GIT_REPO}" >&2; return 1; }
  [ "$PC_STATE" = open ] || { echo "FORGE_NON_CONFIRMEE : PR #${n} n'est pas ouverte (state=${PC_STATE}) — une PR fermee ou mergee ne recoit plus de plan" >&2; return 1; }
  [ "$PC_HEAD_REF" = "$want_head" ] || { echo "FORGE_NON_CONFIRMEE : tete de la PR #${n} = '${PC_HEAD_REF}', le payload nommait '${want_head}'" >&2; return 1; }
  case "$PC_HEAD_REF" in provision/*) ;; *) echo "FORGE_NON_CONFIRMEE : tete de la PR #${n} hors provision/* ('${PC_HEAD_REF}')" >&2; return 1;; esac
  [ "$PC_BASE_REF" = "$want_base" ] || { echo "FORGE_NON_CONFIRMEE : base de la PR #${n} = '${PC_BASE_REF}', attendu '${want_base}'" >&2; return 1; }
  printf 'GITEA_STATE=open\nGITEA_HEAD_REF=%s\nGITEA_HEAD_SHA=%s\nGITEA_BASE_REF=%s\n' "$PC_HEAD_REF" "$PC_HEAD_SHA" "$PC_BASE_REF"
}
