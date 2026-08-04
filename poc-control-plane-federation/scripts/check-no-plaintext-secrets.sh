#!/bin/sh
# check-no-plaintext-secrets.sh — garde de dépôt PUBLIC.
#
# Échoue si une affectation de mot de passe littéral réapparaît dans les scripts.
# Le dépôt est public depuis le 2026-07-30 : quatre mots de passe de lab y ont
# déjà fuité (commits 83964e1, 9ef7eb6) et sont considérés brûlés. Cette garde
# empêche la récidive, elle ne répare pas le passé.
#
# RELECTURE (2026-07-30, ronde 1) : la 1re version de cette garde exigeait que le
# nom de variable soit le TOUT PREMIER token de la ligne — `export FOO_PASS=…`,
# `local FOO_PASS=…`, `declare FOO_PASS=…`, `readonly FOO_PASS=…` passaient tous
# inaperçus, tout comme une variable en minuscules (`foo_pass=…`). Une garde de
# dépôt public contournable par un simple `export` donne une fausse assurance —
# pire que pas de garde. Corrigé : le nom peut suivre un mot-clé de déclaration,
# et la casse n'a plus d'importance (`grep -i`, motif normalisé en majuscules).
#
# RELECTURE (2026-07-30, ronde 2) : le commentaire ci-dessus (version ronde 1)
# affirmait qu'une affectation après `;` SANS mot-clé de déclaration était absente
# du dépôt. C'était FAUX, vérifié FAUX par le relecteur puis par moi (grep réel,
# pas une relecture visuelle) — au moins 10 occurrences réelles, avec des valeurs
# comme `admin`, `manage`, `wm-dev-secret-poc`, ex. `scripts/setup-vault.sh:29`
# (`WSO2_USER="${WSO2_USER:-admin}"; WSO2_PASS="${WSO2_PASS:-admin}"` — le 2e
# n'était pas couvert). En creusant ce cas précis, j'ai aussi trouvé et corrigé
# un `||` du même genre (`scripts/setup-vault-envs.sh:52`). Les DEUX sont
# couverts maintenant : `;`, `&&` et `||` sont traités comme des séparateurs de
# commande valides devant une affectation, au même titre que le début de ligne.
# Une ligne de commentaire PURE (1er caractère non-blanc = `#`) est exclue du
# scan, pour qu'un exemple en commentaire contenant `; VAR_PASS=` ne se
# fasse pas lui-même passer pour du code.
#
# EXEMPTIONS ASSUMÉES (documentées ici pour qu'elles ne soient jamais implicites) :
#   - *_PASS_METACHARS : EXEMPTÉ EN CONNAISSANCE DE CAUSE.
#     RECTIFICATIF (2026-07-30) : la version précédente de cette ligne justifiait
#     l'exemption en affirmant que ce n'était « pas le mot de passe d'un compte ».
#     C'était FAUX. `LAB_BOB_PASS_METACHARS` EST le mot de passe LDAP réel de bob
#     — `seed-ldap-cluster.sh` fait `B_PW="$LAB_BOB_PASS_METACHARS"` et
#     `POST auth/ldap/login/bob` avec cette valeur rend 200 (vérifié). Une garde
#     de dépôt public dont l'exemption repose sur une affirmation fausse ne
#     protège rien : elle documente un angle mort en le déguisant en non-sujet.
#     LA VRAIE JUSTIFICATION : c'est un IDENTIFIANT PUBLIC ASSUMÉ. L'exploitant a
#     tranché le 2026-07-30 — on garde la valeur (la changer imposerait de ranger
#     un secret généré dans Vault, donc une cérémonie de quorum avec des parts
#     irremplaçables) parce que le risque est borné : annuaire et Vault en
#     ClusterIP, et bob ne lit que `payments-team/wm-admin`, dont la valeur est
#     déjà publique partout dans ce dépôt. On l'exempte donc pour que le SIGNAL
#     de cette garde reste sur les fuites NOUVELLES, pas pour prétendre qu'il n'y
#     a rien à voir. Le raisonnement complet et les bornes vivent au-dessus de la
#     variable, dans lab-vault-users.sh — c'est là qu'il faut aller avant de
#     toucher à cette exemption.
#     CONSÉQUENCE À CONNAÎTRE : le motif exempte le NOM `*_PASS_METACHARS=`, pas
#     cette valeur-là. Un futur `AUTRE_PASS_METACHARS="…"` passerait aussi, quel
#     que soit ce qu'il contient. Restreindre l'exemption au seul nom
#     `LAB_BOB_PASS_METACHARS` fermerait ce trou ; non fait aujourd'hui, signalé.
#   - repli PUREMENT numérique dans ${VAR:-…} (ex. "${TTL:-600}", "${T:-600s}") :
#     un TTL ou un port n'est pas un mot de passe.
#   - RHS de pure indirection ($AUTRE_VAR, ${AUTRE_VAR}, ${AUTRE_VAR:-$AUTRE}) :
#     aucun littéral n'est présent SUR CETTE LIGNE précise.
#
# ANGLES MORTS CONNUS — chacun vérifié par grep réel le 2026-07-30 (ronde 2), pas
# affirmé de mémoire ; si un jour ce n'est plus vrai, ce commentaire doit être
# revérifié avant d'être cru :
#   - une variable-cible qui n'est PAS le premier token après `local`/`declare`
#     sur une ligne à affectations multiples (`local a=1 SECRET_X=2`) : VÉRIFIÉ
#     ABSENT (`grep -rnE '^[[:space:]]*local[[:space:]]+\S+[[:space:]]+.*(PASS|
#     PASSWORD|SECRET|TOKEN)[A-Za-z0-9_]*=' scripts ci` ne remonte rien) ;
#   - `typeset` (alias ksh de `declare`) : VÉRIFIÉ ABSENT (`grep -rn typeset
#     scripts ci` ne remonte que ce commentaire-ci) ;
#   - un séparateur `; VAR_PASS=…` / `&& VAR_PASS=…` / `|| VAR_PASS=…` qui
#     apparaîtrait DANS le texte d'un commentaire en fin de ligne (pas en tout
#     début de ligne) : VÉRIFIÉ ABSENT aujourd'hui (`grep -rnE '#.*;[[:space:]]*
#     [A-Za-z_]\S*(PASS|PASSWORD|SECRET|TOKEN)\S*=' scripts ci` ne remonte que ce
#     commentaire-ci) — mais NON PROTÉGÉ structurellement : le filtre « ligne de
#     commentaire pure » ne couvre que les commentaires qui occupent TOUTE la
#     ligne, pas un commentaire en fin d'une ligne de code. Si ce cas apparaît,
#     il faudrait exclure tout ce qui suit un `#` avant d'appliquer le motif.
#   - `|`, retour à la ligne dans un heredoc, `if`/`then`/`do` comme séparateur
#     implicite : PAS VÉRIFIÉ à ce tour de relecture — je ne l'affirme ni absent
#     ni présent, ça n'a pas été audité.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RC=0

