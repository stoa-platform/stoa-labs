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

echo "== ⑨a scellement publication : ENVN vient de la constante, plus du job =="
for F in scripts/team-publish.sh scripts/api-request.sh scripts/setup-team-onboard-jobs.sh; do
  sed 's/[[:space:]]*#.*$//' "$F" > "$TMP/nc9"
  grep -q 'ENVN="\$DEPLOY_PIN_AUTHORING_ENV"' "$TMP/nc9" \
    && ok "⑨a $F scelle ENVN sur DEPLOY_PIN_AUTHORING_ENV" \
    || bad "⑨a $F ne scelle pas ENVN"
  grep -q 'ENVN="\${ENVN:-' "$TMP/nc9" \
    && bad "⑨a $F garde un défaut surchargeable ENVN:- (l'env du job décide encore)" \
    || ok "⑨a $F n'a plus de défaut surchargeable"
  # UNICITÉ de l'affectation. Les deux greps ci-dessus restent verts si une
  # SECONDE affectation de ENVN apparaît plus bas (réaffectation, ou passage
  # d'env à un enfant `ENVN="$ENVN" bash …`) : le scellement serait alors
  # contourné sans qu'aucun voyant ne s'allume. Le compte le refuse.
  N9=$(grep -c 'ENVN=' "$TMP/nc9")
  [ "$N9" -eq 1 ] \
    && ok "⑨a $F ne porte QU'UNE affectation ENVN= — le scellement est la seule" \
    || bad "⑨a $F porte $N9 lignes ENVN= (attendu 1) — une seconde affectation contourne le scellement"
done
# Détecteur d'axe env dans un Jenkinsfile, TROIS verdicts — factorisé exprès
# pour que la contre-épreuve ⑩bis exerce EXACTEMENT le code que ⑨a utilise, et
# non une copie qui pourrait diverger de lui en silence.
#
# ⚠ Le verdict ABSENT est la correction d'un vert VACANT (mesuré en revue) :
# sans lui, un $JF introuvable faisait sortir sed en 1 en laissant un rendu
# VIDE ; le grep d'ABSENCE n'y trouvait évidemment rien et l'épreuve passait au
# vert sans avoir RIEN regardé. Renommer le Jenkinsfile gardait ⑨a verte.
#
# Le NOM de l'axe est un paramètre (défaut ENVN) : ⑰ scelle le MÊME genre d'axe
# sur un autre nom (REQ_ENV, côté demande). Un second détecteur copié-collé
# aurait pu diverger de celui-ci en silence — c'est exactement ce que la
# factorisation existe pour empêcher.
jf_axe_verdict(){ # <chemin> [axe=ENVN] -> ABSENT | ROUTE | PROPRE
  [ -f "$1" ] || { printf 'ABSENT\n'; return; }
  sed 's|[[:space:]]*//.*$||' "$1" > "$TMP/jf9"
  grep -q "${2:-ENVN}" "$TMP/jf9" && printf 'ROUTE\n' || printf 'PROPRE\n'
}
for JF in ci/Jenkinsfile.team-publish ci/Jenkinsfile.api-request; do
  case "$(jf_axe_verdict "$JF")" in
    ABSENT) bad "⑨a $JF introuvable — l'assertion d'absence serait vraie par vacuité" ;;
    ROUTE)  bad "⑨a $JF route encore un axe ENVN vers le script" ;;
    PROPRE) ok  "⑨a $JF ne route plus d'axe env" ;;
  esac
done

echo "== ⑩ mutation : remettre le défaut surchargeable ⇒ l'épreuve ⑨a rougirait =="
sed 's/ENVN="\$DEPLOY_PIN_AUTHORING_ENV"/ENVN="\${ENVN:-dev}"/' scripts/team-publish.sh > "$TMP/tp_mut"
sed 's/[[:space:]]*#.*$//' "$TMP/tp_mut" > "$TMP/tp_mut_nc"
grep -q 'ENVN="\${ENVN:-' "$TMP/tp_mut_nc" \
  && ok "⑩ la mutation réintroduit le défaut et le détecteur ⑨a le verrait" \
  || bad "⑩ la mutation n'a rien changé — ⑨a est un vert vacant"

echo "== ⑩bis mutation de l'axe Jenkinsfile : les DEUX façons de rendre ⑨a vacante =="
# (a) l'axe REVIENT dans le code du Jenkinsfile — à sa place réelle, dans le
# bloc `environment`, pas en queue de fichier : le détecteur doit le VOIR.
AXE='    ENVN = "${env.ENVN ?: '\''dev'\''}"'
awk -v l="$AXE" '{print} /^  environment \{/ && !d {print l; d=1}' \
  ci/Jenkinsfile.team-publish > "$TMP/jf_mut"
# ⚠ ANTI-NO-OP par `cmp`, PAS par un grep du fichier brut. Ce contrôle lisait
# naguère `grep -q 'ENVN' "$TMP/jf_mut"` sur le fichier BRUT — or le Jenkinsfile
# porte depuis G4 un COMMENTAIRE « … SCELLE ENVN » (ligne 105) : le grep matchait
# donc TOUJOURS, ancre awk cassée ou non, et l'anti-no-op était vacant à son tour
# (la classe de bug de ⑨a, une marche plus haut — mesuré : ancre inexistante ⇒
# mutant identique au réel ⇒ l'ancien a0 rendait quand même ok). `cmp` compare
# les octets : il ne peut pas être satisfait par de la prose.
cmp -s ci/Jenkinsfile.team-publish "$TMP/jf_mut" \
  && bad "⑩bis(a0) le mutant est IDENTIQUE au fichier — l'ancre ^  environment { a bougé, la mutation ne mute rien" \
  || ok "⑩bis(a0) le mutant diffère RÉELLEMENT du fichier (la mutation n'est pas un no-op)"
