#!/usr/bin/env bash
# test-archive-store.sh — porte de preuve du TRANSPORT adressé par le contenu
# (scripts/lib/archive-store.sh, jalon G5, ADR-079 C3).
#
# Stub HTTP local (python3, http.server), port ÉPHÉMÈRE (bind 0, port réel
# récupéré au démarrage) : PUT stocke en mémoire (201 ; re-PUT sur un chemin
# déjà occupé -> 409), GET sert ce qui est stocké (200/404), et DEUX modes de
# panne pilotés par le CHEMIN demandé (team="erreur" -> 500 ; team="corrompu"
# -> 200 mais d'AUTRES octets que ceux réellement stockés). Chaque requête est
# journalisée (méthode, chemin, présence de l'en-tête Authorization) dans un
# fichier que les cas relisent — jamais par un pipe (set -uo pipefail : `cmd |
# grep -q X` masquerait le code de sortie de `cmd`), toujours capture-fichier
# puis grep du fichier, motif des harnais frères (cf. test-env-chain.sh,
# test-palier-retention.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/archive-store.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

TMP="$(mktemp -d)"; trap 'kill "${STUB_PID:-0}" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM
umask 077

# Même décommenteur STRICT que test-palier-retention.sh (nc_strict), NÉCESSAIRE
# ici : le décommenteur naïf `sed 's/[[:space:]]*#.*$//'` (utilisé ailleurs)
# accepte ZÉRO blanc avant le `#`, donc il coupe aussi au `#` de l'expansion de
# longueur `${#sha}` — présente deux fois dans cette lib (push ET fetch). Sans
# ce garde-fou, la ligne `[ "${#sha}" -eq 64 ] || { ... }` serait tronquée et
# les comptes de ⑪ mesureraient un fichier mutilé, pas le code réel.
nc_strict() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]][[:space:]]*#.*$//' "$1"; }

# ── stub HTTP (un seul fichier heredoc) ──────────────────────────────────────
STUB_LOG="$TMP/stub.log"; : > "$STUB_LOG"
cat > "$TMP/stub.py" <<'PY'
import os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = os.environ["STUB_LOG"]
STORE = {}

class H(BaseHTTPRequestHandler):
    def _log(self, method):
        # visage gitea : "Authorization" (1/0, forme conservée pour ne pas
        # rompre les cas ①-⑪ qui grep "PUT <chemin> 1") ; visage gitlab :
        # l'en-tête est PRIVATE-TOKEN, un nom DIFFERENT — sans ce troisieme
        # cas le journal dirait "0" pour une requete pourtant authentifiee.
        if self.headers.get("PRIVATE-TOKEN"):
            auth = "PRIVATE-TOKEN"
        elif self.headers.get("Authorization"):
            auth = "1"
        else:
            auth = "0"
        with open(LOG, "a") as f:
            f.write("%s %s %s\n" % (method, self.path, auth))

    def _reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._log("GET")
        path = self.path
        # ROUTE « PRÉSIGNÉE » (registre sur object storage — GitLab
        # proxy_download=false, défaut de GitLab.com et des installs HA) : le
        # chemin du paquet rend 302 vers /blob/<chemin>, qui sert les octets.
        # /blob D'ABORD : la cible porte le même segment "redir" que la source.
        if path.startswith("/blob/"):
            body = STORE.get(path[len("/blob"):])
            self._reply(404 if body is None else 200, body or b"stub: chemin inconnu")
            return
        if "redir" in path:
            self.send_response(302)
            self.send_header("Location", "/blob" + path)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if "erreur" in path:
            self._reply(500, b"stub: panne simulee")
            return
        if "corrompu" in path:
            self._reply(200, b"OCTETS-CORROMPUS-JAMAIS-CEUX-ATTENDUS")
            return
        body = STORE.get(path)
        if body is None:
            self._reply(404, b"stub: chemin inconnu")
        else:
            self._reply(200, body)

    def do_PUT(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        self._log("PUT")
        path = self.path
        if "erreur" in path:
            self._reply(500, b"stub: panne simulee")
            return
        if path in STORE:
            self._reply(409, b"stub: deja occupe")
            return
        STORE[path] = body
        self._reply(201, b"stub: cree")

    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_port)
sys.stdout.flush()
srv.serve_forever()
PY

