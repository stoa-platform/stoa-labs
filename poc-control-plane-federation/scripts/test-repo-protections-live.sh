#!/usr/bin/env bash
# test-repo-protections-live.sh — porte LIVE G4 (ADR-082) côté Gitea (lab requis).
#
# La porte HORS-LIGNE lit ce que le poseur (setup-repo-protections.sh) ÉMET.
# Celle-ci mesure ce que Gitea 1.22 FAIT de cette émission, sur des artefacts
# JETABLES (org g4-proof, dépôt probe, user g4-req), et prononce la porte G4 :
#   ① MESURE de la sémantique protected_file_patterns : bloque-t-elle le push
#      direct ? le MERGE d'une PR ? un admin en est-il exempté ?
#   ② MESURE de la sémantique de FUSION du PATCH branch_protection (1.22) :
#      re-poser la BASELINE NUE (sans patterns) EFFACE-t-il les patterns, ou
#      les PRÉSERVE-t-il ? — la dette nommée dans repo-protection.sh /
#      setup-repo-protections.sh, celle qui débloque (ou non) le re-passage.
#   ③ PORTE G4 (assertions DURES) : le demandeur ne pousse ni main d'un dépôt
#      protégé, ni la chaîne (ci/stoa-labs) ;
#   ④ le flux légitime (PR sur un fichier libre) reste OUVERT ;
#   ⑤ MESURE : le compte admin est-il exempté du push_whitelist ? (décide si le
#      défaut PROTECT_PUSH_WHITELIST=ci doit rester aligné sur GITEA_ADMIN_USER).
#
# ── LECTURE SEULE SUR LES DÉPÔTS RÉELS ──────────────────────────────────────
# Le lab est PARTAGÉ. Ce script ne POSE aucune protection sur un dépôt réel et
# ne POUSSE RIEN sur un dépôt réel. La seule chose qu'il fait toucher à
# ci/stoa-labs est un GET de l'API de permission du collaborateur : la porte
# « le demandeur ne pousse pas la chaîne » est prononcée sur la permission
# EFFECTIVE (read/none ≠ write), pas sur un push mutant. `info/refs?service=
# git-receive-pack` est publiquement annoncé (200 pour tous, mesuré) — c'est le
# git-receive-pack qui refuse ensuite ; la permission effective en est le juge
# autoritatif et NON mutant.
#
# ── FAIL-CLOSED, JAMAIS DE SKIP MUET ────────────────────────────────────────
# Prérequis manquant (Gitea muet, docker/token admin absent) ⇒ exit 1 avec
# `LAB_ABSENT : <détail>`. Une porte live qui « se saute toute seule » quand le
# lab tombe est pire qu'absente : elle rend vert.
#
# ── CE QUE CE SCRIPT ÉCRIT DANS LE LAB, ET CE QU'IL REMET ────────────────────
#   - crée l'org g4-proof, le dépôt g4-proof/probe, le user g4-req — TOUS
#     JETABLES, DÉTRUITS au teardown (motif test-producer-chain.sh:410-419) et
#     le 404 est VÉRIFIÉ en fin ;
#   - un run précédent interrompu aurait pu les laisser : ils sont pré-nettoyés
#     AVANT création (noms dédiés à CETTE porte, jamais un objet réel).
#
#   GITEA_TOKEN=… bash scripts/test-repo-protections-live.sh
#
# `A && ok || bad` (SC2015) est l'idiome des scripts de preuve du repo ; le
# `$?` relu juste après la commande qui le produit (SC2181) est une lecture
# immédiate et non ambiguë.
# shellcheck disable=SC2015,SC2181
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
TMP=$(mktemp -d); umask 077

lab_absent(){ echo "LAB_ABSENT : $*" >&2; rm -rf "$TMP"; exit 1; }

GIT_HOST="${GIT_HOST:-http://localhost:13000}"
GITEA_CONTAINER="${GITEA_CONTAINER:-poc-gitea}"
[ -n "${GITEA_TOKEN:-}" ] || lab_absent "GITEA_TOKEN requis (admin du Gitea de lab)"

for b in curl python3 git docker; do
  command -v "$b" >/dev/null 2>&1 || lab_absent "$b introuvable — prérequis de cette porte"
