#!/usr/bin/env bash
# test-onboard-team.sh — les 7 preuves du palier 1, sur une equipe JETABLE.
#
# N'ecrit JAMAIS sur banking-demo ni insurance-demo : l'equipe de test est
# creee puis supprimee. La preuve 3 est la seule qui compte vraiment — les
# autres verifient que des objets existent, celle-la verifie que l'ISOLATION
# TIENT, donc que la derivation d'equipe faite par le CI est digne de confiance.
#
# CIBLE OBLIGATOIRE, SANS DEFAUT (WM_GATEWAY_URL). Le port 5555 est la VRAIE
# gateway du lab, EN SERVICE (docker-compose.wm.yml) — un defaut qui la
# viserait ferait qu'un lancement distrait ecrirait sur un systeme reel. C'est
# a qui lance ce script de choisir sa cible : la gateway dev, ou le mock
# (cd mocks/webmethods && go run .) pour un essai hors-ligne.
#
# AUCUN LITTERAL DE SECRET : VAULT_TOKEN est exige (":?"), jamais defaute — la
# garde scripts/check-no-plaintext-secrets.sh refuse toute affectation
# litterale sur une variable *TOKEN*/*SECRET*/*PASS*.
set -uo pipefail
cd "$(dirname "$0")/.."

T="${ONBOARD_PROBE_TEAM:-onboard-probe}"
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
# NOTE bash : aucune apostrophe dans les messages ${VAR:?...} ci-dessous —
# meme entouree de doubles guillemets, une apostrophe y ouvre une citation
# simple imbriquee (constate : "unexpected EOF while looking for matching")
# et casse le script AVANT meme d'afficher le message d'erreur voulu.
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN requis — un token avec les droits create/update sur secret/data/stoa/deploy/$T/* et sys/policies/acl/deploy-$T (voir poc-control-plane-federation/.env.example). Aucun defaut litteral ici : la garde scripts/check-no-plaintext-secrets.sh refuse exactement cela.}"
WM_GATEWAY_URL="${WM_GATEWAY_URL:?WM_GATEWAY_URL requis, SANS DEFAUT. Le port 5555 est la VRAIE gateway du lab, en service — un defaut qui le viserait exposerait un lancement distrait a ecrire dessus. Choisissez explicitement la cible : la gateway dev, ou pour un essai hors-ligne, cd mocks/webmethods && go run . puis WM_GATEWAY_URL=http://localhost:PORT.}"
WM="$WM_GATEWAY_URL"
# Convention deja etablie ailleurs dans ce depot (scripts/wm-loadcheck.sh,
# scripts/wm-otel-setup.sh) : nom de variable SANS PASS/SECRET/TOKEN, donc
# hors du perimetre de la garde — "Administrator:manage" est le defaut PoC
# documente d'apim_common/defaults/main.yml (apim_ss_wm_user/apim_ss_wm_password),
# pas un secret.
WM_ADMIN_AUTH="${WM_ADMIN_AUTH:-Administrator:manage}"
INVENTORY="${INVENTORY:-ansible/inventory.lab.ini}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

api() { curl -s -u "$WM_ADMIN_AUTH" -H 'Accept: application/json' "$WM/rest/apigateway/$1"; }
vlt() { curl -s -H "X-Vault-Token: $1" "$VAULT_ADDR/v1/$2" -o /dev/null -w '%{http_code}'; }

# --- equipe jetable declaree a la volee --------------------------------------
# resolve.yml (roles/apim_team_onboard) EXIGE une correspondance EXACTE dans
# une source declarative de providers — onboarder une equipe non declaree est
# refuse par construction (TEAM_NOT_DECLARED). providers.dev.yml est REVU PAR
# PR (les equipes reelles du client) : y ajouter une equipe de preuve jetable
# le polluerait en permanence pour un artefact de test. Ce script genere donc
# sa propre source declarative — au meme endroit que les fixtures de test
# existantes (ansible/tests/onboard/*) — et la detruit en sortie.
PROVIDERS_REL="tests/onboard/providers-probe-$$.yml"
PROVIDERS_ABS="ansible/$PROVIDERS_REL"
mkdir -p "$(dirname "$PROVIDERS_ABS")"
cat > "$PROVIDERS_ABS" <<EOF
---
# Genere par scripts/test-onboard-team.sh — equipe JETABLE, non destine a etre
# commite (nom suffixe du PID de la course qui l'a produit).
providers:
  - team: $T
    description: "equipe jetable de preuve (test-onboard-team.sh)"
    repo: ""
    approvers: []
EOF

# apim_ss_api_base N'A PAS de defaut sur l'environnement : celui du role est
# code en dur sur http://localhost:5555 (apim_common/defaults/main.yml). Sans
# cette surcharge EXPLICITE sur CHAQUE appel ansible-playbook, ce script
# viserait la VRAIE gateway quel que soit WM_GATEWAY_URL — exactement
# l'accident qu'il existe pour eviter.
ANSIBLE_ARGS=(
  -i "$INVENTORY"
  -e "apim_onb_team=$T"
  -e "apim_onb_providers_file=$PROVIDERS_REL"
  -e "apim_ss_vault_addr=$VAULT_ADDR"
  -e "apim_ss_api_base=$WM/rest/apigateway"
)

# Le token Vault part par VAULT_TOKEN_FILE (0600, exporte dans l'env de CE
# process — donc herite par chaque appel ansible-playbook ci-dessous),
# JAMAIS par `-e apim_ss_vault_token=…` : un `-e` finit en clair dans
# `ps`/`/proc/<pid>/cmdline`. Meme motif que setup-vault-userpass.sh (§ header-
# FILE, ADR-074) et ci/lib/vault-login.sh ; apim_common/tasks/secrets.yml lit
# deja VAULT_TOKEN_FILE en priorite. Nettoye par cleanup_exit (trap EXIT).
VAULT_TOKEN_FILE="$(mktemp)"
chmod 600 "$VAULT_TOKEN_FILE"
printf '%s' "$VAULT_TOKEN" > "$VAULT_TOKEN_FILE"
export VAULT_TOKEN_FILE

# --- teardown : gestes de suppression, partages entre la preuve 7 et le trap
# EXIT ------------------------------------------------------------------------
# UNE SEULE implementation, appelee deux fois : par la preuve 7 (qui en verifie
# ensuite l'effet) et par le trap (filet de secours inconditionnel — si le
# run 1 echoue avant la preuve 7, ou si le script est interrompu, Vault et la
# gateway ne doivent pas rester avec les objets de l'equipe jetable). Chaque
# geste tolere l'absence de sa cible (id vide -> l'appel curl part sur une
# ressource inexistante, la gateway rend 404/405, sans consequence — set -u
# EST actif mais aucune de ces lignes ne dereference une variable non posee
# ailleurs que par une substitution deja garde par une valeur par defaut).
teardown() {
  local pid gid uid_
  pid=$(api accessProfiles | python3 -c "
import json,sys
print(next((p['id'] for p in json.load(sys.stdin).get('accessProfiles',[]) if p.get('name')=='$T'), ''))" 2>/dev/null)
  gid=$(api groups | python3 -c "
import json,sys
print(next((g['id'] for g in json.load(sys.stdin).get('groups',[]) if g.get('name')=='$T-devs'), ''))" 2>/dev/null)
  uid_=$(api users | python3 -c "
import json,sys
print(next((u['id'] for u in json.load(sys.stdin).get('users',[]) if u.get('loginId')=='svc-$T'), ''))" 2>/dev/null)
  [ -n "$pid" ] && curl -s -u "$WM_ADMIN_AUTH" -X DELETE "$WM/rest/apigateway/accessProfiles/$pid" -o /dev/null
  [ -n "$gid" ] && curl -s -u "$WM_ADMIN_AUTH" -X DELETE "$WM/rest/apigateway/groups/$gid" -o /dev/null
  [ -n "$uid_" ] && curl -s -u "$WM_ADMIN_AUTH" -X DELETE "$WM/rest/apigateway/users/$uid_" -o /dev/null
  curl -s -H "X-Vault-Token: $VAULT_TOKEN" -X DELETE \
    "$VAULT_ADDR/v1/secret/metadata/stoa/deploy/$T/wm-admin" -o /dev/null
  curl -s -H "X-Vault-Token: $VAULT_TOKEN" -X DELETE \
    "$VAULT_ADDR/v1/sys/policies/acl/deploy-$T" -o /dev/null
}
cleanup_exit() { teardown >/dev/null 2>&1; rm -f "$PROVIDERS_ABS" "$VAULT_TOKEN_FILE"; }
trap cleanup_exit EXIT

echo "== onboarding de l'equipe jetable $T sur $WM =="
ansible-playbook "${ANSIBLE_ARGS[@]}" ansible/onboard-team.yml >/tmp/onb1.log 2>&1
RUN1=$?
CH1=$(grep -o 'changed=[0-9]*' /tmp/onb1.log | tail -1 | cut -d= -f2)
if [ "$RUN1" -ne 0 ]; then
  bad "l'onboarding (run 1) a echoue — voir /tmp/onb1.log"
  echo "== $PASS PASS / $FAIL FAIL =="
  exit 1
fi

# --- 1. les 4 objets gateway existent et sont relies -------------------------
UID_=$(api users | python3 -c "
import json,sys
print(next((u['id'] for u in json.load(sys.stdin)['users'] if u['loginId']=='svc-$T'), ''))")
GID=$(api groups | python3 -c "
import json,sys
print(next((g['id'] for g in json.load(sys.stdin)['groups'] if g['name']=='$T-devs'), ''))")
LINKED=$(api accessProfiles | python3 -c "
import json,sys
p=next((p for p in json.load(sys.stdin)['accessProfiles'] if p['name']=='$T'), None)
print('yes' if p and '$GID' in (p.get('groupIds') or []) else 'no')")
SYS=$(api groups | python3 -c "
import json,sys
g=next((g for g in json.load(sys.stdin)['groups'] if g['name']=='API-Gateway-Providers'), None)
print('yes' if g and '$UID_' in (g.get('userIds') or []) else 'no')")
[ -n "$UID_" ] && [ -n "$GID" ] && [ "$LINKED" = yes ] && [ "$SYS" = yes ] \
  && ok "1. user/groupe/team/groupe systeme poses et relies" \
  || bad "1. chaine rompue (user=$UID_ groupe=$GID team=$LINKED systeme=$SYS)"

# --- 2. le secret et la policy existent --------------------------------------
[ "$(vlt "$VAULT_TOKEN" "secret/data/stoa/deploy/$T/wm-admin")" = 200 ] \
  && [ "$(vlt "$VAULT_TOKEN" "sys/policies/acl/deploy-$T")" = 200 ] \
  && ok "2. entree KV et policy deploy-$T presentes" || bad "2. KV ou policy absente"

# --- 3. LA DOUVE : la policy borne REELLEMENT la lecture ---------------------
# La seule preuve qui compte vraiment : les autres verifient que des objets
# existent, celle-ci verifie que l'ISOLATION TIENT — donc que la derivation
# d'equipe faite par le CI (2e segment du chemin KV) est digne de confiance.
# Un chemin HORS policy rend 403 meme s'il n'existe pas : la preuve tient donc
# sans onboarder banking-demo au prealable.
TOK=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" -X POST \
  -d "{\"policies\":[\"deploy-$T\"],\"ttl\":\"5m\"}" \
  "$VAULT_ADDR/v1/auth/token/create" | python3 -c "
import json,sys; print(json.load(sys.stdin)['auth']['client_token'])")
MINE=$(vlt "$TOK" "secret/data/stoa/deploy/$T/wm-admin")
THEIRS=$(vlt "$TOK" "secret/data/stoa/deploy/banking-demo/wm-admin")
[ "$MINE" = 200 ] && [ "$THEIRS" = 403 ] \
  && ok "3. DOUVE : lit son KV (200), refuse celui d'une autre equipe (403)" \
  || bad "3. DOUVE ROMPUE : sien=$MINE autre=$THEIRS (attendu 200 / 403)"

# --- 4. la derivation du CI rend bien l'equipe -------------------------------
[ "$(printf '%s' "deploy/$T/wm-admin" | cut -d/ -f2)" = "$T" ] \
  && ok "4. la derivation du CI sur ce chemin KV rend '$T'" || bad "4. derivation incoherente"

# --- 5. re-run : rien ne change, le mot de passe ne tourne pas ---------------
# PIEGE : ansible.builtin.uri rend TOUJOURS changed=false quand il n'ecrit pas
# de fichier local (verifie dans la source du module, uri.py:746) — un
# changed=0 au SECOND run ne prouve donc RIEN par lui-meme : ce serait vrai
# meme si le role reecrivait tout a chaque run. Ce qui rend cette preuve
# signifiante, c'est un changed=1 au PREMIER run (CH1, capture plus haut),
# produit par l'UNIQUE changed_when veridique du role — gateway.yml, la tache
# "poser le membre du groupe", seule dont le changed_when est calcule depuis
# un etat REELLEMENT relu avant l'ecriture (les autres taches d'ecriture du
# role n'ont pas de changed_when explicite et heritent du meme defaut
# toujours-false du module). EXIGER CH1=1 ET CH2=0 est donc double, pas
# cosmetique : si un jour ce changed_when se casse, un run 1 qui ne rend plus
# changed=1 doit faire ECHOUER cette preuve — pas rester vert en ne prouvant
# plus rien.
#
# kv() extrait UNIQUEMENT .data.data (username+password) — jamais l'enveloppe
# Vault entiere. Constate en isolant cette comparaison seule : la reponse porte
# un request_id UNIQUE PAR REQUETE (verifie par deux GET consecutifs sans
# aucune ecriture entre les deux : request_id differe a chaque fois), donc un
# sha256sum de la reponse brute rendrait TOUJOURS "REJOUE" — meme quand rien
# n'a change. Comparer .data.data est la seule forme qui repond a la question
# posee : le secret a-t-il change, pas la requete qui l'a lu.
kv() { curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/stoa/deploy/$T/wm-admin" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('data',{}))"; }
BEFORE=$(kv | sha256sum)
ansible-playbook "${ANSIBLE_ARGS[@]}" ansible/onboard-team.yml >/tmp/onb2.log 2>&1
RUN2=$?
AFTER=$(kv | sha256sum)
CH2=$(grep -o 'changed=[0-9]*' /tmp/onb2.log | tail -1 | cut -d= -f2)
if [ "$RUN2" -eq 0 ] && [ "$BEFORE" = "$AFTER" ] && [ "${CH1:-0}" = 1 ] && [ "${CH2:-1}" = 0 ]; then
  ok "5. run 1 changed=1 (preuve veridique) ; run 2 idempotent (changed=0), secret inchange"
else
  bad "5. run1 changed=${CH1:-?} (attendu 1, sinon la preuve d'idempotence ne prouve rien) / run2 changed=${CH2:-?} (attendu 0) / secret $([ "$BEFORE" = "$AFTER" ] && echo inchange || echo REJOUE)"
fi

# --- 6. L'HYPOTHESE DU SPEC : accessProfile pose feature ETEINTE -------------
TW=$(api configurations/extended | python3 -c "
import json,sys; print(json.load(sys.stdin).get('enableTeamWork','?'))")
if [ "$TW" = "false" ]; then
  [ "$LINKED" = yes ] \
    && ok "6. feature ETEINTE et accessProfile pose — l'onboarding n'est PAS bloque" \
    || bad "6. feature eteinte : l'accessProfile n'a pas ete pose (le palier 1 se reduit a Vault)"
else
  printf '  \033[33mSKIP\033[0m 6. feature ACTIVE (enableTeamWork=%s) : hypothese non testable ici\n' "$TW"
fi

# --- 7. suppression symetrique ------------------------------------------------
teardown
GONE=$(api accessProfiles | python3 -c "
import json,sys
print('no' if any(p['name']=='$T' for p in json.load(sys.stdin)['accessProfiles']) else 'yes')")
[ "$GONE" = yes ] && [ "$(vlt "$VAULT_TOKEN" "sys/policies/acl/deploy-$T")" != 200 ] \
  && ok "7. suppression symetrique : rien d'orphelin" || bad "7. residus apres suppression"

echo "== $PASS PASS / $FAIL FAIL =="
[ "$FAIL" -eq 0 ]
