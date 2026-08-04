#!/usr/bin/env bash
# test-vault-user-login.sh — preuve VOIE A (ADR-078 §3) : « un utilisateur se
# connecte au Vault avec son user/mot de passe depuis Jenkins », de bout en bout.
#
#   humain ─(user + mot de passe, paramètre de build)─▶ ci/lib/vault-login.sh
#   ─POST /v1/<mount>/login/<user>─▶ token Vault NOMINATIF tenant-scopé
#   ─▶ lecture du périmètre de SON tenant ─▶ revoke + PREUVE DE MORT.
#
# Ce que la preuve établit, au-delà du chemin nominal :
#   · la ségrégation par tenant est ENFORCÉE par Vault, pas par le pipeline ;
#   · un mot de passe à métacaractères passe (le corps JSON n'est pas forgé en shell) ;
#   · ni le mot de passe ni le token n'apparaissent en argv ni dans le log ;
#   · le token est révoqué MÊME quand le build échoue, et sa mort est prouvée ;
#   · Vault injoignable ou identité refusée = ÉCHEC, jamais un repli silencieux ;
#   · l'audit Vault porte l'identité nominative, succès ET refus, sur CE run.
#
# Prérequis : poc-vault up ; bash scripts/setup-vault-userpass.sh joué (crée les
#   IDENTITÉS userpass, PAS leurs périmètres) ; ET les tenants de la matrice
#   (LAB_TENANT_ALICE, LAB_TENANT_BOB) onboardés via le rôle Ansible
#   apim_team_onboard, qui pose désormais SEUL les policies deploy-<tenant> :
#     ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
#       -e apim_onb_team=<tenant>
#   Sans ça, T6 (alice lit son tenant) et T27 (policy héritée du groupe LDAP)
#   échouent — authentifiée mais sans le périmètre attendu, pas un bug du login.
#   Palier LDAP (formats UPN / DOMAIN\user, mapping groupe AD→policy) : les tests
#   marqués [ldap] sont SAUTÉS tant que setup-vault-ldap.sh n'a pas tourné.
set -uo pipefail
# `A && ok || bad` (SC2015) est l'idiome des scripts de preuve du repo ; les
# sous-shells d'isolation exportent volontairement dans leur seule portée (SC2030/31).
# shellcheck disable=SC2015,SC2030,SC2031
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Cible de ce harnais : le Vault du POC docker-compose, sur la boucle locale.
#
# `VAULT_ADDR` de l'environnement est DÉLIBÉRÉMENT IGNORÉ. Relevé le 2026-07-30 :
# le poste de l'exploitant exporte `VAULT_ADDR=https://<vault-externe>` depuis son
# ~/.zshrc. Ce script lit les mots de passe RÉELS d'alice, carol et oscar dans le
# fichier root-only du nœud, et envoie aussi le jeton de lab en clair — les hériter
# d'une variable d'ambiance expédie tout cela vers l'hôte qu'elle désigne, en
# croyant tester son compose local.
#
# Pas de validation par suffixe : elle porterait sur l'URL et non sur l'hôte, or
# `http://localhost:8200` ne se termine pas par `localhost` tandis que
# `https://x.example/#localhost` s'y termine. Il faudrait un parseur d'URL en shell
# à l'endroit exact où se tromper envoie des identifiants dehors — on ignore.
#
# Pour viser un autre Vault, c'est délibéré et ça se dit : POC_VAULT_ADDR.
POC_VAULT_ADDR_DEFAULT='http://localhost:8200'
VADDR="${POC_VAULT_ADDR:-$POC_VAULT_ADDR_DEFAULT}"
if [ -n "${VAULT_ADDR:-}" ] && [ "$VAULT_ADDR" != "$VADDR" ]; then
  # Dit, pas tu : l'exploitant doit savoir que sa variable n'a pas servi. On
  # n'imprime jamais la valeur héritée, seulement celle effectivement visée.
  printf '  \033[33mnote : le VAULT_ADDR de cet environnement est ignore ; ce harnais vise %s\033[0m\n' "$VADDR" >&2
  printf '  \033[33m       (pour viser ailleurs volontairement : POC_VAULT_ADDR=...)\033[0m\n' >&2
fi
VTOK="${VAULT_TOKEN:?Variable VAULT_TOKEN absente — définissez-la (voir poc-control-plane-federation/.env.example)}"
MOUNT="${USERPASS_MOUNT:-userpass}"
LDAP_MOUNT="${LDAP_MOUNT:-ldap}"
# shellcheck source=scripts/lib/lab-vault-users.sh
. scripts/lib/lab-vault-users.sh

