#!/usr/bin/env bash
# test-a0-wiring.sh — preuve X/X du jalon A0 (GOAL cd-applications) : TOUT EN
# JENKINSFILE. Analyse statique + épreuves fonctionnelles HORS LIGNE : ni
# Jenkins, ni Gitea réels.
#
# ── CE QUE CE TEST DÉFEND ────────────────────────────────────────────────────
# Les trois jobs de l'aval applicatif (provision-apply, provision-plan,
# provisioning-request) et le formulaire app-request ne portent PLUS une ligne
# de Groovy dans leur job.xml : chaque XML est une COQUILLE « Pipeline from
# SCM » (pointeur + miroir des triggers), le pipeline vit dans ci/Jenkinsfile.*
# (compilé par `make lint-ci`), et le formulaire d'app-request est POSÉ par son
# Jenkinsfile (properties([parameters([…])])) depuis des listes dérivées du
# dépôt — plus aucun paramètre dans le XML, plus aucun marqueur substitué à la
# pose.
#
# Quatre faits mesurés sur ce lab (2026-08-06, 2026-09-02) gouvernent ce que le
# test exige : (1) le <triggers> du XML GAGNE sur le Jenkinsfile — d'où le
# miroir structuré (scripts/lib/gwt-mirror.sh) sur les trois jobs à webhook ;
# (2) un paramètre de build subit EnvVars.resolve() — d'où la ré-injection
# brute withEnv([params…]) conservée ; (3) re-poser le XML EFFACE les
# paramètres posés par un build — d'où le build d'amorçage câblé dans la pose ;
# (4) un build sur un job sans paramètre lie ZÉRO paramètre — d'où le signal
# d'amorçage capturé AVANT properties().
#
# Motif anti « vert vacant » : les ancres portent sur une vue CODE des
# Jenkinsfile (lignes `//` blanchies, numérotation conservée) ; les ORDRES sont
# vérifiés par numéros de ligne ; les mutations (§8) prouvent que le miroir
# ROUGIT quand on retire ou altère le bloc <triggers>.
#
#   ./scripts/test-a0-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 2
TMP="$(mktemp -d /tmp/a0wiring.XXXXXX)"; STUB_PID=""; FAKE_PID=""
trap '{ [ -n "$STUB_PID" ] && kill "$STUB_PID" && wait "$STUB_PID"; [ -n "$FAKE_PID" ] && kill "$FAKE_PID" && wait "$FAKE_PID"; } 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# Total ATTENDU, ÉCRIT EN DUR — indépendant de PASS+FAIL. Toute section
# ajoutée/retirée DOIT le mettre à jour : un oubli fait rougir le dernier §.
EXPECTED_CHECKS=184

# shellcheck source=scripts/lib/gwt-mirror.sh
. scripts/lib/gwt-mirror.sh || { echo "lib gwt-mirror.sh introuvable"; exit 2; }

# Vue CODE d'un Jenkinsfile : commentaires `//` blanchis (ligne vide), lignes
# `#` d'un shell embarqué aussi ; numérotation conservée.
code_view(){ sed -E 's@^[[:space:]]*(//|#).*$@@' "$1"; }
code_line(){ grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }   # $1=vue code $2=motif → n° de ligne

JOBS_SCM="provision-apply provision-plan provisioning-request app-request"

echo "== 1. les QUATRE XML sont des coquilles « Pipeline from SCM » : zéro Groovy =="
for J in $JOBS_SCM; do
  X="ci/jenkins/$J.job.xml"
  if [ ! -f "$X" ]; then ko "$J : XML introuvable ($X)"; ko "$J : (from SCM non vérifiable)"; ko "$J : (pointeur non vérifiable)"; continue; fi
  python3 -c "import xml.etree.ElementTree as T; T.parse('$X')" 2>/dev/null \
    && ok "$J : XML parsable" || ko "$J : XML cassé"
  # STRUCTUREL (ElementTree), jamais textuel : les en-têtes XML de ce dépôt
  # CITENT « <script> » et « <sandbox> » dans leurs commentaires — un grep nu
  # rougirait sur un commentaire (mesuré en écrivant ce test).
  RES=$(python3 - "$X" <<'PY'
import sys, xml.etree.ElementTree as T
r = T.parse(sys.argv[1]).getroot()
d = r.find('definition'); pb = []
if d is None or d.get('class') != 'org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition': pb.append('pas-CpsScmFlowDefinition')
if d is not None and d.get('class') == 'org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition': pb.append('CpsFlowDefinition-residuelle')
if r.find('.//script') is not None: pb.append('<script>-present')
if r.find('.//sandbox') is not None: pb.append('<sandbox>-present')
print(' '.join(pb))
PY
)
  [ -z "$RES" ] && ok "$J : Pipeline from SCM — aucun élément <script>, aucune CpsFlowDefinition, aucun <sandbox> (structurel)" \
                || ko "$J : encore du Groovy inline : $RES"
  RES=""
  grep -qF "<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.$J</scriptPath>" "$X" || RES="$RES scriptPath"
  grep -qF '<lightweight>false</lightweight>' "$X" || RES="$RES lightweight"
  grep -qF '<url>http://gitea:3000/ci/stoa-labs.git</url>' "$X" || RES="$RES url"
  grep -qF '<name>*/main</name>' "$X" || RES="$RES branche"
  [ -z "$RES" ] && ok "$J : pointeur SCM complet (scriptPath ci/Jenkinsfile.$J, lightweight=false, gitea main)" \
                || ko "$J : pointeur SCM incomplet :$RES"
done

echo
echo "== 2. le MIROIR XML/Jenkinsfile des triggers, par la lib, sur les TROIS jobs à webhook (+ app-request sans trigger) =="
shellcheck -x scripts/lib/gwt-mirror.sh >/dev/null 2>&1 \
  && ok "scripts/lib/gwt-mirror.sh : shellcheck propre" || ko "scripts/lib/gwt-mirror.sh : shellcheck en échec"