[ "$(jf_axe_verdict "$TMP/jf_mut")" = ROUTE ] \
  && ok "⑩bis(a) axe env réinjecté ⇒ le détecteur de ⑨a REND ROUTE (il n'est pas aveugle)" \
  || bad "⑩bis(a) l'axe réinjecté passe inaperçu — l'assertion Jenkinsfile de ⑨a est vacante"
# (b) le fichier DISPARAÎT — le cas qui passait au vert avant la garde.
[ "$(jf_axe_verdict "ci/Jenkinsfile.NEXISTE-PAS")" = ABSENT ] \
  && ok "⑩bis(b) Jenkinsfile absent ⇒ ABSENT (refus), plus jamais un vert par vacuité" \
  || bad "⑩bis(b) un Jenkinsfile absent ne déclenche pas le refus — la garde d'existence ne tient pas"

echo "== ⑩ter mutation : une SECONDE affectation ENVN= ⇒ l'unicité de ⑨a rougirait =="
# La mutation reproduit EXACTEMENT le câblage mort retiré de team-publish.sh :
# l'env repassé à un enfant. C'est le contournement réaliste, et il est
# INVISIBLE pour les deux premiers greps de ⑨a — d'où l'assertion d'unicité.
cp scripts/team-publish.sh "$TMP/tp_dup"
printf '     ENVN="$ENVN" bash scripts/setup-team-onboard-jobs.sh\n' >> "$TMP/tp_dup"
sed 's/[[:space:]]*#.*$//' "$TMP/tp_dup" > "$TMP/tp_dup_nc"
NDUP=$(grep -c 'ENVN=' "$TMP/tp_dup_nc")
[ "$NDUP" -eq 2 ] \
  && ok "⑩ter seconde affectation ⇒ compte 2 : le détecteur d'unicité la verrait" \
  || bad "⑩ter le compte reste $NDUP — l'assertion d'unicité de ⑨a est vacante"
# Contre-preuve du BESOIN de l'unicité : sur cette même mutation, les deux
# autres greps de ⑨a restent VERTS. Sans le compte, le contournement passait.
grep -q 'ENVN="\${ENVN:-' "$TMP/tp_dup_nc" \
  && bad "⑩ter(b) la mutation a introduit un défaut surchargeable — ce n'est pas le contournement visé" \
  || ok "⑩ter(b) ce contournement ne porte AUCUN défaut surchargeable : seule l'unicité pouvait l'attraper"


# ── Décommenteur STRICT, partagé par ⑨b et ⑪ ────────────────────────────────
# PAS le `sed 's/[[:space:]]*#.*$//'` des épreuves du dessus : `[[:space:]]*`
# accepte ZÉRO blanc avant le `#`, donc il coupe aussi au `#` d'une EXPANSION DE
# PARAMÈTRE. Mesuré sur team-apply.sh :
#   REST="${PR_BRANCH#onboard/}"; ENVN="${REST##*-}"; TEAM="${REST%-*}"
# est tronqué à `REST="${PR_BRANCH` — l'affectation ENVN= qu'on veut COMPTER
# disparaît, le compte tombe à 0 et l'assertion d'unicité devient vraie par
# vacuité. Ici le `#` doit être en TÊTE DE LIGNE ou précédé d'un blanc, ce qui
# est la forme de tous les commentaires de ces deux fichiers (vérifié : ce motif
# ne laisse AUCUNE ligne de commentaire résiduelle dans l'un ni dans l'autre).
nc_strict(){ sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]][[:space:]]*#.*$//' "$1"; }

echo "== ⑨b scellement demande : REQ_ENV vient de la constante, plus du formulaire =="
nc_strict scripts/team-request.sh > "$TMP/tr_nc"
grep -q 'REQ_ENV="\$DEPLOY_PIN_AUTHORING_ENV"' "$TMP/tr_nc" \
  && ok "⑨b team-request scelle REQ_ENV sur DEPLOY_PIN_AUTHORING_ENV" \
  || bad "⑨b team-request ne scelle pas REQ_ENV"
grep -q 'REQ_ENV="\${REQ_ENV:-' "$TMP/tr_nc" \
  && bad "⑨b team-request garde un défaut surchargeable REQ_ENV:- (le formulaire décide encore)" \
  || ok "⑨b team-request n'a plus de défaut surchargeable"
grep -q 'ENV_NOT_OPEN' "$TMP/tr_nc" \
  && bad "⑨b ENV_NOT_OPEN subsiste dans team-request — le refus n'a plus d'objet une fois l'axe scellé" \
  || ok "⑨b ENV_NOT_OPEN a disparu de team-request (plus de choix à refuser)"
# UNICITÉ, adaptée au compte RÉEL de ce fichier — 2, pas 1 comme en ⑨a : le
# scellement, ET le passage de la valeur SCELLÉE à python3 pour le TITRE de la
# PR (`REQ_ENV="$REQ_ENV" python3 -`). Cette seconde ligne ne réaffecte rien,
# elle propage ; la nommer ici évite de la confondre avec un contournement.
NTR=$(grep -c 'REQ_ENV=' "$TMP/tr_nc")
[ "$NTR" -eq 2 ] \
  && ok "⑨b team-request porte exactement 2 lignes REQ_ENV= (le scellement + la propagation au titre de PR)" \
  || bad "⑨b team-request porte $NTR lignes REQ_ENV= (attendu 2) — une ligne de plus réaffecte l'env APRÈS le scellement"
[ "$(grep -c 'REQ_ENV="\$REQ_ENV" python3' "$TMP/tr_nc")" -eq 1 ] \
  && ok "⑨b la seconde ligne EST la propagation à python3 (donc les 2 lignes sont bien celles attendues)" \
  || bad "⑨b la propagation à python3 n'est plus la seconde ligne REQ_ENV= — le compte de 2 couvre autre chose"

