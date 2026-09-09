#!/bin/sh
# ci/test-carto-secrets.sh — éprouve `ci/lib/carto-secrets.sh` ET la façon dont
# `ci/Jenkinsfile.carto` l'appelle. Aucun Vault, aucune gateway, aucun réseau.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QUE CE TEST LIT VRAIMENT
# ─────────────────────────────────────────────────────────────────────────────
#   - la BIBLIOTHÈQUE RÉELLE (`ci/lib/carto-secrets.sh`), sourcée, jamais
#     transcrite : un rejeu peut diverger du fichier en silence ;
#   - le JENKINSFILE RÉEL, relu littéralement (grep) pour les invariants qui ne
#     s'exécutent pas ici : chemin des `source`, absence de `dir()` ;
#   - le cwd RÉEL des blocs `sh` du job, c'est-à-dire la RACINE DU DÉPÔT
#     (`carto/` y est, et `python3 -m carto.collect` l'exige) — d'où le `cd`
#     en tête. Tester depuis `poc-control-plane-federation/` masquerait
#     exactement le défaut du 2026-08-26.
#
# LES QUATRE DÉFAUTS QU'IL VERROUILLE (tous constatés, aucun théorique) :
#   T1 chemin de `source` faux -> sous `set -eu`, le stage meurt AVANT la garde
#      « VAULT_ADDR vide ». Le job NOCTURNE tombait même sans Vault. C'est le
#      défaut le plus cher : le mode par défaut n'était plus le mode inchangé.
#   T2 `VAULT_ADDR` est posé sur le POD, donc vu par TOUS les stages : il ne
#      peut pas décider d'une bascule voulue chemin par chemin. Le signal par
#      stage est la LIAISON (`liaisons()` lie VAULT_SECRET_ID XOR le credential
#      Jenkins). Sans ce test, la bascule graduelle documentée est impossible.
#   T3 `carto-secrets.sh` source à son tour `vault-login.sh` — même piège de
#      chemin, une couche plus bas, et seul le chemin Vault le révèle.
#   T4 le chemin NOMINAL : login accepté, lecture réussie, secrets EXPORTÉS et
#      visibles d'un processus FILS (le collecteur les lit dans l'environnement,
#      jamais en argv). Une suite dont toutes les épreuves sont des REFUS ne
#      teste jamais le chemin qui doit marcher.
#
# USAGE : ci/test-carto-secrets.sh     (depuis n'importe où)
set -u

# Le préfixe du livrable est DÉDUIT de la place de ce fichier, jamais écrit :
# une porte qui épingle le préfixe du lab réinstalle le défaut qu'elle
# interdit (piège mesuré le 2026-09-09 sur test-deploy-pin.sh ⑱).
LIVRABLE="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"    # <racine>/<préfixe>
RACINE="$(CDPATH= cd -- "$LIVRABLE/.." && pwd)"            # racine du DÉPÔT
PFX_REEL="${LIVRABLE#"$RACINE"/}"                          # ex. « poc-control-plane-federation »
LIB_REL="${PFX_REEL}/ci/lib/carto-secrets.sh"
JF="$LIVRABLE/ci/Jenkinsfile.carto"
# SUB_PFX est ce que le podTemplate pose dans le conteneur : ici, sa valeur
# RÉELLE pour cet arbre. Les `sh -c` ci-dessous le posent EXPLICITEMENT — sans
# quoi un SUB_PFX exporté dans le shell de l'opérateur déciderait en silence.
SUB_PFX_REEL="${PFX_REEL}/"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok=0; ko=0
v() { # v <titre> <obtenu> <attendu>
  if [ "$2" = "$3" ]; then ok=$((ok+1)); echo "  ✓ $1"
  else ko=$((ko+1)); echo "  ✗ $1"; echo "      attendu : [$3]"; echo "      obtenu  : [$2]"; fi
}
contient() { # contient <titre> <texte> <aiguille>
  case "$2" in *"$3"*) v "$1" trouvé trouvé;; *) v "$1" "(absent)" "$3";; esac
}

