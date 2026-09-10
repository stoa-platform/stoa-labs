#!/usr/bin/env bash
# provision-apply-reconcile.sh — la RÉCONCILIATION de provision-apply (A2, GOAL
# cd-applications) : le payload du webhook ne fait pas foi — ni sur l'état de la
# PR (Gitea), ni sur l'état de la branche de base (git).
#
# POURQUOI. Le déclencheur de provision-apply est un webhook au token GWT
# partagé, sans HMAC vérifié en aval (limite mesurée, cf. team-apply.sh §webhook).
# Un tir manuel — ou un « Redeliver » Gitea d'un vieux payload — peut donc
# prétendre N'IMPORTE QUOI : `merged:true` sur une PR ouverte, un
# `merge_commit_sha` d'une autre PR, un `merged_by` qui n'a rien mergé, ou
# rejouer à l'identique une PR RÉELLEMENT mergée dont le palier a été supplanté
# depuis. Avant A2, un tel payload ouvrait la pause et — si quelqu'un répondait —
# appliquait l'état de la branche de base ; avec A2 il projetterait le SHA demandé : la
# réconciliation est donc ce qui rend « projeter le SHA mergé » sûr.
#
# CE QUI EST VÉRIFIÉ, DANS L'ORDRE (chaque refus est nommé, stable, greppable) :
#   1. FORME, sans aucun appel réseau : PR_NUMBER entier, MERGE_SHA ^[0-9a-f]{40}$,
#      PR_BRANCH = provision/<app>-<env> (classes strictes : le chemin du
#      manifeste ne peut pas sortir de son dossier).
#   2. LA FORGE = LA VÉRITÉ sur la PR (`forge pr_get`, authentifié, non
#      falsifiable par un payload) : MERGED=1 · MERGE_SHA == MERGE_SHA ·
#      HEAD_REF == PR_BRANCH · BASE_REF == GIT_BASE, sinon PAYLOAD_PERIME ; les
#      IDENTITÉS (MERGED_BY, LOGIN) viennent de là, jamais du payload.
#   3. PÉRIMÈTRE de la PR (`forge pr_files`) : elle ne touche QUE son
#      manifeste et son certificat de palier — sinon PR_HORS_PERIMETRE (l'aval
#      checkoute l'arbre ENTIER au SHA mergé : une PR qui éditerait le rôle ou
#      un script s'exécuterait sous l'identité du valideur).
#
# LA FORGE N'EST PLUS GITEA EN DUR (2026-09-09, client sur GitLab) : tout appel
# passe par scripts/lib/forge-api.sh — visage FORGE_KIND=gitea|gitlab, base
# d'API, en-tête d'auth, garde de réponse (redirection, non-JSON, non-objet,
# retour-ligne dans une valeur) vivent LÀ, avec une cause auto-diagnostique sur
# stderr. Les TAGS de refus ci-dessous ne bougent pas (GITEA_RECONCILE_ECHEC
# garde son nom : provision-plan/apply et les harnais le greppent).
#   4. GIT = LA VÉRITÉ sur la branche de base : MERGE_SHA est un ancêtre de
#      origin/<base> (MERGE_SHA_NON_ANCETRE) et le manifeste EFFECTIF du palier
#      au SHA mergé est encore celui que la base porte pour ce palier — sinon
#      PALIER_SUPPLANTE (un rejeu d'une PR ancienne ne re-projette jamais un
#      état que la base a dépassé ; granularité = le palier, via
#      app_manifest_digest_env : une PR foo-dev postérieure ne bloque pas foo-rec).
#
# Tourne AVANT la pause : personne n'est réveillé pour un payload forgé ou périmé.
#
# COMMENTAIRE SUR LA PR — deux règles, mesurées à la critique de la spec :
#   - on ne commente QUE si la PR a été RELUE sur la forge et que SON head.ref (relu,
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
#   FORGE_SECRET                        (req) jamais en argv, jamais loggé
#   RECONCILE_OUT                      (req) fichier de sortie KEY=VALUE, lu par le pipeline
#   RECONCILE_FACTS                    (opt) fichier écrit DÈS la relecture de la forge (GITEA_HEAD_REF=…),
#                                            succès comme échec — c'est lui qui autorise le
#                                            statut build du post{always}
#   GIT_HOST (REQUIS, aucun repli — base de la forge) · GIT_REPO (défaut ci/stoa-labs)
#   FORGE_KIND (gitea|gitlab, défaut gitea) · FORGE_API_AUTH (cf. scripts/lib/forge-api.py)
#   GIT_WEB_HOST (lien humain du commentaire, défaut GIT_HOST)
#   GIT_WORKTREE (défaut . = poc-control-plane-federation/ dans le workspace : là où
#                 `git fetch origin <base>` et `git show` tournent)
#   GIT_SUBDIR   (défaut poc-control-plane-federation : préfixe des chemins vus par la forge)
#   MANIFEST_DIR (défaut clients/provisioned/applications, relatif à GIT_WORKTREE)
#
# Sortie (RECONCILE_OUT) : GITEA_MERGED_BY= GITEA_REQUESTER= APP_NAME= ENV_NAME=
#   MANIFEST=<MANIFEST_DIR>/<app>.ansible.yml  MERGED_DIGEST=sha256:… — écrit
#   SEULEMENT si tout concorde.
#
# Codes d'échec :
#   BRANCH_FORMAT_INVALIDE · PR_NUMBER_INVALIDE · MERGE_SHA_INVALIDE
#   GITEA_RECONCILE_ECHEC    forge injoignable / réponse illisible ou sans les champs attendus / identité forgée
#   PAYLOAD_PERIME           la forge contredit le payload (merged / SHA / head / base)
#   MERGER_UNKNOWN           la forge ne nomme aucun mergeur
#   PR_HORS_PERIMETRE        la PR touche autre chose que son manifeste / son certificat
#   MERGE_SHA_NON_ANCETRE    le SHA n'est pas sur la branche de base
#   MANIFESTE_ABSENT         le manifeste manque au SHA mergé ou sur la base
#   PALIER_ABSENT            le manifeste au SHA mergé ne déclare pas ce palier (lib)
#   PALIER_SUPPLANTE         la base porte un état plus récent de ce palier que cette PR
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
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN — le secret de la forge (jeton, ou mot de passe d'un couple avec FORGE_USER)" >&2; exit 2; }
RECONCILE_OUT="${RECONCILE_OUT:?RECONCILE_OUT requis (fichier de sortie KEY=VALUE)}"
RECONCILE_FACTS="${RECONCILE_FACTS:-}"
# La base de la forge n'a plus de repli de lab (2026-09-09) : forge_api_init la
# refuse vide — un défaut « gitea:3000 » chez un client GitLab rendait un refus
# qui accusait la PR au lieu du câblage.
GIT_HOST="${GIT_HOST:-}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"
GIT_WORKTREE="${GIT_WORKTREE:-.}"
# shellcheck source=scripts/lib/repo-layout.sh
. "$(dirname "$0")/lib/repo-layout.sh" || { echo "ERREUR: lib/repo-layout.sh introuvable" >&2; exit 1; }
repo_layout_init || exit 2   # tiret NU + sentinelle « . » : « » n'arrive jamais de Jenkins
MANIFEST_DIR="${MANIFEST_DIR:-clients/provisioned/applications}"

# shellcheck source=scripts/lib/app-manifest.sh
. "$SELF_DIR/lib/app-manifest.sh" || { echo "ERREUR: $SELF_DIR/lib/app-manifest.sh introuvable" >&2; exit 1; }
# shellcheck source=scripts/lib/branch-ref.sh
. "$SELF_DIR/lib/branch-ref.sh" || { echo "ERREUR: $SELF_DIR/lib/branch-ref.sh introuvable" >&2; exit 1; }
# shellcheck source=scripts/lib/git-base.sh
. "$SELF_DIR/lib/git-base.sh" || { echo "ERREUR: $SELF_DIR/lib/git-base.sh introuvable" >&2; exit 1; }
# L'unique autorité pour parler à la forge (visage, base, en-tête, garde) ; le
# secret lui parvient par l'environnement (FORGE_SECRET), jamais en argv.
# shellcheck source=scripts/lib/forge-api.sh
. "$SELF_DIR/lib/forge-api.sh" || { echo "ERREUR: $SELF_DIR/lib/forge-api.sh introuvable" >&2; exit 1; }
forge_api_init || exit 2

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
        GIT_REPO="$GIT_REPO" GIT_HOST="$GIT_HOST" GIT_WEB_HOST="$GIT_WEB_HOST" FORGE_SECRET="$FORGE_SECRET" \
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
# Découpage au DERNIER tiret (`credit-scoring-rec` ⇒ app `credit-scoring`, env
# `rec`) — désormais dans scripts/lib/branch-ref.sh, une seule fois pour les
# sept sites qui le réécrivaient (D8). Les codes de refus sont INCHANGÉS : ce
# fichier faisait déjà foi, il cesse seulement de porter la règle en propre.
BR_RC=0; BR_OUT="$(branch_split "$PR_BRANCH" "provision/")" || BR_RC=$?
case "$BR_RC" in
  0) APP_NAME="${BR_OUT% *}"; ENV_NAME="${BR_OUT##* }" ;;
  2) APP_NAME=""; ENV_NAME=""; fail BRANCH_FORMAT_INVALIDE "PR_BRANCH sans suffixe -<env> (valeur : $(shown "$PR_BRANCH"))" ;;
  3) APP_NAME=""; ENV_NAME=""; fail BRANCH_FORMAT_INVALIDE "nom d'application hors de ^[a-z0-9][a-z0-9-]*$ (valeur : $(shown "${REST%-*}"))" ;;
  4) APP_NAME=""; ENV_NAME=""; fail BRANCH_FORMAT_INVALIDE "palier hors de ^[a-z0-9]+$ (valeur : $(shown "${REST##*-}"))" ;;
  *) APP_NAME=""; ENV_NAME=""; fail BRANCH_FORMAT_INVALIDE "PR_BRANCH hors provision/<app>-<env> (valeur : $(shown "$PR_BRANCH"))" ;;
