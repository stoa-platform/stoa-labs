#!/bin/sh
# ci/lib/preflight.sh — LE PRÉFLIGHT DE JOIGNABILITÉ DE LA GATEWAY, à SOURCER.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QUE FAIT CE PRÉFLIGHT, ET POURQUOI IL EXISTE
# ─────────────────────────────────────────────────────────────────────────────
# Avant de consommer une identité nominative (login Vault, mot de passe
# d'annuaire saisi à la main), le pipeline vérifie que la gateway RÉPOND. Le lab
# la recycle toutes les ~20 min (keepalive licence trial) et un rolling restart
# chez le client ouvre la même fenêtre : mieux vaut attendre son retour que
# mourir au milieu du play sur un « Connection refused » cryptique, après avoir
# déjà brûlé un mot de passe.
#
# ─────────────────────────────────────────────────────────────────────────────
# POURQUOI IL EST ICI, ET PLUS DANS LES JENKINSFILE
# ─────────────────────────────────────────────────────────────────────────────
# Il a vécu en DOUBLE, écrit à la main dans `ci/Jenkinsfile.selfservice` et dans
# `ci/Jenkinsfile.publish-api`. La dérive n'est pas une crainte : elle est
# MESURÉE. Le merge 5d34299 a rendu à `Jenkinsfile.publish-api` une version
# antérieure du bloc — sonde `/health` codée en dur, cinq minutes d'attente,
# aucun knob, aucun des quatre garde-fous — pendant que `Jenkinsfile.selfservice`
# gardait la bonne. Personne ne l'a vu, parce que rien ne comparait les deux
# copies. Il n'y a donc plus qu'UNE implémentation, et les deux pipelines
# l'appellent.
#
# ─────────────────────────────────────────────────────────────────────────────
# LES KNOBS — ET L'INCIDENT CLIENT QUI LES A FAIT NAÎTRE
# ─────────────────────────────────────────────────────────────────────────────
# Chez un client (banque), l'API d'admin webMethods n'est PAS jointe en direct :
# elle est proxifiée SUR la gateway elle-même, et `/health` n'est pas joignable
# depuis l'externe (filtré en amont, hors VIP). Le préflight y attendrait dix
# minutes puis échouerait, pour une raison étrangère au travail demandé.
#
#   APIM_PREFLIGHT        `off` (insensible à la casse) : ne sonde pas du tout.
#   APIM_PREFLIGHT_URL    viser UNE AUTRE sonde de vie que `<base>/health`.
#                         ⚠ C'EST UN GABARIT PAR PALIER, PAS UNE URL PLATE :
#                         `__ENV__` y est substitué par le palier du build,
#                         exactement comme la base d'admin l'est par
#                         `scripts/selfservice-palier-gate.sh`. Cf. ci-dessous.
#   APIM_PREFLIGHT_CODES  codes qui valent preuve de vie (défaut « 200 401 ») —
#                         401 SANS jeton EST la preuve de vie d'un proxy dont
#                         l'OAuth2 est déjà enforce ; c'est le cas du client.
#   APIM_PREFLIGHT_TRIES  nombre d'essais (défaut 60). Chaque essai coûte
#                         JUSQU'À 10 s — cf. « la durée annoncée » plus bas.
#
# Ce sont des valeurs de SITE : elles se posent en variables globales du
# contrôleur (`scripts/setup-jenkins-globals.sh`), pas dans le code.
#
# ─────────────────────────────────────────────────────────────────────────────
# `APIM_PREFLIGHT_URL` EST UN GABARIT — ET POURQUOI CE N'EST PAS UN DÉTAIL
# ─────────────────────────────────────────────────────────────────────────────
# Une globale de contrôleur porte UNE valeur pour TOUS les builds, alors que la
# base réellement sondée est PAR PALIER (`wm-admin-__ENV__`, `envs/<env>/…`).
# Une `APIM_PREFLIGHT_URL` plate posée en globale de site — ce que la procédure
# prescrivait — faisait donc sonder LE MÊME palier depuis tous les autres : cinq
# environnements annoncés vivants parce qu'un seul l'était, et l'argument `$1`
# que l'appelant prend la peine de résoudre ignoré en silence. D'où :
#   - `__ENV__` est substitué par le palier que l'appelant NOMME (2e argument) ;
#   - un gabarit sans palier nommé est un REFUS, jamais une sonde du littéral
#     `__ENV__` (fail-closed : mieux vaut nommer la cause que sonder un fantôme) ;
#   - une URL SANS `__ENV__` reste licite (une seule gateway pour tous les
#     paliers, cas réel) mais elle est ANNONCÉE comme telle sur la ligne de
#     trace : « sonde de SITE, la même pour TOUS les paliers ».
#
# ─────────────────────────────────────────────────────────────────────────────
# LA SUBSTITUTION N'APPARTIENT QU'AU GABARIT — ET C'EST UN FAIL-OPEN DE MOINS
# ─────────────────────────────────────────────────────────────────────────────
# Le premier jet écrivait le `sed s/__ENV__/…/` HORS du `if [ -n "$PF_URL" ]` :
# il s'appliquait donc AUSSI à la branche par défaut `$APIM_PREFLIGHT_BASE/health`
# — c'est-à-dire à la base d'admin que l'APPELANT transmet. Or l'arbitrage ne
# demandait la substitution QUE dans `APIM_PREFLIGHT_URL`, et cette base-là
# n'est PAS un gabarit : côté publication, `APIM_API_BASE` est composée de
# globales de SITE (`APIM_PROXY_BASE`, `APIM_PROXY_API`) que RIEN ne résout par
# palier. La lib « réparait » donc en silence une base qui aurait dû être
# REFUSÉE — un fail-open de la même famille que celui qu'elle venait de fermer :
#   base `https://apim-__ENV__.corp/…` + palier `rec`
#     → AVANT : sonde `https://apim-rec.corp/…`, verte, sur une base que
#               personne n'a résolue — et si le palier est vide, une URL fausse ;
#     → APRÈS : REFUS nommant la BASE, pas le knob.
# La base de l'appelant est donc prise TELLE QUELLE, et le refus fail-closed
# dit LAQUELLE des deux origines est en cause (`PF_POURQUOI`) : accuser
# `APIM_PREFLIGHT_URL` quand l'opérateur ne l'a jamais posée envoie l'exploitant
# chercher un knob qui n'existe pas.
#
# ─────────────────────────────────────────────────────────────────────────────
# LA DURÉE ANNONCÉE : ~10 s PAR ESSAI, PAS 5
# ─────────────────────────────────────────────────────────────────────────────
# `$((PF_MAX*5))` ne comptait que les `sleep 5` et oubliait le `-m 5` du curl.
# Or le mode de panne visé est justement celui où l'hôte NE RÉPOND PAS (paquet
# jeté, pas de RST) : le curl consomme alors son timeout ENTIER. Un essai coûte
# donc jusqu'à 5 s (curl) + 5 s (attente) = 10 s, et le défaut de 60 essais vaut
# jusqu'à ~10 minutes, pas 5. La borne haute exacte est `PF_MAX*10 - 5` (le
# dernier essai ne dort pas) ; on annonce `PF_MAX*10`, majorant honnête.
#
# ─────────────────────────────────────────────────────────────────────────────
# LES QUATRE GARDE-FOUS, ET CE QU'ILS ÉVITENT (chacun a une contre-épreuve
# dans ci/test-proxy-base-et-preflight.sh — ne pas les retirer)
# ─────────────────────────────────────────────────────────────────────────────
#   1. la casse de `off` — Jenkins ne normalise pas la casse d'un paramètre
#      `string` : « Off »/« OFF » ne désactivaient rien, en silence ;
#   2. APIM_PREFLIGHT_TRIES non entier — sous sh, `[ "$i" -ge "abc" ]` rend 2
#      (ni vrai ni faux) : la branche de sortie n'est JAMAIS prise, la boucle
#      tourne à l'infini ;
#   3. zéro EN TÊTE (`0`, `08`, `060`) — purement numérique, donc accepté par
#      le filtre ci-dessus, mais `$((08*5))` est une erreur d'arithmétique
#      octale qui TUE l'étape, et `$((060*5))` annonce 240 s au lieu de 300 ;
#   4. borne haute — une valeur énorme mais numérique (10^20) passe les filtres
#      et rouvre le même mode de panne : aucun timeout de build n'est posé dans
#      les job XML. La LONGUEUR est testée AVANT toute comparaison arithmétique.
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠ `set -e` N'EST PAS DISPONIBLE DANS CE CORPS DE FONCTION — MESURÉ
# ─────────────────────────────────────────────────────────────────────────────
# POSIX : `set -e` est IGNORÉ dans tout membre non final d'une liste `&&`/`||`
# ET dans la condition d'un `if`. Or les deux appelants écrivent
# `apim_preflight … || exit 1` : la fonction s'exécute donc AVEC `set -e`
# neutralisé dans tout son corps — ce dont le bloc en ligne d'avant bénéficiait,
# lui, puisqu'il n'était pas une fonction. Mesuré le 2026-09-07 sous dash :
#   f(){ false; echo REACHED; }   set -e
#   f || exit 1          → REACHED    (set -e neutralisé)
#   if ! f; then …; fi   → REACHED    (idem : `if` neutralise aussi)
#   f                    → rien       (le seul appel nu restaure set -e)
# La forme `if ! …` ne corrige donc RIEN, contrairement à l'intuition. Plutôt
# que d'imposer aux appelants la seule forme qui marche (fragile : la prochaine
# main écrira `|| exit 1`), CETTE FONCTION NE DÉPEND PLUS DE `set -e` : chaque
# commande qui peut échouer vérifie son propre code retour, ci-dessous. Sans
# quoi un `sleep` mort (conteneur sans coreutils, signal) laissait la boucle
# tourner jusqu'à épuisement au lieu d'arrêter l'étape.
#
# ─────────────────────────────────────────────────────────────────────────────
# USAGE (dans un bloc `sh '''…'''` sous `set -eu`, depuis la racine du livrable)
#   . ci/lib/preflight.sh
#   apim_preflight "$APIM_API_BASE" "$PALIER_ENV" || exit 1
# ─────────────────────────────────────────────────────────────────────────────
# ⚠ POSIX sh, PAS bash : un bloc `sh` de Jenkins tourne en dash. Pas de
#   `local`, pas de `[[`, pas de tableau. Ce fichier est SOURCÉ, jamais exécuté.

