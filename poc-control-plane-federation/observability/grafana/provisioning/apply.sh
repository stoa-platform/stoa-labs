#!/usr/bin/env bash
# Idempotent live provisioning of the STOA federation observability bridge
# (ADR-070) into the OPEN, no-auth Grafana of the otel-lgtm container.
#
# What it provisions (all idempotent — safe to re-run):
#   1. OpenSearch-Txn datasource (type=elasticsearch, OpenSearch 2.x compatible)
#   2. Dashboard "STOA — Fédération (OTel + Transactions)" (uid stoa-fed-otel-txn)
#   3. Tempo -> OpenSearch correlation on trace_id (trace -> transaction pivot)
#
# Files in datasources/ and dashboards/ are ALSO bind-mounted into otel-lgtm for
# a fresh `up` (see docker-compose); this script is the live/imperative path and
# the apply path for the correlation (whose source datasource is read-only and
# thus not provisionable via a file we own). Datasource passwords live in the
# YAML and are re-sent here so a cold machine reproduces the full bridge.
#
# Usage:  observability/grafana/provisioning/apply.sh
# Env:    GRAFANA_URL (default http://localhost:3000)
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_OBS="$(cd "$HERE/../.." && pwd)"            # observability/
DASH_JSON="$REPO_OBS/grafana/dashboards/federation-otel-transactions.json"
OS_PASSWORD="${OS_PASSWORD:-Stoa!Passw0rd2026}"

say() { printf '\n=== %s ===\n' "$*"; }

# --- 1. OpenSearch datasource (idempotent: PUT by uid if present, else POST) ---
say "datasource OpenSearch-Txn"
DS_BODY=$(cat <<JSON
{
  "name": "OpenSearch-Txn", "uid": "opensearch-txn", "type": "elasticsearch",
  "access": "proxy", "url": "https://opensearch:9200", "database": "txn-*",
  "basicAuth": true, "basicAuthUser": "admin", "isDefault": false,
  "jsonData": {
    "esVersion": "7.10.0", "timeField": "@timestamp",
    "maxConcurrentShardRequests": 5, "logMessageField": "status",
    "logLevelField": "http_status", "tlsSkipVerify": true,
    "dataLinks": [ { "field": "trace_id", "name": "Voir la trace (Tempo)", "datasourceUid": "tempo", "url": "" } ]
  },
  "secureJsonData": { "basicAuthPassword": "${OS_PASSWORD}" }
}
JSON
)
EXIST_ID=$(curl -s "$GRAFANA_URL/api/datasources/uid/opensearch-txn" | python3 -c 'import sys,json;
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")' )
if [ -n "$EXIST_ID" ]; then
  curl -s -X PUT -H 'Content-Type: application/json' \
    "$GRAFANA_URL/api/datasources/uid/opensearch-txn" -d "$DS_BODY" >/dev/null
  echo "updated (id=$EXIST_ID)"
else
  curl -s -X POST -H 'Content-Type: application/json' \
    "$GRAFANA_URL/api/datasources" -d "$DS_BODY" >/dev/null
  echo "created"
fi

# --- 2. Dashboard (idempotent via overwrite:true on a fixed uid) ---
say "dashboard stoa-fed-otel-txn"
python3 - "$DASH_JSON" <<'PY' > /tmp/_stoa_dash_payload.json
import json, sys
d = json.load(open(sys.argv[1])); d.pop("id", None)
json.dump({"dashboard": d, "overwrite": True, "folderId": 0,
           "message": "provision: STOA federation OTel+Transactions (ADR-070)"}, sys.stdout)
PY
curl -s -X POST -H 'Content-Type: application/json' \
  "$GRAFANA_URL/api/dashboards/db" -d @/tmp/_stoa_dash_payload.json \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("status:", d.get("status"), "uid:", d.get("uid"), "version:", d.get("version"))'

# --- 3. Correlation Tempo -> OpenSearch on trace_id (idempotent by label) ---
say "correlation tempo -> opensearch-txn (trace -> transaction)"
HAVE=$(curl -s "$GRAFANA_URL/api/datasources/correlations" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
c=d.get("correlations", d) if isinstance(d,dict) else d
for x in (c or []):
    if x.get("sourceUID")=="tempo" and x.get("targetUID")=="opensearch-txn" and x.get("label")=="Transaction (OpenSearch)":
        print(x.get("uid","")); break
')
if [ -n "$HAVE" ]; then
  echo "already present (uid=$HAVE)"
else
  curl -s -X POST -H 'Content-Type: application/json' \
    "$GRAFANA_URL/api/datasources/uid/tempo/correlations" \
    -d '{"targetUID":"opensearch-txn","label":"Transaction (OpenSearch)","description":"Pivot trace -> transaction d audit (ADR-070).","type":"query","config":{"field":"traceID","target":{"query":"trace_id:\"${__value.raw}\""},"transformations":[]}}' \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print("created:", d.get("result",{}).get("uid", d.get("message")))'
fi

say "done — dashboard at $GRAFANA_URL/d/stoa-fed-otel-txn"