# Motif d'affectation de secret : nom de variable *PASS*/*PASSWORD*/*SECRET*/
# *TOKEN* (insensible à la casse, via grep -i), précédé soit du début de ligne,
# soit d'un séparateur de commande (`;`, `&&`, `||`), le tout optionnellement
# suivi d'un mot-clé de déclaration bash (export/local/declare/readonly, avec
# ses options courtes éventuelles : `declare -gx`, `local -r`, …).
DECL_RE='(export|declare|local|readonly)([[:space:]]+-[A-Za-z]+)*[[:space:]]+'
SEP_RE='(;|&&|\|\|)[[:space:]]*'
ASSIGN_RE="(^[[:space:]]*|${SEP_RE})(${DECL_RE})?[A-Za-z_][A-Za-z0-9_]*(PASS|PASSWORD|SECRET|TOKEN)[A-Za-z0-9_]*="

# scan <répertoire…> -> lignes "fichier:no:VAR=<valeur>" pour chaque affectation
# de secret littéral trouvée. UNE SEULE définition du motif, utilisée à la fois
# par l'auto-test et par le scan réel : la régression qui a fait fuiter les mots
# de passe de lab-vault-users.sh venait d'un motif qui ne détectait pas ce qu'il
# prétendait détecter — deux copies du motif pourraient diverger à nouveau, une
# seule ne peut pas.
# --exclude=<son propre nom> : le bloc d'auto-test ci-dessous embarque, dans SON
# PROPRE code source, les lignes littérales qu'il fabrique pour se tester — sans
# cette exclusion, un scan de $ROOT/scripts se flagge lui-même (faux positif
# garanti, à chaque exécution, sur ce fichier précis). Conséquence assumée :
# ce fichier a un angle mort permanent sur LUI-MÊME. Alternative envisagée —
# limiter l'exclusion au seul appel d'auto-test — écartée : `scan()` est LA
# fonction de scan, en avoir un usage exclu et un autre pas romprait justement
# la garantie « une seule définition, pas deux qui peuvent diverger » qui est
# la raison d'être de cette fonction.
SELF="$(basename "$0")"
scan() {
  grep -rniE "$ASSIGN_RE" --include='*.sh' --exclude="$SELF" "$@" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | grep -viE "_PASS_METACHARS=" \
    | grep -iE "=['\"]?[^'\"[:space:]\$]|:-[A-Za-z0-9]" \
    | grep -viE ":-[0-9]+[A-Za-z]?['\"}]*[[:space:]]*(#.*)?\$" || true
}

