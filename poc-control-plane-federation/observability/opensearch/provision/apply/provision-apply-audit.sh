#!/usr/bin/env bash
# provision-apply-audit.sh — ADR-070 idempotent OpenSearch provisioning for the
# APPLY/converge plane audit trail (labctl apply-uac). It mirrors the onboarding
# audit provisioning: a per-tenant audit-apply-{tenant} index gets a strict index
# template, and the SAME per-tenant viewer role (now broadened to audit-*-{tenant}*)
# scopes each tenant to ITS OWN audit docs across BOTH planes (onboarding + apply).
#
# Provisioned (idempotent — PUT is create-or-replace):
#   1. index template  audit-apply   (audit-apply-* mapping, strict; adds the
#                                      apply fields resource/gateway/principal)
#   2. per tenant {banking-demo, payments-team}: the audit viewer role re-applied
#      with the broadened index pattern audit-*-{tenant}* (client_ip masked).
#
# The apply plane (labctl, internal/audit) writes the docs under the admin
# credential; these roles are the least-privilege READ side a tenant auditor uses.
set -euo pipefail

OS_URL="${OS_URL:-https://localhost:9201}"
OS_AUTH="${OS_AUTH:-admin:Stoa!Passw0rd2026}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ONB="$DIR/../onboarding"
CURL=(/usr/bin/curl -s -k -u "$OS_AUTH")

echo "[1/3] index template audit-apply (audit-apply-* mapping)"
"${CURL[@]}" -X PUT "$OS_URL/_index_template/audit-apply" \
  -H 'Content-Type: application/json' \
  --data-binary @"$DIR/index-template-audit-apply.json"; echo

# re-apply each tenant viewer role with the broadened audit-*-{tenant}* pattern
apply_role() {
  local tenant="$1" role="tenant-${1}-audit-viewer"
  echo "  - role $role (read-only on audit-*-${tenant}* : onboarding + apply)"
  "${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/roles/$role" \
    -H 'Content-Type: application/json' \
    --data-binary @"$ONB/role-tenant-${tenant}-audit-viewer.json"; echo
}

echo "[2/3] tenant banking-demo apply-audit RBAC"; apply_role banking-demo
echo "[3/3] tenant payments-team apply-audit RBAC"; apply_role payments-team

echo "done. Apply-plane tenant isolation proof:"
echo "    curl -s -k -u banking-audit-viewer:Stoa!Audit2026  $OS_URL/audit-apply-banking-demo/_search   # 200"
echo "    curl -s -k -u banking-audit-viewer:Stoa!Audit2026  $OS_URL/audit-apply-payments-team/_search  # 403"
