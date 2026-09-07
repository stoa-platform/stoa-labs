#!/bin/sh
# Deux sujets, dans cet ordre : (P) le PREFLIGHT de joignabilite de la gateway,
# (X) la composition de la base du proxy d'admin. Rejoue la logique reelle sous
# `set -eu`, avec un curl simule.
#
# ⚠ L'ORDRE EST DELIBERE (2026-09-07). Le bloc du proxy compte deux ecarts
# CONNUS et ETRANGERS au preflight (cf. la garde en tete de sa boucle) ; tant
# que les sections du preflight vivaient DANS cette boucle, son arret precoce
# (un `fatal`, sortie 2) rendait TOUTE la couverture du preflight
# INATTEIGNABLE. Le preflight passe donc en premier et rend son propre verdict
# intermediaire, que l'etat du bloc proxy ne peut plus effacer.
#
# ⚠ LE PREFLIGHT N'EST PLUS DANS LES JENKINSFILE. Il a une implementation et
# une seule — ci/lib/preflight.sh — que les deux pipelines SOURCENT. Les
# assertions litterales portent donc sur la LIB, et le CABLAGE (chaque
# Jenkinsfile source la lib, appelle apim_preflight, sort 1 sur refus, et n'en
# garde AUCUNE copie) est verifie a part. C'est precisement ce qui manquait du
# temps de la duplication : un seul des deux fichiers a regresse (merge
# 5d34299, preflight rendu a une version sans knob ni garde-fou) et aucune
# assertion ne pouvait le dire, puisque chacune portait sur UN fichier.
#
# CE QUE CE TEST LIT VRAIMENT — et ne code plus en dur :
#   - le point de comparaison (BASE_REF) = le dernier commit de l'historique
#     de HEAD ou Jenkinsfile.publish-api porte encore un defaut
#     APIM_PROXY_BASE NON VIDE (donc AVANT la proxification par morceaux),
#     jamais un SHA fige NI une derivation par branche (cf. plus bas) ;
#   - l'ANCIEN defaut = l'URL entiere ecrite dans le Jenkinsfile a ce point,
#     relue par `git show <base>:<fichier>` — pour Jenkinsfile.publish-api
#     SEULEMENT (ce fichier UNIQUE fixe le point de comparaison, et l'URL
#     historique qui en est tiree sert de reference aux DEUX Jenkinsfile
#     courants ; l'historique de Jenkinsfile.selfservice n'est jamais relu) ;
#   - les defauts APIM_PROXY_* = extraits par sed sur CHAQUE Jenkinsfile REEL ;
#   - la ligne de composition elle-meme = extraite de CHAQUE Jenkinsfile REEL ;
#   - les defauts du preflight (codes de preuve de vie, nombre d'essais) =
#     extraits par sed de ci/lib/preflight.sh, l'unique implementation ;
#   - les garde-fous (validation de APIM_PREFLIGHT_TRIES, casse de
#     APIM_PREFLIGHT) = leur PRESENCE ET leur ordre sont verifies par lecture
#     litterale (grep) de la LIB REELLE, pas seulement rejoues dans le
#     harnais de simulation ci-dessous ;
#   - le COMPORTEMENT des garde-fous sur les valeurs adverses = le bloc est
#     DECOUPE dans la LIB REELLE et EXECUTE sous `sh` (10^20, 08, 060),
#     jamais transcrit : un rejeu peut diverger du fichier en silence ;
#   - le CABLAGE = chaque Jenkinsfile source la lib, l'appelle AVEC LE PALIER
#     en 2e argument, sort 1 sur refus, et n'en garde aucune copie residuelle ;
#   - le COMPORTEMENT DE LA FONCTION ENTIERE = la LIB REELLE est SOURCEE et
#     APPELEE, `curl` et `sleep` remplaces par des fonctions du shell (bloc
#     P1quater) : quelle URL est sondee, combien de fois, ce qui est imprime,
#     ce qui est rendu — et CHAQUE propriete a sa MUTATION (bloc P1quinquies) ;
#   - le trim d'APIM_PROXY_BASE = extrait du job XML REEL.
#
# CE QUI EST BRANCHE, ET CE QUI NE L'EST PAS (2026-09-07). `make lint-ci`
# appelle ce harnais avec STOA_PREFLIGHT_ONLY=1 : la moitie PREFLIGHT +
# CABLAGE, celle qui aurait attrape 5d34299. Le bloc PROXY reste NON BRANCHE et
# ROUGE (5 KO residuels, etrangers au preflight) — l'arbitrage qui les fermerait
# est ecrit au-dessus du `if [ -n "${STOA_PREFLIGHT_ONLY:-}" ]`. Avant ce jour,
# RIEN n'appelait ce fichier : ses assertions de cablage ne s'executaient jamais.
# Le premier jet codait les DEUX cotes de l'assertion « defauts => identique a
# l'ancien defaut » dans le test : il comparait deux constantes du test entre
# elles et restait VERT alors qu'un defaut du Jenkinsfile avait rompu la
# retro-compatibilite. Un test qui ne lit pas son sujet ne teste rien.
#
# Boucle sur les DEUX Jenkinsfile : rien ne garantit qu'ils restent alignes —
# et pour le preflight, plus rien n'a besoin de le garantir, il n'y en a
# qu'un.
set -eu

ICI="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"   # .../poc-control-plane-federation/ci
POC="$(dirname "$ICI")"                                 # .../poc-control-plane-federation
RACINE="$(dirname "$POC")"                              # racine du depot
SOUS_POC="$(basename "$POC")"
JENKINSFILES="Jenkinsfile.publish-api Jenkinsfile.selfservice"

KO=0
ok(){ printf '  ok   %s\n' "$1"; }
ko(){ printf '  KO   %s\n     attendu=[%s]\n     obtenu =[%s]\n' "$1" "$2" "$3"; KO=$((KO+1)); }
cmp_(){ [ "$2" = "$3" ] && ok "$1" || ko "$1" "$2" "$3"; }
# Vrai si $2 (sous-chaine fixe) apparait litteralement dans le fichier $3 —
# pour verifier qu'un garde-fou est bien ECRIT dans le fichier REEL, sans
# recopier sa logique dans le test (meme piege que l'ancien defaut fige).
contient(){ grep -qF -- "$2" "$3" && ok "$1" || ko "$1" "present dans $3" "absent de $3"; }
# LE PREDICAT DU CABLAGE, NU — et pourquoi `contient` ne suffit PAS ici.
# `contient` = `grep -qF` NON ANCRE : il dit qu'un TEXTE est present, pas qu'une
# LIGNE s'execute. Un appel COMMENTE le satisfait donc pleinement — le texte est
# la, le preflight ne tourne plus. C'est EXACTEMENT la panne 5d34299 sous une
# autre forme, et les deux assertions de cablage etaient censees l'attraper.
# Mesure du 2026-09-07 : les deux Jenkinsfile, leurs deux lignes commentees,
# restaient VERTS. D'ou ce predicat — la ligne doit exister ET ne pas etre un
# commentaire, ni de shell (`#`, le bloc `sh` de Jenkins tourne en dash) ni de
# Groovy (`//`, hors du bloc `sh`).
# `grep -F | grep -qvE` : si la premiere ne trouve rien, la seconde lit du vide
# et rend 1 — donc absent ET commente-seulement rendent tous deux faux.
actif_dans(){ grep -F -- "$1" "$2" 2>/dev/null | grep -qvE '^[[:space:]]*(#|//)'; }
contient_actif(){ actif_dans "$2" "$3" && ok "$1" \
  || ko "$1" "present sur une ligne NON COMMENTEE de $3" "absent de $3, ou present SEULEMENT en commentaire"; }
