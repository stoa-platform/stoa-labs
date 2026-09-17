# shellcheck shell=sh
# ci/lib/site-env.sh — LES VALEURS DE SITE, chargées depuis UN fichier versionné.
#
# POURQUOI CE FICHIER EXISTE (2026-09-17). La chaîne reçoit ses valeurs de site
# par les propriétés globales du contrôleur Jenkins. Les poser exige
# `Overall/RunScripts` (Manage Jenkins → System) : un client qui ne l'a pas n'a
# AUCUNE voie. Mesuré le 2026-09-16 chez un client réel — credentials possibles,
# propriétés globales non. Et depuis `9892876`, `GIT_HOST` n'a plus de repli :
# l'absence ne fait plus dériver vers une adresse de lab, elle fait REFUSER
# (`GIT_HOST_REQUIS`, scripts/lib/forge-api.sh). Chez ce client, la chaîne
# producteur ne démarre donc pas du tout. Cette lib est la voie sans admin : le
# site pose ses valeurs dans un fichier de SON dépôt, que le job checkoute.
#
# LE CONTRAT
#   site_env_load    charge, pose, annonce. rc 0 (chargé, ou dégradé NOMMÉ),
#                    rc 2 (refus nommé). N'exporte QUE des noms absents ou vides.
#   site_env_file    imprime sur stdout le chemin retenu (pour les diagnostics
#                    et les messages de refus des appelants).
#
# PRÉCÉDENCE, TRANCHÉE : environnement POSÉ (non vide) > fichier > rien.
#   Précédent suivi : scripts/setup-provision-jobs.sh (« l'environnement de
#   l'appelant l'emporte s'il est POSÉ — intention explicite d'un CI »). Une
#   globale Jenkins arrive DANS l'environnement du step : elle gagne donc, et la
#   voie admin reste intacte. « Posé » = NON VIDE : Jenkins n'exporte pas une
#   variable de valeur vide, un seul test couvre donc absente et vide.
#
# CE QUE LE FICHIER NE PORTE PAS : les secrets. Un nom de secret porteur d'une
# valeur est REFUSÉ au chargement — le fichier est versionné, donc lisible par
# quiconque lit le dépôt. Les identifiants restent dans les credentials Jenkins
# et dans Vault. Les mêmes règles de nom et les mêmes exemptions que
# `scripts/setup-jenkins-globals.sh`, à l'octet près : les deux voies lisent le
# MÊME format, et une épreuve-miroir l'exige.
#
# POSIX STRICT : cette lib est sourcée depuis des blocs `sh` de Jenkins, qui sont
# du DASH sur Debian. Ni `[[`, ni tableau, ni `<<<`, ni `${v,,}`. Et ni `exit` ni
# `trap` : `return` seulement — c'est l'appelant qui décide de sortir.
# Elle ne source AUCUNE autre lib : git-base.sh, env-chain.sh et forge-api.sh
# échouent à `dash -n`, les sourcer ici casserait tout bloc `sh`.
#
# Usage (première ligne d'un bloc sh, AVANT ci/lib/dbg.sh — STOA_DEBUG est
# lui-même une valeur de site) :
#   . ci/lib/site-env.sh || { echo "REFUS: SITE_LIB_INTROUVABLE : ci/lib/site-env.sh" >&2; exit 2; }
#   site_env_load || exit 2

_SITE_ENV_LOADED="${_SITE_ENV_LOADED:-}"
_SITE_ENV_FILE="${_SITE_ENV_FILE:-}"

_site_refus() {
  printf 'REFUS: %s : %s\n' "$1" "$2" >&2
  return 2
}

