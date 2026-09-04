#!/usr/bin/env bash
# scripts/lib/repo-layout.sh — OÙ le livrable vit dans le dépôt de la forge.
#
# LE PROBLÈME (analyse de configuration, 2026-09-03).
# Le PoC vit dans un monorepo : tout le livrable est sous « poc-control-plane-federation/ ».
# Ce préfixe s'était écrit EN DUR à ~188 endroits, et trois conventions coexistaient
# pour la même idée : un knob `GIT_SUBDIR` (provision-apply-reconcile.sh), des
# chemins relatifs au worktree (provision-apply-gate.sh), et le préfixe littéral
# (provision-request.sh, generate-choices.sh). Chez un client qui range son dépôt
# autrement, les deux dernières formes n'ont aucune prise.
#
# LE CONTRAT, celui que provision-apply-reconcile.sh écrivait déjà :
#   GIT_SUBDIR    le préfixe du livrable DANS le dépôt de la forge (« vu de la racine »)
#   MANIFEST_DIR  et consorts : RELATIFS au livrable, jamais préfixés
#   SUB_PFX       le préfixe prêt à concaténer — vide, ou terminé par « / »
# Un chemin vu de la racine du clone se compose : "${SUB_PFX}${MANIFEST_DIR}/…"
#
# LA SENTINELLE, et pourquoi elle existe.
# « Le livrable EST la racine » se dit avec un point, pas avec une chaîne vide :
# Jenkins n'exporte pas au shell une variable de valeur vide, elle arrive ABSENTE
# du processus — et une variable absente reprend le défaut, donc le préfixe du lab.
# Une globale posée à « » ne dirait donc PAS ce que son auteur croit dire.
# Les deux formes sont acceptées ici (« . » pour le transport, « » pour un appel
# shell direct, ce que font les harnais), et rendent le même préfixe vide.
#
# Le tiret est NU (`${GIT_SUBDIR-…}`) et non `:-` : sans cela, « » reprendrait
# le défaut et la sentinelle vide des harnais serait ignorée en silence.
#
# USAGE
#   . "$(dirname "$0")/lib/repo-layout.sh"   # ou lib/ selon l'appelant
#   repo_layout_init                          # pose GIT_SUBDIR et SUB_PFX
#   chemin_forge="${SUB_PFX}${MANIFEST_DIR}/${app}.ansible.yml"

REPO_LAYOUT_DEFAUT="${REPO_LAYOUT_DEFAUT:-poc-control-plane-federation}"

# repo_layout_init — normalise GIT_SUBDIR et pose SUB_PFX. Idempotent.
repo_layout_init() {
  GIT_SUBDIR="${GIT_SUBDIR-$REPO_LAYOUT_DEFAUT}"
  case "$GIT_SUBDIR" in
    .|./|'') SUB_PFX='' ;;
    /*)      SUB_PFX=''; echo "REFUS: GIT_SUBDIR_ABSOLU : '$GIT_SUBDIR' — le prefixe est RELATIF a la racine du depot" >&2; return 2 ;;
    *)       SUB_PFX="${GIT_SUBDIR%/}/" ;;
  esac
  export GIT_SUBDIR SUB_PFX
}

# repo_layout_path <chemin relatif au livrable> → chemin vu de la racine du dépôt
repo_layout_path() {
  [ -n "${SUB_PFX+x}" ] || repo_layout_init || return 2
  printf '%s%s' "$SUB_PFX" "${1#/}"
}
