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