PASS=0; FAIL=0; SKIP=0
ok(){   printf '  \033[32m✓ %s\033[0m\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf '  \033[31m✗ %s\033[0m\n' "$1"; FAIL=$((FAIL+1)); }
skip(){ printf '  \033[33m- %s (sauté)\033[0m\n' "$1"; SKIP=$((SKIP+1)); }
sec(){  printf '\n\033[1m%s\033[0m\n' "$1"; }

# Les mots de passe d'alice, carol et oscar ne vivent plus dans
# lab-vault-users.sh (dépôt public, cf. check-no-plaintext-secrets.sh) : ils
# viennent du fichier root-only du nœud (tâche 4), absent sur un poste de
# développement. Sans lui, TOUTE cette preuve ([userpass] ET [ldap], qui rejoue
# les mêmes identités) se SAUTE plutôt que d'échouer — un test qui n'a pas pu
# tourner ne doit jamais prétendre avoir vérifié.
#
# ⚠ `LAB_BOB_PASS` NE FAIT PLUS PARTIE DE CETTE CONDITION (corrigé 2026-07-30).
# Il ne vient PAS du fichier root-only : c'est l'alias de l'identifiant public
# assumé de bob, défini dans lab-vault-users.sh, donc toujours présent dès que ce
# fichier est sourcé. Le tester ici revenait à poser une question dont la réponse
# ne dépend pas de ce qu'on cherche à savoir — et pendant la fenêtre où l'alias
# avait disparu du dépôt sans remplaçant, cette garde était TOUJOURS vraie : la
# preuve se sautait intégralement même sur un poste correctement équipé, et
# rendait `0 passed … exit 0`, c'est-à-dire VERT. Un test qui ne peut ni passer
# ni échouer ne doit jamais rendre vert.
#
# CE QUE FAIT DÉSORMAIS LA BRANCHE « SAUTÉ » : elle le dit, et elle sort en 2.
# Pourquoi 2 et pas 0 : `0 passed` sur un canal de CI se lit comme un succès.
# Pourquoi 2 et pas 1 : 1 est réservé à « la preuve a été tentée et elle a
# ÉCHOUÉ ». 2 = « rien n'a pu être vérifié » — même convention que le
# provisioning partiel de setup-vault-ldap.sh.
# Pourquoi ne pas « exercer ce qu'on peut » avec le seul mot de passe de bob :
# ce serait un faux signal. Sans le fichier root-only, le monde compose n'a
# jamais été semé du tout (setup-vault-userpass.sh / seed ont besoin des mêmes
# valeurs) — donc bob n'existe pas non plus côté Vault, et ses tests
# échoueraient en accusant le code au lieu de l'environnement manquant. Le saut
# honnête est ici la bonne réponse ; c'est le VERT qui était le défaut.
: "${LAB_ALICE_PASS:=}"
: "${LAB_BOB_PASS:=}"
: "${LAB_CAROL_PASS:=}"
: "${LAB_OSCAR_PASS:=}"
if [ -z "$LAB_ALICE_PASS" ] || [ -z "$LAB_CAROL_PASS" ] || [ -z "$LAB_OSCAR_PASS" ]; then
  skip "toute la preuve [userpass]/[ldap] — mots de passe d'alice/carol/oscar absents (fichier root-only non monté)"
  echo
  echo "=== RESULT: NON CONCLUANT — 0 test exécuté, $SKIP sauté(s) ==="
  echo "    Rien n'a été vérifié. Ce n'est ni un succès ni un échec : monter"
  echo "    /root/stoa-lab-secrets/lab-vault-users.env (tâche 4) puis relancer."
  exit 2
fi
if [ -z "$LAB_BOB_PASS" ]; then
  # Ne peut arriver que si lab-vault-users.sh a cessé de définir l'alias.
  # C'est une régression du dépôt, pas un environnement incomplet : rouge franc.
  bad "LAB_BOB_PASS non défini alors que lab-vault-users.sh est sourcé — l'alias de l'identifiant public de bob a-t-il été supprimé ?"
  echo
  echo "=== RESULT: $PASS passed, $FAIL failed, $SKIP skipped ==="
  exit 1
fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Offset de l'audit AVANT le run : les tests d'audit ne regardent que CE run.
AUD0=$(docker exec poc-vault sh -c 'wc -l < /tmp/vault-audit.log 2>/dev/null || echo 0' 2>/dev/null | tr -d ' ')
AUD0=${AUD0:-0}

# login <mount> <user> <password> -> imprime le chemin du token, ou rien si refus.
# Passe par la LIB du pipeline : c'est bien le code de production qui est éprouvé,
# pas une réimplémentation de test qui pourrait diverger.
login() {
  local mount="$1" user="$2" pass="$3"
  ( set +u
    . ci/lib/vault-login.sh
    export VAULT_ADDR="$VADDR" VAULT_USER_AUTH_MOUNT="$mount" \
           VAULT_USER="$user" VAULT_USER_PASSWORD="$pass"
    unset USER_VAULT_JWT
    if vault_login_nominative >/dev/null 2>&1; then
      # Le token est recopié hors du tmpdir de la lib, que le sous-shell détruit.
      cat "$VAULT_TOKEN_FILE"
    fi
  )
}

vread() { # vread <token> <chemin> -> code HTTP
  local tok="$1" path="$2"
  printf 'X-Vault-Token: %s\n' "$tok" > "$WORK/h"
  curl -s -o /dev/null -w '%{http_code}' -H @"$WORK/h" "$VADDR/v1/$path"
}

curl -s -o /dev/null "$VADDR/v1/sys/health" || { echo "Vault injoignable sur $VADDR"; exit 1; }

# ═══ 1. Chemin nominal ═══════════════════════════════════════════════════════
sec "1. Chemin nominal — l'utilisateur obtient un token NOMINATIF"

T_ALICE=$(login "$MOUNT" "$LAB_ALICE_USER" "$LAB_ALICE_PASS")
[ -n "$T_ALICE" ] && ok "T1  login user/password accepté ($MOUNT/login/$LAB_ALICE_USER)" \
                 || bad "T1  login user/password REFUSÉ"

if [ -n "$T_ALICE" ]; then
  printf 'X-Vault-Token: %s\n' "$T_ALICE" > "$WORK/h"
  LOOK=$(curl -s -H @"$WORK/h" "$VADDR/v1/auth/token/lookup-self")
  DN=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["data"].get("display_name",""))' <<<"$LOOK")
  EID=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["data"].get("entity_id",""))' <<<"$LOOK")
  TTL=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["data"].get("ttl",0))' <<<"$LOOK")
  POL=$(python3 -c 'import sys,json;print(",".join(json.load(sys.stdin)["data"].get("policies",[])))' <<<"$LOOK")

  # NOMINATIF = l'entité Vault porte l'utilisateur, pas « le job » ni « l'application ».
  [ "$DN" = "$MOUNT-$LAB_ALICE_USER" ] \
    && ok "T2  entité Vault NOMINATIVE (display_name=$DN) — pas une identité de job" \
    || bad "T2  display_name=$DN (attendu $MOUNT-$LAB_ALICE_USER)"
  # entity_id : le pivot de corrélation audit Vault ↔ log Jenkins ↔ audit gateway
  # (la gateway ne voit que le compte de service — ADR-078 §3).
  [ -n "$EID" ] && ok "T3  entity_id présent ($EID) — pivot de corrélation des 3 journaux" \
                || bad "T3  entity_id absent"
  # TTL borné : la durée de vie du pouvoir de déployer est celle du build, pas plus.
  [ "$TTL" -gt 0 ] && [ "$TTL" -le 600 ] \
    && ok "T4  TTL borné (${TTL}s ≤ 600) — le pouvoir de déployer expire" \
    || bad "T4  TTL=$TTL hors borne (attendu 1..600)"
  grep -q "deploy-$LAB_TENANT_ALICE" <<<"$POL" \
    && ok "T5  policy de SON tenant attachée ($POL)" || bad "T5  policies=$POL"
