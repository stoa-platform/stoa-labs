#!/bin/sh
# Rejoue la logique exacte injectee dans les deux Jenkinsfile, sous `set -eu`,
# avec un curl simule. Verifie composition de la base proxy + preflight optionnel.
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
#   - les defauts du preflight (codes de preuve de vie, nombre d'essais) = idem ;
#   - les garde-fous (validation de APIM_PREFLIGHT_TRIES, casse de
#     APIM_PREFLIGHT) = leur PRESENCE ET leur ordre sont verifies par lecture
#     litterale (grep) du Jenkinsfile REEL, pas seulement rejoues dans le
#     harnais de simulation ci-dessous ;
#   - le COMPORTEMENT des garde-fous sur les valeurs adverses = le bloc est
#     DECOUPE dans le Jenkinsfile REEL et EXECUTE sous `sh` (10^20, 08, 060),
#     jamais transcrit : un rejeu peut diverger du fichier en silence ;
#   - le trim d'APIM_PROXY_BASE = extrait du job XML REEL.
# Le premier jet codait les DEUX cotes de l'assertion « defauts => identique a
# l'ancien defaut » dans le test : il comparait deux constantes du test entre
# elles et restait VERT alors qu'un defaut du Jenkinsfile avait rompu la
# retro-compatibilite. Un test qui ne lit pas son sujet ne teste rien.
#
# Boucle sur les DEUX Jenkinsfile : rien ne garantit qu'ils restent alignes.
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
# Defauts du preflight transcrits dans `preflight()` ci-dessous.
PF_CODES_REJOUES='200 401'
PF_MAX_REJOUE='60'

for JF in $JENKINSFILES; do
  F="$POC/ci/$JF"
  [ -f "$F" ] || fatal "$F introuvable"
  echo "== $JF : composition de la base proxy =="

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

  echo "== $JF : defauts du preflight =="
  cmp_ "codes de preuve de vie" "$PF_CODES_REJOUES" "$(lire_defaut_sh "$F" PF_CODES APIM_PREFLIGHT_CODES)"
  cmp_ "nombre d'essais"        "$PF_MAX_REJOUE"    "$(lire_defaut_sh "$F" PF_MAX   APIM_PREFLIGHT_TRIES)"

  echo "== $JF : garde-fous du preflight (lus dans le fichier reel) =="
  # APIM_PREFLIGHT_TRIES non numerique : sous sh, `[ "$i" -ge "abc" ]` rend 2
  # (ni vrai ni faux) — la branche de sortie n'est jamais prise, boucle a
  # l'infini. Le garde-fou doit exister ET s'executer AVANT la boucle.
  contient "$JF : le garde-fou PF_MAX existe (case sur un entier)" 'case "$PF_MAX" in' "$F"
  contient "$JF : rejette le non-numerique" '*[!0-9]*' "$F"
  contient "$JF : rejette aussi zero EN TETE (0, 00, 08, 060 — piege octal de \$((…)))" '|0*)' "$F"
  contient "$JF : replie explicitement sur le defaut 60" 'PF_MAX=60' "$F"
  avant "$JF : le garde-fou PF_MAX est pose avant la boucle, pas apres" \
    'case "$PF_MAX" in' 'while :; do' "$F"
  # Borne haute : sans elle, une valeur enorme mais numerique (ex.
  # 99999999999999999999) passe le garde-fou ci-dessus et rouvre le meme
  # mode de panne — aucun timeout de build n'est pose dans les job XML.
  contient "$JF : la borne haute teste la longueur avant l'arithmetique (pas de debordement de -gt)" '?????*' "$F"
  contient "$JF : la borne haute replie sur 3600" '-gt 3600' "$F"
  avant "$JF : la borne haute est posee avant la boucle, pas apres" \
    '?????*' 'while :; do' "$F"
  # APIM_PREFLIGHT sensible a la casse : 'Off' ne doit pas etre pris pour 'off'.
  contient "$JF : APIM_PREFLIGHT est compare apres mise en minuscules" \
    "tr '[:upper:]' '[:lower:]'" "$F"
  contient "$JF : le test 'off' porte sur la variable normalisee" \
    'if [ "$APIM_PREFLIGHT_LC" = "off" ]; then' "$F"

  echo "== $JF : valeurs adverses, bloc REEL extrait et EXECUTE =="
  # Les `contient`/`avant` ci-dessus prouvent que le garde-fou est ECRIT ;
  # `preflight()` plus bas rejoue une COPIE de sa logique. Ni l'un ni l'autre
  # ne prouve que le texte REEL, EXECUTE, se comporte bien : un rejeu peut
  # diverger du fichier sans que rien ne le dise (c'est exactement ainsi que
  # le harnais restait vert alors que '08' tuait le vrai bloc). On decoupe
  # donc le bloc tel qu'il est ecrit — de `PF_MAX="${APIM_PREFLIGHT_TRIES:-60}"`
  # jusqu'a la ligne qui precede `i=0` — et on l'execute sous `sh`.
  sed -n '/PF_MAX="${APIM_PREFLIGHT_TRIES:-60}"/,/^[[:space:]]*i=0$/p' "$F" \
    | sed '$d' > "$TMPD/gardes.sh"
  grep -qF 'PF_MAX=' "$TMPD/gardes.sh" \
    || fatal "$JF : bloc de garde-fous du preflight introuvable (ancres deplacees ?) — le test ne peut rien affirmer"
  if grep -qF 'while' "$TMPD/gardes.sh"; then
    fatal "$JF : l'extraction du bloc de garde-fous a deborde sur la boucle — le test ne peut rien affirmer"
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
printf 'PFMAX=%s MSG5=%s AVANT=%s BORNE=%s\n' "$PF_MAX" "$((PF_MAX*5))" "$RCLO" "$RCHI"
SONDE
  adverse(){ APIM_PREFLIGHT_TRIES="$1" sh "$TMPD/gardes.sh" 2>&1 | tail -1; }

  cmp_ "$JF (texte reel) : 99999999999999999999 => borne a 3600, ne boucle plus sans fin" \
    "PFMAX=3600 MSG5=18000 AVANT=1 BORNE=0" "$(adverse 99999999999999999999)"
  # '08' : purement numerique, donc accepte par le filtre `*[!0-9]*` — mais
  # `$((08*5))` est une erreur d'arithmetique octale qui TUE l'etape sous
  # `set -e`. MSG5=300 prouve que la duree annoncee est bien lue en base 10.
  cmp_ "$JF (texte reel) : 08 (piege octal) => ne tue plus l'etape, replie sur 60" \
    "PFMAX=60 MSG5=300 AVANT=1 BORNE=0" "$(adverse 08)"
  # '060' : meme filtre, mais ici l'octal est SILENCIEUX — `$((060*5))`
  # vaudrait 240 (48*5) et annoncerait une duree fausse au lieu de 300.
  cmp_ "$JF (texte reel) : 060 => la duree annoncee n'est plus lue en octal (300s, pas 240s)" \
    "PFMAX=60 MSG5=300 AVANT=1 BORNE=0" "$(adverse 060)"
