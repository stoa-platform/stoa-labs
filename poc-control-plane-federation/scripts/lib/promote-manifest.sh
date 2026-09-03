#!/bin/sh
# promote-manifest.sh — rendu, épinglage et lecture du manifeste de promotion
# (spec 2026-08-28-promotion-sans-recopie). Bibliothèque PURE : aucune E/S
# réseau, uniquement des fichiers passés en argument — c'est ce qui la rend
# éprouvable hors ligne (test-promote-sans-recopie.sh) là où les scripts
# appelants exigent Gitea/Vault.
#
# ÉDITION CHIRURGICALE, PAS DE ROUND-TRIP YAML : un safe_dump réécrirait le
# fichier entier et détruirait les commentaires — or le manifeste est AUSSI un
# document d'authoring (backend_alias, per_env ajoutés à la main). On ne
# touche que les lignes qu'on possède (guid/archive_sha256/version/archive),
# posées par notre propre gabarit, à l'indentation connue (2 espaces).
#
# PORTABILITÉ sed : `-i.bak` (suffixe collé, sans espace) et la forme
# traditionnelle `a\` + saut de ligne + texte sont acceptées IDENTIQUEMENT par
# BSD sed (macOS, hôte de cette suite) et GNU sed 4.9 (CI Linux) — vérifié en
# direct sur les deux (conteneur debian:12-slim) : même indentation à 2
# espaces préservée des deux côtés. Pas de bascule python nécessaire ici.
#
# `local` (fix round 1, IMPORTANT 2) : cette lib est SOURCÉE par des scripts
# appelants — sans portée locale, ses variables tampon (_dir/_api/_m/_v/…)
# écrasent celles de l'appelant. `local` n'est pas POSIX strict (shellcheck
# SC3043) mais c'est une extension quasi universelle des sh réels — vérifié
# ici sous bash ET dash (le /bin/sh de fait sur Debian/Ubuntu, cible réelle de
# ce shebang) : comportement identique, aucune fuite de portée. Les seuls
# appelants actuels (api-promote-export.sh, api-promote-request.sh,
# team-promote.sh) sont `#!/usr/bin/env bash` de toute façon.
# shellcheck disable=SC3043

_pm_fail() { printf 'ERREUR: %s\n' "$*" >&2; return 1; }

# publish_manifest_version <team_dir> <api_name> — version portée par le
# publish.yml d'authoring (la vérité de ce qui est publié en dev).
publish_manifest_version() {
  local _pub _v
  _pub="$1/apis/$2.publish.yml"
  [ -f "$_pub" ] || { _pm_fail "PUBLISH_MANIFEST_ABSENT : $_pub — cette API n'est pas publiée en authoring"; return 1; }
  _v=$(python3 - "$_pub" <<'PY' 2>/dev/null
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
a = d.get("apim_api") or {}
n, v = a.get("name") or "", a.get("version") or ""
print(v if (n and v) else "")
PY
) || _v=""
  [ -n "$_v" ] || { _pm_fail "PUBLISH_MANIFEST_ILLISIBLE : $_pub — name/version inextractibles"; return 1; }
  printf '%s' "$_v"
}

# render_promote_manifest <team_dir> <api_name> <tmpl_path>
# Rend apis/<api>.promote.yml depuis le gabarit, name/version dérivés du
# publish.yml — même motif de substitution que api-request.sh:323-326.
render_promote_manifest() {
  local _dir _api _tmpl _ver
  _dir="$1"; _api="$2"; _tmpl="$3"
  _ver=$(publish_manifest_version "$_dir" "$_api") || return 1
  [ -f "$_tmpl" ] || { _pm_fail "GABARIT_ABSENT : $_tmpl"; return 1; }
  sed -e "s/__API_NAME__/${_api}/g" -e "s/__API_VERSION__/${_ver}/g" \
    "$_tmpl" > "$_dir/apis/$_api.promote.yml" \
    || { _pm_fail "RENDU_ECHEC : écriture de apis/$_api.promote.yml"; return 1; }
}