mirror_expect(){ # $1=job $2=nb de clés attendu
  local out rc
  out=$(gwt_mirror_diff "ci/jenkins/$1.job.xml" "ci/Jenkinsfile.$1" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^MIROIR_OK'; then
    ok "$1 : $out"
  else
    ko "$1 : miroir NON exact (rc=$rc) — $(printf '%s' "$out" | tr '\n' ' ')"
  fi
  printf '%s' "$out" | grep -q "vars=$2\$" \
    && ok "$1 : $2 genericVariables, à l'identique des deux côtés" \
    || ko "$1 : nombre de genericVariables inattendu (attendu $2) — $(printf '%s' "$out" | tr '\n' ' ')"
}
mirror_expect provision-apply 7
mirror_expect provision-plan 3
mirror_expect provisioning-request 7
OUT=$(gwt_mirror_diff ci/jenkins/app-request.job.xml ci/Jenkinsfile.app-request 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "AUCUN_TRIGGER" ] \
  && ok "app-request : AUCUN trigger des deux côtés (formulaire humain, <triggers/> vide)" \
  || ko "app-request : un déclencheur est apparu d'un côté (rc=$RC : $OUT)"

echo
echo "== 3. ci/Jenkinsfile.provision-plan : parité stricte avec le Groovy d'origine, sans exécuteur pour rien =="
JFP="ci/Jenkinsfile.provision-plan"; code_view "$JFP" > "$TMP/jf-plan.code"
jfp(){ grep -qF -- "$1" "$TMP/jf-plan.code"; }
grep -qE '^pipeline \{' "$JFP" && grep -qE '^  agent none' "$TMP/jf-plan.code" \
  && ok "déclaratif, \`agent none\` au niveau pipeline (la PR étrangère n'alloue rien)" || ko "pas déclaratif / agent none absent au niveau pipeline"
jfp 'disableConcurrentBuilds()' && ok "options { disableConcurrentBuilds() } — miroir de la propriété du XML" || ko "disableConcurrentBuilds absent (le XML l'a : divergence)"
jfp "regexpFilterExpression: '^(opened|reopened|synchronized)\$'" && jfp "regexpFilterText: '\$PR_ACTION'" \
  && ok "filtre GWT exact : \$PR_ACTION ~ ^(opened|reopened|synchronized)\$ (jamais la fermeture)" || ko "filtre GWT inattendu"
jfp 'beforeAgent true' && jfp "expression { (env.PR_BRANCH ?: '').startsWith('provision/') }" \
  && ok "garde provision/* AVANT l'agent (beforeAgent true)" || ko "garde provision/* ou beforeAgent absents"
L_WHEN=$(code_line "$TMP/jf-plan.code" 'beforeAgent true'); L_AG=$(awk "NR>${L_WHEN:-0} && /^ *agent any/ {print NR; exit}" "$TMP/jf-plan.code")
[ -n "$L_WHEN" ] && [ -n "$L_AG" ] && ok "le stage de plan a son propre \`agent any\` (ligne $L_AG) après la garde (ligne $L_WHEN)" || ko "agent any du stage de plan introuvable après la garde"
L_SH=$(code_line "$TMP/jf-plan.code" "sh 'set +x; rm -f \"\$WORKSPACE/.plan.facts\"; PLAN_FACTS=\"\$WORKSPACE/.plan.facts\" bash scripts/provision-plan.sh'")
[ -n "$L_SH" ] && ok "scripts/provision-plan.sh invoqué en quotes SIMPLES avec set +x, purge puis PLAN_FACTS (ligne $L_SH)" || ko "invocation du script absente ou en quotes doubles"
L_WC=$(code_line "$TMP/jf-plan.code" "withCredentials([string(credentialsId: env.GITEA_CREDENTIALS_ID, variable: 'GITEA_TOKEN')])")
L_DIR=$(code_line "$TMP/jf-plan.code" "dir(env.GIT_SUBDIR)")
[ -n "$L_WC" ] && [ -n "$L_DIR" ] && [ -n "$L_SH" ] && [ "$L_WC" -lt "$L_DIR" ] && [ "$L_DIR" -lt "$L_SH" ] \
  && ok "ordre withCredentials ($L_WC) < dir ($L_DIR) < sh ($L_SH) : token présent, chemins relatifs justes" || ko "ordre withCredentials/dir/sh cassé (wc=$L_WC dir=$L_DIR sh=$L_SH)"
MISS=""
jfp "GIT_WEB_HOST         = \"\${env.GIT_WEB_HOST ?: 'http://localhost:13000'}\"" || MISS="$MISS GIT_WEB_HOST"
jfp "GITEA_CREDENTIALS_ID = \"\${env.GITEA_CREDENTIALS_ID ?: 'gitea-provision-token'}\"" || MISS="$MISS GITEA_CREDENTIALS_ID"
jfp "GIT_HOST             = \"\${env.GIT_HOST ?: 'http://gitea:3000'}\"" || MISS="$MISS GIT_HOST"
jfp "GIT_REPO             = \"\${env.GIT_REPO ?: 'ci/stoa-labs'}\"" || MISS="$MISS GIT_REPO"
[ -z "$MISS" ] && ok "points de config (défauts = ceux du Groovy : GIT_WEB_HOST localhost:13000, credential gitea-provision-token)" || ko "points de config absents/divergents :$MISS"
BAD=""
jfp 'git url:' && BAD="$BAD git-url"; grep -qE '^\s*parameters \{' "$TMP/jf-plan.code" && BAD="$BAD parameters{}"
grep -q 'sh """' "$TMP/jf-plan.code" && BAD="$BAD sh-triple-double"; grep -qE '\binput\b' "$TMP/jf-plan.code" && BAD="$BAD input"
# try/catch : autorisé UNIQUEMENT dans le post{} de pipeline (statut de build, A0 dettes — §9e) ; jamais dans les stages.
L_POST3=$(grep -n '^  post {' "$TMP/jf-plan.code" | head -1 | cut -d: -f1)
awk "NR<${L_POST3:-999999}" "$TMP/jf-plan.code" | grep -qE '^\s*(try \{|\} catch)' && BAD="$BAD try/catch-hors-post"
[ -z "$BAD" ] && ok "aucun git url:, parameters{}, sh \"\"\", input ; try/catch seulement dans le post" || ko "présent(s) :$BAD"
jfp 'currentBuild.displayName = "plan ${app}/${envn} (PR #' && ok "le build est nommé « plan <app>/<env> (PR #n) »" || ko "displayName absent/divergent"
[ -x scripts/provision-plan.sh ] && bash -n scripts/provision-plan.sh 2>/dev/null && ok "scripts/provision-plan.sh existe, exécutable, parsable" || ko "scripts/provision-plan.sh absent ou cassé"
grep -q 'bash scripts/provision-plan.sh' "$TMP/jf-plan.code" && [ "$(grep -c 'provision-plan.sh' "$TMP/jf-plan.code")" -eq 1 ] \
  && ok "le moteur est invoqué UNE fois : le pipeline route, la substance reste dans scripts/" || ko "invocations du moteur : $(grep -c 'provision-plan.sh' "$TMP/jf-plan.code")"

echo
echo "== 4. ci/Jenkinsfile.provisioning-request : la voie machine, sans un seul champ listé =="
JFR="ci/Jenkinsfile.provisioning-request"; code_view "$JFR" > "$TMP/jf-req.code"
jfr(){ grep -qF -- "$1" "$TMP/jf-req.code"; }
grep -qE '^pipeline \{' "$JFR" && grep -qE '^  agent any' "$TMP/jf-req.code" \
  && ok "déclaratif, \`agent any\` au niveau pipeline (aucune pause, travaille dès le départ)" || ko "pas déclaratif / agent any absent"
jfr 'disableConcurrentBuilds' && ko "disableConcurrentBuilds présent — PARITÉ rompue (le XML d'origine n'en avait pas)" || ok "pas de disableConcurrentBuilds (parité : deux demandes visent deux branches)"
jfr "token: 'stoa-provision-request'" && jfr "printPostContent: true" && ! jfr "regexpFilterExpression" \
  && ok "token stoa-provision-request, printPostContent: true, SANS filtre (parité)" || ko "token/printPostContent/filtre divergents du Groovy d'origine"
MISS=""
for KV in "REQ_APP:\$.app" "REQ_ENV:\$.env" "REQ_CLIENT_ID:\$.clientId" "REQ_API:\$.api" "REQ_API_VER:\$.apiVersion" "REQ_AUDIENCE:\$.audience" "REQ_CALLER:\$.caller"; do
  K="${KV%%:*}"; V="${KV#*:}"
  grep -qE "\[key: '$K', *value: '\\$V'\]" "$TMP/jf-req.code" || MISS="$MISS $K"
done
[ -z "$MISS" ] && ok "les 7 clés REQ_* pointent les chemins JSON du contrat machine (\$.app … \$.caller)" || ko "clés absentes/divergentes :$MISS"
L_SH=$(code_line "$TMP/jf-req.code" "sh 'set +x; bash scripts/provision-request.sh'")
[ -n "$L_SH" ] && ok "scripts/provision-request.sh invoqué en quotes SIMPLES avec set +x (ligne $L_SH)" || ko "invocation du script absente ou en quotes doubles"
L_WC=$(code_line "$TMP/jf-req.code" "withCredentials([string(credentialsId: env.GITEA_CREDENTIALS_ID, variable: 'GITEA_TOKEN')])")
L_DIR=$(code_line "$TMP/jf-req.code" "dir(env.GIT_SUBDIR)")
[ -n "$L_WC" ] && [ -n "$L_DIR" ] && [ -n "$L_SH" ] && [ "$L_WC" -lt "$L_DIR" ] && [ "$L_DIR" -lt "$L_SH" ] \
  && ok "ordre withCredentials ($L_WC) < dir ($L_DIR) < sh ($L_SH)" || ko "ordre withCredentials/dir/sh cassé (wc=$L_WC dir=$L_DIR sh=$L_SH)"
if jfr 'withEnv(' || jfr 'params.'; then
  ko "withEnv( ou params. présents — la voie machine ne doit lister AUCUN champ (elle hérite du script)"
else
  ok "aucun withEnv(, aucun params. : la voie machine n'énumère aucun champ, elle hérite de tout enrichissement du script"
fi
BAD=""
jfr 'git url:' && BAD="$BAD git-url"; grep -qE '^\s*parameters \{' "$TMP/jf-req.code" && BAD="$BAD parameters{}"
grep -q 'sh """' "$TMP/jf-req.code" && BAD="$BAD sh-triple-double"; grep -qE '^\s*(try \{|\} catch)' "$TMP/jf-req.code" && BAD="$BAD try/catch"
[ -z "$BAD" ] && ok "aucun git url:, parameters{}, sh \"\"\", try/catch" || ko "présent(s) :$BAD"
MISS=""
jfr "GITEA_CREDENTIALS_ID = \"\${env.GITEA_CREDENTIALS_ID ?: 'gitea-provision-token'}\"" || MISS="$MISS GITEA_CREDENTIALS_ID"
jfr "GIT_HOST             = \"\${env.GIT_HOST ?: 'http://gitea:3000'}\"" || MISS="$MISS GIT_HOST"
jfr "GIT_REPO             = \"\${env.GIT_REPO ?: 'ci/stoa-labs'}\"" || MISS="$MISS GIT_REPO"
[ -z "$MISS" ] && ok "points de config (défauts = ceux du script)" || ko "points de config absents/divergents :$MISS"
jfr 'currentBuild.displayName = "demande ${env.REQ_APP' && ok "le build est nommé « demande <app>/<env> (<caller>) »" || ko "displayName absent/divergent"
[ -x scripts/provision-request.sh ] && bash -n scripts/provision-request.sh 2>/dev/null && ok "scripts/provision-request.sh existe, exécutable, parsable" || ko "scripts/provision-request.sh absent ou cassé"
[ "$(grep -c 'provision-request.sh' "$TMP/jf-req.code")" -eq 1 ] && ok "le moteur est invoqué UNE fois" || ko "invocations du moteur : $(grep -c 'provision-request.sh' "$TMP/jf-req.code")"

echo
echo "== 6. scripts/app-request-choices.sh — les listes du formulaire, HORS LIGNE (bare repos = Gitea, chaîne de test), fail-closed =="
CH="scripts/app-request-choices.sh"
[ -x "$CH" ] && shellcheck -x "$CH" >/dev/null 2>&1 && ok "app-request-choices.sh : exécutable, shellcheck propre" || ko "app-request-choices.sh : absent, non exécutable ou shellcheck en échec"
# « Gitea » local : un bare repo servi comme chemin fichier (motif test-generate-choices.sh).
mk_platform(){ # $1=racine bare $2=providers.dev.yml
  local bare="$1" src="$TMP/src-$RANDOM"
  mkdir -p "$src/poc-control-plane-federation/ansible" "$src/poc-control-plane-federation/clients/_example/apis"
  printf '%s' "$2" > "$src/poc-control-plane-federation/ansible/providers.dev.yml"
  printf 'apim_api:\n  name: accounts-read\n  version: 1.0.0\n' > "$src/poc-control-plane-federation/clients/_example/apis/accounts-read.publish.yml"
  ( cd "$src" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A && git -c user.name=t -c user.email=t commit -qm init >/dev/null )
  mkdir -p "$(dirname "$bare")"; git clone -q --bare "$src" "$bare" >/dev/null
}
PROV_OK=$'providers:\n  - team: banking-demo\n    repo: acme/depot-absent\n    approvers: []\n  - team: payments-team\n    repo: ""\n    approvers: []\n  - team: banking-demo\n    repo: ""\n    approvers: []\n'
PROV_EMPTY=$'providers: []\n'
GH6="$TMP/gitea6"; mk_platform "$GH6/ci/stoa-labs.git" "$PROV_OK"
printf 'environments: [dev, rec, prod]\n' > "$TMP/chain6.yaml"
run_choices(){ # $1=gitea root $2=chain file $3=out file (vide = non posé)
  if [ -n "$3" ]; then
    CHOICES_OUT="$3" STOA_ENV_CHAIN_FILE="$2" GIT_HOST="$1" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy bash "$CH" >"$TMP/ch.out" 2>"$TMP/ch.err"
  else
    STOA_ENV_CHAIN_FILE="$2" GIT_HOST="$1" GIT_REPO=ci/stoa-labs GITEA_TOKEN=dummy bash "$CH" >"$TMP/ch.out" 2>"$TMP/ch.err"
  fi
}
OUT6="$TMP/choices6.env"; rm -f "$OUT6"
run_choices "$GH6" "$TMP/chain6.yaml" "$OUT6"; RC=$?
[ "$RC" -eq 0 ] && [ -f "$OUT6" ] && [ "$(wc -l < "$OUT6" | tr -d ' ')" -eq 3 ] \
  && ok "nominal : rc 0, fichier de TROIS lignes écrit" || ko "nominal : rc=$RC, fichier=$([ -f "$OUT6" ] && wc -l < "$OUT6" || echo absent) — $(cat "$TMP/ch.err" 2>/dev/null | tail -3)"
grep -qx 'ENVS=dev rec prod' "$OUT6" 2>/dev/null && ok "ENVS=dev rec prod — la chaîne ENTIÈRE, terminus COMPRIS (A7 : gardé par ses portes, plus exclu par structure)" || ko "ENVS inattendu : $(grep '^ENVS=' "$OUT6" 2>/dev/null)"
grep -qx 'TEAMS=banking-demo payments-team' "$OUT6" 2>/dev/null && ok "TEAMS=banking-demo payments-team — ordre de déclaration, doublon exact écarté" || ko "TEAMS inattendu : $(grep '^TEAMS=' "$OUT6" 2>/dev/null)"
grep -qx 'APIS=accounts-read@1.0.0' "$OUT6" 2>/dev/null && ok "APIS=accounts-read@1.0.0 — nom@version des publish.yml relus" || ko "APIS inattendu : $(grep '^APIS=' "$OUT6" 2>/dev/null)"
grep -q '^CHOICES_SKIPPED_REPOS=1$' "$TMP/ch.err" && ok "marqueur CHOICES_SKIPPED_REPOS=1 sur stderr (dépôt d'équipe déclaré mais absent, toléré ET signalé)" || ko "marqueur CHOICES_SKIPPED_REPOS absent/inattendu sur stderr"
# Mutation 1 : aucune équipe déclarée ⇒ refus, AUCUN fichier (même pré-existant).
GH6E="$TMP/gitea6e"; mk_platform "$GH6E/ci/stoa-labs.git" "$PROV_EMPTY"
printf 'ENVS=perime\nTEAMS=perime\nAPIS=perime\n' > "$OUT6"
run_choices "$GH6E" "$TMP/chain6.yaml" "$OUT6"; RC=$?
[ "$RC" -ne 0 ] && [ ! -f "$OUT6" ] && grep -q 'EQUIPES_INDISPONIBLES' "$TMP/ch.err" \
  && ok "providers vide ⇒ rc≠0 EQUIPES_INDISPONIBLES, et le fichier PÉRIMÉ pré-existant a été retiré (jamais relu comme frais)" \
  || ko "providers vide : rc=$RC fichier=$([ -f "$OUT6" ] && echo présent || echo absent) — $(tail -2 "$TMP/ch.err")"
# Mutation 2 : chaîne illisible ⇒ refus nommé, aucun fichier.
run_choices "$GH6" "$TMP/inexistant.yaml" "$OUT6"; RC=$?
[ "$RC" -ne 0 ] && [ ! -f "$OUT6" ] && grep -q 'CHAINE_ILLISIBLE' "$TMP/ch.err" \
  && ok "chaîne d'environnements illisible ⇒ rc≠0 CHAINE_ILLISIBLE, aucun fichier" || ko "chaîne illisible : rc=$RC — $(tail -2 "$TMP/ch.err")"
# Mutation 3 : CHOICES_OUT non posé ⇒ refus.
run_choices "$GH6" "$TMP/chain6.yaml" ""; RC=$?
[ "$RC" -ne 0 ] && grep -q 'CHOICES_OUT requis' "$TMP/ch.err" && ok "CHOICES_OUT absent ⇒ rc≠0 nommé" || ko "CHOICES_OUT absent : rc=$RC"
# Mutation 4 : Gitea injoignable ⇒ refus, aucun fichier.
run_choices "$TMP/nulle-part" "$TMP/chain6.yaml" "$OUT6"; RC=$?
[ "$RC" -ne 0 ] && [ ! -f "$OUT6" ] && ok "Gitea injoignable ⇒ rc≠0, aucun fichier (fail-closed)" || ko "Gitea injoignable : rc=$RC fichier=$([ -f "$OUT6" ] && echo présent || echo absent)"

echo
echo "== 5. app-request : le formulaire est POSÉ PAR LE JENKINSFILE — plus un paramètre dans le XML =="
JFA="ci/Jenkinsfile.app-request"; XA="ci/jenkins/app-request.job.xml"; code_view "$JFA" > "$TMP/jf-app.code"
jfa(){ grep -qF -- "$1" "$TMP/jf-app.code"; }
NP=$(python3 -c "
import xml.etree.ElementTree as T
r = T.parse('$XA').getroot()
print(sum(1 for e in r.iter() if e.tag.endswith('ParameterDefinition')) + sum(1 for e in r.iter() if e.tag.endswith('ParametersDefinitionProperty')))")
[ "$NP" = 0 ] && ok "XML : ZÉRO ParameterDefinition / ParametersDefinitionProperty (structurel)" || ko "XML : $NP définition(s) de paramètre résiduelle(s)"
grep -q 'CHOICES:' "$XA" && ko "XML : un marqueur CHOICES: subsiste (setup-team-onboard-jobs.sh tenterait une substitution)" || ok "XML : aucun marqueur CHOICES: — setup-team-onboard-jobs.sh le copie tel quel (NO-OP garanti)"
L_BOOT=$(code_line "$TMP/jf-app.code" "env.FORM_BOOTSTRAP = (params.size() == 0)")
L_PROPS=$(code_line "$TMP/jf-app.code" "properties([parameters([")
[ -n "$L_BOOT" ] && [ -n "$L_PROPS" ] && [ "$L_BOOT" -lt "$L_PROPS" ] \
  && ok "FORM_BOOTSTRAP capturé (ligne $L_BOOT) AVANT properties() (ligne $L_PROPS) — fait 4 : après, params retombe sur les défauts" \
  || ko "signal d'amorçage absent ou capturé après properties() (boot=$L_BOOT props=$L_PROPS)"
[ -n "$L_PROPS" ] && ok "properties([parameters([ … ])]) en vue CODE : le formulaire est posé par le pipeline" || ko "properties([parameters([ absent"
# Le champ obligatoire se refuse DANS le pipeline, avant le workspace et le clone
# (mesuré app-request #47 : APP vide ⇒ message brut de bash au fond du script).
jfa 'GC_PLATFORM_DIR="$WORKSPACE"' && ok "le stage Formulaire passe GC_PLATFORM_DIR=\$WORKSPACE : le dépôt plateforme du workspace est lu, pas re-cloné" || ko "GC_PLATFORM_DIR non passé au script de listes (le premier stage re-clone par le réseau)"
L_REQ=$(code_line "$TMP/jf-app.code" "CHAMP_REQUIS"); L_SH=$(code_line "$TMP/jf-app.code" "bash scripts/provision-request.sh")
[ -n "$L_REQ" ] && [ -n "$L_SH" ] && [ "$L_REQ" -lt "$L_SH" ] \
  && ok "garde CHAMP_REQUIS (ligne $L_REQ) AVANT l'appel de provision-request.sh (ligne $L_SH) : un champ obligatoire vide se nomme sans cloner" \
  || ko "garde du champ obligatoire absente ou après le sh (garde=$L_REQ sh=$L_SH)"
MISS=""
for P in "string(name: 'APP'" "choice(name: 'REQ_ENV', choices: envs" "choice(name: 'TEAM', choices: [''] + teams" "choice(name: 'API', choices: apis" \
         "string(name: 'CLIENT_ID'" "choice(name: 'MODE', choices: ['idp', 'internal']" "text(name: 'IP_ALLOWLIST'" "text(name: 'CERT_PEM'" \
         "choice(name: 'CERT_ROTATION', choices: ['replace', 'overlap']" "string(name: 'BACKEND_KEY_REF'" "string(name: 'BACKEND_KEY_FIELD'"; do
  jfa "$P" || MISS="$MISS [$P]"
done
[ -z "$MISS" ] && ok "les 11 paramètres posés avec leur TYPE (string/choice/text) et leurs listes (envs, ''+teams, apis, idp/internal, replace/overlap)" || ko "paramètres absents/divergents :$MISS"
if grep -qE "\['dev'|'homol'|'rec', 'int'" "$TMP/jf-app.code"; then ko "une liste de paliers LITTÉRALE subsiste dans le Jenkinsfile"; else ok "aucune liste de paliers littérale : REQ_ENV vient d'env_chain (une seule source, celle du script — A7 : la chaîne entière)"; fi
# ── A7 : l'identité de forge et les références, câblées dans le formulaire ──
MISS7=""; for P in "password(name: 'FORGE_TOKEN'" "string(name: 'CHANGE_REF'" "string(name: 'PV_REF'"; do jfa "$P" || MISS7="$MISS7 [$P]"; done
[ -z "$MISS7" ] && ok "A7 : trois paramètres de plus — FORGE_TOKEN (password), CHANGE_REF, PV_REF" || ko "A7 paramètres absents :$MISS7"
grep -q 'FORGE_TOKEN=${params' "$TMP/jf-app.code" && ko "A7 : FORGE_TOKEN traverse un withEnv — il serait PERSISTÉ EN CLAIR (fait 9)" || ok "A7 : FORGE_TOKEN ne traverse AUCUN step (canal natif seulement, fait 9)"
jfa '"REQ_CHANGE_REF=${params.CHANGE_REF ?: '"''"'}"' && jfa '"REQ_PV_REF=${params.PV_REF ?: '"''"'}"' && ok "A7 : REQ_CHANGE_REF / REQ_PV_REF passent par le withEnv brut (fait 5)" || ko "A7 : refs absentes du withEnv"
L_ALT=$(code_line "$TMP/jf-app.code" 'TOKEN_ALTERE'); L_GLB=$(code_line "$TMP/jf-app.code" 'TOKEN_GLOBAL_REFUSE'); L_SHREQ=$(code_line "$TMP/jf-app.code" 'bash scripts/provision-request.sh')
[ -n "$L_ALT" ] && [ -n "$L_GLB" ] && [ -n "$L_SHREQ" ] && [ "$L_ALT" -lt "$L_SHREQ" ] && [ "$L_GLB" -lt "$L_SHREQ" ] && jfa 'brutTok != resoluTok' \
  && ok "A7 : gardes TOKEN_ALTERE ($L_ALT) et TOKEN_GLOBAL_REFUSE ($L_GLB) AVANT l'appel du script ($L_SHREQ) — brut ≠ résolu ⇔ altéré, champ vide + env non vide ⇔ globale" || ko "A7 : gardes du token absentes/mal placées (alt=$L_ALT glb=$L_GLB sh=$L_SHREQ)"
grep -qE "error\('REFUS: TOKEN_(ALTERE|GLOBAL_REFUSE)[^']*\\\$\{(params|env)" "$TMP/jf-app.code" && ko "A7 : un message d'erreur interpole la valeur du token" || ok "A7 : aucun message d'erreur n'interpole le token"
[ "$(grep -c 'STOA_ENV_CHAIN_FILE="\$WORKSPACE/poc-control-plane-federation/clients/_example/environments.yaml"' "$TMP/jf-app.code")" = 2 ] && ok "A7 : la chaîne est ÉPINGLÉE sur les deux sh (listes et demande) — une globale ne redirige plus la porte à la demande" || ko "A7 : épinglages STOA_ENV_CHAIN_FILE : $(grep -c 'STOA_ENV_CHAIN_FILE=' "$TMP/jf-app.code")"
grep -v '^\s*//' ci/Jenkinsfile.provisioning-request | grep -qE "^\s*FORGE_TOKEN\s*=\s*''" && ok "A7 : la voie machine VIDE FORGE_TOKEN dans son bloc environment (une globale du nœud ne lui prête aucune identité de forge)" || ko "A7 : Jenkinsfile.provisioning-request ne vide pas FORGE_TOKEN"
L_SH=$(code_line "$TMP/jf-app.code" "sh 'set +x; GC_PLATFORM_DIR=\"\$WORKSPACE\" STOA_ENV_CHAIN_FILE=\"\$WORKSPACE/poc-control-plane-federation/clients/_example/environments.yaml\" CHOICES_OUT=\"\$WORKSPACE/.a0-choices.env\" bash scripts/app-request-choices.sh'")
L_WC=$(code_line "$TMP/jf-app.code" "withCredentials([string(credentialsId: env.GITEA_CREDENTIALS_ID, variable: 'GITEA_TOKEN')])")
[ -n "$L_SH" ] && [ -n "$L_WC" ] && [ "$L_WC" -lt "$L_SH" ] && [ "$L_SH" -lt "$L_PROPS" ] \
  && ok "app-request-choices.sh invoqué en quotes SIMPLES sous credential (ligne $L_SH), AVANT properties()" || ko "invocation du script de listes absente/mal placée (sh=$L_SH wc=$L_WC props=$L_PROPS)"
jfa 'readFile("${env.WORKSPACE}/.a0-choices.env")' && jfa 'FORMULAIRE_VIDE' \
  && ok "listes relues par readFile, refus FORMULAIRE_VIDE si l'une est vide (double du refus du script)" || ko "readFile / FORMULAIRE_VIDE absents"
[ "$(grep -cF "when { expression { env.FORM_BOOTSTRAP != 'true' } }" "$TMP/jf-app.code")" -eq 2 ] \
  && ok "les DEUX stages de demande sont gardés par FORM_BOOTSTRAP != 'true' (l'amorçage n'ouvre rien)" || ko "garde FORM_BOOTSTRAP absente d'un stage de demande"
L_CTX=$(code_line "$TMP/jf-app.code" "stage('Contexte de la demande')")
[ -n "$L_CTX" ] && [ "$L_PROPS" -lt "$L_CTX" ] && ok "le stage Formulaire précède le stage Contexte : même un build de demande rafraîchit les listes" || ko "ordre des stages inattendu (props=$L_PROPS ctx=$L_CTX)"
MISS=""
for M in "REQ_APP=\${params.APP}" "REQ_ENV=\${params.REQ_ENV}" "REQ_CLIENT_ID=\${params.CLIENT_ID" "REQ_MODE=\${params.MODE}" "REQ_TEAM=\${params.TEAM" \
         "REQ_IP_ALLOWLIST=\${params.IP_ALLOWLIST" "REQ_CERT_PEM=\${params.CERT_PEM" "REQ_CERT_ROTATION=\${params.CERT_ROTATION" \
         "REQ_BACKEND_KEY_REF=\${params.BACKEND_KEY_REF" "REQ_BACKEND_KEY_FIELD=\${params.BACKEND_KEY_FIELD"; do
  jfa "$M" || MISS="$MISS ${M%%=*}"
done
[ -z "$MISS" ] && ok "ré-injection BRUTE withEnv([params…]) des 10 champs conservée (fait 5 : EnvVars.resolve)" || ko "champs non ré-injectés en brut :$MISS"
grep -qE '^  parameters \{' "$TMP/jf-app.code" && ko "une directive déclarative \`parameters {\` de niveau pipeline existe — elle figerait les listes à la pose" || ok "aucune directive déclarative \`parameters {\` : le formulaire est le pas scripté, évalué à chaque build"
jfa 'currentBuild.displayName = "amorçage du formulaire (aucune demande)"' && ok "le build d'amorçage se NOMME (seul build vert sans demande)" || ko "displayName d'amorçage absent"
jfa 'API_FORMAT_INVALIDE' && jfa 'getBuildCauses' && ok "gardes d'origine tenues : API_FORMAT_INVALIDE (pas de repli 1.0.0), REQ_CALLER dérivé de la cause du build" || ko "une garde d'origine a disparu"

echo
echo "== 7. la POSE : coquille copiée telle quelle, build d'amorçage câblé, deux mécanismes qui coexistent =="
SPJ="scripts/setup-provision-jobs.sh"; STO="scripts/setup-team-onboard-jobs.sh"
code_sh(){ grep -vE '^\s*#' "$1"; }
code_sh "$SPJ" | grep -q 'BOOTSTRAP_JOBS="${BOOTSTRAP_JOBS:-}"' && code_sh "$SPJ" | grep -qF '"$JENKINS_UI/job/$J/build"' \
  && ok "setup-provision-jobs.sh : knob BOOTSTRAP_JOBS + POST /job/<j>/build" || ko "setup-provision-jobs.sh : BOOTSTRAP_JOBS ou POST /build absents"
code_sh "$SPJ" | grep -q '400) warn "amorçage refusé' && code_sh "$SPJ" | grep -q 'if \[ "$POSED" = true \]; then' \
  && ok "amorçage gaté sur une pose RÉUSSIE, 400 (déjà paramétré) nommé et rc≠0" || ko "amorçage non gaté sur la pose, ou 400 avalé"
code_sh "$STO" | grep -q 'case " $JOBS " in \*" app-request "\*) BOOTSTRAP="app-request";; esac' && code_sh "$STO" | grep -q 'BOOTSTRAP_JOBS="$BOOTSTRAP"' \
  && ok "setup-team-onboard-jobs.sh : BOOTSTRAP_JOBS=app-request dérivé de JOBS et transmis au délégué" || ko "setup-team-onboard-jobs.sh ne demande pas l'amorçage d'app-request"
grep -Eq '<!--CHOICES:(TEAMS|APIS)-->' ci/jenkins/app-request.job.xml && ko "app-request.job.xml porte encore un marqueur : la substitution serait tentée" \
  || ok "app-request.job.xml sans marqueur : la recherche statique de setup-team-onboard-jobs.sh ne le passe jamais à sed (NO-OP)"
grep -Eq '<!--CHOICES:(TEAMS|APIS)-->' ci/jenkins/api-request.job.xml \
  && ok "api-request.job.xml (chaîne des APIs, hors périmètre) garde ses marqueurs : les deux mécanismes coexistent, dit dans les en-têtes" \
  || ko "api-request.job.xml a perdu ses marqueurs — hors périmètre A0, régression"
grep -q 'A0 (2026-09-02)' "$STO" && grep -q 'DEUX MÉCANISMES COEXISTENT' "$STO" && ok "la coexistence est documentée dans setup-team-onboard-jobs.sh" || ko "coexistence non documentée"
grep -qF 'JOBS="app-request api-request"' scripts/team-apply.sh && grep -qF 'JOBS="app-request api-request"' scripts/team-publish.sh \
  && ok "team-apply.sh / team-publish.sh re-posent toujours app-request après un onboarding/une publication (⇒ amorçage ⇒ listes rafraîchies)" \
  || ko "la re-pose événementielle d'app-request a disparu d'un des deux scripts"
# Fonctionnel HORS LIGNE : setup-team-onboard-jobs.sh JOBS=app-request contre un faux Jenkins.
cat > "$TMP/fakejenkins.py" <<'PY'
import os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
D = os.environ["BODYDIR"]
class H(BaseHTTPRequestHandler):
    def _send(self, code, body=b"{}"):
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/crumbIssuer"): return self._send(200, b'{"crumbRequestField":"Jenkins-Crumb","crumb":"abc"}')
        return self._send(404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n) if n else b""
        mb = re.match(r"^/job/([^/]+)/build$", self.path)
        if mb: open(os.path.join(D, mb.group(1) + ".build"), "w").close(); return self._send(201)
        if self.path.startswith("/createItem"):
            name = re.search(r"name=([^&]+)", self.path).group(1)
            open(os.path.join(D, name + ".posted.xml"), "wb").write(body); return self._send(200)
        self._send(404)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
BODYDIR="$TMP/posted"; mkdir -p "$BODYDIR"; PORT="${FAKE_JENKINS_PORT:-18470}"
BODYDIR="$BODYDIR" python3 "$TMP/fakejenkins.py" "$PORT" >/dev/null 2>&1 & FAKE_PID=$!
for _ in $(seq 1 40); do curl -s "http://127.0.0.1:$PORT/x" >/dev/null 2>&1 && break; sleep 0.1; done
# SANS GITEA_TOKEN ni Gitea : app-request n'a plus de marqueur, la pose ne doit rien demander à Gitea.
OUT=$(JENKINS_UI="http://127.0.0.1:$PORT" JOBS="app-request" bash "$STO" 2>&1); RC=$?
kill "$FAKE_PID" 2>/dev/null
[ "$RC" -eq 0 ] && cmp -s "$BODYDIR/app-request.posted.xml" ci/jenkins/app-request.job.xml \
  && ok "pose d'app-request SANS Gitea ni token : rc 0, XML posté octet pour octet identique à la source" \
  || ko "pose d'app-request : rc=$RC, ou XML posté divergent — $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
[ -f "$BODYDIR/app-request.build" ] && ok "le build d'amorçage a été demandé juste après la pose (POST /job/app-request/build)" || ko "aucun build d'amorçage demandé"

echo
echo "== 9. DETTES A0 — (a) la forge est CONFIRMÉE avant tout geste : scripts/lib/gitea-pr-confirm.sh contre un stub =="
# Stub Gitea (motif test-provision-apply-a2.sh) : /pulls/<n> piloté par ctl.json
# (state, head, base, code, raw), commentaires PAGINÉS (limit/page), journal HTTP.
STUB_CTL="$TMP/ctl.json"; STUB_LOG="$TMP/http.log"; STUB_COMMENTS="$TMP/comments.json"
: > "$STUB_LOG"; printf '[]' > "$STUB_COMMENTS"; printf '{}' > "$STUB_CTL"
cat > "$TMP/stub.py" <<'PY'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
CTL, LOG, STORE, TOKEN = os.environ["STUB_CTL"], os.environ["STUB_LOG"], os.environ["STUB_COMMENTS"], os.environ["STUB_TOKEN"]
def ctl():
    try: return json.load(open(CTL))
    except Exception: return {}
def load():
    try: return json.load(open(STORE))
    except Exception: return []
def save(c): json.dump(c, open(STORE, "w"))
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def _send(self, code, body):
        if isinstance(body, (dict, list)): body = json.dumps(body)
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _route(self, method):
        path, _, qs = self.path.partition("?")
        with open(LOG, "a") as f: f.write("%s %s\n" % (method, path))
        # Depot git servi en dumb-http (git clone) depuis STUB_GITDIR — AVANT
        # l'auth : git n'envoie pas le token (il n'en a pas besoin en lecture).
        gitdir = os.environ.get("STUB_GITDIR", "")
        pfx = "/ci/stoa-labs.git/"
        if gitdir and method == "GET" and path.startswith(pfx):
            fp = os.path.normpath(os.path.join(gitdir, path[len(pfx):]))
            if fp.startswith(os.path.normpath(gitdir)) and os.path.isfile(fp):
                return self._send(200, open(fp, "rb").read())
            return self._send(404, {"message": "git: absent"})
        if self.headers.get("Authorization") != "token " + TOKEN:
            return self._send(401, {"message": "unauthorized"})
        c = ctl()
        m = re.match(r"^/api/v1/repos/[^/]+/[^/]+/pulls/([0-9]+)$", path)
        if m and method == "GET":
            code = int(c.get("code", 200))
            if "raw" in c: return self._send(code, c["raw"])
            pr = c.get("pr") or {}
            return self._send(code, {"number": int(m.group(1)), "state": pr.get("state", "open"),
                "head": {"ref": pr.get("head_ref", ""), "sha": pr.get("head_sha", "a" * 40), "repo": {"full_name": pr.get("head_repo", "ci/stoa-labs")}},
                "base": {"ref": pr.get("base_ref", "main")}, "merged": pr.get("merged", False)})
        if re.match(r"^/api/v1/repos/[^/]+/[^/]+/issues/[0-9]+/comments$", path):
            if method == "GET":
                q = dict(kv.split("=", 1) for kv in qs.split("&") if "=" in kv)
                lim, page = min(int(q.get("limit", 50)), int(c.get("comments_cap", 50))), int(q.get("page", 1))
                return self._send(200, load()[(page - 1) * lim: page * lim])
            body = json.loads(self._body().decode("utf-8", "replace") or "{}")
            cs = load(); new = {"id": len(cs) + 1, "body": body.get("body", "")}; cs.append(new); save(cs)
            return self._send(201, new)
        m = re.match(r"^/api/v1/repos/[^/]+/[^/]+/issues/comments/([0-9]+)$", path)
        if m and method == "PATCH":
            body = json.loads(self._body().decode("utf-8", "replace") or "{}")
            cid = int(m.group(1)); cs = load()
            for e in cs:
                if e["id"] == cid: e["body"] = body.get("body", "")
            save(cs); return self._send(200, {"id": cid})
        self._send(404, {"message": "stub: route inconnue " + path})
    def do_GET(self):   self._route("GET")
    def do_POST(self):  self._route("POST")
    def do_PATCH(self): self._route("PATCH")
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_port); sys.stdout.flush()
srv.serve_forever()
PY
STUB_TOKEN="tok-a0"; STUB_GITDIR="$TMP/bare.git"
STUB_CTL="$STUB_CTL" STUB_LOG="$STUB_LOG" STUB_COMMENTS="$STUB_COMMENTS" STUB_TOKEN="$STUB_TOKEN" STUB_GITDIR="$STUB_GITDIR" python3 "$TMP/stub.py" >"$TMP/stub.port" 2>"$TMP/stub.err" &
STUB_PID=$!
for _ in $(seq 1 60); do [ -s "$TMP/stub.port" ] && break; sleep 0.1; done
GH9="http://127.0.0.1:$(head -n1 "$TMP/stub.port")"
set_pr(){ # $1=state $2=head_ref $3=base_ref [$4=code] [$5=raw] [$6=head_sha] [$7=head_repo] [$8=comments_cap]
  python3 - "$STUB_CTL" "$1" "$2" "$3" "${4:-200}" "${5:-}" "${6:-}" "${7:-}" "${8:-50}" <<'PY'
import json, sys
ctl, state, head, base, code, raw, sha, hrepo, cap = sys.argv[1:10]
c = {"code": int(code), "comments_cap": int(cap), "pr": {"state": state, "head_ref": head, "base_ref": base, "head_sha": sha or "c" * 40, "head_repo": hrepo or "ci/stoa-labs"}}
if raw: c["raw"] = raw
json.dump(c, open(ctl, "w"))
PY
}
nreq(){ grep -c "^$1" "$STUB_LOG" 2>/dev/null || true; }
last_body(){ python3 -c "import json;c=json.load(open('$STUB_COMMENTS'));print(c[-1]['body'] if c else '')"; }
ncomments(){ python3 -c "import json;print(len(json.load(open('$STUB_COMMENTS'))))"; }
confirm(){ # $1=n $2=head attendu [$3=base] → stdout+stderr dans $TMP/cf.out, rc
  ( . scripts/lib/gitea-pr-confirm.sh; GIT_HOST="$GH9" GIT_REPO=ci/stoa-labs GITEA_TOKEN="$STUB_TOKEN" gitea_pr_confirm "$1" "$2" ${3:+"$3"} ) >"$TMP/cf.out" 2>&1
}
shellcheck -x scripts/lib/gitea-pr-confirm.sh >/dev/null 2>&1 && ok "gitea-pr-confirm.sh : shellcheck propre" || ko "gitea-pr-confirm.sh : shellcheck en échec"
set_pr open provision/appa-dev main; confirm 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && grep -qx 'GITEA_STATE=open' "$TMP/cf.out" && grep -qx 'GITEA_HEAD_REF=provision/appa-dev' "$TMP/cf.out" && grep -qx "GITEA_HEAD_SHA=$(printf 'c%.0s' $(seq 40))" "$TMP/cf.out" && grep -qx 'GITEA_BASE_REF=main' "$TMP/cf.out" \
  && ok "PR ouverte, tête et base concordantes ⇒ rc 0 + quatre faits (state/head.ref/head.sha/base.ref)" || ko "confirmation nominale : rc=$RC — $(tr '\n' ' ' < "$TMP/cf.out")"
set_pr open provision/appb-dev main; confirm 12 provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && grep -q 'FORGE_NON_CONFIRMEE' "$TMP/cf.out" && grep -q "appb-dev" "$TMP/cf.out" \
  && ok "tête divergente (le payload nomme appa, la forge dit appb) ⇒ rc 1 FORGE_NON_CONFIRMEE, la tête réelle est nommée" || ko "tête divergente non refusée (rc=$RC)"
set_pr closed provision/appa-dev main; confirm 12 provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && grep -q 'pas ouverte' "$TMP/cf.out" && ok "PR fermée/mergée (branche réutilisée) ⇒ rc 1 (jamais un plan sur une PR mergée)" || ko "PR fermée acceptée (rc=$RC)"
set_pr open onboard/x main; confirm 12 onboard/x; RC=$?
[ "$RC" -eq 1 ] && ok "head attendu hors provision/* ⇒ rc 1 (la lib ne sert que la voie provision/*)" || ko "hors provision/* accepté (rc=$RC)"
set_pr open provision/appa-dev release; confirm 12 provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && grep -q "base de la PR" "$TMP/cf.out" && ok "base ≠ main ⇒ rc 1" || ko "base divergente acceptée (rc=$RC)"
set_pr open provision/appa-dev main 404; confirm 12 provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && grep -q 'HTTP 404' "$TMP/cf.out" && ok "PR inconnue (404) ⇒ rc 1" || ko "404 accepté (rc=$RC)"
set_pr open provision/appa-dev main 500; confirm 12 provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && grep -q 'HTTP 500' "$TMP/cf.out" && ok "forge en erreur (500) ⇒ rc 1" || ko "500 accepté (rc=$RC)"
set_pr open provision/appa-dev main 200 '[]'; confirm 12 provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && grep -q 'pas un objet' "$TMP/cf.out" && ok "200 mais pas un objet PR (portail interposé) ⇒ rc 1" || ko "non-objet accepté (rc=$RC)"
set_pr open "$(printf 'provision/appa-dev\nX')" main; confirm 12 "$(printf 'provision/appa-dev\nX')"; RC=$?
[ "$RC" -eq 1 ] && ok "retour-ligne dans head.ref ⇒ rc 1 (jamais une valeur multi-ligne dans un fichier de faits)" || ko "retour-ligne accepté (rc=$RC)"
: > "$STUB_LOG"; confirm '12;rm' provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && [ "$(nreq GET)" = 0 ] && ok "numéro non numérique ⇒ rc 1 SANS aucun appel réseau (jamais un chemin forgé)" || ko "numéro non numérique : rc=$RC, appels=$(nreq GET)"
set_pr open provision/appa-dev main 200 '' '-b x'; confirm 12 provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && grep -q 'hexadecimal' "$TMP/cf.out" && ok "head.sha non hexadécimal ('-b x') ⇒ rc 1 : jamais un argument libre pour git checkout" || ko "head.sha non hex accepté (rc=$RC)"
set_pr open provision/appa-dev main 200 '' '' acme/fork; confirm 12 provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && grep -q 'FORK' "$TMP/cf.out" && ok "PR depuis un FORK (head.repo ≠ dépôt) ⇒ rc 1 nommé (sa tête n'est pas dans le clone)" || ko "PR de fork acceptée (rc=$RC)"
set_pr open provision/appa-dev main
grep -vE '^\s*#' scripts/lib/gitea-pr-confirm.sh | grep -q 'PC_TOKEN="$GITEA_TOKEN"' && ! grep -vE '^\s*#' scripts/lib/gitea-pr-confirm.sh | grep -qE 'curl .*(token|Authorization)' \
  && ok "le token passe par l'ENVIRONNEMENT du python (jamais en argv)" || ko "token en argv ou lib sans python"
grep -q 'timeout=30)' scripts/lib/gitea-pr-confirm.sh && ok "urlopen(timeout=30)" || ko "aucun timeout"

echo
echo "== 9. (b) gitea-pr-comment.sh : COMMENT_ONLY_IF_EXISTS et pagination (couvert aussi par test-pr-comment.sh §11-12) =="
printf '[]' > "$STUB_COMMENTS"; printf 'corps\n' > "$TMP/cb"
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN="$STUB_TOKEN" PR_NUMBER=12 GIT_HOST="$GH9" COMMENT_MARKER='<!-- provision-plan-build -->' COMMENT_BODY_FILE="$TMP/cb" COMMENT_ONLY_IF_EXISTS=1 bash scripts/lib/gitea-pr-comment.sh 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = COMMENT_SKIPPED ] && [ "$(python3 -c "import json;print(len(json.load(open('$STUB_COMMENTS'))))")" = 0 ] \
  && ok "ONLY_IF_EXISTS sans marqueur ⇒ COMMENT_SKIPPED, rien créé" || ko "ONLY_IF_EXISTS : rc=$RC $OUT"