done
curl -s -m 5 -o /dev/null "$GIT_HOST/api/v1/version" \
  || lab_absent "Gitea ne répond pas à $GIT_HOST"
# Le token du user JETABLE est minté par la CLI Gitea (docker exec) — l'API
# admin ne mint pas le token d'un tiers. Sans docker, cette porte se REFUSE.
docker exec "$GITEA_CONTAINER" true >/dev/null 2>&1 \
  || lab_absent "conteneur Gitea '$GITEA_CONTAINER' injoignable (docker exec) — requis pour minter le token du user jetable"

# Le token ne transite JAMAIS par argv ni par une URL : fichier d'en-tête lu
# par `curl -H @fichier` (discipline de repo-protection.sh / team-apply.sh:149).
AHDR="$TMP/ahdr"; printf 'Authorization: token %s\n' "$GITEA_TOKEN" > "$AHDR"
a(){ curl -s -m 20 -H @"$AHDR" "$@"; }
ac(){ a -o /dev/null -w '%{http_code}' "$@"; }

# Un token non-admin se voit ICI, pas trois épreuves plus loin sur un 403 opaque.
[ "$(ac "$GIT_HOST/api/v1/admin/users?limit=1")" = 200 ] \
  || lab_absent "le GITEA_TOKEN fourni n'a pas les droits admin (GET /admin/users ≠ 200)"

# shellcheck source=scripts/lib/repo-protection.sh
. scripts/lib/repo-protection.sh

ORG="g4-proof"; RN="probe"; REPO="$ORG/$RN"; USR="g4-req"
REALREPO="ci/stoa-labs"        # dépôt PLATEFORME réel — LECTURE SEULE

# ── TEARDOWN, armé AVANT la première création ───────────────────────────────
# Toutes les variables qu'il référence sont déclarées ICI, pour que `set -u` ne
# le casse jamais quand il se déclenche tôt (motif test-producer-chain.sh:417).
WORKREPO=""
del_fixtures(){
  # Dépôt AVANT l'org (un org non vide ne se supprime pas), puis le user.
  ac -X DELETE "$GIT_HOST/api/v1/repos/$REPO"          >/dev/null 2>&1
  ac -X DELETE "$GIT_HOST/api/v1/orgs/$ORG"            >/dev/null 2>&1
  ac -X DELETE "$GIT_HOST/api/v1/admin/users/$USR"     >/dev/null 2>&1
}
teardown(){
  [ -n "$WORKREPO" ] && rm -rf "$WORKREPO" 2>/dev/null
  del_fixtures
  rm -rf "$TMP"
}
trap teardown EXIT INT TERM

# ── FIXTURES JETABLES ───────────────────────────────────────────────────────
echo "Gitea $GIT_HOST — porte de protection de branche (fixtures jetables $ORG / $USR)"
del_fixtures   # pré-nettoyage d'un run interrompu (noms dédiés à cette porte)

RID="$(ac -X POST -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys;print(json.dumps({"username":sys.argv[1],"visibility":"public"}))' "$ORG")" \
  "$GIT_HOST/api/v1/orgs")"
[ "$RID" = 201 ] || lab_absent "création de l'org jetable $ORG en échec (HTTP $RID)"

RID="$(ac -X POST -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"auto_init":True,"default_branch":"main"}))' "$RN")" \
  "$GIT_HOST/api/v1/orgs/$ORG/repos")"
[ "$RID" = 201 ] || lab_absent "création du dépôt jetable $REPO en échec (HTTP $RID)"

RID="$(ac -X POST -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys,secrets,string; pw="".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24))+"!Aa9"; print(json.dumps({"username":sys.argv[1],"email":sys.argv[1]+"@stoa.lab","password":pw,"must_change_password":False}))' "$USR")" \
  "$GIT_HOST/api/v1/admin/users")"
[ "$RID" = 201 ] || lab_absent "création du user jetable $USR en échec (HTTP $RID)"