# ═══ Auto-test ════════════════════════════════════════════════════════════════
# Vérifie, à CHAQUE exécution, que la garde attrape bien les formes qui lui ont
# échappé une fois (export/local/declare/readonly + casse + séparateurs `;`/`&&`/
# `||`), ET qu'elle n'invente pas de faux positif sur un commentaire. Coût
# négligeable (un fichier temporaire, quelques grep) face au risque : sans ce
# test, un de ces trous pourrait se rouvrir en silence à la prochaine réécriture
# du motif — c'est exactement ce qui s'est produit en ronde 2 (le commentaire
# affirmait le cas `;` absent alors qu'il y avait déjà 10 occurrences réelles).
# "hunter2" est une valeur de test, jamais un secret réel.
SELFTEST_DIR="$(mktemp -d)"
trap 'rm -rf "$SELFTEST_DIR"' EXIT
mkdir -p "$SELFTEST_DIR/scripts" "$SELFTEST_DIR/ci"
cat > "$SELFTEST_DIR/scripts/probe.sh" <<'PROBE'
FOO_PASS="hunter2"
export FOO_PASS="hunter2"
local FOO_PASS="hunter2"
declare FOO_PASS="hunter2"
readonly FOO_PASS="hunter2"
foo_pass="hunter2"
A=1; BAR_PASS="hunter2"
true && BAZ_TOKEN="hunter2"
false || QUX_SECRET="hunter2"
# exemple en commentaire, ne doit PAS être détecté : x=1; NOPE_PASS="hunter2"
PROBE
SELFTEST_HITS=$(scan "$SELFTEST_DIR/scripts" "$SELFTEST_DIR/ci")
SELFTEST_N=$(printf '%s\n' "$SELFTEST_HITS" | grep -c 'probe\.sh:' || true)
if [ "$SELFTEST_N" -ne 9 ]; then
  echo "AUTO-TEST DE LA GARDE EN ÉCHEC ($SELFTEST_N/9 formes détectées, 9 attendues)." >&2
  echo "Angle mort dans check-no-plaintext-secrets.sh — NE PAS FAIRE CONFIANCE au résultat ci-dessous tant que ce n'est pas corrigé." >&2
  RC=1
