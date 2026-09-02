#!/usr/bin/env bash
# test-palier-retention-live.sh — porte LIVE G4 (ADR-082) côté Vault (lab requis).
#
# La porte HORS-LIGNE (test-palier-retention.sh) lit ce que le poseur ÉMET.
# Celle-ci mesure ce que Vault FAIT de cette émission :
#   ① pose réelle (setup-vault-paliers.sh, idempotente) ;
#   ② matrice 403 inter-palier : un token apply-<e> lit SON palier, pas le voisin,
#     pas le terminus ;
#   ③ tenant resserré : write d'un secret d'app accepté au palier non terminal,
#     REFUSÉ au terminus (la policy vient de l'onboarding, pas d'un `if`) ;
#   ④ motif F4 par palier : policy révoquée ⇒ geste d'apply FERMÉ, et le CANARI
#     — qui tient la place de la gateway — ne voit RIEN passer ;
#   ⑤ restauration vérifiée à l'octet près ⇒ geste vert, canari à EXACTEMENT un hit.
#
# ── CE QUE LE CANARI PROUVE, ET POURQUOI IL EST CONTRÔLÉ POSITIVEMENT ────────
# « Aucune requête n'a atteint la gateway » est une assertion d'ABSENCE : elle
# est vraie aussi quand le témoin est mort. Un canari qui n'a jamais démarré
# rendrait ④bis vert sans rien mesurer — le vert vacant qui a mordu ce jalon
# trois fois. Le canari est donc TOUCHÉ EXPRÈS au démarrage (auto-test, chemin
# distinct) et son log RELU : tant que ce contrôle positif n'est pas passé, la
# porte REFUSE de courir. Le silence de ④bis ne vaut que derrière lui.
#
# ── FAIL-CLOSED, JAMAIS DE SKIP MUET ────────────────────────────────────────
# Prérequis manquant (Vault muet, ansible-playbook absent, port canari
# inutilisable) ⇒ exit 1 avec `LAB_ABSENT : <détail>`. Une porte live qui « se
# saute toute seule » quand le lab tombe est pire qu'absente : elle rend vert.
#
# ── CE QUE CE SCRIPT ÉCRIT DANS LE LAB, ET CE QU'IL REMET ────────────────────
# Le lab est PARTAGÉ. Ce script :
#   - POSE les policies/AppRoles apply-<e> (c'est le mécanisme lui-même, geste
#     idempotent — il reste posé, comme après tout passage du poseur) ;
#   - RÉVOQUE la seule policy apply-<SECOND> qu'il vient de poser, puis la
#     RESTAURE et RELIT pour vérifier l'identité octet à octet (motif
#     test-deploy-pin.sh:274-279). Aucune policy PRÉEXISTANTE du lab
#     (stoa-*, deploy-*, user-deploy, operator-deploy) n'est touchée ;
#   - crée des fixtures JETABLES (secret de probe du tenant, et le secret
#     d'admin des paliers UNIQUEMENT s'il était absent) et les DÉTRUIT en
#     fin — un secret déjà présent n'est ni lu, ni écrit, ni supprimé.
#
#   VAULT_TOKEN=… bash scripts/test-palier-retention-live.sh
#
# `A && ok || bad` (SC2015) est l'idiome des scripts de preuve du repo ; le
# `$?` relu juste après la redirection du sous-shell qui le produit (SC2181)
# est une lecture immédiate et non ambiguë.
# shellcheck disable=SC2015,SC2181
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
TMP=$(mktemp -d); umask 077

lab_absent(){ echo "LAB_ABSENT : $*" >&2; rm -rf "$TMP"; exit 1; }

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
export VAULT_ADDR
[ -n "${VAULT_TOKEN:-}" ] || lab_absent "VAULT_TOKEN requis (root du Vault de lab)"

for b in curl python3 ansible-playbook; do
  command -v "$b" >/dev/null 2>&1 || lab_absent "$b introuvable — prérequis de cette porte"
done
curl -s -m 5 -o /dev/null "$VAULT_ADDR/v1/sys/health" \
  || lab_absent "Vault ne répond pas à $VAULT_ADDR"

