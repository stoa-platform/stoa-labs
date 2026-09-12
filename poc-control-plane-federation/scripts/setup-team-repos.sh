#!/usr/bin/env bash
# scripts/setup-team-repos.sh — OUTIL DE POSTE du lab : pré-crée un dépôt d'équipe
# VIDE sur la forge, son ou ses webhooks vers team-publish/team-promote et la
# protection de sa branche par défaut — les trois gestes que la chaîne NE FAIT
# PLUS (D10 profond, ADR-099 : chez le client, c'est le client). Deux visages.
# Idempotent. Hors chaîne : exempté nommément par ci/lint-forge-literals.sh (il
# parle aux API de création).
#
#   FORGE_KIND=gitea  GIT_HOST=http://localhost:13000 FORGE_SECRET=<ci, write:organization,write:repository> \
#     scripts/setup-team-repos.sh <org>/<repo> [--print] [--no-hook] [--no-protect]
#   FORGE_KIND=gitlab GIT_HOST=http://localhost:13080 FORGE_SECRET=<PAT api, Owner du groupe> WEBHOOK_KIND=gitlab \
#     scripts/setup-team-repos.sh ci/<repo> [--print]
#
# Knobs :
#   TEAM_PUBLISH_WEBHOOK_URL    défaut gwt    : http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-team-publish
#                               défaut gitlab : http://jenkins:8080/project/team-publish
#   TEAM_PROMOTE_WEBHOOK_URL    IGNORÉ sous gwt (un seul hook au token partagé sert les deux jobs) ;
#                               défaut gitlab : http://jenkins:8080/project/team-promote — le GitLab
#                               Plugin expose UNE URL PAR JOB, il faut un hook PAR récepteur (Ruling 6).
#   WEBHOOK_KIND                gwt (défaut) | gitlab — forme du/des hook(s) posé(s).
#   WEBHOOK_SSL_VERIFY          true (défaut) | false — enable_ssl_verification du hook
#                               GitLab. `false` est réservé à un lab en HTTPS auto-signé ;
#                               il ne peut plus être subi en silence (il l'était : le champ
#                               était en dur à false). Sans effet au lab (http://jenkins:8080).
#   GIT_BASE                    branche à protéger ; ABSENT ⇒ la forge attribue sa branche
#                               par défaut au dépôt créé, relue dans sa réponse (jamais un
#                               littéral deviné ici — Ruling 18, porte ci/lint-branch-literals.sh).
#   TEAM_PUBLISH_WEBHOOK_SECRET la valeur que le job team-publish ATTEND (PAS « le secret ») :
#                               Gitea, secret HMAC optionnel, SANS DÉFAUT ; GitLab, valeur
#                               X-Gitlab-Token du hook publish, défaut stoa-team-publish —
#                               aujourd'hui un littéral dans le Jenkinsfile (dette ADR-098).
#   TEAM_PROMOTE_WEBHOOK_SECRET IGNORÉ sous gwt ; sous gitlab, valeur X-Gitlab-Token du hook
#                               promote, défaut ${TEAM_PUBLISH_WEBHOOK_SECRET:-stoa-team-promote}.
#   PROTECT_PUSH_WHITELIST      Gitea, défaut ci.
#
# Ce que le token authentifie, et ce qu'il n'atteste PAS : il authentifie
# l'APPELANT du hook (la forge), jamais le PAYLOAD — l'intégrité reste la
# confrontation de WEBHOOK_REPO à providers.<env>.yml relu par le récepteur
# (REFUS REPO_AMBIGU, ADR-098). Sous gitlab la forme ${VAR:-littéral} est
# OBLIGATOIRE : un knob VIDE compte comme absent (Groovy fait `env.X ?: défaut`
# côté job) — poser une chaîne vide sur un hook GitLab rend 401 à l'invocation,
# jamais à la pose. Diagnostic : aucun build et rien dans Jenkins ⇒ lire
# l'historique de livraison du hook côté GitLab (401 = valeur du hook ≠ valeur
# du job) AVANT de suspecter le job lui-même.
#
# Option A (deux hooks, un par job) est plus SERRÉE que le gwt (un seul hook au
# token partagé réveille les deux jobs) : le récepteur trie promote/publish par
# BRANCHE, et team-promote ne construit plus jamais sur un merge api/* — un
# gain, pas une divergence.
#
# Refus nommés (rc 2) : REPO_REQUIS, REPO_INVALIDE, BRANCHE_INVALIDE,
# SECRET_FORGE_REQUIS, FORGE_KIND_INCONNU, WEBHOOK_SSL_VERIFY_INVALIDE,
# CREATION_ECHEC, REPO_GET, BRANCHE_PAR_DEFAUT_INDECIDABLE, HOOK_ECHEC,
# PROTECTION_ECHEC, ARGUMENT_INCONNU.
# `A && ok || bad` (SC2015) est l'idiome des poseurs du repo (cf. setup-terminus-apps.sh).
# shellcheck disable=SC2015
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/forge-identity.sh
. scripts/lib/forge-identity.sh || { echo "ERREUR: forge-identity.sh introuvable" >&2; exit 1; }
REPO_FULL=""; MODE=apply; HOOK=1; PROTECT=1
for a in "$@"; do case "$a" in --print) MODE=print;; --no-hook) HOOK=0;; --no-protect) PROTECT=0;; -*) echo "REFUS: ARGUMENT_INCONNU : $a" >&2; exit 2;; *) REPO_FULL="$a";; esac; done
[ -n "$REPO_FULL" ] || { echo "REFUS: REPO_REQUIS : <owner>/<repo> attendu en argument" >&2; exit 2; }
# VALIDÉ AVANT TOUT AUTRE TRAITEMENT — --print et le réseau compris : REPO_FULL
# finit interpolé dans six corps JSON (jbody, plus bas) ; sans cette porte, un
# nom forgé du type `apis","auto_init":true` PASSE la construction JSON (elle
# reste valide) et INJECTE des clés arbitraires dans l'appel de création —
# silencieux, pas une erreur bruyante (revue Task 11, fix round 1). Un seul
# `/` exigé (owner/repo), charset restreint aux formes réelles de Gitea/GitLab.
printf '%s' "$REPO_FULL" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
  || { echo "REFUS: REPO_INVALIDE : <owner>/<repo> en caractères [A-Za-z0-9._-] attendu" >&2; exit 2; }
