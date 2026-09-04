#!/usr/bin/env bash
# provision-plan.sh — FERMETURE DE BOUCLE : une PR de provisioning ouverte
# déclenche le PLAN self-service sur la branche, et le RÉSULTAT est posté en
# commentaire sur la PR (visible avant la validation humaine).
#
#   PR ouverte (maillon 1) → webhook Gitea → job Jenkins → CE script :
#     1. checkout la branche de la PR
#     2. localise le manifeste ajouté (git diff vs main)
#     3. PLAN lecture seule : manifeste valide (name/api) + ansible --syntax-check
#        (identité de JOB, AUCUNE mutation, AUCUN secret — ADR-078 §2)
#     4. poste le verdict (✅/❌) en commentaire sur la PR (API Gitea)
#
# L'apply reste séparé (build nominatif au merge) : ici on ne fait que DONNER À
# VOIR au valideur que la demande passe le plan. Token jamais loggé (set +x).
#
# ── LA FORGE EST RELUE AVANT TOUT GESTE (A0 dettes, 2026-09-02) ─────────────
# Le payload d'un webhook est une AFFIRMATION (token GWT partagé, HMAC non
# vérifié) : jusqu'ici ce script clonait la branche PR_BRANCH et commentait la
# PR PR_NUMBER telles que NOMMÉES — un payload forgé (branche réelle de la PR A,
# numéro de la PR B) faisait poser un verdict du compte de service sur une PR
# étrangère. Désormais, AVANT le clone : scripts/lib/gitea-pr-confirm.sh relit
# la PR sur la forge et exige state=open, head.ref == PR_BRANCH (provision/*),
# base.ref == GIT_BASE — sinon refus nommé FORGE_NON_CONFIRMEE, rc 1, AUCUN
# commentaire. Le clone checkoute ensuite le SHA de tête RELU (pas le nom de
# branche : une branche provision/<app>-<env> réutilisée après merge ne fait
# jamais commenter la PR mergée). Un clone ou un checkout raté est un REFUS
# (CLONE_ECHEC / BRANCHE_INTROUVABLE, rc 1) — changement de parité assumé : il
# rendait vert par « IGNORE » (diff vide) avant.
#
# FAITS (PLAN_FACTS, optionnel) : si posé, un fichier KEY=VALUE est écrit sur
# CHAQUE sortie — GITEA_HEAD_REF / GITEA_HEAD_SHA (vides si la forge n'a pas
# confirmé), PLAN_VERDICT=refus|ignore|ok|fail, PLAN_REASON. C'est ce que le
# statut de build du job (scripts/provision-plan-status.sh) consomme : une
# seule relecture de la forge, jamais une seconde indépendante (pas de TOCTOU).
#
# Entrées (env — mappées depuis le payload webhook Gitea par le GWT du job) :
#   PR_BRANCH   (req) ref de la branche de la PR (ex. provision/credit-scoring-dev)
#   PR_NUMBER   (req) numéro de la PR (pour le commentaire)
#   FORGE_SECRET (req) token (scopes write:issue pour commenter)
#   PLAN_FACTS  fichier de faits (cf. ci-dessus) — vide = pas de faits écrits
#   GIT_REPO    full-name (défaut ci/stoa-labs)
#   GIT_BASE    branche cible (défaut main) — base du diff
#   GIT_HOST    base Gitea vue de l'agent (défaut http://gitea:3000)
#   MANIFEST_DIR dossier des manifestes (défaut poc-control-plane-federation/clients/provisioned/applications)
set -uo pipefail
set +x

