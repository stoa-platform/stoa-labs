package targets

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeManifest writes a targets.yaml into a temp dir and returns (dir, path).
func writeManifest(t *testing.T, body string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "targets.yaml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	return dir, p
}

// A valid manifest loads and resolves the relative contract path against the
// manifest's own directory (so `labctl apply -f x/targets.yaml` works anywhere).
func TestLoad_ValidResolvesRelativeContract(t *testing.T) {
	dir, p := writeManifest(t, `
contract: apis/accounts.yaml
backendUrl: http://backend:8080
targets:
  - name: wso2
    type: wso2
    adminUrl: https://wso2:9443
    gatewayUrl: https://wso2:8243
    insecure: true
    gatewayEnv: Default
    vhost: localhost
  - name: apisix
    type: apisix
    adminUrl: http://apisix:9180
    consumerAuth: jwt-auth
    credentials:
      adminKey: k
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	want := filepath.Join(dir, "apis/accounts.yaml")
	if f.Contract != want {
		t.Errorf("Contract = %q, want resolved %q", f.Contract, want)
	}
	if len(f.Targets) != 2 {
		t.Fatalf("len(Targets) = %d, want 2", len(f.Targets))
	}
}

// An ABSOLUTE contract path must be left untouched (not re-joined to the dir).
func TestLoad_AbsoluteContractUntouched(t *testing.T) {
	abs := filepath.Join(t.TempDir(), "abs", "spec.yaml")
	_, p := writeManifest(t, `
contract: `+abs+`
targets:
  - name: apisix
    type: apisix
    adminUrl: http://apisix:9180
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if f.Contract != abs {
		t.Errorf("Contract = %q, want absolute path untouched %q", f.Contract, abs)
	}
}

func TestLoad_Errors(t *testing.T) {
	cases := []struct {
		name      string
		body      string
		wantInErr string
	}{
		{
			name:      "missing contract",
			body:      "targets:\n  - name: a\n    type: apisix\n    adminUrl: http://x:9180\n",
			wantInErr: "'contract' is required",
		},
		{
			name:      "no targets",
			body:      "contract: apis/x.yaml\ntargets: []\n",
			wantInErr: "at least one target is required",
		},
		{
			name:      "target missing name/type",
			body:      "contract: apis/x.yaml\ntargets:\n  - adminUrl: http://x:9180\n",
			wantInErr: "needs name and type",
		},
		{
			name:      "target missing adminUrl",
			body:      "contract: apis/x.yaml\ntargets:\n  - name: a\n    type: apisix\n",
			wantInErr: `needs adminUrl`,
		},
		{
			name: "duplicate target name",
			body: "contract: apis/x.yaml\ntargets:\n" +
				"  - name: dup\n    type: apisix\n    adminUrl: http://x:9180\n" +
				"  - name: dup\n    type: wso2\n    adminUrl: https://y:9443\n",
			wantInErr: `duplicate target name "dup"`,
		},
		{
			// A half-filled inboundAuth can never validate a signature (issuer
			// without JWKS or vice versa) — fail at load, not mid-publish.
			name: "inboundAuth missing jwksUri",
			body: "contract: apis/x.yaml\ntargets:\n" +
				"  - name: wm\n    type: webmethods\n    adminUrl: http://wm:5555\n" +
				"    inboundAuth:\n      issuer: http://kc:8480/realms/lab\n",
			wantInErr: "inboundAuth needs both issuer and jwksUri",
		},
		{
			name: "inboundAuth missing issuer",
			body: "contract: apis/x.yaml\ntargets:\n" +
				"  - name: wm\n    type: webmethods\n    adminUrl: http://wm:5555\n" +
				"    inboundAuth:\n      jwksUri: http://kc:8080/realms/lab/certs\n",
			wantInErr: "inboundAuth needs both issuer and jwksUri",
		},
		{
			// APISIX consumes a DISCOVERY document, not the raw issuer/jwksUri
			// pair — a block carrying only the webMethods-shaped fields on an
			// apisix target can never configure openid-connect. Fail at load.
			name: "apisix inboundAuth missing discoveryUrl",
			body: "contract: apis/x.yaml\ntargets:\n" +
				"  - name: apisix\n    type: apisix\n    adminUrl: http://apisix:9180\n" +
				"    inboundAuth:\n      issuer: http://kc:8480/realms/lab\n" +
				"      jwksUri: http://kc:8080/realms/lab/certs\n",
			wantInErr: "inboundAuth needs discoveryUrl",
		},
		{
			// The OAuth2 path enforces a scope: audience without scope is a
			// half-open barrier (right aud, no scope -> would pass). Fail closed.
			name: "inboundAuth audience without scope",
			body: "contract: apis/x.yaml\ntargets:\n" +
				"  - name: wm\n    type: webmethods\n    adminUrl: http://wm:5555\n" +
				"    inboundAuth:\n      issuer: http://kc:8480/realms/lab\n" +
				"      jwksUri: http://kc:8080/realms/lab/certs\n" +
				"      audience: accounts-read\n",
			wantInErr: "audience but no scope",
		},
		{
			// audience+scope but no clientId AND no keycloak.consumerClientId to
			// default from -> the strategy/application cannot bind. Fail closed.
			name: "inboundAuth audience without clientId or consumerClientId",
			body: "contract: apis/x.yaml\ntargets:\n" +
				"  - name: wm\n    type: webmethods\n    adminUrl: http://wm:5555\n" +
				"    inboundAuth:\n      issuer: http://kc:8480/realms/lab\n" +
				"      jwksUri: http://kc:8080/realms/lab/certs\n" +
				"      audience: accounts-read\n      scope: accounts.read\n",
			wantInErr: "no clientId",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, p := writeManifest(t, tc.body)
			_, err := Load(p)
			if err == nil {
				t.Fatalf("Load succeeded, want error containing %q", tc.wantInErr)
			}
			if !strings.Contains(err.Error(), tc.wantInErr) {
				t.Errorf("err = %q, want substring %q", err.Error(), tc.wantInErr)
			}
		})
	}
}

