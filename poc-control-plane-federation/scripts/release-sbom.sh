#!/usr/bin/env bash
# release-sbom.sh — SBOM SPDX 2.3 (JSON) des binaires de la release (É0,
# DELIVERY-PROCESS.md §4). Source de vérité : labctl/vendor/modules.txt — la
# liste EXACTE des modules embarqués dans les binaires livrés (build -mod=vendor,
# GOPROXY=off) — plus le module applicatif lui-même. AUCUN outil externe ni accès
# réseau : le SBOM se génère hors zone, au même endroit que le build.
# (Un CI client peut lui substituer syft/cyclonedx-gomod ; le contrat reste :
# 1 release = 1 SBOM qui liste ce qui est réellement dedans.)
#
# Usage : release-sbom.sh <version> <fichier-sortie.spdx.json>
set -euo pipefail

VERSION="${1:?usage: release-sbom.sh <version> <out.spdx.json>}"
OUT="${2:?usage: release-sbom.sh <version> <out.spdx.json>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_TXT="$ROOT/labctl/vendor/modules.txt"
APP_MODULE="$(sed -n 's/^module //p' "$ROOT/labctl/go.mod" | head -1)"
[ -f "$MODULES_TXT" ] || { echo "FATAL: $MODULES_TXT absent (vendor/ requis)"; exit 1; }
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Identifiant SPDX sûr : alnum + . + - uniquement.
spdxid() { printf '%s' "$1" | tr -c 'a-zA-Z0-9.-' '-'; }

{
  printf '{\n'
  printf '  "spdxVersion": "SPDX-2.3",\n'
  printf '  "dataLicense": "CC0-1.0",\n'
  printf '  "SPDXID": "SPDXRef-DOCUMENT",\n'
  printf '  "name": "stoa-poc-binaries-%s",\n' "$VERSION"
  printf '  "documentNamespace": "https://stoa-labs.invalid/spdx/stoa-poc-binaries/%s",\n' "$VERSION"
  printf '  "creationInfo": { "created": "%s", "creators": ["Tool: release-sbom.sh"] },\n' "$CREATED"
  printf '  "documentDescribes": ["SPDXRef-Package-%s"],\n' "$(spdxid "$APP_MODULE")"
  printf '  "packages": [\n'
  printf '    {\n'
  printf '      "name": "%s",\n' "$APP_MODULE"
  printf '      "SPDXID": "SPDXRef-Package-%s",\n' "$(spdxid "$APP_MODULE")"
  printf '      "versionInfo": "%s",\n' "$VERSION"
  printf '      "downloadLocation": "NOASSERTION",\n'
  printf '      "licenseConcluded": "Apache-2.0",\n'
  printf '      "licenseDeclared": "Apache-2.0",\n'
  printf '      "copyrightText": "NOASSERTION"\n'
  printf '    }'
  # modules.txt : chaque module vendoré apparaît en tête de bloc « # <module> <version> ».
  while read -r _hash mod ver _rest; do
    [ -n "${ver:-}" ] || continue
    printf ',\n    {\n'
    printf '      "name": "%s",\n' "$mod"
    printf '      "SPDXID": "SPDXRef-Package-%s",\n' "$(spdxid "$mod-$ver")"
    printf '      "versionInfo": "%s",\n' "$ver"
    printf '      "downloadLocation": "NOASSERTION",\n'
    printf '      "licenseConcluded": "NOASSERTION",\n'
    printf '      "licenseDeclared": "NOASSERTION",\n'
    printf '      "copyrightText": "NOASSERTION",\n'
    printf '      "externalRefs": [{\n'
    printf '        "referenceCategory": "PACKAGE-MANAGER",\n'
    printf '        "referenceType": "purl",\n'
    printf '        "referenceLocator": "pkg:golang/%s@%s"\n' "$mod" "$ver"
    printf '      }]\n'
    printf '    }'
  done < <(grep '^# ' "$MODULES_TXT")
  printf '\n  ]\n}\n'
} > "$OUT"

# Auto-contrôle : le JSON produit doit être parsable et lister 1 + N paquets.
python3 - "$OUT" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
n = len(doc["packages"])
assert n >= 2, f"SBOM suspect: {n} paquet(s) seulement"
print(f"SBOM OK: {sys.argv[1]} ({n} paquets, SPDX-2.3)")
EOF
