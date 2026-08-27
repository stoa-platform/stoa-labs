#!/usr/bin/env bash
# test-team-promote-wiring.sh — LA PORTE HORS-LIGNE DU JALON G5 :
# « porte refusée ⇒ moteur JAMAIS lancé ».
#
# Le GOAL de G5 tient à un invariant d'ORDRE, pas à une liste de contrôles :
# TOUTES les gardes de scripts/team-promote.sh sont mécaniquement ANTÉRIEURES au
# site d'appel du moteur. Une chaîne qui refuse APRÈS avoir importé l'archive ne
# garde rien — elle journalise ses regrets. Cette épreuve le prouve deux fois,
# par deux moyens indépendants :
#
#   VOLET A — statique. L'ordre est lu dans le CODE (décommenté) : chaque jeton
#     de refus est textuellement AVANT l'unique appel `run_engine`. Chaque
#     assertion d'ordre est doublée d'une MUTATION sur une COPIE (jamais sur
#     l'arbre) qui doit la faire rougir : une épreuve d'ordre qu'aucune mutation
#     ne casse est une épreuve vacante.
#
#   VOLET B — exécution réelle, contre des stubs. Le script tourne POUR DE VRAI
#     (clones git smart-HTTP, API Gitea, registre d'archives, Vault) avec un
#     `ansible-playbook` et un `labctl` de paille en tête de PATH qui
#     n'écrivent qu'une ligne dans $STUB_LOG. Pour CHAQUE refus : le jeton
#     attendu sur la sortie ET **$STUB_LOG absent** — le moteur n'a pas été
#     effleuré. Le chemin nominal, lui, exige EXACTEMENT UNE invocation, et on
#     relit ses extra-vars.
#
# ⚠ POURQUOI UN VRAI SERVEUR GIT ET PAS DES `file://`. team-promote.sh
# construit ses URL de clone en préfixant `$GIT_HOST` — un `file://` n'est pas
# exprimable. Et le clone du dépôt plateforme est `--depth 1`, que le protocole
# HTTP « dumb » ne sait pas servir. Le stub délègue donc au CGI `git
# http-backend` (livré avec git), qui parle le smart HTTP natif : c'est la voie
# la plus simple QUI MARCHE, et elle n'ajoute aucune dépendance.
#
# Hors ligne intégralement : aucun Jenkins, aucune Gitea, aucun Vault, aucune
# gateway. Rien contre le lab.
#
#   bash scripts/test-team-promote-wiring.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/scripts/team-promote.sh"
JF="$ROOT/ci/Jenkinsfile.team-promote"
JOB="$ROOT/ci/jenkins/team-promote.job.xml"
PROXY="$ROOT/gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml"
AMI="$ROOT/scripts/lib/assert-merge-identity.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

for f in "$SC" "$JF" "$JOB" "$PROXY" "$AMI"; do
  [ -f "$f" ] || { echo "!! fichier indispensable absent : $f"; exit 2; }
done

TMP="$(mktemp -d)"
# ⚠ `kill "${STUB_PID:-0}"` SERAIT LE PIRE DÉFAUT POSSIBLE ICI (revue F4). Ce
# trap est armé bien AVANT que $STUB_PID n'existe (le stub ne démarre qu'au
# volet B, ~450 lignes plus bas) : un SIGINT reçu pendant le volet A le
# déclencherait avec la variable non définie, et `kill 0` signale TOUT LE GROUPE
# DE PROCESSUS — le `make lint-ci` appelant compris. On teste donc la présence.
trap '[ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM
umask 077

# ── Décommenteurs ────────────────────────────────────────────────────────────
# nc_strict : celui de test-palier-retention.sh / test-archive-store.sh. Le
# décommenteur naïf (`s/[[:space:]]*#.*$//`, ZÉRO blanc accepté avant le `#`)
# coupe aussi au `#` d'une expansion de longueur `${#var}` — team-promote.sh en
# porte deux (`${#PRE_SHA}`, `${#DEPLOY_PIN_COMMIT}` côté lib). Sans ce
# garde-fou, les numéros de ligne mesurés porteraient sur un fichier mutilé.
nc_strict() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]][[:space:]]*#.*$//' "$1"; }
# nc_groovy : commentaires PLEINE LIGNE seulement (`//` ou `#`). Volontairement
# pas de commentaire de fin de ligne : `'http://gitea:3000'` serait tronqué au
# `//` de son schéma d'URL, et une valeur littérale disparaîtrait du fichier
# analysé. Les occurrences qu'on doit neutraliser ici (les `agent any` cités en
# prose) sont toutes en pleine ligne.
nc_groovy() { sed -e 's|^[[:space:]]*//.*$||' -e 's/^[[:space:]]*#.*$//' "$1"; }

SC_NC="$TMP/promote_nc.sh";  nc_strict "$SC" > "$SC_NC"
JF_NC="$TMP/jenkinsfile_nc"; nc_groovy "$JF" > "$JF_NC"

# ── Prédicats réutilisables (volet A ④/⑤, rejoués sur mutant au cas ⑲) ───────
#
# ORDRE_TOKENS : la liste ORDONNÉE des jetons de refus de team-promote.sh, dans
# l'ordre où le script les pose. Chacun doit se trouver AVANT le site d'appel
# unique du moteur.
ORDRE_TOKENS="BRANCH_FORMAT_INVALIDE PAYLOAD_PERIME REPO_NON_DECLARE \
MERGE_SHA_NON_ANCETRE PIN_ABSENT ARCHIVE_INTROUVABLE PIN_NON_RESOLU \
GATE_REFS_REQUIRED IDENTITE_REFUSEE PALIER_FERME"

# ordre_verdict <fichier-décommenté> — rend "OK" ou "KO: <détail>" sur stdout.
# Prédicat PUR (n'appelle ni ok() ni bad()) : c'est ce qui permet au cas ⑲ de le
# rejouer sur un MUTANT et d'exiger un KO.
ordre_verdict() {
  local f="$1" call tok l
  call=$(grep -nE '^[[:space:]]*run_engine ' "$f" | head -1 | cut -d: -f1)
  [ -n "$call" ] || { echo "KO: aucun site d'appel \`run_engine\` trouvé"; return 0; }
  for tok in $ORDRE_TOKENS; do
    l=$(grep -n -F "fail \"$tok" "$f" | head -1 | cut -d: -f1)
    [ -n "$l" ] || { echo "KO: garde $tok absente de tout fail() réel"; return 0; }
    [ "$l" -lt "$call" ] || { echo "KO: $tok en ligne $l, APRÈS l'appel du moteur (ligne $call)"; return 0; }
  done
  echo "OK"
}

# scellement_verdict <fichier-décommenté> — l'extra-var qui SCELLE l'env
# d'authoring est-elle réellement passée au moteur ansible ?
scellement_verdict() {
  grep -q -F -- '-e apim_ss_authoring_env=' "$1" && echo "OK" || echo "KO"
}

# params_verdict <Jenkinsfile décommenté> — la pause n'expose-t-elle QUE
# l'identité ? Rend "OK" ou "KO: <détail>". Prédicat PUR, pour la même raison
# que ordre_verdict : la mutation ②bis le rejoue sur une copie.
#
# ⚠ L'ALPHABET DES TYPES DE PARAMÈTRES EST LARGE, ET C'EST TOUT L'ENJEU (revue
# F1). Une première version listait `(string|password)` — elle laissait donc
# passer un `choice(name: 'PROMOTE_ENGINE', choices: [...])` ajouté DANS le bloc
# `input`, c'est-à-dire EXACTEMENT le geste que cette assertion existe pour
# interdire (le moteur deviendrait choisissable par quiconque répond à la
# pause, alors que la définition du job, elle, est protégée — G4 D7). Jenkins
# déclaratif connaît aussi `booleanParam`, `text`, `file`, `choice`,
# `credentials` : on prend donc TOUT identifiant suivi de `(name: '…'`, et on
# exige que la liste obtenue soit exactement V_PASS/V_USER.
params_verdict() {
  local f="$1" names k
  names=$(grep -oE "[A-Za-z]+\(name: '[A-Z_]+'" "$f" | sed -E "s/.*name: '//; s/'\$//" | sort | tr '\n' ' ')
  [ "$names" = "V_PASS V_USER " ] \
    || { echo "KO: paramètres de pause = '${names}' (attendu 'V_PASS V_USER ')"; return 0; }
  for k in PROMOTE_ENGINE ADMIN_VIA; do
    grep -oE "[A-Za-z]+\(name: '$k'" "$f" | grep -q . \
      && { echo "KO: $k est exposé en paramètre — le knob de pipeline devient saisissable"; return 0; }
  done
  echo "OK"
}

