package cmd

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/render"
)

// posture is the entry point of the PRODUCER chain into the posture engine
// (GOAL posture-par-exposition, jalon P2).
//
// WHY A COMMAND AND NOT A RE-IMPLEMENTATION. The producer chain is bash
// (scripts/api-request.sh) and Ansible (roles/apim_publish_api) — neither can
// import Go. Both need the same two answers `labctl apply` already computes:
// which posture actually governs this API, and is the one the demand declared
// a DOWNGRADE. Re-deriving that in Jinja would re-create, on the two axes at
// once, the hand-copied vocabulary P1 spent a jalon removing — and the exposure
// axis is precisely the one no naive comparison gets right (it is not a ladder;
// see render.Weaker). So the chain ASKS, it does not re-decide.
//
// This command runs the SAME resolveCentralClassification the apply-side gate
// runs, on a ContractSubset built from flags instead of from an api.yaml. The
// codes it can fail with are therefore the codes CI already knows:
// CLASSIFICATION_UNGOVERNED, CLASSIFICATION_SPOOFED, INTEGRITY_INCONSISTENT.
//
// Read-only, offline, no gateway, no Vault: it is meant to run BEFORE anything
// is written — at demand time (the PR plan) and again at publish time (the
// role, before its first gateway call).
var postureCmd = &cobra.Command{
	Use:   "posture",
	Short: "Resolve the GOVERNED posture of an API (central registry wins over the demand) — ADR-092, jalon P2",
	Long: "posture answers, for one API and one non-editable project identity: which (classification, " +
		"exposure) actually governs it, which NAMED truth-table cell that is, and which policy bundle the " +
		"gateway must therefore carry.\n\n" +
		"AUTHORITY: with --classification-source (or LABCTL_CLASSIFICATION_SOURCE) the answer comes from the " +
		"CENTRAL registry, keyed on (--project, --api) — the project's own declaration is only a reference " +
		"that must not be WEAKER. A weaker declaration is refused [CLASSIFICATION_SPOOFED]; an API absent " +
		"from the registry is refused [CLASSIFICATION_UNGOVERNED]; a stronger one is accepted and reported " +
		"as over-provisioning. Without a source the answer is the DEMAND's own values and says so " +
		"(source=demande) — it is the CALLING chain's job to make the source mandatory.\n\n" +
		"SPLIT (P4): the derived bundle is reported twice over — `common_policies` is the half ONE global " +
		"policy carries for every API of the cell (named `global_policy`, with the cell's governed quota), " +
		"and `per_api_policies` is the half that stays on the API itself.\n\n" +
		"ENTRY PROTOCOL (P5): `entry_protocol` is the value the platform pins on the API's own transport " +
		"stage so the clear-text call is refused by the API itself, whatever listener carried it. It is " +
		"derived from the PER-API half, so it follows the split rather than restating it.\n\n" +
		"CALLER IDENTITY (P6): `caller_identity` lists the identification dimensions the platform " +
		"REQUIRES on the API's own IAM stage, so an unidentified caller is refused by the API itself. " +
		"Same half, same rule: it is derived from `per_api_policies`, never restated.\n\n" +
		"Both the retained and the declared posture are printed, so a build log shows which one won.",
	Args: cobra.NoArgs,
	RunE: runPosture,
}

var (
	// postureAPIFlag is the lookup key's api half; the owner half is --project.
	postureAPIFlag string
	// postureTenantFlag is the tenant the caller CLAIMS, when it claims one.
	// The producer manifest carries no tenant (the team is its scoping unit), so
	// this stays optional — see the tenantClaimed argument below.
	postureTenantFlag string
	// The posture the demand declares. Compared against the registry, never
	// trusted over it.
	postureClassificationFlag string
	postureExposureFlag       string
	// postureCellsFlag prints the truth table itself instead of resolving one
	// API — what the day-0 bootstrap play iterates over (P4).
	postureCellsFlag bool
)

func init() {
	postureCmd.Flags().StringVar(&postureAPIFlag, "api", "",
		"API name — the 'api' half of the central registry's (owner, api) lookup key (required)")
	postureCmd.Flags().StringVar(&postureTenantFlag, "tenant", "",
		"tenant CLAIMED by the demand; when given it must match the registry [CLASSIFICATION_SPOOFED]. Omit when the demand claims none — the resolved tenant is reported either way")
	postureCmd.Flags().StringVar(&postureClassificationFlag, "declared-classification", "",
		"integrity classification the demand declares (VH|H|M) — a reference, never the authority")
	postureCmd.Flags().StringVar(&postureExposureFlag, "declared-exposure", "",
		"exposure the demand declares (internal|external|internet); empty defaults to internal")
	postureCmd.Flags().StringVar(&classificationSourceFlag, "classification-source", "",
		"central integrity-classification registry (ADR-076 A5); default env LABCTL_CLASSIFICATION_SOURCE. When set, the posture is AUTHORITATIVE from this registry")
	postureCmd.Flags().StringVar(&projectFlag, "project", "",
		"non-editable project identity for the central lookup; default env LABCTL_PROJECT (the pipeline's PROJECT_NAME / the chain's team)")
	postureCmd.Flags().BoolVar(&postureCellsFlag, "cells", false,
		"print the truth table's NAMED cells with their common bundle, governed quota, global-policy name and member sentinel, instead of resolving one API (jalon P4 — what the bootstrap play iterates over). Offline, no registry, no --api")
	rootCmd.AddCommand(postureCmd)
}

