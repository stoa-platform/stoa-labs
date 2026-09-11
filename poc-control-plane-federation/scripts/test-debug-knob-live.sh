#!/usr/bin/env bash
# test-debug-knob-live.sh — preuve PAR BUILDS RÉELS de la case DEBUG et de la
# globale STOA_DEBUG (L4), sur le Jenkins du lab. Se rend À LA MAIN, comme les
# autres suites -live ; jamais sous `make lint-ci`.
#
# Ce qu'elle prouve, et comment :
#   §0  prérequis : Jenkins joignable, gitea main porte L4 (le CI LIT gitea, pas
#       l'arbre local), le formulaire réel des huit jobs porte DEBUG au rang
#       attendu (la re-pose a eu lieu : XML re-posé, ou build d'amorçage).
#   §1  case cochée, globale absente ⇒ le build PARLE (`[dbg vault-login.sh]`
#       sur un login Vault volontairement refusé — aucun effet de bord), et le
#       mot de passe sentinelle n'apparaît nulle part dans la console.
#   §2  case décochée, globale absente ⇒ le build se TAIT (zéro `[dbg`).
#   §3  case décochée, globale STOA_DEBUG=1 ⇒ le build PARLE : la globale est
#       le PLANCHER, la case n'éteint rien. Puis la globale est retirée (vidée).
#   §4  (informatif) un job webhook-only lancé à vide, globale posée : ce que sa
#       console montre — la globale atteint tout build par construction, mais
#       un job qui refuse avant d'atteindre un script qui parle ne dira rien.
# Le job témoin est api-promote-export : son bloc sh source ci/lib/vault-login.sh
# AVANT le moteur, avec une identité nominative saisie ; un login refusé sur le
# userpass du lab ne verrouille rien et ne touche ni la forge ni la gateway.
#
#   JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 \
#     ./scripts/test-debug-knob-live.sh
# shellcheck disable=SC2015,SC2016
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO" || exit 2
JENKINS_UI="${JENKINS_UI:-http://localhost:18080}"
GITEA_URL="${GITEA_URL:-http://localhost:13000}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
SUBDIR="${GIT_SUBDIR:-poc-control-plane-federation}"
JOB="${L4_JOB:-api-promote-export}"
SENTINEL="L4-sentinelle-$(date +%s)-7f3a"          # un mot de passe faux, reconnaissable, jamais réutilisé
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
die(){ echo "PREREQUIS : $*" >&2; exit 2; }
TMP=$(mktemp -d); G0=""; G0_LUE=0
# Le plancher est posé sur le Jenkins PARTAGÉ du lab : quoi qu'il arrive (die,
# TIMEOUT, Ctrl-C), la valeur d'origine est restaurée en sortie — vide comprise.
restaurer(){ [ "$G0_LUE" = 1 ] && poser_globale "$G0" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap restaurer EXIT
jq_(){ python3 -c "import sys,json; d=json.load(sys.stdin); $1"; }
jcrumb(){ curl -sf -c "$1" "$JENKINS_UI/crumbIssuer/api/json" | jq_ 'print(d["crumbRequestField"]+": "+d["crumb"])'; }
raw_at(){ curl -sf "$GITEA_URL/$GIT_REPO/raw/branch/$1/$2"; }
params_of(){ curl -sg "$JENKINS_UI/job/$1/api/json?tree=property[parameterDefinitions[name]]" | jq_ "print(' '.join(p['name'] for pr in d.get('property',[]) for p in pr.get('parameterDefinitions',[])))"; }
next_build(){ curl -sg "$JENKINS_UI/job/$1/api/json?tree=nextBuildNumber" | jq_ 'print(d["nextBuildNumber"])'; }
# attend la fin du build N du job J (borné), rend son résultat
wait_build(){ local j="$1" n="$2" i=0 r
  while [ $i -lt "${L4_WAIT:-120}" ]; do
    r=$(curl -sg "$JENKINS_UI/job/$j/$n/api/json?tree=building,result" 2>/dev/null | jq_ 'print("building" if d.get("building") else (d.get("result") or "building"))' 2>/dev/null || echo absent)
    case "$r" in building|absent) sleep 3; i=$((i+1));; *) echo "$r"; return 0;; esac
  done; echo TIMEOUT; }
# lance le témoin avec la case à $1 ; imprime le numéro du build
lancer(){ local debug="$1" jar="$TMP/jar.$RANDOM" cr n hc
  cr=$(jcrumb "$jar") || die "crumb CSRF indisponible"
  n=$(next_build "$JOB")
  lancer_data
  hc=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -H "$cr" -X POST "$JENKINS_UI/job/$JOB/buildWithParameters" \
        --data-urlencode "TEAM=l4-debug-proof" --data-urlencode "API_NAME=aucune-api" \
        --data-urlencode "DEBUG=$debug" --data-urlencode "VAULT_USER=l4-nobody" --data-urlencode "V_PASS@$TMP/vpass")
  [ "$hc" = 201 ] || die "buildWithParameters $JOB DEBUG=$debug : HTTP $hc"
  echo "$n"; }
