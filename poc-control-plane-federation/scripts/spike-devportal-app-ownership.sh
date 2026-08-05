#!/usr/bin/env bash
# spike-devportal-app-ownership.sh — « la personne part, on ne peut plus récupérer
# le mot de passe de l'application ». Suite de CARACTÉRISATION : chaque test
# épingle un comportement OBSERVÉ live sur wM 10.15 (2026-08-04). Si un test
# casse un jour, c'est que le produit a changé et que le design doit être
# ré-examiné.
#
# ─── LA QUESTION, ET POURQUOI LA RÉPONSE ÉVIDENTE EST FAUSSE ────────────────
#
# Question posée : sur le Developer Portal 10.15 l'owner d'une application n'est
# plus modifiable ; peut-on au moins l'affecter à une TEAM, pour qu'un départ
# n'emporte pas l'accès au credential ?
#
# La réponse intuitive — « assigner la team avec /assets/team » — est FAUSSE, et
# c'est le cœur de ce spike. Il y a DEUX gestes DISTINCTS, souvent confondus :
#
#   /assets/team   → QUI VOIT et QUI GÈRE l'application (cloisonnement).
#   /assets/owner  → QUI LIT LE SECRET en clair.
#
# La lisibilité du credential suit l'OWNER, jamais les teams[]. Une application
# parfaitement cloisonnée sur la bonne équipe mais restée en propriété
# INDIVIDUELLE devient illisible POUR TOUT LE MONDE — y compris l'Administrator —
# dès que son propriétaire est supprimé (T9). C'est exactement le scénario
# redouté par le client, et /assets/team ne le protège pas.
#
# ─── LES DEUX PIÈGES DE CE SPIKE ────────────────────────────────────────────
#
# 1. ⚠ FAIL-OPEN SUR LE NOM D'ÉQUIPE (T7). `POST /assets/owner` avec
#    ownerType=team et le NOM de l'équipe répond 200, et la RELECTURE renvoie
#    owner=<nom> / ownerType=team — tout paraît juste. Mais les membres de
#    l'équipe ne lisent PAS le secret : l'appartenance n'est pas fonctionnelle.
#    Seul l'UUID de l'accessProfile marche. La relecture de owner/ownerType NE
#    PROUVE DONC RIEN : la seule porte de preuve est « un membre lit-il la clé ».
#    (Même famille que le no-op silencieux de /assets/team sans assetType, mais
#     pire : ici la relecture confirme un état faux.)
#
# 2. L'ADMINISTRATOR N'EST PAS UN LECTEUR PRIVILÉGIÉ (T4). Le compte
#    Administrator voit la clé MASQUÉE dès qu'il n'est ni owner ni membre de
#    l'équipe propriétaire. « On demandera à l'admin » n'est pas un plan de
#    secours.
#
# ─── CÔTÉ DEVELOPER PORTAL : DEUX MODES SELON LA LICENCE ────────────────────
#
# T12-T13 sont READ-ONLY (surface REST). T14 est un GATE : il POste une team et
# regarde ce que répond la licence.
#   - 406 « Valid license is missing » (l'image trial du lab, licence expirée
#     2022/10/30) → le volet ÉCRITURE T15-T20 est SKIPPED, proprement, sans
#     compter en échec. C'est l'état attendu sur le lab.
#   - 2xx (instance licenciée, chez le client) → T15-T20 se déroulent : c'est le
#     scénario « self-service d'équipe SANS compte de service » à valider :
#       T15 users+teams portail, T16 exclusion avant share, T17 share vers la
#       team → LE test décisif : un membre voit-il l'app ET ses credentials ;
#       T18 garde « team du owner » ; T19 forçage du share par l'admin ;
#       T20 cascade à la suppression du compte owner (possédée détruite,
#       partagée survit).
#
# ⚠ SHAPES BEST-EFFORT : les payloads d'écriture du portail (users, teams,
# linkUsers, share) sont dérivés du bytecode et des conventions du produit,
# PAS d'une mesure (la licence du lab bloque tout). Les helpers tentent
# plusieurs shapes (POST/PUT, tableau nu / objet enveloppé) et la preuve est
# TOUJOURS une RELECTURE, jamais le code retour du write. Un 400 persistant sur
# site = shape à ajuster, pas une réfutation du comportement.
#
# BANC D'ESSAI : gateway 10.15 poc-webmethods-real avec enableTeamWork=true
# (extended setting ; l'activation REDÉMARRE la gateway et bascule tous les
# assets existants en [Administrators, Default]).
#
# Assets JETABLES : users spikeown-*, groupe/accessProfile spikeown-team-*,
# applications spikeown-* ; tout est détruit en sortie (trap).
#
#   GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage \
#   DP_BASE=http://localhost:18103/portal ./scripts/spike-devportal-app-ownership.sh
set -u

