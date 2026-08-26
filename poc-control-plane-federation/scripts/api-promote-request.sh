#!/usr/bin/env bash
# api-promote-request.sh — moteur du formulaire « promouvoir une API »
# (jalon G3). Pendant de api-request.sh (publication) : MÊME MODÈLE STRUCTUREL
# — gardes nommées AVANT tout geste Git, team -> repo lu sur GITEA MAIN (jamais
# le worktree local), push par GIT_CONFIG_COUNT/KEY_0/VALUE_0 (jamais de token
# en URL ni en argv), PR par heredoc python, plan commenté sur la PR.
#
# CE SCRIPT NE DÉPLOIE RIEN. Il ouvre une PR portant le marqueur
# apis/<name>.deploy.<TO_ENV>.yaml. La DÉCISION est le merge (ADR-081).
#
# ⚠ ET SUR CE CHEMIN-CI, LA PORTE (4-yeux, ITSM, groupe d'approbation) N'EST
# ENFORCÉE PAR PERSONNE. Une version antérieure de cet en-tête écrivait
# « enforcée à l'apply par labctl/governance-api » : faux ici.
# `labctl dispatch-gate` n'est appelé que par ci/Jenkinsfile.prod, avec
# `--repo governance` — il garde le MONOREPO de gouvernance, pas un dépôt
# d'équipe. Les gardes ci-dessous sont in-repo, donc justiciables d'OWASP
# CICD-SEC-04 : elles rendent le refus LISIBLE TÔT, elles ne le rendent pas
# INCONTOURNABLE. La fermeture réelle est le jalon G4 (rétention du credential
# par palier).
#
# Entrées (env — mappées depuis les paramètres du job) :
#   TEAM, API_NAME, FROM_ENV, TO_ENV, MESSAGE   (requis)
#   CHANGE_REF, PV_REF                          (selon la porte d'arrivée)
#   ARCHIVE_SHA256                              (requis si TO_ENV != authoring)
#   GITEA_TOKEN                                 (requis hors DRY_RUN)
#   DRY_RUN=1                                   (s'arrête après les gardes)
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/lib/env-chain.sh
. scripts/lib/env-chain.sh
# shellcheck source=scripts/lib/deploy-pin.sh
. scripts/lib/deploy-pin.sh

fail() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }

TEAM="${TEAM:?TEAM requis}"
API_NAME="${API_NAME:?API_NAME requis}"
FROM_ENV="${FROM_ENV:?FROM_ENV requis}"
TO_ENV="${TO_ENV:?TO_ENV requis}"
MESSAGE="${MESSAGE:?MESSAGE requis}"
CHANGE_REF="${CHANGE_REF:-}"
PV_REF="${PV_REF:-}"
ARCHIVE_SHA256="${ARCHIVE_SHA256:-}"
# AFFECTATION SÈCHE, comme dans deploy-pin.sh : la source ci-dessus a défini la
# variable, un `${…:-dev}` ne ferait que réintroduire visuellement le knob
# surchargeable contre lequel deploy-pin.sh:29-37 met en garde sur neuf lignes.
# Si la source disparaissait, `set -u` refuserait ici — direction sûre, plutôt
# qu'un repli silencieux.
AUTHORING_ENV="$DEPLOY_PIN_AUTHORING_ENV"

# ⚠ FORME NÉGATIVE, ET C'EST LA SEULE QUI MARCHE. Dans un motif de `case`,
# `*` n'est pas un quantificateur mais le joker « n'importe quelle suite » :
# `[a-z0-9][a-z0-9-]*` se lit donc « un caractère, puis un caractère, puis
# ABSOLUMENT N'IMPORTE QUOI ». Mesuré en revue — cette forme acceptait
# `ab/../../../etc/passwd`, `ab$(id)` et `ab;rm -rf /`. C'est la classe de
# défaut que ce dépôt documente déjà noir sur blanc dans deploy-pin.sh, et
# dont la garde sœur (`""|*[!a-z0-9-]*`) est la forme correcte.
case "$API_NAME" in
  ""|-*|*[!a-z0-9-]*) fail "API_NAME_INVALIDE : '$API_NAME' — attendu des minuscules, chiffres et tirets, sans tiret initial" ;;
