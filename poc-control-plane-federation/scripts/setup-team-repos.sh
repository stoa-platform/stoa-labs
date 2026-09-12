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
#   GIT_BASE                    branche à protéger, défaut main.
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
# Refus nommés (rc 2) : REPO_REQUIS, SECRET_FORGE_REQUIS, FORGE_KIND_INCONNU,
# CREATION_ECHEC, HOOK_ECHEC, PROTECTION_ECHEC, ARGUMENT_INCONNU.
# `A && ok || bad` (SC2015) est l'idiome des poseurs du repo (cf. setup-terminus-apps.sh).
# shellcheck disable=SC2015
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/forge-identity.sh
. scripts/lib/forge-identity.sh || { echo "ERREUR: forge-identity.sh introuvable" >&2; exit 1; }
REPO_FULL=""; MODE=apply; HOOK=1; PROTECT=1
for a in "$@"; do case "$a" in --print) MODE=print;; --no-hook) HOOK=0;; --no-protect) PROTECT=0;; -*) echo "REFUS: ARGUMENT_INCONNU : $a" >&2; exit 2;; *) REPO_FULL="$a";; esac; done
[ -n "$REPO_FULL" ] && case "$REPO_FULL" in */*) ;; *) REPO_FULL="";; esac
[ -n "$REPO_FULL" ] || { echo "REFUS: REPO_REQUIS : <owner>/<repo> attendu en argument" >&2; exit 2; }
FORGE_KIND="${FORGE_KIND:-gitea}"
case "$FORGE_KIND" in gitea|gitlab) ;; *) echo "REFUS: FORGE_KIND_INCONNU : '$FORGE_KIND' — attendu gitea ou gitlab" >&2; exit 2;; esac
GIT_HOST="${GIT_HOST:?GIT_HOST requis (base de la forge)}"
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : FORGE_SECRET (Gitea : write:organization,write:repository ; GitLab : PAT api, Owner du groupe)" >&2; exit 2; }
WEBHOOK_KIND="${WEBHOOK_KIND:-gwt}"; GIT_BASE="${GIT_BASE:-main}"
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

if [ "$MODE" = print ]; then
  echo "MODE=print"; echo "HOST=$GIT_HOST"; echo "KIND=$FORGE_KIND"; echo "REPO=$REPO_FULL"
  if [ "$HOOK" = 1 ]; then
    while IFS=$'\t' read -r H_URL _; do echo "HOOK=$H_URL"; done <<<"$HOOKS"
  else
    echo "HOOK=(non posé)"
  fi
  if [ "$PROTECT" = 1 ]; then case "$FORGE_KIND" in gitlab) echo "PROTECT=$GIT_BASE (access_level 40, allow_force_push false)";; *) echo "PROTECT=$GIT_BASE (push whitelist: ${PROTECT_PUSH_WHITELIST:-ci})";; esac; else echo "PROTECT=(non posée)"; fi
  exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
forge_auth_write "$FORGE_SECRET" "$TMP/hdr" || exit 2
api(){ curl -sS -m 30 -H @"$TMP/hdr" -H 'Content-Type: application/json' "$@"; }
enc(){ python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
case "$FORGE_KIND" in
  gitea)
    B="${GIT_HOST%/}/api/v1"
    hc=$(api -o /dev/null -w '%{http_code}' "$B/orgs/$OWNER") || { echo "REFUS: CREATION_ECHEC : forge injoignable ($GIT_HOST)" >&2; exit 2; }
    if [ "$hc" != 200 ]; then
      hc=$(api -X POST -d "{\"username\":\"$OWNER\"}" -o "$TMP/e" -w '%{http_code}' "$B/orgs"); { [ "$hc" = 201 ] || [ "$hc" = 200 ]; } || { echo "REFUS: CREATION_ECHEC : org $OWNER (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      echo "org $OWNER : créée"
    fi
    hc=$(api -o "$TMP/r" -w '%{http_code}' "$B/repos/$REPO_FULL")
    if [ "$hc" = 404 ]; then
      hc=$(api -X POST -d "{\"name\":\"$NAME\",\"auto_init\":false,\"default_branch\":\"$GIT_BASE\"}" -o "$TMP/e" -w '%{http_code}' "$B/orgs/$OWNER/repos")
      [ "$hc" = 201 ] || { echo "REFUS: CREATION_ECHEC : dépôt $REPO_FULL (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      echo "dépôt $REPO_FULL : créé VIDE (HEAD annoncée : $GIT_BASE)"
    elif [ "$hc" = 200 ]; then echo "dépôt $REPO_FULL : existe (idempotence)"
    else echo "REFUS: REPO_GET : $REPO_FULL (HTTP $hc)" >&2; exit 2; fi
    if [ "$HOOK" = 1 ]; then
      EXISTING=$(api "$B/repos/$REPO_FULL/hooks")
      while IFS=$'\t' read -r H_URL H_TOK; do
        if grep -qF "\"url\":\"$H_URL\"" <<<"$EXISTING"; then echo "hook $H_URL : déjà posé"
        else
          hc=$(api -X POST -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"pull_request\"],\"config\":{\"url\":\"$H_URL\",\"content_type\":\"json\"${H_TOK:+,\"secret\":\"$H_TOK\"}}}" -o "$TMP/e" -w '%{http_code}' "$B/repos/$REPO_FULL/hooks")
          [ "$hc" = 201 ] && echo "hook $H_URL : posé" || { echo "REFUS: HOOK_ECHEC : $H_URL (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
        fi
      done <<<"$HOOKS"
    fi
    if [ "$PROTECT" = 1 ]; then
      # shellcheck source=scripts/lib/repo-protection.sh
      . scripts/lib/repo-protection.sh || exit 1
      repo_protection_payload "$GIT_BASE" "${PROTECT_PUSH_WHITELIST:-ci}" > "$TMP/prot.json" || { echo "REFUS: PROTECTION_ECHEC : payload" >&2; exit 2; }
      # la protection ne se pose que sur une branche qui EXISTE : sur un dépôt vide, elle attend le squelette
      if api "$B/repos/$REPO_FULL/branches/$GIT_BASE" -o /dev/null -w '%{http_code}' | grep -q 200; then
        pose_branch_protection "$GIT_HOST" "$TMP/hdr" "$REPO_FULL" "$TMP/prot.json" && echo "protection $GIT_BASE : posée" || { echo "REFUS: PROTECTION_ECHEC" >&2; exit 2; }
      else echo "protection $GIT_BASE : différée (branche absente — dépôt vide) : repasser après le squelette"; fi
    fi ;;
  gitlab)
    B="${GIT_HOST%/}/api/v4"; P=$(enc "$REPO_FULL")
    hc=$(api -o "$TMP/g" -w '%{http_code}' "$B/groups/$(enc "$OWNER")") || { echo "REFUS: CREATION_ECHEC : forge injoignable ($GIT_HOST)" >&2; exit 2; }
    [ "$hc" = 200 ] || { echo "REFUS: CREATION_ECHEC : groupe $OWNER introuvable (HTTP $hc) — le groupe est un prérequis (setup-gitlab-lab.sh crée ci)" >&2; exit 2; }
    GID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$TMP/g")
    hc=$(api -o "$TMP/r" -w '%{http_code}' "$B/projects/$P")
    if [ "$hc" = 404 ]; then
      hc=$(api -X POST -d "{\"name\":\"$NAME\",\"path\":\"$NAME\",\"namespace_id\":$GID,\"visibility\":\"private\",\"initialize_with_readme\":false,\"merge_method\":\"merge\",\"default_branch\":\"$GIT_BASE\"}" -o "$TMP/e" -w '%{http_code}' "$B/projects")
      [ "$hc" = 201 ] || { echo "REFUS: CREATION_ECHEC : projet $REPO_FULL (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      echo "projet $REPO_FULL : créé VIDE, privé, merge_method=merge"
    elif [ "$hc" = 200 ]; then echo "projet $REPO_FULL : existe (idempotence)"
    else echo "REFUS: REPO_GET : $REPO_FULL (HTTP $hc)" >&2; exit 2; fi
    if [ "$HOOK" = 1 ]; then
      EXISTING=$(api "$B/projects/$P/hooks")
      while IFS=$'\t' read -r H_URL H_TOK; do
        if grep -qF "\"url\":\"$H_URL\"" <<<"$EXISTING"; then echo "hook $H_URL : déjà posé"
        else
          hc=$(api -X POST -d "{\"url\":\"$H_URL\",\"merge_requests_events\":true,\"push_events\":false,\"enable_ssl_verification\":false,\"token\":\"$H_TOK\"}" -o "$TMP/e" -w '%{http_code}' "$B/projects/$P/hooks")
          [ "$hc" = 201 ] && echo "hook $H_URL : posé (merge_requests_events)" || { echo "REFUS: HOOK_ECHEC : $H_URL (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
        fi
      done <<<"$HOOKS"
    fi
    if [ "$PROTECT" = 1 ]; then
      hc=$(api -o /dev/null -w '%{http_code}' "$B/projects/$P/protected_branches/$(enc "$GIT_BASE")")
      if [ "$hc" = 200 ]; then echo "protection $GIT_BASE : déjà posée"
      else
        hc=$(api -X POST -d "{\"name\":\"$GIT_BASE\",\"push_access_level\":40,\"merge_access_level\":40,\"allow_force_push\":false}" -o "$TMP/e" -w '%{http_code}' "$B/projects/$P/protected_branches")
        [ "$hc" = 201 ] && echo "protection $GIT_BASE : posée (par RÔLE — GitLab CE n'a pas la protection nominative)" || { echo "REFUS: PROTECTION_ECHEC : (HTTP $hc) $(head -c 200 "$TMP/e")" >&2; exit 2; }
      fi
    fi ;;
esac
echo "OK — $REPO_FULL prêt pour team-apply (vide ou initialisé), hook(s) et protection selon les options"
