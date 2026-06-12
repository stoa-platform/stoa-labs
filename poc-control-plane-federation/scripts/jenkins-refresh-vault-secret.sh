#!/usr/bin/env bash
# jenkins-refresh-vault-secret.sh — re-mint un secret_id AppRole ci-pipeline
# (TTL court, ADR-074) et met à jour le credential Jenkins `vault-ci-secret-id`.
# À lancer avant une session de builds (le secret_id expire en ~10 min — c'est
# VOULU : la fenêtre d'exposition d'un credential CI volé est de quelques
# minutes). Le secret ne touche jamais argv/stdout : mint → fichier 0600 → POST.
set -euo pipefail
cd "$(dirname "$0")/.."

JENKINS="${JENKINS_URL:-http://localhost:18080}"
JAR="$(mktemp)"; TMP="$(mktemp)"; trap 'rm -f "$JAR" "$TMP"' EXIT
chmod 600 "$TMP"

CR=$(curl -sf -c "$JAR" "$JENKINS/crumbIssuer/api/json")
CF=$(printf '%s' "$CR" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])')
CB=$(printf '%s' "$CR" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumb"])')

SID=$(bash scripts/setup-vault-approle.sh --mint ci-pipeline 2>/dev/null | awk 'NR==1{print $2}')
[ -n "$SID" ] || { echo "✗ mint ci-pipeline KO (Vault up ? setup-vault-approle.sh joué ?)"; exit 1; }
printf '<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl><scope>GLOBAL</scope><id>vault-ci-secret-id</id><description>AppRole ci-pipeline secret_id (court, rotable - ADR-074)</description><secret>%s</secret></org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>' "$SID" > "$TMP"
unset SID

CODE=$(curl -s -b "$JAR" -X POST \
  "$JENKINS/credentials/store/system/domain/_/credential/vault-ci-secret-id/config.xml" \
  -H "$CF: $CB" -H 'Content-Type: application/xml' --data-binary @"$TMP" -o /dev/null -w '%{http_code}')
[ "$CODE" = 200 ] && echo "✓ credential vault-ci-secret-id rafraîchi (secret_id frais, TTL court)" \
  || { echo "✗ update credential Jenkins KO (HTTP $CODE)"; exit 1; }