esac
[ "${#MESSAGE}" -le 1000 ] || fail "MESSAGE_TROP_LONG : le message d'audit dépasse 1000 caractères"

# ── Garde 1 : LA CHAÎNE ─────────────────────────────────────────────────────
# TO_ENV doit être le SUIVANT de FROM_ENV dans environments.yaml. L'ordre de la
# liste EST la chaîne : un saut dev -> prod n'est pas exprimable.
CHAIN="$(env_chain)" || fail "CHAINE_ILLISIBLE : environments.yaml absent, vide ou cassé"
NEXT=""
PREV=""
for e in $CHAIN; do
  if [ "$PREV" = "$FROM_ENV" ]; then NEXT="$e"; break; fi
  PREV="$e"
done
[ -n "$NEXT" ] && [ "$NEXT" = "$TO_ENV" ] \
  || fail "CHAINE_INVALIDE : '$FROM_ENV' -> '$TO_ENV' n'est pas un saut de la chaîne ($CHAIN)"

# ── Garde 2 : LES RÉFÉRENCES QUE LA PORTE D'ARRIVÉE EXIGE ───────────────────
# Refusé À LA DEMANDE, jamais découvert à l'approbation — MÊME RÈGLE que
# handlers_promotions.go:77-89. itsmCheck IMPLIQUE change_ref : il n'y a rien à
# re-vérifier auprès de l'ITSM sans une référence.
#
# ⚠ MÊME RÈGLE, PAS MÊME SOURCE — donc pas le « miroir » que cet en-tête
# annonçait. `env_chain()` lit le gabarit du dépôt PLATEFORME
# (clients/_example/environments.yaml, cf. lib/env-chain.sh) : il est appelé
# AVANT le clone du dépôt d'équipe, plus bas, donc lire la chaîne de l'équipe
# est mécaniquement impossible ici. governance-api, lui, lit `environments.yaml`
# sur `main` du dépôt GOVERNANCE (labctl/internal/governance/envchain.go), et
# seed-governance-chain.sh y copie le gabarit UNE FOIS, dans UN SEUL SENS : une
# porte modifiée côté governance laisse ces gardes-ci sur une copie périmée.
# Elles refusent TÔT ; elles ne font pas autorité.
GATE=$(env_chain_gate "$TO_ENV") || fail "PARSE_GATE : lecture de la porte vers '$TO_ENV'"
case "$GATE" in GATE=*) GATE="${GATE#GATE=}";; *) fail "PARSE_GATE : sortie inattendue";; esac
NEED_CHANGE="${GATE%%|*}"; GATE="${GATE#*|}"
NEED_PV="${GATE%%|*}"; APPROVER_GROUP="${GATE#*|}"

[ "$NEED_CHANGE" = 0 ] || [ -n "$CHANGE_REF" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$TO_ENV' exige une référence de changement (CHANGE_REF)"
[ "$NEED_PV" = 0 ] || [ -n "$PV_REF" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$TO_ENV' exige une référence de PV de recette (PV_REF)"

# ── Garde 2bis : LES RÉFÉRENCES SONT DES IDENTIFIANTS, PAS DU TEXTE LIBRE ────
# Elles finissent embarquées telles quelles dans le marqueur YAML écrit plus
# bas. Sans cette garde, un CHANGE_REF portant un saut de ligne et une clé
# `commit:` fabrique un marqueur qui PARSE PROPREMENT mais dont le commit est
# celui que le DEMANDEUR a choisi, pas celui que `git log` a calculé —
# l'invariant même que deploy-pin.sh existe pour tenir, atteint par une porte
# d'entrée que rien ne validait. On ferme donc ici, à la demande, avant tout
# geste Git — une référence vide reste licite (toutes les portes n'en
# exigent pas), seule sa FORME est contrainte quand elle est fournie.
case "$CHANGE_REF" in
  "") ;;
  *[!A-Za-z0-9._-]*) fail "REF_INVALIDE : CHANGE_REF contient un caractère hors de [A-Za-z0-9._-] (une référence multi-ligne ou citée fabriquerait une clé dans le marqueur)" ;;
