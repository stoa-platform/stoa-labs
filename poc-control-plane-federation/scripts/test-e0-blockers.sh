#!/usr/bin/env bash
# test-e0-blockers.sh — prouve la levée des 4 bloqueurs transverses É0
# (DELIVERY-PROCESS.md §4) qui gataient toutes les briques hors du poste du lab :
#   1. PROXY   : labctl honore HTTP(S)_PROXY/NO_PROXY (http.ProxyFromEnvironment)
#   2. CA      : LABCTL_CA_FILE / VAULT_CACERT (RootCAs), fail-closed si le
#                bundle est illisible ; plus de -k câblé dans les provision OpenSearch
#   3. AUTH GIT: GOVERNANCE_GIT_URL + GIT_CREDENTIALS_ID (GIT_ASKPASS) dans les
#                4 Jenkinsfiles — plus aucun clone anonyme d'URL en dur
#   4. RELEASE : make release -> binaires multi-arch versionnés + SHA256SUMS +
#                SBOM SPDX, build air-gapped (GOPROXY=off, -mod=vendor)
# Preuves aux DEUX niveaux : tests Go (transport) ET binaire livré (bout-en-bout).
# Ne requiert AUCUN service du compose — s'exécute hors zone, comme la release.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; kill $(jobs -p) 2>/dev/null' EXIT

echo "=== É0.1 — proxy sortant d'entreprise (HTTP_PROXY honoré) ==="
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go test ./internal/httpx/ >/dev/null 2>&1 ) \
  && ok "go test internal/httpx (proxy absolu-form + CA + fail-closed)" \
  || bad "go test internal/httpx"

# Binaire livré : un faux proxy local reçoit-il l'appel admin destiné à un host
# non résolvable ? (sans ProxyFromEnvironment : NXDOMAIN direct, log vide)
BIN="$TMP/labctl"
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go build -o "$BIN" . ) || { echo "build failed"; exit 1; }
PROXYLOG="$TMP/proxy.log"; : > "$PROXYLOG"
PROXYPORT=18099
python3 - "$PROXYPORT" "$PROXYLOG" <<'EOF' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def _h(self):
        open(sys.argv[2], 'a').write(self.path + '\n')
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(b'{"list":[]}')
    do_GET = do_POST = do_PUT = _h
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
EOF
sleep 1
cat > "$TMP/targets-proxy.yaml" <<EOF
apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: e0-proxy-probe
contract: $ROOT/apis/accounts-read.openapi.yaml
backendUrl: http://backend.example.invalid:8080
targets:
  - name: apisix-probe
    type: apisix
    adminUrl: http://gateway.example.invalid:9180
    gatewayUrl: http://gateway.example.invalid:9080
    credentials:
      adminKey: dummy
EOF
HTTP_PROXY="http://127.0.0.1:$PROXYPORT" NO_PROXY= VAULT_ADDR= LABCTL_CA_FILE= \
  "$BIN" get apis -f "$TMP/targets-proxy.yaml" >/dev/null 2>&1 || true
grep -q 'gateway.example.invalid' "$PROXYLOG" \
  && ok "binaire livré : l'appel admin vers un host non résolvable TRANSITE par HTTP_PROXY" \
  || bad "binaire livré : le faux proxy n'a rien reçu (HTTP_PROXY ignoré ?)"

echo "=== É0.2 — CA d'entreprise (LABCTL_CA_FILE / VAULT_CACERT, provision sans -k) ==="
( cd "$ROOT/labctl" && GOPROXY=off GOFLAGS=-mod=vendor go test ./internal/vault/ >/dev/null 2>&1 ) \
  && ok "go test internal/vault (VAULT_CACERT bout-en-bout, contrôle x509 sans knob)" \
  || bad "go test internal/vault"

