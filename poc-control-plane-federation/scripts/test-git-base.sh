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
#      git_base_init est MUET sur stdout (les scripts y lisent leur produit) et
#      DIT sur stderr, en une ligne, la branche découverte et l'URL EXPURGÉE qui
#      l'a annoncée — l'auditabilité d'une pose (M.17)
#   B. un knob explicite GAGNE et coûte ZÉRO appel réseau — prouvé par un shim
#      `git` en tête du PATH qui journalise chaque argv ; un knob sans la forme
#      d'un nom de branche (`-x`) est un REFUS, jamais un `clone -b -x` en aval
#   C. un dépôt VIDE (ls-remote ne rend rien, rc 0), injoignable, ou qui annonce
#      un nom sans la forme d'une branche ⇒ REFUS nommé, GIT_BASE NON posée ni
#      exportée (même si `auto` était hérité) — jamais « main » deviné en silence
#   D. git_base_of : une branche PAR DÉPÔT, mémoïsée par URL dans le process —
#      QUATRE appels sur DEUX URL dans le MÊME shell rendent master/main/master/
#      main avec DEUX ls-remote (une mémo qui ignore l'URL rougit : M.4) ; la
#      mémo n'est jamais exportée (une URL peut porter un secret) ; chaque
#      découverte s'annonce sur stderr, UNE fois par URL (mémo comprise, M.18)
#   E. l'enveloppe d'authentification du clone est HÉRITÉE (GIT_CONFIG_COUNT/KEY/
#      VALUE atteignent git : journalisés par le shim ET prouvés par un
#      `url.<x>.insteadOf` qui change ce que ls-remote rend), la lib ne porte
#      aucun secret et n'en imprime aucun — chemin nominal ET refus AVEC
#      enveloppe posée ; GIT_TERMINAL_PROMPT=0 fait refuser un dépôt privé au
#      lieu d'attendre une saisie (git factice qui la simule)
#   F. sourçable des deux façons (`. scripts/lib/…` et `$(dirname $0)/lib/…`)
#   M. mutations sur COPIE — chacune fait rougir l'assertion qu'elle vise, et
#      celle-là seulement quand c'est ce qui est prouvé
#   J. STOA_DEBUG=1 (plan 2026-09-09, L2) : la lib DIT ce qu'elle a décidé —
#      le ls-remote et son rc, GIT_BASE, GIT_BASE_ORIGINE, GIT_BASE_OF — sur
#      STDERR seulement, par dbg/dbg_kv de ci/lib/dbg.sh ; stdout INCHANGÉ
#      octet pour octet ; le knob ne coûte toujours aucun appel git ; le secret
#      d'une URL ne sort ni dans la ligne de debug ni dans le REFUS — même sous
#      GIT_TRACE=1 hérité, où git recopie l'URL NUE sur son stderr : ce stderr
#      est masqué EN ENTIER avant d'être tronqué à 300 octets, aux deux sites
#      (découverte J.4c-d, clone J.4e) ; chaque absence est DOUBLÉE d'une
#      présence (une lib muette ne passe pas) ; trois mutations sur copie
#      prouvent que J.1, J.4 et J.4c/J.4e mordent (jouées après M : elles
#      reprennent son `mute`)
#
# TERRAIN : HORS LIGNE intégralement — dépôts nus en file://, forge injoignable
# (127.0.0.1:1), git FACTICE pour ce qu'une fixture ne peut pas produire (une
# HEAD nommée `-x`, un dépôt privé qui demande une saisie). Chaque cas joue la
# lib dans un PROCESSUS NEUF (`env -i`, stdin fermé, ~/.gitconfig et config
# système IGNORÉS) : rien n'y entre que ce que le cas pose, et le shim git est
# le seul git visible. Les fixtures sont SOURDES à la config de l'hôte
# (commit.gpgsign, identité) et la suite S'ARRÊTE (rc 2) si l'une d'elles rate :
# elle ne joue jamais sur un dépôt vide en imputant les rouges à la lib.
# python3 doit être sur le PATH de l'hôte : sans lui, la rédaction de dbg.sh
# est fail-closed (« <rédaction indisponible> ») et la section J rougit — c'est
# le contrat, pas un défaut de la suite.
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
# LC_ALL=C sur tout ce qui LIT stderr : le détail d'un refus est coupé à 300
# OCTETS et la coupe peut trancher un `é` en deux (celui de « <masqué> », ou de
# git en locale française) ; sous une locale UTF-8, le sed BSD ABANDONNE alors
# la ligne (« RE error: illegal byte sequence ») et le grep BSD ne la voit plus
# — mesuré 2026-09-10 : `grep -q '^REFUS: TAG : '` rend 1 sur une ligne qui
# porte un octet invalide. Une sentinelle est de l'ASCII : sous C, chaque octet
# est un caractère et aucune ligne n'est aveugle.
refus(){ LC_ALL=C grep -q "^REFUS: BRANCHE_PAR_DEFAUT_INCONNUE : " "$TMP/err"; }
muet(){ [ -z "$(libout)" ]; }               # git_base_init n'a RIEN écrit sur stdout
fuite(){ LC_ALL=C grep -q "$1" "$TMP/out" "$TMP/err" "$TMP/lib.out"; }   # <sentinelle> vue quelque part ?

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
# Le même helper, mais le stderr du clone est un FICHIER COMPOSÉ par le cas
# (ERRF) : le 3e argument est un chemin par contrat, et une coupe qui doit
# tomber à un octet précis se compose — elle ne se tire pas d'un vrai clone.
cat > "$TMP/c-clone-refus-fichier.sh" <<'SH'
git_base_clone_refus "$1" "$2" "$ERRF" ""; rc=$?
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

# L'AUDITABILITÉ D'UNE POSE (L3, 2026-09-10). La voie du KNOB dit ce qu'elle
# retient (B.3) ; la DÉCOUVERTE, elle, était MUETTE. Après une pose des treize
# jobs Jenkins, rien dans le journal du poseur ne disait quelle URL avait été
# interrogée ni quelle HEAD elle avait annoncée : un « main » DÉCOUVERT était
# indistinguable d'un « main » écrit en dur, et « pas de ligne knob » était la
# seule preuve — elle-même fausse dès que GIT_BASE_ORIGINE est HÉRITÉ. Une
# ligne, sur stderr, SYMÉTRIQUE de celle du knob ; stdout reste le produit.
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER"
if [ "$(grep -c '^git-base: ' "$TMP/err")" = 1 ] && grep -q '^git-base: GIT_BASE=master découvert' "$TMP/err" \
   && grep -q 'ls-remote --symref' "$TMP/err" && grep -qF "$TMP/master.git" "$TMP/err" \
   && ! grep -q 'knob' "$TMP/err" && muet; then
  ok "A.7 la DÉCOUVERTE s'annonce : UNE ligne sur stderr nommant la branche trouvée ET l'URL qui l'a annoncée, stdout toujours vide"
else ko "A.7 $(grep -c '^git-base: ' "$TMP/err") ligne(s) : $(grep '^git-base: ' "$TMP/err" | head -1) stdout='$(libout)'"; fi

