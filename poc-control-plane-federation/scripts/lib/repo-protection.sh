#!/usr/bin/env bash
# repo-protection.sh — pose IDEMPOTENTE d'une branch protection Gitea.
# (G4, ADR-082, mécanismes M2/M3.) SOURCÉE, jamais exécutée.
#
# Ce que la protection tient, et ce qu'elle NE tient PAS :
#   Baseline SÛRE = enable_push + enable_push_whitelist. Personne hors de la
#   whitelist ne pousse la branche protégée ; tout le reste passe par PR. C'est
#   ce qui sort la définition de pipeline et la référence de déploiement du
#   périmètre d'ÉCRITURE DIRECTE du demandeur.
#   La sémantique de `protected_file_patterns` (Gitea 1.22) n'est PAS SUPPOSÉE
#   ici : personne n'a mesuré si elle bloque aussi le MERGE d'une PR, ou
#   seulement le push direct, ni ce qu'elle fait d'un admin d'organisation.
#   test-repo-protections-live.sh (Task 9) la MESURE ; le poseur n'émet des
#   patterns que là où la mesure a statué. Tant qu'elle n'a pas statué, le
#   champ reste ABSENT du payload — un champ posé « au cas où » se lit comme
#   une garantie et n'en est pas une.
#
# HYPOTHÈSE NON MESURÉE — la sémantique de FUSION du PATCH (Gitea 1.22).
#   `pose_branch_protection` est dit « idempotent » : GET, puis POST 201 si la
#   protection est absente, PATCH 200 si elle existe. Le PATCH n'envoie que les
#   champs de CE payload. Personne n'a mesuré ce que Gitea fait des champs
#   ABSENTS du corps : les PRÉSERVE-t-il (fusion), ou les RÉINITIALISE-t-il à
#   leur défaut (remplacement) ?
#   Conséquence si c'est un remplacement : un passage du poseur baseline
#   (setup-repo-protections.sh, ou l'appel de team-apply) sur un dépôt dont un
#   exploitant a posé À LA MAIN des options plus riches — protected_file_patterns,
#   approbations requises, whitelist de merge — les EFFACERAIT EN SILENCE. Le
#   PATCH rendrait 200, le poseur dirait ✅, et la protection serait plus faible
#   qu'avant. « Idempotent » ne veut donc PAS encore dire « non destructif ».
#   Sémantique de fusion du PATCH : MESURÉE PAR test-repo-protections-live.sh
#   (T9) — tant que la mesure n'a pas tourné, ne pas re-passer le poseur baseline
#   sur un dépôt porteur d'options posées à la main.
#
# Secrets : le token ne transite JAMAIS par argv ni par une URL — l'appelant
# construit un fichier d'en-tête (`Authorization: token …`) que curl lit via
# `-H @fichier`, motif déjà en place dans team-apply.sh (:149) et ailleurs.

repo_protection_payload() { # <branch> <push_whitelist_csv> [file_patterns]
  # JSON émis par python3/json.dumps, JAMAIS par formatage de chaîne : un nom
  # de branche ou d'utilisateur portant un guillemet casserait un `printf`, ou
  # pire y injecterait une clé de protection que personne n'a demandée.
  [ $# -ge 2 ] || { echo "PROTECTION_PAYLOAD_USAGE : repo_protection_payload <branch> <whitelist_csv> [patterns]" >&2; return 1; }
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, sys
branch, wl, patterns = sys.argv[1], sys.argv[2], sys.argv[3]
p = {
    "branch_name": branch,
    "enable_push": True,
    "enable_push_whitelist": True,
    "push_whitelist_usernames": [u for u in wl.split(",") if u],
}
if patterns:
    p["protected_file_patterns"] = patterns
print(json.dumps(p))
PY
}

pose_branch_protection() { # <host> <header_file> <owner/repo> <payload_file>
  # header_file : fichier portant `Authorization: token …` (jamais argv).
  # Idempotent : GET pour savoir si la protection existe, puis POST 201 (absente)
  # ou PATCH 200 (présente — l'état converge, une whitelist élargie s'applique).
  [ $# -eq 4 ] || { echo "PROTECTION_NON_POSEE : usage <host> <header_file> <owner/repo> <payload_file>" >&2; return 1; }
  local host="$1" hdrf="$2" repo="$3" payload="$4"
  local branch out code
  [ -f "$payload" ] || { echo "PROTECTION_NON_POSEE : payload introuvable ($payload)" >&2; return 1; }
  [ -f "$hdrf" ] || { echo "PROTECTION_NON_POSEE : fichier d'en-tête introuvable ($hdrf)" >&2; return 1; }
  # La branche vient du payload LUI-MÊME (json), pas d'un 5e argument : un
  # seul point de vérité, impossible de patcher `main` avec un payload `rec`.
  branch="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["branch_name"])' "$payload" 2>/dev/null)" \
    || { echo "PROTECTION_NON_POSEE : payload illisible ($payload)" >&2; return 1; }
  [ -n "$branch" ] || { echo "PROTECTION_NON_POSEE : branch_name vide dans $payload" >&2; return 1; }
  out="$(mktemp)"
  # `--connect-timeout`/`--max-time` sur les trois appels : ce code tourne dans
  # un job post-merge. Un hôte qui répond RST rend la main tout de suite, mais un
  # hôte qui AVALE les paquets (règle DROP, VIP morte) ferait attendre le job
  # indéfiniment — un onboarding suspendu pour une protection best-effort.
  # `|| true` sur les trois captures : curl injoignable sort non nul TOUT EN
  # imprimant `000` via -w. Sans lui, un appelant en `set -e` qui n'invoque pas
  # cette fonction depuis une condition mourrait sur l'affectation au lieu de
  # lire le refus nommé ci-dessous. Le code lu reste `000` — donc le refus dit
  # bien « HTTP 000 », il n'est pas dilué.
  code="$(curl -s --connect-timeout 10 --max-time 30 -o "$out" -w '%{http_code}' -H @"$hdrf" \
    "$host/api/v1/repos/$repo/branch_protections/$branch")" || true
  case "$code" in
    200)
      code="$(curl -s --connect-timeout 10 --max-time 30 -o "$out" -w '%{http_code}' -X PATCH -H @"$hdrf" \
        -H 'Content-Type: application/json' --data-binary @"$payload" \
        "$host/api/v1/repos/$repo/branch_protections/$branch")" || true
      [ "$code" = 200 ] || { echo "PROTECTION_NON_POSEE : PATCH $repo@$branch -> HTTP $code $(head -c 200 "$out")" >&2; rm -f "$out"; return 1; }
      ;;
    404)
      code="$(curl -s --connect-timeout 10 --max-time 30 -o "$out" -w '%{http_code}' -X POST -H @"$hdrf" \
        -H 'Content-Type: application/json' --data-binary @"$payload" \
        "$host/api/v1/repos/$repo/branch_protections")" || true
      [ "$code" = 201 ] || { echo "PROTECTION_NON_POSEE : POST $repo@$branch -> HTTP $code $(head -c 200 "$out")" >&2; rm -f "$out"; return 1; }
      ;;
    *) echo "PROTECTION_NON_POSEE : GET $repo@$branch -> HTTP $code $(head -c 200 "$out")" >&2; rm -f "$out"; return 1 ;;
  esac
  rm -f "$out"
  return 0
}
