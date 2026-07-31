#!/usr/bin/env bash
# Publication de la carto en Markdown dans un DÉPÔT GIT DÉDIÉ.
#
# Une seule implémentation, appelée par les deux voies du projet : le job
# Jenkins (`poc-control-plane-federation/ci/Jenkinsfile.carto`) et l'enveloppe
# du rôle Ansible (`carto/ansible/roles/carto_collect/`). Écrire la logique de
# commit deux fois, en Groovy et en Jinja, garantissait qu'elles divergent.
#
# ─────────────────────────────────────────────────────────────────────────────
# POURQUOI UN DÉPÔT GIT, ET POURQUOI DÉDIÉ
# ─────────────────────────────────────────────────────────────────────────────
# Chez le client il n'y a pas de serveur web. Il y a git, et une forge qui rend
# le Markdown. Publier là résout d'un coup : où consulter la carto, où faire
# durer l'historique (l'artefact de build disparaît avec la rotation), et sans
# aucune infrastructure nouvelle. Bonus décisif : le `git diff` de la carto
# devient le rapport de changement — « qu'est-ce qui a bougé cette semaine »
# devient une liste de lignes, avec date et auteur.
#
# DÉDIÉ, et non le dépôt de code, pour deux raisons qui ne se négocient pas :
#   - un commit quotidien automatique polluerait l'historique du code, et
#     rendrait `git log` du dépôt de code inutilisable ;
#   - les consommateurs d'API doivent pouvoir lire la carto SANS avoir accès au
#     code. Ce sont deux populations et deux droits différents.
#
# ─────────────────────────────────────────────────────────────────────────────
# LE COMMIT CONDITIONNEL — ARBITRAGE, ET CE QU'IL FAUT EN COMPRENDRE
# ─────────────────────────────────────────────────────────────────────────────
# Règle appliquée : **on ne commite que si le corpus MARKDOWN a changé.**
# Les fichiers de données (`carto.json`, `history.json`, `index.html`) sont
# écrits et embarqués dans le même commit, mais ne le DÉCLENCHENT jamais.
#
# Pourquoi ils ne déclenchent pas :
#   - `history.json` gagne un point PAR JOUR par construction, et `carto.json`
#     porte un `generatedAt` à la microseconde. Les laisser décider produirait
#     un commit quotidien dont le diff Markdown est vide — exactement le bruit
#     qui fait que plus personne ne lit les diffs, donc la fin de l'intérêt de
#     toute la démarche ;
#   - rien n'est perdu : `history.json` est CUMULATIF. Un point non commité
#     aujourd'hui parce que rien n'avait bougé est embarqué tel quel au
#     prochain commit, avec tous les autres. La série reste complète.
#
# Ce que cette règle donne en pratique, et il faut le dire honnêtement : la
# date de collecte fait PARTIE du corpus Markdown (elle est en tête de chaque
# page). Donc une collecte d'un jour nouveau produit toujours au moins un
# commit, dont le diff minimal est le changement de date. Ce n'est pas du
# bruit, c'est le BATTEMENT DE CŒUR de la chaîne : `git log` devient le journal
# de disponibilité du collecteur, et un lecteur voit immédiatement si la carto
# est vivante. En revanche, **rejouer la collecte plusieurs fois le même jour
# ne produit aucun commit** — c'est là que la règle mord réellement, et c'est
# le cas fréquent (relance après échec, double planification, test).
#
# L'alternative écartée : exclure la date du corpus comparé. On aurait alors de
# vrais silences de plusieurs jours — et une page affichant une date vieille de
# trois semaines, sans qu'on puisse distinguer « rien n'a bougé » de « le
# collecteur est mort ». C'est précisément le piège que ce produit combat
# partout ailleurs. La fraîcheur passe avant l'économie de commits.
#
# ─────────────────────────────────────────────────────────────────────────────
# GESTE EXPLOITANT — LE CREDENTIAL D'ÉCRITURE (à poser AVANT le premier passage)
# ─────────────────────────────────────────────────────────────────────────────
# Ce script n'écrit AUCUN identifiant, n'en devine aucun, et n'en a aucun en
# dur. Il lit deux variables d'environnement, et s'arrête en les NOMMANT si
# elles manquent :
#
#   CARTO_PAGES_USER    le compte technique qui pousse dans le dépôt dédié
#   CARTO_PAGES_TOKEN   son jeton d'accès (jamais un mot de passe personnel)
#
# CE QU'IL FAUT POSER, ET SOUS QUELLE IDENTITÉ :
#   1. Créer dans la forge un dépôt DÉDIÉ à la carto (par ex. `carto-apis`),
#      distinct du dépôt de code, lisible par ceux qui doivent consulter la
#      carto.
#   2. Créer un compte de SERVICE (pas le compte d'une personne : un départ ne
#      doit pas arrêter la publication) et lui donner le droit d'ÉCRITURE sur
#      ce seul dépôt. Aucun droit ailleurs.
#   3. Générer pour ce compte un jeton d'accès limité à ce dépôt.
#   4. Déposer ce couple là où la voie d'exécution le lit :
#        - voie Jenkins  : un credential « Username with password »
#          (utilisateur = le compte de service, mot de passe = le jeton),
#          désigné par le paramètre CARTO_PAGES_CREDENTIALS_ID du job ;
#        - voie Ansible  : les variables `carto_pages_user` / `carto_pages_token`
#          fournies depuis le coffre à l'exécution, JAMAIS écrites dans le dépôt.
#   5. Renseigner l'URL du dépôt dédié (CARTO_PAGES_REPO_URL / le paramètre
#      Jenkins CARTO_PAGES_REPO_URL / la variable `carto_pages_repo_url`).
#
# Rotation : quand le jeton expire, la publication échoue en 403 à la première
# poussée. Le remède est de le régénérer et de le remettre au même endroit —
# aucune modification de code.
#
# Le jeton ne transite JAMAIS par la ligne de commande (donc jamais dans la
# table des processus), ni par l'URL du dépôt (donc jamais dans
# `git remote -v`, ni dans `.git/config`, ni dans un message d'erreur de git).
# Il est fourni à git par un assistant `GIT_ASKPASS` qui le lit dans son propre
# environnement.
#
# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────
#   CARTO_PAGES_REPO_URL=https://forge.exemple/equipe/carto-apis.git \
#   CARTO_PAGES_USER=... CARTO_PAGES_TOKEN=... \
#     carto/scripts/publier-markdown.sh --source <répertoire rendu>
#
#   --source DIR   répertoire produit par `python3 -m carto.render` (obligatoire)
#   --no-push      tout faire sauf pousser (répétition à blanc, diagnostic)
#
set -uo pipefail

