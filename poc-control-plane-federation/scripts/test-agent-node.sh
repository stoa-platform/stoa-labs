#!/usr/bin/env bash
# scripts/test-agent-node.sh — L'AGENT DES `node` EXPLICITES (2026-09-18).
#
# LE DÉFAUT MESURÉ. Les cinq pipelines en `agent none` prenaient leurs nœuds
# explicites par `node("${env.POST_AGENT_LABEL ?: ''}")` : une globale sans
# catalogue, vide ⇒ n'importe quel agent. Chez un client Kubernetes dont le
# runner python+ansible est un pod DÉCLARÉ DANS LE JENKINSFILE (label généré par
# build), provision-plan #40 a posé son post{always} sur le pod `default` : ni
# python3 ni ansible, statut jamais posté, build vert. Sept sites portaient ce
# nœud, dont DEUX qui ne sont pas un statut : la porte et la garde d'identité
# de provision-apply, APRÈS la pause.
#
# CE QUE CETTE SUITE MESURE, sans Jenkins : le bloc Groovy LIVRÉ (extrait du
# Jenkinsfile, jamais retapé) est EXÉCUTÉ sous docker (groovy:4-jdk17) ; seuls
# les pas Jenkins sont bouchonnés — readTrusted, echo, error, env, podTemplate,
# node, container — et chaque bouchon ENREGISTRE l'appel reçu. On juge donc la
# SÉQUENCE d'appels que agentNode produirait, cas par cas, plus les refus.
#
#   A.   les cinq blocs sont identiques, plus aucun node( hors du helper
#   B.   la décision : rien / label / pod+conteneur / label+conteneur
#   C.   les refus, tous AU PARSE (avant la pause) et tous nommés
#   D.   l'environnement l'emporte sur config/site.ini
#   M.   mutations sur COPIE : chaque épreuve rougit sur le défaut qu'elle vise
#
# SKIP NOMMÉ si docker ou l'image manque — et la suite le DIT (rc 0, mais pas
# un vert : B/C/D/M ne sont alors pas mesurés).
# SC2015 : ok/ko rendent toujours 0, `A && ok || ko` n'exécute donc jamais les deux.
# SC2016 : les motifs Groovy/perl en quotes simples portent des `$` LITTÉRAUX.
# shellcheck disable=SC2015,SC2016
set -u

