#!/usr/bin/env bash
# setup-user-vault-jwt.sh — chaîne A (ADR-077) : l'IDENTITÉ UTILISATEUR va
# jusqu'à Vault, sans aucun mot de passe stocké côté chaîne CI.
#
#   user (Console/Dex) ──auth_code──▶ Keycloak ──token exchange (RFC 8693,
#   client vault-exchange, audience=vault)──▶ JWT court sub=user, aud=vault,
#   tenant=<tenant> ──▶ Vault auth/jwt/login ──▶ token Vault NOMINATIF
#   (entité = user) scoped au périmètre deploy de SON tenant.
#
# Répond à la contrainte client « c'est un utilisateur qui se connecte au
# Vault, pas une application » : l'entité Vault ET l'audit log portent
# l'utilisateur ; le pipeline n'a que la délégation courte (TTL 5 min).
#
# Provisionne (idempotent, re-jouable après recreate de poc-keycloak/poc-vault) :
#   Keycloak (état DYNAMIQUE — le realm import ne doit PAS déclarer clientScopes,
#   sinon il supprime la création des scopes built-in) :
#     1. client scope `vault-aud` (audience mapper → vault)
#     2. attaché en scope PAR DÉFAUT du client `vault-exchange` — sans lui,
#        l'exchange standard refuse « Requested audience not available: vault »
#   Vault :
#     3. auth method `jwt` + config JWKS split-horizon (fetch keycloak:8080,
#        issuer épinglé http://localhost:8480 — même modèle que les gateways)
#     4. policy `user-deploy` TEMPLATÉE par tenant : READ limité à
#        secret/stoa/deploy/<tenant de l'entité>/* (ségrégation par tenant —
#        un tenant-admin de banking-demo ne lit PAS payments-team)
#     5. rôle jwt `user-deploy` : bound_audiences=vault + azp=vault-exchange
#        (défense en profondeur : même un token aud=vault émis autrement
#        qu'via l'échangeur est refusé), entité = claim preferred_username,
#        claim tenant → metadata (alimente la policy templatée), restreint
#        aux rôles realm métier (bound_claims any-of)
#     6. audit device file (la preuve nominative que l'IT demande)
#     7. secrets de démo secret/stoa/deploy/{banking-demo,payments-team}/demo
#
# Les clients KC `vault` / `vault-exchange` (dont le mapper tenant) et les
# mappers aud=vault-exchange de console-light / stoa-portal sont STATIQUES :
# identity/keycloak/realm-stoa-lab.json.
#
# NB dave/cpi-admin (attribut tenant vide) : le claim_mappings `tenant` exige
# le claim dans le JWT → login refusé. Assumé : la chaîne A est un canal de
# déploiement TENANT-scopé ; un admin plateforme passe par sa propre policy
# (delta prod documenté en ADR-077 §Limites).
set -uo pipefail

KC_BASE="${KC_BASE:-http://localhost:8480}"
REALM="${REALM:-stoa-lab}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"; KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"
VADDR="${VAULT_ADDR:-http://localhost:8200}"; VTOK="${VAULT_TOKEN:?Variable VAULT_TOKEN absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
# Vue de l'INTÉRIEUR du conteneur poc-vault (réseau compose) vs issuer épinglé.
KC_JWKS_INTERNAL="${KC_JWKS_INTERNAL:-http://keycloak:8080/realms/${REALM}/protocol/openid-connect/certs}"
KC_ISSUER_PINNED="${KC_ISSUER_PINNED:-${KC_BASE}/realms/${REALM}}"

