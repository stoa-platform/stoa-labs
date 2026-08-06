#!/usr/bin/env bash
# test-producer-chain.sh — la matrice de preuve du palier 3 : la CHAÎNE
# PRODUCTEUR complète, du formulaire « publier une API » (api-request.sh)
# jusqu'à l'API RÉELLEMENT publiée sur la gateway par le job post-merge
# (team-publish), sur une équipe et des dépôts JETABLES, rejouable de bout en
# bout. 10 preuves + une contre-épreuve rouge (preuve 9) :
#   0   NON-RÉGRESSION : la matrice du palier 2 (chaîne d'onboarding, 11
#       contrôles) rejouée VERTE, ET les voies MACHINE (OIG/CLI2) du palier
#       antérieur rejouées à manifeste diff-vide (golden files, Section C de
#       scripts/test-app-request-v2.sh).
#   1   gardes d'entrée d'api-request.sh : CHAQUE refus ne laisse AUCUNE trace
#       (ls-remote du dépôt d'ÉQUIPE, avant/après, identique).
#   2   nominal `create` : PR sur le dépôt d'équipe portant spec + manifeste,
#       plan ✅ commenté avec la hiérarchie de diagnostic.
#   3   REPO_NON_DECLARE : un dépôt d'équipe RÉEL mais absent de
#       providers.<env>.yml déclenche team-publish -> refus, PR commentée ❌.
#   4   câblage : test-team-publish-wiring.sh (greps ancrés) + garde
#       d'identité rouge/verte (contre-épreuve directe).
#   5   MERGE RÉEL par un SECOND humain (oscar) -> webhook GITEA RÉEL -> job
#       team-publish -> pause répondue par l'API -> garde d'identité -> apply
#       -> API vue sur la gateway -> ✅ sur la PR. Le mot de passe nominatif
#       n'apparaît jamais dans le log du build.
#   6   NOUVELLE VERSION (le piège multi-version, en preuve rejouable) : v2
#       minée depuis v1, policies CLONÉES (M2) et SOUSCRIPTIONS RELUES
#       AVANT/APRÈS le mint (M3) — la base reste abonnée, la v2 hérite.
#   7   re-pose ÉVÉNEMENTIELLE des listes : après l'onboarding les formulaires
#       portent la nouvelle ÉQUIPE ; après la publication ils portent la
#       nouvelle API.
#   8   sondage `ps -Aww` continu AVEC CONTRÔLE POSITIF (trafic git réellement
#       observé) — aucun secret en argv.
#   9   teardown symétrique (404 EXACT, jamais « ≠200 ») ET le harnais SAIT
#       ROUGIR : une garde est cassée pour de vrai, la preuve 1 vire au FAIL,
#       la garde est restaurée à l'octet près.
#
# CIBLES OBLIGATOIRES, SANS DÉFAUT — même discipline que la matrice du
# palier 2 : un défaut vers un système EN SERVICE ferait qu'un lancement
# distrait écrirait dessus. C'est à qui lance ce script de fournir ses cibles :
#   GITEA_URL         base HTTP de la forge, vue du HOST (ex. http://localhost:13000)
#   GITEA_TOKEN       token du compte de service `ci`, scopes
#                     write:repository,write:issue,write:organization
#                     (write:organization est requis : sans lui un DELETE d'org
#                     rend 403 et un GET d'org absent rend 403 AU LIEU DE 404 —
#                     la preuve 9 exige 404 EXACT)
#   VAULT_ADDR        ex. http://localhost:8200
#   VAULT_TOKEN_FILE  FICHIER 0600 portant le token d'amorçage (root du Vault
#                     de LAB). JAMAIS le token en variable d'environnement
#                     nue : il ne sert qu'à minter un token ÉPHÉMÈRE
#                     mono-policy `team-onboarder` (l'onboarding tourne avec CE
#                     périmètre) et à re-minter le mot de passe d'oscar.
#   WM_GATEWAY_URL    LE MOCK webMethods, vu du HOST — et il doit s'agir du
#                     MÊME mock que celui que le JOB atteint depuis le réseau
#                     compose (`webmethods-mock:8080`, défaut du job XML), donc
#                     en pratique http://localhost:${PORT_WEBMETHODS:-8090}.
#                     JAMAIS le port 5555 : c'est la VRAIE gateway 10.15 du
#                     lab, en service. Les preuves 5/6 relisent l'API publiée
#                     ICI alors que le job l'a écrite LÀ-BAS : si les deux
#                     n'étaient pas le même mock, ces preuves échoueraient —
#                     c'est la seule vérification possible de cette égalité,
#                     et elle est structurelle.
#   JENKINS_UI        base HTTP de Jenkins vue du HOST (ex. http://localhost:18080).
#                     DEPUIS les conteneurs, Jenkins est `jenkins:8080` — c'est
#                     ce que les scripts appelés en job utilisent (fix mesuré
#                     de la Task 7), jamais cette valeur-ci.
#
# ── L'ÉCART STRUCTURANT À CONNAÎTRE AVANT DE LIRE LES VERDICTS ──────────────
# LE GATE GITEA DU PALIER 3 N'EST PAS LEVÉ. Les jobs Jenkins clonent le dépôt
# PLATEFORME (`ci/stoa-labs`) sur sa branche `main` ; `main` porte le
# palier 2, PAS le palier 3 (vérifié : ni scripts/team-publish.sh, ni
# scripts/api-request.sh, ni scripts/lib/generate-choices.sh, ni
# ci/jenkins/team-publish.job.xml n'y sont). Un job team-publish posé tel quel
# échouerait donc « fichier absent », et non sur ce qu'il est censé prouver.
#
# Ce harnais MONTE DONC LE PRÉREQUIS EN SCRATCH plutôt que de pousser le
# palier 3 sur `ci/stoa-labs` main (décision de gate, hors de son ressort, et
# le palier interdit explicitement de polluer main) : il crée un dépôt
# PLATEFORME JETABLE (`p3t8lab/stoa-labs`), y publie l'arbre EXACT du commit
# courant (`git archive HEAD`), et pose le job team-publish depuis son XML
# LIVRÉ avec DEUX substitutions, les seules :
#   1. `git url:` -> le dépôt plateforme jetable (2 occurrences) ;
#   2. `export GIT_REPO=<dépôt jetable>` ajouté à côté de l'export
#      APIM_API_BASE déjà présent, pour que team-publish.sh résolve la
#      topologie (providers.<env>.yml) dans CE dépôt.
# TOUT LE RESTE tourne tel que livré : le trigger GWT et son filtre, la garde
# de branche api/*, la pause nominative, la garde d'identité, le `finally`
# d'entrée, team-publish.sh entier, le rôle apim_publish_api, les marqueurs de
# commentaire. Le jour où le gate est levé, ces deux substitutions disparaissent
# et le reste de ce harnais ne bouge pas.
# CONSÉQUENCE À NE PAS PERDRE DE VUE : `ci/stoa-labs` n'est JAMAIS touché par
# les preuves 1 à 9 — ni sa branche main, ni ses branches, ni ses PR. La
# preuve 0, elle, invoque la matrice du palier 2 TELLE QU'ELLE EST : celle-ci
# travaille sur `ci/stoa-labs` (son propre contrat — son job team-apply y est
# codé en dur) et y revient bit-à-bit par son propre teardown. C'est un choix
# de CE harnais de la rejouer fidèlement plutôt que de la détourner.
#
# ── PRÉREQUIS D'ENVIRONNEMENT, VÉRIFIÉS AU DÉMARRAGE (échec NOMMÉ, jamais un
# verdict faux) -------------------------------------------------------------
#   - MOCK À JOUR. Le conteneur du mock doit porter l'image construite depuis
#     mocks/webmethods/ de CE dépôt. Sonde : POST /apis/<id inconnu>/versions
#     doit rendre 401 (comportement mesuré sur la 10.15 le 2026-08-05 et
#     reproduit par le mock du palier 3). Une image ANTÉRIEURE rend 404 avec
#     « api ... not found » : la sémantique des versions (preuve 6) y est
#     absente. Remède : docker build -t stoa-labs/webmethods-mock:dev
#     mocks/webmethods/ puis RECRÉER le conteneur (`docker restart` ne suffit
#     PAS — il relance l'ANCIENNE image ; constaté en direct).
#   - oscar existe dans Gitea ET dans Vault (userpass), et porte la policy
#     `team-onboarder` — sinon l'apply d'onboarding échoue à la lecture du
#     token org-admin. Remède : scripts/setup-team-onboard-prereqs.sh
#     (idempotent, ATTACHE la policy sans jamais remplacer les autres).
#   - CHECKOUT PROPRE. `git status --porcelain` doit être VIDE : l'arbre publié
#     dans le dépôt plateforme jetable est `git archive HEAD`, donc un fichier
#     modifié non commité NE SERAIT PAS celui que le job exécute, et les
#     verdicts porteraient sur autre chose que ce qu'on lit. Refus explicite.
#
# ── COMPORTEMENTS MESURÉS DU MOCK (et leur écart avec la vraie 10.15) ───────
# La preuve 9 exige des 404 EXACTS. Ce que le mock rend RÉELLEMENT, mesuré sur
# l'image de ce dépôt le 2026-08-06 :
#   GET  /apis/<inconnu>            -> 404      (la 10.15 rend 401)
#   PUT  /apis/<inconnu>/activate   -> 404      (la 10.15 rend 401)
#   POST /apis/<inconnu>/versions   -> 401      (fidèle : c'est LE chemin que
#                                                le spike T1 a mesuré)
#   DELETE /apis/<id>               -> 405      (AUCUNE route DELETE, nulle part)
# Sur la VRAIE 10.15, une ressource supprimée — ou un GUID jamais existé —
# répond 401 « User doesn't have permission to manage this API », même en
# Administrator. Les 404 EXACTS de la preuve 9 portent donc sur GITEA, VAULT et
# JENKINS (qui, eux, rendent bien 404), jamais sur les objets de la gateway :
# le mock n'expose AUCUN DELETE, exactement comme au palier 2. Le retour à
# l'ardoise vierge côté gateway passe par un redémarrage du conteneur du mock
# (geste d'opérateur), pas par ce script — qui le DIT plutôt que de fermer les
# yeux dessus. La bascule `enableTeamWork`, elle, EST rendue à sa valeur
# d'entrée (mesurée, pas supposée).
set -uo pipefail
set +x   # jamais de trace : des tokens transitent par ce script
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$(pwd)"