GW="${GW_ADMIN:-http://localhost:5555/rest/apigateway}"
AUTH="${WM_USER:-Administrator}:${WM_PASS:-manage}"
DP="${DP_BASE:-http://localhost:18103/portal}"
DP_AUTH="${DP_USER:-Administrator}:${DP_PASS:-manage}"
PW="${SPIKE_PW:-Spike!2026}"

PASS=0; FAIL=0
say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

adm()  { curl -sS -m 60 -u "$AUTH" -H "Accept: application/json" -H "Content-Type: application/json" "$@"; }
as()   { local who="$1"; shift; curl -sS -m 60 -u "$who:$PW" -H "Accept: application/json" -H "Content-Type: application/json" "$@"; }
code() { curl -sS -m 60 -o /dev/null -w '%{http_code}' "$@"; }
jq_()  { python3 -c "$1"; }

# Lit la clé d'API telle que la VOIT une identité donnée. Rend la valeur, ou
# MASQUEE, ou REFUS. C'est l'oracle central du spike : ni le code HTTP ni la
# relecture de `owner` ne disent la vérité, seule cette lecture le fait.
key_as() {
  local who="$1" app="$2" out
  out=$(curl -sS -m 60 -u "$who:$PW" -H "Accept: application/json" "$GW/applications/$app" 2>/dev/null)
  printf '%s' "$out" | jq_ "
import sys,json
try:
    d=json.load(sys.stdin)
    a=(d.get('applications') or [d])[0]
    k=a.get('accessTokens',{}).get('apiAccessKey_credentials',{}).get('apiAccessKey')
    print('MASQUEE' if k and set(k)=={'*'} else (k or 'ABSENTE'))
except Exception:
    print('REFUS')"
}
teams_of() { adm "$GW/applications/$1" | jq_ "
import sys,json;a=(json.load(sys.stdin).get('applications') or [{}])[0]
print(','.join(sorted(t.get('name','') for t in (a.get('teams') or []))))"; }
owner_of() { adm "$GW/applications/$1" | jq_ "
import sys,json;a=(json.load(sys.stdin).get('applications') or [{}])[0]
print(str(a.get('owner'))+'/'+str(a.get('ownerType')))"; }

U_ALICE=""; U_BOB=""; U_MALLORY=""; U_CAROL=""
G_BANK=""; G_PAY=""; AP_BANK=""; AP_PAY=""
APP1=""; APP2=""; APP3=""
# Volet portail en écriture (T15-T20) — peuplé seulement si la licence l'autorise.
DP_WRITE=0; SKIPPED=""
P_ALICE=""; P_BOB=""; P_MALLORY=""; P_TEAM_A=""; P_TEAM_B=""
P_APP1=""; P_APP2=""; P_APP3=""

cleanup() {
  say "CLEANUP"
  if [ "$DP_WRITE" = 1 ]; then
    # Portail d'abord : supprimer les users en dernier (leur suppression cascade
    # sur leurs apps possédées — c'est même l'objet de T20).
    for a in "$P_APP1" "$P_APP2" "$P_APP3"; do
      [ -n "$a" ] && dpw "$DP_AUTH" "applications/$a" -X DELETE -o /dev/null >/dev/null 2>&1
    done
    for t in "$P_TEAM_A" "$P_TEAM_B"; do
      [ -n "$t" ] && dpw "$DP_AUTH" "teams/$t" -X DELETE -o /dev/null >/dev/null 2>&1
    done
    for u in "$P_ALICE" "$P_BOB" "$P_MALLORY"; do
      [ -n "$u" ] && dpw "$DP_AUTH" "users/$u" -X DELETE -o /dev/null >/dev/null 2>&1
    done
    local prest
    prest=$(dpw "$DP_AUTH" "applications" 2>/dev/null | jq_ "
import sys,json
try: print(len([a for a in json.load(sys.stdin).get('result',[]) if str(a.get('name','')).startswith('spikeown-')]))
except Exception: print('?')")
    [ "$prest" = "0" ] && echo "  cleanup portail vérifié : 0 app spikeown-* résiduelle" \
                       || echo "  ⚠ RÉSIDU portail : $prest app(s) spikeown-* — à purger à la main"
  fi
  for a in "$APP1" "$APP2" "$APP3"; do
    [ -n "$a" ] && adm -o /dev/null -X DELETE "$GW/applications/$a" >/dev/null 2>&1
  done
  for u in "$U_ALICE" "$U_BOB" "$U_MALLORY" "$U_CAROL"; do
    [ -n "$u" ] && adm -o /dev/null -X DELETE "$GW/users/$u" >/dev/null 2>&1
  done
  for p in "$AP_BANK" "$AP_PAY"; do
    [ -n "$p" ] && adm -o /dev/null -X DELETE "$GW/accessProfiles/$p" >/dev/null 2>&1
  done
  for g in "$G_BANK" "$G_PAY"; do
    [ -n "$g" ] && adm -o /dev/null -X DELETE "$GW/groups/$g" >/dev/null 2>&1
  done
  local rest
  rest=$(adm "$GW/applications" | jq_ "
import sys,json
print(len([a for a in json.load(sys.stdin).get('applications',[]) if a.get('name','').startswith('spikeown-')]))" 2>/dev/null || echo '?')
  [ "$rest" = "0" ] && echo "  cleanup vérifié : 0 application spikeown-* résiduelle" \
                    || echo "  ⚠ RÉSIDU : $rest application(s) spikeown-* — à purger à la main"
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
say "PRÉ-REQUIS : feature Teams active sur la gateway"
TW=$(adm "$GW/configurations/extended" | jq_ "
import sys,re;m=set(re.findall(r'\"enableTeamWork\"\s*:\s*\"?(\w+)',sys.stdin.read()));print('true' if m=={'true'} else 'false')")
if [ "$TW" = "true" ]; then ok "enableTeamWork=true"
else
  ko "enableTeamWork=$TW — activer : PUT $GW/configurations/extended {\"enableTeamWork\":\"true\"}"
  echo "     (l'activation REDÉMARRE la gateway ; attendre son retour avant de rejouer)"
  exit 1
fi

say "SETUP : deux équipes, quatre utilisateurs"
mkuser() {
  adm -X POST "$GW/users" -d "{\"loginId\":\"$1\",\"firstName\":\"$1\",\"lastName\":\"spikeown\",
   \"password\":\"$PW\",\"type\":\"local\",\"active\":true,\"allowDigestAuth\":false,
   \"emailAddresses\":[\"$1@bank.invalid\"]}" | jq_ "import sys,json;print(json.load(sys.stdin).get('id',''))"
}
U_ALICE=$(mkuser spikeown-alice); U_BOB=$(mkuser spikeown-bob)
U_MALLORY=$(mkuser spikeown-mallory); U_CAROL=$(mkuser spikeown-carol)
mkgroup() {
  adm -X POST "$GW/groups" -d "{\"name\":\"$1\",\"description\":\"spike ownership\",\"type\":\"local\",\"userIds\":[$2]}" \
   | jq_ "import sys,json;print(json.load(sys.stdin).get('id',''))"
}
G_BANK=$(mkgroup spikeown-team-a-devs "\"$U_ALICE\",\"$U_BOB\",\"$U_CAROL\"")
G_PAY=$(mkgroup spikeown-team-b-devs "\"$U_MALLORY\"")
# privilege : la valeur relevée sur une team existante du lab (Manage APIs +
# Act/Deact + Manage applications). Une team EST un accessProfile.
PRIV=111100101101100000001
mkap() {
  adm -X POST "$GW/accessProfiles" -d "{\"name\":\"$1\",\"description\":\"spike ownership\",
   \"systemDefined\":false,\"includeTeamAdminsAsApprovers\":false,\"privilege\":\"$PRIV\",\"groupIds\":[\"$2\"]}" \
   | jq_ "import sys,json;print(json.load(sys.stdin).get('id',''))"
}
AP_BANK=$(mkap spikeown-team-a "$G_BANK"); AP_PAY=$(mkap spikeown-team-b "$G_PAY")
[ -n "$AP_BANK" ] && [ -n "$AP_PAY" ] && ok "équipes spikeown-team-a / -b créées" || { ko "création des équipes"; exit 1; }

mkapp() {
  as "$1" -X POST "$GW/applications" -d "{\"name\":\"$2\",\"description\":\"spike ownership\",
   \"contactEmails\":[\"$1@bank.invalid\"],\"identifiers\":[],\"siteURLs\":[],\"jsOrigins\":[]}" \
   | jq_ "import sys,json;print(json.load(sys.stdin).get('id',''))"
}
APP1=$(mkapp spikeown-alice spikeown-app-team)
APP2=$(mkapp spikeown-alice spikeown-app-nom)
APP3=$(mkapp spikeown-carol spikeown-app-userowned)

# ─────────────────────────────────────────────────────────────────────────────
say "T1 — une application créée par un membre d'équipe N'HÉRITE PAS de sa team"
T=$(teams_of "$APP1")
[ "$T" = "Administrators,Default" ] && ok "teams=[$T] — la team du créateur n'est PAS posée" \
  || ko "teams=[$T] — attendu Administrators,Default"

say "T2 — AVANT assignation, une équipe TIERCE voit l'application (la brèche)"
C=$(code -u "spikeown-mallory:$PW" -H "Accept: application/json" "$GW/applications/$APP1")
[ "$C" = "200" ] && ok "mallory (équipe B) lit l'app en Default : HTTP $C — brèche confirmée" \
  || ko "mallory : HTTP $C (attendu 200 : tant que Default est là, tout le monde voit)"

say "T3 — /assets/team cloisonne : l'équipe tierce perd voir ET supprimer"
adm -o /dev/null -X POST "$GW/assets/team" \
  -d "{\"assetIds\":[\"$APP1\"],\"assetType\":\"Application\",\"newTeams\":[\"$AP_BANK\"]}"
T=$(teams_of "$APP1")
case "$T" in *spikeown-team-a*) H=1;; *) H=0;; esac
case "$T" in *Default*) D=1;; *) D=0;; esac
[ "$H" = 1 ] && [ "$D" = 0 ] && ok "teams=[$T] : team posée ET Default retirée" || ko "teams=[$T]"
CG=$(code -u "spikeown-mallory:$PW" -H "Accept: application/json" "$GW/applications/$APP1")
CD=$(code -u "spikeown-mallory:$PW" -H "Accept: application/json" -X DELETE "$GW/applications/$APP1")
CW=$(code -u "$AUTH" -H "Accept: application/json" "$GW/applications/$APP1")
[ "$CG" = 401 ] && [ "$CD" = 401 ] && [ "$CW" = 200 ] \
  && ok "mallory GET=$CG DELETE=$CD ; témoin admin=$CW (la suppression n'a PAS eu lieu)" \
  || ko "GET=$CG DELETE=$CD témoin=$CW (attendu 401/401/200)"

say "T4 — la clé n'est lisible QUE par l'owner : ni l'admin, ni un coéquipier"
KA=$(key_as spikeown-alice "$APP1"); KB=$(key_as spikeown-bob "$APP1")
KM=$(adm "$GW/applications/$APP1" | jq_ "
import sys,json;a=(json.load(sys.stdin).get('applications') or [{}])[0]
k=a.get('accessTokens',{}).get('apiAccessKey_credentials',{}).get('apiAccessKey')
print('MASQUEE' if k and set(k)=={'*'} else (k or 'ABSENTE'))")
[ "$KA" != "MASQUEE" ] && [ "$KB" = "MASQUEE" ] && [ "$KM" = "MASQUEE" ] \
  && ok "owner=alice lit ; bob (même équipe)=MASQUEE ; Administrator=MASQUEE" \
  || ko "alice=$KA bob=$KB admin=$KM"

say "T5 — /assets/owner change réellement l'owner, et LE SECRET SUIT"
adm -o /dev/null -X POST "$GW/assets/owner" \
  -d "{\"assetIds\":[\"$APP1\"],\"assetType\":\"Application\",\"newOwner\":\"spikeown-bob\"}"
O=$(owner_of "$APP1"); KA=$(key_as spikeown-alice "$APP1"); KB=$(key_as spikeown-bob "$APP1")
[ "$O" = "spikeown-bob/user" ] && [ "$KB" != "MASQUEE" ] && [ "$KA" = "MASQUEE" ] \
  && ok "owner=$O ; bob lit désormais, alice ne lit plus" || ko "owner=$O alice=$KA bob=$KB"

say "T6 — LA RÉPONSE : owner = une TEAM (ownerType=team + UUID)"
adm -o /dev/null -X POST "$GW/assets/owner" \
  -d "{\"assetIds\":[\"$APP1\"],\"assetType\":\"Application\",\"newOwner\":\"$AP_BANK\",\"ownerType\":\"team\"}"
O=$(owner_of "$APP1"); KA=$(key_as spikeown-alice "$APP1"); KB=$(key_as spikeown-bob "$APP1")
CM=$(code -u "spikeown-mallory:$PW" -H "Accept: application/json" "$GW/applications/$APP1")
[ "$O" = "$AP_BANK/team" ] && [ "$KA" != "MASQUEE" ] && [ "$KB" != "MASQUEE" ] && [ "$CM" = 401 ] \
  && ok "owner=$O : TOUS les membres lisent la clé, l'équipe tierce reste en 401" \
  || ko "owner=$O alice=$KA bob=$KB mallory=$CM"

say "T7 — ⚠ PIÈGE FAIL-OPEN : le NOM d'équipe donne un 200 et une relecture MENTEUSE"
adm -o /dev/null -X POST "$GW/assets/owner" \
  -d "{\"assetIds\":[\"$APP2\"],\"assetType\":\"Application\",\"newOwner\":\"spikeown-team-a\",\"ownerType\":\"team\"}"
O=$(owner_of "$APP2"); KB=$(key_as spikeown-bob "$APP2")
[ "$O" = "spikeown-team-a/team" ] && [ "$KB" = "MASQUEE" ] \
  && ok "relecture owner=$O (paraît juste) MAIS bob=MASQUEE → seul l'UUID est fonctionnel" \
  || ko "owner=$O bob=$KB (le piège a-t-il disparu ? re-caractériser)"

say "T8 — LE DÉPART : le compte part, l'application team-owned survit et reste lisible"
adm -o /dev/null -X DELETE "$GW/users/$U_ALICE"; U_ALICE=""
O=$(owner_of "$APP1"); KB=$(key_as spikeown-bob "$APP1")
CA=$(code -u "spikeown-alice:$PW" -H "Accept: application/json" "$GW/applications/$APP1")
[ "$O" = "$AP_BANK/team" ] && [ "$KB" != "MASQUEE" ] && [ "$CA" = 401 ] \
  && ok "après suppression : app intacte (owner=$O), bob lit toujours, alice=$CA" \
  || ko "owner=$O bob=$KB alice=$CA"

say "T9 — CONTRE-FACTUEL : cloisonnée mais en propriété INDIVIDUELLE → clé orpheline"
adm -o /dev/null -X POST "$GW/assets/team" \
  -d "{\"assetIds\":[\"$APP3\"],\"assetType\":\"Application\",\"newTeams\":[\"$AP_BANK\"]}"
K0=$(key_as spikeown-carol "$APP3")
adm -o /dev/null -X DELETE "$GW/users/$U_CAROL"; U_CAROL=""
KB=$(key_as spikeown-bob "$APP3")
KM=$(adm "$GW/applications/$APP3" | jq_ "
import sys,json;a=(json.load(sys.stdin).get('applications') or [{}])[0]
k=a.get('accessTokens',{}).get('apiAccessKey_credentials',{}).get('apiAccessKey')
print('MASQUEE' if k and set(k)=={'*'} else (k or 'ABSENTE'))")
[ "$K0" != "MASQUEE" ] && [ "$KB" = "MASQUEE" ] && [ "$KM" = "MASQUEE" ] \
  && ok "carol lisait ; après son départ PERSONNE ne lit (bob=$KB, admin=$KM) — /assets/team ne protège PAS le secret" \
  || ko "carol=$K0 bob=$KB admin=$KM"

say "T10 — RÉPARABLE APRÈS COUP : owner fantôme → team, la clé redevient lisible"
adm -o /dev/null -X POST "$GW/assets/owner" \
  -d "{\"assetIds\":[\"$APP3\"],\"assetType\":\"Application\",\"newOwner\":\"$AP_BANK\",\"ownerType\":\"team\"}"
KB=$(key_as spikeown-bob "$APP3")
[ "$KB" = "$K0" ] && ok "même clé qu'avant le départ ($KB) : rien n'était perdu, seulement inaccessible" \
  || ko "bob=$KB (attendu $K0)"

say "T11 — le geste est réservé à l'ADMIN : un membre d'équipe ne peut pas se l'octroyer"
C=$(code -u "spikeown-bob:$PW" -H "Accept: application/json" -H "Content-Type: application/json" \
     -X POST "$GW/assets/owner" -d "{\"assetIds\":[\"$APP3\"],\"assetType\":\"Application\",\"newOwner\":\"$AP_BANK\",\"ownerType\":\"team\"}")
[ "$C" = "401" ] && ok "bob → HTTP $C (not authorized on resource: assets) : anti-spoof" \
  || ko "bob → HTTP $C (attendu 401)"

# ─── Developer Portal 10.15 : T12-T13 read-only, T14 gate, T15-T20 écriture ──
say "T12 — DevPortal 10.15 : la ressource Teams EXISTE (contre la note du repo)"
CT=$(curl -sS -m 30 -u "$DP_AUTH" -H "Accept: application/json" -o /dev/null -w '%{content_type}' "$DP/rest/v1/teams" 2>/dev/null)
CB=$(curl -sS -m 30 -u "$DP_AUTH" -H "Accept: application/json" -o /dev/null -w '%{content_type}' "$DP/rest/v1/bogusresource" 2>/dev/null)
case "$CT:$CB" in
  application/json*:text/html*) ok "/rest/v1/teams = JSON, /rest/v1/bogusresource = HTML (fallback SPA) → vraie ressource" ;;
  *) ko "teams=$CT bogus=$CB (le discriminant JSON-vs-SPA ne joue plus)" ;;
esac

say "T13 — DevPortal : les routes team/partage d'application existent"
R=0
for p in "teams/00000000-0000-0000-0000-000000000000/applications" "teams/00000000-0000-0000-0000-000000000000/users"; do
  C=$(code -u "$DP_AUTH" -H "Accept: application/json" "$DP/rest/v1/$p"); [ "$C" = "404" ] && R=$((R+1))
done
CS=$(code -u "$DP_AUTH" -H "Accept: application/json" "$DP/rest/v1/applications/00000000-0000-0000-0000-000000000000/share")
[ "$R" = 2 ] && [ "$CS" = "405" ] \
  && ok "/teams/{id}/applications et /users → 404 JSON ; /applications/{id}/share → 405 (POST-only)" \
  || ko "routes team=$R/2, share=$CS"

# ─── Helpers portail (volet écriture) ────────────────────────────────────────
# dpw : requête JSON authentifiée sur $DP/rest/v1. $1 = user:pass, $2 = chemin.
dpw()     { local who="$1" p="$2"; shift 2
            curl -sS -m 60 -u "$who" -H "Accept: application/json" \
                 -H "Content-Type: application/json" "$DP/rest/v1/$p" "$@"; }
dpwcode() { local who="$1" p="$2"; shift 2
            curl -sS -m 60 -o /tmp/spikeown-dp.$$ -w '%{http_code}' -u "$who" \
                 -H "Accept: application/json" -H "Content-Type: application/json" \
                 "$DP/rest/v1/$p" "$@"; }
dpid()    { jq_ "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('id') or (d.get('result') or [{}])[0].get('id','') or '')
except Exception: print('')"; }
# Filet quand le POST ne rend pas l'id : retrouver par nom dans la collection.
dp_find() { dpw "$DP_AUTH" "$1" | jq_ "
import sys,json
try:
    for r in (json.load(sys.stdin).get('result') or []):
        if r.get('name')=='$2' or r.get('username')=='$2':
            print(r.get('id','')); break
except Exception: pass"; }
# Shapes best-effort (cf. en-tête) : on tente POST puis PUT, tableau nu puis
# objet enveloppé. La preuve reste la relecture faite par l'appelant.
dp_link_users() { local team="$1" ids="$2" v b c
  for v in POST PUT; do for b in "[$ids]" "{\"users\":[$ids]}"; do
    c=$(dpwcode "$DP_AUTH" "teams/$team/users" -X "$v" -d "$b")
    case "$c" in 2*) return 0;; esac
  done; done; return 1; }
dp_share() { local who="$1" app="$2" teams="$3" b c
  for b in "{\"teams\":[$teams],\"users\":[]}" "{\"teams\":[$teams]}"; do
    c=$(dpwcode "$who" "applications/$app/share" -X POST -d "$b")
    case "$c" in 2*) echo "$c"; return 0;; esac
  done; echo "$c"; return 1; }

say "T14 — DevPortal : GATE — la licence accepte-t-elle l'écriture ?"
GB=/tmp/spikeown-gate.$$
GATE=$(curl -sS -m 60 -o "$GB" -w '%{http_code}' -u "$DP_AUTH" \
        -H "Accept: application/json" -H "Content-Type: application/json" \
        -X POST "$DP/rest/v1/teams" -d '{"name":"spikeown-dpteam-a","description":"spike ownership"}')
case "$GATE" in
  406)
    ok "POST /rest/v1/teams → 406 « Valid license is missing » : trial — volet écriture T15-T20 SKIPPED"
    SKIPPED="T15-T20, portail en écriture — rejouer sur instance licenciée" ;;
  2*)
    ok "POST /rest/v1/teams → $GATE : instance licenciée — volet écriture ACTIVÉ"
    DP_WRITE=1
    P_TEAM_A=$(dpid < "$GB"); [ -n "$P_TEAM_A" ] || P_TEAM_A=$(dp_find teams spikeown-dpteam-a) ;;
  *)
    ko "POST /rest/v1/teams → $GATE inattendu (ni 406 trial, ni 2xx) : $(head -c 200 "$GB" | tr -d '\n')" ;;
