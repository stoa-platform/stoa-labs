package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/cli"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/output"
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
	format, err := output.ParseFormat(outputFlag)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()

	if len(args) == 1 && args[0] != "apis" {
		return fmt.Errorf("unknown resource %q (only 'apis' is supported)", args[0])
	}

	tf, err := targets.Load(fileFlag)
	if err != nil {
		return err
	}

	// Build the federated catalog once; render it as table or JSON below.
	report := output.ListReport{OK: true, Targets: make([]output.ListTarget, 0, len(tf.Targets))}
	for _, t := range tf.Targets {
		lt := output.ListTarget{Gateway: t.Name, Type: t.Type, APIs: []output.ListedAPI{}}
		ad, err := adapter.New(t.ToConfig())
		if err == nil {
			var apis []adapter.PublishedAPI
			apis, err = ad.List(ctx)
			for _, a := range apis {
				lt.APIs = append(lt.APIs, output.ListedAPI{
					APIID:    a.APIID,
					Name:     a.Name,
					Version:  a.Version,
					BasePath: a.BasePath,
				})
			}
		}
		if err != nil {
			report.OK = false
			lt.Error = err.Error()
		}
		report.Targets = append(report.Targets, lt)
	}

	if format == output.FormatJSON {
		if err := output.WriteJSON(out, report); err != nil {
			return err
		}
	} else {
		rows := [][]string{}
		for _, lt := range report.Targets {
			if lt.Error != "" {
				rows = append(rows, []string{lt.Gateway, cli.FAIL, "", "", cli.Truncate(lt.Error, 40)})
				continue
			}
			if len(lt.APIs) == 0 {
				rows = append(rows, []string{lt.Gateway, cli.SKIP, "(none)", "", ""})
				continue
			}
			for _, a := range lt.APIs {
				rows = append(rows, []string{lt.Gateway, a.APIID, a.Name, a.Version, a.BasePath})
			}
		}
		cli.Table(out, []string{"GATEWAY", "API ID", "NAME", "VERSION", "BASEPATH"}, rows)
	}

	if !report.OK {
		listErrs := 0
		for _, lt := range report.Targets {
			if lt.Error != "" {
				listErrs++
			}
		}
		return fmt.Errorf("%d/%d gateways failed to list", listErrs, len(tf.Targets))
	}
	return nil
}