fi

# ═══ 2. Ségrégation — enforcée par Vault, PAS par le pipeline ════════════════
sec "2. Ségrégation par tenant — c'est Vault qui refuse, pas le Jenkinsfile"

if [ -n "$T_ALICE" ]; then
  [ "$(vread "$T_ALICE" "secret/data/stoa/deploy/$LAB_TENANT_ALICE/demo")" = 200 ] \
    && ok "T6  alice lit le périmètre de SON tenant ($LAB_TENANT_ALICE) → 200" \
    || bad "T6  alice ne lit pas son propre tenant"
  # LE test qui compte : un Jenkinsfile modifié ne peut pas élargir ce périmètre.
  [ "$(vread "$T_ALICE" "secret/data/stoa/deploy/$LAB_TENANT_BOB/demo")" = 403 ] \
    && ok "T7  CROSS-TENANT REFUSÉ (alice → $LAB_TENANT_BOB) → 403" \
    || bad "T7  cross-tenant NON refusé — la ségrégation ne tient pas"
fi

# bob : mot de passe à MÉTACARACTÈRES (" \ $ ' ; & {}). Un corps JSON forgé en
# shell (`-d "{\"password\":\"$P\"}"`) casse ou s'injecte ici.
T_BOB=$(login "$MOUNT" "$LAB_BOB_USER" "$LAB_BOB_PASS")
[ -n "$T_BOB" ] \
  && ok "T8  mot de passe à MÉTACARACTÈRES accepté — le corps JSON n'est pas forgé en shell" \
  || bad "T8  login refusé avec un mot de passe à métacaractères (échappement JSON cassé)"
