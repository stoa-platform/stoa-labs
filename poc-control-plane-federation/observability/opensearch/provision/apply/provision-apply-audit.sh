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
# OS_AUTH dérive de OPENSEARCH_PASSWORD — variable canonique unique (voir
# .env.example) : un seul endroit à renseigner, aucune divergence possible
# entre les noms hérités qui désignent le même mot de passe admin.
OS_AUTH="admin:${OPENSEARCH_PASSWORD:?Variable OPENSEARCH_PASSWORD absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ONB="$DIR/../onboarding"
# LE -k ÉTAIT CÂBLÉ EN DUR ICI (corrigé le 2026-09-13) — pas même un défaut
# permissif : un affaiblissement INCONDITIONNEL, que ni knob ni globale ne
# pouvait retirer. Ses trois scripts frères portaient déjà le couple
# CA_FILE / INSECURE ; celui-ci avait été oublié, et la porte qui l'aurait dit
# (test-e0-blockers.sh) tient une liste À LA MAIN de « 3 scripts » où il ne
# figure pas. Trouvé par ci/lint-permissive-defaults.sh, qui cherche l'EFFET
# (`-k`) et pas le nom d'un knob — justement parce qu'un nom peut manquer.
# Même ordre que les frères : le chemin SÛR a la priorité, l'affaiblissement se
# demande EXPLICITEMENT, et son défaut est `false`.
CURL=(/usr/bin/curl -s -u "$OS_AUTH")
if [ -n "${OPENSEARCH_CA_FILE:-}" ]; then
  CURL+=(--cacert "$OPENSEARCH_CA_FILE")
else
  case "${OPENSEARCH_INSECURE:-false}" in 1|true|yes|on) CURL+=(-k) ;; esac
fi

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
echo "    curl -s -k -u banking-audit-viewer:\$AUDIT_VIEWER_PASS  $OS_URL/audit-apply-banking-demo/_search   # 200  (-k : lab auto-signe ; en prod, --cacert "$OPENSEARCH_CA_FILE")"
echo "    curl -s -k -u banking-audit-viewer:\$AUDIT_VIEWER_PASS  $OS_URL/audit-apply-payments-team/_search  # 403"
