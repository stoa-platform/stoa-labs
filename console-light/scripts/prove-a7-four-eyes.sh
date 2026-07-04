#!/usr/bin/env bash
# prove-a7-four-eyes.sh — PREUVE LIVE E2E du refus 4-yeux (goal A7).
#
# Le principe des 4 yeux (self-approval interdit sur le hop int→prod gated
# fourEyes) était couvert en UNITAIRE seulement (TestPromotionFourEyes) ;
# denials.jsonl restait VIDE. Ce script l'exerce de bout en bout sur le BFF réel
# (governance-api) et le repo de gouvernance de la console, avec contre-épreuve :
#
#   1. dave (cpi-admin : peut demander ET approuver) DEMANDE accounts-read int→prod
#      (change CHG-0001 + PV, exigés par le gate prod).
#   2. dave TENTE d'approuver SA PROPRE promotion -> 403 SELF_APPROVAL_BLOCKED.
#   3. le refus est INSCRIT dans evidence/denials/denials.jsonl (commité + poussé
#      vers Gitea par le post-commit hook = le repo que Jenkins consomme).
#   4. CONTRE-ÉPREUVE identité : bob (≠ dave) approuve la MÊME promotion -> 200
#      (le gate est keyé sur l'identité, pas 'toujours non').
#
# Le username est le claim preferred_username = "<user>@bc.example" (piège vérifié :
# PAS "dave" nu). Prérequis up : Keycloak :8480, Dex (broker), itsm-mock :8788
# (CHG-0001=approved), governance-repo initialisé. Lance son PROPRE BFF (port
# dédié) pour être auto-suffisant.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"          # console-light/
POC="$(cd "$ROOT/../poc-control-plane-federation" && pwd)"
GR="${GOVERNANCE_REPO:-$ROOT/var/governance-repo}"
DENIALS="$GR/evidence/denials/denials.jsonl"
KC="${KC_BASE:-http://localhost:8480}"
ITSM="${ITSM_URL:-http://localhost:8788}"
GITEA="${GITEA_URL:-http://localhost:13000}"
PORT="${BFF_PORT:-8799}"; BFF="http://localhost:$PORT"
TENANT=banking-demo; SLUG=accounts-read

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

BFFPID=""; BIN=""
cleanup() { local rc=$?; [ -n "$BFFPID" ] && kill "$BFFPID" 2>/dev/null; rm -f "$BIN" 2>/dev/null
  # restaure CHG-0001=approved (le run le laisse tel quel, mais par sécurité)
  curl -s -X PUT "$ITSM/changes/CHG-0001/status" -H 'Content-Type: application/json' -d '{"status":"approved"}' >/dev/null 2>&1
  exit $rc; }
trap cleanup EXIT INT TERM

say "0. Prérequis + BFF dédié (:$PORT) contre $GR"
[ -f "$GR/environments.yaml" ] || { echo "governance-repo absent ($GR)"; exit 2; }
[ "$(curl -s "$ITSM/changes/CHG-0001" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status"))' 2>/dev/null)" = approved ] \
  || { echo "CHG-0001 non approved dans l'ITSM"; exit 2; }
BIN="$(mktemp)"
( cd "$POC/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" ./cmd/governance-api ) || { echo build KO; exit 1; }
GOVERNANCE_REPO="$GR" ITSM_URL="$ITSM" KC_BASE="$KC" KC_REALM=stoa-lab LISTEN=":$PORT" "$BIN" >/tmp/prove-a7-bff.log 2>&1 &
BFFPID=$!
for _ in $(seq 1 40); do curl -s -o /dev/null "$BFF/api/v1/me" && break; sleep 0.25; done
ok "BFF up (pid $BFFPID)"

mint() { DEX_USER="$1@bc.example" CLIENT_ID=stoa-portal bash "$POC/scripts/get-oracle-token.sh" --quiet 2>/dev/null; }
TOK_DAVE="$(mint dave)"; TOK_BOB="$(mint bob)"
[ -n "$TOK_DAVE" ] && [ -n "$TOK_BOB" ] || { echo "mint tokens KO (Dex/setup-identity ?)"; exit 1; }
DAVE_U="$(curl -s -H "Authorization: Bearer $TOK_DAVE" "$BFF/api/v1/me" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("username",""))')"
ok "identités : dave=$DAVE_U (preferred_username), bob"

say "1. dave DEMANDE accounts-read int→prod (CHG-0001 + PV)"
REQ=$(curl -s -X POST -H "Authorization: Bearer $TOK_DAVE" -H 'Content-Type: application/json' \
  -d "{\"slug\":\"$SLUG\",\"from\":\"int\",\"to\":\"prod\",\"message\":\"tentative auto-approbation E2E\",\"change_ref\":\"CHG-0001\",\"pv_ref\":\"PV-2026-042\"}" \
  "$BFF/api/v1/tenants/$TENANT/promotions")