// orNone renders an empty derived value as an explicit "(aucun)" in the human
// output. An empty field there would read as a rendering bug rather than as the
// answer it is — and for the entry protocol the difference matters: "nothing to
// pin" and "the value did not make it through" call for opposite reactions.
func orNone(s string) string {
	if s == "" {
		return "(aucun)"
	}
	return s
}

func runPosture(cmd *cobra.Command, _ []string) error {
	if postureCellsFlag {
		return runPostureCells(cmd)
	}
	if postureAPIFlag == "" {
		return fmt.Errorf("--api requis : c'est la clé de recherche au registre central (moitié 'api' du couple (owner, api))")
	}

	// The DEMAND, kept verbatim: it is echoed back next to the retained value so
	// a reader of the build log sees both, never just the winner.
	declaredClass := postureClassificationFlag
	declaredExposure := render.EffectiveExposure(postureExposureFlag)

	c := render.ContractSubset{
		Name:           postureAPIFlag,
		TenantID:       postureTenantFlag,
		Classification: postureClassificationFlag,
		Exposure:       postureExposureFlag,
	}

	source := "demande"
	if classificationSource() != "" {
		source = "central"
	}

	// THE shared mechanism — same function, same codes, same anti-spoof anchor
	// as `labctl apply`. tenantClaimed=false when the caller claims no tenant:
	// there is then nothing to lie about, and the (owner, api) key is what
	// actually anchors the lookup.
	warnings, err := resolveCentralClassification(&c, postureTenantFlag != "")
	if err != nil {
		return err
	}

	res, err := render.Derive(c.Input())
	if err != nil {
		// Same code as both existing gates: a posture that derives no bundle
		// must not reach a gateway, whichever door it came through.
		return fmt.Errorf("[%s] %s: %w", render.CodeIntegrityInconsistent, c.Name, err)
	}

	effExposure := render.EffectiveExposure(c.Exposure)
	out := cmd.OutOrStdout()

	if outputFlag == "json" {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(map[string]any{
			"name":              c.Name,
			"tenant":            c.TenantID,
			"classification":    c.Classification,
			"exposure":          effExposure,
			"bundle":            res.Bundle,
			"authn":             res.Authn,
			"required_policies": res.RequiredPolicies,
			// P4 (ADR-094): the SPLIT of the bundle, and the object that
			// carries the common half. `common_policies` is what ONE global
			// policy enforces for every API of the cell; `per_api_policies` is
			// what stays on the API. `global_policy` and `member_sentinel` are
			// FINISHED strings for the same reason `tag` is: the bootstrap play
			// and the publish role write them verbatim and compose nothing.
			"common_policies":  res.CommonPolicies,
			"per_api_policies": res.PerAPIPolicies,
			"quota": map[string]any{
				"requests": res.Quota.Requests,
				"interval": res.Quota.Interval,
				"unit":     res.Quota.Unit,
			},
			"global_policy":   render.PosturePolicyName(res.Bundle),
			"policy_prefix":   render.PosturePolicyPrefix,
			"member_sentinel": render.PostureMemberSentinel,
			// P5 (ADR-095): the entry protocol the platform pins on the API's
			// own transport stage. A FINISHED value in the PRODUCT's
			// vocabulary, for the same reason `tag` and `global_policy` are:
			// the role writes it verbatim into the entryProtocolPolicy action
			// and derives nothing. Empty means "this bundle asks for no
			// protocol restriction here" — the role must then pose NOTHING,
			// which is not the same as posing a default.
			"entry_protocol": res.EntryProtocol,
			// The identification dimensions the platform must REQUIRE on the
			// API's IAM stage (jalon P6, ADR-096). Same contract as
			// entry_protocol: finished vocabulary of the product, written
			// verbatim by the role. An EMPTY list means "this cell requires no
			// dimension of its own" — the role poses nothing, which is not the
			// same as posing "anonymous is fine".
			"caller_identity": res.CallerIdentity,
			// The tag the platform must pose on the gateway object, and the
			// namespace it owns there (jalon P3, ADR-093). Both are FINISHED
			// strings: the Ansible role writes `tag` verbatim and strips every
			// existing tag matching `tag_prefix`, so no caller ever composes a
			// posture tag — the same "ask, do not re-derive" rule P2 set.
			"tag":                     render.PostureTag(res.Bundle),
			"tag_prefix":              render.PostureTagPrefix,
			"source":                  source,
			"declared_classification": declaredClass,
			"declared_exposure":       declaredExposure,
			"warnings":                warnings,
		})
	}

	// ONE greppable line per posture, in the shape `labctl render` already uses,
	// plus the two things P2 exists to make visible: where the value came from,
	// and what the demand had asked for.
	fmt.Fprintf(out, "posture %s [classification=%s exposure=%s] -> bundle=%s authn=%s source=%s\n",
		c.Name, c.Classification, effExposure, res.Bundle, res.Authn, source)
	fmt.Fprintf(out, "required_policies: %s\n", strings.Join(res.RequiredPolicies, ", "))
	fmt.Fprintf(out, "common_policies: %s\n", strings.Join(res.CommonPolicies, ", "))
	fmt.Fprintf(out, "per_api_policies: %s\n", strings.Join(res.PerAPIPolicies, ", "))
	fmt.Fprintf(out, "global_policy: %s [quota %d/%d %s]\n",
		render.PosturePolicyName(res.Bundle), res.Quota.Requests, res.Quota.Interval, res.Quota.Unit)
	fmt.Fprintf(out, "tag: %s\n", render.PostureTag(res.Bundle))
	fmt.Fprintf(out, "entry_protocol: %s\n", orNone(res.EntryProtocol))
	fmt.Fprintf(out, "caller_identity: %s\n", orNone(strings.Join(res.CallerIdentity, ", ")))
	fmt.Fprintf(out, "declared: classification=%s exposure=%s\n", declaredClass, declaredExposure)
	for _, w := range warnings {
		fmt.Fprintf(out, "⚠ %s\n", w)
	}
	return nil
}

