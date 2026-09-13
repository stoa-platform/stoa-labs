#!/usr/bin/env bash
# ci/lint-permissive-defaults.sh — UN DÉFAUT PERMISSIF NE SE POSE PAS TOUT SEUL.
#
# ─────────────────────────────────────────────────────────────────────────────
# LE DÉFAUT QUE CETTE PORTE FERME (mesuré le 2026-09-13)
# ─────────────────────────────────────────────────────────────────────────────
# `OPENSEARCH_INSECURE` valait « ne vérifie pas le certificat » PAR DÉFAUT, à
# TROIS couches indépendantes : les deux binaires Go, les trois scripts de
# provision (qui en tirent un `curl -k`), et un repli dans TROIS Jenkinsfile,
# dont celui qui s'appelle `prod`. Personne ne l'avait demandé : la chaîne
# remontait sa trace d'audit sans vérifier à qui elle parlait — et chez un
# client dont OpenSearch porte un vrai certificat, ça ne se voyait même pas.
#
# Ce n'était PAS dans la dette déclarée de ci/lint-config-knobs.sh, et pour une
# raison intéressante : cette porte-là traque les valeurs de LAB (adresses,
# chemins, identifiants) — un booléen n'a pas la forme d'une valeur de lab. Le
# défaut échappait donc par sa FORME, pas par oubli. D'où une porte séparée.
#
# LA RÈGLE, générale et pas taillée pour un knob : un knob dont le NOM annonce
# un affaiblissement (INSECURE, SKIP_VERIFY, NO_VERIFY, DISABLE_…) ne peut pas
# avoir un défaut permissif. Il se pose EXPLICITEMENT, ou il ne s'applique pas.
# Un futur knob de cette famille est couvert le jour où quelqu'un l'écrit, sans
# que personne ait à penser à cette porte.
#
# ⚠ LES COMMENTAIRES SONT RETIRÉS AVANT DE CHERCHER, et cette porte l'a appris
# SUR ELLE-MÊME : à son premier run elle a rougi sur sa propre prose, qui citait
# la forme interdite pour l'expliquer. Une porte satisfaite — ou trahie — par un
# commentaire ne mesure pas le code. Même précaution que ci/lint-forge-literals.sh.
#
# PORTÉE : ci/Jenkinsfile*, les scripts shell livrés (ci, observability,
# scripts), et les sources Go de labctl.
#
#   bash ci/lint-permissive-defaults.sh
set -uo pipefail
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RACINE" || exit 1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# Les noms qui ANNONCENT un affaiblissement. Une addition ici élargit la porte.
NOMS='INSECURE|SKIP_VERIFY|SKIPVERIFY|NO_VERIFY|NOVERIFY|DISABLE_VERIF|ALLOW_INSECURE'

TMP="$(mktemp -d /tmp/lpd.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
CODE="$TMP/code"   # la vue CODE SEUL de tous les fichiers de la portée
: > "$CODE"
for f in ci/Jenkinsfile* $(find ci observability scripts -name '*.sh' 2>/dev/null) \
         $(find labctl -name '*.go' 2>/dev/null); do
  [ -f "$f" ] || continue
  case "$f" in
    *.sh) sed -E 's@^[[:space:]]*#.*$@@' "$f" ;;
    *)    sed -E 's@^[[:space:]]*//.*$@@' "$f" ;;
  esac >> "$CODE"
done

echo "═══ A. les trois formes de défaut sont LUES (sinon la porte ne mesure rien) ═══"
J=$(grep -oE "[A-Z0-9_]*($NOMS)[A-Z0-9_]*[[:space:]]*=[[:space:]]*\"\\\$\{env\.[A-Z0-9_]+[[:space:]]*\?:[[:space:]]*'[^']*'\}\"" "$CODE" || true)
S=$(grep -oE "\\\$\{[A-Z0-9_]*($NOMS)[A-Z0-9_]*:-[A-Za-z0-9]*\}" "$CODE" || true)
G=$(grep -oE "boolEnv[A-Za-z]*\(\"[A-Z0-9_]*($NOMS)[A-Z0-9_]*\",[[:space:]]*[a-z]+\)" "$CODE" || true)
N=$(printf '%s\n%s\n%s\n' "$J" "$S" "$G" | grep -c '[A-Za-z]' || true)
if [ "$N" -lt 3 ]; then
  ko "A.1 seulement $N déclaration(s) trouvée(s) sur les trois formes — l'extraction est cassée, pas le dépôt sain"
  echo "PORTE ROUGE"; exit 1
fi
ok "A.1 $N déclaration(s) de knob d'affaiblissement lues dans le CODE (Jenkinsfile, shell, Go)"

