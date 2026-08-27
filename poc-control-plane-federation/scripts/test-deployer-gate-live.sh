#!/usr/bin/env bash
# test-deployer-gate-live.sh — porte LIVE G2 (ADR-084) : le grant déployeur SUIT
# L'ANNUAIRE (lab requis : openldap + Vault).
#
# Les portes hors-ligne du jalon lisent ce que les moteurs ÉMETTENT (un refus
# nommé, un ordre d'exécution). Celle-ci mesure la seule chose qu'aucune d'elles
# ne peut voir : ce que Vault MET RÉELLEMENT dans le token d'un porteur, et ce
# qu'il y met quand l'annuaire change. Toute la déclaration `deployerGroup` de
# la chaîne repose sur cette projection ; si elle ne tient pas, les portes
# refusent ou laissent passer sur une croyance.
#
#   ① pose réelle des groupes (setup-deployer-groups.sh), REJOUÉE — la seconde
#     passe est la branche de CONVERGENCE, invisible au premier passage ;
#   ② le déployeur du palier se connecte ⇒ son token PORTE la policy projetée ;
#   ③ la DEMANDEUSE se connecte ⇒ son token ne porte AUCUNE policy de déployeur ;
#   ④ le miroir shell (`deployer_group_policy`) projette ce que Vault a mis —
#     et refuse rc=1 un nom de l'autre annuaire ;
#   ⑤ CONTRE-ÉPREUVE DU GRANT VIVANT : le déployeur retiré de l'annuaire ⇒
#     re-login SANS la policy ; restauration ⇒ re-login qui la re-porte ;
#   ⑥ après restauration, la demandeuse est toujours membre de RIEN.
#
# ── CE QUE ⑤ PROUVE, ET CE QU'IL MESURE AU PASSAGE ──────────────────────────
# Prouve : le droit de déployer n'est pas un état gelé au provisioning — il est
# RE-ÉVALUÉ à chaque login contre l'annuaire. Retirer quelqu'un du groupe suffit
# à lui retirer le palier, sans toucher ni Vault ni la chaîne.
# Mesure (⑤quater) : le token DÉJÀ ÉMIS, lui, garde la policy jusqu'à son TTL.
# Retrait ≠ révocation. C'est exactement pourquoi la porte doit se vérifier AU
# DISPATCH, sur le token du geste, et jamais « à l'approbation » sur un droit
# constaté plus tôt — un porteur écarté ce matin déploierait tout l'après-midi.
#
# ── CE QUE CE SCRIPT ÉCRIT DANS LE LAB, ET CE QU'IL REMET ────────────────────
# Le lab est PARTAGÉ. Ce script :
#   - POSE les groupes déployeurs (c'est le mécanisme lui-même, geste idempotent
#     — ils restent posés, comme après tout passage du poseur) ;
#   - RETIRE le déployeur du SEUL groupe du palier cible, puis le RESTAURE par
#     le poseur et RELIT L'ANNUAIRE pour le vérifier. `groupOfNames` exige au
#     moins un `member` (RFC 4519) : retirer le DERNIER est un refus 65 de
#     l'annuaire (mesuré), donc le groupe est alors SUPPRIMÉ en entier et
#     re-créé à la restauration. Aucun autre objet n'est touché ;
#   - ne touche NI Vault (aucune policy, aucun mapping), NI les groupes des
#     autres paliers, NI `apim-operator-prod`.
# Le trap restaure INCONDITIONNELLEMENT, y compris sur échec ou interruption.
#
# ── FAIL-CLOSED, JAMAIS DE SKIP MUET ────────────────────────────────────────
# Prérequis manquant (Vault muet, conteneur d'annuaire absent, mount ldap non
# monté, mot de passe de lab introuvable) ⇒ `exit 2` avec `LAB_ABSENT : <détail>`.
# Une porte live qui « se saute toute seule » quand le lab tombe est pire
# qu'absente : elle rend vert. exit 2 la distingue d'un ÉCHEC de mesure (exit 1).
#
#   bash scripts/test-deployer-gate-live.sh
#
# AUCUN token Vault n'est requis : la porte ne se sert que d'identités HUMAINES,
# c'est le sujet même de la mesure. Le mot de passe de bob est publié dans
# lib/lab-vault-users.sh (arbitrage assumé, documenté sur place) ; ceux d'alice,
# carol et oscar sont lus dans .env.lab-users (0600, hors Git).
#
# `A && ok || bad` (SC2015) est l'idiome des scripts de preuve du repo ; le `$?`
# relu juste après la commande qui le produit (SC2181) est une lecture immédiate
# et non ambiguë.
# shellcheck disable=SC2015,SC2181
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
umask 077
TMP=$(mktemp -d)

