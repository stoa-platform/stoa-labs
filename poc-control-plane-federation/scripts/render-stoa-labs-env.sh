#!/usr/bin/env bash
# Dérive .stoa-labs.env (forme `export`, sourçable de n'importe où) depuis
# poc-control-plane-federation/.env. Aucune valeur n'est écrite sur stdout :
# tout va dans le fichier de sortie, permissions 600.
set -euo pipefail

# Chemins déduits de l'emplacement du script (dépôt PUBLIC : aucun chemin de
# poste en dur). scripts/ -> poc-control-plane-federation/ -> racine du dépôt.
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
POC=$(dirname -- "$HERE")
REPO=$(dirname -- "$POC")
SRC="$POC/.env"
DST="$REPO/.stoa-labs.env"

[ -r "$SRC" ] || { echo "source illisible: $SRC" >&2; exit 1; }

umask 077
{
  cat <<'HEADER'
# .stoa-labs.env — environnement du labo, forme sourçable.
#
#   source ~/stoa-platform/stoa-labs/.stoa-labs.env
#
# À la différence de poc-control-plane-federation/.env (lu automatiquement par
# `docker compose` quand on est DANS ce répertoire, et sourçable seulement via
# `set -a && source .env && set +a`), ce fichier exporte lui-même : il se source
# depuis n'importe quel répertoire.
#
# GÉNÉRÉ — ne pas éditer à la main. La source de vérité reste
# poc-control-plane-federation/.env ; régénérer après l'avoir modifié.
# Gitignoré (dépôt PUBLIC) : il contient les mêmes secrets que sa source.
#
# ── CE FICHIER NE SUFFIT PAS À LANCER LA PILE ────────────────────────────────
# Vérifié le 2026-08-02 :
#   docker compose -f poc-control-plane-federation/docker-compose.poc.yml config
# échoue (code 15) sur « required variable OPENSEARCH_PASSWORD is missing a
# value » — AVEC ce fichier sourcé. Ce n'est pas un défaut de la conversion :
# le .env source lui-même ne contient que ses 24 variables (images, ports, 4
# secrets), alors que .env.example en déclare 7 autres, toutes absentes :
#
#   OPENSEARCH_PASSWORD  AUDIT_VIEWER_PASS  VIEWER_PASS  VAULT_TOKEN
#   CI_APPLIER_SECRET    CI_HORSPROD_SECRET  DEV_SECRET
#
# Elles ne sont volontairement PAS ajoutées ici à vide : `${VAR:?}` traite vide
# et absent pareil, donc les ajouter ne changerait rien au blocage — et une
# valeur d'exemple ferait démarrer la pile sur un secret du dépôt public, ce que
# .env.example interdit explicitement. Pour les fournir : les renseigner dans
# poc-control-plane-federation/.env, puis régénérer ce fichier.
#
# NB (mémoire du poste) : ~/.zshrc exporte un VAULT_ADDR qui pointe sur un Vault
# EXTERNE. Ce fichier ne définit pas VAULT_ADDR — il ne le corrige donc pas.
# Surcharge-le explicitement avant tout `vault` manuel contre le lab.
HEADER
  printf '\n'

  awk '
    /^[[:space:]]*#/  { print; next }
    /^[[:space:]]*$/  { print; next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      eq  = index($0, "=")
      key = substr($0, 1, eq - 1)
      val = substr($0, eq + 1)
      # dépouiller un quotage déjà présent dans la source
      if (val ~ /^".*"$/ || val ~ /^'"'"'.*'"'"'$/)
        val = substr(val, 2, length(val) - 2)
      # quotage fort : seule la quote simple doit être échappée
      gsub(/'"'"'/, "'"'"'\\'"'"''"'"'", val)
      print "export " key "='"'"'" val "'"'"'"
      next
    }
    { print "# [non converti, forme inattendue] " $0 }
  ' "$SRC"
} > "$DST"

chmod 600 "$DST"
