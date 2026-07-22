#!/usr/bin/env bash
# ci/lib/vault-login.sh — login NOMINATIF à Vault depuis un pipeline, à SOURCER.
#
# Une seule implémentation d'auth pour les 4 Jenkinsfiles (ADR-078 §2) : le shell
# obtient le token UNE fois, l'écrit dans un fichier 0600 et exporte
# VAULT_TOKEN_FILE ; tout l'aval (rôles Ansible, labctl) le consomme déjà en tête
# de précédence. Dupliquer le login dans le rôle ET dans le binaire ferait trois
# surfaces d'auth à auditer pour zéro gain.
#
# Deux voies d'identité humaine (ADR-078 §3), dans cet ordre :
#   B. USER_VAULT_JWT       -> auth/jwt/login        (Keycloak, exchange RFC 8693, ADR-077)
#   A. VAULT_USER + mot de passe -> auth/<mount>/login/<user>  (LDAP/AD client, userpass lab)
# Aucune des deux fournie => code de retour 2 : l'appelant fait un PLAN-only (un
# build webhook tourne en ACL.SYSTEM et ne porte AUCUN humain — JENKINS-44772).
#
# INVARIANTS DE SECRET (chacun a une contre-épreuve dans scripts/test-vault-user-login.sh)
#   - le mot de passe et le token ne passent JAMAIS en argv  -> ps / /proc/<pid>/cmdline ;
#   - le corps JSON est produit par python3 (json.dumps), JAMAIS forgé en shell : un
#     mot de passe bancaire contenant " \ $ casserait le JSON *et* pourrait s'injecter ;
#   - le user part URL-ENCODÉ dans le path (`CORP\alice` -> CORP%5Calice, UPN -> %40) ;
#   - le token Vault est passé à curl par FICHIER d'en-têtes (curl -H @fichier) ;
#   - le mot de passe est UNSET après le login : le process Ansible enfant ne l'hérite pas ;
#   - le token est révoqué à la sortie MÊME si le build échoue (trap), avec PREUVE DE MORT.
#
# Usage type dans un Jenkinsfile (sh '''…'''), toujours sous `set +x` :
#     . ci/lib/vault-login.sh
#     trap vault_trap_revoke EXIT          # AVANT le login : révoque même si ça rate
#     RC=0; vault_login_nominative || RC=$?
#     [ "$RC" = 0 ] || { [ "$RC" = 2 ] && exit 0; exit 1; }   # 2 = pas d'humain -> plan-only
#     ansible-playbook …                   # lit VAULT_TOKEN_FILE
# NB : `RC=0; cmd || RC=$?` et NON `if ! cmd; then RC=$?` — après un `!`, $? vaut 0
# (la négation a réussi) et le code de retour de la fonction est perdu.
#
# Env : VAULT_ADDR (requis) · VAULT_NAMESPACE (Vault Enterprise) · VAULT_CACERT ou
#       LABCTL_CA_FILE (CA d'entreprise) · VAULT_USER_AUTH_MOUNT (défaut `ldap`) ·
#       VAULT_JWT_ROLE (défaut `user-deploy`) · VAULT_USER_PASSWORD | VAULT_USER_PASS_FILE.

_VAULT_TMPDIR=""
_VAULT_REVOKED=0

# _vault_cleanup — efface les fichiers temporaires (jamais le token en clair sur disque
# une fois le build fini). Appelé par vault_trap_revoke.
_vault_cleanup() {
  if [ -n "$_VAULT_TMPDIR" ] && [ -d "$_VAULT_TMPDIR" ]; then
    rm -rf "$_VAULT_TMPDIR"
  fi
  _VAULT_TMPDIR=""
}

# _vault_curl <fichier-sortie> <méthode> <url> [args curl…] -> imprime le code HTTP.
# Pose systématiquement le namespace et la CA d'entreprise s'ils sont configurés.
_vault_curl() {
  local out="$1" method="$2" url="$3"
  shift 3
  local args=(-s -o "$out" -w '%{http_code}' -X "$method" "$url")
  if [ -n "${VAULT_NAMESPACE:-}" ]; then
    args+=(-H "X-Vault-Namespace: ${VAULT_NAMESPACE}")
  fi
  local ca="${VAULT_CACERT:-${LABCTL_CA_FILE:-}}"
  if [ -n "$ca" ] && [ -f "$ca" ]; then
    args+=(--cacert "$ca")
  fi
  curl "${args[@]}" "$@"
}

