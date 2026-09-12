#!/usr/bin/env python3
# scripts/lib/forge-api.py — LES VERBES DE FORGE, DEUX VISAGES, UNE GARDE.
#
# CE QUE CE FICHIER REMPLACE (mesuré le 2026-09-09, CI client sur GitLab).
# La chaîne parlait l'API de Gitea partout : 26 compositions de « /api/v1 » dans
# 14 fichiers, 16 en-têtes « Authorization: token » en dur, 15 json.load sur des
# réponses de forge dont 9 nus. Sur GitLab, « /api/v1/… » répond 302 vers
# /users/sign_in ; urllib suivait, json.load mourait sur du HTML, et le client
# lisait quinze lignes de trace Python sous un refus qui ne disait rien.
#
# ICI, UNE SEULE AUTORITÉ :
#   - le VISAGE (FORGE_KIND=gitea|gitlab) décide des chemins, des en-têtes, des
#     noms de champs (number↔iid, login↔username, open↔opened, head.ref↔
#     source_branch, pulls/N/files↔merge_requests/iid/diffs, issues/N/comments↔
#     merge_requests/iid/notes) — et le SHELL n'en voit RIEN : il reçoit des
#     lignes CLÉ=VALEUR normalisées ;
#   - la GARDE de réponse est la même pour tous les verbes : aucune redirection
#     suivie, statut hors 2xx = cause nommée, corps vide = cause, non-JSON =
#     cause, forme inattendue (objet là où une liste est attendue) = cause.
#     Chaque cause dit le statut, le type, la taille, l'URL et le début du corps
#     EXPURGÉ du secret — c'est ce que le client doit lire, à la place de la trace ;
#   - le SECRET ne vient jamais d'argv : FORGE_SECRET (env) ou FORGE_SECRET_FILE.
#
# CONTRAT (appelé par scripts/lib/forge-api.sh, jamais directement par un job) :
#   forge-api.py <verbe> [args…]     stdout : CLÉ=VALEUR (une par ligne) · rc 0
#                                    stderr : la CAUSE, en une ligne        · rc 2
#   L'APPELANT nomme le tag (FORGE_ILLISIBLE, FORGE_NON_CONFIRMEE…) : les
#   contrats de refus existants ne bougent pas, seule la cause s'enrichit.
#
# ENV : FORGE_KIND (gitea|gitlab, défaut gitea) · GIT_HOST (requis, aucun repli)
#       · FORGE_API_BASE (option : un reverse-proxy qui déplace /api) · GIT_REPO
#       (owner/repo, requis) · FORGE_API_AUTH (token|private-token|bearer|basic ;
#       défaut token pour gitea, private-token pour gitlab) · FORGE_USER (basic)
#       · FORGE_SECRET | FORGE_SECRET_FILE · FORGE_TIMEOUT (défaut 30)
#       · STOA_DEBUG (mode debug, ci-dessous).
#
# MODE DEBUG (STOA_DEBUG, plan L2). Une ligne par requête HTTP, écrite par CE
# process sur stderr : « GET url -> HTTP 200 (42 octets) » — le format de
# dbg_http (ci/lib/dbg.sh), pour qu'un log Jenkins archivé se grep d'une seule
# façon — ou « GET url -> ERREUR URLError » quand rien n'a répondu. Elle est
# écrite AVANT toute cause : un log se lit de haut en bas, le statut d'abord, le
# refus ensuite. Elle est masquée par _mask, PAS par le redact shell de dbg.sh,
# et voici pourquoi : ce process est un ENFANT de forge() ; faire passer sa
# sortie debug par redact obligerait forge() à capturer son stderr, ce qui
# retiendrait la CAUSE d'un refus jusqu'à la fin du process et doublerait la
# plomberie de chaque verbe. _mask est déjà l'autorité de ses causes depuis L1
# (scripts/test-app-request-a7.sh E6.9 le prouve : le corps cité dans un refus
# porte « <secret masqué> », jamais le jeton) — la ligne de debug suit le même
# chemin que la cause. Comme redact, _mask connaît chaque secret sous ses
# formes d'URL (quote, quote_plus) : un chemin ou une ref qui le porte entre
# dans l'URL encodé, et c'est la ligne de CHAQUE requête qui le montrerait
# (test-forge-api P.7c-P.7e). _dbg_on lit STOA_DEBUG comme dbg_on de dbg.sh
# (vide, 0, false, off, no ⇒ muet ; test-forge-api P.6 le vérifie valeur par
# valeur). Jamais stdout : stdout est le produit CLÉ=VALEUR que forge_kv relit.
#
# Preuve : scripts/test-forge-api.sh (mock à deux visages, formes RÉELLES,
# mutations champ par champ) et scripts/test-forge-api-live.sh (le GitLab CE et
# le Gitea du lab, mêmes assertions).
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


