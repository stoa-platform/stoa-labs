#!/usr/bin/env bash
# wm-otel-setup.sh — câble l'export de traces du webMethods RÉEL vers Tempo
# (ADR-073) : custom destination "StoaTraceBridge" (External endpoint →
# wm-trace-bridge:9100/events) + global policy "Transaction logging"
# (Log Invocation : headers ON / payloads OFF, destination CUSTOM) + traceparent
# dans watt.server.http.forwardableHeaders.
#
# IDEMPOTENT : create-or-update sur chaque objet ; relançable à volonté.
# Persistance : destination + policy vivent dans l'ES EXTERNE (poc-wm-es) →
# survivent au keepalive (docker restart) ET au recreate du conteneur.
# Les watt.* (extended settings) vivent dans server.cnf (FS conteneur) →
# survivent au restart, PERDUS sur force-recreate → relancer ce script.
#
# Découvert in-situ (2026-06-12, apigateway-trial:10.15) :
#   - une custom destination EST un policyAction templateKey=customDestination
#     (POST /rest/apigateway/policyActions, cf. collection Postman officielle
#     github.com/SoftwareAG/webmethods-api-gateway custom-destination) ;
#   - le Log Invocation la référence par {destinationType: CUSTOM, ids: [<nom>]}
#     — le paramètre `ids` n'est PAS dans le template ni la doc : capturé sur
#     ce que l'UI 10.15 enregistre (PUT via apigatewayui) ;
#   - le gateway POSTe UN événement JSON par requête (Content-Type:
#     application/json, UA "Mozilla/4.0 [en] (WinNT; I)").
set -euo pipefail
cd "$(dirname "$0")/.."

WM="${WM_ADMIN_URL:-http://localhost:5555}"
AUTH="${WM_ADMIN_AUTH:-Administrator:manage}"
BRIDGE_URL="${WM_BRIDGE_URL:-http://wm-trace-bridge:9100/events}"
DEST_NAME="StoaTraceBridge"

