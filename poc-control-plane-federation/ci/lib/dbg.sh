#!/bin/sh
# ci/lib/dbg.sh — le MODE DEBUG SANS FUITE, à SOURCER (POSIX sh : dash ET bash).
#
# LE PROBLÈME (plan 2026-09-09, L2). Quand la chaîne casse chez un client, le
# log ne dit ni l'URL composée, ni le chemin lu, ni la branche, ni le statut
# HTTP — et il faut solliciter l'auteur. Le réflexe `set -x` est INTERDIT :
# tous les scripts font `set +x` (« jamais de trace : le token ne doit pas
# fuiter ») parce qu'un log Jenkins est ARCHIVÉ — un secret qui y passe une
# fois y reste. Le mode verbeux est donc une sortie CURATÉE : chaque ligne
# passe par une rédaction avant d'atteindre stderr.
#
# LE CONTRAT (preuve : scripts/test-dbg-redaction.sh)
#   dbg <msg…>                 no-op si STOA_DEBUG vide/0/false/off ; sinon
#                              STDERR seulement, préfixe « [dbg <script>] »,
#                              APRÈS rédaction. Rend le $? REÇU (jamais le sien).
#   dbg_kv <clé> <valeur>      « clé=valeur » (valeur vide ⇒ « <vide> », et ce
#                              « <vide> » reste LISIBLE même derrière une clé
#                              qui finit par PASSWORD/TOKEN : c'est le diagnostic).
#   dbg_http <méth> <url> <code> [octets]   « GET url -> HTTP 200 (n octets) ».
#   redact [fichier…]          filtre stdin→stdout ; masque par LITTÉRAL connu
#                              du process et par FORME ; les fichiers passés en
#                              argument sont des secrets de plus à masquer.
#   dbg_on                     vrai si le mode est actif.  dbg_init : idempotent,
#                              normalise et exporte STOA_DEBUG (1 ou vide).
#
# POURQUOI LE $? EST PRÉSERVÉ. La consigne du plan (« return 0 toujours »)
# voulait dire « ne casse JAMAIS l'appelant », pas « efface son verdict » :
# 38 scripts sont en `set +x` sans `set -e` et décident par `||` — un `dbg` qui
# rendrait 0 après un échec effacerait le verdict (`cmd; dbg …; [ $? = 0 ] ||
# refus` passerait). Mesure qui fait foi : `false; dbg x; echo $?` ⇒ 1 (C.1).
# Le rc reçu est capturé en PREMIÈRE instruction et rendu tel quel. UNE
# exception : sous `set -e` — les blocs `sh` de Jenkins tournent en
# `/bin/sh -xe` — rendre un rc≠0 hérité (ex. 1 après `[ "$DEBUG" = true ] &&
# export STOA_DEBUG=1` quand DEBUG est faux) ABATTRAIT le step ; là, et là
# seulement, dbg rend 0 (`case $- in *e*`).
#
# POURQUOI JAMAIS UN SECRET EN LIGNE DE COMMANDE — MÊME EN PRÉFIXE (le `-x` du
# même `sh -xe`). Sous `set -x` le shell trace CHAQUE commande simple avec ses
# arguments ET ses affectations de préfixe (`X=… cmd`), ET ses affectations
# nues (`X=…`), ET les mots de `[ -n "$2" ]` — bash comme dash (mesuré
# 2026-09-09). Une lib qui poserait `FORGE_SECRET="$FORGE_SECRET" python3 …`
# déverserait TOUS les secrets du process sur un message anodin (`dbg_kv
# GIT_BASE main`) : c'était le défaut grave n°1 de la revue. Le remède n'est
# PAS de couper `-x` (on ne touche pas au mode de l'appelant) : c'est un CANAL
# que `-x` ne trace pas. Mesure (bash 3.2 et dash, `-x`) : le builtin `printf`
# est tracé AVEC ses arguments (un fichier 0600 écrit par printf fuit donc) ;
# le CONTENU d'un here-doc n'est tracé par AUCUN des deux, même sur un autre
# descripteur, même dans une fonction sous `$(…)`. Donc : les secrets, les
# logins, les chemins et le préfixe partent vers python par un here-doc sur le
# DESCRIPTEUR 3 (`3<<_DBG_EOF`) ; le message part vers redact par un here-doc
# sur stdin ; dbg_kv décide du vide par `case` (non tracé), jamais par `[`.
# LIMITE, documentée : la ligne d'APPEL (`+ dbg 'Authorization: token …'`,
# `+ dbg_kv WM_PASSWORD …`) est tracée par l'APPELANT avant d'entrer ici — la
# lib n'y ajoute AUCUNE ligne (épreuve X) ; un bloc Jenkins fait `set +x` avant
# le pont DEBUG⇒STOA_DEBUG (plan L4b). Résiduel : sous `-x`, l'affectation
# `_dbg_out=$(…)` trace ce que python a RENDU — le python réel n'écrit qu'après
# masquage ; seul un python de remplacement qui recopierait son entrée puis
# mourrait (G.4, synthétique) y montrerait la valeur.
#
# POURQUOI JAMAIS STDOUT. Les libs rendent leur PRODUIT sur stdout
# (forge_login → le login, gitea-pr-confirm.sh → CLÉ=VALEUR) : une ligne de
# debug qui s'y glisserait deviendrait une valeur.
#
# POURQUOI LE MASQUAGE PAR LITTÉRAL. Le PAT de forge fait 40 hex, sans préfixe :
# aucune forme ne le reconnaît (ni _gc_redact, ni wm_redact_url, ni
# _vault_redact). Seul le process SAIT ce qu'il tient : les valeurs de
# FORGE_SECRET, GITEA_TOKEN, FORGE_TOKEN, PUSH_TOKEN, VAULT_TOKEN,
# VAULT_USER_PASSWORD, WM_PASSWORD, WM_PASS, WM_BEARER, LDAP_ADMIN_PASSWORD,
# le contenu des fichiers CI_TOKEN_FILE, PR_TOKEN_FILE, VAULT_TOKEN_FILE,
# FORGE_TOKEN_FILE (+ DBG_SECRET_FILES, chemins séparés par saut de ligne, et
# les arguments de redact). Les variables sont relues À CHAQUE APPEL : une
# variable shell NON exportée est vue quand même, et rien ne transite par argv
# (ps ne voit que le programme, jamais un secret — épreuve I).
#
# CE QU'ON MASQUE D'UN LITTÉRAL, ET POURQUOI. Un secret ne voyage pas toujours
# tel quel : `%XX` dans une URL (et `+` pour l'espace dans un corps
# x-www-form-urlencoded — le grant password OAuth2), `\t`/`é` dans un JSON,
# base64 de `user:secret` dans un Basic (FORGE_USER, WM_USER, VAULT_USER,
# PUSH_LOGIN). Et il ne fuit pas toujours ENTIER : ssh coupe l'autorité au
# premier « / » et écrit « Could not resolve hostname git:MORCEAU » — canari
# MESURÉ par generate-choices.sh (règle 3bis). On masque donc aussi chaque
# segment (coupé à « / » et aux blancs) de 4 caractères ou plus, et chacune de
# ses formes.
#
# ARBITRAGE DU LITTÉRAL COURT. Un littéral de 1 à 3 caractères n'est PAS
# masqué par littéral : « ab » rendrait « table » illisible dans tout le log.
# La suite prouve (§E.20-23) qu'un tel secret ne passe par AUCUN des transports
# qui l'amènent dans une ligne de debug sans y être rattrapé par sa FORME.
#
# LES FORMES (sans littéral connu) : « Authorization: <schéma> <valeur> » — la
# valeur part, le SCHÉMA reste (token/Bearer/Basic est un diagnostic : le
# client du 2026-09-04 envoyait l'en-tête de Gitea à GitLab) ; userinfo d'URL
# « ://…@ » (l'hôte RESTE : c'est lui qu'on diagnostique) ; préfixes Vault
# hvs./hvb. ; JWT eyJ… ; et une valeur derrière une CLÉ password/secret/token/
# api_key/access_key/client_secret — c'est cette clé générique qui couvre aussi
# « PRIVATE-TOKEN: » (GitLab) et « X-Vault-Token: » (une seule autorité par
# idée : leur nom finit par TOKEN, une forme dédiée serait un doublon
# improuvable — revue 2026-09-09, E.3/E.4).
#
# LITTÉRAUX PUIS FORMES, ET LE MASQUE EST UN ATOME. Un littéral peut ne masquer
# que le DÉBUT d'une valeur (segment connu, reste dans un encodage inconnu :
# `password=<secret masqué>%25209qx…`). Une forme qui s'arrêterait au blanc du
# masque, ou une « garde d'idempotence » qui laisserait telle quelle une valeur
# déjà commencée par le masque, laisserait fuir le reste : connaître le secret
# rendrait la rédaction PIRE (défaut grave n°2 de la revue). Les classes de
# valeur acceptent donc le masque entier comme un atome, et il n'y a pas de
# garde : remplacer le masque par le masque est idempotent par nature (F.1-F.4).
#
# FAIL-CLOSED. Sans python3 sur le PATH, ou si python3 meurt, redact rend la
# ligne unique « <rédaction indisponible> » et RIEN d'autre — pas même ce
# qu'un python bavard aurait pu écrire avant de mourir (sa sortie est retenue
# jusqu'au verdict, son stderr est jeté). Mieux vaut aucun debug qu'un debug
# qui fuit.
#
# JAMAIS D'ANSI. Un log Jenkins archivé se grep : « [dbg » en tête de ligne.
#
# QUI PARLE PAR CETTE LIB (L2, 2026-09-10). Les consommateurs, chacun sous son
# propre nom (« [dbg <script>] », jamais DBG_NAME dans la chaîne) :
#   - scripts/lib/forge-api.sh, via forge_api_init (FORGE_KIND, FORGE_API_AUTH,
#     GIT_HOST, GIT_REPO, FORGE_API_BASE) ;
#   - scripts/lib/git-base.sh (la ligne ls-remote avec son rc, GIT_BASE,
#     GIT_BASE_ORIGINE, GIT_BASE_OF par dépôt) — la ligne d'AUDIT
#     « git-base: GIT_BASE=… découvert — HEAD annoncée par … » (L3) n'est PAS du
#     debug : inconditionnelle, sans préfixe « [dbg », une par build ;
#   - ci/lib/vault-login.sh (dbg_http par appel, contexte du login, empreinte
#     du mot de passe, corps d'erreur ≥ 400 par redact PUIS coupé) — ses
#     _vault_dbg/_vault_redact/_vault_debug_on ont migré ici, VAULT_DEBUG n'existe
#     plus ;
#   - les quatre scripts de la chaîne app-request — scripts/provision-request.sh,
#     scripts/provision-plan.sh, scripts/provision-apply-reconcile.sh,
#     scripts/app-rollback-request.sh (dbg_init en tête ; disposition, identité,
#     URL composées, chaque geste git avec son rc et son stderr masqué PUIS
#     coupé ; le premier et le dernier nomment le fichier du token humain par
#     DBG_SECRET_FILES — le plan et reconcile ne tiennent que FORGE_SECRET,
#     relu dans l'environnement à chaque appel, et ne la posent pas) ;
#   - scripts/lib/gitea-pr-confirm.sh (« PR #n relue : … ») et
#     scripts/lib/gitea-pr-comment.sh (PR_NUMBER, COMMENT_MARKER, CF_ID, CU_*).
#   NON instrumentés, dits pour ne pas les chercher : scripts/provision-plan-status.sh
#   (seul son défaut de site GIT_HOST est tombé) ; scripts/lib/forge-identity.sh
#   (forge_login RELAIE le stderr de forge-api.py, succès compris, sans parler
#   elle-même) ; scripts/provision-apply-comment.sh (appelé par fail() avec sa
#   sortie jetée).
#   L'EXCEPTION, documentée : scripts/lib/forge-api.py est un process python,
#   enfant de forge() ; il écrit LUI-MÊME « [dbg forge-api.py] METHOD url -> HTTP
#   code (n octets) » sur stderr, AVANT toute cause, masqué par SON _mask —
#   l'autorité de ses causes de refus depuis L1 (mêmes littéraux sous leurs
#   formes d'URL, forme ://…@ ; test-forge-api.sh §P). Le faire passer par redact
#   obligerait forge() à capturer son stderr, ce qui retiendrait la cause d'un
#   refus jusqu'à la fin du process et doublerait la plomberie de chaque verbe
#   (l'en-tête de forge-api.py dit le reste). Deux autorités de masque pour le
#   texte côté python, une seule liste de valeurs pour STOA_DEBUG (P.6).
#
# USAGE
#   . ci/lib/dbg.sh                                   # ou "$(dirname "$0")/../ci/lib/dbg.sh"
#   dbg_kv GIT_BASE "$GIT_BASE"
#   dbg_http GET "$API/user" "$code" "$(wc -c < "$out")"
#   git clone … 2>"$err" || { dbg "git: $(cat "$err")"; refus; }

