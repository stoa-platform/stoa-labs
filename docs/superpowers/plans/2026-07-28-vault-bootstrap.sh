#!/bin/sh
# vault-bootstrap.sh — exécuté SUR worker-1, en root (sudo).
# Ré-initialise Vault de bout en bout sans qu'aucune valeur secrète ne sorte
# du nœud : les clés et le jeton racine sont écrits dans un fichier root-only,
# relus par ce script pour desceller et configurer, et jamais affichés.
set -eu

K="k3s kubectl -n ci"
OUT=/root/vault-init-ci.txt

echo "etape 1/7 : effacement du backend file"
$K exec vault-0 -- sh -c 'rm -rf /vault/data/auth /vault/data/core /vault/data/logical /vault/data/sys' >/dev/null 2>&1 || true

echo "etape 2/7 : redemarrage du pod"
$K delete pod vault-0 >/dev/null
P=""
i=0
while [ $i -lt 60 ]; do
  P=$($K get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$P" = "Running" ] && break
  i=$((i + 1)); sleep 3
done
[ "$P" = "Running" ] || { echo "ECHEC etape 2 : vault-0 n'est pas Running"; exit 1; }

# Attendre que l'API Vault reponde (elle repond meme non initialisee)
j=0
while [ $j -lt 40 ]; do
  if $K exec vault-0 -- vault status 2>/dev/null | grep -q '^Initialized'; then break; fi
  j=$((j + 1)); sleep 3
done
[ $j -lt 40 ] || { echo "ECHEC etape 2 : l'API Vault ne repond pas"; exit 1; }

echo "etape 3/7 : initialisation (sortie vers $OUT, jamais affichee)"
umask 077
$K exec vault-0 -- vault operator init -key-shares=3 -key-threshold=2 > "$OUT"
chmod 600 "$OUT"

K1=$(sed -n 's/^Unseal Key 1: //p' "$OUT")
K2=$(sed -n 's/^Unseal Key 2: //p' "$OUT")
RT=$(sed -n 's/^Initial Root Token: //p' "$OUT")
[ -n "$K1" ] && [ -n "$K2" ] && [ -n "$RT" ] \
  || { echo "ECHEC etape 3 : parsing de $OUT impossible"; exit 1; }

echo "etape 4/7 : descellement (2 parts sur 3)"
$K exec -i vault-0 -- vault operator unseal "$K1" >/dev/null
$K exec -i vault-0 -- vault operator unseal "$K2" >/dev/null
$K exec vault-0 -- vault status 2>/dev/null | grep -E '^(Initialized|Sealed)' | sed 's/^/  /'

echo "etape 5/7 : configuration du lot 1 (auth k8s, policy+role, kv-v2, probe)"
$K exec -i vault-0 -- sh -s "$RT" <<'INNER'
set -eu
VAULT_TOKEN="$1"; export VAULT_TOKEN
vault auth enable kubernetes >/dev/null 2>&1 || true
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" >/dev/null
vault policy write jenkins-agent - >/dev/null <<'EOF'
path "secret/data/ci/*" { capabilities = ["read"] }
EOF
vault write auth/kubernetes/role/jenkins-agent \
  bound_service_account_names=jenkins-agent \
  bound_service_account_namespaces=ci \
  token_policies=jenkins-agent \
  ttl=20m >/dev/null
vault secrets enable -path=secret kv-v2 >/dev/null 2>&1 || true
vault kv put secret/ci/probe value=preuve-g8 >/dev/null
INNER

echo "etape 6/7 : PAT Gitea + secret/ci/probe-status"
$K exec -i vault-0 -- sh -s "$RT" <<'INNER2'
set -eu
VAULT_TOKEN="$1"; export VAULT_TOKEN
if vault kv get -field=token secret/ci/probe-status >/dev/null 2>&1; then
  echo "  secret/ci/probe-status deja present — inchange"
else
  # Basic calcule sur le noeud a partir de /root/gitea-ci-pass (0600) : le mot
  # de passe ne figure ni dans ce fichier, ni dans l'URL (donc ni en argv).
  wget -q -O /tmp/vr-pat.json --header='Content-Type: application/json' \
    --header="Authorization: Basic $(printf 'ci:%s' "$(cat /root/gitea-ci-pass)" | base64 -w0)" \
    --post-data='{"name":"probe-status","scopes":["write:repository"]}' \
    'http://gitea.ci.svc.cluster.local:3000/api/v1/users/ci/tokens' \
    || { echo "  ECHEC : Gitea a refuse la creation du PAT (nom deja pris ?)"; exit 1; }
  PAT=$(sed -n 's/.*"sha1":"\([^"]*\)".*/\1/p' /tmp/vr-pat.json)
  rm -f /tmp/vr-pat.json
  [ -n "$PAT" ] || { echo "  ECHEC : PAT non extrait de la reponse Gitea"; exit 1; }
  vault kv put secret/ci/probe-status token="$PAT" >/dev/null
  echo "  PAT cree (jamais affiche) + secret/ci/probe-status ecrit"
fi
INNER2

echo "etape 7/7 : termine"
echo "IMPORTANT : nouvelles cles de descellement + jeton racine dans $OUT (root, 600)."
echo "A recuperer hors ligne, puis supprimer : sudo shred -u $OUT"