echo "== ⑨bter mutations : les trois façons de rendre ⑨b vacante =="
# (a) le défaut surchargeable REVIENT (miroir de ⑩ pour team-publish).
sed 's/REQ_ENV="\$DEPLOY_PIN_AUTHORING_ENV"/REQ_ENV="\${REQ_ENV:-dev}"/' scripts/team-request.sh > "$TMP/tr_mut"
cmp -s scripts/team-request.sh "$TMP/tr_mut" \
  && bad "⑨bter(a0) le mutant est IDENTIQUE au fichier — l'ancre du scellement a bougé, la mutation ne mute rien" \
  || ok "⑨bter(a0) le mutant diffère RÉELLEMENT du fichier (la mutation n'est pas un no-op)"
nc_strict "$TMP/tr_mut" > "$TMP/tr_mut_nc"
grep -q 'REQ_ENV="\${REQ_ENV:-' "$TMP/tr_mut_nc" \
  && ok "⑨bter(a) le défaut réintroduit ⇒ le détecteur de ⑨b le VOIT" \
  || bad "⑨bter(a) le défaut réintroduit passe inaperçu — l'assertion de ⑨b est vacante"
# (b) une TROISIÈME ligne REQ_ENV= : la réaffectation silencieuse après le
# scellement, invisible pour les greps de présence/absence.
cp scripts/team-request.sh "$TMP/tr_dup"
printf 'REQ_ENV="${REQ_ENV_OVERRIDE:-prod}"\n' >> "$TMP/tr_dup"
nc_strict "$TMP/tr_dup" > "$TMP/tr_dup_nc"
NDUP=$(grep -c 'REQ_ENV=' "$TMP/tr_dup_nc")
[ "$NDUP" -eq 3 ] \
  && ok "⑨bter(b) troisième affectation ⇒ compte 3 : le détecteur d'unicité la verrait" \
  || bad "⑨bter(b) le compte reste $NDUP — l'assertion d'unicité de ⑨b est vacante"
# (c) le décommenteur NAÏF sur ce même fichier : contre-preuve du choix de
# nc_strict — si un `#` d'expansion mangeait la ligne comptée, on le saurait.
sed 's/[[:space:]]*#.*$//' scripts/team-request.sh > "$TMP/tr_naif"
[ "$(grep -c 'REQ_ENV=' "$TMP/tr_naif")" -eq "$NTR" ] \
  && ok "⑨bter(c) sur team-request les deux décommenteurs comptent pareil (aucun # d'expansion sur ces lignes)" \
  || bad "⑨bter(c) les deux décommenteurs divergent sur team-request — le compte dépend du motif, pas du code"

echo "== ⑪ team-apply : ENV_MISMATCH contre la CONSTANTE, pas un littéral =="
nc_strict scripts/team-apply.sh > "$TMP/ta_nc"
grep -q 'ENV_MISMATCH' "$TMP/ta_nc" \
  && ok "⑪ le refus ENV_MISMATCH existe" || bad "⑪ pas de refus ENV_MISMATCH"
grep -Eq '\[ "\$ENVN" = "\$DEPLOY_PIN_AUTHORING_ENV" \]' "$TMP/ta_nc" \
  && ok "⑪bis la comparaison vise la constante d'authoring" \
  || bad "⑪bis la comparaison ne vise pas la constante (littéral ?)"
grep -q 'ENV_NOT_OPEN' "$TMP/ta_nc" \
  && bad "⑪ter ENV_NOT_OPEN subsiste dans team-apply" \
  || ok "⑪ter ENV_NOT_OPEN a disparu de team-apply"
# UNICITÉ côté apply : ici l'env n'est pas scellé mais DÉRIVÉ de la branche
# (`ENVN="${REST##*-}"`) puis confronté à la constante. Une seule ligne ENVN=
# est donc attendue — le repassage `ENVN="$ENVN" bash …` à un enfant qui SCELLE
# déjà le sien (setup-team-onboard-jobs.sh:87) est du câblage mort qui suggère
# le contraire.
NTA=$(grep -c 'ENVN=' "$TMP/ta_nc")
[ "$NTA" -eq 1 ] \
  && ok "⑪quater team-apply ne porte QU'UNE ligne ENVN= (la dérivation depuis la branche) — plus de repassage à un enfant" \
  || bad "⑪quater team-apply porte $NTA lignes ENVN= (attendu 1) — l'env est encore repassé à un enfant qui le scelle lui-même"

echo "== ⑫ mutations : les trois façons de rendre ⑪ vacante =="
# (a) la constante redevient le littéral `dev` — même valeur AUJOURD'HUI, mais
# plus aucun lien avec la source qui la définit.
sed 's/\[ "\$ENVN" = "\$DEPLOY_PIN_AUTHORING_ENV" \]/[ "$ENVN" = dev ]/' scripts/team-apply.sh > "$TMP/ta_mut"
cmp -s scripts/team-apply.sh "$TMP/ta_mut" \
  && bad "⑫(a0) le mutant est IDENTIQUE au fichier — l'ancre de la comparaison a bougé, la mutation ne mute rien" \
  || ok "⑫(a0) le mutant diffère RÉELLEMENT du fichier (la mutation n'est pas un no-op)"
nc_strict "$TMP/ta_mut" > "$TMP/ta_mut_nc"
grep -Eq '\[ "\$ENVN" = "\$DEPLOY_PIN_AUTHORING_ENV" \]' "$TMP/ta_mut_nc" \
  && bad "⑫(a) la mutation n'a pas retiré la constante — le détecteur ⑪bis ne protège rien" \
  || ok "⑫(a) mutation efficace : le détecteur ⑪bis verrait rouge"
# (b) le câblage mort REVIENT — invisible pour ⑪/⑪bis/⑪ter.
cp scripts/team-apply.sh "$TMP/ta_dup"
printf '     ENVN="$ENVN" bash scripts/setup-team-onboard-jobs.sh\n' >> "$TMP/ta_dup"
nc_strict "$TMP/ta_dup" > "$TMP/ta_dup_nc"
NADUP=$(grep -c 'ENVN=' "$TMP/ta_dup_nc")
[ "$NADUP" -eq 2 ] \
  && ok "⑫(b) repassage réinjecté ⇒ compte 2 : le détecteur d'unicité de ⑪quater le verrait" \
  || bad "⑫(b) le compte reste $NADUP — l'assertion d'unicité de ⑪quater est vacante"
