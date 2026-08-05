#!/usr/bin/env bash
# team-apply.sh — l'APPLY d'onboarding, APRÈS la décision humaine (le merge).
#
#   merge PR onboard/* → webhook → job team-apply (pause nominative + garde
#   d'identité, cf. le job XML) → CE script :
#     1. ANTI-TOCTOU : checkout de main AU SHA DU MERGE ; l'équipe est lue dans
#        providers.<env>.yml TEL QUE MERGÉ — jamais dans le payload du webhook.
#     2. dépôt Gitea depuis le squelette ADR-076 (token org-admin lu dans Vault,
#        header-file). IDEMPOTENT : dépôt existant → sauté, dit dans le commentaire.
#        repo: "" dans providers → étape sautée (cas payments-team), PAS un échec.
#     3. ansible/onboard-team.yml (rôle idempotent du palier 1).
#     4. commentaire PR : le statut RÉEL, succès comme échec (ADR-081 coroll. 2).
#
# Invocation attendue (miroir de team-request.sh, Task 5/ci/jenkins/team-apply.job.xml) :
#   dir('poc-control-plane-federation') { sh 'bash scripts/team-apply.sh' } — donc
# $0 = "scripts/team-apply.sh" et le `cd "$(dirname "$0")/.."` ci-dessous NE
# BOUGE PAS le cwd (déjà poc-control-plane-federation/, "scripts/.." s'annule).
# Toutes les références de fichier plus bas (PROV, clients/_example, ansible/…)
# sont donc relatives à CE cwd, SANS le préfixe "poc-control-plane-federation/"
# (celui-ci n'a de sens que dans un CLONE FRAIS du dépôt plateforme entier —
# motif utilisé par team-request.sh pour son propre WORK/repo, différent).
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1

PR_BRANCH="${PR_BRANCH:?PR_BRANCH requis}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
MERGE_SHA="${MERGE_SHA:?MERGE_SHA requis (merge_commit_sha du webhook)}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR requis}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE requis (jamais le token en env/argv)}"
APIM_API_BASE="${APIM_API_BASE:?APIM_API_BASE requis — pas de défaut : dire sa cible est volontaire}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
fail(){ comment "❌ team-apply : $*"; echo "ERREUR: $*" >&2; exit 1; }
comment(){ API="${GIT_HOST}/api/v1" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" \
  PR="$PR_NUMBER" BODY="$1" python3 - <<'PY'
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["GITEA_TOKEN"]
req = urllib.request.Request(f"{api}/repos/{repo}/issues/{os.environ['PR']}/comments",
    method="POST", data=json.dumps({"body": os.environ["BODY"]}).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
urllib.request.urlopen(req)
PY
}

# ── 1. équipe et env depuis la branche ; anti-TOCTOU sur le contenu ──────────
case "$PR_BRANCH" in onboard/*) ;; *) echo "hors onboard/* — rien à faire"; exit 0;; esac
REST="${PR_BRANCH#onboard/}"; ENVN="${REST##*-}"; TEAM="${REST%-*}"
[ "$ENVN" = dev ] || fail "ENV_NOT_OPEN : $ENVN"

git fetch -q origin main && git checkout -q "$MERGE_SHA" \
  || fail "checkout du SHA de merge $MERGE_SHA"
PROV="ansible/providers.${ENVN}.yml"
grep -Eq "^  - team: ${TEAM}\$" "$PROV" \
  || fail "TEAM_NOT_IN_MERGED_STATE : ${TEAM} absente de ${PROV} au SHA mergé — le payload ne fait pas foi"
REPO_FULL=$(TEAM="$TEAM" PROV="$PROV" python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["PROV"]))
e = next(p for p in d["providers"] if p["team"] == os.environ["TEAM"])
print(e.get("repo") or "")
PY
)

# ── 2. dépôt Gitea (idempotent ; token org-admin lu dans Vault) ──────────────
REPO_NOTE="dépôt : (repo vide dans providers — étape sautée)"
if [ -n "$REPO_FULL" ]; then
  # ÉCART AU BRIEF (bug corrigé, constaté en direct) : VAULT_TOKEN_FILE contient
  # le token BRUT (ci/lib/vault-login.sh:135-147 — _vault_store_token écrit
  # "token" nu ET "token.hdr" séparément ; seul le premier est exporté sous ce
  # nom, celui que l'apim_common Ansible consomme via lookup('file', …)). Un
  # `curl -H @"$VAULT_TOKEN_FILE"` direct (le texte du brief) n'a AUCUNE ligne
  # "Nom: valeur" à envoyer — le token part sans header, Vault répond 403
  # partout, reproduit en direct sur ce Vault. On construit ici notre PROPRE
  # fichier d'en-tête (même motif que vhdr()/vcurl() ailleurs dans ce dépôt) à
  # partir du contenu brut, sans jamais faire transiter le token par argv/env.
  printf 'X-Vault-Token: %s\n' "$(cat "$VAULT_TOKEN_FILE")" > "$TMP/vthdr"
  curl -s -H @"$TMP/vthdr" "$VAULT_ADDR/v1/secret/data/stoa/ci/gitea-org-admin" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['token'])" > "$TMP/gt" \
    || fail "lecture du token org-admin dans Vault (policy team-onboarder ?)"
  printf 'Authorization: token %s\n' "$(cat "$TMP/gt")" > "$TMP/ghdr"
  ORG="${REPO_FULL%%/*}"; RNAME="${REPO_FULL##*/}"
  gapi(){ curl -s -H @"$TMP/ghdr" -H 'Content-Type: application/json' "$@"; }
  # org : create-or-skip
  RC=$(gapi -o /dev/null -w '%{http_code}' "${GIT_HOST}/api/v1/orgs/${ORG}")
  if [ "$RC" != 200 ]; then
    RC=$(gapi -X POST -d "{\"username\":\"${ORG}\"}" -o "$TMP/err" -w '%{http_code}' "${GIT_HOST}/api/v1/orgs")
    { [ "$RC" = 201 ] || [ "$RC" = 200 ]; } || fail "création org ${ORG} (HTTP $RC)"
  fi
  # repo : create-or-skip, puis squelette si créé
  RC=$(gapi -o /dev/null -w '%{http_code}' "${GIT_HOST}/api/v1/repos/${REPO_FULL}")
  if [ "$RC" = 200 ]; then
    REPO_NOTE="dépôt ${REPO_FULL} : déjà existant, étape sautée (idempotence)"
  else
    RC=$(gapi -X POST -d "{\"name\":\"${RNAME}\",\"auto_init\":false}" -o "$TMP/err" -w '%{http_code}' "${GIT_HOST}/api/v1/orgs/${ORG}/repos")
    [ "$RC" = 201 ] || fail "création dépôt ${REPO_FULL} (HTTP $RC)"
    SK="$TMP/skel"; mkdir -p "$SK"
    cp -R clients/_example/. "$SK/"
    printf '# %s\n\nDépôt d équipe (squelette ADR-076 : apis/, applications/).\nCréé par team-apply au merge de la PR #%s.\n' "$REPO_FULL" "$PR_NUMBER" > "$SK/README.md"
    git -C "$SK" init -q -b main && git -C "$SK" add -A \
      && git -C "$SK" -c user.name=ci -c user.email=ci@stoa.lab commit -qm "squelette ADR-076 (team-apply, PR #${PR_NUMBER})"
    # ÉCART AU BRIEF (bug corrigé, constaté en direct) : le brief (comme
    # team-request.sh/provision-request.sh) met le token dans l'URL
    # (http://x:$TOKEN@host/...) passée en argv à `git push`. Mesuré en
    # direct (ps -Aww pendant un vrai run) : le token org-admin apparaît EN
    # CLAIR dans l'argv du process `git push` ET de son enfant
    # `git-remote-http` pendant toute la durée du push — exactement ce que la
    # preuve 8 du palier (sondage ps -ww) est censée détecter. On passe donc
    # le credential par un HEADER injecté via variables d'ENVIRONNEMENT
    # (GIT_CONFIG_COUNT/KEY/VALUE — jamais argv, jamais visible par `ps -ww`,
    # vérifié en direct par le même sondage) plutôt que dans l'URL ; l'URL
    # elle-même ne porte plus aucun credential.
    AUTH_B64=$(printf 'x:%s' "$(cat "$TMP/gt")" | base64 | tr -d '\n')
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
      GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
      git -C "$SK" push -q "${GIT_HOST}/${REPO_FULL}.git" main 2>"$TMP/pe" \
      || { cat "$TMP/pe" >&2; fail "push du squelette"; }
    unset AUTH_B64
    REPO_NOTE="dépôt ${REPO_FULL} : créé depuis le squelette ADR-076"
  fi