echo
echo "═══ B. aucune d'elles n'a un défaut PERMISSIF ═══"
BAD=""
printf '%s\n' "$J" | grep -qE "\?:[[:space:]]*'(true|True|TRUE|1|yes|on)'" && BAD="$BAD [Jenkinsfile]$(printf '%s\n' "$J" | grep -E "\?:[[:space:]]*'(true|True|TRUE|1|yes|on)'" | tr '\n' ' ')"
printf '%s\n' "$S" | grep -qE ":-(true|True|TRUE|1|yes|on)\}" && BAD="$BAD [shell]$(printf '%s\n' "$S" | grep -E ":-(true|True|TRUE|1|yes|on)\}" | tr '\n' ' ')"
printf '%s\n' "$G" | grep -qE ",[[:space:]]*true\)" && BAD="$BAD [Go]$(printf '%s\n' "$G" | grep -E ",[[:space:]]*true\)" | tr '\n' ' ')"
if [ -z "$BAD" ]; then
  ok "B.1 aucun défaut permissif : un affaiblissement se pose EXPLICITEMENT, ou ne s'applique pas"
else
  ko "B.1 défaut(s) PERMISSIF(S) —$BAD ; ce réglage affaiblit une vérification sans que personne ne l'ait demandé"
fi

echo
echo "═══ C. le chemin SÛR existe là où l'affaiblissement est proposé ═══"
# Proposer « ne vérifie pas » sans offrir « vérifie contre CETTE autorité »
# oblige à choisir entre ne rien vérifier et ne rien faire.
MANQUE=""
for f in $(grep -rlE '\$\{OPENSEARCH_INSECURE:-' --include='*.sh' observability ci scripts 2>/dev/null || true); do
  grep -q 'OPENSEARCH_CA_FILE' "$f" || MANQUE="$MANQUE $f"
done
if [ -z "$MANQUE" ]; then
  ok "C.1 tout consommateur d'OPENSEARCH_INSECURE connaît aussi OPENSEARCH_CA_FILE (le chemin sûr, prioritaire)"
else
  ko "C.1 affaiblissement proposé SANS chemin sûr —$MANQUE : il faudrait choisir entre ne rien vérifier et ne rien faire"
fi

echo
echo "═══ D. l'EFFET, quel que soit le NOM ═══"
# LA LIMITE DE B, ET SA FERMETURE. B dérive sa portée d'une FAMILLE DE NOMS :
# renommer le knob `OPENSEARCH_INSECURE` en `OPENSEARCH_LAXISTE` lui échappe —
# mutation jouée le 2026-09-13, restée VERTE, et c'est la limite honnête d'une
# règle fondée sur le nom. D ferme l'angle par l'AUTRE bout : l'effet. Un `-k`,
# un `--insecure`, un `InsecureSkipVerify: true` littéral ne se renomment pas.
# C'est ainsi qu'a été trouvé un QUATRIÈME script de provision, avec un `-k`
# câblé EN DUR — pire qu'un défaut permissif, et invisible à toute règle de nom.
#
# EXEMPTÉS NOMMÉMENT : les harnais et démos (scripts/test-*, scripts/demo-*,
# scripts/spike-*). Un `-k` contre le lab y est légitime et assumé — ils posent
# leurs valeurs eux-mêmes et ne sont pas livrés au client.
EFFET=""
for f in $(find ci observability scripts -name '*.sh' 2>/dev/null | sort); do
  case "$f" in scripts/test-*|scripts/demo-*|scripts/spike-*) continue ;; esac
  # Les lignes `echo`/`printf` sont du TEXTE, pas une exécution : un script qui
  # IMPRIME une commande de diagnostic à l'exploitant n'affaiblit rien lui-même
  # (faux positif mesuré le 2026-09-13 sur provision-apply-audit.sh). Ce qu'on
  # juge ici, c'est ce que le script FAIT.
  sed -E 's@^[[:space:]]*#.*$@@' "$f" \
    | grep -vE '^[[:space:]]*(echo|printf)[[:space:]]' \
    | grep -qE "curl[^|]*[[:space:]]-k([[:space:]]|\")|--insecure([[:space:]]|\")" \
    && EFFET="$EFFET $f"
done
for f in $(find labctl -name '*.go' 2>/dev/null | grep -v '_test\.go' | sort); do
  sed -E 's@^[[:space:]]*//.*$@@' "$f" | grep -qE 'InsecureSkipVerify:[[:space:]]*true' \
    && EFFET="$EFFET $f"
done
if [ -z "$EFFET" ]; then
  ok "D.1 aucun affaiblissement INCONDITIONNEL dans les fichiers livrés (ni -k, ni --insecure, ni InsecureSkipVerify littéral) — les harnais de lab sont exemptés nommément"
else
  ko "D.1 affaiblissement INCONDITIONNEL —$EFFET : un knob peut être renommé, un \`-k\` non ; celui-là ne se retire par aucune globale"
fi
echo
echo "══════════════════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then echo "PORTE VERTE : $PASS contrôles."; exit 0
else echo "PORTE ROUGE : $FAIL échec(s) sur $((PASS+FAIL))."; exit 1; fi