func TestLoad_MissingFile(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "nope.yaml"))
	if err == nil || !strings.Contains(err.Error(), "read targets") {
		t.Fatalf("err = %v, want 'read targets ...'", err)
	}
}

// ToConfig folds the adapter-specific knobs into Options and passes credentials
// + insecure through verbatim — the projection both commands rely on.
func TestToConfig_FoldsOptionsAndCreds(t *testing.T) {
	tgt := Target{
		Name:         "wso2",
		Type:         "wso2",
		AdminURL:     "https://wso2:9443",
		GatewayURL:   "https://wso2:8243",
		Insecure:     true,
		GatewayEnv:   "Default",
		Vhost:        "localhost",
		ConsumerAuth: "key-auth",
		Credentials:  map[string]string{"username": "admin", "password": "admin"},
	}
	cfg := tgt.ToConfig()
	if cfg.Type != "wso2" || cfg.Name != "wso2" || cfg.AdminURL != "https://wso2:9443" {
		t.Errorf("scalar projection wrong: %+v", cfg)
	}
	if !cfg.Insecure {
		t.Error("Insecure not propagated")
	}
	if cfg.Opt("gatewayEnv", "") != "Default" || cfg.Opt("vhost", "") != "localhost" || cfg.Opt("consumerAuth", "") != "key-auth" {
		t.Errorf("Options not folded: %+v", cfg.Options)
	}
	if cfg.Cred("username", "") != "admin" || cfg.Cred("password", "") != "admin" {
		t.Errorf("Credentials not passed through: %+v", cfg.Credentials)
	}
	// No inboundAuth block -> the keys must be ABSENT from Options (the
	// adapter treats their presence as "feature on", so an empty-but-present
	// projection would be a regression vector).
	for _, k := range []string{"inboundAuthIssuer", "inboundAuthJwksUri", "inboundAuthDiscoveryUrl", "inboundAuthAliasName"} {
		if _, ok := cfg.Options[k]; ok {
			t.Errorf("Options[%q] present without an inboundAuth block", k)
		}
	}
}