# La même ligne sur une URL qui porte un `user:secret@` : elle nomme le dépôt
# EXPURGÉ, comme les refus (§E). Une ligne d'information qui fuiterait un jeton
# serait pire que le silence qu'elle remplace — le git factice sert la HEAD, le
# dépôt n'est jamais joint.
SHIM_DIR="$FAUX" joue "$LIB" "$TMP/c-init.sh" "http://u:SENTINELLE@forge.local/x.git" - GIT_SHIM_FAUX=head=master
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = master ] && grep -q '^git-base: GIT_BASE=master découvert' "$TMP/err" \
   && grep -q '<masqué>@forge.local' "$TMP/err" && ! fuite SENTINELLE && muet; then
  ok "A.8 la ligne de découverte porte l'URL EXPURGÉE (« <masqué>@ ») — un user:secret@ n'y entre jamais"
else ko "A.8 rc $(rrc) : $(grep '^git-base: ' "$TMP/err" | head -1)"; fi

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

# La ligne de découverte suit la MÉMO : UNE interrogation, UNE ligne. Deux
# appels sur la même URL n'en font pas deux — un journal de pose qui annoncerait
# deux découvertes là où il n'y a eu qu'un ls-remote (D.3) mentirait sur ce qui
# a été demandé au dépôt.
joue "$LIB" "$TMP/c-of-memo.sh" "$U_MASTER"
if [ "$(rrc)" = 0 ] && [ "$(grep -c '^git-base: ' "$TMP/err")" = 1 ] \
   && grep -q 'a pour HEAD master (découverte)' "$TMP/err" && grep -qF "$TMP/master.git" "$TMP/err"; then
  ok "D.10 git_base_of annonce la découverte UNE fois pour deux appels sur la même URL (la mémo vaut aussi pour la ligne)"
else ko "D.10 $(grep -c '^git-base: ' "$TMP/err") ligne(s) : $(grep '^git-base: ' "$TMP/err" | tr '\n' ' ')"; fi

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
# La lib source ci/lib/dbg.sh (L2) : à côté d'elle (../../ci/lib) ou sous $PWD.
# Une COPIE isolée (aucun ci/ à côté), sourcée depuis un cwd sans ci/lib, doit
# le DIRE — ERREUR nommée citant les deux chemins cherchés — et ne PAS se
# sourcer (le `|| exit 9` de l'appelant est atteint) : jamais une lib qui se
# tait faute de debug, ni un appelant qui continue sur des fonctions absentes.
mkdir -p "$TMP/isole/lib" && cp "$LIB" "$TMP/isole/lib/git-base.sh"
# shellcheck disable=SC2016  # « $1 » est pour le bash ENFANT (le chemin de la copie), jamais pour celui-ci
F5="$(cd / && env -i PATH="$SHIM:$PATH" HOME="$TMP/home" bash -c '. "$1" || exit 9' _ "$TMP/isole/lib/git-base.sh" 2>&1 >/dev/null </dev/null; echo "rc=$?")"
if grep -q '^ERREUR: ci/lib/dbg.sh introuvable (cherché : ' <<<"$F5" && grep -qF "$TMP/isole/lib/../../ci/lib/dbg.sh" <<<"$F5" && grep -q '^rc=9$' <<<"$F5"; then
  ok "F.5 sans ci/lib/dbg.sh joignable ⇒ « ERREUR: ci/lib/dbg.sh introuvable (cherché : …) » nomme les deux chemins, la lib ne se source pas (rc 9 de l'appelant)"
else ko "F.5 $(tr '\n' ' ' <<<"$F5" | cut -c1-200)"; fi

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

echo "═══ H bis. LE LOGIN DE L'ENVELOPPE, en UN exemplaire — et la COMPLÉTUDE des appelants ═══"
# POURQUOI CETTE SECTION EXISTE. Le 2026-09-11, une preuve live sur un GitLab
# PRIVÉ a trouvé que scripts/provision-plan.sh clonait le dépôt plateforme SANS
# enveloppe et ignorait GIT_CLONE_URL — seul de la chaîne. La lecture ANONYME du
# Gitea du lab masquait le trou (`info/refs` ⇒ 200 sur Gitea, 401 sur un projet
# GitLab privé) : le plan mourait CLONE_ECHEC chez un client, jamais ici. Ce
# n'est pas un oubli isolé : c'est une RÈGLE qui n'était écrite nulle part.
# Elle l'est maintenant, à deux niveaux :
#   1. le LOGIN de l'enveloppe se décide en UN endroit (git_base_basic_login) —
#      « x » convient à Gitea, JAMAIS à GitLab ni Bitbucket (entête de la lib) ;
#   2. la liste des scripts qui parlent à une forge DISTANTE est mesurée en
#      COMPLÉTUDE : chacun porte une enveloppe (git_base_avec_basic) ou
#      GIT_ASKPASS (forge-identity.sh). Un script qui clonerait en anonyme
#      rougit ICI, au lieu d'attendre un client sur forge privée.
for cas in "gitea::x" "gitea:bob:bob" ":oauth2:oauth2" "gitlab::oauth2" "gitlab:alice:alice" "bitbucket::oauth2"; do
  kind="${cas%%:*}"; rest="${cas#*:}"; user="${rest%%:*}"; want="${rest##*:}"
  got=$( FORGE_KIND="$kind" FORGE_USER="$user" bash -c ". $LIB && git_base_basic_login" 2>&1 )
  if [ "$got" = "$want" ]; then ok "H bis.1 FORGE_KIND='$kind' FORGE_USER='$user' ⇒ login '$got'"
  else ko "H bis.1 FORGE_KIND='$kind' FORGE_USER='$user' ⇒ login '$got', attendu '$want'"; fi