SOURCE=""
PUSH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    *) echo "option inconnue : $1" >&2; exit 2 ;;
  esac
done

echec() { echo "" >&2; echo "$1" >&2; exit 1; }

[ -n "$SOURCE" ] || echec "--source <répertoire> est obligatoire (sortie de \`python3 -m carto.render\`)."
[ -d "$SOURCE" ] || echec "répertoire source introuvable : $SOURCE"

# Résolution en chemin ABSOLU, ICI, avant tout `cd`. Le script entre plus loin
# dans le dépôt cloné (répertoire temporaire) ; toute variable de chemin reçue
# relative à l'espace de travail de l'appelant (le job Jenkins passe
# `--source carto-pages`, relatif à son propre répertoire) cesserait sinon de
# désigner quoi que ce soit après le changement de répertoire. Le symptôme
# observé était trompeur : « fichier absent de la source » alors que le rendu
# avait parfaitement tourné — seul le chemin ne suivait plus.
SOURCE="$(cd "$SOURCE" && pwd)"

# Les pages ET les données. `git add` se fera par ces chemins NOMMÉS, jamais
# par `git add -A` : d'autres fichiers peuvent vivre dans le dépôt de
# publication (un CODEOWNERS, un LICENSE, une note d'exploitation posée à la
# main) et ce job n'a rien à y faire.
PAGES="README.md consommateurs.md apis.md evolution.md"
DONNEES="carto.json history.json index.html"

# Échouer TÔT et EN NOMMANT ce qui manque : un secret absent ne doit jamais se
# traduire par un échec de git dix lignes plus loin, que l'équipe de support ne
# sait pas relier à un geste.
manquantes=""
for v in CARTO_PAGES_REPO_URL CARTO_PAGES_USER CARTO_PAGES_TOKEN; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || manquantes="$manquantes $v"
done
if [ -n "$manquantes" ]; then
  echec "PUBLICATION MARKDOWN IMPOSSIBLE — configuration absente.

  CE QUI MANQUE :$manquantes

  CE QUE C'EST :
    CARTO_PAGES_REPO_URL  URL du dépôt git DÉDIÉ à la carto (distinct du dépôt
                          de code), en HTTPS.
    CARTO_PAGES_USER      compte de SERVICE ayant le droit d'écriture sur ce
                          seul dépôt (jamais le compte d'une personne).
    CARTO_PAGES_TOKEN     jeton d'accès de ce compte, limité à ce dépôt.

  LE GESTE QUI RÉPARE est décrit en tête de ce script (section « GESTE
  EXPLOITANT »). Rien n'a été publié ; la carto déjà en place dans le dépôt
  dédié reste intacte."
fi

BRANCHE="${CARTO_PAGES_BRANCH:-main}"
AUTEUR_NOM="${CARTO_PAGES_AUTHOR_NAME:-carto (collecteur automatique)}"
AUTEUR_MAIL="${CARTO_PAGES_AUTHOR_EMAIL:-carto@localhost}"

TRAVAIL="$(mktemp -d)"
nettoyer() { rm -rf "$TRAVAIL"; }
trap nettoyer EXIT INT TERM

# L'assistant d'identifiants. git l'appelle avec l'invite en argument ; il
# répond depuis son environnement. Les secrets ne touchent ni le disque en
# clair durable, ni argv, ni l'URL du dépôt.
ASKPASS="$TRAVAIL/askpass.sh"
cat > "$ASKPASS" <<'FIN'
#!/bin/sh
case "$1" in
  Username*|*"Nom d'utilisateur"*) printf '%s' "$CARTO_PAGES_USER" ;;
  *)                               printf '%s' "$CARTO_PAGES_TOKEN" ;;
