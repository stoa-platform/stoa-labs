#!/usr/bin/env bash
# setup-vault-envs.sh — idempotent provisioning des secrets MULTI-ENV (ADR-075).
# Étend setup-vault.sh : un secret admin par environnement BAS (dev/rec/int)
#   secret/stoa/envs/{env}/wm-admin  {username, password}
# = les creds Basic du mock wM de CET env (valeurs du credential alias
# wm-admin-{env}-cred projeté par scripts/setup-wm-admin-proxy.sh), et le
# secret du compte de service CI hors-prod (ciHorsprodSecret) dans
#   secret/stoa/ci
#
# Vault dev-mode : KV v2 déjà monté sous secret/, unsealed. Écriture KV v2 =
# upsert (POST .../data/<path>) → re-run = converge. ⚠ KV v2 REMPLACE l'objet
# data ENTIER : pour secret/stoa/ci on RELIT ciApplierSecret existant et on
# réémet les DEUX clés (sinon le re-run effacerait le secret du pipeline).
#
# Les VALEURS ci-dessous sont PoC-JETABLES (identiques aux placeholders de
# docker-compose.envs.yml) — surchargeables par env. En prod : valeurs émises
# par Vault, rotées, jamais dans un script. Lancer : bash scripts/setup-vault-envs.sh
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
VAULT_TOKEN="${VAULT_TOKEN:?Variable VAULT_TOKEN absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
MOUNT="${VAULT_KV_MOUNT:-secret}"
PREFIX="${VAULT_PREFIX:-stoa}"
CURL=(/usr/bin/curl -s -H "X-Vault-Token: $VAULT_TOKEN")

# put <subpath> <json-data-object>
put() {
  local sub="$1" data="$2"
  "${CURL[@]}" -X POST "$VAULT_ADDR/v1/$MOUNT/data/$PREFIX/$sub" \
    -H 'Content-Type: application/json' -d "{\"data\":$data}" -o /dev/null -w "  $PREFIX/$sub -> HTTP %{http_code}\n"
}

# Secret values (PoC-disposable; override via env to inject real ones out-of-band).
# DOIVENT matcher les ADMIN_USER/ADMIN_PASSWORD des mocks (docker-compose.envs.yml).
# Chaîne DÉRIVÉE (scripts/lib/env-chain.sh) : un secret admin par palier
# HORS-PROD, plus de bloc à recopier à chaque nouvel environnement. Les
# surcharges nominatives historiques (WM_DEV_USER, WM_REC_PASS…) restent
# honorées à l'identique — c'est ce que lit la boucle ci-dessous.
. "$(dirname "$0")/lib/env-chain.sh"
read -r -a HP_ENVS <<< "$(env_chain_nonprod)" || { echo "✗ chaîne d'environnements illisible" >&2; exit 1; }
CI_HORSPROD_SECRET="${CI_HORSPROD_SECRET:?Variable CI_HORSPROD_SECRET absente — définissez-la (voir poc-control-plane-federation/.env.example)}"

# secret/stoa/ci : MERGE manuel — relire ciApplierSecret (posé par setup-vault.sh)
# avant de réécrire l'objet complet (KV v2 ne merge pas). Posé AVANT la boucle
# par palier (G5) : le sub envs/<env>/admin-oauth qu'elle seed a besoin de
# RELIRE ciHorsprodSecret depuis ce même secret, pas de le prendre directement
# de la variable d'environnement — la valeur qui compte pour les autres
# consommateurs (Task 6) est celle PERSISTÉE dans Vault.
CUR_APPLIER="$("${CURL[@]}" "$VAULT_ADDR/v1/$MOUNT/data/$PREFIX/ci" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["data"]["data"].get("ciApplierSecret",""))
except Exception: print("")' 2>/dev/null || true)"
CI_APPLIER_SECRET="${CI_APPLIER_SECRET:-$CUR_APPLIER}"
[ -n "$CI_APPLIER_SECRET" ] || {
  echo "Variable CI_APPLIER_SECRET absente et aucun ciApplierSecret déjà présent dans" >&2
  echo "Vault (secret/$PREFIX/ci) — définissez CI_APPLIER_SECRET (voir" >&2
  echo "poc-control-plane-federation/.env.example) ou lancez d'abord scripts/setup-vault.sh." >&2
  exit 1
}
put ci "{\"ciApplierSecret\":\"$CI_APPLIER_SECRET\",\"ciHorsprodSecret\":\"$CI_HORSPROD_SECRET\"}"

# Round-trip : c'est CETTE valeur (relue, pas $CI_HORSPROD_SECRET) qui alimente
# admin-oauth ci-dessous.
CI_HORSPROD_FROM_VAULT="$("${CURL[@]}" "$VAULT_ADDR/v1/$MOUNT/data/$PREFIX/ci" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["data"]["data"].get("ciHorsprodSecret",""))
except Exception: print("")' 2>/dev/null || true)"
if [ -z "$CI_HORSPROD_FROM_VAULT" ]; then
  echo "✗ CI_SECRET_ABSENT : ciHorsprodSecret absent de secret/$PREFIX/ci après écriture —" >&2
  echo "  envs/<env>/admin-oauth NON seedé (le reste du plan continue)." >&2
fi
# ADR-079/G5 : le client OAuth des proxies admin est commun à tous les
# paliers hors-prod (ci-horsprod) — token_url par défaut = la vue in-cluster
# (agents Jenkins), surchargeable pour un lab dont Keycloak est ailleurs.
ADMIN_OAUTH_TOKEN_URL="${ADMIN_OAUTH_TOKEN_URL:-http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/token}"

echo "Vault $VAULT_ADDR — provisioning secret/$PREFIX/envs/* (KV v2, ADR-075)"
for E in "${HP_ENVS[@]}"; do
  # Nom de variable historique par env : WM_<ENV>_USER / WM_<ENV>_PASS.
  EU="WM_$(printf %s "$E" | tr '[:lower:]' '[:upper:]')_USER"
  EP="WM_$(printf %s "$E" | tr '[:lower:]' '[:upper:]')_PASS"
  U="${!EU:-wm-$E-admin}"; P="${!EP:-wm-$E-secret-poc}"
  put "envs/$E/wm-admin" "{\"username\":\"$U\",\"password\":\"$P\"}"
  if [ -n "$CI_HORSPROD_FROM_VAULT" ]; then
    put "envs/$E/admin-oauth" "{\"token_url\":\"$ADMIN_OAUTH_TOKEN_URL\",\"client_id\":\"ci-horsprod\",\"client_secret\":\"$CI_HORSPROD_FROM_VAULT\",\"scope\":\"deploy:$E\"}"
  fi
done

echo "done. Vérif (re-lecture d'un secret) :"
"${CURL[@]}" "$VAULT_ADDR/v1/$MOUNT/data/$PREFIX/envs/dev/wm-admin" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  envs/dev/wm-admin.username =", d["data"]["data"].get("username"))' 2>/dev/null \
  || echo "  (lecture KO — Vault joignable ?)"
