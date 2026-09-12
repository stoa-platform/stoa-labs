#!/usr/bin/env bash
# test-setup-team-repos.sh — l'outil de POSTE qui pré-crée les dépôts d'équipe du
# lab (D10 : la chaîne ne les crée plus). Hors ligne : --print, refus nommés,
# propreté shellcheck, deux visages dans le --print, aucun réseau.
# Depuis la revue finale L5 phase 2 (2026-09-12) : ⑪-⑬ exercent AUSSI le chemin
# d'écriture, avec un FAUX curl en tête de PATH — le seul moyen hors ligne de
# mesurer ce qui part réellement en ARGV (ce que `ps -Aww` d'un voisin verrait).
# shellcheck disable=SC2015
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO" || exit 2
T=scripts/setup-team-repos.sh
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }; ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
EXPECTED_CHECKS=13
[ -x "$T" ] && ok "1 l'outil existe et est exécutable" || ko "1 $T absent"
shellcheck -x "$T" >/dev/null 2>&1 && ok "2 shellcheck propre" || ko "2 shellcheck"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x GIT_BASE=main bash "$T" fbi/apis --print 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q '^KIND=gitea$' <<<"$OUT" && grep -q '^REPO=fbi/apis$' <<<"$OUT" && grep -q '^HOOK=http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-team-publish$' <<<"$OUT" \
  && [ "$(grep -c '^HOOK=' <<<"$OUT")" = 1 ] \
  && ok "3 --print gitea : KIND/REPO/HOOK (un seul hook sous gwt), sans réseau (hôte mort)" || ko "3 rc $RC : $(head -3 <<<"$OUT" | tr '\n' ' ')"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab WEBHOOK_KIND=gitlab GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x GIT_BASE=main bash "$T" ci/fbi-apis --print 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q '^KIND=gitlab$' <<<"$OUT" \
  && grep -q '^HOOK=http://jenkins:8080/project/team-publish (ssl_verify=true)$' <<<"$OUT" \
  && grep -q '^HOOK=http://jenkins:8080/project/team-promote (ssl_verify=true)$' <<<"$OUT" \
  && [ "$(grep -c '^HOOK=' <<<"$OUT")" = 2 ] \
  && grep -q '^PROTECT=main (access_level 40, allow_force_push false)$' <<<"$OUT" \
  && ! grep -q 'stoa-team-p' <<<"$OUT" \
  && ok "4 --print gitlab : DEUX hooks de projet (publish + promote, option A) avec leur ssl_verify, protection par rôle, aucun token affiché" \
  || ko "4 rc $RC : $(head -4 <<<"$OUT" | tr '\n' ' ')"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 bash "$T" fbi/apis --print 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q 'SECRET_FORGE_REQUIS' <<<"$OUT" && ok "5 sans secret ⇒ SECRET_FORGE_REQUIS (même en --print : l'outil ne ment pas sur ce qu'il faudra)" || ko "5 rc $RC : $(head -1 <<<"$OUT")"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" --print 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q 'REPO_REQUIS' <<<"$OUT" && ok "6 sans dépôt ⇒ REPO_REQUIS" || ko "6 rc $RC"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=bitbucket GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" a/b --print 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q 'FORGE_KIND_INCONNU' <<<"$OUT" && ok "7 visage inconnu ⇒ FORGE_KIND_INCONNU" || ko "7 rc $RC"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" fbi/apis 2>&1); RC=$?
[ "$RC" != 0 ] && grep -qE 'injoignable|CREATION_ECHEC|REPO_GET' <<<"$OUT" && ok "8 hôte mort sans --print ⇒ refus nommé, jamais un vert" || ko "8 rc $RC : $(head -1 <<<"$OUT")"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" 'fbi/apis","auto_init":true' --print 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q REPO_INVALIDE <<<"$OUT" && ok "9 un nom de dépôt forgé est REFUSÉ avant tout réseau, même en --print (jamais interpolé dans un corps JSON)" || ko "9 rc $RC : $(head -1 <<<"$OUT")"
OUT=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitea GIT_HOST=http://127.0.0.1:1 FORGE_SECRET=x bash "$T" fbi/apis --print 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q '^PROTECT=(branche par défaut de la forge) (push whitelist: ci)$' <<<"$OUT" && ! grep -q 'main' <<<"$OUT" \
  && ok "10 --print sans GIT_BASE ⇒ aucune branche inventée, la forge décide (Ruling 18)" || ko "10 rc $RC : $(tr '\n' ' ' <<<"$OUT")"