# collaborateur WRITE : g4-req a le droit d'écrire — la protection est le SEUL
# obstacle mesuré (sans WRITE, tout serait rejeté et rien ne serait isolé).
RID="$(ac -X PUT -H 'Content-Type: application/json' -d '{"permission":"write"}' \
  "$GIT_HOST/api/v1/repos/$REPO/collaborators/$USR")"
[ "$RID" = 204 ] || lab_absent "collaborateur WRITE $USR sur $REPO en échec (HTTP $RID)"

# token du user jetable — minté par la CLI, jamais en clair dans argv (capturé
# de la sortie, écrit dans un en-tête 0600). Détruit avec le user au teardown.
USRTOK="$(docker exec -u git "$GITEA_CONTAINER" gitea admin user generate-access-token \
  --username "$USR" --token-name "g4t9-$$-$(date +%s)" --raw \
  --scopes write:repository,write:issue 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)"
[ -n "$USRTOK" ] || lab_absent "mint du token Gitea de $USR impossible (docker exec sur $GITEA_CONTAINER)"
UHDR="$TMP/uhdr"; printf 'Authorization: token %s\n' "$USRTOK" > "$UHDR"
u(){ curl -s -m 20 -H @"$UHDR" "$@"; }

# Auth git basic — le token base64é vit dans une VARIABLE d'env passée à git
# (GIT_CONFIG_VALUE), jamais dans l'URL ni l'argv (motif test-producer-chain.sh:596).
REQ_B64="$(printf '%s:%s' "$USR" "$USRTOK" | base64 | tr -d '\n')"
ADM_B64="$(printf 'ci:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')"
req_git(){ GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic $REQ_B64" git -C "$WORKREPO" "$@"; }
adm_git(){ GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic $ADM_B64" git -C "$WORKREPO" "$@"; }

# seed : un fichier PROTÉGÉ (protege.yaml) et un fichier LIBRE (libre.txt).
seed_file(){ # <path> <content>
  local b; b="$(printf '%s' "$2" | base64 | tr -d '\n')"
  ac -X POST -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"content":sys.argv[1],"message":"seed "+sys.argv[2],"branch":"main"}))' "$b" "$1")" \
    "$GIT_HOST/api/v1/repos/$REPO/contents/$1"
}
[ "$(seed_file protege.yaml 'k: seed')" = 201 ] || lab_absent "seed de protege.yaml en échec"
[ "$(seed_file libre.txt   'seed')"    = 201 ] || lab_absent "seed de libre.txt en échec"

WORKREPO="$TMP/work"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic $REQ_B64" \
  git clone -q "$GIT_HOST/$REPO.git" "$WORKREPO" 2>"$TMP/clone.err" \
  || lab_absent "clone jetable de $REPO en échec : $(tail -1 "$TMP/clone.err")"
git -C "$WORKREPO" config user.name  "$USR"
git -C "$WORKREPO" config user.email "$USR@stoa.lab"

# helpers de protection
prot_field(){ # <field> -> valeur (python repr)
  a "$GIT_HOST/api/v1/repos/$REPO/branch_protections/main" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get(sys.argv[1]))' "$1" 2>/dev/null
}
open_pr(){ # <head> <title> -> numéro de PR
  u -X POST -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"head":sys.argv[1],"base":"main","title":sys.argv[2]}))' "$1" "$2")" \
    "$GIT_HOST/api/v1/repos/$REPO/pulls" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("number",""))' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== ① MESURE : sémantique de protected_file_patterns (Gitea 1.22) =="
# ÉCART JUSTIFIÉ au squelette (whitelist vide) : whitelist=[g4-req] (le
# demandeur LUI-MÊME) au lieu de vide — pour ISOLER l'effet du PATTERN de celui
# de la whitelist. Sinon a1 serait rejeté par la whitelist et ne mesurerait
# PAS le pattern. Le pattern se prouve alors sur un pousseur AUTORISÉ.
repo_protection_payload main "$USR" "protege.yaml" > "$TMP/p.s1.json" \
  || lab_absent "payload S1 non formé"
pose_branch_protection "$GIT_HOST" "$AHDR" "$REPO" "$TMP/p.s1.json" \
  || lab_absent "pose S1 (POST) via le poseur réel en échec"
