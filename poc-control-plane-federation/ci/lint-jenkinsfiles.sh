#!/bin/sh
# ci/lint-jenkinsfiles.sh — LA PORTE QUI MANQUAIT : compile les Jenkinsfile.
#
# ─────────────────────────────────────────────────────────────────────────────
# POURQUOI CETTE PORTE EXISTE
# ─────────────────────────────────────────────────────────────────────────────
# Rien dans cette chaîne ne compilait les Jenkinsfile. Un fichier qui ne parse
# plus ne se voit donc qu'à l'exécution — c'est-à-dire, pour `carto`, la nuit
# suivante, sur un job planifié que personne ne regarde le matin.
#
# Ce n'est pas une crainte théorique, c'est arrivé DEUX FOIS :
#   2026-08-07  `Jenkinsfile.carto` ne compilait plus depuis un correctif de
#               mesure : `r"=(\w+)"` écrit dans une chaîne Groovy '''...''',
#               où `\w` est un échappement INVALIDE (contrairement à Python).
#               Découvert par relecture, pas par la chaîne.
#   2026-08-26  revue du lot Vault : quatre `sh` sourçaient une bibliothèque
#               par un chemin faux. Celui-là, cette porte NE l'attrape PAS —
#               il parse très bien. C'est le rôle de `ci/test-carto-secrets.sh`,
#               et c'est pourquoi les deux portes sont complémentaires, pas
#               redondantes : celle-ci lit la SYNTAXE, l'autre le COMPORTEMENT.
#
# CE QU'ELLE FAIT, ET CE QU'ELLE NE FAIT PAS. Elle PARSE (`GroovyShell.parse`),
# elle n'EXÉCUTE pas : aucun step Jenkins n'est appelé, aucun credential n'est
# lu, aucune gateway n'est jointe. Elle attrape les fautes de syntaxe et les
# échappements invalides — pas les erreurs de logique, pas les steps inconnus
# de Jenkins (ça, seul un vrai contrôleur le dit).
#
# ELLE NE SAUTE JAMAIS EN SILENCE. Si l'outil manque, elle ÉCHOUE en nommant le
# geste. Une porte qui se désactive toute seule quand l'outillage manque est
# exactement ce qui a laissé passer les deux défauts ci-dessus.
#
# USAGE
#   ci/lint-jenkinsfiles.sh              # depuis poc-control-plane-federation/
#   make lint-ci                         # depuis la même racine
#   GROOVY_IMAGE=groovy:5-jdk21 ci/lint-jenkinsfiles.sh
set -eu

cd "$(dirname "$0")/.."
CI_DIR="ci"
GROOVY_IMAGE="${GROOVY_IMAGE:-groovy:4-jdk17}"

# Le script Groovy est le MÊME quel que soit le moteur (binaire local ou
# conteneur) : une seule sémantique à raisonner, et pas de divergence possible
# entre « ce que voit le poste » et « ce que voit la porte ».
PROBE="$(mktemp)"; trap 'rm -f "$PROBE"' EXIT
cat > "$PROBE" <<'GROOVY'
def racine = new File(System.getProperty('lint.dir') ?: 'ci')
def fichiers = racine.listFiles().findAll { it.name.startsWith('Jenkinsfile') }.sort { it.name }
if (!fichiers) { System.err.println "AUCUN Jenkinsfile dans ${racine} — porte inopérante."; System.exit 2 }
int ko = 0
fichiers.each { f ->
  try {
    // Le nom de classe est dérivé du nom de fichier : « Jenkinsfile.carto »
    // ne donnerait pas un identifiant Java valide, d'où l'assainissement.
    new groovy.lang.GroovyShell().parse(f.text, f.name.replaceAll(/[^A-Za-z0-9]/, '_'))
    println "  ✓ ${f.name}"
  } catch (Throwable t) {
    ko++
    println "  ✗ ${f.name}"
    t.message.readLines().each { println "      ${it}" }
  }
}
println ""
println ko == 0 ? "PORTE VERTE : ${fichiers.size()} Jenkinsfile compilent."
                : "PORTE ROUGE : ${ko} Jenkinsfile sur ${fichiers.size()} ne compilent pas."
System.exit(ko == 0 ? 0 : 1)
GROOVY

# ─────────────────────────────────────────────────────────────────────────────
# LE SHELL QUI INTERPRÈTE UN BLOC `sh` EST DASH — donc ce qu'il SOURCE aussi
# ─────────────────────────────────────────────────────────────────────────────
# Défaut réel, trouvé en relecture adverse le 2026-09-12, AVANT tout build :
# ci/Jenkinsfile.team-apply sourçait `scripts/lib/forge-api.sh` dans un bloc
# `sh` pour relire les identités sur la forge. Ça PARSE côté Groovy — la porte
# ci-dessous était donc verte — et ça ne peut pas s'EXÉCUTER : cette lib est du
# BASH (${BASH_SOURCE[0]}, printf -v, here-string), et un step `sh` de Jenkins
# tourne en DASH. Mesuré : `dash -n scripts/lib/forge-api.sh` →
# « 111: Syntax error: redirection unexpected », rc 2. Le step mourait sur deux
# messages de dash qui ne nomment aucun refus du dépôt, APRÈS avoir réveillé un
# humain et encaissé son mot de passe d'annuaire — sur les deux visages de
# forge, Gitea comprise.
#
# La règle, que cette porte MESURE au lieu de l'écrire dans un commentaire :
# une lib sourcée depuis un bloc `sh` doit être lisible par dash. Le geste
# normal reste `bash scripts/<script>.sh` — un process à soi, son shebang, et
# tout le bash qu'il veut (c'est ce que fait le reste de la chaîne).
#
# PORTÉE DÉRIVÉE, aucune liste à la main : toute ligne de ci/Jenkinsfile* qui
# COMMENCE par `.` ou `source` suivi d'un chemin scripts/lib/… ou ci/lib/…
# (une telle ligne ne peut venir que d'un bloc shell ; un commentaire Groovy
# commence par `//`).
echo "== Le shell des blocs \`sh\` : dash lit les libs qu'ils sourcent ($CI_DIR/)"
if ! command -v dash >/dev/null 2>&1; then
  echo "!! dash absent de cette machine — la porte ne peut pas mesurer." >&2
  echo "   Le geste : \`brew install dash\` (macOS) ou \`apt-get install dash\` (Debian)." >&2
  echo "   PAS de mode dégradé : sans dash, on ne saurait pas qu'un bloc \`sh\`" >&2
  echo "   source une lib que l'agent Jenkins ne pourra pas lire." >&2
  exit 2
