#!/usr/bin/env bash
# test-classification-central.sh — PREUVE du gate anti-spoof de classification
# CENTRALE (ADR-076 écart #1, goal A5). Prouve, sans dépendre d'une gateway
# vivante (le gate résout la classification AVANT tout dispatch) :
#   1. 2 repos-projets (accounts-team VH, payments-team H) → bundles DIFFÉRENTS
#      dérivés du registre CENTRAL, via le MÊME binaire/pipeline.
#   2. Downgrade (api.yaml plus faible que le central) → CLASSIFICATION_SPOOFED.
#   3. Emprunt de ligne (pointer l'API d'un autre projet) → CLASSIFICATION_UNGOVERNED.
#   4. Mensonge tenant → CLASSIFICATION_SPOOFED.
#   5. API non gouvernée → CLASSIFICATION_UNGOVERNED.
#   6. Invariant d'ancrage (review S2) : un governance/ glissé dans le repo PROJET
#      est IGNORÉ (seul le chemin --classification-source, côté plateforme, fait foi).
#   7. Non-régression A1 : SANS source, l'api.yaml projet pilote (comportement A1).
#
# Le gate refuse AVANT le dispatch → on pointe un adminUrl bogus (127.0.0.1:1) et
# on asserte sur la sortie du gate (ligne "classification=X ... policies=[...]" +
# les codes de refus), pas sur la publication. Déterministe, indépendant de wM.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABS="$(cd "$ROOT/.." && pwd)"
REG="$LABS/stoa-platform-ci/governance/classifications.yaml"
ACC="$LABS/accounts-team/apis/accounts-read"
PAY="$LABS/payments-team/apis/payments-read"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

echo "=== 0. Prérequis ==="
[ -f "$REG" ] && ok "registre central présent ($REG)" || { bad "registre central absent"; exit 2; }
BIN="$(mktemp -d)/labctl"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" . ) || { echo "build failed"; exit 1; }
chmod +x "$BIN"; ok "labctl build (vendored)"

# Workspace de rendu par cas (labctl apply écrit catalog-info.yaml à côté du manifeste ;
# adminUrl réécrit en bogus pour que le gate tranche AVANT tout dispatch réseau).
prep() { # $1=src-api-dir  -> echo workspace
  local ws; ws="$(mktemp -d)"
  cp "$1"/api.yaml "$1"/openapi.yaml "$1"/target.yaml "$ws"/
  sed -i '' 's#http://localhost:5555#http://127.0.0.1:1#g' "$ws"/target.yaml 2>/dev/null \
    || sed -i 's#http://localhost:5555#http://127.0.0.1:1#g' "$ws"/target.yaml
  echo "$ws"
}
# apply avec source centrale + identité projet
applyc() { # $1=ws $2=project ; échos: OUT ; retourne rc
  ( cd "$1" && VAULT_ADDR= LABCTL_CLASSIFICATION_SOURCE="$REG" LABCTL_PROJECT="$2" \
      "$BIN" apply -f target.yaml 2>&1 )
}
# apply SANS source (A1)
applya1() { ( cd "$1" && VAULT_ADDR= "$BIN" apply -f target.yaml 2>&1 ); }

echo ""
echo "=== 1. Deux repos → bundles DIFFÉRENTS dérivés du CENTRAL (même binaire) ==="
WS="$(prep "$ACC")"; OUT="$(applyc "$WS" accounts-team)"
grep -qE "classification=VH .*policies=\[.*mtls.*\]" <<<"$OUT" && ok "accounts-team → bundle VH (mtls) dérivé du central" || bad "accounts-team pas VH+mtls: $(grep Enforcement <<<"$OUT")"
WS="$(prep "$PAY")"; OUT="$(applyc "$WS" payments-team)"
grep -q "classification=H " <<<"$OUT" && ok "payments-team → classification H (central)" || bad "payments-team pas H: $(grep Enforcement <<<"$OUT")"
grep -qE "classification=H .*policies=\[.*mtls" <<<"$OUT" && bad "payments-team NE doit PAS avoir mtls (H)" || ok "payments-team → bundle H SANS mtls (bundle différent, prouvé)"

