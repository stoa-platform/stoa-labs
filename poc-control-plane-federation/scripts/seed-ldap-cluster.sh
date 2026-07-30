#!/bin/sh
# seed-ldap-cluster.sh — peuple l'annuaire de démonstration DU CLUSTER (ns ci).
#
# Pendant cluster de setup-vault-ldap.sh, qui visait le conteneur compose. Même
# arbre, mêmes noms, mêmes tenants : les deux mondes restent comparables.
#
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ ⚠⚠  NE PAS REJOUER CE SCRIPT SUR UN LAB DÉJÀ PROUVÉ. IL DÉSYNCHRONISE    ║
# ║      VAULT, ET LA RESYNCHRONISATION COÛTE UNE CÉRÉMONIE DE QUORUM.       ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# Ce script RÉGÉNÈRE les mots de passe d'alice, carol et oscar À CHAQUE PASSAGE
# (`genpw`, plus bas), puis réécrit DEUX choses : l'annuaire (empreintes SSHA) et
# le fichier root-only du nœud. Il n'écrit RIEN dans Vault — il ne le peut pas :
# la seule identité dont il dispose côté cluster est `jenkins-agent`, qui n'a que
# `read` sur `secret/data/ci/*`.
#
# Conséquence directe : `secret/ci/lab-users/{alice,carol,oscar}` garde les
# ANCIENNES valeurs. Le harnais test-voie-a-cluster.sh lit les mots de passe
# depuis Vault (amendement A.3) et les présente à l'annuaire, qui porte les
# NOUVEAUX : `login ldap/alice -> 400`. Un lab qui rendait 17/0/0 tombe, et rien
# dans le message d'erreur ne désigne ce script comme la cause.
#
# REMETTRE D'APLOMB exige d'ÉCRIRE dans `secret/ci/lab-users/*`, donc un jeton
# racine, donc une NOUVELLE CÉRÉMONIE DE QUORUM (2 parts de descellement sur 3)
# — cf. docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh, étape 7/7.
#
# Autrement dit : ces mots de passe sont jetables, mais leur SYNCHRONISATION ne
# l'est pas. « Perdre ces mots de passe, c'est relancer un script » (amendement
# A.2 du plan, corrigé depuis) est faux dans ce sens-là : c'est RELANCER LE
# SCRIPT qui casse l'état prouvé.
#
# AVANT DE LANCER, se demander : est-ce que je sème un annuaire NEUF (oui →
# allez-y), ou est-ce que je « rafraîchis » un lab qui marche (non → ne rien
# faire ; il n'y a rien à rafraîchir, ces valeurs n'expirent pas) ? Si un rejeu
# est réellement nécessaire, planifier la cérémonie de quorum DANS LA FOULÉE, et
# pas après avoir constaté la panne.
#
# (Le mot de passe de bob, lui, ne bouge jamais : c'est l'identifiant public
# assumé de lab-vault-users.sh, pas une valeur générée. bob survit au rejeu —
# c'est d'ailleurs pourquoi, après un rejeu, le harnais montre un bob qui passe
# à côté d'alice et carol qui échouent. Ce motif-là signe cette panne.)
#
# IDEMPOTENT AU SENS LDAP SEULEMENT : ldapadd renvoie 68 (« Already exists ») en
# re-run, ce qui est le cas NOMINAL et non une erreur. `-c` (continue) ajoute les
# entrées nouvelles et ignore les existantes. Idempotent ne veut PAS dire « sans
# effet » : la deuxième passe `ldapmodify … replace` réécrit les mots de passe.
#
# Les mots de passe sont GÉNÉRÉS ici et déposés dans un fichier root-only du nœud.
# Ils ne passent jamais par argv (visible dans ps) ni par stdout.
#
# Usage : depuis la racine de poc-control-plane-federation, kubeconfig du cluster.
#   KUBECONFIG=~/.kube/k3s-contabo.yaml sh scripts/seed-ldap-cluster.sh
set -eu

NS="${LDAP_NS:-ci}"
DEPLOY="${LDAP_DEPLOY:-deploy/openldap}"
BASE_DN="${LDAP_BASE_DN:-dc=corp,dc=example}"
BIND_DN="${LDAP_BIND_DN:-cn=admin,$BASE_DN}"
SECRETS_HOST="${SECRETS_HOST:-worker-1}"
SECRETS_DIR="${SECRETS_DIR:-/root/stoa-lab-secrets}"

. "$(dirname "$0")/lib/lab-vault-users.sh"