lab_absent(){ echo "LAB_ABSENT : $*" >&2; exit 2; }

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
LDAP_CONTAINER="${LDAP_CONTAINER:-poc-openldap}"
BASE_DN="${LDAP_BASE_DN:-dc=corp,dc=example}"
BIND_DN="${LDAP_BIND_DN:-cn=admin,$BASE_DN}"
BIND_PW="${LDAP_ADMIN_PASSWORD:-admin-lab-2026}"

# ── ÉTAT DE LA MUTATION, déclaré AVANT le trap ──────────────────────────────
# `set -u` casserait un trap qui se déclenche tôt sur une variable pas encore
# née (motif test-palier-retention-live.sh:110). Tout ce que la restauration
# lit est donc déclaré ici, avant qu'elle puisse être appelée.
MUTATED=0        # 1 dès que l'annuaire est touché
MUT_GROUP=""     # le groupe muté
MUT_USER=""      # le membre retiré
RESTORE_KO=0     # 1 si la restauration a échoué — le verdict final le reflète
# La commande de réparation EXACTE, calculée au moment de la mutation (elle a
# besoin du palier et de la liste des membres d'AVANT). Défaut : l'invocation
# nue du poseur, qui suffit tant que la cible est l'un de ses membres par
# défaut. Voir le calcul en ⑤ pour le cas où elle ne l'est pas.
MUT_REPAIR="bash scripts/setup-deployer-groups.sh"

# ── L'appel client LDAP ─────────────────────────────────────────────────────
# MÊME PLOMBERIE que setup-deployer-groups.sh:129 (mot de passe de bind ni dans
# l'argv de l'hôte ni dans celui du conteneur : `-e VAR` sans valeur + `-y`
# fichier 0600 détruit derrière). Dupliquée et non partagée parce que la porte a
# besoin d'un geste que le poseur ne rend délibérément PAS disponible — retirer
# un membre, supprimer un groupe. Une lib commune pour deux appelants dont un
# seul doit pouvoir détruire serait un mauvais service rendu.
ldap_run(){   # ldap_run <ldapadd|ldapmodify|ldapdelete|ldapsearch> [args…]  < LDIF
  local tool="$1"; shift
  LDAP_BIND_PW="$BIND_PW" docker exec -i -e LDAP_BIND_PW "$LDAP_CONTAINER" \
    sh -c 'umask 077; f=/tmp/.ldap-bind.$$
           printf %s "$LDAP_BIND_PW" > "$f"
           t="$1"; d="$2"; shift 2
           "$t" -x -D "$d" -y "$f" "$@"; rc=$?
           rm -f "$f"; exit $rc' sh "$tool" "$BIND_DN" "$@"
}

# group_members <cn> — un uid par ligne ; VIDE si le groupe est absent.
# `-o ldif-wrap=no` : sans lui un DN de membre au-delà de 78 colonnes est REPLIÉ
# et le `sed` ne le voit plus — un membre présent serait rapporté absent.
group_members(){
  ldap_run ldapsearch -LLL -o ldif-wrap=no \
      -b "cn=$1,ou=Groups,$BASE_DN" -s base member 2>/dev/null \
    | sed -n 's/^member: uid=\([^,]*\),.*/\1/p'
}

# ── RESTAURATION ────────────────────────────────────────────────────────────
# Par le POSEUR lui-même, jamais par un LDIF maison : ce que la porte remet doit
# être ce que l'exploitant poserait, sinon elle restaure un état qui n'existe
# nulle part. RELUE ensuite dans l'annuaire — une restauration dont personne ne
# lit le résultat laisse le lab cassé pendant qu'on imprime « 0 FAIL ».
restore_group(){
  [ "$MUTATED" -eq 1 ] || return 0
  bash scripts/setup-deployer-groups.sh >"$TMP/restore.log" 2>&1
  local rc=$? got
  got=" $(group_members "$MUT_GROUP" | tr '\n' ' ')"
  case "$got" in
    *" $MUT_USER "*)
      MUTATED=0
      [ "$rc" -eq 0 ] || echo "NOTE : le poseur rend rc=$rc mais $MUT_USER est bien remis dans $MUT_GROUP" >&2
      return 0 ;;
  esac
  RESTORE_KO=1
  # La commande de réparation est IMPRIMÉE TELLE QUELLE, prête à coller. Le
  # poseur nu ne suffit PAS toujours : il repose ses membres PAR DÉFAUT, et la
  # cible de cette porte est dérivée de l'ANNUAIRE (elle peut donc être
  # quelqu'un que les défauts ne nomment pas). D'où le knob DEPLOYERS_<PALIER>
  # calculé en ⑤ sur la liste d'AVANT la mutation. Un exploitant qui lit
  # « lab laissé AMPUTÉ » doit pouvoir réparer sans relire le script.
  {
    echo "RESTAURATION ECHOUEE : $MUT_USER n'est PAS revenu dans $MUT_GROUP (poseur rc=$rc) — lab laissé AMPUTÉ."
    echo "  RÉPARER (commande exacte, à coller depuis $(pwd)) :"
    echo "      $MUT_REPAIR"
    echo "  VÉRIFIER ensuite que le membre est bien revenu :"
    echo "      docker exec $LDAP_CONTAINER ldapsearch -x -b 'cn=$MUT_GROUP,ou=Groups,$BASE_DN' -s base member"
    echo "  dernières lignes du poseur :"
  } >&2
  tail -5 "$TMP/restore.log" >&2
  return 1
}