STUB_LOG="$STUB_LOG" python3 "$TMP/stub.py" >"$TMP/stub.port" 2>"$TMP/stub.err" &
STUB_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/stub.port" ] && break; sleep 0.1; done
PORT="$(head -n1 "$TMP/stub.port" 2>/dev/null)"
case "$PORT" in ''|*[!0-9]*)
  echo "!! stub HTTP n'a pas démarré :"; sed 's/^/      /' "$TMP/stub.err"
  exit 2
  ;;
esac
GIT_HOST="http://127.0.0.1:$PORT"
OWNER="ci"
echo "== stub HTTP : $GIT_HOST (pid $STUB_PID)"

# path-only de l'URL canonique (miroir de _as_url, sans le host — pour grepper
# le journal et pour pré-semer directement par curl, hors de la lib).
url_path() { printf '/api/packages/%s/generic/promote--%s--%s/%s/archive.zip' "$OWNER" "$1" "$2" "$3"; }
# miroir de _as_url sous le visage gitlab (registre PAR PROJET) : le chemin
# encodé de ARCHIVE_STORE_PROJECT=ci/archives, en dur — la seule valeur que
# les cas ⑫/⑫bis/⑬ posent.
url_path_gl() { printf '/api/v4/projects/ci%%2Farchives/packages/generic/promote--%s--%s/%s/archive.zip' "$1" "$2" "$3"; }
loglines() { wc -l < "$STUB_LOG" | tr -d ' '; }
putcount() { grep -c -F "PUT $1 " "$STUB_LOG" 2>/dev/null || true; }

# Payload réel : un petit zip factice (le contenu importe peu, seul son sha256 compte).
PAYLOAD="$TMP/payload.zip"
printf 'PK\x03\x04 archive de sonde G5 %s\n' "$(date +%s%N)" > "$PAYLOAD"
SHA="$(shasum -a 256 "$PAYLOAD" | cut -d' ' -f1)"

# Payload distinct, pour le scénario de conflit (⑥) : octets différents, sha différent.
OTHER="$TMP/other.zip"
printf 'CE-NE-SONT-PAS-LES-MEMES-OCTETS\n' > "$OTHER"

run() { # <outfile> <commande...> — capture stdout+stderr en FICHIER (jamais
        # un pipe), rc récupéré immédiatement après. Chaque appelant passe une
        # commande déjà complète (typiquement `env VAR=val bash -c '. "$1"; …'
        # _ "$LIB" args…`) : ce wrapper ne source rien lui-même.
  local outfile="$1"; shift
  "$@" >"$outfile" 2>&1
  echo $?
}

echo
echo "== ⑧ team invalide (Team/../x) : refus AVANT tout réseau =="
L0="$(loglines)"
RC="$(run "$TMP/c8.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_push "$2" "Team/../x" "probe"' _ "$LIB" "$PAYLOAD")"
[ "$RC" -ne 0 ] && grep -q 'STORE_PARAM_INVALIDE' "$TMP/c8.out" \
  && ok "⑧ team invalide refusé (STORE_PARAM_INVALIDE)" \
  || bad "⑧ refus attendu absent : $(cat "$TMP/c8.out")"
[ "$(loglines)" = "$L0" ] \
  && ok "⑧bis le journal du stub n'a REÇU AUCUNE requête pour ce cas" \
  || bad "⑧bis le stub a vu une requête alors que le refus doit tomber avant tout réseau"

echo
echo "== ⑨ GITEA_TOKEN absent : refus sans appel réseau =="
L0="$(loglines)"
RC="$(run "$TMP/c9.out" env -u GITEA_TOKEN FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_push "$2" "neuf" "probe"' _ "$LIB" "$PAYLOAD")"
[ "$RC" -ne 0 ] && grep -q 'STORE_TOKEN_ABSENT' "$TMP/c9.out" \
  && ok "⑨ GITEA_TOKEN absent refusé (STORE_TOKEN_ABSENT)" \
  || bad "⑨ refus attendu absent : $(cat "$TMP/c9.out")"
[ "$(loglines)" = "$L0" ] \
  && ok "⑨bis aucun appel réseau tenté sans token" \
  || bad "⑨bis le stub a vu une requête malgré l'absence de token"

echo
echo "== ① push d'un zip : ARCHIVE_STORE_PUSHED, 1 PUT reçu =="
P1="$(url_path uno alpha "$SHA")"
RC="$(run "$TMP/c1.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_push "$2" uno alpha' _ "$LIB" "$PAYLOAD")"
[ "$RC" -eq 0 ] && grep -q "ARCHIVE_STORE_PUSHED sha256=$SHA" "$TMP/c1.out" \
  && ok "① ARCHIVE_STORE_PUSHED sha256=$SHA" \
  || bad "① push échoué : $(cat "$TMP/c1.out")"