// The optional inboundAuth block loads from YAML and folds into Options so the
// webMethods adapter can project it (alias + IAM stage) without the targets
// package knowing gateway specifics.
func TestLoad_InboundAuthParsesAndFolds(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    gatewayUrl: http://wm:5555
    inboundAuth:
      issuer: http://localhost:8480/realms/stoa-lab
      jwksUri: http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs
      aliasName: KeycloakStoaLab
    credentials:
      username: Administrator
      password: manage
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	ia := f.Targets[0].InboundAuth
	if ia == nil {
		t.Fatal("InboundAuth = nil, want parsed block")
	}
	if ia.Issuer != "http://localhost:8480/realms/stoa-lab" {
		t.Errorf("Issuer = %q", ia.Issuer)
	}
	if ia.JwksURI != "http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs" {
		t.Errorf("JwksURI = %q", ia.JwksURI)
	}
	if ia.AliasName != "KeycloakStoaLab" {
		t.Errorf("AliasName = %q", ia.AliasName)
	}

	cfg := f.Targets[0].ToConfig()
	if cfg.Opt("inboundAuthIssuer", "") != ia.Issuer ||
		cfg.Opt("inboundAuthJwksUri", "") != ia.JwksURI ||
		cfg.Opt("inboundAuthAliasName", "") != ia.AliasName {
		t.Errorf("inboundAuth not folded into Options: %+v", cfg.Options)
	}
}

// The OAuth2 fields (audience/scope/clientId) parse, fold into Options, and
// clientId DEFAULTS from keycloak.consumerClientId when omitted — so the
// manifest does not repeat the consumer clientId.
func TestLoad_InboundAuthOAuth2FieldsAndClientIDDefault(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    gatewayUrl: http://wm:5555
    inboundAuth:
      issuer: http://localhost:8480/realms/stoa-lab
      jwksUri: http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs
      aliasName: KeycloakStoaLab
      audience: accounts-read
      scope: accounts.read
    credentials:
      username: Administrator
      password: manage
keycloak:
  url: http://keycloak:8080
  realm: stoa-lab
  consumerClientId: accounts-read-consumer
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	ia := f.Targets[0].InboundAuth
	if ia.Audience != "accounts-read" || ia.Scope != "accounts.read" {
		t.Errorf("audience/scope = (%q,%q), want (accounts-read, accounts.read)", ia.Audience, ia.Scope)
	}
	// clientId defaulted from keycloak.consumerClientId.
	if ia.ClientID != "accounts-read-consumer" {
		t.Errorf("clientId = %q, want defaulted accounts-read-consumer", ia.ClientID)
	}
	cfg := f.Targets[0].ToConfig()
	if cfg.Opt("inboundAuthAudience", "") != "accounts-read" ||
		cfg.Opt("inboundAuthScope", "") != "accounts.read" ||
		cfg.Opt("inboundAuthClientId", "") != "accounts-read-consumer" {
		t.Errorf("OAuth2 fields not folded into Options: %+v", cfg.Options)
	}
}

// Remote introspection: introspectionEndpoint folds into Options and the
// gateway client credentials DEFAULT to poc-gateways / poc-gateways-secret when
// omitted (so the manifest need not repeat them).
func TestLoad_InboundAuthIntrospectionDefaultsAndFolds(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    inboundAuth:
      issuer: http://localhost:8480/realms/stoa-lab
      jwksUri: http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs
      audience: accounts-read
      scope: accounts.read
      introspectionEndpoint: http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/token/introspect
    credentials:
      username: Administrator
      password: manage
keycloak:
  consumerClientId: accounts-read-consumer
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	ia := f.Targets[0].InboundAuth
	if ia.IntrospectionClientID != "poc-gateways" || ia.IntrospectionClientSecret != "poc-gateways-secret" {
		t.Errorf("introspection client = (%q,%q), want defaulted (poc-gateways, poc-gateways-secret)", ia.IntrospectionClientID, ia.IntrospectionClientSecret)
	}
	cfg := f.Targets[0].ToConfig()
	if cfg.Opt("inboundAuthIntrospectionEndpoint", "") != ia.IntrospectionEndpoint ||
		cfg.Opt("inboundAuthIntrospectionClientId", "") != "poc-gateways" ||
		cfg.Opt("inboundAuthIntrospectionClientSecret", "") != "poc-gateways-secret" {
		t.Errorf("introspection fields not folded into Options: %+v", cfg.Options)
	}
}