esac
# Sans point ni slash possible dans APP_NAME (classe ci-dessus) : le chemin du
# manifeste ne peut pas sortir de MANIFEST_DIR.
MANIFEST="${MANIFEST_DIR}/${APP_NAME}.ansible.yml"
FORGE_MANIFEST="${SUB_PFX}${MANIFEST}"
FORGE_CERT="${SUB_PFX}clients/provisioned/certs/${APP_NAME}-${ENV_NAME}.crt"

# ── 1bis. LA BRANCHE DE BASE (L3, 2026-09-10) ────────────────────────────────
# Ce script ne clone RIEN : il lit le worktree que Jenkins a déjà posé. La
# branche par défaut se découvre donc sur l'origine DE CE WORKTREE — la même que
# le `git fetch` du §4 interroge, sous le même environnement, donc sous la même
# enveloppe d'authentification (celle que la définition SCM du job a posée).
# APRÈS la §1 : un payload difforme reste refusé sans toucher au réseau. AVANT la
# §2 : c'est la base RELUE de la PR que la §2 compare (base.ref). « main » y était
# écrit en dur — chez un client dont la branche est `master`, TOUTE PR mergée
# était refusée PAYLOAD_PERIME, en accusant le webhook au lieu du câblage.
#
# Écrit en `if`, pas en `${…:-…}` (forme retenue par team-apply.sh) : ce n'est
# pas un DÉFAUT de configuration mais une LECTURE de l'arbre en place, et
# ci/lint-config-knobs.sh a raison de refuser un `:-` dont la valeur ressemble à
# un chemin. Sous la forme `${…:-$(…)}`, sa règle T3 laissait ce site passer par
# ACCIDENT (sa regex s'arrête au guillemet interne du `git -C "$GIT_WORKTREE"`)
# alors que le MÊME motif sans guillemet a bien été refusé dans team-apply.sh.
if [ -z "${GIT_CLONE_URL:-}" ]; then
  GIT_CLONE_URL="$(git -C "$GIT_WORKTREE" remote get-url origin 2>/dev/null || true)"