[ "$(putcount "$P1")" = 1 ] \
  && ok "① le stub a reçu EXACTEMENT 1 PUT" \
  || bad "① nombre de PUT inattendu ($(putcount "$P1"))"

echo
echo "== ② re-push identique : ARCHIVE_STORE_PUSHED, PAS de 2e PUT =="
RC="$(run "$TMP/c2.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_push "$2" uno alpha' _ "$LIB" "$PAYLOAD")"
[ "$RC" -eq 0 ] && grep -q "ARCHIVE_STORE_PUSHED sha256=$SHA" "$TMP/c2.out" \
  && ok "② re-push idempotent : ARCHIVE_STORE_PUSHED" \
  || bad "② re-push échoué : $(cat "$TMP/c2.out")"
[ "$(putcount "$P1")" = 1 ] \
  && ok "② toujours 1 SEUL PUT au total — pas de doublon réseau" \
  || bad "② un second PUT a été émis ($(putcount "$P1")) — l'idempotence par le contenu a sauté"

echo
echo "== ③ fetch par digest : ARCHIVE_STORE_FETCHED, octets identiques =="
DEST3="$TMP/case3.dest"
RC="$(run "$TMP/c3.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_fetch uno alpha "$2" "$3"' _ "$LIB" "$SHA" "$DEST3")"
[ "$RC" -eq 0 ] && grep -q "ARCHIVE_STORE_FETCHED sha256=$SHA" "$TMP/c3.out" \
  && ok "③ ARCHIVE_STORE_FETCHED sha256=$SHA" \
  || bad "③ fetch échoué : $(cat "$TMP/c3.out")"
cmp -s "$DEST3" "$PAYLOAD" \
  && ok "③bis octets fetchés IDENTIQUES au zip poussé (cmp)" \
  || bad "③bis les octets fetchés diffèrent du zip poussé"

echo
echo "== ④ fetch d'un digest jamais poussé : STORE_HTTP_404, dest ABSENT =="
NEVER="0000000000000000000000000000000000000000000000000000000000000000"
NEVER="${NEVER:0:64}"
DEST4="$TMP/case4.dest"
RC="$(run "$TMP/c4.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_fetch quatre beta "$2" "$3"' _ "$LIB" "$NEVER" "$DEST4")"
[ "$RC" -ne 0 ] && grep -q 'STORE_HTTP_404' "$TMP/c4.out" \
  && ok "④ STORE_HTTP_404 sur un digest jamais poussé" \
  || bad "④ refus attendu absent : $(cat "$TMP/c4.out")"
[ ! -e "$DEST4" ] \
  && ok "④bis la destination reste ABSENTE" \
  || bad "④bis la destination a été créée malgré le 404"

echo
echo "== ⑤ contenu corrompu servi : STORE_DIGEST_MISMATCH, dest ABSENT =="
DEST5="$TMP/case5.dest"
RC="$(run "$TMP/c5.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_fetch corrompu cinq "$2" "$3"' _ "$LIB" "$SHA" "$DEST5")"
[ "$RC" -ne 0 ] && grep -q 'STORE_DIGEST_MISMATCH' "$TMP/c5.out" \
  && ok "⑤ STORE_DIGEST_MISMATCH sur un contenu corrompu" \
  || bad "⑤ refus attendu absent : $(cat "$TMP/c5.out")"
[ ! -e "$DEST5" ] \
  && ok "⑤bis la destination reste ABSENTE" \
  || bad "⑤bis la destination a été créée malgré le mismatch"

echo
echo "== ⑥ chemin occupé par d'autres octets au push : STORE_CONFLIT_CONTENU, aucun PUT =="
# Pré-semage HORS lib (curl direct, avec header d'auth) : on occupe exactement
# l'URL que le push va lui-même dériver (team/api/sha du VRAI payload), avec
# d'AUTRES octets — c'est le seul moyen de simuler un registre incohérent sans
# toucher au code adressé-par-contenu lui-même.
P6="$(url_path conflit probe "$SHA")"
HDR6="$TMP/hdr6"; printf 'Authorization: token x\n' > "$HDR6"
SEED_CODE="$(curl -sS -H @"$HDR6" -o /dev/null -w '%{http_code}' --upload-file "$OTHER" "$GIT_HOST$P6")"
[ "$SEED_CODE" = 201 ] \
  && ok "⑥ pré-semage direct du chemin avec d'autres octets (201)" \
  || bad "⑥ le pré-semage direct a échoué (code=$SEED_CODE) — le cas ne peut pas être joué"
