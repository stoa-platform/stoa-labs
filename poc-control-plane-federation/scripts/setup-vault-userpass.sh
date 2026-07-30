#!/usr/bin/env bash
# setup-vault-userpass.sh — VOIE A (ADR-078 §3) : « un utilisateur se connecte au
# Vault avec son user/mot de passe depuis Jenkins », palier LAB.
#
#   humain ──(user + mot de passe, paramètre de build)──▶ Jenkins
#          ──▶ POST /v1/<mount>/login/<user> ──▶ token Vault NOMINATIF
#          ──▶ le rôle Ansible lit les creds du compte de service gateway
#          ──▶ revoke-self + PREUVE DE MORT en fin de build
#
# Pourquoi `userpass` alors que le client est en LDAP/AD : la requête REST est
# IDENTIQUE (POST /v1/<mount>/login/<user> + {"password": …}) — seul le MOUNT
# change. Ce script prouve donc TOUTE la chaîne pipeline sans annuaire ; la
# fidélité AD (bind, userdn, groupfilter, mapping groupe→policy) est prouvée par
# scripts/setup-vault-ldap.sh contre un OpenLDAP réel.
#
# Provisionne (idempotent, re-jouable après recreate de poc-vault) :
#   1. auth method `userpass` (mount configurable — USERPASS_MOUNT)
#   2. policies `deploy-<tenant>` : READ secret/stoa/deploy/<tenant>/* UNIQUEMENT
#   3. utilisateurs de démo (matrice de preuve, cf. ci-dessous)
#   4. audit device file (la traçabilité nominative que l'IT exige)
#
# ⚠ DIFFÉRENCE DE MÉCANIQUE avec ADR-077 (chaîne B / JWT), à connaître :
#   en JWT, la ségrégation par tenant vient d'une policy TEMPLATÉE sur le claim
#   `tenant` du jeton. En user/password il n'y a PAS de claim : la ségrégation
#   passe par une policy STATIQUE PAR TENANT, attachée à l'utilisateur (userpass)
#   ou au GROUPE AD (ldap : auth/ldap/groups/<grp>). Conséquence côté client :
#   il faut UN GROUPE AD PAR TENANT, et c'est l'annuaire qui devient la source
#   de vérité de « qui déploie pour qui ».
#
# Matrice d'utilisateurs (chacun porte UN invariant de la preuve) :
#   alice               banking-demo   nominal
#   bob                 payments-team  cross-tenant (doit se voir refuser banking-demo)
#                                      + MOT DE PASSE À MÉTACARACTÈRES (" \ $ ' ; &)
#                                        -> prouve que le corps JSON n'est pas forgé en shell
#   carol               —              authentifiée mais SANS policy de déploiement
#   CORP\alice          banking-demo   prouve l'URL-encodage du path (%5C)
#   alice@corp.example  banking-demo   prouve l'URL-encodage du path (%40, format UPN)
#
#   bash scripts/setup-vault-userpass.sh
#   ./scripts/test-vault-user-login.sh      # la preuve
set -uo pipefail

VADDR="${VAULT_ADDR:-http://localhost:8200}"; VTOK="${VAULT_TOKEN:?Variable VAULT_TOKEN absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
MOUNT="${USERPASS_MOUNT:-userpass}"
TENANTS="${TENANTS:-banking-demo payments-team}"
TOKEN_TTL="${TOKEN_TTL:-600}"; TOKEN_MAX_TTL="${TOKEN_MAX_TTL:-900}"

# Identités de démo — SOURCE UNIQUE partagée avec la preuve (aucune dérive possible).
# shellcheck source=scripts/lib/lab-vault-users.sh
. "$(dirname "$0")/lib/lab-vault-users.sh"

