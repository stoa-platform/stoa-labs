#!/usr/bin/env bash
# shellcheck disable=SC2015  # idiome des harnais du dépôt : `cond && ok "…" || ko "…"` — ok() finit par printf, rc 0
# test-forge-api-live.sh — L'ADAPTATEUR DE FORGE CONTRE DES FORGES RÉELLES.
#
# Le mock de test-forge-api.sh rend les formes que JE crois réelles. Cette suite
# joue les MÊMES verbes contre un GitLab CE et un Gitea qui tournent pour de
# vrai — c'est elle qui tranche si le mock ment (l'utilisateur, 2026-09-09 :
# « tu devrais passer sur gitlab en local pour valider tout cela »).
#
# CE QU'ELLE FAIT, sur CHAQUE forge, dans un projet de lab : pousse une branche
# de sonde par `git` (agnostique), puis par l'adaptateur : whoami, pr_open,
# pr_find_open, pr_get, pr_files, comment_upsert ×2 (created puis updated),
# comment_find (le marqueur posé, puis un marqueur inconnu), pr_list_merged
# (la sonde est ouverte, jamais mergée : zéro ligne), raw ;
# et le DISCRIMINANT : FORGE_KIND=gitea contre le GitLab réel ⇒ la cause nomme
# « 302 » et « /users/sign_in » (la panne du client, reproduite ici).
# Elle NETTOIE derrière elle (ferme la MR/PR, supprime la branche) — mais un
# échec en cours de route peut laisser une branche `sonde/…` : sans conséquence.
#
# PRÉREQUIS :
#   GitLab : docker compose -f docker-compose.gitlab.yml up -d gitlab
#            bash scripts/setup-gitlab-lab.sh        → .env.gitlab-lab (PAT 0600)
#   Gitea  : le lab (poc-gitea, localhost:13000), jeton dans GITEA_LAB_TOKEN ou .env
#   Une forge absente est SAUTÉE en le disant — jamais comptée verte.
#
#   bash scripts/test-forge-api-live.sh            # les deux
#   FORGES=gitlab bash scripts/test-forge-api-live.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
LIB="$REPO/scripts/lib/forge-api.sh"
TMP="$(mktemp -d /tmp/forgelive.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM
umask 077
PASS=0; FAIL=0; SKIP=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
skip(){ SKIP=$((SKIP+1)); printf '  \033[33m- %s (sauté)\033[0m\n' "$*"; }
# shellcheck source=scripts/lib/forge-api.sh
. "$LIB"

