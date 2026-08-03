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
#   GITEA_TOKEN   token (scope write:issue) — JAMAIS en argv, jamais loggé
#   PR_NUMBER     numéro de la PR
#   COMMENT_MARKER      marqueur HTML invisible (ex. '<!-- provision-apply -->')
#   COMMENT_BODY_FILE   fichier contenant le corps SANS le marqueur
#   GIT_HOST      base Gitea vue de l'agent (défaut http://gitea:3000)
#
# Sortie : "COMMENT_UPDATED <id>" ou "COMMENT_CREATED <id>". Échec = code 1.
set -uo pipefail
set +x

GIT_REPO="${GIT_REPO:?GIT_REPO requis}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
COMMENT_MARKER="${COMMENT_MARKER:?COMMENT_MARKER requis}"
COMMENT_BODY_FILE="${COMMENT_BODY_FILE:?COMMENT_BODY_FILE requis}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"

[ -f "$COMMENT_BODY_FILE" ] || { echo "COMMENT_BODY_FILE introuvable : $COMMENT_BODY_FILE" >&2; exit 1; }

API="${GIT_HOST}/api/v1" \
GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" PR_NUMBER="$PR_NUMBER" \
COMMENT_MARKER="$COMMENT_MARKER" COMMENT_BODY_FILE="$COMMENT_BODY_FILE" \
python3 - <<'PY'
import os, json, urllib.request, urllib.error, sys
api  = os.environ["API"]
repo = os.environ["GIT_REPO"]
tok  = os.environ["GITEA_TOKEN"]
prn  = os.environ["PR_NUMBER"]
mark = os.environ["COMMENT_MARKER"]
body = mark + "\n" + open(os.environ["COMMENT_BODY_FILE"]).read()

def call(method, url, data=None):
    r = urllib.request.Request(
        url,
        data=(json.dumps(data).encode() if data is not None else None),
        method=method,
        headers={"Authorization": "token " + tok, "Content-Type": "application/json"})
    with urllib.request.urlopen(r) as resp:
        return json.loads(resp.read() or "null")

try:
    # Le commentaire de CE rôle existe-t-il déjà ? On ne regarde que le marqueur :
    # ni l'auteur (le compte de service peut changer) ni la position (d'autres
    # commentaires s'intercalent) ne sont des clés fiables.
    existing = None
    for c in call("GET", f"{api}/repos/{repo}/issues/{prn}/comments") or []:
        if mark in (c.get("body") or ""):
            existing = c["id"]
            break
    if existing is not None:
        call("PATCH", f"{api}/repos/{repo}/issues/comments/{existing}", {"body": body})
        print(f"COMMENT_UPDATED {existing}")
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
