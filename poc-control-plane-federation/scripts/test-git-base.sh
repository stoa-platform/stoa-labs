#!/usr/bin/env bash
# test-git-base.sh — la porte de la BRANCHE PAR DÉFAUT (scripts/lib/git-base.sh).
#
# CE QU'ELLE EMPÊCHE. La chaîne écrivait « main » en dur à 46 endroits exécutés
# (`-b main`, `origin/main`, `"base": "main"`) et dans 155 messages. Un client
# sur GitLab a sa branche par défaut sur `master` : il a perdu DEUX JOURS
# (2026-09-09, CI `ci-app-request`) à lire des refus qui parlaient d'une branche
# qui n'existe pas chez lui. Le knob GIT_BASE existait (provision-request.sh:192)
# mais dix scripts l'ignoraient — et son défaut « main » est un défaut de SITE
# que ci/lint-config-knobs.sh ne voit pas (« main » y est classé NEUTRE).
#
# CE QUE PROUVE CETTE SUITE, sur la lib SEULE (le remplacement des 46 sites est
# un lot suivant) :
#   A. la HEAD du dépôt fait foi — un dépôt HEAD→master rend master, jamais main
#      (c'est le DISCRIMINANT : un code qui suppose main rougit ici sans mutation) ;
#      git_base_init est MUET sur stdout (les scripts y lisent leur produit)
#   B. un knob explicite GAGNE et coûte ZÉRO appel réseau — prouvé par un shim
#      `git` en tête du PATH qui journalise chaque argv ; un knob sans la forme
#      d'un nom de branche (`-x`) est un REFUS, jamais un `clone -b -x` en aval
#   C. un dépôt VIDE (ls-remote ne rend rien, rc 0), injoignable, ou qui annonce
#      un nom sans la forme d'une branche ⇒ REFUS nommé, GIT_BASE NON posée ni
#      exportée (même si `auto` était hérité) — jamais « main » deviné en silence
#   D. git_base_of : une branche PAR DÉPÔT, mémoïsée par URL dans le process —
#      QUATRE appels sur DEUX URL dans le MÊME shell rendent master/main/master/
#      main avec DEUX ls-remote (une mémo qui ignore l'URL rougit : M.4) ; la
#      mémo n'est jamais exportée (une URL peut porter un secret)
#   E. l'enveloppe d'authentification du clone est HÉRITÉE (GIT_CONFIG_COUNT/KEY/
#      VALUE atteignent git : journalisés par le shim ET prouvés par un
#      `url.<x>.insteadOf` qui change ce que ls-remote rend), la lib ne porte
#      aucun secret et n'en imprime aucun — chemin nominal ET refus AVEC
#      enveloppe posée ; GIT_TERMINAL_PROMPT=0 fait refuser un dépôt privé au
#      lieu d'attendre une saisie (git factice qui la simule)
#   F. sourçable des deux façons (`. scripts/lib/…` et `$(dirname $0)/lib/…`)
#   M. mutations sur COPIE — chacune fait rougir l'assertion qu'elle vise, et
#      celle-là seulement quand c'est ce qui est prouvé
#
# TERRAIN : HORS LIGNE intégralement — dépôts nus en file://, forge injoignable
# (127.0.0.1:1), git FACTICE pour ce qu'une fixture ne peut pas produire (une
# HEAD nommée `-x`, un dépôt privé qui demande une saisie). Chaque cas joue la
# lib dans un PROCESSUS NEUF (`env -i`, stdin fermé, ~/.gitconfig et config
# système IGNORÉS) : rien n'y entre que ce que le cas pose, et le shim git est
# le seul git visible. Les fixtures sont SOURDES à la config de l'hôte
# (commit.gpgsign, identité) et la suite S'ARRÊTE (rc 2) si l'une d'elles rate :
# elle ne joue jamais sur un dépôt vide en imputant les rouges à la lib.
#
#   bash scripts/test-git-base.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
LIB="$REPO/scripts/lib/git-base.sh"
TMP="$(mktemp -d /tmp/gitbase.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

# ── le shim git : journalise argv ET l'enveloppe, puis délègue au vrai git ───
# Une ligne par appel : « <argv>|env:count=<COUNT>,key0=<KEY_0>,value0=<VALUE_0> ».
# Le second champ prouve que l'enveloppe d'authentification de l'appelant ARRIVE
# jusqu'à git ENTIÈRE : une lib qui poserait COUNT=0 ou perdrait VALUE_0 aurait
# une authentification morte avec une clé encore visible (M.5).
REAL_GIT="$(command -v git)"
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat > "$SHIM/git" <<'SH'
#!/bin/sh
printf '%s|env:count=%s,key0=%s,value0=%s\n' "$*" "${GIT_CONFIG_COUNT-}" "${GIT_CONFIG_KEY_0-}" "${GIT_CONFIG_VALUE_0-}" >> "$GIT_SHIM_LOG"
exec "$GIT_SHIM_REAL" "$@"
SH
chmod +x "$SHIM/git"
SHIM_LOG="$TMP/shim.log"
nls(){ grep -c 'ls-remote' "$SHIM_LOG"; }   # combien de ls-remote émis par le dernier cas

# ── le git FACTICE : ne délègue à rien, rend ce que le cas lui dicte ─────────
# GIT_SHIM_FAUX=head=<nom> ⇒ un ls-remote qui annonce refs/heads/<nom> — la forme
#   qu'une fixture ne peut pas produire (symbolic-ref refuse d'écrire `-x`).
# GIT_SHIM_FAUX=prive ⇒ un dépôt privé sans enveloppe, comme le git réel : avec
#   GIT_TERMINAL_PROMPT=0 il refuse net (« terminal prompts disabled ») ; sinon il
#   DEMANDE une saisie (journalisée SAISIE_DEMANDEE) — ce qu'un build sans
#   terminal ne doit jamais provoquer.
FAUX="$TMP/faux"; mkdir -p "$FAUX"
cat > "$FAUX/git" <<'SH'
#!/bin/sh
printf '%s|env:count=%s,key0=%s,value0=%s\n' "$*" "${GIT_CONFIG_COUNT-}" "${GIT_CONFIG_KEY_0-}" "${GIT_CONFIG_VALUE_0-}" >> "$GIT_SHIM_LOG"
case "${GIT_SHIM_FAUX-}" in
  head=*) printf 'ref: refs/heads/%s\tHEAD\n0000000000000000000000000000000000000000\tHEAD\n' "${GIT_SHIM_FAUX#head=}"; exit 0 ;;
  prive)
    if [ "${GIT_TERMINAL_PROMPT-}" = 0 ]; then
      printf "fatal: could not read Username for 'http://forge.local': terminal prompts disabled\n" >&2; exit 128
    fi
    echo 'SAISIE_DEMANDEE' >> "$GIT_SHIM_LOG"
    printf "Username for 'http://forge.local': " >&2
    read -r _saisie
    printf 'fatal: Authentication failed\n' >&2; exit 128 ;;
esac
echo "faux git : GIT_SHIM_FAUX='${GIT_SHIM_FAUX-}' inconnu" >&2; exit 99
SH
chmod +x "$FAUX/git"

# ── fixtures : des dépôts nus en file:// ─────────────────────────────────────
# fgit : le git des fixtures, SOURD à la config de l'hôte. Un ~/.gitconfig qui
# signe les commits (commit.gpgsign=true) avec gpg hors du PATH faisait échouer
# commit et push EN SILENCE : la suite jouait sur des dépôts VIDES et imputait
# 18 rouges à la lib (mesuré : 21/39 sous PATH=/usr/bin:/bin:…).
fgit(){ GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }
fixture_ko(){ printf 'FIXTURE %s : %s a échoué — la suite ne joue PAS sur un dépôt vide (rc 2)\n' "$1" "$2" >&2; exit 2; }
# bare <nom> <branche de HEAD> [vide] → URL file://. « vide » : HEAD est posée
# mais AUCUN commit — c'est exactement ce que rend un dépôt tout juste créé sur
# la forge, et `ls-remote --symref … HEAD` n'y rend RIEN (mesuré git 2.42, rc 0).
# Chaque étape qui rate ARRÊTE la suite (exit 2 dans le sous-shell, relayé par
# `|| exit 2` sur l'affectation) : jamais une URL rendue sur un dépôt raté.
bare(){
  local o="$TMP/$1.git" w="$TMP/$1.w"
  { fgit init -q --bare "$o" && fgit -C "$o" symbolic-ref HEAD "refs/heads/$2"; } || fixture_ko "$1" "init --bare / symbolic-ref HEAD"
  if [ "${3:-}" != vide ]; then
    { fgit init -q "$w" && fgit -C "$w" checkout -q -b "$2"; } || fixture_ko "$1" "init / checkout -b $2"
    printf 'init\n' > "$w/README" || fixture_ko "$1" "écriture de README"
    { fgit -C "$w" add -A && fgit -C "$w" commit -qm c0; } || fixture_ko "$1" "commit (signature ? identité ?)"
    fgit -C "$w" push -q "$o" "$2" || fixture_ko "$1" "push $2"
  fi
  printf 'file://%s' "$o"
}
U_MASTER=$(bare master master) || exit 2       # le client
U_MAIN=$(bare main main) || exit 2             # le lab
U_DEVELOP=$(bare develop develop) || exit 2    # une troisième valeur : lue, pas tirée à pile ou face
U_VIDE=$(bare vide main vide) || exit 2        # HEAD→main écrite, mais rien à cloner
U_ABSENT="file://$TMP/absent.git"              # n'existe pas
U_PRIVE="http://forge.local/prive.git"         # servi par le git factice, jamais joint

