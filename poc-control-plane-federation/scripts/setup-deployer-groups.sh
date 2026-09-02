#!/usr/bin/env bash
# setup-deployer-groups.sh — G2 (ADR-084) : l'ANNUAIRE N°2, celui qui dit QUI
# PORTE L'APPLY. Jamais qui approuve.
#
# ⚠ DEUX ANNUAIRES, DEUX AXES — les confondre est LA faute de ce jalon :
#   · Keycloak, claim `groups`  →  `approverGroup` des portes (`int-team`,
#     `release-team`) : QUI APPROUVE. Posé par scripts/setup-release-team.sh.
#   · LDAP, groupe → policy Vault  →  `deployerGroup` des portes
#     (`apim-apply-<env>`, `apim-operator-prod`) : QUI DÉPLOIE. Posé ICI.
# Écrire un nom de l'un dans le champ de l'autre ne « marche à moitié » pas :
# côté deployerGroup c'est un refus BRUYANT (DEPLOYER_GROUP_UNSUPPORTED), côté
# approverGroup c'est une porte qui ne matche JAMAIS, en silence.
#
# ── CE SCRIPT NE TOUCHE PAS VAULT ────────────────────────────────────────────
# Le mapping `auth/ldap/groups/apim-apply-<env>` → policy `apply-<env>` est déjà
# posé par scripts/setup-vault-paliers.sh, où il est INERTE tant que le groupe
# n'existe pas dans l'annuaire. Ce script pose exactement la moitié qui manque :
# le groupe et ses membres. Les deux gestes restent SÉPARÉS parce qu'ils relèvent
# de deux exploitants différents chez le client (l'équipe Vault d'un côté,
# l'équipe annuaire de l'autre) — c'est le cas réel, pas une coquetterie de lab.
#
# ── UN PALIER SANS DÉPLOYEUR NOMMÉ N'A PAS DE GROUPE, ET C'EST VOULU ─────────
# `groupOfNames` exige au moins un `member` (RFC 4519) : un groupe vide n'est
# tout simplement pas représentable. Le palier reste donc FERMÉ — sa porte
# déclare peut-être un `deployerGroup`, mais personne ne porte la policy
# projetée et l'apply refuse `DEPLOYER_GROUP_REQUIRED`. Ouvrir un palier =
# NOMMER un déployeur, ici, explicitement. Même discipline que le `--mint`
# d'ADR-082 : rien ne s'ouvre par défaut, et ce qui est fermé le DIT.
#
# ── `apim-operator-prod` EST VÉRIFIÉ, JAMAIS REPOSÉ ──────────────────────────
# Il vit dans setup-vault-ldap.sh (avec oscar, et sa policy `operator-deploy`).
# Deux poseurs pour un même objet d'annuaire, c'est une divergence qui attend
# son heure : ici on RELIT (présence + oscar membre) et on s'arrête là. Le
# terminus est de toute façon hors de `env_chain_nonprod` — il est exclu de la
# boucle par STRUCTURE, pas par son nom.
#
# Membres par défaut, tous surchargeables par l'environnement :
#   DEPLOYERS_INT=bob     DEPLOYERS_HOMOL=carol     dev/rec : VIDES par défaut (fermés)
#   Le grant nominatif d'A3 (ADR-082 : l'humain rejoint apim-apply-<palier>) est un
#   geste EXPLICITE, jamais un défaut : DEPLOYERS_DEV=alice DEPLOYERS_REC=alice $0
# Le nom de la variable est dérivé du palier (`DEPLOYERS_<PALIER>`), donc une
# chaîne qui gagne un palier gagne son knob sans toucher à ce fichier.
#
# Usage :
#   bash scripts/setup-deployer-groups.sh --print   # le plan, AUCUN docker, hors-ligne
#   bash scripts/setup-deployer-groups.sh           # pose + read-back + contre-épreuve
#
# Prérequis de la POSE :
#   docker compose -f docker-compose.poc.yml -f docker-compose.ldap.yml up -d openldap
#   bash scripts/setup-vault-ldap.sh   # crée alice/bob/carol/oscar ET apim-operator-prod
#
# ⚠ `set -uo pipefail` SANS `-e`, comme setup-vault-ldap.sh et
# setup-release-team.sh dont ce script reprend les mécaniques. La vérification
# est un COMPTE de PASS/FAIL rendu à la fin : sous `set -e`, le premier rouge
# tuerait le script AVANT la contre-épreuve alice, et on rapporterait un défaut
# au lieu de la photo complète — une contre-épreuve jamais exécutée est un vert
# qu'on n'a pas mesuré. Le verdict final reste fail-closed : sortie non-zéro dès
# qu'un seul FAIL est compté.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Sourcés par chemin ABSOLU et AVANT tout `cd` : env-chain.sh mémorise sa racine
# à l'instant du source, et un chemin relatif résolu plus tard pointerait
# ailleurs — la chaîne reviendrait VIDE au lieu d'échouer (piège documenté dans
# la lib elle-même).
# shellcheck source=scripts/lib/env-chain.sh
. "$ROOT/scripts/lib/env-chain.sh"
# shellcheck source=scripts/lib/lab-vault-users.sh
. "$ROOT/scripts/lib/lab-vault-users.sh"

