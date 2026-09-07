#!/usr/bin/env bash
# scripts/lib/wm-admin-curl.sh — l'appel HTTP vers l'admin webMethods.
#
# LE SECRET NE PASSE JAMAIS PAR ARGV. Motif de assign-api-team.sh:37-43 :
# un fichier d'en-tête 0600, lu par `curl -H @fichier`. `curl -u` et
# `-H "Authorization: …"` mettent tous deux le secret dans l'argv, visible
# par `ps -Aww` de tout utilisateur de la machine pendant toute la durée.
#
# L'URL EST LE SECOND VECTEUR, ET IL ÉTAIT OUVERT. Une base d'admin de site
# porte son userinfo (`https://svc-scan:<mot de passe>@apim…`) : l'en-tête
# était protégé, l'URL non — elle passait en argv de `curl`. Mesuré avant
# correctif : le canari Basic base64 comptait 0 occurrence dans `ps -Aww`
# pendant que le mot de passe d'URL en comptait 1 (l'argv de curl). Le
# vecteur se ferme EXACTEMENT comme l'autre : `curl -K <fichier 0600>` lit
# `url = "…"` du fichier — mesuré, seul le CHEMIN du fichier reste en argv,
# et `-H @fichier` continue de primer sur l'auth déduite de l'userinfo.
#
# L'EXPURGATION EST UNE SEULE FONCTION (`wm_redact_url`), employée par les
# MESSAGES d'ici ET par la provenance écrite dans l'inventaire
# (scan-parc.sh). L'asymétrie d'avant — le fichier expurgé, le message non —
# faisait fuir l'userinfo sur stderr, donc dans le log de build, donc dans un
# artefact archivé (spec §9.5 : « base d'admin dans un message : expurgée »).
#
# LE PRÉFLIGHT NE VISE PAS /health : chez un client il peut être injoignable
# depuis la VIP ou filtré en amont (ci/Jenkinsfile.selfservice:503-507). La
# sonde est <BASE>/apis SANS jeton : un 401 dit que le proxy est vivant ET
# que son OAuth2 est enforce — c'est plus fort qu'un /health.
_wm_refus(){ echo "REFUS: $1 : $2" >&2; return 1; }

# wm_redact_url <url> — l'UNIQUE expurgation d'userinfo du chantier. Tout ce
# qui affiche ou écrit une base d'admin passe par ici : le message de refus
# ci-dessous, et provenance.base de l'inventaire (scan-parc.sh). Une seconde
# copie de ce `sed` ailleurs serait le défaut qu'on vient de corriger.
wm_redact_url(){ printf '%s' "$1" | sed -E 's#://[^[:space:]]*@#://<identifiants masqués>@#g'; }

# _wm_url_file <url> — écrit l'URL dans un fichier de configuration curl 0600
# et imprime son chemin, pour `curl -K`. L'appelant supprime le fichier.
#
# LE CONTRÔLE DE CARACTÈRES N'EST PAS DÉCORATIF : un saut de ligne dans l'URL
# injecterait une SECONDE directive dans le fichier de configuration (curl y
# accepte toutes ses options, pas seulement `url`). Comme le chemin de
# `wm_get` est composé d'identifiants VENUS DU PARC, cette garde est la
# dernière avant curl. Les guillemets et l'antislash sont refusés aussi : ce
# sont les deux seuls caractères d'échappement de la forme quotée de curl —
# les exclure rend l'écriture ci-dessous sûre sans échappement.
_wm_url_file(){
  local u="$1" f old
  case "$u" in
    ''|*[[:space:][:cntrl:]]*|*'"'*|*\\*)
      _wm_refus WM_URL_INVALIDE "l'URL composée est vide ou porte un espace, un caractère de contrôle, un guillemet ou un antislash — refusée AVANT curl (une URL multiligne injecterait des options dans le fichier de configuration)"
      return 1 ;;
  esac
  old="$(umask)"; umask 077
  f="$(mktemp)" || { umask "$old"; _wm_refus MKTEMP "fichier d'URL"; return 1; }
  umask "$old"; chmod 600 "$f"
  printf 'url = "%s"\n' "$u" > "$f" || { rm -f "$f"; _wm_refus ECRITURE_URL "$f"; return 1; }
  printf '%s' "$f"
}

