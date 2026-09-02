#!/usr/bin/env bash
# test-a3-live.sh — la PORTE et les CONTRE-ÉPREUVES d'A3 (GOAL cd-applications :
# le credential du seul palier), par BUILDS RÉELS sur le lab : Gitea + Jenkins +
# Vault + annuaire + la 10.15 réelle.
#
#   PORTE : demande rec, merge par alice (LDAP : deploy-banking-demo + apply-rec),
#     pause, réponse ⇒ provision-apply SUCCESS ; la console de l'AVAL montre
#     « palier ouvert : envs/rec/wm-admin », PALIER_CREDS=envs/rec/wm-admin,
#     PALIER_TEAM=banking-demo (décidée par le token), JAMAIS
#     deploy/banking-demo/wm-admin, et l'ORDRE : ticket < préflight < converge <
#     verify ; la gateway porte l'application (claim <app>-rec, IP du bloc mergé).
#   MATRICE PAR BUILD : main reçoit per_env.int, build DIRECT de l'aval avec
#     ENVIRONMENT=int sous alice ⇒ FAILURE `PALIER_FERME` (envs/int/wm-admin,
#     403), AUCUN préflight, AUCUN play d'apply, token révoqué prouvé mort,
#     gateway inchangée — « le job de rec ne peut lire aucun envs/int/* ».
#   F4 : policy apply-rec RÉVOQUÉE ⇒ build direct rec au MERGE_SHA de la porte
#     ⇒ FAILURE `PALIER_FERME`, zéro connexion gateway, gateway inchangée ;
#     policy restaurée et relue identique à l'octet près.
#   REJEU : même build ⇒ SUCCESS, « palier ouvert », MÊME id d'application (la
#     convergence ne recrée pas).
#   MESURE (jamais un ko) : sur la gateway UNIQUE du lab, envs/rec/wm-admin lit
#     une application dev — la ségrégation au plan de données est topologique.
#
# ── FAIL-CLOSED, JAMAIS DE SKIP MUET ────────────────────────────────────────
# Prérequis manquant ⇒ exit 1 `LAB_ABSENT : …` ou `PREREQUIS : …`.
#
# ── CE QUE CE SCRIPT ÉCRIT DANS LE LAB, ET CE QU'IL REMET ────────────────────
# Lab PARTAGÉ : PR provision/* jetable MERGÉE (la porte), commit sur main
# (per_env.int), manifeste retiré de main en fin ; application jetable créée
# sur la gateway réelle puis supprimée ; policy apply-rec révoquée puis
# RESTAURÉE (relue octet à octet, trap) ; ne draine que SES pauses.
#
# Entrées (env) — OBLIGATOIRES, sans défaut vers un système en service :
#   JENKINS_UI GITEA_URL GW_ADMIN WM_USER WM_PASS
#   LAB_ALICE_PASS  (ou lu dans ./.env.lab-users s'il existe)
#   VAULT_TOKEN     (root de lab ; ou lu dans le conteneur poc-vault)
# Optionnelles : GITEA_TOKEN_FILE GITEA_CONTAINER GIT_REPO EXPECT_ADMIN_VIA
#   REQ_API REQ_API_VER VAULT_ADDR_LAB VAULT_CONTAINER
#
#   JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 \
#   GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage \
#     bash scripts/test-a3-live.sh
# `A && ok || ko` (SC2015) est l'idiome des scripts de preuve du repo.
# shellcheck disable=SC2015
set -uo pipefail
set +x
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