# Le programme de rédaction. Une seule autorité : redact l'appelle, dbg appelle
# redact. Pas d'apostrophe dans ce texte (il vit entre quotes simples).
_DBG_PY='
import os, re, sys, json, base64
from urllib.parse import quote, quote_plus
M = "<secret masqué>"
# LE CANAL : le descripteur 3, un here-doc du shell (jamais argv, jamais un
# préfixe d affectation : sous « sh -x » les deux sont tracés, un here-doc non).
# Lignes « P=préfixe », « U=login », « F=chemin », « S=secret » ; une ligne sans
# étiquette CONTINUE la valeur précédente (un secret peut porter un saut de
# ligne, DBG_SECRET_FILES en porte entre ses chemins).
try:
    with os.fdopen(3, "rb") as f3:
        canal = f3.read().decode("utf-8", "surrogateescape")
except OSError:
    sys.exit(1)                       # pas de canal = secrets inconnus = fail-closed
if canal.endswith("\n"):
    canal = canal[:-1]
pre, users, chemins, secrets, cour = "", [], [], [], ""
for ligne in canal.split("\n"):
    et, sep, val = ligne.partition("=")
    if sep and et in ("P", "U", "F", "S"):
        cour = et
        if et == "P":
            pre = val
        elif et == "U":
            users.append(val)
        elif et == "F":
            chemins.append(val)
        else:
            secrets.append(val)
    elif cour == "S":
        secrets[-1] += "\n" + ligne
    elif cour == "F":
        chemins.append(ligne)