// Remote introspection without an audience is a half-open config (there is no
// aud to enforce) — Load must fail closed.
func TestLoad_InboundAuthIntrospectionWithoutAudienceFails(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    inboundAuth:
      issuer: http://localhost:8480/realms/stoa-lab
      jwksUri: http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs
      introspectionEndpoint: http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/token/introspect
`)
	_, err := Load(p)
	if err == nil {
		t.Fatal("Load with introspectionEndpoint but no audience succeeded, want fail-closed")
	}
	if !strings.Contains(err.Error(), "audience") {
		t.Errorf("error %q should explain remote introspection needs an audience", err.Error())
	}
}

// An explicit clientId on the block is NOT overridden by the keycloak default.
func TestLoad_InboundAuthExplicitClientIDWins(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    inboundAuth:
      issuer: http://kc:8480/realms/lab
      jwksUri: http://kc:8080/realms/lab/certs
      audience: accounts-read
      scope: accounts.read
      clientId: explicit-client
    credentials:
      username: Administrator
      password: manage
keycloak:
  consumerClientId: other-consumer
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := f.Targets[0].InboundAuth.ClientID; got != "explicit-client" {
		t.Errorf("clientId = %q, want explicit-client (not overridden by keycloak default)", got)
	}
}

// The APISIX shape of the inboundAuth block: discoveryUrl alone is valid (the
// openid-connect plugin derives issuer+jwks from the discovery document), it
// loads and folds into Options under inboundAuthDiscoveryUrl — withOUT
// requiring the webMethods-shaped issuer/jwksUri pair.
func TestLoad_APISIXInboundAuthDiscoveryOnly(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: apisix
    type: apisix
    adminUrl: http://apisix:9180
    gatewayUrl: http://apisix:9080
    inboundAuth:
      discoveryUrl: http://keycloak:8080/realms/stoa-lab/.well-known/openid-configuration
    credentials:
      adminKey: k
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	ia := f.Targets[0].InboundAuth
	if ia == nil {
		t.Fatal("InboundAuth = nil, want parsed block")
	}
	const wantDisc = "http://keycloak:8080/realms/stoa-lab/.well-known/openid-configuration"
	if ia.DiscoveryURL != wantDisc {
		t.Errorf("DiscoveryURL = %q, want %q", ia.DiscoveryURL, wantDisc)
	}
	cfg := f.Targets[0].ToConfig()
	if cfg.Opt("inboundAuthDiscoveryUrl", "") != wantDisc {
		t.Errorf("inboundAuthDiscoveryUrl not folded into Options: %+v", cfg.Options)
	}
}

// The optional observability block (ADR-070) parses, defaults the tenant from
// backstage.owner (the owner→tenant derivation), and folds into Options so the
// apisix adapter can project a kafka-logger without the targets package knowing
// gateway specifics.
func TestLoad_ObservabilityParsesAndDefaultsTenantFromOwner(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: apisix
    type: apisix
    adminUrl: http://apisix:9180
    gatewayUrl: http://apisix:9080
    observability:
      kafkaBroker: poc-analytics-redpanda:9092
      topicPrefix: stoa.txn
    credentials:
      adminKey: k
backstage:
  owner: accounts-team
  system: accounts
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	ob := f.Targets[0].Observability
	if ob == nil {
		t.Fatal("Observability = nil, want parsed block")
	}
	if ob.KafkaBroker != "poc-analytics-redpanda:9092" {
		t.Errorf("KafkaBroker = %q", ob.KafkaBroker)
	}
	if ob.TopicPrefix != "stoa.txn" {
		t.Errorf("TopicPrefix = %q", ob.TopicPrefix)
	}
	// Tenant omitted in the manifest -> defaulted from backstage.owner.
	if ob.Tenant != "accounts-team" {
		t.Errorf("Tenant = %q, want accounts-team (defaulted from backstage.owner)", ob.Tenant)
	}

	cfg := f.Targets[0].ToConfig()
	if cfg.Opt("observabilityKafkaBroker", "") != "poc-analytics-redpanda:9092" ||
		cfg.Opt("observabilityTopicPrefix", "") != "stoa.txn" ||
		cfg.Opt("observabilityTenant", "") != "accounts-team" {
		t.Errorf("observability not folded into Options: %+v", cfg.Options)
	}
}

// The optional partner block (ADR-071) parses its token/IP/cert fields and
// resolves a RELATIVE publicCertRef against the manifest dir (so a governance
// repo can reference ./partners/acme/public.crt from anywhere).
func TestLoad_PartnerParsesAndResolvesCertPath(t *testing.T) {
	dir, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    credentials:
      username: Administrator
      password: manage
partner:
  tokenIdentifiers:
    - b2b-partner-acme-2026
  ipAllowlist:
    - 203.0.113.10
    - 10.60.30.1-10.60.30.30
  publicCertRef: partners/acme/public.crt
`)
	// The referenced cert file must exist (Load fails closed on a missing path).
	certDir := filepath.Join(dir, "partners", "acme")
	if err := os.MkdirAll(certDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(certDir, "public.crt"), []byte("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"), 0o600); err != nil {
		t.Fatalf("write cert: %v", err)
	}

	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if f.Partner == nil {
		t.Fatal("Partner = nil, want parsed block")
	}
	if len(f.Partner.TokenIdentifiers) != 1 || f.Partner.TokenIdentifiers[0] != "b2b-partner-acme-2026" {
		t.Errorf("TokenIdentifiers = %v", f.Partner.TokenIdentifiers)
	}
	if len(f.Partner.IPAllowlist) != 2 {
		t.Errorf("IPAllowlist = %v, want 2 entries", f.Partner.IPAllowlist)
	}
	want := filepath.Join(dir, "partners/acme/public.crt")
	if f.Partner.PublicCertRef != want {
		t.Errorf("PublicCertRef = %q, want resolved %q", f.Partner.PublicCertRef, want)
	}
}

