#!/usr/bin/env bash
# test-team-publish-wiring.sh — preuve X/X du CÂBLAGE du job team-publish.
# Analyse statique du XML : ni Jenkins, ni Gitea. Motif copié de
# test-team-apply-wiring.sh (palier 2), étendu pour WEBHOOK_REPO (autorité par
# topologie) et le finally D'ENTRÉE (dette I3 du palier 2, réglée ici).
#
# FIX ROUND 1 (panel, §F) : durcissement anti « vert vacant ». Les greps NUS
# (motif présent n'importe où, y compris dans un COMMENTAIRE Groovy/bash qui
# nomme la chose sans jamais l'appeler) ont été remplacés par des ancres sur
# le CODE réel — soit une syntaxe d'invocation précise (`fail "TOKEN :`,
# `bash scripts/...`), soit une exclusion explicite des lignes de commentaire.
# Chaque assertion durcie a été prouvée capable de VIRER AU ROUGE par mutation
# réelle (casser → rouge → restaurer → vert), preuve tenue au rapport de
# tâche, pas ici (ce fichier reste un test STATIQUE, pas la contre-épreuve).
#
#   ./scripts/test-team-publish-wiring.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOB="$REPO/ci/jenkins/team-publish.job.xml"
JOB_APPLY="$REPO/ci/jenkins/team-apply.job.xml"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# [Important, panel §F point 5] Total ATTENDU, ÉCRIT EN DUR — indépendant de
# PASS+FAIL (qui devient vrai par construction, quel que soit le nombre de
# contrôles réellement exécutés : une section entière sautée silencieusement
# ferait baisser le total affiché SANS jamais faire échouer ce script). Toute
# section ajoutée/retirée DOIT mettre à jour ce nombre à la main — un oubli
# fait virer le §23 au rouge, ce qui EST le comportement voulu (un rappel,
# pas un bug).
EXPECTED_CHECKS=74

[ -f "$JOB" ] || { echo "job introuvable : $JOB"; exit 2; }

echo "== 1. le XML reste bien formé =="
python3 -c "import xml.etree.ElementTree as T; T.parse('$JOB')" 2>/dev/null \
  && ok "parsable" || ko "XML cassé"

echo
echo "== 2. le webhook capte le DÉPÔT déclencheur, QUI a validé, QUI a demandé, et le SHA de merge =="
grep -q '<key>WEBHOOK_REPO</key><value>\$.repository.full_name</value>' "$JOB" \
  && ok "WEBHOOK_REPO mappé sur repository.full_name (autorité par topologie)" \
  || ko "WEBHOOK_REPO absent ou mal mappé — team-publish.sh ne pourrait pas dériver l'équipe"
grep -q 'pull_request.merged_by.login' "$JOB" \
  && ok "merged_by.login capté" || ko "merged_by absent — la garde ne pourrait rien vérifier"
grep -q 'pull_request.user.login' "$JOB" \
  && ok "user.login capté (quatre yeux)" || ko "requester absent"
grep -q '<key>MERGE_SHA</key><value>\$.pull_request.merge_commit_sha</value>' "$JOB" \
  && ok "MERGE_SHA mappé sur merge_commit_sha" || ko "MERGE_SHA absent ou mal mappé — team-publish.sh l'exige (anti-TOCTOU)"

echo
echo "== 3. le filtre GWT est exact (fusion, pas juste fermeture) =="
grep -q '<regexpFilterText>\$PR_ACTION|\$PR_MERGED</regexpFilterText>' "$JOB" \
  && ok "filterText = \$PR_ACTION|\$PR_MERGED" || ko "filterText inattendu"
grep -q '<regexpFilterExpression>\^closed\\|true\$</regexpFilterExpression>' "$JOB" \
  && ok "filterExpression = ^closed\\|true\$" || ko "filterExpression inattendue — laisserait passer une fermeture SANS merge"

echo
echo "== 4. la branche est gardée à api/* =="
grep -q "ref.startsWith('api/')" "$JOB" \
  && ok "garde de branche api/* présente" || ko "garde de branche absente — appliquerait sur n'importe quelle PR fermée d'un dépôt d'équipe"

echo
echo "== 5. la garde d'identité est réellement appelée, AVANT team-publish.sh =="
grep -q 'assert-merge-identity.sh' "$JOB" \
  && ok "assert-merge-identity.sh invoquée" || ko "garde non appelée"
for a in --merged-by --requester --vault-user; do
  grep -q -- "$a" "$JOB" && ok "argument $a passé" || ko "argument $a manquant"
