#!/usr/bin/env bash
# scripts/lib/forge-api.sh — l'enveloppe shell des verbes de forge (forge-api.py).
#
# À SOURCER. Une seule autorité sur « comment parler à la forge » : le visage
# (FORGE_KIND=gitea|gitlab), la base d'API, l'en-tête d'auth et la garde de
# réponse vivent dans scripts/lib/forge-api.py — ce fichier ne fait que le
# trouver, lui passer le secret SANS argv, et rendre ses lignes CLÉ=VALEUR.
#
#   . scripts/lib/forge-api.sh
#   forge_api_init                       # exige FORGE_KIND (gitea|gitlab) — REQUIS, aucun
#                                        # défaut ; puis vérifie GIT_HOST/GIT_REPO
#   eval "$(forge pr_find_open "$BRANCH")"   # NUMBER= LOGIN= URL=   (rc 0)
#   forge pr_list_merged "$BRANCH"       # UNE ligne par PR mergée de cette tête : NUMBER= MERGE_SHA= BASE_REF= SAME_REPO= HEAD_REPO=
#   forge pr_get 42                     # STATE= HEAD_REF= HEAD_SHA= BASE_REF= SAME_REPO= MERGED= MERGE_SHA= MERGED_BY= LOGIN= URL=
#   forge pr_open <head> <base> <titre> <fichier-corps>    # NUMBER= URL=
#   forge pr_files 42                    # un chemin par ligne
#   forge comment_find 42 "<marqueur>"   # ID= (vide si aucun commentaire ne porte le marqueur ; rc 0, lecture seule)
#   forge comment_upsert 42 "<marqueur>" <fichier>          # ID= ACTION=created|updated
#   forge raw <chemin> [ref]             # le contenu, brut, sur stdout (sans ref : la HEAD du projet — GitLab ≥ 13.12)
#   forge repo_get                       # EXISTS= EMPTY= DEFAULT_BRANCH= URL= (404 ⇒ EXISTS=0, rc 0)
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
_FORGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_FORGE_API_PY="$_FORGE_LIB_DIR/forge-api.py"
[ -f "$_FORGE_API_PY" ] || _FORGE_API_PY="$PWD/scripts/lib/forge-api.py"

# Le MODE DEBUG (STOA_DEBUG) : dbg_kv de ci/lib/dbg.sh est la seule voie de
# sortie côté shell — stderr seulement, rédigé, `$?` préservé. Même localisation
# que forge-api.py (à côté de ce fichier puis ../../ci/lib, repli la racine) ;
# absent ⇒ ERREUR nommée, même régime que les autres libs manquantes — jamais
# un `forge` qui marcherait sans pouvoir se dire. Sourcer dbg.sh n'a aucun
# effet de bord (des fonctions et deux variables) : la suite vérifie que les
# sections L et N (argv, set -x) restent vertes.
_FORGE_DBG_SH="$_FORGE_LIB_DIR/../../ci/lib/dbg.sh"
[ -f "$_FORGE_DBG_SH" ] || _FORGE_DBG_SH="$PWD/ci/lib/dbg.sh"
if [ -f "$_FORGE_DBG_SH" ]; then
  # shellcheck source=ci/lib/dbg.sh
  . "$_FORGE_DBG_SH"
else
  echo "ERREUR: ci/lib/dbg.sh introuvable (cherché : $_FORGE_LIB_DIR/../../ci/lib/dbg.sh, $PWD/ci/lib/dbg.sh)" >&2
  return 1
fi