if [ -z "${LAB_ALICE_PASS:-}" ] && [ -r ./.env.lab-users ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env.lab-users; set +a
fi
JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis (ex. http://localhost:18080)}"
GITEA_URL="${GITEA_URL:?GITEA_URL requis (ex. http://localhost:13000)}"
GW_ADMIN="${GW_ADMIN:?GW_ADMIN requis (ex. http://localhost:5555/rest/apigateway)}"
WM_USER="${WM_USER:?WM_USER requis}"
WM_PASS="${WM_PASS:?WM_PASS requis}"
LAB_ALICE_PASS="${LAB_ALICE_PASS:?LAB_ALICE_PASS requis (ou ./.env.lab-users)}"
VAULT_ADDR_LAB="${VAULT_ADDR_LAB:-http://localhost:8200}"
VAULT_CONTAINER="${VAULT_CONTAINER:-poc-vault}"
if [ -z "${VAULT_TOKEN:-}" ] && docker inspect "$VAULT_CONTAINER" >/dev/null 2>&1; then
  VAULT_TOKEN="$(docker exec "$VAULT_CONTAINER" printenv VAULT_DEV_ROOT_TOKEN_ID 2>/dev/null || true)"
fi
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis (root de lab, ou conteneur $VAULT_CONTAINER)}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GITEA_CONTAINER="${GITEA_CONTAINER:-poc-gitea}"
EXPECT_ADMIN_VIA="${EXPECT_ADMIN_VIA:-direct}"
REQ_API="${REQ_API:-demo-selfservice}"
REQ_API_VER="${REQ_API_VER:-1.0.0}"
TENANT="${A3_TENANT:-banking-demo}"
MAN_DIR="poc-control-plane-federation/clients/provisioned/applications"

TS="$(date +%s)"
TMP="$(mktemp -d)"; umask 077
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
die(){ printf '\n%s\n' "$*" >&2; exit 1; }

APP_P="a3p$TS"; BR_P="provision/${APP_P}-rec"
PR_P=""; MERGE_SHA=""; APP_P_ID=""; CI_TOKEN=""; ALICE_TOKEN=""
POLICY_BAK="$TMP/policy.bak"; POLICY_REVOKED=0
API="$GITEA_URL/api/v1"
VHDR="$TMP/vhdr"; printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$VHDR"
vcurl(){ curl -s -m 20 -H @"$VHDR" "$@"; }

# ── helpers Gitea (token en EN-TÊTE via fichier, jamais en argv) ─────────────
gapi(){ curl -s -H @"$TMP/ci.hdr" -H 'Content-Type: application/json' "$@"; }
aapi(){ curl -s -H @"$TMP/alice.hdr" -H 'Content-Type: application/json' "$@"; }
jq_(){ python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
$1"; }
raw_at(){ gapi -o "$TMP/raw.out" -w '%{http_code}' "$API/repos/$GIT_REPO/raw/$1/$2" > "$TMP/raw.hc"; cat "$TMP/raw.out"; }
raw_hc(){ cat "$TMP/raw.hc" 2>/dev/null; }
pr_field(){ gapi "$API/repos/$GIT_REPO/pulls/$1" | jq_ "print(d$2)"; }
pr_comments(){ gapi "$API/repos/$GIT_REPO/issues/$1/comments" | jq_ "print('\n=====\n'.join(c.get('body','') for c in d))"; }
# ── helpers Jenkins ──────────────────────────────────────────────────────────
jcrumb(){ curl -sf -c "$1" "$JENKINS_UI/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])'; }
jstatus(){ curl -s "$JENKINS_UI/job/$1/$2/wfapi/describe" | jq_ "print(d.get('status',''))" 2>/dev/null || true; }
jresult(){ curl -s "$JENKINS_UI/job/$1/$2/api/json?tree=result,building" | jq_ "print(d.get('result') or ('BUILDING' if d.get('building') else ''))" 2>/dev/null || true; }
jnext(){ curl -sf "$JENKINS_UI/job/$1/api/json?tree=nextBuildNumber" | jq_ "print(d['nextBuildNumber'])"; }
jconsole(){ curl -s "$JENKINS_UI/job/$1/$2/consoleText"; }
jinput_id(){ curl -s "$JENKINS_UI/job/$1/$2/wfapi/pendingInputActions" | jq_ "print(d[0]['id'] if d else '')" 2>/dev/null || true; }
jabort_input(){ local jar="$TMP/jar.abort.$2" cr iid; cr=$(jcrumb "$jar") || return 1; iid=$(jinput_id "$1" "$2"); [ -n "$iid" ] && curl -s -b "$jar" -H "$cr" -X POST "$JENKINS_UI/job/$1/$2/input/$iid/abort" -o /dev/null; }
wait_until(){ # <secondes> <job> <build> <état attendu | FINISHED>
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
# jbuild <job> <fichier de formulaire urlencodé> → numéro de build (résolu depuis
# l'item de file, jamais « le dernier build » — lab partagé). Le mot de passe est
# dans le fichier, jamais en argv.
jbuild(){
  local jar="$TMP/jar.b.$RANDOM" cr qid n dl
  cr=$(jcrumb "$jar") || { echo ""; return; }
  curl -s -b "$jar" -H "$cr" -X POST -D "$TMP/b.hdr" -o /dev/null --data-binary @"$2" -H 'Content-Type: application/x-www-form-urlencoded' "$JENKINS_UI/job/$1/buildWithParameters"
  qid=$(grep -i '^Location:' "$TMP/b.hdr" | grep -oE 'queue/item/[0-9]+' | grep -oE '[0-9]+$' | head -1)
  [ -n "$qid" ] || { echo ""; return; }
  dl=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    n=$(curl -s "$JENKINS_UI/queue/item/$qid/api/json" | jq_ "print((d.get('executable') or {}).get('number', ''))" 2>/dev/null || true)
    [ -n "$n" ] && { echo "$n"; return; }
    sleep 2
  done
  echo ""
}
form_file(){ # <fichier> puis paires clé=valeur sur STDIN (une par ligne) → urlencodé
  # ⚠ urlencode() exige des TUPLES : une liste de listes lève TypeError, le
  # fichier n'est jamais écrit et curl poste un corps VIDE — Jenkins démarre
  # alors un build SANS paramètre (mesuré : builds #43-#45 « anonymous », PLAN-only).
  # Fail-closed : un fichier vide/absent tue la suite ici, pas trois builds plus loin.
  python3 -c 'import os,sys,urllib.parse
pairs=[tuple(l.split("=",1)) for l in sys.stdin.read().splitlines() if "=" in l]
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write(urllib.parse.urlencode(pairs))' "$1"
  [ -s "$1" ] && grep -q 'VAULT_USER=alice' "$1" || die "HARNAIS : formulaire de build non écrit ($1)"
}
# ── helpers gateway (Basic via fichier -K, jamais en argv) ───────────────────
cfg(){ U="$2" P="$3" python3 -c 'import os,sys
e=lambda s: s.replace("\\","\\\\").replace("\"","\\\"")
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write("user = \"%s:%s\"\n" % (e(os.environ["U"]), e(os.environ["P"])))' "$1"; }
cfg "$TMP/wm.cfg" "$WM_USER" "$WM_PASS"
gw(){ curl -s -K "$TMP/wm.cfg" -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"; }
gw_app(){ local hc; hc=$(gw -o "$TMP/gw.apps" -w '%{http_code}' "$GW_ADMIN/applications")
  [ "$hc" = 200 ] || die "LAB_GATEWAY_ILLISIBLE : GET $GW_ADMIN/applications -> HTTP $hc"
  N="$1" python3 -c "import json,os
for a in json.load(open('$TMP/gw.apps')).get('applications',[]):
    if a.get('name')==os.environ['N']: print(json.dumps(a)); break"; }
gw_app_ip(){ printf '%s' "$1" | python3 -c "import json,sys
a=json.load(sys.stdin)
for i in a.get('identifiers') or []:
    if i.get('key')=='ipAddressRange': print(','.join(i.get('value') or [])); break" 2>/dev/null; }
gw_app_claims(){ printf '%s' "$1" | python3 -c "import json,sys
a=json.load(sys.stdin)
for i in a.get('identifiers') or []:
    if i.get('key')=='openIdClaims': print(','.join(i.get('value') or [])); break" 2>/dev/null; }

restore_policy(){
  [ "$POLICY_REVOKED" -eq 1 ] || return 0
  [ -s "$POLICY_BAK" ] || { echo "RESTAURATION IMPOSSIBLE : sauvegarde de apply-rec vide" >&2; return 1; }
  vcurl -X PUT "$VAULT_ADDR_LAB/v1/sys/policies/acl/apply-rec" -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"policy":open(sys.argv[1]).read()}))' "$POLICY_BAK")" -o /dev/null
  vcurl "$VAULT_ADDR_LAB/v1/sys/policies/acl/apply-rec" | python3 -c 'import sys,json
try: sys.stdout.write(json.load(sys.stdin)["data"]["policy"])
except Exception: sys.exit(1)' > "$TMP/policy.after" 2>/dev/null
  if cmp -s "$POLICY_BAK" "$TMP/policy.after"; then POLICY_REVOKED=0; return 0; fi
  echo "RESTAURATION ECHOUEE : apply-rec relue diffère de la sauvegarde — lab laissé désarmé" >&2; return 1
}
cleanup(){
  echo; echo "── nettoyage ──"
  restore_policy && echo "  policy apply-rec : armée" || echo "  ⚠ policy apply-rec NON restaurée"
  if [ -n "$CI_TOKEN" ]; then
    gapi -X DELETE -o /dev/null "$API/repos/$GIT_REPO/branches/$BR_P"
    SHA_F=$(gapi "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP_P}.ansible.yml?ref=main" | jq_ "print(d.get('sha',''))" 2>/dev/null || true)
    if [ -n "$SHA_F" ]; then
      gapi -X DELETE -d "{\"branch\":\"main\",\"sha\":\"$SHA_F\",\"message\":\"test(a3-live): retrait du manifeste jetable ${APP_P} (porte A3 jouée)\"}" -o /dev/null "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP_P}.ansible.yml" \
        && echo "  manifeste jetable ${APP_P} retiré de main"
    fi
  fi
  if [ -n "$APP_P_ID" ]; then
    HC=$(gw -X DELETE -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications/$APP_P_ID"); echo "  application jetable ${APP_P} supprimée de la gateway (HTTP $HC, best-effort)"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

echo "═══ 0. Préconditions (fail-closed) ═══"
curl -sf -o /dev/null "$JENKINS_UI/api/json" || die "LAB_ABSENT : Jenkins injoignable ($JENKINS_UI)"
curl -sf -o /dev/null "$GITEA_URL/api/v1/version" || die "LAB_ABSENT : Gitea injoignable ($GITEA_URL)"
HC=$(gw -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications"); [ "$HC" = 200 ] || die "LAB_ABSENT : gateway injoignable ou refus ($GW_ADMIN/applications -> $HC)"
[ "$(vcurl -o /dev/null -w '%{http_code}' "$VAULT_ADDR_LAB/v1/sys/policies/acl?list=true")" = 200 ] || die "LAB_ABSENT : le VAULT_TOKEN ne liste pas les policies (root de lab attendu)"
ok "0.1 Jenkins, Gitea, la gateway et Vault répondent"
if [ -n "${GITEA_TOKEN_FILE:-}" ] && [ -r "$GITEA_TOKEN_FILE" ]; then CI_TOKEN="$(cat "$GITEA_TOKEN_FILE")"
elif docker inspect "$GITEA_CONTAINER" >/dev/null 2>&1; then
  CI_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username ci --token-name "a3-live-ci-$TS" --scopes write:repository,write:issue,write:user,read:user,write:admin 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
fi
[ -n "$CI_TOKEN" ] || die "LAB_ABSENT : aucun token Gitea ci"
printf 'Authorization: token %s\n' "$CI_TOKEN" > "$TMP/ci.hdr"
gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO" | grep -q '^200$' || die "LAB_ABSENT : $GIT_REPO illisible"
ok "0.2 token ci opérationnel"
curl -sf "$JENKINS_UI/job/provision-apply/config.xml" | grep -q 'ci/Jenkinsfile.provision-apply' || die "PREREQUIS : provision-apply n'est pas from SCM"
PARAMS=$(curl -sf "$JENKINS_UI/job/selfservice-app-deploy/api/json?tree=property%5BparameterDefinitions%5Bname%5D%5D" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(" ".join(p["name"] for pr in d.get("property",[]) for p in (pr.get("parameterDefinitions") or [])))')
for p in MERGE_SHA ADMIN_VIA ENVIRONMENT MANIFEST VAULT_USER VAULT_USER_PASSWORD; do case " $PARAMS " in *" $p "*) ;; *) die "PREREQUIS : selfservice-app-deploy ne déclare pas $p";; esac; done
ok "0.3 provision-apply from SCM ; selfservice-app-deploy déclare ses paramètres"
JAR="$TMP/jar.sc"; CR=$(jcrumb "$JAR") || die "LAB_ABSENT : crumb Jenkins"
GLOBAL_VIA=$(curl -s -b "$JAR" -H "$CR" -X POST --data-urlencode 'script=import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty; def p=Jenkins.instance.globalNodeProperties.get(EnvironmentVariablesNodeProperty); println(p==null ? "" : (p.envVars.get("APPLY_ADMIN_VIA") ?: ""))' "$JENKINS_UI/scriptText" | tr -d '\r\n')
[ "$GLOBAL_VIA" = "$EXPECT_ADMIN_VIA" ] && ok "0.4 APPLY_ADMIN_VIA global = $GLOBAL_VIA" || die "PREREQUIS : APPLY_ADMIN_VIA global = '${GLOBAL_VIA:-(absent)}' ≠ '$EXPECT_ADMIN_VIA'"
GLOBAL_TB=$(curl -s -b "$JAR" -H "$CR" -X POST --data-urlencode 'script=import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty; def p=Jenkins.instance.globalNodeProperties.get(EnvironmentVariablesNodeProperty); println(p==null ? "" : (p.envVars.get("APIM_TERMINUS_BASE") ?: ""))' "$JENKINS_UI/scriptText" | tr -d '\r\n')
[ -z "$GLOBAL_TB" ] && ok "0.4b aucune APIM_TERMINUS_BASE globale : le terminus reste sans voie (TERMINUS_SANS_VOIE)" || ko "0.4b APIM_TERMINUS_BASE globale posée ($GLOBAL_TB) — le terminus aurait une voie sur ce lab"
RUNNING=$(curl -s "$JENKINS_UI/job/provision-apply/api/json?tree=builds%5Bnumber,building%5D" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(" ".join(str(b["number"]) for b in d.get("builds",[]) if b.get("building")))')
[ -z "$RUNNING" ] && ok "0.5 aucun build provision-apply en cours" || die "PREREQUIS : builds provision-apply en cours ($RUNNING)"
gw "$GW_ADMIN/apis" | A="$REQ_API" V="$REQ_API_VER" python3 -c "import json,os,sys
d=json.load(sys.stdin)
ok=any((i.get('api',i).get('apiName')==os.environ['A'] and i.get('api',i).get('apiVersion')==os.environ['V'] and i.get('api',i).get('isActive') is True) for i in d.get('apiResponse',[]))
sys.exit(0 if ok else 1)" && ok "0.6 API $REQ_API@$REQ_API_VER active" || die "PREREQUIS : $REQ_API@$REQ_API_VER absente/inactive"
# la garde telle que le CI l'extraira : sur gitea main
gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/raw/main/poc-control-plane-federation/scripts/selfservice-palier-gate.sh" | grep -q '^200$' \
  && ok "0.7 scripts/selfservice-palier-gate.sh est sur gitea main (la lignée que l'aval extrait)" || die "PREREQUIS : la garde n'est pas sur gitea main — git push gitea HEAD:main"
# alice : Gitea
HC=$(gapi -o /dev/null -w '%{http_code}' "$API/users/alice")
if [ "$HC" != 200 ]; then
  APW=$(python3 -c "import secrets,string;print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))")
  docker exec -u git "$GITEA_CONTAINER" gitea admin user create --username alice --password "$APW" --email alice@stoa.lab --must-change-password=false >/dev/null 2>&1 || die "PREREQUIS : création du compte Gitea alice"
  unset APW
fi
HC=$(gapi -o /dev/null -w '%{http_code}' "$API/repos/$GIT_REPO/collaborators/alice")
[ "$HC" = 204 ] || gapi -X PUT -d '{"permission":"write"}' -o /dev/null "$API/repos/$GIT_REPO/collaborators/alice"
ALICE_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token --username alice --token-name "a3-live-alice-$TS" --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
[ -n "$ALICE_TOKEN" ] || die "PREREQUIS : token Gitea d'alice non minté"
printf 'Authorization: token %s\n' "$ALICE_TOKEN" > "$TMP/alice.hdr"
ok "0.8 alice : compte Gitea + collaboratrice write + token"
# alice : Vault par LDAP (le mount du Jenkinsfile) — LA MATRICE SUR L'IDENTITÉ RÉELLE
P="$LAB_ALICE_PASS" python3 -c 'import json,os,sys;open(sys.argv[1],"w").write(json.dumps({"password":os.environ["P"]}))' "$TMP/alogin.json"; chmod 600 "$TMP/alogin.json"
ALT=$(curl -s -m 20 -X POST -H 'Content-Type: application/json' --data-binary @"$TMP/alogin.json" "$VAULT_ADDR_LAB/v1/auth/ldap/login/alice" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["auth"]["client_token"])
except Exception: print("")')
rm -f "$TMP/alogin.json"
[ -n "$ALT" ] || die "PREREQUIS : login LDAP d'alice refusé (mot de passe de lab périmé ? lockout Vault ?)"
printf 'X-Vault-Token: %s\n' "$ALT" > "$TMP/ahdr"
APOL=$(curl -s -m 20 -H @"$TMP/ahdr" "$VAULT_ADDR_LAB/v1/auth/token/lookup-self" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(" ".join(sorted(set((d.get("policies") or [])+(d.get("identity_policies") or [])))))')
case " $APOL " in *" deploy-$TENANT "*) ;; *) die "PREREQUIS : le token LDAP d'alice ne porte pas deploy-$TENANT ($APOL)";; esac
case " $APOL " in *" apply-rec "*) ok "0.9 le token LDAP d'alice porte deploy-$TENANT ET apply-rec ($APOL)";; *) die "PREREQUIS : le token LDAP d'alice ne porte pas apply-rec ($APOL) — jouer DEPLOYERS_REC=alice bash scripts/setup-deployer-groups.sh";; esac
R1=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -H @"$TMP/ahdr" "$VAULT_ADDR_LAB/v1/secret/data/stoa/envs/rec/wm-admin")
R2=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -H @"$TMP/ahdr" "$VAULT_ADDR_LAB/v1/secret/data/stoa/envs/int/wm-admin")
[ "$R1" = 200 ] && ok "0.9b alice lit envs/rec/wm-admin (200)" || die "PREREQUIS : alice ne lit pas envs/rec/wm-admin ($R1)"
[ "$R2" = 403 ] && ok "0.9c PORTE (identité réelle) : alice NE lit PAS envs/int/wm-admin (403) — « le job de rec ne peut lire aucun envs/int/* »" || ko "0.9c alice lit envs/int/wm-admin ($R2) — fuite inter-palier"
curl -s -m 20 -H @"$TMP/ahdr" -X POST "$VAULT_ADDR_LAB/v1/auth/token/revoke-self" -o /dev/null; rm -f "$TMP/ahdr"
# envs/rec/wm-admin s'authentifie sur la gateway (lu par root, jamais imprimé)
vcurl "$VAULT_ADDR_LAB/v1/secret/data/stoa/envs/rec/wm-admin" | python3 -c 'import json,os,sys
d=json.load(sys.stdin)["data"]["data"]
e=lambda s: s.replace("\\","\\\\").replace("\"","\\\"")
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write("user = \"%s:%s\"\n" % (e(d["username"]), e(d["password"])))' "$TMP/rec.cfg" 2>/dev/null
HC=$(curl -s -K "$TMP/rec.cfg" -H 'Accept: application/json' -o /dev/null -w '%{http_code}' "$GW_ADMIN/applications")
[ "$HC" = 200 ] && ok "0.10 envs/rec/wm-admin s'authentifie sur la gateway (200)" || die "PREREQUIS : envs/rec/wm-admin refusé par la gateway ($HC) — jouer scripts/setup-wm-palier-admins.sh"
MAIN_BEFORE=$(gapi "$API/repos/$GIT_REPO/branches/main" | jq_ "print(d['commit']['id'])")
[ -z "$(gw_app "$APP_P")" ] && ok "0.11 aucune application homonyme (main=$MAIN_BEFORE)" || die "PREREQUIS : application $APP_P déjà présente"

echo
echo "═══ 1. PORTE — demande rec, merge par alice, apply au SHA mergé avec le credential du palier ═══"
N_PA=$(jnext provision-apply); N_SS=$(jnext selfservice-app-deploy)
OUT=$(GITEA_TOKEN="$CI_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$GIT_REPO" PROVISION_PLAN_INLINE=false \
      REQ_APP="$APP_P" REQ_ENV=rec REQ_API="$REQ_API" REQ_API_VER="$REQ_API_VER" REQ_CALLER=oig-provisioner \
      REQ_CLIENT_ID="${APP_P}-rec" REQ_IP_ALLOWLIST="10.42.0.1" bash scripts/provision-request.sh 2>&1); RC=$?
PR_P=$(printf '%s' "$OUT" | grep -oE 'PR_URL=[^ ]*/pulls/[0-9]+' | grep -oE '[0-9]+$' | tail -1)
[ "$RC" -eq 0 ] && [ -n "$PR_P" ] && ok "1.1 demande rec ${APP_P} ⇒ PR #$PR_P" || die "PREREQUIS : demande rec en échec (rc=$RC) : $(printf '%s' "$OUT" | tail -5)"
DL=$(( $(date +%s) + 30 )); MERGEABLE=false
while [ "$(date +%s)" -lt "$DL" ]; do MERGEABLE=$(pr_field "$PR_P" ".get('mergeable')"); [ "$MERGEABLE" = True ] && break; sleep 1; done
[ "$MERGEABLE" = True ] || die "PREREQUIS : PR #$PR_P non mergeable"
HC=$(aapi -X POST -d '{"Do":"merge"}' -o "$TMP/merge.out" -w '%{http_code}' "$API/repos/$GIT_REPO/pulls/$PR_P/merge")
[ "$HC" = 200 ] || die "PREREQUIS : merge par alice refusé (HTTP $HC)"
MERGE_SHA=$(pr_field "$PR_P" "['merge_commit_sha']")
printf '%s' "$MERGE_SHA" | grep -Eq '^[0-9a-f]{40}$' && ok "1.2 PR #$PR_P mergée par alice — MERGE_SHA=$MERGE_SHA" || die "PREREQUIS : merge incohérent"
ST=$(wait_until 240 provision-apply "$N_PA" PAUSED_PENDING_INPUT); RCW=$?
[ "$RCW" -eq 0 ] && ok "1.3 provision-apply #$N_PA en PAUSE" || die "PREREQUIS : #$N_PA n'atteint pas la pause ($ST) — $(jconsole provision-apply "$N_PA" | grep -E 'REFUS|error' | tail -2 | tr '\n' ' ')"
IID=$(jinput_id provision-apply "$N_PA"); [ -n "$IID" ] || die "PREREQUIS : aucune pause sur #$N_PA"
JAR="$TMP/jar.in"; CR=$(jcrumb "$JAR") || die "LAB_ABSENT : crumb"
LAB_ALICE_PASS="$LAB_ALICE_PASS" python3 - > "$TMP/input.json" <<'PY'
import json, os
print(json.dumps({"parameter": [{"name": "V_USER", "value": "alice"}, {"name": "V_PASS", "value": os.environ["LAB_ALICE_PASS"]}]}))
PY
HC=$(curl -s -b "$JAR" -H "$CR" -X POST --data-urlencode json@"$TMP/input.json" "$JENKINS_UI/job/provision-apply/$N_PA/wfapi/inputSubmit?inputId=$IID" -o /dev/null -w '%{http_code}')
rm -f "$TMP/input.json"
{ [ "$HC" = 200 ] || [ "$HC" = 302 ]; } && ok "1.4 pause #$N_PA répondue par alice" || die "PREREQUIS : réponse à la pause refusée (HTTP $HC)"
ST=$(wait_until 1500 provision-apply "$N_PA" FINISHED); RES=$(jresult provision-apply "$N_PA")
jconsole provision-apply "$N_PA" > "$TMP/pa.console"
[ "$RES" = SUCCESS ] && ok "1.5 provision-apply #$N_PA : SUCCESS" || ko "1.5 provision-apply #$N_PA : $RES ($ST) — $(grep -E 'REFUS|SHA_NON|error' "$TMP/pa.console" | tail -3 | tr '\n' ' ')"
S_NUM=$(grep -oE "aval selfservice-app-deploy #[0-9]+" "$TMP/pa.console" | grep -oE '[0-9]+$' | head -1)
[ -n "$S_NUM" ] && [ "$S_NUM" -ge "$N_SS" ] && ok "1.6 aval selfservice-app-deploy #$S_NUM" || die "PREREQUIS : numéro de build aval introuvable"
jconsole selfservice-app-deploy "$S_NUM" > "$TMP/ss.console"
[ "$(jresult selfservice-app-deploy "$S_NUM")" = SUCCESS ] && ok "1.7 aval #$S_NUM : SUCCESS" || ko "1.7 aval #$S_NUM : $(jresult selfservice-app-deploy "$S_NUM") — $(grep -E 'REFUS|fatal|error' "$TMP/ss.console" | head -3 | tr '\n' ' ')"
grep -q '^palier ouvert : envs/rec/wm-admin' "$TMP/ss.console" && ok "1.8 console aval : « palier ouvert : envs/rec/wm-admin » (le ticket du palier)" || ko "1.8 « palier ouvert » absent"
grep -q '^PALIER_CREDS=envs/rec/wm-admin$' "$TMP/ss.console" && ok "1.8b PALIER_CREDS=envs/rec/wm-admin" || ko "1.8b PALIER_CREDS absent/divergent : $(grep '^PALIER_CREDS=' "$TMP/ss.console")"
grep -q "^PALIER_TEAM=$TENANT$" "$TMP/ss.console" && ok "1.8c PALIER_TEAM=$TENANT (décidée par le token, manifeste sans team)" || ko "1.8c PALIER_TEAM absent/divergent : $(grep '^PALIER_TEAM=' "$TMP/ss.console")"
grep -q 'deploy/banking-demo/wm-admin' "$TMP/ss.console" && ko "1.8d deploy/banking-demo/wm-admin apparaît dans la console de l'aval" || ok "1.8d aucune occurrence de deploy/banking-demo/wm-admin (le credential du tenant n'est plus lu)"
L_T=$(grep -n '^palier ouvert :' "$TMP/ss.console" | head -1 | cut -d: -f1); L_P=$(grep -n 'préflight de joignabilité :' "$TMP/ss.console" | head -1 | cut -d: -f1)
L_C=$(grep -n 'PLAY \[Self-service application — converge' "$TMP/ss.console" | head -1 | cut -d: -f1); L_V=$(grep -n 'PLAY \[Self-service application — verify' "$TMP/ss.console" | head -1 | cut -d: -f1)
[ -n "$L_T" ] && [ -n "$L_P" ] && [ -n "$L_C" ] && [ -n "$L_V" ] && [ "$L_T" -lt "$L_P" ] && [ "$L_P" -lt "$L_C" ] && [ "$L_C" -lt "$L_V" ] \
  && ok "1.8e ORDRE dans la console : ticket ($L_T) < préflight ($L_P) < converge ($L_C) < verify ($L_V) — aucune connexion gateway avant le credential du palier" \
  || ko "1.8e ordre inattendu : ticket=$L_T préflight=$L_P converge=$L_C verify=$L_V"
[ "$(grep -c 'failed=0' "$TMP/ss.console")" -ge 2 ] && ok "1.8f converge + verify : failed=0 ×2" || ko "1.8f failed=0 : $(grep -c 'failed=0' "$TMP/ss.console")"
grep -q "^APPLIED_SHA=$MERGE_SHA$" "$TMP/ss.console" && ok "1.8g APPLIED_SHA = MERGE_SHA (A2 tient)" || ko "1.8g APPLIED_SHA divergent"
APPJ=$(gw_app "$APP_P"); APP_P_ID=$(printf '%s' "$APPJ" | jq_ "print(d.get('id',''))" 2>/dev/null || true)
[ -n "$APP_P_ID" ] && ok "1.9 application ${APP_P} présente sur la gateway (id $APP_P_ID)" || ko "1.9 application absente"
[ "$(gw_app_ip "$APPJ")" = "10.42.0.1-10.42.0.1" ] && ok "1.9b ipAddressRange = 10.42.0.1-10.42.0.1 (le bloc mergé)" || ko "1.9b IP : $(gw_app_ip "$APPJ")"
[ "$(gw_app_claims "$APPJ")" = "${APP_P}-rec" ] && ok "1.9c claim = ${APP_P}-rec (l'identité du palier rec, et elle seule)" || ko "1.9c claims : $(gw_app_claims "$APPJ")"
CMTS=$(pr_comments "$PR_P")
printf '%s' "$CMTS" | grep -q 'Apply nominatif RÉUSSI' && printf '%s' "$CMTS" | grep -q "$MERGE_SHA" && ok "1.10 PR #$PR_P : ✅ apply nominatif + SHA" || ko "1.10 commentaire d'apply absent"

echo
echo "═══ 2. MATRICE PAR BUILD — main déclare per_env.int, build DIRECT int sous alice ⇒ PALIER_FERME ═══"
MAN_MAIN=$(raw_at main "$MAN_DIR/${APP_P}.ansible.yml"); [ "$(raw_hc)" = 200 ] || die "PREREQUIS : manifeste illisible sur main"
printf '%s\n' "$MAN_MAIN" > "$TMP/man.main.yml"
awk -v app="$APP_P" '{ print } /^    rec: /{ l=$0; gsub(app "-rec", app "-int", l); gsub("10\\.42\\.0\\.1", "10.42.0.3", l); sub(/^    rec: /, "    int: ", l); print l }' "$TMP/man.main.yml" > "$TMP/man.int.yml"
grep -q '^    int: ' "$TMP/man.int.yml" && ! cmp -s "$TMP/man.main.yml" "$TMP/man.int.yml" || die "PREREQUIS : la ligne per_env.int n'a pas pu être dérivée de la ligne rec"
SHA_F=$(gapi "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP_P}.ansible.yml?ref=main" | jq_ "print(d['sha'])")
B64=$(base64 < "$TMP/man.int.yml" | tr -d '\n')
HC=$(gapi -X PUT -d "{\"branch\":\"main\",\"sha\":\"$SHA_F\",\"content\":\"$B64\",\"message\":\"test(a3-live): per_env.int declare pour ${APP_P} (matrice par build : int doit rester FERME a alice)\"}" -o "$TMP/put.out" -w '%{http_code}' "$API/repos/$GIT_REPO/contents/$MAN_DIR/${APP_P}.ansible.yml")
{ [ "$HC" = 200 ] || [ "$HC" = 201 ]; } && ok "2.1 main déclare per_env.int pour ${APP_P} (sans lui, le Plan mourrait ENV_UNDEFINED avant l'Apply)" || die "PREREQUIS : commit per_env.int refusé (HTTP $HC)"
sleep 3
printf 'MANIFEST=clients/provisioned/applications/%s.ansible.yml\nENVIRONMENT=int\nADMIN_VIA=%s\nMERGE_SHA=\nDEBUG=false\nVAULT_USER=alice\nVAULT_USER_PASSWORD=%s\nUSER_VAULT_JWT=\n' "$APP_P" "$EXPECT_ADMIN_VIA" "$LAB_ALICE_PASS" | form_file "$TMP/form.int"
N_INT=$(jbuild selfservice-app-deploy "$TMP/form.int"); rm -f "$TMP/form.int"
[ -n "$N_INT" ] && ok "2.2 build direct selfservice-app-deploy #$N_INT (ENVIRONMENT=int, alice)" || die "BUILD_EN_FILE : aucun build résolu pour le tir int"
ST=$(wait_until 900 selfservice-app-deploy "$N_INT" FINISHED); RES=$(jresult selfservice-app-deploy "$N_INT")
jconsole selfservice-app-deploy "$N_INT" > "$TMP/int.console"
[ "$RES" = FAILURE ] && ok "2.3 build #$N_INT : FAILURE" || ko "2.3 build #$N_INT : $RES ($ST)"
grep -q '^REFUS: PALIER_FERME :' "$TMP/int.console" && grep -q 'envs/int/wm-admin' "$TMP/int.console" && grep -q 'HTTP 403' "$TMP/int.console" \
  && ok "2.4 REFUS: PALIER_FERME sur envs/int/wm-admin (HTTP 403) — PORTE par build : le job de rec ne lit pas envs/int/*" || ko "2.4 PALIER_FERME absent : $(grep -E 'REFUS|error|fatal' "$TMP/int.console" | head -3 | tr '\n' ' ')"
grep -q 'préflight de joignabilité :' "$TMP/int.console" && ko "2.5 le préflight a tourné (connexion gateway sans credential du palier)" || ok "2.5 AUCUN préflight : la gateway n'a pas été contactée"
grep -q 'PLAY \[Self-service application' "$TMP/int.console" && ko "2.6 un play d'apply a tourné" || ok "2.6 AUCUN play d'apply (converge/verify jamais lancés)"
grep -q 'token Vault révoqué — mort PROUVÉE' "$TMP/int.console" && ok "2.7 token nominatif révoqué, mort prouvée (trap)" || ko "2.7 révocation absente de la console"
APPJ2=$(gw_app "$APP_P")
[ "$(gw_app_claims "$APPJ2")" = "${APP_P}-rec" ] && [ "$(gw_app_ip "$APPJ2")" = "10.42.0.1-10.42.0.1" ] && ok "2.8 gateway inchangée : claim ${APP_P}-rec seule, IP 10.42.0.1" || ko "2.8 gateway modifiée : claims=$(gw_app_claims "$APPJ2") ip=$(gw_app_ip "$APPJ2")"

echo
echo "═══ 3. CONTRE-ÉPREUVE F4 — apply-rec RÉVOQUÉE ⇒ apply rec au MERGE_SHA échoue fermé, gateway inchangée ═══"
vcurl "$VAULT_ADDR_LAB/v1/sys/policies/acl/apply-rec" | python3 -c 'import sys,json
try: sys.stdout.write(json.load(sys.stdin)["data"]["policy"])
except Exception: sys.exit(1)' > "$POLICY_BAK" 2>/dev/null
[ -s "$POLICY_BAK" ] || die "LAB_ABSENT : policy apply-rec illisible — révoquer sans sauvegarde est exclu"
POLICY_REVOKED=1
vcurl -X DELETE "$VAULT_ADDR_LAB/v1/sys/policies/acl/apply-rec" -o /dev/null
[ "$(vcurl -o /dev/null -w '%{http_code}' "$VAULT_ADDR_LAB/v1/sys/policies/acl/apply-rec")" = 404 ] && ok "3.1 policy apply-rec RÉVOQUÉE (404)" || ko "3.1 apply-rec répond encore"
printf 'MANIFEST=clients/provisioned/applications/%s.ansible.yml\nENVIRONMENT=rec\nADMIN_VIA=%s\nMERGE_SHA=%s\nDEBUG=false\nVAULT_USER=alice\nVAULT_USER_PASSWORD=%s\nUSER_VAULT_JWT=\n' "$APP_P" "$EXPECT_ADMIN_VIA" "$MERGE_SHA" "$LAB_ALICE_PASS" | form_file "$TMP/form.rec"
N_F4=$(jbuild selfservice-app-deploy "$TMP/form.rec")
[ -n "$N_F4" ] && ok "3.2 build direct rec #$N_F4 au MERGE_SHA de la porte (le levier A6), policy révoquée" || die "BUILD_EN_FILE : aucun build pour le tir F4"
ST=$(wait_until 900 selfservice-app-deploy "$N_F4" FINISHED); RES=$(jresult selfservice-app-deploy "$N_F4")
jconsole selfservice-app-deploy "$N_F4" > "$TMP/f4.console"
[ "$RES" = FAILURE ] && grep -q '^REFUS: PALIER_FERME :' "$TMP/f4.console" && grep -q 'envs/rec/wm-admin' "$TMP/f4.console" \
  && ok "3.3 build #$N_F4 : FAILURE PALIER_FERME sur envs/rec/wm-admin — le palier s'est FERMÉ par la révocation, sans edit" || ko "3.3 build #$N_F4 : $RES — $(grep -E 'REFUS|error' "$TMP/f4.console" | head -2 | tr '\n' ' ')"
grep -q 'SHA mergé .* checkouté' "$TMP/f4.console" && ok "3.3b le SHA mergé avait été checkouté (pinned) — la garde est venue de main, pas de l'arbre pinné" || ko "3.3b checkout du SHA absent"
grep -q 'préflight de joignabilité :' "$TMP/f4.console" && ko "3.4 le préflight a tourné" || ok "3.4 AUCUN préflight — zéro connexion gateway (le F4-canari, sur cette voie)"
grep -q 'PLAY \[Self-service application' "$TMP/f4.console" && ko "3.5 un play d'apply a tourné" || ok "3.5 AUCUN play d'apply"
grep -q 'token Vault révoqué — mort PROUVÉE' "$TMP/f4.console" && ok "3.6 token révoqué, mort prouvée" || ko "3.6 révocation absente"
APPJ3=$(gw_app "$APP_P")
[ "$(gw_app_claims "$APPJ3")" = "${APP_P}-rec" ] && [ "$(gw_app_ip "$APPJ3")" = "10.42.0.1-10.42.0.1" ] && ok "3.7 gateway inchangée" || ko "3.7 gateway modifiée"
restore_policy && ok "3.8 policy apply-rec restaurée et RELUE identique à l'octet près" || ko "3.8 restauration en échec"

echo
echo "═══ 4. REJEU après restauration — même build ⇒ SUCCESS, même id d'application ═══"
N_RJ=$(jbuild selfservice-app-deploy "$TMP/form.rec"); rm -f "$TMP/form.rec"
[ -n "$N_RJ" ] && ok "4.1 build direct rec #$N_RJ au MERGE_SHA, policy restaurée" || die "BUILD_EN_FILE : aucun build pour le rejeu"
ST=$(wait_until 1500 selfservice-app-deploy "$N_RJ" FINISHED); RES=$(jresult selfservice-app-deploy "$N_RJ")
jconsole selfservice-app-deploy "$N_RJ" > "$TMP/rj.console"
[ "$RES" = SUCCESS ] && grep -q '^palier ouvert : envs/rec/wm-admin' "$TMP/rj.console" && ok "4.2 build #$N_RJ : SUCCESS, palier ouvert" || ko "4.2 build #$N_RJ : $RES — $(grep -E 'REFUS|fatal|error' "$TMP/rj.console" | head -3 | tr '\n' ' ')"
APPJ4=$(gw_app "$APP_P"); ID4=$(printf '%s' "$APPJ4" | jq_ "print(d.get('id',''))" 2>/dev/null || true)
[ -n "$ID4" ] && [ "$ID4" = "$APP_P_ID" ] && ok "4.3 MÊME id d'application ($ID4) : la convergence ne recrée pas (la propriété qu'A6 attend)" || ko "4.3 id divergent : $ID4 ≠ $APP_P_ID"

echo
echo "═══ 5. MESURE (limite D9) — la gateway unique du lab ═══"
OTHER=$(curl -s -K "$TMP/rec.cfg" -H 'Accept: application/json' "$GW_ADMIN/applications" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(" ".join(sorted(a.get("name","") for a in d.get("applications",[]) if a.get("name") not in ("'"$APP_P"'",))))' 2>/dev/null | cut -c1-120)
echo "  MESURE : sur cette gateway UNIQUE, envs/rec/wm-admin lit aussi : ${OTHER:-(rien)} — la ségrégation des paliers au plan de données est celle de la topologie (une gateway par palier chez un client), pas du credential ; A3 mesure la rétention côté Vault."

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
