#!/usr/bin/env bash
# scripts/lib/git-base.sh — LA branche par défaut du dépôt de la forge, une autorité.
#
# LE PROBLÈME (2026-09-09, CI client `ci-app-request`, GitLab).
# La chaîne écrivait « main » en dur à 46 endroits exécutés (`-b main`,
# `origin/main`, `"base": "main"`) et dans 155 messages. La branche par défaut
# du client est `master` : deux jours perdus à lire des refus qui parlaient
# d'une branche qui n'existe pas chez lui. Un knob GIT_BASE existait
# (provision-request.sh:192, défaut « main »), ignoré par dix scripts — et son
# défaut « main » est un défaut de SITE que ci/lint-config-knobs.sh ne voit pas
# (« main » y est classé NEUTRE). Ce fichier remplace le défaut par une
# DÉCOUVERTE, et la découverte manquée par un REFUS nommé : jamais « main »
# deviné en silence.
#
# LE CONTRAT.
#   git_base_init [<url>]
#     1. GIT_BASE non vide et ≠ auto  ⇒ GARDÉ tel quel — AUCUN réseau, aucun
#        ls-remote (prouvé par un shim git, test-git-base.sh §B). Une ligne
#        d'information sur stderr dit que le knob est retenu et que la HEAD
#        du dépôt n'est PAS consultée : s'ils divergent, c'est le knob qui gagne.
#        Le knob doit avoir la FORME d'un nom de branche (même garde que la
#        découverte, ci-dessous) : `GIT_BASE=-x` est un REFUS nommé, pas un
#        `git clone -b -x` en aval — et rien n'est découvert à sa place, le
#        knob a été posé exprès (fail-closed).
#     2. sinon                        ⇒ découverte :
#          git ls-remote --symref <url> HEAD | sed -n 's#^ref: refs/heads/\(.*\)\tHEAD$#\1#p'
#        motif PROUVÉ sur Gitea, GitLab, GitHub et un dépôt nu local. L'URL est
#        l'argument, sinon GIT_CLONE_URL.
#     3. rien découvert               ⇒ REFUS: BRANCHE_PAR_DEFAUT_INCONNUE (rc 2),
#        GIT_BASE NON posée — et si la sentinelle `auto` était HÉRITÉE (Jenkins
#        l'exporte), elle est RETIRÉE de l'environnement (unset) : un appelant
#        qui lit GIT_BASE au lieu du rc, ou un enfant, ne voit jamais « auto »
#        passer pour une branche. Un dépôt VIDE (HEAD écrite, aucun commit — ce
#        que rend une forge sur un dépôt tout juste créé) fait rendre à
#        ls-remote une sortie VIDE avec rc 0 (mesuré git 2.42) : c'est ce cas,
#        plus le dépôt injoignable et la HEAD sans la forme d'un nom de branche,
#        qui tombent ici. Un seul tag, la PHRASE distingue.
#     Pose et exporte GIT_BASE et GIT_BASE_ORIGINE=knob|decouverte ; n'écrit
#     RIEN sur stdout (les scripts y lisent leur produit). Idempotent dans le
#     process ; un processus ENFANT qui hérite de GIT_BASE_ORIGINE=decouverte
#     ne rejoue pas la découverte et ne parle pas de knob.
#
#   git_base_of <url>
#     Rend sur stdout (et dans GIT_BASE_OF) la branche par défaut de CE dépôt,
#     découverte puis MÉMOÏSÉE par URL dans le process. Trois familles de
#     dépôts — plateforme, gouvernance, équipe — peuvent avoir trois HEAD : un
#     GIT_BASE global n'est vrai que pour la plateforme. Si un knob explicite
#     GIT_BASE diverge de la HEAD découverte, une ligne d'information le dit ;
#     c'est la HEAD du dépôt qui est rendue, le knob reste intact.
#     La mémo est une variable du process (jamais exportée : une URL peut porter
#     un secret). Appelée en `$(git_base_of …)`, la découverte est juste mais la
#     mémo meurt avec le sous-shell — préférer `git_base_of "$u" >/dev/null &&
#     b=$GIT_BASE_OF` quand plusieurs appels visent la même URL.
#
#   git_base_clone_refus <url> <branche> <fichier-stderr-du-clone> [désignation]
#     LE DIAGNOSTIC D'UN `clone -b <branche>` REFUSÉ, une fois pour toute la
#     chaîne. Écrit le refus NOMMÉ sur stderr et rend :
#       2  la branche n'existe pas sur un dépôt qui a RÉPONDU  (BRANCHE_DE_BASE_INTROUVABLE)
#       1  le dépôt n'a pas répondu                            (DEPOT_INJOIGNABLE)
#     Ne rend JAMAIS 0 : il n'est appelé que sur le chemin d'échec, et
#     l'appelant l'écrit `git_base_clone_refus … || exit $?`.
#     LA DISTINCTION VIENT DE `git ls-remote --exit-code --heads <url>
#     refs/heads/<branche>` (rc 0 / 2 / autre — mesurés 0/2/128, git 2.42),
#     JAMAIS du texte de git : « Remote branch … not found » devient « La
#     branche distante … n'a pas été trouvée » sous une autre locale, et un
#     diagnostic qui dépend de LANG n'en est pas un. Le `ls-remote` hérite de
#     l'environnement de l'appelant, donc de son enveloppe d'authentification,
#     comme le clone qui vient d'échouer. [désignation] est le nom que
#     l'appelant donne au dépôt dans SES termes (ex. `ci/stoa-labs`) — à défaut,
#     l'URL expurgée. Le stderr du clone est relayé, expurgé lui aussi, tronqué
#     à 300 octets et mis sur une ligne.
#
#   git_base_avec_basic <login> <NOM-de-variable-du-secret> <commande…>
#     EXÉCUTE <commande…> sous l'enveloppe `GIT_CONFIG_COUNT=1
#     GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="Authorization:
#     Basic <base64(login:secret)>"`, posée en PRÉFIXE D'ENV sur la commande —
#     bash la passe aux enfants et ne la laisse pas persister après le retour
#     (mesuré). C'est l'enveloppe des clones authentifiés de la chaîne
#     (team-publish, team-promote, api-promote-export) et donc, par contrat de
#     cette lib, celle que la DÉCOUVERTE doit porter aussi : la lib n'embarque
#     aucun secret, elle hérite de l'environnement de son appelant.
#     ⚠ LE 2e ARGUMENT EST LE **NOM** D'UNE VARIABLE, JAMAIS LE SECRET.
#     `ps -Aww` lit l'argv de tout process de la machine : un secret passé là
#     serait lisible pendant toute la durée de la commande (défaut mesuré sur ce
#     dépôt, cf. team-apply.sh). Le nom est déréférencé ici (`${!nom}`) ; le
#     secret ne vit que dans deux variables LOCALES qui meurent au retour.
#     Le LOGIN est un paramètre, et ce n'est pas gratuit : Gitea accepte
#     n'importe quel utilisateur du moment que le mot de passe est un jeton,
#     GitLab et Bitbucket NON. Les appelants d'aujourd'hui passent `x` (le
#     comportement historique) ; celui qui vise une autre forge passe son
#     `${FORGE_USER:-x}`.
#     Refus nommé ENVELOPPE_AUTH_INCOMPLETE (rc 2) si le nom de variable manque,
#     désigne une variable vide, ou si aucune commande n'est donnée : une
#     enveloppe à moitié composée serait une authentification MORTE avec une
#     clé encore visible — exactement le mode de panne que ce fichier existe
#     pour rendre impossible.
#
# LA SENTINELLE « auto », et pourquoi elle existe (même piège que le point de
# repo-layout.sh) : Jenkins n'exporte pas au shell une variable de valeur vide,
# elle arrive ABSENTE du processus. « Découvrir » se dit donc avec un mot,
# `auto`, transportable par une globale. Vide, absent ou auto = découvrir.
#
# AUCUN SECRET ICI. La lib n'en lit, n'en porte et n'en écrit aucun : c'est
# l'APPELANT qui enveloppe le ls-remote comme il enveloppe le clone
# (GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0=…,
# ou GIT_ASKPASS). La lib HÉRITE de l'environnement, elle ne le nettoie pas —
# test-git-base.sh §E prouve que l'enveloppe atteint git. La seule variable
# qu'elle ajoute est GIT_TERMINAL_PROMPT=0 : sans terminal, un dépôt privé sans
# enveloppe doit ÉCHOUER (refus nommé), pas attendre une saisie. Les URL sont
# expurgées de tout `user:secret@` avant d'entrer dans un message.
#
# USAGE
#   . "$(dirname "$0")/lib/git-base.sh"     # ou « . scripts/lib/git-base.sh » depuis la racine
#   git_base_init "$CLONE_URL" || exit 2     # pose GIT_BASE, GIT_BASE_ORIGINE
#   git clone -q --depth 1 -b "$GIT_BASE" "$CLONE_URL" …
#   git_base_of "$TEAM_URL" >/dev/null || exit 2 ; base_equipe="$GIT_BASE_OF"

