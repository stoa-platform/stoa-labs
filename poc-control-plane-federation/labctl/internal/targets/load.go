package targets

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"sigs.k8s.io/yaml"
)

// Load reads and validates a targets.yaml. The contract path is resolved
// relative to the manifest file's directory so `labctl apply -f x/targets.yaml`
// works from anywhere.
func Load(path string) (*File, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read targets %s: %w", path, err)
	}
	var f File
	if err := yaml.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("parse targets %s: %w", path, err)
	}
	if f.Contract == "" {
		return nil, fmt.Errorf("targets %s: 'contract' is required", path)
	}
	if len(f.Targets) == 0 {
		return nil, fmt.Errorf("targets %s: at least one target is required", path)
	}
	dir := filepath.Dir(path)
	if !filepath.IsAbs(f.Contract) {
		f.Contract = filepath.Join(dir, f.Contract)
	}
	seen := map[string]bool{}
	for i, t := range f.Targets {
		if t.Name == "" || t.Type == "" {
			return nil, fmt.Errorf("targets %s: target #%d needs name and type", path, i)
		}
		if t.AdminURL == "" {
			return nil, fmt.Errorf("targets %s: target %q needs adminUrl", path, t.Name)
		}
		if seen[t.Name] {
			return nil, fmt.Errorf("targets %s: duplicate target name %q", path, t.Name)
		}
		seen[t.Name] = true
		// inboundAuth is optional, but a half-filled block is a config bug —
		// fail at load time instead of mid-publish. The required fields are
		// PER-TYPE: apisix projects an openid-connect plugin and resolves
		// issuer+JWKS from the DISCOVERY document, every other gateway needs
		// the raw issuer+jwksUri pair (issuer without JWKS can never validate
		// a signature, and vice versa).
		if ia := t.InboundAuth; ia != nil {
			switch t.Type {
			case "apisix":
				if ia.DiscoveryURL == "" {
					return nil, fmt.Errorf("targets %s: target %q inboundAuth needs discoveryUrl (apisix openid-connect derives issuer+jwks from the discovery document)", path, t.Name)
				}
			default:
				if ia.Issuer == "" || ia.JwksURI == "" {
					return nil, fmt.Errorf("targets %s: target %q inboundAuth needs both issuer and jwksUri", path, t.Name)
				}
				// The OAuth2 path (audience binding) enforces a scope: a token
				// carrying the right aud but no scope must be REFUSED. So audience
				// without scope is a half-open barrier — fail closed at load time
				// rather than silently leaving the scope gate off.
				if ia.Audience != "" {
					if ia.Scope == "" {
						return nil, fmt.Errorf("targets %s: target %q inboundAuth has audience but no scope (the OAuth2 path enforces a scope; set inboundAuth.scope to the scope subscribe grants the consumer)", path, t.Name)
					}
					// The strategy + application identifier are bound to the
					// consumer's clientId. Default it from keycloak.consumerClientId
					// so the manifest does not repeat it; fail closed if neither is
					// set (the OAuth2 path cannot bind an empty clientId).
					if ia.ClientID == "" {
						ia.ClientID = f.Keycloak.ConsumerClientID
						f.Targets[i].InboundAuth.ClientID = ia.ClientID
					}
					if ia.ClientID == "" {
						return nil, fmt.Errorf("targets %s: target %q inboundAuth has audience but no clientId, and keycloak.consumerClientId is empty (set one so the OAuth2 strategy/application can bind the consumer identity)", path, t.Name)
					}
				}
				// Remote introspection (RFC 7662) is what makes the audience an
				// ENFORCED barrier on webMethods: offline JWKS validation never
				// checks aud. It is only meaningful on the OAuth2 path (an
				// audience to enforce), so introspection without audience is a
				// config mistake — fail closed. Default the gateway's own
				// confidential client (distinct from the consumer's clientId) to
				// poc-gateways so the manifest need not repeat it.
				if ia.IntrospectionEndpoint != "" {
					if ia.Audience == "" {
						return nil, fmt.Errorf("targets %s: target %q inboundAuth has introspectionEndpoint but no audience (remote introspection only enforces aud on the OAuth2 path; set inboundAuth.audience)", path, t.Name)
					}
					if ia.IntrospectionClientID == "" {
						ia.IntrospectionClientID = "poc-gateways"
						f.Targets[i].InboundAuth.IntrospectionClientID = ia.IntrospectionClientID
					}
					if ia.IntrospectionClientSecret == "" {
						ia.IntrospectionClientSecret = "poc-gateways-secret"
						f.Targets[i].InboundAuth.IntrospectionClientSecret = ia.IntrospectionClientSecret
					}
					// 10.15 requires a Gateway user on the remote block; default it
					// from the target's Basic-auth username.
					if ia.IntrospectionUser == "" {
						ia.IntrospectionUser = t.Credentials["username"]
						f.Targets[i].InboundAuth.IntrospectionUser = ia.IntrospectionUser
					}
				}
			}
		}
		// webMethods auth mode: exactly ONE of bearerTokenFile (CI bearer mode,
		// the token lives in a 0600 file, never in the manifest) XOR
		// username+password (HTTP Basic). Mixed or missing modes are config
		// bugs — fail at load instead of mid-publish.
		if t.Type == "webmethods" {
			tok := t.Credentials["bearerTokenFile"]
			user, pass := t.Credentials["username"], t.Credentials["password"]
			if tok != "" && (user != "" || pass != "") {
				return nil, fmt.Errorf("targets %s: target %q credentials mix bearerTokenFile and username/password — use exactly ONE auth mode (bearer XOR HTTP Basic)", path, t.Name)
			}
			if tok == "" && (user == "" || pass == "") {
				return nil, fmt.Errorf("targets %s: target %q needs credentials: either username+password (HTTP Basic) or bearerTokenFile (CI bearer mode)", path, t.Name)
			}
		}
		// routing is optional (CI multi-env). A present block needs the
		// endpoint alias URL (the per-env value the feature exists for), and a
		// credentialAlias needs the backend credential VALUES in credentials
		// (the routing block itself never carries secrets) — fail at load.
		if r := t.Routing; r != nil {
			if r.EndpointAlias == nil || r.EndpointAlias.URL == "" {
				return nil, fmt.Errorf("targets %s: target %q routing needs endpointAlias.url (the per-environment backend the ${alias} resolves to)", path, t.Name)
			}
			if r.CredentialAlias != nil {
				if t.Credentials["backendUsername"] == "" || t.Credentials["backendPassword"] == "" {
					return nil, fmt.Errorf("targets %s: target %q routing.credentialAlias needs credentials.backendUsername and credentials.backendPassword (the values the alias stores — never inline in the routing block)", path, t.Name)
				}
			}
		}
		// observability is optional (ADR-070). A present block needs a broker
		// (where to emit) — fail at load instead of projecting a kafka-logger
		// that points nowhere. The tenant tag defaults from backstage.owner (the
		// ADR-070 owner→tenant derivation) so the manifest need not repeat it;
		// fail closed if neither is set (the collector cannot route
		// txn-{tenant}-* without a tenant).
		if ob := t.Observability; ob != nil {
			if ob.KafkaBroker == "" {
				return nil, fmt.Errorf("targets %s: target %q observability needs kafkaBroker (host:port reachable FROM the gateway container, e.g. poc-analytics-redpanda:9092)", path, t.Name)
			}
			if ob.Tenant == "" {
				ob.Tenant = f.Backstage.Owner
				f.Targets[i].Observability.Tenant = ob.Tenant
			}
			if ob.Tenant == "" {
				return nil, fmt.Errorf("targets %s: target %q observability has no tenant, and backstage.owner is empty (set one so the collector can route the tenant-isolated index txn-{tenant}-*)", path, t.Name)
			}
		}
	}

	// partner onboarding (ADR-071) is optional. PublicCertRef may be an INLINE
	// PEM (kept verbatim) or a PATH resolved relative to the manifest dir — so a
	// governance repo can reference ./partners/acme/public.crt and `labctl
	// subscribe` reads it from anywhere. A referenced file that does not exist is
	// a config typo; fail at load instead of mid-subscribe.
	if p := f.Partner; p != nil {
		ref := strings.TrimSpace(p.PublicCertRef)
		if ref != "" && !strings.Contains(ref, "-----BEGIN") {
			if !filepath.IsAbs(ref) {
				ref = filepath.Join(dir, ref)
				f.Partner.PublicCertRef = ref
			}
			if _, err := os.Stat(ref); err != nil {
				return nil, fmt.Errorf("targets %s: partner.publicCertRef %q is not readable: %w", path, ref, err)
			}
		}
	}
	return &f, nil
}
