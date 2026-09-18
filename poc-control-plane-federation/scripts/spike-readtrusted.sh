#!/usr/bin/env bash
# scripts/spike-readtrusted.sh — JETABLE. UNE question, trois issues nommées.
#
# LA QUESTION : `readTrusted('<chemin>')` fonctionne-t-il dans un job
# **CpsScmFlowDefinition** (« Pipeline script from SCM », notre cas), ou est-il
# réservé aux projets multibranch ?
#
# POURQUOI ELLE DÉCIDE UN LOT. Un client peut créer des credentials mais PAS
# poser de propriétés globales (rapporté le 2026-09-16). Or `WEBHOOK_KIND` est lu
# par le stage RÉCEPTEUR de cinq Jenkinsfile qui tournent en `agent none` —
# délibérément, pour ne pas prendre d'exécuteur sur un build qui n'a rien à
# faire. Sans globale, ce knob vaut son défaut `gwt`, le `properties()` scripté
# invoque `GenericTrigger`, et sur un Jenkins sans ce plugin le job meurt
# « No such DSL method » : exactement le blocage que L6 existait pour lever.
# Un fichier de site VERSIONNÉ le résoudrait — mais il faut pouvoir le lire SANS
# workspace. D'où cette mesure, et rien d'autre.
#
# LES TROIS ISSUES, NOMMÉES AVANT DE LANCER (sans quoi le résultat serait une
# interprétation) :
#   A. INDISPONIBLE — le pas n'existe pas pour ce type de définition, et l'erreur
#      le dit (« only available when the Pipeline is defined in SCM », ou
#      « No such DSL method 'readTrusted' »). ⇒ le fichier de site ne peut pas
#      servir au stage `agent none` ; il faut mesurer les replis.
#   B. MÉCANISME PROUVÉ — le pas répond ET rend le contenu attendu. ⇒ le fichier
#      de site est lisible sans workspace, le lot peut être dessiné.
#   C. CHEMIN SEULEMENT — le pas répond mais le fichier manque
#      (« FileNotFoundException »). ⇒ ça ne prouve QUE la résolution du chemin,
#      pas le mécanisme. C'est pourquoi l'épreuve porte sur un fichier qui
#      EXISTE DÉJÀ sur la branche par défaut, et s'assure de son CONTENU.
#
# DEUX PIÈGES, signalés par la session voisine et intégrés ici :
#   1. LES CHEMINS SONT RELATIFS À LA RACINE DU DÉPÔT, pas au livrable : le
#      `<scriptPath>` d'un job du lab est `poc-control-plane-federation/ci/…`.
#      On éprouve donc `poc-control-plane-federation/ci/lint-eol.sh`, jamais
#      `ci/lint-eol.sh` — qui n'existe pas et n'existera jamais.
#   2. ON N'ÉPROUVE PAS CONTRE UN FICHIER ABSENT : un échec confondrait A et C.
#      Le fichier de contrôle est choisi parce qu'il EST sur la branche, et on
#      assure sur une chaîne connue de son contenu.
#
# CE QU'IL FAUT POUR LE JOUER, et pourquoi ce script ne le fait pas tout seul :
# le job doit être un CpsScmFlowDefinition, donc son pipeline doit vivre DANS le
# dépôt que lit le lab (gitea). Il faut donc y POUSSER une branche jetable
# portant ce Jenkinsfile — ce qui exige un jeton d'écriture sur la forge du lab.
#   SPIKE_BRANCH   nom de la branche jetable (défaut spike/readtrusted)
#   GIT_HOST       vu du POSTE (http://localhost:13000), pour le push
#   GIT_HOST_AGENT vu de l'AGENT (http://gitea:3000), pour le <scm> du job
#   FORGE_SECRET   jeton d'écriture sur ci/stoa-labs
#   JENKINS_UI     le Jenkins à sonder
# La ligne À COPIER pour le lab de ce dépôt (aucune de ces valeurs n'est un
# défaut du script : il refuse si l'une manque) :
#   FORGE_SECRET="<jeton ci>" SPIKE_BRANCH=spike/readtrusted \
#   JENKINS_UI=http://localhost:18080 GIT_HOST=http://localhost:13000 \
#   GIT_HOST_AGENT=http://gitea:3000 GIT_REPO=ci/stoa-labs \
#     bash scripts/spike-readtrusted.sh
# NETTOYAGE : le job ET la branche sont supprimés en sortie, même en échec — et
# une passe SÉPARÉE SONDE ensuite chaque objet (404 sur le job, ls-remote sur la
# branche) au lieu de croire le code de retour des suppressions. Un trap ne peut
# pas être son propre témoin.
# `A && ok || ko` (SC2015) est l'idiome des scripts de PREUVE de ce dépôt — même
# directive que scripts/test-team-apply-wiring.sh, et pour la même raison : ici
# `ok`/`ko`/`note` ne peuvent pas échouer, la branche C n'est donc jamais prise
# à tort. Directive de FICHIER, posée sciemment, pour que ce script tienne le
# jour où quelqu'un l'ajoute à la liste du Makefile (qui joue l'outil SANS `-S`,
# donc au niveau info). ⚠ Une ligne de commentaire qui COMMENCE par le nom de
# l'outil est prise pour une DIRECTIVE (SC1072/SC1073) — mesuré ici même.
# shellcheck disable=SC2015
set -uo pipefail