teardown(){
  restore_group || true
  rm -rf "$TMP"
}
trap teardown EXIT INT TERM

# ── PRÉAMBULE : le lab est-il là ? ──────────────────────────────────────────
for b in curl python3 docker sed; do
  command -v "$b" >/dev/null 2>&1 || lab_absent "$b introuvable — prérequis de cette porte"
done
curl -s -m 5 -o /dev/null "$VAULT_ADDR/v1/sys/health" \
  || lab_absent "Vault ne répond pas à $VAULT_ADDR"
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$LDAP_CONTAINER" \
  || lab_absent "conteneur d'annuaire '$LDAP_CONTAINER' absent — docker compose -f docker-compose.poc.yml -f docker-compose.ldap.yml up -d openldap"
# Bind + lecture réels, sur la racine et non sur un groupe nommé : la porte ne
# doit pas dépendre de l'existence d'un objet qu'elle n'a pas posé.
ldap_run ldapsearch -LLL -b "$BASE_DN" -s base dn >/dev/null 2>&1 \
  || lab_absent "annuaire '$LDAP_CONTAINER' injoignable ou bind refusé sur $BASE_DN — vérifier LDAP_ADMIN_PASSWORD, puis scripts/setup-vault-ldap.sh"

# Le mount `auth/ldap` existe-t-il ? Sondé SANS credential, par un login voué à
# échouer : sur un mount MONTÉ, Vault rend 400 « failed to bind as user » ; sur
# un chemin ABSENT il rend 403 « permission denied » (il ne révèle pas ses
# routes à un anonyme — mesuré, ce n'est PAS un 404). Sans cette distinction, un
# mount disparu ferait rougir ② au lieu de dire que le lab est incomplet.
#
# ⚠ LE NOM DE LA SONDE DOIT ÊTRE NEUF À CHAQUE PASSAGE — piège mesuré le
# 2026-08-27, au 6e run. Vault verrouille un ALIAS après 5 échecs de login en
# 15 min (user lockout, activé par défaut depuis 1.13) et répond alors 403 :
# avec un nom FIXE, la sonde se verrouille elle-même et la porte accuse un
# « mount absent » sur un lab parfaitement sain. Le diagnostic faux d'une porte
# de diagnostic est le pire des défauts — il envoie réparer ce qui marche.
PROBE_USER="zz-probe-inexistant-$$-${RANDOM}"
PROBE_CODE="$(curl -s -m 10 -o "$TMP/probe.json" -w '%{http_code}' \
  -X POST "$VAULT_ADDR/v1/auth/ldap/login/$PROBE_USER" \
  -H 'Content-Type: application/json' -d '{"password":"x"}')"
[ "$PROBE_CODE" = 400 ] \
  || lab_absent "mount auth/ldap absent ou muet (sonde anonyme HTTP $PROBE_CODE, attendu 400) — jouer scripts/setup-vault-ldap.sh"

# shellcheck source=scripts/lib/env-chain.sh
. scripts/lib/env-chain.sh
# shellcheck source=scripts/lib/lab-vault-users.sh
. scripts/lib/lab-vault-users.sh
# Mots de passe de lab hors Git (0600). Absent ⇒ seul bob est jouable, et ③/⑥
# (la demandeuse) deviennent impossibles : c'est un lab incomplet, pas un échec.
# shellcheck source=/dev/null
[ -r .env.lab-users ] && { set -a; . ./.env.lab-users; set +a; }

ENVS_NONPROD="$(env_chain_nonprod)" || lab_absent "chaîne d'environnements illisible (env_chain_nonprod)"
ALL_ENVS="$(env_chain)" || lab_absent "chaîne d'environnements illisible (env_chain)"
echo "Chaîne : $ALL_ENVS — hors-prod '$ENVS_NONPROD'"

