#!/usr/bin/env bash
# setup-vault-ldap.sh — VOIE A (ADR-078 §3), palier ANNUAIRE : le login
# user/mot de passe de Jenkins passe par un vrai LDAP, comme chez le client.
#
# Ce que ce palier prouve et que `userpass` ne peut PAS prouver :
#   · le BIND réel (forme du DN utilisateur, compte de service de bind) ;
#   · le MAPPING GROUPE → POLICY : c'est lui qui porte la ségrégation par tenant.
#     En JWT (ADR-077) la policy est templatée sur le claim `tenant` ; en LDAP il
#     n'existe pas de claim — la policy est attachée au GROUPE de l'annuaire, donc
#     il faut UN GROUPE PAR TENANT et c'est l'AD qui devient la source de vérité
#     de « qui a le droit de déployer pour qui » ;
#   · les FORMATS de login de l'entreprise (UPN user@domaine, DOMAIN\user), que
#     `userpass` refuse par construction (regex de path : \w, `-`, `.`).
#
# Provisionne, idempotent et rejouable à chaud :
#   1. l'annuaire de démo (OU, utilisateurs, groupes) via ldapadd dans le conteneur
#   2. l'auth method `ldap` de Vault + sa config (bind, userdn, groupes)
#   3. le TTL des tokens issus de ce mount (durée de vie = celle d'un build)
#   4. le mapping groupe d'annuaire -> policy deploy-<tenant>
#
# Prérequis :
#   docker compose -f docker-compose.poc.yml -f docker-compose.ldap.yml up -d openldap
#   bash scripts/setup-vault-userpass.sh     (pour les policies deploy-<tenant>)
#
#   bash scripts/setup-vault-ldap.sh
#   ./scripts/test-vault-user-login.sh       # les tests [ldap] cessent d'être sautés
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VADDR="${VAULT_ADDR:-http://localhost:8200}"; VTOK="${VAULT_TOKEN:?Variable VAULT_TOKEN absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
MOUNT="${LDAP_MOUNT:-ldap}"
LDAP_CONTAINER="${LDAP_CONTAINER:-poc-openldap}"
BASE_DN="${LDAP_BASE_DN:-dc=corp,dc=example}"
BIND_DN="${LDAP_BIND_DN:-cn=admin,$BASE_DN}"
BIND_PW="${LDAP_ADMIN_PASSWORD:-admin-lab-2026}"
# URL vue DEPUIS le conteneur poc-vault (réseau compose) — même split-horizon que
# le JWKS Keycloak d'ADR-077 : Vault parle aux services par leur nom de service.
LDAP_URL="${LDAP_URL:-ldap://openldap:389}"
TOKEN_TTL="${TOKEN_TTL:-600s}"; TOKEN_MAX_TTL="${TOKEN_MAX_TTL:-900s}"

# shellcheck source=scripts/lib/lab-vault-users.sh
. scripts/lib/lab-vault-users.sh