fi
git_base_init "$GIT_CLONE_URL" \
  || fail GITEA_RECONCILE_ECHEC "branche par défaut du dépôt inconnue (cause ci-dessus) — sans elle, ni la base de la PR ni l'ancêtre ne peuvent être vérifiés" \
                                "la branche par défaut du dépôt n'a pas pu être déterminée"

# ── 2. LA FORGE = LA VÉRITÉ sur la PR ────────────────────────────────────────
# Relue par `forge pr_get` (scripts/lib/forge-api.py). Ce que la lib refuse
# DÉJÀ, avec une cause auto-diagnostique sur stderr : redirection, statut hors
# 2xx (401 = secret refusé, 500 = panne), corps vide, non-JSON, non-objet, et
# tout champ portant un retour-ligne — les logins remontent EMPAQUETÉS PAR
# LIGNES et sont forgeables par un saut de ligne (même classe que team-promote.sh
# §2 et deploy-pin.sh) : le délimiteur est REFUSÉ dans la valeur, jamais espéré
# absent. Ce qui reste ICI, parce que la lib ne peut pas le savoir : le SCHÉMA
# d'une PR (un 200 sans état ni tête — portail interposé, autre objet — est une
# réponse illisible, pas une divergence) et la confrontation au payload.
# Les clés attendues de pr_get sont posées VIDES avant l'appel : une clé que la
# forge ne rend pas reste vide, jamais héritée (forge_kv pose par printf -v).
R_NUMBER=""; R_STATE_RAW=""; R_HEAD_REF=""; R_BASE_REF=""; R_MERGED=""; R_MERGE_SHA=""; R_MERGED_BY=""; R_LOGIN=""
forge_kv R pr_get "$PR_NUMBER" 2>"$TMP/forge.err" || {
  cat "$TMP/forge.err" >&2
  fail GITEA_RECONCILE_ECHEC "lecture de ${GIT_REPO}#${PR_NUMBER} sur la forge en échec — sans la vérité de la forge, pas d'apply (cause ci-dessus)"
}
# Le SCHÉMA, dans le vocabulaire normalisé : l'adaptateur rend VIDE ce que la
# forge ne rend pas (il ne distingue pas « absent » de « nul »), et `merged`
# vaut 0 dans les deux cas — le schéma se fonde donc sur ce qu'une PR ne peut
# JAMAIS rendre vide : son numéro (celui demandé), sa tête et sa base. Un objet
# qui n'a rien de tout cela (portail interposé, page d'erreur en 200) est
# illisible ; une PR non mergée sans champ `state` (forme Gitea minimale) reste
# une PR, et sa divergence se nomme plus bas (PAYLOAD_PERIME).
MISSING=""
[ "$R_NUMBER" = "$PR_NUMBER" ] || MISSING="$MISSING number"
[ -n "$R_HEAD_REF" ] || MISSING="$MISSING head.ref"
[ -n "$R_BASE_REF" ] || MISSING="$MISSING base.ref"
[ -z "$MISSING" ] \
  || fail GITEA_RECONCILE_ECHEC "réponse de la forge sans les champs d'une PR (absents ou étrangers :${MISSING} ; lu : number=$(shown "$R_NUMBER") état=$(shown "$R_STATE_RAW")) pour ${GIT_REPO}#${PR_NUMBER} (schéma inattendu / portail interposé) — refus"