esac
case "$PV_REF" in
  "") ;;
  *[!A-Za-z0-9._-]*) fail "REF_INVALIDE : PV_REF contient un caractère hors de [A-Za-z0-9._-] (une référence multi-ligne ou citée fabriquerait une clé dans le marqueur)" ;;
esac

# ── Garde 3 : LE DIGEST ─────────────────────────────────────────────────────
if [ "$TO_ENV" != "$AUTHORING_ENV" ]; then
  [ -n "$ARCHIVE_SHA256" ] \
    || fail "DIGEST_ABSENT : promotion vers '$TO_ENV' sans ARCHIVE_SHA256 — les octets déployés doivent être pinnés (sortie EXPORT_CONFIRMED)"
  case "$ARCHIVE_SHA256" in
    *[!0-9a-f]* | "") fail "DIGEST_MALFORMED : '$ARCHIVE_SHA256' n'est pas un sha256 hexadécimal minuscule" ;;
  esac
  [ "${#ARCHIVE_SHA256}" -eq 64 ] \
    || fail "DIGEST_MALFORMED : sha256 attendu sur 64 caractères, reçu ${#ARCHIVE_SHA256}"
fi

echo "GARDES_OK : $FROM_ENV -> $TO_ENV, groupe d'approbation='${APPROVER_GROUP:-<aucun>}'"
[ "${DRY_RUN:-0}" = 1 ] && exit 0

GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"   # dépôt PLATEFORME — porte providers.<env>.yml
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
printf 'Authorization: token %s\n' "$GITEA_TOKEN" > "$TMP/ghdr"
gapi() { curl -sS -H @"$TMP/ghdr" -H 'Content-Type: application/json' "$@"; }

# ── team -> repo, lu sur GITEA MAIN (jamais le worktree local) ───────────────
# Le worktree local peut être en retard, ou modifié : la seule source qui dit
# VRAIMENT « ce dépôt appartient à cette équipe » est providers.<env>.yml sur
# main du dépôt plateforme (même discipline que team-publish.sh §3).
# ⚠ DEUX PIÈGES ICI, MESURÉS TOUS LES DEUX.
#
# (1) LE CHEMIN. `providers.<env>.yml` ne vit pas à la racine du dépôt
#     plateforme mais sous `poc-control-plane-federation/` — c'est ce que
#     lisent les scripts frères. Sans ce préfixe, chaque exécution hors
#     DRY_RUN tape un 404 et le chemin nominal est mort.
#
# (2) `curl -s` REND 0 SUR UN 404. Le `|| fail` ci-dessous ne se déclencherait
#     donc jamais : le corps d'erreur JSON de Gitea atterrirait dans le
#     fichier, `yaml.safe_load` le parserait sans broncher (JSON ⊂ YAML),
#     `providers` vaudrait None — et l'opérateur lirait « équipe absente de
#     providers » alors qu'elle y est. Un chemin cassé, un hôte injoignable,
#     un token périmé et un dépôt privé se présenteraient TOUS comme un défaut
#     de déclaration d'équipe. C'est la classe de panne que ce dépôt a déjà
#     payée — une variable vide, une branche plausible, un verdict trompeur —
#     ici en refus trompeur. `--fail-with-body` rend le statut HTTP au shell.
gapi --fail-with-body --max-time 20 \
  "${GIT_HOST}/api/v1/repos/${GIT_REPO}/raw/poc-control-plane-federation/ansible/providers.${AUTHORING_ENV}.yml" \
  > "$TMP/providers.yml" \
  || fail "LECTURE_PROVIDERS : poc-control-plane-federation/ansible/providers.${AUTHORING_ENV}.yml illisible sur ${GIT_REPO}@main (HTTP non-2xx, hote injoignable ou token refuse)"
REPO_FULL=$(TEAM="$TEAM" PROV="$TMP/providers.yml" python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["PROV"])) or {}
e = next((p for p in (d.get("providers") or []) if p.get("team") == os.environ["TEAM"]), None)
if e is None:
    sys.exit("TEAM_NOT_FOUND")
print("REPO=" + (e.get("repo") or ""))
PY
) || fail "REPO_NON_DECLARE : équipe '$TEAM' absente de providers.${AUTHORING_ENV}.yml"
case "$REPO_FULL" in REPO=*) REPO_FULL="${REPO_FULL#REPO=}";; *) fail "PARSE_PROVIDERS : sortie inattendue";; esac
[ -n "$REPO_FULL" ] || fail "REPO_NON_DECLARE : équipe '$TEAM' sans dépôt dans providers.${AUTHORING_ENV}.yml"

