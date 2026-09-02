---
title: "Plan — A4, les portes de la chaîne et l'axe déployeur au dispatch de provision-apply"
type: plan
status: "EN COURS 2026-09-02 — T0..T8 inline, TDD (chaque suite vue rouge avant le code) ; preuve finale par BUILDS réels (T7)"
date: 2026-09-02
spec: docs/superpowers/specs/2026-09-02-a4-portes-de-la-chaine-au-dispatch-design.md
---

# A4 — plan d'implémentation

> **Pour un exécutant sans contexte** : lire d'abord la spec (D0..D9) ; chaque tâche nomme son épreuve AVANT son code (TDD) ; la preuve finale est par BUILDS réels sur le lab (T7), les tâches T0..T6 sont vérifiables hors ligne. Exécution **inline** (superpowers:executing-plans), un seul écrivain : le mode de défaillance « narration prématurée » des sous-agents est mesuré et cher (mémoire g2-axe-qui-deploie).

**But :** `provision-apply` lit `environments.yaml` (validé) par la lib et applique la porte du palier AVANT la pause et AU DISPATCH (fourEyes fail-closed sur un demandeur de service, refs/ITSM, terminus par position, déclaration déployeur confrontée) ; l'aval vérifie `deployerGroup` sur le token de la pause avant le ticket et relaie son refus jusqu'à la PR ; la contre-épreuve « deux portes, une source » est prouvée hors ligne ; la porte du GOAL est jouée par builds réels.

**Architecture :** une fonction additive de lib (`env_chain_validate`) ; un script de porte amont (`scripts/provision-apply-gate.sh`, ne parle qu'à la chaîne et à l'ITSM) joué deux fois par `ci/Jenkinsfile.provision-apply` ; une §2bis dans la garde A3 (`scripts/selfservice-palier-gate.sh`) + `REFUS_OUT` relayé par `ci/Jenkinsfile.selfservice` ; le rapport de PR étendu ; une suite hors ligne neuve (`scripts/test-provision-apply-a4.sh`), des cas additifs dans les suites A3 et env-chain ; une suite live par builds réels (`scripts/test-a4-live.sh`).

**Stack :** bash 3.2 (poste) / dash (agent Jenkins, `sh '''…'''`), python3 + PyYAML, curl, Vault KV v2 (dev, lab), wM 10.15 REST, Jenkins 2.541 déclaratif from SCM, Gitea 1.22, OpenLDAP (lab), itsm-mock.

**Spec :** `docs/superpowers/specs/2026-09-02-a4-portes-de-la-chaine-au-dispatch-design.md`

## Contraintes globales (copiées de la spec)

- Aucun `job.xml` porteur de logique ; le Jenkinsfile ROUTE, le script DÉCIDE ; aucune re-pose de job ; aucun XML touché.
- La porte amont tourne DEUX fois (`GATE_STAGE=pre` avant `input(`, `GATE_STAGE=dispatch` sous le `node` post-pause avant la garde d'identité) ; les deux lignes d'appel portent `STOA_ENV_CHAIN_FILE="$PWD/clients/_example/environments.yaml"` ; l'aval porte `STOA_ENV_CHAIN_FILE="$GATE_DIR/clients/_example/environments.yaml"` sur la ligne d'appel de sa garde.
- Ordre du script amont : forme → `env_chain_validate` (`CHAINE_INVALIDE`) → `ENV_INVALIDE`/`CHAINE_ILLISIBLE` → lecture de la porte (`PARSE_GATE`, `DEPLOYER_GROUP_UNSUPPORTED` hors famille OU `apim-apply-<x>` ≠ palier) → refs sur le manifeste MERGÉ (`MANIFESTE_ABSENT`, `MANIFESTE_ILLISIBLE`, `REF_INVALIDE`, `GATE_REFS_REQUIRED`) → quatre yeux (`MERGER_UNKNOWN`, `REQUESTER_UNKNOWN`, `FOUR_EYES_VIOLATION`/`IDENTITE_REFUSEE`, `CABLAGE_INCOMPLET`) → ITSM (`ITSM_NOT_CONFIGURED`, `ITSM_NOT_APPROVED`, `ITSM_UNAVAILABLE`) → terminus par position (`TERMINUS_SANS_VOIE`) → `GATE_OUT` (`SORTIE_INVALIDE`).
- Ordre de la garde A3 : §0 forme + `env_chain_validate` + `chaîne :` → §1 voie → §2 équipe (lookup-self) → **§2bis déployeur** (`DEPLOYER_GROUP_UNSUPPORTED`/`UNVERIFIABLE`/`REQUIRED`) → §3 capacités → §4 ticket → §5 sortie ; `REFUS_OUT="${REFUS_OUT:-}"` AVANT `refus()`, `rm -f "$REFUS_OUT"` en tête, écriture conditionnelle avant `exit 1`.
- Refus : rc 1, `REFUS: <TAG> : …` sur stdout, `GATE_OUT`/`PALIER_OUT` jamais écrits ; le refus amont est commenté sous `<!-- provision-apply-refus -->` avec `REFUSAL_KIND=porte`.
- Toutes les variables d'env lues `${X:-}` (Jenkins n'exporte pas une variable vide) ; classe de `GATE_OUT` `[A-Za-z0-9_.@:+-]*` (`GATE_ENV`, `GATE_STAGE`, `GATE_ALLOW_SELF` jamais vides) vérifiée à l'écriture (python) ET à la lecture (Groovy `==~`, sinon `PORTE_ILLISIBLE`) ; `APPLIED_REFUSAL` classe `[A-Z][A-Z0-9_]{2,40}`.
- Refs : `safe_load` + `str(d.get(k) or "")`, classe `^[A-Za-z0-9][A-Za-z0-9._-]*$`, saut de ligne refusé ; ITSM : `curl -sS --path-as-is [--cacert] --max-time 20`, 200+approved passe, 200 autre/404 ⇒ `ITSM_NOT_APPROVED`, autre ⇒ `ITSM_UNAVAILABLE`.
- Quatre yeux pré-pause : `sh "$SELF_DIR/lib/assert-merge-identity.sh" --merged-by M --requester R --vault-user M` SANS `--map`, stdout/stderr capturés, rc 0 ⇒ `porte(<stage>) : mergeur ≠ demandeur — identité non prouvée à ce stade`, rc 1 ⇒ tag extrait `^[A-Z][A-Z0-9_]+` (sinon `IDENTITE_REFUSEE`), rc ≥ 2 ⇒ `CABLAGE_INCOMPLET` ; demandeur absent/vide/∈ `GITEA_SERVICE_LOGINS` (défaut `ci`) ⇒ `REQUESTER_UNKNOWN`.
- Marqueurs de console (preuves) : `chaîne : `, `PORTE_OK(pre) : palier `, `PORTE_OK(dispatch) : palier `, `porte(pre) : `, `itsm : change '…' approved`, `REFUS: <TAG>`, `déclaration déployeur : `, `palier ouvert :`, `préflight de joignabilité :`, `PLAY [Self-service application — converge`, `auto-approbation admise par la porte`.
- Pièges bash 3.2 : pas de `mapfile`, pas de `declare -A`, pas d'apostrophe dans `${X:?…}`, pas d'apostrophe dans un heredoc python sous `$( )`, tableaux vides `${A[@]+"${A[@]}"}`, `case`/`grep -E` plutôt que `[[ =~ ]]`.
- Suites existantes INCHANGÉES dans leurs assertions : `test-provision-apply-wiring.sh` 142/142, `test-provision-apply-a2.sh` 148/148, `test-a0-wiring.sh` 176/176, `test-palier-retention.sh` 137/0, `test-merge-identity.sh` 19/19, `test-app-request-a1.sh` 49/49 (hors ligne), `test-team-promote-wiring.sh` ; `make lint-ci` passe à `[13/13]`.
- Lab : identité alice (LDAP `deploy-banking-demo apply-dev apply-rec`), carol (compte Gitea humain à créer par la suite), `APPLY_ADMIN_VIA=direct`, gateway réelle, `itsm-mock` `CHG-0001 approved` / `CHG-0002 draft`, `apim-apply-int` = bob seul, `envs/int/wm-admin` valide sur la gateway ; les manifestes jetables n'ont PAS de `team:` (providers.<env>.yml n'existe que pour dev).

