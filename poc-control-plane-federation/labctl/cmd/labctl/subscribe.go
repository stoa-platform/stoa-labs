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
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

// credentialsFile is where `labctl subscribe` writes the FULL synthetic
// credentials (mode 0600), so secrets never have to be echoed on stdout.
const credentialsFile = "labctl-credentials.txt"

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
	res  *adapter.ConsumerResult
	err  error
}

func runSubscribe(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	out := cmd.OutOrStdout()

	tf, err := targets.Load(fileFlag)
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
	fmt.Fprintf(out, "Minting Keycloak client %q in realm %q…\n", tf.Keycloak.ConsumerClientID, tf.Keycloak.Realm)
	clientID, clientSecret, err := keycloak.EnsureClient(ctx, keycloak.Config{
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
	fmt.Fprintf(out, "  %s client %s ready (secret acquired)\n\n", cli.OK, clientID)

	// 2) Provision the consumer on every gateway, bound to that identity.
	outcomes := make([]consumerOutcome, 0, len(tf.Targets))
	for _, t := range tf.Targets {
		oc := consumerOutcome{name: t.Name}
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
		res, err := ad.CreateConsumer(ctx, api, spec)
		oc.res, oc.err = res, err
		outcomes = append(outcomes, oc)
	}

	// 3) Report — stdout shows ids + MASKED credentials only; the full secret
	//    material goes to the 0600 credentials file written below.
	rows := make([][]string, 0, len(outcomes))
	failed := 0
	for _, o := range outcomes {
		if o.err != nil || o.res == nil {
			failed++
			rows = append(rows, []string{o.name, cli.FAIL, "", cli.Truncate(errStr(o.err), 50)})
			continue
		}
		rows = append(rows, []string{o.name, cli.OK, o.res.ConsumerID, maskCredential(o.res)})
	}
	cli.Table(out, []string{"GATEWAY", "STATUS", "CONSUMER ID", "CREDENTIAL"}, rows)

	// Persist FULL credentials to a 0600 file so nothing secret hits stdout.
	if credPath, err := writeCredentials(clientID, clientSecret, outcomes); err != nil {
		fmt.Fprintf(out, "\n%s could not write credentials file: %v\n", cli.FAIL, err)
	} else {
		fmt.Fprintf(out, "\n%s full credentials written to %s (mode 0600) — keep it out of version control.\n", cli.OK, credPath)
	}

	// How to call each gateway (auth models differ — TokenHint makes it explicit).
	// TokenHints are TEMPLATES (e.g. "apikey: <key>", "Authorization: $token"),
	// never literal secret values, so they are safe to print verbatim.
	fmt.Fprintln(out, "\nHow to invoke (per gateway):")
	for _, o := range outcomes {
		if o.res != nil && o.res.TokenHint != "" {
			fmt.Fprintf(out, "  • %-12s %s\n", o.name, o.res.TokenHint)
		}
	}

	fmt.Fprintf(out, "\n%d/%d gateways provisioned for client %q.\n", len(outcomes)-failed, len(outcomes), clientID)
	if failed > 0 {
		return fmt.Errorf("%d/%d gateways failed to provision", failed, len(outcomes))
	}
	return nil
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
