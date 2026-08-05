#!/bin/bash
# E1 / D2 — état des lieux CI, LECTURE SEULE : que contient Gitea, et à quoi
# ressemble le job de publication côté Jenkins ?
# Secrets : /root/gitea-ci-pass (0600). Jamais en argv (curl -K -), jamais affichés.
set -eu
umask 077
GP="$(cat /root/gitea-ci-pass)"
K="k3s kubectl -n ci exec -i gitea-0 --"     # le pod gitea a curl ; celui de jenkins non
G="http://localhost:3000/api/v1"
J="http://jenkins.ci.svc.cluster.local:8080"

gapi() {   # gapi <method> <path>
  {
    printf 'url = "%s%s"\n' "$G" "$2"
    printf 'user = "ci:%s"\n' "$GP"
    printf 'request = "%s"\n' "$1"
    printf 'header = "Accept: application/json"\n'
    printf 'silent\n'
    printf 'write-out = "\\n__CODE__%%{http_code}"\n'
  } | $K curl -K - 2>/dev/null
}
japi() {   # japi <path>  (Jenkins, joint depuis le pod gitea)
  {
    printf 'url = "%s%s"\n' "$J" "$1"
    printf 'silent\n'
    printf 'write-out = "\\n__CODE__%%{http_code}"\n'
  } | $K curl -K - 2>/dev/null
}
code_of() { printf '%s' "$1" | sed -n 's/.*__CODE__\([0-9]*\)$/\1/p'; }
body_of() { printf '%s' "$1" | sed 's/__CODE__[0-9]*$//'; }

echo "=== GITEA ==="
r=$(gapi GET /user/orgs); echo "orgs (HTTP $(code_of "$r")) :"
body_of "$r" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (illisible)"); raise SystemExit
for o in d: print("  -", o.get("username"))' 2>/dev/null || true

r=$(gapi GET "/repos/search?limit=50"); echo "dépôts (HTTP $(code_of "$r")) :"
body_of "$r" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (illisible)"); raise SystemExit
for x in d.get("data") or []: print("  -", x.get("full_name"))' 2>/dev/null || true

echo
echo "contenu de banking-demo/accounts-api (branche main) :"
r=$(gapi GET "/repos/banking-demo/accounts-api/contents"); echo "  HTTP $(code_of "$r")"
body_of "$r" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (illisible)"); raise SystemExit
for x in d: print("  -", x.get("path"), x.get("type"))' 2>/dev/null || true

echo
echo "=== JENKINS ==="
r=$(japi "/api/json?tree=jobs[name]"); echo "jobs (HTTP $(code_of "$r")) :"
body_of "$r" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (illisible ou auth requise)"); raise SystemExit
for j in d.get("jobs") or []: print("  -", j.get("name"))' 2>/dev/null || true

echo
echo "config du job publish-accounts (extrait) :"
r=$(japi "/job/publish-accounts/config.xml")
echo "  HTTP $(code_of "$r")"
body_of "$r" | grep -oE "<definition class=\"[^\"]+\"|<scriptPath>[^<]*</scriptPath>|<url>[^<]*</url>" | head -6 | sed 's/^/  /'
