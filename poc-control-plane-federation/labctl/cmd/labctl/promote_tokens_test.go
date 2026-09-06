package cmd

// promote_tokens_test.go — DIVERGENCE #3 (mesurée 2026-09-06).
//
// team-promote.sh:736 affirme, en commentaire, que les trois jetons sont « les
// trois jetons que les DEUX moteurs émettent en clair » et les grep sur le log
// pour composer le résumé de la PR :
//
//	SUMMARY=$(grep -oE '(PROMOTE_CONFIRMED|IMPORT_OK|ARCHIVE_DIGEST_OK)[^"]{0,140}' …)
//
// Mesure : seul PROMOTE_CONFIRMED existe côté Go. IMPORT_OK et
// ARCHIVE_DIGEST_OK ne vivent que dans le rôle Ansible. Le moteur Go rendait
// donc un résumé de PR APPAUVRI, sans que rien ne rougisse.
//
// Et ARCHIVE_DIGEST_OK n'était pas qu'un message manquant : le moteur Go ne
// vérifiait PAS le digest. `archive_sha256` était décodé puis IGNORÉ
// (TestPromoteSpecToleratesPinnedSha le constatait sans s'en émouvoir) —
// `labctl promote --action import` importait les octets présents à --archive
// sans preuve que ce soient ceux qui ont été approuvés. Fail-open sur le
// chemin d'intégrité.

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stoa-platform/stoa-labs/poc/labctl/internal/adapter/webmethods"
)

// shellPromotePath is the caller that greps the tokens out of both engines.
const shellPromotePath = "../../../scripts/team-promote.sh"

func TestArchiveDigest_MismatchRefusesWithNamedCode(t *testing.T) {
	bytes := []byte("les octets rellement prsents")
	want := strings.Repeat("a", 64) // un pin qui ne correspond pas
	tok, err := verifyArchiveDigest(bytes, want, "/tmp/accounts-read.zip")
	if err == nil {
		t.Fatal("un digest qui ne correspond pas DOIT refuser : ce ne sont pas les octets approuvés")
	}
	if !strings.Contains(err.Error(), "ARCHIVE_DIGEST_MISMATCH") {
		t.Errorf("refus = %v, want ARCHIVE_DIGEST_MISMATCH", err)
	}
	if tok != "" {
		t.Errorf("aucun jeton ne doit être émis sur un refus, got %q", tok)
	}
}

func TestArchiveDigest_MatchEmitsToken(t *testing.T) {
	bytes := []byte("les octets approuvs")
	sum := sha256.Sum256(bytes)
	want := hex.EncodeToString(sum[:])
	tok, err := verifyArchiveDigest(bytes, want, "/tmp/accounts-read.zip")
	if err != nil {
		t.Fatalf("les octets SONT ceux du pin : %v", err)
	}
	if !strings.HasPrefix(tok, "ARCHIVE_DIGEST_OK") || !strings.Contains(tok, want) {
		t.Errorf("jeton = %q, want ARCHIVE_DIGEST_OK … %s", tok, want)
	}
}

// TestArchiveDigest_NoPinIsSkipped mirrors the role's guard
// `when: (apim_ss_archive_sha256 | default(”)) | length == 64` — sans pin de
// 64 caractères, il n'y a rien à vérifier et AUCUN jeton n'est émis (émettre
// ARCHIVE_DIGEST_OK sans avoir vérifié serait le pire des deux mondes).
func TestArchiveDigest_NoPinIsSkipped(t *testing.T) {
	for _, want := range []string{"", "trop-court", strings.Repeat("b", 63)} {
		tok, err := verifyArchiveDigest([]byte("x"), want, "/tmp/a.zip")
		if err != nil {
			t.Errorf("pin %q: pas de pin exploitable ⇒ pas de refus, got %v", want, err)
		}
		if tok != "" {
			t.Errorf("pin %q: rien n'a été vérifié ⇒ aucun jeton, got %q", want, tok)
		}
	}
}

func TestImportSummary_MirrorsTheRoleWording(t *testing.T) {
	rows := []webmethods.ImportRow{
		{Type: "API", Status: "Success", Overwritten: true},
		{Type: "Policy", Status: "Success", Overwritten: true},
		{Type: "PolicyAction", Status: "Success", Overwritten: false},
	}
	got := importSummary(rows)
	for _, want := range []string{"IMPORT_OK", "3 asset(s)", "overwrite=2", "création=1"} {
		if !strings.Contains(got, want) {
			t.Errorf("résumé = %q, il manque %q", got, want)
		}
	}
}

// TestPromoteTokensMatchTheShellGrep is the mechanism: it applies the ACTUAL
// regex from team-promote.sh to the lines the Go engine emits, and requires
// the three tokens to be captured. If either side drifts — the Go wording or
// the shell regex — this goes red.
func TestPromoteTokensMatchTheShellGrep(t *testing.T) {
	raw, err := os.ReadFile(shellPromotePath)
	if err != nil {
		t.Fatalf("read %s: %v", shellPromotePath, err)
	}
	// La classe POSIX du grep -oE, transcrite telle quelle.
	re := regexp.MustCompile(`(PROMOTE_CONFIRMED|IMPORT_OK|ARCHIVE_DIGEST_OK)[^"]{0,140}`)
	if !strings.Contains(string(raw), `(PROMOTE_CONFIRMED|IMPORT_OK|ARCHIVE_DIGEST_OK)`) {
		t.Fatalf("%s n'extrait plus ces trois jetons — le contrat des deux moteurs a bougé", shellPromotePath)
	}

	sum := sha256.Sum256([]byte("octets"))
	digestTok, err := verifyArchiveDigest([]byte("octets"), hex.EncodeToString(sum[:]), "/tmp/a.zip")
	if err != nil {
		t.Fatal(err)
	}
	emitted := []string{
		digestTok,
		importSummary([]webmethods.ImportRow{{Type: "API", Status: "Success", Overwritten: true}}),
		"PROMOTE_CONFIRMED: accounts-read v1.0.0 guid=abc active on wm (env \"prod\", 1 assets)",
	}
	for _, line := range emitted {
		if re.FindString(line) == "" {
			t.Errorf("le grep de team-promote.sh ne capture pas la ligne du moteur Go : %q", line)
		}
	}
}