# ── PROJECTION DE LA CHAÎNE : toutes les policies de déployeur déclarées ─────
# Dérivées, JAMAIS écrites en dur : une chaîne qui gagne un palier gagne son
# épreuve sans toucher ce fichier. C'est cette liste que la demandeuse ne doit
# porter EN ENTIER — pas seulement les deux paliers que le lab ouvre.
DEPLOYER_POLICIES=""
for e in $ALL_ENVS; do
  g="$(env_chain_gate_deployer_group "$e")" || lab_absent "porte du palier $e illisible"
  [ -n "$g" ] || continue
  p="$(deployer_group_policy "$g")" \
    || lab_absent "la chaîne déclare deployerGroup='$g' (palier $e), hors des deux familles vérifiables — la chaîne du lab est cassée"
  DEPLOYER_POLICIES="$DEPLOYER_POLICIES $p"
  echo "  porte $e : deployerGroup=$g ⇒ policy projetée '$p'"
done
[ -n "$DEPLOYER_POLICIES" ] \
  || lab_absent "aucune porte de la chaîne ne déclare de deployerGroup — rien à mesurer"

# ── LOGIN NOMINATIF, sans un seul secret en argv ────────────────────────────
# Discipline de ci/lib/vault-login.sh:224-238, reprise telle quelle :
#   · corps JSON produit par python3 (json.dumps) — jamais forgé en shell : le
#     mot de passe de bob porte " \ $ ' ; & { } et casserait un JSON à la main ;
#   · mot de passe passé à python par l'ENVIRONNEMENT, jamais en argv ;
#   · corps envoyé par FICHIER (--data-binary @) puis détruit — jamais en argv ;
#   · user URL-encodé dans le path (`CORP\alice` → CORP%5Calice, UPN → %40).
login_token(){   # login_token <uid> <nom_de_variable_mot_de_passe> — imprime le token, vide si refus
  local user="$1" pv="$2" body="$TMP/body.json" resp="$TMP/login.json" code uenc
  [ -n "${!pv:-}" ] || return 1
  P="${!pv}" python3 - "$body" <<'PY' || return 1
import json, os, sys
open(sys.argv[1], "w").write(json.dumps({"password": os.environ["P"]}))
PY
  uenc="$(U="$user" python3 -c 'import os,urllib.parse;print(urllib.parse.quote(os.environ["U"], safe=""))')"
  code="$(curl -s -m 20 -o "$resp" -w '%{http_code}' \
    -X POST "$VAULT_ADDR/v1/auth/ldap/login/$uenc" \
    -H 'Content-Type: application/json' --data-binary "@$body")"
  rm -f "$body"
  [ "$code" = 200 ] || { echo "    (login $user : HTTP $code)" >&2; return 1; }
  F="$resp" python3 -c 'import os,json;print((json.load(open(os.environ["F"])).get("auth") or {}).get("client_token",""))'
}

# lookup_policies <token> <fichier de sortie> — les policies que Vault dit
# LUI-MÊME porter par ce token, une par ligne.
#
# `lookup-self` et pas le corps du login : le login rend ce que Vault a DÉCIDÉ
# d'accorder, lookup-self ce que le token PORTE encore à l'instant de la
# question. Les deux coïncident ici, mais c'est le second que la porte
# d'ADR-084 interrogera au dispatch — on mesure donc le même objet qu'elle.
#
# Le token part par FICHIER D'EN-TÊTES (`curl -H @fichier`), jamais en argv, et
# la RÉPONSE est capturée dans un fichier AVANT d'être lue par python : jamais
# de `curl | grep && … || …`, dont le code de retour sous `pipefail` est celui
# du grep et non celui de l'appel (piège de repo).
lookup_policies(){
  local tok="$1" out="$2" h="$TMP/hdr" code
  printf 'X-Vault-Token: %s\n' "$tok" > "$h"
  code="$(curl -s -m 20 -o "$TMP/lookup.json" -w '%{http_code}' -H @"$h" \
    "$VAULT_ADDR/v1/auth/token/lookup-self")"
  rm -f "$h"
  [ "$code" = 200 ] || { : > "$out"; return 1; }
  # `policies` ET `identity_policies` : un grant passé par l'entité Identity
  # plutôt que par le mapping de groupe n'apparaît que dans la seconde. Les
  # ignorer rendrait ③ vert sur une demandeuse pourtant déployeuse.
  F="$TMP/lookup.json" python3 -c '
import os, json
d = json.load(open(os.environ["F"]))["data"]
for p in (d.get("policies") or []) + (d.get("identity_policies") or []):
    print(p)' > "$out"
}

has_policy(){ grep -qx "$2" "$1"; }        # has_policy <fichier> <policy>
policies_line(){ tr '\n' ' ' < "$1"; }

