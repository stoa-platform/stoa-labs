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
#   STOA_DEBUG   (opt) mode debug SANS FUITE (ci/lib/dbg.sh, plan L2) : chaque
#                décision de ce script se dit sur stderr, rédigée — le produit,
#                les refus et les rc ne bougent pas (test-provision-apply-a2.sh §E)
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
# LE MODE DEBUG (STOA_DEBUG, plan L2 ; preuve : test-provision-apply-a2.sh §E).
# dbg/dbg_kv de ci/lib/dbg.sh sont la SEULE voie de sortie : stderr seulement
# (stdout est le PRODUIT — RECONCILE_OK, relu par le pipeline), rédigé
# (littéraux connus du process et formes), `$?` préservé. Ce script ne redit
# pas ce que les autorités disent déjà (FORGE_KIND…, GIT_BASE…, les lignes
# HTTP) : il dit ce que LUI décide. Même résolution que ses libs ($SELF_DIR,
# posé AVANT le cd) ; absent ⇒ ERREUR nommée, comme toute lib manquante.
# dbg_init normalise et EXPORTE STOA_DEBUG : les enfants (forge-api.py,
# provision-apply-comment.sh) parlent avec la même valeur. Pas de DBG_NAME : le
# préfixe est le nom du script ($0), c'est ce qu'on lit dans un log Jenkins.
# Pas de DBG_SECRET_FILES : ce script ne tient que FORGE_SECRET, que dbg.sh
# relit dans l'environnement à chaque appel.
# shellcheck source=ci/lib/dbg.sh
. "$SELF_DIR/../ci/lib/dbg.sh" || { echo "ERREUR: ci/lib/dbg.sh introuvable ou illisible" >&2; exit 1; }
dbg_init
# shellcheck source=scripts/lib/repo-layout.sh
. "$(dirname "$0")/lib/repo-layout.sh" || { echo "ERREUR: lib/repo-layout.sh introuvable" >&2; exit 1; }
repo_layout_init || exit 2   # tiret NU + sentinelle « . » : « » n'arrive jamais de Jenkins
# Vide ⇒ « <vide> » : c'est LE diagnostic d'un PR_HORS_PERIMETRE chez un client
# qui a posé GIT_SUBDIR=. alors que sa forge préfixe les chemins (§E.1ab).
dbg_kv SUB_PFX "$SUB_PFX"
MANIFEST_DIR="${MANIFEST_DIR:-clients/provisioned/applications}"
dbg_kv MANIFEST_DIR "$MANIFEST_DIR"
dbg_kv GIT_WORKTREE "$GIT_WORKTREE"

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

