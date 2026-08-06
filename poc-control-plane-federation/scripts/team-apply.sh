#!/usr/bin/env bash
# team-apply.sh — l'APPLY d'onboarding, APRÈS la décision humaine (le merge).
#
#   merge PR onboard/* → webhook → job team-apply (pause nominative + garde
#   d'identité, cf. le job XML) → CE script :
#     1. ANTI-TOCTOU : checkout de main AU SHA DU MERGE ; l'équipe est lue dans
#        providers.<env>.yml TEL QUE MERGÉ — jamais dans le payload du webhook.
#     2. dépôt Gitea depuis le squelette ADR-076 (token org-admin lu dans Vault,
#        header-file). IDEMPOTENT : dépôt existant → sauté, dit dans le commentaire.
#        repo: "" dans providers → étape sautée (cas payments-team), PAS un échec.
#     3. ansible/onboard-team.yml (rôle idempotent du palier 1).
#     4. commentaire PR : le statut RÉEL, succès comme échec (ADR-081 coroll. 2).
#
# Invocation attendue (miroir de team-request.sh, Task 5/ci/jenkins/team-apply.job.xml) :
#   dir('poc-control-plane-federation') { sh 'bash scripts/team-apply.sh' } — donc
# $0 = "scripts/team-apply.sh" et le `cd "$(dirname "$0")/.."` ci-dessous NE
# BOUGE PAS le cwd (déjà poc-control-plane-federation/, "scripts/.." s'annule).
# Toutes les références de fichier plus bas (PROV, clients/_example, ansible/…)
# sont donc relatives à CE cwd, SANS le préfixe "poc-control-plane-federation/"
# (celui-ci n'a de sens que dans un CLONE FRAIS du dépôt plateforme entier —
# motif utilisé par team-request.sh pour son propre WORK/repo, différent).
set -uo pipefail
set +x   # jamais de trace : le token ne doit pas fuiter
cd "$(dirname "$0")/.." || exit 1

PR_BRANCH="${PR_BRANCH:?PR_BRANCH requis}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
MERGE_SHA="${MERGE_SHA:?MERGE_SHA requis (merge_commit_sha du webhook)}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR requis}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:?VAULT_TOKEN_FILE requis (jamais le token en env/argv)}"
APIM_API_BASE="${APIM_API_BASE:?APIM_API_BASE requis — pas de défaut : dire sa cible est volontaire}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; umask 077
fail(){ comment "❌ team-apply : $*"; echo "ERREUR: $*" >&2; exit 1; }
comment(){ API="${GIT_HOST}/api/v1" GIT_REPO="$GIT_REPO" GITEA_TOKEN="$GITEA_TOKEN" \
  PR="$PR_NUMBER" BODY="$1" python3 - <<'PY'
import json, os, urllib.request
api, repo, tok = os.environ["API"], os.environ["GIT_REPO"], os.environ["GITEA_TOKEN"]
req = urllib.request.Request(f"{api}/repos/{repo}/issues/{os.environ['PR']}/comments",
    method="POST", data=json.dumps({"body": os.environ["BODY"]}).encode(),
    headers={"Authorization": f"token {tok}", "Content-Type": "application/json"})
urllib.request.urlopen(req)
PY
}

