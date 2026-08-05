#!/usr/bin/env bash
# test-api-request.sh — preuve X/X de la Task 5 (P3) : scripts/api-request.sh
# (la porte du PRODUCTEUR) + ci/jenkins/api-request.job.xml.
#
#   Section A — gardes d'entrée (HORS LIGNE, AVANT tout geste Git). GIT_HOST
#     volontairement injoignable : un refus AVANT le message "[1/5]" prouve
#     qu'aucun réseau n'a été touché.
#   Section B — résolution team -> repo (TEAM_NOT_DECLARED, REPO_MANQUANT,
#     REPO_INACCESSIBLE, API_ALREADY_EXISTS, API_BASE_NOT_FOUND,
#     API_BASE_STALE), contre des dépôts bare LOCAUX (motif de
#     test-generate-choices.sh : `git clone` accepte un chemin fichier comme
#     n'importe quelle URL) — aucun Gitea réel requis, contre-épreuve
#     `ls-remote` inchangé après chaque refus.
#   Section C — extraction du verdict PLAN (fatal > msg > tail-3), rejouée
#     contre la fixture E1 réelle (ansible/tests/e1/manifest-crossteam.yml) :
#     preuve directe que la hiérarchie de diagnostic produit un message
#     exploitable, pas juste un ❌ muet.
#   Section D — nominal E2E contre le VRAI Gitea du lab (localhost:13000) :
#     org+dépôt plateforme ET org+dépôt d'équipe SCRATCH (jetables,
#     timestampés, jamais ci/stoa-labs ni un tenant réel), mode create PUIS
#     new-version (après merge du create — new-version lit MAIN, jamais une
#     branche non mergée : ADR-081, la décision reste le merge). Nettoyé en
#     fin de run (DELETE repos + orgs).
#
#   GITEA_TOKEN_FILE=<fichier 0600, scopes write:repository,write:issue,
#     write:organization> ./scripts/test-api-request.sh
#   (défaut : mint un token jetable via `docker exec -u git poc-gitea ...`
#   si GITEA_TOKEN_FILE est absent ET que le conteneur poc-gitea existe.)
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO/scripts/api-request.sh"
TS="$(date +%s)"
TMP="$(mktemp -d /tmp/apireq.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

