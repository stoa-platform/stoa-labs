#!/usr/bin/env bash
# test-jenkinsfile-lint.sh — porte de LINT GROOVY sur tous les Jenkinsfile.
#
# POURQUOI : le 2026-08-07, ci/Jenkinsfile.carto a cessé de COMPILER (`\w` dans
# une chaîne Groovy — échappement invalide) et personne ne l'a vu, parce que
# rien ne parse ces fichiers hors d'un build réel. Un Jenkinsfile qui ne compile
# pas ne « rate » pas un test : il rend le job inexécutable, et le diagnostic
# arrive au pire moment. Cette porte manquait ; la voici.
#
# Ce lint PARSE, il n'exécute pas : aucun effet de bord, aucun accès réseau,
# aucun besoin de Jenkins. Il attrape les erreurs de SYNTAXE et d'échappement,
# pas les erreurs de logique de pipeline (un `sh` qui échouera au runtime passe
# ce lint — c'est attendu, ce n'est pas son rôle).
#
# Usage :  bash scripts/test-jenkinsfile-lint.sh
# Prérequis : Docker (image groovy:4-jdk17). Aucun Groovy local nécessaire.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${GROOVY_IMAGE:-groovy:4-jdk17}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

command -v docker >/dev/null 2>&1 || { echo "docker requis (image $IMG)"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/Lint.groovy" <<'GROOVY'
// Parse SEULEMENT (pas d'exécution) : GroovyShell.parse compile le script et
// lève sur toute erreur de syntaxe ou d'échappement.
int bad = 0
args.each { p ->
  try { new GroovyShell().parse(new File(p)); println "OK\t${p}" }
  catch (Throwable t) { bad++; println "PARSE\t${p}\t${t.message.readLines()[0]}" }
}
System.exit(bad == 0 ? 0 : 1)
GROOVY

# Tous les Jenkinsfile du dépôt, y compris les miroirs — un miroir cassé est un
# job cassé le jour où on le repose.
#
# ⚠ PAS de `mapfile` : c'est un builtin bash 4, et macOS livre bash 3.2. Écrit
# avec, ce script rendait « 1 PASS / 0 FAIL » et sortait 0 alors que l'étape ①
# n'avait tourné sur AUCUN fichier (mesuré) — un vert vacant dans la porte
# elle-même. D'où le tableau construit à la main, ET le garde-fou de compte
# ci-dessous : zéro fichier linté est désormais un ÉCHEC, pas un silence.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(cd "$ROOT" && find . -name 'Jenkinsfile*' -not -path './.git/*' | sort)
if [ "${#FILES[@]}" -eq 0 ]; then
  bad "aucun Jenkinsfile trouvé sous $ROOT — la porte n'a rien vérifié"
  printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"; exit 1
fi
echo "① lint Groovy de ${#FILES[@]} Jenkinsfile"

OUT=$(docker run --rm -v "$ROOT":/w -v "$TMP/Lint.groovy":/Lint.groovy -w /w "$IMG" \
        groovy /Lint.groovy "${FILES[@]}" 2>/dev/null)
LINTED=0
while IFS=$'\t' read -r verdict path msg; do
  case "$verdict" in
    OK)    LINTED=$((LINTED+1)); ok "$path" ;;
    PARSE) LINTED=$((LINTED+1)); bad "$path — $msg" ;;
  esac
done <<< "$OUT"
# Le lint doit avoir rendu un verdict pour CHAQUE fichier : un conteneur mort ou
# une sortie tronquée ne doit pas passer pour « tout va bien ».
[ "$LINTED" -eq "${#FILES[@]}" ] || bad "verdicts rendus : $LINTED / ${#FILES[@]} — sortie du lint incomplète"

# CONTRE-ÉPREUVE : un lint qui ne rougit jamais ne prouve rien. On injecte
# l'erreur EXACTE qui a cassé Jenkinsfile.carto (échappement `\w` invalide).
echo "② contre-épreuve — un échappement invalide doit ROUGIR"
printf 'def s = "motif \\w+ invalide"\n' > "$TMP/Jenkinsfile.saboté"
if docker run --rm -v "$TMP":/w -v "$TMP/Lint.groovy":/Lint.groovy -w /w "$IMG" \
     groovy /Lint.groovy "Jenkinsfile.saboté" >/dev/null 2>&1; then
  bad "échappement invalide NON détecté — le lint est un vert vacant"
else
  ok "échappement invalide détecté (le défaut de carto serait attrapé)"
fi

printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
