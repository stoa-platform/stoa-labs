#!/usr/bin/env bash
# test-console-user-deploy.sh — PREUVE LIVE E2E du wiring console → chaîne A
# (ADR-077 §Limites (2), désormais branché) :
#
#   bob approuve une promotion dans la Console (BFF governance-api) →
#   le BFF échange LE BEARER DE BOB (RFC 8693, client vault-exchange) →
#   JWT court aud=vault sub=bob tenant=banking-demo →
#   webhook Jenkins stoa-user-deploy (job SANS credential) →
#   token Vault NOMINATIF (bob) → lecture secret du tenant → revoke prouvé.
#
# L'approbation 4-yeux et la propagation d'identité sont UNE SEULE action
# utilisateur : personne d'autre que bob n'a de session, et c'est bien
# l'identité de bob (pas dave le demandeur, pas un service account) que Vault
# voit. Lance son PROPRE BFF (port dédié, wiring chaîne A activé par env) pour
# être auto-suffisant — même recette que prove-a7-four-eyes.sh.
#
# Prérequis up : Keycloak :8480 (26.2+), Dex, Vault :8200, Jenkins :18080,
# itsm-mock :8788 (CHG-0001=approved), governance-repo initialisé ;
# setup-user-vault-jwt.sh + setup-user-deploy-job.sh joués.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"          # poc repo
CL="$(cd "$ROOT/../console-light" && pwd)"
GR="${GOVERNANCE_REPO:-$CL/var/governance-repo}"
KC="${KC_BASE:-http://localhost:8480}"
ITSM="${ITSM_URL:-http://localhost:8788}"
JENKINS="${JENKINS:-http://localhost:18080}"
PORT="${BFF_PORT:-8797}"; BFF="http://localhost:$PORT"
TENANT=banking-demo; SLUG=accounts-read

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
jget(){ python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null; }

BFFPID=""; BIN=""; SECF=""
cleanup() { local rc=$?; [ -n "$BFFPID" ] && kill "$BFFPID" 2>/dev/null; rm -f "$BIN" "$SECF" 2>/dev/null; exit $rc; }
trap cleanup EXIT INT TERM

say "0. Prérequis + BFF dédié (:$PORT) avec wiring chaîne A ACTIVÉ"
[ -f "$GR/environments.yaml" ] || { echo "governance-repo absent ($GR)"; exit 2; }
[ "$(curl -s "$ITSM/changes/CHG-0001" | jget '.get("status")')" = approved ] \
  || { echo "CHG-0001 non approved dans l'ITSM"; exit 2; }
curl -sf "$JENKINS/job/stoa-user-deploy/api/json" >/dev/null || { echo "job stoa-user-deploy absent (jouer setup-user-deploy-job.sh)"; exit 2; }
BIN="$(mktemp)"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" ./cmd/governance-api ) || { echo build KO; exit 1; }
# secret de l'échangeur en fichier 0600 (jamais en argv, standard ADR-074)
SECF="$(mktemp)"; chmod 600 "$SECF"; printf 'vault-exchange-secret-poc' > "$SECF"
GOVERNANCE_REPO="$GR" ITSM_URL="$ITSM" KC_BASE="$KC" KC_REALM=stoa-lab LISTEN=":$PORT" \
  USER_DEPLOY_WEBHOOK_URL="$JENKINS/generic-webhook-trigger/invoke?token=stoa-user-deploy" \
  VAULT_EXCHANGE_SECRET_FILE="$SECF" \
  "$BIN" >/tmp/test-console-ud-bff.log 2>&1 &
BFFPID=$!
for _ in $(seq 1 40); do curl -s -o /dev/null "$BFF/api/v1/me" && break; sleep 0.25; done
grep -q "user-deploy=on" /tmp/test-console-ud-bff.log \
  && ok "BFF up, wiring chaîne A annoncé au boot (user-deploy=on)" \
  || bad "BFF up mais wiring non annoncé (log: $(head -1 /tmp/test-console-ud-bff.log))"

mint() { DEX_USER="$1@bc.example" CLIENT_ID=stoa-portal bash "$ROOT/scripts/get-oracle-token.sh" --quiet 2>/dev/null; }
TOK_DAVE="$(mint dave)"; TOK_BOB="$(mint bob)"
[ -n "$TOK_DAVE" ] && [ -n "$TOK_BOB" ] || { echo "mint tokens KO (Dex/setup-identity ?)"; exit 1; }

