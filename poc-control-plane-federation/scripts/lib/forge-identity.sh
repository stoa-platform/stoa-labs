#!/usr/bin/env bash
# scripts/lib/forge-identity.sh — A7 (GOAL cd-applications, ADR-090) : l'IDENTITÉ
# DE FORGE d'une demande.
#
# Le token nominatif saisi au formulaire (FORGE_TOKEN) est la seule preuve
# d'identité humaine que ce lab tient (Jenkins anonyme, pas de build-user-vars,
# Sudo de forge refusé : il ferait dériver l'auteur d'une identité non prouvée).
# Son PORTEUR est l'auteur de la PR — c'est lui que la porte à quatre yeux (A4,
# provision-apply-gate.sh §3) confronte au mergeur relu sur la forge.
#
# Mesuré (Gitea 1.22.6, 2026-09-03) : le token authentifie son porteur quel que
# soit le login de l'URL ; GET /api/v1/user exige le scope read:user (403 sinon) ;
# read:user + write:repository suffisent à créer une branche et une PR.
#
# Le token voyage par FICHIER (jamais argv, jamais URL) ; le login est BORNÉ (il
# entre dans un corps de PR, un trailer de commit et un script askpass).
#
#   . scripts/lib/forge-identity.sh
#   login="$(forge_login "$API" "$tokfile")"     # rc 0 ; rc 2 = REFUS: nommé (stderr) ; rc 1 = ERREUR: (réseau)
#   forge_is_service "$login" "$GITEA_SERVICE_LOGINS" && …
#   export GIT_ASKPASS="$(forge_askpass "$dir" "$login" "$tokfile")"

# forge_login <api-base> <token-file> → login sur stdout
forge_login() {
  local api="$1" tf="$2" hc login
  [ -s "$tf" ] || { echo "REFUS: FORGE_TOKEN_INVALIDE : fichier de token vide" >&2; return 2; }
  { printf 'Authorization: token '; tr -d '\r\n' < "$tf"; printf '\n'; } > "${tf}.hdr" || return 1
  hc=$(curl -sS --max-time 20 -H @"${tf}.hdr" -o "${tf}.user" -w '%{http_code}' "${api}/user" 2>"${tf}.err") \
    || { rm -f "${tf}.hdr" "${tf}.user"; echo "ERREUR: identité de forge invérifiable (réseau) : $(head -c 120 "${tf}.err" 2>/dev/null | tr '\n' ' ')" >&2; rm -f "${tf}.err"; return 1; }
  rm -f "${tf}.hdr" "${tf}.err"
  case "$hc" in
    200) ;;
    401) rm -f "${tf}.user"; echo "REFUS: FORGE_TOKEN_INVALIDE : la forge refuse ce token (HTTP 401) — token révoqué ou mal collé" >&2; return 2 ;;
    403) rm -f "${tf}.user"; echo "REFUS: FORGE_SCOPE_INSUFFISANT : le token ne peut pas lire son propre profil (HTTP 403) — il doit porter le scope read:user (et write:repository pour pousser)" >&2; return 2 ;;
    *)   rm -f "${tf}.user"; echo "ERREUR: identité de forge invérifiable (GET /user → HTTP ${hc})" >&2; return 1 ;;
  esac
  login=$(python3 -c 'import json,sys
try: print(str((json.load(open(sys.argv[1])) or {}).get("login") or ""))
except Exception: print("")' "${tf}.user" 2>/dev/null)
  rm -f "${tf}.user"
  [ -n "$login" ] || { echo "ERREUR: identité de forge invérifiable (réponse sans login)" >&2; return 1; }
  printf '%s' "$login" | grep -Eq '^[A-Za-z0-9._-]+$' \
    || { echo "REFUS: FORGE_LOGIN_INVALIDE : login de forge hors de [A-Za-z0-9._-] — il entrerait dans un corps de PR et un trailer de commit" >&2; return 2; }
  printf '%s' "$login"
}

# forge_is_service <login> "<liste séparée par des espaces>" → rc 0 si le login y est
forge_is_service() {
  local l
  for l in $2; do [ "$l" = "$1" ] && return 0; done
  return 1
}

# forge_askpass <dir> <login> <token-file> → chemin d'un script GIT_ASKPASS (0700)
# qui rend le login pour "Username…" et le token (lu dans le fichier) sinon.
forge_askpass() {
  local f="$1/askpass"
  # shellcheck disable=SC2016  # le `$1` est celui du script askpass rendu, à dessein
  printf '#!/bin/sh\ncase "$1" in Username*) printf %%s "%s" ;; *) tr -d "\\r\\n" < "%s" ;; esac\n' "$2" "$3" > "$f" \
    && chmod 700 "$f" && printf '%s' "$f"
}
