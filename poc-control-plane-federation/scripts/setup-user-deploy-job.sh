#!/usr/bin/env bash
# setup-user-deploy-job.sh — job Jenkins `stoa-user-deploy` (chaîne A, ADR-077).
#
# Le job matérialise « l'utilisateur se connecte au Vault, pas l'application » :
# il ne détient AUCUN credential (pas d'AppRole, pas de secret Jenkins). Il ne
# fait qu'ÉCHANGER le JWT utilisateur reçu dans le payload du webhook
# (vault_jwt, JWT court aud=vault issu du token exchange Keycloak) contre un
# token Vault NOMINATIF, lire le secret de déploiement, puis révoquer le token.
#
# Sécurité du transport du JWT :
#   - printContributedVariables/printPostContent = false (jamais dans le log) ;
#   - TTL Keycloak 300 s : même intercepté, le jeton meurt vite ;
#   - le build d'amorçage (pas de payload) est un no-op qui enregistre le trigger.
#
# Idempotent — même mécanique crumb/createItem que ci-wire-governance.sh.
set -uo pipefail

JENKINS="${JENKINS:-http://localhost:18080}"
JOB="stoa-user-deploy"
TRIGGER_TOKEN="stoa-user-deploy"

say() { printf '\033[1;36m[user-deploy-job]\033[0m %s\n' "$*"; }

XML="$(mktemp)"; trap 'rm -f "$XML" /tmp/judj.txt' EXIT
cat > "$XML" <<'JOBXML'
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Chaîne A (ADR-077) : identité UTILISATEUR de bout en bout — Console/Keycloak → token exchange (RFC 8693) → webhook (vault_jwt) → Vault auth/jwt → token nominatif → lecture du secret de déploiement. Le job ne stocke AUCUN credential. Le trigger (token stoa-user-deploy) s'enregistre au premier build.</description>
  <keepDependencies>false</keepDependencies>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>// Aucun secret dans ce job : l'identité arrive PAR le webhook (JWT court),
// la preuve est nominative (entité Vault = l'utilisateur qui a déclenché).
pipeline {
  agent any
  options { disableConcurrentBuilds() }
  triggers {
    GenericTrigger(
      token: 'stoa-user-deploy',
      genericVariables: [
        [key: 'USER_VAULT_JWT', value: '$.vault_jwt'],
        [key: 'DEPLOY_HINT',    value: '$.hint']
      ],
      printContributedVariables: false,
      printPostContent: false
    )
  }
  environment { VAULT_ADDR = 'http://vault:8200' }
  stages {
    stage('Vault login — identité utilisateur') {
      steps {
        // Un build MANUEL sans payload = amorçage du trigger (no-op assumé).
        // Un build WEBHOOK sans vault_jwt = payload invalide → ÉCHEC (jamais
        // de vert qui n'a rien fait).
        script {
          env.VIA_WEBHOOK = currentBuild.getBuildCauses('org.jenkinsci.plugins.gwt.GenericCause') ? 'yes' : 'no'
        }
        sh '''#!/bin/bash
set -euo pipefail
set +x
if [ -z "${USER_VAULT_JWT:-}" ]; then
  if [ "${VIA_WEBHOOK:-no}" = yes ]; then
    echo "✗ webhook SANS vault_jwt — payload invalide (cle absente/renommee/body vide)"
    exit 1
  fi
  echo "amorçage : build manuel sans payload — enregistrement du trigger, rien à faire."
  exit 0
fi
# contexte non-secret du déclencheur (hint = promotion + approbateur) : permet
# de corréler CE build à UNE approbation précise dans les preuves.
echo "ctx: ${DEPLOY_HINT:-}"
# PIÈGE Groovy : dans une string triple-quoted, un backslash-guillemet est
# consommé par GROOVY (pas par le shell) — le JSON partirait sans guillemets
# (« error parsing JSON » côté Vault). Donc : zéro backslash ici, le body est
# construit via printf single-quoted, et le JWT part en CORPS (jamais en argv).
BODY=$(printf '{"role":"user-deploy","jwt":"%s"}' "$USER_VAULT_JWT")
LOGIN=$(printf '%s' "$BODY" | curl -s -X POST "$VAULT_ADDR/v1/auth/jwt/login" --data-binary @-)
VT=$(printf '%s' "$LOGIN" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("auth",{}).get("client_token",""))' 2>/dev/null || true)
if [ -z "$VT" ]; then
  echo "✗ login Vault REFUSÉ (JWT invalide, expiré, mauvaise audience ou rôle realm insuffisant)"
  printf '%s' "$LOGIN" | python3 -c 'import sys,json;print("  détail:", ",".join(json.load(sys.stdin).get("errors",[])))' 2>/dev/null || true
  exit 1
fi
# Le token Vault part dans un header-FILE, jamais en argv (visible ps/cmdline
# par tout process co-localisé) — standard ADR-074 « jamais en argv ».
umask 077
HF=$(mktemp)
trap 'rm -f "$HF"' EXIT
printf 'X-Vault-Token: %s' "$VT" > "$HF"
WHO=$(printf '%s' "$LOGIN" | python3 -c 'import sys,json;a=json.load(sys.stdin)["auth"];print(a["metadata"].get("username","?"))')
VIA=$(printf '%s' "$LOGIN" | python3 -c 'import sys,json;a=json.load(sys.stdin)["auth"];print(a["metadata"].get("exchanged_by","?"))')
TEN=$(printf '%s' "$LOGIN" | python3 -c 'import sys,json;a=json.load(sys.stdin)["auth"];print(a["metadata"].get("tenant","?"))')
echo "✓ token Vault NOMINATIF — identite=$WHO tenant=$TEN (delegation via $VIA) ; le job ne detient aucun credential propre"
KEYS=$(curl -sf -H @"$HF" "$VAULT_ADDR/v1/secret/data/stoa/deploy/$TEN/demo" | python3 -c 'import sys,json;print(",".join(sorted(json.load(sys.stdin)["data"]["data"].keys())))')
echo "✓ secret de deploiement ($TEN) lu (cles: $KEYS) — valeurs jamais loggees"
# revoke VERIFIE + preuve de mort du token : la propriete « duree de vie = le
# build » est testee, pas seulement affichee.
HC=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H @"$HF" "$VAULT_ADDR/v1/auth/token/revoke-self")
if [ "$HC" != 204 ]; then
  echo "✗ revoke-self KO (HTTP $HC) — le token expirerait par TTL, pas au build"
  exit 1
fi
LC=$(curl -s -o /dev/null -w '%{http_code}' -H @"$HF" "$VAULT_ADDR/v1/auth/token/lookup-self")
if [ "$LC" = 403 ]; then
  echo "✓ token Vault revoque et VERIFIE mort (lookup-self 403) — sa duree de vie est le build, pas plus"
else
  echo "✗ token encore vivant apres revoke (lookup-self $LC)"
  exit 1
fi
'''
      }
    }
  }
  post {
    success { echo '✓ chaîne A : utilisateur → exchange → Vault → job. Zéro credential stocké côté CI.' }
    failure { echo '✗ chaîne A KO — voir le log (login Vault ou lecture du secret).' }
  }
}
</script>
    <sandbox>true</sandbox>
  </definition>
  <disabled>false</disabled>
