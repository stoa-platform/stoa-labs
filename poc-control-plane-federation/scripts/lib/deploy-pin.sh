#!/usr/bin/env bash
# scripts/lib/deploy-pin.sh — LE RÉSOLVEUR DE PIN (jalon G3).
#
# POURQUOI CE FICHIER EXISTE : hors de dev, ce qui est déployé ne doit pas être
# « le dernier main » mais l'état EXACT qu'une porte a approuvé. Le marqueur
# apis/<name>.deploy.<env>.yaml porte ce SHA ; ce fichier le résout, une fois,
# EN AMONT des deux moteurs (décision D3 de la spec). Aucun moteur ne porte de
# logique de pin : ils reçoivent des CHEMINS de fichiers déjà résolus, par les
# extra-vars qui existent déjà (apim_ss_manifest, apim_promote_manifest,
# apim_ss_contract_pin).
#
# FAIL-CLOSED PARTOUT : toute anomalie est un refus nommé, jamais un repli sur
# HEAD. Un repli silencieux déploierait autre chose que l'approuvé, sans que
# rien ne rougisse — c'est le mode de panne que ce fichier existe pour rendre
# impossible (même discipline que labctl/internal/uac/pinned.go:15-16).

# Racine résolue AU SOURCE (piège mesuré en G1 : les appelants font un `cd`
# après le source, un BASH_SOURCE résolu à l'appel renverrait du vide).
_STOA_DEPLOY_PIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export _STOA_DEPLOY_PIN_ROOT

# L'environnement d'AUTHORING — le seul palier sans marqueur, le seul qui suit
# HEAD (labctl/internal/uac/pinned.go:15 : « publish writes no pin: the entry
# environment follows HEAD by design »). ADR-079 : c'est le seul env où le blip
# de première création est toléré. C'est le PREMIER palier de la chaîne
# `environments.yaml` (clients/_example/environments.yaml : [dev, rec, int,
# homol, prod]).
#
# ⚠ AFFECTATION SÈCHE, PAS `${…:-dev}`. Une valeur surchargeable par
# l'environnement serait le contournement de TOUT ce fichier : poser
# `DEPLOY_PIN_AUTHORING_ENV=prod` ferait entrer la prod dans la branche
# d'authoring, qui retourne AVANT le marqueur, le pin, l'ancêtreté, la version
# et le digest — un repli total et silencieux sur HEAD, déclenché par un seul
# mot. Et ce n'est pas théorique ici : les paramètres d'un build Jenkins
# atterrissent dans l'environnement du job (fait mesuré lors du refactor des
# Jenkinsfile). Le seul palier qui a le droit de suivre HEAD ne se choisit pas
# depuis l'extérieur.
DEPLOY_PIN_AUTHORING_ENV="dev"

deploy_pin_marker_path() { printf 'apis/%s.deploy.%s.yaml' "$1" "$2"; }

# Nomme le refus sur stderr. Toujours appelé comme une INSTRUCTION suivie d'un
# `return 1` explicite — jamais `return $(_dp_fail …)`. Cette dernière forme
# « marche » (return sans argument rend le statut de la dernière commande) mais
# elle est illisible et se casse au premier refactor : un message qui écrirait
# par erreur sur stdout deviendrait l'argument de `return`, donc un code de
# sortie absurde ou une erreur de syntaxe.
_dp_fail() { printf 'deploy-pin: %s\n' "$*" >&2; }