# ── le harnais : la lib dans un processus NEUF, le shim en tête du PATH ──────
# Le prélude source la lib SOUS TEST (LIB_SOUS_TEST) puis le corps du cas ; la
# lib écrit son produit dans LIB_OUT, le corps photographie l'état dans
# $TMP/out (une ligne, champs « clé=valeur » séparés par des espaces).
# MEMO_ENFANT compte les `_GIT_BASE_MEMO=` dans l'environnement d'un ENFANT :
# la mémo (des URL, donc peut-être des secrets) ne doit jamais y apparaître.
cat > "$TMP/prelude.sh" <<'SH'
. "$LIB_SOUS_TEST" || exit 9
etat(){ printf ' rc=%s GIT_BASE=%s ORIGINE=%s POSE=%s OF=%s ENFANT=%s MEMO_ENFANT=%s\n' \
  "$1" "${GIT_BASE-}" "${GIT_BASE_ORIGINE-}" "${GIT_BASE+x}" "${GIT_BASE_OF-}" \
  "$(env | sed -n 's/^GIT_BASE=//p')" "$(env | grep -c '^_GIT_BASE_MEMO=')"; }
corps="$1"; shift
. "$corps"
SH
# joue <lib> <corps> <url|-> [url2] [VAR=val…] — SHIM_DIR choisit le git visible
# (défaut : le shim délégant ; $FAUX pour le factice). ~/.gitconfig et la config
# système sont IGNORÉS (GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1) : un
# `url.*.insteadOf` ou un credential.helper de l'hôte ne joue pas la découverte.
joue(){
  local lib="$1" corps="$2" u1="$3" u2="${4:--}"; shift 3; [ $# -eq 0 ] || shift
  : > "$SHIM_LOG"; : > "$TMP/lib.out"
  # shellcheck disable=SC2016  # « $0 » est pour le bash ENFANT (le prélude), jamais pour celui-ci
  ( cd "$REPO" && env -i PATH="${SHIM_DIR:-$SHIM}:$PATH" HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      GIT_SHIM_LOG="$SHIM_LOG" GIT_SHIM_REAL="$REAL_GIT" LIB_SOUS_TEST="$lib" LIB_OUT="$TMP/lib.out" "$@" \
      bash -c '. "$0"' "$TMP/prelude.sh" "$corps" "$u1" "$u2" ) > "$TMP/out" 2> "$TMP/err" < /dev/null
  echo $? > "$TMP/rc"
}
rrc(){ cat "$TMP/rc"; }
val(){ grep -o " $1=[^ ]*" "$TMP/out" | head -1 | cut -d= -f2-; }
libout(){ tr -d '\n' < "$TMP/lib.out"; }
detail(){ grep -E 'REFUS|ERREUR|git-base' "$TMP/err" | head -1; }
refus(){ grep -q "^REFUS: BRANCHE_PAR_DEFAUT_INCONNUE : " "$TMP/err"; }
muet(){ [ -z "$(libout)" ]; }               # git_base_init n'a RIEN écrit sur stdout
fuite(){ grep -q "$1" "$TMP/out" "$TMP/err" "$TMP/lib.out"; }   # <sentinelle> vue quelque part ?

# les corps de cas
cat > "$TMP/c-init.sh" <<'SH'
if [ "$1" = - ]; then git_base_init; else git_base_init "$1"; fi > "$LIB_OUT"; rc=$?
etat "$rc"; exit "$rc"
SH
cat > "$TMP/c-init2.sh" <<'SH'
git_base_init "$1" > "$LIB_OUT" && git_base_init "$1" >> "$LIB_OUT"; rc=$?
etat "$rc"; exit "$rc"
SH
# le parent découvre, puis un ENFANT (processus neuf, la lib re-sourcée) hérite
cat > "$TMP/c-enfant.sh" <<'SH'
git_base_init "$1" || exit $?
bash -c '. "$LIB_SOUS_TEST" && git_base_init "$1"; printf "enfant rc=%s GIT_BASE=%s ORIGINE=%s" $? "${GIT_BASE-}" "${GIT_BASE_ORIGINE-}"' _ "$1" > "$LIB_OUT" 2>"$LIB_OUT.err"
etat 0
SH
cat > "$TMP/c-of.sh" <<'SH'
git_base_of "$1" > "$LIB_OUT"; rc=$?
etat "$rc"; exit "$rc"
SH
cat > "$TMP/c-of-memo.sh" <<'SH'
git_base_of "$1" >/dev/null && git_base_of "$1" > "$LIB_OUT"; rc=$?
etat "$rc"; exit "$rc"
SH
# QUATRE appels, DEUX URL, dans le MÊME shell — jamais en `$(…)` : la mémo
# mourrait avec chaque sous-shell et une mémo sans clé resterait invisible.
cat > "$TMP/c-of-deux.sh" <<'SH'
rc=0
git_base_of "$1" >/dev/null || rc=$?; a=${GIT_BASE_OF-}
git_base_of "$2" >/dev/null || rc=$?; b=${GIT_BASE_OF-}
git_base_of "$1" >/dev/null || rc=$?; c=${GIT_BASE_OF-}
git_base_of "$2" >/dev/null || rc=$?; d=${GIT_BASE_OF-}
printf '%s %s %s %s' "$a" "$b" "$c" "$d" > "$LIB_OUT"
etat "$rc"; exit "$rc"
SH
cat > "$TMP/c-init-of.sh" <<'SH'
git_base_init "$1" && git_base_of "$1" > "$LIB_OUT"; rc=$?
etat "$rc"; exit "$rc"
SH
# G/H — les deux helpers de la lib. Le clone est joué POUR DE VRAI (le shim
# délègue au git réel), donc son stderr est celui de git, pas une imitation.
cat > "$TMP/c-clone-refus.sh" <<'SH'
d="${LIB_OUT}.repo"; rm -rf "$d"
git clone -q --depth 1 -b "$2" "$1" "$d" 2>"${LIB_OUT}.err"
git_base_clone_refus "$1" "$2" "${LIB_OUT}.err" "${DESIGNATION:-}"; rc=$?
etat "$rc"; exit "$rc"
SH
cat > "$TMP/c-avec-basic.sh" <<'SH'
git_base_avec_basic "${LOGIN:-x}" SECRET_SONDE git ls-remote --symref "$1" HEAD > "$LIB_OUT"; rc=$?
etat "$rc"; exit "$rc"
SH
cat > "$TMP/c-basic-refus.sh" <<'SH'
case "$2" in
  sansnom) git_base_avec_basic x "" git ls-remote "$1" ;;
  videvar) git_base_avec_basic x VAR_VIDE git ls-remote "$1" ;;
  sanscmd) git_base_avec_basic x SECRET_SONDE ;;
esac
rc=$?; etat "$rc"; exit "$rc"
SH

echo "═══ A. la HEAD du dépôt fait foi — jamais « main » deviné, jamais un mot sur stdout ═══"
# DISCRIMINANT (ce que l'ancien code aurait raté) : le dépôt du client a
# HEAD→master. Un code qui suppose main rend main ici — et rougit. Aucune
# mutation n'est nécessaire pour prouver que ce cas sépare : master ≠ main.
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER"
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = master ] && [ "$(val ORIGINE)" = decouverte ] && muet; then
  ok "A.1 discriminant : HEAD→master, aucun knob ⇒ GIT_BASE=master (origine decouverte), NON main, et stdout VIDE"