# Vrai si le motif $2 apparait a une ligne strictement avant le motif $3 dans
# le fichier $4 — un garde-fou pose APRES la boucle qu'il est cense proteger
# ne protege rien.
avant(){
  L1="$(grep -nF -- "$2" "$4" | head -1 | cut -d: -f1)"
  L2="$(grep -nF -- "$3" "$4" | head -1 | cut -d: -f1)"
  if [ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ]; then ok "$1"
  else ko "$1" "ligne($2) < ligne($3)" "L1=$L1 L2=$L2 dans $4"; fi
}
# Un prerequis manquant n'est PAS un test qui passe : le test s'arrete en 2.
fatal(){ printf '  !!   %s\n' "$1" >&2; exit 2; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# ---- lecture des Jenkinsfile ---------------------------------------------
# Defaut Groovy d'une variable d'environnement : `X = "${env.X ?: 'valeur'}"`.
# Prefixe '=' dans la sortie pour distinguer « absent » (sortie vide) de
# « present et vide » (sortie '='), le cas d'APIM_PROXY_BASE.
defaut_env(){ sed -n "s/^[[:space:]]*$2[[:space:]]*=.*?:[[:space:]]*'\([^']*\)'.*/=\1/p" "$1" | head -1; }
lire_defaut(){
  V="$(defaut_env "$1" "$2")"
  [ -n "$V" ] || fatal "$2 : aucun defaut Groovy dans $1 — le test ne peut rien affirmer"
  printf '%s' "${V#=}"
}
# Defaut shell d'une variable du corps du pipeline : `X="${ENV_VAR:-valeur}"`.
defaut_sh(){ sed -n "s/^[[:space:]]*$2=\"[\$]{$3:-\(.*\)}\".*/=\1/p" "$1" | head -1; }
lire_defaut_sh(){
  V="$(defaut_sh "$1" "$2" "$3")"
  [ -n "$V" ] || fatal "$2 (\${$3:-...}) : introuvable dans $1 — le test ne peut rien affirmer"
  printf '%s' "${V#=}"
}
# Les lignes d'affectation de PROXY_BASE, telles qu'elles sont ecrites.
ligne_pb(){ sed -n 's/^[[:space:]]*\(PROXY_BASE=.*\)$/\1/p' "$1" | grep -F "$2" | head -1; }

# ---- bloc P1 : LE PREFLIGHT — une seule implementation, deux appelants -------
# CE BLOC PASSE EN PREMIER, ET C'EST DELIBERE. Il ne depend ni de l'historique
# git ni du bloc proxy. Raison mesuree le 2026-09-07 : le bloc proxy ci-dessous
# s'arrete en `fatal` sur Jenkinsfile.publish-api (qui ne decrit pas le proxy
# par morceaux) — tant que les sections du preflight vivaient DANS sa boucle,
# TOUTE la couverture du preflight etait INATTEIGNABLE, le fatal tuant le
# script avant la premiere assertion. Un test qui ne s'execute pas ne prouve
# rien, et il le disait d'autant moins qu'il sortait en 2, pas en 1.
#
# CE QUE CE BLOC LIT. Le preflight ne vit plus dans les Jenkinsfile mais dans
# ci/lib/preflight.sh — UNE implementation, deux appelants :
#   - les defauts (codes de preuve de vie, nombre d'essais) = extraits de la LIB ;
#   - les garde-fous = leur PRESENCE ET leur ORDRE, lus litteralement dans la LIB ;
#   - leur COMPORTEMENT sur les valeurs adverses = le bloc est DECOUPE dans la
#     LIB et EXECUTE sous `sh` (10^20, 08, 060), jamais transcrit ;
#   - le CABLAGE = chaque Jenkinsfile SOURCE la lib ET APPELLE la fonction, et
#     ne garde aucune copie. Sans cette derniere assertion, un pipeline pourrait
#     perdre son preflight sans qu'aucune ligne ne rougisse : c'est exactement
#     ce qui est arrive a Jenkinsfile.publish-api (le merge 5d34299 lui a rendu
#     une version anterieure, sans knob et sans garde-fou), et que rien ne
#     mesurait — les assertions portaient sur CHAQUE fichier, donc la copie
#     saine de Jenkinsfile.selfservice ne disait rien de l'autre.
LIB="$POC/ci/lib/preflight.sh"
[ -f "$LIB" ] || fatal "$LIB introuvable — le preflight n'a plus d'implementation"

# Defauts du preflight transcrits dans `preflight()` du bloc P2.
PF_CODES_REJOUES='200 401'
PF_MAX_REJOUE='60'

echo "== ci/lib/preflight.sh : defauts du preflight =="
cmp_ "codes de preuve de vie" "$PF_CODES_REJOUES" "$(lire_defaut_sh "$LIB" PF_CODES APIM_PREFLIGHT_CODES)"
cmp_ "nombre d'essais"        "$PF_MAX_REJOUE"    "$(lire_defaut_sh "$LIB" PF_MAX   APIM_PREFLIGHT_TRIES)"

echo "== ci/lib/preflight.sh : garde-fous du preflight (lus dans le fichier reel) =="
# APIM_PREFLIGHT_TRIES non numerique : sous sh, `[ "$i" -ge "abc" ]` rend 2
# (ni vrai ni faux) — la branche de sortie n'est jamais prise, boucle a
# l'infini. Le garde-fou doit exister ET s'executer AVANT la boucle.
contient "preflight.sh : le garde-fou PF_MAX existe (case sur un entier)" 'case "$PF_MAX" in' "$LIB"
contient "preflight.sh : rejette le non-numerique" '*[!0-9]*' "$LIB"
contient "preflight.sh : rejette aussi zero EN TETE (0, 00, 08, 060 — piege octal de \$((…)))" '|0*)' "$LIB"
contient "preflight.sh : replie explicitement sur le defaut 60" 'PF_MAX=60' "$LIB"
avant "preflight.sh : le garde-fou PF_MAX est pose avant la boucle, pas apres" \
  'case "$PF_MAX" in' 'while :; do' "$LIB"
# Borne haute : sans elle, une valeur enorme mais numerique (ex.
# 99999999999999999999) passe le garde-fou ci-dessus et rouvre le meme
# mode de panne — aucun timeout de build n'est pose dans les job XML.
contient "preflight.sh : la borne haute teste la longueur avant l'arithmetique (pas de debordement de -gt)" '?????*' "$LIB"
contient "preflight.sh : la borne haute replie sur 3600" '-gt 3600' "$LIB"
avant "preflight.sh : la borne haute est posee avant la boucle, pas apres" \
  '?????*' 'while :; do' "$LIB"
# APIM_PREFLIGHT sensible a la casse : 'Off' ne doit pas etre pris pour 'off'.
contient "preflight.sh : APIM_PREFLIGHT est compare apres mise en minuscules" \
  "tr '[:upper:]' '[:lower:]'" "$LIB"
contient "preflight.sh : le test 'off' porte sur la variable normalisee" \
  'if [ "$APIM_PREFLIGHT_LC" = "off" ]; then' "$LIB"
# Le refus doit rester un REFUS de l'etape : la lib rend 1, l'appelant sort 1.
# Un `return 0` ici (ou un `exit` oublie du temps du bloc en ligne) rendrait le
# preflight decoratif — la publication continuerait sur une gateway morte.
contient "preflight.sh : l'epuisement REFUSE (return 1), il n'avertit pas" \
  'attendu : $PF_CODES)"; return 1; fi' "$LIB"

echo "== ci/lib/preflight.sh : valeurs adverses, bloc REEL extrait et EXECUTE =="
# Les `contient`/`avant` ci-dessus prouvent que le garde-fou est ECRIT ;
# `preflight()` du bloc P2 rejoue une COPIE de sa logique. Ni l'un ni l'autre
# ne prouve que le texte REEL, EXECUTE, se comporte bien : un rejeu peut
# diverger du fichier sans que rien ne le dise (c'est exactement ainsi que
# le harnais restait vert alors que '08' tuait le vrai bloc). On decoupe
# donc le bloc tel qu'il est ecrit — de `PF_MAX="${APIM_PREFLIGHT_TRIES:-60}"`
# jusqu'a la ligne qui precede `i=0` — et on l'execute sous `sh`.
sed -n '/PF_MAX="${APIM_PREFLIGHT_TRIES:-60}"/,/^[[:space:]]*i=0$/p' "$LIB" \
  | sed '$d' > "$TMPD/gardes.sh"
grep -qF 'PF_MAX=' "$TMPD/gardes.sh" \
  || fatal "preflight.sh : bloc de garde-fous du preflight introuvable (ancres deplacees ?) — le test ne peut rien affirmer"
if grep -qF 'while' "$TMPD/gardes.sh"; then
  fatal "preflight.sh : l'extraction du bloc de garde-fous a deborde sur la boucle — le test ne peut rien affirmer"
fi
# Sonde ajoutee APRES le texte extrait (jamais dedans) : valeur bornee,
# arithmetique du message de sortie, et decidabilite de la sortie de boucle
# AUX DEUX BORNES. AVANT=1 (faux et decidable) + BORNE=0 (vrai) prouvent que
# la boucle sort a exactement PF_MAX tours, sans avoir a les jouer. C'est la
# propriete qui manquait : `-ge` contre un non-entier rend 2, `if` le traite
# comme faux, la sortie n'est JAMAIS prise.
cat >> "$TMPD/gardes.sh" <<'SONDE'
RCLO=0; [ 0 -ge "$PF_MAX" ] || RCLO=$?
RCHI=0; [ "$PF_MAX" -ge "$PF_MAX" ] || RCHI=$?
printf 'PFMAX=%s MSG5=%s MSG10=%s AVANT=%s BORNE=%s\n' "$PF_MAX" "$((PF_MAX*5))" "$((PF_MAX*10))" "$RCLO" "$RCHI"
SONDE
adverse(){ APIM_PREFLIGHT_TRIES="$1" sh "$TMPD/gardes.sh" 2>&1 | tail -1; }

# MSG10 = la duree REELLEMENT annoncee depuis 2026-09-07 : chaque essai coute
# le timeout du curl (`-m 5`, consomme ENTIER quand l'hote ne repond pas) PUIS
# l'attente (`sleep 5`). MSG5 est garde a cote : c'est le chiffre FAUX d'avant,
# et le voir a cote du bon interdit de les reconfondre.
cmp_ "preflight.sh (texte reel) : 99999999999999999999 => borne a 3600, ne boucle plus sans fin" \
  "PFMAX=3600 MSG5=18000 MSG10=36000 AVANT=1 BORNE=0" "$(adverse 99999999999999999999)"
# '08' : purement numerique, donc accepte par le filtre `*[!0-9]*` — mais
# `$((08*10))` est une erreur d'arithmetique octale qui TUE l'etape sous
# `set -e`. MSG10=600 prouve que la duree annoncee est bien lue en base 10.
cmp_ "preflight.sh (texte reel) : 08 (piege octal) => ne tue plus l'etape, replie sur 60" \
  "PFMAX=60 MSG5=300 MSG10=600 AVANT=1 BORNE=0" "$(adverse 08)"
# '060' : meme filtre, mais ici l'octal est SILENCIEUX — `$((060*10))`
# vaudrait 480 (48*10) et annoncerait une duree fausse au lieu de 600.
cmp_ "preflight.sh (texte reel) : 060 => la duree annoncee n'est plus lue en octal (600s, pas 480s)" \
  "PFMAX=60 MSG5=300 MSG10=600 AVANT=1 BORNE=0" "$(adverse 060)"

echo "== le CABLAGE : les deux Jenkinsfile appellent CETTE implementation, et aucune autre =="
# L'APPEL ATTENDU, PAR FICHIER. Le 2e argument est LE PALIER : sans lui, un
# APIM_PREFLIGHT_URL pose en globale de SITE (ce que la procedure prescrit)
# sonde le MEME palier depuis tous les autres, et l'argument $1 que l'appelant
# a pris la peine de resoudre est ignore en silence. selfservice passe
# $PALIER_ENV — celui que la garde a VALIDE contre la chaine, jamais le
# parametre brut ; publish-api passe ${ENVIRONMENT:-} (vide licite : API
# mono-palier ; un gabarit __ENV__ y est alors REFUSE, pas sonde).
appel_attendu(){
  case "$1" in
    Jenkinsfile.selfservice) printf '%s' 'apim_preflight "$APIM_API_BASE" "$PALIER_ENV" || exit 1' ;;
    Jenkinsfile.publish-api) printf '%s' 'apim_preflight "$APIM_API_BASE" "${ENVIRONMENT:-}" || exit 1' ;;
    *) printf '' ;;
  esac
}
for JF in $JENKINSFILES; do
  F="$POC/ci/$JF"
  [ -f "$F" ] || fatal "$F introuvable"
  # `contient_actif` et NON `contient` : la ligne doit s'EXECUTER, pas seulement
  # figurer. Un `# . ci/lib/preflight.sh` satisfaisait `grep -qF` — le texte
  # present, le preflight mort. Mutation M8 ci-dessous.
  contient_actif "$JF : source ci/lib/preflight.sh (ligne NON commentee)" '. ci/lib/preflight.sh' "$F"
  # `|| exit 1` : le refus de la lib doit TUER l'etape. Sans lui, un preflight
  # rouge se contenterait d'imprimer une ligne et le play partirait quand meme.
  A="$(appel_attendu "$JF")"
  [ -n "$A" ] || fatal "$JF : aucun appel attendu declare dans ce test — le test ne peut rien affirmer"
  contient_actif "$JF : appelle apim_preflight avec le PALIER en 2e argument, et sort 1 si elle refuse (ligne NON commentee)" "$A" "$F"
  # Contre-epreuve de la MEME propriete, prise par l'autre bout : aucun appel
  # ne doit rester a UN seul argument. La ligne litterale ci-dessus dit ce qui
  # DOIT etre ecrit ; celle-ci dit ce qui ne doit plus l'etre nulle part —
  # c'est elle qui attrape un second appel oublie ailleurs dans le fichier.
  if grep -nE 'apim_preflight[[:space:]]+"\$APIM_API_BASE"[[:space:]]*(\|\||$)' "$F" >/dev/null 2>&1; then
    ko "$JF : plus aucun appel d'apim_preflight sans palier" "aucun appel a 1 argument" "un appel a 1 argument subsiste"
  else
    ok "$JF : plus aucun appel d'apim_preflight sans palier"
  fi
  # Aucune copie residuelle : c'est la duplication que ce refactor supprime, et
  # c'est elle qui avait permis a un seul des deux fichiers de regresser.
  if grep -qF 'PF_MAX="${APIM_PREFLIGHT_TRIES:-60}"' "$F"; then
    ko "$JF : plus aucune copie du preflight dans le Jenkinsfile" "absente" "encore presente"
  else
    ok "$JF : plus aucune copie du preflight dans le Jenkinsfile"
  fi