# pipe_q — `grep -q` sous `set -o pipefail` INVERSE son verdict : il sort à la
# première correspondance, ferme le tuyau, l'écrivain prend un SIGPIPE et rend
# 141, donc le pipeline est non nul PRÉCISÉMENT quand le motif est présent. Le
# piège dépend de la taille du flux, donc il dort. `grep -c` a le MÊME statut de
# sortie (0 si ≥1 ligne, 1 sinon) et lit TOUTE son entrée : aucun SIGPIPE.
# shellcheck disable=SC2329  # MESURÉ : shellcheck 0.11.0 ne voit pas l'invocation
# en PIPELINE de cette fonction dans ces fichiers (0 signalement à HEAD, donc le
# défaut vient bien d'ici), alors qu'il l'accepte sur un script minimal. On perd
# ce signal — et on le REMPLACE : ci/lint-pipe-grepq.sh exige que tout fichier qui
# DÉFINIT pipe_q l'INVOQUE, ce que SC2329 prétend vérifier et fait ici à tort.
pipe_q() { grep -c "$@" >/dev/null; }
cd "$(dirname "$0")/.." || exit 1
# L'ENVELOPPE D'AUTHENTIFICATION DES GESTES GIT — l'autorité unique du dépôt.
# La première écriture de ce spike poussait par une URL contenant le secret :
#   git push "http://x:$FORGE_SECRET@host/repo.git"
# donc le jeton dans l'ARGV de git, lisible par `ps -Aww` pendant toute la
# poussée. Troisième instance du même défaut en deux jours (le jeton de hook
# dans l'argv de curl, le `-c http.extraHeader` de seed-governance-chain), et
# le dépôt porte déjà le refus qui l'interdit : git_base_avec_basic « exige le
# NOM de la variable qui porte le secret, jamais le secret lui-même : argv est
# lisible par tous ». Signalé par la session voisine en relisant ce script.
# shellcheck source=scripts/lib/git-base.sh
. scripts/lib/git-base.sh || { echo "ERREUR: scripts/lib/git-base.sh introuvable" >&2; exit 1; }
gitauth(){ git_base_avec_basic "$(git_base_basic_login)" FORGE_SECRET "$@"; }
JOB=spike-readtrusted
# AUCUN DÉFAUT DE SITE — ce script REFUSE quand une valeur manque, et c'est la
# porte ci/lint-config-knobs.sh qui l'a exigé en rougissant sur cinq d'entre
# elles. Elle avait raison : un spike qui vise silencieusement le mauvais
# Jenkins ou le mauvais dépôt est pire qu'un spike qui ne part pas. Les valeurs
# du lab sont dans l'USAGE ci-dessus (un commentaire n'est pas du code) — on les
# copie sciemment, on ne les hérite pas.
# ⚠ Les spikes existants (spike-webhook-kind-*.sh) portent ce défaut sans être
# signalés : ils assignent à une variable RENOMMÉE (`J="${JENKINS_UI:-…}"`), que
# le motif de la porte ne voit pas. C'est la même limite que celle mesurée le
# 2026-09-13 sur les noms — une règle de forme se contourne en renommant. Dette
# nommée ici, non traitée dans ce spike.
# UN REFUS NOMMÉ, PAS UN `${VAR:?}` DE BASH. La règle du dépôt visait les champs
# de FORMULAIRE (un `${VAR:?}` y rend un numéro de ligne de shell et un nom de
# variable INTERNE, là où le demandeur a rempli un champ qui porte un autre nom).
# Ici l'exploitant passe bien ces noms — mais l'esprit vaut quand même : un refus
# se NOMME et dit le remède, avec rc 2. Une ligne par garde : une ligne se mute
# par sed dans une suite.
requis(){ [ -n "$2" ] || { printf 'REFUS: CONFIG_REQUISE : %s est vide — %s. Rien n a ete tente.\n' "$1" "$3" >&2; exit 2; }; }
requis SPIKE_BRANCH   "${SPIKE_BRANCH:-}"   "nom de la branche JETABLE poussee puis supprimee (lab : spike/readtrusted)"
requis JENKINS_UI     "${JENKINS_UI:-}"     "le Jenkins a sonder (lab : http://localhost:18080)"
requis GIT_HOST       "${GIT_HOST:-}"       "la forge vue du POSTE, pour le clone et la poussee (lab : http://localhost:13000)"
requis GIT_HOST_AGENT "${GIT_HOST_AGENT:-}" "la forge vue de l AGENT, pour le <scm> du job (lab : http://gitea:3000)"
requis GIT_REPO       "${GIT_REPO:-}"       "owner/repo du depot plateforme (lab : ci/stoa-labs)"

