package cmd

import (
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/cli"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/keycloak"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/openapi"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/output"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

// credentialsFile is where `labctl subscribe` writes the FULL synthetic
// credentials (mode 0600), so secrets never have to be echoed on stdout.
const credentialsFile = "labctl-credentials.txt"

// ensureClient is the Keycloak client-provisioning step, indirected through a
// package var so the dispatch/aggregation logic can be unit-tested without a
// live Keycloak. Production always uses keycloak.EnsureClient.
var ensureClient = keycloak.EnsureClient

// ensureConsumerAuth converges the Keycloak-side OAuth2 enforcement inputs
// (audience mapper + default client scope) on the consumer client. Indirected
// for the same testability reason as ensureClient.
var ensureConsumerAuth = keycloak.EnsureConsumerAuth

var subscribeCmd = &cobra.Command{
	Use:   "subscribe",
	Short: "Provision a consumer on every gateway, tied to one Keycloak OAuth client",
	Long: "subscribe mints a confidential OAuth client in Keycloak (Oracle-master via the broker), " +
		"then provisions a consumer/application on every gateway bound to that identity — self-service " +
		"in one command, across heterogeneous runtimes.",
	RunE: runSubscribe,
}

func init() {
	rootCmd.AddCommand(subscribeCmd)
}

type consumerOutcome struct {
	name string
	typ  string
	res  *adapter.ConsumerResult
	err  error
}

// consumerAuthFromTargets resolves the (audience, scope) the Keycloak consumer
// must carry from the targets' inboundAuth blocks. The consumer is ONE Keycloak
// client across all gateways, so every target that pins an audience must pin the
// SAME (audience, scope) pair — the last one wins, which is correct only when
// they agree; divergence would be a manifest bug, but since Load already
// defaults clientId from the same keycloak block, the PoC keeps a single OAuth2
// target (webMethods). ok=false when no target asks for the OAuth2 path.
func consumerAuthFromTargets(tf *targets.File) (audience, scope string, ok bool) {
	for _, t := range tf.Targets {
		if t.InboundAuth != nil && t.InboundAuth.Audience != "" {
			audience, scope, ok = t.InboundAuth.Audience, t.InboundAuth.Scope, true
		}
	}
	return audience, scope, ok
}

func runSubscribe(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	format, err := output.ParseFormat(outputFlag)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	// In json mode stdout must carry the JSON document ONLY; every human
	// progress line moves to stderr. In table mode log == out, so the rendering
	// is byte-identical to the historical output.
	log := out
	if format == output.FormatJSON {
		log = cmd.ErrOrStderr()
	}

	tf, err := loadResolvedTargets(ctx, fileFlag)
	if err != nil {
		return err
	}
	api, err := openapi.Load(tf.Contract, tf.Name, tf.BackendURL)
	if err != nil {
		return err
	}
	if tf.Keycloak.URL == "" || tf.Keycloak.ConsumerClientID == "" {
		return fmt.Errorf("targets %s: keycloak.url and keycloak.consumerClientId are required for subscribe", fileFlag)
	}

	// 1) Mint the out-of-band OAuth client FIRST — adapters consume its creds.
	fmt.Fprintf(log, "Minting Keycloak client %q in realm %q…\n", tf.Keycloak.ConsumerClientID, tf.Keycloak.Realm)
	clientID, clientSecret, err := ensureClient(ctx, keycloak.Config{
		URL:           tf.Keycloak.URL,
		Realm:         tf.Keycloak.Realm,
		AdminUser:     tf.Keycloak.Admin.Username,
		AdminPassword: tf.Keycloak.Admin.Password,
		ClientID:      tf.Keycloak.ConsumerClientID,
		ClientSecret:  tf.Keycloak.ConsumerClientSecret,
	})
	if err != nil {
		return fmt.Errorf("keycloak: %w", err)
	}
	// SECURITY: never print secret material (not even a prefix) on stdout — it
	// would leak into the terminal/CI logs/scrollback. Confirm acquisition only;
	// the full secret is written to the 0600 credentials file below.
	fmt.Fprintf(log, "  %s client %s ready (secret acquired)\n\n", cli.OK, clientID)

	// 1b) OAuth2 path: converge the Keycloak-side enforcement inputs on the
	// consumer client — the audience mapper (aud=<audience>) and the default
	// client scope (<scope>) the gateway barrier requires. Projected from the
	// targets' inboundAuth (audience+scope); no-op when no target asks for the
	// OAuth2 path. Runs BEFORE gateway provisioning so the very first token a
	// consumer mints already satisfies the barrier the adapters install.
	if audience, scope, ok := consumerAuthFromTargets(tf); ok {
		fmt.Fprintf(log, "Converging Keycloak consumer auth (aud=%q, scope=%q)…\n", audience, scope)
		if err := ensureConsumerAuth(ctx, keycloak.ConsumerAuthConfig{
			Config: keycloak.Config{
				URL:           tf.Keycloak.URL,
				Realm:         tf.Keycloak.Realm,
				AdminUser:     tf.Keycloak.Admin.Username,
				AdminPassword: tf.Keycloak.Admin.Password,
				ClientID:      tf.Keycloak.ConsumerClientID,
			},
			Audience: audience,
			Scope:    scope,
		}); err != nil {
			return fmt.Errorf("keycloak consumer auth: %w", err)
		}
		fmt.Fprintf(log, "  %s audience mapper + default scope ready\n\n", cli.OK)
	}

	// 2) Provision the consumer on every gateway, bound to that identity.
	outcomes := make([]consumerOutcome, 0, len(tf.Targets))
	for _, t := range tf.Targets {
		oc := consumerOutcome{name: t.Name, typ: t.Type}
		ad, err := adapter.New(t.ToConfig())
		if err != nil {
			oc.err = err
			outcomes = append(outcomes, oc)
			continue
		}
		spec := &adapter.ConsumerSpec{
			Name:             tf.Keycloak.ConsumerClientID,
			ClientID:         clientID,
			ClientSecret:     clientSecret,
			AuthType:         t.ConsumerAuth,
			ThrottlingPolicy: "Unlimited",
		}
		// Partner onboarding (ADR-071): project the declared partner identifiers
		// (custom token, IP allowlist, public certificate) onto adapters that
		// model them (webMethods). Absent block => fields stay zero => the
		// consumer keeps its current behavior on every gateway.
		if tf.Partner != nil {
			spec.TokenIdentifiers = tf.Partner.TokenIdentifiers
			spec.IPAllowlist = tf.Partner.IPAllowlist
			spec.PublicCertRef = tf.Partner.PublicCertRef
		}
		res, err := ad.CreateConsumer(ctx, api, spec)
		oc.res, oc.err = res, err
		outcomes = append(outcomes, oc)
	}

	// Persist FULL credentials to a 0600 file BEFORE rendering, so the machine
	// report can reference the path and nothing secret ever hits stdout.
	credPath, credErr := writeCredentials(clientID, clientSecret, outcomes)

	// 3) Report — stdout shows ids + MASKED credentials only (table) or the
	//    secret-free JSON document; the full secret material lives in the 0600
	//    credentials file only.
	failed := 0
	for _, o := range outcomes {
		if o.err != nil || o.res == nil {
			failed++
		}
	}
	if format == output.FormatJSON {
		if err := output.WriteJSON(out, consumerReport(clientID, credPath, outcomes)); err != nil {
			return err
		}
	} else {
		rows := make([][]string, 0, len(outcomes))
		for _, o := range outcomes {
			if o.err != nil || o.res == nil {
				rows = append(rows, []string{o.name, cli.FAIL, "", cli.Truncate(errStr(o.err), 50)})
				continue
			}
			rows = append(rows, []string{o.name, cli.OK, o.res.ConsumerID, maskCredential(o.res)})
		}
		cli.Table(out, []string{"GATEWAY", "STATUS", "CONSUMER ID", "CREDENTIAL"}, rows)
	}

	if credErr != nil {
		fmt.Fprintf(log, "\n%s could not write credentials file: %v\n", cli.FAIL, credErr)
	} else {
		fmt.Fprintf(log, "\n%s full credentials written to %s (mode 0600) — keep it out of version control.\n", cli.OK, credPath)
	}

	// How to call each gateway (auth models differ — TokenHint makes it explicit).
	// TokenHints are TEMPLATES (e.g. "apikey: <key>", "Authorization: $token"),
	// never literal secret values, so they are safe to print verbatim.
	fmt.Fprintln(log, "\nHow to invoke (per gateway):")
	for _, o := range outcomes {
		if o.res != nil && o.res.TokenHint != "" {
			fmt.Fprintf(log, "  • %-12s %s\n", o.name, o.res.TokenHint)
		}
	}

	fmt.Fprintf(log, "\n%d/%d gateways provisioned for client %q.\n", len(outcomes)-failed, len(outcomes), clientID)
	if failed > 0 {
		return fmt.Errorf("%d/%d gateways failed to provision", failed, len(outcomes))
	}
	return nil
}

// consumerReport projects the subscribe outcomes onto the stable
// machine-readable shape shared with the governance BFF. SECURITY: like the
// human table it carries NO secret material — credential_issued only reports
// that a data-plane secret exists, and credentials_file points at the 0600
// file holding it.
func consumerReport(clientID, credentialsPath string, outcomes []consumerOutcome) output.ConsumerReport {
	r := output.ConsumerReport{
		OK:              true,
		ClientID:        clientID,
		CredentialsFile: credentialsPath,
		Targets:         make([]output.ConsumerTarget, 0, len(outcomes)),
	}
	for _, o := range outcomes {
		t := output.ConsumerTarget{Gateway: o.name, Type: o.typ}
		if o.err != nil || o.res == nil {
			r.OK = false
			t.Error = errStr(o.err)
		}
		if o.res != nil {
			t.ConsumerID = o.res.ConsumerID
			t.SubscriptionID = o.res.SubscriptionID
			t.CredentialIssued = o.res.ConsumerKey != "" || o.res.ConsumerSecret != ""
			t.TokenHint = o.res.TokenHint
		}
		r.Targets = append(r.Targets, t)
	}
	return r
}

// maskCredential renders a non-revealing marker for the CREDENTIAL column. It
// NEVER returns secret material (not even a prefix): the data-plane credential
// (WSO2 consumerKey, APISIX apikey, ...) lives in res.ConsumerKey/Secret and is
// only ever written to the 0600 credentials file. The marker only reports
// whether a secret was issued, so the table stays informative without leaking.
func maskCredential(res *adapter.ConsumerResult) string {
	if res.ConsumerKey == "" && res.ConsumerSecret == "" {
		// No data-plane secret for this gateway (e.g. the webMethods mock has no
		// auth); nothing to mask.
		return "(none)"
	}
	return "•••••• (see " + credentialsFile + ")"
}

// writeCredentials writes the FULL synthetic credentials to a 0600 file so no
// secret has to be echoed on stdout. The file is opened with O_TRUNC so a
// re-run overwrites stale material rather than appending. It returns the path
// written for the on-stdout pointer.
func writeCredentials(clientID, clientSecret string, outcomes []consumerOutcome) (string, error) {
	f, err := os.OpenFile(credentialsFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if err := renderCredentials(f, clientID, clientSecret, outcomes); err != nil {
		return "", err
	}
	return credentialsFile, nil
}

// renderCredentials writes the credentials document to w. Split out from
// writeCredentials so the rendering is unit-testable without touching disk.
func renderCredentials(w io.Writer, clientID, clientSecret string, outcomes []consumerOutcome) error {
	var b strings.Builder
	b.WriteString("# PoC synthetic credentials — generated by `labctl subscribe`\n")
	b.WriteString("# These are DISPOSABLE demonstrator secrets, NOT production material.\n")
	b.WriteString("# Do not commit. Generated: " + time.Now().UTC().Format(time.RFC3339) + "\n\n")

	b.WriteString("[keycloak]\n")
	b.WriteString("clientId     = " + clientID + "\n")
	b.WriteString("clientSecret = " + clientSecret + "\n\n")

	for _, o := range outcomes {
		if o.res == nil {
			continue
		}
		b.WriteString("[" + o.name + "]\n")
		b.WriteString("consumerId     = " + o.res.ConsumerID + "\n")
		if o.res.SubscriptionID != "" {
			b.WriteString("subscriptionId = " + o.res.SubscriptionID + "\n")
		}
		if o.res.ConsumerKey != "" {
			b.WriteString("consumerKey    = " + o.res.ConsumerKey + "\n")
		}
		if o.res.ConsumerSecret != "" {
			b.WriteString("consumerSecret = " + o.res.ConsumerSecret + "\n")
		}
		if o.res.TokenHint != "" {
			b.WriteString("invoke         = " + o.res.TokenHint + "\n")
		}
		b.WriteString("\n")
	}

	_, err := io.WriteString(w, b.String())
	return err
}
