#!/usr/bin/env bash
# test-producer-chain-gitlab.sh — LA CHAÎNE PRODUCTEUR EN DIRECT SUR LE GITLAB CE
# RÉEL DU LAB (L5 phase 2). Les scripts sont joués DIRECTEMENT (pas par Jenkins :
# les récepteurs team-* à deux visages sont L6 phase 2), les MR sont mergées par
# l'API, l'apply post-merge est joué sur le SHA mergé. Dépôts d'équipe PRÉ-CRÉÉS
# par setup-team-repos.sh (D10). Cibles OBLIGATOIRES, sans défaut :
#   GITLAB_URL (http://localhost:13080) · GITLAB_TOKEN_FILE (fichier 0600, PAT api du lab : .env.gitlab-lab)
#   VAULT_ADDR · VAULT_TOKEN_FILE · WM_GATEWAY_URL (le MOCK, jamais 5555) · GIT_REPO (ci/stoa-labs)
# Preuves :
#   0  prérequis : GitLab joignable, projet plateforme privé (info/refs anonyme ⇒ 401), merge_method=merge,
#      ci/archives présent, et le tronc SOUS TEST semé sur la branche par défaut DÉCOUVERTE du projet
#   1  team-request.sh en direct ⇒ MR sur le dépôt plateforme, commentée <!-- team-request-plan --> ✅
#   2b contre-épreuve : team-apply.sh sur un dépôt NON créé ⇒ rc 2, DEPOT_ABSENT sur la MR, rien de poussé
#   2  merge par l'API ⇒ team-apply.sh sur le SHA mergé, dépôt PRÉ-CRÉÉ vide ⇒ squelette poussé, ✅ <!-- team-apply -->
#   3  api-request.sh ⇒ MR sur le dépôt d'équipe, commentée <!-- api-request -->
#   4  merge par l'API ⇒ team-publish.sh en direct ⇒ API vue sur le mock, ✅ sur la MR (lien -/merge_requests/)
#   5  api-promote-export.sh ⇒ archive au registre ci/archives, MR d'épinglage ; rejeu ⇒ MR retrouvée
#      (pr_find_open), pas de doublon
#   6  api-promote-request.sh ⇒ MR de promotion ; merge ⇒ team-promote.sh en direct ⇒ archive rapatriée par digest
#   7  discriminant : FORGE_KIND=gitea contre ce GitLab ⇒ refus nommé « REDIRIGE vers /users/sign_in »
#   8  sondage ps -Aww pendant 1-6 : aucun secret en argv (contrôle positif : du trafic git observé)
#   9  teardown symétrique : projets créés supprimés (404 exact), branches et paquets du run retirés,
#      Vault nettoyé, branche par défaut de la plateforme rendue au tronc semé
# Les preuves 4, 5 et 6 traversent la GATEWAY : sur le mock du lab elles sont SKIP,
# à leur signature exacte et avec leur cause (écart 8 ci-dessous) — jamais vertes
# par défaut, jamais rouges au nom d'un défaut qui n'est pas celui de la chaîne.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QUE LA FORGE RÉELLE A IMPOSÉ (mesuré le 2026-09-12, GitLab CE du lab) —
# écarts ASSUMÉS au squelette du brief, chacun avec sa raison :
#
# 1. team-apply.sh NE PEUT PAS être joué depuis cet arbre-ci. Il fait
#    `git checkout "$MERGE_SHA"` DANS SON PROPRE cwd (§1, anti-TOCTOU) : le
#    lancer depuis le worktree de travail y détacherait la HEAD — sur un arbre
#    partagé avec d'autres sessions, c'est un dégât, pas une preuve. Il est donc
#    joué depuis un CLONE FRAIS et AUTHENTIFIÉ du dépôt plateforme, exactement
#    comme le fait son jumeau Gitea (scripts/test-producer-chain.sh, §pré-requis).
#    Conséquence directe : le team-apply SOUS TEST est celui du CLONE, donc celui
#    de HEAD — d'où le semis de la preuve 0, et l'avertissement quand l'arbre de
#    travail diverge de HEAD.
#
# 2. LE TRONC EST SEMÉ (preuve 0.4). Mesuré : la branche par défaut de
#    ci/stoa-labs portait `0ac16c26`, un commit ABSENT de cet arbre (merge
#    serveur d'un run antérieur). Sans le semis, la chaîne jouerait le code d'un
#    autre jour et la matrice ne dirait rien du code sous revue. Le semis est un
#    `push --force` de la valeur DÉCOUVERTE (ls-remote --symref HEAD), jamais
#    d'un littéral ; le teardown rend la branche à ce même tronc, ce qui rend le
#    run RÉELLEMENT rejouable (le second run ne trouve aucun résidu du premier).
#
# 3. LE DISCRIMINANT A DEUX VOIES, PARCE QUE LA FORGE RÉPOND SELON LE VERBE.
#    Deux mesures : (a) le login Basic « x » PASSE sur ce GitLab (ls-remote OK en
#    x:<PAT> comme en oauth2:<PAT>), donc le visage menti ne tombe pas au premier
#    geste git ; (b) sur un chemin « /api/v1 », ce GitLab REDIRIGE un GET (302
#    vers /users/sign_in — la panne du client du 2026-09-09) mais rend un 404
#    JSON à un POST. La preuve 7 joue donc les deux : api-promote-export, dont le
#    premier contact d'API est un GET (`forge raw`) AVANT tout clone et tout push,
#    porte la redirection nommée ; team-request, dont le premier contact d'API est
#    le POST d'ouverture de MR, porte le refus nommé — et sa branche, poussée
#    avant ce POST, est retirée au teardown. Exiger la redirection de la voie
#    d'écriture aurait été exiger de la forge un comportement qu'elle n'a pas.
#
# 4. LE REGISTRE CENTRAL DE GOUVERNANCE est un dépôt À PART, créé par ce run
#    (GOVERNANCE_REPO/GOVERNANCE_PATH n'ont AUCUN défaut dans la chaîne :
#    api-request et team-publish refusent CHAMP_REQUIS sans eux). Il déclare
#    l'API jetable ; la posture déclarée par les demandes lui est conforme,
#    sinon le rouge accuserait la chaîne d'un défaut du harnais.
#
# 5. LES IDENTITÉS VAULT SONT CELLES DE L'APPLY, pas le root : un token éphémère
#    mono-policy `team-onboarder` pour l'onboarding/la publication/l'export, un
#    token éphémère mono-policy `apply-<palier>` pour la promotion (c'est la
#    rétention G4/ADR-082 qui ouvre le palier, §7b de team-promote). Le root ne
#    sert qu'à MINTER et à nettoyer.
#
# 6. `secret/stoa/gateways/webmethods` est ABSENT de ce Vault (mesuré : 404) :
#    le rôle retombe alors champ par champ sur ses variables (Administrator /
#    manage), ce que le mock accepte. C'est un fait du lab, pas un contrat.
#
# 7. LA FEATURE TEAMS EST ALLUMÉE PAR LE HARNAIS, et rendue à sa valeur d'entrée
#    au teardown : le rôle de publication exige une équipe et refuse fail-closed
#    (TEAMS_DISABLED) sinon. Geste d'admin assumé, mesuré à l'entrée.
#
# 8. LA POSTURE EST H/internal, ET LES PREUVES 4 À 6 PEUVENT ÊTRE « SKIP ».
#    Deux faits du socle, tous deux mesurés le 2026-09-12 :
#      - tout bouquet `vh-*` exige `mtls`, que la 10.15 ne décline pas par API
#        (jalon P5) — d'où H/internal, applicable, plutôt que VH/external ;
#      - le mock ne re-sérialise pas `apiDefinition` (mocks/webmethods/store.go,
#        champ `Definition` en `json:"-"` ; le record relu ne porte que id,
#        apiName, apiVersion, isActive, type, policies). Or le tag de posture
#        (P3/ADR-093) vit dans `apiDefinition.tags` et sa relecture est
#        fail-closed : la publication s'arrête donc AVANT l'activation, l'API
#        reste inactive, et l'export refuse (piège isActive, ADR-079).
#    La suite RECONNAÎT cette signature (TAG_UNCONFIRMED + « porte tags=[] ») et
#    marque 4, 5 et 6 SKIP avec leur cause, au lieu d'un rouge qui accuserait la
#    chaîne ou d'un vert qui mentirait. Le jour où le mock rend ce champ — ou le
#    jour où WM_GATEWAY_URL vise une gateway qui le rend — ces preuves se jouent
#    d'elles-mêmes, sans toucher à ce fichier.
#
# PRÉREQUIS : GitLab CE du lab up, PAT `api` Owner du groupe ci dans un fichier
# 0600, Vault up (policies team-onboarder et apply-<palier> posées), mock
# webMethods up. La suite est LIVE : lint-ci ne l'exécute JAMAIS.
#
#   GITLAB_URL=http://localhost:13080 GITLAB_TOKEN_FILE=/chemin/pat.tok \
#   VAULT_ADDR=http://localhost:8200 VAULT_TOKEN_FILE=/chemin/vault-root.tok \
#   WM_GATEWAY_URL=http://localhost:8090 bash scripts/test-producer-chain-gitlab.sh
# shellcheck disable=SC2015,SC2016
set -uo pipefail
RACINE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$RACINE" || exit 2
: "${GITLAB_URL:?GITLAB_URL requis (ex. http://localhost:13080)}" "${GITLAB_TOKEN_FILE:?GITLAB_TOKEN_FILE requis (fichier 0600)}"
: "${VAULT_ADDR:?VAULT_ADDR requis}" "${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE requis (fichier 0600)}" "${WM_GATEWAY_URL:?le MOCK webMethods, jamais 5555}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
TS=$(date +%s); TEAM="l5gl${TS: -6}"; TEAM_REPO="ci/${TEAM}-apis"; API_NAME="demo-${TEAM}"
GOV_REPO="ci/${TEAM}-gov"; GOV_PATH="governance/classifications.yaml"
PKG_ATTENDU="promote--${TEAM}--${API_NAME}"   # le paquet du run au registre générique
DISC_TEAM="${TEAM}d"          # le discriminant (preuve 7) travaille sur SON équipe : réutiliser
DISC_REPO="ci/${DISC_TEAM}-apis"  # celle du nominal ferait tomber une garde d'entrée, pas la forge
export FORGE_KIND=gitlab GIT_HOST="$GITLAB_URL" GIT_WEB_HOST="$GITLAB_URL" ARCHIVE_STORE_PROJECT=ci/archives
export GOVERNANCE_REPO="$GOV_REPO" GOVERNANCE_PATH="$GOV_PATH"
# La posture déclarée par les demandes de ce harnais : conforme au registre semé
# plus bas. Une demande sans posture serait refusée en CHAMP_REQUIS, une posture
# divergente en CLASSIFICATION_SPOOFED — deux rouges qui accuseraient le harnais.
# ⚠ H/internal, PAS VH (mesuré le 2026-09-12) : tout bouquet `vh-*` exige `mtls`,
# et la 10.15 ne le décline PAS par API (clientAuth du listener non éditable,
# jalon P5) — la publication rendrait POSTURE_NON_DECLINABLE, un refus JUSTE qui
# accuserait la plateforme au lieu de mesurer la chaîne. `*-internet` est écarté
# pour la même raison (threat-protection refusé au stage, jalon P4). Le bouquet
# h-internal (https-only + oauth2) est applicable sur ce socle : c'est donc lui
# qui laisse la chaîne aller jusqu'au bout.
export CLASSIFICATION=H EXPOSURE=internal
PASS=0; FAIL=0; SKIPPED=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
skip(){ SKIPPED=$((SKIPPED+1)); printf '  \033[33mSKIP\033[0m %s\n' "$*"; }
note(){ printf '  ⚠ %s\n' "$*"; }
umask 077
TMP=$(mktemp -d)
# shellcheck source=scripts/lib/forge-api.sh
. scripts/lib/forge-api.sh
forge_api_init || exit 2
# shellcheck source=scripts/lib/forge-identity.sh
. scripts/lib/forge-identity.sh
# shellcheck source=scripts/lib/posture-authority.sh
. scripts/lib/posture-authority.sh
# shellcheck source=scripts/lib/env-chain.sh
. scripts/lib/env-chain.sh

