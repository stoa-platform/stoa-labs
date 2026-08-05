#!/usr/bin/env python3
"""Les statuts de commit portés dans Gitea — le signal que l'équipe VOIT."""
import base64, json, urllib.request, urllib.error

GITEA = "http://10.43.60.211:3000"
with open("/root/gitea-ci-pass") as fh:
    AUTH = "Basic " + base64.b64encode(f"ci:{fh.read().strip()}".encode()).decode()


def g(path):
    r = urllib.request.Request(f"{GITEA}/api/v1{path}")
    r.add_header("Authorization", AUTH)
    r.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return {"erreur": e.code, "corps": e.read()[:200].decode("utf-8", "replace")}


commits = g("/repos/banking-demo/accounts-api/commits?limit=4")
if isinstance(commits, dict):
    print("commits :", commits); raise SystemExit
for c in commits:
    sha = c["sha"]
    msg = c["commit"]["message"].splitlines()[0][:60]
    st = g(f"/repos/banking-demo/accounts-api/statuses/{sha}")
    states = [(s.get("status") or s.get("state"), s.get("context")) for s in st] if isinstance(st, list) else st
    print(f"  {sha[:8]}  {msg}")
    print(f"            statuts : {states}")