if [ -n "$T_BOB" ]; then
  [ "$(vread "$T_BOB" "secret/data/stoa/deploy/$LAB_TENANT_ALICE/demo")" = 403 ] \
    && ok "T9  cross-tenant REFUSÉ dans l'autre sens (bob → $LAB_TENANT_ALICE) → 403" \
    || bad "T9  bob lit le tenant d'alice"
fi

# carol : authentifiée, mais SANS policy de déploiement. L'authentification n'est
# pas l'autorisation — un compte valide de l'annuaire ne déploie pas pour autant.
T_CAROL=$(login "$MOUNT" "$LAB_CAROL_USER" "$LAB_CAROL_PASS")
if [ -n "$T_CAROL" ]; then
  [ "$(vread "$T_CAROL" "secret/data/stoa/deploy/$LAB_TENANT_ALICE/demo")" = 403 ] \
    && ok "T10 carol s'authentifie mais NE DÉPLOIE PAS (aucune policy) → 403" \
    || bad "T10 carol lit un périmètre de déploiement sans y avoir droit"
else
  bad "T10 carol n'a pas pu s'authentifier (elle le devrait)"
fi

# ═══ 3. Refus — fail-closed, jamais de repli silencieux ══════════════════════
sec "3. Refus et fail-closed"

[ -z "$(login "$MOUNT" "$LAB_ALICE_USER" 'mauvais-mot-de-passe')" ] \
  && ok "T11 mauvais mot de passe → aucun token" || bad "T11 un mauvais mot de passe a produit un token"
[ -z "$(login "$MOUNT" 'utilisateur-inexistant' "$LAB_ALICE_PASS")" ] \
  && ok "T12 utilisateur inexistant → aucun token" || bad "T12 un utilisateur inexistant a produit un token"
[ -z "$(login 'mount-qui-nexiste-pas' "$LAB_ALICE_USER" "$LAB_ALICE_PASS")" ] \
  && ok "T13 mount inexistant → aucun token (erreur de config = build rouge)" || bad "T13 mount inexistant accepté"

# Vault injoignable : la lib doit ÉCHOUER, pas retomber en silence sur autre chose.
RC=0
( set +u; . ci/lib/vault-login.sh
  export VAULT_ADDR="http://127.0.0.1:1" VAULT_USER_AUTH_MOUNT="$MOUNT" \
         VAULT_USER="$LAB_ALICE_USER" VAULT_USER_PASSWORD="$LAB_ALICE_PASS"
  unset USER_VAULT_JWT
  vault_login_nominative ) >/dev/null 2>&1 || RC=$?
[ "$RC" = 1 ] && ok "T14 Vault injoignable → échec explicite (code 1), aucun repli silencieux" \
              || bad "T14 Vault injoignable → code $RC (1 attendu)"

# Aucune identité fournie → code 2 : l'appelant fait un PLAN-only. C'est la
# barrière humaine : un build webhook (ACL.SYSTEM) ne peut PAS appliquer.
RC=0
( set +u; . ci/lib/vault-login.sh
  export VAULT_ADDR="$VADDR"; unset USER_VAULT_JWT VAULT_USER VAULT_LDAP_USER
  vault_login_nominative ) >/dev/null 2>&1 || RC=$?
