#!/usr/bin/env bash
# scripts/lib/generate-choices.sh — génère les fragments <string>…</string>
# des listes déroulantes Jenkins (équipes, APIs) depuis l'état RÉEL sur
# GITEA MAIN — jamais depuis le worktree local (qui peut être en avance ou en
# retard sur ce qui est réellement mergé). À SOURCER, jamais exécuté seul.
#
# generate_choices_teams <env> : une <string>…</string> par équipe déclarée
#   dans ansible/providers.<env>.yml.
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
#   GIT_HOST     défaut http://gitea:3000
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
_gc_clone(){
  local repo="$1" dest="$2"
  local token="${GITEA_TOKEN:?GITEA_TOKEN requis (generate-choices)}"
  local host="${GIT_HOST:-http://gitea:3000}"
  local auth_b64
  auth_b64=$(printf 'x:%s' "$token" | base64 | tr -d '\n')
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${auth_b64}" \
    git clone -q --depth 1 -b main "${host}/${repo}.git" "$dest" 2>/dev/null
}
_gc_fetch_main(){ _gc_clone "${GIT_REPO:-ci/stoa-labs}" "$1"; }        # dépôt plateforme
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

# generate_choices_teams <env> — cf. en-tête.
generate_choices_teams(){
  local envn="${1:?env requis (generate_choices_teams)}"
  local work
  work=$(mktemp -d) || { echo "MKTEMP : impossible de créer un répertoire de travail" >&2; return 1; }

  if ! _gc_fetch_main "$work"; then
    echo "GITEA_UNREACHABLE : clone de ${GIT_REPO:-ci/stoa-labs}@main en échec" >&2
    rm -rf "$work"; return 1
  fi
  local prov="$work/poc-control-plane-federation/ansible/providers.${envn}.yml"
  if [ ! -f "$prov" ]; then
    echo "PROVIDERS_MISSING : ansible/providers.${envn}.yml absent sur main" >&2
    rm -rf "$work"; return 1
  fi

  local perr="$work/.perr" out
  out=$(python3 - "$prov" <<'PY' 2>"$perr"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for p in (d.get("providers") or []):
    t = p.get("team")
    if t:
        print(t)
PY
)
  if [ $? -ne 0 ]; then
    echo "PROVIDERS_PARSE : providers.${envn}.yml illisible — $(cat "$perr" 2>/dev/null)" >&2
    rm -rf "$work"; return 1
  fi
  rm -rf "$work"

  if [ -z "$out" ]; then
    echo "PROVIDERS_EMPTY : aucune équipe déclarée dans providers.${envn}.yml" >&2
    return 1
  fi
  while IFS= read -r t; do
    [ -n "$t" ] && printf '<string>%s</string>\n' "$(_gc_escape "$t")"
  done <<<"$out"
}

# generate_choices_apis <env> — cf. en-tête.
generate_choices_apis(){
  local envn="${1:?env requis (generate_choices_apis)}"
  local work
  work=$(mktemp -d) || { echo "MKTEMP : impossible de créer un répertoire de travail" >&2; return 1; }

  if ! _gc_fetch_main "$work/platform"; then
    echo "GITEA_UNREACHABLE : clone de ${GIT_REPO:-ci/stoa-labs}@main en échec" >&2
    rm -rf "$work"; return 1
  fi
  local root="$work/platform/poc-control-plane-federation"
  local prov="$root/ansible/providers.${envn}.yml"
  if [ ! -f "$prov" ]; then
    echo "PROVIDERS_MISSING : ansible/providers.${envn}.yml absent sur main" >&2
    rm -rf "$work"; return 1
  fi

  local perr="$work/.perr" repos
  repos=$(python3 - "$prov" <<'PY' 2>"$perr"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for p in (d.get("providers") or []):
    r = p.get("repo")
    if r:
        print(r)
PY
)
  if [ $? -ne 0 ]; then
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
  while IFS= read -r n; do
    [ -n "$n" ] && printf '<string>%s</string>\n' "$(_gc_escape "$n")"
  done <<<"$result"
}