[ "$(prot_field protected_file_patterns)" = protege.yaml ] \
  && ok "① protection posée : whitelist=[$USR], protected_file_patterns=protege.yaml" \
  || bad "① la protection posée ne porte pas le pattern attendu"

# a1 (ASSERTION DURE) : le demandeur, POURTANT whitelisté, ne pousse PAS le
# fichier protégé.
req_git fetch -q origin; req_git checkout -q main; req_git reset -q --hard origin/main
printf 'k: a1\n' > "$WORKREPO/protege.yaml"; req_git add protege.yaml; req_git commit -qm "req: touche protege" >/dev/null
req_git push origin main >"$TMP/a1.out" 2>&1; A1RC=$?
A1MSG="$(grep -i 'remote:.*protected' "$TMP/a1.out" | head -1 | sed 's/^ *remote: *//;s/ *$//')"
[ "$A1RC" -ne 0 ] \
  && ok "① a1 (DURE) push direct de protege.yaml (demandeur whitelisté) REJETÉ (rc=$A1RC) — « $A1MSG »" \
  || bad "① a1 le demandeur a POUSSÉ un fichier protégé (rc=0) — le pattern ne tient pas"

# a2 (MESURE) : le MÊME pousseur, sur un fichier LIBRE, passe — c'est bien le
# pattern qui discrimine, pas un blocage en bloc.
req_git checkout -q main; req_git reset -q --hard origin/main
printf 'a2\n' > "$WORKREPO/libre.txt"; req_git add libre.txt; req_git commit -qm "req: touche libre" >/dev/null
req_git push origin main >"$TMP/a2.out" 2>&1; A2RC=$?
[ "$A2RC" -eq 0 ] \
  && ok "① a2 MESURE : le même pousseur whitelisté POUSSE libre.txt (rc=0) — protected_file_patterns discrimine PAR FICHIER, pas en bloc" \
  || ok "① a2 MESURE : push de libre.txt rc=$A2RC (inattendu — voir $TMP/a2.out ; n'infirme pas la porte)"

# a3 (MESURE) : une PR qui MODIFIE le fichier protégé — le MERGE est-il bloqué ?
req_git checkout -q main; req_git reset -q --hard origin/main
req_git checkout -q -b pr-protege
printf 'k: a3\n' > "$WORKREPO/protege.yaml"; req_git add protege.yaml; req_git commit -qm "pr: change protege" >/dev/null
req_git push -q origin pr-protege >/dev/null 2>&1
PR="$(open_pr pr-protege 'change protege via PR')"
sleep 1
MOUT="$TMP/merge.a3"
M3="$(a -o "$MOUT" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"Do":"merge"}' "$GIT_HOST/api/v1/repos/$REPO/pulls/${PR:-0}/merge")"
M3REASON="$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("message",""))' "$MOUT" 2>/dev/null)"
case "$M3" in
  405|409|422) ok "① a3 MESURE : MERGE (par l'admin) d'une PR touchant protege.yaml BLOQUÉ — HTTP $M3 « $M3REASON » ; protected_file_patterns gate AUSSI la fusion, admin compris" ;;
  200) ok "① a3 MESURE : MERGE d'une PR touchant protege.yaml AUTORISÉ (HTTP 200) — protected_file_patterns ne gate PAS la fusion sur cette version" ;;
  *) ok "① a3 MESURE : MERGE d'une PR touchant protege.yaml -> HTTP $M3 « $M3REASON »" ;;
esac

# a4 (MESURE) : l'admin de site (ci) est-il exempté du PATTERN en push direct ?
req_git checkout -q main; req_git reset -q --hard origin/main
printf 'k: a4\n' > "$WORKREPO/protege.yaml"; adm_git add protege.yaml; adm_git commit -qm "admin: touche protege" >/dev/null
adm_git push origin main >"$TMP/a4.out" 2>&1; A4RC=$?
A4MSG="$(grep -i 'remote:.*protected' "$TMP/a4.out" | head -1 | sed 's/^ *remote: *//;s/ *$//')"
[ "$A4RC" -ne 0 ] \
  && ok "① a4 MESURE : push direct de protege.yaml par l'ADMIN de site REJETÉ (rc=$A4RC) — « $A4MSG » ; le pattern n'exempte PAS l'admin" \
  || ok "① a4 MESURE : l'ADMIN pousse protege.yaml (rc=0) — l'admin EST exempté du pattern"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== ② MESURE : sémantique de FUSION du PATCH branch_protection (1.22) =="
