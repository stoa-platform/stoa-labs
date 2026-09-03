#!/usr/bin/env bash
# test-provision-apply-a2-live.sh — la PORTE et la CONTRE-ÉPREUVE d'A2 (GOAL
# cd-applications), par BUILDS RÉELS sur le lab : Gitea + Jenkins + Vault + la
# 10.15 réelle.
#
#   PORTE : merger provision/<app>-rec (par alice), pousser un autre commit sur
#     `main` AVANT de répondre à la pause ⇒ l'apply projette le SHA MERGÉ, pas
#     HEAD — prouvé par le log de l'aval (APPLIED_SHA), le commentaire de PR
#     (SHA + digest du bloc mergé, ≠ digest de HEAD) et l'ÉTAT DE LA GATEWAY
#     relu (identifier ipAddressRange = l'IP du bloc mergé, pas celle de HEAD).
#   CONTRE-ÉPREUVE 1 : webhook forgé (merged:true) sur une PR JAMAIS mergée ⇒
#     build FAILURE `PAYLOAD_PERIME`, jamais en pause, aval jamais lancé
#     (compte de builds inchangé), aucune application sur la gateway, PR commentée.
#   CONTRE-ÉPREUVE 2 : rejeu du webhook RÉEL de la porte, après que main a dépassé
#     le palier ⇒ FAILURE `PALIER_SUPPLANTE`, jamais en pause, gateway inchangée,
#     le ✅ de l'apply réel intact sur la PR (marqueurs distincts).
#
# ── FAIL-CLOSED, JAMAIS DE SKIP MUET ────────────────────────────────────────
# Prérequis manquant ⇒ exit 1 `LAB_ABSENT : <détail>` ou `PREREQUIS : <détail>`.
# Une porte live qui « se saute toute seule » rend vert : jamais ici.
#
# ── CE QUE CE SCRIPT ÉCRIT DANS LE LAB, ET CE QU'IL REMET ────────────────────
# Le lab est PARTAGÉ. Ce script :
#   - crée le compte Gitea `alice` (collaboratrice `write` de ci/stoa-labs) s'il
#     n'existe pas — LAISSÉ EN PLACE (comme `oscar`, posé par le harnais
#     d'onboarding) : c'est l'identité tenant (Vault deploy-banking-demo) ;
#   - ouvre deux PR provision/* pour des applications JETABLES a2p<ts>/a2q<ts>,
#     MERGE la première sur `main` (c'est la porte : un vrai merge, un vrai
#     webhook), pousse un commit sur `main` (le déplacement de HEAD), puis
#     RETIRE le manifeste jetable de `main` en fin de suite ;
#   - laisse le build provision-apply appliquer a2p sur la gateway réelle, puis
#     SUPPRIME l'application jetable (best-effort) ;
#   - ne draine JAMAIS une pause provision-apply qui n'est pas la sienne (numéro
#     de PR extrait du displayName « apply <app>/<env> (PR #n) »).
#
# Entrées (env) — OBLIGATOIRES, sans défaut vers un système en service :
#   JENKINS_UI      ex. http://localhost:18080 (ouvert, crumb seul)
#   GITEA_URL       ex. http://localhost:13000 (vu du poste)
#   GW_ADMIN        ex. http://localhost:5555/rest/apigateway (la 10.15 réelle, vue du poste)
#   WM_USER/WM_PASS compte admin de la gateway (lecture d'état + suppression de l'app jetable)
#   LAB_ALICE_PASS  mot de passe annuaire d'alice (Vault ldap/userpass — cf. .env.lab-users)
# Optionnelles :
#   GITEA_TOKEN_FILE   token `ci` (write:repository,write:issue) — sinon minté via `docker exec poc-gitea`
#   GITEA_CONTAINER    défaut poc-gitea ; GIT_REPO défaut ci/stoa-labs
#   EXPECT_ADMIN_VIA   défaut direct (la valeur globale Jenkins APPLY_ADMIN_VIA attendue sur CE lab)
#   REQ_API/REQ_API_VER l'API consommée (défaut demo-selfservice/1.0.0 — doit être ACTIVE sur la gateway)
#
#   set -a; . ./.env.lab-users; set +a
#   JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 \
#   GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage \
#     bash scripts/test-provision-apply-a2-live.sh
set -uo pipefail
set +x
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis (ex. http://localhost:18080)}"
GITEA_URL="${GITEA_URL:?GITEA_URL requis (ex. http://localhost:13000)}"
GW_ADMIN="${GW_ADMIN:?GW_ADMIN requis (ex. http://localhost:5555/rest/apigateway)}"
WM_USER="${WM_USER:?WM_USER requis}"
WM_PASS="${WM_PASS:?WM_PASS requis}"
LAB_ALICE_PASS="${LAB_ALICE_PASS:?LAB_ALICE_PASS requis (set -a; . ./.env.lab-users)}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GITEA_CONTAINER="${GITEA_CONTAINER:-poc-gitea}"
EXPECT_ADMIN_VIA="${EXPECT_ADMIN_VIA:-direct}"
REQ_API="${REQ_API:-demo-selfservice}"
REQ_API_VER="${REQ_API_VER:-1.0.0}"
MAN_DIR="poc-control-plane-federation/clients/provisioned/applications"

TS="$(date +%s)"
TMP="$(mktemp -d /tmp/pa-a2-live.XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
die(){ printf '\n%s\n' "$*" >&2; exit 1; }
# shellcheck source=scripts/lib/app-manifest.sh
. scripts/lib/app-manifest.sh || die "PREREQUIS : scripts/lib/app-manifest.sh introuvable"

APP_P="a2p$TS"; APP_Q="a2q$TS"
BR_P="provision/${APP_P}-rec"; BR_Q="provision/${APP_Q}-rec"
PR_P=""; PR_Q=""; MERGE_SHA=""; MAIN_BEFORE=""; APP_P_ID=""
CI_TOKEN=""; ALICE_TOKEN=""
API="$GITEA_URL/api/v1"

# ── helpers Gitea (token en EN-TÊTE via fichier, jamais en argv) ─────────────
gapi(){ curl -s -H @"$TMP/ci.hdr" -H 'Content-Type: application/json' "$@"; }
aapi(){ curl -s -H @"$TMP/alice.hdr" -H 'Content-Type: application/json' "$@"; }
jq_(){ python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
$1"; }
# ⚠ appelé dans un $( ) : une variable posée ICI meurt avec le sous-shell —
# le code HTTP passe par un FICHIER, relu par l'appelant (raw_hc).
raw_at(){ # $1=ref $2=path → stdout ; code HTTP dans $TMP/raw.hc
  gapi -o "$TMP/raw.out" -w '%{http_code}' "$API/repos/$GIT_REPO/raw/$1/$2" > "$TMP/raw.hc"; cat "$TMP/raw.out"
}
raw_hc(){ cat "$TMP/raw.hc" 2>/dev/null; }
pr_field(){ gapi "$API/repos/$GIT_REPO/pulls/$1" | jq_ "print(d$2)"; }
pr_comments(){ gapi "$API/repos/$GIT_REPO/issues/$1/comments" | jq_ "print('\n=====\n'.join(c.get('body','') for c in d))"; }
# ── helpers Jenkins (crumb + cookie du MÊME appel, sinon « Rejected ») ────────
jcrumb(){ # $1=jar → imprime "Field: Crumb"
  curl -sf -c "$1" "$JENKINS_UI/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])'
}
jstatus(){ curl -s "$JENKINS_UI/job/$1/$2/wfapi/describe" | jq_ "print(d.get('status',''))" 2>/dev/null || true; }
jresult(){ curl -s "$JENKINS_UI/job/$1/$2/api/json?tree=result,building,displayName" | jq_ "print(d.get('result') or ('BUILDING' if d.get('building') else ''))" 2>/dev/null || true; }
jnext(){ curl -sf "$JENKINS_UI/job/$1/api/json?tree=nextBuildNumber" | jq_ "print(d['nextBuildNumber'])"; }
jconsole(){ curl -s "$JENKINS_UI/job/$1/$2/consoleText"; }
jinput_id(){ curl -s "$JENKINS_UI/job/$1/$2/wfapi/pendingInputActions" | jq_ "print(d[0]['id'] if d else '')" 2>/dev/null || true; }
jabort_input(){ # $1=job $2=build
  local jar="$TMP/jar.abort.$2" cr iid; cr=$(jcrumb "$jar") || return 1; iid=$(jinput_id "$1" "$2")
  [ -n "$iid" ] && curl -s -b "$jar" -H "$cr" -X POST "$JENKINS_UI/job/$1/$2/input/$iid/abort" -o /dev/null
}
wait_until(){ # $1=secondes $2=job $3=build $4=état wfapi attendu (ou FINISHED = terminal)
  local deadline=$(( $(date +%s) + $1 )) st
  while [ "$(date +%s)" -lt "$deadline" ]; do
    st=$(jstatus "$2" "$3")
    case "$4:$st" in
      "FINISHED:SUCCESS"|"FINISHED:FAILED"|"FINISHED:ABORTED"|"FINISHED:UNSTABLE") printf '%s' "$st"; return 0 ;;
      "$4:$4") printf '%s' "$st"; return 0 ;;
      "PAUSED_PENDING_INPUT:SUCCESS"|"PAUSED_PENDING_INPUT:FAILED"|"PAUSED_PENDING_INPUT:ABORTED") printf '%s' "$st"; return 1 ;;
    esac
    sleep 3
  done
  printf '%s' "$(jstatus "$2" "$3")"; return 1
}
# ── helpers gateway (Basic via fichier -K, jamais en argv) ───────────────────
printf 'user = "%s:%s"\n' "$WM_USER" "$WM_PASS" > "$TMP/wm.cfg"; chmod 600 "$TMP/wm.cfg"
gw(){ curl -s -K "$TMP/wm.cfg" -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"; }
gw_app(){ # $1=nom → JSON de l'application (ou vide) ; tout code ≠ 200 = LAB_GATEWAY_ILLISIBLE (fail-closed)
  local hc
  hc=$(gw -o "$TMP/gw.apps" -w '%{http_code}' "$GW_ADMIN/applications")
  [ "$hc" = 200 ] || die "LAB_GATEWAY_ILLISIBLE : GET $GW_ADMIN/applications -> HTTP $hc (une absence d'application ne serait pas une preuve)"
  python3 -c "import json,sys
d=json.load(open('$TMP/gw.apps'))
for a in d.get('applications',[]):
    if a.get('name')=='$1': print(json.dumps(a)); break"
}
gw_app_ip(){ printf '%s' "$1" | python3 -c "import json,sys
a=json.load(sys.stdin)
for i in a.get('identifiers') or []:
    if i.get('key')=='ipAddressRange': print(','.join(i.get('value') or [])); break" 2>/dev/null; }

cleanup(){
  echo
  echo "── nettoyage ──"
  if [ -n "$CI_TOKEN" ]; then
    [ -n "$PR_Q" ] && gapi -X PATCH -d '{"state":"closed"}' -o /dev/null "$API/repos/$GIT_REPO/pulls/$PR_Q" && echo "  PR #$PR_Q fermée (jamais mergée)"
    for b in "$BR_P" "$BR_Q"; do gapi -X DELETE -o /dev/null "$API/repos/$GIT_REPO/branches/$b"; done
    # le manifeste jetable a2p est sur main (mergé par la porte) : retiré par l'API contents
    SHA_F=$(gapi "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP_P}.ansible.yml?ref=main" | jq_ "print(d.get('sha',''))" 2>/dev/null || true)
    if [ -n "$SHA_F" ]; then
      gapi -X DELETE -d "{\"branch\":\"main\",\"sha\":\"$SHA_F\",\"message\":\"test(a2-live): retrait du manifeste jetable ${APP_P} (porte A2 jouée)\"}" -o /dev/null "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP_P}.ansible.yml" \
        && echo "  manifeste jetable ${APP_P} retiré de main"
    fi
  fi
  if [ -n "$APP_P_ID" ]; then
    HC=$(gw -X DELETE -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications/$APP_P_ID"); echo "  application jetable ${APP_P} supprimée de la gateway (HTTP $HC, best-effort)"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "═══ 0. Préconditions (fail-closed) ═══"
curl -sf -o /dev/null "$JENKINS_UI/api/json" || die "LAB_ABSENT : Jenkins injoignable ($JENKINS_UI)"
curl -sf -o /dev/null "$GITEA_URL/api/v1/version" || die "LAB_ABSENT : Gitea injoignable ($GITEA_URL)"
HC=$(gw -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications"); [ "$HC" = 200 ] || die "LAB_ABSENT : gateway injoignable ou refus ($GW_ADMIN/applications -> $HC)"
ok "0.1 Jenkins, Gitea et la gateway répondent"

# token ci (fichier 0600 ou mint jetable)
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then CI_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect "$GITEA_CONTAINER" >/dev/null 2>&1; then
  CI_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username ci \
    --token-name "a2-live-ci-$TS" --scopes write:repository,write:issue,write:user,read:user,write:admin 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
[ -n "$CI_TOKEN" ] || die "LAB_ABSENT : aucun token Gitea ci (GITEA_TOKEN_FILE ou conteneur $GITEA_CONTAINER)"
printf 'Authorization: token %s\n' "$CI_TOKEN" > "$TMP/ci.hdr"; chmod 600 "$TMP/ci.hdr"
gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO" | grep -q '^200$' || die "LAB_ABSENT : $GIT_REPO illisible avec le token ci"
ok "0.2 token ci opérationnel sur $GIT_REPO"

# les jobs, tels que posés
CFG=$(curl -sf "$JENKINS_UI/job/provision-apply/config.xml") || die "LAB_ABSENT : job provision-apply absent"
printf '%s' "$CFG" | grep -q 'CpsScmFlowDefinition' && printf '%s' "$CFG" | grep -q 'ci/Jenkinsfile.provision-apply' \
  && ok "0.3 provision-apply est posé from SCM sur ci/Jenkinsfile.provision-apply" \
  || die "PREREQUIS : provision-apply n'est pas la coquille from SCM d'A2 — jouer JOBS=provision-apply scripts/setup-provision-jobs.sh"
printf '%s' "$CFG" | grep -q '<key>MERGE_SHA</key>' && ok "0.3b son déclencheur capte MERGE_SHA" || die "PREREQUIS : MERGE_SHA absent du déclencheur posé"
PARAMS=$(curl -sf "$JENKINS_UI/job/selfservice-app-deploy/api/json?tree=property%5BparameterDefinitions%5Bname%5D%5D" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(" ".join(p["name"] for pr in d.get("property",[]) for p in (pr.get("parameterDefinitions") or [])))')
for p in MERGE_SHA ADMIN_VIA ENVIRONMENT MANIFEST VAULT_USER VAULT_USER_PASSWORD; do
  case " $PARAMS " in *" $p "*) ;; *) die "PREREQUIS : PARAM_ABSENT — selfservice-app-deploy ne déclare pas $p (params : $PARAMS) : jouer scripts/setup-selfservice-job.sh (build d'amorçage)";; esac
done
ok "0.4 selfservice-app-deploy déclare MERGE_SHA (et ADMIN_VIA, ENVIRONMENT, MANIFEST, VAULT_USER…) — un build job: ne le retirera pas en silence"
JAR="$TMP/jar.sc"; CR=$(jcrumb "$JAR") || die "LAB_ABSENT : crumb Jenkins"
GLOBAL_VIA=$(curl -s -b "$JAR" -H "$CR" -X POST --data-urlencode 'script=import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty; def p=Jenkins.instance.globalNodeProperties.get(EnvironmentVariablesNodeProperty); println(p==null ? "" : (p.envVars.get("APPLY_ADMIN_VIA") ?: ""))' "$JENKINS_UI/scriptText" | tr -d '\r\n')
[ "$GLOBAL_VIA" = "$EXPECT_ADMIN_VIA" ] \
  && ok "0.5 APPLY_ADMIN_VIA global Jenkins = $GLOBAL_VIA (attendu $EXPECT_ADMIN_VIA sur ce lab)" \
  || die "PREREQUIS : APPLY_ADMIN_VIA global Jenkins = '${GLOBAL_VIA:-(absent)}' ≠ '$EXPECT_ADMIN_VIA' — poser la variable globale (script console) ou EXPECT_ADMIN_VIA"

# aucune pause provision-apply en cours (lab partagé : on ne draine rien qui ne soit à nous)
RUNNING=$(curl -s "$JENKINS_UI/job/provision-apply/api/json?tree=builds%5Bnumber,building,displayName%5D" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(" ".join("%s:%s" % (b["number"], (b.get("displayName") or "").replace(" ","_")) for b in d.get("builds",[]) if b.get("building")))')
[ -z "$RUNNING" ] && ok "0.6 aucun build provision-apply en cours (file libre)" \
  || die "PREREQUIS : build(s) provision-apply en cours — $RUNNING — pause d'autrui ou résidu : à solder par son propriétaire (disableConcurrentBuilds bloquerait la porte)"

# l'API consommée doit être ACTIVE sur la gateway (sinon l'apply échouerait pour une raison étrangère à A2)
gw "$GW_ADMIN/apis" | python3 -c "import json,sys
d=json.load(sys.stdin)
ok=any((i.get('api',i).get('apiName')=='$REQ_API' and i.get('api',i).get('apiVersion')=='$REQ_API_VER' and i.get('api',i).get('isActive') is True) for i in d.get('apiResponse',[]))
sys.exit(0 if ok else 1)" && ok "0.7 API consommée $REQ_API@$REQ_API_VER active sur la gateway" \
  || die "PREREQUIS : $REQ_API@$REQ_API_VER absente ou inactive sur la gateway (REQ_API/REQ_API_VER)"

# alice : Gitea (créée + collaboratrice write si absente) et Vault (lecture tenant)
HC=$(gapi -o /dev/null -w '%{http_code}' "$API/users/alice")
if [ "$HC" != 200 ]; then
  docker inspect "$GITEA_CONTAINER" >/dev/null 2>&1 || die "PREREQUIS : alice absente de Gitea et conteneur $GITEA_CONTAINER indisponible pour la créer"
  APW=$(python3 -c "import secrets,string;print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))")
  docker exec -u git "$GITEA_CONTAINER" gitea admin user create --username alice --password "$APW" --email alice@stoa.lab --must-change-password=false >/dev/null 2>&1 \
    || die "PREREQUIS : création du compte Gitea alice en échec"
  unset APW
  echo "  compte Gitea alice créé (mot de passe aléatoire non conservé : l'accès se fait par token)"
fi
HC=$(gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/collaborators/alice")
if [ "$HC" != 204 ]; then
  HC=$(gapi -X PUT -d '{"permission":"write"}' -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/collaborators/alice")
  { [ "$HC" = 204 ] || [ "$HC" = 200 ]; } || die "PREREQUIS : alice non ajoutée comme collaboratrice write de $GIT_REPO (HTTP $HC)"
  echo "  alice ajoutée collaboratrice write de $GIT_REPO"
fi
ALICE_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username alice \
  --token-name "a2-live-alice-$TS" --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
[ -n "$ALICE_TOKEN" ] || die "PREREQUIS : token Gitea d'alice non minté"
printf 'Authorization: token %s\n' "$ALICE_TOKEN" > "$TMP/alice.hdr"; chmod 600 "$TMP/alice.hdr"
ok "0.8 alice : compte Gitea + collaboratrice write + token (la mergeuse de la porte)"
VAULT_ADDR_LAB="${VAULT_ADDR_LAB:-http://localhost:8200}"
VPROBE=$(P="$LAB_ALICE_PASS" python3 - "$VAULT_ADDR_LAB" <<'PY'
import json, os, sys, urllib.request, urllib.error
va = sys.argv[1]
for mount in ("ldap", "userpass"):
    try:
        r = urllib.request.Request(f"{va}/v1/auth/{mount}/login/alice", data=json.dumps({"password": os.environ["P"]}).encode(), headers={"Content-Type": "application/json"})
        t = json.load(urllib.request.urlopen(r, timeout=10))["auth"]["client_token"]
        # A3 : l'aval lit le credential du PALIER (envs/rec/wm-admin) avec le token de
        # la pause — plus deploy/<tenant>/wm-admin. La précondition mesure donc le
        # ticket du palier rec (200) ET son refus sur int (403, la matrice sur
        # l'identité réelle) : sans le grant apply-rec, l'apply mourrait PALIER_FERME
        # pour une raison étrangère à A2.
        rr = urllib.request.Request(f"{va}/v1/secret/data/stoa/envs/rec/wm-admin", headers={"X-Vault-Token": t})
        urllib.request.urlopen(rr, timeout=10)
        try:
            urllib.request.urlopen(urllib.request.Request(f"{va}/v1/secret/data/stoa/envs/int/wm-admin", headers={"X-Vault-Token": t}), timeout=10)
            code_int = 200
        except urllib.error.HTTPError as e:
            code_int = e.code
        urllib.request.urlopen(urllib.request.Request(f"{va}/v1/auth/token/revoke-self", data=b"", headers={"X-Vault-Token": t}), timeout=10)
        if code_int != 403:
            print("FUITE " + mount); break
        print("OK " + mount); break
    except Exception as e:
        continue
else:
    print("KO")
PY
)
case "$VPROBE" in
  OK*) ok "0.9 alice se connecte à Vault (${VPROBE#OK }), lit envs/rec/wm-admin (200) et NE lit PAS envs/int/wm-admin (403) — le ticket du palier (A3) est ouvert pour l'identité de la pause";;
  FUITE*) die "PREREQUIS : alice lit envs/int/wm-admin (${VPROBE#FUITE }) — la rétention par palier est trouée sur ce lab, l'apply A2 ne prouverait rien de sain";;
  *) die "PREREQUIS : alice ne peut pas lire envs/rec/wm-admin via Vault ($VAULT_ADDR_LAB) — jouer DEPLOYERS_REC=alice bash scripts/setup-deployer-groups.sh (grant A3) ; sinon l'apply mourrait PALIER_FERME pour une raison étrangère à A2";;
esac

MAIN_BEFORE=$(gapi "$API/repos/$GIT_REPO/branches/main" | jq_ "print(d['commit']['id'])")
[ -n "$MAIN_BEFORE" ] || die "LAB_ABSENT : tête de main illisible"
[ -z "$(gw_app "$APP_P")" ] && [ -z "$(gw_app "$APP_Q")" ] && ok "0.10 aucune application jetable homonyme sur la gateway (main=$MAIN_BEFORE)" || die "PREREQUIS : application ${APP_P}/${APP_Q} déjà présente"

echo
echo "═══ 1. PORTE — merge de provision/${APP_P}-rec par alice, HEAD déplacé, apply au SHA mergé ═══"
N_PA=$(jnext provision-apply); N_SS=$(jnext selfservice-app-deploy)
OUT=$(GITEA_TOKEN="$CI_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" PROVISION_PLAN_INLINE=false \
      REQ_APP="$APP_P" REQ_ENV=rec REQ_API="$REQ_API" REQ_API_VER="$REQ_API_VER" REQ_CALLER=oig-provisioner \
      REQ_CLIENT_ID="${APP_P}-rec" REQ_IP_ALLOWLIST="10.42.0.1" bash scripts/provision-request.sh 2>&1); RC=$?
PR_P=$(printf '%s' "$OUT" | grep -oE 'PR_URL=[^ ]*/pulls/[0-9]+' | grep -oE '[0-9]+$' | tail -1)
[ "$RC" -eq 0 ] && [ -n "$PR_P" ] && ok "1.1 demande rec ${APP_P} ⇒ PR #$PR_P (auteur ci, ip_allowlist 10.42.0.1)" || die "PREREQUIS : demande rec en échec (rc=$RC) : $(printf '%s' "$OUT" | tail -5)"
MERGEABLE=false; DL=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$DL" ]; do MERGEABLE=$(pr_field "$PR_P" ".get('mergeable')"); [ "$MERGEABLE" = True ] && break; sleep 1; done
[ "$MERGEABLE" = True ] || die "PREREQUIS : PR #$PR_P non mergeable"
HC=$(aapi -X POST -d '{"Do":"merge"}' -o "$TMP/merge.out" -w '%{http_code}' "$API/repos/$GIT_REPO/pulls/$PR_P/merge")
[ "$HC" = 200 ] || die "PREREQUIS : merge par alice refusé (HTTP $HC) : $(head -c 300 "$TMP/merge.out")"
MERGE_SHA=$(pr_field "$PR_P" "['merge_commit_sha']"); MERGED_BY=$(pr_field "$PR_P" "['merged_by']['login']")
[ "$MERGED_BY" = alice ] && printf '%s' "$MERGE_SHA" | grep -Eq '^[0-9a-f]{40}$' \
  && ok "1.2 PR #$PR_P mergée par alice — MERGE_SHA=$MERGE_SHA" || die "PREREQUIS : merge incohérent (merged_by=$MERGED_BY sha=$MERGE_SHA)"

ST=$(wait_until 240 provision-apply "$N_PA" PAUSED_PENDING_INPUT); RCW=$?
DN=$(curl -s "$JENKINS_UI/job/provision-apply/$N_PA/api/json?tree=displayName" | jq_ "print(d.get('displayName',''))")
if [ "$RCW" -eq 0 ]; then ok "1.3 build provision-apply #$N_PA en PAUSE (réconciliation Gitea passée) — « $DN »"
else ko "1.3 build #$N_PA n'atteint pas la pause (état $ST) — $(jconsole provision-apply "$N_PA" | grep -E 'REFUS|ERROR|error' | tail -3 | tr '\n' ' ')"; fi
[ "$DN" = "apply ${APP_P}/rec (PR #$PR_P)" ] && ok "1.3b displayName = « apply ${APP_P}/rec (PR #$PR_P) » (format lu par ce harnais)" || ko "1.3b displayName inattendu : $DN"
jconsole provision-apply "$N_PA" > "$TMP/pa.console"
grep -q 'RECONCILE_OK' "$TMP/pa.console" && ok "1.3c RECONCILE_OK dans le log (Gitea a confirmé merged/SHA/head/base)" || ko "1.3c RECONCILE_OK absent"
grep -q "mergée par 'alice' (demandeur 'ci')" "$TMP/pa.console" && ok "1.3d identités réconciliées = alice / ci (relues sur la forge)" || ko "1.3d identités réconciliées absentes du log"

# ── déplacer HEAD : un commit sur main qui change per_env.rec AVANT de répondre ──
MERGED_MAN=$(raw_at "$MERGE_SHA" "$MAN_DIR/${APP_P}.ansible.yml"); [ "$(raw_hc)" = 200 ] || die "PREREQUIS : manifeste illisible au SHA mergé (HTTP $(raw_hc))"
printf '%s\n' "$MERGED_MAN" > "$TMP/merged.yml"
printf '%s\n' "$MERGED_MAN" | sed 's/"10\.42\.0\.1"/"10.42.0.2"/' > "$TMP/head.yml"
cmp -s "$TMP/merged.yml" "$TMP/head.yml" && die "PREREQUIS : la substitution d'IP n'a rien changé (forme du manifeste inattendue)"
SHA_F=$(gapi "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP_P}.ansible.yml?ref=main" | jq_ "print(d['sha'])")
B64=$(base64 < "$TMP/head.yml" | tr -d '\n')
HC=$(gapi -X PUT -d "{\"branch\":\"main\",\"sha\":\"$SHA_F\",\"content\":\"$B64\",\"message\":\"test(a2-live): HEAD bouge apres le merge de #$PR_P — per_env.rec de ${APP_P} passe a 10.42.0.2 (ne doit PAS etre projete)\"}" -o "$TMP/put.out" -w '%{http_code}' "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP_P}.ansible.yml")
NEW_SHA=$(jq_ "print(d['commit']['sha'])" < "$TMP/put.out" 2>/dev/null || true)
MAIN_MOVED=$(gapi "$API/repos/$GIT_REPO/branches/main" | jq_ "print(d['commit']['id'])")
{ [ "$HC" = 200 ] || [ "$HC" = 201 ]; } && [ -n "$NEW_SHA" ] && [ "$MAIN_MOVED" = "$NEW_SHA" ] && [ "$MAIN_MOVED" != "$MERGE_SHA" ] \
  && ok "1.4 HEAD de main déplacé APRÈS le merge et AVANT la réponse : commit $NEW_SHA = tête de main ≠ MERGE_SHA (per_env.rec y porte 10.42.0.2)" \
  || die "PREREQUIS : déplacement de HEAD non confirmé (HTTP $HC, commit=$NEW_SHA, main=$MAIN_MOVED, merge=$MERGE_SHA)"
HEAD_MAN=$(raw_at main "$MAN_DIR/${APP_P}.ansible.yml"); printf '%s\n' "$HEAD_MAN" > "$TMP/head.relu.yml"
D_MERGED=$(app_manifest_digest_env "$TMP/merged.yml" rec 2>/dev/null); D_HEAD=$(app_manifest_digest_env "$TMP/head.relu.yml" rec 2>/dev/null)
[ -n "$D_MERGED" ] && [ -n "$D_HEAD" ] && [ "$D_MERGED" != "$D_HEAD" ] \
  && ok "1.5 digests locaux : bloc mergé $D_MERGED ≠ bloc HEAD $D_HEAD (contrôle positif : la porte peut discriminer)" \
  || die "PREREQUIS : digests locaux non discriminants (mergé=$D_MERGED head=$D_HEAD)"

# ── répondre à la pause : V_USER=alice ──
IID=$(jinput_id provision-apply "$N_PA"); [ -n "$IID" ] || die "PREREQUIS : aucune pause à répondre sur #$N_PA"
JAR="$TMP/jar.in"; CR=$(jcrumb "$JAR") || die "LAB_ABSENT : crumb"
LAB_ALICE_PASS="$LAB_ALICE_PASS" python3 - > "$TMP/input.json" <<'PY'
import json, os
print(json.dumps({"parameter": [{"name": "V_USER", "value": "alice"}, {"name": "V_PASS", "value": os.environ["LAB_ALICE_PASS"]}]}))
PY
HC=$(curl -s -b "$JAR" -H "$CR" -X POST --data-urlencode json@"$TMP/input.json" "$JENKINS_UI/job/provision-apply/$N_PA/wfapi/inputSubmit?inputId=$IID" -o /dev/null -w '%{http_code}')
rm -f "$TMP/input.json"
{ [ "$HC" = 200 ] || [ "$HC" = 302 ]; } && ok "1.6 pause #$N_PA répondue par alice (HTTP $HC)" || die "PREREQUIS : réponse à la pause refusée (HTTP $HC)"
ST=$(wait_until 1500 provision-apply "$N_PA" FINISHED); RES=$(jresult provision-apply "$N_PA")
jconsole provision-apply "$N_PA" > "$TMP/pa.console"
[ "$RES" = SUCCESS ] && ok "1.7 build provision-apply #$N_PA : SUCCESS" || ko "1.7 build #$N_PA : $RES ($ST) — $(grep -E 'REFUS|MERGER_|FOUR_EYES|SHA_NON|error' "$TMP/pa.console" | tail -4 | tr '\n' ' ')"
grep -q 'MERGE_IDENTITY_OK' "$TMP/pa.console" && ok "1.7b MERGE_IDENTITY_OK (alice = mergeuse relue sur la forge, ≠ demandeur ci)" || ko "1.7b garde d'identité absente du log"
S_NUM=$(grep -oE "aval selfservice-app-deploy #[0-9]+" "$TMP/pa.console" | grep -oE '[0-9]+$' | head -1)
[ -n "$S_NUM" ] && [ "$S_NUM" -ge "$N_SS" ] && ok "1.8 aval selfservice-app-deploy #$S_NUM lancé par ce build" || ko "1.8 numéro de build aval introuvable dans le log amont"
grep -q "APPLIED_MODE=pinned APPLIED_SHA=$MERGE_SHA " "$TMP/pa.console" && grep -q 'verdict amont : SUCCESS' "$TMP/pa.console" \
  && ok "1.9 l'amont a relu APPLIED_MODE=pinned et APPLIED_SHA=$MERGE_SHA dans buildVariables et rendu SUCCESS (confrontation passée)" || ko "1.9 APPLIED_SHA/verdict absents ou divergents : $(grep -E 'aval .*APPLIED_SHA' "$TMP/pa.console" | head -1)"
if [ -n "$S_NUM" ]; then
  jconsole selfservice-app-deploy "$S_NUM" > "$TMP/ss.console"
  grep -q "SHA mergé $MERGE_SHA checkouté" "$TMP/ss.console" && ok "1.10 l'AVAL a checkouté le SHA mergé (log : « SHA mergé … checkouté »)" || ko "1.10 checkout du SHA mergé absent du log aval"
  grep -q "^APPLIED_SHA=$MERGE_SHA$" "$TMP/ss.console" && ok "1.10b log aval : APPLIED_SHA=$MERGE_SHA" || ko "1.10b APPLIED_SHA divergent dans l'aval : $(grep '^APPLIED_SHA=' "$TMP/ss.console")"
  grep -q "^APPLIED_DIGEST=$D_MERGED$" "$TMP/ss.console" && ok "1.10c log aval : APPLIED_DIGEST = digest du manifeste effectif MERGÉ (≠ HEAD)" || ko "1.10c APPLIED_DIGEST divergent : $(grep '^APPLIED_DIGEST=' "$TMP/ss.console")"
  grep -q 'failed=0' "$TMP/ss.console" && ok "1.10d converge + verify : failed=0 dans le log aval" || ko "1.10d aucun failed=0 dans le log aval"
  [ "$(jresult selfservice-app-deploy "$S_NUM")" = SUCCESS ] && ok "1.10e aval #$S_NUM : SUCCESS" || ko "1.10e aval #$S_NUM : $(jresult selfservice-app-deploy "$S_NUM")"
fi
# ── la PR comme tableau de bord ──
CMTS=$(pr_comments "$PR_P")
printf '%s' "$CMTS" | grep -q 'Apply nominatif RÉUSSI' && ok "1.11 PR #$PR_P : « Apply nominatif RÉUSSI »" || ko "1.11 verdict absent du commentaire"
printf '%s' "$CMTS" | grep -q "référence appliquée (SHA de merge) : \`$MERGE_SHA\`" && ok "1.11b la PR porte le SHA appliqué = MERGE_SHA" || ko "1.11b SHA absent ou divergent dans la PR"
printf '%s' "$CMTS" | grep -q "digest du manifeste effectif \`per_env.rec\` à ce SHA : \`$D_MERGED\`" && ok "1.11c la PR porte le digest du manifeste effectif MERGÉ" || ko "1.11c digest absent ou divergent"
printf '%s' "$CMTS" | grep -q "$D_HEAD" && ko "1.11d le digest de HEAD apparaît dans la PR (l'apply a projeté HEAD ?)" || ok "1.11d le digest de HEAD n'apparaît nulle part dans la PR"
printf '%s' "$CMTS" | grep -q 'appliqué sous l'"'"'identité de : \*\*alice\*\*' && ok "1.11e identité nominative alice sur la PR" || ko "1.11e identité absente"
printf '%s' "$CMTS" | grep -q 'provision-apply (statut build) : build termine sans erreur' && ok "1.11f statut build (post) posé sous son marqueur distinct" || ko "1.11f statut build absent"
# ── L'ÉTAT DE LA GATEWAY : ce qui tourne en rec ──
APPJ=$(gw_app "$APP_P")
APP_P_ID=$(printf '%s' "$APPJ" | jq_ "print(d.get('id',''))" 2>/dev/null || true)
[ -n "$APP_P_ID" ] && ok "1.12 application ${APP_P} présente sur la gateway (id $APP_P_ID)" || ko "1.12 application ${APP_P} absente de la gateway"
IPS=$(gw_app_ip "$APPJ")
[ "$IPS" = "10.42.0.1-10.42.0.1" ] && ok "1.13 PORTE A2 : identifier ipAddressRange = 10.42.0.1-10.42.0.1 — l'IP du SHA MERGÉ, pas celle de HEAD (10.42.0.2)" || ko "1.13 identifier IP inattendu : '$IPS' (attendu 10.42.0.1-10.42.0.1)"
printf '%s' "$APPJ" | grep -q "${APP_P}-rec" && ok "1.13b claim azp = ${APP_P}-rec (identité du palier rec)" || ko "1.13b claim du palier absente"

echo
echo "═══ 2. CONTRE-ÉPREUVE — webhook forgé sur une PR JAMAIS mergée ⇒ PAYLOAD_PERIME, gateway inchangée ═══"
OUT=$(GITEA_TOKEN="$CI_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" PROVISION_PLAN_INLINE=false \
      REQ_APP="$APP_Q" REQ_ENV=rec REQ_API="$REQ_API" REQ_API_VER="$REQ_API_VER" REQ_CALLER=oig-provisioner \
      REQ_CLIENT_ID="${APP_Q}-rec" REQ_IP_ALLOWLIST="10.42.0.9" bash scripts/provision-request.sh 2>&1); RC=$?
PR_Q=$(printf '%s' "$OUT" | grep -oE 'PR_URL=[^ ]*/pulls/[0-9]+' | grep -oE '[0-9]+$' | tail -1)
[ "$RC" -eq 0 ] && [ -n "$PR_Q" ] && ok "2.1 PR #$PR_Q ouverte pour ${APP_Q} — et JAMAIS mergée" || die "PREREQUIS : seconde demande en échec (rc=$RC)"
[ "$(pr_field "$PR_Q" "['merged']")" = False ] && ok "2.1b Gitea : merged=False" || ko "2.1b la PR #$PR_Q est déjà mergée ?"
N_PA2=$(jnext provision-apply); N_SS2=$(jnext selfservice-app-deploy)
MAIN_NOW=$(gapi "$API/repos/$GIT_REPO/branches/main" | jq_ "print(d['commit']['id'])")
python3 - "$BR_Q" "$PR_Q" "$MAIN_NOW" > "$TMP/forged.json" <<'PY'
import json, sys
print(json.dumps({"action": "closed", "pull_request": {"head": {"ref": sys.argv[1]}, "number": int(sys.argv[2]), "merged": True,
  "merged_by": {"login": "alice"}, "user": {"login": "ci"}, "merge_commit_sha": sys.argv[3]}}))
PY
# Le build de CE tir est résolu depuis la réponse GWT (item de file → executable.number),
# jamais « le dernier build » : sur un lab partagé, un autre tir pourrait fournir l'ancre.
# ⚠ appelé dans un $( ) : le code HTTP passe par un fichier (wh_hc), pas par une variable.
fire_webhook(){ # $1=fichier payload → imprime le numéro de build, ou vide ; code HTTP dans $TMP/wh.hc
  curl -s -X POST -H 'Content-Type: application/json' --data-binary @"$1" "$JENKINS_UI/generic-webhook-trigger/invoke?token=stoa-provision-apply" -o "$TMP/wh.out" -w '%{http_code}' > "$TMP/wh.hc"
  local qid n dl
  qid=$(jq_ "print((d.get('jobs') or {}).get('provision-apply', {}).get('id', ''))" < "$TMP/wh.out" 2>/dev/null || true)
  [ -n "$qid" ] || { echo ""; return; }
  dl=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    n=$(curl -s "$JENKINS_UI/queue/item/$qid/api/json" | jq_ "print((d.get('executable') or {}).get('number', ''))" 2>/dev/null || true)
    [ -n "$n" ] && { echo "$n"; return; }
    sleep 2
  done
  echo ""
}
N_PA2=$(fire_webhook "$TMP/forged.json")
wh_hc(){ cat "$TMP/wh.hc" 2>/dev/null; }
[ "$(wh_hc)" = 200 ] && ok "2.2 webhook forgé accepté par GWT (HTTP 200 — le filtre ne voit que le payload) : merged:true, SHA réel de main $MAIN_NOW" || ko "2.2 webhook forgé refusé (HTTP $(wh_hc)) : $(head -c 200 "$TMP/wh.out")"
[ -n "$N_PA2" ] && ok "2.2b build résolu depuis l'item de file GWT : provision-apply #$N_PA2" || die "BUILD_EN_FILE : le tir forgé n'a pas produit de build (item de file sans executable) — file bloquée ?"
ST=$(wait_until 300 provision-apply "$N_PA2" FINISHED); RES=$(jresult provision-apply "$N_PA2")
DN2=$(curl -s "$JENKINS_UI/job/provision-apply/$N_PA2/api/json?tree=displayName" | jq_ "print(d.get('displayName',''))")
[ "$DN2" = "apply ${APP_Q}/rec (PR #$PR_Q)" ] && ok "2.2c displayName « apply ${APP_Q}/rec (PR #$PR_Q) » : c'est bien NOTRE tir" || ko "2.2c displayName inattendu : $DN2"
if [ "$ST" = PAUSED_PENDING_INPUT ]; then
  jabort_input provision-apply "$N_PA2"; ko "2.3 le build forgé #$N_PA2 a atteint la PAUSE (régression : la réconciliation aurait dû refuser avant) — pause abandonnée par ce harnais"
else
  [ "$RES" = FAILURE ] && ok "2.3 build #$N_PA2 : FAILURE, jamais en pause (état final $ST)" || ko "2.3 build #$N_PA2 : $RES ($ST)"
fi
jconsole provision-apply "$N_PA2" > "$TMP/pa2.console"
grep -q 'REFUS: PAYLOAD_PERIME' "$TMP/pa2.console" && ok "2.4 REFUS: PAYLOAD_PERIME dans le log (Gitea : merged=False)" || ko "2.4 PAYLOAD_PERIME absent : $(grep -E 'REFUS|error' "$TMP/pa2.console" | tail -3 | tr '\n' ' ')"
grep -q 'MERGE_IDENTITY_OK\|assert-merge-identity' "$TMP/pa2.console" && ko "2.5 la garde d'identité a tourné (elle ne devait jamais être atteinte)" || ok "2.5 la garde d'identité n'a jamais tourné (refus AVANT la pause)"
grep -q 'aval selfservice-app-deploy #' "$TMP/pa2.console" && ko "2.6 un build aval a été lancé" || ok "2.6 aucun build aval lancé par le build forgé"
[ "$(jnext selfservice-app-deploy)" = "$N_SS2" ] && ok "2.7 nextBuildNumber de selfservice-app-deploy inchangé ($N_SS2) : le moteur n'a JAMAIS été invoqué" || ko "2.7 selfservice-app-deploy a tourné (next $N_SS2 → $(jnext selfservice-app-deploy))"
[ -z "$(gw_app "$APP_Q")" ] && ok "2.8 aucune application ${APP_Q} sur la gateway (gateway inchangée)" || ko "2.8 application ${APP_Q} PRÉSENTE sur la gateway"
CMTS=$(pr_comments "$PR_Q")
printf '%s' "$CMTS" | grep -q 'Apply REFUSÉ avant la pause\*\* — `PAYLOAD_PERIME`' && ok "2.9 PR #$PR_Q commentée « REFUSÉ avant la pause — PAYLOAD_PERIME »" || ko "2.9 commentaire de refus absent"
printf '%s' "$CMTS" | grep -q "CE webhook n'a rien appliqué" && ok "2.9b « CE webhook n'a rien appliqué »" || ko "2.9b conséquence absente"
printf '%s' "$CMTS" | grep -q '<!-- provision-apply-refus -->' && ok "2.9c le refus est sous le marqueur provision-apply-refus" || ko "2.9c marqueur du refus absent"
printf '%s' "$CMTS" | grep -q 'provision-apply (statut build) : le build a echoue' && ok "2.9d statut build (post) : échec, sous son marqueur (la forge a confirmé une PR provision/*)" || ko "2.9d statut build absent"

echo
echo "═══ 3. CONTRE-ÉPREUVE 2 — rejeu du webhook RÉEL de la porte : main a dépassé ce palier ⇒ PALIER_SUPPLANTE ═══"
# Le payload exact de la PR #PR_P (réellement mergée, par alice) rejoué maintenant
# que main porte 10.42.0.2 pour per_env.rec : sans A2, Gitea dirait « tout
# concorde » et la pause s'ouvrirait sur un état dépassé.
python3 - "$BR_P" "$PR_P" "$MERGE_SHA" > "$TMP/replay.json" <<'PY'
import json, sys
print(json.dumps({"action": "closed", "pull_request": {"head": {"ref": sys.argv[1]}, "number": int(sys.argv[2]), "merged": True,
  "merged_by": {"login": "alice"}, "user": {"login": "ci"}, "merge_commit_sha": sys.argv[3]}}))
PY
N_SS3=$(jnext selfservice-app-deploy)
N_PA3=$(fire_webhook "$TMP/replay.json")
[ "$(wh_hc)" = 200 ] && [ -n "$N_PA3" ] && ok "3.1 rejeu accepté par GWT, build provision-apply #$N_PA3 (item de file résolu)" || die "BUILD_EN_FILE : rejeu sans build (HTTP $(wh_hc))"
ST=$(wait_until 300 provision-apply "$N_PA3" FINISHED); RES=$(jresult provision-apply "$N_PA3")
if [ "$ST" = PAUSED_PENDING_INPUT ]; then
  jabort_input provision-apply "$N_PA3"; ko "3.2 le rejeu #$N_PA3 a atteint la PAUSE (régression) — pause abandonnée par ce harnais"
else
  [ "$RES" = FAILURE ] && ok "3.2 build #$N_PA3 : FAILURE, jamais en pause (état final $ST)" || ko "3.2 build #$N_PA3 : $RES ($ST)"
fi
jconsole provision-apply "$N_PA3" > "$TMP/pa3.console"
grep -q 'REFUS: PALIER_SUPPLANTE' "$TMP/pa3.console" && ok "3.3 REFUS: PALIER_SUPPLANTE (main porte 10.42.0.2, la PR portait 10.42.0.1)" || ko "3.3 PALIER_SUPPLANTE absent : $(grep -E 'REFUS|error' "$TMP/pa3.console" | tail -3 | tr '\n' ' ')"
[ "$(jnext selfservice-app-deploy)" = "$N_SS3" ] && ok "3.4 aucun build aval : le moteur n'a pas été invoqué" || ko "3.4 selfservice-app-deploy a tourné"
APPJ3=$(gw_app "$APP_P"); [ "$(gw_app_ip "$APPJ3")" = "10.42.0.1-10.42.0.1" ] && ok "3.5 gateway inchangée : ${APP_P} porte toujours 10.42.0.1 (le rejeu n'a rien re-projeté)" || ko "3.5 état gateway modifié : $(gw_app_ip "$APPJ3")"
CMTS=$(pr_comments "$PR_P")
printf '%s' "$CMTS" | grep -q 'Apply REFUSÉ avant la pause\*\* — `PALIER_SUPPLANTE`' && ok "3.6 PR #$PR_P : refus PALIER_SUPPLANTE commenté (marqueur refus)" || ko "3.6 commentaire PALIER_SUPPLANTE absent"
printf '%s' "$CMTS" | grep -q "référence appliquée (SHA de merge) : \`$MERGE_SHA\`" && printf '%s' "$CMTS" | grep -q 'Apply nominatif RÉUSSI' \
  && ok "3.7 le tableau de bord de l'apply RÉEL (✅ SHA + digest) est INTACT : le refus est un commentaire distinct" || ko "3.7 le ✅ de l'apply réel a été altéré par le rejeu"

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
