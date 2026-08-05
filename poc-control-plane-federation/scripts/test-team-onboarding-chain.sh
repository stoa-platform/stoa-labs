#!/usr/bin/env bash
# test-team-onboarding-chain.sh — la matrice de preuve du palier 2 (9 points) :
# la CHAÎNE COMPLÈTE d'onboarding d'équipe en self-service, de la demande
# (formulaire Jenkins → team-request.sh) jusqu'à l'apply post-merge
# (team-apply.sh), sur une équipe JETABLE (probe-p2), rejouable de bout en
# bout sans jamais toucher aux tenants réels (banking-demo, payments-team) —
# sauf pour PROUVER, en lecture seule, que le refus TEAM_ALREADY_DECLARED les
# protège (preuve 2).
#
# ÉCART ASSUMÉ AUX BRIEFS PRÉCÉDENTS, VOULU (motif Task 4, cf. progress.md) :
# les preuves 5-6 invoquent team-apply.sh EN DIRECT, avec l'environnement que
# poserait le webhook Jenkins (PR_BRANCH/PR_NUMBER/MERGE_SHA/…), et NON via le
# job Jenkins `team-apply` — ce job n'est pas posé sur le Jenkins du lab (la
# pause nominative qu'il impose ne s'automatise pas proprement dans un
# harnais). C'est la MÊME preuve, un cran plus bas : le câblage du JOB
# lui-même (garde d'identité appelée avant l'apply, aucune interpolation
# Groovy, …) est couvert séparément par la preuve 4
# (scripts/test-team-apply-wiring.sh, déjà 28/28).
#
# CIBLES OBLIGATOIRES, SANS DÉFAUT — même discipline que
# scripts/test-onboard-team.sh (palier 1) : un défaut vers un système EN
# SERVICE (le port 5555 de la vraie gateway, un Vault de prod, …) ferait qu'un
# lancement distrait écrirait dessus. C'est à qui lance ce script de fournir
# ses cibles :
#   GITEA_URL      base HTTP de la forge du lab (ex. http://localhost:13000)
#   GITEA_TOKEN    token du compte de service `ci` (write:repository,
#                  write:issue — même scope que team-request.sh)
#   VAULT_ADDR     ex. http://localhost:8200
#   VAULT_TOKEN    droits d'amorçage (root du Vault de LAB) — sert UNIQUEMENT
#                  à minter un token ÉPHÉMÈRE mono-policy `team-onboarder`
#                  (voir plus bas) : la preuve nominale tourne avec CE
#                  périmètre restreint, jamais avec le root lui-même — même
#                  discipline que la Task 4 (« mono-policy porte tout le
#                  chemin »).
#   WM_GATEWAY_URL LE MOCK (cd mocks/webmethods && go run .), JAMAIS 5555 —
#                  la vraie gateway du lab, en service.
#   JENKINS_UI     ex. http://localhost:18080 (job app-request, preuve 7)
#
# COMPTE HUMAIN DE MERGE (preuve 5) — ÉCART DÉCLARÉ : ce Gitea de lab ne porte
# qu'un seul compte (`ci`, service, admin) ; il n'y a pas de second compte
# "humain" distinct pour merger la PR. Le merge réel utilise donc GITEA_TOKEN
# lui-même. Ce n'est PAS une lacune de cette preuve : l'identité qui merge et
# celle qui répond à la pause nominative (assert-merge-identity.sh) sont
# testées SÉPARÉMENT et en isolation par la preuve 4 (contre-épreuve directe
# rouge/vert de la garde) — préciser QUI a mergé n'a pas d'incidence sur ce
# que team-apply.sh fait une fois appelé avec un MERGE_SHA donné.
#
# DETTE CONNUE, HORS PÉRIMÈTRE (déclarée par la Task 4, reconduite ici) :
# provision-request.sh porte encore le motif URL-avec-token pour son propre
# `git push` (jamais corrigé — fichier d'une tâche déjà revue). La preuve 8
# (sondage ps) ne l'exerce PAS : la preuve 7 déclenche provision-request.sh
# par le JOB app-request, hors de la fenêtre de sondage (3/5/6 seulement, motif
# exact demandé). Signalé, pas corrigé ici.
set -uo pipefail
set +x   # jamais de trace : des tokens transitent par ce script
cd "$(dirname "$0")/.." || exit 1

