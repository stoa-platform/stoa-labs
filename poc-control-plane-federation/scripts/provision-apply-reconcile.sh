#!/usr/bin/env bash
# provision-apply-reconcile.sh — la RÉCONCILIATION de provision-apply (A2, GOAL
# cd-applications) : le payload du webhook ne fait pas foi — ni sur l'état de la
# PR (Gitea), ni sur l'état de `main` (git).
#
# POURQUOI. Le déclencheur de provision-apply est un webhook au token GWT
# partagé, sans HMAC vérifié en aval (limite mesurée, cf. team-apply.sh §webhook).
# Un tir manuel — ou un « Redeliver » Gitea d'un vieux payload — peut donc
# prétendre N'IMPORTE QUOI : `merged:true` sur une PR ouverte, un
# `merge_commit_sha` d'une autre PR, un `merged_by` qui n'a rien mergé, ou
# rejouer à l'identique une PR RÉELLEMENT mergée dont le palier a été supplanté
# depuis. Avant A2, un tel payload ouvrait la pause et — si quelqu'un répondait —
# appliquait l'état de `main` ; avec A2 il projetterait le SHA demandé : la
# réconciliation est donc ce qui rend « projeter le SHA mergé » sûr.
#
# CE QUI EST VÉRIFIÉ, DANS L'ORDRE (chaque refus est nommé, stable, greppable) :
#   1. FORME, sans aucun appel réseau : PR_NUMBER entier, MERGE_SHA ^[0-9a-f]{40}$,
#      PR_BRANCH = provision/<app>-<env> (classes strictes : le chemin du
#      manifeste ne peut pas sortir de son dossier).
#   2. GITEA = LA VÉRITÉ sur la PR (GET authentifié, non falsifiable par un
#      payload) : merged === true · merge_commit_sha == MERGE_SHA ·
#      head.ref == PR_BRANCH · base.ref == main, sinon PAYLOAD_PERIME ; les
#      IDENTITÉS (merged_by.login, user.login) viennent de là, jamais du payload.
#   3. PÉRIMÈTRE de la PR (GET /pulls/<n>/files) : elle ne touche QUE son
#      manifeste et son certificat de palier — sinon PR_HORS_PERIMETRE (l'aval
#      checkoute l'arbre ENTIER au SHA mergé : une PR qui éditerait le rôle ou
#      un script s'exécuterait sous l'identité du valideur).
#   4. GIT = LA VÉRITÉ sur main : MERGE_SHA est un ancêtre de origin/main
#      (MERGE_SHA_NON_ANCETRE) et le manifeste EFFECTIF du palier au SHA mergé
#      est encore celui que main porte pour ce palier — sinon
#      PALIER_SUPPLANTE (un rejeu d'une PR ancienne ne re-projette jamais un
#      état que main a dépassé ; granularité = le palier, via
#      app_manifest_digest_env : une PR foo-dev postérieure ne bloque pas foo-rec).
#
# Tourne AVANT la pause : personne n'est réveillé pour un payload forgé ou périmé.
#
# COMMENTAIRE SUR LA PR — deux règles, mesurées à la critique de la spec :
#   - on ne commente QUE si la PR a été RELUE sur Gitea et que SON head.ref (relu,
#     pas celui du payload) est en provision/* : un PR_NUMBER forgé ne fait pas
#     publier le compte de service sur une PR étrangère ; refus de forme, 404,
#     500, JSON illisible ⇒ journal + rc 1 seulement ;
#   - le refus part sous le marqueur `<!-- provision-apply-refus -->`, DISTINCT
#     de celui du résultat d'apply : un webhook forgé ne peut pas PATCHer
#     l'enregistrement SHA/digest d'un apply réel ;
#   - un refus de FORME ne recopie jamais la valeur refusée dans un message :
#     le journal la montre tronquée et échappée (`printf %q`), c'est tout.
#
# Entrées (env) :
#   PR_BRANCH, PR_NUMBER, MERGE_SHA   (req) la charge utile du webhook (GenericTrigger)
#   GITEA_TOKEN                        (req) jamais en argv, jamais loggé
#   RECONCILE_OUT                      (req) fichier de sortie KEY=VALUE, lu par le pipeline
#   RECONCILE_FACTS                    (opt) fichier écrit DÈS la relecture Gitea (GITEA_HEAD_REF=…),
#                                            succès comme échec — c'est lui qui autorise le
#                                            statut build du post{always}
#   GIT_HOST (défaut http://gitea:3000) · GIT_REPO (défaut ci/stoa-labs)
#   GIT_WEB_HOST (lien humain du commentaire, défaut GIT_HOST)
#   GIT_WORKTREE (défaut . = poc-control-plane-federation/ dans le workspace : là où
#                 `git fetch origin main` et `git show` tournent)
#   GIT_SUBDIR   (défaut poc-control-plane-federation : préfixe des chemins vus par la forge)
#   MANIFEST_DIR (défaut clients/provisioned/applications, relatif à GIT_WORKTREE)
#
# Sortie (RECONCILE_OUT) : GITEA_MERGED_BY= GITEA_REQUESTER= APP_NAME= ENV_NAME=
#   MANIFEST=<MANIFEST_DIR>/<app>.ansible.yml  MERGED_DIGEST=sha256:… — écrit
#   SEULEMENT si tout concorde.
#
# Codes d'échec :
#   BRANCH_FORMAT_INVALIDE · PR_NUMBER_INVALIDE · MERGE_SHA_INVALIDE
#   GITEA_RECONCILE_ECHEC    Gitea injoignable / réponse illisible ou sans les champs attendus / identité forgée
#   PAYLOAD_PERIME           Gitea contredit le payload (merged / SHA / head / base)
#   MERGER_UNKNOWN           Gitea ne nomme aucun mergeur
#   PR_HORS_PERIMETRE        la PR touche autre chose que son manifeste / son certificat
#   MERGE_SHA_NON_ANCETRE    le SHA n'est pas sur main
#   MANIFESTE_ABSENT         le manifeste manque au SHA mergé ou sur main
#   PALIER_ABSENT            le manifeste au SHA mergé ne déclare pas ce palier (lib)
#   PALIER_SUPPLANTE         main porte un état plus récent de ce palier que cette PR
set -uo pipefail
set +x
# Chemin du script résolu AVANT le `cd` (motif provision-plan.sh : après, un
# `dirname "$0"` relatif ne résout plus — test-pr-comment.sh §10 le garde).
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SELF_DIR/.." || exit 1

