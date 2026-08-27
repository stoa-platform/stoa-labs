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

# ── ⑥quinquies : le RENDU, pas la forme ──────────────────────────────────────
# ⑥/⑥bis/⑥ter prouvent qu'un MOTIF est dans le fichier. Ils ne prouvent pas la
# propriété D3 : « le terminus n'est inscriptible nulle part ». On rend donc le
# scalaire Jinja avec la liste réellement dérivée d'une chaîne JETABLE, et on
# asserte le résultat. Les deux volets comptent : sans le volet positif
# (alpha/beta présents), un rendu VIDE passerait — vert vacant.
NONPROD3=$(STOA_ENV_CHAIN_FILE="$TMP/chain3.yaml" bash -c '. scripts/lib/env-chain.sh && env_chain_nonprod')
cat > "$TMP/render_vy.py" <<'PYR'
import sys, yaml, jinja2
tasks = yaml.safe_load(open(sys.argv[1]))
pol = next(t["ansible.builtin.uri"]["body"]["policy"] for t in tasks
           if isinstance(t.get("ansible.builtin.uri"), dict)
           and isinstance(t["ansible.builtin.uri"].get("body"), dict)
           and "policy" in t["ansible.builtin.uri"]["body"])
# trim_blocks=True : le reglage du Templar d'Ansible (sinon la ligne du {% for %}
# laisserait un saut de ligne que le vrai rendu n'a pas).
env = jinja2.Environment(trim_blocks=True)
sys.stdout.write(env.from_string(pol).render(
    apim_ss_vault_kv_mount="secret", onb_tenant_root="stoa/deploy/t",
    onb={"team": "t"}, apim_onb_write_envs=sys.argv[2:]))
PYR
# $NONPROD3 non quoté : le découpage par mots est l'effet voulu (un argv par palier).
# shellcheck disable=SC2086
python3 "$TMP/render_vy.py" "$VY" $NONPROD3 > "$TMP/rvy" 2>&1
grep 'create' "$TMP/rvy" > "$TMP/rvy_cr"
grep -q '/gamma/' "$TMP/rvy_cr" \
  && bad "⑥quinquies le TERMINUS gamma est inscriptible dans le rendu — D3 est violée" \
  || ok "⑥quinquies rendu : aucune ligne create ne porte le terminus gamma"
grep -q '/alpha/' "$TMP/rvy_cr" && grep -q '/beta/' "$TMP/rvy_cr" \
  && ok "⑥quinquies(b) rendu : alpha ET beta sont bien inscriptibles (le rendu n'est pas vide)" \
  || bad "⑥quinquies(b) rendu sans ligne create pour alpha/beta : $(tail -1 "$TMP/rvy")"
# Mutation : rendre avec la chaîne ENTIÈRE (terminus compris) ⇒ le détecteur DOIT voir.
python3 "$TMP/render_vy.py" "$VY" alpha beta gamma > "$TMP/rvy_mut" 2>&1
grep 'create' "$TMP/rvy_mut" > "$TMP/rvy_mut_cr"
grep -q '/gamma/' "$TMP/rvy_mut_cr" \
  && ok "⑥quinquies(c) un terminus dans la liste rend une ligne create — l'épreuve n'est pas vacante" \
  || bad "⑥quinquies(c) même avec gamma dans la liste, rien n'est détecté — ⑥quinquies est un vert vacant"

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

# ── ⑦ter : l'assert de liste non vide existe ET EST AU BON ENDROIT ───────────
# Un grep dit qu'un assert EXISTE, jamais qu'il PRÉCÈDE ce qu'il protège. Placé
# après la tâche uri, le refus tombe quand la policy est DÉJÀ chez Vault. Même
# motif que scripts/lib/import-guard-probe.py (épreuve ⑮ de G3), même séparateur
# \x1f : le champ `that:` porte lui-même des filtres Jinja (`| default([]) |
# length > 0`), un séparateur '|' collisionnerait avec son contenu.
US=$'\x1f'
WV=$(VY="$VY" python3 scripts/lib/write-envs-guard-probe.py) \
  || bad "⑦ter PARSE_VAULT : vault.yml illisible par la sonde"
