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

deploy_pin_marker_path() { printf 'apis/%s.deploy.%s.yaml' "$1" "$2"; }

# Nomme le refus sur stderr. Toujours appelé comme une INSTRUCTION suivie d'un
# `return 1` explicite — jamais `return $(_dp_fail …)`. Cette dernière forme
# « marche » (return sans argument rend le statut de la dernière commande) mais
# elle est illisible et se casse au premier refactor : un message qui écrirait
# par erreur sur stdout deviendrait l'argument de `return`, donc un code de
# sortie absurde ou une erreur de syntaxe.
_dp_fail() { printf 'deploy-pin: %s\n' "$*" >&2; }

# resolve_deploy_pin <clone_dir> <api_name> <env> <workdir>
resolve_deploy_pin() {
  local clone="$1" api="$2" env="$3" work="$4"

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

  mkdir -p "$work" || return 1
  # publish.yml et openapi.yaml sont TOUJOURS présents — api-request.sh les pose
  # ENSEMBLE, au même commit (team-publish.sh:259 refuse déjà CONTRAT_ABSENT).
  local f
  for f in publish.yml openapi.yaml; do
    local src="apis/${api}.${f}" dst="$work/${api}.${f}"
    git -C "$clone" show "${DEPLOY_PIN_COMMIT}:${src}" > "$dst" 2>/dev/null \
      || { _dp_fail "PIN_UNREADABLE : git show ${DEPLOY_PIN_COMMIT}:${src} a échoué — le pin ne se résout pas, refus (jamais de repli sur HEAD)"; return 1; }
  done

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
  export DEPLOY_PIN_COMMIT DEPLOY_PIN_VERSION DEPLOY_PIN_SHA256 \
         DEPLOY_PIN_PUBLISH DEPLOY_PIN_PROMOTE DEPLOY_PIN_CONTRACT
  return 0
}
