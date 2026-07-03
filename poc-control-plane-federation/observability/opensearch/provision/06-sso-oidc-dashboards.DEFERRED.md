# SSO OIDC Dashboards — DEFERRED (ADR-070, best-effort)

Status: **deferred**. The RBAC slice (role + internal user + rolesmapping) is proven
WITHOUT SSO via the internal user `accounts-viewer`. OIDC is the prod path; it is
documented here ready-to-apply but NOT wired into the running socle, to avoid
destabilizing the security config (`basic_internal_auth_domain`) used for RBAC tests.

Realm `stoa-lab` OIDC discovery is reachable:
  issuer: http://localhost:8480/realms/stoa-lab
  well-known: http://localhost:8480/realms/stoa-lab/.well-known/openid-configuration

## Why deferred (PoC blockers, not design blockers)

1. **Split-horizon issuer URL.** The Dashboards backend validates the OIDC issuer
   from INSIDE the `poc` docker network (must reach `http://poc-keycloak:8080/...`),
   but the browser redirect_uri must use the host-facing `http://localhost:8480/...`.
   Keycloak `KC_HOSTNAME`/`frontendUrl` + an internal connect_url override are
   required so the issuer string matches in both contexts. Fiddly in a container PoC.
2. **Mutating the running security config.** Adding `openid_auth_domain` to
   `config.yml` requires a `securityadmin.sh` reload against the live single-node
   cluster; a bad reload can lock out basic auth (the path the RBAC test relies on).

## Ready-to-apply (when the socle can absorb a security reload)

### 1. Keycloak client (realm stoa-lab)
- clientId: `opensearch-dashboards`
- access type: confidential, standard flow on
- valid redirect URIs: `http://localhost:5601/auth/openid/login`
- a protocol mapper emitting group/role claim `roles` (or `groups`) carrying
  `tenant-accounts-team` so `roles_mapping` backend_roles match the OpenSearch role.

### 2. OpenSearch security `config.yml` — add authc domain (order < basic)
```yaml
    openid_auth_domain:
      description: "OIDC via Keycloak realm stoa-lab"
      http_enabled: true
      transport_enabled: false
      order: 0
      http_authenticator:
        type: openid
        challenge: false
        config:
          subject_key: preferred_username
          roles_key: roles
          openid_connect_url: "http://poc-keycloak:8080/realms/stoa-lab/.well-known/openid-configuration"
      authentication_backend:
        type: noop
```
Reload: `docker exec poc-analytics-opensearch \
  plugins/opensearch-security/tools/securityadmin.sh -f config/opensearch-security/config.yml \
  -icl -nhnv -cacert ... -cert ... -key ...`

### 3. Dashboards `opensearch_dashboards.yml`
```yaml
opensearch_security.auth.type: "openid"
opensearch_security.openid.connect_url: "http://poc-keycloak:8080/realms/stoa-lab/.well-known/openid-configuration"
opensearch_security.openid.base_redirect_url: "http://localhost:5601"
opensearch_security.openid.client_id: "opensearch-dashboards"
opensearch_security.openid.client_secret: "<from keycloak>"
opensearch_security.openid.scope: "openid profile email roles"
```

### 4. roles_mapping (already provisioned, future-ready)
The role mapping `tenant-accounts-team-viewer` already lists backend_role
`tenant-accounts-team`. Once OIDC emits that claim as a backend role, KC users in
the matching group inherit the tenant viewer role with zero further OpenSearch
changes. The internal user `accounts-viewer` remains as the no-SSO test path.
