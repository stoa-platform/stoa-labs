package governance

import (
	"os"
	"testing"
)

// shippedChainPath is the chain template that ACTUALLY ships (DELIVERY-PROCESS
// §3, couche CONFIG CLIENT). This test exists because that file is the one
// thing standing between a client and the default dev→staging→production
// chain: a typo in it does not fail loudly at deploy time, it fails as "the
// environment is unknown" three layers away. Parsing it here makes the rot
// visible at `go test`, not in a pipeline at 2am.
const shippedChainPath = "../../../clients/_example/environments.yaml"

func TestShippedExampleChain_ParsesAndKeepsItsOrder(t *testing.T) {
	raw, err := os.ReadFile(shippedChainPath)
	if err != nil {
		t.Fatalf("read %s: %v", shippedChainPath, err)
	}
	c, err := ParseEnvChain(raw)
	if err != nil {
		t.Fatalf("ParseEnvChain(%s): %v", shippedChainPath, err)
	}

	// The ORDER is the chain: it is what NextOf walks. Asserting the slice
	// verbatim is the point — a reordering is a silent change of what "the
	// next environment" means.
	want := []string{"dev", "rec", "int", "homol", "prod"}
	if len(c.Envs) != len(want) {
		t.Fatalf("chain = %v, want %v", c.Envs, want)
	}
	for i := range want {
		if c.Envs[i] != want[i] {
			t.Fatalf("chain = %v, want %v", c.Envs, want)
		}
	}

	// prod is terminal, homol precedes it: the two ends of the chain that a
	// bad edit is most likely to break.
	if n, ok := c.NextOf("homol"); !ok || n != "prod" {
		t.Fatalf("NextOf(homol) = %q, %v; want prod, true", n, ok)
	}
	if n, ok := c.NextOf("prod"); ok {
		t.Fatalf("NextOf(prod) = %q, true; prod must be terminal", n)
	}
}

// TestShippedExampleChain_GatesMatchTheStatedPolicy pins the control set of
// every hop. These are not arbitrary values: they are the client's stated
// segregation of duties (dev+rec autonomous, int by another team, homol and
// prod by a third with a stricter process). If someone relaxes a gate, this
// test names WHICH control disappeared rather than letting it pass as a diff.
func TestShippedExampleChain_GatesMatchTheStatedPolicy(t *testing.T) {
	raw, err := os.ReadFile(shippedChainPath)
	if err != nil {
		t.Fatalf("read %s: %v", shippedChainPath, err)
	}
	c, err := ParseEnvChain(raw)
	if err != nil {
		t.Fatalf("ParseEnvChain: %v", err)
	}

	// dev is the chain head: nothing is promoted INTO it, so it carries no gate.
	if _, ok := c.Gates["dev"]; ok {
		t.Errorf("dev must carry no gate (it is the chain head, nothing promotes into it)")
	}

	for _, tc := range []struct {
		env  string
		want Gate
	}{
		// Requester autonomy — selfApproval is DOCUMENTARY (only fourEyes
		// blocks self-approval). Adding fourEyes here is the one-line change
		// that closes the DORA art. 17(1)(b) tension noted in the file.
		{"rec", Gate{To: "rec", SelfApproval: true}},
		{"int", Gate{To: "int", ApproverGroup: "int-team", FourEyes: true, DeployerGroup: "apim-apply-int"}},
		{"homol", Gate{To: "homol", ApproverGroup: "release-team", FourEyes: true, RequirePVRef: true, DeployerGroup: "apim-apply-homol"}},
		{"prod", Gate{
			To: "prod", ApproverGroup: "release-team", FourEyes: true,
			RequireChangeRef: true, RequirePVRef: true, ITSMCheck: true, DeployerGroup: "apim-operator-prod",
		}},
	} {
		got, ok := c.Gates[tc.env]
		if !ok {
			t.Errorf("%s: no gate — this hop would accept anyone holding promotions:approve, requester included", tc.env)
			continue
		}
		if got != tc.want {
			t.Errorf("%s gate:\n got  %+v\n want %+v", tc.env, got, tc.want)
		}
	}

	// Every hop above dev must at least name WHO approves or forbid the
	// requester from doing it himself. Stated as a property so a NEW
	// environment added to the chain cannot slip in ungated.
	for _, e := range c.Envs {
		if e == "dev" {
			continue
		}
		g := c.Gates[e]
		if g.ApproverGroup == "" && !g.FourEyes && !g.SelfApproval {
			t.Errorf("%s: hop is ungated and undocumented — set approverGroup, fourEyes, or an explicit selfApproval", e)
		}
	}

	// Every declared deployerGroup must be PROJECTABLE: a group outside the two
	// verifiable families would ship a gate nothing can check (fail-closed by
	// construction — but we refuse to ship it at all).
	for env, g := range c.Gates {
		if _, err := g.DeployerPolicy(); err != nil {
			t.Errorf("%s: %v", env, err)
		}
	}
}