GITEA_HEAD_REF="$R_HEAD_REF"; GITEA_MERGED_BY="$R_MERGED_BY"; GITEA_REQUESTER="$R_LOGIN"
# Les FAITS relus, écrits dès maintenant (succès comme échec) : c'est ce que le
# post{always} du pipeline consulte avant de poser un statut de build.
[ -n "$RECONCILE_FACTS" ] && printf 'GITEA_HEAD_REF=%s\n' "$GITEA_HEAD_REF" > "$RECONCILE_FACTS"
# La confrontation au payload : UNE comparaison par ligne — chacune porte une
# épreuve de mutation (test-provision-apply-a2.sh §D : retirer la ligne fait
# PASSER le scénario qui la vise, la preuve tient donc à cette ligne).
WHY=""
[ "$R_MERGED" = 1 ]               || WHY="$WHY merged=false"
[ "$R_MERGE_SHA" = "$MERGE_SHA" ] || WHY="$WHY merge_commit_sha=${R_MERGE_SHA}"
[ "$GITEA_HEAD_REF" = "$PR_BRANCH" ] || WHY="$WHY head.ref=${GITEA_HEAD_REF}"
[ "$R_BASE_REF" = "$GIT_BASE" ]   || WHY="$WHY base.ref=${R_BASE_REF}"
[ -z "$WHY" ] \
  || fail PAYLOAD_PERIME "${GIT_REPO}#${PR_NUMBER} sur la forge ne correspond pas au webhook (${WHY# }) — le payload ne fait pas foi, refus ; CE webhook n'a rien appliqué" \
                         "la PR relue sur la forge ne correspond pas au webhook (${WHY# })"