FORGES="${FORGES:-gitlab gitea}"
GITLAB_URL="${GITLAB_LAB_URL:-http://localhost:13080}"
GITEA_URL="${GITEA_LAB_URL:-http://localhost:13000}"
if [ -r ./.env.gitlab-lab ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.gitlab-lab
  set +a
fi
# Le jeton Gitea du lab : GITEA_LAB_TOKEN, sinon le FICHIER que les suites -live
# lisent déjà (GITEA_TOKEN_FILE, motif de test-a7-live.sh), sinon .env. Absent ⇒
# la moitié Gitea est SAUTÉE en le disant, jamais comptée verte.
if [ -z "${GITEA_LAB_TOKEN:-}" ] && [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then GITEA_LAB_TOKEN="$(tr -d '\r\n' < "$GITEA_TOKEN_FILE")"; fi
[ -r ./.env ] && [ -z "${GITEA_LAB_TOKEN:-}" ] && GITEA_LAB_TOKEN="$(sed -n 's/^GITEA_TOKEN=//p' ./.env | head -1)"

# fx <verbe…> : joue le verbe sous l'environnement de la forge courante
fx(){ ( env -i PATH="$PATH" HOME="$HOME" FORGE_KIND="$K" GIT_HOST="$H" GIT_REPO="$R" FORGE_SECRET="$S" FORGE_API_AUTH="$A" bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge "$@"' _ "$@" ) > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"; }
rc(){ cat "$TMP/rc"; }
val(){ sed -n "s/^$1=//p" "$TMP/out" | head -1; }
cause(){ head -c 220 "$TMP/err" | tr '\n' ' '; }
# gitauth : l'enveloppe Basic du canal git (le secret n'est jamais en argv de git)
# http.postBuffer : un push > 1 Mio part en chunked et ce GitLab le refuse (500,
# gitaly « waiting for receive-pack: exit status 128 », mesuré) — buffé, il passe.
gitauth(){ GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic $(printf '%s:%s' "$GIT_USER" "$S" | base64 | tr -d '\n')" GIT_CONFIG_KEY_1=http.postBuffer GIT_CONFIG_VALUE_1=524288000 git "$@"; }

for K in $FORGES; do
  case "$K" in
    gitlab) H="$GITLAB_URL"; R="ci/stoa-labs"; S="${GITLAB_LAB_TOKEN:-}"; A=private-token; GIT_USER=oauth2 ;;
    gitea)  H="$GITEA_URL";  R="ci/stoa-labs"; S="${GITEA_LAB_TOKEN:-}"; A=token; GIT_USER=x ;;
    *) echo "forge inconnue : $K"; exit 2 ;;
  esac
  echo "═══ $K — $H ═══"
  if [ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$H/")" = 000 ]; then skip "$K injoignable sur $H"; continue; fi
  if [ -z "$S" ]; then skip "$K : aucun secret (GITLAB_LAB_TOKEN via setup-gitlab-lab.sh / GITEA_LAB_TOKEN)"; continue; fi

  fx probe
  [ "$(rc)" = 0 ] && [ "$(val KIND_DETECTED)" = "$K" ] && ok "$K A.1 probe (sans secret) ⇒ $K — la forge RÉELLE se présente comme le mock le disait" || ko "$K A.1 rc $(rc) : $(cat "$TMP/out") $(cause)"
  fx whoami
  LOGIN="$(val LOGIN)"
  if [ "$(rc)" = 0 ] && [ -n "$LOGIN" ]; then ok "$K B.1 whoami ⇒ LOGIN=$LOGIN"; else ko "$K B.1 rc $(rc) : $(cause)"; continue; fi

  # ── la branche de sonde, poussée par git (le canal agnostique) ──
  SONDE="sonde/forge-api-$(date +%s)-$$"
  W="$TMP/w-$K"; rm -rf "$W"
  CLONE="${H%/}/$R.git"
  if ! gitauth clone -q --depth 1 "$CLONE" "$W" 2>"$TMP/clone.err"; then
    ko "$K C.0 clone de $R impossible : $(head -c 160 "$TMP/clone.err")"; continue
  fi
  BASE="$(git -C "$W" rev-parse --abbrev-ref HEAD)"
  # Le fichier de sonde : SONDE porte une barre (sonde/…) — le chemin est aplati.
  FILE="sonde/${SONDE#sonde/}.txt"
  mkdir -p "$W/sonde"; printf 'sonde forge-api %s\n' "$SONDE" > "$W/$FILE"
  git -C "$W" -c user.name=sonde -c user.email=sonde@lab checkout -q -b "$SONDE" \
    && git -C "$W" -c user.name=sonde -c user.email=sonde@lab add -A \
    && git -C "$W" -c user.name=sonde -c user.email=sonde@lab commit -qm "sonde forge-api"
  if ! gitauth -C "$W" push -q origin "$SONDE" 2>"$TMP/push.err"; then
    ko "$K C.0 push de $SONDE impossible : $(head -c 160 "$TMP/push.err")"; continue
  fi
  ok "$K C.0 branche de sonde poussée par git (base $BASE) — le canal agnostique marche avec l'utilisateur Basic '$GIT_USER'"
  SHA="$(git -C "$W" rev-parse HEAD)"

  fx pr_find_open "$SONDE"
  [ "$(rc)" = 0 ] && [ -z "$(val NUMBER)" ] && ok "$K C.1 pr_find_open avant ouverture ⇒ NUMBER vide, rc 0" || ko "$K C.1 rc $(rc) NUMBER=$(val NUMBER) $(cause)"
  printf 'Sonde forge-api — ouverte par le harnais, sera fermée.\n' > "$TMP/body.txt"
  fx pr_open "$SONDE" "$BASE" "sonde: forge-api $K" "$TMP/body.txt"
  N="$(val NUMBER)"
  if [ "$(rc)" = 0 ] && [ -n "$N" ] && [ -n "$(val URL)" ]; then ok "$K E.1 pr_open ⇒ NUMBER=$N URL=$(val URL)"; else ko "$K E.1 rc $(rc) : $(cause)"; continue; fi
  fx pr_find_open "$SONDE"
  [ "$(rc)" = 0 ] && [ "$(val NUMBER)" = "$N" ] && [ "$(val LOGIN)" = "$LOGIN" ] && ok "$K C.2 pr_find_open ⇒ NUMBER=$N LOGIN=$LOGIN (l'auteur relu = whoami)" || ko "$K C.2 rc $(rc) NUMBER=$(val NUMBER) LOGIN=$(val LOGIN)"
  fx pr_get "$N"
  [ "$(rc)" = 0 ] && [ "$(val STATE)" = open ] && [ "$(val HEAD_REF)" = "$SONDE" ] && [ "$(val HEAD_SHA)" = "$SHA" ] && [ "$(val BASE_REF)" = "$BASE" ] && [ "$(val SAME_REPO)" = 1 ] && [ "$(val MERGED)" = 0 ] \
    && ok "$K D.1 pr_get $N ⇒ STATE=open HEAD_REF=$SONDE HEAD_SHA=le SHA poussé BASE_REF=$BASE SAME_REPO=1" || ko "$K D.1 rc $(rc) : $(tr '\n' ' ' < "$TMP/out") $(cause)"
  fx pr_files "$N"
  [ "$(rc)" = 0 ] && grep -qx "$FILE" "$TMP/out" && ok "$K F.1 pr_files ⇒ le fichier de la sonde ($FILE)" || ko "$K F.1 rc $(rc) : $(tr '\n' ' ' < "$TMP/out") $(cause)"
  printf 'premier verdict\n' > "$TMP/note.txt"
  fx comment_upsert "$N" "<!-- sonde:forge-api -->" "$TMP/note.txt"
  ID1="$(val ID)"
  [ "$(rc)" = 0 ] && [ "$(val ACTION)" = created ] && [ -n "$ID1" ] && ok "$K G.1 comment_upsert ⇒ created ID=$ID1" || ko "$K G.1 rc $(rc) : $(cause)"
  printf 'second verdict\n' > "$TMP/note.txt"
  fx comment_upsert "$N" "<!-- sonde:forge-api -->" "$TMP/note.txt"
  [ "$(rc)" = 0 ] && [ "$(val ACTION)" = updated ] && [ "$(val ID)" = "${ID1:-x}" ] && ok "$K G.2 comment_upsert (marqueur présent) ⇒ updated, MÊME ID=$ID1 — pas un doublon" || ko "$K G.2 rc $(rc) ACTION=$(val ACTION) ID=$(val ID)"
  fx comment_find "$N" "<!-- sonde:forge-api -->"
  [ "$(rc)" = 0 ] && [ "$(val ID)" = "${ID1:-x}" ] && ok "$K G.3 comment_find (marqueur posé) ⇒ le MÊME ID=$ID1, lecture seule" || ko "$K G.3 rc $(rc) ID=$(val ID) $(cause)"
  fx comment_find "$N" "<!-- sonde:inconnue-$$ -->"
  [ "$(rc)" = 0 ] && [ -z "$(val ID)" ] && ok "$K G.4 comment_find (marqueur inconnu) ⇒ ID vide, rc 0 (« aucun » n'est pas une panne)" || ko "$K G.4 rc $(rc) ID=$(val ID) $(cause)"
  # La lignée : la sonde est OUVERTE, jamais mergée — le verbe parle le bon
  # chemin (state=merged / closed+merged) et rend ZÉRO ligne, rc 0 (pas une cause).
  fx pr_list_merged "$SONDE"
  [ "$(rc)" = 0 ] && [ ! -s "$TMP/out" ] && ok "$K B.2 pr_list_merged sur la sonde (ouverte, jamais mergée) ⇒ 0 ligne, rc 0" || ko "$K B.2 rc $(rc) : $(tr '\n' ' ' < "$TMP/out" | cut -c1-120) $(cause)"
  fx raw "$FILE" "$SONDE"
  [ "$(rc)" = 0 ] && grep -q "$SONDE" "$TMP/out" && ok "$K H.1 raw sur la branche de sonde ⇒ le contenu poussé" || ko "$K H.1 rc $(rc) : $(cause)"
  fx pr_get 999999
  [ "$(rc)" = 2 ] && grep -q '404' "$TMP/err" && ok "$K D.4 PR inconnue ⇒ rc 2, cause « 404 »" || ko "$K D.4 rc $(rc) : $(cause)"

  # ── nettoyage : fermer et supprimer la branche ──
  if [ "$K" = gitlab ]; then
    enc="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$R")"
    curl -s --max-time 20 -o /dev/null -H "PRIVATE-TOKEN: $S" -X PUT "$H/api/v4/projects/$enc/merge_requests/$N" -d state_event=close
  else
    curl -s --max-time 20 -o /dev/null -H "Authorization: token $S" -X PATCH -H 'Content-Type: application/json' "$H/api/v1/repos/$R/pulls/$N" -d '{"state":"closed"}'
  fi
  gitauth -C "$W" push -q origin --delete "$SONDE" 2>/dev/null && ok "$K Z.1 nettoyage : PR/MR $N fermée, branche $SONDE supprimée" || ko "$K Z.1 nettoyage incomplet (branche $SONDE à supprimer à la main)"
done

# ── LE DISCRIMINANT sur la forge RÉELLE ─────────────────────────────────────
echo "═══ J. le discriminant, contre le GitLab RÉEL ═══"
if [ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$GITLAB_URL/")" = 000 ] || [ -z "${GITLAB_LAB_TOKEN:-}" ]; then
  skip "J.1 GitLab injoignable ou sans PAT"
else
  K=gitea; H="$GITLAB_URL"; R="ci/stoa-labs"; S="$GITLAB_LAB_TOKEN"; A=token
  fx pr_find_open x
  [ "$(rc)" = 2 ] && grep -q '302' "$TMP/err" && grep -q '/users/sign_in' "$TMP/err" && ! grep -q 'Traceback' "$TMP/err" \
    && ok "J.1 FORGE_KIND=gitea contre le GitLab RÉEL ⇒ « 302 … /users/sign_in » — la panne du client, reproduite et NOMMÉE" \
    || ko "J.1 rc $(rc) : $(cause)"
fi

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d (%d sauté(s))\n' "$PASS" $((PASS + FAIL)) "$SKIP"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ] || exit 1
