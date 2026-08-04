#!/usr/bin/env bash
# setup-team-onboard-prereqs.sh — les deux prérequis bloquants du palier 2 (§8) :
#   1. policy Vault `team-onboarder` : ce que l'APPLY d'onboarding a le droit
#      d'écrire — les policies deploy-<team> et les entrées KV wm-admin des
#      tenants, RIEN d'autre. Toutes les preuves du palier 1 tournaient au token
#      root : cette policy est ce qui rend l'apply livrable.
#   2. token org-admin Gitea (création d'orgs/dépôts), STOCKÉ DANS VAULT sous
#      secret/stoa/ci/gitea-org-admin — jamais dans les credentials Jenkins :
#      seul le porteur de team-onboarder le lit, donc seul l'apply post-merge.
#   3. attache team-onboarder à l'opérateur nominatif (ONBOARD_OPERATOR).
#
# Idempotent : rejouable — la policy est un PUT (remplace son propre HCL), le
# token Gitea est régénéré à chaque run (motif setup-provision-request-job.sh),
# et l'attache §3 est un AJOUT — jamais un remplacement — des token_policies
# existantes de l'opérateur (cf. §3 ci-dessous : casser deploy-<team> d'oscar
# casserait la chaîne applicative prouvée au palier 1).
#
#   VAULT_TOKEN=… GITEA_ADMIN_USER=ci bash scripts/setup-team-onboard-prereqs.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis (amorçage, droits admin)}"
GITEA_CONTAINER="${GITEA_CONTAINER:-poc-gitea}"
# Pas de défaut : le user admin réel de Gitea SE RELÈVE (docker exec -u git
# $GITEA_CONTAINER gitea admin user list), il ne se suppose pas — au lab ce
# n'est PAS "admin" mais "ci" (compte de service, cf. IsAdmin=true).
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:?relever via: docker exec -u git $GITEA_CONTAINER gitea admin user list}"
ONBOARD_OPERATOR="${ONBOARD_OPERATOR:-oscar}"
# local nommée MOUNT (pas USERPASS_MOUNT) : même motif que setup-vault-userpass.sh
# ligne 64 — le nom de la variable LOCALE ne doit pas contenir PASS/SECRET/TOKEN,
# sous peine de faux positif sur check-no-plaintext-secrets.sh (le motif de la
# garde matche le NOM de variable assignée, pas la variable d'env source).
MOUNT="${USERPASS_MOUNT:-userpass}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
# Le token Vault part dans un header-FILE, jamais en argv (standard ADR-074,
# motif setup-vault-userpass.sh:77-79 / vcurl).
printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$TMP/hdr"
vcurl(){ curl -s -H @"$TMP/hdr" "$@"; }
ok(){ printf '  \033[32m✅\033[0m %s\n' "$*"; }
ko(){ printf '  \033[31m❌\033[0m %s\n' "$*"; exit 1; }

curl -s -o /dev/null "$VAULT_ADDR/v1/sys/health" || ko "Vault injoignable sur $VAULT_ADDR"

echo "1. policy team-onboarder"
# HCL généré en python (comme les policies de tenant dans setup-vault-userpass.sh
# ligne ~142) : le faire transiter par un printf shell casserait ses guillemets.
python3 - > "$TMP/pol.json" <<'PY'
import json
hcl = (
    "# Perimetre de l'APPLY d'onboarding d'equipe (palier 2).\n"
    "# Ecrit les policies deploy-<team> et les entrees KV wm-admin des tenants\n"
    "# — et lit le token org-admin Gitea. RIEN d'autre : pas gateways/*, pas ci/*\n"
    "# au-dela de l'entree nommee.\n"
    'path "sys/policies/acl/deploy-*"                  { capabilities = ["create", "update", "read"] }\n'
    'path "secret/data/stoa/deploy/+/wm-admin"         { capabilities = ["create", "update", "read"] }\n'
    'path "secret/metadata/stoa/deploy/*"              { capabilities = ["read", "list"] }\n'
    'path "secret/data/stoa/ci/gitea-org-admin"        { capabilities = ["read"] }\n'
)
json.dump({"policy": hcl}, __import__("sys").stdout)
PY
RC=$(vcurl -X PUT "$VAULT_ADDR/v1/sys/policies/acl/team-onboarder" --data-binary @"$TMP/pol.json" -o "$TMP/err" -w '%{http_code}')
{ [ "$RC" = 200 ] || [ "$RC" = 204 ]; } && ok "policy team-onboarder" || ko "policy (HTTP $RC): $(cat "$TMP/err")"