cd "$(dirname "$0")/.." || { echo "REFUS: racine du depot introuvable" >&2; exit 2; }
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
note() { printf '  ⚠️  %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FICHIERS="provision-plan provision-apply team-apply team-promote team-publish"
extraire() { awk '/^def SITE_WEBHOOK_KIND = /,/^pipeline \{/' "$1" | sed '$d'; }

echo "═══ A. les cinq copies, et la portée du helper ═══"
REF=""; DIFF=""
for f in $FICHIERS; do
  extraire "ci/Jenkinsfile.$f" > "$TMP/bloc.$f"
  [ -s "$TMP/bloc.$f" ] || { ko "A.1 bloc introuvable dans ci/Jenkinsfile.$f"; continue; }
  if [ -z "$REF" ]; then REF="$TMP/bloc.$f"; elif ! cmp -s "$REF" "$TMP/bloc.$f"; then DIFF="$DIFF $f"; fi
done
[ -z "$DIFF" ] && ok "A.1 le bloc site.ini + agentSpec/agentNode est IDENTIQUE octet pour octet dans les cinq pipelines" \
  || ko "A.1 copies divergentes :$DIFF"

# Portée DÉRIVÉE : tous les Jenkinsfile, pas une liste à la main. Un node( hors
# des trois lignes du helper serait un nœud qui échappe au choix d'agent.
HORS=$(grep -nE '\bnode *\(' ci/Jenkinsfile* | grep -vE '^[^:]+:[0-9]+: *//' \
         | grep -vE 'node\((POD_LABEL|AGENT_SPEC\.label)\)' || true)
[ -z "$HORS" ] && ok "A.2 aucun node( hors du helper dans les $(find ci -maxdepth 1 -name 'Jenkinsfile*' | wc -l | tr -d ' ') Jenkinsfile" \
  || ko "A.2 node( hors du helper : $HORS"
N_SITES=0
for f in $FICHIERS; do
  n=$(grep -E '^\s*agentNode \{' "ci/Jenkinsfile.$f" | grep -vcE '^\s*//')
  N_SITES=$((N_SITES+n))
  [ "$n" -ge 1 ] || ko "A.3 ci/Jenkinsfile.$f : aucun appel agentNode"
done
[ "$N_SITES" -eq 7 ] && ok "A.3 sept sites passent par agentNode (plan 1, apply 3, team-apply/promote/publish 1 chacun)" \
  || ko "A.3 $N_SITES sites agentNode, 7 attendus"
grep -F 'node("${env.POST_AGENT_LABEL' ci/Jenkinsfile* | grep -vqE '^[^:]+: *//' && ko "A.4 un node(POST_AGENT_LABEL ?: '') subsiste" \
  || ok "A.4 plus aucun node(\"\${env.POST_AGENT_LABEL ?: ''}\") — le label nu n'est plus un chemin à part"
MISS=""
for k in AGENT_POD_YAML_FILE AGENT_CONTAINER POST_AGENT_LABEL; do
  grep -qE "^#$k=" config/site.ini || MISS="$MISS $k"
done
[ -z "$MISS" ] && ok "A.5 les trois clés sont au catalogue de config/site.ini (commentées : aucune valeur active livrée)" \
  || ko "A.5 absentes du catalogue site.ini :$MISS"
grep -qE '^(AGENT_POD_YAML_FILE|AGENT_CONTAINER|POST_AGENT_LABEL)=' config/site.ini \
  && ko "A.6 une valeur d'agent ACTIVE est livrée dans config/site.ini" || ok "A.6 aucune valeur d'agent active dans la copie livrée de site.ini"

GROOVY_IMG="${AGENT_NODE_IMG:-groovy:4-jdk17}"
if ! command -v docker >/dev/null 2>&1; then
  note "B/C/D/M SAUTÉES : docker absent — la décision d'agent n'est pas mesurée sur ce poste"
  echo; echo "RÉSULTAT : $PASS/$((PASS+FAIL)) (B/C/D/M non mesurées)"; [ "$FAIL" -eq 0 ]; exit $?
elif ! docker image inspect "$GROOVY_IMG" >/dev/null 2>&1; then
  note "B/C/D/M SAUTÉES : image $GROOVY_IMG absente — \`docker pull $GROOVY_IMG\`"
  echo; echo "RÉSULTAT : $PASS/$((PASS+FAIL)) (B/C/D/M non mesurées)"; [ "$FAIL" -eq 0 ]; exit $?
fi

# ── le harnais : bouchons ENREGISTREURS + pilote qui joue chaque cas ─────────
M="$TMP/m"; mkdir -p "$M/hudson" "$M/cases" "$M/scripts"
printf '%s\n' 'package hudson' 'class AbortException extends Exception { AbortException(String m) { super(m) } }' \
  > "$M/hudson/AbortException.groovy"
cat > "$M/prelude.groovy" <<'GROOVY'
def readTrusted(String p) {
  def f = new File(CASE_DIR + '/repo/' + p)
  if (!f.exists()) { throw new hudson.AbortException('introuvable : ' + p) }
  return f.text
}
def echo(String m) { OUT << 'echo' }
def error(String m) { throw new hudson.AbortException(m) }
def podTemplate(Map a, Closure c) {
  OUT << 'podTemplate(' + a.yaml.readLines()[0] + ')'
  binding.setVariable('POD_LABEL', 'pod-genere')
  try { c() } finally { binding.variables.remove('POD_LABEL') }
}
def node(String l, Closure c) { OUT << 'node(' + l + ')'; c() }
def container(String n, Closure c) { OUT << 'container(' + n + ')'; c() }
GROOVY
cat > "$M/driver.groovy" <<'GROOVY'
def texte = new File(args[0]).text
new File('/m/cases').listFiles().sort { it.name }.each { d ->
  def out = []
  def b = new Binding()
  b.setVariable('CASE_DIR', d.path)
  b.setVariable('OUT', out)
  def envMap = [:]
  def ef = new File(d, 'env')
  if (ef.exists()) { ef.eachLine { l -> def i = l.indexOf('='); if (i > 0) { envMap[l.substring(0, i)] = l.substring(i + 1) } } }
  b.setVariable('env', envMap)
  try {
    new GroovyShell(this.class.classLoader, b).evaluate(texte)
  } catch (hudson.AbortException e) {
    out << ('REFUS ' + ((e.message =~ /REFUS: ([A-Z_]+)/) ? (e.message =~ /REFUS: ([A-Z_]+)/)[0][1] : e.message))
  } catch (Throwable t) {
    out << ('EXC ' + t.getClass().getName())
  }
  println "CASE ${d.name} " + out.findAll { it != 'echo' }.join(' ')
}
GROOVY

# cas <nom> <site.ini (\n) ou ABSENT> <env (\n)> [fichier-yaml:contenu-première-ligne]
cas() {
  d="$M/cases/$1"; mkdir -p "$d/repo/poc-control-plane-federation/config"
  [ "$2" = ABSENT ] || printf '%b\n' "$2" > "$d/repo/poc-control-plane-federation/config/site.ini"
  [ -z "$3" ] || printf '%b\n' "$3" > "$d/env"
  if [ -n "${4:-}" ]; then
    mkdir -p "$d/repo/$(dirname "${4%%:*}")"
    printf '%b\n' "${4#*:}" > "$d/repo/${4%%:*}"
  fi
}
POD='ci/agent-pod.yaml:# pod-de-test\napiVersion: v1\nkind: Pod'
cas B1-rien          ''                                                         ''
cas B2-label         'POST_AGENT_LABEL=runner-ansible'                          ''
cas B3-pod           'AGENT_POD_YAML_FILE=ci/agent-pod.yaml\nAGENT_CONTAINER=ansible' '' "$POD"
cas B4-label-ctr     'POST_AGENT_LABEL=runner\nAGENT_CONTAINER=python'          ''
cas B5-expression    'POST_AGENT_LABEL=linux && ansible'                        ''
cas B6-site-absent   ABSENT                                                     ''
cas C1-pod-sans-ctr  'AGENT_POD_YAML_FILE=ci/agent-pod.yaml'                    ''  "$POD"
cas C2-ambigu        'AGENT_POD_YAML_FILE=ci/agent-pod.yaml\nAGENT_CONTAINER=ansible\nPOST_AGENT_LABEL=x' '' "$POD"
cas C3-ctr-invalide  'POST_AGENT_LABEL=r\nAGENT_CONTAINER=Ansible_1'            ''
cas C4-chemin-remonte 'AGENT_POD_YAML_FILE=../secret.yaml\nAGENT_CONTAINER=ansible' ''
cas C5-chemin-absolu 'AGENT_POD_YAML_FILE=/etc/pod.yaml\nAGENT_CONTAINER=ansible' ''
cas C6-yaml-absent   'AGENT_POD_YAML_FILE=ci/absent.yaml\nAGENT_CONTAINER=ansible' ''
cas C7-yaml-vide     'AGENT_POD_YAML_FILE=ci/vide.yaml\nAGENT_CONTAINER=ansible' '' 'ci/vide.yaml:  '
cas C8-doublon       'AGENT_CONTAINER=ansible\nAGENT_CONTAINER=python'          ''
cas C9-label-quote   'POST_AGENT_LABEL=a"b'                                     ''
cas D1-env-gagne     'POST_AGENT_LABEL=du-fichier'                              'POST_AGENT_LABEL=de-la-globale'
cas D2-env-pod       ''  'AGENT_POD_YAML_FILE=ci/agent-pod.yaml\nAGENT_CONTAINER=ansible' "$POD"

attendu() {
  case "$1" in
    B1-rien)           echo 'node() body' ;;
    B2-label)          echo 'node(runner-ansible) body' ;;
    B3-pod)            echo 'podTemplate(# pod-de-test) node(pod-genere) container(ansible) body' ;;
    B4-label-ctr)      echo 'node(runner) container(python) body' ;;
    B5-expression)     echo 'node(linux && ansible) body' ;;
    B6-site-absent)    echo 'node() body' ;;
    C1-pod-sans-ctr)   echo 'REFUS AGENT_CONTAINER_REQUIS' ;;
    C2-ambigu)         echo 'REFUS AGENT_AMBIGU' ;;
    C3-ctr-invalide)   echo 'REFUS AGENT_CONTAINER_INVALIDE' ;;
    C4-chemin-remonte) echo 'REFUS AGENT_POD_YAML_FILE_INVALIDE' ;;
    C5-chemin-absolu)  echo 'REFUS AGENT_POD_YAML_FILE_INVALIDE' ;;
    C6-yaml-absent)    echo 'REFUS AGENT_POD_YAML_ILLISIBLE' ;;
    C7-yaml-vide)      echo 'REFUS AGENT_POD_YAML_VIDE' ;;
    C8-doublon)        echo 'REFUS SITE_CLE_EN_DOUBLE' ;;
    C9-label-quote)    echo 'REFUS POST_AGENT_LABEL_INVALIDE' ;;
    D1-env-gagne)      echo 'node(de-la-globale) body' ;;
    D2-env-pod)        echo 'podTemplate(# pod-de-test) node(pod-genere) container(ansible) body' ;;
  esac
}
libelle() {
  case "$1" in
    B1-rien)           echo "rien de posé ⇒ node('') : le comportement historique du lab est INCHANGÉ" ;;
    B2-label)          echo "POST_AGENT_LABEL ⇒ node(label), sans conteneur" ;;
    B3-pod)            echo "AGENT_POD_YAML_FILE + AGENT_CONTAINER ⇒ podTemplate(le yaml lu) → node(POD_LABEL) → container → corps" ;;
    B4-label-ctr)      echo "label + conteneur ⇒ node(label) → container (template à plusieurs conteneurs)" ;;
    B5-expression)     echo "une EXPRESSION de labels passe telle quelle" ;;
    B6-site-absent)    echo "site.ini absent ⇒ dégradation vers node(''), aucune panne" ;;
    C1-pod-sans-ctr)   echo "pod SANS conteneur ⇒ REFUS (les sh tourneraient dans le jnlp — la panne mesurée)" ;;
    C2-ambigu)         echo "pod ET label ⇒ REFUS, jamais un arbitrage silencieux" ;;
    C3-ctr-invalide)   echo "nom de conteneur hors classe Kubernetes ⇒ REFUS" ;;
    C4-chemin-remonte) echo "chemin du yaml avec .. ⇒ REFUS" ;;
    C5-chemin-absolu)  echo "chemin du yaml absolu ⇒ REFUS" ;;
    C6-yaml-absent)    echo "yaml introuvable ⇒ REFUS NOMMÉ (pas l'AbortException brute)" ;;
    C7-yaml-vide)      echo "yaml vide ⇒ REFUS" ;;
    C8-doublon)        echo "clé d'agent en double dans site.ini ⇒ REFUS (même verdict que la lib shell)" ;;
    C9-label-quote)    echo "label portant un guillemet ⇒ REFUS" ;;
    D1-env-gagne)      echo "la globale l'emporte sur site.ini (la voie admin reste intacte)" ;;
    D2-env-pod)        echo "le pod peut venir des globales seules" ;;
  esac
}