say()  { printf '\033[1;36m[vault-userpass]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[vault-userpass]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[vault-userpass]\033[0m %s\n' "$*"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Le token Vault part dans un header-FILE, jamais en argv (standard ADR-074).
printf 'X-Vault-Token: %s\n' "$VTOK" > "$TMP/hdr"
vcurl() { curl -s -H @"$TMP/hdr" "$@"; }

curl -s -o /dev/null "$VADDR/v1/sys/health" || fail "Vault injoignable sur $VADDR"

# ═══ 1. auth method userpass ═════════════════════════════════════════════════
if ! vcurl "$VADDR/v1/sys/auth" | python3 -c "import sys,json;raise SystemExit(0 if '$MOUNT/' in json.load(sys.stdin) else 1)" 2>/dev/null; then
  RC=$(vcurl -X POST "$VADDR/v1/sys/auth/$MOUNT" -d '{"type":"userpass"}' -o "$TMP/err" -w '%{http_code}')
  case "$RC" in 200|204) say "auth method userpass activée sur $MOUNT/";;
                *) fail "activation auth/$MOUNT KO (HTTP $RC): $(cat "$TMP/err")";; esac
else
  say "auth method $MOUNT/ déjà activée"
fi

# ═══ 2. policies deploy-<tenant> (STATIQUES, une par tenant — modèle LDAP) ═══
# On génère le HCL en python : imbriquer une policy HCL (guillemets) dans du JSON
# dans du shell donne un empilement d'échappements illisible et fragile.
for T in $TENANTS; do
  python3 - "$T" > "$TMP/pol.json" <<'PY'
import json, sys
t = sys.argv[1]
hcl = (
    '# Périmètre de déploiement du tenant %s.\n'
    '# LECTURE sur tout le sous-arbre du tenant ; ÉCRITURE limitée au seul\n'
    '# sous-arbre apps/ (mode OAuth2 internal : celui qui déploie une app de SON\n'
    '# tenant y stocke le client généré par la gateway — jamais ailleurs, jamais\n'
    "# un autre tenant). La ségrégation reste ENFORCÉE ici, pas dans le pipeline.\n"
    'path "secret/data/stoa/deploy/%s/*"          { capabilities = ["read"] }\n'
    'path "secret/metadata/stoa/deploy/%s/*"      { capabilities = ["read", "list"] }\n'
    'path "secret/data/stoa/deploy/%s/apps/*"     { capabilities = ["create", "update", "read"] }\n'
    'path "secret/metadata/stoa/deploy/%s/apps/*" { capabilities = ["read", "list"] }\n'
) % (t, t, t, t, t)
json.dump({"policy": hcl}, sys.stdout)
PY
  RC=$(vcurl -X PUT "$VADDR/v1/sys/policies/acl/deploy-$T" --data-binary @"$TMP/pol.json" -o "$TMP/err" -w '%{http_code}')
  case "$RC" in 200|204) say "policy deploy-$T (READ secret/stoa/deploy/$T/* uniquement)";;
                *) fail "policy deploy-$T KO (HTTP $RC): $(cat "$TMP/err")";; esac
done

# Policy de l'OPÉRATEUR DE MISE EN PROD — périmètre PLATEFORME, distinct des
# périmètres de tenant. Jenkinsfile.prod/.rollback en ont besoin pour tourner sous
# une identité NOMINATIVE ; sans elle, ces pipelines ne peuvent que retomber sur
# l'AppRole (identité de machine, acte non imputable à un humain).
# HCL généré en python (comme les policies de tenant) : le faire transiter par un
# printf shell casserait ses guillemets à la première expansion.
python3 - > "$TMP/pol.json" <<'POLICY'
import json, sys
hcl = (
    "# Perimetre PLATEFORME de l'operateur de mise en prod - READ SEULE.\n"
    "# /!\\ Donne a un HUMAIN la lecture des secrets de service (jeton du compte\n"
    "# applicatif, mot de passe OpenSearch, creds admin des gateways). L'octroi de\n"
    "# cette policy est une decision de securite du client, pas un defaut technique.\n"
    'path "secret/data/stoa/ci"             { capabilities = ["read"] }\n'
    'path "secret/data/stoa/opensearch"     { capabilities = ["read"] }\n'
    'path "secret/data/stoa/gateways/*"     { capabilities = ["read"] }\n'
    'path "secret/metadata/stoa/gateways/*" { capabilities = ["read", "list"] }\n'
)
json.dump({"policy": hcl}, sys.stdout)
POLICY
RC=$(vcurl -X PUT "$VADDR/v1/sys/policies/acl/operator-deploy" --data-binary @"$TMP/pol.json" -o "$TMP/err" -w '%{http_code}')
case "$RC" in 200|204) say "policy operator-deploy (READ plateforme : ci, opensearch, gateways/*)";;
              *) fail "policy operator-deploy KO (HTTP $RC): $(cat "$TMP/err")";; esac