LDAP_CONTAINER="${LDAP_CONTAINER:-poc-openldap}"
BASE_DN="${LDAP_BASE_DN:-dc=corp,dc=example}"
BIND_DN="${LDAP_BIND_DN:-cn=admin,$BASE_DN}"
BIND_PW="${LDAP_ADMIN_PASSWORD:-admin-lab-2026}"
OPERATOR_GROUP="${OPERATOR_GROUP:-apim-operator-prod}"

# Les deux paliers ouverts du lab. bob approuve `int` par sa claim Keycloak
# (`int-team`) ET le déploie par son groupe d'annuaire : DEUX axes portés par la
# même personne dans un lab à quatre comptes, deux personnes distinctes chez un
# client — sans rien changer ici.
: "${DEPLOYERS_INT:=$LAB_BOB_USER}"
: "${DEPLOYERS_HOMOL:=$LAB_CAROL_USER}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
say()  { printf '\033[1;36m[deployer-groups]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deployer-groups]\033[0m %s\n' "$*"; }

# deployers_for <palier> — les membres déclarés pour ce palier, ou rien.
deployers_for() {
  local key var
  key=$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  var="DEPLOYERS_$key"
  printf '%s' "${!var:-}"
}

# ── LDIF ─────────────────────────────────────────────────────────────────────
# demandeuse_exclue <palier> — le read-back « la demandeuse n'est PAS membre »
# ne s'applique qu'aux paliers dont la PORTE déclare un deployerGroup : c'est
# l'axe (annuaire n°2, LDAP→Vault) que ce poseur protège. JAMAIS fourEyes (axe
# d'approbation, claim Keycloak — les deux annuaires que l'en-tête interdit de
# confondre) : un palier déclarant deployerGroup sans fourEyes est légal. Sur
# dev/rec (sans deployerGroup), la demandeuse membre d'apim-apply-<palier> est
# l'état voulu — le grant nominatif d'A3/ADR-082, décision client n°1 (rec
# autonome). rc 0 = s'applique · 1 = ne s'applique pas · 2 = chaîne illisible
# (jamais un 1 silencieux : une chaîne cassée ne relâche rien).
demandeuse_exclue() {
  local g
  g="$(env_chain_gate_deployer_group "$1")" || return 2
  [ -n "$g" ]
}

ldif_group() {   # ldif_group <cn> <uid>…
  local cn="$1"; shift
  printf 'dn: cn=%s,ou=Groups,%s\n' "$cn" "$BASE_DN"
  printf 'objectClass: groupOfNames\n'
  printf 'cn: %s\n' "$cn"
  local u; for u in "$@"; do printf 'member: uid=%s,ou=People,%s\n' "$u" "$BASE_DN"; done
  printf '\n'
}