# Le token ne transite JAMAIS par argv ni par une URL : fichier d'en-tête lu
# par `curl -H @fichier` (discipline de repo-protection.sh / team-apply.sh:149).
VHDR="$TMP/vhdr"; printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$VHDR"
vcurl(){ curl -s -m 20 -H @"$VHDR" "$@"; }

# Un root muet se voit ICI, pas trois épreuves plus loin sur un 403 énigmatique.
[ "$(vcurl -o /dev/null -w '%{http_code}' "$VAULT_ADDR/v1/sys/policies/acl?list=true")" = 200 ] \
  || lab_absent "le VAULT_TOKEN fourni ne peut pas lister les policies (root de lab attendu)"

# shellcheck source=scripts/lib/env-chain.sh
. scripts/lib/env-chain.sh
ENVS="$(env_chain_nonprod)" || lab_absent "chaîne d'environnements illisible (env_chain_nonprod)"
FIRST="$(echo "$ENVS" | awk '{print $1}')"
SECOND="$(echo "$ENVS" | awk '{print $2}')"
TERM_ENV="$(env_chain | awk '{print $NF}')" || lab_absent "chaîne d'environnements illisible (env_chain)"
[ -n "$FIRST" ] && [ -n "$SECOND" ] && [ -n "$TERM_ENV" ] \
  || lab_absent "chaîne trop courte pour cette porte (paliers hors-prod : '$ENVS')"
echo "Chaîne : $(env_chain) — hors-prod '$ENVS', terminus '$TERM_ENV'"

TENANT="${G4_LIVE_TENANT:-banking-demo}"
PROBE_APP="probe-g4"
PROBE_ROOT="secret/metadata/stoa/deploy/$TENANT/apps/$PROBE_APP"

# La probe s'ÉCRIT à une FEUILLE (apps/probe-g4/<env>/oauth-client), pas à la
# racine apps/probe-g4 : en KV v2 celle-ci n'est qu'un PRÉFIXE. Un DELETE sur le
# préfixe est un no-op qui laisse la feuille en place (défaut mesuré : ⑥ rougit,
# la probe rec survit). KV v2 n'a pas de delete récursif : on LISTe le sous-arbre
# de l'app et on DÉTRUIT chaque feuille oauth-client (③ n'en crée qu'une — le
# palier non terminal — mais la purge reste correcte si d'autres apparaissent).
probe_purge(){
  local envs e
  envs="$(vcurl "$VAULT_ADDR/v1/$PROBE_ROOT?list=true" \
    | python3 -c 'import sys,json
try: print("\n".join(json.load(sys.stdin)["data"]["keys"]))
except Exception: pass' 2>/dev/null)"
  for e in $envs; do
    e="${e%/}"
    vcurl -X DELETE "$VAULT_ADDR/v1/$PROBE_ROOT/$e/oauth-client" -o /dev/null 2>/dev/null
  done
}

# ── TEARDOWN, armé AVANT la première écriture ───────────────────────────────
# Toutes les variables qu'il référence sont déclarées ICI, pour que `set -u` ne
# le casse jamais quand il se déclenche tôt (motif test-producer-chain.sh:417).
CPID=""
SEEDED_ENVS=""          # paliers dont NOUS avons créé le secret d'admin
POLICY_BAK=""           # HCL capturé de apply-$SECOND avant révocation
POLICY_REVOKED=0

restore_policy(){
  # Restauration VÉRIFIÉE : re-pose puis RELECTURE comparée à l'octet près.
  # Un `cp`/PUT dont personne ne lit le résultat peut laisser le lab désarmé
  # pendant que le script imprime « N PASS / 0 FAIL ».
  [ "$POLICY_REVOKED" -eq 1 ] || return 0
  [ -s "$POLICY_BAK" ] || { echo "RESTAURATION IMPOSSIBLE : sauvegarde de apply-$SECOND vide" >&2; return 1; }
  vcurl -X PUT "$VAULT_ADDR/v1/sys/policies/acl/apply-$SECOND" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"policy":open(sys.argv[1]).read()}))' "$POLICY_BAK")" \
    -o /dev/null
  vcurl "$VAULT_ADDR/v1/sys/policies/acl/apply-$SECOND" \
    | python3 -c 'import sys,json
