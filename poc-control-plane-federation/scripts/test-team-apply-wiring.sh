#!/usr/bin/env bash
# test-team-apply-wiring.sh — preuve X/X du CÂBLAGE du job team-apply.
# Analyse statique : ni Jenkins, ni Gitea.
#
# ── CE QUI A CHANGÉ (conversion en Jenkinsfile déclaratif) ───────────────────
# Le pipeline ne vit PLUS en Groovy inline dans ci/jenkins/team-apply.job.xml
# (<script>…</script>) : il est dans ci/Jenkinsfile.team-apply, DÉCLARATIF, et
# le XML n'est plus qu'une coquille « Pipeline from SCM ». Ce test suit :
#   - $JF  (le Jenkinsfile)  porte désormais les gardes du PIPELINE ;
#   - $JOB (le XML)          ne porte plus que le déclencheur + le pointeur SCM,
#                            et doit prouver l'ABSENCE de tout Groovy inline.
# Les sections qui visent scripts/team-apply.sh et la garde d'identité (§10,
# §11) sont inchangées : ce moteur-là n'a pas bougé d'une ligne.
#
# Les constructions Groovy vérifiées avant ont un ÉQUIVALENT DÉCLARATIF vérifié
# à leur place, jamais un simple abandon de contrôle :
#   if (!ref.startsWith('onboard/')) { return }
#                           →  `when { beforeInput true; expression … }`
#                              (la condition passe AVANT la pause : une PR hors
#                              onboard/* ne réveille personne) ;
#   input() hors de node{}  →  `agent none` + directive `input` de stage
#                              (évaluée AVANT l'allocation de l'agent : la pause
#                              ne réserve AUCUN exécuteur) ;
#   withEnv([G_MERGED_BY…]) →  variables DÉJÀ dans l'environnement (contribuées
#                              par GenericTrigger) + paramètres de la directive
#                              `input` ; ce qui comptait — aucune interpolation
#                              Groovy dans une chaîne shell — est vérifié §7 ;
#   export VAR=… dans le sh →  bloc `environment {}` de niveau pipeline, dont
#                              l'ordre (avant `stages`) est vérifié §12.
#
# Motif anti « vert vacant » repris de test-team-publish-wiring.sh (panel, §F) :
# pas de grep NU (un motif présent dans un COMMENTAIRE qui NOMME la chose sans
# jamais l'appeler suffirait à verdir). Les ancres portent sur le CODE réel —
# syntaxe d'invocation précise (`sh scripts/lib/assert-merge-identity.sh`,
# `bash scripts/team-apply.sh`) ou paire complète option/variable.
#
#   ./scripts/test-team-apply-wiring.sh
# `A && ok || ko` (SC2015) est l'idiome des scripts de preuve du repo ; SC2016 vise
# les quotes SIMPLES délibérées. Directive de FICHIER posée le 2026-09-11 (L4) en
# entrant sous `make lint-ci` : la suite est désormais shellcheckée comme les autres.
# shellcheck disable=SC2015,SC2016
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/team-apply.job.xml"
JF="$REPO/ci/Jenkinsfile.team-apply"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# [Important, panel §F point 5] Total ATTENDU, ÉCRIT EN DUR — indépendant de
# PASS+FAIL (qui devient vrai par construction, quel que soit le nombre de
# contrôles réellement exécutés : une section entière sautée silencieusement
# ferait baisser le total affiché SANS jamais faire échouer ce script). Toute
# section ajoutée/retirée DOIT mettre à jour ce nombre à la main — un oubli
# fait virer le §16 au rouge, ce qui EST le comportement voulu (un rappel,
# pas un bug).
# NB : ce total compte les contrôles exécutés AVANT le §16 lui-même (le sien
# n'est pas encore compté quand la comparaison a lieu) — le `RÉSULTAT` final
# affiche donc EXPECTED_CHECKS+1. Même convention que test-team-publish-wiring.sh.
EXPECTED_CHECKS=107

[ -f "$JOB" ] || { echo "job introuvable : $JOB"; exit 2; }
[ -f "$JF" ]  || { echo "Jenkinsfile introuvable : $JF"; exit 2; }

# Lecture NORMALISÉE du Jenkinsfile : les espaces d'ALIGNEMENT (colonnes de
# `key:`/`=`) sont cosmétiques — un reformatage ne doit pas faire virer un
# contrôle au rouge, alors que la disparition d'une clé le doit.
JF_N="$(tr -s ' ' < "$JF")"
TMP="$(mktemp -d /tmp/ta-wiring.XXXXXX)"
# Le §3sexies monte une fausse forge (un python en tâche de fond) : le trap la
# tue AUSSI, sinon une interruption au milieu de la section laisserait un
# process et un port ouverts derrière elle.
trap 'rm -rf "$TMP"; [ -n "${FF_PID:-}" ] && kill "$FF_PID" 2>/dev/null; :' EXIT
# shellcheck source=scripts/lib/gwt-mirror.sh
. "$REPO/scripts/lib/gwt-mirror.sh" || { echo "lib gwt-mirror.sh introuvable"; exit 2; }
jf(){ printf '%s\n' "$JF_N" | grep -qF "$1"; }

echo "== 1. le XML reste bien formé, et le Jenkinsfile est bien un pipeline DÉCLARATIF =="
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "XML parsable" || ko "XML cassé"
grep -qE '^pipeline \{' "$JF" \
  && ok "le Jenkinsfile ouvre sur \`pipeline {\` (déclaratif, pas un script Groovy libre)" \
  || ko "le Jenkinsfile n'ouvre pas sur \`pipeline {\` — ce n'est pas un pipeline déclaratif"
grep -qE '^  stages \{' "$JF" \
  && ok "bloc \`stages\` de niveau pipeline présent" || ko "aucun bloc \`stages\` de niveau pipeline"

echo
echo "== 2. le webhook capte QUI a validé, QUI a demandé, et le SHA de merge =="
# Les deux fichiers portent le déclencheur ; c'est le XML qui GAGNE (§3). On
# vérifie ici le Jenkinsfile — le seul actif quand le job est posé sans XML —
# puis le XML en MIROIR juste après.
jf "[key: 'PR_BRANCH', value: '\$.pull_request.head.ref']" \
  && ok "PR_BRANCH capté (c'est lui qui porte équipe et env)" || ko "PR_BRANCH absent ou mal mappé"
jf "[key: 'PR_NUMBER', value: '\$.pull_request.number']" \
  && ok "PR_NUMBER capté" || ko "PR_NUMBER absent ou mal mappé"
jf "[key: 'PR_ACTION', value: '\$.action']" \
  && ok "PR_ACTION capté (moitié gauche du filtre GWT)" || ko "PR_ACTION absent — le filtre ne pourrait rien comparer"
jf "[key: 'PR_MERGED', value: '\$.pull_request.merged']" \
  && ok "PR_MERGED capté (moitié droite du filtre GWT)" || ko "PR_MERGED absent — une fermeture SANS merge passerait"
jf "[key: 'PR_MERGED_BY', value: '\$.pull_request.merged_by.login']" \
  && ok "merged_by.login capté" || ko "merged_by absent — la garde ne pourrait rien vérifier"
jf "[key: 'PR_REQUESTER', value: '\$.pull_request.user.login']" \
  && ok "user.login capté (quatre yeux)" || ko "requester absent"
jf "[key: 'MERGE_SHA', value: '\$.pull_request.merge_commit_sha']" \
  && ok "MERGE_SHA mappé sur merge_commit_sha" || ko "MERGE_SHA absent ou mal mappé — team-apply.sh l'exige (anti-TOCTOU)"
# ANTI-ÉLARGISSEMENT : aucun bloc `parameters {}`. Exposer PR_MERGED_BY en
# paramètre de build permettrait à quiconque peut lancer le job de saisir
# lui-même l'identité du valideur et de passer sa propre garde d'identité.
grep -qE '^  parameters \{' "$JF" \
  && ko "un bloc \`parameters {}\` de niveau pipeline expose les clés du webhook en saisie libre — auto-validation possible" \
  || ok "aucun bloc \`parameters {}\` : les clés du webhook ne viennent QUE du webhook (un build manuel échoue sur \${VAR:?})"

echo
echo "== 3. le filtre GWT est exact (fusion, pas juste fermeture) — et le XML est le MIROIR du Jenkinsfile =="
# DEUX visages sur le même texte (L5/L6) : une clé absente du payload arrive
# VIDE, donc un payload Gitea laisse GL_* vides et l'inverse. Le filtre accepte
# l'un OU l'autre, et JAMAIS une fermeture sans fusion.
jf "regexpFilterText: '\$PR_ACTION|\$PR_MERGED|\$GL_KIND:\$GL_ACTION'" \
  && ok "filterText = \$PR_ACTION|\$PR_MERGED|\$GL_KIND:\$GL_ACTION (Jenkinsfile, deux visages)" || ko "filterText inattendu dans le Jenkinsfile"
jf "regexpFilterExpression: '^closed\\\\|true\\\\||merge_request:merge\$'" \
  && ok "filterExpression = ^closed\\|true\\| … merge_request:merge\$ : fusion RÉELLE seulement, sur l'un OU l'autre visage" \
  || ko "filterExpression inattendue dans le Jenkinsfile — laisserait passer une fermeture SANS merge"
jf "token: 'stoa-team-apply'" \
  && ok "token de déclenchement = stoa-team-apply (Jenkinsfile)" || ko "token de déclenchement absent/inattendu"