FORGE_KIND="${FORGE_KIND:-gitea}"
case "$FORGE_KIND" in gitea|gitlab) ;; *) echo "REFUS: FORGE_KIND_INCONNU : '$FORGE_KIND' — attendu gitea ou gitlab" >&2; exit 2;; esac
GIT_HOST="${GIT_HOST:?GIT_HOST requis (base de la forge)}"
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : FORGE_SECRET (Gitea : write:organization,write:repository ; GitLab : PAT api, Owner du groupe)" >&2; exit 2; }
WEBHOOK_KIND="${WEBHOOK_KIND:-gwt}"; GIT_BASE="${GIT_BASE:-}"
# enable_ssl_verification du hook GitLab : VRAI par défaut. Un hook qui appelle
# un récepteur en HTTPS doit vérifier son certificat ; `false` en dur (ce que ce
# script posait) désarmait la vérification chez TOUS les clients pour la
# commodité d'un lab en auto-signé, sans que personne puisse le voir. Le lab, lui,
# appelle http://jenkins:8080 : le champ y est sans effet.
WEBHOOK_SSL_VERIFY="${WEBHOOK_SSL_VERIFY:-true}"
case "$WEBHOOK_SSL_VERIFY" in true|false) ;; *) echo "REFUS: WEBHOOK_SSL_VERIFY_INVALIDE : '$WEBHOOK_SSL_VERIFY' — attendu true ou false" >&2; exit 2;; esac
# JAMAIS de littéral de repli ici (Ruling 18, porte ci/lint-branch-literals.sh,
# même règle que scripts/lib/git-base.sh depuis L3) : GIT_BASE ABSENT signifie
# « laisser la forge attribuer sa propre branche par défaut au dépôt créé » —
# elle l'annonce dans sa réponse (default_branch), relue plus bas dans
# BASE_EFF. Quand GIT_BASE EST fourni (knob explicite, ou une DÉCOUVERTE de
# forge en amont — git_base_of / ls-remote --symref, jamais un « main » deviné
# ici), il s'interpole aussi dans les six corps JSON : même porte de forme que
# REPO_INVALIDE, mais SEULEMENT si non vide (vide = « pas fourni », pas une
# valeur invalide).
[ -z "$GIT_BASE" ] || printf '%s' "$GIT_BASE" | grep -Eq '^[A-Za-z0-9._/-]+$' \
  || { echo "REFUS: BRANCHE_INVALIDE : GIT_BASE en caractères [A-Za-z0-9._/-] attendu" >&2; exit 2; }