# (c) LA raison d'être de nc_strict, prouvée sur le fichier réel : le
# décommenteur naïf tronque la dérivation au `#` de ${PR_BRANCH#onboard/} et
# fait perdre UNE ligne au compte. Écrit ⑪quater avec lui, l'unicité passait au
# vert même avec le câblage mort en place.
sed 's/[[:space:]]*#.*$//' scripts/team-apply.sh > "$TMP/ta_naif"
[ "$(grep -c 'ENVN=' "$TMP/ta_naif")" -lt "$NTA" ] \
  && ok "⑫(c) le décommenteur naïf perd bien la dérivation (# d'expansion) — nc_strict n'est pas un caprice de style" \
  || bad "⑫(c) le décommenteur naïf ne perd rien ici — vérifier l'hypothèse qui motive nc_strict"

echo "== ⑰ le formulaire team-request n'a plus d'axe env (Jenkinsfile ET XML) =="
# Détecteur FACTORISÉ de ⑨a (jf_axe_verdict), appelé sur l'axe REQ_ENV : la
# contre-épreuve ⑰bis exerce EXACTEMENT le code qui rend le verdict ici, et le
# cas ABSENT interdit le vert par fichier manquant.
JTR="ci/Jenkinsfile.team-request"
case "$(jf_axe_verdict "$JTR" REQ_ENV)" in
  ABSENT) bad "⑰ $JTR introuvable — l'assertion d'absence serait vraie par vacuité" ;;
  ROUTE)  bad "⑰ $JTR paramètre/route encore un axe REQ_ENV vers le script" ;;
  PROPRE) ok  "⑰ $JTR ne porte plus d'axe env" ;;
esac
XTR="ci/jenkins/team-request.job.xml"
if [ ! -f "$XTR" ]; then
  bad "⑰bis $XTR introuvable — l'assertion d'absence serait vraie par vacuité"
else
  grep -q 'REQ_ENV' "$XTR" \
    && bad "⑰bis REQ_ENV encore dans le job.xml — et le XML GAGNE sur le Jenkinsfile" \
    || ok "⑰bis job.xml sans axe env"
  # Absence STRUCTURELLE, pas seulement textuelle : le formulaire posé compte
  # 4 champs et aucun n'est une liste fermée (la seule qui existait était l'env).
  python3 - "$XTR" <<'PY' >"$TMP/xtr_params" 2>&1
import sys, xml.etree.ElementTree as T
root = T.parse(sys.argv[1]).getroot()
names, choices = [], []
for p in root.iter():
    n = p.findtext('name') if p.tag.startswith('hudson.model.') and p.tag.endswith('ParameterDefinition') else None
    if n is not None:
        names.append(n)
        if p.tag.endswith('ChoiceParameterDefinition'):
            choices.append(n)
print("PARAMS=%d CHOICES=%d REQ_ENV=%s" % (len(names), len(choices), 'REQ_ENV' in names))
PY
  grep -q '^PARAMS=4 CHOICES=0 REQ_ENV=False$' "$TMP/xtr_params" \
    && ok "⑰bis le XML déclare 4 paramètres, 0 liste fermée, aucun REQ_ENV (lu par ElementTree, pas par grep)" \
    || { bad "⑰bis structure du formulaire XML inattendue"; sed 's/^/      /' "$TMP/xtr_params" | head -3; }
fi

echo "== ⑰ter mutation : l'axe REVIENT dans le Jenkinsfile ⇒ ⑰ rougirait =="
# Réinjection À SA PLACE RÉELLE (le bloc `parameters`), pas en queue de fichier.
sed 's|^  parameters {$|  parameters {\n    choice(name: '"'"'REQ_ENV'"'"', choices: ['"'"'dev'"'"'], description: "")|' \
  "$JTR" > "$TMP/jtr_mut"
cmp -s "$JTR" "$TMP/jtr_mut" \
  && bad "⑰ter(a0) le mutant est IDENTIQUE au fichier — l'ancre ^  parameters { a bougé, la mutation ne mute rien" \
  || ok "⑰ter(a0) le mutant diffère RÉELLEMENT du fichier (la mutation n'est pas un no-op)"
[ "$(jf_axe_verdict "$TMP/jtr_mut" REQ_ENV)" = ROUTE ] \
  && ok "⑰ter(a) axe env réinjecté ⇒ le détecteur de ⑰ REND ROUTE (il n'est pas aveugle)" \
  || bad "⑰ter(a) l'axe réinjecté passe inaperçu — l'assertion Jenkinsfile de ⑰ est vacante"
# Et la même chose côté XML, où la réinjection est CELLE QUI COMPTE (il gagne).
sed 's|</parameterDefinitions>|<hudson.model.ChoiceParameterDefinition><name>REQ_ENV</name><choices class="java.util.Arrays$ArrayList"><a class="string-array"><string>dev</string></a></choices></hudson.model.ChoiceParameterDefinition></parameterDefinitions>|' \
  "$XTR" > "$TMP/xtr_mut"
cmp -s "$XTR" "$TMP/xtr_mut" \
  && bad "⑰ter(b0) le mutant XML est IDENTIQUE — l'ancre </parameterDefinitions> a bougé" \
  || ok "⑰ter(b0) le mutant XML diffère RÉELLEMENT du fichier"
grep -q 'REQ_ENV' "$TMP/xtr_mut" \
  && ok "⑰ter(b) axe env réinjecté dans le XML ⇒ le détecteur de ⑰bis le VOIT" \
  || bad "⑰ter(b) l'axe réinjecté dans le XML passe inaperçu — ⑰bis est vacante"