# ── refus et expurgation ────────────────────────────────────────────────────
class ForgeError(Exception):
    """Une cause nommée, prête à être écrite sur stderr — jamais une trace."""


_FD3 = None


def _secret_fd3():
    """Le secret que forge-api.sh dépose sur le DESCRIPTEUR 3 par here-doc
    (« S=<secret> ») : un préfixe `FORGE_SECRET=… python3` serait TRACÉ sous
    `set -x` (mesuré, bash et dash), le contenu d'un here-doc jamais. Le
    marqueur « S= » refuse un fd 3 hérité d'ailleurs. Lu UNE fois et mémorisé,
    sur un DUPLICATA du descripteur : fermer le 3 lui-même le rendrait libre,
    et le prochain fichier ouvert (corps de note, socket HTTP) hériterait de
    son numéro — mesuré sur un GitLab réel (comment_upsert = deux appels)."""
    global _FD3
    if _FD3 is not None:
        return _FD3
    _FD3 = ""
    try:
        with os.fdopen(os.dup(3), encoding="utf-8") as fh:
            body = fh.read()
    except (OSError, ValueError):
        return _FD3
    if body.startswith("S="):
        _FD3 = body[2:].rstrip("\n").strip()
    return _FD3


def _secret():
    f = os.environ.get("FORGE_SECRET_FILE")
    if f:
        try:
            with open(f, encoding="utf-8") as fh:
                return fh.read().strip()
        except OSError as e:
            raise ForgeError("FORGE_SECRET_FILE illisible (%s)" % e.__class__.__name__)
    return _secret_fd3() or (os.environ.get("FORGE_SECRET") or os.environ.get("GITEA_TOKEN") or "").strip()


def _secrets_connus(s):
    """Tout ce qui doit être masqué dans une cause ou une ligne de debug : le
    secret EN USAGE et ceux que l'environnement porte encore (le token de
    service pendant un pr_open sous le token du pousseur, par exemple) — chacun
    sous ses FORMES D'URL, pas seulement en clair. Un secret que l'appelant
    passe en chemin (`forge raw <chemin>`) ou en ref entre dans l'URL par quote
    (GitLab : t-s%2Bvc, %3A, %2F, %20) ou par urlencode (la query, « + » pour
    l'espace) : le littéral brut n'y est plus et un masque qui ne connaît que
    lui laisse la forme encodée en clair dans la ligne de CHAQUE requête et dans
    la cause d'un refus (mesuré L2-A1 tour 1, test-forge-api P.7c-P.7e). Le
    modèle est redact de ci/lib/dbg.sh : quote(x) et quote_plus(x) de chaque
    littéral. Une forme identique au littéral (secret URL-safe) n'est pas
    doublée."""
    for t in (s, os.environ.get("FORGE_SECRET"), os.environ.get("GITEA_TOKEN")):
        t = (t or "").strip()
        if not t:
            continue
        formes = (t, urllib.parse.quote(t, safe=""), urllib.parse.quote_plus(t, safe=""))
        for forme in formes:
            if forme not in _SECRETS:
                _SECRETS.append(forme)


_SECRETS = []
_M = "<secret masqué>"
# La FORME « ://userinfo@ » d'une URL. Le masque est un ATOME de la classe : si
# le mot de passe était un littéral connu, le premier passage laisse
# « svc:<secret masqué>@ » et la forme doit reprendre l'userinfo EN ENTIER —
# même arbitrage que dbg.sh (F.1-F.4) : une forme qui s'arrêterait au blanc du
# masque laisserait le login dans un log archivé (test-forge-api P.10b).
_USERINFO = re.compile(r"://(?:" + re.escape(_M) + r"|[^/@\s])+@")


def _mask(s):
    """Les LITTÉRAUX connus du process, du plus long au plus court, puis la
    FORME. Le plus long d'abord (comme redact de dbg.sh) : deux secrets dont
    l'un est un préfixe de l'autre (t-svc en usage, t-svc-long encore dans
    l'env) laisseraient « <secret masqué>-long » si le court passait en premier
    (test-forge-api P.7f). Un GIT_HOST qui porterait user:mdp ne doit fuiter ni
    dans la ligne de debug ni dans une cause — l'hôte RESTE, c'est lui qu'on
    diagnostique."""
    for t in sorted(_SECRETS, key=len, reverse=True):
        if t:
            s = s.replace(t, _M)
    return _USERINFO.sub("://" + _M + "@", s)