# ── LES POST VERS JENKINS EXIGENT UN CRUMB *ET* SON COOKIE (2026-09-17) ──────
# Mesuré : un `curl -X POST .../createItem` nu rend 403, et la sonde s'arretait
# la sans jamais poser sa question. Jenkins veut le jeton anti-CSRF ET la
# session qui l'a emis : le crumb seul ne suffit pas, le cookie seul non plus.
# UN seul helper, pas trois copies aux trois sites de POST (creation, build,
# suppression) : trois copies auraient diverge a la premiere correction.
# ⚠ JAR est calcule A L'APPEL, pas ici : `$TMP` n'existe qu'une cinquantaine de
# lignes plus bas, et sous `set -u` une assignation ici tuerait la sonde sur une
# « unbound variable ». Le piege est sournois : le refus de CONFIG plus haut
# coupe avant, donc un essai a knobs manquants passe au vert sans jamais
# atteindre la ligne fautive. On supprime la dependance d'ordre plutot que de la
# deplacer — un jour quelqu'un reordonnera ce fichier.
#
# PLACEMENT (revue de la session voisine, 2026-09-17) : ce bloc est DESSOUS le
# dernier `requis`, et pas au milieu. L'en-tete de ce fichier promet « rien n'a
# ete tente avant le refus de config » : un lecteur ne doit pas traverser un
# helper pour verifier que la liste des refus est complete.
JAR=""
CRUMB=""
jenkins_crumb(){
  [ -n "$CRUMB" ] && return 0
  # ⚠ PAS `JAR="${JAR:-$TMP/…}"`, malgré l'evidence : ci/lint-config-knobs.sh lit
  # cette forme comme un DEFAUT DE SITE, classe sa valeur en chemin (T3), et la
  # refuse parce qu'elle ne resout pas depuis la racine — mesure, porte rouge.
  # Un test explicite garde la meme paresse sans rien donner a classer.
  [ -n "$JAR" ] || JAR="$TMP/jenkins.cookies"
  CRUMB=$(curl -s -c "$JAR" "$JENKINS_UI/crumbIssuer/api/json" 2>/dev/null \
          | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin); print(d["crumbRequestField"] + ":" + d["crumb"])
except Exception:
    pass' 2>/dev/null)
  [ -n "$CRUMB" ]
}
# jpost <url> [args curl…] — imprime le code HTTP. Sans crumb joignable on NE
# suppose pas que ca passera : on rend 000, et l'appelant refuse en le nommant.
jpost(){
  local url="$1"; shift
  jenkins_crumb || { printf '000'; return 1; }
  curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -H "$CRUMB" -X POST "$url" "$@"
}
TEMOIN="poc-control-plane-federation/ci/lint-eol.sh"
TEMOIN_MOT="PORTE"   # chaîne connue du contenu du témoin
ok(){ printf '  ✅ %s\n' "$*"; }
ko(){ printf '  ❌ %s\n' "$*"; }
note(){ printf '  ℹ %s\n' "$*"; }