say()  { printf '\033[1;36m[user-vault]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[user-vault]\033[0m %s\n' "$*"; exit 1; }
# G4 (ADR-082) : les paliers ou la voie B a le droit d'ECRIRE un secret d'app,
# derives de LA chaine — jamais reecrits ici. Le terminus n'y est pas, par
# structure (env_chain_nonprod retire le DERNIER palier, pas « prod » par son
# nom). Chaine illisible ⇒ on s'arrete : une policy posee sur une liste devinee
# est pire que pas de policy du tout.
#
# ⚠ CHEZ UN CLIENT, POSER STOA_ENV_CHAIN_FILE SUR LA CHAINE REELLE — une policy
# derivee du gabarit d'exemple peut rendre son terminus INSCRIPTIBLE (ADR-082).
# env-chain.sh retombe sur clients/_example/environments.yaml quand la variable
# est absente : c'est la source declaree du lab, mais chez un client dont la
# chaine est plus COURTE, le dernier palier du gabarit n'est pas son terminus a
# lui — il entrerait alors dans la liste hors-prod, donc dans les chemins
# inscriptibles, SANS AUCUN SYMPTOME. D'ou la ligne qui suit : la source lue est
# NOMMEE dans la sortie, pas devinee a la relecture.
# shellcheck source=scripts/lib/env-chain.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/env-chain.sh"
UVJ_WRITE_ENVS="$(env_chain_nonprod)" || fail "CHAINE_ILLISIBLE : env_chain_nonprod"
say "chaîne d'envs lue depuis : ${STOA_ENV_CHAIN_FILE:-<gabarit par défaut : clients/_example/environments.yaml>}"
# Le token Vault part dans un header-FILE, jamais en argv (ps/cmdline) —
# standard du repo depuis ADR-074 (« jamais en argv »).
VHDR="$(mktemp)"; trap 'rm -f "$VHDR" /tmp/uvj-*.err' EXIT
printf 'X-Vault-Token: %s\n' "$VTOK" > "$VHDR"
vcurl(){ curl -s -H @"$VHDR" "$@"; }

# ═══ 1+2. Keycloak : client scope vault-aud → défaut de vault-exchange ═══════
AT=$(curl -s -d grant_type=password -d client_id=admin-cli \
  -d "username=${KC_ADMIN_USER}" -d "password=${KC_ADMIN_PASSWORD}" \
  "${KC_BASE}/realms/master/protocol/openid-connect/token" |
  python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
[ -n "$AT" ] || fail "token admin Keycloak KO (${KC_BASE})"
KR="${KC_BASE}/admin/realms/${REALM}"
kc(){ curl -s -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' "$@"; }

SID=$(kc "$KR/client-scopes" | python3 -c 'import sys,json;print(next((s["id"] for s in json.load(sys.stdin) if s["name"]=="vault-aud"),""))')
if [ -z "$SID" ]; then
  RC=$(kc -X POST "$KR/client-scopes" -d '{
    "name":"vault-aud","protocol":"openid-connect",
    "attributes":{"include.in.token.scope":"false","display.on.consent.screen":"false"},
    "protocolMappers":[{"name":"vault-audience","protocol":"openid-connect",
      "protocolMapper":"oidc-audience-mapper","consentRequired":false,
      "config":{"included.client.audience":"vault","id.token.claim":"false","access.token.claim":"true"}}]}' \
    -o /dev/null -w '%{http_code}')
  [ "$RC" = 201 ] || fail "création client scope vault-aud KO (HTTP $RC)"
  SID=$(kc "$KR/client-scopes" | python3 -c 'import sys,json;print(next((s["id"] for s in json.load(sys.stdin) if s["name"]=="vault-aud"),""))')
  say "client scope vault-aud créé"
else
  say "client scope vault-aud déjà présent"
fi
[ -n "$SID" ] || fail "client scope vault-aud introuvable après création"

CID=$(kc "$KR/clients?clientId=vault-exchange" | python3 -c 'import sys,json;c=json.load(sys.stdin);print(c[0]["id"] if c else "")')
[ -n "$CID" ] || fail "client vault-exchange absent — recréer poc-keycloak (realm-stoa-lab.json le déclare)"
RC=$(kc -X PUT "$KR/clients/$CID/default-client-scopes/$SID" -o /dev/null -w '%{http_code}')
[ "$RC" = 204 ] || fail "attache vault-aud à vault-exchange KO (HTTP $RC)"
say "vault-aud = scope par défaut de vault-exchange"

# ═══ 3. Vault : auth jwt + config split-horizon ══════════════════════════════
if ! vcurl "$VADDR/v1/sys/auth" | python3 -c 'import sys,json;raise SystemExit(0 if "jwt/" in json.load(sys.stdin) else 1)' 2>/dev/null; then
  RC=$(vcurl -X POST "$VADDR/v1/sys/auth/jwt" -d '{"type":"jwt"}' -o /tmp/uvj-auth.err -w '%{http_code}')
  case "$RC" in 200|204) say "auth method jwt activée";; *) fail "activation auth jwt KO (HTTP $RC): $(cat /tmp/uvj-auth.err)";; esac