say "1. dave DEMANDE $SLUG int→prod (CHG-0001 + PV)"
REQ=$(curl -s -X POST -H "Authorization: Bearer $TOK_DAVE" -H 'Content-Type: application/json' \
  -d "{\"slug\":\"$SLUG\",\"from\":\"int\",\"to\":\"prod\",\"message\":\"preuve wiring chaîne A\",\"change_ref\":\"CHG-0001\",\"pv_ref\":\"PV-2026-077\"}" \
  "$BFF/api/v1/tenants/$TENANT/promotions")
PROMO=$(printf '%s' "$REQ" | jget '.get("promotion",{}).get("id","")')
[ -n "$PROMO" ] && ok "promotion demandée par dave ($PROMO)" || { bad "request KO: $REQ"; exit 1; }

say "2. bob APPROUVE dans la Console → le BFF propage SON identité (exchange + webhook)"
N=$(curl -s "$JENKINS/job/stoa-user-deploy/api/json" | jget '["nextBuildNumber"]')
CODE=$(curl -s -o /tmp/test-console-ud-appr.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK_BOB" \
  -H 'Content-Type: application/json' -d '{"message":"approbation croisée + déploiement nominatif"}' \
  "$BFF/api/v1/tenants/$TENANT/promotions/$PROMO/approve")
APPR_BY=$(jget '["promotion"]["approved_by"]' < /tmp/test-console-ud-appr.json)
UD=$(jget '["user_deploy"]' < /tmp/test-console-ud-appr.json)
[ "$CODE" = 200 ] && [ "$APPR_BY" = "bob@bc.example" ] \
  && ok "approve → 200, approved_by=bob@bc.example (4-yeux intact)" \
  || bad "approve → HTTP $CODE approved_by=$APPR_BY"
[ "$UD" = "dispatched" ] \
  && ok "réponse approve : user_deploy=dispatched (le BFF a lancé la chaîne A)" \
  || bad "user_deploy=$UD (attendu dispatched)"

say "3. le job Jenkins stoa-user-deploy tourne SOUS L'IDENTITÉ DE BOB"
R=""
for _ in $(seq 1 30); do
  R=$(curl -s "$JENKINS/job/stoa-user-deploy/$N/api/json" 2>/dev/null | jget '.get("result") or ""')
  [ -n "$R" ] && break; sleep 3
done
[ "$R" = "SUCCESS" ] && ok "build #$N SUCCESS" || bad "build #$N: ${R:-jamais déclenché/terminé}"
LOG=$(curl -s "$JENKINS/job/stoa-user-deploy/$N/consoleText")
grep -qF "$PROMO" <<<"$LOG" \
  && ok "le build est corrélé à CETTE approbation (hint porte $PROMO)" \
  || bad "le build #$N ne référence pas la promotion $PROMO (course avec un autre déclencheur ?)"
grep -q "identite=bob@bc.example tenant=banking-demo" <<<"$LOG" \
  && ok "token Vault NOMINATIF de L'APPROBATEUR (bob@bc.example, tenant banking-demo) — pas dave, pas un service account" \
  || bad "identité de bob absente du log du build"
grep -q "VERIFIE mort (lookup-self 403)" <<<"$LOG" \
  && ok "token Vault révoqué et prouvé mort en fin de build" || bad "revoke non prouvé"
grep -q "eyJ" <<<"$LOG" \
  && bad "FUITE : un jeton apparaît dans le log Jenkins" \
  || ok "aucun jeton dans le log Jenkins"
grep -q "user-deploy dispatché" /tmp/test-console-ud-bff.log \
  && ok "le BFF a journalisé le dispatch (sans jamais logger de jeton)" \
  || bad "dispatch absent du log BFF"
grep -q "eyJ" /tmp/test-console-ud-bff.log \
  && bad "FUITE : un jeton apparaît dans le log du BFF" \
  || ok "aucun jeton (JWT) dans le log du BFF"
# le token du generic-webhook-trigger vit dans la query de l'URL — le boot doit
# logger l'URL REDACTÉE (le grep eyJ est aveugle à ce credential-là).
grep -q "token=" /tmp/test-console-ud-bff.log \
  && bad "FUITE : le token du webhook Jenkins apparaît dans le log du BFF" \
  || ok "URL du webhook redactée dans le log BFF (token GWT jamais loggé)"

say "RÉSULTAT"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] \
  && echo "OK — console → approve 4-yeux → exchange RFC 8693 → job sans credential → Vault nominatif : UNE action utilisateur, identité de bout en bout." \
  || echo "ÉCHECS ci-dessus"
exit $(( FAIL > 0 ? 1 : 0 ))
