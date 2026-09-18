#!/usr/bin/env bash
# test-site-env.sh — la preuve HORS LIGNE de ci/lib/site-env.sh, la VOIE SANS
# ADMIN : un client sans `Overall/RunScripts` pose ses valeurs de site dans un
# fichier versionné de son dépôt, que le job checkoute.
#
# CE QU'ELLE EMPÊCHE. Ce fichier est VERSIONNÉ : quiconque lit le dépôt le lit.
# Trois propriétés le rendent acceptable, et chacune a ici son épreuve ET son
# mutant — une garde qu'aucun mutant ne retire n'est pas éprouvée, elle est
# seulement présente :
#   S.1 un SECRET y est REFUSÉ au chargement (pas seulement absent aujourd'hui) ;
#   S.2 l'ENVIRONNEMENT POSÉ l'emporte sur le fichier (une globale Jenkins, si le
#       site a un admin, gagne toujours — la voie admin reste intacte) ;
#   S.3 l'INCLASSABLE est rouge : une ligne qui n'est ni vide, ni un commentaire,
#       ni `CLE=valeur` REFUSE le chargement, elle n'est jamais ignorée.
# Et deux propriétés de robustesse :
#   S.4 un fichier ABSENT n'est pas une panne (un site qui a un admin ne doit pas
#       être cassé par cette voie) — ligne nommée, rc 0 ;
#   S.5 un CRLF ne se propage pas dans la valeur (fichier édité sous Windows).
#
# ATOMICITÉ (S.6) : le fichier est validé EN ENTIER avant qu'une seule valeur ne
# soit posée. Un refus au milieu laisserait sinon un état moitié fichier moitié
# environnement, que personne ne pourrait diagnostiquer.
#
# TROIS SHELLS : la lib est sourcée depuis les blocs `sh` de Jenkins, qui sont du
# DASH sur Debian ; sur un poste macOS /bin/sh est bash en mode POSIX. Les trois
# sont mesurés — une construction bash-only y casserait toute la chaîne.
#
# ⚠ LE CHEMIN DE LA LIB EST RÉSOLU AVANT TOUT `cd` : une première écriture de ce
# harnais le composait depuis $PWD après s'être déplacé dans le répertoire de
# fixtures, et les cinq cas échouaient identiquement sur « No such file or
# directory » — cinq faux rouges qui ne mesuraient rien (mesuré le 2026-09-17).
#
#   bash scripts/test-site-env.sh
# shellcheck disable=SC2016
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${SITE_ENV_LIB:-$REPO/ci/lib/site-env.sh}"
TMP="$(mktemp -d /tmp/site-env.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
note(){ printf '  · %s\n' "$*"; }

[ -f "$LIB" ] || { ko "0.0 la lib n'existe pas : $LIB — tout ce qui suit est ROUGE par construction"; }

# ARDOISE PROPRE : le poste de l'exploitant exporte volontiers GIT_HOST.
unset GIT_HOST GIT_REPO FORGE_KIND WM_PASSWORD STOA_SITE_FILE SUB_PFX _SITE_ENV_LOADED

SHELLS=""
for s in dash sh bash; do
  # `if` et non `A && B || C` : le Makefile joue shellcheck SANS -S, donc son
  # SC2015 (« C peut tourner même si A est vrai ») rougit l'étape 2.
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"
  else note "$s absent — ses épreuves sont sautées"; fi
done

fixture(){ mkdir -p "$TMP/w/config"; printf '%s' "$1" > "$TMP/w/config/site.ini"; }
# joue <shell> <programme> — la lib en $1, exécuté depuis le répertoire de fixtures.
joue(){ ( cd "$TMP/w" && "$1" -c "$2" sh "$LIB" ) 2>"$TMP/err" >"$TMP/out"; echo $? > "$TMP/rc"; }
rrc(){ cat "$TMP/rc"; }
err_a(){ grep -qF -- "$1" "$TMP/err"; }

P_LOAD='. "$1" || exit 99; site_env_load; rc=$?; printf "GIT_HOST=%s|FORGE_KIND=%s\n" "${GIT_HOST:-<vide>}" "${FORGE_KIND:-<vide>}"; exit $rc'