say()  { printf '\033[1;36m[vault-ldap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[vault-ldap]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[vault-ldap]\033[0m %s\n' "$*"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf 'X-Vault-Token: %s\n' "$VTOK" > "$TMP/hdr"
vcurl() { curl -s -H @"$TMP/hdr" "$@"; }

docker ps --format '{{.Names}}' | grep -qx "$LDAP_CONTAINER" \
  || fail "conteneur $LDAP_CONTAINER absent — docker compose -f docker-compose.poc.yml -f docker-compose.ldap.yml up -d openldap"
curl -s -o /dev/null "$VADDR/v1/sys/health" || fail "Vault injoignable sur $VADDR"

# ═══ 1. Annuaire de démo ═════════════════════════════════════════════════════
# Poussé par ldapadd plutôt que par un LDIF de bootstrap : celui-ci n'est joué
# qu'à la création du volume (donc non rejouable), et il dupliquerait les mots de
# passe de scripts/lib/lab-vault-users.sh. Ici, source unique.
#
# ldapadd renvoie 68 (« Already exists ») en re-run : c'est le cas NOMINAL de
# l'idempotence, pas une erreur.
ldap_add() {   # ldap_add <libellé> < LDIF sur stdin
  local label="$1" out rc
  out=$(docker exec -i "$LDAP_CONTAINER" ldapadd -x -D "$BIND_DN" -w "$BIND_PW" -c 2>&1)
  rc=$?
  if [ "$rc" = 0 ]; then
    say "$label — créé"
  elif grep -q 'Already exists' <<<"$out"; then
    # -c (continue) : ldapadd a ajouté les entrées NOUVELLES et ignoré celles qui
    # existaient déjà. Dire « déjà présent » masquerait les ajouts réels.
    say "$label — convergé (nouvelles entrées ajoutées, existantes ignorées)"
  else
    fail "$label KO (rc=$rc) : $out"
  fi
}

# Le mot de passe d'annuaire part par STDIN de ldapadd, jamais en argv.
ldif_user() {  # ldif_user <uid> <dn-échappé> <mot de passe>
  printf 'dn: uid=%s,ou=People,%s\n' "$2" "$BASE_DN"
  printf 'objectClass: inetOrgPerson\n'
  printf 'uid: %s\n' "$1"
  printf 'cn: %s\n' "$1"
  printf 'sn: %s\n' "$1"
  printf 'userPassword: %s\n\n' "$3"
}

{
  printf 'dn: ou=People,%s\nobjectClass: organizationalUnit\nou: People\n\n' "$BASE_DN"
  printf 'dn: ou=Groups,%s\nobjectClass: organizationalUnit\nou: Groups\n\n' "$BASE_DN"
} | ldap_add "OU People/Groups"

# alice, bob, carol + les DEUX formats d'entreprise. Dans un DN, le `\` doit être
# échappé en `\5C` (RFC 4514) — l'attribut uid, lui, porte la valeur littérale.
{
  ldif_user "$LAB_ALICE_USER"     "$LAB_ALICE_USER"          "$LAB_ALICE_PASS"
  ldif_user "$LAB_BOB_USER"       "$LAB_BOB_USER"            "$LAB_BOB_PASS"
  ldif_user "$LAB_CAROL_USER"     "$LAB_CAROL_USER"          "$LAB_CAROL_PASS"
  ldif_user "$LAB_OSCAR_USER"     "$LAB_OSCAR_USER"          "$LAB_OSCAR_PASS"
  ldif_user "$LAB_ALICE_UPN_USER" "$LAB_ALICE_UPN_USER"      "$LAB_ALICE_PASS"
  ldif_user "$LAB_ALICE_DOMAIN_USER" 'CORP\5Calice'          "$LAB_ALICE_PASS"
} | ldap_add "utilisateurs (alice, bob, carol, UPN, DOMAIN\\user)"

# Groupes = groupOfNames. Vault les retrouve SANS overlay memberOf : son
# groupfilter par défaut fait la recherche inverse (quels groupes ont ce membre).
ldif_group() { # ldif_group <cn> <dn membre>…
  local cn="$1"; shift
  printf 'dn: cn=%s,ou=Groups,%s\n' "$cn" "$BASE_DN"
  printf 'objectClass: groupOfNames\n'
  printf 'cn: %s\n' "$cn"
  local m
  for m in "$@"; do printf 'member: %s\n' "$m"; done
  printf '\n'
}
{
  ldif_group "apim-deploy-$LAB_TENANT_ALICE" \
    "uid=$LAB_ALICE_USER,ou=People,$BASE_DN" \
    "uid=$LAB_ALICE_UPN_USER,ou=People,$BASE_DN" \
    "uid=CORP\\5Calice,ou=People,$BASE_DN"
  ldif_group "apim-deploy-$LAB_TENANT_BOB" "uid=$LAB_BOB_USER,ou=People,$BASE_DN"
  # carol est dans l'annuaire et dans un groupe — mais un groupe SANS policy de
  # déploiement : être authentifié n'est pas être autorisé.
  ldif_group "apim-readonly" "uid=$LAB_CAROL_USER,ou=People,$BASE_DN"
  # Groupe SÉPARÉ de ceux des tenants : l'opérateur de mise en prod lit les secrets
  # de plateforme, les déployeurs de tenant non. Deux périmètres, deux groupes.
  ldif_group "apim-operator-prod" "uid=$LAB_OSCAR_USER,ou=People,$BASE_DN"
} | ldap_add "groupes (apim-deploy-<tenant>, apim-readonly)"

# ═══ 2. auth method ldap ═════════════════════════════════════════════════════
if ! vcurl "$VADDR/v1/sys/auth" | python3 -c "import sys,json;raise SystemExit(0 if '$MOUNT/' in json.load(sys.stdin) else 1)" 2>/dev/null; then
  RC=$(vcurl -X POST "$VADDR/v1/sys/auth/$MOUNT" -d '{"type":"ldap"}' -o "$TMP/err" -w '%{http_code}')
  case "$RC" in 200|204) say "auth method ldap activée sur $MOUNT/";;
                *) fail "activation auth/$MOUNT KO (HTTP $RC): $(cat "$TMP/err")";; esac
else
  say "auth method $MOUNT/ déjà activée"
fi