echo ""
echo "=== 2. DOWNGRADE : api.yaml plus faible que le central → CLASSIFICATION_SPOOFED ==="
WS="$(prep "$ACC")"
sed -i '' 's/^classification: VH.*/classification: M/' "$WS"/api.yaml 2>/dev/null || sed -i 's/^classification: VH.*/classification: M/' "$WS"/api.yaml
OUT="$(applyc "$WS" accounts-team)"; RC=$?
[ "$RC" != 0 ] && grep -q "CLASSIFICATION_SPOOFED" <<<"$OUT" && ok "downgrade VH→M refusé [CLASSIFICATION_SPOOFED]" || bad "downgrade non refusé: $OUT"

echo ""
echo "=== 3. EMPRUNT DE LIGNE : accounts-team prétend servir payments-read → UNGOVERNED ==="
WS="$(prep "$PAY")"   # contrat payments-read (name=payments-read, central owner=payments-team)…
OUT="$(applyc "$WS" accounts-team)"; RC=$?   # …mais l'identité injectée est accounts-team
[ "$RC" != 0 ] && grep -q "CLASSIFICATION_UNGOVERNED" <<<"$OUT" && ok "accounts-team ne peut PAS emprunter payments-read [CLASSIFICATION_UNGOVERNED]" || bad "emprunt non refusé: $OUT"

echo ""
echo "=== 4. MENSONGE TENANT : bon owner/api, tenant_id falsifié → SPOOFED ==="
WS="$(prep "$ACC")"
sed -i '' 's/^tenant_id: banking-demo.*/tenant_id: payments-team/' "$WS"/api.yaml 2>/dev/null || sed -i 's/^tenant_id: banking-demo.*/tenant_id: payments-team/' "$WS"/api.yaml
OUT="$(applyc "$WS" accounts-team)"; RC=$?
[ "$RC" != 0 ] && grep -q "CLASSIFICATION_SPOOFED" <<<"$OUT" && ok "tenant falsifié refusé [CLASSIFICATION_SPOOFED]" || bad "tenant spoof non refusé: $OUT"

echo ""
echo "=== 5. API NON GOUVERNÉE : renommer l'API vers un nom absent du registre → UNGOVERNED ==="
WS="$(prep "$ACC")"
sed -i '' 's/^name: accounts-read.*/name: accounts-secret/' "$WS"/api.yaml 2>/dev/null || sed -i 's/^name: accounts-read.*/name: accounts-secret/' "$WS"/api.yaml
sed -i '' 's/^name: accounts-read.*/name: accounts-secret/' "$WS"/target.yaml 2>/dev/null || sed -i 's/^name: accounts-read.*/name: accounts-secret/' "$WS"/target.yaml
OUT="$(applyc "$WS" accounts-team)"; RC=$?
[ "$RC" != 0 ] && grep -q "CLASSIFICATION_UNGOVERNED" <<<"$OUT" && ok "API non enregistrée refusée [CLASSIFICATION_UNGOVERNED]" || bad "API non gouvernée non refusée: $OUT"

echo ""
echo "=== 6. ANCRAGE (review S2) : un governance/ glissé dans le repo PROJET est IGNORÉ ==="
WS="$(prep "$ACC")"
# l'équipe plante un faux registre affaiblissant DANS son workspace projet…
mkdir -p "$WS"/governance
cat > "$WS"/governance/classifications.yaml <<'FAKE'
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: accounts-team, tenant: banking-demo, api: accounts-read, classification: M, exposure: internal}
FAKE
# …et downgrade son api.yaml en M pour matcher son faux registre.
sed -i '' 's/^classification: VH.*/classification: M/' "$WS"/api.yaml 2>/dev/null || sed -i 's/^classification: VH.*/classification: M/' "$WS"/api.yaml
# Le pipeline pointe TOUJOURS le registre PLATEFORME (chemin absolu) → le faux est ignoré.
OUT="$(applyc "$WS" accounts-team)"; RC=$?
[ "$RC" != 0 ] && grep -q "CLASSIFICATION_SPOOFED" <<<"$OUT" && ok "faux governance/ projet IGNORÉ — le central plateforme (VH) fait foi, downgrade refusé" || bad "le faux registre projet a été pris en compte (ancrage cassé !): $OUT"

echo ""
echo "=== 7. NON-RÉGRESSION A1 : SANS source, l'api.yaml projet pilote (VH) ==="
WS="$(prep "$ACC")"; OUT="$(applya1 "$WS")"
grep -qE "classification=VH .*policies=\[.*mtls.*\]" <<<"$OUT" && ok "sans source → A1 (classification projet VH, inchangé)" || bad "régression A1: $(grep Enforcement <<<"$OUT")"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
