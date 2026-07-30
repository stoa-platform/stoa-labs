#!/usr/bin/env bash
# test-txn-wso2.sh — PREUVE LIVE de la tranche analytics WSO2 (goal A3, ADR-070) :
# parité 3/3 avec APISIX + webMethods. Chaîne prouvée :
#   WSO2 :8243 --OTLP/gRPC--> wso2-otel-tap ─┬─► forward ─► otel-lgtm (Tempo)
#                                            └─► stoa.txn.wso2 ─► Data Prepper ─► OpenSearch txn-{tenant}
# Le record porte le trace_id NATIF du span → pivot Tempo↔OpenSearch (le même id
# des deux côtés). Prérequis : socle + overlay analytics up, WSO2 pointé sur le
# tap (WSO2_OTLP_TARGET=wso2-otel-tap:4317 ./scripts/setup-wso2-otel.sh) + restart.
set -uo pipefail

KC=http://localhost:8480
WSO2=https://localhost:8243
OS=https://localhost:9201
OS_PASS="${OPENSEARCH_PASSWORD:?Variable OPENSEARCH_PASSWORD absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
API_PATH="/accounts-read/v1/1.0.0/accounts"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
osq() { curl -sk -u "admin:$OS_PASS" "$@"; }

echo "=== 0. Prérequis ==="
docker ps --filter name=poc-wso2-otel-tap --format '{{.Names}}' | grep -q poc-wso2-otel-tap && ok "wso2-otel-tap up" || { bad "wso2-otel-tap absent — up l'overlay analytics"; exit 2; }
docker exec poc-wso2am sh -c "grep -q 'wso2-otel-tap:4317' /home/wso2carbon/wso2am-4.5.0/repository/conf/deployment.toml" && ok "WSO2 pointe le tap" || bad "WSO2 ne pointe pas le tap (rejouer setup-wso2-otel.sh WSO2_OTLP_TARGET=wso2-otel-tap:4317 + restart)"

echo "=== 1. Token client_credentials (secret via KC admin) ==="
KCTOK=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))")
CID=$(curl -s -H "Authorization: Bearer $KCTOK" "$KC/admin/realms/stoa-lab/clients?clientId=accounts-read-consumer" | python3 -c "import json,sys;c=json.load(sys.stdin);print(c[0]['id'] if c else '')")
SECRET=$(curl -s -H "Authorization: Bearer $KCTOK" "$KC/admin/realms/stoa-lab/clients/$CID/client-secret" | python3 -c "import json,sys;print(json.load(sys.stdin).get('value',''))")
TOK=$(curl -s -X POST "$KC/realms/stoa-lab/protocol/openid-connect/token" -d "grant_type=client_credentials&client_id=accounts-read-consumer&client_secret=$SECRET&scope=accounts.read" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))")
[ -n "$TOK" ] && ok "token obtenu" || { bad "mint token KO"; exit 1; }