say() { printf '  %s\n' "$1"; }
die() { printf 'ÉCHEC : %s\n' "$1" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl absent"
kubectl -n "$NS" get "$DEPLOY" >/dev/null 2>&1 || die "$DEPLOY absent dans $NS (tâche 2 non faite ?)"

# Le mot de passe de bind est lu depuis le Secret et gardé en variable, jamais en argv.
BIND_PW="$(kubectl -n "$NS" get secret openldap-admin -o go-template='{{index .data "password" | base64decode}}')"
[ -n "$BIND_PW" ] || die "Secret openldap-admin illisible ou vide"

# ldap_apply <ldif> — envoie le LDIF par STDIN ; le mot de passe part par STDIN de
# ldapadd via -y /dev/stdin ? Non : osixia n'expose pas -y de façon fiable. On passe
# donc par un fichier temporaire DANS le conteneur, en mode 600, supprimé aussitôt.
ldap_apply() {
  kubectl -n "$NS" exec -i "$DEPLOY" -- sh -c '
    umask 077
    PWF=$(mktemp)
    # 1re ligne de stdin = mot de passe de bind, SANS son saut de ligne.
    # `ldapadd -y` ne retire PAS le saut final du fichier : le garder ajoute un
    # octet au mot de passe et le bind échoue en « Invalid credentials (49) ».
    # Démontré le 2026-07-30 : 32 octets -> bind OK, 33 octets -> refus.
    #
    # `read` (builtin), PAS `head -n 1` : sur un pipe non-seekable (stdin de
    # `kubectl exec -i`), `head` lit par blocs et peut engloutir bien plus que
    # la 1re ligne, affamant le `cat` qui suit (le LDIF arrive alors vide,
    # ldapadd sort en RC=0 sans rien ajouter ni rien dire). `read` lit octet
    # par octet sur un pipe et stoppe pile au saut de ligne. Démontré le
    # 2026-07-30 : avec `head`, un payload de test de 5012 octets après la
    # 1re ligne arrivait à `cat` tronqué a 0 octet ; avec `read`, intact.
    IFS= read -r PWLINE
    printf "%s" "$PWLINE" > "$PWF"
    cat > /tmp/seed.ldif        # le reste = LDIF
    ldapadd -x -D "'"$BIND_DN"'" -y "$PWF" -c -f /tmp/seed.ldif 2>&1
    RC=$?
    rm -f "$PWF" /tmp/seed.ldif
    exit $RC
  ' 2>&1 || true                # 68 « Already exists » est nominal, on filtre ensuite
}

# ldap_modify_pw <ldif-modify> — BUG trouvé le 2026-07-30, absent du brief initial :
# `ldapadd -c` est idempotent pour la STRUCTURE (il ignore un uid déjà présent),
# mais le fichier de mots de passe, lui, est réécrit à CHAQUE passage avec des
# valeurs fraîchement générées. Sur un deuxième passage, l'entrée existe déjà
# donc ldapadd NE TOUCHE PAS son userPassword — mais le fichier root-only, lui,
# reçoit quand même les nouvelles valeurs générées. Résultat : le fichier et
# l'annuaire divergent, et ldapwhoami échoue après un simple re-run alors même
# que le recompte des utilisateurs reste correct (4). Reproduit : après un 2e
# passage sans ce correctif, bind d'alice -> Invalid credentials (49).
#
# Correctif : après le ldapadd -c (idempotent pour la structure), on FORCE le
# userPassword de chaque compte via ldapmodify/replace, à CHAQUE passage — donc
# toujours aligné sur ce qui vient d'être (ré)écrit dans le fichier root-only.
#
# Relecture du 2026-07-30 : contrairement à ldap_apply, où le 68 « Already
# exists » est le cas NOMINAL documenté, ici AUCUN code non nul n'est nominal —
# une entrée manquante, une ACL, un LDIF malformé doivent arrêter le script, pas
# être avalés. Le motif `2>&1 || true` hérité de ldap_apply était donc une
# fausse sécurité ici : `command terminated with exit code 68` fuyait sur la
# sortie de CE run sans jamais déclencher de die(), preuve qu'aucun garde-fou ne
# regardait vraiment le code de retour. `-c` retiré côté ldapmodify (on veut
# s'arrêter net à la première entrée en échec, pas continuer en silence sur un
# état partiel) ; le code de sortie de kubectl exec remonte tel quel, l'appelant
# décide (die() ci-dessous) — et la preuve qui compte n'est de toute façon pas
# ce code, c'est le re-bind fait par verify_bind().
ldap_modify_pw() {
  kubectl -n "$NS" exec -i "$DEPLOY" -- sh -c '
    umask 077
    PWF=$(mktemp)
    IFS= read -r PWLINE
    printf "%s" "$PWLINE" > "$PWF"
    cat > /tmp/seed-pw.ldif
    ldapmodify -x -D "'"$BIND_DN"'" -y "$PWF" -f /tmp/seed-pw.ldif
    RC=$?
    rm -f "$PWF" /tmp/seed-pw.ldif
    exit $RC
  ' 2>&1
}

# hash_pw — empreinte SSHA calculée DANS le pod (slappasswd, fourni par l'image
# osixia). Le mot de passe part par STDIN, jamais en argv, ni localement ni côté
# pod. Amendement du 2026-07-30 : l'annuaire ne doit plus stocker de mot de passe
# en clair — deux expositions {CLEARTEXT} via slapcat le même jour l'ont motivé.
# {SSHA} est irréversible : le fichier root-only de $SECRETS_HOST devient la
# SEULE copie humainement lisible tant que Vault n'a pas repris les valeurs.
hash_pw() {
  kubectl -n "$NS" exec -i "$DEPLOY" -- slappasswd -h '{SSHA}' -T /dev/stdin
}

# verify_bind <uid> — re-BIND réel avec le mot de passe en clair lu sur STDIN,
# pas un code de retour. Un hachage qui « réussit » au sens de ldapmodify mais
# casse le bind serait pire que le clair qu'il remplace : c'est le seul test qui
# prouve que l'empreinte stockée correspond effectivement au mot de passe.
verify_bind() {
  _vb_uid="$1"
  kubectl -n "$NS" exec -i "$DEPLOY" -- sh -c '
    umask 077
    PWF=$(mktemp)
    IFS= read -r PWLINE
    printf "%s" "$PWLINE" > "$PWF"
    ldapwhoami -x -H ldap://localhost:389 -D "uid='"$_vb_uid"',ou=People,'"$BASE_DN"'" -y "$PWF"
    RC=$?
    rm -f "$PWF"
    exit $RC
  '
}

# Génère un mot de passe robuste sans métacaractères de shell (les métacaractères
# sont testés séparément, par LAB_BOB_PASS_METACHARS).
genpw() { openssl rand -base64 27 | tr -d '\n=+/' | cut -c1-24; }

A_PW="$(genpw)"; C_PW="$(genpw)"; O_PW="$(genpw)"
# bob porte VOLONTAIREMENT le vecteur à métacaractères : c'est son invariant.
B_PW="$LAB_BOB_PASS_METACHARS"

# Empreintes SSHA calculées avant tout envoi à l'annuaire — c'est le HASH, pas le
# clair, qui va dans les deux LDIF (création et modify). `if VAR=$(...)` plutôt
# qu'une simple affectation : sous `set -e`, le comportement d'une substitution de
# commande en échec dans une affectation nue est trop subtil pour qu'on lui fasse
# confiance ici — on veut un die() explicite, pas un espoir.
if HASH_A="$(printf '%s' "$A_PW" | hash_pw)" && [ -n "$HASH_A" ]; then :; else die "échec du hachage SSHA (alice)"; fi
if HASH_B="$(printf '%s' "$B_PW" | hash_pw)" && [ -n "$HASH_B" ]; then :; else die "échec du hachage SSHA (bob)"; fi
if HASH_C="$(printf '%s' "$C_PW" | hash_pw)" && [ -n "$HASH_C" ]; then :; else die "échec du hachage SSHA (carol)"; fi
if HASH_O="$(printf '%s' "$O_PW" | hash_pw)" && [ -n "$HASH_O" ]; then :; else die "échec du hachage SSHA (oscar)"; fi

printf 'peuplement de %s dans %s/%s\n' "$BASE_DN" "$NS" "$DEPLOY"

{
  printf '%s\n' "$BIND_PW"
  cat <<LDIF
dn: ou=People,$BASE_DN
objectClass: organizationalUnit
ou: People

dn: ou=Groups,$BASE_DN
objectClass: organizationalUnit
ou: Groups

dn: uid=$LAB_ALICE_USER,ou=People,$BASE_DN
objectClass: inetOrgPerson
uid: $LAB_ALICE_USER
cn: $LAB_ALICE_USER
sn: $LAB_ALICE_USER
userPassword: $HASH_A

dn: uid=$LAB_BOB_USER,ou=People,$BASE_DN
objectClass: inetOrgPerson
uid: $LAB_BOB_USER
cn: $LAB_BOB_USER
sn: $LAB_BOB_USER
userPassword: $HASH_B

dn: uid=$LAB_CAROL_USER,ou=People,$BASE_DN
objectClass: inetOrgPerson
uid: $LAB_CAROL_USER
cn: $LAB_CAROL_USER
sn: $LAB_CAROL_USER
userPassword: $HASH_C

dn: uid=$LAB_OSCAR_USER,ou=People,$BASE_DN
objectClass: inetOrgPerson
uid: $LAB_OSCAR_USER
cn: $LAB_OSCAR_USER
sn: $LAB_OSCAR_USER
userPassword: $HASH_O

dn: cn=$LAB_TENANT_ALICE,ou=Groups,$BASE_DN
objectClass: groupOfNames
cn: $LAB_TENANT_ALICE
member: uid=$LAB_ALICE_USER,ou=People,$BASE_DN

dn: cn=$LAB_TENANT_BOB,ou=Groups,$BASE_DN
objectClass: groupOfNames
cn: $LAB_TENANT_BOB
member: uid=$LAB_BOB_USER,ou=People,$BASE_DN

dn: cn=operators,ou=Groups,$BASE_DN
objectClass: groupOfNames
cn: operators
member: uid=$LAB_OSCAR_USER,ou=People,$BASE_DN
LDIF
} | ldap_apply | grep -viE "already exists|adding new entry" || true

# Deuxième passe, TOUJOURS appliquée (même si les comptes existaient déjà) :
# aligne le userPassword (désormais une empreinte SSHA, jamais du clair) de
# chaque compte sur ce qui vient d'être généré, pour que le fichier root-only
# et l'annuaire ne divergent jamais. Voir le commentaire de ldap_modify_pw
# ci-dessus pour le bug que ceci corrige, et celui de hash_pw pour l'amendement
# du 2026-07-30 sur le stockage en clair.
#
# Relecture du 2026-07-30 : ici, tout code non nul est un échec réel — die()
# immédiat, on n'écrit PAS le fichier root-only avec des valeurs qui n'ont
# peut-être jamais atteint l'annuaire.
if MODIFY_OUT="$(
  {
    printf '%s\n' "$BIND_PW"
    cat <<LDIF
dn: uid=$LAB_ALICE_USER,ou=People,$BASE_DN
changetype: modify
replace: userPassword
userPassword: $HASH_A

dn: uid=$LAB_BOB_USER,ou=People,$BASE_DN
changetype: modify
replace: userPassword
userPassword: $HASH_B

dn: uid=$LAB_CAROL_USER,ou=People,$BASE_DN
changetype: modify
replace: userPassword
userPassword: $HASH_C

dn: uid=$LAB_OSCAR_USER,ou=People,$BASE_DN
changetype: modify
replace: userPassword
userPassword: $HASH_O
LDIF
  } | ldap_modify_pw
)"; then
  printf '%s\n' "$MODIFY_OUT" | grep -viE "^modifying entry" || true
