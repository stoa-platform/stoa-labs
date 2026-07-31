#!/usr/bin/env bash
# provision-banking-demo-txn.sh — ADR-070/072 idempotent txn-analytics RBAC for
# the tenant banking-demo. After the accounts-read federation was re-tagged
# (backstage.owner accounts-team -> banking-demo), the APISIX kafka-logger tags
# txn events tenant=banking-demo on the next `labctl apply`, so the data-plane
# analytics now lands in txn-banking-demo. This provisions the matching
# least-privilege viewer (mirror of tenant-accounts-team-viewer): read-only on
# txn-banking-demo*, with the SAME PII masking (monitoring-capture-model:
# response_body + req/resp headers masked).
#
# Security role/user/rolesmapping only (the substance). The OpenSearch Dashboards
# tenant + saved index-pattern (cosmetic OSD UI sugar) mirror provision.sh [7/7]
# and are left as a follow-up.
set -euo pipefail
OS_URL="${OS_URL:-https://localhost:9201}"
OS_AUTH="${OS_AUTH:?Variable OS_AUTH absente — définissez-la (\"admin:<mot-de-passe>\", voir poc-control-plane-federation/.env.example)}"
VIEWER_PASS="${VIEWER_PASS:?Variable VIEWER_PASS absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
# TLS (É0) — same knobs as provision.sh: OPENSEARCH_CA_FILE verifies against the
# enterprise CA; OPENSEARCH_INSECURE=false forces strict system trust; the
# default (unset/true) keeps -k for the PoC's self-signed demo certs ONLY.
CURL=(/usr/bin/curl -s -u "$OS_AUTH" -H 'Content-Type: application/json')
if [ -n "${OPENSEARCH_CA_FILE:-}" ]; then
  CURL+=(--cacert "$OPENSEARCH_CA_FILE")
else
  case "${OPENSEARCH_INSECURE:-true}" in 1|true|yes|on) CURL+=(-k) ;; esac
fi

echo "[1/3] role tenant-banking-demo-viewer (read-only txn-banking-demo*, PII masked)"
"${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/roles/tenant-banking-demo-viewer" -d '{
  "description": "ADR-070 tenant viewer: read-only on txn-banking-demo* (+ .ds-* backing) with PII masked. Mirror of tenant-accounts-team-viewer.",
  "cluster_permissions": [],
  "index_permissions": [{
    "index_patterns": ["txn-banking-demo*", ".ds-txn-banking-demo-*"],
    "dls": "", "fls": [],
    "masked_fields": ["user_ip","user_agent","response_body","request_headers.*","response_headers.*"],
    "allowed_actions": ["read","indices:data/read/search","indices:data/read/get","indices:admin/mappings/get","indices:monitor/settings/get","indices:admin/get"]
  }],
  "tenant_permissions": [{"tenant_patterns": ["banking-demo"], "allowed_actions": ["kibana_all_read"]}]
}'; echo

echo "[2/3] internaluser banking-txn-viewer (backend_role tenant-banking-demo)"
# VIEWER_PASS ne passe JAMAIS en argv (ADR-074) : il traverse l'environnement du
# process enfant (VP=... python3 ...), pas un paramètre de ligne de commande ;
# python3 écrit directement le JSON (json.dump, échappement correct — pas de
# concaténation de guillemets) dans un fichier TEMPORAIRE 0600 hors dépôt
# (mktemp sans répertoire cible).
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE"' EXIT
( umask 077
  VP="$VIEWER_PASS" python3 -c '
import json, os, sys
payload = {
    "password": os.environ["VP"],
    "backend_roles": ["tenant-banking-demo"],
    "attributes": {"tenant": "banking-demo"},
    "description": "ADR-070 test txn viewer for banking-demo (RBAC test without SSO).",
}
with open(sys.argv[1], "w") as out:
    json.dump(payload, out)
' "$PAYLOAD_FILE"
)
"${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/internalusers/banking-txn-viewer" \
  --data-binary @"$PAYLOAD_FILE"; echo
rm -f "$PAYLOAD_FILE"
trap - EXIT

echo "[3/3] rolesmapping tenant-banking-demo-viewer"
"${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/rolesmapping/tenant-banking-demo-viewer" -d '{
  "users": ["banking-txn-viewer"],
  "backend_roles": ["tenant-banking-demo"],
  "description": "ADR-070 mapping: banking-txn-viewer + backend_role tenant-banking-demo -> tenant-banking-demo-viewer."
}'; echo

echo "done. txn-banking-demo viewer ready (read-only, PII masked)."
