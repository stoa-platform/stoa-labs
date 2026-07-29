#!/bin/bash
# F4 — enveloppe NON INTERACTIVE des gestes quorum, à exécuter SUR worker-1
# (root), tant que /root/vault-init-ci.txt (600) est encore sur le nœud :
# les 2 clés de descellement y sont lues par sed, passées au script in-pod,
# JAMAIS affichées, jamais dans la session de l'agent.
#   $1 = script in-pod déjà copié dans /tmp/<nom> DU NŒUD (ex: /tmp/f4-wm.sh)
#   $2… = arguments additionnels du script in-pod (ex: revoke | restore)
# Après la passe F4 : récupérer le fichier hors ligne puis `shred -u`
# (action exploitant pendante depuis la re-init du 2026-07-29).
set -eu
F=/root/vault-init-ci.txt
SCRIPT="$1"; shift
test -s "$F" || { echo "ECHEC: $F absent — geste interactif requis"; exit 1; }
test -s "$SCRIPT" || { echo "ECHEC: $SCRIPT absent (scp d'abord)"; exit 1; }
K1=$(sed -n 's/^Unseal Key 1: //p' "$F")
K2=$(sed -n 's/^Unseal Key 2: //p' "$F")
[ -n "$K1" ] && [ -n "$K2" ] || { echo "ECHEC: cles non trouvees dans $F"; exit 1; }
k3s kubectl -n ci exec -i vault-0 -- sh -c 'cat > /tmp/f4q.sh && chmod 700 /tmp/f4q.sh' < "$SCRIPT"
k3s kubectl -n ci exec vault-0 -- sh /tmp/f4q.sh "$K1" "$K2" "$@"
RC=$?
k3s kubectl -n ci exec vault-0 -- rm -f /tmp/f4q.sh
exit $RC