bruts = set(x for v in secrets for x in (v, v.strip()) if x)
for p in chemins + sys.argv[1:]:
    p = p.strip()
    if not p:
        continue
    try:
        with open(p, "rb") as f:
            c = f.read().decode("utf-8", "surrogateescape")
    except OSError:
        continue                      # un fichier absent ne casse pas le debug : les autres littéraux restent masqués
    bruts.update(v for v in (c.strip("\r\n"), c.strip()) if v)
users = [u for u in users if u]
lits = set()
for v in bruts:
    if len(v) < 4:
        continue                      # ARBITRAGE : 1-3 caractères masqueraient chaque lettre du log ; les FORMES rattrapent (suite §E.20-23)
    for x in [v] + [seg for seg in re.split(r"[/\s]+", v) if len(seg) >= 4]:   # le tout ET ses morceaux (ssh coupe au « / », le shell aux blancs)
        lits.add(x)
        lits.add(quote(x, safe="", errors="surrogateescape"))        # ce que porte une URL bien formée (%40, %2F, %20) ; surrogateescape : un octet non-UTF-8 ne tue pas python
        lits.add(quote_plus(x, safe="", errors="surrogateescape"))   # ce que porte un corps x-www-form-urlencoded (+ pour l espace)
        for j in (json.dumps(x)[1:-1], json.dumps(x, ensure_ascii=False)[1:-1]):
            lits.add(j)               # \t, é …
            lits.add(j.replace("/", "\\/"))   # … et \/ chez certains encodeurs
    for u in users:
        lits.add(base64.b64encode((u + ":" + v).encode("utf-8", "surrogateescape")).decode("ascii"))
