#!/bin/bash
# F4 T3 — org + repo + contenu + webhook, via l'API Gitea (localhost:30300).
# Idempotent. Exécuté sur worker-1 (root), fichiers du repo attendus dans
# /tmp/f4-repo/ (scp depuis le poste). Le jeton webhook est frappé ICI et ne
# quitte jamais le nœud (/root/f4-webhook.token, 0600).
set -eu
umask 077
G=http://localhost:30300/api/v1
CRED="ci:$(cat /root/gitea-ci-pass)"   # mdp du user `ci`, root-only sur worker-1 (rotation T9)
J='Content-Type: application/json'
TOKF=/root/f4-webhook.token
[ -s "$TOKF" ] || openssl rand -hex 24 > "$TOKF"
T=$(cat "$TOKF")
# org (422 = existe déjà : sain au rejeu)
curl -s -u "$CRED" -H "$J" -X POST -d '{"username":"banking-demo","visibility":"public"}' \
  "$G/orgs" -o /dev/null -w "org: %{http_code}\n"
# repo public (lecture anonyme requise : checkout Jenkins sans credential)
curl -s -u "$CRED" -H "$J" -X POST -d '{"name":"accounts-api","private":false,"default_branch":"main","auto_init":true}' \
  "$G/orgs/banking-demo/repos" -o /dev/null -w "repo: %{http_code}\n"
# contenu : création OU mise à jour (sha requis si le fichier existe)
put_file() { # $1=chemin repo  $2=fichier local
  BODY=$(base64 -w0 < "$2")
  SHA=$(curl -s -u "$CRED" "$G/repos/banking-demo/accounts-api/contents/$1" \
    | sed -n 's/.*"sha":"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$SHA" ]; then
    curl -s -u "$CRED" -H "$J" -X PUT \
      -d "{\"content\":\"$BODY\",\"message\":\"feat: $1 (F4)\",\"sha\":\"$SHA\"}" \
      "$G/repos/banking-demo/accounts-api/contents/$1" -o /dev/null -w "put $1: %{http_code}\n"
  else
    curl -s -u "$CRED" -H "$J" -X POST \
      -d "{\"content\":\"$BODY\",\"message\":\"feat: $1 (F4)\"}" \
      "$G/repos/banking-demo/accounts-api/contents/$1" -o /dev/null -w "post $1: %{http_code}\n"
  fi
}
put_file Jenkinsfile /tmp/f4-repo/Jenkinsfile
put_file stoa-publish.yaml /tmp/f4-repo/stoa-publish.yaml
put_file apis/accounts-read.openapi.yaml /tmp/f4-repo/accounts-read.openapi.yaml
# webhook push → Jenkins (allowlist Gitea = jenkins.ci.svc.cluster.local).
# Idempotent : si un hook F4 existe déjà, on ne double pas.
HOOKS=$(curl -s -u "$CRED" "$G/repos/banking-demo/accounts-api/hooks")
if echo "$HOOKS" | grep -q "generic-webhook-trigger"; then
  echo "hook: deja present"
else
  curl -s -u "$CRED" -H "$J" -X POST -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],
    \"config\":{\"url\":\"http://jenkins.ci.svc.cluster.local:8080/generic-webhook-trigger/invoke?token=$T\",\"content_type\":\"json\"}}" \
    "$G/repos/banking-demo/accounts-api/hooks" -o /dev/null -w "hook: %{http_code}\n"
fi
echo "OK — jeton webhook dans $TOKF (jamais affiche)"