# On re-pose la BASELINE NUE (whitelist=ci, SANS champ patterns) PAR LE POSEUR
# RÉEL (pose_branch_protection → PATCH). Les patterns sont-ils préservés ?
BEFORE_WL="$(prot_field push_whitelist_usernames)"
BEFORE_PAT="$(prot_field protected_file_patterns)"
repo_protection_payload main "ci" "" > "$TMP/p.s2.json" \
  || lab_absent "payload S2 (baseline nue) non formé"
grep -q protected_file_patterns "$TMP/p.s2.json" \
  && lab_absent "le payload baseline porte protected_file_patterns — la mesure serait faussée" \
  || :
pose_branch_protection "$GIT_HOST" "$AHDR" "$REPO" "$TMP/p.s2.json" \
  || bad "② PATCH baseline via le poseur réel en échec"
AFTER_WL="$(prot_field push_whitelist_usernames)"
AFTER_PAT="$(prot_field protected_file_patterns)"
if [ "$AFTER_PAT" = protege.yaml ]; then
  ok "② MESURE : PATCH baseline NUE (whitelist ci, sans patterns) -> patterns PRÉSERVÉS ($BEFORE_PAT -> $AFTER_PAT), whitelist mise à jour ($BEFORE_WL -> $AFTER_WL) — le PATCH 1.22 FUSIONNE : un champ ABSENT du corps est conservé. Re-passer le poseur baseline NE DÉTRUIT PAS les options posées à la main. Corollaire : pour EFFACER un champ il faut l'envoyer explicitement vide."
else
  ok "② MESURE : PATCH baseline NUE -> patterns EFFACÉS ($BEFORE_PAT -> ${AFTER_PAT:-vide}) — le PATCH 1.22 REMPLACE : re-passer le poseur baseline EFFACERAIT en silence les options posées à la main. RECOMMANDATION : GET-fusion-PATCH dans pose_branch_protection avant tout re-passage."
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== ③ PORTE G4 (assertions DURES) : le demandeur ne pousse ni main ni la chaîne =="
# État courant : whitelist=[ci], patterns préservés=protege.yaml. Le demandeur
# pousse un fichier LIBRE sur main : rejet par la WHITELIST (pas le pattern).
req_git fetch -q origin; req_git checkout -q main; req_git reset -q --hard origin/main
printf 'porte\n' > "$WORKREPO/libre.txt"; req_git add libre.txt; req_git commit -qm "req: violation whitelist" >/dev/null
req_git push origin main >"$TMP/g4.out" 2>&1; G4RC=$?
G4MSG="$(grep -i 'remote:.*protected' "$TMP/g4.out" | head -1 | sed 's/^ *remote: *//;s/ *$//')"
[ "$G4RC" -ne 0 ] \
  && ok "③ (DURE) push du demandeur sur main d'un dépôt protégé baseline (whitelist ci) REJETÉ (rc=$G4RC) — « $G4MSG »" \
  || bad "③ le demandeur a POUSSÉ sur main (rc=0) — la porte G4 est trouée"

# ci/stoa-labs : LECTURE SEULE. La permission EFFECTIVE juge le push.
PERM="$(a "$GIT_HOST/api/v1/repos/$REALREPO/collaborators/$USR/permission" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("permission",""))' 2>/dev/null)"
RCVP="$(ac "$GIT_HOST/$REALREPO.git/info/refs?service=git-receive-pack")"
[ -n "$PERM" ] && [ "$PERM" != write ] && [ "$PERM" != admin ] \
  && ok "③ (DURE) le demandeur n'a AUCUN droit d'écriture sur $REALREPO : permission effective = '$PERM' — un push (git-receive-pack) est refusé. NB : info/refs?service=git-receive-pack rend HTTP $RCVP (annonce publique) ; l'enforcement est au receive-pack, jugé ici par la permission autoritative, sans push mutant." \
  || bad "③ le demandeur a la permission '$PERM' sur $REALREPO (write/admin) — il pourrait pousser la chaîne"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== ④ le flux LÉGITIME reste ouvert (PR sur un fichier libre) =="