PR_BRANCH="${PR_BRANCH:-}"
PR_NUMBER="${PR_NUMBER:-}"
MERGE_SHA="${MERGE_SHA:-}"
# Le secret de la forge porte un nom NEUTRE (2026-09-04) : un gestionnaire
# d'identite rend un jeton OU un couple, et les deux occupent la meme place.
GITEA_TOKEN="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$GITEA_TOKEN" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni GITEA_TOKEN — le secret de la forge (jeton, ou mot de passe d'un couple avec FORGE_USER)" >&2; exit 2; }
RECONCILE_OUT="${RECONCILE_OUT:?RECONCILE_OUT requis (fichier de sortie KEY=VALUE)}"
RECONCILE_FACTS="${RECONCILE_FACTS:-}"
GIT_HOST="${GIT_HOST:-http://gitea:3000}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"
GIT_WORKTREE="${GIT_WORKTREE:-.}"
# shellcheck source=scripts/lib/repo-layout.sh
. "$(dirname "$0")/lib/repo-layout.sh" || { echo "ERREUR: lib/repo-layout.sh introuvable" >&2; exit 1; }
repo_layout_init || exit 2   # tiret NU + sentinelle « . » : « » n'arrive jamais de Jenkins
MANIFEST_DIR="${MANIFEST_DIR:-clients/provisioned/applications}"

# shellcheck source=scripts/lib/app-manifest.sh
. "$SELF_DIR/lib/app-manifest.sh" || { echo "ERREUR: $SELF_DIR/lib/app-manifest.sh introuvable" >&2; exit 1; }

APP_NAME=""; ENV_NAME=""; GITEA_HEAD_REF=""
rm -f "$RECONCILE_OUT"
[ -n "$RECONCILE_FACTS" ] && rm -f "$RECONCILE_FACTS"
TMP="$(mktemp -d /tmp/pa-reconcile.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

# Valeur externe montrée dans le JOURNAL seulement : tronquée, échappée.
shown(){ printf '%q' "$(printf '%s' "${1:-}" | head -c 80)"; }

# Le refus est RAPPORTÉ sur la PR (tableau de bord, ADR-081) — sous le marqueur
# des REFUS, et seulement si la forge a confirmé qu'il s'agit d'une PR de
# provisioning (GITEA_HEAD_REF relu). Best-effort : la forge muette ne masque
# pas le refus, c'est le code de retour qui porte le verdict. `|| true` explicite.
# $1=tag $2=détail pour le JOURNAL $3=détail pour la PR (borné : jamais une valeur du payload)
fail(){
  local tag="$1" logmsg="$2" prmsg="${3:-}"
  echo "REFUS: ${tag} : ${logmsg}" >&2
  case "$GITEA_HEAD_REF" in
    provision/*)
      PR_NUMBER="$PR_NUMBER" APPLY_RESULT=REFUSED REFUSAL="$tag" REFUSAL_DETAIL="$prmsg" \
        APP_NAME="${APP_NAME:-(inconnue)}" ENV_NAME="${ENV_NAME:-(inconnu)}" \
        GIT_REPO="$GIT_REPO" GIT_HOST="$GIT_HOST" GIT_WEB_HOST="$GIT_WEB_HOST" GITEA_TOKEN="$GITEA_TOKEN" \
        BUILD_URL="${BUILD_URL:-}" \
        bash "$SELF_DIR/provision-apply-comment.sh" >/dev/null 2>&1 || true ;;
    *) echo "  (refus non commenté : la forge n'a pas confirmé une PR provision/* — journal seul)" >&2 ;;
  esac
  exit 1
}

# ── 1. FORME, avant tout appel réseau ────────────────────────────────────────
case "$PR_NUMBER" in
  ''|*[!0-9]*) fail PR_NUMBER_INVALIDE "PR_NUMBER n'est pas un entier (valeur : $(shown "$PR_NUMBER")) — rien à réconcilier" ;;
esac
case "$MERGE_SHA" in
  '') fail MERGE_SHA_INVALIDE "MERGE_SHA vide — un webhook sans merge_commit_sha ne nomme aucune référence (déclencheur mal câblé ? payload forgé ?)" ;;
esac
printf '%s' "$MERGE_SHA" | grep -Eq '^[0-9a-f]{40}$' \
  || fail MERGE_SHA_INVALIDE "MERGE_SHA hors de ^[0-9a-f]{40}$ (valeur : $(shown "$MERGE_SHA"))"
case "$PR_BRANCH" in
  provision/*) ;;
  *) fail BRANCH_FORMAT_INVALIDE "PR_BRANCH hors provision/<app>-<env> (valeur : $(shown "$PR_BRANCH")) — pas une demande d'application" ;;
esac
REST="${PR_BRANCH#provision/}"
# Découpage au DERNIER tiret (le motif du Groovy d'origine et de team-apply.sh) :
# `credit-scoring-rec` ⇒ app `credit-scoring`, env `rec`.
case "$REST" in
  *-*) ENV_NAME="${REST##*-}"; APP_NAME="${REST%-*}" ;;
  *) fail BRANCH_FORMAT_INVALIDE "PR_BRANCH sans suffixe -<env> (valeur : $(shown "$PR_BRANCH"))" ;;
esac
printf '%s' "$APP_NAME" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
  || { APP_NAME=""; ENV_NAME=""; fail BRANCH_FORMAT_INVALIDE "nom d'application hors de ^[a-z0-9][a-z0-9-]*$ (valeur : $(shown "${REST%-*}"))"; }
printf '%s' "$ENV_NAME" | grep -Eq '^[a-z0-9]+$' \
  || { APP_NAME=""; ENV_NAME=""; fail BRANCH_FORMAT_INVALIDE "palier hors de ^[a-z0-9]+$ (valeur : $(shown "${REST##*-}"))"; }
# Sans point ni slash possible dans APP_NAME (classe ci-dessus) : le chemin du
# manifeste ne peut pas sortir de MANIFEST_DIR.
MANIFEST="${MANIFEST_DIR}/${APP_NAME}.ansible.yml"
FORGE_MANIFEST="${SUB_PFX}${MANIFEST}"
FORGE_CERT="${SUB_PFX}clients/provisioned/certs/${APP_NAME}-${ENV_NAME}.crt"

# ── 2. GITEA = LA VÉRITÉ sur la PR ───────────────────────────────────────────
# Les deux logins remontent EMPAQUETÉS PAR LIGNES et sont donc forgeables par
# un saut de ligne (même classe que team-promote.sh §2 et deploy-pin.sh) : on
# REFUSE le délimiteur dans la valeur plutôt que d'espérer qu'il n'y soit pas.
# Les champs attendus doivent être PRÉSENTS (un 200 sans eux — portail
# interposé, autre objet — est une réponse illisible, pas une divergence).
PR_STATE=$(GIT_HOST="$GIT_HOST" GIT_REPO="$GIT_REPO" PR_NUMBER="$PR_NUMBER" \
  GITEA_TOKEN="$GITEA_TOKEN" PR_BRANCH="$PR_BRANCH" MERGE_SHA="$MERGE_SHA" \
  FORGE_MANIFEST="$FORGE_MANIFEST" FORGE_CERT="$FORGE_CERT" python3 - <<'PY'
import os, json, urllib.request, urllib.error
api = os.environ["GIT_HOST"].rstrip("/") + "/api/v1"
repo, pr = os.environ["GIT_REPO"], os.environ["PR_NUMBER"]
hdr = {"Authorization": "token " + os.environ["GITEA_TOKEN"], "Accept": "application/json"}
def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=30) as r:
        return json.load(r)
try:
    d = get(f"{api}/repos/{repo}/pulls/{pr}")
    if not isinstance(d, dict):
        raise ValueError("réponse non-objet")
except urllib.error.HTTPError as e:
    print("ERR=HTTP%s" % e.code); raise SystemExit
except (urllib.error.URLError, ValueError, OSError) as e:
    print("ERR=" + type(e).__name__); raise SystemExit
for k in ("merged", "merge_commit_sha", "head", "base", "user"):
    if k not in d:
        print("SCHEMA=" + k); raise SystemExit
if not isinstance(d.get("head"), dict) or "ref" not in d["head"] or not isinstance(d.get("base"), dict) or "ref" not in d["base"]:
    print("SCHEMA=head.ref/base.ref"); raise SystemExit
head_ref = str(d["head"].get("ref") or "")
mb = str((d.get("merged_by") or {}).get("login") or "")
rq = str((d.get("user") or {}).get("login") or "")
for name, val in (("merged_by.login", mb), ("user.login", rq), ("head.ref", head_ref)):
    if "\n" in val or "\r" in val:
        print("FORGE=" + name); raise SystemExit
why = []
if d.get("merged") is not True:                             why.append("merged=%r" % d.get("merged"))
if d.get("merge_commit_sha") != os.environ["MERGE_SHA"]:    why.append("merge_commit_sha=%s" % d.get("merge_commit_sha"))
if head_ref != os.environ["PR_BRANCH"]:                     why.append("head.ref=%s" % head_ref)
if d["base"].get("ref") != "main":                          why.append("base.ref=%s" % d["base"].get("ref"))
# Périmètre : la PR ne touche QUE son manifeste et son certificat de palier.
files_verdict = "FILES_OK"
if not why:
    try:
        files = get(f"{api}/repos/{repo}/pulls/{pr}/files?limit=200")
        if not isinstance(files, list):
            raise ValueError("files non-liste")
        allowed = {os.environ["FORGE_MANIFEST"], os.environ["FORGE_CERT"]}
        extra = sorted({str(f.get("filename") or "?") for f in files} - allowed)
        if not files:
            files_verdict = "FILES_VIDE"
        elif extra:
            files_verdict = "FILES_HORS " + " ".join(x.replace(" ", "_")[:120] for x in extra[:5])
    except urllib.error.HTTPError as e:
        files_verdict = "FILES_ERR=HTTP%s" % e.code
    except (urllib.error.URLError, ValueError, OSError) as e:
        files_verdict = "FILES_ERR=" + type(e).__name__
print("OK" if not why else "MISMATCH " + " ".join(why))
print("HR=" + head_ref)
print("MB=" + mb)
print("RQ=" + rq)
print("FV=" + files_verdict)
PY
) || fail GITEA_RECONCILE_ECHEC "lecture de ${GIT_REPO}#${PR_NUMBER} sur Gitea en échec (python)"
PR_VERDICT=$(printf '%s\n' "$PR_STATE" | sed -n '1p')
GITEA_HEAD_REF=$(printf '%s\n' "$PR_STATE" | sed -n 's/^HR=//p')
GITEA_MERGED_BY=$(printf '%s\n' "$PR_STATE" | sed -n 's/^MB=//p')
GITEA_REQUESTER=$(printf '%s\n' "$PR_STATE" | sed -n 's/^RQ=//p')
FILES_VERDICT=$(printf '%s\n' "$PR_STATE" | sed -n 's/^FV=//p')
# Les FAITS relus, écrits dès maintenant (succès comme échec) : c'est ce que le
# post{always} du pipeline consulte avant de poser un statut de build.
case "$PR_VERDICT" in
  OK|MISMATCH*)
    [ -n "$RECONCILE_FACTS" ] && printf 'GITEA_HEAD_REF=%s\n' "$GITEA_HEAD_REF" > "$RECONCILE_FACTS" ;;
esac
case "$PR_VERDICT" in
  OK) ;;
  ERR=*)    fail GITEA_RECONCILE_ECHEC "appel Gitea en échec (${PR_VERDICT#ERR=}) pour ${GIT_REPO}#${PR_NUMBER} — sans la vérité de la forge, pas d'apply" ;;
  SCHEMA=*) fail GITEA_RECONCILE_ECHEC "réponse Gitea sans le champ ${PR_VERDICT#SCHEMA=} pour ${GIT_REPO}#${PR_NUMBER} (schéma inattendu / portail interposé) — refus" ;;
  FORGE=*)  fail GITEA_RECONCILE_ECHEC "le champ ${PR_VERDICT#FORGE=} de ${GIT_REPO}#${PR_NUMBER} contient un saut de ligne — une identité ne fabrique pas de champ, refus" ;;
  MISMATCH*) fail PAYLOAD_PERIME "${GIT_REPO}#${PR_NUMBER} sur Gitea ne correspond pas au webhook (${PR_VERDICT#MISMATCH }) — le payload ne fait pas foi, refus ; CE webhook n'a rien appliqué" \
                                 "la PR relue sur la forge ne correspond pas au webhook (${PR_VERDICT#MISMATCH })" ;;
  *) fail GITEA_RECONCILE_ECHEC "réponse inattendue de la réconciliation ($(shown "$PR_VERDICT"))" ;;
esac
# FAIL-CLOSED, dit ICI : la garde d'identité refuserait aussi un mergeur vide
# (MERGER_UNKNOWN), mais en accusant le CÂBLAGE du webhook — alors que la cause
# est que Gitea lui-même ne nomme personne. Et refuser ici évite de réveiller
# un humain pour une pause qui ne peut pas aboutir.
[ -n "$GITEA_MERGED_BY" ] \
  || fail MERGER_UNKNOWN "Gitea ne nomme aucun mergeur sur ${GIT_REPO}#${PR_NUMBER} (merged_by absent) — la garde d'identité ne pourrait RIEN vérifier" \
                         "la forge ne nomme aucun mergeur pour cette PR"

# ── 3. PÉRIMÈTRE : la PR n'a touché que son manifeste et son certificat ──────
case "$FILES_VERDICT" in
  FILES_OK) ;;
  FILES_VIDE)  fail PR_HORS_PERIMETRE "${GIT_REPO}#${PR_NUMBER} ne modifie aucun fichier — rien à projeter" "la PR ne modifie aucun fichier" ;;
  FILES_HORS*) fail PR_HORS_PERIMETRE "${GIT_REPO}#${PR_NUMBER} touche des fichiers hors de son manifeste/certificat (${FILES_VERDICT#FILES_HORS }) — l'aval checkoute l'arbre ENTIER au SHA mergé : refus" \
                                      "la PR touche des fichiers hors de son manifeste et de son certificat de palier (${FILES_VERDICT#FILES_HORS })" ;;
  FILES_ERR=*) fail GITEA_RECONCILE_ECHEC "lecture des fichiers de ${GIT_REPO}#${PR_NUMBER} en échec (${FILES_VERDICT#FILES_ERR=})" ;;
  *)           fail GITEA_RECONCILE_ECHEC "verdict de périmètre inattendu ($(shown "$FILES_VERDICT"))" ;;
esac

# ── 4. GIT = LA VÉRITÉ sur main : ancêtre, et palier non supplanté ───────────
git -C "$GIT_WORKTREE" fetch -q origin main 2>"$TMP/fetch.err" \
  || fail GITEA_RECONCILE_ECHEC "git fetch origin main en échec dans ${GIT_WORKTREE} : $(head -c 200 "$TMP/fetch.err")"
git -C "$GIT_WORKTREE" merge-base --is-ancestor "$MERGE_SHA" origin/main \
  || fail MERGE_SHA_NON_ANCETRE "${MERGE_SHA} n'est pas un ancêtre de main — le SHA ne correspond pas à un commit fusionné sur la branche protégée" \
                                "le SHA de merge n'est pas sur main"
git -C "$GIT_WORKTREE" show "${MERGE_SHA}:./${MANIFEST}" > "$TMP/merged.yml" 2>/dev/null \
  || fail MANIFESTE_ABSENT "${MANIFEST} absent de l'arbre au SHA mergé ${MERGE_SHA}" "le manifeste de l'application est absent au SHA mergé"
git -C "$GIT_WORKTREE" show "origin/main:./${MANIFEST}" > "$TMP/main.yml" 2>/dev/null \
  || fail MANIFESTE_ABSENT "${MANIFEST} absent de main (application retirée depuis ?) — rien à projeter" "le manifeste de l'application n'est plus sur main"
MERGED_DIGEST=$(app_manifest_digest_env "$TMP/merged.yml" "$ENV_NAME" 2>"$TMP/dg.err") \
  || fail PALIER_ABSENT "le manifeste au SHA mergé ne déclare pas le palier ${ENV_NAME} ou est illisible : $(head -c 200 "$TMP/dg.err" | tr '\n' ' ')" \
                        "le manifeste au SHA mergé ne déclare pas ce palier (ou est illisible)"
MAIN_DIGEST=$(app_manifest_digest_env "$TMP/main.yml" "$ENV_NAME" 2>"$TMP/dg2.err") \
  || fail PALIER_SUPPLANTE "main ne déclare plus le palier ${ENV_NAME} pour ${APP_NAME} (ou son manifeste est illisible) : $(head -c 200 "$TMP/dg2.err" | tr '\n' ' ') — rejouer une demande" \
                           "main ne déclare plus ce palier pour cette application"
[ "$MERGED_DIGEST" = "$MAIN_DIGEST" ] \
  || fail PALIER_SUPPLANTE "main porte un état plus récent de ${APP_NAME}/${ENV_NAME} que ${GIT_REPO}#${PR_NUMBER} (digest mergé ${MERGED_DIGEST} ≠ main ${MAIN_DIGEST}) — un rejeu ne re-projette jamais un état dépassé : rejouer une demande, ou le repli (A6)" \
                           "main porte un état plus récent de ce palier que cette PR (rejeu d'un webhook ancien ?) — rejouer une demande, ou le repli A6"

# ── 4bis. A6 (D1ter) — un REPLI ne restaure que l'état d'avant le MERGE ──────
# PALIER_SUPPLANTE compare le SHA mergé à main : pour la PR qui vient d'être
# mergée ce sont le même commit. Si main a bougé pour ce palier ENTRE la
# demande de repli (trailer `Repli-De: <sha>` du commit de branche, MERGE_SHA^2)
# et le merge (MERGE_SHA^1 = main juste avant), la PR restaure « l'état d'avant »
# d'un main qui n'existe plus : refus, avant la pause. Certificat comparé par
# identifiant de blob (aucun contenu lu). INERTE sans trailer (toute PR non-repli,
# un squash) : rien d'autre ne change dans ce script.
P2=$(git -C "$GIT_WORKTREE" rev-parse -q --verify "${MERGE_SHA}^2" 2>/dev/null || true)
REPLI_DE=""
[ -n "$P2" ] && REPLI_DE=$(git -C "$GIT_WORKTREE" log -1 --format=%B "$P2" | sed -n 's/^Repli-De: \([0-9a-f]\{40\}\).*/\1/p' | head -1)
if [ -n "$REPLI_DE" ]; then
  P1=$(git -C "$GIT_WORKTREE" rev-parse "${MERGE_SHA}^1")
  CERT_REL="clients/provisioned/certs/${APP_NAME}-${ENV_NAME}.crt"
  git -C "$GIT_WORKTREE" show "${P1}:./${MANIFEST}" > "$TMP/p1.yml" 2>/dev/null \
    || fail REPLI_PERIME "${MANIFEST} absent de main juste avant le merge (${P1}) — main a bougé depuis la demande de repli ; rejouer la demande de repli" \
                         "main a bougé pour ce palier entre la demande de repli et son merge (manifeste absent avant le merge) — rejouer la demande de repli"
  git -C "$GIT_WORKTREE" show "${REPLI_DE}:./${MANIFEST}" > "$TMP/de.yml" 2>/dev/null \
    || fail REPLI_PERIME "la référence Repli-De ${REPLI_DE} ne porte pas ${MANIFEST}" "la référence Repli-De de la PR est illisible — rejouer la demande de repli"
  D_P1=$(app_manifest_digest_env "$TMP/p1.yml" "$ENV_NAME" 2>/dev/null); D_DE=$(app_manifest_digest_env "$TMP/de.yml" "$ENV_NAME" 2>/dev/null)
  [ -n "$D_P1" ] && [ "$D_P1" = "$D_DE" ] \
    || fail REPLI_PERIME "main a bougé pour ${APP_NAME}/${ENV_NAME} entre la demande de repli (${REPLI_DE}) et le merge (${P1}) : digest ${D_DE:-illisible} → ${D_P1:-illisible} — rejouer la demande de repli" \
                         "main a bougé pour ce palier entre la demande de repli et son merge — rejouer la demande de repli"
  B1=$(git -C "$GIT_WORKTREE" rev-parse -q --verify "${P1}:./${CERT_REL}" 2>/dev/null || true)
  B2=$(git -C "$GIT_WORKTREE" rev-parse -q --verify "${REPLI_DE}:./${CERT_REL}" 2>/dev/null || true)
  [ "$B1" = "$B2" ] \
    || fail REPLI_PERIME "le certificat ${CERT_REL} a changé sur main entre la demande de repli et le merge — rejouer la demande de repli" \
                         "le certificat du palier a changé sur main entre la demande de repli et son merge — rejouer la demande de repli"
  echo "REPLI_OK : la PR est un repli (Repli-De ${REPLI_DE}) et main n'a pas bougé pour ${APP_NAME}/${ENV_NAME} avant le merge"
fi

# ── 5. SORTIE : ce que le pipeline charge dans son environnement ─────────────
{
  printf 'GITEA_MERGED_BY=%s\n' "$GITEA_MERGED_BY"
  printf 'GITEA_REQUESTER=%s\n' "$GITEA_REQUESTER"
  printf 'APP_NAME=%s\n' "$APP_NAME"
  printf 'ENV_NAME=%s\n' "$ENV_NAME"
  printf 'MANIFEST=%s\n' "$MANIFEST"
  printf 'MERGED_DIGEST=%s\n' "$MERGED_DIGEST"
} > "$RECONCILE_OUT"
echo "RECONCILE_OK : ${GIT_REPO}#${PR_NUMBER} mergée (${MERGE_SHA}) par '${GITEA_MERGED_BY}' (demandeur '${GITEA_REQUESTER}') — ${APP_NAME}/${ENV_NAME}, manifeste ${MANIFEST}, digest ${MERGED_DIGEST} = main"