echo "======================================================================"
echo "VOLET A — statique : l'ORDRE est lu dans le code, et les mutations le prouvent"
echo "======================================================================"

echo
echo "== ① le Jenkinsfile et le XML portent le MÊME déclencheur (token + genericVariables) =="
JF_TOKEN=$(grep -oE "token: '[^']*'" "$JF_NC" | head -1 | sed "s/token: '//; s/'$//")
XML_TOKEN=$(grep -oE '<token>[^<]*</token>' "$JOB" | head -1 | sed 's/<token>//; s|</token>||')
[ -n "$JF_TOKEN" ] && [ "$JF_TOKEN" = "$XML_TOKEN" ] \
  && ok "① token GWT identique dans les deux fichiers ('$JF_TOKEN') — c'est le XML qui gagne, une divergence serait SILENCIEUSE" \
  || bad "① token divergent ou absent (Jenkinsfile='$JF_TOKEN', XML='$XML_TOKEN')"
[ "$JF_TOKEN" = "stoa-team-publish" ] \
  && ok "① le token est bien le PARTAGÉ stoa-team-publish (D1 : un seul webhook réveille team-publish ET team-promote)" \
  || bad "① token inattendu '$JF_TOKEN' — un token propre exigerait un geste sur CHAQUE dépôt d'équipe"
grep -oE "\[key: '[A-Z_]+'" "$JF_NC" | sed "s/\[key: '//; s/'$//" | sort > "$TMP/keys.jf"
grep -oE '<key>[A-Z_]+</key>' "$JOB" | sed 's/<key>//; s|</key>||' | sort > "$TMP/keys.xml"
if cmp -s "$TMP/keys.jf" "$TMP/keys.xml"; then
  ok "① les genericVariables sont IDENTIQUES des deux côtés ($(wc -l < "$TMP/keys.jf" | tr -d ' ') clés) — comparaison des deux listes extraites, pas un grep par clé"
else
  bad "① les listes de genericVariables divergent : JF=[$(tr '\n' ' ' < "$TMP/keys.jf")] XML=[$(tr '\n' ' ' < "$TMP/keys.xml")]"
fi
[ -s "$TMP/keys.jf" ] \
  && ok "① la liste extraite du Jenkinsfile n'est pas vide (une extraction muette ferait passer deux fichiers vides pour identiques)" \
  || bad "① aucune genericVariable extraite du Jenkinsfile — l'ancre d'extraction a bougé, la comparaison ① serait vacante"

echo
echo "== ② AUCUN paramètre de build : PROMOTE_ENGINE/ADMIN_VIA sont des knobs de PIPELINE =="
# Un paramètre de build rendrait le MOTEUR et la VOIE D'ADMIN choisissables par
# quiconque déclenche le job — la définition du job, elle, est protégée (G4 D7).
if grep -qE '^  parameters \{' "$JF_NC"; then
  bad "② un bloc \`parameters {}\` de NIVEAU PIPELINE existe — les knobs deviendraient saisissables au lancement"
else
  ok "② aucun bloc \`parameters {}\` de niveau pipeline"
fi
NPARAMS=$(grep -cE '^[[:space:]]*parameters \{' "$JF_NC")
[ "$NPARAMS" -eq 1 ] \
  && ok "② un SEUL bloc \`parameters {}\` dans tout le fichier — celui de la pause (V_USER/V_PASS)" \
  || bad "② $NPARAMS bloc(s) \`parameters {}\` (attendu 1, celui de l'input)"
L_INPUT=$(grep -nE '^      input \{' "$JF_NC" | head -1 | cut -d: -f1)
L_PARAMS=$(grep -nE '^[[:space:]]*parameters \{' "$JF_NC" | head -1 | cut -d: -f1)
if [ -n "$L_INPUT" ] && [ -n "$L_PARAMS" ] && [ "$L_PARAMS" -gt "$L_INPUT" ]; then
  ok "② l'unique bloc \`parameters\` (ligne $L_PARAMS) est IMBRIQUÉ dans la directive \`input\` (ligne $L_INPUT)"
else
  bad "② le bloc \`parameters\` n'est pas celui de l'input (input=$L_INPUT parameters=$L_PARAMS)"
fi
V2="$(params_verdict "$JF_NC")"
[ "$V2" = OK ] \
  && ok "② la pause n'expose QUE l'identité : paramètres exactement V_USER/V_PASS, et ni PROMOTE_ENGINE ni ADMIN_VIA (tous types de paramètres déclaratifs confondus)" \
  || bad "② $V2"
# MUTATION anti-vacuité (revue F1) : un `choice()` injecté DANS le bloc `input`
# doit faire rougir ②. C'est le contournement réel — un `parameters {}` de
# NIVEAU PIPELINE, lui, est déjà attrapé par le compte ci-dessus.
awk '{ print }
     /^[[:space:]]*parameters \{$/ && !done { print "          choice(name: '\''PROMOTE_ENGINE'\'', choices: ['\''ansible'\'','\''labctl'\''], description: '\''mutant'\'')"; done=1 }' \
  "$JF" > "$TMP/jf_mut2"
cmp -s "$JF" "$TMP/jf_mut2" \
  && bad "②bis MUTATION no-op : le mutant est identique au Jenkinsfile — l'ancre du bloc \`parameters\` a bougé" \
  || ok "②bis le mutant diffère RÉELLEMENT du Jenkinsfile (anti-no-op cmp)"
nc_groovy "$TMP/jf_mut2" > "$TMP/jf_mut2_nc"
case "$(params_verdict "$TMP/jf_mut2_nc")" in
  KO*PROMOTE_ENGINE*) ok "②bis MUTATION : un \`choice(name: 'PROMOTE_ENGINE')\` glissé dans l'\`input\` fait ROUGIR ② en le nommant (l'assertion n'est pas vacante)" ;;
  OK)                 bad "②bis MUTATION : le \`choice()\` injecté passe au VERT — ② ne couvre pas les types de paramètres autres que string/password" ;;
  *)                  bad "②bis MUTATION : ② rougit, mais sans nommer le paramètre injecté : $(params_verdict "$TMP/jf_mut2_nc")" ;;
esac
if grep -q 'ParametersDefinitionProperty' "$JOB"; then
  bad "② le XML porte une ParametersDefinitionProperty — le job exposerait des paramètres de build"
else
  ok "② le XML ne déclare AUCUN paramètre de build"
fi
for K in PROMOTE_ENGINE ADMIN_VIA; do
  grep -q "$K" "$JOB" \
    && bad "② $K apparaît dans le XML du job — il doit rester un knob d'ENVIRONNEMENT du Jenkinsfile" \
    || ok "② $K absent du XML du job (knob d'environnement, pas de coquille de job)"
done
for K in PROMOTE_ENGINE ADMIN_VIA; do
  grep -qE "^    $K +=" "$JF_NC" \
    && ok "② $K est bien posé dans le bloc \`environment {}\` du Jenkinsfile" \
    || bad "② $K absent du bloc \`environment {}\` — team-promote.sh retomberait sur son propre défaut sans que le pipeline le dise"
done