case "$WV" in
  W=*)
    WVR="${WV#W=}"
    W_THAT="${WVR%%"$US"*}"; WVR="${WVR#*"$US"}"
    W_HASPOL="${WVR%%"$US"*}"; W_BEFORE="${WVR#*"$US"}"
    case "$W_THAT" in
      *apim_onb_write_envs*length*) ok "⑦ter un assert borne la LONGUEUR d'apim_onb_write_envs" ;;
      "")  bad "⑦ter aucun assert ne porte sur apim_onb_write_envs — une liste vide rendrait la policy muette en écriture" ;;
      *)   bad "⑦ter l'assert porte « $W_THAT » — il ne borne pas la longueur de la liste" ;;
    esac
    [ "$W_HASPOL" = 1 ] \
      && ok "⑦ter(b) la tâche qui POSE la policy est repérée par sa structure (uri + body.policy)" \
      || bad "⑦ter(b) aucune tâche uri ne porte body.policy — la sonde ne mesure rien"
    [ "$W_BEFORE" = 1 ] \
      && ok "⑦ter(c) l'assert PRÉCÈDE la pose de la policy" \
      || bad "⑦ter(c) l'assert vient APRÈS la policy — elle serait déjà partie chez Vault quand le refus tombe"
    ;;
  *) bad "⑦ter sortie de sonde inattendue : $WV" ;;
esac
# Mutations. La première (retirer l'assert) éprouve ⑦ter ; la SECONDE (le
# déplacer après la policy) éprouve ⑦ter(c), qui sinon n'aurait jamais été vu
# que dans le sens qui passe.
python3 - "$VY" "$TMP/vy_noassert" "$TMP/vy_late" <<'PYM'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
def is_guard(t):
    return isinstance(t, dict) and "apim_onb_write_envs" in str(
        (t.get("ansible.builtin.assert") or {}).get("that") or "")
kept = [t for t in tasks if not is_guard(t)]
yaml.safe_dump(kept, open(sys.argv[2], "w"))
yaml.safe_dump(kept + [t for t in tasks if is_guard(t)], open(sys.argv[3], "w"))
PYM
W_NO=$(VY="$TMP/vy_noassert" python3 scripts/lib/write-envs-guard-probe.py)
case "$W_NO" in
  "W=$US"*"${US}0") ok "⑦quater retirer l'assert est DÉTECTÉ (that vide, précède=0)" ;;
  *) bad "⑦quater l'assert retiré passe quand même — ⑦ter est un vert vacant : $W_NO" ;;
esac
W_LATE=$(VY="$TMP/vy_late" python3 scripts/lib/write-envs-guard-probe.py)
case "$W_LATE" in
  *"${US}0") ok "⑦quater(b) déplacer l'assert APRÈS la policy est DÉTECTÉ" ;;
  *) bad "⑦quater(b) l'assert déplacé après la policy passe encore — ⑦ter(c) est un vert vacant : $W_LATE" ;;
esac

# ── ⑦quinquies : la SOURCE de chaîne est nommée par les deux écrivains ───────
# Le repli d'env-chain.sh sur clients/_example/environments.yaml est fail-OPEN
# pour un client dont la chaîne est plus courte : le dernier palier du gabarit
# n'est pas son terminus, il deviendrait inscriptible SANS SYMPTÔME. On ne
# refuse pas le repli (le gabarit est la source déclarée du lab) — on exige que
# la source réellement lue soit NOMMÉE dans la sortie des deux poseurs de policy.
# Grep sur code décommenté : les commentaires d'avertissement citent eux aussi
# STOA_ENV_CHAIN_FILE, et un commentaire ne s'imprime dans aucun log.
sed 's/[[:space:]]*#.*$//' "scripts/setup-user-vault-jwt.sh" > "$TMP/uvj_nc0"
grep -q 'STOA_ENV_CHAIN_FILE' "$TMP/ot_nc" \
  && ok "⑦quinquies onboard-team.yml NOMME la source de chaîne dans le log du play" \
  || bad "⑦quinquies onboard-team.yml n'imprime pas sa source — rien ne distingue la chaîne du client du gabarit d'exemple"
