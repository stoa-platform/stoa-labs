#!/usr/bin/env bash
# team-apply-identity.sh — les IDENTITÉS et le LIEN payload↔objet, RELUS SUR LA
# FORGE, avant toute demande en attente qui aboutit et avant tout apply.
#
# POURQUOI UN SCRIPT, ET PAS SIX LIGNES DANS LE JENKINSFILE (mesuré 2026-09-12).
# Ces six lignes ont existé, inline, dans un `sh '''…'''` de
# ci/Jenkinsfile.team-apply — et elles ne pouvaient PAS marcher : un step `sh`
# de Jenkins est interprété par /bin/sh, DASH sur nos agents (le dépôt l'écrit
# déjà : ci/lint-jenkinsfiles.sh:79), or scripts/lib/forge-api.sh est du BASH
# (${BASH_SOURCE[0]}, printf -v, <<<). Mesure, lecture seule :
#   dash -n  scripts/lib/forge-api.sh  → « 111: Syntax error: redirection unexpected », rc 2
#   dash -c '. scripts/lib/forge-api.sh; echo PASSE' → « 34: Bad substitution »
#                                        puis la même erreur, et PASSE n'est JAMAIS imprimé.
# Le step mourait donc sur deux messages de dash qui ne nomment AUCUN refus du
# dépôt, après avoir réveillé un humain et encaissé son mot de passe d'annuaire
# — sur les DEUX visages, Gitea comprise (qui marchait avant le lot L6 phase 2).
# D'où la règle du dépôt, qui n'a pas d'exception : une lib `scripts/lib/*.sh`
# ne se source QUE depuis du bash, et le Jenkinsfile appelle `bash scripts/…`.
# La porte : ci/lint-jenkinsfiles.sh joue `dash -n` sur toute lib sourcée dans
# un bloc `sh` de ci/Jenkinsfile* (portée DÉRIVÉE, aucune liste à la main).
#
# CE QUE CE SCRIPT REFUSE, et pourquoi chaque refus existe :
#   PR_NUMBER_INVALIDE / MERGE_SHA_INVALIDE  la FORME, avant tout appel réseau
#   FORGE_IDENTITES_ILLISIBLES               la forge ne répond pas : on ne se
#                                            rabat PAS sur le payload
#   PAYLOAD_PERIME                           la PR RELUE n'est pas celle qu'on
#                                            s'apprête à appliquer
#   (puis la garde : MERGER_UNKNOWN / REQUESTER_UNKNOWN / MERGER_MISMATCH /
#    FOUR_EYES_VIOLATION — scripts/lib/assert-merge-identity.sh)
#
# LE LIEN PAYLOAD↔OBJET EST LE POINT DUR (défaut trouvé en relecture adverse,
# 2026-09-12, AVANT tout build). Relire `pr_get $PR_NUMBER` pour n'en prendre
# QUE les deux identités laisse le quatre-yeux contournable : PR_NUMBER est un
# fait du PAYLOAD, tandis que l'objet appliqué vient de PR_BRANCH/MERGE_SHA
# (scripts/team-apply.sh : `git checkout -q "$MERGE_SHA"`). Qui poste une charge
# utile portant SON merge (branche + sha) et le NUMÉRO d'une PR d'autrui fait
# valider les quatre yeux par une PR étrangère, en vert. On confronte donc les
# trois faits que la forge rend — merged, merge_commit_sha, head.ref — comme le
# fait déjà scripts/provision-apply-reconcile.sh (PAYLOAD_PERIME), UNE
# comparaison par ligne : chacune porte sa propre épreuve de mutation.
#
# Invocation attendue, depuis ci/Jenkinsfile.team-apply :
#   dir(env.GIT_SUBDIR) { sh 'set +x; bash scripts/team-apply-identity.sh' }
# Les faits arrivent par l'ENVIRONNEMENT (PR_NUMBER, PR_BRANCH, MERGE_SHA
# contribués par le déclencheur ; V_USER saisi dans la demande en attente) —
# jamais par argv, que `ps -Aww` donne à tout le nœud.
set -uo pipefail
set +x   # jamais de trace : le secret de la forge est dans l'environnement
cd "$(dirname "$0")/.." || exit 1

