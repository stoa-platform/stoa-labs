package main

import (
	"net/http"
	"strings"
	"testing"
)

// approveRec drives one dev→rec promotion to approved on the chain fixture
// (selfApproval hop: carol does both ends) and returns its id.
func approveRec(t *testing.T, h http.Handler, carol string) string {
	t.Helper()
	promoID := requestPromotion(t, h, carol,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "rec", "message": "vers rec"})
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", carol,
		map[string]any{"message": "ok"})
	if code != 200 {
		t.Fatalf("approve = %d %v", code, body)
	}
	return promoID
}

func TestRollbackRestoresPreviousState(t *testing.T) {
	// deploy.rec.yaml is SEEDED: the approval is its second commit, so a
	// previous state exists to restore.
	srv, h, fix := newChainServer(t, map[string]string{
		"tenants/banking-demo/apis/payments-initiation/deploy.rec.yaml": chainSeedDeploy,
	}, "")
	carol := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	promoID := approveRec(t, h, carol)

	// Reason is mandatory.
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{}); code != 400 || errCode(body) != "BAD_REQUEST" {
		t.Fatalf("rollback without reason = %d %v", code, body)
	}

	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "régression détectée en rec"})
	if code != 200 {
		t.Fatalf("rollback = %d %v", code, body)
	}
	promo := body["promotion"].(map[string]any)
	if promo["status"] != "rolled_back" || promo["reason"] != "régression détectée en rec" {
		t.Fatalf("rolled_back marker wrong: %v", promo)
	}
	// The restored desired state is the SEED file, verbatim (no commit pin).
	restored := body["restored"].(map[string]any)
	if restored["environment"] != "rec" || restored["version"] != "1.0.0" || restored["commit"] != "" {
		t.Fatalf("restored state wrong: %v", restored)
	}
	repoDir := srv.Store.Repo.Dir
	deployRaw := gitT(t, repoDir, "show", "main:tenants/banking-demo/apis/payments-initiation/deploy.rec.yaml")
	if deployRaw != chainSeedDeploy {
		t.Fatalf("deploy.rec.yaml not restored verbatim:\n%q\nwant\n%q", deployRaw, chainSeedDeploy)
	}
	// Evidence pack committed with the rollback, trailers included.
	evPath, _ := body["evidence"].(string)
	if !strings.HasPrefix(evPath, "evidence/banking-demo/payments-initiation/rollback-") {
		t.Fatalf("evidence path = %q", evPath)
	}
	evRaw := gitT(t, repoDir, "show", "main:"+evPath)
	for _, want := range []string{`"action": "rollback"`, `"reason": "régression détectée en rec"`, `"version": "1.0.0"`} {
		if !strings.Contains(evRaw, want) {
			t.Fatalf("rollback evidence missing %q:\n%s", want, evRaw)
		}
	}
	show := gitT(t, repoDir, "show", "--stat", "--format=%s", "HEAD")
	if !strings.Contains(show, "rollback payments-initiation") || !strings.Contains(show, "deploy.rec.yaml") {
		t.Fatalf("rollback commit shape wrong:\n%s", show)
	}

	// A rolled_back promotion cannot be rolled back again.
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "encore"}); code != 409 || errCode(body) != "NOT_APPROVED" {
		t.Fatalf("double rollback = %d %v", code, body)
	}
}

func TestRollbackWithoutHistoryConflicts(t *testing.T) {
	// deploy.rec.yaml is NOT seeded: the approval commit is its FIRST and only
	// touch — there is no N-1 state to restore.
	_, h, fix := newChainServer(t, nil, "")
	carol := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	promoID := approveRec(t, h, carol)

	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "rien à restaurer pourtant"})
	if code != 409 || errCode(body) != "NO_PREVIOUS_STATE" {
		t.Fatalf("rollback without history = %d %v", code, body)
	}
}

func TestRollbackRequiresApprovedPromotion(t *testing.T) {
	_, h, fix := newChainServer(t, nil, "")
	carol := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	bob := fix.sign(t, "bob", "Bob Approver", "banking-demo", []string{"devops"})
	alice := fix.sign(t, "alice", "Alice Martin", "banking-demo", []string{"tenant-admin"})

	promoID := requestPromotion(t, h, carol,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "rec", "message": "vers rec"})

	// Pending promotion: nothing approved to revert.
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", bob,
		map[string]any{"reason": "trop tôt"})
	if code != 409 || errCode(body) != "NOT_APPROVED" {
		t.Fatalf("rollback of pending = %d %v", code, body)
	}
	// And the permission stays promotions:approve (alice cannot).
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", alice,
		map[string]any{"reason": "essai"}); code != 403 || errCode(body) != "FORBIDDEN" {
		t.Fatalf("rollback without approve permission = %d %v", code, body)
	}
}

