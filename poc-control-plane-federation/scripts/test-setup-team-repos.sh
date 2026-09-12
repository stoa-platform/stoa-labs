#!/usr/bin/env bash
# test-setup-team-repos.sh — l'outil de POSTE qui pré-crée les dépôts d'équipe du
# lab (D10 : la chaîne ne les crée plus). Hors ligne : --print, refus nommés,
# propreté shellcheck, deux visages dans le --print, aucun réseau.
# shellcheck disable=SC2015
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO" || exit 2
T=scripts/setup-team-repos.sh
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }; ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
EXPECTED_CHECKS=8
[ -x "$T" ] && ok "1 l'outil existe et est exécutable" || ko "1 $T absent"
shellcheck -x "$T" >/dev/null 2>&1 && ok "2 shellcheck propre" || ko "2 shellcheck"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" fbi/apis --print 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q '^KIND=gitea$' <<<"$OUT" && grep -q '^REPO=fbi/apis$' <<<"$OUT" && grep -q '^HOOK=http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-team-publish$' <<<"$OUT" \
  && [ "$(grep -c '^HOOK=' <<<"$OUT")" = 1 ] \
  && ok "3 --print gitea : KIND/REPO/HOOK (un seul hook sous gwt), sans réseau (hôte mort)" || ko "3 rc $RC : $(head -3 <<<"$OUT" | tr '\n' ' ')"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab WEBHOOK_KIND=gitlab GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" ci/fbi-apis --print 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q '^KIND=gitlab$' <<<"$OUT" \
  && grep -q '^HOOK=http://jenkins:8080/project/team-publish$' <<<"$OUT" \
  && grep -q '^HOOK=http://jenkins:8080/project/team-promote$' <<<"$OUT" \
  && [ "$(grep -c '^HOOK=' <<<"$OUT")" = 2 ] \
  && grep -q '^PROTECT=main (access_level 40, allow_force_push false)$' <<<"$OUT" \
  && ! grep -q 'stoa-team-p' <<<"$OUT" \
  && ok "4 --print gitlab : DEUX hooks de projet (publish + promote, option A), protection par rôle, aucun token affiché" \
  || ko "4 rc $RC : $(head -4 <<<"$OUT" | tr '\n' ' ')"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 bash "$T" fbi/apis --print 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q 'SECRET_FORGE_REQUIS' <<<"$OUT" && ok "5 sans secret ⇒ SECRET_FORGE_REQUIS (même en --print : l'outil ne ment pas sur ce qu'il faudra)" || ko "5 rc $RC : $(head -1 <<<"$OUT")"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" --print 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q 'REPO_REQUIS' <<<"$OUT" && ok "6 sans dépôt ⇒ REPO_REQUIS" || ko "6 rc $RC"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=bitbucket GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" a/b --print 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q 'FORGE_KIND_INCONNU' <<<"$OUT" && ok "7 visage inconnu ⇒ FORGE_KIND_INCONNU" || ko "7 rc $RC"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" fbi/apis 2>&1); RC=$?
[ "$RC" != 0 ] && grep -qE 'injoignable|CREATION_ECHEC|REPO_GET' <<<"$OUT" && ok "8 hôte mort sans --print ⇒ refus nommé, jamais un vert" || ko "8 rc $RC : $(head -1 <<<"$OUT")"
TOTAL=$((PASS+FAIL)); [ "$TOTAL" -eq "$EXPECTED_CHECKS" ] && ok "total $EXPECTED_CHECKS" || ko "total $TOTAL ≠ $EXPECTED_CHECKS"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS+FAIL)); [ "$FAIL" -eq 0 ]