python3 - "$STUB_COMMENTS" <<'PY'
import json, sys
cs = [{"id": i, "body": f"bruit {i}"} for i in range(1, 61)]; cs[54]["body"] = "<!-- provision-plan-build -->\nrouge perime"
json.dump(cs, open(sys.argv[1], "w"))
PY
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN="$STUB_TOKEN" PR_NUMBER=12 GIT_HOST="$GH9" COMMENT_MARKER='<!-- provision-plan-build -->' COMMENT_BODY_FILE="$TMP/cb" COMMENT_ONLY_IF_EXISTS=1 bash scripts/lib/gitea-pr-comment.sh 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "COMMENT_UPDATED 55" ] && ok "ONLY_IF_EXISTS avec un marqueur en 55e position (2e page) ⇒ COMMENT_UPDATED 55 : pagination + mise à jour" || ko "pagination/ONLY_IF_EXISTS : rc=$RC $OUT"
set_pr open provision/appa-dev main 200 '' '' '' 30
OUT=$(GIT_REPO=ci/stoa-labs GITEA_TOKEN="$STUB_TOKEN" PR_NUMBER=12 GIT_HOST="$GH9" COMMENT_MARKER='<!-- provision-plan-build -->' COMMENT_BODY_FILE="$TMP/cb" bash scripts/lib/gitea-pr-comment.sh 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "COMMENT_UPDATED 55" ] && ok "forge qui PLAFONNE limit à 30 (api.MAX_RESPONSE_ITEMS) ⇒ le marqueur en 55e est encore trouvé (arrêt sur page VIDE, jamais sur page courte)" || ko "plafond serveur 30 : $OUT — empilement (revue 2026-09-02)"
set_pr open provision/appa-dev main