done

# ---- bloc P1quater : LA LIB REELLE, PILOTEE (curl et sleep simules) ---------
# Les blocs precedents lisent le TEXTE de la lib (`contient`, `avant`) et en
# executent UN MORCEAU decoupe (les garde-fous de PF_MAX). Ni l'un ni l'autre ne
# dit ce que la FONCTION ENTIERE fait : quelle URL elle sonde, combien de fois,
# ce qu'elle imprime, et ce qu'elle rend. Ce bloc source la LIB REELLE et
# l'appelle, avec `curl` et `sleep` remplaces par des FONCTIONS du shell (donc
# visibles jusque dans les sous-shells de `$( )`, ou une commande externe ne
# serait pas interceptee).
#
# LA FORME D'APPEL DU PILOTE EST CELLE DES JENKINSFILE — `apim_preflight … ||
# RC=$?` — et ce n'est pas un detail : elle NEUTRALISE `set -e` dans tout le
# corps de la fonction (POSIX : membre non final d'une liste `||`). C'est
# precisement la condition dans laquelle les proprietes ci-dessous doivent
# tenir. Mesure du 2026-09-07 sous dash : `if ! f; then …; fi` neutralise
# `set -e` TOUT AUTANT que `f || exit 1` — seul l'appel NU le conserve. La
# fonction ne peut donc pas s'appuyer dessus, et chaque epreuve « une commande
# echoue au milieu » ci-dessous mesure exactement ca.
#
# CHAQUE PROPRIETE EST SUIVIE DE SA MUTATION (bloc P1quinquies) : la lib est
# recopiee, le garde-fou correspondant retire, et l'epreuve REJOUEE doit
# rougir. Une epreuve qu'aucune mutation ne fait tomber ne mesure rien.
cat > "$TMPD/pilote.sh" <<'PILOTE'
set -eu
: > "$PF_URLS"; echo 0 > "$PF_CNT"
# `curl` : journalise l'URL sondee (dernier argument) et rend le code voulu.
curl(){ for a in "$@"; do :; done; printf '%s\n' "$a" >> "$PF_URLS"; N=$(( $(cat "$PF_CNT") + 1 )); echo "$N" > "$PF_CNT"; printf '%s' "${PF_FAKE_CODE:-000}"; }
# `sleep` : instantane, et ECHOUE sur demande — c'est la commande « au milieu »
# du preflight dont l'echec ne doit plus passer inapercu.
sleep(){ if [ "${PF_SLEEP_FAILS:-0}" = 1 ]; then return 7; fi; return 0; }
. "$PF_LIB"
PF_RC=0
apim_preflight "$1" "$2" || PF_RC=$?
echo "RC=$PF_RC"
echo "CURLS=$(cat "$PF_CNT")"
sed 's/^/URL=/' "$PF_URLS" | sort -u
PILOTE

# <lib> <base> <palier> [VAR=val …] — rend la sortie complete (trace + RC= +
# CURLS= + URL=…). `env` et non un prefixe de fonction : POSIX laisse une
# affectation prefixant un APPEL DE FONCTION persister apres coup, ce qui
# contaminerait les epreuves suivantes.
pilote(){
  P_LIB="$1"; P_BASE="$2"; P_ENV="$3"; shift 3
  env PF_LIB="$P_LIB" PF_URLS="$TMPD/urls" PF_CNT="$TMPD/cnt2" "$@" \
      sh "$TMPD/pilote.sh" "$P_BASE" "$P_ENV" 2>&1
}
pf_val(){  printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }
pf_urls(){ printf '%s\n' "$1" | sed -n 's/^URL=//p' | tr '\n' ' ' | sed 's/ *$//'; }
pf_dit(){ printf '%s\n' "$3" | grep -qF -- "$2" && ok "$1" || ko "$1" "la trace dit [$2]" "elle ne le dit pas"; }
pf_tait(){ printf '%s\n' "$3" | grep -qF -- "$2" && ko "$1" "la trace NE dit PAS [$2]" "elle le dit" || ok "$1"; }

echo "== la LIB REELLE, PILOTEE : APIM_PREFLIGHT_URL est un GABARIT par palier =="
# LE DEFAUT FERME ICI. `APIM_PREFLIGHT_URL` est une valeur de SITE : posee en
# globale du controleur, elle vaut pour TOUS les builds — alors que la base
# reellement sondee est PAR PALIER. Avant le 2026-09-07 la lib ne substituait
# `__ENV__` NULLE PART (mesure : 0 occurrence dans le fichier) et, des que le
# knob etait pose, l'argument $1 que l'appelant avait pris la peine de resoudre
# etait IGNORE : un client multi-paliers sondait le meme palier depuis les
# quatre autres et lisait cinq environnements vivants la ou un seul l'etait.
O_DEV="$(pilote "$LIB" "https://apim-dev.corp/rest/apigateway"  dev  APIM_PREFLIGHT_URL='https://apim-__ENV__.corp/ping' APIM_PREFLIGHT_TRIES=1)"
O_PRD="$(pilote "$LIB" "https://apim-prod.corp/rest/apigateway" prod APIM_PREFLIGHT_URL='https://apim-__ENV__.corp/ping' APIM_PREFLIGHT_TRIES=1)"
U_DEV="$(pf_urls "$O_DEV")"; U_PRD="$(pf_urls "$O_PRD")"
cmp_ "gabarit + palier dev  => sonde l'URL du palier dev"  "https://apim-dev.corp/ping"  "$U_DEV"
cmp_ "gabarit + palier prod => sonde l'URL du palier prod" "https://apim-prod.corp/ping" "$U_PRD"
if [ "$U_DEV" != "$U_PRD" ]; then ok "  … donc DEUX paliers sondent DEUX URLs (le defaut ferme : plus de sonde unique pour tous)"
else ko "  … donc DEUX paliers sondent DEUX URLs" "des URLs differentes" "la MEME URL : $U_DEV"; fi
# Fail-closed : un gabarit dont personne ne nomme le palier n'est PAS sonde
# litteralement (dix minutes d'attente sur une URL qui n'existe nulle part,
# cause illisible) — il est REFUSE, et le refus nomme le 2e argument manquant.
O_NOENV="$(pilote "$LIB" "https://apim.corp/rest/apigateway" "" APIM_PREFLIGHT_URL='https://apim-__ENV__.corp/ping' APIM_PREFLIGHT_TRIES=1)"
cmp_ "gabarit SANS palier nomme => REFUS (rc 1)" "1" "$(pf_val RC "$O_NOENV")"
cmp_ "  … et ZERO sonde : le littéral __ENV__ n'est jamais joint" "0" "$(pf_val CURLS "$O_NOENV")"
pf_dit "  … et le refus nomme la cause (gabarit par palier, 2e argument)" \
  "porte encore __ENV__" "$O_NOENV"
# Une URL PLATE reste licite (une seule gateway pour tous les paliers, cas
# reel) — mais elle est DITE telle, sinon cinq paliers sondant la meme URL se
# relisent comme cinq paliers vivants.
O_PLATE="$(pilote "$LIB" "https://apim.corp/rest/apigateway" rec APIM_PREFLIGHT_URL='https://vip/ping' APIM_PREFLIGHT_TRIES=1)"
cmp_ "URL plate + palier => sondee telle quelle" "https://vip/ping" "$(pf_urls "$O_PLATE")"
pf_dit "  … et ANNONCEE comme sonde de site, pas comme sonde du palier" \
  "sonde de SITE, la même pour TOUS les paliers" "$O_PLATE"