else ko "A.1 rc $(rrc) : $(cat "$TMP/out") stdout='$(libout)' $(detail)"; fi
if [ "$(val ENFANT)" = master ]; then ok "A.2 GIT_BASE est EXPORTÉE (un processus enfant la voit)"
else ko "A.2 GIT_BASE non exportée : enfant='$(val ENFANT)'"; fi
if [ "$(nls)" = 1 ]; then ok "A.3 sans knob, exactement UN ls-remote émis (shim)"
else ko "A.3 ls-remote émis : $(nls) — $(cat "$SHIM_LOG")"; fi
if grep -q 'ls-remote --symref' "$SHIM_LOG"; then ok "A.4 la découverte passe par ls-remote --symref (la forme prouvée sur Gitea, GitLab, GitHub et bare)"
else ko "A.4 forme d'appel inattendue : $(cat "$SHIM_LOG")"; fi

joue "$LIB" "$TMP/c-init.sh" "$U_MAIN"
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = main ] && muet; then ok "A.5 non-régression : HEAD→main ⇒ main (le lab), stdout vide"
else ko "A.5 rc $(rrc) : $(cat "$TMP/out") stdout='$(libout)' $(detail)"; fi

joue "$LIB" "$TMP/c-init.sh" "$U_DEVELOP"
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = develop ] && muet; then ok "A.6 HEAD→develop ⇒ develop (une troisième valeur : la HEAD est LUE), stdout vide"
else ko "A.6 rc $(rrc) : $(cat "$TMP/out") stdout='$(libout)' $(detail)"; fi

echo "═══ B. le knob explicite gagne, ne coûte AUCUN appel réseau, et doit avoir la forme d'une branche ═══"
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER" - GIT_BASE=develop
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = develop ] && [ "$(val ORIGINE)" = knob ] && muet; then
  ok "B.1 GIT_BASE=develop explicite sur un dépôt HEAD→master ⇒ develop (origine knob), stdout vide"
else ko "B.1 rc $(rrc) : $(cat "$TMP/out") stdout='$(libout)' $(detail)"; fi
if [ "$(nls)" = 0 ]; then ok "B.2 avec un knob explicite, AUCUN ls-remote émis (shim : $(wc -l < "$SHIM_LOG" | tr -d ' ') appel(s) git)"
else ko "B.2 ls-remote émis malgré le knob : $(cat "$SHIM_LOG")"; fi
if grep -q '^git-base: GIT_BASE=develop' "$TMP/err" && grep -q 'knob' "$TMP/err" && ! grep -q 'REFUS' "$TMP/err"; then
  ok "B.3 une ligne d'information sur stderr dit que le knob est retenu et que la HEAD n'est pas consultée"
else ko "B.3 stderr : $(head -2 "$TMP/err" | tr '\n' ' ')"; fi

joue "$LIB" "$TMP/c-init.sh" "$U_MASTER" - GIT_BASE=auto
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = master ] && [ "$(val ORIGINE)" = decouverte ] && [ "$(nls)" = 1 ] && muet; then
  ok "B.4 sentinelle GIT_BASE=auto ⇒ découverte (Jenkins n'exporte pas une variable vide)"
else ko "B.4 rc $(rrc) : $(cat "$TMP/out") ls-remote=$(nls) stdout='$(libout)' $(detail)"; fi

joue "$LIB" "$TMP/c-init.sh" "$U_MASTER" - GIT_BASE=
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = master ] && [ "$(val ORIGINE)" = decouverte ] && muet; then
  ok "B.5 GIT_BASE vide (la forme des harnais) ⇒ découverte"
else ko "B.5 rc $(rrc) : $(cat "$TMP/out") stdout='$(libout)' $(detail)"; fi

joue "$LIB" "$TMP/c-init2.sh" "$U_MASTER"
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = master ] && [ "$(val ORIGINE)" = decouverte ] && [ "$(nls)" = 1 ] && muet; then
  ok "B.6 idempotence : deux git_base_init dans le même process ⇒ une seule découverte, l'origine reste decouverte, stdout vide"
else ko "B.6 rc $(rrc) : $(cat "$TMP/out") ls-remote=$(nls) stdout='$(libout)'"; fi

joue "$LIB" "$TMP/c-enfant.sh" "$U_MASTER"
if grep -q 'enfant rc=0 GIT_BASE=master ORIGINE=decouverte' "$TMP/lib.out" && [ "$(nls)" = 1 ] && ! grep -q 'git-base:' "$TMP/lib.out.err"; then
  ok "B.7 un enfant hérite de la découverte du parent (export) : aucun second ls-remote, aucune ligne « knob »"
else ko "B.7 enfant : $(cat "$TMP/lib.out") ls-remote=$(nls) err=$(head -1 "$TMP/lib.out.err" 2>/dev/null)"; fi

# Un script ENCHAÎNÉ (provision-request → plan) hérite du knob ET de son origine :
# le parent l'a annoncé, l'enfant se tait — une ligne par build, pas par processus.
joue "$LIB" "$TMP/c-enfant.sh" "$U_MASTER" - GIT_BASE=develop
if grep -q 'enfant rc=0 GIT_BASE=develop ORIGINE=knob' "$TMP/lib.out" && [ "$(nls)" = 0 ] \
   && grep -q '^git-base: GIT_BASE=develop' "$TMP/err" && ! grep -q 'git-base:' "$TMP/lib.out.err"; then
  ok "B.8 un enfant hérite du knob annoncé par le parent : develop gardé, zéro ls-remote, la ligne n'est pas répétée"
else ko "B.8 enfant : $(cat "$TMP/lib.out") ls-remote=$(nls) parent=$(grep -c 'git-base:' "$TMP/err") enfant=$(grep -c 'git-base:' "$TMP/lib.out.err" 2>/dev/null)"; fi

# Un knob qui n'a pas la forme d'un nom de branche : retenu tel quel, il arrive
# en `git clone -b -x` en aval — un refus nommé ici, avant tout réseau, et rien
# n'est découvert à sa place (le knob a été posé exprès : fail-closed).
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER" - GIT_BASE=-x
if [ "$(rrc)" = 2 ] && refus && grep -q "knob" "$TMP/err" && grep -q "forme d'un nom de branche" "$TMP/err" \
   && [ -z "$(val POSE)" ] && [ -z "$(val ENFANT)" ] && [ "$(nls)" = 0 ] && muet; then
  ok "B.9 GIT_BASE=-x explicite ⇒ REFUS nommé (la phrase dit knob + forme), rc 2, GIT_BASE ni posée ni exportée, zéro ls-remote"
else ko "B.9 rc $(rrc) : $(cat "$TMP/out") ls-remote=$(nls) $(detail)"; fi

echo "═══ C. le refus : dépôt vide, injoignable, sans URL, HEAD difforme — jamais un défaut muet ═══"
joue "$LIB" "$TMP/c-init.sh" "$U_VIDE"
if [ "$(rrc)" = 2 ] && refus && [ -z "$(val POSE)" ] && [ -z "$(val ORIGINE)" ] && muet; then
  ok "C.1 dépôt VIDE (HEAD→main écrite, aucun commit) ⇒ REFUS: BRANCHE_PAR_DEFAUT_INCONNUE, rc 2, GIT_BASE NON posée, stdout vide"
else ko "C.1 rc $(rrc) : $(cat "$TMP/out") $(detail)"; fi
if grep -q "BRANCHE_PAR_DEFAUT_INCONNUE : .*$TMP/vide.git" "$TMP/err" && grep -q 'GIT_BASE' "$TMP/err"; then
  ok "C.2 le refus NOMME le dépôt lu et dit le remède (poser GIT_BASE) — auto-diagnostique"
else ko "C.2 refus non auto-diagnostique : $(detail)"; fi

joue "$LIB" "$TMP/c-init.sh" "$U_ABSENT"
if [ "$(rrc)" = 2 ] && refus && [ -z "$(val POSE)" ]; then
  ok "C.3 dépôt injoignable ⇒ même tag, rc 2, GIT_BASE non posée (la distinction vit dans la phrase)"
