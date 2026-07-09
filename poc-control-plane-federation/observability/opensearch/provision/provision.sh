#!/usr/bin/env bash
# ADR-070 — idempotent OpenSearch provisioning (template + ISM + RBAC + tenant +
# Dashboards index-pattern). Mirror of what labctl projects
# ("Define Once -> Observe Everywhere"). Safe to re-run: a blank provision.sh
# reproduces the data stream template + Dashboards tenant + viewer role/FLS +
# the txn-accounts-team index pattern. SSO OIDC is deferred (see
# 06-sso-oidc-dashboards.DEFERRED.md).
set -euo pipefail

OS_URL="${OS_URL:-https://localhost:9201}"
OS_AUTH="${OS_AUTH:-admin:Stoa!Passw0rd2026}"
# OpenSearch Dashboards (saved objects API) — plain HTTP on 5601 in the PoC.
OSD_URL="${OSD_URL:-http://localhost:5601}"
OSD_AUTH="${OSD_AUTH:-$OS_AUTH}"
# Dashboards tenant the index-pattern saved object lives in (ADR-070 per-tenant
# space). The viewer role grants kibana_all_read on this tenant.
OSD_TENANT="${OSD_TENANT:-accounts-team}"
DIR="$(cd "$(dirname "$0")" && pwd)"
# TLS (É0) — no hardwired -k anymore; three regimes, one knob each:
#   OPENSEARCH_CA_FILE=<pem>   verify against the enterprise CA (--cacert; wins)
#   OPENSEARCH_INSECURE=false  strict system trust
#   default (unset/true)       -k — PoC regime only (self-signed demo certs)
# A client site sets OPENSEARCH_CA_FILE (or INSECURE=false) and never ships -k.
CURL=(/usr/bin/curl -s -u "$OS_AUTH")
# Dashboards needs the osd-xsrf header on every write and the securitytenant
# header to target the per-tenant saved-object space.
OSD_CURL=(/usr/bin/curl -s -u "$OSD_AUTH" -H 'osd-xsrf: true' -H "securitytenant: $OSD_TENANT")
if [ -n "${OPENSEARCH_CA_FILE:-}" ]; then
  CURL+=(--cacert "$OPENSEARCH_CA_FILE"); OSD_CURL+=(--cacert "$OPENSEARCH_CA_FILE")
else
  case "${OPENSEARCH_INSECURE:-true}" in 1|true|yes|on) CURL+=(-k); OSD_CURL+=(-k) ;; esac
fi

echo "[1/7] index template stoa-txn (data_stream enabled)"
"${CURL[@]}" -X PUT "$OS_URL/_index_template/stoa-txn" \
  -H 'Content-Type: application/json' \
  --data-binary @"$DIR/01-index-template-stoa-txn.json"; echo

echo "[2/7] ISM policy stoa-txn-retention (create-or-update)"
EXISTING="$("${CURL[@]}" "$OS_URL/_plugins/_ism/policies/stoa-txn-retention")"
if echo "$EXISTING" | grep -q '"_seq_no"'; then
  SEQ="$(echo "$EXISTING" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_seq_no"])')"
  TERM="$(echo "$EXISTING" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_primary_term"])')"
  "${CURL[@]}" -X PUT "$OS_URL/_plugins/_ism/policies/stoa-txn-retention?if_seq_no=$SEQ&if_primary_term=$TERM" \
    -H 'Content-Type: application/json' \
    --data-binary @"$DIR/02-ism-policy-stoa-txn-retention.json"; echo
else
  "${CURL[@]}" -X PUT "$OS_URL/_plugins/_ism/policies/stoa-txn-retention" \
    -H 'Content-Type: application/json' \
    --data-binary @"$DIR/02-ism-policy-stoa-txn-retention.json"; echo
fi

echo "[3/7] Dashboards tenant accounts-team (PUT is create-or-replace, idempotent)"
"${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/tenants/$OSD_TENANT" \
  -H 'Content-Type: application/json' \
  --data-binary @"$DIR/07-tenant-accounts-team.json"; echo

echo "[4/7] RBAC role tenant-accounts-team-viewer (index_perms + FLS + tenant_perms)"
"${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/roles/tenant-accounts-team-viewer" \
  -H 'Content-Type: application/json' \
  --data-binary @"$DIR/03-role-tenant-accounts-team-viewer.json"; echo

echo "[5/7] internal user accounts-viewer"
"${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/internalusers/accounts-viewer" \
  -H 'Content-Type: application/json' \
  --data-binary @"$DIR/04-internaluser-accounts-viewer.json"; echo

echo "[6/7] rolesmapping tenant-accounts-team-viewer"
"${CURL[@]}" -X PUT "$OS_URL/_plugins/_security/api/rolesmapping/tenant-accounts-team-viewer" \
  -H 'Content-Type: application/json' \
  --data-binary @"$DIR/05-rolesmapping-tenant-accounts-team-viewer.json"; echo

echo "[7/7] Dashboards index-pattern txn-accounts-team (tenant $OSD_TENANT)"
# Saved-objects API has no idempotent PUT; the create call returns 409 when the
# object already exists. Treat both 2xx (created) and 409 (already there) as
# success so re-runs converge without overwrite=true churn. The id is pinned to
# the title so the object is stable across runs.
IP_ID="txn-accounts-team"
IP_CODE="$("${OSD_CURL[@]}" -o /dev/null -w '%{http_code}' \
  -X POST "$OSD_URL/api/saved_objects/index-pattern/$IP_ID" \
  -H 'Content-Type: application/json' \
  --data-binary @"$DIR/08-index-pattern-txn-accounts-team.json" || true)"
case "$IP_CODE" in
  2*)   echo "  created index-pattern $IP_ID (HTTP $IP_CODE)";;
  409)  echo "  index-pattern $IP_ID already present (HTTP 409) — idempotent";;
  000)  echo "  WARN: Dashboards ($OSD_URL) unreachable — index-pattern skipped (re-run when up)";;
  *)    echo "  WARN: index-pattern create returned HTTP $IP_CODE (continuing)";;
esac

echo "[done] SSO OIDC Dashboards: DEFERRED (best-effort) — see 06-sso-oidc-dashboards.DEFERRED.md"