# Sans le knob : la base RESOLUE PAR L'APPELANT (le palier pour le
# self-service, le self-proxy pour la publication) + /health. Inchange.
O_DEFAUT="$(pilote "$LIB" "https://apim-int.corp/rest/apigateway" int APIM_PREFLIGHT_TRIES=1)"
cmp_ "sans APIM_PREFLIGHT_URL => <base de l'appelant>/health" \
  "https://apim-int.corp/rest/apigateway/health" "$(pf_urls "$O_DEFAUT")"

echo "== la LIB REELLE, PILOTEE : la substitution n'appartient QU'AU gabarit =="
# LE DEFAUT FERME ICI, ET C'EST UN FAIL-OPEN DE LA MEME FAMILLE QUE LE
# PRECEDENT. Le `sed s/__ENV__/$PF_ENV/g` vivait HORS du `if [ -n "$PF_URL" ]` :
# il s'appliquait donc AUSSI a la branche par defaut `<base de l'appelant>/health`.
# Or l'arbitrage ne demandait la substitution QUE dans APIM_PREFLIGHT_URL — et
# la base d'admin de publish-api (APIM_API_BASE, composee de APIM_PROXY_BASE /
# APIM_PROXY_API) est une globale de SITE que RIEN ne resout par palier. La lib
# REPARAIT donc en silence une base qui aurait du etre REFUSEE (mesure du
# 2026-09-07 : base `https://apim-__ENV__.corp/…` + palier `rec` => sondait
# `https://apim-rec.corp/…`, vert), ou composait une URL fausse palier vide.
O_BASE="$(pilote "$LIB" 'https://apim-__ENV__.corp/rest/apigateway' rec APIM_PREFLIGHT_TRIES=1)"
cmp_ "base par defaut portant __ENV__ + palier nomme => REFUS (rc 1)" "1" "$(pf_val RC "$O_BASE")"
cmp_ "  … et ZERO sonde : la lib ne repare pas la base de l'appelant" "0" "$(pf_val CURLS "$O_BASE")"
pf_tait "  … et elle n'a PAS substitue le palier dans cette base (le fail-open ferme)" \
  "https://apim-rec.corp" "$O_BASE"
# Le meme defaut, palier VIDE : sans substitution possible, l'ancienne lib
# composait `…apim-__ENV__.corp/…/health` et le refusait — mais en accusant le
# mauvais coupable (cf. l'epreuve suivante).
O_BASE0="$(pilote "$LIB" 'https://apim-__ENV__.corp/rest/apigateway' "" APIM_PREFLIGHT_TRIES=1)"
cmp_ "base par defaut portant __ENV__ + palier VIDE => REFUS (rc 1)" "1" "$(pf_val RC "$O_BASE0")"

echo "== la LIB REELLE, PILOTEE : le refus nomme la VRAIE cause, pas un knob absent =="
# Le refus fail-closed disait « c'est un GABARIT PAR PALIER et l'appelant n'a
# pas nomme le palier » Y COMPRIS quand aucun APIM_PREFLIGHT_URL n'etait pose :
# il envoyait l'exploitant chercher un knob que personne n'avait mis, alors que
# la faute etait dans la base transmise. Les deux origines ont maintenant deux
# messages, et ils s'excluent.
pf_dit "base non resolue => le refus nomme LA BASE de l'appelant" \
  "base d'admin reçue de l'appelant" "$O_BASE0"
pf_tait "  … et n'accuse PAS un APIM_PREFLIGHT_URL que l'operateur n'a pas pose" \
  "est un GABARIT PAR PALIER et l'appelant n'a pas nommé le palier" "$O_BASE0"
pf_dit "knob pose sans palier => le refus nomme LE KNOB et le 2e argument" \
  "APIM_PREFLIGHT_URL est un GABARIT PAR PALIER et l'appelant n'a pas nommé le palier" "$O_NOENV"
pf_tait "  … et n'accuse PAS la base, que l'appelant a pourtant bien resolue" \
  "base d'admin reçue de l'appelant" "$O_NOENV"
# Le palier part dans une expression `sed` : un `/` l'y ferait eclater.
O_SALE="$(pilote "$LIB" "https://apim.corp/rest" "re/c" APIM_PREFLIGHT_URL='https://apim-__ENV__.corp/ping' APIM_PREFLIGHT_TRIES=1)"
cmp_ "palier hors classe (re/c) => REFUS avant toute sonde (rc 1)" "1" "$(pf_val RC "$O_SALE")"
cmp_ "  … et zero sonde" "0" "$(pf_val CURLS "$O_SALE")"

echo "== la LIB REELLE, PILOTEE : une commande qui ECHOUE AU MILIEU arrete le preflight =="
# `set -e` est neutralise dans le corps par la forme d'appel (mesure ci-dessus).
# Un `sleep` mort — conteneur sans coreutils, signal — laissait donc la boucle
# tourner PF_MAX fois a pleine vitesse : le preflight devenait un COMPTEUR, plus
# une attente, et rien ne le disait. Il doit s'arreter au PREMIER echec.
O_SLEEP="$(pilote "$LIB" "http://gw/rest/apigateway" dev PF_SLEEP_FAILS=1 APIM_PREFLIGHT_TRIES=5)"
cmp_ "sleep en echec au 1er tour => l'etape s'arrete (rc 1)" "1" "$(pf_val RC "$O_SLEEP")"
cmp_ "  … APRES UN SEUL essai, pas apres les 5 (la boucle ne tourne pas a vide)" "1" "$(pf_val CURLS "$O_SLEEP")"
pf_dit "  … et la cause est nommee, pas deduite" "l'attente entre deux essais a échoué" "$O_SLEEP"

echo "== la LIB REELLE, PILOTEE : la duree annoncee compte AUSSI le timeout du curl =="
# `$((PF_MAX*5))` ne comptait que les `sleep 5` et oubliait le `-m 5` du curl.
# Or le mode de panne vise est celui ou l'hote NE REPOND PAS : le curl consomme
# son timeout ENTIER. 60 essais valent donc jusqu'a ~600 s, pas 300.
O_DUREE="$(pilote "$LIB" "http://gw/rest/apigateway" dev APIM_PREFLIGHT_TRIES=60 PF_SLEEP_FAILS=1)"
pf_dit "60 essais => la trace annonce ~600s (5s de curl + 5s d'attente par essai)" \
  "max 60 essais — jusqu'à ~600s" "$O_DUREE"
pf_tait "  … et n'annonce plus 300s (le chiffre faux d'un facteur 2)" \
  "max 60 essais — jusqu'à ~300s" "$O_DUREE"
O_EPUISE="$(pilote "$LIB" "http://gw/rest/apigateway" dev APIM_PREFLIGHT_TRIES=2)"
pf_dit "  … et l'echec d'epuisement annonce le meme majorant" \
  "après 2 essais / jusqu'à ~20s" "$O_EPUISE"

echo "== la LIB REELLE, PILOTEE : APIM_PREFLIGHT=off garde le MARQUEUR de preuve =="
# `off` est LE remede prescrit au client, et des preuves du depot s'ancrent sur
# `préflight de joignabilité :` (scripts/test-a{3,4,5,7}-live.sh, ADR-082). Le
# chemin desactive n'imprimait plus ce marqueur : la preuve ne pouvait plus
# distinguer « desactive » de « jamais atteint » — deux etats opposes.
for V in off Off OFF; do
  O_OFF="$(pilote "$LIB" "http://gw/rest/apigateway" dev APIM_PREFLIGHT="$V" APIM_PREFLIGHT_TRIES=1)"
  cmp_ "APIM_PREFLIGHT=$V => passe (rc 0)" "0" "$(pf_val RC "$O_OFF")"
  cmp_ "  … sans sonder" "0" "$(pf_val CURLS "$O_OFF")"
  pf_dit "  … et la ligne porte LE MEME marqueur que le chemin actif" \
    "préflight de joignabilité :" "$O_OFF"
  pf_dit "  … et dit clairement qu'il est desactive" "DÉSACTIVÉ (APIM_PREFLIGHT=off)" "$O_OFF"
done

# ---- bloc P1quinquies : LES MUTATIONS ---------------------------------------
# Chaque garde-fou ferme ci-dessus est RETIRE d'une copie de la lib, et
# l'epreuve correspondante rejouee sur le mutant : elle DOIT rougir. Sans ce
# bloc, rien ne distingue une epreuve qui mesure d'une epreuve qui passe.
echo "== MUTATIONS : chaque epreuve ci-dessus rougit quand son garde-fou disparait =="
mordu(){ # <mutant> <ce que la mutation retire> — une mutation sans effet est un test faux
  # `if` et non `cmp … && fatal` : sous `set -e`, une liste `&&` dont le membre
  # gauche echoue rend 1, et c'est le harnais entier qui meurt en silence.
  if cmp -s "$LIB" "$1"; then
    fatal "mutation sans effet ($2) : le texte de la lib a bouge, l'ancre ne mord plus — le test ne peut rien affirmer"
  fi
}

# M1 — le refus fail-closed du gabarit non substitue neutralise : la lib sonde
#      alors le litteral __ENV__ au lieu de nommer la cause.
awk '/porte encore __ENV__/{print; if ((getline l) > 0) { sub(/return 1 ;;/, ": ;;", l); print l } next} {print}' "$LIB" > "$TMPD/m1.sh"
mordu "$TMPD/m1.sh" "refus du gabarit non substitue"
O_M1="$(pilote "$TMPD/m1.sh" "https://apim.corp/rest" "" APIM_PREFLIGHT_URL='https://apim-__ENV__.corp/ping' APIM_PREFLIGHT_TRIES=1)"
if [ "$(pf_val CURLS "$O_M1")" = "0" ]; then
  ko "M1 refus retire => l'epreuve « gabarit sans palier : zero sonde » rougit" "elle rougit" "elle passe encore (mutant vert)"
else ok "M1 refus retire => l'epreuve « gabarit sans palier : zero sonde » rougit (le mutant sonde [$(pf_urls "$O_M1")])"; fi