done
L_GUARD=$(grep -n 'assert-merge-identity.sh' "$JOB" | head -1 | cut -d: -f1)
L_APPLY=$(grep -n 'bash scripts/team-publish\.sh' "$JOB" | head -1 | cut -d: -f1)
if [ -n "$L_GUARD" ] && [ -n "$L_APPLY" ] && [ "$L_GUARD" -lt "$L_APPLY" ]; then
  ok "garde ligne $L_GUARD, apply ligne $L_APPLY"
else
  ko "garde APRÈS l'apply (ou introuvable) : garde=$L_GUARD apply=$L_APPLY"
fi

echo
echo "== 6. team-publish.sh est bien invoqué =="
grep -q 'bash scripts/team-publish\.sh' "$JOB" \
  && ok "scripts/team-publish.sh invoqué" || ko "team-publish.sh non invoqué — job mort"

echo
echo "== 7. pas d'injection : les valeurs passent par l'ENVIRONNEMENT ==="
grep -q "withEnv(\[\"G_MERGED_BY=" "$JOB" \
  && ok "identité du valideur exportée via withEnv" || ko "G_MERGED_BY non passé par l'environnement"
grep -q "withEnv(\[\"V_USER=" "$JOB" \
  && ok "VAULT_USER exporté via withEnv" || ko "V_USER non passé par l'environnement"
grep -q '"V_PASS=\${creds\.VAULT_USER_PASSWORD' "$JOB" \
  && ok "VAULT_USER_PASSWORD exporté via withEnv (jamais interpolé dans la chaîne sh)" \
  || ko "V_PASS non passé par l'environnement — le mot de passe risque une interpolation Groovy directe"
if grep 'assert-merge-identity.sh' "$JOB" | grep -q '\${'; then
  ko "interpolation Groovy dans la commande sh de la garde — injection possible"
else
  ok "aucune interpolation Groovy dans la commande sh de la garde"
fi
grep 'assert-merge-identity.sh' "$JOB" | grep -q "^ *sh '" \
  && ok "chaîne sh de la garde en quotes simples" || ko "chaîne sh de la garde en quotes doubles (Groovy interpolerait)"
if grep -A3 "sh '''" "$JOB" | grep -q '\${V_PASS}\|\${V_USER}'; then
  ko "V_PASS/V_USER référencés en syntaxe Groovy (\${...}) dans le bloc sh — vérifier l'absence d'interpolation"
else
  ok "bloc login+apply en triple quotes simples, variables lues par le shell (\$VAR), pas par Groovy"
fi

echo
echo "== 8. le mot de passe ne transite jamais par argv (login sourcé, pas exec direct) =="
grep -q '\. ci/lib/vault-login\.sh' "$JOB" \
  && ok "ci/lib/vault-login.sh sourcé (motif établi, jamais un appel direct qui mettrait le mot de passe en argv)" \
  || ko "vault-login.sh non sourcé — vérifier comment le login est fait"
grep -q 'trap vault_trap_revoke EXIT' "$JOB" \
  && ok "révocation du token armée (trap EXIT) avant tout appel réseau" \
  || ko "aucun trap de révocation — le token nominatif pourrait survivre au build"

echo
echo "== 9. login et l'appel à team-publish.sh se suivent TEXTUELLEMENT dans le job (login précède l'appel) =="
# [Important, panel §F point « §9 »] Renommé depuis « même bloc sh » : le job
# contient DEUX blocs \`sh '''...'''\` distincts (login+apply, PUIS le
# commentaire de secours du finally) — un \`awk\` qui repère « vault-login.sh
# AVANT team-publish.sh quelque part dans le texte » ne prouve PAS le
# bornage de bloc réel (une preuve de bornage serait une machinerie de plus,
# elle-même faillible ; le panel autorise explicitement ce renommage en
# alternative). Les motifs sont ANCRÉS sur la syntaxe RÉELLE d'invocation
# (\`. ci/lib/vault-login.sh\`, \`bash scripts/team-publish.sh\`), pas une
# mention en prose, pour ne pas matcher un simple commentaire qui NOMME l'un
# ou l'autre sans jamais les appeler.
if awk '/\. ci\/lib\/vault-login\.sh/{f=1} f&&/bash scripts\/team-publish\.sh/{print "same"; exit}' "$JOB" | grep -q same; then
  ok "vault-login.sh (source réelle) précède textuellement l'appel réel à team-publish.sh"
else
  ko "vault-login.sh et l'appel réel à team-publish.sh ne se suivent pas dans cet ordre — le trap de révocation pourrait tuer le token avant l'apply"
fi

echo
echo "== 10. la garde et team-publish.sh appelés existent et sont exécutables =="
[ -f "$REPO/scripts/lib/assert-merge-identity.sh" ] \
  && ok "scripts/lib/assert-merge-identity.sh présent" || ko "script absent — appel mort"
