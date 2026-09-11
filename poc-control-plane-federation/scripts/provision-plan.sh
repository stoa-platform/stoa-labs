#!/usr/bin/env bash
# provision-plan.sh — FERMETURE DE BOUCLE : une PR de provisioning ouverte
# déclenche le PLAN self-service sur la branche, et le RÉSULTAT est posté en
# commentaire sur la PR (visible avant la validation humaine).
#
#   PR ouverte (maillon 1) → webhook Gitea → job Jenkins → CE script :
#     1. checkout la branche de la PR
#     2. localise le manifeste ajouté (git diff vs la branche de base)
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
#   GIT_BASE    branche cible — AUCUN défaut : vide, absente ou « auto » =
#               DÉCOUVERTE de la HEAD du dépôt (scripts/lib/git-base.sh) ; base du diff
#   GIT_HOST    base de la forge vue de l'agent, avec son schéma (REQUIS, aucun
#               repli : le défaut http://gitea:3000 d'avant 2026-09-11 remplaçait
#               en silence une variable non transmise chez un client, et la
#               panne sortait plus loin sous un autre nom — ci/lint-config-knobs.sh)
#   MANIFEST_DIR dossier des manifestes (défaut poc-control-plane-federation/clients/provisioned/applications)
#   STOA_DEBUG  mode debug SANS FUITE (ci/lib/dbg.sh, L2 2026-09-11) : ce que ce
#               script DÉCIDE (disposition, base, tête relue, rc de chaque geste
#               git, verdict) sur STDERR seulement, rédigé — jamais un token,
#               jamais stdout (le journal [n/4] ne bouge pas), jamais les faits.
#               Preuve : scripts/test-a0-wiring.sh §9 (c ter).
set -uo pipefail
set +x