# M2 — L'ETAT D'AVANT, RECONSTITUE : la substitution de __ENV__ retiree EN PLUS
#      du refus (M1). C'est exactement la lib du 2026-09-07 au matin — zero
#      occurrence de __ENV__, knob absolu. Le mutant doit alors sonder LA MEME
#      URL depuis DEUX paliers differents : le fail-open mesure, reproduit.
sed 's|__ENV__/\$PF_ENV|__ENV__/__ENV__|' "$TMPD/m1.sh" > "$TMPD/m2.sh"
if cmp -s "$TMPD/m1.sh" "$TMPD/m2.sh"; then
  fatal "mutation sans effet (substitution de __ENV__) : l'ancre ne mord plus — le test ne peut rien affirmer"
fi
M2D="$(pf_urls "$(pilote "$TMPD/m2.sh" "https://apim-dev.corp/rest"  dev  APIM_PREFLIGHT_URL='https://apim-__ENV__.corp/ping' APIM_PREFLIGHT_TRIES=1)")"
M2P="$(pf_urls "$(pilote "$TMPD/m2.sh" "https://apim-prod.corp/rest" prod APIM_PREFLIGHT_URL='https://apim-__ENV__.corp/ping' APIM_PREFLIGHT_TRIES=1)")"
if [ "$M2D" != "$M2P" ]; then
  ko "M2 substitution retiree => l'epreuve « deux paliers, deux URLs » rougit" "elle rougit" "le mutant sonde encore deux URLs distinctes"
else ok "M2 substitution retiree => l'epreuve « deux paliers, deux URLs » rougit (dev et prod sondent tous deux [$M2D])"; fi

# M3 — le controle de rc du `sleep` retire : la boucle repart, `set -e` etant
#      neutralise par la forme d'appel.
awk '
  /^[[:space:]]*sleep 5 \|\| \{/ { print "    sleep 5 || true"; skip=1; next }
  skip && /^[[:space:]]*\}$/     { skip=0; next }
  skip                           { next }
                                 { print }
' "$LIB" > "$TMPD/m3.sh"
mordu "$TMPD/m3.sh" "controle de rc du sleep"
O_M3="$(pilote "$TMPD/m3.sh" "http://gw/rest/apigateway" dev PF_SLEEP_FAILS=1 APIM_PREFLIGHT_TRIES=5)"
if [ "$(pf_val CURLS "$O_M3")" = "1" ]; then
  ko "M3 controle du sleep retire => l'epreuve « arret au 1er echec » rougit" "elle rougit" "elle passe encore (mutant vert)"
else ok "M3 controle du sleep retire => l'epreuve « arret au 1er echec » rougit (le mutant boucle : $(pf_val CURLS "$O_M3") essais)"; fi

# M4 — la duree annoncee remise a *5 (le chiffre faux d'un facteur 2).
awk '/codes attendus/{gsub(/PF_MAX\*10/, "PF_MAX*5")} {print}' "$LIB" > "$TMPD/m4.sh"
mordu "$TMPD/m4.sh" "duree annoncee *10"
O_M4="$(pilote "$TMPD/m4.sh" "http://gw/rest/apigateway" dev APIM_PREFLIGHT_TRIES=60 PF_SLEEP_FAILS=1)"
if printf '%s\n' "$O_M4" | grep -qF -- "max 60 essais — jusqu'à ~600s"; then
  ko "M4 duree remise a *5 => l'epreuve « ~600s » rougit" "elle rougit" "elle passe encore (mutant vert)"
else ok "M4 duree remise a *5 => l'epreuve « ~600s » rougit (le mutant annonce ~300s)"; fi

# M5 — le marqueur retire du chemin desactive.
sed 's/préflight de joignabilité : DÉSACTIVÉ/préflight désactivé/' "$LIB" > "$TMPD/m5.sh"
mordu "$TMPD/m5.sh" "marqueur du chemin desactive"
O_M5="$(pilote "$TMPD/m5.sh" "http://gw/rest/apigateway" dev APIM_PREFLIGHT=off APIM_PREFLIGHT_TRIES=1)"
if printf '%s\n' "$O_M5" | grep -qF -- "préflight de joignabilité :"; then
  ko "M5 marqueur retire => l'epreuve « off garde le marqueur » rougit" "elle rougit" "elle passe encore (mutant vert)"
else ok "M5 marqueur retire => l'epreuve « off garde le marqueur » rougit"; fi

# M6 — L'ETAT D'AVANT, RECONSTITUE : la substitution rendue a la branche PAR
#      DEFAUT, c'est-a-dire `sed` applique HORS du `if [ -n "$PF_URL" ]`. Le
#      mutant « repare » alors la base de l'appelant au lieu de la refuser :
#      c'est le fail-open mesure le 2026-09-07, reproduit ici.
awk '
  /^[[:space:]]*PF_URL="\$APIM_PREFLIGHT_BASE\/health"$/ {
    print "    PF_URL=\"$(printf %s \"$APIM_PREFLIGHT_BASE/health\" | sed \"s/__ENV__/$PF_ENV/g\")\""
    next
  }
  { print }
' "$LIB" > "$TMPD/m6.sh"
mordu "$TMPD/m6.sh" "substitution confinee au gabarit"
O_M6="$(pilote "$TMPD/m6.sh" 'https://apim-__ENV__.corp/rest/apigateway' rec APIM_PREFLIGHT_TRIES=1)"
if [ "$(pf_val CURLS "$O_M6")" = "0" ]; then
  ko "M6 substitution rendue a la base => l'epreuve « la lib ne repare pas la base » rougit" \
     "elle rougit" "elle passe encore (mutant vert)"
else ok "M6 substitution rendue a la base => l'epreuve « la lib ne repare pas la base » rougit (le mutant sonde [$(pf_urls "$O_M6")])"; fi

# M7 — le refus rendu a son message UNIQUE : la branche « base de l'appelant »
#      reprend le texte qui accuse APIM_PREFLIGHT_URL. C'est l'etat d'avant, ou
#      le refus envoyait chercher un knob que personne n'avait pose.
#      Regex sans apostrophe litterale (le programme awk est en quotes simples) :
#      `.` couvre les apostrophes de « c'est » et « d'admin ».
awk '/^[[:space:]]*PF_POURQUOI="c.est la base d.admin/ {
       print "    PF_POURQUOI=\"APIM_PREFLIGHT_URL est un GABARIT PAR PALIER et l\047appelant n\047a pas nommé le palier (2e argument d\047apim_preflight)\""
       next
     }
     { print }' "$LIB" > "$TMPD/m7.sh"
mordu "$TMPD/m7.sh" "message de refus propre a la base"
O_M7="$(pilote "$TMPD/m7.sh" 'https://apim-__ENV__.corp/rest/apigateway' "" APIM_PREFLIGHT_TRIES=1)"
if printf '%s\n' "$O_M7" | grep -qF -- "base d'admin reçue de l'appelant"; then
  ko "M7 message unique restaure => l'epreuve « le refus nomme LA BASE » rougit" \
     "elle rougit" "elle passe encore (mutant vert)"
else ok "M7 message unique restaure => l'epreuve « le refus nomme LA BASE » rougit (le mutant accuse le knob absent)"; fi

# M8 — LE CABLAGE, COMMENTE. Les deux assertions de cablage utilisaient
#      `contient` (= `grep -qF` NON ANCRE) : un appel COMMENTE les satisfaisait,
#      le texte etant present et le preflight mort. C'est la panne 5d34299 sous
#      sa forme « commentee », que ces assertions sont precisement censees
#      attraper. Ce bloc mute CHAQUE Jenkinsfile et verifie DEUX choses :
#      l'ancien predicat reste vert (le defaut, reproduit) et le nouveau rougit.
for JF in $JENKINSFILES; do
  F="$POC/ci/$JF"
  A="$(appel_attendu "$JF")"
  sed 's|^\([[:space:]]*\)\(\. ci/lib/preflight\.sh\)$|\1# \2|; s|^\([[:space:]]*\)\(apim_preflight .*\)$|\1# \2|' \
    "$F" > "$TMPD/m8-$JF"
  if cmp -s "$F" "$TMPD/m8-$JF"; then
    fatal "mutation sans effet (cablage commente dans $JF) : l'ancre ne mord plus — le test ne peut rien affirmer"
  fi
  # Le DEFAUT, reproduit : sans ancrage, le mutant passe. Si cette ligne
  # rougissait, c'est que `grep -qF` n'etait pas le fail-open decrit — et
  # l'epreuve suivante ne prouverait plus rien de nouveau.
  if grep -qF -- "$A" "$TMPD/m8-$JF"; then
    ok "M8 $JF commente : l'ANCIEN predicat (grep -qF nu) reste vert — le fail-open, reproduit"
  else
    ko "M8 $JF commente : l'ANCIEN predicat reste vert" "vert (fail-open reproduit)" "il rougit deja"
  fi
  # LA PROPRIETE : le predicat ancre, lui, rougit sur les DEUX lignes.
  if actif_dans '. ci/lib/preflight.sh' "$TMPD/m8-$JF"; then
    ko "M8 $JF commente => l'epreuve « source la lib (ligne NON commentee) » rougit" \
       "elle rougit" "elle passe encore (mutant vert)"
  else ok "M8 $JF commente => l'epreuve « source la lib (ligne NON commentee) » rougit"; fi
  if actif_dans "$A" "$TMPD/m8-$JF"; then
    ko "M8 $JF commente => l'epreuve « appelle apim_preflight (ligne NON commentee) » rougit" \
       "elle rougit" "elle passe encore (mutant vert)"
  else ok "M8 $JF commente => l'epreuve « appelle apim_preflight (ligne NON commentee) » rougit"; fi
done


# ---- bloc P2 : preflight, comportement (copie conforme, curl simule) ----
# Le compteur passe par FICHIER : curl est appele dans $( ), donc dans un
# sous-shell, ou une variable ne survivrait pas (piege du premier jet).
CURL_SEQ=""; CNT="$TMPD/cnt"
curl(){
  N=$(( $(cat $CNT 2>/dev/null || echo 0) + 1 )); echo "$N" > $CNT
  printf '%s' "$(echo "$CURL_SEQ" | cut -d, -f$N)"
}

