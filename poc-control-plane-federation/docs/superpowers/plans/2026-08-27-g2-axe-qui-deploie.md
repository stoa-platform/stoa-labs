# G2 — L'axe « qui déploie » (deployerGroup) — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** ajouter l'axe `deployerGroup` au modèle `Gate` et le faire refuser PAR NOM,
mécaniquement avant le verbe, sur les deux chemins de dispatch (team-promote.sh et
`labctl apply-uac`), avec le gabarit, les annuaires du lab, et les portes de preuve.

**Architecture :** `deployerGroup` = annuaire n°2 (LDAP→Vault) ; enforcement = la
policy projetée (table 2 familles, fail-closed) présente dans le lookup-self du token
Vault du porteur. governance-api parse/sert/matérialise le champ mais ne l'évalue pas
à l'approve. Voir la spec — le plan argue depuis elle.

**Tech stack :** Go (labctl, air-gapped `GOPROXY=off GOFLAGS=-mod=vendor`), bash 3.2
(macOS), python3 inline, Vault KV v2/LDAP, harnais maison (`make lint-ci`).

**Spec :** `docs/superpowers/specs/2026-08-27-g2-axe-qui-deploie-design.md`

## Global Constraints

- Go se lance TOUJOURS `cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go test -count=1 …`
  (le cache ne piste pas les YAML hors module — `-count=1` obligatoire).
- bash 3.2 : pas de `mapfile`, pas de `declare -A` ; harnais en `set -uo pipefail`
  (JAMAIS `-e` dans les tests) ; capture fichier puis grep — jamais `cmd | grep && ok || bad`.
- Aucune apostrophe française dans `${VAR:?msg}` (EOF signalé à la dernière ligne).
- Secrets : jamais en argv/URL ; token Vault via header-FILE (`-H @fichier`).
- Codes de refus UPPER_SNAKE, format `fail "CODE : détail"` ; les trois codes G2 sont
  IDENTIQUES dans les deux moteurs : `DEPLOYER_GROUP_REQUIRED`,
  `DEPLOYER_GROUP_UNSUPPORTED`, `DEPLOYER_GROUP_UNVERIFIABLE`.
- Toute garde nouvelle = une MUTATION qui la retire et exige le rouge (jamais un grep
  satisfait par un commentaire — greps ancrés sur code décommenté).
- Chaque tâche committe (`type(g2): …`) ; ne JAMAIS committer un harnais rouge.
- Les compteurs de harnais (`EXPECTED_ASSERTIONS`) sont RE-MESURÉS par un run, jamais déduits.

---

### Task 1 : le modèle — `DeployerGroup` + `DeployerPolicy()` (Go)

**Files:**
- Modify: `labctl/internal/governance/envchain.go`
- Test: `labctl/internal/governance/envchain_test.go`

**Interfaces:**
- Produces: `Gate.DeployerGroup string` (clé YAML `deployerGroup`) ;
  `func (g Gate) DeployerPolicy() (string, error)` — `("", nil)` si champ vide ;
  `("apply-<x>", nil)` pour `apim-apply-<x>` ; `("operator-deploy", nil)` pour
  `apim-operator-<x>` ; `("", error)` sinon. Consommée par Task 5 (labctl) et
  épinglée par Task 2 (shipped test) et Task 6 (miroir shell).

- [ ] **Step 1 : test rouge.** Dans `envchain_test.go`, ajouter :

```go
func TestParseEnvChainDeployerGroup(t *testing.T) {
	c, err := ParseEnvChain([]byte(
		"environments: [dev, rec]\ngates:\n  - to: rec\n    deployerGroup: apim-apply-rec\n"))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got := c.Gates["rec"].DeployerGroup; got != "apim-apply-rec" {
		t.Fatalf("DeployerGroup = %q, want apim-apply-rec", got)
	}
}

// La table de projection est FAIL-CLOSED hors des deux familles : un nom
// invérifiable doit refuser BRUYAMMENT (contrairement à approverGroup, dont le
// mauvais nom ne matche jamais en silence).
func TestGateDeployerPolicy(t *testing.T) {
	cases := []struct {
		group, want string
		wantErr     bool
	}{
		{"", "", false},                                // pas de déclaration => pas de check
		{"apim-apply-int", "apply-int", false},         // famille paliers (setup-vault-paliers.sh)
		{"apim-apply-homol", "apply-homol", false},
		{"apim-operator-prod", "operator-deploy", false}, // famille terminus (setup-vault-ldap.sh:156)
		{"apim-operator-dr", "operator-deploy", false},
		{"int-team", "", true},          // annuaire KC : PAS un groupe déployeur
		{"apim-apply-", "", true},       // suffixe vide = invérifiable
		{"apim-operator-", "", true},
		{"release-team", "", true},
	}
	for _, tc := range cases {
		got, err := (Gate{DeployerGroup: tc.group}).DeployerPolicy()
		if (err != nil) != tc.wantErr || got != tc.want {
			t.Errorf("DeployerPolicy(%q) = (%q, %v), want (%q, err=%v)", tc.group, got, err, tc.want, tc.wantErr)
		}
	}
}
```

- [ ] **Step 2 : vérifier le rouge** — `cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go test -count=1 ./internal/governance/ -run 'DeployerGroup|DeployerPolicy'` ⇒ FAIL (champ/méthode inconnus).
- [ ] **Step 3 : implémentation.** Dans `envchain.go`, après `ITSMCheck` dans la struct :

```go
	// DeployerGroup, when set, names WHO may CARRY the apply toward this
	// environment — the OTHER directory (LDAP group → Vault policy), never the
	// KC `groups` claim: at dispatch time the only verified identity available
	// on every chain is the Vault token (ADR-084). Enforced at the two dispatch
	// sites (team-promote.sh §7.a, apply-uac preflight), NEVER at approve.
	DeployerGroup string `json:"deployerGroup"`
```

puis, après `ParseEnvChain` :

