#!/usr/bin/env bash
# shellcheck disable=SC2015  # idiome des harnais du dépôt : `cond && ok "…" || ko "…"`
# test-app-request-gitlab-live.sh — LA DEMANDE D'APPLICATION, DE BOUT EN BOUT,
# CONTRE UN GITLAB RÉEL. C'est le scénario du client, rejoué au lab.
#
# CE QU'ELLE PROUVE. scripts/provision-request.sh — le script que le client
# lance depuis Jenkins (`ci-app-request`) — déroule [1/5] clone, [2/5] rendu,
# [3/5] push, [4/5] ouverture de la MR contre le GitLab CE du lab ([5/5] plan
# enchaîné, désactivé ici : PROVISION_PLAN_INLINE=false)
# (docker-compose.gitlab.yml), avec FORGE_KIND=gitlab et un PAT de service.
# Puis le DISCRIMINANT : le même script sous FORGE_KIND=gitea contre ce même
# GitLab doit refuser en NOMMANT « 302 … /users/sign_in » — c'est exactement
# la panne vue chez le client le 2026-09-09, reproduite et lisible.
#
# PRÉREQUIS :
#   docker compose -f docker-compose.gitlab.yml up -d gitlab
#   bash scripts/setup-gitlab-lab.sh                 → .env.gitlab-lab (PAT 0600)
#   Le projet ci/stoa-labs du GitLab reçoit NOTRE main (poussé ici si absent) :
#   c'est le même dépôt que sur Gitea, donc les mêmes providers/manifestes.
#
# NETTOIE derrière elle : ferme la MR, supprime la branche provision/<app>-dev.
#
#   bash scripts/test-app-request-gitlab-live.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
S="$REPO/scripts/provision-request.sh"
TMP="$(mktemp -d /tmp/appreqgl.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM
umask 077
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
# shellcheck source=scripts/lib/forge-api.sh
. scripts/lib/forge-api.sh