s = sys.stdin.buffer.read().decode("utf-8", "surrogateescape").replace("\x00", "")
for lit in sorted(lits, key=len, reverse=True):   # le plus long d abord : un segment ne doit pas trouer son tout
    s = s.replace(lit, M)

# LES FORMES, après les littéraux. Le masque M est un ATOME des classes de
# valeur (V) : une valeur déjà masquée en partie est remasquée EN ENTIER, et
# remplacer M par M est idempotent — aucune garde. VIDE : le « <vide> » que
# dbg_kv pose pour une valeur absente reste lisible derrière WM_PASSWORD= aussi.
V = re.escape(M)
VIDE = r"(?!<vide>(?:[\s,&;\"\x27]|\Z))"
def masque(motif, texte, prefixe, suffixe=""):
    def rempl(m):
        return "".join(m.group(k) or "" for k in prefixe) + M + suffixe
    return re.sub(motif, rempl, texte)

s = masque(r"(?i)(authorization\"?\s*[:=]\s*\"?)(?:([A-Za-z][A-Za-z0-9-]*[ \t]+))?" + VIDE + r"([^\"\x27\r\n]+)", s, (1, 2))
s = masque(r"(://)((?:" + V + r"|[^/\s])+)@", s, (1,), "@")
s = re.sub(r"(?<![A-Za-z0-9])hv[sb]\.[A-Za-z0-9._-]{8,}", M, s)
s = re.sub(r"eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}(?:\.[A-Za-z0-9_-]*)?", M, s)
s = masque(r"(?i)((?:client_?secret|pass(?:word|wd)?|secret|token|bearer|api_?key|access_?key|apiaccesskey)\"?\s*[:=]\s*\"?)" + VIDE + r"((?:" + V + r"|[^\"\x27\s,&;])+)", s, (1,))
if pre:
    s = "".join(pre + l for l in s.splitlines(True))