echo
echo "== ③ le filtre promote/ est présent aux TROIS sites (contexte, when, post) =="
# ⚠ ANCRE PROPRE AU SITE 1 (revue F2). Un `startsWith('promote/')` nu est une
# SOUS-CHAÎNE du motif du site 2 : l'assertion restait verte après suppression
# complète du stage Contexte — un vert vacant, mesuré. On ancre donc sur la
# forme NÉGATIVE, qui n'existe qu'ici.
grep -q -F "if (!(env.PR_BRANCH ?: '').startsWith('promote/'))" "$JF_NC" \
  && ok "③ site 1 (stage Contexte) : la branche est testée avant tout, et le build DIT pourquoi il n'y a rien à promouvoir" \
  || bad "③ site 1 absent — le build ne dirait pas pourquoi il n'y a rien à promouvoir"
grep -q -F "expression { (env.PR_BRANCH ?: '').startsWith('promote/') }" "$JF_NC" \
  && ok "③ site 2 (\`when\`) : la condition garde l'étape d'apply" \
  || bad "③ site 2 absent — n'importe quelle PR fermée d'un dépôt d'équipe déclencherait la promotion"
grep -q -F 'beforeInput true' "$JF_NC" \
  && ok "③ site 2bis : \`beforeInput true\` — une PR hors promote/* ne réveille PERSONNE" \
  || bad "③ \`beforeInput true\` absent — la pause s'ouvrirait avant l'évaluation du \`when\`"
POST_CODE=$(awk '/^  post \{/{f=1} f{print}' "$JF_NC")
printf '%s\n' "$POST_CODE" | grep -q -F 'promote/*) ;;' \
  && ok "③ site 3 (\`post\`) : le statut de build se tait sur une PR hors promote/* (étape SAUTÉE, pas exécutée)" \
  || bad "③ site 3 absent — le post commenterait une PR qui n'a rien déclenché"

echo
echo "== ④ run_engine : défini UNE fois, appelé UNE fois, et APRÈS toutes les gardes =="
NDEF=$(grep -cE '^run_engine\(\) \{' "$SC_NC")
[ "$NDEF" -eq 1 ] \
  && ok "④ \`run_engine\` défini exactement 1 fois" \
  || bad "④ $NDEF définition(s) de \`run_engine\` (attendu 1)"
NCALL=$(grep -cE '^[[:space:]]*run_engine ' "$SC_NC")
[ "$NCALL" -eq 1 ] \
  && ok "④ \`run_engine\` appelé exactement 1 fois — deux sites d'appel rouvriraient la question à chaque relecture" \
  || bad "④ $NCALL site(s) d'appel de \`run_engine\` (attendu 1)"
V4="$(ordre_verdict "$SC_NC")"
if [ "$V4" = OK ]; then
  L_CALL=$(grep -nE '^[[:space:]]*run_engine ' "$SC_NC" | head -1 | cut -d: -f1)
  ok "④ les $(printf '%s\n' $ORDRE_TOKENS | wc -l | tr -d ' ') gardes nommées sont TOUTES avant le site d'appel (ligne $L_CALL, code décommenté)"
else
  bad "④ $V4"
fi

echo
echo "== ⑤ le SCELLEMENT de l'env d'authoring, et l'archive sur le chemin labctl =="
[ "$(scellement_verdict "$SC_NC")" = OK ] \
  && ok "⑤ \`-e apim_ss_authoring_env=\` est réellement passé au moteur ansible (l'env d'authoring est SCELLÉ, pas devinable par le play)" \
  || bad "⑤ \`-e apim_ss_authoring_env=\` absent — le rôle retomberait sur son propre défaut"
grep -q -F -- '-e apim_ss_authoring_env="$ENVN_AUTH"' "$SC_NC" \
  && ok "⑤ l'extra-var est alimentée par \$ENVN_AUTH (affectation sèche depuis la constante de lib, jamais un \${…:-dev})" \
  || bad "⑤ l'extra-var n'est pas alimentée par \$ENVN_AUTH — un paramètre de job pourrait la choisir"
grep -q -F -- '--archive "$DEPLOY_PIN_ARCHIVE"' "$SC_NC" \
  && ok "⑤ le chemin labctl passe \`--archive \"\$DEPLOY_PIN_ARCHIVE\"\` (le verbe G5 est l'IMPORT D'ARCHIVE, jamais un re-POST)" \
  || bad "⑤ \`--archive \"\$DEPLOY_PIN_ARCHIVE\"\` absent du chemin labctl"
# MUTATION anti-vacuité : retirer le scellement d'une COPIE doit faire rougir
# l'assertion. (L'arbre n'est jamais touché — la copie vit dans $TMP.)
sed '/-e apim_ss_authoring_env=/d' "$SC_NC" > "$TMP/sc_mut5"
cmp -s "$SC_NC" "$TMP/sc_mut5" \
  && bad "⑤ MUTATION no-op : le mutant est identique à l'original — l'ancre a bougé, la mutation ne mute rien" \
  || ok "⑤ MUTATION : le mutant diffère RÉELLEMENT (anti-no-op cmp)"
[ "$(scellement_verdict "$TMP/sc_mut5")" = KO ] \
  && ok "⑤ MUTATION : scellement retiré ⇒ l'assertion ROUGIT (elle n'est pas vacante)" \
  || bad "⑤ MUTATION : le scellement retiré, l'assertion reste verte — elle ne teste rien"

echo
echo "== ⑥ l'allowlist du proxy d'admin porte /rest/apigateway/archive, et TOUJOURS aucun delete: =="
grep -qE '^  /rest/apigateway/archive:' "$PROXY" \
  && ok "⑥ /rest/apigateway/archive déclaré dans wm-admin-proxy.openapi.yaml (sans lui, l'import d'archive passe par une route non déclarée)" \
  || bad "⑥ /rest/apigateway/archive absent de l'allowlist du proxy — le verbe G5 n'aurait pas de route"
NDEL=$(grep -c 'delete:' "$PROXY")
[ "$NDEL" -eq 0 ] \
  && ok "⑥ AUCUN \`delete:\` dans l'allowlist du proxy (l'ouverture d'archive n'a rien ouvert d'autre)" \
  || bad "⑥ $NDEL \`delete:\` dans l'allowlist du proxy — une suppression est devenue atteignable par la voie d'admin"
python3 -c "import sys,yaml; d=yaml.safe_load(open('$PROXY')) or {}; sys.exit(0 if '/rest/apigateway/archive' in (d.get('paths') or {}) else 1)" \
  && ok "⑥ le fichier PARSE et la route est bien une clé de \`paths\` (pas une sous-chaîne dans un commentaire)" \
  || bad "⑥ le fichier ne parse pas, ou /rest/apigateway/archive n'est pas une clé de \`paths\`"

echo
echo "== ⑦ la porte décide des quatre yeux, et --allow-self-approval ne saute QUE ce bloc =="
# shellcheck source=lib/env-chain.sh
. "$ROOT/scripts/lib/env-chain.sh"
FE_REC="$(env_chain_gate_four_eyes rec)"
FE_INT="$(env_chain_gate_four_eyes int)"
[ "$FE_REC" = "FOUREYES=0" ] \
  && ok "⑦ porte rec ⇒ FOUREYES=0 (selfApproval, gabarit livré)" \
  || bad "⑦ porte rec ⇒ '$FE_REC' (attendu FOUREYES=0)"
[ "$FE_INT" = "FOUREYES=1" ] \
  && ok "⑦ porte int ⇒ FOUREYES=1 (une autre équipe déclenche)" \
  || bad "⑦ porte int ⇒ '$FE_INT' (attendu FOUREYES=1)"
# La PROBE : mêmes trois identités (merger == requester == vault-user).
# AVEC le drapeau ⇒ passe (la porte admet l'auto-approbation).
sh "$AMI" --merged-by oscar --requester oscar --vault-user oscar --allow-self-approval \
  > "$TMP/ami_with.out" 2>&1 \
  && ok "⑦ probe : merger==requester==vault-user PASSE avec --allow-self-approval" \
  || bad "⑦ probe : le drapeau ne laisse pas passer l'auto-approbation : $(cat "$TMP/ami_with.out")"
