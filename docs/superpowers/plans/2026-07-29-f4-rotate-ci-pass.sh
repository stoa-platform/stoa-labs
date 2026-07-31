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
# Rejouable : le script lit le mot de passe COURANT dans /root/gitea-ci-pass
# pour s'authentifier, et y écrit le nouveau. Aucun identifiant en dur — les
# deux scripts du lot 1 qui en portaient un (2026-07-28-vault-bootstrap.sh,
# 2026-07-28-f1-provision-status-token.sh) calculent désormais leur en-tête
# Basic depuis ce même fichier.
set -eu
umask 077
G=http://localhost:30300/api/v1
NEWF=/root/gitea-ci-pass
[ -s "$NEWF" ] || { echo "ECHEC : $NEWF absent — mot de passe courant inconnu"; exit 1; }
OLD=$(cat "$NEWF")
NEW=$(openssl rand -base64 18 | tr -d '\n')
CODE=$(curl -s -u "ci:$OLD" -H 'Content-Type: application/json' -X PATCH \
  -d "{\"login_name\":\"ci\",\"source_id\":0,\"password\":\"$NEW\",\"must_change_password\":false}" \
  "$G/admin/users/ci" -o /tmp/f4-rot.out -w '%{http_code}')
echo "patch: $CODE"
head -c 300 /tmp/f4-rot.out; echo
rm -f /tmp/f4-rot.out
# n'écrire le nouveau mdp QUE si Gitea l'a accepté : sinon le fichier
# désignerait un mot de passe inactif → plus aucun geste ne s'authentifie.
[ "$CODE" = "200" ] || { echo "ECHEC : rotation refusée ($CODE) — $NEWF inchangé"; exit 1; }
printf '%s' "$NEW" > "$NEWF"
# contre-épreuve : l'ancien mot de passe ne passe plus, le nouveau passe
curl -s -u "ci:$OLD" -o /dev/null -w "ancien mdp: %{http_code} (401 attendu)\n" "$G/user"
curl -s -u "ci:$NEW" -o /dev/null -w "nouveau mdp: %{http_code} (200 attendu)\n" "$G/user"
# le PAT (probe-status, dans Vault) est un jeton : il doit survivre à la rotation
echo "OK — mot de passe dans $NEWF ; les gestes futurs font : -u \"ci:\$(cat $NEWF)\""