else ko "C.3 rc $(rrc) : $(cat "$TMP/out") $(detail)"; fi
if grep -q 'ls-remote' "$TMP/err" && grep -qE 'rc [0-9]+' "$TMP/err"; then
  ok "C.4 la phrase porte l'appel qui a échoué et son rc (ce que le client verra)"
else ko "C.4 phrase muette : $(detail)"; fi

joue "$LIB" "$TMP/c-init.sh" -
if [ "$(rrc)" = 2 ] && refus && grep -q 'GIT_CLONE_URL' "$TMP/err"; then
  ok "C.5 ni argument, ni GIT_CLONE_URL, ni knob ⇒ refus qui nomme les deux voies manquantes"
else ko "C.5 rc $(rrc) : $(detail)"; fi

joue "$LIB" "$TMP/c-init.sh" - - "GIT_CLONE_URL=$U_MASTER"
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = master ] && muet; then
  ok "C.6 sans argument, GIT_CLONE_URL porte l'URL à découvrir ⇒ master"
else ko "C.6 rc $(rrc) : $(cat "$TMP/out") stdout='$(libout)' $(detail)"; fi

joue "$LIB" "$TMP/c-init.sh" "$U_VIDE" - GIT_BASE=main
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = main ] && [ "$(val ORIGINE)" = knob ] && [ "$(nls)" = 0 ] && muet; then
  ok "C.7 sur un dépôt vide, le knob explicite est la SEULE voie — et il ne touche pas au réseau"
else ko "C.7 rc $(rrc) : $(cat "$TMP/out") ls-remote=$(nls)"; fi

# Une HEAD qui annonce un nom sans la forme d'une branche — le git factice la
# sert (une fixture ne peut pas : symbolic-ref refuse d'écrire `-x`).
SHIM_DIR="$FAUX" joue "$LIB" "$TMP/c-init.sh" "$U_PRIVE" - GIT_SHIM_FAUX=head=-x
if [ "$(rrc)" = 2 ] && refus && grep -q "'-x'" "$TMP/err" && grep -q "forme d'un nom de branche" "$TMP/err" && [ -z "$(val POSE)" ] && muet; then
  ok "C.8 HEAD annoncée '-x' ⇒ REFUS nommé (la phrase cite le nom et dit « forme »), GIT_BASE non posée — jamais un clone -b -x"
else ko "C.8 rc $(rrc) : $(cat "$TMP/out") $(detail)"; fi
SHIM_DIR="$FAUX" joue "$LIB" "$TMP/c-init.sh" "$U_PRIVE" - "GIT_SHIM_FAUX=head=x y"
if [ "$(rrc)" = 2 ] && refus && grep -q "'x y'" "$TMP/err" && [ -z "$(val POSE)" ]; then
  ok "C.9 HEAD annoncée 'x y' (espace) ⇒ même refus"
else ko "C.9 rc $(rrc) : $(cat "$TMP/out") $(detail)"; fi

# Jenkins exporte la sentinelle : GIT_BASE=auto est HÉRITÉ. Après un refus, elle
# ne doit pas rester posée ni exportée — un appelant qui teste `[ -n "$GIT_BASE" ]`
# au lieu du rc serait trompé, et un enfant recevrait « auto » comme une branche.
joue "$LIB" "$TMP/c-init.sh" "$U_VIDE" - GIT_BASE=auto
if [ "$(rrc)" = 2 ] && refus && [ -z "$(val POSE)" ] && [ -z "$(val ENFANT)" ] && [ -z "$(val ORIGINE)" ]; then
  ok "C.10 GIT_BASE=auto hérité + dépôt vide ⇒ refus, et GIT_BASE n'est NI posée NI exportée (auto retiré de l'environnement)"
else ko "C.10 rc $(rrc) : $(cat "$TMP/out") $(detail)"; fi

echo "═══ D. git_base_of : une branche PAR DÉPÔT, mémoïsée par URL, jamais exportée ═══"
joue "$LIB" "$TMP/c-of.sh" "$U_MASTER"
if [ "$(rrc)" = 0 ] && [ "$(libout)" = master ] && [ "$(val OF)" = master ]; then
  ok "D.1 git_base_of <url HEAD→master> ⇒ master sur stdout et dans GIT_BASE_OF"
else ko "D.1 rc $(rrc) : stdout='$(libout)' $(cat "$TMP/out") $(detail)"; fi
if [ -z "$(val POSE)" ]; then ok "D.2 git_base_of ne pose PAS GIT_BASE (ce n'est pas la base de la plateforme)"
else ko "D.2 GIT_BASE posée par git_base_of : $(val GIT_BASE)"; fi

joue "$LIB" "$TMP/c-of-memo.sh" "$U_MASTER"
if [ "$(rrc)" = 0 ] && [ "$(libout)" = master ] && [ "$(nls)" = 1 ]; then
  ok "D.3 mémo : deux git_base_of sur la même URL ⇒ UN seul ls-remote"
else ko "D.3 rc $(rrc) : stdout='$(libout)' ls-remote=$(nls)"; fi

# Le MÊME shell, quatre appels, deux URL : master main master main, DEUX
# ls-remote. Une mémo qui rend la première branche connue pour toute URL
# rendrait « master master master master » avec UN ls-remote (M.4).
joue "$LIB" "$TMP/c-of-deux.sh" "$U_MASTER" "$U_MAIN"
if [ "$(rrc)" = 0 ] && [ "$(libout)" = "master main master main" ] && [ "$(nls)" = 2 ]; then
  ok "D.4 deux URL, quatre appels dans le MÊME shell ⇒ master main master main, DEUX ls-remote (la mémo distingue les URL)"
else ko "D.4 rc $(rrc) : stdout='$(libout)' ls-remote=$(nls) $(detail)"; fi

joue "$LIB" "$TMP/c-init-of.sh" "$U_MASTER"
if [ "$(rrc)" = 0 ] && [ "$(libout)" = master ] && [ "$(nls)" = 1 ]; then
  ok "D.5 git_base_init a découvert ⇒ git_base_of de la MÊME URL ne rejoue pas ls-remote (mémo partagée)"
else ko "D.5 rc $(rrc) : stdout='$(libout)' ls-remote=$(nls)"; fi

joue "$LIB" "$TMP/c-init-of.sh" "$U_MASTER" - GIT_BASE=develop
if [ "$(rrc)" = 0 ] && [ "$(libout)" = master ] && [ "$(val GIT_BASE)" = develop ] && [ "$(nls)" = 1 ]; then
  ok "D.6 knob=develop + git_base_of ⇒ master rendu, GIT_BASE=develop intact (le knob n'est vrai que pour la plateforme)"
else ko "D.6 rc $(rrc) : stdout='$(libout)' $(cat "$TMP/out") ls-remote=$(nls)"; fi
if grep -q '^git-base: .*master' "$TMP/err" && grep -q 'develop' "$TMP/err"; then
  ok "D.7 la divergence knob/découverte est DITE sur stderr, avec les deux valeurs"
else ko "D.7 divergence muette : $(grep 'git-base' "$TMP/err" | tr '\n' ' ')"; fi

joue "$LIB" "$TMP/c-of.sh" "$U_VIDE"
if [ "$(rrc)" = 2 ] && refus && [ -z "$(libout)" ] && [ -z "$(val OF)" ]; then
  ok "D.8 git_base_of sur un dépôt vide ⇒ refus rc 2, stdout vide, GIT_BASE_OF non posée"
else ko "D.8 rc $(rrc) : stdout='$(libout)' $(cat "$TMP/out") $(detail)"; fi

# La mémo contient des URL — donc peut-être un `user:secret@`. Elle reste une
# variable du process : l'environnement d'un ENFANT n'en porte aucune trace.
joue "$LIB" "$TMP/c-of-deux.sh" "$U_MASTER" "$U_MAIN"
if [ "$(rrc)" = 0 ] && [ "$(val MEMO_ENFANT)" = 0 ]; then
  ok "D.9 après deux découvertes mémoïsées, _GIT_BASE_MEMO est ABSENTE de l'environnement d'un enfant (jamais exportée)"
else ko "D.9 rc $(rrc) : MEMO_ENFANT=$(val MEMO_ENFANT) — la mémo (des URL) fuit vers les enfants"; fi