# git_err_une_ligne <fichier> [coupe=400] — le stderr d'un geste git pour UNE
# ligne : masqué EN ENTIER (redact : littéraux du process + forme ://…@), PUIS
# mis sur une ligne, PUIS coupé (400 octets par défaut) — dans cet ordre et
# pas un autre.
# Sous GIT_TRACE=1 (le knob de debug de git, qu'un client pose à côté de
# STOA_DEBUG) git recopie l'URL NUE de l'origine (mesuré : 3 fois sur ≈ 600
# octets, git 2.42 — 601 en anglais, 613 en français : seule la ligne « fatal »
# varie, l'URL est aux mêmes offsets) ; couper AVANT de masquer laisserait un morceau de mot de
# passe orphelin de son « @ », que la forme ne rattrape plus — la mesure de
# git-base.sh (_git_base_stderr_relaye, §J.4e). L'ORDRE a son épreuve :
# test-provision-apply-a2 §E.4d (mot de passe de 512 octets, la coupe à 400
# tombe dedans) et son mutant §E.7c (coupe puis masque ⇒ le fragment passe).
# dbg rédige une seconde fois :
# le masque est un atome, c'est idempotent (dbg.sh, F.1-F.4). Here-string et
# non tube pour la coupe : head ne ferme jamais un tube sous un écrivain encore
# actif (SIGPIPE sous pipefail — même mesure).
# DEUX APPELANTS (tour 3 L2-B3) : la ligne de debug « git: » (400, sous dbg_on
# seulement — sans debug, ni python ni lecture, §E.6) et le REFUS
# GITEA_RECONCILE_ECHEC du fetch (200 : la longueur qu'il a toujours eue).
# Jusque-là ce refus relayait fetch.err BRUT, coupé avant tout masque : sous
# GIT_TRACE=1, 11 octets du mot de passe de l'URL dans le refus — ce qu'un
# client colle dans un ticket (mesuré ; §E.4e le garde, mutant §E.7f). Sur ce
# chemin python tourne sans STOA_DEBUG (redact ne dépend pas du mode) : python3
# est déjà exigé en amont (forge-api.sh, PYTHON3_REQUIS avant tout appel de
# forge, donc avant ce fetch) ; s'il mourait, « <rédaction indisponible> » —
# fail-closed. Le refus change de FORME, et de forme seulement : multi-ligne ⇒
# UNE ligne (tr), blancs de fin retirés (sed) — un stderr d'UNE ligne (le cas
# sans GIT_TRACE : git expurge lui-même l'userinfo) rend le refus OCTET POUR
# OCTET identique à l'ancien (mesuré tour 3, e4.se avant/après) ; aucune
# section B n'exerce un fetch en échec, seules E.4/E.4d-f le font (§E.4f).
git_err_une_ligne(){ local m; m="$(redact < "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"; head -c "${2:-400}" <<<"$m"; }

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
dbg_kv APP_NAME "$APP_NAME"
dbg_kv ENV_NAME "$ENV_NAME"
# Sans point ni slash possible dans APP_NAME (classe ci-dessus) : le chemin du
# manifeste ne peut pas sortir de MANIFEST_DIR.
MANIFEST="${MANIFEST_DIR}/${APP_NAME}.ansible.yml"
FORGE_MANIFEST="${SUB_PFX}${MANIFEST}"
FORGE_CERT="${SUB_PFX}clients/provisioned/certs/${APP_NAME}-${ENV_NAME}.crt"
# Les chemins tels que CE script les compose : celui que git lit, ceux que la
# forge compare (§3) — c'est l'écart entre les deux qu'on diagnostique.
dbg_kv MANIFEST "$MANIFEST"
dbg_kv FORGE_MANIFEST "$FORGE_MANIFEST"
dbg_kv FORGE_CERT "$FORGE_CERT"

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
# L'URL est UTILE (c'est elle qu'on diagnostique) ; un `user:secret@` qu'elle
# porterait est masqué par redact (forme ://…@), l'hôte reste (§E.5a).
dbg_kv GIT_CLONE_URL "$GIT_CLONE_URL"
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
# Sur SUCCÈS, forge.err ne porte que la ligne de debug de forge-api.py
# (« GET …/pulls/n -> HTTP 200 ») : sans relais elle serait PERDUE — la capture
# n'existe que pour que la cause d'un refus précède le verdict. Sans debug le
# fichier est vide et rien ne s'écrit (§E.1o ; mutant §E.7a).
[ -s "$TMP/forge.err" ] && cat "$TMP/forge.err" >&2
# Ce que la forge a rendu, en UNE ligne, AVANT le schéma et la confrontation :
# un refus qui suit se lit avec ses données. Valeurs BRUTES, comme la jumelle
# de gitea-pr-confirm.sh : dbg masque, et il masque APRÈS — pas `shown` ici.
# `shown` (head -c 80 puis %q) transforme AVANT le masque : le %q défait un
# littéral qui porte un espace ou un « $ » (« <secret masqué>\ w0rd\$2026\! »,
# 10 caractères sur 15 en clair) et la coupe à 80 tranche dans un secret qui
# la chevauche (« …rrrtok-a ») — l'ordre coupe-puis-masque que ce lot interdit
# partout (relecture finale I-3 ; test-provision-apply-a2 §E.9, mutants E.9e/f).
# Cette ligne n'est pas relayée sur la PR : rien à échapper ; forge-api refuse
# déjà un retour-ligne dans une valeur de forge (B.7).
dbg "PR #${PR_NUMBER} relue : state=${R_STATE_RAW} head=${R_HEAD_REF} base=${R_BASE_REF} merged=${R_MERGED} merge_sha=${R_MERGE_SHA} merged_by=${R_MERGED_BY}"
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
# Même relais que forge.err : sur succès, les lignes de debug de la pagination
# (« GET …/files?page=n -> HTTP 200 ») seraient perdues (§E.1q).
[ -s "$TMP/files.err" ] && cat "$TMP/files.err" >&2
# Hors périmètre = tout chemin qui n'est ni le manifeste ni le certificat DE CE
# PALIER ; montrés au plus cinq, tronqués, sans blanc (ils entrent dans un
# message d'une ligne relayé sur la PR).
EXTRA=$(grep -vxF -e "$FORGE_MANIFEST" -e "$FORGE_CERT" "$TMP/files" | sort -u | head -5 | cut -c1-120 | tr ' ' '_' | tr '\n' ' ')
FILES_VERDICT=FILES_OK
if [ ! -s "$TMP/files" ]; then FILES_VERDICT=FILES_VIDE
elif [ -n "$EXTRA" ]; then FILES_VERDICT="FILES_HORS ${EXTRA% }"
fi
dbg_kv FILES_VERDICT "$FILES_VERDICT"   # déjà borné : cinq chemins au plus, tronqués
case "$FILES_VERDICT" in
  FILES_OK) ;;
  FILES_VIDE)  fail PR_HORS_PERIMETRE "${GIT_REPO}#${PR_NUMBER} ne modifie aucun fichier — rien à projeter" "la PR ne modifie aucun fichier" ;;
  FILES_HORS*) fail PR_HORS_PERIMETRE "${GIT_REPO}#${PR_NUMBER} touche des fichiers hors de son manifeste/certificat (${FILES_VERDICT#FILES_HORS }) — l'aval checkoute l'arbre ENTIER au SHA mergé : refus" \
                                      "la PR touche des fichiers hors de son manifeste et de son certificat de palier (${FILES_VERDICT#FILES_HORS })" ;;
  *)           fail GITEA_RECONCILE_ECHEC "verdict de périmètre inattendu ($(shown "$FILES_VERDICT"))" ;;
