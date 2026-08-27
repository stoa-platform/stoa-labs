// promote.go — the ADR-079 archive-promotion verb, driven by the SAME
// .promote.yml manifest as the apim_promote_api Ansible role (one manifest,
// two engines — the roles are the client deliverable, this command keeps the
// lab engine iso-semantic).
//
//	export: labctl promote --manifest clients/x/apis/foo.promote.yml --action export
//	import: labctl promote --manifest clients/x/apis/foo.promote.yml --env rec
//
// Semantics (all spike-pinned, ADR-079):
//   - the ARCHIVE is the deployment unit: guid-stable, sanitized (no Alias/,
//     no PassmanData/, ExportReport dropped, acdl purged), routing re-pointed
//     onto ${backend_alias} so the artifact never carries an env's backend;
//   - ALIAS-FIRST: per-env values (backend URL, credentials from Vault,
//     generic aliases) are converged BEFORE the import, by PUT only (never
//     delete/recreate — the ${alias} binding resolves name->id at deploy);
//   - import overwrites apis,policies,policyactions — NEVER aliases nor "*";
//   - read-back fail-closed: every row Success, the API row IS the pinned
//     guid (iso), the API is ACTIVE after import (isActive trap), optional
//     data-plane smoke;
//   - the per-API scope mapping (client model, "<name>:<version>") is
//     re-converged by REST after the import — scope mappings do NOT travel in
//     archives (proven both ways).
package cmd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"
	sigsyaml "sigs.k8s.io/yaml"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter/webmethods"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/vault"
)

var (
	promoteManifestFlag string
	promoteActionFlag   string
	promoteEnvFlag      string
	promoteTargetFlag   string
	promoteArchiveFlag  string
)

var promoteCmd = &cobra.Command{
	Use:   "promote",
	Short: "Promote an API by guid-stable archive (ADR-079): sanitized export / 0-downtime import",
	Long: "promote drives the archive verb the client delivery uses (apim_promote_api role): " +
		"export produces a sanitized, portable, secret-free archive and prints the id-map to pin; " +
		"import converges the env-local aliases first (backend URL, Vault credentials), uploads the " +
		"archive with a scoped overwrite (never aliases), and fail-closed verifies guid-iso + active " +
		"+ the per-API scope mapping. The API is NEVER deactivated.",
	RunE: runPromote,
}

func init() {
	promoteCmd.Flags().StringVar(&promoteManifestFlag, "manifest", "", "path to the .promote.yml manifest (apim_promote root key) — required")
	promoteCmd.Flags().StringVar(&promoteActionFlag, "action", "import", "export | import")
	promoteCmd.Flags().StringVar(&promoteEnvFlag, "env", "", "environment key for the per_env merge (required when the manifest declares per_env)")
	promoteCmd.Flags().StringVar(&promoteTargetFlag, "target", "", "targets.yaml entry to drive (default: the first webmethods target)")
	promoteCmd.Flags().StringVar(&promoteArchiveFlag, "archive", "", "absolute path of the artifact fetched by the CI (overrides the manifest's archive field); required when the manifest's archive is a Jinja template ({{ ... }}) only Ansible can render")
	rootCmd.AddCommand(promoteCmd)
}

// promoteSpec mirrors the Ansible role's apim_promote manifest block (same
// file, same keys — sigs.k8s.io/yaml maps the snake_case via JSON tags).
type promoteSpec struct {
	Name         string               `json:"name"`
	Version      string               `json:"version"`
	GUID         string               `json:"guid"`
	Archive      string               `json:"archive"`
	Overwrite    string               `json:"overwrite"`
	BackendAlias promoteBackendAlias  `json:"backend_alias"`
	CredAlias    promoteCredAlias     `json:"cred_alias"`
	Aliases      []promoteAliasEntry  `json:"aliases"`
	ScopeMapping promoteScopeMapping  `json:"scope_mapping"`
	SmokePath    string               `json:"smoke_path"`
	PerEnv       map[string]yamlBlock `json:"per_env"`
}