def _dbg_on():
    """Vrai SAUF si STOA_DEBUG vaut vide, 0, false, off ou no (valeur nettoyée,
    en minuscules) : la liste de dbg_on dans ci/lib/dbg.sh — les deux autorités
    doivent répondre pareil, test-forge-api P.6 le vérifie valeur par valeur."""
    return (os.environ.get("STOA_DEBUG") or "").strip().lower() not in ("", "0", "false", "off", "no")


def _dbg(texte):
    """Une ligne de debug : stderr SEULEMENT (stdout est le produit), masquée par
    _mask ICI et nulle part avant — les appelants donnent l'URL BRUTE : c'est
    cette fonction l'autorité du masque de la ligne, et le mutant P.8 (un _dbg
    sans _mask) ne rougirait rien si l'URL arrivait déjà masquée. flush : la
    ligne doit PRÉCÉDER la cause qu'un refus écrira juste après, quel que soit
    le tampon (test-forge-api P.4)."""
    if _dbg_on():
        sys.stderr.write("[dbg forge-api.py] " + _mask(texte) + "\n")
        sys.stderr.flush()


def _debut(b):
    """Le DÉBUT d'un corps cité dans une cause : masqué EN ENTIER, PUIS coupé à
    120 caractères — dans cet ordre et pas un autre. Coupé d'abord, un secret
    qui chevauche l'octet 120 n'est plus le littéral connu : `_mask` ne le voit
    pas et son préfixe sort en clair dans la cause — un chemin INCONDITIONNEL
    (pas même gardé par STOA_DEBUG) qui finit dans le log Jenkins archivé et,
    par provision-plan.sh, dans PLAN_REASON (mesuré : PAT de 40 caractères à
    l'offset 100, 20 en clair ; test-forge-api P.11, mutant P.11c)."""
    return _mask(b.decode("utf-8", "replace"))[:120]


# ── visage, base, en-tête ───────────────────────────────────────────────────
def kind():
    k = (os.environ.get("FORGE_KIND") or "gitea").strip().lower()
    if k not in ("gitea", "gitlab"):
        raise ForgeError("FORGE_KIND inconnu : '%s' — attendu gitea ou gitlab" % k)
    return k


def api_base():
    """UNE composition de la base d'API. Slash final retiré (13 des 14 anciennes
    compositions ne le faisaient pas : un clone vert suivi d'un appel d'API mort,
    sans que rien ne le nomme). FORGE_API_BASE pour un reverse-proxy qui déplace
    /api — l'adresse qu'une entreprise déplace le plus souvent."""
    b = (os.environ.get("FORGE_API_BASE") or "").strip()
    if b:
        return b.rstrip("/")
    h = (os.environ.get("GIT_HOST") or "").strip()
    if not h:
        raise ForgeError("GIT_HOST requis (base de la forge, ex. https://forge.client) — aucun repli")
    if not re.match(r"^https?://", h):
        raise ForgeError("GIT_HOST doit porter son schéma (http:// ou https://) : '%s'" % _mask(h))
    return h.rstrip("/") + ("/api/v4" if kind() == "gitlab" else "/api/v1")


def auth_header():
    mode = (os.environ.get("FORGE_API_AUTH") or ("private-token" if kind() == "gitlab" else "token")).strip().lower()
    s = _secret()
    if not s:
        raise ForgeError("FORGE_SECRET requis (ou FORGE_SECRET_FILE) — le secret de la forge")
    if mode == "token":
        return {"Authorization": "token " + s}
    if mode == "private-token":
        return {"PRIVATE-TOKEN": s}
    if mode == "bearer":
        return {"Authorization": "Bearer " + s}
    if mode == "basic":
        u = (os.environ.get("FORGE_USER") or "").strip()
        if not u:
            raise ForgeError("FORGE_USER requis : FORGE_API_AUTH=basic exige l'utilisateur du couple")
        b64 = base64.b64encode(("%s:%s" % (u, s)).encode()).decode()
        _SECRETS.append(b64)
        return {"Authorization": "Basic " + b64}
    raise ForgeError("FORGE_API_AUTH inconnu : '%s' — attendu token, private-token, bearer ou basic" % mode)