# _vault_mount — normalise VAULT_USER_AUTH_MOUNT : `ldap`, `auth/ldap` et
# `auth/ldap/` donnent tous `auth/ldap`. Chez le client ce peut être auth/ad,
# auth/ldap-corp… ; en lab c'est auth/userpass. Même requête REST dans les 3 cas.
_vault_mount() {
  local m="${VAULT_USER_AUTH_MOUNT:-ldap}"
  m="${m#auth/}"
  m="${m%/}"
  printf 'auth/%s' "$m"
}

# _vault_store_token <fichier-réponse> — extrait auth.client_token de la réponse et
# écrit (0600) le token brut + le fichier d'en-tête pour curl. Le token ne transite
# par AUCUNE variable shell ni argv : python3 lit et écrit les fichiers lui-même.
_vault_store_token() {
  python3 - "$1" "$_VAULT_TMPDIR/token" "$_VAULT_TMPDIR/token.hdr" <<'PY'
import json, os, sys
resp, tokf, hdrf = sys.argv[1], sys.argv[2], sys.argv[3]
with open(resp) as fh:
    tok = json.load(fh)["auth"]["client_token"]
if not tok:
    sys.exit("client_token vide")
for path, text in ((tokf, tok), (hdrf, "X-Vault-Token: %s\n" % tok)):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
PY
}

# vault_login_nominative — obtient un token Vault NOMINATIF et exporte VAULT_TOKEN_FILE.
#   0 = token obtenu · 1 = identité fournie mais REFUSÉE (fail-closed) · 2 = aucune
#   identité fournie (l'appelant doit faire un PLAN-only, pas un apply).
vault_login_nominative() {
  : "${VAULT_ADDR:?VAULT_ADDR est requis}"
  local jwt="${USER_VAULT_JWT:-}" user="${VAULT_USER:-${VAULT_LDAP_USER:-}}"
  jwt="$(printf '%s' "$jwt" | tr -d '[:space:]')"

  if [ -z "$jwt" ] && [ -z "$user" ]; then
    return 2
  fi

  _VAULT_TMPDIR="$(mktemp -d)"
  chmod 700 "$_VAULT_TMPDIR"
  local body="$_VAULT_TMPDIR/body.json" resp="$_VAULT_TMPDIR/resp.json" code url

  if [ -n "$jwt" ]; then
    # ── Voie B (ADR-077) : JWT court aud=vault issu du token exchange Keycloak ──
    url="$VAULT_ADDR/v1/auth/jwt/login"
    JWT="$jwt" ROLE="${VAULT_JWT_ROLE:-user-deploy}" python3 - "$body" <<'PY'
import json, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump({"role": os.environ["ROLE"], "jwt": os.environ["JWT"]}, fh)
PY
  else
    # ── Voie A : user/mot de passe (LDAP/AD chez le client, userpass en lab) ────
    # Le mot de passe vient d'un FICHIER 0600 de préférence ; le paramètre de build
    # Jenkins (VAULT_USER_PASSWORD) est accepté et immédiatement retiré de l'env.
    local passfile="${VAULT_USER_PASS_FILE:-${VAULT_LDAP_PASS_FILE:-}}"
    if [ -n "$passfile" ] && [ -f "$passfile" ]; then
      VAULT_USER_PASSWORD="$(cat "$passfile")"
    fi
    VAULT_USER_PASSWORD="${VAULT_USER_PASSWORD:-${VAULT_USER_PASS:-${VAULT_LDAP_PASS:-}}}"
    if [ -z "$VAULT_USER_PASSWORD" ]; then
      echo "  ✗ VAULT_USER=$user fourni SANS mot de passe (VAULT_USER_PASSWORD / VAULT_USER_PASS_FILE)" >&2
      return 1
    fi
    # json.dumps échappe " \ $ et l'unicode — ne jamais forger ce corps en shell.
    export VAULT_USER_PASSWORD
    python3 - "$body" <<'PY'
import json, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump({"password": os.environ["VAULT_USER_PASSWORD"]}, fh)
PY
    # Le mot de passe a fini son office : il ne doit PAS être hérité par ansible-playbook.
    unset VAULT_USER_PASSWORD VAULT_USER_PASS VAULT_LDAP_PASS
    url="$VAULT_ADDR/v1/$(_vault_mount)/login/$(VU="$user" python3 -c \
        'import os,urllib.parse;print(urllib.parse.quote(os.environ["VU"], safe=""))')"
  fi

  # Le corps part par FICHIER (--data-binary @) : jamais en argv.
  code="$(_vault_curl "$resp" POST "$url" -H 'Content-Type: application/json' --data-binary "@$body" || true)"
  rm -f "$body"

  if [ "$code" != "200" ]; then
    if [ -n "$jwt" ]; then
      echo "  ✗ auth/jwt/login REFUSÉ (HTTP $code) — JWT expiré (TTL 5 min), audience ou rôle ${VAULT_JWT_ROLE:-user-deploy} ?" >&2
    else
      echo "  ✗ $(_vault_mount)/login REFUSÉ (HTTP $code). Vérifier : le MOUNT (VAULT_USER_AUTH_MOUNT), le FORMAT" >&2
      echo "    de login attendu par l'annuaire (sAMAccountName / UPN user@domaine / DOMAIN\\user)," >&2
      echo "    le mot de passe, et VAULT_NAMESPACE si Vault Enterprise." >&2
      echo "    ⚠ NE PAS relancer en boucle : la politique de lockout AD verrouille le compte après N échecs." >&2
    fi
    _vault_cleanup
    return 1
  fi

  _vault_store_token "$resp" || { _vault_cleanup; return 1; }
  rm -f "$resp"
  export VAULT_TOKEN_FILE="$_VAULT_TMPDIR/token"

  # lookup-self : QUI est cette identité, et pour combien de temps. Le token part en
  # fichier d'en-têtes (curl -H @) — jamais en argv.
  code="$(_vault_curl "$resp" GET "$VAULT_ADDR/v1/auth/token/lookup-self" -H "@$_VAULT_TMPDIR/token.hdr" || true)"
  if [ "$code" = "200" ]; then
    # entity_id = le PIVOT de corrélation entre l'audit Vault, le log Jenkins et
    # l'audit gateway (ADR-078 §3 : l'imputabilité de bout en bout n'existe que par
    # corrélation, la gateway ne voyant que le compte de service).
    python3 - "$resp" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["data"]
print("  ✓ token Vault NOMINATIF — entité=%s  entity_id=%s  ttl=%ss  policies=%s"
      % (d.get("display_name", "?"), d.get("entity_id", "-"), d.get("ttl", "?"),
         ",".join(d.get("policies", []))))
PY
  fi
  rm -f "$resp"
  echo "  ✓ le job ne détient AUCUN credential propre — le token meurt avec le build"
  return 0
}