esac

# ── 4. GIT = LA VÉRITÉ sur la branche de base : ancêtre, palier non supplanté ─
# Chaque geste git : son rc est CAPTURÉ (`cmd; RC_GIT=$?`) et dit AVANT le
# verdict — le VRAI rc, pas un `||` qui le résume ; la décision qui suit est la
# même qu'avant (mêmes refus, mêmes codes, mêmes messages : §B reste vert sans
# STOA_DEBUG). Le stderr du fetch est relayé, masqué avant coupe
# (git_err_une_ligne) — dans la ligne de debug (400) ET dans le refus (200 :
# tour 3 L2-B3, il le relayait BRUT, voir le helper) ; celui de merge-base
# n'est pas capturé (il n'a jamais été jeté : il tombe dans le journal, comme
# avant).
git -C "$GIT_WORKTREE" fetch -q origin "$GIT_BASE" 2>"$TMP/fetch.err"; RC_GIT=$?
dbg "git fetch origin ${GIT_BASE} -> rc ${RC_GIT}"
if dbg_on && [ -s "$TMP/fetch.err" ]; then dbg "  git: $(git_err_une_ligne "$TMP/fetch.err")"; fi
[ "$RC_GIT" -eq 0 ] \
  || fail GITEA_RECONCILE_ECHEC "git fetch origin ${GIT_BASE} en échec dans ${GIT_WORKTREE} : $(git_err_une_ligne "$TMP/fetch.err" 200)"
# rc 1 = pas un ancêtre : C'EST la décision MERGE_SHA_NON_ANCETRE ; 128 = SHA
# inconnu du dépôt (le refus est le même, la ligne dit lequel — §E.3a).
git -C "$GIT_WORKTREE" merge-base --is-ancestor "$MERGE_SHA" "origin/${GIT_BASE}"; RC_GIT=$?
dbg "git merge-base --is-ancestor ${MERGE_SHA} origin/${GIT_BASE} -> rc ${RC_GIT}"
[ "$RC_GIT" -eq 0 ] \
  || fail MERGE_SHA_NON_ANCETRE "${MERGE_SHA} n'est pas un ancêtre de ${GIT_BASE} — le SHA ne correspond pas à un commit fusionné sur la branche protégée" \
                                "le SHA de merge n'est pas sur ${GIT_BASE}"
# Les `2>/dev/null` des `git show` restent : leur message ne dit rien que le rc
# et le refus (chemin, SHA) ne disent déjà — la ligne de debug porte les deux.
# Chacune des quatre a son rc 128 devant le refus (§E.3d-i : c0, master sans le
# manifeste ; §E.8g-h : Repli-De = c0, parent 1 sans le manifeste) et son mutant
# « rc 0 en dur » (§E.7e).
git -C "$GIT_WORKTREE" show "${MERGE_SHA}:./${MANIFEST}" > "$TMP/merged.yml" 2>/dev/null; RC_GIT=$?
dbg "git show ${MERGE_SHA}:./${MANIFEST} -> rc ${RC_GIT}"
[ "$RC_GIT" -eq 0 ] \
  || fail MANIFESTE_ABSENT "${MANIFEST} absent de l'arbre au SHA mergé ${MERGE_SHA}" "le manifeste de l'application est absent au SHA mergé"
