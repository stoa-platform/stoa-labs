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
#
# LE PRÉFLIGHT DE JOIGNABILITÉ (APIM_PREFLIGHT*), ET POURQUOI IL EST DOCUMENTÉ ICI
# Avant de consommer une identité nominative (login Vault, mot de passe
# d'annuaire saisi à la main), `publish-api` et `selfservice` sondent la
# gateway — une seule implémentation, `ci/lib/preflight.sh`. Chez un client dont
# l'API d'admin est proxifiée SUR la gateway, `/health` n'est pas joignable
# depuis l'externe (filtré en amont, hors VIP) : le build attend DIX MINUTES
# puis échoue, pour une raison ÉTRANGÈRE au travail demandé. Les quatre knobs
# qui l'évitent existaient déjà dans le code, mais aucune procédure ne les
# nommait : un intégrateur qui la déroulait ne pouvait pas savoir qu'ils
# existent. C'est le mode de panne rencontré (incident client, 2026-09-07).
#
#   APIM_PREFLIGHT=off      ne sonde pas du tout (comparaison insensible à la
#                           casse : « Off », « OFF » désactivent aussi). Le
#                           build le DIT : « préflight de joignabilité :
#                           DÉSACTIVÉ » — jamais un silence.
#   APIM_PREFLIGHT_URL      viser UNE AUTRE sonde de vie que <base>/health.
#                           ⚠ C'EST UN GABARIT PAR PALIER, PAS UNE URL PLATE :
#                           `__ENV__` y est remplacé par le palier du build,
#                           comme dans APIM_PROXY_API (wm-admin-__ENV__) et dans
#                           les sous-chemins Vault (envs/__ENV__/wm-admin).
#                           Une globale de contrôleur vaut pour TOUS les
#                           builds : une valeur plate ferait sonder LE MÊME
#                           palier depuis les quatre autres, et cinq
#                           environnements se liraient vivants alors qu'un seul
#                           l'est. Exemple : https://apim-__ENV__.corp/ping
#                           (une URL plate reste acceptée quand il n'y a
#                           qu'une gateway pour tous les paliers — la trace le
#                           dit alors : « sonde de SITE, la même pour TOUS les
#                           paliers »).
#                           ⚠ LA SUBSTITUTION VAUT POUR CE KNOB, ET POUR LUI
#                           SEUL. Sans APIM_PREFLIGHT_URL, la lib sonde
#                           <base>/health où <base> est reçue TELLE QUELLE de
#                           l'appelant : elle ne la répare pas. Une base
#                           portant encore __ENV__ (APIM_API_BASE ou
#                           APIM_PROXY_BASE posées ici, en globales de SITE,
#                           que rien ne résout par palier) est donc REFUSÉE,
#                           et le refus dit que la faute est dans LA BASE —
#                           pas dans un knob que vous n'avez pas posé ;
#   APIM_PREFLIGHT_CODES    codes qui valent preuve de vie (défaut « 200 401 » :
#                           un 401 SANS jeton EST la preuve de vie d'un proxy
#                           dont l'OAuth2 est déjà enforce) ;
#   APIM_PREFLIGHT_TRIES    nombre d'essais (défaut 60, borné à 3600 par la
#                           lib). ⚠ UN ESSAI COÛTE JUSQU'À 10 s, pas 5 : le
#                           timeout du curl (5 s, consommé ENTIER quand l'hôte
#                           ne répond pas — le cas visé) PUIS l'attente (5 s).
#                           Le défaut vaut donc jusqu'à ~10 minutes, pas 5.
#
# Les APIM_PREFLIGHT* et les FORGE_* sont OPTIONNELLES : absentes, la chaîne
# garde son comportement par défaut, et le rapport final ne les annonce pas
# « manquantes ».
#
# LE CREDENTIAL DE LA FORGE (GITEA_CREDENTIALS_ID, FORGE_CRED_KIND)
# Le secret ne se pose JAMAIS ici : il vit dans le gestionnaire de credentials
# Jenkins, et seuls son IDENTIFIANT et son TYPE sont des globales.
#
#   GITEA_CREDENTIALS_ID    identifiant du credential Jenkins qui porte le
#                           secret de la forge (défaut du lab :
#                           gitea-provision-token).
#   FORGE_CRED_KIND         secret-text (défaut) | username-password — le TYPE
#                           de ce credential, tel que Jenkins le lie :
#                           secret-text = un jeton (« Secret text ») ;
#                           username-password = un couple (« Username with
#                           password », y compris la variante Vault
#                           « Vault Username-Password Credential »). Toute
#                           autre valeur est REFUSÉE par nom AVANT tout
#                           binding (FORGE_CRED_KIND_INVALIDE), et la console
#                           du build dit quel identifiant est lié, en quel
#                           type. Mesuré chez un client le 2026-09-10 : sans ce
#                           knob, Jenkins refusait un couple par « is of type
#                           Vault Username-Password Credential where
#                           StringCredentials was expected » — un message qui
#                           accuse le credential, jamais le knob absent.
#
# LE VISAGE DE LA FORGE (FORGE_KIND, FORGE_API_AUTH, FORGE_API_BASE)
# La chaîne parlait l'API de Gitea en dur ; depuis le 2026-09-09 une seule
# autorité, scripts/lib/forge-api.sh, décide des chemins, des en-têtes et des
# noms de champs selon le visage. Trois knobs : le premier REQUIS, les deux
# autres optionnels (la lib les dérive).
#
#   FORGE_KIND              gitea | gitlab — REQUISE, SANS DÉFAUT (2026-09-12).
#                           Elle a eu `gitea` pour défaut, et c'est ce défaut
#                           qui a fait parler /api/v1 et « Authorization: token »
#                           à un GitLab chez un client, qui répond par une
#                           redirection vers sa page de connexion : le refus
#                           sortait bien (FORGE_ILLISIBLE) mais accusait la
#                           forge, là où il manquait une variable. Absente ou
#                           vide, la chaîne REFUSE maintenant FORGE_KIND_REQUIS
#                           — et les onze Jenkinsfile ont perdu leur repli, sans
#                           quoi ce refus n'aurait jamais pu se déclencher.
#   FORGE_API_AUTH          token | private-token | bearer | basic. ABSENTE, la
#                           lib dérive l'en-tête du visage (token pour Gitea,
#                           PRIVATE-TOKEN pour GitLab) : ne la poser que pour
#                           en SORTIR (un GitLab derrière un portail OAuth2 qui
#                           exige Bearer, un couple user/mot de passe en basic —
#                           basic exige aussi FORGE_USER).
#   FORGE_API_BASE          base d'API COMPLÈTE quand un reverse-proxy la
#                           déplace (ex. https://forge.client/gitlab/api/v4).
#                           ABSENTE, la lib compose GIT_HOST + /api/v1 ou /api/v4.
#
# LA BRANCHE PAR DÉFAUT (GIT_BASE), et pourquoi elle est OPTIONNELLE
# Un client dont la branche par défaut est `master` a perdu deux jours sur des
# refus qui nommaient une branche inexistante chez lui : la chaîne écrivait
# « main » en dur. Une seule autorité en décide désormais,
# scripts/lib/git-base.sh, et son contrat tient en deux lignes :
#
#   GIT_BASE                POSÉE (et ≠ `auto`), elle GAGNE : aucune HEAD n'est
#                           consultée, et si le dépôt en annonce une autre,
#                           c'est le knob qui l'emporte. ABSENTE, vide ou
#                           `auto`, la branche est DÉCOUVERTE sur la HEAD que le
#                           dépôt annonce (`git ls-remote --symref <url> HEAD`).
#                           Découverte impossible — dépôt injoignable, dépôt
#                           VIDE, HEAD sans forme de nom de branche — la chaîne
#                           REFUSE, nommément (BRANCHE_PAR_DEFAUT_INCONNUE) :
#                           « main » n'est jamais deviné en silence.
#
# Ne la poser ici que pour en SORTIR : un dépôt dont la HEAD ne désigne pas la
# branche d'intégration, ou une bascule préparée à l'avance. Le knob vaut pour
# le dépôt PLATEFORME ; la gouvernance et les dépôts d'équipe se voient demander
# LEUR branche, dépôt par dépôt (git_base_of) — trois familles, trois HEAD.
# ⚠ PRÉREQUIS GITLAB : la HEAD d'un projet GitLab est sa « Default branch »
# (Settings → Repository) — c'est elle qu'annonce `ls-remote --symref`. Un
# projet dont la default branch n'est pas celle qu'on veut voir déployer doit
# être corrigé là, ou nommer GIT_BASE ici.
#
# LE RÉCEPTEUR DE WEBHOOKS (WEBHOOK_KIND) — L6, 2026-09-11
#
#   WEBHOOK_KIND            gwt (défaut) | gitlab — le PLUGIN de ce Jenkins qui
#                           reçoit les webhooks de la forge et pose les
#                           variables du build. Ce n'est pas le visage de la
#                           forge (FORGE_KIND) : un GitLab peut être servi par
#                           l'un OU l'autre récepteur.
#
#                           gwt = generic-webhook-trigger. Côté forge, pointer
#                           le hook sur /generic-webhook-trigger/invoke?token=
#                           <token du job> ; les DEUX formes de payload (Gitea
#                           « pull_request », GitLab « Merge Request Hook »)
#                           sont lues sans knob.
#
#                           gitlab = GitLab Plugin, pour un Jenkins qui ne peut
#                           pas recevoir le précédent. Côté GitLab : DEUX
#                           webhooks de projet, événements « Merge request »
#                           SEULEMENT (jamais push), vers
#                           <jenkins>/project/provision-plan et
#                           <jenkins>/project/provision-apply, champ « Secret
#                           Token » = stoa-provision-plan / stoa-provision-apply.
#                           Ce mot est une SONNETTE, pas une autorité : la forge
#                           est relue ensuite (FORGE_NON_CONFIRMEE,
#                           PAYLOAD_PERIME). Plugin >= 1.7.13 exigé
#                           (gitlabMergeCommitSha, la référence A2), et méthode
#                           de merge « merge commit » côté projet — en
#                           fast-forward ou squash le SHA arrive VIDE et l'apply
#                           refuse MERGE_SHA_INVALIDE.
#
#                           Le déclencheur est posé par le Jenkinsfile à son
#                           PREMIER BUILD (l'amorçage, que setup-provision-jobs.sh
#                           attend et relit) ; toute autre valeur est refusée par
#                           NOM avant que rien ne soit posé
#                           (WEBHOOK_KIND_INVALIDE). Sous gitlab,
#                           selfservice-app-deploy n'a AUCUN hook direct : il
#                           n'est atteint que par le `build job:` de
#                           provision-apply.
#
# LE MODE DEBUG SANS FUITE (STOA_DEBUG) — L4, 2026-09-11
#
#   STOA_DEBUG              absente (défaut) | 1 | true — le PLANCHER du mode
#                           debug pour TOUS les builds de ce Jenkins : posée,
#                           chaque script de la chaîne qui source ci/lib/dbg.sh
#                           dit sur stderr ce qu'il décide (disposition,
#                           identité, URL composées, chaque geste git avec son
#                           vrai rc, chaque appel HTTP avec son code), corps
#                           d'erreur RÉDIGÉS, jamais un secret ni un corps de
#                           succès. Les formulaires portent en plus une case
#                           DEBUG (booleanParam) : cochée, elle ALLUME le mode
#                           pour ce build ; décochée, elle n'ÉTEINT PAS la
#                           globale — le plancher reste le plancher. Les jobs
#                           sans formulaire (webhook, pauses) n'ont QUE la
#                           globale. ⚠ dbg_on (ci/lib/dbg.sh) est une liste
#                           d'EXTINCTION : seules vide / 0 / false / off / no
#                           éteignent, TOUTE autre valeur allume — une faute de
#                           frappe (`flase`, `2`) allume le plancher, elle ne
#                           l'éteint pas. Poser 1 ou true, rien d'autre.
#                           Retirer le plancher = le VIDER : `STOA_DEBUG=` en
#                           argument de ce script (ce script n'a pas de verbe de
#                           suppression ; la clé reste listée par --print, à
#                           vide, et Jenkins n'exporte pas une globale vide :
#                           elle arrive ABSENTE au build), ou la vider dans
#                           Jenkins. `--from-env` ne vide jamais (une valeur
#                           vide y est ignorée).
#                           Les lignes sortent préfixées `[dbg …]` : un log
#                           archivé avec STOA_DEBUG posée reste lisible par
#                           un tiers sans lui livrer un secret (L2).
set -euo pipefail

