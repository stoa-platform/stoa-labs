#!/usr/bin/env bash
# test-vault-rotation.sh — prouve que labctl lit les creds depuis Vault à CHAQUE
# run (« rotable sans rebuild », ADR-074, gap (d) d'ADR-072). Non-destructif :
# on rote la clé admin APISIX dans Vault vers une MAUVAISE valeur (l'apply échoue
# l'auth APISIX) puis on RESTAURE la bonne (l'apply réussit) — le MÊME binaire
# change de comportement selon la valeur Vault courante, sans rebuild ni restart.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VADDR="${VAULT_ADDR:-http://localhost:8200}"; VTOK="${VAULT_TOKEN:-stoa-root-token}"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

BIN="$(mktemp -d)/labctl"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" . ) || { echo "build failed"; exit 1; }
chmod +x "$BIN"

vault_put_apisix(){ # vault_put_apisix <adminKey>
  curl -s -H "X-Vault-Token: $VTOK" -H 'Content-Type: application/json' \
    -X POST "$VADDR/v1/secret/data/stoa/gateways/apisix" -d "{\"data\":{\"adminKey\":\"$1\"}}" >/dev/null
}
applies(){ ( cd "$ROOT" && VAULT_ADDR="$VADDR" VAULT_TOKEN="$VTOK" "$BIN" apply -f targets.yaml >/dev/null 2>&1 ); echo $?; }

echo "=== rotation live-read depuis Vault (ADR-074) ==="
vault_put_apisix "poc-apisix-admin-key"   # état initial correct
[ "$(applies)" = "0" ] && ok "clé Vault correcte -> apply 3/3 (exit 0)" || bad "apply initial KO"

vault_put_apisix "ROTATED-WRONG-$$"
[ "$(applies)" != "0" ] && ok "clé APISIX rotée (mauvaise) dans Vault -> apply échoue (lecture live, pas de cache)" || bad "la rotation n'a pas été vue"

vault_put_apisix "poc-apisix-admin-key"
[ "$(applies)" = "0" ] && ok "clé restaurée dans Vault -> apply 3/3 (MÊME binaire, sans rebuild)" || bad "restauration KO"

echo ""; echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
