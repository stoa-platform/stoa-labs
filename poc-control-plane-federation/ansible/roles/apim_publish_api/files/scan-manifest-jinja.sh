#!/usr/bin/env bash
# scan-manifest-jinja.sh — refuse tout motif Jinja ({{ ou {%) dans un
# manifeste de publication, SAUF le fragment légitime du gabarit `contract`
# (posé par api-request.sh, gateways/templates/publish.yml.tmpl).
#
# POURQUOI CE SCRIPT EXTERNE, PAS DE L'ANSIBLE INLINE (panel Fix round 2,
# item A1b). Ansible re-template PARESSEUSEMENT/RÉCURSIVEMENT toute chaîne
# qui ressemble à un gabarit dès qu'elle est référencée à l'intérieur d'un
# AUTRE bloc Jinja — y compris une chaîne qu'on écrit SOI-MÊME dans une tâche
# du rôle si elle contient elle-même "{{"/"{%" (constaté en direct : un
# `that:`/`set_fact` portant ces caractères, même échappés par un backslash,
# fait choper le LEXER Jinja lui-même AVANT toute évaluation — le backslash
# n'a aucun sens pour Jinja). Le SEUL moyen fiable de comparer du texte
# contenant "{{"/"{%" est de ne JAMAIS le faire transiter par le moteur de
# templating d'Ansible : ce script tourne comme process ENFANT, lit le
# fichier depuis le disque, compare en PYTHON PUR (aucun import Jinja) — le
# contenu du manifeste ne touche JAMAIS Ansible tant que ce script n'a pas
# statué.
#
# APPELÉ AVANT tout include_vars/référence à apim_api (manifest-guard.yml) :
# le pin côté rôle (apim_ss_contract_pin, resolve-env.yml) ne suffit PAS —
# prouvé par contre-épreuve (panel Fix round 2) qu'Ansible EXÉCUTE un Jinja
# injecté dans apim_api AVANT de l'écraser par le combine() du pin (le
# `lookup('pipe', …)` d'un manifeste malveillant tourne pendant
# `apim_api | combine({'contract': pin})`, PAS après). La fermeture RÉELLE
# reste team-publish.sh §4 (MANIFEST_CONTRACT_INVALIDE, hors ligne, AVANT
# tout ansible-playbook) ; ce scan est une SECONDE couche fail-closed pour
# les appelants qui n'ont pas cette garde en amont (jamais une garantie
# redondante avec elle).
#
# Sortie : "UNSAFE" (motif détecté, hors du fragment légitime) ou "CLEAN".
# Code de sortie : toujours 0 si le script a pu lire/analyser le fichier
# (le VERDICT est dans stdout, pas le code de retour — l'appelant Ansible
# décide via `'UNSAFE' in ....stdout`) ; non-zéro seulement si le fichier
# est illisible (échec d'exécution, distinct d'un verdict UNSAFE).
set -euo pipefail
FILE="${1:?usage: scan-manifest-jinja.sh <manifest-path>}"
[ -r "$FILE" ] || { echo "SCAN_ERROR: fichier illisible: $FILE" >&2; exit 2; }

# Fragment EXACT du gabarit légitime (gateways/templates/publish.yml.tmpl,
# le seul endroit où "{{"/"{%" a le droit d'apparaître dans un manifeste).
SAFE_FRAGMENT="{{ (pub_manifest_path | dirname) }}"

FILE="$FILE" SAFE_FRAGMENT="$SAFE_FRAGMENT" python3 - <<'PY'
import os
path = os.environ["FILE"]
safe = os.environ["SAFE_FRAGMENT"]
with open(path, encoding="utf-8") as f:
    text = f.read()
# Neutralise l'UNIQUE occurrence du fragment légitime avant de chercher tout
# motif Jinja RESTANT. Comparaison sur le TEXTE, pas sur la position/clé
# YAML : si ce fragment (inoffensif en lui-même — un simple dirname, aucune
# exécution) apparaissait ailleurs que dans contract, au pire une SEULE de
# ses occurrences serait neutralisée et l'autre resterait détectée UNSAFE —
# jamais l'inverse (aucun scénario ne fait disparaître un motif RÉELLEMENT
# dangereux). Fail-closed : une ambiguïté se résout toujours vers le refus.
checked = text.replace(safe, "", 1)
print("UNSAFE" if ("{{" in checked or "{%" in checked) else "CLEAN")
PY