echo "== ⑱ chemin nominal : gardes de team-request traversées VERTES en DRY_RUN =="
# GITEA_TOKEN est exigé EN TÊTE (`${GITEA_TOKEN:?}`), avant les gardes : sans
# lui le script refuserait pour une raison sans rapport. Valeur factice — le
# contrat DRY_RUN sort AVANT tout appel réseau (motif run_w de
# test-deploy-pin.sh:434-439, qui passe le même GITEA_TOKEN=x).
tr_dry(){ ( cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
    TEAM="$1" DESCRIPTION="$2" APPROVERS="A1,B2" \
    GITEA_TOKEN=x DRY_RUN=1 bash scripts/team-request.sh ) >"$TMP/tr_dry" 2>&1; }
tr_dry preuve-g4 "equipe de preuve"
RC=$?
grep -q 'GARDES_OK' "$TMP/tr_dry" && [ "$RC" -eq 0 ] \
  && ok "⑱ DRY_RUN traverse les gardes et sort 0" \
  || { bad "⑱ le chemin nominal ne passe pas (rc=$RC)"; sed 's/^/      /' "$TMP/tr_dry" | head -5; }
# AVANT tout geste Git : le premier geste du script s'annonce « [1/4] clone ».
# Son absence est la preuve que la sortie a eu lieu en amont — pas seulement
# que le script a fini par sortir 0.
grep -q '\[1/4\] clone' "$TMP/tr_dry" \
  && bad "⑱bis le clone a été tenté malgré DRY_RUN — le contrat n'est pas placé avant les gestes Git" \
  || ok "⑱bis aucun clone tenté : la sortie est en AMONT de tout geste Git/réseau"

echo "== ⑲ DRY_RUN n'est pas un laissez-passer : les gardes statuent quand même =="
# Un contrat DRY_RUN placé AVANT les gardes imprimerait GARDES_OK sans avoir
# rien vérifié — ⑱ serait alors un vert vacant. Deux gardes, l'une AVANT et
# l'autre APRÈS la position de l'ancien refus d'env, doivent encore refuser.
tr_dry 'Bad_Name' "equipe de preuve"
RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'TEAM_NAME_INVALID' "$TMP/tr_dry" && ! grep -q 'GARDES_OK' "$TMP/tr_dry"; } \
  && ok "⑲ TEAM invalide ⇒ refus nommé même en DRY_RUN (garde AMONT franchie, pas court-circuitée)" \
  || { bad "⑲ DRY_RUN court-circuite la garde de nom (rc=$RC)"; sed 's/^/      /' "$TMP/tr_dry" | head -5; }
tr_dry preuve-g4 'desc avec " guillemet'
RC=$?
{ [ "$RC" -ne 0 ] && grep -q 'YAML_UNSAFE_INPUT' "$TMP/tr_dry" && ! grep -q 'GARDES_OK' "$TMP/tr_dry"; } \
  && ok "⑲bis description hostile ⇒ YAML_UNSAFE_INPUT : le contrat est bien APRÈS toutes les gardes de forme" \
  || { bad "⑲bis DRY_RUN court-circuite la garde YAML (rc=$RC)"; sed 's/^/      /' "$TMP/tr_dry" | head -5; }

echo "== ⑮ D9 : le refus nommé du résolveur rejoint le commentaire de PR =="
sed 's/[[:space:]]*#.*$//' scripts/team-publish.sh > "$TMP/tp15_nc"
grep -q 'resolve_deploy_pin .* 2>' "$TMP/tp15_nc" \
  && ok "⑮ stderr du résolveur capturé dans un fichier (jamais un pipe)" \
  || bad "⑮ pas de capture de stderr sur l'appel du résolveur"
grep -qF 'deploy-pin: [A-Z_]*' "$TMP/tp15_nc" \
  && ok "⑮bis le jeton deploy-pin: est extrait vers le message de fail" \
  || bad "⑮bis rien n'extrait le jeton du fichier capturé (grep -o attendu)"
# Mutation : retirer la capture ⇒ ⑮ rougirait.
sed 's/ 2>"\$TMP\/pin.err"//' scripts/team-publish.sh > "$TMP/tp15_mut"
sed 's/[[:space:]]*#.*$//' "$TMP/tp15_mut" > "$TMP/tp15_mut_nc"
grep -q 'resolve_deploy_pin .* 2>' "$TMP/tp15_mut_nc" \
  && bad "⑮ter la mutation n'a pas retiré la capture — le détecteur ne protège rien" \
  || ok "⑮ter mutation efficace : sans capture, ⑮ verrait rouge"

# ── G4 / D7 : les protections de branche Gitea (lib, poseur, pose au create) ──
# NUMÉROTATION : le brief nommait ces épreuves ⑫ ⑬ ⑭ ; ⑫ était déjà pris (les
# mutations de ⑪, Task 4). Renumérotées ⑬ ⑭ ⑯, plus ⑳ pour le poseur — les
# seuls numéros libres. L'ordre du fichier n'a jamais été numérique de toute
# façon (⑮ vit après ⑲).

echo "== ⑬ payload de protection : JSON par python3, formé, complet =="
PROT_LIB="scripts/lib/repo-protection.sh"
if [ ! -f "$PROT_LIB" ]; then
  # Garde d'EXISTENCE avant toute assertion : sans elle, un fichier absent
  # ferait TAIRE les assertions du dessous au lieu de les faire rougir.
  bad "⑬ $PROT_LIB introuvable — les assertions sur le payload seraient vaines"
else
  # shellcheck source=scripts/lib/repo-protection.sh
  . "$PROT_LIB"
  repo_protection_payload main ci > "$TMP/pp1" 2>&1
  python3 - "$TMP/pp1" <<'PY' >"$TMP/pp1v" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["branch_name"] == "main"
assert d["enable_push"] is True and d["enable_push_whitelist"] is True
assert d["push_whitelist_usernames"] == ["ci"]
assert "protected_file_patterns" not in d, "patterns émis sans être demandés"
print("OK")
PY
  grep -q '^OK$' "$TMP/pp1v" \
    && ok "⑬ payload baseline conforme (push whitelist, aucun pattern non demandé)" \
    || bad "⑬ $(tail -1 "$TMP/pp1v")"
  repo_protection_payload main "ci,oscar" 'environments.yaml' > "$TMP/pp2" 2>&1
  python3 - "$TMP/pp2" <<'PY' >"$TMP/pp2v" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["push_whitelist_usernames"] == ["ci", "oscar"]
