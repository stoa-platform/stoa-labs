#!/usr/bin/env bash
# test-env-chain.sh — porte de preuve de la CHAÎNE DE PROMOTION livrée
# (clients/_example/environments.yaml, jalon G1 du GOAL 2026-08-26).
#
# Ce fichier de config est le seul rempart entre un client et la chaîne PAR
# DÉFAUT `dev → staging → production` : absent, personne ne le remarque avant
# qu'un déploiement ne « ne trouve pas son palier » trois couches plus loin.
# Ses portes (approverGroup / fourEyes / ITSM) sont la séparation des tâches
# elle-même — un relâchement s'y lit comme une ligne de diff anodine.
#
#   1. le fichier livré existe et PARSE (fail-closed vérifié)
#   2. la chaîne est celle attendue, DANS L'ORDRE (l'ordre EST la chaîne)
#   3. chaque saut porte le jeu de contrôles annoncé
#   4. CONTRE-ÉPREUVE : un relâchement de porte fait ROUGIR (sabotage joué,
#      puis restauration inconditionnelle)
#
# ── POURQUOI CE SCRIPT EXISTE ALORS QUE LE TEST GO EXISTE DÉJÀ ───────────────
# MESURÉ le 2026-08-26 : `go test ./internal/governance/` rend `ok (cached)`
# APRÈS un relâchement de porte. Le cache de test Go ne piste pas
# clients/_example/environments.yaml, qui vit HORS du module labctl/ — le
# sabotage passe donc au vert sur un run mis en cache, et n'est rattrapé que
# par `-count=1`. Une garde qui ne rougit que si l'on pense au bon flag n'est
# pas une garde. Ce script force `-count=1` et joue la contre-épreuve ; c'est
# LUI la porte, le test Go en est le moteur.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAIN="$ROOT/clients/_example/environments.yaml"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

gotest() { ( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor \
              go test -count=1 ./internal/governance/ -run TestShippedExampleChain "$@" ); }

echo "① le fichier de chaîne livré existe"
[ -f "$CHAIN" ] && ok "clients/_example/environments.yaml présent" \
                || bad "clients/_example/environments.yaml ABSENT — chaîne par défaut dev/staging/production"

echo "② + ③ la chaîne parse, garde son ordre, et ses portes sont celles annoncées"
if OUT=$(gotest 2>&1); then
  ok "TestShippedExampleChain_* (ordre de la chaîne + jeu de contrôles par saut)"
else
  bad "chaîne livrée NON conforme :"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi

echo "④ CONTRE-ÉPREUVE — un relâchement de porte doit faire ROUGIR"
# Restauration INCONDITIONNELLE : ce script ne doit jamais laisser derrière lui
# une chaîne sabotée, quel que soit son point de sortie (y compris Ctrl-C).
BAK="$(mktemp)"; cp "$CHAIN" "$BAK"
trap 'cp "$BAK" "$CHAIN"; rm -f "$BAK"' EXIT INT TERM

# Sabotage : on retire à la prod la re-vérification ITSM au moment de
# l'approbation — exactement la garde anti-TOCTOU d'ADR-075, et exactement le
# genre de ligne qu'une revue pressée laisse passer.
sed -i.tmp 's/^    itsmCheck: true$/    itsmCheck: false/' "$CHAIN" && rm -f "$CHAIN.tmp"
if grep -q 'itsmCheck: false' "$CHAIN"; then
  if gotest >/dev/null 2>&1; then
    bad "porte relâchée NON détectée — le test est un vert vacant"
  else
    ok "itsmCheck retiré de la porte prod ⇒ le test ROUGIT"
  fi
else
  bad "sabotage non appliqué (le fichier a changé de forme ?) — contre-épreuve NON jouée"
fi

cp "$BAK" "$CHAIN"
grep -q 'itsmCheck: true' "$CHAIN" && ok "chaîne restaurée à l'identique" \
                                   || bad "RESTAURATION KO — vérifier $CHAIN à la main"

echo "⑤ CONTRE-ÉPREUVE n°2 — retirer QUI PORTE l'apply doit aussi faire ROUGIR"
# ── contre-épreuve n°2 (G2) : retirer la déclaration déployeur de int ────────
sed -i.tmp 's/^    deployerGroup: apim-apply-int$//' "$CHAIN" && rm -f "$CHAIN.tmp"
if gotest >/dev/null 2>&1; then
  bad "sabotage deployerGroup NON détecté — le gabarit n'épingle pas l'axe (vert vacant)"
else
  ok "porte relâchée (deployerGroup int retiré) => test Go ROUGE"
fi
cp "$BAK" "$CHAIN"
grep -q 'deployerGroup: apim-apply-int' "$CHAIN" && ok "chaîne restaurée (deployerGroup)" \
  || bad "restauration deployerGroup manquée"

printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