sh -n "$REPO/scripts/lib/assert-merge-identity.sh" 2>/dev/null \
  && ok "assert-merge-identity.sh : syntaxe shell valide" || ko "assert-merge-identity.sh non parsable"
[ -f "$REPO/scripts/team-publish.sh" ] \
  && ok "scripts/team-publish.sh présent" || ko "team-publish.sh absent — appel mort"
bash -n "$REPO/scripts/team-publish.sh" 2>/dev/null \
  && ok "team-publish.sh : syntaxe shell valide" || ko "team-publish.sh non parsable"
[ -f "$REPO/ci/lib/vault-login.sh" ] \
  && ok "ci/lib/vault-login.sh présent" || ko "vault-login.sh absent — appel mort"
[ -f "$REPO/scripts/lib/gitea-pr-comment.sh" ] \
  && ok "scripts/lib/gitea-pr-comment.sh présent" || ko "gitea-pr-comment.sh absent — le commentaire idempotent est mort"
bash -n "$REPO/scripts/lib/gitea-pr-comment.sh" 2>/dev/null \
  && ok "gitea-pr-comment.sh : syntaxe shell valide" || ko "gitea-pr-comment.sh non parsable"

echo
echo "== 11. le job est bien posé par setup-team-onboard-jobs.sh =="
grep -q 'team-publish' "$REPO/scripts/setup-team-onboard-jobs.sh" \
  && ok "team-publish listé dans JOBS de setup-team-onboard-jobs.sh" || ko "team-publish absent de JOBS"

echo
echo "== 12. VAULT_USER_AUTH_MOUNT, APIM_API_BASE et JENKINS_UI exportés dans le bloc sh — présence ET valeur =="
# ANCRÉ sur la ligne \`export VAR=\`, PAS un grep nu (leçon du palier 2, Task 8,
# deux rounds pour la trouver en réel : un grep -q 'VAULT_USER_AUTH_MOUNT' nu
# matche AUSSI les COMMENTAIRES qui nomment la variable — filet « vert vacant »
# sinon). L'ancre \`^ *export VAR=\` ne matche QUE l'export réel.
grep -qE '^ *export VAULT_USER_AUTH_MOUNT=' "$JOB" \
  && ok "VAULT_USER_AUTH_MOUNT exporté (sinon : login retombe sur le défaut ldap de la lib)" \
  || ko "VAULT_USER_AUTH_MOUNT absent — régression connue (palier 2, Task 8)"
grep -qE '^ *export APIM_API_BASE=' "$JOB" \
  && ok "APIM_API_BASE exporté (cible gateway explicite requise)" \
  || ko "APIM_API_BASE absent — team-publish.sh refuse de démarrer sans lui (\${APIM_API_BASE:?...})"
# JENKINS_UI : fix mesuré (Task 7) — "localhost" depuis le conteneur du job ne
# désigne PAS Jenkins ; sans cet export, la re-pose d'app-request échoue
# systématiquement en job réel (curl "000"), jamais vu en test depuis un poste.
grep -qE '^ *export JENKINS_UI=' "$JOB" \
  && ok "JENKINS_UI exporté vers l'alias in-cluster (sinon : re-pose injoignable en job réel)" \
  || ko "JENKINS_UI absent — la re-pose d'app-request échouera systématiquement une fois joué en job (défaut localhost:18080 invalide depuis le conteneur)"
# [Important, panel §F point « §12 »] La PRÉSENCE d'un export ne dit rien de
# SA VALEUR — \`export JENKINS_UI=""\` passerait les trois contrôles
# précédents sans jamais donner le bon alias in-cluster. Comparaison LITTÉRALE
# de la ligne entière (motif fixe, grep -F).
grep -qF 'export VAULT_USER_AUTH_MOUNT="${VAULT_USER_AUTH_MOUNT:-userpass}"' "$JOB" \
  && ok "valeur littérale de VAULT_USER_AUTH_MOUNT = userpass (défaut nominatif du lab)" \
  || ko "VAULT_USER_AUTH_MOUNT : valeur par défaut inattendue ou absente (export présent mais valeur non conforme)"
grep -qF 'export APIM_API_BASE="${APIM_API_BASE:-http://webmethods-mock:8080/rest/apigateway}"' "$JOB" \
  && ok "valeur littérale de APIM_API_BASE = mock in-cluster (jamais 5555)" \
  || ko "APIM_API_BASE : valeur par défaut inattendue ou absente (export présent mais valeur non conforme)"
grep -qF 'export JENKINS_UI="${JENKINS_UI:-http://jenkins:8080}"' "$JOB" \
  && ok "valeur littérale de JENKINS_UI = http://jenkins:8080 (avant : seule la présence de l'export était vérifiée)" \
  || ko "JENKINS_UI : valeur par défaut inattendue ou absente (export présent mais valeur non conforme)"

