#!/usr/bin/env bash
# team-apply.sh — l'APPLY d'onboarding, APRÈS la décision humaine (le merge).
#
#   merge PR onboard/* → webhook → job team-apply (pause nominative + garde
#   d'identité, cf. le job XML) → CE script :
#     1. ANTI-TOCTOU : checkout de la branche de base AU SHA DU MERGE ; l'équipe est lue dans
#        providers.<env>.yml TEL QUE MERGÉ — jamais dans le payload du webhook.
#     2. dépôt d'équipe LU, jamais créé (D10, ADR-099) : repo_get par l'autorité
#        de forge ; absent -> REFUS DEPOT_ABSENT ; vide -> squelette ADR-076
#        poussé ; déjà initialisé -> sauté (idempotence, dit dans le commentaire).
#        repo: "" dans providers → étape sautée (cas payments-team), PAS un échec.
#     3. ansible/onboard-team.yml (rôle idempotent du palier 1).
#     4. commentaire PR : le statut RÉEL, succès comme échec (ADR-081 coroll. 2).
#
# Invocation attendue (miroir de team-request.sh, Task 5/ci/jenkins/team-apply.job.xml) :
#   dir(env.GIT_SUBDIR) { sh 'bash scripts/team-apply.sh' } — donc
# $0 = "scripts/team-apply.sh" et le `cd "$(dirname "$0")/.."` ci-dessous NE
# BOUGE PAS le cwd (déjà poc-control-plane-federation/, "scripts/.." s'annule).
# Toutes les références de fichier plus bas (PROV, clients/_example, ansible/…)
# sont donc relatives à CE cwd, SANS le préfixe "poc-control-plane-federation/"
# (celui-ci n'a de sens que dans un CLONE FRAIS du dépôt plateforme entier —
# motif utilisé par team-request.sh pour son propre WORK/repo, différent).
set -uo pipefail
# shellcheck source=scripts/lib/forge-identity.sh
. scripts/lib/forge-identity.sh || { echo "ERREUR: scripts/lib/forge-identity.sh introuvable ou illisible" >&2; exit 1; }
# shellcheck source=scripts/lib/branch-ref.sh
. scripts/lib/branch-ref.sh || { echo "ERREUR: scripts/lib/branch-ref.sh introuvable ou illisible" >&2; exit 1; }
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1

# Auto-localisation par BASH_SOURCE quand le fichier vit dans son arbre ; repli
# sur le cwd — qui est ICI la racine du PoC, le `cd` ci-dessus venant de
# s'exécuter (motif de setup-vault-paliers.sh:26-38 et api-request.sh:58-66).
# Sourcé AVANT le `git checkout "$MERGE_SHA"` plus bas : la constante ne doit
# pas dépendre de l'état de l'arbre au SHA mergé.
_TA_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/deploy-pin.sh"
[ -f "$_TA_LIB" ] || _TA_LIB="scripts/lib/deploy-pin.sh"
# `set -e` n'est pas actif ici : sans garde explicite, un fichier manquant
# laisserait bash continuer jusqu'à un « unbound variable » sur la constante.
# shellcheck source=scripts/lib/deploy-pin.sh
. "$_TA_LIB" || { echo "ERREUR: $_TA_LIB introuvable ou illisible" >&2; exit 1; }

_TA_PROV="$(dirname "${BASH_SOURCE[0]}")/lib/providers-teams.sh"
[ -f "$_TA_PROV" ] || _TA_PROV="scripts/lib/providers-teams.sh"
# shellcheck source=scripts/lib/providers-teams.sh
. "$_TA_PROV" || { echo "ERREUR: $_TA_PROV introuvable ou illisible" >&2; exit 1; }
# LA branche par défaut, une autorité (L3, 2026-09-10). Ce script ne clone pas
# le dépôt plateforme : il lit le WORKTREE que Jenkins a checkouté. La branche
# se découvre donc sur l'origine DE CE WORKTREE — le même dépôt, la même URL et
# le même environnement que le `git fetch` du §1, donc la même enveloppe
# d'authentification (celle que la définition SCM du job a posée).
_TA_BASE="$(dirname "${BASH_SOURCE[0]}")/lib/git-base.sh"
[ -f "$_TA_BASE" ] || _TA_BASE="scripts/lib/git-base.sh"
# shellcheck source=scripts/lib/git-base.sh
. "$_TA_BASE" || { echo "ERREUR: $_TA_BASE introuvable ou illisible" >&2; exit 1; }