esac
rm -f "$GB"

if [ "$DP_WRITE" = 1 ]; then

say "T15 — portail : users, 2e team, rattachements (preuve par relecture)"
mk_dpuser() {
  dpw "$DP_AUTH" users -X POST -d "{\"username\":\"$1\",\"password\":\"$PW\",
    \"firstname\":\"$1\",\"lastname\":\"spikeown\",\"email\":\"$1@bank.invalid\"}" | dpid
}
P_ALICE=$(mk_dpuser spikeown-alice);   [ -n "$P_ALICE" ]   || P_ALICE=$(dp_find users spikeown-alice)
P_BOB=$(mk_dpuser spikeown-bob);       [ -n "$P_BOB" ]     || P_BOB=$(dp_find users spikeown-bob)
P_MALLORY=$(mk_dpuser spikeown-mallory); [ -n "$P_MALLORY" ] || P_MALLORY=$(dp_find users spikeown-mallory)
P_TEAM_B=$(dpw "$DP_AUTH" teams -X POST -d '{"name":"spikeown-dpteam-b","description":"spike ownership"}' | dpid)
[ -n "$P_TEAM_B" ] || P_TEAM_B=$(dp_find teams spikeown-dpteam-b)
dp_link_users "$P_TEAM_A" "\"$P_ALICE\",\"$P_BOB\"" || true
dp_link_users "$P_TEAM_B" "\"$P_MALLORY\"" || true
# Relecture : alice ET bob membres de team A, alice ABSENTE de team B (T18 en dépend).
MA=$(dpw "$DP_AUTH" "teams/$P_TEAM_A/users" | grep -c spikeown-alice || true)
MB=$(dpw "$DP_AUTH" "teams/$P_TEAM_A/users" | grep -c spikeown-bob || true)
NA=$(dpw "$DP_AUTH" "teams/$P_TEAM_B/users" | grep -c spikeown-alice || true)
[ -n "$P_ALICE" ] && [ -n "$P_BOB" ] && [ -n "$P_MALLORY" ] && [ "$MA" -ge 1 ] && [ "$MB" -ge 1 ] && [ "$NA" -eq 0 ] \
  && ok "3 users créés ; team A={alice,bob} relue ; alice hors team B" \
  || ko "users a=$P_ALICE b=$P_BOB m=$P_MALLORY ; team A alice=$MA bob=$MB ; team B alice=$NA (shape linkUsers à ajuster ?)"