fi

# ── 3. onboarding (rôle du palier 1, idempotent) ─────────────────────────────
( ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
    -e "apim_onb_team=${TEAM}" -e "apim_onb_providers_file=providers.${ENVN}.yml" \
    -e "apim_ss_api_base=${APIM_API_BASE}" \
) >"$TMP/onb.log" 2>&1
ONB_RC=$?

# ── 4. le statut RÉEL sur la PR — succès comme échec ─────────────────────────
if [ "$ONB_RC" -eq 0 ]; then
  SUMMARY=$(grep -oE '(ONBOARD_OK|VERIFY_[A-Z_]+|TEAM_[A-Z_]+|TENANT_ROOT_UNSAFE|KV_[A-Z_]+)[^"]*' "$TMP/onb.log" | tail -3 | tr '\n' ' ')
  comment "✅ team-apply ${TEAM}/${ENVN} — ${REPO_NOTE} ; onboarding : ${SUMMARY:-ONBOARD_OK}"
else
  # ÉCART AU BRIEF (bug corrigé, constaté en direct) : le grep(tags) du brief
  # cherche UNIQUEMENT les marqueurs propres à apim_team_onboard (TEAM_*/KV_*/
  # VERIFY_*/…) — absents quand l'échec vient d'AILLEURS dans la chaîne (ex.
  # apim_common, résolution des creds admin gateway, cf. réserve Vault dans le
  # rapport). Résultat reproduit : le résumé affichait "TEAM_NAME_OK" — le
  # DERNIER tag de succès vu AVANT l'échec réel — sur une PR dont le run a EN
  # RÉALITÉ échoué. Sur échec, on préfère donc le message "msg" du dernier bloc
  # fatal/FAILED! Ansible, jamais un tag OK antérieur ; repli sur tail -3 brut
  # si aucun bloc fatal reconnaissable (même hiérarchie TAGS→brut que
  # team-request.sh §4).
  SUMMARY=$(grep -A6 'fatal:\|FAILED!' "$TMP/onb.log" | grep -oE '"msg":.*' | tail -1 | cut -c1-300)
  [ -n "$SUMMARY" ] || SUMMARY=$(tail -3 "$TMP/onb.log" | tr '\n' ' ')
  comment "❌ team-apply ${TEAM}/${ENVN} — ${REPO_NOTE} ; onboarding EN ÉCHEC : ${SUMMARY:-voir le build}. Re-run possible : tout est idempotent."
  fail "onboarding (voir log du build)"
fi
echo "team-apply OK — ${REPO_NOTE}"