// --- le CÂBLAGE : les deux fonctions ci-dessus doivent être APPELÉES ---------
//
// « Une garde correcte branchée au mauvais endroit — ou débranchée par une
// édition ultérieure — est une garde inexistante » (test-provision-apply-wiring.sh).
// Les tests unitaires au-dessus verdissent même si personne n'appelle ces
// fonctions : ceux-ci pilotent runPromote --action import contre une fausse
// gateway et exigent le refus AVANT toute écriture.

func makeZip(t *testing.T, name, content string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	f, err := zw.Create(name)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write([]byte(content)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// runPromoteImportAgainst drives a real --action import against a fake gateway.
func runPromoteImportAgainst(t *testing.T, zipBytes []byte, pinnedSHA string) (string, error, *[]string) {
	t.Helper()
	const guid = "99999999-8888-7777-6666-555555555555"
	calls := &[]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*calls = append(*calls, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/rest/apigateway/archive":
			fmt.Fprint(w, `{"ArchiveResult":[{"API":{"id":"`+guid+`","name":"g8imp-api","status":"Success","overwritten":true}},`+
				`{"Policy":{"id":"p1","name":"pol","status":"Success","overwritten":false}}]}`)
		case strings.HasPrefix(r.URL.Path, "/rest/apigateway/apis/"):
			fmt.Fprint(w, `{"apiResponse":{"api":{"id":"`+guid+`","apiName":"g8imp-api","apiVersion":"1.0.0","isActive":true}}}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	dir := t.TempDir()
	archive := filepath.Join(dir, "g8imp.zip")
	if err := os.WriteFile(archive, zipBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	manifest := filepath.Join(dir, "m.promote.yml")
	if err := os.WriteFile(manifest, []byte(`apim_promote:
  name: "g8imp-api"
  version: "1.0.0"
  guid: "`+guid+`"
  archive: "`+archive+`"
  archive_sha256: "`+pinnedSHA+`"
  overwrite: "apis,policies,policyactions"
`), 0o600); err != nil {
		t.Fatal(err)
	}
	contract := filepath.Join(dir, "contract.yaml")
	if err := os.WriteFile(contract, []byte("openapi: 3.0.0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	targetsF := filepath.Join(dir, "targets.yaml")
	if err := os.WriteFile(targetsF, []byte(`apiVersion: labctl.stoa.io/v1
kind: FederationTarget
name: g8imp
contract: `+contract+`
targets:
  - name: wm
    type: webmethods
    adminUrl: `+srv.URL+`
    gatewayUrl: `+srv.URL+`
    credentials: { username: u, password: p }
`), 0o600); err != nil {
		t.Fatal(err)
	}

	savedManifest, savedAction, savedEnv, savedTarget, savedArchive, savedFile :=
		promoteManifestFlag, promoteActionFlag, promoteEnvFlag, promoteTargetFlag, promoteArchiveFlag, fileFlag
	t.Cleanup(func() {
		promoteManifestFlag, promoteActionFlag, promoteEnvFlag, promoteTargetFlag, promoteArchiveFlag, fileFlag =
			savedManifest, savedAction, savedEnv, savedTarget, savedArchive, savedFile
	})
	promoteManifestFlag, promoteActionFlag, promoteEnvFlag = manifest, "import", ""
	promoteTargetFlag, promoteArchiveFlag, fileFlag = "", "", targetsF

	out := new(strings.Builder)
	promoteCmd.SetOut(out)
	promoteCmd.SetContext(context.Background())
	err := runPromote(promoteCmd, nil)
	return out.String(), err, calls
}

// TestPromoteImport_WrongDigestRefusesBeforeAnyWrite is the one that matters:
// the pinned digest must be checked BEFORE the gateway is touched at all.
func TestPromoteImport_WrongDigestRefusesBeforeAnyWrite(t *testing.T) {
	z := makeZip(t, "APIs/g8imp.json", "{}")
	_, err, calls := runPromoteImportAgainst(t, z, strings.Repeat("c", 64))
	if err == nil || !strings.Contains(err.Error(), "ARCHIVE_DIGEST_MISMATCH") {
		t.Fatalf("des octets qui ne sont pas ceux du pin doivent être refusés, got %v", err)
	}
	if len(*calls) != 0 {
		t.Errorf("la gateway a été touchée AVANT le refus de digest : %v — le contrôle d'intégrité doit être mécaniquement antérieur", *calls)
	}
}

func TestPromoteImport_EmitsTheThreeTokens(t *testing.T) {
	z := makeZip(t, "APIs/g8imp.json", "{}")
	sum := sha256.Sum256(z)
	out, err, _ := runPromoteImportAgainst(t, z, hex.EncodeToString(sum[:]))
	if err != nil {
		t.Fatalf("import nominal : %v", err)
	}
	for _, want := range []string{"ARCHIVE_DIGEST_OK", "IMPORT_OK", "2 asset(s)", "overwrite=1", "création=1", "PROMOTE_CONFIRMED"} {
		if !strings.Contains(out, want) {
			t.Errorf("la sortie du moteur Go ne porte pas %q — le résumé de PR reste appauvri\n--- sortie ---\n%s", want, out)
		}
	}
}