sys.stdout.buffer.write(s.encode("utf-8", "surrogateescape"))
'

# dbg_on — le mode est-il actif ? (STOA_DEBUG relu à chaque appel : un script
# peut l'allumer après avoir sourcé la lib, c'est le pont Jenkins DEBUG⇒STOA_DEBUG.)
dbg_on() {
  case "${STOA_DEBUG:-}" in
    ''|0|false|FALSE|False|off|OFF|Off|no|NO|No) return 1 ;;
  esac
  return 0
}

# dbg_init — idempotent : normalise STOA_DEBUG (1 ou vide) et l'exporte, pour
# que les enfants (ansible, labctl, python) lisent la même valeur canonique.
dbg_init() {
  if dbg_on; then STOA_DEBUG=1; else STOA_DEBUG=''; fi
  export STOA_DEBUG
  return 0
}

# _dbg_py [fichier…] — lance le programme de rédaction : stdin = le texte,
# descripteur 3 = LE CANAL (here-doc : rien en argv, rien en préfixe — voir en
# tête, « le -x du même sh -xe »). Les variables sont relues À CHAQUE APPEL ;
# `${X:-}` : survit à `set -u`. Le stderr de python est JETÉ : un traceback
# d'import n'est pas une ligne de debug (G.5).
# Un retour-ligne DANS un secret (ou un login, un chemin, le préfixe)
# déformerait le canal fd 3, qui est ligne à ligne : une suite commençant par
# « P= » deviendrait le préfixe, imprimé EN CLAIR (mesuré, re-relecture
# 2026-09-09). Aucun parseur par lignes n'y échappe : on REFUSE de rédiger.
# Le test est un `case` dont le mot est la concaténation ÉCRITE DANS LE CASE —
# jamais affectée à une variable : `-x` trace une affectation avec sa valeur,
# mais imprime le mot d'un `case` NON expansé (bash) ou rien (dash), mesuré.
# DBG_SECRET_FILES est exclu : ses retours-ligne sont sa syntaxe (un chemin
# par ligne), et ce sont des chemins, pas des secrets.
_DBG_NL='
'
_dbg_py() {
  case "${_DBG_PREFIX:-}${FORGE_USER:-}${WM_USER:-}${VAULT_USER:-}${PUSH_LOGIN:-}${CI_TOKEN_FILE:-}${PR_TOKEN_FILE:-}${VAULT_TOKEN_FILE:-}${FORGE_TOKEN_FILE:-}${FORGE_SECRET:-}${GITEA_TOKEN:-}${FORGE_TOKEN:-}${PUSH_TOKEN:-}${VAULT_TOKEN:-}${VAULT_USER_PASSWORD:-}${WM_PASSWORD:-}${WM_PASS:-}${WM_BEARER:-}${LDAP_ADMIN_PASSWORD:-}" in
    *"$_DBG_NL"*) printf '<rédaction indisponible>\n'; return 0 ;;
  esac
  python3 -c "$_DBG_PY" "$@" 2>/dev/null 3<<_DBG_EOF
P=${_DBG_PREFIX:-}
U=${FORGE_USER:-}
U=${WM_USER:-}
U=${VAULT_USER:-}
U=${PUSH_LOGIN:-}
F=${CI_TOKEN_FILE:-}
F=${PR_TOKEN_FILE:-}
F=${VAULT_TOKEN_FILE:-}
F=${FORGE_TOKEN_FILE:-}
F=${DBG_SECRET_FILES:-}
S=${FORGE_SECRET:-}
S=${GITEA_TOKEN:-}
S=${FORGE_TOKEN:-}
S=${PUSH_TOKEN:-}
S=${VAULT_TOKEN:-}
S=${VAULT_USER_PASSWORD:-}
S=${WM_PASSWORD:-}
S=${WM_PASS:-}
S=${WM_BEARER:-}
S=${LDAP_ADMIN_PASSWORD:-}
_DBG_EOF
}

