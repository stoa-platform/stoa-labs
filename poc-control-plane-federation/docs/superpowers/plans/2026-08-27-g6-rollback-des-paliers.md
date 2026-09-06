# G6 — Rollback des paliers : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Étendre le rollback (aujourd'hui prod-only côté Jenkins) à tout palier non-authoring, l'exercer live sur homol (retour au SHA N-1, smoke vert, trace Git), et prouver le refus sans change_ref sur un palier qui l'exige.

**Architecture:** Le moteur (`handlers_rollback.go`) est déjà générique par palier — on aligne UNE condition de garde (change_ref exigé si `RequireChangeRef || ITSMCheck`, symétrie avec la demande) ; le gros du geste est `ci/Jenkinsfile.rollback` : le palier vient de `restored.environment` de la réponse du POST (jamais saisi), la voie de re-apply se choisit par POSITION dans la chaîne (terminus = voie ci-applier/Vault direct existante ; intermédiaire = voie ci-horsprod/proxy du pipeline aller), le smoke mesure l'état restauré (catalogue à la version N-1). La preuve : tests go offline + script live sur chaîne 5 paliers + builds Jenkins si les gestes exploitant passent.

**Tech Stack:** Go (net/http, air-gapped vendored), Jenkins declarative pipeline (sh = dash), bash 3.2-compatible, curl/python3, governance-api + labctl apply-uac, wM mocks + proxies `wm-admin-<env>`.