# `replace: member` plutôt qu'un `add:` — c'est ce qui rend le script CONVERGENT
# et pas seulement idempotent : un groupe posé hier avec le mauvais déployeur
# est ramené sur la liste déclarée, au lieu de la cumuler en silence.
ldif_replace_members() {  # ldif_replace_members <cn> <uid>…
  local cn="$1"; shift
  printf 'dn: cn=%s,ou=Groups,%s\n' "$cn" "$BASE_DN"
  printf 'changetype: modify\n'
  printf 'replace: member\n'
  local u; for u in "$@"; do printf 'member: uid=%s,ou=People,%s\n' "$u" "$BASE_DN"; done
  # `--` OBLIGATOIRE : le terminateur LDIF d'une modification EST un `-`, et un
  # format qui COMMENCE par un tiret est mangé comme une OPTION par le printf de
  # bash (« -\: invalid option »). Mesuré live le 2026-08-27 : sans lui, le LDIF
  # part SANS terminateur, ldapmodify rend 2, et la convergence annoncée
  # ci-dessus n'a jamais lieu — le premier passage (ldapadd) restait vert, seul
  # le REJEU touchait cette branche. Défaut invisible hors-ligne.
  printf -- '-\n\n'
}

# ── L'appel client LDAP, et le mot de passe de bind qui n'est nulle part ─────
# ÉCART ASSUMÉ avec setup-vault-ldap.sh (qui passe `-w "$BIND_PW"`) : là-bas le
# mot de passe d'admin de l'annuaire est sur la ligne de commande de
# `docker exec`, donc dans le `ps` de l'HÔTE. Le lab s'en accommode (sa valeur
# par défaut est publique) ; l'annuaire d'un client, non. Ici :
#   · `-e LDAP_BIND_PW` SANS `=valeur` : docker recopie la valeur depuis
#     l'environnement de CE processus — rien n'apparaît dans l'argv ;
#   · `-y <fichier>` : l'outil lit le mot de passe dans un fichier écrit en
#     0600 à l'instant et détruit juste après — jamais `-w <mot de passe>`,
#     donc rien non plus dans le `ps` du CONTENEUR.
# STDIN reste libre pour le LDIF : `printf > fichier` ne le consomme pas.
ldap_run() {   # ldap_run <ldapadd|ldapmodify|ldapsearch> [args…]   < LDIF éventuel
  local tool="$1"; shift
  LDAP_BIND_PW="$BIND_PW" docker exec -i -e LDAP_BIND_PW "$LDAP_CONTAINER" \
    sh -c 'umask 077; f=/tmp/.ldap-bind.$$
           printf %s "$LDAP_BIND_PW" > "$f"
           t="$1"; d="$2"; shift 2
           "$t" -x -D "$d" -y "$f" "$@"; rc=$?
           rm -f "$f"; exit $rc' sh "$tool" "$BIND_DN" "$@"
}

group_members() {  # group_members <cn> — un uid par ligne ; VIDE si absent
  # `-o ldif-wrap=no` : sans lui, un DN de membre dépassant 78 colonnes est
  # REPLIÉ sur la ligne suivante et le `sed` ci-dessous ne le voit plus — un
  # membre présent serait rapporté absent, ce qui est le pire des deux sens.
  ldap_run ldapsearch -LLL -o ldif-wrap=no \
      -b "cn=$1,ou=Groups,$BASE_DN" -s base member 2>/dev/null \
    | sed -n 's/^member: uid=\([^,]*\),.*/\1/p'
}

# uid_exists <uid> — l'entrée existe-t-elle vraiment sous ou=People ?
# Rend : 0 = existe ; 32 = ABSENT (« No such object », le seul rc qui dise
# vraiment ça) ; tout autre rc = MESURE IMPOSSIBLE (49 bind refusé, 255
# conteneur muet, 127 outil absent…). Les confondre ferait passer TOUS les uid
# pour fantômes sur un simple bind cassé — un diagnostic qui MENT, fail-closed
# mais envoyant chasser une typo qui n'existe pas. Mesuré live 2026-08-27 :
# bob/0, bpb/32, mauvais mdp/49. Même discipline que read_back_group plus bas,
# qui refuse déjà de confondre « rien posé » et « relecture en échec ».
uid_exists() {
  ldap_run ldapsearch -LLL -o ldif-wrap=no \
      -b "uid=$1,ou=People,$BASE_DN" -s base dn >/dev/null 2>&1
  case $? in 0) return 0 ;; 32) return 32 ;; *) return 1 ;; esac
}