for shell in $SHELLS; do
  echo "═══ S.1 [$shell] un SECRET dans un fichier versionné est REFUSÉ ═══"
  fixture 'WM_PASSWORD=motdepasse
'
  ( cd "$TMP/w" && env -u WM_PASSWORD "$shell" -c "$P_LOAD" sh "$LIB" ) >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"
  if [ "$(rrc)" = 2 ] && err_a 'SITE_SECRET_INTERDIT' && ! grep -q 'motdepasse' "$TMP/out"; then
    ok "S.1 [$shell] nom de secret ⇒ refus nommé SITE_SECRET_INTERDIT, rc 2, rien n'est posé"
  else ko "S.1 [$shell] rc $(rrc) — $(head -1 "$TMP/err" | cut -c1-120)"; fi

  echo "═══ S.2 [$shell] l'ENVIRONNEMENT POSÉ l'emporte sur le fichier ═══"
  fixture 'GIT_HOST=https://du-fichier
'
  ( cd "$TMP/w" && GIT_HOST=https://de-l-env "$shell" -c "$P_LOAD" sh "$LIB" ) >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"
  if grep -q 'GIT_HOST=https://de-l-env' "$TMP/out" && err_a 'IGNORÉ'; then
    ok "S.2 [$shell] la valeur de l'environnement est retenue, et l'ignorance du fichier est ANNONCÉE"
  else ko "S.2 [$shell] retenu '$(cut -d'|' -f1 < "$TMP/out")' — $(grep IGNOR "$TMP/err" | head -1 | cut -c1-100)"; fi

  echo "═══ S.3 [$shell] une ligne INCLASSABLE refuse, elle n'est pas ignorée ═══"
  fixture 'GIT_HOST=https://bon
ceci nest pas une paire
'
  ( cd "$TMP/w" && env -u GIT_HOST "$shell" -c "$P_LOAD" sh "$LIB" ) >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"
  if [ "$(rrc)" = 2 ] && err_a 'SITE_LIGNE_INVALIDE' && grep -q 'GIT_HOST=<vide>' "$TMP/out"; then
    ok "S.3 [$shell] ligne inclassable ⇒ rc 2 ; et S.6 : la ligne VALIDE qui la précède n'a PAS été posée (atomicité)"
  else ko "S.3 [$shell] rc $(rrc) sortie '$(head -1 "$TMP/out" | cut -c1-80)'"; fi

  echo "═══ S.4 [$shell] aucun fichier : dégradation NOMMÉE, jamais une panne ═══"
  rm -rf "$TMP/w"; mkdir -p "$TMP/w"
  ( cd "$TMP/w" && env -u GIT_HOST "$shell" -c "$P_LOAD" sh "$LIB" ) >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"
  if [ "$(rrc)" = 0 ] && err_a 'aucun fichier de site'; then
    ok "S.4 [$shell] rc 0 et ligne nommée — un site qui a un admin n'est pas cassé par cette voie"
  else ko "S.4 [$shell] rc $(rrc) — $(head -1 "$TMP/err" | cut -c1-120)"; fi

  echo "═══ S.5 [$shell] un CRLF ne se propage pas dans la valeur ═══"
  fixture "$(printf 'GIT_HOST=https://crlf.example\r\n')"
  ( cd "$TMP/w" && env -u GIT_HOST "$shell" -c '. "$1"; site_env_load >/dev/null 2>&1; printf "%s\n" "${#GIT_HOST}"' sh "$LIB" ) >"$TMP/out" 2>"$TMP/err"
  if grep -qx '20' "$TMP/out"; then
    ok "S.5 [$shell] la valeur fait 20 caractères : le retour chariot est retiré (21 = un CR resté, qui casserait la première URL)"
  else ko "S.5 [$shell] longueur '$(head -1 "$TMP/out")' au lieu de 20"; fi

  echo "═══ S.10 [$shell] une CLÉ EN DOUBLE est INCLASSABLE : refus, jamais un arbitrage ═══"
  # POURQUOI CETTE ÉPREUVE EXISTE (2026-09-17, revue de la session voisine, puis
  # MESURÉE). Les deux lecteurs du format ne tranchaient pas pareil : la lib shell
  # gardait la PREMIÈRE valeur (la seconde tombe dans « déjà posé dans
  # l'environnement », un effet de bord de la précédence, pas une décision) et
  # l'extraction Groovy des récepteurs gardait la DERNIÈRE (`each` écrase). Le même
  # fichier donnait donc DEUX valeurs selon qu'on le lisait depuis un bloc `sh` ou
  # depuis `environment{}` — exactement la divergence silencieuse que ce dépôt a
  # fermée le 2026-09-06. La règle maison tranche : l'inclassable est ROUGE, on
  # n'arbitre pas à la place de l'auteur du fichier.
  fixture 'GIT_HOST=https://premier
GIT_HOST=https://second
'
  ( cd "$TMP/w" && env -u GIT_HOST "$shell" -c "$P_LOAD" sh "$LIB" ) >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"
  if [ "$(rrc)" = 2 ] && err_a 'SITE_CLE_EN_DOUBLE' && grep -q 'GIT_HOST=<vide>' "$TMP/out"; then
    ok "S.10 [$shell] clé répétée ⇒ refus nommé SITE_CLE_EN_DOUBLE, rc 2, et RIEN n'est posé (ni la première ni la seconde)"
  else ko "S.10 [$shell] rc $(rrc) retenu '$(cut -d'|' -f1 < "$TMP/out")' — $(head -1 "$TMP/err" | cut -c1-110)"; fi

  echo "═══ S.7 [$shell] STOA_SITE_FILE posé mais illisible : REFUS, jamais un repli ═══"
  ( cd "$TMP/w" && STOA_SITE_FILE=/nexiste/pas.ini "$shell" -c "$P_LOAD" sh "$LIB" ) >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"
  if [ "$(rrc)" = 2 ] && err_a 'SITE_FILE_ILLISIBLE'; then
    ok "S.7 [$shell] un pointeur EXPLICITE qui ne résout pas est un refus — pas un retour silencieux à la recherche par défaut"
  else ko "S.7 [$shell] rc $(rrc) — $(head -1 "$TMP/err" | cut -c1-120)"; fi
done

echo
echo "═══ S.8 mutations sur COPIE : chaque épreuve rougit sur le défaut qu'elle vise ═══"
# mute <étiquette> <sed> — écrit $TMP/mut-<et>.sh ; ko si no-op ou incompilable
# (l'ancre a changé de forme : l'épreuve ne prouverait plus rien).
mute(){
  local et="$1" expr="$2" lib="$TMP/mut-$1.sh"
  sed "$expr" "$LIB" > "$lib"
  if cmp -s "$LIB" "$lib" || ! dash -n "$lib" 2>/dev/null; then
    ko "$et mutant no-op ou incompilable — l'ancre a changé, l'épreuve ne prouve plus rien"; return 1
  fi
  return 0
}

# M1 — la garde de secret neutralisée : le secret DOIT sortir posé. C'est la
# seule façon de prouver qu'elle empêche une FUITE et pas seulement un message.
if mute M1 's/^    \*PASSWORD\*|\*SECRET\*|\*TOKEN\*|\*_KEY|\*CREDENTIALS) return 0 ;;/    ZZZ_JAMAIS) return 0 ;;/'; then
  fixture 'WM_PASSWORD=canari-du-mutant
'
  ( cd "$TMP/w" && env -u WM_PASSWORD dash -c '. "$1"; site_env_load >/dev/null 2>&1; printf "%s\n" "${WM_PASSWORD:-<vide>}"' sh "$TMP/mut-M1.sh" ) >"$TMP/out" 2>&1
  if grep -q 'canari-du-mutant' "$TMP/out"; then
    ok "M1 garde de secret neutralisée ⇒ le secret est POSÉ (S.1 rougit : c'est bien elle qui refuse, et elle empêche une fuite)"
  else ko "M1 le mutant refuse encore : '$(head -1 "$TMP/out" | cut -c1-80)'"; fi
fi

# M2 — la précédence retirée : le fichier écraserait l'environnement.
# ⚠ PREMIÈRE ÉCRITURE REFUSÉE PAR L'ÉPREUVE, et c'est le bon comportement : elle
# supprimait la ligne du MESSAGE (« déjà posé »), pas le test qui l'entoure. Le
# mutant compilait, ne changeait RIEN, et l'assertion l'a dit au lieu de passer.
# Un mutant doit viser le COMPORTEMENT, jamais l'annonce. On neutralise donc la
# condition elle-même ; le motif évite de citer ses guillemets imbriqués.
if mute M2 's/^    if \[ -n .*_sl_k.*\]; then$/    if false; then/'; then
  fixture 'GIT_HOST=https://du-fichier
'
  ( cd "$TMP/w" && GIT_HOST=https://de-l-env dash -c '. "$1"; site_env_load >/dev/null 2>&1; printf "%s\n" "$GIT_HOST"' sh "$TMP/mut-M2.sh" ) >"$TMP/out" 2>&1
  if grep -q 'du-fichier' "$TMP/out"; then
    ok "M2 précédence retirée ⇒ le fichier ÉCRASE l'environnement (S.2 rougit : la voie admin serait cassée par la voie fichier)"
  else ko "M2 le mutant respecte encore la précédence : '$(head -1 "$TMP/out")'"; fi
fi

# M3 — le refus d'inclassable retiré : la ligne serait ignorée EN SILENCE.
if mute M3 's/^      \*) _site_refus SITE_LIGNE_INVALIDE \\/      *) continue ;; *) _site_refus SITE_LIGNE_INVALIDE \\/'; then
  fixture 'GIT_HOST=https://bon
ceci nest pas une paire
'
  ( cd "$TMP/w" && env -u GIT_HOST dash -c '. "$1"; site_env_load >/dev/null 2>&1; printf "%s\n" "${GIT_HOST:-<vide>}"' sh "$TMP/mut-M3.sh" ) >"$TMP/out" 2>&1
  if grep -q 'https://bon' "$TMP/out"; then
    ok "M3 refus d'inclassable retiré ⇒ la ligne est ignorée en silence et le reste est posé (S.3 rougit)"
  else ko "M3 le mutant refuse encore : '$(head -1 "$TMP/out" | cut -c1-80)'"; fi
fi

# M4 — la garde de clé en double neutralisée : le fichier DOIT repasser, et la
# PREMIÈRE valeur ressortir posée. C'est la seule façon de montrer que le refus
# vient de cette garde, et non de l'ordre des lignes ou d'un autre contrôle.
if mute M4 's/^    case "$_sl_vus" in$/    case " AUCUN_NOM_JAMAIS " in/'; then
  fixture 'GIT_HOST=https://premier
GIT_HOST=https://second
'
  ( cd "$TMP/w" && env -u GIT_HOST dash -c '. "$1"; site_env_load >/dev/null 2>&1; printf "%s\n" "${GIT_HOST:-<vide>}"' sh "$TMP/mut-M4.sh" ) >"$TMP/out" 2>&1
  if grep -q 'https://premier' "$TMP/out"; then
    ok "M4 garde de doublon neutralisée ⇒ le fichier repasse et la PREMIÈRE valeur est posée (S.10 rougit : c'est bien elle qui refuse)"
  else ko "M4 le mutant refuse encore : '$(head -1 "$TMP/out" | cut -c1-80)'"; fi
fi

echo
echo "═══ S.11 MIROIR EXÉCUTÉ : le même fichier dans les DEUX analyseurs ═══"
# LE FORMAT A SIX IMPLÉMENTATIONS : ci/lib/site-env.sh (l'autorité) et le bloc
# Groovy recopié dans les cinq récepteurs, qui lisent config/site.ini AU PARSE,
# dans un stage `agent none` où aucun `sh` n'existe. Une shared library les
# unifierait — elle se déclare dans Manage Jenkins, précisément le droit que cette
# voie contourne. Puisqu'on ne peut pas SUPPRIMER la duplication, on la MESURE.
#
# ⚠ ON N'ÉCRIT PAS ICI UNE SEPTIÈME COPIE. Le bloc Groovy est EXTRAIT du
# Jenkinsfile réellement livré et EXÉCUTÉ ; seuls `readTrusted`, `echo` et `error`
# sont bouchonnés, plus un `env` VIDE : depuis le 2026-09-18 le bloc résout aussi
# l'agent des `node` explicites (agentSpec, qui lit env) — sa mesure propre est
# scripts/test-agent-node.sh, ce miroir n'y juge que le doublon. Retaper l'extraction rendrait ce miroir vert le jour même où
# les récepteurs divergeraient — c'est le défaut qu'il existe pour attraper.
GROOVY_IMG="${SITE_MIRROR_IMG:-groovy:4-jdk17}"
if ! command -v docker >/dev/null 2>&1; then
  note "S.11 SAUTÉE : docker absent — le miroir Groovy↔shell n'est pas mesuré sur ce poste"
elif ! docker image inspect "$GROOVY_IMG" >/dev/null 2>&1; then
  note "S.11 SAUTÉE : image $GROOVY_IMG absente — le miroir Groovy↔shell n'est pas mesuré ici"
else
  mkdir -p "$TMP/mir"
  # le bloc LIVRÉ, extrait tel quel (du `def` initial jusqu'au `}` du refus)
  awk '/^def SITE_WEBHOOK_KIND = /,/^pipeline \{/' "$REPO/ci/Jenkinsfile.provision-plan" \
    | sed '$d' > "$TMP/mir/bloc.groovy"
  { printf '%s\n' 'def readTrusted(String p) { return new File(System.getenv("SITE_FILE")).text }' \
                  'def echo(String m) { }' \
                  'def error(String m) { println m; System.exit(2) }' \
                  'env = [:]'
    cat "$TMP/mir/bloc.groovy"
    printf '%s\n' 'println "VALEUR:" + SITE_WEBHOOK_KIND'
  } > "$TMP/mir/mirror.groovy"

  # cas : <étiquette>|<contenu>|<verdict attendu>
  MIR_KO=""; MIR_N=0
  for cas in 'nominal|WEBHOOK_KIND=gitlab|ACCORD:gitlab' \
             'doublon|WEBHOOK_KIND=gwt\nWEBHOOK_KIND=gitlab|REFUS_DES_DEUX' \
             'guillemets|WEBHOOK_KIND="gitlab"|SHELL_REFUSE_GROOVY_INVALIDE' \
             'doublon-agent|AGENT_CONTAINER=ansible\nAGENT_CONTAINER=python|REFUS_DES_DEUX'; do
    et="${cas%%|*}"; reste="${cas#*|}"; contenu="${reste%|*}"; attendu="${reste##*|}"
    printf '%b\n' "$contenu" > "$TMP/mir/site.ini"
    # verdict SHELL
    s_rc=$( ( cd "$TMP/mir" && env -u WEBHOOK_KIND STOA_SITE_FILE="$TMP/mir/site.ini" \
        dash -c '. "$1"; site_env_load >/dev/null; printf "%s\n" "${WEBHOOK_KIND:-<vide>}"' sh "$LIB" ) 2>"$TMP/mir/s.err"; )
    s_tag=$(grep -oE 'SITE_[A-Z_]+' "$TMP/mir/s.err" | head -1)
    # verdict GROOVY (le bloc livré, exécuté)
    g_out=$(docker run --rm -e SITE_FILE=/m/site.ini -v "$TMP/mir:/m" "$GROOVY_IMG" \
              groovy /m/mirror.groovy 2>/dev/null | grep -E '^(VALEUR|REFUS):' | head -1)
    MIR_N=$((MIR_N+1))
    case "$attendu" in
      ACCORD:*) v="${attendu#ACCORD:}"
        { [ "$s_rc" = "$v" ] && [ "$g_out" = "VALEUR:$v" ]; } || MIR_KO="$MIR_KO $et(shell=$s_rc,groovy=$g_out)" ;;
      REFUS_DES_DEUX)
        { [ "$s_tag" = "SITE_CLE_EN_DOUBLE" ] && [ "${g_out#REFUS:}" != "$g_out" ] \
          && case "$g_out" in *SITE_CLE_EN_DOUBLE*) true ;; *) false ;; esac; } \
          || MIR_KO="$MIR_KO $et(shell=$s_tag,groovy=$g_out)" ;;
      SHELL_REFUSE_GROOVY_INVALIDE)
        # DIVERGENCE ASSUMÉE, et c'est un CHOIX, pas un oubli : le shell refuse au
        # chargement (SITE_VALEUR_NON_TRANSPORTABLE), le Groovy rend la valeur AVEC
        # ses guillemets, que le garde-fou aval refuse (WEBHOOK_KIND_INVALIDE). Les
        # deux sont fail-closed. Personne ne doit « réparer » par replaceAll('"','').
        { [ "$s_tag" = "SITE_VALEUR_NON_TRANSPORTABLE" ] \
          && [ "$g_out" != "VALEUR:gitlab" ] && [ "$g_out" != "VALEUR:gwt" ]; } \
          || MIR_KO="$MIR_KO $et(shell=$s_tag,groovy=$g_out)" ;;
    esac
  done
  if [ -z "$MIR_KO" ]; then
    ok "S.11 les deux analyseurs jugent $MIR_N fichiers à l'identique (valeur commune, doublon refusé des deux côtés, guillemets fail-closed des deux côtés) — le bloc Groovy EXÉCUTÉ est celui du Jenkinsfile livré"
  else ko "S.11 divergence Groovy↔shell :$MIR_KO"; fi