# ── LE XML NE PORTE PLUS RIEN (L6 phase 2, 2026-09-12) ──────────────────────
# Il portait le même déclencheur « parce que c'est lui qui fait foi ». MESURÉ
# depuis (fait 10, puis spike-webhook-kind-m2m4) : un XML porteur + un
# properties() scripté donne un DOUBLON au build 1, puis l'exemplaire du XML est
# PERDU au build 2 — ce n'était pas une ceinture, c'était une avarie différée. Et
# un bloc `triggers {}` DÉCLARATIF exige au PARSE le plugin qui porte son
# symbole : sur un Jenkins sans generic-webhook-trigger, ce job mourait avant son
# premier stage. Le déclencheur et le verrou viennent donc du Jenkinsfile, selon
# WEBHOOK_KIND, et le XML est vide — l'amorçage, que le poseur s'impose en lisant
# ce XML (§18 de test-setup-provision-jobs.sh), les pose.
python3 -c "import sys,xml.etree.ElementTree as T; p=T.parse(sys.argv[1]).getroot().find('properties'); sys.exit(0 if p is not None and len(list(p))==0 else 1)" "$JOB" \
  && ok "le XML ne porte AUCUNE propriété (<properties/>) : ni déclencheur, ni verrou — ils viennent du BUILD" \
  || ko "le XML porte une propriété : doublon au build 1, perte au build 2"
grep -q '<key>' "$JOB" \
  && ko "le XML porte encore des genericVariables — le Jenkinsfile est le SEUL à déclarer" \
  || ok "aucune genericVariable dans le XML : le Jenkinsfile déclare seul"
OUT_M=$(gwt_mirror_diff "$JOB" "$JF" 2>&1); RC_M=$?
{ [ "$RC_M" -eq 2 ] && [ "$OUT_M" = "DIVERGENCE trigger xml=absent jenkinsfile=present token=stoa-team-apply vars=14" ]; } \
  && ok "miroir : « xml=absent jenkinsfile=present token=stoa-team-apply vars=14 » — l'état VOULU, et le côté présent est COMPTÉ (7 clés Gitea + 7 GitLab)" \
  || ko "miroir inattendu (rc=$RC_M) : $OUT_M"

echo
echo "== 3bis. le RÉCEPTEUR de webhooks : deux visages, refus nommé AVANT, état relu APRÈS =="
# STRUCTUREL, par ORDRE de lignes et par COMPTE — un `if` qui mente ne se voit
# pas au grep, et c'est l'angle mort assumé de cette porte (seule la preuve live
# le couvre). Mêmes règles que test-a0-wiring.sh §3bis, au nom du job près.
JF_C="$TMP/jf-team-apply.code"
sed -E 's@^[[:space:]]*//.*$@@' "$JF" > "$JF_C"
tr -s ' ' < "$JF_C" > "$JF_C.norm"
MISS=""
grep -qE '^  (options|triggers) \{' "$JF_C" && MISS="$MISS bloc-declaratif-present"
grep -qF "WEBHOOK_KIND = \"\${env.WEBHOOK_KIND ?: 'gwt'}\"" "$JF_C.norm" || MISS="$MISS env-WEBHOOK_KIND"
L_IF=$(grep -nF "if (hook == 'gwt') {" "$JF_C" | head -1 | cut -d: -f1)
L_PR=$(grep -nF 'properties([disableConcurrentBuilds(), pipelineTriggers([' "$JF_C" | head -1 | cut -d: -f1)
L_GL=$(grep -nF "} else if (hook == 'gitlab') {" "$JF_C" | head -1 | cut -d: -f1)
L_ER=$(grep -nF 'error("REFUS: WEBHOOK_KIND_INVALIDE' "$JF_C" | head -1 | cut -d: -f1)
L_FA=$(grep -nF 'env.PR_BRANCH = env.PR_BRANCH ?:' "$JF_C" | head -1 | cut -d: -f1)
if [ -n "$L_IF" ] && [ -n "$L_PR" ] && [ -n "$L_GL" ] && [ -n "$L_ER" ] && [ -n "$L_FA" ]; then
  { [ "$L_IF" -lt "$L_PR" ] && [ "$L_PR" -lt "$L_GL" ] && [ "$L_GL" -lt "$L_ER" ] && [ "$L_ER" -lt "$L_FA" ]; } \
    || MISS="$MISS ordre(if=$L_IF prop=$L_PR gitlab=$L_GL error=$L_ER fait=$L_FA)"
else MISS="$MISS ancres(if=${L_IF:-?} prop=${L_PR:-?} gitlab=${L_GL:-?} error=${L_ER:-?} fait=${L_FA:-?})"; fi
[ "$(grep -c 'GenericTrigger(' "$JF_C")" -eq 1 ] || MISS="$MISS GenericTrigger(x$(grep -c 'GenericTrigger(' "$JF_C"))"
[ "$(grep -c 'gitlab(' "$JF_C")" -eq 1 ] || MISS="$MISS gitlab(x$(grep -c 'gitlab(' "$JF_C"))"
[ "$(grep -c 'properties(\[disableConcurrentBuilds(), pipelineTriggers(\[' "$JF_C")" -eq 2 ] || MISS="$MISS properties-pas-2"
# Les défauts TRUE du plugin GitLab, figés ; la porte de branche est onboard/*
# (pas provision/* : ce job écoute les PR d'ONBOARDING du dépôt plateforme).
for K in "triggerOnMergeRequest: false" "triggerOnAcceptedMergeRequest: true" \
         "triggerOpenMergeRequestOnPush: 'never'" "triggerOnPush: false" \
         "triggerOnNoteRequest: false" "ciSkip: false" "setBuildDescription: false" \
         "skipWorkInProgressMergeRequest: false" "triggerOnClosedMergeRequest: false" \
         "triggerOnApprovedMergeRequest: false" "triggerOnPipelineEvent: false" \
         "triggerToBranchDeleteRequest: false" "cancelPendingBuildsOnUpdate: false" \
         "cancelRunningBuildsOnUpdate: false" "branchFilterType: 'RegexBasedFilter'" \
         "sourceBranchRegex: 'onboard/.*'" "targetBranchRegex: '.*'" \
         "secretToken: 'stoa-team-apply'" \
         "env.gitlabSourceBranch" "env.gitlabMergeRequestIid" "env.gitlabMergeCommitSha" \
         "!= 'merged'"; do
  grep -qF -- "$K" "$JF_C.norm" || MISS="$MISS [$K]"
done
# La PREMIÈRE occurrence de chaque symbole doit ÊTRE son appel : la vue code ne
# blanchit que les `//`, donc un symbole dans un /* */ serait COMPTÉ.
PREM=$(sed -n "$(grep -n 'GenericTrigger(' "$JF_C" | head -1 | cut -d: -f1)p" "$JF_C")
case "$PREM" in *"pipelineTriggers([GenericTrigger("*) ;; *) MISS="$MISS GenericTrigger-premiere-hors-appel" ;; esac
PREM=$(sed -n "$(grep -n 'gitlab(' "$JF_C" | head -1 | cut -d: -f1)p" "$JF_C")
case "$PREM" in *"pipelineTriggers([gitlab("*) ;; *) MISS="$MISS gitlab-premiere-hors-appel" ;; esac
[ -z "$MISS" ] \
  && ok "récepteur câblé : WEBHOOK_KIND (défaut gwt) ; if gwt ⇒ GenericTrigger deux visages ; else if gitlab ⇒ gitlab(… fusion seule, onboard/*, défauts TRUE figés) ; else error nommé ; le tout AVANT le fait unifié ; troisième visage gitlab* et ÉTAT relu" \
  || ko "récepteur mal câblé —$MISS"
# Les trois knobs de forge que les scripts de la chaîne producteur liront.
MISSK=""
for K in "FORGE_KIND = \"\${env.FORGE_KIND ?: 'gitea'}\"" \
         "FORGE_API_AUTH = \"\${env.FORGE_API_AUTH ?: ''}\"" \
         "FORGE_API_BASE = \"\${env.FORGE_API_BASE ?: ''}\""; do
  grep -qF -- "$K" "$JF_C.norm" || MISSK="$MISSK [$K]"
done
[ -z "$MISSK" ] \
  && ok "les trois knobs de forge sont dans environment{} (FORGE_KIND gitea par défaut, AUTH/BASE en repli VIDE) : les scripts de la chaîne producteur les lisent tels quels" \
  || ko "knobs de forge absents/divergents :$MISSK"

echo
echo "== 3ter. contre-épreuve du récepteur, par MUTATION =="
mut_ta(){ # <libellé> <sed>
  sed "$2" "$JF" > "$TMP/m.jf"
  if cmp -s "$TMP/m.jf" "$JF"; then ko "$1 : mutation NON appliquée"; return; fi
  sed -E 's@^[[:space:]]*//.*$@@' "$TMP/m.jf" > "$TMP/m.code"; tr -s ' ' < "$TMP/m.code" > "$TMP/m.norm"
  local bad=""
  grep -qE '^  (options|triggers) \{' "$TMP/m.code" && bad=1
  grep -qF "secretToken: 'stoa-team-apply'" "$TMP/m.norm" || bad=1
  grep -qF "triggerOnAcceptedMergeRequest: true" "$TMP/m.norm" || bad=1
  grep -qF "sourceBranchRegex: 'onboard/.*'" "$TMP/m.norm" || bad=1
  grep -qF 'error("REFUS: WEBHOOK_KIND_INVALIDE' "$TMP/m.code" || bad=1
  [ "$(grep -c 'gitlab(' "$TMP/m.code")" -eq 1 ] || bad=1
  # La PREMIÈRE occurrence doit ÊTRE l'appel : un `gitlab(` dans un /* */ serait
  # compté (la vue code ne blanchit que les //) — c'est ainsi que cette mutation
  # passait, et c'est le même trou que test-a0-wiring a fermé en phase 1.
  PREM_M=$(sed -n "$(grep -n 'gitlab(' "$TMP/m.code" | head -1 | cut -d: -f1)p" "$TMP/m.code")
  case "$PREM_M" in *"pipelineTriggers([gitlab("*) ;; *) bad=1 ;; esac
  [ "$(grep -c 'properties(\[disableConcurrentBuilds(), pipelineTriggers(\[' "$TMP/m.code")" -eq 2 ] || bad=1
  [ -n "$bad" ] && ok "$1 ⇒ rouge" || ko "$1 : mutation INVISIBLE à la porte"
}
mut_ta "triggerOnAcceptedMergeRequest true→false (la fusion ne construirait plus)" "s/triggerOnAcceptedMergeRequest: true/triggerOnAcceptedMergeRequest: false/"
mut_ta "la branche gardée devient provision/* (ce job écouterait les demandes d'APPLICATION)" "s#sourceBranchRegex: 'onboard/\.\*'#sourceBranchRegex: 'provision/.*'#"
mut_ta "secretToken altéré (la sonnette ne répondrait plus au mot)" "s/secretToken: 'stoa-team-apply'/secretToken: 'autre'/"
mut_ta "la branche else error() retirée (un knob inconnu passerait en silence)" "/error(\"REFUS: WEBHOOK_KIND_INVALIDE/d"
mut_ta "le visage gitlab commenté (un /* */ ne blanchit pas la vue code)" "s#pipelineTriggers(\[gitlab(#pipelineTriggers([/* gitlab( */ cron(#"