type promoteBackendAlias struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

type promoteCredAlias struct {
	Name     string `json:"name"`
	AuthType string `json:"auth_type"`
	Domain   string `json:"domain"`
	VaultSub string `json:"vault_sub"`
}

type promoteAliasEntry struct {
	Name   string         `json:"name"`
	Record map[string]any `json:"record"`
}

type promoteScopeMapping struct {
	Name            string `json:"name"`
	ExternalScope   string `json:"external_scope"`
	AuthServerAlias string `json:"auth_server_alias"`
	Audience        string `json:"audience"`
}

// yamlBlock keeps a per_env override as raw structure for the recursive merge.
type yamlBlock map[string]any

// loadPromoteManifest parses the manifest and resolves the EFFECTIVE spec:
// root (without per_env) ⊕(recursive) per_env[env]. Fail closed exactly like
// the Ansible role: a manifest with per_env REQUIRES a declared, known env —
// otherwise we would import an API routed at the WRONG env's backend.
func loadPromoteManifest(path, env string) (promoteSpec, error) {
	var spec promoteSpec
	raw, err := os.ReadFile(path)
	if err != nil {
		return spec, fmt.Errorf("promote: read manifest: %w", err)
	}
	var doc struct {
		APIMPromote map[string]any `json:"apim_promote"`
	}
	if err := sigsyaml.Unmarshal(raw, &doc); err != nil {
		return spec, fmt.Errorf("promote: parse manifest: %w", err)
	}
	if len(doc.APIMPromote) == 0 {
		return spec, fmt.Errorf("promote: manifest %s has no apim_promote block", path)
	}
	root := doc.APIMPromote
	perEnvRaw, _ := root["per_env"].(map[string]any)
	delete(root, "per_env")
	if len(perEnvRaw) > 0 {
		if env == "" {
			return spec, fmt.Errorf("promote: ENV_UNDEFINED — the manifest declares per_env=%v but --env is empty", mapKeys(perEnvRaw))
		}
		over, ok := perEnvRaw[env].(map[string]any)
		if !ok {
			return spec, fmt.Errorf("promote: ENV_UNDEFINED — env %q is not in per_env=%v (refusing to promote with another env's alias values)", env, mapKeys(perEnvRaw))
		}
		deepMerge(root, over)
	}
	// map -> struct via JSON (sigs yaml already normalised everything to JSON types)
	buf, err := json.Marshal(root)
	if err != nil {
		return spec, fmt.Errorf("promote: normalise manifest: %w", err)
	}
	if err := json.Unmarshal(buf, &spec); err != nil {
		return spec, fmt.Errorf("promote: decode manifest: %w", err)
	}
	if spec.Overwrite == "" {
		spec.Overwrite = webmethods.DefaultOverwrite
	}
	return spec, nil
}

// applyArchiveOverride pins the CI-fetched artifact path over the manifest's
// archive field. The real manifests carry a Jinja expression only Ansible can
// render (measured: clients/_example/apis/accounts-read.promote.yml) — reading
// it raw would always fail, so a templated path WITHOUT an override is refused
// by name instead of surfacing as a confusing open() error.
func applyArchiveOverride(spec *promoteSpec, override string) error {
	if override != "" {
		if !strings.HasPrefix(override, "/") {
			return fmt.Errorf("promote: ARCHIVE_PATH_RELATIVE — --archive %q must be absolute", override)
		}
		spec.Archive = override
		return nil
	}
	if strings.Contains(spec.Archive, "{{") {
		return fmt.Errorf("promote: ARCHIVE_PATH_TEMPLATED — the manifest carries %q (a template only Ansible renders); pass --archive with the fetched artifact", spec.Archive)
	}
	return nil
}

// deepMerge merges src into dst recursively (maps merge, scalars/lists replace)
// — the same combine(recursive=True) the Ansible resolve-env uses.
func deepMerge(dst, src map[string]any) {
	for k, v := range src {
		if sv, ok := v.(map[string]any); ok {
			if dv, ok := dst[k].(map[string]any); ok {
				deepMerge(dv, sv)
				continue
			}
		}
		dst[k] = v
	}
}

func mapKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// promoteAdapter resolves the webMethods driver from targets.yaml.
func promoteAdapter(tf *targets.File) (*webmethods.Adapter, string, error) {
	for _, t := range tf.Targets {
		if promoteTargetFlag != "" && t.Name != promoteTargetFlag {
			continue
		}
		if t.Type != "webmethods" {
			if promoteTargetFlag != "" {
				return nil, "", fmt.Errorf("promote: target %q is type %q — archive promotion is webMethods-only", t.Name, t.Type)
			}
			continue
		}
		ad, err := adapter.New(t.ToConfig())
		if err != nil {
			return nil, "", fmt.Errorf("promote: build adapter for %q: %w", t.Name, err)
		}
		wm, ok := ad.(*webmethods.Adapter)
		if !ok {
			return nil, "", fmt.Errorf("promote: target %q did not build a webMethods driver", t.Name)
		}
		return wm, t.Name, nil
	}
	return nil, "", fmt.Errorf("promote: no webmethods target found in %s (use --target)", fileFlag)
}

func runPromote(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	out := cmd.OutOrStdout()
	if promoteManifestFlag == "" {
		return fmt.Errorf("promote: --manifest is required")
	}
	if promoteActionFlag != "export" && promoteActionFlag != "import" {
		return fmt.Errorf("promote: --action must be export or import (got %q)", promoteActionFlag)
	}
	spec, err := loadPromoteManifest(promoteManifestFlag, promoteEnvFlag)
	if err != nil {
		return err
	}
	if err := applyArchiveOverride(&spec, promoteArchiveFlag); err != nil {
		return err
	}
	if spec.Archive == "" {
		return fmt.Errorf("promote: manifest needs archive (the artifact path)")
	}
	tf, err := targets.Load(fileFlag)
	if err != nil {
		return err
	}
	wm, targetName, err := promoteAdapter(tf)
	if err != nil {
		return err
	}

	if promoteActionFlag == "export" {
		return runPromoteExport(ctx, out, wm, targetName, spec)
	}
	return runPromoteImport(ctx, out, wm, targetName, spec)
}

func runPromoteExport(ctx context.Context, out interface{ Write([]byte) (int, error) }, wm *webmethods.Adapter, targetName string, spec promoteSpec) error {
	guid := spec.GUID
	if guid == "" {
		// id-map not pinned yet: resolve by name+version, then TELL the user to pin.
		apis, err := wm.List(ctx)
		if err != nil {
			return err
		}
		for _, api := range apis {
			if api.Name == spec.Name && api.Version == spec.Version {
				guid = api.APIID
				break
			}
		}
		if guid == "" {
			return fmt.Errorf("promote: EXPORT_REFUSED — %s v%s not found on %s (no pinned guid, no name+version match)", spec.Name, spec.Version, targetName)
		}
	}
	// isActive trap, export side: refuse to build an archive that would
	// deactivate on import.
	if _, err := wm.VerifyAPIActive(ctx, guid); err != nil {
		return fmt.Errorf("promote: EXPORT_REFUSED — %w", err)
	}
	raw, err := wm.ExportArchive(ctx, guid)
	if err != nil {
		return err
	}
	clean, rep, err := webmethods.SanitizeArchive(raw, spec.BackendAlias.Name)
	if err != nil {
		return err
	}
	if err := os.WriteFile(spec.Archive, clean, 0o644); err != nil {
		return fmt.Errorf("promote: write archive: %w", err)
	}
	idmap, _ := json.MarshalIndent(rep.APIs, "  ", "  ")
	fmt.Fprintf(out, "EXPORT_CONFIRMED: %s (stripped %d, routing rewritten %d)\n  id-map to pin in the manifest:\n  %s\n",
		spec.Archive, len(rep.Stripped), len(rep.RoutingRewritten), idmap)
	return nil
}