```go
// DeployerPolicy projects a deployerGroup name onto the Vault policy the
// carrier's token must hold. TWO verifiable families, fail-closed beyond them
// (a name outside the table is a declaration nothing can check — refuse LOUDLY,
// unlike approverGroup whose wrong name silently never matches):
//   apim-apply-<x>    → policy "apply-<x>"     (setup-vault-paliers.sh, per-palier)
//   apim-operator-<x> → policy "operator-deploy" (setup-vault-ldap.sh, terminus)
// The shell mirror is deployer_group_policy() in scripts/lib/env-chain.sh —
// same table, same refusals; any divergence is a bug (ADR-083 regime).
func (g Gate) DeployerPolicy() (string, error) {
	dg := g.DeployerGroup
	switch {
	case dg == "":
		return "", nil
	case strings.HasPrefix(dg, "apim-apply-") && dg != "apim-apply-":
		return "apply-" + strings.TrimPrefix(dg, "apim-apply-"), nil
	case strings.HasPrefix(dg, "apim-operator-") && dg != "apim-operator-":
		return "operator-deploy", nil
	default:
		return "", fmt.Errorf("deployerGroup %q: outside the two verifiable families (apim-apply-<x> | apim-operator-<x>)", dg)
	}
}
```

- [ ] **Step 4 : vert** — même commande ⇒ PASS ; puis `go test -count=1 ./internal/governance/` entier (le shipped test NE doit PAS bouger encore : le gabarit n'a pas changé, un champ zéro ne fait pas diverger les want).
- [ ] **Step 5 : commit** — `feat(g2): le Gate porte deployerGroup et sa projection fail-closed`

---

### Task 2 : le gabarit déclare l'axe — shipped test + sabotage n°2

**Files:**
- Modify: `clients/_example/environments.yaml`
- Modify: `labctl/internal/governance/envchain_shipped_test.go`
- Modify: `scripts/test-env-chain.sh`

**Interfaces:**
- Consumes: `Gate.DeployerGroup`, `DeployerPolicy()` (Task 1).
- Produces: le gabarit avec `deployerGroup: apim-apply-int` (int),
  `apim-apply-homol` (homol), `apim-operator-prod` (prod) — Tasks 6/7/8/9 s'y réfèrent.

- [ ] **Step 1 : le YAML.** Dans `clients/_example/environments.yaml` :
  1. Dans la liste « Champs disponibles » (après `selfApproval`), ajouter :

```yaml
#   deployerGroup     — QUI PORTE l'apply vers ce palier (G2, ADR-084). Nom d'un
#                       groupe de l'ANNUAIRE N°2 (LDAP → policy Vault), vérifié au
#                       DISPATCH par la policy projetée du token Vault du porteur —
#                       jamais à l'approbation. Deux familles vérifiables :
#                       apim-apply-<x> → apply-<x> ; apim-operator-<x> →
#                       operator-deploy. Hors famille ⇒ refus BRUYANT
#                       (DEPLOYER_GROUP_UNSUPPORTED), jamais un silence.
#                       Absent ⇒ pas de déclaration : la rétention de credential
#                       (ADR-082, PALIER_FERME) reste le seul « qui ».
```

  2. Porte int : ajouter `deployerGroup: apim-apply-int` + commentaire :

```yaml
  # `deployerGroup` (G2) : QUI PORTE l'apply vers int — l'axe GitLab
  # deploy_access_levels, indépendant de l'approbation. bob approuve (int-team,
  # claim KC) ET déploie (apim-apply-int, LDAP→Vault) dans le lab ; deux
  # personnes distinctes chez un client, sans rien changer ici.
```

  3. Porte homol : `deployerGroup: apim-apply-homol`.
  4. Porte prod : `deployerGroup: apim-operator-prod` + commentaire nommant la
     conséquence (spec D5) :

```yaml
  # ⚠ CONSÉQUENCE ASSUMÉE : avec cette déclaration, le repli AppRole de
  # Jenkinsfile.prod (« acte non imputable ») est REFUSÉ fail-closed
  # (DEPLOYER_GROUP_REQUIRED — son token ne porte pas operator-deploy).
  # Déployer prod exige un humain du groupe, ou un grant EXPLICITE de la
  # policy à un AppRole dédié (geste exploitant, jamais un défaut).
```

  5. Réécrire le bloc « ⚠ DEUX CONVENTIONS DE GROUPES COEXISTENT » en « ⚠ TROIS
     AXES, DEUX ANNUAIRES — CHAQUE CHAMP EST ÉPINGLÉ AU SIEN » : `approverGroup` =
     claim `groups` KC (`<env>-team`) ; `deployerGroup` = LDAP→Vault (les deux
     familles) ; `apim-operator-<env>` cité comme la famille terminus DÉSORMAIS
     déclarable via `deployerGroup`. Garder l'avertissement : un nom KC dans
     `deployerGroup` refuse BRUYAMMENT (amélioration sur le piège silencieux
     d'`approverGroup`, qu'on garde tel quel).

- [ ] **Step 2 : shipped test.** Dans `envchain_shipped_test.go` : les `want` des
  paliers int/homol/prod gagnent le champ :

```go
{"int", Gate{To: "int", ApproverGroup: "int-team", FourEyes: true, DeployerGroup: "apim-apply-int"}},
{"homol", Gate{To: "homol", ApproverGroup: "release-team", FourEyes: true, RequirePVRef: true, DeployerGroup: "apim-apply-homol"}},
{"prod", Gate{To: "prod", ApproverGroup: "release-team", FourEyes: true, RequireChangeRef: true, RequirePVRef: true, ITSMCheck: true, DeployerGroup: "apim-operator-prod"}},
```

  et une propriété nouvelle (même style que l'anti-palier-sans-porte) :

```go
// Every declared deployerGroup must be PROJECTABLE: a group outside the two
// verifiable families would ship a gate nothing can check (fail-closed by
// construction — but we refuse to ship it at all).
for env, g := range c.Gates {
	if _, err := g.DeployerPolicy(); err != nil {
		t.Errorf("%s: %v", env, err)
	}
}
```

- [ ] **Step 3 : vert Go** — `go test -count=1 ./internal/governance/ -run TestShippedExampleChain` ⇒ PASS.
- [ ] **Step 4 : sabotage n°2 dans `scripts/test-env-chain.sh`** (même mécanique que
  le n°1 : sauvegarde déjà en place, trap inconditionnel déjà en place — ajouter le
  sabotage AVANT la restauration finale) :

```bash
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
```

  ⚠ ajuster le compteur final du script s'il en a un, et vérifier que le sed mute
  RÉELLEMENT (le motif doit matcher l'indentation EXACTE du YAML écrit au Step 1).
- [ ] **Step 5 : run** — `bash scripts/test-env-chain.sh` ⇒ tout PASS (l'ancien 4/4 devient 6/6 ou +).
- [ ] **Step 6 : commit** — `feat(g2): le gabarit déclare qui déploie — int/homol/prod épinglés, sabotage n°2`

---

### Task 3 : governance-api — l'évidence porte l'axe ; le 4-yeux et le groupe prouvés PAR PALIER

**Files:**
- Modify: `labctl/cmd/governance-api/handlers_promotions.go` (bloc `gateCheck`, ~l.305-313)
- Test: le fichier de tests des handlers promotions existant (le repérer :
  `grep -rln "SELF_APPROVAL_BLOCKED" labctl/cmd/governance-api/*_test.go`)

**Interfaces:**
- Consumes: `Gate.DeployerGroup` (Task 1) ; le gabarit 5 paliers (Task 2).
- Produces: l'évidence d'approbation gagne `"deployer_group": gate.DeployerGroup`
  dans `gateCheck`. AUCUN nouveau refus à l'approve (spec D4 — déployer est un acte
  de dispatch ; l'écrire en commentaire au-dessus du bloc).

- [ ] **Step 1 : évidence.** Dans `handlers_promotions.go`, le `gateCheck` gagne la clé :

```go
gateCheck := map[string]any{
	"hop": promo.From + "→" + promo.To, "four_eyes": gate.FourEyes,
	"approver_group": gate.ApproverGroup, "pv_ref": promo.PVRef,
	// deployer_group is MATERIALIZED here, never EVALUATED here: carrying the
	// deploy is a dispatch-time act (ADR-084) — the refusal lives at the two
	// dispatch sites, where the carrier's Vault token exists.
	"deployer_group": gate.DeployerGroup,
}
```

- [ ] **Step 2 : preuves par palier (contre-épreuve du GOAL « rejoué sur les trois
  nouveaux paliers »).** Étudier le harnais de test existant des handlers (fake
  Repo/Store, mint de jetons). Ajouter des cas TABLE sur une chaîne = COPIE
  CONFORME du gabarit livré (la lire depuis `../../../clients/_example/environments.yaml`
  comme envchain_shipped_test.go, OU l'inline en la faisant vérifier égale au
  fichier — suivre le motif du harnais existant) :
  1. approve int par le demandeur lui-même (groupes=[int-team]) ⇒ 403 `SELF_APPROVAL_BLOCKED` ;
  2. approve homol par le demandeur (groupes=[release-team]) ⇒ 403 `SELF_APPROVAL_BLOCKED` ;
  3. approve int par un tiers SANS int-team ⇒ 403 `GATE_GROUP_REQUIRED` ;
  4. approve homol par un tiers sans release-team ⇒ 403 `GATE_GROUP_REQUIRED` ;
  5. approve prod par un tiers sans release-team ⇒ 403 `GATE_GROUP_REQUIRED` ;
  6. VARIANTE rec+fourEyes (chaîne de fixture où rec porte `fourEyes: true`) :
     approve rec par le demandeur ⇒ 403 `SELF_APPROVAL_BLOCKED` — la décision
     client n°1 est bien « une ligne qui MORD » ;
  7. l'évidence d'un approve réussi sur int porte `gate.deployer_group == "apim-apply-int"`.
- [ ] **Step 3 : vert** — `go test -count=1 ./cmd/governance-api/` ⇒ PASS (et la
  suite entière `go test -count=1 ./...` du module).
- [ ] **Step 4 : commit** — `feat(g2): l'évidence d'approbation nomme le déployeur ; 4-yeux et groupe prouvés par palier`

---

### Task 4 : `internal/vault` — `TokenPolicies` (lookup-self)

**Files:**
- Modify: `labctl/internal/vault/vault.go`
- Test: `labctl/internal/vault/vault_test.go`

**Interfaces:**
- Produces: `func (c *Client) TokenPolicies(ctx context.Context) ([]string, error)` —
  union `data.policies` + `data.identity_policies` de `GET /v1/auth/token/lookup-self` ;
  TOUTE erreur (transport, 403, corps vide) EST une erreur (fail-closed — le
  contraire de ReadKV qui tolère le 404). Consommée par Task 5.

- [ ] **Step 1 : tests rouges** (motif httptest de `TestReadKV`) :

```go
func TestTokenPolicies(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/auth/token/lookup-self" || r.Header.Get("X-Vault-Token") != "tok" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		fmt.Fprint(w, `{"data":{"policies":["default","apply-int"],"identity_policies":["ldap-derived"]}}`)
	}))
	defer srv.Close()
	c := &Client{addr: srv.URL, token: "tok", hc: srv.Client()}
	got, err := c.TokenPolicies(context.Background())
	if err != nil {
		t.Fatalf("TokenPolicies: %v", err)
	}
	want := []string{"default", "apply-int", "ldap-derived"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("policies = %v, want %v", got, want)
	}
}

// Fail-closed : un lookup refusé n'est jamais « pas de policies », c'est une erreur.
func TestTokenPoliciesAuthFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()
	c := &Client{addr: srv.URL, token: "bad", hc: srv.Client()}
	if _, err := c.TokenPolicies(context.Background()); err == nil {
		t.Fatal("expected error on 403 lookup-self, got nil (fail-open)")
	}
}
```

  (adapter la construction du Client au motif exact des tests existants — ils
  passent par `FromEnv` + `t.Setenv` ; suivre le fichier.)
- [ ] **Step 2 : rouge** — `go test -count=1 ./internal/vault/ -run TokenPolicies` ⇒ FAIL.
- [ ] **Step 3 : implémentation** dans `vault.go` :

```go
// TokenPolicies returns the policies attached to the CALLER's own token
// (GET /v1/auth/token/lookup-self): direct token_policies plus identity-derived
// policies. Fail-closed on ANY failure — a dispatch gate consumes this to decide
// WHO may carry an apply (ADR-084), and an unverifiable identity must refuse,
// never pass. (Contrast ReadKV, where a 404 falls back by design.)
func (c *Client) TokenPolicies(ctx context.Context) ([]string, error) {
	tok, err := c.ensureToken(ctx)
	if err != nil {
		return nil, err
	}
	var out struct {
		Data struct {
			Policies         []string `json:"policies"`
			IdentityPolicies []string `json:"identity_policies"`
		} `json:"data"`
	}
	url := c.addr + "/v1/auth/token/lookup-self"
	headers := map[string]string{"X-Vault-Token": tok}
	if _, err := httpx.JSON(ctx, c.hc, http.MethodGet, url, headers, nil, &out); err != nil {
		return nil, fmt.Errorf("vault lookup-self: %w", err)
	}
	return append(append([]string(nil), out.Data.Policies...), out.Data.IdentityPolicies...), nil
}
```

- [ ] **Step 4 : vert** — `go test -count=1 ./internal/vault/` ⇒ PASS.
- [ ] **Step 5 : commit** — `feat(g2): lookup-self — le token dit ses policies, fail-closed`

---

### Task 5 : labctl — le preflight déployeur, avant toute écriture

**Files:**
- Modify: `labctl/cmd/labctl/dispatchgate.go` (codes + raisons + nouvelle fonction)
- Modify: `labctl/cmd/labctl/applyuac.go` (site d'appel, juste après `preflightDispatchGate`, ~l.166-173)
- Test: `labctl/cmd/labctl/dispatchgate_test.go` (ou le fichier de tests existant du paquet — le repérer)

**Interfaces:**
- Consumes: `Gate.DeployerPolicy()` (Task 1), `vault.FromEnv`/`TokenPolicies` (Task 4),
  la dérivation gated+enabled de `preflightDispatchGate` (motif existant, à REPRODUIRE
  à l'identique : scope, `uacSkipReason`, `EnvAny`).
- Produces: `func preflightDeployerGate(ctx context.Context, gchain governance.EnvChain, apis []uac.API, scope, env string) error`
  avec `dispatchGateError.Code` ∈ {`DEPLOYER_GROUP_REQUIRED`, `DEPLOYER_GROUP_UNSUPPORTED`,
  `DEPLOYER_GROUP_UNVERIFIABLE`} ; raisons d'audit `deployer_group_required_at_dispatch`,
  `deployer_group_unsupported`, `deployer_group_unverifiable`.

- [ ] **Step 1 : tests rouges.** Table-driven, httptest Vault (motif Task 4),
  chaîne de fixture 3 paliers avec `deployerGroup: apim-apply-beta` sur beta,
  une API enabled sur beta :
  1. token dont lookup-self rend `["default","apply-beta"]` ⇒ nil ;
  2. token `["default"]` ⇒ erreur code `DEPLOYER_GROUP_REQUIRED` ;
  3. lookup-self 403 ⇒ `DEPLOYER_GROUP_UNVERIFIABLE` ;
  4. `VAULT_ADDR` vide (t.Setenv) ⇒ `DEPLOYER_GROUP_UNVERIFIABLE` (« porte déclarée,
     identité invérifiable — fail-closed ») ;
  5. gate `deployerGroup: int-team` ⇒ `DEPLOYER_GROUP_UNSUPPORTED` ;
  6. gate SANS deployerGroup ⇒ nil ET AUCUN appel lookup (compteur de requêtes du
     httptest à zéro — l'absence de déclaration ne coûte rien) ;
  7. API non-enabled sur le palier déclaré ⇒ nil (jamais dispatché = jamais gated).
  Vérifier chaque code via `errors.As(&dispatchGateError{})`.
- [ ] **Step 2 : rouge**, puis **Step 3 : implémentation** dans `dispatchgate.go` :
  - étendre le commentaire du champ `Code` (l.35) avec les trois codes ;
  - étendre `dispatchGateReason` (les trois mappings d'audit) ;
  - la fonction :

```go
// preflightDeployerGate enforces WHO may CARRY this run (G2, ADR-084): for every
// gated+enabled env this run would actually dispatch whose gate declares a
// deployerGroup, the CALLER's Vault token must hold the projected policy. Same
// derivation as the ITSM preflight (scope + enabled deploys, not --env alone),
// same placement: BEFORE any gateway write, zero partial dispatch. One
// lookup-self per run. `labctl dispatch-gate` (standalone stage) deliberately
// does NOT run this: its stage executes before the Vault login exists — the
// refusal lives here, at the moment the carrier's identity exists.
func preflightDeployerGate(ctx context.Context, gchain governance.EnvChain, apis []uac.API, scope, env string) error {
	var policies []string
	looked := false
	for _, a := range apis {
		if !inScope(scope, a.Tenant) {
			continue
		}
		if _, skip := uacSkipReason(a, env, gchain.Envs); skip {
			continue
		}
		envs := []string{env}
		if env == uac.EnvAny {
			envs = a.EnabledEnvsIn(uac.EnvAny, gchain.Envs)
		}
		for _, e := range envs {
			gate, ok := gchain.Gates[e]
			if !ok || gate.DeployerGroup == "" {
				continue // no declaration — credential retention stays the only "who"
			}
			d, ok := a.Deploys[e]
			if !ok || !d.Enabled {
				continue // not actually dispatched to this env
			}
			want, err := gate.DeployerPolicy()
			if err != nil {
				return &dispatchGateError{Code: "DEPLOYER_GROUP_UNSUPPORTED", Msg: fmt.Sprintf(
					"[DEPLOYER_GROUP_UNSUPPORTED] %s/%s→%s: %v — déclaration invérifiable, refus fail-closed",
					a.Tenant, a.Slug, e, err)}
			}
			if !looked {
				vc, enabled := vault.FromEnv()
				if !enabled {
					return &dispatchGateError{Code: "DEPLOYER_GROUP_UNVERIFIABLE", Msg: fmt.Sprintf(
						"[DEPLOYER_GROUP_UNVERIFIABLE] %s/%s→%s: la porte déclare le groupe déployeur %q mais VAULT_ADDR est vide — identité du porteur invérifiable, refus fail-closed",
						a.Tenant, a.Slug, e, gate.DeployerGroup)}
				}
				policies, err = vc.TokenPolicies(ctx)
				if err != nil {
					return &dispatchGateError{Code: "DEPLOYER_GROUP_UNVERIFIABLE", Msg: fmt.Sprintf(
						"[DEPLOYER_GROUP_UNVERIFIABLE] %s/%s→%s: lookup-self en échec (%v) — refus fail-closed",
						a.Tenant, a.Slug, e, err)}
				}
				looked = true
			}
			found := false
			for _, p := range policies {
				if p == want {
					found = true
					break
				}
			}
			if !found {
				return &dispatchGateError{Code: "DEPLOYER_GROUP_REQUIRED", Msg: fmt.Sprintf(
					"[DEPLOYER_GROUP_REQUIRED] %s/%s→%s: la porte déclare le groupe déployeur %q (policy projetée %q) — le token du porteur ne la porte pas, AUCUN apply",
					a.Tenant, a.Slug, e, gate.DeployerGroup, want)}
			}
		}
	}
	return nil
}
```

  (import `"github.com/stoa-platform/stoa-labs/poc/labctl/internal/vault"`.)
  Dans `applyuac.go`, immédiatement après le bloc `preflightDispatchGate` (même
  motif d'audit, `Reason: dispatchGateReason(err)`) :

```go
	// G2 (ADR-084): WHO carries this run — the deployer gate, same placement
	// (before any write), same fail-closed regime as the ITSM preflight.
	if err := preflightDeployerGate(ctx, gchain, apis, scope, uacEnvFlag); err != nil {
		auditor.record(ctx, audit.Event{
			Actor: auditor.actorFor(""), Action: audit.ActionApply,
			Tenant: scope, Resource: uacEnvFlag, Decision: audit.Deny,
			Reason: dispatchGateReason(err), TraceID: audit.NewTraceID(),
		})
		return err
	}
```

- [ ] **Step 4 : vert** — `go test -count=1 ./cmd/labctl/ ./...` ⇒ PASS intégral du module.
- [ ] **Step 5 : commit** — `feat(g2): apply-uac refuse par nom le porteur hors groupe — avant toute écriture`

---

### Task 6 : le miroir shell — env-chain.sh + team-promote.sh §7.a

**Files:**
- Modify: `scripts/lib/env-chain.sh`
- Modify: `scripts/team-promote.sh` (insertion entre la construction de `vcurl` et la lecture `wm-admin`, ~l.489-491)

**Interfaces:**
- Consumes: le gabarit (Task 2) ; `vcurl`/`$TMP/vhdr` (existants, §7) ; `VAULT_IDENTITY_USER` (§6bis).
- Produces: `env_chain_gate_deployer_group <env>` → nom du groupe (vide si non
  déclaré), et `deployer_group_policy <groupe>` → policy projetée (rc=1 hors
  famille) — consommées par Task 7 (harnais) et Task 9 (live).

- [ ] **Step 1 : les fonctions**, dans `env-chain.sh`, après `env_chain_gate_four_eyes` :

```bash
# env_chain_gate_deployer_group <env> — le groupe déployeur de la porte, chaîne
# vide si non déclaré. FONCTION SŒUR, comme fourEyes : JAMAIS un 4e champ de
# env_chain_gate — les appelants lisent GATE=| positionnellement, un champ
# inséré ferait lire deployerGroup là où ils lisent approverGroup, porte
# relâchée EN SILENCE (le motif est documenté sur env_chain_gate_four_eyes).
env_chain_gate_deployer_group() {
  f="$(_env_chain_file)" || return 1
  [ -r "$f" ] || { echo "env-chain: source illisible : $f" >&2; return 1; }
  python3 - "$f" "$1" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(next((g.get("deployerGroup", "") or "" for g in (d.get("gates") or []) if g.get("to") == sys.argv[2]), ""))
PYEOF
}

# deployer_group_policy <groupe> — la policy Vault projetée. MIROIR EXACT de
# Gate.DeployerPolicy() (labctl/internal/governance/envchain.go) : deux familles
# vérifiables, rc=1 au-delà (fail-closed BRUYANT). Toute divergence Go/shell est
# un bug — régime deux moteurs, ADR-083/ADR-084.
deployer_group_policy() {
  case "${1:-}" in
    apim-apply-?*)    printf 'apply-%s' "${1#apim-apply-}" ;;
    apim-operator-?*) printf 'operator-deploy' ;;
    *) return 1 ;;
  esac
}
```

  ⚠ recopier la mécanique EXACTE de lecture YAML des fonctions sœurs existantes
  (elles n'utilisent peut-être pas `import yaml` — regarder `env_chain_gate` et
  faire PAREIL, y compris le traitement d'erreur python).
- [ ] **Step 2 : la garde §7.a** dans `team-promote.sh`, APRÈS `vcurl(){ … }` et
  AVANT `WM_ADMIN_CODE=` (renuméroter le commentaire de section existant « 7. LE
  PALIER EST-IL OUVERT ? » en « 7.b » et poser 7.a devant) :

```bash
# ── 7.a LA DÉCLARATION : QUI DÉPLOIE CE PALIER ? (G2 — ADR-084) ──────────────
# La porte peut nommer un groupe déployeur (annuaire n°2, LDAP→policy Vault —
# jamais la claim KC : ici, la seule identité vérifiée est le token Vault de la
# pause, et V_USER == mergeur est déjà scellé par MERGER_MISMATCH en §6bis).
# Le refus est DÉCLARATIF et NOMMÉ, et précède la rétention (§7.b) : d'abord
# « la chaîne dit QUI », ensuite « ton ticket ouvre-t-il ». Pas de déclaration
# ⇒ AUCUN lookup (rec : autonomie du demandeur, décision client n°1) — la
# rétention §7.b reste inconditionnelle dans tous les cas.
DEPLOYER_GROUP=$(env_chain_gate_deployer_group "$TO_ENV") || fail "PARSE_GATE : deployerGroup"
if [ -n "$DEPLOYER_GROUP" ]; then
  DEPLOYER_POLICY=$(deployer_group_policy "$DEPLOYER_GROUP") \
    || fail "DEPLOYER_GROUP_UNSUPPORTED : '$DEPLOYER_GROUP' est hors des deux familles vérifiables (apim-apply-<x> | apim-operator-<x>) — déclaration invérifiable, refus fail-closed"
  LOOKUP_CODE=$(vcurl -o "$TMP/lookup.json" -w '%{http_code}' --max-time 20 \
    "${VAULT_ADDR}/v1/auth/token/lookup-self") || LOOKUP_CODE=000
  [ "$LOOKUP_CODE" = 200 ] \
    || fail "DEPLOYER_GROUP_UNVERIFIABLE : lookup-self HTTP ${LOOKUP_CODE} — l'identité du porteur est invérifiable, refus fail-closed"
  DEPPOL_VERDICT=$(python3 - "$TMP/lookup.json" "$DEPLOYER_POLICY" <<'PYEOF'
import json, sys
d = (json.load(open(sys.argv[1])) or {}).get("data") or {}
pols = set((d.get("policies") or []) + (d.get("identity_policies") or []))
print("OK" if sys.argv[2] in pols else "KO")
PYEOF
) || fail "DEPLOYER_GROUP_UNVERIFIABLE : lookup-self illisible"
  [ "$DEPPOL_VERDICT" = OK ] \
    || fail "DEPLOYER_GROUP_REQUIRED : la porte vers '$TO_ENV' déclare le groupe déployeur '$DEPLOYER_GROUP' (policy projetée '$DEPLOYER_POLICY') — le token de l'identité '$VAULT_IDENTITY_USER' ne la porte pas, refus"
  echo "déclaration déployeur : '$VAULT_IDENTITY_USER' porte '$DEPLOYER_POLICY' (groupe '$DEPLOYER_GROUP')"
fi
```

  ⚠ le bloc `VAULT_TOKEN_ILLISIBLE`/`vhdr`/`vcurl` (l.486-489) reste AVANT 7.a —
  déplacer le titre de section pour que la construction du header appartienne à 7.a.
- [ ] **Step 3 : lint** — `shellcheck -x scripts/lib/env-chain.sh scripts/team-promote.sh` ⇒ 0 finding
  (ou disables ciblés documentés, style du fichier) ; `bash -n scripts/team-promote.sh`.
- [ ] **Step 4 : vérifier à la main l'ordre** — `grep -n "DEPLOYER_GROUP_REQUIRED\|PALIER_FERME\|run_engine" scripts/team-promote.sh` :
  les trois refus G2 apparaissent AVANT `PALIER_FERME`, qui reste avant l'unique `run_engine`.
- [ ] **Step 5 : commit** — `feat(g2): team-promote refuse par nom le porteur hors groupe — déclaration avant rétention`

---

### Task 7 : le harnais wiring éprouve l'axe — mutations + stub lookup-self

**Files:**
- Modify: `scripts/test-team-promote-wiring.sh`

**Interfaces:**
- Consumes: §7.a (Task 6), le gabarit (Task 2), la mécanique du harnais (ORDRE_TOKENS,
  nc_strict, mutations sur COPIE + cmp anti-no-op, stub.py + ctl.json, refus_attendu,
  EXPECTED_ASSERTIONS).

- [ ] **Step 1 : lire le harnais en entier** (932 lignes) — les conventions sont la
  LOI de ce fichier ; chaque ajout les recopie (copies dans `$TMP`, jamais l'arbre ;
  `rm -f "$STUB_LOG"` avant chaque cas ; capture fichier).
- [ ] **Step 2 : volet A.** Dans `ORDRE_TOKENS`, insérer entre `IDENTITE_REFUSEE`
  et `PALIER_FERME` : `DEPLOYER_GROUP_UNSUPPORTED DEPLOYER_GROUP_UNVERIFIABLE
  DEPLOYER_GROUP_REQUIRED`. Ajouter les épreuves :
  1. le code décommenté appelle `env_chain_gate_deployer_group` et
     `deployer_group_policy` AVANT `run_engine` (grep ancré + numéros de ligne) ;
  2. MUTATION : supprimer le bloc 7.a de la copie
     (`sed '/7.a LA DÉCLARATION/,/déclaration déployeur/d'` — ancres à ajuster sur
     le texte réel, `cmp -s` anti-no-op) ⇒ `ordre_verdict` doit rendre KO
     (jetons absents avant le moteur) ;
  3. MUTATION : inverser 7.a et 7.b (déplacer la lecture wm-admin avant le bloc
     déployeur, motif awk du cas ⑲) ⇒ le verdict d'ordre relatif
     `DEPLOYER_GROUP_REQUIRED < PALIER_FERME` rougit ; contrôler `bash -n` que le
     mutant PARSE, et que l'ORIGINAL est intact après coup.
- [ ] **Step 3 : volet B — le stub.** Étendre `stub.py` : route
  `GET /v1/auth/token/lookup-self` rendant le code et les policies pilotés par
  `ctl.json` (nouvelles clés, ex. `"vault":{"wm-admin":200,"admin-oauth":200,
  "lookup":200,"lookup_policies":["default","apply-int"]}`) ; étendre `set_ctl`
  en conséquence. ⚠ TOUS les cas int existants qui atteignaient §7 doivent
  maintenant fournir un lookup qui PASSE (sinon ils rougissent pour la mauvaise
  raison) — les repérer en lançant le harnais après l'ajout des routes, AVANT
  d'ajouter les cas neufs.
- [ ] **Step 4 : volet B — les cas** (promotion vers int, gabarit :
  `deployerGroup: apim-apply-int`) :
  1. lookup 200, policies SANS `apply-int`, wm-admin=200 ⇒ `refus_attendu
     DEPLOYER_GROUP_REQUIRED` (+ `$STUB_LOG` absent — le helper le fait) ;
  2. lookup 403 ⇒ `refus_attendu DEPLOYER_GROUP_UNVERIFIABLE` ;
  3. chaîne VARIANTE via `STOA_ENV_CHAIN_FILE` (copie du gabarit où int porte
     `deployerGroup: int-team`) ⇒ `refus_attendu DEPLOYER_GROUP_UNSUPPORTED` ;
  4. lookup 200 policies AVEC `apply-int`, wm-admin=403 ⇒ `PALIER_FERME`
     (la déclaration passe, la rétention mord toujours — l'ordre 7.a → 7.b est
     OBSERVÉ en exécution, pas seulement en statique) ;
  5. chemin nominal rec (existant) : ajouter l'assertion « AUCUN appel
     lookup-self dans le log du stub » (rec ne déclare rien ⇒ zéro lookup) ;
  6. 4-yeux homol : rejouer le cas ⑮ (merger == promoted_by) sur `TO_ENV=homol`
     ⇒ `IDENTITE_REFUSEE` + `FOUR_EYES_VIOLATION` dans le log (la contre-épreuve
     du GOAL « rejoué sur les trois nouveaux paliers » côté chaîne, homol compris).
- [ ] **Step 5 : le compte** — lancer `bash scripts/test-team-promote-wiring.sh`,
  lire le total réel, poser `EXPECTED_ASSERTIONS=<mesuré>`, relancer ⇒ 0 FAIL.
- [ ] **Step 6 : `make lint-ci`** intégral ⇒ rc=0 (aucune étape cassée par G2).
- [ ] **Step 7 : commit** — `test(g2): le harnais wiring éprouve l'axe déployeur — ordre, mutations, stub lookup-self`

---

### Task 8 : les annuaires du lab et les gestes exploitant

**Files:**
- Create: `scripts/setup-deployer-groups.sh`
- Modify: `scripts/setup-vault-paliers.sh` (volet `--grant-ci`)
- Modify: `scripts/seed-governance-chain.sh` (read-back étendu)
- Modify: `scripts/api-promote-request.sh` (corps de PR)
- Modify: `ci/Jenkinsfile.prod` (commentaire conséquence D5)
- Modify: `Makefile` (shellcheck du nouveau script)

**Interfaces:**
- Consumes: la table de projection (Tasks 1/6), `env_chain`/`env_chain_nonprod`,
  le mapping LDAP posé par G4 (`auth/ldap/groups/apim-apply-<env>` → `apply-<env>`).
- Produces: groupes LDAP `apim-apply-int`={bob}, `apim-apply-homol`={carol}
  (surchargeables), consommés par Task 9.

- [ ] **Step 1 : `setup-deployer-groups.sh`.** Modèle : la pose ldif de
  `setup-vault-ldap.sh` (docker exec openldap, `ldapadd`/`ldapmodify`, users
  existants `uid=bob`/`uid=carol` sous `ou=People,dc=corp,dc=example`).
  Comportement :
  - dérive les paliers de la chaîne (`env_chain_nonprod`) ; pose les groupes
    `groupOfNames` `apim-apply-<env>` sous `ou=Groups` UNIQUEMENT pour les
    paliers ayant un membre configuré (groupOfNames exige ≥1 member — un palier
    sans déployeur nommé = pas de groupe, grant à la demande, et on l'ÉCRIT) ;
  - membres par défaut : `DEPLOYERS_INT="${DEPLOYERS_INT:-bob}"`,
    `DEPLOYERS_HOMOL="${DEPLOYERS_HOMOL:-carol}"`, rec/dev vides ;
  - idempotent (ldapadd tolère « Already exists » en le disant, ou
    ldapmodify replace) ; contre-épreuve intégrée : alice n'est membre d'AUCUN
    groupe posé (même motif que setup-release-team.sh:81) ;
  - NE TOUCHE PAS Vault (le mapping groupe→policy est déjà posé par
    setup-vault-paliers.sh — l'écrire en tête) ;
  - `apim-operator-prod` (oscar) existe déjà : le script le VÉRIFIE (présence +
    oscar membre) sans le reposer.
- [ ] **Step 2 : `--grant-ci` dans `setup-vault-paliers.sh`.** Nouveau mode à côté
  de `--mint` : lit le rôle AppRole `ci-pipeline`
  (`GET /v1/auth/approle/role/ci-pipeline`), ajoute aux `token_policies` les
  `apply-<env>` de `env_chain_nonprod` (terminus exclu par STRUCTURE, comme
  partout), réécrit le rôle (read-modify-write, dédoublonné), imprime avant/après.
  Commentaire de tête : « c'est la DÉCLARATION explicite que la machine du CI
  gouvernance est le déployeur hors-prod (ADR-084/D6) ; sans ce geste, le
  pipeline hors-prod refuse DEPLOYER_GROUP_REQUIRED sur les paliers déclarés —
  comportement voulu d'une déclaration qui vient d'apparaître ».
- [ ] **Step 3 : read-back de seed.** Dans `seed-governance-chain.sh`, la boucle
  de vérification `for E in homol prod` (approverGroup) gagne la vérification du
  `deployerGroup` attendu (`apim-apply-homol` / `apim-operator-prod`) + int
  (`apim-apply-int`) — relu DEPUIS Gitea raw, comme l'existant.
- [ ] **Step 4 : corps de PR.** Dans `api-promote-request.sh`, à côté de la ligne
  « Groupe d'approbation ATTENDU … attendu, **pas vérifié** » (l.280), ajouter :

```bash
DEPLOYER_GROUP_LINE="Groupe déployeur DÉCLARÉ : \`${DEPLOYER_GROUP:-<aucun>}\` — VÉRIFIÉ à l'apply (team-promote §7.a, refus DEPLOYER_GROUP_REQUIRED ; G2/ADR-084). L'approbation, elle, reste le MERGE, protégé par la branche (ADR-081)."
```

  avec `DEPLOYER_GROUP=$(env_chain_gate_deployer_group "$TO_ENV" || true)` lu comme
  les autres champs de porte du fichier — suivre le motif local (échos + corps de PR).
- [ ] **Step 5 : `ci/Jenkinsfile.prod`** — sous le commentaire des paramètres
  VAULT_USER (l.29-32), ajouter :

```groovy
        // ⚠ G2 (ADR-084) : la porte prod déclare deployerGroup=apim-operator-prod.
        // Le repli AppRole ci-dessous est donc REFUSÉ par apply-uac
        // (DEPLOYER_GROUP_REQUIRED : le token AppRole ne porte pas operator-deploy).
        // Déployer prod exige un humain du groupe — l'imputabilité n'est plus un
        // vœu, c'est la déclaration qui la force. Pour un compte de service
        // d'exception : grant EXPLICITE de la policy (geste exploitant).
```

- [ ] **Step 6 : Makefile** — ajouter `scripts/setup-deployer-groups.sh` à la liste
  shellcheck de l'étape 2 de `lint-ci`.
- [ ] **Step 7 : preuves** — `bash -n` des quatre scripts ; `shellcheck -x` ;
  `make lint-ci` ⇒ rc=0. (La pose LDAP réelle est éprouvée par Task 9.)
- [ ] **Step 8 : commit** — `feat(g2): les annuaires du lab — groupes déployeurs, grant machine explicite, PR qui dit qui`

---

### Task 9 : la porte live — le grant est vivant

**Files:**
- Create: `scripts/test-deployer-gate-live.sh`

**Interfaces:**
- Consumes: setup-deployer-groups.sh (Task 8), `deployer_group_policy` (Task 6),
  le Vault/LDAP du lab (`lib/lab-vault-users.sh` pour les mots de passe),
  le mapping G4 `auth/ldap/groups/apim-apply-<env>`.

- [ ] **Step 1 : le script.** Modèle : `test-palier-retention-live.sh` (préambule,
  exit 2 si le lab est absent — Vault ou openldap injoignables —, compteur
  ok/bad, trap). Épreuves :
  1. pose : `bash scripts/setup-deployer-groups.sh` ⇒ rc=0, idempotent (2e run rc=0) ;
  2. login LDAP bob (`POST /v1/auth/ldap/login/bob`, mot de passe de
     `lib/lab-vault-users.sh`, JSON par python3, jamais argv) ⇒ token dont
     `lookup-self` porte `apply-int` (capture fichier puis python — JAMAIS
     `curl | grep &&…||` sous pipefail) ;
  3. login alice ⇒ `lookup-self` SANS `apply-int` ni `apply-homol` (la persona
     demandeuse n'est déployeuse de rien) ;
  4. le miroir shell : `deployer_group_policy apim-apply-int` ⇒ `apply-int` ;
     `deployer_group_policy int-team` ⇒ rc=1 ;
  5. CONTRE-ÉPREUVE DU GRANT VIVANT : retirer bob du groupe LDAP
     (`ldapmodify delete member` — si le groupe devient vide, le supprimer puis
     le reposer à la restauration) ⇒ RE-login bob ⇒ lookup-self SANS `apply-int`
     (le droit suit l'annuaire, pas un état gelé) ; restauration par
     setup-deployer-groups.sh + re-login qui re-porte la policy ;
  6. contre-épreuve d'annuaire : alice ajoutée à RIEN — re-vérifier après la
     restauration (pas de fuite de membership par le replay).
  Trap : restauration inconditionnelle (re-run du setup) même sur échec.
- [ ] **Step 2 : run live** — `bash scripts/test-deployer-gate-live.sh` sur le lab
  ⇒ X/X, 0 FAIL (mesurer X ; exit 2 documenté si le lab est éteint — relancer
  les conteneurs requis avant de conclure).
- [ ] **Step 3 : `make lint-ci`** — le live ne s'y branche PAS (comme les autres
  `-live`) mais s'ajoute à la liste shellcheck de l'étape 2.
- [ ] **Step 4 : commit** — `test(g2): porte live — le grant déployeur suit l'annuaire, alice reste dehors`

---

### Task 10 : ADR-084, doc opérateur, GOAL, handoff

**Files:**
- Create: `adr/adr-084-axe-qui-deploie-deployer-group.md`
- Modify: `ENVIRONNEMENTS.md` (§ « Promouvoir une API (G5) » + § chaîne)
- Modify: `GOAL-cd-promotion-5-envs-2026-08-26.md` (G2 : livré, portes, ce qui reste)
- Create: `HANDOFF-2026-08-27-G2-AXE-QUI-DEPLOIE.md`

- [ ] **Step 1 : ADR-084.** Style ADR-082/083 (titre long affirmatif, statut,
  maturité avec les X/X RÉELS des portes, contexte, décision, conséquences,
  résiduel). Contenu OBLIGATOIRE : les deux annuaires et pourquoi deployerGroup
  vit dans le n°2 (au dispatch, la seule identité vérifiée partout est le token
  Vault) ; la table de projection et son fail-closed bruyant ; les trois codes,
  identiques deux moteurs ; les sites d'enforcement et le NON-site (approve,
  dispatch-gate standalone — documentés) ; la conséquence prod (repli AppRole
  refusé = imputabilité forcée) ; le grant machine `--grant-ci` comme
  DÉCLARATION ; les limites : 4-yeux pipeline inerte (build-user-vars),
  approverGroup toujours pas enforced au merge (ADR-081 : protection de
  branche), parité d'état = G8.
- [ ] **Step 2 : ENVIRONNEMENTS.md** — dans le parcours opérateur : qui peut
  porter une promotion par palier, les trois refus et leur remède (grant LDAP /
  --grant-ci / corriger la déclaration), le geste d'ouverture complété
  (« ouvrir un palier = mint/grant (G4) + être du groupe déclaré (G2) »).
- [ ] **Step 3 : GOAL** — sous « ### G2 » : livré le 2026-08-27, portes réelles
  (test-env-chain X/X, wiring X/X, go test, live X/X), la ligne d'honnêteté
  (4-yeux pipeline inerte tant que build-user-vars manque ; E2E Jenkins
  conditionné aux gestes exploitant du handoff G5), et le renvoi ADR-084.
- [ ] **Step 4 : handoff** — même gabarit que G5 : tableau des portes avec les
  comptes MESURÉS, « à lire en premier », gestes exploitant
  (`setup-deployer-groups.sh` si lab re-seedé, `setup-vault-paliers.sh --grant-ci`,
  et RAPPEL des gestes G5 toujours pendants — push gitea, credential
  write:package), dettes/pièges nouveaux, état du lab en fin de session.
- [ ] **Step 5 : preuve finale** — `make lint-ci` intégral rc=0 + `cd labctl &&
  GOPROXY=off GOFLAGS=-mod=vendor go test -count=1 ./...` ⇒ 0 échec +
  `bash scripts/test-env-chain.sh` + `bash scripts/test-deployer-gate-live.sh`
  (lab) — recopier les comptes RÉELS dans l'ADR/le GOAL/le handoff.
- [ ] **Step 6 : commit** — `docs(g2): ADR-084 + parcours opérateur + GOAL — l'axe qui déploie est déclaré, refusé par nom, prouvé`
