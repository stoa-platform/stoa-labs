# G4 — Rétention de credential par palier : Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lever le verrou dev-only du self-service par SCELLEMENT de l'axe env sur les chemins d'authoring, et le remplacer par la rétention de credential par palier (Vault), la mise hors de portée des définitions de pipeline (Gitea), et la surface de refus nommée sur la PR.

**Architecture:** Trois plans : (1) un plan de credential Vault par palier (`apply-<env>` policies + AppRoles, dérivés de la chaîne, terminus exclu structurellement, rien d'accordé par défaut) ; (2) le scellement des scripts self-service sur `DEPLOY_PIN_AUTHORING_ENV` (constante de lib, jamais surchargeable) ; (3) les protections de branche Gitea (lib partagée + poseur + pose à la création des dépôts d'équipe). Preuve hors-ligne dans `scripts/test-palier-retention.sh` (branchée sur `make lint-ci`), preuves live séparées.

**Tech Stack:** bash 3.2-compatible (PAS de `mapfile`), python3 pour tout YAML/JSON, curl, API Vault KV v2/AppRole, API Gitea 1.22, Ansible (rôle `apim_team_onboard`).

**Spec:** `docs/superpowers/specs/2026-08-26-g4-retention-credential-par-palier-design.md` — le plan argumente depuis la spec ; l'exécutant lit les deux.

## Global Constraints

- **Répertoire de travail** : `/Users/torpedo/hlfh-repos/stoa-labs/poc-control-plane-federation` (le dépôt Git est le parent `stoa-labs`). Tous les chemins ci-dessous sont relatifs à ce répertoire. Les commits se font depuis le parent.
- **bash 3.2** (macOS) : pas de `mapfile`, pas de `declare -A`. Pas d'apostrophe française dans `${VAR:?message}`.
- **YAML/JSON par python3 uniquement** — jamais de formatage de chaîne.
- **Secrets jamais en argv ni en URL** : token Gitea en header-file (`curl -H @file`), token Vault en header depuis variable — discipline `team-apply.sh:148-168`.
- **pipefail** : les scripts de garde sortent 1 au refus ⇒ JAMAIS `cmd | grep -q X && ok || bad`. Toujours capturer dans un fichier puis grepper le fichier.
- **Ancrage sur code décommenté** : `sed 's/[[:space:]]*#.*$//' fichier > "$TMP/nc"` avant tout grep d'assertion sur un livrable.
- **Toute garde nouvelle a son épreuve de MUTATION** (retirer la garde ⇒ rouge). Un sabotage doit OUVRIR la porte, jamais la souder ; restauration vérifiée par relecture (motif `test-deploy-pin.sh:274-279`).
- **Aucun nom de palier en dur** dans le code livré : tout dérive de `DEPLOY_PIN_AUTHORING_ENV` (`scripts/lib/deploy-pin.sh:38`) ou d'`env_chain`/`env_chain_nonprod` (`scripts/lib/env-chain.sh`).
- Les numéros de ligne cités viennent du relevé du 2026-08-26 : **re-vérifier chaque ancre avant d'éditer** (`grep -n`), le fichier a pu bouger.
- Chaque tâche = un commit, portes vertes au commit. Message de commit imposé par la tâche.
- **Ledger SDD** : `/Users/torpedo/hlfh-repos/stoa-labs/.superpowers/sdd/2026-08-26-g4-retention-credential-par-palier/progress.md` (niveau parent, convention G3).

## Structure des fichiers

| Fichier | Responsabilité | Tâche |
|---|---|---|
| `scripts/setup-vault-paliers.sh` (créer) | poseur du plan de credential par palier (+ `--print`, `--mint`) | 1 |
| `scripts/test-palier-retention.sh` (créer) | porte hors-ligne G4 — grandit à chaque tâche | 1→7 |
| `ansible/roles/apim_team_onboard/{tasks/vault.yml,defaults/main.yml}`, `ansible/onboard-team.yml`, `scripts/setup-user-vault-jwt.sh` | write tenant par palier (D3) | 2 |
| `scripts/team-publish.sh`, `scripts/api-request.sh`, `scripts/setup-team-onboard-jobs.sh`, `ci/Jenkinsfile.team-publish`, `ci/Jenkinsfile.api-request`, `scripts/test-deploy-pin.sh`, `scripts/test-api-request-wiring.sh`, `scripts/test-team-publish-wiring.sh` | scellement côté publication (D4) + épreuves retournées | 3 |
| `scripts/team-request.sh`, `scripts/team-apply.sh`, `ci/Jenkinsfile.team-request`, `ci/jenkins/team-request.job.xml`, `scripts/test-team-request-wiring.sh`, `scripts/test-team-apply-wiring.sh` | scellement côté demande (D5) + `ENV_MISMATCH` + DRY_RUN + épreuves retournées | 4 |
| `scripts/team-publish.sh` | surface de refus D9 (capture stderr résolveur → commentaire PR) | 5 |
| `scripts/lib/repo-protection.sh` (créer), `scripts/setup-repo-protections.sh` (créer), `scripts/team-apply.sh` | protections Gitea (D7) | 6 |
| `scripts/provision-request.sh`, `scripts/provision-plan.sh`, `ci/jenkins/app-request.job.xml`, `scripts/setup-selfservice-job.sh`, `ci/Jenkinsfile.selfservice` | liste consommateur dérivée (D6) + branche main (D8) | 7 |
| `Makefile` | lint-ci : shellcheck des nouveaux .sh + porte G4 | 8 |
| `scripts/test-palier-retention-live.sh`, `scripts/test-repo-protections-live.sh` (créer) | portes live Vault + Gitea | 9 |
| `adr/adr-082-ouverture-palier-retention-credential.md` (créer), `ENVIRONNEMENTS.md`, `GOAL-cd-promotion-5-envs-2026-08-26.md`, `HANDOFF-2026-08-26-G4-RETENTION-CREDENTIAL.md` (créer) | doctrine + statut + handoff | 10 |

Découpage : 3 et 4 sont séparés parce que le scellement publication (rien à retirer côté formulaire) et le scellement demande (paramètre de formulaire à retirer dans DEUX artefacts — le XML gagne sur le Jenkinsfile) échouent différemment et se relisent séparément. 5 est séparé de 3 parce que D9 touche la ligne exacte que 3 vient de sceller — deux intentions, deux commits, deux revues.

---

### Task 1: Le poseur `setup-vault-paliers.sh` et le socle de la porte

**Files:**
- Create: `scripts/setup-vault-paliers.sh`
- Create: `scripts/test-palier-retention.sh`

**Interfaces:**
- Consumes: `env_chain_nonprod` (stdout : paliers non terminaux séparés par espaces, fail-closed — `scripts/lib/env-chain.sh:62-68`) ; `STOA_ENV_CHAIN_FILE` (override de la source de chaîne, honoré par la lib).
- Produces: `scripts/setup-vault-paliers.sh` avec trois modes : sans argument = pose sur Vault (exige `VAULT_TOKEN`) ; `--print` = émet policies + gestes sur stdout SANS réseau ni `VAULT_TOKEN` ; `--mint apply-<env>` = imprime `role_id\tsecret_id` (exige `VAULT_TOKEN`), refuse `MINT_ROLE_INCONNU` si le rôle n'est pas dans le set dérivé. Noms : policy `apply-<env>`, AppRole `apply-<env>`.

- [ ] **Step 1: Écrire le squelette de la porte et les épreuves ① à ⑤ (qui doivent échouer)**

Créer `scripts/test-palier-retention.sh` :

```bash
#!/usr/bin/env bash
# test-palier-retention.sh — porte hors-ligne G4 (ADR-082) : le plan de
# credential par palier, le scellement de l'axe env, les protections Gitea.
# Discipline héritée de test-deploy-pin.sh : capture fichier jamais pipe
# (pipefail), grep sur code DÉCOMMENTÉ, chaque garde mutée, sabotage qui
# OUVRE la porte, restauration vérifiée.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
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
```

- [ ] **Step 2: Lancer la porte, vérifier qu'elle ÉCHOUE**

Run: `bash scripts/test-palier-retention.sh`
Expected: FAIL (le fichier `scripts/setup-vault-paliers.sh` n'existe pas — chaque épreuve rouge ou erreur d'exécution, code de sortie ≠ 0).

- [ ] **Step 3: Écrire `scripts/setup-vault-paliers.sh`**