echo "═══ E. l'enveloppe d'authentification est HÉRITÉE entière ; la lib ne porte aucun secret ═══"
# La même enveloppe que le clone (GIT_CONFIG_COUNT/KEY/VALUE) doit ARRIVER
# jusqu'au ls-remote sans que la lib la connaisse — les TROIS variables (le shim
# les journalise ; une lib qui poserait COUNT=0 garderait KEY_0 visible et
# l'authentification morte).
SENT='U0VOVElORUxMRQ=='
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER" - GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader "GIT_CONFIG_VALUE_0=Authorization: Basic $SENT"
if [ "$(rrc)" = 0 ] && grep -q "ls-remote.*|env:count=1,key0=http.extraheader,value0=Authorization: Basic $SENT\$" "$SHIM_LOG"; then
  ok "E.1 GIT_CONFIG_COUNT=1, KEY_0 et VALUE_0 de l'appelant atteignent le ls-remote tels quels (héritage, pas de nettoyage)"
else ko "E.1 rc $(rrc) : shim=$(cat "$SHIM_LOG")"; fi
if ! fuite "$SENT"; then
  ok "E.2 le secret de l'enveloppe n'apparaît ni sur stdout ni sur stderr (chemin nominal)"
else ko "E.2 FUITE du secret de l'enveloppe"; fi

joue "$LIB" "$TMP/c-init.sh" "http://u:SENTINELLE@127.0.0.1:1/x.git"
if [ "$(rrc)" = 2 ] && refus && ! fuite SENTINELLE && grep -q '127.0.0.1:1/x.git' "$TMP/err"; then
  ok "E.3 chemin d'échec : le refus nomme l'URL EXPURGÉE de son secret (forge injoignable 127.0.0.1:1)"
else ko "E.3 rc $(rrc) : $(detail)"; fi
if ! grep -qE 'set -x|FORGE_SECRET|GITEA_TOKEN|FORGE_TOKEN|PASSWORD' "$LIB"; then
  ok "E.4 la lib ne lit AUCUNE variable de secret et ne pose jamais set -x (forme)"
else ko "E.4 la lib touche à un secret ou à set -x : $(grep -nE 'set -x|FORGE_SECRET|GITEA_TOKEN|FORGE_TOKEN|PASSWORD' "$LIB" | head -2)"; fi

# Preuve SÉMANTIQUE que l'enveloppe est LUE par git, pas seulement présente dans
# l'environnement : un `url.<main>.insteadOf=<master>` posé par GIT_CONFIG_*
# fait que la découverte de U_MASTER rend… main. Une lib qui couperait
# l'enveloppe (COUNT=0) rendrait master (M.5).
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER" - GIT_CONFIG_COUNT=1 "GIT_CONFIG_KEY_0=url.$U_MAIN.insteadOf" "GIT_CONFIG_VALUE_0=$U_MASTER"
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = main ] && grep -q "ls-remote --symref $U_MASTER HEAD|" "$SHIM_LOG"; then
  ok "E.5 l'enveloppe est LUE par git : url.<main>.insteadOf=<master> via GIT_CONFIG_* ⇒ la découverte de <master> rend main"
else ko "E.5 rc $(rrc) : $(cat "$TMP/out") shim=$(cat "$SHIM_LOG")"; fi

# Refus AVEC enveloppe posée : ni le secret de l'URL ni celui de l'enveloppe ne
# sortent — un refus qui viderait l'environnement en diagnostic (env >&2) rougit (M.6).
joue "$LIB" "$TMP/c-init.sh" "http://u:SENTINELLE@127.0.0.1:1/x.git" - GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader "GIT_CONFIG_VALUE_0=Authorization: Basic $SENT"
if [ "$(rrc)" = 2 ] && refus && ! fuite "$SENT" && ! fuite SENTINELLE; then
  ok "E.6 refus AVEC enveloppe posée : ni le secret de l'URL ni GIT_CONFIG_VALUE_0 ne sortent (stdout, stderr, produit)"
else ko "E.6 rc $(rrc) : FUITE — $(grep -l -e "$SENT" -e SENTINELLE "$TMP/out" "$TMP/err" "$TMP/lib.out" | tr '\n' ' ')"; fi

# Dépôt privé, aucune enveloppe, aucun terminal : le git réel DEMANDE une saisie
# sauf GIT_TERMINAL_PROMPT=0 — le git factice rejoue exactement cela. La lib
# doit refuser net, et la phrase le dit ; SAISIE_DEMANDEE ne doit jamais
# apparaître (M.8 : sans GIT_TERMINAL_PROMPT=0, le factice demande).
SHIM_DIR="$FAUX" joue "$LIB" "$TMP/c-init.sh" "$U_PRIVE" - GIT_SHIM_FAUX=prive
if [ "$(rrc)" = 2 ] && refus && grep -q 'terminal prompts disabled' "$TMP/err" && ! grep -q 'SAISIE_DEMANDEE' "$SHIM_LOG" && [ -z "$(val POSE)" ]; then
  ok "E.7 dépôt privé sans enveloppe ⇒ refus net « terminal prompts disabled », AUCUNE saisie demandée (GIT_TERMINAL_PROMPT=0)"
else ko "E.7 rc $(rrc) : saisie=$(grep -c SAISIE_DEMANDEE "$SHIM_LOG") $(detail)"; fi

echo "═══ F. sourçable des deux façons, syntaxe propre ═══"
joue "scripts/lib/git-base.sh" "$TMP/c-init.sh" "$U_MASTER"
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = master ]; then
  ok "F.1 « . scripts/lib/git-base.sh » depuis la racine du livrable (la forme des scripts de chaîne)"
else ko "F.1 rc $(rrc) : $(cat "$TMP/out") $(detail)"; fi
# Un appelant posé AILLEURS, dont le lib/ voisin est le nôtre : « $(dirname $0)/lib/ ».
mkdir -p "$TMP/appelant" && ln -s "$REPO/scripts/lib" "$TMP/appelant/lib"
cat > "$TMP/appelant/x.sh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/lib/git-base.sh" || exit 9
git_base_init "$1" && printf '%s' "$GIT_BASE"
SH
F2="$(cd / && env -i PATH="$SHIM:$PATH" HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        GIT_SHIM_LOG="$SHIM_LOG" GIT_SHIM_REAL="$REAL_GIT" bash "$TMP/appelant/x.sh" "$U_MASTER" 2>/dev/null </dev/null)"
if [ "$F2" = master ]; then ok "F.2 « . \$(dirname \$0)/lib/git-base.sh » depuis un autre cwd (aucune dépendance au cwd ni à une lib voisine)"
else ko "F.2 rendu='$F2'"; fi
if [ -f "$LIB" ] && bash -n "$LIB" 2>/dev/null; then ok "F.3 bash -n propre"
else ko "F.3 la lib est absente ou ne compile pas"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if [ -f "$LIB" ] && shellcheck -x "$LIB" "$0" >/dev/null 2>&1; then ok "F.4 shellcheck -x propre (lib + suite)"
  else ko "F.4 shellcheck : $(shellcheck -x "$LIB" "$0" 2>&1 | grep -c '^In ') site(s)"; fi
else echo "  (shellcheck absent — F.4 non jouée ; make lint-ci la joue)"; fi

echo "═══ G. git_base_clone_refus : POURQUOI le -b a été refusé, sans lire le texte de git ═══"
# Le diagnostic était écrit à l'identique dans trois scripts de la chaîne
# (provision-request, team-request, api-request) ; il vit ici depuis la revue du
# sous-lot 4b. Ce qu'il doit tenir : DEUX causes, DEUX rc, DEUX tags — et la
# distinction ne doit jamais venir du texte de git, qui dépend de la locale.
joue "$LIB" "$TMP/c-clone-refus.sh" "$U_MASTER" develop
if [ "$(rrc)" = 2 ] && grep -q '^REFUS: BRANCHE_DE_BASE_INTROUVABLE : ' "$TMP/err" \
   && grep -q "develop n'existe pas" "$TMP/err" && ! grep -qw main "$TMP/err"; then
  ok "G.1 dépôt JOIGNABLE sans la branche demandée ⇒ rc 2, BRANCHE_DE_BASE_INTROUVABLE nommant develop (jamais « main »)"
else ko "G.1 rc $(rrc) : $(detail)"; fi
if grep -q 'ls-remote --exit-code --heads .* refs/heads/develop|' "$SHIM_LOG"; then
  ok "G.2 la distinction vient de \`ls-remote --exit-code --heads refs/heads/<branche>\`, pas du message de git"