# forge_api_init — vérifie le minimum AVANT le premier appel réseau — le visage
# d'abord, sans défaut — et pose les défauts qui dépendent du visage (l'en-tête
# d'auth par défaut de GitLab est PRIVATE-TOKEN, celui de Gitea « Authorization:
# token »).
forge_api_init() {
  # Le visage n'a PAS de défaut. Un Jenkinsfile CLIENT qui ne le transmet pas
  # parlerait /api/v1 à un GitLab (incident 2026-09-10) — et cette copie-là,
  # aucune porte du dépôt ne la voit. Refus nommé, avant tout réseau ; l'ordre
  # est stable : visage, puis hôte, puis dépôt (décision du 2026-09-12).
  [ -n "${FORGE_KIND:-}" ] || { echo "REFUS: FORGE_KIND_REQUIS : visage de la forge (gitea|gitlab) — aucun défaut, le job doit le transmettre (environment{} du Jenkinsfile, globale Jenkins FORGE_KIND)" >&2; return 2; }
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
  # Le mode debug dit ce que l'init a DÉCIDÉ (stderr, rédigé ; dbg_kv rend le
  # rc reçu, celui de l'init ne bouge pas). FORGE_API_BASE vide se lit
  # « <vide> » : c'est le diagnostic « Jenkins a retiré la variable ».
  dbg_kv FORGE_KIND "$FORGE_KIND"
  dbg_kv FORGE_API_AUTH "$FORGE_API_AUTH"
  dbg_kv GIT_HOST "$GIT_HOST"
  dbg_kv GIT_REPO "$GIT_REPO"
  dbg_kv FORGE_API_BASE "${FORGE_API_BASE:-}"
}

# forge <verbe> [args…] — le secret ne passe NI par argv (`ps` le verrait), NI
# par un préfixe `FORGE_SECRET=… python3` (tracé sous `set -x`, mesuré) : il
# part par un here-doc sur le descripteur 3, dont le contenu n'est jamais tracé
# (FORGE_SECRET_FILE, quand il est posé, garde la priorité côté python). Les
# knobs non secrets sont passés EXPLICITEMENT : l'appelant n'a pas à les
# exporter (provision-plan.sh les pose sans export). STOA_DEBUG en fait partie :
# un script qui l'allume sans l'exporter (ni dbg_init) verrait le shell parler
# et python se taire — les deux autorités doivent répondre pareil (P.6).
forge() {
  GIT_HOST="${GIT_HOST:-}" GIT_REPO="${GIT_REPO:-}" FORGE_KIND="${FORGE_KIND:-}" \
  FORGE_API_AUTH="${FORGE_API_AUTH:-}" FORGE_API_BASE="${FORGE_API_BASE:-}" FORGE_USER="${FORGE_USER:-}" \
  STOA_DEBUG="${STOA_DEBUG:-}" \
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

# forge_web_url <url> — l'URL RENDUE PAR UN VERBE (URL= de pr_open/pr_get/repo_get),
# vue du poste : si GIT_WEB_HOST est posée et diffère de GIT_HOST, le préfixe
# GIT_HOST (vue conteneur, ex. http://gitea:3000) est remplacé par GIT_WEB_HOST.
# Une URL qui ne commence pas par GIT_HOST est rendue telle quelle. Les scripts
# ne composent plus jamais « /pulls/N » : la forme est celle du visage.
forge_web_url() {
  local u="$1" h="${GIT_HOST%/}" w="${GIT_WEB_HOST:-}"
  w="${w%/}"
  if [ -n "$w" ] && [ "$w" != "$h" ]; then
    case "$u" in "$h"/*) printf '%s\n' "${w}${u#"$h"}"; return 0 ;; esac
  fi
  printf '%s\n' "$u"
}

# forge_web_file_url <sha> <chemin> — le lien HUMAIN d'un fichier À UN COMMIT,
# selon le visage (gitea : src/commit ; gitlab : -/blob), base GIT_WEB_HOST sinon GIT_HOST.
forge_web_file_url() {
  local web="${GIT_WEB_HOST:-${GIT_HOST:-}}"
  web="${web%/}"
  case "${FORGE_KIND:-gitea}" in
    gitlab) printf '%s/%s/-/blob/%s/%s\n' "$web" "${GIT_REPO:-}" "$1" "$2" ;;
    *)      printf '%s/%s/src/commit/%s/%s\n' "$web" "${GIT_REPO:-}" "$1" "$2" ;;
  esac
}
