#!/usr/bin/env bash
# diagnose-vault.sh — DIAGNOSTIC autonome de la chaîne pipeline → Vault, à lancer
# CHEZ LE CLIENT pour localiser « est-ce MA config ou LA LEUR qui plante ».
#
# Rejoue, une étape à la fois, ce que le pipeline fait — et dit à CHAQUE étape si
# ça passe, et sinon POURQUOI (code HTTP + message d'erreur de Vault). AUCUN secret
# n'est imprimé : mot de passe/token jamais affichés, corps de réponse jamais
# affichés (seuls les messages d'erreur, rédactés, le sont).
#
# Il s'appuie sur la MÊME lib que le pipeline (ci/lib/vault-login.sh) : ce qui
# passe ici passe dans le CI, et inversement — pas une ré-implémentation qui
# pourrait diverger.
#
# Usage (les mêmes variables que le pipeline) :
#   VAULT_ADDR=https://vault.corp:8200 \
#   VAULT_USER_AUTH_MOUNT=ldap \
#   VAULT_USER='alice@corp' VAULT_USER_PASSWORD='...' \
#   [VAULT_NAMESPACE=banque/apim] [VAULT_CACERT=/etc/pki/corp-ca.pem] \
#   [APIM_WM_CREDS_SUB=deploy/<tenant>/wm-admin] \
#   bash scripts/diagnose-vault.sh
#
# Le mot de passe peut aussi venir d'un fichier (VAULT_USER_PASS_FILE) pour ne pas
# le poser en variable d'environnement.
set -uo pipefail
cd "$(dirname "$0")/.."

VADDR="${VAULT_ADDR:-http://localhost:8200}"
SUB="${APIM_WM_CREDS_SUB:-deploy/banking-demo/wm-admin}"
KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
PREFIX="${VAULT_PREFIX:-stoa}"
export STOA_DEBUG=1   # la lib trace chaque appel (rédacté)

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓ %s\033[0m\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
warn() { WARN=$((WARN+1)); printf '  \033[33m! %s\033[0m\n' "$1"; }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# curl rédacté pour les sondes hors-lib (health, sys/mounts).
dcurl() { curl -s "$@"; }

sec "0. Contexte (ce que je vais utiliser)"
echo "   VAULT_ADDR           = $VADDR"
echo "   VAULT_USER_AUTH_MOUNT = ${VAULT_USER_AUTH_MOUNT:-ldap}"
echo "   VAULT_USER           = ${VAULT_USER:-${VAULT_LDAP_USER:-<non fourni>}}"
echo "   VAULT_NAMESPACE      = ${VAULT_NAMESPACE:-<aucun>}"
echo "   VAULT_CACERT         = ${VAULT_CACERT:-${LABCTL_CA_FILE:-<système>}}"
echo "   secret ciblé         = ${KV_MOUNT}/data/${PREFIX}/${SUB}"

sec "1. Vault est-il JOIGNABLE ? (réseau + TLS)"
NSARG=""; [ -n "${VAULT_NAMESPACE:-}" ] && NSARG="-H X-Vault-Namespace:${VAULT_NAMESPACE}"
CA="${VAULT_CACERT:-${LABCTL_CA_FILE:-}}"; CAARG=""; [ -n "$CA" ] && [ -f "$CA" ] && CAARG="--cacert $CA"
# shellcheck disable=SC2086
H=$(dcurl -o /tmp/diag-h.json -w '%{http_code}' $NSARG $CAARG "$VADDR/v1/sys/health" 2>/tmp/diag-h.err)
case "$H" in
  200|429|472|473|501|503) ok "sys/health répond (HTTP $H) — Vault joignable" ;;
  000) bad "sys/health INJOIGNABLE (curl: $(tr -d '\n' </tmp/diag-h.err | tail -c 120))"
       echo "       → réseau bloqué, mauvaise URL, ou TLS (CA ?). RIEN d'autre ne marchera tant que ceci échoue." ;;
  *)   warn "sys/health HTTP $H (inattendu mais joignable)" ;;
esac
[ "$H" = 000 ] && { echo; echo "STOP : Vault injoignable — corriger le réseau/URL/TLS d'abord."; exit 1; }