def repo_path():
    r = (os.environ.get("GIT_REPO") or "").strip().strip("/")
    if not r or "/" not in r:
        raise ForgeError("GIT_REPO requis, sous la forme owner/repo (lu : '%s')" % r)
    if r.endswith(".git"):
        raise ForgeError("GIT_REPO ne doit pas finir par .git ('%s') — c'est le chemin de la forge, pas l'URL du clone" % r)
    if kind() == "gitlab":
        # GitLab adresse un projet par son chemin URL-ENCODÉ (ci%2Fstoa-labs).
        return "projects/" + urllib.parse.quote(r, safe="")
    return "repos/" + r


# ── la garde ────────────────────────────────────────────────────────────────
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def call(method, path, data=None, want=None, query=None, raw=False, allow_404=False):
    """Appelle <base>/<path> et rend le JSON (de la forme `want`), ou les octets si raw.
    Toute réponse hors contrat lève ForgeError avec une cause auto-diagnostique."""
    url = api_base() + "/" + path.lstrip("/")
    if query:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query)
    headers = dict(auth_header())
    headers["Accept"] = "application/octet-stream" if raw else "application/json"
    body = None
    if data is not None:
        # UTF-8 tel quel (ensure_ascii=False) : un corps de PR ou de commentaire est
        # écrit en français ; échappé en \uXXXX il resterait valide pour la forge
        # mais illisible dans tout journal, stub ou relecture d'un humain.
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    timeout = float(os.environ.get("FORGE_TIMEOUT") or 30)
    u = _mask(url)
    try:
        with _opener.open(req, timeout=timeout) as resp:
            content = resp.read()
            st = resp.getcode()
            ct = resp.headers.get("Content-Type") or "(type absent)"
    except urllib.error.HTTPError as e:
        content = e.read() or b""
        ct = e.headers.get("Content-Type") or "(type absent)"
        # 3xx compris : c'est la ligne que le client GitLab aurait vue (302 vers /users/sign_in).
        _dbg("%s %s -> HTTP %d (%d octets)" % (method, url, e.code, len(content)))
        diag = "%s %s → HTTP %d %s, %d octet(s), début : %r" % (method, u, e.code, ct, len(content), _debut(content))
        if e.code == 404 and allow_404:
            if kind() == "gitlab":
                sys.stderr.write("(note : sur GitLab un 404 vaut aussi « invisible pour ce jeton » — %s)\n" % _mask(diag))
            return None
        if 300 <= e.code < 400:
            loc = _mask(e.headers.get("Location") or "(sans Location)")
            raise ForgeError("la forge REDIRIGE vers %s — GIT_HOST doit être l'URL finale de la forge, et une forge qui redirige /api/%s vers une page de connexion n'est pas de ce visage (FORGE_KIND=%s) ; %s"
                             % (loc, "v4" if kind() == "gitlab" else "v1", kind(), diag))
        if e.code in (401, 403):
            raise ForgeError("la forge REFUSE le secret ou son scope (FORGE_API_AUTH=%s) ; %s"
                             % ((os.environ.get("FORGE_API_AUTH") or "défaut"), diag))
        if e.code == 404 and kind() == "gitlab":
            raise ForgeError("introuvable — sur GitLab, un 404 vaut aussi « pas le droit de voir » (projet privé, PAT sans scope api) ; %s" % diag)
        raise ForgeError(diag)
    except ForgeError:
        raise
    except Exception as e:  # réseau, TLS, DNS, timeout
        _dbg("%s %s -> ERREUR %s" % (method, url, e.__class__.__name__))
        raise ForgeError("forge injoignable : %s %s (%s : %s)" % (method, u, e.__class__.__name__, _mask(str(e))))
    _dbg("%s %s -> HTTP %d (%d octets)" % (method, url, st, len(content)))
    diag = "%s %s → HTTP %d %s, %d octet(s), début : %r" % (method, u, st, ct, len(content), _debut(content))
    if raw:
        return content
    if not content:
        if want is None and st in (200, 201, 204):
            return None
        raise ForgeError("corps VIDE — " + diag)
    try:
        d = json.loads(content)
    except Exception:
        raise ForgeError("réponse NON JSON (page HTML d'un proxy, d'un portail SSO, ou d'une forge qui ne parle pas ce visage ?) — " + diag)
    if want is list and not isinstance(d, list):
        quoi = "un OBJET JSON (dict)" if isinstance(d, dict) else "un %s" % type(d).__name__
        raise ForgeError("%s a été rendu là où une LISTE était attendue (une forge ou un proxy qui normalise ses erreurs en 200 ?) — %s" % (quoi, diag))
    if want is dict and not isinstance(d, dict):
        quoi = "une LISTE" if isinstance(d, list) else "un %s" % type(d).__name__
        raise ForgeError("%s a été rendu là où un OBJET était attendu — %s" % (quoi, diag))
    return d


