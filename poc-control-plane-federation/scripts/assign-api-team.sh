#!/usr/bin/env bash
# assign-api-team.sh — MIGRATION : sortir une API existante de `Default` en
# l'assignant à son équipe propriétaire sur la gateway webMethods.
#
# Pourquoi : depuis le palier 3, le rôle apim_publish_api REFUSE (API_OWNER_MISMATCH)
# qu'une équipe ré-applique une API qui n'appartient qu'à des profils SYSTÈME
# (`Administrators`/`Default`) — `Default` ne vaut pas appartenance. Une API qu'une
# équipe possède légitimement mais qui traîne en Default (héritée d'avant le garde)
# doit donc lui être assignée une fois, par un admin. Les APIs d'INFRA plateforme
# (ex. `provisioning`) se laissent en Default : aucune équipe ne doit les ré-appliquer.
#
# Deux pièges wM 10.15, gérés ici :
#   1. `assetType` est OBLIGATOIRE dans POST /assets/team — sans lui, 200 et
#      l'assignation ne se fait PAS.
#   2. Le POST rend 200 même quand il n'a rien fait — on ne s'y fie jamais :
#      chaque assignation est VÉRIFIÉE par relecture de GET /apis/{id}.
# Idempotent : une API qui porte déjà l'équipe est sautée (no-op annoncé).
#
# Usage :
#   GW=http://localhost:8090 GW_PASS=<motdepasse> ./assign-api-team.sh --list
#   GW=... GW_PASS=... ./assign-api-team.sh --team <nom-équipe> <sélecteur>...
#     sélecteur = nom d'API | nom@version | id de l'API
#
# Auth : GW_USER (défaut Administrator) + GW_PASS. Le mot de passe n'est JAMAIS
# passé en argv (ps-invisible) : il est encodé dans un fichier d'en-tête 0600.
set -uo pipefail
set +x

GW="${GW:?GW requis — base de la gateway, ex. http://localhost:8090}"
GW_USER="${GW_USER:-Administrator}"
GW_PASS="${GW_PASS:?GW_PASS requis — mot de passe admin gateway (jamais passé en argv)}"
BASE="${GW%/}/rest/apigateway"

# Profils système = non-appartenance (miroir de apim_pub_system_profiles du rôle).
SYSTEM_PROFILES="Administrators Default"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/assignteam.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
HDR="$TMP/auth"; : >"$HDR"; chmod 600 "$HDR"
printf 'Authorization: Basic %s\n' \
  "$(printf '%s:%s' "$GW_USER" "$GW_PASS" | base64 | tr -d '\n')" >"$HDR"

gw() { curl -s -m 20 -H @"$HDR" "$@"; }

fail(){ printf '❌ %s\n' "$*" >&2; exit 1; }
ok(){   printf '✅ %s\n' "$*"; }
warn(){ printf '⚠️  %s\n' "$*" >&2; }

is_system_profile(){
  local n="$1" p
  for p in $SYSTEM_PROFILES; do [ "$n" = "$p" ] && return 0; done
  return 1
}

# ---- inventaire ------------------------------------------------------------
list_apis(){
  local body; body="$(gw "$BASE/apis")" || fail "GET /apis injoignable"
  printf '%s' "$body" | SYS="$SYSTEM_PROFILES" python3 -c '
import sys, os, json
sysset = set(os.environ["SYS"].split())
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.exit("réponse /apis illisible : %s" % e)
rows = d.get("apiResponse") or []
if not rows:
    print("(aucune API sur la gateway)"); sys.exit(0)
print("%-34s %-9s %-14s %s" % ("API", "version", "id", "équipes (⚑ = Default-only, non ré-appliable)"))
for r in rows:
    api = r.get("api", {})
    teams = r.get("teams") or api.get("teams") or []
    names = [t.get("name") for t in teams]
    real = [n for n in names if n not in sysset]
    flag = "" if real else "  ⚑"
    print("%-34s %-9s %-14s %s%s" % (
        (api.get("apiName") or "?")[:34], api.get("apiVersion") or "?",
        (api.get("id") or "?")[:14], ", ".join(names) or "(aucune)", flag))
' || fail "parse /apis"
}

# ---- résolution équipe -----------------------------------------------------
resolve_team_uuid(){   # $1 = nom d'équipe → imprime l'UUID sur stdout
  local name="$1" body
  body="$(gw "$BASE/accessProfiles")" || fail "GET /accessProfiles injoignable"
  printf '%s' "$body" | NAME="$name" python3 -c '
import sys, os, json
name = os.environ["NAME"]
d = json.load(sys.stdin)
aps = d.get("accessProfiles") or d.get("accessProfile") or []
for a in aps:
    if a.get("name") == name:
        print(a.get("id") or ""); sys.exit(0)
sys.exit(3)
' || fail "TEAM_INTROUVABLE : aucune équipe (accessProfile) nommée '$name' sur la gateway"
}

