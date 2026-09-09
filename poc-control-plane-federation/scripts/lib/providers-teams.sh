#!/usr/bin/env bash
# scripts/lib/providers-teams.sh — QUI EST DÉCLARÉ dans providers.<env>.yml.
#
# LE PROBLÈME (mesuré le 2026-09-09, CI client `ci-app-request`).
# Trois scripts décidaient l'appartenance d'une équipe par un grep TEXTUEL sur
# la forme exacte de la ligne (`  - team: <valeur>`, exactement deux espaces,
# valeur nue, rien après) :
#   provision-request.sh  grep -Fxq -- "  - team: ${REQ_TEAM}"
#   team-request.sh       grep -Eq  "^  - team: ${TEAM}\$"
#   team-apply.sh         grep -Eq  "^  - team: ${TEAM}\$"
# Chez un client dont le fichier — YAML parfaitement valide — indente à quatre
# espaces, met la valeur entre guillemets, laisse un commentaire en fin de
# ligne ou arrive en CRLF, l'équipe DÉCLARÉE était refusée `TEAM_NOT_DECLARED`.
#
# Ce n'était pas une inattention isolée : six autres scripts du même dépôt
# lisent CE MÊME fichier par `yaml.safe_load` (api-request.sh, team-publish.sh,
# team-promote.sh, api-promote-request.sh, api-promote-export.sh, et la lib
# generate-choices.sh). Il y avait donc DEUX AUTORITÉS sur la même question, et
# c'est la textuelle qui décidait du refus. Cette lib supprime la seconde.
#
# CE QUE LE GREP TENAIT, ET QU'IL FAUT CONTINUER DE TENIR. Le `-F` de
# provision-request.sh n'était pas décoratif : la valeur de l'équipe vient d'un
# formulaire, et `team-request.sh`/`team-apply.sh` l'interpolaient, eux, dans
# une ERE — une équipe nommée `.*` y matchait n'importe quelle déclaration.
# Une comparaison de VALEURS (jamais de motifs) ferme cette porte par
# construction : c'est un avantage de la lecture YAML, pas une concession.
#
# FAIL-CLOSED, ET NOMMÉ. « Fichier illisible » et « équipe absente » ne se
# soignent pas pareil — l'un est une panne de la plateforme, l'autre un défaut
# de la demande. Ils sortent donc par deux codes distincts (2 vs 1) et, pour le
# premier, sous un nom : PROVIDERS_PARSE. Les confondre a déjà coûté deux
# allers-retours chez un client.
#
# TOLÉRANCES ASSUMÉES, et pourquoi chacune :
#   - `utf-8-sig` : un BOM en tête de fichier (Windows) casse `yaml.safe_load`
#     sur un fichier autrement parfait, et n'est visible dans aucun affichage.
#   - `.strip()` sur la valeur : une équipe entre guillemets qui traîne un
#     espace (« "fbi " ») est une faute de frappe, jamais une équipe distincte.
#   - une entrée de la liste qui n'est pas un dictionnaire est IGNORÉE, pas une
#     panne : elle ne déclare aucune équipe, elle n'en cache aucune non plus.
#
# USAGE
#   . "$(dirname "$0")/lib/providers-teams.sh"     # ou scripts/lib/… selon l'appelant
#   providers_team_declared <fichier> <équipe>     # rc 0 déclarée · 1 absente · 2 illisible
#   providers_teams_list    <fichier>              # une équipe par ligne · rc 2 illisible
#
# Preuve : scripts/test-providers-teams.sh (hors ligne).

# _providers_read <mode:list|decide> <fichier> [équipe]
_providers_read() {
  local mode="$1" fichier="$2" equipe="${3-}"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "PROVIDERS_PARSE : python3 introuvable — l'appartenance d'équipe ne peut pas être lue" >&2
    return 2
  fi
  # `-r` et non `-f` : un fichier présent mais illisible (droits) doit sortir
  # par le MÊME chemin qu'un fichier absent — un refus nommé, pas « absente ».
  if [ ! -r "$fichier" ]; then
    echo "PROVIDERS_PARSE : ${fichier} illisible ou absent" >&2
    return 2
  fi
  PROV_MODE="$mode" PROV_FILE="$fichier" PROV_TEAM="$equipe" python3 - <<'PY'
import os, sys

mode    = os.environ["PROV_MODE"]
chemin  = os.environ["PROV_FILE"]
demande = os.environ["PROV_TEAM"]

def refus(msg):
    sys.stderr.write("PROVIDERS_PARSE : %s\n" % msg)
    raise SystemExit(2)

try:
    import yaml
except Exception as e:                                    # noqa: BLE001
    refus("module python 'yaml' indisponible (%s)" % e)

try:
    # utf-8-sig : absorbe un BOM Windows, qui casserait le parse sans rien
    # montrer à la relecture. PyYAML normalise CRLF lui-même.
    with open(chemin, encoding="utf-8-sig") as fh:
        doc = yaml.safe_load(fh)
except Exception as e:                                    # noqa: BLE001
    refus("%s n'est pas du YAML lisible — %s" % (chemin, e))

if doc is None:
    doc = {}
if not isinstance(doc, dict):
    refus("%s ne rend pas un dictionnaire au premier niveau (lu : %s)" % (chemin, type(doc).__name__))

entrees = doc.get("providers")
if entrees is None:
    entrees = []
if not isinstance(entrees, list):
    refus("la cle 'providers' de %s n'est pas une liste (lu : %s)" % (chemin, type(entrees).__name__))

equipes = []
for e in entrees:
    if not isinstance(e, dict):
        continue
    t = e.get("team")
    # Seule une CHAINE non vide declare une equipe : `team:` sans valeur rend
    # None, et le confondre avec "" ferait passer une demande sans equipe.
    if isinstance(t, str) and t.strip():
        equipes.append(t.strip())

if mode == "list":
    if equipes:
        sys.stdout.write("\n".join(equipes) + "\n")
    raise SystemExit(0)

# mode decide : comparaison de VALEURS, jamais de motifs.
if not demande.strip():
    raise SystemExit(1)
raise SystemExit(0 if demande.strip() in equipes else 1)
PY
}

# providers_teams_list <fichier> → les équipes déclarées, une par ligne (rc 2 si illisible)
providers_teams_list() { _providers_read list "$1"; }

# providers_team_declared <fichier> <équipe> → 0 déclarée · 1 absente · 2 illisible
providers_team_declared() { _providers_read decide "$1" "$2"; }

# providers_teams_inline <fichier> → les équipes déclarées sur UNE ligne, pour
# un message de refus. Rend « (aucune) » quand la liste est vide et « (illisible) »
# quand le fichier ne se lit pas : un refus ne doit jamais sortir muet.
providers_teams_inline() {
  local l
  l="$(providers_teams_list "$1" 2>/dev/null)" || { printf '(illisible)'; return 0; }
  [ -n "$l" ] || { printf '(aucune)'; return 0; }
  printf '%s' "$l" | tr '\n' ' ' | sed 's/ $//'
}
