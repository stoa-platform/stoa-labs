#!/usr/bin/env bash
# api-promote-request.sh — moteur du formulaire « promouvoir une API »
# (jalon G3). Pendant de api-request.sh (publication) : MÊME MODÈLE STRUCTUREL
# — gardes nommées AVANT tout geste Git, team -> repo lu sur GITEA MAIN (jamais
# le worktree local), push par GIT_CONFIG_COUNT/KEY_0/VALUE_0 (jamais de token
# en URL ni en argv), PR par heredoc python, plan commenté sur la PR.
#
# CE SCRIPT NE DÉPLOIE RIEN. Il ouvre une PR portant le marqueur
# apis/<name>.deploy.<TO_ENV>.yaml. La DÉCISION est le merge (ADR-081) ; la
# PORTE (4-yeux, ITSM, groupe d'approbation) est enforcée à l'apply par
# labctl/governance-api, PAS ici — les gardes ci-dessous sont in-repo, donc
# justiciables d'OWASP CICD-SEC-04 : elles rendent le refus LISIBLE TÔT, elles
# ne le rendent pas INCONTOURNABLE. La fermeture réelle est le jalon G4
# (rétention du credential par palier).
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

# shellcheck source=lib/env-chain.sh
. scripts/lib/env-chain.sh
# shellcheck source=lib/deploy-pin.sh
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
AUTHORING_ENV="${DEPLOY_PIN_AUTHORING_ENV:-dev}"

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
# Refusé À LA DEMANDE, jamais découvert à l'approbation — miroir de
# handlers_promotions.go:77-89. itsmCheck IMPLIQUE change_ref : il n'y a rien à
# re-vérifier auprès de l'ITSM sans une référence.
GATE=$(env_chain_gate "$TO_ENV") || fail "PARSE_GATE : lecture de la porte vers '$TO_ENV'"
case "$GATE" in GATE=*) GATE="${GATE#GATE=}";; *) fail "PARSE_GATE : sortie inattendue";; esac
NEED_CHANGE="${GATE%%|*}"; GATE="${GATE#*|}"
NEED_PV="${GATE%%|*}"; APPROVER_GROUP="${GATE#*|}"

[ "$NEED_CHANGE" = 0 ] || [ -n "$CHANGE_REF" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$TO_ENV' exige une référence de changement (CHANGE_REF)"
[ "$NEED_PV" = 0 ] || [ -n "$PV_REF" ] \
  || fail "GATE_REFS_REQUIRED : la porte vers '$TO_ENV' exige une référence de PV de recette (PV_REF)"

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
echo "GESTE_GIT_NON_IMPLEMENTE : voir Task 8" >&2
exit 1