# ─────────────────────────────────────────────────────────────────────────────
# ⑪-⑬ le chemin d'ÉCRITURE, hors ligne : un faux curl en tête de PATH
# ─────────────────────────────────────────────────────────────────────────────
# POURQUOI un faux curl plutôt qu'un grep du source : la propriété mesurée
# (« le secret du hook ne transite par AUCUN argv ») est une propriété de
# l'APPEL, pas du texte. Un grep dirait « -d @ est présent » ; seul un curl
# qui journalise son propre argv prouve que la valeur n'y est PAS — c'est
# exactement ce que `ps -Aww` d'un voisin lirait sur la machine du client.
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT; umask 077
mkdir -p "$TMPD/bin"
cat > "$TMPD/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# faux curl du harnais : journalise l'ARGV COMPLET de chaque appel, puis le
# CORPS désigné par `-d @<fichier>` (ou posé en clair par `-d <json>`), et rend
# les codes qui laissent l'outil aller jusqu'au POST du hook. Aucun réseau.
LOG="${FAKE_CURL_LOG:?FAKE_CURL_LOG requis}"
{ printf 'ARGV'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$LOG"
METHOD=GET; OUT=""; WOUT=""; URL=""; DATA=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    -w) WOUT="$2"; shift 2 ;;
    -d) DATA="$2"; shift 2 ;;
    -H) shift 2 ;;
    -m|--max-time|--upload-file) shift 2 ;;
    -*) shift ;;
    *)  URL="$1"; shift ;;
  esac
done
case "$DATA" in
  "") ;;
  @*) { printf 'BODY '; cat "${DATA#@}"; printf '\n'; } >> "$LOG" ;;
  *)  printf 'BODY %s\n' "$DATA" >> "$LOG" ;;
esac
case "$METHOD:$URL" in
  GET:*/hooks)                CODE=200; BODY='[]' ;;
  POST:*/hooks)               CODE=201; BODY='{"id":1}' ;;
  POST:*/protected_branches)  CODE=201; BODY='{}' ;;
  GET:*/branches/*)           CODE=404; BODY='{}' ;;
  GET:*/orgs/*)               CODE=200; BODY='{"username":"fbi"}' ;;
  GET:*/groups/*)             CODE=200; BODY='{"id":7}' ;;
  GET:*/repos/*)              CODE=404; BODY='{}' ;;
  GET:*/projects/*)           CODE=404; BODY='{}' ;;
  POST:*/repos)               CODE=201; BODY='{"default_branch":"main"}' ;;
  POST:*/projects)            CODE=201; BODY='{"default_branch":"main"}' ;;
  *)                          CODE=200; BODY='{}' ;;
esac
[ -z "$OUT" ] || printf '%s' "$BODY" > "$OUT"
if [ -n "$WOUT" ]; then printf '%s' "$CODE"
elif [ -z "$OUT" ]; then printf '%s' "$BODY"; fi
exit 0
FAKE
chmod +x "$TMPD/bin/curl"
# Valeur RECONNAISSABLE : si elle apparaît dans une ligne ARGV, la fuite est
# prouvée ; si elle n'apparaît QUE dans une ligne BODY, le corps est bien passé
# par un fichier.
SECRET_ARGV='SECRET-ARGV-TEST-42'

: > "$TMPD/g.log"
OUT=$(env -i PATH="$TMPD/bin:$PATH" HOME="$HOME" FAKE_CURL_LOG="$TMPD/g.log" \
  FORGE_KIND=gitea GIT_HOST=http://forge.invalide FORGE_SECRET=x GIT_BASE=main \
  TEAM_PUBLISH_WEBHOOK_SECRET="$SECRET_ARGV" bash "$T" fbi/apis 2>&1); RC=$?