try: sys.stdout.write(json.load(sys.stdin)["data"]["policy"])
except Exception: sys.exit(1)' > "$TMP/policy.after" 2>/dev/null
  if cmp -s "$POLICY_BAK" "$TMP/policy.after"; then
    POLICY_REVOKED=0
    return 0
  fi
  echo "RESTAURATION ECHOUEE : la policy apply-$SECOND relue diffère de la sauvegarde — lab laissé désarmé" >&2
  return 1
}

teardown(){
  [ -n "$CPID" ] && kill "$CPID" 2>/dev/null
  restore_policy || true
  # Fixtures jetables : la probe du tenant, puis les secrets d'admin QUE NOUS
  # avons créés (jamais un secret préexistant du lab).
  probe_purge
  for e in $SEEDED_ENVS; do
    vcurl -X DELETE "$VAULT_ADDR/v1/secret/metadata/stoa/envs/$e/wm-admin" -o /dev/null 2>/dev/null
  done
  rm -rf "$TMP"
}
trap teardown EXIT INT TERM

# ── FIXTURE : le secret d'admin du palier ───────────────────────────────────
# La policy apply-<e> porte `read` sur envs/<e>/wm-admin. Sans le secret, une
# lecture AUTORISÉE rend 404 et une lecture REFUSÉE rend 403 : la matrice reste
# lisible, mais ⑤ (geste vert) exige un `curl -f` qui réussit. On sème donc —
# UNIQUEMENT si le chemin est vide — une valeur jetable, retirée au teardown.
seed_env_secret(){ # <env>
  local code
  code="$(vcurl -o /dev/null -w '%{http_code}' "$VAULT_ADDR/v1/secret/data/stoa/envs/$1/wm-admin")"
  case "$code" in
    200) echo "  envs/$1/wm-admin : PRÉEXISTANT — ni écrit ni supprimé par cette porte"; return 0 ;;
    404) : ;;
    *) bad "fixture envs/$1/wm-admin : lecture inattendue HTTP $code"; return 1 ;;
  esac
  code="$(vcurl -o /dev/null -w '%{http_code}' -X POST "$VAULT_ADDR/v1/secret/data/stoa/envs/$1/wm-admin" \
    -H 'Content-Type: application/json' \
    -d '{"data":{"username":"g4-live-probe","password":"g4-live-probe-jetable"}}')"
  case "$code" in
    200|204) SEEDED_ENVS="$SEEDED_ENVS $1"; echo "  envs/$1/wm-admin : ABSENT ⇒ fixture JETABLE semée (retirée au teardown)" ;;
    *) bad "fixture envs/$1/wm-admin : écriture HTTP $code"; return 1 ;;
  esac
}