# vault_login_approle — identité de MACHINE (ADR-074) : role_id public + secret_id
# court. À n'utiliser QUE là où aucun humain n'existe (build webhook = ACL.SYSTEM).
# Le token obtenu N'EST PAS nominatif : aucun acte ne peut être imputé à quelqu'un.
# Env : VAULT_ROLE_ID + (VAULT_SECRET_ID_FILE > VAULT_SECRET_ID).
vault_login_approle() {
  : "${VAULT_ADDR:?VAULT_ADDR est requis}"
  local sid="${VAULT_SECRET_ID:-}"
  if [ -n "${VAULT_SECRET_ID_FILE:-}" ] && [ -f "${VAULT_SECRET_ID_FILE}" ]; then
    sid="$(cat "$VAULT_SECRET_ID_FILE")"
  fi
  if [ -z "${VAULT_ROLE_ID:-}" ] || [ -z "$sid" ]; then
    return 2
  fi

  _VAULT_TMPDIR="$(mktemp -d)"
  chmod 700 "$_VAULT_TMPDIR"
  local body="$_VAULT_TMPDIR/body.json" resp="$_VAULT_TMPDIR/resp.json" code
  RID="$VAULT_ROLE_ID" SID="$sid" python3 - "$body" <<'PY'
import json, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump({"role_id": os.environ["RID"], "secret_id": os.environ["SID"]}, fh)
PY
  unset sid VAULT_SECRET_ID
  code="$(_vault_curl "$resp" POST "$VAULT_ADDR/v1/auth/approle/login" \
          -H 'Content-Type: application/json' --data-binary "@$body" || true)"
  rm -f "$body"
  if [ "$code" != "200" ]; then
    echo "  ✗ auth/approle/login REFUSÉ (HTTP $code) — secret_id expiré ou role_id d'une autre instance Vault ?" >&2
    _vault_cleanup
    return 1
  fi
  _vault_store_token "$resp" || { _vault_cleanup; return 1; }
  rm -f "$resp"
  export VAULT_TOKEN_FILE="$_VAULT_TMPDIR/token"
  return 0
}

