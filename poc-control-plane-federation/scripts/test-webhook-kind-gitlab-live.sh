#!/usr/bin/env bash
# scripts/test-webhook-kind-gitlab-live.sh — LA PREUVE du visage `gitlab` : la
# chaîne app-request déroulée de bout en bout par le GitLab Plugin, contre le
# GitLab CE et le Jenkins du LAB (spec docs/superpowers/specs/
# 2026-09-11-webhook-kind-deux-visages-design.md §9.3, ADR-098).
#
# CE QUE CETTE SUITE DÉFEND. Sous WEBHOOK_KIND=gitlab, plus une seule ligne de
# la chaîne ne passe par le generic-webhook-trigger : c'est le GitLab Plugin qui
# reçoit, et ses CASES (pas une expression régulière) qui filtrent. Trois
# propriétés doivent tenir, et aucune n'est démontrable hors ligne :
#   1. l'ouverture d'une MR fait un PLAN et la fusion fait un APPLY — rien
#      d'autre ne construit (une fermeture sans fusion, en particulier) ;
#   2. MERGE_SHA vaut le merge_commit_sha de l'API : la référence A2 survit au
#      changement de récepteur (le plugin n'expose pas l'action, seulement
#      l'état — le pipeline le relit) ;
#   3. le retour à gwt est complet : /project/<job> redevient muet et le token
#      du GWT revit.
#
# JETABLE et RÉVERSIBLE : deux webhooks de projet, une branche provision/*, une
# MR, et les globales Jenkins du visage gitlab — tout est retiré ou restauré en
# sortie (trap), y compris en cas d'échec, et les deux jobs sont re-posés sous
# gwt. La pause nominative de l'apply est ABANDONNÉE, jamais soldée : ce harnais
# ne déploie rien.
#
# PRÉREQUIS :
#   - gitlab-plugin ET generic-webhook-trigger sur le Jenkins (l'image du lab
#     les porte depuis L6 ; sur un lab plus ancien : bash
#     scripts/spike-webhook-kind-m5.sh) ;
#   - docker compose -f docker-compose.gitlab.yml up -d gitlab, puis
#     bash scripts/setup-gitlab-lab.sh  → .env.gitlab-lab (PAT 0600) ;
#   - le projet GitLab porte notre tronc sur SA branche par défaut et fusionne
#     par MERGE COMMIT (en ff/squash, merge_commit_sha est nul : le harnais
#     REFUSE plutôt que de mesurer un SHA vide) ;
#   - un credential Jenkins « secret text » nommé `gitlab-provision-token`
#     (knob CID_GL) portant un PAT GitLab (scopes api, read_user,
#     write_repository) : le credential de forge du lab porte un jeton GITEA,
#     que l'API de GitLab refuse en 401 — le plan déclencherait puis mourrait.
#     Le harnais pose GITEA_CREDENTIALS_ID dessus et le RESTAURE en sortie ;
#   - Vault du lab re-seedé (la garde A3 lit envs/dev/wm-admin).
#
#   JENKINS_UI=http://localhost:18080 bash scripts/test-webhook-kind-gitlab-live.sh
#
# Directives shellcheck : SC2329 les fonctions de trap, SC2034 les compteurs,
# SC2015 `A && ok … || ko …` (idiome des harnais du dépôt), SC1091
# .env.gitlab-lab est hors Git.
# shellcheck disable=SC2329,SC2034,SC2015,SC1091
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
J="${JENKINS_UI:?JENKINS_UI requis (ex. http://localhost:18080)}"
JIN="${JENKINS_INCLUSTER:-http://jenkins:8080}"        # Jenkins vu DEPUIS GitLab
GL="${GITLAB_LAB_URL:-http://localhost:13080}"          # GitLab vu du poste
GLIN="${GITLAB_INCLUSTER:-http://gitlab:80}"            # GitLab vu de Jenkins
PID_PROJ="${GITLAB_LAB_PROJECT_ID:-1}"
GL_REPO="${GITLAB_LAB_REPO:-ci/stoa-labs}"
APP="${APP:-appwk}"; ENVN=dev
TMP="$(mktemp -d /tmp/wkgl.XXXXXX)"; umask 077
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
say(){ printf '%s\n' "$*"; }
set -a; [ -r ./.env.gitlab-lab ] && . ./.env.gitlab-lab; set +a
TOK="${GITLAB_LAB_TOKEN:-}"
[ -n "$TOK" ] || { say "!! GITLAB_LAB_TOKEN absent : bash scripts/setup-gitlab-lab.sh"; rm -rf "$TMP"; say "RÉSULTAT : 0/1"; exit 1; }
# curl -g : sans lui, les [] d'un `tree=` sont pris pour un glob d'URL (rc 3).
jget(){ curl -sg --max-time 30 "$@"; }
gl(){ curl -s --max-time 30 -H "PRIVATE-TOKEN: $TOK" "$@"; }
jq_(){ python3 -c "import sys,json; d=json.load(sys.stdin); $1" 2>/dev/null || true; }
# git parle au GitLab par Basic oauth2:<PAT> (en-tête, jamais dans l'URL, que
# `ps` montrerait) ; postBuffer parce qu'un push > 1 Mio part en chunked et que
# ce GitLab le refuse alors en 500 (gitaly).
gauth(){ GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'oauth2:%s' "$TOK" | base64 | tr -d '\n')" \
  GIT_CONFIG_KEY_1=http.postBuffer GIT_CONFIG_VALUE_1=524288000 git "$@"; }