PR_BRANCH="${PR_BRANCH:?PR_BRANCH requis}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
MERGE_SHA="${MERGE_SHA:?MERGE_SHA requis (merge_commit_sha du webhook)}"
# Le secret de la forge porte un nom NEUTRE (2026-09-04) : un gestionnaire
# d'identite rend un jeton OU un couple, et les deux occupent la meme place.
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN — le secret de la forge (jeton, ou mot de passe d'un couple avec FORGE_USER)" >&2; exit 2; }

# ── L'ENVELOPPE D'AUTHENTIFICATION DES GESTES GIT (2026-09-11) ───────────────
# Ces gestes étaient NUS : ils marchaient sur le Gitea du lab, qui sert
# `info/refs` en lecture ANONYME (200), et cassaient sur toute forge PRIVÉE —
# 401, puis un refus qui accuse autre chose (mesuré quatre fois d'affilée sur la
# chaîne app-request, cf. ENVIRONNEMENTS.md « La forge privée »). Le login vient
# de l'autorité unique `git_base_basic_login` (« x » convient à Gitea, JAMAIS à
# GitLab ni Bitbucket) ; le secret ne passe NI en argv NI dans l'URL.
# ⚠ La DÉCOUVERTE compte autant que le clone : `git_base_init` fait un
# `ls-remote`, et un ls-remote nu meurt « could not read Username » sur un dépôt
# privé — le refus accuse alors la branche, pas l'authentification.
gclone(){ git_base_avec_basic "$(git_base_basic_login)" FORGE_SECRET git clone -q "$@"; }
gbase(){ git_base_avec_basic "$(git_base_basic_login)" FORGE_SECRET "$@"; }
ggit(){ git_base_avec_basic "$(git_base_basic_login)" FORGE_SECRET git "$@"; }
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR requis}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE requis (jamais le token en env/argv)}"
APIM_API_BASE="${APIM_API_BASE:?APIM_API_BASE requis — pas de défaut : dire sa cible est volontaire}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"

# L5 phase 2 (2026-09-12) — LA FORGE SE PARLE PAR UNE SEULE AUTORITÉ (D10) :
# visage, base d'API, en-tête d'auth et garde de réponse vivent dans
# scripts/lib/forge-api.sh (+ .py) — ce script ne compose plus /api/v1 ni
# « Authorization: token » lui-même (mêmes verbes que team-request.sh,
# d879968). Sourcé APRÈS GIT_HOST/GIT_REPO/GIT_WEB_HOST : forge_api_init ne
# fait aucun appel réseau, mais REFUSE si l'un des deux est vide.
_TA_FORGE="$(dirname "${BASH_SOURCE[0]}")/lib/forge-api.sh"
[ -f "$_TA_FORGE" ] || _TA_FORGE="scripts/lib/forge-api.sh"
# shellcheck source=scripts/lib/forge-api.sh
. "$_TA_FORGE" || { echo "ERREUR: $_TA_FORGE introuvable ou illisible" >&2; exit 1; }
forge_api_init || exit 2

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
# Un commentaire par RÔLE, sous marqueur : le statut de team-apply se REMPLACE à
# chaque passage (idempotence, ADR-081 corollaire 1). fail() écrit UN SEUL ❌ (le
# double commentaire d'antan — détaillé puis générique — est fermé, comme dans
# team-publish.sh). L'échec du commentaire est un avertissement : le verdict de
# l'apply ne dépend jamais de son rapport.
comment(){
  printf '%s\n' "$1" > "$TMP/comment.md"
  forge comment_upsert "$PR_NUMBER" '<!-- team-apply -->' "$TMP/comment.md" >/dev/null \
    || echo "AVERTISSEMENT: statut non posé sur la PR #${PR_NUMBER} (cause ci-dessus) — l'apply, lui, a rendu son verdict dans ce build" >&2
}
fail(){ comment "❌ team-apply ${TEAM:-?}/${ENVN:-?} — $*"; echo "ERREUR: $*" >&2; exit 1; }
refus(){ comment "❌ team-apply ${TEAM:-?}/${ENVN:-?} — REFUS: $*"; echo "REFUS: $*" >&2; exit 2; }