GITEA_URL="${GITEA_URL:?GITEA_URL requis (ex. http://localhost:13000) — aucun défaut, jamais deviner la forge}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis (compte ci, scopes write:repository,write:issue,write:organization — write:organization est requis pour que la preuve 9 obtienne 404 et non 403 sur un org supprimé)}"
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR requis}"
# NB : aucune apostrophe dans les messages ${VAR:?…} — bash 3.2 (celui de
# macOS) y voit une ouverture de chaîne simple-quotée et perd le `}` fermant :
# « unexpected EOF while looking for matching } », à des dizaines de lignes de
# là. Constaté en direct sur ce fichier.
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE requis — un FICHIER 0600 portant le token racine du Vault de lab (amorçage), jamais le token en variable nue}"
WM_GATEWAY_URL="${WM_GATEWAY_URL:?WM_GATEWAY_URL requis, SANS DÉFAUT : le MOCK vu du host (typiquement http://localhost:8090), et le MÊME que celui que le job atteint par webmethods-mock:8080. Le port 5555 est la VRAIE gateway du lab, en service.}"
JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis (ex. http://localhost:18080) — vue HOST ; depuis les conteneurs, Jenkins est jenkins:8080}"

# Vue INTERNE du réseau compose : c'est ce que Jenkins et les scripts qui
# tournent DANS un job utilisent pour joindre Gitea. Jamais GITEA_URL (vue
# host), qui ne résout pas depuis un conteneur.
GIT_HOST_INTERNAL="${GIT_HOST_INTERNAL:-http://gitea:3000}"
ENVN="${ENVN:-dev}"

# Objets JETABLES — aucun tenant réel, aucun dépôt de travail du palier.
PLAT_ORG="p3t8lab"                  # dépôt plateforme de substitution (cf. écart du gate)
PLAT_REPO="${PLAT_ORG}/stoa-labs"
TEAM="probe-p3"                     # équipe jetable, onboardée puis démontée
TEAM_REPO="${TEAM}/apis"
ORPH_ORG="p3t8x"                    # dépôt d'équipe RÉEL mais NON déclaré (preuve 3)
ORPH_REPO="${ORPH_ORG}/orphan-api"
# Noms d'objets GATEWAY portant l'horodatage du run. Ce n'est pas de la
# coquetterie : le mock n'expose AUCUNE route DELETE (405, cf. l'en-tête), donc
# les APIs et applications d'un run PRÉCÉDENT SURVIVENT dans son état en
# mémoire. Avec un nom fixe, le rôle — idempotent par construction — RETROUVE
# la v1 et la v2 du run d'avant au lieu de les créer : aucun mint n'a lieu, la
# preuve 6 ne voit ni VERSION_CREATED ni transport de souscription, et échoue
# en accusant la chaîne alors que c'est l'ardoise qui n'était pas vierge.
# Constaté en direct au deuxième run de ce harnais. Un nom par run rend la
# matrice rejouable SANS exiger le redémarrage du conteneur du mock — au prix
# d'objets qui s'accumulent dans son état en mémoire, disparaissant au
# prochain redémarrage (état volatil, aucun disque).
# RUN_TAG porte AUSSI le PID et un aléa, pas seulement l'horodatage : `date +%s`
# résout à la SECONDE, donc deux runs démarrés dans la même seconde
# obtiendraient le MÊME jeton — et `claim_build` accepterait alors le build de
# l'autre run. Ce que la valeur garantit : deux runs qui coexistent ont des PID
# DIFFÉRENTS (le système ne réattribue pas un PID vivant), ce qui suffit à
# distinguer deux instances CONCURRENTES ; l'horodatage et l'aléa ne font que
# réduire la collision avec un run PASSÉ dont le PID aurait été recyclé.
# Format : uniquement [0-9-] — le nom d'API qui en dérive doit rester dans la
# classe que la porte du producteur accepte (assertion ci-dessous).
RUN_TAG="$(date +%s)-$$-${RANDOM}"
API_NAME="t8api${RUN_TAG}"
WITNESS_APP="t8consumer${RUN_TAG}"  # application témoin des souscriptions (preuve 6)
# FAIL-CLOSED : le nom dérivé doit satisfaire la MÊME regex que la garde
# API_NAME d'api-request.sh (^[a-z0-9][a-z0-9-]{1,30}$, donc 31 caractères au
# plus). Sans ce contrôle, un futur changement de format de RUN_TAG ferait
# échouer la preuve 2 sur un refus de la porte — un rouge qui accuserait la
# chaîne pour un défaut du harnais.
printf '%s' "$API_NAME" | grep -Eq '^[a-z0-9][a-z0-9-]{1,30}$' \
  || { echo "API_NAME dérivé de RUN_TAG ('$API_NAME', ${#API_NAME} caractères) ne satisfait PAS la regex de la porte producteur ^[a-z0-9][a-z0-9-]{1,30}\$ — corriger le format de RUN_TAG" >&2; exit 2; }
JOB="team-publish"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

TMP="$(mktemp -d)"; chmod 700 "$TMP"

# ── helpers header-file (ADR-074) : un secret part TOUJOURS par un fichier
# 0600, jamais en argv/URL — même motif que team-request.sh/team-apply.sh, et
# c'est la preuve 8 qui le POLICE. ------------------------------------------
VROOT="$(cat "$VAULT_TOKEN_FILE" 2>/dev/null)"
[ -n "$VROOT" ] || { echo "VAULT_TOKEN_FILE ('$VAULT_TOKEN_FILE') illisible ou vide — abandon" >&2; exit 2; }
vhdr() { local f; f="$(mktemp "$TMP/vhdr.XXXXXX")"; chmod 600 "$f"; printf 'X-Vault-Token: %s\n' "$1" > "$f"; printf '%s' "$f"; }
vlt()  { curl -s -H @"$(vhdr "$1")" "$VAULT_ADDR/v1/$2" -o /dev/null -w '%{http_code}'; }
GHDR="$TMP/ghdr"; printf 'Authorization: token %s\n' "$GITEA_TOKEN" > "$GHDR"; chmod 600 "$GHDR"
gapi() { curl -s -H @"$GHDR" "$@"; }
ghc()  { gapi -o /dev/null -w '%{http_code}' "$@"; }
wmapi(){ curl -s -u Administrator:manage -H 'Accept: application/json' "$WM_GATEWAY_URL/rest/apigateway/$1"; }

# ── Jenkins : crumb + cookie DU MÊME appel (motif reconstitué au palier 2 —
# un crumb obtenu ailleurs que le cookie réutilisé fait répondre « Rejected »
# sans message exploitable). --------------------------------------------------
JCK="$TMP/jck"; JF=""; JC=""
jcrumb() {
  local cj; rm -f "$JCK"
  cj=$(curl -sf -c "$JCK" "$JENKINS_UI/crumbIssuer/api/json") || return 1
  JF=$(printf '%s' "$cj" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumbRequestField"])' 2>/dev/null)
  JC=$(printf '%s' "$cj" | python3 -c 'import sys,json;print(json.load(sys.stdin)["crumb"])' 2>/dev/null)
  [ -n "$JF" ] && [ -n "$JC" ]
}
jstatus() { curl -s "$JENKINS_UI/job/$1/$2/wfapi/describe" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' 2>/dev/null; }
jnext()   { curl -sf "$JENKINS_UI/job/$1/api/json" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])' 2>/dev/null; }

# Attend un état NON transitoire. Piège du palier 2 : wfapi rend une SUITE
# d'états avant la valeur cherchée — vide (build pas encore démarré, ou encore
# EN FILE), puis NOT_EXECUTED, puis IN_PROGRESS. S'arrêter au premier état
# « ni vide ni IN_PROGRESS » prendrait NOT_EXECUTED pour un état final.
jwait() {
  local job="$1" n="$2" secs="$3" st="" dl
  dl=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    st=$(jstatus "$job" "$n")
    case "$st" in ""|NOT_EXECUTED|IN_PROGRESS) sleep 2;; *) break;; esac
  done
  printf '%s' "$st"
}
jwait_end() {
  local job="$1" n="$2" secs="$3" st="" dl
  dl=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    st=$(jstatus "$job" "$n")
    case "$st" in PAUSED_PENDING_INPUT|IN_PROGRESS|"") sleep 3;; *) break;; esac
  done
  printf '%s' "$st"
}

# ── APPARTENANCE PROUVÉE DES BUILDS (fix round 2) ───────────────────────────
# MY_BUILDS : les numéros de build que CE RUN a fait naître, et dont
# l'appartenance a été PROUVÉE (cf. claim_build). Déclaré ICI, avant le trap,
# pour que cleanup_exit ne casse jamais sous `set -u`.
#
# POURQUOI un numéro de build et non plus un nom de périmètre (le fix du round
# précédent, insuffisant) : `probe-p3/apis` est le nom du PÉRIMÈTRE du harnais,
# pas de son EXÉCUTION. Deux runs CONCURRENTS de CETTE MÊME matrice produisent
# exactement le même `displayName` — le drain de l'un aurait donc abandonné la
# pause 4-yeux de l'autre, en annonçant « pause orpheline de CE harnais ».
# C'était une revendication d'appartenance FAUSSE : précisément la classe de
# défaut que ce palier traque partout ailleurs. Le numéro de build, lui, est
# unique par job et connu de ce run seul.
MY_BUILDS=""
is_mine() { case " $MY_BUILDS " in *" $1 "*) return 0;; *) return 1;; esac; }

# claim_build <job> <n> <motif> — n'enregistre <n> comme NÔTRE que si le log du
# build PORTE <motif>, un jeton propre à ce run (le nom d'API horodaté, présent
# dans la branche que le webhook transporte). Deux runs concurrents de cette
# matrice ont des PID différents, donc des RUN_TAG différents (cf. la
# construction de RUN_TAG) : l'appartenance est donc DÉMONTRÉE pour deux runs
# CONCURRENTS, pas seulement supposée. Effet de bord voulu : si le créneau de build a été pris par un run
# concurrent, on ne le revendique pas — et on n'ira pas répondre à SA pause
# avec NOS identifiants.
claim_build() {
  local job="$1" n="$2" motif="$3"
  [ -n "$n" ] || return 1
  curl -s "$JENKINS_UI/job/$job/$n/consoleText" 2>/dev/null | grep -qF -- "$motif" || return 1
  is_mine "$n" || MY_BUILDS="${MY_BUILDS:+$MY_BUILDS }$n"
  return 0
}

# abort_pause <job> <n> — abandonne UNE pause. Appelée uniquement pour un build
# de MY_BUILDS (jdrain) ou par le filet de secours du trap.
abort_pause() {
  local job="$1" n="$2" iid
  jcrumb || return 1
  iid=$(curl -s "$JENKINS_UI/job/$job/$n/wfapi/pendingInputActions" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])' 2>/dev/null)
  [ -n "$iid" ] || return 1
  curl -s -b "$JCK" -H "$JF: $JC" -X POST "$JENKINS_UI/job/$job/$n/input/$iid/abort" -o /dev/null
}