[ "$RC" = 2 ] && ok "T15 aucune identité → code 2 (PLAN-only) : un webhook n'applique jamais" \
              || bad "T15 aucune identité → code $RC (2 attendu)"

# ═══ 4. Le secret ne fuit pas ════════════════════════════════════════════════
sec "4. Non-fuite du mot de passe et du token"

# argv : le mot de passe ne doit apparaître dans la ligne de commande d'AUCUN
# process (ps / /proc/<pid>/cmdline sont lisibles par les autres builds du nœud).
SENTINEL="Sentinel-argv-$$"
curl -s -o /dev/null -H "X-Vault-Token: $VTOK" -X POST \
  "$VADDR/v1/auth/$MOUNT/users/sentinel" \
  -d "{\"password\":\"$SENTINEL\",\"token_policies\":\"\",\"token_ttl\":60}"
PSOUT="$WORK/ps.txt"
( login "$MOUNT" 'sentinel' "$SENTINEL" >/dev/null & LPID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do ps -ww -o command= -ax >> "$PSOUT" 2>/dev/null; done
  wait $LPID ) 2>/dev/null
grep -q "$SENTINEL" "$PSOUT" \
  && bad "T16 le mot de passe APPARAÎT en argv (visible par ps depuis un autre build)" \
  || ok "T16 mot de passe ABSENT de argv pendant tout le login (ps échantillonné 10×)"

# log : la lib ne doit rien imprimer de secret, même en marche nominale.
LOGOUT="$WORK/log.txt"
( set +u; . ci/lib/vault-login.sh
  export VAULT_ADDR="$VADDR" VAULT_USER_AUTH_MOUNT="$MOUNT" \
         VAULT_USER="$LAB_ALICE_USER" VAULT_USER_PASSWORD="$LAB_ALICE_PASS"
  unset USER_VAULT_JWT
  vault_login_nominative && cat "$VAULT_TOKEN_FILE" > "$WORK/tok" ) > "$LOGOUT" 2>&1
grep -q "$LAB_ALICE_PASS" "$LOGOUT" \
  && bad "T17 le mot de passe apparaît dans la sortie de la lib" \
  || ok "T17 mot de passe ABSENT de la sortie de la lib"
if [ -s "$WORK/tok" ] && grep -qF "$(cat "$WORK/tok")" "$LOGOUT"; then
  bad "T18 le token Vault apparaît dans la sortie de la lib"
else
  ok "T18 token Vault ABSENT de la sortie de la lib (seuls entité/TTL/policies sont affichés)"
fi

# MODE DEBUG (STOA_DEBUG) : montre BEAUCOUP plus (appels, codes, erreurs) — il
# doit rester NON-FUYANT. On capture TOUTE la sortie debug d'un login réussi ET
# d'un login raté (mot de passe sentinelle) et on vérifie que NI le mot de passe
# NI le token n'y apparaissent.
DBGOUT="$WORK/dbg.txt"
DBGSENTINEL="Sentinel-dbg-$$-a1b2c3"
( set +u; . ci/lib/vault-login.sh
  export STOA_DEBUG=1 VAULT_ADDR="$VADDR" VAULT_USER_AUTH_MOUNT="$MOUNT"
  # 1) login réussi (alice) : trace + lecture KV
  export VAULT_USER="$LAB_ALICE_USER" VAULT_USER_PASSWORD="$LAB_ALICE_PASS"; unset USER_VAULT_JWT
  vault_login_nominative && cat "$VAULT_TOKEN_FILE" > "$WORK/tok2"
  vault_read "secret/data/stoa/deploy/$LAB_TENANT_ALICE/wm-admin" username >/dev/null
  vault_revoke_proof
  # 2) login raté avec un mot de passe SENTINELLE (doit tracer l'erreur, pas le mdp)
  export VAULT_USER="alice" VAULT_USER_PASSWORD="$DBGSENTINEL"
  vault_login_nominative ) > "$DBGOUT" 2>&1
grep -q "$LAB_ALICE_PASS" "$DBGOUT" && bad "D1 [debug] mot de passe d'alice dans la sortie debug" \
  || grep -q "$DBGSENTINEL" "$DBGOUT" && bad "D1 [debug] mot de passe sentinelle dans la sortie debug" \
  || ok "D1 [debug] STOA_DEBUG actif : AUCUN mot de passe dans la sortie (ni réussi ni raté)"
if [ -s "$WORK/tok2" ] && grep -qF "$(cat "$WORK/tok2")" "$DBGOUT"; then
  bad "D2 [debug] le token Vault apparaît dans la sortie debug"