[ -n "${FORGE_SECRET:-}" ] || { echo "REFUS: FORGE_SECRET requis — ce spike POUSSE une branche jetable sur ${GIT_REPO}" >&2; exit 2; }
# DEUX POINTS DE VUE SUR LE MÊME FICHIER (corrigé le 2026-09-17). `$TEMOIN` est
# le chemin vu par JENKINS après checkout — c'est celui que `readTrusted` reçoit
# plus bas, et l'en-tête (§ ci-dessus) explique pourquoi il porte le préfixe du
# livrable. Mais ce contrôle-ci est LOCAL, et la ligne `cd "$(dirname "$0")/.."`
# nous a placés DANS `poc-control-plane-federation/` : le même chemin n'y résout
# pas, et la sonde refusait « le témoin ne porte pas PORTE » sur un fichier qui
# le porte quatre fois. Le chemin local est DÉRIVÉ du chemin Jenkins, jamais
# écrit une seconde fois : deux littéraux finiraient par diverger.
TEMOIN_LOCAL="../$TEMOIN"
[ -f "$TEMOIN_LOCAL" ] \
  || { echo "REFUS: le fichier témoin est introuvable depuis le poste ($TEMOIN_LOCAL, soit '$TEMOIN' vu de la racine du dépôt) — l'épreuve B serait vacante" >&2; exit 2; }
grep -q "$TEMOIN_MOT" "$TEMOIN_LOCAL" \
  || { echo "REFUS: le fichier témoin $TEMOIN ne porte pas '$TEMOIN_MOT' — l'épreuve B serait vacante" >&2; exit 2; }

TMP="$(mktemp -d /tmp/spike-rt.XXXXXX)"
# LE NETTOYAGE DIT CE QU'IL A FAIT, et ne l'affirme jamais sans l'avoir mesuré.
# Première écriture : un `push --delete` sur un `origin` cloné ANONYMEMENT, avec
# `2>/dev/null || true`. Sur une forge qui refuse l'écriture anonyme, la
# suppression échouait EN SILENCE et la branche jetable SURVIVAIT — contre ce que
# l'en-tête promet. C'est « annoncer un vert qu'on n'a pas mesuré », appliqué au
# nettoyage, et c'est le pire endroit pour ça : personne ne relit un trap.
nettoyage(){
  local hj hb
  hj=$(jpost "$JENKINS_UI/job/$JOB/doDelete" 2>/dev/null || true)
  case "$hj" in
    200|302|404) note "nettoyage : job $JOB supprimé (HTTP $hj)" ;;
    *)           ko "NETTOYAGE INCOMPLET : job $JOB PEUT-ÊTRE encore présent (HTTP $hj) — à supprimer à la main : $JENKINS_UI/job/$JOB/" ;;
  esac
  if [ -d "$TMP/clone/.git" ] && [ -n "${FORGE_SECRET:-}" ]; then
    if gitauth git -C "$TMP/clone" push -q origin --delete "$SPIKE_BRANCH" 2>"$TMP/del.err"; then
      note "nettoyage : branche $SPIKE_BRANCH supprimée (sous enveloppe authentifiée)"
    else
      ko "NETTOYAGE INCOMPLET : la branche $SPIKE_BRANCH SURVIT sur $GIT_REPO — à supprimer à la main. Cause : $(head -1 "$TMP/del.err" 2>/dev/null)"
      hb=1
    fi
  else
    note "nettoyage : aucune branche à supprimer (le clone ou le secret manquent)"
  fi
  # ── UN TRAP NE PEUT PAS ÊTRE SON PROPRE TÉMOIN (leçon du 2026-09-16) ──
  # Ci-dessus, le nettoyage juge son propre travail sur le code de retour de la
  # SUPPRESSION. Ça ne suffit pas : la session voisine a perdu un job ET un
  # credential sur le Jenkins partagé avec un trap qui imprimait « nettoyage
  # tenté » alors que ses suppressions partaient sans session (son bocal à
  # cookies était effacé AVANT les appels qui s'en servaient — un nettoyage qui
  # détruit ses moyens d'agir avant d'agir). Le code de retour disait oui.
  # D'où une passe SÉPARÉE qui SONDE chaque objet, après coup, sans rien
  # supposer de ce qui précède.
  local hcj brest
  hcj=$(curl -s -o /dev/null -w '%{http_code}' "$JENKINS_UI/job/$JOB/api/json" 2>/dev/null || echo 000)
  case "$hcj" in
    404) note "témoin : le job $JOB est bien ABSENT (HTTP 404 sur son API)" ;;
    *)   ko "TÉMOIN NÉGATIF : le job $JOB RÉPOND ENCORE (HTTP $hcj) — il SURVIT sur un Jenkins partagé : $JENKINS_UI/job/$JOB/" ;;
  esac
  if [ -n "${FORGE_SECRET:-}" ]; then
    brest=$(gitauth git ls-remote --heads "$GIT_HOST/$GIT_REPO.git" "refs/heads/$SPIKE_BRANCH" 2>/dev/null | grep -c . || true)
    case "$brest" in
      0) note "témoin : la branche $SPIKE_BRANCH est bien ABSENTE (ls-remote ne la voit plus)" ;;
      *) ko "TÉMOIN NÉGATIF : la branche $SPIKE_BRANCH EXISTE ENCORE sur $GIT_REPO — à supprimer à la main" ;;
    esac
  else
    ko "TÉMOIN IMPOSSIBLE : sans FORGE_SECRET, la présence de la branche $SPIKE_BRANCH n'a PAS été sondée — ne pas croire ce spike jetable"
  fi
  rm -rf "$TMP"
  [ -n "${hb:-}" ] && printf '  ⚠ le spike n'"'"'est PAS jetable tant que cette branche reste : %s\n' "$SPIKE_BRANCH"
  return 0
}
trap nettoyage EXIT