echo
echo "== 13. le finally est pris D'ENTRÉE (dette I3 du palier 2) — et son marqueur est DISTINCT de celui du script (fix C, panel) =="
# LE point que team-apply.job.xml/provision-apply.job.xml manquent (I3) : leur
# try/finally n'entoure QUE l'apply, jamais la garde d'identité — un refus de
# garde n'y laisse donc AUCUNE trace sur la PR. Ici le \`try {\` doit apparaître
# AVANT la garde, pas seulement avant l'apply.
L_TRY=$(grep -n '^try {' "$JOB" | head -1 | cut -d: -f1)
L_GUARD2=$(grep -n "stage('garde identite du valideur')" "$JOB" | head -1 | cut -d: -f1)
L_FINALLY=$(grep -n '^} finally {' "$JOB" | head -1 | cut -d: -f1)
if [ -n "$L_TRY" ] && [ -n "$L_GUARD2" ] && [ "$L_TRY" -lt "$L_GUARD2" ]; then
  ok "try (ligne $L_TRY) commence AVANT la garde d'identité (ligne $L_GUARD2) — un refus de garde EST couvert"
else
  ko "try absent ou APRÈS la garde d'identité (try=$L_TRY garde=$L_GUARD2) — un refus de garde ne serait PAS commenté (dette I3 reproduite)"
fi
[ -n "$L_FINALLY" ] && ok "bloc finally présent (ligne $L_FINALLY)" || ko "aucun bloc finally — rien ne commente un échec"
# [Important, panel §F] Le CODE du finally, comments Groovy (//) exclus — pour
# ne plus confondre une mention en PROSE ("... gitea-pr-comment.sh ...", que le
# fix C a lui-même ajoutée en commentaire juste sous \`} finally {\`) avec
# l'INVOCATION réelle, plus bas dans le même bloc.
FINALLY_CODE=$(awk '/^} finally \{/{f=1} f{print} f&&/^}$/{exit}' "$JOB" | grep -vE '^[[:space:]]*//')
if [ -n "$L_FINALLY" ] && printf '%s\n' "$FINALLY_CODE" | grep -q 'bash scripts/lib/gitea-pr-comment\.sh'; then
  ok "le finally poste bien un commentaire sur la PR (appel RÉEL à gitea-pr-comment.sh, commentaires Groovy exclus)"
else
  ko "le finally ne contient aucun appel RÉEL à gitea-pr-comment.sh (une mention en commentaire Groovy ne suffit pas)"
fi
# Marqueur : comparaison LITTÉRALE (pas juste la présence de \`--&gt;\`, qui
# matchait N'IMPORTE QUEL commentaire XML clos) — et DISTINCTION du marqueur
# du script (avant le fix C, les deux commentaires PARTAGEAIENT le même
# marqueur : le finally écrasait, via PATCH, la cause nommée que team-
# publish.sh venait de poster).
SCRIPT_MARKER=$(grep -oE "TEAM_PUBLISH_MARKER='[^']*'" "$REPO/scripts/team-publish.sh" | sed -E "s/^TEAM_PUBLISH_MARKER='//; s/'\$//")
SCRIPT_MARKER_ESC=$(printf '%s' "$SCRIPT_MARKER" | sed 's/</\&lt;/g; s/>/\&gt;/g')
FINALLY_MARKER_ESC=$(printf '%s\n' "$FINALLY_CODE" | grep -oE 'COMMENT_MARKER="[^"]*"' | head -1 | sed -E 's/^COMMENT_MARKER="//; s/"$//')
EXPECTED_FINALLY_MARKER_ESC='&lt;!-- team-publish-build --&gt;'
if [ "$FINALLY_MARKER_ESC" = "$EXPECTED_FINALLY_MARKER_ESC" ]; then
  ok "marqueur du finally = littéralement ${EXPECTED_FINALLY_MARKER_ESC}"
else
  ko "marqueur du finally inattendu : '${FINALLY_MARKER_ESC}' (attendu '${EXPECTED_FINALLY_MARKER_ESC}')"
fi
if [ -n "$FINALLY_MARKER_ESC" ] && [ "$FINALLY_MARKER_ESC" != "$SCRIPT_MARKER_ESC" ]; then
  ok "marqueur du finally (${FINALLY_MARKER_ESC}) DISTINCT du marqueur du script (${SCRIPT_MARKER_ESC}) — plus d'écrasement croisé"
else
  ko "marqueur du finally identique à celui du script ('${FINALLY_MARKER_ESC}') — un échec IN-SCRIPT verrait sa cause nommée écrasée par le statut générique du finally (fix C non tenu)"
