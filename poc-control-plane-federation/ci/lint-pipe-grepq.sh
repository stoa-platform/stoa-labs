#!/usr/bin/env bash
# ci/lint-pipe-grepq.sh — LA PORTE QUI MANQUAIT : « … | grep -q … » sous `pipefail`.
#
# ─────────────────────────────────────────────────────────────────────────────
# POURQUOI CETTE PORTE EXISTE
# ─────────────────────────────────────────────────────────────────────────────
# `grep -q` sort à la PREMIÈRE correspondance et ferme le tuyau. L'écrivain en
# amont, s'il écrit encore, prend un SIGPIPE et rend 141 ; sous `set -o pipefail`
# le pipeline vaut alors 141, donc NON NUL — et en condition, le test devient FAUX
# PRÉCISÉMENT QUAND LE MOTIF EST PRÉSENT. Le verdict s'inverse en silence.
#
# ⚠ LE PIÈGE DÉPEND DE LA TAILLE, DONC IL DORT. Tant que la sortie de l'écrivain
# tient dans le tampon du tuyau, il a fini d'écrire avant que `grep` ne parte : pas
# de SIGPIPE, le contrôle marche. Mesuré le 2026-09-17 sur un fichier réel :
#     fenêtre 100 lignes (6 Ko)  : détecte
#     fenêtre 435 lignes (28 Ko) : AVEUGLE
# Un contrôle juste aujourd'hui devient vacant le jour où le fichier grossit, sans
# qu'une ligne n'ait changé. C'est pour ça qu'on refuse la FORME, uniformément,
# sans chercher à prédire quel tampon sauve quelle occurrence : prédire le tampon
# est exactement la partie qui dort.
#
# CE QUE ÇA A COÛTÉ AVANT LA PORTE. Deux assertions de câblage étaient VERTES À
# TORT depuis des mois (`test-team-apply-wiring.sh` §15, `test-team-publish-wiring.sh`).
# La conversion les a RÉVEILLÉES : toutes deux signalaient un vrai défaut.
#
# LE REMÈDE : `pipe_q`, qui redirige À L'INTÉRIEUR. `grep -c` a le MÊME statut de
# sortie que `grep -q` (0 si ≥1 ligne, 1 sinon, 2 en erreur — mesuré) et lit TOUTE
# son entrée : aucun SIGPIPE. On ne remplace PAS par `grep -c … >/dev/null` sur
# place, parce qu'il faudrait poser la redirection à la fin d'une commande dont les
# arguments débordent parfois sur la ligne suivante — 726 placements, c'est là
# qu'un lot mécanique casse sans bruit.
#
# ⚠ LE HELPER N'EXISTE PAS DANS UN SHELL QU'ON DÉMARRE. Un bloc `sh '''` de
# Jenkinsfile, un corps de heredoc, un `sh -c '…'` : ces programmes n'héritent
# d'AUCUNE fonction. `pipe_q` y serait introuvable ⇒ 127 ⇒ non nul ⇒ FAUX en
# condition — soit exactement le défaut réparé. Ces sites gardent
# `grep -c … >/dev/null`, écrit sur place. §R5 mesure cette règle.
#
# CE QU'ELLE VÉRIFIE
#   R1  aucun « | grep -q » (un seul tuyau ; « || grep -q » n'est pas un pipeline)
#   R2  qui DÉFINIT pipe_q l'INVOQUE  (remplace SC2329, faux ici — voir plus bas)
#   R3  toutes les définitions sont IDENTIQUES À L'OCTET (duplication MESURÉE)
#   R4  la définition PRÉCÈDE le premier usage (sinon 127 à l'exécution)
#   R5  aucun usage de pipe_q dans un SHELL ENFANT (heredoc à terminateur RÉEL,
#       bloc `sh '''`) — le helper n'y existe pas
#
# ⚠ SC2329 NE REMPLACE PAS R2 : shellcheck 0.11.0 signale `pipe_q` comme « jamais
# invoquée » dans 5 fichiers où elle l'est, en pipeline (0 signalement à HEAD, donc
# le défaut vient bien de la conversion ; et il l'accepte sur un script minimal).
# D'où `# shellcheck disable=SC2329` dans le bloc, et R2 qui mesure VRAIMENT la
# propriété que SC2329 prétend garantir.
#
# PORTÉE DÉRIVÉE, JAMAIS UNE LISTE : `git ls-files`. Une liste à la main a déjà
# manqué deux fichiers dans ce dépôt le jour même de ce lot (`ci/test-*.sh` et
# `observability/…`), parce qu'aucun glob ne les couvrait.
#
# L'INCLASSABLE EST ROUGE : un fichier qu'elle ne sait pas classer est signalé,
# jamais écarté en silence.
#
# USAGE
#   ci/lint-pipe-grepq.sh          # depuis poc-control-plane-federation/
#   make lint-ci                   # sous l'étape 2, sans rang à elle
set -uo pipefail

