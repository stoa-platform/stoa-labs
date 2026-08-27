# G8 — Parité des deux moteurs : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fermer la porte G8 : les deux moteurs (`apim_promote_api` /
`labctl promote`), sur le même `.promote.yml`, produisent un état de gateway
identique sur les champs du registre — avec un registre mécanique des écarts
et une contre-épreuve par mutation qui rougit.

**Architecture:** (1) un verbe de relecture `labctl promote --action verify`
(miroir de `tasks/verify.yml`) ; (2) un harnais live
`scripts/test-parity-moteurs.sh` (export ×2, import ×2 à archive égale,
snapshot normalisé, diff sous registre d'exclusions, verify ×2, mutations ×2) ;
(3) le registre `scripts/testdata/parity-ecarts.txt` consommé par le harnais +
ADR-087 (registre humain).

**Tech Stack:** Go (labctl, httptest), bash+jq+curl, ansible-playbook, wM 10.15
réel (`poc-webmethods-real`, localhost:5555), Vault dev (localhost:8200).

**Spec:** `docs/superpowers/specs/2026-08-27-g8-parite-des-moteurs-design.md`

## Global Constraints

- Gateway réelle : `GW_ADMIN=http://localhost:5555/rest/apigateway`, keepalive
  ~20 min ⇒ `wait_gw` avant chaque phase (motif `test-promote-verb-live.sh`).
- Assets jetables préfixés `g8par-`, purgés au setup ET par trap.
- Vault : `VAULT_ADDR=http://localhost:8200`, token via `VAULT_TOKEN`
  (défaut lab `stoa-root-token`) ; KV v2 mount `secret`, prefix `stoa`
  (identiques rôle/labctl — mesuré).
- labctl : build `GOPROXY=off GOFLAGS=-mod=vendor`.
- Aucune modification de la SÉMANTIQUE des moteurs (seul ajout : un verbe de
  lecture) ; les mutations se font sur des COPIES dans `$WORK`.
- Commits `type(scope): description` ; jamais de secret committé.

---

### Task 1: `VerifyEndpointAliasValue` — la relecture d'alias côté Go

**Files:**
- Modify: `labctl/internal/adapter/webmethods/archive.go` (après
  `assertEndpointAliasValue`, ~l.466)
- Test: `labctl/internal/adapter/webmethods/archive_test.go`

**Interfaces:**
- Produces: `func (a *Adapter) VerifyEndpointAliasValue(ctx context.Context, name, want string) error` —
  lecture seule ; erreur `ALIAS_DRIFT` (valeur ≠ want) ou `ALIAS_MISSING`
  (alias absent) ; `nil` si `endPointURI == want`.

- [x] **Step 1: test failing** — dans `archive_test.go`, sur le modèle des
  tests httptest existants du fichier (serveur `httptest.NewServer` qui sert
  `GET /rest/apigateway/alias`) :

```go
func TestVerifyEndpointAliasValue(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/rest/apigateway/alias" {
			t.Errorf("unexpected call %s %s (verify must be read-only)", r.Method, r.URL.Path)
			http.NotFound(w, r)
			return
		}
		fmt.Fprint(w, `{"alias":[{"id":"a1","name":"g8par-backend","type":"endpoint","endPointURI":"http://poc-token-echo:8080/backend/rec"}]}`)
	}))
	defer srv.Close()
	a := newTestAdapter(t, srv.URL) // helper existant du fichier (sinon: construire comme les tests voisins)

	if err := a.VerifyEndpointAliasValue(context.Background(), "g8par-backend", "http://poc-token-echo:8080/backend/rec"); err != nil {
		t.Fatalf("nominal: %v", err)
	}
	if err := a.VerifyEndpointAliasValue(context.Background(), "g8par-backend", "http://autre"); err == nil || !strings.Contains(err.Error(), "ALIAS_DRIFT") {
		t.Fatalf("want ALIAS_DRIFT, got %v", err)
	}
	if err := a.VerifyEndpointAliasValue(context.Background(), "absent", "x"); err == nil || !strings.Contains(err.Error(), "ALIAS_MISSING") {
		t.Fatalf("want ALIAS_MISSING, got %v", err)
	}
}
```

- [x] **Step 2:** `cd labctl && GOPROXY=off GOFLAGS=-mod=vendor go test ./internal/adapter/webmethods/ -run TestVerifyEndpointAliasValue -count=1` → FAIL (méthode absente).
- [x] **Step 3: implémentation** (archive.go) :

```go
// VerifyEndpointAliasValue re-reads the env-local backend alias WITHOUT
// writing: the verify half of the alias-first contract (mirror of the role's
// tasks/verify.yml ALIAS_DRIFT check).
func (a *Adapter) VerifyEndpointAliasValue(ctx context.Context, name, want string) error {
	aliases, err := a.listAliases(ctx)
	if err != nil {
		return err
	}
	for _, al := range aliases {
		if al.Name != name {
			continue
		}
		got, _ := al.Raw["endPointURI"].(string)
		if got != want {
			return fmt.Errorf("verify: ALIAS_DRIFT — alias %q carries %q, the env declares %q", name, got, want)
		}
		return nil
	}
	return fmt.Errorf("verify: ALIAS_MISSING — endpoint alias %q not found", name)
}
```

- [x] **Step 4:** re-run → PASS. **Step 5:** commit
  `feat(g8): labctl — relecture d'alias sans écriture (ALIAS_DRIFT/ALIAS_MISSING)`.

---

### Task 2: `labctl promote --action verify`

**Files:**
- Modify: `labctl/cmd/labctl/promote.go`
- Test: `labctl/cmd/labctl/promote_test.go`

**Interfaces:**
- Consumes: `VerifyAPIActive(ctx, guid) (wmAPI, error)` (existant),
  `VerifyEndpointAliasValue` (Task 1), `InvokeSmoke` (existant).
- Produces: `labctl promote --manifest m.yml --env rec --action verify -f targets.yaml`
  → lecture seule, sortie `PROMOTE_CONFIRMED: <name> v<version> guid=<guid> …` ;
  refus nommés `VERIFY_REFUSED` (guid absent), `PROMOTE_UNCONFIRMED`
  (API absente/inactive/mauvais nom — porté par l'erreur de `VerifyAPIActive`
  ou le check de nom), `ALIAS_DRIFT`/`ALIAS_MISSING` (Task 1).

- [x] **Step 1: tests failing** (promote_test.go) — un serveur httptest qui
  joue la gateway, un `targets.yaml` temporaire pointant dessus, exécution de
  la commande cobra :

```go
// runPromoteVerifyAgainst spins a fake gateway, writes a targets file and a
// manifest, runs `promote --action verify`, and returns (stdout, err, calls).
func runPromoteVerifyAgainst(t *testing.T, apiJSON, aliasJSON string) (string, error, *[]string) {
	t.Helper()
	calls := &[]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*calls = append(*calls, r.Method+" "+r.URL.Path)
		if r.Method != http.MethodGet {
			http.Error(w, "verify must be read-only", http.StatusMethodNotAllowed)
			return
		}
		switch {
		case strings.HasPrefix(r.URL.Path, "/rest/apigateway/apis/"):
			fmt.Fprint(w, apiJSON)
		case r.URL.Path == "/rest/apigateway/alias":
			fmt.Fprint(w, aliasJSON)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	dir := t.TempDir()
	manifest := filepath.Join(dir, "m.promote.yml")
	os.WriteFile(manifest, []byte(`apim_promote:
  name: "g8par-api"
  version: "1.0.0"
  guid: "11111111-2222-3333-4444-555555555555"
  archive: "/tmp/unused.zip"
  backend_alias: { name: "g8par-backend" }
  per_env:
    rec: { backend_alias: { url: "http://poc-token-echo:8080/backend/rec" } }
`), 0o600)
	targetsF := filepath.Join(dir, "targets.yaml")
	os.WriteFile(targetsF, []byte(`apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: g8par
contract: `+manifest+`
targets:
  - name: wm
    type: webmethods
    adminUrl: `+srv.URL+`
    gatewayUrl: `+srv.URL+`
    credentials: { username: u, password: p }
`), 0o600)
	out := new(bytes.Buffer)
	rootCmd.SetOut(out)
	rootCmd.SetErr(out)
	rootCmd.SetArgs([]string{"promote", "--manifest", manifest, "--env", "rec",
		"--action", "verify", "-f", targetsF})
	err := rootCmd.Execute()
	return out.String(), err, calls
}

func TestPromoteVerify_NominalIsReadOnly(t *testing.T) {
	apiJSON := `{"apiResponse":{"api":{"id":"11111111-2222-3333-4444-555555555555","apiName":"g8par-api","apiVersion":"1.0.0","isActive":true}}}`
	aliasJSON := `{"alias":[{"id":"a1","name":"g8par-backend","type":"endpoint","endPointURI":"http://poc-token-echo:8080/backend/rec"}]}`
	out, err, calls := runPromoteVerifyAgainst(t, apiJSON, aliasJSON)
	if err != nil {
		t.Fatalf("verify nominal: %v (out=%s)", err, out)
	}
	if !strings.Contains(out, "PROMOTE_CONFIRMED") {
		t.Fatalf("want PROMOTE_CONFIRMED, out=%s", out)
	}
	for _, c := range *calls {
		if !strings.HasPrefix(c, "GET ") {
			t.Fatalf("verify wrote to the gateway: %s", c)
		}
	}
}

func TestPromoteVerify_RefusesInactive(t *testing.T) {
	apiJSON := `{"apiResponse":{"api":{"id":"11111111-2222-3333-4444-555555555555","apiName":"g8par-api","apiVersion":"1.0.0","isActive":false}}}`
	aliasJSON := `{"alias":[]}`
	_, err, _ := runPromoteVerifyAgainst(t, apiJSON, aliasJSON)
	if err == nil {
		t.Fatal("inactive API must refuse")
	}
}

func TestPromoteVerify_NamesAliasDrift(t *testing.T) {
	apiJSON := `{"apiResponse":{"api":{"id":"11111111-2222-3333-4444-555555555555","apiName":"g8par-api","apiVersion":"1.0.0","isActive":true}}}`
	aliasJSON := `{"alias":[{"id":"a1","name":"g8par-backend","type":"endpoint","endPointURI":"http://WRONG"}]}`
	_, err, _ := runPromoteVerifyAgainst(t, apiJSON, aliasJSON)
	if err == nil || !strings.Contains(err.Error(), "ALIAS_DRIFT") {
		t.Fatalf("want ALIAS_DRIFT, got %v", err)
	}
}

func TestPromoteVerify_RequiresPinnedGUID(t *testing.T) {
	// même déroulé mais manifeste avec guid:"" → VERIFY_REFUSED avant tout réseau
}
```

  (Adapter les imports ; si `rootCmd` ne se réexécute pas proprement deux fois,
  suivre le motif des autres tests cmd du paquet — chercher `rootCmd.SetArgs`
  dans `*_test.go` et reprendre leur reset.)

- [x] **Step 2:** run → FAIL (`--action verify` rejeté par runPromote).
- [x] **Step 3: implémentation** (promote.go) :
  - accepter `verify` dans le garde d'action (`export|import|verify`) ;
  - court-circuit archive : `applyArchiveOverride` et l'exigence
    `spec.Archive != ""` ne s'appliquent PAS à verify (relecture sans octets) ;
  - nouvelle fonction :

```go
func runPromoteVerify(ctx context.Context, out io.Writer, wm *webmethods.Adapter, targetName string, spec promoteSpec) error {
	if spec.GUID == "" {
		return fmt.Errorf("promote: VERIFY_REFUSED — guid (id-map) is required to verify (name lookups can lie across envs)")
	}
	rec, err := wm.VerifyAPIActive(ctx, spec.GUID)
	if err != nil {
		return fmt.Errorf("promote: PROMOTE_UNCONFIRMED — %w", err)
	}
	if rec.APIName != spec.Name {
		return fmt.Errorf("promote: PROMOTE_UNCONFIRMED — guid=%s carries %q, manifest declares %q", spec.GUID, rec.APIName, spec.Name)
	}
	if spec.BackendAlias.Name != "" {
		if spec.BackendAlias.URL == "" {
			return fmt.Errorf("promote: ALIAS_UNDEFINED — backend_alias %q has no url for env %q (declare it under per_env)", spec.BackendAlias.Name, promoteEnvFlag)
		}
		if err := wm.VerifyEndpointAliasValue(ctx, spec.BackendAlias.Name, spec.BackendAlias.URL); err != nil {
			return err
		}
	}
	if spec.SmokePath != "" {
		if err := wm.InvokeSmoke(ctx, spec.SmokePath); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "PROMOTE_CONFIRMED: %s v%s guid=%s active on %s (env %q, verify read-only)\n",
		rec.APIName, rec.APIVersion, spec.GUID, targetName, promoteEnvFlag)
	return nil
}
```

  (Signature `wmAPI` : reprendre les champs réellement exportés par
  `VerifyAPIActive` — relire `archive.go:366` ; si `rec.APIName` n'existe pas
  sous ce nom, utiliser le champ réel.)
- [x] **Step 4:** run tests paquet cmd + webmethods → PASS.
- [x] **Step 5:** commit
  `feat(g8): labctl promote --action verify — la porte rejouable côté Go, lecture seule`.

---

### Task 3: registre des écarts + harnais phases préflight/setup/EXPORT ×2

**Files:**
- Create: `scripts/testdata/parity-ecarts.txt`
- Create: `scripts/test-parity-moteurs.sh` (phases 0-1)

**Interfaces:**
- Produces: format registre — lignes `state<TAB><chemin jq><TAB><raison>` et
  `artifact<TAB><motif sed><TAB><raison>` (commentaires `#`) ; fonctions bash
  `wait_gw`, `adm`, `wipe_target`, `snapshot <fichier>` (Task 4),
  `engine_export/import <ansible|labctl> [rolesdir] [labctlbin]`.

- [x] **Step 1:** registre initial (les seules exclusions POSÉES d'avance sont
  celles déjà prouvées ailleurs ; tout le reste devra être mesuré en Task 6) :

```
# parity-ecarts.txt — registre MÉCANIQUE des écarts assumés (ADR-087).
# Un écart d'état non listé ici fait ROUGIR test-parity-moteurs.sh.
# state    <chemin jq dans le snapshot>    <raison mesurée>
# artifact <motif sed -E appliqué aux entrées texte>    <raison mesurée>
```

  (vide de règles au départ — il se remplit par la mesure, jamais d'avance.)

- [x] **Step 2:** harnais, squelette + phases 0-1. Reprendre de
  `test-promote-verb-live.sh` : `wait_gw`, `adm`, `say/ok/ko/check`, build
  labctl, préflight outils (+`zipinfo`), contrat OpenAPI jetable (servers
  littéral). Spécifique G8 :

```bash
API=g8par-api; BALS=g8par-backend; CALS=g8par-backend-creds
GALS=g8par-flag; AS=g8par-as; SCOPE_NAME="g8par-api:1.0.0"
VAULT="${VAULT_ADDR:-http://localhost:8200}"
VTOK="${VAULT_TOKEN:-stoa-root-token}"
REG="$REPO/scripts/testdata/parity-ecarts.txt"

# seed Vault (KV v2 secret/data/stoa/envs/rec/backends/g8par)
curl -sS -H "X-Vault-Token: $VTOK" -X POST \
  -d '{"data":{"username":"g8par-user","password":"g8par-pass"}}' \
  "$VAULT/v1/secret/data/stoa/envs/rec/backends/g8par" -o /dev/null

# AS alias jetable (shape authServerAlias prouvée par labctl inboundauth.go:441)
adm -H "Content-Type: application/json" -X POST "$GW/alias" -d '{
  "name":"'"$AS"'","type":"authServerAlias",
  "localIntrospectionConfig":{"issuer":"https://g8par.invalid","jwksuri":"https://g8par.invalid/jwks"}}'
```

  Manifeste PARTAGÉ unique `$WORK/parity.promote.yml` (name/version/guid vide,
  overwrite par défaut, backend_alias `$BALS`, cred_alias
  `{name: $CALS, vault_sub: ""}` + per_env.rec
  `{backend_alias.url: http://poc-token-echo:8080/backend/rec, cred_alias.vault_sub: envs/rec/backends/g8par}`,
  aliases `[{name: $GALS, record:{type: simple, value: g8par}}]`,
  scope_mapping `{external_scope: g8par.read, auth_server_alias: $AS}`).
  Setup source : purge `g8par-*`, POST alias backend littéral, POST API
  openapi, activate (motif G5 `setup_engine`).

  Phase 1 — EXPORT ×2 : `engine_export ansible` → `$WORK/A.zip`,
  `engine_export labctl` → `$WORK/B.zip` (invocations identiques à
  `test-promote-verb-live.sh:152-170`, avec en plus
  `-e apim_ss_vault_addr=$VAULT -e apim_ss_vault_token=$VTOK` côté rôle et
  `VAULT_ADDR/VAULT_TOKEN` exportés côté labctl). Parité d'artefact :

```bash
zipinfo -1 "$WORK/A.zip" | sort > "$WORK/A.toc"
zipinfo -1 "$WORK/B.zip" | sort > "$WORK/B.toc"
diff -u "$WORK/A.toc" "$WORK/B.toc"   # même liste d'entrées
# par entrée : texte → normalisé par les règles `artifact` du registre puis diff ;
# binaire → sha256 égal
while IFS= read -r entry; do
  unzip -p "$WORK/A.zip" "$entry" > "$WORK/ea"; unzip -p "$WORK/B.zip" "$entry" > "$WORK/eb"
  norm "$WORK/ea"; norm "$WORK/eb"        # applique les sed du registre
  cmp -s "$WORK/ea" "$WORK/eb" || ko "ARTIFACT_DIVERGENT: $entry"
done < "$WORK/A.toc"
```

  Épingler le GUID de l'archive dans le manifeste partagé (motif G5 E6/E7),
  digest sha256 de **A.zip** (l'archive UNIQUE des imports).
- [x] **Step 3:** run partiel (`bash scripts/test-parity-moteurs.sh`) : phases
  0-1 vertes ou écarts d'artefact MESURÉS → chaque motif volatil entre au
  registre (`artifact`) avec sa raison, re-run vert.
- [x] **Step 4:** commit
  `feat(g8): harnais de parité — export par les deux moteurs, artefacts comparés entrée par entrée sous registre`.

---

### Task 4: snapshot normalisé + IMPORT ×2 + LE diff de parité

**Files:**
- Modify: `scripts/test-parity-moteurs.sh` (phases 2-4)

**Interfaces:**
- Produces: `snapshot <out.json>` — objet jq `{api, actions, aliases, scope, dp}` ;
  `wipe_target` — retrait API/aliases g8par-(backend|creds|flag)/scope
  mapping, l'AS reste ; `parity_diff <A.json> <B.json>` — 0 si identiques
  après exclusions `state`, sinon imprime les chemins divergents.

- [x] **Step 1:** implémentation :

```bash
# retire du snapshot les chemins enregistrés (colonne 2 des lignes `state`)
strip_registered() { # $1=json in-place
  local p
  while IFS=$'\t' read -r kind p _; do
    [ "$kind" = "state" ] || continue
    jq "del($p)" "$1" > "$1.t" && mv "$1.t" "$1"
  done < <(grep -v '^#' "$REG")
}

snapshot() { # $1=fichier de sortie — mêmes lectures pour A et B, triées
  local api actions aliases scope dp pol act
  api=$(adm "$GW/apis/$PIN_GUID" | jq '.apiResponse.api')
  actions='[]'
  for pol in $(printf '%s' "$api" | jq -r '.policies[]?' | sort); do
    for act in $(adm "$GW/policies/$pol" | jq -r '.policy.policyAction[]?' | sort); do
      actions=$(printf '%s' "$actions" | jq --argjson a "$(adm "$GW/policyActions/$act" | jq '.policyAction')" '. + [$a]')
    done
  done
  aliases=$(adm "$GW/alias" | jq --arg b "$BALS" --arg c "$CALS" --arg g "$GALS" \
    '[.alias[] | select(.name==$b or .name==$c or .name==$g)] | sort_by(.name)')
  scope=$(adm "$GW/scopes" | jq --arg n "$SCOPE_NAME" \
    '[.scopes[]? | select(.scopeName==$n)] | first // {}')
  dp=$(curl -sS -m 8 "$DP/$API/1.0.0/ping" | jq -c '.path // empty' || printf '""')
  jq -n --argjson api "$api" --argjson actions "$actions" \
        --argjson aliases "$aliases" --argjson scope "$scope" --argjson dp "${dp:-\"\"}" \
        '{api:$api, actions:($actions|sort_by(.id)), aliases:$aliases, scope:$scope, dp:$dp}' > "$1"
  strip_registered "$1"
}

parity_diff() { # $1 $2 — imprime les chemins qui divergent, rc=1 si écart
  jq -n --slurpfile a "$1" --slurpfile b "$2" '
    def leaves: paths(scalars) as $p | {($p|map(tostring)|join(".")): getpath($p)};
    ([$a[0]|leaves] | add // {}) as $A | ([$b[0]|leaves] | add // {}) as $B
    | [ ((($A|keys) + ($B|keys))|unique[]) | select($A[.] != $B[.])
        | {champ:., ansible:$A[.], labctl:$B[.]} ]' | tee "$WORK/parity.diff.json" \
    | jq -e 'length == 0' > /dev/null
}

wipe_target() {
  adm -X PUT "$GW/apis/$PIN_GUID/deactivate" -o /dev/null
  adm -X DELETE "$GW/apis/$PIN_GUID" -o /dev/null
  local id n
  for n in "$BALS" "$CALS" "$GALS"; do
    id=$(alias_id "$n"); [ -n "$id" ] && adm -X DELETE "$GW/alias/$id" -o /dev/null
  done
  id=$(adm "$GW/scopes" | jq -r --arg n "$SCOPE_NAME" '[.scopes[]?|select(.scopeName==$n)|.id][0] // empty')
  [ -n "$id" ] && adm -X DELETE "$GW/scopes/$id" -o /dev/null
  return 0
}
```

  (Shapes `/policies/{id}` et `/policyActions/{id}` : si le produit répond
  autrement — clé racine différente —, adapter à LA SHAPE MESURÉE et la noter
  dans l'ADR ; ne jamais deviner en silence. Si `.policies` n'est pas porté
  par l'api record, lister via `GET /policies?policyIds=` mesuré.)

  Phase 2 : `wait_gw` ; `wipe_target` ; `engine_import ansible` (archive
  A.zip, sha pinné, `-e apim_ss_env=rec`, Vault) ; `snapshot $WORK/snap-ansible.json`.
  Phase 3 : idem avec `engine_import labctl` (MÊME A.zip via `--archive`) →
  `$WORK/snap-labctl.json`.
  Phase 4 : `parity_diff` → vert = LA porte ; rouge = imprimer
  `parity.diff.json`, MESURER chaque champ, décider : volatil justifié →
  registre + raison ; sémantique → STOP, c'est un vrai écart de moteur
  (le traiter à la Task 6 comme découverte, jamais l'exclure par confort).
- [x] **Step 2:** run partiel ; peupler le registre depuis la mesure
  (attendus probables, à CONFIRMER : ids de scope-mapping et d'aliases
  générés par POST par-run ; horodatages du record API).
- [x] **Step 3:** commit
  `feat(g8): la porte — même manifeste, même archive, deux moteurs, un seul état (diff sous registre)`.

---

### Task 5: VERIFY ×2 — la porte rejouable, par les deux moteurs

**Files:**
- Modify: `scripts/test-parity-moteurs.sh` (phase 5)

**Interfaces:**
- Consumes: `ansible/promote-api-verify.yml` (le `--tags verify` du rôle),
  `labctl promote --action verify` (Task 2), `snapshot`/`parity_diff` (Task 4).

- [x] **Step 1:** sur l'état final (import labctl) :

```bash
say "phase 5 — VERIFY rejouable, par les DEUX moteurs, sans écrire"
ansible-playbook -i "$REPO/ansible/inventory.lab.ini" "$REPO/ansible/promote-api-verify.yml" \
  -e apim_promote_manifest="$WORK/parity.promote.yml" -e apim_ss_env=rec \
  -e apim_ss_api_base="$GW" -e apim_ss_data_base="$DP" \
  -e apim_ss_wm_user="$WM_USER" -e apim_ss_wm_password="$WM_PASS" \
  -e apim_ss_vault_addr="" > "$WORK/verify.ansible.log" 2>&1 \
  && grep -q "PROMOTE_CONFIRMED" "$WORK/verify.ansible.log" \
  && ok "V1 rôle : --tags verify rejoue PROMOTE_CONFIRMED" || ko "V1 …"
"$WORK/labctl" promote --manifest "$WORK/parity.promote.yml" --env rec \
  --action verify -f "$WORK/targets.yaml" > "$WORK/verify.labctl.log" 2>&1 \
  && grep -q "PROMOTE_CONFIRMED" "$WORK/verify.labctl.log" \
  && ok "V2 labctl : --action verify rejoue PROMOTE_CONFIRMED" || ko "V2 …"
snapshot "$WORK/snap-after-verify.json"
parity_diff "$WORK/snap-labctl.json" "$WORK/snap-after-verify.json" \
  && ok "V3 verify n'a RIEN écrit (snapshot identique)" || ko "V3 verify a modifié l'état"
```

- [x] **Step 2:** run partiel → V1-V3 verts. **Step 3:** commit
  `feat(g8): la porte se rejoue par les deux moteurs — verify ×2 sans écriture, snapshot inchangé`.

---

### Task 6: CONTRE-ÉPREUVES — deux mutations, deux rouges

**Files:**
- Modify: `scripts/test-parity-moteurs.sh` (phase 6)

- [x] **Step 1:** mutation labctl (copie + sed ANCRÉ + rebuild) :

```bash
say "phase 6a — MUTATION labctl : la parité doit rougir"
cp -R "$REPO/labctl" "$WORK/labctl-mut"
MUT='if spec.ScopeMapping.ExternalScope != "" || spec.ScopeMapping.AuthServerAlias != "" {'
grep -qF "$MUT" "$WORK/labctl-mut/cmd/labctl/promote.go" \
  || { ko "M0 motif de mutation introuvable — promote.go a changé, ré-ancrer"; }
python3 - "$WORK/labctl-mut/cmd/labctl/promote.go" <<PYEOF
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('''$MUT''', 'if false {', 1)
open(p, 'w').write(s)
PYEOF
( cd "$WORK/labctl-mut" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$WORK/labctl-mutbin" . )
wipe_target
engine_import labctl-mut > "$WORK/import.mut-labctl.log" 2>&1   # même archive, binaire muté
snapshot "$WORK/snap-mut-labctl.json"
if parity_diff "$WORK/snap-ansible.json" "$WORK/snap-mut-labctl.json"; then
  ko "M1 la parité N'A PAS rougi sur un labctl muté (elle ne prouve rien — motif F1)"
else
  jq -e '[.[]|select(.champ|startswith("scope"))]|length > 0' "$WORK/parity.diff.json" >/dev/null \
    && ok "M1 mutation labctl (scope sauté) → parité ROUGE, champ nommé" \
    || ko "M1 rouge, mais l'écart nommé n'est pas le scope muté"
fi
```

  (`engine_import` prend le cas `labctl-mut` → `"$WORK/labctl-mutbin"`, mêmes
  flags que `labctl`.)
- [x] **Step 2:** mutation rôle (copie de `ansible/` + `when: false` sur
  l'include scope) :

```bash
say "phase 6b — MUTATION rôle : l'autre sens doit rougir aussi"
cp -R "$REPO/ansible" "$WORK/ansible-mut"
IMP="$WORK/ansible-mut/roles/apim_promote_api/tasks/import.yml"
grep -qF 'when: "(apim_promote.scope_mapping | default({})) | length > 0"' "$IMP" \
  || ko "M2 motif de mutation rôle introuvable — import.yml a changé, ré-ancrer"
python3 - "$IMP" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('when: "(apim_promote.scope_mapping | default({})) | length > 0"',
              'when: false', 1)
open(p, 'w').write(s)
PYEOF
wipe_target
engine_import ansible-mut > "$WORK/import.mut-ansible.log" 2>&1  # playbook $WORK/ansible-mut/promote-api.yml
snapshot "$WORK/snap-mut-ansible.json"
if parity_diff "$WORK/snap-mut-ansible.json" "$WORK/snap-labctl.json"; then
  ko "M2 la parité N'A PAS rougi sur un rôle muté"
else
  ok "M2 mutation rôle (scope sauté) → parité ROUGE"
fi
# remise en état nominale : le trap purge ; l'état final du lab = assets retirés
```

- [x] **Step 3:** run partiel → M0-M2 verts (c.-à-d. les rouges attendus vus).
- [x] **Step 4:** commit
  `test(g8): contre-épreuves — un moteur muté fait rougir la parité, dans les deux sens`.

---

### Task 7: LA porte — run complet ×2 + `make lint-ci`

**Files:**
- Modify: `Makefile` (liste shellcheck [2/8] : ajouter
  `scripts/test-parity-moteurs.sh`)

- [x] **Step 1:** `shellcheck -x scripts/test-parity-moteurs.sh` propre ;
  ajouter le chemin à la liste `[2/8]` du Makefile (après
  `scripts/test-rollback-paliers.sh`, étiquette G2/G3/G4/G5/G6 → G2..G8).
- [x] **Step 2:** run COMPLET `bash scripts/test-parity-moteurs.sh` → X/0.
- [x] **Step 3:** re-run COMPLET (rejouabilité — le trap a purgé, le setup
  re-crée) → X/0, même X.
- [x] **Step 4:** `make lint-ci` → 8/8.
- [x] **Step 5:** commit `feat(g8): porte tenue — parité X/0 ×2, lint-ci vert`.

---

### Task 8: ADR-087, ENVIRONNEMENTS.md, GOAL, handoff, mémoire

**Files:**
- Create: `adr/adr-087-parite-des-moteurs.md`
- Modify: `ENVIRONNEMENTS.md` (§ « La parité des deux moteurs (G8) », après le § G7)
- Modify: `GOAL-cd-promotion-5-envs-2026-08-26.md` (encart FAIT sous § G8 +
  status ligne 4)
- Create: `HANDOFF-2026-08-27-G8-PARITE-DES-MOTEURS.md`
- Modify: mémoire `cd-promotion-5-envs.md` (+ index MEMORY.md), nouvelle
  mémoire `g8-parite-des-moteurs.md`

- [x] **Step 1:** ADR-087 : décision (le registre mécanique EST la définition
  de l'iso-sémantique), tableau de preuve (scores mesurés), registre HUMAIN
  complet — chaque ligne de `parity-ecarts.txt` avec sa mesure, PLUS les
  écarts de moteur hors état : digest sha256 (rôle+CI, jamais labctl), voie
  terminus ansible-only (G7), défaut `apim_ss_authoring_env` D0/D2,
  acquisition auth admin (secrets.yml vs targets.yaml), et tout écart
  découvert en Tasks 3-6.
- [x] **Step 2:** ENVIRONNEMENTS.md : comment rejouer la porte
  (`test-parity-moteurs.sh`, verify ×2), où vit le registre, quoi faire quand
  la parité rougit (mesurer → registre justifié OU réparer le moteur).
- [x] **Step 3:** GOAL § G8 : encart `> **FAIT le 2026-08-27**` avec les
  scores réels ; ligne de status : plus aucun jalon ouvert.
- [x] **Step 4:** handoff (portes, livrables, pièges mesurés, restes) ;
  mémoire mise à jour.
- [x] **Step 5:** commit `docs(g8): ADR-087 + parcours opérateur + GOAL soldé — G1..G8 faits`,
  puis push gitea (`git push gitea provision/probe-dev`, http.postBuffer si >1 Mo).

## Self-review

- Couverture spec : §3.1→T1-T2, §3.2→T3-T5, §3.3→T4, §3.4→T6, §3.5→T3+T8,
  §4.7→T7. OK.
- Les shapes /policies//policyActions sont explicitement « à mesurer, adapter,
  documenter » — pas de shape devinée en silence.
- Cohérence types : `engine_import` étendu aux cas `labctl-mut`/`ansible-mut`
  (T6) — défini comme extension du même dispatch que T3.