# Config du mount. Les 4 paramètres que le client devra ajuster à SON annuaire
# sont isolés ici — c'est la totalité de l'écart entre ce lab et son AD :
#   userdn/userattr : où et sous quel attribut chercher l'utilisateur
#                     (AD : userattr=sAMAccountName, ou upndomain=corp.example
#                      pour un bind en user@domaine) ;
#   groupdn/groupattr : où chercher les groupes et quel attribut en est le nom ;
#   binddn/bindpass : le compte de service qui a le droit de CHERCHER dans l'AD.
# Valeurs passées par l'ENV et non interpolées dans le heredoc : un bindpass
# contenant un guillemet casserait le source Python (et pourrait s'y injecter).
U="$LDAP_URL" BD="$BIND_DN" BP="$BIND_PW" BASE="$BASE_DN" python3 - "$TMP/cfg.json" <<'PY'
import json, os, sys
e = os.environ
json.dump({
    "url": e["U"],
    "binddn": e["BD"],
    "bindpass": e["BP"],
    "userdn": "ou=People," + e["BASE"],
    "userattr": "uid",
    "groupdn": "ou=Groups," + e["BASE"],
    "groupattr": "cn",
    "insecure_tls": True,   # lab en clair ; chez le client : LDAPS + certificate
    "starttls": False,
}, open(sys.argv[1], "w"))
PY
RC=$(vcurl -X POST "$VADDR/v1/auth/$MOUNT/config" --data-binary @"$TMP/cfg.json" -o "$TMP/err" -w '%{http_code}')
case "$RC" in 200|204) say "config $MOUNT : url=$LDAP_URL userdn=ou=People,$BASE_DN userattr=uid groupdn=ou=Groups,$BASE_DN";;
              *) fail "config auth/$MOUNT KO (HTTP $RC): $(cat "$TMP/err")";; esac

# ═══ 3. TTL des tokens du mount ══════════════════════════════════════════════
# L'auth ldap n'a pas de « rôle » où poser un TTL (contrairement à jwt/approle) :
# il se règle sur le MOUNT. Sans ça, les tokens héritent du TTL système (768h) —
# un token de déploiement qui survivrait 32 jours au build qui l'a créé.
RC=$(vcurl -X POST "$VADDR/v1/sys/auth/$MOUNT/tune" \
     -d "{\"default_lease_ttl\":\"$TOKEN_TTL\",\"max_lease_ttl\":\"$TOKEN_MAX_TTL\"}" \
     -o "$TMP/err" -w '%{http_code}')
case "$RC" in 200|204) say "TTL du mount : défaut=$TOKEN_TTL max=$TOKEN_MAX_TTL (la vie du token = celle du build)";;
              *) fail "tune auth/$MOUNT KO (HTTP $RC): $(cat "$TMP/err")";; esac

# ═══ 4. Mapping GROUPE D'ANNUAIRE -> POLICY ══════════════════════════════════
# LE point de bascule du modèle : la policy n'est pas attachée à l'utilisateur
# mais à son groupe. Ajouter quelqu'un au tenant = l'ajouter au groupe AD — c'est
# l'annuaire qui gouverne, pas le pipeline ni Vault. Corollaire à porter au
# client : il lui faut UN GROUPE AD PAR TENANT, et un processus pour les peupler.
for T in "$LAB_TENANT_ALICE" "$LAB_TENANT_BOB"; do
  RC=$(vcurl -X POST "$VADDR/v1/auth/$MOUNT/groups/apim-deploy-$T" \
       -d "{\"policies\":\"deploy-$T\"}" -o "$TMP/err" -w '%{http_code}')
  case "$RC" in 200|204) say "groupe 'apim-deploy-$T' -> policy deploy-$T";;
                *) fail "mapping groupe apim-deploy-$T KO (HTTP $RC): $(cat "$TMP/err")";; esac
done
RC=$(vcurl -X POST "$VADDR/v1/auth/$MOUNT/groups/apim-operator-prod" \
     -d '{"policies":"operator-deploy"}' -o "$TMP/err" -w '%{http_code}')
case "$RC" in 200|204) say "groupe 'apim-operator-prod' -> policy operator-deploy (secrets de PLATEFORME — décision client)";;
              *) fail "mapping groupe apim-operator-prod KO (HTTP $RC): $(cat "$TMP/err")";; esac

# apim-readonly n'est mappé sur AUCUNE policy : carol s'authentifiera sans
# pouvoir lire le moindre périmètre de déploiement.
vcurl -o /dev/null -w '' -X POST "$VADDR/v1/auth/$MOUNT/groups/apim-readonly" -d '{"policies":""}'
say "groupe 'apim-readonly' -> aucune policy (authentifié ≠ autorisé)"

vcurl "$VADDR/v1/sys/policies/acl/deploy-$LAB_TENANT_ALICE" | grep -q '"policy"' \
  || warn "policy deploy-$LAB_TENANT_ALICE absente — lancer d'abord scripts/setup-vault-userpass.sh"

say "Terminé. VAULT_USER_AUTH_MOUNT=$MOUNT  ·  preuve : ./scripts/test-vault-user-login.sh"
