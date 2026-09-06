#!/usr/bin/env bash
# scripts/lib/posture-authority.sh — résout LE binaire qui porte l'autorité de
# posture (jalon P2, ADR-092), pour les HARNAIS de preuve. À SOURCER.
#
# POURQUOI CE FICHIER EXISTE. Depuis P2, scripts/api-request.sh refuse d'écrire
# quoi que ce soit sans pouvoir interroger `labctl posture` : la table de vérité
# exposition × classification vit dans ce binaire et n'est réécrite nulle part
# (P1). Sur un agent Jenkins, labctl est dans le PATH ; sur un poste de
# développement, rarement. Sans ce résolveur, chaque harnais tomberait sur
# POSTURE_AUTORITE_ABSENTE et le lecteur croirait à une régression du script
# testé, alors que c'est son POSTE qui manque d'un binaire.
#
#   resolve_posture_authority [dest]
#     pose LABCTL_BIN (exporté) et rend 0. Ordre :
#       1. $LABCTL_BIN déjà posé et exécutable  -> respecté tel quel
#       2. `go build` du dépôt (vendored, hors réseau) -> le binaire du CODE
#          COURANT, seul qui prouve quoi que ce soit sur une modification en
#          cours de revue
#       3. `labctl` du PATH -> repli honnête, ANNONCÉ (il peut être en retard
#          sur le dépôt : c'est précisément ce que le message dit)
#     rend 1 si aucune voie n'aboutit — au harnais de décider s'il saute la
#     section ou s'il rougit. On ne devine pas à sa place.
#
# Rien ici ne parle à un réseau, à Vault ou à une gateway.

resolve_posture_authority() {
  local dest="${1:-}" root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  if [ -n "${LABCTL_BIN:-}" ] && command -v "$LABCTL_BIN" >/dev/null 2>&1; then
    export LABCTL_BIN
    echo "posture-authority: LABCTL_BIN fourni ($LABCTL_BIN)" >&2
    return 0
  fi

  if command -v go >/dev/null 2>&1 && [ -d "$root/labctl" ]; then
    [ -n "$dest" ] || dest="$(mktemp -d)/labctl"
    mkdir -p "$(dirname "$dest")"
    if ( cd "$root/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$dest" . ) >/dev/null 2>&1; then
      LABCTL_BIN="$dest"; export LABCTL_BIN
      echo "posture-authority: labctl construit depuis le dépôt ($dest)" >&2
      return 0
    fi
    echo "posture-authority: ⚠ go build en échec — repli sur le PATH" >&2
  fi

  if command -v labctl >/dev/null 2>&1; then
    LABCTL_BIN="$(command -v labctl)"; export LABCTL_BIN
    echo "posture-authority: ⚠ labctl du PATH ($LABCTL_BIN) — PAS forcément le code de ce dépôt" >&2
    return 0
  fi

  echo "posture-authority: aucun labctl (ni LABCTL_BIN, ni go build, ni PATH)" >&2
  return 1
}
