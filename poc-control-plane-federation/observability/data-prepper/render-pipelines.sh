#!/usr/bin/env bash
# render-pipelines.sh — rend pipelines.yaml (gabarit VERSIONNÉ, marqueur
# __FROM_ENV__) vers pipelines.rendered.yaml (gitignored, 0600) : le fichier
# RÉELLEMENT monté dans le conteneur data-prepper (docker-compose.analytics.yml).
#
# Pourquoi ce détour et pas une substitution "native" : Data Prepper ne résout
# AUCUNE variable d'environnement dans pipelines.yaml (ni ${VAR}, ni
# ${env:VAR}, ni ${env.VAR} — vérifié, non documenté, rapporté cassé par
# plusieurs utilisateurs amont ; seul ${{VARIABLE}} existe, alimenté par une
# section `variables` du pipeline, pas par l'environnement). Le mécanisme
# retenu ici reprend celui déjà en place dans
# scripts/setup-wm-admin-proxy.sh (placeholder __FROM_VAULT__ → sed vers un
# fichier temporaire jamais commité) : le gabarit versionné ne porte JAMAIS la
# vraie valeur ; seul le fichier RENDU (hors git) la porte.
#
# Sans OPENSEARCH_PASSWORD : ÉCHEC EXPLICITE, RIEN N'EST ÉCRIT (ni fichier
# vide, ni marqueur littéral, ni ancien rendu silencieusement réutilisé) —
# l'ingestion ne doit jamais démarrer avec un mot de passe vide ou littéral.
#
#   bash observability/data-prepper/render-pipelines.sh
#   docker compose -f docker-compose.poc.yml -f docker-compose.analytics.yml \
#     up -d redpanda opensearch opensearch-dashboards data-prepper
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/pipelines.yaml"
OUT="$DIR/pipelines.rendered.yaml"

OPENSEARCH_PASSWORD="${OPENSEARCH_PASSWORD:?Variable OPENSEARCH_PASSWORD absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
export OPENSEARCH_PASSWORD

# Fichier temporaire HORS dépôt (mktemp SANS répertoire cible : atterrit dans
# $TMPDIR/system, jamais sous observability/data-prepper/) — une interruption
# brutale ne peut donc jamais laisser un fichier portant le vrai mot de passe
# non suivi ET non ignoré DANS le dépôt public.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# python3 (pas sed) : évite tout souci de métacaractères (&, \, délimiteur) du
# mot de passe dans une substitution texte ; le secret passe par l'environnement
# du process enfant, JAMAIS en argv (ADR-074, « jamais en argv »). Substitution
# CIBLÉE sur le champ YAML (pas un remplacement brut du mot __FROM_ENV__ pris
# isolément) : les commentaires du gabarit qui MENTIONNENT __FROM_ENV__ pour le
# documenter restent intacts dans le rendu, le secret n'y est pas dupliqué.
# json.dumps() (pas une concaténation de guillemets) : un scalaire JSON est du
# YAML valide, et ça couvre pour de vrai guillemet, antislash et retour à la
# ligne dans le mot de passe (une concaténation naïve casse le YAML sur les
# deux premiers, et PRODUIT UN YAML VALIDE MAIS UN MOT DE PASSE FAUX sur le
# troisième — le pire des trois, un échec qui ne se voit pas).
( umask 077
  python3 - "$SRC" "$TMP" <<'PY'
import json
import os
import sys

src, out = sys.argv[1], sys.argv[2]
NEEDLE = 'password: "__FROM_ENV__"'
with open(src, encoding="utf-8") as f:
    content = f.read()
n = content.count(NEEDLE)
if n == 0:
    sys.exit(f"aucun champ {NEEDLE!r} trouvé dans {src} — gabarit modifié ? rien n'est rendu.")
replacement = "password: " + json.dumps(os.environ["OPENSEARCH_PASSWORD"])
content = content.replace(NEEDLE, replacement)
with open(out, "w", encoding="utf-8") as f:
    f.write(content)
print(f"  {n} occurrence(s) de {NEEDLE!r} substituée(s)", file=sys.stderr)
PY
)

chmod 600 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT

echo "rendu : $OUT (depuis $SRC, marqueur __FROM_ENV__ substitué, 0600)"
