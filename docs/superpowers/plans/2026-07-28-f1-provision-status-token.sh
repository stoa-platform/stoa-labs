#!/bin/sh
# F1, porte utilisateur (T4) — à exécuter DANS vault-0, PAR L'EXPLOITANT :
#   $1, $2 = deux clés de descellement (quorum 2/3) — jamais affichées.
#
# Le jeton racine n'est PAS conservé au repos (constat du 2026-07-28) : ce
# script en régénère un ÉPHÉMÈRE par quorum (vault operator generate-root),
# écrit le PAT Gitea dans secret/ci/probe-status, puis le RÉVOQUE. Après
# exécution, il n'existe toujours aucun jeton racine au repos.
#
# Usage depuis le poste opérateur (racine du dépôt stoa-labs) :
#   scp docs/superpowers/plans/2026-07-28-f1-provision-status-token.sh worker-1:/tmp/f1-provision.sh
#   ssh -t worker-1 'sudo k3s kubectl -n ci exec -i vault-0 -- sh -c "cat > /tmp/f1p.sh && chmod 700 /tmp/f1p.sh" < /tmp/f1-provision.sh; \
#     read -r -s -p "Cle de descellement 1/2 : " K1; echo; read -r -s -p "Cle de descellement 2/2 : " K2; echo; \
#     sudo k3s kubectl -n ci exec vault-0 -- sh /tmp/f1p.sh "$K1" "$K2"; unset K1 K2; \
#     sudo k3s kubectl -n ci exec vault-0 -- rm -f /tmp/f1p.sh; rm -f /tmp/f1-provision.sh'
set -eu
K1="$1"; K2="$2"

echo "etape 1/6 : init generate-root (annule un eventuel essai en cours)…"
vault operator generate-root -cancel >/dev/null 2>&1 || true
INIT=$(vault operator generate-root -init -format=json)
NONCE=$(echo "$INIT" | sed -n 's/.*"nonce": *"\([^"]*\)".*/\1/p')
OTP=$(echo "$INIT" | sed -n 's/.*"otp": *"\([^"]*\)".*/\1/p')
[ -n "$NONCE" ] && [ -n "$OTP" ] || { echo "ECHEC etape 1 : nonce/otp non obtenus"; exit 1; }

echo "etape 2/6 : quorum des cles (2/3)…"
vault operator generate-root -nonce="$NONCE" -format=json "$K1" >/dev/null \
  || { echo "ECHEC etape 2 : cle 1 refusee"; exit 1; }
STEP2=$(vault operator generate-root -nonce="$NONCE" -format=json "$K2") \
  || { echo "ECHEC etape 2 : cle 2 refusee"; exit 1; }
ENC=$(echo "$STEP2" | sed -n 's/.*"encoded_token": *"\([^"]*\)".*/\1/p')
[ -n "$ENC" ] || ENC=$(echo "$STEP2" | sed -n 's/.*"encoded_root_token": *"\([^"]*\)".*/\1/p')
[ -n "$ENC" ] || { echo "ECHEC etape 2 : jeton encode absent (quorum incomplet ?)"; exit 1; }

echo "etape 3/6 : decodage du jeton racine ephemere…"
DEC=$(vault operator generate-root -decode="$ENC" -otp="$OTP" -format=json 2>/dev/null) \
  || DEC=$(vault operator generate-root -decode="$ENC" -otp="$OTP")
ROOT=$(echo "$DEC" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
[ -n "$ROOT" ] || ROOT=$(echo "$DEC" | tr -d '[:space:]')
[ -n "$ROOT" ] || { echo "ECHEC etape 3 : decodage vide"; exit 1; }
VAULT_TOKEN="$ROOT"; export VAULT_TOKEN
vault token lookup >/dev/null || { echo "ECHEC etape 3 : jeton ephemere invalide"; exit 1; }

echo "etape 4/6 : creation du PAT Gitea (probe-status)…"
# Basic calcule sur le noeud a partir de /root/gitea-ci-pass (0600, rotation
# T9 du 2026-07-29) : aucun identifiant en clair dans ce fichier.
wget -q -O /tmp/f1-pat.json --header='Content-Type: application/json' \
  --header="Authorization: Basic $(printf 'ci:%s' "$(cat /root/gitea-ci-pass)" | base64 -w0)" \
  --post-data='{"name":"probe-status","scopes":["write:repository"]}' \
  'http://gitea.ci.svc.cluster.local:3000/api/v1/users/ci/tokens' \
  || { vault token revoke -self >/dev/null 2>&1 || true; echo "ECHEC etape 4 : API Gitea"; exit 1; }
PAT=$(sed -n 's/.*"sha1":"\([^"]*\)".*/\1/p' /tmp/f1-pat.json)
rm -f /tmp/f1-pat.json
[ -n "$PAT" ] || { vault token revoke -self >/dev/null 2>&1 || true; echo "ECHEC etape 4 : PAT non extrait"; exit 1; }

echo "etape 5/6 : ecriture Vault secret/ci/probe-status…"
vault kv put secret/ci/probe-status token="$PAT" >/dev/null \
  || { vault token revoke -self >/dev/null 2>&1 || true; echo "ECHEC etape 5 : ecriture refusee"; exit 1; }

echo "etape 6/6 : revocation du jeton racine ephemere…"
vault token revoke -self >/dev/null \
  || { echo "AVERTISSEMENT : revocation a verifier (vault token lookup doit echouer)"; exit 1; }
unset VAULT_TOKEN

echo "OK: secret/ci/probe-status ecrit, jeton racine ephemere revoque"
