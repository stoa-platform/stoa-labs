#!/usr/bin/env bash
# setup-vault-paliers.sh — G4 (ADR-082) : le plan de credential PAR PALIER.
#
# « Ouvrir un palier » n'est PAS un edit de code : c'est un geste Vault de
# l'exploitant (mint d'un secret_id, grant d'une policy à un humain). Ce
# script pose le MÉCANISME, fermé par défaut :
#   - une policy apply-<env> par palier NON terminal (read du seul secret
#     d'admin du palier : envs/<env>/wm-admin) — dérivée d'env_chain_nonprod,
#     JAMAIS de nom de palier en dur, le terminus est exclu par STRUCTURE
#     (le dernier de la chaîne, pas « prod ») ;
#   - un AppRole apply-<env> lié 1:1 à sa policy — AUCUN secret_id minté ici :
#     le mint est le geste d'ouverture, séparé, explicite ;
#   - le mapping LDAP apim-apply-<env> → apply-<env> (inerte tant que le
#     groupe n'existe pas dans l'annuaire — le grant humain reste un geste).
#
# DISSYMÉTRIE NOMMÉE : stoa-proxy-provision (setup-vault-approle.sh) garde
# son wildcard envs/+/wm-admin — c'est l'outillage OPÉRATEUR de pose des
# proxies ADR-075, pas une identité de pipeline. Clause de réouverture : le
# jour où la pose de proxy devient déclenchable par un tiers, elle suit la
# discipline par palier posée ici.
#
#   bash scripts/setup-vault-paliers.sh            # pose (exige VAULT_TOKEN)
#   bash scripts/setup-vault-paliers.sh --print    # émet SANS réseau (preuve)
#   bash scripts/setup-vault-paliers.sh --mint apply-rec   # geste d'OUVERTURE
set -euo pipefail
# Pas de cd(dirname "$0")/.. ici : ce script n'a besoin d'aucun fichier hors
# cette lib, et la porte (test-palier-retention.sh, épreuves ③bis/⑤) exécute
# des COPIES mutées de ce fichier depuis un répertoire temporaire — un cd
# basé sur $0 y résoudrait un mauvais répertoire racine. On source donc
# relativement au cwd d'invocation, qui est TOUJOURS la racine du dépôt
# poc-control-plane-federation (convention de tous les appels documentés
# ci-dessus : `bash scripts/setup-vault-paliers.sh`).
# shellcheck source=scripts/lib/env-chain.sh
. "scripts/lib/env-chain.sh"

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
TOKEN_TTL="${TOKEN_TTL:-3m}"
SECRET_ID_TTL="${SECRET_ID_TTL:-10m}"
SECRET_ID_USES="${SECRET_ID_USES:-0}"

ENVS_NONPROD="$(env_chain_nonprod)" || { echo "CHAINE_ILLISIBLE : env_chain_nonprod a échoué" >&2; exit 1; }
[ -n "$ENVS_NONPROD" ] || { echo "CHAINE_VIDE : aucun palier non terminal" >&2; exit 1; }

policy_hcl() { # <env> — le périmètre est le SECRET D'ADMIN DU PALIER, rien d'autre
  # Interpolation directe de $1 (pas de printf %s) : la contre-épreuve ③bis de
  # la porte mute le littéral envs/$1/ en envs/+/ — la forme est un contrat.
  printf '%s\n' \
    "path \"secret/data/stoa/envs/$1/wm-admin\" { capabilities = [\"read\"] }" \
    "path \"secret/metadata/stoa/envs/$1/wm-admin\" { capabilities = [\"read\"] }"
}