# Normalisation de PF_MAX — rejeu du bloc de garde-fous du Jenkinsfile, ISOLE
# dans sa propre fonction pour que le BORNAGE puisse etre verifie sur la
# VALEUR obtenue, sans payer PF_MAX tours de boucle. Jouer reellement la borne
# haute coutait a lui seul ~34 s des 36 s du banc (2 cas x 3600 tours, chaque
# tour forkant le curl simule) : inacceptable pour un banc joue a chaque build.
# Ce n'est PAS un affaiblissement, parce que la preuve se decompose en deux
# proprietes verifiees separement :
#   (a) la VALEUR : 10^20 et 4000 deviennent 3600 — verifie ici, en O(1) ;
#   (b) la BOUCLE sort a EXACTEMENT PF_MAX tours — verifie quantitativement
#       plus bas par comptage des appels curl (cas 2, 3, 5, et 60 pour
#       'abc'/'0'/'-3'/'08'/'060').
# Le bloc REEL des deux Jenkinsfile est en outre extrait et EXECUTE plus haut
# (« valeurs adverses, bloc REEL extrait et EXECUTE ») sur les memes valeurs
# adverses, y compris la decidabilite de `[ "$i" -ge "$PF_MAX" ]` aux deux
# bornes — ce rejeu ne peut donc pas diverger du fichier en silence.
# L'avertissement est rejoue lui aussi (sur stderr, pour ne pas polluer la
# valeur capturee par `$(preflight)` que les assertions comparent) — sans lui,
# le harnais ne verifierait jamais que ce chemin s'execute reellement.
normalise_pf_max(){
  PF_MAX="$1"
  case "$PF_MAX" in
    ''|*[!0-9]*|0*)
      printf "  ⚠ APIM_PREFLIGHT_TRIES='%s' n'est pas un entier positif — repli sur le défaut (60)\n" "$PF_MAX" >&2
      PF_MAX=60
      ;;
  esac
  # Borne haute rejouee ici aussi (longueur AVANT arithmetique, cf. Jenkinsfile) —
  # sans elle, le harnais ne verifierait jamais qu'une valeur enorme est bornee.
  case "$PF_MAX" in
    ?????*)
      printf "  ⚠ APIM_PREFLIGHT_TRIES='%s' dépasse la borne raisonnable — repli sur 3600\n" "$PF_MAX" >&2
      PF_MAX=3600
      ;;
  esac
  if [ "$PF_MAX" -gt 3600 ]; then
    printf "  ⚠ APIM_PREFLIGHT_TRIES='%s' dépasse la borne raisonnable — repli sur 3600\n" "$PF_MAX" >&2
    PF_MAX=3600
  fi
}

preflight(){
  echo 0 > $CNT
  APIM_API_BASE="http://gw/rest/apigateway"
  APIM_PREFLIGHT_LC="$(printf '%s' "${APIM_PREFLIGHT:-on}" | tr '[:upper:]' '[:lower:]')"
  if [ "$APIM_PREFLIGHT_LC" = "off" ]; then
    echo "SKIP"; return 0
  fi
  PF_URL="${APIM_PREFLIGHT_URL:-}"
  [ -n "$PF_URL" ] || PF_URL="$APIM_API_BASE/health"
  PF_CODES="${APIM_PREFLIGHT_CODES:-200 401}"
  normalise_pf_max "${APIM_PREFLIGHT_TRIES:-60}"
  i=0
  while :; do
    HC="$(curl || true)"
    for C in $PF_CODES; do
      if [ "$HC" = "$C" ]; then break 2; fi
    done
    i=$((i+1))
    # `$((PF_MAX*10))` rejoue ICI aussi : c'est cette arithmetique precise qui,
    # sur la vraie lib, casse sur une valeur en tete de zero non filtree (piege
    # octal) — sans elle, le harnais resterait vert alors que le bloc reel meurt
    # sur un message cryptique. *10 et non *5 depuis le 2026-09-07 : un essai
    # coute le timeout du curl (5 s) PUIS l'attente (5 s), cf. la lib.
    if [ "$i" -ge "$PF_MAX" ]; then echo "FAIL:$PF_URL:$HC:apres ~$((PF_MAX*10))s"; return 1; fi
    if [ "$i" -eq 1 ]; then :; fi
  done
  echo "UP:$PF_URL:apres $i tentative(s)"
}

echo "== preflight =="
unset APIM_PREFLIGHT APIM_PREFLIGHT_URL APIM_PREFLIGHT_CODES APIM_PREFLIGHT_TRIES 2>/dev/null || true

CURL_SEQ="200"
cmp_ "200 direct => passe" "UP:http://gw/rest/apigateway/health:apres 0 tentative(s)" "$(preflight)"

CURL_SEQ="401"
cmp_ "401 (proxy OAuth2 enforce) => preuve de vie" \
  "UP:http://gw/rest/apigateway/health:apres 0 tentative(s)" "$(preflight)"

CURL_SEQ="000,000,200"; APIM_PREFLIGHT_TRIES=5
cmp_ "gateway qui revient au 3e essai" \
  "UP:http://gw/rest/apigateway/health:apres 2 tentative(s)" "$(preflight)"
unset APIM_PREFLIGHT_TRIES

CURL_SEQ="000,000,000"; APIM_PREFLIGHT_TRIES=3
R="$(preflight || true)"
cmp_ "epuisement => echec explicite" "FAIL:http://gw/rest/apigateway/health:000:apres ~30s" "$R"
if ( CURL_SEQ="000,000,000"; APIM_PREFLIGHT_TRIES=3; preflight >/dev/null 2>&1 ); then
  ko "epuisement => code retour non nul" "!=0" "0"; else ok "epuisement => code retour non nul"; fi
unset APIM_PREFLIGHT_TRIES

# APIM_PREFLIGHT_TRIES non numerique : preuve QUANTITATIVE de non-bouclage —
# pas seulement « ca finit par sortir », mais « ca sort au bout d'exactement
# PF_MAX(=60, le defaut) appels curl », donc borne et pas un hasard de sequence.
CURL_SEQ="000"; APIM_PREFLIGHT_TRIES="abc"
R="$(preflight || true)"
cmp_ "APIM_PREFLIGHT_TRIES='abc' => ne boucle plus a l'infini (replie sur 60)" \
  "FAIL:http://gw/rest/apigateway/health:000:apres ~600s" "$R"
cmp_ "  … et le nombre d'essais reellement effectues est borne au defaut (60)" "60" "$(cat "$CNT")"
unset APIM_PREFLIGHT_TRIES

CURL_SEQ="000"; APIM_PREFLIGHT_TRIES="0"
preflight >/dev/null || true
cmp_ "APIM_PREFLIGHT_TRIES=0 n'est pas un entier POSITIF => replie aussi sur 60" "60" "$(cat "$CNT")"
unset APIM_PREFLIGHT_TRIES

CURL_SEQ="000"; APIM_PREFLIGHT_TRIES="-3"
preflight >/dev/null || true
cmp_ "APIM_PREFLIGHT_TRIES negatif => replie aussi sur 60" "60" "$(cat "$CNT")"
unset APIM_PREFLIGHT_TRIES

# Zero EN TETE : passe le filtre "que des chiffres" mais casse `$((PF_MAX*10))`
# sur le vrai Jenkinsfile (interpretation octale, "08" n'existe pas en base
# 8). C'est le cas precis remonte en revue — non couvert par les cas 'abc'/
# '0'/'-3' ci-dessus, qui ne passent pas ce filtre-la.
CURL_SEQ="000"; APIM_PREFLIGHT_TRIES="08"
preflight >/dev/null || true
cmp_ "APIM_PREFLIGHT_TRIES='08' (zero en tete, piege octal) => replie aussi sur 60" "60" "$(cat "$CNT")"
unset APIM_PREFLIGHT_TRIES

CURL_SEQ="000"; APIM_PREFLIGHT_TRIES="060"
preflight >/dev/null || true
cmp_ "APIM_PREFLIGHT_TRIES='060' (zero en tete) => replie aussi sur 60" "60" "$(cat "$CNT")"
unset APIM_PREFLIGHT_TRIES

# Valeur ENORME mais purement numerique : passe le premier garde-fou et
# rouvrirait le meme mode de panne (boucle non bornee en pratique, aucun
# timeout de build pose dans les job XML) sans la borne haute.
# On mesure ici la VALEUR bornee, pas 3600 tours de boucle (cf. le commentaire
# de `normalise_pf_max`) : les tours coutaient ~17 s par cas.
normalise_pf_max "99999999999999999999" 2>"$TMPD/warn"
cmp_ "APIM_PREFLIGHT_TRIES enorme => bornee a 3600, pas une boucle non bornee" "3600" "$PF_MAX"
cmp_ "  … et \$((PF_MAX*10)) du message de sortie reste calculable" "36000" "$((PF_MAX*10))"
contient "  … et le bornage est annonce, pas silencieux" 'dépasse la borne raisonnable' "$TMPD/warn"
# La boucle sort a EXACTEMENT PF_MAX tours : faux (et DECIDABLE, rc=1) avant
# la borne, vrai (rc=0) a la borne. C'est cette decidabilite qui manquait —
# `-ge` contre un non-entier rend 2, et `if` traite 2 comme faux : sortie
# jamais prise. Verifie aussi sur le texte REEL au bloc 1ter.
RCLO=0; [ 0 -ge "$PF_MAX" ] || RCLO=$?
RCHI=0; [ "$PF_MAX" -ge "$PF_MAX" ] || RCHI=$?
cmp_ "  … la sortie de boucle est DECIDABLE avant la borne (faux, rc=1, jamais 2)" "1" "$RCLO"
cmp_ "  … et se declenche A la borne (vrai, rc=0)" "0" "$RCHI"