grep '^ARGV ' "$TMPD/g.log" > "$TMPD/g.argv"; grep '^BODY ' "$TMPD/g.log" > "$TMPD/g.body"
{ [ "$RC" = 0 ] \
  && ! grep -qF "$SECRET_ARGV" "$TMPD/g.argv" \
  && grep -qF -- '-d @' "$TMPD/g.argv" \
  && grep -qF "$SECRET_ARGV" "$TMPD/g.body" \
  && grep -qF '"secret"' "$TMPD/g.body"; } \
  && ok "11 gitea : le secret du hook n'est dans AUCUN argv (ni curl, ni python) — il n'existe que dans le corps passé par -d @fichier, config imbriquée comprise" \
  || ko "11 rc $RC — argv fuité=$(grep -cF "$SECRET_ARGV" "$TMPD/g.argv") ; -d @=$(grep -cF -- '-d @' "$TMPD/g.argv") ; corps=$(grep -cF "$SECRET_ARGV" "$TMPD/g.body") : $(head -2 <<<"$OUT" | tr '\n' ' ')"

: > "$TMPD/l.log"
OUT=$(env -i PATH="$TMPD/bin:$PATH" HOME="$HOME" FAKE_CURL_LOG="$TMPD/l.log" \
  FORGE_KIND=gitlab WEBHOOK_KIND=gitlab GIT_HOST=http://forge.invalide FORGE_SECRET=x GIT_BASE=main \
  TEAM_PUBLISH_WEBHOOK_SECRET="$SECRET_ARGV" TEAM_PROMOTE_WEBHOOK_SECRET="$SECRET_ARGV" bash "$T" ci/fbi-apis 2>&1); RC=$?
grep '^ARGV ' "$TMPD/l.log" > "$TMPD/l.argv"; grep '^BODY ' "$TMPD/l.log" > "$TMPD/l.body"
{ [ "$RC" = 0 ] \
  && ! grep -qF "$SECRET_ARGV" "$TMPD/l.argv" \
  && grep -qF -- '-d @' "$TMPD/l.argv" \
  && grep -qF "$SECRET_ARGV" "$TMPD/l.body" \
  && grep -qE '"enable_ssl_verification":[[:space:]]*true' "$TMPD/l.body"; } \
  && ok "12 gitlab : le token du hook n'est dans AUCUN argv, et enable_ssl_verification suit le knob (défaut true, plus de false en dur)" \
  || ko "12 rc $RC — argv fuité=$(grep -cF "$SECRET_ARGV" "$TMPD/l.argv") ; -d @=$(grep -cF -- '-d @' "$TMPD/l.argv") ; corps=$(grep -cF "$SECRET_ARGV" "$TMPD/l.body") ; ssl=$(grep -cE '"enable_ssl_verification":[[:space:]]*true' "$TMPD/l.body") : $(head -2 <<<"$OUT" | tr '\n' ' ')"

# La liste EXISTING est lue UNE fois avant la boucle : deux URLs identiques
# posaient donc DEUX hooks (la seconde ne pouvait pas voir la première).
: > "$TMPD/d.log"
OUT=$(env -i PATH="$TMPD/bin:$PATH" HOME="$HOME" FAKE_CURL_LOG="$TMPD/d.log" \
  FORGE_KIND=gitlab WEBHOOK_KIND=gitlab GIT_HOST=http://forge.invalide FORGE_SECRET=x GIT_BASE=main \
  TEAM_PUBLISH_WEBHOOK_URL=http://jenkins:8080/project/unique \
  TEAM_PROMOTE_WEBHOOK_URL=http://jenkins:8080/project/unique bash "$T" ci/fbi-apis 2>&1); RC=$?
NPOST=$(grep -c -- '^ARGV .*-X POST .*/hooks$' "$TMPD/d.log")
{ [ "$RC" = 0 ] && [ "$NPOST" = 1 ]; } \
  && ok "13 deux URLs de hook IDENTIQUES ⇒ un SEUL POST (liste dédoublonnée avant la boucle, l'instantané EXISTING ne pouvait pas les départager)" \
  || ko "13 rc $RC : $NPOST POST de hook émis, 1 attendu"

TOTAL=$((PASS+FAIL)); [ "$TOTAL" -eq "$EXPECTED_CHECKS" ] && ok "total $EXPECTED_CHECKS" || ko "total $TOTAL ≠ $EXPECTED_CHECKS"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS+FAIL)); [ "$FAIL" -eq 0 ]
