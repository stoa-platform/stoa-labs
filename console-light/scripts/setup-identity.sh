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

# --- attributs non gérés : ENABLED, sinon le PUT attributes.tenant ci-dessous
# est IGNORÉ EN SILENCE (unmanagedAttributePolicy par défaut = DISABLED depuis
# KC 24 ; constaté après recreate du realm : rôles OK mais tenant absent) -----
UP=$(api GET "/users/profile")
if ! printf '%s' "$UP" | grep -q '"unmanagedAttributePolicy":"ENABLED"'; then
  DATA=$(printf '%s' "$UP" | python3 -c 'import sys,json;p=json.load(sys.stdin);p["unmanagedAttributePolicy"]="ENABLED";print(json.dumps(p))')
  api PUT "/users/profile" "$DATA" >/dev/null
  say "unmanagedAttributePolicy → ENABLED (les attributs user persisteront)"
fi

# --- rôles realm (normalement importés au boot ; filet idempotent) ----------
for role in cpi-admin tenant-admin devops viewer; do
  if ! api GET "/roles/${role}" >/dev/null 2>&1; then
    say "Création du rôle realm ${role}"
    api POST "/roles" "{\"name\":\"${role}\"}" || true
  fi
done

# --- assignation par user : username rôle tenant -----------------------------
MISSING=0
assign() {
  local username="$1" role="$2" tenant="$3"
  local users uid
  users=$(api GET "/users?username=${username}&exact=true")
  uid=$(printf '%s' "$users" | python3 -c 'import sys,json;u=json.load(sys.stdin);print(u[0]["id"] if u else "")')
  if [ -z "$uid" ]; then
    warn "user '${username}' absent (premier login broker pas encore fait) — re-jouer ce script après."
    MISSING=$((MISSING+1))
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

# Piège vérifié (cf. prove-a7-four-eyes.sh) : le username fédéré est le claim
# preferred_username = "<user>@bc.example", PAS le prénom nu.
assign alice@bc.example tenant-admin banking-demo
assign bob@bc.example   devops       banking-demo
assign carol@bc.example viewer       banking-demo
assign dave@bc.example  cpi-admin    ""

# Restauration incomplète = code retour non-zéro (sinon un runbook enchaîné
# croit la restauration faite alors que les users n'existaient pas encore).
if [ "$MISSING" -gt 0 ]; then
  warn "Incomplet : ${MISSING}/4 users absents — faire leur premier login broker puis re-jouer ce script."
  exit 1
fi
say "Terminé (4/4). Les users doivent se re-loguer pour que le token porte les rôles."
