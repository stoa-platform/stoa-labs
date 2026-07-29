#!/bin/sh
# F4 (T7, contre-épreuve) — à exécuter DANS vault-0, PAR L'EXPLOITANT :
#   $1, $2 = deux clés de descellement (quorum 2/3) — jamais affichées ;
#   $3     = revoke | restore
#
# revoke  : supprime le rôle k8s jenkins-agent → le login par identité de pod
#           échoue FERMÉ (aucun secret servi) ; le build publish rougit.
# restore : recrée le rôle À L'IDENTIQUE de vault-bootstrap.sh (lot 1).
# Dans les deux cas : jeton racine ÉPHÉMÈRE par quorum, révoqué en sortie.
#
# Usage (poste opérateur, racine stoa-labs) — MODE = revoke ou restore :
#   scp docs/superpowers/plans/2026-07-29-f4-vault-role-toggle.sh worker-1:/tmp/f4-rt.sh
#   ssh -t worker-1 'sudo k3s kubectl -n ci exec -i vault-0 -- sh -c "cat > /tmp/f4t.sh && chmod 700 /tmp/f4t.sh" < /tmp/f4-rt.sh; \
#     read -r -s -p "Cle de descellement 1/2 : " K1; echo; read -r -s -p "Cle de descellement 2/2 : " K2; echo; \
#     sudo k3s kubectl -n ci exec vault-0 -- sh /tmp/f4t.sh "$K1" "$K2" MODE; unset K1 K2; \
#     sudo k3s kubectl -n ci exec vault-0 -- rm -f /tmp/f4t.sh; rm -f /tmp/f4-rt.sh'
set -eu
K1="$1"; K2="$2"; MODE="$3"
case "$MODE" in revoke|restore) ;; *) echo "usage: … revoke|restore"; exit 2;; esac

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

echo "etape 4/5 : $MODE du role jenkins-agent…"
if [ "$MODE" = "revoke" ]; then
  vault delete auth/kubernetes/role/jenkins-agent >/dev/null \
    || { vault token revoke -self >/dev/null 2>&1 || true; echo "ECHEC etape 4 : delete refuse"; exit 1; }
  echo "role jenkins-agent REVOQUE"
else
  vault write auth/kubernetes/role/jenkins-agent \
    bound_service_account_names=jenkins-agent \
    bound_service_account_namespaces=ci \
    token_policies=jenkins-agent ttl=20m >/dev/null \
    || { vault token revoke -self >/dev/null 2>&1 || true; echo "ECHEC etape 4 : write refuse"; exit 1; }
  echo "role jenkins-agent RESTAURE"
fi

echo "etape 5/5 : revocation du jeton racine ephemere…"
vault token revoke -self >/dev/null \
  || { echo "AVERTISSEMENT : revocation a verifier (vault token lookup doit echouer)"; exit 1; }
unset VAULT_TOKEN
echo "OK ($MODE)"
