#!/usr/bin/env bash
# scripts/lib/archive-store.sh — LE TRANSPORT DES OCTETS (jalon G5, ADR-079 C3 :
# l'archive est un artefact de build tagué — dépôt d'artefacts, PAS Git).
# Registre = packages GÉNÉRIQUES Gitea, ADRESSÉ PAR LE CONTENU : la version du
# package EST le sha256 de l'archive sanitizée. Conséquences voulues :
#   - l'URL de fetch se dérive du marqueur G3 (archive_sha256) sans champ nouveau ;
#   - pousser deux fois les mêmes octets est un no-op nommé, pas un doublon ;
#   - un même chemin portant d'AUTRES octets est un incident nommé, jamais écrasé.
# FAIL-CLOSED partout ; token via header-file, jamais argv/URL.
# `A && B || C` (SC2015) est l'idiome des scripts de preuve du repo pour
# chaîner deux gardes avant un refus commun (cf. test-palier-retention.sh) ;
# ici les deux membres de gauche ne peuvent pas produire d'effet de bord qui
# rendrait la branche B ambiguë — ajouté au diff de transcription (le brief
# n'a pas ce pragma), shellcheck l'exigeait pour passer.
# shellcheck disable=SC2015
_STOA_ARCHIVE_STORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# La voisine qui choisit la forme de l'en-tete. Elle est cherchee A COTE puis
# DEPUIS LA RACINE : un harnais copie cette lib ailleurs pour la muter, et la
# copie n'a alors aucune voisine (mesure 2026-09-04).
# shellcheck source=scripts/lib/forge-identity.sh
if [ -r "${BASH_SOURCE[0]%/*}/forge-identity.sh" ]; then . "${BASH_SOURCE[0]%/*}/forge-identity.sh"
elif [ -r "${_STOA_ARCHIVE_STORE_ROOT}/poc-control-plane-federation/scripts/lib/forge-identity.sh" ]; then . "${_STOA_ARCHIVE_STORE_ROOT}/poc-control-plane-federation/scripts/lib/forge-identity.sh"
elif [ -r "${_STOA_ARCHIVE_STORE_ROOT}/scripts/lib/forge-identity.sh" ]; then . "${_STOA_ARCHIVE_STORE_ROOT}/scripts/lib/forge-identity.sh"
else echo "LIB_ABSENTE : forge-identity.sh (ni voisine, ni sous la racine)" >&2; return 1; fi
export _STOA_ARCHIVE_STORE_ROOT

_as_fail() { printf 'archive-store: %s\n' "$*" >&2; }

_as_ident_ok() {   # <valeur> — classe [a-z0-9-], jamais vide (segment d'URL/chemin)
  case "$1" in ""|*[!a-z0-9-]*) return 1;; esac; return 0
}

_as_curl() {       # $@ — curl authentifié, header-file éphémère (umask du caller)
  local hdr rc
  hdr="$(mktemp)" || { _as_fail "STORE_TMP_INCREABLE"; return 1; }
  forge_auth_write "${FORGE_SECRET:-${GITEA_TOKEN:?}}" "$hdr" || return 1
  curl -sS -H @"$hdr" "$@"; rc=$?
  rm -f "$hdr"
  return "$rc"
}

