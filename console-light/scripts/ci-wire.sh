#!/usr/bin/env bash
# Phase 0 — câblage du fil CI : user+repo Gitea, job Jenkins, webhook push.
# Idempotent (re-jouable). Prérequis : poc-gitea et poc-jenkins UP.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GITEA="http://localhost:13000"
JENKINS="http://localhost:18080"
CI_USER="ci"
CI_PASS="stoa-ci-demo-2026"
REPO="stoa-labs"
JOB="stoa-federation"

say() { printf '\033[1;36m[ci-wire]\033[0m %s\n' "$*"; }

# --- 1. user Gitea (CLI admin dans le container, idempotent) ------------------
if ! curl -sf -u "$CI_USER:$CI_PASS" "$GITEA/api/v1/user" >/dev/null 2>&1; then
  say "création du user Gitea '$CI_USER'"
  docker exec -u git poc-gitea gitea admin user create \
    --username "$CI_USER" --password "$CI_PASS" --email ci@bc.example --admin \
    --must-change-password=false || true
fi
curl -sf -u "$CI_USER:$CI_PASS" "$GITEA/api/v1/user" >/dev/null && say "user Gitea OK"

# --- 2. repo (public → clone anonyme par Jenkins, pas de credential) ----------
if ! curl -sf "$GITEA/api/v1/repos/$CI_USER/$REPO" >/dev/null 2>&1; then
  say "création du repo $CI_USER/$REPO"
  curl -sf -u "$CI_USER:$CI_PASS" -X POST "$GITEA/api/v1/user/repos" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$REPO\",\"private\":false,\"auto_init\":false}" >/dev/null
fi
say "repo OK"

# --- 3. miroir → push ----------------------------------------------------------
bash "$HERE/scripts/ci-mirror.sh" init
bash "$HERE/scripts/ci-mirror.sh" push "http://$CI_USER:$CI_PASS@localhost:13000/$CI_USER/$REPO.git"

# --- 4. job Jenkins (REST + crumb CSRF) ----------------------------------------
JAR="$HERE/var/jenkins-cookies.txt"
CRUMB_JSON=$(curl -sf -c "$JAR" "$JENKINS/crumbIssuer/api/json")
CRUMB_FIELD=$(printf '%s' "$CRUMB_JSON" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"])')
CRUMB=$(printf '%s' "$CRUMB_JSON" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumb"])')
if curl -sf -b "$JAR" "$JENKINS/job/$JOB/api/json" >/dev/null 2>&1; then
  say "job $JOB existe — config mise à jour"
  curl -sf -b "$JAR" -X POST "$JENKINS/job/$JOB/config.xml" \
    -H "$CRUMB_FIELD: $CRUMB" -H 'Content-Type: application/xml' \
    --data-binary @"$HERE/var/jenkins-job.xml" >/dev/null
else
  say "création du job $JOB"
  curl -sf -b "$JAR" -X POST "$JENKINS/createItem?name=$JOB" \
    -H "$CRUMB_FIELD: $CRUMB" -H 'Content-Type: application/xml' \
    --data-binary @"$HERE/var/jenkins-job.xml" >/dev/null
fi
say "job Jenkins OK"

# --- 5. webhook Gitea → Jenkins (réseau interne, token du job) ----------------
HOOK_URL="http://jenkins:8080/job/$JOB/build?token=stoa-ci"
HOOKS=$(curl -sf -u "$CI_USER:$CI_PASS" "$GITEA/api/v1/repos/$CI_USER/$REPO/hooks")
if ! printf '%s' "$HOOKS" | grep -q "$JOB/build"; then
  say "création du webhook push → $HOOK_URL"
  curl -sf -u "$CI_USER:$CI_PASS" -X POST "$GITEA/api/v1/repos/$CI_USER/$REPO/hooks" \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"$HOOK_URL\",\"content_type\":\"json\",\"http_method\":\"post\"}}" >/dev/null
fi
say "webhook OK"

say "CÂBLAGE TERMINÉ — un push sur $CI_USER/$REPO déclenche $JENKINS/job/$JOB"