OWNER="${REPO_FULL%%/*}"; NAME="${REPO_FULL#*/}"

# Les hooks à poser : liste « URL<TAB>token » — une entrée sous gwt, deux sous
# gitlab (le GitLab Plugin a une URL par job ; le tri publish/promote se fait
# dans le récepteur, plus serré que le gwt où un seul appel réveille les deux
# jobs). Le token doit ÉGALER le secretToken configuré sur le JOB (globales
# Jenkins de mêmes noms) : mêmes littéraux et même chaîne de repli que les
# Jenkinsfile (Ruling 6, addendum §1).
case "$WEBHOOK_KIND" in
  gitlab)
    HOOKS="${TEAM_PUBLISH_WEBHOOK_URL:-http://jenkins:8080/project/team-publish}	${TEAM_PUBLISH_WEBHOOK_SECRET:-stoa-team-publish}
${TEAM_PROMOTE_WEBHOOK_URL:-http://jenkins:8080/project/team-promote}	${TEAM_PROMOTE_WEBHOOK_SECRET:-${TEAM_PUBLISH_WEBHOOK_SECRET:-stoa-team-promote}}" ;;
  *)
    HOOKS="${TEAM_PUBLISH_WEBHOOK_URL:-http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-team-publish}	${TEAM_PUBLISH_WEBHOOK_SECRET:-}" ;;
esac
# Dédoublonnage PAR URL, avant toute pose : l'instantané des hooks déjà présents
# est relu UNE seule fois (avant la boucle, plus bas), donc deux entrées de même
# URL dans CETTE liste-ci poseraient deux hooks — la seconde ne pouvant pas voir
# la première. Le premier gagne : sous gitlab, publish précède promote.
HOOKS="$(awk -F'\t' '!vu[$1]++' <<<"$HOOKS")"

if [ "$MODE" = print ]; then
  echo "MODE=print"; echo "HOST=$GIT_HOST"; echo "KIND=$FORGE_KIND"; echo "REPO=$REPO_FULL"
  if [ "$HOOK" = 1 ]; then
    # ssl_verify n'est annoncé que sous le visage qui l'ENVOIE réellement (champ
    # de hook GitLab) : l'afficher sous gitea promettrait un champ inexistant.
    case "$FORGE_KIND" in gitlab) SSL_SHOW=" (ssl_verify=$WEBHOOK_SSL_VERIFY)";; *) SSL_SHOW="";; esac
    while IFS=$'\t' read -r H_URL _; do echo "HOOK=$H_URL$SSL_SHOW"; done <<<"$HOOKS"
  else
    echo "HOOK=(non posé)"
  fi
  if [ "$PROTECT" = 1 ]; then
    B_SHOW="${GIT_BASE:-(branche par défaut de la forge)}"
    case "$FORGE_KIND" in gitlab) echo "PROTECT=$B_SHOW (access_level 40, allow_force_push false)";; *) echo "PROTECT=$B_SHOW (push whitelist: ${PROTECT_PUSH_WHITELIST:-ci})";; esac
  else echo "PROTECT=(non posée)"; fi
  exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