echo
echo "== 3quater. LES IDENTITÉS VIENNENT DE LA FORGE — et par un SCRIPT, pas dans le bloc \`sh\` =="
# DEUX défauts fermés ici, tous deux trouvés par relecture adverse le
# 2026-09-12, AVANT le premier build.
#
# (a) LA GARDE ÉTAIT NOURRIE DU PAYLOAD (`--merged-by "${PR_MERGED_BY:-}"`),
# capté par le GenericTrigger depuis `$.pull_request.merged_by.login` et
# `$.pull_request.user.login`. Le GitLab Plugin n'expose AUCUN de ces deux
# champs : sous le visage gitlab la garde ne pouvait que refuser
# (MERGER_UNKNOWN), l'onboarding ne démarrait jamais. Le palliatif « évident »
# (`gitlabMergedByUser`) est FAUX : c'est l'ACTEUR de l'événement, il ne dit
# RIEN du demandeur. La réponse est la doctrine du dépôt — le payload est une
# AFFIRMATION, on RELIT la forge (`forge pr_get` parle les deux visages).
#
# (b) LA RELECTURE A D'ABORD ÉTÉ ÉCRITE DANS LE BLOC `sh` DU JENKINSFILE, et
# elle ne pouvait pas s'exécuter : un step `sh` tourne en DASH sur nos agents,
# et scripts/lib/forge-api.sh est du BASH. Mesuré : `dash -n
# scripts/lib/forge-api.sh` → « 111: Syntax error: redirection unexpected ».
# Le step mourait sur deux messages de dash qui ne nomment aucun refus, APRÈS
# avoir réveillé un humain et encaissé son mot de passe d'annuaire — sur les
# DEUX visages, Gitea comprise, qui marchait avant ce lot. La porte générale
# est dans ci/lint-jenkinsfiles.sh (portée dérivée : toute lib sourcée dans un
# bloc `sh` doit passer `dash -n`) ; ici on mesure la forme VOULUE du job.
#
# (c) ET LE LIEN PAYLOAD↔OBJET. Relire `pr_get $PR_NUMBER` pour n'en prendre
# que les deux identités laisse le quatre-yeux contournable : PR_NUMBER est un
# fait du PAYLOAD, l'objet appliqué vient de PR_BRANCH/MERGE_SHA. Qui poste SON
# merge (branche + sha) avec le NUMÉRO d'une PR d'autrui fait valider les
# quatre yeux par une PR étrangère, en vert. D'où les trois confrontations
# (merged, merge_commit_sha, head.ref → PAYLOAD_PERIME), comme le fait déjà
# scripts/provision-apply-reconcile.sh.
IDS="$REPO/scripts/team-apply-identity.sh"
MISSI=""
jf "sh 'set +x; bash scripts/team-apply-identity.sh'" || MISSI=" pas-d-appel-bash-du-script"
grep -qE '^[[:space:]]*(\.|source)[[:space:]]+(scripts|ci)/lib/forge' "$JF" && MISSI="$MISSI lib-bash-sourcee-dans-un-bloc-sh"
# Un seul `script {}` dans le CORPS (le post{} a le sien : cf. §15).
_LP=$(grep -n '^  post {' "$JF_C" | head -1 | cut -d: -f1); _SB=$(awk "NR<${_LP:-999999}" "$JF_C" | grep -c 'script {')
[ "$_SB" -eq 1 ] || MISSI="$MISSI script{}x$_SB"
[ -z "$MISSI" ] \
  && ok "3quater.1 le Jenkinsfile APPELLE \`bash scripts/team-apply-identity.sh\` (un seul step \`sh\`, quotes simples) et ne SOURCE aucune lib de forge dans un bloc \`sh\` — dash ne saurait pas la lire" \
  || ko "3quater.1 relecture mal portée par le pipeline —$MISSI"
{ [ -f "$IDS" ] && head -1 "$IDS" | grep -qE '^#!.*bash' && bash -n "$IDS" 2>/dev/null; } \
  && ok "3quater.2 scripts/team-apply-identity.sh existe, son shebang est bash (son propre process, son propre shell) et il parse" \
  || ko "3quater.2 scripts/team-apply-identity.sh absent, sans shebang bash, ou ne parse pas"
