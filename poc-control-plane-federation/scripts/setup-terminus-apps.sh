#!/usr/bin/env bash
# scripts/setup-terminus-apps.sh — LAB : équiper le TERMINUS pour les APPLICATIONS
# (A7, ADR-090). Ouvrir le terminus n'est pas un edit : c'est déclarer la voie
# (APIM_TERMINUS_BASE — globale Jenkins, posée par le harnais), ACCORDER le
# credential (ce poseur) et laisser la porte décider (apim-operator-prod). Ce
# script pose, et RELIT, ce que le rôle apim_selfservice_app attend de la
# gateway du terminus — sur ce lab, wm-mock-prod (mémoire seule : rejouer après
# chaque `up -d`) :
#   1. Vault : envs/<terminus>/wm-admin = {username, password} de l'admin de la
#      gateway du terminus — le ticket qu'operator-deploy lit (G7 D2), consommé
#      par le rôle en direct (Basic). Valeurs REQUISES, jamais un défaut : les
#      placeholders du mock ne sont pas ceux d'un client ;
#   2. la feature Teams (PUT /configurations/extended enableTeamWork) ;
#   3. l'accessProfile de l'équipe (POST /accessProfiles s'il manque) ;
#   4. l'alias auth-server, POSÉ depuis des valeurs EXPLICITES du terminus
#      (TERMINUS_ISSUER / TERMINUS_JWKS — « même nom, valeurs locales »,
#      inbound.yml) — JAMAIS copié depuis une autre gateway (un alias copié
#      ferait du terminus un client de l'IdP des paliers hors-prod, et
#      transporterait un éventuel secret d'introspection) ; présent ⇒ relu et
#      comparé, jamais réécrit en silence ;
#   5. le login PROUVÉ (GET /applications avec les creds de Vault ⇒ 200) ;
#   6. un mot de passe FAUX ⇒ 401 (le ticket garde bien quelque chose).
# Ce qu'il ne pose PAS : l'API au terminus (geste PRODUCTEUR — promotion par
# archive) et la globale Jenkins (le geste de déclaration, joué par le harnais).
#
# Le terminus est DÉRIVÉ (env_chain_terminus), jamais un nom en dur. Aucun
# secret en argv ni imprimé : Vault par en-tête fichier, la gateway par une
# config curl lue sur STDIN (`-K -`) — ce qui permet aussi d'appeler la gateway
# depuis un autre conteneur : TERMINUS_CURL="docker exec -i poc-jenkins curl".
#
#   bash scripts/setup-terminus-apps.sh --print       # hors ligne, aucun réseau
#   VAULT_TOKEN=… TERMINUS_ADMIN=http://wm-mock-prod:8080/rest/apigateway \
#     TERMINUS_CURL="docker exec -i poc-jenkins curl" \
#     TERMINUS_WM_USER=… TERMINUS_WM_PASS=… \
#     TERMINUS_ISSUER=http://localhost:8480/realms/stoa-lab \
#     TERMINUS_JWKS=http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs \
#     bash scripts/setup-terminus-apps.sh
# `A && ok || bad` (SC2015) est l'idiome des poseurs du repo ; TERMINUS_CURL est
# volontairement éclaté en mots (SC2086).
# shellcheck disable=SC2015,SC2086
set -uo pipefail
_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/env-chain.sh"; [ -f "$_LIB" ] || _LIB="scripts/lib/env-chain.sh"
# shellcheck source=scripts/lib/env-chain.sh
. "$_LIB"
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
APIM_KV_MOUNT="${APIM_KV_MOUNT:-secret}"; APIM_KV_PREFIX="${APIM_KV_PREFIX:-stoa}"
ALIAS_NAME="${ALIAS_NAME:-KeycloakStoaLab}"
TEAM="${TEAM:-banking-demo}"
TERMINUS_CURL="${TERMINUS_CURL:-curl}"
TERMINUS="$(env_chain_terminus)" || { echo "CHAINE_ILLISIBLE : env_chain_terminus a échoué" >&2; exit 1; }
[ -n "$TERMINUS" ] || { echo "CHAINE_VIDE : aucun terminus" >&2; exit 1; }
KV_SUB="envs/${TERMINUS}/wm-admin"
KV_PATH="${APIM_KV_MOUNT}/data${APIM_KV_PREFIX:+/$APIM_KV_PREFIX}/${KV_SUB}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

