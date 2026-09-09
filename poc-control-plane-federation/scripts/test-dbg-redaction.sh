#!/usr/bin/env bash
# test-dbg-redaction.sh — la porte du MODE DEBUG SANS FUITE (plan 2026-09-09, Task 5 / L2).
#
# CE QU'ELLE EMPÊCHE. Un log Jenkins est ARCHIVÉ : un secret qui y passe une
# fois y reste, et la fuite est irréversible. Tous les scripts de la chaîne
# font `set +x` (« jamais de trace : le token ne doit pas fuiter »). Le mode
# verbeux demandé (URLs composées, chemins, branches, statuts HTTP) ne peut
# donc être qu'une sortie CURATÉE, passée par une rédaction — jamais `set -x`.
# Cette suite prouve que ci/lib/dbg.sh tient quatre promesses :
#   1. il SE TAIT quand on ne lui demande rien (STOA_DEBUG vide/0/false/off) ;
#   2. quand il PARLE, il parle sur STDERR seulement et ne touche pas au `$?`
#      de l'appelant — 38 scripts décident par `||` sans `set -e` (la consigne
#      « return 0 toujours » voulait dire « ne casse jamais l'appelant » :
#      `false; dbg x; echo $?` ⇒ 1 est la lecture qui fait foi, C.1) ;
#   3. ce qu'il dit ne porte AUCUN secret : ni par littéral connu du process
#      (FORGE_SECRET, VAULT_TOKEN, fichiers de token…), ni par forme
#      (Authorization, clé token/password, userinfo d'URL, hvs., JWT), ni par
#      encodage (base64 d'un Basic, %XX et + d'une URL, \uXXXX d'un JSON,
#      morceau d'un secret que ssh a coupé au premier « / » ou le shell à un
#      blanc) — y compris quand un littéral n'a masqué que le DÉBUT d'une
#      valeur (F.2-F.4 : connaître le secret ne doit jamais rendre la
#      rédaction pire) ;
#   4. sous `set -x` — le `-x` du `/bin/sh -xe` de Jenkins — la lib n'AJOUTE
#      aucune ligne de trace portant un secret : ni argument, ni affectation
#      de préfixe (`X=… python3`), ni `[ -n "$2" ]` (épreuve X, bash ET dash).
#
# GABARIT : D1/D2/D3 de test-vault-user-login.sh:277-304 — on capture TOUT ce
# que la lib écrit, on cherche le secret, et on exige que le debug ait été
# UTILE (D3 : une ligne `HTTP <code>` doit être PRÉSENTE). Sans cette dernière
# exigence, une lib muette passerait toutes les épreuves d'absence : c'est le
# vert vacant, et chaque épreuve d'absence est ici DOUBLÉE d'une présence.
# Là où c'est possible, l'assertion est la LIGNE EXACTE attendue : c'est ce
# qui la rend sensible à un masque partiel (« <secret masqué>%2F… »).
#
# LES SENTINELLES portent « / @ espace tabulation é » : chacun de ces
# caractères a un échappement différent selon le transport (URL, JSON, shell,
# base64), et c'est précisément là qu'une rédaction naïve rate le secret.
# `toutes_absentes` cherche le secret ENTIER et CHACUN de ses morceaux (≥ 4
# caractères) sous chacune de ses formes : le fragment « ttTAGé » d'un
# JSON dont le tout est déjà troué est une fuite, revue 2026-09-09.
#
# TERRAIN : hors ligne intégralement. python3 est retiré du PATH pour une
# section (fail-closed : sans lui, « <rédaction indisponible> » et RIEN
# d'autre). Les mutations se jouent sur des COPIES de la lib, jamais sur
# l'arbre. DBG_LIB=<copie> joue la suite entière contre une autre lib (c'est
# ainsi qu'on montre le rouge d'une épreuve neuve contre la lib d'avant).
#
#   bash scripts/test-dbg-redaction.sh
# SC2034 : les cas posent des variables (FORGE_SECRET, WM_USER, PATH…) que la LIB
# consomme, pas le harnais — c'est l'objet même de l'épreuve. SC2123 : PATH est
# réduit À DESSEIN (python3 retiré). SC2016 : quotes simples voulues, le code
# est interprété par dash/sh, pas par ce bash. SC1090 : la lib sourcée peut
# être un MUTANT (copie), son chemin n'est pas constant.
# shellcheck disable=SC2034,SC2123,SC2016,SC1090
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
LIB="${DBG_LIB:-$REPO/ci/lib/dbg.sh}"
TMP="$(mktemp -d /tmp/dbgred.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
note(){ printf '  · %s\n' "$*"; }

# ── ARDOISE PROPRE ───────────────────────────────────────────────────────────
# Le poste de l'exploitant exporte volontiers VAULT_TOKEN=root (Vault dev) :
# un littéral de 4 lettres masquerait « root » partout et fausserait les
# lectures ci-dessous. La suite pose ELLE-MÊME chaque secret qu'elle éprouve.
unset STOA_DEBUG VAULT_DEBUG DBG_NAME DBG_SECRET_FILES \
      FORGE_SECRET GITEA_TOKEN FORGE_TOKEN PUSH_TOKEN VAULT_TOKEN VAULT_USER_PASSWORD \
      WM_PASSWORD WM_PASS WM_BEARER LDAP_ADMIN_PASSWORD \
      CI_TOKEN_FILE PR_TOKEN_FILE VAULT_TOKEN_FILE FORGE_TOKEN_FILE \
      FORGE_USER WM_USER VAULT_USER PUSH_LOGIN

OUT="$TMP/out"; ERR="$TMP/err"; RCF="$TMP/rc"
# joue <fonction> [lib] — exécute <fonction> dans un sous-shell NEUF où la lib
# est sourcée ; stdout → $OUT, stderr → $ERR, rc → $RCF. Le sous-shell HÉRITE
# de `set -u` et `pipefail` : la lib doit y survivre, c'est une épreuve en soi.
joue(){
  local fn="$1" lib="${2:-$LIB}"
  ( . "$lib" || exit 99; "$fn" ) >"$OUT" 2>"$ERR"
  echo $? > "$RCF"
}
rrc(){ cat "$RCF"; }
absent(){ ! grep -qF -- "$1" "$ERR" && ! grep -qF -- "$1" "$OUT"; }
present_err(){ grep -qF -- "$1" "$ERR"; }
ligne_err(){ grep -q -- "$1" "$ERR"; }   # motif (regex) sur stderr — les assertions de LIGNE EXACTE
stdout_vide(){ [ ! -s "$OUT" ]; }
# parle : le debug a bien parlé (préfixe présent sur stderr) — l'anti-vert-vacant.
parle(){ grep -q '^\[dbg ' "$ERR"; }
MASQUE='<secret masqué>'
INDISPO='<rédaction indisponible>'