console(){ curl -s "$JENKINS_UI/job/$1/$2/consoleText"; }
poser_globale(){ JENKINS_UI="$JENKINS_UI" bash scripts/setup-jenkins-globals.sh "STOA_DEBUG=$1" >"$TMP/pose.log" 2>&1 || { cat "$TMP/pose.log"; die "pose de STOA_DEBUG=$1 refusée"; }; }
# la VALEUR seule ('' = absente OU vide : mêmes états pour Jenkins) ; classes POSIX (BSD et GNU sed)
lire_globale(){ JENKINS_UI="$JENKINS_UI" bash scripts/setup-jenkins-globals.sh --print 2>/dev/null | sed -n 's/^[[:space:]]*STOA_DEBUG=//p' | head -1; }
# le mot de passe sentinelle ne passe JAMAIS en argv (ps le verrait) : curl le lit dans un fichier 0600
lancer_data(){ umask 077; printf '%s' "$SENTINEL" > "$TMP/vpass"; }

echo "== 0. prérequis : Jenkins, gitea main porte L4, les huit formulaires réels =="
curl -sf "$JENKINS_UI/api/json" >/dev/null || die "Jenkins injoignable : $JENKINS_UI"
raw_at main "$SUBDIR/ci/Jenkinsfile.$JOB" | grep -q 'then export STOA_DEBUG=1; fi' || die "gitea main ne porte pas L4 (Jenkinsfile.$JOB sans pont) — pousser gitea d'abord : le CI LIT gitea"
ok "0.1 Jenkins joignable et gitea main porte le pont DEBUG ⇒ STOA_DEBUG"
# la table = celle de test-debug-knob-wiring.sh (job local | job Jenkins | rang attendu)
FORMS="api-promote-export|api-promote-export|TEAM API_NAME DEBUG VAULT_USER V_PASS
api-promote-request|api-promote-request|TEAM API_NAME FROM_ENV TO_ENV MESSAGE CHANGE_REF PV_REF ARCHIVE_SHA256 DEBUG
api-request|api-request|ACTION TEAM API_NAME API_VERSION API_BASE NEW_VERSION OPENAPI_SPEC INBOUND_MODE CLASSIFICATION EXPOSURE DEBUG
app-request|app-request|APP REQ_ENV TEAM API CLIENT_ID MODE IP_ALLOWLIST CERT_PEM CERT_ROTATION BACKEND_KEY_REF BACKEND_KEY_FIELD DEBUG FORGE_TOKEN CHANGE_REF PV_REF
app-rollback|app-rollback|APP ENV REASON CHANGE_REF DEBUG FORGE_TOKEN
team-request|team-request|TEAM DESCRIPTION APPROVERS REPO DEBUG
prod|stoa-prod-deploy|PROMOTION_ID DEBUG VAULT_USER VAULT_USER_PASSWORD
rollback|stoa-prod-rollback|PROMOTION_ID REASON CHANGE_REF DEBUG VAULT_USER VAULT_USER_PASSWORD"
while IFS='|' read -r LOCAL JJOB EXPECT; do
  GOT=$(params_of "$JJOB")
  [ "$GOT" = "$EXPECT" ] && ok "0.2 $JJOB : formulaire réel = $EXPECT" || ko "0.2 $JJOB : formulaire réel '$GOT' ≠ attendu '$EXPECT' — re-poser ($LOCAL : XML via setup-team-onboard-jobs.sh, ou build d'amorçage)"
done <<< "$FORMS"

G0=$(lire_globale); G0_LUE=1
[ -z "$G0" ] || { echo "  (globale posée avant la suite : STOA_DEBUG=$G0 — vidée pour la preuve, restaurée en sortie)"; poser_globale ""; }