forge_auth_write "$FORGE_SECRET" "$TMP/hdr" || exit 2
api(){ curl -sS -m 30 -H @"$TMP/hdr" -H 'Content-Type: application/json' "$@"; }
enc(){ python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
# jbody clé=valeur… [clé:=json] [clé^=VAR_ENV] — le corps JSON est ÉCRIT par
# json.dumps, JAMAIS interpolé par bash : REPO_INVALIDE/BRANCHE_INVALIDE
# ferment déjà REPO_FULL/GIT_BASE en amont, mais NAME/OWNER en dérivent et
# H_URL vient d'un knob — même discipline que scripts/lib/repo-protection.sh
# et scripts/setup-terminus-apps.sh (revue Task 11, fix round 1) : un
# guillemet dans une valeur ne peut plus injecter de clé.
#   clé=valeur   → chaîne, valeur prise TELLE QUELLE dans l'argv (URL, nom…) ;
#   clé:=json    → JSON brut (booléen/nombre/tableau/objet imbriqué, ex. un
#                  jbody NICHÉ dans jbody) ;
#   clé^=VAR_ENV → chaîne lue dans la variable d'ENVIRONNEMENT nommée VAR_ENV :
#                  l'argv de python3 ne porte ici que le NOM "VAR_ENV" (littéral
#                  en dur dans le code, jamais une valeur). L'appelant exporte la
#                  variable pour la durée du SEUL appel (`H_TOK="$H_TOK" jbody …`),
#                  jamais globalement.
# CE QUE `jbody` NE SUFFIT PAS À GARANTIR — corrigé le 2026-09-12 (revue finale
# L5 phase 2), l'en-tête d'avant affirmait le contraire : `^=` protège l'argv de
# PYTHON, pas celui de CURL. Le corps RENDU sur la sortie standard revenait dans
# `-d "$(jbody …)"`, donc dans l'argv de curl — secret compris, visible d'un
# `ps -Aww` — et sous gitea l'objet `config` rendu repassait en plus dans l'argv
# du python3 suivant (`config:=$CFG`). RÈGLE : un corps qui porte un secret
# passe par `jbody_file` (fichier 0600 + `-d @fichier`), jamais par `jbody`.
# La détection est sans ambiguïté quel que soit le contenu de la VALEUR : les
# clés sont des littéraux choisis ICI (jamais dynamiques), donc le premier
# « = » de la chaîne suit TOUJOURS la clé, et le caractère qui le précède (« : »,
# « ^ » ou rien) est celui qui décide du mode — la valeur, elle, peut contenir
# n'importe quoi (guillemets compris) sans jamais rouvrir cette décision.
jbody(){
  python3 - "$@" <<'PY'
import json, os, sys
d = {}
for a in sys.argv[1:]:
    i = a.index("=")
    prefix, val = a[:i], a[i+1:]
    if prefix.endswith(":"):
        d[prefix[:-1]] = json.loads(val)
    elif prefix.endswith("^"):
        d[prefix[:-1]] = os.environ.get(val, "")
    else:
        d[prefix] = val
print(json.dumps(d, ensure_ascii=False))
PY
}
# jbody_file <fichier> clé=valeur… — MÊME grammaire que jbody (=, :=, ^=), mais
# le corps est ÉCRIT dans <fichier> au lieu d'être rendu sur la sortie standard,
# et une clé POINTÉE niche : `config.secret^=H_TOK` produit {"config":{"secret":…}}.
# Les deux propriétés servent la même fin : UN SEUL appel python construit
# l'objet ENTIER, imbrication comprise, et rien de ce qu'il produit ne repasse
# par un argv — ni celui de curl (`-d @fichier`), ni celui d'un python suivant.
# Le fichier naît sous `umask 077` dans $TMP (lui-même 0700), donc 0600.
# Les clés sont des littéraux choisis ICI : aucune ne contient de point, la
# nidification est donc sans ambiguïté, comme le choix du mode.
jbody_file(){ # <fichier> clé=valeur…
  python3 - "$@" <<'PY'
import json, os, sys
dest = sys.argv[1]
d = {}
for a in sys.argv[2:]:
    i = a.index("=")
    prefix, val = a[:i], a[i+1:]
    if prefix.endswith(":"):
        key, val = prefix[:-1], json.loads(val)
    elif prefix.endswith("^"):
        key, val = prefix[:-1], os.environ.get(val, "")
    else:
        key = prefix
    parts = key.split(".")
    node = d
    for p in parts[:-1]:
        node = node.setdefault(p, {})
    node[parts[-1]] = val
with open(dest, "w") as f:
    json.dump(d, f, ensure_ascii=False)
PY
}
# default_branch_of <fichier-json> — lit la branche par défaut ANNONCÉE par la
# forge dans un objet dépôt (Gitea) ou projet (GitLab) : les DEUX portent le
# même champ "default_branch" (mesuré). Utilisé UNIQUEMENT quand GIT_BASE est
# ABSENT (Ruling 18) : c'est la forge qui a choisi, jamais ce script — sur le
# corps de la création (le `POST` la renvoie déjà) ou sur celui du `GET`
# quand le dépôt existait déjà.
default_branch_of(){ # <fichier-json>
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(d.get("default_branch") or "")
' "$1"
}
case "$FORGE_KIND" in
  gitea)
    B="${GIT_HOST%/}/api/v1"
    hc=$(api -o /dev/null -w '%{http_code}' "$B/orgs/$OWNER") || { echo "REFUS: CREATION_ECHEC : forge injoignable ($GIT_HOST)" >&2; exit 2; }
    if [ "$hc" != 200 ]; then
      hc=$(api -X POST -d "$(jbody username="$OWNER")" -o "$TMP/e" -w '%{http_code}' "$B/orgs"); { [ "$hc" = 201 ] || [ "$hc" = 200 ]; } || { echo "REFUS: CREATION_ECHEC : org $OWNER (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      echo "org $OWNER : créée"
    fi
    hc=$(api -o "$TMP/r" -w '%{http_code}' "$B/repos/$REPO_FULL")
    if [ "$hc" = 404 ]; then
      REPO_CREATE_ARGS=(name="$NAME" auto_init:=false)
      [ -z "$GIT_BASE" ] || REPO_CREATE_ARGS+=(default_branch="$GIT_BASE")
      hc=$(api -X POST -d "$(jbody "${REPO_CREATE_ARGS[@]}")" -o "$TMP/e" -w '%{http_code}' "$B/orgs/$OWNER/repos")
      [ "$hc" = 201 ] || { echo "REFUS: CREATION_ECHEC : dépôt $REPO_FULL (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      BASE_EFF="${GIT_BASE:-$(default_branch_of "$TMP/e")}"
      echo "dépôt $REPO_FULL : créé VIDE (HEAD annoncée : ${BASE_EFF:-?})"
    elif [ "$hc" = 200 ]; then
      BASE_EFF="${GIT_BASE:-$(default_branch_of "$TMP/r")}"
      echo "dépôt $REPO_FULL : existe (idempotence)"
    else echo "REFUS: REPO_GET : $REPO_FULL (HTTP $hc)" >&2; exit 2; fi
    [ -n "$BASE_EFF" ] || { echo "REFUS: BRANCHE_PAR_DEFAUT_INDECIDABLE : $REPO_FULL — la forge n'a annoncé aucun default_branch (HTTP $hc) et GIT_BASE n'est pas posé : poser GIT_BASE explicitement" >&2; exit 2; }
    if [ "$HOOK" = 1 ]; then
      EXISTING=$(api "$B/repos/$REPO_FULL/hooks")
      while IFS=$'\t' read -r H_URL H_TOK; do
        if grep -qF "\"url\":\"$H_URL\"" <<<"$EXISTING"; then echo "hook $H_URL : déjà posé"
        else
          # UN SEUL python construit le corps ENTIER, `config` imbriquée
          # comprise, et l'ÉCRIT : plus de corps rendu qui repasserait en argv.
          SECRET_ARG=""; [ -n "$H_TOK" ] && SECRET_ARG="config.secret^=H_TOK"
          H_TOK="$H_TOK" jbody_file "$TMP/body.json" type=gitea active:=true events:='["pull_request"]' \
            config.url="$H_URL" config.content_type=json ${SECRET_ARG:+"$SECRET_ARG"} \
            || { echo "REFUS: HOOK_ECHEC : $H_URL (corps JSON inconstructible)" >&2; exit 2; }
          hc=$(api -X POST -d @"$TMP/body.json" -o "$TMP/e" -w '%{http_code}' "$B/repos/$REPO_FULL/hooks")
          [ "$hc" = 201 ] && echo "hook $H_URL : posé" || { echo "REFUS: HOOK_ECHEC : $H_URL (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
        fi
      done <<<"$HOOKS"
    fi
    if [ "$PROTECT" = 1 ]; then
      # shellcheck source=scripts/lib/repo-protection.sh
      . scripts/lib/repo-protection.sh || exit 1
      repo_protection_payload "$BASE_EFF" "${PROTECT_PUSH_WHITELIST:-ci}" > "$TMP/prot.json" || { echo "REFUS: PROTECTION_ECHEC : payload" >&2; exit 2; }
      # la protection ne se pose que sur une branche qui EXISTE : sur un dépôt vide, elle attend le squelette
      if api "$B/repos/$REPO_FULL/branches/$BASE_EFF" -o /dev/null -w '%{http_code}' | grep -q 200; then
        pose_branch_protection "$GIT_HOST" "$TMP/hdr" "$REPO_FULL" "$TMP/prot.json" && echo "protection $BASE_EFF : posée" || { echo "REFUS: PROTECTION_ECHEC" >&2; exit 2; }
      else echo "protection $BASE_EFF : différée (branche absente — dépôt vide) : repasser après le squelette"; fi
    fi ;;
  gitlab)
    B="${GIT_HOST%/}/api/v4"; P=$(enc "$REPO_FULL")
    hc=$(api -o "$TMP/g" -w '%{http_code}' "$B/groups/$(enc "$OWNER")") || { echo "REFUS: CREATION_ECHEC : forge injoignable ($GIT_HOST)" >&2; exit 2; }
    [ "$hc" = 200 ] || { echo "REFUS: CREATION_ECHEC : groupe $OWNER introuvable (HTTP $hc) — le groupe est un prérequis (setup-gitlab-lab.sh crée ci)" >&2; exit 2; }
    GID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$TMP/g")
    hc=$(api -o "$TMP/r" -w '%{http_code}' "$B/projects/$P")
    if [ "$hc" = 404 ]; then
      PROJ_CREATE_ARGS=(name="$NAME" path="$NAME" namespace_id:="$GID" visibility=private initialize_with_readme:=false merge_method=merge)
      [ -z "$GIT_BASE" ] || PROJ_CREATE_ARGS+=(default_branch="$GIT_BASE")
      hc=$(api -X POST -d "$(jbody "${PROJ_CREATE_ARGS[@]}")" -o "$TMP/e" -w '%{http_code}' "$B/projects")
      [ "$hc" = 201 ] || { echo "REFUS: CREATION_ECHEC : projet $REPO_FULL (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      BASE_EFF="${GIT_BASE:-$(default_branch_of "$TMP/e")}"
      echo "projet $REPO_FULL : créé VIDE, privé, merge_method=merge (HEAD annoncée : ${BASE_EFF:-?})"
    elif [ "$hc" = 200 ]; then
      BASE_EFF="${GIT_BASE:-$(default_branch_of "$TMP/r")}"
      echo "projet $REPO_FULL : existe (idempotence)"
    else echo "REFUS: REPO_GET : $REPO_FULL (HTTP $hc)" >&2; exit 2; fi
    [ -n "$BASE_EFF" ] || { echo "REFUS: BRANCHE_PAR_DEFAUT_INDECIDABLE : $REPO_FULL — la forge n'a annoncé aucun default_branch (HTTP $hc) et GIT_BASE n'est pas posé : poser GIT_BASE explicitement" >&2; exit 2; }
    if [ "$HOOK" = 1 ]; then
      EXISTING=$(api "$B/projects/$P/hooks")
      while IFS=$'\t' read -r H_URL H_TOK; do
        if grep -qF "\"url\":\"$H_URL\"" <<<"$EXISTING"; then echo "hook $H_URL : déjà posé"
        else
          H_TOK="$H_TOK" jbody_file "$TMP/body.json" url="$H_URL" merge_requests_events:=true push_events:=false \
            "enable_ssl_verification:=$WEBHOOK_SSL_VERIFY" token^=H_TOK \
            || { echo "REFUS: HOOK_ECHEC : $H_URL (corps JSON inconstructible)" >&2; exit 2; }
          hc=$(api -X POST -d @"$TMP/body.json" -o "$TMP/e" -w '%{http_code}' "$B/projects/$P/hooks")
          [ "$hc" = 201 ] && echo "hook $H_URL : posé (merge_requests_events)" || { echo "REFUS: HOOK_ECHEC : $H_URL (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
        fi
      done <<<"$HOOKS"
    fi
    if [ "$PROTECT" = 1 ]; then
      hc=$(api -o /dev/null -w '%{http_code}' "$B/projects/$P/protected_branches/$(enc "$BASE_EFF")")
      if [ "$hc" = 200 ]; then echo "protection $BASE_EFF : déjà posée"
      else
        hc=$(api -X POST -d "$(jbody name="$BASE_EFF" push_access_level:=40 merge_access_level:=40 allow_force_push:=false)" -o "$TMP/e" -w '%{http_code}' "$B/projects/$P/protected_branches")
        [ "$hc" = 201 ] && echo "protection $BASE_EFF : posée (par RÔLE — GitLab CE n'a pas la protection nominative)" || { echo "REFUS: PROTECTION_ECHEC : (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      fi
    fi ;;
esac
echo "OK — $REPO_FULL prêt pour team-apply (vide ou initialisé), hook(s) et protection selon les options"