# ── clone du dépôt d'équipe (authentifié — un dépôt privé casserait sinon) ───
AUTH_B64=$(printf 'x:%s' "$GITEA_TOKEN" | base64 | tr -d '\n')
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
       GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}"
unset AUTH_B64
git clone -q "${GIT_HOST}/${REPO_FULL}.git" "$TMP/team" \
  || fail "CLONE_ECHEC : ${REPO_FULL}"

# ── Garde 4 : LE PALIER SOURCE PORTE-T-IL QUELQUE CHOSE ? ───────────────────
# Depuis l'env d'authoring, c'est la présence du manifeste de publication qui
# en tient lieu : dev n'a PAS de marqueur, par conception.
if [ "$FROM_ENV" = "$AUTHORING_ENV" ]; then
  [ -f "$TMP/team/apis/${API_NAME}.publish.yml" ] \
    || fail "SOURCE_NON_DEPLOYEE : apis/${API_NAME}.publish.yml absent de ${REPO_FULL} — rien à promouvoir depuis '$FROM_ENV'"
fi
# Hors env d'authoring, l'etat du palier source est verifie par
# resolve_promotion_pin ci-dessous — c'est LUI qui lit le marqueur, une seule
# fois. Dupliquer cette lecture ici ferait deriver les deux copies.

# ── LE PIN : ce que le palier SOURCE execute ────────────────────────────────
# Depuis dev (env d'authoring, sans marqueur) : le dernier commit de main
# touchant CETTE API. Au-dela : le pin ET le digest du marqueur SOURCE, pour
# qu'un saut promeuve ce que le palier precedent sert reellement — la lettre du
# GOAL, « chaque palier recevant exactement l'archive approuvee et pas le
# dernier main ». La logique vit dans la bibliotheque parce qu'elle s'y eprouve
# hors ligne ; ici elle serait dans le chemin post-DRY_RUN, que rien ne teste.
resolve_promotion_pin "$TMP/team" "$API_NAME" "$FROM_ENV" \
  || fail "PIN_NON_RESOLU : impossible de determiner ce que '$FROM_ENV' execute pour ${API_NAME} (voir le refus nomme ci-dessus)"
PIN="$DEPLOY_PROMO_PIN"
VERSION="$DEPLOY_PROMO_VERSION"

# LE DIGEST. Depuis dev il vient du formulaire (sortie EXPORT_CONFIRMED) ; au
# dela il est HERITE du palier source, et le formulaire ne peut pas le
# contredire — sinon le demandeur substituerait les octets en cours de route,
# ce que tout ce jalon existe pour empecher.
ARCHIVE_SHA256=$(reconcile_promotion_digest "$ARCHIVE_SHA256" "$DEPLOY_PROMO_SHA256") \
  || fail "DIGEST_CONTREDIT_SOURCE : le digest du formulaire contredit celui que '$FROM_ENV' execute (voir le refus nomme ci-dessus)"