PR_BRANCH="${PR_BRANCH:?PR_BRANCH requis}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
# Le secret de la forge porte un nom NEUTRE (2026-09-04) : un gestionnaire
# d'identite rend un jeton OU un couple, et les deux occupent la meme place.
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN — le secret de la forge (jeton, ou mot de passe d'un couple avec FORGE_USER)" >&2; exit 2; }
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
# GIT_BASE : plus de défaut « main » (L3, 2026-09-10) — il est POSÉ plus bas par
# scripts/lib/git-base.sh, une fois l'URL du dépôt composée. Ce script compare la
# base RELUE de la PR à GIT_BASE (§0) et diffe contre `origin/${GIT_BASE}` (§2) :
# un « main » deviné faisait refuser FORGE_NON_CONFIRMEE toute PR d'un client
# dont la branche est `master`, en accusant la PR au lieu du câblage.
# GIT_HOST : plus de défaut de site (L2, 2026-09-11 — la même ligne que
# provision-request.sh et app-rollback-request.sh). Absent ou vide ⇒ mort nommée
# ici, AVANT tout appel : chez un client, « http://gitea:3000 » remplaçait la
# variable non transmise et la panne sortait sous BRANCHE_PAR_DEFAUT_INCONNUE.
GIT_HOST="${GIT_HOST:?GIT_HOST requis (base de la forge, ex. https://forge.client) — aucun repli}"
# L2 : le MODE DEBUG SANS FUITE. dbg/dbg_kv/redact de ci/lib/dbg.sh sont les
# seules voies de sortie du debug (stderr seulement, rédigé, `$?` préservé) —
# jamais `set -x` (le `set +x` en tête : un log Jenkins est archivé). Même base
# de résolution que les libs ci-dessous : le cwd d'appel, AVANT le cd de [1/4].
# dbg_init normalise et EXPORTE STOA_DEBUG pour que les enfants (forge-api.py,
# gitea-pr-comment.sh) parlent avec la même valeur. Pas de DBG_NAME : le préfixe
# est le nom de CE script, c'est lui qu'on veut lire dans un log Jenkins. Pas de
# DBG_SECRET_FILES : le plan ne tient que FORGE_SECRET, que dbg.sh relit dans
# l'environnement à chaque appel — aucun token humain ici.
# shellcheck source=ci/lib/dbg.sh
. "ci/lib/dbg.sh" || { echo "ERREUR: ci/lib/dbg.sh introuvable ou illisible" >&2; exit 1; }
dbg_init
# dbg_git_err <fichier> — le stderr d'un geste git, relayé en mode debug sur
# UNE ligne « git: … » : rédigé EN ENTIER, puis mis sur une ligne, puis tronqué
# à 400 octets — dans cet ordre et pas un autre. Couper AVANT de masquer
# laisserait un MORCEAU de secret que redact ne reconnaît plus (la classe de
# défaut fermée trois fois par la relecture de la phase A ; même ordre que
# dbg_git_err de provision-request.sh et _git_base_stderr_relaye de
# scripts/lib/git-base.sh). L'ORDRE a son épreuve : test-a0-wiring §9 (c ter).6b/6d
# et le mutant (c ter).7c — un secret de 6 octets À CHEVAL sur l'octet 400 ;
# coupé avant d'être masqué, il en laisse cinq en clair, et dbg qui rédige une
# seconde fois ne les reconnaît pas (le masque est un atome, remasquer est
# idempotent — mais un MORCEAU n'est pas un littéral connu). Hors debug : rien
# n'est lu, rien n'est lancé ; fichier vide ⇒ rien. Le `$?` reçu est rendu tel quel.
dbg_git_err(){
  local _rc=$? m
  if dbg_on && [ -s "${1:-}" ]; then
    m="$(redact < "$1" | tr '\n' ' ')"
    dbg "  git: $(head -c 400 <<<"$m")"
  fi
  return "$_rc"
}
# shellcheck source=scripts/lib/repo-layout.sh
. "scripts/lib/repo-layout.sh" || { echo "ERREUR: scripts/lib/repo-layout.sh introuvable ou illisible" >&2; exit 1; }
repo_layout_init || exit 2
dbg_kv SUB_PFX "$SUB_PFX"   # vide ⇒ « <vide> » : le livrable EST la racine — c'est le diagnostic d'un IGNORE chez un client dont la forge préfixe
# shellcheck source=scripts/lib/git-base.sh
. "scripts/lib/git-base.sh" || { echo "ERREUR: scripts/lib/git-base.sh introuvable ou illisible" >&2; exit 1; }
# RELATIF au livrable (2026-09-03) ; le préfixe du dépôt vit dans GIT_SUBDIR.
MANIFEST_DIR="${MANIFEST_DIR:-clients/provisioned/applications}"
MANIFEST_PATH="${SUB_PFX}${MANIFEST_DIR}"   # vu de la racine du clone : c'est ce que git connaît
dbg_kv MANIFEST_PATH "$MANIFEST_PATH"   # le chemin tel que ce script le COMPOSE : c'est l'écart avec l'arbre qu'on diagnostique
INVENTORY="${INVENTORY:-ansible/inventory.lab.ini}"
# URL Git vue par l'HUMAIN (lien du commentaire) — distincte de GIT_HOST (in-cluster,
# pour les opérations git). Chez le client, les deux valent l'URL entreprise ; au lab,
# split-horizon (jenkins→gitea:3000, navigateur→localhost:13000).
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"

# Chemin du script résolu AVANT tout `cd` : ce script se déplace dans le clone de
# la PR ($WORK/repo) en [1/4], et un `dirname "$0"` relatif n'y résoudrait plus.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAN_FACTS="${PLAN_FACTS:-}"
dbg_kv PLAN_FACTS "$PLAN_FACTS"   # vide ⇒ « <vide> » : aucun fait écrit, le statut de build relira la forge
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
# GIT_HOST porte son schéma (http, https, file pour les épreuves) — même
# composition que la lib de confirmation ; un hôte nu reçoit http:// (revue :
# `http://${GIT_HOST#http://}` rendait « http://https://… » chez un client TLS).
# Composé ICI, avant [0/4] : la BASE se découvre sur cette URL, et la base est ce
# que la relecture de la PR compare (base.ref) — donc avant le premier appel.
case "$GIT_HOST" in http://*|https://*|file://*) CLONE_BASE="${GIT_HOST%/}";; *) CLONE_BASE="http://${GIT_HOST%/}";; esac
# L'URL composée : c'est elle qu'on diagnostique (le « http://https:// » du
# 2026-09-03 se serait lu ici). Un userinfo éventuel est masqué par redact.
dbg_kv CLONE_BASE "$CLONE_BASE"
# Le clone de ce script n'est PAS enveloppé (dépôt lu en anonyme) : le
# `git ls-remote` de la lib hérite du même environnement, donc de la même
# absence d'enveloppe — ce que l'un peut lire, l'autre le peut.
git_base_init "${CLONE_BASE}/${GIT_REPO}.git" \
  || { facts refus "BRANCHE_PAR_DEFAUT_INCONNUE : branche par defaut de ${GIT_REPO} indeterminable (cause dans le log du build)"; exit 1; }
echo "[0/4] relecture de la PR #${PR_NUMBER} sur la forge (tete attendue ${PR_BRANCH}, base ${GIT_BASE})"
# Le stderr de la confirmation est CAPTURÉ parce que le refus le RECOPIE (la
# cause de forge-api puis la ligne FORGE_NON_CONFIRMEE) et que PLAN_REASON en
# hérite. Sous STOA_DEBUG il porte AUSSI les lignes de debug — celles de
# forge_api_init, de forge-api.py (« GET …/pulls/n -> HTTP code ») et la PR relue
# par la lib — toutes préfixées « [dbg » (le contrat de ci/lib/dbg.sh et de
# forge-api.py : un log archivé se grep en tête de ligne). Sur REFUS, elles sont
# relayées AVANT le refus, SÉPARÉES de la cause : recopiées dans le refus, elles
# entreraient dans PLAN_REASON, donc dans le commentaire de statut (mesuré :
# test-a0-wiring (c ter).2b rouge avant cette séparation). Sans debug, aucune
# ligne « [dbg » n'existe : `grep -v` rend le fichier tel quel, le refus est
# octet pour octet celui d'avant.
if ! CONFIRM="$(gitea_pr_confirm "$PR_NUMBER" "$PR_BRANCH" "$GIT_BASE" 2>"$WORK/confirm.err")"; then
  grep '^\[dbg ' "$WORK/confirm.err" >&2
  refus FORGE_NON_CONFIRMEE "$(grep -v '^\[dbg ' "$WORK/confirm.err") — aucun commentaire, aucun clone"
fi
# Sur SUCCÈS, confirm.err ne porte que les lignes de debug : sans relais elles
# seraient PERDUES — la capture n'existe que pour le refus. Sans debug le
# fichier est vide et rien ne s'écrit ((c ter).1j ; mutant (c ter).7a).
[ -s "$WORK/confirm.err" ] && cat "$WORK/confirm.err" >&2
GITEA_HEAD_REF="$(printf '%s\n' "$CONFIRM" | sed -n 's/^GITEA_HEAD_REF=//p')"
GITEA_HEAD_SHA="$(printf '%s\n' "$CONFIRM" | sed -n 's/^GITEA_HEAD_SHA=//p')"
# La tête RELUE — celle que le clone va checkouter, jamais le nom du payload.
dbg_kv GITEA_HEAD_REF "$GITEA_HEAD_REF"
dbg_kv GITEA_HEAD_SHA "$GITEA_HEAD_SHA"
echo "  forge : PR #${PR_NUMBER} ouverte, tete ${GITEA_HEAD_REF} @ ${GITEA_HEAD_SHA}"

echo "[1/4] checkout ${PR_BRANCH} @ ${GITEA_HEAD_SHA} (la tete RELUE, pas le nom)"
# `--detach <sha>` : le SHA est un COMMIT (validé ^[0-9a-f]{40}$ par la lib —
# jamais une option), pas un chemin : `checkout -- <sha>` le prendrait pour un
# pathspec (mesuré : « BRANCHE_INTROUVABLE » sur un clone pourtant complet).
# Le VRAI rc de git est capturé (L2) : la ligne de debug le dit, puis la même
# décision qu'avant — un rc non nul est CLONE_ECHEC. Le stderr du clone allait
# BRUT dans le journal ; il y va toujours, mais RÉDIGÉ (redact : littéraux du
# process + forme ://…@) : sous GIT_TRACE=1 git y recopie l'URL NUE (mesure de
# scripts/lib/git-base.sh, _git_base_stderr_relaye), et un GIT_HOST à
# user:secret@ serait sorti en clair dans le log archivé — test-a0-wiring
# (c ter).6c/6d (un shim qui recopie le secret) rougissaient avant ce relais.
# Même forme sinon, octet pour octet (redact ne change rien à une ligne sans
# secret). python3 est acquis ici : forge_api_init l'a exigé (PYTHON3_REQUIS)
# avant la relecture de la PR, qui précède ce clone.
git clone -q "${CLONE_BASE}/${GIT_REPO}.git" "$WORK/repo" 2>"$WORK/clone.err"; rc=$?
dbg "git clone ${CLONE_BASE}/${GIT_REPO}.git -> rc $rc"
dbg_git_err "$WORK/clone.err"
[ ! -s "$WORK/clone.err" ] || redact < "$WORK/clone.err" >&2
[ "$rc" -eq 0 ] || refus CLONE_ECHEC "clone de ${GIT_REPO} en echec"
cd "$WORK/repo" || refus CLONE_ECHEC "clone incomplet"
# Le stderr du checkout allait à /dev/null : en mode debug il est le diagnostic
# (« reference is not a tree » = tête déplacée) — capturé, rc dit ; hors debug,
# rien n'est lu, rien ne change.
git checkout -q --detach "$GITEA_HEAD_SHA" 2>"$WORK/checkout.err"; rc=$?
dbg "git checkout --detach ${GITEA_HEAD_SHA} -> rc $rc"
dbg_git_err "$WORK/checkout.err"
[ "$rc" -eq 0 ] || refus BRANCHE_INTROUVABLE "la tete ${GITEA_HEAD_SHA} de ${PR_BRANCH} n'est pas dans le clone (branche deplacee depuis la relecture, ou PR depuis un fork)"

echo "[2/4] localisation du manifeste (diff vs ${GIT_BASE})"
# Le diff dit ce qu'il a RENDU (pas un rc : sous `| head -1` et pipefail, un
# SIGPIPE en ferait un 141 sans valeur) ; son stderr allait à /dev/null, il est
# capturé (« bad revision origin/<base> » = base non ramenée par le clone).
MAN=$(git diff --name-only "origin/${GIT_BASE}...HEAD" -- "${MANIFEST_PATH}/*.ansible.yml" 2>"$WORK/diff.err" | head -1)
dbg "git diff --name-only origin/${GIT_BASE}...HEAD -- ${MANIFEST_PATH}/*.ansible.yml -> ${MAN:-<vide>}"
dbg_git_err "$WORK/diff.err"
if [ -z "$MAN" ]; then
  MAN=$(git diff --name-only "origin/${GIT_BASE}...HEAD" 2>"$WORK/diff.err" | grep -E "^${MANIFEST_PATH}/.*\.ansible\.yml$" | head -1)
  dbg "git diff --name-only origin/${GIT_BASE}...HEAD | grep ^${MANIFEST_PATH}/ -> ${MAN:-<vide>}"
  dbg_git_err "$WORK/diff.err"
fi
dbg_kv MAN "$MAN"   # vide ⇒ « <vide> » : c'est l'IGNORE qui suit — et, avec SUB_PFX, son diagnostic
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
# Le découpage vient de la lib, plus d'une expression locale : sept sites en
# avaient quatre comportements (D8, 2026-09-06). Contrat tenu par la table de
# labctl/internal/governance/branchref_mirror_test.go.
# shellcheck source=scripts/lib/branch-ref.sh
. "$SELF_DIR/lib/branch-ref.sh" || refus LIB_ABSENTE "$SELF_DIR/lib/branch-ref.sh introuvable ou illisible"
BR_RC=0; BR_OUT="$(branch_split "$PR_BRANCH" "provision/")" || BR_RC=$?
case "$BR_RC" in
  0) ;;
  1) refus BRANCHE_HORS_PERIMETRE "'$PR_BRANCH' ne commence pas par provision/ — ce n'est pas une demande d'application" ;;
  *) refus BRANCH_FORMAT_INVALIDE "'$PR_BRANCH' hors provision/<app>-<palier> (app ^[a-z0-9][a-z0-9-]*\$, palier ^[a-z0-9]+\$)" ;;