# pass_var_for <uid> — la variable qui porte le mot de passe de lab de cet uid.
# rc=1 pour un compte dont la porte n'a pas le secret : elle le DIT plutôt que
# de rougir sur un login impossible.
pass_var_for(){
  case "$1" in
    "$LAB_BOB_USER")   printf 'LAB_BOB_PASS' ;;
    "$LAB_ALICE_USER") printf 'LAB_ALICE_PASS' ;;
    "$LAB_CAROL_USER") printf 'LAB_CAROL_PASS' ;;
    "$LAB_OSCAR_USER") printf 'LAB_OSCAR_PASS' ;;
    *) return 1 ;;
  esac
}

echo
echo "== ① pose réelle des groupes déployeurs, puis REJEU =="
# Le REJEU n'est pas une coquetterie : le premier passage ne fait que des
# `ldapadd`, la seconde passe emprunte la branche `Already exists` → `replace:
# member`, la seule qui porte la CONVERGENCE annoncée. Un défaut qui n'existe
# que là est resté invisible jusqu'à cette porte (corrigé le 2026-08-27 : le
# terminateur LDIF `-` mangé comme une option par le printf de bash).
bash scripts/setup-deployer-groups.sh >"$TMP/pose1.log" 2>&1 \
  && ok "① pose des groupes déployeurs : rc=0 ($(grep -c '^  .*PASS' "$TMP/pose1.log") PASS interne)" \
  || { bad "① pose en échec : $(tail -3 "$TMP/pose1.log" | tr '\n' ' ')"; printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"; exit 1; }
bash scripts/setup-deployer-groups.sh >"$TMP/pose2.log" 2>&1 \
  && ok "①bis REJEU : rc=0 — idempotent ET convergent (branche replace: member)" \
  || bad "①bis le rejeu rend rc≠0 — la pose n'est pas idempotente : $(grep FAIL "$TMP/pose2.log" | head -2 | tr '\n' ' ')"

# ── CIBLE : dérivée de la chaîne ET de l'annuaire, jamais nommée en dur ──────
# Le palier mesuré est le PREMIER palier hors-prod dont la porte déclare un
# groupe de la famille `apim-apply-*` ET dont l'annuaire porte un membre dont ce
# lab connaît le mot de passe. Prendre le membre DANS L'ANNUAIRE plutôt que dans
# les défauts du poseur, c'est déjà la thèse du jalon : le porteur est celui que
# l'annuaire désigne, pas celui qu'un script croit avoir nommé.
TARGET_ENV=""; TARGET_GROUP=""; TARGET_POLICY=""; TARGET_USER=""; TARGET_PV=""
for e in $ENVS_NONPROD; do
  g="$(env_chain_gate_deployer_group "$e")"
  case "$g" in apim-apply-?*) : ;; *) continue ;; esac
  for u in $(group_members "$g"); do
    pv="$(pass_var_for "$u")" || continue
    [ -n "${!pv:-}" ] || continue
    TARGET_ENV="$e"; TARGET_GROUP="$g"; TARGET_USER="$u"; TARGET_PV="$pv"
    TARGET_POLICY="$(deployer_group_policy "$g")"
    break 2
  done
done
[ -n "$TARGET_ENV" ] || lab_absent "aucun palier hors-prod ouvert avec un déployeur dont le mot de passe de lab est connu — ouvrir un palier (DEPLOYERS_<PALIER>=<uid>) et vérifier .env.lab-users"
echo "  cible dérivée : palier $TARGET_ENV, groupe $TARGET_GROUP, déployeur $TARGET_USER, policy projetée $TARGET_POLICY"

echo
echo "== ② le déployeur du palier $TARGET_ENV porte '$TARGET_POLICY' =="
TOK_DEP="$(login_token "$TARGET_USER" "$TARGET_PV")"
[ -n "$TOK_DEP" ] \
  && ok "② login LDAP de $TARGET_USER accepté" \
  || bad "② login LDAP de $TARGET_USER REFUSÉ — mot de passe de lab périmé (re-seed : scripts/setup-vault-ldap.sh), OU compte VERROUILLÉ par Vault après 5 échecs en 15 min (user lockout : GET sys/locked-users, puis POST — et non DELETE, qui rend 405 — sys/locked-users/<accessor>/unlock/$TARGET_USER)"
POL_DEP="$TMP/pol.dep"
lookup_policies "$TOK_DEP" "$POL_DEP" \
  && ok "②bis lookup-self répond pour $TARGET_USER : [$(policies_line "$POL_DEP")]" \
  || bad "②bis lookup-self en échec pour $TARGET_USER"