# Binaire livré face à un HTTPS signé par une CA inconnue du système.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 2 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1
TLSLOG="$TMP/tls.log"; : > "$TLSLOG"
TLSPORT=18443
python3 - "$TLSPORT" "$TLSLOG" "$TMP/cert.pem" "$TMP/key.pem" <<'EOF' &
import http.server, ssl, sys
class H(http.server.BaseHTTPRequestHandler):
    def _h(self):
        open(sys.argv[2], 'a').write(self.path + '\n')
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(b'{"list":[]}')
    do_GET = do_POST = _h
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[3], sys.argv[4])
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
EOF
sleep 1
cat > "$TMP/targets-ca.yaml" <<EOF
apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: e0-ca-probe
contract: $ROOT/apis/accounts-read.openapi.yaml
backendUrl: http://backend.example.invalid:8080
targets:
  - name: apisix-probe
    type: apisix
    adminUrl: https://127.0.0.1:$TLSPORT
    gatewayUrl: https://127.0.0.1:$TLSPORT
    credentials:
      adminKey: dummy
EOF
# -o json : la sortie table TRONQUE l'erreur par colonne ; le document JSON
# porte le message x509 complet (stdout), stderr ne dit que « 1/1 failed ».
ERRNOCA="$("$BIN" get apis -o json -f "$TMP/targets-ca.yaml" 2>/dev/null)" || true
[ ! -s "$TLSLOG" ] && echo "$ERRNOCA" | grep -Eqi 'certificate|x509' \
  && ok "binaire livré : SANS knob, CA inconnue -> échec x509 (contrôle)" \
  || bad "binaire livré : le contrôle sans CA aurait dû échouer en x509"
LABCTL_CA_FILE="$TMP/cert.pem" VAULT_ADDR= "$BIN" get apis -f "$TMP/targets-ca.yaml" >/dev/null 2>&1 || true
grep -q '/apisix/admin' "$TLSLOG" \
  && ok "binaire livré : LABCTL_CA_FILE=<pem> -> handshake TLS accepté, l'appel admin passe" \
  || bad "binaire livré : LABCTL_CA_FILE ignoré (rien reçu côté serveur TLS)"

PROV=(observability/opensearch/provision/provision.sh
      observability/opensearch/provision/provision-banking-demo-txn.sh
      observability/opensearch/provision/onboarding/provision-onboarding-audit.sh)
HARDK=0; KNOB=0; SYNTAX=0
for p in "${PROV[@]}"; do
  grep -Eq 'curl -s(-| )*-k| -k -u' "$ROOT/$p" && HARDK=$((HARDK+1))
  grep -q 'OPENSEARCH_CA_FILE' "$ROOT/$p" && KNOB=$((KNOB+1))
  bash -n "$ROOT/$p" || SYNTAX=$((SYNTAX+1))
done
[ "$HARDK" = 0 ] && ok "provision OpenSearch : plus aucun -k câblé en dur (3 scripts)" \
                 || bad "provision OpenSearch : $HARDK script(s) gardent un -k en dur"
[ "$KNOB" = 3 ] && ok "provision OpenSearch : knob OPENSEARCH_CA_FILE/OPENSEARCH_INSECURE présent (3/3)" \
                || bad "provision OpenSearch : knob absent ($KNOB/3)"
[ "$SYNTAX" = 0 ] && ok "provision OpenSearch : bash -n OK (3/3)" \
                  || bad "provision OpenSearch : erreur de syntaxe"

echo "=== É0.3 — auth Git (GOVERNANCE_GIT_URL + GIT_CREDENTIALS_ID, 4 Jenkinsfiles) ==="
JF=(ci/Jenkinsfile ci/Jenkinsfile.prod ci/Jenkinsfile.rollback ../stoa-platform-ci/Jenkinsfile.deploy)
HARDURL=0; CREDS=0; ASKPASS=0
for j in "${JF[@]}"; do
  grep -Eq 'git clone [^"$]*(http|git@)' "$ROOT/$j" && HARDURL=$((HARDURL+1))
  grep -q 'GIT_CREDENTIALS_ID' "$ROOT/$j" && CREDS=$((CREDS+1))
  grep -q 'GIT_ASKPASS' "$ROOT/$j" && ASKPASS=$((ASKPASS+1))