**Spec:** `docs/superpowers/specs/2026-08-27-g6-rollback-des-paliers-design.md` (le plan argumente depuis elle ; l'exécutant lit les deux). GOAL : `GOAL-cd-promotion-5-envs-2026-08-26.md` §G6.

## Global Constraints

- Commits en français, format `type(g6): description` (commitlint).
- Go : TOUJOURS `GOPROXY=off GOFLAGS=-mod=vendor GOSUMDB=off`, tests avec `-count=1` (piège du cache mesuré G1).
- Bash : compatible 3.2 macOS (pas de `mapfile`) ; les `sh` Jenkins sont du **dash** (pas de tableaux) ; pas d'apostrophe française dans `${VAR:?msg}` (piège G1).
- Secrets : jamais en argv/env/log ; fichiers 0600 ; `set +x` dans tout sh qui en touche.
- Fail-closed partout : une source illisible est une ERREUR, jamais un défaut deviné.
- Ne PAS convertir le verbe governance (apply-uac) vers l'archive : tension parquée ADR-083, périmètre G8.
- Aucun DELETE gateway, jamais (le rollback est revert Git + re-apply).
- `make lint-ci` doit rester 8/8 (il compile les Jenkinsfile — toute édition de `ci/Jenkinsfile.rollback` y passe).
- Rendu de sous-agent jamais cru sur parole : le contrôleur vérifie par `git log`/grep (défaillance « narration prématurée » mesurée G2).

---

### Task 1: Alignement de la garde change_ref au rollback + tests offline

**Files:**
- Modify: `labctl/cmd/governance-api/handlers_rollback.go:51-58`
- Test: `labctl/cmd/governance-api/handlers_rollback_test.go` (3 tests ajoutés en fin de fichier)

**Interfaces:**
- Consomme les helpers existants de `handlers_gates_test.go` : `newChainServer(t, extra, itsmURL)` (NB : une clé `"environments.yaml"` dans `extra` REMPLACE la chaîne fixture — c'est l'ordre d'écriture de `seedChainRepo`), `newITSMStub`, `requestPromotion`, `do`, `errCode`, `fix.sign`, `gitT`, `chainSeedDeploy`.
- Produit : le code d'erreur `GATE_REFS_REQUIRED` au rollback couvre désormais `itsmCheck` ; aucun changement d'API.

- [ ] **Step 1: Écrire les 3 tests (dont un qui ROUGIT sur le code actuel)**

Ajouter en fin de `handlers_rollback_test.go` :

```go
// Contre-épreuve G6 (GOAL) : un palier dont le gate exige un change_ref
// l'exige AUSSI au rollback — refus nommé, avant toute lecture d'historique.
func TestRollbackRequiresChangeRefWhenGateDemandsIt(t *testing.T) {
	chain := "environments: [dev, rec]\ngates:\n  - {to: rec, requireChangeRef: true}\n"
	_, h, fix := newChainServer(t, map[string]string{
		"environments.yaml": chain,
		"tenants/banking-demo/apis/payments-initiation/deploy.rec.yaml": chainSeedDeploy,
	}, "")
	carol := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	promoID := requestPromotion(t, h, carol,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "rec",
			"message": "vers rec", "change_ref": "CHG-0007"})
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", carol,
		map[string]any{"message": "ok"}); code != 200 {
		t.Fatalf("approve = %d %v", code, body)
	}
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "régression"}); code != 400 || errCode(body) != "GATE_REFS_REQUIRED" {
		t.Fatalf("rollback sans change_ref = %d %v (attendu 400 GATE_REFS_REQUIRED)", code, body)
	}
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "régression", "change_ref": "CHG-0008"}); code != 200 {
		t.Fatalf("rollback avec change_ref = %d %v", code, body)
	}
}

// Trou de symétrie (spec D3) : à la DEMANDE le change_ref est exigé dès que
// itsmCheck est posé (rien à vérifier sans lui) ; le rollback doit faire de
// même. Ce test ROUGIT sur le code d'avant G6 (seul RequireChangeRef testé).
func TestRollbackChangeRefAlignedWithITSMCheck(t *testing.T) {
	_, itsm := newITSMStub(t, map[string]string{"CHG-0007": "approved"})
	chain := "environments: [dev, rec]\ngates:\n  - {to: rec, itsmCheck: true}\n"
	_, h, fix := newChainServer(t, map[string]string{
		"environments.yaml": chain,
		"tenants/banking-demo/apis/payments-initiation/deploy.rec.yaml": chainSeedDeploy,
	}, itsm.URL)
	carol := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	promoID := requestPromotion(t, h, carol,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "rec",
			"message": "vers rec", "change_ref": "CHG-0007"})
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", carol,
		map[string]any{"message": "ok"}); code != 200 {
		t.Fatalf("approve = %d %v", code, body)
	}
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "régression"}); code != 400 || errCode(body) != "GATE_REFS_REQUIRED" {
		t.Fatalf("rollback sans change_ref (gate itsmCheck) = %d %v (attendu 400)", code, body)
	}
}

// Décision D3 (spec) : le pv_ref n'est PAS exigé au rollback — l'état restauré
// a porté le sien quand il a été promu. Chaîne 5 paliers, palier homol pv-only ;
// la restauration est VERBATIM, pin `commit` du N-1 compris.
func TestRollbackHomolPVOnlyRestoresVerbatimPin(t *testing.T) {
	const homolSeed = "version: 0.9.0\nenabled: true\npromoted_by: seed\ncommit: deadbeef00\n"
	chain := "environments: [dev, rec, int, homol, prod]\ngates:\n  - {to: homol, requirePVRef: true}\n"
	srv, h, fix := newChainServer(t, map[string]string{
		"environments.yaml": chain,
		"tenants/banking-demo/apis/payments-initiation/deploy.rec.yaml":   chainSeedDeploy,
		"tenants/banking-demo/apis/payments-initiation/deploy.int.yaml":   chainSeedDeploy,
		"tenants/banking-demo/apis/payments-initiation/deploy.homol.yaml": homolSeed,
	}, "")
	carol := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	// Garde de la DEMANDE (déjà en place) : sans pv_ref, refus.
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", carol,
		map[string]any{"slug": "payments-initiation", "from": "int", "to": "homol",
			"message": "vers homol"}); code != 400 || errCode(body) != "GATE_REFS_REQUIRED" {
		t.Fatalf("request homol sans pv_ref = %d %v", code, body)
	}
	promoID := requestPromotion(t, h, carol,
		map[string]any{"slug": "payments-initiation", "from": "int", "to": "homol",
			"message": "vers homol", "pv_ref": "PV-2026-099"})
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", carol,
		map[string]any{"message": "ok"}); code != 200 {
		t.Fatalf("approve = %d %v", code, body)
	}
	// Rollback avec la seule reason : ni change_ref ni pv_ref exigés ici.
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "KO recette homol"})
	if code != 200 {
		t.Fatalf("rollback homol = %d %v", code, body)
	}
	restored := body["restored"].(map[string]any)
	if restored["environment"] != "homol" || restored["version"] != "0.9.0" || restored["commit"] != "deadbeef00" {
		t.Fatalf("restored state wrong: %v", restored)
	}
	deployRaw := gitT(t, srv.Store.Repo.Dir, "show", "main:tenants/banking-demo/apis/payments-initiation/deploy.homol.yaml")
	if deployRaw != homolSeed {
		t.Fatalf("deploy.homol.yaml pas restauré verbatim:\n%q\nwant\n%q", deployRaw, homolSeed)
	}
}
```

- [ ] **Step 2: Vérifier que le test de symétrie ROUGIT (et que les 2 autres passent)**

Run: `cd labctl && GOPROXY=off GOFLAGS=-mod=vendor GOSUMDB=off go test ./cmd/governance-api -run 'TestRollback' -count=1 -v`
Attendu : `TestRollbackChangeRefAlignedWithITSMCheck` FAIL (`rollback sans change_ref (gate itsmCheck) = 200`) ; `TestRollbackRequiresChangeRefWhenGateDemandsIt` et `TestRollbackHomolPVOnlyRestoresVerbatimPin` PASS (elles documentent l'existant), les 3 tests historiques PASS.

- [ ] **Step 3: Aligner la condition dans `handlers_rollback.go`**

Remplacer (l.51-58) :

```go
	// The rollback of a gated environment is itself a change: same change_ref
	// requirement as the forward hop (fail at the earliest).
	gate := chain.Gates[promo.To]
	if gate.RequireChangeRef && body.ChangeRef == "" {
```

par :

```go
	// The rollback of a gated environment is itself a change: same change_ref
	// requirement as the forward hop (fail at the earliest) — itsmCheck implies
	// a change_ref there too, so it does here. pv_ref is deliberately NOT
	// demanded: the restored state carried its own when it was promoted (D3,
	// adr-085); the motivation lives in `reason` + change_ref.
	gate := chain.Gates[promo.To]
	if (gate.RequireChangeRef || gate.ITSMCheck) && body.ChangeRef == "" {
```

- [ ] **Step 4: Tout vert**

Run: `cd labctl && GOPROXY=off GOFLAGS=-mod=vendor GOSUMDB=off go test ./cmd/governance-api -count=1`
Attendu : PASS complet (les tests gates/promotions existants ne changent pas : sur la chaîne fixture, prod portait déjà `requireChangeRef`).

- [ ] **Step 5: Commit**

```bash
git add labctl/cmd/governance-api/handlers_rollback.go labctl/cmd/governance-api/handlers_rollback_test.go
git commit -m "fix(g6): la garde change_ref du rollback s'aligne sur la demande — itsmCheck l'implique, pv_ref jamais (D3)"
```

---

### Task 2: `ci/Jenkinsfile.rollback` — le palier vient de la promotion, deux voies de re-apply, smoke d'état

**Files:**
- Modify: `ci/Jenkinsfile.rollback` (réécriture des stages ; params et cloneGovernance conservés)

**Interfaces:**
- Consomme : `ci/lib/vault-login.sh` (`vault_login_any` exporte `VAULT_TOKEN_FILE` ; `vault_read`, `vault_tmpfile`, `form_post_no_argv`, `vault_trap_revoke`) ; la réponse JSON du POST rollback (`restored.environment`, `restored.version`, `promotion.slug`) ; `governance/environments.yaml` du clone post-revert ; `envs/<env>/targets.cluster.yaml`.
- Produit : fichiers de workspace `rollback-env.txt`, `rollback-version.txt`, `rollback-slug.txt`, `rollback-terminus.flag` (contrat interne aux stages de CE pipeline).

- [ ] **Step 1: Assouplir la validation des paramètres (stage `Rollback governance`)**

Dans le sh du stage, remplacer :

```sh
              [ -n "$PROMOTION_ID" ] && [ -n "$REASON" ] && [ -n "$CHANGE_REF" ] \
                || { echo 'PROMOTION_ID, REASON et CHANGE_REF sont requis'; exit 1; }
```

par :

```sh
              # CHANGE_REF n'est requis que si le gate du palier de la promotion
              # l'exige (prod aujourd'hui) — c'est governance-api qui le sait et
              # refuse GATE_REFS_REQUIRED fail-closed. Le job ne devine pas.
              [ -n "$PROMOTION_ID" ] && [ -n "$REASON" ] \
                || { echo 'PROMOTION_ID et REASON sont requis'; exit 1; }
```

Et mettre à jour la `description` du paramètre `CHANGE_REF` : `'Change ITSM couvrant le rollback — REQUIS si le gate du palier de la promotion exige une référence de changement (prod), refusé GATE_REFS_REQUIRED sinon vide'`. Mettre à jour aussi le commentaire d'en-tête du fichier (l.1-7) : le pipeline n'est plus « ROLLBACK PROD » mais « ROLLBACK DU PALIER DE LA PROMOTION (G6, ADR-085) — prod ET paliers intermédiaires ».

- [ ] **Step 2: Capturer le palier restauré depuis la réponse (fin du même sh, après le check HTTP)**

Après `[ "$CODE" = 200 ] || [ "$CODE" = 201 ] || …`, ajouter :

```sh
              # D1 (adr-085) : le palier du rollback n'est JAMAIS saisi — il est
              # celui de la promotion, relu dans la réponse. Absent => refus.
              python3 - /tmp/rollback-resp.json "$WORKSPACE" <<'PYCAP'
import json, sys
d = json.load(open(sys.argv[1])); ws = sys.argv[2]
env = (d.get("restored") or {}).get("environment") or ""
ver = (d.get("restored") or {}).get("version") or ""
slug = (d.get("promotion") or {}).get("slug") or ""
if not env or not slug:
    sys.exit("reponse rollback sans restored.environment / promotion.slug — refus fail-closed")
open(ws + "/rollback-env.txt", "w").write(env)
open(ws + "/rollback-version.txt", "w").write(ver)
open(ws + "/rollback-slug.txt", "w").write(slug)
PYCAP
              echo "✓ promotion $PROMOTION_ID annulée côté governance (palier: $(cat "$WORKSPACE/rollback-env.txt"), raison: $REASON)"
```

(La ligne `echo "✓ promotion …"` existante est remplacée par celle-ci.)

- [ ] **Step 3: Nouveau stage `Palier du rollback (fail-closed)` après `Checkout governance (post-revert)`**

```groovy
    stage('Palier du rollback — chaîne dérivée, fail-closed') {
      steps {
        dir('poc-control-plane-federation') {
          sh '''
            set -eu
            RENV=$(cat "$WORKSPACE/rollback-env.txt")
            # Même dérivation que ci/Jenkinsfile : la chaîne vient du clone
            # governance post-revert, jamais d'une liste en dur.
            CHAIN=$(python3 - governance/environments.yaml <<'PYCHAIN'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
e = d.get("environments") or []
if len(e) < 2:
    sys.exit("environments.yaml: chaine trop courte ou absente")
print(" ".join(e))
PYCHAIN
            ) || { echo "chaine d environnements illisible (governance/environments.yaml)"; exit 1; }
            FIRST=${CHAIN%% *}; LAST=${CHAIN##* }
            echo "$CHAIN" | tr ' ' '\\n' | grep -qx "$RENV" \
              || { echo "ROLLBACK_ENV_INCONNU: $RENV hors chaine ($CHAIN)"; exit 1; }
            # Défense en profondeur : structurellement aucune promotion n'a
            # To == premier palier (NextOf ne rend jamais chain[0]).
            [ "$RENV" != "$FIRST" ] \
              || { echo "ROLLBACK_ENV_INELIGIBLE: $RENV est le palier d authoring"; exit 1; }
            # Terminus par POSITION, pas par nom (motif env_chain_nonprod).
            if [ "$RENV" = "$LAST" ]; then printf yes > "$WORKSPACE/rollback-terminus.flag"
            else printf no > "$WORKSPACE/rollback-terminus.flag"; fi
            echo "=== palier du rollback: $RENV (terminus: $(cat "$WORKSPACE/rollback-terminus.flag")) ==="
          '''
        }
      }
    }
```

- [ ] **Step 4: Le stage de re-apply prod devient `Re-apply terminus`, palier lu du fichier**

Renommer le stage `Re-apply PROD — convergence de l'état Git reverté` en `Re-apply terminus — convergence de l'état Git reverté`, le garder tel quel à deux changements près : ajout d'un `when` et le palier depuis le fichier.

```groovy
    stage('Re-apply terminus — convergence de l\'état Git reverté') {
      when { expression { readFile('rollback-terminus.flag').trim() == 'yes' } }
```

et dans son sh, remplacer la ligne d'apply :

```sh
              RENV=$(cat "$WORKSPACE/rollback-env.txt")
              LABCTL_TOKEN_FILE="$TOKFILE" "$WORKSPACE/labctl" apply-uac \
                --repo governance --env "$RENV" --tenant "$APPLY_TENANT" -f "envs/$RENV/targets.cluster.yaml"
```

- [ ] **Step 5: Nouveau stage `Re-apply + smoke palier intermédiaire` (voie ci-horsprod/proxy)**

```groovy
    stage('Re-apply + smoke palier intermédiaire — via wm-admin-<env>') {
      when { expression { readFile('rollback-terminus.flag').trim() == 'no' } }
      steps {
        dir('poc-control-plane-federation') {
          withCredentials([string(credentialsId: 'vault-ci-secret-id', variable: 'VAULT_SECRET_ID')]) {
            sh '''
              set +x
              set -eu
              RENV=$(cat "$WORKSPACE/rollback-env.txt")
              RVER=$(cat "$WORKSPACE/rollback-version.txt")
              RSLUG=$(cat "$WORKSPACE/rollback-slug.txt")
              # Même login mutualisé que le terminus : NOMINATIF si l'opérateur a
              # saisi VAULT_USER (G2 : son token porte apply-<env> via l'annuaire),
              # sinon repli AppRole ci-pipeline — qui n'ouvre les paliers gardés
              # par deployerGroup que si --grant-ci a été déclaré (ADR-084).
              . ci/lib/vault-login.sh
              trap 'vault_trap_revoke; rm -f /tmp/stoa-wm-admin-token' EXIT
              vault_login_any || exit 1
              CI_SECRET=$(vault_read secret/data/stoa/ci ciApplierSecret)
              HP_SECRET=$(vault_read secret/data/stoa/ci ciHorsprodSecret)
              OPENSEARCH_PASSWORD=$(vault_read secret/data/stoa/opensearch adminPassword)
              export OPENSEARCH_PASSWORD
              # ci-applier -> mediation apply-uac ; ci-horsprod -> Bearer des
              # proxies wm-admin-<env> (scope deploy:<env>, jamais le terminus).
              KCRESP=$(vault_tmpfile kc-resp.json)
              printf 'client_id=ci-applier\\ngrant_type=client_credentials\\nclient_secret=%s\\n' "$CI_SECRET" \\
                | form_post_no_argv "$KCRESP" http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/token >/dev/null
              unset CI_SECRET
              TOKFILE=$(vault_tmpfile labctl-token)
              python3 -c 'import json,sys;open(sys.argv[2],"w").write(json.load(open(sys.argv[1]))["access_token"])' \\
                "$KCRESP" "$TOKFILE"
              [ -s "$TOKFILE" ] || { echo 'no CI token'; exit 1; }
              HPRESP=$(vault_tmpfile hp-resp.json)
              printf 'client_id=ci-horsprod\\ngrant_type=client_credentials\\nclient_secret=%s\\n' "$HP_SECRET" \\
                | form_post_no_argv "$HPRESP" http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/token >/dev/null
              unset HP_SECRET
              # bearerTokenFile déclaré par envs/*/targets.cluster.yaml — chemin FIXE.
              ( umask 077; python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["access_token"],end="")' \\
                  "$HPRESP" > /tmp/stoa-wm-admin-token )
              [ -s /tmp/stoa-wm-admin-token ] || { echo 'no ci-horsprod token'; exit 1; }
              [ -d governance/.git ] || { echo 'governance/ absent (stage Checkout KO ?)'; exit 1; }
              LABCTL_TOKEN_FILE="$TOKFILE" VAULT_TOKEN_FILE="$VAULT_TOKEN_FILE" "$WORKSPACE/labctl" apply-uac \\
                --repo governance --env "$RENV" --tenant "$APPLY_TENANT" -f "envs/$RENV/targets.cluster.yaml"
              # SMOKE D5 : le catalogue du palier, via SON proxy admin, doit
              # porter l'API restaurée A LA VERSION N-1 — l'état, pas un ping.
              "$WORKSPACE/labctl" get apis -f "envs/$RENV/targets.cluster.yaml" -o json > /tmp/rollback-catalog.json
              python3 - /tmp/rollback-catalog.json "$RSLUG" "$RVER" <<'PYSMOKE'
import json, sys
d = json.load(open(sys.argv[1])); slug, ver = sys.argv[2], sys.argv[3]
apis = [a for t in d.get("targets", []) for a in (t.get("apis") or [])]
hit = [a for a in apis if a.get("name") == slug and (not ver or a.get("version") == ver)]
if not hit:
    sys.exit("SMOKE KO: %s@%s absent du catalogue restaure (%s)" % (slug, ver or "?", 
             ", ".join("%s@%s" % (a.get("name"), a.get("version")) for a in apis) or "vide"))
print("SMOKE OK — %s@%s present dans le catalogue du palier" % (slug, ver or "?"))
PYSMOKE
              echo "✓ rollback $RENV converge — etat N-1 servi via wm-admin-$RENV"
            '''
          }
        }
      }
    }
```

- [ ] **Step 6: Le smoke terminus gagne l'assertion d'état (catalogue N-1) en plus du 401**

Dans le stage `Smoke test — data-plane prod (état reverté)` (renommé `Smoke terminus — data-plane + catalogue N-1`), ajouter `when { expression { readFile('rollback-terminus.flag').trim() == 'yes' } }` et remplacer le sh par :

```sh
            set -eu
            RENV=$(cat "$WORKSPACE/rollback-env.txt")
            RVER=$(cat "$WORKSPACE/rollback-version.txt")
            RSLUG=$(cat "$WORKSPACE/rollback-slug.txt")
            "$WORKSPACE/labctl" get apis -f "envs/$RENV/targets.cluster.yaml" -o json > /tmp/rollback-catalog.json
            python3 - /tmp/rollback-catalog.json "$RSLUG" "$RVER" <<'PYSMOKE'
import json, sys
d = json.load(open(sys.argv[1])); slug, ver = sys.argv[2], sys.argv[3]
apis = [a for t in d.get("targets", []) for a in (t.get("apis") or [])]
hit = [a for a in apis if a.get("name") == slug and (not ver or a.get("version") == ver)]
if not hit:
    sys.exit("SMOKE KO: %s@%s absent du catalogue restaure" % (slug, ver or "?"))
print("SMOKE OK — %s@%s present dans le catalogue du palier" % (slug, ver or "?"))
PYSMOKE
            CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
              "http://webmethods-real:5555/gateway/accounts-read/1.0.0/accounts")
            echo "data-plane sans token -> HTTP $CODE"
            [ "$CODE" = 401 ] || { echo "SMOKE KO: attendu 401 sans token (recu $CODE)"; exit 1; }
            echo 'SMOKE OK — rollback converge, barriere OAuth2 active.'
```

(Le check data-plane 401 reste propre au terminus : c'est la seule surface data-plane que Jenkins atteint ; l'URL `accounts-read/1.0.0` est le smoke historique du lab, conservé tel quel.)

- [ ] **Step 7: `post { success }` mis à jour**

```groovy
    success { echo '✓ rollback = revert Git audité + re-apply idempotent du PALIER DE LA PROMOTION (jamais de DELETE gateway).' }
```

- [ ] **Step 8: Lint**

Run: `make lint-ci`
Attendu : 8/8 vert (dont la compilation des Jenkinsfile — c'est elle qui attrape une faute de syntaxe declarative).

- [ ] **Step 9: Commit**

```bash
git add ci/Jenkinsfile.rollback
git commit -m "feat(g6): le rollback suit le palier de sa promotion — env relu de la réponse, deux voies de re-apply par position, smoke d'état N-1"
```

---

### Task 3: Preuve live — `scripts/test-rollback-paliers.sh` (chaîne 5 paliers, rollback homol réel)

**Files:**
- Create: `scripts/test-rollback-paliers.sh` (exécutable)

**Interfaces:**
- Consomme : le motif de `scripts/demo-multienv.sh` (governance-api éphémère sur repo scratch, `gov()`, `pid()`, `mint_user` via `scripts/get-oracle-token.sh`, `applyenv` via `envs/<env>/targets.yaml`, groupes KC posés idempotents) ; `scripts/setup-ci-horsprod.sh --mint` ; `scripts/setup-ci-applier.sh --mint` ; proxies `wm-admin-int` / `wm-admin-homol` (G5) ; mocks `poc-wm-mock-int` / `poc-wm-mock-homol`.
- Produit : la porte G6 « script live » — X/X PASS, lab remis à l'identique (restart des 2 mocks touchés, catalogues re-vérifiés vides).
- Prereqs (échec propre si absents) : lab up (compose poc+wm+envs), Vault seedé, identités alice/bob (setup-identity.sh), proxies posés.

- [ ] **Step 1: Écrire le script**

```bash
#!/usr/bin/env bash
# test-rollback-paliers.sh — G6 (ADR-085) : le repli, composant du déploiement,
# exercé LIVE sur homol avec la chaîne 5 paliers du gabarit. Porte du GOAL :
# retour au SHA N-1, smoke vert (catalogue du palier à la version N-1 via SON
# proxy admin), trace Git de l'acte (commit rolled_back + evidence + trailers).
# Contre-épreuves : rollback sans change_ref sur un palier qui l'exige (prod)
# => 400 GATE_REFS_REQUIRED ; double rollback => 409 ; 1er état => 409.
#
# Périmètre dit : le deployerGroup (G2) n'est PAS déclaré sur la chaîne scratch —
# l'axe « qui porte l'apply » a sa propre porte live (test-deployer-gate-live.sh,
# 21/21) et le preflight d'apply-uac est LE MÊME site de code pour l'aller et le
# re-apply du rollback. Ici on prouve le REPLI, pas le porteur.
#
# Prereqs : ceux de demo-multienv.sh + proxies wm-admin-{int,homol} (G5) +
# scope deploy:homol du client ci-horsprod (dérivé de la chaîne, G1).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KC="${KC_BASE:-http://localhost:8480}"
ITSM="${ITSM_URL:-http://localhost:8788}"
GPORT="${GOV_PORT:-8792}"; GOV="http://localhost:${GPORT}"
TENANT=banking-demo; SLUG=accounts-read
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
say() { printf '\n════════ %s ════════\n' "$*"; }

gov() {
  local m="$1" p="$2" t="$3" d="${4:-}"
  if [ -n "$d" ]; then
    CODE=$(curl -s -o /tmp/trp.json -w '%{http_code}' -X "$m" -H "Authorization: Bearer $t" \
      -H 'Content-Type: application/json' -d "$d" "$GOV/api/v1$p")
  else
    CODE=$(curl -s -o /tmp/trp.json -w '%{http_code}' -X "$m" -H "Authorization: Bearer $t" "$GOV/api/v1$p")
  fi
  cat /tmp/trp.json
}
pid() { python3 -c "import sys,json
try:
    d = json.load(sys.stdin)
    print((d.get('promotion') or {}).get('id') or d.get('id') or '')
except Exception:
    print('')"; }
jget() { python3 -c "import sys,json
d=json.load(open('/tmp/trp.json'))
cur=d
for k in sys.argv[1:]:
    cur=(cur or {}).get(k)
print(cur if cur is not None else '')" "$@"; }

say "0. Build air-gapped + repo governance jetable (chaîne 5 paliers) + governance-api"
BD="$(mktemp -d)"; LABCTL="$BD/labctl"; GAPI="$BD/governance-api"
( cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$LABCTL" . \
  && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$GAPI" ./cmd/governance-api ) || { echo build failed; exit 1; }

REPO="$(mktemp -d)/gov"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main; git -C "$REPO" config commit.gpgsign false
mkf() { mkdir -p "$(dirname "$REPO/$1")"; cat > "$REPO/$1"; }
# La chaîne du GABARIT (5 paliers) — sans deployerGroup (périmètre, cf. header).
mkf environments.yaml <<'Y'
environments: [dev, rec, int, homol, prod]
gates:
  - to: rec
    selfApproval: true
  - to: int
    approverGroup: int-team
    fourEyes: true
  - to: homol
    approverGroup: release-team
    fourEyes: true
    requirePVRef: true
  - to: prod
    approverGroup: release-team
    fourEyes: true
    requireChangeRef: true
    requirePVRef: true
    itsmCheck: true
Y
mkf tenants/$TENANT/apis/$SLUG/api.yaml <<'Y'
name: accounts-read
version: 1.0.0
tenant_id: banking-demo
status: published
endpoints: [{path: /accounts, methods: [GET], backend_url: http://microcks:8080/rest/Accounts+Read+API/1.0.0}]
Y
printf 'version: 1.0.0\nenabled: true\npromoted_by: alice\n' > "$REPO/tenants/$TENANT/apis/$SLUG/deploy.dev.yaml"
printf 'version: 1.0.0\nenabled: true\npromoted_by: alice\n' > "$REPO/tenants/$TENANT/apis/$SLUG/deploy.rec.yaml"
git -C "$REPO" add -A
git -C "$REPO" -c user.name="Alice Banking" -c user.email=alice@bank.example commit -q -m "feat(banking): accounts-read + deploy dev/rec (chaîne 5 paliers)"

GOVERNANCE_REPO="$REPO" KC_BASE="$KC" KC_REALM=stoa-lab ITSM_URL="$ITSM" LISTEN=":${GPORT}" \
  "$GAPI" >/tmp/trp_gapi.log 2>&1 &
SRV=$!
trap 'curl -s -X PUT "$ITSM/changes/CHG-0001/status" -H "Content-Type: application/json" -d "{\"status\":\"approved\"}" >/dev/null 2>&1; kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -f /tmp/stoa-wm-admin-token' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "$GOV/healthz" && break; sleep 0.2; done

say "0b. Identités — groupes int-team + release-team (bob membre des deux) + mappers"
ATOK=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d grant_type=password -d "username=${KC_ADMIN_USER:-admin}" -d "password=${KC_ADMIN_PASS:-admin}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
API="$KC/admin/realms/stoa-lab"; AH=(-H "Authorization: Bearer $ATOK")
ensure_group_with_bob() { # ensure_group_with_bob <name>
  local G="$1" GID BID
  GID=$(curl -s "${AH[@]}" "$API/groups?search=$G" | python3 -c "import sys,json
g=[x for x in json.load(sys.stdin) if x.get('name')=='$G'];print(g[0]['id'] if g else '')")
  if [ -z "$GID" ]; then
    curl -s "${AH[@]}" -H 'Content-Type: application/json' -X POST "$API/groups" -d "{\"name\":\"$G\"}" >/dev/null
    GID=$(curl -s "${AH[@]}" "$API/groups?search=$G" | python3 -c "import sys,json
g=[x for x in json.load(sys.stdin) if x.get('name')=='$G'];print(g[0]['id'] if g else '')")
  fi
  BID=$(curl -s "${AH[@]}" "$API/users?username=bob@bc.example&exact=true" | python3 -c 'import sys,json;u=json.load(sys.stdin);print(u[0]["id"] if u else "")')
  [ -n "$BID" ] && [ -n "$GID" ] && curl -s "${AH[@]}" -X PUT "$API/users/$BID/groups/$GID" -o /dev/null
  echo "  $G=$GID bob=$BID"
}
ensure_group_with_bob int-team
ensure_group_with_bob release-team
# Mappers stoa-portal tenant+groups : posés idempotents par demo-multienv ;
# on les (re)pose ici pareil pour que le script soit autoporteur.
PCID=$(curl -s "${AH[@]}" "$API/clients?clientId=stoa-portal" | python3 -c 'import sys,json;c=json.load(sys.stdin);print(c[0]["id"] if c else "")')
if [ -n "$PCID" ]; then
  HAVE=$(curl -s "${AH[@]}" "$API/clients/$PCID/protocol-mappers/models" | python3 -c 'import sys,json
print(" ".join(m["name"] for m in json.load(sys.stdin)))')
  echo "$HAVE" | grep -q 'demo-tenant-attr' || curl -s "${AH[@]}" -H 'Content-Type: application/json' \
    -X POST "$API/clients/$PCID/protocol-mappers/models" -d '{
      "name":"demo-tenant-attr","protocol":"openid-connect",
      "protocolMapper":"oidc-usermodel-attribute-mapper",
      "config":{"user.attribute":"tenant","claim.name":"tenant","jsonType.label":"String",
                "access.token.claim":"true","id.token.claim":"true"}}' -o /dev/null
  echo "$HAVE" | grep -q 'demo-groups' || curl -s "${AH[@]}" -H 'Content-Type: application/json' \
    -X POST "$API/clients/$PCID/protocol-mappers/models" -d '{
      "name":"demo-groups","protocol":"openid-connect",
      "protocolMapper":"oidc-group-membership-mapper",
      "config":{"claim.name":"groups","full.path":"false",
                "access.token.claim":"true","id.token.claim":"true"}}' -o /dev/null
fi

mint_user() { DEX_USER="$1@bc.example" CLIENT_ID=stoa-portal bash scripts/get-oracle-token.sh --quiet 2>/dev/null; }
TOK_ALICE="$(mint_user alice)"; TOK_BOB="$(mint_user bob)"
[ -n "$TOK_ALICE" ] && [ -n "$TOK_BOB" ] || { echo "✗ tokens alice/bob introuvables (setup-identity.sh ? Dex ?)"; exit 1; }
( umask 077; bash scripts/setup-ci-horsprod.sh --mint > /tmp/stoa-wm-admin-token ) || { echo "✗ mint ci-horsprod"; exit 1; }
CPTOKFILE="$BD/cptok"; ( umask 077; bash scripts/setup-ci-applier.sh --mint > "$CPTOKFILE" )

applyenv() { LABCTL_TOKEN_FILE="$CPTOKFILE" ITSM_URL="$ITSM" "$LABCTL" apply-uac \
  --repo "$REPO" --env "$1" --tenant "$TENANT" -f "envs/$1/targets.yaml"; }
promote() { # promote <from> <to> <extra-json-fields> — request alice + approve bob
  gov POST "/tenants/$TENANT/promotions" "$TOK_ALICE" \
    "{\"slug\":\"$SLUG\",\"from\":\"$1\",\"to\":\"$2\",\"message\":\"hop $1->$2\"$3}" >/dev/null
  PRID="$(pid < /tmp/trp.json)"
  [ -n "$PRID" ] || { bad "request $1->$2 KO (HTTP $CODE): $(cat /tmp/trp.json)"; return 1; }
  gov POST "/tenants/$TENANT/promotions/$PRID/approve" "$TOK_BOB" '{}' >/dev/null
  [ "$CODE" = 200 ] || { bad "approve $1->$2 KO (HTTP $CODE): $(cat /tmp/trp.json)"; return 1; }
}

say "① la chaîne monte jusqu'à homol — v1.0.0 (l'état N-1 de la preuve)"
promote rec int '' && ok "① rec→int demandée alice, approuvée bob (int-team, 4-yeux)"
applyenv int >/dev/null 2>&1 && ok "① int convergé (wm-admin-int)" || bad "① apply int KO"
promote int homol ',"pv_ref":"PV-2026-101"' && ok "① int→homol (pv_ref exigé à la demande) approuvée bob (release-team)"
applyenv homol >/dev/null 2>&1 && ok "① homol convergé v1.0.0 (wm-admin-homol)" || bad "① apply homol KO"
DEPLOY_PATH="tenants/$TENANT/apis/$SLUG/deploy.homol.yaml"
N1RAW="$(git -C "$REPO" show "main:$DEPLOY_PATH")"
N1SHA="$(git -C "$REPO" log -1 --format=%H -- "$DEPLOY_PATH")"
echo "$N1RAW" | grep -q 'commit:' && ok "① l'état N-1 porte son pin (commit: présent)" || bad "① deploy.homol.yaml N-1 sans pin"

say "② v1.0.1 atteint homol (l'état N que le repli va quitter)"
python3 - "$REPO/tenants/$TENANT/apis/$SLUG/api.yaml" <<'EOF'
import sys,re
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(re.sub(r'version:\s*1\.0\.0','version: 1.0.1',s,count=1))
EOF
printf 'version: 1.0.1\nenabled: true\npromoted_by: alice\n' > "$REPO/tenants/$TENANT/apis/$SLUG/deploy.int.yaml"
git -C "$REPO" -c user.name="Alice Banking" -c user.email=alice@bank.example \
  commit -qam "feat(banking): accounts-read v1.0.1 jusqu'en int (chaîne rejouée)"
promote int homol ',"pv_ref":"PV-2026-102"' && ok "② v1.0.1 promue en homol (2e état de deploy.homol.yaml)"
V2ID="$PRID"
applyenv homol >/tmp/trp-apply-v101.log 2>&1 && ok "② v1.0.1 appliquée en homol" \
  || { bad "② apply v1.0.1 KO"; tail -5 /tmp/trp-apply-v101.log | sed 's/^/    /'; }

say "③ PORTE G6 — rollback homol : SHA N-1, verbatim, trace Git, smoke"
# homol n'exige AUCUNE ref au rollback (pv-only ; D3 adr-085) — reason suffit.
gov POST "/tenants/$TENANT/promotions/$V2ID/rollback" "$TOK_BOB" \
  '{"reason":"KO recette homol v1.0.1"}' >/dev/null
if [ "$CODE" = 200 ]; then
  ok "③ rollback homol accepté (200, reason seule — pv_ref non exigé au repli)"
  RESTCOMMIT="$(jget restored commit)"; RESTVER="$(jget restored version)"; RESTENV="$(jget restored environment)"
  [ "$RESTENV" = homol ] && [ "$RESTVER" = "1.0.0" ] && ok "③ restored = homol@1.0.0" \
    || bad "③ restored inattendu: env=$RESTENV ver=$RESTVER"
  NOWRAW="$(git -C "$REPO" show "main:$DEPLOY_PATH")"
  [ "$NOWRAW" = "$N1RAW" ] && ok "③ deploy.homol.yaml == contenu au SHA N-1 ($(printf %.7s "$N1SHA")) VERBATIM, pin compris" \
    || bad "③ contenu restauré ≠ N-1"
  PINN1="$(printf '%s\n' "$N1RAW" | sed -n 's/^commit: *//p')"
  [ -n "$PINN1" ] && [ "$RESTCOMMIT" = "$PINN1" ] && ok "③ le pin restauré est CELUI du N-1 ($PINN1)" \
    || bad "③ pin restauré ($RESTCOMMIT) ≠ pin N-1 ($PINN1)"
  MSG="$(git -C "$REPO" log -1 --format=%B)"
  echo "$MSG" | grep -q "rollback $SLUG (homol)" && echo "$MSG" | grep -q "Evidence:" \
    && ok "③ trace Git de l'acte : commit 'rollback $SLUG (homol)' + trailer Evidence" \
    || bad "③ commit de rollback sans sujet/trailers attendus: $MSG"
  EVP="$(jget evidence)"
  git -C "$REPO" show "main:$EVP" >/dev/null 2>&1 && ok "③ evidence pack commité ($EVP)" || bad "③ evidence absent ($EVP)"
  gov GET "/tenants/$TENANT/promotions/$V2ID" "$TOK_BOB" >/dev/null
  [ "$(jget promotion status)" = rolled_back ] && ok "③ promotion marquée rolled_back" || bad "③ statut: $(jget promotion status)"
else bad "③ rollback homol KO (HTTP $CODE): $(cat /tmp/trp.json)"; fi
applyenv homol >/dev/null 2>&1 && ok "③ homol re-convergé sur l'état Git reverté" || bad "③ re-apply homol KO"
"$LABCTL" get apis -f envs/homol/targets.yaml -o json > /tmp/trp-catalog.json 2>/dev/null
python3 - /tmp/trp-catalog.json <<'PY' && ok "③ SMOKE : catalogue homol (via wm-admin-homol) porte accounts-read@1.0.0" || bad "③ SMOKE KO : accounts-read@1.0.0 absent du catalogue homol"
import json, sys
d = json.load(open(sys.argv[1]))
apis = [a for t in d.get("targets", []) for a in (t.get("apis") or [])]
sys.exit(0 if any(a.get("name") == "accounts-read" and a.get("version") == "1.0.0" for a in apis) else 1)
PY

say "④ CONTRE-ÉPREUVES — les refus, par leur nom"
# a. double rollback => 409 NOT_APPROVED (rolled_back n'est plus annulable)
gov POST "/tenants/$TENANT/promotions/$V2ID/rollback" "$TOK_BOB" '{"reason":"encore"}' >/dev/null
[ "$CODE" = 409 ] && ok "④a double rollback → 409 $(jget error code)" || bad "④a double rollback → HTTP $CODE (attendu 409)"
# b. LA contre-épreuve du GOAL : palier à change_ref (prod) — sans lui, refus nommé.
curl -s -X PUT "$ITSM/changes/CHG-0001/status" -H 'Content-Type: application/json' -d '{"status":"approved"}' >/dev/null
promote homol prod ',"change_ref":"CHG-0001","pv_ref":"PV-2026-103"' && ok "④b homol→prod approuvée (régime complet : change+PV+ITSM+4-yeux)"
PRODID="$PRID"
gov POST "/tenants/$TENANT/promotions/$PRODID/rollback" "$TOK_BOB" '{"reason":"test refus"}' >/dev/null
B="$(cat /tmp/trp.json)"
if [ "$CODE" = 400 ] && echo "$B" | grep -q GATE_REFS_REQUIRED; then
  ok "④b rollback prod SANS change_ref → 400 GATE_REFS_REQUIRED (contre-épreuve GOAL)"
else bad "④b rollback sans change_ref → HTTP $CODE (attendu 400 GATE_REFS_REQUIRED): $B"; fi
# c. …et la garde des refs est bien ANTÉRIEURE à l'historique : avec le
# change_ref, le MÊME rollback tombe sur 409 NO_PREVIOUS_STATE (1er état prod).
gov POST "/tenants/$TENANT/promotions/$PRODID/rollback" "$TOK_BOB" \
  '{"reason":"test premier état","change_ref":"CHG-0003"}' >/dev/null
B="$(cat /tmp/trp.json)"
if [ "$CODE" = 409 ] && echo "$B" | grep -q NO_PREVIOUS_STATE; then
  ok "④c avec change_ref → 409 NO_PREVIOUS_STATE (fail at the earliest prouvé : refs AVANT historique)"
else bad "④c rollback 1er état → HTTP $CODE (attendu 409 NO_PREVIOUS_STATE): $B"; fi

say "⑤ Remise à l'identique du lab (mocks int+homol touchés → restart, catalogues re-vérifiés)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^poc-wm-mock-homol$'; then
  docker restart poc-wm-mock-int poc-wm-mock-homol >/dev/null 2>&1
  sleep 2
  for E in int homol; do
    "$LABCTL" get apis -f "envs/$E/targets.yaml" -o json > /tmp/trp-clean.json 2>/dev/null
    N=$(python3 -c 'import json,sys;d=json.load(open("/tmp/trp-clean.json"));print(sum(len(t.get("apis") or []) for t in d.get("targets",[])))' 2>/dev/null || echo '?')
    [ "$N" = 0 ] && ok "⑤ catalogue $E remis à n=0" || bad "⑤ catalogue $E: n=$N (attendu 0)"
  done
else echo "  (mocks absents — remise à l'identique SKIP)"; fi

say "RÉCAP"
echo "  $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ] && echo "✓ G6 : le repli est un composant du déploiement — homol rollbacké au SHA N-1, tracé, smoké ; les refus portent leur nom." \
  || { echo "✗ preuve incomplète — voir les FAIL."; exit 1; }
```

Note d'exécutant : `gov GET .../promotions/$V2ID` — vérifier que la route GET par id existe (`handlers_promotions.go` / `server.go`) ; si la relecture unitaire n'existe pas, lister (`GET /promotions`) et filtrer par id en python. Ne pas inventer une route.

- [ ] **Step 2: Rendre exécutable, shellcheck**

Run: `chmod +x scripts/test-rollback-paliers.sh && shellcheck -x scripts/test-rollback-paliers.sh || true` — corriger ce qui est réel (le lint-ci passe shellcheck sur scripts/).

- [ ] **Step 3: Exécuter contre le lab**

Run: `bash scripts/test-rollback-paliers.sh`
Attendu : 0 FAIL. Si un prereq manque (proxy homol, scope deploy:homol, identités), le script échoue PROPREMENT au préambule — réparer le lab (scripts setup-* nommés dans le header), pas le test. Piège connu : keepalive wM (`restart-wm.sh`, fenêtre ~20 min) — lancer juste après un cycle (`docker inspect poc-webmethods-real` → StartedAt récent).

- [ ] **Step 4: Rejouer (idempotence de la preuve)**

Run: `bash scripts/test-rollback-paliers.sh`
Attendu : même verdict à froid (le repo scratch est neuf à chaque run ; le lab a été remis à l'identique par ⑤).

- [ ] **Step 5: Commit**

```bash
git add scripts/test-rollback-paliers.sh
git commit -m "test(g6): porte live — rollback homol au SHA N-1 (verbatim+pin), smoke catalogue, refus GATE_REFS_REQUIRED/NO_PREVIOUS_STATE nommés"
```

---

### Task 4: E2E par builds Jenkins (conditionné aux gestes exploitant)

**Files:**
- Aucun nouveau fichier ; builds sur le lab + rapport dans le ledger.

**Interfaces:**
- Consomme : le job Jenkins `rollback` (Pipeline-from-SCM, runbook `ci/README.md` §119), gitea `ci/stoa-labs` main (doit porter G2+G6), le dépôt governance du lab (chaîne 5 paliers seedée — `seed-governance-chain.sh`), governance-api hôte :8787, `setup-vault-paliers.sh --grant-ci` (G2, geste 2).

- [ ] **Step 1: Préflights, dans l'ordre** — chaque échec = STOP et report du geste dans le handoff, pas de contournement silencieux :
  1. `git fetch gitea && git log --oneline gitea/main -1` — gitea doit porter G6 (sinon : geste exploitant `git push gitea provision/probe-dev:main`, `http.postBuffer` relevé si >1 Mo).
  2. Chaîne governance du lab : cloner `http://localhost:3000/ci/governance.git` (ou via docker exec) et vérifier `environments.yaml` = 5 paliers avec gates G1 (sinon : `GITEA_TOKEN=… bash scripts/seed-governance-chain.sh`, geste G1 resté pendant).
  3. `bash scripts/setup-vault-paliers.sh --grant-ci` joué (sinon le re-apply machine homol refuse `DEPLOYER_GROUP_REQUIRED` — c'est un refus G2 CORRECT, pas un bug G6).
  4. Groupe KC `release-team` + membres (`bash scripts/setup-release-team.sh`, geste G1).
- [ ] **Step 2: Matérialiser deux états homol sur le VRAI dépôt governance** via governance-api :8787 (mêmes appels que le script T3, tokens alice/bob réels), puis vérifier `git log -- …/deploy.homol.yaml` ≥ 2.
- [ ] **Step 3: Build PORTE** : job rollback, `PROMOTION_ID` = la 2e promotion homol, `REASON` renseignée, `CHANGE_REF` vide (homol ne l'exige pas), `VAULT_USER` vide (voie machine grant-ci). Attendu : SUCCESS — stages `Palier du rollback` (homol, terminus: no), `Re-apply + smoke palier intermédiaire` vert, catalogue homol à la version N-1.
- [ ] **Step 4: Build CONTRE-ÉPREUVE** : même job, `PROMOTION_ID` d'une promotion PROD approuvée (il y en a au moins une dans l'historique du lab ; sinon la créer comme au Step 2), `CHANGE_REF` VIDE. Attendu : FAILURE au stage `Rollback governance` avec `GATE_REFS_REQUIRED` dans `/tmp/rollback-resp.json` affiché au log — le refus vient de l'API, pas d'une validation de formulaire.
- [ ] **Step 5: Consigner les numéros de builds + verdicts dans le ledger** (`.superpowers/sdd/2026-08-27-g6-rollback-des-paliers/progress.md`). Si les préflights ont bloqué : consigner CE QUI a bloqué et le geste exact, la porte reste tenue par T3 (précédent G2, dit tel quel dans le handoff).

---

### Task 5: Documentation — ADR-085, parcours opérateur, gabarit, GOAL

**Files:**
- Create: `adr/adr-085-rollback-des-paliers.md`
- Modify: `clients/_example/environments.yaml` (bloc de commentaires : ce que chaque gate exige AU ROLLBACK)
- Modify: `ENVIRONNEMENTS.md` (nouvelle section « Revenir en arrière (G6) »)
- Modify: `ci/README.md:14` (ligne Rollback du tableau)
- Modify: `envs/homol/targets.yaml` + `envs/homol/targets.cluster.yaml` (en-têtes « plomberie non posée » périmés depuis G5)
- Modify: `GOAL-cd-promotion-5-envs-2026-08-26.md` (§G6 : fait, chiffres)

- [ ] **Step 1: ADR-085** — structure des ADR récents (contexte/décision/conséquences), contenu = les décisions D1-D7 de la spec, MOT POUR MOT sur : la qualification 17(1)(e) (identifier ≠ tester — on teste depuis (c)/DORA niveau 1) ; pourquoi pv_ref n'est pas exigé au repli ; le verbe apply-uac conservé (tension ADR-083 parquée → G8) ; « le rollback restaure l'état désiré, il ne supprime pas la version N de la gateway (aucun DELETE, ADR-075) » ; le re-apply du rollback passe par LE MÊME preflight déployeur que l'aller (G2, ADR-084).
- [ ] **Step 2: gabarit `environments.yaml`** — dans le bloc « Champs disponibles », ajouter un paragraphe : « AU ROLLBACK (adr-085) : requireChangeRef et itsmCheck exigent le change_ref du rollback lui-même ; requirePVRef n'exige RIEN au rollback (l'état restauré a porté son PV à sa promotion) ; le reste des gates ne s'applique pas (pas d'approbation — on revient à un état déjà approuvé). »
- [ ] **Step 3: ENVIRONNEMENTS.md** § « Revenir en arrière (G6) » : le parcours opérateur du job rollback (PROMOTION_ID+REASON, CHANGE_REF si le palier l'exige, VAULT_USER pour l'acte imputable), ce que fait chaque stage, et la phrase « le palier n'est jamais saisi : c'est celui de la promotion ».
- [ ] **Step 4: `ci/README.md`** ligne 14 : remplacer « re-apply prod idempotent + smoke » par « re-apply idempotent du palier de la promotion (terminus en direct, paliers intermédiaires via wm-admin-<env>) + smoke d'état N-1 ».
- [ ] **Step 5: en-têtes envs/homol** : remplacer le ⚠ « PLOMBERIE DE LAB NON POSÉE à la création (2026-08-26) » par « Plomberie posée depuis G5 (2026-08-27) : proxy wm-admin-homol (matrice 20/0), scope deploy:homol dérivé de la chaîne, secret envs/homol/wm-admin. » (les DEUX fichiers).
- [ ] **Step 6: GOAL §G6** : marquer fait, avec les chiffres des portes (offline X tests, live X/X, builds si joués).
- [ ] **Step 7: `make lint-ci`** une dernière fois (8/8), puis commit :

```bash
git add adr/adr-085-rollback-des-paliers.md clients/_example/environments.yaml ENVIRONNEMENTS.md ci/README.md envs/homol/targets.yaml envs/homol/targets.cluster.yaml GOAL-cd-promotion-5-envs-2026-08-26.md
git commit -m "docs(g6): ADR-085 + parcours opérateur + gabarit — le repli est un composant du déploiement, identifié ET exercé"
```

---

## Self-review (fait à l'écriture)

- **Couverture spec** : D1/D2/D5 → Task 2 ; D3 → Task 1 (+gabarit Task 5) ; D4 → aucun code (décision de NE PAS faire, ADR) ; D6 → Tasks 1/3/4 ; D7 → ADR ; §3 livrables tous adressés ; porte GOAL → T3 ③ + T4 Step 3 ; contre-épreuve GOAL → T1 test 1-2 + T3 ④b + T4 Step 4.
- **Types/nommage inter-tâches** : fichiers de workspace (`rollback-env.txt` etc.) nommés identiquement aux Steps 2/3/4/5/6 de Task 2 ; codes d'erreur (`GATE_REFS_REQUIRED`, `NO_PREVIOUS_STATE`, `NOT_APPROVED`) = ceux du handler lu ; champs JSON (`restored.environment/version/commit`, `promotion.slug/status`, `targets[].apis[].name/version`) = ceux lus dans le code.
- **Piège assumé** : la route `GET /promotions/{id}` est à VÉRIFIER en T3 (note d'exécutant) ; le smoke homol tolère la présence résiduelle de v1.0.1 au catalogue (aucun DELETE — assertion = présence du N-1, documentée ADR).
