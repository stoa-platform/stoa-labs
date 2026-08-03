#!/bin/sh
# assert-merge-identity.sh — la personne qui répond à la demande en attente
# est-elle bien celle qui a validé la PR, et n'est-elle pas le demandeur ?
#
# POURQUOI CETTE GARDE EXISTE. Un webhook ne porte AUCUNE authentification :
# `merged_by.login` dans la charge utile Gitea est une AFFIRMATION, pas un
# credential. On ne dérive pas un token Vault d'un nom dans un JSON. C'est
# pourquoi la chaîne met le build en pause et demande une identité — le login
# Vault, lui, est authentifié.
#
# Mais la pause, seule, ne prouve rien : n'importe qui ayant le droit `input`
# sur Jenkins peut y répondre. Cette garde relie les deux — l'identité PROUVÉE
# (le login Vault, validé par le login Vault lui-même) et l'identité AFFIRMÉE
# (qui a mergé) — et refuse si elles divergent.
#
# CE QU'ELLE NE FAIT PAS : authentifier. Elle compare. C'est le login Vault qui
# authentifie, en amont. Si ce login échoue, on n'arrive jamais ici.
#
# Usage :
#   assert-merge-identity.sh --merged-by <login> --requester <login> \
#                            --vault-user <login> [--map <fichier>]
#
#   --map : correspondances « loginGitea:loginAnnuaire », une par ligne, quand
#           les deux annuaires ne portent pas les mêmes identifiants. Les lignes
#           vides et celles commençant par # sont ignorées.
#
# Codes d'échec (stables, greppables dans un log de build) :
#   MERGER_UNKNOWN        : merged_by absent — le webhook ne l'a pas fourni
#   MERGER_MISMATCH       : le répondant n'est pas celui qui a mergé
#   FOUR_EYES_VIOLATION   : le valideur est le demandeur
set -eu

MERGED_BY=""; REQUESTER=""; VAULT_USER=""; MAPFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --merged-by)  MERGED_BY="${2:-}"; shift 2 ;;
    --requester)  REQUESTER="${2:-}"; shift 2 ;;
    --vault-user) VAULT_USER="${2:-}"; shift 2 ;;
    --map)        MAPFILE="${2:-}"; shift 2 ;;
    *) echo "argument inconnu : $1" >&2; exit 2 ;;
  esac
done

# NORMALISATION. La voie A accepte trois écritures du même humain —
# sAMAccountName (`alice`), UPN (`alice@banque.fr`) et DOMAIN\user
# (`BANQUE\alice`) — alors que Gitea n'en connaît qu'une. Comparer les chaînes
# brutes ferait échouer la garde sur une simple différence de forme, et l'ops
# finirait par la désactiver. On réduit donc au nom de compte, en minuscules.
norm() {
  printf '%s' "${1:-}" \
    | tr -d '[:space:]' \
    | sed 's/^.*\\//; s/@.*$//' \
    | tr '[:upper:]' '[:lower:]'
}

# Correspondance explicite (optionnelle), appliquée AVANT la normalisation :
# c'est le login Gitea BRUT qui sert de clé.
map_login() {
  _raw="${1:-}"
  if [ -n "$MAPFILE" ] && [ -f "$MAPFILE" ]; then
    _hit=$(grep -v '^[[:space:]]*#' "$MAPFILE" 2>/dev/null \
           | grep -v '^[[:space:]]*$' \
           | awk -F: -v k="$_raw" '$1==k {print $2; exit}')
    [ -n "$_hit" ] && { printf '%s' "$_hit"; return; }
  fi
  printf '%s' "$_raw"
}

# ── FAIL-CLOSED n°1 : sans merged_by, il n'y a rien à comparer ───────────────
# C'est LE piège de cette garde. Si le webhook n'expose pas le champ (il n'est
# pas capté par défaut dans genericVariables), une comparaison naïve
# « $A = $B » avec deux chaînes vides serait VRAIE et la garde passerait au
# vert sans rien vérifier. On refuse d'abord.
if [ -z "$(norm "$MERGED_BY")" ]; then
  echo "MERGER_UNKNOWN : le webhook n'a pas fourni pull_request.merged_by.login." >&2
  echo "  La garde ne peut RIEN vérifier — refus. Ajouter le champ aux" >&2
  echo "  genericVariables du trigger (\$.pull_request.merged_by.login)." >&2
  exit 1
fi
if [ -z "$(norm "$VAULT_USER")" ]; then
  echo "MERGER_UNKNOWN : aucune identité authentifiée fournie (--vault-user vide)." >&2
  exit 1
fi

N_MERGER=$(norm "$(map_login "$MERGED_BY")")
N_USER=$(norm "$VAULT_USER")
N_REQ=$(norm "$(map_login "$REQUESTER")")

# ── FAIL-CLOSED n°2 : le répondant EST le valideur ──────────────────────────
if [ "$N_MERGER" != "$N_USER" ]; then
  echo "MERGER_MISMATCH : la PR a été validée par '$MERGED_BY' mais l'identité" >&2
  echo "  fournie à la demande en attente est '$VAULT_USER'. Le secret serait" >&2
  echo "  écrit sous une identité qui n'a pas validé — refus." >&2
  exit 1
fi

# ── FAIL-CLOSED n°3 : quatre yeux ───────────────────────────────────────────
# Défense en profondeur : la règle se pose D'ABORD dans la protection de branche
# Gitea. Une garde de pipeline seule se contourne en déclenchant le job
# directement — elle complète le contrôle amont, elle ne le remplace pas.
if [ -n "$N_REQ" ] && [ "$N_REQ" = "$N_MERGER" ]; then
  echo "FOUR_EYES_VIOLATION : '$MERGED_BY' a validé sa propre demande" >&2
  echo "  (demandeur '$REQUESTER'). À imposer aussi dans la protection de" >&2
  echo "  branche Gitea : une garde de pipeline se contourne." >&2
  exit 1
fi

echo "MERGE_IDENTITY_OK : '$VAULT_USER' a bien validé la PR${REQUESTER:+ (demandeur : $REQUESTER)}."
