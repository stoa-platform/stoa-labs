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
	"context"
	_ "embed"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

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
		// Chaîne A (ADR-077) : opt-in par USER_DEPLOY_WEBHOOK_URL +
		// VAULT_EXCHANGE_SECRET[_FILE]. Absent → flux A7 inchangé.
		UserDeploy: NewUserDeployFromEnv(kcBase, kcRealm),
	}

	listen := envOr("LISTEN", ":8787")
	userDeployState := "off"
	if srv.UserDeploy != nil {
		// L'URL du webhook porte le token generic-webhook-trigger dans sa query
		// string — on logge l'URL REDACTÉE (query strippée), jamais le token.
		userDeployState = "on"
		if u, err := url.Parse(srv.UserDeploy.WebhookURL); err == nil {
			u.RawQuery = ""
			userDeployState = "on → " + u.String()
		}
	}
	log.Printf("governance-api: repo=%s keycloak=%s/realms/%s listen=%s user-deploy=%s", repoPath, kcBase, kcRealm, listen, userDeployState)

	// Arrêt gracieux : un SIGTERM juste après un approve ne doit pas perdre un
	// dispatch chaîne A (ni un audit de refus) en vol — on ferme l'écoute PUIS
	// on vide les goroutines suivies avant de sortir.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	hs := &http.Server{Addr: listen, Handler: srv.Handler()}
	go func() {
		if err := hs.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("governance-api: %v", err)
		}
	}()
	<-ctx.Done()
	stop()
	shCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = hs.Shutdown(shCtx)
	srv.WaitDispatches()
	srv.WaitDenials()
	log.Printf("governance-api: arrêt propre (dispatches chaîne A et audits vidés)")
}

// envOr reads an env var with a default (contract §7).
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