sec "2. Le MOUNT d'auth existe-t-il ? (la moitié config-Vault, côté client)"
MOUNT_N="$(printf 'auth/%s' "${VAULT_USER_AUTH_MOUNT:-ldap}" | sed 's#^auth/auth/#auth/#; s#/$##')"
# On sonde SANS token (le diag tourne avant login) : un login bidon. ⚠ Vault
# renvoie le MÊME 403 pour un mount ABSENT que pour un mount présent-mais-qui-
# -rejette — on ne peut donc PAS trancher sur 403. Seul un 400 (le mount a tenté
# de traiter la requête, p.ex. bind LDAP) prouve qu'il existe. Message honnête.
# shellcheck disable=SC2086
MH=$(dcurl -o /dev/null -w '%{http_code}' $NSARG $CAARG -X POST "$VADDR/v1/$MOUNT_N/login/__diag_probe__" -d '{"password":"x"}' 2>/dev/null)
case "$MH" in
  400|200) ok "le mount '$MOUNT_N' EXISTE et traite les requêtes (HTTP $MH sur un login bidon)" ;;
  403|401) warn "mount '$MOUNT_N' → HTTP $MH : AMBIGU — soit le mount n'existe pas, soit il rejette la sonde."
           echo "       → confirmer le nom EXACT du mount avec l'équipe Vault (VAULT_USER_AUTH_MOUNT)."
           echo "       → si l'étape 3 (login) échoue aussi en 403, le mount absent est l'explication la plus probable." ;;
  404) bad "le mount '$MOUNT_N' est ABSENT (HTTP 404) — point de CONFIG VAULT côté client (nom du mount ?)" ;;
  000) bad "mount injoignable (TLS/namespace ?)" ;;
  *)   warn "mount '$MOUNT_N' → HTTP $MH (à interpréter)" ;;
esac

sec "3. LOGIN avec l'identité fournie (le cœur de la voie A)"
if [ -z "${VAULT_USER:-${VAULT_LDAP_USER:-}}" ]; then
  warn "VAULT_USER non fourni — étape login SAUTÉE. (Fournir VAULT_USER pour la tester.)"
else
  # SAISIE SÛRE du mot de passe : si aucun n'est déjà fourni (env/fichier), on le
  # demande avec `read -s` — qui lit l'entrée VERBATIM, SANS aucune interprétation
  # shell. C'est LA parade aux caractères spéciaux : `$$` (PID), `$x` (variable),
  # `*` (glob) ne sont JAMAIS interprétés. Évite tout problème de guillemets.
  if [ -z "${VAULT_USER_PASSWORD:-${VAULT_USER_PASS:-${VAULT_LDAP_PASS:-}}}" ] \
     && [ -z "${VAULT_USER_PASS_FILE:-${VAULT_LDAP_PASS_FILE:-}}" ]; then
    if [ -t 0 ]; then
      printf 'Mot de passe pour %s (saisie masquée, aucun caractère interprété) : ' \
        "${VAULT_USER:-$VAULT_LDAP_USER}" >&2
      read -rs VAULT_USER_PASSWORD; echo >&2
      export VAULT_USER_PASSWORD
      _dbg_len=$(printf '%s' "$VAULT_USER_PASSWORD" | wc -c | tr -d ' ')
      echo "   (mot de passe saisi : $_dbg_len octets — compare au besoin avec: printf %%s '…' | shasum -a 256)"
    else
      warn "aucun mot de passe fourni et pas de terminal pour le saisir — login SAUTÉ."
      warn "  → fournir VAULT_USER_PASS_FILE=<fichier 0600> (recommandé pour \$ * @), ou VAULT_USER_PASSWORD en guillemets SIMPLES."
    fi
  fi
  # shellcheck disable=SC1091
  . ci/lib/vault-login.sh
  RC=0; vault_login_nominative || RC=$?
  case "$RC" in
    0) ok "login ACCEPTÉ — token nominatif obtenu (détails ci-dessus)"
       sec "4. LECTURE du secret de déploiement (la policy couvre-t-elle le chemin ?)"
       if vault_read "${KV_MOUNT}/data/${PREFIX}/${SUB}" username >/dev/null 2>&1 \
          || vault_read "${KV_MOUNT}/data/${PREFIX}/${SUB}" client_id >/dev/null 2>&1; then
         ok "lecture de ${PREFIX}/${SUB} OK — la policy du token couvre ce chemin"
       else
         bad "lecture de ${PREFIX}/${SUB} REFUSÉE — voir le code ci-dessus (403=policy, 404=chemin absent)"
         echo "       → 403 : la policy du token ne couvre pas ce chemin (config Vault : mapping groupe→policy)."
         echo "       → 404 : le secret n'existe pas encore à ce chemin (a-t-il été provisionné ?)."
       fi
       vault_revoke_proof >/dev/null 2>&1 || true ;;
    1) bad "login REFUSÉ — voir le code HTTP + le message Vault ci-dessus"
       echo "       → 'failed to bind' / 400 : mauvais mot de passe, ou format de login (sAMAccountName/UPN/DOMAIN\\user), ou config du mount."
       echo "       → 403 : le mount existe mais refuse (bind du compte de service Vault ? filtre ?)."
       echo "       → distinguer MA config (VAULT_USER/format/mount) de LA LEUR (bind/annuaire) via le message exact ci-dessus." ;;
    2) warn "aucune identité résolue (ni JWT ni user/pwd) — rien à tester" ;;
  esac
fi

sec "RÉSULTAT"
printf '  %d OK, %d échec(s), %d avertissement(s)\n' "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✓ la chaîne pipeline→Vault est saine de bout en bout avec cette config."
else
  echo "  ✗ voir les ✗ ci-dessus : le message d'erreur de CHAQUE étape localise la faute (MA config vs config Vault client)."
fi
rm -f /tmp/diag-h.json /tmp/diag-h.err
[ "$FAIL" -eq 0 ]