# resolve_deploy_pin <clone_dir> <api_name> <env> <workdir> [main_ref=origin/main] [archive_in]
resolve_deploy_pin() {
  local clone="$1" api="$2" env="$3" work="$4" mainref="${5:-origin/main}" archive_in="${6:-}"

  # Sans elle, un appel qui ÉCHOUE laisse en place les valeurs du précédent :
  # mesuré en revue — après un succès sur `bonapi` puis un échec sur
  # `mauvaiseapi`, DEPLOY_PIN_PUBLISH désignait le manifeste de la seconde et
  # DEPLOY_PIN_ARCHIVE les octets de la PREMIÈRE. Un appelant qui ignore le code
  # de retour (ou un wrapper Ansible en `ignore_errors`) déploierait les octets
  # d'une API sous l'identité d'une autre. Un refus doit laisser un état VIDE,
  # jamais l'état de quelqu'un d'autre.
  DEPLOY_PIN_COMMIT=""; DEPLOY_PIN_VERSION=""; DEPLOY_PIN_SHA256=""
  DEPLOY_PIN_PUBLISH=""; DEPLOY_PIN_PROMOTE=""; DEPLOY_PIN_CONTRACT=""
  DEPLOY_PIN_ARCHIVE=""
  export DEPLOY_PIN_COMMIT DEPLOY_PIN_VERSION DEPLOY_PIN_SHA256 \
         DEPLOY_PIN_PUBLISH DEPLOY_PIN_PROMOTE DEPLOY_PIN_CONTRACT DEPLOY_PIN_ARCHIVE

  # Le nom d'API construit des CHEMINS (`apis/<api>.publish.yml`) et des
  # arguments `git show`. On le contraint ici, indépendamment de ce que les
  # appelants valident de leur côté : une fonction qui fabrique des chemins à
  # partir de son argument ne délègue pas sa sûreté à ses appelants — le jour
  # où un nouvel appelant oublie de valider, c'est ce fichier qui tient.
  case "$api" in
    ""|*[!a-z0-9-]*) { _dp_fail "API_NAME_INVALIDE : '$api' — attendu des minuscules, chiffres et tirets (aucun '/', aucun '..')"; return 1; };;
  esac
  case "$env" in
    ""|*[!a-z0-9-]*) { _dp_fail "ENV_INVALIDE : '$env' — attendu des minuscules, chiffres et tirets"; return 1; };;
  esac

  local rel; rel="$(deploy_pin_marker_path "$api" "$env")"

  if [ "$env" = "$DEPLOY_PIN_AUTHORING_ENV" ]; then
    # dev : pas de marqueur, pas de digest — on matérialise l'ARBRE DE TRAVAIL
    # du clone tel quel. En CI c'est exactement l'état revu (l'appelant a fait
    # `git checkout <MERGE_SHA>` avant d'appeler) ; hors CI, sur un clone sale,
    # ce n'est PAS HEAD — dire « HEAD » ici serait décrire autre chose que le
    # code.
    mkdir -p "$work" \
      || { _dp_fail "WORKDIR_INCREABLE : impossible de créer '$work'"; return 1; }
    local g
    for g in publish.yml openapi.yaml; do
      cp "$clone/apis/${api}.${g}" "$work/${api}.${g}" \
        || { _dp_fail "MANIFESTE_ABSENT : apis/${api}.${g} introuvable sur HEAD"; return 1; }
    done
    DEPLOY_PIN_PROMOTE=""
    if [ -f "$clone/apis/${api}.promote.yml" ]; then
      cp "$clone/apis/${api}.promote.yml" "$work/${api}.promote.yml" \
        && DEPLOY_PIN_PROMOTE="$work/${api}.promote.yml"
    fi
    DEPLOY_PIN_COMMIT=""; DEPLOY_PIN_VERSION=""; DEPLOY_PIN_SHA256=""
    DEPLOY_PIN_PUBLISH="$work/${api}.publish.yml"
    DEPLOY_PIN_CONTRACT="$work/${api}.openapi.yaml"
    DEPLOY_PIN_ARCHIVE=""
    export DEPLOY_PIN_COMMIT DEPLOY_PIN_VERSION DEPLOY_PIN_SHA256 \
           DEPLOY_PIN_PUBLISH DEPLOY_PIN_PROMOTE DEPLOY_PIN_CONTRACT DEPLOY_PIN_ARCHIVE
    return 0
  fi

  [ -f "$clone/$rel" ] || { _dp_fail "PIN_ABSENT : $rel absent — hors de l'environnement d'authoring, aucun repli sur HEAD"; return 1; }

  local raw
  raw=$(DP_FILE="$clone/$rel" python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["DP_FILE"])) or {}
