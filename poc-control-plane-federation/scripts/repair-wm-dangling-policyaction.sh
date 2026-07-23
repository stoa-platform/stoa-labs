#!/usr/bin/env bash
# repair-wm-dangling-policyaction.sh — diagnostic + réparation du NPE
# « Unable to process the PUT/ACTIVATE request for apis … NullPointerException »
# de webMethods API Gateway 10.15.
#
# CAUSE RACINE (établie live le 2026-07-23, corrélation 7/7 cassées vs 2/2 saines) :
#   une policy d'API référence une policyAction SUPPRIMÉE (enforcementObjectId
#   pendant). PUT et ACTIVATE matérialisent la policy → chargent l'action → null
#   → NPE ; le forceDelete, qui saute cette matérialisation, passe. Les APIs
#   touchées restent COINCÉES inactives (activate NPE) — l'état inactif est un
#   SYMPTÔME, pas le déclencheur.
#
# CE QUE FAIT CE SCRIPT (100 % REST admin, aucun accès Elasticsearch — livrable
# tel quel chez un client) :
#   1. GET /policies + GET /policyActions → ensemble des actions RÉSOLUES ;
#   2. pour chaque policy : liste les enforcementObjectId NON résolus (pendants) ;
#   3. mode --fix : PUT de la policy SANS les références pendantes (un stage vidé
#      est retiré). Sans --fix : rapport seul, aucune écriture.
#
# ⚠ APRÈS le --fix, la policy a PERDU les actions pendantes (souvent le stage
# IAM = l'identification !). NE PAS activer l'API en l'état : RE-APPLIQUER
# depuis la source de vérité (labctl apply / rôle Ansible / setup-wm-admin-proxy)
# pour reconverger les actions manquantes, PUIS activer. Le script le rappelle.
#
#   bash scripts/repair-wm-dangling-policyaction.sh          # diagnostic seul
#   bash scripts/repair-wm-dangling-policyaction.sh --fix    # répare
set -uo pipefail

WM="${WM_API_BASE:-http://localhost:5555/rest/apigateway}"
WMUSER="${WM_USER:-Administrator}"; WMPASS="${WM_PASS:-manage}"
FIX=0; [ "${1:-}" = "--fix" ] && FIX=1

say()  { printf '\033[1;36m[wm-policy-repair]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[wm-policy-repair]\033[0m %s\n' "$*"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Basic auth par fichier de config curl — jamais en argv (standard du repo).
printf 'user = "%s:%s"\n' "$WMUSER" "$WMPASS" > "$TMP/auth"
wmcurl() { curl -s -K "$TMP/auth" -H 'Accept: application/json' "$@"; }

wmcurl -o "$TMP/policies.json"      "$WM/policies"      || fail "GET /policies KO"
wmcurl -o "$TMP/policyactions.json" "$WM/policyActions" || fail "GET /policyActions KO"
wmcurl -o "$TMP/apis.json"          "$WM/apis"          || fail "GET /apis KO"

FIX="$FIX" WM="$WM" TMP="$TMP" python3 - <<'PY'
import json, os, subprocess, sys

TMP, WM, FIX = os.environ["TMP"], os.environ["WM"], os.environ["FIX"] == "1"

pol_raw  = json.load(open(f"{TMP}/policies.json"))
policies = pol_raw.get("policy") or pol_raw.get("policies") or []
act_raw  = json.load(open(f"{TMP}/policyactions.json"))
actions  = act_raw.get("policyAction") or act_raw.get("policyActions") or []
apis_raw = json.load(open(f"{TMP}/apis.json"))
apis     = apis_raw.get("apiResponse") or apis_raw.get("apis") or []
known    = {a.get("id") for a in actions}
api_by_pol = {}
for a in apis:
    x = a.get("api", a)
    for pid in x.get("policies") or []:
        api_by_pol.setdefault(pid, []).append("%s v%s (active=%s)" % (x.get("apiName"), x.get("apiVersion"), x.get("isActive")))

print("  %d policies, %d policyActions résolues, %d APIs" % (len(policies), len(actions), len(apis)))
broken = []
for p in policies:
    ghosts = []
    for st in p.get("policyEnforcements") or []:
        for e in st.get("enforcements") or []:
            oid = e.get("enforcementObjectId")
            if oid and oid not in known:
                ghosts.append((st.get("stageKey"), oid))
    if ghosts:
        broken.append((p, ghosts))

if not broken:
    print("  ✓ aucune référence pendante — le NPE ne vient pas d'ici.")
    sys.exit(0)

print("\n  %d policy(ies) avec référence(s) PENDANTE(s) :" % len(broken))
for p, ghosts in broken:
    name = (p.get("names") or [{}])[0].get("value", "?")
    print("   · %s  « %s »" % (p.get("id"), name))
    for stage, oid in ghosts:
        print("       stage %-10s action FANTÔME %s" % (stage, oid))
    # NB : le LISTING /apis n'expose pas le champ `policies` (détail GET seulement) ;
    # le nom de la policy (« Default Policy for API X ») identifie déjà l'API.
    for lbl in api_by_pol.get(p.get("id"), []):
        print("       portée par : %s" % lbl)

if not FIX:
    print("\n  (diagnostic seul — relancer avec --fix pour exciser les références pendantes)")
    sys.exit(2)

print("\n  ── FIX : excision des références pendantes ──")
ok = ko = 0
for p, ghosts in broken:
    ghost_ids = {oid for _, oid in ghosts}
    pe = []
    for st in p.get("policyEnforcements") or []:
        keep = [e for e in (st.get("enforcements") or []) if e.get("enforcementObjectId") not in ghost_ids]
        if keep:
            pe.append({**st, "enforcements": keep})
    p2 = {**p, "policyEnforcements": pe}
    body = f"{TMP}/fix-{p['id']}.json"
    # Enveloppe {"policy": …} OBLIGATOIRE : le corps nu est un no-op silencieux
    # (même piège que policyActions — mémoire wm-1015-rest-shapes).
    json.dump({"policy": p2}, open(body, "w"), ensure_ascii=False)
    r = subprocess.run(["curl", "-s", "-K", f"{TMP}/auth", "-o", f"{TMP}/fix-resp.json",
                        "-w", "%{http_code}", "-X", "PUT",
                        "-H", "Content-Type: application/json",
                        "--data-binary", f"@{body}", f"{WM}/policies/{p['id']}"],
                       capture_output=True, text=True)
    code = r.stdout.strip()
    if code == "200":
        print("   ✓ %s réparée (stages restants : %s)" % (p["id"], [s.get("stageKey") for s in pe]))
        ok += 1
    else:
        print("   ✗ %s : PUT -> HTTP %s" % (p["id"], code)); ko += 1

print("\n  %d réparée(s), %d échec(s)." % (ok, ko))
if ok:
    print("  ⚠ Les policies réparées ont PERDU les actions pendantes (souvent l'IAM).")
    print("    RE-APPLIQUER depuis la source de vérité AVANT toute activation :")
    print("      bash scripts/setup-wm-admin-proxy.sh      (proxies d'admin)")
    print("      bash scripts/demo-multienv.sh             (chaîne accounts-read)")
sys.exit(1 if ko else 0)
PY