// runPostureCells prints the truth table's cells — the bootstrap side of P4.
//
// WHY THE PLAY DOES NOT KEEP ITS OWN LIST. The day-0 play creates one global
// policy per NAMED cell. A list of cells written in YAML would be the fifth
// hand-copy of the vocabulary P1 spent a jalon removing, and the first cell
// added to the table without a matching line would simply have no object —
// which is to say APIs of that cell would silently carry no common bundle at
// all. So the play ASKS, exactly as the publish role does.
//
// Every string here is FINISHED: the policy name, the sentinel, the quota's
// unit in the product's own vocabulary. The play concatenates nothing.
func runPostureCells(cmd *cobra.Command) error {
	type cell struct {
		Bundle         string   `json:"bundle"`
		GlobalPolicy   string   `json:"global_policy"`
		CommonPolicies []string `json:"common_policies"`
		PerAPIPolicies []string `json:"per_api_policies"`
		Quota          struct {
			Requests int    `json:"requests"`
			Interval int    `json:"interval"`
			Unit     string `json:"unit"`
		} `json:"quota"`
		Tag string `json:"tag"`
	}

	// Reconstructed by DERIVING, never by reading the tables directly: a cell
	// that no input can reach must not get an object either.
	seen := map[string]cell{}
	add := func(in render.Input) error {
		res, err := render.Derive(in)
		if err != nil {
			return err
		}
		c := cell{Bundle: res.Bundle, GlobalPolicy: render.PosturePolicyName(res.Bundle),
			CommonPolicies: res.CommonPolicies, PerAPIPolicies: res.PerAPIPolicies,
			Tag: render.PostureTag(res.Bundle)}
		c.Quota.Requests, c.Quota.Interval, c.Quota.Unit = res.Quota.Requests, res.Quota.Interval, res.Quota.Unit
		seen[res.Bundle] = c
		return nil
	}
	for _, cl := range render.Classifications() {
		for _, ex := range render.Exposures() {
			if err := add(render.Input{Classification: cl, Exposure: ex}); err != nil {
				return err
			}
		}
	}
	if err := add(render.Input{Classification: render.ClassificationM, Exposure: render.ExposureInternal,
		Tags: []string{render.AuthExceptionApiKey}}); err != nil {
		return err
	}

	// render.Cells() is the independent list; if the two disagree, a cell has a
	// quota nobody can reach or is reachable with no quota — fail-closed rather
	// than bootstrap a table that does not match the engine.
	cells := make([]cell, 0, len(seen))
	for _, b := range render.Cells() {
		c, ok := seen[b]
		if !ok {
			return fmt.Errorf("[%s] la cellule %q est gouvernée mais n'est dérivable par aucune entrée",
				render.CodeIntegrityInconsistent, b)
		}
		cells = append(cells, c)
	}
	if len(cells) != len(seen) {
		return fmt.Errorf("[%s] %d cellules dérivables pour %d gouvernées : la table des quotas et la table des bouquets divergent",
			render.CodeIntegrityInconsistent, len(seen), len(cells))
	}

	out := cmd.OutOrStdout()
	if outputFlag == "json" {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(map[string]any{
			"cells":           cells,
			"member_sentinel": render.PostureMemberSentinel,
			"policy_prefix":   render.PosturePolicyPrefix,
		})
	}
	fmt.Fprintf(out, "member_sentinel: %s\n", render.PostureMemberSentinel)
	for _, c := range cells {
		fmt.Fprintf(out, "%s -> %s [quota %d/%d %s] common=%s per-api=%s\n",
			c.Bundle, c.GlobalPolicy, c.Quota.Requests, c.Quota.Interval, c.Quota.Unit,
			strings.Join(c.CommonPolicies, "+"), strings.Join(c.PerAPIPolicies, "+"))
	}
	return nil
}