echo
echo "== ① pose réelle du plan de credential par palier =="
bash scripts/setup-vault-paliers.sh >"$TMP/pose" 2>&1 \
  && ok "① pose idempotente (policies + AppRoles apply-{$(echo "$ENVS" | tr ' ' ',')})" \
  || { bad "① pose: $(tail -2 "$TMP/pose")"; printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"; exit 1; }

seed_env_secret "$FIRST" || { printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"; exit 1; }
seed_env_secret "$SECOND" || { printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"; exit 1; }

# mint <role> -> imprime "role_id<TAB>secret_id" ; échec = sortie vide
mint(){ bash scripts/setup-vault-paliers.sh --mint "$1" 2>"$TMP/mint.err"; }

approle_token(){ # <role_id> <secret_id> -> imprime le client_token
  # role_id/secret_id passés par ENV, jamais par argv : le secret_id est un
  # credential, et `ps` sur cet hôte PARTAGÉ exposerait un argv de python3.
  local body
  body="$(ROLE_ID="$1" SECRET_ID="$2" python3 -c 'import json,os;print(json.dumps({"role_id":os.environ["ROLE_ID"],"secret_id":os.environ["SECRET_ID"]}))')"
  curl -s -m 20 -X POST "$VAULT_ADDR/v1/auth/approle/login" \
    -H 'Content-Type: application/json' -d "$body" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])' 2>/dev/null
}

echo
echo "== ② matrice 403 : un palier ne lit QUE son propre secret d'admin =="
M1="$(mint "apply-$FIRST")"
R1="${M1%%$'\t'*}"; S1="${M1##*$'\t'}"
[ -n "$M1" ] && [ "$R1" != "$S1" ] \
  && ok "② --mint apply-$FIRST rend un couple (role_id, secret_id)" \
  || bad "② --mint apply-$FIRST : $(tail -1 "$TMP/mint.err")"
T1="$(approle_token "$R1" "$S1")"
[ -n "$T1" ] && ok "② login AppRole apply-$FIRST accepté" || bad "② login AppRole apply-$FIRST refusé"
AHDR="$TMP/ahdr"; printf 'X-Vault-Token: %s\n' "$T1" > "$AHDR"
rd(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -H @"$1" "$VAULT_ADDR/v1/secret/data/stoa/envs/$2/wm-admin"; }
C1="$(rd "$AHDR" "$FIRST")"
C2="$(rd "$AHDR" "$SECOND")"
C3="$(rd "$AHDR" "$TERM_ENV")"
[ "$C1" = 200 ] && ok "② apply-$FIRST lit envs/$FIRST (200)" || bad "② lecture du propre palier: $C1 (attendu 200)"
[ "$C2" = 403 ] && ok "②bis apply-$FIRST NE lit PAS envs/$SECOND (403)" || bad "②bis fuite inter-palier: $C2 (attendu 403)"
[ "$C3" = 403 ] && ok "②ter apply-$FIRST NE lit PAS le terminus envs/$TERM_ENV (403)" || bad "②ter fuite vers le terminus: $C3 (attendu 403)"

echo
echo "== ③ tenant resserré : write au palier non terminal ✓, au terminus ✗ =="
# apim_onb_gateway=false : ÉCART ASSUMÉ au squelette du brief. Ce que ③ mesure
# est la POLICY, et le mode Vault-seul la pose à l'identique (defaults/main.yml)
# sans toucher un seul objet de la gateway 10.15 EN SERVICE du lab partagé.
# VAULT_ADDR doit être EXPORTÉ : apim_ss_vault_addr le lit dans l'environnement
# (apim_common/defaults/main.yml:58) — sans lui l'URI part vide et le play meurt
# sur un `no_log` opaque (mesuré).
VAULT_TOKEN="$VAULT_TOKEN" ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
  -e "apim_onb_team=$TENANT" -e apim_onb_gateway=false >"$TMP/onb" 2>&1 \
  && ok "③ onboarding $TENANT convergé en mode Vault-seul (policy resserrée)" \
  || bad "③ onboarding: $(tail -3 "$TMP/onb")"

vcurl "$VAULT_ADDR/v1/sys/policies/acl/deploy-$TENANT" \
  | python3 -c 'import sys,json
try: sys.stdout.write(json.load(sys.stdin)["data"]["policy"])
except Exception: sys.exit(1)' > "$TMP/tenant.hcl" 2>/dev/null
grep -q "apps/+/$TERM_ENV/" "$TMP/tenant.hcl" \
  && bad "③bis la policy du tenant porte une capacité au terminus $TERM_ENV" \
  || ok "③bis la policy deploy-$TENANT n'émet AUCUNE règle apps/+/$TERM_ENV/"

TTOK="$(vcurl -X POST -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys;print(json.dumps({"policies":[sys.argv[1]],"ttl":"5m"}))' "deploy-$TENANT")" \
  "$VAULT_ADDR/v1/auth/token/create" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])' 2>/dev/null)"
THDR="$TMP/thdr"; printf 'X-Vault-Token: %s\n' "$TTOK" > "$THDR"
[ -n "$TTOK" ] && ok "③ter token tenant deploy-$TENANT minté (ttl 5m)" || bad "③ter mint du token tenant en échec"
wr(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST -H @"$THDR" -H 'Content-Type: application/json' \
  -d '{"data":{"probe":"g4-live"}}' \
  "$VAULT_ADDR/v1/secret/data/stoa/deploy/$TENANT/apps/$PROBE_APP/$1/oauth-client"; }
W1="$(wr "$SECOND")"
W2="$(wr "$TERM_ENV")"
case "$W1" in 200|204) ok "③quater write apps/$PROBE_APP/$SECOND accepté ($W1) — voie consommateur intacte" ;;
              *) bad "③quater write $SECOND: $W1 (attendu 200/204)" ;; esac