# ⚠ CETTE PORTE NE DÉFINIT PAS `pipe_q`, ET C'EST VOULU : elle ne lit que des
# FICHIERS (`grep -qxF -- … "$f"`), jamais un tuyau — donc aucun SIGPIPE possible,
# donc aucun besoin du helper. En définir un qu'elle n'invoquerait pas ferait
# rougir sa propre règle R2 le jour où elle est suivie par git. Une porte doit
# passer la règle qu'elle impose.

cd "$(dirname "$0")/.." || exit 2
KO=0
ko(){ printf '  \033[31m❌\033[0m %s\n' "$*"; KO=1; }
ok(){ printf '  \033[32m✅\033[0m %s\n' "$*"; }

PORTEE=$(git ls-files | grep -E '\.sh$|/Jenkinsfile' || true)
[ -n "$PORTEE" ] || { echo "REFUS: PORTEE_VIDE : git ls-files n'a rien rendu — la porte ne mesurerait rien" >&2; exit 2; }
NF=$(printf '%s\n' "$PORTEE" | grep -c .)

# ── R1 : aucun « | grep -q », un seul tuyau ──────────────────────────────────
R1=$(printf '%s\n' "$PORTEE" | while IFS= read -r f; do
  [ -f "$f" ] || continue
  # EXEMPTES NOMMES, et ils sont les deux SEULS : cette porte doit PORTER le motif
  # interdit (son propre programme awk le contient), et son epreuve doit le porter
  # aussi pour pouvoir le MUTER. Sans cette exemption, la porte se refuserait
  # elle-meme — et la tentation serait alors daffaiblir la regle pour se laisser
  # passer, soit exactement le geste que ce depot proscrit. Exempter par NOM, avec
  # la raison ecrite, garde la regle entiere pour tout le reste.
  # (Pas dapostrophe ici : ce bloc vit dans un $( … ) et une apostrophe de
  # commentaire y a deja casse le `case` qui suit — sixieme faute de citation du
  # jour dans du code ecrit a la main, toutes attrapees par `bash -n`.)
  # `if` et non `case` : un `case` vit ici DANS un $( … ), et les `)` de ses motifs
  # sont un piege connu de cette imbrication. Un test degalite suffit — `git ls-files`
  # rend des chemins relatifs a la racine, ou cette porte sest deja placee.
  if [ "$f" = "ci/lint-pipe-grepq.sh" ] || [ "$f" = "scripts/test-pipe-q.sh" ]; then
    continue
  fi
  awk -v F="$f" '
    # UNE LIGNE DE COMMENTAIRE NEST PAS DU CODE. Cette porte a rougi sur le
    # commentaire qui EXPLIQUE le piege, dans le fichier meme ou on venait de le
    # reparer : juger le TEXTE au lieu de leffet est un defaut que ce depot a deja
    # nomme. Un commentaire en fin de ligne, lui, ne masque rien : la partie CODE
    # de la ligne reste examinee.
    /^[[:space:]]*#/ { next }
    { l=$0
      # ATTENTION : ce commentaire vit DANS un programme awk entre quotes SIMPLES.
      # Une apostrophe y FERMERAIT la chaine du shell (cest exactement ce qui a
      # casse la premiere ecriture de cette porte, avec une erreur signalee 60
      # lignes plus loin). Pas daccent, pas dapostrophe ici.
      # Un « || grep -q » ne forme PAS un pipeline : aucun ecrivain, aucun SIGPIPE.
      gsub(/\|\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q[a-zA-Z]*/, "", l)
      if (l ~ /\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q[a-zA-Z]*/) printf "%s:%d\n", F, NR }
  ' "$f"
done)
if [ -z "$R1" ]; then
  ok "R1 aucun « | grep -q » dans $NF fichiers (portée dérivée de git ls-files)"
else
  ko "R1 « | grep -q » subsiste — le verdict s'y inverse dès que le flux grossit :"
  printf '%s\n' "$R1" | sed 's/^/       /'
fi

# ── R2/R3/R4/R5 : le helper lui-même ─────────────────────────────────────────
REF_DEF='pipe_q() { grep -c "$@" >/dev/null; }'
DEFS=$(printf '%s\n' "$PORTEE" | while IFS= read -r f; do
  [ -f "$f" ] && grep -l '^pipe_q() {' "$f" 2>/dev/null
done)
ND=$(printf '%s\n' "$DEFS" | grep -c . || true)

MAUVAIS=''; ORPHELIN=''; ORDRE=''; ENFANT=''
for f in $DEFS; do
  [ -n "$f" ] || continue
  # R3 — la ligne de définition, à l'octet
  grep -qxF -- "$REF_DEF" "$f" || MAUVAIS="$MAUVAIS $f"
  # R2 — qui définit invoque
  U=$(grep -cE '\|[[:space:]]*pipe_q\b' "$f")
  [ "$U" -gt 0 ] || ORPHELIN="$ORPHELIN $f"
  # R4 — la définition précède le premier usage
  LD=$(grep -n '^pipe_q() {' "$f" | head -1 | cut -d: -f1)
  LU=$(grep -nE '\|[[:space:]]*pipe_q\b' "$f" | head -1 | cut -d: -f1)
  if [ -n "$LD" ] && [ -n "$LU" ] && [ "$LD" -gt "$LU" ]; then ORDRE="$ORDRE $f(def=$LD,usage=$LU)"; fi