fi

echo
echo "═══ S.9 MIROIR : les DEUX voies refusent exactement les mêmes noms ═══"
# La voie admin (setup-jenkins-globals.sh, propriétés globales) et la voie sans
# admin (cette lib, fichier versionné) écrivent dans le MÊME canal logique. Si
# leurs règles divergent, un nom refusé d'un côté passe de l'autre — et la
# frontière des secrets dépend alors de la porte par laquelle on est entré.
# On ne compare pas les fichiers : on EXÉCUTE les deux classificateurs sur les
# mêmes noms, et on exige le même verdict. Une comparaison de texte serait
# verte le jour où l'un des deux change de forme sans changer de sens.
POSEUR="$REPO/scripts/setup-jenkins-globals.sh"
if [ ! -f "$POSEUR" ]; then
  ko "S.9 $POSEUR introuvable — le miroir ne peut pas être mesuré"
else
  MIROIR_KO=""
  for nom in GIT_HOST FORGE_KIND VAULT_ADDR APIM_API_BASE STOA_DEBUG \
             WM_PASSWORD FORGE_SECRET GITEA_TOKEN APIM_BACKEND_KEY VAULT_CREDENTIALS \
             GITEA_CREDENTIALS_ID TEAM_PUBLISH_WEBHOOK_SECRET TEAM_PROMOTE_WEBHOOK_SECRET; do
    # verdict de la LIB : _site_nom_secret rend 0 quand le nom est un secret
    v_lib=$(dash -c '. "$1"; if _site_nom_secret "$2"; then echo SECRET; else echo OK; fi' sh "$LIB" "$nom")
    # verdict du POSEUR : la même cascade de `case`, rejouée à l'identique
    v_pos=$(dash -c '
      case "$1" in
        *CREDENTIALS_ID) echo OK ;;
        TEAM_PUBLISH_WEBHOOK_SECRET|TEAM_PROMOTE_WEBHOOK_SECRET) echo OK ;;
        *PASSWORD*|*SECRET*|*TOKEN*|*_KEY|*CREDENTIALS) echo SECRET ;;
        *) echo OK ;;
      esac' sh "$nom")
    [ "$v_lib" = "$v_pos" ] || MIROIR_KO="$MIROIR_KO $nom(lib=$v_lib,poseur=$v_pos)"
  done
  if [ -z "$MIROIR_KO" ]; then
    ok "S.9 les deux voies rendent le MÊME verdict sur 13 noms (dont les 3 exemptions nommées) : la frontière des secrets ne dépend pas de la porte d'entrée"
  else ko "S.9 divergence :$MIROIR_KO"; fi
fi

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