# L'aide = l'entête de commentaire ENTIER (ligne 1 exclue : le shebang), coupé à
# la première ligne de code. Aucun compte de lignes en dur : un compte se périme
# dès qu'on documente une variable de plus, et il se périme EN SILENCE.
aide(){ awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }
# `--help` AVANT tout prérequis : une aide qui exige JENKINS_UI pour s'afficher
# n'est pas une aide — or c'est elle qui NOMME les knobs à un intégrateur qui
# n'a encore rien posé. (Mesuré le 2026-09-07 : `--help` refusait sans elle.)
for _a in ${@+"$@"}; do
  case "$_a" in -h|--help) aide; exit 0 ;; esac
done

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
# Le préflight de joignabilité (APIM_PREFLIGHT*) est décrit dans l'entête de ce
# fichier — donc dans `--help`, qui est le seul endroit où un intégrateur qui
# n'a encore rien posé ira le lire.
CONNUES="
GIT_HOST GIT_WEB_HOST GIT_REPO GIT_BASE GIT_SUBDIR GITEA_CREDENTIALS_ID GITEA_SERVICE_LOGINS
FORGE_KIND FORGE_CRED_KIND FORGE_API_AUTH FORGE_API_BASE FORGE_USER WEBHOOK_KIND STOA_DEBUG
VAULT_ADDR JENKINS_UI ITSM_URL
APIM_API_BASE APIM_DATA_BASE APIM_PROXY_HOST APIM_PROXY_API APIM_PROXY_VER APIM_PROXY_PATH APIM_TERMINUS_BASE
APIM_PREFLIGHT APIM_PREFLIGHT_URL APIM_PREFLIGHT_CODES APIM_PREFLIGHT_TRIES
APPLY_TENANT APPLY_JOB APPLY_ADMIN_VIA VAULT_USER_AUTH_MOUNT MANIFEST_DIR INVENTORY STOA_ENV_CHAIN_FILE
CI_COMMIT_EMAIL CI_COMMIT_NAME
GOVERNANCE_REPO GOVERNANCE_PATH
"