# Valeur numerique raisonnable en apparence (4 chiffres) mais > 3600 : prend
# le chemin `-gt 3600` (pas le filtre de longueur "5 chiffres ou plus").
normalise_pf_max "4000" 2>"$TMPD/warn"
cmp_ "APIM_PREFLIGHT_TRIES=4000 (4 chiffres, > 3600) => borne aussi sur 3600" "3600" "$PF_MAX"
contient "  … par le chemin arithmetique -gt 3600, avec avertissement" 'dépasse la borne raisonnable' "$TMPD/warn"

APIM_PREFLIGHT=off
cmp_ "APIM_PREFLIGHT=off => saute, ne sonde pas" "SKIP" "$(preflight)"
unset APIM_PREFLIGHT

APIM_PREFLIGHT=Off
cmp_ "APIM_PREFLIGHT=Off (casse mixte) => desactive aussi, insensible a la casse" "SKIP" "$(preflight)"
unset APIM_PREFLIGHT

APIM_PREFLIGHT=OFF
cmp_ "APIM_PREFLIGHT=OFF (tout majuscule) => desactive aussi" "SKIP" "$(preflight)"
unset APIM_PREFLIGHT

CURL_SEQ="204"; APIM_PREFLIGHT_URL="https://vip/ping"; APIM_PREFLIGHT_CODES="204 200"
cmp_ "sonde de vie alternative + codes personnalises" \
  "UP:https://vip/ping:apres 0 tentative(s)" "$(preflight)"
unset APIM_PREFLIGHT_URL APIM_PREFLIGHT_CODES

CURL_SEQ="503"; APIM_PREFLIGHT_TRIES=2
R="$(preflight || true)"
cmp_ "code non attendu => n'est PAS pris pour une preuve de vie" \
  "FAIL:http://gw/rest/apigateway/health:503:apres ~20s" "$R"

# ---- bloc P3 : LA DECOUVERTE DES KNOBS -------------------------------------
# Un knob que personne ne peut trouver n'existe pas. Les quatre knobs du
# preflight sont le REMEDE prescrit au client : ils doivent etre lisibles LA ou
# l'integrateur regarde — `scripts/setup-jenkins-globals.sh --help` — et non
# seulement dans le code. Mesure du 2026-09-07 : l'aide repondait par
# `sed -n '1,50p' "$0"` (un compte de lignes EN DUR) et la documentation des
# knobs venait d'etre inseree aux lignes 58-77 : elle etait donc INVISIBLE. Et
# l'aide exigeait JENKINS_UI pour s'afficher — or c'est justement l'integrateur
# qui n'a encore RIEN pose qui la lit.
GLOBALS="$POC/scripts/setup-jenkins-globals.sh"
DOC="$POC/ENVIRONNEMENTS.md"
[ -f "$GLOBALS" ] || fatal "$GLOBALS introuvable"
[ -f "$DOC" ] || fatal "$DOC introuvable"
echo "== la DECOUVERTE des knobs : \`setup-jenkins-globals.sh --help\` les nomme =="
AIDE_RC=0
AIDE="$(env -u JENKINS_UI bash "$GLOBALS" --help 2>&1)" || AIDE_RC=$?
cmp_ "--help repond SANS JENKINS_UI (l'integrateur n'a encore rien pose)" "0" "$AIDE_RC"
for K in APIM_PREFLIGHT APIM_PREFLIGHT_URL APIM_PREFLIGHT_CODES APIM_PREFLIGHT_TRIES; do
  pf_dit "--help nomme $K" "$K" "$AIDE"
done
pf_dit "--help dit que APIM_PREFLIGHT_URL est un GABARIT par palier" "GABARIT PAR PALIER" "$AIDE"
pf_dit "  … et montre __ENV__" "__ENV__" "$AIDE"
# La CONFINEMENT de la substitution est ce qui distingue « la lib resout » de
# « l'appelant resout ». Un exploitant qui lit l'inverse pose une base gabarit
# en globale de SITE et s'attend a ce qu'elle soit reparee : elle sera refusee.
pf_dit "  … et que la substitution ne vaut QUE pour ce knob (la base n'est pas reparee)" \
  "LA SUBSTITUTION VAUT POUR CE KNOB, ET POUR LUI" "$AIDE"
pf_dit "--help dit la duree REELLE d'un essai (10 s, pas 5)" "JUSQU'À 10 s, pas 5" "$AIDE"
# Aucun compte de lignes en dur : c'est LUI qui a rendu la doc invisible.
if grep -nE "sed -n '1,[0-9]+p' \"\\\$0\"" "$GLOBALS" >/dev/null 2>&1; then
  ko "setup-jenkins-globals.sh : l'aide ne repose plus sur un compte de lignes en dur" \
     "aucun sed -n '1,Np' \"\$0\"" "il en reste un"
else
  ok "setup-jenkins-globals.sh : l'aide ne repose plus sur un compte de lignes en dur"
fi
echo "== la DECOUVERTE des knobs : ENVIRONNEMENTS.md dit la meme chose =="
contient "ENVIRONNEMENTS.md : APIM_PREFLIGHT_URL y est un GABARIT par palier" \
  "C'est un GABARIT par palier, pas une URL plate" "$DOC"
contient "ENVIRONNEMENTS.md : la duree annoncee est ~10 minutes, plus 5" \
  "jusqu'à ~10 minutes" "$DOC"
contient "ENVIRONNEMENTS.md : le chemin desactive garde le marqueur" \
  "préflight de joignabilité : DÉSACTIVÉ" "$DOC"
contient "ENVIRONNEMENTS.md : la substitution n'appartient QU'au knob (la base n'est pas reparee)" \
  'La substitution n'"'"'appartient QU'"'"'à `APIM_PREFLIGHT_URL`' "$DOC"

# MUTATION M9 — l'aide remise a un compte de lignes en dur : la documentation
# des knobs retombe hors fenetre, exactement comme le 2026-09-07 au matin.
sed 's|^aide(){ awk .*|aide(){ sed -n "1,50p" "$0"; }|' "$GLOBALS" > "$TMPD/m9.sh"
if cmp -s "$GLOBALS" "$TMPD/m9.sh"; then
  fatal "mutation sans effet (aide par compte de lignes) : l'ancre ne mord plus — le test ne peut rien affirmer"
fi
M9="$(env -u JENKINS_UI bash "$TMPD/m9.sh" --help 2>&1 || true)"
if printf '%s\n' "$M9" | grep -qF -- "APIM_PREFLIGHT_URL"; then
  ko "M9 aide remise a \`sed -n '1,50p'\` => l'epreuve « --help nomme les knobs » rougit" \
     "elle rougit" "elle passe encore (mutant vert)"
else
  ok "M9 aide remise a \`sed -n '1,50p'\` => l'epreuve « --help nomme les knobs » rougit (le mutant tait les quatre knobs)"
fi

# Verdict INTERMEDIAIRE du preflight : le bloc proxy qui suit peut s'arreter en
# `fatal` (voir son entete), et le verdict final ne serait alors jamais imprime.
# On rend donc ici, explicitement, l'etat de la moitie « preflight ».
echo
if [ "$KO" -eq 0 ]; then echo "-- PREFLIGHT : TOUT PASSE --"; else echo "-- PREFLIGHT : $KO ECHEC(S) --"; fi

# ── STOA_PREFLIGHT_ONLY : LA MOITIE QUI TOURNE SOUS `make lint-ci` ───────────
# L'ARBITRAGE, ECRIT ICI PARCE QU'IL SE RELIT ICI (2026-09-07).
# Jusqu'a ce jour, RIEN n'appelait ce harnais — ni le Makefile, ni lint-ci, ni
# un Jenkinsfile (mesure : `grep -rn test-proxy-base-et-preflight Makefile ci/
# scripts/` ne rendait qu'un commentaire). Les six assertions de CABLAGE qui
# « auraient attrape 5d34299 » ne pouvaient donc rien attraper : elles ne
# s'executaient jamais.
#
# Le brancher EN ENTIER sous `make lint-ci` casserait la porte du depot : le
# bloc PROXY ci-dessous compte 5 KO RESIDUELS, ETRANGERS au preflight
# (Jenkinsfile.publish-api a perdu la description du proxy PAR MORCEAUX au meme
# merge 5d34299 ; Jenkinsfile.selfservice a DEPLACE la composition vers
# scripts/selfservice-palier-gate.sh en A3). Les fermer exigerait DEUX nouveaux
# defauts de site (APIM_PROXY_HOST T1, APIM_PROXY_PATH T3) que
# ci/lint-config-knobs.exempt interdit d'ajouter — c'est un arbitrage a rendre,
# pas une ligne a ecrire.
#
# TRANCHE : `make lint-ci` branche la moitie PREFLIGHT + CABLAGE — celle dont
# le defaut est ferme, et celle qui aurait attrape la regression. Le bloc PROXY
# reste NON BRANCHE et se joue a la main (`sh ci/test-proxy-base-et-preflight.sh`
# sans le knob) : il est ROUGE, et ce rouge est DIT — dans l'entete de sa
# boucle, dans la cible du Makefile, et dans le rendu du chantier. On ne masque
# pas un rouge pour faire passer une porte ; on nomme ce qui n'est pas branche,
# et pourquoi.
if [ -n "${STOA_PREFLIGHT_ONLY:-}" ]; then
  echo "   (STOA_PREFLIGHT_ONLY : le bloc PROXY n'est pas joue — 5 KO residuels connus, arbitrage ouvert, cf. l'entete de sa boucle)"
  [ "$KO" -eq 0 ] || exit 1
  exit 0
fi