# ── branche, marqueur, commit, push, PR ─────────────────────────────────────
BRANCH="promote/${API_NAME}-${TO_ENV}"
MARKER="$(deploy_pin_marker_path "$API_NAME" "$TO_ENV")"
git -C "$TMP/team" checkout -q -b "$BRANCH"
# ⚠ LE MARQUEUR S'ÉCRIT AVEC UN SÉRIALISEUR, IL NE SE FORMATE PAS.
#
# Un `%`-formatage laisse chaque valeur libre d'ouvrir une NOUVELLE LIGNE dans
# le YAML, et PyYAML applique « le dernier gagne » sur les clés dupliquées.
# Reproduit en revue : un `change_ref` valant
#     x"\ncommit: <40 hex>\nzz: "y
# produit un marqueur qui PARSE PROPREMENT et dont le `commit` est celui que le
# DEMANDEUR a choisi — pas celui que la ligne `git log` a calculé. C'est
# exactement l'invariant que deploy-pin.sh existe pour tenir : « le pin
# déplacerait la confiance du MERGE vers un champ que le demandeur remplit
# lui-même ». Même faille, moindre portée, pour `promoted_by` (non quoté,
# `ci\nenabled: false` fabrique une clé que le demandeur choisit — la FAILLE
# est réelle, sa conséquence beaucoup moins : rien ne lit `enabled` sur le
# marqueur d'ARRIVÉE, cf. le gabarit) et pour
# `message` (dont l'échappement `"` -> `'` ne couvrait pas l'antislash, donc
# une PR s'ouvrait en portant un marqueur illisible que seul l'apply refusait).
#
# `safe_dump` ferme les trois d'un coup : il quote et échappe ce qu'il faut,
# et une valeur ne peut plus fabriquer de clé. La garde REF_INVALIDE ci-dessus
# ferme déjà CHANGE_REF/PV_REF en amont ; celle-ci est le second verrou,
# indépendant, sur le point d'écriture lui-même.
MSG="$MESSAGE" PB="${PROMOTED_BY:-ci}" V="$VERSION" P="$PIN" CR="$CHANGE_REF" \
  SH="$ARCHIVE_SHA256" OUT="$TMP/team/$MARKER" python3 - <<'PY'
import os
import yaml

with open(os.environ["OUT"], "w") as f:
    yaml.safe_dump({
        "version": os.environ["V"],
        "enabled": True,
        "promoted_by": os.environ["PB"],
        "message": os.environ["MSG"],
        "commit": os.environ["P"],
        "change_ref": os.environ["CR"],
        "archive_sha256": os.environ["SH"],
    }, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
PY
# Sans cette garde, un échec d'écriture (disque plein, chemin impossible) ne
# se voit qu'au commit suivant, sous la forme trompeuse « COMMIT_VIDE : le
# marqueur est déjà à cette valeur ». Nommer la vraie cause.
[ -s "$TMP/team/$MARKER" ] \
  || fail "MARQUEUR_NON_ECRIT : $MARKER vide ou absent après sérialisation"
git -C "$TMP/team" add "$MARKER"
git -C "$TMP/team" -c user.name=ci -c user.email=ci@stoa.lab \
  commit -qm "promote(${API_NAME}): ${FROM_ENV} -> ${TO_ENV} @ ${PIN}" \
  || fail "COMMIT_VIDE : le marqueur est déjà à cette valeur (rien à promouvoir)"
git -C "$TMP/team" push -q origin "$BRANCH" || fail "PUSH_ECHEC : $BRANCH sur $REPO_FULL"

PR_URL=$(API="${GIT_HOST}/api/v1" R="$REPO_FULL" B="$BRANCH" \
  T="promote(${API_NAME}): ${FROM_ENV} → ${TO_ENV}" \
  BODY="Marqueur \`${MARKER}\` — pin \`${PIN}\`, sha256 \`${ARCHIVE_SHA256:-<authoring>}\`.

La DÉCISION est le merge de cette PR (ADR-081). Groupe d'approbation ATTENDU : \`${APPROVER_GROUP:-<aucun>}\` — attendu, **pas vérifié** : rien sur ce chemin ne contrôle qui approuve (jalon G4).

⚠ **Ce merge n'applique rien aujourd'hui.** Le job post-merge du dépôt d'équipe ne publie que les branches \`api/*\` ; celle-ci est \`${BRANCH}\`, donc le build passera au vert sans rien déployer. Le marqueur est posé pour être consommé quand G4 (verrou dev-only) et G5 (verbe archive) auront ouvert le palier." \
  HDR="$TMP/ghdr" python3 - <<'PY'
import json, os, urllib.request
h = dict(l.split(": ", 1) for l in open(os.environ["HDR"]).read().splitlines() if l)
h["Content-Type"] = "application/json"
req = urllib.request.Request(
    f"{os.environ['API']}/repos/{os.environ['R']}/pulls", method="POST",
    data=json.dumps({"head": os.environ["B"], "base": "main",
                     "title": os.environ["T"], "body": os.environ["BODY"]}).encode(),
    headers=h)
print(json.load(urllib.request.urlopen(req))["html_url"])
PY
) || fail "PR_ECHEC : ouverture de la PR sur $REPO_FULL"
echo "PROMOTION_DEMANDEE : $PR_URL"