done
# LA COMPLÉTUDE, sur ce qui compte : un script qui CLONE ou POUSSE une forge
# distante doit porter un mécanisme d'authentification. La liste est DÉRIVÉE du
# dépôt, jamais écrite à la main — un script ajouté demain entre dans la mesure
# tout seul. Les mécanismes acceptés sont les QUATRE formes en usage :
#   git_base_avec_basic (la lib)            · http.extraheader posé en ligne
#   GIT_ASKPASS / forge_askpass (A7)        · _gc_auth_b64 (generate-choices)
# EXEMPTÉS, un par un et avec leur raison :
#   test-*/spike-*            harnais : ils posent leurs propres valeurs ;
#   setup-*                   poseurs lancés DEPUIS LE POSTE : ils ne clonent
#                             JAMAIS (mesuré : 0 `git clone`), ils DÉCOUVRENT, et
#                             sur une forge privée leur refus nomme GIT_BASE —
#                             c'est une consigne actionnable, pas une panne muette ;
#   seed-governance-chain.sh  amorce de lab sur un dépôt de démonstration.
MECANISMES='git_base_avec_basic|extraheader|GIT_ASKPASS|forge_askpass|_gc_auth_b64|git_base_basic_login'
# LE PÉRIMÈTRE EST DÉRIVÉ DES JENKINSFILE, pas d'une liste : un script EXÉCUTÉ
# par un pipeline (`bash scripts/x.sh`) tourne sur un agent, sans terminal et
# sans utilisateur — son geste git DOIT donc porter son authentification. Une
# simple MENTION en commentaire ou dans un message de refus ne compte pas
# (mesuré : setup-jenkins-globals.sh et setup-provision-request-job.sh ne sont
# cités que là). On ajoute les scripts de chaîne appelés par d'autres scripts de
# chaîne (provision-request appelle provision-plan), en suivant la même règle.
EXECUTES=$(grep -ohE '(bash|sh) scripts/[a-z0-9-]+\.sh' "$REPO"/ci/Jenkinsfile.* "$REPO"/scripts/*.sh 2>/dev/null |
           grep -oE 'scripts/[a-z0-9-]+\.sh' | sort -u)
MANQUANTS=""
for rel in $EXECUTES; do
  b="$(basename "$rel")"; f="$REPO/scripts/$b"
  [ -f "$f" ] || continue
  # EXEMPTÉS, nommément et avec leur raison — jamais une classe balayée :
  #   test-*/spike-*  harnais : ils posent leurs propres valeurs ;
  #   setup-*         POSEURS lancés depuis le POSTE par un exploitant (ils
  #                   entrent ici parce qu'ils s'appellent entre eux) : ils ne
  #                   clonent JAMAIS, ils DÉCOUVRENT, et sur une forge privée
  #                   leur refus NOMME GIT_BASE et GIT_HOST/GIT_REPO — une
  #                   consigne actionnable par la personne qui les lance, pas
  #                   une panne muette dans un build sans terminal.
  case "$b" in test-*|spike-*|setup-*) continue ;; esac
  # parle-t-il à une forge DISTANTE ? cloner, pousser, ou DÉCOUVRIR une HEAD
  grep -qE 'git (clone|push|fetch)|git_base_init|git_base_of|ls-remote' "$f" || continue
  # PAR GESTE, pas par fichier (leçon du 2026-09-11) : la seule PRÉSENCE d'un
  # mécanisme dans le script ne dit rien des autres gestes. provision-apply-
  # reconcile.sh avait sa découverte enveloppée et son `git fetch` NU — le
  # défaut a reculé d'un cran au lieu de se fermer. Un script qui exporte
  # GIT_ASKPASS, lui, couvre TOUS ses gestes d'un coup : il est accepté en bloc.
  grep -qE 'export .*GIT_ASKPASS|GIT_ASKPASS=' "$f" && continue
  # Les CONTINUATIONS de ligne sont jointes d'abord : une enveloppe posée en
  # préfixe et son `git` sur la ligne suivante forment UN seul geste (faux
  # positif mesuré le 2026-09-11 sur provision-apply-reconcile.sh:396).
  NUS=$(python3 - "$f" <<'PY'
import re, sys
brut = open(sys.argv[1], encoding='utf-8').read().split('\n')
logiques, cur, depart = [], '', 1
for n, ln in enumerate(brut, 1):
    if not cur:
        depart = n
    cur += ln
    if cur.rstrip().endswith('\\'):
        cur = cur.rstrip()[:-1] + ' '
        continue
    logiques.append((depart, cur)); cur = ''
if cur:
    logiques.append((depart, cur))
# La DÉCOUVERTE compte comme un geste : git_base_init/of font un `ls-remote`, et
# un ls-remote nu meurt « could not read Username » sur un dépôt privé — le refus
# accuse alors la branche, pas l'authentification (angle mort de la première
# version de cette porte, trouvé le 2026-09-11 sur team-apply.sh:134).
GESTE = re.compile(r'(^|[;&|(]|\s)(git (-C \S+ )?(clone|push|fetch|ls-remote)|git_base_init|git_base_of)\b')
# Les QUATRE formes en usage, enveloppe en ligne comprise (`http.extraheader`
# posé en préfixe d'env — api-promote-export.sh et ses frères l'écrivent ainsi).
ENVELOPPE = re.compile(r'git_base_avec_basic|gclone|gbase|gauth|GIT_ASKPASS|extraheader|_gc_auth_b64')
DEFINITION = re.compile(r'^\s*(gclone|gbase|ggit|git_base_[a-z_]+)\s*\(\)')
nus = [str(n) for n, l in logiques
       if GESTE.search(l) and not ENVELOPPE.search(l)
       and not l.lstrip().startswith('#') and not DEFINITION.search(l)]
print(','.join(nus))
PY
)
  [ -z "$NUS" ] && continue
  MANQUANTS="$MANQUANTS ${b}:${NUS}"
done
# ── LA DETTE, DATÉE ET COMPTÉE (2026-09-11) ─────────────────────────────────
# Les gestes nus CONNUS au moment de la pose de cette porte, tous dans la chaîne
# API/producteur (la chaîne app-request, elle, est close : provision-plan,
# provision-apply-reconcile, provision-request, app-rollback-request).
# CE N'EST PAS UNE LISTE DE PARDONS : c'est la dette. On n'y AJOUTE jamais une
# ligne — un geste nu neuf fait rougir. Et une ligne qui ne correspond PLUS à un
# geste nu fait rougir aussi : réparer oblige à la retirer. C'est le cliquet.
# La dette du 2026-09-11 (8 gestes de la chaîne API/producteur) a été SOLDÉE le
# même jour : le cliquet a d'abord exigé leur réparation, puis la RETRAIT de
# leurs lignes — et en chemin il a révélé quatre DÉCOUVERTES nues de plus
# (git_base_init/of, que la première version de cette règle ne comptait pas
# comme des gestes). La liste est vide, et c'est l'état normal : on n'y ajoute
# jamais une ligne pour faire passer un geste neuf.
DETTE=""
RESTE=""; PERIMEES=""
for e in $MANQUANTS; do
  case " $DETTE " in *" $e "*) ;; *) RESTE="$RESTE $e" ;; esac
done
for d in $DETTE; do
  case " $MANQUANTS " in *" $d "*) ;; *) PERIMEES="$PERIMEES $d" ;; esac
done
MANQUANTS="$RESTE"
if [ -z "$PERIMEES" ]; then
  ok "H bis.2b la dette est EXACTE : chaque ligne déclarée correspond encore à un geste nu (une ligne réparée doit être RETIRÉE — sinon cette porte ne serait qu'une liste de pardons)"
else ko "H bis.2b dette PÉRIMÉE — ces gestes sont réparés (ou déplacés), retire-les de DETTE :$PERIMEES"; fi
if [ -z "$MANQUANTS" ]; then
  ok "H bis.2 COMPLÉTUDE : tout script qui CLONE ou POUSSE porte un mécanisme d'authentification — aucun geste anonyme, donc aucun CLONE_ECHEC réservé aux forges privées (la lecture anonyme du Gitea du lab masquait le trou : info/refs ⇒ 200 Gitea, 401 GitLab privé)"
