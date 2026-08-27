#!/usr/bin/env bash
# test-palier-retention.sh — porte hors-ligne G4 (ADR-082) : le plan de
# credential par palier, le scellement de l'axe env, les protections Gitea.
# Discipline héritée de test-deploy-pin.sh : capture fichier jamais pipe
# (pipefail), grep sur code DÉCOMMENTÉ, chaque garde mutée, sabotage qui
# OUVRE la porte, restauration vérifiée.
# `A && ok || bad` (SC2015) est l'idiome des scripts de preuve du repo (cf.
# test-vault-user-login.sh, test-voie-a-cluster.sh) ; le pattern sed en
# single-quote de l'épreuve ③bis porte un $1 LITTÉRAL, pas une expansion
# voulue (SC2016) ; l'épreuve ④ relit $? juste après la redirection du
# sous-shell qui le produit (SC2181), lecture immédiate et non ambiguë ici.
# shellcheck disable=SC2015,SC2016,SC2181
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck disable=SC2034  # documente la racine résolue (convention test-env-chain.sh) ; non consommée par les épreuves ci-dessous.
ROOT="$(pwd)"

PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM; umask 077

SVP="scripts/setup-vault-paliers.sh"

# Chaîne JETABLE à trois paliers : l'épreuve ne dépend pas du gabarit livré.
cat > "$TMP/chain3.yaml" <<'EOF'
environments: [alpha, beta, gamma]
gates: []
EOF
cat > "$TMP/chain2.yaml" <<'EOF'
environments: [alpha, gamma]
gates: []
EOF

echo "== ① --print dérive une policy par palier NON terminal =="
( STOA_ENV_CHAIN_FILE="$TMP/chain3.yaml" bash "$SVP" --print ) >"$TMP/p1" 2>&1
RC=$?
[ "$RC" -eq 0 ] || bad "① --print sort $RC (attendu 0)"
grep -q 'apply-alpha' "$TMP/p1" && grep -q 'apply-beta' "$TMP/p1" \
  && ok "① policies apply-alpha et apply-beta émises" \
  || bad "① policies des paliers non terminaux absentes de --print"
grep -q 'apply-gamma' "$TMP/p1" \
  && bad "① le TERMINUS gamma a une policy — l'exclusion structurelle a sauté" \
  || ok "① le terminus gamma n'a ni policy ni AppRole (structurel)"
grep -q 'envs/alpha/wm-admin' "$TMP/p1" \
  && ok "① le périmètre est le secret d'admin du palier" \
  || bad "① le chemin envs/<e>/wm-admin n'apparaît pas dans la policy"

echo "== ② la dérivation SUIT la source (chaîne réduite ⇒ set réduit) =="
( STOA_ENV_CHAIN_FILE="$TMP/chain2.yaml" bash "$SVP" --print ) >"$TMP/p2" 2>&1
grep -q 'apply-alpha' "$TMP/p2" && ! grep -q 'apply-beta' "$TMP/p2" \
  && ok "② chain2 ⇒ apply-alpha seul (beta a disparu avec la chaîne)" \
  || bad "② le set de policies ne suit pas la source de chaîne"

echo "== ③ aucun wildcard multi-palier envs/+ =="
grep -q 'envs/+' "$TMP/p1" \
  && bad "③ un wildcard envs/+ est émis — la rétention par palier est trouée" \
  || ok "③ aucun envs/+ dans ce que le poseur émet"
# Mutation : injecter le wildcard dans une copie sabotée, le détecteur DOIT voir.
# (ancré sur la forme CONTRACTUELLE de policy_hcl : interpolation directe de $1)
sed 's|envs/\$1/wm-admin|envs/+/wm-admin|g' "$SVP" > "$TMP/svp_mut"
( STOA_ENV_CHAIN_FILE="$TMP/chain3.yaml" bash "$TMP/svp_mut" --print ) >"$TMP/p3" 2>&1
grep -q 'envs/+' "$TMP/p3" \
  && ok "③bis la mutation wildcard est DÉTECTABLE (le détecteur verrait rouge)" \
  || bad "③bis la mutation n'a pas produit de wildcard — l'épreuve ③ ne protège rien (vert vacant)"

echo "== ④ --print est hors-ligne et ne mint RIEN =="
( STOA_ENV_CHAIN_FILE="$TMP/chain3.yaml" VAULT_ADDR="http://127.0.0.1:1" bash "$SVP" --print ) >"$TMP/p4" 2>&1
[ $? -eq 0 ] \
  && ok "④ --print réussit avec un VAULT_ADDR mort — aucun réseau" \
  || bad "④ --print touche le réseau (échec avec VAULT_ADDR mort)"
grep -qi 'secret_id' "$TMP/p4" \
  && bad "④bis --print émet un secret_id — le mode hors-ligne mint" \
  || ok "④bis aucun secret_id émis par --print"

echo "== ⑤ terminus exclu par STRUCTURE (env_chain_nonprod, pas un nom) =="
sed 's/env_chain_nonprod/env_chain/g' "$SVP" > "$TMP/svp_mut5"
( STOA_ENV_CHAIN_FILE="$TMP/chain3.yaml" bash "$TMP/svp_mut5" --print ) >"$TMP/p5" 2>&1
grep -q 'apply-gamma' "$TMP/p5" \
  && ok "⑤ muter env_chain_nonprod→env_chain fait apparaître le terminus : l'épreuve ① le verrait" \
  || bad "⑤ la mutation ne change rien — l'exclusion du terminus ne vient pas de la dérivation (vert vacant)"

printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