if has_policy "$POL_DEP" "$TARGET_POLICY"; then
  ok "②ter le token de $TARGET_USER PORTE '$TARGET_POLICY' — annuaire → mapping → policy, la chaîne complète tient"
elif group_members "$TARGET_GROUP" | grep -qx "$TARGET_USER"; then
  # L'annuaire dit membre, Vault ne projette rien : ce n'est pas la pose qui a
  # raté, c'est la MOITIÉ VAULT du grant qui manque. On le nomme au lieu de
  # laisser accuser le poseur qu'on vient de jouer vert.
  lab_absent "mapping auth/ldap/groups/$TARGET_GROUP → $TARGET_POLICY absent de Vault ($TARGET_USER est pourtant membre dans l'annuaire) — jouer scripts/setup-vault-paliers.sh"
else
  bad "②ter le token de $TARGET_USER ne porte PAS '$TARGET_POLICY' et l'annuaire ne le dit pas membre de $TARGET_GROUP — la pose n'a rien laissé"
fi

echo
echo "== ③ la demandeuse ne porte AUCUNE policy de déployeur =="
# alice est la persona DEMANDEUSE : elle remplit le formulaire, elle ne porte
# aucun apply. Si elle en portait un, `deployerGroup` serait décoratif — la
# porte serait satisfaite par la personne même qu'elle doit écarter du geste.
ALICE_PV="$(pass_var_for "$LAB_ALICE_USER")" || lab_absent "mot de passe de $LAB_ALICE_USER introuvable"
if [ -z "${!ALICE_PV:-}" ]; then
  lab_absent "$ALICE_PV vide — .env.lab-users absent ou incomplet ; sans lui la contre-épreuve de la demandeuse ne peut pas être MESURÉE (et une contre-épreuve sautée est un vert vacant)"
fi
TOK_REQ="$(login_token "$LAB_ALICE_USER" "$ALICE_PV")"
[ -n "$TOK_REQ" ] \
  && ok "③ login LDAP de $LAB_ALICE_USER (demandeuse) accepté — elle EXISTE, le refus qui suit n'est pas une absence" \
  || bad "③ login LDAP de $LAB_ALICE_USER refusé — la contre-épreuve ne mesurerait rien (mot de passe de .env.lab-users périmé, ou compte verrouillé par le user lockout de Vault : chaque passage brûlerait alors une tentative de plus)"
POL_REQ="$TMP/pol.req"
lookup_policies "$TOK_REQ" "$POL_REQ" \
  && ok "③bis lookup-self répond pour $LAB_ALICE_USER : [$(policies_line "$POL_REQ")]" \
  || bad "③bis lookup-self en échec pour $LAB_ALICE_USER"
LEAKED=""
for p in $DEPLOYER_POLICIES; do
  has_policy "$POL_REQ" "$p" && LEAKED="$LEAKED $p"
done
[ -z "$LEAKED" ] \
  && ok "③ter $LAB_ALICE_USER ne porte AUCUNE des policies de déployeur de la chaîne ($(echo "$DEPLOYER_POLICIES" | tr -s ' '))" \
  || bad "③ter $LAB_ALICE_USER porte des policies de déployeur :$LEAKED — la demandeuse est déployeuse, la déclaration est décorative"

echo
echo "== ④ le miroir shell projette ce que Vault a mis =="
MIRROR="$(deployer_group_policy "$TARGET_GROUP")"
[ -n "$MIRROR" ] && has_policy "$POL_DEP" "$MIRROR" \
  && ok "④ deployer_group_policy $TARGET_GROUP ⇒ '$MIRROR' — et c'est EXACTEMENT ce que le token porte (miroir shell, moteur Go et Vault d'accord)" \
  || bad "④ divergence miroir/Vault : deployer_group_policy rend '$MIRROR', le token porte [$(policies_line "$POL_DEP")]"
OPOL="$(deployer_group_policy apim-operator-prod)"
[ "$OPOL" = operator-deploy ] \
  && ok "④bis deployer_group_policy apim-operator-prod ⇒ 'operator-deploy' (seconde famille)" \
  || bad "④bis famille operator : '$OPOL' (attendu operator-deploy)"
# Le nom de l'AUTRE annuaire (claim Keycloak) doit être refusé, pas traduit :
# c'est LA faute du jalon, et elle doit être BRUYANTE.
KCNAME="$(env_chain_approver_group "$TARGET_ENV")"
[ -n "$KCNAME" ] || KCNAME="int-team"
if deployer_group_policy "$KCNAME" >/dev/null 2>&1; then
  bad "④ter deployer_group_policy accepte '$KCNAME' (nom de l'annuaire d'APPROBATION) — il devrait refuser rc=1"
