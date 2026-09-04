#!/usr/bin/env bash
# gitea-pr-comment.sh — poser OU mettre à jour UN commentaire identifié sur une
# Pull Request. Idempotent par MARQUEUR : le même appelant, rejoué, met à jour
# son commentaire au lieu d'en empiler un second.
#
# POURQUOI CE FICHIER EXISTE (2026-08-03). La logique vivait à l'intérieur de
# provision-plan.sh. ADR-081 fait remonter AUSSI le statut de l'apply sur la PR :
# sans extraction, le même upsert serait réécrit une deuxième fois, et un jour
# l'une des deux copies serait corrigée et pas l'autre. Même raisonnement que
# cert-der.yml (apply/verify) et strategies-list.yml (consumer-auth/rotate).
#
# LE MARQUEUR EST LA CLÉ D'IDEMPOTENCE, pas l'auteur ni le rang. Un commentaire
# par RÔLE (plan, apply) : deux marqueurs différents cohabitent sur la même PR
# sans jamais s'écraser, et chacun raconte l'état COURANT de son étape plutôt
# qu'un historique que personne ne relit.
#
# Entrées (env) :
#   GIT_REPO      full-name (ex. ci/stoa-labs)
#   FORGE_SECRET   token (scope write:issue) — JAMAIS en argv, jamais loggé
#   PR_NUMBER     numéro de la PR
#   COMMENT_MARKER      marqueur HTML invisible (ex. '<!-- provision-apply -->')
#   COMMENT_BODY_FILE   fichier contenant le corps SANS le marqueur
#   GIT_HOST      base Gitea vue de l'agent (défaut http://gitea:3000)
#   COMMENT_ONLY_IF_EXISTS=1  (A0 dettes) ne fait QUE mettre à jour un commentaire
#                 déjà présent sous ce marqueur — s'il n'existe pas, ne crée rien
#                 et rend "COMMENT_SKIPPED" (rc 0). Sert au statut de build de
#                 provision-plan : en SUCCESS il n'ajoute pas un troisième
#                 commentaire redondant, il efface seulement un rouge périmé.
#
# Sortie : "COMMENT_UPDATED <id>", "COMMENT_CREATED <id>" ou "COMMENT_SKIPPED".
# Échec = code 1. Réseau : timeout 30 s par appel ; la recherche du marqueur
# PAGINE jusqu'à une page VIDE (limit=50&page=N — Gitea pagine par défaut ET
# plafonne `limit` : un marqueur au-delà de la première page était invisible
# et le commentaire se serait EMPILÉ).
set -uo pipefail
set +x

GIT_REPO="${GIT_REPO:?GIT_REPO requis}"
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN" >&2; exit 2; }
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
COMMENT_MARKER="${COMMENT_MARKER:?COMMENT_MARKER requis}"
COMMENT_BODY_FILE="${COMMENT_BODY_FILE:?COMMENT_BODY_FILE requis}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"

[ -f "$COMMENT_BODY_FILE" ] || { echo "COMMENT_BODY_FILE introuvable : $COMMENT_BODY_FILE" >&2; exit 1; }

API="${GIT_HOST}/api/v1" \
GIT_REPO="$GIT_REPO" FORGE_SECRET="$FORGE_SECRET" PR_NUMBER="$PR_NUMBER" \
COMMENT_MARKER="$COMMENT_MARKER" COMMENT_BODY_FILE="$COMMENT_BODY_FILE" \
COMMENT_ONLY_IF_EXISTS="${COMMENT_ONLY_IF_EXISTS:-0}" \
python3 - <<'PY'
import os, json, urllib.request, urllib.error, sys
api  = os.environ["API"]
repo = os.environ["GIT_REPO"]
tok  = os.environ["FORGE_SECRET"]
prn  = os.environ["PR_NUMBER"]
mark = os.environ["COMMENT_MARKER"]
only_if_exists = os.environ.get("COMMENT_ONLY_IF_EXISTS", "0") == "1"
body = mark + "\n" + open(os.environ["COMMENT_BODY_FILE"]).read()

def call(method, url, data=None):
    r = urllib.request.Request(
        url,
        data=(json.dumps(data).encode() if data is not None else None),
        method=method,
        headers={"Authorization": "token " + tok, "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read() or "null")

try:
    # Le commentaire de CE rôle existe-t-il déjà ? On ne regarde que le marqueur :
    # ni l'auteur (le compte de service peut changer) ni la position (d'autres
    # commentaires s'intercalent) ne sont des clés fiables. PAGINÉ jusqu'à une
    # page VIDE — jamais « plus courte que limit » : Gitea PLAFONNE `limit` à
    # api.MAX_RESPONSE_ITEMS (50 par défaut, souvent moins chez un client), une
    # page pleine de 30 aurait été prise pour la dernière (revue 2026-09-02).
    # Une forge qui ignorerait `page` rend la même page : détectée par ses ids,
    # on s'arrête. Borne haute de 40 pages.
    existing = None
    LIMIT = 50
    seen_ids = set()
    for page in range(1, 41):
        chunk = call("GET", f"{api}/repos/{repo}/issues/{prn}/comments?limit={LIMIT}&page={page}") or []
        ids = {c.get("id") for c in chunk}
        if not chunk or ids <= seen_ids:
            break
        seen_ids |= ids
        for c in chunk:
            if mark in (c.get("body") or ""):
                existing = c["id"]
                break
        if existing is not None:
            break
    if existing is not None:
        call("PATCH", f"{api}/repos/{repo}/issues/comments/{existing}", {"body": body})
        print(f"COMMENT_UPDATED {existing}")
    elif only_if_exists:
        print("COMMENT_SKIPPED")
    else:
        c = call("POST", f"{api}/repos/{repo}/issues/{prn}/comments", {"body": body})
        print(f"COMMENT_CREATED {c['id']}")
except urllib.error.HTTPError as e:
    # Le corps d'erreur peut contenir l'URL appelée, jamais le token (il est en
    # en-tête). On tronque tout de même : un message d'API n'est pas un log.
    print(f"COMMENT_FAILED HTTP {e.code}: {e.read().decode()[:200]}", file=sys.stderr)
    raise SystemExit(1)
except Exception as e:
    print(f"COMMENT_FAILED {type(e).__name__}: {e}", file=sys.stderr)
    raise SystemExit(1)
PY