```bash
#!/usr/bin/env bash
# setup-vault-paliers.sh — G4 (ADR-082) : le plan de credential PAR PALIER.
#
# « Ouvrir un palier » n'est PAS un edit de code : c'est un geste Vault de
# l'exploitant (mint d'un secret_id, grant d'une policy à un humain). Ce
# script pose le MÉCANISME, fermé par défaut :
#   - une policy apply-<env> par palier NON terminal (read du seul secret
#     d'admin du palier : envs/<env>/wm-admin) — dérivée d'env_chain_nonprod,
#     JAMAIS de nom de palier en dur, le terminus est exclu par STRUCTURE
#     (le dernier de la chaîne, pas « prod ») ;
#   - un AppRole apply-<env> lié 1:1 à sa policy — AUCUN secret_id minté ici :
#     le mint est le geste d'ouverture, séparé, explicite ;
#   - le mapping LDAP apim-apply-<env> → apply-<env> (inerte tant que le
#     groupe n'existe pas dans l'annuaire — le grant humain reste un geste).
#
# DISSYMÉTRIE NOMMÉE : stoa-proxy-provision (setup-vault-approle.sh) garde
# son wildcard envs/+/wm-admin — c'est l'outillage OPÉRATEUR de pose des
# proxies ADR-075, pas une identité de pipeline. Clause de réouverture : le
# jour où la pose de proxy devient déclenchable par un tiers, elle suit la
# discipline par palier posée ici.
#
#   bash scripts/setup-vault-paliers.sh            # pose (exige VAULT_TOKEN)
#   bash scripts/setup-vault-paliers.sh --print    # émet SANS réseau (preuve)
#   bash scripts/setup-vault-paliers.sh --mint apply-rec   # geste d'OUVERTURE
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/env-chain.sh
. "scripts/lib/env-chain.sh"

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
TOKEN_TTL="${TOKEN_TTL:-3m}"
SECRET_ID_TTL="${SECRET_ID_TTL:-10m}"
SECRET_ID_USES="${SECRET_ID_USES:-0}"

ENVS_NONPROD="$(env_chain_nonprod)" || { echo "CHAINE_ILLISIBLE : env_chain_nonprod a échoué" >&2; exit 1; }
[ -n "$ENVS_NONPROD" ] || { echo "CHAINE_VIDE : aucun palier non terminal" >&2; exit 1; }

policy_hcl() { # <env> — le périmètre est le SECRET D'ADMIN DU PALIER, rien d'autre
  # Interpolation directe de $1 (pas de printf %s) : la contre-épreuve ③bis de
  # la porte mute le littéral envs/$1/ en envs/+/ — la forme est un contrat.
  printf '%s\n' \
    "path \"secret/data/stoa/envs/$1/wm-admin\" { capabilities = [\"read\"] }" \
    "path \"secret/metadata/stoa/envs/$1/wm-admin\" { capabilities = [\"read\"] }"
}

MODE="${1:-pose}"
case "$MODE" in
  --print)
    for e in $ENVS_NONPROD; do
      printf '# ── policy apply-%s ──\n' "$e"
      policy_hcl "$e"
      printf '# ── approle apply-%s (token_policies=apply-%s, token_ttl=%s) ──\n' "$e" "$e" "$TOKEN_TTL"
      printf '# ── mapping ldap apim-apply-%s -> apply-%s (inerte sans groupe) ──\n' "$e" "$e"
    done
    echo "# Geste d'OUVERTURE d'un palier (exploitant, hors pipeline) :"
    for e in $ENVS_NONPROD; do
      printf '#   %s --mint apply-%s\n' "$0" "$e"
    done
    exit 0 ;;
  --mint)
    ROLE="${2:?usage: --mint apply-<env>}"
    KNOWN=0
    for e in $ENVS_NONPROD; do [ "$ROLE" = "apply-$e" ] && KNOWN=1; done
    [ "$KNOWN" -eq 1 ] || { echo "MINT_ROLE_INCONNU : '$ROLE' hors du set dérivé (apply-{$(echo "$ENVS_NONPROD" | tr ' ' ',')})" >&2; exit 1; }
    VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis pour --mint}"
    CURL=(/usr/bin/curl -s -H "X-Vault-Token: $VAULT_TOKEN")
    RID="$("${CURL[@]}" "$VAULT_ADDR/v1/auth/approle/role/$ROLE/role-id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["role_id"])')"
    SID="$("${CURL[@]}" -X POST "$VAULT_ADDR/v1/auth/approle/role/$ROLE/secret-id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["secret_id"])')"
    printf '%s\t%s\n' "$RID" "$SID"
    exit 0 ;;
  pose) : ;;
  *) echo "usage: $0 [--print | --mint apply-<env>]" >&2; exit 2 ;;
esac

VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis pour poser (voir .env.example)}"
CURL=(/usr/bin/curl -s -H "X-Vault-Token: $VAULT_TOKEN")

echo "Vault $VAULT_ADDR — plan de credential par palier ($ENVS_NONPROD)"
"${CURL[@]}" -X POST "$VAULT_ADDR/v1/sys/auth/approle" -H 'Content-Type: application/json' \
  -d '{"type":"approle"}' -o /dev/null -w "  enable approle -> HTTP %{http_code} (204 ok / 400 déjà actif)\n" || true

for e in $ENVS_NONPROD; do
  HCL="$(policy_hcl "$e")"
  "${CURL[@]}" -X PUT "$VAULT_ADDR/v1/sys/policies/acl/apply-$e" \
    -H 'Content-Type: application/json' \
    -d "{\"policy\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$HCL")}" \
    -o /dev/null -w "  policy apply-$e -> HTTP %{http_code}\n"
  "${CURL[@]}" -X POST "$VAULT_ADDR/v1/auth/approle/role/apply-$e" -H 'Content-Type: application/json' \
    -d "{\"token_policies\":\"apply-$e\",\"token_ttl\":\"$TOKEN_TTL\",\"token_max_ttl\":\"$TOKEN_TTL\",\"secret_id_ttl\":\"$SECRET_ID_TTL\",\"secret_id_num_uses\":$SECRET_ID_USES}" \
    -o /dev/null -w "  approle apply-$e -> HTTP %{http_code}\n"
  # Mapping de GRANT humain — inerte tant que le groupe LDAP n'existe pas.
  # Tolérance NOMMÉE : sans mount ldap (lab partiel), on le dit, on ne casse pas.
  LC="$("${CURL[@]}" -X PUT "$VAULT_ADDR/v1/auth/ldap/groups/apim-apply-$e" \
    -H 'Content-Type: application/json' -d "{\"policies\":\"apply-$e\"}" \
    -o /dev/null -w '%{http_code}')"
  case "$LC" in 2*) echo "  ldap apim-apply-$e -> apply-$e (HTTP $LC)";;
                 *) echo "  ldap apim-apply-$e NON posé (HTTP $LC — mount ldap absent ? grant humain à poser autrement)";; esac
done

echo "done. RIEN n'est accordé : l'état sorti de ce script est « tout fermé »."
echo "Ouvrir un palier = "
for e in $ENVS_NONPROD; do echo "    $0 --mint apply-$e"; done
```

`chmod +x scripts/setup-vault-paliers.sh`

- [ ] **Step 4: Lancer la porte, vérifier qu'elle PASSE**

Run: `bash scripts/test-palier-retention.sh`
Expected: 9 PASS / 0 FAIL (①×3 + assertions rc, ②, ③+③bis, ④+④bis, ⑤ — compter les `ok` réels et noter le compte exact dans le ledger).

- [ ] **Step 5: shellcheck**

Run: `shellcheck -x scripts/setup-vault-paliers.sh scripts/test-palier-retention.sh`
Expected: rc=0 (corriger sans désactiver de règle globalement ; une directive locale se justifie en commentaire).

- [ ] **Step 6: Commit**

```bash
cd /Users/torpedo/hlfh-repos/stoa-labs
git add poc-control-plane-federation/scripts/setup-vault-paliers.sh poc-control-plane-federation/scripts/test-palier-retention.sh
git commit -m "feat(g4): le plan de credential par palier — ferme par defaut, ouvert par geste"
```

---

### Task 2: Le write tenant par palier (D3)

**Files:**
- Modify: `ansible/roles/apim_team_onboard/tasks/vault.yml` (bloc policy, autour de :96-112)
- Modify: `ansible/roles/apim_team_onboard/defaults/main.yml`
- Modify: `ansible/onboard-team.yml`
- Modify: `scripts/setup-user-vault-jwt.sh` (bloc `uvj-pol`, autour de :130-150)
- Modify: `scripts/test-palier-retention.sh` (épreuves ⑥ ⑦ ⑧)

**Interfaces:**
- Consumes: `env_chain_nonprod` ; la structure KV `deploy/<tenant>/apps/<app>/<env>/…` (`apim_selfservice_app/tasks/consumer-auth.yml:75`).
- Produces: var de rôle `apim_onb_write_envs` (liste, défaut `["dev"]` fail-closed) ; le playbook `ansible/onboard-team.yml` la dérive de la chaîne (lookup pipe) pour toutes les invocations documentées.

- [ ] **Step 1: Écrire les épreuves ⑥ ⑦ ⑧ (qui doivent échouer)**

Ajouter à `scripts/test-palier-retention.sh` avant le `printf` final :

```bash
echo "== ⑥ vault.yml : write tenant PAR PALIER, plus d'apps/* nu =="
VY="ansible/roles/apim_team_onboard/tasks/vault.yml"
sed 's/[[:space:]]*#.*$//' "$VY" > "$TMP/vy_nc"
grep -q 'apps/\*"' "$TMP/vy_nc" \
  && bad "⑥ un write apps/* NU subsiste dans la policy tenant (trou trans-env)" \
  || ok "⑥ plus aucun write apps/* nu dans vault.yml"
grep -q 'apim_onb_write_envs' "$TMP/vy_nc" \
  && ok "⑥bis la policy write est bouclée sur apim_onb_write_envs" \
  || bad "⑥bis apim_onb_write_envs n'apparaît pas — la boucle par palier n'existe pas"
grep -q 'apps/+/' "$TMP/vy_nc" \
  && ok "⑥ter le motif apps/+/<env>/ est présent (segment app wildcardé, env fixé)" \
  || bad "⑥ter le motif apps/+/<env>/ absent"

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
grep -q 'apps/\*"' "$TMP/uvj_nc" \
  && bad "⑧ un write apps/* nu subsiste dans la policy user-deploy" \
  || ok "⑧ plus d'apps/* nu dans user-deploy"
grep -q 'env_chain_nonprod' "$TMP/uvj_nc" \
  && ok "⑧bis la liste des paliers est dérivée au setup (env_chain_nonprod)" \
  || bad "⑧bis pas de dérivation de chaîne dans setup-user-vault-jwt.sh"
```