api() { # api METHOD PATH [JSON_FILE] — exit non-zéro sur HTTP>=400, corps sur stdout
  local m="$1" p="$2" f="${3:-}" out="" rc=0
  if [[ -n "$f" ]]; then
    out=$(curl -sS --fail-with-body -u "$AUTH" -X "$m" "$WM/rest/apigateway$p" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' -d @"$f") || rc=$?
  else
    out=$(curl -sS --fail-with-body -u "$AUTH" -X "$m" "$WM/rest/apigateway$p" -H 'Accept: application/json') || rc=$?
  fi
  if (( rc != 0 )); then
    echo "ERREUR api $m $p (curl exit $rc ; 7=connexion refusée — gateway down ou mi-boot du recycle ~23 min, 22=HTTP>=400) : ${out:-<pas de corps>}" >&2
    return "$rc"
  fi
  printf '%s' "$out"
}

echo "═══ 0/4 Attente readiness gateway (boot 3-7 min possible après recycle/expiry)"
deadline=$(( $(date +%s) + 600 ))
until curl -sf -u "$AUTH" "$WM/rest/apigateway/health" >/dev/null 2>&1; do
  if (( $(date +%s) > deadline )); then echo "✗ gateway non prêt après 10 min ($WM)"; exit 1; fi
  sleep 10
done
echo "  ✓ gateway up"

echo "═══ 1/4 Custom destination '$DEST_NAME' → $BRIDGE_URL"
# Une custom destination est identifiée par son paramètre customDestinationName
# (le champ names[] est forcé à "Custom Destination" par le serveur).
existing_id=$(api GET "/policyActions?policyType=customDestination" \
  | python3 -c "
import json,sys
for a in json.load(sys.stdin).get('policyAction', []):
    if a.get('templateKey') != 'customDestination': continue
    for p in a.get('parameters', []):
        if p.get('templateKey') == 'customDestinationName' and p.get('values') == ['$DEST_NAME']:
            print(a['id']); break
" | head -1)

cat > /tmp/wm-otel-cd.json <<EOF
{
  "policyAction": {
    "names": [{"value": "$DEST_NAME", "locale": "EN"}],
    "templateKey": "customDestination",
    "parameters": [
      {"templateKey": "customDestinationName", "values": ["$DEST_NAME"]},
      {"templateKey": "transformationConditions", "parameters": [
        {"templateKey": "logicalConnector", "values": ["OR"]}
      ]},
      {"templateKey": "customExtensionAction", "values": ["customAction"]},
      {"templateKey": "customExtensionType", "values": ["externalCallout"]},
      {"templateKey": "externalEndpoint", "parameters": [
        {"templateKey": "endpointUri", "values": ["$BRIDGE_URL"]},
        {"templateKey": "externalEndpointMethod", "values": ["POST"]},
        {"templateKey": "connectTimeout", "values": ["10"]},
        {"templateKey": "readTimeout", "values": ["10"]}
      ]},
      {"templateKey": "customExtensionRequestProcessing", "parameters": [
        {"templateKey": "requestPayload", "values": [""]}
      ]},
      {"templateKey": "mashupHeaderTransformation", "parameters": [
        {"templateKey": "useIncomingHeaders", "values": ["false"]}
      ]},
      {"templateKey": "customExtensionResponseProcessing", "parameters": [
        {"templateKey": "copyEntireResponse", "values": ["false"]},
        {"templateKey": "abortInCaseOfFailure", "values": ["false"]}
      ]}
    ]
  }
}
EOF
# ⚠️ PAS d'abonnement customDestinationEvents (ERROR/POLICYVIOLATION) sur cette
# destination : vérifié in-situ 2026-06-12, l'abonnement DÉTOURNE les events du
# data store interne SANS les livrer à l'endpoint (perdus) — les 401 disparaissent
# alors de gateway_default_analytics_policyviolationevents* ET le poller PV du
# bridge n'a plus de source. Transaction events seuls ici (via Log Invocation).
if [[ -n "$existing_id" ]]; then
  api PUT "/policyActions/$existing_id" /tmp/wm-otel-cd.json >/dev/null
  echo "  ✓ mise à jour ($existing_id)"
else
  existing_id=$(api POST "/policyActions" /tmp/wm-otel-cd.json | python3 -c "import json,sys;print(json.load(sys.stdin)['policyAction']['id'])")
  echo "  ✓ créée ($existing_id)"
fi

echo "═══ 2/4 Global policy action Log Invocation (headers ON, payloads OFF) → CUSTOM/$DEST_NAME"
cat > /tmp/wm-otel-li.json <<EOF
{
  "policyAction": {
    "id": "GlobalLogInvocationPolicyAction",
    "names": [{"value": "Log Invocation", "locale": "en"}],
    "templateKey": "logInvocation",
    "parameters": [
      {"templateKey": "storeRequestHeaders", "values": ["true"]},
      {"templateKey": "storeResponseHeaders", "values": ["true"]},
      {"templateKey": "storeRequestPayload", "values": ["false"]},
      {"templateKey": "storeResponsePayload", "values": ["false"]},
      {"templateKey": "storeAsZip", "values": ["false"]},
      {"templateKey": "logGenerationFrequency", "values": ["Always"]},
      {"templateKey": "destination", "parameters": [
        {"templateKey": "destinationType", "values": ["CUSTOM"]},
        {"templateKey": "ids", "values": ["$DEST_NAME"]}
      ]}
    ]
  }
}
EOF
api PUT "/policyActions/GlobalLogInvocationPolicyAction" /tmp/wm-otel-li.json >/dev/null
echo "  ✓ GlobalLogInvocationPolicyAction"

echo "═══ 3/4 Activation de la system policy 'Transaction logging'"
active=$(api GET "/policies/GlobalLogInvocationPolicy" | python3 -c "import json,sys;print(json.load(sys.stdin)['policy']['active'])")
if [[ "$active" == "True" || "$active" == "true" ]]; then
  echo "  ✓ déjà active"
else
  api PUT "/policies/GlobalLogInvocationPolicy/activate" >/dev/null
  echo "  ✓ activée"
fi

echo "═══ 4/4 traceparent/tracestate dans watt.server.http.forwardableHeaders"
# Read-modify-write : on ne remplace pas la liste B3 par défaut, on étend.
# (Observé in-situ : traceparent est DÉJÀ forwardé au backend par le routing
# 10.15 ; on aligne quand même la liste déclarée pour W3C trace context et
# tracestate — config server.cnf, perdue sur recreate.)
current=$(api GET "/configurations/settings" | python3 -c "
import json,sys
print(json.load(sys.stdin)['allSettings']['wattKeys'].get('watt.server.http.forwardableHeaders',
  'x-request-id,x-b3-traceid,x-b3-spanid,x-b3-parentspanid,x-b3-sampled,x-b3-flags,x-ot-span-context'))")
want="$current"
for h in traceparent tracestate; do
  [[ ",$want," == *",$h,"* ]] || want="$want,$h"
done
if [[ "$want" == "$current" ]]; then
  echo "  ✓ déjà en place"
else
  printf '{"wattKeys": {"watt.server.http.forwardableHeaders": "%s"}}' "$want" > /tmp/wm-otel-watt.json
  api PUT "/configurations/settings" /tmp/wm-otel-watt.json >/dev/null
  echo "  ✓ $want"
fi

echo
echo "Câblage OK. Vérif : appel data-plane → trace service.name=webmethods dans Grafana/Tempo (~30 s de latence de dispatch)."
