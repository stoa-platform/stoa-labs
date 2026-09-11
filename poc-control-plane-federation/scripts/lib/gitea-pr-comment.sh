#!/usr/bin/env bash
# gitea-pr-comment.sh — poser OU mettre à jour UN commentaire identifié sur une
# Pull Request. Idempotent par MARQUEUR : le même appelant, rejoué, met à jour
# son commentaire au lieu d'en empiler un second.
#
# LE NOM EST HISTORIQUE (2026-09-09). Il date du lab, où la forge était Gitea.
# Ce fichier ne parle plus l'API de Gitea : il demande `comment_find` puis
# `comment_upsert` à scripts/lib/forge-api.sh, la SEULE autorité sur le visage
# (FORGE_KIND=gitea|gitlab), la base d'API, l'en-tête d'auth et la garde de
# réponse. Le nom reste parce que cinq Jenkinsfile et quatre scripts l'appellent
# par ce chemin — le renommer casserait plus qu'il n'éclairerait.
#
# POURQUOI CE FICHIER EXISTE (2026-08-03). La logique vivait à l'intérieur de
# provision-plan.sh. ADR-081 fait remonter AUSSI le statut de l'apply sur la PR :
# sans extraction, le même upsert serait réécrit une deuxième fois, et un jour
# l'une des deux copies serait corrigée et pas l'autre. Même raisonnement que
# cert-der.yml (apply/verify) et strategies-list.yml (consumer-auth/rotate).
#
# LE MARQUEUR EST LA CLÉ D'IDEMPOTENCE, pas l'auteur ni le rang. Un commentaire
# par RÔLE (plan, apply) : deux marqueurs différents cohabitent sur la même PR
# sans jamais s'écraser, et chacun raconte l'état COURANT de son étape plutôt
# qu'un historique que personne ne relit.
#
# Entrées (env) :
#   GIT_HOST      base de la forge vue de l'agent, AVEC son schéma — REQUIS,
#                 aucun repli : le défaut http://gitea:3000 d'avant 2026-09-09
#                 remplaçait en silence une variable non transmise chez un client
#                 (refus nommé GIT_HOST_REQUIS par forge_api_init)
#   GIT_REPO      owner/repo (ex. ci/stoa-labs)
#   FORGE_SECRET  secret de la forge (alias historique GITEA_TOKEN) — lu par
#                 forge-api.py dans l'ENVIRONNEMENT, JAMAIS en argv, jamais loggé
#   FORGE_KIND    gitea (défaut) | gitlab — cf. scripts/lib/forge-api.sh
#   PR_NUMBER     numéro de la PR (iid sur GitLab)
#   COMMENT_MARKER      marqueur HTML invisible (ex. '<!-- provision-apply -->')
#   COMMENT_BODY_FILE   fichier contenant le corps SANS le marqueur
#   COMMENT_ONLY_IF_EXISTS=1  (A0 dettes) ne fait QUE mettre à jour un commentaire
#                 déjà présent sous ce marqueur — s'il n'existe pas, ne crée rien
#                 et rend "COMMENT_SKIPPED" (rc 0). Sert au statut de build de
#                 provision-plan : en SUCCESS il n'ajoute pas un troisième
#                 commentaire redondant, il efface seulement un rouge périmé.
#   API           N'EST PLUS LUE (2026-09-09). La base d'API (v1 chez Gitea,
#                 v4 chez GitLab) est composée par forge-api.py à partir de
#                 GIT_HOST et FORGE_KIND — ou de FORGE_API_BASE pour un
#                 reverse-proxy qui déplace /api. Un appelant qui la pose encore
#                 n'est pas en faute : elle est ignorée.
#   STOA_DEBUG    mode debug SANS FUITE (ci/lib/dbg.sh, L2 2026-09-11) : ce que
#                 ce script DÉCIDE (PR_NUMBER, COMMENT_MARKER, ONLY_IF_EXISTS,
#                 CF_ID, CU_ACTION/CU_ID) sur STDERR seulement, rédigé — jamais
#                 le secret, jamais stdout (le produit ci-dessous ne bouge pas).
#                 Preuve : scripts/test-pr-comment.sh §13.
#
# Sortie : "COMMENT_UPDATED <id>", "COMMENT_CREATED <id>" ou "COMMENT_SKIPPED".
# Échec = rc 1 et `COMMENT_FAILED : … (cause ci-dessus)` sur stderr : la CAUSE
# (statut HTTP, type, taille, URL, début du corps EXPURGÉ du secret) est écrite
# par forge-api juste avant — c'est elle que le client doit lire.
# Réseau : timeout FORGE_TIMEOUT (30 s) par appel ; la recherche du marqueur
# PAGINE jusqu'à une page VIDE (limit=50&page=N sur Gitea, per_page sur GitLab —
# Gitea pagine par défaut ET plafonne `limit` : un marqueur au-delà de la
# première page était invisible et le commentaire se serait EMPILÉ).
set -uo pipefail
set +x