# vault_login_any — nominatif d'abord, AppRole en repli. Dit TOUJOURS à voix haute
# laquelle des deux a servi : un log qui ne distingue pas « acte d'un humain » de
# « acte d'une machine » ruine l'imputabilité que toute la chaîne cherche à établir.
#   0 = token obtenu · 1 = échec · 2 = aucune identité d'aucune sorte.
vault_login_any() {
  local rc=0
  vault_login_nominative || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;   # identité humaine fournie mais REFUSÉE -> ne pas retomber sur la machine
  esac
  rc=0                      # remis à 0 : sinon le 2 du login nominatif survit au succès AppRole
  vault_login_approle || rc=$?
  if [ "$rc" = 0 ]; then
    echo "  ⚠ identité NON NOMINATIVE (AppRole) : cet acte n'est imputable à AUCUN humain."
    echo "    Fournir VAULT_USER + mot de passe pour un token nominatif (voie A, ADR-078 §3)."
    return 0
  fi
  return "$rc"
}

# vault_read <chemin-v1> <champ> — lit un champ d'un secret KV v2 et l'imprime.
# Le token part par fichier d'en-têtes (jamais en argv, contrairement à un
# `-H "X-Vault-Token: $TOK"`) et l'extraction est un parse JSON, pas un `sed` :
# un `sed` sur du JSON casse dès qu'un champ change d'ordre ou contient une quote.
vault_read() {
  local path="$1" field="$2" resp code
  if [ -z "$_VAULT_TMPDIR" ] || [ ! -f "$_VAULT_TMPDIR/token.hdr" ]; then
    echo "  ✗ vault_read appelé sans login préalable" >&2
    return 1
  fi
  resp="$_VAULT_TMPDIR/read.json"
  code="$(_vault_curl "$resp" GET "$VAULT_ADDR/v1/$path" -H "@$_VAULT_TMPDIR/token.hdr" || true)"
  if [ "$code" != "200" ]; then
    echo "  ✗ lecture $path REFUSÉE (HTTP $code) — la policy du token couvre-t-elle ce chemin ?" >&2
    rm -f "$resp"
    return 1
  fi
  FIELD="$field" python3 - "$resp" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
v = d.get("data", {}).get("data", {}).get(os.environ["FIELD"], "")
if not v:
    sys.exit("champ %s absent du secret" % os.environ["FIELD"])
print(v)
PY
  local rc=$?
  rm -f "$resp"
  return "$rc"
}

# vault_revoke_proof — révoque le token ET PROUVE sa mort (lookup-self doit répondre
# 403). Idempotent, sans effet si aucun login n'a eu lieu. 0 = révoqué et prouvé mort.
vault_revoke_proof() {
  if [ -z "$_VAULT_TMPDIR" ] || [ ! -f "$_VAULT_TMPDIR/token.hdr" ]; then
    return 0
  fi
  if [ "$_VAULT_REVOKED" = "1" ]; then
    return 0
  fi
  _VAULT_REVOKED=1
  local resp="$_VAULT_TMPDIR/revoke.json" code rc=0

  code="$(_vault_curl "$resp" POST "$VAULT_ADDR/v1/auth/token/revoke-self" -H "@$_VAULT_TMPDIR/token.hdr" || true)"
  if [ "$code" != "204" ] && [ "$code" != "200" ]; then
    echo "  ✗ revoke-self a échoué (HTTP $code) — le token nominatif survit jusqu'à son TTL" >&2
    rc=1
  fi
  # PREUVE DE MORT : un token révoqué DOIT être refusé. 403 = mort confirmée.
  code="$(_vault_curl "$resp" GET "$VAULT_ADDR/v1/auth/token/lookup-self" -H "@$_VAULT_TMPDIR/token.hdr" || true)"
  if [ "$code" = "403" ]; then
    echo "  ✓ token Vault révoqué — mort PROUVÉE (lookup-self -> 403)"
  else
    echo "  ✗ le token répond encore (lookup-self -> HTTP $code) : révocation NON prouvée" >&2
    rc=1
  fi

  unset VAULT_TOKEN_FILE
  _vault_cleanup
  return "$rc"
}

# vault_trap_revoke — à poser en `trap vault_trap_revoke EXIT` juste après le login.
# Révoque MÊME quand le build échoue (le revoke en dernière instruction sous `set -e`
# est sauté dès qu'une étape rate, et le token survit alors jusqu'à son TTL).
# Préserve le code de sortie d'origine ; ne rougit un build vert que si la révocation
# ou la preuve de mort a échoué.
vault_trap_revoke() {
  local rc=$?
  if ! vault_revoke_proof; then
    if [ "$rc" -eq 0 ]; then
      rc=1
    fi
  fi
  exit "$rc"
}
