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

echo "⑦ lecteurs G7 — terminus par position, itsmCheck par porte"
# shellcheck source=scripts/lib/env-chain.sh
. "$ROOT/scripts/lib/env-chain.sh"
T="$(env_chain_terminus)"
[ "$T" = prod ] && ok "env_chain_terminus rend le DERNIER palier (prod)" \
                || bad "env_chain_terminus rend '$T' (attendu prod)"
I="$(env_chain_gate_itsm_check prod)"
[ "$I" = "ITSMCHECK=1" ] && ok "la porte prod déclare itsmCheck (lu par la lib)" \
                         || bad "itsmCheck prod non lu ($I)"
I="$(env_chain_gate_itsm_check rec)"
[ "$I" = "ITSMCHECK=0" ] && ok "la porte rec ne déclare PAS itsmCheck" \
                         || bad "itsmCheck rec inattendu ($I)"
# CONTRE-ÉPREUVE : source cassée ⇒ refus FERMÉ des deux lecteurs (jamais une
# valeur devinée). On pointe un fichier ABSENT via STOA_ENV_CHAIN_FILE.
if OUT=$(STOA_ENV_CHAIN_FILE="$ROOT/nexiste.pas.yaml" env_chain_terminus 2>&1); then
  bad "env_chain_terminus a rendu '$OUT' sur source absente (fail-open)"
else
  ok "env_chain_terminus refuse FERMÉ sur source absente"
fi
if OUT=$(STOA_ENV_CHAIN_FILE="$ROOT/nexiste.pas.yaml" env_chain_gate_itsm_check prod 2>&1); then
  bad "env_chain_gate_itsm_check a rendu '$OUT' sur source absente (fail-open)"
else
  ok "env_chain_gate_itsm_check refuse FERMÉ sur source absente"
fi

echo "⑧ env_chain_validate — le gabarit livré est valide, cinq sabotages sont REFUSÉS (A4, D0)"
# POURQUOI : env_chain_gate rend {} pour une porte `to: itn` ou une clé mal
# orthographiée — un palier SANS contrôle, sans journal (critique adverse A4).
# Le lecteur de validation doit refuser la chaîne AVANT qu'une porte ne la lise.
if type env_chain_validate >/dev/null 2>&1; then ok "env_chain_validate existe dans la lib"; else bad "env_chain_validate ABSENTE de la lib"; fi
V="$(mktemp -d)"; trap 'cp "$BAK" "$CHAIN"; rm -f "$BAK"; rm -rf "$V"' EXIT INT TERM
cp "$CHAIN" "$V/ok.yaml"
if ( STOA_ENV_CHAIN_FILE="$V/ok.yaml" env_chain_validate ) 2>"$V/err"; then ok "gabarit livré : valide"; else bad "gabarit livré REFUSÉ : $(cat "$V/err")"; fi
sab(){ # <nom> <sed-expr> <fragment de cause attendu>
  sed -E "$2" "$CHAIN" > "$V/$1.yaml"
  if cmp -s "$CHAIN" "$V/$1.yaml"; then bad "sabotage $1 NO-OP (l'ancre a bougé)"; return; fi
  if ( STOA_ENV_CHAIN_FILE="$V/$1.yaml" env_chain_validate ) 2>"$V/err"; then bad "sabotage $1 ACCEPTÉ (vert vacant)"
  elif grep -q "$3" "$V/err"; then ok "sabotage $1 refusé : $(tail -1 "$V/err" | cut -c1-100)"
  else bad "sabotage $1 refusé pour une autre cause : $(cat "$V/err")"; fi
}
sab to-inconnu    's/^  - to: int$/  - to: itn/'                     "ne nomme aucun environnement"
sab cle-inconnue  's/^    fourEyes: true$/    foureyes: true/'        "inconnue"
sab bool-texte    's/^    itsmCheck: true$/    itsmCheck: "true"/'    "booleen"
sab to-double     's/^  - to: homol$/  - to: int/'                   "deux fois"
sab env-majuscule 's/^environments: \[dev, rec, int, homol, prod\]$/environments: [dev, rec, int, homol, Prod]/' "hors de"

printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