esac
ENVV="${BR_OUT##* }"
dbg_kv ENVV "$ENVV"   # le palier que la branche nomme : c'est lui que PALIER_HORS_CHAINE juge
# ⚠ CE REFUS REMPLACE UN BLANCHIMENT SILENCIEUX (D8). Avant : un palier hors
# chaîne hors-prod vidait ENVV, et `${ENVV:+-e apim_ss_env=…}` faisait
# DISPARAÎTRE l'extra-var — le plan présenté au demandeur portait alors sur le
# palier par défaut du rôle, pas sur celui que sa branche nomme. Un plan qui
# répond à une autre question que celle posée est pire que pas de plan.
case " $CHAIN_NONPROD " in
  *" $ENVV "*) ;;
  *) refus PALIER_HORS_CHAINE "le palier '$ENVV' (branche '$PR_BRANCH') n'est pas un palier hors-prod de la chaîne ($CHAIN_NONPROD) — le terminus se sert par sa propre voie (A7), et un palier inconnu ne se planifie pas en silence" ;;
esac

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
  # Le préfixe du livrable DANS LE CLONE, pris au knob comme MANIFEST_PATH plus
  # haut — il s'écrivait ici en dur (résidu de la généralisation du 2026-09-03,
  # même famille que le défaut client du 2026-09-08). SUB_PFX est vide quand le
  # livrable EST la racine : `${SUB_PFX:-.}` rend alors un `cd .` inoffensif.
  cd "${SUB_PFX:-.}"
  ansible-playbook -i "$INVENTORY" ansible/selfservice-app.yml --syntax-check \
    -e "apim_ss_manifest=$(cd "$WORK/repo" && pwd)/$MAN" ${ENVV:+-e apim_ss_env="$ENVV"}
) >"$PLAN_LOG" 2>&1 || VERDICT="fail"
dbg_kv VERDICT "$VERDICT"   # ce que le commentaire va porter, et le rc final (fail ⇒ 1)
sed -n '1,40p' "$PLAN_LOG"

echo "[4/4] commentaire sur la PR #${PR_NUMBER} (verdict ${VERDICT})"
# L'UPSERT par marqueur vit dans scripts/lib/gitea-pr-comment.sh — partagé avec
# le commentaire d'apply (ADR-081). Ici on ne construit que le CORPS ; le
# marqueur, la recherche du commentaire existant et le choix POST/PATCH sont à
# la lib. Sans ce partage, le même upsert existerait en deux copies. Son stderr
# est LIBRE (rien à relayer) : sous STOA_DEBUG — exporté par dbg_init, hérité —
# elle parle sous son propre nom (« [dbg gitea-pr-comment.sh] »).
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