# jdrain <job> — libère la file de <job> pour que la preuve suivante puisse
# démarrer. Les jobs de cette chaîne portent DisableConcurrentBuildsJobProperty :
# un build resté en pause bloque tout build suivant, qui reste EN FILE — wfapi
# rend alors un statut VIDE, et l'échec ne ressemble ni à un problème de webhook
# (HTTP 200) ni à un problème de job.
#
# N'ABANDONNE QUE LES PAUSES DE MY_BUILDS — c'est-à-dire celles dont CE run a
# PROUVÉ qu'il les a fait naître. Toute autre pause est LAISSÉE INTACTE, nommée
# (numéro + displayName) sur stderr, et fait rendre un code non nul : la preuve
# appelante échoue alors avec une cause NOMMÉE, au lieu de piétiner
# l'approbation de quelqu'un d'autre puis de s'en attribuer le mérite.
#
# Conséquence assumée : au tout premier appel (avant le merge de la preuve 5),
# MY_BUILDS est VIDE — ce run n'a encore rien déclenché, donc AUCUNE pause en
# cours ne peut lui appartenir. jdrain n'y fait alors qu'une chose : vérifier
# que la file est libre. Une pause laissée par un run ANTÉRIEUR de cette même
# matrice n'est plus nettoyée automatiquement (elle ne serait pas prouvable) :
# elle est signalée, et c'est à son propriétaire — ou à un opérateur — de la
# solder. En contrepartie, ce run ne LAISSE plus d'orpheline derrière lui : le
# trap solde les siennes (cleanup_exit).
jdrain() {
  local job="$1" drained=0 foreign="" info n dn st
  jcrumb || return 0
  for _ in $(seq 1 15); do
    # Les builds NON TERMINÉS de ce job (building=true), avec leur displayName :
    # c'est l'un d'eux qui bloque, pas forcément le dernier numéro.
    info=$(curl -s "$JENKINS_UI/job/$job/api/json?tree=builds%5Bnumber,building,displayName%5D" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for b in d.get('builds',[]):
    if b.get('building'):
        print(str(b['number']) + '\t' + (b.get('displayName') or ''))" 2>/dev/null)
    if [ -z "$info" ]; then
      # plus aucun build en cours ; reste à attendre que la file se vide
      local q
      q=$(curl -s "$JENKINS_UI/queue/api/json" 2>/dev/null | python3 -c "
import json,sys
print(sum(1 for i in json.load(sys.stdin).get('items',[]) if (i.get('task') or {}).get('name')=='$job'))" 2>/dev/null)
      [ "${q:-0}" = 0 ] && break
      sleep 3
      continue
    fi
    while IFS=$'\t' read -r n dn; do
      [ -n "$n" ] || continue
      st=$(jstatus "$job" "$n")
      [ "$st" = PAUSED_PENDING_INPUT ] || continue
      if is_mine "$n"; then
        if abort_pause "$job" "$n"; then
          drained=$((drained + 1))
          echo "   ($job #$n « $dn » : pause déclenchée par CE run (build enregistré comme nôtre) — abandonnée)"
        fi
      else
        foreign="${foreign:+$foreign, }#$n « $dn »"
      fi
    done <<<"$info"
    [ -n "$foreign" ] && break
    sleep 3
  done
  if [ -n "$foreign" ]; then
    echo "   ($job : pause(s) en attente dont CE run ne peut PAS prouver qu'elles sont siennes — LAISSÉE(S) INTACTE(S) : $foreign. Numéros de build de ce run : [${MY_BUILDS:-aucun}]. Lab PARTAGÉ : il peut s'agir de l'approbation 4-yeux d'un run concurrent, ou du résidu d'un run antérieur. La file de ce job reste bloquée tant que son propriétaire (ou un opérateur) ne l'a pas soldée — ce harnais ne la touchera pas.)" >&2
    return 1
  fi
  return 0
}

# answer_pause <job> <build> — répond à la pause nominative par l'API, avec
# l'identité oscar et un mot de passe Vault RE-MINTÉ pour CE run. Le mot de
# passe transite par l'ENVIRONNEMENT d'un heredoc python, JAMAIS par l'argv
# d'un `python3 -c` (ce serait exactement la fuite que la preuve 8 cherche).
answer_pause() {
  local job="$1" n="$2" iid
  iid=$(curl -s "$JENKINS_UI/job/$job/$n/wfapi/pendingInputActions" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])' 2>/dev/null)
  [ -n "$iid" ] || return 1
  OSCAR_VAULT_PASS="$OSCAR_VAULT_PASS" python3 - > "$TMP/input.json" <<'PY'
import json, os
print(json.dumps({'parameter': [
  {'name': 'VAULT_USER', 'value': 'oscar'},
  {'name': 'VAULT_USER_PASSWORD', 'value': os.environ['OSCAR_VAULT_PASS']}]}))
PY
  jcrumb || return 1
  curl -s -b "$JCK" -H "$JF: $JC" -X POST --data-urlencode json@"$TMP/input.json" \
    -o /dev/null -w '%{http_code}' "$JENKINS_UI/job/$job/$n/wfapi/inputSubmit?inputId=$iid"
}

# merge_pr <fichier-en-tête> <repo> <pr> — merge RÉEL, sous l'identité que
# porte le fichier d'en-tête. Gitea calcule `mergeable` de façon ASYNCHRONE
# juste après l'ouverture d'une PR : tenter le merge avant la fin de ce calcul
# rend 405 Method Not Allowed (constaté en direct, sur CE lab, y compris avec
# un token pleinement habilité — ce n'est PAS un refus de droits). On attend le
# feu vert plutôt que de deviner un délai fixe.
merge_pr() {
  local hdr="$1" repo="$2" pr="$3" m dl
  dl=$(( $(date +%s) + 25 ))
  while [ "$(date +%s)" -lt "$dl" ]; do
    m=$(curl -s -H @"$hdr" "$GITEA_URL/api/v1/repos/$repo/pulls/$pr" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("mergeable") or False)' 2>/dev/null)
    [ "$m" = True ] && break
    sleep 1
  done
  curl -s -H @"$hdr" -X POST -H 'Content-Type: application/json' -d '{"Do":"merge"}' \
    -o /dev/null -w '%{http_code}' "$GITEA_URL/api/v1/repos/$repo/pulls/$pr/merge"
}
merge_as_oscar() { merge_pr "$TMP/ohdr" "$1" "$2"; }
merge_as_ci()    { merge_pr "$GHDR"     "$1" "$2"; }

pr_comment_last() { gapi "$GITEA_URL/api/v1/repos/$1/issues/$2/comments" \
  | python3 -c "import json,sys; c=json.load(sys.stdin); print(c[-1]['body'] if c else '')" 2>/dev/null; }
pr_comment_marked() { gapi "$GITEA_URL/api/v1/repos/$1/issues/$2/comments" | MARK="$3" python3 -c "
import json, os, sys
mark = os.environ['MARK']
print(next((c['body'] for c in reversed(json.load(sys.stdin)) if mark in c['body']), ''))" 2>/dev/null; }

# ── teardown : UNE SEULE implémentation, appelée par la preuve 9 (qui en
# VÉRIFIE l'effet) ET par le trap (filet de secours). Armée AVANT tout mint :
# si le script meurt en route, rien ne fuit. Toutes les variables qu'elle
# référence sont déclarées PLUS HAUT, pour que `set -u` ne la casse jamais. ---
CREATED_JOB=0
JOB_EXISTED_AT_ENTRY=0
TEAMWORK_AT_ENTRY=""
SAMPLER_PID=""
TOK_ONBOARDER=""

teardown() {
  # Gitea : dépôts AVANT les orgs (un org non vide ne se supprime pas).
  gapi -X DELETE "$GITEA_URL/api/v1/repos/$TEAM_REPO"  -o /dev/null 2>/dev/null
  gapi -X DELETE "$GITEA_URL/api/v1/repos/$PLAT_REPO"  -o /dev/null 2>/dev/null
  gapi -X DELETE "$GITEA_URL/api/v1/repos/$ORPH_REPO"  -o /dev/null 2>/dev/null
  gapi -X DELETE "$GITEA_URL/api/v1/orgs/$TEAM"        -o /dev/null 2>/dev/null
  gapi -X DELETE "$GITEA_URL/api/v1/orgs/$PLAT_ORG"    -o /dev/null 2>/dev/null
  gapi -X DELETE "$GITEA_URL/api/v1/orgs/$ORPH_ORG"    -o /dev/null 2>/dev/null

  # Vault : ce que l'onboarding de l'équipe jetable a écrit.
  curl -s -H @"$(vhdr "$VROOT")" -X DELETE "$VAULT_ADDR/v1/secret/metadata/stoa/deploy/$TEAM/wm-admin" -o /dev/null 2>/dev/null
  curl -s -H @"$(vhdr "$VROOT")" -X DELETE "$VAULT_ADDR/v1/sys/policies/acl/deploy-$TEAM" -o /dev/null 2>/dev/null

  # Jenkins : le job n'est supprimé que si c'est CE run qui l'a créé — jamais
  # destructeur d'un état antérieur (même discipline que le compte oscar de la
  # matrice du palier 2). Les CONFIGS des deux formulaires sont, elles,
  # toujours remises à l'octet près depuis la baseline capturée à l'entrée :
  # la re-pose événementielle (preuve 7) les a réécrites avec les listes
  # dérivées du dépôt plateforme JETABLE, il ne doit rien en rester.
  if jcrumb; then
    for j in app-request api-request; do
      [ -s "$TMP/baseline-$j.xml" ] && curl -s -b "$JCK" -H "$JF: $JC" \
        -H 'Content-Type: application/xml; charset=utf-8' \
        --data-binary @"$TMP/baseline-$j.xml" -o /dev/null "$JENKINS_UI/job/$j/config.xml"
    done
    if [ "$CREATED_JOB" = 1 ]; then
      curl -s -b "$JCK" -H "$JF: $JC" -X POST "$JENKINS_UI/job/$JOB/doDelete" -o /dev/null
    fi
  fi

  # Gateway : la bascule enableTeamWork est rendue à sa valeur d'ENTRÉE
  # (mesurée au démarrage). Les OBJETS (APIs, applications, policies) ne le
  # sont pas : le mock n'expose AUCUNE route DELETE (405, mesuré) — cf.
  # l'en-tête. La preuve 9 le DIT au lieu de le taire.
  if [ -n "$TEAMWORK_AT_ENTRY" ]; then
    curl -s -u Administrator:manage -X PUT -H 'Content-Type: application/json' \
      -d "{\"enableTeamWork\":\"$TEAMWORK_AT_ENTRY\"}" \
      "$WM_GATEWAY_URL/rest/apigateway/configurations/extended" -o /dev/null 2>/dev/null
  fi
}

cleanup_exit() {
  if [ -n "$SAMPLER_PID" ]; then kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; fi
  # Ce run SOLDE SES PROPRES pauses — et seulement les siennes. C'est la
  # contrepartie de jdrain, qui ne nettoie plus les résidus d'autrui : pour que
  # cette rigueur ne rende pas la matrice non rejouable, il faut que ce run ne
  # LAISSE aucune orpheline derrière lui, y compris s'il meurt en route.
  for _b in ${MY_BUILDS:-}; do
    if [ "$(jstatus "$JOB" "$_b")" = PAUSED_PENDING_INPUT ]; then
      abort_pause "$JOB" "$_b" && echo "   ($JOB #$_b : pause de CE run soldée à la sortie — aucune orpheline laissée derrière)" >&2
    fi
  done
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
  teardown >/dev/null 2>&1
  # Restauration d'une éventuelle mutation de la contre-épreuve rouge
  # (preuve 9) : si le script meurt ENTRE la casse et la restauration, la
  # garde doit revenir malgré tout — un harnais qui laisserait une garde
  # cassée derrière lui serait pire que pas de harnais.
  [ -f "$TMP/api-request.sh.orig" ] && cp "$TMP/api-request.sh.orig" "$REPO_ROOT/scripts/api-request.sh" 2>/dev/null
  # ${TOK_ONBOARDER:-} : le trap est armé AVANT le mint, il peut donc se
  # déclencher avant que la variable ne porte quoi que ce soit.
  [ -n "$TOK_ONBOARDER" ] && curl -s -H @"$(vhdr "$TOK_ONBOARDER")" -X POST "$VAULT_ADDR/v1/auth/token/revoke-self" -o /dev/null 2>/dev/null
  # KEEP_TMP=1 conserve les logs pour diagnostic. Le répertoire porte des
  # fichiers 0600 avec des tokens (needles du sondage ps, en-têtes) : c'est
  # une aide au DÉBOGAGE, jamais le mode nominal — d'où le rappel bruyant.
  if [ "${KEEP_TMP:-0}" = 1 ]; then
    echo "   (KEEP_TMP=1 — logs conservés dans $TMP ; il contient des tokens en clair, à supprimer après lecture)" >&2
  else
    rm -rf "$TMP"
  fi
}
trap cleanup_exit EXIT

# ─────────────────────────────────────────────────────────────────────────────
# PRÉ-VOL — chaque prérequis est VÉRIFIÉ et NOMMÉ. Un prérequis absent arrête
# le harnais (exit 2) plutôt que de produire des verdicts qui parleraient
# d'autre chose.
# ─────────────────────────────────────────────────────────────────────────────
die() { echo "PRÉ-VOL: $*" >&2; exit 2; }

DIRTY=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)
[ -z "$DIRTY" ] || die "checkout SALE — l'arbre publié dans le dépôt plateforme jetable est \`git archive HEAD\` : un fichier modifié non commité ne serait PAS celui que le job exécute, et les verdicts porteraient sur autre chose que ce qu'on lit. Committer (ou remiser) d'abord :
$DIRTY"

[ "$(ghc "$GITEA_URL/api/v1/version")" = 200 ] || die "Gitea injoignable ou token refusé ($GITEA_URL)"
curl -sf "$JENKINS_UI/api/json" >/dev/null 2>&1 || die "Jenkins injoignable ($JENKINS_UI)"
[ "$(vlt "$VROOT" "sys/policies/acl/team-onboarder")" = 200 ] \
  || die "policy Vault 'team-onboarder' absente — jouer scripts/setup-team-onboard-prereqs.sh"

case "$WM_GATEWAY_URL" in
  *:5555*) die "WM_GATEWAY_URL vise le port 5555 — c'est la VRAIE gateway 10.15 du lab, en service. Ce harnais écrit sur sa cible : refus." ;;
esac
[ "$(curl -s -u Administrator:manage -o /dev/null -w '%{http_code}' "$WM_GATEWAY_URL/rest/apigateway/health")" = 200 ] \
  || die "mock injoignable ($WM_GATEWAY_URL)"
# Sonde de FRAÎCHEUR (cf. en-tête) : 401 = image du palier 3 ; 404 = image
# antérieure, sans la sémantique des versions que la preuve 6 exerce.
MOCK_FRESH=$(curl -s -u Administrator:manage -X POST -H 'Content-Type: application/json' \
  -d '{"newApiVersion":"0.0.1"}' -o /dev/null -w '%{http_code}' \
  "$WM_GATEWAY_URL/rest/apigateway/apis/00000000-dead-4000-8000-000000000000/versions")
[ "$MOCK_FRESH" = 401 ] || die "mock PÉRIMÉ : POST /apis/<inconnu>/versions rend $MOCK_FRESH, attendu 401 (comportement mesuré 2026-08-05, reproduit par le mock du palier 3). Reconstruire l'image (docker build -t stoa-labs/webmethods-mock:dev mocks/webmethods/) puis RECRÉER le conteneur — 'docker restart' relance l'ANCIENNE image."