else ko "G.2 aucun ls-remote --exit-code --heads dans le journal du shim : $(cat "$SHIM_LOG")"; fi

joue "$LIB" "$TMP/c-clone-refus.sh" "$U_ABSENT" master
if [ "$(rrc)" = 1 ] && grep -q '^REFUS: DEPOT_INJOIGNABLE : ' "$TMP/err" \
   && ! grep -q 'BRANCHE_DE_BASE_INTROUVABLE' "$TMP/err"; then
  ok "G.3 dépôt qui NE RÉPOND PAS ⇒ rc 1, DEPOT_INJOIGNABLE — l'autre cause, l'autre tag, l'autre code"
else ko "G.3 rc $(rrc) : $(detail)"; fi

# La DÉSIGNATION : l'appelant nomme le dépôt dans SES termes (« ci/stoa-labs »),
# sinon l'URL EXPURGÉE. Un refus qui nommerait un chemin file:// de harnais chez
# un client ne lui dirait rien.
joue "$LIB" "$TMP/c-clone-refus.sh" "$U_MASTER" develop DESIGNATION=ci/stoa-labs
if [ "$(rrc)" = 2 ] && grep -q 'sur ci/stoa-labs' "$TMP/err"; then
  ok "G.4 la désignation de l'appelant est reprise telle quelle dans le refus"
else ko "G.4 rc $(rrc) : $(detail)"; fi
joue "$LIB" "$TMP/c-clone-refus.sh" "http://u:SENTINELLE@127.0.0.1:1/x.git" master
if [ "$(rrc)" = 1 ] && ! fuite SENTINELLE && grep -q '127.0.0.1:1/x.git' "$TMP/err"; then
  ok "G.5 sans désignation, le refus nomme l'URL EXPURGÉE de son userinfo (aucun secret relayé)"
else ko "G.5 rc $(rrc) : $(detail)"; fi

echo "═══ H. git_base_avec_basic : l'enveloppe composée ICI, le secret jamais en argv ═══"
# Elle était recopiée mot pour mot dans trois scripts (team-publish, team-promote,
# api-promote-export). Ce qu'elle doit tenir : les TROIS variables arrivent à git,
# l'en-tête vaut base64("<login>:<secret>"), et le secret ne passe NI par argv NI
# par la sortie. Le shim journalise l'argv ET l'enveloppe : les deux se voient.
SECRET_SONDE='sonde-tres-secrete'
B64_ATTENDU="$(printf 'x:%s' "$SECRET_SONDE" | base64 | tr -d '\n')"
joue "$LIB" "$TMP/c-avec-basic.sh" "$U_MASTER" - "SECRET_SONDE=$SECRET_SONDE"
if [ "$(rrc)" = 0 ] && grep -q "|env:count=1,key0=http.extraheader,value0=Authorization: Basic ${B64_ATTENDU}\$" "$SHIM_LOG"; then
  ok "H.1 les TROIS variables atteignent git, et VALUE_0 vaut « Authorization: Basic base64(x:<secret>) » — MESURÉ derrière le shim"
else ko "H.1 rc $(rrc) : shim=$(cat "$SHIM_LOG")"; fi
if ! grep -q "$SECRET_SONDE" <(cut -d'|' -f1 "$SHIM_LOG") && ! fuite "$SECRET_SONDE"; then
  ok "H.2 le secret n'est NI dans l'argv de git (ps -Aww le lirait) NI sur stdout/stderr — seul son NOM a voyagé"
else ko "H.2 FUITE du secret : argv=$(cut -d'|' -f1 "$SHIM_LOG" | tr '\n' ' ')"; fi
joue "$LIB" "$TMP/c-avec-basic.sh" "$U_MASTER" - "SECRET_SONDE=$SECRET_SONDE" LOGIN=oscar
B64_OSCAR="$(printf 'oscar:%s' "$SECRET_SONDE" | base64 | tr -d '\n')"
if [ "$(rrc)" = 0 ] && grep -q "value0=Authorization: Basic ${B64_OSCAR}\$" "$SHIM_LOG"; then
  ok "H.3 le LOGIN est un paramètre : Gitea accepte n'importe quel utilisateur avec un jeton, GitLab et Bitbucket NON"
else ko "H.3 rc $(rrc) : shim=$(cat "$SHIM_LOG")"; fi

# TROIS façons de composer une enveloppe À MOITIÉ : chacune est un refus nommé,
# jamais un git lancé sous une authentification morte.
joue "$LIB" "$TMP/c-basic-refus.sh" "$U_MASTER" sansnom "SECRET_SONDE=$SECRET_SONDE"
if [ "$(rrc)" = 2 ] && grep -q '^REFUS: ENVELOPPE_AUTH_INCOMPLETE : ' "$TMP/err" && [ "$(nls)" = 0 ]; then
  ok "H.4 nom de variable absent ⇒ ENVELOPPE_AUTH_INCOMPLETE rc 2, AUCUN appel git"
else ko "H.4 rc $(rrc) ls-remote=$(nls) : $(detail)"; fi
joue "$LIB" "$TMP/c-basic-refus.sh" "$U_MASTER" videvar "SECRET_SONDE=$SECRET_SONDE"
if [ "$(rrc)" = 2 ] && grep -q "la variable 'VAR_VIDE' est vide" "$TMP/err" && [ "$(nls)" = 0 ]; then
  ok "H.5 variable désignée mais VIDE ⇒ refus nommé, AUCUN appel git (une clé sans secret = authentification morte)"
else ko "H.5 rc $(rrc) ls-remote=$(nls) : $(detail)"; fi
joue "$LIB" "$TMP/c-basic-refus.sh" "$U_MASTER" sanscmd "SECRET_SONDE=$SECRET_SONDE"
if [ "$(rrc)" = 2 ] && grep -q 'exige une commande' "$TMP/err"; then
  ok "H.6 enveloppe sans commande ⇒ refus nommé (une enveloppe qui n'enveloppe rien n'est pas un succès)"
else ko "H.6 rc $(rrc) : $(detail)"; fi

echo "═══ I. git_base_xml_substituer : le placeholder des XML de jobs, fail-closed ═══"
# Les treize ci/jenkins/*.job.xml ne nomment plus de branche : ils portent
# __GIT_BASE__, et le POSEUR substitue. Trois refus nommés, un nominal.
XSRC="$TMP/x.job.xml"; XDST="$TMP/x.rendu.xml"
printf '<flow-definition>\n  <name>*/__GIT_BASE__</name>\n  <d>base __GIT_BASE__</d>\n</flow-definition>\n' > "$XSRC"
xsub(){ # xsub <GIT_BASE|-> <src> <dst> → rc et stderr dans $TMP/xerr
  ( set +u
    . "$REPO/scripts/lib/git-base.sh"
    [ "$1" = - ] || GIT_BASE="$1"
    git_base_xml_substituer "$2" "$3" ) 2>"$TMP/xerr"
}
xsub master "$XSRC" "$XDST"; RCX=$?
if [ "$RCX" -eq 0 ] && grep -qF '<name>*/master</name>' "$XDST" && grep -qF 'base master' "$XDST" \
   && ! grep -qF '__GIT_BASE__' "$XDST"; then
  ok "I.1 substitution nominale : TOUTES les occurrences remplacées, plus aucun placeholder"
else ko "I.1 rc $RCX : $(tr '\n' ' ' < "$XDST" 2>/dev/null | cut -c1-90)"; fi
rm -f "$XDST"; xsub - "$XSRC" "$XDST"; RCX=$?
if [ "$RCX" -eq 2 ] && grep -q 'XML_SUBSTITUTION_IMPOSSIBLE' "$TMP/xerr" && [ ! -s "$XDST" ]; then
  ok "I.2 GIT_BASE non posée ⇒ refus XML_SUBSTITUTION_IMPOSSIBLE, aucun XML rendu (git_base_init d'abord)"
else ko "I.2 rc $RCX : $(head -1 "$TMP/xerr")"; fi
rm -f "$XDST"; xsub master "$TMP/absent.job.xml" "$XDST"; RCX=$?
if [ "$RCX" -eq 2 ] && grep -q 'XML_SUBSTITUTION_IMPOSSIBLE' "$TMP/xerr"; then
  ok "I.3 source illisible ⇒ refus nommé, jamais un XML vide posté"