PR_BRANCH="${PR_BRANCH:?PR_BRANCH requis}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
# Le secret de la forge porte un nom NEUTRE (2026-09-04) : un gestionnaire
# d'identite rend un jeton OU un couple, et les deux occupent la meme place.
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN — le secret de la forge (jeton, ou mot de passe d'un couple avec FORGE_USER)" >&2; exit 2; }
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_BASE="${GIT_BASE:-main}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
# shellcheck source=scripts/lib/repo-layout.sh
. "scripts/lib/repo-layout.sh" || { echo "ERREUR: scripts/lib/repo-layout.sh introuvable ou illisible" >&2; exit 1; }
repo_layout_init || exit 2
# RELATIF au livrable (2026-09-03) ; le préfixe du dépôt vit dans GIT_SUBDIR.
MANIFEST_DIR="${MANIFEST_DIR:-clients/provisioned/applications}"
MANIFEST_PATH="${SUB_PFX}${MANIFEST_DIR}"   # vu de la racine du clone : c'est ce que git connaît
INVENTORY="${INVENTORY:-ansible/inventory.lab.ini}"
# URL Git vue par l'HUMAIN (lien du commentaire) — distincte de GIT_HOST (in-cluster,
# pour les opérations git). Chez le client, les deux valent l'URL entreprise ; au lab,
# split-horizon (jenkins→gitea:3000, navigateur→localhost:13000).
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"

# Chemin du script résolu AVANT tout `cd` : ce script se déplace dans le clone de
# la PR ($WORK/repo) en [1/4], et un `dirname "$0"` relatif n'y résoudrait plus.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAN_FACTS="${PLAN_FACTS:-}"
GITEA_HEAD_REF=""; GITEA_HEAD_SHA=""

# facts <verdict> <raison> — écrit le fichier de faits (si demandé), à CHAQUE
# sortie. Résolu par rapport au cwd D'ORIGINE : le script fait un `cd` dans le
# clone plus bas, un chemin relatif serait alors faux — d'où la résolution ici.
ORIG_PWD="$PWD"
facts(){
  [ -n "$PLAN_FACTS" ] || return 0
  local f="$PLAN_FACTS"; case "$f" in /*) ;; *) f="$ORIG_PWD/$f";; esac
  printf 'PLAN_PR_NUMBER=%s\nGITEA_HEAD_REF=%s\nGITEA_HEAD_SHA=%s\nPLAN_VERDICT=%s\nPLAN_REASON=%s\n' \
    "$PR_NUMBER" "$GITEA_HEAD_REF" "$GITEA_HEAD_SHA" "$1" "$(printf '%s' "$2" | tr '\n\r' '  ')" > "$f"
}
refus(){ echo "REFUS: $1 : $2" >&2; facts refus "$1 : $2"; exit 1; }
# Faits INITIAUX (revue 2026-09-02) : une mort inattendue plus bas — pipe cassé,
# lib absente, kill — laisse un fichier HONNÊTE (refus SCRIPT_INTERROMPU, tête
# vide ⇒ le statut se tait), jamais le fichier d'un build précédent : le
# workspace Jenkins persiste et le post de stage relit ce qu'il trouve. Le
# Jenkinsfile retire aussi le fichier AVANT d'appeler ce script (double garde).
facts refus "SCRIPT_INTERROMPU : sortie inattendue avant les faits"

case "$PR_BRANCH" in provision/*) ;; *) echo "IGNORE: branche '$PR_BRANCH' hors provision/* — pas une demande" >&2; facts ignore "branche '$PR_BRANCH' hors provision/*"; exit 0;; esac
WORK="$(mktemp -d /tmp/provplan.XXXXXX)"; trap 'rm -rf "$WORK"' EXIT

# ── [0/4] LA FORGE, AVANT LE CLONE ────────────────────────────────────────────
# shellcheck source=scripts/lib/gitea-pr-confirm.sh
. "$SELF_DIR/lib/gitea-pr-confirm.sh" || { echo "ERREUR: $SELF_DIR/lib/gitea-pr-confirm.sh introuvable" >&2; facts refus "LIB_ABSENTE"; exit 1; }
echo "[0/4] relecture de la PR #${PR_NUMBER} sur la forge (tete attendue ${PR_BRANCH}, base ${GIT_BASE})"
if ! CONFIRM="$(gitea_pr_confirm "$PR_NUMBER" "$PR_BRANCH" "$GIT_BASE" 2>"$WORK/confirm.err")"; then
  refus FORGE_NON_CONFIRMEE "$(cat "$WORK/confirm.err") — aucun commentaire, aucun clone"
fi
GITEA_HEAD_REF="$(printf '%s\n' "$CONFIRM" | sed -n 's/^GITEA_HEAD_REF=//p')"
GITEA_HEAD_SHA="$(printf '%s\n' "$CONFIRM" | sed -n 's/^GITEA_HEAD_SHA=//p')"
echo "  forge : PR #${PR_NUMBER} ouverte, tete ${GITEA_HEAD_REF} @ ${GITEA_HEAD_SHA}"

echo "[1/4] checkout ${PR_BRANCH} @ ${GITEA_HEAD_SHA} (la tete RELUE, pas le nom)"
# GIT_HOST porte son schéma (http, https, file pour les épreuves) — même
# composition que la lib de confirmation ; un hôte nu reçoit http:// (revue :
# `http://${GIT_HOST#http://}` rendait « http://https://… » chez un client TLS).
# `--detach <sha>` : le SHA est un COMMIT (validé ^[0-9a-f]{40}$ par la lib —
# jamais une option), pas un chemin : `checkout -- <sha>` le prendrait pour un
# pathspec (mesuré : « BRANCHE_INTROUVABLE » sur un clone pourtant complet).
case "$GIT_HOST" in http://*|https://*|file://*) CLONE_BASE="${GIT_HOST%/}";; *) CLONE_BASE="http://${GIT_HOST%/}";; esac
git clone -q "${CLONE_BASE}/${GIT_REPO}.git" "$WORK/repo" || refus CLONE_ECHEC "clone de ${GIT_REPO} en echec"
cd "$WORK/repo" || refus CLONE_ECHEC "clone incomplet"
git checkout -q --detach "$GITEA_HEAD_SHA" 2>/dev/null || refus BRANCHE_INTROUVABLE "la tete ${GITEA_HEAD_SHA} de ${PR_BRANCH} n'est pas dans le clone (branche deplacee depuis la relecture, ou PR depuis un fork)"

echo "[2/4] localisation du manifeste (diff vs ${GIT_BASE})"
MAN=$(git diff --name-only "origin/${GIT_BASE}...HEAD" -- "${MANIFEST_PATH}/*.ansible.yml" 2>/dev/null | head -1)
[ -n "$MAN" ] || MAN=$(git diff --name-only "origin/${GIT_BASE}...HEAD" 2>/dev/null | grep -E "^${MANIFEST_PATH}/.*\.ansible\.yml$" | head -1)
if [ -z "$MAN" ]; then echo "IGNORE: aucun manifeste ajouté sous ${MANIFEST_PATH}" >&2; facts ignore "aucun manifeste ajoute sous ${MANIFEST_PATH}"; exit 0; fi
echo "  manifeste : $MAN"
# env = suffixe de la branche provision/<app>-<env>
# G4 (D6) : même geste que provision-request.sh — la liste suit LA chaîne,
# jamais une liste en dur. On est déjà DANS le clone ($WORK/repo, cd plus haut) :
# `scripts/lib/env-chain.sh` relatif au cwd viserait le mauvais dépôt (celui-ci
# n'a que ci/stoa-labs à la racine) — d'où $SELF_DIR, résolu par rapport à CE
# script AVANT le cd (même piège que documenté au-dessus pour SELF_DIR lui-même).
# shellcheck source=scripts/lib/env-chain.sh
. "$SELF_DIR/lib/env-chain.sh" || refus LIB_ABSENTE "$SELF_DIR/lib/env-chain.sh introuvable ou illisible"
CHAIN_NONPROD="$(env_chain_nonprod)" || refus CHAINE_ILLISIBLE "env_chain_nonprod en echec"
ENVV="${PR_BRANCH##*-}"; case " $CHAIN_NONPROD " in *" $ENVV "*) ;; *) ENVV="";; esac

echo "[3/4] PLAN (lecture seule) sur $MAN"
PLAN_LOG="$WORK/plan.log"; VERDICT="ok"
# SOUS-SHELL `( … )`, pas un groupe `{ … }` (revue 2026-09-02, bloquant) : dans
# un groupe, `exit 1` tue le SCRIPT — un manifeste supprimé par la PR (listé par
# le diff, absent de l'arbre) ou sans name/api sortait rc 1 SANS verdict ni
# faits. En sous-shell, `exit 1` rend VERDICT=fail : le ❌ est posé, les faits
# aussi. Le `cd` intérieur reste local au sous-shell.
(
  echo "== manifeste présent + champs requis =="
  test -f "$MAN" || { echo "manifeste introuvable"; exit 1; }
  grep -qE '^[[:space:]]*name:' "$MAN" && grep -qE '^[[:space:]]*api:' "$MAN" \
    || { echo "manifeste incomplet (name/api requis)"; exit 1; }
  grep -qE '^[[:space:]]*mode:' "$MAN" && echo "  mode: $(grep -oE 'mode: *"[a-z]+"' "$MAN" | head -1)"
  echo "== ansible --syntax-check (aucune mutation) =="
  cd poc-control-plane-federation
  ansible-playbook -i "$INVENTORY" ansible/selfservice-app.yml --syntax-check \
    -e "apim_ss_manifest=$(cd "$WORK/repo" && pwd)/$MAN" ${ENVV:+-e apim_ss_env="$ENVV"}
) >"$PLAN_LOG" 2>&1 || VERDICT="fail"
sed -n '1,40p' "$PLAN_LOG"

echo "[4/4] commentaire sur la PR #${PR_NUMBER} (verdict ${VERDICT})"
# L'UPSERT par marqueur vit dans scripts/lib/gitea-pr-comment.sh — partagé avec
# le commentaire d'apply (ADR-081). Ici on ne construit que le CORPS ; le
# marqueur, la recherche du commentaire existant et le choix POST/PATCH sont à
# la lib. Sans ce partage, le même upsert existerait en deux copies.
VERDICT="$VERDICT" MAN="$MAN" PLAN_LOG="$PLAN_LOG" GIT_REPO="$GIT_REPO" HEAD_SHA="$GITEA_HEAD_SHA" \
GIT_WEB_HOST="$GIT_WEB_HOST" PR_BRANCH="$PR_BRANCH" BODY_OUT="$WORK/comment.md" python3 - <<'PY'
import os
verdict = os.environ["VERDICT"]
head = "✅ **Plan self-service OK**" if verdict == "ok" else "❌ **Plan self-service EN ÉCHEC**"
log  = open(os.environ["PLAN_LOG"]).read()[-1500:]
man  = os.environ["MAN"]; sha = os.environ["HEAD_SHA"]
# Le verdict est LIÉ à un contenu (revue 2026-09-02) : le lien vise le COMMIT
# jugé, pas la tête mouvante de la branche — un push ultérieur dont le plan
# meurt avant le verdict ne fait pas passer l'ancien ✅ pour le sien.
man_url = f"{os.environ['GIT_WEB_HOST']}/{os.environ['GIT_REPO']}/src/commit/{sha}/{man}"
body = (f"{head} — automatique.\n\n"
        f"- manifeste : [`{man}`]({man_url})\n"
        f"- tete relue sur la forge : `{sha}` (branche `{os.environ['PR_BRANCH']}`)\n"
        f"- nature : lecture seule (aucune mutation, aucun secret) — ADR-078 §2\n\n"
        "<details><summary>sortie du plan</summary>\n\n```\n" + log + "\n```\n</details>\n\n"
        + ("Prêt pour validation humaine (4-yeux) puis apply nominatif au merge."
           if verdict == "ok" else "**Corriger la demande avant validation.**"))
open(os.environ["BODY_OUT"], "w").write(body)
PY
GIT_REPO="$GIT_REPO" FORGE_SECRET="$FORGE_SECRET" PR_NUMBER="$PR_NUMBER" GIT_HOST="$GIT_HOST" \
COMMENT_MARKER='<!-- provision-plan -->' COMMENT_BODY_FILE="$WORK/comment.md" \
  bash "$SELF_DIR/lib/gitea-pr-comment.sh" || refus COMMENTAIRE_ECHEC "plan ${VERDICT} sur ${MAN} mais le commentaire de verdict n'a pas pu etre pose"


if [ "$VERDICT" = "ok" ]; then
  facts ok "plan vert sur ${MAN}"; echo "OK: plan vert, PR #${PR_NUMBER} commentée"
else
  facts fail "plan en echec sur ${MAN} (voir le commentaire provision-plan)"; echo "PLAN EN ÉCHEC (PR commentée)"; exit 1
fi