echo
echo "== 9. (c) provision-plan.sh : la forge relue AVANT le clone — refus nommé, zéro commentaire, zéro clone =="
plan(){ # $1=PR_NUMBER $2=PR_BRANCH → $TMP/plan.out (stdout+stderr), rc ; faits dans $TMP/plan.facts
  rm -f "$TMP/plan.facts"; : > "$STUB_LOG"; printf '[]' > "$STUB_COMMENTS"
  # GIT_TERMINAL_PROMPT=0 : le stub répond 401 au clone (pas un dépôt git) — sans
  # ce knob, git demanderait un mot de passe au terminal et la suite pendrait.
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PR_NUMBER="$1" PR_BRANCH="$2" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH9" GIT_REPO=ci/stoa-labs PLAN_FACTS="$TMP/plan.facts" \
    bash scripts/provision-plan.sh >"$TMP/plan.out" 2>&1
}
fact(){ sed -n "s/^$1=//p" "$TMP/plan.facts" 2>/dev/null | head -1; }
set_pr open provision/appb-dev main; plan 12 provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && grep -q 'REFUS: FORGE_NON_CONFIRMEE' "$TMP/plan.out" && [ "$(fact PLAN_VERDICT)" = refus ] && [ -z "$(fact GITEA_HEAD_REF)" ] \
  && ok "payload forgé (branche de A, numéro de B) ⇒ rc 1 FORGE_NON_CONFIRMEE, faits : verdict=refus, tête VIDE (non confirmée)" || ko "payload forgé : rc=$RC — $(tail -2 "$TMP/plan.out" | tr '\n' ' ')"