# sentinelle <tag> → « Zs<tag>X/9<pid>@q<tag> pq<tag>X<TAB>tt<tag>é » : un « / »,
# un « @ », un espace, une tabulation, un caractère accentué. Chaque segment
# (coupé à « / » ou aux blancs) fait ≥ 4 caractères : un morceau qui fuit est
# détectable.
sentinelle(){ printf 'Zs%sX/9%s@q%s pq%sX\ttt%sé' "$1" "$$" "$1" "$1" "$1"; }
# Les encodages qu'un transport applique à un secret — calculés par python,
# pas par la lib sous test (sinon la preuve tournerait en rond).
forme_json(){ S="$1" python3 -c 'import json,os; print(json.dumps(os.environ["S"])[1:-1])'; }
forme_json_utf(){ S="$1" python3 -c 'import json,os; print(json.dumps(os.environ["S"], ensure_ascii=False)[1:-1])'; }
forme_url(){ S="$1" python3 -c 'import os; from urllib.parse import quote; print(quote(os.environ["S"], safe=""))'; }
forme_url_plus(){ S="$1" python3 -c 'import os; from urllib.parse import quote_plus; print(quote_plus(os.environ["S"], safe=""))'; }
forme_b64(){ printf '%s:%s' "$1" "$2" | base64 | tr -d '\n'; }
# formes <secret> — le secret ENTIER et chacun de ses morceaux (≥ 4, coupés à
# « / » et aux blancs), chacun sous ses formes : brut, JSON (\uXXXX et utf-8,
# avec « \/ »), %XX, « + ». Une ligne par forme.
formes(){ S="$1" python3 -c '
import json, os, re
from urllib.parse import quote, quote_plus
v = os.environ["S"]; out = set()
for x in [v] + [s for s in re.split(r"[/\s]+", v) if len(s) >= 4]:
    j = json.dumps(x)[1:-1]
    for f in (x, j, j.replace("/", "\\/"), json.dumps(x, ensure_ascii=False)[1:-1], quote(x, safe=""), quote_plus(x, safe="")):
        out.add(f)
print("\n".join(sorted(out)))'; }
# toutes_absentes <secret> — aucune forme d'aucun morceau ne paraît.
toutes_absentes(){
  local f
  while IFS= read -r f; do absent "$f" || return 1; done < <(formes "$1")
}

if [ ! -f "$LIB" ]; then
  ko "0.0 la lib n'existe pas : $LIB — tout ce qui suit est ROUGE par construction"
fi

echo "═══ A. le silence : STOA_DEBUG vide / 0 / false / off ⇒ pas une ligne ═══"
cas_silence(){ dbg "ne doit pas paraître"; dbg_kv cle valeur; dbg_http GET http://h/p 200 3; }
for v in __ABSENT__ '' 0 false off; do
  if [ "$v" = __ABSENT__ ]; then unset STOA_DEBUG; else export STOA_DEBUG="$v"; fi
  joue cas_silence
  if [ "$(rrc)" = 0 ] && ! grep -q 'dbg' "$ERR" && stdout_vide; then
    ok "A. STOA_DEBUG=${v} ⇒ 0 ligne, stdout vide, rc 0"
  else ko "A. STOA_DEBUG=${v} : rc $(rrc), stderr: $(head -1 "$ERR")"; fi
done
unset STOA_DEBUG
cas_dbg_on(){ for v in '' 0 false off no; do STOA_DEBUG="$v" dbg_on && echo "ON:$v"; done
              for v in 1 true yes on; do STOA_DEBUG="$v" dbg_on || echo "OFF:$v"; done; echo fin; }
joue cas_dbg_on
if grep -qx fin "$OUT" && ! grep -q '^ON:\|^OFF:' "$OUT"; then
  ok "A.6 dbg_on : faux pour ''/0/false/off/no, vrai pour 1/true/yes/on"
else ko "A.6 dbg_on : $(tr '\n' ' ' < "$OUT")"; fi

echo "═══ B. la parole : STOA_DEBUG=1 ⇒ stderr seulement, préfixe [dbg <script>] ═══"
export STOA_DEBUG=1
cas_parle(){ dbg "bonjour le monde"; }
joue cas_parle
if grep -q '^\[dbg test-dbg-redaction.sh\] bonjour le monde$' "$ERR" && stdout_vide && [ "$(rrc)" = 0 ]; then
  ok "B.1 la ligne est sur STDERR, préfixée du nom du script (\$0), stdout VIDE"
else ko "B.1 stderr: '$(head -1 "$ERR")' stdout: '$(head -1 "$OUT")' rc $(rrc)"; fi

# Le nom vient de $0 : un script qui source la lib se nomme lui-même.
printf '#!/bin/sh\n. "%s"\ndbg "depuis un appelant"\n' "$LIB" > "$TMP/appelant.sh"
STOA_DEBUG=1 sh "$TMP/appelant.sh" >"$OUT" 2>"$ERR"
if grep -q '^\[dbg appelant.sh\] depuis un appelant$' "$ERR" && stdout_vide; then
  ok "B.2 le préfixe porte le nom du script APPELANT (déduit de \$0), pas celui de la lib"
else ko "B.2 stderr: '$(head -1 "$ERR")'"; fi

cas_nom(){ DBG_NAME=mon-job dbg "nommé"; }
joue cas_nom
if grep -q '^\[dbg mon-job\] nommé$' "$ERR"; then
  ok "B.3 DBG_NAME l'emporte sur \$0 (un step Jenkins s'appelle script.sh : il peut se nommer)"
else ko "B.3 stderr: '$(head -1 "$ERR")'"; fi

cas_true(){ STOA_DEBUG=true dbg "vrai"; }
joue cas_true
if grep -q '^\[dbg .*\] vrai$' "$ERR"; then ok "B.4 STOA_DEBUG=true parle aussi (le booleanParam Jenkins rend « true »)"
else ko "B.4 stderr: '$(head -1 "$ERR")'"; fi

cas_multi(){ dbg "$(printf 'ligne un\nligne deux')"; }
joue cas_multi
if [ "$(grep -c '^\[dbg ' "$ERR")" = 2 ] && grep -q '\] ligne deux$' "$ERR"; then
  ok "B.5 un message multi-lignes (stderr de git) : CHAQUE ligne est préfixée"
else ko "B.5 stderr: $(tr '\n' '|' < "$ERR")"; fi

cas_kv(){ dbg_kv GIT_BASE master; dbg_kv REL_PATH ''; }
joue cas_kv
if grep -q '\] GIT_BASE=master$' "$ERR" && grep -q '\] REL_PATH=<vide>$' "$ERR" && stdout_vide; then
  ok "B.6 dbg_kv : clé=valeur ; une valeur vide se dit « <vide> » (Jenkins retire les variables vides)"
else ko "B.6 stderr: $(tr '\n' '|' < "$ERR")"; fi

cas_http(){ dbg_http GET http://forge/api/v1/user 200 42; dbg_http POST http://forge/api/v1/repos/x/pulls 302; }
joue cas_http
if grep -q '\] GET http://forge/api/v1/user -> HTTP 200 (42 octets)$' "$ERR" \
   && grep -q '\] POST http://forge/api/v1/repos/x/pulls -> HTTP 302$' "$ERR" && stdout_vide; then
  ok "B.7 dbg_http : « METHODE url -> HTTP code (n octets) », octets facultatifs"
else ko "B.7 stderr: $(tr '\n' '|' < "$ERR")"; fi

cas_printf(){ dbg '100%s de %d et un \n antislash'; }
joue cas_printf
if grep -qF '] 100%s de %d et un \n antislash' "$ERR"; then
  ok "B.8 « % » et « \\n » dans un message passent LITTÉRALEMENT (jamais interprétés par printf)"
else ko "B.8 stderr: '$(head -1 "$ERR")'"; fi

# Le diagnostic « Jenkins a retiré la variable » doit survivre EXACTEMENT sur
# les variables qu'on veut diagnostiquer : celles dont le nom finit par
# PASSWORD/TOKEN (revue 2026-09-09 : « WM_PASSWORD=<secret masqué> » perdait
# l'information). Et l'exception ne doit pas ouvrir de trou : une VRAIE valeur
# derrière la même clé, même commençant par « <vide> », reste masquée.
cas_kv_vide(){ dbg_kv WM_PASSWORD ''; dbg_kv FORGE_TOKEN ''; dbg_kv LDAP_ADMIN_PASSWORD ''; dbg_kv VAULT_TOKEN_FILE ''; }
joue cas_kv_vide
if ligne_err '\] WM_PASSWORD=<vide>$' && ligne_err '\] FORGE_TOKEN=<vide>$' && ligne_err '\] LDAP_ADMIN_PASSWORD=<vide>$' \
   && ligne_err '\] VAULT_TOKEN_FILE=<vide>$' && ! present_err "$MASQUE"; then
  ok "B.9 dbg_kv <clé finissant par PASSWORD/TOKEN> '' ⇒ « <vide> » LISIBLE (la forme générique ne masque pas la garde)"
else ko "B.9 stderr: $(tr '\n' '|' < "$ERR")"; fi
cas_kv_pas_vide(){ dbg_kv WM_PASSWORD 'vraie-valeur-9'; dbg_kv FORGE_TOKEN '<vide>xyz'; dbg 'Authorization=<vide>'; }
joue cas_kv_pas_vide
if ligne_err "\] WM_PASSWORD=$MASQUE\$" && ligne_err "\] FORGE_TOKEN=$MASQUE\$" && ligne_err '\] Authorization=<vide>$' \
   && absent vraie-valeur-9 && absent '<vide>xyz'; then
  ok "B.10 (témoin) une vraie valeur derrière PASSWORD=/TOKEN= reste masquée, même préfixée « <vide> » ; « Authorization=<vide> » reste lisible"
else ko "B.10 stderr: $(tr '\n' '|' < "$ERR")"; fi

echo "═══ C. le code de retour : dbg ne change JAMAIS le \$? de l'appelant ═══"
cas_rc_faux(){ false; dbg "après false"; echo "rc=$?"; }
joue cas_rc_faux
if grep -qx 'rc=1' "$OUT" && parle; then ok "C.1 false; dbg x; echo \$? ⇒ 1 (debug ACTIF : la rédaction a tourné sans toucher au rc)"
else ko "C.1 stdout: '$(cat "$OUT")'"; fi

cas_rc_faux_off(){ STOA_DEBUG=0; false; dbg "muet"; echo "rc=$?"; }
joue cas_rc_faux_off
if grep -qx 'rc=1' "$OUT"; then ok "C.2 idem debug ÉTEINT : le no-op rend le rc reçu"
else ko "C.2 stdout: '$(cat "$OUT")'"; fi

cas_rc_vrai(){ true; dbg "après true"; echo "rc=$?"; dbg_kv k v; echo "rc=$?"; dbg_http GET u 200; echo "rc=$?"; }
joue cas_rc_vrai
if [ "$(grep -c '^rc=0$' "$OUT")" = 3 ]; then ok "C.3 true; dbg/dbg_kv/dbg_http ⇒ 0 — les trois fonctions rendent le rc reçu"
else ko "C.3 stdout: $(tr '\n' '|' < "$OUT")"; fi

cas_rc_kv_faux(){ false; dbg_kv k v; echo "rc=$?"; false; dbg_http GET u 200; echo "rc=$?"; false; dbg_http GET u 500 12; echo "rc=$?"; }
joue cas_rc_kv_faux
if [ "$(grep -c '^rc=1$' "$OUT")" = 3 ]; then ok "C.4 dbg_kv et dbg_http (avec et sans octets) préservent aussi un rc ≠ 0"
else ko "C.4 stdout: $(tr '\n' '|' < "$OUT")"; fi

# Jenkins exécute ses blocs `sh` en /bin/sh -xe : sous `set -e`, rendre le rc
# reçu (ex. 1 après `[ "$DEBUG" = true ] && export STOA_DEBUG=1` quand DEBUG
# est faux) ABATTRAIT le step. Là, et là seulement, dbg rend 0. (Le `-x` du
# même mode est éprouvé en X.)
for mode in 1 0; do
  bash -c "set -e; . '$LIB'; STOA_DEBUG=$mode; [ 1 = 2 ] && :; dbg 'sous set -e'; echo survecu" >"$OUT" 2>"$ERR"
  if grep -qx survecu "$OUT"; then ok "C.5 set -e (STOA_DEBUG=$mode) : un rc≠0 hérité ne tue pas le shell (dbg rend 0 sous -e)"
  else ko "C.5 set -e (STOA_DEBUG=$mode) : le shell est mort — $(head -1 "$ERR")"; fi
done

# `env -u` : STOA_DEBUG=1 est exporté par la suite, ce shell doit ne PAS l'hériter.
env -u STOA_DEBUG bash -c "set -u; . '$LIB'; dbg 'sans STOA_DEBUG'; dbg_kv a; dbg_http GET u 200; echo survecu" >"$OUT" 2>"$ERR"
if grep -qx survecu "$OUT" && [ ! -s "$ERR" ]; then ok "C.6 set -u, STOA_DEBUG absent, arguments manquants : aucune variable non liée"
else ko "C.6 $(head -1 "$ERR")"; fi

cas_capture(){ v="$(dbg 'capturé ?')"; echo "capture=[$v]"; }
joue cas_capture
if grep -qx 'capture=\[\]' "$OUT" && parle; then ok "C.7 \$(dbg …) capture une chaîne VIDE : jamais rien sur stdout, même en parlant"
else ko "C.7 stdout: '$(cat "$OUT")'"; fi

echo "═══ D. les littéraux connus du process — chaque nom, chaque transport ═══"
# Un secret est posé SANS export : la lib doit le voir quand même (les
# scripts tiennent leurs secrets en variables shell, pas toujours exportées).
# Le JSON porte le secret derrière « url » — une clé SANS forme : seule la
# forme JSON du littéral (é, \t) le masque là, pas la clé « token ».
S_D=""
for nom in FORGE_SECRET GITEA_TOKEN FORGE_TOKEN PUSH_TOKEN VAULT_TOKEN VAULT_USER_PASSWORD WM_PASSWORD WM_PASS WM_BEARER LDAP_ADMIN_PASSWORD; do
  S_D="$(sentinelle "$nom")"
  cas_lit(){
    eval "$NOM_D=\"\$S_D\""
    dbg "valeur en clair : $S_D"
    dbg_http GET "http://svc:$S_D@forge/api/v1/user" 200 12
    dbg "Authorization: token $S_D"
    dbg "$(S="$S_D" python3 -c 'import json,os; print(json.dumps({"token": os.environ["S"], "url": "http://x/"+os.environ["S"]}))')"
    dbg "url encodée : http://svc:$(forme_url "$S_D")@forge/"
  }
  NOM_D="$nom" S_D="$S_D" joue cas_lit
  if toutes_absentes "$S_D" && present_err "$MASQUE" && present_err 'HTTP 200' && [ "$(grep -c '^\[dbg ' "$ERR")" = 5 ] \
     && ligne_err "\"url\": \"http://x/$MASQUE\"}\$"; then
    ok "D. $nom (non exporté) : ABSENT en clair, dans l'URL, l'en-tête, le JSON (aucun morceau, aucune forme), l'URL encodée — 5 lignes dites, HTTP 200 visible"
  else ko "D. $nom : rc $(rrc) — $(grep -n -F -- "${S_D%%/*}" "$ERR" "$OUT" | head -2 | tr '\n' '|') — $(grep '"url"' "$ERR" | head -1)"; fi
done

S_E="$(sentinelle E)"
cas_export(){ export FORGE_SECRET="$S_E"; dbg "exporté : $FORGE_SECRET"; }
S_E="$S_E" joue cas_export
if toutes_absentes "$S_E" && present_err "$MASQUE"; then ok "D.11 FORGE_SECRET EXPORTÉ : absent aussi (les deux voies, variable shell et environnement)"
else ko "D.11 $(head -1 "$ERR")"; fi

# Les fichiers de token : leur CONTENU est un littéral (avec fin de ligne).
for fv in CI_TOKEN_FILE PR_TOKEN_FILE VAULT_TOKEN_FILE FORGE_TOKEN_FILE; do
  S_F="$(sentinelle "F$fv")"
  printf '%s\n' "$S_F" > "$TMP/tok-$fv"
  cas_fichier(){ eval "$FV=\"\$TMP/tok-\$FV\""; dbg "lu : $(cat "$TMP/tok-$FV")"; dbg_http POST http://forge/x 201 7; }
  FV="$fv" S_F="$S_F" joue cas_fichier
  if toutes_absentes "$S_F" && present_err "$MASQUE" && present_err 'HTTP 201'; then
    ok "D.12 $fv : le contenu du fichier est masqué (fin de ligne comprise)"
  else ko "D.12 $fv : $(head -1 "$ERR")"; fi
done

S_G1="$(sentinelle G1)"; S_G2="$(sentinelle G2)"
printf '%s' "$S_G1" > "$TMP/tok-g1"; printf '%s\r\n' "$S_G2" > "$TMP/tok-g2"
cas_files_knob(){ DBG_SECRET_FILES="$(printf '%s\n%s' "$TMP/tok-g1" "$TMP/tok-g2")"; dbg "deux : $S_G1 et $S_G2"; }
S_G1="$S_G1" S_G2="$S_G2" joue cas_files_knob
if toutes_absentes "$S_G1" && toutes_absentes "$S_G2" && present_err "$MASQUE"; then
  ok "D.13 DBG_SECRET_FILES (chemins séparés par saut de ligne) : les deux contenus masqués (CRLF compris)"
else ko "D.13 $(head -1 "$ERR")"; fi

cas_redact_arg(){ printf 'brut %s fin\n' "$S_G1" | redact "$TMP/tok-g1"; }
S_G1="$S_G1" joue cas_redact_arg
if ! grep -qF -- "$S_G1" "$OUT" && grep -qF "brut $MASQUE fin" "$OUT" && [ ! -s "$ERR" ]; then
  ok "D.14 redact <fichier> en filtre stdin→stdout : le contenu du fichier passé en argument est masqué"
else ko "D.14 stdout: '$(cat "$OUT")' stderr: '$(cat "$ERR")'"; fi

cas_inexistant(){ CI_TOKEN_FILE="$TMP/nexiste-pas"; FORGE_SECRET="$S_G1"; dbg "quand même : $S_G1"; dbg_http GET u 200 1; }
S_G1="$S_G1" joue cas_inexistant
if toutes_absentes "$S_G1" && present_err 'HTTP 200' && [ "$(rrc)" = 0 ]; then
  ok "D.15 un fichier de token INEXISTANT ne casse rien : la ligne sort, les autres littéraux restent masqués"
else ko "D.15 rc $(rrc) : $(head -1 "$ERR")"; fi

S_B="$(sentinelle B)"
cas_basic(){
  FORGE_USER=svc-ci; FORGE_SECRET="$S_B"; WM_USER=Administrator; WM_PASSWORD="$S_B"
  dbg "b64 nu : $(forme_b64 svc-ci "$S_B")"
  dbg "b64 wm : $(forme_b64 Administrator "$S_B")"
  dbg "Authorization: Basic $(forme_b64 svc-ci "$S_B")"
}
S_B="$S_B" joue cas_basic
if toutes_absentes "$S_B" && absent "$(forme_b64 svc-ci "$S_B")" && absent "$(forme_b64 Administrator "$S_B")" \
   && [ "$(grep -c -F "$MASQUE" "$ERR")" = 3 ]; then
  ok "D.16 le base64 de FORGE_USER:secret et de WM_USER:secret (ce que porte un Basic) est masqué, même NU hors en-tête"
else ko "D.16 $(tr '\n' '|' < "$ERR")"; fi

S_S="$(sentinelle S)"
cas_segment(){ FORGE_SECRET="$S_S"; dbg "ssh: Could not resolve hostname git:${S_S%%/*}: nodename nor servname provided"; }
S_S="$S_S" joue cas_segment
if absent "${S_S%%/*}" && present_err "hostname git:$MASQUE:"; then
  ok "D.17 un MORCEAU du secret (ssh coupe l'autorité au premier « / » — canari mesuré, generate-choices.sh règle 3bis) est masqué"
else ko "D.17 $(head -1 "$ERR")"; fi

cas_lisible(){ FORGE_SECRET="$S_S"; WM_PASS=ab; dbg "GIT_BASE=main SUB_PFX=livrable/ REL_PATH=clients/provisioned/applications/appa.ansible.yml table stable"; }
S_S="$S_S" joue cas_lisible
if grep -q '\] GIT_BASE=main SUB_PFX=livrable/ REL_PATH=clients/provisioned/applications/appa.ansible.yml table stable$' "$ERR"; then
  ok "D.18 le texte SANS secret ressort INTACT (pas de sur-masquage : « table » survit à WM_PASS=ab, les chemins survivent)"
else ko "D.18 $(head -1 "$ERR")"; fi

# Les transports que la revue 2026-09-09 a trouvés SANS épreuve : %XX hors
# userinfo (rien ne le rattrape par forme), « + » d'un corps form-urlencoded,
# morceau coupé à un BLANC (pas au « / »). Ligne EXACTE : un masque troué
# (« <secret masqué>%2F<secret masqué> ») est un rouge.
S_T="$(sentinelle T)"
cas_transports(){
  FORGE_SECRET="$S_T"
  dbg "corps : $(forme_url "$S_T")"
  dbg "corps plus : $(forme_url_plus "$S_T")"
  dbg "le shell a coupé : pqTX seul"
}
S_T="$S_T" joue cas_transports
if ligne_err "\] corps : $MASQUE\$" && toutes_absentes "$S_T"; then
  ok "D.19 %XX HORS userinfo et hors clé (un corps, un chemin) : masqué d'un seul tenant par la forme %XX du littéral"
else ko "D.19 $(grep 'corps :' "$ERR")"; fi
if ligne_err "\] corps plus : $MASQUE\$"; then
  ok "D.20 le « + » d'un corps x-www-form-urlencoded (grant password OAuth2) : masqué d'un seul tenant"
else ko "D.20 $(grep 'corps plus' "$ERR")"; fi
if ligne_err "\] le shell a coupé : $MASQUE seul\$"; then
  ok "D.21 un morceau coupé à un BLANC (pas au « / ») est masqué seul (le shell coupe aux blancs, ssh au « / »)"
else ko "D.21 $(grep 'a coupé' "$ERR")"; fi

echo "═══ E. les FORMES, sans aucun littéral connu ═══"
# Aucune variable de secret n'est posée ici : ce qui est masqué l'est par la
# FORME seule. Les valeurs ne portent pas de sentinelle réutilisée en D.
JWT='eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhbGljZSIsImF1ZCI6InZhdWx0In0.Xk9pQaBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789'
cas_formes(){
  dbg "jwt : $JWT"
  dbg "vault : hvs.CAESIJ0123456789abcdefghijklmnop_-XYZ et hvb.AAAAAQJ0123456789abc"
  # La valeur de fixture ne doit PAS avoir la forme d'un vrai jeton GitLab (glpat-<20>) :
  # la protection de push de GitHub bloque le commit qui la porte (mesuré 2026-09-09).
  dbg "PRIVATE-TOKEN: glpat_faux_9Xk7QaZzTt"
  dbg "X-Vault-Token: tokenvaultquelconque123"
  dbg "Authorization: token 0123456789abcdef0123456789abcdef01234567"
  dbg "Authorization: Bearer bearer.valeur.opaque-987"
  dbg "Authorization: Basic c3ZjOnNlY3JldC1pbmNvbm51"
  dbg "clone http://svc:motdepasse-inconnu@forge:3000/ci/x.git -> rc 128"
  dbg "clone https://tokenseul9876@gitlab.example/ci/x.git"
  dbg "client_secret=cs-0f1e2d3c&grant_type=client_credentials"
  dbg '{"password": "pw-json-inconnu", "user": "alice"}'
  dbg '{"Authorization": "token tok-dans-json", "Content-Type": "application/json"}'
  dbg_http GET "https://u:p-inconnu@forge/api/v1/user" 401 55
}
export STOA_DEBUG=1
JWT="$JWT" joue cas_formes
e(){ # e <n> <valeur secrète> <ce qui doit rester> <libellé>
  if absent "$2" && present_err "$3"; then ok "E.$1 $4"
  else ko "E.$1 $4 — $(grep -n -F -- "$2" "$ERR" | head -1) | attendu : $3"; fi
}
e 1 "$JWT" "jwt : $MASQUE" "JWT (eyJ…) masqué par forme"
e 2 "hvs.CAESIJ0123456789abcdefghijklmnop_-XYZ" "vault : $MASQUE et $MASQUE" "hvs./hvb. masqués par forme"
e 3 "glpat_faux_9Xk7QaZzTt" "PRIVATE-TOKEN: $MASQUE" "PRIVATE-TOKEN: <valeur> (GitLab) masqué par la clé générique « token » (son nom finit par TOKEN — une seule autorité, M10), l'en-tête reste nommé"
e 4 "tokenvaultquelconque123" "X-Vault-Token: $MASQUE" "X-Vault-Token: <valeur> masqué par la même clé générique (M10)"
e 5 "0123456789abcdef0123456789abcdef01234567" "Authorization: token $MASQUE" "Authorization: token <PAT 40 hex> : la valeur part, le SCHÉMA reste (il dit token/Bearer/Basic — le diagnostic FORGE_API_AUTH)"
e 6 "bearer.valeur.opaque-987" "Authorization: Bearer $MASQUE" "Authorization: Bearer <valeur> masqué"
e 7 "c3ZjOnNlY3JldC1pbmNvbm51" "Authorization: Basic $MASQUE" "Authorization: Basic <b64> masqué"
e 8 "motdepasse-inconnu" "clone http://$MASQUE@forge:3000/ci/x.git -> rc 128" "userinfo ://user:pass@ masqué, l'HÔTE et le rc RESTENT (c'est eux qu'on diagnostique)"
e 9 "tokenseul9876" "clone https://$MASQUE@gitlab.example/ci/x.git" "userinfo ://token@ masqué (un token seul avant le @)"
e 10 "cs-0f1e2d3c" "client_secret=$MASQUE&grant_type=client_credentials" "client_secret= masqué, le reste de la requête reste"
e 11 "pw-json-inconnu" "\"password\": \"$MASQUE\", \"user\": \"alice\"" "« password » en clé JSON masqué (défense en profondeur), le user reste"
e 12 "tok-dans-json" "\"Authorization\": \"token $MASQUE\", \"Content-Type\": \"application/json\"" "Authorization dans un JSON d'en-têtes : masqué, Content-Type reste"
e 13 "p-inconnu" "GET https://$MASQUE@forge/api/v1/user -> HTTP 401 (55 octets)" "dbg_http sur le chemin d'ÉCHEC : URL expurgée, HTTP 401 et taille VISIBLES (le refus auto-diagnostique)"

# ── L'ARBITRAGE DU LITTÉRAL COURT ────────────────────────────────────────────
# Un littéral de 1 à 3 caractères n'est PAS masqué par littéral : il masquerait
# chaque occurrence de ces lettres dans le log (« ab » ⇒ « table » illisible,
# D.18). Le seuil est 4. En contrepartie, la suite prouve qu'un tel secret ne
# passe par AUCUN des transports par lesquels un secret atteint une ligne de
# debug : ces transports ont une FORME, et la forme le rattrape.
cas_court(){
  WM_PASS=x7Q; FORGE_SECRET=x7Q; FORGE_USER=svc
  dbg "quatre lettres masquées : $(printf 'ab%s' 'cd')"
  dbg "Authorization: token x7Q"
  dbg "Authorization: Basic $(forme_b64 svc x7Q)"
  dbg "http://svc:x7Q@forge/api"
  dbg "PRIVATE-TOKEN: x7Q"
  dbg "X-Vault-Token: x7Q"
  dbg "client_secret=x7Q"
  dbg '{"token": "x7Q"}'
  dbg "WM_PASS=x7Q"
  dbg "nu : x7Q (limite documentée)"
}
joue cas_court; cp "$ERR" "$TMP/err-court"   # conservée : le cas suivant écrase $ERR
if grep -q 'quatre lettres masquées : abcd$' "$ERR"; then
  ok "E.20 (témoin) un texte anodin n'est pas touché par un secret de 3 lettres"
else ko "E.20 $(grep 'quatre lettres' "$ERR")"; fi
cas_quatre(){ WM_PASS=x7Qz; dbg "quatre : x7Qz"; }
joue cas_quatre
if grep -q "quatre : $MASQUE\$" "$ERR"; then ok "E.21 le seuil est 4 : un littéral de 4 caractères EST masqué nu"
else ko "E.21 $(head -1 "$ERR")"; fi
if [ "$(grep -c -F 'x7Q' "$TMP/err-court")" = 1 ] && grep -q "nu : x7Q (limite documentée)" "$TMP/err-court"; then
  ok "E.22 ARBITRAGE : un secret de 3 caractères passe par 8 transports (en-tête token/Basic, URL, PRIVATE-TOKEN, X-Vault-Token, client_secret, JSON, clé=) ⇒ masqué 8/8 par la FORME ; seul le nu reste (documenté)"
else ko "E.22 occurrences de x7Q : $(grep -n -F 'x7Q' "$TMP/err-court" | tr '\n' '|')"; fi
if ! grep -qF -- "$(forme_b64 svc x7Q)" "$TMP/err-court" && grep -qF "Authorization: Basic $MASQUE" "$TMP/err-court"; then ok "E.23 le base64 du couple svc:x7Q (Basic) est masqué par la forme Authorization (et la ligne est bien dite)"
else ko "E.23 $(grep -F "$(forme_b64 svc x7Q)" "$TMP/err-court")"; fi

echo "═══ F. idempotence, et le masque partiel : connaître le secret ne rend JAMAIS la rédaction pire ═══"
S_I="$(sentinelle I)"
cas_idem(){
  FORGE_SECRET="$S_I"
  # Authorization en QUEUE : sa valeur court jusqu'en fin de ligne, en tête
  # elle effondrerait toute la ligne en un masque et rien d'autre ne serait éprouvé.
  l="PRIVATE-TOKEN: pt-123456 ; X-Vault-Token: hvs.abcdefghijkl ; http://u:$S_I@h/ ; client_secret=cs-1 ; token=$S_I ; $JWT ; Authorization: token $S_I"
  a="$(printf '%s\n' "$l" | redact)"; b="$(printf '%s\n' "$a" | redact)"
  printf 'A=%s\nB=%s\n' "$a" "$b"
}
S_I="$S_I" JWT="$JWT" joue cas_idem
A_="$(sed -n 's/^A=//p' "$OUT")"; B_="$(sed -n 's/^B=//p' "$OUT")"
if [ -n "$A_" ] && [ "$A_" = "$B_" ] && ! grep -q 'masqué> masqué>' "$OUT" && ! grep -qF -- "$S_I" "$OUT"; then
  ok "F.1 redact ∘ redact = redact ; jamais « masqué> masqué> » ; le schéma survit aux deux passes (sans garde : M remplacé par M)"
else ko "F.1 A='$A_' B='$B_'"; fi

# LE DÉFAUT GRAVE N°2 (revue 2026-09-09). Un littéral peut ne masquer que le
# DÉBUT d'une valeur : un morceau connu (« Ab7k ») suivi du reste dans un
# encodage que la lib ne modélise pas (ici un double-encodage %25XX, comme un
# reverse-proxy en écrit), ou un secret connu suivi d'un inconnu dans le même
# en-tête. L'ancienne « garde d'idempotence » (valeur commençant par le masque
# ⇒ ne pas toucher) désactivait alors la FORME, et le reste fuyait : connaître
# le secret rendait la rédaction PIRE. Sans garde et avec le masque comme
# ATOME de la classe de valeur, la forme remasque la valeur EN ENTIER.
S_R='Ab7k 9qx/zé@w'   # le mot de passe de la revue : espace, « / », accent, « @ » — un segment de 3 (« 9qx »)
cas_garde(){
  FORGE_SECRET="$S_R"; WM_PASSWORD="$S_R"
  dbg "Authorization: token $S_R REELSECRET-inconnu-9999"
  dbg "password=Ab7k%25209qx%252Fz%25C3%25A9%2540w&grant_type=password&c=double"
  dbg "password=$(forme_url_plus "$S_R")&grant_type=password&c=plus"
}
S_R="$S_R" joue cas_garde
if ligne_err "\] Authorization: token $MASQUE\$" && absent REELSECRET-inconnu-9999; then
  ok "F.2 « Authorization: token <connu> <inconnu> » ⇒ la valeur ENTIÈRE part (avec garde : l'inconnu fuyait — M5)"
else ko "F.2 $(grep 'Authorization' "$ERR")"; fi
if ligne_err "\] password=$MASQUE&grant_type=password&c=double\$"; then
  ok "F.3 « password=<morceau connu><reste double-encodé> » ⇒ masqué d'un seul tenant : le masque est un ATOME de la classe (M5, M6)"
else ko "F.3 $(grep 'c=double' "$ERR")"; fi
if ligne_err "\] password=$MASQUE&grant_type=password&c=plus\$"; then
  ok "F.4 le cas EXACT de la revue (grant password, mot de passe quote_plus) ⇒ « password=<secret masqué>& » (M7 : garde + sans « + » ⇒ « +9qx%2F » fuyait)"
else ko "F.4 $(grep 'c=plus' "$ERR")"; fi

echo "═══ G. python3 absent ou cassé ⇒ « $INDISPO » et RIEN d'autre ═══"
mkdir -p "$TMP/vide" "$TMP/pycasse" "$TMP/pybavard" "$TMP/pytrace"
printf '#!/bin/sh\nexit 1\n' > "$TMP/pycasse/python3"; chmod +x "$TMP/pycasse/python3"
printf '#!/bin/sh\ncat\nexit 1\n' > "$TMP/pybavard/python3"; chmod +x "$TMP/pybavard/python3"
printf '#!/bin/sh\necho "Traceback (most recent call last): boum" >&2\nexit 1\n' > "$TMP/pytrace/python3"; chmod +x "$TMP/pytrace/python3"
S_P="$(sentinelle P)"
cas_nopy(){ PATH="$TMP/vide"; FORGE_SECRET="$S_P"; dbg "sans python : $S_P"; echo "rc=$?"; }
S_P="$S_P" joue cas_nopy
if [ "$(cat "$ERR")" = "$INDISPO" ] && grep -qx 'rc=0' "$OUT" && [ "$(wc -l < "$OUT")" -eq 1 ]; then
  ok "G.1 python3 hors du PATH : stderr = EXACTEMENT « $INDISPO » (une ligne, pas de préfixe, pas de secret, pas de « command not found »), rc 0"
else ko "G.1 stderr: '$(cat "$ERR")' stdout: '$(cat "$OUT")'"; fi

cas_nopy_redact(){ PATH="$TMP/vide"; printf 'brut %s\n' "$S_P" | redact; echo "rc=$?"; }
S_P="$S_P" joue cas_nopy_redact
if [ "$(sed -n 1p "$OUT")" = "$INDISPO" ] && grep -qx 'rc=0' "$OUT" && [ "$(wc -l < "$OUT")" -eq 2 ] && [ ! -s "$ERR" ]; then
  ok "G.2 redact en filtre sans python3 : la ligne unique sur stdout, rc 0, stderr vide"
else ko "G.2 stdout: '$(tr '\n' '|' < "$OUT")' stderr: '$(cat "$ERR")'"; fi

cas_pycasse(){ PATH="$TMP/pycasse:/usr/bin:/bin"; FORGE_SECRET="$S_P"; dbg "python cassé : $S_P"; }
S_P="$S_P" joue cas_pycasse
if [ "$(cat "$ERR")" = "$INDISPO" ] && stdout_vide; then
  ok "G.3 python3 présent mais qui MEURT (rc 1, muet) : la ligne unique — fail-closed sur la panne, pas seulement sur l'absence"
else ko "G.3 stderr: '$(cat "$ERR")'"; fi

cas_pybavard(){ PATH="$TMP/pybavard:/usr/bin:/bin"; FORGE_SECRET="$S_P"; dbg "python bavard : $S_P"; }
S_P="$S_P" joue cas_pybavard
if [ "$(cat "$ERR")" = "$INDISPO" ] && stdout_vide; then
  ok "G.4 python3 qui RECOPIE son entrée puis meurt : rien de ce qu'il a écrit ne sort (la sortie est retenue jusqu'au verdict)"
else ko "G.4 stderr: '$(cat "$ERR")'"; fi

# « RIEN d'autre » face à un python qui ÉCRIT SUR STDERR avant de mourir
# (traceback d'import, stdlib cassée) : son stderr est jeté (M11).
cas_pytrace(){ PATH="$TMP/pytrace:/usr/bin:/bin"; FORGE_SECRET="$S_P"; dbg "python qui trace : $S_P"; }
S_P="$S_P" joue cas_pytrace
if [ "$(cat "$ERR")" = "$INDISPO" ] && stdout_vide; then
  ok "G.5 python3 qui TRACE sur stderr puis meurt : le traceback n'est pas une ligne de debug — stderr = EXACTEMENT la ligne unique"
else ko "G.5 stderr: '$(tr '\n' '|' < "$ERR")'"; fi

# Le drain de stdin par builtin (sans python) : un message plus gros que le
# tampon du tube, écrit par le builtin printf d'un appelant qui IGNORE SIGPIPE
# (trap '' PIPE — des runners le font) ⇒ sans drain, bash imprime
# « printf: write error: Broken pipe » (M15). Mesuré : 300 Ko, bash 3.2.
bash -c 'trap "" PIPE; . "$1"; big=$(head -c 300000 /dev/zero | tr "\0" a); PATH="$2"; printf "%s\n" "$big" | redact; echo "rc=$?"' sh "$LIB" "$TMP/vide" >"$OUT" 2>"$ERR"
if [ "$(sed -n 1p "$OUT")" = "$INDISPO" ] && grep -qx 'rc=0' "$OUT" && [ ! -s "$ERR" ]; then
  ok "G.6 sans python3, 300 Ko sur le tube, SIGPIPE ignoré par l'appelant : la ligne unique, rc 0, stderr VIDE (l'écrivain est drainé, jamais cassé)"
else ko "G.6 stdout: '$(head -c 60 "$OUT")' stderr: '$(head -c 120 "$ERR")'"; fi

echo "═══ H. les shells : dash et sh sourcent la lib sans erreur ═══"
S_H="$(sentinelle H)"
for shell in dash sh; do
  if ! command -v "$shell" >/dev/null 2>&1; then note "H. $shell absent de cette machine — épreuve sautée (non comptée)"; continue; fi
  if "$shell" -n "$LIB" 2>"$ERR"; then ok "H.1 $shell -n : la lib est du $shell (aucun bashisme)"
  else ko "H.1 $shell -n : $(head -1 "$ERR")"; fi
  S_H="$S_H" STOA_DEBUG=1 "$shell" -c '. "$1"; FORGE_SECRET="$S_H"; dbg "sous le shell : $S_H"; dbg_http GET "http://u:$S_H@h/p" 200 3; false; dbg x; echo "rc=$?"' sh "$LIB" >"$OUT" 2>"$ERR"
  if toutes_absentes "$S_H" && present_err 'HTTP 200' && [ "$(grep -c '^\[dbg ' "$ERR")" = 3 ] && grep -qx 'rc=1' "$OUT"; then
    ok "H.2 $shell : parle sur stderr, masque, préserve le rc (false; dbg x ⇒ 1)"
  else ko "H.2 $shell : stdout '$(cat "$OUT")' stderr '$(tr '\n' '|' < "$ERR")'"; fi
  env -u STOA_DEBUG "$shell" -c 'set -u; . "$1"; dbg "sans STOA_DEBUG"; echo survecu' sh "$LIB" >"$OUT" 2>"$ERR"
  if grep -qx survecu "$OUT" && [ ! -s "$ERR" ]; then ok "H.3 $shell + set -u, STOA_DEBUG absent : survit, muet"
  else ko "H.3 $shell : $(head -1 "$ERR")"; fi
  "$shell" -c 'set -e; . "$1"; STOA_DEBUG=1; [ 1 = 2 ] && :; dbg "sous -e"; echo survecu' sh "$LIB" >"$OUT" 2>"$ERR"
  if grep -qx survecu "$OUT"; then ok "H.4 $shell + set -e : un rc≠0 hérité ne tue pas le shell"
  else ko "H.4 $shell : $(head -1 "$ERR")"; fi
done

echo "═══ I. argv : le secret n'apparaît JAMAIS dans ps (contrôle positif inclus) ═══"
PSOUT="$TMP/ps.txt"; : > "$PSOUT"
CANARI="CANARI-argv-$$-visible"
# Deux commandes, pas une : bash `exec` directement la dernière commande simple
# d'un `-c`, et le canari disparaîtrait de l'argv avec le processus sh.
sh -c "sleep 0.7; : $CANARI" & BG=$!
for _ in 1 2 3 4 5; do ps -Aww -o command= >> "$PSOUT" 2>/dev/null; sleep 0.05; done
wait $BG
if grep -qF -- "$CANARI" "$PSOUT"; then ok "I.1 contrôle positif : un secret mis en argv EST vu par ps -Aww (la sonde fonctionne)"
else ko "I.1 la sonde ps ne voit même pas le canari — I.2 ne prouverait rien"; fi
: > "$PSOUT"; S_PS="$(sentinelle PS)"
( . "$LIB"; FORGE_SECRET="$S_PS"; FORGE_USER=svc; ( sleep 0.8; printf 'x=%s\n' "$FORGE_SECRET" ) | redact >/dev/null ) & BG=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do ps -Aww -o command= >> "$PSOUT" 2>/dev/null; sleep 0.05; done
wait $BG
# Le marqueur est le TEXTE du programme (argv de -c) : sur macOS argv[0] est
# « …/MacOS/Python », jamais « python3 ».
PY_MARQUE='import os, re, sys, json, base64'
if grep -qF -- "$PY_MARQUE" "$PSOUT" && ! grep -qF -- "$S_PS" "$PSOUT" && ! grep -qF -- "${S_PS%%/*}" "$PSOUT" \
   && ! grep -qF -- "$(forme_b64 svc "$S_PS")" "$PSOUT"; then
  ok "I.2 pendant la rédaction (python observé $(grep -c -F -- "$PY_MARQUE" "$PSOUT")×), ni le secret, ni son segment, ni son base64 en argv"
else ko "I.2 python vu: $(grep -c -F -- "$PY_MARQUE" "$PSOUT") ; secret vu: $(grep -c -F -- "${S_PS%%/*}" "$PSOUT")"; fi

echo "═══ X. sous set -x (le -x du /bin/sh -xe de Jenkins) : la lib n'AJOUTE aucune ligne de trace portant un secret ═══"
# LE DÉFAUT GRAVE N°1 (revue 2026-09-09) : sous -x, un préfixe d'affectation
# (`FORGE_SECRET=… python3`) est TRACÉ — un message ANODIN déversait tous les
# secrets du process. Les secrets sont posés AVANT `set -x` : toute occurrence
# dans la trace est donc due à la lib (X.1), sauf la ligne d'APPEL que
# l'appelant trace lui-même (X.2 : exactement celle-là, pas une de plus).
printf 'SEC-file-5\n' > "$TMP/tok-x"
X1='FORGE_SECRET=SEC-forge-1; VAULT_TOKEN=SEC-vault-2; WM_PASSWORD=SEC-wm-3; LDAP_ADMIN_PASSWORD=SEC-ldap-4; FORGE_USER=svc; CI_TOKEN_FILE="$2"; STOA_DEBUG=1
set -x
. "$1"; dbg_kv GIT_BASE main; dbg_http GET http://forge/api/v1/user 200 42; dbg anodin; echo fin'
X2='WM_PASSWORD=SEC-wm-3; STOA_DEBUG=1
set -x
. "$1"; dbg_kv WM_PASSWORD "$WM_PASSWORD"; dbg "Authorization: token $WM_PASSWORD"; echo fin'
for shell in bash dash; do
  if ! command -v "$shell" >/dev/null 2>&1; then note "X. $shell absent — épreuve sautée (non comptée)"; continue; fi
  "$shell" -c "$X1" sh "$LIB" "$TMP/tok-x" >"$OUT" 2>"$ERR"
  if grep -qx fin "$OUT" && [ "$(grep -c 'SEC-' "$ERR")" = 0 ] && grep -q '^+ dbg_kv GIT_BASE main$' "$ERR" \
     && grep -q '^\[dbg sh\] GIT_BASE=main$' "$ERR" && grep -q '^\[dbg sh\] GET http://forge/api/v1/user -> HTTP 200 (42 octets)$' "$ERR" \
     && grep -q '^\[dbg sh\] anodin$' "$ERR"; then
    ok "X.1 $shell -x, 4 secrets + 1 fichier posés, messages ANODINS : 0 occurrence de secret dans la trace (la trace est bien là : « + dbg_kv GIT_BASE main »)"
  else ko "X.1 $shell -x : $(grep -c 'SEC-' "$ERR") occurrence(s) — $(grep 'SEC-' "$ERR" | head -2 | cut -c1-100 | tr '\n' '|')"; fi
  "$shell" -c "$X2" sh "$LIB" >"$OUT" 2>"$ERR"
  if grep -qx fin "$OUT" && [ "$(grep -c 'SEC-wm-3' "$ERR")" = 2 ] && [ "$(grep -c '^+ dbg.* SEC-wm-3' "$ERR")" = 2 ] \
     && grep -q "^\[dbg sh\] WM_PASSWORD=$MASQUE\$" "$ERR" && grep -q "^\[dbg sh\] Authorization: token $MASQUE\$" "$ERR"; then
    ok "X.2 $shell -x, message PORTANT un secret : les 2 seules occurrences sont les lignes d'APPEL tracées par l'appelant (« + dbg… ») — la lib n'en ajoute aucune, et dit la ligne masquée"
  else ko "X.2 $shell -x : $(grep 'SEC-wm-3' "$ERR" | cut -c1-100 | tr '\n' '|')"; fi
done

echo "═══ M. mutations sur COPIE : l'épreuve attrape ce qu'elle prétend attraper ═══"
# mute <étiquette> <sed> <fonction de cas> <prédicat « le mutant est PRIS »> <libellé>
S_M="$(sentinelle M)"
mute(){
  local et="$1" expr="$2" fn="$3" pris="$4" lib="$TMP/mut-$1.sh"
  [ -f "$LIB" ] || { ko "$et pas de lib à muter"; return; }
  sed "$expr" "$LIB" > "$lib"
  if cmp -s "$LIB" "$lib" || ! sh -n "$lib" 2>/dev/null; then
    ko "$et mutant no-op ou incompilable — l'épreuve ne prouve rien (la lib a-t-elle changé de forme ?)"; return
  fi
  S_M="$S_M" S_R="$S_R" S_P="$S_P" S_T="$S_T" joue "$fn" "$lib"
  if "$pris"; then ok "$et $5"; else ko "$et le mutant passe encore : stderr '$(head -1 "$ERR" | cut -c1-120)'"; fi
}
cas_m(){ FORGE_SECRET="$S_M"; dbg "clair : $S_M"; }
pris_fuite(){ grep -qF -- "$S_M" "$ERR"; }
mute M1 's/  redact >&2 || :/  cat >\&2 || :/' cas_m pris_fuite \
  "dbg SANS redact ⇒ le secret FUIT sur stderr : les épreuves D rougiraient (la rédaction est bien sur le chemin)"
mute M2 's/len(v) < 4/len(v) < 400/' cas_m pris_fuite \
  "règle du littéral neutralisée ⇒ un secret nu fuit : D n'est pas portée par les seules formes"
cas_m_nopy(){ PATH="$TMP/vide"; FORGE_SECRET="$S_M"; dbg "sans python : $S_M"; }
pris_nopy(){ [ "$(cat "$ERR")" != "$INDISPO" ]; }
mute M3 's/do :; done/do printf "%s\\n" "$_dbg_l"; done/' cas_m_nopy pris_nopy \
  "repli sans python rendu BAVARD ⇒ la sortie n'est plus la ligne unique : G.1 rougirait (le fail-closed est éprouvé, pas supposé)"

# M4 — le défaut grave n°1 rejoué : UN préfixe d'affectation réintroduit devant
# python3 ⇒ sous -x, bash ET dash tracent le secret sur un message anodin.
sed 's/^  python3 -c "\$_DBG_PY" "\$@" 2>\/dev\/null 3<<_DBG_EOF$/  FORGE_SECRET="${FORGE_SECRET:-}" python3 -c "$_DBG_PY" "$@" 2>\/dev\/null 3<<_DBG_EOF/' "$LIB" > "$TMP/mut-M4.sh"
if cmp -s "$LIB" "$TMP/mut-M4.sh" || ! sh -n "$TMP/mut-M4.sh" 2>/dev/null; then ko "M4 mutant no-op ou incompilable"
else
  for shell in bash dash; do
    command -v "$shell" >/dev/null 2>&1 || continue
    "$shell" -c "$X1" sh "$TMP/mut-M4.sh" "$TMP/tok-x" >"$OUT" 2>"$ERR"
    # bash trace « ++ » dans un $(…) et pose chaque préfixe sur SA ligne
    # (« ++ FORGE_SECRET=SEC-forge-1 ») ; dash « + FORGE_SECRET=… python3 -c ».
    if [ "$(grep -c 'SEC-forge-1' "$ERR")" -ge 1 ] && grep -q '^+\{1,\} FORGE_SECRET=SEC-forge-1' "$ERR"; then
      ok "M4 $shell -x : un seul préfixe « FORGE_SECRET=… python3 » réintroduit ⇒ « + FORGE_SECRET=SEC-forge-1 python3 » dans la trace sur un message ANODIN — X.1 rougit"
    else ko "M4 $shell -x : le mutant passe encore : $(grep 'SEC-' "$ERR" | head -1 | cut -c1-100)"; fi
  done
fi

# M5..M7 — le défaut grave n°2 rejoué : la garde d'idempotence RÉINSÉRÉE (une
# ligne), la classe SANS le masque en atome, et le cas exact de la revue.
pris_reel(){ grep -qF 'REELSECRET-inconnu-9999' "$ERR" || ! grep -q "\] password=$MASQUE&grant_type=password&c=double\$" "$ERR"; }
mute M5 's/^        return "".join(m.group(k) or "" for k in prefixe) + M + suffixe$/        return m.group(0) if texte[m.start(len(prefixe) + 1):m.start(len(prefixe) + 1) + len(M)] == M else "".join(m.group(k) or "" for k in prefixe) + M + suffixe/' cas_garde pris_reel \
  "garde « commence par le masque ⇒ ne pas toucher » réinsérée ⇒ « REELSECRET » et le reste double-encodé FUIENT (F.2/F.3 rougissent : la garde rendait la rédaction pire)"
pris_troue(){ ! grep -q "\] password=$MASQUE&grant_type=password&c=double\$" "$ERR"; }
mute M6 's/(?:" + V + r"|/(?:/g' cas_garde pris_troue \
  "masque retiré des classes de valeur ⇒ « password=<secret masqué> masqué>%2520… » (F.3 rougit : la forme s'arrêtait au blanc du masque)"
pris_plus(){ ! grep -q "\] password=$MASQUE&grant_type=password&c=plus\$" "$ERR"; }
mute M7 's/^        return "".join(m.group(k) or "" for k in prefixe) + M + suffixe$/        return m.group(0) if texte[m.start(len(prefixe) + 1):m.start(len(prefixe) + 1) + len(M)] == M else "".join(m.group(k) or "" for k in prefixe) + M + suffixe/;/quote_plus(x, safe=""/d' cas_garde pris_plus \
  "garde réinsérée + forme « + » retirée = la lib de la revue ⇒ « password=<secret masqué>+9qx%2F… » (F.4 rougit : le cas exact)"
pris_plus_t(){ ! grep -q "\] corps plus : $MASQUE\$" "$ERR"; }
mute M8 '/quote_plus(x, safe=""/d' cas_transports pris_plus_t \
  "forme « + » (quote_plus) retirée ⇒ « corps plus : <secret masqué>+… » troué (D.20 rougit)"
pris_vide(){ ! grep -q '\] WM_PASSWORD=<vide>$' "$ERR"; }
mute M9 's/ + VIDE + / + /g' cas_kv_vide pris_vide \
  "exception « <vide> » retirée ⇒ « WM_PASSWORD=<secret masqué> » : le diagnostic est perdu (B.9 rougit)"
pris_glpat(){ grep -qF 'glpat_faux_9Xk7QaZzTt' "$ERR" || grep -qF 'tokenvaultquelconque123' "$ERR"; }
mute M10 's/|secret|token|bearer|/|secret|bearer|/' cas_formes pris_glpat \
  "« token » retiré de la clé générique ⇒ PRIVATE-TOKEN et X-Vault-Token FUIENT (E.3/E.4 rougissent : c'est bien cette clé qui les porte, pas une forme dédiée)"
pris_trace(){ grep -qF 'Traceback' "$ERR"; }
mute M11 's/"\$@" 2>\/dev\/null 3<<_DBG_EOF/"$@" 3<<_DBG_EOF/' cas_pytrace pris_trace \
  "stderr de python non jeté ⇒ « Traceback… » paraît avant la ligne unique (G.5 rougit)"
# M12 — formes JSON retirées : le tout masqué, mais le morceau « tt…é »
# du JSON derrière « url » (clé sans forme) FUIT.
cas_json(){ FORGE_SECRET="$S_T"; dbg "$(S="$S_T" python3 -c 'import json,os; print(json.dumps({"url": "http://x/"+os.environ["S"]}))')"; }
pris_json(){ ! toutes_absentes "$S_T"; }
mute M12 '/json.dumps(x)\[1:-1\], json.dumps(x, ensure_ascii=False)/,/j.replace("\/", "\\\\\/")/d' cas_json pris_json \
  "formes JSON retirées ⇒ le fragment « ttTX\\u00e9 » d'un JSON derrière une clé sans forme FUIT (D.1-10 rougissent)"
pris_seul(){ ! grep -q "\] le shell a coupé : $MASQUE seul\$" "$ERR"; }
mute M13 's/re.split(r"\[\/\\s\]+", v)/re.split(r"\/+", v)/' cas_transports pris_seul \
  "coupe aux blancs retirée (« / » seul) ⇒ « pqTX seul » fuit (D.21 rougit)"
pris_corps(){ ! grep -q "\] corps : $MASQUE\$" "$ERR"; }
mute M14 '/lits.add(quote(x, safe=""/d' cas_transports pris_corps \
  "forme %XX retirée ⇒ « corps : <secret masqué>%2F<secret masqué>%20… » troué (D.19 rougit)"
# M15 — drain de stdin retiré : l'écrivain qui ignore SIGPIPE imprime « write error ».
sed '/while IFS= read -r _dbg_l; do :; done/d' "$LIB" > "$TMP/mut-M15.sh"
if cmp -s "$LIB" "$TMP/mut-M15.sh" || ! sh -n "$TMP/mut-M15.sh" 2>/dev/null; then ko "M15 mutant no-op ou incompilable"
else
  bash -c 'trap "" PIPE; . "$1"; big=$(head -c 300000 /dev/zero | tr "\0" a); PATH="$2"; printf "%s\n" "$big" | redact; echo "rc=$?"' sh "$TMP/mut-M15.sh" "$TMP/vide" >"$OUT" 2>"$ERR"
  if grep -q 'write error' "$ERR"; then ok "M15 drain retiré ⇒ « printf: write error: Broken pipe » sur stderr (G.6 rougit : le drain est éprouvé, pas supposé)"
  else ko "M15 le mutant passe encore : stderr '$(head -c 120 "$ERR")'"; fi
fi

echo
echo "═══════════════════════════════════════════════════"
echo "═══ N. un secret MULTI-LIGNE ne peut pas déformer le canal fd 3 (fail-closed) ═══"
# Re-relecture 2026-09-09 (FAIBLE, mais une vraie fuite) : le canal fd 3 est
# ligne à ligne (« P=… », « U=… », « F=… », « S=… »). Un secret portant un
# retour-ligne dont la suite commence par « P= » ré-étiquetait le reste en
# PRÉFIXE — imprimé EN CLAIR. Le remède n'est pas un parseur plus malin (toute
# grammaire par lignes a ce trou) : c'est un `case` — le seul test que `-x` ne
# trace pas — qui refuse de rédiger et sort « <rédaction indisponible> ».
n_cas(){ STOA_DEBUG=1 FORGE_SECRET="ab${NL}P=fuite-en-clair-XYZ" dbg_kv GIT_BASE main; }
NL='
'
joue n_cas
if [ "$(cat "$ERR")" = "<rédaction indisponible>" ] && ! grep -q 'fuite-en-clair' "$ERR" "$OUT"; then
  ok "N.1 secret avec retour-ligne (suite « P=… ») ⇒ exactement « <rédaction indisponible> », rien en clair"
else ko "N.1 stderr=[$(head -c 120 "$ERR" | tr '\n' '|')]"; fi
n_cas_f(){ STOA_DEBUG=1 CI_TOKEN_FILE="x${NL}S=y" FORGE_SECRET=SEC-normal-4567 dbg_kv GIT_BASE main; }
joue n_cas_f
if [ "$(cat "$ERR")" = "<rédaction indisponible>" ]; then
  ok "N.2 un CHEMIN de fichier de token avec retour-ligne ⇒ même refus (le canal porte aussi les chemins)"
else ko "N.2 stderr=[$(head -c 120 "$ERR" | tr '\n' '|')]"; fi
# Mutation : sans le `case`, N.1 doit rougir — sinon N.1 ne prouve rien.
MN="$TMP/mut-nl.sh"; sed 's/^\(    \*"\$_DBG_NL"\*)\).*/\1 : ;;/' "$LIB" > "$MN"
if cmp -s "$LIB" "$MN"; then ko "M16 mutant no-op (la garde a changé de forme ?)"
else
  joue n_cas "$MN"
  if grep -q 'fuite-en-clair' "$ERR"; then ok "M16 garde du retour-ligne retirée ⇒ le fragment sort EN CLAIR (N.1 rougit) — la garde n'est pas décorative"
  else ko "M16 le mutant ne fuit pas : N.1 serait vacante — stderr=[$(head -c 100 "$ERR" | tr '\n' '|')]"; fi
fi

printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