PAGES_MAX = 40


def paged(path, query, key_page="page", per_page=50):
    """Itère les pages jusqu'à une page VIDE — jamais « plus courte que la limite » :
    Gitea plafonne `limit` à MAX_RESPONSE_ITEMS (souvent < 50 chez un client)."""
    seen = set()
    for page in range(1, PAGES_MAX + 1):
        q = dict(query or {})
        q[key_page] = page
        q["per_page" if kind() == "gitlab" else "limit"] = per_page
        chunk = call("GET", path, want=list, query=q)
        ids = {id(c) if not isinstance(c, dict) else (c.get("id"), c.get("iid"), c.get("number")) for c in chunk}
        if not chunk or ids <= seen:
            return
        seen |= ids
        for c in chunk:
            if isinstance(c, dict):
                yield c
    # Jamais un silence : au-delà du plafond, la liste (lignée de PR, fil de
    # commentaires) serait INCOMPLÈTE et l'appelant déciderait sur un tronçon.
    raise ForgeError("pagination TRONQUÉE : plus de %d pages de %d sur %s — la liste serait incomplète, refusé (fail-closed)"
                     % (PAGES_MAX, per_page, path))


# ── sortie normalisée ───────────────────────────────────────────────────────
def out(**kv):
    for k, v in kv.items():
        v = "" if v is None else str(v)
        if "\n" in v or "\r" in v:
            raise ForgeError("la forge a rendu un %s portant un retour-ligne — refusé (il entrerait dans un script)" % k)
        print("%s=%s" % (k, v))


def line(**kv):
    """UNE ligne « CLÉ=VALEUR CLÉ=VALEUR … » pour les verbes qui rendent une LISTE
    d'objets (une PR par ligne). Chaque valeur est refusée si elle porte un
    blanc : c'est ce qui permet au shell de la lire par `read -r` et un `for`
    sans deviner où finit un champ (numéros, SHA, refs et chemins de dépôt n'en
    portent jamais — une forge qui en rendrait un ne dit pas ce qu'elle promet)."""
    parts = []
    for k, v in kv.items():
        v = "" if v is None else str(v)
        if re.search(r"\s", v):
            raise ForgeError("la forge a rendu un %s portant un blanc ('%s') — refusé (il casserait la ligne lue par le shell)" % (k, _mask(v[:40])))
        parts.append("%s=%s" % (k, v))
    print(" ".join(parts))


def _str(d, *keys):
    for k in keys:
        d = d.get(k) if isinstance(d, dict) else None
        if d is None:
            return ""
    return "" if d is None else str(d)


# ── les verbes ──────────────────────────────────────────────────────────────
def v_probe():
    """Quel visage parle cette forge ? Sans secret. KIND_DETECTED=gitea|gitlab|inconnu."""
    h = (os.environ.get("GIT_HOST") or "").rstrip("/")
    if not h:
        raise ForgeError("GIT_HOST requis")
    det = "inconnu"
    notes = []
    for label, path, ok_codes in (("gitea", "/api/v1/version", (200,)), ("gitlab", "/api/v4/version", (200, 401))):
        url = h + path
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            with _opener.open(req, timeout=15) as r:
                code, ct, n = r.getcode(), r.headers.get("Content-Type") or "", len(r.read())
        except urllib.error.HTTPError as e:
            code, ct, n = e.code, (e.headers.get("Content-Type") or ""), len(e.read() or b"")
        except Exception as e:
            _dbg("GET %s -> ERREUR %s" % (url, e.__class__.__name__))
            notes.append("%s:%s" % (label, e.__class__.__name__))
            continue
        _dbg("GET %s -> HTTP %d (%d octets)" % (url, code, n))
        notes.append("%s:%d" % (label, code))
        if code in ok_codes and "json" in ct:
            det = label
            break
    out(KIND_DETECTED=det, PROBE=" ".join(notes))


def v_whoami():
    d = call("GET", "user", want=dict)
    login = _str(d, "username") if kind() == "gitlab" else _str(d, "login")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", login or ""):
        raise ForgeError("login de forge absent ou hors de [A-Za-z0-9._-] ('%s')" % _mask(login))
    out(LOGIN=login)