pose_group() {   # pose_group <cn> <uid>…
  local cn="$1"; shift
  local out rc u missing=""
  # ── MEMBRE FANTÔME : LA GARDE QUE `ldapadd` NE FAIT PAS ────────────────────
  # Cet annuaire n'a AUCUNE intégrité référentielle (pas d'overlay refint) : un
  # `member: uid=bbo,ou=People,…` dont l'uid n'existe pas est accepté SANS UN
  # MOT. Conséquence exacte, et elle est vicieuse : le run sort VERT, le groupe
  # est bien là, le read-back confirme le membre — et le palier est en réalité
  # FERMÉ, parce que personne ne se connectera jamais sous ce nom. Une typo
  # d'uid produit donc un lab qu'on croit ouvert. C'est la garde que
  # setup-vault-ldap.sh:138-141 pose en amont de ses propres groupes, pour la
  # même raison et dans les mêmes termes.
  local unreachable=""
  for u in "$@"; do
    uid_exists "$u"
    case $? in
      0)  : ;;
      32) missing="$missing $u" ;;
      *)  unreachable="$unreachable $u" ;;
    esac
  done
  if [ -n "$unreachable" ]; then
    # ANNUAIRE_INJOIGNABLE ≠ membre fantôme : ici la MESURE a échoué (bind
    # refusé, conteneur muet, outil absent) — aucun uid n'est déclaré fantôme
    # sur cette base, et on n'écrit rien tant qu'on ne sait pas lire.
    bad "groupe $cn NON POSÉ — ANNUAIRE_INJOIGNABLE : impossible de vérifier$unreachable (bind refusé ? conteneur muet ? ldapsearch absent ?) — vérifier LDAP_ADMIN_PASSWORD et docker exec $LDAP_CONTAINER ldapsearch"
    return 0
  fi
  if [ -n "$missing" ]; then
    bad "groupe $cn NON POSÉ — uid inexistant dans l'annuaire :$missing (typo, ou annuaire non semé : jouer scripts/setup-vault-ldap.sh). Un membre fantôme rendrait ce run VERT sur un palier RÉELLEMENT FERMÉ."
    return 0
  fi
  out=$(ldif_group "$cn" "$@" | ldap_run ldapadd 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then ok "groupe $cn CRÉÉ (membres déclarés : $*)"; return 0; fi
  # 68 « Already exists » est le cas NOMINAL du rejeu, pas une erreur — mais on
  # ne s'en contente pas : on converge la liste des membres derrière.
  if printf '%s' "$out" | grep -q 'Already exists'; then
    out=$(ldif_replace_members "$cn" "$@" | ldap_run ldapmodify 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      ok "groupe $cn déjà présent — membres CONVERGÉS par replace ($*)"
    else
      bad "groupe $cn : convergence des membres KO (rc=$rc) : $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    fi
    return 0
  fi
  bad "groupe $cn : ldapadd KO (rc=$rc) : $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
}

# READ-BACK fail-closed : on ne croit pas les codes de retour, on RELIT
# l'annuaire (motif de setup-release-team.sh §③).
read_back_group() {   # read_back_group <palier> <cn> <uid attendu>…
  local palier="$1"; shift
  local cn="$1"; shift
  local got u
  got=$(group_members "$cn" | tr '\n' ' ')
  echo "   membres lus dans $cn : ${got:-<aucun>}"
  if [ -z "$got" ]; then
    # DEUX causes possibles, et les confondre enverrait chercher au mauvais
    # endroit : soit la pose n'a rien laissé, soit c'est la RELECTURE qui a
    # échoué (ldapsearch absent de l'image, bind refusé). On les nomme toutes
    # les deux plutôt que d'affirmer la première.
    bad "read-back : rien de lu dans $cn — pose sans effet, OU relecture en échec (ldapsearch/bind) ; vérifier : docker exec $LDAP_CONTAINER ldapsearch -x -b 'cn=$cn,ou=Groups,$BASE_DN'"
    return 0
  fi
  for u in "$@"; do
    case " $got " in *" $u "*) ok "read-back : $u est bien membre de $cn" ;;
                     *) bad "read-back : $u ABSENT de $cn" ;; esac
  done
  # CONTRE-ÉPREUVE D'INTENTION (motif setup-release-team.sh:81). alice est la
  # DEMANDEUSE : un annuaire qui la met parmi les déployeurs rendrait la
  # déclaration `deployerGroup` décorative — la porte serait « satisfaite » par
  # la personne même qu'elle est censée écarter du geste d'apply.
  demandeuse_exclue "$palier"; local de=$?
  case "$de" in
    0) case " $got " in
         *" $LAB_ALICE_USER "*) bad "$LAB_ALICE_USER (demandeuse) est membre de $cn — la porte de $palier déclare un deployerGroup, à retirer" ;;
         *)                     ok "$LAB_ALICE_USER (demandeuse) n'est PAS dans $cn (deployerGroup déclaré pour $palier)" ;;
       esac ;;
    1) ok "$LAB_ALICE_USER (demandeuse) peut être membre de $cn — aucun deployerGroup déclaré pour $palier (grant nominatif A3)" ;;
    *) bad "chaîne d'environnements illisible : le contrôle demandeuse de $palier ne peut pas statuer" ;;
  esac
}

