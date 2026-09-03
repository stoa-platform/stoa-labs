#!/usr/bin/env bash
# scripts/lib/generate-choices.sh — génère les fragments <string>…</string>
# des listes déroulantes Jenkins (équipes, APIs) depuis l'état RÉEL sur
# GITEA MAIN — jamais depuis le worktree local (qui peut être en avance ou en
# retard sur ce qui est réellement mergé). À SOURCER, jamais exécuté seul.
#
# generate_choices_teams <env> : une <string>…</string> par équipe déclarée
#   dans ansible/providers.<env>.yml.
# generate_choices_teams_raw / generate_choices_apis_raw <env> : les MÊMES
#   listes, une VALEUR brute par ligne (A0 : formulaire posé par le Jenkinsfile).
# generate_choices_apis  <env> : une <string>nom@version</string> par API
#   trouvée dans clients/*/apis/*.publish.yml (dépôt plateforme, squelettes
#   déjà onboardés) UNION apis/*.publish.yml des dépôts d'équipe déclarés
#   dans providers.<env>.yml (repo: "" toléré — rien à balayer, pas une erreur).
#
# FAIL-CLOSED (non négociable — le brief de la Task 3) :
#   - Gitea injoignable, providers.<env>.yml absent, ou YAML cassé -> ÉCHEC
#     (return 1, message explicite sur stderr) AVANT que l'appelant ne poste
#     quoi que ce soit à Jenkins.
#   - Liste finale vide -> ÉCHEC aussi. Zéro équipe déclarée = lab pas amorcé,
#     pas un état posable ; un formulaire aux choix vides ne doit JAMAIS
#     partir en silence.
#   - Un dépôt d'équipe DÉCLARÉ mais introuvable sur Gitea (T5/T6 n'ont pas
#     encore livré la chaîne producteur, donc la plupart n'existent pas
#     encore) est TOLÉRÉ : averti sur stderr, ignoré pour cette liste — ce
#     n'est pas la même chose qu'une source cassée. Un fichier
#     apis/*.publish.yml PRÉSENT mais illisible/malformé, lui, EST une
#     source cassée (corruption réelle) et fait échouer tout l'appel : la
#     distinction est délibérée (cf. task-3-report.md).
#
# Entrées (env) :
#   GIT_HOST     défaut http://gitea:3000 (toute forge servant du git HTTP :
#                le clone n'utilise que git, pas l'API de la forge — le refus
#                s'appelle GIT_UNREACHABLE et cite la sortie de git)
#   GIT_REPO     défaut ci/stoa-labs (dépôt plateforme, porte providers.<env>.yml)
#   GITEA_TOKEN  requis (${:?}) — jamais en argv. Un clone en LECTURE n'exige
#                pas forcément un token sur ce Gitea de lab (team-request.sh
#                clone sans lui), mais le brief de cette tâche le demande
#                explicitement et fail-closed ; le header est injecté par
#                GIT_CONFIG_KEY/VALUE (même motif que team-apply.sh/
#                team-request.sh pour leurs push, symétrique en lecture ici).
#
# Sortie : sur stdout, une ligne "<string>valeur échappée</string>" par entrée
# (ordre non garanti pour generate_choices_apis — trié). Rien d'autre sur
# stdout : les diagnostics vont sur stderr, pour un usage sûr en `X=$(fn env)`.
#
# SIGNAL DE TOLÉRANCE (revue round 1) : generate_choices_apis émet, sur
# stderr et SEULEMENT sur le chemin de succès, un marqueur explicite en FIN
# de sortie — motif marqueur de la classe du palier 2 :
#   CHOICES_SKIPPED_REPOS=<n>
# <n> = nombre de dépôts d'équipe DÉCLARÉS mais introuvables sur Gitea,
# tolérés (cf. FAIL-CLOSED plus haut), TOUJOURS émis (y compris n=0) pour
# qu'un grep sache distinguer "zéro sauté" de "marqueur absent" (le second
# cas signifie : generate_choices_apis pas appelée du tout ce run, ex. aucun
# job posé n'a le placeholder APIS). VOLONTAIREMENT sur stderr, jamais
# stdout : stdout devient tel quel le fragment XML inséré par `sed r` dans un
# job Jenkins — y mêler une ligne "CHOICES_SKIPPED_REPOS=…" casserait le XML
# posé. C'est ce marqueur que setup-team-onboard-jobs.sh laisse remonter
# (stderr non capturé par `$(...)`) et que team-apply.sh grep dans son log de
# re-pose MÊME SUR SUCCÈS — sans lui, une re-pose réussie pouvait cacher en
# silence une équipe tolérée/sautée (cf. task-3-report.md, round 1).