else ko "I.3 rc $RCX : $(head -1 "$TMP/xerr")"; fi
# Le placeholder SURVIT quand la valeur substituée le contient elle-même : c'est
# la seule façon de le faire réapparaître, et la garde doit quand même tenir —
# un XML posté avec « __GIT_BASE__ » ferait chercher à Jenkins une branche de ce
# nom, diagnostic que personne ne relie au fichier qui l'a causé.
rm -f "$XDST"; xsub 'a__GIT_BASE__b' "$XSRC" "$XDST"; RCX=$?
if [ "$RCX" -eq 2 ] && grep -q 'XML_PLACEHOLDER_RESTANT' "$TMP/xerr"; then
  ok "I.4 un placeholder qui SURVIT à la substitution ⇒ refus XML_PLACEHOLDER_RESTANT (fail-closed)"
else ko "I.4 rc $RCX : $(head -1 "$TMP/xerr")"; fi
# Une valeur portant `&` ou `#` — légale pour git — ne doit pas se faire manger
# par sed (`&` = « le motif trouvé »).
rm -f "$XDST"; xsub 'rel&2.0' "$XSRC" "$XDST"; RCX=$?
if [ "$RCX" -eq 0 ] && grep -qF '<name>*/rel&2.0</name>' "$XDST"; then
  ok "I.5 une branche portant « & » est substituée telle quelle (échappement du remplacement sed)"
else ko "I.5 rc $RCX : $(grep -o '<name>[^<]*</name>' "$XDST" 2>/dev/null | head -1)"; fi

echo "═══ M. mutations sur COPIE : chaque assertion attrape ce qu'elle prétend attraper ═══"
# mute <fichier> <sed-expr> — écrit le mutant ; rc 1 si no-op (le motif n'est
# plus dans la lib : l'épreuve ne prouverait rien) ou incompilable.
mute(){ sed -e "$2" "$LIB" > "$1"; [ -f "$LIB" ] && ! cmp -s "$LIB" "$1" && bash -n "$1" 2>/dev/null; }
# M.1 — la découverte remplacée par « main » : le défaut historique, à l'envers.
MUT1="$TMP/mut1.sh"
# shellcheck disable=SC2016  # quotes SIMPLES à dessein : `"$url"` est le TEXTE cherché, jamais une expansion
if ! mute "$MUT1" 's#git ls-remote --symref "$url" HEAD#printf "ref: refs/heads/main\\tHEAD\\n"#'; then
  ko "M.1 mutant no-op ou incompilable — l'épreuve ne prouve rien (la découverte a-t-elle changé de forme ?)"
else
  joue "$MUT1" "$TMP/c-init.sh" "$U_MASTER"
  if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = main ]; then
    ok "M.1 découverte remplacée par « main » ⇒ A.1 rougit (le mutant rend main sur HEAD→master)"
  else ko "M.1 le mutant passe encore : $(cat "$TMP/out")"; fi
fi
# M.2 — le knob ignoré : ce que faisaient les dix scripts.
MUT2="$TMP/mut2.sh"
# shellcheck disable=SC2016  # idem : `${GIT_BASE:-}` est le motif, pas une expansion
if ! mute "$MUT2" 's#if \[ -n "${GIT_BASE:-}" \] && \[ "$GIT_BASE" != auto \]; then#if false; then#'; then
  ko "M.2 mutant no-op ou incompilable — l'épreuve ne prouve rien (le test du knob a-t-il changé de forme ?)"
else
  joue "$MUT2" "$TMP/c-init.sh" "$U_MASTER" - GIT_BASE=develop
  if [ "$(val GIT_BASE)" = master ] && [ "$(nls)" = 1 ]; then
    ok "M.2 knob ignoré ⇒ B.1/B.2 rougissent (develop perdu, un ls-remote émis)"
  else ko "M.2 le mutant passe encore : $(cat "$TMP/out") ls-remote=$(nls)"; fi
fi
# M.3 — le dépôt vide comblé par « main » : le défaut muet que C.1 interdit.
MUT3="$TMP/mut3.sh"
# shellcheck disable=SC2016  # idem : `"$branche"` est le motif, pas une expansion
if ! mute "$MUT3" 's#\[ -n "$branche" \] || {#[ -n "$branche" ] || branche=main; false \&\& {#'; then
  ko "M.3 mutant no-op ou incompilable — l'épreuve ne prouve rien (le refus du vide a-t-il changé de forme ?)"
else
  joue "$MUT3" "$TMP/c-init.sh" "$U_VIDE"
  if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = main ]; then
    ok "M.3 dépôt vide comblé par « main » ⇒ C.1 rougit (le mutant devine main)"
  else ko "M.3 le mutant passe encore : rc $(rrc) $(cat "$TMP/out")"; fi
fi
# M.4 — une mémo SANS clé : la première branche connue est rendue pour toute URL.
# Sous D.4 en `$(…)` (l'ancienne forme), ce mutant restait vert : chaque appel
# partait d'une mémo vide dans son sous-shell.
MUT4="$TMP/mut4.sh"
# shellcheck disable=SC2016  # idem : `"$u" = "$1"` est le motif
if ! mute "$MUT4" 's#\[ "$u" = "$1" \] && {#true \&\& {#'; then
  ko "M.4 mutant no-op ou incompilable — l'épreuve ne prouve rien (la lecture de la mémo a-t-elle changé de forme ?)"
else
  joue "$MUT4" "$TMP/c-of-deux.sh" "$U_MASTER" "$U_MAIN"
  if [ "$(libout)" = "master master master master" ] && [ "$(nls)" = 1 ]; then
    ok "M.4 mémo sans clé ⇒ D.4 rougit (master rendu pour main, UN seul ls-remote)"
  else ko "M.4 le mutant passe encore : stdout='$(libout)' ls-remote=$(nls)"; fi
fi
# M.5 — la lib coupe l'enveloppe (GIT_CONFIG_COUNT=0) : KEY_0 reste visible,
# l'authentification est morte. Un shim qui ne journalise que KEY_0 restait vert.
MUT5="$TMP/mut5.sh"
if ! mute "$MUT5" 's#GIT_TERMINAL_PROMPT=0 git ls-remote#GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=0 git ls-remote#'; then
  ko "M.5 mutant no-op ou incompilable — l'épreuve ne prouve rien (l'appel ls-remote a-t-il changé de forme ?)"
else
  joue "$MUT5" "$TMP/c-init.sh" "$U_MASTER" - GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader "GIT_CONFIG_VALUE_0=Authorization: Basic $SENT"
  M5A=$(grep -q 'ls-remote.*|env:count=0,key0=http.extraheader,' "$SHIM_LOG" && echo oui)
  joue "$MUT5" "$TMP/c-init.sh" "$U_MASTER" - GIT_CONFIG_COUNT=1 "GIT_CONFIG_KEY_0=url.$U_MAIN.insteadOf" "GIT_CONFIG_VALUE_0=$U_MASTER"
  if [ "$M5A" = oui ] && [ "$(val GIT_BASE)" = master ]; then
    ok "M.5 enveloppe coupée (COUNT=0) ⇒ E.1 rougit (count=0 journalisé) ET E.5 rougit (insteadOf ignoré : master, pas main)"
  else ko "M.5 le mutant passe encore : count0=${M5A:-non} GIT_BASE=$(val GIT_BASE)"; fi
fi
# M.6 — un refus qui vide l'environnement en diagnostic : E.3 (sans enveloppe)
# restait vert ; E.6 porte l'enveloppe et rougit.
MUT6="$TMP/mut6.sh"
# shellcheck disable=SC2016  # idem : `$1` est le motif
if ! mute "$MUT6" 's#_git_base_refus() { echo "REFUS: BRANCHE_PAR_DEFAUT_INCONNUE : $1" >&2; }#_git_base_refus() { echo "REFUS: BRANCHE_PAR_DEFAUT_INCONNUE : $1" >\&2; env >\&2; }#'; then
  ko "M.6 mutant no-op ou incompilable — l'épreuve ne prouve rien (le refus a-t-il changé de forme ?)"
else
  joue "$MUT6" "$TMP/c-init.sh" "http://u:SENTINELLE@127.0.0.1:1/x.git" - GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader "GIT_CONFIG_VALUE_0=Authorization: Basic $SENT"
  if [ "$(rrc)" = 2 ] && fuite "$SENT"; then
    ok "M.6 refus qui fait env >&2 ⇒ E.6 rougit (GIT_CONFIG_VALUE_0 sort sur stderr)"
  else ko "M.6 le mutant passe encore : rc $(rrc), aucune fuite vue"; fi
