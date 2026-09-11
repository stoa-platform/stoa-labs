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
# soit le login de l'URL ; GET /user exige le scope read:user (403 sinon) ;
# read:user + write:repository suffisent à créer une branche et une PR.
#
# L5 (2026-09-09) : le login est demandé par `forge whoami` (scripts/lib/forge-api.sh)
# — le visage (FORGE_KIND), la base d'API, l'en-tête et la garde de réponse
# vivent LÀ, jamais ici. Cette lib se contente de NOMMER les refus (tags
# inchangés : FORGE_TOKEN_INVALIDE, FORGE_SCOPE_INSUFFISANT, FORGE_LOGIN_INVALIDE)
# depuis la cause auto-diagnostique que forge-api rend sur stderr.
#
# Le token voyage par FICHIER (jamais argv, jamais URL) ; le login est BORNÉ (il
# entre dans un corps de PR, un trailer de commit et un script askpass).
#
#   . scripts/lib/forge-identity.sh
#   login="$(forge_login "" "$tokfile")"         # rc 0 ; rc 2 = REFUS: nommé (stderr) ; rc 1 = ERREUR: (réseau)
#   forge_is_service "$login" "$GITEA_SERVICE_LOGINS" && …
#
# DEUX MODES D'IDENTITE, selon ce que rend le gestionnaire d'identite :
#   un JETON      → FORGE_API_AUTH=token (defaut) ou private-token ; le login est
#                   demande a la forge (`forge whoami`).
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
# forge_auth_write <secret> <fichier d'en-tete> — meme choix, mais depuis la
# VALEUR. La plupart des scripts tiennent le secret dans une variable, pas dans
# un fichier ; sans cette forme, ils continueraient d'ecrire l'en-tete de Gitea
# en dur — et un jeton GitLab dans une variable au nom neutre, envoye avec
# l'en-tete de Gitea, rendrait un 401 sous un nom qui promet la neutralite.
# `forge` vient de forge-api.sh ; un appelant qui ne l'a pas sourcé (la suite E0
# charge cette lib seule) le reçoit d'ici — AU MOMENT de forge_login, jamais au
# chargement : six des sept scripts qui sourcent cette lib n'ont besoin que de
# forge_auth_header/forge_askpass, et test-archive-store copie la lib SEULE dans
# un répertoire de travail (un sourcing au chargement la rendait inchargeable).
# Chemin ABSOLU, parce que forge-api.sh localise forge-api.py à côté de lui.
_FORGE_IDENTITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_forge_identity_forge() {
  declare -F forge >/dev/null 2>&1 && return 0
  # shellcheck source=scripts/lib/forge-api.sh
  . "${_FORGE_IDENTITY_DIR}/forge-api.sh" \
    || { echo "ERREUR: scripts/lib/forge-api.sh introuvable ou illisible (forge_login en dépend)" >&2; return 1; }
}