say "T16 — avant share : l'app d'alice est invisible pour bob comme pour mallory"
mk_dpapp() { dpw "$1" applications -X POST -d "{\"name\":\"$2\",\"description\":\"spike ownership\"}" | dpid; }
P_APP1=$(mk_dpapp "spikeown-alice:$PW" spikeown-dp-app1)   # share par alice (T17/T18)
P_APP2=$(mk_dpapp "spikeown-alice:$PW" spikeown-dp-app2)   # share forcé par admin (T19)
P_APP3=$(mk_dpapp "spikeown-bob:$PW"   spikeown-dp-app3)   # possédée par bob, partagée à team A (survie T20)
CB=$(dpwcode "spikeown-bob:$PW" "applications/$P_APP1")
CM=$(dpwcode "spikeown-mallory:$PW" "applications/$P_APP1")
[ -n "$P_APP1" ] && [ -n "$P_APP2" ] && [ -n "$P_APP3" ] && [ "$CB" != "200" ] && [ "$CM" != "200" ] \
  && ok "3 apps créées ; avant share : bob=$CB mallory=$CM (pas de vue d'équipe implicite)" \
  || ko "apps=$P_APP1/$P_APP2/$P_APP3 bob=$CB mallory=$CM"

say "T17 — LE TEST DÉCISIF : share owner→team A ⇒ bob voit l'app ET ses credentials"
SC=$(dp_share "spikeown-alice:$PW" "$P_APP1" "\"$P_TEAM_A\"") || true
CB=$(dpwcode "spikeown-bob:$PW" "applications/$P_APP1")
CT=$(dpwcode "spikeown-bob:$PW" "applications/$P_APP1/tokens")
CM=$(dpwcode "spikeown-mallory:$PW" "applications/$P_APP1")
[ "$CB" = "200" ] && [ "$CT" = "200" ] && [ "$CM" != "200" ] \
  && ok "share=$SC ; bob : app=200, /tokens=200 (credentials VISIBLES) ; mallory=$CM — le self-service d'équipe sans compte de service TIENT" \
  || ko "share=$SC bob app=$CB tokens=$CT mallory=$CM — si tokens≠200, le share ne donne PAS les credentials : pattern à revoir"