echo "═══ 0. la branche jetable qui porte le pipeline du spike ═══"
gitauth git clone -q --depth 1 "$GIT_HOST/$GIT_REPO.git" "$TMP/clone" 2>/dev/null \
  || { ko "clone de $GIT_REPO impossible depuis le poste"; exit 1; }
cat > "$TMP/clone/Jenkinsfile.spike-readtrusted" <<'JF'
// ── LECTURE AU NIVEAU SCRIPT (ajout 2026-09-17) ─────────────────────────────
// La 1re passe a prouvé readTrusted DANS un stage. Ce n'est PAS le contexte qui
// décide le gros du lot : les ~40 knobs vivent dans `environment{}`, évalué AU
// PARSE, avant tout stage. On mesure donc ICI, hors du bloc pipeline, et on fait
// CONSOMMER la valeur par un environment{} — un `echo` prouverait la lecture,
// pas son arrivée là où les knobs sont déclarés.
// `catch (Throwable)` et non `catch (e)` : un pas indisponible lève une Error.
def PARSE_LEN = 'NON_TENTE'
def PARSE_ABS = 'NON_TENTE'
try {
  PARSE_LEN = 'OK:' + readTrusted('poc-control-plane-federation/ci/lint-eol.sh').length()
} catch (Throwable e) {
  PARSE_LEN = 'ECHEC:' + e.getClass().getName() + ':' + e.getMessage()
}
try {
  readTrusted('poc-control-plane-federation/ci/site.env')
  PARSE_ABS = 'LU_ALORS_QU_ABSENT'
} catch (Throwable e) {
  PARSE_ABS = e.getClass().getName()
}

pipeline {
  agent none
  environment {
    // LE point : une valeur lue au parse atteint-elle le bloc des knobs ?
    SITE_AU_PARSE = "${PARSE_LEN}"
  }
  stages {
    stage('readTrusted sans workspace') {
      steps {
        script {
          // LE VERDICT DE LA LECTURE AU PARSE (ajout 2026-09-17) — imprimé AVANT
          // les épreuves de stage : c'est le contexte qui décide le gros du lot,
          // puisque les ~40 knobs vivent dans `environment{}`, évalué au parse.
          // SPIKE_ENV prouve l'ARRIVÉE de la valeur là où les knobs sont déclarés ;
          // SPIKE_PARSE dit la lecture elle-même et le contraste du fichier absent.
          echo "SPIKE_PARSE=${PARSE_LEN} absent=${PARSE_ABS}"
          echo "SPIKE_ENV=${env.SITE_AU_PARSE}"
          // ⚠ `catch (Throwable e)` ET NON `catch (e)` : en Groovy, `catch (e)`
          // ne rattrape que les `Exception`. Un STEP INEXISTANT lève une
          // `Error` (NoSuchMethodError), qui passe au travers — le build
          // tomberait en FAILURE et le `echo` de diagnostic n'imprimerait
          // JAMAIS. C'est-à-dire que l'issue A, la plus probable, serait la
          // seule à ne rendre AUCUNE information. Signalé par la session
          // voisine, qui l'a payé d'une passe en sondant configFileProvider.
          // ISSUE A : le pas n'existe pas, ou pas pour ce type de définition.
          // ISSUE B : il rend le contenu (on assure sur une chaîne connue).
          // ISSUE C : il répond mais le fichier manque.
          try {
            def c = readTrusted 'poc-control-plane-federation/ci/lint-eol.sh'
            echo "SPIKE_VERDICT=B_MECANISME_PROUVE longueur=${c.length()} contient_PORTE=${c.contains('PORTE')}"
          } catch (Throwable e) {
            echo "SPIKE_VERDICT=?? classe=${e.getClass().getName()} message=${e.getMessage()}"
          }
          // Le contraste : un fichier ABSENT, pour distinguer A de C.
          try {
            readTrusted 'poc-control-plane-federation/ci/site.env'
            echo "SPIKE_ABSENT=LU_QUAND_MEME (inattendu)"
          } catch (Throwable e) {
            echo "SPIKE_ABSENT=${e.getClass().getName()}: ${e.getMessage()}"
          }
        }
      }
    }
  }
}
JF
( cd "$TMP/clone" && git checkout -q -b "$SPIKE_BRANCH" \
  && git -c user.email=spike@lab -c user.name=spike add Jenkinsfile.spike-readtrusted \
  && git -c user.email=spike@lab -c user.name=spike commit -q -m "spike: readTrusted (jetable)" \
  ) && gitauth git -C "$TMP/clone" push -q origin "$SPIKE_BRANCH" \
  || { ko "push de la branche jetable impossible"; exit 1; }