git -C "$GIT_WORKTREE" show "origin/${GIT_BASE}:./${MANIFEST}" > "$TMP/base.yml" 2>/dev/null; RC_GIT=$?
dbg "git show origin/${GIT_BASE}:./${MANIFEST} -> rc ${RC_GIT}"
[ "$RC_GIT" -eq 0 ] \
  || fail MANIFESTE_ABSENT "${MANIFEST} absent de ${GIT_BASE} (application retirée depuis ?) — rien à projeter" "le manifeste de l'application n'est plus sur ${GIT_BASE}"
MERGED_DIGEST=$(app_manifest_digest_env "$TMP/merged.yml" "$ENV_NAME" 2>"$TMP/dg.err") \
  || fail PALIER_ABSENT "le manifeste au SHA mergé ne déclare pas le palier ${ENV_NAME} ou est illisible : $(head -c 200 "$TMP/dg.err" | tr '\n' ' ')" \
                        "le manifeste au SHA mergé ne déclare pas ce palier (ou est illisible)"
dbg_kv MERGED_DIGEST "$MERGED_DIGEST"
BASE_DIGEST=$(app_manifest_digest_env "$TMP/base.yml" "$ENV_NAME" 2>"$TMP/dg2.err") \
  || fail PALIER_SUPPLANTE "${GIT_BASE} ne déclare plus le palier ${ENV_NAME} pour ${APP_NAME} (ou son manifeste est illisible) : $(head -c 200 "$TMP/dg2.err" | tr '\n' ' ') — rejouer une demande" \
                           "la branche de base ne déclare plus ce palier pour cette application"
dbg_kv BASE_DIGEST "$BASE_DIGEST"   # ≠ MERGED_DIGEST ⇒ PALIER_SUPPLANTE : les deux se lisent avant le verdict
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
# Le `2>/dev/null` du rev-parse reste : ${MERGE_SHA}^2 est une ref FACULTATIVE
# (absente de tout commit sans second parent — squash, fast-forward), son
# absence est le cas normal, pas un diagnostic. REPLI_DE se dit ensuite, vide
# compris : « <vide> » = pas un repli, le bloc est inerte (§E.1y).
P2=$(git -C "$GIT_WORKTREE" rev-parse -q --verify "${MERGE_SHA}^2" 2>/dev/null || true)
REPLI_DE=""
[ -n "$P2" ] && REPLI_DE=$(git -C "$GIT_WORKTREE" log -1 --format=%B "$P2" | sed -n 's/^Repli-De: \([0-9a-f]\{40\}\).*/\1/p' | head -1)
dbg_kv REPLI_DE "$REPLI_DE"
if [ -n "$REPLI_DE" ]; then
  P1=$(git -C "$GIT_WORKTREE" rev-parse "${MERGE_SHA}^1")
  CERT_REL="clients/provisioned/certs/${APP_NAME}-${ENV_NAME}.crt"
  git -C "$GIT_WORKTREE" show "${P1}:./${MANIFEST}" > "$TMP/p1.yml" 2>/dev/null; RC_GIT=$?
  dbg "git show ${P1}:./${MANIFEST} -> rc ${RC_GIT}"
  [ "$RC_GIT" -eq 0 ] \
    || fail REPLI_PERIME "${MANIFEST} absent de ${GIT_BASE} juste avant le merge (${P1}) — ${GIT_BASE} a bougé depuis la demande de repli ; rejouer la demande de repli" \
                         "la branche de base a bougé pour ce palier entre la demande de repli et son merge (manifeste absent avant le merge) — rejouer la demande de repli"
  git -C "$GIT_WORKTREE" show "${REPLI_DE}:./${MANIFEST}" > "$TMP/de.yml" 2>/dev/null; RC_GIT=$?
  dbg "git show ${REPLI_DE}:./${MANIFEST} -> rc ${RC_GIT}"
  [ "$RC_GIT" -eq 0 ] \
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