---

## Carte des fichiers

| Fichier | Rôle | Tâche |
|---|---|---|
| `scripts/lib/env-chain.sh` (modifier, additif) | `env_chain_validate` | T0 |
| `scripts/test-env-chain.sh` (modifier, additif) | ⑤ `env_chain_validate` : gabarit + 5 sabotages | T0 |
| `scripts/provision-apply-gate.sh` (créer) | la porte amont : forme, chaîne, porte, refs, quatre yeux, ITSM, terminus, sortie, refus commenté | T1 |
| `scripts/provision-apply-comment.sh` (modifier) | `REFUSAL_KIND=porte`, ligne « porte du palier » (`GATE_*`) | T1 |
| `scripts/test-provision-apply-a4.sh` (créer) | suite hors ligne : A porte amont (fixtures git + stub ITSM + enregistreur + shim git + mutations) ; B câblage amont (+ fragment `$AMI` EXÉCUTÉ, mutations d'ordre) ; C câblage aval ; D rapport ; E deux portes, une source | T1, T2, T3, T4 |
| `ci/Jenkinsfile.provision-apply` (modifier) | knobs ; porte pré-pause ; porte au dispatch + relecture `GATE_*` ; garde avec `PORTE_INCOHERENTE`/`$AMI` ; `APPLIED_REFUSAL` ; message du post | T2 |
| `scripts/selfservice-palier-gate.sh` (modifier) | `REFUS_OUT`, `env_chain_validate`, `chaîne :`, §2bis | T3 |
| `ci/Jenkinsfile.selfservice` (modifier) | `REFUS_OUT` + `STOA_ENV_CHAIN_FILE` sur la ligne d'appel, purges absolues, `post{always}` du stage Apply | T3 |
| `scripts/test-selfservice-palier-a3.sh` (modifier, additif A.30+, B) | §2bis, `REFUS_OUT`, `CHAINE_INVALIDE`, terminus+voie, mutations, ordre | T3 |
| `scripts/app-request-choices.sh` (modifier, 2 lignes) | `env_chain_validate` ⇒ `CHAINE_INVALIDE` | T4 |
| `Makefile` (modifier) | `[13/13]`, shellcheck du nouveau script | T5 |
| `scripts/test-a4-live.sh` (créer) | preuve par builds réels (D7) | T6, T7 |
| `ENVIRONNEMENTS.md`, `adr/adr-084-…md`, `GOAL-cd-applications-2026-09-02.md`, spec/plan (statuts), mémoire | docs | T8 |

---

## T0 — `env_chain_validate` (lib, additif) + `test-env-chain.sh` ⑤

**Files:** modify `scripts/lib/env-chain.sh` (fin de fichier), modify `scripts/test-env-chain.sh` (avant le total).
**Produces:** `env_chain_validate` (rc 0 ; rc 1 + `env-chain: <fichier> : <cause>` sur stderr) — lu par T1, T3, T4.

- [ ] **Étape 1 — l'épreuve, rouge d'abord.** Ajouter à `scripts/test-env-chain.sh`, après le bloc ④ (avant `printf '\n%d PASS`), une section ⑤ :

```bash
echo "⑤ env_chain_validate — le gabarit livré est valide, cinq sabotages sont refusés (A4, D0)"
# shellcheck source=scripts/lib/env-chain.sh
. "$ROOT/scripts/lib/env-chain.sh"
if type env_chain_validate >/dev/null 2>&1; then ok "env_chain_validate existe"; else bad "env_chain_validate ABSENTE de la lib"; fi
V="$(mktemp -d)"; trap 'cp "$BAK" "$CHAIN"; rm -f "$BAK"; rm -rf "$V"' EXIT INT TERM
cp "$CHAIN" "$V/ok.yaml"
( STOA_ENV_CHAIN_FILE="$V/ok.yaml" env_chain_validate ) 2>"$V/err" && ok "gabarit livré : valide" || bad "gabarit livré REFUSÉ : $(cat "$V/err")"
sab(){ # <nom> <sed-expr> <fragment de cause attendu>
  sed -E "$2" "$CHAIN" > "$V/$1.yaml"
  cmp -s "$CHAIN" "$V/$1.yaml" && { bad "sabotage $1 NO-OP (l'ancre a bougé)"; return; }
  if ( STOA_ENV_CHAIN_FILE="$V/$1.yaml" env_chain_validate ) 2>"$V/err"; then bad "sabotage $1 ACCEPTÉ (vert vacant)"
  elif grep -q "$3" "$V/err"; then ok "sabotage $1 refusé : $(tail -1 "$V/err" | cut -c1-90)"
  else bad "sabotage $1 refusé pour une autre cause : $(cat "$V/err")"; fi
}
sab to-inconnu   's/^  - to: int$/  - to: itn/'                       "ne nomme aucun environnement"
sab cle-inconnue 's/^    fourEyes: true$/    foureyes: true/'          "inconnue"
sab bool-texte   's/^    itsmCheck: true$/    itsmCheck: "true"/'      "booleen"
sab to-double    's/^  - to: homol$/  - to: int/'                     "deux fois"
sab env-majuscule 's/^environments: \[dev, rec, int, homol, prod\]$/environments: [dev, rec, int, homol, Prod]/' "hors de"
```

- [ ] **Étape 2 — la voir rouge.** `bash scripts/test-env-chain.sh` ⇒ « env_chain_validate ABSENTE » (le reste inchangé, 11 PASS avant).

- [ ] **Étape 3 — la fonction**, à la fin de `scripts/lib/env-chain.sh` :

```bash
# env_chain_validate — VALIDE la chaîne AVANT qu'un lecteur ne la lise (A4, D0).
#
# POURQUOI : env_chain_gate fait `next((x for x in gates if x.get("to") == env), {})`
# — une porte `to: itn` ou une clé `foureyes:` mal orthographiée rend un palier
# SANS AUCUN CONTRÔLE, sans aucun journal : le vert vacant parfait. Le parseur Go
# (ParseEnvChain) refuse un `to` non déclaré ou dupliqué mais n'est pas dans la
# boucle des applications, et n'est pas strict sur les clés inconnues. Ici, le
# shell est PLUS strict (liste blanche des clés, booléens YAML, forme des noms) :
# une chaîne acceptée ici l'est par Go — le sens sûr. Écart enregistré (ADR-087).
# rc 0 ; rc 1 + `env-chain: <fichier> : <cause>` sur stderr. Aucun repli.
env_chain_validate() {
  local f; f="$(_env_chain_file)"
  [ -r "$f" ] || { echo "env-chain: source illisible : $f" >&2; return 1; }
  python3 - "$f" <<'PY' || return 1
import re, sys, yaml
p = sys.argv[1]
def bad(msg):
    sys.stderr.write("env-chain: %s : %s\n" % (p, msg)); sys.exit(1)
try:
    d = yaml.safe_load(open(p, encoding="utf-8"))
except Exception as e:
    bad("YAML illisible (%s)" % type(e).__name__)
if not isinstance(d, dict):
    bad("document racine : mapping attendu")
envs = d.get("environments")
if not isinstance(envs, list) or not envs:
    bad("'environments' absent ou vide")
seen = set()
for e in envs:
    if not isinstance(e, str) or not re.fullmatch(r"[a-z0-9]+", e):
        bad("environnement %r hors de [a-z0-9]+" % (e,))
    if e in seen:
        bad("environnement '%s' declare deux fois" % e)
    seen.add(e)
gates = d.get("gates")
if gates is None:
    gates = []
if not isinstance(gates, list):
    bad("'gates' : liste attendue")
ALLOWED = ("to", "selfApproval", "approverGroup", "fourEyes", "requireChangeRef", "requirePVRef", "itsmCheck", "deployerGroup")
BOOLS = ("selfApproval", "fourEyes", "requireChangeRef", "requirePVRef", "itsmCheck")
NAMES = ("approverGroup", "deployerGroup")
tos = set()
for i, g in enumerate(gates):
    if not isinstance(g, dict):
        bad("gates[%d] : mapping attendu" % i)
    unknown = sorted(k for k in g if k not in ALLOWED)
    if unknown:
        bad("gates[%d] : cle(s) inconnue(s) %s (attendu : %s)" % (i, ", ".join(str(k) for k in unknown), ", ".join(ALLOWED)))
    to = g.get("to")
    if not isinstance(to, str) or to not in seen:
        bad("gates[%d] : 'to: %s' ne nomme aucun environnement declare" % (i, to))
    if to in tos:
        bad("porte '%s' declaree deux fois" % to)
    tos.add(to)
    for k in BOOLS:
        if k in g and not isinstance(g[k], bool):
            bad("porte '%s' : %s doit etre un booleen YAML (true/false), pas %r" % (to, k, g[k]))
    for k in NAMES:
        if k in g and (not isinstance(g[k], str) or not re.fullmatch(r"[A-Za-z0-9._-]+", g[k])):
            bad("porte '%s' : %s hors de [A-Za-z0-9._-] (%r)" % (to, k, g[k]))
PY
}
```

- [ ] **Étape 4 — verte.** `bash scripts/test-env-chain.sh` ⇒ 18 PASS / 0 FAIL ; `shellcheck -x scripts/lib/env-chain.sh` propre ; `go test` de la lib inchangé (aucun fichier Go touché).
- [ ] **Étape 5 — commit** : `git add scripts/lib/env-chain.sh scripts/test-env-chain.sh && git commit -m "feat(env-chain): env_chain_validate — la chaîne est validée avant d'être lue (A4 D0)"`.

---

## T1 — `scripts/provision-apply-gate.sh` + rapport + section A de la suite hors ligne

**Files:** create `scripts/provision-apply-gate.sh` ; modify `scripts/provision-apply-comment.sh` ; create `scripts/test-provision-apply-a4.sh` (sections 0, A, D — B/C/E viennent en T2/T3/T4).
**Consumes:** `env_chain_validate`, `env_chain`, `env_chain_gate`, `env_chain_gate_four_eyes`, `env_chain_gate_itsm_check`, `env_chain_gate_deployer_group`, `deployer_group_policy`, `env_chain_terminus`, `_env_chain_file` (lib) ; `scripts/lib/assert-merge-identity.sh` ; `scripts/provision-apply-comment.sh`.
**Produces:** le script (entrées/sorties de la spec D1) ; `provision-apply-comment.sh` accepte `REFUSAL_KIND` et `GATE_ENV/GATE_FOUR_EYES/GATE_APPROVER_GROUP/GATE_DEPLOYER_GROUP/GATE_DEPLOYER_POLICY/GATE_ITSM`.

- [ ] **Étape 1 — la suite, sections 0 + A + D, rouge d'abord.** Créer `scripts/test-provision-apply-a4.sh` sur le squelette de `test-selfservice-palier-a3.sh` (`ok`/`bad`, `TMP`, trap, `EXPECTED_CHECKS` en dur contrôlé à la fin). Fixtures :
  - **arborescence jetable** `$TMP/tree/scripts/{provision-apply-gate.sh, provision-apply-comment.sh(enregistreur), lib/env-chain.sh, lib/assert-merge-identity.sh}` + `$TMP/tree/clients/_example/environments.yaml` (copie du gabarit) — l'enregistreur écrit toutes ses variables `APPLY_RESULT REFUSAL REFUSAL_KIND REFUSAL_DETAIL PR_NUMBER APP_NAME ENV_NAME` dans `$TMP/comment.log` (une ligne `K=V` chacune, `---` entre deux appels) et ne poste rien ;
  - **shim `git`** en tête de `PATH` : `$TMP/bin/git` = `printf '%s\n' "$*" >> "$TMP/git.log"; exec /usr/bin/env -u PATH… ` — plus simplement : `#!/bin/sh` `printf '%s\n' "$*" >> "$GIT_LOG"; exec "$REAL_GIT" "$@"` avec `REAL_GIT="$(command -v git)"` capturé avant de préfixer le PATH ;
  - **dépôt git local** (motif A2) : bare `$TMP/origin.git` + clone `$TMP/work` ; commit c1 = `clients/provisioned/applications/appa.ansible.yml` multi-palier :

```yaml
---
apim_ss_app:
  name: "appa"
  api: "demo-selfservice"
  api_version: "1.0.0"
  auth:
    mode: "idp"
    claim: { name: "azp" }
  per_env:
    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"] }
    int: { auth: { claim: { value: "appa-int" } }, ip_allowlist: ["10.42.0.3"] }
    homol: { auth: { claim: { value: "appa-homol" } } }
    prod: { auth: { claim: { value: "appa-prod" } }, change_ref: "CHG-1", pv_ref: "PV-1" }
```
    et des commits frères c2..c5 (branche `variants`, chaque variante = un commit dont on garde le SHA) : `homol` avec `pv_ref: "PV-2"` ; `homol` avec `pv_ref: null` ; `prod` avec `change_ref: ".."` ; `prod` avec `change_ref: "CHG;1"` ; `prod` avec `change_ref: "CHG\n1"` (écrit `change_ref: "CHG\n1"` en YAML à guillemets doubles = saut de ligne réel) ;
  - **stub ITSM** (`python3 http.server`, `GET /changes/<id>` piloté par `$TMP/itsm.json` `{"CHG-1": {"code":200,"status":"approved"}}`, défaut 404 ; journal `$TMP/itsm.log` des chemins bruts) ; **auto-test** `GET /changes/selftest` au démarrage, `grep -q '/changes/selftest' itsm.log || exit 2` ;
  - `run_gate <env> <mergeur> <demandeur> [VAR=val | UNSET:VAR …]` : `rm -f "$OUTF"`, `env ${UNS…} ENV_NAME=… APP_NAME=appa MANIFEST=clients/provisioned/applications/appa.ansible.yml MERGE_SHA="$C1" GITEA_MERGED_BY=… GITEA_REQUESTER=… PR_NUMBER=42 GITEA_TOKEN=stub GATE_OUT="$OUTF" GIT_WORKTREE="$TMP/work" STOA_ENV_CHAIN_FILE="$TMP/tree/clients/_example/environments.yaml" ITSM_URL="http://127.0.0.1:$IPORT" PATH="$TMP/bin:$PATH" GIT_LOG="$TMP/git.log" REAL_GIT="$REAL_GIT" bash "${GATE_BIN:-$TMP/tree/scripts/provision-apply-gate.sh}" > "$TMP/g.out" 2>&1; echo $? > "$TMP/g.rc"` ; `refus <TAG>` = rc 1 + `^REFUS: <TAG> :` ; `out_val K` ; `itsm_calls` = `grep -c '^/changes/' itsm.log` ; `git_shows` = `grep -c '^-C .* show ' git.log` (ou `grep -c ' show '`).
  - **Cas A** (numérotés A.1…) tels que la spec D6 §A les liste, chacun `ok`/`bad` ; les mutations A.M1..A.M6 par `sed` sur une copie (`cmp` anti-no-op, `bash -n`) : ancres `^if \[ "\$FOUREYES" = 1 \]; then$` → `if false; then` (quatre-yeux retiré) ; `for s in \$GITEA_SERVICE_LOGINS; do` → `for s in; do` (comptes de service) ; `\[ "\$NEED_PV" = 0 \] \|\| \[ -n "\$MK_PV" \]` → `true` ; `^if \[ "\$ITSMCHECK" = 1 \]; then$` → `if false; then` ; `DEPLOYER_POLICY=\$\(deployer_group_policy "\$DEPLOYER_GROUP"\) \|\| refus DEPLOYER_GROUP_UNSUPPORTED` → `DEPLOYER_POLICY=x || true` ; `^env_chain_validate 2>` → `true 2>` (validate retiré).
  - **Section D** (rapport) : stub `scripts/lib/gitea-pr-comment.sh` dans une copie de `scripts/` qui copie `COMMENT_BODY_FILE` vers `$TMP/body.md` ; cas : `REFUSED`+`REFUSAL_KIND=porte` ⇒ body contient `porte du palier` et PAS `ne correspondent pas` ; `REFUSED` sans kind ⇒ texte A2 inchangé ; `FAILURE`+`REFUSAL=DEPLOYER_GROUP_REQUIRED` ⇒ `Refus \`DEPLOYER_GROUP_REQUIRED\`` ; `GATE_ENV=int GATE_FOUR_EYES=1 GATE_APPROVER_GROUP=int-team GATE_DEPLOYER_GROUP=apim-apply-int GATE_DEPLOYER_POLICY=apply-int GATE_ITSM=none` ⇒ ligne `porte du palier \`int\`` avec `non vérifiée` et `apim-apply-int` ; `GATE_ENV` vide ⇒ aucune ligne `porte du palier`.

- [ ] **Étape 2 — la voir rouge.** `bash scripts/test-provision-apply-a4.sh` ⇒ le script absent fait rougir tous les A.x ; D.x rougissent (pas de `porte du palier`).

- [ ] **Étape 3 — le script** `scripts/provision-apply-gate.sh` (en-tête = spec D1 condensée ; `chmod +x`) :

```bash
#!/usr/bin/env bash
# provision-apply-gate.sh — A4 (GOAL cd-applications) : LA PORTE DE LA CHAÎNE au
# dispatch de provision-apply — environments.yaml DÉCIDE (fourEyes, refs/ITSM,
# terminus par position, déclaration déployeur), la §6/§6bis/§6ter de
# team-promote.sh portée au second objet. Jouée DEUX fois par le Jenkinsfile :
# GATE_STAGE=pre (avant la pause : personne n'est réveillé pour un refus certain)
# et GATE_STAGE=dispatch (au geste : anti-TOCTOU ADR-075 — c'est CE passage qui
# nourrit la garde d'identité et le rapport). Ne parle qu'à la CHAÎNE (fichier,
# par la lib, chemin ÉPINGLÉ par l'appelant) et, si la porte le déclare, à l'ITSM.
# Jamais Vault (aucun token à l'amont), jamais la gateway.
# Refus : rc 1, `REFUS: <TAG> : …` sur stdout, GATE_OUT jamais écrit, commentaire
# de PR sous le marqueur des refus (REFUSAL_KIND=porte), best-effort.
set -uo pipefail
set +x
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SELF_DIR/.." || exit 1
# shellcheck source=scripts/lib/env-chain.sh
. "$SELF_DIR/lib/env-chain.sh" || { echo "REFUS: CABLAGE_INCOMPLET : $SELF_DIR/lib/env-chain.sh introuvable"; exit 1; }

ENV_NAME="${ENV_NAME:-}"; APP_NAME="${APP_NAME:-}"; MANIFEST="${MANIFEST:-}"; MERGE_SHA="${MERGE_SHA:-}"
GITEA_MERGED_BY="${GITEA_MERGED_BY:-}"; GITEA_REQUESTER="${GITEA_REQUESTER:-}"
PR_NUMBER="${PR_NUMBER:-}"; GITEA_TOKEN="${GITEA_TOKEN:-}"
GATE_OUT="${GATE_OUT:-}"; GATE_STAGE="${GATE_STAGE:-pre}"
ITSM_URL="${ITSM_URL:-}"; ITSM_CACERT="${ITSM_CACERT:-}"
APIM_TERMINUS_BASE="${APIM_TERMINUS_BASE:-}"
GITEA_SERVICE_LOGINS="${GITEA_SERVICE_LOGINS:-ci}"
GIT_WORKTREE="${GIT_WORKTREE:-.}"; MANIFEST_DIR="${MANIFEST_DIR:-clients/provisioned/applications}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"; GIT_HOST="${GIT_HOST:-http://gitea:3000}"; GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"
case "$GATE_STAGE" in pre|dispatch) ;; *) GATE_STAGE=pre ;; esac
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; umask 077
[ -n "$GATE_OUT" ] || { echo "REFUS: CABLAGE_INCOMPLET : GATE_OUT absent (le Jenkinsfile doit nommer le fichier de sortie)"; exit 1; }
rm -f "$GATE_OUT"
shown(){ printf '%q' "$(printf '%s' "${1:-}" | head -c 80)"; }
refus(){ # <TAG> <journal> [<détail pour la PR, borné>]
  local tag="$1" logmsg="$2" prmsg="${3:-}"
  printf 'REFUS: %s : %s\n' "$tag" "$logmsg"
  if [ -n "$PR_NUMBER" ] && [ -n "$GITEA_TOKEN" ]; then
    PR_NUMBER="$PR_NUMBER" APPLY_RESULT=REFUSED REFUSAL="$tag" REFUSAL_KIND=porte REFUSAL_DETAIL="$prmsg" \
      APP_NAME="${APP_NAME:-(inconnue)}" ENV_NAME="${ENV_NAME:-(inconnu)}" \
      GIT_REPO="$GIT_REPO" GIT_HOST="$GIT_HOST" GIT_WEB_HOST="$GIT_WEB_HOST" GITEA_TOKEN="$GITEA_TOKEN" BUILD_URL="${BUILD_URL:-}" \
      bash "$SELF_DIR/provision-apply-comment.sh" >/dev/null 2>&1 || true
  fi
  exit 1
}
# (le corps : §0..§7 — voir la spec D1 ; le code intégral est dans le fichier livré)
```
    puis §0..§7 exactement comme la spec D1 les décrit (voir le fichier créé — le plan ne les recopie pas pour rester lisible ; les ancres de mutation de la suite les figent).

- [ ] **Étape 4 — le rapport** `scripts/provision-apply-comment.sh` : ajouter `REFUSAL_KIND="${REFUSAL_KIND:-}" GATE_ENV="${GATE_ENV:-}" GATE_FOUR_EYES="${GATE_FOUR_EYES:-}" GATE_APPROVER_GROUP="${GATE_APPROVER_GROUP:-}" GATE_DEPLOYER_GROUP="${GATE_DEPLOYER_GROUP:-}" GATE_DEPLOYER_POLICY="${GATE_DEPLOYER_POLICY:-}" GATE_ITSM="${GATE_ITSM:-}"` à l'invocation python ; dans le python : après les lignes `build :`, si `GATE_ENV` non vide (classe `[a-z0-9]+`), ajouter la ligne « porte du palier » ; dans la branche `REFUSED`, si `REFUSAL_KIND == "porte"` : « **CE webhook n'a rien appliqué.** Refus `TAG` : detail. » + « La porte du palier (`environments.yaml`) a refusé avant la demande en attente — aucune identité n'a été demandée. Corriger la cause (annuaire, référence ITSM, identité du demandeur) puis rejouer le webhook. » ; sinon le texte A2 inchangé.

- [ ] **Étape 5 — verte.** `bash scripts/test-provision-apply-a4.sh` ⇒ sections 0/A/D vertes ; `shellcheck -x scripts/provision-apply-gate.sh scripts/provision-apply-comment.sh` ; `bash scripts/test-provision-apply-a2.sh` 148/148 (section C du rapport inchangée).
- [ ] **Étape 6 — commit** : `git add scripts/provision-apply-gate.sh scripts/provision-apply-comment.sh scripts/test-provision-apply-a4.sh && git commit -m "feat(provision-apply): la porte de la chaîne — provision-apply-gate.sh (A4 D1) + rapport REFUSAL_KIND/porte du palier"`.

---

## T2 — `ci/Jenkinsfile.provision-apply` : la porte deux fois, la garde, l'écoute de l'aval + section B

**Files:** modify `ci/Jenkinsfile.provision-apply` ; modify `scripts/test-provision-apply-a4.sh` (section B).
**Consumes:** `scripts/provision-apply-gate.sh` (T1), `GATE_OUT` (10 clés).

- [ ] **Étape 1 — section B, rouge d'abord** (vue code `code_view`, `code_line`, `line_after`) : les contrôles de la spec D6 §B, dont le **fragment exécuté** :

```bash
# la chaîne sh '…' de la ligne de garde, extraite et JOUÉE sous sh avec un stub de la garde
L_G=$(code_line "$TMP/jf.code" 'sh scripts/lib/assert-merge-identity.sh')
FRAG=$(sed -n "${L_G}p" "$TMP/jf.code" | sed -E "s/^ *sh '(.*)'$/\1/")
mkdir -p "$TMP/frag/scripts/lib"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$FRAG_LOG"\n' > "$TMP/frag/scripts/lib/assert-merge-identity.sh"
run_frag(){ ( cd "$TMP/frag" && FRAG_LOG="$TMP/frag.log" GATE_ENV="$1" ENV_NAME="$2" GATE_ALLOW_SELF="$3" GITEA_MERGED_BY=alice GITEA_REQUESTER=carol V_USER=alice sh -c "$FRAG" ) >"$TMP/frag.out" 2>&1; echo $?; }
: > "$TMP/frag.log"; RC=$(run_frag int int 1); grep -q -- '--allow-self-approval' "$TMP/frag.log" && ok "B.x GATE_ALLOW_SELF=1 ⇒ la garde reçoit --allow-self-approval (fragment EXÉCUTÉ)" || bad "…"
: > "$TMP/frag.log"; RC=$(run_frag int int 0); grep -q -- '--allow-self-approval' "$TMP/frag.log" && bad "…" || ok "B.x GATE_ALLOW_SELF=0 ⇒ pas de drapeau"
: > "$TMP/frag.log"; RC=$(run_frag rec int 1); [ "$RC" = 1 ] && grep -q PORTE_INCOHERENTE "$TMP/frag.out" && [ ! -s "$TMP/frag.log" ] && ok "B.x GATE_ENV≠ENV_NAME ⇒ PORTE_INCOHERENTE, garde jamais appelée" || bad "…"
```
    et les mutations d'ordre (awk déplace la ligne `GATE_STAGE=pre` après `def creds = input(` ⇒ le détecteur d'ordre rougit ; suppression de la ligne `GATE_STAGE=dispatch` ⇒ rougit ; `STOA_ENV_CHAIN_FILE=` retiré ⇒ rougit ; `$AMI` retiré ⇒ le fragment exécuté ne porte plus le drapeau).