else
  printf '%s\n' "$MODIFY_OUT" >&2
  die "ldapmodify (mise à jour des userPassword) a échoué — voir la sortie ci-dessus ; contrairement à ldap_apply, aucun code non nul n'est nominal ici, rien n'est écrit sur $SECRETS_HOST"
fi

# Preuve par re-bind, pas par code de retour : un ldapmodify qui « réussit » ne
# garantit pas qu'une empreinte cassée n'a pas été acceptée puis silencieusement
# inutilisable. On bind réellement les 4 comptes avec le mot de passe en clair
# qu'on vient de hacher, AVANT d'écrire quoi que ce soit sur le nœud.
for _vb_pair in "$LAB_ALICE_USER:$A_PW" "$LAB_BOB_USER:$B_PW" "$LAB_CAROL_USER:$C_PW" "$LAB_OSCAR_USER:$O_PW"; do
  _vb_uid="${_vb_pair%%:*}"
  _vb_pw="${_vb_pair#*:}"
  printf '%s' "$_vb_pw" | verify_bind "$_vb_uid" >/dev/null 2>&1 \
    || die "re-bind de $_vb_uid a échoué après hachage SSHA — l'empreinte stockée ne correspond pas au mot de passe déposé, rien n'est écrit sur $SECRETS_HOST"
done
say "les 4 comptes re-bindent avec leur mot de passe en clair (empreinte SSHA vérifiée, pas seulement un code de retour)"

# Dépôt des mots de passe dans le fichier root-only du nœud. Jamais sur stdout.
{
  printf '# lab-vault-users — mots de passe générés le %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# Régénérés à chaque passe de seed-ldap-cluster.sh. Ne pas versionner.\n'
  printf "LAB_ALICE_PASS=%s\n" "$A_PW"
  printf "LAB_CAROL_PASS=%s\n" "$C_PW"
  printf "LAB_OSCAR_PASS=%s\n" "$O_PW"
  printf '# bob porte le vecteur à métacaractères de lab-vault-users.sh (public, non secret).\n'
} | ssh "$SECRETS_HOST" "sudo install -d -m 700 $SECRETS_DIR && \
      sudo tee $SECRETS_DIR/lab-vault-users.env >/dev/null && \
      sudo chmod 600 $SECRETS_DIR/lab-vault-users.env"

unset A_PW C_PW O_PW B_PW BIND_PW

say "utilisateurs et groupes poussés"
say "mots de passe dans $SECRETS_HOST:$SECRETS_DIR/lab-vault-users.env (root, 600)"