# ── 1. équipe et env depuis la branche ; anti-TOCTOU sur le contenu ──────────
case "$PR_BRANCH" in onboard/*) ;; *) echo "hors onboard/* — rien à faire"; exit 0;; esac
REST="${PR_BRANCH#onboard/}"; ENVN="${REST##*-}"; TEAM="${REST%-*}"
[ "$ENVN" = dev ] || fail "ENV_NOT_OPEN : $ENVN"

git fetch -q origin main && git checkout -q "$MERGE_SHA" \
  || fail "checkout du SHA de merge $MERGE_SHA"
PROV="ansible/providers.${ENVN}.yml"
grep -Eq "^  - team: ${TEAM}\$" "$PROV" \
  || fail "TEAM_NOT_IN_MERGED_STATE : ${TEAM} absente de ${PROV} au SHA mergé — le payload ne fait pas foi"
# REVUE (Important) : la 1ère version n'avait aucun `|| fail` sur cette
# extraction — une exception Python (YAML malformé, équipe absente malgré le
# grep texte du dessus) laissait REPO_FULL vide EN SILENCE, et le script
# prenait alors le chemin « repo vide dans providers » comme si c'était le
# cas légitime payments-team : un commentaire ✅ trompeur possible. Même
# classe de bug que le Critical de la Task 3 (extraction entre appels gardés
# = le point aveugle). Deux verrous : (1) `|| fail` sur l'échec du process
# python lui-même (exception -> exit non nul, capté par `||`) ; (2) un
# marqueur explicite `REPO=` en préfixe de sortie — un python qui réussirait
# SANS lever mais sans imprimer ce préfixe (sortie inattendue) est aussi
# refusé, pour ne jamais confondre « champ repo légitimement absent/vide »
# (le marqueur est présent, la valeur après lui est vide) et « extraction
# cassée » (marqueur absent).
REPO_FULL=$(TEAM="$TEAM" PROV="$PROV" python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["PROV"]))
e = next((p for p in d["providers"] if p["team"] == os.environ["TEAM"]), None)
if e is None:
    sys.exit("TEAM_NOT_FOUND_IN_PARSE : incohérence grep vs yaml.safe_load")
print("REPO=" + (e.get("repo") or ""))
PY
) || fail "PARSE_PROVIDERS : lecture du champ repo de ${TEAM} dans ${PROV} — $REPO_FULL"
case "$REPO_FULL" in
  REPO=*) REPO_FULL="${REPO_FULL#REPO=}";;
  *) fail "PARSE_PROVIDERS : sortie inattendue de l'extraction repo pour ${TEAM} (ni échec ni marqueur REPO=)";;
esac

# ── 2. dépôt Gitea (idempotent ; token org-admin lu dans Vault) ──────────────
REPO_NOTE="dépôt : (repo vide dans providers — étape sautée)"
if [ -n "$REPO_FULL" ]; then
  # ÉCART AU BRIEF (bug corrigé, constaté en direct) : VAULT_TOKEN_FILE contient
  # le token BRUT (ci/lib/vault-login.sh:135-147 — _vault_store_token écrit
  # "token" nu ET "token.hdr" séparément ; seul le premier est exporté sous ce
  # nom, celui que l'apim_common Ansible consomme via lookup('file', …)). Un
  # `curl -H @"$VAULT_TOKEN_FILE"` direct (le texte du brief) n'a AUCUNE ligne
  # "Nom: valeur" à envoyer — le token part sans header, Vault répond 403
  # partout, reproduit en direct sur ce Vault. On construit ici notre PROPRE
  # fichier d'en-tête (même motif que vhdr()/vcurl() ailleurs dans ce dépôt) à
  # partir du contenu brut, sans jamais faire transiter le token par argv/env.
  printf 'X-Vault-Token: %s\n' "$(cat "$VAULT_TOKEN_FILE")" > "$TMP/vthdr"
  curl -s -H @"$TMP/vthdr" "$VAULT_ADDR/v1/secret/data/stoa/ci/gitea-org-admin" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['token'])" > "$TMP/gt" \
    || fail "lecture du token org-admin dans Vault (policy team-onboarder ?)"
  printf 'Authorization: token %s\n' "$(cat "$TMP/gt")" > "$TMP/ghdr"
  ORG="${REPO_FULL%%/*}"; RNAME="${REPO_FULL##*/}"
  gapi(){ curl -s -H @"$TMP/ghdr" -H 'Content-Type: application/json' "$@"; }
  # org : create-or-skip
  RC=$(gapi -o /dev/null -w '%{http_code}' "${GIT_HOST}/api/v1/orgs/${ORG}")
  if [ "$RC" != 200 ]; then
    RC=$(gapi -X POST -d "{\"username\":\"${ORG}\"}" -o "$TMP/err" -w '%{http_code}' "${GIT_HOST}/api/v1/orgs")
    { [ "$RC" = 201 ] || [ "$RC" = 200 ]; } || fail "création org ${ORG} (HTTP $RC)"
  fi
  # repo : trois états, pas deux (REVUE Important) — le test d'existence
  # jetait le corps de la réponse (`-o /dev/null`), donc ne regardait jamais
  # le champ `empty` de l'API Gitea. Un dépôt CRÉÉ (par un run précédent) dont
  # le push du squelette avait échoué pour une raison résiduelle (réseau, panne
  # Gitea, etc.) était alors déclaré « déjà existant, étape sautée » à chaque
  # re-run et restait bloqué vide pour toujours — aucune réparation
  # automatique, alors que le rôle Ansible (§3) est lui bien rejouable.
  # Vérifié en direct (2026-08-05, curl+API Gitea réel) : un dépôt créé
  # SANS jamais y pousser expose bien "empty": true dans la réponse GET.
  # Trois états, donc trois notes distinctes :
  #   absent            -> créer + pousser (cas normal)
  #   existant ET vide   -> pousser SEULEMENT (réparation d'un run précédent)
  #   existant NON vide  -> sauté (idempotence réelle)
  RC=$(gapi -o "$TMP/repoinfo" -w '%{http_code}' "${GIT_HOST}/api/v1/repos/${REPO_FULL}")
  PUSH_SKELETON=0
  if [ "$RC" != 200 ]; then
    RC=$(gapi -X POST -d "{\"name\":\"${RNAME}\",\"auto_init\":false}" -o "$TMP/err" -w '%{http_code}' "${GIT_HOST}/api/v1/orgs/${ORG}/repos")
    [ "$RC" = 201 ] || fail "création dépôt ${REPO_FULL} (HTTP $RC)"
    PUSH_SKELETON=1
    REPO_NOTE="dépôt ${REPO_FULL} : créé depuis le squelette ADR-076"
  else
    # Même discipline fail-closed que l'extraction REPO_FULL ci-dessus :
    # HTTP 200 ne garantit pas un parse réussi — un JSON inattendu ou un champ
    # `empty` absent doit refuser, pas être lu comme "non vide" par défaut
    # (un défaut silencieux là laisserait un dépôt vide non réparé, exactement
    # le bug que cette revue corrige).
    IS_EMPTY=$(python3 -c "import json; print('1' if json.load(open('$TMP/repoinfo'))['empty'] else '0')" 2>"$TMP/perr") \
      || fail "lecture du champ 'empty' du dépôt ${REPO_FULL} (HTTP 200, parse en échec) : $(cat "$TMP/perr")"
    if [ "$IS_EMPTY" = 1 ]; then
      PUSH_SKELETON=1
      REPO_NOTE="dépôt ${REPO_FULL} : existant VIDE, squelette poussé — réparation d'un run précédent"
    else
      REPO_NOTE="dépôt ${REPO_FULL} : déjà existant, étape sautée (idempotence)"
    fi
  fi
  if [ "$PUSH_SKELETON" = 1 ]; then
    SK="$TMP/skel"; mkdir -p "$SK"
    cp -R clients/_example/. "$SK/"
    printf '# %s\n\nDépôt d équipe (squelette ADR-076 : apis/, applications/).\nCréé par team-apply au merge de la PR #%s.\n' "$REPO_FULL" "$PR_NUMBER" > "$SK/README.md"
    git -C "$SK" init -q -b main && git -C "$SK" add -A \
      && git -C "$SK" -c user.name=ci -c user.email=ci@stoa.lab commit -qm "squelette ADR-076 (team-apply, PR #${PR_NUMBER})"
    # ÉCART AU BRIEF (bug corrigé, constaté en direct) : le brief (comme
    # team-request.sh/provision-request.sh) met le token dans l'URL
    # (http://x:$TOKEN@host/...) passée en argv à `git push`. Mesuré en
    # direct (ps -Aww pendant un vrai run) : le token org-admin apparaît EN
    # CLAIR dans l'argv du process `git push` ET de son enfant
    # `git-remote-http` pendant toute la durée du push — exactement ce que la
    # preuve 8 du palier (sondage ps -ww) est censée détecter. On passe donc
    # le credential par un HEADER injecté via variables d'ENVIRONNEMENT
    # (GIT_CONFIG_COUNT/KEY/VALUE — jamais argv, jamais visible par `ps -ww`,
    # vérifié en direct par le même sondage) plutôt que dans l'URL ; l'URL
    # elle-même ne porte plus aucun credential.
    AUTH_B64=$(printf 'x:%s' "$(cat "$TMP/gt")" | base64 | tr -d '\n')
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
      GIT_CONFIG_VALUE_0="Authorization: Basic ${AUTH_B64}" \
      git -C "$SK" push -q "${GIT_HOST}/${REPO_FULL}.git" main 2>"$TMP/pe" \
      || { cat "$TMP/pe" >&2; fail "push du squelette"; }
    unset AUTH_B64
  fi

  # ── webhook pull_request -> team-publish (Task 7, extension a) ────────────
  # IDEMPOTENT (GET puis POST si absent) : un hook existant portant la MÊME
  # URL cible est sauté et dit — jamais un doublon (un dépôt déjà réparé, ou
  # un re-run après incident, ne double pas le déclenchement). Posé qu'il
  # s'agisse d'un dépôt fraîchement créé OU déjà existant (pas seulement
  # PUSH_SKELETON=1) : un dépôt onboardé AVANT que cette extension n'existe
  # doit pouvoir rattraper son webhook au run suivant.
  #
  # ÉCHEC NOMMÉ, PAS SILENCIEUX (brief) — à la différence de la re-pose plus
  # bas (⚠, purement best-effort) : un dépôt SANS ce webhook ne déclenchera
  # JAMAIS team-publish tant que personne ne le répare à la main, ce n'est pas
  # une liste qui se rafraîchit toute seule au run suivant. Marqué ❌ dans le
  # commentaire — mais n'appelle PAS fail() : l'onboarding lui-même (le rôle
  # Ansible, §3) est indépendant du webhook, et le retarder d'un geste manuel
  # reste possible sans reprendre tout l'onboarding.
  WEBHOOK_URL="${TEAM_PUBLISH_WEBHOOK_URL:-http://jenkins:8080/generic-webhook-trigger/invoke?token=stoa-team-publish}"
  RC=$(gapi -o "$TMP/hooks" -w '%{http_code}' "${GIT_HOST}/api/v1/repos/${REPO_FULL}/hooks")
  if [ "$RC" = 200 ]; then
    HOOK_STATE=$(WEBHOOK_URL="$WEBHOOK_URL" python3 -c "
import json, os
hooks = json.load(open('$TMP/hooks'))
target = os.environ['WEBHOOK_URL']
print('FOUND' if any((h.get('config') or {}).get('url') == target for h in hooks) else 'ABSENT')
" 2>"$TMP/hookperr")
    case "$HOOK_STATE" in
      FOUND)
        WEBHOOK_NOTE=" ; webhook team-publish : déjà enregistré (idempotence)"
        ;;
      ABSENT)
        HOOK_BODY="$TMP/hookbody.json"
        printf '{"type":"gitea","config":{"url":"%s","content_type":"json"},"events":["pull_request"],"active":true}' \
          "$WEBHOOK_URL" > "$HOOK_BODY"
        RC2=$(gapi -X POST -d @"$HOOK_BODY" -o "$TMP/hookerr" -w '%{http_code}' "${GIT_HOST}/api/v1/repos/${REPO_FULL}/hooks")
        if [ "$RC2" = 201 ]; then
          WEBHOOK_NOTE=" ; webhook team-publish : enregistré"
        else
          WEBHOOK_NOTE=" ; ❌ webhook team-publish NON enregistré (HTTP ${RC2}) — team-publish ne se déclenchera pas sur ce dépôt tant qu'il n'est pas réparé à la main"
          echo "AVERTISSEMENT: enregistrement du webhook team-publish en échec (HTTP ${RC2}) : $(cat "$TMP/hookerr")" >&2
        fi
        ;;
      *)
        WEBHOOK_NOTE=" ; ❌ webhook team-publish : état indéterminé (liste des hooks illisible) — vérifier à la main"
        echo "AVERTISSEMENT: lecture des hooks existants du dépôt ${REPO_FULL} illisible : $(cat "$TMP/hookperr")" >&2
        ;;
    esac
  else
    WEBHOOK_NOTE=" ; ❌ webhook team-publish NON enregistré (liste des hooks illisible, HTTP ${RC}) — vérifier à la main"
    echo "AVERTISSEMENT: lecture des hooks existants du dépôt ${REPO_FULL} en échec (HTTP ${RC})" >&2
  fi
  REPO_NOTE="${REPO_NOTE}${WEBHOOK_NOTE}"
