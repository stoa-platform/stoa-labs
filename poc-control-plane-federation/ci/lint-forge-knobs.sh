#!/usr/bin/env bash
# ci/lint-forge-knobs.sh — UN SCRIPT ROUTÉ SUR L'AUTORITÉ DE FORGE NE VAUT QUE
# SI LE JENKINSFILE QUI L'INVOQUE LUI TRANSMET LE VISAGE.
#
# ─────────────────────────────────────────────────────────────────────────────
# LE DÉFAUT QUE CETTE PORTE FERME (mesuré le 2026-09-12)
# ─────────────────────────────────────────────────────────────────────────────
# Router un script sur `scripts/lib/forge-api.sh` le rend capable de parler aux
# deux forges. Ça ne le fait pas. Le visage arrive par l'ENVIRONNEMENT, et c'est
# le Jenkinsfile qui le pose. Mesure du jour : `team-publish.sh` et
# `team-promote.sh` venaient d'être routés, et SIX Jenkinsfile de la chaîne
# producteur ne portaient AUCUN des trois knobs — `FORGE_KIND=0 FORGE_API_AUTH=0
# FORGE_API_BASE=0`. Or `forge_api_init` défautait alors sur `gitea` : donc
# INVISIBLE au lab (le défaut EST le bon visage) et FAUX VISAGE chez un client
# GitLab — /api/v1, 302 vers /users/sign_in, corps HTML, `FORGE_ILLISIBLE`.
# C'est l'incident du 2026-09-09 que le routage existe pour empêcher, et la
# forme de celui du 2026-09-10 (copie client d'un Jenkinsfile sans le knob).
#
# Rien ne l'aurait dit : `test-a0-wiring.sh` vérifie cette propriété À LA MAIN,
# un Jenkinsfile à la fois (`jfp`, `jfa`) — donc rien ne rougissait pour les six
# autres. Une porte à liste manuelle ne protège que ce que quelqu'un a pensé à
# y écrire.
#
# PORTÉE DÉRIVÉE, ET DE LA SOURCE DE QUELQU'UN D'AUTRE : la liste des scripts
# routés est `ROUTES` dans `ci/lint-forge-literals.sh` — elle est LUE, jamais
# recopiée. Elle ne fait que grandir (chaque tâche de routage y déplace son
# fichier depuis `EN_ROUTAGE`), donc la portée de cette porte grandit toute
# seule, sans que personne ne pense à elle.
#
# CE QU'ELLE NE MESURE PAS, et c'est nommé : la transitivité. Un Jenkinsfile qui
# appelle un script NON routé, lequel source une lib routée, n'est pas vu. Les
# libs de `ROUTES` (`scripts/lib/*.sh`) sont d'ailleurs SOURCÉES, jamais
# invoquées : elles sont rapportées, pas exigées.
#
#   bash ci/lint-forge-knobs.sh
set -uo pipefail
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RACINE" || exit 1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
info(){ printf '  ℹ %s\n' "$*"; }

SOURCE_ROUTES="ci/lint-forge-literals.sh"
KNOBS="FORGE_KIND FORGE_API_AUTH FORGE_API_BASE"

echo "═══ A. la source de portée est LISIBLE (sinon la porte ne mesure rien) ═══"
[ -f "$SOURCE_ROUTES" ] \
  || { ko "A.1 $SOURCE_ROUTES introuvable — aucune portée à dériver"; echo "PORTE ROUGE"; exit 1; }
# Le contenu de ROUTES='…' : de la ligne d'ouverture à la ligne qui ferme la
# quote. On ne source PAS le fichier (il s'exécuterait) ; on le LIT.
BRUT=$(awk "/^ROUTES='/,/'\$/" "$SOURCE_ROUTES" \
       | sed -e "s/^ROUTES='//" -e "s/'\$//" | grep -v '^[[:space:]]*$')
N_BRUT=$(printf '%s\n' "$BRUT" | grep -c '')
ROUTES=$(printf '%s\n' "$BRUT" | grep -E '^scripts/' | sort -u)
N_ROUTES=$(printf '%s\n' "$ROUTES" | grep -c 'scripts/')
if [ "$N_ROUTES" -lt 3 ]; then
  ko "A.2 ROUTES lue dans $SOURCE_ROUTES ne rend que $N_ROUTES fichier(s) — la lecture est cassée, pas le dépôt sain"
  echo "PORTE ROUGE"; exit 1
fi
# ANTI-VACUITÉ, et ce trou était dans CETTE porte (mesuré à sa 3e mutation le
# 2026-09-12) : filtrer sur `^scripts/` écarte EN SILENCE ce qu'on ne sait pas
# lire. Corrompre une entrée de ROUTES faisait simplement rétrécir la liste, et
# la porte restait VERTE sur les autres. On exige donc que TOUTE ligne du bloc
# soit comprise — un jour où ROUTES changera de forme, c'est rouge, pas muet.
if [ "$N_BRUT" -ne "$N_ROUTES" ]; then
  ko "A.3 le bloc ROUTES porte $N_BRUT ligne(s) et cette porte n'en comprend que $N_ROUTES — elle mesurerait un sous-ensemble en silence. Lignes incomprises :"
  printf '%s\n' "$BRUT" | grep -vE '^scripts/' | sed 's/^/       /'
  echo "PORTE ROUGE"; exit 1