forge_auth_write() {
  local secret="$1" hf="$2" mode="${FORGE_API_AUTH:-token}" u b64
  case "$mode" in
    token)         printf 'Authorization: token %s\n' "$secret" > "$hf" ;;
    private-token) printf 'PRIVATE-TOKEN: %s\n' "$secret" > "$hf" ;;
    basic)
      u="${FORGE_USER:-}"
      [ -n "$u" ] || { echo "REFUS: FORGE_USER_REQUIS : FORGE_API_AUTH=basic exige FORGE_USER (l'utilisateur du couple)" >&2; return 2; }
      b64=$(printf '%s:%s' "$u" "$secret" | base64 | tr -d '\n') || return 1
      printf 'Authorization: Basic %s\n' "$b64" > "$hf" ;;
    *) echo "REFUS: FORGE_API_AUTH_INCONNU : '$mode' — attendu token, private-token ou basic" >&2; return 2 ;;
  esac
}

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
#
# <api-base> (L5) : la base d'API n'est PLUS composée par l'appelant — elle vient
# de forge-api (GIT_HOST + FORGE_KIND, ou FORGE_API_BASE pour un reverse-proxy).
# La signature est conservée (les appelants le passent encore) et l'argument est
# IGNORÉ dès que l'environnement porte GIT_HOST ou FORGE_API_BASE — c'est-à-dire
# dans toute la chaîne, où forge_api_init les a exigés. Il n'est lu que pour un
# appel DIRECT hors chaîne (la lib chargée seule, sans GIT_HOST : la suite E0),
# où il vaut FORGE_API_BASE le temps de l'appel — jamais un chemin d'API deviné.
#
# Les refus gardent leurs TAGS (les harnais les grep) ; la CAUSE de forge-api
# (statut, type, taille, URL, début du corps expurgé) est écrite AVANT, telle
# quelle : c'est elle que le client doit lire à la place d'une trace. Sous
# STOA_DEBUG (L2, 2026-09-11), la ligne « [dbg forge-api.py] GET …/user -> HTTP
# 200 » du whoami RÉUSSI est relayée elle aussi : ce que forge-api.py écrit sur
# stderr n'est plus retenu par cette lib, quel que soit le rc.
#   HTTP 401 ⇒ REFUS: FORGE_TOKEN_INVALIDE (rc 2)
#   HTTP 403 ⇒ REFUS: FORGE_SCOPE_INSUFFISANT (rc 2)
#   login hors classe ⇒ REFUS: FORGE_LOGIN_INVALIDE (rc 2) — le contrat d'avant L5
#   tout autre échec (réseau, 5xx, redirection, HTML…) ⇒ ERREUR: (rc 1)
forge_login() {
  local api="${1:-}" tf="$2" rc cause login api_base WHO_LOGIN=""
  if [ -n "${FORGE_USER:-}" ]; then
    printf '%s' "$FORGE_USER" | grep -Eq '^[A-Za-z0-9._-]+$' \
      || { echo "REFUS: FORGE_LOGIN_INVALIDE : FORGE_USER hors de [A-Za-z0-9._-]" >&2; return 2; }
    printf '%s' "$FORGE_USER"; return 0
  fi
  [ -s "$tf" ] || { echo "REFUS: FORGE_TOKEN_INVALIDE : fichier de token vide" >&2; return 2; }
  _forge_identity_forge || return 1
  api_base="${FORGE_API_BASE:-}"
  [ -n "$api_base" ] || [ -n "${GIT_HOST:-}" ] || api_base="$api"
  # Le secret par FICHIER (jamais argv) ; la cause éventuelle dans un fichier à
  # côté du token, jamais mêlée au login rendu sur stdout. Le rc est lu AVANT
  # toute autre commande (pas de `set -e` chez les appelants). La capture reste :
  # c'est dans la cause que le `case` ci-dessous lit le statut (401/403…) pour
  # NOMMER le refus — pas seulement pour ordonner cause puis tag.
  FORGE_API_BASE="$api_base" FORGE_SECRET_FILE="$tf" forge_kv WHO whoami 2>"${tf}.err"; rc=$?
  cause="$(cat "${tf}.err" 2>/dev/null)"; rm -f "${tf}.err"
  # Relayée dans TOUS les cas, succès compris (mode debug L2, grammaire §5).
  # Sur rc 0 le fichier ne porte que ce que forge-api.py écrit sous STOA_DEBUG —
  # « [dbg forge-api.py] GET …/user -> HTTP 200 (n octets) », déjà masquée par
  # SON _mask (le secret en usage sous ses formes d'URL, l'userinfo d'un
  # GIT_HOST) — et rien sans lui : forge-api.py n'écrit sur stderr que par _dbg
  # et sur ForgeError. Mesuré (L2-B5, 2026-09-11, forge_login seule, HEAD contre
  # arbre, six chemins × {STOA_DEBUG=1, absent, 0}) : 16 cas sur 17 identiques
  # à l'octet — rc, stdout, stderr — ; le 17e est celui-ci, rc 0 sous debug, qui
  # gagne cette seule ligne. Jusque-là elle n'était relayée que sur rc ≠ 0 :
  # lue, effacée, PERDUE (mesure L2-B1 n°2 — journal du stub users=1, 0 ligne
  # « /user » sur stderr ; test-app-request-a7 E12.1n', et M15 qui remet le
  # relais conditionnel). Sur rc ≠ 0 rien ne bouge : la cause sort UNE fois,
  # AVANT le tag, comme avant. Rien n'est coupé ici, donc rien à masquer avant
  # une coupe : la ligne part entière, telle que python l'a écrite.
  [ -z "$cause" ] || printf '%s\n' "$cause" >&2
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      2) case "$cause" in
           *"HTTP 401"*) echo "REFUS: FORGE_TOKEN_INVALIDE : la forge refuse ce token (HTTP 401) — token révoqué ou mal collé (cause ci-dessus)" >&2; return 2 ;;
           *"HTTP 403"*) echo "REFUS: FORGE_SCOPE_INSUFFISANT : le token ne peut pas lire son propre profil (HTTP 403) — il doit porter le scope read:user (et write:repository pour pousser) (cause ci-dessus)" >&2; return 2 ;;
           *"('')"*)     echo "ERREUR: identité de forge invérifiable (réponse sans login)" >&2; return 1 ;;
           *"login de forge"*) echo "REFUS: FORGE_LOGIN_INVALIDE : login de forge hors de [A-Za-z0-9._-] — il entrerait dans un corps de PR et un trailer de commit (cause ci-dessus)" >&2; return 2 ;;
           *) echo "ERREUR: identité de forge invérifiable (forge whoami — cause ci-dessus)" >&2; return 1 ;;
         esac ;;
      *) echo "ERREUR: identité de forge invérifiable (forge whoami rc ${rc} — cause ci-dessus)" >&2; return 1 ;;
    esac
  fi
  login="$WHO_LOGIN"
  [ -n "$login" ] || { echo "ERREUR: identité de forge invérifiable (réponse sans login)" >&2; return 1; }
  # La classe est re-vérifiée ICI même si forge-api l'a déjà bornée : c'est
  # cette lib qui répond du login qu'elle rend (corps de PR, trailer, askpass).
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
