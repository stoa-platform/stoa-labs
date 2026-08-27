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

echo "== ⑥ vault.yml : write tenant PAR PALIER, plus d'apps/* nu =="
VY="ansible/roles/apim_team_onboard/tasks/vault.yml"
sed 's/[[:space:]]*#.*$//' "$VY" > "$TMP/vy_nc"
# ANCRAGE sur les seules lignes portant `create` (précaution du plan) : une ligne
# READ restée en « …/apps/* » serait légitime — les métadonnées ne sont pas le
# secret. C'est le CREATE qui est resserré, lui seul est asserté ici.
grep 'create' "$TMP/vy_nc" > "$TMP/vy_cr"
grep -q 'apps/\*"' "$TMP/vy_cr" \
  && bad "⑥ un write apps/* NU subsiste dans la policy tenant (trou trans-env)" \
  || ok "⑥ plus aucun write apps/* nu dans vault.yml"
grep -q 'apim_onb_write_envs' "$TMP/vy_nc" \
  && ok "⑥bis la policy write est bouclée sur apim_onb_write_envs" \
  || bad "⑥bis apim_onb_write_envs n'apparaît pas — la boucle par palier n'existe pas"
grep -q 'apps/+/' "$TMP/vy_nc" \
  && ok "⑥ter le motif apps/+/<env>/ est présent (segment app wildcardé, env fixé)" \
  || bad "⑥ter le motif apps/+/<env>/ absent"
# Mutation. Sans elle, ⑥ passerait aussi bien sur un fichier VIDE ou un chemin
# faux : le détecteur doit voir rouge quand le write nu revient.
sed 's|/apps/+/[^/]*/|/apps/|g' "$VY" > "$TMP/vy_mut"
sed 's/[[:space:]]*#.*$//' "$TMP/vy_mut" > "$TMP/vy_mut_nc"
grep 'create' "$TMP/vy_mut_nc" > "$TMP/vy_mut_cr"
grep -q 'apps/\*"' "$TMP/vy_mut_cr" \
  && ok "⑥quater le retour à apps/* nu est DÉTECTÉ — l'épreuve ⑥ n'est pas vacante" \
  || bad "⑥quater la mutation ne produit pas de write nu — ⑥ est un vert vacant"

echo "== ⑦ le défaut d'apim_onb_write_envs est FAIL-CLOSED =="
python3 - "ansible/roles/apim_team_onboard/defaults/main.yml" <<'PY' >"$TMP/p7" 2>&1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
v = d.get("apim_onb_write_envs")
assert v == ["dev"], f"apim_onb_write_envs={v!r} (attendu ['dev'] fail-closed)"
print("OK")
PY
grep -q '^OK$' "$TMP/p7" \
  && ok "⑦ défaut ['dev'] — un appel sans la var reste au palier d'authoring" \
  || bad "⑦ $(cat "$TMP/p7")"
# Le playbook, lui, dérive la chaîne : toute invocation documentée passe par lui.
sed 's/[[:space:]]*#.*$//' "ansible/onboard-team.yml" > "$TMP/ot_nc"
grep -q 'env_chain_nonprod' "$TMP/ot_nc" \
  && ok "⑦bis onboard-team.yml dérive apim_onb_write_envs d'env_chain_nonprod" \
  || bad "⑦bis le playbook ne dérive pas la liste — la voie consommateur hors-prod régresserait"

echo "== ⑧ user-deploy (voie B) : même resserrage =="
UVJ="scripts/setup-user-vault-jwt.sh"
sed 's/[[:space:]]*#.*$//' "$UVJ" > "$TMP/uvj_nc"
# Même ancrage sur `create` qu'en ⑥, et pour la même raison.
grep 'create' "$TMP/uvj_nc" > "$TMP/uvj_cr"
grep -q 'apps/\*"' "$TMP/uvj_cr" \
  && bad "⑧ un write apps/* nu subsiste dans la policy user-deploy" \
  || ok "⑧ plus d'apps/* nu dans user-deploy"
grep -q 'env_chain_nonprod' "$TMP/uvj_nc" \
  && ok "⑧bis la liste des paliers est dérivée au setup (env_chain_nonprod)" \
  || bad "⑧bis pas de dérivation de chaîne dans setup-user-vault-jwt.sh"
# Mutation, même rôle qu'en ⑥quater.
sed 's|/apps/+/[^/]*/|/apps/|g' "$UVJ" > "$TMP/uvj_mut"
sed 's/[[:space:]]*#.*$//' "$TMP/uvj_mut" > "$TMP/uvj_mut_nc"
grep 'create' "$TMP/uvj_mut_nc" > "$TMP/uvj_mut_cr"
grep -q 'apps/\*"' "$TMP/uvj_mut_cr" \
  && ok "⑧ter le retour à apps/* nu est DÉTECTÉ côté voie B — ⑧ n'est pas vacante" \
  || bad "⑧ter la mutation ne produit pas de write nu — ⑧ est un vert vacant"

echo "== ⑨ une liste de paliers VIDE est refusée côté voie A (miroir de l'assert voie B) =="
# Statique et sans ansible : la porte doit rester jouable sur un poste qui n'a
# que bash + python3 (comme ①-⑧). Le comportement de l'assert lui-même a été
# exercé pour de vrai avec ansible-playbook hors porte (cf. rapport de tâche).
cat > "$TMP/chk9.py" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
a = [t for t in tasks if isinstance(t, dict) and "ansible.builtin.assert" in t]
assert a, "aucune tache assert dans le fichier"
cond = " ".join(str(t["ansible.builtin.assert"].get("that")) for t in a)
assert "apim_onb_write_envs" in cond, "aucun assert ne porte sur apim_onb_write_envs"
assert "length > 0" in cond, "l'assert ne borne pas la liste par sa longueur"
print("OK")
PY
python3 "$TMP/chk9.py" "$VY" >"$TMP/p9" 2>&1
grep -q '^OK$' "$TMP/p9" \
  && ok "⑨ vault.yml refuse une liste vide — la policy ne peut pas devenir muette en écriture" \
  || bad "⑨ $(tail -1 "$TMP/p9")"
# Mutation : retirer l'assert d'une copie ⇒ le détecteur DOIT voir rouge.
python3 - "$VY" "$TMP/vy_noassert" <<'PY'
import sys, yaml
tasks = [t for t in yaml.safe_load(open(sys.argv[1]))
         if not (isinstance(t, dict) and "ansible.builtin.assert" in t)]
yaml.safe_dump(tasks, open(sys.argv[2], "w"))
PY
python3 "$TMP/chk9.py" "$TMP/vy_noassert" >"$TMP/p9m" 2>&1
grep -q '^OK$' "$TMP/p9m" \
  && bad "⑨bis l'assert retiré passe quand même — ⑨ est un vert vacant" \
  || ok "⑨bis retirer l'assert est DÉTECTÉ — ⑨ n'est pas vacante"

printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
