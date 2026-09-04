#!/usr/bin/env bash
# scripts/setup-jenkins-globals.sh — poser les VALEURS DE SITE comme variables
# d'environnement globales du contrôleur Jenkins (Manage Jenkins → System →
# Global properties → Environment variables).
#
# POURQUOI CE SCRIPT EXISTE (analyse de configuration, 2026-09-03).
# La chaîne portait ses valeurs de laboratoire dans les blocs `environment{}` de
# ses pipelines (`GIT_HOST = "${env.GIT_HOST ?: 'http://gitea:3000'}"`, 64 replis
# de ce genre sur 16 fichiers). Mesuré : le lab ne pose PRESQUE aucune variable
# globale — `docker-compose.ci.yml` ne donne que JAVA_OPTS, aucun script
# d'installation n'écrit de propriété globale de nœud, et les deux seules
# présentes ont été posées par des harnais (APPLY_ADMIN_VIA, APIM_DIRECT_BASE_TPL).
# Autrement dit, CES REPLIS SONT la configuration du lab : les retirer sans poser
# les valeurs ailleurs éteint le lab, et avec lui toutes les preuves rejouables.
#
# Ce script est donc le PRÉALABLE au durcissement : il donne aux valeurs un
# domicile hors du code, le même chez un client que sur le lab. Après quoi un
# pipeline peut ne plus rien inventer (`X = "${env.X ?: ''}"`) et le script
# refuser proprement (`${X:?}`) — Jenkins n'exportant pas au shell une variable
# de valeur vide, elle arrive ABSENTE et le refus se déclenche (fait mesuré,
# ci/Jenkinsfile.selfservice:119-123).
#
# CONTRAT
#   Idempotent : rejouable, ne retire jamais une variable qu'il n'a pas posée.
#   Fail-closed : une pose non relue est un échec, jamais un succès annoncé.
#   Aucun secret : ce script pose des ADRESSES et des NOMS. Les identifiants
#   restent dans les credentials Jenkins et dans le coffre — un mot de passe
#   posé ici serait lisible par tout job et par la console de script.
#
# USAGE
#   JENKINS_UI=http://localhost:18080 bash scripts/setup-jenkins-globals.sh --from-env
#   JENKINS_UI=…  bash scripts/setup-jenkins-globals.sh --file site.env
#   JENKINS_UI=…  bash scripts/setup-jenkins-globals.sh --print          # lit, ne pose rien
#   JENKINS_UI=…  bash scripts/setup-jenkins-globals.sh GIT_HOST=https://forge.client GIT_REPO=grp/depot
#
#   --from-env  pose celles des variables CONNUES (liste ci-dessous) qui sont
#               définies et non vides dans l'environnement de ce shell.
#   --file F    lit des lignes `CLE=valeur` (# et lignes vides ignorés).
#   Arguments positionnels `CLE=valeur` : posés tels quels, après contrôle du nom.
#
#   Authentification : JENKINS_USER + JENKINS_TOKEN si l'instance les exige
#   (le lab est anonyme). Le jeton n'est jamais en argv : fichier de config curl.
set -euo pipefail

JENKINS_UI="${JENKINS_UI:?JENKINS_UI requis (ex. https://jenkins.client)}"
JENKINS_UI="${JENKINS_UI%/}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; umask 077
PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
die(){ printf '\nREFUS: %s\n' "$*" >&2; exit 2; }

# Les variables de SITE que la chaîne lit. Ne pas y mettre de secret : ce sont
# des adresses, des chemins et des noms. La liste sert à --from-env et au
# rapport final ; un nom hors liste reste posable explicitement.
CONNUES="
GIT_HOST GIT_WEB_HOST GIT_REPO GIT_BASE GIT_SUBDIR GITEA_CREDENTIALS_ID GITEA_SERVICE_LOGINS
VAULT_ADDR JENKINS_UI ITSM_URL
APIM_API_BASE APIM_DATA_BASE APIM_PROXY_HOST APIM_PROXY_API APIM_PROXY_VER APIM_PROXY_PATH APIM_TERMINUS_BASE
APPLY_TENANT APPLY_JOB APPLY_ADMIN_VIA VAULT_USER_AUTH_MOUNT MANIFEST_DIR INVENTORY STOA_ENV_CHAIN_FILE
CI_COMMIT_EMAIL CI_COMMIT_NAME
"

# ── le canal : console de script Jenkins, jeton par fichier ──────────────────
CFG="$TMP/curl.cfg"
if [ -n "${JENKINS_TOKEN:-}" ]; then
  U="${JENKINS_USER:?JENKINS_USER requis dès lors que JENKINS_TOKEN est fourni}"
  esc(){ printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  printf 'user = "%s:%s"\n' "$(esc "$U")" "$(esc "$JENKINS_TOKEN")" > "$CFG"
else
  : > "$CFG"
fi
jcurl(){ curl -sS --max-time 30 -K "$CFG" "$@"; }

JAR="$TMP/jar"
crumb(){
  local c
  c=$(jcurl -c "$JAR" "$JENKINS_UI/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)" 2>/dev/null || true)
  case "$c" in *:*) printf '%s' "$c";; *) printf '%s' "";; esac
}
# groovy <script> → stdout du script (fail-closed sur transport)
groovy(){
  local cr; cr=$(crumb)
  local args=(-b "$JAR" -X POST --data-urlencode "script=$1" "$JENKINS_UI/scriptText")
  [ -n "$cr" ] && args=(-H "$cr" "${args[@]}")
  jcurl "${args[@]}" || die "JENKINS_INJOIGNABLE : $JENKINS_UI (console de script refusée ou hors service)"
}