RC="$(run "$TMP/c6.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_push "$2" conflit probe' _ "$LIB" "$PAYLOAD")"
[ "$RC" -ne 0 ] && grep -q 'STORE_CONFLIT_CONTENU' "$TMP/c6.out" \
  && ok "⑥bis STORE_CONFLIT_CONTENU — refus d'écraser" \
  || bad "⑥bis refus attendu absent : $(cat "$TMP/c6.out")"
[ "$(putcount "$P6")" = 1 ] \
  && ok "⑥ter AUCUN PUT émis par le push (seul le pré-semage compte pour 1)" \
  || bad "⑥ter un PUT du push est apparu ($(putcount "$P6")) — le conflit n'a pas empêché l'écriture"

echo
echo "== ⑦ 500 : STORE_HTTP_500 =="
RC="$(run "$TMP/c7.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_push "$2" erreur six' _ "$LIB" "$PAYLOAD")"
[ "$RC" -ne 0 ] && grep -q 'STORE_HTTP_500' "$TMP/c7.out" \
  && ok "⑦ STORE_HTTP_500 propagé depuis la sonde" \
  || bad "⑦ refus attendu absent : $(cat "$TMP/c7.out")"

echo
echo "== ⑩ MUTATION : retirer la comparaison du fetch doit faire VERDIR ⑤ =="
# Ancrage sur l'INDENTATION (2 espaces = corps de archive_store_fetch) : la
# même expression littérale existe aussi dans archive_store_push (4 espaces,
# le contrôle de conflit ⑥), et ce n'est PAS elle qu'on veut désarmer.
sed 's/^  \[ "\$got" = "\$sha" \] \\$/  true \\/' "$LIB" > "$TMP/lib_mut10.sh"
# la lib charge sa voisine (forge-identity.sh, qui choisit la forme de l'en-tête) :
# une copie mutée sans elle ne serait pas la lib, mais une lib amputée (2026-09-04).
cp "$(dirname "$LIB")/forge-identity.sh" "$TMP/forge-identity.sh"
cmp -s "$LIB" "$TMP/lib_mut10.sh" \
  && bad "⑩ le mutant est IDENTIQUE à la lib — l'ancre a bougé, la mutation ne mute rien" \
  || ok "⑩ le mutant diffère RÉELLEMENT de la lib (mutation non no-op)"
# La ligne de push (4 espaces) doit être INTACTE : preuve que le sed a visé la
# bonne occurrence et non les deux.
grep -q '^    \[ "\$got" = "\$sha" \] \\$' "$TMP/lib_mut10.sh" \
  && ok "⑩bis le contrôle de conflit du PUSH reste INTACT dans le mutant (ciblage précis)" \
  || bad "⑩bis le sed a aussi muté le contrôle de conflit du push — ciblage trop large"
DEST10="$TMP/case10.dest"
RC="$(run "$TMP/c10.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_fetch corrompu cinq "$2" "$3"' _ "$TMP/lib_mut10.sh" "$SHA" "$DEST10")"
[ "$RC" -eq 0 ] && grep -q 'ARCHIVE_STORE_FETCHED' "$TMP/c10.out" \
  && ok "⑩ter guard retirée ⇒ le fetch corrompu VERDIT (⑤ n'est pas une épreuve vacante)" \
  || bad "⑩ter le mutant refuse encore — la mutation n'a pas désarmé le contrôle visé : $(cat "$TMP/c10.out")"

echo
echo "== ⑪ le token n'apparaît dans AUCUNE ligne de commande curl =="
nc_strict "$LIB" > "$TMP/lib_nc.sh"
# 2026-09-04 : la lib ne compose plus l'en-tête elle-même — forge_auth_write le
# fait, selon FORGE_API_AUTH (Gitea, GitLab, ou un couple). La PROPRIÉTÉ mesurée
# est la même, et elle est même plus forte : plus AUCUNE mention d'Authorization
# ici, et le secret ne va que dans un FICHIER d'en-tête, jamais dans un argv.
NAUTH="$(grep -c 'Authorization' "$TMP/lib_nc.sh")"
[ "$NAUTH" = 0 ] \
  && ok "⑪ aucune occurrence de 'Authorization' dans le code décommenté (l'en-tête est délégué)" \
  || bad "⑪ $NAUTH occurrence(s) de 'Authorization' (attendu 0) — le token pourrait fuiter ailleurs"