c = str(d.get("commit") or "")
v = str(d.get("version") or "")
s = str(d.get("archive_sha256") or "")
# Les trois champs voyagent dans UNE ligne délimitée par '|', que le shell
# redécoupe. Un '|' présent dans une valeur décalerait silencieusement les
# frontières de champ — une version « 1.0|0 » ferait fuiter du texte dans le
# digest sans qu'aucun refus ne se déclenche. On REFUSE le délimiteur dans
# les valeurs plutôt que d'espérer qu'il n'y soit pas.
for name, val in (("commit", c), ("version", v), ("archive_sha256", s)):
    if "|" in val:
        sys.exit("le champ %s contient le délimiteur '|'" % name)
print("PIN=%s|%s|%s" % (c, v, s))
PY
) || { _dp_fail "PIN_MALFORMED : $rel illisible ou champ invalide (parse YAML, ou valeur contenant le délimiteur)"; return 1; }
  case "$raw" in PIN=*) raw="${raw#PIN=}";; *) { _dp_fail "PIN_MALFORMED : sortie inattendue de la lecture de $rel"; return 1; };; esac

  DEPLOY_PIN_COMMIT="${raw%%|*}"; raw="${raw#*|}"
  DEPLOY_PIN_VERSION="${raw%%|*}"
  DEPLOY_PIN_SHA256="${raw#*|}"

  # LE PIN DOIT ÊTRE UN OBJET IMMUABLE, PAS UNE RÉFÉRENCE MOUVANTE.
  #
  # ⚠ Un motif de la forme `[0-9a-f]×7*` ne contraint que les SEPT premiers
  # caractères : le `*` final accepte n'importe quoi ensuite. Reproduit en
  # revue — un marqueur portant `commit: cafebabe-drift` (un NOM DE BRANCHE)
  # passait, et `git show` résolvait la branche, donc la tête du moment. Le
  # résolveur rendait alors silencieusement une AUTRE version que celle
  # pinnée : précisément le mode de panne que ce fichier existe pour rendre
  # impossible, atteint par une référence mouvante au lieu de HEAD.
  #
  # Deux verrous, pas un : (1) AUCUN caractère non hexadécimal, où qu'il soit ;
  # (2) la longueur d'un identifiant d'objet COMPLET — 40 (SHA-1) ou 64
  # (SHA-256). L'écrivain pose `git log -1 --format=%H`, donc 40. Exiger la
  # forme complète ferme aussi le cas pathologique d'une branche dont le nom
  # serait entièrement hexadécimal : elle n'aura pas cette longueur.
  case "$DEPLOY_PIN_COMMIT" in
    *[!0-9a-f]*) { _dp_fail "PIN_MALFORMED : commit='$DEPLOY_PIN_COMMIT' contient un caractère non hexadécimal — un pin est un identifiant d'objet, jamais un nom de branche ou de tag (une référence mouvante ne pinne rien)"; return 1; };;
  esac
  case "${#DEPLOY_PIN_COMMIT}" in
    40|64) ;;
    *) { _dp_fail "PIN_MALFORMED : commit='$DEPLOY_PIN_COMMIT' fait ${#DEPLOY_PIN_COMMIT} caractères — un identifiant d'objet complet en fait 40 (SHA-1) ou 64 (SHA-256)"; return 1; };;
  esac

  # GARDE D'ATTEIGNABILITÉ — la garde qui ne se devine pas.
  # `git show <sha>:<path>` réussit sur TOUT objet présent dans le clone, y
  # compris un commit vivant sur une branche jamais mergée (un `git clone`
  # sans --depth 1 récupère toutes les branches). Sans cette vérification, une
  # PR de promotion irréprochable en apparence peut pinner un SHA jamais revu :
  # le pin déplacerait alors la confiance du MERGE vers un champ que le
  # demandeur remplit lui-même. Même intention que MERGE_SHA_NON_ANCETRE
  # (team-publish.sh:246), un cran plus bas.
  git -C "$clone" merge-base --is-ancestor "$DEPLOY_PIN_COMMIT" "$mainref" 2>/dev/null \
    || { _dp_fail "PIN_NON_ANCETRE : $DEPLOY_PIN_COMMIT n'est pas un ancêtre de $mainref — refus de déployer depuis un état jamais fusionné"; return 1; }

  mkdir -p "$work" \
    || { _dp_fail "WORKDIR_INCREABLE : impossible de créer '$work'"; return 1; }
  # publish.yml et openapi.yaml sont TOUJOURS présents — api-request.sh les pose
  # ENSEMBLE, au même commit (team-publish.sh:259 refuse déjà CONTRAT_ABSENT).
  local f
  for f in publish.yml openapi.yaml; do
    local src="apis/${api}.${f}" dst="$work/${api}.${f}"
    git -C "$clone" show "${DEPLOY_PIN_COMMIT}:${src}" > "$dst" 2>/dev/null \
      || { _dp_fail "PIN_UNREADABLE : git show ${DEPLOY_PIN_COMMIT}:${src} a échoué — le pin ne se résout pas, refus (jamais de repli sur HEAD)"; return 1; }
  done

  # Le marqueur et le manifeste doivent parler de la MÊME version. Une
  # divergence signale un marqueur édité à la main après coup, ou un pin posé
  # sur le mauvais commit — dans les deux cas on déploierait une version que
  # personne n'a demandée.
  local mv
  mv=$(DP_FILE="$work/${api}.publish.yml" python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["DP_FILE"])) or {}