# LA RELECTURE, puis LES CONFRONTATIONS, puis LA GARDE — dans cet ordre.
ids_invariants(){ # <fichier> → imprime les manques, rien si tout est là
  # Sur le CODE SEUL : l'en-tête du script NOMME PAYLOAD_PERIME et la garde
  # pour expliquer pourquoi ils existent, et mesurer l'ORDRE sur le fichier
  # brut classait donc le commentaire avant le code (mesuré : relecture=70,
  # confrontation=26 — les deux dans l'en-tête). Un vert vacant à l'envers.
  local f bad="" a b c
  f="$TMP/ids-$$.code"; sed -E 's@^[[:space:]]*#.*$@@' "$1" > "$f"
  grep -qF 'forge_kv PRG pr_get "$PR_NUMBER"' "$f" || bad="$bad pas-de-forge_kv-pr_get"
  grep -qF 'assert-merge-identity.sh' "$f" || bad="$bad pas-de-garde"
  grep -qF -- '--merged-by "${PRG_MERGED_BY:-}" --requester "${PRG_LOGIN:-}"' "$f" || bad="$bad garde-pas-nourrie-des-valeurs-RELUES"
  grep -qF 'FORGE_IDENTITES_ILLISIBLES' "$f" || bad="$bad pas-de-refus-nomme-si-la-forge-se-tait"
  grep -qF 'PAYLOAD_PERIME' "$f" || bad="$bad pas-de-refus-nomme-PAYLOAD_PERIME"
  grep -qF '[ "${PRG_MERGED:-}" = 1 ]' "$f" || bad="$bad pas-de-confrontation-merged"
  grep -qF '[ "${PRG_MERGE_SHA:-}" = "$MERGE_SHA" ]' "$f" || bad="$bad pas-de-confrontation-merge_commit_sha"
  grep -qF '[ "${PRG_HEAD_REF:-}" = "$PR_BRANCH" ]' "$f" || bad="$bad pas-de-confrontation-head.ref"
  a=$(grep -nF 'forge_kv PRG pr_get' "$f" | head -1 | cut -d: -f1)
  b=$(grep -nF 'PAYLOAD_PERIME' "$f" | head -1 | cut -d: -f1)
  c=$(grep -nF 'assert-merge-identity.sh' "$f" | head -1 | cut -d: -f1)
  { [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; } \
    || bad="$bad ordre(relecture=${a:-?} confrontation=${b:-?} garde=${c:-?})"
  printf '%s' "$bad"
}
MISSI="$(ids_invariants "$IDS")"
[ -z "$MISSI" ] \
  && ok "3quater.3 le script RELIT (forge_kv PRG pr_get), CONFRONTE les trois faits de la forge au webhook (merged, merge_commit_sha, head.ref → PAYLOAD_PERIME) puis nourrit la garde des valeurs RELUES — dans cet ordre" \
  || ko "3quater.3 chaîne d'identité incomplète —$MISSI"
# LA FORME AVANT LE RÉSEAU : un MERGE_SHA hors 40 hex ou un PR_NUMBER non
# entier se refusent sans appeler la forge (motif provision-apply-reconcile §1).
L_FORME=$(grep -nF 'MERGE_SHA_INVALIDE' "$IDS" | head -1 | cut -d: -f1)
L_RESEAU=$(grep -nF 'forge_api_init' "$IDS" | head -1 | cut -d: -f1)
{ grep -qF 'PR_NUMBER_INVALIDE' "$IDS" && [ -n "$L_FORME" ] && [ -n "$L_RESEAU" ] && [ "$L_FORME" -lt "$L_RESEAU" ]; } \
  && ok "3quater.4 la FORME est jugée AVANT tout appel réseau (PR_NUMBER_INVALIDE, MERGE_SHA_INVALIDE en ^[0-9a-f]{40}\$)" \
  || ko "3quater.4 forme non jugée, ou jugée après l'appel réseau (forme=${L_FORME:-?} réseau=${L_RESEAU:-?})"
# Les clés du payload RESTENT captées : journal et diagnostic, jamais la garde.
{ grep -qF "[key: 'PR_MERGED_BY'," "$JF_C" && grep -qF "[key: 'PR_REQUESTER'," "$JF_C"; } \
  && ok "3quater.5 les clés d'identité du payload restent captées (journal, diagnostic) — comme provision-apply, qui les garde « pour le journal, JAMAIS lues par la garde »" \
  || ko "3quater.5 les clés d'identité du payload ont disparu du trigger"
# Le Jenkinsfile ne doit PLUS nourrir la garde lui-même (ni la rappeler).
grep -qF 'assert-merge-identity.sh' "$JF_C" \
  && ko "3quater.6 le Jenkinsfile appelle encore la garde directement — deux chemins pour une seule règle" \
  || ok "3quater.6 le Jenkinsfile n'appelle plus la garde : un seul chemin, celui du script, donc un seul endroit où la règle peut changer"
# MUTATIONS : chacune doit rougir. Sur le SCRIPT (c'est lui qui porte la règle)…
mut_ids(){ # <libellé> <sed>
  sed "$2" "$IDS" > "$TMP/mi.sh"
  if cmp -s "$TMP/mi.sh" "$IDS"; then ko "$1 : mutation NON appliquée"; return; fi
  [ -n "$(ids_invariants "$TMP/mi.sh")" ] && ok "$1 ⇒ rouge" || ko "$1 : mutation INVISIBLE à la porte"
}
mut_ids "la garde renourrie du payload (PR_MERGED_BY)" 's/--merged-by "${PRG_MERGED_BY:-}" --requester "${PRG_LOGIN:-}"/--merged-by "${PR_MERGED_BY:-}" --requester "${PR_REQUESTER:-}"/'
mut_ids "la relecture retirée" '/forge_kv PRG pr_get/d'
mut_ids "le refus de relecture muette retiré" '/FORGE_IDENTITES_ILLISIBLES/d'
mut_ids "la confrontation merged retirée" '/PRG_MERGED:-} " = 1/d;/{PRG_MERGED:-}" = 1/d'
mut_ids "la confrontation merge_commit_sha retirée" '/{PRG_MERGE_SHA:-}" = "\$MERGE_SHA"/d'
mut_ids "la confrontation head.ref retirée" '/{PRG_HEAD_REF:-}" = "\$PR_BRANCH"/d'
mut_ids "le refus PAYLOAD_PERIME retiré" '/PAYLOAD_PERIME/d'
# …et sur le JENKINSFILE : le défaut exact du 2026-09-12 (la lib bash sourcée
# dans le bloc `sh`) doit rougir, c'est la seule mutation qui prouve (b).
sed "s@sh 'set +x; bash scripts/team-apply-identity.sh'@sh '''\n              . scripts/lib/forge-api.sh\n              forge_kv PRG pr_get \"\$PR_NUMBER\"\n            '''@" "$JF" > "$TMP/mj.jf"
if cmp -s "$TMP/mj.jf" "$JF"; then ko "la relecture remise INLINE dans le bloc \`sh\` : mutation NON appliquée"; else
  MISSI=""
  printf '%s\n' "$(tr -s ' ' < "$TMP/mj.jf")" | grep -qF "sh 'set +x; bash scripts/team-apply-identity.sh'" || MISSI=" pas-d-appel-bash-du-script"
  grep -qE '^[[:space:]]*(\.|source)[[:space:]]+(scripts|ci)/lib/forge' "$TMP/mj.jf" && MISSI="$MISSI lib-bash-sourcee-dans-un-bloc-sh"
  [ -n "$MISSI" ] && ok "la relecture remise INLINE dans le bloc \`sh\` (dash) ⇒ rouge" || ko "la relecture remise INLINE : mutation INVISIBLE à la porte"
fi

echo
echo
echo "== 3quinquies. LE SCRIPT S'EXÉCUTE (et pas seulement : il contient les bons mots) =="
# LA LENTILLE QUI MANQUAIT (relecture adverse du 2026-09-12). Tout ce qui
# précède est une porte de LITTÉRAUX : elle vérifie que les chaînes sont là,
# jamais que le bloc TOURNE. C'est précisément par là qu'est passé le défaut :
# `. scripts/lib/forge-api.sh` écrit dans un `sh` de Jenkins (donc dash) PARSE
# côté Groovy, contient tous les bons mots, et meurt à la première ligne.
# Ces épreuves JOUENT le script — sans réseau : les quatre premières refusent
# sur la FORME, la cinquième sur l'absence de forge configurée, et aucune
# n'atteint un appel HTTP (forge_api_init refuse avant).
ids_joue(){ # <libellé> <attendu> <var=val…>
  local lib="$1" att="$2"; shift 2
  local out rc
  out=$(env -u GIT_HOST -u GIT_REPO -u FORGE_KIND -u FORGE_SECRET -u GITEA_TOKEN -u FORGE_API_BASE \
        "$@" bash "$IDS" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "$att"; then
    ok "3quinquies $lib ⇒ rc $rc et « $att »"
  else
    ko "3quinquies $lib ⇒ rc $rc, attendu « $att » — obtenu : $(printf '%s' "$out" | head -1 | cut -c1-90)"
  fi
}
SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
ids_joue "PR_NUMBER absent"        "PR_NUMBER_INVALIDE"          PR_BRANCH=onboard/x-dev MERGE_SHA="$SHA40"
ids_joue "PR_NUMBER non entier"    "PR_NUMBER_INVALIDE"          PR_NUMBER=4x PR_BRANCH=onboard/x-dev MERGE_SHA="$SHA40"
ids_joue "MERGE_SHA hors 40 hex"   "MERGE_SHA_INVALIDE"          PR_NUMBER=41 PR_BRANCH=onboard/x-dev MERGE_SHA=deadbeef
ids_joue "PR_BRANCH vide"          "BRANCHE_REQUISE"             PR_NUMBER=41 MERGE_SHA="$SHA40"
ids_joue "forge non configurée"    "FORGE_IDENTITES_ILLISIBLES"  PR_NUMBER=41 PR_BRANCH=onboard/x-dev MERGE_SHA="$SHA40"
# LE GESTE EXACT DU JENKINSFILE, joué par DASH — c'est CELA qui mourait.
if command -v dash >/dev/null 2>&1; then
  D_OUT=$(env -u GIT_HOST -u GIT_REPO -u FORGE_KIND -u FORGE_SECRET -u GITEA_TOKEN \
          PR_NUMBER=41 PR_BRANCH=onboard/x-dev MERGE_SHA="$SHA40" \
          dash -c 'set +x; bash scripts/team-apply-identity.sh' 2>&1)
  { printf '%s' "$D_OUT" | grep -qF 'FORGE_IDENTITES_ILLISIBLES' \
    && ! printf '%s' "$D_OUT" | grep -qF 'Syntax error'; } \
    && ok "3quinquies le geste exact du Jenkinsfile (\`dash -c 'set +x; bash scripts/team-apply-identity.sh'\`) rend le refus NOMMÉ du dépôt — pas un message de dash" \
    || ko "3quinquies sous dash, le geste du Jenkinsfile ne rend pas le refus nommé : $(printf '%s' "$D_OUT" | head -2 | tr '\n' ' ' | cut -c1-120)"
  # CONTRE-ÉPREUVE : l'ANCIENNE forme (la lib bash sourcée dans le bloc) meurt
  # sans nommer aucun refus. Si un jour elle passait, c'est que la lib serait
  # devenue POSIX — et la porte de ci/lint-jenkinsfiles.sh le dirait aussi.
  A_OUT=$(dash -c '. scripts/lib/forge-api.sh
forge_api_init || { echo "REFUS: FORGE_IDENTITES_ILLISIBLES"; exit 1; }
echo "ARRIVE A LA GARDE"' 2>&1)
  { printf '%s' "$A_OUT" | grep -qF 'Syntax error' \
    && ! printf '%s' "$A_OUT" | grep -qF 'ARRIVE A LA GARDE'; } \
    && ok "3quinquies contre-épreuve : la lib SOURCÉE sous dash meurt en « Syntax error » sans jamais nommer de refus ni atteindre la garde — le défaut du 2026-09-12, reproduit à la demande" \
    || ko "3quinquies contre-épreuve MUETTE : dash source désormais la lib ($(printf '%s' "$A_OUT" | head -1 | cut -c1-80)) — si la lib est devenue POSIX, retirer cette épreuve EN LE DISANT"
else
  ko "3quinquies dash absent : le shell des blocs \`sh\` n'est pas mesurable ici (geste : brew install dash)"
  ko "3quinquies dash absent : contre-épreuve impossible"
fi

echo
echo "== 3sexies. LE CHEMIN NOMINAL, JOUÉ : une fausse forge répond, la garde tranche =="
# Les épreuves précédentes ne jouent que des REFUS de forme : elles ne prouvent
# pas que le chemin qui doit ABOUTIR aboutit (« une suite tout-REFUS ne teste
# jamais le nominal » — leçon d'app-request v3). On monte donc une fausse forge
# LOCALE (127.0.0.1, port choisi par le noyau, aucun secret réel, aucun réseau
# sortant) et on joue le script ENTIER : relecture → confrontations → garde.
# C'est aussi la seule épreuve hors-ligne qui prouve la fermeture du défaut
# d'intégrité : la charge utile qui porte SON merge et le NUMÉRO d'une PR
# d'autrui est refusée PAYLOAD_PERIME au lieu de faire valider les quatre yeux
# par une PR étrangère.
cat > "$TMP/fauxforge.py" <<'PYFF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
PR = {
  "41": {"number": 41, "state": "closed", "merged": True, "merge_commit_sha": "b" * 40,
         "head": {"ref": "onboard/equipe-dev", "sha": "c" * 40, "repo": {"full_name": "ci/stoa-labs"}},
         "base": {"ref": "main"}, "merged_by": {"login": "oscar"}, "user": {"login": "alice"},
         "html_url": "http://faux/pulls/41"},
  "42": {"number": 42, "state": "closed", "merged": True, "merge_commit_sha": "d" * 40,
         "head": {"ref": "onboard/autre-dev", "sha": "e" * 40, "repo": {"full_name": "ci/stoa-labs"}},
         "base": {"ref": "main"}, "merged_by": {"login": "alice"}, "user": {"login": "bob"},
         "html_url": "http://faux/pulls/42"},
  "44": {"number": 44, "state": "closed", "merged": True, "merge_commit_sha": "a" * 40,
         "head": {"ref": "onboard/equipe-dev", "sha": "9" * 40, "repo": {"full_name": "ci/stoa-labs"}},
         "base": {"ref": "main"}, "merged_by": {"login": "alice"}, "user": {"login": "bob"},
         "html_url": "http://faux/pulls/44"},
  "43": {"number": 43, "state": "open", "merged": False, "merge_commit_sha": None,
         "head": {"ref": "onboard/pas-fusionnee-dev", "sha": "f" * 40, "repo": {"full_name": "ci/stoa-labs"}},
         "base": {"ref": "main"}, "merged_by": None, "user": {"login": "alice"},
         "html_url": "http://faux/pulls/43"},
}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        n = self.path.rstrip("/").rsplit("/", 1)[-1]
        if self.path.startswith("/api/v1/repos/ci/stoa-labs/pulls/") and n in PR:
            b = json.dumps(PR[n]).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        else:
            self.send_response(404); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PYFF
python3 "$TMP/fauxforge.py" > "$TMP/ff.port" 2>"$TMP/ff.err" &
FF_PID=$!
FF_PORT=""
i=0; while [ "$i" -lt 50 ]; do
  FF_PORT=$(head -1 "$TMP/ff.port" 2>/dev/null || true)
  case "$FF_PORT" in ''|*[!0-9]*) FF_PORT="" ;; *) break ;; esac
  i=$((i+1)); python3 -c 'import time; time.sleep(0.1)'
done
if [ -z "$FF_PORT" ]; then
  kill "$FF_PID" 2>/dev/null || true
  ko "3sexies la fausse forge n'a pas démarré ($(head -1 "$TMP/ff.err" 2>/dev/null | cut -c1-80)) — le chemin NOMINAL reste non joué"
  ko "3sexies chemin nominal non joué (fausse forge absente)"
  ko "3sexies charge utile forgée non jouée (fausse forge absente)"
  ko "3sexies PR non fusionnée non jouée (fausse forge absente)"
else
  ff_joue(){ # <libellé> <attendu> <rc attendu: 0|ko> <var=val…>
    local lib="$1" att="$2" wrc="$3"; shift 3
    local out rc
    out=$(env -u FORGE_API_BASE GIT_HOST="http://127.0.0.1:$FF_PORT" GIT_REPO=ci/stoa-labs \
          FORGE_KIND=gitea FORGE_SECRET=faux-jeton-de-suite "$@" bash "$IDS" 2>&1); rc=$?
    local okrc=1
    if [ "$wrc" = 0 ]; then [ "$rc" -eq 0 ] && okrc=0; else [ "$rc" -ne 0 ] && okrc=0; fi
    if [ "$okrc" -eq 0 ] && printf '%s' "$out" | grep -qF "$att"; then
      ok "3sexies $lib ⇒ rc $rc et « $att »"
    else
      ko "3sexies $lib ⇒ rc $rc, attendu « $att » — obtenu : $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-110)"
    fi
  }
  SHA_B=$(python3 -c "print('b'*40)")
  ff_joue "NOMINAL : oscar a fusionné la PR #41 d'alice, oscar répond à la pause" \
          "MERGE_IDENTITY_OK" 0 PR_NUMBER=41 PR_BRANCH=onboard/equipe-dev MERGE_SHA="$SHA_B" V_USER=oscar
  ff_joue "les identités relues sont DITES dans le journal" \
          "identites RELUES sur la forge : PR #41 (onboard/equipe-dev) validee par 'oscar', demandee par 'alice'" 0 \
          PR_NUMBER=41 PR_BRANCH=onboard/equipe-dev MERGE_SHA="$SHA_B" V_USER=oscar
  ff_joue "FORGÉE : le merge de la #41, le NUMÉRO de la #42 (quatre yeux d'autrui)" \
          "PAYLOAD_PERIME" ko PR_NUMBER=42 PR_BRANCH=onboard/equipe-dev MERGE_SHA="$SHA_B" V_USER=oscar
  # LA BRANCHE MÊME, UN AUTRE MERGE : la #44 porte `onboard/equipe-dev` comme la
  # #41 (branche réutilisée / re-fusionnée) mais un autre merge. Seule la
  # confrontation du `merge_commit_sha` peut refuser celui-là — `head.ref`
  # concorde, `merged` vaut 1. C'est le scénario qui ISOLE cette ligne, et la
  # mutation ci-dessous s'appuie sur lui.
  ff_joue "FORGÉE, MÊME branche : le merge de la #41 avec le numéro de la #44" \
          "PAYLOAD_PERIME" ko PR_NUMBER=44 PR_BRANCH=onboard/equipe-dev MERGE_SHA="$SHA_B" V_USER=alice
  ff_joue "la forge dit la PR NON fusionnée (#43)" \
          "PAYLOAD_PERIME" ko PR_NUMBER=43 PR_BRANCH=onboard/pas-fusionnee-dev MERGE_SHA="$SHA_B" V_USER=oscar
  # MUTATION DE COMPORTEMENT, la plus forte : on RETIRE la confrontation du
  # merge_commit_sha et on rejoue la charge utile forgée. Elle doit alors
  # PASSER (MERGE_IDENTITY_OK sur une PR étrangère) — c'est la preuve que le
  # trou existait et que CETTE ligne le ferme. Le `cd` du script est neutralisé
  # dans la copie : elle vit hors de l'arbre, mais lit scripts/ depuis la racine.
  sed -e '/{PRG_MERGE_SHA:-}" = "\$MERGE_SHA"/d' -e '/^cd "\$(dirname "\$0")\/\.\." || exit 1$/d' \
      "$IDS" > "$TMP/mids.sh"
  if cmp -s "$TMP/mids.sh" "$IDS"; then
    ko "3sexies mutation de comportement NON appliquée (ni la confrontation ni le cd n'ont bougé)"
  else
    MOUT=$(env -u FORGE_API_BASE GIT_HOST="http://127.0.0.1:$FF_PORT" GIT_REPO=ci/stoa-labs \
           FORGE_KIND=gitea FORGE_SECRET=faux-jeton-de-suite \
           PR_NUMBER=44 PR_BRANCH=onboard/equipe-dev MERGE_SHA="$SHA_B" V_USER=alice \
           bash "$TMP/mids.sh" 2>&1) || true
    printf '%s' "$MOUT" | grep -qF 'MERGE_IDENTITY_OK' \
      && ok "3sexies mutation « confrontation du merge_commit_sha retirée » ⇒ la charge utile FORGÉE passe (MERGE_IDENTITY_OK au nom de la PR #44 alors qu'on applique le merge de la #41, MÊME branche) : le trou est réel, et c'est cette ligne SEULE qui le ferme" \
      || ko "3sexies mutation INVISIBLE : sans la confrontation du sha, la charge forgée (même branche) est refusée quand même ($(printf '%s' "$MOUT" | tr '\n' ' ' | cut -c1-100)) — que mesure la ligne, alors ?"
  fi
  kill "$FF_PID" 2>/dev/null || true
fi

echo "== 4. la branche est gardée à onboard/*, AVANT la pause (personne n'est réveillé pour rien) =="
jf "expression { (env.PR_BRANCH ?: '').startsWith('onboard/') }" \
  && ok "garde de branche onboard/* présente (condition \`when\`)" \
  || ko "garde de branche absente — appliquerait sur n'importe quelle PR fermée du dépôt plateforme"
jf "beforeInput true" \
  && ok "\`beforeInput true\` : la condition est évaluée AVANT la demande en attente — une PR hors onboard/* ne réveille personne" \
  || ko "\`beforeInput true\` absent — une PR hors onboard/* ouvrirait quand même une demande en attente (la directive \`input\` passe AVANT \`when\` par défaut)"

echo
echo "== 5. la garde d'identité est réellement appelée, AVANT team-apply.sh =="
# ⚠ LA GARDE A DÉMÉNAGÉ le 2026-09-12, et ce n'est pas cosmétique : elle a
# d'abord été écrite INLINE dans un bloc `sh` du Jenkinsfile, où elle ne
# pouvait pas s'exécuter — dash ne sait pas sourcer scripts/lib/forge-api.sh
# (cf. §3quater (b), et la porte de ci/lint-jenkinsfiles.sh). Elle vit
# maintenant dans scripts/team-apply-identity.sh : le CÂBLAGE (quelle valeur
# alimente quel drapeau) se mesure donc DANS LE SCRIPT, et l'ORDRE (identité
# avant apply) reste mesuré sur le Jenkinsfile.
# Continuations RECOLLÉES : l'appel de la garde tient sur deux lignes, et une
# paire option/valeur coupée par un `\` en fin de ligne serait invisible.
IDS_J="$TMP/ids.joined"
sed -E 's@^[[:space:]]*#.*$@@' "$IDS" | sed -e :a -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' > "$IDS_J"
GUARD_LINE=$(grep -n 'sh scripts/lib/assert-merge-identity\.sh' "$IDS_J" | head -1)
L_GUARD=${GUARD_LINE%%:*}
[ -n "$GUARD_LINE" ] \
  && ok "assert-merge-identity.sh réellement invoquée par team-apply-identity.sh (ligne ${L_GUARD} du script, appel réel — pas une mention en commentaire)" \
  || ko "aucun appel RÉEL à scripts/lib/assert-merge-identity.sh — la garde d'identité a disparu"
# Les PAIRES option/variable, pas seulement les noms d'options : c'est le
# CÂBLAGE qui doit survivre au déménagement. Les trois valeurs sont RELUES sur
# la forge (PRG_*) ou saisies dans la pause (V_USER) — jamais le payload.
printf '%s' "$GUARD_LINE" | grep -qF -- '--merged-by "${PRG_MERGED_BY:-}"' \
  && ok "--merged-by alimenté par PRG_MERGED_BY (la forge RELUE, pas le payload)" || ko "--merged-by non alimenté par la forge relue"
printf '%s' "$GUARD_LINE" | grep -qF -- '--requester "${PRG_LOGIN:-}"' \
  && ok "--requester alimenté par PRG_LOGIN (la forge RELUE — sans lui, le quatre-yeux serait invérifiable)" || ko "--requester non alimenté par la forge relue"
printf '%s' "$GUARD_LINE" | grep -qF -- '--vault-user "${V_USER:-}"' \
  && ok "--vault-user alimenté par V_USER (la saisie de la pause, traversant le step \`sh\` par l'environnement)" || ko "--vault-user non alimenté par V_USER"
L_ID=$(grep -n 'bash scripts/team-apply-identity\.sh' "$JF" | head -1 | cut -d: -f1)
L_APPLY=$(grep -n 'bash scripts/team-apply\.sh' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_ID" ] && [ -n "$L_APPLY" ] && [ "$L_ID" -lt "$L_APPLY" ]; then
  ok "étape d'identité ligne $L_ID, apply ligne $L_APPLY — rien n'est appliqué avant que les identités relues n'aient été confrontées"
else
  ko "identité APRÈS l'apply (ou introuvable) : identité=${L_ID:-?} apply=${L_APPLY:-?}"
fi

echo
echo "== 6. team-apply.sh est bien invoqué, et le pipeline reste MINCE =="
grep -q 'bash scripts/team-apply\.sh' "$JF" \
  && ok "scripts/team-apply.sh invoqué" || ko "team-apply.sh non invoqué — job mort"
# Le pipeline ROUTE, il ne réimplémente pas. Aucun appel direct à l'API de la
# gateway ni à Ansible ne doit apparaître ici.
if grep -qE '^\s*(curl|ansible-playbook) ' "$JF"; then
  ko "le Jenkinsfile appelle directement curl/ansible-playbook — la substance doit rester dans scripts/ et ansible/roles/"
else
  ok "aucun curl/ansible-playbook direct : le pipeline route, le moteur reste dans scripts/ et ansible/roles/"
fi

echo
echo "== 7. pas d'injection : les valeurs sont lues par le SHELL, jamais interpolées par Groovy =="
# merged_by vient d'un webhook, V_USER/V_PASS d'une saisie humaine : trois
# tiers. Interpolés par Groovy DANS la chaîne sh, ils exécuteraient du shell
# arbitraire sur l'agent. En déclaratif les valeurs du webhook sont DÉJÀ dans
# l'environnement du step (contribuées par GenericTrigger) et celles de la pause
# y sont posées par la directive `input` — d'où la disparition des withEnv()
# explicites. Ce qui doit être prouvé n'a pas changé.
grep -q "sh '''" "$JF" \
  && ok "le bloc login+apply est en triple quotes SIMPLES (Groovy n'y interpole rien)" \
  || ko "aucun bloc \`sh '''\` — vérifier comment le bloc d'apply est écrit"
if grep -q 'sh """' "$JF"; then
  ko "un bloc \`sh \"\"\"\` (triple quotes DOUBLES) existe — Groovy y interpolerait le mot de passe et les champs du webhook"
else
  ok "aucun bloc \`sh \"\"\"\` : impossible d'interpoler un secret dans une chaîne shell"
fi
# La garde vit dans un SCRIPT (§3quater) : plus aucune chaîne shell d'identité
# ne traverse une interpolation Groovy. Ce qui reste à prouver côté pipeline,
# c'est que le STEP qui l'appelle est à quotes SIMPLES — un `sh "…"` y
# interpolerait encore `${V_USER}` et compagnie côté Groovy.
L_OUV=$L_ID   # le step d'identité EST la ligne : `sh 'set +x; bash scripts/…'`
OUV=$(sed -n "${L_OUV:-1}p" "$JF")
case "$OUV" in
  *"sh '"*) ok "le step qui appelle la garde est à quotes SIMPLES (ligne ${L_OUV}) : les \${…} y sont du SHELL, pas du Groovy" ;;
  *)        ko "le step qui appelle la garde n'est pas à quotes simples (ligne ${L_OUV}) — Groovy interpolerait : $(printf '%s' "$OUV" | sed 's/^[[:space:]]*//' | cut -c1-60)" ;;