# FAIL-CLOSED, dit ICI : la garde d'identité refuserait aussi un mergeur vide
# (MERGER_UNKNOWN), mais en accusant le CÂBLAGE du webhook — alors que la cause
# est que la forge elle-même ne nomme personne. Et refuser ici évite de réveiller
# un humain pour une pause qui ne peut pas aboutir.
[ -n "$GITEA_MERGED_BY" ] \
  || fail MERGER_UNKNOWN "la forge ne nomme aucun mergeur sur ${GIT_REPO}#${PR_NUMBER} (merged_by absent) — la garde d'identité ne pourrait RIEN vérifier" \
                         "la forge ne nomme aucun mergeur pour cette PR"

# ── 3. PÉRIMÈTRE : la PR n'a touché que son manifeste et son certificat ──────
# `forge pr_files` : un chemin par ligne, PAGINÉ jusqu'à une page vide — une PR
# qui touche plus de fichiers qu'une page n'en montre n'échappe pas au périmètre.
forge pr_files "$PR_NUMBER" > "$TMP/files" 2>"$TMP/files.err" || {
  cat "$TMP/files.err" >&2
  fail GITEA_RECONCILE_ECHEC "lecture des fichiers de ${GIT_REPO}#${PR_NUMBER} en échec (cause ci-dessus)"
}
# Hors périmètre = tout chemin qui n'est ni le manifeste ni le certificat DE CE
# PALIER ; montrés au plus cinq, tronqués, sans blanc (ils entrent dans un
# message d'une ligne relayé sur la PR).
EXTRA=$(grep -vxF -e "$FORGE_MANIFEST" -e "$FORGE_CERT" "$TMP/files" | sort -u | head -5 | cut -c1-120 | tr ' ' '_' | tr '\n' ' ')
FILES_VERDICT=FILES_OK
if [ ! -s "$TMP/files" ]; then FILES_VERDICT=FILES_VIDE
elif [ -n "$EXTRA" ]; then FILES_VERDICT="FILES_HORS ${EXTRA% }"
fi
case "$FILES_VERDICT" in
  FILES_OK) ;;
  FILES_VIDE)  fail PR_HORS_PERIMETRE "${GIT_REPO}#${PR_NUMBER} ne modifie aucun fichier — rien à projeter" "la PR ne modifie aucun fichier" ;;
  FILES_HORS*) fail PR_HORS_PERIMETRE "${GIT_REPO}#${PR_NUMBER} touche des fichiers hors de son manifeste/certificat (${FILES_VERDICT#FILES_HORS }) — l'aval checkoute l'arbre ENTIER au SHA mergé : refus" \
                                      "la PR touche des fichiers hors de son manifeste et de son certificat de palier (${FILES_VERDICT#FILES_HORS })" ;;
  *)           fail GITEA_RECONCILE_ECHEC "verdict de périmètre inattendu ($(shown "$FILES_VERDICT"))" ;;
