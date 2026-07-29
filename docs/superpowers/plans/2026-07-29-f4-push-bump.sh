#!/bin/bash
# F4 — pousse un bump horodaté sur banking-demo/accounts-api (déclencheur du
# webhook, sans toucher au fond du manifeste). Exécuté sur worker-1 (root).
#   $1 = message de commit
# Le mot de passe du user `ci` est lu dans /root/gitea-ci-pass (rotation T9) ;
# repli sur l'ancien bootstrap tant que la rotation n'a pas eu lieu.
set -eu
G=http://localhost:30300/api/v1
if [ -s /root/gitea-ci-pass ]; then CRED="ci:$(cat /root/gitea-ci-pass)"; else CRED='ci:ci-bootstrap'; fi
J='Content-Type: application/json'
F=stoa-publish.yaml
CUR=$(curl -s -u "$CRED" "$G/repos/banking-demo/accounts-api/contents/$F")
SHA=$(echo "$CUR" | sed -n 's/.*"sha":"\([^"]*\)".*/\1/p' | head -1)
test -n "$SHA" || { echo "ECHEC: sha de $F introuvable (auth ?)"; exit 1; }
echo "$CUR" | python3 -c '
import json,sys,base64
d=json.load(sys.stdin)
print(base64.b64decode(d["content"]).decode(), end="")' > /tmp/f4-manifest.cur
grep -v '^# bump:' /tmp/f4-manifest.cur > /tmp/f4-manifest.new
printf '# bump: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /tmp/f4-manifest.new
BODY=$(base64 -w0 < /tmp/f4-manifest.new)
curl -s -u "$CRED" -H "$J" -X PUT \
  -d "{\"content\":\"$BODY\",\"message\":\"$1\",\"sha\":\"$SHA\"}" \
  "$G/repos/banking-demo/accounts-api/contents/$F" \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)
sha=d.get("commit",{}).get("sha","")
print("commit:", sha or "ECHEC")
open("/tmp/f4-last-push-sha","w").write(sha)'
rm -f /tmp/f4-manifest.cur /tmp/f4-manifest.new