_GIT_BASE_MEMO="${_GIT_BASE_MEMO:-}"   # « <url>\t<branche>\n »… — jamais exportée
_GIT_BASE_TAB=$'\t'
_GIT_BASE_NL=$'\n'

_git_base_refus() { echo "REFUS: BRANCHE_PAR_DEFAUT_INCONNUE : $1" >&2; }

# _git_base_url_masquee <url> — `scheme://user:secret@hôte` ⇒ `scheme://<masqué>@hôte`.
# git 2.42 expurge déjà l'URL dans « unable to access » ; on n'en dépend pas.
_git_base_url_masquee() { printf '%s' "$1" | sed -E 's#://[^/@[:space:]]+@#://<masqué>@#g'; }

_git_base_memo_lire() {   # <url> → branche sur stdout ; rc 1 si inconnue
  local u b
  [ -n "$_GIT_BASE_MEMO" ] || return 1
  while IFS="$_GIT_BASE_TAB" read -r u b; do
    [ "$u" = "$1" ] && { printf '%s' "$b"; return 0; }
  done <<<"$_GIT_BASE_MEMO"
  return 1
}
_git_base_memo_ecrire() { _GIT_BASE_MEMO="${_GIT_BASE_MEMO}${1}${_GIT_BASE_TAB}${2}${_GIT_BASE_NL}"; }