fi
if printf '%s\n' "$SELFTEST_HITS" | grep -q 'NOPE_PASS'; then
  echo "AUTO-TEST DE LA GARDE EN ÉCHEC : un exemple DANS UN COMMENTAIRE (NOPE_PASS) a été détecté comme du code — faux positif sur les lignes de commentaire." >&2
  RC=1
fi

# ═══ Base de référence ════════════════════════════════════════════════════════
# La garde échouait sur 23 occurrences préexistantes, donc elle échouait
# TOUJOURS. Une garde toujours rouge est une garde désactivée : plus personne ne
# la regarde, et la 24e passe inaperçue. On fige donc le connu-et-assumé dans
# scripts/secrets-baseline.txt (chaque ligne motivée), pour que toute occurrence
# NOUVELLE rougisse.
#
# La clé est (fichier, VARIABLE) — pas la valeur : hacher la valeur pour
# détecter un changement reviendrait à publier un condensat de secret dans un
# dépôt public. Limite énoncée, pas masquée.
BASELINE="$ROOT/scripts/secrets-baseline.txt"

# Variables SENSIBLES d'une ligne (mêmes suffixes que le motif de détection).
vars_de_ligne() {
  printf '%s' "$1" \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*(PASS|PASSWORD|SECRET|TOKEN)[A-Za-z0-9_]*=' \
    | sed 's/=$//' | sort -u
}

# ═══ Scan réel ════════════════════════════════════════════════════════════════
HITS=$(scan "$ROOT/scripts" "$ROOT/ci")

NOUVEAUX="$SELFTEST_DIR/nouveaux"; : > "$NOUVEAUX"
VUS="$SELFTEST_DIR/vus"; : > "$VUS"

if [ -n "$HITS" ]; then
  printf '%s\n' "$HITS" > "$SELFTEST_DIR/hits"
  while IFS= read -r H; do
    [ -n "$H" ] || continue
    CHEMIN=${H%%:*}
    REL=$(printf '%s' "$CHEMIN" | sed "s#^$ROOT/##")
    RESTE=${H#*:}; CONTENU=${RESTE#*:}
    # Une ligne n'est acceptée que si TOUTES ses variables sensibles le sont.
    ACCEPTEE=1
    for V in $(vars_de_ligne "$CONTENU"); do
      if grep -qE "^${REL}\|${V}\|" "$BASELINE" 2>/dev/null; then
        echo "${REL}|${V}" >> "$VUS"
      else
        ACCEPTEE=0
        echo "  ${REL} : ${V}" >> "$NOUVEAUX"
      fi
    done
    [ "$ACCEPTEE" = "1" ] || true
  done < "$SELFTEST_DIR/hits"
fi

if [ -s "$NOUVEAUX" ]; then
  echo "ÉCHEC — affectation(s) de secret littéral NON RÉFÉRENCÉE(S), dans un dépôt public :" >&2
  sort -u "$NOUVEAUX" >&2
  echo "  → soit lire la valeur depuis l'environnement, soit l'assumer" >&2
  echo "    explicitement dans scripts/secrets-baseline.txt (avec sa raison)." >&2
  RC=1
else
  N=$(grep -c '^[^#]' "$BASELINE" 2>/dev/null || echo 0)
  echo "OK — aucune affectation de secret littéral NOUVELLE ($N occurrence(s) assumée(s) en base de référence)"
fi

# Entrées devenues inutiles : signalées, jamais bloquantes — une base de
# référence qui ne se purge pas finit par absoudre des fichiers disparus.
if [ -f "$BASELINE" ]; then
  PERIMEES=""
  while IFS='|' read -r BF BV BR; do
    case "$BF" in ''|'#'*) continue;; esac
    grep -qx "${BF}|${BV}" "$VUS" 2>/dev/null || PERIMEES="${PERIMEES}  ${BF} : ${BV}\n"
  done < "$BASELINE"
  if [ -n "$PERIMEES" ]; then
    echo "AVERTISSEMENT — entrée(s) de base de référence sans occurrence réelle (à purger) :"
    printf "$PERIMEES"
  fi
fi

exit $RC