# manifest_pinned_digest <manifest_path> — le sha épinglé, '' si absent.
# Fichier absent = pas une erreur (le premier export n'a rien à lire) ;
# YAML illisible = erreur (un fichier corrompu ne doit pas passer pour vide).
manifest_pinned_digest() {
  [ -f "$1" ] || { printf ''; return 0; }
  python3 - "$1" <<'PY' 2>/dev/null || { _pm_fail "MANIFESTE_ILLISIBLE : $1"; return 1; }
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print((d.get("apim_promote") or {}).get("archive_sha256") or "")
PY
}

# pin_promote_manifest <manifest_path> <guid> <sha256> [version]
# sed chirurgical sur NOS lignes (gabarit : indentation 2 espaces). La ligne
# archive_sha256 est insérée après guid si le manifeste (antérieur au gabarit,
# ex. t10) ne la porte pas encore.
#
# RELECTURE FAIL-CLOSED, PAS SEULEMENT SUR LE SHA (fix round 1, IMPORTANT 1) :
# le sed de réalignement archive (`/${_api}-[0-9][0-9.]*\.archive\.zip`) ne
# matche QUE des versions purement numériques dans la ligne archive:
# EXISTANTE — une version pré-release déjà en place (ex. archive:
# .../demo-api-2.1.0-rc1.archive.zip) ou une ligne éditée à la main fait
# échouer le sed EN SILENCE (rc=0, zéro substitution) : version: change,
# archive: reste périmée, le manifeste devient incohérent sans qu'aucun signal
# ne sorte. On relit donc AUSSI version: et archive: après un pin versionné —
# même principe que la relecture du sha juste en dessous.
pin_promote_manifest() {
  local _m _g _s _v _api _lu _rv _ra
  _m="$1"; _g="$2"; _s="$3"; _v="${4:-}"
  [ -f "$_m" ] || { _pm_fail "MANIFESTE_ABSENT : $_m"; return 1; }
  sed -i.bak -e "s|^\(  guid:\).*|\1 \"${_g}\"|" "$_m"
  if grep -q '^  archive_sha256:' "$_m"; then
    sed -i.bak -e "s|^\(  archive_sha256:\).*|\1 \"${_s}\"|" "$_m"
  else
    sed -i.bak -e "/^  guid:/a\\
  archive_sha256: \"${_s}\"" "$_m"
  fi
  if [ -n "$_v" ]; then
    _api=$(python3 - "$_m" <<'PY'
import sys, yaml
print((yaml.safe_load(open(sys.argv[1])) or {}).get("apim_promote", {}).get("name", ""))
PY
)
    sed -i.bak -e "s|^\(  version:\).*|\1 \"${_v}\"|" \
      -e "s|/${_api}-[0-9][0-9.]*\.archive\.zip|/${_api}-${_v}.archive.zip|" "$_m"
  fi
  rm -f "$_m.bak"
  # relecture fail-closed : l'épinglage doit se RELIRE, pas se supposer
  _lu=$(manifest_pinned_digest "$_m") || return 1
  if [ "$_lu" != "$_s" ]; then
    _pm_fail "PIN_NON_RELU : écrit ${_s}, relu '${_lu}' — édition chirurgicale en échec"
    return 1
  fi
  if [ -n "$_v" ]; then
    _rv=$(python3 - "$_m" <<'PY'
import sys, yaml
print((yaml.safe_load(open(sys.argv[1])) or {}).get("apim_promote", {}).get("version", ""))
PY
) || { _pm_fail "REALIGNEMENT_NON_RELU : $_m illisible après le pin de version"; return 1; }
    if [ "$_rv" != "$_v" ]; then
      _pm_fail "REALIGNEMENT_NON_APPLIQUE : version relue '${_rv}', attendue '${_v}' — la ligne version: n'a pas été trouvée par sed"
      return 1
    fi
    _ra=$(python3 - "$_m" <<'PY'
import sys, yaml
print((yaml.safe_load(open(sys.argv[1])) or {}).get("apim_promote", {}).get("archive", ""))
PY
) || { _pm_fail "REALIGNEMENT_NON_RELU : $_m illisible après le pin de version"; return 1; }
    case "$_ra" in
      */"${_api}-${_v}.archive.zip") ;;
      *)
        _pm_fail "REALIGNEMENT_NON_APPLIQUE : archive relue '${_ra}' ne porte pas /${_api}-${_v}.archive.zip — forme inattendue (version pré-release déjà en place, ligne éditée à la main), le sed de réalignement n'a rien substitué"
        return 1
        ;;
    esac
  fi
  return 0
}