fi
SOURCEES="$(grep -lE '^[[:space:]]*(\.|source)[[:space:]]+(scripts|ci)/lib/' "$CI_DIR"/Jenkinsfile* 2>/dev/null || true)"
ko_dash=0
n_dash=0
for JF in $SOURCEES; do
  # Délimiteur `@` et NON `|` : le motif porte une alternance `(\.|source)`, et
  # le sed de BSD prend alors le premier `|` pour la fin du motif (« RE error:
  # parentheses not balanced » — mesuré ici même, et la porte imprimait
  # « 0 source mesurée » puis sortait VERTE : un vert vacant).
  LIBS_JF="$(sed -nE 's@^[[:space:]]*(\.|source)[[:space:]]+((scripts|ci)/lib/[A-Za-z0-9_.@-]+\.sh).*@\2@p' "$JF" | sort -u)"
  if [ -z "$LIBS_JF" ]; then
    # grep a vu une ligne de source dans ce fichier, l'extraction n'en tire
    # rien : c'est la porte qui ne sait plus lire, pas le dépôt qui est sain.
    echo "  ❌ $JF porte une ligne de source de lib que cette porte NE SAIT PAS extraire"
    grep -nE '^[[:space:]]*(\.|source)[[:space:]]+(scripts|ci)/lib/' "$JF" | sed 's/^/       /'
    ko_dash=$((ko_dash + 1))
    continue
  fi
  for LIB in $LIBS_JF; do
    n_dash=$((n_dash + 1))
    if [ ! -f "$LIB" ]; then
      echo "  ❌ $JF source $LIB — INTROUVABLE depuis la racine du dépôt"
      ko_dash=$((ko_dash + 1))
    elif dash -n "$LIB" 2>/dev/null; then
      echo "  ✅ $JF source $LIB — dash la lit"
    else
      echo "  ❌ $JF source $LIB dans un bloc \`sh\` (donc DASH), mais dash NE LA LIT PAS :"
      dash -n "$LIB" 2>&1 | sed 's/^/       /'
      echo "       Le geste : sortir ces lignes dans scripts/<script>.sh (shebang"
      echo "       bash, mêmes refus nommés) et n'appeler que \`bash scripts/<script>.sh\`."
      ko_dash=$((ko_dash + 1))
    fi
  done
done
if [ "$ko_dash" -ne 0 ]; then
  echo ""
  echo "PORTE ROUGE : $ko_dash lib(s) sourcée(s) sur $n_dash illisible(s) par dash."
  exit 1
fi
echo "  ($n_dash source(s) de lib mesurée(s) dans les blocs \`sh\`)"
echo ""

echo "== Compilation des Jenkinsfile ($CI_DIR/)"
if command -v groovy >/dev/null 2>&1; then
  groovy -Dlint.dir="$CI_DIR" "$PROBE"
elif command -v docker >/dev/null 2>&1; then
  # :ro sur le dépôt — cette porte LIT, elle n'écrit rien.
  #
  # PAS DE PIPE ICI, ET C'EST LE POINT DÉLICAT. Écrire
  #   docker run ... | grep -v WARNING
  # rend le code de sortie de la PORTE égal à celui de `grep`, pas à celui de
  # `groovy` : la porte imprimait « PORTE ROUGE » et sortait 0. `set -o pipefail`
  # n'existe pas en POSIX sh (les blocs `sh` de Jenkins tournent en dash), donc
  # on passe par un fichier : le filtrage du bruit ne doit jamais avaler le
  # verdict. Défaut constaté sur cette porte même, le 2026-08-26.
  SORTIE="$(mktemp)"; trap 'rm -f "$PROBE" "$SORTIE"' EXIT
  rc=0
  docker run --rm \
    -v "$PWD/$CI_DIR":/w:ro -v "$PROBE":/probe.groovy:ro \
    "$GROOVY_IMAGE" groovy -Dlint.dir=/w /probe.groovy > "$SORTIE" 2>&1 || rc=$?
  grep -v '^WARNING: Using incubator' "$SORTIE" || true
  exit "$rc"
else
  echo "!! NI groovy NI docker sur ce poste — la porte ne peut pas s'exécuter." >&2
  echo "   Le geste : soit \`brew install groovy\`, soit démarrer Docker (l'image" >&2
  echo "   $GROOVY_IMAGE est tirée une fois puis mise en cache)." >&2
  echo "   Cette porte n'a PAS de mode dégradé : un Jenkinsfile non compilé est" >&2
  echo "   un job qui tombera la nuit suivante." >&2
  exit 2
fi