[ "$W2" = 403 ] && ok "③quinquies write apps/$PROBE_APP/$TERM_ENV (terminus) REFUSÉ structurellement (403)" \
                || bad "③quinquies le terminus accepte un write: $W2 (attendu 403)"

echo
echo "== ④ motif F4 : policy révoquée ⇒ geste FERMÉ, gateway JAMAIS touchée =="
# Le canari tient la place de la gateway : `python3 -m http.server` journalise
# CHAQUE requête. Port libre alloué par l'OS (le lab est partagé entre agents ;
# un port en dur se heurte), surchargeable par CANARY_PORT.
CANARY_PORT="${CANARY_PORT:-$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')}"
python3 -m http.server "$CANARY_PORT" --bind 127.0.0.1 >"$TMP/canary.log" 2>&1 &
CPID=$!
for _ in $(seq 1 30); do
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$CANARY_PORT/canary-selftest" && break
  sleep 0.3
done
# CONTRÔLE POSITIF, sans lequel ④bis est VACANT : un canari mort est muet.
grep -q 'canary-selftest' "$TMP/canary.log" \
  || lab_absent "le canari ne journalise pas sur 127.0.0.1:$CANARY_PORT — le témoin de ④ serait vacant"
ok "④ canari VIVANT sur 127.0.0.1:$CANARY_PORT (auto-test journalisé — le silence de ④bis est probant)"

# Le geste d'apply MINIMAL : lire le secret du palier, PUIS toucher la gateway.
# Sans le secret, le canari ne doit JAMAIS voir passer une requête.
apply_gesture(){ # <role_id> <secret_id> <env>
  local tok
  tok="$(approle_token "$1" "$2")" || return 1
  [ -n "$tok" ] || return 1
  local h="$TMP/gest.hdr"; printf 'X-Vault-Token: %s\n' "$tok" > "$h"
  curl -s -m 20 -f -H @"$h" "$VAULT_ADDR/v1/secret/data/stoa/envs/$3/wm-admin" -o /dev/null || return 1
  curl -s -m 5 -o /dev/null "http://127.0.0.1:$CANARY_PORT/apply-$3" || return 1
}

M2="$(mint "apply-$SECOND")"; R2="${M2%%$'\t'*}"; S2="${M2##*$'\t'}"
[ -n "$M2" ] && ok "④bis --mint apply-$SECOND (le geste d'ouverture du palier)" \
             || bad "④bis --mint apply-$SECOND : $(tail -1 "$TMP/mint.err")"

# Sauvegarde AVANT révocation — la restauration en dépend, et le trap est déjà armé.
POLICY_BAK="$TMP/policy.bak"
vcurl "$VAULT_ADDR/v1/sys/policies/acl/apply-$SECOND" \
  | python3 -c 'import sys,json
try: sys.stdout.write(json.load(sys.stdin)["data"]["policy"])
except Exception: sys.exit(1)' > "$POLICY_BAK" 2>/dev/null
[ -s "$POLICY_BAK" ] || lab_absent "policy apply-$SECOND illisible — révoquer sans sauvegarde est exclu"

# POLICY_REVOKED armé AVANT le DELETE : un SIGINT/SIGTERM reçu PENDANT le curl
# du DELETE déclencherait teardown ; l'indicateur posé APRÈS, la restauration
# serait SAUTÉE et apply-$SECOND resterait révoquée sur le lab PARTAGÉ. Le
# backup ci-dessus est garanti non vide : si le DELETE n'a pas eu lieu,
# restore_policy re-PUT un contenu IDENTIQUE et le cmp passe — strictement sûr.
POLICY_REVOKED=1
vcurl -X DELETE "$VAULT_ADDR/v1/sys/policies/acl/apply-$SECOND" -o /dev/null
[ "$(vcurl -o /dev/null -w '%{http_code}' "$VAULT_ADDR/v1/sys/policies/acl/apply-$SECOND")" = 404 ] \
  && ok "④ter policy apply-$SECOND RÉVOQUÉE (404) — l'exploitant a fermé le palier" \
  || bad "④ter la policy apply-$SECOND répond encore après DELETE"

apply_gesture "$R2" "$S2" "$SECOND" >"$TMP/g1" 2>&1
GRC=$?
[ "$GRC" -ne 0 ] \
  && ok "④quater policy révoquée ⇒ geste d'apply FERMÉ (rc=$GRC)" \
  || bad "④quater le geste passe SANS policy — la rétention par palier est trouée"