esac
FIN
chmod 0700 "$ASKPASS"
export GIT_ASKPASS="$ASKPASS"
export GIT_TERMINAL_PROMPT=0     # jamais d'attente sur un TTY : ce job est planifié

DEPOT="$TRAVAIL/depot"
# Clone superficiel : ce job n'a besoin que du DERNIER état publié pour décider
# s'il y a quelque chose de neuf. L'historique complet, qui est justement le
# livrable, n'a aucune raison d'être rapatrié tous les jours.
if ! git clone --depth 1 --branch "$BRANCHE" "$CARTO_PAGES_REPO_URL" "$DEPOT" 2>"$TRAVAIL/clone.log"; then
  # Un dépôt vide (jamais poussé) n'a pas de branche : c'est le cas du tout
  # premier passage, il ne doit pas ressembler à une panne.
  if ! git clone --depth 1 "$CARTO_PAGES_REPO_URL" "$DEPOT" 2>>"$TRAVAIL/clone.log"; then
    sed -e "s#$CARTO_PAGES_TOKEN#***#g" "$TRAVAIL/clone.log" >&2 || true
    echec "clone du dépôt de publication impossible.
  Vérifier CARTO_PAGES_REPO_URL, l'existence du dépôt, et le droit d'écriture
  du compte de service (voir la section « GESTE EXPLOITANT » de ce script).
  Rien n'a été publié."
  fi
  ( cd "$DEPOT" && git checkout -b "$BRANCHE" >/dev/null 2>&1 )
fi

cd "$DEPOT" || echec "dépôt cloné introuvable"
git config user.name  "$AUTEUR_NOM"
git config user.email "$AUTEUR_MAIL"

for f in $PAGES $DONNEES; do
  [ -f "$SOURCE/$f" ] || echec "fichier attendu absent de la source : $SOURCE/$f
  Le rendu a-t-il bien tourné ? (\`python3 -m carto.render --source … --out …\`)"
  cp "$SOURCE/$f" "./$f"
done

# Chemins NOMMÉS, jamais `git add -A` : d'autres sessions et d'autres mains
# travaillent peut-être dans ce dépôt.
git add -- $PAGES $DONNEES

# LA DÉCISION. Elle ne porte QUE sur le corpus Markdown (voir l'arbitrage en
# tête de ce script) : les documents JSON changent tous les jours par
# construction et ne doivent pas fabriquer de commit à eux seuls.
if git diff --cached --quiet -- $PAGES; then
  echo "aucun changement dans les pages Markdown : rien n'est commité."
  echo "  (un diff vide serait du bruit ; le point du jour de history.json est"
  echo "   cumulatif, il partira avec le prochain commit réel — rien n'est perdu)"
  git reset --quiet -- $PAGES $DONNEES
  exit 0
fi

MESSAGE="$SOURCE/.message"
if [ -f "$MESSAGE" ]; then
  git commit --quiet --file "$MESSAGE"
else
  # Repli volontairement pauvre ET explicite : un message générique doit se
  # dénoncer, pas passer pour un résumé.
  git commit --quiet -m "carto : pages régénérées (message détaillé indisponible — rendre avec --message)"
fi

SHA="$(git rev-parse HEAD)"
echo "commit $SHA"
git show --stat --oneline HEAD | sed -n '1,12p'

if [ "$PUSH" != 1 ]; then
  echo "--no-push : le commit reste local, rien n'a été poussé."
  exit 0
fi

if ! git push origin "HEAD:$BRANCHE" 2>"$TRAVAIL/push.log"; then
  sed -e "s#$CARTO_PAGES_TOKEN#***#g" "$TRAVAIL/push.log" >&2 || true
  echec "poussée refusée par la forge.
  Causes les plus fréquentes : jeton expiré ou révoqué (le régénérer et le
  remettre au même endroit — aucune modification de code), droit d'écriture
  retiré au compte de service, ou branche « $BRANCHE » protégée.
  Le commit existe localement mais le clone est jeté : la publication
  précédente reste en place, rien n'est corrompu."
fi
echo "publié sur $BRANCHE."