if [ "${1:-pose}" = --print ]; then
  echo "# terminus ${TERMINUS} (dérivé d'environments.yaml) — équipement pour les applications (A7) :"
  echo "#   1. Vault ${KV_PATH} = {username, password} de l'admin du terminus (POST, relu — valeurs REQUISES)"
  echo "#   2. PUT /configurations/extended {enableTeamWork: true} (relu)"
  echo "#   3. accessProfile '${TEAM}' (POST s'il manque, relu par nom)"
  echo "#   4. alias auth-server '${ALIAS_NAME}' posé depuis TERMINUS_ISSUER / TERMINUS_JWKS (jamais copié ; présent ⇒ comparé, jamais réécrit)"
  echo "#   5. login prouvé (GET /applications avec les creds de Vault ⇒ 200) ; 6. mot de passe faux ⇒ 401"
  echo "# Aucun secret n'est imprimé ; la pose exige VAULT_TOKEN TERMINUS_ADMIN TERMINUS_WM_USER TERMINUS_WM_PASS TERMINUS_ISSUER TERMINUS_JWKS."
  exit 0
fi
[ "${1:-pose}" = pose ] || { echo "usage: $0 [--print]" >&2; exit 2; }
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis (token exploitant Vault)}"
TERMINUS_ADMIN="${TERMINUS_ADMIN:?TERMINUS_ADMIN requis (ex. http://wm-mock-prod:8080/rest/apigateway, vu de TERMINUS_CURL)}"
TERMINUS_WM_USER="${TERMINUS_WM_USER:?TERMINUS_WM_USER requis (admin de la gateway du terminus — jamais un défaut)}"
TERMINUS_WM_PASS="${TERMINUS_WM_PASS:?TERMINUS_WM_PASS requis}"
TERMINUS_ISSUER="${TERMINUS_ISSUER:?TERMINUS_ISSUER requis (issuer OIDC de l alias auth-server du terminus — valeurs LOCALES, jamais copiees)}"
TERMINUS_JWKS="${TERMINUS_JWKS:?TERMINUS_JWKS requis (jwks_uri de l alias auth-server du terminus)}"
case "$TERMINUS_ADMIN" in http://*|https://*) ;; *) echo "TERMINUS_ADMIN_INVALIDE : '${TERMINUS_ADMIN}' doit être une URL http(s)" >&2; exit 2;; esac
case "$TERMINUS_ISSUER" in http://*|https://*) ;; *) echo "TERMINUS_ISSUER_INVALIDE : '${TERMINUS_ISSUER}' doit être une URL http(s)" >&2; exit 2;; esac
case "$TERMINUS_JWKS" in http://*|https://*) ;; *) echo "TERMINUS_JWKS_INVALIDE : '${TERMINUS_JWKS}' doit être une URL http(s)" >&2; exit 2;; esac
TERMINUS_ADMIN="${TERMINUS_ADMIN%/}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; umask 077
printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$TMP/vhdr"
vcurl(){ curl -sS --max-time 20 -H @"$TMP/vhdr" "$@"; }
# La gateway : config Basic sur STDIN (jamais argv), sortie sur STDOUT (le curl
# peut tourner dans un autre conteneur : aucun fichier -o), code HTTP en dernière ligne.
esc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
tcall(){ # <method> <chemin> [corps JSON] [user] [pass] → $TMP/t.body + $TMP/t.code
  local m="$1" p="$2" body="${3:-}" u="${4:-$TERMINUS_WM_USER}" pw="${5:-$TERMINUS_WM_PASS}"
  if [ -n "$body" ]; then
    printf 'user = "%s:%s"\n' "$(esc "$u")" "$(esc "$pw")" | $TERMINUS_CURL -s -m 20 -K - -X "$m" -H 'Content-Type: application/json' -H 'Accept: application/json' --data-binary "$body" -w '\n%{http_code}' "${TERMINUS_ADMIN}${p}" > "$TMP/t.raw" 2>/dev/null
  else
    printf 'user = "%s:%s"\n' "$(esc "$u")" "$(esc "$pw")" | $TERMINUS_CURL -s -m 20 -K - -X "$m" -H 'Accept: application/json' -w '\n%{http_code}' "${TERMINUS_ADMIN}${p}" > "$TMP/t.raw" 2>/dev/null
  fi
  sed '$d' "$TMP/t.raw" > "$TMP/t.body"; tail -1 "$TMP/t.raw" | tr -d '\r\n' > "$TMP/t.code"
}
tcode(){ cat "$TMP/t.code" 2>/dev/null; }
jfind(){ # <clé de liste> <nom> [champ à imprimer] → imprime le champ (ou l'id) de l'entrée nommée
  python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
for e in d.get(sys.argv[2]) or []:
    if e.get("name")==sys.argv[3]:
        v=e
        for k in (sys.argv[4].split(".") if len(sys.argv)>4 else ["id"]): v=(v or {}).get(k) if isinstance(v,dict) else None
        print("" if v is None else v); sys.exit(0)
sys.exit(1)' "$TMP/t.body" "$1" "$2" "${3:-}"
}