grep -q "apply-$SECOND" "$TMP/canary.log" \
  && bad "④quinquies le canari a vu passer une requête — la gateway AURAIT été touchée sans credential" \
  || ok "④quinquies canari MUET : aucune requête gateway sans le credential du palier"

# MESURE (pas une assertion) : la révocation ferme l'AUTORISATION, pas
# l'AUTHENTIFICATION. Un pipeline qui se contenterait de « j'ai obtenu un
# token » poursuivrait jusqu'à la gateway. C'est ce que ④quinquies interdit.
# Même discipline que approle_token : secret_id par ENV, hors argv (hôte partagé).
LOGIN_BODY="$(ROLE_ID="$R2" SECRET_ID="$S2" python3 -c 'import json,os;print(json.dumps({"role_id":os.environ["ROLE_ID"],"secret_id":os.environ["SECRET_ID"]}))')"
LOGIN_AFTER="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$VAULT_ADDR/v1/auth/approle/login" \
  -H 'Content-Type: application/json' -d "$LOGIN_BODY")"
ok "MESURE : policy révoquée, le login AppRole apply-$SECOND rend HTTP $LOGIN_AFTER — Vault délivre encore un token porteur d'un NOM de policy disparu ; la fermeture se produit à la LECTURE (403), pas à l'authentification"

echo
echo "== ⑤ restauration vérifiée ⇒ geste vert, canari à EXACTEMENT un hit =="
restore_policy \
  && ok "⑤ policy apply-$SECOND restaurée et RELUE identique à l'octet près" \
  || bad "⑤ restauration de apply-$SECOND en échec"
M3="$(mint "apply-$SECOND")"; R3="${M3%%$'\t'*}"; S3="${M3##*$'\t'}"
apply_gesture "$R3" "$S3" "$SECOND" \
  && ok "⑤bis policy restaurée ⇒ geste d'apply VERT (secret lu, gateway touchée)" \
  || bad "⑤bis geste toujours fermé après restauration"
N=$(grep -c "apply-$SECOND" "$TMP/canary.log")
[ "$N" -eq 1 ] \
  && ok "⑤ter le canari a vu EXACTEMENT un hit — le geste restauré, et lui seul" \
  || bad "⑤ter canari: $N hits (attendu 1)"

echo
echo "== ⑦ la voie APPLICATION (A3) : matrice 403 sur l'identité de l'apply d'app, la garde, le F4 sur cette voie =="
# La PORTE du GOAL cd-applications A3 : « matrice 403 par palier rejouée sur la
# voie application : le job de rec ne peut lire aucun envs/int/* ». L'identité
# de l'apply d'application est un token NOMINATIF qui projette la policy du
# tenant (deploy-<tenant>) ET celle du palier (apply-<SECOND>) — le grant
# nominatif d'ADR-082 par groupe d'annuaire. Un token enfant portant exactement
# ces deux policies en est le modèle fidèle (lookup-self : `policies`, pas
# `identity_policies` — même forme qu'un login LDAP de ce lab).
THIRD="$(echo "$ENVS" | awk '{print $3}')"
[ -n "$THIRD" ] || lab_absent "la porte ⑦ exige au moins TROIS paliers hors-prod (rec ne doit pas lire int) : '$ENVS'"
APPTOK="$TMP/apptok"
vcurl -X POST -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys;print(json.dumps({"policies":[sys.argv[1],sys.argv[2]],"ttl":"5m"}))' "deploy-$TENANT" "apply-$SECOND")" \
  "$VAULT_ADDR/v1/auth/token/create" \
  | python3 -c 'import json,os,sys
t=json.load(sys.stdin)["auth"]["client_token"]
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write(t)' "$APPTOK" 2>/dev/null
[ -s "$APPTOK" ] && ok "⑦ token modèle de l'apply d'application minté (deploy-$TENANT + apply-$SECOND, ttl 5m) — écrit en fichier, jamais en variable" \
                 || lab_absent "mint du token modèle de l'apply d'application en échec"