fi
# Le commentaire de secours du finally doit cibler WEBHOOK_REPO (le dépôt de
# l'ÉQUIPE), jamais GIT_REPO (le dépôt plateforme, sans rapport avec CETTE PR).
if [ -n "$L_FINALLY" ] && printf '%s\n' "$FINALLY_CODE" | grep -q 'WEBHOOK_REPO='; then
  ok "le commentaire de secours cible WEBHOOK_REPO (le dépôt de l'équipe, pas la plateforme)"
else
  ko "le commentaire de secours ne référence pas WEBHOOK_REPO — risque de cibler le mauvais dépôt"
fi

echo
echo "== 14. les gardes d'intégrité de team-publish.sh sont réellement câblées =="
# Statique (grep), pas fonctionnel — le comportement rouge/vert de chacune est
# prouvé par contre-épreuve à l'exécution (rapport de tâche), pas ici.
# [Important, panel §F] Ancré sur \`fail "TOKEN :\` (l'invocation RÉELLE), pas
# sur le token nu : REPO_AMBIGU/CONTRAT_ABSENT apparaissent AUSSI dans des
# commentaires qui les NOMMENT sans jamais appeler fail() — un grep nu passait
# tout autant si la garde était retirée mais son commentaire laissé en place.
grep -q 'merge-base --is-ancestor' "$REPO/scripts/team-publish.sh" \
  && ok "garde d'atteignabilité merge-base --is-ancestor présente (MERGE_SHA doit être un ANCÊTRE de main, pas juste un objet existant)" \
  || ko "aucune garde d'atteignabilité — un SHA valide mais non fusionné sur main serait accepté"
grep -qF 'fail "REPO_AMBIGU :' "$REPO/scripts/team-publish.sh" \
  && ok "REPO_AMBIGU réellement appelé (fail nommé, pas juste mentionné en commentaire)" \
  || ko "REPO_AMBIGU absent de tout fail() réel — un dépôt déclaré deux fois choisirait la première équipe rencontrée en silence"
grep -qF 'fail "CONTRAT_ABSENT :' "$REPO/scripts/team-publish.sh" \
  && ok "CONTRAT_ABSENT réellement appelé (fail nommé, pas juste mentionné en commentaire)" \
  || ko "CONTRAT_ABSENT absent de tout fail() réel — un contrat manquant échouerait loin de sa cause réelle"
# Validation de FORME (leçon \Z du palier 1 : refus de CLASSE avant tout argv
# git/curl) — WEBHOOK_REPO, MERGE_SHA et PR_NUMBER viennent d'un webhook (un tiers).
grep -qF 'fail "WEBHOOK_REPO_INVALIDE :' "$REPO/scripts/team-publish.sh" \
  && ok "WEBHOOK_REPO validé en forme AVANT tout argv git/curl" \
  || ko "WEBHOOK_REPO jamais validé en forme — une valeur de webhook mal formée atteindrait argv sans avoir été regardée"
grep -qF 'fail "MERGE_SHA_INVALIDE :' "$REPO/scripts/team-publish.sh" \
  && ok "MERGE_SHA validé en forme (40 hex) AVANT tout argv git" \
  || ko "MERGE_SHA jamais validé en forme"
grep -qF 'fail "PR_NUMBER_INVALIDE :' "$REPO/scripts/team-publish.sh" \
  && ok "PR_NUMBER validé en forme (entier positif) AVANT de servir de segment d'URL API Gitea (§réconciliation, §commentaires)" \
  || ko "PR_NUMBER jamais validé en forme — folded minor du panel non tenu"
grep -qF 'fail "API_NAME_INVALIDE :' "$REPO/scripts/team-publish.sh" \
  && ok "API_NAME (dérivé de la branche) validé en forme — devient un segment de CHEMIN (apis/<name>.publish.yml)" \
  || ko "API_NAME jamais validé en forme — évasion de chemin possible via une branche malformée"
# Ordre : le refus de CLASSE (case) doit précéder le refus de FORME complète
# (grep ancré), même discipline que resolve.yml (palier 1) — sinon un \n final
# passerait le grep ancré (piège \Z déjà documenté ailleurs dans ce dépôt).
L_CASE=$(grep -n '\*\[!a-z0-9-\]\*' "$REPO/scripts/team-publish.sh" | head -1 | cut -d: -f1)
L_GREPQ=$(grep -n "API_NAME_INVALIDE" "$REPO/scripts/team-publish.sh" | tail -1 | cut -d: -f1)
if [ -n "$L_CASE" ] && [ -n "$L_GREPQ" ] && [ "$L_CASE" -lt "$L_GREPQ" ]; then
  ok "le refus de classe (case, ligne $L_CASE) précède le refus de forme complète (ligne $L_GREPQ) pour API_NAME"