say "T18 — garde « team du owner » : share vers une team dont alice n'est PAS membre"
SC=$(dp_share "spikeown-alice:$PW" "$P_APP1" "\"$P_TEAM_B\"") && G=0 || G=1
BODY=$(head -c 160 /tmp/spikeown-dp.$$ 2>/dev/null | tr -d '\n')
if [ "$G" = 1 ]; then ok "rejeté (HTTP $SC : $BODY) — la garde du bytecode est réelle : partager AVANT le départ"
else
  CMB=$(dpwcode "spikeown-mallory:$PW" "applications/$P_APP1")
  [ "$CMB" = "200" ] && ko "accepté (HTTP $SC) ET mallory lit ($CMB) — la garde n'existe pas : re-caractériser" \
                     || ok "write accepté (HTTP $SC) mais SANS effet (mallory=$CMB) — no-op silencieux, même famille que le nom d'équipe côté gateway"
fi

say "T19 — forçage admin : l'admin partage l'app d'alice sans son concours"
SC=$(dp_share "$DP_AUTH" "$P_APP2" "\"$P_TEAM_A\"") || true
CB=$(dpwcode "spikeown-bob:$PW" "applications/$P_APP2")
[ "$CB" = "200" ] && ok "share admin=$SC ⇒ bob=200 : récupération pilotable par la gouvernance, sans le owner" \
  || ko "share admin=$SC bob=$CB — le forçage admin ne marche pas : le share doit venir du owner, à intégrer au process de départ"