else
  ok "D2 [debug] token Vault ABSENT de la sortie debug (appels/codes/erreurs seulement)"
fi
# et le debug DOIT être utile : l'erreur de bind du login raté est bien tracée.
grep -qE "HTTP 4[0-9][0-9]|bind|denied|REFUSÉ" "$DBGOUT" \
  && ok "D3 [debug] l'erreur du login raté EST visible (code HTTP / message) — diagnostic utile" \
  || bad "D3 [debug] le login raté n'a produit aucune trace exploitable"

# ═══ 5. Révocation — y compris quand le build échoue ═════════════════════════
sec "5. Révocation et preuve de mort"

TOK_OK=$( set +u; . ci/lib/vault-login.sh
  export VAULT_ADDR="$VADDR" VAULT_USER_AUTH_MOUNT="$MOUNT" \
         VAULT_USER="$LAB_ALICE_USER" VAULT_USER_PASSWORD="$LAB_ALICE_PASS"
  unset USER_VAULT_JWT
  vault_login_nominative >/dev/null 2>&1 && cat "$VAULT_TOKEN_FILE" )
if [ -n "$TOK_OK" ]; then
  ( set +u; . ci/lib/vault-login.sh
    export VAULT_ADDR="$VADDR" VAULT_USER_AUTH_MOUNT="$MOUNT" \
           VAULT_USER="$LAB_ALICE_USER" VAULT_USER_PASSWORD="$LAB_ALICE_PASS"
    unset USER_VAULT_JWT
    vault_login_nominative >/dev/null 2>&1
    vault_revoke_proof ) >/dev/null 2>&1 \
    && ok "T19 revoke-self + preuve de mort (lookup-self → 403) réussis" \
    || bad "T19 révocation ou preuve de mort en échec"
fi

# LE cas que l'ancien code ratait : `revoke` en dernière instruction sous `set -e`
# est SAUTÉ dès qu'une étape échoue, et le token survit jusqu'à son TTL.
#
# Simulé dans un VRAI processus fils (`bash -c`), pas un sous-shell `( … )` : un
# sous-shell placé à gauche d'un `||` hérite de la suspension de `set -e` du shell
# appelant, le `false` n'interromprait rien et le test se prouverait lui-même faux.
BUILD_RC=0
WORKDIR="$WORK" VADDR="$VADDR" MNT="$MOUNT" U="$LAB_ALICE_USER" P="$LAB_ALICE_PASS" \
bash -c '
  set -eu
  . ci/lib/vault-login.sh
  export VAULT_ADDR="$VADDR" VAULT_USER_AUTH_MOUNT="$MNT" VAULT_USER="$U" VAULT_USER_PASSWORD="$P"
  unset USER_VAULT_JWT
  trap vault_trap_revoke EXIT
  vault_login_nominative >/dev/null 2>&1
  cp "$VAULT_TOKEN_FILE" "$WORKDIR/tok-fail"
  false                       # ← simule une convergence Ansible qui échoue
  echo "jamais atteint"
' >/dev/null 2>&1 || BUILD_RC=$?
[ "$BUILD_RC" != 0 ] && ok "T20 un build en échec reste ROUGE (code $BUILD_RC préservé par le trap)" \
                     || bad "T20 le trap a masqué l'échec du build"
if [ -s "$WORK/tok-fail" ]; then
  printf 'X-Vault-Token: %s\n' "$(cat "$WORK/tok-fail")" > "$WORK/h"
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H @"$WORK/h" "$VADDR/v1/auth/token/lookup-self")" = 403 ] \
    && ok "T21 token RÉVOQUÉ alors même que le build a ÉCHOUÉ (lookup-self → 403)" \
    || bad "T21 le token survit à un build en échec"
else
  bad "T21 token du build en échec non capturé"
fi

# ═══ 6. Audit — la traçabilité nominative que l'IT exige ════════════════════
sec "6. Audit Vault (succès ET refus, sur CE run)"

AUDLOG=$(docker exec poc-vault sh -c "tail -n +$((AUD0+1)) /tmp/vault-audit.log 2>/dev/null" 2>/dev/null \
         | grep "auth/$MOUNT/login" || true)