grep -q 'STOA_ENV_CHAIN_FILE' "$TMP/uvj_nc0" \
  && ok "⑦quinquies(b) setup-user-vault-jwt.sh NOMME la source de chaîne" \
  || bad "⑦quinquies(b) setup-user-vault-jwt.sh n'imprime pas sa source"

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

# ── ⑧quater : le RENDU de la voie B ──────────────────────────────────────────
# Les deux voies sont un miroir de PÉRIMÈTRE, PAS de code : ici c'est un gabarit
# python qui construit des chaînes, là-bas une boucle Jinja. Un défaut de l'un
# ne se verrait donc pas dans l'autre — on rend les DEUX, jamais un seul.
# Le gabarit est EXTRAIT du script livré (pas recopié) : il ne peut pas dériver.
python3 - "$UVJ" "$TMP/uvj_tpl.py" <<'PYX'
import sys, io
s = io.open(sys.argv[1], encoding="utf-8").read()
i = s.index("/tmp/uvj-pol.json <<'" + "PY'")
j = s.index("\n", i) + 1
k = s.index("\n" + "PY\n", j) + 1
io.open(sys.argv[2], "w", encoding="utf-8").write(s[j:k])
PYX
# shellcheck disable=SC2086
python3 "$TMP/uvj_tpl.py" "secret/data/stoa/deploy/T" "secret/metadata/stoa/deploy/T" $NONPROD3 > "$TMP/ruvj.json" 2>"$TMP/ruvj.err"
python3 -c 'import json,sys;sys.stdout.write(json.load(open(sys.argv[1]))["policy"])' "$TMP/ruvj.json" > "$TMP/ruvj" 2>&1
grep 'create' "$TMP/ruvj" > "$TMP/ruvj_cr"
grep -q '/gamma/' "$TMP/ruvj_cr" \
  && bad "⑧quater le TERMINUS gamma est inscriptible côté voie B — D3 est violée par la porte SSO" \
  || ok "⑧quater rendu voie B : aucune ligne create ne porte le terminus gamma"
grep -q '/alpha/' "$TMP/ruvj_cr" && grep -q '/beta/' "$TMP/ruvj_cr" \
  && ok "⑧quater(b) rendu voie B : alpha ET beta inscriptibles (le rendu n'est pas vide)" \
  || bad "⑧quater(b) rendu voie B sans ligne create : $(tail -1 "$TMP/ruvj") $(tail -1 "$TMP/ruvj.err")"
# Mutation : la chaîne ENTIÈRE ⇒ le détecteur DOIT voir le terminus.
python3 "$TMP/uvj_tpl.py" "secret/data/stoa/deploy/T" "secret/metadata/stoa/deploy/T" alpha beta gamma > "$TMP/ruvj_mut.json" 2>&1
python3 -c 'import json,sys;sys.stdout.write(json.load(open(sys.argv[1]))["policy"])' "$TMP/ruvj_mut.json" > "$TMP/ruvj_mut" 2>&1
grep 'create' "$TMP/ruvj_mut" > "$TMP/ruvj_mut_cr"
grep -q '/gamma/' "$TMP/ruvj_mut_cr" \
  && ok "⑧quater(c) un terminus dans la liste rend une ligne create côté voie B — l'épreuve n'est pas vacante" \
  || bad "⑧quater(c) même avec gamma, rien n'est détecté — ⑧quater est un vert vacant"
# La garde liste-vide du gabarit doit survivre à PYTHONOPTIMIZE=1 : un `assert`
# python DISPARAÎT du bytecode sous -O, et la garde avec lui, en silence.
PYTHONOPTIMIZE=1 python3 "$TMP/uvj_tpl.py" "d" "m" >"$TMP/uvj_opt" 2>&1
[ -s "$TMP/uvj_opt" ] && ! grep -q '"policy"' "$TMP/uvj_opt" \
  && ok "⑧quater(d) la garde liste-vide tient sous PYTHONOPTIMIZE=1 (pas un assert)" \
  || bad "⑧quater(d) sous PYTHONOPTIMIZE=1 le gabarit produit une policy sans aucune ligne create — garde supprimée par -O"

printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