else
  ok "④ter deployer_group_policy REFUSE rc=1 le nom d'approbation '$KCNAME' — les deux annuaires ne se confondent pas en silence"
fi

echo
echo "== ⑤ CONTRE-ÉPREUVE DU GRANT VIVANT : retirer de l'annuaire ⇒ perdre le palier =="
MEMBERS="$(group_members "$TARGET_GROUP" | tr '\n' ' ')"
NMEM="$(group_members "$TARGET_GROUP" | grep -c .)"
MUT_GROUP="$TARGET_GROUP"; MUT_USER="$TARGET_USER"
# La commande de réparation EXACTE, calculée ICI parce que c'est le seul endroit
# où la liste d'AVANT est connue. Le knob est nommé d'après le palier, comme le
# poseur le dérive lui-même (`DEPLOYERS_<PALIER>`) : il rend la réparation
# correcte même quand la cible, dérivée de l'ANNUAIRE, n'est pas un membre par
# défaut du poseur — cas où l'invocation nue reposerait quelqu'un d'AUTRE et
# laisserait le lab amputé en annonçant un succès.
MUT_KEY="$(printf '%s' "$TARGET_ENV" | tr 'a-z-' 'A-Z_')"
MUT_REPAIR="DEPLOYERS_${MUT_KEY}=\"$(printf '%s' "$MEMBERS" | tr -s ' ' | sed 's/ *$//')\" bash scripts/setup-deployer-groups.sh"
# MUTATED armé AVANT l'écriture : une interruption REÇUE PENDANT le docker exec
# déclencherait le trap ; l'indicateur posé APRÈS, la restauration serait sautée
# et le lab PARTAGÉ resterait amputé. Posé avant, une restauration « pour rien »
# rejoue simplement le poseur — strictement sûr.
MUTATED=1
if [ "$NMEM" -gt 1 ]; then
  # Le `-` terminateur passe par un `%s` et JAMAIS en tête de format : un format
  # qui commence par un tiret est mangé comme une OPTION par le printf de bash
  # (défaut mesuré le 2026-08-27 dans le poseur lui-même, corrigé en a8867cf —
  # le LDIF partait sans terminateur et la modification était refusée rc=2).
  MUT_OUT="$(printf 'dn: cn=%s,ou=Groups,%s\nchangetype: modify\ndelete: member\nmember: uid=%s,ou=People,%s\n%s\n\n' \
      "$TARGET_GROUP" "$BASE_DN" "$TARGET_USER" "$BASE_DN" '-' \
    | ldap_run ldapmodify 2>&1)"
  MRC=$?
  MUT_KIND="membre retiré (le groupe garde $((NMEM-1)) membre(s))"
else
  # `groupOfNames` EXIGE au moins un `member` (RFC 4519) : retirer le dernier
  # est refusé 65 « object class violation » par l'annuaire — MESURÉ, ce n'est
  # pas une hypothèse. Le seul retrait exprimable est donc la suppression du
  # groupe, ce qui est aussi la vérité du modèle : un palier sans déployeur
  # nommé n'a PAS de groupe (setup-deployer-groups.sh, §« un palier sans
  # déployeur nommé »).
  MUT_OUT="$(ldap_run ldapdelete "cn=$TARGET_GROUP,ou=Groups,$BASE_DN" 2>&1)"
  MRC=$?
  MUT_KIND="groupe SUPPRIMÉ (dernier membre : groupOfNames interdit le groupe vide)"
fi
[ "$MRC" -eq 0 ] \
  && ok "⑤ annuaire muté — $MUT_KIND" \
  || bad "⑤ mutation de l'annuaire en échec (rc=$MRC) : $(printf '%s' "$MUT_OUT" | head -2 | tr '\n' ' ')"
AFTER="$(group_members "$TARGET_GROUP" | grep -x "$TARGET_USER")"
[ -z "$AFTER" ] \
  && ok "⑤bis relecture : $TARGET_USER n'est plus membre de $TARGET_GROUP (avant : $MEMBERS)" \
  || bad "⑤bis $TARGET_USER est TOUJOURS membre après mutation — la contre-épreuve ne mesurerait rien"

TOK_AFTER="$(login_token "$TARGET_USER" "$TARGET_PV")"
[ -n "$TOK_AFTER" ] \
  && ok "⑤ter re-login de $TARGET_USER TOUJOURS accepté — l'AUTHENTIFICATION ne dépend pas du groupe" \
  || bad "⑤ter re-login de $TARGET_USER refusé — on mesurerait une panne d'auth, pas une perte de droit"