assert d["protected_file_patterns"] == "environments.yaml"
print("OK")
PY
  grep -q '^OK$' "$TMP/pp2v" \
    && ok "⑬bis whitelist CSV éclatée en liste, patterns optionnels posés quand demandés" \
    || bad "⑬bis $(tail -1 "$TMP/pp2v")"
  # LA raison du python3 : le JSON n'est JAMAIS du formatage de chaîne. La
  # contre-épreuve est une entrée HOSTILE — un printf naïf casserait le JSON ou,
  # pire, injecterait une clé de protection que personne n'a demandée.
  repo_protection_payload 'ma"in' 'ci","enable_push":false,"x":"' > "$TMP/pp3" 2>&1
  python3 - "$TMP/pp3" <<'PY' >"$TMP/pp3v" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["branch_name"] == 'ma"in', d
assert d["enable_push"] is True, "enable_push retourné par l'entrée : %r" % d["enable_push"]
assert set(d) == {"branch_name", "enable_push", "enable_push_whitelist",
                  "push_whitelist_usernames"}, "clé injectée : %r" % sorted(d)
print("OK")
PY
  grep -q '^OK$' "$TMP/pp3v" \
    && ok "⑬ter entrée hostile ⇒ JSON valide, AUCUNE clé injectée, enable_push non retourné" \
    || bad "⑬ter $(tail -1 "$TMP/pp3v")"
  # Le POSEUR lui-même, hors ligne : rien n'est posé nulle part (127.0.0.1:1
  # refuse la connexion), mais la fonction est RÉELLEMENT exercée — c'est la
  # seule façon de prouver que son refus est NOMMÉ plutôt que silencieux, et
  # qu'un hôte injoignable ne la fait pas retourner 0. La sémantique LIVE
  # (ce que Gitea fait vraiment d'un push/merge) reste la Task 9.
  printf 'Authorization: token factice\n' > "$TMP/hdr_off"
  repo_protection_payload main ci > "$TMP/pp_off"
  pose_branch_protection "http://127.0.0.1:1" "$TMP/hdr_off" "ci/absent" "$TMP/pp_off" \
    >"$TMP/off_out" 2>"$TMP/off_err"
  RC=$?
  # Motif EXACT, pas un `grep PROTECTION_NON_POSEE` fourre-tout : il prouve que
  # la fonction a bien ATTEINT le GET (aucune garde d'entrée ne l'a court-
  # circuitée) et que le code `000` de curl arrive INTACT dans le refus — ce que
  # le `|| true` de la lib est là pour préserver.
  { [ "$RC" -ne 0 ] && grep -q 'PROTECTION_NON_POSEE : GET ci/absent@main -> HTTP 000' "$TMP/off_err"; } \
    && ok "⑬quater hôte injoignable ⇒ rc≠0 ET refus nommé PORTANT le code 000 (jamais un succès muet)" \
    || { bad "⑬quater hôte injoignable : rc=$RC sans refus nommé"; sed 's/^/      /' "$TMP/off_err" | head -3; }
  grep -q 'PROTECTION_NON_POSEE' "$TMP/off_out" \
    && bad "⑬quinquies le refus part sur STDOUT — il se mêlerait au JSON/aux notes de l'appelant" \
    || ok "⑬quinquies le refus part bien sur stderr, stdout reste propre"
  # Payload absent : deuxième refus nommé, distinct — une garde d'entrée, pas
  # un plantage python à mi-chemin.
  pose_branch_protection "http://127.0.0.1:1" "$TMP/hdr_off" "ci/absent" "$TMP/pas-de-payload.json" \
    >/dev/null 2>"$TMP/off_err2"
  RC=$?
  { [ "$RC" -ne 0 ] && grep -q 'PROTECTION_NON_POSEE : payload introuvable' "$TMP/off_err2"; } \
    && ok "⑬sexies payload absent ⇒ refus nommé AVANT tout appel réseau" \
    || { bad "⑬sexies payload absent : rc=$RC"; sed 's/^/      /' "$TMP/off_err2" | head -3; }
fi

echo "== ⑭ team-apply APPELLE la pose, APRÈS le push du squelette et AVANT le webhook =="
nc_strict scripts/team-apply.sh > "$TMP/ta14_nc"
grep -q 'repo-protection.sh' "$TMP/ta14_nc" \
  && ok "⑭ la lib repo-protection est sourcée par team-apply" \
  || bad "⑭ lib repo-protection non sourcée"
grep -Eq '^[[:space:]]*pose_branch_protection |[^A-Za-z_]pose_branch_protection ' "$TMP/ta14_nc" \
  && ok "⑭bis pose_branch_protection est APPELÉE (sourcer n'est pas appeler)" \
  || bad "⑭bis aucun appel réel de pose_branch_protection"