# les variantes : le bloc LIVRÉ, puis ses mutants (sur COPIE du bloc extrait)
{ cat "$M/prelude.groovy"; cat "$REF"; echo "agentNode { OUT << 'body' }"; } > "$M/scripts/0-livre.groovy"
muter() { # <nom> <perl -0pe expression>
  perl -0pe "$2" "$M/scripts/0-livre.groovy" > "$M/scripts/$1.groovy"
  cmp -s "$M/scripts/0-livre.groovy" "$M/scripts/$1.groovy" && ko "M mutation $1 INOPÉRANTE (rien n'a changé)"
}
muter m1-sans-container 's/container\(AGENT_SPEC\.container\) \{ body\(\) \}\n(\s*\}\n\s*\}\n\s*\} else if)/body()\n$1/'
muter m2-sans-requis    's/if \(f && !c\) \{/if (false) {/'
muter m3-site-gagne     's/env\.POST_AGENT_LABEL \?: SITE_AGENT\.POST_AGENT_LABEL/SITE_AGENT.POST_AGENT_LABEL ?: env.POST_AGENT_LABEL/'
muter m4-sans-doublon   's/if \(SITE_AGENT_N\[k\] > 1\)/if (false)/'

docker run --rm -v "$M:/m" "$GROOVY_IMG" sh -c \
  'for s in /m/scripts/*.groovy; do echo "SCRIPT $(basename "$s" .groovy)"; groovy -cp /m /m/driver.groovy "$s" 2>&1; done' \
  > "$TMP/sortie" 2>&1