ok "branche $SPIKE_BRANCH poussée, portant Jenkinsfile.spike-readtrusted"

echo "═══ 1. le job JETABLE, en CpsScmFlowDefinition (le type de NOTRE cas) ═══"
cat > "$TMP/job.xml" <<XML
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>SPIKE JETABLE readTrusted — supprime en sortie</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs><hudson.plugins.git.UserRemoteConfig>
        <url>$GIT_HOST_AGENT/$GIT_REPO.git</url>
      </hudson.plugins.git.UserRemoteConfig></userRemoteConfigs>
      <branches><hudson.plugins.git.BranchSpec><name>*/$SPIKE_BRANCH</name></hudson.plugins.git.BranchSpec></branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile.spike-readtrusted</scriptPath>
    <lightweight>false</lightweight>
  </definition>
  <disabled>false</disabled>
</flow-definition>
XML
HC=$(jpost "$JENKINS_UI/createItem?name=$JOB" \
     -H 'Content-Type: application/xml; charset=utf-8' --data-binary "@$TMP/job.xml")
[ "$HC" = 200 ] && ok "job $JOB créé (HTTP 200)" || { ko "création du job refusée (HTTP $HC)"; exit 1; }

echo "═══ 2. un build, et le VERDICT lu dans sa console ═══"
NB=$(curl -s "$JENKINS_UI/job/$JOB/api/json?tree=nextBuildNumber" | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])')
jpost "$JENKINS_UI/job/$JOB/build" >/dev/null
for _ in $(seq 1 60); do
  R=$(curl -s "$JENKINS_UI/job/$JOB/$NB/api/json?tree=result" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("result") or "")' 2>/dev/null || true)
  [ -n "$R" ] && break; sleep 2
done
CONSOLE=$(curl -s "$JENKINS_UI/job/$JOB/$NB/consoleText")
printf '%s\n' "$CONSOLE" | grep -E 'SPIKE_VERDICT|SPIKE_ABSENT|SPIKE_PARSE|SPIKE_ENV' | sed 's/^/     /'
V=$(printf '%s\n' "$CONSOLE" | grep -oE 'SPIKE_VERDICT=[A-Z_]+' | head -1 | cut -d= -f2)
A=$(printf '%s\n' "$CONSOLE" | grep -oE 'SPIKE_ABSENT=[^ ]+' | head -1)
echo
case "$V" in
  B_MECANISME_PROUVE)
    printf '%s\n' "$CONSOLE" | pipe_q 'contient_PORTE=true' \
      && ok "ISSUE B — readTrusted FONCTIONNE en CpsScmFlowDefinition et rend le CONTENU (témoin assuré). Le fichier de site est lisible SANS workspace." \
      || ko "readTrusted répond mais le contenu ne porte pas '$TEMOIN_MOT' — ne pas conclure B" ;;
  "")
    ko "ISSUE A — readTrusted a levé une exception sur un fichier PRÉSENT : le pas n'est pas disponible pour ce type de définition. Classe/message ci-dessus ; le contraste fichier-absent dit : $A" ;;
  *)
    ko "verdict inattendu '$V' — lire la console ci-dessus, ne rien conclure" ;;
esac
echo "  (build #$NB : $R — console : $JENKINS_UI/job/$JOB/$NB/console)"
