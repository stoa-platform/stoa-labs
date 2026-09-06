#!/usr/bin/env bash
# scripts/lib/branch-ref.sh — LE découpage d'une référence de branche
# `<prefixe>/<app>-<palier>`, dérivé d'UN endroit.
#
# POURQUOI CE FICHIER EXISTE : au 2026-09-06, le même découpage était écrit à
# SEPT endroits, en deux langages, avec QUATRE comportements différents sur les
# mêmes entrées — trois Groovy sans aucune validation, provision-plan.sh avec un
# BLANCHIMENT SILENCIEUX, provision-apply-reconcile.sh avec les classes qui font
# foi, team-apply.sh avec un préfixe différent et aucune classe.
#
# Le défaut réel n'était pas la duplication, c'était le blanchiment :
#   ENVV="${PR_BRANCH##*-}"; case " $CHAIN " in *" $ENVV "*) ;; *) ENVV="";; esac
# suivi, en aval, de `${ENVV:+-e apim_ss_env="$ENVV"}`. Un palier hors chaîne
# faisait DISPARAÎTRE l'extra-var : le PLAN présenté au demandeur portait sur le
# palier par défaut du rôle, pas sur celui que sa branche nomme. Aucun refus,
# aucun signal — un plan qui répond à une autre question que celle posée.
#
# Le contrat est tenu par une table exécutée à chaque `go test` :
# labctl/internal/governance/branchref_mirror_test.go (régime dégradé assumé :
# il n'existe aucune implémentation Go, c'est un test de contrat à un moteur).
#
# Usage :
#   . scripts/lib/branch-ref.sh
#   if out=$(branch_split "$PR_BRANCH" "provision/"); then
#     read -r APP_NAME ENV_NAME <<<"$out"
#   else case $? in 1) … ;; 2) … ;; esac
#   fi

# branch_split <ref> <prefixe> — découpe au DERNIER tiret.
#
#   rc=0  stdout « <app> <palier> »
#   rc=1  la référence ne commence pas par <prefixe>
#   rc=2  pas de suffixe -<palier>
#   rc=3  nom d'application hors de ^[a-z0-9][a-z0-9-]*$
#   rc=4  palier hors de ^[a-z0-9]+$
#
# L'APPARTENANCE À LA CHAÎNE n'est PAS l'affaire de cette fonction : `zeta` est
# une forme valide. C'est à l'appelant de refuser un palier hors chaîne — par un
# refus NOMMÉ, jamais en blanchissant la variable.
#
# Le découpage se fait au DERNIER tiret (`##*-`, `%-*`) et non au premier :
# `credit-scoring-rec` ⇒ app `credit-scoring`, palier `rec`. Le mutant qui
# substitue `#*-` à `##*-` doit faire rougir la table (contre-épreuve incluse).
branch_split() {
  local ref="${1:-}" prefix="${2:-}" rest app env
  case "$ref" in
    "$prefix"*) rest="${ref#"$prefix"}" ;;
    *) return 1 ;;
  esac
  case "$rest" in
    *-*) env="${rest##*-}"; app="${rest%-*}" ;;
    *) return 2 ;;
  esac
  printf '%s' "$app" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || return 3
  printf '%s' "$env" | grep -Eq '^[a-z0-9]+$' || return 4
  printf '%s %s' "$app" "$env"
}