else ko "H bis.2 geste(s) git NU(S) HORS DETTE dans un script exécuté par un pipeline — casse sur forge PRIVÉE, invisible au lab :$MANQUANTS"; fi
# ── H bis.4 : LE LOGIN NE SE COMPOSE PLUS À LA MAIN ─────────────────────────
# H bis.2 mesure si le GESTE est enveloppé ; elle ne dit RIEN d'où vient le
# login. Cinq sites composaient encore « x: » en dur avec le secret — geste
# authentifié, login mort sur GitLab (401), et donc invisibles à H bis.2
# (trouvés le 2026-09-12 par la cartographie de la chaîne producteur).
# La règle : personne ne compose un Basic à la main hors de l'autorité.
# Exemptés : la lib elle-même (elle EST l'autorité) et les harnais.
COMPOSEURS=""
for f in "$REPO"/scripts/*.sh "$REPO"/scripts/lib/*.sh; do
  b="$(basename "$f")"
  case "$b" in test-*|spike-*|git-base.sh) continue ;; esac
  # une composition à la main : « <login>:<secret> » passé à base64
  # Le défaut est PRÉCIS : une partie login LITTÉRALE (pas « %s », qui vient
  # d'une variable) composée avec un secret de FORGE. Un `printf '%s:%s'` dont
  # le login sort de l'autorité est correct ; un Basic de webMethods ou de
  # Keycloak (WM_USER, GW_USER) n'a rien à voir avec une forge — les deux
  # étaient des faux positifs de la première version de cette règle.
  L=$(grep -nE "printf '[^'%]+:%s'" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' |
      grep -E 'FORGE_SECRET|GITEA_TOKEN|\$\(cat [^)]*g?t[^)]*\)' | cut -d: -f1 | tr '\n' ',')
  [ -z "$L" ] && continue
  COMPOSEURS="$COMPOSEURS ${b}:${L%,}"
done
if [ -z "$COMPOSEURS" ]; then
  ok "H bis.4 aucun login de Basic composé à la main hors de l'autorité : « x » ne peut plus retomber en dur sur une forge qui le refuse (GitLab, Bitbucket ⇒ 401 — et le geste est pourtant AUTHENTIFIÉ, donc invisible à H bis.2)"
else ko "H bis.4 login composé À LA MAIN (le geste est enveloppé, mais « x » y retombe ⇒ 401 sur GitLab) :$COMPOSEURS"; fi

# DISCRIMINANT : la porte doit attraper le défaut réel du 2026-09-11. On rejoue
# la mesure sur une COPIE de provision-plan.sh privée de son mécanisme.
CP="$TMP/pp-sans-mecanisme.sh"
sed -E 's/git_base_avec_basic|git_base_basic_login/NEANT/g' "$REPO/scripts/provision-plan.sh" > "$CP"
if grep -qE 'git (clone|push|fetch)|git_base_init' "$CP" && ! grep -qE "$MECANISMES" "$CP"; then
  ok "H bis.3 discriminant : provision-plan.sh privé de son enveloppe est VU par la règle de H bis.2 (c'est l'état dans lequel il a été trouvé, et il rougirait)"
else ko "H bis.3 la règle de H bis.2 ne verrait PAS un provision-plan.sh anonyme — elle ne mesure rien"; fi

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
# CE QUI ENTRE DANS UN XML N'EST PAS CE QU'ACCEPTE GIT (revue 4c). `rel&2.0`
# est un nom de branche PARFAITEMENT légal (check-ref-format ne refuse que
# ~ ^ : ? * [ \ et les contrôles) et il rend `<name>*/rel&2.0</name>`, c'est-à-dire
# un XML MAL FORMÉ que Jenkins refuse par une SAXParseException. Un échappement
# discret serait pire qu'un refus : la branche ne serait pas celle qu'on croit.
# Donc REFUS nommé, avant toute écriture.
bienforme(){ python3 - "$1" <<'PYX'
import sys, xml.etree.ElementTree as T
try:
    T.parse(sys.argv[1]); sys.exit(0)
except Exception:
    sys.exit(1)
PYX
}
for CAR in 'rel&2.0' 'a<b' 'a>b' 'a"b' "a'b"; do
  rm -f "$XDST"; xsub "$CAR" "$XSRC" "$XDST"; RCX=$?
  if [ "$RCX" -eq 2 ] && grep -q 'BRANCHE_NON_INSERABLE_XML' "$TMP/xerr" && [ ! -f "$XDST" ]; then
    ok "I.5 branche '$CAR' (légale pour git, ingérable en XML) ⇒ refus BRANCHE_NON_INSERABLE_XML, RIEN écrit"
  else ko "I.5 '$CAR' : rc $RCX, fichier $( [ -f "$XDST" ] && echo ECRIT || echo absent ) — $(head -1 "$TMP/xerr")"; fi
done
# … et le nominal ne se contente pas de « contenir le bon texte » : il doit
# PARSER. Sans cette lecture, la porte ci-dessus resterait une opinion.
rm -f "$XDST"; xsub 'release/2.0' "$XSRC" "$XDST"; RCX=$?
if [ "$RCX" -eq 0 ] && bienforme "$XDST" && grep -qF '<name>*/release/2.0</name>' "$XDST"; then
  ok "I.6 un nom ordinaire ⇒ XML BIEN FORMÉ (relu par ElementTree), branche exacte"
else ko "I.6 rc $RCX : $(grep -o '<name>[^<]*</name>' "$XDST" 2>/dev/null | head -1)"; fi
# `#` et `\` restent ÉCHAPPÉS pour sed (délimiteur, séquence de remplacement) :
# légaux pour git, sans signification en XML, ils doivent passer TELS QUELS.
rm -f "$XDST"; xsub 'rel#2' "$XSRC" "$XDST"; RCX=$?
if [ "$RCX" -eq 0 ] && bienforme "$XDST" && grep -qF '<name>*/rel#2</name>' "$XDST"; then
  ok "I.7 une branche portant « # » (le délimiteur du sed) passe telle quelle"
else ko "I.7 rc $RCX : $(grep -o '<name>[^<]*</name>' "$XDST" 2>/dev/null | head -1)"; fi

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

# M.15 — LA GARDE XML RETIRÉE. C'est le défaut relevé en revue de 4c : sans
# elle, un nom de branche légal pour git mais porteur de balisage traversait la
# substitution et le XML partait vers Jenkins. Deux mutants, deux degrés :
#   M.15 la garde neutralisée seule ⇒ le refus BRANCHE_NON_INSERABLE_XML
#        DISPARAÎT, donc I.5 rougirait (c'est ce que la mutation doit montrer) ;
#   M.16 la garde neutralisée ET l'échappement `&` de sed remis, c'est-à-dire
#        la lib EXACTEMENT telle qu'elle était avant cette correction ⇒ rc 0 sur
#        un XML MAL FORMÉ. Le défaut mesuré par la revue, reproduit.
MUT15="$TMP/mut15.sh"
# shellcheck disable=SC2016  # quotes SIMPLES à dessein : `"$GIT_BASE"` est le TEXTE cherché dans la lib
if ! mute "$MUT15" 's#case "$GIT_BASE" in#case ZZ_NEUTRE in#'; then
  ko "M.15 mutant no-op ou incompilable — l'épreuve ne prouve rien (la garde a-t-elle changé de forme ?)"
  ko "M.16 (non jouée : le mutant de M.15 n'a pas pu être construit)"
else
  rm -f "$XDST"
  # shellcheck source=/dev/null  # le mutant est produit à l'exécution, par construction
  ( set +u; . "$MUT15"; GIT_BASE='rel&2.0'; git_base_xml_substituer "$XSRC" "$XDST" ) 2>"$TMP/xerr"; RCX=$?
  if grep -q 'BRANCHE_NON_INSERABLE_XML' "$TMP/xerr"; then
    ko "M.15 la garde neutralisée refuse encore — la mutation ne mord pas, I.5 est vacante"
  else
    ok "M.15 garde neutralisée ⇒ plus aucun BRANCHE_NON_INSERABLE_XML : I.5 rougirait (rc $RCX)"
  fi
  # M.16 : et on remet l'échappement `&` du remplacement sed, retiré avec la
  # garde. `&` y signifiait « le motif trouvé » ; échappé, il insérait le nom
  # tel quel — donc le balisage — dans le XML.
  MUT16="$TMP/mut16.sh"
  sed -e 's|\[#\\\\]|[\&#\\\\]|' "$MUT15" > "$MUT16"
  if cmp -s "$MUT15" "$MUT16" || ! bash -n "$MUT16" 2>/dev/null; then
    ko "M.16 mutant no-op ou incompilable — l'échappement sed a-t-il changé de forme ?"
  else
    rm -f "$XDST"
    # shellcheck source=/dev/null  # idem
    ( set +u; . "$MUT16"; GIT_BASE='rel&2.0'; git_base_xml_substituer "$XSRC" "$XDST" ) 2>"$TMP/xerr"; RCX=$?
    if [ "$RCX" -eq 0 ] && [ -f "$XDST" ] && ! bienforme "$XDST"; then
      ok "M.16 lib d'avant la correction ⇒ rc 0 sur un XML MAL FORMÉ — le défaut de la revue 4c, reproduit"
    else ko "M.16 le mutant ne reproduit pas le défaut : rc $RCX, $( [ -f "$XDST" ] && { bienforme "$XDST" && echo bien-formé || echo mal-formé; } || echo 'aucun fichier' )"; fi
  fi
