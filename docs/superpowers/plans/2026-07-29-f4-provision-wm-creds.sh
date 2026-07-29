#!/bin/sh
# F4 (T2) — à exécuter DANS vault-0, PAR L'EXPLOITANT : $1 $2 = 2 clés de
# descellement (quorum 2/3) — jamais affichées.
#
# Régénère un jeton racine ÉPHÉMÈRE (vault operator generate-root), écrit les
# identifiants admin de la gateway wM du cluster dans
# secret/ci/gateways/wm-cluster (lu par labctl via VAULT_PREFIX=ci, policy
# jenkins-agent inchangée), puis RÉVOQUE le jeton. Après exécution, il
# n'existe toujours aucun jeton racine au repos. Motif identique à
# 2026-07-28-f1-provision-status-token.sh (étapes 1-3 et révocation).
#
# Usage depuis le poste opérateur (racine du dépôt stoa-labs) :
#   scp docs/superpowers/plans/2026-07-29-f4-provision-wm-creds.sh worker-1:/tmp/f4-wm.sh
#   ssh -t worker-1 'sudo k3s kubectl -n ci exec -i vault-0 -- sh -c "cat > /tmp/f4w.sh && chmod 700 /tmp/f4w.sh" < /tmp/f4-wm.sh; \
#     read -r -s -p "Cle de descellement 1/2 : " K1; echo; read -r -s -p "Cle de descellement 2/2 : " K2; echo; \
#     sudo k3s kubectl -n ci exec vault-0 -- sh /tmp/f4w.sh "$K1" "$K2"; unset K1 K2; \
#     sudo k3s kubectl -n ci exec vault-0 -- rm -f /tmp/f4w.sh; rm -f /tmp/f4-wm.sh'
set -eu
K1="$1"; K2="$2"

echo "etape 1/5 : init generate-root (annule un eventuel essai en cours)…"
vault operator generate-root -cancel >/dev/null 2>&1 || true
INIT=$(vault operator generate-root -init -format=json)
NONCE=$(echo "$INIT" | sed -n 's/.*"nonce": *"\([^"]*\)".*/\1/p')
OTP=$(echo "$INIT" | sed -n 's/.*"otp": *"\([^"]*\)".*/\1/p')
[ -n "$NONCE" ] && [ -n "$OTP" ] || { echo "ECHEC etape 1 : nonce/otp non obtenus"; exit 1; }

echo "etape 2/5 : quorum des cles (2/3)…"
vault operator generate-root -nonce="$NONCE" -format=json "$K1" >/dev/null \
  || { echo "ECHEC etape 2 : cle 1 refusee"; exit 1; }
STEP2=$(vault operator generate-root -nonce="$NONCE" -format=json "$K2") \
  || { echo "ECHEC etape 2 : cle 2 refusee"; exit 1; }
ENC=$(echo "$STEP2" | sed -n 's/.*"encoded_token": *"\([^"]*\)".*/\1/p')
[ -n "$ENC" ] || ENC=$(echo "$STEP2" | sed -n 's/.*"encoded_root_token": *"\([^"]*\)".*/\1/p')
[ -n "$ENC" ] || { echo "ECHEC etape 2 : jeton encode absent (quorum incomplet ?)"; exit 1; }

echo "etape 3/5 : decodage du jeton racine ephemere…"
DEC=$(vault operator generate-root -decode="$ENC" -otp="$OTP" -format=json 2>/dev/null) \
  || DEC=$(vault operator generate-root -decode="$ENC" -otp="$OTP")
ROOT=$(echo "$DEC" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
[ -n "$ROOT" ] || ROOT=$(echo "$DEC" | tr -d '[:space:]')
[ -n "$ROOT" ] || { echo "ECHEC etape 3 : decodage vide"; exit 1; }
VAULT_TOKEN="$ROOT"; export VAULT_TOKEN
vault token lookup >/dev/null || { echo "ECHEC etape 3 : jeton ephemere invalide"; exit 1; }

echo "etape 4/5 : ecriture Vault secret/ci/gateways/wm-cluster…"
# Identifiants admin du trial (defauts publics du produit) — la valeur importe
# moins que le CHEMIN : le pipeline ne connait que Vault (zero secret statique).
vault kv put secret/ci/gateways/wm-cluster \
  username=Administrator password=manage >/dev/null \
  || { vault token revoke -self >/dev/null 2>&1 || true; echo "ECHEC etape 4 : ecriture refusee"; exit 1; }

echo "etape 5/5 : revocation du jeton racine ephemere…"
vault token revoke -self >/dev/null \
  || { echo "AVERTISSEMENT : revocation a verifier (vault token lookup doit echouer)"; exit 1; }
unset VAULT_TOKEN

echo "OK: secret/ci/gateways/wm-cluster ecrit, jeton racine ephemere revoque"