else
  ko "ordre case/grep pour API_NAME non confirmé (case=$L_CASE forme=$L_GREPQ)"
fi

echo
echo "== 15. la réconciliation Gitea est réellement câblée (fix B, panel) — le payload webhook n'est jamais la vérité seule =="
grep -qF 'fail "GITEA_RECONCILE_ECHEC :' "$REPO/scripts/team-publish.sh" \
  && ok "GITEA_RECONCILE_ECHEC présent (échec de lecture Gitea = refus, jamais un continue silencieux)" \
  || ko "GITEA_RECONCILE_ECHEC absent — un échec de lecture Gitea ne serait pas nommé"
grep -qF 'fail "PAYLOAD_PERIME :' "$REPO/scripts/team-publish.sh" \
  && ok "PAYLOAD_PERIME présent (divergence webhook/Gitea = refus)" \
  || ko "PAYLOAD_PERIME absent — un payload rejoué/périmé ne serait pas détecté"
grep -qF 'd.get("merged") is True' "$REPO/scripts/team-publish.sh" \
  && ok "merged relu chez Gitea (pas déduit du payload)" || ko "merged non revérifié chez Gitea"
grep -qF 'd.get("merge_commit_sha") == os.environ["MERGE_SHA"]' "$REPO/scripts/team-publish.sh" \
  && ok "merge_commit_sha comparé au MERGE_SHA du webhook" || ko "merge_commit_sha non comparé"
grep -qF '.get("ref") == os.environ["PR_BRANCH"]' "$REPO/scripts/team-publish.sh" \
  && ok "head.ref comparé à PR_BRANCH du webhook" || ko "head.ref non comparé"
grep -qF '.get("ref") == "main"' "$REPO/scripts/team-publish.sh" \
  && ok "base.ref comparé à main" || ko "base.ref non comparé"

echo
echo "== 16. contract (liste blanche EXACTE) + MANIFEST_UNSAFE (scan du reste) — le gabarit LÉGITIME porte lui-même un Jinja (CRITICAL, panel) =="
# [CRITICAL, panel — corrigé après contre-épreuve réelle] La toute première
# version de ce scan (grep Jinja nu sur TOUT le manifeste) aurait refusé
# jusqu'au gabarit LÉGITIME lui-même (gateways/templates/publish.yml.tmpl,
# posé par api-request.sh), dont le champ contract PORTE un Jinja voulu.
# Trouvé en rejouant une VRAIE contre-épreuve contre le gabarit réel (pas un
# exemple inventé) — d'où la liste blanche EXACTE ci-dessous, remplaçant le
# grep nu.
grep -qF 'fail "MANIFEST_CONTRACT_INVALIDE :' "$REPO/scripts/team-publish.sh" \
  && ok "MANIFEST_CONTRACT_INVALIDE réellement appelé (fail nommé) — refuse tout contract qui diverge du gabarit, Jinja injecté OU chemin absolu" \
  || ko "MANIFEST_CONTRACT_INVALIDE absent de tout fail() réel"
grep -qF 'fail "MANIFEST_UNSAFE :' "$REPO/scripts/team-publish.sh" \
  && ok "MANIFEST_UNSAFE réellement appelé (fail nommé)" || ko "MANIFEST_UNSAFE absent de tout fail() réel"
grep -qF 'a.pop("contract", None)' "$REPO/scripts/team-publish.sh" \
  && ok "le scan MANIFEST_UNSAFE EXCLUT réellement le champ contract (sinon : le gabarit légitime échouerait toujours ici, contre-épreuve du panel)" \
  || ko "aucune exclusion réelle de contract trouvée dans le scan — MANIFEST_UNSAFE pourrait refuser tout manifeste légitime"
grep -qF 'EXPECTED_CONTRACT="{{ (pub_manifest_path | dirname) }}/${API_NAME}.openapi.yaml"' "$REPO/scripts/team-publish.sh" \
  && ok "la liste blanche cible EXACTEMENT le gabarit paramétré par API_NAME (pas une chaîne inventée qui pourrait déjà avoir divergé)" \
  || ko "EXPECTED_CONTRACT absent ou construit différemment — la liste blanche pourrait avoir dérivé du vrai gabarit"
