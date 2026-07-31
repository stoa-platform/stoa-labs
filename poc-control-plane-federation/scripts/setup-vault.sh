#!/usr/bin/env bash
# setup-vault.sh — idempotent provisioning des secrets du PoC dans Vault (ADR-074).
# Concrétise le gap (d) d'ADR-072 : les secrets ne vivent plus en placeholders
# targets.yaml / env / credentials Jenkins, mais dans Vault, LUS à l'exécution
# (labctl / onboarding-api / CI) et rotables sans rebuild.
#
# Vault dev-mode : KV v2 déjà monté sous secret/, unsealed, root token jetable.
# Écriture KV v2 = upsert (POST .../data/<path>) → re-run = converge.
#
# Les secrets de démo (VAULT_TOKEN, CI_APPLIER_SECRET, OS_ADMIN_PASS, ...) ne
# sont PLUS en clair dans ce script (dépôt public) : ils sont EXIGÉS depuis
# l'environnement, voir poc-control-plane-federation/.env.example. En prod :
# valeurs émises par Vault, rotées, jamais dans un script.
# Lancer : cp .env.example .env && set -a && source .env && set +a && bash scripts/setup-vault.sh
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

# Secret values (PoC-disposable; override via env to inject real ones out-of-band)
WSO2_USER="${WSO2_USER:-admin}";            WSO2_PASS="${WSO2_PASS:-admin}"
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-poc-apisix-admin-key}"
WM_USER="${WM_USER:-Administrator}";        WM_PASS="${WM_PASS:-manage}"
# mTLS (ADR-076) : storepass du truststore + CA cliente PUBLIQUE. CA via contenu
# (WM_CLIENT_CA_PEM) ou fichier (WM_CLIENT_CA_FILE, défaut = CA de démo du repo).
WM_TRUSTSTORE_PASS="${WM_TRUSTSTORE_PASS:-manage}"
WM_CLIENT_CA_FILE="${WM_CLIENT_CA_FILE:-$(cd "$(dirname "$0")/.." && pwd)/ansible/files/accounts-team-client-ca.pem}"
WM_CLIENT_CA_PEM="${WM_CLIENT_CA_PEM:-$(cat "$WM_CLIENT_CA_FILE" 2>/dev/null || true)}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}";    KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
KC_CONSUMER_SECRET="${KC_CONSUMER_SECRET:-}"
CI_APPLIER_SECRET="${CI_APPLIER_SECRET:?Variable CI_APPLIER_SECRET absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
OS_ADMIN_PASS="${OS_ADMIN_PASS:?Variable OS_ADMIN_PASS absente — définissez-la (voir poc-control-plane-federation/.env.example)}"

echo "Vault $VAULT_ADDR — provisioning secret/$PREFIX/* (KV v2)"
put gateways/wso2       "{\"username\":\"$WSO2_USER\",\"password\":\"$WSO2_PASS\"}"
put gateways/apisix     "{\"adminKey\":\"$APISIX_ADMIN_KEY\"}"
put gateways/webmethods "{\"username\":\"$WM_USER\",\"password\":\"$WM_PASS\"}"
# truststore_pass = secret PLATEFORME (mot de passe du JKS de la gateway) -> gateways/*.
put gateways/webmethods/mtls "{\"truststore_pass\":\"$WM_TRUSTSTORE_PASS\"}"
# CA partenaire = matériel FOURNI PAR LE PROJET -> projects/accounts-team/* (son
# namespace). Ici seed root (PoC) ; le vrai modèle = le PROJET l'y écrit via son rôle
# write-accounts-team (self-service scopé, cf. setup-vault-approle.sh + démo).
if [ -n "$WM_CLIENT_CA_PEM" ]; then
  put projects/accounts-team/mtls "$(CA="$WM_CLIENT_CA_PEM" python3 -c 'import json,os;print(json.dumps({"client_ca_pem":os.environ["CA"]}))')"
else
  echo "  (skip projects/accounts-team/mtls : pas de CA — définir WM_CLIENT_CA_FILE/PEM)"
fi
put keycloak            "{\"adminUsername\":\"$KC_ADMIN_USER\",\"adminPassword\":\"$KC_ADMIN_PASS\",\"consumerClientSecret\":\"$KC_CONSUMER_SECRET\"}"
put ci                  "{\"ciApplierSecret\":\"$CI_APPLIER_SECRET\"}"
put opensearch          "{\"adminPassword\":\"$OS_ADMIN_PASS\"}"

echo "done. Vérif (re-lecture d'un secret) :"
"${CURL[@]}" "$VAULT_ADDR/v1/$MOUNT/data/$PREFIX/gateways/apisix" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  apisix.adminKey =", d["data"]["data"].get("adminKey"))' 2>/dev/null \
  || echo "  (lecture KO — Vault joignable ?)"