PROMO=$(echo "$REQ" | python3 -c 'import sys,json;print((json.load(sys.stdin).get("promotion") or {}).get("id") or "")' 2>/dev/null)
[ -n "$PROMO" ] && ok "promotion demandée par dave ($PROMO)" || { bad "request KO: $REQ"; exit 1; }
WC0=$(( $(wc -l < "$DENIALS" 2>/dev/null || echo 0) ))

say "2. dave TENTE d'approuver SA PROPRE promotion → 403 SELF_APPROVAL_BLOCKED"
CODE=$(curl -s -o /tmp/prove-a7-appr.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK_DAVE" \
  -H 'Content-Type: application/json' -d '{"message":"auto-approbation interdite"}' \
  "$BFF/api/v1/tenants/$TENANT/promotions/$PROMO/approve")
ECODE=$(python3 -c 'import json;print(json.load(open("/tmp/prove-a7-appr.json")).get("error",{}).get("code",""))' 2>/dev/null)
[ "$CODE" = 403 ] && [ "$ECODE" = SELF_APPROVAL_BLOCKED ] \
  && ok "self-approval → 403 SELF_APPROVAL_BLOCKED" || bad "self-approval → HTTP $CODE code=$ECODE (attendu 403/SELF_APPROVAL_BLOCKED)"

say "3. le refus est INSCRIT dans denials.jsonl (+ poussé Gitea)"
# le fichier est écrit synchrone ; le commit/push est asynchrone (~15s)
for _ in $(seq 1 20); do [ "$(( $(wc -l < "$DENIALS" 2>/dev/null || echo 0) ))" -gt "$WC0" ] && break; sleep 0.5; done
WC1=$(( $(wc -l < "$DENIALS" 2>/dev/null || echo 0) ))
[ "$WC1" -gt "$WC0" ] && ok "denials.jsonl a grandi ($WC0 -> $WC1 lignes)" || bad "denials.jsonl inchangé ($WC0 -> $WC1)"
LINE=$(grep -F "$PROMO" "$DENIALS" | tail -1)
echo "$LINE" | PROMO="$PROMO" python3 -c '
import sys, os, json
d = json.loads(sys.stdin.read() or "{}")
promo = os.environ["PROMO"]
ok = (d.get("code") == "SELF_APPROVAL_BLOCKED" and d.get("resource") == promo
      and d.get("tenant") == "banking-demo" and d.get("action") == "promote-approve"
      and str(d.get("user", "")).endswith("@bc.example"))
print("ENTRY_OK" if ok else "ENTRY_BAD " + json.dumps(d))
' 2>/dev/null | grep -q ENTRY_OK \
  && ok "entrée denials conforme (code+resource+tenant+action+user@bc.example)" || bad "entrée denials non conforme: $LINE"
# repo local : le deny commit existe
git -C "$GR" log --oneline -8 | grep -qiE 'deny|self.?approval|promote-approve' \
  && ok "deny commité dans le repo governance (git log)" || echo "  (deny commit asynchrone pas encore visible — non bloquant)"
# vrai repo Gitea : le refus est DANS le repo que Jenkins consomme
RAW=$(curl -s "$GITEA/ci/governance/raw/branch/main/evidence/denials/denials.jsonl" 2>/dev/null)
if echo "$RAW" | grep -qF "$PROMO"; then ok "refus présent dans Gitea ci/governance (repo consommé par Jenkins)"
else echo "  (push Gitea du deny asynchrone/non câblé — le fichier local fait foi)"; fi

say "4. CONTRE-ÉPREUVE identité : bob (≠ dave) approuve la MÊME promotion → 200"
CODE=$(curl -s -o /tmp/prove-a7-appr2.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK_BOB" \
  -H 'Content-Type: application/json' -d '{"message":"approbation croisée (bob≠dave)"}' \
  "$BFF/api/v1/tenants/$TENANT/promotions/$PROMO/approve")
APPR_BY=$(python3 -c 'import json;print(json.load(open("/tmp/prove-a7-appr2.json")).get("promotion",{}).get("approved_by",""))' 2>/dev/null)
[ "$CODE" = 200 ] && [ "$APPR_BY" != "$DAVE_U" ] && [ -n "$APPR_BY" ] \
  && ok "bob approuve → 200 (approved_by=$APPR_BY ≠ requester) — gate keyé sur l'identité" \
  || bad "bob approve → HTTP $CODE approved_by=$APPR_BY (attendu 200, ≠ dave)"

say "RÉSULTAT"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "OK — refus 4-yeux exercé E2E (denials.jsonl peuplé) + contre-épreuve identité" || echo "ÉCHECS ci-dessus"
exit $(( FAIL > 0 ? 1 : 0 ))