AUTHW="$(grep -c 'forge_auth_write .* "\$hdr"' "$TMP/lib_nc.sh")"
[ "$AUTHW" = 1 ] \
  && ok "⑪bis l'en-tête est écrit dans un FICHIER par forge_auth_write (pas un argv curl)" \
  || bad "⑪bis forge_auth_write vers un header-file : $AUTHW occurrence(s), attendu 1"
grep -q -F "PUT $P1 1" "$STUB_LOG" \
  && ok "⑪ter le stub a bien REÇU l'en-tête Authorization sur une requête réelle de la lib" \
  || bad "⑪ter aucune requête journalisée par le stub ne porte l'en-tête Authorization"

echo
echo "== ⑫ visage gitlab : l'URL est adressée PAR PROJET (ARCHIVE_STORE_PROJECT), PUT 201 =="
P12="$(url_path_gl deux beta "$SHA")"
RC="$(run "$TMP/c12.out" env GITEA_TOKEN=x FORGE_KIND=gitlab ARCHIVE_STORE_PROJECT=ci/archives GIT_HOST="$GIT_HOST" bash -c '. "$1"; archive_store_push "$2" deux beta' _ "$LIB" "$PAYLOAD")"
[ "$RC" -eq 0 ] && grep -q "ARCHIVE_STORE_PUSHED sha256=$SHA" "$TMP/c12.out" && [ "$(putcount "$P12")" = 1 ] \
  && ok "⑫ gitlab : PUT sur /api/v4/projects/ci%2Farchives/packages/generic/… (1 PUT)" || bad "⑫ rc $RC put=$(putcount "$P12") : $(cat "$TMP/c12.out")"
# Ancré sur LA requête de ⑫ (le PUT de $P12), jamais sur le journal entier :
# un grep global verdirait sur n'importe quelle ligne — y compris celle d'un
# cas futur — alors que la propriété mesurée est que CE PUT-là, celui du
# visage gitlab, porte l'en-tête de GitLab.
grep -q -F "PUT $P12 PRIVATE-TOKEN" "$STUB_LOG" \
  && ok "⑫bis le PUT de ⑫ porte PRIVATE-TOKEN (en-tête dérivé du visage par forge_auth_write)" \
  || bad "⑫bis l'en-tête du PUT gitlab n'est pas dérivé du visage : $(grep -F "$P12" "$STUB_LOG" | tr '\n' ' ')"

echo
echo "== ⑬ visage gitlab sans ARCHIVE_STORE_PROJECT : refus AVANT tout réseau =="
L0="$(loglines)"
RC="$(run "$TMP/c13.out" env GITEA_TOKEN=x FORGE_KIND=gitlab GIT_HOST="$GIT_HOST" bash -c '. "$1"; archive_store_push "$2" deux beta' _ "$LIB" "$PAYLOAD")"
[ "$RC" -ne 0 ] && grep -q 'ARCHIVE_STORE_PROJECT_REQUIS' "$TMP/c13.out" && [ "$(loglines)" = "$L0" ] \
  && ok "⑬ ARCHIVE_STORE_PROJECT_REQUIS, aucun appel réseau" || bad "⑬ rc $RC : $(cat "$TMP/c13.out")"

echo
echo "== ⑭ sans FORGE_KIND : refus FORGE_KIND_REQUIS AVANT tout réseau =="
# Task 17 (addendum §1) : archive-store.sh ne source pas forge_api_init (transport
# binaire), donc son propre _as_url serait le DERNIER défaut silencieux de la
# chaîne si on lui laissait un repli — d'où ce cas, même idiome que ⑬.
L0="$(loglines)"
RC="$(run "$TMP/c14.out" env -u FORGE_KIND GITEA_TOKEN=x GIT_HOST="$GIT_HOST" bash -c '. "$1"; archive_store_push "$2" deux beta' _ "$LIB" "$PAYLOAD")"
[ "$RC" -ne 0 ] && grep -q 'FORGE_KIND_REQUIS' "$TMP/c14.out" && [ "$(loglines)" = "$L0" ] \
  && ok "⑭ FORGE_KIND_REQUIS, aucun appel réseau" || bad "⑭ rc $RC : $(cat "$TMP/c14.out")"