# _site_localiser — pose _SITE_ENV_FILE. rc 0 si trouvé, 1 si aucun (état
# NORMAL chez un site qui a un admin), 2 si STOA_SITE_FILE est posé mais
# illisible — un pointeur explicite qui ne résout pas est un refus, jamais un
# repli silencieux.
_site_localiser() {
  if [ -n "${STOA_SITE_FILE:-}" ]; then
    if [ -r "$STOA_SITE_FILE" ]; then _SITE_ENV_FILE="$STOA_SITE_FILE"; return 0; fi
    _site_refus SITE_FILE_ILLISIBLE \
      "STOA_SITE_FILE=$STOA_SITE_FILE est posé mais le fichier est absent ou illisible — corriger le chemin, ou retirer la variable pour revenir à la recherche par défaut"
    return 2
  fi
  # AUCUNE remontée d'arborescence : un « ../.. » lirait le fichier de site d'un
  # autre arbre (worktree détaché, harnais). Deux emplacements, bornés.
  if [ -n "${SUB_PFX:-}" ] && [ -r "${SUB_PFX}config/site.ini" ]; then
    _SITE_ENV_FILE="${SUB_PFX}config/site.ini"; return 0
  fi
  if [ -r "config/site.ini" ]; then _SITE_ENV_FILE="config/site.ini"; return 0; fi
  return 1
}

# _site_nom_valide <nom> — mêmes classes que setup-jenkins-globals.sh.
_site_nom_valide() {
  case "$1" in
    [A-Z_]*[A-Z0-9_]|[A-Z_]) return 0 ;;
    *) return 1 ;;
  esac
}

# _site_nom_secret <nom> — vrai si le nom désigne un SECRET, donc interdit dans
# un fichier versionné. Les exemptions sont NOMMÉES une par une, jamais par un
# motif `*_WEBHOOK_SECRET` : un motif exempterait d'avance tout knob futur
# portant ce suffixe, y compris un vrai secret partagé.
_site_nom_secret() {
  case "$1" in
    *CREDENTIALS_ID) return 1 ;;
    TEAM_PUBLISH_WEBHOOK_SECRET|TEAM_PROMOTE_WEBHOOK_SECRET) return 1 ;;
    *PASSWORD*|*SECRET*|*TOKEN*|*_KEY|*CREDENTIALS) return 0 ;;
    *) return 1 ;;
  esac
}

site_env_file() { printf '%s' "$_SITE_ENV_FILE"; }

