#!/usr/bin/env bash
# provision-onboarding-audit.sh — ADR-070 idempotent OpenSearch provisioning for
# the SECURED onboarding-api audit trail. It mirrors provision.sh (txn) for the
# onboarding-audit data: a per-tenant index gets an index template, and a
# role<->index-pattern RBAC role scopes each tenant to ITS OWN audit docs ONLY —
# exactly the tenant-accounts-team-viewer isolation pattern.
#
# Provisioned (idempotent — safe to re-run; PUT is create-or-replace):
#
#   1. index template  audit-onboarding   (audit-onboarding-* mapping, strict)
#   2. per tenant {banking-demo, payments-team}:
#        - role          tenant-{tenant}-audit-viewer
#                          (read-only on audit-onboarding-{tenant}* ONLY,
#                           client_ip field-masked)
#        - internaluser  {short}-audit-viewer  (backend_role tenant-{tenant}-audit)
#        - rolesmapping  tenant-{tenant}-audit-viewer
#                          (user + backend_role -> the role; the backend_role is
#                           the future SSO/OIDC group claim seam)
#
# The onboarding-api itself writes the audit docs (Go, internal/audit) under the
# admin credential; THESE roles are the least-privilege READ side governance/
# auditors use, proving a tenant viewer can read ONLY its tenant's audit index.
set -euo pipefail

OS_URL="${OS_URL:-https://localhost:9201}"
OS_AUTH="${OS_AUTH:?Variable OS_AUTH absente — définissez-la (\"admin:<mot-de-passe>\", voir poc-control-plane-federation/.env.example)}"
AUDIT_VIEWER_PASS="${AUDIT_VIEWER_PASS:?Variable AUDIT_VIEWER_PASS absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
DIR="$(cd "$(dirname "$0")" && pwd)"
# TLS (É0) — same knobs as provision.sh: OPENSEARCH_CA_FILE verifies against the
# enterprise CA; OPENSEARCH_INSECURE=false forces strict system trust; the
# default (unset/true) keeps -k for the PoC's self-signed demo certs ONLY.
CURL=(/usr/bin/curl -s -u "$OS_AUTH")
if [ -n "${OPENSEARCH_CA_FILE:-}" ]; then
  CURL+=(--cacert "$OPENSEARCH_CA_FILE")
else
  case "${OPENSEARCH_INSECURE:-true}" in 1|true|yes|on) CURL+=(-k) ;; esac
fi

echo "[1/4] index template audit-onboarding (audit-onboarding-* mapping)"
"${CURL[@]}" -X PUT "$OS_URL/_index_template/audit-onboarding" \
  -H 'Content-Type: application/json' \
  --data-binary @"$DIR/index-template-audit-onboarding.json"; echo

# provision_tenant SHORT TENANT
#   SHORT  : internal-user prefix (banking | payments)
#   TENANT : the tenant id == OpenSearch index suffix (banking-demo | payments-team)
provision_tenant() {
  local short="$1" tenant="$2"
  local role="tenant-${tenant}-audit-viewer"
  local user="${short}-audit-viewer"
  echo "  - role $role (read-only on audit-onboarding-${tenant}* ONLY)"
  "${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/roles/$role" \
    -H 'Content-Type: application/json' \
    --data-binary @"$DIR/role-tenant-${tenant}-audit-viewer.json"; echo
  echo "  - internaluser $user (backend_role tenant-${tenant}-audit)"
  # Le fichier internaluser-*.json ne porte plus le mot de passe en clair (dépôt
  # public) : on injecte AUDIT_VIEWER_PASS dans le gabarit au moment de l'appel,
  # via un fichier TEMPORAIRE hors dépôt (mktemp sans répertoire cible) — jamais
  # en argv (ADR-074, « jamais en argv » : --data-binary @fichier, pas la charge
  # utile en dur sur la ligne de commande de curl). `local` : la variable ne
  # doit pas survivre en portée globale après le retour de la fonction.
  local payload_file
  payload_file="$(mktemp)"
  AUDIT_PASS="$AUDIT_VIEWER_PASS" python3 -c '
import json, os, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
d["password"] = os.environ["AUDIT_PASS"]
with open(sys.argv[2], "w") as out:
    json.dump(d, out)
' "$DIR/internaluser-${short}-audit-viewer.json" "$payload_file"
  chmod 600 "$payload_file"
  "${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/internalusers/$user" \
    -H 'Content-Type: application/json' \
    --data-binary @"$payload_file"; echo
  rm -f "$payload_file"
  echo "  - rolesmapping $role"
  "${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/rolesmapping/$role" \
    -H 'Content-Type: application/json' \
    --data-binary @"$DIR/rolesmapping-tenant-${tenant}-audit-viewer.json"; echo
}

echo "[2/4] tenant banking-demo audit RBAC"
provision_tenant banking banking-demo

echo "[3/4] tenant payments-team audit RBAC"
provision_tenant payments payments-team

echo "[4/4] done. Tenant isolation proof (each viewer sees ONLY its tenant's audits):"
echo "    (PoC self-signed: add -k, or point --cacert at OPENSEARCH_CA_FILE)"
echo "    curl -s -u banking-audit-viewer:\$AUDIT_VIEWER_PASS  $OS_URL/audit-onboarding-banking-demo/_search   # 200"
echo "    curl -s -u banking-audit-viewer:\$AUDIT_VIEWER_PASS  $OS_URL/audit-onboarding-payments-team/_search  # 403"