verdict() { # <script> <cas> → la séquence observée
  awk -v s="$1" -v c="$2" '$1=="SCRIPT"{cur=$2; next} cur==s && $1=="CASE" && $2==c {$1="";$2=""; sub(/^  /,""); print; exit}' "$TMP/sortie"
}
if ! grep -q '^CASE ' "$TMP/sortie"; then
  ko "le harnais n'a rien rendu :"; sed 's/^/      /' "$TMP/sortie" | head -20
fi

echo; echo "═══ B/C/D. le bloc LIVRÉ, exécuté cas par cas ═══"
for d in "$M"/cases/*; do
  c=$(basename "$d"); vu=$(verdict 0-livre "$c"); att=$(attendu "$c")
  [ "$vu" = "$att" ] && ok "${c%%-*} $(libelle "$c")" || ko "${c%%-*} $(libelle "$c") — attendu « $att », vu « $vu »"
done

echo; echo "═══ M. mutations : chaque épreuve rougit sur le défaut qu'elle vise ═══"
mut() { # <script> <cas> <libellé>
  vu=$(verdict "$1" "$2")
  [ -n "$vu" ] && [ "$vu" != "$(attendu "$2")" ] && ok "$1 ⇒ $2 ROUGIT ($3 ; vu « $vu »)" \
    || ko "$1 ⇒ $2 reste vert : l'épreuve ne voit pas ce défaut (vu « $vu »)"
}
mut m1-sans-container B3-pod       "le corps tournerait dans le jnlp du pod"
mut m2-sans-requis    C1-pod-sans-ctr "le pod sans conteneur passerait"
mut m3-site-gagne     D1-env-gagne "le fichier écraserait la globale"
mut m4-sans-doublon   C8-doublon   "le doublon serait tranché en silence"

echo
echo "======================================================================"
echo "RÉSULTAT : $PASS/$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