fi

# M.17 — la ligne de découverte de git_base_init retirée : la pose redevient
# MUETTE, c'est-à-dire l'état d'avant ce lot — le journal du poseur ne dit plus
# ni l'URL interrogée ni la HEAD annoncée, et « GIT_BASE=main » redevient
# indistinguable d'un littéral.
MUT17="$TMP/mut17.sh"
if ! mute "$MUT17" "s#^ *printf 'git-base: GIT_BASE=%s d.*#  :#"; then
  ko "M.17 mutant no-op ou incompilable — l'épreuve ne prouve rien (la ligne de découverte a-t-elle changé de forme ?)"
else
  joue "$MUT17" "$TMP/c-init.sh" "$U_MASTER"
  if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = master ] && ! grep -q '^git-base: ' "$TMP/err"; then
    ok "M.17 découverte muette ⇒ A.7 rougit (la pose ne dit plus ni l'URL interrogée ni la HEAD annoncée)"
  else ko "M.17 le mutant passe encore : rc $(rrc), $(grep -c '^git-base: ' "$TMP/err") ligne(s)"; fi
fi
# M.18 — la même ligne retirée de git_base_of : les dépôts NON plateforme
# (gouvernance, équipes) redeviennent découverts en silence.
MUT18="$TMP/mut18.sh"
if ! mute "$MUT18" "s#^ *printf 'git-base: %s a pour HEAD %s (d.*#  :#"; then
  ko "M.18 mutant no-op ou incompilable — l'épreuve ne prouve rien (la ligne de git_base_of a-t-elle changé de forme ?)"
else
  joue "$MUT18" "$TMP/c-of-memo.sh" "$U_MASTER"
  if [ "$(rrc)" = 0 ] && [ "$(libout)" = master ] && ! grep -q '^git-base: ' "$TMP/err"; then
    ok "M.18 git_base_of muet ⇒ D.10 rougit (la branche d'un dépôt d'équipe est posée sans qu'on sache d'où elle vient)"
  else ko "M.18 le mutant passe encore : rc $(rrc), $(grep -c '^git-base: ' "$TMP/err") ligne(s)"; fi
fi

echo "═══ J. STOA_DEBUG=1 : la lib dit ce qu'elle a décidé, sur stderr, jamais un secret ═══"
# LE MODE DEBUG SANS FUITE (plan 2026-09-09, L2). Quand la chaîne casse chez un
# client, le log ne dit ni la branche retenue, ni d'où elle vient (knob ou
# HEAD), ni ce que le ls-remote a rendu — et il faut solliciter l'auteur. Sous
# STOA_DEBUG=1 la lib le dit, par dbg/dbg_kv de ci/lib/dbg.sh : STDERR
# seulement, préfixe « [dbg <script>] », APRÈS rédaction. Gabarit : D1/D2/D3 de
# test-vault-user-login.sh — chaque absence (« le secret n'y est pas ») est
# DOUBLÉE d'une présence (« la ligne attendue y est »), sinon une lib muette
# passerait tout. Les assertions de présence sont la LIGNE EXACTE, préfixe
# retiré (<script> est le prélude du harnais : on ne l'épingle pas).
corps_dbg(){ LC_ALL=C sed -n 's/^\[dbg [^]]*\] //p' "$TMP/err"; }   # les lignes de debug, préfixe retiré (C : voir refus/fuite)
ligne_dbg(){ corps_dbg | LC_ALL=C grep -qxF -- "$1"; }               # la LIGNE EXACTE attendue est là
dbgl(){ LC_ALL=C grep -c '^\[dbg ' "$TMP/err"; }                      # combien de lignes de debug émises
# init PUIS of dans le MÊME shell, TOUT le stdout de la lib dans LIB_OUT : c'est
# là qu'une ligne de debug égarée sur stdout se verrait — git_base_init n'y
# écrit rien, git_base_of y écrit la branche, et rien d'autre.
cat > "$TMP/c-dbg.sh" <<'SH'
{ git_base_init "$1" && git_base_of "$1"; } > "$LIB_OUT"; rc=$?
etat "$rc"; exit "$rc"
SH
# La taille RÉELLE de ce que ls-remote rend sur la fixture — « (n octets) » n'est
# pas un [0-9]+ vacant. `$(…)` retire le saut de ligne final, comme dans la lib.
N_MASTER=$(s=$(fgit ls-remote --symref "$U_MASTER" HEAD); printf '%s' "${#s}")

# J.1 — la découverte se dit : le ls-remote et son rc, la branche, l'origine.
joue "$LIB" "$TMP/c-dbg.sh" "$U_MASTER"
cp "$TMP/lib.out" "$TMP/lib.out.sans"; J1_SANS="$(dbgl)"
joue "$LIB" "$TMP/c-dbg.sh" "$U_MASTER" - STOA_DEBUG=1
if [ "$(rrc)" = 0 ] && ligne_dbg "git ls-remote --symref $U_MASTER HEAD -> rc 0 ($N_MASTER octets)"; then
  ok "J.1a découverte sous STOA_DEBUG=1 ⇒ « git ls-remote --symref <url> HEAD -> rc 0 ($N_MASTER octets) » sur stderr (la taille est celle mesurée sur la fixture)"
else ko "J.1a rc $(rrc) : $(corps_dbg | grep ls-remote | head -1) — attendu ($N_MASTER octets)"; fi
if ligne_dbg "GIT_BASE=master" && ligne_dbg "GIT_BASE_ORIGINE=decouverte"; then
  ok "J.1b « GIT_BASE=master » puis « GIT_BASE_ORIGINE=decouverte » : la décision ET son origine, en clair"
else ko "J.1b lignes vues : $(corps_dbg | grep GIT_BASE | tr '\n' ' ')"; fi
if ligne_dbg "GIT_BASE_OF $U_MASTER=master" && [ "$(nls)" = 1 ]; then
  ok "J.1c git_base_of dit sa décision « GIT_BASE_OF <url>=master » — ici mémoïsée (init a découvert) : UN seul ls-remote au total"
else ko "J.1c ligne GIT_BASE_OF ou mémo : ls-remote=$(nls) — $(corps_dbg | tr '\n' ' ' | cut -c1-200)"; fi
if [ "$(libout)" = master ] && cmp -s "$TMP/lib.out" "$TMP/lib.out.sans" && [ "$J1_SANS" = 0 ] && [ "$(nls)" = 1 ]; then
  ok "J.1d stdout de git_base_of INCHANGÉ : exactement « master », octet pour octet le même que sans STOA_DEBUG (qui n'émet, lui, 0 ligne [dbg) ; toujours UN seul ls-remote"