# Le secret vit en VARIABLE D'ENVIRONNEMENT (héritée par les enfants) et en
# FICHIER (pour l'adaptateur python) — jamais en argv : c'est la preuve 8 qui
# le police. `export` ne met rien dans la table des process.
FORGE_SECRET="$(tr -d '\r\n' < "$GITLAB_TOKEN_FILE")"; export FORGE_SECRET
export FORGE_SECRET_FILE="$GITLAB_TOKEN_FILE"
[ -n "$FORGE_SECRET" ] || { echo "PRÉ-VOL: GITLAB_TOKEN_FILE ('$GITLAB_TOKEN_FILE') vide ou illisible" >&2; exit 2; }
VROOT="$(tr -d '\r\n' < "$VAULT_TOKEN_FILE")"
[ -n "$VROOT" ] || { echo "PRÉ-VOL: VAULT_TOKEN_FILE ('$VAULT_TOKEN_FILE') vide ou illisible" >&2; exit 2; }

# ── harnais : l'API DIRECTE n'est utilisée QUE pour merger, lire et nettoyer ──
# (aucune décision de la chaîne ne passe par ici ; les scripts, eux, ne parlent
# à la forge que par scripts/lib/forge-api.*)
forge_auth_write "$FORGE_SECRET" "$TMP/hdr" || exit 2
gl(){ curl -s --max-time 60 -H @"$TMP/hdr" -H 'Content-Type: application/json' "$@"; }
glc(){ gl -o /dev/null -w '%{http_code}' "$@"; }
enc(){ python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
# git authentifié : en-tête Basic (jamais l'URL, que `ps` lirait), et
# http.postBuffer — notre tronc pèse ~11 Mio et ce GitLab rend 500 en chunked.
GAUTH_B64="$(printf 'oauth2:%s' "$FORGE_SECRET" | base64 | tr -d '\n')"
gauth(){ GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization: Basic $GAUTH_B64" \
         GIT_CONFIG_KEY_1=http.postBuffer GIT_CONFIG_VALUE_1=524288000 git "$@"; }
vhdr(){ local f; f="$(mktemp "$TMP/vhdr.XXXXXX")"; chmod 600 "$f"; printf 'X-Vault-Token: %s\n' "$1" > "$f"; printf '%s' "$f"; }
vlt(){ curl -s --max-time 20 -H @"$(vhdr "$1")" "$VAULT_ADDR/v1/$2" -o /dev/null -w '%{http_code}'; }
wmapi(){ curl -s --max-time 30 -u Administrator:manage -H 'Accept: application/json' "$WM_GATEWAY_URL/rest/apigateway/$1"; }

# merge_mr <projet> <iid> → merge_commit_sha sur stdout
# GitLab prépare le diff d'une MR de façon ASYNCHRONE : tant que
# detailed_merge_status n'est pas « mergeable », le PUT /merge rend 405.
merge_mr(){
  local p st; p=$(enc "$1")
  for _ in $(seq 1 60); do
    st=$(gl "$GITLAB_URL/api/v4/projects/$p/merge_requests/$2" \
         | python3 -c 'import json,sys;print(json.load(sys.stdin).get("detailed_merge_status",""))' 2>/dev/null)
    [ "$st" = mergeable ] && break
    sleep 1
  done
  [ "$st" = mergeable ] || { echo "merge_mr: MR !$2 de $1 jamais mergeable (detailed_merge_status='$st')" >&2; return 1; }
  gl -X PUT "$GITLAB_URL/api/v4/projects/$p/merge_requests/$2/merge" -o "$TMP/merge.json" -w '%{http_code}' \
    | grep -q '^200$' || { echo "merge_mr: PUT /merge refusé sur !$2 de $1 : $(head -c 200 "$TMP/merge.json")" >&2; return 1; }
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("merge_commit_sha") or "")' "$TMP/merge.json"
}
# mr_notes <projet> <iid> → le corps de TOUTES les notes, concaténé
mr_notes(){ gl "$GITLAB_URL/api/v4/projects/$(enc "$1")/merge_requests/$2/notes?per_page=100" \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("\n".join(n.get("body","") for n in d) if isinstance(d,list) else "")' 2>/dev/null; }
# pkg_names → les noms de paquets du registre (un par ligne)
pkg_names(){ gl "$GITLAB_URL/api/v4/projects/$(enc "$ARCHIVE_STORE_PROJECT")/packages?per_page=100" \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("\n".join(p.get("name","") for p in d) if isinstance(d,list) else "")' 2>/dev/null; }

# ── teardown : UNE implémentation, appelée par la preuve 9 (qui en VÉRIFIE
# l'effet) ET par le trap. Armée AVANT le premier geste : si la suite meurt en
# route, rien ne reste. Elle ne touche QUE ce que ce run a créé — jamais
# ci/stoa-labs, ci/archives ou le groupe ci eux-mêmes.
BASE_DEFAUT=""; TRONC=""; VTOK_ONB=""; VTOK_PAL=""; SAMPLER_PID=""; MR_PLAT=""; MR_PIN=""; TEAMWORK_AT_ENTRY=""
teardown(){
  [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null
  # projets créés par ce run (le team-repo, le registre de gouvernance jetable)
  glc -X DELETE "$GITLAB_URL/api/v4/projects/$(enc "$TEAM_REPO")" >/dev/null
  glc -X DELETE "$GITLAB_URL/api/v4/projects/$(enc "$GOV_REPO")"  >/dev/null
  # les MR encore OUVERTES sur le dépôt plateforme : FERMÉES (jamais supprimées)
  local n
  for n in $MR_PLAT; do
    glc -X PUT "$GITLAB_URL/api/v4/projects/$(enc "$GIT_REPO")/merge_requests/$n" -d '{"state_event":"close"}' >/dev/null
  done
  # les branches que ce run a poussées sur le dépôt plateforme
  local b
  for b in "$TR_BRANCH" "$DISC_BRANCH"; do
    [ -n "$b" ] && glc -X DELETE "$GITLAB_URL/api/v4/projects/$(enc "$GIT_REPO")/repository/branches/$(enc "$b")" >/dev/null
  done
  # le paquet du run au registre générique (jamais le registre lui-même)
  local id
  for id in $(gl "$GITLAB_URL/api/v4/projects/$(enc "$ARCHIVE_STORE_PROJECT")/packages?per_page=100" \
      | PKG="promote--${TEAM}--${API_NAME}" python3 -c 'import json,os,sys
d=json.load(sys.stdin)
print(" ".join(str(p["id"]) for p in d if p.get("name")==os.environ["PKG"]) if isinstance(d,list) else "")' 2>/dev/null); do
    glc -X DELETE "$GITLAB_URL/api/v4/projects/$(enc "$ARCHIVE_STORE_PROJECT")/packages/$id" >/dev/null
  done
  # Vault : ce que l'onboarding de l'équipe jetable a écrit, puis les tokens du run
  curl -s --max-time 20 -H @"$(vhdr "$VROOT")" -X DELETE "$VAULT_ADDR/v1/secret/metadata/stoa/deploy/$TEAM/wm-admin" -o /dev/null
  curl -s --max-time 20 -H @"$(vhdr "$VROOT")" -X DELETE "$VAULT_ADDR/v1/sys/policies/acl/deploy-$TEAM" -o /dev/null
  local t
  for t in "$VTOK_ONB" "$VTOK_PAL"; do
    [ -n "$t" ] && curl -s --max-time 20 -H @"$(vhdr "$t")" -X POST "$VAULT_ADDR/v1/auth/token/revoke-self" -o /dev/null
  done
  # Gateway : la bascule enableTeamWork est rendue à sa valeur D'ENTRÉE
  # (mesurée, pas supposée). Les OBJETS (API publiée, archive importée) ne le
  # sont pas : le mock n'expose aucune route DELETE (405, mesuré au palier 3) —
  # la preuve 9 le DIT plutôt que de le taire.
  if [ -n "$TEAMWORK_AT_ENTRY" ]; then
    curl -s --max-time 20 -u Administrator:manage -X PUT -H 'Content-Type: application/json' \
      -d "{\"enableTeamWork\":\"$TEAMWORK_AT_ENTRY\"}" "$WM_GATEWAY_URL/rest/apigateway/configurations/extended" -o /dev/null
  fi
  # la branche par défaut de la plateforme rendue AU TRONC SEMÉ : le merge
  # d'onboarding de ce run ne doit pas survivre au run (rejouabilité).
  if [ -n "$BASE_DEFAUT" ] && [ -n "$TRONC" ]; then
    gauth -C "$RACINE" push -q --force "$CLONE_URL" "${TRONC}:refs/heads/${BASE_DEFAUT}" >/dev/null 2>&1
  fi
}
TR_BRANCH=""; DISC_BRANCH=""
CLONE_URL="${GITLAB_URL%/}/${GIT_REPO}.git"
# KEEP_LOGS=1 garde le répertoire de travail (journaux des scripts joués) : le
# teardown, lui, a TOUJOURS lieu — on garde des traces, jamais des objets.
trap 'teardown; if [ -n "${KEEP_LOGS:-}" ]; then echo "journaux conservés : $TMP"; else rm -rf "$TMP"; fi' EXIT

echo "== chaîne PRODUCTEUR en direct sur GITLAB — équipe jetable $TEAM, API $API_NAME =="
echo "   GitLab=$GITLAB_URL  plateforme=$GIT_REPO  registre=$ARCHIVE_STORE_PROJECT  Vault=$VAULT_ADDR  gateway(mock)=$WM_GATEWAY_URL"

# ── PRÉ-VOL : chaque prérequis NOMMÉ. Un prérequis absent arrête la suite
# (exit 2) plutôt que de produire des verdicts qui parleraient d'autre chose. ──
die(){ echo "PRÉ-VOL: $*" >&2; exit 2; }
case "$WM_GATEWAY_URL" in
  *:5555*) die "WM_GATEWAY_URL vise le port 5555 — c'est la VRAIE gateway 10.15 du lab, en service. Ce harnais écrit sur sa cible : refus." ;;
esac
[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$GITLAB_URL/")" != 000 ] || die "GitLab injoignable sur $GITLAB_URL"
[ "$(curl -s --max-time 10 -u Administrator:manage -o /dev/null -w '%{http_code}' "$WM_GATEWAY_URL/rest/apigateway/apis")" = 200 ] \
  || die "mock webMethods injoignable ($WM_GATEWAY_URL)"
[ "$(vlt "$VROOT" 'sys/policies/acl/team-onboarder')" = 200 ] \
  || die "policy Vault 'team-onboarder' absente — jouer scripts/setup-team-onboard-prereqs.sh"
command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook absent du PATH (plans et applys de la chaîne)"
# LA FEATURE TEAMS DOIT ÊTRE ACTIVE : le rôle de publication exige une équipe
# (apim_pub_require_team) et refuse fail-closed sinon — TEAMS_DISABLED, mesuré
# en direct au troisième run de cette suite : la publication s'arrête avant
# toute écriture. C'est un geste d'ADMIN sur la gateway, assumé ici et RENDU au
# teardown à la valeur trouvée à l'entrée.
TEAMWORK_AT_ENTRY=$(wmapi configurations/extended | python3 -c 'import json,sys;print(json.load(sys.stdin).get("enableTeamWork","false"))' 2>/dev/null)
[ -n "$TEAMWORK_AT_ENTRY" ] || TEAMWORK_AT_ENTRY=false
curl -s --max-time 20 -u Administrator:manage -X PUT -H 'Content-Type: application/json' \
  -d '{"enableTeamWork":"true"}' "$WM_GATEWAY_URL/rest/apigateway/configurations/extended" -o /dev/null
echo "   état d'entrée de la gateway : enableTeamWork=$TEAMWORK_AT_ENTRY (rendu tel quel au teardown)"
resolve_posture_authority "$TMP/labctl" \
  || die "aucun labctl disponible (ni LABCTL_BIN, ni go build, ni PATH) — depuis P2 la chaîne producteur ne peut pas arbitrer une posture sans lui"
# L'AUTORITÉ DE POSTURE DOIT ÊTRE DANS LE PATH, comme sur l'agent du lab. Les
# scripts livrés honorent LABCTL_BIN pour LEURS gardes, mais le RÔLE
# apim_publish_api résout `apim_pub_labctl_bin` (défaut « labctl ») dans le PATH
# et AUCUN script livré ne lui transmet LABCTL_BIN — mesuré ici au premier run
# (POSTURE_AUTORITE_ABSENTE à la publication). Le knob LABCTL_BIN de
# ci/Jenkinsfile.team-publish est donc INERTE sur ce chemin : dette NOMMÉE au
# rapport de cette tâche, fail-CLOSED (un refus, jamais une posture sans juge),
# donc hors du périmètre de correction de ce lot. Le lab range labctl dans le
# PATH de son agent ; ce harnais fait la même chose, et rien de plus.
case "$LABCTL_BIN" in /*/labctl) PATH="$(dirname "$LABCTL_BIN"):$PATH"; export PATH ;; esac

echo
echo "== 0. prérequis =="
hc=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' "$GITLAB_URL/$GIT_REPO.git/info/refs?service=git-upload-pack")
[ "$hc" = 401 ] && ok "0.1 le dépôt plateforme est PRIVÉ (info/refs anonyme ⇒ 401) — le vrai cas client" \
  || bad "0.1 info/refs anonyme ⇒ $hc (dépôt public : la preuve ne prouverait pas l'authentification)"
MM=$(gl "$GITLAB_URL/api/v4/projects/$(enc "$GIT_REPO")" \
     | python3 -c 'import json,sys;print(json.load(sys.stdin).get("merge_method",""))' 2>/dev/null)
[ "$MM" = merge ] && ok "0.2 merge_method=merge (merge_commit_sha non nul, l'apply post-merge a un SHA à checkouter)" \
  || bad "0.2 merge_method='$MM' ≠ merge — un squash/ff ne rendrait aucun merge_commit_sha"
if GIT_REPO="$ARCHIVE_STORE_PROJECT" forge_kv AR repo_get && [ "${AR_EXISTS:-0}" = 1 ]; then
  ok "0.3 $ARCHIVE_STORE_PROJECT existe (registre générique PAR PROJET — le visage GitLab d'archive-store)"
else
  bad "0.3 $ARCHIVE_STORE_PROJECT absent — jouer scripts/setup-gitlab-lab.sh ; les preuves 5 et 6 n'auraient nulle part où déposer"
fi
# LA BRANCHE PAR DÉFAUT EST CELLE QUE LE PROJET ANNONCE, jamais celle que la
# suite préfère (même motif que scripts/lib/git-base.sh, joué ici par le harnais
# pour savoir OÙ semer).
BASE_DEFAUT="$(gauth ls-remote --symref "$CLONE_URL" HEAD 2>"$TMP/symref.err" | sed -n 's#^ref: refs/heads/\(.*\)\tHEAD$#\1#p' | head -1)"
[ -n "$BASE_DEFAUT" ] || die "BRANCHE_PAR_DEFAUT_INCONNUE : $GIT_REPO n'annonce aucune HEAD symbolique — $(head -c 200 "$TMP/symref.err")"
TRONC="$(git -C "$RACINE" rev-parse HEAD)"
REMOTE_TRONC="$(gauth ls-remote "$CLONE_URL" "refs/heads/$BASE_DEFAUT" 2>/dev/null | cut -f1)"
if [ "$REMOTE_TRONC" = "$TRONC" ]; then
  ok "0.4 $GIT_REPO porte déjà le tronc sous test ($(printf '%s' "$TRONC" | cut -c1-7)) sur sa branche par défaut DÉCOUVERTE '$BASE_DEFAUT'"
elif gauth -C "$RACINE" push -q --force "$CLONE_URL" "${TRONC}:refs/heads/${BASE_DEFAUT}" 2>"$TMP/push0.err"; then
  ok "0.4 tronc sous test ($(printf '%s' "$TRONC" | cut -c1-7)) semé sur '$BASE_DEFAUT' (l'ancien $(printf '%s' "${REMOTE_TRONC:-néant}" | cut -c1-7) n'était pas de cet arbre) — c'est CE code que l'apply post-merge exécutera"
else
  bad "0.4 semis impossible vers $BASE_DEFAUT : $(head -c 200 "$TMP/push0.err")"
fi
# L'arbre de travail n'est PAS ce que le clone exécutera : le dire plutôt que de
# le taire (une correction non commitée resterait invisible à la preuve 2).
SALE=$(git -C "$RACINE" status --porcelain -- scripts ansible clients labctl 2>/dev/null | head -5)
[ -z "$SALE" ] || note "arbre de travail MODIFIÉ hors HEAD ($(printf '%s' "$SALE" | tr '\n' ' ' | cut -c1-140)) — le clone de la preuve 2 exécute HEAD, pas ces fichiers-là"

# ── identités Vault ÉPHÉMÈRES : le périmètre RÉEL de chaque geste, pas le root ─
mint_vault(){ curl -s --max-time 20 -H @"$(vhdr "$VROOT")" -X POST \
  -d "{\"policies\":[\"$1\"],\"ttl\":\"60m\",\"no_default_policy\":true}" "$VAULT_ADDR/v1/auth/token/create" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("auth",{}).get("client_token",""))' 2>/dev/null; }
VTOK_ONB=$(mint_vault team-onboarder)
[ -n "$VTOK_ONB" ] || die "mint du token éphémère team-onboarder impossible"
VTOK_ONB_FILE="$TMP/vtok-onboarder"; printf '%s' "$VTOK_ONB" > "$VTOK_ONB_FILE"; chmod 600 "$VTOK_ONB_FILE"

# ── le REGISTRE CENTRAL de classification (dépôt à part, créé par ce run) ────
gl -X POST -o /dev/null "$GITLAB_URL/api/v4/projects" \
  -d "{\"name\":\"${TEAM}-gov\",\"path\":\"${TEAM}-gov\",\"namespace_id\":$(gl "$GITLAB_URL/api/v4/groups/$(enc ci)" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])'),\"visibility\":\"private\",\"initialize_with_readme\":false}"
rm -rf "$TMP/gov"; mkdir -p "$TMP/gov/governance"
cat > "$TMP/gov/$GOV_PATH" <<GOVYML
apiVersion: governance.stoa.io/v1
kind: ClassificationRegistry
classifications:
  - {owner: ${TEAM}, tenant: banking-demo, api: ${API_NAME}, classification: ${CLASSIFICATION}, exposure: ${EXPOSURE}}
GOVYML
( cd "$TMP/gov" && git init -q -b "$BASE_DEFAUT" . && git add governance \
  && git -c user.name=ci -c user.email=ci@stoa.lab commit -qm "seed: registre central de classification (jetable, run $TS)" ) >/dev/null 2>&1
gauth -C "$TMP/gov" push -q "${GITLAB_URL%/}/${GOV_REPO}.git" "$BASE_DEFAUT" 2>"$TMP/govpush.err" \
  || die "publication du registre central jetable dans $GOV_REPO en échec — $(tail -2 "$TMP/govpush.err")"

# ── sondage ps -Aww : ouvert ICI, fermé après la preuve 6 (il couvre 1 à 6) ──
PSLOG="$TMP/pslog"; : > "$PSLOG"
( while :; do ps -Aww >>"$PSLOG" 2>/dev/null; sleep 0.02; done ) & SAMPLER_PID=$!

echo
echo "== 1. team-request.sh en direct ⇒ MR + commentaire de plan =="
TEAM="$TEAM" DESCRIPTION="equipe jetable L5 phase 2 (run $TS)" APPROVERS="" REPO="$TEAM_REPO" GIT_REPO="$GIT_REPO" \
  bash scripts/team-request.sh > "$TMP/p1.log" 2>&1; R1=$?
MR1=$(grep -oE 'PR #[0-9]+ ouverte' "$TMP/p1.log" | grep -oE '[0-9]+' | head -1)
MR_PLAT="$MR1"
if [ "$R1" = 0 ] && [ -n "$MR1" ]; then
  ok "1.1 MR !$MR1 ouverte sur $GIT_REPO (rc 0) — clone, providers modifié, branche poussée, MR ouverte par l'adaptateur"
else
  bad "1.1 rc $R1 : $(tail -3 "$TMP/p1.log" | tr '\n' ' ' | cut -c1-260)"
fi
# La branche et le palier ne sont pas devinés : ils sont RELUS sur la forge —
# team-request scelle l'env d'authoring (G4/ADR-082), la suite le CONSTATE.
if [ -n "$MR1" ] && GIT_REPO="$GIT_REPO" forge_kv M1 pr_get "$MR1"; then
  TR_BRANCH="${M1_HEAD_REF:-}"; ENVN="${TR_BRANCH##*-}"
else
  TR_BRANCH=""; ENVN=""
fi
N1=$(mr_notes "$GIT_REPO" "${MR1:-0}")
case "$N1" in
  *team-request-plan*) ok "1.2 commentaire de plan sous <!-- team-request-plan --> présent sur !$MR1 (branche relue : ${TR_BRANCH:-?}, palier scellé : ${ENVN:-?})" ;;
  *) bad "1.2 pas de commentaire de plan sur !${MR1:-?} — $(tail -2 "$TMP/p1.log" | tr '\n' ' ' | cut -c1-200)" ;;
esac
[ -n "$TR_BRANCH" ] && [ -n "$ENVN" ] || die "branche/palier de la MR d'onboarding illisibles sur la forge — les preuves suivantes n'auraient rien à appliquer"

echo
echo "== 2b. contre-épreuve DEPOT_ABSENT (dépôt d'équipe NON pré-créé) =="
SHA1=$(merge_mr "$GIT_REPO" "${MR1:-0}") || bad "2b.0 merge de !${MR1:-?} impossible"
[ -n "${SHA1:-}" ] || die "merge_commit_sha vide après le merge de !${MR1:-?} — l'apply n'a rien à checkouter"
MR_PLAT=""   # mergée : plus rien à fermer au teardown
# LE CLONE FRAIS (cf. écart n°1 de l'en-tête) : team-apply checkoute le SHA
# mergé DANS SON cwd. Il est donc joué là, jamais dans l'arbre de travail.
SUB="$(basename "$RACINE")"
gauth clone -q -b "$BASE_DEFAUT" "$CLONE_URL" "$TMP/src" 2>"$TMP/clone.err" \
  || die "clone du dépôt plateforme impossible : $(head -c 200 "$TMP/clone.err")"
SRC="$TMP/src/$SUB"
[ -d "$SRC" ] || die "le clone de $GIT_REPO ne porte pas '$SUB' — le tronc semé n'est pas celui qu'on croit"
apply_team(){ # <fichier de log> — team-apply.sh joué depuis le clone frais
  ( cd "$SRC" && PR_BRANCH="$TR_BRANCH" PR_NUMBER="$MR1" MERGE_SHA="$SHA1" \
      VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VTOK_ONB_FILE" \
      APIM_API_BASE="${WM_GATEWAY_URL}/rest/apigateway" \
      GIT_HOST="$GITLAB_URL" GIT_WEB_HOST="$GITLAB_URL" GIT_REPO="$GIT_REPO" \
      bash scripts/team-apply.sh ) > "$1" 2>&1
}
apply_team "$TMP/p2b.log"; R2B=$?
if [ "$R2B" = 2 ] && grep -q 'DEPOT_ABSENT' "$TMP/p2b.log"; then
  ok "2b.1 team-apply refuse DEPOT_ABSENT (rc 2) sur un dépôt d'équipe non créé — D10 : la chaîne LIT le dépôt, elle ne le crée plus"
else
  bad "2b.1 rc $R2B : $(tail -3 "$TMP/p2b.log" | tr '\n' ' ' | cut -c1-260)"
fi
N2B=$(mr_notes "$GIT_REPO" "$MR1")
case "$N2B" in
  *DEPOT_ABSENT*) ok "2b.2 le refus est NOMMÉ sur la MR (marqueur <!-- team-apply -->)" ;;
  *) bad "2b.2 refus non commenté sur !$MR1" ;;
esac
RC2B=$(glc "$GITLAB_URL/api/v4/projects/$(enc "$TEAM_REPO")")
[ "$RC2B" = 404 ] && ok "2b.3 rien n'a été créé : $TEAM_REPO en 404 EXACT" || bad "2b.3 $TEAM_REPO répond $RC2B — un projet est apparu malgré le refus"

echo
echo "== 2. dépôt pré-créé VIDE ⇒ team-apply pousse le squelette =="
# Ruling 24 : --no-hook. Le Jenkins du lab porte désormais de VRAIS récepteurs
# GitLab team-publish/team-promote (lot voisin) : un hook ferait rejouer ces
# jobs à chaque merge EN PLUS des scripts que cette suite joue en direct — deux
# applys concurrents sur la même MR. La protection, elle, reste posée.
WEBHOOK_KIND=gitlab bash scripts/setup-team-repos.sh "$TEAM_REPO" --no-hook > "$TMP/pre.log" 2>&1 \
  && ok "2.1 setup-team-repos.sh : projet vide + protection, sans hook — Ruling 24" \
  || bad "2.1 pré-création : $(tail -3 "$TMP/pre.log" | tr '\n' ' ' | cut -c1-260)"
apply_team "$TMP/p2.log"; R2=$?
D_EMPTY=""; GIT_REPO="$TEAM_REPO" forge_kv D repo_get
if [ "$R2" = 0 ] && [ "${D_EMPTY:-1}" = 0 ] && grep -q 'squelette' "$TMP/p2.log"; then
  ok "2.2 team-apply rc 0 : dépôt VIDE → squelette ADR-076 poussé (repo_get rend EMPTY=0), statut ✅ sur la MR"
else
  bad "2.2 rc $R2 EMPTY=${D_EMPTY:-?} : $(tail -3 "$TMP/p2.log" | tr '\n' ' ' | cut -c1-260)"
fi

echo
echo "== 3. api-request.sh ⇒ MR sur le dépôt d'ÉQUIPE =="
SPEC_OK='openapi: 3.0.0
info:
  title: '"$API_NAME"'
  version: 1.0.0
paths:
  /ping:
    get:
      responses:
        "200":
          description: ok
'
ACTION=create TEAM="$TEAM" API_NAME="$API_NAME" API_VERSION=1.0.0 OPENAPI_SPEC="$SPEC_OK" INBOUND_MODE=jwt \
  GIT_REPO="$GIT_REPO" LABCTL_BIN="$LABCTL_BIN" \
  bash scripts/api-request.sh > "$TMP/p3.log" 2>&1; R3=$?
MR3=$(grep -oE 'PR #[0-9]+ ouverte' "$TMP/p3.log" | grep -oE '[0-9]+' | head -1)
API_BRANCH="api/${API_NAME}-1.0.0"
if [ "$R3" = 0 ] && [ -n "$MR3" ]; then
  ok "3.1 MR !$MR3 ouverte sur $TEAM_REPO (branche $API_BRANCH) — spec + manifeste portés par la demande"
else
  bad "3.1 rc $R3 : $(tail -3 "$TMP/p3.log" | tr '\n' ' ' | cut -c1-260)"
fi
N3=$(mr_notes "$TEAM_REPO" "${MR3:-0}")
case "$N3" in
  *api-request*) ok "3.2 plan commenté sous <!-- api-request --> sur !${MR3:-?}" ;;
  *) bad "3.2 pas de commentaire de plan sur !${MR3:-?}" ;;
esac

echo
echo "== 4. merge ⇒ team-publish.sh en direct ⇒ API sur la gateway =="
SHA3=$(merge_mr "$TEAM_REPO" "${MR3:-0}") || bad "4.0 merge de !${MR3:-?} impossible"
WEBHOOK_REPO="$TEAM_REPO" PR_BRANCH="$API_BRANCH" PR_NUMBER="${MR3:-0}" MERGE_SHA="${SHA3:-}" \
  VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VTOK_ONB_FILE" \
  APIM_API_BASE="${WM_GATEWAY_URL}/rest/apigateway" \
  GIT_HOST="$GITLAB_URL" GIT_WEB_HOST="$GITLAB_URL" GIT_REPO="$GIT_REPO" LABCTL_BIN="$LABCTL_BIN" \
  bash scripts/team-publish.sh > "$TMP/p4.log" 2>&1; R4=$?
NB_API=$(wmapi apis | API="$API_NAME" python3 -c 'import json,os,sys
d=json.load(sys.stdin)
print(sum(1 for a in d.get("apiResponse",[]) if a.get("api",{}).get("apiName")==os.environ["API"]))' 2>/dev/null)
# LA LIMITE DU LAB, RECONNUE À SA SIGNATURE — jamais supposée. Le mock ne
# re-sérialise PAS `apiDefinition` (mocks/webmethods/store.go : le champ
# `Definition` porte `json:"-"`, et le record relu n'a que id/apiName/
# apiVersion/isActive/type/policies — MESURÉ le 2026-09-12). Or le tag de
# posture (P3, ADR-093) vit dans `apiDefinition.tags` et sa RELECTURE est
# fail-closed : elle lit donc toujours `tags=[]`, et la publication s'arrête
# AVANT l'activation. Ce n'est ni un défaut de la chaîne ni du visage GitLab —
# c'est la fidélité du mock, et le tag a été prouvé au jalon P3 contre la 10.15
# RÉELLE (port 5555), que cette tâche a interdiction de viser. La preuve n'est
# donc pas « verte quand même » : elle est SKIP, avec sa cause, et redeviendra
# rouge ou verte d'elle-même le jour où le mock rendra ce champ.
MOCK_TAG_LIMITE=0
if [ "$R4" = 0 ] && [ "${NB_API:-0}" -ge 1 ]; then
  ok "4.1 team-publish rc 0 sur le SHA mergé — l'API '$API_NAME' est VUE sur la gateway (${NB_API} exemplaire)"
elif grep -q 'TAG_UNCONFIRMED' "$TMP/p4.log" && grep -q 'porte tags=\[\]' "$TMP/p4.log"; then
  MOCK_TAG_LIMITE=1
  skip "4.1 LIMITE DU LAB (pas un défaut de la chaîne) : l'API '$API_NAME' EST créée sur la gateway (n=${NB_API:-0}) — tout ce qui précède a fonctionné — mais la RELECTURE fail-closed du tag de posture (P3/ADR-093, roles/apim_publish_api/tasks/tag.yml) lit tags=[] : le mock ne re-sérialise pas apiDefinition (mocks/webmethods/store.go, champ Definition en json:\"-\"), donc aucun tag ne peut être relu. Publication arrêtée avant l'activation. Le tag est prouvé au jalon P3 contre la 10.15 RÉELLE (port 5555), interdite ici. Remède (lab, hors périmètre L5) : sérialiser apiDefinition dans le mock, puis RECRÉER le conteneur (un restart relance l'ancienne image)."
else
  bad "4.1 rc $R4, apis '$API_NAME' sur la gateway = ${NB_API:-?} : $(tail -3 "$TMP/p4.log" | tr '\n' ' ' | cut -c1-260)"
fi
N4=$(mr_notes "$TEAM_REPO" "${MR3:-0}")
if case "$N4" in *team-publish*'/-/merge_requests/'*|*'/-/merge_requests/'*team-publish*) true;; *) false;; esac; then
  ok "4.2 statut ✅ commenté sous <!-- team-publish -->, avec le lien GitLab de la MR (/-/merge_requests/) — jamais un /pulls/N composé à la main"
elif [ "$MOCK_TAG_LIMITE" = 1 ]; then
  skip "4.2 le statut de succès (seul porteur du lien [PR #N](…)) n'est pas écrit tant que la publication ne va pas au bout — dépend de 4.1 (LIMITE DU LAB). Le commentaire d'ÉCHEC, lui, EST posé sur la MR par l'autorité de forge : $(printf '%s' "$N4" | grep -c 'team-publish') note(s) team-publish relue(s)"
else
  bad "4.2 commentaire team-publish absent ou sans lien GitLab : $(printf '%s' "$N4" | tail -2 | tr '\n' ' ' | cut -c1-200)"
fi

echo
if [ "$MOCK_TAG_LIMITE" = 1 ]; then
  echo "== 5. api-promote-export.sh / == 6. promotion — NON JOUÉES =="
  # Une API que la publication n'a pas pu activer n'a pas d'archive à exporter
  # (EXPORT_REFUSED : « … est INACTIVE — son archive désactiverait l'API à chaque
  # import », piège isActive d'ADR-079, mesuré ici) : jouer 5 et 6 quand même ne
  # mesurerait que la conséquence de 4.1, sous un autre nom.
  skip "5.1 dépend de la publication (4.1, LIMITE DU LAB) : sans API ACTIVE, api-promote-export refuse EXPORT_REFUSED (piège isActive, ADR-079) — le registre générique PAR PROJET ($ARCHIVE_STORE_PROJECT) n'est donc pas exercé ici ; il l'est hors ligne par scripts/test-archive-store.sh et en direct par scripts/test-forge-live (Task 13)"
  skip "5.2 MR d'épinglage — dépend de 5.1"
  skip "5.3 rejeu/idempotence de l'épinglage — dépend de 5.1"
  skip "6.1 demande de promotion — dépend de 5.1 (sans épinglage, api-promote-request refuse DIGEST_ABSENT, mesuré)"
  skip "6.2 merge de la MR de promotion — dépend de 6.1"
  skip "6.3 team-promote / ARCHIVE_STORE_FETCHED — dépend de 6.1"
else
  echo "== 5. api-promote-export.sh ⇒ archive au registre + MR d'épinglage =="
  export_api(){ TEAM="$TEAM" API_NAME="$API_NAME" \
    VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VTOK_ONB_FILE" \
    APIM_API_BASE="${WM_GATEWAY_URL}/rest/apigateway" \
    GIT_HOST="$GITLAB_URL" GIT_WEB_HOST="$GITLAB_URL" GIT_REPO="$GIT_REPO" \
    bash scripts/api-promote-export.sh > "$1" 2>&1; }
  export_api "$TMP/p5.log"; R5=$?
  ARCH_SHA=$(grep -oE 'EXPORT_CONFIRMED_SUMMARY .*sha256=[0-9a-f]{64}' "$TMP/p5.log" | grep -oE '[0-9a-f]{64}' | head -1)
  if [ "$R5" = 0 ] && [ -n "$ARCH_SHA" ] && pkg_names | grep -qxF "$PKG_ATTENDU"; then
    ok "5.1 export rc 0 : archive poussée au registre $ARCHIVE_STORE_PROJECT sous '$PKG_ATTENDU', version = son sha256 ($(printf '%s' "$ARCH_SHA" | cut -c1-12)…)"
  else
    bad "5.1 rc $R5 sha=${ARCH_SHA:-absent} paquet '$PKG_ATTENDU' $(pkg_names | grep -qxF "$PKG_ATTENDU" && echo présent || echo ABSENT) : $(grep -oE '"msg": "[^"]{0,200}"' "$TMP/p5.log" | tail -1) $(tail -2 "$TMP/p5.log" | tr '\n' ' ' | cut -c1-200)"
  fi
  PIN_BRANCH="chore/promote-manifest-${API_NAME}"
  MR_PIN=$(GIT_REPO="$TEAM_REPO" forge pr_find_open "$PIN_BRANCH" 2>/dev/null | sed -n 's/^NUMBER=//p')
  [ -n "$MR_PIN" ] && ok "5.2 MR d'épinglage !$MR_PIN ouverte sur $TEAM_REPO (branche $PIN_BRANCH) : guid + sha256 + version" \
    || bad "5.2 aucune MR d'épinglage ouverte sur $PIN_BRANCH"
  export_api "$TMP/p5bis.log"; R5B=$?
  MR_PIN2=$(GIT_REPO="$TEAM_REPO" forge pr_find_open "$PIN_BRANCH" 2>/dev/null | sed -n 's/^NUMBER=//p')
  if [ "$R5B" = 0 ] && grep -q 'déjà ouverte' "$TMP/p5bis.log" && [ "$MR_PIN2" = "$MR_PIN" ]; then
    ok "5.3 rejeu : « PR d'épinglage déjà ouverte : #$MR_PIN » (pr_find_open la retrouve), aucun doublon — le registre est idempotent PAR LE CONTENU"
  else
    bad "5.3 rejeu rc $R5B, MR retrouvée '${MR_PIN2:-aucune}' (attendu '${MR_PIN:-?}') : $(tail -3 "$TMP/p5bis.log" | tr '\n' ' ' | cut -c1-260)"
  fi

  echo
  echo "== 6. api-promote-request.sh ⇒ MR de promotion ; merge ⇒ team-promote.sh =="
  # L'épinglage est MERGÉ d'abord : c'est lui qui porte le digest que la demande
  # de promotion lira sur la branche de base du dépôt d'équipe.
  if [ -n "$MR_PIN" ]; then
    merge_mr "$TEAM_REPO" "$MR_PIN" >/dev/null || bad "6.0 merge de la MR d'épinglage !$MR_PIN impossible"
    MR_PIN=""
  fi
  # Le palier d'ARRIVÉE se LIT dans la chaîne d'environnements (l'ordre de la
  # liste EST la chaîne, cf. clients/_example/environments.yaml) — jamais un
  # littéral : sur un engagement client la chaîne porte d'autres noms.
  CHAINE=$(env_chain 2>/dev/null) || CHAINE=""
  TO_ENV=""; PREV=""
  # shellcheck disable=SC2086  # découpage VOULU : env_chain rend les paliers séparés par des espaces
  for e in $CHAINE; do
    [ "$PREV" = "$ENVN" ] && { TO_ENV="$e"; break; }
    PREV="$e"
  done
  if [ -z "$TO_ENV" ]; then
    skip "6.1 palier suivant de '$ENVN' introuvable dans la chaîne d'environnements — rien à promouvoir"
  else
    TEAM="$TEAM" API_NAME="$API_NAME" FROM_ENV="$ENVN" TO_ENV="$TO_ENV" \
      MESSAGE="promotion de la matrice producteur GitLab (run $TS)" \
      GIT_HOST="$GITLAB_URL" GIT_WEB_HOST="$GITLAB_URL" GIT_REPO="$GIT_REPO" \
      bash scripts/api-promote-request.sh > "$TMP/p6req.log" 2>&1; R6=$?
    PROMO_BRANCH="promote/${API_NAME}-${TO_ENV}"
    MR6=$(GIT_REPO="$TEAM_REPO" forge pr_find_open "$PROMO_BRANCH" 2>/dev/null | sed -n 's/^NUMBER=//p')
    if [ "$R6" = 0 ] && [ -n "$MR6" ] && grep -q 'PROMOTION_DEMANDEE' "$TMP/p6req.log"; then
      ok "6.1 MR de promotion !$MR6 ouverte sur $TEAM_REPO (branche $PROMO_BRANCH, $ENVN → $TO_ENV)"
    else
      bad "6.1 rc $R6, MR '${MR6:-aucune}' : $(tail -3 "$TMP/p6req.log" | tr '\n' ' ' | cut -c1-260)"
    fi
    if [ -n "$MR6" ]; then
      SHA6=$(merge_mr "$TEAM_REPO" "$MR6") || bad "6.2 merge de !$MR6 impossible"
      # L'identité qui PORTE l'apply : celle du compte de service de la forge, la
      # même que celle qui vient de merger — la garde d'identité de team-promote
      # (§6bis) compare les deux, et un écart serait un rouge du HARNAIS.
      VID=$(forge whoami 2>/dev/null | sed -n 's/^LOGIN=//p')
      VTOK_PAL=$(mint_vault "apply-${TO_ENV}")
      if [ -z "$VTOK_PAL" ]; then
        skip "6.3 policy Vault 'apply-${TO_ENV}' non mintable — la rétention du palier (ADR-082) ne peut pas être exercée ici"
      else
        VTOK_PAL_FILE="$TMP/vtok-palier"; printf '%s' "$VTOK_PAL" > "$VTOK_PAL_FILE"; chmod 600 "$VTOK_PAL_FILE"
        WEBHOOK_REPO="$TEAM_REPO" PR_BRANCH="$PROMO_BRANCH" PR_NUMBER="$MR6" MERGE_SHA="${SHA6:-}" \
          VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VTOK_PAL_FILE" VAULT_IDENTITY_USER="$VID" \
          ADMIN_VIA=direct APIM_API_BASE_TPL="${WM_GATEWAY_URL}/rest/apigateway" \
          APIM_DIRECT_BASE_TPL="${WM_GATEWAY_URL}/rest/apigateway" \
          GIT_HOST="$GITLAB_URL" GIT_WEB_HOST="$GITLAB_URL" GIT_REPO="$GIT_REPO" LABCTL_BIN="$LABCTL_BIN" \
          bash scripts/team-promote.sh > "$TMP/p6apply.log" 2>&1; R6A=$?
        if [ "$R6A" = 0 ] && grep -q 'ARCHIVE_STORE_FETCHED' "$TMP/p6apply.log"; then
          ok "6.3 team-promote rc 0 : archive RAPATRIÉE du registre PAR SON DIGEST (ARCHIVE_STORE_FETCHED) puis importée sur $TO_ENV"
        else
          bad "6.3 rc $R6A, ARCHIVE_STORE_FETCHED $(grep -q 'ARCHIVE_STORE_FETCHED' "$TMP/p6apply.log" && echo vu || echo ABSENT) : $(tail -4 "$TMP/p6apply.log" | tr '\n' ' ' | cut -c1-320)"
        fi
      fi
    fi
  fi
fi

# fin de la fenêtre de sondage (preuves 1 à 6)
kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""

echo
echo "== 7. discriminant : FORGE_KIND=gitea contre ce GitLab =="
# Le visage MENTI est le SEUL écart : mêmes cibles, même secret, mêmes scripts.
# ⚠ FAIT MESURÉ (2026-09-12, premier run de cette suite) : ce GitLab répond à un
# chemin « /api/v1 » SELON LE VERBE — un GET est REDIRIGÉ (302) vers
# /users/sign_in (la panne du client du 2026-09-09), un POST rend un 404 JSON.
# Le discriminant se joue donc sur les DEUX faces de la chaîne producteur :
#   A. la LECTURE — api-promote-export, dont le PREMIER contact d'API est
#      `forge raw` (un GET), AVANT tout clone et tout push : c'est là que la
#      redirection est nommée, et le refus ne laisse rien derrière lui ;
#   B. l'ÉCRITURE — team-request, dont le premier contact d'API est le POST
#      d'ouverture de MR : refus nommé lui aussi, et AUCUNE MR ouverte.
# Exiger la redirection de la voie B aurait été exiger un comportement que la
# forge ne produit pas sur ce verbe — un vert impossible, ou pire, un vert obtenu
# en relâchant l'assertion.
FORGE_KIND=gitea FORGE_API_AUTH=token \
  TEAM="$TEAM" API_NAME="$API_NAME" \
  VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN_FILE="$VTOK_ONB_FILE" \
  APIM_API_BASE="${WM_GATEWAY_URL}/rest/apigateway" \
  GIT_HOST="$GITLAB_URL" GIT_WEB_HOST="$GITLAB_URL" GIT_REPO="$GIT_REPO" \
  bash scripts/api-promote-export.sh > "$TMP/p7a.log" 2>&1; R7A=$?
if [ "$R7A" != 0 ] && grep -q 'REDIRIGE' "$TMP/p7a.log" && grep -q '/users/sign_in' "$TMP/p7a.log" \
   && grep -q 'LECTURE_PROVIDERS' "$TMP/p7a.log" && ! grep -q 'Traceback' "$TMP/p7a.log"; then
  ok "7.1 (lecture) FORGE_KIND=gitea ⇒ refus NOMMÉ LECTURE_PROVIDERS (rc $R7A), cause : « $(grep -o 'la forge REDIRIGE vers [^ ]*' "$TMP/p7a.log" | head -1) » — la panne du client du 2026-09-09, lisible, sans trace python"
else
  bad "7.1 rc $R7A : $(tail -3 "$TMP/p7a.log" | tr '\n' ' ' | cut -c1-300)"
fi
DISC_BRANCH="onboard/${DISC_TEAM}-${ENVN}"
FORGE_KIND=gitea FORGE_API_AUTH=token \
  TEAM="$DISC_TEAM" DESCRIPTION="discriminant du visage (run $TS)" APPROVERS="" REPO="$DISC_REPO" GIT_REPO="$GIT_REPO" \
  bash scripts/team-request.sh > "$TMP/p7b.log" 2>&1; R7B=$?
if [ "$R7B" != 0 ] && grep -q 'ouverture de la PR' "$TMP/p7b.log" && grep -q '/api/v1/' "$TMP/p7b.log" \
   && ! grep -q 'Traceback' "$TMP/p7b.log"; then
  ok "7.2 (écriture) FORGE_KIND=gitea ⇒ refus NOMMÉ (rc $R7B) : « $(grep -oE 'POST [^ ]*/api/v1/[^ ]* → HTTP [0-9]+' "$TMP/p7b.log" | head -1) » — l'adaptateur nomme le chemin du MAUVAIS visage, jamais un json.load sur du HTML"
else
  bad "7.2 rc $R7B : $(tail -3 "$TMP/p7b.log" | tr '\n' ' ' | cut -c1-300)"
fi
DISC_MR=$(GIT_REPO="$GIT_REPO" forge pr_find_open "$DISC_BRANCH" 2>/dev/null | sed -n 's/^NUMBER=//p')
[ -z "$DISC_MR" ] && ok "7.3 aucune MR ouverte par le visage menti — la branche poussée par la voie B est retirée au teardown, et la voie A n'a rien poussé du tout" \
  || bad "7.3 une MR !$DISC_MR a été ouverte malgré le refus"

echo "== 8. sondage ps -Aww (fenêtre des preuves 1 à 6, celles que ce run a jouées) — aucun secret en argv =="
printf '%s\n' "$FORGE_SECRET" > "$TMP/needle-pat";   chmod 600 "$TMP/needle-pat"
printf '%s\n' "$VROOT"        > "$TMP/needle-root";  chmod 600 "$TMP/needle-root"
printf '%s\n' "$VTOK_ONB"     > "$TMP/needle-onb";   chmod 600 "$TMP/needle-onb"
: > "$TMP/needle-pal"; chmod 600 "$TMP/needle-pal"
[ -n "$VTOK_PAL" ] && printf '%s\n' "$VTOK_PAL" > "$TMP/needle-pal"
LINES=$(grep -c '' "$PSLOG" 2>/dev/null || true)
H_PAT=$(grep -cFf "$TMP/needle-pat"  "$PSLOG" 2>/dev/null || true)
H_ROOT=$(grep -cFf "$TMP/needle-root" "$PSLOG" 2>/dev/null || true)
H_ONB=$(grep -cFf "$TMP/needle-onb"  "$PSLOG" 2>/dev/null || true)
H_PAL=0; [ -s "$TMP/needle-pal" ] && H_PAL=$(grep -cFf "$TMP/needle-pal" "$PSLOG" 2>/dev/null || true)
# Motif GÉNÉRIQUE : toute URL http://user:secret@host — il attraperait même un
# credential que ce harnais ne possède pas.
H_URL=$(grep -cE 'https?://[A-Za-z0-9_.%-]+:[^@[:space:]]+@[A-Za-z0-9_.-]+' "$PSLOG" 2>/dev/null || true)
# CONTRÔLE POSITIF : LINES>0 ne prouve que le fonctionnement de `ps`. Sans une
# classe de process RÉELLEMENT observée, la preuve ne policerait rien.
H_TRAF=$(grep -cE 'git-remote-http|send-pack|git push|git-upload-pack' "$PSLOG" 2>/dev/null || true)
if [ "${LINES:-0}" -gt 0 ] && [ "${H_TRAF:-0}" -gt 0 ] && [ "${H_PAT:-0}" -eq 0 ] \
   && [ "${H_ROOT:-0}" -eq 0 ] && [ "${H_ONB:-0}" -eq 0 ] && [ "${H_PAL:-0}" -eq 0 ] && [ "${H_URL:-0}" -eq 0 ]; then
  ok "8.1 0 occurrence des 4 secrets (PAT GitLab, token root Vault, 2 tokens éphémères) et 0 motif user:secret@host sur $LINES lignes de ps, DONT $H_TRAF lignes de trafic git RÉELLEMENT observées — contrôle positif tenu"
else
  bad "8.1 pat×$H_PAT root×$H_ROOT onboarder×$H_ONB palier×$H_PAL url×$H_URL trafic_git×${H_TRAF:-0} (sur ${LINES:-0} lignes) — $([ "${H_TRAF:-0}" -eq 0 ] && echo 'CONTRÔLE POSITIF ÉCHOUÉ : aucun trafic git vu, la preuve ne peut RIEN affirmer' || echo 'FUITE réelle')"
fi

echo
echo "== 9. teardown symétrique =="
teardown
sleep 2   # laisser GitLab digérer les suppressions avant relecture
RC_TEAM=$(glc "$GITLAB_URL/api/v4/projects/$(enc "$TEAM_REPO")")
RC_GOV=$(glc "$GITLAB_URL/api/v4/projects/$(enc "$GOV_REPO")")
RC_PLAT=$(glc "$GITLAB_URL/api/v4/projects/$(enc "$GIT_REPO")")
RC_ARCH=$(glc "$GITLAB_URL/api/v4/projects/$(enc "$ARCHIVE_STORE_PROJECT")")
RC_BR=$(glc "$GITLAB_URL/api/v4/projects/$(enc "$GIT_REPO")/repository/branches/$(enc "$TR_BRANCH")")
RC_BRD=$(glc "$GITLAB_URL/api/v4/projects/$(enc "$GIT_REPO")/repository/branches/$(enc "$DISC_BRANCH")")
PKG_RESTE=$(pkg_names | grep -cxF "$PKG_ATTENDU" || true)
RC_KV=$(vlt "$VROOT" "secret/data/stoa/deploy/$TEAM/wm-admin")
RC_POL=$(vlt "$VROOT" "sys/policies/acl/deploy-$TEAM")
TRONC_APRES=$(gauth ls-remote "$CLONE_URL" "refs/heads/$BASE_DEFAUT" 2>/dev/null | cut -f1)
if [ "$RC_TEAM" = 404 ] && [ "$RC_GOV" = 404 ] && [ "$RC_BR" = 404 ] && [ "$RC_BRD" = 404 ] \
   && [ "${PKG_RESTE:-1}" = 0 ] && [ "$RC_KV" = 404 ] && [ "$RC_POL" = 404 ] \
   && [ "$RC_PLAT" = 200 ] && [ "$RC_ARCH" = 200 ] && [ "$TRONC_APRES" = "$TRONC" ]; then
  ok "9.1 teardown symétrique : projets créés ($TEAM_REPO, $GOV_REPO) en 404 EXACT, branches du run ($TR_BRANCH, $DISC_BRANCH) retirées, 0 paquet '$PKG_ATTENDU' au registre, KV et policy de l'équipe en 404, tokens Vault du run révoqués, enableTeamWork rendu à '$TEAMWORK_AT_ENTRY' ; $GIT_REPO et $ARCHIVE_STORE_PROJECT INTACTS (200), branche '$BASE_DEFAUT' rendue au tronc $(printf '%s' "$TRONC" | cut -c1-7) — le run suivant ne trouve aucun résidu. NON supprimés, et c'est DIT : les objets de gateway (le mock n'expose aucune route DELETE — 405 mesuré au palier 3)"
else
  bad "9.1 team=$RC_TEAM gov=$RC_GOV branche=$RC_BR branche_disc=$RC_BRD paquets_restants=${PKG_RESTE:-?} kv=$RC_KV policy=$RC_POL | plateforme=$RC_PLAT registre=$RC_ARCH tronc=$(printf '%s' "${TRONC_APRES:-néant}" | cut -c1-7) (attendu $(printf '%s' "$TRONC" | cut -c1-7))"
fi

echo
echo "═══════════════════════════════════════════════════"
[ "$SKIPPED" -eq 0 ] || printf 'SKIP : %d preuve(s) non jouée(s) — voir les lignes SKIP ci-dessus\n' "$SKIPPED"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ]