# ---- sélection d'une API (nom | nom@version | id) → un ou plusieurs ids -----
resolve_api_ids(){   # $1 = sélecteur → imprime des lignes "id\tname\tversion"
  local sel="$1" body
  body="$(gw "$BASE/apis")" || fail "GET /apis injoignable"
  printf '%s' "$body" | SEL="$sel" python3 -c '
import sys, os, json
sel = os.environ["SEL"]
name, _, ver = sel.partition("@")
d = json.load(sys.stdin)
rows = d.get("apiResponse") or []
hit = []
for r in rows:
    a = r.get("api", {})
    if a.get("id") == sel:                       # sélecteur = id exact
        hit.append((a["id"], a.get("apiName"), a.get("apiVersion"))); continue
    if a.get("apiName") == name and (not ver or a.get("apiVersion") == ver):
        hit.append((a.get("id"), a.get("apiName"), a.get("apiVersion")))
if not hit:
    sys.exit(4)
for i, n, v in hit:
    print("%s\t%s\t%s" % (i, n, v))
' || fail "API_INTROUVABLE : aucun match pour '$sel' (essaie nom, nom@version, ou id)"
}

# team porte-t-elle DÉJÀ cette équipe ? (idempotence + vérif par relecture)
# On matche par NOM d'équipe — c'est la comparaison canonique du rôle
# (apim_publish_api/tasks/team.yml : `pub_team_name in teams|map(name)`), et le
# `id` renvoyé sur le record peut être le nom (mock) ou l'UUID (10.15) selon le cas.
api_has_team(){   # $1 = api id, $2 = nom d'équipe → rc 0 si présent
  local id="$1" tname="$2" body
  body="$(gw "$BASE/apis/$id")" || return 2
  printf '%s' "$body" | TNAME="$tname" python3 -c '
import sys, os, json
tname = os.environ["TNAME"]
d = json.load(sys.stdin)
api = d.get("apiResponse", {}).get("api", d)
teams = d.get("apiResponse", {}).get("teams") or api.get("teams") or []
names = [t.get("name") for t in teams]
sys.exit(0 if tname in names else 1)
'
}

assign_one(){   # $1 id, $2 name, $3 ver, $4 team-name, $5 uuid
  local id="$1" name="$2" ver="$3" tname="$4" uuid="$5"
  if api_has_team "$id" "$tname"; then
    ok "$name@$ver ($id) porte déjà '$tname' — rien à faire (idempotent)"; return 0
  fi
  # POST /assets/team — assetType OBLIGATOIRE (piège 1)
  local rc
  gw -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
     -X POST "$BASE/assets/team" \
     --data "$(printf '{"assetIds":["%s"],"assetType":"API","newTeams":["%s"]}' "$id" "$uuid")" \
     >"$TMP/code" 2>/dev/null
  rc="$(cat "$TMP/code")"
  # Le 200 ne prouve rien (piège 2) : on VÉRIFIE par relecture (par NOM, comme le rôle).
  if api_has_team "$id" "$tname"; then
    ok "$name@$ver ($id) → '$tname' assignée ET confirmée par relecture"
  else
    fail "ASSIGN_UNCONFIRMED : POST rendu HTTP $rc mais la relecture ne voit pas '$tname' sur $name@$ver ($id) — assetType/UUID/droits ? (le POST rend 200 même sans effet)"
  fi
}

# ---- dispatch --------------------------------------------------------------
case "${1:-}" in
  --list|"" )
    list_apis
    printf '\nLes lignes ⚑ ne portent qu%ss profils système : une équipe ne pourra pas les ré-appliquer\ntant qu%sun admin ne lui aura pas assigné l%sAPI. Les APIs d%sinfra plateforme se laissent ainsi.\n' "'e" "'" "'" "'"
    ;;
  --team )
    TEAM="${2:?--team exige un nom d équipe}"; shift 2
    [ "$#" -ge 1 ] || fail "donne au moins un sélecteur d API (nom | nom@version | id)"
    is_system_profile "$TEAM" && fail "TEAM_IS_SYSTEM_PROFILE : '$TEAM' est un profil système — on n assigne pas une API à '$TEAM' (ce n est pas une appartenance)."
    UUID="$(resolve_team_uuid "$TEAM")"
    [ -n "$UUID" ] || fail "TEAM_INTROUVABLE : '$TEAM'"
    ok "équipe '$TEAM' = $UUID"
    # resolve_api_ids est appelé dans le SHELL PRINCIPAL (écrit dans un fichier) :
    # son fail() sur un sélecteur introuvable arrête bien le script (fail-closed).
    # Une substitution de process `< <(...)` masquerait cet échec dans un sous-shell.
    for sel in "$@"; do
      resolve_api_ids "$sel" >"$TMP/ids"
      while IFS=$'\t' read -r id name ver; do
        [ -n "$id" ] || continue
        assign_one "$id" "$name" "$ver" "$TEAM" "$UUID"
      done <"$TMP/ids"
    done
    ;;
  -h|--help )
    sed -n '2,30p' "$0"
    ;;
  * )
    fail "argument inconnu '$1' — voir --help"
    ;;
esac