echo
echo "== 1. case cochée, globale absente ⇒ le build parle, sans fuite =="
N1=$(lancer true); R1=$(wait_build "$JOB" "$N1"); console "$JOB" "$N1" > "$TMP/c1"
# Le refus attendu est DISCERNABLE : FAILURE + le marqueur que vault-login.sh
# imprime HORS debug (« ✗ <mount>/login REFUSÉ (HTTP … ) ») — pas « tout sauf TIMEOUT ».
[ "$R1" = FAILURE ] && grep -q 'login REFUSÉ (HTTP' "$TMP/c1" && ok "1.1 build #$N1 : FAILURE au login Vault refusé (l'identité l4-nobody n'existe pas) — le chemin attendu, pas un autre rouge" || ko "1.1 build #$N1 : $R1, marqueur de refus de login : $(grep -c 'login REFUSÉ (HTTP' "$TMP/c1")"
grep -q '\[dbg ' "$TMP/c1" && ok "1.2 build #$N1 : lignes [dbg présentes ($(grep -c '\[dbg ' "$TMP/c1") lignes)" || ko "1.2 build #$N1 : aucune ligne [dbg — le pont n'a pas exporté STOA_DEBUG"
# Le préfixe [dbg <nom>] est le $0 du STEP (dbg.sh : DBG_NAME sinon ${0##*/}), jamais
# « vault-login.sh » pour une lib sourcée : on reconnaît vault_login_nominative à son CONTENU.
grep -qE '^\[dbg [^]]+\] voie A \(user/pwd\) : mount=' "$TMP/c1" && ok "1.3 build #$N1 : vault_login_nominative parle ($(grep -m1 -E '^\[dbg [^]]+\] voie A' "$TMP/c1" | cut -c1-100)…)" || ko "1.3 build #$N1 : aucune ligne « voie A (user/pwd) » — vault-login.sh muet, ou le préfixe/le contenu ont changé (relire dbg.sh)"
grep -qE '^\[dbg [^]]+\] POST [^ ]+/login/[^ ]+ -> HTTP [0-9]{3}' "$TMP/c1" && ok "1.3b build #$N1 : la ligne HTTP du login refusé est là ($(grep -m1 -E 'POST [^ ]+/login/[^ ]+ -> HTTP' "$TMP/c1" | sed -E 's/^.*(POST [^ ]+ -> HTTP [0-9]{3}).*/\1/'))" || ko "1.3b build #$N1 : pas de ligne POST …/login -> HTTP"
grep -qF "$SENTINEL" "$TMP/c1" && ko "1.4 build #$N1 : LE MOT DE PASSE SENTINELLE EST DANS LA CONSOLE" || ok "1.4 build #$N1 : le mot de passe sentinelle n'apparaît pas dans la console (ni en clair, ni en trace shell)"
grep -qE '^\+ .*(V_PASS|VAULT_USER_PASSWORD)=' "$TMP/c1" && ko "1.5 build #$N1 : une trace shell (+) affecte le mot de passe" || ok "1.5 build #$N1 : aucune trace shell du mot de passe (set +x précède le pont)"

echo
echo "== 2. case décochée, globale absente ⇒ le build se tait =="
N2=$(lancer false); R2=$(wait_build "$JOB" "$N2"); console "$JOB" "$N2" > "$TMP/c2"
[ "$R2" = FAILURE ] && grep -q 'login REFUSÉ (HTTP' "$TMP/c2" && ok "2.1 build #$N2 : FAILURE au login Vault refusé (même chemin que #$N1)" || ko "2.1 build #$N2 : $R2, marqueur de refus : $(grep -c 'login REFUSÉ (HTTP' "$TMP/c2")"
grep -q '\[dbg ' "$TMP/c2" && ko "2.2 build #$N2 : des lignes [dbg sortent sans case ni globale ($(grep -c '\[dbg ' "$TMP/c2"))" || ok "2.2 build #$N2 : zéro ligne [dbg (opt-in respecté)"

echo
echo "== 3. case décochée, globale STOA_DEBUG=1 ⇒ le plancher parle =="
poser_globale 1; G1=$(lire_globale)
[ "$G1" = "1" ] && ok "3.1 globale posée et relue : STOA_DEBUG=1" || ko "3.1 globale relue : 'STOA_DEBUG=$G1'"
N3=$(lancer false); R3=$(wait_build "$JOB" "$N3"); console "$JOB" "$N3" > "$TMP/c3"
[ "$R3" = FAILURE ] && grep -q 'login REFUSÉ (HTTP' "$TMP/c3" && ok "3.2 build #$N3 : FAILURE au login Vault refusé (même chemin)" || ko "3.2 build #$N3 : $R3, marqueur de refus : $(grep -c 'login REFUSÉ (HTTP' "$TMP/c3")"
grep -qE '^\[dbg [^]]+\] voie A \(user/pwd\) : mount=' "$TMP/c3" && ok "3.3 build #$N3 : case décochée mais globale posée ⇒ vault_login_nominative parle (le plancher tient, la case n'éteint rien)" || ko "3.3 build #$N3 : aucune ligne « voie A » malgré la globale — soit le Jenkinsfile éteint STOA_DEBUG, soit la globale n'atteint pas le build, soit le contenu a changé"
grep -qF "$SENTINEL" "$TMP/c3" && ko "3.4 build #$N3 : sentinelle dans la console" || ok "3.4 build #$N3 : sentinelle absente"

echo
echo "== 4. (informatif) un job webhook-only lancé à vide sous la globale =="
JAR="$TMP/jar.w"; CR=$(jcrumb "$JAR"); NW=$(next_build provisioning-request)
HC=$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -H "$CR" -X POST "$JENKINS_UI/job/provisioning-request/build")
if [ "$HC" = 201 ]; then RW=$(wait_build provisioning-request "$NW"); console provisioning-request "$NW" > "$TMP/c4"
  echo "  ℹ provisioning-request #$NW : $RW ; lignes [dbg : $(grep -c '\[dbg ' "$TMP/c4") ; première : $(grep -m1 '\[dbg ' "$TMP/c4" | cut -c1-110)"
else echo "  ℹ provisioning-request : build refusé (HTTP $HC) — pas de conclusion"; fi

poser_globale "$G0"; G2=$(lire_globale)
[ "$G2" = "$G0" ] && ok "3.5 globale restaurée à sa valeur d'origine après la preuve (STOA_DEBUG='$G0')" || ko "3.5 globale relue 'STOA_DEBUG=$G2', attendu '$G0'"

echo
echo "RÉSULTAT : $PASS/$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