fi

# REVUE (point hérité du brief de cette tâche) : GIT_WEB_HOST était déclaré
# mais jamais utilisé — l'intention était le lien humain dans le commentaire
# ✅, même convention que provision-plan.sh:82-88 (URL construite depuis
# GIT_WEB_HOST, pas GIT_HOST — le lien doit être cliquable pour un humain,
# GIT_HOST peut être un nom interne au cluster non résolu hors des
# conteneurs).
REPO_LINK=""
[ -n "$REPO_FULL" ] && REPO_LINK=" ([${REPO_FULL}](${GIT_WEB_HOST}/${REPO_FULL}))"

# ── 3. onboarding (rôle du palier 1, idempotent) ─────────────────────────────
( ansible-playbook -i ansible/inventory.lab.ini ansible/onboard-team.yml \
    -e "apim_onb_team=${TEAM}" -e "apim_onb_providers_file=providers.${ENVN}.yml" \
    -e "apim_ss_api_base=${APIM_API_BASE}" \
) >"$TMP/onb.log" 2>&1
ONB_RC=$?

# ── 4. le statut RÉEL sur la PR — succès comme échec ─────────────────────────
if [ "$ONB_RC" -eq 0 ]; then
  SUMMARY=$(grep -oE '(ONBOARD_OK|VERIFY_[A-Z_]+|TEAM_[A-Z_]+|TENANT_ROOT_UNSAFE|KV_[A-Z_]+)[^"]*' "$TMP/onb.log" | tail -3 | tr '\n' ' ')

  # ── re-pose ÉVÉNEMENTIELLE des listes (Task 3, palier 3) ───────────────────
  # L'équipe qu'on vient d'onboarder doit apparaître dans les listes
  # déroulantes (app-request, api-request quand il existera) SANS attendre un
  # relance manuelle de setup-team-onboard-jobs.sh. BEST-EFFORT BRUYANT : à ce
  # point l'onboarding est déjà FAIT (ONB_RC=0, rôle Ansible idempotent
  # convergé) — un échec de re-pose ne l'annule PAS et n'appelle jamais
  # `fail` ; il est seulement NOMMÉ dans le commentaire ✅, pour qu'un humain
  # sache qu'il doit relancer la pose à la main. api-request n'existe pas
  # encore (Task 5) : setup-team-onboard-jobs.sh tolère proprement son
  # absence (avertit, ignore), donc CE code est déjà prêt pour lui.
  #
  # DÉFAUT IN-CLUSTER (fix mesuré, Task 7) : ce script tourne comme process
  # ENFANT du job Jenkins — "localhost" y désigne le CONTENEUR du job, pas
  # l'hôte. `http://localhost:18080` rendait la re-pose systématiquement
  # injoignable (curl "000") une fois JOUÉ EN JOB — jamais vu en test depuis
  # un poste (où "localhost" désigne bien Jenkins publié), toujours vu en job
  # réel. `jenkins:8080` est l'alias réseau in-cluster déjà utilisé pour
  # webmethods-mock/gitea (même convention). Un poste hors du réseau compose
  # surcharge JENKINS_UI explicitement (comme APIM_API_BASE).
  REFRESH_NOTE=""
  if JENKINS_UI="${JENKINS_UI:-http://jenkins:8080}" JOBS="app-request api-request" \
     ENVN="$ENVN" bash scripts/setup-team-onboard-jobs.sh >"$TMP/refresh.log" 2>&1
  then
    # REVUE (round 1, Important) : la re-pose peut RÉUSSIR tout en ayant
    # toléré/sauté un dépôt d'équipe déclaré mais introuvable sur Gitea
    # (generate_choices_apis, réserve 3 du rapport) — ce cas émet
    # CHOICES_SKIPPED_REPOS=<n> sur stderr (marqueur explicite, motif du
    # palier 2), qui atterrit dans CE log (stdout+stderr confondus) même sur
    # le chemin de succès. Sans ce grep, la moitié "signal" de la tolérance
    # ne sortait jamais du process : une re-pose verte pouvait cacher en
    # silence une équipe manquante — la moitié de fail-open exacte que la
    # revue a nommée. `tail -1` : au plus un marqueur par run (generate_
    # choices_apis n'est appelée qu'une fois par invocation de
    # setup-team-onboard-jobs.sh).
    SKIPPED=$(grep -oE 'CHOICES_SKIPPED_REPOS=[0-9]+' "$TMP/refresh.log" | tail -1 | cut -d= -f2)
    if [ -n "$SKIPPED" ] && [ "$SKIPPED" -gt 0 ]; then
      REFRESH_NOTE=" (listes rafraîchies ; ⚠ ${SKIPPED} dépôt(s) d'équipe déclarés mais absents, sautés)"
      echo "AVERTISSEMENT: listes rafraîchies mais ${SKIPPED} dépôt(s) d'équipe déclarés absents/sautés :" >&2
      tail -20 "$TMP/refresh.log" >&2
    else
      echo "listes rafraîchies (app-request, api-request si présent)"
    fi
  else
    REFRESH_NOTE=" ⚠ listes non rafraîchies — relancer setup-team-onboard-jobs.sh"
    echo "AVERTISSEMENT: re-pose des listes en échec — l'onboarding, lui, EST fait :" >&2
    tail -20 "$TMP/refresh.log" >&2
  fi

  comment "✅ team-apply ${TEAM}/${ENVN} — ${REPO_NOTE}${REPO_LINK} ; onboarding : ${SUMMARY:-ONBOARD_OK}${REFRESH_NOTE}"