// An INLINE PEM publicCertRef is kept verbatim (not treated as a path, so Load
// does not try to stat it as a file).
func TestLoad_PartnerInlineCertKeptVerbatim(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    credentials:
      username: Administrator
      password: manage
partner:
  publicCertRef: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if !strings.Contains(f.Partner.PublicCertRef, "BEGIN CERTIFICATE") {
		t.Errorf("inline PEM not kept verbatim: %q", f.Partner.PublicCertRef)
	}
}

// A publicCertRef PATH that does not exist is a config typo — fail at load.
func TestLoad_PartnerMissingCertFileFailsClosed(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    credentials:
      username: Administrator
      password: manage
partner:
  publicCertRef: partners/acme/nope.crt
`)
	_, err := Load(p)
	if err == nil || !strings.Contains(err.Error(), "publicCertRef") {
		t.Fatalf("Load = %v, want fail-closed error mentioning publicCertRef", err)
	}
}

// No partner block -> File.Partner is nil (the default leaves the consumer
// unchanged on every gateway).
func TestLoad_NoPartnerBlockIsNil(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    credentials:
      username: Administrator
      password: manage
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if f.Partner != nil {
		t.Errorf("Partner = %+v, want nil (no block declared)", f.Partner)
	}
}

// The optional routing block (CI multi-env) parses, defaults the alias-name
// templates, and folds into Options so the webMethods adapter can project the
// endpoint/credential aliases without the targets package knowing gateway
// specifics.
func TestLoad_RoutingParsesDefaultsAndFolds(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    routing:
      endpointAlias:
        url: http://backend-dev:8080/rest/accounts
      credentialAlias: {}
    credentials:
      username: Administrator
      password: manage
      backendUsername: svc-accounts
      backendPassword: s3cret
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	r := f.Targets[0].Routing
	if r == nil || r.EndpointAlias == nil {
		t.Fatal("Routing/EndpointAlias = nil, want parsed block")
	}
	if r.EndpointAlias.URL != "http://backend-dev:8080/rest/accounts" {
		t.Errorf("EndpointAlias.URL = %q", r.EndpointAlias.URL)
	}
	cfg := f.Targets[0].ToConfig()
	// Names omitted in the manifest -> the "{api}" templates are defaulted.
	if cfg.Opt("routingEndpointAliasName", "") != "{api}-backend" ||
		cfg.Opt("routingEndpointAliasUrl", "") != "http://backend-dev:8080/rest/accounts" ||
		cfg.Opt("routingCredentialAliasName", "") != "{api}-backend-cred" {
		t.Errorf("routing not folded/defaulted into Options: %+v", cfg.Options)
	}
	// The backend credential VALUES pass through Credentials, not Options.
	if cfg.Cred("backendUsername", "") != "svc-accounts" || cfg.Cred("backendPassword", "") != "s3cret" {
		t.Errorf("backend credentials not passed through: %+v", cfg.Credentials)
	}
}

// No routing block -> the routing keys must be ABSENT from Options (their
// presence switches the adapter feature on).
func TestLoad_NoRoutingBlockNoOptions(t *testing.T) {
	tgt := Target{Name: "wm", Type: "webmethods", AdminURL: "http://wm:5555"}
	cfg := tgt.ToConfig()
	for _, k := range []string{"routingEndpointAliasName", "routingEndpointAliasUrl", "routingCredentialAliasName"} {
		if _, ok := cfg.Options[k]; ok {
			t.Errorf("Options[%q] present without a routing block", k)
		}
	}
}

// A routing block without the endpoint alias URL can never re-point the
// backend (the URL is the per-env value the feature exists for) — fail closed.
func TestLoad_RoutingMissingURLFailsClosed(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    routing:
      endpointAlias:
        name: "{api}-backend"
    credentials:
      username: Administrator
      password: manage
`)
	_, err := Load(p)
	if err == nil || !strings.Contains(err.Error(), "endpointAlias.url") {
		t.Fatalf("Load = %v, want fail-closed error mentioning endpointAlias.url", err)
	}
}