done
[ "$HARDURL" = 0 ] && ok "aucun git clone d'URL en dur (l'URL vient d'un knob d'env) (4/4)" \
                   || bad "$HARDURL Jenkinsfile(s) clonent encore une URL en dur"
[ "$CREDS" = 4 ] && ok "convention GIT_CREDENTIALS_ID présente (4/4)" \
                 || bad "GIT_CREDENTIALS_ID absent ($CREDS/4)"
[ "$ASKPASS" = 4 ] && ok "créds injectées via GIT_ASKPASS (jamais URL/argv/log) (4/4)" \
                   || bad "helper GIT_ASKPASS absent ($ASKPASS/4)"
URLKNOB=0
for j in ci/Jenkinsfile ci/Jenkinsfile.prod ci/Jenkinsfile.rollback; do
  grep -q 'GOVERNANCE_GIT_URL' "$ROOT/$j" && URLKNOB=$((URLKNOB+1))
done
grep -q 'env.PROJECT_REPO ?:' "$ROOT/../stoa-platform-ci/Jenkinsfile.deploy" && URLKNOB=$((URLKNOB+1))
[ "$URLKNOB" = 4 ] && ok "knob d'URL surchargeable au niveau job (GOVERNANCE_GIT_URL ×3 + PROJECT_REPO) (4/4)" \
                   || bad "knob d'URL manquant ($URLKNOB/4)"

echo "=== É0.4 — release binaire (make release : multi-arch + checksums + SBOM) ==="
RELOUT="$TMP/release.log"
( cd "$ROOT" && make release >"$RELOUT" 2>&1 )
[ $? = 0 ] && ok "make release (air-gapped, GOPROXY=off -mod=vendor) exit 0" \
           || { bad "make release KO"; sed -n '1,20p' "$RELOUT"; }
VERSION="$(cd "$ROOT" && git describe --tags --always --dirty 2>/dev/null || echo 0.1.0-poc)"
DIST="$ROOT/dist/$VERSION"
NBIN="$(find "$DIST" -name '*_linux_*' -o -name '*_darwin_*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$NBIN" = 9 ] && [ -f "$DIST/SHA256SUMS" ] && ls "$DIST"/*.spdx.json >/dev/null 2>&1 \
  && ok "artefacts : 9 binaires (3 outils × 3 archs) + SHA256SUMS + SBOM" \
  || bad "artefacts incomplets dans $DIST ($NBIN binaires)"
file "$DIST/labctl_${VERSION}_linux_amd64" 2>/dev/null | grep -q 'ELF 64-bit.*x86-64' \
  && ok "labctl linux/amd64 est bien un ELF x86-64 (cross-compilé, agent client sans Go)" \
  || bad "labctl linux/amd64 n'est pas un ELF x86-64"
( cd "$DIST" && { command -v sha256sum >/dev/null && sha256sum -c SHA256SUMS || shasum -a 256 -c SHA256SUMS ; } >/dev/null 2>&1 ) \
  && ok "SHA256SUMS vérifie (sha256sum -c) — intégrité contrôlable côté client" \
  || bad "SHA256SUMS ne vérifie pas"
python3 - "$DIST"/*.spdx.json <<'EOF' >/dev/null 2>&1 \
  && ok "SBOM SPDX-2.3 parsable, liste l'app + les modules vendorés (purl golang)" \
  || bad "SBOM invalide ou incomplet"
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["spdxVersion"] == "SPDX-2.3"
purls = [r["referenceLocator"] for p in doc["packages"] for r in p.get("externalRefs", [])]
assert any("pkg:golang/github.com/spf13/cobra@" in u for u in purls), purls
EOF
HOSTBIN="$DIST/labctl_${VERSION}_$(cd "$ROOT/labctl" && go env GOOS)_$(cd "$ROOT/labctl" && go env GOARCH)"
[ -x "$HOSTBIN" ] && [ "$("$HOSTBIN" version)" = "labctl $VERSION" ] \
  && ok "version injectée par ldflags : \`labctl version\` -> $VERSION (traçable au commit)" \
  || bad "version non injectée ($HOSTBIN)"

echo ""; echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