APPHDR="$TMP/apphdr"; { printf 'X-Vault-Token: '; cat "$APPTOK"; printf '\n'; } > "$APPHDR"
rdo(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -H @"$1" "$VAULT_ADDR/v1/secret/data/stoa/envs/$2/admin-oauth"; }
A1="$(rd "$APPHDR" "$SECOND")"; A2="$(rd "$APPHDR" "$THIRD")"; A3="$(rdo "$APPHDR" "$THIRD")"; A4="$(rd "$APPHDR" "$TERM_ENV")"
[ "$A1" = 200 ] && ok "⑦a l'identité de l'apply d'app lit envs/$SECOND/wm-admin (200)" || bad "⑦a lecture du propre palier : $A1 (attendu 200)"
[ "$A2" = 403 ] && ok "⑦b …et NE lit PAS envs/$THIRD/wm-admin (403) — « le job de $SECOND ne peut lire aucun envs/$THIRD/* »" || bad "⑦b fuite inter-palier sur la voie application : $A2 (attendu 403)"
[ "$A3" = 403 ] && ok "⑦c …ni envs/$THIRD/admin-oauth (403)" || bad "⑦c fuite admin-oauth : $A3 (attendu 403)"
[ "$A4" = 403 ] && ok "⑦d …ni le terminus envs/$TERM_ENV (403)" || bad "⑦d fuite vers le terminus : $A4 (attendu 403)"

# La GARDE elle-même (scripts/selfservice-palier-gate.sh), avec ce token et un
# manifeste jetable ; la base d'admin vise le CANARI de ④ (toujours vivant) :
# le geste minimal de l'Apply = gate && curl canari.
printf -- '---\napim_ss_app:\n  name: "%s"\n  team: "%s"\n  api: "probe"\n  api_version: "1"\n  per_env:\n    %s: {}\n    %s: {}\n' "$PROBE_APP" "$TENANT" "$SECOND" "$THIRD" > "$TMP/probe.yml"
app_gesture(){ # <env> → rc de la garde ; touche le canari si elle a ouvert
  local rc
  rm -f "$TMP/p.out"
  ENVIRONMENT="$1" ADMIN_VIA=direct MANIFEST="$TMP/probe.yml" VAULT_TOKEN_FILE="$APPTOK" PALIER_OUT="$TMP/p.out" \
    APIM_KV_PREFIX=stoa APIM_API_BASE="http://127.0.0.1:$CANARY_PORT/rest/apigateway" \
    bash scripts/selfservice-palier-gate.sh > "$TMP/p.$1.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && curl -s -m 5 -o /dev/null "http://127.0.0.1:$CANARY_PORT/apply-app-$1"
  return "$rc"
}
app_gesture "$SECOND"; RC7=$?
[ "$RC7" -eq 0 ] && grep -q "^APIM_WM_CREDS_SUB=envs/$SECOND/wm-admin$" "$TMP/p.out" && grep -q "^PALIER_TEAM=$TENANT$" "$TMP/p.out" \
  && ok "⑦e la garde OUVRE $SECOND : APIM_WM_CREDS_SUB=envs/$SECOND/wm-admin, PALIER_TEAM=$TENANT (décidée par le token)" \
  || bad "⑦e la garde refuse $SECOND (rc=$RC7) : $(grep REFUS "$TMP/p.$SECOND.out" | head -1)"
[ "$(grep -c "apply-app-$SECOND" "$TMP/canary.log")" -eq 1 ] && ok "⑦e' canari : un hit (la gate a ouvert, la gateway a été touchée)" || bad "⑦e' canari : $(grep -c "apply-app-$SECOND" "$TMP/canary.log") hit(s)"
app_gesture "$THIRD"; RC7=$?
[ "$RC7" -ne 0 ] && grep -q "^REFUS: PALIER_FERME :" "$TMP/p.$THIRD.out" && [ ! -f "$TMP/p.out" ] \
  && ok "⑦f la garde REFUSE $THIRD : PALIER_FERME (HTTP 403), aucun PALIER_OUT — la voie application ne lit pas envs/$THIRD/*" \
  || bad "⑦f la garde ouvre $THIRD (rc=$RC7) : $(tail -1 "$TMP/p.$THIRD.out")"
grep -q "apply-app-$THIRD" "$TMP/canary.log" && bad "⑦f' le canari a vu passer une requête pour $THIRD" || ok "⑦f' canari MUET pour $THIRD"