# ÉCART AU BRIEF (détecteur corrigé, MESURÉ) : le brief cherchait le littéral
# `git push`. Il n'existe PAS dans team-apply.sh — le push du squelette s'écrit
# `git -C "$SK" push -q …` (le credential passe par GIT_CONFIG_*, plus par
# l'URL, cf. l'écart documenté :199-214). Écrit tel quel, L_PUSH restait VIDE
# et ⑭ter tombait à jamais dans sa branche d'échec. Motif élargi, garde
# d'existence CONSERVÉE : un push qui disparaîtrait rend l'ordre indémontrable,
# pas vrai par défaut.
L_PUSH=$(grep -nE 'git( -C [^ ]+)? push' "$TMP/ta14_nc" | head -1 | cut -d: -f1)
L_POSE=$(grep -n 'pose_branch_protection' "$TMP/ta14_nc" | head -1 | cut -d: -f1)
L_HOOK=$(grep -n 'TEAM_PUBLISH_WEBHOOK_URL' "$TMP/ta14_nc" | head -1 | cut -d: -f1)
{ [ -n "$L_PUSH" ] && [ -n "$L_POSE" ] && [ "$L_POSE" -gt "$L_PUSH" ]; } \
  && ok "⑭ter la pose vient APRÈS le push du squelette (protéger avant bloquerait le premier push)" \
  || bad "⑭ter ordre pose/push non prouvé (push=${L_PUSH:-absent} pose=${L_POSE:-absent})"
{ [ -n "$L_HOOK" ] && [ -n "$L_POSE" ] && [ "$L_POSE" -lt "$L_HOOK" ]; } \
  && ok "⑭quater la pose vient AVANT la section webhook (l'ordre annoncé est l'ordre réel)" \
  || bad "⑭quater ordre pose/webhook non prouvé (pose=${L_POSE:-absent} webhook=${L_HOOK:-absent})"
# Best-effort NOMMÉ, comme le webhook : jamais fail() — sinon une protection
# manquée annulerait un onboarding par ailleurs réussi.
# REVUE round 1 (Minor 3) : sans la garde d'existence, un L_POSE VIDE faisait
# lire `NR>=0 && NR<=6` — les six premières lignes du fichier, qui ne portent
# évidemment aucun `fail ` — et l'épreuve virait au VERT alors que la pose avait
# disparu. Vert par vacuité, exactement le motif que ce fichier traque ailleurs.
if [ -z "$L_POSE" ]; then
  bad "⑭quinquies pose introuvable — l'assertion « pas de fail() » serait vraie par vacuité"
else
  awk "NR>=$L_POSE && NR<=$L_POSE+6" "$TMP/ta14_nc" | grep -q 'fail ' \
    && bad "⑭quinquies la pose appelle fail() — une protection manquée annulerait l'onboarding" \
    || ok "⑭quinquies la pose n'appelle pas fail() (best-effort : l'onboarding survit)"
fi
# … mais NOMMÉ : la note est repliée dans REPO_NOTE (motif exact du webhook
# :332), donc elle rejoint les commentaires ✅ ET ❌, pas seulement le job.
grep -qF 'REPO_NOTE="${REPO_NOTE}${PROT_NOTE}"' "$TMP/ta14_nc" \
  && ok "⑭sexies PROT_NOTE est replié dans REPO_NOTE (motif du webhook) — il sort du job" \
  || bad "⑭sexies PROT_NOTE n'est pas replié dans REPO_NOTE — la note reste dans le job"
grep -q 'comment "✅ team-apply.*REPO_NOTE' "$TMP/ta14_nc" \
  && ok "⑭septies REPO_NOTE atteint bien le commentaire ✅ (le repli de ⑭sexies mène quelque part)" \
  || bad "⑭septies REPO_NOTE n'atteint pas le commentaire ✅ — le repli est sans destination"
# REVUE round 1 (Minor 4) : le repli dans REPO_NOTE a DEUX destinations, et
# seule la première était détectée. Le ❌ est la moitié qui compte le plus — un
# onboarding qui rate est justement le moment où l'exploitant a besoin de savoir
# si la protection est posée ou non.
grep -q 'comment "❌ team-apply.*REPO_NOTE' "$TMP/ta14_nc" \
  && ok "⑭octies REPO_NOTE atteint AUSSI le commentaire ❌ (l'état de la protection est dit même quand l'onboarding rate)" \
  || bad "⑭octies REPO_NOTE n'atteint pas le commentaire ❌ — la note se perd sur le chemin d'échec"

echo "== ⑯ mutations : les trois façons de rendre ⑬/⑭ vacantes =="
# (a) retirer l'APPEL — le contournement le plus direct.
sed 's/pose_branch_protection /true /' scripts/team-apply.sh > "$TMP/ta16_mut"
cmp -s scripts/team-apply.sh "$TMP/ta16_mut" \
  && bad "⑯(a0) le mutant est IDENTIQUE au fichier — l'ancre de l'appel a bougé, la mutation ne mute rien" \
  || ok "⑯(a0) le mutant diffère RÉELLEMENT du fichier (la mutation n'est pas un no-op)"
nc_strict "$TMP/ta16_mut" > "$TMP/ta16_mut_nc"
grep -Eq '^[[:space:]]*pose_branch_protection |[^A-Za-z_]pose_branch_protection ' "$TMP/ta16_mut_nc" \
  && bad "⑯(a) la mutation n'a pas retiré l'appel — le détecteur de ⑭bis ne protège rien" \
  || ok "⑯(a) mutation efficace : sans appel, ⑭bis verrait rouge"
# (b) DÉPLACER la pose AVANT le push : elle bloquerait alors le premier push du
# squelette. Le détecteur de PRÉSENCE de ⑭bis reste VERT sur ce mutant — seul
# le détecteur d'ORDRE l'attrape. C'est la raison d'être de ⑭ter.
if python3 - scripts/team-apply.sh "$TMP/ta16_ord" <<'PY'
import re, sys
src = open(sys.argv[1]).read().splitlines(True)
call = [i for i, l in enumerate(src) if re.search(r'(^|[^A-Za-z_])pose_branch_protection ', l)]
push = [i for i, l in enumerate(src) if re.search(r'git( -C \S+)? push', l)]
if not call or not push or call[0] < push[0]:
    sys.exit("ancres introuvables ou déjà inversées (call=%r push=%r)" % (call[:1], push[:1]))