[ "$(nreq POST)" = 0 ] && [ "$(nreq PATCH)" = 0 ] && ok "… AUCUN commentaire (zéro POST/PATCH sur le stub)" || ko "… un commentaire est parti (POST=$(nreq POST) PATCH=$(nreq PATCH))"
grep -q 'stoa-labs.git' "$STUB_LOG" && ko "… un clone a été tenté AVANT la confirmation" || ok "… AUCUN clone tenté : la forge est relue AVANT tout geste Git"
set_pr closed provision/appa-dev main; plan 12 provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && grep -q 'pas ouverte' "$TMP/plan.out" && [ "$(nreq POST)" = 0 ] && ok "PR mergée/fermée (branche réutilisée) ⇒ refus, aucun commentaire" || ko "PR fermée : rc=$RC POST=$(nreq POST)"
plan '12;rm' provision/appa-dev; RC=$?
[ "$RC" -eq 1 ] && [ "$(nreq GET)" = 0 ] && ok "PR_NUMBER non numérique ⇒ refus SANS aucun appel réseau" || ko "PR_NUMBER non numérique : rc=$RC GET=$(nreq GET)"
plan 12 onboard/x; RC=$?
[ "$RC" -eq 0 ] && [ "$(fact PLAN_VERDICT)" = ignore ] && [ "$(nreq GET)" = 0 ] && ok "hors provision/* ⇒ IGNORE rc 0, faits verdict=ignore, aucun appel" || ko "hors provision/* : rc=$RC verdict=$(fact PLAN_VERDICT)"
set_pr open provision/appa-dev main; plan 12 provision/appa-dev; RC=$?
L_PULL=$(grep -n 'GET /api/v1/repos/ci/stoa-labs/pulls/12' "$STUB_LOG" | head -1 | cut -d: -f1); L_CLONE=$(grep -n 'stoa-labs.git' "$STUB_LOG" | head -1 | cut -d: -f1)
[ "$RC" -eq 1 ] && grep -q 'REFUS: CLONE_ECHEC' "$TMP/plan.out" && [ "$(fact PLAN_VERDICT)" = refus ] && [ "$(fact GITEA_HEAD_REF)" = provision/appa-dev ] \
  && ok "forge confirmée puis clone impossible (le stub n'est pas un dépôt git) ⇒ CLONE_ECHEC rc 1, faits : refus + tête CONFIRMÉE (le statut pourra parler)" || ko "clone impossible : rc=$RC verdict=$(fact PLAN_VERDICT) head=$(fact GITEA_HEAD_REF)"
[ -n "$L_PULL" ] && [ -n "$L_CLONE" ] && [ "$L_PULL" -lt "$L_CLONE" ] && ok "ordre sur le journal HTTP : GET /pulls/12 (ligne $L_PULL) AVANT la tentative de clone (ligne $L_CLONE)" || ko "ordre forge/clone non prouvé (pull=$L_PULL clone=$L_CLONE)"
[ "$(nreq POST)" = 0 ] && ok "… et toujours aucun commentaire" || ko "… un commentaire est parti sur un refus"
grep -vE '^\s*#' scripts/provision-plan.sh | grep -q 'git checkout -q --detach "$GITEA_HEAD_SHA"' && ok "le checkout vise le SHA de tête RELU (--detach : un commit, jamais un chemin ni une option), jamais le nom de branche du payload" || ko "le checkout n'utilise pas --detach GITEA_HEAD_SHA"
grep -vE '^\s*#' scripts/provision-plan.sh | grep -q '|| refus BRANCHE_INTROUVABLE' && ok "checkout raté ⇒ BRANCHE_INTROUVABLE (plus jamais vert par IGNORE)" || ko "checkout non gardé"
grep -q '^PLAN_PR_NUMBER=12$' "$TMP/plan.facts" && ok "les faits portent PLAN_PR_NUMBER (jamais les faits d'une autre PR relus comme les siens)" || ko "PLAN_PR_NUMBER absent des faits"

grep -vE '^\s*#' scripts/provision-plan.sh | grep -q 'facts refus "SCRIPT_INTERROMPU' && ok "faits INITIAUX (refus SCRIPT_INTERROMPU, tête vide) écrits dès le prologue : une mort inattendue laisse un fichier honnête" || ko "pas de faits initiaux"
grep -vE '^\s*#' scripts/provision-plan.sh | grep -qE '^\($' && grep -vE '^\s*#' scripts/provision-plan.sh | grep -q '^) >"$PLAN_LOG" 2>&1 || VERDICT="fail"' && ok "le bloc de plan est un SOUS-SHELL ( … ) : un exit 1 y rend VERDICT=fail au lieu de tuer le script" || ko "le bloc de plan n'est pas un sous-shell"

echo
echo "== 9. (c bis) APRÈS le clone (dépôt git servi en dumb-http par le stub) : un manifeste SUPPRIMÉ rend un ❌ commenté + faits fail — plus jamais un rc 1 muet =="
# Bare repo : main porte un manifeste ; la branche provision/appa-dev le SUPPRIME
# (le diff le liste, `test -f` échoue — le cas du bloquant de la revue : `exit 1`
# dans un groupe { } tuait le script sans verdict ni faits).
SRC="$TMP/src-plan"; mkdir -p "$SRC/poc-control-plane-federation/clients/provisioned/applications"
printf 'apim_ss_app:\n  name: appa\n  api: demo\n' > "$SRC/poc-control-plane-federation/clients/provisioned/applications/appa.ansible.yml"
( cd "$SRC" && git init -q -b main && git -c user.name=t -c user.email=t@t add -A && git -c user.name=t -c user.email=t@t commit -qm init >/dev/null \
  && git checkout -q -b provision/appa-dev && git rm -q poc-control-plane-federation/clients/provisioned/applications/appa.ansible.yml && git -c user.name=t -c user.email=t@t commit -qm retrait >/dev/null )
git clone -q --bare "$SRC" "$STUB_GITDIR" && ( cd "$STUB_GITDIR" && git update-server-info )
SHA_BR=$(git -C "$STUB_GITDIR" rev-parse provision/appa-dev)
set_pr open provision/appa-dev main 200 '' "$SHA_BR"; printf '[]' > "$STUB_COMMENTS"
plan 12 provision/appa-dev; RC=$?
[ -n "${PLAN_DEBUG:-}" ] && { echo "----- plan.out (PLAN_DEBUG)"; cat "$TMP/plan.out"; echo "----- http.log"; cat "$STUB_LOG"; echo "-----"; }
[ "$RC" -eq 1 ] && ok "plan sur une PR qui supprime le manifeste : rc 1 (verdict négatif), le script n'est PAS mort en silence" || ko "plan sur manifeste supprimé : rc=$RC — $(tail -3 "$TMP/plan.out" | tr '\n' ' ')"
[ "$(fact PLAN_VERDICT)" = fail ] && [ "$(fact GITEA_HEAD_SHA)" = "$SHA_BR" ] && ok "faits : PLAN_VERDICT=fail, tête = SHA relu ($SHA_BR)" || ko "faits : verdict=$(fact PLAN_VERDICT) sha=$(fact GITEA_HEAD_SHA)"
last_body | grep -q '❌' && last_body | grep -q '<!-- provision-plan -->' && ok "le verdict ❌ EST posé sur la PR (marqueur provision-plan)" || ko "aucun verdict posé : $(last_body | head -c 120)"
last_body | grep -q "src/commit/$SHA_BR/" && last_body | grep -q "tete relue sur la forge : \`$SHA_BR\`" && ok "le verdict est LIÉ au contenu : lien src/commit/<sha relu>, tête citée" || ko "verdict non lié au SHA relu"
grep -q 'manifeste introuvable' "$TMP/plan.out" && ok "la sortie du plan nomme la cause (manifeste introuvable)" || ko "cause absente de la sortie"
rm -rf "$STUB_GITDIR"; set_pr open provision/appa-dev main