# redact [fichier…] — filtre stdin→stdout. Les secrets passent à python par
# le descripteur 3 (jamais argv, jamais un préfixe) ; les arguments sont des
# CHEMINS de fichiers de secret (un chemin n'est pas un secret). Fail-closed :
# sans python3, ou si python3 meurt, la ligne unique « <rédaction indisponible> ».
# shellcheck disable=SC2120  # les arguments sont FACULTATIFS : dbg appelle redact sans, un script peut lui passer ses fichiers
redact() {
  if command -v python3 >/dev/null 2>&1; then
    # La sortie est RETENUE ($(…)) et n'est libérée que sur rc 0 : un python qui
    # écrirait puis mourrait ne laisse rien passer (épreuve G.4). `if` et non
    # `x=$(…) || …` : sous `set -e`, une substitution en échec dans une
    # affectation nue abattrait l'appelant.
    if _dbg_out=$(_dbg_py "$@"); then
      [ -z "$_dbg_out" ] || printf '%s\n' "$_dbg_out"
    else
      printf '<rédaction indisponible>\n'
    fi
    _dbg_out=''
  else
    # Vider stdin avec un builtin (le PATH peut être vide) : sinon l'écrivain
    # reçoit SIGPIPE — et si l'appelant ignore SIGPIPE (trap '' PIPE), bash
    # imprime « printf: write error: Broken pipe » : ce serait « autre chose »
    # (épreuve G.6, message plus gros que le tampon du tube).
    while IFS= read -r _dbg_l; do :; done
    _dbg_l=''
    printf '<rédaction indisponible>\n'
  fi
  return 0
}

# _dbg_fin <rc reçu> — rend le rc reçu, sauf sous `set -e` (voir en tête).
_dbg_fin() {
  case $- in *e*) return 0 ;; esac
  return "$1"
}

# _dbg_emit — stdin = le message (un here-doc de l'appelant interne : jamais un
# argument, jamais une variable — sous `-x` les deux seraient tracés).
# `|| :` : un échec du tube (stderr fermé…) ne doit ni parler ni compter.
_dbg_emit() {
  _DBG_PREFIX="[dbg ${DBG_NAME:-${0##*/}}] "
  # shellcheck disable=SC2119  # sans argument : les fichiers de secret viennent de l'environnement
  redact >&2 || :
  _DBG_PREFIX=''
}

# dbg <msg…> — voir en tête. Le rc reçu est capturé AVANT toute autre chose.
dbg() {
  # shellcheck disable=SC2319  # dbg_kv/dbg_http appellent dbg derrière un `if` : ce $? est bien LEUR condition, et ils le jettent (ils rendent le rc qu'ILS ont reçu)
  _dbg_rc=$?
  if dbg_on; then
    _dbg_emit <<_DBG_EOF
$*
_DBG_EOF
  fi
  _dbg_fin "$_dbg_rc"
}

# dbg_kv <clé> <valeur> — « clé=valeur » ; une valeur vide se DIT (« <vide> ») :
# Jenkins retire une variable vide de l'environnement, c'est un diagnostic.
# `case`, pas `[ -n "$2" ]` : sous `-x`, `[` trace ses mots, `case` non.
dbg_kv() {
  _dbg_rc_kv=$?
  if dbg_on; then
    case "${2:-}" in
      '') _dbg_emit <<_DBG_EOF
${1:-}=<vide>
_DBG_EOF
          ;;
      *)  _dbg_emit <<_DBG_EOF
${1:-}=$2
_DBG_EOF
          ;;
    esac
  fi
  _dbg_fin "$_dbg_rc_kv"
}

# dbg_http <méthode> <url> <code> [octets] — la ligne normalisée d'un appel de
# forge, URL expurgée par redact comme le reste : « GET url -> HTTP 200 (n octets) ».
dbg_http() {
  _dbg_rc_http=$?
  if dbg_on; then
    case "${4:-}" in
      '') _dbg_emit <<_DBG_EOF
${1:-} ${2:-} -> HTTP ${3:-}
_DBG_EOF
          ;;
      *)  _dbg_emit <<_DBG_EOF
${1:-} ${2:-} -> HTTP ${3:-} ($4 octets)
_DBG_EOF
          ;;
    esac
  fi
  _dbg_fin "$_dbg_rc_http"
}
