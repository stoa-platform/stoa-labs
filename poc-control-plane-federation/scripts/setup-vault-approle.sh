#!/usr/bin/env bash
# setup-vault-approle.sh — durcissement ADR-074 : IDENTITÉS ÉPHÉMÈRES least-priv.
# Remplace le root token statique par des AppRoles scopées :
#   - policy stoa-labctl          : LECTURE secret/stoa/gateways/* + keycloak +
#     projects/* (le platform-reader lit le matériel FOURNI par les projets)
#   - policy stoa-ci              : LECTURE secret/stoa/ci + secret/stoa/opensearch
#   - policy stoa-proxy-provision : LECTURE secret/stoa/envs/+/wm-admin (creds
#     admin des mocks dev/rec/int) + secret/stoa/gateways/webmethods (l'admin du
#     wM réel où les proxies sont appliqués) — ADR-075, setup-wm-admin-proxy.sh
#   - policy write-accounts-team  : ÉCRITURE SCOPÉE projects/accounts-team/* (le
#     PROJET pousse SES secrets dans son seul sous-arbre — jamais gateways/*, jamais
#     un autre projet). Séparation des devoirs : lecture=plateforme, écriture=projet.
# Chaque rôle émet, sur (role_id public + secret_id court/usage-limité), un TOKEN
# ÉPHÉMÈRE (TTL court) portant SA SEULE policy — un token compromis ne lit que son
# périmètre, jamais root, et expire. C'est le « management du token Vault » prod.
#
# Idempotent (PUT = create-or-replace). Le bootstrap a encore besoin d'un token
# admin (ici root, PoC) pour ÉCRIRE les policies/roles — en prod c'est un
# opérateur Vault, pas la CI.
#
#   bash scripts/setup-vault-approle.sh                 # provisionne policies+roles
#   bash scripts/setup-vault-approle.sh --mint labctl   # imprime role_id + secret_id frais
#   bash scripts/setup-vault-approle.sh --mint ci
set -euo pipefail
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-stoa-root-token}"   # token ADMIN de bootstrap (pas le runtime)
TOKEN_TTL="${TOKEN_TTL:-3m}"                     # durée de vie du token éphémère
SECRET_ID_TTL="${SECRET_ID_TTL:-10m}"           # durée de vie du secret_id (court)
SECRET_ID_USES="${SECRET_ID_USES:-0}"           # 0 = illimité (PoC) ; prod: 1 (single-use)
CURL=(/usr/bin/curl -s -H "X-Vault-Token: $VAULT_TOKEN")

# --mint <role>: imprime "role_id<TAB>secret_id" frais, sans rien logger d'autre.
if [ "${1:-}" = "--mint" ]; then
  ROLE="${2:?usage: --mint <labctl|ci|ci-pipeline|proxy-provision>}"
  RID="$("${CURL[@]}" "$VAULT_ADDR/v1/auth/approle/role/$ROLE/role-id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["role_id"])')"
  SID="$("${CURL[@]}" -X POST "$VAULT_ADDR/v1/auth/approle/role/$ROLE/secret-id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["secret_id"])')"
  printf '%s\t%s\n' "$RID" "$SID"
  exit 0
fi

# policy <name> <hcl>
policy() {
  "${CURL[@]}" -X PUT "$VAULT_ADDR/v1/sys/policies/acl/$1" \
    -H 'Content-Type: application/json' -d "{\"policy\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")}" \
    -o /dev/null -w "  policy $1 -> HTTP %{http_code}\n"
}

