#!/usr/bin/env bash
# scripts/lib/gitea-pr-confirm.sh — CONFIRMER une PR auprès de la FORGE avant
# d'agir en son nom. À SOURCER, jamais exécuté seul.
#
# POURQUOI CETTE LIB EXISTE (A0 dettes, 2026-09-02 — critique adverse, constat
# BLOQUANT). Un webhook generic-webhook-trigger porte un token partagé et aucun
# HMAC vérifié : son payload est une AFFIRMATION. Jusqu'ici, provision-plan.sh
# clonait la branche PR_BRANCH et commentait la PR PR_NUMBER TELS QUE NOMMÉS
# par le payload — un payload forgé (branche réelle de la PR A, numéro de la
# PR B) faisait poser au compte de service un VERDICT sur une PR étrangère.
# provision-apply, lui, relit la forge avant tout (provision-apply-reconcile.sh).
# Cette lib porte la même règle, en UN endroit, pour le plan ET son statut :
#
#   « jamais un geste du compte de service sur une PR seulement NOMMÉE. »
#
# gitea_pr_confirm <numéro> <head_ref attendu> [base_ref attendue (défaut main)]
#   GET /repos/<GIT_REPO>/pulls/<numéro> (python, token PAR ENV — jamais en
#   argv —, timeout 30 s). rc 0 et, sur stdout, quatre lignes
#     GITEA_STATE=open
#     GITEA_HEAD_REF=<head.ref>
#     GITEA_HEAD_SHA=<head.sha>
#     GITEA_BASE_REF=<base.ref>
#   SEULEMENT si : state == open, head.ref == attendu, head.ref ~ ^provision/,
#   base.ref == base attendue, et aucune valeur ne porte de retour-ligne.
#   Sinon rc 1 et `FORGE_NON_CONFIRMEE : <raison>` sur stderr — 404 (PR
#   inconnue), 5xx, timeout, réponse non-objet, champ absent, head.sha non
#   hexadécimal (jamais un argument libre pour git), PR depuis un FORK
#   (head.repo ≠ dépôt : sa tête n'est pas dans le clone), PR fermée ou
#   mergée (une branche provision/<app>-<env> RÉUTILISÉE après merge ne doit
#   pas faire commenter la PR mergée), tête ou base divergente.
#   Le numéro est validé ^[0-9]+$ AVANT de composer l'URL (jamais un chemin
#   forgé) ; rc 1 sans aucun appel réseau sinon.
#
# Entrées (env) : GIT_HOST (défaut http://gitea:3000), GIT_REPO (défaut
# ci/stoa-labs), GITEA_TOKEN (requis).
gitea_pr_confirm(){
  local n="${1:-}" want_head="${2:-}" want_base="${3:-main}"
  case "$n" in ''|*[!0-9]*) echo "FORGE_NON_CONFIRMEE : numero de PR non numerique ('$n')" >&2; return 1;; esac
  [ -n "$want_head" ] || { echo "FORGE_NON_CONFIRMEE : head_ref attendu vide" >&2; return 1; }
  case "$want_head" in provision/*) ;; *) echo "FORGE_NON_CONFIRMEE : head_ref attendu hors provision/* ('$want_head')" >&2; return 1;; esac
  GITEA_TOKEN="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
  [ -n "$GITEA_TOKEN" ] || { echo "FORGE_NON_CONFIRMEE : ni FORGE_SECRET ni GITEA_TOKEN" >&2; return 1; }
  PC_API="${GIT_HOST:-http://gitea:3000}/api/v1" PC_REPO="${GIT_REPO:-ci/stoa-labs}" PC_TOKEN="$GITEA_TOKEN" \
  PC_N="$n" PC_HEAD="$want_head" PC_BASE="$want_base" python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error
api, repo, tok = os.environ["PC_API"], os.environ["PC_REPO"], os.environ["PC_TOKEN"]
n, want_head, want_base = os.environ["PC_N"], os.environ["PC_HEAD"], os.environ["PC_BASE"]
def refuse(why):
    print("FORGE_NON_CONFIRMEE : " + why, file=sys.stderr); sys.exit(1)
req = urllib.request.Request(f"{api}/repos/{repo}/pulls/{n}", headers={"Authorization": "token " + tok})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
except urllib.error.HTTPError as e:
    refuse(f"forge HTTP {e.code} sur la PR #{n}")
except Exception as e:
    refuse(f"forge injoignable ({type(e).__name__})")
try:
    pr = json.loads(raw)
except Exception:
    refuse("reponse de la forge illisible (pas un JSON)")
if not isinstance(pr, dict):
    refuse("reponse de la forge : pas un objet PR")
head, base = pr.get("head") or {}, pr.get("base") or {}
state, href, hsha, bref = pr.get("state"), head.get("ref"), head.get("sha"), base.get("ref")
for name, v in (("state", state), ("head.ref", href), ("head.sha", hsha), ("base.ref", bref)):
    if not isinstance(v, str) or not v:
        refuse(f"champ {name} absent de la PR #{n}")
    if "\n" in v or "\r" in v:
        refuse(f"champ {name} porte un retour-ligne")
import re as _re
if not _re.fullmatch(r"[0-9a-f]{40}", hsha):
    refuse(f"head.sha de la PR #{n} n'est pas un SHA hexadecimal de 40 caracteres")
head_repo = ((head.get("repo") or {}).get("full_name")) if isinstance(head.get("repo"), dict) else None
if head_repo is not None and head_repo != repo:
    refuse(f"PR #{n} vient d'un FORK ({head_repo}) — sa tete n'est pas dans le depot {repo}")
if state != "open":
    refuse(f"PR #{n} n'est pas ouverte (state={state}) — une PR fermee ou mergee ne recoit plus de plan")
if href != want_head:
    refuse(f"tete de la PR #{n} = '{href}', le payload nommait '{want_head}'")
if not href.startswith("provision/"):
    refuse(f"tete de la PR #{n} hors provision/* ('{href}')")
if bref != want_base:
    refuse(f"base de la PR #{n} = '{bref}', attendu '{want_base}'")
print("GITEA_STATE=open"); print("GITEA_HEAD_REF=" + href); print("GITEA_HEAD_SHA=" + hsha); print("GITEA_BASE_REF=" + bref)
PY
}
