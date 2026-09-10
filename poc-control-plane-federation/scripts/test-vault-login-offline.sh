#!/usr/bin/env bash
# test-vault-login-offline.sh — la preuve HORS LIGNE que le mode debug de
# ci/lib/vault-login.sh ne fuit pas et reste utile (plan 2026-09-09, L2 / A3).
#
# CE QU'ELLE EMPÊCHE. Le debug de vault-login.sh vivait dans le fichier
# (`_vault_dbg`, `_vault_redact`, ANSI, `[vault-dbg]`, VAULT_DEBUG) avec un
# repli FAIL-OPEN : sans python3, `_vault_redact … || cat` sortait le corps
# d'erreur EN CLAIR — à l'inverse de son commentaire. Il passe désormais par
# ci/lib/dbg.sh (dbg, dbg_http, dbg_on : stderr seulement, rédaction par
# littéral connu du process et par forme, fail-closed « <rédaction
# indisponible> »). Cette suite prouve, sans lab, que CE fichier-ci tient les
# promesses de la lib qu'il consomme :
#   O.1 un login RATÉ sous STOA_DEBUG=1 dit la ligne HTTP et le message de
#       Vault (le debug est UTILE), jamais le mot de passe — ni entier, ni un
#       morceau ≥ 4, ni une forme (%XX, \uXXXX, +) ; stdout reste vide ;
#       O.1d : la COUPE à 400 caractères du corps d'erreur vient APRÈS la
#       rédaction — un secret coupé n'est plus un littéral (ni entier, ni un
#       segment) et son préfixe sortirait en clair (relecture 2026-09-10, F1) ;
#   O.2 un login RÉUSSI ne montre le token NI sur stdout NI sur stderr (un
#       corps 2xx n'est jamais imprimé) et la ligne `-> HTTP 200` est là ;
#       O.2d : cet invariant a son DISCRIMINANT — une seule ligne « ↳ erreur »
#       sur le parcours (le 403 de la preuve de mort), et aucun mot que SEUL
#       un corps 2xx porte (relecture 2026-09-10, F2 : l'absence du token était
#       portée par les FORMES de dbg.sh, pas par la lib) ;
#   O.3 STOA_DEBUG vide ⇒ silence ; VAULT_DEBUG=1 seul ⇒ silence aussi
#       (ruling L2 : STOA_DEBUG est la SEULE autorité, VAULT_DEBUG a disparu) ;
#   O.4 sans python3 sur le PATH, le corps d'erreur ne sort PAS en clair :
#       « <rédaction indisponible> », et le rc de _vault_curl est inchangé ;
#   O.5 mutations sur COPIE : un corps d'erreur écrit hors de dbg, une ligne
#       HTTP retirée, VAULT_DEBUG réintroduit, l'unset remis avant l'appel,
#       tout corps (2xx compris) passé à dbg, la coupe remise AVANT la
#       rédaction — chacune fait ROUGIR l'épreuve visée : la suite attrape ce
#       qu'elle prétend attraper ;
#   O.6 la lib trouve ci/lib/dbg.sh par les DEUX conventions de ses appelants
#       (`${SUB_PFX}ci/lib/…` puis `ci/lib/…`, la plus spécifique d'abord) et
#       REFUSE, nommé, hors de ces deux-là — un `sh -e` de Jenkins s'y arrête.
#
# GABARIT : ok/ko/joue, sentinelle, formes, toutes_absentes de
# scripts/test-dbg-redaction.sh ; D1/D2/D3 de scripts/test-vault-user-login.sh
# (277-304). Chaque épreuve d'ABSENCE est doublée d'une PRÉSENCE : sans elle
# une lib muette passerait tout (vert vacant). Là où c'est possible, c'est la
# LIGNE EXACTE qui est attendue (sensible à un masque partiel).
#
# TERRAIN : un stub HTTP python jetable joue Vault (login userpass, lookup-self,
# revoke-self, lecture KV v2) sur un port LIBRE — port 0, numéro écrit dans un
# fichier, motif de scripts/test-forge-api.sh. Son mode `echo_pwd` RECOPIE le
# mot de passe reçu dans le corps 400 sous trois formes (JSON \uXXXX, JSON
# utf-8, %XX) : un Vault réel ne le fait pas, et sans lui l'épreuve d'absence
# serait vacante. Joué sous dash, sh ET bash : la lib est sourcée par les deux
# familles (le step `sh` de Jenkins est dash sur Debian ; sur un poste macOS,
# /bin/sh est bash 3.2 en mode POSIX — une troisième mesure, gratuite).
#
#   bash scripts/test-vault-login-offline.sh
#   VAULT_LOGIN_LIB=<copie> bash scripts/test-vault-login-offline.sh   # contre une autre lib
#
# SC2016 : quotes simples voulues — les programmes sont interprétés par le
# shell SOUS TEST (dash/sh/bash), pas par ce bash. SC2034 : la suite pose des
# variables (S_O, JLIB…) que les enfants consomment par l'environnement.
# shellcheck disable=SC2016,SC2034
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
VLIB="${VAULT_LOGIN_LIB:-$REPO/ci/lib/vault-login.sh}"
TMP="$(mktemp -d /tmp/vlo.XXXXXX)"
PIDS=""
nettoie(){ for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap nettoie EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
note(){ printf '  · %s\n' "$*"; }

# ── ARDOISE PROPRE ───────────────────────────────────────────────────────────
# Le poste de l'exploitant exporte volontiers VAULT_TOKEN=root et VAULT_ADDR :
# le premier masquerait « root » partout, le second enverrait un mot de passe
# sentinelle vers un vrai Vault. La suite pose ELLE-MÊME tout ce qu'elle éprouve.
unset STOA_DEBUG VAULT_DEBUG DBG_NAME DBG_SECRET_FILES \
      FORGE_SECRET GITEA_TOKEN FORGE_TOKEN PUSH_TOKEN VAULT_TOKEN VAULT_USER_PASSWORD \
      WM_PASSWORD WM_PASS WM_BEARER LDAP_ADMIN_PASSWORD \
      CI_TOKEN_FILE PR_TOKEN_FILE VAULT_TOKEN_FILE FORGE_TOKEN_FILE \
      FORGE_USER WM_USER VAULT_USER PUSH_LOGIN \
      VAULT_ADDR VAULT_NAMESPACE VAULT_CACERT LABCTL_CA_FILE VAULT_USER_AUTH_MOUNT \
      USER_VAULT_JWT VAULT_USER_PASS VAULT_LDAP_PASS VAULT_USER_PASS_FILE VAULT_LDAP_PASS_FILE \
      VAULT_LDAP_USER SUB_PFX

OUT="$TMP/out"; ERR="$TMP/err"; RCF="$TMP/rc"
rrc(){ cat "$RCF"; }
absent(){ ! grep -qF -- "$1" "$ERR" && ! grep -qF -- "$1" "$OUT"; }
present_err(){ grep -qF -- "$1" "$ERR"; }
ligne_err(){ grep -q -- "$1" "$ERR"; }   # motif (regex) sur stderr
stdout_vide(){ [ ! -s "$OUT" ]; }
MASQUE='<secret masqué>'
INDISPO='<rédaction indisponible>'

# sentinelle <tag> → « Zs<tag>X/9<pid>@q<tag> pq<tag>X<TAB>tt<tag>é » : un « / »,
# un « @ », un espace, une tabulation, un caractère accentué — chacun s'échappe
# autrement selon le transport. Chaque segment (coupé à « / » ou aux blancs)
# fait ≥ 4 caractères : un morceau qui fuit est détectable.
sentinelle(){ printf 'Zs%sX/9%s@q%s pq%sX\ttt%sé' "$1" "$$" "$1" "$1" "$1"; }
# Les encodages qu'un transport applique à un secret — calculés par python,
# pas par la lib sous test (sinon la preuve tournerait en rond).
forme_json(){ S="$1" python3 -c 'import json,os; print(json.dumps(os.environ["S"])[1:-1])'; }
formes(){ S="$1" python3 -c '
import json, os, re
from urllib.parse import quote, quote_plus
v = os.environ["S"]; out = set()
for x in [v] + [s for s in re.split(r"[/\s]+", v) if len(s) >= 4]:
    j = json.dumps(x)[1:-1]
    for f in (x, j, j.replace("/", "\\/"), json.dumps(x, ensure_ascii=False)[1:-1], quote(x, safe=""), quote_plus(x, safe="")):
        out.add(f)
print("\n".join(sorted(out)))'; }
# toutes_absentes <secret> — aucune forme d'aucun morceau ne paraît (stdout ni stderr).
toutes_absentes(){
  local f
  while IFS= read -r f; do absent "$f" || return 1; done < <(formes "$1")
}
# prefixes_absents <secret> — aucun PRÉFIXE (≥ 4) du premier segment ne paraît.
# C'est la trace d'un littéral COUPÉ avant d'être rédigé (O.1d) : formes() ne
# connaît que les segments ENTIERS, et redact non plus — un préfixe qui fuit
# passe donc sous toutes_absentes. Ici, chaque longueur de 4 au segment entier.
prefixes_absents(){
  local seg="${1%%/*}" n=4
  while [ "$n" -le "${#seg}" ]; do absent "$(printf '%s' "$seg" | cut -c1-"$n")" || return 1; n=$((n+1)); done
}

if [ ! -f "$VLIB" ]; then
  ko "0.0 la lib n'existe pas : $VLIB — tout ce qui suit est ROUGE par construction"
fi

# ── LE STUB VAULT ────────────────────────────────────────────────────────────
# Mime EXACTEMENT ce que la lib appelle : POST /v1/auth/<mount>/login/<user>
# (corps JSON {"password": …}), GET /v1/auth/token/lookup-self (en-tête
# X-Vault-Token lu d'un fichier), POST /v1/auth/token/revoke-self (204, puis
# lookup-self ⇒ 403 : la preuve de mort), GET /v1/secret/data/… (KV v2). Le
# mode vient d'un fichier de contrôle relu à CHAQUE requête : `ok`, `echo_pwd`
# (le corps 400 recopie le mot de passe — voir en tête) ou `echo_pwd_400` (il
# le recopie APRÈS un long message, à cheval sur la coupe de la lib — O.1d).
CTL="$TMP/ctl"; LOG="$TMP/stub.log"
TOKEN="hvs.STUBtoken${$}0123456789abcdefghij"   # ≥ 8 après « hvs. » : la forme le voit aussi
KV_PASS="kv-valeur-secrete-${$}-Q7"
# La COUPE de la lib (`cut -c1-400` de _vault_curl) et le corps qui la met à
# l'épreuve : TETE + NPAD × « F » + « ", » puis le mot de passe entre quotes,
# calé pour que ses AVANT premiers caractères précèdent la frontière — la coupe
# tombe DANS le mot de passe. Un seul calcul, partagé avec le stub (STUB_*) et
# avec la ligne EXACTE attendue par O.1d.
COUPE=400; AVANT=8
TETE='{"errors": ["canari-bind-KO", "'
NPAD=$((COUPE - AVANT - ${#TETE} - 4))          # 4 = « ", " » entre le remplissage et le mot de passe
PAD="$(printf '%*s' "$NPAD" '' | tr ' ' F)"
cat > "$TMP/stub.py" <<'PY'
import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote
CTL, LOG = os.environ["STUB_CTL"], os.environ["STUB_LOG"]
TOKEN, KV_PASS = os.environ["STUB_TOKEN"], os.environ["STUB_KV"]
TETE, NPAD = os.environ["STUB_TETE"], int(os.environ["STUB_NPAD"])
etat = {"revoque": False}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def mode(self):
        try: return open(CTL).read().strip()
        except OSError: return "ok"
    def corps(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def js(self, code, obj=None, brut=None):
        b = brut if brut is not None else json.dumps(obj).encode("utf-8")
        self.send_response(code)
        if b:
            self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        if b: self.wfile.write(b)
    def token_ok(self):
        return self.headers.get("X-Vault-Token") == TOKEN and not etat["revoque"]
    def route(self, method):
        p = self.path
        open(LOG, "a").write(method + " " + p + "\n")
        if method == "POST" and p.startswith("/v1/auth/userpass/login/"):
            try: pwd = json.loads(self.corps().decode("utf-8")).get("password", "")
            except Exception: pwd = ""
            if self.mode() == "echo_pwd":
                # Un Vault réel ne recopie pas le mot de passe ; ce stub le fait, sous
                # trois formes, pour que l'épreuve d'absence ne soit pas vacante.
                brut = ('{"errors": ["canari-bind-KO", %s, %s, "%s"]}'
                        % (json.dumps(pwd), json.dumps(pwd, ensure_ascii=False), quote(pwd, safe=""))).encode("utf-8")
                return self.js(400, brut=brut)
            if self.mode() == "echo_pwd_400":
                # O.1d : le mot de passe recopié LOIN dans le corps, à cheval sur la
                # coupe de la lib (NPAD calculé par le harnais, une seule formule).
                brut = (TETE + "F" * NPAD + '", ' + json.dumps(pwd) + "]}").encode("utf-8")
                return self.js(400, brut=brut)
            etat["revoque"] = False
            return self.js(200, {"auth": {"client_token": TOKEN, "policies": ["default", "deploy-alice"],
                                          "entity_id": "ent-stub-1", "lease_duration": 600}})
        if not self.token_ok():
            return self.js(403, {"errors": ["permission denied"]})
        if p == "/v1/auth/token/lookup-self" and method == "GET":
            return self.js(200, {"data": {"display_name": "userpass-alice", "entity_id": "ent-stub-1",
                                          "ttl": 600, "policies": ["default", "deploy-alice"]}})
        if p == "/v1/auth/token/revoke-self" and method == "POST":
            etat["revoque"] = True
            return self.js(204, brut=b"")
        if p.startswith("/v1/secret/data/") and method == "GET":
            return self.js(200, {"data": {"data": {"username": "svc-stub", "password": KV_PASS}}})
        return self.js(404, {"errors": ["route inconnue " + p]})
    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
PY
start_stub(){ # → imprime l'URL
  local port
  STUB_CTL="$CTL" STUB_LOG="$LOG" STUB_TOKEN="$TOKEN" STUB_KV="$KV_PASS" STUB_TETE="$TETE" STUB_NPAD="$NPAD" \
    python3 "$TMP/stub.py" > "$TMP/port" 2>"$TMP/stub.err" &
  PIDS="$PIDS $!"
  for _ in $(seq 1 60); do [ -s "$TMP/port" ] && break; sleep 0.1; done
  port="$(head -n1 "$TMP/port")"; case "$port" in ''|*[!0-9]*) echo "!! stub Vault non démarré : $(cat "$TMP/stub.err")"; exit 2;; esac
  printf 'http://127.0.0.1:%s' "$port"
}
VADDR="$(start_stub)"
set_mode(){ printf '%s' "$1" > "$CTL"; : > "$LOG"; }

# joue <shell> <programme> [args…] — exécute <programme> sous `<shell> -c`, la
# lib ($JLIB, par défaut la vraie ; une COPIE mutée en O.5) en $1, l'adresse du
# stub en $2, les args suivants à partir de $3 ; stdout → $OUT, stderr → $ERR,
# rc → $RCF. Les secrets arrivent par l'ENVIRONNEMENT (préfixe S_O=…), jamais
# en argument : ps ne doit rien voir, même d'un harnais.
JLIB=""
joue(){
  local shell="$1" prog="$2"; shift 2
  "$shell" -c "$prog" sh "${JLIB:-$VLIB}" "$VADDR" "$@" >"$OUT" 2>"$ERR"
  echo $? > "$RCF"
}
# Les programmes. `set -u` APRÈS le source : la lib doit y survivre — le
# prélude pose l'identité d'alice sur le mount userpass du stub.
PRELUDE='. "$1" || exit 99; set -u
export VAULT_ADDR="$2" VAULT_USER_AUTH_MOUNT=userpass VAULT_USER=alice VAULT_USER_PASSWORD="$S_O"
unset USER_VAULT_JWT'
P_LOGIN="$PRELUDE"'
vault_login_nominative'
# O.2 : le token va dans un FICHIER ($3), jamais sur stdout ; puis une lecture
# KV (le produit sur stdout), puis la révocation avec preuve de mort.
P_OK="$PRELUDE"'
vault_login_nominative || exit 3
cat "$VAULT_TOKEN_FILE" > "$3"
vault_read secret/data/stoa/demo password
vault_revoke_proof'
# O.4 : _vault_curl SEUL, PATH réduit à $4 (le corps est préparé par le harnais).
P_CURL='. "$1" || exit 99; set -u
export VAULT_USER_PASSWORD="$S_O"
PATH="$4"
_vault_curl "$3/o4.out" POST "$2/v1/auth/userpass/login/alice" -H "Content-Type: application/json" --data-binary "@$3/o4.body" > "$3/o4.code"
echo "rc=$?"'

SHELLS=""
for shell in dash sh bash; do
  if command -v "$shell" >/dev/null 2>&1; then SHELLS="$SHELLS $shell"
  else note "$shell absent de cette machine — ses épreuves sont sautées (non comptées)"; fi
done

for shell in $SHELLS; do
  echo "═══ O.1 [$shell] login RATÉ sous STOA_DEBUG=1, stub echo_pwd : utile, sans le mot de passe, stdout vide ═══"
  set_mode echo_pwd
  S_O="$(sentinelle O1)"
  S_O="$S_O" STOA_DEBUG=1 joue "$shell" "$P_LOGIN"
  if [ "$(rrc)" = 1 ] && stdout_vide && present_err "] POST $VADDR/v1/auth/userpass/login/alice -> HTTP 400" \
     && present_err 'canari-bind-KO' && toutes_absentes "$S_O"; then
    ok "O.1 [$shell] rc 1, stdout VIDE ; « ] POST …/v1/auth/userpass/login/alice -> HTTP 400 » et « canari-bind-KO » PRÉSENTS ; la sentinelle ABSENTE (entière, morceaux ≥ 4, formes %XX / \\uXXXX / +)"
  else ko "O.1 [$shell] rc $(rrc) — stdout '$(head -c 80 "$OUT")' — $(grep -n -F -- "${S_O%%/*}" "$ERR" | head -1 | cut -c1-120) — $(grep 'HTTP 400' "$ERR" | head -1)"; fi
  # La ligne EXACTE du corps d'erreur : les trois formes recopiées par le stub
  # sont masquées d'un seul tenant — un masque troué (« <secret masqué>%2F… »)
  # ou une forme oubliée rougirait ici, pas seulement dans toutes_absentes.
  if grep -qF "]   ↳ erreur: {\"errors\": [\"canari-bind-KO\", \"$MASQUE\", \"$MASQUE\", \"$MASQUE\"]}" "$ERR"; then
    ok "O.1b [$shell] la ligne « ↳ erreur: » est EXACTEMENT le corps 400 avec ses trois formes du mot de passe masquées (\\uXXXX, utf-8, %XX)"
  else ko "O.1b [$shell] $(grep 'erreur:' "$ERR" | head -1 | cut -c1-160)"; fi
  if ligne_err '\] empreinte mot de passe: [0-9][0-9]* caractères / [0-9][0-9]* octets  sha256=[0-9a-f]\{16\}  (aucun blanc parasite)$' \
     && ligne_err '\] voie A (user/pwd) : mount=auth/userpass  user=alice$' \
     && present_err 'auth/userpass/login REFUSÉ (HTTP 400)' \
     && ! grep -q 'vault-dbg' "$ERR" && ! grep -q "$(printf '\033')" "$ERR"; then
    ok "O.1c [$shell] le contexte (voie A, mount, user) et l'EMPREINTE du mot de passe sont dits, le refus nommé ; plus de « [vault-dbg] », plus d'ANSI"
  else ko "O.1c [$shell] $(tr '\n' '|' < "$ERR" | cut -c1-240)"; fi
  # O.1d — la coupe à 400 caractères tombe DANS le mot de passe (AVANT=8 de
  # ses caractères la précèdent). Coupé AVANT la rédaction, ce préfixe n'est
  # ni le littéral entier ni un segment : il sortirait en clair (relecture
  # 2026-09-10, F1 ; mutant M6). Le tag est LONG à dessein : le premier segment
  # « Zs<tag>X » doit dépasser AVANT, sinon le segment entier serait visible et
  # masqué par littéral — et l'épreuve ne verrait rien. La ligne attendue est
  # EXACTE : les 400 premiers caractères du corps RÉDIGÉ, donc « …", "<secret »
  # (le masque coupé, jamais le mot de passe coupé) — un cut retiré ou déplacé
  # rougit ici.
  set_mode echo_pwd_400
  S_O="$(sentinelle Tronc400)"
  S_O="$S_O" STOA_DEBUG=1 joue "$shell" "$P_LOGIN"
  if [ "$(rrc)" = 1 ] && stdout_vide && present_err "] POST $VADDR/v1/auth/userpass/login/alice -> HTTP 400" \
     && grep -qxF "[dbg sh]   ↳ erreur: ${TETE}${PAD}\", \"<secret " "$ERR" \
     && prefixes_absents "$S_O" && toutes_absentes "$S_O"; then
    ok "O.1d [$shell] mot de passe à cheval sur la coupe ($AVANT caractères avant la frontière des $COUPE) : la ligne « ↳ erreur » est EXACTEMENT les $COUPE premiers caractères du corps RÉDIGÉ (finit par « \", \"<secret ») ; aucun préfixe ≥ 4 du mot de passe, aucune forme"
  else ko "O.1d [$shell] rc $(rrc) — fin de ligne : « $(grep 'erreur:' "$ERR" | head -1 | cut -c400-440) »"; fi

  echo "═══ O.2 [$shell] login RÉUSSI sous STOA_DEBUG=1 : le token n'est NI sur stdout NI sur stderr ═══"
  set_mode ok
  S_O="$(sentinelle O2)"; : > "$TMP/tok"
  S_O="$S_O" STOA_DEBUG=1 joue "$shell" "$P_OK" "$TMP/tok"
  if [ "$(rrc)" = 0 ] && [ "$(cat "$TMP/tok")" = "$TOKEN" ] && absent "$TOKEN" && toutes_absentes "$S_O" \
     && present_err "] POST $VADDR/v1/auth/userpass/login/alice -> HTTP 200" \
     && present_err "] GET $VADDR/v1/auth/token/lookup-self -> HTTP 200"; then
    ok "O.2 [$shell] rc 0, VAULT_TOKEN_FILE posé et son contenu = le token du stub ; le token ABSENT de stdout et stderr (corps 2xx jamais imprimé) ; « -> HTTP 200 » PRÉSENT (login et lookup-self)"
  else ko "O.2 [$shell] rc $(rrc) tok='$(head -c 12 "$TMP/tok")…' — $(grep -n -F -- "$TOKEN" "$ERR" "$OUT" | head -1 | cut -c1-100) — $(grep 'HTTP' "$ERR" | head -2 | tr '\n' '|')"; fi
  if grep -qx -- "$KV_PASS" "$OUT" && ! grep -qF -- "$KV_PASS" "$ERR" && ! grep -q '^\[dbg' "$OUT" \
     && present_err "] GET $VADDR/v1/secret/data/stoa/demo -> HTTP 200" \
     && ligne_err '\]   ↳ champs disponibles: password,username$' \
     && grep -q 'token Vault NOMINATIF — entité=userpass-alice' "$OUT"; then
    ok "O.2b [$shell] vault_read : la VALEUR est le produit (stdout, seule), jamais sur stderr ; le debug ne dit que les CLÉS (password,username) et la ligne HTTP ; aucune ligne [dbg sur stdout"
  else ko "O.2b [$shell] stdout '$(tr '\n' '|' < "$OUT" | cut -c1-160)' — $(grep 'champs\|secret/data' "$ERR" | tr '\n' '|' | cut -c1-200)"; fi
  if present_err "] POST $VADDR/v1/auth/token/revoke-self -> HTTP 204" \
     && present_err "] GET $VADDR/v1/auth/token/lookup-self -> HTTP 403" \
     && present_err '↳ erreur: {"errors": ["permission denied"]}' \
     && grep -q 'mort PROUVÉE (lookup-self -> 403)' "$OUT"; then
    ok "O.2c [$shell] révocation + preuve de mort tracées (204 puis 403) ; le corps 403 « permission denied » est dit — un corps d'erreur SANS secret reste lisible"
  else ko "O.2c [$shell] $(grep 'revoke\|403' "$ERR" "$OUT" | tr '\n' '|' | cut -c1-240)"; fi
  # O.2d — le DISCRIMINANT de « un corps 2xx n'est JAMAIS imprimé » (relecture
  # 2026-09-10, F2 ; mutant M5). Sur ce parcours (login 200, lookup-self 200,
  # KV 200, revoke 204, lookup-self 403), la SEULE ligne « ↳ erreur » est celle
  # du 403 ; et aucun mot que SEUL un corps 2xx porte et qu'aucune forme ne
  # masque — lease_duration (login), display_name (lookup-self), svc-stub (KV)
  # — ne touche stderr. Sans cette épreuve, l'absence du token (O.2) et de la
  # valeur KV (O.2b) tenait aux FORMES de dbg.sh (hvs., clé token/password),
  # pas à la propriété de la lib : un mutant qui passait TOUT corps à dbg
  # restait 54/54.
  if [ "$(grep -c '↳ erreur:' "$ERR")" = 1 ] && ! grep -qF 'lease_duration' "$ERR" \
     && ! grep -qF 'display_name' "$ERR" && ! grep -qF 'svc-stub' "$ERR"; then
    ok "O.2d [$shell] une SEULE ligne « ↳ erreur » (le 403 de la preuve de mort) ; ni lease_duration, ni display_name, ni svc-stub sur stderr : les corps 2xx (login, lookup-self, KV) ne passent PAS par dbg"
  else ko "O.2d [$shell] $(grep -c '↳ erreur:' "$ERR") lignes « ↳ erreur » — $(grep 'lease_duration\|display_name\|svc-stub' "$ERR" | head -1 | cut -c1-160)"; fi

  echo "═══ O.3 [$shell] STOA_DEBUG vide ⇒ silence ; VAULT_DEBUG=1 seul ⇒ silence (STOA_DEBUG est la seule autorité) ═══"
  set_mode echo_pwd
  S_O="$(sentinelle O3)"
  S_O="$S_O" joue "$shell" "$P_LOGIN"
  if [ "$(rrc)" = 1 ] && ! grep -q '\[dbg' "$ERR" && ! grep -q 'vault-dbg' "$ERR" \
     && present_err 'auth/userpass/login REFUSÉ (HTTP 400)' && toutes_absentes "$S_O" && stdout_vide; then
    ok "O.3 [$shell] STOA_DEBUG absent : aucune ligne « [dbg », le refus « REFUSÉ (HTTP 400) » est quand même nommé (le login a bien eu lieu), la sentinelle absente"
  else ko "O.3 [$shell] rc $(rrc) — $(tr '\n' '|' < "$ERR" | cut -c1-200)"; fi
  S_O="$S_O" VAULT_DEBUG=1 joue "$shell" "$P_LOGIN"
  if [ "$(rrc)" = 1 ] && ! grep -q '\[dbg' "$ERR" && ! grep -q 'vault-dbg' "$ERR" \
     && present_err 'auth/userpass/login REFUSÉ (HTTP 400)' && toutes_absentes "$S_O"; then
    ok "O.3b [$shell] VAULT_DEBUG=1 seul : aucune ligne — l'ancien knob n'existe plus (ruling L2 : STOA_DEBUG est la seule autorité, comme pour toute la chaîne)"
  else ko "O.3b [$shell] rc $(rrc) — $(tr '\n' '|' < "$ERR" | cut -c1-200)"; fi

  echo "═══ O.4 [$shell] python3 RETIRÉ du PATH : le fail-open est FERMÉ (« $INDISPO », jamais le corps en clair) ═══"
  # PATH réduit à un répertoire de shims SANS python3 (section G de
  # test-dbg-redaction.sh) : _vault_curl n'a besoin que de curl, tr et cut ;
  # cat y est AUSSI, pour que l'ancien repli « || cat » puisse montrer sa fuite.
  set_mode echo_pwd
  S_O="$(sentinelle O4)"
  mkdir -p "$TMP/shims"; rm -f "$TMP/shims"/*
  for outil in curl tr cut cat; do ln -s "$(command -v "$outil")" "$TMP/shims/$outil"; done
  printf '{"password": "%s"}' "$(forme_json "$S_O")" > "$TMP/o4.body"
  # Référence : même appel avec le PATH complet — le rc et le code doivent être les mêmes.
  S_O="$S_O" STOA_DEBUG=1 joue "$shell" "$P_CURL" "$TMP" "$PATH"
  REF_RC="$(cat "$OUT")"; REF_CODE="$(cat "$TMP/o4.code")"; cp "$ERR" "$TMP/o4.err-ref"
  S_O="$S_O" STOA_DEBUG=1 joue "$shell" "$P_CURL" "$TMP" "$TMP/shims"
  if [ "$REF_RC" = "rc=0" ] && [ "$REF_CODE" = 400 ] && grep -qF "$MASQUE" "$TMP/o4.err-ref" && ! grep -qF -- "${S_O%%/*}" "$TMP/o4.err-ref"; then
    ok "O.4a [$shell] (référence, python3 présent) rc=0, code 400, corps masqué « $MASQUE »"
  else ko "O.4a [$shell] référence : '$REF_RC' code '$REF_CODE' — $(head -2 "$TMP/o4.err-ref" | tr '\n' '|' | cut -c1-160)"; fi
  if [ "$(cat "$OUT")" = "$REF_RC" ] && [ "$(cat "$TMP/o4.code")" = "$REF_CODE" ] \
     && [ "$(grep -cx -- "$INDISPO" "$ERR")" -ge 1 ] && [ "$(grep -cvx -- "$INDISPO" "$ERR")" = 0 ] && toutes_absentes "$S_O"; then
    ok "O.4b [$shell] sans python3 : stderr = $(grep -cx -- "$INDISPO" "$ERR") × « $INDISPO » et RIEN d'autre (la ligne HTTP comprise), zéro sentinelle, rc et code inchangés — l'ancien « || cat » sortait le corps EN CLAIR"
  else ko "O.4b [$shell] rc '$(cat "$OUT")' code '$(cat "$TMP/o4.code")' — stderr: $(tr '\n' '|' < "$ERR" | cut -c1-200)"; fi
done

echo "═══ O.5 mutations sur COPIE de vault-login.sh : chaque épreuve rougit sur le défaut qu'elle vise ═══"
# mute <étiquette> <sed> — écrit $TMP/mut-<étiquette>.sh ; ko si no-op (l'ancre
# a disparu : l'épreuve ne prouverait plus rien) ou incompilable.
mute(){
  local et="$1" expr="$2" lib="$TMP/mut-$1.sh"
  [ -f "$VLIB" ] || { ko "$et pas de lib à muter"; return 1; }
  sed "$expr" "$VLIB" > "$lib"
  if cmp -s "$VLIB" "$lib" || ! sh -n "$lib" 2>/dev/null; then
    ko "$et mutant no-op ou incompilable — l'ancre a changé de forme, l'épreuve ne prouve plus rien"; return 1
  fi
  return 0
}
# M1 — le corps d'erreur écrit HORS de dbg (l'ancien fail-open, en pire) ⇒ O.1 rougit.
if mute M1 's/^\( *\)dbg "  ↳ erreur: .*$/\1printf '\''%s\\n'\'' "$(cat "$out")" >\&2/'; then
  for shell in $SHELLS; do
    set_mode echo_pwd; S_O="$(sentinelle M1)"
    S_O="$S_O" STOA_DEBUG=1 JLIB="$TMP/mut-M1.sh" joue "$shell" "$P_LOGIN"
    if ! toutes_absentes "$S_O" && grep -qF 'canari-bind-KO' "$ERR"; then
      ok "M1 [$shell] « ↳ erreur » remplacé par printf du corps ⇒ la sentinelle SORT (O.1 rougit : c'est bien dbg qui rédige)"
    else ko "M1 [$shell] le mutant passe encore : $(grep 'canari' "$ERR" | head -1 | cut -c1-120)"; fi
  done
fi
# M2 — la ligne HTTP retirée ⇒ la PRÉSENCE de O.1 rougit (l'absence seule serait vacante).
if mute M2 '/^ *dbg_http "\$method" "\$url" "\$code"$/d'; then
  for shell in $SHELLS; do
    set_mode echo_pwd; S_O="$(sentinelle M2)"
    S_O="$S_O" STOA_DEBUG=1 JLIB="$TMP/mut-M2.sh" joue "$shell" "$P_LOGIN"
    if ! present_err "] POST $VADDR/v1/auth/userpass/login/alice -> HTTP 400" && present_err 'canari-bind-KO'; then
      ok "M2 [$shell] dbg_http retiré ⇒ plus de « -> HTTP 400 » (O.1 rougit sur sa présence : le debug DOIT rester utile)"
    else ko "M2 [$shell] le mutant passe encore : $(grep 'HTTP 400' "$ERR" | head -1 | cut -c1-120)"; fi
  done
fi
# M3 — VAULT_DEBUG réintroduit comme second knob ⇒ O.3b rougit (le ruling est éprouvé, pas supposé).
if mute M3 's/^_VAULT_REVOKED=0$/_VAULT_REVOKED=0; [ -z "${VAULT_DEBUG:-}" ] || STOA_DEBUG=1/'; then
  for shell in $SHELLS; do
    set_mode echo_pwd; S_O="$(sentinelle M3)"
    S_O="$S_O" VAULT_DEBUG=1 JLIB="$TMP/mut-M3.sh" joue "$shell" "$P_LOGIN"
    if grep -q '^\[dbg ' "$ERR"; then
      ok "M3 [$shell] VAULT_DEBUG réintroduit ⇒ des lignes « [dbg » paraissent sous VAULT_DEBUG=1 seul (O.3b rougit)"
    else ko "M3 [$shell] le mutant passe encore : $(head -1 "$ERR" | cut -c1-120)"; fi
  done
fi
# M4 — l'`unset VAULT_USER_PASSWORD` remis AVANT l'appel (là où il était avant
# la migration) ⇒ au moment du « ↳ erreur », le process ne TIENT plus le
# littéral et dbg ne peut plus le masquer : la sentinelle sort (O.1 rougit).
# C'est le défaut que le premier rouge de cette suite a révélé (2026-09-10).
if mute M4 's/^  code="\$(_vault_curl "\$resp" POST "\$url"/  unset VAULT_USER_PASSWORD; &/'; then
  for shell in $SHELLS; do
    set_mode echo_pwd; S_O="$(sentinelle M4)"
    S_O="$S_O" STOA_DEBUG=1 JLIB="$TMP/mut-M4.sh" joue "$shell" "$P_LOGIN"
    if ! toutes_absentes "$S_O" && present_err "] POST $VADDR/v1/auth/userpass/login/alice -> HTTP 400"; then
      ok "M4 [$shell] unset du mot de passe remis AVANT l'appel ⇒ la sentinelle SORT du corps 400 (O.1 rougit : le littéral doit être TENU au moment du dbg)"
    else ko "M4 [$shell] le mutant passe encore : $(grep 'erreur:' "$ERR" | head -1 | cut -c1-120)"; fi
  done
fi
# M5 — TOUT corps passé à dbg (`[45]??)` → `*)`) ⇒ O.2d rougit : les corps du
# login, du lookup-self et de la lecture KV paraissent sur stderr (leurs
# secrets rattrapés par la FORME — mais l'invariant de la lib, lui, est mort).
# Relecture 2026-09-10, F2 : sans O.2d ce mutant passait 54/54.
if mute M5 's/^      \[45\]??)$/      *)/'; then
  for shell in $SHELLS; do
    set_mode ok; S_O="$(sentinelle M5)"; : > "$TMP/tok"
    S_O="$S_O" STOA_DEBUG=1 JLIB="$TMP/mut-M5.sh" joue "$shell" "$P_OK" "$TMP/tok"
    if [ "$(grep -c '↳ erreur:' "$ERR")" -gt 1 ] && grep -qF 'lease_duration' "$ERR" && grep -qF 'svc-stub' "$ERR"; then
      ok "M5 [$shell] tout corps passé à dbg ⇒ $(grep -c '↳ erreur:' "$ERR") lignes « ↳ erreur », dont lease_duration (login 200) et svc-stub (KV 200) : O.2d rougit"
    else ko "M5 [$shell] le mutant passe encore : $(grep -c '↳ erreur:' "$ERR") lignes ↳ erreur — $(grep 'erreur:' "$ERR" | head -1 | cut -c1-120)"; fi
  done
fi
# M6 — la COUPE remise AVANT la rédaction (`redact < "$out" | tr | cut` →
# `cat "$out" | tr | cut` : le corps BRUT est coupé, dbg ne voit qu'un préfixe
# du mot de passe) ⇒ O.1d rougit : AVANT caractères du mot de passe sortent en
# clair. Relecture 2026-09-10, F1 : c'était la lettre du brief.
if mute M6 's/\$(redact < "\$out" | tr/$(cat "$out" | tr/'; then
  for shell in $SHELLS; do
    set_mode echo_pwd_400; S_O="$(sentinelle M6tronc400)"
    S_O="$S_O" STOA_DEBUG=1 JLIB="$TMP/mut-M6.sh" joue "$shell" "$P_LOGIN"
    if ! prefixes_absents "$S_O" && present_err "] POST $VADDR/v1/auth/userpass/login/alice -> HTTP 400"; then
      ok "M6 [$shell] coupe AVANT rédaction ⇒ la ligne finit par « $(grep 'erreur:' "$ERR" | head -1 | cut -c$((COUPE + 8))-$((COUPE + 30)))» : un préfixe du mot de passe SORT en clair (O.1d rougit)"
    else ko "M6 [$shell] le mutant passe encore : « $(grep 'erreur:' "$ERR" | head -1 | cut -c400-440) »"; fi
  done
fi

echo "═══ O.6 où la lib cherche ci/lib/dbg.sh : les deux conventions de ses appelants, et un refus NOMMÉ ailleurs ═══"
# Les appelants : `. ci/lib/vault-login.sh` (7 Jenkinsfile, cwd = racine du
# livrable) et `. "${SUB_PFX}ci/lib/vault-login.sh"` (carto-secrets.sh, cwd =
# racine du dépôt). POSIX oblige (pas de BASH_SOURCE), la lib essaie
# `${SUB_PFX:-}ci/lib/dbg.sh` PUIS `ci/lib/dbg.sh` — et rien d'autre.
for shell in $SHELLS; do
  ( cd "$TMP" && "$shell" -c '. "$1"; echo "rc=$?"' sh "$VLIB" ) >"$OUT" 2>"$ERR"
  if grep -qx 'rc=1' "$OUT" && grep -qF "ERREUR: ci/lib/dbg.sh introuvable (cherché : ci/lib/dbg.sh et ci/lib/dbg.sh depuis $TMP ; SUB_PFX=<vide>) — vault-login.sh se source depuis la racine du livrable" "$ERR"; then
    ok "O.6a [$shell] hors de la racine, sans SUB_PFX : « . lib » rend 1 et NOMME les deux chemins cherchés, le cwd et le knob"
  else ko "O.6a [$shell] stdout '$(cat "$OUT")' stderr '$(head -1 "$ERR" | cut -c1-200)'"; fi
  ( cd "$TMP" && "$shell" -ec '. "$1"; echo survecu' sh "$VLIB" ) >"$OUT" 2>"$ERR"
  if ! grep -q survecu "$OUT" && present_err 'ERREUR: ci/lib/dbg.sh introuvable'; then
    ok "O.6b [$shell] sous « sh -e » (le bloc sh de Jenkins) : le step S'ARRÊTE sur le refus — jamais un login sans sa rédaction"
  else ko "O.6b [$shell] stdout '$(cat "$OUT")'"; fi
  ( cd "$TMP" && SUB_PFX="$REPO/" "$shell" -c '. "$1" || exit 99; STOA_DEBUG=1 dbg "trouvée par SUB_PFX"; echo "rc=$?"' sh "$VLIB" ) >"$OUT" 2>"$ERR"
  if grep -qx 'rc=0' "$OUT" && grep -qx '\[dbg sh\] trouvée par SUB_PFX' "$ERR"; then
    ok "O.6c [$shell] hors de la racine AVEC SUB_PFX=<racine>/ (convention carto-secrets.sh) : dbg.sh trouvée, dbg parle"
  else ko "O.6c [$shell] stdout '$(cat "$OUT")' stderr '$(head -1 "$ERR" | cut -c1-160)'"; fi
  ( SUB_PFX="$TMP/nulle-part/" "$shell" -c '. "$1" || exit 99; STOA_DEBUG=1 dbg "trouvée à la racine"; echo "rc=$?"' sh "$VLIB" ) >"$OUT" 2>"$ERR"
  if grep -qx 'rc=0' "$OUT" && grep -qx '\[dbg sh\] trouvée à la racine' "$ERR"; then
    ok "O.6d [$shell] à la racine du livrable avec un SUB_PFX qui n'y mène pas (le job Jenkins l'exporte pour un autre cwd) : repli sur ci/lib/dbg.sh"
  else ko "O.6d [$shell] stdout '$(cat "$OUT")' stderr '$(head -1 "$ERR" | cut -c1-160)'"; fi
done

printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
