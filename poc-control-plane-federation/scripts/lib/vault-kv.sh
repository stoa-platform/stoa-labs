#!/usr/bin/env bash
# scripts/lib/vault-kv.sh — LA composition du chemin KV v2, dérivée d'UN endroit.
#
# POURQUOI CE FICHIER EXISTE : au 2026-09-06, `<mount>/data/<prefix>/<sub>` était
# composé à QUATRE endroits, et deux d'entre eux étaient FAUX sur la
# configuration client mesurée (entrées à plat, aucun préfixe). Le rôle Ansible
# nomme le piège lui-même (apim_common/tasks/secrets.yml) :
#
#   « un chemin <prefix>/<sub> avec segment vide donnerait un slash final
#     (404 Vault) ou double (301). `select` élimine les segments vides. »
#
# Ansible élide, ce shell élide — le Go concaténait (`secret/data//envs/dev/x`).
# Le contrat est désormais tenu par une table exécutée à chaque `go test` :
# labctl/internal/vault/kvpath_mirror_test.go, qui lance CETTE fonction et
# vault.KVDataPath sur les mêmes entrées et exige le même chemin.
#
# Usage :
#   . scripts/lib/vault-kv.sh
#   TICKET_PATH="$(APIM_KV_MOUNT=secret APIM_KV_PREFIX=stoa kv_data_path envs/dev/wm-admin)"

# kv_data_path <sub> — rend "<mount>/data[/<prefix>]/<sub>".
# Lit APIM_KV_MOUNT et APIM_KV_PREFIX dans l'environnement (APIM_KV_PREFIX vide
# ⇒ entrées à plat, c'est une configuration LÉGITIME, pas une valeur manquante).
# Les slashs parasites de chaque segment sont élidés, jamais accumulés.
kv_data_path() {
  local mount="${APIM_KV_MOUNT:-secret}" prefix="${APIM_KV_PREFIX-}" sub="${1:-}" p
  _kv_trim() { local v="$1"; v="${v#"${v%%[!/]*}"}"; v="${v%"${v##*[!/]}"}"; printf '%s' "$v"; }
  mount="$(_kv_trim "$mount")"; prefix="$(_kv_trim "$prefix")"; sub="$(_kv_trim "$sub")"
  p="${mount}/data"
  [ -n "$prefix" ] && p="${p}/${prefix}"
  [ -n "$sub" ] && p="${p}/${sub}"
  printf '%s' "$p"
}