else
  # ÉCART AU BRIEF (bug corrigé, constaté en direct) : le grep(tags) du brief
  # cherche UNIQUEMENT les marqueurs propres à apim_team_onboard (TEAM_*/KV_*/
  # VERIFY_*/…) — absents quand l'échec vient d'AILLEURS dans la chaîne (ex.
  # apim_common, résolution des creds admin gateway, cf. réserve Vault dans le
  # rapport). Résultat reproduit : le résumé affichait "TEAM_NAME_OK" — le
  # DERNIER tag de succès vu AVANT l'échec réel — sur une PR dont le run a EN
  # RÉALITÉ échoué. Sur échec, on préfère donc le message "msg" du dernier bloc
  # fatal/FAILED! Ansible, jamais un tag OK antérieur ; repli sur tail -3 brut
  # si aucun bloc fatal reconnaissable (même hiérarchie TAGS→brut que
  # team-request.sh §4).
  SUMMARY=$(grep -A6 'fatal:\|FAILED!' "$TMP/onb.log" | grep -oE '"msg":.*' | tail -1 | cut -c1-300)
  [ -n "$SUMMARY" ] || SUMMARY=$(tail -3 "$TMP/onb.log" | tr '\n' ' ')
  comment "❌ team-apply ${TEAM}/${ENVN} — ${REPO_NOTE} ; onboarding EN ÉCHEC : ${SUMMARY:-voir le build}. Re-run possible : tout est idempotent."
  fail "onboarding (voir log du build)"
fi
echo "team-apply OK — ${REPO_NOTE}"