ATTENTION à l'épreuve ⑧ : le gabarit uvj-pol garde des lignes READ `"%s/*"` — l'assertion
vise le write `apps/*` ; vérifier que le grep `apps/\*"` ne matche pas une ligne read légitime
restée `…/apps/*` en READ. Si la ligne read-list metadata `apps/*` est conservée (elle peut
l'être : les métadonnées ne sont pas le secret), ANCRER le grep sur les seules lignes
portant `create` : `grep 'create' "$TMP/uvj_nc" | grep -q 'apps/\*"'`. Même précaution en ⑥.

- [ ] **Step 2: Lancer, vérifier l'échec**

Run: `bash scripts/test-palier-retention.sh`
Expected: les épreuves ⑥-⑧ FAIL, ①-⑤ toujours PASS.

- [ ] **Step 3: Implémenter**

`ansible/roles/apim_team_onboard/defaults/main.yml` — ajouter (près des autres `apim_onb_*`) :

```yaml
# G4 (ADR-082) : paliers où le tenant a le DROIT D'ÉCRIRE ses secrets d'app
# (deploy/<t>/apps/<app>/<env>/…). Défaut FAIL-CLOSED : le palier d'authoring
# seul. Le playbook onboard-team.yml dérive la vraie liste d'env_chain_nonprod
# — le terminus n'y entre JAMAIS (une écriture d'app au terminus meurt en 403,
# structurellement : c'est la rétention de credential, pas un if).
apim_onb_write_envs: ["dev"]
```

`ansible/roles/apim_team_onboard/tasks/vault.yml` — remplacer les deux lignes `apps/*` du
bloc policy (create/update data + metadata) par une boucle Jinja DANS le heredoc de policy.
La policy devient :

```yaml
      policy: |
        # Perimetre de deploiement du tenant {{ onb.team }}.
        # LECTURE sur tout le sous-arbre du tenant ; ECRITURE limitee au seul
        # sous-arbre apps/, PAR PALIER NON TERMINAL (G4, ADR-082) : celui qui
        # deploie une app de SON tenant y stocke le client genere — jamais
        # ailleurs, jamais un autre tenant, JAMAIS le terminus.
        path "{{ apim_ss_vault_kv_mount }}/data/{{ onb_tenant_root }}/*"          { capabilities = ["read"] }
        path "{{ apim_ss_vault_kv_mount }}/metadata/{{ onb_tenant_root }}/*"      { capabilities = ["read", "list"] }
{% raw %}{% for e in apim_onb_write_envs %}{% endraw %}
        path "{{ apim_ss_vault_kv_mount }}/data/{{ onb_tenant_root }}/apps/+/{% raw %}{{ e }}{% endraw %}/*"     { capabilities = ["create", "update", "read"] }
        path "{{ apim_ss_vault_kv_mount }}/metadata/{{ onb_tenant_root }}/apps/+/{% raw %}{{ e }}{% endraw %}/*" { capabilities = ["read", "list"] }
{% raw %}{% endfor %}{% endraw %}
```

(Le `{% raw %}` ci-dessus est une notation de PLAN : dans le fichier réel, écrire le
`{% for %}`/`{% endfor %}` directement — le champ `policy:` est templaté par Ansible.
Vérifier l'indentation rendue : les lignes de boucle doivent rester DANS le scalaire `|`.
La ligne metadata `…/*` read,list du tronc est conservée — les métadonnées ne sont pas le
secret ; c'est le CREATE qui est resserré.)

`ansible/onboard-team.yml` — au niveau `vars:` du play (créer le bloc si absent) :

```yaml
  vars:
    # G4 : la liste des paliers d'écriture d'apps est DÉRIVÉE de la chaîne
    # (une source). lookup pipe : le play est lancé depuis la racine
    # poc-control-plane-federation (convention de tous les appelants —
    # team-apply.sh:265, docs). Échec du pipe = échec du play : fail-closed.
    apim_onb_write_envs: "{{ lookup('pipe', 'bash -c \". scripts/lib/env-chain.sh && env_chain_nonprod\"').split() }}"
```

`scripts/setup-user-vault-jwt.sh` — en tête (après les autres sources/varibles), ajouter :

```bash
# shellcheck source=lib/env-chain.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/env-chain.sh"
UVJ_WRITE_ENVS="$(env_chain_nonprod)" || fail "CHAINE_ILLISIBLE : env_chain_nonprod"
```

puis remplacer le gabarit python `uvj-pol` : passer `$UVJ_WRITE_ENVS` (mots séparés) en
arguments supplémentaires et générer les lignes write par env :

```bash
python3 - "$VP" "$VM" $UVJ_WRITE_ENVS > /tmp/uvj-pol.json <<'PY'
import json, sys
d, m = sys.argv[1], sys.argv[2]
envs = sys.argv[3:]
assert envs, "liste de paliers vide — fail-closed"
lines = [
    '# Périmètre de déploiement du tenant porté par la claim (voie B, ADR-077).',
    '# LECTURE sur tout le sous-arbre ; ÉCRITURE limitée à apps/ PAR PALIER NON',
    '# TERMINAL (G4, ADR-082) — miroir exact de la policy deploy-<tenant> voie A.',
    'path "%s/*"          { capabilities = ["read"] }' % d,
    'path "%s/*"          { capabilities = ["read", "list"] }' % m,
]
for e in envs:
    lines.append('path "%s/apps/+/%s/*"     { capabilities = ["create", "update", "read"] }' % (d, e))
    lines.append('path "%s/apps/+/%s/*"     { capabilities = ["read", "list"] }' % (m, e))
json.dump({"policy": "\n".join(lines) + "\n"}, sys.stdout)
PY
```

(`$UVJ_WRITE_ENVS` volontairement NON quoté : le splitting par mots est l'effet voulu ;
poser `# shellcheck disable=SC2086` localement avec ce commentaire.)

- [ ] **Step 4: Vérifier**

Run: `bash scripts/test-palier-retention.sh` — Expected: toutes vertes (compter, consigner).
Run: `python3 -c "import yaml; yaml.safe_load(open('ansible/roles/apim_team_onboard/tasks/vault.yml')); yaml.safe_load(open('ansible/onboard-team.yml')); print('YAML OK')"` — Expected: `YAML OK`.
Run: `ansible-playbook --syntax-check -i ansible/inventory.lab.ini ansible/onboard-team.yml` — Expected: rc=0 (si ansible absent du poste, le dire dans le ledger et s'appuyer sur le YAML OK + la porte).
Run: `shellcheck -x scripts/setup-user-vault-jwt.sh` — Expected: rc=0.

- [ ] **Step 5: Commit**

```bash
cd /Users/torpedo/hlfh-repos/stoa-labs
git add -A poc-control-plane-federation/ansible/roles/apim_team_onboard poc-control-plane-federation/ansible/onboard-team.yml poc-control-plane-federation/scripts/setup-user-vault-jwt.sh poc-control-plane-federation/scripts/test-palier-retention.sh
git commit -m "feat(g4): le write tenant est par palier — le terminus sort par structure"
```

---

### Task 3: Scellement côté publication (D4) — team-publish, api-request, et les épreuves retournées

**Files:**
- Modify: `scripts/team-publish.sh` (:79-82), `scripts/api-request.sh` (:70 et son commentaire :49-51), `scripts/setup-team-onboard-jobs.sh` (:68)
- Modify: `ci/Jenkinsfile.team-publish` (:106), `ci/Jenkinsfile.api-request` (:112)
- Modify: `scripts/test-deploy-pin.sh` (épreuve ⑳, :673-676), `scripts/test-api-request-wiring.sh` (:219-221), `scripts/test-team-publish-wiring.sh` (si rouge)
- Modify: `scripts/test-palier-retention.sh` (épreuves ⑨a ⑩)

**Interfaces:**
- Consumes: `DEPLOY_PIN_AUTHORING_ENV` (`scripts/lib/deploy-pin.sh:38`, affectation sèche).
- Produces: dans les trois scripts scellés, la ligne EXACTE `ENVN="$DEPLOY_PIN_AUTHORING_ENV"` (team-publish, setup-team-onboard-jobs) / `ENVN="$DEPLOY_PIN_AUTHORING_ENV"` (api-request) — les épreuves et Task 4 s'ancrent sur cette forme.

- [ ] **Step 1: Écrire les épreuves ⑨a et ⑩ (qui doivent échouer)**

Ajouter à `scripts/test-palier-retention.sh` :

```bash
echo "== ⑨a scellement publication : ENVN vient de la constante, plus du job =="
for F in scripts/team-publish.sh scripts/api-request.sh scripts/setup-team-onboard-jobs.sh; do
  sed 's/[[:space:]]*#.*$//' "$F" > "$TMP/nc9"
  grep -q 'ENVN="\$DEPLOY_PIN_AUTHORING_ENV"' "$TMP/nc9" \
    && ok "⑨a $F scelle ENVN sur DEPLOY_PIN_AUTHORING_ENV" \
    || bad "⑨a $F ne scelle pas ENVN"
  grep -q 'ENVN="\${ENVN:-' "$TMP/nc9" \
    && bad "⑨a $F garde un défaut surchargeable ENVN:- (l'env du job décide encore)" \
    || ok "⑨a $F n'a plus de défaut surchargeable"
done
for JF in ci/Jenkinsfile.team-publish ci/Jenkinsfile.api-request; do
  sed 's|[[:space:]]*//.*$||' "$JF" > "$TMP/jf9"
  grep -q 'ENVN' "$TMP/jf9" \
    && bad "⑨a $JF route encore un axe ENVN vers le script" \
    || ok "⑨a $JF ne route plus d'axe env"
done

echo "== ⑩ mutation : remettre le défaut surchargeable ⇒ l'épreuve ⑨a rougirait =="
sed 's/ENVN="\$DEPLOY_PIN_AUTHORING_ENV"/ENVN="\${ENVN:-dev}"/' scripts/team-publish.sh > "$TMP/tp_mut"
sed 's/[[:space:]]*#.*$//' "$TMP/tp_mut" > "$TMP/tp_mut_nc"
grep -q 'ENVN="\${ENVN:-' "$TMP/tp_mut_nc" \
  && ok "⑩ la mutation réintroduit le défaut et le détecteur ⑨a le verrait" \
  || bad "⑩ la mutation n'a rien changé — ⑨a est un vert vacant"
```

- [ ] **Step 2: Lancer, vérifier l'échec** — `bash scripts/test-palier-retention.sh` : ⑨a/⑩ FAIL.

- [ ] **Step 3: Implémenter le scellement**

`scripts/team-publish.sh` — vérifier d'abord OÙ `scripts/lib/deploy-pin.sh` est sourcé
(`grep -n 'deploy-pin.sh' scripts/team-publish.sh`). Si le source est APRÈS la ligne 82, le
REMONTER avant (le sourcing ne fait que définir fonctions + constantes, aucun effet de bord).
Puis remplacer `:79-82` (commentaire + défaut) par :

```bash
# G4 (ADR-082) : ENVN est SCELLÉ sur l'env d'authoring — affectation sèche
# depuis la constante de lib, jamais "${ENVN:-dev}" : les variables d'un job
# Jenkins atterrissent dans l'environnement du process (fait mesuré, même
# raison que deploy-pin.sh:29-37). La publication est un geste d'AUTHORING
# par conception (ADR-079) ; au-delà, c'est la promotion (marqueurs G3,
# verbe archive G5) — et son autorité est la rétention de credential, pas
# une variable.
ENVN="$DEPLOY_PIN_AUTHORING_ENV"
```

`scripts/api-request.sh` — même geste sur `:70` ; ajouter en tête (près des autres sources,
ou en créer un) :

```bash
# shellcheck source=lib/deploy-pin.sh
. "$(dirname "$0")/lib/deploy-pin.sh"   # pour DEPLOY_PIN_AUTHORING_ENV (G4)
```

(vérifier le motif de cd/chemin du script : api-request.sh fait-il un `cd` d'abord ?
`grep -n '^cd ' scripts/api-request.sh` — sourcer AVANT tout cd, ou avec un chemin absolu
dérivé de `BASH_SOURCE`, pour ne pas rejouer le piège BASH_SOURCE de G1.)
Adapter le commentaire `:49-51` (« défaut dev ») au nouveau régime.

`scripts/setup-team-onboard-jobs.sh:68` — même geste (source deploy-pin.sh + affectation sèche).

`ci/Jenkinsfile.team-publish:106` — supprimer la ligne `ENVN = "${env.ENVN ?: 'dev'}"` ;
vérifier par `grep -n ENVN ci/Jenkinsfile.team-publish` qu'aucun autre usage ne reste
(nom de build, withEnv…) ; supprimer chaque routage restant.
`ci/Jenkinsfile.api-request:112` — idem.

- [ ] **Step 4: Retourner les épreuves satellites**

`scripts/test-deploy-pin.sh:673-676` (épreuve ⑳ — l'ancre exacte : `grep -n 'verrou dev-only' scripts/test-deploy-pin.sh`) — remplacer le bloc par :

```bash
# G4 a REMPLACÉ le verrou dev-only par le scellement : l'épreuve garde
# désormais le remplacement (l'affectation sèche), pas l'ancien défaut.
sed 's/[[:space:]]*#.*$//' "$TP" > "$TMP/tp20_nc"
grep -q 'ENVN="\$DEPLOY_PIN_AUTHORING_ENV"' "$TMP/tp20_nc" \
  && ok "⑳ ENVN est scellé sur la constante d'authoring (G4)" \
  || bad "⑳ team-publish.sh ne scelle plus ENVN — le remplacement du verrou a sauté"
grep -q 'ENVN="\${ENVN:-' "$TMP/tp20_nc" \
  && bad "⑳bis un défaut surchargeable ENVN:- est revenu (l'env du job déciderait)" \
  || ok "⑳bis aucun défaut surchargeable ne subsiste"
```

`scripts/test-api-request-wiring.sh:219-221` (ancre : `grep -n 'ENVN' scripts/test-api-request-wiring.sh`) — remplacer l'exigence du littéral `ENVN = "${env.ENVN ?: 'dev'}"` par :

```bash
sed 's|[[:space:]]*//.*$||' "$JF" > "$TMP/jf_envn"
grep -q 'ENVN' "$TMP/jf_envn" \
  && ko "le Jenkinsfile route encore un axe ENVN — G4 l'a scellé dans le script" \
  || ok "aucun axe ENVN routé par le Jenkinsfile (scellé côté script, G4)"
sed 's/[[:space:]]*#.*$//' scripts/api-request.sh > "$TMP/ar_envn"
grep -q 'ENVN="\$DEPLOY_PIN_AUTHORING_ENV"' "$TMP/ar_envn" \
  && ok "api-request.sh scelle ENVN sur DEPLOY_PIN_AUTHORING_ENV" \
  || ko "api-request.sh ne scelle pas ENVN"
```

(Adopter les helpers RÉELS de ce fichier — `ok`/`ko`, noms de variables `$JF`, tmp — en les
lisant d'abord ; si le fichier utilise un compteur EXPECTED, l'incrémenter d'autant.)

Lancer `bash scripts/test-team-publish-wiring.sh` : s'il rougit sur des assertions qui
citaient la ligne ENVN du Jenkinsfile, METTRE À JOUR ces assertions (asserter le
remplacement), ne jamais les supprimer ; ajuster `EXPECTED_CHECKS` (:52) en conséquence.

- [ ] **Step 5: Vérifier tout**

Run: `bash scripts/test-palier-retention.sh` → tout vert.
Run: `bash scripts/test-deploy-pin.sh` → attendu 79 PASS / 0 FAIL (78 + ⑳bis ; consigner le compte réel).
Run: `bash scripts/test-api-request-wiring.sh` → X/X vert (consigner).
Run: `bash scripts/test-team-publish-wiring.sh` → X/X vert (consigner).
Run: `bash ci/lint-jenkinsfiles.sh` → 12 fichiers verts.

- [ ] **Step 6: Commit**

```bash
cd /Users/torpedo/hlfh-repos/stoa-labs
git add -A poc-control-plane-federation/scripts poc-control-plane-federation/ci
git commit -m "feat(g4): la publication est scellee a l'authoring — l'env du job ne decide plus rien"
```

---

### Task 4: Scellement côté demande (D5) — team-request, team-apply, formulaire

**Files:**
- Modify: `scripts/team-request.sh` (:32, :49, + contrat DRY_RUN), `scripts/team-apply.sh` (:52-53)
- Modify: `ci/Jenkinsfile.team-request` (:71, choice REQ_ENV), `ci/jenkins/team-request.job.xml` (:58-61)
- Modify: `scripts/test-team-request-wiring.sh` (:135-137, :149-151, :158-160), `scripts/test-team-apply-wiring.sh` (si rouge)
- Modify: `scripts/test-palier-retention.sh` (épreuves ⑨b ⑪ ⑰ ⑱)

**Interfaces:**
- Consumes: `DEPLOY_PIN_AUTHORING_ENV` ; contrat DRY_RUN d'`api-promote-request.sh:131-132` (gardes OK → `exit 0` avant tout geste Git/réseau).
- Produces: refus nommé `ENV_MISMATCH` dans team-apply.sh ; `DRY_RUN=1` dans team-request.sh imprimant `GARDES_OK` ; le formulaire team-request SANS paramètre d'env (Jenkinsfile ET job.xml — le XML gagne).

- [ ] **Step 1: Écrire les épreuves ⑨b ⑪ ⑰ ⑱ (qui doivent échouer)**

Ajouter à `scripts/test-palier-retention.sh` :

```bash
echo "== ⑨b scellement demande : REQ_ENV/ENVN depuis la constante =="
sed 's/[[:space:]]*#.*$//' scripts/team-request.sh > "$TMP/tr_nc"
grep -q 'REQ_ENV="\$DEPLOY_PIN_AUTHORING_ENV"' "$TMP/tr_nc" \
  && ok "⑨b team-request scelle REQ_ENV" || bad "⑨b team-request ne scelle pas REQ_ENV"
grep -q 'ENV_NOT_OPEN' "$TMP/tr_nc" \
  && bad "⑨b ENV_NOT_OPEN subsiste dans team-request — le refus n'a plus d'objet une fois l'axe scellé" \
  || ok "⑨b ENV_NOT_OPEN a disparu de team-request (plus de choix à refuser)"

echo "== ⑪ team-apply : ENV_MISMATCH contre la CONSTANTE, pas un littéral =="
sed 's/[[:space:]]*#.*$//' scripts/team-apply.sh > "$TMP/ta_nc"
grep -q 'ENV_MISMATCH' "$TMP/ta_nc" \
  && ok "⑪ le refus ENV_MISMATCH existe" || bad "⑪ pas de refus ENV_MISMATCH"
grep -Eq '\[ "\$ENVN" = "\$DEPLOY_PIN_AUTHORING_ENV" \]' "$TMP/ta_nc" \
  && ok "⑪bis la comparaison vise la constante d'authoring" \
  || bad "⑪bis la comparaison ne vise pas la constante (littéral ?)"
grep -q 'ENV_NOT_OPEN' "$TMP/ta_nc" \
  && bad "⑪ter ENV_NOT_OPEN subsiste dans team-apply" \
  || ok "⑪ter ENV_NOT_OPEN a disparu de team-apply"
# Mutation : remplacer la constante par le littéral dev ⇒ ⑪bis rougirait.
sed 's/\[ "\$ENVN" = "\$DEPLOY_PIN_AUTHORING_ENV" \]/[ "$ENVN" = dev ]/' scripts/team-apply.sh > "$TMP/ta_mut"
sed 's/[[:space:]]*#.*$//' "$TMP/ta_mut" > "$TMP/ta_mut_nc"
grep -Eq '\[ "\$ENVN" = "\$DEPLOY_PIN_AUTHORING_ENV" \]' "$TMP/ta_mut_nc" \
  && bad "⑪quater la mutation n'a pas retiré la constante — le détecteur ne protège rien" \
  || ok "⑪quater mutation efficace : le détecteur ⑪bis verrait rouge"

echo "== ⑰ le formulaire team-request n'a plus d'axe env (Jenkinsfile ET XML) =="
sed 's|[[:space:]]*//.*$||' ci/Jenkinsfile.team-request > "$TMP/jtr_nc"
grep -q 'REQ_ENV' "$TMP/jtr_nc" \
  && bad "⑰ REQ_ENV encore routé/paramétré par le Jenkinsfile" \
  || ok "⑰ Jenkinsfile.team-request sans axe env"
grep -q 'REQ_ENV' ci/jenkins/team-request.job.xml \
  && bad "⑰bis REQ_ENV encore dans le job.xml — et le XML GAGNE sur le Jenkinsfile" \
  || ok "⑰bis job.xml sans axe env"

echo "== ⑱ chemin nominal : gardes de team-request traversées VERTES en DRY_RUN =="
( cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
    TEAM=preuve-g4 DESCRIPTION="equipe de preuve" APPROVERS="A1,B2" \
    GITEA_TOKEN=x DRY_RUN=1 bash scripts/team-request.sh ) >"$TMP/tr_dry" 2>&1
RC=$?
grep -q 'GARDES_OK' "$TMP/tr_dry" && [ "$RC" -eq 0 ] \
  && ok "⑱ DRY_RUN traverse les gardes et sort 0 AVANT tout geste Git" \
  || { bad "⑱ le chemin nominal ne passe pas (rc=$RC)"; sed 's/^/      /' "$TMP/tr_dry" | head -5; }
```

- [ ] **Step 2: Lancer, vérifier l'échec** — ⑨b ⑪ ⑰ ⑱ FAIL, le reste vert.

- [ ] **Step 3: Implémenter**

`scripts/team-request.sh` :
- en tête (après le `cd`, :25) : `. "scripts/lib/deploy-pin.sh"` avec `# shellcheck source=lib/deploy-pin.sh` et le commentaire « pour DEPLOY_PIN_AUTHORING_ENV (G4) ».
- `:32` : `REQ_ENV="${REQ_ENV:-dev}"` → 

```bash
# G4 (ADR-082, D5) : l'onboarding d'équipe est un geste d'AUTHORING — l'axe
# env a disparu du formulaire. La tenancy aux paliers supérieurs viendra du
# chemin de promotion (G5) ou d'un geste opérateur D0/D2, jamais d'ici.
REQ_ENV="$DEPLOY_PIN_AUTHORING_ENV"
```

- `:47-49` : supprimer le refus `ENV_NOT_OPEN` et son commentaire (« Palier 2 : seul dev… »).
- après la boucle APPROVERS (fin des gardes de forme, avant `WORK=$(mktemp -d)`) :

```bash
# Contrat DRY_RUN (motif api-promote-request.sh) : les gardes ont statué,
# aucun geste Git/réseau n'a eu lieu — c'est la surface qu'éprouve la porte.
[ "${DRY_RUN:-0}" = 1 ] && { echo "GARDES_OK : team-request (env d'authoring scellé : ${REQ_ENV})"; exit 0; }
```

`scripts/team-apply.sh` :
- en tête (après le shebang/es réglages, avant :52) : sourcer `scripts/lib/deploy-pin.sh`
  (le script tourne depuis le clone plateforme — vérifier le cwd effectif au point
  d'exécution : `grep -n 'cd \|BASH_SOURCE' scripts/team-apply.sh` — et sourcer par un
  chemin sûr, p.ex. `. "$(dirname "${BASH_SOURCE[0]}")/lib/deploy-pin.sh"`).
- `:53` : `[ "$ENVN" = dev ] || fail "ENV_NOT_OPEN : $ENVN"` →

```bash
# G4 (ADR-082, D5) : la branche onboard/<team>-<env> porte l'env par
# construction (team-request le scelle) — un suffixe étranger n'est pas un
# palier fermé, c'est une branche FORGÉE : refus.
[ "$ENVN" = "$DEPLOY_PIN_AUTHORING_ENV" ] || fail "ENV_MISMATCH : ${ENVN} ≠ ${DEPLOY_PIN_AUTHORING_ENV} — l'onboarding est un geste d'authoring ; la tenancy aux paliers supérieurs vient du chemin de promotion (ADR-082)"
```

`ci/Jenkinsfile.team-request` : supprimer le `choice REQ_ENV` (:71) et tout routage de
`REQ_ENV` vers le sh (grep ENVN/REQ_ENV, tout retirer).
`ci/jenkins/team-request.job.xml` : supprimer le bloc `ChoiceParameterDefinition` REQ_ENV
(:58-61 — vérifier les balises exactes du bloc, le XML doit rester bien formé :
`python3 -c "import xml.etree.ElementTree as ET; ET.parse('ci/jenkins/team-request.job.xml'); print('XML OK')"`).

- [ ] **Step 4: Retourner les épreuves satellites**

`scripts/test-team-request-wiring.sh` :
- `:149-151` (exigence des choix `dev,rec,int,prod`) → asserter l'ABSENCE du paramètre dans
  les DEUX artefacts + le scellement dans le script :

```bash
grep -q 'REQ_ENV' "$JOB" \
  && ko "REQ_ENV encore dans le job.xml (l'axe env doit avoir disparu — G4 D5)" \
  || ok "job.xml sans paramètre d'env (scellé côté script, G4)"
sed 's/[[:space:]]*#.*$//' "$SCRIPT" > "$T/tr_seal"
grep -q 'REQ_ENV="\$DEPLOY_PIN_AUTHORING_ENV"' "$T/tr_seal" \
  && ok "team-request.sh scelle REQ_ENV sur la constante d'authoring" \
  || ko "team-request.sh ne scelle pas REQ_ENV"
```

- `:158-160` (exigence de PRÉSENCE d'ENV_NOT_OPEN) → asserter l'ABSENCE (+ commentaire
  disant pourquoi : G4 D5, le refus n'a plus d'objet) ;
- `:135-137` : réécrire le commentaire qui motivait l'ordre des choix par ENV_NOT_OPEN.
- Adapter les helpers/compteurs à ce que le fichier utilise RÉELLEMENT (le lire d'abord).

Lancer `bash scripts/test-team-apply-wiring.sh` : mettre à jour ce qui citait ENV_NOT_OPEN
(asserter ENV_MISMATCH + la constante), ajuster le compteur attendu s'il y en a un.

- [ ] **Step 5: Vérifier tout**

Run: `bash scripts/test-palier-retention.sh` → tout vert (consigner le compte).
Run: `bash scripts/test-team-request-wiring.sh` → X/X vert.
Run: `bash scripts/test-team-apply-wiring.sh` → X/X vert.
Run: `bash ci/lint-jenkinsfiles.sh` → 12 verts.
Run: `python3 -c "import xml.etree.ElementTree as ET; ET.parse('ci/jenkins/team-request.job.xml'); print('XML OK')"` → XML OK.

- [ ] **Step 6: Commit**

```bash
cd /Users/torpedo/hlfh-repos/stoa-labs
git add -A poc-control-plane-federation/scripts poc-control-plane-federation/ci
git commit -m "feat(g4): l'onboarding est un geste d'authoring — l'axe env quitte le formulaire"
```

---

### Task 5: La surface de refus (D9) — le refus nommé du résolveur atteint la PR

**Files:**
- Modify: `scripts/team-publish.sh` (:351-352)
- Modify: `scripts/test-palier-retention.sh` (épreuve ⑮)

**Interfaces:**
- Consumes: `resolve_deploy_pin` (refus nommés sur stderr, format `deploy-pin: <JETON> : détail` — `deploy-pin.sh:48`) ; `fail()` de team-publish (:98, poste `$*` en commentaire PR).
- Produces: le commentaire PR d'échec porte le JETON précis (`PIN_ABSENT`, `ARCHIVE_ABSENT`…), plus seulement `PIN_NON_RESOLU`.

- [ ] **Step 1: Écrire l'épreuve ⑮ (qui doit échouer)**

```bash
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
```

(La double condition de ⑮bis est un garde-fou d'écriture : ancrer le grep sur la chaîne
RÉELLE utilisée dans l'implémentation ci-dessous — `deploy-pin: [A-Z_]*` — et vérifier à la
main qu'un `grep -c` sur le fichier réel rend exactement 1 site.)

- [ ] **Step 2: Lancer, vérifier l'échec** — ⑮ FAIL.

- [ ] **Step 3: Implémenter**

`scripts/team-publish.sh:351-352` — remplacer :

```bash
resolve_deploy_pin "$TMP/team" "$API_NAME" "$ENVN" "$TMP/resolved" \
  || fail "PIN_NON_RESOLU : la référence de déploiement de ${API_NAME} en ${ENVN} n'a pas pu être résolue (voir le refus nommé ci-dessus)"
```

par :

```bash
# G4 (D9) : le refus PRÉCIS du résolveur (PIN_ABSENT, ARCHIVE_ABSENT, …)
# part sur stderr (_dp_fail, deploy-pin.sh) — un lecteur de PR ne voit pas le
# log Jenkins. On capture stderr en FICHIER (jamais un pipe : pipefail + le
# résolveur sort 1) et le dernier jeton nommé rejoint le commentaire. C'est
# LA surface de diagnostic de l'équipe le jour où la chaîne s'exerce.
if ! resolve_deploy_pin "$TMP/team" "$API_NAME" "$ENVN" "$TMP/resolved" 2>"$TMP/pin.err"; then
  cat "$TMP/pin.err" >&2   # le log de build garde TOUT le détail
  REFUS="$(grep -o 'deploy-pin: [A-Z_]*' "$TMP/pin.err" | tail -1)"
  fail "PIN_NON_RESOLU : la référence de déploiement de ${API_NAME} en ${ENVN} n'a pas pu être résolue (${REFUS:-refus non nommé — voir le log du build})"
fi
```

- [ ] **Step 4: Vérifier**

Run: `bash scripts/test-palier-retention.sh` → tout vert.
Run: `bash scripts/test-team-publish-wiring.sh` → X/X vert (l'assertion :342-359 sur la
syntaxe `fail "JETON :` doit toujours matcher — vérifier, ajuster si le libellé a bougé).
Run: `bash scripts/test-deploy-pin.sh` → compte de Task 3 inchangé.

- [ ] **Step 5: Commit**

```bash
cd /Users/torpedo/hlfh-repos/stoa-labs
git add -A poc-control-plane-federation/scripts
git commit -m "feat(g4): le refus nomme du resolveur atteint la PR — la surface de diagnostic existe"
```

---

### Task 6: Les protections Gitea (D7) — lib, poseur, pose à la création

**Files:**
- Create: `scripts/lib/repo-protection.sh`
- Create: `scripts/setup-repo-protections.sh`
- Modify: `scripts/team-apply.sh` (après le push du squelette, avant la pose du webhook — repères : push :148-168, webhook :211-252)
- Modify: `scripts/test-palier-retention.sh` (épreuves ⑫ ⑬ ⑭)

**Interfaces:**
- Consumes: le header-file token déjà construit par team-apply (:99-103) ; `ansible/providers.dev.yml` (champ `repo`).
- Produces: `repo_protection_payload <branch> <push_whitelist_csv> [file_patterns]` → JSON sur stdout ; `pose_branch_protection <host> <header_file> <owner/repo> <payload_file>` → rc 0, sinon rc 1 + `PROTECTION_NON_POSEE : détail` sur stderr. Idempotent (GET puis POST 201 / PATCH 200).

- [ ] **Step 1: Écrire les épreuves ⑫ ⑬ ⑭ (qui doivent échouer)**

```bash
echo "== ⑫ payload de protection : JSON par python, formé, complet =="
# shellcheck source=scripts/lib/repo-protection.sh
. scripts/lib/repo-protection.sh
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
grep -q '^OK$' "$TMP/pp1v" && ok "⑫ payload baseline conforme" || { bad "⑫ $(cat "$TMP/pp1v" | tail -1)"; }
repo_protection_payload main "ci,oscar" 'environments.yaml' > "$TMP/pp2" 2>&1
python3 - "$TMP/pp2" <<'PY' >"$TMP/pp2v" 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["push_whitelist_usernames"] == ["ci", "oscar"]
assert d["protected_file_patterns"] == "environments.yaml"
print("OK")
PY
grep -q '^OK$' "$TMP/pp2v" && ok "⑫bis whitelist CSV et patterns optionnels conformes" || bad "⑫bis $(tail -1 "$TMP/pp2v")"

echo "== ⑬ team-apply APPELLE la pose, APRÈS le push du squelette =="
sed 's/[[:space:]]*#.*$//' scripts/team-apply.sh > "$TMP/ta13_nc"
grep -q 'repo-protection.sh' "$TMP/ta13_nc" \
  && ok "⑬ la lib est sourcée" || bad "⑬ lib repo-protection non sourcée"
grep -Eq '^[[:space:]]*pose_branch_protection |[^A-Za-z_]pose_branch_protection ' "$TMP/ta13_nc" \
  && ok "⑬bis pose_branch_protection est APPELÉE (sourcer n'est pas appeler)" \
  || bad "⑬bis aucun appel réel de pose_branch_protection"
L_PUSH=$(grep -n 'git push' "$TMP/ta13_nc" | head -1 | cut -d: -f1)
L_POSE=$(grep -n 'pose_branch_protection' "$TMP/ta13_nc" | head -1 | cut -d: -f1)
[ -n "$L_PUSH" ] && [ -n "$L_POSE" ] && [ "$L_POSE" -gt "$L_PUSH" ] \
  && ok "⑬ter la pose vient APRÈS le push du squelette (protéger avant bloquerait le premier push)" \
  || bad "⑬ter ordre pose/push non prouvé (push=$L_PUSH pose=$L_POSE)"

echo "== ⑭ mutation : retirer l'appel ⇒ ⑬bis rougirait =="
sed 's/pose_branch_protection /true /' scripts/team-apply.sh > "$TMP/ta14_mut"
sed 's/[[:space:]]*#.*$//' "$TMP/ta14_mut" > "$TMP/ta14_nc"
grep -Eq '^[[:space:]]*pose_branch_protection |[^A-Za-z_]pose_branch_protection ' "$TMP/ta14_nc" \
  && bad "⑭ la mutation n'a pas retiré l'appel — le détecteur ne protège rien" \
  || ok "⑭ mutation efficace : sans appel, ⑬bis verrait rouge"
```

- [ ] **Step 2: Lancer, vérifier l'échec** — ⑫ ⑬ ⑭ FAIL.

- [ ] **Step 3: Écrire `scripts/lib/repo-protection.sh`**

```bash
#!/usr/bin/env bash
# repo-protection.sh — pose idempotente d'une branch protection Gitea
# (G4, ADR-082, mécanismes M2/M3). SOURCÉE, jamais exécutée.
#
# Sémantique de protected_file_patterns (Gitea 1.22) : NON SUPPOSÉE ICI.
# test-repo-protections-live.sh la MESURE (push direct / merge de PR / admin)
# et le poseur n'émet des patterns que là où la mesure a statué. Baseline
# sûre : enable_push + whitelist — personne hors whitelist ne pousse la
# branche, tout le reste passe par PR.

repo_protection_payload() { # <branch> <push_whitelist_csv> [file_patterns]
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, sys
branch, wl, patterns = sys.argv[1], sys.argv[2], sys.argv[3]
p = {
    "branch_name": branch,
    "enable_push": True,
    "enable_push_whitelist": True,
    "push_whitelist_usernames": [u for u in wl.split(",") if u],
}
if patterns:
    p["protected_file_patterns"] = patterns
print(json.dumps(p))
PY
}

pose_branch_protection() { # <host> <header_file> <owner/repo> <payload_file>
  # header_file : fichier portant `Authorization: token …` (jamais argv).
  local host="$1" hdrf="$2" repo="$3" payload="$4"
  local branch out code
  branch="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["branch_name"])' "$payload" 2>/dev/null)" \
    || { echo "PROTECTION_NON_POSEE : payload illisible ($payload)" >&2; return 1; }
  out="$(mktemp)"
  code="$(curl -s -o "$out" -w '%{http_code}' -H @"$hdrf" \
    "$host/api/v1/repos/$repo/branch_protections/$branch")"
  case "$code" in
    200)
      code="$(curl -s -o "$out" -w '%{http_code}' -X PATCH -H @"$hdrf" \
        -H 'Content-Type: application/json' --data-binary @"$payload" \
        "$host/api/v1/repos/$repo/branch_protections/$branch")"
      [ "$code" = 200 ] || { echo "PROTECTION_NON_POSEE : PATCH $repo@$branch -> HTTP $code $(head -c 200 "$out")" >&2; rm -f "$out"; return 1; }
      ;;
    404)
      code="$(curl -s -o "$out" -w '%{http_code}' -X POST -H @"$hdrf" \
        -H 'Content-Type: application/json' --data-binary @"$payload" \
        "$host/api/v1/repos/$repo/branch_protections")"
      [ "$code" = 201 ] || { echo "PROTECTION_NON_POSEE : POST $repo@$branch -> HTTP $code $(head -c 200 "$out")" >&2; rm -f "$out"; return 1; }
      ;;
    *) echo "PROTECTION_NON_POSEE : GET $repo@$branch -> HTTP $code $(head -c 200 "$out")" >&2; rm -f "$out"; return 1 ;;
  esac
  rm -f "$out"
  return 0
}
```

- [ ] **Step 4: Écrire `scripts/setup-repo-protections.sh`**

```bash
#!/usr/bin/env bash
# setup-repo-protections.sh — G4 (ADR-082, M2/M3) : pose les protections de
# branche sur les dépôts que le PIPELINE lit — la définition de pipeline et
# la référence de déploiement sortent du périmètre d'écriture du demandeur.
#   - ci/stoa-labs@main   (plateforme : Jenkinsfiles, scripts/, ansible/)
#   - ci/governance@main  (chaîne d'environnements)
#   - chaque dépôt d'équipe déclaré (providers.dev.yml, repo non vide)
# Baseline : push whitelist = ${PROTECT_PUSH_WHITELIST:-ci} ; tout le reste
# passe par PR. PROTECT_FILE_PATTERNS (optionnel) n'est posé que si
# l'exploitant le fournit — la sémantique des patterns est MESURÉE par
# test-repo-protections-live.sh avant d'être engagée (spec G4 §4).
#   GITEA_TOKEN=… bash scripts/setup-repo-protections.sh
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/repo-protection.sh
. "scripts/lib/repo-protection.sh"

GIT_HOST="${GIT_HOST:-http://localhost:13000}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis (write:repository sur les dépôts visés)}"
WL="${PROTECT_PUSH_WHITELIST:-ci}"
PATTERNS="${PROTECT_FILE_PATTERNS:-}"

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT INT TERM; umask 077
printf 'Authorization: token %s\n' "$GITEA_TOKEN" > "$TMPD/hdr"

REPOS="ci/stoa-labs ci/governance"
TEAM_REPOS="$(python3 - ansible/providers.dev.yml <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for p in d.get("providers", []):
    r = (p.get("repo") or "").strip()
    if r:
        print(r)
PY
)"
RC=0
for repo in $REPOS $TEAM_REPOS; do
  repo_protection_payload main "$WL" "$PATTERNS" > "$TMPD/payload.json"
  if pose_branch_protection "$GIT_HOST" "$TMPD/hdr" "$repo" "$TMPD/payload.json"; then
    echo "  ✅ $repo@main protégé (push whitelist: $WL${PATTERNS:+ ; patterns: $PATTERNS})"
  else
    echo "  ❌ $repo@main NON protégé (voir PROTECTION_NON_POSEE ci-dessus)"; RC=1
  fi
done
exit "$RC"
```

- [ ] **Step 5: Brancher team-apply.sh**

Repérer la fin du push du squelette (`grep -n 'git push' scripts/team-apply.sh`, autour de
:168) et, AVANT la section webhook (:211), insérer — même régime best-effort NOMMÉ que le
webhook (:183-186 : jamais `fail`, le ❌ rejoint le commentaire) :

```bash
# ── protection de branche du dépôt d'équipe (G4, ADR-082 M2/M3) ─────────────
# APRÈS le push du squelette (protéger avant aurait bloqué le premier push),
# AVANT le webhook. Best-effort NOMMÉ : l'onboarding n'échoue pas pour une
# protection — mais le commentaire le dit, l'exploitant repasse
# setup-repo-protections.sh.
# shellcheck source=lib/repo-protection.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/repo-protection.sh"
PROT_NOTE=""
repo_protection_payload main "${PROTECT_PUSH_WHITELIST:-ci}" > "$TMP/prot.json"
if pose_branch_protection "$GIT_HOST" "$TOKF_HDR" "$ORG/$RNAME" "$TMP/prot.json"; then
  PROT_NOTE=" ; protection main posée"
else
  PROT_NOTE=" ; ⚠ protection main NON posée (setup-repo-protections.sh à repasser)"
fi
```

(`$TOKF_HDR` : reprendre la variable RÉELLE du header-file déjà construit vers :99-103 —
la lire dans le fichier ; si le header-file existant est consommé par `curl -H @…` sous un
autre nom, utiliser CE nom. `$ORG/$RNAME` : idem, reprendre les variables réelles de la
création du dépôt. Ajouter `$PROT_NOTE` au commentaire ✅ existant, comme le webhook fait.)

- [ ] **Step 6: Vérifier**

Run: `bash scripts/test-palier-retention.sh` → tout vert.
Run: `shellcheck -x scripts/lib/repo-protection.sh scripts/setup-repo-protections.sh scripts/team-apply.sh` → rc=0.
Run: `bash scripts/test-team-apply-wiring.sh` → vert (ajuster si une assertion compte les sections).

- [ ] **Step 7: Commit**

```bash
cd /Users/torpedo/hlfh-repos/stoa-labs
git add -A poc-control-plane-federation/scripts
git commit -m "feat(g4): la definition de pipeline sort du perimetre d'ecriture du demandeur"
```

---

### Task 7: La liste consommateur dérivée (D6) et la branche du job selfservice (D8)

**Files:**
- Modify: `scripts/provision-request.sh` (:127), `scripts/provision-plan.sh` (:59)
- Modify: `ci/jenkins/app-request.job.xml` (:48, texte descriptif)
- Modify: `scripts/setup-selfservice-job.sh` (:26-27 BRANCH, :73-81 choices ENVIRONMENT)
- Modify: `ci/Jenkinsfile.selfservice` (:42 choice ENVIRONMENT, :34-41 commentaire)
- Modify: `scripts/test-palier-retention.sh` (épreuves ⑯ ⑯bis)

**Interfaces:**
- Consumes: `env_chain_nonprod`.
- Produces: les scripts consommateur valident l'env par appartenance à `env_chain_nonprod` ; les listes de formulaire (Jenkinsfile + XML, tenues à la main — contrainte `parameters{}` documentée `Jenkinsfile.selfservice:34-41`) alignées sur `dev/rec/int/homol`.

- [ ] **Step 1: Écrire les épreuves ⑯ ⑯bis (qui doivent échouer)**

```bash
echo "== ⑯ la voie consommateur valide l'env par la CHAÎNE, terminus exclu =="
for F in scripts/provision-request.sh scripts/provision-plan.sh; do
  sed 's/[[:space:]]*#.*$//' "$F" > "$TMP/nc16"
  grep -q 'env_chain_nonprod' "$TMP/nc16" \
    && ok "⑯ $F dérive la liste de la chaîne" \
    || bad "⑯ $F ne dérive pas (liste en dur ?)"
  grep -Eq 'dev\|rec\|int\|prod' "$TMP/nc16" \
    && bad "⑯bis $F garde la liste en dur dev|rec|int|prod (sans homol, avec terminus)" \
    || ok "⑯bis $F n'a plus la liste en dur"
done

echo "== ⑯ter le job selfservice ride main, plus une branche de feature =="
sed 's/[[:space:]]*#.*$//' scripts/setup-selfservice-job.sh > "$TMP/ssj_nc"
grep -q 'BRANCH="\${BRANCH:-main}"' "$TMP/ssj_nc" \
  && ok "⑯ter défaut BRANCH=main (M2 : un pipeline sur branche non protégée est éditable hors revue)" \
  || bad "⑯ter le job selfservice ride encore une branche de feature par défaut"
grep -Eq "choices.*'prod'|>prod<" scripts/setup-selfservice-job.sh ci/Jenkinsfile.selfservice \
  && bad "⑯quater le formulaire consommateur propose encore le terminus" \
  || ok "⑯quater le terminus a quitté le formulaire consommateur (D3/D6 : l'écriture y meurt de toute façon)"
```

(⑯quater : ancrer le grep sur la LISTE de choix réelle — lire les deux fichiers d'abord ;
attention à ne pas matcher un commentaire ou le mot « prod » d'une URL : d'où le grep sur le
code décommenté et sur la forme exacte de la liste. Ajuster la regex à la forme réelle,
puis vérifier à la main qu'elle matche AVANT la modification et plus APRÈS.)

- [ ] **Step 2: Lancer, vérifier l'échec** — ⑯ FAIL.

- [ ] **Step 3: Implémenter**

`scripts/provision-request.sh` — en tête, sourcer env-chain (`. "scripts/lib/env-chain.sh"`
selon le motif cd du script — le lire) ; remplacer `:127`
`case "$REQ_ENV" in dev|rec|int|prod) ;; *) fail …` par :

```bash
# G4 (D6) : la liste suit la CHAÎNE, terminus exclu par structure (l'écriture
# d'app au terminus meurt en 403 depuis D3 — le formulaire ne ment plus).
CHAIN_NONPROD="$(env_chain_nonprod)" || fail "CHAINE_ILLISIBLE : env_chain_nonprod"
case " $CHAIN_NONPROD " in
  *" $REQ_ENV "*) : ;;
  *) fail "<MÊME JETON QUE L'EXISTANT> : '$REQ_ENV' hors de la chaîne hors-terminus ($CHAIN_NONPROD)" ;;
esac
```

(`<MÊME JETON QUE L'EXISTANT>` : reprendre le jeton de refus DÉJÀ utilisé par la ligne
actuelle — le lire à :127 — pour ne pas casser un consommateur du message ; si la ligne
actuelle n'a pas de jeton nommé, en poser un : `ENV_INVALIDE`.)

`scripts/provision-plan.sh:59` — même geste.
`ci/jenkins/app-request.job.xml:48` — le texte `(dev|rec|int|prod)` devient
`(paliers non terminaux de la chaîne — dev/rec/int/homol aujourd'hui)`.
`scripts/setup-selfservice-job.sh` — `:27` `BRANCH="${BRANCH:-feat/selfservice-app-adr078}"`
→ `BRANCH="${BRANCH:-main}"` avec commentaire M2 ; dans le XML heredoc (:73-81), la liste
ENVIRONMENT `dev/rec/int/prod` → `dev/rec/int/homol` (homol entre — G1 l'avait ajouté au
seul Jenkinsfile, or le XML GAGNE ; prod sort — D3).
`ci/Jenkinsfile.selfservice:42` — `['dev','rec','int','homol','prod']` →
`['dev','rec','int','homol']`, et le commentaire :34-41 complété : « prod retiré par G4/D3 :
l'écriture d'app au terminus est structurellement fermée ; liste tenue à la main (contrainte
parameters{} hors workspace), alignée sur env_chain_nonprod du 2026-08-26 ».

- [ ] **Step 4: Vérifier**

Run: `bash scripts/test-palier-retention.sh` → tout vert.
Run: `bash ci/lint-jenkinsfiles.sh` → 12 verts.
Run: `bash scripts/test-app-request-wiring.sh` et `bash scripts/test-provision-apply-wiring.sh`
→ verts (si une assertion citait la liste en dur, la retourner — asserter la dérivation).
Run: `shellcheck -x scripts/provision-request.sh scripts/provision-plan.sh scripts/setup-selfservice-job.sh` → rc=0.

- [ ] **Step 5: Commit**

```bash
cd /Users/torpedo/hlfh-repos/stoa-labs
git add -A poc-control-plane-federation/scripts poc-control-plane-federation/ci
git commit -m "feat(g4): la voie consommateur suit la chaine, le job selfservice ride main"
```

---

### Task 8: `make lint-ci` porte G4

**Files:**
- Modify: `Makefile` (:91-101, cible lint-ci)

**Interfaces:**
- Consumes: `scripts/test-palier-retention.sh` (code de sortie 0/1) ; la liste shellcheck explicite (`Makefile:96-97`).
- Produces: lint-ci à 5 étapes.

- [ ] **Step 1: Modifier la cible**

Dans `Makefile` (lint-ci) : (a) ajouter à la liste shellcheck (:96-97) :
`scripts/setup-vault-paliers.sh scripts/lib/repo-protection.sh scripts/setup-repo-protections.sh scripts/setup-user-vault-jwt.sh` ;
(b) ajouter une étape `[5/5]` : `bash scripts/test-palier-retention.sh` ;
(c) renuméroter les échos `[1/4]`→`[1/5]` etc. (les libellés d'étapes sont dans la cible —
les lire, renuméroter TOUS).

- [ ] **Step 2: Vérifier**

Run: `make lint-ci`
Expected: `[1/5]`…`[5/5]` verts — 12 Jenkinsfile compilés, shellcheck rc=0 (liste élargie),
15 épreuves carto, test-deploy-pin (compte de Task 3), test-palier-retention (compte de
Task 7). Consigner les comptes exacts dans le ledger.

- [ ] **Step 3: Rejouer l'arbre au repos**

Run, dans l'ordre, et consigner chaque compte :
`bash scripts/test-deploy-pin.sh` ; `bash scripts/test-team-publish-wiring.sh` ;
`bash scripts/test-team-request-wiring.sh` ; `bash scripts/test-team-apply-wiring.sh` ;
`bash scripts/test-api-request-wiring.sh` ; `bash scripts/test-app-request-wiring.sh` ;
`bash scripts/test-env-chain.sh` ; `bash scripts/test-jenkinsfile-lint.sh` (docker requis).
Expected: tout vert, aucun compte en régression non expliquée.

- [ ] **Step 4: Commit**

```bash
cd /Users/torpedo/hlfh-repos/stoa-labs
git add poc-control-plane-federation/Makefile
git commit -m "ci(g4): lint-ci porte la retention par palier — cinq etapes"
```

---

### Task 9: Les portes live — Vault (403 + F4-canari) et Gitea (mesure + porte G4)

**Files:**
- Create: `scripts/test-palier-retention-live.sh`
- Create: `scripts/test-repo-protections-live.sh`

**Interfaces:**
- Consumes: `setup-vault-paliers.sh` (pose + `--mint`) ; `repo_protection_payload`/`pose_branch_protection` ; `VAULT_ADDR`/`VAULT_TOKEN` (root lab) ; `GITEA_TOKEN` (admin lab).
- Produces: deux scripts REJOUABLES ; chacun REFUSE de courir (exit 1, refus nommé `LAB_ABSENT : <détail>`) si son prérequis ne répond pas — jamais de SKIP silencieux (règle no-silent-caps).

- [ ] **Step 1: Écrire `scripts/test-palier-retention-live.sh`**

Structure imposée (le code suit les motifs de Task 1 ; ok/bad/TMP identiques) :

```bash
#!/usr/bin/env bash
# test-palier-retention-live.sh — porte LIVE G4 côté Vault (lab requis).
# ① pose réelle ; ② matrice 403 inter-palier ; ③ tenant : write rec ✓ / terminus ✗ ;
# ④ motif F4 par palier : policy révoquée ⇒ geste fermé, CANARI intact ;
# ⑤ restauration + geste vert + le canari voit EXACTEMENT un hit.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# … ok/bad/TMP comme test-palier-retention.sh …
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis (root lab)}"
curl -s -m 5 -o /dev/null "$VAULT_ADDR/v1/sys/health" || { echo "LAB_ABSENT : Vault ne répond pas à $VAULT_ADDR" >&2; exit 1; }
. scripts/lib/env-chain.sh
ENVS="$(env_chain_nonprod)"
FIRST="$(echo "$ENVS" | awk '{print $1}')"; SECOND="$(echo "$ENVS" | awk '{print $2}')"

# ① pose
bash scripts/setup-vault-paliers.sh >"$TMP/pose" 2>&1 && ok "① pose" || { bad "① pose: $(tail -2 "$TMP/pose")"; exit 1; }

# ② matrice : token apply-$FIRST lit SON palier, pas le voisin
MINT="$(VAULT_TOKEN="$VAULT_TOKEN" bash scripts/setup-vault-paliers.sh --mint "apply-$FIRST")"
RID="${MINT%%$'\t'*}"; SID="${MINT##*$'\t'}"
TOK="$(curl -s -X POST "$VAULT_ADDR/v1/auth/approle/login" -d "{\"role_id\":\"$RID\",\"secret_id\":\"$SID\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')"
C1="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $TOK" "$VAULT_ADDR/v1/secret/data/stoa/envs/$FIRST/wm-admin")"
C2="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $TOK" "$VAULT_ADDR/v1/secret/data/stoa/envs/$SECOND/wm-admin")"
[ "$C1" = 200 ] && ok "② apply-$FIRST lit envs/$FIRST (200)" || bad "② lecture du propre palier: $C1"
[ "$C2" = 403 ] && ok "②bis apply-$FIRST NE lit PAS envs/$SECOND (403)" || bad "②bis fuite inter-palier: $C2 (attendu 403)"

# ③ tenant resserré : onboarding rejoué (converge la policy), puis probes
ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml -e apim_onb_team=banking-demo >"$TMP/onb" 2>&1 \
  && ok "③ onboarding banking-demo convergé (policy resserrée)" || { bad "③ onboarding: $(tail -3 "$TMP/onb")"; }
TTOK="$(curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{"policies":["deploy-banking-demo"],"ttl":"5m"}' "$VAULT_ADDR/v1/auth/token/create" | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')"
W1="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Vault-Token: $TTOK" -d '{"data":{"probe":"g4"}}' "$VAULT_ADDR/v1/secret/data/stoa/deploy/banking-demo/apps/probe-g4/$SECOND/oauth-client")"
TERM="$(env_chain | awk '{print $NF}')"
W2="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Vault-Token: $TTOK" -d '{"data":{"probe":"g4"}}' "$VAULT_ADDR/v1/secret/data/stoa/deploy/banking-demo/apps/probe-g4/$TERM/oauth-client")"
[ "$W1" = 200 ] && ok "③bis write apps/…/$SECOND accepté (voie consommateur intacte)" || bad "③bis write $SECOND: $W1"
[ "$W2" = 403 ] && ok "③ter write apps/…/$TERM (terminus) REFUSÉ structurellement" || bad "③ter le terminus accepte un write: $W2"

# ④ F4-canari sur $SECOND : révoquer apply-$SECOND ⇒ geste fermé, canari muet.
#    Le « geste d'apply minimal » = lire le secret du palier PUIS toucher la
#    gateway (ici le CANARI). Sans le secret, le canari ne doit JAMAIS voir
#    passer une requête.
CANARY_PORT=18466
python3 -m http.server "$CANARY_PORT" --bind 127.0.0.1 >"$TMP/canary.log" 2>&1 & CPID=$!
sleep 1
apply_gesture() { # <env> — retourne 0 ssi secret lu ET canari touché
  local tok; tok="$(curl -s -X POST "$VAULT_ADDR/v1/auth/approle/login" -d "{\"role_id\":\"$1\",\"secret_id\":\"$2\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')" || return 1
  curl -s -f -H "X-Vault-Token: $tok" "$VAULT_ADDR/v1/secret/data/stoa/envs/$3/wm-admin" -o /dev/null || return 1
  curl -s -o /dev/null "http://127.0.0.1:$CANARY_PORT/apply-$3" || return 1
}
M2="$(bash scripts/setup-vault-paliers.sh --mint "apply-$SECOND")"; R2="${M2%%$'\t'*}"; S2="${M2##*$'\t'}"
curl -s -X DELETE -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/policies/acl/apply-$SECOND" -o /dev/null
apply_gesture "$R2" "$S2" "$SECOND" >"$TMP/g1" 2>&1
GRC=$?
[ "$GRC" -ne 0 ] && ok "④ policy révoquée ⇒ geste FERMÉ (rc=$GRC)" || bad "④ le geste passe sans policy"
grep -q "apply-$SECOND" "$TMP/canary.log" \
  && bad "④bis le canari a vu passer une requête — la gateway aurait été touchée" \
  || ok "④bis canari MUET : aucune requête gateway sans le credential"

# ⑤ restauration = re-pose, geste vert, canari voit UN hit
bash scripts/setup-vault-paliers.sh >>"$TMP/pose" 2>&1
M3="$(bash scripts/setup-vault-paliers.sh --mint "apply-$SECOND")"; R3="${M3%%$'\t'*}"; S3="${M3##*$'\t'}"
apply_gesture "$R3" "$S3" "$SECOND" && ok "⑤ policy restaurée ⇒ geste vert" || bad "⑤ geste toujours fermé après restauration"
N=$(grep -c "apply-$SECOND" "$TMP/canary.log")
[ "$N" -eq 1 ] && ok "⑤bis le canari a vu EXACTEMENT un hit (le geste restauré)" || bad "⑤bis canari: $N hits (attendu 1)"
kill "$CPID" 2>/dev/null
# nettoyage de la probe tenant
curl -s -o /dev/null -X DELETE -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/secret/metadata/stoa/deploy/banking-demo/apps/probe-g4" || true
```

(Compléter le squelette ok/bad/TMP exactement comme Task 1 ; `python3 -m http.server` logge
chaque requête sur stderr → le log est le témoin. Si le port 18466 est pris, prendre
`CANARY_PORT="${CANARY_PORT:-18466}"`. `ansible-playbook` absent ⇒ ③ se REFUSE avec
`LAB_ABSENT : ansible-playbook introuvable` — pas de skip muet.)

- [ ] **Step 2: Écrire `scripts/test-repo-protections-live.sh`**

Structure imposée :

```bash
#!/usr/bin/env bash
# test-repo-protections-live.sh — porte LIVE G4 côté Gitea (lab requis).
# ① MESURE de la sémantique protected_file_patterns (1.22) sur dépôt jetable ;
# ② porte G4 : le demandeur ne pousse ni la chaîne ni main ;
# ③ le flux légitime (PR) reste ouvert. Nettoyage complet.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# … ok/bad/TMP …
GIT_HOST="${GIT_HOST:-http://localhost:13000}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis (admin lab)}"
curl -s -m 5 -o /dev/null "$GIT_HOST/api/v1/version" || { echo "LAB_ABSENT : Gitea ne répond pas à $GIT_HOST" >&2; exit 1; }
. scripts/lib/repo-protection.sh
HDR="$TMP/hdr"; printf 'Authorization: token %s\n' "$GITEA_TOKEN" > "$HDR"
ORG="g4-proof"; RN="probe"
# créer org+repo jetables (POST /orgs, /orgs/$ORG/repos, auto_init:true)
# créer un user jetable g4-req (POST /admin/users) + token, collaborateur WRITE du repo
# pousser un fichier protege.yaml + un fichier libre.txt sur main (token admin)
# poser la protection : repo_protection_payload main "" 'protege.yaml' → pose_branch_protection
# ① MESURE :
#   a) push direct (token g4-req) touchant protege.yaml   → attendu: REJETÉ (capturer le message)
#   b) push direct (token g4-req) touchant libre.txt      → whitelist vide: mesurer (rejeté ? = enable_push_whitelist avec liste vide)
#   c) PR (token g4-req) touchant protege.yaml, merge API → MESURER allow/deny, IMPRIMER le verdict
#   d) push direct (token admin ci) touchant protege.yaml → MESURER (l'admin passe-t-il ?)
#   → chaque mesure est un `ok "MESURE : …"` qui IMPRIME le comportement observé ;
#     les assertions dures ne portent que sur (a) : un non-admin ne pousse pas un fichier protégé.
# ② PORTE G4 :
#   - push direct g4-req sur main du repo d'équipe protégé baseline (whitelist ci) → REJETÉ
#   - push g4-req vers ci/stoa-labs (aucun droit)                                   → 403
# ③ flux légitime : PR de g4-req sur un fichier libre → mergeable_state ≠ blocked par la protection
# nettoyage : DELETE repo, org, user (motif test-producer-chain.sh:417-419)
```

L'implémenteur ÉCRIT chaque appel API réel (org/repo/user/push par `git -c http.extraHeader`
ou URL localhost avec token de l'utilisateur jetable — token du user jetable OK en URL ? NON :
même discipline, header-file partout). Les verdicts de MESURE (b, c, d) sont des `ok` textuels
qui consignent l'observation — c'est la livraison de la mesure exigée par la spec §6 ; seule
(a) et la section ② portent des assertions dures.

- [ ] **Step 3: Exécuter (si le lab répond)**

Run: `VAULT_TOKEN=… bash scripts/test-palier-retention-live.sh` → tout vert (consigner).
Run: `GITEA_TOKEN=… bash scripts/test-repo-protections-live.sh` → tout vert + verdicts de
mesure consignés dans le ledger ET reportés dans le commentaire d'en-tête de
`scripts/setup-repo-protections.sh` (la sémantique mesurée remplace « NON SUPPOSÉE ICI »).
Si un lab ne répond pas : consigner `LAB_ABSENT` dans le ledger — la porte est ROUGE PAR
ABSENCE, jamais supposée verte.

- [ ] **Step 4: shellcheck + commit**

Run: `shellcheck -x scripts/test-palier-retention-live.sh scripts/test-repo-protections-live.sh` → rc=0.

```bash
cd /Users/torpedo/hlfh-repos/stoa-labs
git add -A poc-control-plane-federation/scripts
git commit -m "test(g4): les portes live — 403 par palier, F4-canari, mesure Gitea"
```

---

### Task 10: ADR-082, statut du GOAL, handoff

**Files:**
- Create: `adr/adr-082-ouverture-palier-retention-credential.md`
- Modify: `ENVIRONNEMENTS.md` (section G4), `GOAL-cd-promotion-5-envs-2026-08-26.md` (statut G4)
- Create: `HANDOFF-2026-08-26-G4-RETENTION-CREDENTIAL.md`

- [ ] **Step 1: Écrire l'ADR-082**

Sections imposées (format des ADR voisins — lire adr-081 pour le gabarit) :
- **Contexte** : le verrou dev-only était trois `if` shell lisibles par le demandeur ; le GOAL
  G4 exige un contrôle qu'un pipeline compromis ne contourne pas.
- **Décision** : (1) l'axe env est SCELLÉ sur les chemins d'authoring (constante de lib) ;
  (2) l'ouverture d'un palier est un GESTE DE CREDENTIAL (mint AppRole `apply-<env>` / grant
  humain), jamais un edit de code ; (3) définitions de pipeline et référence de déploiement
  sous protection de branche Gitea, posée par script et à la création des dépôts.
- **Ce que ça ne ferme PAS** (copier depuis la spec §6.1) : le config.xml Jenkins gagne sur le
  Jenkinsfile (frontière = admin Jenkins, hors Git) ; le verbe de promotion (G5) ; qui
  DÉCLENCHE (G2, DeployerGroup) ; la sémantique protected_file_patterns tant que la mesure
  live n'a pas tourné.
- **Parkings avec clause de réouverture** : `apim_ss_authoring_env` surchargeable (rouvrir
  quand G5 rend le rôle déclenchable par un tiers — c'est écrit dans
  `apim_promote_api/defaults/main.yml:106-110`) ; wildcard `envs/+` de stoa-proxy-provision
  (rouvrir si la pose de proxy devient déclenchable par un tiers).

- [ ] **Step 2: Mettre à jour ENVIRONNEMENTS.md et le GOAL**

ENVIRONNEMENTS.md : une section « Ouvrir un palier (G4) » — le geste opérateur exact
(`setup-vault-paliers.sh --mint apply-<env>` / grant nominatif), et la phrase : « aucun edit
de code n'ouvre un palier ». GOAL : dans l'en-tête de G4, ajouter « **LIVRÉ 2026-08-26** —
voir ADR-082 et HANDOFF-2026-08-26-G4-RETENTION-CREDENTIAL.md » sans réécrire le corps.

- [ ] **Step 3: Écrire le handoff**

Format du handoff G3 (`HANDOFF-2026-08-26-G3-REFERENCE-DEPLOIEMENT.md`) : tableau des portes
avec les COMPTES RÉELS consignés au fil des tâches ; « À LIRE EN PREMIER » = D1 (scellement,
pas ouverture) et ce que ça coûte (l'onboarding hors authoring n'est pas exprimable — clause
de réouverture) ; « Ce que G4 ne prouve PAS » (spec §6.1 + résultats live réels ou
`LAB_ABSENT`) ; points ouverts ordonnés (gestes G1 en attente, poussée gitea, mesure
protected_file_patterns si non faite, brief G5 : PIN_NON_RESOLU sur PR fait, archive verbe à
brancher, apim_ss_authoring_env à sceller quand G5 câble).

- [ ] **Step 4: Commit**

```bash
cd /Users/torpedo/hlfh-repos/stoa-labs
git add -A poc-control-plane-federation
git commit -m "docs(g4): ADR-082 — l'ouverture d'un palier est un geste de credential"
```

---

## Ce que ce plan ne fait PAS

- Il ne branche AUCUN verbe de déploiement sur les paliers ouverts par credential — c'est G5
  (import d'archive, les deux moteurs).
- Il n'ajoute pas `DeployerGroup` (G2) ni ne prouve la parité des moteurs (G8).
- Il ne pose PAS les protected_file_patterns en production de lab tant que la mesure live n'a
  pas statué — la baseline whitelist est posée, la mesure est livrée comme épreuve.
- Il ne crée aucun compte Gitea d'équipe (le demandeur n'en a pas aujourd'hui — fait 8 de la
  spec) : il rend les protections POSABLES et PROUVÉES avec un utilisateur jetable.
- Il ne touche pas aux deux gestes G1 en attente (release-team, seed governance) — gestes
  exploitant, `! bash`.
