#!/usr/bin/env bash
# ci/lib/carto-secrets.sh — les secrets du job carto, depuis Vault ou depuis
# l'environnement. À SOURCER en tête d'un bloc `sh` du Jenkinsfile.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QUE CE FICHIER AMENDE, ET CE QU'IL N'AMENDE PAS
# ─────────────────────────────────────────────────────────────────────────────
# `ci/Jenkinsfile.carto` porte un arbitrage écrit : « ce job recule sciemment
# sur Vault, le client n'autorise pas l'authentification Vault PAR IDENTITÉ DE
# POD ». Cet arbitrage reste vrai — et il n'est pas contredit ici.
#
# Ce qui était refusé, c'est l'auth `kubernetes` (le pod prouve son identité au
# cluster). Ce n'est PAS la seule voie : les pipelines `prod` et `rollback` de
# ce même dépôt obtiennent déjà leurs secrets de Vault par APPROLE, et c'est un
# chemin que le client exécute réellement. Le job carto s'y aligne, sans rien
# inventer : même `ci/lib/vault-login.sh`, même `vault_login_any`, même
# `vault_read`, même credential `vault-ci-secret-id`.
#
# CE QUE ÇA DÉPLACE, ET CE QUE ÇA NE SUPPRIME PAS. Il faut être honnête sur le
# gain : AppRole ne fait pas disparaître le secret zéro, il le REMPLACE. Avant,
# Jenkins détenait au repos trois secrets à longue vie (le compte gateway, le
# jeton de la forge, le jeton Confluence), chacun utilisable partout où il est
# reconnu. Après, Jenkins ne détient plus qu'un `secret_id` AppRole, dont le
# pouvoir est borné par la policy Vault attachée au rôle, et les trois secrets
# métier ne sont plus au repos dans Jenkins. C'est un vrai gain — pas une
# élimination du problème, et le dire autrement serait se mentir.
#
# ─────────────────────────────────────────────────────────────────────────────
# LE DÉFAUT EST « PAS DE VAULT », ET C'EST DÉLIBÉRÉ
# ─────────────────────────────────────────────────────────────────────────────
# Sans `VAULT_ADDR`, cette fonction ne fait RIEN et le dit : le job garde
# exactement le comportement d'avant, celui des credentials Jenkins injectés par
# `withCredentials`. Deux raisons, et la seconde est la vraie :
#   - le client qui refuse Vault doit pouvoir dérouler ce job tel quel ;
#   - ce job est PLANIFIÉ toutes les nuits. Une voie d'authentification neuve
#     activée par défaut, c'est une série de nuits rouges découvertes trop tard.
#     On l'active en renseignant un paramètre, en regardant le build.
#
# ─────────────────────────────────────────────────────────────────────────────
# LES CHEMINS VAULT, ET POURQUOI ILS SONT PARAMÉTRABLES
# ─────────────────────────────────────────────────────────────────────────────
# Aucun chemin KV n'est en dur : l'arborescence d'un coffre client ne ressemble
# à celle du labo (`secret/data/stoa/...`) qu'avec beaucoup de chance, et la
# leçon a déjà été payée sur le rôle self-service (namespace imbriqué, mount
# `secret_DEV`, entrées à plat). Chaque secret a donc son couple
# chemin + champ, surchargeable par variable d'environnement.
#
#   CARTO_VAULT_GW_PATH / _USER_FIELD / _PASS_FIELD    compte gateway (lecture)
#   CARTO_VAULT_PAGES_PATH / _USER_FIELD / _TOKEN_FIELD  compte forge (écriture)
#   CARTO_VAULT_CONFLUENCE_PATH / _TOKEN_FIELD         jeton Confluence
#
# Un secret dont le chemin est vide n'est PAS lu : c'est ainsi qu'on active
# Vault pour la gateway seule, en laissant Confluence sur un credential Jenkins.
#
# INVARIANTS DE SECRET (hérités de `vault-login.sh`, à ne pas affaiblir ici)
#   - aucun secret en argv : tout passe par des variables d'environnement ;
#   - aucun `echo` d'une valeur : ce fichier n'imprime que des NOMS et des
#     longueurs ;
#   - le token Vault est révoqué à la sortie par le `trap` de `vault-login.sh`.