echo
echo "== 9. (d) provision-plan-status.sh : les faits d'abord, la forge sinon, jamais une PR seulement nommée =="
status(){ # $1=BUILD_RESULT $2=facts content (vide = pas de fichier) $3=PR_NUMBER $4=PR_BRANCH → $TMP/st.out, rc
  rm -f "$TMP/st.facts"; [ -n "$2" ] && printf '%b' "$2" > "$TMP/st.facts"; : > "$STUB_LOG"
  BUILD_RESULT="$1" PLAN_FACTS="$TMP/st.facts" PR_NUMBER="$3" PR_BRANCH="$4" GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH9" GIT_REPO=ci/stoa-labs \
    JOB_NAME=provision-plan BUILD_NUMBER=77 BUILD_URL="${ST_BUILD_URL:-}" bash scripts/provision-plan-status.sh >"$TMP/st.out" 2>&1
}
F_OK='GITEA_HEAD_REF=provision/appa-dev\nGITEA_HEAD_SHA=cccc\nPLAN_VERDICT=ok\nPLAN_REASON=plan vert\n'
F_IGN='GITEA_HEAD_REF=provision/appa-dev\nGITEA_HEAD_SHA=cccc\nPLAN_VERDICT=ignore\nPLAN_REASON=aucun manifeste ajoute\n'
F_FAIL='GITEA_HEAD_REF=provision/appa-dev\nGITEA_HEAD_SHA=cccc\nPLAN_VERDICT=fail\nPLAN_REASON=plan en echec\n'
F_REFUS='GITEA_HEAD_REF=provision/appa-dev\nGITEA_HEAD_SHA=cccc\nPLAN_VERDICT=refus\nPLAN_REASON=CLONE_ECHEC : clone en echec\n'
F_NC='GITEA_HEAD_REF=\nGITEA_HEAD_SHA=\nPLAN_VERDICT=refus\nPLAN_REASON=FORGE_NON_CONFIRMEE : tete divergente\n'
shellcheck -x scripts/provision-plan-status.sh >/dev/null 2>&1 && ok "provision-plan-status.sh : shellcheck propre" || ko "provision-plan-status.sh : shellcheck en échec"
printf '[]' > "$STUB_COMMENTS"; status SUCCESS "$F_OK" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && grep -q COMMENT_SKIPPED "$TMP/st.out" && [ "$(ncomments)" = 0 ] && ok "SUCCESS + verdict ok, aucun statut préexistant ⇒ COMMENT_SKIPPED : pas de troisième commentaire redondant" || ko "SUCCESS+ok : rc=$RC $(cat "$TMP/st.out") n=$(ncomments)"
printf '[{"id":1,"body":"<!-- provision-plan-build -->\\nrouge perime"}]' > "$STUB_COMMENTS"; status SUCCESS "$F_OK" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && grep -q 'COMMENT_UPDATED 1' "$TMP/st.out" && last_body | grep -q 'termine sans erreur' && ok "SUCCESS + ok avec un statut rouge périmé ⇒ mis à jour (le rouge est effacé)" || ko "SUCCESS+ok avec statut existant : $(cat "$TMP/st.out")"
printf '[]' > "$STUB_COMMENTS"; status SUCCESS "$F_IGN" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && [ "$(ncomments)" = 1 ] && last_body | grep -q 'IGNOREE' && last_body | grep -q 'aucun manifeste ajoute' && last_body | grep -q '<!-- provision-plan-build -->' \
  && ok "SUCCESS + ignore ⇒ statut posé « demande IGNOREE (raison) : aucun verdict », marqueur provision-plan-build" || ko "SUCCESS+ignore : $(cat "$TMP/st.out") body=$(last_body | head -c 120)"
printf '[]' > "$STUB_COMMENTS"; status ABORTED "" 12 provision/appa-dev; RC=$?
set_pr open provision/appa-dev main
[ "$RC" -eq 0 ] && [ "$(ncomments)" = 1 ] && last_body | grep -q 'ABANDONNE' && last_body | grep -q 'provision-plan #77' \
  && ok "ABORTED sans faits ⇒ forge relue, statut « ABANDONNE, aucun verdict », repli textuel provision-plan #77 (BUILD_URL vide)" || ko "ABORTED : rc=$RC $(cat "$TMP/st.out") body=$(last_body | head -c 120)"
printf '[]' > "$STUB_COMMENTS"; status FAILURE "$F_FAIL" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && last_body | grep -q 'NEGATIF' && ok "FAILURE + fail ⇒ « verdict NEGATIF, voir provision-plan »" || ko "FAILURE+fail : $(last_body | head -c 120)"
printf '[]' > "$STUB_COMMENTS"; status FAILURE "$F_REFUS" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && last_body | grep -q 'REFUS avant le verdict' && last_body | grep -q 'CLONE_ECHEC' && ok "FAILURE + refus (forge confirmée, clone refusé) ⇒ « REFUS avant le verdict : CLONE_ECHEC »" || ko "FAILURE+refus : $(last_body | head -c 120)"
printf '[]' > "$STUB_COMMENTS"; status FAILURE "$F_NC" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && [ "$(ncomments)" = 0 ] && grep -q "n'a pas obtenu la confirmation" "$TMP/st.out" && ok "faits « refus, tête vide » (FORGE_NON_CONFIRMEE) ⇒ AUCUN commentaire : la PR nommée par le payload n'est pas la nôtre" || ko "faits non confirmés : n=$(ncomments) $(cat "$TMP/st.out")"
printf '[]' > "$STUB_COMMENTS"; status FAILURE "" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && [ "$(ncomments)" = 1 ] && last_body | grep -q 'ECHOUE (FAILURE) avant le plan' && grep -q 'GET /api/v1/repos/ci/stoa-labs/pulls/12' "$STUB_LOG" \
  && ok "FAILURE sans faits ⇒ forge relue par la lib, statut « ECHOUE (FAILURE) avant le plan »" || ko "FAILURE sans faits : n=$(ncomments) $(cat "$TMP/st.out")"
set_pr open provision/appb-dev main; printf '[]' > "$STUB_COMMENTS"; status FAILURE "" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && [ "$(ncomments)" = 0 ] && grep -q 'forge non confirmee' "$TMP/st.out" && ok "FAILURE sans faits, forge divergente ⇒ AUCUN commentaire (rc 0)" || ko "forge divergente : n=$(ncomments) $(cat "$TMP/st.out")"
: > "$STUB_LOG"; status FAILURE "" 'x' provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && [ "$(nreq GET)" = 0 ] && ok "PR_NUMBER non numérique ⇒ rc 0, aucun appel" || ko "PR_NUMBER non numérique : rc=$RC GET=$(nreq GET)"
set_pr open provision/appa-dev main; printf '[]' > "$STUB_COMMENTS"; ST_BUILD_URL=http://j/job/provision-plan/78/ status ABORTED "" 12 provision/appa-dev
last_body | grep -q 'http://j/job/provision-plan/78/' && ok "BUILD_URL posé ⇒ le lien est dans le corps" || ko "BUILD_URL ignoré"
printf '[]' > "$STUB_COMMENTS"; status ABORTED "$F_OK" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && last_body | grep -q 'verdict a ete RENDU' && ! last_body | grep -q 'AUCUN verdict' && ok "ABORTED + verdict ok ⇒ « verdict RENDU, build termine ABORTED apres coup » (jamais « AUCUN verdict » à côté d'un ✅)" || ko "ABORTED+ok : $(last_body | head -c 140)"
printf '[]' > "$STUB_COMMENTS"; status UNSTABLE "$F_OK" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && last_body | grep -q 'verdict a ete RENDU' && ! last_body | grep -q 'injoignable' && ok "UNSTABLE + verdict ok ⇒ verdict RENDU (jamais « agent injoignable »)" || ko "UNSTABLE+ok : $(last_body | head -c 140)"
F_CE='GITEA_HEAD_REF=provision/appa-dev\nGITEA_HEAD_SHA=cccc\nPLAN_VERDICT=refus\nPLAN_REASON=COMMENTAIRE_ECHEC : plan ok sur x mais le commentaire de verdict n a pas pu etre pose\n'
printf '[]' > "$STUB_COMMENTS"; status FAILURE "$F_CE" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && last_body | grep -q 'REFUS avant le verdict' && last_body | grep -q 'COMMENTAIRE_ECHEC' && ok "verdict rendu mais commentaire en échec ⇒ « REFUS avant le verdict : COMMENTAIRE_ECHEC » (vrai), pas « agent injoignable »" || ko "COMMENTAIRE_ECHEC : $(last_body | head -c 140)"
F_AUTRE='PLAN_PR_NUMBER=99\nGITEA_HEAD_REF=provision/appa-dev\nGITEA_HEAD_SHA=cccc\nPLAN_VERDICT=ok\nPLAN_REASON=x\n'
printf '[]' > "$STUB_COMMENTS"; status FAILURE "$F_AUTRE" 12 provision/appa-dev; RC=$?
[ "$RC" -eq 0 ] && [ "$(ncomments)" = 0 ] && grep -q 'autre PR' "$TMP/st.out" && ok "faits d'une AUTRE PR (#99, workspace persistant) ⇒ périmés, aucun statut" || ko "faits d'une autre PR relus : n=$(ncomments) $(cat "$TMP/st.out")"
printf '[]' > "$STUB_COMMENTS"; rm -f "$TMP/st.facts"; : > "$STUB_LOG"
BUILD_RESULT=FAILURE PLAN_FACTS="$TMP/st.facts" GITEA_HEAD_REF=provision/appa-dev PLAN_VERDICT=ok PLAN_PR_NUMBER=99 PR_NUMBER=12 PR_BRANCH=provision/appa-dev GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH9" GIT_REPO=ci/stoa-labs bash scripts/provision-plan-status.sh >"$TMP/st.out" 2>&1
[ "$(ncomments)" = 0 ] && grep -q 'autre PR' "$TMP/st.out" && ok "faits en env d'une autre PR ⇒ aucun statut" || ko "faits env d'une autre PR relus"
grep -q 'à' "$TMP/st.out" && ko "accents dans la sortie du statut" || true
for W in 'IGNOREE' 'ABANDONNE' 'NEGATIF' 'ECHOUE'; do grep -q "$W" scripts/provision-plan-status.sh || ko "corps '$W' absent"; done
grep -vE '^\s*#' scripts/provision-plan-status.sh | grep -qE "[àâéèêîôûç]" && ko "corps de statut avec accents (traversent agent/JSON/Gitea)" || ok "corps de statut sans accents (vue code)"

echo
echo "== 9. (d bis) statut : les faits peuvent venir de l'ENVIRONNEMENT (post de stage) =="
printf '[]' > "$STUB_COMMENTS"; rm -f "$TMP/st.facts"; : > "$STUB_LOG"
BUILD_RESULT=SUCCESS PLAN_FACTS="$TMP/st.facts" GITEA_HEAD_REF=provision/appa-dev PLAN_VERDICT=ignore PLAN_REASON='aucun manifeste ajoute' \
  PR_NUMBER=12 PR_BRANCH=provision/appa-dev GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH9" GIT_REPO=ci/stoa-labs JOB_NAME=provision-plan BUILD_NUMBER=79 \
  bash scripts/provision-plan-status.sh >"$TMP/st.out" 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(ncomments)" = 1 ] && last_body | grep -q 'IGNOREE' && ! grep -q 'GET /api/v1/repos/ci/stoa-labs/pulls' "$STUB_LOG" \
  && ok "faits en env (sans fichier) ⇒ statut IGNOREE posé SANS relire la forge (le nœud du post n'a pas besoin du workspace du stage)" || ko "faits en env : rc=$RC n=$(ncomments) $(cat "$TMP/st.out")"
printf '[]' > "$STUB_COMMENTS"; rm -f "$TMP/st.facts"
BUILD_RESULT=FAILURE PLAN_FACTS="$TMP/st.facts" GITEA_HEAD_REF= PLAN_VERDICT=refus PLAN_REASON='FORGE_NON_CONFIRMEE : tete divergente' \
  PR_NUMBER=12 PR_BRANCH=provision/appa-dev GITEA_TOKEN="$STUB_TOKEN" GIT_HOST="$GH9" GIT_REPO=ci/stoa-labs bash scripts/provision-plan-status.sh >"$TMP/st.out" 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(ncomments)" = 0 ] && ok "faits en env « refus, tête vide » ⇒ aucun commentaire" || ko "faits env non confirmés : n=$(ncomments)"

echo
echo "== 9. (e) ci/Jenkinsfile.provision-plan : faits dans le sh, post de STAGE qui les charge, post de PIPELINE gardé AVANT tout nœud =="
code_view ci/Jenkinsfile.provision-plan > "$TMP/jf-plan2.code"
L_SHP=$(code_line "$TMP/jf-plan2.code" "sh 'set +x; rm -f \"\$WORKSPACE/.plan.facts\"; PLAN_FACTS=\"\$WORKSPACE/.plan.facts\" bash scripts/provision-plan.sh'")
[ -n "$L_SHP" ] && ok "le plan est invoqué avec rm -f des faits PÉRIMÉS puis PLAN_FACTS=\$WORKSPACE/.plan.facts, quotes simples, set +x (ligne $L_SHP)" || ko "invocation du plan sans purge des faits ou sans PLAN_FACTS"
L_RF=$(code_line "$TMP/jf-plan2.code" 'readFile(f).readLines().each')
L_ENVH=$(code_line "$TMP/jf-plan2.code" "if (k == 'GITEA_HEAD_REF') { env.GITEA_HEAD_REF = v }")
L_ENVV=$(code_line "$TMP/jf-plan2.code" "if (k == 'PLAN_VERDICT')   { env.PLAN_VERDICT = v }")
L_POST=$(grep -n '^  post {' "$TMP/jf-plan2.code" | head -1 | cut -d: -f1)
[ -n "$L_RF" ] && [ -n "$L_ENVH" ] && [ -n "$L_ENVV" ] && [ -n "$L_POST" ] && [ "$L_SHP" -lt "$L_RF" ] && [ "$L_RF" -lt "$L_POST" ] && grep -qF "env.PLAN_PR_NUMBER = v" "$TMP/jf-plan2.code" \
  && ok "post de STAGE (ligne $L_RF, après le sh, avant le post de pipeline ligne $L_POST) charge GITEA_HEAD_REF / PLAN_VERDICT / PLAN_PR_NUMBER dans env" || ko "post de stage absent ou mal placé (sh=$L_SHP rf=$L_RF envh=$L_ENVH post=$L_POST)"
