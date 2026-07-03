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
OS_AUTH="${OS_AUTH:-admin:Stoa!Passw0rd2026}"
CURL=(/usr/bin/curl -s -k -u "$OS_AUTH" -H 'Content-Type: application/json')

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
"${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/internalusers/banking-txn-viewer" -d '{
  "password": "Stoa!Viewer2026",
  "backend_roles": ["tenant-banking-demo"],
  "attributes": {"tenant": "banking-demo"},
  "description": "ADR-070 test txn viewer for banking-demo (RBAC test without SSO)."
}'; echo

echo "[3/3] rolesmapping tenant-banking-demo-viewer"
"${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/rolesmapping/tenant-banking-demo-viewer" -d '{
  "users": ["banking-txn-viewer"],
  "backend_roles": ["tenant-banking-demo"],
  "description": "ADR-070 mapping: banking-txn-viewer + backend_role tenant-banking-demo -> tenant-banking-demo-viewer."
}'; echo

echo "done. txn-banking-demo viewer ready (read-only, PII masked)."