// Contre-épreuve G6 (GOAL) : un palier dont le gate exige un change_ref
// l'exige AUSSI au rollback — refus nommé, avant toute lecture d'historique.
func TestRollbackRequiresChangeRefWhenGateDemandsIt(t *testing.T) {
	chain := "environments: [dev, rec]\ngates:\n  - {to: rec, requireChangeRef: true}\n"
	_, h, fix := newChainServer(t, map[string]string{
		"environments.yaml": chain,
		"tenants/banking-demo/apis/payments-initiation/deploy.rec.yaml": chainSeedDeploy,
	}, "")
	carol := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	promoID := requestPromotion(t, h, carol,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "rec",
			"message": "vers rec", "change_ref": "CHG-0007"})
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", carol,
		map[string]any{"message": "ok"}); code != 200 {
		t.Fatalf("approve = %d %v", code, body)
	}
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "régression"}); code != 400 || errCode(body) != "GATE_REFS_REQUIRED" {
		t.Fatalf("rollback sans change_ref = %d %v (attendu 400 GATE_REFS_REQUIRED)", code, body)
	}
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "régression", "change_ref": "CHG-0008"}); code != 200 {
		t.Fatalf("rollback avec change_ref = %d %v", code, body)
	}
}

// Trou de symétrie (spec D3) : à la DEMANDE le change_ref est exigé dès que
// itsmCheck est posé (rien à vérifier sans lui) ; le rollback doit faire de
// même. Ce test ROUGIT sur le code d'avant G6 (seul RequireChangeRef testé).
func TestRollbackChangeRefAlignedWithITSMCheck(t *testing.T) {
	_, itsm := newITSMStub(t, map[string]string{"CHG-0007": "approved"})
	chain := "environments: [dev, rec]\ngates:\n  - {to: rec, itsmCheck: true}\n"
	_, h, fix := newChainServer(t, map[string]string{
		"environments.yaml": chain,
		"tenants/banking-demo/apis/payments-initiation/deploy.rec.yaml": chainSeedDeploy,
	}, itsm.URL)
	carol := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	promoID := requestPromotion(t, h, carol,
		map[string]any{"slug": "payments-initiation", "from": "dev", "to": "rec",
			"message": "vers rec", "change_ref": "CHG-0007"})
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", carol,
		map[string]any{"message": "ok"}); code != 200 {
		t.Fatalf("approve = %d %v", code, body)
	}
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "régression"}); code != 400 || errCode(body) != "GATE_REFS_REQUIRED" {
		t.Fatalf("rollback sans change_ref (gate itsmCheck) = %d %v (attendu 400)", code, body)
	}
}

// Décision D3 (spec) : le pv_ref n'est PAS exigé au rollback — l'état restauré
// a porté le sien quand il a été promu. Chaîne 5 paliers, palier homol pv-only ;
// la restauration est VERBATIM, pin `commit` du N-1 compris.
func TestRollbackHomolPVOnlyRestoresVerbatimPin(t *testing.T) {
	const homolSeed = "version: 0.9.0\nenabled: true\npromoted_by: seed\ncommit: deadbeef00\n"
	chain := "environments: [dev, rec, int, homol, prod]\ngates:\n  - {to: homol, requirePVRef: true}\n"
	srv, h, fix := newChainServer(t, map[string]string{
		"environments.yaml": chain,
		"tenants/banking-demo/apis/payments-initiation/deploy.rec.yaml":   chainSeedDeploy,
		"tenants/banking-demo/apis/payments-initiation/deploy.int.yaml":   chainSeedDeploy,
		"tenants/banking-demo/apis/payments-initiation/deploy.homol.yaml": homolSeed,
	}, "")
	carol := fix.sign(t, "carol", "Carol Admin", "", []string{"cpi-admin"})
	// Garde de la DEMANDE (déjà en place) : sans pv_ref, refus.
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions", carol,
		map[string]any{"slug": "payments-initiation", "from": "int", "to": "homol",
			"message": "vers homol"}); code != 400 || errCode(body) != "GATE_REFS_REQUIRED" {
		t.Fatalf("request homol sans pv_ref = %d %v", code, body)
	}
	promoID := requestPromotion(t, h, carol,
		map[string]any{"slug": "payments-initiation", "from": "int", "to": "homol",
			"message": "vers homol", "pv_ref": "PV-2026-099"})
	if code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/approve", carol,
		map[string]any{"message": "ok"}); code != 200 {
		t.Fatalf("approve = %d %v", code, body)
	}
	// Rollback avec la seule reason : ni change_ref ni pv_ref exigés ici.
	code, body := do(t, h, "POST", "/api/v1/tenants/banking-demo/promotions/"+promoID+"/rollback", carol,
		map[string]any{"reason": "KO recette homol"})
	if code != 200 {
		t.Fatalf("rollback homol = %d %v", code, body)
	}
	restored := body["restored"].(map[string]any)
	if restored["environment"] != "homol" || restored["version"] != "0.9.0" || restored["commit"] != "deadbeef00" {
		t.Fatalf("restored state wrong: %v", restored)
	}
	deployRaw := gitT(t, srv.Store.Repo.Dir, "show", "main:tenants/banking-demo/apis/payments-initiation/deploy.homol.yaml")
	if deployRaw != homolSeed {
		t.Fatalf("deploy.homol.yaml pas restauré verbatim:\n%q\nwant\n%q", deployRaw, homolSeed)
	}
}