if [ -n "$AUDLOG" ]; then
  grep -q "\"display_name\":\"$MOUNT-$LAB_ALICE_USER\"" <<<"$AUDLOG" \
    && ok "T22 audit Vault NOMINATIF sur ce run (display_name=$MOUNT-$LAB_ALICE_USER)" \
    || bad "T22 audit non nominatif sur ce run"
  grep -q '"error":' <<<"$AUDLOG" \
    && ok "T23 les REFUS de ce run sont audités aussi (tentatives tracées)" \
    || bad "T23 aucun refus audité sur ce run"
  grep -q "$LAB_ALICE_PASS" <<<"$AUDLOG" \
    && bad "T24 un mot de passe EN CLAIR dans l'audit Vault" \
    || ok "T24 aucun mot de passe en clair dans l'audit (Vault hashe les champs sensibles)"
else
  skip "T22-T24 audit device inactif ou poc-vault inaccessible"
fi

# ═══ 7. [ldap] Formats de login AD — palier annuaire réel ═══════════════════
sec "7. [ldap] Formats de login de l'annuaire (UPN, DOMAIN\\user)"

if curl -s -H "X-Vault-Token: $VTOK" "$VADDR/v1/sys/auth" \
     | grep -q "\"$LDAP_MOUNT/\""; then

  # Trouvaille live 2026-07-22 : `userpass` REFUSE '@' et '\' dans un username
  # (GenericNameRegex : \w, '-', '.'), le backend `ldap` les accepte (pattern .+).
  # Le format de login contraint donc le choix du backend — ce n'est pas cosmétique.
  N=25
  for U in "$LAB_ALICE_UPN_USER" "$LAB_ALICE_DOMAIN_USER"; do
    if [ -n "$(login "$LDAP_MOUNT" "$U" "$LAB_ALICE_PASS")" ]; then
      ok "T$N format d'entreprise '$U' accepté (path URL-encodé : @→%40, \\→%5C)"
    else
      bad "T$N format '$U' refusé — vérifier userattr/upndomain du mount $LDAP_MOUNT"
    fi
    N=$((N+1))
  done

  # LE test qui valide le modèle d'autorisation du palier LDAP : la policy n'est
  # PAS attachée à l'utilisateur, elle vient de son GROUPE d'annuaire. C'est ce
  # qui remplace la policy templatée par claim `tenant` d'ADR-077 — et ce qui
  # impose au client UN GROUPE AD PAR TENANT.
  T_LA=$(login "$LDAP_MOUNT" "$LAB_ALICE_USER" "$LAB_ALICE_PASS")
  if [ -n "$T_LA" ]; then
    printf 'X-Vault-Token: %s\n' "$T_LA" > "$WORK/h"
    LPOL=$(curl -s -H @"$WORK/h" "$VADDR/v1/auth/token/lookup-self" \
           | python3 -c 'import sys,json;print(",".join(json.load(sys.stdin)["data"].get("policies",[])))')
    grep -q "deploy-$LAB_TENANT_ALICE" <<<"$LPOL" \
      && ok "T27 policy HÉRITÉE DU GROUPE d'annuaire (apim-deploy-$LAB_TENANT_ALICE → $LPOL)" \
      || bad "T27 policy non héritée du groupe (policies=$LPOL) — groupdn/groupattr du mount ?"
    [ "$(vread "$T_LA" "secret/data/stoa/deploy/$LAB_TENANT_BOB/demo")" = 403 ] \
      && ok "T28 cross-tenant REFUSÉ sur le mount annuaire (alice → $LAB_TENANT_BOB) → 403" \
      || bad "T28 cross-tenant NON refusé sur le mount annuaire"
  else
    bad "T27-T28 login annuaire d'alice refusé"
  fi

  # carol est dans l'annuaire, dans un groupe — mais un groupe SANS policy.
  T_LC=$(login "$LDAP_MOUNT" "$LAB_CAROL_USER" "$LAB_CAROL_PASS")
  if [ -n "$T_LC" ]; then
    [ "$(vread "$T_LC" "secret/data/stoa/deploy/$LAB_TENANT_ALICE/demo")" = 403 ] \
      && ok "T29 groupe d'annuaire NON mappé → authentifiée mais aucun déploiement (403)" \
      || bad "T29 un groupe non mappé donne accès au déploiement"
  else
    bad "T29 carol ne s'authentifie pas contre l'annuaire"
  fi
else
  skip "T25-T29 mount $LDAP_MOUNT absent — lancer scripts/setup-vault-ldap.sh (userpass ne peut porter ni '@' ni '\\')"
