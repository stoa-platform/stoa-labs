#!/bin/bash
# E1 / D2 — pousser le MOTEUR (rôle Ansible) dans le dépôt PLATEFORME de Gitea.
#
# POURQUOI UN DÉPÔT SÉPARÉ. Le job de publication doit prendre son moteur
# ailleurs que dans le dépôt de l'équipe : c'est toute la décision D2. Le dépôt
# d'équipe ne fournit plus que ses DONNÉES (contrat OpenAPI + manifeste) ; le
# rôle qui les applique — et les gardes qui les refusent — vivent côté plateforme.
#
# Le mot de passe reste dans /root/gitea-ci-pass (0600) et n'apparaît ni en argv
# ni dans un log : il passe par un ~/.netrc temporaire, supprimé en sortie.
set -eu
umask 077

SRC=/root/e1-pcf                      # copie locale du dépôt (déposée par scp)
WORK=/root/e1-labs-clone
GITEA_IP="${GITEA_IP:-10.43.60.211}"  # ClusterIP épinglée en Git (cf. GOAL socle)
REPO="http://${GITEA_IP}:3000/ci/stoa-labs.git"
HOMEDIR=/root/.e1-home
NETRC="$HOMEDIR/.netrc"

cleanup() { rm -rf "$HOMEDIR"; }
trap cleanup EXIT

[ -d "$SRC" ] || { echo "!! $SRC absent — déposer la copie du dépôt d'abord"; exit 1; }

rm -rf "$HOMEDIR"; mkdir -p "$HOMEDIR"; chmod 700 "$HOMEDIR"
# git lit ~/.netrc via curl : c'est HOME qui décide, pas une variable NETRC.
printf 'machine %s\nlogin ci\npassword %s\n' "$GITEA_IP" "$(cat /root/gitea-ci-pass)" > "$NETRC"
chmod 600 "$NETRC"

rm -rf "$WORK"
GIT_TERMINAL_PROMPT=0 HOME="$HOMEDIR" \
  git -c credential.helper= clone -q "$REPO" "$WORK" 2>&1 | tail -3 || {
    echo "!! clone impossible"; exit 1; }

echo "avant : $(find "$WORK/poc-control-plane-federation" -type f 2>/dev/null | wc -l) fichiers dans poc-control-plane-federation"

rm -rf "$WORK/poc-control-plane-federation"
cp -a "$SRC" "$WORK/poc-control-plane-federation"
find "$WORK/poc-control-plane-federation" -name '.git' -maxdepth 2 -exec rm -rf {} + 2>/dev/null || true

echo "après : $(find "$WORK/poc-control-plane-federation" -type f | wc -l) fichiers"
echo "rôle présent : $(ls "$WORK/poc-control-plane-federation/ansible/roles/apim_publish_api/tasks/" 2>/dev/null | tr '\n' ' ')"

cd "$WORK"
git config user.email "ci@stoa.invalid"
git config user.name "ci"
git add -A
if git diff --cached --quiet; then
  echo "aucun changement à pousser"
else
  git commit -q -m "feat(E1): le moteur de publication vit côté plateforme, pas chez l'équipe

Le job de publication prend désormais le rôle Ansible apim_publish_api ici, et
non un Jenkinsfile du dépôt de l'équipe : c'est ce qui rend la garde d'équipe
opposable (D2). Le dépôt d'équipe ne fournit plus que son contrat et son
manifeste."
  HOME="$HOMEDIR" GIT_TERMINAL_PROMPT=0 git -c credential.helper= push -q origin HEAD 2>&1 | tail -3
  echo "poussé : $(git rev-parse --short HEAD)"
fi
