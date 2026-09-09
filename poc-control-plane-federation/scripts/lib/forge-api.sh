#!/usr/bin/env bash
# scripts/lib/forge-api.sh — l'enveloppe shell des verbes de forge (forge-api.py).
#
# À SOURCER. Une seule autorité sur « comment parler à la forge » : le visage
# (FORGE_KIND=gitea|gitlab), la base d'API, l'en-tête d'auth et la garde de
# réponse vivent dans scripts/lib/forge-api.py — ce fichier ne fait que le
# trouver, lui passer le secret SANS argv, et rendre ses lignes CLÉ=VALEUR.
#
#   . scripts/lib/forge-api.sh
#   forge_api_init                       # pose FORGE_KIND (défaut gitea), vérifie GIT_HOST/GIT_REPO
#   eval "$(forge pr_find_open "$BRANCH")"   # NUMBER= LOGIN= URL=   (rc 0)
#   forge pr_list_merged "$BRANCH"       # UNE ligne par PR mergée de cette tête : NUMBER= MERGE_SHA= BASE_REF= SAME_REPO= HEAD_REPO=
#   forge pr_get 42                     # STATE= HEAD_REF= HEAD_SHA= BASE_REF= SAME_REPO= MERGED= MERGE_SHA= MERGED_BY= LOGIN= URL=
#   forge pr_open <head> <base> <titre> <fichier-corps>    # NUMBER= URL=
#   forge pr_files 42                    # un chemin par ligne
#   forge comment_find 42 "<marqueur>"   # ID= (vide si aucun commentaire ne porte le marqueur ; rc 0, lecture seule)
#   forge comment_upsert 42 "<marqueur>" <fichier>          # ID= ACTION=created|updated
#   forge raw <chemin> [ref]             # le contenu, brut, sur stdout
#   forge probe                          # KIND_DETECTED=gitea|gitlab|inconnu (sans secret)
#
# rc 0 = produit sur stdout · rc 2 = CAUSE en une ligne sur stderr, rien sur
# stdout. L'APPELANT nomme le tag (`|| fail "FORGE_ILLISIBLE : … (cause ci-dessus)"`) :
# les contrats de refus existants ne bougent pas.
#
# ⚠ `forge_kv` : la lecture d'une sortie CLÉ=VALEUR dans des variables shell,
# SANS eval sur du texte venu du réseau — la valeur est prise après le premier
# « = », telle quelle. Utiliser ceci plutôt qu'un `eval "$(forge …)"` quand la
# valeur peut porter n'importe quoi (un titre de PR, une URL).

# Localisation de forge-api.py : à côté de ce fichier, en chemin ABSOLU — la
# chaîne fait `cd` dans un clone après avoir sourcé la lib (provision-request),
# et un chemin relatif y devenait « python3: can't open file ». Repli : la racine.
_FORGE_API_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/forge-api.py"
[ -f "$_FORGE_API_PY" ] || _FORGE_API_PY="$PWD/scripts/lib/forge-api.py"

# forge_api_init — vérifie le minimum AVANT le premier appel réseau et pose les
# défauts qui dépendent du visage (l'en-tête d'auth par défaut de GitLab est
# PRIVATE-TOKEN, celui de Gitea « Authorization: token »).
forge_api_init() {
  FORGE_KIND="${FORGE_KIND:-gitea}"
  case "$FORGE_KIND" in
    gitea|gitlab) ;;
    *) echo "REFUS: FORGE_KIND_INCONNU : '$FORGE_KIND' — attendu gitea ou gitlab" >&2; return 2 ;;
  esac
  [ -n "${GIT_HOST:-}" ] || { echo "REFUS: GIT_HOST_REQUIS : base de la forge (ex. https://forge.client) — aucun repli" >&2; return 2; }
  [ -n "${GIT_REPO:-}" ] || { echo "REFUS: GIT_REPO_REQUIS : owner/repo du dépôt sur la forge" >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || { echo "REFUS: PYTHON3_REQUIS : forge-api.py ne peut pas tourner" >&2; return 2; }
  [ -f "$_FORGE_API_PY" ] || { echo "ERREUR: $_FORGE_API_PY introuvable" >&2; return 1; }
  if [ -z "${FORGE_API_AUTH:-}" ]; then
    case "$FORGE_KIND" in gitlab) FORGE_API_AUTH=private-token ;; *) FORGE_API_AUTH=token ;; esac
  fi
  export FORGE_KIND FORGE_API_AUTH
}

# forge <verbe> [args…] — le secret ne passe NI par argv (`ps` le verrait), NI
# par un préfixe `FORGE_SECRET=… python3` (tracé sous `set -x`, mesuré) : il
# part par un here-doc sur le descripteur 3, dont le contenu n'est jamais tracé
# (FORGE_SECRET_FILE, quand il est posé, garde la priorité côté python). Les
# knobs non secrets sont passés EXPLICITEMENT : l'appelant n'a pas à les
# exporter (provision-plan.sh les pose sans export).
forge() {
  GIT_HOST="${GIT_HOST:-}" GIT_REPO="${GIT_REPO:-}" FORGE_KIND="${FORGE_KIND:-}" \
  FORGE_API_AUTH="${FORGE_API_AUTH:-}" FORGE_API_BASE="${FORGE_API_BASE:-}" FORGE_USER="${FORGE_USER:-}" \
  python3 "$_FORGE_API_PY" "$@" 3<<_FORGE_EOF
S=${FORGE_SECRET:-${GITEA_TOKEN:-}}
_FORGE_EOF
}

# forge_kv <préfixe> <verbe> [args…] — joue le verbe et pose <préfixe>_<CLÉ>
# pour chaque ligne CLÉ=VALEUR. rc = celui du verbe. Sans eval sur la valeur.
forge_kv() {
  local pfx="$1" out line k v rc; shift
  out="$(forge "$@")"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  while IFS= read -r line; do
    case "$line" in
      *=*) k="${line%%=*}"; v="${line#*=}"
           case "$k" in *[!A-Z0-9_]*|'') continue ;; esac
           printf -v "${pfx}_${k}" '%s' "$v" ;;
    esac
  done <<< "$out"
}