CK="$TMP/ck"
jcrumb(){ jget -f -c "$CK" "$J/crumbIssuer/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])'; }
CR="$(jcrumb)" || { say "!! crumbIssuer illisible sur $J"; rm -rf "$TMP"; say "RÉSULTAT : 0/1"; exit 1; }
jpost(){ curl -sg --max-time 60 -b "$CK" -H "$CR" -X POST "$@"; }
# La globale Jenkins, posée par la console de script : un seul knob à la fois,
# et RESTAURÉE en sortie. (setup-jenkins-globals.sh poserait tout le jeu.)
globale(){ # <nom> <valeur | vide pour retirer>
  python3 - "$1" "${2:-}" > "$TMP/g.groovy" <<'PY'
import sys
n, v = sys.argv[1], sys.argv[2]
val = "null" if v == "" else "'%s'" % v
print("""import jenkins.model.Jenkins
import hudson.slaves.EnvironmentVariablesNodeProperty
def j = Jenkins.get(); def gp = j.getGlobalNodeProperties()
def p = gp.get(EnvironmentVariablesNodeProperty)
if (p == null) { p = new EnvironmentVariablesNodeProperty(); gp.add(p) }
def env = p.getEnvVars()
def v = %s
if (v == null) { env.remove('%s') } else { env.put('%s', v) }
j.save(); println('GLOBALE %s = ' + (env.get('%s') ?: '(absente)'))""" % (val, n, n, n, n))
PY
  jpost --data-urlencode "script@$TMP/g.groovy" "$J/scriptText" | tail -1
}
globale_lire(){ # <nom> → valeur, ou vide
  python3 - "$1" > "$TMP/gr.groovy" <<'PY'
import sys
print("""import jenkins.model.Jenkins
import hudson.slaves.EnvironmentVariablesNodeProperty
def p = Jenkins.get().getGlobalNodeProperties().get(EnvironmentVariablesNodeProperty)
println(p == null ? '' : (p.getEnvVars().get('%s') ?: ''))""" % sys.argv[1])
PY
  jpost --data-urlencode "script@$TMP/gr.groovy" "$J/scriptText" | sed -n '1p' | tr -d '\r'
}
jnext(){ jget -f "$J/job/$1/api/json?tree=nextBuildNumber" | jq_ "print(d['nextBuildNumber'])"; }
jresult(){ jget "$J/job/$1/$2/api/json?tree=result,building" | jq_ "print(d.get('result') or ('BUILDING' if d.get('building') else ''))"; }
jconsole(){ jget "$J/job/$1/$2/consoleText"; }
jname(){ jget "$J/job/$1/$2/api/json?tree=displayName" | jq_ "print(d.get('displayName',''))"; }
attendre(){ # <job> <n> [secondes] → résultat ('' si l'échéance passe)
  local dl=$(( $(date +%s) + ${3:-300} )) r
  while [ "$(date +%s)" -lt "$dl" ]; do
    r=$(jresult "$1" "$2"); [ -n "$r" ] && [ "$r" != BUILDING ] && { printf '%s' "$r"; return; }
    sleep 3
  done
  printf '%s' "${r:-}"
}
attendre_pause(){ # <job> <n> [secondes] → rc 0 si la pause nominative est ouverte
  local dl=$(( $(date +%s) + ${3:-300} ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    jget "$J/job/$1/$2/wfapi/pendingInputActions" | grep -q '"id"' && return 0
    case "$(jresult "$1" "$2")" in ''|BUILDING) ;; *) return 1 ;; esac
    sleep 3
  done
  return 1
}
# poser_jobs <WEBHOOK_KIND> [URL du <scm>] : pose les deux jobs. Le second
# argument RE-POINTE le dépôt du job — nécessaire au lab SEULEMENT, parce qu'il
# a DEUX forges et que les job.xml codent l'URL de Gitea en dur. Sans cela,
# l'apply checkoute gitea et cherche le SHA de la MR GitLab dans l'histoire de
# gitea : `MERGE_SHA_NON_ANCETRE`, à juste titre (mesuré le 2026-09-11). Chez un
# client il n'y a qu'une forge, et ce paramètre n'existe pas. Le poseur accepte
# des XML PRÉ-RENDUS par JOBS_SRC_DIR : c'est son mécanisme, pas un contournement.
poser_jobs(){
  local kind="$1" url="${2:-}" src=ci/jenkins d
  if [ -n "$url" ]; then
    d="$TMP/jobs.$kind"; mkdir -p "$d"
    for jx in provision-plan provision-apply; do
      sed "s#<url>[^<]*</url>#<url>${url}</url>#" "ci/jenkins/$jx.job.xml" > "$d/$jx.job.xml"
      grep -qF "<url>$url</url>" "$d/$jx.job.xml" || { say "!! mise en scène de $jx.job.xml sans effet"; return 1; }
    done
    src="$d"
  fi
  # GIT_CREDENTIALS_ID : le checkout que JENKINS fait lui-même est anonyme sans
  # lui, et le dépôt est PRIVÉ — le build mourrait « Authentication failed »
  # avant d'exécuter une ligne du Jenkinsfile (mesuré le 2026-09-11). Sous gwt
  # on ne le pose PAS : le Gitea du lab est en lecture anonyme, et le remettre
  # ferait diverger la config du job de son état nominal.
  # ⚠ DEUX credentials, DEUX types, le même PAT (mesuré le 2026-09-11) :
  #   - le <scm> du JOB est checkouté par Jenkins lui-même ⇒ il exige un COUPLE
  #     username/password (ou une clé SSH). Un « Secret text » y est INUTILISABLE :
  #     le build meurt « Authentication failed » sans autre explication ;
  #   - la chaîne, elle, lit son secret par forgeCreds() et accepte les deux
  #     types (knob FORGE_CRED_KIND).
  local cid=""; [ "$kind" = gitlab ] && cid="$CID_SCM"
  GIT_HOST="$GL" GIT_REPO="$GL_REPO" WEBHOOK_KIND="$kind" JENKINS_UI="$J" JOBS_SRC_DIR="$src" \
  GIT_CREDENTIALS_ID="$cid" \
    bash scripts/setup-provision-jobs.sh > "$TMP/pose.$kind.log" 2>&1
}
HOOKS=""; IID=""; BR="provision/${APP}-${ENVN}"; CLONE="$GL/$GL_REPO.git"
SAVE_WK=""; SAVE_FK=""; SAVE_GH=""; SAVE_GR=""; SAVE_GW=""; SAVE_CID=""; SAVE_GB=""
restaurer(){
  say ""
  say "── Z. nettoyage et restauration ──"
  for h in $HOOKS; do gl -X DELETE "$GL/api/v4/projects/$PID_PROJ/hooks/$h" -o /dev/null; done
  [ -n "$IID" ] && gl -X PUT "$GL/api/v4/projects/$PID_PROJ/merge_requests/$IID" -d state_event=close -o /dev/null
  gauth push -q "$CLONE" --delete "$BR" 2>/dev/null
  globale WEBHOOK_KIND "$SAVE_WK" >/dev/null
  globale FORGE_KIND   "$SAVE_FK" >/dev/null
  globale GIT_HOST     "$SAVE_GH" >/dev/null
  globale GIT_REPO     "$SAVE_GR" >/dev/null
  globale GIT_WEB_HOST "$SAVE_GW" >/dev/null
  globale GITEA_CREDENTIALS_ID "$SAVE_CID" >/dev/null
  globale GIT_BASE "$SAVE_GB" >/dev/null
  if poser_jobs gwt && grep -q '1 trigger GenericTrigger' "$TMP/pose.gwt.log"; then
    say "  ✔ globales restaurées, jobs re-posés sous gwt (amorçage relu)"
  else
    say "  ⚠ RE-POSE SOUS gwt À VÉRIFIER : $(tail -3 "$TMP/pose.gwt.log" 2>/dev/null | tr '\n' ' ')"
  fi
  rm -rf "$TMP"
}
trap restaurer EXIT INT TERM

say "═══ 0. préconditions : les deux récepteurs, la méthode de merge, notre tronc ═══"
P=$(jget "$J/pluginManager/api/json?tree=plugins[shortName]" | jq_ "s={x['shortName'] for x in d['plugins']}; print('oui' if {'gitlab-plugin','generic-webhook-trigger'} <= s else 'non')")
[ "$P" = oui ] && ok "0.1 le Jenkins porte les DEUX récepteurs (gitlab-plugin et generic-webhook-trigger)" \
  || { ko "0.1 il manque un récepteur — bash scripts/spike-webhook-kind-m5.sh"; say "RÉSULTAT : $PASS/$((PASS+FAIL))"; exit 1; }
MM=$(gl "$GL/api/v4/projects/$PID_PROJ" | jq_ "print(d.get('merge_method',''))")
[ "$MM" = merge ] && ok "0.2 $GL_REPO fusionne par MERGE COMMIT (sans quoi merge_commit_sha serait nul et la mesure vide)" \
  || { ko "0.2 merge_method='$MM' — PUT /projects/$PID_PROJ -d merge_method=merge"; say "RÉSULTAT : $PASS/$((PASS+FAIL))"; exit 1; }
BASE=$(gl "$GL/api/v4/projects/$PID_PROJ" | jq_ "print(d['default_branch'])")
[ -n "$BASE" ] && ok "0.3 branche par défaut ANNONCÉE par le projet : '$BASE' (jamais un littéral)" || { ko "0.3 aucune branche par défaut"; exit 1; }
# LE DÉPÔT DOIT ÊTRE PRIVÉ : c'est le cas client, et c'est ce qui a révélé que le
# clone et la découverte de provision-plan.sh n'étaient pas authentifiés. Sur un
# dépôt public, cette suite passerait sans rien prouver de l'authentification.
ANON=$(curl -sg --max-time 15 -o /dev/null -w '%{http_code}' "$GL/$GL_REPO.git/info/refs?service=git-upload-pack")
[ "$ANON" != 200 ] \
  && ok "0.3b le dépôt REFUSE la lecture anonyme (info/refs ⇒ HTTP $ANON) : l'authentification du clone ET de la découverte est réellement éprouvée" \
  || ko "0.3b le dépôt est en lecture ANONYME (info/refs ⇒ 200) — cette suite ne prouverait rien de l'authentification ; le remettre en 'private'"
LOCAL=$(git -C "$REPO/.." rev-parse HEAD 2>/dev/null || git -C "$REPO" rev-parse HEAD)
REMOTE=$(gauth ls-remote "$CLONE" "refs/heads/$BASE" 2>/dev/null | cut -f1)
if [ "$REMOTE" = "$LOCAL" ]; then ok "0.4 $GL_REPO est à notre tronc sur $BASE ($(printf '%s' "$LOCAL" | cut -c1-7))"
else
  gauth -C "$REPO/.." push -q --force "$CLONE" "${LOCAL}:refs/heads/${BASE}" 2>"$TMP/push0.err" \
    && ok "0.4 notre tronc ($(printf '%s' "$LOCAL" | cut -c1-7)) poussé sur $BASE" \
    || { ko "0.4 push impossible : $(head -c 200 "$TMP/push0.err")"; say "RÉSULTAT : $PASS/$((PASS+FAIL))"; exit 1; }
fi
SAVE_WK=$(globale_lire WEBHOOK_KIND); SAVE_FK=$(globale_lire FORGE_KIND)
SAVE_GH=$(globale_lire GIT_HOST);     SAVE_GR=$(globale_lire GIT_REPO)
SAVE_GW=$(globale_lire GIT_WEB_HOST); SAVE_CID=$(globale_lire GITEA_CREDENTIALS_ID)
SAVE_GB=$(globale_lire GIT_BASE)
ok "0.5 globales relevées pour restauration (WEBHOOK_KIND='$SAVE_WK' FORGE_KIND='$SAVE_FK' GIT_HOST='$SAVE_GH' GITEA_CREDENTIALS_ID='$SAVE_CID')"
# Le credential de la forge est un JETON DE FORGE : celui du lab porte un jeton
# GITEA, que l'API de GitLab refuse en 401 — la réconciliation A2 meurt alors,
# après le déclenchement (mesuré le 2026-09-11). Le visage gitlab a donc besoin
# de SON credential ; il est posé ici et RESTAURÉ en sortie.
CID_GL="${CID_GL:-gitlab-provision-token}"      # secret text : pour forgeCreds()
CID_SCM="${CID_SCM:-gitlab-scm-userpass}"       # username/password : pour le <scm> du job
CRED_OK=$(jget "$J/credentials/store/system/domain/_/credential/$CID_GL/api/json" -o /dev/null -w '%{http_code}')
[ "$CRED_OK" = 200 ] && ok "0.6 le credential '$CID_GL' existe (secret text, pour forgeCreds() : sans lui le plan déclenche puis meurt en 401)" \
  || ko "0.6 credential '$CID_GL' absent (HTTP $CRED_OK) — le créer (secret text, PAT GitLab scopes api/read_user/write_repository)"
CRED_SCM_OK=$(jget "$J/credentials/store/system/domain/_/credential/$CID_SCM/api/json" -o /dev/null -w '%{http_code}')
[ "$CRED_SCM_OK" = 200 ] && ok "0.6b le credential '$CID_SCM' existe (username/password, pour le <scm> du job : le Git SCM de Jenkins REFUSE un secret text — « Authentication failed » sans autre explication)" \
  || ko "0.6b credential '$CID_SCM' absent (HTTP $CRED_SCM_OK) — le créer (username 'oauth2', password = le PAT)"

say ""
say "═══ 1. le visage gitlab : globales, webhooks de projet, jobs amorcés ═══"
globale WEBHOOK_KIND gitlab >/dev/null; globale FORGE_KIND gitlab >/dev/null
globale GIT_HOST "$GLIN" >/dev/null;    globale GIT_REPO "$GL_REPO" >/dev/null
globale GIT_WEB_HOST "$GL" >/dev/null
globale GITEA_CREDENTIALS_ID "$CID_GL" >/dev/null
# LA DÉCOUVERTE N'EST PLUS CONTOURNÉE (ec6ebfd, 2026-09-11). Ce harnais posait
# `GIT_BASE` parce que, sur un GitLab PRIVÉ, la découverte de la branche par
# défaut tournait hors de l'enveloppe d'authentification et mourait
# « could not read Username » (`BRANCHE_PAR_DEFAUT_INCONNUE`), comme le clone
# mourait `CLONE_ECHEC`. Depuis le correctif, les deux gestes portent
# l'enveloppe : on laisse donc `GIT_BASE` ABSENTE, et la découverte sur dépôt
# privé DEVIENT une assertion de cette suite. Le knob `WKGL_POSE_GIT_BASE=1`
# remet l'ancien contournement, pour éprouver une chaîne antérieure.
if [ "${WKGL_POSE_GIT_BASE:-0}" = 1 ]; then
  globale GIT_BASE "$BASE" >/dev/null
  say "  (WKGL_POSE_GIT_BASE=1 : GIT_BASE posée à '$BASE' — la découverte n'est PAS éprouvée)"
else
  globale GIT_BASE "" >/dev/null
fi
[ "$(globale_lire WEBHOOK_KIND)" = gitlab ] && ok "1.1 globales du visage gitlab posées (WEBHOOK_KIND=gitlab, FORGE_KIND=gitlab, GIT_HOST=$GLIN, GITEA_CREDENTIALS_ID=$CID_GL) ; GIT_BASE laissée ABSENTE : la DÉCOUVERTE sur dépôt privé est éprouvée, plus contournée" || ko "1.1 globale non posée"
for h in $(gl "$GL/api/v4/projects/$PID_PROJ/hooks" | jq_ "print(' '.join(str(x['id']) for x in d if '/project/provision-' in x['url']))"); do
  gl -X DELETE "$GL/api/v4/projects/$PID_PROJ/hooks/$h" -o /dev/null
done
hook(){ gl -X POST "$GL/api/v4/projects/$PID_PROJ/hooks" -d "url=$1" -d "token=$2" \
        -d merge_requests_events=true -d push_events=false -d enable_ssl_verification=false | jq_ "print(d.get('id',''))"; }
H1=$(hook "$JIN/project/provision-plan" stoa-provision-plan)
H2=$(hook "$JIN/project/provision-apply" stoa-provision-apply)
HOOKS="$H1 $H2"
{ [ -n "$H1" ] && [ -n "$H2" ]; } && ok "1.2 deux webhooks de projet ($HOOKS) : « Merge request events » SEULEMENT, Secret Token = le mot du job" || ko "1.2 webhooks non posés : [$HOOKS]"
# ⚠ L'URL du <scm> est celle que voit l'AGENT (réseau docker), jamais celle du
# poste : un `http://localhost:13080/...` dans le job donne « Could not connect
# to server » côté conteneur (mesuré le 2026-09-11). Split-horizon du lab.
poser_jobs gitlab "$GLIN/$GL_REPO.git"
{ [ "$(grep -c '1 trigger GitLabPushTrigger' "$TMP/pose.gitlab.log")" = 2 ] && [ "$(grep -c 'amorçage #' "$TMP/pose.gitlab.log")" = 2 ]; } \
  && ok "1.3 provision-plan et provision-apply re-posés (dépôt du job = $GLIN/$GL_REPO.git, credential du <scm> = $CID_GL : le lab a DEUX forges, un client n'en a qu'une), amorçage ATTENDU et RELU : 1 GitLabPushTrigger + 1 verrou chacun" \
  || ko "1.3 pose/amorçage : $(grep -E 'AMORCAGE|amorçage|relecture' "$TMP/pose.gitlab.log" | tr '\n' ' ' | cut -c1-300)"
NG=$(jget "$J/job/provision-apply/config.xml" | grep -c 'GenericTrigger')
[ "$NG" = 0 ] && ok "1.4 aucun GenericTrigger résiduel sur provision-apply : un seul récepteur à la fois" || ko "1.4 $NG GenericTrigger encore présent(s)"

say ""
say "═══ 2. la demande ouvre la MR ⇒ PLAN par le plugin, commenté sur la MR ═══"
gauth push -q "$CLONE" --delete "$BR" 2>/dev/null
SVC=$(env -i PATH="$PATH" HOME="$HOME" FORGE_KIND=gitlab GIT_HOST="$GL" GIT_REPO="$GL_REPO" FORGE_SECRET="$TOK" \
      bash -c '. scripts/lib/forge-api.sh && forge_api_init && forge whoami' 2>/dev/null | sed -n 's/^LOGIN=//p')
[ -n "$SVC" ] && ok "2.0 le PAT de service se présente comme '$SVC'" || ko "2.0 whoami muet (le PAT de .env.gitlab-lab ne répond pas)"
NP=$(jnext provision-plan)
( cd "$REPO" && env -i PATH="$PATH" HOME="$HOME" \
    FORGE_KIND=gitlab FORGE_API_AUTH=private-token FORGE_SECRET="$TOK" \
    GIT_HOST="$GL" GIT_WEB_HOST="$GL" GIT_REPO="$GL_REPO" GIT_SUBDIR="$(basename "$REPO")" \
    GIT_CLONE_URL="$CLONE" GIT_PUSH_URL="$CLONE" \
    STOA_ENV_CHAIN_FILE="$REPO/clients/_example/environments.yaml" PROVISION_PLAN_INLINE=false \
    REQ_APP="$APP" REQ_ENV="$ENVN" REQ_API=demo-selfservice REQ_API_VER=1.0.0 REQ_CLIENT_ID="${APP}-${ENVN}" \
    REQ_CALLER=jenkins-form:x REQ_TEAM=banking-demo GITEA_SERVICE_LOGINS="$SVC" \
    bash scripts/provision-request.sh ) > "$TMP/req.out" 2>&1
IID=$(grep -oE 'PR (créée|déjà ouverte): #[0-9]+' "$TMP/req.out" | grep -oE '[0-9]+$' | head -1)
[ -n "$IID" ] && ok "2.1 MR !$IID ouverte par provision-request.sh (branche $BR)" \
  || { ko "2.1 aucune MR : $(grep -E 'REFUS|ERREUR' "$TMP/req.out" | tail -2 | tr '\n' ' ' | cut -c1-250)"; say "RÉSULTAT : $PASS/$((PASS+FAIL))"; exit 1; }
R=$(attendre provision-plan "$NP" 300)
[ "$R" = SUCCESS ] && ok "2.2 le PLUGIN a déclenché le plan : build #$NP $R" || ko "2.2 plan #$NP : ${R:-jamais déclenché (webhook non reçu ? alert_status du hook ?)}"
N1=$(jname provision-plan "$NP")
[ "$N1" = "plan $APP/$ENVN (PR #$IID)" ] && ok "2.3 build nommé « $N1 » : le fait unifié vient des variables gitlab*" || ko "2.3 build nommé « $N1 »"
# Le GitLab Plugin n'a PAS d'équivalent de `printContributedVariables` : ses
# variables ne sont jamais ÉCHOUÉES dans la console (assertion fausse du premier
# jet, 2026-09-11). Ce qui se mesure, c'est le FAIT UNIFIÉ qu'elles ont produit :
# `action=merge_request:opened` ne peut venir que de gitlabMergeRequestState —
# le GWT aurait écrit `merge_request:open` (l'ACTION, que ce plugin n'expose pas).
jconsole provision-plan "$NP" | grep -q "Demande OUVERTE — application=$APP env=$ENVN action=merge_request:opened" \
  && ok "2.4 le fait unifié vient de l'ÉTAT relu (« action=merge_request:opened ») : c'est la signature du troisième visage, le GWT aurait dit « merge_request:open »" \
  || ko "2.4 fait unifié absent/divergent : $(jconsole provision-plan "$NP" | grep -m1 'Demande OUVERTE' | cut -c1-160)"
sleep 5
gl "$GL/api/v4/projects/$PID_PROJ/merge_requests/$IID/notes" | jq_ "import sys; sys.exit(0 if any('plan' in (n.get('body') or '').lower() for n in d) else 1)" \
  && ok "2.5 un commentaire de plan est posé sur la MR (comment_upsert, sous l'identité de forge)" \
  || ko "2.5 aucun commentaire de plan sur la MR"

say ""
say "═══ 3. un nouveau commit rejoue le plan (parité mesurée avec le GWT) ═══"
NP=$(jnext provision-plan)
# ⚠ Un commit qui AJOUTE un fichier ferait refuser l'apply plus loin
# (PR_HORS_PERIMETRE : l'aval checkoute l'arbre entier au SHA mergé et n'accepte
# que le manifeste et son certificat — mesuré le 2026-09-11). Un commit VIDE
# change le SHA sans toucher un octet : c'est exactement ce qu'on veut éprouver.
W="$TMP/w"; gauth clone -q --depth 1 -b "$BR" "$CLONE" "$W" 2>/dev/null \
  && { git -C "$W" -c user.name=wk -c user.email=wk@lab commit -q --allow-empty -m "wk : nouveau SHA, aucun fichier touché"
       gauth -C "$W" push -q "$CLONE" "$BR"; }
R=$(attendre provision-plan "$NP" 300)
[ "$R" = SUCCESS ] && ok "3.1 push d'un commit ⇒ plan rejoué (build #$NP $R)" || ko "3.1 push ⇒ ${R:-aucun build}"

say ""
say "═══ 4. la fusion ⇒ APPLY jusqu'à la pause, MERGE_SHA == l'API ═══"
NA=$(jnext provision-apply)
gl -X PUT "$GL/api/v4/projects/$PID_PROJ/merge_requests/$IID/merge" -o "$TMP/merge.json"
SHA=$(jq_ "print(d.get('merge_commit_sha') or '')" < "$TMP/merge.json")
[ "${#SHA}" = 40 ] && ok "4.1 MR !$IID fusionnée, merge_commit_sha = $SHA" || ko "4.1 fusion : $(head -c 200 "$TMP/merge.json")"
IID=""   # fusionnée : plus rien à fermer en Z
if attendre_pause provision-apply "$NA" 420; then
  ok "4.2 le PLUGIN a déclenché l'apply sur la FUSION (build #$NA), arrêté à la pause NOMINATIVE"
else
  ko "4.2 apply #$NA : $(jresult provision-apply "$NA") — $(jconsole provision-apply "$NA" | grep -m1 'REFUS' | cut -c1-200)"
fi
jconsole provision-apply "$NA" | grep -q "merge_sha=$SHA" \
  && ok "4.3 MERGE_SHA du build == merge_commit_sha de l'API : la référence A2 survit au changement de récepteur" \
  || ko "4.3 MERGE_SHA divergent : $(jconsole provision-apply "$NA" | grep -m1 'merge_sha=' | cut -c1-160)"
jconsole provision-apply "$NA" | grep -qE 'RECONCILE|[Rr]éconcili|provision-apply-reconcile|forge a CONFIRM' \
  && ok "4.4 la réconciliation a relu la forge : le payload du plugin ne fait pas foi non plus" \
  || ko "4.4 aucune trace de réconciliation dans la console"
AB=$(jget "$J/job/provision-apply/$NA/wfapi/pendingInputActions" | jq_ "print(d[0]['abortUrl'] if d else '')")
[ -n "$AB" ] && jpost "$J$AB" -o /dev/null && ok "4.5 pause ABANDONNÉE : ce harnais ne déploie rien (lab partagé)" || ko "4.5 pause non abandonnée (abortUrl=[$AB])"

say ""
say "═══ 5. contre-épreuves : close muet, token exigé, retour à gwt ═══"
NA=$(jnext provision-apply); NP=$(jnext provision-plan)
BR2="provision/${APP}2-${ENVN}"
if gauth clone -q --depth 1 -b "$BASE" "$CLONE" "$TMP/w2" 2>/dev/null; then
  git -C "$TMP/w2" checkout -q -b "$BR2"; printf 'x\n' > "$TMP/w2/.wk2.txt"; git -C "$TMP/w2" add .wk2.txt
  git -C "$TMP/w2" -c user.name=wk -c user.email=wk@lab commit -qm wk2
  gauth -C "$TMP/w2" push -q "$CLONE" "$BR2"
  I2=$(gl -X POST "$GL/api/v4/projects/$PID_PROJ/merge_requests" -d source_branch="$BR2" -d target_branch="$BASE" -d title="wk2" | jq_ "print(d.get('iid',''))")
  sleep 12
  gl -X PUT "$GL/api/v4/projects/$PID_PROJ/merge_requests/$I2" -d state_event=close -o /dev/null
  sleep 15
  [ "$(jnext provision-apply)" = "$NA" ] && ok "5.1 une MR FERMÉE SANS FUSION ne déclenche AUCUN apply (la porte du visage gitlab est la case, pas une regex)" || ko "5.1 un close a déclenché l'apply"
  gl -X PUT "$GL/api/v4/projects/$PID_PROJ/merge_requests/$I2" -d state_event=close -o /dev/null
  gauth push -q "$CLONE" --delete "$BR2" 2>/dev/null
else ko "5.1 impossible de préparer la MR jetable de contre-épreuve"; fi
HC=$(curl -sg --max-time 30 -o /dev/null -w '%{http_code}' -X POST \
  -H 'X-Gitlab-Event: Merge Request Hook' -H 'Content-Type: application/json' \
  -d '{"object_kind":"merge_request","object_attributes":{"iid":999999,"state":"merged","action":"merge","source_branch":"provision/x-dev","target_branch":"'"$BASE"'"}}' \
  "$J/project/provision-apply")
case "$HC" in 401|403) ok "5.2 POST /project/provision-apply SANS X-Gitlab-Token ⇒ HTTP $HC : la sonnette exige le mot";; *) ko "5.2 sans token ⇒ HTTP $HC (attendu 401/403)";; esac
globale WEBHOOK_KIND gwt >/dev/null; globale FORGE_KIND "$SAVE_FK" >/dev/null
poser_jobs gwt
[ "$(grep -c '1 trigger GenericTrigger' "$TMP/pose.gwt.log")" = 2 ] \
  && ok "5.3 retour WEBHOOK_KIND=gwt : les deux jobs reposent 1 GenericTrigger ($(jget "$J/job/provision-plan/config.xml" | grep -c GitLabPushTrigger) GitLabPushTrigger résiduel)" \
  || ko "5.3 retour gwt : $(grep -E 'AMORCAGE|relecture' "$TMP/pose.gwt.log" | tr '\n' ' ' | cut -c1-200)"
NP=$(jnext provision-plan)
HC=$(curl -sg --max-time 30 -o /dev/null -w '%{http_code}' -X POST \
  -H 'X-Gitlab-Token: stoa-provision-plan' -H 'X-Gitlab-Event: Merge Request Hook' -H 'Content-Type: application/json' \
  -d '{"object_kind":"merge_request","object_attributes":{"iid":1,"state":"opened","action":"open","source_branch":"provision/x-dev","target_branch":"'"$BASE"'"}}' \
  "$J/project/provision-plan")
sleep 10
[ "$(jnext provision-plan)" = "$NP" ] && ok "5.4 sous gwt, /project/provision-plan est MUET (HTTP $HC, aucun build) : un récepteur à la fois, et son silence est mesuré" || ko "5.4 /project/ a construit sous gwt"

say ""
say "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