req_git checkout -q main; req_git reset -q --hard origin/main; req_git checkout -q -b pr-libre
printf 'freePR\n' > "$WORKREPO/libre.txt"; req_git add libre.txt; req_git commit -qm "pr: change libre" >/dev/null
req_git push -q origin pr-libre >/dev/null 2>&1
PRL="$(open_pr pr-libre 'change libre via PR')"
sleep 1
MERGEABLE="$(a "$GIT_HOST/api/v1/repos/$REPO/pulls/${PRL:-0}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("mergeable"))' 2>/dev/null)"
ML="$(a -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"Do":"merge"}' "$GIT_HOST/api/v1/repos/$REPO/pulls/${PRL:-0}/merge")"
[ "$ML" = 200 ] \
  && ok "④ PR du demandeur sur un fichier LIBRE : mergeable=$MERGEABLE, merge (par l'admin) HTTP 200 — la protection ne ferme pas la voie légitime" \
  || bad "④ le flux légitime est BLOQUÉ : mergeable=$MERGEABLE, merge HTTP $ML"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== ⑤ MESURE : l'admin de site est-il exempté du push_whitelist ? =="
# Config bespoke (PAS le poseur) : whitelist=[g4-req] (ci ABSENT), patterns
# effacés explicitement. L'admin ci pousse un fichier LIBRE : passe-t-il ?
ac -X PATCH -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys;print(json.dumps({"branch_name":"main","enable_push":True,"enable_push_whitelist":True,"push_whitelist_usernames":[sys.argv[1]],"protected_file_patterns":""}))' "$USR")" \
  "$GIT_HOST/api/v1/repos/$REPO/branch_protections/main" >/dev/null
req_git fetch -q origin; req_git checkout -q main; req_git reset -q --hard origin/main
printf 'admin-non-whitelisté\n' > "$WORKREPO/adminfile.txt"; adm_git add adminfile.txt; adm_git commit -qm "admin: non-whitelisté" >/dev/null
adm_git push origin main >"$TMP/c.out" 2>&1; CRC=$?
CMSG="$(grep -i 'remote:.*protected' "$TMP/c.out" | head -1 | sed 's/^ *remote: *//;s/ *$//')"
if [ "$CRC" -ne 0 ]; then
  ok "⑤ MESURE : l'admin de site (ci), NON whitelisté, est REJETÉ (rc=$CRC) — « $CMSG ». L'admin n'est PAS exempté du push_whitelist ⇒ le défaut PROTECT_PUSH_WHITELIST=ci DOIT rester aligné sur GITEA_ADMIN_USER (chemin de réparation de team-apply) : il est PORTANT, pas décoratif."
else
  ok "⑤ MESURE : l'admin de site (ci) pousse malgré une whitelist qui l'exclut (rc=0) — l'admin EST exempté du push_whitelist ⇒ l'alignement PROTECT_PUSH_WHITELIST=ci est une ceinture-bretelles, pas une nécessité."
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== ⑥ nettoyage vérifié =="
rm -rf "$WORKREPO" 2>/dev/null; WORKREPO=""
del_fixtures
RREPO="$(ac "$GIT_HOST/api/v1/repos/$REPO")"
RORG="$(ac "$GIT_HOST/api/v1/orgs/$ORG")"
RUSR="$(ac "$GIT_HOST/api/v1/users/$USR")"
[ "$RREPO" = 404 ] && ok "⑥ dépôt jetable $REPO détruit (404)" || bad "⑥ le dépôt $REPO survit au nettoyage (HTTP $RREPO)"
[ "$RORG" = 404 ] && ok "⑥bis org jetable $ORG détruit (404)" || bad "⑥bis l'org $ORG survit au nettoyage (HTTP $RORG)"
{ [ "$RUSR" = 404 ] || [ "$RUSR" = 403 ]; } && ok "⑥ter user jetable $USR détruit (HTTP $RUSR)" || bad "⑥ter le user $USR survit au nettoyage (HTTP $RUSR)"

printf '\n  %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