GITEA_URL="${GITEA_URL:?GITEA_URL requis (ex. http://localhost:13000) — aucun défaut, jamais deviner la forge}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis (compte ci, write:repository,write:issue,write:organization — les deux premiers scopes de team-request.sh, PLUS write:organization : sans lui, DELETE sur un org rend 403 (mesure directe) et GET sur un org absent rend 403 au lieu de 404, ce qui casse la preuve 9)}"
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR requis}"
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis (amorçage — sert à minter un token éphémère mono-policy team-onboarder, jamais utilisé tel quel par team-apply.sh)}"
WM_GATEWAY_URL="${WM_GATEWAY_URL:?WM_GATEWAY_URL requis, SANS DÉFAUT. Le port 5555 est la VRAIE gateway du lab, en service — un défaut qui le viserait exposerait ce harnais à écrire dessus. cd mocks/webmethods && go run . puis WM_GATEWAY_URL=http://localhost:PORT.}"
JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis (ex. http://localhost:18080) — preuve 7, job app-request}"

GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
TEAM="probe-p2"
APP7="p2t8appreq"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

TMP="$(mktemp -d)"; chmod 700 "$TMP"

# ── helpers header-file (ADR-074) : le token part TOUJOURS par un fichier
# 0600, jamais en argv/env visible par ps — même motif que team-request.sh
# (vhdr) et team-apply.sh. ------------------------------------------------
vhdr() { local f; f="$(mktemp "$TMP/vhdr.XXXXXX")"; chmod 600 "$f"; printf 'X-Vault-Token: %s\n' "$1" > "$f"; printf '%s' "$f"; }
vlt()  { curl -s -H @"$(vhdr "$1")" "$VAULT_ADDR/v1/$2" -o /dev/null -w '%{http_code}'; }
ghdr() { local f; f="$(mktemp "$TMP/ghdr.XXXXXX")"; chmod 600 "$f"; printf 'Authorization: token %s\n' "$1" > "$f"; printf '%s' "$f"; }
gapi() { curl -s -H @"$(ghdr "$GITEA_TOKEN")" "$@"; }
wmapi(){ curl -s -u Administrator:manage -H 'Accept: application/json' "$WM_GATEWAY_URL/rest/apigateway/$1"; }

# ── token ÉPHÉMÈRE mono-policy team-onboarder, minté depuis VAULT_TOKEN ─────
# La preuve nominale (5/6) doit tourner avec LE PÉRIMÈTRE RÉEL de l'apply, pas
# avec le root — sinon elle ne prouverait rien sur ce que team-apply.sh peut
# réellement faire en production (même discipline que task-4-report.md :
# « la preuve que team-onboarder porte tout le chemin »).
TOK_ONBOARDER=$(curl -s -H @"$(vhdr "$VAULT_TOKEN")" -X POST \
  -d '{"policies":["team-onboarder"],"ttl":"20m","no_default_policy":true}' \
  "$VAULT_ADDR/v1/auth/token/create" | python3 -c "import json,sys; print(json.load(sys.stdin).get('auth',{}).get('client_token',''))" 2>/dev/null)
[ -n "$TOK_ONBOARDER" ] || { echo "impossible de minter le token éphémère team-onboarder (policy absente ? cf. scripts/setup-team-onboard-prereqs.sh) — abandon" >&2; exit 2; }
VAULT_TOKEN_FILE_ONBOARDER="$TMP/vtok-onboarder"
printf '%s' "$TOK_ONBOARDER" > "$VAULT_TOKEN_FILE_ONBOARDER"; chmod 600 "$VAULT_TOKEN_FILE_ONBOARDER"

# ── baseline de main : providers.dev.yml TEL QU'IL EST avant toute mutation,
# pour un revert bit-à-bit en teardown (discipline Task 4/T7 : main ne doit
# jamais finir sale). ---------------------------------------------------------
git clone -q --depth 1 -b main "$GITEA_URL/$GIT_REPO.git" "$TMP/baseline" \
  || { echo "clone baseline de $GIT_REPO impossible — $GITEA_URL joignable ?" >&2; exit 2; }
cp "$TMP/baseline/poc-control-plane-federation/ansible/providers.dev.yml" "$TMP/providers.dev.yml.baseline"

# ── classification, MESURÉE (pas supposée) : la cible WM_GATEWAY_URL expose-
# t-elle un DELETE sur ses objets Teams ? mocks/webmethods/server.go ne
# déclare AUCUNE route DELETE (grep -n DELETE ne remonte rien) — constaté en
# direct : 405 Method Not Allowed sur un groupe jetable créé puis supprimé.
# C'est un manque STRUCTUREL du mock autonome, déjà rencontré par la Task 4
# (« Mock gateway : process arrêté … pas de nettoyage d'objets à faire côté
# mock ») — pas une régression de ce palier. Contre une VRAIE gateway wM,
# DELETE existe : la preuve 9 doit donc exiger l'absence des objets SEULEMENT
# quand la cible le permet, jamais fermer les yeux dessus sans le dire.
WM_DELETE_SUPPORTED=false
_PROBE_GID=$(curl -s -u Administrator:manage -X POST -H 'Content-Type: application/json' \
  -d '{"name":"t8-delete-probe","description":"sonde capacite DELETE"}' \
  "$WM_GATEWAY_URL/rest/apigateway/groups" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
if [ -n "$_PROBE_GID" ]; then
  _PROBE_HC=$(curl -s -u Administrator:manage -X DELETE "$WM_GATEWAY_URL/rest/apigateway/groups/$_PROBE_GID" -o /dev/null -w '%{http_code}')
  if [ "$_PROBE_HC" = 200 ] || [ "$_PROBE_HC" = 204 ]; then
    WM_DELETE_SUPPORTED=true
  fi
fi
unset _PROBE_GID _PROBE_HC
echo "   (sonde DELETE gateway : ${WM_GATEWAY_URL} -> WM_DELETE_SUPPORTED=$WM_DELETE_SUPPORTED)"

# ── teardown : UNE SEULE implémentation, appelée par la preuve 9 (qui en
# vérifie l'effet) ET par le trap (filet de secours) — même motif que
# team-request.sh. ------------------------------------------------------------
teardown() {
  local pid gid uid_
  pid=$(wmapi accessProfiles | python3 -c "
import json,sys
print(next((p['id'] for p in json.load(sys.stdin).get('accessProfiles',[]) if p.get('name')=='$TEAM'), ''))" 2>/dev/null)
  gid=$(wmapi groups | python3 -c "
import json,sys
print(next((g['id'] for g in json.load(sys.stdin).get('groups',[]) if g.get('name')=='$TEAM-devs'), ''))" 2>/dev/null)
  uid_=$(wmapi users | python3 -c "
import json,sys
print(next((u['id'] for u in json.load(sys.stdin).get('users',[]) if u.get('loginId')=='svc-$TEAM'), ''))" 2>/dev/null)
  [ -n "$pid" ] && curl -s -u Administrator:manage -X DELETE "$WM_GATEWAY_URL/rest/apigateway/accessProfiles/$pid" -o /dev/null
  [ -n "$gid" ] && curl -s -u Administrator:manage -X DELETE "$WM_GATEWAY_URL/rest/apigateway/groups/$gid" -o /dev/null
  [ -n "$uid_" ] && curl -s -u Administrator:manage -X DELETE "$WM_GATEWAY_URL/rest/apigateway/users/$uid_" -o /dev/null

  curl -s -H @"$(vhdr "$VAULT_TOKEN")" -X DELETE "$VAULT_ADDR/v1/secret/metadata/stoa/deploy/$TEAM/wm-admin" -o /dev/null
  curl -s -H @"$(vhdr "$VAULT_TOKEN")" -X DELETE "$VAULT_ADDR/v1/sys/policies/acl/deploy-$TEAM" -o /dev/null

  gapi -X DELETE "$GITEA_URL/api/v1/repos/$TEAM/apis" -o /dev/null
  gapi -X DELETE "$GITEA_URL/api/v1/orgs/$TEAM" -o /dev/null
  gapi -X DELETE "$GITEA_URL/api/v1/repos/$GIT_REPO/branches/onboard/${TEAM}-dev" -o /dev/null

  if [ -n "${PR7_NUM:-}" ]; then
    gapi -X PATCH -H 'Content-Type: application/json' -d '{"state":"closed"}' \
      "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls/$PR7_NUM" -o /dev/null
  fi
  gapi -X DELETE "$GITEA_URL/api/v1/repos/$GIT_REPO/branches/provision/${APP7}-dev" -o /dev/null

  restore_main_providers
}

restore_main_providers() {
  local work="$TMP/restore-main" prov
  rm -rf "$work"
  git clone -q --depth 1 -b main "$GITEA_URL/$GIT_REPO.git" "$work" 2>/dev/null || return 0
  prov="$work/poc-control-plane-federation/ansible/providers.dev.yml"
  [ -f "$prov" ] || return 0
  if ! cmp -s "$TMP/providers.dev.yml.baseline" "$prov"; then
    cp "$TMP/providers.dev.yml.baseline" "$prov"
    git -C "$work" -c user.name=ci -c user.email=ci@stoa.lab add poc-control-plane-federation/ansible/providers.dev.yml
    if ! git -C "$work" diff --cached --quiet; then
      git -C "$work" -c user.name=ci -c user.email=ci@stoa.lab commit -qm \
        "revert(onboard): purge de l'entrée jetable ${TEAM} de providers.dev.yml (test-team-onboarding-chain.sh)"
      local b64; b64=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
        GIT_CONFIG_VALUE_0="Authorization: Basic ${b64}" \
        git -C "$work" push -q "$GITEA_URL/$GIT_REPO.git" HEAD:main 2>"$TMP/revertpush.err" \
        || echo "  ATTENTION : revert de main (providers.dev.yml) a échoué — voir $TMP/revertpush.err" >&2
    fi
  fi
}

cleanup_exit() {
  [ -n "${SAMPLER_PID:-}" ] && kill "$SAMPLER_PID" 2>/dev/null; wait "${SAMPLER_PID:-}" 2>/dev/null
  teardown >/dev/null 2>&1
  curl -s -H @"$(vhdr "$TOK_ONBOARDER")" -X POST "$VAULT_ADDR/v1/auth/token/revoke-self" -o /dev/null 2>/dev/null
  [ -f "$TMP/team-request.sh.orig" ] && cp "$TMP/team-request.sh.orig" scripts/team-request.sh 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup_exit EXIT

echo "== chaîne d'onboarding d'équipe (palier 2) — équipe jetable $TEAM =="
echo "   Gitea=$GITEA_URL  Vault=$VAULT_ADDR  gateway(mock)=$WM_GATEWAY_URL  Jenkins=$JENKINS_UI"
echo

# ─────────────────────────────────────────────────────────────────────────────
# 1. gardes d'entrée team-request.sh — évasion de chemin / newline interne
# ─────────────────────────────────────────────────────────────────────────────
echo "== 1. gardes d'entrée (TEAM='../evil', TEAM=\$'a\\nb') — rc≠0, onboard/* inchangé =="
BEFORE1=$(git ls-remote "$GITEA_URL/$GIT_REPO.git" 'refs/heads/onboard/*' 2>/dev/null)

TEAM='../evil' REQ_ENV=dev GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" \
  bash scripts/team-request.sh >"$TMP/p1a.log" 2>&1
R1A=$?
TEAM=$'a\nb' REQ_ENV=dev GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" \
  bash scripts/team-request.sh >"$TMP/p1b.log" 2>&1
R1B=$?

AFTER1=$(git ls-remote "$GITEA_URL/$GIT_REPO.git" 'refs/heads/onboard/*' 2>/dev/null)
if [ "$R1A" -ne 0 ] && [ "$R1B" -ne 0 ] && [ "$BEFORE1" = "$AFTER1" ]; then
  ok "1. TEAM='../evil' (rc=$R1A) et TEAM=\$'a\\nb' (rc=$R1B) refusés, onboard/* inchangé sur le dépôt distant"
else
  bad "1. rc1=$R1A rc2=$R1B ls-remote identique=$([ "$BEFORE1" = "$AFTER1" ] && echo oui || echo NON) — voir $TMP/p1?.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. TEAM_ALREADY_DECLARED — équipe déjà déclarée (banking-demo), aucune PR
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 2. refus TEAM_ALREADY_DECLARED (banking-demo) — aucune PR nouvelle =="
PRS_BEFORE=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls?state=all&limit=200" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))" 2>/dev/null)
TEAM=banking-demo REQ_ENV=dev GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" \
  bash scripts/team-request.sh >"$TMP/p2.log" 2>&1
R2=$?
PRS_AFTER=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls?state=all&limit=200" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))" 2>/dev/null)
if [ "$R2" -ne 0 ] && grep -q TEAM_ALREADY_DECLARED "$TMP/p2.log" && [ "${PRS_BEFORE:-x}" = "${PRS_AFTER:-y}" ]; then
  ok "2. TEAM_ALREADY_DECLARED (banking-demo), $PRS_BEFORE PR avant/après (aucune nouvelle)"
else
  bad "2. rc=$R2 PRavant=$PRS_BEFORE PRapres=$PRS_AFTER — voir $TMP/p2.log"
fi

# ── Step 2 (contre-épreuve du harnais) : casse le TAG que la preuve 2
# reconnaît, vérifie que la preuve 2 rougirait, restaure. Un harnais jamais vu
# rouge est le défaut n°1 de ce dépôt (cf. progress.md). ─────────────────────
echo
echo "== Step 2 : le harnais sait rougir (contre-épreuve de la preuve 2) =="
cp scripts/team-request.sh "$TMP/team-request.sh.orig"
sed -i '' 's/TEAM_ALREADY_DECLARED/EQUIPE_DEJA_DECLAREE_CASSEE_PAR_LE_HARNAIS/' scripts/team-request.sh
TEAM=banking-demo REQ_ENV=dev GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" \
  bash scripts/team-request.sh >"$TMP/redcheck.log" 2>&1
RRED=$?
cp "$TMP/team-request.sh.orig" scripts/team-request.sh
if ! git diff --quiet -- scripts/team-request.sh 2>/dev/null; then
  echo "  ATTENTION : scripts/team-request.sh ne revient pas identique après restauration" >&2
fi
if [ "$RRED" -ne 0 ] && ! grep -q TEAM_ALREADY_DECLARED "$TMP/redcheck.log"; then
  ok "Step 2. tag renommé → le critère de la preuve 2 rougit (rc=$RRED, tag absent du log), fichier restauré identique"
else
  bad "Step 2. la contre-épreuve n'a PAS rougi — le harnais ne détecterait pas une régression ici (rc=$RRED)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. TEAM=probe-p2 nominal — PR ouverte, PLAN OK, les 4 dérivations
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 3. TEAM=$TEAM nominal — PR ouverte, PLAN OK, dérivations =="
# sondage ps -Aww continu (preuves 3/5/6, motif Task 4) — token en argv ?
PSLOG="$TMP/pslog"; : > "$PSLOG"
( while :; do ps -Aww >>"$PSLOG" 2>/dev/null; sleep 0.02; done ) & SAMPLER_PID=$!

TEAM="$TEAM" DESCRIPTION="equipe jetable de preuve (test-team-onboarding-chain.sh)" REQ_ENV=dev \
  GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" \
  bash scripts/team-request.sh >"$TMP/p3.log" 2>&1
R3=$?
PR_ONBOARD_NUM=$(grep -oE 'PR #[0-9]+ ouverte' "$TMP/p3.log" | grep -oE '[0-9]+' | head -1)
CBODY3=""
[ -n "${PR_ONBOARD_NUM:-}" ] && CBODY3=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/issues/${PR_ONBOARD_NUM}/comments" \
  | python3 -c "import json,sys; c=json.load(sys.stdin); print(c[-1]['body'] if c else '')" 2>/dev/null)

if [ "$R3" -eq 0 ] && [ -n "${PR_ONBOARD_NUM:-}" ] \
   && printf '%s' "$CBODY3" | grep -q 'PLAN OK' \
   && printf '%s' "$CBODY3" | grep -q "user=svc-$TEAM" \
   && printf '%s' "$CBODY3" | grep -q "groupe=$TEAM-devs" \
   && printf '%s' "$CBODY3" | grep -q "kv=deploy/$TEAM/wm-admin" \
   && printf '%s' "$CBODY3" | grep -q "policy=deploy-$TEAM"; then
  ok "3. PR #$PR_ONBOARD_NUM ouverte, commentaire PLAN OK avec les 4 dérivations (svc-$TEAM, $TEAM-devs, deploy/$TEAM/wm-admin, deploy-$TEAM)"
else
  bad "3. rc=$R3 PR=${PR_ONBOARD_NUM:-absente} commentaire=$(printf '%s' "$CBODY3" | head -c200) — voir $TMP/p3.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. câblage team-apply.job.xml + garde d'identité (contre-épreuve directe)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 4. câblage (test-team-apply-wiring.sh) + garde d'identité rouge/vert =="
bash scripts/test-team-apply-wiring.sh >"$TMP/p4wiring.log" 2>&1
R4W=$?
sh scripts/lib/assert-merge-identity.sh --merged-by ci --requester x --vault-user oscar >"$TMP/p4red.log" 2>&1
R4RED=$?
sh scripts/lib/assert-merge-identity.sh --merged-by oscar --requester ci --vault-user oscar >"$TMP/p4green.log" 2>&1
R4GREEN=$?
WIRING_TAIL=$(tail -1 "$TMP/p4wiring.log" 2>/dev/null)
if [ "$R4W" -eq 0 ] && [ "$R4RED" -ne 0 ] && grep -q MERGER_MISMATCH "$TMP/p4red.log" \
   && [ "$R4GREEN" -eq 0 ] && grep -q MERGE_IDENTITY_OK "$TMP/p4green.log"; then
  ok "4. câblage XML ($WIRING_TAIL), garde rouge=MERGER_MISMATCH (--merged-by ci --vault-user oscar), garde verte=MERGE_IDENTITY_OK"
else
  bad "4. wiring_rc=$R4W ($WIRING_TAIL) red_rc=$R4RED green_rc=$R4GREEN — voir $TMP/p4*.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. merge réel de la PR + team-apply.sh EN DIRECT (env webhook simulé)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 5. merge de la PR #$PR_ONBOARD_NUM + team-apply.sh EN DIRECT =="
UID_BEFORE=$(wmapi users | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((u['id'] for u in d.get('users',[]) if u.get('loginId')=='svc-$TEAM'),''))" 2>/dev/null)
GID_BEFORE=$(wmapi groups | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((g['id'] for g in d.get('groups',[]) if g.get('name')=='$TEAM-devs'),''))" 2>/dev/null)
PID_BEFORE=$(wmapi accessProfiles | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((p['id'] for p in d.get('accessProfiles',[]) if p.get('name')=='$TEAM'),''))" 2>/dev/null)
KV_BEFORE=$(vlt "$TOK_ONBOARDER" "secret/data/stoa/deploy/$TEAM/wm-admin")
REPO_BEFORE=$(gapi -o /dev/null -w '%{http_code}' "$GITEA_URL/api/v1/repos/$TEAM/apis")

# Gitea calcule `mergeable` de façon ASYNCHRONE juste après l'ouverture d'une
# PR (constaté en direct : 405 Method Not Allowed si le merge est tenté avant
# la fin de ce calcul, converge vers `mergeable=true` en ~1s sur ce lab) — pas
# une panne, une caractéristique de Gitea. On attend le feu vert plutôt que de
# deviner un délai fixe.
MERGEABLE=false; DEADLINE_M=$(( $(date +%s) + 15 ))
while [ "$(date +%s)" -lt "$DEADLINE_M" ]; do
  MERGEABLE=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls/${PR_ONBOARD_NUM:-0}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('mergeable') or False)" 2>/dev/null)
  [ "$MERGEABLE" = True ] && break
  sleep 0.5
done

MERGE_HC=$(gapi -X POST -H 'Content-Type: application/json' -d '{"Do":"merge"}' \
  -o "$TMP/mergebody" -w '%{http_code}' "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls/${PR_ONBOARD_NUM:-0}/merge")
MERGE_SHA=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls/${PR_ONBOARD_NUM:-0}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('merge_commit_sha') or '')" 2>/dev/null)

# team-apply.sh fait `git fetch origin main && git checkout $MERGE_SHA` (anti-
# TOCTOU) — motif VALIDE dans un job Jenkins réel, qui clone TOUJOURS FRAÎCHEMENT
# depuis Gitea sous le nom "origin". CE worktree-ci n'est PAS ce clone : son
# "origin" est le dépôt de développement (GitHub), et "gitea" est un remote
# séparé — constaté en direct (`fatal: reference is not a tree`). On peuple
# donc l'objet localement en amont, par une URL anonyme (jamais besoin de
# connaître le nom du remote) : le `git fetch origin main` interne de
# team-apply.sh continue de tourner (inoffensif, il ira chercher le mauvais
# dépôt) mais le `git checkout $MERGE_SHA` qui suit trouve l'objet déjà présent
# dans l'ODB local, quel que soit le remote qui l'y a mis.
git fetch -q "$GITEA_URL/$GIT_REPO.git" main \
  || echo "  ATTENTION : pré-fetch du SHA de merge en échec — team-apply.sh va probablement échouer au checkout" >&2

rm -f "$TMP/run5.anslog"
PR_BRANCH="onboard/${TEAM}-dev" PR_NUMBER="${PR_ONBOARD_NUM:-0}" MERGE_SHA="$MERGE_SHA" \
  GITEA_TOKEN="$GITEA_TOKEN" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VAULT_TOKEN_FILE_ONBOARDER" \
  APIM_API_BASE="${WM_GATEWAY_URL}/rest/apigateway" GIT_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" GIT_WEB_HOST="$GITEA_URL" \
  ANSIBLE_LOG_PATH="$TMP/run5.anslog" \
  bash scripts/team-apply.sh >"$TMP/p5.log" 2>&1
R5=$?

UID_AFTER=$(wmapi users | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((u['id'] for u in d.get('users',[]) if u.get('loginId')=='svc-$TEAM'),''))" 2>/dev/null)
GID_AFTER=$(wmapi groups | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((g['id'] for g in d.get('groups',[]) if g.get('name')=='$TEAM-devs'),''))" 2>/dev/null)
PID_AFTER=$(wmapi accessProfiles | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((p['id'] for p in d.get('accessProfiles',[]) if p.get('name')=='$TEAM'),''))" 2>/dev/null)
KV_AFTER=$(vlt "$TOK_ONBOARDER" "secret/data/stoa/deploy/$TEAM/wm-admin")
REPO_AFTER=$(gapi -o /dev/null -w '%{http_code}' "$GITEA_URL/api/v1/repos/$TEAM/apis")
CBODY5=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/issues/${PR_ONBOARD_NUM:-0}/comments" \
  | python3 -c "import json,sys; c=json.load(sys.stdin); print(c[-1]['body'] if c else '')" 2>/dev/null)

if [ "$MERGE_HC" = 200 ] && [ "$R5" -eq 0 ] \
   && [ "$REPO_BEFORE" != 200 ] && [ "$REPO_AFTER" = 200 ] \
   && [ -z "$UID_BEFORE" ] && [ -n "$UID_AFTER" ] \
   && [ -z "$GID_BEFORE" ] && [ -n "$GID_AFTER" ] \
   && [ -z "$PID_BEFORE" ] && [ -n "$PID_AFTER" ] \
   && [ "$KV_BEFORE" != 200 ] && [ "$KV_AFTER" = 200 ] \
   && printf '%s' "$CBODY5" | grep -q '✅' && printf '%s' "$CBODY5" | grep -q ONBOARD_OK; then
  ok "5. merge HTTP $MERGE_HC (sha ${MERGE_SHA:0:8}), team-apply.sh direct : dépôt $TEAM/apis 404→200, objets gateway créés, KV 404→200, commentaire ✅ ONBOARD_OK"
else
  bad "5. merge_hc=$MERGE_HC rc5=$R5 repo:${REPO_BEFORE}->${REPO_AFTER} uid:${UID_BEFORE:-vide}->${UID_AFTER:-vide} gid:${GID_BEFORE:-vide}->${GID_AFTER:-vide} pid:${PID_BEFORE:-vide}->${PID_AFTER:-vide} kv:${KV_BEFORE}->${KV_AFTER} — voir $TMP/p5.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. re-run team-apply.sh à l'identique — idempotence ET convergence du rôle
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 6. re-run team-apply.sh identique — déjà existant, rôle changed=0 =="
rm -f "$TMP/run6.anslog"
PR_BRANCH="onboard/${TEAM}-dev" PR_NUMBER="${PR_ONBOARD_NUM:-0}" MERGE_SHA="$MERGE_SHA" \
  GITEA_TOKEN="$GITEA_TOKEN" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VAULT_TOKEN_FILE_ONBOARDER" \
  APIM_API_BASE="${WM_GATEWAY_URL}/rest/apigateway" GIT_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" GIT_WEB_HOST="$GITEA_URL" \
  ANSIBLE_LOG_PATH="$TMP/run6.anslog" \
  bash scripts/team-apply.sh >"$TMP/p6.log" 2>&1
R6=$?

# fin de la fenêtre de sondage ps -Aww (preuves 3/5/6) — arrêté ICI, avant la
# lecture des résultats, jamais avant.
kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; unset SAMPLER_PID

CH6=$(grep -o 'changed=[0-9]*' "$TMP/run6.anslog" 2>/dev/null | tail -1 | cut -d= -f2)
if [ "$R6" -eq 0 ] && grep -q 'déjà existant' "$TMP/p6.log" && [ "${CH6:-1}" = 0 ] \
   && [ "$REPO_BEFORE" != 200 ] && [ "$REPO_AFTER" = 200 ]; then
  ok "6. re-run : \"déjà existant, étape sautée\" ; rôle changed=$CH6 — ET le run 5 avait réellement créé (dépôt 404→200 mesuré ci-dessus)"
else
  bad "6. rc=$R6 changed=${CH6:-?} (attendu 0) repo_before=$REPO_BEFORE(attendu≠200) repo_after=$REPO_AFTER(attendu 200) — voir $TMP/p6.log et $TMP/run6.anslog"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. job app-request (REQ_MODE additif, via MODE=internal) — l'aval existant
#    (provision-plan) prend le relais
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 7. job app-request MODE=internal → PR provision/* (aval provision-plan) =="
CJ=$(curl -sf -c "$TMP/jck" "$JENKINS_UI/crumbIssuer/api/json" 2>/dev/null)
if [ -n "${CJ:-}" ]; then
  JF=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])')
  JC=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumb"])')
  N=$(curl -sf "$JENKINS_UI/job/app-request/api/json" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])' 2>/dev/null)
  HC7=$(curl -s -b "$TMP/jck" -X POST "$JENKINS_UI/job/app-request/buildWithParameters" \
    -H "$JF: $JC" \
    --data-urlencode "APP=$APP7" --data-urlencode "REQ_ENV=dev" \
    --data-urlencode "API=accounts-api" --data-urlencode "API_VER=1.0.0" \
    --data-urlencode "CLIENT_ID=" --data-urlencode "MODE=internal" \
    -o /dev/null -w '%{http_code}')
  R7=""; DEADLINE=$(( $(date +%s) + 120 ))
  while [ -n "$N" ] && [ "$(date +%s)" -lt "$DEADLINE" ]; do
    R7=$(curl -sf "$JENKINS_UI/job/app-request/$N/api/json" 2>/dev/null \
      | python3 -c 'import sys,json;b=json.load(sys.stdin);print(b.get("result") or "")' 2>/dev/null || true)
    [ -n "$R7" ] && break
    sleep 3
  done
  PR7_NUM=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls?state=open&limit=50" | python3 -c "
import json,sys
for pr in json.load(sys.stdin):
    if pr.get('head',{}).get('ref')=='provision/${APP7}-dev':
        print(pr['number']); break" 2>/dev/null)
  if [ "$HC7" = 201 ] && [ "$R7" = SUCCESS ] && [ -n "${PR7_NUM:-}" ]; then
    ok "7. job app-request(MODE=internal) build #$N SUCCESS, PR provision/${APP7}-dev #$PR7_NUM ouverte"
  else
    bad "7. build_http=$HC7 build_result=$R7 PR7=${PR7_NUM:-absente} — voir $JENKINS_UI/job/app-request/${N:-?}/console"
  fi
else
  bad "7. Jenkins injoignable ($JENKINS_UI) — crumbIssuer KO"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. sondage ps -Aww (preuves 3/5/6) — aucun token en argv
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 8. sondage ps -Aww continu (preuves 3/5/6) — aucun token en argv =="
printf '%s\n' "$GITEA_TOKEN" > "$TMP/needle-gitea"; chmod 600 "$TMP/needle-gitea"
printf '%s\n' "$TOK_ONBOARDER" > "$TMP/needle-vault"; chmod 600 "$TMP/needle-vault"
# les deux tokens que CE harnais connaît explicitement (GITEA_TOKEN, le token
# Vault éphémère mono-policy). Le token org-admin Gitea que team-apply.sh lit
# depuis Vault en interne n'est PAS extrait ici (ce script n'a aucune raison
# légitime de le connaître) : on le couvre par un motif GÉNÉRIQUE — toute URL
# de la forme http://user:secret@host, la signature exacte du bug corrigé par
# la Task 4 (GIT_CONFIG_* remplace précisément cette forme) — plus fort qu'un
# grep sur une valeur connue, puisqu'il détecterait N'IMPORTE QUEL credential
# embarqué dans une URL de push, pas seulement les deux que nous possédons.
LINES=$(wc -l < "$PSLOG" 2>/dev/null | tr -d ' ')
HITS_G=$(grep -cFf "$TMP/needle-gitea" "$PSLOG" 2>/dev/null || true)
HITS_V=$(grep -cFf "$TMP/needle-vault" "$PSLOG" 2>/dev/null || true)
HITS_URL=$(grep -cE 'https?://[A-Za-z0-9_.%-]+:[^@[:space:]]+@[A-Za-z0-9_.-]+' "$PSLOG" 2>/dev/null || true)
if [ "${LINES:-0}" -gt 0 ] && [ "${HITS_G:-0}" -eq 0 ] && [ "${HITS_V:-0}" -eq 0 ] && [ "${HITS_URL:-0}" -eq 0 ]; then
  ok "8. 0 occurrence en argv sur $LINES lignes de ps échantillonnées (GITEA_TOKEN, token Vault éphémère, ET motif générique user:secret@host)"
else
  bad "8. GITEA_TOKEN×$HITS_G  token-Vault×$HITS_V  motif-URL-générique×$HITS_URL (sur $LINES lignes) — RÉGRESSION réelle si non nul, voir $PSLOG"
fi
echo "  (hors périmètre, dette déclarée par la Task 4 : provision-request.sh porte encore le motif URL-avec-token pour son propre git push — non modifié par ce palier, non sondé ici car déclenché par le job de la preuve 7, hors fenêtre 3/5/6)"

# ─────────────────────────────────────────────────────────────────────────────
# 9. teardown symétrique — org, dépôt, PR, branche, KV, policy, objets gateway
#    — puis relecture : rien d'orphelin
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 9. teardown symétrique — rien d'orphelin =="
teardown
sleep 1   # laisser Gitea/Vault/gateway digérer les suppressions avant relecture

RC_REPO=$(gapi -o /dev/null -w '%{http_code}' "$GITEA_URL/api/v1/repos/$TEAM/apis")
RC_ORG=$(gapi -o /dev/null -w '%{http_code}' "$GITEA_URL/api/v1/orgs/$TEAM")
RC_KV=$(vlt "$VAULT_TOKEN" "secret/data/stoa/deploy/$TEAM/wm-admin")
RC_POL=$(vlt "$VAULT_TOKEN" "sys/policies/acl/deploy-$TEAM")
UID_GONE=$(wmapi users | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((u['id'] for u in d.get('users',[]) if u.get('loginId')=='svc-$TEAM'),''))" 2>/dev/null)
GID_GONE=$(wmapi groups | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((g['id'] for g in d.get('groups',[]) if g.get('name')=='$TEAM-devs'),''))" 2>/dev/null)
PID_GONE=$(wmapi accessProfiles | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((p['id'] for p in d.get('accessProfiles',[]) if p.get('name')=='$TEAM'),''))" 2>/dev/null)
PR7_STATE=""
[ -n "${PR7_NUM:-}" ] && PR7_STATE=$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls/${PR7_NUM}" | python3 -c "import json,sys;print(json.load(sys.stdin).get('state','?'))" 2>/dev/null)
rm -rf "$TMP/verifymain"
git clone -q --depth 1 -b main "$GITEA_URL/$GIT_REPO.git" "$TMP/verifymain" 2>/dev/null
PROV_DIFF=DIFF
cmp -s "$TMP/providers.dev.yml.baseline" "$TMP/verifymain/poc-control-plane-federation/ansible/providers.dev.yml" 2>/dev/null && PROV_DIFF=same

# objets gateway : exigés ABSENTS seulement si la cible expose un DELETE (sonde
# faite au démarrage, WM_DELETE_SUPPORTED) — mocks/webmethods n'en a AUCUN
# (grep -n DELETE server.go : rien), limite déjà rencontrée et acceptée par la
# Task 4 (« process arrêté, état en mémoire perdu avec lui — pas de nettoyage
# d'objets à faire côté mock »). Fermer les yeux dessus SANS le dire serait un
# faux vert ; l'exiger contre une cible qui ne peut structurellement pas le
# satisfaire serait un faux rouge. On mesure, on ne suppose pas.
GW_OK=1
if [ "$WM_DELETE_SUPPORTED" = true ]; then
  [ -z "$UID_GONE" ] && [ -z "$GID_GONE" ] && [ -z "$PID_GONE" ] || GW_OK=0
fi

if [ "$RC_REPO" = 404 ] && [ "$RC_ORG" = 404 ] && [ "$RC_KV" != 200 ] && [ "$RC_POL" != 200 ] \
   && [ "$GW_OK" = 1 ] \
   && [ "$PROV_DIFF" = same ] \
   && { [ -z "${PR7_NUM:-}" ] || [ "$PR7_STATE" = closed ]; }; then
  if [ "$WM_DELETE_SUPPORTED" = true ]; then
    ok "9. teardown symétrique : org/dépôt/policy/KV/objets gateway absents, main.providers.dev.yml restauré identique à l'entrée, PR provision fermée"
  else
    ok "9. teardown symétrique : org/dépôt/policy/KV absents, main.providers.dev.yml restauré identique à l'entrée, PR provision fermée — objets gateway du mock NON vérifiés absents (mock sans route DELETE, limite structurelle déjà actée Task 4 ; état en mémoire, perdu si le process mock est redémarré)"
  fi
else
  bad "9. résidus : repo=$RC_REPO org=$RC_ORG kv=$RC_KV pol=$RC_POL uid=${UID_GONE:-vide} gid=${GID_GONE:-vide} pid=${PID_GONE:-vide} providers=$PROV_DIFF pr7=${PR7_STATE:-n/a} (WM_DELETE_SUPPORTED=$WM_DELETE_SUPPORTED)"
fi

echo
echo "== $PASS PASS / $FAIL FAIL =="
[ "$FAIL" -eq 0 ]