# ═══ 3. utilisateurs de démo ═════════════════════════════════════════════════
# mkuser <username> <password> <policies csv>  — le username est URL-ENCODÉ dans
# le path (il peut contenir \ ou @) et le mot de passe part par FICHIER (jamais argv).
mkuser() {
  local u="$1" p="$2" pol="$3" enc rc
  enc="$(VU="$u" python3 -c 'import os,urllib.parse;print(urllib.parse.quote(os.environ["VU"], safe=""))')"
  P="$p" POL="$pol" TTL="$TOKEN_TTL" MAXTTL="$TOKEN_MAX_TTL" python3 - > "$TMP/user.json" <<'PY'
import json, os, sys
json.dump({"password": os.environ["P"],
           "token_policies": os.environ["POL"],
           "token_ttl": int(os.environ["TTL"]),
           "token_max_ttl": int(os.environ["MAXTTL"])}, sys.stdout)
PY
  rc=$(vcurl -X POST "$VADDR/v1/auth/$MOUNT/users/$enc" --data-binary @"$TMP/user.json" -o "$TMP/err" -w '%{http_code}')
  case "$rc" in 200|204) say "utilisateur '$u' -> policies [$pol], TTL ${TOKEN_TTL}s";;
                *) fail "création utilisateur '$u' KO (HTTP $rc): $(cat "$TMP/err")";; esac
}

mkuser "$LAB_ALICE_USER" "$LAB_ALICE_PASS" "deploy-$LAB_TENANT_ALICE"
mkuser "$LAB_BOB_USER"   "$LAB_BOB_PASS"   "deploy-$LAB_TENANT_BOB"
mkuser "$LAB_CAROL_USER" "$LAB_CAROL_PASS" ''
mkuser "$LAB_OSCAR_USER" "$LAB_OSCAR_PASS" 'operator-deploy'
# Pas de CORP\alice ni alice@corp.example ICI : `userpass` refuse `@` et `\` dans
# un username (GenericNameRegex). Les formats AD réels sont provisionnés et prouvés
# sur le palier LDAP — cf. scripts/lib/lab-vault-users.sh et setup-vault-ldap.sh.
warn "userpass n'accepte ni '@' ni '\\' dans un username : les formats UPN et DOMAIN\\user se prouvent sur le palier LDAP."

# ═══ 4. audit device (preuve nominative : QUI s'est connecté, succès ET refus) ═
if ! vcurl "$VADDR/v1/sys/audit" | python3 -c 'import sys,json;raise SystemExit(0 if "file/" in json.load(sys.stdin) else 1)' 2>/dev/null; then
  RC=$(vcurl -X PUT "$VADDR/v1/sys/audit/file" -d '{"type":"file","options":{"file_path":"/tmp/vault-audit.log"}}' -o "$TMP/err" -w '%{http_code}')
  case "$RC" in 200|204) say "audit device file activé (/tmp/vault-audit.log dans poc-vault)";;
                *) fail "audit device KO (HTTP $RC): $(cat "$TMP/err")";; esac
else
  say "audit device déjà actif"
fi

# ═══ 5. garde-fou : le périmètre lu par le pipeline doit exister ══════════════
for T in $TENANTS; do
  RC=$(vcurl -o /dev/null -w '%{http_code}' "$VADDR/v1/secret/data/stoa/deploy/$T/wm-admin")
  [ "$RC" = 200 ] || warn "secret/stoa/deploy/$T/wm-admin absent (HTTP $RC) — le rôle retombera sur ses valeurs littérales. Lancer scripts/setup-vault.sh."
done

say "Terminé. VAULT_USER_AUTH_MOUNT=$MOUNT  ·  preuve : ./scripts/test-vault-user-login.sh"