else ko "J.1d stdout='$(libout)' sans-debug='$(tr -d '\n' < "$TMP/lib.out.sans")' lignes-sans-debug=$J1_SANS ls-remote=$(nls)"; fi

# J.2 — le knob explicite : dit, et toujours ZÉRO appel git (le debug n'en ajoute pas).
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER" - GIT_BASE=develop STOA_DEBUG=1
if [ "$(rrc)" = 0 ] && ligne_dbg "GIT_BASE=develop" && ligne_dbg "GIT_BASE_ORIGINE=knob" && muet; then
  ok "J.2a knob GIT_BASE=develop sous STOA_DEBUG=1 ⇒ « GIT_BASE=develop » et « GIT_BASE_ORIGINE=knob » sur stderr, stdout vide"
else ko "J.2a rc $(rrc) : $(corps_dbg | tr '\n' ' ') stdout='$(libout)'"; fi
if [ "$(nls)" = 0 ] && ! grep -q 'ls-remote' "$TMP/err"; then
  ok "J.2b AUCUN ls-remote : ni dans le journal du shim ($(wc -l < "$SHIM_LOG" | tr -d ' ') appel(s) git), ni sur stderr — le mode debug n'ajoute aucune commande git"
else ko "J.2b ls-remote vu : shim=$(nls) stderr=$(grep -c ls-remote "$TMP/err")"; fi

# J.3 — le chemin d'échec : le rc du ls-remote se lit AVANT le verdict (c'est
# le point du mode debug) — l'ORDRE est vérifié, pas seulement la présence.
joue "$LIB" "$TMP/c-init.sh" "$U_VIDE" - STOA_DEBUG=1
L_LSR=$(grep -nF "] git ls-remote --symref $U_VIDE HEAD -> rc 0 (0 octets)" "$TMP/err" | head -1 | cut -d: -f1)
L_REF=$(grep -n '^REFUS: BRANCHE_PAR_DEFAUT_INCONNUE : ' "$TMP/err" | head -1 | cut -d: -f1)
if [ "$(rrc)" = 2 ] && [ -n "$L_LSR" ] && [ -n "$L_REF" ] && [ "$L_LSR" -lt "$L_REF" ]; then
  ok "J.3 dépôt VIDE ⇒ « ls-remote … -> rc 0 (0 octets) » (ligne $L_LSR de stderr) PRÉCÈDE « REFUS: BRANCHE_PAR_DEFAUT_INCONNUE » (ligne $L_REF)"
else ko "J.3 rc $(rrc) : ls-remote ligne '${L_LSR:-absente}', refus ligne '${L_REF:-absent}' — $(head -3 "$TMP/err" | tr '\n' ' ' | cut -c1-200)"; fi

# J.4 — le secret d'une URL : la ligne de debug est LÀ (contrôle positif), le
# secret n'est NULLE PART — ni stdout, ni stderr, ni le REFUS. La lib masque
# l'userinfo AVANT d'appeler dbg (le refus a le même masque) et dbg la passe
# ENCORE par redact (forme ://…@) : « <masqué> » ou « <secret masqué> », les
# deux disent la même chose, jamais « S3cret-jx ».
U_SECRET='http://u:S3cret-jx@127.0.0.1:1/x.git'
joue "$LIB" "$TMP/c-init.sh" "$U_SECRET" - STOA_DEBUG=1
if [ "$(rrc)" = 2 ] && refus && corps_dbg | grep -qE '^git ls-remote --symref http://<(secret )?masqué>@127\.0\.0\.1:1/x\.git HEAD -> rc [1-9][0-9]* \(0 octets\)$'; then
  ok "J.4a URL avec userinfo, forge injoignable ⇒ la ligne ls-remote est LÀ avec son rc ($(corps_dbg | grep -o 'rc [0-9]*' | head -1)) et l'userinfo masquée (contrôle positif)"
else ko "J.4a rc $(rrc) : $(corps_dbg | grep ls-remote | head -1 | cut -c1-160)"; fi
if ! fuite S3cret-jx && grep -q '://<masqué>@127.0.0.1:1/x.git' "$TMP/err"; then
  ok "J.4b « S3cret-jx » n'apparaît NI sur stdout NI sur stderr — y compris dans le REFUS, qui nomme l'URL expurgée « ://<masqué>@ »"
else ko "J.4b FUITE ou refus sans URL expurgée : $(grep -n 'S3cret-jx' "$TMP/out" "$TMP/err" "$TMP/lib.out" | head -1 | cut -c1-160)"; fi

# J.4c — GIT_TRACE=1 HÉRITÉ (le knob de debug de git, celui qu'un client pose à
# côté de STOA_DEBUG ; la lib hérite de l'environnement par contrat) : git
# 2.42.0 recopie alors l'URL AVEC son userinfo sur son stderr — sept fois sur
# quatre lignes, 899 octets mesurés sur ce poste. Le REFUS relaie ce stderr
# tronqué à 300 octets ; tronquer AVANT de masquer laissait un « u:S3cret-j »
# orphelin de son `@` — que la forme ://…@ du sed ne prend plus — en clair dans
# le REFUS (relecture L2-A2, F1 : 10 longueurs d'URL sur 91). La lib masque
# désormais le stderr EN ENTIER, puis coupe.
# LA FIXTURE EST MESURÉE, pas supposée : on cherche les longueurs d'URL pour
# lesquelles le 300e octet du stderr BRUT de git (le vrai, sous le même
# environnement que le harnais) tombe DANS l'userinfo ; sans une telle
# longueur l'épreuve est un ko (« git ne recopie plus l'URL ? la mesure de F1
# est à refaire »), jamais un vert vacant. Puis, à CHACUNE de ces longueurs :
# la ligne [dbg est là avec son rc (présence), pas un fragment du secret
# (absence). §J.6d prouve que ces longueurs mordent sur le chemin RÉEL de la
# lib (shim compris) : l'ancien ordre y fait ressortir le fragment.
# `return 0` : git rend 128 (forge injoignable) et la suite est sous pipefail —
# sans lui, le `if … | grep -q` aval hériterait de ce 128 et ne verrait AUCUNE
# longueur, même trouvée (mesuré : 0/141, puis 25-28 une fois le rc rendu).
trace_brute(){   # <url> → le stderr de git sous GIT_TRACE=1, mis sur une ligne
  env -i PATH="$PATH" HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TRACE=1 GIT_TERMINAL_PROMPT=0 \
    "$REAL_GIT" ls-remote --symref "$1" HEAD 2>&1 >/dev/null </dev/null | tr '\n' ' '
  return 0
}
url_pad(){ printf 'http://u:S3cret-jx@127.0.0.1:1/%s.git' "$(printf '%*s' "$1" '' | tr ' ' a)"; }
PADS=''; NPAD=0
for p in $(seq 0 140); do
  if trace_brute "$(url_pad "$p")" | head -c 300 | LC_ALL=C grep -qE '://u:S3[A-Za-z0-9-]*$'; then PADS="$PADS $p"; NPAD=$((NPAD+1)); fi
  [ "$NPAD" -lt 6 ] || break
