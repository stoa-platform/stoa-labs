#!/usr/bin/env bash
# mint-selfservice-jwt.sh — DÉMO/LAB : fabrique le JWT `aud=vault` à coller dans
# le param USER_VAULT_JWT du job Jenkins `selfservice-app-deploy`.
#
# Ce N'EST PAS le token de l'UI Vault : c'est un JWT d'IDENTITÉ émis par Keycloak
# (token exchange RFC 8693). Le job le présente à Vault (auth/jwt/login) pour
# obtenir un token Vault NOMINATIF. TTL court (~5 min) : minter juste avant le build.
#
# CHEZ LE CLIENT (voie A) ce script disparaît : l'humain saisit son user/mot de
# passe LDAP dans le job, qui fait auth/ldap/login (aucun JWT à copier). En voie B
# (console), c'est la console qui fait l'exchange et déclenche le job — pas toi.
set -euo pipefail
USER_EMAIL="${1:-${DEX_USER:-alice@bc.example}}"
KC="${KC_BASE:-http://localhost:8480}/realms/${REALM:-stoa-lab}/protocol/openid-connect/token"
XCID="${XCID:-vault-exchange}"; XSEC="${XSEC:-vault-exchange-secret-poc}"

# 1) token utilisateur (login humain via Dex/Keycloak broker)
TOK=$(DEX_USER="$USER_EMAIL" ./scripts/get-oracle-token.sh --quiet)
[ -n "$TOK" ] || { echo "login $USER_EMAIL KO" >&2; exit 1; }

# 2) exchange RFC 8693 -> JWT aud=vault  (== USER_VAULT_JWT)
JWT=$(curl -s -X POST "$KC" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d client_id="$XCID" -d client_secret="$XSEC" \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d audience=vault --data-urlencode "subject_token=$TOK" \
  | python3 -c 'import sys,json;sys.stdout.write(json.load(sys.stdin).get("access_token",""))')
[ -n "$JWT" ] || { echo "exchange refusé (client vault-exchange ? aud=vault ?)" >&2; exit 1; }
printf '%s\n' "$JWT"