def _norm_pr(d):
    """Une PR/MR sous la même forme, quel que soit le visage."""
    repo = (os.environ.get("GIT_REPO") or "").strip().strip("/")
    if kind() == "gitlab":
        state_raw = _str(d, "state")
        merged = state_raw == "merged"
        return dict(
            NUMBER=_str(d, "iid"), STATE={"opened": "open", "locked": "open"}.get(state_raw, state_raw), STATE_RAW=state_raw,
            HEAD_REF=_str(d, "source_branch"), HEAD_SHA=_str(d, "sha"), BASE_REF=_str(d, "target_branch"),
            SAME_REPO="1" if _str(d, "source_project_id") == _str(d, "target_project_id") else "0",
            MERGED="1" if merged else "0", MERGE_SHA=_str(d, "merge_commit_sha"),
            MERGED_BY=_str(d, "merge_user", "username") or _str(d, "merged_by", "username"),
            LOGIN=_str(d, "author", "username"), URL=_str(d, "web_url"),
        )
    state_raw = _str(d, "state")
    merged = bool(d.get("merged"))
    return dict(
        NUMBER=_str(d, "number"), STATE="merged" if merged else state_raw, STATE_RAW=state_raw,
        HEAD_REF=_str(d, "head", "ref"), HEAD_SHA=_str(d, "head", "sha"), BASE_REF=_str(d, "base", "ref"),
        SAME_REPO="1" if (_str(d, "head", "repo", "full_name") or repo) == repo else "0",
        MERGED="1" if merged else "0", MERGE_SHA=_str(d, "merge_commit_sha"),
        MERGED_BY=_str(d, "merged_by", "login"), LOGIN=_str(d, "user", "login"), URL=_str(d, "html_url"),
    )


def v_pr_find_open(head):
    if not head:
        raise ForgeError("pr_find_open exige la branche de tête")
    rp = repo_path()
    if kind() == "gitlab":
        it = paged(rp + "/merge_requests", {"state": "opened", "source_branch": head})
    else:
        it = paged(rp + "/pulls", {"state": "open"})
    for d in it:
        n = _norm_pr(d)
        if n["HEAD_REF"] == head and n["SAME_REPO"] == "1":
            out(NUMBER=n["NUMBER"], LOGIN=n["LOGIN"], URL=n["URL"])
            return
    out(NUMBER="", LOGIN="", URL="")


def v_pr_list_merged(head):
    """Les PR MERGÉES dont la tête est <head> — UNE ligne par PR :
      NUMBER= MERGE_SHA= BASE_REF= SAME_REPO=0|1 HEAD_REPO=
    C'est la LIGNÉE d'une branche (app-rollback-request.sh §6, A6) : la forge
    est la vérité sur « quelles PR ont été mergées », Git reste la vérité sur
    leur ORDRE (première parenté de la base) — l'ordre rendu ici est celui de la
    forge, sans valeur. Gitea ne filtre pas ses pulls par tête : on parcourt
    `state=closed` (fermées ET mergées) et on ne garde que les mergées ; GitLab
    filtre côté serveur (state=merged&source_branch=…). Le filtre est REJOUÉ ici
    dans les deux cas : la forge n'est pas crue sur parole. Une PR de FORK est
    rendue (SAME_REPO=0) : c'est l'appelant qui décide qu'une lignée à laquelle
    un fork a contribué est ambiguë (LIGNEE_AMBIGUE), pas l'adaptateur."""
    if not head:
        raise ForgeError("pr_list_merged exige la branche de tête")
    rp = repo_path()
    if kind() == "gitlab":
        it = paged(rp + "/merge_requests", {"state": "merged", "source_branch": head})
    else:
        it = paged(rp + "/pulls", {"state": "closed"})
    # La liste est MATÉRIALISÉE avant la première ligne écrite : une pagination
    # qui refuse en cours de route (tronquée, forge muette) ne doit rien avoir
    # laissé sur stdout — rc 2 = cause sur stderr, RIEN sur stdout, sans exception.
    rows = []
    for d in it:
        n = _norm_pr(d)
        if n["HEAD_REF"] != head or n["MERGED"] != "1":
            continue
        # GitLab ne nomme le dépôt source que par son id de projet (le chemin
        # exigerait un appel de plus) ; Gitea rend son full_name.
        head_repo = ("project:" + _str(d, "source_project_id")) if kind() == "gitlab" else (_str(d, "head", "repo", "full_name") or "?")
        rows.append(dict(NUMBER=n["NUMBER"], MERGE_SHA=n["MERGE_SHA"], BASE_REF=n["BASE_REF"], SAME_REPO=n["SAME_REPO"], HEAD_REPO=head_repo))
    for r in rows:
        line(**r)