</flow-definition>
JOBXML

# --- crumb CSRF + create/update (pattern ci-wire-governance.sh) ---------------
CJ=$(curl -sf -c /tmp/judj.txt "$JENKINS/crumbIssuer/api/json")
F=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])')
C=$(printf '%s' "$CJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumb"])')
# charset=utf-8 OBLIGATOIRE : sans lui, le endpoint config.xml relit le body en
# ISO-8859-1 et rejette les accents/tirets en 500 « invalid XML character 0x80 »
# (createItem, lui, tolère — d'où des mises à jour qui échouent en silence si on
# ne vérifie pas le code HTTP).
CT='Content-Type: application/xml; charset=utf-8'
if curl -sf -b /tmp/judj.txt "$JENKINS/job/$JOB/api/json" >/dev/null 2>&1; then
  say "job $JOB existe — config mise à jour"
  HC=$(curl -s -b /tmp/judj.txt -X POST "$JENKINS/job/$JOB/config.xml" -H "$F: $C" \
    -H "$CT" --data-binary @"$XML" -o /dev/null -w '%{http_code}')
else
  say "création du job $JOB"
  HC=$(curl -s -b /tmp/judj.txt -X POST "$JENKINS/createItem?name=$JOB" -H "$F: $C" \
    -H "$CT" --data-binary @"$XML" -o /dev/null -w '%{http_code}')
fi
[ "$HC" = 200 ] || { printf '\033[1;31m[user-deploy-job]\033[0m POST job KO (HTTP %s)\n' "$HC"; exit 1; }

# --- build d'amorçage : enregistre le GenericTrigger (no-op sans payload) -----
# On vise le NUMÉRO du prochain build (pas lastBuild : pendant la quiet period,
# lastBuild pointe encore le précédent et on lirait son verdict).
N=$(curl -sf "$JENKINS/job/$JOB/api/json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])')
say "build d'amorçage #$N (enregistre le trigger $TRIGGER_TOKEN)"
HC=$(curl -s -b /tmp/judj.txt -X POST "$JENKINS/job/$JOB/build" -H "$F: $C" -o /dev/null -w '%{http_code}')
[ "$HC" = 201 ] || { printf '\033[1;31m[user-deploy-job]\033[0m POST /build KO (HTTP %s)\n' "$HC"; exit 1; }
R=""
for i in $(seq 1 30); do
  R=$(curl -sf "$JENKINS/job/$JOB/$N/api/json" 2>/dev/null |
    python3 -c 'import sys,json;b=json.load(sys.stdin);print(b.get("result") or "")' 2>/dev/null || true)
  [ -n "$R" ] && break
  sleep 2
done
[ "$R" = "SUCCESS" ] || {
  printf '\033[1;31m[user-deploy-job]\033[0m build d'"'"'amorçage #%s : %s — trigger %s possiblement NON enregistré (le webhook répondrait à vide)\n' "$N" "${R:-pas de résultat en 60 s}" "$TRIGGER_TOKEN"
  exit 1
}
say "build d'amorçage #$N : SUCCESS (trigger enregistré)"

say "OK — déclenchement : POST $JENKINS/generic-webhook-trigger/invoke?token=$TRIGGER_TOKEN  body {\"vault_jwt\":\"<JWT échangé>\"}"