echo
echo "== ⑮ registre derrière un 302 : la Location présignée est relue SANS authentification =="
# Le défaut mesuré : sur un registre servi par un object storage, le GET du
# paquet rend 302 et la lib refusait « STORE_HTTP_302 : l'archive pinnée n'est
# pas au registre (export jamais poussé ?) » — une panne dure AVEC un faux
# diagnostic sur un registre parfaitement sain. Et `curl -L` nu n'était pas la
# réponse : il aurait livré le jeton de forge à l'hôte de stockage.
P15="$(url_path redir quinze "$SHA")"
HDR15="$TMP/hdr15"; printf 'Authorization: token x\n' > "$HDR15"
SEED15="$(curl -sS -H @"$HDR15" -o /dev/null -w '%{http_code}' --upload-file "$PAYLOAD" "$GIT_HOST$P15")"
DEST15="$TMP/case15.dest"
RC="$(run "$TMP/c15.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_fetch redir quinze "$2" "$3"' _ "$LIB" "$SHA" "$DEST15")"
# L'en-tête du GET présigné : le journal du stub dit "0" quand la requête ne
# portait NI Authorization NI PRIVATE-TOKEN. C'est LA propriété, pas un détail.
BLOBAUTH="$(grep -F "GET /blob$P15 " "$STUB_LOG" | tail -1)"
{ [ "$SEED15" = 201 ] && [ "$RC" -eq 0 ] && cmp -s "$DEST15" "$PAYLOAD" \
  && [ "$BLOBAUTH" = "GET /blob$P15 0" ]; } \
  && ok "⑮ 302 suivi UNE fois : octets identiques (cmp) et le GET de la Location présignée ne porte AUCUN en-tête d'authentification" \
  || bad "⑮ semis=$SEED15 rc=$RC cmp=$(cmp -s "$DEST15" "$PAYLOAD" && echo ok || echo NON) blob='${BLOBAUTH:-aucune requête}' : $(cat "$TMP/c15.out")"

echo
echo "== ⑯ push derrière un 302 : contenu déjà présent ⇒ no-op idempotent, AUCUN PUT =="
P16="$(url_path redir seize "$SHA")"
SEED16="$(curl -sS -H @"$HDR15" -o /dev/null -w '%{http_code}' --upload-file "$PAYLOAD" "$GIT_HOST$P16")"
RC="$(run "$TMP/c16.out" env GITEA_TOKEN=x FORGE_KIND=gitea GIT_HOST="$GIT_HOST" bash -c \
  '. "$1"; archive_store_push "$2" redir seize' _ "$LIB" "$PAYLOAD")"
{ [ "$SEED16" = 201 ] && [ "$RC" -eq 0 ] && grep -q "ARCHIVE_STORE_PUSHED sha256=$SHA" "$TMP/c16.out" \
  && [ "$(putcount "$P16")" = 1 ]; } \
  && ok "⑯ la sonde d'existence voit le 302 comme PRÉSENT et compare le digest par le même chemin : no-op (seul le semis compte pour 1 PUT)" \
  || bad "⑯ semis=$SEED16 rc=$RC put=$(putcount "$P16") : $(cat "$TMP/c16.out")"

# ── Garde-fou : verdicts rendus == cas attendus ─────────────────────────────
# Les 28 assertions ci-dessus (⑧/⑨/①/②/③/④/⑤/⑥/⑦/⑩/⑪/⑫/⑬/⑭, sous-parties
# comprises) sont le compte EXACT de ce que cette épreuve pose (mesuré par un
# run complet, pas déduit de tête). Si une assertion tombe en silence (script
# tronqué, cas sauté, échantillonnage), ce compte bouge et CE garde-fou
# rougit — un vert sur un sous-ensemble ne peut plus se faire passer pour le
# vert complet. (24 mesurées avant Task 13, +3 pour ⑫/⑫bis/⑬, +1 pour ⑭,
# +2 pour ⑮/⑯ — la relecture de la Location présignée, revue finale 2026-09-12.)
EXPECTED_ASSERTIONS=30
TOTAL_BEFORE_GUARD=$((PASS+FAIL))
[ "$TOTAL_BEFORE_GUARD" -eq "$EXPECTED_ASSERTIONS" ] \
  && ok "verdicts rendus ($TOTAL_BEFORE_GUARD) == cas attendus ($EXPECTED_ASSERTIONS)" \
  || bad "verdicts rendus ($TOTAL_BEFORE_GUARD) != cas attendus ($EXPECTED_ASSERTIONS) — épreuve altérée ou tronquée"

printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
