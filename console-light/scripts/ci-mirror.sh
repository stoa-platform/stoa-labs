#!/usr/bin/env bash
# Phase 0 — miroir Git pour la CI (n'altère PAS le repo stoa-labs réel).
# Construit var/ci-mirror avec le sous-ensemble attendu par ci/Jenkinsfile :
#   poc-control-plane-federation/{labctl(+vendor), apis, targets.cluster.yaml, ci}
# Usage :
#   ci-mirror.sh init                  # (re)construit le miroir + commit initial
#   ci-mirror.sh push <remote-url>     # ajoute/maj le remote origin et pousse main
#   ci-mirror.sh bump <message>        # change déclencheur (description du contrat) + commit + push
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
POC="$(cd "$HERE/../poc-control-plane-federation" && pwd)"
MIRROR="$HERE/var/ci-mirror"
SUB="$MIRROR/poc-control-plane-federation"

case "${1:-}" in
  init)
    rm -rf "$MIRROR"
    mkdir -p "$SUB"
    # labctl avec vendor/ (build air-gapped) — sans caches ni binaires
    rsync -a --exclude '.git' --exclude '*.test' --exclude 'labctl-credentials.txt' \
      "$POC/labctl" "$SUB/"
    rsync -a "$POC/apis" "$SUB/"
    rsync -a "$POC/ci" "$SUB/"
    # envs/ : manifests par environnement (ADR-075) — la boucle hors-prod du
    # Jenkinsfile référence envs/$E/targets.cluster.yaml (proxies wm-admin-{env}).
    rsync -a "$POC/envs" "$SUB/"
    cp "$POC/targets.cluster.yaml" "$SUB/"
    cd "$MIRROR"
    git init -q -b main
    git config user.name "ci-mirror"
    git config user.email "ci@bc.example"
    git add -A
    git commit -q -m "ci: miroir initial du périmètre fédération (labctl vendored + apis + targets + Jenkinsfile)"
    echo "MIRROR_READY $(git rev-parse --short HEAD) ($(git ls-files | wc -l | tr -d ' ') fichiers)"
    ;;
  push)
    cd "$MIRROR"
    git remote remove origin 2>/dev/null || true
    git remote add origin "$2"
    git push -qf -u origin main
    echo "PUSHED $(git rev-parse --short HEAD)"
    ;;
  bump)
    cd "$MIRROR"
    # Changement métier minimal et visible : description du contrat OpenAPI.
    F="poc-control-plane-federation/apis/accounts-read.openapi.yaml"
    printf '\n# change-control: %s — %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${2:-bump}" >> "$F"
    git add "$F"
    git commit -q -m "feat(api): ${2:-bump de démonstration} [via change-control]"
    git push -q origin main
    echo "BUMPED $(git rev-parse --short HEAD)"
    ;;
  *)
    echo "usage: $0 init | push <url> | bump <message>" >&2
    exit 2
    ;;
esac