echo "Vault $VAULT_ADDR — policies least-privilege + AppRoles éphémères"
# stoa-labctl (platform reader) : lit les creds gateway/keycloak ET le matériel
# FOURNI par les projets sous projects/* (CA partenaire, creds backend) pour les
# déployer. Il LIT projects/* mais n'y ÉCRIT jamais.
policy stoa-labctl 'path "secret/data/stoa/gateways/*" { capabilities = ["read"] }
path "secret/data/stoa/keycloak" { capabilities = ["read"] }
path "secret/data/stoa/projects/*" { capabilities = ["read"] }'
# write-accounts-team : self-service SCOPÉ du projet accounts-team. Il ÉCRIT (et
# relit) UNIQUEMENT son propre sous-arbre projects/accounts-team/*. Jamais gateways/*,
# jamais keycloak, jamais un autre projet. C'est la réponse à « comment un projet
# pousse ses creds dans un Vault qui n'est pas le sien » : un rôle write scopé.
policy write-accounts-team 'path "secret/data/stoa/projects/accounts-team/*" { capabilities = ["create","update","read"] }
path "secret/metadata/stoa/projects/accounts-team/*" { capabilities = ["read","list"] }'
policy stoa-ci 'path "secret/data/stoa/ci" { capabilities = ["read"] }
path "secret/data/stoa/opensearch" { capabilities = ["read"] }'
# ADR-075 — provisioning des proxies admin wm-admin-{env} UNIQUEMENT. Le chemin
# secret/stoa/envs/+/wm-admin n'est PAS donné à stoa-ci ni stoa-labctl : la CI
# hors-prod ne voit JAMAIS les creds admin des mocks (elle ne porte qu'un Bearer
# ci-horsprod) — contre-épreuve « ci-pipeline lit envs/dev/wm-admin → 403 »
# dans scripts/demo-multienv.sh.
policy stoa-proxy-provision 'path "secret/data/stoa/envs/+/wm-admin" { capabilities = ["read"] }
path "secret/data/stoa/gateways/webmethods" { capabilities = ["read"] }'

# enable approle (idempotent : 400 si déjà actif)
"${CURL[@]}" -X POST "$VAULT_ADDR/v1/sys/auth/approle" -H 'Content-Type: application/json' \
  -d '{"type":"approle"}' -o /dev/null -w "  enable approle -> HTTP %{http_code} (204 ok / 400 déjà actif)\n" || true

# role <name> <policy>
role() {
  "${CURL[@]}" -X POST "$VAULT_ADDR/v1/auth/approle/role/$1" -H 'Content-Type: application/json' \
    -d "{\"token_policies\":\"$2\",\"token_ttl\":\"$TOKEN_TTL\",\"token_max_ttl\":\"$TOKEN_TTL\",\"secret_id_ttl\":\"$SECRET_ID_TTL\",\"secret_id_num_uses\":$SECRET_ID_USES}" \
    -o /dev/null -w "  role $1 (policy $2, token_ttl $TOKEN_TTL) -> HTTP %{http_code}\n"
}
role labctl stoa-labctl
role ci      stoa-ci
# ci-pipeline : le job Jenkins lit SES secrets (ci+opensearch) ET fait tourner
# labctl (gateways+keycloak) — un seul login, un token éphémère scopé EXACTEMENT
# à ces 4 chemins (rien d'autre, jamais root). Single secret_id côté Jenkins.
role ci-pipeline 'stoa-ci,stoa-labctl'
# proxy-provision : l'OPÉRATEUR qui pose les 3 proxies admin (ADR-075,
# setup-wm-admin-proxy.sh) — seul rôle à lire secret/stoa/envs/+/wm-admin.
role proxy-provision stoa-proxy-provision
# accounts-team : identité du PROJET pour pousser SES propres secrets (self-service
# scopé). WRITE limité à projects/accounts-team/* — un token de ce rôle ne peut ni
# écrire gateways/*, ni lire un autre projet (contre-épreuve dans le --demo-scope).
role accounts-team write-accounts-team

echo "done. Mint d'un secret_id frais :"
echo "    $0 --mint labctl           # token éphémère, policy stoa-labctl (gateways+keycloak+projects RO)"
echo "    $0 --mint ci               # token éphémère, policy stoa-ci (ci+opensearch)"
echo "    $0 --mint ci-pipeline      # token éphémère, les 2 policies (le job Jenkins)"
echo "    $0 --mint proxy-provision  # token éphémère, policy stoa-proxy-provision (ADR-075)"
echo "    $0 --mint accounts-team    # token éphémère, WRITE scopé projects/accounts-team/* (projet)"