[ "$(ghc "$GITEA_URL/api/v1/users/oscar")" = 200 ] \
  || die "second compte Gitea 'oscar' absent — sans lui, aucun merge par un SECOND humain, donc aucune garde d'identité à discriminer (preuves 5/6)"
OSCAR_POL=$(curl -s -H @"$(vhdr "$VROOT")" "$VAULT_ADDR/v1/auth/userpass/users/oscar" \
  | python3 -c "import json,sys; print(','.join(json.load(sys.stdin).get('data',{}).get('token_policies',[])))" 2>/dev/null)
printf '%s' ",$OSCAR_POL," | grep -qF ',team-onboarder,' \
  || die "oscar (Vault userpass) ne porte pas la policy 'team-onboarder' (policies: ${OSCAR_POL:-aucune}) — l'apply lirait 403 sur le token org-admin. Remède : scripts/setup-team-onboard-prereqs.sh (ATTACHE, ne remplace pas)"

command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook absent du PATH (plan d'api-request, apply du rôle)"
command -v go >/dev/null 2>&1 || die "go absent du PATH (mock standalone de la preuve 0)"

echo "== chaîne PRODUCTEUR (palier 3) — équipe jetable $TEAM, API $API_NAME =="
echo "   Gitea=$GITEA_URL  Vault=$VAULT_ADDR  gateway(mock)=$WM_GATEWAY_URL  Jenkins=$JENKINS_UI"
echo "   dépôt plateforme de substitution (gate Gitea non levé) : $PLAT_REPO"
echo

# ── token ÉPHÉMÈRE mono-policy team-onboarder ───────────────────────────────
# L'onboarding tourne avec LE PÉRIMÈTRE RÉEL de l'apply, jamais avec le root —
# sinon il ne prouverait rien sur ce que team-apply.sh peut faire en vrai.
TOK_ONBOARDER=$(curl -s -H @"$(vhdr "$VROOT")" -X POST \
  -d '{"policies":["team-onboarder"],"ttl":"60m","no_default_policy":true}' \
  "$VAULT_ADDR/v1/auth/token/create" | python3 -c "import json,sys; print(json.load(sys.stdin).get('auth',{}).get('client_token',''))" 2>/dev/null)
[ -n "$TOK_ONBOARDER" ] || die "mint du token éphémère team-onboarder impossible"
VTOK_FILE="$TMP/vtok-onboarder"; printf '%s' "$TOK_ONBOARDER" > "$VTOK_FILE"; chmod 600 "$VTOK_FILE"

# ── état d'entrée : configs Jenkins (restaurées à l'octet près au teardown) et
# bascule enableTeamWork (MESURÉE, pas supposée). --------------------------
for j in app-request api-request; do
  curl -sf "$JENKINS_UI/job/$j/config.xml" -o "$TMP/baseline-$j.xml" 2>/dev/null || : > "$TMP/baseline-$j.xml"
done
curl -sf "$JENKINS_UI/job/$JOB/api/json" >/dev/null 2>&1 && JOB_EXISTED_AT_ENTRY=1
TEAMWORK_AT_ENTRY=$(wmapi configurations/extended | python3 -c "import json,sys; print(json.load(sys.stdin).get('enableTeamWork','false'))" 2>/dev/null)
[ -n "$TEAMWORK_AT_ENTRY" ] || TEAMWORK_AT_ENTRY=false
echo "   état d'entrée : enableTeamWork=$TEAMWORK_AT_ENTRY, job $JOB $([ "$JOB_EXISTED_AT_ENTRY" = 1 ] && echo présent || echo absent)"

# La feature Teams DOIT être active : le rôle exige une équipe
# (apim_pub_require_team=true) et refuse fail-closed sinon (TEAMS_DISABLED —
# constaté en direct sur ce lab, la publication s'arrête avant toute écriture).
# C'est un geste d'ADMIN, assumé ici et RENDU au teardown.
curl -s -u Administrator:manage -X PUT -H 'Content-Type: application/json' \
  -d '{"enableTeamWork":"true"}' "$WM_GATEWAY_URL/rest/apigateway/configurations/extended" -o /dev/null

# ─────────────────────────────────────────────────────────────────────────────
# 0. NON-RÉGRESSION — la matrice du palier 2 + les voies MACHINE (OIG/CLI2)
# ─────────────────────────────────────────────────────────────────────────────
echo "== 0. non-régression : matrice du palier 2 + voies machine (manifeste diff-vide) =="

# mock standalone pour la matrice du palier 2 : PORT DEMANDÉ AU NOYAU (jamais
# un port en dur — le scratchpad est partagé entre agents, les collisions de
# port sont vécues), logs dans NOTRE TMP (unique par run).
MOCK_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
( cd "$REPO_ROOT/mocks/webmethods" && LISTEN_ADDR=":$MOCK_PORT" go run . >"$TMP/mock-p2.log" 2>&1 ) &
MOCK_PID=$!
for _ in $(seq 1 90); do
  curl -sf -u Administrator:manage "http://127.0.0.1:$MOCK_PORT/rest/apigateway/health" >/dev/null 2>&1 && break
  sleep 1
done

# La matrice du palier 2 est invoquée depuis un CLONE, jamais depuis CE
# checkout : team-apply.sh (qu'elle appelle) fait `git checkout $MERGE_SHA` sur
# SON cwd (anti-TOCTOU) — dans ce checkout-ci, cela remplacerait l'arbre du
# palier 3 par celui de ci/stoa-labs@main (72 fichiers d'écart) sous les pieds
# des preuves suivantes. Le clone porte l'arbre du palier 3 (dépôt plateforme
# jetable, publié juste avant) : la matrice s'y exécute donc AVEC le palier 3
# présent — c'est précisément ce que « non-régression » veut dire ici — pendant
# que le code APPLIQUÉ reste, par la conception anti-TOCTOU de team-apply.sh,
# celui de ci/stoa-labs@main.
gapi -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$PLAT_ORG\",\"visibility\":\"public\"}" \
  "$GITEA_URL/api/v1/orgs" -o /dev/null
gapi -X POST -H 'Content-Type: application/json' -d '{"name":"stoa-labs","private":false,"auto_init":false}' \
  "$GITEA_URL/api/v1/orgs/$PLAT_ORG/repos" -o /dev/null
rm -rf "$TMP/plat"; mkdir -p "$TMP/plat"
# DEPUIS LA RACINE DU DÉPÔT, jamais depuis ce sous-répertoire : `git archive
# HEAD` lancé dans un sous-répertoire n'archive QUE ce sous-arbre (mesuré) —
# le dépôt plateforme y perdrait son niveau `poc-control-plane-federation/`,
# celui-là même que le job ouvre (`dir('poc-control-plane-federation')`) et où
# vivent les scripts. Le clone se retrouvait sans ce répertoire, et TOUT ce qui
# s'invoque depuis lui échouait sur un `cd` — sans que le message ne parle
# jamais de l'archive.
GIT_TOPLEVEL=$(git -C "$REPO_ROOT" rev-parse --show-toplevel)
git -C "$GIT_TOPLEVEL" archive HEAD | tar -x -C "$TMP/plat" 2>/dev/null
( cd "$TMP/plat" && git init -q -b main . \
  && git add -A \
  && git -c user.name=ci -c user.email=ci@stoa.lab commit -qm "seed: arbre du palier 3 sous test (matrice producteur)" ) >/dev/null 2>&1
PLAT_AUTH=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic ${PLAT_AUTH}" \
  GIT_CONFIG_KEY_1=http.postBuffer GIT_CONFIG_VALUE_1=524288000 \
  git -C "$TMP/plat" push -q "$GITEA_URL/$PLAT_REPO.git" main 2>"$TMP/platpush.err"
PLAT_PUSH_RC=$?
unset PLAT_AUTH
[ "$PLAT_PUSH_RC" -eq 0 ] || die "publication de l'arbre sous test dans $PLAT_REPO en échec — $(tail -2 "$TMP/platpush.err")"
# DEUX clones DISTINCTS, et c'est nécessaire : la matrice du palier 2 MUTE le
# sien (sa preuve 10 y restaure ci/jenkins/team-apply.job.xml depuis sa propre
# baseline, et ses preuves 5/6 y déplacent HEAD). Le `git checkout $MERGE_SHA`
# de team-apply.sh, plus bas, REFUSE alors de tourner : « Your local changes
# would be overwritten by checkout » — un échec du PRÉ-REQUIS de la chaîne
# producteur, causé par une preuve DÉJÀ passée. Constaté en direct.
git clone -q --depth 1 -b main "$GITEA_URL/$PLAT_REPO.git" "$TMP/p2src" || die "clone de $PLAT_REPO (matrice du palier 2)"

( cd "$TMP/p2src/poc-control-plane-federation" && GITEA_URL="$GITEA_URL" GITEA_TOKEN="$GITEA_TOKEN" \
    VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VROOT" \
    WM_GATEWAY_URL="http://127.0.0.1:$MOCK_PORT" JENKINS_UI="$JENKINS_UI" \
    bash scripts/test-team-onboarding-chain.sh ) >"$TMP/p0-palier2.log" 2>&1
R0A=$?
V0A=$(grep -oE '[0-9]+ PASS / [0-9]+ FAIL' "$TMP/p0-palier2.log" | tail -1)
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""

bash scripts/test-app-request-v2.sh >"$TMP/p0-machine.log" 2>&1
R0B=$?
V0B=$(grep -oE '[0-9]+ OK / [0-9]+ KO' "$TMP/p0-machine.log" | tail -1)
GOLD=$(grep -c 'manifeste identique au golden' "$TMP/p0-machine.log")

# TOTAUX ÉPINGLÉS, pas seulement l'absence d'échec (fix round 1, Minor 1).
# Les deux sous-harnais finissent par `[ "$FAIL" -eq 0 ]` : leur code de retour
# capte les ÉCHECS, jamais le PÉRIMÈTRE. Une future édition qui SUPPRIMERAIT
# une preuve de la matrice du palier 2 (sans jamais appeler bad()) laisserait
# cette preuve-ci VERTE en affichant « 10 PASS » au lieu de 11 — or le brief
# exige la matrice EN ENTIER, pas un sous-ensemble. Les totaux sont donc écrits
# EN DUR ici : s'ils évoluent légitimement (preuve ajoutée), ce rouge force à
# le CONSTATER et à mettre à jour la constante, plutôt qu'à laisser un
# rétrécissement passer inaperçu. Même intention que le compteur en dur de
# test-team-publish-wiring.sh.
P2_TOTAL_ATTENDU="11 PASS / 0 FAIL"
MACHINE_TOTAL_ATTENDU="18 OK / 0 KO"
if [ "$R0A" -eq 0 ] && [ "$R0B" -eq 0 ] && [ "${GOLD:-0}" -eq 2 ] \
   && [ "$V0A" = "$P2_TOTAL_ATTENDU" ] && [ "$V0B" = "$MACHINE_TOTAL_ATTENDU" ]; then
  ok "0. non-régression : matrice du palier 2 = $V0A (périmètre ATTENDU, épinglé) ; voies machine OIG/CLI2 = $V0B dont $GOLD manifestes IDENTIQUES à leur golden (diff vide)"
else
  bad "0. palier2_rc=$R0A ($V0A, attendu '$P2_TOTAL_ATTENDU') machine_rc=$R0B ($V0B, attendu '$MACHINE_TOTAL_ATTENDU') goldens_diff_vides=${GOLD:-0}/2 — un total INFÉRIEUR à l'attendu signale une preuve DISPARUE, pas un échec : le rc des sous-harnais ne le voit pas. Voir $TMP/p0-palier2.log et $TMP/p0-machine.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PRÉ-REQUIS DES PREUVES 1-9 : onboarder l'équipe jetable (chaîne du palier 2,
# jouée ici sur le dépôt plateforme JETABLE). Ce n'est pas une preuve — c'est
# ce que la chaîne PRODUCTEUR consomme : un dépôt d'équipe, son webhook
# team-publish, son entrée dans providers.<env>.yml.
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== (pré-requis) onboarding de l'équipe jetable $TEAM sur $PLAT_REPO =="
# Clone NEUF (cf. le commentaire des deux clones, preuve 0) : team-apply.sh y
# fera un `git checkout $MERGE_SHA`, qui exige un arbre propre.
git clone -q -b main "$GITEA_URL/$PLAT_REPO.git" "$TMP/src" || die "clone de $PLAT_REPO (chaîne producteur)"
SRC="$TMP/src/poc-control-plane-federation"
( cd "$SRC" && TEAM="$TEAM" DESCRIPTION="equipe jetable de la matrice producteur (P3-T8)" REQ_ENV="$ENVN" \
    GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" GIT_REPO="$PLAT_REPO" \
    bash scripts/team-request.sh ) >"$TMP/onb-req.log" 2>&1
RONB=$?
PR_ONB=$(grep -oE 'PR #[0-9]+ ouverte' "$TMP/onb-req.log" | grep -oE '[0-9]+' | head -1)
# ÉCART DÉCLARÉ, repris du palier 2 (sa preuve 5) : CE merge-ci est fait par
# `ci` lui-même. L'identité qui merge n'est pas ce que ce pré-requis prouve —
# les preuves 5 et 6, elles, mergent RÉELLEMENT par oscar, et c'est là que la
# garde d'identité a un cas à discriminer.
MERGE_ONB=$(merge_as_ci "$PLAT_REPO" "${PR_ONB:-0}")
SHA_ONB=$(gapi "$GITEA_URL/api/v1/repos/$PLAT_REPO/pulls/${PR_ONB:-0}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('merge_commit_sha') or '')" 2>/dev/null)
git -C "$TMP/src" fetch -q "$GITEA_URL/$PLAT_REPO.git" main 2>/dev/null
( cd "$SRC" && PR_BRANCH="onboard/${TEAM}-${ENVN}" PR_NUMBER="${PR_ONB:-0}" MERGE_SHA="$SHA_ONB" \
    GITEA_TOKEN="$GITEA_TOKEN" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VTOK_FILE" \
    APIM_API_BASE="$WM_GATEWAY_URL/rest/apigateway" \
    GIT_HOST="$GITEA_URL" GIT_REPO="$PLAT_REPO" GIT_WEB_HOST="$GITEA_URL" JENKINS_UI="$JENKINS_UI" \
    bash scripts/team-apply.sh ) >"$TMP/onb-apply.log" 2>&1
RAPP=$?
HOOK_OK=$(gapi "$GITEA_URL/api/v1/repos/$TEAM_REPO/hooks" | python3 -c "
import json,sys
try: h=json.load(sys.stdin)
except Exception: h=[]
print(sum(1 for x in h if 'stoa-team-publish' in ((x.get('config') or {}).get('url') or '')))" 2>/dev/null)
[ "$RONB" -eq 0 ] && [ "$MERGE_ONB" = 200 ] && [ "$RAPP" -eq 0 ] && [ "${HOOK_OK:-0}" -ge 1 ] \
  || die "onboarding de l'équipe jetable en échec (req=$RONB merge=$MERGE_ONB apply=$RAPP hooks=${HOOK_OK:-0}) — voir $TMP/onb-*.log ; les preuves 1-9 n'auraient rien à exercer"
echo "   $TEAM_REPO créé, webhook team-publish enregistré (${HOOK_OK}), listes re-posées"

# Les LISTES juste après l'onboarding — capturées ICI, jugées en preuve 7.
CFG_TEAM_AFTER_ONB=$(curl -sf "$JENKINS_UI/job/api-request/api/json?depth=1" | python3 -c "
import json,sys
for p in json.load(sys.stdin).get('property',[]):
    for q in p.get('parameterDefinitions',[]):
        if q.get('name')=='TEAM': print(','.join(q.get('choices') or []))" 2>/dev/null)

# oscar : collaborateur ADMIN du dépôt d'ÉQUIPE (sans quoi son merge rend 405)
# et token Gitea ÉPHÉMÈRE minté pour CE run.
gapi -X PUT -H 'Content-Type: application/json' -d '{"permission":"admin"}' \
  "$GITEA_URL/api/v1/repos/$TEAM_REPO/collaborators/oscar" -o /dev/null
OSCAR_TOK=$(docker exec -u git "${GITEA_CONTAINER:-poc-gitea}" gitea admin user generate-access-token \
  --username oscar --token-name "p3t8-$$-$(date +%s)" --scopes write:repository,write:issue 2>/dev/null \
  | grep -oE '[0-9a-f]{40}')
[ -n "$OSCAR_TOK" ] || die "mint du token Gitea d'oscar impossible (docker exec sur ${GITEA_CONTAINER:-poc-gitea})"
printf 'Authorization: token %s\n' "$OSCAR_TOK" > "$TMP/ohdr"; chmod 600 "$TMP/ohdr"
# Mot de passe VAULT d'oscar : ÉPHÉMÈRE, re-minté à CHAQUE run par l'endpoint
# DÉDIÉ .../password — jamais le POST plein, qui REMPLACERAIT token_policies.
# Un GET avant/après vérifie que les policies existantes tiennent.
OSCAR_VAULT_PASS=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))")
printf '{"password":"%s"}' "$OSCAR_VAULT_PASS" > "$TMP/oscar-pw.json"
OSCAR_PASS_FILE="$TMP/oscar-pass"; printf '%s' "$OSCAR_VAULT_PASS" > "$OSCAR_PASS_FILE"; chmod 600 "$OSCAR_PASS_FILE"
RC_SETPW=$(curl -s -H @"$(vhdr "$VROOT")" -X POST --data-binary @"$TMP/oscar-pw.json" \
  "$VAULT_ADDR/v1/auth/userpass/users/oscar/password" -o /dev/null -w '%{http_code}')
OSCAR_POL_AFTER=$(curl -s -H @"$(vhdr "$VROOT")" "$VAULT_ADDR/v1/auth/userpass/users/oscar" \
  | python3 -c "import json,sys; print(','.join(json.load(sys.stdin).get('data',{}).get('token_policies',[])))" 2>/dev/null)
{ [ "$RC_SETPW" = 204 ] || [ "$RC_SETPW" = 200 ]; } && [ "$OSCAR_POL" = "$OSCAR_POL_AFTER" ] \
  || die "mot de passe éphémère d'oscar : HTTP $RC_SETPW, policies '$OSCAR_POL' -> '$OSCAR_POL_AFTER' (elles doivent être INCHANGÉES)"

# ── pose du job team-publish depuis son XML LIVRÉ, deux substitutions (cf.
# l'écart du gate, en tête). ------------------------------------------------
PLAT_ORG="$PLAT_ORG" PLAT_REPO="$PLAT_REPO" GIT_HOST_INTERNAL="$GIT_HOST_INTERNAL" python3 - \
  "$REPO_ROOT/ci/jenkins/$JOB.job.xml" "$TMP/$JOB.job.xml" <<'PY' || die "réécriture du XML du job"
import os, sys
src, dst = sys.argv[1], sys.argv[2]
x = open(src, encoding="utf-8").read()
old = "http://gitea:3000/ci/stoa-labs.git"
new = f"{os.environ['GIT_HOST_INTERNAL']}/{os.environ['PLAT_REPO']}.git"
n = x.count(old)
if n != 2:
    sys.exit(f"attendu 2 occurrences de '{old}' dans le XML du job, trouvé {n} — le XML a changé, revoir la substitution")
x = x.replace(old, new)
# MÊME rigueur fail-closed que la substitution ci-dessus (fix round 1, item 4) :
# on EXIGE un compte EXACT, on ne se contente pas de la présence du marqueur
# suivie d'un replace(..., 1). Une ancre qui se mettrait à apparaître DEUX fois
# (un second export ajouté au job) rendrait le `1` silencieusement arbitraire :
# la substitution s'appliquerait à la première occurrence rencontrée, pas
# forcément la bonne, et rien ne le dirait.
marker = "export APIM_API_BASE="
m = x.count(marker)
if m != 1:
    sys.exit(f"attendu 1 occurrence de l'ancre '{marker}' dans le XML du job, trouvé {m} — le XML a changé, revoir la substitution")
x = x.replace(marker, f'export GIT_REPO="{os.environ["PLAT_REPO"]}"\n              ' + marker, 1)
open(dst, "w", encoding="utf-8").write(x)
PY
jcrumb || die "crumb Jenkins indisponible"
if [ "$JOB_EXISTED_AT_ENTRY" = 1 ]; then
  HCJOB=$(curl -s -b "$JCK" -H "$JF: $JC" -H 'Content-Type: application/xml; charset=utf-8' \
    --data-binary @"$TMP/$JOB.job.xml" -o /dev/null -w '%{http_code}' "$JENKINS_UI/job/$JOB/config.xml")
else
  HCJOB=$(curl -s -b "$JCK" -H "$JF: $JC" -H 'Content-Type: application/xml; charset=utf-8' \
    --data-binary @"$TMP/$JOB.job.xml" -o /dev/null -w '%{http_code}' "$JENKINS_UI/createItem?name=$JOB")
  [ "$HCJOB" = 200 ] && CREATED_JOB=1
fi
[ "$HCJOB" = 200 ] || die "pose du job $JOB en échec (HTTP $HCJOB)"
echo "   job $JOB posé (HTTP $HCJOB), checkout -> $PLAT_REPO"

# ── TÉMOIN DU DÉPÔT PLATEFORME RÉEL (fix round 1, item 3) ───────────────────
# L'en-tête de ce fichier AFFIRME que `ci/stoa-labs` n'est jamais touché par
# les preuves 1 à 9. Une affirmation qui ne peut pas ROUGIR n'est pas une
# preuve : si une régression future faisait fuiter un accès en écriture vers ce
# dépôt (un GIT_REPO oublié, un défaut qui reprend le dessus), rien ici ne
# l'aurait signalé. On capture donc la LISTE COMPLÈTE de ses heads (SHA ET
# noms de branches, pas seulement leur nombre — un rename ou un échange de deux
# branches laisserait le compte inchangé) et on la RELIT en preuve 9.
#
# PLACEMENT : ICI, c'est-à-dire APRÈS la preuve 0 et AVANT la preuve 1. La
# preuve 0 travaille RÉELLEMENT sur ci/stoa-labs — c'est le contrat de la
# matrice du palier 2, dont le job team-apply code ce dépôt en dur — et elle y
# revient par son propre teardown (revert bit-à-bit de providers.<env>.yml).
# La fenêtre surveillée est donc exactement celle que l'affirmation couvre :
# les preuves 1 à 9, jamais la 0.
CI_HEADS_BEFORE=$(git ls-remote --heads "$GITEA_URL/ci/stoa-labs.git" 2>/dev/null)
[ -n "$CI_HEADS_BEFORE" ] || die "témoin ci/stoa-labs vide (ls-remote sans réponse) — sans point de comparaison, la preuve 9 ne pourrait rien affirmer sur l'intégrité du dépôt plateforme réel"

# ─────────────────────────────────────────────────────────────────────────────
# 1. gardes d'entrée d'api-request.sh — CHAQUE refus sans la moindre trace
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 1. gardes d'api-request : chaque refus SANS trace sur $TEAM_REPO =="

# sondage ps -Aww continu — ouvert ICI, fermé après la preuve 6 : il couvre
# TOUT le trafic git/curl des preuves 1, 2, 5 et 6 (clones, push, PR, merges).
PSLOG="$TMP/pslog"; : > "$PSLOG"
( while :; do ps -Aww >>"$PSLOG" 2>/dev/null; sleep 0.02; done ) & SAMPLER_PID=$!

SPEC_OK='openapi: 3.0.0
info:
  title: t8api
  version: 1.0.0
paths:
  /ping:
    get:
      responses:
        "200":
          description: ok
'
BEFORE1=$(git ls-remote "$GITEA_URL/$TEAM_REPO.git" 2>/dev/null)

# Chaque cas : un TAG attendu, et l'assurance que le refus tombe. Les valeurs
# hors classe (\n) sont testées EN PREMIER (leçon \Z du palier 1 : le refus de
# CLASSE précède la garde de fond).
G_TAGS=""; G_FAILED=""
guard_case() {
  local label="$1" tag="$2"; shift 2
  local out rc
  out=$(env GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" \
        GIT_REPO="$PLAT_REPO" ENVN="$ENVN" "$@" bash scripts/api-request.sh 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "$tag"; then
    G_TAGS="${G_TAGS:+$G_TAGS }$tag"
  else
    G_FAILED="${G_FAILED:+$G_FAILED; }$label(rc=$rc, attendu $tag, obtenu: $(printf '%s' "$out" | tail -1 | cut -c1-90))"
  fi
}
guard_case "ACTION inconnue"        ACTION_INVALIDE            ACTION=publish TEAM="$TEAM" API_NAME=g1 API_VERSION=1.0.0 OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=jwt
guard_case "TEAM avec newline"      TEAM_NAME_INVALID          ACTION=create TEAM=$'a\nb' API_NAME=g2 API_VERSION=1.0.0 OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=jwt
guard_case "API_NAME hors classe"   API_NAME_INVALID           ACTION=create TEAM="$TEAM" API_NAME='../evil' API_VERSION=1.0.0 OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=jwt
guard_case "oauth2 refusé"          INBOUND_OAUTH2_NON_SUPPORTE ACTION=create TEAM="$TEAM" API_NAME=g3 API_VERSION=1.0.0 OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=oauth2
guard_case "version mal formée"     API_VERSION_INVALIDE       ACTION=create TEAM="$TEAM" API_NAME=g4 API_VERSION=v1 OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=jwt
guard_case "spec non parseable"     SPEC_INVALIDE              ACTION=create TEAM="$TEAM" API_NAME=g5 API_VERSION=1.0.0 OPENAPI_SPEC='ceci: [n est pas: du yaml' INBOUND_MODE=jwt
guard_case "spec sans openapi/swagger" SPEC_INVALIDE           ACTION=create TEAM="$TEAM" API_NAME=g6 API_VERSION=1.0.0 OPENAPI_SPEC='titre: contrat sans openapi' INBOUND_MODE=jwt
guard_case "équipe non déclarée"    TEAM_NOT_DECLARED          ACTION=create TEAM=equipe-fantome API_NAME=g7 API_VERSION=1.0.0 OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=jwt
guard_case "API_BASE mal formée"    API_BASE_FORMAT_INVALIDE   ACTION=new-version TEAM="$TEAM" API_NAME=g8 API_BASE='sans-arobase' NEW_VERSION=2.0.0 OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=jwt
guard_case "nouvelle version = base" NEW_VERSION_IDENTIQUE     ACTION=new-version TEAM="$TEAM" API_NAME=g9 API_BASE='g9@1.0.0' NEW_VERSION=1.0.0 OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=jwt

AFTER1=$(git ls-remote "$GITEA_URL/$TEAM_REPO.git" 2>/dev/null)
NB_GUARDS=$(printf '%s\n' $G_TAGS | grep -c . )
if [ -z "$G_FAILED" ] && [ "$BEFORE1" = "$AFTER1" ] && [ "$NB_GUARDS" -eq 10 ]; then
  ok "1. 10 refus nommés ($G_TAGS), ls-remote de $TEAM_REPO IDENTIQUE avant/après — aucune branche, aucun objet"
else
  bad "1. refus_ok=$NB_GUARDS/10 ls-remote_identique=$([ "$BEFORE1" = "$AFTER1" ] && echo oui || echo NON) — ${G_FAILED:-(aucun cas en échec)}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. nominal `create` — PR sur le dépôt d'ÉQUIPE, spec + manifeste, plan ✅
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 2. nominal create : PR sur $TEAM_REPO avec spec + manifeste, plan ✅ =="
ACTION=create TEAM="$TEAM" API_NAME="$API_NAME" API_VERSION=1.0.0 \
  OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=jwt \
  GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" \
  GIT_REPO="$PLAT_REPO" ENVN="$ENVN" \
  bash scripts/api-request.sh >"$TMP/p2.log" 2>&1
R2=$?
PR_V1=$(grep -oE 'PR #[0-9]+ ouverte' "$TMP/p2.log" | grep -oE '[0-9]+' | head -1)
BR_V1="api/${API_NAME}-1.0.0"
# Les fichiers que la PR AJOUTE, pas le contenu du répertoire : le squelette
# ADR-076 posé à l'onboarding porte déjà ses propres apis/*.yml (constaté :
# accounts-read.publish.yml et accounts-read.promote.yml). Exiger un contenu
# de répertoire EXACT confondrait « ce que la demande apporte » avec « ce que
# le dépôt contenait déjà » — ce qu'on veut prouver, c'est que la demande
# apporte EXACTEMENT le manifeste et son contrat, ni plus ni moins.
FILES2=$(gapi "$GITEA_URL/api/v1/repos/$TEAM_REPO/pulls/${PR_V1:-0}/files" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(','.join(sorted(f['filename'] for f in d)) if isinstance(d,list) else '')" 2>/dev/null)
CB2=$(pr_comment_last "$TEAM_REPO" "${PR_V1:-0}")
if [ "$R2" -eq 0 ] && [ -n "${PR_V1:-}" ] \
   && [ "$FILES2" = "apis/${API_NAME}.openapi.yaml,apis/${API_NAME}.publish.yml" ] \
   && printf '%s' "$CB2" | grep -q 'PLAN OK' \
   && printf '%s' "$CB2" | grep -q 'MANIFEST_KEYS_OK' \
   && printf '%s' "$CB2" | grep -q "TEAM_REQUESTED"; then
  ok "2. PR #$PR_V1 sur $TEAM_REPO (branche $BR_V1) AJOUTE exactement [$FILES2], commentaire ✅ PLAN OK avec la hiérarchie de diagnostic (MANIFEST_KEYS_OK + TEAM_REQUESTED)"
else
  bad "2. rc=$R2 PR=${PR_V1:-absente} fichiers=[${FILES2:-aucun}] commentaire=$(printf '%s' "$CB2" | head -c 160) — voir $TMP/p2.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. REPO_NON_DECLARE — un dépôt d'équipe RÉEL, absent de providers.<env>.yml
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 3. REPO_NON_DECLARE : $ORPH_REPO déclenche team-publish -> refus, PR commentée =="
gapi -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$ORPH_ORG\",\"visibility\":\"public\"}" \
  "$GITEA_URL/api/v1/orgs" -o /dev/null
gapi -X POST -H 'Content-Type: application/json' \
  -d '{"name":"orphan-api","private":false,"auto_init":true,"default_branch":"main"}' \
  "$GITEA_URL/api/v1/orgs/$ORPH_ORG/repos" -o /dev/null
# `auto_init` est ASYNCHRONE côté Gitea : cloner tout de suite peut rendre un
# dépôt encore VIDE. La branche poussée juste après serait alors ORPHELINE (sans
# ancêtre commun avec main), la PR jamais `mergeable`, et le merge rendrait 405
# — un échec de mise en scène qui ressemble trait pour trait à un échec de la
# garde qu'on veut prouver. Observé en direct (preuve 3 rouge sur un run, verte
# sur les trois précédents : la définition même d'un flake). On attend donc que
# `main` EXISTE réellement avant de cloner.
ORPH_READY=0
for _ in $(seq 1 30); do
  if [ "$(ghc "$GITEA_URL/api/v1/repos/$ORPH_REPO/branches/main")" = 200 ]; then ORPH_READY=1; break; fi
  sleep 1
done
[ "$ORPH_READY" = 1 ] || echo "   ATTENTION : $ORPH_REPO n'a pas de branche main après 30 s — la preuve 3 va probablement échouer sur sa mise en scène, pas sur sa garde" >&2
rm -rf "$TMP/orph"
git clone -q "$GITEA_URL/$ORPH_REPO.git" "$TMP/orph" 2>/dev/null
mkdir -p "$TMP/orph/apis"
printf 'apim_api:\n  name: orphan\n  version: 1.0.0\n' > "$TMP/orph/apis/orphan.publish.yml"
printf 'openapi: 3.0.0\ninfo:\n  title: orphan\n  version: 1.0.0\npaths: {}\n' > "$TMP/orph/apis/orphan.openapi.yaml"
( cd "$TMP/orph" && git checkout -q -b api/orphan-1.0.0 && git add -A \
  && git -c user.name=ci -c user.email=ci@stoa.lab commit -qm "api(orphan): dépôt volontairement NON déclaré (preuve 3)" ) >/dev/null 2>&1
ORPH_AUTH=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic ${ORPH_AUTH}" \
  git -C "$TMP/orph" push -q "$GITEA_URL/$ORPH_REPO.git" api/orphan-1.0.0 2>/dev/null
unset ORPH_AUTH
PR_ORPH=$(gapi -X POST -H 'Content-Type: application/json' \
  -d '{"base":"main","head":"api/orphan-1.0.0","title":"api(orphan): dépôt non déclaré","body":"preuve 3"}' \
  "$GITEA_URL/api/v1/repos/$ORPH_REPO/pulls" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)
M3HC=""; SHA_ORPH=""
if [ -n "${PR_ORPH:-}" ]; then
  M3HC=$(merge_as_ci "$ORPH_REPO" "$PR_ORPH")
  SHA_ORPH=$(gapi "$GITEA_URL/api/v1/repos/$ORPH_REPO/pulls/$PR_ORPH" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('merge_commit_sha') or '')" 2>/dev/null)
fi
# team-publish.sh EN DIRECT ici (et non par le job) : le refus se joue au §3 du
# script, APRÈS la réconciliation Gitea et AVANT tout apply — le CÂBLAGE du
# déclenchement, lui, est prouvé par la preuve 4 (statique) et par les preuves
# 5/6 (webhook Gitea RÉEL, deux fois). Le faire passer par la pause du job
# n'ajouterait qu'un aller-retour d'input sans rien prouver de plus sur CETTE
# garde-ci.
WEBHOOK_REPO="$ORPH_REPO" PR_BRANCH="api/orphan-1.0.0" PR_NUMBER="${PR_ORPH:-0}" MERGE_SHA="$SHA_ORPH" \
  GITEA_TOKEN="$GITEA_TOKEN" VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VTOK_FILE" \
  APIM_API_BASE="$WM_GATEWAY_URL/rest/apigateway" \
  GIT_HOST="$GITEA_URL" GIT_REPO="$PLAT_REPO" GIT_WEB_HOST="$GITEA_URL" ENVN="$ENVN" \
  bash scripts/team-publish.sh >"$TMP/p3.log" 2>&1
R3=$?
CB3=$(pr_comment_marked "$ORPH_REPO" "${PR_ORPH:-0}" '<!-- team-publish -->')
APIS3=$(wmapi apis | python3 -c "
import json,sys
print(sum(1 for a in json.load(sys.stdin).get('apiResponse',[]) if a['api']['apiName']=='orphan'))" 2>/dev/null)
if [ "$R3" -ne 0 ] && [ "$M3HC" = 200 ] && grep -q REPO_NON_DECLARE "$TMP/p3.log" \
   && printf '%s' "$CB3" | grep -q '❌' && printf '%s' "$CB3" | grep -q REPO_NON_DECLARE \
   && [ "${APIS3:-1}" = 0 ]; then
  ok "3. $ORPH_REPO (PR #$PR_ORPH réellement mergée) refusé REPO_NON_DECLARE, rc=$R3, PR commentée ❌ avec la cause NOMMÉE, 0 API 'orphan' sur la gateway"
else
  bad "3. rc=$R3 merge=$M3HC$([ "$M3HC" != 200 ] && echo " (mise en scène : main du dépôt orphelin prêt=$ORPH_READY — un merge 405 signale une PR jamais mergeable, donc un échec de MISE EN SCÈNE, pas de la garde)") commentaire=$(printf '%s' "$CB3" | head -c 120) apis_orphan=${APIS3:-?} — voir $TMP/p3.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. câblage du job + garde d'identité (contre-épreuve directe rouge/verte)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 4. câblage (test-team-publish-wiring.sh) + garde d'identité rouge/verte =="
bash scripts/test-team-publish-wiring.sh >"$TMP/p4wiring.log" 2>&1
R4W=$?
W4=$(grep -oE 'RÉSULTAT : [0-9]+/[0-9]+' "$TMP/p4wiring.log" | tail -1)
sh scripts/lib/assert-merge-identity.sh --merged-by ci --requester x --vault-user oscar >"$TMP/p4red.log" 2>&1
R4RED=$?
sh scripts/lib/assert-merge-identity.sh --merged-by oscar --requester ci --vault-user oscar >"$TMP/p4green.log" 2>&1
R4GREEN=$?
if [ "$R4W" -eq 0 ] && [ "$R4RED" -ne 0 ] && grep -q MERGER_MISMATCH "$TMP/p4red.log" \
   && [ "$R4GREEN" -eq 0 ] && grep -q MERGE_IDENTITY_OK "$TMP/p4green.log"; then
  ok "4. câblage $W4, garde ROUGE=MERGER_MISMATCH (merged-by ci / vault-user oscar), garde VERTE=MERGE_IDENTITY_OK (merged-by oscar / demandeur ci)"
else
  bad "4. wiring_rc=$R4W ($W4) rouge_rc=$R4RED verte_rc=$R4GREEN — voir $TMP/p4*.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. merge RÉEL par oscar -> webhook GITEA RÉEL -> job team-publish E2E
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 5. merge réel (oscar) -> webhook Gitea -> job $JOB -> pause -> apply =="
# Au premier appel, MY_BUILDS est vide : jdrain ne fait donc que VÉRIFIER que
# la file est libre, et refuse de toucher une pause qu'il ne peut pas prouver
# sienne (DRAIN5 le dit, et le diagnostic de la preuve le relaie).
DRAIN5=0; jdrain "$JOB" || DRAIN5=1
N5=$(jnext "$JOB")
MERGE5=$(merge_as_oscar "$TEAM_REPO" "${PR_V1:-0}")
MERGED_BY5=$(gapi "$GITEA_URL/api/v1/repos/$TEAM_REPO/pulls/${PR_V1:-0}" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('merged_by') or {}).get('login',''))" 2>/dev/null)
ST5=$(jwait "$JOB" "${N5:-0}" 120)
SUB5=""; ST5B=""; OWN5=non
# On ne répond à une pause QU'APRÈS avoir prouvé qu'elle est la nôtre : son log
# doit porter la branche de CE run (nom d'API horodaté). Sans cette preuve, le
# créneau de build a pu être pris par un run concurrent — y injecter NOS
# identifiants nominatifs serait répondre à l'approbation d'autrui.
if [ "$ST5" = PAUSED_PENDING_INPUT ] && claim_build "$JOB" "$N5" "api/${API_NAME}-1.0.0"; then
  OWN5=oui
  SUB5=$(answer_pause "$JOB" "$N5")
  ST5B=$(jwait_end "$JOB" "$N5" 300)
fi
curl -s "$JENKINS_UI/job/$JOB/$N5/consoleText" > "$TMP/build5.log" 2>/dev/null
# -Ff sur un FICHIER 0600, jamais -F "$VAR" : un grep -F "$PASS" mettrait le
# mot de passe dans l'argv DE CE GREP — la vérification anti-fuite ne doit pas
# être elle-même la fuite qu'elle cherche.
LEAK5=$(grep -cFf "$OSCAR_PASS_FILE" "$TMP/build5.log" 2>/dev/null || true)
API_V1=$(wmapi apis | python3 -c "
import json,sys
print(next((a['api']['id'] for a in json.load(sys.stdin).get('apiResponse',[])
            if a['api']['apiName']=='$API_NAME' and a['api']['apiVersion']=='1.0.0'), ''))" 2>/dev/null)
CB5=$(pr_comment_marked "$TEAM_REPO" "${PR_V1:-0}" '<!-- team-publish -->')
if [ "$MERGE5" = 200 ] && [ "$MERGED_BY5" = oscar ] && [ "$ST5" = PAUSED_PENDING_INPUT ] \
   && [ "$SUB5" = 200 ] && [ "$ST5B" = SUCCESS ] \
   && grep -q MERGE_IDENTITY_OK "$TMP/build5.log" \
   && [ "${LEAK5:-1}" = 0 ] && [ -n "$API_V1" ] \
   && printf '%s' "$CB5" | grep -q '✅' && printf '%s' "$CB5" | grep -q "$API_NAME@1.0.0"; then
  ok "5. merge par oscar (HTTP $MERGE5) -> webhook Gitea -> build #$N5 en pause -> réponse API ($SUB5) -> MERGE_IDENTITY_OK -> $ST5B ; API $API_NAME@1.0.0 sur la gateway (id $API_V1), PR commentée ✅, mot de passe jamais loggé (0 occurrence)"
else
  bad "5. merge=$MERGE5 par='${MERGED_BY5:-?}' pause=$ST5 build_prouvé_nôtre=$OWN5 submit=$SUB5 fin=$ST5B api_id=${API_V1:-absente} fuite_mdp=${LEAK5:-?}$([ "$DRAIN5" = 1 ] && echo ' — CAUSE PROBABLE : une pause ÉTRANGÈRE bloque la file de ce job (laissée intacte à dessein, cf. le message ci-dessus)') — voir $JENKINS_UI/job/$JOB/${N5:-?}/console"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. NOUVELLE VERSION — le piège multi-version, souscriptions relues
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 6. nouvelle version v2 : policies clonées (M2), souscriptions transportées (M3) =="
# Un témoin d'abonnement est INDISPENSABLE : sans application souscrite à la
# base, le rôle rend VERSION_SUBS_VACANT et le transport reste NON PROUVÉ (son
# propre message le dit). On en pose donc un, et on relit les souscriptions
# AVANT et APRÈS le mint — la mesure M3 du spike T1 dit que sans
# `retainApplications: true` (booléen, casse EXACTE) elles sont perdues EN
# SILENCE, HTTP 201 dans tous les cas.
APPID=$(curl -s -u Administrator:manage -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"$WITNESS_APP\",\"description\":\"temoin des souscriptions (preuve 6)\"}" \
  "$WM_GATEWAY_URL/rest/apigateway/applications" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
curl -s -u Administrator:manage -X PUT -H 'Content-Type: application/json' \
  -d "{\"apiIDs\":[\"$API_V1\"]}" "$WM_GATEWAY_URL/rest/apigateway/applications/$APPID/apis" -o /dev/null
subs_of() { wmapi applications | API="$1" python3 -c "
import json, os, sys
api = os.environ['API']
print(','.join(sorted(a['id'] for a in json.load(sys.stdin).get('applications',[])
                      if api in (a.get('consumingAPIs') or []))))" 2>/dev/null; }
SUBS_V1_BEFORE=$(subs_of "$API_V1")

SPEC_V2=$(printf '%s\n' "$SPEC_OK" | sed 's/  version: 1.0.0/  version: 2.0.0/')
API_BASE_V1="${API_NAME}@1.0.0"
ACTION=new-version TEAM="$TEAM" API_NAME="$API_NAME" API_BASE="$API_BASE_V1" NEW_VERSION=2.0.0 \
  OPENAPI_SPEC="$SPEC_V2" INBOUND_MODE=jwt \
  GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" \
  GIT_REPO="$PLAT_REPO" ENVN="$ENVN" \
  bash scripts/api-request.sh >"$TMP/p6req.log" 2>&1
R6REQ=$?
PR_V2=$(grep -oE 'PR #[0-9]+ ouverte' "$TMP/p6req.log" | grep -oE '[0-9]+' | head -1)
DRAIN6=0; jdrain "$JOB" || DRAIN6=1
N6=$(jnext "$JOB")
MERGE6=$(merge_as_oscar "$TEAM_REPO" "${PR_V2:-0}")
ST6=$(jwait "$JOB" "${N6:-0}" 120)
SUB6=""; ST6B=""; OWN6=non
if [ "$ST6" = PAUSED_PENDING_INPUT ] && claim_build "$JOB" "$N6" "api/${API_NAME}-2.0.0"; then
  OWN6=oui
  SUB6=$(answer_pause "$JOB" "$N6")
  ST6B=$(jwait_end "$JOB" "$N6" 300)
fi
API_V2=$(wmapi apis | python3 -c "
import json,sys
print(next((a['api']['id'] for a in json.load(sys.stdin).get('apiResponse',[])
            if a['api']['apiName']=='$API_NAME' and a['api']['apiVersion']=='2.0.0'), ''))" 2>/dev/null)
POL_V1=$(wmapi "apis/$API_V1" | python3 -c "import json,sys; print(','.join(sorted(json.load(sys.stdin)['apiResponse']['api'].get('policies') or [])))" 2>/dev/null)
POL_V2=$(wmapi "apis/${API_V2:-none}" | python3 -c "import json,sys; print(','.join(sorted(json.load(sys.stdin)['apiResponse']['api'].get('policies') or [])))" 2>/dev/null)
SUBS_V1_AFTER=$(subs_of "$API_V1")
SUBS_V2_AFTER=$(subs_of "${API_V2:-none}")
# Les marqueurs du rôle voyagent par le COMMENTAIRE de la PR (team-publish.sh
# en extrait son résumé depuis le log Ansible, qui ne passe PAS par la console
# Jenkins) — c'est donc là qu'on les lit, pas dans le log du build.
CB6=$(pr_comment_marked "$TEAM_REPO" "${PR_V2:-0}" '<!-- team-publish -->')
DISJOINT=no
[ -n "$POL_V1" ] && [ -n "$POL_V2" ] && [ -z "$(comm -12 <(printf '%s\n' "${POL_V1//,/$'\n'}" | sort) <(printf '%s\n' "${POL_V2//,/$'\n'}" | sort))" ] && DISJOINT=oui
if [ "$R6REQ" -eq 0 ] && [ "$MERGE6" = 200 ] && [ "$ST6B" = SUCCESS ] && [ -n "$API_V2" ] \
   && [ "$DISJOINT" = oui ] \
   && [ -n "$SUBS_V1_BEFORE" ] && [ "$SUBS_V2_AFTER" = "$SUBS_V1_BEFORE" ] && [ "$SUBS_V1_AFTER" = "$SUBS_V1_BEFORE" ] \
   && printf '%s' "$CB6" | grep -q VERSION_CREATED \
   && printf '%s' "$CB6" | grep -q VERSION_CLONE_OK \
   && printf '%s' "$CB6" | grep -q VERSION_SUBS_RETAINED; then
  ok "6. v2 minée (id $API_V2) : policies [$POL_V2] DISJOINTES de la base [$POL_V1] (M2) ; souscriptions relues AVANT [$SUBS_V1_BEFORE] -> APRÈS v2 [$SUBS_V2_AFTER] et base [$SUBS_V1_AFTER] (M3, base jamais désabonnée) ; PR ✅ VERSION_CREATED + VERSION_CLONE_OK + VERSION_SUBS_RETAINED"
else
  bad "6. req=$R6REQ merge=$MERGE6 pause=$ST6 build_prouvé_nôtre=$OWN6 submit=$SUB6 fin=$ST6B v2=${API_V2:-absente} policies_disjointes=$DISJOINT subs_avant=[${SUBS_V1_BEFORE:-vide}] subs_v2=[${SUBS_V2_AFTER:-vide}] subs_base=[${SUBS_V1_AFTER:-vide}] commentaire=$(printf '%s' "$CB6" | head -c 160)$([ "$DRAIN6" = 1 ] && echo ' — CAUSE PROBABLE : une pause ÉTRANGÈRE bloque la file de ce job (laissée intacte à dessein)') — voir $JENKINS_UI/job/$JOB/${N6:-?}/console"
fi

# fin de la fenêtre de sondage ps — ICI, avant toute lecture de ses résultats.
kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""

# ─────────────────────────────────────────────────────────────────────────────
# 7. re-pose ÉVÉNEMENTIELLE des listes des DEUX formulaires
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 7. re-pose des listes : la nouvelle ÉQUIPE et la nouvelle API y sont =="
choices_of() { curl -sf "$JENKINS_UI/job/$1/api/json?depth=1" | NAME="$2" python3 -c "
import json, os, sys
name = os.environ['NAME']
for p in json.load(sys.stdin).get('property', []):
    for q in p.get('parameterDefinitions', []):
        if q.get('name') == name:
            print(','.join(q.get('choices') or [])); raise SystemExit
" 2>/dev/null; }
T7_API_TEAM=$(choices_of api-request TEAM)
T7_APP_TEAM=$(choices_of app-request TEAM)
T7_API_BASE=$(choices_of api-request API_BASE)
T7_APP_API=$(choices_of app-request API)
T7A=no; printf '%s' ",$CFG_TEAM_AFTER_ONB," | grep -qF ",$TEAM," && T7A=oui
T7B=no; printf '%s' ",$T7_API_TEAM," | grep -qF ",$TEAM," && printf '%s' ",$T7_APP_TEAM," | grep -qF ",$TEAM," && T7B=oui
T7C=no; printf '%s' ",$T7_API_BASE," | grep -qF ",${API_NAME}@2.0.0," && printf '%s' ",$T7_APP_API," | grep -qF ",${API_NAME}@2.0.0," && T7C=oui
if [ "$T7A" = oui ] && [ "$T7B" = oui ] && [ "$T7C" = oui ]; then
  ok "7. après l'onboarding les formulaires portaient déjà '$TEAM' (api-request TEAM=[$CFG_TEAM_AFTER_ONB]) ; après publication les DEUX formulaires portent '$TEAM' ET '${API_NAME}@2.0.0' (api-request API_BASE=[$T7_API_BASE], app-request API=[$T7_APP_API])"
else
  bad "7. equipe_apres_onboarding=$T7A equipe_maintenant=$T7B api_v2_dans_les_deux=$T7C — api-request TEAM=[$T7_API_TEAM] API_BASE=[$T7_API_BASE] ; app-request TEAM=[$T7_APP_TEAM] API=[$T7_APP_API]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. sondage ps -Aww — aucun secret en argv, AVEC contrôle positif
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 8. sondage ps -Aww (preuves 1/2/5/6) — aucun secret en argv =="
printf '%s\n' "$GITEA_TOKEN"   > "$TMP/needle-gitea";  chmod 600 "$TMP/needle-gitea"
printf '%s\n' "$TOK_ONBOARDER" > "$TMP/needle-vault";  chmod 600 "$TMP/needle-vault"
printf '%s\n' "$OSCAR_TOK"     > "$TMP/needle-oscar";  chmod 600 "$TMP/needle-oscar"
printf '%s\n' "$VROOT"         > "$TMP/needle-root";   chmod 600 "$TMP/needle-root"
LINES=$(wc -l < "$PSLOG" 2>/dev/null | tr -d ' ')
H_G=$(grep -cFf "$TMP/needle-gitea" "$PSLOG" 2>/dev/null || true)
H_V=$(grep -cFf "$TMP/needle-vault" "$PSLOG" 2>/dev/null || true)
H_O=$(grep -cFf "$TMP/needle-oscar" "$PSLOG" 2>/dev/null || true)
H_R=$(grep -cFf "$TMP/needle-root"  "$PSLOG" 2>/dev/null || true)
H_P=$(grep -cFf "$OSCAR_PASS_FILE"  "$PSLOG" 2>/dev/null || true)
# Motif GÉNÉRIQUE : toute URL http://user:secret@host — la signature exacte du
# bug que GIT_CONFIG_* referme. Plus fort qu'un grep sur des valeurs connues :
# il attraperait N'IMPORTE QUEL credential embarqué dans une URL de push, y
# compris un que ce script ne possède pas (le token org-admin que team-apply.sh
# lit lui-même dans Vault, par exemple).
H_URL=$(grep -cE 'https?://[A-Za-z0-9_.%-]+:[^@[:space:]]+@[A-Za-z0-9_.-]+' "$PSLOG" 2>/dev/null || true)
# CONTRÔLE POSITIF : LINES>0 prouve seulement que `ps` a TOURNÉ. Un `git push`
# local dure <200 ms et peut passer ENTRE deux échantillons — sans cette
# mesure, la preuve rendrait PASS sans avoir jamais regardé la classe de
# process qu'elle police.
H_TRAF=$(grep -cE 'git-remote-http|send-pack|git push' "$PSLOG" 2>/dev/null || true)
if [ "${LINES:-0}" -gt 0 ] && [ "${H_TRAF:-0}" -gt 0 ] \
   && [ "${H_G:-0}" -eq 0 ] && [ "${H_V:-0}" -eq 0 ] && [ "${H_O:-0}" -eq 0 ] \
   && [ "${H_R:-0}" -eq 0 ] && [ "${H_P:-0}" -eq 0 ] && [ "${H_URL:-0}" -eq 0 ]; then
  ok "8. 0 occurrence des 5 secrets (token ci, token Vault éphémère, token Gitea d'oscar, token d'amorçage, mot de passe nominatif) et 0 motif user:secret@host sur $LINES lignes de ps, DONT $H_TRAF lignes de trafic git RÉELLEMENT observées — contrôle positif tenu"
else
  bad "8. ci×$H_G vault×$H_V oscar×$H_O root×$H_R mdp×$H_P url×$H_URL trafic_git×${H_TRAF:-0} (sur $LINES lignes) — $([ "${H_TRAF:-0}" -eq 0 ] && echo 'CONTRÔLE POSITIF ÉCHOUÉ : aucun trafic git vu, la preuve ne peut RIEN affirmer' || echo 'FUITE réelle') — voir $PSLOG"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 9. le harnais SAIT ROUGIR, puis teardown symétrique (404 EXACT)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "== 9. contre-épreuve rouge (garde cassée pour de vrai) + teardown symétrique =="
# Un harnais jamais vu rouge est le défaut nº1 de ce dépôt : on casse une
# garde RÉELLE de la chaîne producteur, on vérifie que le CRITÈRE de la
# preuve 1 vire au FAIL, et on restaure à l'octet près. La restauration est
# vérifiée par `git diff` — pas par la seule bonne foi du `cp`.
cp scripts/api-request.sh "$TMP/api-request.sh.orig"
# sed PORTABLE : `-i ''` est BSD/macOS, `-i` nu est GNU — on tente le premier,
# on retombe sur le second (motif établi du dépôt).
sed -i '' 's/API_NAME_INVALID/API_NAME_CASSE_PAR_LE_HARNAIS/g' scripts/api-request.sh 2>/dev/null \
  || sed -i 's/API_NAME_INVALID/API_NAME_CASSE_PAR_LE_HARNAIS/g' scripts/api-request.sh
RED_OUT=$(env GITEA_TOKEN="$GITEA_TOKEN" GIT_HOST="$GITEA_URL" GIT_WEB_HOST="$GITEA_URL" \
  GIT_REPO="$PLAT_REPO" ENVN="$ENVN" ACTION=create TEAM="$TEAM" API_NAME='../evil' \
  API_VERSION=1.0.0 OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=jwt bash scripts/api-request.sh 2>&1)
RED_RC=$?
cp "$TMP/api-request.sh.orig" scripts/api-request.sh
rm -f "$TMP/api-request.sh.orig"
RESTORED=non
git -C "$REPO_ROOT" diff --quiet -- scripts/api-request.sh 2>/dev/null && RESTORED=oui
if [ "$RESTORED" != oui ]; then
  bad "9. scripts/api-request.sh NE revient PAS identique après la contre-épreuve — arrêt avant le teardown (l'état du dépôt prime sur la suite des verdicts)"
  echo "== $PASS PASS / $FAIL FAIL =="
  exit 1
fi
RED_OK=non
{ [ "$RED_RC" -ne 0 ] && ! printf '%s' "$RED_OUT" | grep -q 'API_NAME_INVALID'; } && RED_OK=oui

teardown
sleep 1   # laisser Gitea/Vault/Jenkins digérer les suppressions avant relecture

RC_TEAMREPO=$(ghc "$GITEA_URL/api/v1/repos/$TEAM_REPO")
RC_TEAMORG=$(ghc "$GITEA_URL/api/v1/orgs/$TEAM")
RC_PLATREPO=$(ghc "$GITEA_URL/api/v1/repos/$PLAT_REPO")
RC_PLATORG=$(ghc "$GITEA_URL/api/v1/orgs/$PLAT_ORG")
RC_ORPHREPO=$(ghc "$GITEA_URL/api/v1/repos/$ORPH_REPO")
RC_ORPHORG=$(ghc "$GITEA_URL/api/v1/orgs/$ORPH_ORG")
RC_KV=$(vlt "$VROOT" "secret/data/stoa/deploy/$TEAM/wm-admin")
RC_POL=$(vlt "$VROOT" "sys/policies/acl/deploy-$TEAM")
RC_JOB=$(curl -s -o /dev/null -w '%{http_code}' "$JENKINS_UI/job/$JOB/api/json")
# Le témoin du dépôt plateforme RÉEL (capturé juste avant la preuve 1) : relu
# ICI, après le teardown, pour que la fenêtre couverte soit exactement les
# preuves 1 à 9.
CI_HEADS_AFTER=$(git ls-remote --heads "$GITEA_URL/ci/stoa-labs.git" 2>/dev/null)
CI_INTACT=oui
[ "$CI_HEADS_BEFORE" = "$CI_HEADS_AFTER" ] || CI_INTACT=non
CI_DELTA=""
if [ "$CI_INTACT" = non ]; then
  CI_DELTA=$(diff <(printf '%s\n' "$CI_HEADS_BEFORE") <(printf '%s\n' "$CI_HEADS_AFTER") 2>/dev/null | head -6 | tr '\n' ' ')
fi
TEAMWORK_NOW=$(wmapi configurations/extended | python3 -c "import json,sys; print(json.load(sys.stdin).get('enableTeamWork','?'))" 2>/dev/null)
CFG_SAME=oui
for j in app-request api-request; do
  curl -sf "$JENKINS_UI/job/$j/config.xml" -o "$TMP/final-$j.xml" 2>/dev/null
  cmp -s "$TMP/baseline-$j.xml" "$TMP/final-$j.xml" || CFG_SAME=non
done
# Le job n'est exigé ABSENT que si c'est CE run qui l'a créé — sinon on ne
# détruit pas un état antérieur, et l'exiger absent serait un faux rouge.
JOB_OK=oui
if [ "$CREATED_JOB" = 1 ]; then [ "$RC_JOB" = 404 ] || JOB_OK=non; else [ "$RC_JOB" = 200 ] || JOB_OK=non; fi

if [ "$RED_OK" = oui ] && [ "$RESTORED" = oui ] \
   && [ "$RC_TEAMREPO" = 404 ] && [ "$RC_TEAMORG" = 404 ] \
   && [ "$RC_PLATREPO" = 404 ] && [ "$RC_PLATORG" = 404 ] \
   && [ "$RC_ORPHREPO" = 404 ] && [ "$RC_ORPHORG" = 404 ] \
   && [ "$RC_KV" = 404 ] && [ "$RC_POL" = 404 ] \
   && [ "$JOB_OK" = oui ] && [ "$CFG_SAME" = oui ] \
   && [ "$CI_INTACT" = oui ] \
   && [ "$TEAMWORK_NOW" = "$TEAMWORK_AT_ENTRY" ]; then
  ok "9. contre-épreuve ROUGE tenue (tag renommé -> le critère de la preuve 1 ne matche plus, rc=$RED_RC) et garde restaurée à l'identique (git diff vide) ; ci/stoa-labs (dépôt plateforme RÉEL) INCHANGÉ sur toute la fenêtre des preuves 1-9 (heads identiques au témoin) ; teardown : dépôts/orgs jetables, KV et policy tous en 404 EXACT, job $JOB $([ "$CREATED_JOB" = 1 ] && echo 'supprimé (créé par ce run)' || echo 'laissé en place (préexistant)'), configs des 2 formulaires restaurées à l'octet près, enableTeamWork rendu à '$TEAMWORK_AT_ENTRY' — objets gateway NON supprimés (le mock n'expose aucune route DELETE : 405 mesuré ; sur la vraie 10.15 une ressource supprimée répondrait 401, pas 404)"
else
  bad "9. rouge=$RED_OK(rc=$RED_RC) restauré=$RESTORED | team_repo=$RC_TEAMREPO team_org=$RC_TEAMORG plat_repo=$RC_PLATREPO plat_org=$RC_PLATORG orph_repo=$RC_ORPHREPO orph_org=$RC_ORPHORG kv=$RC_KV policy=$RC_POL job=$RC_JOB(ok=$JOB_OK) configs_identiques=$CFG_SAME teamwork=$TEAMWORK_NOW(attendu $TEAMWORK_AT_ENTRY)$([ "$CI_INTACT" = non ] && echo " | CI_STOA_LABS_MUTE_PAR_LES_PREUVES_1_9 : les heads de ci/stoa-labs ont CHANGÉ entre la fin de la preuve 0 et la fin de la preuve 9 — soit une régression fait fuiter un accès en écriture au dépôt plateforme RÉEL hors de la preuve 0, soit un run CONCURRENT y a poussé (lab partagé). Delta : $CI_DELTA") — tous les codes Gitea/Vault attendus à 404 EXACT"
fi

echo
echo "== $PASS PASS / $FAIL FAIL =="
[ "$FAIL" -eq 0 ]
