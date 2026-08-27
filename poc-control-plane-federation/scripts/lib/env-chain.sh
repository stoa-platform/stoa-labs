#!/usr/bin/env bash
# scripts/lib/env-chain.sh — LA chaîne d'environnements, dérivée d'UNE source.
#
# POURQUOI CE FICHIER EXISTE : au 2026-08-26, la chaîne était écrite en dur
# dans SIX endroits (setup-wm-admin-proxy.sh, setup-ci-horsprod.sh,
# setup-vault-envs.sh, docker-compose.envs.yml, ci/Jenkinsfile,
# ci/Jenkinsfile.selfservice). Ajouter un palier — `homol` — voulait dire
# éditer six listes et espérer n'en oublier aucune. C'est exactement le
# problème que `environments.yaml` est censé supprimer : on ne l'ajoute pas
# une septième fois, on le DÉRIVE.
#
# SOURCE, par ordre de préséance :
#   1. $STOA_ENV_CHAIN_FILE  — chemin explicite (le dépôt governance cloné,
#                              typiquement, quand l'appelant en a un)
#   2. clients/_example/environments.yaml — le gabarit livrable, toujours
#                              présent dans le dépôt plateforme
#
# FAIL-CLOSED : source absente ou illisible ⇒ ERREUR, jamais un repli
# silencieux sur une liste devinée. Une chaîne fausse ne se voit pas — elle
# produit des paliers qui « n'existent pas » trois couches plus loin.
#
# Usage :
#   . scripts/lib/env-chain.sh
#   read -r -a ENVS <<< "$(env_chain)"            # dev rec int homol prod
#   read -r -a ENVS <<< "$(env_chain_nonprod)"    # idem SANS le dernier palier
#
# `env_chain_nonprod` retire le DERNIER palier de la chaîne, pas « prod » par
# son nom : la barrière hors-prod est structurelle (le terminus n'est jamais
# servi par le pipeline hors-prod), elle ne dépend pas d'un nom d'environnement
# qu'un client pourrait appeler autrement.

# Racine du dépôt, résolue À L'INSTANT DU SOURCE et mémorisée.
#
# ⚠ PIÈGE MESURÉ (2026-08-26) : ne PAS résoudre ceci à l'appel. `BASH_SOURCE`
# porte le chemin TEL QU'IL A ÉTÉ ÉCRIT par l'appelant — souvent relatif
# (`. scripts/lib/env-chain.sh`). Or tous les scripts de ce dépôt font un `cd`
# après le source (`cd "$(dirname "$0")/.."`) : résolu plus tard, le chemin
# relatif pointe alors ailleurs, et la fonction renvoie une chaîne VIDE au lieu
# d'échouer. Un `cd` innocent suffisait à vider la chaîne d'environnements.
_STOA_ENV_CHAIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_env_chain_file() {
  if [ -n "${STOA_ENV_CHAIN_FILE:-}" ]; then
    printf %s "$STOA_ENV_CHAIN_FILE"; return
  fi
  printf %s "$_STOA_ENV_CHAIN_ROOT/clients/_example/environments.yaml"
}

env_chain() {
  local f; f="$(_env_chain_file)"
  [ -r "$f" ] || { echo "env-chain: source illisible : $f" >&2; return 1; }
  python3 - "$f" <<'PY' || return 1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
envs = d.get("environments") or []
if not envs:
    sys.exit("env-chain: 'environments' vide ou absent de %s" % sys.argv[1])
print(" ".join(envs))
PY
}

env_chain_nonprod() {
  local all; all="$(env_chain)" || return 1
  # shellcheck disable=SC2206
  local a=($all)
  [ "${#a[@]}" -ge 2 ] || { echo "env-chain: chaîne trop courte pour un hors-prod" >&2; return 1; }
  printf '%s' "${a[*]:0:${#a[@]}-1}"
}

# Le groupe d'approbation d'un palier, tel que la porte le déclare — utile aux
# scripts qui doivent poser ce groupe dans l'IdP plutôt que le redeviner.
env_chain_approver_group() {
  local f; f="$(_env_chain_file)"
  # Même garde que env_chain : pas de traceback Python en guise de message
  # d'erreur, et surtout pas de chaîne vide passée pour un « pas de groupe ».
  [ -r "$f" ] || { echo "env-chain: source illisible : $f" >&2; return 1; }
  python3 - "$f" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(next((g.get("approverGroup", "") for g in (d.get("gates") or [])
            if g.get("to") == sys.argv[2]), ""))
PY
}

# Ce que la porte d'un palier EXIGE, en une lecture — prolongement de
# env_chain_approver_group, qui ne disait que QUI approuve. Rend :
#   GATE=<changeRef 0|1>|<pvRef 0|1>|<approverGroup>
#
# `itsmCheck` IMPLIQUE une référence de changement : il n'y a rien à
# re-vérifier auprès de l'ITSM sans elle (même règle que
# governance-api, handlers_promotions.go:77-89 — la porte est lue au même
# endroit des deux côtés, sinon les deux divergent en silence).
# La porte d'arrivée exige-t-elle les quatre yeux ? Rend FOUREYES=0|1.
#
# FONCTION SŒUR, PAS UN CHAMP DE PLUS. `env_chain_gate` rend trois champs
# POSITIONNELS que ses appelants redécoupent à la main (api-promote-request.sh,
# team-promote.sh) : y ajouter un quatrième ferait lire `fourEyes` là où ils
# lisent aujourd'hui `approverGroup`, sans qu'aucun refus ne se déclenche — une
# porte relâchée en silence. On ajoute donc une lecture séparée.
env_chain_gate_four_eyes() {
  local f; f="$(_env_chain_file)"
  [ -r "$f" ] || { echo "env-chain: source illisible : $f" >&2; return 1; }
  python3 - "$f" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
g = next((x for x in (d.get("gates") or []) if x.get("to") == sys.argv[2]), {}) or {}
print("FOUREYES=%s" % ("1" if g.get("fourEyes") else "0"))
PY
}

env_chain_gate() {
  local f; f="$(_env_chain_file)"
  [ -r "$f" ] || { echo "env-chain: source illisible : $f" >&2; return 1; }
  python3 - "$f" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
g = next((x for x in (d.get("gates") or []) if x.get("to") == sys.argv[2]), {}) or {}
print("GATE=%s|%s|%s" % (
    "1" if (g.get("requireChangeRef") or g.get("itsmCheck")) else "0",
    "1" if g.get("requirePVRef") else "0",
    g.get("approverGroup") or ""))
PY
}
