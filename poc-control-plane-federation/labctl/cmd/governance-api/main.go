// Command governance-api is the Console Light BFF (console-light/API-CONTRACT.md):
// a thin governance layer over a Git repository where every validated action is
// a signed commit. It never executes labctl on the production path (ADR-068) —
// it writes governed commits; the client's CI converges the gateways.
//
// Stdlib + the module's vendored YAML only. Run from labctl/:
//
//	GOVERNANCE_REPO=/abs/path go run ./cmd/governance-api
package main

import (
	_ "embed"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
)

//go:embed uac_contract_v1_schema.json
var uacSchema []byte

func main() {
	repoPath := envOr("GOVERNANCE_REPO", "../var/governance-repo")
	if !filepath.IsAbs(repoPath) {
		abs, err := filepath.Abs(repoPath)
		if err == nil {
			repoPath = abs
		}
	}
	repo, err := governance.OpenRepo(repoPath)
	if err != nil {
		log.Fatalf("governance-api: %v", err)
	}

	kcBase := envOr("KC_BASE", "http://localhost:8480")
	kcRealm := envOr("KC_REALM", "stoa-lab")

	srv := &Server{
		Store:       &governance.Store{Repo: repo},
		Verifier:    governance.NewVerifier(kcBase, kcRealm),
		KC:          governance.NewKCAdmin(kcBase, kcRealm, envOr("KC_ADMIN_USER", "admin"), envOr("KC_ADMIN_PASSWORD", "admin")),
		TargetsFile: os.Getenv("TARGETS_FILE"),
		UIDist:      os.Getenv("UI_DIST"),
		Schema:      uacSchema,
		// ITSM_URL empty → nil client → itsmCheck gates refuse (fail-closed).
		ITSM: governance.NewITSMClient(os.Getenv("ITSM_URL")),
	}

	listen := envOr("LISTEN", ":8787")
	log.Printf("governance-api: repo=%s keycloak=%s/realms/%s listen=%s", repoPath, kcBase, kcRealm, listen)
	if err := http.ListenAndServe(listen, srv.Handler()); err != nil {
		log.Fatalf("governance-api: %v", err)
	}
}

// envOr reads an env var with a default (contract §7).
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