- [ ] **Étape 2 — rouge.** La suite rougit sur B.
- [ ] **Étape 3 — le Jenkinsfile** (spec D2) : (a) `environment{}` : `ITSM_URL`, `ITSM_CACERT`, `APIM_TERMINUS_BASE`, `GITEA_SERVICE_LOGINS` ; (b) stage Réconciliation, après le `script{}` des six clés : `sh 'set +x; STOA_ENV_CHAIN_FILE="$PWD/clients/_example/environments.yaml" GATE_STAGE=pre GATE_OUT="$WORKSPACE/.a4-gate.env" bash scripts/provision-apply-gate.sh'` ; (c) stage Apply, dans le `node` post-pause sous `dir(…)` et AVANT la garde : `withCredentials([string(credentialsId: env.GITEA_CREDENTIALS_ID, variable: 'GITEA_TOKEN')]) { sh 'set +x; STOA_ENV_CHAIN_FILE="$PWD/clients/_example/environments.yaml" GATE_STAGE=dispatch GATE_OUT="$WORKSPACE/.a4-gate.env" bash scripts/provision-apply-gate.sh' }`, relecture `readFile` + `==~ /[A-Za-z0-9_.@:+-]*/` (sinon `error("PORTE_ILLISIBLE : …")`) + 10 `env.GATE_* = gk.GATE_* ?: ''` + `echo` de la porte relue ; (d) la ligne de garde : `sh 'set +x; [ "${GATE_ENV:-}" = "${ENV_NAME:-}" ] || { echo "REFUS: PORTE_INCOHERENTE : la porte relue au dispatch ne porte pas ce palier — rien n est applique"; exit 1; }; AMI=""; [ "${GATE_ALLOW_SELF:-0}" = 1 ] && AMI=--allow-self-approval; sh scripts/lib/assert-merge-identity.sh --merged-by "${GITEA_MERGED_BY:-}" --requester "${GITEA_REQUESTER:-}" --vault-user "${V_USER:-}" $AMI'` (pas d'apostrophe dans le message : la chaîne est en quotes simples) ; (e) après `build(…)` : `def ar = (vars.APPLIED_REFUSAL ?: '').toString(); env.APPLIED_REFUSAL = (ar ==~ /[A-Z][A-Z0-9_]{2,40}/) ? ar : ''` puis, dans le verdict, `else if (env.APPLY_RESULT != 'SUCCESS' && env.APPLIED_REFUSAL) { env.REFUSAL = env.APPLIED_REFUSAL; env.REFUSAL_DETAIL = "refus de l aval ${env.APPLY_BUILD} — voir sa console" }` ; (f) message FAILURE du `post` : ajouter « porte du palier (fourEyes, refs/ITSM, terminus, deployerGroup) ».
- [ ] **Étape 4 — verte.** `bash scripts/test-provision-apply-a4.sh` (A, B, D) ; `bash scripts/test-provision-apply-wiring.sh` 142/142 ; `ci/lint-jenkinsfiles.sh` compile.
- [ ] **Étape 5 — commit** : `git commit -m "feat(provision-apply): la porte jouée avant la pause et au dispatch, drapeau selfApproval à la garde, refus de l'aval jusqu'à la PR (A4 D2)"`.

---

## T3 — la garde A3 : `REFUS_OUT`, `env_chain_validate`, §2bis ; `ci/Jenkinsfile.selfservice` ; sections A.30+ / B d'A3 + section C d'A4

**Files:** modify `scripts/selfservice-palier-gate.sh` ; modify `ci/Jenkinsfile.selfservice` (stage Référence l.299, stage Apply l.436-450, `post{}` du stage Apply avant l.611) ; modify `scripts/test-selfservice-palier-a3.sh` (A.30+, B, `EXPECTED_CHECKS`) ; modify `scripts/test-provision-apply-a4.sh` (section C).

- [ ] **Étape 1 — les épreuves, rouges d'abord.** Dans `test-selfservice-palier-a3.sh`, après A.27 : chaîne jetable `$TMP/chain-int.yaml` (gabarit copié, `int: deployerGroup: apim-apply-int`) ; cas A.30 token `[deploy-banking-demo, apply-int, default]` + kv int 200 ⇒ rc 0, `déclaration déployeur : 'alice' porte 'apply-int'` (avec `VAULT_USER=alice`), pas de `$TMP/refus` ; A.31 token sans `apply-int` ⇒ `DEPLOYER_GROUP_REQUIRED`, `jcount capabilities-self` = 0, aucune lecture KV, canari muet, `REFUS_OUT` = `DEPLOYER_GROUP_REQUIRED` ; A.31b sans `REFUS_OUT` posé (UNSET:REFUS_OUT) ⇒ même refus, même ligne ; A.32 `deployerGroup: int-team` ⇒ `DEPLOYER_GROUP_UNSUPPORTED` ; A.33 `int: deployerGroup: apim-apply-rec` ⇒ `DEPLOYER_GROUP_UNSUPPORTED` ; A.34 `rec` sans déclaration ⇒ un seul `lookup-self`, rc 0 ; A.35 `prod` + `APIM_TERMINUS_BASE` + token sans `operator-deploy` ⇒ `DEPLOYER_GROUP_REQUIRED` ; A.36 chaîne `to: itn` ⇒ `CHAINE_INVALIDE`, `jcount lookup-self` = 0 ; A.37 `chaîne : ` imprimé avec le chemin posé ; A.M7 mutation §2bis retiré (`^if \[ -n "\$DEPLOYER_GROUP" \]; then$` → `if false; then`) ⇒ A.31 passe sur le mutant puis `PALIER_FERME` (kv int 403) — l'original refuse `DEPLOYER_GROUP_REQUIRED`. Section B : `L_DEP=$(line_after "$L_LOGIN" 'déclaration déployeur' …)` — NON : la vue code du Jenkinsfile ne porte pas le script ; asserter dans la vue code du SCRIPT (`code_view scripts/selfservice-palier-gate.sh`) l'ordre `env_chain_gate_deployer_group` < `sys/capabilities-self` < `kv_data_path "$WM_SUB"`/ticket `GET`, et la mutation « bloc §2bis déplacé après le ticket » (awk) ⇒ rouge ; dans le Jenkinsfile : `REFUS_OUT="$WORKSPACE/.a3-refus"` ET `STOA_ENV_CHAIN_FILE="$GATE_DIR/clients/_example/environments.yaml"` sur la ligne d'appel ; `rm -f "$WORKSPACE/.a3-refus"` avant l'appel ET au stage Référence ; `post { always {` avec `fileExists(` + `==~ /[A-Z][A-Z0-9_]{2,40}/` + `env.APPLIED_REFUSAL =`. `EXPECTED_CHECKS` 145 → nouveau total. Section C d'A4 = les mêmes ancres Jenkinsfile (rejouées dans la suite A4).
- [ ] **Étape 2 — rouge.**
- [ ] **Étape 3 — la garde** : `REFUS_OUT="${REFUS_OUT:-}"` avant `refus()` ; `refus(){ printf 'REFUS: %s : %s\n' "$1" "$2"; [ -n "$REFUS_OUT" ] && printf '%s\n' "$1" > "$REFUS_OUT"; exit 1; }` ; après `rm -f "$PALIER_OUT"` : `[ -n "$REFUS_OUT" ] && rm -f "$REFUS_OUT"` ; §0 avant `CHAIN=` : `echo "chaîne : $(_env_chain_file)"` puis `env_chain_validate 2>"$TMP/validate.err" || refus CHAINE_INVALIDE "$(tail -1 "$TMP/validate.err")"` ; §2bis (code de la spec D3, entre `TEAM_NON_PORTEE` et `# ── 3.`).
- [ ] **Étape 4 — le Jenkinsfile de l'aval** : l.299 ajouter une ligne `rm -f "$WORKSPACE/.a3-refus"` après la purge relative ; l.449 (`PALIER_OUT=… rm -f "$PALIER_OUT"`) ajouter `rm -f "$WORKSPACE/.a3-refus"` ; l.450 la ligne d'appel devient `STOA_ENV_CHAIN_FILE="$GATE_DIR/clients/_example/environments.yaml" REFUS_OUT="$WORKSPACE/.a3-refus" PALIER_OUT="$PALIER_OUT" MANIFEST="$MANIFEST" bash "$GATE_DIR/scripts/selfservice-palier-gate.sh" || exit 1` ; `post { always { script { … } } }` du stage Apply (code de la spec D3) inséré entre la fin de `steps {` (l.610) et la fermeture du stage (l.611).
- [ ] **Étape 5 — verte** : `bash scripts/test-selfservice-palier-a3.sh` (nouveau total), `bash scripts/test-provision-apply-a4.sh`, `bash scripts/test-a0-wiring.sh` 176/176, `bash scripts/test-provision-apply-wiring.sh` 142/142, `bash scripts/test-palier-retention.sh` 137/0, `ci/lint-jenkinsfiles.sh`.
- [ ] **Étape 6 — commit** : `git commit -m "feat(selfservice-app-deploy): §2bis — la déclaration déployeur vérifiée sur le token avant le ticket, REFUS_OUT relayé à l'amont, chaîne validée et épinglée (A4 D3)"`.

---

## T4 — deux portes, une source : `app-request-choices.sh` + section E

**Files:** modify `scripts/app-request-choices.sh` (après `. scripts/lib/env-chain.sh`) ; modify `scripts/test-provision-apply-a4.sh` (section E).

- [ ] **Étape 1 — section E, rouge d'abord** : chaîne jetable `environments: [dev, rec, homol, prod]` (sans `int`) + `gates: []` ; (a) `app-request-choices.sh` contre le « Gitea » bare local du motif `test-a0-wiring` §6 (copier `mk_platform`) ⇒ `ENVS=dev rec homol` ; (b) `provision-request.sh` `REQ_ENV=int` (cwd racine poc, `REQ_APP=x REQ_API=y REQ_CLIENT_ID=z GITEA_TOKEN=dummy GIT_HOST=http://127.0.0.1:1`, `PATH` avec le shim git) ⇒ rc 2, stderr `REFUS: ENV_INVALIDE`, `git.log` vide ; (c) la porte amont `ENV_NAME=int` ⇒ `ENV_INVALIDE`, aucun `show` dans `git.log` ; (d) `selfservice-palier-gate.sh` `ENVIRONMENT=int` (stub Vault non nécessaire : le refus précède tout appel — `VAULT_ADDR=http://127.0.0.1:1`) ⇒ `ENV_INVALIDE` ; (e) chaîne `to: itn` ⇒ `app-request-choices.sh` rc ≠ 0 + `CHAINE_INVALIDE`, aucun `CHOICES_OUT` écrit.
- [ ] **Étape 2 — rouge** (e).
- [ ] **Étape 3 — le poseur** : après le source de la lib : `env_chain_validate 2>"$TMP/validate.err" || refus "CHAINE_INVALIDE : $(tail -1 "$TMP/validate.err")"` (adapter au `refus` local du script et à son `TMP`).
- [ ] **Étape 4 — verte** ; `bash scripts/test-a0-wiring.sh` 176/176.
- [ ] **Étape 5 — commit** : `git commit -m "feat(app-request): le formulaire refuse une chaîne invalide (CHAINE_INVALIDE) — deux portes, une source prouvé (A4 D5)"`.

---

## T5 — `Makefile` `[13/13]` + passage complet hors ligne

- [ ] Renuméroter les 12 échos en `/13`, ajouter `scripts/provision-apply-gate.sh` à la liste `shellcheck -x` du pas [2/13], ajouter le pas `[13/13] épreuves des portes de la chaîne au dispatch — porte amont, câblages, rapport, deux portes une source (A4)` = `bash scripts/test-provision-apply-a4.sh`.
- [ ] `make lint-ci` ⇒ [13/13] vert ; totaux notés.
- [ ] commit : `git commit -m "ci(lint-ci): [13/13] épreuves A4"`.

---

## T6 — `scripts/test-a4-live.sh` (écriture) — lab : Gitea + Jenkins + Vault + LDAP + 10.15 + itsm-mock

**Files:** create `scripts/test-a4-live.sh` sur le squelette de `test-a3-live.sh` (helpers Gitea/Jenkins/gateway/Vault repris tels quels ; `ldap_run` repris de `test-deployer-gate-live.sh` ; `MUTATED=0` déclaré AVANT le trap).

Helpers neufs :
- `human_pr <branche> <hdr-humain> <titre>` : `gapi -X PATCH -d '{"state":"closed"}' /pulls/<n-ci>` puis `curl -H @hdr POST /pulls {head: branche, base: main, title}` ⇒ numéro ; assertion `user.login` == l'humain ;
- `request_branch <env> <ip>` : `provision-request.sh` (token ci, `PROVISION_PLAN_INLINE=false`, sans `REQ_TEAM`) ⇒ `PR_URL` ⇒ numéro de la PR de `ci` (à fermer) + branche `provision/<app>-<env>` ;
- `merge_as_alice <pr>` (`aapi POST /merge`), `merge_sha <pr>` ;
- `wait_no_pause <build>` : `wfapi/describe` ⇒ stages `Réconciliation…` FAILED et `Appliquer…` NOT_EXECUTED, jamais `PAUSED_PENDING_INPUT` ;
- `answer_pause <build>` (repris d'A3) ;
- `ldap_add_alice_int` / `ldap_del_alice_int` (LDIF `add: member` / `delete: member`, `printf --`), `alice_in_int` (ldapsearch) ;
- `gw_state` : `gw_app "$APP"` ⇒ claims + IP ;
- `pr_refus_comment <pr> <TAG>` : `pr_comments` contient `provision-apply-refus`… avec le tag.

Déroulé = spec D7 §0..§8, numéros de contrôles `0.x, 1.x … 8.x`, `RÉSULTAT : N/N` en fin, nettoyage par trap (manifeste retiré de main, application supprimée, PR fermées + branches supprimées, alice retirée d'int si `MUTATED=1`).

- [ ] Écrire le script ; `bash -n` ; `shellcheck -x scripts/test-a4-live.sh` ; ajouter à la liste shellcheck du Makefile (jamais exécuté par lint-ci).
- [ ] commit : `git commit -m "test(a4-live): la porte et les contre-épreuves d'A4 par builds réels (écriture)"`.

---

## T7 — Rollout + preuve live

- [ ] `git fetch gitea && git rebase gitea/main` si nécessaire, puis `git push gitea HEAD:main || exit 1` (jamais enchaîner une suite live après un push refusé).
- [ ] Préconditions manuelles : `docker restart poc-webmethods-real` si uptime ≥ 20 min (keepalive) ; `.env.lab-users` lisible.
- [ ] `JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage bash scripts/test-a4-live.sh` ⇒ N/N. Défauts trouvés ⇒ corriger, re-jouer les suites hors ligne, re-push gitea, re-jouer.
- [ ] Régression : `bash scripts/test-a3-live.sh` 54/54 ; `bash scripts/test-provision-apply-a2-live.sh` 60/60.
- [ ] `git add` des artefacts de suite (la forge pousse des commits sur main : les rapatrier par `git pull --rebase gitea main` AVANT tout push) ; commit `test(a4-live): …`.

---

## T8 — Documentation, statuts, mémoire

- [ ] `ENVIRONNEMENTS.md` : section « Les portes de la chaîne au dispatch (A4 — GOAL cd-applications, 2026-09-02) » (ce qui a changé, le dessin des deux passages, les codes, les knobs `ITSM_URL`/`ITSM_CACERT`/`APIM_TERMINUS_BASE`/`GITEA_SERVICE_LOGINS`, rollout, limites : `REQUESTER_UNKNOWN` sur les voies livrées, approuver = porter, approverGroup non vérifié, homol refuse sans pv_ref, mono-gateway) ; la section A3 : la phrase « A4 (groupe déployeur, ITSM) … posent le reste » mise à jour.
- [ ] `adr/adr-084-axe-qui-deploie-deployer-group.md` : section « Extension 2026-09-02 (A4, GOAL cd-applications) — le second objet » (le motif de l'extension A3 d'ADR-082) ; « Limites nommées » : « approverGroup … » complétée (approuver = porter sur les deux chaînes Gitea).
- [ ] `GOAL-cd-applications-2026-09-02.md` : bloc « LIVRÉ » sous A4 (totaux, builds, codes, limites), en-tête `status`, reformulation de la porte A4 (« même individu »), tableau des briques (axe déployeur / portes : FERMÉ par A4).
- [ ] spec + plan : `status` finalisés.
- [ ] Mémoire : `a4-portes-de-la-chaine-au-dispatch.md` + index + `cd-applications-goal.md` (état : A4 LIVRÉ, prochain A5).
- [ ] commit docs ; `git push gitea HEAD:main`.