# Contre-épreuve anti-dérive : le PRÉFIXE Jinja de EXPECTED_CONTRACT doit
# être EXACTEMENT celui du VRAI gabarit (gateways/templates/publish.yml.tmpl)
# — une preuve croisée entre les deux fichiers, pas une simple relecture du
# même fichier.
TMPL="$REPO/gateways/templates/publish.yml.tmpl"
if [ -f "$TMPL" ]; then
  TMPL_CONTRACT_LINE=$(grep -E '^\s*contract:' "$TMPL" | head -1)
  case "$TMPL_CONTRACT_LINE" in
    *'{{ (pub_manifest_path | dirname) }}'*)
      ok "le préfixe Jinja de la liste blanche correspond au VRAI gabarit (gateways/templates/publish.yml.tmpl)" ;;
    *)
      ko "le gabarit réel ne porte plus '{{ (pub_manifest_path | dirname) }}' dans son champ contract — la liste blanche de team-publish.sh a dérivé (ligne lue : '${TMPL_CONTRACT_LINE}')" ;;
  esac
else
  ko "gateways/templates/publish.yml.tmpl introuvable — impossible de prouver l'absence de dérive"
fi
L_CONTRACT_CHECK=$(grep -n 'fail "MANIFEST_CONTRACT_INVALIDE :' "$REPO/scripts/team-publish.sh" | head -1 | cut -d: -f1)
L_SCAN=$(grep -n 'fail "MANIFEST_UNSAFE :' "$REPO/scripts/team-publish.sh" | head -1 | cut -d: -f1)
L_ANSIBLE=$(grep -n 'ansible-playbook -i' "$REPO/scripts/team-publish.sh" | head -1 | cut -d: -f1)
if [ -n "$L_CONTRACT_CHECK" ] && [ -n "$L_ANSIBLE" ] && [ "$L_CONTRACT_CHECK" -lt "$L_ANSIBLE" ]; then
  ok "la liste blanche contract a lieu AVANT l'invocation du rôle Ansible (ligne $L_CONTRACT_CHECK puis $L_ANSIBLE)"
else
  ko "ordre contract/apply non confirmé (contract=$L_CONTRACT_CHECK apply=$L_ANSIBLE) — le manifeste pourrait être appliqué avant d'être vérifié"
fi
if [ -n "$L_SCAN" ] && [ -n "$L_ANSIBLE" ] && [ "$L_SCAN" -lt "$L_ANSIBLE" ]; then
  ok "le scan MANIFEST_UNSAFE a lieu AVANT l'invocation du rôle Ansible (ligne $L_SCAN puis $L_ANSIBLE)"
else
  ko "ordre scan/apply non confirmé (scan=$L_SCAN apply=$L_ANSIBLE) — le manifeste pourrait être appliqué avant d'être scanné"
fi

echo
echo "== 17. apim_ss_contract_pin épingle le contract (CRITICAL, panel) — câblé côté script ET côté rôle, dans le bon ordre =="
grep -qF -- '-e apim_ss_contract_pin="$SPEC_PATH"' "$REPO/scripts/team-publish.sh" \
  && ok "team-publish.sh passe apim_ss_contract_pin=SPEC_PATH (le chemin déjà VÉRIFIÉ, jamais celui du manifeste) en extra-var" \
  || ko "apim_ss_contract_pin non passé par team-publish.sh — le manifeste resterait maître du contract"
RESOLVE_ENV="$REPO/ansible/roles/apim_publish_api/tasks/resolve-env.yml"
[ -f "$RESOLVE_ENV" ] && grep -qF "apim_api | combine({'contract': apim_ss_contract_pin})" "$RESOLVE_ENV" \
  && ok "le rôle applique réellement le pin (set_fact combine sur contract, pas juste une variable declarée dans defaults/main.yml sans jamais être lue)" \
  || ko "aucune application réelle du pin côté rôle — la variable pourrait n'être qu'un defaults mort"
