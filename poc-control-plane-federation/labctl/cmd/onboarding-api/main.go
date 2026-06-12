// Command onboarding-api is the self-service "partner onboarding as-code"
// surface (ADR-071), SECURED with OAuth2/OIDC + RBAC multi-tenant + audit.
//
//	POST /applications              (Authorization: Bearer <Keycloak token>)
//	{ "name","tenant","clientId","apis":[...],
//	  "ipAllowlist":[...], "publicCert":"<PEM>", "tokenIdentifiers":[...] }
//
// The request is AUTHENTICATED (Keycloak realm stoa-lab, RS256 token validated
// locally against the realm JWKS — iss + exp + aud), AUTHORIZED (realm role
// partner-onboarder AND a tenant that MUST equal the body tenant), VALIDATED,
// and WRITTEN as a partner manifest into the governance Git repository — and it
// stops there. It NEVER calls a gateway (ADR-068 — STOA off the data path; Git
// is the source of truth). Every decision (ACCEPT/DENY) is audited to OpenSearch
// (per-tenant index) and to a structured stdout line with a W3C trace_id.
//
// Git service account: the push uses the REPO's own credential, server-side —
// never the developer's. In production that credential is issued from Vault with
// short-TTL rotation and is NEVER logged (nothing here prints it). The developer
// only ever presents an OAuth token; the Git identity stays on the server.
//
// Stdlib + the module's vendored deps only (air-gapped: GOPROXY=off, no go get).
// Run from labctl/:
//
//	GOVERNANCE_REPO=/abs/path \
//	KEYCLOAK_URL=http://localhost:8480 KEYCLOAK_REALM=stoa-lab \
//	ONBOARDING_AUDIENCE=onboarding-api \
//	OPENSEARCH_URL=https://localhost:9201 OPENSEARCH_USER=admin \
//	OPENSEARCH_PASSWORD='Stoa!Passw0rd2026' OPENSEARCH_INSECURE=true \
//	go run ./cmd/onboarding-api
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/audit"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/governance"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/onboarding"
	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/vault"
)

func main() {
	repoPath := envOr("GOVERNANCE_REPO", "../var/governance-repo")
	if !filepath.IsAbs(repoPath) {
		if abs, err := filepath.Abs(repoPath); err == nil {
			repoPath = abs
		}
	}
	repo, err := governance.OpenRepo(repoPath)
	if err != nil {
		log.Fatalf("onboarding-api: %v", err)
	}

	// OAuth2/OIDC verifier: local JWKS validation against the Keycloak realm
	// (RS256 + iss + exp + aud). Air-gapped: reuses the module's stdlib verifier;
	// no introspection round-trip, no new dependency.
	kcURL := envOr("KEYCLOAK_URL", "http://localhost:8480")
	kcRealm := envOr("KEYCLOAK_REALM", "stoa-lab")
	audience := envOr("ONBOARDING_AUDIENCE", "onboarding-api")
	verifier := governance.NewVerifierWithAudience(kcURL, kcRealm, audience)

	// Audit sink: per-tenant OpenSearch index + structured stdout line. An empty
	// OPENSEARCH_URL keeps the stdout sink only (still fully auditable).
	osURL := envOr("OPENSEARCH_URL", "https://localhost:9201")
	osUser := envOr("OPENSEARCH_USER", "admin")
	osPass := os.Getenv("OPENSEARCH_PASSWORD") // never defaulted, never logged
	// When OPENSEARCH_PASSWORD is absent and Vault is configured, fetch the
	// audit-write secret from Vault (ADR-074) — it lives in Vault, not in the
	// process env. Never logged.
	if osPass == "" {
		if c, ok := vault.FromEnv(); ok {
			sec, err := c.ReadKV(context.Background(), "opensearch")
			if err != nil {
				log.Fatalf("onboarding-api: vault opensearch: %v", err)
			}
			if sec != nil {
				osPass = sec["adminPassword"]
			}
		}
	}
	osInsecure := boolEnv("OPENSEARCH_INSECURE", true)
	recorder := audit.NewRecorder(osURL, osUser, osPass, osInsecure, log.Default())
	// OTLP/HTTP span export (optional): turns the trace_id into a real Tempo span.
	recorder.OTLPEndpoint = os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")

	// Per-principal rate limit on the shared management plane (actor+tenant).
	// ONBOARDING_RATE_PER_MIN <= 0 disables it.
	ratePerMin := intEnv("ONBOARDING_RATE_PER_MIN", 20)

	srv := &Server{
		Svc:      &onboarding.Service{Repo: repo},
		Verifier: verifier,
		Audit:    recorder,
		Limiter:  newRateLimiter(ratePerMin),
	}

	listen := envOr("LISTEN", ":8788")
	log.Printf("onboarding-api: repo=%s listen=%s realm=%s aud=%s opensearch=%s rate=%d/min (OAuth2+RBAC+audit+rate-limit, ADR-070/071; never touches a gateway)",
		repoPath, listen, kcRealm, audience, osURL, ratePerMin)
	if err := http.ListenAndServe(listen, srv.Handler()); err != nil {
		log.Fatalf("onboarding-api: %v", err)
	}
}

// envOr reads an env var with a default.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// boolEnv reads a boolean env var with a default.
func boolEnv(key string, def bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return b
}

// intEnv reads an integer env var with a default.
func intEnv(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}