esac
grep -q "password(name: 'V_PASS'" "$JF" \
  && ok "le mot de passe de la pause est un paramètre \`password\` (masqué), pas un \`string\`" \
  || ko "V_PASS n'est pas déclaré en paramètre \`password\` — il s'afficherait en clair dans l'UI et les logs"
grep -q "string(name: 'V_USER'" "$JF" \
  && ok "le login de la pause est un paramètre \`string\` nommé V_USER" || ko "V_USER non déclaré en paramètre de la pause"
# Le nom V_PASS (et non VAULT_USER_PASSWORD) est CE QUI PERMET le §13 : la
# valeur est recopiée puis `unset` dans le seul sh qui en a besoin.
if grep -q "password(name: 'VAULT_USER_PASSWORD'" "$JF"; then
  ko "la pause expose directement VAULT_USER_PASSWORD — la variable resterait dans l'environnement de TOUTE l'étape, l'unset du §13 deviendrait inopérant"
else
  ok "la pause n'expose pas VAULT_USER_PASSWORD directement (nom intermédiaire V_PASS, cf. §13)"
fi

echo
echo "== 8. le mot de passe ne transite jamais par argv (login sourcé, pas exec direct) =="
grep -q '\. ci/lib/vault-login\.sh' "$JF" \
  && ok "ci/lib/vault-login.sh sourcé (motif établi, jamais un appel direct qui mettrait le mot de passe en argv)" \
  || ko "vault-login.sh non sourcé — vérifier comment le login est fait"