# Parmi les CONNUES, celles dont l'ABSENCE est un état normal : la chaîne garde
# alors son comportement par défaut, et on ne les pose que pour en SORTIR. Elles
# se posent et se relisent comme les autres (--from-env les prend) ; cette liste
# ne sert qu'au rapport final, pour ne pas les annoncer manquantes au même titre
# qu'une adresse sans laquelle le pipeline refuse — ce serait faux, et un
# rapport qui crie au loup ne se lit plus.
#
# ⚠ LE VISAGE DE LA FORGE N'EN FAIT PLUS PARTIE (2026-09-12). `FORGE_KIND` a été
# optionnelle, et ce texte disait « absent, la chaîne parle Gitea » : c'était
# vrai, et c'était le défaut. Un client GitLab qui ne la posait pas voyait la
# chaîne parler l'API de Gitea à un GitLab (302 vers /users/sign_in, corps HTML,
# FORGE_ILLISIBLE — incident du 2026-09-09), sans qu'aucune porte ne puisse le
# dire : les portes ne lisent que les Jenkinsfile DU DÉPÔT, jamais la copie du
# client. Elle est donc REQUISE, les onze Jenkinsfile ont perdu leur repli
# `gitea`, et `forge_api_init` refuse FORGE_KIND_REQUIS quand elle est vide.
# FORGE_API_AUTH et FORGE_API_BASE restent optionnelles : la lib les DÉRIVE du
# visage et de GIT_HOST, et ce sont des dérivations, pas des valeurs de lab.
# La branche par défaut en fait partie depuis L3 : absente (ou `auto`), la
# chaîne la DÉCOUVRE sur la HEAD du dépôt — l'annoncer « manquante » ferait
# poser un littéral, c'est-à-dire exactement le défaut qu'on vient de retirer.
# Le récepteur de webhooks en fait partie depuis L6 : absent, la chaîne pose le
# generic-webhook-trigger (gwt), c'est-à-dire exactement ce qu'elle faisait
# avant ce knob. Le mode debug en fait partie depuis L4 : absent, la chaîne se
# tait — et un rapport qui annoncerait « STOA_DEBUG manquante » inviterait à
# poser un plancher de debug permanent, c'est-à-dire l'inverse d'un opt-in.
OPTIONNELLES="APIM_PREFLIGHT APIM_PREFLIGHT_URL APIM_PREFLIGHT_CODES APIM_PREFLIGHT_TRIES FORGE_CRED_KIND FORGE_API_AUTH FORGE_API_BASE GIT_BASE WEBHOOK_KIND STOA_DEBUG"

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
    # `aide` et non `sed -n '1,50p'` : un compte de lignes en dur RATE toute
    # documentation ajoutee plus bas — c'est arrive le 2026-09-07, la
    # description des knobs du preflight etant inseree aux lignes 58-77, hors
    # de la fenetre. L'aide imprime desormais TOUT l'entete de commentaire, du
    # shebang jusqu'a la premiere ligne de code : elle ne peut plus rater un
    # bloc, et rien n'est a mettre a jour quand l'entete grandit.
    -h|--help)   aide; exit 0 ;;
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
MANQUE=""; MANQUE_OPT=""
for k in $CONNUES; do
  grep -q "^${k}=" "$APRES" 2>/dev/null && continue
  case " $OPTIONNELLES " in
    *" $k "*) MANQUE_OPT="$MANQUE_OPT $k" ;;
    *)        MANQUE="$MANQUE $k" ;;
  esac
done
[ -n "$MANQUE" ] && printf '  non posées (le pipeline devra les déclarer, ou le script refusera) :%s\n' "$MANQUE"
[ -n "$MANQUE_OPT" ] && printf '  non posées, OPTIONNELLES (le défaut est conservé — à poser seulement pour en sortir) :%s\n' "$MANQUE_OPT"

echo
printf 'RÉSULTAT : %d posées / %d en échec\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