say "T20 — cascade : suppression du compte alice — possédée détruite, partagée survit"
dp_share "spikeown-bob:$PW" "$P_APP3" "\"$P_TEAM_A\"" >/dev/null 2>&1 || true
DC=$(dpwcode "$DP_AUTH" "users/$P_ALICE" -X DELETE); P_ALICE=""
C1=$(dpwcode "$DP_AUTH" "applications/$P_APP1")
C3=$(dpwcode "spikeown-bob:$PW" "applications/$P_APP3")
if [ "$C1" = "404" ] && [ "$C3" = "200" ]; then
  P_APP1=""; P_APP2=""
  ok "DELETE user=$DC ⇒ app possédée par alice=404 (cascade CONFIRMÉE, le share ne l'a pas sauvée) ; app de bob=200 (participant survit) — désactiver, JAMAIS supprimer"
elif [ "$C3" != "200" ]; then
  ko "app3 de bob=$C3 après suppression d'alice (simple participante) — cascade plus large que le bytecode ne le dit"
else
  ok "DELETE user=$DC ⇒ app possédée=$C1 (pas de hard delete immédiat : softDelete via demande d'approbation probable — vérifier la file des requests) ; app de bob=200"
fi

fi  # DP_WRITE

rm -f /tmp/spikeown-dp.$$
say "RÉSULTAT : $PASS/$((PASS+FAIL))${SKIPPED:+   (SKIP : $SKIPPED)}"
[ "$FAIL" -eq 0 ] || exit 1