func runPromoteImport(ctx context.Context, out interface{ Write([]byte) (int, error) }, wm *webmethods.Adapter, targetName string, spec promoteSpec) error {
	if spec.GUID == "" {
		return fmt.Errorf("promote: IMPORT_REFUSED — guid (the pinned id-map) is required: without it there is no cross-gateway iso proof (ADR-079)")
	}
	zipBytes, err := os.ReadFile(spec.Archive)
	if err != nil {
		return fmt.Errorf("promote: read archive: %w", err)
	}

	// ---- alias-first: the env-local values, BEFORE the API ----------------
	if spec.BackendAlias.Name != "" {
		if spec.BackendAlias.URL == "" {
			return fmt.Errorf("promote: ALIAS_UNDEFINED — backend_alias %q has no url for env %q (declare it under per_env)", spec.BackendAlias.Name, promoteEnvFlag)
		}
		if err := wm.EnsureEndpointAliasValue(ctx, spec.BackendAlias.Name, spec.BackendAlias.URL); err != nil {
			return err
		}
	}
	if spec.CredAlias.Name != "" {
		if spec.CredAlias.VaultSub == "" {
			return fmt.Errorf("promote: CRED_UNDEFINED — cred_alias %q needs vault_sub (backend creds live in Vault, never in Git or the archive)", spec.CredAlias.Name)
		}
		vc, ok := vault.FromEnv()
		if !ok {
			return fmt.Errorf("promote: CRED_UNDEFINED — cred_alias %q needs VAULT_ADDR (backend creds are Vault-resolved)", spec.CredAlias.Name)
		}
		kv, err := vc.ReadKV(ctx, spec.CredAlias.VaultSub)
		if err != nil {
			return err
		}
		if kv == nil || kv["username"] == "" || kv["password"] == "" {
			return fmt.Errorf("promote: CRED_UNDEFINED — vault %s must carry username+password", spec.CredAlias.VaultSub)
		}
		domain := kv["domain"]
		if domain == "" {
			domain = spec.CredAlias.Domain
		}
		if err := wm.EnsureCredentialAliasValue(ctx, spec.CredAlias.Name, spec.CredAlias.AuthType,
			kv["username"], base64.StdEncoding.EncodeToString([]byte(kv["password"])), domain); err != nil {
			return err
		}
	}
	for _, ga := range spec.Aliases {
		if err := wm.EnsureGenericAlias(ctx, ga.Name, ga.Record); err != nil {
			return err
		}
	}

	// ---- the archive itself (taint check + scoped overwrite inside) -------
	rows, err := wm.ImportArchive(ctx, zipBytes, spec.Overwrite)
	if err != nil {
		return err
	}
	guidSeen := false
	for _, r := range rows {
		if r.Type == "API" && r.ID == spec.GUID {
			guidSeen = true
			break
		}
	}
	if !guidSeen {
		return fmt.Errorf("promote: GUID_MISMATCH — the archive does not carry API guid=%s (manifest id-map and artifact diverge)", spec.GUID)
	}
	rec, err := wm.VerifyAPIActive(ctx, spec.GUID)
	if err != nil {
		return err
	}

	// ---- per-API scope mapping (REST — does not travel in archives) -------
	if spec.ScopeMapping.ExternalScope != "" || spec.ScopeMapping.AuthServerAlias != "" {
		name := spec.ScopeMapping.Name
		if name == "" {
			name = spec.Name + ":" + spec.Version
		}
		if err := wm.EnsureScopeMappingPerAPI(ctx, name, spec.ScopeMapping.AuthServerAlias,
			spec.ScopeMapping.ExternalScope, spec.ScopeMapping.Audience, spec.GUID); err != nil {
			return err
		}
	}
	if spec.SmokePath != "" {
		if err := wm.InvokeSmoke(ctx, spec.SmokePath); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "PROMOTE_CONFIRMED: %s v%s guid=%s active on %s (env %q, %d assets)\n",
		rec.APIName, rec.APIVersion, spec.GUID, targetName, promoteEnvFlag, len(rows))
	return nil
}
