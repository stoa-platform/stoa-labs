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
#
# DEUX MODES D'IDENTITE, selon ce que rend le gestionnaire d'identite :
#   un JETON      → FORGE_API_AUTH=token (defaut) ou private-token ; le login est
#                   demande a la forge (GET /user).
#   un COUPLE     → FORGE_API_AUTH=basic + FORGE_USER=<utilisateur> ; le login est
#                   CONNU, aucun appel n'est fait pour le redemander.
#   export GIT_ASKPASS="$(forge_askpass "$dir" "$login" "$tokfile")"

# forge_auth_header <fichier de secret> <fichier d'en-tete> — ECRIT l'en-tete
# d'autorisation, selon FORGE_API_AUTH :
#   token         « Authorization: token <secret> »   — Gitea (defaut, inchange)
#   private-token « PRIVATE-TOKEN: <secret> »         — GitLab, jeton personnel
#   basic         « Authorization: Basic <u:p> »      — GitLab/Bitbucket, ou tout
#                 gestionnaire d'identite qui rend un COUPLE (Jenkins
#                 usernamePassword) : FORGE_USER porte alors l'utilisateur.
# Deploiement client 2026-09-04 : le credential Jenkins rend un user + mot de
# passe, pas un jeton ; « Authorization: token » n'a aucun sens pour la forge en
# face, et le refus qui suivait accusait le jeton de l'utilisateur.
forge_auth_header() {
  local sf="$1" hf="$2" mode="${FORGE_API_AUTH:-token}" u b64
  case "$mode" in
    token)         { printf 'Authorization: token '; tr -d '\r\n' < "$sf"; printf '\n'; } > "$hf" ;;
    private-token) { printf 'PRIVATE-TOKEN: ';       tr -d '\r\n' < "$sf"; printf '\n'; } > "$hf" ;;
    basic)
      u="${FORGE_USER:-}"
      [ -n "$u" ] || { echo "REFUS: FORGE_USER_REQUIS : FORGE_API_AUTH=basic exige FORGE_USER (l'utilisateur du couple)" >&2; return 2; }
      b64=$(printf '%s:%s' "$u" "$(tr -d '\r\n' < "$sf")" | base64 | tr -d '\n') || return 1
      printf 'Authorization: Basic %s\n' "$b64" > "$hf" ;;
    *) echo "REFUS: FORGE_API_AUTH_INCONNU : '$mode' — attendu token, private-token ou basic" >&2; return 2 ;;
  esac
}

# forge_login <api-base> <token-file> → login sur stdout
# FORGE_USER, quand il est pose, DISPENSE de l'appel : un gestionnaire d'identite
# qui rend un couple connait deja le login, et l'aller-retour ne ferait que le
# reconfirmer — au prix du seul scope que certaines forges refusent d'accorder.
forge_login() {
  local api="$1" tf="$2" hc login
  if [ -n "${FORGE_USER:-}" ]; then
    printf '%s' "$FORGE_USER" | grep -Eq '^[A-Za-z0-9._-]+$' \
      || { echo "REFUS: FORGE_LOGIN_INVALIDE : FORGE_USER hors de [A-Za-z0-9._-]" >&2; return 2; }
    printf '%s' "$FORGE_USER"; return 0
  fi
  [ -s "$tf" ] || { echo "REFUS: FORGE_TOKEN_INVALIDE : fichier de token vide" >&2; return 2; }
  forge_auth_header "$tf" "${tf}.hdr" || return $?
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
# qui rend le login pour "Username…" et le SECRET (lu dans le fichier) sinon.
# Ce canal-la est deja neutre : git ne fait qu'un Basic, et un mot de passe y
# vaut un jeton. C'est l'APPELANT qui decide de l'identite (login) et du secret.
forge_askpass() {
  local f="$1/askpass"
  # shellcheck disable=SC2016  # le `$1` est celui du script askpass rendu, à dessein
  printf '#!/bin/sh\ncase "$1" in Username*) printf %%s "%s" ;; *) tr -d "\\r\\n" < "%s" ;; esac\n' "$2" "$3" > "$f" \
    && chmod 700 "$f" && printf '%s' "$f"
}