def v_pr_get(n):
    if not re.fullmatch(r"[0-9]+", n or ""):
        raise ForgeError("numéro de PR non numérique ('%s') — jamais un chemin forgé" % n)
    rp = repo_path()
    d = call("GET", rp + ("/merge_requests/%s" % n if kind() == "gitlab" else "/pulls/%s" % n), want=dict)
    out(**_norm_pr(d))


def v_pr_open(head, base, title, bodyfile):
    if not (head and base and title):
        raise ForgeError("pr_open exige head, base et titre")
    try:
        body = open(bodyfile, encoding="utf-8").read() if bodyfile else ""
    except OSError as e:
        raise ForgeError("fichier de corps illisible (%s)" % e.__class__.__name__)
    rp = repo_path()
    if kind() == "gitlab":
        d = call("POST", rp + "/merge_requests", want=dict,
                 data={"source_branch": head, "target_branch": base, "title": title, "description": body, "remove_source_branch": False})
    else:
        d = call("POST", rp + "/pulls", want=dict, data={"head": head, "base": base, "title": title, "body": body})
    n = _norm_pr(d)
    if not n["NUMBER"]:
        raise ForgeError("la forge a accepté la PR mais n'a rendu aucun numéro")
    out(NUMBER=n["NUMBER"], URL=n["URL"])


PREPARE_WAIT = int(os.environ.get("FORGE_PREPARE_WAIT") or "30")


def _gitlab_wait_prepared(n):
    """GitLab calcule le diff d'une MR EN ASYNCHRONE — mesuré 17.11 le
    2026-09-09 : `prepared_at` nul et `detailed_merge_status=preparing` pendant
    3-4 s après la création, `/diffs` rend [] entre-temps. Un webhook « open »
    arrive AVANT : lire les fichiers à ce moment-là dirait « aucun fichier » et
    la porte de périmètre refuserait à tort. On attend, borné
    (FORGE_PREPARE_WAIT s, défaut 30) ; au-delà, refus NOMMÉ — jamais une liste
    vide prise pour vraie. Une forge sans ces champs (GitLab ancien) : pas
    d'attente."""
    rp = repo_path()
    deadline = time.monotonic() + PREPARE_WAIT
    while True:
        d = call("GET", rp + "/merge_requests/%s" % n, want=dict)
        if "prepared_at" in d:
            ready = bool(d.get("prepared_at"))
        elif "detailed_merge_status" in d:
            ready = d.get("detailed_merge_status") != "preparing"
        else:
            ready = True
        if ready:
            return
        if time.monotonic() >= deadline:
            raise ForgeError("MR #%s encore en PRÉPARATION après %d s (prepared_at nul, detailed_merge_status=%s) — GitLab calcule son diff en asynchrone : rejouer" % (n, PREPARE_WAIT, d.get("detailed_merge_status")))
        time.sleep(1)


def v_pr_files(n):
    if not re.fullmatch(r"[0-9]+", n or ""):
        raise ForgeError("numéro de PR non numérique ('%s')" % n)
    rp = repo_path()
    if kind() == "gitlab":
        _gitlab_wait_prepared(n)
        for d in paged(rp + "/merge_requests/%s/diffs" % n, {}):
            p = _str(d, "new_path") or _str(d, "old_path")
            if p:
                print(p)
    else:
        for d in paged(rp + "/pulls/%s/files" % n, {}):
            p = _str(d, "filename")
            if p:
                print(p)


def _comments_path(n):
    """Le fil de commentaires d'une PR, sous le nom que lui donne le visage :
    Gitea le range sous l'ISSUE (issues/N/comments), GitLab sous la MR
    (merge_requests/iid/notes). UN seul endroit : comment_find et comment_upsert
    paginent le même fil — deux compositions divergeraient un jour."""
    if not re.fullmatch(r"[0-9]+", n or ""):
        raise ForgeError("numéro de PR non numérique ('%s') — jamais un chemin forgé" % n)
    return repo_path() + ("/merge_requests/%s/notes" % n if kind() == "gitlab" else "/issues/%s/comments" % n)


def _comment_find(n, marker):
    """L'id du premier commentaire portant le marqueur, ou "" s'il n'y en a pas.
    On ne regarde QUE le marqueur : ni l'auteur (le compte de service change),
    ni le rang (d'autres commentaires s'intercalent). PAGINÉ jusqu'à une page
    VIDE (cf. paged) : un marqueur au-delà de la première page était invisible
    et le commentaire s'EMPILAIT (revue 2026-09-02)."""
    if not marker:
        raise ForgeError("un marqueur est exigé (c'est la clé d'idempotence du commentaire)")
    for c in paged(_comments_path(n), {}):
        if marker in (_str(c, "body") or ""):
            return _str(c, "id")
    return ""