fi
# M.7 — la mémo exportée : les URL (donc leurs secrets) passent aux enfants.
MUT7="$TMP/mut7.sh"
if ! mute "$MUT7" 's#_git_base_memo_ecrire() { _GIT_BASE_MEMO=#_git_base_memo_ecrire() { export _GIT_BASE_MEMO; _GIT_BASE_MEMO=#'; then
  ko "M.7 mutant no-op ou incompilable — l'épreuve ne prouve rien (l'écriture de la mémo a-t-elle changé de forme ?)"
else
  joue "$MUT7" "$TMP/c-of-deux.sh" "$U_MASTER" "$U_MAIN"
  if [ "$(val MEMO_ENFANT)" = 1 ]; then
    ok "M.7 mémo exportée ⇒ D.9 rougit (_GIT_BASE_MEMO vue dans l'environnement de l'enfant)"
  else ko "M.7 le mutant passe encore : MEMO_ENFANT=$(val MEMO_ENFANT)"; fi
fi
# M.8 — GIT_TERMINAL_PROMPT=0 retiré : devant un dépôt privé, git demande une saisie.
MUT8="$TMP/mut8.sh"
if ! mute "$MUT8" 's#GIT_TERMINAL_PROMPT=0 git ls-remote#git ls-remote#'; then
  ko "M.8 mutant no-op ou incompilable — l'épreuve ne prouve rien (l'appel ls-remote a-t-il changé de forme ?)"
else
  SHIM_DIR="$FAUX" joue "$MUT8" "$TMP/c-init.sh" "$U_PRIVE" - GIT_SHIM_FAUX=prive
  if grep -q 'SAISIE_DEMANDEE' "$SHIM_LOG" && ! grep -q 'terminal prompts disabled' "$TMP/err"; then
    ok "M.8 sans GIT_TERMINAL_PROMPT=0 ⇒ E.7 rougit (le git factice a DEMANDÉ une saisie)"
  else ko "M.8 le mutant passe encore : saisie=$(grep -c SAISIE_DEMANDEE "$SHIM_LOG") $(detail)"; fi
fi
# M.9 — la forme des noms neutralisée : `-x` accepté partout (HEAD annoncée ET knob).
MUT9="$TMP/mut9.sh"
if ! mute "$MUT9" 's#^_git_base_forme_invalide() {#_git_base_forme_invalide() { return 1;#'; then
  ko "M.9 mutant no-op ou incompilable — l'épreuve ne prouve rien (la garde de forme a-t-elle changé de nom ?)"
else
  SHIM_DIR="$FAUX" joue "$MUT9" "$TMP/c-init.sh" "$U_PRIVE" - GIT_SHIM_FAUX=head=-x
  M9C=$([ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = -x ] && echo oui)
  joue "$MUT9" "$TMP/c-init.sh" "$U_MASTER" - GIT_BASE=-x
  if [ "$M9C" = oui ] && [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = -x ]; then
    ok "M.9 forme neutralisée ⇒ C.8 rougit (HEAD '-x' retenue) ET B.9 rougit (knob '-x' retenu)"
  else ko "M.9 le mutant passe encore : head=${M9C:-non} knob rc $(rrc) GIT_BASE=$(val GIT_BASE)"; fi
fi
# M.10 — la forme contournée pour le KNOB seul : B.9 rougit, C.8 reste verte —
# la preuve que B.9 éprouve bien la voie du knob et pas la découverte.
MUT10="$TMP/mut10.sh"
# shellcheck disable=SC2016  # idem : `"$GIT_BASE"` est le motif
if ! mute "$MUT10" 's#if _git_base_forme_invalide "$GIT_BASE"; then#if false; then#'; then
  ko "M.10 mutant no-op ou incompilable — l'épreuve ne prouve rien (la garde du knob a-t-elle changé de forme ?)"
else
  joue "$MUT10" "$TMP/c-init.sh" "$U_MASTER" - GIT_BASE=-x
  M10B=$([ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = -x ] && echo oui)
  SHIM_DIR="$FAUX" joue "$MUT10" "$TMP/c-init.sh" "$U_PRIVE" - GIT_SHIM_FAUX=head=-x
  if [ "$M10B" = oui ] && [ "$(rrc)" = 2 ] && refus; then
    ok "M.10 forme du knob contournée ⇒ B.9 rougit (knob '-x' retenu) et C.8 reste verte (la HEAD '-x' est toujours refusée)"
  else ko "M.10 le mutant passe encore : knob=${M10B:-non} head rc $(rrc)"; fi
fi
# M.11 — un git_base_init bavard : il imprime la branche sur stdout, là où les
# scripts lisent leur produit.
MUT11="$TMP/mut11.sh"
# shellcheck disable=SC2016  # idem : `"$GIT_BASE"` est du texte pour sed
if ! mute "$MUT11" 's#^  _GIT_BASE_INIT_FAIT=1$#  printf "%s\\n" "$GIT_BASE"; _GIT_BASE_INIT_FAIT=1#'; then
  ko "M.11 mutant no-op ou incompilable — l'épreuve ne prouve rien (la marque d'idempotence a-t-elle changé de forme ?)"
else
  joue "$MUT11" "$TMP/c-init.sh" "$U_MASTER"
  if [ "$(rrc)" = 0 ] && [ "$(libout)" = master ]; then
    ok "M.11 init bavard ⇒ A.1 rougit (master écrit sur stdout)"
  else ko "M.11 le mutant passe encore : stdout='$(libout)'"; fi
fi
# M.12 — le refus laisse GIT_BASE=auto hérité en place (et exporté).
MUT12="$TMP/mut12.sh"
if ! mute "$MUT12" 's#unset GIT_BASE; return 2#return 2#g'; then
  ko "M.12 mutant no-op ou incompilable — l'épreuve ne prouve rien (la voie de refus a-t-elle changé de forme ?)"
else
  joue "$MUT12" "$TMP/c-init.sh" "$U_VIDE" - GIT_BASE=auto
  if [ "$(rrc)" = 2 ] && [ "$(val ENFANT)" = auto ]; then
    ok "M.12 refus sans unset ⇒ C.10 rougit (auto reste exporté vers l'enfant)"
  else ko "M.12 le mutant passe encore : rc $(rrc) ENFANT=$(val ENFANT)"; fi
fi

# M.13 — le diagnostic confond « branche absente » et « dépôt injoignable » :
# le client lirait « dépôt injoignable » sur un dépôt qui a parfaitement répondu.
MUT13="$TMP/mut13.sh"
# shellcheck disable=SC2016  # quotes SIMPLES à dessein : `"$rc"` est le TEXTE cherché dans la lib, jamais une expansion
if ! mute "$MUT13" 's#if \[ "$rc" = 2 \]; then#if false; then#'; then
  ko "M.13 mutant no-op ou incompilable — l'épreuve ne prouve rien (le diagnostic a-t-il changé de forme ?)"
else
  joue "$MUT13" "$TMP/c-clone-refus.sh" "$U_MASTER" develop
  if [ "$(rrc)" = 1 ] && grep -q 'DEPOT_INJOIGNABLE' "$TMP/err"; then
    ok "M.13 rc 2 traité comme « injoignable » ⇒ G.1 rougit (une branche absente s'annonce comme une panne de forge)"
  else ko "M.13 le mutant passe encore : rc $(rrc) $(detail)"; fi
fi
# M.14 — l'enveloppe part à MOITIÉ (COUNT=0) : la clé reste visible, git
# n'applique rien, et l'authentification est morte sans que rien ne le dise.
MUT14="$TMP/mut14.sh"
if ! mute "$MUT14" 's#GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \\#GIT_CONFIG_COUNT=0 GIT_CONFIG_KEY_0=http.extraheader \\#'; then
  ko "M.14 mutant no-op ou incompilable — l'épreuve ne prouve rien (l'enveloppe a-t-elle changé de forme ?)"
else
  joue "$MUT14" "$TMP/c-avec-basic.sh" "$U_MASTER" - "SECRET_SONDE=$SECRET_SONDE"
  if grep -q '|env:count=0,' "$SHIM_LOG"; then
    ok "M.14 COUNT=0 ⇒ H.1 rougit (git voit la clé mais n'applique aucune config : authentification morte)"
  else ko "M.14 le mutant passe encore : shim=$(cat "$SHIM_LOG")"; fi
fi

echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
