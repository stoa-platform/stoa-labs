#!/usr/bin/env bash
# Console Light — provisioning identité Keycloak (idempotent, re-jouable).
#
# Séquence : les users fédérés (alice/bob/carol/dave) sont créés par leur PREMIER
# login broker (le sub Dex n'est pas prédictible → pas de pré-création par import).
# Ce script s'exécute APRÈS ce premier login et assigne rôles realm + attribut tenant.
# S'il trouve un user absent, il l'indique et continue (re-jouer après le login).
#
# Usage : ./setup-identity.sh
set -euo pipefail

KC_BASE="${KC_BASE:-http://localhost:8480}"
KC_REALM="${KC_REALM:-stoa-lab}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"

say() { printf '\033[1;34m[identity]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[identity]\033[0m %s\n' "$*"; }

# --- attendre Keycloak -------------------------------------------------------
say "Attente de Keycloak (${KC_BASE}) ..."
for i in $(seq 1 60); do
  if curl -sf "${KC_BASE}/realms/${KC_REALM}/.well-known/openid-configuration" >/dev/null 2>&1; then
    break
  fi
  [ "$i" = 60 ] && { warn "Keycloak injoignable"; exit 1; }
  sleep 2
done
say "Keycloak prêt."

# --- token admin (realm master, admin-cli — même mécanique que labctl) -------
TOKEN=$(curl -sf -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" -d "client_id=admin-cli" \
  -d "username=${KC_ADMIN_USER}" -d "password=${KC_ADMIN_PASSWORD}" |
  python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

api() { # api METHOD PATH [DATA]
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then
    curl -sf -X "$m" "${AUTH[@]}" -d "$d" "${KC_BASE}/admin/realms/${KC_REALM}${p}"
  else
    curl -sf -X "$m" "${AUTH[@]}" "${KC_BASE}/admin/realms/${KC_REALM}${p}"
  fi
}

# --- rôles realm (normalement importés au boot ; filet idempotent) ----------
for role in cpi-admin tenant-admin devops viewer; do
  if ! api GET "/roles/${role}" >/dev/null 2>&1; then
    say "Création du rôle realm ${role}"
    api POST "/roles" "{\"name\":\"${role}\"}" || true
  fi
done

# --- assignation par user : username rôle tenant -----------------------------
assign() {
  local username="$1" role="$2" tenant="$3"
  local users uid
  users=$(api GET "/users?username=${username}&exact=true")
  uid=$(printf '%s' "$users" | python3 -c 'import sys,json;u=json.load(sys.stdin);print(u[0]["id"] if u else "")')
  if [ -z "$uid" ]; then
    warn "user '${username}' absent (premier login broker pas encore fait) — re-jouer ce script après."
    return 0
  fi
  # attribut tenant (vide pour cpi-admin = tous tenants)
  if [ -n "$tenant" ]; then
    api PUT "/users/${uid}" "{\"attributes\":{\"tenant\":[\"${tenant}\"]}}"
  fi
  # rôle realm
  local rolerep
  rolerep=$(api GET "/roles/${role}")
  api POST "/users/${uid}/role-mappings/realm" "[${rolerep}]"
  say "✓ ${username} → rôle ${role}${tenant:+, tenant ${tenant}}"
}

assign alice tenant-admin banking-demo
assign bob   devops       banking-demo
assign carol viewer       banking-demo
assign dave  cpi-admin    ""

say "Terminé. Les users doivent se re-loguer pour que le token porte les rôles."