echo "=== 2. Appel data-plane WSO2 (le status importe peu : la transaction est capturée) ==="
CODE=$(curl -sk -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $TOK" "$WSO2$API_PATH")
ok "appel WSO2 :8243 -> HTTP $CODE"

echo "=== 3. Le tap a émis un record avec un trace_id ==="
sleep 6
TID=$(docker logs poc-wso2-otel-tap --since 30s 2>&1 | grep "txn wso2" | tail -1 | sed -n 's/.*trace_id=\([0-9a-f]\{32\}\).*/\1/p')
[ -n "$TID" ] && ok "record émis, trace_id=$TID" || { bad "aucun record émis par le tap (WSO2 exporte-t-il ? gzip ?)"; exit 1; }

echo "=== 4. PIVOT — le MÊME trace_id dans Tempo (service.name=wso2, trace forwardée) ==="
sleep 2
SVC=$(docker exec poc-otel-lgtm curl -s "http://localhost:3200/api/traces/$TID" | python3 -c "
import json,sys
d=json.load(sys.stdin)
svcs=set()
for b in d.get('batches',[]):
    for a in b.get('resource',{}).get('attributes',[]):
        if a['key']=='service.name': svcs.add(a['value'].get('stringValue'))
print(','.join(sorted(svcs)))" 2>/dev/null)
[ "$SVC" = "wso2" ] && ok "Tempo: trace $TID présente, service.name=wso2 (forward OK, Tempo inchangé)" || bad "Tempo: service.name=$SVC (attendu wso2)"

echo "=== 5. PIVOT — le MÊME trace_id dans OpenSearch txn-{tenant} ==="
# Fenêtre large : la chaîne WSO2 (flush BatchSpanProcessor ~périodique) → tap →
# Kafka → Data Prepper (delay 1s + batch) → OpenSearch prend ~15-40 s bout-en-bout.
for i in $(seq 1 30); do
  DOC=$(osq "$OS/txn-*/_search" -H 'Content-Type: application/json' -d "{\"query\":{\"term\":{\"trace_id\":\"$TID\"}},\"size\":1}" 2>/dev/null)
  N=$(python3 -c "import json,sys;print(len(json.loads('''$DOC''')['hits']['hits']))" 2>/dev/null || echo 0)
  [ "$N" = "1" ] && break; sleep 3
done
if [ "$N" = "1" ]; then
  python3 - "$DOC" <<'PY' && ok "OpenSearch: doc txn wso2 présent, pivot trace_id confirmé" || bad "doc wso2 incohérent"
import json,sys
s=json.loads(sys.argv[1])['hits']['hits'][0]['_source']
assert s['gateway']=='wso2', s.get('gateway')
assert s['provider']=='wso2'
assert s['tenant']=='accounts-team', s.get('tenant')
assert s['api']=='accounts-read'
assert isinstance(s['http_status'], int)
assert s['status'] in ('success','error')
assert s.get('redaction_applied') is True
assert s['@timestamp']
print('   doc:', {k:s.get(k) for k in ('gateway','tenant','api','http_status','status','trace_id','latency_ms')})
PY
else
  bad "aucun doc OpenSearch pour $TID (pipeline stoa-txn-wso2 down ?)"
fi

echo "=== 6. UN SEUL doc par trace (dedup live : le tap émet 1 record/trace, pas 1/span) ==="
CNT=$(osq "$OS/txn-*/_count" -H 'Content-Type: application/json' -d "{\"query\":{\"term\":{\"trace_id\":\"$TID\"}}}" 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('count',0))" 2>/dev/null)
[ "$CNT" = "1" ] && ok "1 doc pour ce trace_id (le tap n'émet que le span RACINE porteur des attrs API : 1/trace, batch-indépendant)" || bad "$CNT docs pour ce trace_id (dedup cassé)"

echo "=== 7. Autorité de redaction unique : aucun corps/headers bruts côté span ==="
NOBODY=$(python3 -c "
import json
s=json.loads('''$DOC''')['hits']['hits'][0]['_source']
print('ok' if ('response_body' not in s and 'request_headers' not in s) else 'ko')" 2>/dev/null)
[ "$NOBODY" = "ok" ] && ok "métadonnées seules (spans sans corps — ADR-070 respecté par construction)" || bad "un corps/headers a fuité dans le doc"

echo "=== 8. Parité 3/3 : les trois gateways produisent des docs txn ==="
GW=$(osq "$OS/txn-*/_search" -H 'Content-Type: application/json' -d '{"size":0,"aggs":{"gw":{"terms":{"field":"gateway"}}}}' 2>/dev/null | python3 -c "
import json,sys
b=json.load(sys.stdin)['aggregations']['gw']['buckets']
print(','.join(sorted(x['key'] for x in b)))" 2>/dev/null)
echo "   gateways avec docs txn: $GW"
for g in apisix webmethods wso2; do
  echo "$GW" | grep -q "$g" && ok "tranche $g présente" || bad "tranche $g absente"
done

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