grep -q 'trap vault_trap_revoke EXIT' "$JF" \
  && ok "révocation du token armée (trap EXIT) avant tout appel réseau" \
  || ko "aucun trap de révocation — le token nominatif pourrait survivre au build"

echo
echo "== 9. login et l'appel à team-apply.sh se suivent TEXTUELLEMENT (login précède l'appel) =="
if awk '/\. ci\/lib\/vault-login\.sh/{f=1} f&&/bash scripts\/team-apply\.sh/{print "same"; exit}' "$JF" | grep -q same; then
  ok "vault-login.sh (source réelle) précède textuellement l'appel réel à team-apply.sh"
else
  ko "vault-login.sh et l'appel réel à team-apply.sh ne se suivent pas dans cet ordre — le trap de révocation pourrait tuer le token avant l'apply"
fi
# UN SEUL step `sh` pour le login ET l'apply : deux steps rouvriraient un
# process par step, et le trap du premier révoquerait le token AVANT que le
# second ne le consomme. Preuve : entre la source de la lib et l'appel au
# script, aucune fermeture de bloc `sh` (`'''`) ne doit s'intercaler.
BETWEEN=$(awk "NR>$(grep -n '\. ci/lib/vault-login\.sh' "$JF" | head -1 | cut -d: -f1) && NR<$(grep -n 'bash scripts/team-apply\.sh' "$JF" | head -1 | cut -d: -f1)" "$JF" | grep -c "'''")
[ "$BETWEEN" -eq 0 ] \
  && ok "aucune fermeture de bloc sh entre le login et l'apply — ils sont dans LE MÊME step \`sh\`" \
  || ko "un bloc \`sh\` se ferme entre le login et l'apply (${BETWEEN} occurrence(s) de ''') — le trap révoquerait le token avant sa consommation"

echo
echo "== 10. la garde et team-apply.sh appelés existent et sont parsables =="
[ -f "$REPO/scripts/lib/assert-merge-identity.sh" ] \
  && ok "scripts/lib/assert-merge-identity.sh présent" || ko "script absent — appel mort"
sh -n "$REPO/scripts/lib/assert-merge-identity.sh" 2>/dev/null \
  && ok "assert-merge-identity.sh : syntaxe shell valide" || ko "assert-merge-identity.sh non parsable"
[ -f "$REPO/scripts/team-apply.sh" ] \
  && ok "scripts/team-apply.sh présent" || ko "team-apply.sh absent — appel mort"
bash -n "$REPO/scripts/team-apply.sh" 2>/dev/null \
  && ok "team-apply.sh : syntaxe shell valide" || ko "team-apply.sh non parsable"
[ -f "$REPO/ci/lib/vault-login.sh" ] \
  && ok "ci/lib/vault-login.sh présent" || ko "vault-login.sh absent — appel mort"

echo
echo "== 11. le job est bien posé par setup-team-onboard-jobs.sh =="
grep -q 'team-apply' "$REPO/scripts/setup-team-onboard-jobs.sh" \
  && ok "team-apply listé dans JOBS de setup-team-onboard-jobs.sh" || ko "team-apply absent de JOBS"

echo
echo "== 12. les \`export VAR=\` du bloc sh sont devenus des entrées de \`environment\` — présence ET valeur =="
# FILET STATIQUE (revue finale de branche) contre la régression qui a coûté
# deux rounds de la Task 8 : VAULT_USER_AUTH_MOUNT absent du job faisait
# retomber ci/lib/vault-login.sh sur son défaut ldap (la convention CLIENT)
# alors que ce lab authentifie ses opérateurs en userpass — login refusé,
# jamais détecté par une revue statique puisque ce filet n'existait pas.
# On vérifie la VALEUR LITTÉRALE, pas seulement le nom (un grep nu matcherait
# aussi les commentaires qui citent la variable — ils la citent 4 fois).
grep -qE '^  environment \{' "$JF" \
  && ok "bloc \`environment\` de niveau pipeline présent" || ko "aucun bloc \`environment\` de niveau pipeline"