# Commit de base : le dernier commit de l'historique de HEAD ou le
# Jenkinsfile porte ENCORE un defaut APIM_PROXY_BASE NON VIDE — par
# construction, l'etat d'AVANT la proxification par morceaux. STOA_BASE_REF
# reste l'echappatoire explicite (poser n'importe quelle ref).
#
# Pourquoi PAS une derivation par branche (`merge-base` avec origin/main) :
# le job reel vise `*/main`, et le plugin Git y place HEAD EXACTEMENT sur le
# commit d'origin/main — donc merge-base(HEAD, origin/main) == HEAD. Relire
# le Jenkinsfile a ce point relit alors le fichier COURANT (deja decompose,
# defaut VIDE) : la comparaison « compose() == ancien defaut » devient
# « compose() == '' », ce qui n'est jamais vrai. Mesure sur depot jetable :
# main sain et main sabote rendent tous deux 4 ECHEC(S) — verdict IDENTIQUE,
# donc PAS un faux vert, mais un FAUX ROUGE permanent des la fusion (pire :
# le SHA fige qu'on remplaçait, lui, survivait a la fusion — c'etait une
# regression). C'est precisement quand « cette branche descend de main »
# devient une EGALITE que ce mecanisme se degrade ; il est donc abandonne.
#
# Le defaut normal remonte au contraire l'historique du FICHIER lui-meme :
# identique sur main et sur une branche (aucune dependance a une topologie de
# branches), et resistant a une purge tant qu'un commit pre-refonte reste
# atteignable depuis HEAD — sans jamais figer un SHA particulier.
JF_REF="$SOUS_POC/ci/Jenkinsfile.publish-api"
BASE_REF="${STOA_BASE_REF:-}"
if [ -z "$BASE_REF" ]; then
  git -C "$RACINE" rev-list HEAD -- "$JF_REF" > "$TMPD/hist" 2>/dev/null || :
  while read -r C; do
    if git -C "$RACINE" show "$C:$JF_REF" 2>/dev/null \
       | sed -n "s/^[[:space:]]*APIM_PROXY_BASE[[:space:]]*=.*?:[[:space:]]*'\([^']\{1,\}\)'.*/\1/p" \
       | grep -q .; then BASE_REF="$C"; break; fi
  done < "$TMPD/hist"
fi
[ -n "$BASE_REF" ] || fatal "point de comparaison introuvable : aucun commit de l'historique de HEAD sur $JF_REF ne porte encore un defaut APIM_PROXY_BASE non vide (clone superficiel ? historique purge sans etat pre-refonte restant ?) — poser STOA_BASE_REF=<sha-ou-ref> explicitement pour rejouer le test."


# ---- l'ANCIEN defaut : relu dans le Jenkinsfile d'AVANT la branche --------
# Un SEUL fichier est relu dans l'historique : Jenkinsfile.publish-api. La
# boucle sur les DEUX Jenkinsfile plus bas confronte leurs defauts COURANTS a
# cette unique URL historique — ce qui est le contrat voulu (les deux doivent
# composer la MEME base qu'avant), mais n'est PAS « l'ancien defaut extrait de
# chaque Jenkinsfile » : si Jenkinsfile.selfservice avait un jour porte un
# autre defaut, ce test ne le saurait pas.
git -C "$RACINE" show "$BASE_REF:$SOUS_POC/ci/Jenkinsfile.publish-api" > "$TMPD/base.groovy" 2>/dev/null \
  || fatal "impossible de lire $BASE_REF:$SOUS_POC/ci/Jenkinsfile.publish-api (clone superficiel ? commit absent ?) — poser STOA_BASE_REF"
ANCIEN_DEFAUT="$(lire_defaut "$TMPD/base.groovy" APIM_PROXY_BASE)"
printf 'ancien defaut (%s) : %s\n\n' "$BASE_REF" "$ANCIEN_DEFAUT"
# Garde-fou de trivialite : interdit STRUCTURELLEMENT qu'un point de
# comparaison degenere (fichier deja decompose) produise un garde-fou
# decoratif — quel que soit le mecanisme de derivation utilise au-dessus.
[ -n "$ANCIEN_DEFAUT" ] || fatal "le point de comparaison $BASE_REF porte déjà la forme décomposée : la comparaison serait vide de sens — poser STOA_BASE_REF."

# ---- bloc 1 : composition de la base du proxy (copie conforme) ----
compose(){
  PROXY_BASE="${APIM_PROXY_BASE:-}"
  if [ -z "$PROXY_BASE" ]; then
    PROXY_BASE="${APIM_PROXY_HOST}/gateway/${APIM_PROXY_API}/${APIM_PROXY_VER}${APIM_PROXY_PATH}"
  fi
  printf '%s' "$PROXY_BASE"
}
# Les deux lignes que `compose()` transcrit. Comparees LITTERALEMENT a celles du
# Jenkinsfile : sans quoi la « copie conforme » peut diverger sans que rien ne
# le dise, et le reste du bloc ne mesurerait plus le pipeline reel.
COMPO_ATTENDUE='PROXY_BASE="${APIM_PROXY_HOST}/gateway/${APIM_PROXY_API}/${APIM_PROXY_VER}${APIM_PROXY_PATH}"'
OVERRIDE_ATTENDU='PROXY_BASE="${APIM_PROXY_BASE:-}"'

for JF in $JENKINSFILES; do
  F="$POC/ci/$JF"
  [ -f "$F" ] || fatal "$F introuvable"
  echo "== $JF : composition de la base proxy =="

  # ── CE BLOC SUPPOSE que le Jenkinsfile decrit le proxy d'admin PAR MORCEAUX.
  # Deux ecarts CONNUS au 2026-09-07, tous deux ETRANGERS au preflight :
  #   - Jenkinsfile.publish-api ne le decrit pas (APIM_PROXY_BASE entier) : le
  #     merge 5d34299 lui a rendu l'etat d'AVANT la proxification par morceaux.
  #     Le lui rendre exigerait deux nouveaux defauts de site (APIM_PROXY_HOST
  #     T1, APIM_PROXY_PATH T3) que ci/lint-config-knobs.exempt interdit
  #     d'ajouter (« ON N'Y AJOUTE JAMAIS DE LIGNE ») : c'est un arbitrage a
  #     rendre, pas une ligne a ecrire ;
  #   - Jenkinsfile.selfservice a DEPLACE la composition vers
  #     scripts/selfservice-palier-gate.sh (A3), et son APIM_PROXY_API vaut
  #     desormais wm-admin-__ENV__ et non plus wm-admin-self : les quatre KO
  #     qui suivent mesurent CE deplacement, pas une regression du jour.
  # On les COMPTE en rouge ; on ne MEURT plus dessus. Le `fatal` d'origine
  # sortait en 2 des le premier fichier et rendait TOUT le bloc preflight
  # inatteignable — un test qui ne s'execute pas ne prouve rien.
  if [ -z "$(defaut_env "$F" APIM_PROXY_HOST)" ]; then
    ko "$JF : decrit le proxy d'admin par morceaux (surchargeables un a un)" \
       "un defaut APIM_PROXY_HOST" "aucun — forme APIM_PROXY_BASE entiere"
    continue
  fi


  # Defauts LUS dans ce Jenkinsfile — plus aucune valeur codee dans le test.
  D_HOST="$(lire_defaut "$F" APIM_PROXY_HOST)"
  D_API="$(lire_defaut  "$F" APIM_PROXY_API)"
  D_VER="$(lire_defaut  "$F" APIM_PROXY_VER)"
  D_PATH="$(lire_defaut "$F" APIM_PROXY_PATH)"
  D_BASE="$(defaut_env  "$F" APIM_PROXY_BASE)"
  [ -n "$D_BASE" ] || fatal "APIM_PROXY_BASE : aucun defaut Groovy dans $F"
  D_BASE="${D_BASE#=}"

  defauts(){
    APIM_PROXY_HOST="$D_HOST"; APIM_PROXY_API="$D_API"
    APIM_PROXY_VER="$D_VER";   APIM_PROXY_PATH="$D_PATH"
    APIM_PROXY_BASE="$D_BASE"
  }

  cmp_ "la ligne d'override est bien celle rejouee" "$OVERRIDE_ATTENDU" "$(ligne_pb "$F" 'APIM_PROXY_BASE')"
  cmp_ "la ligne de composition est bien celle rejouee" "$COMPO_ATTENDUE" "$(ligne_pb "$F" 'APIM_PROXY_HOST')"
  cmp_ "APIM_PROXY_BASE par defaut VIDE (sinon la composition ne sert jamais)" "" "$D_BASE"

  defauts
  cmp_ "defauts du Jenkinsfile => identique a l'ancien defaut" "$ANCIEN_DEFAUT" "$(compose)"

  defauts; APIM_PROXY_API=wm-admin-prod
  cmp_ "le NOM seul est surchargeable" \
    "${D_HOST}/gateway/wm-admin-prod/${D_VER}${D_PATH}" "$(compose)"

  defauts; APIM_PROXY_HOST=https://apim.vip.interne:5543; APIM_PROXY_API=admin-proxy; APIM_PROXY_VER=2
  cmp_ "hote + nom + version" \
    "https://apim.vip.interne:5543/gateway/admin-proxy/2${D_PATH}" "$(compose)"

  defauts; APIM_PROXY_BASE=https://edge.client/adm/v1
  cmp_ "override complet gagne" "https://edge.client/adm/v1" "$(compose)"

  defauts; APIM_PROXY_BASE=""
  cmp_ "override VIDE (Jenkins n'exporte pas) => retombe sur la composition" \
    "$ANCIEN_DEFAUT" "$(compose)"

done

# ---- bloc 1bis : SUPPRIME (2026-08-04) ----
# Il verifiait <trim>true</trim> sur un parametre APIM_PROXY_BASE des job XML
# ci/jenkins/{publish-api,selfservice-app}-deploy.job.xml. Ces XML ont ete
# supprimes : ils n'etaient deployes nulle part, et APIM_PROXY_BASE n'est PAS
# un parametre de build — c'est une variable d'ENVIRONNEMENT des deux
# Jenkinsfile. La garde portait donc sur une declaration qui n'existait que
# dans ces fichiers, et sur aucun job reel.
#
# Ce qu'elle protegeait vraiment — qu'un espace colle en debut/fin d'un
# override d'URL ne passe pas — reste a couvrir la ou la valeur est REELLEMENT
# lue : dans le shell des Jenkinsfile. Non fait ici, signale.


echo
[ "$KO" -eq 0 ] && echo "TOUT PASSE" || { echo "$KO ECHEC(S)"; exit 1; }