done

# ---- bloc 1bis : trim du parametre APIM_PROXY_BASE dans les job XML ----
# APIM_PROXY_BASE est l'echappatoire (override complet, cf. commentaire du
# Jenkinsfile) : c'est justement celle qui ne doit PAS laisser passer un
# espace colle en debut/fin — sinon l'URL composee est invalide, et l'erreur
# est difficile a voir (un espace ne se distingue pas a l'oeil dans un log).
# Valeur LUE dans le XML reel : jamais une constante du test.
JOBXMLS="jenkins/publish-api-deploy.job.xml jenkins/selfservice-app-deploy.job.xml"
# Extrait le <trim> du bloc <hudson.model.StringParameterDefinition> dont le
# <name> vaut $2, dans le fichier $1 (les blocs ne s'imbriquent pas dans ces XML).
trim_de(){
  awk -v nom="$2" '
    /<hudson\.model\.StringParameterDefinition>/ { buf=""; dans=1 }
    dans { buf = buf $0 "\n" }
    /<\/hudson\.model\.StringParameterDefinition>/ {
      dans=0
      if (buf ~ ("<name>" nom "</name>")) {
        if (match(buf, /<trim>[a-z]*<\/trim>/)) {
          s = substr(buf, RSTART, RLENGTH); gsub(/<\/?trim>/, "", s); print s; exit
        }
      }
    }
  ' "$1"
}

for X in $JOBXMLS; do
  XF="$POC/ci/$X"
  [ -f "$XF" ] || fatal "$XF introuvable"
  echo "== $X : trim d'APIM_PROXY_BASE =="
  TR="$(trim_de "$XF" APIM_PROXY_BASE)"
  [ -n "$TR" ] || fatal "APIM_PROXY_BASE : aucun <trim> lisible dans $XF"
  cmp_ "$X : APIM_PROXY_BASE n'est plus la seule echappatoire non rognee (trim=true)" "true" "$TR"

  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$XF" >"$TMPD/xmlok" 2>&1; then
      ok "$X : XML bien forme"
    else
      ko "$X : XML bien forme" "0" "$(cat "$TMPD/xmlok")"
    fi
  fi
done

# ---- bloc 2 : preflight (copie conforme, curl simule) ----
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
    # `$((PF_MAX*5))` rejoue ICI aussi : c'est cette arithmetique precise qui,
    # sur le vrai Jenkinsfile, casse sur une valeur en tete de zero non filtree
    # (piege octal) — sans elle, le harnais resterait vert alors que le bloc
    # reel meurt sur un message cryptique.
    if [ "$i" -ge "$PF_MAX" ]; then echo "FAIL:$PF_URL:$HC:apres $((PF_MAX*5))s"; return 1; fi
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
cmp_ "epuisement => echec explicite" "FAIL:http://gw/rest/apigateway/health:000:apres 15s" "$R"
if ( CURL_SEQ="000,000,000"; APIM_PREFLIGHT_TRIES=3; preflight >/dev/null 2>&1 ); then
  ko "epuisement => code retour non nul" "!=0" "0"; else ok "epuisement => code retour non nul"; fi
unset APIM_PREFLIGHT_TRIES

# APIM_PREFLIGHT_TRIES non numerique : preuve QUANTITATIVE de non-bouclage —
# pas seulement « ca finit par sortir », mais « ca sort au bout d'exactement
# PF_MAX(=60, le defaut) appels curl », donc borne et pas un hasard de sequence.
CURL_SEQ="000"; APIM_PREFLIGHT_TRIES="abc"
R="$(preflight || true)"
cmp_ "APIM_PREFLIGHT_TRIES='abc' => ne boucle plus a l'infini (replie sur 60)" \
  "FAIL:http://gw/rest/apigateway/health:000:apres 300s" "$R"
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

# Zero EN TETE : passe le filtre "que des chiffres" mais casse `$((PF_MAX*5))`
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
cmp_ "  … et \$((PF_MAX*5)) du message de sortie reste calculable" "18000" "$((PF_MAX*5))"
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
  "FAIL:http://gw/rest/apigateway/health:503:apres 10s" "$R"

echo
[ "$KO" -eq 0 ] && echo "TOUT PASSE" || { echo "$KO ECHEC(S)"; exit 1; }