done

# R5 — usage de pipe_q dans un SHELL ENFANT. Le suivi de heredoc n'ouvre QUE si un
# TERMINATEUR RÉEL existe : sans cette règle, un « 3<<_EOF » écrit DANS un motif
# sed passe pour une ouverture et marque tout le reste du fichier (faux positif
# partagé par DEUX détecteurs indépendants le 2026-09-18 — la redondance ne protège
# pas quand les deux reposent sur la même heuristique).
# ⚠ LE PROGRAMME awk VIT DANS UN FICHIER, et ce n'est pas du confort : l'écrire en
# ligne obligeait à imbriquer des quotes simples dans des quotes simples, ce qui a
# cassé la PREMIÈRE écriture de cette porte (erreur de syntaxe à 60 lignes de là,
# donc attribuée au mauvais endroit). Un heredoc cité rend tout littéral.
AWKP="$(mktemp /tmp/lpg.XXXXXX)"
trap 'rm -f "$AWKP"' EXIT
cat > "$AWKP" <<'AWK'
function estterm(d,  i){ for(i=1;i<=nl;i++) if (ligne[i] ~ "^[[:space:]]*" d "[[:space:]]*$") return 1; return 0 }
{ nl++; ligne[nl]=$0 }
END{
  delim=""; groovy=0
  for(i=1;i<=nl;i++){
    l=ligne[i]
    if (delim=="") {
      if (l !~ /^[[:space:]]*#/ && match(l, /<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*/)) {
        d=substr(l, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*['"]?/, "", d)
        if (estterm(d)) delim=d
      }
    } else if (l ~ "^[[:space:]]*" delim "[[:space:]]*$") { delim=""; continue }
    # LA REGLE GROOVY NE VAUT QUE POUR UN JENKINSFILE, et cest une correction de
    # conception, pas un motif quon elargit : « sh ''' » est de la syntaxe GROOVY.
    # La chercher dans un fichier .sh, ou trois quotes peuvent se suivre par
    # accident, produit des faux positifs — 36 sites accuses a tort, dans des
    # fichiers ou la machine a heredoc nouvrait pourtant rien (mesure).
    # ET UN COMMENTAIRE GROOVY NON PLUS NEST PAS DU CODE : ce qui a ouvert un faux
    # bloc dans un fichier .sh etait un COMMENTAIRE racontant que six lignes avaient
    # existe « dans un sh ... ». Meme faute que R1, commise deux fois dans la meme
    # porte : juger le texte au lieu de leffet. On la ferme ici aussi.
    if (jenkinsfile && l !~ /^[[:space:]]*\/\//) {
      if (l ~ /sh[[:space:]]+'''/) groovy=1
      else if (groovy && l ~ /'''/) groovy=0
    }
    if ((delim!="" || groovy) && l ~ /\|[[:space:]]*pipe_q/) printf "%d ", i
  }
}
AWK
for f in $DEFS $(printf '%s\n' "$PORTEE" | grep '/Jenkinsfile' || true); do
  [ -f "$f" ] || continue
  case "$f" in *Jenkinsfile*) JF=1 ;; *) JF=0 ;; esac
  E=$(awk -v jenkinsfile="$JF" -f "$AWKP" "$f")
  [ -n "$E" ] && ENFANT="$ENFANT $f(lignes:$E)"
done

[ -z "$MAUVAIS"  ] && ok "R3 les $ND définitions de pipe_q sont IDENTIQUES à l'octet" || ko "R3 définition divergente :$MAUVAIS"
[ -z "$ORPHELIN" ] && ok "R2 chaque fichier qui DÉFINIT pipe_q l'INVOQUE ($ND)"      || ko "R2 définit pipe_q sans jamais l'invoquer :$ORPHELIN"
[ -z "$ORDRE"    ] && ok "R4 la définition PRÉCÈDE le premier usage partout"          || ko "R4 usage AVANT définition (127 à l'exécution) :$ORDRE"
[ -z "$ENFANT"   ] && ok "R5 aucun usage de pipe_q dans un shell ENFANT (heredoc à terminateur réel, bloc sh ''')" \
                   || ko "R5 pipe_q employé dans un shell ENFANT — il y est introuvable (127), le test s'inverse :$ENFANT"

echo
if [ "$KO" -eq 0 ]; then echo "PORTE VERTE : la forme « | grep -q » n'existe plus, et le helper tient ses 4 invariants."; exit 0
else echo "PORTE ROUGE : voir ci-dessus."; exit 1; fi