wm_admin_init(){
  local old_umask; old_umask="$(umask)"; umask 077
  WM_HDR="$(mktemp)" || { umask "$old_umask"; _wm_refus MKTEMP "fichier d'en-tête"; return 1; }
  umask "$old_umask"
  chmod 600 "$WM_HDR"
  case "${APIM_AUTH_MODE:-}" in
    basic)
      [ -n "${WM_USER:-}" ] && [ -n "${WM_PASSWORD:-}" ] \
        || { _wm_refus WM_CREDENTIAL_REQUIS "WM_USER et WM_PASSWORD sont requis en mode basic"; return 1; }
      printf 'Authorization: Basic %s\n' \
        "$(printf '%s:%s' "$WM_USER" "$WM_PASSWORD" | base64 | tr -d '\n')" > "$WM_HDR" ;;
    oauth2)
      [ -n "${WM_BEARER:-}" ] \
        || { _wm_refus WM_JETON_REQUIS "WM_BEARER est requis en mode oauth2 (client_credentials déjà échangé)"; return 1; }
      printf 'Authorization: Bearer %s\n' "$WM_BEARER" > "$WM_HDR" ;;
    *) _wm_refus WM_AUTH_MODE_INCONNU "'${APIM_AUTH_MODE:-}' — attendu basic ou oauth2"; return 1 ;;
  esac
  export WM_HDR
}
wm_admin_cleanup(){ [ -n "${WM_HDR:-}" ] && rm -f "$WM_HDR"; }

wm_get(){
  local path="$1" out="$2" ca=()
  [ -n "${VAULT_CACERT:-${LABCTL_CA_FILE:-}}" ] && ca=(--cacert "${VAULT_CACERT:-$LABCTL_CA_FILE}")
  # `${ca[@]+"${ca[@]}"}` : un tableau VIDE sous `set -u` en bash 3.2 est « unbound »
  # (même motif que scripts/selfservice-palier-gate.sh:165).
  local uf rc
  uf="$(_wm_url_file "${APIM_BASE}${path}")" || return 1
  curl -s -m "${WM_TIMEOUT:-30}" -o "$out" -w '%{http_code}' \
    -H @"$WM_HDR" ${ca[@]+"${ca[@]}"} -K "$uf"
  rc=$?
  rm -f "$uf"
  return "$rc"
}

wm_preflight(){
  local lc; lc="$(printf '%s' "${APIM_PREFLIGHT:-on}" | tr '[:upper:]' '[:lower:]')"
  WM_PREFLIGHT_URL="${APIM_PREFLIGHT_URL:-${APIM_BASE}/apis}"; export WM_PREFLIGHT_URL
  # WM_PREFLIGHT_CODE dit CE QUI A ÉTÉ MESURÉ, jamais ce qu'on espérait :
  # DESACTIVE tant que la sonde n'a pas tourné. L'inventaire l'écrit tel quel
  # (scan-parc.sh) — il portait « OK » EN LITTÉRAL, y compris quand
  # APIM_PREFLIGHT=off : un champ de provenance qui mentait.
  WM_PREFLIGHT_CODE=DESACTIVE; export WM_PREFLIGHT_CODE
  [ "$lc" = off ] && { echo "  (préflight désactivé — APIM_PREFLIGHT=off)" >&2; return 0; }
  local codes="${APIM_PREFLIGHT_CODES:-200 401}" c uf
  uf="$(_wm_url_file "$WM_PREFLIGHT_URL")" || return 1
  # SANS jeton, délibérément : le 401 est la preuve de vie du proxy.
  c="$(curl -s -o /dev/null -m "${WM_TIMEOUT:-30}" -w '%{http_code}' -K "$uf")"
  rm -f "$uf"
  # `curl -w '%{http_code}'` imprime DÉJÀ `000` quand la connexion échoue. Le
  # `|| echo 000` d'avant en concaténait un SECOND : le refus annonçait
  # « HTTP 000000 », un code qui n'existe pas — un message qui ment sur ce
  # qu'il a mesuré. On normalise ce qui n'est pas trois chiffres, sans rien
  # ajouter à ce que curl a dit.
  case "$c" in ''|*[!0-9]*) c=000 ;; esac
  WM_PREFLIGHT_CODE="$c"; export WM_PREFLIGHT_CODE
  case " $codes " in *" $c "*) return 0 ;; esac
  # EXPURGÉ : ce message part sur stderr, donc dans le log de build, donc dans
  # un artefact archivé. La base brute y portait l'userinfo du compte de scan.
  _wm_refus GATEWAY_INJOIGNABLE "sonde $(wm_redact_url "$WM_PREFLIGHT_URL") -> HTTP ${c} (attendus : ${codes})"
}

# wm_diag_401 <fichier de corps> — un 401 a DEUX causes, et les confondre fait
# relancer un login en boucle jusqu'à verrouiller le compte d'annuaire.
wm_diag_401(){
  if grep -qi 'administrator group\|not a member' "$1" 2>/dev/null; then
    echo "WM_401_AUTORISATION : le couple est bon, mais le compte n'appartient à aucun groupe d'administration. Demander à l'ops l'ajout des droits de LECTURE sur l'API d'administration (GET /apis, GET /applications) — ne PAS relancer avec un autre mot de passe." >&2
  else
    echo "WM_401_AUTHENTIFICATION : identifiant refusé. Vérifier WM_USER/WM_PASSWORD (mode basic) ou le jeton (mode oauth2) AVANT de réessayer — un compte d'annuaire se verrouille." >&2
  fi
}