jf 'VAULT_USER_AUTH_MOUNT = "${env.VAULT_USER_AUTH_MOUNT ?: '"'"'userpass'"'"'}"' \
  && ok "valeur littérale de VAULT_USER_AUTH_MOUNT = userpass (défaut nominatif du lab, surchargeable en ldap chez le client)" \
  || ko "VAULT_USER_AUTH_MOUNT : valeur par défaut inattendue ou absente — régression connue (Task 8, deux rounds pour la trouver en réel)"
jf 'APIM_API_BASE = "${env.APIM_API_BASE ?: '"'"'http://webmethods-mock:8080/rest/apigateway'"'"'}"' \
  && ok "valeur littérale de APIM_API_BASE = mock in-cluster (jamais 5555)" \
  || ko "APIM_API_BASE : valeur par défaut inattendue ou absente — team-apply.sh refuse de démarrer sans lui (\${APIM_API_BASE:?…}, team-apply.sh:32)"
# JENKINS_UI : fix mesuré (Task 7) — "localhost" depuis le conteneur du job ne
# désigne PAS Jenkins ; sans lui, la re-pose événementielle des listes échoue
# systématiquement en job réel (curl "000"), jamais vu en test depuis un poste.
jf 'JENKINS_UI = "${env.JENKINS_UI ?: '"'"'http://jenkins:8080'"'"'}"' \
  && ok "valeur littérale de JENKINS_UI = http://jenkins:8080 (sinon : re-pose injoignable en job réel)" \
  || ko "JENKINS_UI : valeur par défaut inattendue ou absente"
jf 'VAULT_ADDR = "${env.VAULT_ADDR ?: '"'"'http://vault:8200'"'"'}"' \
  && ok "valeur littérale de VAULT_ADDR = http://vault:8200 (alias in-cluster)" \
  || ko "VAULT_ADDR : valeur par défaut inattendue ou absente"
jf 'GIT_WEB_HOST = "${env.GIT_WEB_HOST ?: '"'"'http://localhost:13000'"'"'}"' \
  && ok "valeur littérale de GIT_WEB_HOST = http://localhost:13000 (lien CLIQUABLE du commentaire de PR, vu d'un poste — pas l'alias interne)" \
  || ko "GIT_WEB_HOST : valeur par défaut inattendue ou absente — le lien du commentaire retomberait sur GIT_HOST, non résolu hors des conteneurs"
jf 'GIT_HOST = "${env.GIT_HOST ?: '"'"'http://gitea:3000'"'"'}"' \
  && ok "valeur littérale de GIT_HOST = http://gitea:3000 (alias in-cluster)" \
  || ko "GIT_HOST : valeur par défaut inattendue ou absente"
jf 'GITEA_CREDENTIALS_ID = "${env.GITEA_CREDENTIALS_ID ?: '"'"'gitea-provision-token'"'"'}"' \
  && ok "valeur littérale de GITEA_CREDENTIALS_ID = gitea-provision-token (point de config client, plus en dur dans le pipeline)" \
  || ko "GITEA_CREDENTIALS_ID : valeur par défaut inattendue ou absente"
jf "withCredentials(forgeCreds())" \
  && ok "le credential Gitea est réellement lu via env.GITEA_CREDENTIALS_ID et exposé en GITEA_TOKEN (jamais en argv)" \
  || ko "withCredentials n'utilise pas env.GITEA_CREDENTIALS_ID — la surcharge client serait décorative"