else
  say "auth method jwt déjà activée"
fi
# accessor du mount jwt — requis par la policy templatée par tenant.
JWT_ACCESSOR=$(vcurl "$VADDR/v1/sys/auth" | python3 -c 'import sys,json;print(json.load(sys.stdin)["jwt/"]["accessor"])' 2>/dev/null)
[ -n "$JWT_ACCESSOR" ] || fail "accessor du mount jwt introuvable"

RC=$(vcurl -X POST "$VADDR/v1/auth/jwt/config" -d "{
  \"jwks_url\": \"${KC_JWKS_INTERNAL}\",
  \"bound_issuer\": \"${KC_ISSUER_PINNED}\"
}" -w '%{http_code}' -o /tmp/uvj-cfg.err)
[ "$RC" = 204 ] || [ "$RC" = 200 ] || fail "config auth/jwt KO (HTTP $RC) — Vault joint-il keycloak:8080 ? $(cat /tmp/uvj-cfg.err)"
say "config jwt : jwks=${KC_JWKS_INTERNAL} / issuer épinglé ${KC_ISSUER_PINNED}"

# ═══ 4. policy user-deploy TEMPLATÉE (voie B) ════════════════════════════════
# PÉRIMÈTRE : lecture sur tout le sous-arbre du tenant, ÉCRITURE bornée au seul
# sous-arbre `apps/`, ET PAR PALIER NON TERMINAL (G4, ADR-082 : `apps/+/<env>/*`,
# un bloc par palier de $UVJ_WRITE_ENVS). STRICTEMENT LE MÊME que la policy
# deploy-<tenant> de la voie A (rôle apim_team_onboard, tasks/vault.yml) : les
# deux voies mènent à la même personne, elles doivent donner le même pouvoir —
# le resserrage par palier DOIT donc rester appliqué des deux côtés, sinon la
# rétention de credential se contourne en changeant de porte d'entrée.
# Jusqu'au 2026-08-03 la voie B était en LECTURE SEULE — un même humain pouvait
# donc écrire la clé d'une application en se connectant par mot de passe, et ne
# le pouvait plus en arrivant par le SSO. Écart silencieux, corrigé ici.
#
# POURQUOI L'ÉCRITURE. Le valideur d'une PR initialise les secrets de
# l'application qu'il approuve (clé backend, client OAuth2 interne) sous SON
# identité : c'est ce qui rend l'écriture imputable dans l'audit Vault.
#
# POURQUOI `apps/` ET PAS LE SOUS-ARBRE DU TENANT. Le préfixe du tenant contient
# aussi `wm-admin` (compte de service de la gateway) et `admin-oauth`. Y accorder
# l'écriture permettrait à un valideur d'écraser les identifiants d'admin de son
# tenant — escalade sévère. Le bornage est fait PAR PRÉFIXE, et il ne peut pas
# l'être autrement : un `deny` explicite sur ces chemins serait TOTAL en HCL
# Vault (il n'existe pas de « deny en écriture seulement ») et casserait la
# LECTURE dont l'apply a besoin pour ces mêmes secrets.
VP="secret/data/stoa/deploy/{{identity.entity.aliases.${JWT_ACCESSOR}.metadata.tenant}}"
VM="secret/metadata/stoa/deploy/{{identity.entity.aliases.${JWT_ACCESSOR}.metadata.tenant}}"
# $UVJ_WRITE_ENVS est volontairement NON quoté : le découpage par mots est
# l'effet VOULU (un argv par palier), pas un oubli.
# shellcheck disable=SC2086
python3 - "$VP" "$VM" $UVJ_WRITE_ENVS > /tmp/uvj-pol.json <<'PY' || fail "gabarit de policy user-deploy KO"
import json, sys
d, m = sys.argv[1], sys.argv[2]
envs = sys.argv[3:]
# PAS un `assert` : PYTHONOPTIMIZE=1 (ou `python3 -O`) les SUPPRIME du bytecode,
# et la garde disparaitrait sans bruit — exactement l'inverse d'un fail-closed.
if not envs:
    sys.exit("liste de paliers vide — fail-closed")