# SANS le drapeau ⇒ refus nommé FOUR_EYES_VIOLATION.
sh "$AMI" --merged-by oscar --requester oscar --vault-user oscar \
  > "$TMP/ami_without.out" 2>&1 \
  && bad "⑦ probe : l'auto-approbation passe SANS le drapeau — les quatre yeux ne mordent pas" \
  || { grep -q FOUR_EYES_VIOLATION "$TMP/ami_without.out" \
       && ok "⑦ probe : sans le drapeau, refus FOUR_EYES_VIOLATION" \
       || bad "⑦ probe : refusé sans nommer FOUR_EYES_VIOLATION : $(cat "$TMP/ami_without.out")"; }
# CE QUE LE DRAPEAU NE RELÂCHE PAS : l'identité du répondant reste vérifiée.
sh "$AMI" --merged-by oscar --requester oscar --vault-user mallory --allow-self-approval \
  > "$TMP/ami_mm.out" 2>&1 \
  && bad "⑦ probe : --allow-self-approval laisse passer un répondant qui n'a PAS mergé — le drapeau relâcherait MERGER_MISMATCH" \
  || { grep -q MERGER_MISMATCH "$TMP/ami_mm.out" \
       && ok "⑦ probe : MERGER_MISMATCH reste INCONDITIONNEL sous --allow-self-approval (le drapeau saute UNIQUEMENT le bloc quatre yeux)" \
       || bad "⑦ probe : refusé sans nommer MERGER_MISMATCH : $(cat "$TMP/ami_mm.out")"; }
# Et le câblage réel : team-promote.sh conditionne le drapeau à la PORTE, et
# passe `promoted_by` du marqueur (pas l'auteur de la PR) comme demandeur.
grep -q -F 'FOUREYES=0) AMI_ARGS="--allow-self-approval";;' "$SC_NC" \
  && ok "⑦ team-promote.sh conditionne --allow-self-approval à la PORTE (FOUREYES=0), il ne l'invente pas" \
  || bad "⑦ le drapeau n'est pas conditionné à la porte dans team-promote.sh"
grep -q -F -- '--requester "$MK_PROMOTED_BY"' "$SC_NC" \
  && ok "⑦ le DEMANDEUR passé à la garde est \`promoted_by\` du MARQUEUR mergé (comparer au \`ci\` auteur de la PR ne refuserait jamais)" \
  || bad "⑦ le demandeur n'est pas \$MK_PROMOTED_BY — la garde comparerait un humain au compte de service du CI"

echo
echo "== T7 le build labctl vit DANS le stage d'apply, et son échec est nommé =="
NAGENT=$(grep -cE '^[[:space:]]*agent any$' "$JF_NC")
[ "$NAGENT" -eq 1 ] \
  && ok "T7(i) exactement 1 \`agent any\` dans le fichier décommenté — aucun stage à agent indépendant avant l'input" \
  || bad "T7(i) $NAGENT \`agent any\` (attendu 1) : un stage \`Build labctl\` séparé pourrait être résolu sur un AUTRE nœud, et \$WORKSPACE/labctl n'y serait pas"
L_AGENT=$(grep -nE '^[[:space:]]*agent any$' "$JF_NC" | head -1 | cut -d: -f1)
L_POST=$(grep -nE '^  post \{' "$JF_NC" | head -1 | cut -d: -f1)
if [ -n "$L_AGENT" ] && [ -n "$L_INPUT" ] && [ -n "$L_POST" ] \
   && [ "$L_AGENT" -gt "$L_INPUT" ] && [ "$L_AGENT" -lt "$L_POST" ]; then
  ok "T7(i) l'unique \`agent any\` (ligne $L_AGENT) est dans le stage d'apply, APRÈS l'input (ligne $L_INPUT) — la pause ne réserve aucun exécuteur"
else
  bad "T7(i) l'\`agent any\` n'est pas situé dans le stage d'apply (agent=$L_AGENT input=$L_INPUT post=$L_POST)"
fi
grep -q -F '[ ! -x "$LABCTL_BIN" ]' "$JF_NC" \
  && ok "T7(ii) la garde \`-x \"\$LABCTL_BIN\"\` existe en CODE (un binaire présent mais non exécutable est un artefact corrompu, pas un binaire utilisable)" \
  || bad "T7(ii) garde \`-x \"\$LABCTL_BIN\"\` absente du code décommenté"
grep -q -F '[ "${PROMOTE_ENGINE:-ansible}" = labctl ]' "$JF_NC" \
  && ok "T7(ii) le build est gardé par PROMOTE_ENGINE=labctl (le chemin client, ansible, ne builde rien)" \
  || bad "T7(ii) le build n'est pas gardé par PROMOTE_ENGINE=labctl"
grep -q -F 'ERREUR: build labctl en echec' "$JF_NC" \
  && ok "T7(ii) l'échec de build est NOMMÉ et tue le step (\`|| { … exit 1; }\`) — plus de symptôme aval qui accuse le moteur" \
  || bad "T7(ii) aucun \`|| {\` d'échec de build nommé — un \`go\` absent laisserait la chaîne continuer jusqu'au moteur"
L_BUILD=$(grep -n -F 'ERREUR: build labctl en echec' "$JF_NC" | head -1 | cut -d: -f1)
L_LOGIN=$(grep -n -F '. ci/lib/vault-login.sh' "$JF_NC" | head -1 | cut -d: -f1)
if [ -n "$L_BUILD" ] && [ -n "$L_LOGIN" ] && [ "$L_BUILD" -lt "$L_LOGIN" ]; then
  ok "T7(ii) l'échec de build meurt (ligne $L_BUILD) AVANT le login Vault (ligne $L_LOGIN) — aucun token nominatif n'est minté pour rien"
else
  bad "T7(ii) ordre build/login non confirmé (build=$L_BUILD login=$L_LOGIN)"
fi

echo
echo "======================================================================"
echo "VOLET B — exécution réelle : chaque refus, moteur JAMAIS invoqué"
echo "======================================================================"