fi
ok "A.3 les $N_BRUT lignes du bloc ROUTES sont TOUTES comprises — aucune entrée n'est écartée en silence"
ok "A.2 ROUTES lue (non recopiée) dans $SOURCE_ROUTES : $N_ROUTES scripts routés sur l'autorité de forge"

echo
echo "═══ B. tout script routé INVOQUÉ par un Jenkinsfile y reçoit le visage ═══"
MANQUANTS=""
N_PAIRES=0
N_LIBS=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  case "$s" in
    scripts/lib/*) N_LIBS=$((N_LIBS+1)); info "$s — lib SOURCÉE, jamais invoquée depuis un Jenkinsfile : rapportée, pas exigée (son visage vient du script appelant)"; continue ;;
  esac
  base="${s#scripts/}"
  # Les Jenkinsfile qui l'invoquent RÉELLEMENT : `bash scripts/x.sh` ou
  # `sh scripts/x.sh`, dans du CODE (les commentaires sont retirés).
  JFS=""
  for jf in ci/Jenkinsfile.*; do
    sed -E 's@^[[:space:]]*//.*$@@' "$jf" | grep -qE "(bash|sh) scripts/${base//./\\.}([^0-9A-Za-z_-]|\$)" \
      && JFS="$JFS $jf"
  done
  if [ -z "$JFS" ]; then
    info "$s — routé, mais AUCUN Jenkinsfile ne l'invoque directement (appelé par un autre script, ou par la main) : rien à exiger ici"
    continue
  fi
  for jf in $JFS; do
    N_PAIRES=$((N_PAIRES+1))
    ENVBLOC=$(awk '/^  environment \{/,/^  \}/' "$jf")
    for k in $KNOBS; do
      printf '%s\n' "$ENVBLOC" | grep -qE "^[[:space:]]*${k}[[:space:]]*=" \
        || MANQUANTS="$MANQUANTS ${jf#ci/Jenkinsfile.}:$k(pour $base)"
    done
  done
done <<< "$ROUTES"
if [ -z "$MANQUANTS" ]; then
  ok "B.1 $N_PAIRES couple(s) (script routé, Jenkinsfile qui l'invoque) : les trois knobs sont dans le bloc environment de chacun"
else
  ko "B.1 knobs ABSENTS —$MANQUANTS ; sans eux le script parle au visage par DÉFAUT, invisible au lab et faux chez le client"
fi
if [ "$N_PAIRES" -ge 3 ]; then
  ok "B.2 la portée n'est pas vide : $N_PAIRES couples mesurés ($N_LIBS libs rapportées)"
else
  ko "B.2 seulement $N_PAIRES couple(s) mesuré(s) — l'extraction des invocations est cassée (un vert vacant serait pire que rouge)"
fi

echo
echo "═══ C. FORGE_KIND n'a PAS de défaut de site — sinon le refus est inatteignable ═══"
# La décision du 2026-09-12 : `?: 'gitea'` dans un Jenkinsfile rendait le refus
# fail-closed de l'autorité INATTEIGNABLE, puisque le pipeline fournissait
# toujours une valeur — y compris dans la copie client, qui recopie le repli.
DEFAUTS=""
N_KIND=0
for jf in ci/Jenkinsfile.*; do
  L=$(sed -E 's@^[[:space:]]*//.*$@@' "$jf" | grep -E "^[[:space:]]*FORGE_KIND[[:space:]]*=" || true)
  [ -n "$L" ] || continue
  N_KIND=$((N_KIND+1))
  printf '%s\n' "$L" | grep -qF "?: ''" || DEFAUTS="$DEFAUTS ${jf#ci/Jenkinsfile.}"
done
if [ "$N_KIND" -lt 3 ]; then
  ko "C.0 seulement $N_KIND Jenkinsfile portent FORGE_KIND — l'extraction est cassée"
elif [ -z "$DEFAUTS" ]; then
  ok "C.1 les $N_KIND Jenkinsfile porteurs déclarent FORGE_KIND en repli VIDE : une globale manquante devient un REFUS, pas un visage supposé"
else
  ko "C.1 défaut de site sur FORGE_KIND —$DEFAUTS ; le refus FORGE_KIND_REQUIS ne pourrait jamais s'y déclencher"
fi

echo
echo "══════════════════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then echo "PORTE VERTE : $PASS contrôles."; exit 0
else echo "PORTE ROUGE : $FAIL échec(s) sur $((PASS+FAIL))."; exit 1; fi