// A credentialAlias without the backend credential VALUES in credentials would
// store an empty/corrupt gateway credential — fail closed at load.
func TestLoad_RoutingCredentialAliasNeedsBackendCreds(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    routing:
      endpointAlias:
        url: http://backend-dev:8080/rest/accounts
      credentialAlias: {}
    credentials:
      username: Administrator
      password: manage
`)
	_, err := Load(p)
	if err == nil || !strings.Contains(err.Error(), "backendUsername") {
		t.Fatalf("Load = %v, want fail-closed error mentioning backendUsername", err)
	}
}

// webMethods auth mode at load: bearerTokenFile XOR username/password.
func TestLoad_WebmethodsAuthModeXOR(t *testing.T) {
	// Mixed modes -> fail closed.
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    credentials:
      username: Administrator
      password: manage
      bearerTokenFile: /run/secrets/wm-token
`)
	if _, err := Load(p); err == nil || !strings.Contains(err.Error(), "exactly ONE auth mode") {
		t.Fatalf("Load with mixed auth modes = %v, want fail-closed 'exactly ONE auth mode'", err)
	}

	// Half a Basic pair and no bearer -> fail closed.
	_, p = writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    credentials:
      username: Administrator
`)
	if _, err := Load(p); err == nil || !strings.Contains(err.Error(), "bearerTokenFile") {
		t.Fatalf("Load with half a Basic pair = %v, want fail-closed naming both modes", err)
	}

	// Bearer-only mode loads fine (the FILE is read by the adapter, not here).
	_, p = writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: webmethods
    type: webmethods
    adminUrl: http://wm:5555
    credentials:
      bearerTokenFile: /run/secrets/wm-token
`)
	if _, err := Load(p); err != nil {
		t.Fatalf("Load with bearer-only credentials: %v", err)
	}
}

// An explicit tenant in the observability block wins over backstage.owner.
func TestLoad_ObservabilityExplicitTenantWins(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: apisix
    type: apisix
    adminUrl: http://apisix:9180
    gatewayUrl: http://apisix:9080
    observability:
      kafkaBroker: poc-analytics-redpanda:9092
      tenant: explicit-tenant
    credentials:
      adminKey: k
backstage:
  owner: accounts-team
`)
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := f.Targets[0].Observability.Tenant; got != "explicit-tenant" {
		t.Errorf("Tenant = %q, want explicit-tenant (explicit wins over owner)", got)
	}
}

// An observability block without a broker is a config bug — fail at load instead
// of projecting a kafka-logger that points nowhere.
func TestLoad_ObservabilityMissingBrokerFailsClosed(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: apisix
    type: apisix
    adminUrl: http://apisix:9180
    gatewayUrl: http://apisix:9080
    observability:
      topicPrefix: stoa.txn
    credentials:
      adminKey: k
backstage:
  owner: accounts-team
`)
	_, err := Load(p)
	if err == nil || !strings.Contains(err.Error(), "kafkaBroker") {
		t.Fatalf("Load = %v, want fail-closed error mentioning kafkaBroker", err)
	}
}

// An observability block with no tenant AND no backstage.owner cannot route the
// tenant-isolated index — fail closed.
func TestLoad_ObservabilityNoTenantNoOwnerFailsClosed(t *testing.T) {
	_, p := writeManifest(t, `
contract: apis/x.yaml
targets:
  - name: apisix
    type: apisix
    adminUrl: http://apisix:9180
    gatewayUrl: http://apisix:9080
    observability:
      kafkaBroker: poc-analytics-redpanda:9092
    credentials:
      adminKey: k
`)
	_, err := Load(p)
	if err == nil || !strings.Contains(err.Error(), "tenant") {
		t.Fatalf("Load = %v, want fail-closed error mentioning tenant", err)
	}
}
