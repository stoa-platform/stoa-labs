package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print the labctl version",
	RunE: func(cmd *cobra.Command, _ []string) error {
		fmt.Fprintln(cmd.OutOrStdout(), "labctl "+Version)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}