done
PADS="${PADS# }"
if [ "$NPAD" -eq 0 ]; then
  ko "J.4c aucune longueur d'URL (0..140) ne fait tomber le 300e octet du stderr de git dans l'userinfo sous GIT_TRACE=1 — $("$REAL_GIT" --version) ne recopie plus l'URL ? la mesure de F1 est à refaire : l'épreuve n'a pas de fixture"
  ko "J.4d (sans fixture, voir J.4c)"
else
  J4C_FUITES=0; J4C_DBG=0; J4C_DET=''
  for p in $PADS; do
    joue "$LIB" "$TMP/c-init.sh" "$(url_pad "$p")" - STOA_DEBUG=1 GIT_TRACE=1
    ! fuite 'u:S3' || J4C_FUITES=$((J4C_FUITES+1))
    if [ "$(rrc)" = 2 ] && refus && corps_dbg | LC_ALL=C grep -qE '^git ls-remote --symref http://<(secret )?masqué>@127\.0\.0\.1:1/a*\.git HEAD -> rc [1-9][0-9]* \(0 octets\)$'; then J4C_DBG=$((J4C_DBG+1)); fi
    [ -n "$J4C_DET" ] || J4C_DET="$(LC_ALL=C sed -n 's/^REFUS: BRANCHE_PAR_DEFAUT_INCONNUE : .* a échoué (rc [0-9]*) : \(.*\) — dépôt injoignable.*$/\1/p' "$TMP/err" | head -1)"
  done
  if [ "$J4C_FUITES" -eq 0 ] && [ "$J4C_DBG" -eq "$NPAD" ]; then
    ok "J.4c GIT_TRACE=1 hérité, $NPAD longueur(s) d'URL (pad $PADS) où le 300e octet du stderr de git tombe DANS l'userinfo ⇒ à chacune : rc 2, REFUS, la ligne [dbg ls-remote là avec son rc — et pas un fragment « u:S3 » nulle part"
  else ko "J.4c fuites=$J4C_FUITES/$NPAD, lignes [dbg=$J4C_DBG/$NPAD (pad $PADS) — $(LC_ALL=C grep -o 'u:S3[A-Za-z0-9-]*' "$TMP/err" | head -1)"; fi
  # J.4d — la coupe a bien eu lieu, et APRÈS le masque : le détail relayé fait
  # 300 octets EXACTEMENT (le stderr masqué en fait 885) et porte le masque.
  # Une coupe avant le masque rendrait un détail plus COURT (le masque retire
  # deux octets par URL entière qu'il trouve dans les 300 premiers).
  if [ "$(printf '%s' "$J4C_DET" | wc -c | tr -d ' ')" -eq 300 ] && printf '%s' "$J4C_DET" | LC_ALL=C grep -q '://<masqué>@127.0.0.1:1/'; then
    ok "J.4d … et le détail relayé dans le REFUS fait 300 octets EXACTEMENT et porte « ://<masqué>@ » : la coupe a eu lieu, APRÈS le masque"
  else ko "J.4d détail de $(printf '%s' "$J4C_DET" | wc -c | tr -d ' ') octet(s) : $(printf '%s' "$J4C_DET" | LC_ALL=C cut -c1-120)"; fi
fi

