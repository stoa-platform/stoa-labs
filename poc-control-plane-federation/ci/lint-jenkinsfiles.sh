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