esac

# ── 4. GIT = LA VÉRITÉ sur la branche de base : ancêtre, palier non supplanté ─
git -C "$GIT_WORKTREE" fetch -q origin "$GIT_BASE" 2>"$TMP/fetch.err" \
  || fail GITEA_RECONCILE_ECHEC "git fetch origin ${GIT_BASE} en échec dans ${GIT_WORKTREE} : $(head -c 200 "$TMP/fetch.err")"
git -C "$GIT_WORKTREE" merge-base --is-ancestor "$MERGE_SHA" "origin/${GIT_BASE}" \
  || fail MERGE_SHA_NON_ANCETRE "${MERGE_SHA} n'est pas un ancêtre de ${GIT_BASE} — le SHA ne correspond pas à un commit fusionné sur la branche protégée" \
                                "le SHA de merge n'est pas sur ${GIT_BASE}"
git -C "$GIT_WORKTREE" show "${MERGE_SHA}:./${MANIFEST}" > "$TMP/merged.yml" 2>/dev/null \
  || fail MANIFESTE_ABSENT "${MANIFEST} absent de l'arbre au SHA mergé ${MERGE_SHA}" "le manifeste de l'application est absent au SHA mergé"
git -C "$GIT_WORKTREE" show "origin/${GIT_BASE}:./${MANIFEST}" > "$TMP/base.yml" 2>/dev/null \
  || fail MANIFESTE_ABSENT "${MANIFEST} absent de ${GIT_BASE} (application retirée depuis ?) — rien à projeter" "le manifeste de l'application n'est plus sur ${GIT_BASE}"
MERGED_DIGEST=$(app_manifest_digest_env "$TMP/merged.yml" "$ENV_NAME" 2>"$TMP/dg.err") \
  || fail PALIER_ABSENT "le manifeste au SHA mergé ne déclare pas le palier ${ENV_NAME} ou est illisible : $(head -c 200 "$TMP/dg.err" | tr '\n' ' ')" \
                        "le manifeste au SHA mergé ne déclare pas ce palier (ou est illisible)"
BASE_DIGEST=$(app_manifest_digest_env "$TMP/base.yml" "$ENV_NAME" 2>"$TMP/dg2.err") \
  || fail PALIER_SUPPLANTE "${GIT_BASE} ne déclare plus le palier ${ENV_NAME} pour ${APP_NAME} (ou son manifeste est illisible) : $(head -c 200 "$TMP/dg2.err" | tr '\n' ' ') — rejouer une demande" \
                           "la branche de base ne déclare plus ce palier pour cette application"
[ "$MERGED_DIGEST" = "$BASE_DIGEST" ] \
  || fail PALIER_SUPPLANTE "${GIT_BASE} porte un état plus récent de ${APP_NAME}/${ENV_NAME} que ${GIT_REPO}#${PR_NUMBER} (digest mergé ${MERGED_DIGEST} ≠ ${GIT_BASE} ${BASE_DIGEST}) — un rejeu ne re-projette jamais un état dépassé : rejouer une demande, ou le repli (A6)" \
                           "la branche de base porte un état plus récent de ce palier que cette PR (rejeu d'un webhook ancien ?) — rejouer une demande, ou le repli A6"