# ── Les stubs de MOTEUR : en tête de PATH, ils n'écrivent qu'une ligne ───────
STUBBIN="$TMP/bin"; mkdir -p "$STUBBIN"
STUB_LOG="$TMP/engine.log"
cat > "$STUBBIN/ansible-playbook" <<'ENG'
#!/bin/sh
{ printf 'ansible-playbook'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$STUB_LOG"
exit 0
ENG
cat > "$STUBBIN/labctl" <<'ENG'
#!/bin/sh
{ printf 'labctl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$STUB_LOG"
exit 0
ENG
chmod +x "$STUBBIN/ansible-playbook" "$STUBBIN/labctl"

# ── Le stub HTTP unique : Gitea (API + git smart HTTP + packages) et Vault ────
STUB_REPOS="$TMP/repos"; mkdir -p "$STUB_REPOS"
STUB_CTL="$TMP/ctl.json"
STUB_HTTPLOG="$TMP/http.log"; : > "$STUB_HTTPLOG"
cat > "$TMP/stub.py" <<'PY'
import json, os, re, subprocess, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPOS = os.environ["STUB_REPOS"]
CTL   = os.environ["STUB_CTL"]
LOG   = os.environ["STUB_HTTPLOG"]
PKG   = {}          # registre d'archives, en mémoire (motif test-archive-store.sh)
BASE  = [""]        # rempli au démarrage : l'URL de CE serveur

def ctl():
    try:
        return json.load(open(CTL))
    except Exception:
        return {}

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def _log(self, method):
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (method, self.path.split("?")[0]))

    def _body(self):
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            buf = b""
            while True:
                n = int(self.rfile.readline().strip().split(b";")[0], 16)
                if n == 0:
                    self.rfile.readline()
                    break
                buf += self.rfile.read(n)
                self.rfile.readline()
            return buf
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ── git smart HTTP, délégué au CGI git http-backend ──────────────────────
    def _git(self, method):
        p = urllib.parse.urlsplit(self.path)
        body = self._body()
        env = dict(os.environ)
        env.update({
            "GIT_PROJECT_ROOT": REPOS, "GIT_HTTP_EXPORT_ALL": "1",
            "REQUEST_METHOD": method,
            "PATH_INFO": urllib.parse.unquote(p.path),
            "QUERY_STRING": p.query,
            "REMOTE_ADDR": self.client_address[0], "REMOTE_USER": "stub",
            "CONTENT_LENGTH": str(len(body)),
        })
        for h, e in (("Content-Type", "CONTENT_TYPE"),
                     ("Content-Encoding", "HTTP_CONTENT_ENCODING"),
                     ("Git-Protocol", "HTTP_GIT_PROTOCOL")):
            v = self.headers.get(h)
            if v:
                env[e] = v
        r = subprocess.run(["git", "http-backend"], input=body,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        if r.returncode != 0:
            sys.stderr.write("git http-backend rc=%s: %s\n" % (r.returncode, r.stderr[:400]))
        head, _, payload = r.stdout.partition(b"\r\n\r\n")
        status, hdrs = 200, []
        for line in head.split(b"\r\n"):
            k, _, v = line.partition(b":")
            if not k.strip():
                continue
            if k.strip().lower() == b"status":
                status = int(v.strip().split()[0])
            else:
                hdrs.append((k.strip().decode(), v.strip().decode()))
        self.send_response(status)
        for k, v in hdrs:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    # ── routage ──────────────────────────────────────────────────────────────
    def _route(self, method):
        self._log(method)
        path = self.path.split("?")[0]
        c = ctl()

        # Vault : le palier est-il ouvert ?
        m = re.match(r"^/v1/secret/data/stoa/envs/([a-z0-9-]+)/([a-z0-9-]+)$", path)
        if m:
            env_name, key = m.group(1), m.group(2)
            code = int((c.get("vault") or {}).get(key, 200))
            if code != 200:
                self._send(code, json.dumps({"errors": ["permission denied"]}))
                return
            if key == "admin-oauth":
                data = {"token_url": BASE[0] + "/oauth/token", "client_id": "cid",
                        "client_secret": "sec", "scope": ""}
            else:
                data = {"username": "wm-admin-" + env_name, "password": "x"}
            self._send(200, json.dumps({"data": {"data": data}}))
            return

        if path == "/oauth/token":
            self._body()
            self._send(200, json.dumps({"access_token": "stub-bearer", "expires_in": 300}))
            return

        # Gitea : l'état RÉCONCILIÉ d'une PR
        m = re.match(r"^/api/v1/repos/([^/]+/[^/]+)/pulls/([0-9]+)$", path)
        if m:
            pr = dict(c.get("pr") or {})
            self._send(200, json.dumps({
                "merged": bool(pr.get("merged", True)),
                "merge_commit_sha": pr.get("merge_commit_sha", ""),
                "head": {"ref": pr.get("head_ref", "")},
                "base": {"ref": pr.get("base_ref", "main")},
                "merged_by": {"login": pr.get("merged_by", "")},
                "user": {"login": pr.get("user", "")},
            }))
            return

        # Gitea : les commentaires de PR (gitea-pr-comment.sh)
        if re.match(r"^/api/v1/repos/[^/]+/[^/]+/issues/", path):
            self._body()
            if method == "GET":
                self._send(200, "[]")
            else:
                self._send(201, json.dumps({"id": 1}))
            return

        # Registre d'archives (packages génériques Gitea)
        if path.startswith("/api/packages/"):
            if method == "PUT":
                PKG[path] = self._body()
                self._send(201, "stub: cree", "application/octet-stream")
                return
            body = PKG.get(path)
            if body is None:
                self._send(404, "stub: absent du registre", "application/octet-stream")
            else:
                self._send(200, body, "application/octet-stream")
            return

        if ".git/" in path:
            self._git(method)
            return

        self._send(404, json.dumps({"message": "stub: route inconnue " + path}))

    def do_GET(self):    self._route("GET")
    def do_POST(self):   self._route("POST")
    def do_PUT(self):    self._route("PUT")
    def do_PATCH(self):  self._route("PATCH")
    def log_message(self, *a): pass

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
BASE[0] = "http://127.0.0.1:%d" % srv.server_port
print(srv.server_port)
sys.stdout.flush()
srv.serve_forever()
PY

STUB_REPOS="$STUB_REPOS" STUB_CTL="$STUB_CTL" STUB_HTTPLOG="$STUB_HTTPLOG" \
  python3 "$TMP/stub.py" >"$TMP/stub.port" 2>"$TMP/stub.err" &
STUB_PID=$!
printf '{}\n' > "$STUB_CTL"
for _ in $(seq 1 60); do [ -s "$TMP/stub.port" ] && break; sleep 0.1; done
PORT="$(head -n1 "$TMP/stub.port" 2>/dev/null)"
case "$PORT" in ''|*[!0-9]*)
  echo "!! le stub HTTP n'a pas démarré :"; sed 's/^/      /' "$TMP/stub.err"; exit 2;;
esac
GIT_HOST="http://127.0.0.1:$PORT"
echo "  (stub HTTP : $GIT_HOST — git smart HTTP via \`git http-backend\`, pid $STUB_PID)"

# ── Fabrique de dépôts (motif test-deploy-pin.sh, servis en HTTP) ────────────
TEAM_REPO="equipe/paiements"
TEAM_NAME="paiements"
PLAT_REPO="ci/stoa-labs"

_gitinit() { git -C "$1" init -q -b main && git -C "$1" config user.email ci@stoa.lab && git -C "$1" config user.name ci; }
_publish() { # <src-worktree> <full-name>
  rm -rf "${STUB_REPOS:?}/${2}.git"
  mkdir -p "$(dirname "$STUB_REPOS/${2}.git")"
  git clone -q --bare "$1" "$STUB_REPOS/${2}.git"
}

# Dépôt PLATEFORME : il ne porte QUE providers.<authoring>.yml (§3 n'en lit rien
# d'autre). L'équipe se DÉRIVE de ce fichier — jamais du payload du webhook.
PLAT="$TMP/plat"; mkdir -p "$PLAT/poc-control-plane-federation/ansible"; _gitinit "$PLAT"
printf 'providers:\n  - team: %s\n    repo: %s\n' "$TEAM_NAME" "$TEAM_REPO" \
  > "$PLAT/poc-control-plane-federation/ansible/providers.dev.yml"
git -C "$PLAT" add -A && git -C "$PLAT" commit -qm "providers"
_publish "$PLAT" "$PLAT_REPO"

ARCHIVE="$TMP/archive.zip"
printf 'PK\x03\x04 archive de sonde G5 team-promote\n' > "$ARCHIVE"
ARCH_SHA="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
OTHER="$TMP/other.zip"
printf 'CE-NE-SONT-PAS-LES-MEMES-OCTETS\n' > "$OTHER"

store_path() { printf '/api/packages/ci/generic/promote--%s--accounts-read/%s/archive.zip' "$TEAM_NAME" "$1"; }
store_seed() { # <sha-de-l-URL> <fichier à servir>
  local hdr="$TMP/seedhdr"; printf 'Authorization: token stub\n' > "$hdr"
  curl -sS -H @"$hdr" -o /dev/null -w '%{http_code}' \
    --upload-file "$2" "${GIT_HOST}$(store_path "$1")"
}

write_api() { # <dir> <version>
  mkdir -p "$1/apis"
  printf 'apim_api:\n  name: "accounts-read"\n  version: "%s"\n' "$2" > "$1/apis/accounts-read.publish.yml"
  printf 'apim_promote:\n  name: "accounts-read"\n  version: "%s"\n  archive: "{{ playbook_dir }}/../dist/a.zip"\n' "$2" \
    > "$1/apis/accounts-read.promote.yml"
  printf 'openapi: 3.0.0\ninfo: {title: accounts-read, version: "%s"}\n' "$2" > "$1/apis/accounts-read.openapi.yaml"
}

write_marker() { # <dir> <env> <commit> <version> <sha256> <change_ref> <pv_ref> <promoted_by>
  printf 'version: "%s"\nenabled: true\npromoted_by: %s\nmessage: "promotion"\ncommit: %s\nchange_ref: "%s"\npv_ref: "%s"\narchive_sha256: "%s"\n' \
    "$4" "$8" "$3" "$6" "$7" "$5" > "$1/apis/accounts-read.deploy.$2.yaml"
}

# mk_team <dir> — dépôt d'équipe à UN commit d'API ; laisse $PIN_C1 = ce commit.
mk_team() {
  local d="$1"; mkdir -p "$d"; _gitinit "$d"
  write_api "$d" "1.0.0"
  git -C "$d" add -A && git -C "$d" commit -qm "C1 accounts-read 1.0.0"
  PIN_C1="$(git -C "$d" rev-parse HEAD)"
}

seal_team() { # <dir> — commit final + publication ; laisse $MERGE_SHA
  git -C "$1" add -A && git -C "$1" commit -qm "merge de la PR de promotion" >/dev/null
  MERGE_SHA="$(git -C "$1" rev-parse HEAD)"
  _publish "$1" "$TEAM_REPO"
}

VAULT_TOKEN_FILE="$TMP/vault.token"; printf 'hvs.stub-token\n' > "$VAULT_TOKEN_FILE"

# ⚠ L'ARCHIVE LÉGITIME EST SEMÉE ICI, UNE FOIS, ET PAS DANS UN CAS (revue F5).
# Le registre du stub vit EN MÉMOIRE et persiste d'un cas à l'autre — c'est la
# seule chose qui survive (le journal du moteur, le fichier de contrôle et les
# dépôts bare sont tous remis à zéro par cas). La semer au fond d'un cas créait
# un couplage NON DÉCLARÉ : cinq cas en aval avaient besoin que celui-là ait
# tourné d'abord. Le couplage penchait du bon côté (son absence fait rougir,
# pas verdir), mais c'était le seul point du harnais où l'ordre des cas
# comptait sans le dire.
SEED=$(store_seed "$ARCH_SHA" "$ARCHIVE")
[ "$SEED" = 201 ] \
  && ok "volet B : l'archive légitime est au registre (201), semée UNE fois en tête — aucun cas ne dépend de l'ordre des autres" \
  || bad "volet B : le pré-semage de l'archive légitime a échoué (code=$SEED) — les cas ⑬ à ⑱ ne peuvent pas être joués"

set_ctl() { # <merged true|false> <merge_sha> <head_ref> <merged_by> <user> <wm-admin code>
  printf '{"pr":{"merged":%s,"merge_commit_sha":"%s","head_ref":"%s","base_ref":"main","merged_by":"%s","user":"%s"},"vault":{"wm-admin":%s,"admin-oauth":200}}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" > "$STUB_CTL"
}

# run_promote <outfile> <branche> [PROMOTE_ENGINE] [WEBHOOK_REPO] — rend le rc.
# Le moteur de paille est en TÊTE de PATH ; $STUB_LOG est effacé juste avant,
# pour que « absent » signifie « jamais invoqué » et rien d'autre.
run_promote() {
  local out="$1" branch="$2" engine="${3:-ansible}" repo="${4:-$TEAM_REPO}" rc
  rm -f "$STUB_LOG"
  ( cd "$ROOT" && env \
      PATH="$STUBBIN:$PATH" \
      STUB_LOG="$STUB_LOG" \
      WEBHOOK_REPO="$repo" \
      PR_BRANCH="$branch" \
      PR_NUMBER=7 \
      MERGE_SHA="$MERGE_SHA" \
      GITEA_TOKEN=stub \
      VAULT_ADDR="$GIT_HOST" \
      VAULT_TOKEN_FILE="$VAULT_TOKEN_FILE" \
      GIT_HOST="$GIT_HOST" \
      GIT_REPO="$PLAT_REPO" \
      VAULT_IDENTITY_USER=oscar \
      PROMOTE_ENGINE="$engine" \
      ADMIN_VIA=proxy-oauth2 \
      LABCTL_BIN="$STUBBIN/labctl" \
      APIM_API_BASE_TPL='http://webmethods-real:5555/gateway/wm-admin-__ENV__/1.0/rest/apigateway' \
      bash scripts/team-promote.sh ) >"$out" 2>&1
  rc=$?
  return "$rc"
}

# refus_attendu <n° du cas> <libellé> <jeton> <fichier de sortie> <rc>
refus_attendu() {
  local n="$1" label="$2" tok="$3" out="$4" rc="$5"
  [ "$rc" -ne 0 ] && grep -q "$tok" "$out" \
    && ok "$n $label — refus $tok" \
    || bad "$n $label — refus $tok attendu, rc=$rc : $(tail -3 "$out" | tr '\n' ' ')"
  [ ! -e "$STUB_LOG" ] \
    && ok "$n le MOTEUR n'a JAMAIS été invoqué (\$STUB_LOG absent)" \
    || bad "$n le moteur a tourné malgré le refus : $(cat "$STUB_LOG")"
}

echo
echo "== ⑧ WEBHOOK_REPO malformé : refus de FORME, avant tout argv git/curl =="
D="$TMP/t8"; mk_team "$D"
write_marker "$D" rec "$PIN_C1" "1.0.0" "$ARCH_SHA" "" "" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-rec" oscar ci 200
HTTP_BEFORE=$(wc -l < "$STUB_HTTPLOG" | tr -d ' ')
run_promote "$TMP/o8" "promote/accounts-read-rec" ansible 'equipe/paiements;rm'; RC=$?
refus_attendu "⑧" "WEBHOOK_REPO hors classe" "WEBHOOK_REPO_INVALIDE" "$TMP/o8" "$RC"
# ⚠ « AUCUNE requête » SERAIT FAUX, ET LE MESURER AINSI AURAIT ÉTÉ UN VERT
# TROMPEUR : `fail()` RAPPORTE le refus sur la PR (gitea-pr-comment.sh), donc un
# refus, même le tout premier, produit des appels /issues/. Ce qui doit être
# vide, c'est tout le RESTE : aucun clone (.git), aucune réconciliation
# (/pulls/), aucun registre (/api/packages/), aucun Vault (/v1/secret/).
awk -v n="$HTTP_BEFORE" 'NR>n' "$STUB_HTTPLOG" > "$TMP/http8"
if grep -qE '(\.git/|/pulls/|/api/packages/|/v1/secret/)' "$TMP/http8"; then
  bad "⑧bis le refus de forme a laissé partir des appels git/Gitea/registre/Vault : $(tr '\n' ' ' < "$TMP/http8")"
else
  ok "⑧bis aucun clone, aucune réconciliation, aucun registre, aucun Vault — seul le RAPPORT du refus a parlé au réseau ($(wc -l < "$TMP/http8" | tr -d ' ') appel(s), tous /issues/)"
fi

echo
echo "== ⑨ PR non mergée côté Gitea : le payload n'est pas la vérité =="
set_ctl false "$MERGE_SHA" "promote/accounts-read-rec" oscar ci 200
run_promote "$TMP/o9" "promote/accounts-read-rec"; RC=$?
refus_attendu "⑨" "réconciliation Gitea : PR non mergée" "PAYLOAD_PERIME" "$TMP/o9" "$RC"

echo
echo "== ⑩ branche promote/<api>-prod, marqueur ABSENT : aucun repli sur HEAD =="
D="$TMP/t10"; mk_team "$D"
write_marker "$D" rec "$PIN_C1" "1.0.0" "$ARCH_SHA" "" "" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-prod" oscar ci 200
run_promote "$TMP/o10" "promote/accounts-read-prod"; RC=$?
refus_attendu "⑩" "aucun marqueur pour le palier visé" "PIN_ABSENT" "$TMP/o10" "$RC"

echo
echo "== ⑪ digest absent du marqueur : hors authoring, les octets doivent être pinnés =="
D="$TMP/t11"; mk_team "$D"
write_marker "$D" rec "$PIN_C1" "1.0.0" "" "" "" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-rec" oscar ci 200
run_promote "$TMP/o11" "promote/accounts-read-rec"; RC=$?
refus_attendu "⑪" "archive_sha256 vide" "DIGEST_ABSENT" "$TMP/o11" "$RC"

echo
echo "== ⑫ archive JAMAIS poussée au registre =="
NEVER="1111111111111111111111111111111111111111111111111111111111111111"
D="$TMP/t12"; mk_team "$D"
write_marker "$D" rec "$PIN_C1" "1.0.0" "$NEVER" "" "" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-rec" oscar ci 200
run_promote "$TMP/o12" "promote/accounts-read-rec"; RC=$?
refus_attendu "⑫" "digest jamais poussé" "ARCHIVE_INTROUVABLE" "$TMP/o12" "$RC"
grep -q 'STORE_HTTP_404' "$TMP/o12" \
  && ok "⑫bis le refus SOUS-JACENT est nommé (STORE_HTTP_404) — « jamais poussée » reste distinguable de « registre en panne »" \
  || bad "⑫bis STORE_HTTP_404 absent du refus : $(tail -3 "$TMP/o12" | tr '\n' ' ')"

echo
echo "== ⑫ter le registre sert d'AUTRES octets à l'URL pinnée =="
BADSHA="2222222222222222222222222222222222222222222222222222222222222222"
SEED=$(store_seed "$BADSHA" "$OTHER")
[ "$SEED" = 201 ] \
  && ok "⑫ter pré-semage direct du chemin avec d'autres octets (201)" \
  || bad "⑫ter le pré-semage a échoué (code=$SEED) — le cas ne peut pas être joué"
D="$TMP/t12c"; mk_team "$D"
write_marker "$D" rec "$PIN_C1" "1.0.0" "$BADSHA" "" "" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-rec" oscar ci 200
run_promote "$TMP/o12c" "promote/accounts-read-rec"; RC=$?
refus_attendu "⑫ter" "octets servis != digest pinné" "STORE_DIGEST_MISMATCH" "$TMP/o12c" "$RC"

echo
echo "== ⑬ le résolveur refuse : pin vivant sur une branche JAMAIS fusionnée =="
# ⚠ ÉCART ASSUMÉ AVEC LE BRIEF, ET IL FAUT LE DIRE. Le brief visait ici
# ARCHIVE_DIGEST_MISMATCH (le résolveur). Ce refus-là est INATTEIGNABLE dans la
# chaîne livrée : `archive_store_fetch` vérifie DÉJÀ les octets contre le MÊME
# digest, pré-lu au même marqueur mergé (team-promote.sh §5) — c'est le cas
# ⑫ter ci-dessus, qui refuse plus tôt. Le contrôle du résolveur est donc un
# SECOND filet, jamais le premier. On éprouve ici l'AUTRE porte de
# `resolve_deploy_pin` qui, elle, est bien atteignable : l'ancêtreté du pin.
D="$TMP/t13"; mk_team "$D"
git -C "$D" checkout -q -b sournoise
write_api "$D" "9.9.9"
git -C "$D" add -A && git -C "$D" commit -qm "commit jamais merge"
EVIL="$(git -C "$D" rev-parse HEAD)"
git -C "$D" checkout -q main
write_marker "$D" rec "$EVIL" "1.0.0" "$ARCH_SHA" "" "" alice
seal_team "$D"
# L'archive légitime est déjà au registre (semée en tête de volet B) : le refus
# qui suit ne peut donc pas venir du transport. On le VÉRIFIE plutôt que de
# l'affirmer — un GET direct, hors du script éprouvé.
HDR13="$TMP/hdr13"; printf 'Authorization: token stub\n' > "$HDR13"
GET13=$(curl -sS -H @"$HDR13" -o /dev/null -w '%{http_code}' "${GIT_HOST}$(store_path "$ARCH_SHA")")
[ "$GET13" = 200 ] \
  && ok "⑬ l'archive légitime est servie par le registre (200) — ce qui suit est un refus du RÉSOLVEUR, pas du transport" \
  || bad "⑬ le registre ne sert pas l'archive légitime (code=$GET13) — le cas mesurerait le transport, pas le résolveur"
set_ctl true "$MERGE_SHA" "promote/accounts-read-rec" oscar ci 200
run_promote "$TMP/o13" "promote/accounts-read-rec"; RC=$?
refus_attendu "⑬" "pin non ancêtre de main" "PIN_NON_RESOLU" "$TMP/o13" "$RC"
grep -q 'PIN_NON_ANCETRE' "$TMP/o13" \
  && ok "⑬bis le refus PRÉCIS du résolveur remonte au commentaire de PR (PIN_NON_ANCETRE), pas seulement « non résolu »" \
  || bad "⑬bis PIN_NON_ANCETRE absent : $(tail -3 "$TMP/o13" | tr '\n' ' ')"

echo
echo "== ⑭ porte prod sans change_ref au marqueur MERGÉ =="
D="$TMP/t14"; mk_team "$D"
write_marker "$D" prod "$PIN_C1" "1.0.0" "$ARCH_SHA" "" "PV-1" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-prod" oscar ci 200
run_promote "$TMP/o14" "promote/accounts-read-prod"; RC=$?
refus_attendu "⑭" "la porte exige change_ref" "GATE_REFS_REQUIRED" "$TMP/o14" "$RC"

echo
echo "== ⑮ porte int, quatre yeux : le mergeur EST le demandeur =="
D="$TMP/t15"; mk_team "$D"
write_marker "$D" int "$PIN_C1" "1.0.0" "$ARCH_SHA" "" "" oscar
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-int" oscar ci 200
run_promote "$TMP/o15" "promote/accounts-read-int"; RC=$?
refus_attendu "⑮" "merger == promoted_by sur une porte à quatre yeux" "IDENTITE_REFUSEE" "$TMP/o15" "$RC"
grep -q 'FOUR_EYES_VIOLATION' "$TMP/o15" \
  && ok "⑮bis la cause exacte est nommée dans le log (FOUR_EYES_VIOLATION)" \
  || bad "⑮bis FOUR_EYES_VIOLATION absent : $(tail -5 "$TMP/o15" | tr '\n' ' ')"

echo
echo "== ⑯ Vault refuse le secret d'admin du palier : le palier n'est pas ouvert =="
D="$TMP/t16"; mk_team "$D"
write_marker "$D" rec "$PIN_C1" "1.0.0" "$ARCH_SHA" "" "" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-rec" oscar ci 403
run_promote "$TMP/o16" "promote/accounts-read-rec"; RC=$?
refus_attendu "⑯" "lecture de envs/rec/wm-admin refusée (403)" "PALIER_FERME" "$TMP/o16" "$RC"

echo
echo "== ⑰ CHEMIN NOMINAL (porte rec selfApproval, Vault 200, moteur ansible) =="
D="$TMP/t17"; mk_team "$D"
write_marker "$D" rec "$PIN_C1" "1.0.0" "$ARCH_SHA" "" "" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-rec" oscar ci 200
run_promote "$TMP/o17" "promote/accounts-read-rec"; RC=$?
[ "$RC" -eq 0 ] \
  && ok "⑰ le chemin nominal sort 0" \
  || bad "⑰ le chemin nominal a échoué (rc=$RC) : $(tail -5 "$TMP/o17" | tr '\n' ' ')"
[ -s "$STUB_LOG" ] \
  && ok "⑰ le moteur a bien été invoqué" \
  || bad "⑰ le moteur n'a PAS été invoqué sur le chemin nominal — l'épreuve des refus serait vacante (rien n'y passe jamais)"
NINV=$(wc -l < "$STUB_LOG" 2>/dev/null | tr -d ' ')
[ "${NINV:-0}" = 1 ] \
  && ok "⑰ EXACTEMENT une invocation de moteur (un seul site d'appel, prouvé à l'exécution)" \
  || bad "⑰ $NINV invocation(s) de moteur (attendu 1)"
grep -q '^ansible-playbook ' "$STUB_LOG" 2>/dev/null \
  && ok "⑰ c'est bien \`ansible-playbook\` qui a été appelé (PROMOTE_ENGINE=ansible)" \
  || bad "⑰ le moteur invoqué n'est pas ansible-playbook : $(cat "$STUB_LOG" 2>/dev/null)"
grep -q -F -- '-e apim_ss_env=rec' "$STUB_LOG" 2>/dev/null \
  && ok "⑰ extra-var apim_ss_env=rec (le palier VISÉ, dérivé de la branche)" \
  || bad "⑰ apim_ss_env=rec absent des extra-vars"
grep -qE -- '-e apim_ss_archive_pin=/[^ ]+' "$STUB_LOG" 2>/dev/null \
  && ok "⑰ extra-var apim_ss_archive_pin NON VIDE et absolue (les octets fetchés au registre, pas un chemin de manifeste)" \
  || bad "⑰ apim_ss_archive_pin vide ou relative"
grep -q -F -- '-e apim_ss_authoring_env=dev' "$STUB_LOG" 2>/dev/null \
  && ok "⑰ extra-var apim_ss_authoring_env=dev (SCELLÉE sur la constante de lib, pas sur l'environnement du job)" \
  || bad "⑰ apim_ss_authoring_env=dev absent — le scellement du §8 n'atteint pas le moteur"
grep -q -F -- '-e apim_promote_action=import' "$STUB_LOG" 2>/dev/null \
  && ok "⑰ le VERBE est \`import\` (ADR-079 : hors authoring, on importe une archive, on ne re-POSTe pas le contrat)" \
  || bad "⑰ apim_promote_action=import absent"

echo
echo "== ⑱ CHEMIN NOMINAL, moteur labctl : --archive sur la ligne de commande =="
D="$TMP/t18"; mk_team "$D"
write_marker "$D" rec "$PIN_C1" "1.0.0" "$ARCH_SHA" "" "" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-rec" oscar ci 200
run_promote "$TMP/o18" "promote/accounts-read-rec" labctl; RC=$?
[ "$RC" -eq 0 ] \
  && ok "⑱ le chemin labctl sort 0" \
  || bad "⑱ le chemin labctl a échoué (rc=$RC) : $(tail -5 "$TMP/o18" | tr '\n' ' ')"
NINV=$(wc -l < "$STUB_LOG" 2>/dev/null | tr -d ' ')
[ "${NINV:-0}" = 1 ] \
  && ok "⑱ EXACTEMENT une invocation de moteur" \
  || bad "⑱ $NINV invocation(s) de moteur (attendu 1)"
grep -q '^labctl promote ' "$STUB_LOG" 2>/dev/null \
  && ok "⑱ c'est bien \`labctl promote\` qui a été appelé (PROMOTE_ENGINE=labctl)" \
  || bad "⑱ le moteur invoqué n'est pas labctl : $(cat "$STUB_LOG" 2>/dev/null)"
grep -qE -- '--archive /[^ ]+' "$STUB_LOG" 2>/dev/null \
  && ok "⑱ \`--archive <chemin absolu>\` passé au moteur labctl" \
  || bad "⑱ --archive absent ou vide sur la ligne labctl : $(cat "$STUB_LOG" 2>/dev/null)"
grep -q -F -- '--action import' "$STUB_LOG" 2>/dev/null \
  && ok "⑱ \`--action import\` — même verbe des deux côtés" \
  || bad "⑱ --action import absent de la ligne labctl"
grep -q -F -- '--env rec' "$STUB_LOG" 2>/dev/null \
  && ok "⑱ \`--env rec\` — le palier visé" \
  || bad "⑱ --env rec absent de la ligne labctl"

echo
echo "== ⑲ MUTATION FINALE : déplacer l'appel du moteur AVANT la garde PALIER_FERME =="
# La contre-épreuve de l'épreuve : si ④ restait vert sur un script où le moteur
# tourne AVANT la dernière garde, ④ ne mesurerait rien. La mutation s'applique à
# une COPIE (jamais à l'arbre), et l'ancre est un début d'INSTRUCTION — insérer
# entre un test et son `|| fail` produirait un fichier qui ne parse même pas,
# donc un rouge pour la mauvaise raison.
ANCHOR=$(grep -n -F '[ -s "$VAULT_TOKEN_FILE" ]' "$SC" | head -1 | cut -d: -f1)
[ -n "$ANCHOR" ] \
  && ok "⑲ ancre de mutation trouvée (ligne $ANCHOR de team-promote.sh : début du §7, avant PALIER_FERME)" \
  || bad "⑲ ancre de mutation introuvable — la mutation ne peut pas être posée"
awk -v n="${ANCHOR:-0}" '
  NR==n { print "run_engine >\"$TMP/promote.log\" 2>&1" }
  /^run_engine >"\$TMP\/promote\.log" 2>&1$/ { next }
  { print }' "$SC" > "$TMP/sc_mut19"
cmp -s "$SC" "$TMP/sc_mut19" \
  && bad "⑲ MUTATION no-op : le mutant est identique — l'ancre a bougé, rien n'est éprouvé" \
  || ok "⑲ le mutant diffère RÉELLEMENT de l'original (anti-no-op cmp)"
bash -n "$TMP/sc_mut19" 2>"$TMP/mut19.err" \
  && ok "⑲ le mutant PARSE toujours (le rouge qui suit vient de l'ORDRE, pas d'une coquille de sed)" \
  || bad "⑲ le mutant ne parse plus : $(cat "$TMP/mut19.err")"
nc_strict "$TMP/sc_mut19" > "$TMP/sc_mut19_nc"
V19="$(ordre_verdict "$TMP/sc_mut19_nc")"
# ⚠ « ROUGE » NE SUFFIT PAS : IL FAUT LE BON ROUGE (revue F3). Un glob
# `KO*PALIER_FERME*` matcherait aussi bien « ordre violé » que « garde ABSENTE »
# — et ce cas-là est produit par un tout autre défaut (une garde supprimée),
# pas par la mutation d'ordre qu'on vient de poser. Mesuré : sous un sabotage
# qui NEUTRALISE la garde, l'ancien glob passait au vert et prétendait avoir
# prouvé l'ordre. On discrimine donc sur « APRÈS l'appel ».
case "$V19" in
  "KO: PALIER_FERME en ligne "*"APRÈS l'appel du moteur"*)
    ok "⑲ ④ ROUGIT sur le mutant pour la BONNE raison — ordre violé, garde nommée : ${V19}" ;;
  *absente*)
    bad "⑲ ④ rougit sur une garde ABSENTE, pas sur un ordre violé — la mutation d'ordre n'est pas ce qui a été mesuré : ${V19}" ;;
  OK)
    bad "⑲ ④ reste VERT sur un script où le moteur tourne avant PALIER_FERME — l'épreuve d'ordre est VACANTE" ;;
  *)
    bad "⑲ ④ rougit, mais pas sur la garde attendue : ${V19}" ;;
