package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/cli"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/keycloak"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/openapi"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

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
	fmt.Fprintf(out, "  %s client %s ready (secret %s…)\n\n", cli.OK, clientID, cli.Truncate(clientSecret, 6))

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

	// 3) Report.
	rows := make([][]string, 0, len(outcomes))
	failed := 0
	for _, o := range outcomes {
		if o.err != nil || o.res == nil {
			failed++
			rows = append(rows, []string{o.name, cli.FAIL, "", cli.Truncate(errStr(o.err), 50)})
			continue
		}
		cred := o.res.ConsumerKey
		if cred == "" {
			cred = o.res.ConsumerID
		}
		rows = append(rows, []string{o.name, cli.OK, o.res.ConsumerID, cli.Truncate(cred, 24)})
	}
	cli.Table(out, []string{"GATEWAY", "STATUS", "CONSUMER ID", "CREDENTIAL"}, rows)

	// How to call each gateway (auth models differ — TokenHint makes it explicit).
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