# _git_base_forme_invalide <nom> — rc 0 si <nom> N'A PAS la forme d'un nom de
# branche : vide, blanc, tiret initial (une option pour `clone -b`), `..`, un
# des caractères que check-ref-format refuse (~ ^ : ? * [ \), `@{`, barre
# initiale/finale/double, composant commençant par `.`, suffixe `.lock`.
# UNE garde pour les deux voies (HEAD annoncée, knob explicite) : ce que la
# découverte refuse, le knob ne le fait pas passer.
_git_base_forme_invalide() {
  case "$1" in
    ''|*[[:space:]]*|-*|*..*|*[~^:?*\[\\]*|*@\{*|/*|*/|*//*|.*|*/.*|*.lock) return 0 ;;
  esac
  return 1
}

# _git_base_decouvrir <url> — la HEAD symbolique du dépôt, sur stdout.
# rc 2 + REFUS nommé (stderr) si le dépôt est injoignable, vide, ou si ce qu'il
# annonce n'a pas la forme d'un nom de branche.
_git_base_decouvrir() {
  local url="$1" masquee err sortie rc branche detail
  masquee="$(_git_base_url_masquee "$url")"
  err="$(mktemp 2>/dev/null)" || err=/dev/null
  sortie=$(GIT_TERMINAL_PROMPT=0 git ls-remote --symref "$url" HEAD 2>"$err"); rc=$?
  detail="$(_git_base_url_masquee "$(head -c 300 "$err" 2>/dev/null | tr '\n' ' ')")"
  [ "$err" = /dev/null ] || rm -f "$err"
  if [ "$rc" -ne 0 ]; then
    _git_base_refus "git ls-remote --symref ${masquee} HEAD a échoué (rc ${rc}) : ${detail:-(sans message)} — dépôt injoignable ou droits insuffisants ; l'enveloppe d'authentification du clone (GIT_CONFIG_*/GIT_ASKPASS) vaut ici aussi ; sinon poser GIT_BASE explicitement"
    return 2
  fi
  branche="$(printf '%s\n' "$sortie" | sed -n 's#^ref: refs/heads/\(.*\)\tHEAD$#\1#p' | head -n 1)"
  [ -n "$branche" ] || { _git_base_refus "${masquee} n'annonce aucune HEAD symbolique (ls-remote rc 0, ${#sortie} octet(s)) — dépôt VIDE (aucun commit) ou HEAD détachée ; « main » n'est jamais deviné : pousser un premier commit, ou poser GIT_BASE explicitement"; return 2; }
  if _git_base_forme_invalide "$branche"; then
    _git_base_refus "${masquee} annonce '${branche}', qui n'a pas la forme d'un nom de branche — poser GIT_BASE explicitement"; return 2
  fi
  printf '%s\n' "$branche"
}

# git_base_init [<url>] — pose et exporte GIT_BASE et GIT_BASE_ORIGINE. Idempotent.
# Sur CHAQUE voie de refus : `unset GIT_BASE` — le contrat dit « NON posée », et
# une sentinelle `auto` héritée (ou un knob difforme) ne doit pas survivre,
# exportée, à un rc 2 ; ce qui n'a jamais été posé n'a rien à perdre.
git_base_init() {
  local url="${1:-${GIT_CLONE_URL:-}}" b
  [ -z "${_GIT_BASE_INIT_FAIT:-}" ] || return 0
  if [ -n "${GIT_BASE:-}" ] && [ "$GIT_BASE" != auto ]; then
    if _git_base_forme_invalide "$GIT_BASE"; then
      _git_base_refus "GIT_BASE='${GIT_BASE}' (knob explicite) n'a pas la forme d'un nom de branche — le knob n'est pas retenu et rien n'est découvert à sa place : corriger GIT_BASE, ou le vider (auto) pour laisser la HEAD du dépôt décider"
      unset GIT_BASE; return 2
    fi
    if [ -z "${GIT_BASE_ORIGINE:-}" ]; then
      # Un knob EXPLICITE, vu pour la première fois. La HEAD n'est pas consultée
      # (zéro réseau, §B) : on ne peut pas dire si elle diverge — on dit ce qui
      # se passe si c'est le cas. Une origine HÉRITÉE (knob ou decouverte,
      # exportée par le parent d'un script enchaîné) a déjà été annoncée : silence.
      GIT_BASE_ORIGINE=knob
      printf 'git-base: GIT_BASE=%s retenu (knob explicite) — la HEAD de %s n'\''est pas consultée ; si elle diffère, le knob gagne\n' \
        "$GIT_BASE" "$([ -n "$url" ] && _git_base_url_masquee "$url" || printf '(dépôt non nommé)')" >&2
    fi
  else
    [ -n "$url" ] || { _git_base_refus "aucun knob GIT_BASE (vide, absent ou auto) et aucune URL de dépôt — ni argument de git_base_init, ni GIT_CLONE_URL : rien à découvrir"; unset GIT_BASE; return 2; }
    b="$(_git_base_decouvrir "$url")" || { unset GIT_BASE; return 2; }
    _git_base_memo_ecrire "$url" "$b"
    GIT_BASE="$b"; GIT_BASE_ORIGINE=decouverte
  fi
  _GIT_BASE_INIT_FAIT=1
  export GIT_BASE GIT_BASE_ORIGINE
}

# git_base_of <url> — la branche par défaut de CE dépôt (stdout + GIT_BASE_OF), mémoïsée.
git_base_of() {
  local url="${1:-}" b
  [ -n "$url" ] || { _git_base_refus "git_base_of exige l'URL du dépôt à interroger"; return 2; }
  if ! b="$(_git_base_memo_lire "$url")"; then
    b="$(_git_base_decouvrir "$url")" || return 2
    _git_base_memo_ecrire "$url" "$b"
    if [ -n "${GIT_BASE:-}" ] && [ "$GIT_BASE" != auto ] && [ "${GIT_BASE_ORIGINE:-knob}" = knob ] && [ "$b" != "$GIT_BASE" ]; then
      printf 'git-base: %s a pour HEAD %s alors que GIT_BASE=%s (knob) — le knob vaut pour la plateforme ; pour ce dépôt, c'\''est %s qui est rendue\n' \
        "$(_git_base_url_masquee "$url")" "$b" "$GIT_BASE" "$b" >&2
    fi
  fi
  # shellcheck disable=SC2034  # posée POUR L'APPELANT (le contrat : stdout + variable, sans sous-shell)
  GIT_BASE_OF="$b"
  printf '%s\n' "$b"
}

# ── git_base_clone_refus : POURQUOI le `-b <branche>` a été refusé ───────────
# Contrat complet dans l'entête. Ne rend jamais 0 ; l'appelant écrit
# `git_base_clone_refus … || exit $?`.
git_base_clone_refus() {
  local url="${1:-}" branche="${2:-}" errf="${3:-}" designation="${4:-}" detail rc=0
  [ -n "$designation" ] || designation="$(_git_base_url_masquee "$url")"
  # Le stderr du clone est relayé, mais git peut y citer l'URL : on n'en relaie
  # jamais la partie userinfo. Une ligne, 300 octets — un dump complet noierait
  # le refus qui le précède.
  detail="$(_git_base_url_masquee "$(head -c 300 "$errf" 2>/dev/null | tr '\n' ' ')")"
  # rc 0 la branche existe (le clone a donc échoué pour une autre raison), rc 2
  # le dépôt a répondu mais ne l'a pas, rc autre le dépôt n'a pas répondu.
  # GIT_TERMINAL_PROMPT=0 comme partout dans cette lib : sans terminal, un dépôt
  # privé sans enveloppe doit ÉCHOUER, jamais attendre une saisie.
  GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --heads "$url" "refs/heads/${branche}" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 2 ]; then
    echo "REFUS: BRANCHE_DE_BASE_INTROUVABLE : ${branche} n'existe pas sur ${designation} — knob GIT_BASE faux, ou dépôt vide ; rien n'a été écrit (git : ${detail:-sans message})" >&2
    return 2
  fi
  echo "REFUS: DEPOT_INJOIGNABLE : ${designation} n'a pas répondu (ls-remote rc ${rc}) — la branche ${branche} n'a donc pas pu être vérifiée ; rien n'a été écrit (git : ${detail:-sans message})" >&2
  return 1
}

# ── git_base_avec_basic : l'enveloppe d'authentification, une fois ───────────
# Contrat complet dans l'entête. Le 2e argument est le NOM d'une variable —
# jamais le secret : argv est lisible par `ps -Aww`.
git_base_avec_basic() {
  local login="${1:-x}" nomvar="${2:-}" secret b64
  [ -n "$nomvar" ] \
    || { echo "REFUS: ENVELOPPE_AUTH_INCOMPLETE : git_base_avec_basic exige le NOM de la variable qui porte le secret (jamais le secret lui-même : argv est lisible par ps -Aww)" >&2; return 2; }
  shift 2
  [ "$#" -gt 0 ] \
    || { echo "REFUS: ENVELOPPE_AUTH_INCOMPLETE : git_base_avec_basic exige une commande à exécuter sous l'enveloppe" >&2; return 2; }
  secret="${!nomvar-}"
  [ -n "$secret" ] \
    || { echo "REFUS: ENVELOPPE_AUTH_INCOMPLETE : la variable '${nomvar}' est vide — une enveloppe à moitié composée est une authentification morte avec une clé encore visible" >&2; return 2; }
  b64="$(printf '%s:%s' "$login" "$secret" | base64 | tr -d '\n')"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic ${b64}" \
    "$@"
}

# ── git_base_xml_substituer : le placeholder des XML de jobs ─────────────────
# LE PROBLÈME (L3, 2026-09-10). Les treize ci/jenkins/*.job.xml portaient
# `<name>*/main</name>`. Chez un client dont la branche par défaut est `master`,
# le job Jenkins checkoutait une branche INEXISTANTE : aucun script de la chaîne
# ne pouvait le rattraper, le mal était fait avant que le pipeline ne démarre.
# La source ne nomme donc plus AUCUNE branche : elle porte `__GIT_BASE__`, et
# c'est le POSEUR qui substitue, une fois, au moment où il envoie le XML.
#
#   git_base_xml_substituer <source> <destination>
#     Écrit <destination> = <source> avec `__GIT_BASE__` remplacé par $GIT_BASE
#     (que git_base_init doit avoir posée : c'est le contrat, pas un défaut).
#     rc 2 + refus nommé si GIT_BASE n'est pas posée, si la source est
#     illisible, si le nom de branche ne peut pas entrer dans du XML (ci-dessous),
#     ou si un `__GIT_BASE__` SURVIT dans le produit — fail-closed : un XML posé
#     avec son placeholder ferait chercher à Jenkins une branche nommée
#     « __GIT_BASE__ », et ce diagnostic-là, personne ne le relie au fichier qui
#     l'a causé.
#
#     ⚠ CE QUI ENTRE DANS UN XML N'EST PAS CE QU'ACCEPTE GIT (revue 4c). Un nom
#     de branche a parfaitement le droit de porter `&`, `<`, `>`, `"` ou `'` :
#     `git check-ref-format` ne refuse que `~ ^ : ? * [ \` et les caractères de
#     contrôle. Or `rel&2.0` inséré tel quel dans `<name>*/rel&2.0</name>` rend
#     un XML MAL FORMÉ, que Jenkins refuse par une SAXParseException — le mode
#     de panne exact que l'en-tête de setup-provision-request-job.sh consigne
#     déjà pour le charset. Échapper vers des entités (`&amp;`) serait pire :
#     le placeholder peut vivre dans un nœud de TEXTE comme dans une valeur
#     d'ATTRIBUT, où les règles diffèrent, et une branche que personne ne
#     retrouverait dans Jenkins vaut moins qu'un refus. Les cinq caractères sont
#     donc REFUSÉS, nommément, AVANT toute écriture : rc 2, rien n'est écrit.
#     Restent échappés pour sed `#` (son délimiteur ici) et `\` (qui ouvre une
#     séquence dans le remplacement) — les deux sont légaux pour git et n'ont
#     aucun sens particulier en XML, donc eux passent.
git_base_xml_substituer() {
  local src="${1:-}" dst="${2:-}" rep
  [ -n "$src" ] && [ -n "$dst" ] \
    || { echo "REFUS: XML_SUBSTITUTION_IMPOSSIBLE : git_base_xml_substituer exige <source> et <destination>" >&2; return 2; }
  [ -r "$src" ] \
    || { echo "REFUS: XML_SUBSTITUTION_IMPOSSIBLE : ${src} introuvable ou illisible — rien n'a été mis en scène" >&2; return 2; }
  { [ -n "${GIT_BASE:-}" ] && [ "$GIT_BASE" != auto ]; } \
    || { echo "REFUS: XML_SUBSTITUTION_IMPOSSIBLE : GIT_BASE n'est pas posée — git_base_init doit être joué AVANT la mise en scène de ${src}" >&2; return 2; }
  # Cinq motifs plutôt qu'une classe `[...]` : une classe qui doit contenir les
  # DEUX guillemets se cite mal, et shellcheck a raison de s'en méfier (SC1003).
  case "$GIT_BASE" in
    *'&'*|*'<'*|*'>'*|*'"'*|*"'"*)
      echo "REFUS: BRANCHE_NON_INSERABLE_XML : la branche '${GIT_BASE}' porte un caractère de balisage (& < > \" ') — un nom de branche portant ces caractères ne peut pas être posé dans un nœud XML sans ambiguïté ; ${dst} n'a PAS été écrit. Renommer la branche, ou poser le XML du job à la main." >&2
      return 2 ;;
  esac
  rep="$(printf '%s' "$GIT_BASE" | sed -e 's/[#\\]/\\&/g')"
  sed "s#__GIT_BASE__#${rep}#g" "$src" > "$dst" \
    || { echo "REFUS: XML_SUBSTITUTION_IMPOSSIBLE : écriture de ${dst} en échec" >&2; return 2; }
  if grep -qF '__GIT_BASE__' "$dst"; then
    echo "REFUS: XML_PLACEHOLDER_RESTANT : ${src} porte encore __GIT_BASE__ après substitution — Jenkins chercherait une branche de ce nom ; rien n'a été envoyé" >&2
    return 2
  fi
}