L_PEREN=$(grep -n 'apim_api_base_m | combine(apim_api_over_m' "$RESOLVE_ENV" 2>/dev/null | head -1 | cut -d: -f1)
L_PIN=$(grep -n "apim_api | combine({'contract': apim_ss_contract_pin})" "$RESOLVE_ENV" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$L_PEREN" ] && [ -n "$L_PIN" ] && [ "$L_PEREN" -lt "$L_PIN" ]; then
  ok "le pin est posé APRÈS la fusion per_env (ligne ${L_PEREN} puis ${L_PIN}) — un contract caché sous per_env.<env>.contract ne peut pas contourner le pin"
else
  ko "ordre pin/per_env non confirmé (per_env=${L_PEREN} pin=${L_PIN}) — un contract sous per_env pourrait écraser le pin"
fi

echo
echo "== 18. V_PASS ne survit pas dans l'environnement du step sh, dans LES DEUX jobs (fix D, panel) =="
L_EXPORT_PUB=$(grep -n 'export VAULT_USER_PASSWORD="\$V_PASS"' "$JOB" | head -1 | cut -d: -f1)
L_UNSET_PUB=$(grep -n '^ *unset V_PASS$' "$JOB" | head -1 | cut -d: -f1)
if [ -n "$L_EXPORT_PUB" ] && [ -n "$L_UNSET_PUB" ] && [ "$L_EXPORT_PUB" -lt "$L_UNSET_PUB" ]; then
  ok "team-publish.job.xml : unset V_PASS après l'export (ligne ${L_EXPORT_PUB} puis ${L_UNSET_PUB})"
else
  ko "team-publish.job.xml : unset V_PASS absent ou avant l'export (export=${L_EXPORT_PUB} unset=${L_UNSET_PUB}) — le mot de passe resterait lisible dans /proc/PID/environ"
fi
if [ -f "$JOB_APPLY" ]; then
  L_EXPORT_APL=$(grep -n 'export VAULT_USER_PASSWORD="\$V_PASS"' "$JOB_APPLY" | head -1 | cut -d: -f1)
  L_UNSET_APL=$(grep -n '^ *unset V_PASS$' "$JOB_APPLY" | head -1 | cut -d: -f1)
  if [ -n "$L_EXPORT_APL" ] && [ -n "$L_UNSET_APL" ] && [ "$L_EXPORT_APL" -lt "$L_UNSET_APL" ]; then
    ok "team-apply.job.xml : unset V_PASS après l'export (ligne ${L_EXPORT_APL} puis ${L_UNSET_APL}) — même correction, miroir"
  else
    ko "team-apply.job.xml : unset V_PASS absent ou avant l'export (export=${L_EXPORT_APL} unset=${L_UNSET_APL})"
  fi
else
  ko "team-apply.job.xml introuvable — impossible de vérifier le miroir de la correction D"
fi

echo
echo "== 19. la re-pose après succès couvre app-request ET api-request (fix E, panel) =="
grep -qF 'JOBS="app-request api-request"' "$REPO/scripts/team-publish.sh" \
  && ok "JOBS=\"app-request api-request\" — la liste API_BASE d'api-request est aussi rafraîchie (sinon : stale après chaque publication)" \
  || ko "JOBS ne couvre pas api-request — sa liste API_BASE resterait périmée après chaque publication"

echo
echo "== 20. le secret HMAC est proposé à l'enregistrement du hook (fix B, panel — limite documentée : non vérifiable côté GWT 2.4.2, cf. rapport) =="
grep -qF "cfg['secret'] = secret" "$REPO/scripts/team-apply.sh" \
  && ok "le hook Gitea peut porter un secret HMAC (TEAM_PUBLISH_WEBHOOK_SECRET, si fourni) — Gitea signe alors ses envois" \
  || ko "aucun mécanisme de secret dans l'enregistrement du hook"

echo
echo "== 21. les DEUX clones (dépôt plateforme ET dépôt d'équipe) sont authentifiés, pas seulement les push (folded minor, panel) =="
NONCOMMENT_GITCLONE=$(grep -vE '^\s*#' "$REPO/scripts/team-publish.sh" | grep -c 'git clone')
[ "$NONCOMMENT_GITCLONE" -eq 1 ] \
  && ok "un seul \`git clone\` brut dans le script, celui enveloppé par gclone() (aucun clone anonyme parallèle)" \
  || ko "nombre de \`git clone\` bruts inattendu (${NONCOMMENT_GITCLONE}, attendu 1 — celui interne à gclone())"
GCLONE_CALLS=$(grep -cE '^gclone ' "$REPO/scripts/team-publish.sh")
[ "$GCLONE_CALLS" -eq 2 ] \
  && ok "gclone (authentifiée) appelée exactement 2 fois — dépôt plateforme ET dépôt d'équipe" \
  || ko "gclone appelée ${GCLONE_CALLS} fois, attendu 2 — un clone pourrait être resté anonyme"

echo
echo "== 22. la pause (input) est DANS le try — un abandon est couvert par le finally (folded minor, panel) =="
L_INPUT=$(grep -n 'creds = input(' "$JOB" | head -1 | cut -d: -f1)
if [ -n "$L_TRY" ] && [ -n "$L_INPUT" ] && [ "$L_TRY" -lt "$L_INPUT" ]; then
  ok "try (ligne ${L_TRY}) commence AVANT la pause input() (ligne ${L_INPUT}) — un abandon/timeout EST couvert"
else
  ko "la pause input() n'est pas dans le try (try=${L_TRY} input=${L_INPUT}) — un abandon resterait muet sur la PR"
fi

echo
echo "== 23. le total de contrôles exécutés correspond au total ATTENDU, écrit en dur (fix F point 5, panel) =="
# Le \`RÉSULTAT : %d/%d\` final ci-dessous imprime PASS/(PASS+FAIL) — une
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
