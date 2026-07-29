#!/bin/bash
# F4 T9 — rotation du mot de passe bootstrap du user Gitea `ci` (dette lot 1,
# portée par F4 : « les identités réelles arrivent »). Exécuté sur worker-1
# (root). Le nouveau mot de passe est frappé ICI et ne quitte jamais le nœud :
# /root/gitea-ci-pass (0600), jamais affiché.
#
# Rayon d'action VÉRIFIÉ avant rotation (2026-07-29) : aucun `imagePullSecrets`
# dans `ci`/`wm`, aucune auth dans /etc/rancher/k3s/registries.yaml, aucun
# secret dockerconfigjson → les tirages d'images du registre Gitea sont
# ANONYMES. Consommateurs réels du mot de passe : les gestes d'exploitation
# (API admin Gitea, `docker login` de worker-3) et les scripts de cette passe.
#
# ⚠ Scripts du lot 1 qui portent l'ancien mot de passe EN DUR (à substituer
# par $(cat /root/gitea-ci-pass) si on les rejoue un jour) :
#   - 2026-07-28-vault-bootstrap.sh        (URL http://ci:ci-bootstrap@gitea…)
#   - 2026-07-28-f1-provision-status-token.sh (en-tête Basic Y2k6Y2ktYm9vdHN0cmFw)
set -eu
umask 077
G=http://localhost:30300/api/v1
NEWF=/root/gitea-ci-pass
[ -s "$NEWF" ] || openssl rand -base64 18 | tr -d '\n' > "$NEWF"
NEW=$(cat "$NEWF")
curl -s -u 'ci:ci-bootstrap' -H 'Content-Type: application/json' -X PATCH \
  -d "{\"login_name\":\"ci\",\"source_id\":0,\"password\":\"$NEW\",\"must_change_password\":false}" \
  "$G/admin/users/ci" -o /tmp/f4-rot.out -w "patch: %{http_code}\n"
head -c 300 /tmp/f4-rot.out; echo
rm -f /tmp/f4-rot.out
# contre-épreuve : l'ancien mot de passe ne passe plus, le nouveau passe
curl -s -u 'ci:ci-bootstrap' -o /dev/null -w "ancien mdp: %{http_code} (401 attendu)\n" "$G/user"
curl -s -u "ci:$NEW" -o /dev/null -w "nouveau mdp: %{http_code} (200 attendu)\n" "$G/user"
# le PAT (probe-status, dans Vault) est un jeton : il doit survivre à la rotation
echo "OK — mot de passe dans $NEWF ; les gestes futurs font : -u \"ci:\$(cat $NEWF)\""