LIRE='import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty
def p = Jenkins.instance.globalNodeProperties.get(EnvironmentVariablesNodeProperty)
if (p == null) { println("") } else { p.envVars.each { k, v -> println(k + "=" + v) } }
null'

lire_toutes(){ groovy "$LIRE" | tr -d '\r' | sed '/^$/d; /^Result: /d'; }

poser(){ # <cle> <valeur>
  groovy 'import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty
def j = Jenkins.instance
def p = j.globalNodeProperties.get(EnvironmentVariablesNodeProperty)
if (p == null) { p = new EnvironmentVariablesNodeProperty(); j.globalNodeProperties.add(p) }
p.envVars.put("'"$1"'", "'"$2"'")
j.save()
println("OK")' > /dev/null
}

# ── ce qui est demandé ───────────────────────────────────────────────────────
MODE=""; FICHIER=""; declare -a PAIRES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --print)     MODE=print ;;
    --from-env)  MODE=from-env ;;
    --file)      MODE=fichier; FICHIER="${2:?--file exige un chemin}"; shift ;;
    -h|--help)   sed -n '1,50p' "$0"; exit 0 ;;
    *=*)         PAIRES+=("$1") ;;
    *)           die "ARGUMENT_INCONNU : '$1' (attendu --print, --from-env, --file F, ou CLE=valeur)" ;;
  esac
  shift
done

echo "== variables globales du contrôleur $JENKINS_UI =="
AVANT="$TMP/avant"; lire_toutes > "$AVANT" || true
if [ -s "$AVANT" ]; then
  echo "  déjà posées :"; sed 's/^/    /' "$AVANT"
else
  echo "  aucune variable globale posée (c'est l'état d'un lab neuf)"
fi

if [ "$MODE" = print ]; then
  echo; echo "RÉSULTAT : lecture seule, rien posé."; exit 0
fi

case "$MODE" in
  from-env)
    for k in $CONNUES; do
      v="$(eval "printf '%s' \"\${$k:-}\"")"
      [ -n "$v" ] && PAIRES+=("$k=$v")
    done
    ;;
  fichier)
    [ -f "$FICHIER" ] || die "FICHIER_ABSENT : $FICHIER"
    while IFS= read -r l; do
      case "$l" in ''|'#'*) continue;; esac
      case "$l" in *=*) PAIRES+=("$l");; *) die "LIGNE_INVALIDE : '$l' (attendu CLE=valeur)";; esac
    done < "$FICHIER"
    ;;
esac

[ "${#PAIRES[@]}" -gt 0 ] || die "RIEN_A_POSER : ni --from-env, ni --file, ni argument CLE=valeur"

echo; echo "== pose =="
for p in "${PAIRES[@]}"; do
  k="${p%%=*}"; v="${p#*=}"
  case "$k" in
    [A-Z_]*[A-Z0-9_]|[A-Z_]) : ;;
    *) ko "$k : nom invalide (majuscules, chiffres et souligné)"; continue ;;
  esac
  # garde de secret : ce canal est lisible par tout job, il ne porte pas d'identifiant
  case "$k" in
    *PASSWORD*|*SECRET*|*TOKEN*|*_KEY|*CREDENTIALS)
      case "$k" in
        *CREDENTIALS_ID) : ;;   # un IDENTIFIANT de credential n'est pas un secret
        *) ko "$k : refusé — une variable globale est lisible par tout job ; identifiants dans les credentials Jenkins ou dans le coffre"; continue ;;
      esac ;;
  esac
  case "$v" in *[\"\\]*) ko "$k : la valeur contient un guillemet ou une barre inverse (non transportable par ce canal)"; continue ;; esac

  poser "$k" "$v"
  relu="$(lire_toutes | sed -n "s/^${k}=//p" | head -1)"
  if [ "$relu" = "$v" ]; then ok "$k = $v"; else ko "$k : posé mais relu « ${relu:-<absent>} »"; fi
done

echo
echo "== ce que la chaîne lira =="
APRES="$TMP/apres"; lire_toutes > "$APRES" || true
MANQUE=""
for k in $CONNUES; do
  grep -q "^${k}=" "$APRES" 2>/dev/null || MANQUE="$MANQUE $k"
done
[ -n "$MANQUE" ] && printf '  non posées (le pipeline devra les déclarer, ou le script refusera) :%s\n' "$MANQUE"

echo
printf 'RÉSULTAT : %d posées / %d en échec\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