CLEANUP_URLS=()
cleanup(){
  if [ -n "${GITEA_TOKEN:-}" ]; then
    for u in "${CLEANUP_URLS[@]:-}"; do
      [ -n "$u" ] && curl -s -o /dev/null -X DELETE -H "Authorization: token $GITEA_TOKEN" "$u" 2>/dev/null || true
    done
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "═══ Section A — gardes d'entrée (HORS LIGNE, AVANT tout geste Git) ═══"
run_guard(){
  # $1=label $2=expected_tag ; le reste = env KEY=VALUE...
  local label="$1" tag="$2"; shift 2
  local out rc
  out=$(env -i PATH="$PATH" GIT_HOST="http://127.0.0.1:1" GITEA_TOKEN=dummy \
        ACTION=create TEAM=probe API_NAME=probe API_VERSION=1.0.0 \
        OPENAPI_SPEC='{"openapi":"3.0.0"}' INBOUND_MODE=jwt "$@" bash "$S" 2>&1)
  rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "$tag"; then
    if printf '%s' "$out" | grep -q '\[1/5\]'; then
      ko "$label : refusé mais APRÈS le clone (réseau touché) — pas 'AVANT tout geste Git'"
    else
      ok "$label : refusé ($tag), AVANT tout appel réseau"
    fi
  else
    ko "$label : attendu exit=1 + '$tag', obtenu rc=$rc out=$(printf '%s' "$out" | tail -1)"
  fi
}
run_guard "ACTION invalide"          "ACTION_INVALIDE"        ACTION=bogus
run_guard "TEAM format invalide"     "TEAM_NAME_INVALID"      TEAM='Not Valid'
run_guard "API_NAME format invalide" "API_NAME_INVALID"       API_NAME='Bad_Name'
run_guard "INBOUND_MODE invalide"    "INBOUND_MODE_INVALIDE"  INBOUND_MODE=basic
run_guard "create sans API_VERSION"  "API_VERSION_REQUIS"     API_VERSION=''
run_guard "version create invalide"  "API_VERSION_INVALIDE"   API_VERSION=abc
run_guard "new-version sans API_BASE" "API_BASE_REQUIS"       ACTION=new-version API_VERSION=''
run_guard "API_BASE sans @"          "API_BASE_FORMAT_INVALIDE" ACTION=new-version API_VERSION='' API_BASE=fooonly NEW_VERSION=2.0.0
run_guard "cohérence nom (mismatch)" "API_NAME_MISMATCH"      ACTION=new-version API_VERSION='' API_NAME=bar API_BASE='foo@1.0.0' NEW_VERSION=2.0.0
run_guard "new-version sans NEW_VERSION" "NEW_VERSION_REQUIS" ACTION=new-version API_VERSION='' API_NAME=foo API_BASE='foo@1.0.0'
run_guard "NEW_VERSION == base"      "NEW_VERSION_IDENTIQUE"  ACTION=new-version API_VERSION='' API_NAME=foo API_BASE='foo@1.0.0' NEW_VERSION=1.0.0
run_guard "spec non parseable"       "SPEC_INVALIDE"          OPENAPI_SPEC='{not: valid: yaml: ['
run_guard "spec sans openapi/swagger" "SPEC_INVALIDE"         OPENAPI_SPEC='info: {title: x}'

echo
echo "═══ Section B — résolution team -> repo (dépôts bare LOCAUX, aucun Gitea réel) ═══"
mk_platform(){ # $1=bare-dir $2=providers.dev.yml content
  local bare="$1" src="$TMP/src-plat-$$-$RANDOM"
  mkdir -p "$src/poc-control-plane-federation/ansible"
  printf '%s' "$2" > "$src/poc-control-plane-federation/ansible/providers.dev.yml"
  ( cd "$src" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A \
    && git -c user.name=t -c user.email=t commit -qm init >/dev/null )
  mkdir -p "$(dirname "$bare")"; git clone -q --bare "$src" "$bare" >/dev/null
}
mk_team(){ # $1=bare-dir  $2=contenu optionnel de apis/foo.publish.yml
  local bare="$1" src="$TMP/src-team-$$-$RANDOM"
  mkdir -p "$src/apis"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$src/apis/foo.publish.yml"
  ( cd "$src" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A 2>/dev/null
    git -c user.name=t -c user.email=t commit -qm init --allow-empty >/dev/null )
  mkdir -p "$(dirname "$bare")"; git clone -q --bare "$src" "$bare" >/dev/null
}
run_local(){ # $1=label $2=expected_tag $3=GH $4=GIT_REPO ; le reste = env...
  local label="$1" tag="$2" gh="$3" gitrepo="$4"; shift 4
  local before after out rc
  before=$(git ls-remote "$gh/$gitrepo.git" 2>&1)
  out=$(env -i PATH="$PATH" GIT_HOST="$gh" GIT_REPO="$gitrepo" GITEA_TOKEN=dummy \
        ACTION=create TEAM=teamx API_NAME=foo API_VERSION=1.0.0 \
        OPENAPI_SPEC='{"openapi":"3.0.0"}' INBOUND_MODE=jwt "$@" bash "$S" 2>&1)
  rc=$?
  after=$(git ls-remote "$gh/$gitrepo.git" 2>&1)
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "$tag" && [ "$before" = "$after" ]; then
    ok "$label : refusé ($tag), dépôt plateforme intact (ls-remote inchangé)"
  else
    ko "$label : attendu exit=1 + '$tag' + ls-remote intact, obtenu rc=$rc out=$(printf '%s' "$out" | tail -1)"
  fi
}

GH1="$TMP/gh1"
mk_platform "$GH1/ci/stoa-labs.git" 'providers:
  - team: teamx
    repo: teamx/apis
    approvers: []'
run_local "TEAM_NOT_DECLARED" "TEAM_NOT_DECLARED" "$GH1" "ci/stoa-labs" TEAM=ghost-team

GH2="$TMP/gh2"
mk_platform "$GH2/ci/stoa-labs.git" 'providers:
  - team: teamx
    repo: ""
    approvers: []'
run_local "REPO_MANQUANT" "REPO_MANQUANT" "$GH2" "ci/stoa-labs"

GH3="$TMP/gh3"
mk_platform "$GH3/ci/stoa-labs.git" 'providers:
  - team: teamx
    repo: teamx/nonexistent
    approvers: []'
run_local "REPO_INACCESSIBLE" "REPO_INACCESSIBLE" "$GH3" "ci/stoa-labs"

GH4="$TMP/gh4"
mk_platform "$GH4/ci/stoa-labs.git" 'providers:
  - team: teamx
    repo: teamx/apis
    approvers: []'
mk_team "$GH4/teamx/apis.git" 'apim_api:
  name: foo
  version: 1.0.0'
run_local "API_ALREADY_EXISTS (create sur API existante)" "API_ALREADY_EXISTS" "$GH4" "ci/stoa-labs"
run_local "API_BASE_NOT_FOUND (new-version sur API absente)" "API_BASE_NOT_FOUND" "$GH4" "ci/stoa-labs" \
  ACTION=new-version API_VERSION='' API_NAME=bar API_BASE='bar@1.0.0' NEW_VERSION=2.0.0
run_local "API_BASE_STALE (version de base désaccordée)" "API_BASE_STALE" "$GH4" "ci/stoa-labs" \
  ACTION=new-version API_VERSION='' API_NAME=foo API_BASE='foo@0.9.0' NEW_VERSION=2.0.0

echo
echo "═══ Section C — hiérarchie de diagnostic PLAN (fatal > msg > tail-3) ═══"
# Rejoue EXACTEMENT l'invocation de api-request.sh (§5) contre la fixture E1
# réelle du dépôt (ansible/tests/e1/manifest-crossteam.yml, TEAM_FORBIDDEN
# connu) : preuve que l'extraction produit un message EXPLOITABLE, pas un
# ❌ muet — même hiérarchie que team-apply.sh (leçon du palier 2, appliquée
# d'entrée ici plutôt qu'en rattrapage).
PLAN_LOG="$TMP/plan.log"
( cd "$REPO" && {
  ansible-playbook -i ansible/inventory.lab.ini ansible/test-publish-guards.yml \
    -e apim_ss_manifest="$REPO/ansible/tests/e1/manifest-crossteam.yml" -e apim_ss_team="banking-demo"
  echo "GUARD_RC=$?"
} ) >"$PLAN_LOG" 2>&1
MSG=$(grep -A6 -E 'fatal:|FAILED!|^ERROR!' "$PLAN_LOG" | grep -oE '"msg":.*|^ERROR!.*' | tail -1 | cut -c1-300)
if printf '%s' "$MSG" | grep -q "TEAM_FORBIDDEN"; then
  ok "extraction PLAN : TEAM_FORBIDDEN remonté par la hiérarchie fatal>msg (pas un tail-3 générique)"
else
  ko "extraction PLAN : TEAM_FORBIDDEN absent du message extrait — $MSG"
fi

echo
echo "═══ Section D — nominal E2E contre le VRAI Gitea du lab (poc-gitea:13000) ═══"
GITEA_TOKEN=""
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then
  GITEA_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect poc-gitea >/dev/null 2>&1; then
  GITEA_TOKEN=$(docker exec -u git poc-gitea gitea admin user generate-access-token \
    --username ci --token-name "p3t5-test-$TS" \
    --scopes write:repository,write:issue,write:organization 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
if [ -z "$GITEA_TOKEN" ] || ! curl -s -o /dev/null "http://localhost:13000" 2>/dev/null; then
  echo "  (section D sautée — Gitea du lab (poc-gitea:13000) ou token indisponible)"
else
  GH="http://localhost:13000"
  PLATORG="p3t5plat${TS}"; TEAMORG="p3t5team${TS}"
  gapi(){ curl -s -H "Authorization: token $GITEA_TOKEN" -H 'Content-Type: application/json' "$@"; }
  RC1=$(gapi -X POST -d "{\"username\":\"$PLATORG\"}" -o /dev/null -w '%{http_code}' "$GH/api/v1/orgs")
  RC2=$(gapi -X POST -d "{\"username\":\"$TEAMORG\"}" -o /dev/null -w '%{http_code}' "$GH/api/v1/orgs")
  RC3=$(gapi -X POST -d '{"name":"stoa-labs","auto_init":false}' -o /dev/null -w '%{http_code}' "$GH/api/v1/orgs/$PLATORG/repos")
  RC4=$(gapi -X POST -d '{"name":"apis","auto_init":false}' -o /dev/null -w '%{http_code}' "$GH/api/v1/orgs/$TEAMORG/repos")
  CLEANUP_URLS+=("$GH/api/v1/repos/$PLATORG/stoa-labs" "$GH/api/v1/repos/$TEAMORG/apis" "$GH/api/v1/orgs/$PLATORG" "$GH/api/v1/orgs/$TEAMORG")
  if [ "$RC1" != 201 ] || [ "$RC2" != 201 ] || [ "$RC3" != 201 ] || [ "$RC4" != 201 ]; then
    ko "préparation scratch (org/repo) en échec (HTTP $RC1/$RC2/$RC3/$RC4) — section D avortée"
  else
    WD="$TMP/d-work"
    mkdir -p "$WD/plat/poc-control-plane-federation/ansible" "$WD/team/apis"
    cat > "$WD/plat/poc-control-plane-federation/ansible/providers.dev.yml" <<YML
---
providers:
  - team: ${TEAMORG}
    description: "scratch team p3t5"
    repo: ${TEAMORG}/apis
    approvers: []
YML
    ( cd "$WD/plat" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A \
      && git -c user.name=t -c user.email=t commit -qm init )
    ( cd "$WD/team" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A 2>/dev/null
      git -c user.name=t -c user.email=t commit -qm init --allow-empty )
    AUTH_B64=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
      git -C "$WD/plat" push -q "$GH/$PLATORG/stoa-labs.git" main
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
      git -C "$WD/team" push -q "$GH/$TEAMORG/apis.git" main
    unset AUTH_B64

    # ── flake d'ENVIRONNEMENT observé (pas un défaut d'api-request.sh) : sur
    # ce Gitea de lab, un `git push` (branche neuve OU dépôt tout juste créé)
    # suivi QUASI IMMÉDIATEMENT (quelques dizaines de ms, deux process python
    # de suite) d'un appel API peut rendre 404 "The target couldn't be found"
    # — l'objet n'est pas encore indexé côté API au moment de l'appel.
    # Reproduit ISOLÉMENT (push+POST nus, sans api-request.sh) : absent avec
    # un délai de 2s entre les deux, présent sans délai. team-request.sh
    # partage EXACTEMENT le même motif (push puis POST immédiat,
    # scripts/team-request.sh:144-161) — ce n'est donc pas un défaut propre à
    # ce script, et rien ne justifie d'y introduire un retry qu'aucun autre
    # script du dépôt ne porte (« ne réinvente pas »). Palliatif LOCAL AU
    # TEST : un délai de settle avant le PREMIER essai (évite la course dans
    # l'immense majorité des cas, mesuré) — pas de retry avec suppression de
    # branche (tenté, lui-même retombé sur la même course côté DELETE :
    # confirmation qu'ajouter de la mécanique ici ne fait que déplacer le
    # problème, pas le résoudre).
    settle(){ sleep 3; }

    echo "── D1. mode create (nominal) ──"
    SPEC1='openapi: "3.0.0"
info: {title: scratch-api, version: "1.0.0"}
paths: {}'
    settle
    OUT1=$(env -i PATH="$PATH" HOME="$HOME" GIT_HOST="$GH" GIT_REPO="${PLATORG}/stoa-labs" GIT_WEB_HOST="$GH" \
      ACTION=create TEAM="$TEAMORG" API_NAME=scratch-api API_VERSION=1.0.0 \
      OPENAPI_SPEC="$SPEC1" INBOUND_MODE=jwt GITEA_TOKEN="$GITEA_TOKEN" bash "$S" 2>&1)
    RC=$?
    MANI1=$(gapi "$GH/api/v1/repos/$TEAMORG/apis/raw/api/scratch-api-1.0.0/apis/scratch-api.publish.yml")
    if [ "$RC" -eq 0 ] && printf '%s' "$MANI1" | grep -q 'name: "scratch-api"' \
       && printf '%s' "$MANI1" | grep -q 'version: "1.0.0"' \
       && printf '%s' "$MANI1" | grep -q 'mode: "jwt"'; then
      ok "D1 : PR create ouverte, manifeste name/version/mode corrects"
    else
      ko "D1 : run en échec ou manifeste incorrect — $(printf '%s' "$OUT1" | tail -5)"
    fi
    PRNUM1=$(printf '%s' "$OUT1" | grep -oE 'PR #[0-9]+' | head -1 | grep -oE '[0-9]+')
    # Le verdict COMPLET vit dans le commentaire posté sur la PR (le stdout
    # du script n'en imprime que le premier symbole, "[5/5] plan ✅ ...") —
    # on va donc le lire là où api-request.sh l'a réellement écrit.
    PLANCMT=""
    [ -n "$PRNUM1" ] && PLANCMT=$(gapi "$GH/api/v1/repos/$TEAMORG/apis/issues/$PRNUM1/comments" \
      | python3 -c "import json,sys; c=json.load(sys.stdin); print(c[0]['body'] if c else '')" 2>/dev/null)
    printf '%s' "$PLANCMT" | grep -q '✅ PLAN OK — MANIFEST_KEYS_OK' && printf '%s' "$PLANCMT" | grep -q 'TEAM_REQUESTED' \
      && ok "D1 : PLAN OK commenté sur la PR (MANIFEST_KEYS_OK + TEAM_REQUESTED)" \
      || ko "D1 : verdict PLAN attendu absent du commentaire — ${PLANCMT:-<vide>}"

    if [ -n "$PRNUM1" ]; then
      # Même flake d'indexation que plus haut (cf. commentaire de `settle`),
      # côté calcul de "mergeable" cette fois : un 405 quasi immédiatement
      # après l'ouverture de la PR peut n'être qu'un "pas encore prêt", pas un
      # vrai refus — un seul rejeu après settle() avant de conclure à un échec.
      MRC=$(gapi -X POST -d '{"Do":"merge"}' -o /dev/null -w '%{http_code}' "$GH/api/v1/repos/$TEAMORG/apis/pulls/$PRNUM1/merge")
      if [ "$MRC" != 200 ]; then
        settle
        MRC=$(gapi -X POST -d '{"Do":"merge"}' -o /dev/null -w '%{http_code}' "$GH/api/v1/repos/$TEAMORG/apis/pulls/$PRNUM1/merge")
      fi
      [ "$MRC" = 200 ] && ok "D2 : merge de la PR create (préalable à new-version — new-version lit MAIN)" \
        || ko "D2 : merge de la PR create en échec (HTTP $MRC)"
    else
      ko "D2 : numéro de PR introuvable dans la sortie de D1 — new-version non tentée"
    fi

    echo "── D3. mode new-version (après merge) ──"
    SPEC2='openapi: "3.0.0"
info: {title: scratch-api, version: "2.0.0"}
paths: {}'
    settle
    OUT2=$(env -i PATH="$PATH" HOME="$HOME" GIT_HOST="$GH" GIT_REPO="${PLATORG}/stoa-labs" GIT_WEB_HOST="$GH" \
      ACTION=new-version TEAM="$TEAMORG" API_NAME=scratch-api API_BASE='scratch-api@1.0.0' NEW_VERSION=2.0.0 \
      OPENAPI_SPEC="$SPEC2" INBOUND_MODE=oauth2 GITEA_TOKEN="$GITEA_TOKEN" bash "$S" 2>&1)
    RC2=$?
    MANI2=$(gapi "$GH/api/v1/repos/$TEAMORG/apis/raw/api/scratch-api-2.0.0/apis/scratch-api.publish.yml")
    if [ "$RC2" -eq 0 ] && printf '%s' "$MANI2" | grep -q 'version: "2.0.0"' \
       && printf '%s' "$MANI2" | grep -q 'mode: "oauth2"'; then
      ok "D3 : PR new-version ouverte, manifeste bumpé en 2.0.0, mode oauth2"
    else
      ko "D3 : run en échec ou manifeste incorrect — $(printf '%s' "$OUT2" | tail -5)"
    fi

    echo "── D4. contre-épreuve : re-tenter new-version 1.0.0 -> 2.0.0 (base périmée) ──"
    settle
    OUT3=$(env -i PATH="$PATH" HOME="$HOME" GIT_HOST="$GH" GIT_REPO="${PLATORG}/stoa-labs" GIT_WEB_HOST="$GH" \
      ACTION=new-version TEAM="$TEAMORG" API_NAME=scratch-api API_BASE='scratch-api@1.0.0' NEW_VERSION=3.0.0 \
      OPENAPI_SPEC="$SPEC2" INBOUND_MODE=jwt GITEA_TOKEN="$GITEA_TOKEN" bash "$S" 2>&1)
    RC3=$?
    # main porte encore 1.0.0 (D3 n'est pas mergée) : ce n'est PAS une base
    # périmée ici, donc la PR doit s'ouvrir sans API_BASE_STALE. On vérifie
    # juste la non-régression du chemin nominal, pas un refus.
    if [ "$RC3" -eq 0 ]; then
      ok "D4 : new-version rejouée depuis la même base non mergée (idempotence du chemin nominal)"
    else
      ko "D4 : $(printf '%s' "$OUT3" | tail -3)"
    fi
  fi
fi

echo
echo "═══ ${PASS} OK / ${FAIL} KO ═══"
[ "$FAIL" -eq 0 ]