print("V=" + str((d.get("apim_api") or {}).get("version") or ""))
PY
) || { _dp_fail "PIN_MALFORMED : publish.yml résolu illisible"; return 1; }
  case "$mv" in V=*) mv="${mv#V=}";; *) { _dp_fail "PIN_MALFORMED : sortie inattendue de la lecture de version"; return 1; };; esac
  # ⚠ COMPARER AVANT DE VÉRIFIER LA PRÉSENCE EST UN FAIL-OPEN. Les deux côtés
  # sont extraits en `… or ""` : un marqueur sans `version:` et un manifeste
  # sans `apim_api.version` donnent tous deux la chaîne vide, et `"" = ""`
  # passerait pour une CORRESPONDANCE. Le résolveur accepterait alors un pin
  # dont personne ne sait quelle version il déploie — exactement ce que ce
  # garde-fou existe pour empêcher. On exige donc la présence des deux, puis
  # seulement on compare.
  [ -n "$DEPLOY_PIN_VERSION" ] \
    || { _dp_fail "PIN_MALFORMED : le marqueur ne porte aucune version — impossible de vérifier ce qui serait déployé"; return 1; }
  [ -n "$mv" ] \
    || { _dp_fail "PIN_MALFORMED : le manifeste au SHA pinné ne porte aucune version (apim_api.version absent)"; return 1; }
  [ "$mv" = "$DEPLOY_PIN_VERSION" ] \
    || { _dp_fail "PIN_VERSION_MISMATCH : le marqueur annonce '$DEPLOY_PIN_VERSION' mais le manifeste au SHA pinné porte '$mv'"; return 1; }

  # promote.yml, LUI, peut légitimement manquer : api-request.sh n'écrit que
  # publish.yml + openapi.yaml (vérifié — scripts/api-request.sh:281-282). Le
  # manifeste de promotion n'existe que pour une API destinée à voyager par
  # archive. On le résout s'il existe ; la garde qui l'EXIGE vit plus bas, au
  # moment où on en a réellement besoin (le digest). Exiger les trois ici
  # casserait toute API créée par le formulaire.
  DEPLOY_PIN_PROMOTE=""
  if git -C "$clone" show "${DEPLOY_PIN_COMMIT}:apis/${api}.promote.yml" \
       > "$work/${api}.promote.yml" 2>/dev/null; then
    DEPLOY_PIN_PROMOTE="$work/${api}.promote.yml"
  else
    rm -f "$work/${api}.promote.yml"
  fi

  DEPLOY_PIN_PUBLISH="$work/${api}.publish.yml"
  DEPLOY_PIN_CONTRACT="$work/${api}.openapi.yaml"

  # ── LE DIGEST ────────────────────────────────────────────────────────────
  # CE QUE CETTE VÉRIFICATION TIENT, EXACTEMENT : les octets de l'archive
  # fournie == le digest que LE DEMANDEUR a écrit dans le marqueur du palier
  # d'arrivée. Rien de plus.
  #
  # ⚠ ELLE NE CHAÎNE RIEN D'UN PALIER À L'AUTRE, et la version précédente de ce
  # commentaire affirmait le contraire — « cette vérification FORCE la
  # réutilisation des MÊMES octets d'un palier à l'autre… c'est ce qui distingue
  # “build once, deploy many” d'une intention ». C'était faux :
  # `archive_sha256` était saisi au formulaire à CHAQUE saut, indépendamment,
  # et personne ne comparait le digest du palier N à celui du palier N−1 ; le
  # pin, lui, venait du dernier `main`. Une promotion rec → int pouvait donc
  # pinner un état que rec n'avait jamais servi.
  #
  # ⚙ ARBITRÉ ET FERMÉ (2026-08-26) — chaînage strict. `resolve_promotion_pin`
  # (plus bas dans ce fichier) prend le pin ET le digest dans le marqueur du
  # palier SOURCE dès que l'on part d'autre chose que l'env d'authoring, et
  # l'écrivain refuse un digest de formulaire qui les contredirait
  # (DIGEST_CONTREDIT_SOURCE). Les mêmes octets voyagent donc réellement d'un
  # palier au suivant : « build once, deploy many » est tenu par le MÉCANISME,
  # plus par la discipline du demandeur. Éprouvé par ㉑ (mutation : rétablir le
  # calcul depuis `main` fait rougir cinq assertions).
  #
  # ⚠ CE QUE ÇA COÛTE : une correction ne saute aucun palier. Un correctif
  # urgent re-traverse depuis l'env d'authoring. C'est le prix de la garantie,
  # et c'est ce que l'exploitant devra expliquer le jour où ça pressera.
  [ -n "$DEPLOY_PIN_SHA256" ] \
    || { _dp_fail "DIGEST_ABSENT : archive_sha256 vide pour l'env '$env' — hors authoring, les octets déployés doivent être pinnés"; return 1; }

  # promote.yml devient obligatoire ICI, et pas plus tôt : hors de l'env
  # d'authoring, le verbe est l'import d'archive (ADR-079) et c'est ce manifeste
  # qui pilote le play. Une API sans promote.yml ne peut pas voyager par archive.
  [ -n "$DEPLOY_PIN_PROMOTE" ] \
    || { _dp_fail "PROMOTE_MANIFEST_ABSENT : apis/${api}.promote.yml absent au SHA pinné — hors de '$DEPLOY_PIN_AUTHORING_ENV', la promotion se fait par archive et exige ce manifeste"; return 1; }

  # ⚠ LE CHEMIN DE L'ARCHIVE NE SE LIT PAS DANS promote.yml. Mesuré : le seul
  # manifeste réel du dépôt y porte une EXPRESSION JINJA, pas un chemin —
  #   clients/_example/apis/accounts-read.promote.yml:
  #     archive: "{{ playbook_dir }}/../dist/accounts-read-1.0.0.archive.zip"
  # que seul Ansible sait rendre, au moment du play. Un `stat` sur cette chaîne
  # brute échoue TOUJOURS : une première version de ce bloc la lisait, et la
  # promotion hors dev était donc morte au premier contact avec le format réel,
  # pendant que six fixtures inventaient un format littéral pour rester vertes.
  #
  # L'archive est un ARTEFACT DE BUILD dont l'appelant (le CI) connaît
  # l'emplacement — c'est lui qui l'a produite ou récupérée. Il le passe donc
  # explicitement. Le lien « approuvé == déployé » n'est pas porté par le
  # CHEMIN mais par le DIGEST, vérifié deux fois contre la même valeur pinnée :
  # ici sur les octets que le CI détient, et de nouveau dans le rôle sur les
  # octets qu'il s'apprête à POSTer (Task 6). Deux chemins, un invariant.
  [ -n "$archive_in" ] \
    || { _dp_fail "ARCHIVE_ABSENT : aucun chemin d'archive fourni (6e argument) — hors authoring le digest doit être vérifié, donc on ne promeut pas"; return 1; }
  # ABSOLU EXIGÉ : l'en-tête de ce fichier documente que les appelants font un
  # `cd` après le source. Un chemin relatif serait haché depuis le cwd du
  # résolveur puis réexporté tel quel, et le moteur le rouvrirait depuis SON
  # cwd : on vérifierait un fichier et on en déploierait un autre, sans aucun
  # refus. Mesuré.
  case "$archive_in" in
    /*) ;;
    *) { _dp_fail "ARCHIVE_PATH_RELATIVE : '$archive_in' n'est pas absolu — les octets vérifiés et les octets consommés seraient résolus depuis deux répertoires différents"; return 1; };;
  esac
  [ -f "$archive_in" ] \
    || { _dp_fail "ARCHIVE_ABSENT : archive '$archive_in' introuvable — le digest ne peut pas être vérifié, donc on ne promeut pas"; return 1; }

  local actual
  actual=$(shasum -a 256 "$archive_in" 2>/dev/null | cut -d' ' -f1) \
    || { _dp_fail "ARCHIVE_UNREADABLE : impossible de hacher '$archive_in' (droits ? fichier spécial ?)"; return 1; }
  # `actual` vide ne doit JAMAIS retomber dans la comparaison : si le digest
  # pinné pouvait l'être aussi, `"" = ""` passerait pour une correspondance —
  # le fail-open déjà rencontré sur la version.
  [ -n "$actual" ] \
    || { _dp_fail "ARCHIVE_UNREADABLE : sha256 vide pour '$archive_in'"; return 1; }
  [ "$actual" = "$DEPLOY_PIN_SHA256" ] \
    || { _dp_fail "ARCHIVE_DIGEST_MISMATCH : archive '$archive_in' porte $actual, le marqueur pinne $DEPLOY_PIN_SHA256"; return 1; }
  DEPLOY_PIN_ARCHIVE="$archive_in"

  export DEPLOY_PIN_COMMIT DEPLOY_PIN_VERSION DEPLOY_PIN_SHA256 \
         DEPLOY_PIN_PUBLISH DEPLOY_PIN_PROMOTE DEPLOY_PIN_CONTRACT DEPLOY_PIN_ARCHIVE
  return 0
}

# resolve_promotion_pin <clone> <api> <from_env>
#
# CE QU'UN SAUT PROMEUT : l'état que le palier SOURCE exécute — pas « le dernier
# main ».
#
# ⚠ C'EST LA LETTRE DU GOAL, et le premier jet ne la tenait pas. Le pin était
# `git log -1 main -- apis/<api>.*`, et le marqueur du palier source était
# ouvert puis jeté sauf `enabled`. Mesuré : rec servant v1.0.0, main à v2.0.0,
# une demande rec -> int écrivait v2.0.0 — un état que rec n'a JAMAIS servi, et
# rien ne rougissait. La chaîne à cinq paliers ne garantissait plus que homol a
# vu ce que int a vu.
#
# DEUX RÉGIMES, ET UN SEUL EST « le dernier main » :
#   from == authoring  -> dev n'a pas de marqueur, il suit HEAD par conception
#                         (pinned.go:15). Le pin est donc le dernier commit de
#                         main touchant CETTE API — pas HEAD, sinon une API
#                         soeur ferait bouger le pin. Le digest vient du
#                         formulaire (sortie EXPORT_CONFIRMED).
#   sinon              -> pin ET digest viennent du marqueur SOURCE. Le digest
#                         voyage donc avec le pin : c'est ce qui rend « build
#                         once, deploy many » VRAI plutôt que déclaratif.
#
# Exporte : DEPLOY_PROMO_PIN, DEPLOY_PROMO_SHA256, DEPLOY_PROMO_VERSION.
#
# Les deux valeurs remontent du python empaquetées PAR LIGNES, pas par un
# caractère séparateur. Ce n'est pas de la coquetterie : un `|` a déjà décalé
# des champs deux fois dans ce dépôt (marqueur, puis sonde d'import). Ici les
# deux valeurs sont hexadécimales et sont validées comme telles juste après —
# une nouvelle ligne ne peut donc pas s'y cacher. C'est ce qui rend le
# découpage par ligne sûr, et il faut le dire plutôt que prétendre qu'aucun
# empaquetage n'a lieu.
resolve_promotion_pin() {
  local clone="$1" api="$2" from="$3"

  DEPLOY_PROMO_PIN=""; DEPLOY_PROMO_SHA256=""; DEPLOY_PROMO_VERSION=""
  _src_version=""
  export DEPLOY_PROMO_PIN DEPLOY_PROMO_SHA256 DEPLOY_PROMO_VERSION

  case "$api" in
    ""|*[!a-z0-9-]*) { _dp_fail "API_NAME_INVALIDE : '$api'"; return 1; };;
  esac
  # `from` construit un chemin de marqueur, exactement comme `env` dans le
  # jumeau — il se contraint donc au meme endroit et de la meme facon.
  case "$from" in
    ""|*[!a-z0-9-]*) { _dp_fail "ENV_INVALIDE : '$from'"; return 1; };;
  esac

  if [ "$from" = "$DEPLOY_PIN_AUTHORING_ENV" ]; then
    # `git log -1` porte sur le HEAD du clone, pas litteralement sur `main` :
    # c'est la meme chose chez l'appelant actuel (clone frais, donc HEAD == main)
    # et ce serait faux ailleurs. Le refus le dit tel quel plutot que de promettre
    # « main ».
    DEPLOY_PROMO_PIN=$(git -C "$clone" log -1 --format=%H -- "apis/${api}.*")
    [ -n "$DEPLOY_PROMO_PIN" ] \
      || { _dp_fail "PIN_INTROUVABLE : aucun commit ne touche apis/${api}.* sur le HEAD du clone"; return 1; }
  else
    local rel; rel="$(deploy_pin_marker_path "$api" "$from")"
    [ -f "$clone/$rel" ] \
      || { _dp_fail "SOURCE_NON_DEPLOYEE : $rel absent — '$api' n'est pas deployee en '$from'"; return 1; }
    local raw
    # DEUX CAUSES, DEUX JETONS. Fondre « marqueur illisible » et « palier eteint »
    # dans un seul refus rendait un marqueur CORROMPU indiscernable d'un palier
    # volontairement arrete — et un grep de logs sur les jetons ne separait plus
    # les deux. Le python distingue donc par son CODE DE SORTIE : 3 = eteint,
    # tout autre echec = illisible.
    raw=$(DP_FILE="$clone/$rel" python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["DP_FILE"])) or {}
if not d.get("enabled"):
    sys.exit(3)
sys.stdout.write("SRC=1\n%s\n%s\n%s\n" % (
    str(d.get("commit") or ""),
    str(d.get("archive_sha256") or ""),
    str(d.get("version") or "")))
PY
)
    case "$?" in
      0) ;;
      3) { _dp_fail "SOURCE_NON_DEPLOYEE : $rel porte enabled: false — '$from' n'execute rien"; return 1; };;
      *) { _dp_fail "PARSE_MARQUEUR_SOURCE : $rel illisible (YAML)"; return 1; };;
    esac
    case "$raw" in SRC=1*) ;; *) { _dp_fail "PARSE_MARQUEUR_SOURCE : sortie inattendue de $rel"; return 1; };; esac
    DEPLOY_PROMO_PIN=$(printf '%s\n' "$raw" | sed -n '2p')
    DEPLOY_PROMO_SHA256=$(printf '%s\n' "$raw" | sed -n '3p')
    _src_version=$(printf '%s\n' "$raw" | sed -n '4p')
    # Le pin du palier source est celui qu'on RECOPIE : s'il est mal formé, on
    # ne le « corrige » pas en retombant sur main — ce serait rouvrir le défaut.
    case "$DEPLOY_PROMO_PIN" in
      *[!0-9a-f]*|"") { _dp_fail "SOURCE_PIN_MALFORMED : le marqueur $rel porte commit='$DEPLOY_PROMO_PIN'"; return 1; };;
    esac
    case "${#DEPLOY_PROMO_PIN}" in 40|64) ;;
      *) { _dp_fail "SOURCE_PIN_MALFORMED : commit de $rel long de ${#DEPLOY_PROMO_PIN} caracteres"; return 1; };;
    esac
    [ -n "$DEPLOY_PROMO_SHA256" ] \
      || { _dp_fail "SOURCE_DIGEST_ABSENT : le marqueur $rel ne porte pas d'archive_sha256 — impossible de faire voyager les memes octets"; return 1; }
    # ⚠ PAS DE GARDE D'ANCETRETE ICI, ET C'EST DELIBERE MAIS PAS GRATUIT.
    # Un marqueur source pinnant un commit vivant sur une branche jamais
    # fusionnee serait recopie tel quel dans le marqueur d'arrivee. Le filet
    # existe EN AVAL : resolve_deploy_pin refuse PIN_NON_ANCETRE a l'apply
    # (team-publish.sh). Un lecteur de CETTE fonction ne peut pas le deviner —
    # d'ou cette ligne. Poser la garde ici aussi serait mieux : il faudrait lui
    # passer la reference de comparaison, que cette fonction ne prend pas.
  fi

  # La version se lit AU COMMIT RETENU, jamais sur l'arbre de travail : sinon on
  # ecrirait la version de main a cote d'un pin qui designe autre chose.
  # ⚠ PAS DE PIPELINE ICI. Avec `git show … | python3 …`, le NOM du refus
  # dependait de `pipefail` chez l'appelant : sans lui, un pin irresoluble
  # faisait echouer `git show` en silence, python lisait un flux vide, et le cas
  # se disait VERSION_ABSENTE au lieu de PIN irresoluble. Fail-closed, mais mal
  # nomme — et un verdict trompeur coute plus cher qu'un refus brut. On separe.
  local blob mv
  blob=$(git -C "$clone" show "${DEPLOY_PROMO_PIN}:apis/${api}.publish.yml" 2>/dev/null) \
    || { _dp_fail "PIN_UNREADABLE : apis/${api}.publish.yml introuvable au commit ${DEPLOY_PROMO_PIN}"; return 1; }
  mv=$(printf '%s' "$blob" | python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin) or {}; print("V=" + str((d.get("apim_api") or {}).get("version") or ""))') \
    || { _dp_fail "PARSE_MANIFEST : apis/${api}.publish.yml illisible au commit ${DEPLOY_PROMO_PIN}"; return 1; }
  case "$mv" in V=*) mv="${mv#V=}";; *) { _dp_fail "PARSE_MANIFEST : sortie inattendue"; return 1; };; esac
  [ -n "$mv" ] \
    || { _dp_fail "VERSION_ABSENTE : apis/${api}.publish.yml ne porte pas de version au commit retenu"; return 1; }
  # M5 — le jumeau a PIN_VERSION_MISMATCH « pour attraper un marqueur edite a la
  # main apres coup ». Le meme risque existe ici : sans cette comparaison, un
  # marqueur source incoherent serait recopie en avant avec une version
  # silencieusement autre. Les deux valeurs sont deja en main.
  if [ -n "${_src_version:-}" ] && [ "$_src_version" != "$mv" ]; then
    _dp_fail "SOURCE_VERSION_MISMATCH : le marqueur de '$from' annonce '$_src_version' mais son propre pin porte '$mv' — marqueur incoherent, on ne le propage pas"
    return 1
  fi
  DEPLOY_PROMO_VERSION="$mv"
  return 0
}

# reconcile_promotion_digest <digest du formulaire> <digest herite du palier source>
#
# CE QUI TIENT L'ARBITRAGE, C'EST LE REFUS, PAS L'HERITAGE.
# Le digest reste EXIGE au formulaire a chaque saut (`TO_ENV` ne peut jamais
# valoir l'env d'authoring : c'est la TETE de la chaine, et une promotion va
# toujours vers le palier SUIVANT). Hors env d'authoring il n'est simplement
# plus CRU : il est confronte a celui du palier source, et une divergence
# refuse. Le demandeur ne peut donc pas substituer les octets en cours de
# route ; il peut seulement se tromper de recopie, et il est refuse.
#
# Cette fonction vit ici, et non au site d'appel, pour la meme raison que
# resolve_promotion_pin : au site d'appel elle serait dans le chemin
# post-DRY_RUN, qu'aucune epreuve n'exerce — une garantie sans porte.
#
# Rend sur stdout le digest RETENU.
reconcile_promotion_digest() {
  local form="$1" inherited="$2"
  if [ -z "$inherited" ]; then
    printf '%s' "$form"          # depuis l'env d'authoring : le formulaire fait foi
    return 0
  fi
  if [ -n "$form" ] && [ "$form" != "$inherited" ]; then
    _dp_fail "DIGEST_CONTREDIT_SOURCE : le formulaire annonce $form mais le palier source execute $inherited — un saut ne substitue pas les octets"
    return 1
  fi
  printf '%s' "$inherited"
  return 0
}