moved = src.pop(call[0])
src.insert(push[0], moved)
open(sys.argv[2], "w").write("".join(src))
PY
then
  cmp -s scripts/team-apply.sh "$TMP/ta16_ord" \
    && bad "⑯(b0) le mutant d'ORDRE est identique — le déplacement n'a rien déplacé" \
    || ok "⑯(b0) le mutant d'ordre diffère RÉELLEMENT du fichier"
  nc_strict "$TMP/ta16_ord" > "$TMP/ta16_ord_nc"
  grep -Eq '^[[:space:]]*pose_branch_protection |[^A-Za-z_]pose_branch_protection ' "$TMP/ta16_ord_nc" \
    && ok "⑯(b) sur ce mutant ⑭bis reste VERT — la présence seule ne prouve pas l'ordre" \
    || bad "⑯(b) le déplacement a aussi supprimé l'appel — ce n'est pas le contournement visé"
  M_PUSH=$(grep -nE 'git( -C [^ ]+)? push' "$TMP/ta16_ord_nc" | head -1 | cut -d: -f1)
  M_POSE=$(grep -n 'pose_branch_protection' "$TMP/ta16_ord_nc" | head -1 | cut -d: -f1)
  { [ -n "$M_PUSH" ] && [ -n "$M_POSE" ] && [ "$M_POSE" -lt "$M_PUSH" ]; } \
    && ok "⑯(b bis) pose avant push ⇒ le détecteur d'ORDRE de ⑭ter le VOIT (pose=$M_POSE push=$M_PUSH)" \
    || bad "⑯(b bis) l'inversion passe inaperçue — l'assertion d'ordre de ⑭ter est vacante"
else
  bad "⑯(b) mutation d'ordre impossible à construire — l'assertion d'ordre de ⑭ter reste non contre-prouvée"
fi
# (c) la pose se fait, mais son issue ne QUITTE PLUS le job : le repli dans
# REPO_NOTE disparaît. Invisible pour ⑭bis comme pour ⑭ter.
sed 's/REPO_NOTE="${REPO_NOTE}${PROT_NOTE}"/REPO_NOTE="${REPO_NOTE}"/' scripts/team-apply.sh > "$TMP/ta16_mute"
cmp -s scripts/team-apply.sh "$TMP/ta16_mute" \
  && bad "⑯(c0) le mutant MUET est identique — l'ancre du repli a bougé" \
  || ok "⑯(c0) le mutant muet diffère RÉELLEMENT du fichier"
nc_strict "$TMP/ta16_mute" > "$TMP/ta16_mute_nc"
grep -qF 'REPO_NOTE="${REPO_NOTE}${PROT_NOTE}"' "$TMP/ta16_mute_nc" \
  && bad "⑯(c) la mutation n'a pas retiré le repli — le détecteur de ⑭sexies ne protège rien" \
  || ok "⑯(c) mutation efficace : sans repli, ⑭sexies verrait rouge"
grep -Eq '^[[:space:]]*pose_branch_protection |[^A-Za-z_]pose_branch_protection ' "$TMP/ta16_mute_nc" \
  && ok "⑯(c bis) et sur ce mutant ⑭bis reste VERT : une pose muette n'est PAS une pose absente" \
  || bad "⑯(c bis) la mutation a aussi retiré l'appel — ce n'est pas le contournement visé"

echo "== ⑳ le poseur setup-repo-protections.sh statue HORS LIGNE (--print) =="
SRP="scripts/setup-repo-protections.sh"
if [ ! -f "$SRP" ]; then
  bad "⑳ $SRP introuvable — les assertions sur le poseur seraient vaines"
else
  # ÉCART AU BRIEF (ajout justifié) : le brief n'ouvrait aucun chemin sans
  # GITEA_TOKEN ni réseau — la dérivation de la LISTE des dépôts (le seul
  # calcul du script) serait alors restée entièrement non prouvée. `--print`
  # l'émet sans rien poser. La sémantique LIVE, elle, reste la Task 9.
  ( env -i PATH="$PATH" HOME="$HOME" bash "$SRP" --print ) >"$TMP/srp" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] \
    && ok "⑳ --print sort 0 sans GITEA_TOKEN ni réseau" \
    || { bad "⑳ --print sort $RC"; sed 's/^/      /' "$TMP/srp" | head -5; }
  { grep -q '^REPO=ci/stoa-labs$' "$TMP/srp" && grep -q '^REPO=ci/governance$' "$TMP/srp"; } \
    && ok "⑳bis les deux dépôts de PLATEFORME sont visés (définition de pipeline + chaîne d'environnements)" \
    || bad "⑳bis un dépôt de plateforme manque dans --print"
  grep -q '^REPO=banking-demo/accounts-api$' "$TMP/srp" \
    && ok "⑳ter le dépôt d'équipe déclaré est DÉRIVÉ de providers.dev.yml" \
    || bad "⑳ter le dépôt d'équipe déclaré n'est pas dérivé"
  # payments-team porte `repo: ""` : un champ vide ne doit PAS produire une
  # cible vide (`…/repos//branch_protections`, qui viserait n'importe quoi).
  grep -q '^REPO=$' "$TMP/srp" \
    && bad "⑳quater un repo VIDE produit une cible — la pose viserait une URL sans dépôt" \
    || ok "⑳quater le repo vide de payments-team est écarté, pas transformé en cible vide"
  # Et la liste SUIT la source : retirer le repo dans providers le retire ici.
  sed 's|repo: banking-demo/accounts-api|repo: ""|' ansible/providers.dev.yml > "$TMP/prov_mut.yml"
  cmp -s ansible/providers.dev.yml "$TMP/prov_mut.yml" \
    && bad "⑳quinquies(0) le providers muté est identique — l'ancre repo: a bougé" \
    || ok "⑳quinquies(0) le providers muté diffère RÉELLEMENT"
  ( env -i PATH="$PATH" HOME="$HOME" PROVIDERS_FILE="$TMP/prov_mut.yml" bash "$SRP" --print ) >"$TMP/srp2" 2>&1
  grep -q '^REPO=banking-demo/accounts-api$' "$TMP/srp2" \
    && bad "⑳quinquies la liste ne SUIT pas providers (dépôt d'équipe codé en dur ?)" \
    || ok "⑳quinquies la liste SUIT providers : repo retiré ⇒ dépôt hors de la pose"
fi

printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