cd "$RACINE"

echo "T0 — invariants relus dans le Jenkinsfile RÉEL"
v "T0.1 les 4 blocs sh sourcent la lib par un chemin COMPOSÉ depuis SUB_PFX" \
  "$(grep -c '^ *\. "\${SUB_PFX}ci/lib/carto-secrets\.sh"$' "$JF")" "4"
v "T0.2 aucun source par le chemin court (cwd = racine, pas le sous-dossier)" \
  "$(grep -c '^ *\. ci/lib/carto-secrets\.sh$' "$JF")" "0"
# CE QUE CETTE PORTE EXIGEAIT AVANT : les 4 lignes AVEC le préfixe du lab écrit
# en dur. Elle imposait donc exactement le défaut de portabilité qu'on ferme.
# Elle l'INTERDIT désormais — dans le Jenkinsfile comme dans la lib.
v "T0.2b aucun préfixe de lab en dur dans le Jenkinsfile (hors commentaires)" \
  "$(grep -v '^ *//' "$JF" | grep -c "${PFX_REEL}/ci/lib")" "0"
v "T0.2c aucun préfixe de lab en dur dans la lib (hors commentaires)" \
  "$(grep -v '^ *#' "$RACINE/$LIB_REL" | grep -c "${PFX_REEL}/ci/lib")" "0"
# Le préfixe n'atteint le shell QUE par le podTemplate : sans cette ligne, les
# quatre `source` ci-dessus n'ont aucune valeur à composer.
v "T0.2d le podTemplate injecte SUB_PFX dans le conteneur" \
  "$(grep -c "envVar(key: .SUB_PFX." "$JF")" "1"
# Les lignes de COMMENTAIRE parlent de `dir()` (elles expliquent son absence) :
# ce qu'on vérifie, c'est qu'aucune ligne de CODE n'en ouvre un — sinon le cwd
# changerait et les chemins complets ci-dessus deviendraient faux à leur tour.
v "T0.3 aucun dir() dans le CODE — c'est la prémisse du chemin complet" \
  "$(grep -v '^ *//' "$JF" | grep -c 'dir(')" "0"
# Une garde par préflight, nommément — un simple compte global serait satisfait
# par n'importe quel mélange, y compris deux gardes sur le même secret.
v "T0.4a préflight gateway gardé"    "$(grep -c 'if (VAULT_ON && V_GW)' "$JF")" "1"
v "T0.4b préflight publication gardé" "$(grep -c 'else if (VAULT_ON && V_PAGES)' "$JF")" "1"
v "T0.4c préflight Confluence gardé"  "$(grep -c 'if (VAULT_ON && V_CONF)' "$JF")" "1"

echo "T1 — mode par défaut : VAULT_ADDR vide, depuis la racine, sous set -eu"
# La ligne de `source` est DÉCOUPÉE dans le Jenkinsfile réel puis EXÉCUTÉE, pas
# transcrite : c'est le seul moyen que ce test tombe si le chemin redevient
# faux. Le transcrire reviendrait à tester une copie qui, elle, est correcte —
# précisément l'angle mort qui a laissé passer le défaut du 2026-08-26.
# ERE et guillemet optionnel : la ligne est désormais `. "${SUB_PFX}…sh"`.
# L'ancre `\.sh$` d'avant ne la retrouvait plus — et un SOURCE_REELLE vide
# faisait passer T1 pour un défaut de la lib au lieu d'un défaut de l'ancre.
SOURCE_REELLE="$(grep -m1 -E '^ *\. .*carto-secrets\.sh"?$' "$JF" | sed 's/^ *//')"
v "T1.0b l'extraction n'est pas vide (sinon T1 ne teste rien)" \
  "$([ -n "$SOURCE_REELLE" ] && echo non-vide || echo VIDE)" "non-vide"
v "T1.0 la ligne de source a bien été retrouvée dans le Jenkinsfile" \
  "$(printf '%s' "$SOURCE_REELLE" | cut -c1-2)" ". "
out=$(unset VAULT_ADDR VAULT_SECRET_ID
      SUB_PFX="$SUB_PFX_REEL" sh -c "set -eu; $SOURCE_REELLE; carto_secrets_resolve || exit 1; echo COLLECTE_LANCEE" 2>&1)
v         "T1.1 le stage survit (le job nocturne ne tombe pas)" "$(echo "$out" | tail -1)" "COLLECTE_LANCEE"
contient  "T1.2 il annonce le mode par défaut, pas un repli d'échec" "$out" "VAULT_ADDR vide"

echo "T2 — bascule graduelle : Vault actif, mais ce stage n'a pas de chemin"
out=$(VAULT_ADDR=http://vault:8200 CARTO_VAULT_PAGES_PATH=secret/data/pages SUB_PFX="$SUB_PFX_REEL" \
      sh -c "set -eu; unset VAULT_SECRET_ID; . $LIB_REL; carto_secrets_resolve || exit 1; echo RESTE_SUR_JENKINS" 2>&1)
v         "T2.1 le stage reste sur son credential Jenkins (rc=0)" "$(echo "$out" | tail -1)" "RESTE_SUR_JENKINS"
contient  "T2.2 il le DIT (sinon l'exploitant croit Vault actif partout)" "$out" "n'a pas de chemin Vault"

echo "T3 — chemin Vault : vault-login.sh doit être TROUVÉ (login peut échouer)"
out=$(VAULT_ADDR=http://127.0.0.1:1 VAULT_SECRET_ID=factice SUB_PFX="$SUB_PFX_REEL" \
      sh -c "set -eu; . $LIB_REL; carto_secrets_resolve" 2>&1)
case "$out" in
  *"No such file"*|*"not found"*|*"introuvable"*) v "T3.1 vault-login.sh trouvé" "chemin faux" "trouvé";;
  *) v "T3.1 vault-login.sh trouvé (aucune erreur de chemin)" trouvé trouvé;;
