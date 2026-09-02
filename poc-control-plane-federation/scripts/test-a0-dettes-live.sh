#!/usr/bin/env bash
# test-a0-dettes-live.sh — la PORTE et les CONTRE-ÉPREUVES de la dette 1 d'A0
# (statut de build sur provision-plan, forge relue AVANT le verdict), par
# BUILDS RÉELS sur le lab : Jenkins + Gitea (aucune gateway).
#
#   PORTE : une demande machine ⇒ PR A ⇒ provision-plan (hook Gitea) SUCCESS :
#     la console porte la relecture de la forge ([0/4] … PR #A ouverte), la PR
#     porte le verdict (marqueur provision-plan) et AUCUN statut (SUCCESS + ok
#     ⇒ COMMENT_SKIPPED : pas de troisième commentaire).
#   CONTRE-ÉPREUVE 1 (le bloquant de la critique) : webhook stoa-provision-plan
#     FORGÉ — branche RÉELLE de la PR A + numéro de la PR B ⇒ build FAILURE
#     FORGE_NON_CONFIRMEE nommant la vraie tête de B, comptes de commentaires
#     de A ET de B inchangés (ni verdict ni statut sur une PR seulement nommée).
#   CONTRE-ÉPREUVE 2 : branche INEXISTANTE + numéro de A ⇒ FAILURE
#     FORGE_NON_CONFIRMEE, A inchangée (avant : vert par IGNORE, diff vide).
#   CONTRE-ÉPREUVE 3 (économie d'exécuteur) : branche hors provision/* ⇒ build
#     vert « hors provision/* », le post n'alloue aucun nœud (message de garde).
#
# FAIL-CLOSED, jamais de skip muet. Objets JETABLES a0dA<ts>/a0dB<ts> : PR
# fermées et branches supprimées en fin de suite (rien n'atteint main).
#
#   JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 bash scripts/test-a0-dettes-live.sh
set -uo pipefail
set +x
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO" || exit 1
JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis}"; GITEA_URL="${GITEA_URL:?GITEA_URL requis}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"; GITEA_CONTAINER="${GITEA_CONTAINER:-poc-gitea}"; PFX="poc-control-plane-federation"
TS="$(date +%s)"; TMP="$(mktemp -d /tmp/a0d-live.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
die(){ printf '\n%s\n' "$*" >&2; exit 1; }
jq_(){ python3 -c "import sys,json; d=json.load(sys.stdin); $1"; }
jnext(){ curl -sfg "$JENKINS_UI/job/$1/api/json?tree=nextBuildNumber" | jq_ 'print(d["nextBuildNumber"])'; }
jresult(){ curl -sg "$JENKINS_UI/job/$1/$2/api/json?tree=result,building" 2>/dev/null | jq_ 'print("building" if d.get("building") else (d.get("result") or ""))' 2>/dev/null || true; }
jname(){ curl -sg "$JENKINS_UI/job/$1/$2/api/json?tree=displayName" 2>/dev/null | jq_ 'print(d.get("displayName",""))' 2>/dev/null || true; }
wait_build(){ local i r; for i in $(seq 1 "$(( $3 / 3 ))"); do r=$(jresult "$1" "$2"); [ -n "$r" ] && [ "$r" != "building" ] && { printf '%s' "$r"; return 0; }; sleep 3; done; printf '%s' "$(jresult "$1" "$2")"; return 1; }
GITEA_TOKEN=""
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then GITEA_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect "$GITEA_CONTAINER" >/dev/null 2>&1; then
  GITEA_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username ci --token-name "a0d-live-$TS" --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