# ── Dérivation de la chaîne ──────────────────────────────────────────────────
ENVS_NONPROD="$(env_chain_nonprod)" || { echo "CHAINE_ILLISIBLE : env_chain_nonprod a échoué" >&2; exit 1; }
[ -n "$ENVS_NONPROD" ] || { echo "CHAINE_VIDE : aucun palier non terminal" >&2; exit 1; }

# print_plan_line <palier> — ce que le read-back FERAIT à la pose (le mode --print
# sort avant toute pose : c'est cette ligne que la porte hors ligne assert).
print_plan_line() {
  local g
  if demandeuse_exclue "$1"; then
    g="$(env_chain_gate_deployer_group "$1")"
    printf '#   read-back demandeuse absente : OUI (deployerGroup=%s)\n' "$g"
  elif [ $? -eq 1 ]; then
    printf '#   read-back demandeuse absente : NON (aucun deployerGroup)\n'
  else
    printf '#   read-back demandeuse absente : INDÉTERMINÉ (chaîne illisible)\n'
  fi
}

MODE="${1:-pose}"
case "$MODE" in
  --print)
    echo "# Paliers non terminaux dérivés de la chaîne : $ENVS_NONPROD"
    echo "# (le terminus est exclu par STRUCTURE — env_chain_nonprod, pas un nom)"
    for e in $ENVS_NONPROD; do
      M="$(deployers_for "$e")"
      if [ -z "$M" ]; then
        printf '# ── palier %s : AUCUN GROUPE ──\n' "$e"
        printf '#   aucun déployeur nommé (DEPLOYERS_%s vide) ⇒ groupOfNames impossible.\n' \
          "$(printf '%s' "$e" | tr 'a-z-' 'A-Z_')"
        printf '#   Le palier reste FERMÉ : DEPLOYER_GROUP_REQUIRED si la porte déclare le groupe (G2), PALIER_FERME pour toute identité humaine sans le grant (A3).\n'
        print_plan_line "$e"
        printf '#   Ouvrir : DEPLOYERS_%s="<uid>" %s\n' \
          "$(printf '%s' "$e" | tr 'a-z-' 'A-Z_')" "$0"
      else
        printf '# ── palier %s : groupe apim-apply-%s ──\n' "$e" "$e"
        # $M non quoté : le découpage par mots est l'effet voulu (un uid par membre).
        # shellcheck disable=SC2086
        ldif_group "apim-apply-$e" $M | sed 's/^/#   /'
        print_plan_line "$e"
      fi
    done
    printf '# ── terminus : %s est VÉRIFIÉ (présence + %s membre), jamais reposé ──\n' \
      "$OPERATOR_GROUP" "$LAB_OSCAR_USER"
    echo "# Aucun geste Vault ici : le mapping groupe→policy vient de setup-vault-paliers.sh."
    exit 0 ;;
  pose) : ;;
  *) echo "usage: $0 [--print]" >&2; exit 2 ;;