esac

echo "T4 — CHEMIN NOMINAL : Vault répond, les secrets sont exportés"
# Arbre factice : la lib RÉELLE (copiée telle quelle), sa dépendance BOUCHONNÉE.
# On bouchonne `vault-login.sh` et rien d'autre — la logique testée reste celle
# du fichier livré, seule la sortie réseau est remplacée.
mkdir -p "$TMP/$PFX_REEL/ci/lib"
cp "$LIB_REL" "$TMP/$PFX_REEL/ci/lib/"
cat > "$TMP/$PFX_REEL/ci/lib/vault-login.sh" <<'STUB'
vault_trap_revoke() { :; }
vault_login_any()   { return 0; }
vault_read() {
  case "$1/$2" in
    secret/data/gw/user)        echo "svc-carto-ro" ;;
    secret/data/gw/password)    echo "MotDePasseQuiNeDoitPasFuir" ;;
    secret/data/pages/user)     echo "svc-pages" ;;
    secret/data/pages/token)    echo "jeton-forge" ;;
    *) return 1 ;;
  esac
}
STUB
out=$(cd "$TMP" && VAULT_ADDR=http://vault:8200 VAULT_SECRET_ID=factice \
      CARTO_VAULT_GW_PATH=secret/data/gw CARTO_VAULT_PAGES_PATH=secret/data/pages SUB_PFX="$SUB_PFX_REEL" \
      sh -c "set -eu; . $LIB_REL; carto_secrets_resolve || exit 1
             python3 -c 'import os;print(\"FILS\",os.environ.get(\"WM_USER\",\"<ABSENT>\"),os.environ.get(\"WM_PASS\",\"<ABSENT>\"),os.environ.get(\"CARTO_PAGES_TOKEN\",\"<ABSENT>\"),os.environ.get(\"CONFLUENCE_TOKEN\",\"<NON-LU>\"))'" 2>&1)
v "T4.1 secrets lus dans Vault et vus par le processus FILS" \
  "$(echo "$out" | tail -1)" "FILS svc-carto-ro MotDePasseQuiNeDoitPasFuir jeton-forge <NON-LU>"
v "T4.2 un chemin vide n'est PAS lu (Confluence reste sur Jenkins)" \
  "$(echo "$out" | grep -c 'CONFLUENCE_TOKEN  ←')" "0"
v "T4.3 la lib n'imprime AUCUNE valeur de secret (noms et longueurs seulement)" \
  "$(echo "$out" | sed '$d' | grep -c 'MotDePasseQuiNeDoitPasFuir')" "0"

echo "T5 — PORTABILITÉ : le préfixe vient du knob, et il DÉCIDE"
# Cette section est la SEULE qui joue hors du préfixe du lab. Sans elle, T0..T4
# passeraient à l'identique sur du code qui écrit « poc-control-plane-federation »
# en dur — c'est exactement l'angle mort qui a laissé vivre ce défaut, et c'est
# ce que la porte EXIGEAIT encore hier (T0.1, dans sa forme d'avant).
# `sh -c` en quotes SIMPLES : ${SUB_PFX} doit atteindre le shell INTÉRIEUR.
t5_arbre() {   # t5_arbre <racine> <préfixe|.> → imprime le SUB_PFX correspondant
  t5_sub=""
  [ "$2" = "." ] || t5_sub="$2/"
  mkdir -p "$1/${t5_sub}ci/lib"
  cp "$RACINE/$LIB_REL" "$1/${t5_sub}ci/lib/"
  cp "$TMP/$PFX_REEL/ci/lib/vault-login.sh" "$1/${t5_sub}ci/lib/"
  printf '%s' "$t5_sub"
}
t5_joue() {    # t5_joue <racine> <SUB_PFX posé>
  ( cd "$1" && VAULT_ADDR=http://vault:8200 VAULT_SECRET_ID=factice \
      CARTO_VAULT_GW_PATH=secret/data/gw CARTO_VAULT_PAGES_PATH=secret/data/pages \
      SUB_PFX="$2" sh -c 'set -eu; . "${SUB_PFX}ci/lib/carto-secrets.sh"; carto_secrets_resolve >/dev/null 2>&1 && echo CHAINE_OK' 2>&1 ) | tail -1
}

T5A="$TMP/t5a"; S5A="$(t5_arbre "$T5A" livrable)"
v "T5.1 préfixe NON-DÉFAUT (livrable/) : la chaîne carto résout ses deux libs" \
  "$(t5_joue "$T5A" "$S5A")" "CHAINE_OK"

T5B="$TMP/t5b"; S5B="$(t5_arbre "$T5B" .)"
v "T5.2 sentinelle « le livrable EST la racine » (SUB_PFX vide)" \
  "$(t5_joue "$T5B" "$S5B")" "CHAINE_OK"

# LE DISCRIMINANT. L'arbre porte le préfixe du LAB, le knob dit « livrable/ » :
# un code qui ignore le knob trouve ses libs et rend CHAINE_OK — c'est le
# défaut, à l'envers. Aucune mutation n'est nécessaire pour prouver que T5.1
# n'est pas vacante : ce cas seul sépare les deux formes du code.
T5C="$TMP/t5c"; t5_arbre "$T5C" "$PFX_REEL" >/dev/null
v "T5.3 discriminant : libs présentes au préfixe du lab + knob 'livrable/' ⇒ la chaîne NE résout PAS" \
  "$(t5_joue "$T5C" "livrable/" | grep -c CHAINE_OK)" "0"

echo
echo "RÉSULTAT : $ok réussies, $ko échouées"
[ "$ko" -eq 0 ]