[ -n "$GITEA_TOKEN" ] || die "LAB_ABSENT : aucun token Gitea"
gapi(){ curl -s -H "Authorization: token $GITEA_TOKEN" "$@"; }
pr_by_head(){ gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls?state=open&limit=50" | jq_ "
for p in d:
    if p['head']['ref'] == '$1': print(p['number']); break"; }
comments(){ gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/issues/$1/comments?limit=50" | jq_ 'print("\n".join(c["body"] for c in d))'; }
ncomments(){ gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/issues/$1/comments?limit=50" | jq_ 'print(len(d))'; }
close_pr(){ gapi -X PATCH -H 'Content-Type: application/json' -d '{"state":"closed"}' "$GITEA_URL/api/v1/repos/$GIT_REPO/pulls/$1" -o /dev/null -w '%{http_code}'; }
del_branch(){ gapi -X DELETE "$GITEA_URL/api/v1/repos/$GIT_REPO/branches/$1" -o /dev/null -w '%{http_code}'; }
wait_plan(){ local i n; for i in $(seq 1 "$(( $4 / 3 ))"); do
    n=$(curl -sg "$JENKINS_UI/job/provision-plan/api/json?tree=builds[number,displayName]{0,15}" | jq_ "
for b in d['builds']:
    if b['number'] >= $3 and b.get('displayName') == 'plan $1/dev (PR #$2)': print(b['number']); break")
    [ -n "$n" ] && { printf '%s' "$n"; return 0; }; sleep 3; done; return 1; }
wait_comment(){ local i; for i in $(seq 1 "$(( $3 / 3 ))"); do comments "$1" 2>/dev/null | grep -qF -- "$2" && return 0; sleep 3; done; return 1; }
machine_request(){ # $1=app → PR number (attend la PR)
  local n hc pr; n=$(jnext provisioning-request)
  printf '{"app":"%s","env":"dev","clientId":"%s-dev","api":"%s","apiVersion":"%s","audience":"%s","caller":"oig-provisioner"}' "$1" "$1" "$API_NAME" "$API_VER" "$API_NAME" > "$TMP/wh-$1.json"
  hc=$(curl -s -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/wh-$1.json" "$JENKINS_UI/generic-webhook-trigger/invoke?token=stoa-provision-request" -o /dev/null -w '%{http_code}')
  [ "$hc" = 200 ] || { echo "webhook demande $1 : HTTP $hc" >&2; return 1; }
  [ "$(wait_build provisioning-request "$n" 300)" = SUCCESS ] || { echo "provisioning-request #$n pas SUCCESS" >&2; return 1; }
  pr=""; for _ in $(seq 1 20); do pr=$(pr_by_head "provision/$1-dev"); [ -n "$pr" ] && break; sleep 3; done
  [ -n "$pr" ] || return 1; printf '%s' "$pr"
}
forge_plan(){ # $1=PR_BRANCH $2=PR_NUMBER → numéro de build provision-plan (attendu FINI)
  local n hc; n=$(jnext provision-plan)
  printf '{"action":"opened","pull_request":{"number":%s,"head":{"ref":"%s"}}}' "$2" "$1" > "$TMP/forge.json"
  hc=$(curl -s -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/forge.json" "$JENKINS_UI/generic-webhook-trigger/invoke?token=stoa-provision-plan" -o "$TMP/forge.out" -w '%{http_code}')
  [ "$hc" = 200 ] && grep -q '"triggered":true' "$TMP/forge.out" || { echo "webhook forgé : HTTP $hc $(head -c 200 "$TMP/forge.out")" >&2; return 1; }
  wait_build provision-plan "$n" 300 >/dev/null; printf '%s' "$n"
}

echo "== 0. préflights =="
curl -sf "$JENKINS_UI/crumbIssuer/api/json" >/dev/null || die "LAB_ABSENT : Jenkins"
for F in scripts/lib/gitea-pr-confirm.sh scripts/provision-plan-status.sh; do
  [ "$(gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/contents/$PFX/$F?ref=main" -o /dev/null -w '%{http_code}')" = 200 ] || die "PREREQUIS : $F absent de gitea main — git push gitea HEAD:main"
done
gapi "$GITEA_URL/api/v1/repos/$GIT_REPO/raw/main/$PFX/ci/Jenkinsfile.provision-plan" | grep -q 'provision-plan-status.sh' || die "PREREQUIS : Jenkinsfile.provision-plan sur gitea main sans statut de build"
API_CHOICE=$(curl -sg "$JENKINS_UI/job/app-request/api/json?tree=property[parameterDefinitions[name,choices]]" | jq_ '
c=[p.get("choices") for pr in d.get("property",[]) for p in pr.get("parameterDefinitions",[]) if p["name"]=="API"]
print(c[0][0] if c and c[0] else "")')
[ -n "$API_CHOICE" ] || die "PREREQUIS : app-request sans liste API (amorcer le formulaire)"
API_NAME="${API_CHOICE%%@*}"; API_VER="${API_CHOICE#*@}"
ok "lab joignable, A0 dettes sur gitea main, API de test $API_CHOICE"

echo
echo "== 1. PORTE : demande machine ⇒ PR A ⇒ plan (forge relue) ⇒ verdict, et AUCUN statut en SUCCESS =="
APP_A="a0da$TS"; N_PLAN0=$(jnext provision-plan)
PR_A=$(machine_request "$APP_A") && ok "PR A provision/$APP_A-dev ouverte (#$PR_A)" || die "PREREQUIS : la voie machine n'a pas ouvert la PR A"
NP_A=$(wait_plan "$APP_A" "$PR_A" "$N_PLAN0" 240); [ -n "$NP_A" ] && R=$(wait_build provision-plan "$NP_A" 300) && [ "$R" = SUCCESS ] && ok "provision-plan #$NP_A (hook) : SUCCESS" || ko "plan de A : build ${NP_A:-introuvable} ${R:-}"
curl -s "$JENKINS_UI/job/provision-plan/$NP_A/consoleText" > "$TMP/planA.log"
grep -q '\[0/4\] relecture de la PR' "$TMP/planA.log" && grep -q "forge : PR #$PR_A ouverte, tete provision/$APP_A-dev @" "$TMP/planA.log" && ok "console : la forge a été relue AVANT le clone (tête et SHA nommés)" || ko "console sans relecture de la forge"
grep -q 'faits du plan : tete=' "$TMP/planA.log" && grep -q "verdict='ok'" "$TMP/planA.log" && ok "post de stage : faits chargés dans env (verdict=ok)" || ko "faits du plan non chargés"
wait_comment "$PR_A" '<!-- provision-plan -->' 60 && ok "PR A : verdict posé (marqueur provision-plan)" || ko "PR A sans verdict"
comments "$PR_A" | grep -q '<!-- provision-plan-build -->' && ko "PR A : un STATUT a été posé en SUCCESS+ok (troisième commentaire redondant)" || ok "PR A : AUCUN statut en SUCCESS+ok (COMMENT_SKIPPED — le verdict suffit)"
grep -q 'COMMENT_SKIPPED' "$TMP/planA.log" && ok "console : COMMENT_SKIPPED (le statut a bien tourné, et s'est tu)" || ko "console sans COMMENT_SKIPPED"
NA0=$(ncomments "$PR_A")

echo
echo "== 2. PR B (deuxième demande machine, la PR « étrangère ») =="
APP_B="a0db$TS"; N_PLAN1=$(jnext provision-plan)
PR_B=$(machine_request "$APP_B") && ok "PR B provision/$APP_B-dev ouverte (#$PR_B)" || die "PREREQUIS : la voie machine n'a pas ouvert la PR B"
NP_B=$(wait_plan "$APP_B" "$PR_B" "$N_PLAN1" 240); [ -n "$NP_B" ] && wait_build provision-plan "$NP_B" 300 >/dev/null
wait_comment "$PR_B" '<!-- provision-plan -->' 60 && ok "PR B : verdict posé" || ko "PR B sans verdict"
NB0=$(ncomments "$PR_B")

echo
echo "== 3. CONTRE-ÉPREUVE 1 : webhook forgé — branche RÉELLE de A + numéro de B =="
N1=$(forge_plan "provision/$APP_A-dev" "$PR_B") || ko "webhook forgé non accepté"
R=$(jresult provision-plan "$N1")
[ "$R" = FAILURE ] && ok "provision-plan #$N1 : FAILURE (refus fermé)" || ko "provision-plan #$N1 : ${R:-?} (attendu FAILURE)"
curl -s "$JENKINS_UI/job/provision-plan/$N1/consoleText" > "$TMP/forge1.log"
grep -q 'REFUS: FORGE_NON_CONFIRMEE' "$TMP/forge1.log" && grep -q "tete de la PR #$PR_B = 'provision/$APP_B-dev', le payload nommait 'provision/$APP_A-dev'" "$TMP/forge1.log" \
  && ok "console : FORGE_NON_CONFIRMEE nommant la VRAIE tête de B et la branche prétendue" || ko "console sans refus nommé"
grep -q 'aucun commentaire, aucun clone' "$TMP/forge1.log" && ! grep -q '\[1/4\] checkout' "$TMP/forge1.log" && ok "aucun clone tenté après le refus" || ko "un clone a été tenté"
grep -q "n'a pas obtenu la confirmation de la forge" "$TMP/forge1.log" && ok "statut : « la forge n'a pas confirmé » ⇒ rien posé" || ko "le statut n'a pas décliné"
[ "$(ncomments "$PR_B")" = "$NB0" ] && ok "PR B : nombre de commentaires INCHANGÉ ($NB0) — ni verdict ni statut sur une PR seulement nommée" || ko "PR B a reçu un commentaire ($NB0 → $(ncomments "$PR_B"))"
[ "$(ncomments "$PR_A")" = "$NA0" ] && ok "PR A : inchangée ($NA0)" || ko "PR A a reçu un commentaire"

echo
echo "== 4. CONTRE-ÉPREUVE 2 : branche INEXISTANTE + numéro de A =="
N2=$(forge_plan "provision/inexistante$TS-dev" "$PR_A") || ko "webhook forgé non accepté"
R=$(jresult provision-plan "$N2")
[ "$R" = FAILURE ] && ok "provision-plan #$N2 : FAILURE (avant A0 dettes : vert par IGNORE, diff vide)" || ko "provision-plan #$N2 : ${R:-?}"
curl -s "$JENKINS_UI/job/provision-plan/$N2/consoleText" | grep -q 'REFUS: FORGE_NON_CONFIRMEE' && ok "console : FORGE_NON_CONFIRMEE (la PR #$PR_A n'a pas cette tête)" || ko "refus non nommé"
[ "$(ncomments "$PR_A")" = "$NA0" ] && ok "PR A : inchangée ($NA0)" || ko "PR A a reçu un commentaire"

echo
echo "== 5. CONTRE-ÉPREUVE 3 : branche hors provision/* ⇒ vert sans nœud, aucun statut =="
N3=$(forge_plan "onboard/x$TS" "$PR_A") || ko "webhook forgé non accepté"
R=$(jresult provision-plan "$N3")
[ "$R" = SUCCESS ] && [ "$(jname provision-plan "$N3")" = "hors provision/* (PR #$PR_A)" ] && ok "provision-plan #$N3 : SUCCESS « hors provision/* (PR #$PR_A) »" || ko "provision-plan #$N3 : ${R:-?} / $(jname provision-plan "$N3")"
curl -s "$JENKINS_UI/job/provision-plan/$N3/consoleText" > "$TMP/forge3.log"
grep -q 'aucun statut a commenter, aucun executeur alloue' "$TMP/forge3.log" && ! grep -q 'provision-plan-status.sh' "$TMP/forge3.log" && ok "post : garde Groovy avant tout nœud — aucun exécuteur, script de statut jamais lancé" || ko "le post a alloué un nœud pour une PR étrangère"
[ "$(ncomments "$PR_A")" = "$NA0" ] && ok "PR A : inchangée ($NA0)" || ko "PR A a reçu un commentaire"

echo
echo "== 6. nettoyage =="
for PR in ${PR_A:-} ${PR_B:-}; do echo "  PR #$PR fermée (HTTP $(close_pr "$PR"))"; done
for B in "provision/$APP_A-dev" "provision/$APP_B-dev"; do echo "  branche $B : suppression HTTP $(del_branch "$B")"; done
rm -rf "$TMP"
echo; echo "======================================================================"; printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