POSTV="$TMP/jf-plan2.post"; awk "NR>=${L_POST:-1}" "$TMP/jf-plan2.code" > "$POSTV"
L_G=$(code_line "$POSTV" "if (!ref.startsWith('provision/') || !(num ==~ /[0-9]+/))")
L_TRY=$(code_line "$POSTV" 'try {'); L_TO=$(code_line "$POSTV" "timeout(time: 2, unit: 'MINUTES')"); L_ND=$(code_line "$POSTV" 'node("${env.POST_AGENT_LABEL ?: '"''"'}")')
L_ST=$(code_line "$POSTV" "sh 'set +x; bash scripts/provision-plan-status.sh || echo")
L_CATCH=$(code_line "$POSTV" 'catch (e)')
[ -n "$L_G" ] && [ -n "$L_ND" ] && [ "$L_G" -lt "$L_ND" ] && ok "post de pipeline : garde Groovy provision/* + PR_NUMBER numérique (ligne +$L_G) AVANT node( (ligne +$L_ND) — aucun exécuteur pour une PR étrangère" || ko "garde absente ou après node (g=$L_G node=$L_ND)"
[ -n "$L_TRY" ] && [ -n "$L_TO" ] && [ -n "$L_CATCH" ] && [ "$L_TRY" -lt "$L_ND" ] && [ "$L_TO" -lt "$L_ND" ] && ok "try (+$L_TRY) et timeout 2 min (+$L_TO) enveloppent le nœud ; catch présent (+$L_CATCH) : le statut ne rougit ni ne bloque jamais" || ko "try/timeout/catch absents ou mal placés (try=$L_TRY to=$L_TO catch=$L_CATCH node=$L_ND)"
[ -n "$L_ST" ] && [ "$L_ND" -lt "$L_ST" ] && grep -q 'BUILD_RESULT=${currentBuild.currentResult}' "$POSTV" && grep -q "withCredentials(\[string(credentialsId: env.GITEA_CREDENTIALS_ID, variable: 'GITEA_TOKEN')\])" "$POSTV" \
  && ok "provision-plan-status.sh invoqué sous node + credential + BUILD_RESULT (quotes simples, set +x, || echo)" || ko "invocation du statut absente/mal enveloppée (st=$L_ST)"
grep -q "provision-plan-build" scripts/provision-plan-status.sh && grep -q "COMMENT_MARKER='<!-- provision-plan -->'" scripts/provision-plan.sh \
  && ok "marqueurs DISTINCTS : verdict <!-- provision-plan -->, statut <!-- provision-plan-build -->" || ko "marqueurs non distincts"
[ "$(grep -c 'provision-plan.sh' "$TMP/jf-plan2.code")" -eq 1 ] && [ "$(grep -c 'provision-plan-status.sh' "$TMP/jf-plan2.code")" -eq 1 ] && ok "le plan et le statut sont invoqués UNE fois chacun" || ko "invocations en double"

echo
echo "== 9. (f) ci/Jenkinsfile.provision-apply : la même garde AVANT le nœud du post =="
code_view ci/Jenkinsfile.provision-apply > "$TMP/jf-apply2.code"
L_POSTA=$(grep -n '^  post {' "$TMP/jf-apply2.code" | head -1 | cut -d: -f1); POSTA="$TMP/jf-apply2.post"; awk "NR>=${L_POSTA:-1}" "$TMP/jf-apply2.code" > "$POSTA"
L_GA=$(code_line "$POSTA" "if (!ref.startsWith('provision/') || !(num ==~ /[0-9]+/))"); L_NDA=$(code_line "$POSTA" 'node("${env.POST_AGENT_LABEL ?: '"''"'}")')
[ -n "$L_GA" ] && [ -n "$L_NDA" ] && [ "$L_GA" -lt "$L_NDA" ] && ok "provision-apply : garde Groovy (+$L_GA) AVANT node( (+$L_NDA)" || ko "provision-apply : garde absente ou après node (g=$L_GA node=$L_NDA)"
code_line "$POSTA" 'try {' >/dev/null && [ -n "$(code_line "$POSTA" "timeout(time: 2, unit: 'MINUTES')")" ] && grep -q 'GITEA_HEAD_REF:-' "$POSTA" \
  && ok "provision-apply : try + timeout autour du nœud, et le gate de FORGE (GITEA_HEAD_REF) reste dans le sh" || ko "provision-apply : try/timeout absents ou gate forge disparu"

echo
echo "== 9. (g) provisioning-request : pas de post{always}, et les faits qui le justifient sont VRAIS =="
grep -q "POURQUOI CE JOB N'A PAS DE post{always}" ci/Jenkinsfile.provisioning-request && grep -q 'PRÉEXISTER' ci/Jenkinsfile.provisioning-request \
  && ok "le Jenkinsfile documente l'absence de statut ET ses deux limites (rejeu, ERR après POST /pulls)" || ko "justification absente/incomplète"
grep -qE '^\s*post \{' ci/Jenkinsfile.provisioning-request && ko "un post{} existe pourtant" || ok "aucun post{} (rien à commenter avant le succès)"
PRS=scripts/provision-request.sh
L_4=$(grep -n 'echo "\[4/5\] ouverture de la Pull Request' "$PRS" | cut -d: -f1); L_5=$(grep -n 'echo "\[5/5\] plan enchaîné sur la PR' "$PRS" | cut -d: -f1)
[ -n "$L_4" ] && [ -n "$L_5" ] && [ "$L_4" -lt "$L_5" ] && ok "la PR naît en [4/5] (ligne $L_4), le plan enchaîné suit en [5/5] (ligne $L_5)" || ko "numérotation/ordre [4/5]<[5/5] cassés (4=$L_4 5=$L_5)"
L_PF=$(grep -n 'PLAN_INLINE=fail' "$PRS" | cut -d: -f1)
[ -n "$L_PF" ] && ! sed -n "$((L_PF)),$((L_PF+2))p" "$PRS" | grep -qE 'exit [1-9]' && ok "PLAN_INLINE=fail (ligne $L_PF) n'est suivi d'aucun exit non nul : le plan enchaîné n'est pas fatal" || ko "le plan enchaîné est devenu fatal"
grep -q 'EXIST\*)   echo "  PR déjà ouverte' "$PRS" && ok "EXIST (PR préexistante au rejeu) est un succès" || ko "EXIST n'est plus traité comme succès"

echo
echo "== 10. DETTE 2 — selfservice-app-deploy : formulaire posé par le Jenkinsfile, XML sans paramètre, liste dérivée =="
JSF="ci/Jenkinsfile.selfservice"; SSJ="scripts/setup-selfservice-job.sh"; code_view "$JSF" > "$TMP/jsf.code"
jss(){ grep -qF -- "$1" "$TMP/jsf.code"; }
grep -qE '^\s*parameters \{' "$TMP/jsf.code" && ko "un bloc parameters{} déclaratif subsiste (il fusionnerait par nom avec properties() : formulaire flottant)" || ok "aucun bloc parameters{} déclaratif"
L_FORM=$(code_line "$TMP/jsf.code" "stage('Formulaire — paliers dérivés de la chaîne')"); L_PROPS=$(code_line "$TMP/jsf.code" 'properties([')
L_REF=$(code_line "$TMP/jsf.code" "stage('Référence — le SHA mergé"); L_REQ=$(code_line "$TMP/jsf.code" 'MERGE_SHA_REQUIS'); L_PLAN=$(code_line "$TMP/jsf.code" "stage('Plan — valider"); L_APPLY=$(code_line "$TMP/jsf.code" "stage('Apply — converge")
[ -n "$L_FORM" ] && [ -n "$L_PROPS" ] && [ -n "$L_REF" ] && [ -n "$L_REQ" ] && [ -n "$L_PLAN" ] && [ -n "$L_APPLY" ] && [ "$L_FORM" -lt "$L_PROPS" ] && [ "$L_PROPS" -lt "$L_REF" ] && [ "$L_REF" -lt "$L_REQ" ] && [ "$L_REQ" -lt "$L_PLAN" ] && [ "$L_PLAN" -lt "$L_APPLY" ] \
  && ok "ordre Formulaire ($L_FORM) < properties ($L_PROPS) < Référence ($L_REF) < MERGE_SHA_REQUIS ($L_REQ) < Plan ($L_PLAN) < Apply ($L_APPLY)" || ko "ordre des stages cassé (form=$L_FORM props=$L_PROPS ref=$L_REF req=$L_REQ plan=$L_PLAN apply=$L_APPLY)"
MISS=""; for P in MANIFEST MERGE_SHA ENVIRONMENT ADMIN_VIA DEBUG VAULT_USER VAULT_USER_PASSWORD USER_VAULT_JWT; do jss "(name: '$P'" || MISS="$MISS $P"; done
[ -z "$MISS" ] && ok "les 8 paramètres sont posés par properties()" || ko "paramètres absents :$MISS"
jss "choice(name: 'ENVIRONMENT', choices: envs" && ok "ENVIRONMENT : choices: envs (dérivée)" || ko "ENVIRONMENT n'est pas dérivée"
grep -qE "\['dev'|'homol'|'rec', 'int'" "$TMP/jsf.code" && ko "une liste de paliers LITTÉRALE subsiste" || ok "aucune liste de paliers littérale dans Jenkinsfile.selfservice"
L_DIRF=$(awk "NR>${L_FORM:-0} && /dir\(env\.GIT_SUBDIR\)/ {print NR; exit}" "$TMP/jsf.code"); L_DER=$(code_line "$TMP/jsf.code" 'env-chain.sh && env_chain_validate && env_chain" > "$WORKSPACE/.a0-envs"')
[ -n "$L_DIRF" ] && [ -n "$L_DER" ] && [ "$L_DIRF" -lt "$L_DER" ] && [ "$L_DER" -lt "$L_PROPS" ] && ok "dérivation env_chain (validée, chaîne ENTIÈRE — A7) sous dir() (ligne $L_DER), avant properties()" || ko "dérivation absente/mal placée (dir=$L_DIRF der=$L_DER)"
jss 'envs.every { it ==~ /[a-z0-9]+/ }' && jss 'FORMULAIRE_INVALIDE' && ok "paliers validés ^[a-z0-9]+$, refus FORMULAIRE_INVALIDE (définitions précédentes conservées)" || ko "validation des paliers absente"
# Les listes withEnv EXACTES par stage (revue : compter MANIFEST ne prouvait rien
# pour les 6 autres) — extraites de la vue code jusqu'au `]) {` de chaque withEnv.
wenv_names(){ # $1=numéro de ligne du withEnv → noms, séparés par espace
  awk -v s="$1" 'NR>=s { print; if ($0 ~ /\]\) \{/) exit }' "$TMP/jsf.code" | grep -oE '"[A-Z_]+=\$\{params\.' | sed -E 's/^"([A-Z_]+)=.*/\1/' | tr '\n' ' ' | sed 's/ $//'
}
L_W1=$(awk "NR>${L_REF:-0} && /withEnv\(\[/ {print NR; exit}" "$TMP/jsf.code"); L_W2=$(awk "NR>${L_PLAN:-0} && /withEnv\(\[/ {print NR; exit}" "$TMP/jsf.code"); L_W3=$(awk "NR>${L_APPLY:-0} && /withEnv\(\[/ {print NR; exit}" "$TMP/jsf.code")
[ "$(wenv_names "$L_W1")" = "MANIFEST MERGE_SHA ENVIRONMENT" ] && [ "$(wenv_names "$L_W2")" = "MANIFEST MERGE_SHA ENVIRONMENT" ] \
  && ok "withEnv brut de Référence et Plan = exactement MANIFEST MERGE_SHA ENVIRONMENT (fait 7)" || ko "withEnv Référence=[$(wenv_names "$L_W1")] Plan=[$(wenv_names "$L_W2")]"
[ "$(wenv_names "$L_W3")" = "MANIFEST MERGE_SHA ENVIRONMENT ADMIN_VIA DEBUG VAULT_USER USER_VAULT_JWT" ] \
  && ok "withEnv brut de l'Apply = exactement les 7 paramètres NON secrets (fait 7)" || ko "withEnv Apply=[$(wenv_names "$L_W3")]"
grep -q 'VAULT_USER_PASSWORD=${params' "$TMP/jsf.code" && ko "le mot de passe passe par un withEnv — il serait PERSISTÉ EN CLAIR dans flowNodeStore.xml (fait 9, mesuré)" || ok "le mot de passe ne traverse AUCUN step (fait 9 : withEnv le persisterait en clair) — canal natif conservé"
L_GARDE=$(code_line "$TMP/jsf.code" "MOT_DE_PASSE_ALTERE"); L_BRUT=$(code_line "$TMP/jsf.code" 'def brut = "${params.VAULT_USER_PASSWORD ?: '"''"'}"')
[ -n "$L_GARDE" ] && [ -n "$L_BRUT" ] && [ "$L_APPLY" -lt "$L_BRUT" ] && [ "$L_BRUT" -lt "$L_GARDE" ] && [ "$L_GARDE" -lt "$L_W3" ] && jss 'brut != "${env.VAULT_USER_PASSWORD ?: '"''"'}"' \
  && ok "garde MOT_DE_PASSE_ALTERE (ligne $L_GARDE) : « \${params} » brut ≠ env résolu ⇒ refus fermé AVANT le withEnv de l'Apply (ligne $L_W3), aucun step ne reçoit le secret" || ko "garde du mot de passe absente/mal placée (apply=$L_APPLY brut=$L_BRUT garde=$L_GARDE w3=$L_W3)"