# J.4e — le SECOND site, git_base_clone_refus : son 3e argument est le stderr
# du clone, un FICHIER par contrat — la fixture se compose donc à l'octet près,
# à l'image d'une trace de git : une première ligne qui cite l'URL nue en
# entier, du remplissage sur une seconde ligne (le `tr` doit joindre les deux),
# puis une seconde URL nue dont le 300e octet tombe sur le `t` de « u:S3cret ».
# L'ancien ordre relayait « u:S3cret » (§J.6d le rejoue) ; le bon masque les
# deux, et le détail fait 300 octets, avec la première URL masquée en entier.
ERRF_J4="$TMP/j4e.err"
J4E_L1='trace: built-in: git clone -q --depth 1 -b master http://u:S3cret-jx@127.0.0.1:1/x.git d'
{ printf '%s\n' "$J4E_L1"; printf '%*s' $((285 - ${#J4E_L1} - 1)) '' | tr ' ' x; printf 'http://u:S3cret-jx@127.0.0.1:1/x.git fatal: composé\n'; } > "$ERRF_J4"
joue "$LIB" "$TMP/c-clone-refus-fichier.sh" "$U_SECRET" master ERRF="$ERRF_J4"
J4E_DET="$(LC_ALL=C sed -n 's/^REFUS: DEPOT_INJOIGNABLE : .* (git : \(.*\))$/\1/p' "$TMP/err" | head -1)"
if [ "$(rrc)" = 1 ] && LC_ALL=C grep -q '^REFUS: DEPOT_INJOIGNABLE : ' "$TMP/err" && ! fuite 'u:S3' \
   && [ "$(printf '%s' "$J4E_DET" | wc -c | tr -d ' ')" -eq 300 ] \
   && printf '%s' "$J4E_DET" | LC_ALL=C grep -q 'master http://<masqué>@127.0.0.1:1/x.git d xxx' \
   && printf '%s' "$J4E_DET" | LC_ALL=C grep -q 'xhttp://<masqu'; then
  ok "J.4e git_base_clone_refus, stderr composé dont le 300e octet tombe dans l'userinfo ⇒ DEPOT_INJOIGNABLE, détail de 300 octets, les DEUX URL masquées « ://<masqué>@ », aucun « u:S3 »"
else ko "J.4e rc $(rrc) : détail $(printf '%s' "$J4E_DET" | wc -c | tr -d ' ') octet(s) — $(LC_ALL=C grep -o 'u:S3[A-Za-z0-9-]*' "$TMP/err" | head -1) $(printf '%s' "$J4E_DET" | LC_ALL=C cut -c1-120)"; fi

# J.5 — le silence quand on ne demande rien, et A.1 + B.1 rejouées sous
# STOA_DEBUG=1 : mêmes verdicts, stdout identique (c'est là qu'une ligne
# égarée sur stdout deviendrait une branche).
for V in absent 0 false off; do
  if [ "$V" = absent ]; then joue "$LIB" "$TMP/c-dbg.sh" "$U_MASTER"; else joue "$LIB" "$TMP/c-dbg.sh" "$U_MASTER" - "STOA_DEBUG=$V"; fi
  if [ "$(rrc)" = 0 ] && [ "$(dbgl)" = 0 ] && [ "$(libout)" = master ]; then ok "J.5 STOA_DEBUG $V ⇒ 0 ligne [dbg, master rendu"
  else ko "J.5 STOA_DEBUG $V : rc $(rrc), $(dbgl) ligne(s) [dbg — $(grep '^\[dbg' "$TMP/err" | head -1 | cut -c1-120)"; fi
done
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER"
cp "$TMP/out" "$TMP/out.a1"; cp "$TMP/lib.out" "$TMP/lib.out.a1"
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER" - STOA_DEBUG=1
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = master ] && [ "$(val ORIGINE)" = decouverte ] && muet \
   && cmp -s "$TMP/out" "$TMP/out.a1" && cmp -s "$TMP/lib.out" "$TMP/lib.out.a1" && [ "$(dbgl)" -ge 3 ]; then
  ok "J.5e A.1 rejouée sous STOA_DEBUG=1 ⇒ même verdict (master, decouverte, stdout vide), état IDENTIQUE octet pour octet, et $(dbgl) lignes [dbg sur stderr"
else ko "J.5e rc $(rrc) : $(cat "$TMP/out") stdout='$(libout)' lignes=$(dbgl) $(cmp "$TMP/out" "$TMP/out.a1" 2>&1 | head -1)"; fi
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER" - GIT_BASE=develop
cp "$TMP/out" "$TMP/out.b1"; cp "$TMP/lib.out" "$TMP/lib.out.b1"
joue "$LIB" "$TMP/c-init.sh" "$U_MASTER" - GIT_BASE=develop STOA_DEBUG=1
if [ "$(rrc)" = 0 ] && [ "$(val GIT_BASE)" = develop ] && [ "$(val ORIGINE)" = knob ] && [ "$(nls)" = 0 ] && muet \
   && cmp -s "$TMP/out" "$TMP/out.b1" && cmp -s "$TMP/lib.out" "$TMP/lib.out.b1" && [ "$(dbgl)" -ge 2 ]; then
  ok "J.5f B.1 rejouée sous STOA_DEBUG=1 ⇒ même verdict (develop, knob, zéro ls-remote, stdout vide), état identique, $(dbgl) lignes [dbg"
else ko "J.5f rc $(rrc) : $(cat "$TMP/out") ls-remote=$(nls) lignes=$(dbgl)"; fi

# J.6 — mutations sur COPIE (le `mute` de M) : chacune fait rougir l'épreuve visée.
# (a) la ligne de branche écrite sur stdout, là où git_base_of rend son produit.
MUTJA="$TMP/mutJa.sh"
# shellcheck disable=SC2016  # quotes SIMPLES à dessein : `"$GIT_BASE"` est le TEXTE cherché dans la lib
if ! mute "$MUTJA" 's#dbg_kv GIT_BASE "$GIT_BASE"#echo "GIT_BASE=$GIT_BASE"#'; then
  ko "J.6a mutant no-op ou incompilable — l'épreuve ne prouve rien (la ligne dbg_kv GIT_BASE a-t-elle changé de forme ?)"
else
  joue "$MUTJA" "$TMP/c-dbg.sh" "$U_MASTER" - STOA_DEBUG=1
  if [ "$(libout)" != master ] && grep -q '^GIT_BASE=master$' "$TMP/lib.out"; then
    ok "J.6a dbg_kv GIT_BASE remplacé par un echo ⇒ J.1d rougit (stdout='$(libout)' ≠ master : la ligne de debug est devenue un produit)"
  else ko "J.6a le mutant passe encore : stdout='$(libout)'"; fi
fi
# (b) l'URL NUE à la place de l'URL masquée dans les lignes « ls-remote » — la
# ligne de debug ET le refus portent le même texte, la mutation touche les deux.
MUTJB="$TMP/mutJb.sh"
# shellcheck disable=SC2016  # idem : `${masquee}` et `${url}` sont du texte pour sed
if ! mute "$MUTJB" 's#--symref ${masquee} HEAD#--symref ${url} HEAD#g'; then
  ko "J.6b mutant no-op ou incompilable — l'épreuve ne prouve rien (les lignes ls-remote ont-elles changé de forme ?)"
else
  joue "$MUTJB" "$TMP/c-init.sh" "$U_SECRET" - STOA_DEBUG=1
  if fuite S3cret-jx && grep -q '^REFUS: .*S3cret-jx' "$TMP/err"; then
    ok "J.6b URL nue dans les lignes ls-remote ⇒ J.4b rougit (S3cret-jx sort dans le REFUS, qui ne passe pas par redact)"
  else ko "J.6b le mutant passe encore : aucune fuite vue — $(grep -c 'S3cret-jx' "$TMP/err") occurrence(s) sur stderr"; fi
  # Le second filet, MESURÉ et non supposé : sous le même mutant, la ligne
  # [dbg reste masquée par la forme ://…@ de redact (dbg.sh, §E de sa suite).
  # C'est pourquoi la mutation ne peut faire fuir que le refus : la ligne de
  # debug est sous DEUX masques, celui de la lib (prouvé ici par le refus, qui
  # n'a que lui) et celui de dbg.sh.
  if corps_dbg | grep -q '^git ls-remote --symref http://<secret masqué>@127.0.0.1:1/x.git HEAD -> rc ' && ! grep -q '^\[dbg .*S3cret-jx' "$TMP/err"; then
    ok "J.6c … et sous ce mutant la ligne [dbg reste masquée « ://<secret masqué>@ » : redact est le second filet, sur le chemin, éprouvé"
  else ko "J.6c la ligne [dbg du mutant : $(corps_dbg | grep ls-remote | head -1 | cut -c1-160)"; fi
fi
# (d) L'ANCIEN ORDRE — couper à 300 octets PUIS masquer (la lib de L3, le défaut
# F1 de la relecture L2-A2) : les deux sites passent par _git_base_stderr_relaye,
# la mutation inverse ses deux étapes. Aux longueurs d'URL mesurées en J.4c et
# sur le fichier composé de J.4e, un fragment « u:S3… » ressort dans le REFUS :
# J.4c ET J.4e rougissent. C'est aussi la preuve que la fixture de J.4c MORD sur
# le chemin réel de la lib (shim compris), pas seulement sur le stderr brut.
MUTJD="$TMP/mutJd.sh"
# shellcheck disable=SC2016  # idem : `${1:-}` et `$m` sont du texte pour sed
if ! mute "$MUTJD" 's#_git_base_masquer "${1:-}" 2>/dev/null | tr#head -c 300 "${1:-}" 2>/dev/null | tr#;s#head -c 300 <<<"$m"#_git_base_masquer <<<"$m"#'; then
  ko "J.6d mutant no-op ou incompilable — l'épreuve ne prouve rien (_git_base_stderr_relaye a-t-elle changé de forme ?)"
else
  J6D_FUITES=0; J6D_FRAG=''
  for p in ${PADS:-}; do
    joue "$MUTJD" "$TMP/c-init.sh" "$(url_pad "$p")" - STOA_DEBUG=1 GIT_TRACE=1
    if LC_ALL=C grep -q '^REFUS: .*u:S3' "$TMP/err"; then J6D_FUITES=$((J6D_FUITES+1)); J6D_FRAG="$J6D_FRAG $(LC_ALL=C grep -o 'u:S3[A-Za-z0-9-]*' "$TMP/err" | head -1)"; fi
  done
  joue "$MUTJD" "$TMP/c-clone-refus-fichier.sh" "$U_SECRET" master ERRF="$ERRF_J4"
  if [ "${NPAD:-0}" -gt 0 ] && [ "$J6D_FUITES" -eq "$NPAD" ] && LC_ALL=C grep -q '^REFUS: DEPOT_INJOIGNABLE : .*u:S3cret' "$TMP/err"; then
    ok "J.6d coupe-puis-masque (l'ancien ordre) ⇒ J.4c rougit à $J6D_FUITES/$NPAD longueur(s) («$J6D_FRAG » dans le REFUS) et J.4e rougit (« u:S3cret » relayé par git_base_clone_refus)"
  else ko "J.6d le mutant passe encore : fuites J.4c=$J6D_FUITES/${NPAD:-0}, clone : $(LC_ALL=C grep -o 'u:S3[A-Za-z0-9-]*' "$TMP/err" | head -1)"; fi
fi

echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" $((PASS + FAIL))
[ "$FAIL" -eq 0 ] || exit 1
