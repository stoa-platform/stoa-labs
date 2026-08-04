#!/usr/bin/env bash
# team-request.sh — moteur du formulaire « onboarder une équipe » (palier 2).
#
#   formulaire Jenkins → CE script :
#     1. gardes d'entrée (AVANT tout geste Git — un refus ne laisse rien derrière)
#     2. clone du dépôt plateforme, AJOUT de l'entrée dans providers.<env>.yml
#     3. branche onboard/<team>-<env>, commit (identité de service ci), push, PR
#     4. PLAN : ansible/team-plan.yml contre le fichier MODIFIÉ → commentaire ✅/❌
#
# La décision reste le MERGE (ADR-081) : ce script n'applique rien, ne crée
# aucun dépôt, ne touche ni Vault ni la gateway. Le privilège de création vit
# dans le seul job post-merge (team-apply).
#
# Entrées (env — mappées depuis les paramètres du job) :
#   TEAM         (req) nom d'équipe — regex du rôle, refus TEAM_NAME_INVALID
#   DESCRIPTION        libre (sans " ni retour ligne — YAML_UNSAFE_INPUT sinon)
#   APPROVERS          matricules CSV ; VIDE ACCEPTÉ (cas payments-team)
#   REPO               full-name org/nom (défaut <TEAM>/apis)
#   REQ_ENV            dev|rec|int|prod — seul dev est OUVERT au palier 2
#   GITEA_TOKEN  (req) token du service ci (write:repository, write:issue)
#   GIT_REPO           défaut ci/stoa-labs   GIT_HOST  défaut http://gitea:3000
#   GIT_WEB_HOST       URL Gitea vue par l'HUMAIN (liens des commentaires)
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1

TEAM="${TEAM:?TEAM requis}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
DESCRIPTION="${DESCRIPTION:-}"
APPROVERS="${APPROVERS:-}"
REPO="${REPO:-${TEAM}/apis}"
REQ_ENV="${REQ_ENV:-dev}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"

fail(){ echo "ERREUR: $*" >&2; exit 1; }

# ── 1. gardes d'entrée — AVANT tout geste Git ────────────────────────────────
# Regex du rôle, avec la leçon \Z du palier 1 : bash/grep matchent par LIGNE,
# donc un TEAM porteur d'un \n interne passerait un grep naïf. On refuse
# d'abord tout caractère hors classe (dont \n), PUIS la forme.
case "$TEAM" in *[!a-z0-9-]*) fail "TEAM_NAME_INVALID : '$TEAM' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis";; esac
printf '%s' "$TEAM" | grep -Eq '^[a-z0-9][a-z0-9-]{1,30}$' \
  || fail "TEAM_NAME_INVALID : '$TEAM' — ^[a-z0-9][a-z0-9-]{1,30}\$ requis"

# Palier 2 : seul dev est ouvert. Les autres envs sont listés au formulaire
# mais GARDÉS ici — le message dit pourquoi, pas juste « non ».
[ "$REQ_ENV" = "dev" ] || fail "ENV_NOT_OPEN : '$REQ_ENV' — seul dev est ouvert au palier 2 (rec/int/prod : gouvernance à cadrer)"