# Rend 0 si la gateway répond (ou si le préflight est désactivé), 1 si elle
# reste injoignable après APIM_PREFLIGHT_TRIES essais, 1 aussi sur tout refus
# de forme. N'écrit rien d'autre que des lignes de trace ; ne lit aucun secret ;
# n'envoie aucun jeton.
#
# $1 — base de l'API d'admin à sonder (déjà résolue par l'appelant : le palier
#      pour le self-service, le self-proxy pour la publication). À défaut,
#      APIM_API_BASE de l'environnement.
# $2 — LE PALIER du build (`rec`, `int`, `prod`…), substitué à `__ENV__` dans
#      APIM_PREFLIGHT_URL. Vide est licite (API mono-palier) — mais alors un
#      gabarit portant `__ENV__` est REFUSÉ, jamais sondé littéralement.
apim_preflight() {
  APIM_PREFLIGHT_BASE="${1:-${APIM_API_BASE:-}}"
  PF_ENV="${2:-}"
  PF_SITE=""

  # Comparaison insensible à la casse : Jenkins ne normalise pas la
  # casse d'un paramètre `string`, et "Off"/"OFF" ne désactivaient
  # rien avant ce correctif — silencieusement.
  # `|| return 1` : sans `set -e` (cf. l'entête), un `tr` absent rendrait
  # APIM_PREFLIGHT_LC vide, donc « ni off ni on », et le préflight partirait
  # quand même — une panne d'outillage ne doit pas se lire comme un « on ».
  APIM_PREFLIGHT_LC="$(printf '%s' "${APIM_PREFLIGHT:-on}" | tr '[:upper:]' '[:lower:]')" || {
    echo "  ✗ préflight de joignabilité : REFUSÉ — normalisation de APIM_PREFLIGHT impossible (tr indisponible ?)"
    return 1
  }
  if [ "$APIM_PREFLIGHT_LC" = "off" ]; then
    # LE MÊME MARQUEUR que le chemin actif (`préflight de joignabilité :`) :
    # des preuves du dépôt s'ancrent dessus (scripts/test-a{3,4,5,7}-live.sh,
    # ADR-082) et `off` est précisément le remède prescrit au client. Une
    # désactivation qui EFFACE le marqueur rendrait ces preuves muettes là où
    # elles doivent dire « désactivé », pas « absent ».
    echo "  préflight de joignabilité : DÉSACTIVÉ (APIM_PREFLIGHT=off) — la gateway n'est PAS sondée"
    return 0
  fi

  # Le palier part dans une expression `sed` : on borne sa classe AVANT, sinon
  # un `/` l'y ferait éclater. Même classe que la garde du palier, élargie aux
  # majuscules et au tiret pour ne pas refuser un nom d'environnement client.
  case "$PF_ENV" in
    '') ;;
    *[!A-Za-z0-9_-]*)
      echo "  ✗ préflight de joignabilité : REFUSÉ — palier '$PF_ENV' hors de [A-Za-z0-9_-]"
      return 1 ;;
  esac

  # D'OÙ vient l'URL décide de DEUX choses : si `__ENV__` y est substitué, et
  # ce que dit le refus plus bas. Les deux origines n'ont pas le même statut —
  # cf. l'entête « la substitution n'appartient QU'AU gabarit ».
  PF_URL="${APIM_PREFLIGHT_URL:-}"
  PF_POURQUOI=""
  if [ -n "$PF_URL" ]; then
    # Une sonde de site SANS `__ENV__` reste licite (gateway unique), mais elle
    # est DITE : sans cette ligne, cinq paliers sondant la même URL se lisent
    # comme cinq paliers vivants.
    case "$PF_URL" in
      *__ENV__*) ;;
      *) [ -z "$PF_ENV" ] || PF_SITE=" — sonde de SITE, la même pour TOUS les paliers" ;;
    esac
    # ⚠ LA SUBSTITUTION VIT *DANS* CETTE BRANCHE, ET C'EST TOUT L'ARBITRAGE.
    # Hors du `if`, elle s'appliquait AUSSI à `$APIM_PREFLIGHT_BASE/health` —
    # cf. l'entête : la lib réparait alors en silence une base de SITE qu'elle
    # aurait dû refuser.
    if [ -n "$PF_ENV" ]; then
      PF_URL="$(printf '%s' "$PF_URL" | sed "s/__ENV__/$PF_ENV/g")" || {
        echo "  ✗ préflight de joignabilité : REFUSÉ — substitution de __ENV__ impossible (sed indisponible ?)"
        return 1
      }
      PF_POURQUOI="APIM_PREFLIGHT_URL est un GABARIT PAR PALIER, et le palier nommé ('$PF_ENV') ne l'a pas entièrement résolu"
    else
      PF_POURQUOI="APIM_PREFLIGHT_URL est un GABARIT PAR PALIER et l'appelant n'a pas nommé le palier (2e argument d'apim_preflight)"
    fi
  else
    # LA BASE DE L'APPELANT, TELLE QUELLE — aucune substitution. C'est LUI qui
    # résout son palier (garde du palier pour le self-service, self-proxy pour
    # la publication) ; cette lib n'a pas à réparer ce qu'il n'a pas résolu.
    PF_URL="$APIM_PREFLIGHT_BASE/health"
    PF_POURQUOI="c'est la base d'admin reçue de l'appelant (1er argument, ou APIM_API_BASE), et elle n'a PAS été résolue par palier — une globale de SITE posée telle quelle ? Cette lib ne substitue QUE dans APIM_PREFLIGHT_URL, jamais dans une base : à l'appelant de la résoudre"
  fi
  # Fail-closed : un gabarit non substitué sonderait le littéral `__ENV__` —
  # une URL qui n'existe nulle part, donc un échec à retardement de dix minutes
  # dont la cause serait illisible. On nomme la cause tout de suite — LA VRAIE :
  # accuser `APIM_PREFLIGHT_URL` quand l'opérateur ne l'a pas posée envoie
  # chercher un knob absent, alors que la faute est dans la base de l'appelant.
  case "$PF_URL" in
    *__ENV__*)
      echo "  ✗ préflight de joignabilité : REFUSÉ — '$PF_URL' porte encore __ENV__ : $PF_POURQUOI"
      return 1 ;;
  esac
  # 200 = up (accès direct) ; 401 = up ET l'OAuth2 du proxy est déjà
  # enforce (on sonde SANS token — le 401 est la preuve de vie du proxy).
  PF_CODES="${APIM_PREFLIGHT_CODES:-200 401}"
  PF_MAX="${APIM_PREFLIGHT_TRIES:-60}"
  # `[ "$i" -ge "$PF_MAX" ]` sous sh : si PF_MAX n'est pas un entier
  # décimal canonique, `-ge` rend soit 2 (ni vrai ni faux — la
  # branche de sortie n'est JAMAIS prise, boucle à l'infini), soit
  # une interprétation OCTALE surprenante dans `$((PF_MAX*10))` plus
  # bas (`08` : arithmétique invalide, l'étape meurt sur un message
  # cryptique — exactement ce que ce garde-fou doit éviter). `0*`
  # rejette `0`/`00` ET tout zéro en tête (`08`, `060`). On valide
  # AVANT d'entrer dans la boucle ; repli sur le défaut, avec avertissement.
  case "$PF_MAX" in
    ''|*[!0-9]*|0*) echo "  ⚠ APIM_PREFLIGHT_TRIES='$PF_MAX' n'est pas un entier positif — repli sur le défaut (60)"; PF_MAX=60 ;;
  esac
  # Borne haute : une valeur énorme mais numérique (ex.
  # 99999999999999999999) passe le garde-fou ci-dessus et rouvre
  # le même mode de panne — une boucle non bornée en pratique
  # (aucun timeout de build n'est posé dans les job XML). La
  # LONGUEUR est testée avant toute comparaison arithmétique :
  # au-delà de 4 chiffres la valeur dépasse déjà 3600, sans
  # risquer un débordement de `-gt` sur un entier à 20 chiffres.
  case "$PF_MAX" in
    ?????*) echo "  ⚠ APIM_PREFLIGHT_TRIES='$PF_MAX' dépasse la borne raisonnable — repli sur 3600"; PF_MAX=3600 ;;
  esac
  if [ "$PF_MAX" -gt 3600 ]; then
    echo "  ⚠ APIM_PREFLIGHT_TRIES='$PF_MAX' dépasse la borne raisonnable — repli sur 3600"
    PF_MAX=3600
  fi
  # `jusqu'à ~N s` et non `N s` : chaque essai coûte le timeout du curl (5 s
  # quand l'hôte ne répond pas) PUIS l'attente (5 s). L'ancien chiffre ne
  # comptait que l'attente et sous-estimait d'un facteur 2.
  echo "  préflight de joignabilité : $PF_URL (codes attendus : $PF_CODES, max $PF_MAX essais — jusqu'à ~$((PF_MAX*10))s)$PF_SITE"
  i=0
  while :; do
    HC="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$PF_URL" || true)"
    for C in $PF_CODES; do
      if [ "$HC" = "$C" ]; then break 2; fi
    done
    i=$((i+1))
    if [ "$i" -ge "$PF_MAX" ]; then echo "  ✗ gateway toujours injoignable après $PF_MAX essais / jusqu'à ~$((PF_MAX*10))s ($PF_URL -> $HC ; attendu : $PF_CODES)"; return 1; fi
    if [ "$i" -eq 1 ]; then echo "  (gateway indisponible — recyclage en cours ? attente du retour, jusqu'à ~$((PF_MAX*10))s…)"; fi
    # `|| return 1` : cf. l'entête — `set -e` est neutralisé dans ce corps par
    # la forme d'appel `… || exit 1`. Sans ce contrôle explicite, un `sleep`
    # qui échoue laissait la boucle tourner PF_MAX fois à pleine vitesse au
    # lieu d'arrêter l'étape : le préflight devenait un compteur, plus une
    # attente. Contre-épreuve : ci/test-proxy-base-et-preflight.sh, section
    # « une commande qui échoue AU MILIEU arrête le préflight ».
    sleep 5 || {
      echo "  ✗ préflight de joignabilité : REFUSÉ — l'attente entre deux essais a échoué (sleep rc=$?) ; le préflight ne peut plus attendre, l'étape s'arrête ici"
      return 1
    }
  done
  return 0
}