_as_get_follow_once() { # <url> <fichier> — GET authentifié, UNE redirection suivie SANS auth ; imprime le code final
  # POURQUOI (mesuré en revue le 2026-09-12) : le registre peut vivre sur un
  # OBJECT STORAGE — GitLab avec proxy_download=false, qui est le défaut de
  # GitLab.com et des installations HA. Le GET du paquet rend alors 302 vers une
  # URL PRÉSIGNÉE. Sans ce chemin, un registre parfaitement sain se lisait
  # « STORE_HTTP_302 : l'archive pinnée n'est pas au registre (export jamais
  # poussé ?) » : une panne dure AVEC un faux diagnostic.
  # ET PAS `curl -L` NU : curl réémet ses en-têtes sur la cible, donc le jeton
  # de forge partirait chez l'hôte de stockage — un secret livré à un tiers.
  # La deuxième requête est donc ANONYME : l'URL présignée porte déjà son
  # autorisation. UNE SEULE redirection : une chaîne plus longue est un
  # registre qu'on ne reconnaît pas, et le code 3xx ressort tel quel pour que
  # le refus de l'appelant le NOMME.
  local url="$1" dest="$2" code hdr loc
  hdr="$(mktemp)" || { _as_fail "STORE_TMP_INCREABLE"; printf '000'; return 0; }
  code="$(_as_curl -o "$dest" -D "$hdr" -w '%{http_code}' --max-time 300 "$url")" || code=000
  case "$code" in
    301|302|303|307|308)
      loc="$(tr -d '\r' < "$hdr" | awk 'tolower($1) == "location:" { print $2; exit }')"
      rm -f "$hdr"
      [ -n "$loc" ] || { _as_fail "STORE_REDIRECTION_SANS_LOCATION : $url rend $code sans en-tête Location"; printf '%s' "$code"; return 0; }
      # Une Location ENRACINÉE (RFC 9110 : elle peut être relative) se recolle
      # sur l'hôte du registre, jamais sur un hôte deviné.
      case "$loc" in
        http://*|https://*) ;;
        /*) loc="${GIT_HOST%/}$loc" ;;
        *) _as_fail "STORE_REDIRECTION_ILLISIBLE : Location '$loc' n'est ni absolue ni enracinée"; printf '%s' "$code"; return 0 ;;
      esac
      code="$(curl -sS -o "$dest" -w '%{http_code}' --max-time 300 "$loc")" || code=000 ;;
    *) rm -f "$hdr" ;;
  esac
  printf '%s' "$code"
}

_as_url() {        # <team> <api> <sha> — l'URL canonique du contenu, selon le VISAGE
  # Gitea : registre GÉNÉRIQUE par PROPRIÉTAIRE (ARCHIVE_STORE_OWNER, défaut
  # ci). GitLab : le registre générique n'existe qu'à l'échelle d'un PROJET —
  # ARCHIVE_STORE_PROJECT (<groupe>/<projet>, au lab ci/archives), chemin
  # URL-encodé (ADR-099 D10).
  # Aucun défaut de visage ici (Task 17, addendum §1) : forge_api_init refuse
  # déjà FORGE_KIND_REQUIS quand la variable manque, mais cette lib ne le
  # source pas (transport binaire, jamais l'init JSON) — sans ce refus, son
  # propre case serait le DERNIER défaut silencieux de toute la chaîne, une
  # fois tous les autres retirés le 2026-09-12.
  [ -n "${FORGE_KIND:-}" ] || { _as_fail "FORGE_KIND_REQUIS : visage de la forge (gitea|gitlab) — aucun défaut ; l'appelant (api-promote-export, team-promote) l'a reçu de son Jenkinsfile et exporté à l'init"; return 1; }
  # Le `/` final de GIT_HOST est retiré ICI, comme dans setup-team-repos.sh : sans
  # cela un GIT_HOST posé avec sa barre produit `…//api/…`, que certains
  # reverse-proxies refusent, et qui n'est de toute façon pas l'URL canonique.
  local host="${GIT_HOST:?GIT_HOST requis}"; host="${host%/}"
  case "$FORGE_KIND" in
    gitlab)
      [ -n "${ARCHIVE_STORE_PROJECT:-}" ] || { _as_fail "ARCHIVE_STORE_PROJECT_REQUIS : sous GitLab le registre générique est PAR PROJET — poser ARCHIVE_STORE_PROJECT=<groupe>/<projet> (au lab : ci/archives)"; return 1; }
      printf '%s/api/v4/projects/%s/packages/generic/promote--%s--%s/%s/archive.zip' \
        "$host" "$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$ARCHIVE_STORE_PROJECT")" "$1" "$2" "$3" ;;
    gitea)
      printf '%s/api/packages/%s/generic/promote--%s--%s/%s/archive.zip' \
        "$host" "${ARCHIVE_STORE_OWNER:-ci}" "$1" "$2" "$3" ;;
    *) _as_fail "FORGE_KIND_INCONNU : '$FORGE_KIND' — attendu gitea ou gitlab"; return 1 ;;
  esac
}

archive_store_push() { # <zip_abs> <team> <api>
  local zip="$1" team="$2" api="$3" sha url code probe
  [ -n "${FORGE_SECRET:-${GITEA_TOKEN:-}}" ] || { _as_fail "STORE_TOKEN_ABSENT : FORGE_SECRET requis"; return 1; }
  _as_ident_ok "$team" && _as_ident_ok "$api" \
    || { _as_fail "STORE_PARAM_INVALIDE : team='$team' api='$api' (classe [a-z0-9-])"; return 1; }
  case "$zip" in /*) ;; *) { _as_fail "STORE_PARAM_INVALIDE : chemin d'archive non absolu '$zip'"; return 1; };; esac
  [ -f "$zip" ] || { _as_fail "STORE_PARAM_INVALIDE : archive introuvable '$zip'"; return 1; }
  sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
  [ "${#sha}" -eq 64 ] || { _as_fail "STORE_DIGEST_INCALCULABLE : '$zip'"; return 1; }
  url="$(_as_url "$team" "$api" "$sha")" || return 1
  # Idempotence PAR LE CONTENU : si le chemin existe déjà, on re-hache ce qu'il
  # sert. Identique -> no-op nommé ; différent -> incident (l'adressage par
  # contenu vient d'être contredit), on n'écrase JAMAIS.
  # La sonde passe par le MÊME chemin de relecture que le fetch : derrière un
  # 302 d'object storage, « présent » doit rester « présent », sinon la
  # promotion re-PUT sur un chemin déjà occupé (409) au lieu du no-op nommé.
  probe="$(mktemp)" || { _as_fail "STORE_TMP_INCREABLE"; return 1; }
  code="$(_as_get_follow_once "$url" "$probe")"
  if [ "$code" = 200 ]; then
    local got; got="$(shasum -a 256 "$probe" | cut -d' ' -f1)"; rm -f "$probe"
    [ "$got" = "$sha" ] \
      || { _as_fail "STORE_CONFLIT_CONTENU : $url sert $got, attendu $sha — registre incohérent, refus d'écraser"; return 1; }
    printf 'ARCHIVE_STORE_PUSHED sha256=%s url=%s\n' "$sha" "$url"
    return 0
  fi
  rm -f "$probe"
  [ "$code" = 404 ] || { _as_fail "STORE_HTTP_$code : sonde de $url"; return 1; }
  code="$(_as_curl -o /dev/null -w '%{http_code}' --max-time 300 --upload-file "$zip" "$url")" || code=000
  [ "$code" = 201 ] || { _as_fail "STORE_HTTP_$code : PUT $url"; return 1; }
  printf 'ARCHIVE_STORE_PUSHED sha256=%s url=%s\n' "$sha" "$url"
}

archive_store_fetch() { # <team> <api> <sha256> <dest_abs>
  local team="$1" api="$2" sha="$3" dest="$4" url code got tmp
  [ -n "${FORGE_SECRET:-${GITEA_TOKEN:-}}" ] || { _as_fail "STORE_TOKEN_ABSENT : FORGE_SECRET requis (ou son alias historique)"; return 1; }
  _as_ident_ok "$team" && _as_ident_ok "$api" \
    || { _as_fail "STORE_PARAM_INVALIDE : team='$team' api='$api'"; return 1; }
  case "$sha" in *[!0-9a-f]*|"") { _as_fail "STORE_PARAM_INVALIDE : sha256 '$sha'"; return 1; };; esac
  [ "${#sha}" -eq 64 ] || { _as_fail "STORE_PARAM_INVALIDE : sha256 long de ${#sha}"; return 1; }
  case "$dest" in /*) ;; *) { _as_fail "STORE_PARAM_INVALIDE : destination non absolue '$dest'"; return 1; };; esac
  url="$(_as_url "$team" "$api" "$sha")" || return 1
  tmp="$(mktemp)" || { _as_fail "STORE_TMP_INCREABLE"; return 1; }
  code="$(_as_get_follow_once "$url" "$tmp")"
  [ "$code" = 200 ] || { rm -f "$tmp"; _as_fail "STORE_HTTP_$code : GET $url — l'archive pinnée n'est pas au registre (export jamais poussé ?)"; return 1; }
  got="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
  [ "$got" = "$sha" ] \
    || { rm -f "$tmp"; _as_fail "STORE_DIGEST_MISMATCH : $url sert $got, le marqueur pinne $sha"; return 1; }
  mv "$tmp" "$dest" || { rm -f "$tmp"; _as_fail "STORE_DEST_INECRIVABLE : '$dest'"; return 1; }
  printf 'ARCHIVE_STORE_FETCHED sha256=%s\n' "$sha"
}