esac
# ET L'ARBRE N'A PAS BOUGÉ : la mutation vivait dans $TMP, l'original est intact.
[ "$(ordre_verdict "$SC_NC")" = OK ] \
  && ok "⑲ l'ORIGINAL est intact et toujours vert (la mutation n'a jamais touché l'arbre)" \
  || bad "⑲ l'original ne passe plus l'épreuve d'ordre — la mutation a fui hors de \$TMP"

# ── Garde-fou : verdicts rendus == cas attendus ─────────────────────────────
# Compte EXACT mesuré par un run complet, jamais déduit de tête. Si une section
# tombe en silence (branche jamais évaluée, script tronqué, cas sauté), ce
# nombre bouge et CE garde-fou rougit : un vert sur un sous-ensemble ne peut
# plus se faire passer pour le vert complet.
EXPECTED_ASSERTIONS=89
TOTAL_BEFORE_GUARD=$((PASS+FAIL))
echo
[ "$TOTAL_BEFORE_GUARD" -eq "$EXPECTED_ASSERTIONS" ] \
  && ok "verdicts rendus ($TOTAL_BEFORE_GUARD) == cas attendus ($EXPECTED_ASSERTIONS)" \
  || bad "verdicts rendus ($TOTAL_BEFORE_GUARD) != cas attendus ($EXPECTED_ASSERTIONS) — épreuve altérée ou tronquée"

printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
