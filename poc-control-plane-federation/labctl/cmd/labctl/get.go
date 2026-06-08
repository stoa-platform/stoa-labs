package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/cli"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/targets"
)

var getCmd = &cobra.Command{
	Use:   "get",
	Short: "List APIs across all gateways — the unified federated catalog",
	Args:  cobra.MaximumNArgs(1),
	Long: "get apis queries every gateway in targets.yaml and prints one unified view of " +
		"what each heterogeneous runtime exposes — the federated catalog the study says no " +
		"product delivers.",
	RunE: runGet,
}

func init() {
	rootCmd.AddCommand(getCmd)
}

func runGet(cmd *cobra.Command, args []string) error {
	ctx := cmd.Context()
	out := cmd.OutOrStdout()

	if len(args) == 1 && args[0] != "apis" {
		return fmt.Errorf("unknown resource %q (only 'apis' is supported)", args[0])
	}

	tf, err := targets.Load(fileFlag)
	if err != nil {
		return err
	}

	rows := [][]string{}
	var listErrs int
	for _, t := range tf.Targets {
		ad, err := adapter.New(t.ToConfig())
		if err != nil {
			listErrs++
			rows = append(rows, []string{t.Name, cli.FAIL, "", "", cli.Truncate(err.Error(), 40)})
			continue
		}
		apis, err := ad.List(ctx)
		if err != nil {
			listErrs++
			rows = append(rows, []string{t.Name, cli.FAIL, "", "", cli.Truncate(err.Error(), 40)})
			continue
		}
		if len(apis) == 0 {
			rows = append(rows, []string{t.Name, cli.SKIP, "(none)", "", ""})
			continue
		}
		for _, a := range apis {
			rows = append(rows, []string{t.Name, a.APIID, a.Name, a.Version, a.BasePath})
		}
	}

	cli.Table(out, []string{"GATEWAY", "API ID", "NAME", "VERSION", "BASEPATH"}, rows)
	if listErrs > 0 {
		return fmt.Errorf("%d/%d gateways failed to list", listErrs, len(tf.Targets))
	}
	return nil
}