# ── 1. équipe et env depuis la branche ; anti-TOCTOU sur le contenu ──────────
case "$PR_BRANCH" in onboard/*) ;; *) echo "hors onboard/* — rien à faire"; exit 0;; esac
# Même découpage que les six autres sites, une seule implémentation (D8) — et
# ce site-ci n'avait AUCUNE classe : une branche malformée y passait entière.
BR_RC=0; BR_OUT="$(branch_split "$PR_BRANCH" "onboard/")" || BR_RC=$?
[ "$BR_RC" = 0 ] || fail "BRANCH_FORMAT_INVALIDE : '$PR_BRANCH' hors onboard/<equipe>-<palier> (equipe ^[a-z0-9][a-z0-9-]*$, palier ^[a-z0-9]+$)"
TEAM="${BR_OUT% *}"; ENVN="${BR_OUT##* }"
# G4 (ADR-082, D5) : la branche onboard/<team>-<env> porte l'env par
# CONSTRUCTION (team-request le scelle sur la même constante) — un suffixe
# étranger n'est donc pas un palier fermé qu'on refuserait d'ouvrir, c'est une
# branche FORGÉE : le refus change de NOM parce qu'il change de nature.
# Comparaison contre la constante et non contre le littéral `dev` : les deux ont
# la même valeur aujourd'hui, mais seule la première suit la source si l'env
# d'authoring bouge — un littéral serait un second point de vérité muet.
[ "$ENVN" = "$DEPLOY_PIN_AUTHORING_ENV" ] || fail "ENV_MISMATCH : ${ENVN} ≠ ${DEPLOY_PIN_AUTHORING_ENV} — l'onboarding est un geste d'authoring ; la tenancy aux paliers supérieurs vient du chemin de promotion (ADR-082)"

# La branche de base AVANT le premier geste git : le fetch la nomme, et c'est
# elle que le squelette du dépôt d'équipe suivra (§2). Knob GIT_BASE > HEAD de
# l'origine du worktree > refus nommé (rc 2, déjà dit par la lib).
# Écrit en `if`, pas en `${…:-…}` : ce n'est pas un DÉFAUT de configuration mais
# une LECTURE de l'arbre en place — et ci/lint-config-knobs.sh a raison de
# refuser un `:-` dont la valeur ressemble à un chemin.
if [ -z "${GIT_CLONE_URL:-}" ]; then
  GIT_CLONE_URL="$(git remote get-url origin 2>/dev/null || true)"
fi
gbase git_base_init "$GIT_CLONE_URL" \
  || fail "BRANCHE_PAR_DEFAUT_INCONNUE : branche par défaut du dépôt plateforme indéterminable (cause ci-dessus) — rien n'est appliqué"
ggit fetch -q origin "$GIT_BASE" && git checkout -q "$MERGE_SHA" \
  || fail "checkout du SHA de merge $MERGE_SHA"
PROV="ansible/providers.${ENVN}.yml"
# Lu en YAML (voir provision-request.sh). L'ERE interpolait $TEAM ici aussi.
providers_team_declared "$PROV" "$TEAM"
case $? in
  0) ;;
  1) fail "TEAM_NOT_IN_MERGED_STATE : ${TEAM} absente de ${PROV} au SHA mergé — le payload ne fait pas foi (équipes déclarées au SHA mergé : $(providers_teams_inline "$PROV"))" ;;
  *) fail "PROVIDERS_PARSE : ${PROV} ne se lit pas en YAML au SHA mergé (cause ci-dessus) — refus" ;;
esac
# REVUE (Important) : la 1ère version n'avait aucun `|| fail` sur cette
# extraction — une exception Python (YAML malformé, équipe absente malgré le
# grep texte du dessus) laissait REPO_FULL vide EN SILENCE, et le script
# prenait alors le chemin « repo vide dans providers » comme si c'était le
# cas légitime payments-team : un commentaire ✅ trompeur possible. Même
# classe de bug que le Critical de la Task 3 (extraction entre appels gardés
# = le point aveugle). Deux verrous : (1) `|| fail` sur l'échec du process
# python lui-même (exception -> exit non nul, capté par `||`) ; (2) un
# marqueur explicite `REPO=` en préfixe de sortie — un python qui réussirait
# SANS lever mais sans imprimer ce préfixe (sortie inattendue) est aussi
# refusé, pour ne jamais confondre « champ repo légitimement absent/vide »
# (le marqueur est présent, la valeur après lui est vide) et « extraction
# cassée » (marqueur absent).
REPO_FULL=$(TEAM="$TEAM" PROV="$PROV" python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["PROV"]))
e = next((p for p in d["providers"] if p["team"] == os.environ["TEAM"]), None)
if e is None:
    sys.exit("TEAM_NOT_FOUND_IN_PARSE : incohérence grep vs yaml.safe_load")
print("REPO=" + (e.get("repo") or ""))
PY
) || fail "PARSE_PROVIDERS : lecture du champ repo de ${TEAM} dans ${PROV} — $REPO_FULL"
case "$REPO_FULL" in
  REPO=*) REPO_FULL="${REPO_FULL#REPO=}";;
  *) fail "PARSE_PROVIDERS : sortie inattendue de l'extraction repo pour ${TEAM} (ni échec ni marqueur REPO=)";;
esac

# ── 2. le dépôt d'équipe : LU, jamais créé (D10 profond, ADR-099) ────────────
# Le client crée le dépôt VIDE, son ou ses webhooks vers les récepteurs et la protection de
# sa branche par défaut (prérequis de forge, ENVIRONNEMENTS.md § Prérequis côté
# client). Ici : repo_get par l'autorité de forge, sous le secret de forge
# ORDINAIRE (le jeton org-admin lu dans Vault n'existe plus), puis trois états :
#   absent            -> REFUS DEPOT_ABSENT (nommé sur la PR, rien de poussé) ;
#   existant ET vide   -> squelette ADR-076 poussé sur la HEAD que la forge annonce,
#                        sinon la branche de base de la plateforme ;
#   existant NON vide  -> déjà initialisé, étape sautée (idempotence : un re-run
#                        après un échec d'onboarding ne doit jamais refuser ici).
# Le parse est fail-closed dans l'autorité : un 200 sans champ « vide » lisible
# est un refus, jamais « non vide » par défaut.
#
# ÉCART AU BRIEF (bug corrigé, constaté en relisant ansible/providers.dev.yml) :
# le brief de cette tâche appelait repo_get INCONDITIONNELLEMENT. payments-team
# porte délibérément `repo: ""` (providers.dev.yml:36 — tenant réel, « inconnu,
# à renseigner au palier 2 ») : un repo_get sur un GIT_REPO vide n'a aucun sens,
# et refuser ce cas en DEPOT_ABSENT casserait l'onboarding d'une équipe qui n'a
# simplement pas encore de dépôt produit — c'est déjà l'invariant nommé dans
# l'en-tête de ce fichier (« repo: "" → étape sautée, PAS un échec »). La garde
# `[ -n "$REPO_FULL" ]` du code d'avant D10 est donc CONSERVÉE autour du bloc.
REPO_NOTE="dépôt : (repo vide dans providers — étape sautée)"
REPO_LINK=""
if [ -n "$REPO_FULL" ]; then
  GIT_REPO="$REPO_FULL" forge_kv DEPOT repo_get \
    || fail "lecture du dépôt d'équipe ${REPO_FULL} sur la forge (cause ci-dessus)"
  PUSH_SKELETON=0
  if [ "$DEPOT_EXISTS" != 1 ]; then
    refus "DEPOT_ABSENT : le dépôt ${REPO_FULL} n'existe pas sur ${GIT_HOST} (ou n'est pas visible pour ce jeton) — le client le crée VIDE, avec son ou ses webhooks vers les récepteurs (un seul sous gwt, deux sous gitlab : un par job) et la protection de sa branche par défaut (prérequis D10, ENVIRONNEMENTS.md § Prérequis côté client), puis rejoue ce merge. Rien n'a été poussé."
  elif [ "$DEPOT_EMPTY" = 1 ]; then
    PUSH_SKELETON=1
    SKEL_BRANCH="${DEPOT_DEFAULT_BRANCH:-$GIT_BASE}"
    REPO_NOTE="dépôt ${REPO_FULL} : vide, squelette ADR-076 poussé sur ${SKEL_BRANCH}"
  else
    REPO_NOTE="dépôt ${REPO_FULL} : déjà initialisé, étape sautée (idempotence)"
  fi
  if [ "$PUSH_SKELETON" = 1 ]; then
    SK="$TMP/skel"; mkdir -p "$SK"
    cp -R clients/_example/. "$SK/"
    printf '# %s\n\nDépôt d équipe (squelette ADR-076 : apis/, applications/).\nInitialisé par team-apply au merge de la PR #%s.\n' "$REPO_FULL" "$PR_NUMBER" > "$SK/README.md"
    git -C "$SK" init -q -b "$SKEL_BRANCH" && git -C "$SK" add -A \
      && git -C "$SK" -c user.name=ci -c user.email=ci@stoa.lab commit -qm "squelette ADR-076 (team-apply, PR #${PR_NUMBER})"
    # Le push passe par l'enveloppe de l'autorité git (login du visage, secret de
    # forge ordinaire, jamais en argv) — c'est le porteur de FORGE_SECRET qui
    # initialise le dépôt ; sur GitLab il doit être Maintainer sur le projet
    # (la protection de branche y est par RÔLE : push/merge access_level 40).
    ggit -C "$SK" push -q "${GIT_HOST}/${REPO_FULL}.git" "$SKEL_BRANCH" 2>"$TMP/pe" \
      || { cat "$TMP/pe" >&2; fail "push du squelette dans ${REPO_FULL} (dépôt vide : le porteur du secret de forge doit pouvoir y écrire)"; }
  fi
  [ -n "${DEPOT_URL:-}" ] && REPO_LINK=" ([${REPO_FULL}]($(forge_web_url "$DEPOT_URL")))"
fi

# ── 3. onboarding (rôle du palier 1, idempotent) ─────────────────────────────
( ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
    -e stoa_debug="$(dbg_bool)" \
    -e "apim_onb_team=${TEAM}" -e "apim_onb_providers_file=providers.${ENVN}.yml" \
    -e "apim_ss_api_base=${APIM_API_BASE}" \
) >"$TMP/onb.log" 2>&1
ONB_RC=$?

# ── 4. le statut RÉEL sur la PR — succès comme échec ─────────────────────────
if [ "$ONB_RC" -eq 0 ]; then
  SUMMARY=$(grep -oE '(ONBOARD_OK|VERIFY_[A-Z_]+|TEAM_[A-Z_]+|TENANT_ROOT_UNSAFE|KV_[A-Z_]+)[^"]*' "$TMP/onb.log" | tail -3 | tr '\n' ' ')

  # ── re-pose ÉVÉNEMENTIELLE des listes (Task 3, palier 3) ───────────────────
  # L'équipe qu'on vient d'onboarder doit apparaître dans les listes
  # déroulantes (app-request, api-request quand il existera) SANS attendre un
  # relance manuelle de setup-team-onboard-jobs.sh. BEST-EFFORT BRUYANT : à ce
  # point l'onboarding est déjà FAIT (ONB_RC=0, rôle Ansible idempotent
  # convergé) — un échec de re-pose ne l'annule PAS et n'appelle jamais
  # `fail` ; il est seulement NOMMÉ dans le commentaire ✅, pour qu'un humain
  # sache qu'il doit relancer la pose à la main. api-request n'existe pas
  # encore (Task 5) : setup-team-onboard-jobs.sh tolère proprement son
  # absence (avertit, ignore), donc CE code est déjà prêt pour lui.
  #
  # DÉFAUT IN-CLUSTER (fix mesuré, Task 7) : ce script tourne comme process
  # ENFANT du job Jenkins — "localhost" y désigne le CONTENEUR du job, pas
  # l'hôte. `http://localhost:18080` rendait la re-pose systématiquement
  # injoignable (curl "000") une fois JOUÉ EN JOB — jamais vu en test depuis
  # un poste (où "localhost" désigne bien Jenkins publié), toujours vu en job
  # réel. `jenkins:8080` est l'alias réseau in-cluster déjà utilisé pour
  # webmethods-mock/gitea (même convention). Un poste hors du réseau compose
  # surcharge JENKINS_UI explicitement (comme APIM_API_BASE).
  REFRESH_NOTE=""
  # AUCUN ENVN passé au délégué, et c'est délibéré : depuis G4 il SCELLE
  # lui-même son env sur la même constante d'authoring
  # (setup-team-onboard-jobs.sh:87). Le lui repasser serait du câblage mort qui
  # suggère qu'il obéit à son appelant.
  # A0 (2026-09-02) : app-request n'a plus de marqueur — sa re-pose est une
  # copie tel quel suivie d'un build d'AMORÇAGE (BOOTSTRAP_JOBS, délégué) :
  # c'est ce build qui recalcule ses listes ; api-request garde la substitution.
  if JENKINS_UI="${JENKINS_UI:-http://jenkins:8080}" JOBS="app-request api-request" \
     bash scripts/setup-team-onboard-jobs.sh >"$TMP/refresh.log" 2>&1
  then
    # REVUE (round 1, Important) : la re-pose peut RÉUSSIR tout en ayant
    # toléré/sauté un dépôt d'équipe déclaré mais introuvable sur Gitea
    # (generate_choices_apis, réserve 3 du rapport) — ce cas émet
    # CHOICES_SKIPPED_REPOS=<n> sur stderr (marqueur explicite, motif du
    # palier 2), qui atterrit dans CE log (stdout+stderr confondus) même sur
    # le chemin de succès. Sans ce grep, la moitié "signal" de la tolérance
    # ne sortait jamais du process : une re-pose verte pouvait cacher en
    # silence une équipe manquante — la moitié de fail-open exacte que la
    # revue a nommée. `tail -1` : au plus un marqueur par run (generate_
    # choices_apis n'est appelée qu'une fois par invocation de
    # setup-team-onboard-jobs.sh).
    SKIPPED=$(grep -oE 'CHOICES_SKIPPED_REPOS=[0-9]+' "$TMP/refresh.log" | tail -1 | cut -d= -f2)
    if [ -n "$SKIPPED" ] && [ "$SKIPPED" -gt 0 ]; then
      REFRESH_NOTE=" (listes rafraîchies ; ⚠ ${SKIPPED} dépôt(s) d'équipe déclarés mais absents, sautés)"
      echo "AVERTISSEMENT: listes rafraîchies mais ${SKIPPED} dépôt(s) d'équipe déclarés absents/sautés :" >&2
      tail -20 "$TMP/refresh.log" >&2
    else
      echo "listes rafraîchies (app-request, api-request si présent)"
    fi
  else
    REFRESH_NOTE=" ⚠ listes non rafraîchies — relancer setup-team-onboard-jobs.sh"
    echo "AVERTISSEMENT: re-pose des listes en échec — l'onboarding, lui, EST fait :" >&2
    tail -20 "$TMP/refresh.log" >&2
  fi

  comment "✅ team-apply ${TEAM}/${ENVN} — ${REPO_NOTE}${REPO_LINK} ; onboarding : ${SUMMARY:-ONBOARD_OK}${REFRESH_NOTE}"
else
  # ÉCART AU BRIEF (bug corrigé, constaté en direct) : le grep(tags) du brief
  # cherche UNIQUEMENT les marqueurs propres à apim_team_onboard (TEAM_*/KV_*/
  # VERIFY_*/…) — absents quand l'échec vient d'AILLEURS dans la chaîne (ex.
  # apim_common, résolution des creds admin gateway, cf. réserve Vault dans le
  # rapport). Résultat reproduit : le résumé affichait "TEAM_NAME_OK" — le
  # DERNIER tag de succès vu AVANT l'échec réel — sur une PR dont le run a EN
  # RÉALITÉ échoué. Sur échec, on préfère donc le message "msg" du dernier bloc
  # fatal/FAILED! Ansible, jamais un tag OK antérieur ; repli sur tail -3 brut
  # si aucun bloc fatal reconnaissable (même hiérarchie TAGS→brut que
  # team-request.sh §4).
  SUMMARY=$(grep -A6 'fatal:\|FAILED!' "$TMP/onb.log" | grep -oE '"msg":.*' | tail -1 | cut -c1-300)
  [ -n "$SUMMARY" ] || SUMMARY=$(tail -3 "$TMP/onb.log" | tr '\n' ' ')
  # UN SEUL appel : fail() poste déjà son ❌ (comment(), ci-dessus) — le double
  # commentaire d'antan (celui-ci en détail, PUIS le générique de fail()) ne
  # laissait sur la PR QUE le second, sous le même marqueur (comment_upsert
  # REMPLACE) : REPO_NOTE et le résumé Ansible disparaissaient en silence.
  fail "onboarding EN ÉCHEC : ${SUMMARY:-voir le build}. Re-run possible : tout est idempotent (${REPO_NOTE})"
fi
echo "team-apply OK — ${REPO_NOTE}"
