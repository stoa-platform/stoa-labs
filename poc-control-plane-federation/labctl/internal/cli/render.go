// Package cli holds small, dependency-light output helpers for the labctl
// commands: aligned tables and status glyphs, so the dispatch loop stays focused
// on orchestration rather than formatting.
package cli

import (
	"fmt"
	"io"
	"strings"
	"text/tabwriter"
)

// Status glyphs used across apply/subscribe/get output.
const (
	OK   = "✓"
	FAIL = "✗"
	SKIP = "–"
)

// Table writes an aligned table. rows must each have len(headers) cells.
func Table(w io.Writer, headers []string, rows [][]string) {
	tw := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, strings.Join(headers, "\t"))
	for _, r := range rows {
		fmt.Fprintln(tw, strings.Join(r, "\t"))
	}
	_ = tw.Flush()
}

// Truncate shortens s to n runes with an ellipsis, for tidy table cells.
func Truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	if n <= 1 {
		return string(r[:n])
	}
	return string(r[:n-1]) + "…"
}

// Glyph maps a boolean ok/err into a status cell.
func Glyph(ok bool) string {
	if ok {
		return OK
	}
	return FAIL
}