esac

# ── POSE ─────────────────────────────────────────────────────────────────────
docker ps --format '{{.Names}}' | grep -qx "$LDAP_CONTAINER" \
  || { echo "conteneur $LDAP_CONTAINER absent — docker compose -f docker-compose.poc.yml -f docker-compose.ldap.yml up -d openldap" >&2; exit 1; }

say "annuaire $LDAP_CONTAINER ($BASE_DN) — groupes déployeurs des paliers : $ENVS_NONPROD"

echo "① groupes déployeurs par palier"
POSED=""
for e in $ENVS_NONPROD; do
  M="$(deployers_for "$e")"
  if [ -z "$M" ]; then
    # Ce n'est PAS un échec : c'est l'état fermé par défaut, et il est DIT.
    warn "palier $e : aucun déployeur nommé ⇒ pas de groupe apim-apply-$e (palier FERMÉ : DEPLOYER_GROUP_REQUIRED si la porte déclare le groupe, PALIER_FERME pour toute identité humaine sans le grant — A3 ; ouvrir avec DEPLOYERS_$(printf '%s' "$e" | tr 'a-z-' 'A-Z_'))"
    continue
  fi
  # $M non quoté : le découpage par mots est l'effet voulu (un uid par membre).
  # shellcheck disable=SC2086
  pose_group "apim-apply-$e" $M
  POSED="$POSED $e"
done
[ -n "$POSED" ] || warn "AUCUN groupe posé — tous les paliers de la chaîne sont sans déployeur nommé"

echo "② read-back depuis l'annuaire (ce que Vault LIRA, pas ce qu'on croit avoir écrit)"
for e in $POSED; do
  M="$(deployers_for "$e")"
  # shellcheck disable=SC2086
  read_back_group "$e" "apim-apply-$e" $M
done

echo "③ terminus : $OPERATOR_GROUP est VÉRIFIÉ, pas reposé"
OGOT=$(group_members "$OPERATOR_GROUP" | tr '\n' ' ')
echo "   membres lus dans $OPERATOR_GROUP : ${OGOT:-<aucun>}"
if [ -z "$OGOT" ]; then
  # Même prudence qu'au ② : « rien lu » n'est pas « rien posé ».
  bad "$OPERATOR_GROUP : rien de lu — groupe absent (jouer scripts/setup-vault-ldap.sh, ce script ne le pose PAS volontairement) OU relecture en échec ; la porte prod, elle, DÉCLARE ce groupe"
else
  ok "$OPERATOR_GROUP existe déjà (posé par setup-vault-ldap.sh)"
  case " $OGOT " in *" $LAB_OSCAR_USER "*) ok "$LAB_OSCAR_USER est bien membre de $OPERATOR_GROUP" ;;
                    *) bad "$LAB_OSCAR_USER ABSENT de $OPERATOR_GROUP — personne ne peut porter l'apply prod" ;; esac
  # MÊME CONTRE-ÉPREUVE QU'AU ②, et elle compte DAVANTAGE ici : le terminus est
  # le seul palier dont l'exclusivité humaine est structurelle (--grant-ci ne
  # l'atteint jamais). alice membre de ce groupe-là, et la demandeuse déploie
  # la PROD — le seul endroit où plus rien d'autre ne l'en empêcherait.
  case " $OGOT " in
    *" $LAB_ALICE_USER "*) bad "$LAB_ALICE_USER (demandeuse) est membre de $OPERATOR_GROUP — la demandeuse porterait l'apply PROD ; à retirer de l'annuaire" ;;
    *)                     ok "$LAB_ALICE_USER (demandeuse) n'est PAS dans $OPERATOR_GROUP" ;;
  esac
fi

printf '\n%d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