POL_AFTER="$TMP/pol.after"
lookup_policies "$TOK_AFTER" "$POL_AFTER" || bad "⑤ter lookup-self en échec après mutation"
has_policy "$POL_AFTER" "$TARGET_POLICY" \
  && bad "⑤quater le token frais porte ENCORE '$TARGET_POLICY' alors que l'annuaire ne le désigne plus — le grant est un état gelé, pas un droit vivant" \
  || ok "⑤quater le token frais NE porte PLUS '$TARGET_POLICY' : [$(policies_line "$POL_AFTER")] — le droit suit l'ANNUAIRE"

# MESURE (assertion, pas commentaire) : le token émis AVANT le retrait garde sa
# policy jusqu'à son TTL. Retrait ≠ révocation. Si Vault se mettait un jour à
# révoquer à chaud, cette ligne rougirait — et ce serait une nouvelle à ne pas
# manquer, pas un faux positif.
POL_GHOST="$TMP/pol.ghost"
lookup_policies "$TOK_DEP" "$POL_GHOST" || bad "⑤quinquies lookup-self en échec sur le token antérieur"
has_policy "$POL_GHOST" "$TARGET_POLICY" \
  && ok "⑤quinquies MESURE : le token émis AVANT le retrait porte TOUJOURS '$TARGET_POLICY' — retrait ≠ révocation, d'où la vérification AU DISPATCH et jamais à l'approbation" \
  || bad "⑤quinquies le token antérieur a perdu '$TARGET_POLICY' — Vault révoque désormais à chaud, la note « cache fantôme » du repo est à réécrire"

echo
echo "== ⑤sexies restauration par le poseur ⇒ le palier se rouvre =="
restore_group \
  && ok "⑤sexies restauration : $TARGET_USER est de nouveau membre de $TARGET_GROUP (relu dans l'annuaire)" \
  || bad "⑤sexies restauration en échec — voir le message ci-dessus"
TOK_BACK="$(login_token "$TARGET_USER" "$TARGET_PV")"
POL_BACK="$TMP/pol.back"
lookup_policies "$TOK_BACK" "$POL_BACK" || bad "⑤sexies lookup-self en échec après restauration"
has_policy "$POL_BACK" "$TARGET_POLICY" \
  && ok "⑤septies re-login après restauration : le token RE-PORTE '$TARGET_POLICY' — le palier se referme et se rouvre par l'ANNUAIRE seul, sans toucher Vault" \
  || bad "⑤septies le token ne re-porte pas '$TARGET_POLICY' après restauration — le lab sort DÉGRADÉ"

echo
echo "== ⑥ après le rejeu du poseur, la demandeuse est membre de RIEN =="
# Contre-épreuve d'annuaire : la restauration a REJOUÉ le poseur, et un poseur
# qui « répare » en élargissant serait le pire des remèdes. On relit donc tous
# les groupes déclarés par la chaîne, puis on re-mesure la demandeuse par un
# login FRAIS — l'annuaire et Vault, pas l'un ou l'autre.
FOUND_IN=""
for e in $ALL_ENVS; do
  g="$(env_chain_gate_deployer_group "$e")"
  [ -n "$g" ] || continue
  group_members "$g" | grep -qx "$LAB_ALICE_USER" && FOUND_IN="$FOUND_IN $g"
done
[ -z "$FOUND_IN" ] \
  && ok "⑥ $LAB_ALICE_USER n'est membre d'AUCUN groupe déployeur de la chaîne après le rejeu" \
  || bad "⑥ $LAB_ALICE_USER est apparue dans :$FOUND_IN — le replay a fait fuiter un membership"
TOK_REQ2="$(login_token "$LAB_ALICE_USER" "$ALICE_PV")"
POL_REQ2="$TMP/pol.req2"
lookup_policies "$TOK_REQ2" "$POL_REQ2" || bad "⑥bis lookup-self en échec pour $LAB_ALICE_USER"
LEAKED2=""
for p in $DEPLOYER_POLICIES; do
  has_policy "$POL_REQ2" "$p" && LEAKED2="$LEAKED2 $p"
done
[ -z "$LEAKED2" ] \
  && ok "⑥bis login frais de $LAB_ALICE_USER : toujours aucune policy de déployeur ([$(policies_line "$POL_REQ2")])" \
  || bad "⑥bis $LAB_ALICE_USER porte désormais :$LEAKED2"

echo
echo "== ⑦ état du lab à la sortie =="
[ "$MUTATED" -eq 0 ] && [ "$RESTORE_KO" -eq 0 ] \
  && ok "⑦ aucune mutation laissée derrière — le lab sort dans l'état où il est entré" \
  || bad "⑦ le lab sort MUTÉ (MUTATED=$MUTATED, RESTORE_KO=$RESTORE_KO)"

printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && [ "$RESTORE_KO" -eq 0 ]