def v_comment_find(n, marker):
    """ID=<id> si un commentaire porte le marqueur, ID= (vide) sinon — rc 0 dans
    les deux cas : « aucun commentaire » n'est pas une panne. Lecture seule.
    Sert à COMMENT_ONLY_IF_EXISTS (ne jamais CRÉER, seulement rafraîchir)."""
    out(ID=_comment_find(n, marker))


def v_comment_upsert(n, marker, bodyfile):
    path = _comments_path(n)          # valide le numéro AVANT de lire le fichier
    if not marker:
        raise ForgeError("comment_upsert exige un marqueur")
    try:
        text = open(bodyfile, encoding="utf-8").read()
    except OSError as e:
        raise ForgeError("fichier de commentaire illisible (%s)" % e.__class__.__name__)
    body = marker + "\n" + text
    existing = _comment_find(n, marker)
    if existing:
        if kind() == "gitlab":
            call("PUT", path + "/" + existing, want=dict, data={"body": body})
        else:
            # Gitea édite un commentaire par son id SEUL, hors de l'issue.
            call("PATCH", repo_path() + "/issues/comments/%s" % existing, want=dict, data={"body": body})
        out(ID=existing, ACTION="updated")
        return
    d = call("POST", path, want=dict, data={"body": body})
    out(ID=_str(d, "id"), ACTION="created")


def v_raw(path, ref=""):
    if not path:
        raise ForgeError("raw exige un chemin")
    rp = repo_path()
    if kind() == "gitlab":
        content = call("GET", rp + "/repository/files/%s/raw" % urllib.parse.quote(path, safe=""), raw=True,
                       query={"ref": ref} if ref else None)
    else:
        content = call("GET", rp + "/raw/" + path.lstrip("/"), raw=True, query={"ref": ref} if ref else None)
    sys.stdout.buffer.write(content)


def v_repo_get():
    """Le dépôt GIT_REPO existe-t-il, est-il vide, quelle HEAD annonce-t-il ? Un 404 est une réponse (EXISTS=0)."""
    d = call("GET", repo_path(), want=dict, allow_404=True)
    if d is None:
        out(EXISTS="0", EMPTY="", DEFAULT_BRANCH="", URL="")
        return
    champ = "empty_repo" if kind() == "gitlab" else "empty"
    if not isinstance(d.get(champ), bool):
        raise ForgeError("la forge a rendu un dépôt sans champ « %s » lisible — jamais « non vide » par défaut" % champ)
    out(EXISTS="1", EMPTY="1" if d[champ] else "0",
        DEFAULT_BRANCH=_str(d, "default_branch"),
        URL=_str(d, "web_url") if kind() == "gitlab" else _str(d, "html_url"))


VERBES = {  # nom: (fonction, min_args, max_args)
    "probe": (v_probe, 0, 0), "whoami": (v_whoami, 0, 0), "pr_find_open": (v_pr_find_open, 1, 1),
    "pr_list_merged": (v_pr_list_merged, 1, 1),
    "pr_get": (v_pr_get, 1, 1), "pr_open": (v_pr_open, 4, 4), "pr_files": (v_pr_files, 1, 1),
    "comment_find": (v_comment_find, 2, 2), "comment_upsert": (v_comment_upsert, 3, 3), "raw": (v_raw, 1, 2),
    "repo_get": (v_repo_get, 0, 0),
}


def main(argv):
    if len(argv) < 1 or argv[0] not in VERBES:
        sys.stderr.write("verbe inconnu — attendu : %s\n" % ", ".join(sorted(VERBES)))
        return 2
    fn, mn, mx = VERBES[argv[0]]
    args = argv[1:]
    if len(args) < mn:
        sys.stderr.write("%s attend %d argument(s)\n" % (argv[0], mn))
        return 2
    if len(args) > mx:
        # Refusé, jamais tronqué : un argument de trop est une erreur d'appelant, pas un détail.
        sys.stderr.write("%s attend au plus %d argument(s) (%d reçus)\n" % (argv[0], mx, len(args)))
        return 2
    try:
        s = _secret()
        _secrets_connus(s)
        fn(*args)
        return 0
    except ForgeError as e:
        sys.stderr.write("%s\n" % _mask(str(e)))
        return 2
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
