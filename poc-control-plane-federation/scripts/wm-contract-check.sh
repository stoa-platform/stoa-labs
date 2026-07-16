#!/usr/bin/env bash
# wm-contract-check.sh — harnais de contrat fixpack (ADR-073).
#
# Le pont wm-trace-bridge repose sur des comportements de webMethods 10.15
# NON DOCUMENTÉS, vérifiés in-situ (param `ids`, tableau `externalCalls`,
# noms de payloads live ≠ swagger). Ce script re-valide ce contrat contre le
# gateway VIVANT : à lancer après chaque fixpack/upgrade, avant tout rollout.
#
#   1. invoque l'API accounts-read avec un traceparent connu ;
#   2. récupère l'événement BRUT reçu par le bridge (GET /debug/last-event,
#      le bridge doit être joignable depuis l'hôte — port-forward ou exec) ;
#   3. vérifie chaque clause du contrat (jq) — sortie PASS/FAIL par clause.
set -uo pipefail
cd "$(dirname "$0")/.."

WM="${WM_DATAPLANE_URL:-http://localhost:5555}"
BRIDGE="${WM_BRIDGE_DEBUG_URL:-}"   # ex. http://localhost:9100 ; vide => docker exec
KC="${KC_TOKEN_URL:-http://localhost:8480/realms/stoa-lab/protocol/openid-connect/token}"

get_cred() { awk -v sec="[keycloak]" -v k="$1" '$0==sec{f=1;next} f&&/^\[/{exit} f{p=index($0,"="); if(p){key=substr($0,1,p-1); gsub(/ /,"",key); if(key==k){v=substr($0,p+1); sub(/^ +/,"",v); print v; exit}}}' labctl-credentials.txt; }

bridge_last_event() {
  if [[ -n "$BRIDGE" ]]; then
    curl -sf "$BRIDGE/debug/last-event"
  else
    # le conteneur est distroless (pas de curl) : on passe par un conteneur
    # outillé éphémère sur le même réseau compose.
    docker run --rm --network stoa-labs-poc_poc curlimages/curl:8.10.1 \
      -sf "http://wm-trace-bridge:9100/debug/last-event"
  fi
}

fail=0
check() { # check LIBELLÉ EXPRESSION_JQ (doit rendre true)
  local label="$1" expr="$2"
  if [[ "$(jq -r "$expr" /tmp/wm-contract-event.json 2>/dev/null)" == "true" ]]; then
    echo "  PASS  $label"
  else
    echo "  FAIL  $label   (jq: $expr)"
    fail=1
  fi
}

echo "═══ 1/3 Invocation avec traceparent connu"
TOK=$(curl -s -d grant_type=client_credentials -d client_id="$(get_cred clientId)" \
  -d client_secret="$(get_cred clientSecret)" "$KC" | jq -r '.access_token // empty')
[[ -z "$TOK" ]] && { echo "✗ pas de token Keycloak"; exit 1; }
TP_ID="$(printf 'c0%030d' $((RANDOM * RANDOM)))"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" \
  -H "traceparent: 00-${TP_ID}-00000000000000aa-01" \
  "$WM/gateway/accounts-read/1.0.0/accounts")
[[ "$code" != "200" ]] && { echo "✗ invocation HTTP $code (gateway mi-recycle ?)"; exit 1; }
echo "  ✓ 200 (traceparent $TP_ID)"

echo "═══ 2/3 Attente de l'événement au bridge (dispatch ~10-40 s)"
deadline=$(( $(date +%s) + 120 ))
while :; do
  if bridge_last_event > /tmp/wm-contract-event.json 2>/dev/null \
     && [[ "$(jq -r '.requestHeaders.traceparent // ""' /tmp/wm-contract-event.json)" == *"$TP_ID"* ]]; then
    break
  fi
  (( $(date +%s) > deadline )) && { echo "✗ événement jamais reçu (bridge/destination cassés ?)"; exit 1; }
  sleep 5
done
echo "  ✓ événement reçu"

echo "═══ 3/3 Clauses du contrat (comportements non documentés, ADR-073)"
check "eventType=Transactional"                  '.eventType == "Transactional"'
check "creationDate epoch ms (number)"           '(.creationDate | type) == "number" and .creationDate > 1700000000000'
check "totalTime ms (number)"                    '(.totalTime | type) == "number"'
check "responseCode est une STRING"              '(.responseCode | type) == "string"'
check "requestHeaders est un OBJET"              '(.requestHeaders | type) == "object"'
check "traceparent stocké dans requestHeaders"   '.requestHeaders.traceparent != null'
check "Authorization masquée à la source"        '(.requestHeaders.Authorization // "*") | test("^\\*+$")'
check "externalCalls[] présent"                  '(.externalCalls | type) == "array" and (.externalCalls | length) > 0'
check "externalCalls NATIVE_SERVICE_CALL fenêtré" '[.externalCalls[] | select(.externalCallType=="NATIVE_SERVICE_CALL") | (.callStartTime > 0 and .callEndTime >= .callStartTime)] | any'
check "payloads live = noms connus (sinon MAJ pipeline!)" '[keys[] | select(test("(?i)payload"))] - ["reqPayload","resPayload","nativeRequestPayload","nativeResponsePayload","messagePayload"] | length == 0'

if (( fail )); then
  echo
  echo "✗ CONTRAT ROMPU — le fixpack a changé un comportement : mettre à jour"
  echo "  observability/wm-trace-bridge/ (+ fixtures testdata/) et"
  echo "  observability/data-prepper/pipelines.yaml (drop payloads), cf. ADR-073."
  exit 1
fi
echo
echo "✓ Contrat intact — pont compatible avec ce niveau de fixpack."