echo "== terminus ${TERMINUS} : équipement pour les applications (A7) =="
# ── 1. Vault : le ticket du terminus ─────────────────────────────────────────
# Le corps porte le mot de passe : par FICHIER 0600, jamais en argv.
U="$TERMINUS_WM_USER" P="$TERMINUS_WM_PASS" python3 -c 'import json,os,sys;sys.stdout.write(json.dumps({"data":{"username":os.environ["U"],"password":os.environ["P"]}}))' > "$TMP/ticket.json"
HC=$(vcurl -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/ticket.json" "${VAULT_ADDR}/v1/${KV_PATH}" 2>/dev/null || echo 000)
rm -f "$TMP/ticket.json"
[ "$HC" = 200 ] && ok "1. ${KV_PATH} écrit (HTTP 200)" || bad "1. écriture de ${KV_PATH} : HTTP ${HC}"
RU=$(vcurl "${VAULT_ADDR}/v1/${KV_PATH}" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["data"]["data"].get("username",""))
except Exception: print("")')
[ "$RU" = "$TERMINUS_WM_USER" ] && ok "1b. relu : username == TERMINUS_WM_USER (le mot de passe n'est pas relu)" || bad "1b. relecture : username='${RU}'"

# ── 2. la feature Teams ──────────────────────────────────────────────────────
tcall PUT /configurations/extended '{"enableTeamWork":"true"}'
[ "$(tcode)" = 200 ] && ok "2. PUT /configurations/extended enableTeamWork=true (HTTP 200)" || bad "2. enableTeamWork : HTTP $(tcode)"
tcall GET /configurations/extended
grep -q '"enableTeamWork": *"true"' "$TMP/t.body" 2>/dev/null && ok "2b. relu : enableTeamWork=\"true\"" || bad "2b. relecture : $(head -c 120 "$TMP/t.body" 2>/dev/null)"

# ── 3. l'accessProfile de l'équipe ───────────────────────────────────────────
tcall GET /accessProfiles
if PID=$(jfind accessProfiles "$TEAM"); then
  ok "3. accessProfile '${TEAM}' présent (${PID})"
else
  BODY=$(T="$TEAM" python3 -c 'import json,os;print(json.dumps({"name":os.environ["T"],"description":"onboarding par palier (A7) — terminus"}))')
  tcall POST /accessProfiles "$BODY"
  [ "$(tcode)" = 200 ] || [ "$(tcode)" = 201 ] && ok "3. accessProfile '${TEAM}' créé (HTTP $(tcode))" || bad "3. création de l'accessProfile : HTTP $(tcode)"
  tcall GET /accessProfiles; jfind accessProfiles "$TEAM" >/dev/null && ok "3b. relu par nom" || bad "3b. accessProfile '${TEAM}' absent après création"
fi

# ── 4. l'alias auth-server : valeurs LOCALES, jamais copiées ─────────────────
tcall GET /alias
if jfind alias "$ALIAS_NAME" >/dev/null; then
  ISS=$(jfind alias "$ALIAS_NAME" localIntrospectionConfig.issuer); JW=$(jfind alias "$ALIAS_NAME" localIntrospectionConfig.jwksuri)
  [ "$ISS" = "$TERMINUS_ISSUER" ] && [ "$JW" = "$TERMINUS_JWKS" ] \
    && ok "4. alias '${ALIAS_NAME}' présent, issuer/jwks == valeurs du terminus (jamais réécrit)" \
    || bad "4. alias '${ALIAS_NAME}' présent mais DIVERGENT (issuer='${ISS}' jwks='${JW}') — jamais réécrit en silence : le retirer à la main si c'est voulu"
else
  BODY=$(N="$ALIAS_NAME" I="$TERMINUS_ISSUER" J="$TERMINUS_JWKS" python3 -c 'import json,os;print(json.dumps({"name":os.environ["N"],"type":"authServerAlias","authServerType":"EXTERNAL","description":"terminus (A7) — alias auth-server pose depuis des valeurs locales, jamais copiees","localIntrospectionConfig":{"issuer":os.environ["I"],"jwksuri":os.environ["J"]}}))')
  tcall POST /alias "$BODY"
  [ "$(tcode)" = 200 ] || [ "$(tcode)" = 201 ] && ok "4. alias '${ALIAS_NAME}' créé (HTTP $(tcode))" || bad "4. création de l'alias : HTTP $(tcode) $(head -c 120 "$TMP/t.body" 2>/dev/null)"
  tcall GET /alias; jfind alias "$ALIAS_NAME" >/dev/null && ok "4b. relu par nom" || bad "4b. alias absent après création"
fi

# ── 5. le login prouvé, 6. le ticket garde quelque chose ─────────────────────
tcall GET /applications
[ "$(tcode)" = 200 ] && ok "5. login prouvé : GET /applications avec les creds de Vault ⇒ 200" || bad "5. login : HTTP $(tcode)"
tcall GET /applications "" "$TERMINUS_WM_USER" "faux-$RANDOM$RANDOM"
[ "$(tcode)" = 401 ] && ok "6. un mot de passe faux ⇒ 401 (le ticket garde bien l'admin)" || bad "6. mot de passe faux : HTTP $(tcode)"

echo
printf 'RÉSULTAT : %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