MODE="${1:-pose}"
case "$MODE" in
  --print)
    for e in $ENVS_NONPROD; do
      printf '# ── policy apply-%s ──\n' "$e"
      policy_hcl "$e"
      printf '# ── approle apply-%s (token_policies=apply-%s, token_ttl=%s) ──\n' "$e" "$e" "$TOKEN_TTL"
      printf '# ── mapping ldap apim-apply-%s -> apply-%s (inerte sans groupe) ──\n' "$e" "$e"
    done
    echo "# Geste d'OUVERTURE d'un palier (exploitant, hors pipeline) :"
    for e in $ENVS_NONPROD; do
      printf '#   %s --mint apply-%s\n' "$0" "$e"
    done
    exit 0 ;;
  --mint)
    ROLE="${2:?usage: --mint apply-<env>}"
    KNOWN=0
    for e in $ENVS_NONPROD; do [ "$ROLE" = "apply-$e" ] && KNOWN=1; done
    [ "$KNOWN" -eq 1 ] || { echo "MINT_ROLE_INCONNU : '$ROLE' hors du set dérivé (apply-{$(echo "$ENVS_NONPROD" | tr ' ' ',')})" >&2; exit 1; }
    VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis pour --mint}"
    CURL=(/usr/bin/curl -s -H "X-Vault-Token: $VAULT_TOKEN")
    RID="$("${CURL[@]}" "$VAULT_ADDR/v1/auth/approle/role/$ROLE/role-id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["role_id"])')"
    SID="$("${CURL[@]}" -X POST "$VAULT_ADDR/v1/auth/approle/role/$ROLE/secret-id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["secret_id"])')"
    printf '%s\t%s\n' "$RID" "$SID"
    exit 0 ;;
  pose) : ;;
  *) echo "usage: $0 [--print | --mint apply-<env>]" >&2; exit 2 ;;
esac

VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis pour poser (voir .env.example)}"
CURL=(/usr/bin/curl -s -H "X-Vault-Token: $VAULT_TOKEN")

echo "Vault $VAULT_ADDR — plan de credential par palier ($ENVS_NONPROD)"
"${CURL[@]}" -X POST "$VAULT_ADDR/v1/sys/auth/approle" -H 'Content-Type: application/json' \
  -d '{"type":"approle"}' -o /dev/null -w "  enable approle -> HTTP %{http_code} (204 ok / 400 déjà actif)\n" || true

for e in $ENVS_NONPROD; do
  HCL="$(policy_hcl "$e")"
  "${CURL[@]}" -X PUT "$VAULT_ADDR/v1/sys/policies/acl/apply-$e" \
    -H 'Content-Type: application/json' \
    -d "{\"policy\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$HCL")}" \
    -o /dev/null -w "  policy apply-$e -> HTTP %{http_code}\n"
  "${CURL[@]}" -X POST "$VAULT_ADDR/v1/auth/approle/role/apply-$e" -H 'Content-Type: application/json' \
    -d "{\"token_policies\":\"apply-$e\",\"token_ttl\":\"$TOKEN_TTL\",\"token_max_ttl\":\"$TOKEN_TTL\",\"secret_id_ttl\":\"$SECRET_ID_TTL\",\"secret_id_num_uses\":$SECRET_ID_USES}" \
    -o /dev/null -w "  approle apply-$e -> HTTP %{http_code}\n"
  # Mapping de GRANT humain — inerte tant que le groupe LDAP n'existe pas.
  # Tolérance NOMMÉE : sans mount ldap (lab partiel), on le dit, on ne casse pas.
  LC="$("${CURL[@]}" -X PUT "$VAULT_ADDR/v1/auth/ldap/groups/apim-apply-$e" \
    -H 'Content-Type: application/json' -d "{\"policies\":\"apply-$e\"}" \
    -o /dev/null -w '%{http_code}')"
  case "$LC" in 2*) echo "  ldap apim-apply-$e -> apply-$e (HTTP $LC)";;
                 *) echo "  ldap apim-apply-$e NON posé (HTTP $LC — mount ldap absent ? grant humain à poser autrement)";; esac
done

echo "done. RIEN n'est accordé : l'état sorti de ce script est « tout fermé »."
echo "Ouvrir un palier = "
for e in $ENVS_NONPROD; do echo "    $0 --mint apply-$e"; done