jss '"DEBUG=${params.DEBUG ?: false}"' && ok "DEBUG=\${params.DEBUG ?: false} (jamais la chaîne « null » sur un job non matérialisé)" || ko "DEBUG sans repli"
jss '"MANIFEST=${params.MANIFEST ?: (env.MANIFEST ?: '"''"')}"' && ok "MANIFEST retombe sur env.MANIFEST (valeur GWT) quand le paramètre n'est pas matérialisé : un PLAN par webhook ne tourne jamais sur le manifeste par défaut" || ko "MANIFEST sans repli env.MANIFEST"
if grep -qE '^  (options|triggers) \{' "$TMP/jsf.code"; then ko "options{}/triggers{} déclaratifs présents — fait 10 : PERDUS au premier build d'un job re-posé"; else ok "aucun options{}/triggers{} déclaratif (fait 10)"; fi
jss 'disableConcurrentBuilds(),' && jss "pipelineTriggers([GenericTrigger(token: 'stoa-selfservice-plan'," && ok "properties() pose AUSSI disableConcurrentBuilds et le trigger PLAN (stoa-selfservice-plan) — les trois propriétés en un seul pas (fait 10)" || ko "trigger/option absents de properties()"
# ── le poseur ──
printf 'environments: [alpha, beta, gamma, delta, eps, zeta]\n' > "$TMP/chain10.yaml"
STOA_ENV_CHAIN_FILE="$TMP/chain10.yaml" bash "$SSJ" --print > "$TMP/ss-no.xml" 2>"$TMP/ss.err"; RC=$?
NP=$(python3 -c "import sys,xml.etree.ElementTree as T; r=T.parse(sys.argv[1]).getroot(); print(sum(1 for e in r.iter() if e.tag.endswith('ParameterDefinition')), sum(1 for e in r.iter() if e.tag.endswith('ParametersDefinitionProperty')), sum(1 for e in r.iter() if e.tag.endswith('GenericTrigger')), sum(1 for e in r.iter() if e.tag.endswith('DisableConcurrentBuildsJobProperty')))" "$TMP/ss-no.xml" 2>/dev/null)
[ "$RC" -eq 0 ] && [ "$NP" = "0 0 0 0" ] && grep -q '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.selfservice</scriptPath>' "$TMP/ss-no.xml" \
  && ok "setup-selfservice-job.sh --print (auto ⇒ XML_PARAMS=no) : AUCUNE propriété — ni paramètre, ni trigger, ni option (faits 6 et 10 : ni doublon, ni perte)" || ko "--print mode no : rc=$RC params/prop/trig/dis=$NP $(tail -2 "$TMP/ss.err")"
OUT=$(gwt_mirror_diff "$TMP/ss-no.xml" "$JSF" 2>&1); RC=$?; [ "$RC" -eq 2 ] && [ "$OUT" = "DIVERGENCE trigger xml=absent jenkinsfile=present" ] && ok "miroir : le trigger PLAN n'est QUE dans le Jenkinsfile (xml=absent jenkinsfile=present) — l'état voulu pour ce job (fait 10), pas une divergence" || ko "miroir XML rendu / Jenkinsfile.selfservice : $OUT (rc=$RC)"
STOA_ENV_CHAIN_FILE="$TMP/chain10.yaml" JOB=publish-api-deploy TRIGGER_TOKEN=stoa-publish-api-plan SCRIPT_PATH=poc-control-plane-federation/ci/Jenkinsfile.publish-api bash "$SSJ" --print > "$TMP/ss-yes.xml" 2>"$TMP/ss.err"; RC=$?
ENVX=$(python3 -c "
import sys, xml.etree.ElementTree as T
r = T.parse(sys.argv[1]).getroot()
for p in r.iter():
    if p.tag.endswith('ChoiceParameterDefinition') and p.findtext('name') == 'ENVIRONMENT': print(' '.join(s.text or '' for s in p.iter('string')))" "$TMP/ss-yes.xml" 2>/dev/null)
[ "$RC" -eq 0 ] && [ "$ENVX" = "alpha beta gamma delta eps zeta" ] && grep -q '<name>MERGE_SHA</name>' "$TMP/ss-yes.xml" && grep -q '<token>stoa-publish-api-plan</token>' "$TMP/ss-yes.xml" && grep -q 'DisableConcurrentBuildsJobProperty' "$TMP/ss-yes.xml" \
  && ok "--print publish-api-deploy (XML_PARAMS=yes) : ENVIRONMENT DÉRIVÉE à la pose [$ENVX], terminus zeta PRÉSENT (A7 : build job: valide les choice, mesuré), MERGE_SHA présent (ceinture SECURITY-170), trigger + option dans le XML (bloc déclaratif côté Jenkinsfile)" || ko "--print mode yes : rc=$RC ENVIRONMENT=[$ENVX]"
sed 's/ENVS="$(env_chain)"/ENVS="$(env_chain_nonprod)"/' "$SSJ" > "$TMP/ssj_mut.sh"; cp -R scripts/lib "$TMP/" 2>/dev/null; mkdir -p "$TMP/scripts"; cp "$TMP/ssj_mut.sh" "$TMP/scripts/setup-selfservice-job.sh"; cp -R scripts/lib "$TMP/scripts/"
ENVM=$(STOA_ENV_CHAIN_FILE="$TMP/chain10.yaml" JOB=publish-api-deploy SCRIPT_PATH=poc-control-plane-federation/ci/Jenkinsfile.publish-api bash "$TMP/scripts/setup-selfservice-job.sh" --print 2>/dev/null | python3 -c "
import sys, xml.etree.ElementTree as T
r = T.fromstring(sys.stdin.read())
for p in r.iter():
    if p.tag.endswith('ChoiceParameterDefinition') and p.findtext('name') == 'ENVIRONMENT': print(' '.join(s.text or '' for s in p.iter('string')))")
[ "$ENVM" = "alpha beta gamma delta eps" ] && ok "mutation env_chain→env_chain_nonprod dans le poseur ⇒ le TERMINUS disparaît (zeta) : la dérivation est bien ce qui l'inclut (A7)" || ko "mutation du poseur sans effet : [$ENVM]"
grep -vE '^\s*#' "$SSJ" | grep -q 'BUILD_EP="build"' && grep -vE '^\s*#' "$SSJ" | grep -q "ParametersDefinitionProperty'))" && grep -q 'BOOTSTRAP_WAIT="${BOOTSTRAP_WAIT:-360}"' "$SSJ" && grep -vE '^\s*#' "$SSJ" | grep -q 'attendu UN trigger $TRIGGER_TOKEN et UNE option' \
  && ok "poseur : amorçage POST /build en mode no, relecture « UNE propriété + trigger + option posés par le build » (faits 6/10), BOOTSTRAP_WAIT 360 s" || ko "poseur : amorçage/relecture/attente non câblés"
printf 'environments: [alpha, Beta, gamma]\n' > "$TMP/chain10b.yaml"
OUTB=$(STOA_ENV_CHAIN_FILE="$TMP/chain10b.yaml" JOB=publish-api-deploy SCRIPT_PATH=poc-control-plane-federation/ci/Jenkinsfile.publish-api bash "$SSJ" --print 2>"$TMP/ss.err"); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUTB" ] && grep -q 'PALIER_INVALIDE' "$TMP/ss.err" && ok "--print mode yes avec un palier invalide (Beta) ⇒ rc 1, PALIER_INVALIDE sur stderr, stdout VIDE (jamais un message pris pour du XML)" || ko "palier invalide : rc=$RC stdout=$(printf '%s' "$OUTB" | head -c 60) err=$(tail -1 "$TMP/ss.err")"
grep -q "choices: \['dev', 'rec', 'int', 'prod'\]" ci/Jenkinsfile.publish-api && ok "exception NOMMÉE : ci/Jenkinsfile.publish-api garde sa liste littérale avec le terminus (chaîne des APIs, décision producteur, hors périmètre A0)" || ko "l'exception publish-api n'est plus celle décrite (liste modifiée ?) — mettre la spec à jour"

echo
echo "== 8. contre-épreuve du miroir, par MUTATION (le test de miroir ROUGIT) =="
# (a) le XML privé de son bloc <triggers> ⇒ rc 2, un seul côté déclare.
# Mutation STRUCTURELLE (l'en-tête du XML cite « <triggers> » en commentaire :
# un `sed` par plage l'aurait éventré).
python3 - ci/jenkins/provision-apply.job.xml "$TMP/pa-sans-triggers.xml" <<'PY'
import sys, xml.etree.ElementTree as T
t = T.parse(sys.argv[1]); r = t.getroot(); p = r.find('properties')
for el in list(p):
    if el.tag.endswith('PipelineTriggersJobProperty'): p.remove(el)
t.write(sys.argv[2], encoding='unicode')
PY
OUT=$(gwt_mirror_diff "$TMP/pa-sans-triggers.xml" ci/Jenkinsfile.provision-apply 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^DIVERGENCE trigger xml=absent jenkinsfile=present' \
  && ok "XML sans <triggers> ⇒ rc 2 « DIVERGENCE trigger xml=absent » (le webhook serait borgne dès la pose)" \
  || ko "XML sans <triggers> non détecté (rc=$RC : $OUT)"
# (b) token altéré dans le XML ⇒ rc 1, champ nommé.
sed 's#<token>stoa-provision-apply</token>#<token>stoa-provision-apply-MUTE</token>#' ci/jenkins/provision-apply.job.xml > "$TMP/pa-token.xml"
OUT=$(gwt_mirror_diff "$TMP/pa-token.xml" ci/Jenkinsfile.provision-apply 2>&1); RC=$?
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '^DIVERGENCE token' \
  && ok "token altéré dans le XML ⇒ rc 1 « DIVERGENCE token »" || ko "token altéré non détecté (rc=$RC : $OUT)"
# (c) la VALEUR d'une clé altérée dans le XML (même clé, autre chemin JSON) ⇒ rc 1.
sed 's#<key>MERGE_SHA</key><value>$.pull_request.merge_commit_sha</value>#<key>MERGE_SHA</key><value>$.pull_request.head.sha</value>#' ci/jenkins/provision-apply.job.xml > "$TMP/pa-val.xml"
OUT=$(gwt_mirror_diff "$TMP/pa-val.xml" ci/Jenkinsfile.provision-apply 2>&1); RC=$?
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '^DIVERGENCE vars' && printf '%s' "$OUT" | grep -q 'head.sha' \
  && ok "valeur de MERGE_SHA altérée (head.sha) ⇒ rc 1 « DIVERGENCE vars » nommant la clé" \
  || ko "valeur altérée non détectée (rc=$RC : $OUT)"
# (d) le filtre altéré côté JENKINSFILE (fermeture sans merge) ⇒ rc 1.
sed "s#regexpFilterExpression: '^closed\\\\\\\\|true\$'#regexpFilterExpression: '^closed'#" ci/Jenkinsfile.provision-apply > "$TMP/jf-filtre"
grep -q "regexpFilterExpression: '^closed'" "$TMP/jf-filtre" || echo "  (avertissement : mutation (d) non appliquée)"
OUT=$(gwt_mirror_diff ci/jenkins/provision-apply.job.xml "$TMP/jf-filtre" 2>&1); RC=$?
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '^DIVERGENCE regexpFilterExpression' \
  && ok "filtre altéré côté Jenkinsfile (^closed) ⇒ rc 1 « DIVERGENCE regexpFilterExpression »" \
  || ko "filtre altéré côté Jenkinsfile non détecté (rc=$RC : $OUT)"
# (e) un commentaire qui NOMME un autre token ne verdit ni ne rougit rien (vue code).
{ echo "// token: 'stoa-un-autre-token' — commentaire, pas du code"; cat ci/Jenkinsfile.provision-apply; } > "$TMP/jf-comm"
OUT=$(gwt_mirror_diff ci/jenkins/provision-apply.job.xml "$TMP/jf-comm" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "un token cité dans un COMMENTAIRE Groovy est ignoré (vue code) : miroir toujours exact" \
  || ko "un commentaire a fait diverger le miroir (rc=$RC : $OUT)"

echo
echo "== 10. le total de contrôles exécutés correspond au total ATTENDU, écrit en dur =="
ACTUAL=$((PASS+FAIL))
[ "$ACTUAL" -eq "$EXPECTED_CHECKS" ] \
  && ok "nombre de contrôles exécutés = ${EXPECTED_CHECKS}" \
  || ko "nombre de contrôles exécutés = ${ACTUAL}, attendu ${EXPECTED_CHECKS} — une section a été sautée ou le total n'a pas été mis à jour"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