# ── 4bis. A6 (D1ter) — un REPLI ne restaure que l'état d'avant le MERGE ──────
# PALIER_SUPPLANTE compare le SHA mergé à la base : pour la PR qui vient d'être
# mergée ce sont le même commit. Si la base a bougé pour ce palier ENTRE la
# demande de repli (trailer `Repli-De: <sha>` du commit de branche, MERGE_SHA^2)
# et le merge (MERGE_SHA^1 = la base juste avant), la PR restaure « l'état
# d'avant » d'une base qui n'existe plus : refus, avant la pause. Certificat par
# identifiant de blob (aucun contenu lu). INERTE sans trailer (toute PR non-repli,
# un squash) : rien d'autre ne change dans ce script.
P2=$(git -C "$GIT_WORKTREE" rev-parse -q --verify "${MERGE_SHA}^2" 2>/dev/null || true)
REPLI_DE=""
[ -n "$P2" ] && REPLI_DE=$(git -C "$GIT_WORKTREE" log -1 --format=%B "$P2" | sed -n 's/^Repli-De: \([0-9a-f]\{40\}\).*/\1/p' | head -1)
if [ -n "$REPLI_DE" ]; then
  P1=$(git -C "$GIT_WORKTREE" rev-parse "${MERGE_SHA}^1")
  CERT_REL="clients/provisioned/certs/${APP_NAME}-${ENV_NAME}.crt"
  git -C "$GIT_WORKTREE" show "${P1}:./${MANIFEST}" > "$TMP/p1.yml" 2>/dev/null \
    || fail REPLI_PERIME "${MANIFEST} absent de ${GIT_BASE} juste avant le merge (${P1}) — ${GIT_BASE} a bougé depuis la demande de repli ; rejouer la demande de repli" \
                         "la branche de base a bougé pour ce palier entre la demande de repli et son merge (manifeste absent avant le merge) — rejouer la demande de repli"
  git -C "$GIT_WORKTREE" show "${REPLI_DE}:./${MANIFEST}" > "$TMP/de.yml" 2>/dev/null \
    || fail REPLI_PERIME "la référence Repli-De ${REPLI_DE} ne porte pas ${MANIFEST}" "la référence Repli-De de la PR est illisible — rejouer la demande de repli"
  D_P1=$(app_manifest_digest_env "$TMP/p1.yml" "$ENV_NAME" 2>/dev/null); D_DE=$(app_manifest_digest_env "$TMP/de.yml" "$ENV_NAME" 2>/dev/null)
  [ -n "$D_P1" ] && [ "$D_P1" = "$D_DE" ] \
    || fail REPLI_PERIME "${GIT_BASE} a bougé pour ${APP_NAME}/${ENV_NAME} entre la demande de repli (${REPLI_DE}) et le merge (${P1}) : digest ${D_DE:-illisible} → ${D_P1:-illisible} — rejouer la demande de repli" \
                         "la branche de base a bougé pour ce palier entre la demande de repli et son merge — rejouer la demande de repli"
  B1=$(git -C "$GIT_WORKTREE" rev-parse -q --verify "${P1}:./${CERT_REL}" 2>/dev/null || true)
  B2=$(git -C "$GIT_WORKTREE" rev-parse -q --verify "${REPLI_DE}:./${CERT_REL}" 2>/dev/null || true)
  [ "$B1" = "$B2" ] \
    || fail REPLI_PERIME "le certificat ${CERT_REL} a changé sur ${GIT_BASE} entre la demande de repli et le merge — rejouer la demande de repli" \
                         "le certificat du palier a changé sur la branche de base entre la demande de repli et son merge — rejouer la demande de repli"
  echo "REPLI_OK : la PR est un repli (Repli-De ${REPLI_DE}) et ${GIT_BASE} n'a pas bougé pour ${APP_NAME}/${ENV_NAME} avant le merge"
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
echo "RECONCILE_OK : ${GIT_REPO}#${PR_NUMBER} mergée (${MERGE_SHA}) par '${GITEA_MERGED_BY}' (demandeur '${GITEA_REQUESTER}') — ${APP_NAME}/${ENV_NAME}, manifeste ${MANIFEST}, digest ${MERGED_DIGEST} = ${GIT_BASE}"