lines = [
    '# Périmètre de déploiement du tenant porté par la claim (voie B, ADR-077).',
    '# LECTURE sur tout le sous-arbre ; ÉCRITURE limitée à apps/ PAR PALIER NON',
    '# TERMINAL (G4, ADR-082) — miroir exact de la policy deploy-<tenant> voie A.',
    'path "%s/*"          { capabilities = ["read"] }' % d,
    'path "%s/*"          { capabilities = ["read", "list"] }' % m,
]
for e in envs:
    lines.append('path "%s/apps/+/%s/*"     { capabilities = ["create", "update", "read"] }' % (d, e))
    lines.append('path "%s/apps/+/%s/*"     { capabilities = ["read", "list"] }' % (m, e))
json.dump({"policy": "\n".join(lines) + "\n"}, sys.stdout)
PY
RC=$(vcurl -X PUT "$VADDR/v1/sys/policies/acl/user-deploy" --data-binary @/tmp/uvj-pol.json -o /tmp/uvj-pol.err -w '%{http_code}')
[ "$RC" = 204 ] || [ "$RC" = 200 ] || fail "policy user-deploy KO (HTTP $RC): $(cat /tmp/uvj-pol.err)"
say "policy user-deploy templatée (READ deploy/<tenant>/*, WRITE deploy/<tenant>/apps/+/<palier>/* pour : $UVJ_WRITE_ENVS)"

# ═══ 5. rôle jwt user-deploy ═════════════════════════════════════════════════
RC=$(vcurl -X POST "$VADDR/v1/auth/jwt/role/user-deploy" -d '{
  "role_type": "jwt",
  "bound_audiences": ["vault"],
  "user_claim": "preferred_username",
  "claim_mappings": { "preferred_username": "username", "azp": "exchanged_by", "tenant": "tenant" },
  "bound_claims_type": "string",
  "bound_claims": {
    "/realm_access/roles": ["tenant-admin", "devops", "cpi-admin"],
    "azp": "vault-exchange"
  },
  "token_policies": ["user-deploy"],
  "token_ttl": 600,
  "token_max_ttl": 900
}' -w '%{http_code}' -o /tmp/uvj-role.err)
[ "$RC" = 204 ] || [ "$RC" = 200 ] || fail "rôle jwt KO (HTTP $RC): $(cat /tmp/uvj-role.err)"
say "rôle jwt user-deploy : aud=vault + azp=vault-exchange, entité=preferred_username, tenant→metadata, rôles realm requis"

# ═══ 6. audit device (preuve nominative : QUI s'est connecté, PAS de secrets en clair) ═══
if ! vcurl "$VADDR/v1/sys/audit" | python3 -c 'import sys,json;raise SystemExit(0 if "file/" in json.load(sys.stdin) else 1)' 2>/dev/null; then
  RC=$(vcurl -X PUT "$VADDR/v1/sys/audit/file" -d '{"type":"file","options":{"file_path":"/tmp/vault-audit.log"}}' -o /tmp/uvj-aud.err -w '%{http_code}')
  case "$RC" in 200|204) say "audit device file activé (/tmp/vault-audit.log dans poc-vault)";; *) fail "audit device KO (HTTP $RC): $(cat /tmp/uvj-aud.err)";; esac
else
  say "audit device déjà actif"
fi

# ═══ 7. secrets de démo PAR TENANT (valeurs PoC jetables, déterministes) ═══════
for T in banking-demo payments-team; do
  RC=$(vcurl -X POST "$VADDR/v1/secret/data/stoa/deploy/$T/demo" -d "{
    \"data\": { \"deployKey\": \"poc-user-chain-a-$T\", \"note\": \"périmètre $T — lu avec un token Vault NOMINATIF (ADR-077)\" }
  }" -o /tmp/uvj-kv.err -w '%{http_code}')
  [ "$RC" = 200 ] || [ "$RC" = 204 ] || fail "écriture secret deploy/$T/demo KO (HTTP $RC): $(cat /tmp/uvj-kv.err)"
done
say "secrets secret/stoa/deploy/{banking-demo,payments-team}/demo écrits"

say "Terminé. Preuve : ./scripts/test-user-vault-jwt.sh"