GL="${GITLAB_LAB_URL:-http://localhost:13080}"
GL_REPO="${GITLAB_LAB_REPO:-ci/stoa-labs}"
if [ -r ./.env.gitlab-lab ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.gitlab-lab
  set +a
fi
[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$GL/")" != 000 ] || { echo "!! GitLab injoignable sur $GL"; echo "RÉSULTAT : 0/1"; exit 1; }
[ -n "${GITLAB_LAB_TOKEN:-}" ] || { echo "!! GITLAB_LAB_TOKEN absent : bash scripts/setup-gitlab-lab.sh"; echo "RÉSULTAT : 0/1"; exit 1; }
TOK="$GITLAB_LAB_TOKEN"
# git parle au GitLab par Basic oauth2:<PAT>, en-tête et jamais dans l'URL (ps).
# http.postBuffer : notre main pèse ~11 Mio ; en chunked (> 1 Mio) ce GitLab rend
# un 500 (gitaly « waiting for receive-pack: exit status 128 », mesuré) — buffé, il passe.
gauth(){ GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'oauth2:%s' "$TOK" | base64 | tr -d '\n')" GIT_CONFIG_KEY_1=http.postBuffer GIT_CONFIG_VALUE_1=524288000 git "$@"; }
CLONE="${GL%/}/${GL_REPO}.git"

echo "═══ 0. le projet GitLab porte notre main (le même dépôt que sur Gitea) ═══"
LOCAL_MAIN="$(git -C "$REPO/.." rev-parse main 2>/dev/null || git -C "$REPO" rev-parse HEAD)"
REMOTE_MAIN="$(gauth ls-remote "$CLONE" refs/heads/main 2>/dev/null | cut -f1)"
if [ "$REMOTE_MAIN" != "$LOCAL_MAIN" ]; then
  gauth -C "$REPO/.." push -q --force "$CLONE" "main:refs/heads/main" 2>"$TMP/push0.err" \
    && ok "0.1 main ($(printf '%s' "$LOCAL_MAIN" | cut -c1-7)) poussé sur $GL_REPO" \
    || { ko "0.1 push de main impossible : $(head -c 200 "$TMP/push0.err")"; echo "RÉSULTAT : $PASS/$((PASS+FAIL))"; exit 1; }
else ok "0.1 $GL_REPO est déjà à notre main ($(printf '%s' "$LOCAL_MAIN" | cut -c1-7))"; fi

# Le login de SERVICE de ce GitLab (le PAT) : la chaîne le compare à l'auteur
# d'une PR ouverte (PR_D_AUTRUI) — chez le client c'est le knob
# GITEA_SERVICE_LOGINS qui nomme le compte de service ; ici, whoami le rend.
# shellcheck disable=SC2016  # le bash enfant reçoit $1, à dessein
SVC_LOGIN="$( env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GL" GIT_REPO="$GL_REPO" FORGE_SECRET="$TOK" bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge whoami' 2>/dev/null | sed -n 's/^LOGIN=//p' )"
[ -n "$SVC_LOGIN" ] || { echo "!! whoami muet : le PAT de .env.gitlab-lab ne répond pas"; echo "RÉSULTAT : 0/1"; exit 1; }
ok "0.2 le PAT de service se présente comme '$SVC_LOGIN' (GITEA_SERVICE_LOGINS pour la chaîne)"

# Le sous-répertoire du livrable DANS ce dépôt (le même qu'au lab).
SUB="$(basename "$REPO")"
APP="appgl"; ENVN="dev"; BR="provision/${APP}-${ENVN}"
gauth push -q "$CLONE" --delete "$BR" 2>/dev/null || true

# req <FORGE_KIND> [VAR=val…] : provision-request.sh contre le GitLab réel
req(){
  local kind="$1"; shift
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" \
      FORGE_KIND="$kind" FORGE_API_AUTH=private-token FORGE_SECRET="$TOK" \
      GIT_HOST="$GL" GIT_WEB_HOST="$GL" GIT_REPO="$GL_REPO" GIT_BASE=main GIT_SUBDIR="$SUB" \
      GIT_CLONE_URL="$CLONE" GIT_PUSH_URL="$CLONE" \
      STOA_ENV_CHAIN_FILE="$REPO/clients/_example/environments.yaml" PROVISION_PLAN_INLINE=false \
      REQ_APP="$APP" REQ_ENV="$ENVN" REQ_API=demo-selfservice REQ_API_VER=1.0.0 REQ_CLIENT_ID="${APP}-${ENVN}" \
      REQ_CALLER=jenkins-form:x REQ_TEAM=banking-demo GITEA_SERVICE_LOGINS="$SVC_LOGIN" \
      "$@" bash "$S" ) > "$TMP/req.out" 2>&1
  echo $? > "$TMP/req.rc"
}
rrc(){ cat "$TMP/req.rc"; }
extrait(){ grep -E 'REFUS|ERREUR|PR |PR_URL|\[[0-9]/4\]' "$TMP/req.out" | tail -4 | tr '\n' ' ' | cut -c1-300; }

echo "═══ A. FORGE_KIND=gitlab : la demande ouvre une MERGE REQUEST ═══"
req gitlab
# Le numéro est relevé AVANT le verdict : le nettoyage doit fermer la MR même si A.1 rougit.
N="$(grep -oE 'PR (créée|déjà ouverte): #[0-9]+' "$TMP/req.out" | grep -oE '[0-9]+$' | head -1)"
if [ "$(rrc)" = 0 ] && grep -q '^\[4/5\]' "$TMP/req.out" && [ -n "$N" ]; then
  ok "A.1 provision-request.sh déroule [1/5]→[4/5] contre GitLab et ouvre la MR !$N"
else ko "A.1 rc $(rrc) : $(extrait)"; fi
if grep -q 'PR_URL=.*/-/merge_requests/' "$TMP/req.out"; then
  ok "A.2 PR_URL est l'URL GitLab de la MR (/-/merge_requests/N), pas un /pulls/N composé à la main"
else ko "A.2 PR_URL : $(grep 'PR_URL=' "$TMP/req.out" | head -1)"; fi
if [ -n "$N" ]; then
  # shellcheck disable=SC2016  # le bash enfant reçoit $1, à dessein
  ( env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GL" GIT_REPO="$GL_REPO" FORGE_SECRET="$TOK" bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge pr_get "$1"' _ "$N" ) > "$TMP/pr.out" 2>"$TMP/pr.err"
  st="$(sed -n 's/^STATE=//p' "$TMP/pr.out")"; hr="$(sed -n 's/^HEAD_REF=//p' "$TMP/pr.out")"; lg="$(sed -n 's/^LOGIN=//p' "$TMP/pr.out")"
  [ "$st" = open ] && [ "$hr" = "$BR" ] && [ -n "$lg" ] && ok "A.3 la MR relue par l'adaptateur : STATE=open HEAD_REF=$BR LOGIN=$lg" || ko "A.3 STATE=$st HEAD_REF=$hr LOGIN=$lg $(head -c 160 "$TMP/pr.err")"
  # IDEMPOTENCE : rejouer la même demande ⇒ « déjà ouverte », même numéro, pas de doublon.
  req gitlab
  grep -q "PR déjà ouverte: #$N" "$TMP/req.out" && ok "A.4 rejeu ⇒ « PR déjà ouverte: #$N » (pr_find_open relit la MR, aucun doublon)" || ko "A.4 rc $(rrc) : $(extrait)"
fi

echo "═══ B. le DISCRIMINANT : FORGE_KIND=gitea contre ce GitLab = la panne du client, NOMMÉE ═══"
gauth push -q "$CLONE" --delete "$BR" 2>/dev/null || true
req gitea FORGE_API_AUTH=token
if [ "$(rrc)" = 2 ] && grep -q 'REFUS: FORGE_ILLISIBLE' "$TMP/req.out" && grep -q '302' "$TMP/req.out" && grep -q '/users/sign_in' "$TMP/req.out" && ! grep -q 'Traceback' "$TMP/req.out"; then
  ok "B.1 FORGE_KIND=gitea ⇒ REFUS: FORGE_ILLISIBLE avec « 302 … /users/sign_in », aucune trace — le 2026-09-09 du client, lisible"
else ko "B.1 rc $(rrc) : $(extrait)"; fi
# Le refus tombe à la relecture des PR, AVANT le push : la branche ne doit pas exister.
if [ "$(gauth ls-remote "$CLONE" "refs/heads/$BR" 2>/dev/null | wc -l | tr -d ' ')" = 0 ]; then
  ok "B.2 refus avant le push : la branche $BR n'existe pas sur la forge (ls-remote)"
else ko "B.2 la branche $BR a été poussée malgré le refus"; fi

echo "═══ Z. nettoyage ═══"
# Une MR laissée ouverte sur la branche (passe précédente interrompue) est retrouvée par l'adaptateur.
if [ -z "${N:-}" ]; then
  # shellcheck disable=SC2016  # le bash enfant reçoit $1, à dessein
  N="$( env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GL" GIT_REPO="$GL_REPO" FORGE_SECRET="$TOK" bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge pr_find_open "$1"' _ "$BR" 2>/dev/null | sed -n 's/^NUMBER=//p' )"
fi
if [ -n "${N:-}" ]; then
  enc="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$GL_REPO")"
  curl -s --max-time 20 -o /dev/null -H "PRIVATE-TOKEN: $TOK" -X PUT "$GL/api/v4/projects/$enc/merge_requests/$N" -d state_event=close
fi
gauth push -q "$CLONE" --delete "$BR" 2>/dev/null && ok "Z.1 MR ${N:-—} fermée, branche $BR supprimée" || ok "Z.1 branche $BR déjà absente"

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