# Ces valeurs sont INJECTÉES dans un YAML : un " ou un retour ligne dans la
# description casserait ou détournerait le fichier — même classe d'attaque que
# l'évasion de chemin du rôle. Refus, pas échappement (KISS + auditables).
case "$DESCRIPTION" in *'"'*|*$'\n'*) fail "YAML_UNSAFE_INPUT : description sans \" ni retour ligne";; esac
case "$REPO" in
  */*) printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
         || fail "YAML_UNSAFE_INPUT : REPO '$REPO' — forme org/nom requise";;
  *) fail "YAML_UNSAFE_INPUT : REPO '$REPO' — forme org/nom requise";;
esac
APPROVERS_YAML=""
if [ -n "$APPROVERS" ]; then
  IFS=',' read -ra _APPR <<< "$APPROVERS"
  for a in "${_APPR[@]}"; do
    a="$(printf '%s' "$a" | tr -d '[:space:]')"
    [ -z "$a" ] && continue
    printf '%s' "$a" | grep -Eq '^[A-Za-z0-9_-]+$' \
      || fail "YAML_UNSAFE_INPUT : approbateur '$a' — [A-Za-z0-9_-] uniquement"
    APPROVERS_YAML="${APPROVERS_YAML:+$APPROVERS_YAML, }\"$a\""
  done
fi

# ── 2. clone + édition de providers.<env>.yml ────────────────────────────────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
BRANCH="onboard/${TEAM}-${REQ_ENV}"
echo "[1/4] clone ${GIT_REPO}"
git clone -q --depth 1 -b main "${GIT_HOST}/${GIT_REPO}.git" "$WORK/repo" || fail "clone ${GIT_REPO}"
PROV="$WORK/repo/poc-control-plane-federation/ansible/providers.${REQ_ENV}.yml"
[ -f "$PROV" ] || fail "providers.${REQ_ENV}.yml absent du dépôt plateforme"

# Jamais d'écrasement silencieux : une équipe déjà déclarée est un refus,
# pas une mise à jour — la mise à jour d'une équipe passe par une PR manuelle.
grep -Eq "^  - team: ${TEAM}\$" "$PROV" && fail "TEAM_ALREADY_DECLARED : ${TEAM} est déjà dans providers.${REQ_ENV}.yml"

echo "[2/4] entrée ${TEAM} dans providers.${REQ_ENV}.yml"
cat >> "$PROV" <<EOF

  # Ajout par formulaire Jenkins team-request (palier 2) — la PR est l'acte
  # d'autorisation (ADR-081) ; le dépôt et les objets naissent au merge.
  - team: ${TEAM}
    description: "${DESCRIPTION}"
    repo: ${REPO}
    approvers: [${APPROVERS_YAML}]
EOF

# ── 3. branche, commit, push, PR ─────────────────────────────────────────────
echo "[3/4] branche ${BRANCH} + PR"
PUSH_URL="http://ci:${GITEA_TOKEN}@${GIT_HOST#http://}/${GIT_REPO}.git"
git -C "$WORK/repo" checkout -q -b "$BRANCH"
git -C "$WORK/repo" -c user.name=ci -c user.email=ci@stoa.lab \
  commit -qam "onboard(${TEAM}): demande d'onboarding ${REQ_ENV} (formulaire)"
git -C "$WORK/repo" push -q "$PUSH_URL" "$BRANCH" 2>"$WORK/pusherr" \
  || { echo "ERREUR push (détail masqué — token)" >&2; grep -v "$GITEA_TOKEN" "$WORK/pusherr" >&2 || true; exit 1; }

PR_NUMBER=$(API="${GIT_HOST}/api/v1" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" \
  BRANCH="$BRANCH" TEAM="$TEAM" REQ_ENV="$REQ_ENV" python3 - <<'PY'
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["GITEA_TOKEN"]
body = {"base": "main", "head": os.environ["BRANCH"],
        "title": f"onboard: équipe {os.environ['TEAM']} ({os.environ['REQ_ENV']})"}
req = urllib.request.Request(f"{api}/repos/{repo}/pulls", method="POST",
    data=json.dumps(body).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
print(json.load(urllib.request.urlopen(req))["number"])
PY
) || fail "ouverture de la PR"
echo "PR #${PR_NUMBER} ouverte : ${GIT_WEB_HOST}/${GIT_REPO}/pulls/${PR_NUMBER}"

# ── 4. PLAN contre le fichier MODIFIÉ + commentaire ──────────────────────────
# Le plan tourne dans le CLONE (la branche), pas dans le checkout du job : ce
# que le valideur lira est calculé sur ce qui sera mergé, rien d'autre.
echo "[4/4] plan (gardes hors ligne du rôle)"
PLAN_LOG="$WORK/plan.log"
( cd "$WORK/repo/poc-control-plane-federation" \
  && ansible-playbook -i ansible/inventory.lab.ini ansible/team-plan.yml \
       -e "apim_onb_team=${TEAM}" -e "apim_onb_providers_file=providers.${REQ_ENV}.yml" \
) >"$PLAN_LOG" 2>&1
PLAN_RC=$?
DERIVED=$(grep -oE 'equipe=[^"]*' "$PLAN_LOG" | head -1)
if [ "$PLAN_RC" -eq 0 ]; then
  VERDICT="✅ PLAN OK — ${DERIVED:-dérivations non capturées}"
else
  VERDICT="❌ PLAN EN ÉCHEC — NE PAS MERGER : $(grep -oE '(TEAM_[A-Z_]+|TENANT_ROOT_UNSAFE)' "$PLAN_LOG" | sort -u | tr '\n' ' ')"
fi
BODY="${VERDICT}

Au merge, team-apply : crée le dépôt \`${REPO}\` (squelette ADR-076) puis pose
user/groupe/team gateway + KV/policy Vault (rôle apim_team_onboard, idempotent)."
API="${GIT_HOST}/api/v1" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" \
  PR="$PR_NUMBER" BODY="$BODY" python3 - <<'PY'
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["GITEA_TOKEN"]
req = urllib.request.Request(f"{api}/repos/{repo}/issues/{os.environ['PR']}/comments",
    method="POST", data=json.dumps({"body": os.environ["BODY"]}).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
urllib.request.urlopen(req)
PY
echo "plan ${VERDICT%% *} commenté sur la PR #${PR_NUMBER}"
[ "$PLAN_RC" -eq 0 ]