echo "2. token org-admin Gitea → Vault"
GTOK=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token \
  --username "$GITEA_ADMIN_USER" --token-name "team-onboard-$(date +%s)" \
  --scopes write:organization,write:repository 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
[ -n "$GTOK" ] || ko "génération token Gitea (user $GITEA_ADMIN_USER)"
printf '{"data":{"token":"%s"}}' "$GTOK" > "$TMP/kv.json"
RC=$(vcurl -X POST "$VAULT_ADDR/v1/secret/data/stoa/ci/gitea-org-admin" --data-binary @"$TMP/kv.json" -o "$TMP/err" -w '%{http_code}')
{ [ "$RC" = 200 ] || [ "$RC" = 204 ]; } && ok "token stocké (secret/stoa/ci/gitea-org-admin)" || ko "KV (HTTP $RC)"
unset GTOK

echo "3. attache à l'opérateur $ONBOARD_OPERATOR"
# Motif relevé dans setup-vault-userpass.sh (mkuser, §3) : le POST plein sur
# /auth/<mount>/users/<u> REMPLACE token_policies en entier — donc jamais utilisé
# ici pour une attache. Vault expose un endpoint DÉDIÉ, .../users/<u>/policies,
# qui met à jour SEULEMENT les policies (touche pas le mot de passe ni le TTL) —
# mais lui aussi REMPLACE la liste envoyée : l'additivité est donc à NOTRE charge,
# en lisant l'existant AVANT d'écrire l'union. Vérifié en direct contre ce Vault
# (2026-08-04) : GET puis POST .../policies avec la liste fusionnée laisse le mot
# de passe et le login de l'utilisateur intacts.
RC=$(vcurl -o "$TMP/operator.json" -w '%{http_code}' "$VAULT_ADDR/v1/auth/$MOUNT/users/$ONBOARD_OPERATOR")
[ "$RC" = 200 ] || ko "opérateur '$ONBOARD_OPERATOR' introuvable dans auth/$MOUNT (HTTP $RC) — provisionner l'opérateur d'abord (scripts/setup-vault-userpass.sh, LAB_OSCAR_PASS)"
EXISTING=$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["data"].get("token_policies") or []))' "$TMP/operator.json")
if printf '%s' ",$EXISTING," | grep -qF ",team-onboarder,"; then
  ok "opérateur '$ONBOARD_OPERATOR' porte déjà team-onboarder (policies: $EXISTING)"
else
  MERGED=$( [ -n "$EXISTING" ] && printf '%s,team-onboarder' "$EXISTING" || printf 'team-onboarder' )
  printf '{"policies":"%s"}' "$MERGED" > "$TMP/attach.json"
  RC=$(vcurl -X POST "$VAULT_ADDR/v1/auth/$MOUNT/users/$ONBOARD_OPERATOR/policies" --data-binary @"$TMP/attach.json" -o "$TMP/err" -w '%{http_code}')
  { [ "$RC" = 200 ] || [ "$RC" = 204 ]; } && ok "opérateur '$ONBOARD_OPERATOR' -> policies [$MERGED] (AJOUT, rien retiré)" || ko "attache (HTTP $RC): $(cat "$TMP/err")"
fi
rm -f "$TMP/operator.json"

echo
say(){ printf '\033[1;36m[team-onboard-prereqs]\033[0m %s\n' "$*"; }
say "Terminé. Périmètre team-onboarder ; opérateur=$ONBOARD_OPERATOR ; contre-épreuve : cf. rapport de la tâche 3 (mesures 200/403, objets nettoyés)."
