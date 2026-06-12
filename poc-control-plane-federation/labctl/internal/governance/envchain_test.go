package governance

import (
	"strings"
	"testing"
)

func TestDefaultEnvChainMatchesHistoricalBehaviour(t *testing.T) {
	c := DefaultEnvChain()
	if strings.Join(c.Envs, ",") != "dev,staging,production" {
		t.Errorf("Envs = %v, want the historical chain", c.Envs)
	}
	g, ok := c.Gates["production"]
	if !ok || !g.FourEyes {
		t.Errorf("production gate = %+v, want FourEyes (verbatim default)", g)
	}
	if g, ok := c.Gates["staging"]; ok {
		t.Errorf("staging must carry no gate by default, got %+v", g)
	}
	if c.First() != "dev" {
		t.Errorf("First() = %q, want dev", c.First())
	}
	if next, ok := c.NextOf("dev"); !ok || next != "staging" {
		t.Errorf("NextOf(dev) = %q,%v", next, ok)
	}
	if next, ok := c.NextOf("staging"); !ok || next != "production" {
		t.Errorf("NextOf(staging) = %q,%v", next, ok)
	}
	if _, ok := c.NextOf("production"); ok {
		t.Errorf("production is terminal")
	}
	if _, ok := c.NextOf("nope"); ok {
		t.Errorf("unknown env has no next")
	}
	if c.HopsString() != "dev→staging, staging→production" {
		t.Errorf("HopsString() = %q", c.HopsString())
	}
}

func TestParseEnvChain(t *testing.T) {
	c, err := ParseEnvChain([]byte(`environments: [dev, rec, int, prod]
gates:
  - {to: rec, selfApproval: true}
  - {to: int, approverGroup: integration-team}
  - {to: prod, fourEyes: true, requireChangeRef: true, requirePVRef: true, itsmCheck: true}
`))
	if err != nil {
		t.Fatalf("ParseEnvChain: %v", err)
	}
	if strings.Join(c.Envs, ",") != "dev,rec,int,prod" {
		t.Errorf("Envs = %v", c.Envs)
	}
	if g := c.Gates["prod"]; !g.FourEyes || !g.RequireChangeRef || !g.RequirePVRef || !g.ITSMCheck {
		t.Errorf("prod gate misparsed: %+v", g)
	}
	if g := c.Gates["int"]; g.ApproverGroup != "integration-team" || g.FourEyes {
		t.Errorf("int gate misparsed: %+v", g)
	}
	if g := c.Gates["rec"]; !g.SelfApproval {
		t.Errorf("rec gate misparsed: %+v", g)
	}
}

func TestParseEnvChainFailsClosed(t *testing.T) {
	cases := map[string]string{
		"empty environments": "environments: []\n",
		"duplicate env":      "environments: [dev, dev]\n",
		"gate unknown env":   "environments: [dev, prod]\ngates: [{to: staging}]\n",
		"duplicate gate":     "environments: [dev, prod]\ngates: [{to: prod}, {to: prod}]\n",
		"malformed":          "environments: [dev\n",
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseEnvChain([]byte(body)); err == nil {
				t.Errorf("ParseEnvChain must fail on %s", name)
			}
		})
	}
}