# L2 : le MODE DEBUG SANS FUITE. dbg_kv de ci/lib/dbg.sh est la seule voie de
# sortie (stderr seulement, rédigé, `$?` préservé) — jamais `set -x`. Même
# localisation que forge-api.sh (à côté de ce fichier puis ../../ci/lib, repli
# $PWD/ci/lib) ; absente ⇒ COMMENT_FAILED nommé, rc 1 — le contrat de ce script
# (« Échec = rc 1 et COMMENT_FAILED : … »), le même régime que forge-api.sh
# manquante. dbg_init normalise et EXPORTE STOA_DEBUG pour forge-api.py. Pas de
# DBG_NAME : le préfixe est le nom de CE script.
_CM_DBG="$(dirname "${BASH_SOURCE[0]}")/../../ci/lib/dbg.sh"
[ -f "$_CM_DBG" ] || _CM_DBG="$PWD/ci/lib/dbg.sh"
[ -f "$_CM_DBG" ] \
  || { echo "COMMENT_FAILED : ci/lib/dbg.sh introuvable (cherche : $(dirname "${BASH_SOURCE[0]}")/../../ci/lib/dbg.sh, $PWD/ci/lib/dbg.sh)" >&2; exit 1; }
# shellcheck source=ci/lib/dbg.sh
. "$_CM_DBG"
dbg_init

GIT_REPO="${GIT_REPO:?GIT_REPO requis}"
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN" >&2; exit 2; }
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
COMMENT_MARKER="${COMMENT_MARKER:?COMMENT_MARKER requis}"
COMMENT_BODY_FILE="${COMMENT_BODY_FILE:?COMMENT_BODY_FILE requis}"
COMMENT_ONLY_IF_EXISTS="${COMMENT_ONLY_IF_EXISTS:-0}"
# Ce que ce script a DÉCIDÉ, juste après la décision (stderr, rédigé) : la PR
# visée, la clé d'idempotence, le mode — jamais le corps (il est sur la PR).
dbg_kv PR_NUMBER "$PR_NUMBER"
dbg_kv COMMENT_MARKER "$COMMENT_MARKER"
dbg_kv COMMENT_ONLY_IF_EXISTS "$COMMENT_ONLY_IF_EXISTS"

[ -f "$COMMENT_BODY_FILE" ] || { echo "COMMENT_BODY_FILE introuvable : $COMMENT_BODY_FILE" >&2; exit 1; }

# La forge : une seule autorité, à côté de ce fichier. `forge` lit FORGE_SECRET
# dans l'environnement du shell — la variable posée ci-dessus suffit, rien en argv.
# shellcheck source=scripts/lib/forge-api.sh
. "$(dirname "${BASH_SOURCE[0]}")/forge-api.sh" || { echo "COMMENT_FAILED : scripts/lib/forge-api.sh introuvable a cote de ce fichier" >&2; exit 1; }
# GIT_HOST vide ⇒ GIT_HOST_REQUIS (aucun repli de site) ; visage inconnu ⇒ FORGE_KIND_INCONNU.
forge_api_init || { echo "COMMENT_FAILED : forge non initialisee (cause ci-dessus)" >&2; exit 1; }

# ONLY_IF_EXISTS : le commentaire de CE rôle existe-t-il déjà ? Marqueur seul,
# paginé — dans forge-api, la même pagination que l'upsert (qui la rejoue :
# cette lecture n'est faite QUE quand la réponse décide de ne rien écrire). Une
# forge qui ne répond pas est un échec NOMMÉ, jamais « aucun commentaire » (qui
# ferait EMPILER au prochain appel).
if [ "$COMMENT_ONLY_IF_EXISTS" = 1 ]; then
  forge_kv CF comment_find "$PR_NUMBER" "$COMMENT_MARKER" \
    || { echo "COMMENT_FAILED : recherche du marqueur sur la PR #${PR_NUMBER} (cause ci-dessus)" >&2; exit 1; }
  dbg_kv CF_ID "${CF_ID:-}"   # vide ⇒ « <vide> » : aucun commentaire sous ce marqueur — c'est la raison du SKIPPED
  if [ -z "${CF_ID:-}" ]; then
    echo "COMMENT_SKIPPED"
    exit 0
  fi
fi

forge_kv CU comment_upsert "$PR_NUMBER" "$COMMENT_MARKER" "$COMMENT_BODY_FILE" \
  || { echo "COMMENT_FAILED : ecriture du commentaire sur la PR #${PR_NUMBER} (cause ci-dessus)" >&2; exit 1; }
# Ce que forge-api a fait (created|updated) et sur quel identifiant, AVANT le
# produit qui le redit sur stdout : un ACTION inattendu se lit ici avant le refus.
dbg_kv CU_ACTION "${CU_ACTION:-}"
dbg_kv CU_ID "${CU_ID:-}"
case "${CU_ACTION:-}" in
  updated) echo "COMMENT_UPDATED ${CU_ID:-}" ;;
  created) echo "COMMENT_CREATED ${CU_ID:-}" ;;
  *) echo "COMMENT_FAILED : forge-api a rendu ACTION='${CU_ACTION:-}' (attendu created ou updated)" >&2; exit 1 ;;
esac