# _gc_escape <valeur> — échappe & et < (défense en profondeur : la regex
# ^[a-z0-9][a-z0-9-]{1,30}$ de team-request.sh interdit déjà ces caractères
# dans un nom d'équipe, et le contrat apim_publish_api restreint name/version
# de la même façon côté producteur — mais un fragment XML ne doit JAMAIS
# dépendre UNIQUEMENT d'une garde en amont).
_gc_escape(){
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  printf '%s' "$s"
}

# _gc_clone <repo_fullname> <dest> — clone superficiel (branche main) de
# <repo_fullname> depuis GIT_HOST, EN LECTURE, dans <dest> (déjà créé, vide).
# Le token est injecté en HEADER Basic via GIT_CONFIG_COUNT/KEY/VALUE, jamais
# dans l'URL/argv (motif éprouvé de team-apply.sh — vérifié en direct par
# sondage ps -ww dans ce dépôt, jamais recomposé).
# _GC_CLONE_ERR : la DERNIÈRE erreur de git, expurgée, publiée par _gc_clone.
# Avant (2026-09-03), `2>/dev/null` avalait la cause : un déploiement client ne
# pouvait pas distinguer un hôte injoignable d'un jeton refusé, d'une branche
# `main` absente ou d'un dépôt privé — tous rendus par le même refus muet.
_GC_CLONE_ERR=""
# _gc_redact <texte> — retire la partie userinfo de toute URL (http://user:jeton@hote).
# Vaut pour la sortie de git ET pour GIT_HOST lui-même : un opérateur qui met ses
# identifiants dans GIT_HOST les verrait sinon ressortir par le refus (mesuré).
_gc_redact(){ printf '%s' "$1" | sed -E 's#://[^/@[:space:]]*@#://<identifiants masqués>@#g'; }
_gc_clone(){
  local repo="$1" dest="$2"
  local token="${GITEA_TOKEN:?GITEA_TOKEN requis (generate-choices)}"
  local host="${GIT_HOST:-http://gitea:3000}"
  # GIT_USER : l'utilisateur du Basic. Gitea accepte n'importe lequel avec un
  # PAT, d'où le « x » historique — GitLab et Bitbucket, NON (401). Knob, défaut
  # inchangé. GIT_BASE : la branche de base, knob d'ADR-075 honoré partout
  # ailleurs (provision-request.sh:393) et jusqu'ici IGNORÉ ici — un client dont
  # la branche est `master`/`develop` voyait donc échouer CE clone, et lui seul.
  local user="${GIT_USER:-x}" base="${GIT_BASE:-main}"
  local auth_b64 err rc
  auth_b64=$(printf '%s:%s' "$user" "$token" | base64 | tr -d '\n')
  err=$(mktemp) || { _GC_CLONE_ERR="mktemp indisponible"; return 1; }
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${auth_b64}" \
    git clone -q --depth 1 -b "$base" "${host}/${repo}.git" "$dest" 2>"$err"
  rc=$?
  # expurgation : un identifiant glissé dans GIT_HOST (http://user:jeton@hote)
  # ressortirait par stderr — on ne relaie jamais la partie userinfo d'une URL.
  _GC_CLONE_ERR=$(_gc_redact "$(tr '\n' ' ' < "$err")" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  rm -f "$err"
  return "$rc"
}
# _gc_fetch_main <dest> — le dépôt PLATEFORME, par le réseau… ou pas.
# GC_PLATFORM_DIR : racine d'un dépôt plateforme DÉJÀ présent (opt-in). Un job
# « pipeline from SCM » sur ce dépôt l'a déjà dans le workspace de l'agent
# (lightweight=false) : le re-cloner exige d'un client un hôte joignable, un
# jeton, une branche de base et une traversée de proxy pour lire un fichier
# qu'il a sous la main — et c'est le PREMIER geste réseau de la chaîne, donc le
# premier à tomber (déploiement client 2026-09-03 : EQUIPES_INDISPONIBLES sans
# cause). L'appelant qui pose ce knob AFFIRME que ce répertoire est le dépôt
# plateforme à la bonne révision ; en Jenkins c'est la définition SCM du job qui
# l'assure. Les listes restent de l'ERGONOMIE (l'autorité est dans les gardes).
# FAIL-CLOSED : un knob qui ne porte pas le dépôt ne retombe JAMAIS sur un
# clone — un repli masquerait la méprise de configuration.
_gc_fetch_main(){
  local dest="$1"
  if [ -n "${GC_PLATFORM_DIR:-}" ]; then
    if [ ! -d "${GC_PLATFORM_DIR}/poc-control-plane-federation/ansible" ]; then
      _GC_CLONE_ERR="GC_PLATFORM_DIR=$(_gc_redact "$GC_PLATFORM_DIR") ne porte pas poc-control-plane-federation/ansible — répertoire fourni par l'appelant, aucun repli sur un clone"
      return 1
    fi
    rm -df "$dest" 2>/dev/null
    ln -s "$GC_PLATFORM_DIR" "$dest" 2>/dev/null || {
      _GC_CLONE_ERR="lien vers GC_PLATFORM_DIR impossible ($dest)"; return 1; }
    return 0
  fi
  _gc_clone "${GIT_REPO:-ci/stoa-labs}" "$dest"
}
_gc_fetch_team_repo(){ _gc_clone "$1" "$2"; }                          # dépôt d'équipe

# _gc_collect_publish_yml <dir> <outfile> — ajoute "nom@version" (une ligne
# par match) à <outfile> pour chaque .../apis/*.publish.yml sous <dir>.
# Un fichier ABSENT (rien sous <dir>) n'est pas une erreur. Un fichier
# PRÉSENT mais illisible/malformé (apim_api.name ou .version manquant, YAML
# cassé) FAIT ÉCHOUER l'appel (return 1) — corruption réelle, jamais un skip
# silencieux qui laisserait une API manquante sans que personne ne le sache.
_gc_collect_publish_yml(){
  local dir="$1" outfile="$2" f perr
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    perr=$(mktemp)
    if ! python3 - "$f" <<'PY' >>"$outfile" 2>"$perr"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
api = d.get("apim_api") or {}
name, ver = api.get("name"), api.get("version")
if name and ver:
    print(f"{name}@{ver}")
else:
    sys.exit("apim_api.name/version manquant")
PY
    then
      echo "PUBLISH_YML_PARSE : ${f} illisible — $(cat "$perr")" >&2
      rm -f "$perr"
      return 1
    fi
    rm -f "$perr"
  done < <(find "$dir" -type f -path '*/apis/*.publish.yml' 2>/dev/null | sort)
}

# generate_choices_teams_raw <env> — une équipe par ligne, NON échappée, dans
# l'ordre de providers.<env>.yml. A0 (2026-09-02) : consommée par
# scripts/app-request-choices.sh, qui pose le formulaire app-request depuis son
# Jenkinsfile — il lui faut des VALEURS, pas des fragments XML. Même contrat
# fail-closed que le wrapper XML ci-dessous (qui n'est plus qu'un habillage).
generate_choices_teams_raw(){
  local envn="${1:?env requis (generate_choices_teams)}"
  local work
  work=$(mktemp -d) || { echo "MKTEMP : impossible de créer un répertoire de travail" >&2; return 1; }

  if ! _gc_fetch_main "$work"; then
    echo "GIT_UNREACHABLE : accès au dépôt plateforme ${GIT_REPO:-ci/stoa-labs}@${GIT_BASE:-main} (${GC_PLATFORM_DIR:+répertoire fourni}${GC_PLATFORM_DIR:-clone depuis $(_gc_redact "${GIT_HOST:-http://gitea:3000}")}) en échec — ${_GC_CLONE_ERR:-aucune sortie de git}" >&2
    rm -rf "$work"; return 1
  fi
  local prov="$work/poc-control-plane-federation/ansible/providers.${envn}.yml"
  if [ ! -f "$prov" ]; then
    echo "PROVIDERS_MISSING : ansible/providers.${envn}.yml absent sur main" >&2
    rm -rf "$work"; return 1
  fi

  local perr="$work/.perr" out
  if ! out=$(python3 - "$prov" <<'PY' 2>"$perr"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for p in (d.get("providers") or []):
    t = p.get("team")
    if t:
        print(t)
PY
  ); then
    echo "PROVIDERS_PARSE : providers.${envn}.yml illisible — $(cat "$perr" 2>/dev/null)" >&2
    rm -rf "$work"; return 1
  fi
  rm -rf "$work"

  if [ -z "$out" ]; then
    echo "PROVIDERS_EMPTY : aucune équipe déclarée dans providers.${envn}.yml" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# generate_choices_teams <env> — cf. en-tête : fragments <string>…</string>
# (habillage XML de la variante brute, sortie IDENTIQUE à celle d'avant A0).
generate_choices_teams(){
  local out
  out=$(generate_choices_teams_raw "$1") || return 1
  while IFS= read -r t; do
    [ -n "$t" ] && printf '<string>%s</string>\n' "$(_gc_escape "$t")"
  done <<<"$out"
}

# generate_choices_apis_raw <env> — un « nom@version » par ligne, NON échappé,
# trié (sort -u). Même rôle que generate_choices_teams_raw ; le marqueur
# CHOICES_SKIPPED_REPOS=<n> (stderr) est émis ICI, donc aussi par le wrapper.
generate_choices_apis_raw(){
  local envn="${1:?env requis (generate_choices_apis)}"
  local work
  work=$(mktemp -d) || { echo "MKTEMP : impossible de créer un répertoire de travail" >&2; return 1; }

  if ! _gc_fetch_main "$work/platform"; then
    echo "GIT_UNREACHABLE : accès au dépôt plateforme ${GIT_REPO:-ci/stoa-labs}@${GIT_BASE:-main} (${GC_PLATFORM_DIR:+répertoire fourni}${GC_PLATFORM_DIR:-clone depuis $(_gc_redact "${GIT_HOST:-http://gitea:3000}")}) en échec — ${_GC_CLONE_ERR:-aucune sortie de git}" >&2
    rm -rf "$work"; return 1
  fi
  local root="$work/platform/poc-control-plane-federation"
  local prov="$root/ansible/providers.${envn}.yml"
  if [ ! -f "$prov" ]; then
    echo "PROVIDERS_MISSING : ansible/providers.${envn}.yml absent sur main" >&2
    rm -rf "$work"; return 1
  fi

  local perr="$work/.perr" repos
  if ! repos=$(python3 - "$prov" <<'PY' 2>"$perr"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for p in (d.get("providers") or []):
    r = p.get("repo")
    if r:
        print(r)
PY
  ); then
    echo "PROVIDERS_PARSE : providers.${envn}.yml illisible — $(cat "$perr" 2>/dev/null)" >&2
    rm -rf "$work"; return 1
  fi

  local names="$work/.names"; : > "$names"

  # clients/ du dépôt plateforme lui-même (squelettes ADR-076 déjà onboardés,
  # ex. clients/_example/apis/accounts-read.publish.yml).
  if ! _gc_collect_publish_yml "$root/clients" "$names"; then
    rm -rf "$work"; return 1
  fi

  # dépôts d'équipe déclarés — CHACUN son propre clone (ce sont des dépôts
  # SÉPARÉS de la plateforme, cf. ADR-076, pas des sous-dossiers de
  # ci/stoa-labs). Un dépôt introuvable est attendu tant que T5/T6 n'ont pas
  # livré la chaîne producteur : averti, ignoré POUR CETTE LISTE, pas fatal —
  # mais COMPTÉ (skipped) : le nombre est le signal réutilisable par
  # l'appelant, cf. marqueur CHOICES_SKIPPED_REPOS en fin de fonction.
  local rrepo tw skipped=0
  while IFS= read -r rrepo; do
    [ -n "$rrepo" ] || continue
    tw="$work/team-$(printf '%s' "$rrepo" | tr './' '__')"
    if _gc_fetch_team_repo "$rrepo" "$tw"; then
      if ! _gc_collect_publish_yml "$tw" "$names"; then
        rm -rf "$work"; return 1
      fi
    else
      skipped=$((skipped + 1))
      echo "  (avertissement) dépôt d'équipe ${rrepo} illisible sur main — ignoré pour cette liste" >&2
    fi
  done <<<"$repos"

  local result
  result=$(sort -u "$names" 2>/dev/null)
  rm -rf "$work"

  if [ -z "$result" ]; then
    echo "APIS_EMPTY : aucune API publiée trouvée (clients/ + dépôts d'équipe déclarés)" >&2
    return 1
  fi
  # Marqueur TOUJOURS émis sur le chemin de succès (y compris skipped=0) —
  # cf. en-tête "SIGNAL DE TOLÉRANCE". Émis AVANT les fragments XML pour ne
  # jamais dépendre de l'ordre d'un flush partiel côté appelant ; sur stderr,
  # jamais mêlé au fragment stdout.
  echo "CHOICES_SKIPPED_REPOS=${skipped}" >&2
  printf '%s\n' "$result"
}

# generate_choices_apis <env> — cf. en-tête : fragments <string>…</string>
# (habillage XML de la variante brute, sortie IDENTIQUE à celle d'avant A0).
generate_choices_apis(){
  local out
  out=$(generate_choices_apis_raw "$1") || return 1
  while IFS= read -r n; do
    [ -n "$n" ] && printf '<string>%s</string>\n' "$(_gc_escape "$n")"
  done <<<"$out"
}
