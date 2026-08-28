#!/usr/bin/env bash
# setup-provision-request-job.sh — câble le MAILLON 1 côté Jenkins (idempotent) :
#   1. mint un token Gitea (user de service `ci`) pour push + PR
#   2. crée le credential Jenkins secret-text `gitea-provision-token`
#   3. crée le job pipeline `provisioning-request` (GWT token stoa-provision-request)
#      qui checkoute ci/stoa-labs et lance scripts/provision-request.sh
#
# Ensuite, router l'API provisioning vers ce job :
#   GWT_TOKEN=stoa-provision-request TARGET_JOB=provisioning-request \
#     ./scripts/setup-provisioning-api.sh   (ou re-patch du routing endpointUri)
#
# Le job checkoute ci/stoa-labs (Gitea) → le script provision-request.sh DOIT y
# être poussé (git push gitea main). Aucune identité humaine (webhook) : le commit
# est signé par `ci`, la PR reste à valider (4-yeux, ADR-078).
set -uo pipefail
cd "$(dirname "$0")/.."
JENKINS_UI="${JENKINS_UI:-http://localhost:18080}"
GITEA_CONTAINER="${GITEA_CONTAINER:-poc-gitea}"
JOB=provisioning-request
JOB_XML="ci/jenkins/provisioning-request.job.xml"
ok(){ printf '  \033[32m✅\033[0m %s\n' "$*"; }
ko(){ printf '  \033[31m❌\033[0m %s\n' "$*"; exit 1; }

[ -f "$JOB_XML" ] || ko "job XML absent : $JOB_XML"

# 1. token Gitea (idempotent : regénéré à chaque run, TTL du lab)
echo "1. token Gitea (service ci)"
# write:package : le registre d'archives G5 (scripts/lib/archive-store.sh) pousse
# et refetche par CE token — mesuré, 401 dès la sonde sans lui, 201/200 avec.
TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token \
  --username ci --token-name "provision-mr-$(date +%s 2>/dev/null || echo x)" \
  --scopes write:repository,write:issue,write:package 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
[ -n "$TOKEN" ] || ko "génération token Gitea (user ci ?)"
ok "token Gitea acquis"

# 2. credential Jenkins secret-text
echo "2. credential Jenkins gitea-provision-token"
CK=$(mktemp); CJ=$(curl -sf -c "$CK" "$JENKINS_UI/crumbIssuer/api/json") || ko "Jenkins injoignable"
F=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])')
C=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumb"])')
# supprimer un éventuel ancien credential (rotation), puis (re)créer
curl -s -b "$CK" -X POST "$JENKINS_UI/credentials/store/system/domain/_/credential/gitea-provision-token/doDelete" -H "$F: $C" -o /dev/null
JSON=$(python3 -c 'import json,sys; print(json.dumps({"":"0","credentials":{"scope":"GLOBAL","id":"gitea-provision-token","secret":sys.argv[1],"description":"Gitea token maillon1 provisioning","$class":"org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl"}}))' "$TOKEN")
HC=$(curl -s -b "$CK" -X POST "$JENKINS_UI/credentials/store/system/domain/_/createCredentials" -H "$F: $C" --data-urlencode "json=$JSON" -o /dev/null -w '%{http_code}')
{ [ "$HC" = "200" ] || [ "$HC" = "302" ]; } && ok "credential posé (HTTP $HC)" || ko "createCredentials (HTTP $HC)"

# 3. job pipeline provisioning-request
echo "3. job Jenkins $JOB"
rm -f "$CK"
# DÉLÉGUÉ à setup-provision-jobs.sh, qui met à jour EN PLACE.
#
# Ce bloc faisait un delete+create inconditionnel, justifié par « le POST
# config.xml sur un job pipeline peut 500 ». Ce 500 n'était pas une fatalité du
# produit : Jenkins parse le corps en ISO-8859-1 quand le Content-Type ne déclare
# pas de charset, et casse sur le premier caractère accentué de la description
# (diagnostiqué le 2026-08-04 — trace SAXParseException « invalid XML character
# (Unicode: 0x89) »). Le contournement coûtait cher : chaque exécution DÉTRUISAIT
# l'historique de builds du job.
#
# La logique correcte (charset, mise à jour en place, création si absent, repli
# destructeur seulement sur demande explicite) vit dans setup-provision-jobs.sh,
# qui est générique (`JOBS=`) et prouvé contre l'instance réelle. On l'appelle
# plutôt que d'en écrire une seconde copie qui divergerait.
JENKINS_UI="$JENKINS_UI" JOBS="$JOB" bash "$(cd "$(dirname "$0")" && pwd)/setup-provision-jobs.sh" \
  || ko "mise à jour du job $JOB"
echo
echo "→ pousser le script sur Gitea :  git push gitea main"
echo "→ router l'API :  GWT_TOKEN=stoa-provision-request TARGET_JOB=$JOB ./scripts/setup-provisioning-api.sh"