site_env_load() {
  [ -n "$_SITE_ENV_LOADED" ] && return 0

  _site_localiser
  case "$?" in
    2) return 2 ;;
    1) # Le message NOMME ce qui a VRAIMENT été cherché. Sans le test sur SUB_PFX,
       # il annonçait deux fois le même chemin quand la variable est vide — un
       # diagnostic qui se répète ment sur ce qu'il a tenté.
       if [ -n "${SUB_PFX:-}" ]; then
         printf 'site-env: aucun fichier de site (cherché %sconfig/site.ini puis config/site.ini, depuis %s) — les valeurs viennent de l environnement seul\n' \
           "$SUB_PFX" "$PWD" >&2
       else
         printf 'site-env: aucun fichier de site (cherché config/site.ini depuis %s ; SUB_PFX non posé) — les valeurs viennent de l environnement seul\n' \
           "$PWD" >&2
       fi
       _SITE_ENV_LOADED=1
       return 0 ;;
  esac

  # DEUX PASSES. La première VALIDE tout le fichier sans rien poser : un refus
  # au milieu laisserait sinon un état partiel, moitié fichier moitié
  # environnement, que personne ne pourrait diagnostiquer. On ne pose qu'une
  # fois le fichier entier jugé bon.
  # LE MÊME DÉCOUPAGE DANS LES DEUX PASSES, et calculé UNE fois. Deux formes
  # différentes (l'une retirant un saut de ligne, l'autre un retour chariot)
  # feraient VALIDER un octet et en POSER un autre : la validation ne dirait plus
  # rien de ce qui est posé. Le CR vient d'un fichier édité sous Windows — sans
  # ce retrait, on exporterait « valeur\r », qui casse la première URL venue.
  _sl_cr=$(printf '\r')
  # LES NOMS DÉJÀ VUS, pour refuser une clé répétée. Un espace de part et d'autre
  # de chaque nom : sans lui, « GIT_HOST » serait « déjà vu » à cause de
  # « GIT_HOSTNAME ». Pas de tableau : cette lib est sourcée depuis des blocs `sh`
  # de Jenkins, qui sont du DASH.
  _sl_vus=' '
  _sl_n=0; _sl_poses=0; _sl_ignores=0
  while IFS= read -r _sl_l || [ -n "$_sl_l" ]; do
    _sl_n=$((_sl_n + 1))
    _sl_l="${_sl_l%"$_sl_cr"}"
    _sl_l="${_sl_l%"${_sl_l##*[! ]}"}"          # espaces de fin
    case "$_sl_l" in ''|'#'*) continue ;; esac
    case "$_sl_l" in
      *=*) ;;
      *) _site_refus SITE_LIGNE_INVALIDE \
           "$_SITE_ENV_FILE ligne $_sl_n : '$_sl_l' — attendu CLE=valeur, une ligne vide, ou un commentaire commençant par #. L inclassable est refusé, jamais ignoré"
         return 2 ;;
    esac
    _sl_k="${_sl_l%%=*}"
    _sl_v="${_sl_l#*=}"
    if ! _site_nom_valide "$_sl_k"; then
      _site_refus SITE_NOM_INVALIDE \
        "$_SITE_ENV_FILE ligne $_sl_n : '$_sl_k' — majuscules, chiffres et souligné seulement"
      return 2
    fi
    if _site_nom_secret "$_sl_k"; then
      _site_refus SITE_SECRET_INTERDIT \
        "$_SITE_ENV_FILE ligne $_sl_n : '$_sl_k' porte un secret, et ce fichier est VERSIONNÉ (lisible par quiconque lit le dépôt) — poser ce secret dans un credential Jenkins ou dans le coffre"
      return 2
    fi
    case "$_sl_v" in
      *[\"\\]*) _site_refus SITE_VALEUR_NON_TRANSPORTABLE \
          "$_SITE_ENV_FILE ligne $_sl_n : la valeur de '$_sl_k' contient un guillemet ou une barre inverse — non transportable par ce canal (même limite que setup-jenkins-globals.sh)"
        return 2 ;;
    esac
    # UNE CLÉ RÉPÉTÉE EST INCLASSABLE, DONC ROUGE (2026-09-17). Ce n'est pas un
    # excès de zèle : avant cette garde, les DEUX lecteurs du format tranchaient
    # DIFFÉREMMENT le même fichier. Ici la seconde ligne tombait dans « déjà posé
    # dans l'environnement » et la PREMIÈRE valeur gagnait — un effet de bord de la
    # précédence, pas une décision. L'extraction Groovy des cinq récepteurs, elle,
    # fait `each` et gardait la DERNIÈRE. Le même octet rendait donc deux valeurs
    # selon qu'on le lisait depuis un bloc `sh` ou depuis `environment{}`, en
    # silence. On n'arbitre pas à la place de l'auteur du fichier : on refuse.
    case "$_sl_vus" in
      *" $_sl_k "*)
        _site_refus SITE_CLE_EN_DOUBLE \
          "$_SITE_ENV_FILE ligne $_sl_n : '$_sl_k' est défini plusieurs fois — lequel gagne n est pas une question que ce canal tranche (les deux lecteurs du format ne répondaient pas pareil). Ne gardez qu une seule ligne"
        return 2 ;;
    esac
    _sl_vus="$_sl_vus$_sl_k "
  done < "$_SITE_ENV_FILE"

  # SECONDE PASSE : la pose. Le fichier est déjà jugé bon dans son ENTIER.
  while IFS= read -r _sl_l || [ -n "$_sl_l" ]; do
    _sl_l="${_sl_l%"$_sl_cr"}"
    _sl_l="${_sl_l%"${_sl_l##*[! ]}"}"
    case "$_sl_l" in ''|'#'*) continue ;; esac
    _sl_k="${_sl_l%%=*}"
    _sl_v="${_sl_l#*=}"
    if [ -n "$(eval "printf '%s' \"\${$_sl_k:-}\"")" ]; then
      printf 'site-env: %s IGNORÉ (déjà posé dans l environnement) — la valeur du fichier ne gagne pas\n' "$_sl_k" >&2
      _sl_ignores=$((_sl_ignores + 1))
      continue
    fi
    eval "$_sl_k=\$_sl_v"
    eval "export $_sl_k"
    printf 'site-env: %s posé depuis %s\n' "$_sl_k" "$_SITE_ENV_FILE" >&2
    _sl_poses=$((_sl_poses + 1))
  done < "$_SITE_ENV_FILE"

  printf 'site-env: %d posé(s), %d ignoré(s), fichier=%s\n' "$_sl_poses" "$_sl_ignores" "$_SITE_ENV_FILE" >&2
  _SITE_ENV_LOADED=1
  return 0
}
