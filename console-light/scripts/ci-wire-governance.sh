#!/usr/bin/env bash
# Câble le repo de GOUVERNANCE (celui de la Console Light) sur le fil CI :
#   1. repo Gitea `governance` (public, checkout anonyme par Jenkins)
#   2. hooks post-commit/post-merge du repo local → push automatique
#   3. job Jenkins `stoa-governance` (pipeline inline, trigger token stoa-gov)
#   4. webhook push Gitea → generic-webhook-trigger
# Idempotent.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GITEA="http://localhost:13000"
JENKINS="http://localhost:18080"
CI_USER="ci"; CI_PASS="stoa-ci-demo-2026"
REPO="governance"; JOB="stoa-governance"
GOV="$HERE/var/governance-repo"

say() { printf '\033[1;35m[gov-wire]\033[0m %s\n' "$*"; }

# --- 1. repo Gitea ------------------------------------------------------------
if ! curl -sf "$GITEA/api/v1/repos/$CI_USER/$REPO" >/dev/null 2>&1; then
  say "création du repo $CI_USER/$REPO"
  curl -sf -u "$CI_USER:$CI_PASS" -X POST "$GITEA/api/v1/user/repos" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$REPO\",\"private\":false,\"auto_init\":false}" >/dev/null
fi
say "repo OK"

# --- 2. remote + hooks de push auto -------------------------------------------
cd "$GOV"
git remote remove origin 2>/dev/null || true
git remote add origin "http://$CI_USER:$CI_PASS@localhost:13000/$CI_USER/$REPO.git"
git push -qf --all origin
for hook in post-commit post-merge; do
  cat > ".git/hooks/$hook" <<'EOF'
#!/bin/sh
# Console Light : toute action validée (commit/merge signé) part en push —
# c'est le push qui déclenche la CI (webhook Gitea → Jenkins).
git push --all --prune origin --quiet 2>>.git/push-hook.log || echo "$(date) push KO" >> .git/push-hook.log
EOF
  chmod +x ".git/hooks/$hook"
done
say "remote + hooks post-commit/post-merge installés"

# --- 3. job Jenkins (pipeline inline, crumb CSRF) ------------------------------
JAR=/tmp/jgov.txt
CJ=$(curl -sf -c $JAR "$JENKINS/crumbIssuer/api/json")
F=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])')
C=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumb"])')
if curl -sf -b $JAR "$JENKINS/job/$JOB/api/json" >/dev/null 2>&1; then
  say "job $JOB existe — config mise à jour"
  curl -sf -b $JAR -X POST "$JENKINS/job/$JOB/config.xml" -H "$F: $C" \
    -H 'Content-Type: application/xml' --data-binary @"$HERE/var/jenkins-gov-job.xml" >/dev/null
else
  say "création du job $JOB"
  curl -sf -b $JAR -X POST "$JENKINS/createItem?name=$JOB" -H "$F: $C" \
    -H 'Content-Type: application/xml' --data-binary @"$HERE/var/jenkins-gov-job.xml" >/dev/null
fi
say "job Jenkins OK"

# --- 4. webhook push -----------------------------------------------------------
HOOK_URL="http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-gov"
HOOKS=$(curl -sf -u "$CI_USER:$CI_PASS" "$GITEA/api/v1/repos/$CI_USER/$REPO/hooks")
if ! printf '%s' "$HOOKS" | grep -q "stoa-gov"; then
  say "création du webhook push"
  curl -sf -u "$CI_USER:$CI_PASS" -X POST "$GITEA/api/v1/repos/$CI_USER/$REPO/hooks" \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"$HOOK_URL\",\"content_type\":\"json\",\"http_method\":\"post\"}}" >/dev/null
fi
say "webhook OK — un commit approuvé dans la Console déclenchera $JENKINS/job/$JOB"