# L'ordre compte : le bloc `environment` doit précéder les `stages` pour que
# les valeurs soient dans l'environnement de TOUS les steps — en particulier
# VAULT_USER_AUTH_MOUNT AVANT que vault-login.sh ne soit sourcé (la lib la lit
# au moment du login, pas après).
L_ENV=$(grep -n '^  environment {' "$JF" | head -1 | cut -d: -f1)
L_STAGES=$(grep -n '^  stages {' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_ENV" ] && [ -n "$L_STAGES" ] && [ "$L_ENV" -lt "$L_STAGES" ]; then
  ok "\`environment\` (ligne $L_ENV) précède \`stages\` (ligne $L_STAGES) — exporté avant que vault-login.sh ne soit sourcé"
else
  ko "ordre environment/stages non confirmé (environment=$L_ENV stages=$L_STAGES)"
fi

echo
echo "== 13. V_PASS ne survit pas dans l'environnement du step sh =="
L_EXPORT_USER=$(grep -n 'export VAULT_USER="\${V_USER:-}"' "$JF" | head -1 | cut -d: -f1)
[ -n "$L_EXPORT_USER" ] \
  && ok "VAULT_USER alimenté depuis V_USER dans le bloc sh (ligne ${L_EXPORT_USER})" \
  || ko "VAULT_USER non alimenté depuis V_USER — le login nominatif n'aurait pas d'identité"
L_EXPORT_PASS=$(grep -n 'export VAULT_USER_PASSWORD="\${V_PASS:-}"' "$JF" | head -1 | cut -d: -f1)
L_UNSET=$(grep -n '^ *unset V_PASS$' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_EXPORT_PASS" ] && [ -n "$L_UNSET" ] && [ "$L_EXPORT_PASS" -lt "$L_UNSET" ]; then
  ok "unset V_PASS après l'export (ligne ${L_EXPORT_PASS} puis ${L_UNSET}) — le mot de passe ne reste pas lisible dans /proc/PID/environ"
else
  ko "unset V_PASS absent ou avant l'export (export=${L_EXPORT_PASS} unset=${L_UNSET}) — le mot de passe resterait lisible dans /proc/PID/environ"
fi
# L'unset doit précéder TOUT appel réseau (le login inclus) : après, le mot de
# passe aurait déjà été visible dans l'environnement d'un process fils.
L_SOURCE=$(grep -n '\. ci/lib/vault-login\.sh' "$JF" | head -1 | cut -d: -f1)
if [ -n "$L_UNSET" ] && [ -n "$L_SOURCE" ] && [ "$L_UNSET" -lt "$L_SOURCE" ]; then
  ok "unset V_PASS (ligne ${L_UNSET}) AVANT la source de vault-login.sh (ligne ${L_SOURCE}) — donc avant tout appel réseau"
else
  ko "unset V_PASS après le login (unset=${L_UNSET} source=${L_SOURCE})"
fi

echo
echo "== 14. la pause ne réserve AUCUN exécuteur =="
# `agent none` au niveau pipeline + directive `input` de stage : la pause est
# évaluée AVANT l'allocation de l'agent de l'étape. Un `agent any` de niveau
# pipeline gâcherait un slot pendant toute l'attente d'une réponse humaine —
# c'est la raison pour laquelle l'input() du job Groovy était déjà HORS du
# node{}.
grep -qE '^  agent none$' "$JF" \
  && ok "\`agent none\` au niveau pipeline — la pause ne réserve aucun exécuteur" \
  || ko "pas d'\`agent none\` au niveau pipeline — un exécuteur serait réservé pendant toute l'attente humaine"
L_INPUT=$(grep -nE '^      input \{' "$JF" | head -1 | cut -d: -f1)
[ -n "$L_INPUT" ] \
  && ok "directive \`input\` de stage présente (ligne ${L_INPUT}) — évaluée avant l'agent de l'étape" \
  || ko "aucune directive \`input\` de stage — la pause nominative a disparu, ou est devenue un step (qui, lui, réserve un exécuteur)"
grep -qE '^      agent any$' "$JF" \
  && ok "l'étape d'apply déclare son propre \`agent any\` (alloué APRÈS la réponse)" \
  || ko "l'étape d'apply ne déclare aucun agent — sous \`agent none\` elle n'aurait pas de workspace"

echo
# L_POST — LA FRONTIÈRE corps-du-pipeline / post{}, calculée ICI parce que §15
# s'en sert. Elle était affectée QUINZE LIGNES PLUS BAS (§15b) et lue en
# `$L_POST` : immune à `set -u`, donc `awk "NR>=0"` rendait TOUT le
# fichier et le contrôle « le seul node() est bien DANS le post » ne pouvait
# plus rougir (vert vacant trouvé par relecture adverse le 2026-09-12). Le
# repli REFUSE au lieu de balayer.
L_POST=$(grep -n '^  post {' "$JF" | head -1 | cut -d: -f1)
if [ -z "$L_POST" ]; then
  ko "aucun bloc \`post\` de niveau pipeline — la frontière corps/post n'existe pas, et la dette I3 est reproduite (§15b)"
  L_POST=999999
fi

echo "== 15. plus AUCUN Groovy inline dans le job : c'est un Pipeline from SCM =="
# LA demande client : des Jenkinsfile versionnés, pas un pipeline en dur dans
# un config.xml. Ce contrôle est la preuve que la conversion a bien eu lieu et
# ne peut pas régresser en silence.
grep -q 'CpsScmFlowDefinition' "$JOB" \
  && ok "définition = CpsScmFlowDefinition (Pipeline from SCM)" || ko "le job n'est pas un Pipeline from SCM"
if grep -q '>org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition<\|class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition"' "$JOB"; then
  ko "le job contient encore une CpsFlowDefinition (pipeline en dur dans le XML)"
else
  ok "aucune CpsFlowDefinition résiduelle"
fi
if grep -q '<script>' "$JOB"; then
  ko "le job contient encore un bloc <script> (Groovy inline)"
else
  ok "aucun bloc <script> : le XML ne porte plus une ligne de Groovy"
fi
grep -qF '<scriptPath>poc-control-plane-federation/ci/Jenkinsfile.team-apply</scriptPath>' "$JOB" \
  && ok "scriptPath pointe sur ci/Jenkinsfile.team-apply" || ko "scriptPath absent ou divergent"
grep -qF '<lightweight>false</lightweight>' "$JOB" \
  && ok "lightweight=false : le workspace de l'agent porte tout le dépôt (scripts/, ansible/, ci/lib/), pas seulement le Jenkinsfile" \
  || ko "lightweight absent ou true — le workspace n'aurait que le Jenkinsfile, tous les appels scripts/ mourraient"
# Le CORPS du pipeline doit rester déclaratif : ni try/catch, ni Groovy
# scripté. Le `post{}`, lui, EN EXIGE (try + timeout + catch autour du nœud,
# parité provision-apply ci/Jenkinsfile.provision-apply:511-520) — d'où la
# frontière L_POST. L'interdiction portait sur le FICHIER ENTIER, et le
# commentaire disait « ce job n'a pas de bloc post » : faux depuis §15b.
if awk "NR<$L_POST" "$JF" | grep -qE '^[[:space:]]*(try \{|\} catch)'; then
  ko "le CORPS du pipeline contient un try/catch — la gestion d'erreur doit y passer par les codes de retour et \`post\`"
else
  ok "aucun try/catch dans le CORPS du pipeline (le post{} en a, et doit en avoir : §15b)"
fi
NODE_COUNT=$(grep -cE '^\s*node\(' "$JF")
# Exactement 1 `node(...)` attendu : celui du `post{always}` (parité team-publish).
# Avec `agent none`, le post n'a ni exécuteur ni workspace → un `node` explicite y
# est OBLIGATOIRE (pas du pipeline scripté qui revient). Ailleurs qu'au post = 0.
[ "$NODE_COUNT" -eq 1 ] \
  && ok "exactement un \`node(...)\` — celui du \`post{always}\` (agent none l'exige), pas du Groovy scripté ailleurs" \
  || ko "nombre de \`node(...)\` inattendu (${NODE_COUNT}, attendu 1 = celui du post) — le pipeline redevient scripté OU le post a perdu son node"
POST_NODE=$(awk "NR>=$L_POST" "$JF" | grep -cE '^\s*node\(')
[ "$POST_NODE" -eq 1 ] \
  && ok "le seul \`node(...)\` est bien DANS le \`post{}\` — le corps du pipeline reste 100% déclaratif" \
  || ko "le \`node(...)\` n'est pas dans le post (${POST_NODE} trouvé au post) — Groovy scripté hors post"
# Au plus UN `script {}` dans le CORPS (le nommage du build). Le post{} en a
# un aussi — c'est lui qui porte la garde Groovy AVANT le nœud — et le compter
# avec les autres ferait rougir une propriété qu'on VEUT.
SCRIPT_BLOCKS=$(awk "NR<$L_POST" "$JF" | grep -cE '^[[:space:]]*script \{')
[ "$SCRIPT_BLOCKS" -le 1 ] \
  && ok "au plus un bloc \`script {}\` dans le corps (le nommage du build) — le reste est déclaratif" \
  || ko "${SCRIPT_BLOCKS} blocs \`script {}\` dans le corps — le Groovy revient par la fenêtre"

echo
echo "== 15b. post{always} de STATUT BUILD sur la PR (parité team-publish, dette I3 fermée) =="
# team-apply.sh commente DÉJÀ la PR (✅/❌) mais SEULEMENT s'il tourne : un échec
# AVANT lui (garde d'identité refusée, pause abandonnée/expirée, agent injoignable)
# laissait la PR d'onboarding MUETTE — c'est la dette I3, longtemps ouverte pour
# team-apply. Ce bloc `post{always}` de niveau PIPELINE la ferme.
# L_POST est calculé AVANT §15 (qui s'en sert pour la frontière corps/post).
[ "$L_POST" != 999999 ] \
  && ok "bloc \`post\` de niveau PIPELINE présent (ligne $L_POST) — un refus de garde ou une pause abandonnée est désormais commenté sur la PR (dette I3 FERMÉE)" \
  || ko "aucun \`post\` de niveau pipeline — un refus de garde ou une pause abandonnée resterait muet sur la PR (dette I3 reproduite)"
grep -qF 'COMMENT_MARKER="<!-- team-apply-build -->"' "$JF" \
  && ok "marqueur DISTINCT \`team-apply-build\` — le statut build ne peut pas écraser le commentaire détaillé de team-apply.sh (chacun idempotent sous son marqueur)" \
  || ko "marqueur de statut build absent ou non distinct — risque d'écrasement du commentaire de team-apply.sh"
{ awk "NR>=$L_POST" "$JF" | grep -q 'gitea-pr-comment.sh' \
  && awk "NR>=$L_POST" "$JF" | grep -q 'onboard/\*)'; } \
  && ok "le post{} filtre \`onboard/*\` ET commente via gitea-pr-comment.sh (idempotent, une PR hors onboard/* n'est pas commentée)" \
  || ko "le post{} ne filtre pas onboard/* ou n'appelle pas gitea-pr-comment.sh"
# ── L'ORDRE DANS LE post{} : la garde AVANT le nœud ─────────────────────────
# Défaut trouvé par relecture adverse le 2026-09-12 : le post prenait
# exécuteur + clone + credential AVANT toute garde (les gardes vivaient dans le
# `sh`). Sans conséquence fonctionnelle — mais le lot L6 phase 2 a changé le
# poids du détail : le XML de ce job ne porte plus aucune propriété, donc
# setup-provision-jobs.sh s'IMPOSE un build d'AMORÇAGE et en JUGE le verdict.
# Un post sans timeout qui attend un exécuteur occupé fait expirer l'amorçage,
# et la POSE est déclarée en échec sur un job dont le déclencheur EST posé. Le
# motif prouvé est celui de provision-apply (test-a0-wiring.sh §9 (f)).
POSTV="$TMP/jf-ta.post"; awk "NR>=$L_POST" "$JF" > "$POSTV"
L_G=$(grep -nF "if (!ref.startsWith('onboard/') || !(num ==~ /[0-9]+/))" "$POSTV" | head -1 | cut -d: -f1)
L_ND=$(grep -nE '^[[:space:]]*node\(' "$POSTV" | head -1 | cut -d: -f1)
L_TRY=$(grep -nE '^[[:space:]]*try \{' "$POSTV" | head -1 | cut -d: -f1)
L_TO=$(grep -nF "timeout(time: 2, unit: 'MINUTES')" "$POSTV" | head -1 | cut -d: -f1)
L_CATCH=$(grep -nF 'catch (e)' "$POSTV" | head -1 | cut -d: -f1)
{ [ -n "$L_G" ] && [ -n "$L_ND" ] && [ "$L_G" -lt "$L_ND" ]; } \
  && ok "post{} : garde Groovy onboard/* + PR_NUMBER numérique (ligne +$L_G) AVANT node( (+$L_ND) — aucune PR étrangère ne consomme d'exécuteur ni de clone" \
  || ko "post{} : garde absente ou APRÈS le nœud (garde=${L_G:-?} node=${L_ND:-?})"
{ [ -n "$L_TRY" ] && [ -n "$L_TO" ] && [ -n "$L_CATCH" ] && [ -n "$L_ND" ] \
  && [ "$L_TRY" -lt "$L_ND" ] && [ "$L_TO" -lt "$L_ND" ]; } \
  && ok "post{} : try (+$L_TRY) et timeout 2 min (+$L_TO) enveloppent le nœud, catch présent (+$L_CATCH) — un statut non posté ne rougit pas le build et n'expire pas l'amorçage" \
  || ko "post{} : try/timeout/catch absents ou mal placés (try=${L_TRY:-?} to=${L_TO:-?} catch=${L_CATCH:-?} node=${L_ND:-?})"
# MUTATION : le `node()` remonté du post vers le CORPS. Elle DOIT rougir — le
# contrôle « le seul node() est bien DANS le post » était vacant jusqu'au
# 2026-09-12 (L_POST lu avant d'être affecté, donc `awk "NR>=0"`), et sous
# `agent none` un post sans `node` lèverait MissingContextVariableException.
awk -v lp="$L_POST" -v nd="$L_ND" 'NR==lp+nd-1 { next }
  NR==lp-1 { print "    node(\"deplace-hors-post\") { }" } { print }' "$JF" > "$TMP/mn.jf"
MN_TOTAL=$(grep -cE '^[[:space:]]*node\(' "$TMP/mn.jf")
MN_LP=$(grep -n '^  post {' "$TMP/mn.jf" | head -1 | cut -d: -f1)
MN_POST=$(awk "NR>=${MN_LP:-999999}" "$TMP/mn.jf" | grep -cE '^[[:space:]]*node\(')
{ [ "$MN_TOTAL" -eq 1 ] && [ "$MN_POST" -ne 1 ]; } \
  && ok "mutation « le node() remonte du post vers le corps » ⇒ rouge (total encore 1, mais 0 au post) : le contrôle n'est plus vacant" \
  || ko "mutation « node() hors post » INVISIBLE (total=$MN_TOTAL post=$MN_POST) — le contrôle du §15 mesure-t-il encore quelque chose ?"

echo
echo "== 16. le total de contrôles exécutés correspond au total ATTENDU, écrit en dur =="
# Le `RÉSULTAT : %d/%d` final ci-dessous imprime PASS/(PASS+FAIL) — une
# formule auto-référentielle qui devient vraie par construction. CE contrôle
# compare plutôt contre EXPECTED_CHECKS, une CONSTANTE écrite en tête de ce
# fichier, indépendante de ce qui vient de tourner.
ACTUAL_CHECKS=$((PASS+FAIL))
if [ "$ACTUAL_CHECKS" -eq "$EXPECTED_CHECKS" ]; then
  ok "nombre de contrôles exécutés = ${EXPECTED_CHECKS} (attendu, écrit en dur en tête de ce fichier)"
else
  ko "nombre de contrôles exécutés = ${ACTUAL_CHECKS}, attendu ${EXPECTED_CHECKS} (écrit en dur) — une section a peut-être été sautée silencieusement (branche jamais évaluée, boucle vide, etc.)"
fi

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