refus(){ echo "REFUS: $*" >&2; exit 1; }
shown(){ [ -n "${1:-}" ] && printf '%s' "$1" || printf '<vide>'; }

PR_NUMBER="${PR_NUMBER:-}"; PR_BRANCH="${PR_BRANCH:-}"; MERGE_SHA="${MERGE_SHA:-}"

# ── 1. LA FORME, avant tout appel réseau ─────────────────────────────────────
case "$PR_NUMBER" in
  ''|*[!0-9]*) refus "PR_NUMBER_INVALIDE : PR_NUMBER n'est pas un entier (valeur : $(shown "$PR_NUMBER")) — aucune identité ne peut être relue" ;;
esac
printf '%s' "$MERGE_SHA" | grep -Eq '^[0-9a-f]{40}$' \
  || refus "MERGE_SHA_INVALIDE : MERGE_SHA hors de ^[0-9a-f]{40}\$ (valeur : $(shown "$MERGE_SHA")) — déclencheur mal câblé, fusion sans commit de merge (fast-forward / squash), ou payload forgé"
[ -n "$PR_BRANCH" ] \
  || refus "BRANCHE_REQUISE : PR_BRANCH vide — sans elle le lien entre la PR relue et l'objet appliqué ne peut pas être vérifié"

# ── 2. LA RELECTURE, seule autorité sur les identités ────────────────────────
# shellcheck source=scripts/lib/forge-api.sh
. scripts/lib/forge-api.sh || refus "FORGE_IDENTITES_ILLISIBLES : scripts/lib/forge-api.sh introuvable ou illisible — sans elle aucune identité ne peut être RELUE, et nourrir la garde du payload serait faire confiance à un tiers"
forge_api_init \
  || refus "FORGE_IDENTITES_ILLISIBLES : la lib de forge ne s'initialise pas (cause ci-dessus) — sans elle aucune identité ne peut être RELUE, et nourrir la garde du payload serait faire confiance à un tiers"
forge_kv PRG pr_get "$PR_NUMBER" \
  || refus "FORGE_IDENTITES_ILLISIBLES : GET de la PR #${PR_NUMBER} sur la forge en échec (cause ci-dessus) — la garde d'identité ne sera PAS nourrie du payload"

# ── 3. LE LIEN : la PR RELUE est-elle CELLE qu'on applique ? ─────────────────
# UNE comparaison par ligne (motif provision-apply-reconcile.sh §A2). La base
# (base.ref) n'est PAS confrontée ici : la branche par défaut est DÉCOUVERTE
# plus loin, par team-apply.sh sur l'origine du worktree — limite nommée.
POURQUOI=""
[ "${PRG_MERGED:-}" = 1 ]                  || POURQUOI="$POURQUOI merged=$(shown "${PRG_MERGED:-}")"
[ "${PRG_MERGE_SHA:-}" = "$MERGE_SHA" ]    || POURQUOI="$POURQUOI merge_commit_sha=$(shown "${PRG_MERGE_SHA:-}")"
[ "${PRG_HEAD_REF:-}" = "$PR_BRANCH" ]     || POURQUOI="$POURQUOI head.ref=$(shown "${PRG_HEAD_REF:-}")"
[ -z "$POURQUOI" ] \
  || refus "PAYLOAD_PERIME : la PR #${PR_NUMBER} relue sur la forge ne correspond pas au webhook (${POURQUOI# }) — les identités relues ne seraient pas celles de la demande appliquée (branche '${PR_BRANCH}', sha ${MERGE_SHA}) ; CE webhook n'a rien appliqué"

# ── 4. LA GARDE, nourrie des identités RELUES ────────────────────────────────
echo "identites RELUES sur la forge : PR #${PR_NUMBER} (${PRG_HEAD_REF}) validee par '${PRG_MERGED_BY:-}', demandee par '${PRG_LOGIN:-}'"
exec sh scripts/lib/assert-merge-identity.sh \
  --merged-by "${PRG_MERGED_BY:-}" --requester "${PRG_LOGIN:-}" --vault-user "${V_USER:-}"