# F4 SUR CETTE VOIE : la policy du palier révoquée ⇒ la garde ferme, canari muet ;
# restaurée (octet à octet) ⇒ vert, canari à EXACTEMENT un hit de plus.
[ -s "$POLICY_BAK" ] || lab_absent "sauvegarde de apply-$SECOND vide — révoquer sans sauvegarde est exclu"
POLICY_REVOKED=1
vcurl -X DELETE "$VAULT_ADDR/v1/sys/policies/acl/apply-$SECOND" -o /dev/null
[ "$(vcurl -o /dev/null -w '%{http_code}' "$VAULT_ADDR/v1/sys/policies/acl/apply-$SECOND")" = 404 ] \
  && ok "⑦g policy apply-$SECOND RÉVOQUÉE (404)" || bad "⑦g la policy apply-$SECOND répond encore après DELETE"
app_gesture "$SECOND"; RC7=$?
[ "$RC7" -ne 0 ] && grep -q "^REFUS: PALIER_FERME :" "$TMP/p.$SECOND.out" \
  && ok "⑦g' policy révoquée ⇒ la garde de la voie application FERME (PALIER_FERME) — le token porte encore le NOM de la policy, la fermeture est à la lecture" \
  || bad "⑦g' la garde ouvre sans policy (rc=$RC7)"
[ "$(grep -c "apply-app-$SECOND" "$TMP/canary.log")" -eq 1 ] && ok "⑦g'' canari inchangé (un seul hit, celui de ⑦e) : la gateway n'a PAS été touchée sans le credential du palier" || bad "⑦g'' canari : $(grep -c "apply-app-$SECOND" "$TMP/canary.log") hits"
restore_policy && ok "⑦h policy apply-$SECOND restaurée et RELUE identique à l'octet près" || bad "⑦h restauration en échec"
app_gesture "$SECOND"; RC7=$?
[ "$RC7" -eq 0 ] && [ "$(grep -c "apply-app-$SECOND" "$TMP/canary.log")" -eq 2 ] \
  && ok "⑦h' policy restaurée ⇒ la garde ouvre, canari à EXACTEMENT deux hits (le geste restauré, et lui seul)" \
  || bad "⑦h' après restauration : rc=$RC7, canari $(grep -c "apply-app-$SECOND" "$TMP/canary.log") hits"
curl -s -m 20 -H @"$APPHDR" -X POST "$VAULT_ADDR/v1/auth/token/revoke-self" -o /dev/null
[ "$(curl -s -m 20 -o /dev/null -w '%{http_code}' -H @"$APPHDR" "$VAULT_ADDR/v1/auth/token/lookup-self")" = 403 ] \
  && ok "⑦i token modèle révoqué — mort prouvée (lookup-self 403)" || bad "⑦i le token modèle répond encore"

echo
echo "== ⑥ nettoyage vérifié =="
kill "$CPID" 2>/dev/null; CPID=""
probe_purge
[ "$(vcurl -o /dev/null -w '%{http_code}' "$VAULT_ADDR/v1/secret/data/stoa/deploy/$TENANT/apps/$PROBE_APP/$SECOND/oauth-client")" = 404 ] \
  && ok "⑥ probe tenant apps/$PROBE_APP détruite (404)" \
  || bad "⑥ la probe tenant apps/$PROBE_APP survit au nettoyage"
for e in $SEEDED_ENVS; do
  vcurl -X DELETE "$VAULT_ADDR/v1/secret/metadata/stoa/envs/$e/wm-admin" -o /dev/null
  [ "$(vcurl -o /dev/null -w '%{http_code}' "$VAULT_ADDR/v1/secret/data/stoa/envs/$e/wm-admin")" = 404 ] \
    && ok "⑥bis fixture jetable envs/$e/wm-admin retirée (404) — état d'entrée rendu" \
    || bad "⑥bis la fixture envs/$e/wm-admin survit au nettoyage"
done
SEEDED_ENVS=""
[ "$POLICY_REVOKED" -eq 0 ] \
  && ok "⑥ter aucune policy laissée révoquée — le lab sort armé" \
  || bad "⑥ter apply-$SECOND est encore révoquée à la sortie"

printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