# Lit un secret dans Vault et l'exporte, SI son chemin est renseigné.
# $1 = nom de la variable à exporter · $2 = chemin KV · $3 = champ
_carto_vault_export() {
  _cv_var="$1"; _cv_path="$2"; _cv_field="$3"
  [ -n "$_cv_path" ] || return 0
  _cv_val=$(vault_read "$_cv_path" "$_cv_field") || {
    echo "  ✗ Vault : lecture impossible de $_cv_path (champ $_cv_field)" >&2
    echo "    Vérifier que le rôle AppRole du CI a le droit de LIRE ce chemin," >&2
    echo "    et que le champ existe (nom exact, sensible à la casse)." >&2
    return 1
  }
  [ -n "$_cv_val" ] || {
    echo "  ✗ Vault : $_cv_path existe mais le champ $_cv_field est VIDE." >&2
    echo "    Un champ vide n'est pas un secret : on s'arrête plutôt que de" >&2
    echo "    tenter une authentification qui échouerait en 401 sans dire" >&2
    echo "    pourquoi." >&2
    return 1
  }
  # SC2163 : faux positif. L'indirection est VOULUE — on exporte la variable
  # DONT LE NOM est dans $_cv_var (WM_USER, CARTO_PAGES_TOKEN…), parce que le
  # collecteur lit ses identifiants dans l'ENVIRONNEMENT et jamais en argv.
  eval "$_cv_var=\$_cv_val"
  # shellcheck disable=SC2163
  export "$_cv_var"
  echo "  ✓ $_cv_var  ← $_cv_path ($_cv_field, ${#_cv_val} caractères)"
  unset _cv_val
}

# Résout tous les secrets du job. Retourne 0 si l'aval peut continuer.
carto_secrets_resolve() {
  if [ -z "${VAULT_ADDR:-}" ]; then
    echo "Secrets : CREDENTIALS JENKINS (VAULT_ADDR vide)."
    echo "  C'est le mode par défaut, pas un repli d'échec. Pour passer par"
    echo "  Vault : renseigner le paramètre VAULT_ADDR du job."
    return 0
  fi

  # VAULT_ADDR ne suffit PAS à décider : il est posé sur le POD, donc vu par
  # tous les stages, alors que la bascule est voulue chemin par chemin. Le
  # signal par stage, c'est la LIAISON : `liaisons()` dans le Jenkinsfile lie
  # VAULT_SECRET_ID au stage qui passe par Vault, et le credential Jenkins à
  # celui qui reste dessus — jamais les deux. Un stage sans VAULT_SECRET_ID est
  # donc un stage resté sur Jenkins : tenter le login Vault ici le ferait
  # échouer sur un `secret_id` vide, et la bascule graduelle documentée en tête
  # de `Jenkinsfile.carto` (« un chemin vide laisse SON secret sur le credential
  # Jenkins ») serait impossible à exécuter.
  #
  # Ce test ne masque pas un credential mal posé : si le stage passe par Vault
  # et que `vault-ci-secret-id` manque, c'est `withCredentials` qui échoue, côté
  # Jenkins, avant même d'entrer dans ce shell.
  if [ -z "${VAULT_SECRET_ID:-}" ]; then
    echo "Secrets : CREDENTIALS JENKINS (ce stage n'a pas de chemin Vault)."
    echo "  VAULT_ADDR est renseigné, mais aucun secret_id n'est lié à ce"
    echo "  stage : son chemin CARTO_VAULT_*_PATH est vide, il reste donc sur"
    echo "  son credential Jenkins. C'est la bascule graduelle, pas un échec."
    return 0
  fi

  echo "Secrets : VAULT ($VAULT_ADDR)"
  # Chemin COMPLET, et non `ci/lib/…` : ce fichier n'est sourcé que par
  # `ci/Jenkinsfile.carto`, dont les blocs `sh` tournent à la RACINE du dépôt
  # (voir le commentaire du stage `Source`). Sous `set -eu`, un chemin faux ne
  # dégrade pas — il tue le stage avant la moindre garde.
  # shellcheck source=/dev/null
  . poc-control-plane-federation/ci/lib/vault-login.sh
  trap vault_trap_revoke EXIT
  vault_login_any || {
    echo "  ✗ Login Vault impossible." >&2
    echo "    Ce job est PLANIFIÉ : il ne porte aucun humain, donc seule la" >&2
    echo "    voie APPROLE peut aboutir. Vérifier VAULT_ROLE_ID (paramètre du" >&2
    echo "    job) et le credential Jenkins portant le secret_id." >&2
    return 1
  }

  _carto_vault_export WM_USER \
    "${CARTO_VAULT_GW_PATH:-}" "${CARTO_VAULT_GW_USER_FIELD:-user}" || return 1
  _carto_vault_export WM_PASS \
    "${CARTO_VAULT_GW_PATH:-}" "${CARTO_VAULT_GW_PASS_FIELD:-password}" || return 1
  _carto_vault_export CARTO_PAGES_USER \
    "${CARTO_VAULT_PAGES_PATH:-}" "${CARTO_VAULT_PAGES_USER_FIELD:-user}" || return 1
  _carto_vault_export CARTO_PAGES_TOKEN \
    "${CARTO_VAULT_PAGES_PATH:-}" "${CARTO_VAULT_PAGES_TOKEN_FIELD:-token}" || return 1
  _carto_vault_export CONFLUENCE_TOKEN \
    "${CARTO_VAULT_CONFLUENCE_PATH:-}" "${CARTO_VAULT_CONFLUENCE_TOKEN_FIELD:-token}" || return 1

  return 0
}
