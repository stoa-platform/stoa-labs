#!/usr/bin/env bash
# scripts/lib/wm-admin-curl.sh — l'appel HTTP vers l'admin webMethods.
#
# LE SECRET NE PASSE JAMAIS PAR ARGV. Motif de assign-api-team.sh:37-43 :
# un fichier d'en-tête 0600, lu par `curl -H @fichier`. `curl -u` et
# `-H "Authorization: …"` mettent tous deux le secret dans l'argv, visible
# par `ps -Aww` de tout utilisateur de la machine pendant toute la durée.
#
# LE PRÉFLIGHT NE VISE PAS /health : chez un client il peut être injoignable
# depuis la VIP ou filtré en amont (ci/Jenkinsfile.selfservice:503-507). La
# sonde est <BASE>/apis SANS jeton : un 401 dit que le proxy est vivant ET
# que son OAuth2 est enforce — c'est plus fort qu'un /health.
_wm_refus(){ echo "REFUS: $1 : $2" >&2; return 1; }

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
  curl -s -m "${WM_TIMEOUT:-30}" -o "$out" -w '%{http_code}' \
    -H @"$WM_HDR" "${ca[@]}" "${APIM_BASE}${path}"
}

wm_preflight(){
  local lc; lc="$(printf '%s' "${APIM_PREFLIGHT:-on}" | tr '[:upper:]' '[:lower:]')"
  WM_PREFLIGHT_URL="${APIM_PREFLIGHT_URL:-${APIM_BASE}/apis}"; export WM_PREFLIGHT_URL
  [ "$lc" = off ] && { echo "  (préflight désactivé — APIM_PREFLIGHT=off)" >&2; return 0; }
  local codes="${APIM_PREFLIGHT_CODES:-200 401}" c
  # SANS jeton, délibérément : le 401 est la preuve de vie du proxy.
  c="$(curl -s -o /dev/null -m "${WM_TIMEOUT:-30}" -w '%{http_code}' "$WM_PREFLIGHT_URL" || echo 000)"
  case " $codes " in *" $c "*) return 0 ;; esac
  _wm_refus GATEWAY_INJOIGNABLE "sonde ${WM_PREFLIGHT_URL} -> HTTP ${c} (attendus : ${codes})"
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