fi

# ═══ 8. Deux périmètres DISJOINTS : déployeur de tenant vs opérateur de prod ═══
sec "8. Périmètre de l'opérateur de mise en prod (Jenkinsfile.prod/.rollback)"

# Jenkinsfile.prod/.rollback lisent des secrets de PLATEFORME (stoa/ci,
# stoa/opensearch, stoa/gateways/*) — hors de toute policy deploy-<tenant>. D'où
# une policy `operator-deploy` séparée. Ce qui doit être prouvé n'est pas qu'elle
# marche, mais que les deux périmètres sont DISJOINTS dans les DEUX sens : un
# déployeur de tenant ne lit pas les secrets de plateforme, et un opérateur de
# prod ne lit pas les périmètres de déploiement des tenants.
T_OSCAR=$(login "$MOUNT" "$LAB_OSCAR_USER" "$LAB_OSCAR_PASS")
if [ -n "$T_OSCAR" ]; then
  [ "$(vread "$T_OSCAR" "secret/data/stoa/ci")" = 200 ] \
    && ok "T30 opérateur prod lit les secrets de PLATEFORME (stoa/ci) → 200" \
    || bad "T30 opérateur prod ne lit pas stoa/ci — Jenkinsfile.prod ne peut pas tourner en nominatif"
  [ "$(vread "$T_OSCAR" "secret/data/stoa/gateways/webmethods")" = 200 ] \
    && ok "T31 opérateur prod lit les creds admin gateway → 200" \
    || bad "T31 opérateur prod ne lit pas gateways/webmethods"
  [ "$(vread "$T_OSCAR" "secret/data/stoa/deploy/$LAB_TENANT_ALICE/demo")" = 403 ] \
    && ok "T32 opérateur prod N'ACCÈDE PAS au périmètre d'un tenant → 403" \
    || bad "T32 l'opérateur prod lit le périmètre d'un tenant (périmètres non disjoints)"
else
  bad "T30-T32 login de l'opérateur prod refusé"
fi
if [ -n "$T_ALICE" ]; then
  # La réciproque, celle qui compte pour le client : donner le déploiement d'un
  # tenant à quelqu'un ne lui donne PAS les secrets de service de la plateforme.
  [ "$(vread "$T_ALICE" "secret/data/stoa/ci")" = 403 ] \
    && ok "T33 déployeur de tenant N'ACCÈDE PAS aux secrets de plateforme → 403" \
    || bad "T33 un déployeur de tenant lit stoa/ci (périmètres non disjoints)"
fi

# Le jeton du compte de service doit s'obtenir SANS mettre le client_secret en argv
# (form_post_no_argv), sinon Jenkinsfile.prod le fuiterait dans ps à chaque prod.
KCURL="${KC_TOKEN_URL:-http://localhost:8480/realms/stoa-lab/protocol/openid-connect/token}"
KCOUT=$( set +u
  . ci/lib/vault-login.sh
  export VAULT_ADDR="$VADDR" VAULT_USER_AUTH_MOUNT="$MOUNT" \
         VAULT_USER="$LAB_OSCAR_USER" VAULT_USER_PASSWORD="$LAB_OSCAR_PASS"
  unset USER_VAULT_JWT
  vault_login_nominative >/dev/null 2>&1 || exit 1
  SEC=$(vault_read secret/data/stoa/ci ciApplierSecret) || exit 1
  RESP=$(vault_tmpfile kc.json)
  printf 'client_id=ci-applier\ngrant_type=client_credentials\nclient_secret=%s\n' "$SEC" \
    | form_post_no_argv "$RESP" "$KCURL"
  python3 -c 'import json,sys;print("TOKEN_OK" if json.load(open(sys.argv[1])).get("access_token") else "NO_TOKEN")' "$RESP"
  vault_revoke_proof >/dev/null 2>&1 )
grep -q TOKEN_OK <<<"$KCOUT" \
  && ok "T34 jeton du compte de service obtenu avec le client_secret HORS argv (chaîne Jenkinsfile.prod)" \
  || skip "T34 chaîne Jenkinsfile.prod non vérifiable ici (Keycloak/ci-applier indisponible : $(tr -d '\n' <<<"$KCOUT" | tail -c 60))"

curl -s -o /dev/null -H "X-Vault-Token: $VTOK" -X DELETE "$VADDR/v1/auth/$MOUNT/users/sentinel"

echo
echo "=== RESULT: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
