#!/usr/bin/env bash
# scripts/app-rollback-request.sh — LE REPLI D'UNE APPLICATION EST UNE PR (A6, ADR-089).
#
# « On promeut la demande, pas l'objet » (GOAL cd-applications) — alors on REPLIE
# la demande : ce script ouvre une PR provision/<app>-<env> dont la ligne
# `per_env.<env>` et le certificat `certs/<app>-<env>.crt` redeviennent, à
# l'octet, ceux du merge PRÉCÉDENT (N-1) de cette même branche. La chaîne
# existante (merge → provision-apply → selfservice-app-deploy) l'applique
# comme tout apply : mêmes portes, même rôle, même GUID, même clé (spike S1).
# C'est le port d'ADR-085 (G6 écrivait N-1 verbatim dans un commit NEUF sur
# la branche de base) à l'objet dont « la PR est le fichier de déploiement ».
#
# ORDRE = LA PROPRIÉTÉ (rien n'est poussé avant le dernier refus ; chaque étape
# imprime `ETAPE <nom>`) : forme → chaîne (épinglée par l'appelant) → porte
# (GATE_REFS_REQUIRED AVANT tout clone, AVANT tout appel de forge) → clone avec
# historique → manifeste + naissance (BIRTH) → lignée (forge = la vérité sur
# les PR, Git = la vérité sur la branche de base, bornée à la vie courante du manifeste) →
# cohérence → ligne candidate en mémoire (N-1 ⊕ change_ref) → ETAT_IDENTIQUE →
# restauration → auto-vérification → PR en cours / EXIST strict → tête
# distante en bail → commit (trailers) + push --force-with-lease + ouverture
# de la PR (forge pr_open) + plan enchaîné.
#
# LA FORGE N'EST PLUS GITEA EN DUR (2026-09-09, client sur GitLab) : tout appel
# passe par scripts/lib/forge-api.sh (verbes pr_list_merged, pr_find_open,
# pr_open ; whoami via forge-identity.sh) — visage FORGE_KIND=gitea|gitlab,
# base d'API, en-tête d'auth et garde de réponse vivent LÀ, avec une cause
# auto-diagnostique sur stderr ; ici l'appelant NOMME le refus (FORGE_ILLISIBLE,
# PR_ECHEC…), les tags ne bougent pas. Le python qui reste ne compose que du
# TEXTE (ligne candidate, corps de PR) : plus jamais de réseau.
#
# Entrées (env) : REQ_APP REQ_ENV REQ_REASON (requis), REQ_CHANGE_REF,
#   REQ_CALLER (défaut unknown), FORGE_SECRET (requis), GIT_HOST (requis) GIT_REPO
#   GIT_BASE GIT_SUBDIR GIT_CLONE_URL GITEA_SERVICE_LOGINS STOA_ENV_CHAIN_FILE
#   PROVISION_PLAN_INLINE ROLLBACK_OUT ; FORGE_KIND FORGE_API_AUTH (cf. forge-api.py).
# Sorties : ETAPE …, LIGNEE : …, REPLI_DU_REPLI : … (le cas échéant),
#   PR_URL=…, REPLI_DE=… REPLI_VERS=… REPLI_DIGEST=… ; ROLLBACK_OUT (KEY=VALUE).
# rc 0 (PR créée, ou EXIST), 2 refus nommé `REFUS: <TAG> : <phrase>`, 1 erreur.
# shellcheck disable=SC2016  # le python et l'askpass sont en quotes simples à dessein
set -uo pipefail
set +x
cd "$(dirname "$0")/.." || exit 1
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/env-chain.sh
. "$SELF_DIR/lib/env-chain.sh" || { echo "ERREUR: $SELF_DIR/lib/env-chain.sh introuvable" >&2; exit 1; }
# shellcheck source=scripts/lib/app-manifest.sh
. "$SELF_DIR/lib/app-manifest.sh" || { echo "ERREUR: $SELF_DIR/lib/app-manifest.sh introuvable" >&2; exit 1; }
# shellcheck source=scripts/lib/forge-identity.sh
. "$SELF_DIR/lib/forge-identity.sh" || { echo "ERREUR: $SELF_DIR/lib/forge-identity.sh introuvable" >&2; exit 1; }
# shellcheck source=scripts/lib/forge-api.sh
. "$SELF_DIR/lib/forge-api.sh" || { echo "ERREUR: $SELF_DIR/lib/forge-api.sh introuvable" >&2; exit 1; }

# Même règle que provision-request.sh : un champ obligatoire vide se NOMME
# (CHAMP_REQUIS + le champ du formulaire), jamais un `${VAR:?}` de bash.
requis(){ case "${2//[[:space:]]/}" in "") echo "REFUS: CHAMP_REQUIS : $1 est vide — obligatoire ($3). Rien n'a été tenté." >&2; exit 2;; esac; }
REQ_APP="${REQ_APP:-}"; requis REQ_APP "$REQ_APP" "formulaire app-rollback : champ « APP », l'application à replier"
REQ_ENV="${REQ_ENV:-}"; requis REQ_ENV "$REQ_ENV" "formulaire app-rollback : champ « ENV », le palier à replier"
REQ_REASON="${REQ_REASON:-}"; requis REQ_REASON "$REQ_REASON" "formulaire app-rollback : champ « REASON », le motif du repli"
REQ_CHANGE_REF="${REQ_CHANGE_REF:-}"
REQ_CALLER="${REQ_CALLER:-unknown}"
# Le secret de la forge porte un nom NEUTRE (2026-09-04) : un gestionnaire
# d'identite rend un jeton OU un couple, et pour git comme pour l'API les deux
# occupent la meme place. FORGE_SECRET est le nom ; FORGE_SECRET reste honore.
FORGE_SECRET="${FORGE_SECRET:-${GITEA_TOKEN:-}}"
[ -n "$FORGE_SECRET" ] || { echo "REFUS: SECRET_FORGE_REQUIS : ni FORGE_SECRET ni son alias GITEA_TOKEN — le secret de la forge (jeton, ou mot de passe d'un couple avec FORGE_USER)" >&2; exit 2; }
export FORGE_SECRET
GIT_HOST="${GIT_HOST:?GIT_HOST requis (base de la forge, ex. https://forge.client) — aucun repli}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"   # l'adresse HUMAINE, si elle diffère de celle vue par le CI
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
# GIT_BASE n'a plus de défaut « main » (L3, 2026-09-10) : elle est POSÉE à
# l'étape 4, sous l'enveloppe d'authentification du clone (git-base.sh).
# shellcheck source=scripts/lib/repo-layout.sh
. "$(dirname "$0")/lib/repo-layout.sh" || { echo "ERREUR: lib/repo-layout.sh introuvable" >&2; exit 1; }
repo_layout_init || exit 2
# shellcheck source=scripts/lib/git-base.sh
. "$(dirname "$0")/lib/git-base.sh" || { echo "ERREUR: lib/git-base.sh introuvable" >&2; exit 1; }
# Le visage et la base d'API sont posés UNE fois (GIT_HOST, GIT_REPO, FORGE_KIND
# défaut gitea) — aucun appel réseau ici : les refus de forme restent muets.
forge_api_init || exit 2
# schéma conservé (cf. provision-request.sh) : « http:// » forcé cassait toute forge TLS
case "$GIT_HOST" in http://*|https://*|file://*) GIT_BASE_URL="${GIT_HOST%/}";; *) GIT_BASE_URL="http://${GIT_HOST%/}";; esac
GIT_CLONE_URL="${GIT_CLONE_URL:-${GIT_BASE_URL}/${GIT_REPO}.git}"
GITEA_SERVICE_LOGINS="${GITEA_SERVICE_LOGINS:-ci}"
PROVISION_PLAN_INLINE="${PROVISION_PLAN_INLINE:-true}"
ROLLBACK_OUT="${ROLLBACK_OUT:-}"
MAN_PATH="${SUB_PFX}clients/provisioned/applications/${REQ_APP}.ansible.yml"
CERT_PATH="${SUB_PFX}clients/provisioned/certs/${REQ_APP}-${REQ_ENV}.crt"
BRANCH="provision/${REQ_APP}-${REQ_ENV}"
[ -n "$ROLLBACK_OUT" ] && rm -f "$ROLLBACK_OUT"
WORK="$(mktemp -d /tmp/approll.XXXXXX)"; trap 'rm -rf "$WORK"' EXIT
# ── A7 — les tokens par FICHIER ; le token humain (FORGE_TOKEN / FORGE_TOKEN_FILE)
# est copié puis RETIRÉ de l'environnement avant tout processus enfant.
umask 077
FORGE_TF=""
if [ -n "${FORGE_TOKEN_FILE:-}" ] && [ -s "${FORGE_TOKEN_FILE}" ]; then
  FORGE_TF="$WORK/forge-token"; tr -d '\r\n' < "$FORGE_TOKEN_FILE" > "$FORGE_TF"
elif [ -n "${FORGE_TOKEN:-}" ]; then
  FORGE_TF="$WORK/forge-token"; printf '%s' "$FORGE_TOKEN" > "$FORGE_TF"
fi
unset FORGE_TOKEN FORGE_TOKEN_FILE
CI_TF="$WORK/ci-token"; printf '%s' "$FORGE_SECRET" > "$CI_TF"
# Défauts = le compte de service ; l'identité (§3bis) les remplace quand un token humain existe.
FORGE_LOGIN="(service)"; PUSH_LOGIN=ci; PUSH_TF="$CI_TF"

etape(){ echo "ETAPE $*"; }
refus(){ echo "REFUS: $1 : $2" >&2; exit 2; }
shown(){ printf '%q' "$(printf '%s' "${1:-}" | head -c 80)"; }

# ── 1. FORME, avant tout réseau ──────────────────────────────────────────────
etape forme
printf '%s' "$REQ_APP" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
  || refus APP_INVALIDE "REQ_APP hors de ^[a-z0-9][a-z0-9-]*\$ (valeur : $(shown "$REQ_APP"))"
printf '%s' "$REQ_ENV" | grep -Eq '^[a-z0-9]+$' \
  || refus ENV_INVALIDE "REQ_ENV hors de ^[a-z0-9]+\$ (valeur : $(shown "$REQ_ENV"))"
REQ_REASON="$REQ_REASON" python3 -c 'import os,re,sys; r=os.environ["REQ_REASON"]; sys.exit(0 if 1 <= len(r) <= 300 and not re.search(r"[\r\n`<>#@\[\]\\]", r) else 1)' \
  || refus MOTIF_INVALIDE "REQ_REASON : 1 à 300 caractères, sans retour-ligne ni \` < > # @ [ ] \\ (il entre dans un commit et dans le corps markdown de la PR)"
if [ -n "$REQ_CHANGE_REF" ]; then
  printf '%s' "$REQ_CHANGE_REF" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
    || refus REF_INVALIDE "REQ_CHANGE_REF hors de ^[A-Za-z0-9][A-Za-z0-9._-]*\$ (valeur : $(shown "$REQ_CHANGE_REF")) — il entre dans un flow mapping YAML"
fi
printf '%s' "$REQ_CALLER" | grep -Eq '^[A-Za-z0-9._:@-]+$' \
  || refus CALLER_INVALIDE "REQ_CALLER hors de ^[A-Za-z0-9._:@-]+\$ (valeur : $(shown "$REQ_CALLER"))"

# ── 2. CHAÎNE (source épinglée par l'appelant : STOA_ENV_CHAIN_FILE) ─────────
etape chaine
env_chain_validate 2>"$WORK/chain.err" || refus CHAINE_INVALIDE "$(head -c 200 "$WORK/chain.err" | tr '\n' ' ')"
CHAIN="$(env_chain 2>/dev/null)" || refus CHAINE_INVALIDE "env_chain illisible"
case " $CHAIN " in
  *" $REQ_ENV "*) ;;
  *) refus ENV_INVALIDE "'$REQ_ENV' hors de la chaîne ($CHAIN)" ;;
esac

# ── 3. PORTE : change_ref exigé au repli comme à la demande (G6-D3) ───────────
etape porte
GATE="$(env_chain_gate "$REQ_ENV" 2>/dev/null)" || refus CHAINE_INVALIDE "env_chain_gate '$REQ_ENV' illisible"
case "$GATE" in
  GATE=1\|*) [ -n "$REQ_CHANGE_REF" ] || refus GATE_REFS_REQUIRED "la porte vers '$REQ_ENV' exige change_ref au repli comme à la demande (requireChangeRef ou itsmCheck) — fournir REQ_CHANGE_REF ; aucune PR ouverte" ;;
  GATE=0\|*) ;;
  *) refus CHAINE_INVALIDE "porte illisible ($(shown "$GATE"))" ;;
esac

# ── 3bis. L'IDENTITÉ DE FORGE (A7) — après la porte, AVANT tout clone et toute forge ──
# Sans token humain, il n'y a pas d'humain (le job n'a qu'un token de service) :
# sous fourEyes, la PR de repli serait refusée REQUESTER_UNKNOWN à l'apply — refus
# ici, au plus tôt, aucune PR ouverte. Avec un token : le login est demandé à la
# forge (forge-identity.sh, `forge whoami` : scope read:user).
FOUREYES="$(env_chain_gate_four_eyes "$REQ_ENV")" || refus CHAINE_INVALIDE "fourEyes de '$REQ_ENV' illisible"
FOUREYES="${FOUREYES#FOUREYES=}"
if [ -n "$FORGE_TF" ]; then
  etape identite
  # La base d'API n'est plus composée ici : forge_login la tient de forge_api_init
  # (GIT_HOST, FORGE_KIND) — le premier argument, historique, reste vide.
  FORGE_LOGIN="$(forge_login "" "$FORGE_TF")" || { rc=$?; [ "$rc" = 2 ] && exit 2; exit 1; }
  forge_is_service "$FORGE_LOGIN" "$GITEA_SERVICE_LOGINS" && FORGE_LOGIN="(service)"
fi
[ "$FOUREYES" != 1 ] || [ "$FORGE_LOGIN" != "(service)" ] \
  || refus REQUESTER_UNKNOWN "la porte vers '$REQ_ENV' exige les quatre yeux ; une PR de repli ouverte par un compte de service (${GITEA_SERVICE_LOGINS}) serait refusée REQUESTER_UNKNOWN à l'apply — fournir FORGE_TOKEN (votre token de forge, scopes read:user + write:repository) ; aucune PR ouverte"
PUSH_LOGIN="$FORGE_LOGIN"; [ "$PUSH_LOGIN" = "(service)" ] && PUSH_LOGIN=ci
PUSH_TF="${FORGE_TF:-$CI_TF}"

# ── 4. CLONE avec historique (jamais --depth, jamais --filter : la lignée se lit sur la branche de base ; un clone partiel boucle en fetchs paresseux contre une origine shallow — mesuré) ─────
# A7 : l'askpass rend le login du POUSSEUR et le token lu dans son fichier (humain
# s'il y en a un, service sinon) — jamais en argv, jamais dans une URL.
ASKPASS="$(forge_askpass "$WORK" "$PUSH_LOGIN" "$PUSH_TF")" || refus CABLAGE_INCOMPLET "askpass"
export GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0
# LA BRANCHE DE BASE, ICI et pas plus haut : GIT_ASKPASS vient d'être EXPORTÉ, le
# `git ls-remote` de la lib hérite donc de la MÊME enveloppe que le clone qui
# suit. `etape clone` la NOMME : l'étape ne peut pas annoncer une branche avant
# que le dépôt ait dit laquelle. Refus déjà nommé par la lib, rc 2, rien d'écrit.
git_base_init "$GIT_CLONE_URL" || exit 2
etape clone "$GIT_BASE"
R="$WORK/repo"
git clone -q --single-branch --branch "$GIT_BASE" "$GIT_CLONE_URL" "$R" 2>"$WORK/clone.err" \
  || refus CLONE_ECHEC "clone de ${GIT_REPO} (${GIT_BASE}) impossible : $(grep -v -F -- "$(cat "$PUSH_TF")" "$WORK/clone.err" | grep -v -F -- "$FORGE_SECRET" | head -c 200 | tr '\n' ' ')"
[ "$(git -C "$R" rev-parse --is-shallow-repository)" = false ] \
  || refus LIGNEE_TRONQUEE "le clone de ${GIT_BASE} est shallow — un historique tronqué ne peut pas prouver l'absence d'un état précédent"
g(){ git -C "$R" "$@"; }
g config user.email "${CI_COMMIT_EMAIL:-ci@bc.example}"; g config user.name "${CI_COMMIT_NAME:-provisioning (service ci)}"

# ── 5. MANIFESTE sur la branche de base, palier déclaré, naissance courante ───
etape manifeste
[ -f "$R/$MAN_PATH" ] || refus MANIFESTE_ABSENT "${MAN_PATH} absent de ${GIT_BASE} — rien à replier (application retirée ?)"
app_manifest_read "$R/$MAN_PATH" >/dev/null 2>"$WORK/read.err" || refus MANIFESTE_INVALIDE "$(head -c 200 "$WORK/read.err" | tr '\n' ' ')"
D_BASE=$(app_manifest_digest_env "$R/$MAN_PATH" "$REQ_ENV" 2>"$WORK/dg.err") \
  || refus PALIER_ABSENT "${GIT_BASE} ne déclare pas per_env.${REQ_ENV} pour ${REQ_APP} : $(head -c 200 "$WORK/dg.err" | tr '\n' ' ')"
BIRTH=$(g log --first-parent --diff-filter=A --format=%H -1 -- "$MAN_PATH")
[ -n "$BIRTH" ] || refus MANIFESTE_INVALIDE "naissance de ${MAN_PATH} introuvable sur la première parenté de ${GIT_BASE}"

# ── 6. LIGNÉE : forge (PR mergées de la branche) ordonnée par Git, bornée à BIRTH ──
etape lignee
g rev-list --first-parent "$GIT_BASE" > "$WORK/firstparent"
# `forge pr_list_merged` : une ligne par PR mergée de cette tête, quel que soit
# le visage — NUMBER= MERGE_SHA= BASE_REF= SAME_REPO= HEAD_REPO= ; rc 2 + cause
# sur stderr si la forge est en panne, illisible ou hors forme (liste attendue).
# L'ORDRE de merge se lit dans Git (position du merge_commit_sha sur la première
# parenté de la base), jamais dans l'ordre que la forge rend.
forge pr_list_merged "$BRANCH" > "$WORK/merged" 2>"$WORK/merged.err" \
  || { cat "$WORK/merged.err" >&2; refus FORGE_ILLISIBLE "lecture des PR mergées de ${BRANCH} en échec (cause ci-dessus)"; }
: > "$WORK/lineage"; : > "$WORK/seen"
set -f   # les champs sont découpés sur les blancs, jamais développés en chemins
while IFS= read -r line; do
  [ -n "$line" ] || continue
  L_NUMBER=""; L_MERGE_SHA=""; L_BASE_REF=""; L_SAME_REPO=""; L_HEAD_REPO=""
  for kv in $line; do
    case "$kv" in
      NUMBER=*) L_NUMBER="${kv#*=}" ;; MERGE_SHA=*) L_MERGE_SHA="${kv#*=}" ;; BASE_REF=*) L_BASE_REF="${kv#*=}" ;;
      SAME_REPO=*) L_SAME_REPO="${kv#*=}" ;; HEAD_REPO=*) L_HEAD_REPO="${kv#*=}" ;;
    esac
  done
  # mergée ailleurs que sur la base : pas un état de la base
  [ "$L_BASE_REF" = "$GIT_BASE" ] || continue
  [ "$L_SAME_REPO" = 1 ] \
    || refus LIGNEE_AMBIGUE "la PR #${L_NUMBER} mergée sur ${BRANCH} vient d'un fork (${L_HEAD_REPO}) — une lignée que personne n'a voulue, refus"
  case "$L_NUMBER" in ''|*[!0-9]*) refus FORGE_ILLISIBLE "PR #$(shown "$L_NUMBER") : numéro illisible" ;; esac
  case "$L_MERGE_SHA" in ''|*[!0-9a-f]*) refus FORGE_ILLISIBLE "PR #${L_NUMBER} : merge_commit_sha illisible" ;; esac
  [ "${#L_MERGE_SHA}" = 40 ] || refus FORGE_ILLISIBLE "PR #${L_NUMBER} : merge_commit_sha illisible"
  POS=$(grep -m1 -nxF "$L_MERGE_SHA" "$WORK/firstparent" | cut -d: -f1)
  [ -n "$POS" ] \
    || refus FORGE_INCOHERENTE "la PR #${L_NUMBER} (mergée, ${BRANCH}) a un merge_commit_sha $(printf '%s' "$L_MERGE_SHA" | cut -c1-7) absent de la première parenté de ${GIT_BASE} — historique réécrit ou base changée, refus"
  grep -qxF "$L_MERGE_SHA" "$WORK/seen" && continue
  printf '%s\n' "$L_MERGE_SHA" >> "$WORK/seen"
  printf 'CAND %d %s %s\n' "$((POS - 1))" "$L_MERGE_SHA" "$L_NUMBER" >> "$WORK/lineage"
done < "$WORK/merged"
set +f
# borne : seuls les merges dont BIRTH est ancêtre-ou-égal comptent (la vie courante du manifeste)
: > "$WORK/lineage.ok"
while read -r _c pos sha num; do
  [ "$_c" = CAND ] || continue
  if g merge-base --is-ancestor "$BIRTH" "$sha"; then printf '%s %s %s\n' "$pos" "$sha" "$num" >> "$WORK/lineage.ok"; fi
done < "$WORK/lineage"
sort -n "$WORK/lineage.ok" > "$WORK/lineage.sorted"
N_COUNT=$(grep -c . "$WORK/lineage.sorted" || true)
[ "$N_COUNT" -ge 1 ] || refus AUCUNE_LIGNEE "aucune PR ${BRANCH} mergée sur ${GIT_BASE} depuis la création du manifeste (candidats forge : $(grep -c '^CAND ' "$WORK/lineage" || true), naissance $(printf '%s' "$BIRTH" | cut -c1-7)) — rien à replier"
SHA_N=$(sed -n '1p' "$WORK/lineage.sorted" | cut -d' ' -f2); NUM_N=$(sed -n '1p' "$WORK/lineage.sorted" | cut -d' ' -f3)
echo "LIGNEE : $(awk '{printf "#%s (%s) ", $3, substr($2,1,7)}' "$WORK/lineage.sorted")"
[ "$N_COUNT" -ge 2 ] || refus AUCUN_ETAT_PRECEDENT "un seul état mergé pour ${REQ_APP}/${REQ_ENV} (#${NUM_N}) : un repli restaure l'état précédent, il n'y en a pas — le retrait d'une application est une SUSPENSION (règle 2 du spike), pas un repli"
SHA_N1=$(sed -n '2p' "$WORK/lineage.sorted" | cut -d' ' -f2); NUM_N1=$(sed -n '2p' "$WORK/lineage.sorted" | cut -d' ' -f3)

# ── 7. COHÉRENCE : la base == #N pour ce palier ; racine(N-1) == racine(N) ────
etape coherence
g show "${SHA_N}:${MAN_PATH}" > "$WORK/n.yml" 2>/dev/null || refus MANIFESTE_INVALIDE "${MAN_PATH} absent au merge #${NUM_N}"
g show "${SHA_N1}:${MAN_PATH}" > "$WORK/n1.yml" 2>/dev/null || refus MANIFESTE_INVALIDE "${MAN_PATH} absent au merge #${NUM_N1}"
D_N=$(app_manifest_digest_env "$WORK/n.yml" "$REQ_ENV" 2>/dev/null) || refus PALIER_ABSENT "per_env.${REQ_ENV} absent au merge #${NUM_N}"
[ "$D_BASE" = "$D_N" ] \
  || refus REFERENCE_DIVERGENTE "${GIT_BASE} porte pour ${REQ_APP}/${REQ_ENV} un état qu'aucune PR ne porte (digest ${GIT_BASE} ${D_BASE} ≠ #${NUM_N} ${D_N}) — écriture hors flux ; corriger ${GIT_BASE} par une demande avant de replier"
python3 - "$WORK/n1.yml" "$WORK/n.yml" <<'PY' || refus RACINE_DIVERGENTE "la racine du manifeste diffère entre #${NUM_N1} et #${NUM_N} (édition hors flux) — le repli ne restaure que per_env.${REQ_ENV} et son certificat, il ne peut pas restaurer une racine sans toucher les autres paliers"
import sys, yaml
def root(p):
    d = yaml.load(open(p, encoding="utf-8"), Loader=yaml.BaseLoader)["apim_ss_app"]
    return {k: v for k, v in d.items() if k != "per_env"}
sys.exit(0 if root(sys.argv[1]) == root(sys.argv[2]) else 1)
PY

# ── 8. LIGNE CANDIDATE, en mémoire : N-1 à l'octet ⊕ change_ref ──────────────
etape candidate
CANDIDATE_REF="$REQ_CHANGE_REF"
A6_REF="$CANDIDATE_REF" A6_ENV="$REQ_ENV" python3 - "$WORK/n1.yml" "$WORK/candidate" <<'PY' > "$WORK/cand.out" || refus MANIFESTE_INVALIDE "ligne per_env.${REQ_ENV} de #${NUM_N1} illisible : $(head -c 200 "$WORK/cand.out")"
import io, os, re, sys, yaml
src, out = sys.argv[1], sys.argv[2]; env, ref = os.environ["A6_ENV"], os.environ["A6_REF"]
lines = open(src, encoding="utf-8").read().splitlines()
heads = [i for i, l in enumerate(lines) if re.match(r"^  per_env:\s*(#.*)?$", l)]
if len(heads) != 1: print("REFUS LIGNE_INTROUVABLE bloc per_env absent ou multiple"); sys.exit(0)
start = heads[0] + 1; end = start
while end < len(lines) and lines[end].startswith("    "): end += 1
key_re = re.compile(r"^    ([\"']?)%s\1:\s*(.*)$" % re.escape(env))
hits = [i for i in range(start, end) if key_re.match(lines[i])]
if len(hits) != 1: print("REFUS LIGNE_INTROUVABLE per_env.%s : %d ligne(s) au merge N-1" % (env, len(hits))); sys.exit(0)
mapping = key_re.match(lines[hits[0]]).group(2).strip()
base = yaml.load(io.StringIO(mapping), Loader=yaml.BaseLoader)
if not isinstance(base, dict): print("REFUS LIGNE_INTROUVABLE per_env.%s n est pas un mapping flow" % env); sys.exit(0)
occ = len(re.findall(r"\bchange_ref\s*:", mapping))
if occ > 1: print("REFUS LIGNE_AMBIGUE per_env.%s au merge N-1 porte %d cles change_ref" % (env, occ)); sys.exit(0)
cand = mapping
if ref:
    pat = re.compile(r"(\bchange_ref\s*:\s*)(\"[^\"]*\"|'[^']*'|[^,}\s]+)")
    if occ == 1:
        cand = pat.sub(lambda m: m.group(1) + '"' + ref + '"', mapping, count=1)
    else:
        inner = mapping.rstrip()
        if not inner.endswith("}"): print("REFUS LIGNE_INTROUVABLE per_env.%s : mapping flow sans accolade fermante" % env); sys.exit(0)
        body = inner[:-1].rstrip()
        cand = ("%s, change_ref: \"%s\" }" % (body, ref)) if body.strip("{ ") else ("{ change_ref: \"%s\" }" % ref)
    got = yaml.load(io.StringIO(cand), Loader=yaml.BaseLoader)
    want = dict(base); want["change_ref"] = ref
    if len(re.findall(r"\bchange_ref\s*:", cand)) != 1 or got != want:
        print("REFUS REF_DUPLIQUEE la ligne candidate ne porte pas exactement une cle change_ref relue a la valeur demandee"); sys.exit(0)
open(out, "w", encoding="utf-8").write(cand + "\n")
print("LINE_OK")
PY
CAND_LINE=$(head -1 "$WORK/cand.out")
case "$CAND_LINE" in
  LINE_OK) ;;
  REFUS*) refus "$(printf '%s' "$CAND_LINE" | cut -d' ' -f2)" "$(printf '%s' "$CAND_LINE" | cut -d' ' -f3-)" ;;
  *) refus MANIFESTE_INVALIDE "candidate illisible ($(shown "$CAND_LINE"))" ;;
esac
CANDIDATE="$(cat "$WORK/candidate")"
cp "$WORK/n1.yml" "$WORK/expect.yml"
app_manifest_merge_env "$WORK/expect.yml" "$REQ_ENV" "$CANDIDATE" >/dev/null 2>"$WORK/merge.err" \
  || refus MANIFESTE_INVALIDE "la candidate ne se fusionne pas dans le manifeste de #${NUM_N1} : $(head -c 200 "$WORK/merge.err" | tr '\n' ' ')"
D_EXPECT=$(app_manifest_digest_env "$WORK/expect.yml" "$REQ_ENV" 2>/dev/null) || refus MANIFESTE_INVALIDE "digest attendu incalculable"
HAS_N1_CERT=0; g show "${SHA_N1}:${CERT_PATH}" > "$WORK/n1.crt" 2>/dev/null && HAS_N1_CERT=1
HAS_MAIN_CERT=0; [ -f "$R/$CERT_PATH" ] && HAS_MAIN_CERT=1

# ── 9. ÉTAT IDENTIQUE : rien à replier ? (sur la candidate, jamais la ligne brute) ──
etape identique
CERT_SAME=0
if [ "$HAS_N1_CERT" = 0 ] && [ "$HAS_MAIN_CERT" = 0 ]; then CERT_SAME=1
elif [ "$HAS_N1_CERT" = 1 ] && [ "$HAS_MAIN_CERT" = 1 ] && cmp -s "$WORK/n1.crt" "$R/$CERT_PATH"; then CERT_SAME=1; fi
if [ "$D_EXPECT" = "$D_BASE" ] && [ "$CERT_SAME" = 1 ]; then
  refus ETAT_IDENTIQUE "l'état à restaurer (#${NUM_N1}) est identique à l'état courant de ${REQ_APP}/${REQ_ENV} — rien à replier ; une dérive de la gateway se corrige en rejouant le webhook de la PR #${NUM_N} (A2)"
fi

# ── 10. RESTAURATION dans le clone ───────────────────────────────────────────
etape restauration
g checkout -q -B "$BRANCH"
app_manifest_merge_env "$R/$MAN_PATH" "$REQ_ENV" "$CANDIDATE" >/dev/null 2>"$WORK/merge2.err" \
  || refus MANIFESTE_INVALIDE "fusion de la candidate dans ${MAN_PATH} refusée : $(head -c 200 "$WORK/merge2.err" | tr '\n' ' ')"
g add "$MAN_PATH"
CERT_ACTION=inchangé
if [ "$HAS_N1_CERT" = 1 ]; then
  if [ "$HAS_MAIN_CERT" = 0 ] || ! cmp -s "$WORK/n1.crt" "$R/$CERT_PATH"; then
    mkdir -p "$(dirname "$R/$CERT_PATH")"; cp "$WORK/n1.crt" "$R/$CERT_PATH"; chmod 0644 "$R/$CERT_PATH"; g add "$CERT_PATH"; CERT_ACTION=restauré
  fi
elif [ "$HAS_MAIN_CERT" = 1 ]; then
  g rm -q "$CERT_PATH"; CERT_ACTION=supprimé
fi

# ── 11. AUTO-VÉRIFICATION : rien de poussé si la restauration n'est pas fidèle ──
etape verification
D_GOT=$(app_manifest_digest_env "$R/$MAN_PATH" "$REQ_ENV" 2>/dev/null)
[ "$D_GOT" = "$D_EXPECT" ] || refus RESTAURATION_INFIDELE "digest du clone ${D_GOT:-illisible} ≠ digest attendu ${D_EXPECT} — rien n'est poussé"
FILES=$(g diff --cached --name-only | sort | tr '\n' ' ')
case "$FILES" in
  "$MAN_PATH "|"$CERT_PATH $MAN_PATH "|"$MAN_PATH $CERT_PATH ") ;;
  "") [ "$CERT_ACTION" != inchangé ] || refus PERIMETRE_INATTENDU "aucun fichier modifié après restauration" ;;
  *) refus PERIMETRE_INATTENDU "la restauration touche autre chose que le manifeste et le cert du palier : ${FILES}" ;;
esac
CH=$(g diff --cached -U0 -- "$MAN_PATH" | grep -cE '^[-+][^-+]' || true)
[ "$CH" = 0 ] || [ "$CH" = 2 ] || refus PERIMETRE_INATTENDU "le diff du manifeste touche ${CH} ligne(s) au lieu d'une (racine ou autres paliers modifiés ?)"

# ── 12. PR EN COURS / EXIST strict (auteur de service, même dépôt, contenu identique) ──
etape pr-en-cours
# `forge pr_find_open` ne rend que « la nôtre » : même tête, même dépôt (une PR
# de fork portant ce head.ref est ignorée). NUMBER vide = aucune, rc 0 — ce
# n'est pas une panne ; rc 2 + cause = la forge est illisible.
O_NUMBER=""; O_LOGIN=""; O_URL=""
forge_kv O pr_find_open "$BRANCH" 2>"$WORK/open.err" \
  || { cat "$WORK/open.err" >&2; refus FORGE_ILLISIBLE "lecture des PR ouvertes de ${BRANCH} en échec (cause ci-dessus)"; }
if [ -n "$O_NUMBER" ]; then
  O_NUM="$O_NUMBER"; [ -n "$O_LOGIN" ] || O_LOGIN="-"
  # A7 : une PR ouverte n'appartient qu'à son auteur — « la sienne » = même
  # identité que le pousseur (service ↔ service, humain ↔ ce même humain).
  MINE=0
  if [ "$FORGE_LOGIN" = "(service)" ]; then case " $GITEA_SERVICE_LOGINS " in *" $O_LOGIN "*) MINE=1;; esac
  else [ "$O_LOGIN" = "$FORGE_LOGIN" ] && MINE=1; fi
  SAME=0
  if [ "$MINE" = 1 ] && g fetch -q origin "refs/heads/${BRANCH}" 2>/dev/null; then
    g show "FETCH_HEAD:${MAN_PATH}" > "$WORK/open.yml" 2>/dev/null \
      && [ "$(app_manifest_digest_env "$WORK/open.yml" "$REQ_ENV" 2>/dev/null)" = "$D_EXPECT" ] && SAME=1
    if [ "$SAME" = 1 ]; then
      if [ "$HAS_N1_CERT" = 1 ]; then g show "FETCH_HEAD:${CERT_PATH}" > "$WORK/open.crt" 2>/dev/null && cmp -s "$WORK/open.crt" "$WORK/n1.crt" || SAME=0
      else g cat-file -e "FETCH_HEAD:${CERT_PATH}" 2>/dev/null && SAME=0; fi
    fi
  fi
  if [ "$SAME" = 1 ]; then
    # Le lien humain est celui que la forge rend (html_url Gitea, web_url GitLab),
    # vu de GIT_HOST — réécrit sur GIT_WEB_HOST en split-horizon. Jamais composé
    # ici : GitLab dit /-/merge_requests/N, Gitea /pulls/N.
    O_URL="${O_URL/#"$GIT_HOST"/"$GIT_WEB_HOST"}"
    echo "EXIST : la PR #${O_NUM} (${O_LOGIN}) porte déjà exactement cette restauration — rien à pousser"
    echo "PR_URL=${O_URL}"; echo "REPLI_DE=${SHA_N} REPLI_VERS=${SHA_N1} REPLI_DIGEST=${D_EXPECT}"
    [ -n "$ROLLBACK_OUT" ] && printf 'PR_URL=%s\nPR_NUMBER=%s\nREPLI_DE=%s\nREPLI_VERS=%s\nREPLI_DIGEST=%s\nREPLI_DU_REPLI=%s\n' "$O_URL" "$O_NUM" "$SHA_N" "$SHA_N1" "$D_EXPECT" "0" > "$ROLLBACK_OUT"
    exit 0
  fi
  refus PR_EN_COURS "une PR est ouverte sur ${BRANCH} (#${O_NUM}, par ${O_LOGIN}) : la fermer ou la merger avant de replier — un repli ne réécrit jamais une PR ouverte"
fi

# ── 12bis. TÊTE DISTANTE : absente ou déjà mergée ⇒ bail ; sinon refus ────────
etape tete-distante
TIP=$(g ls-remote --heads origin "refs/heads/${BRANCH}" 2>/dev/null | cut -f1 | head -1)
if [ -n "$TIP" ]; then
  g fetch -q origin "refs/heads/${BRANCH}" 2>/dev/null || refus BRANCHE_NON_MERGEE "la tête distante ${TIP} de ${BRANCH} est illisible"
  g merge-base --is-ancestor "$TIP" "origin/${GIT_BASE}" \
    || refus BRANCHE_NON_MERGEE "${BRANCH} porte des commits non mergés (${TIP}) sans PR ouverte — les merger, ou supprimer la branche, avant de replier"
fi

# ── 13. COMMIT (trailers), PUSH en bail, PR, plan enchaîné ───────────────────
etape commit
REPLI_DU_REPLI=0
N_MSG=$(g log -1 --format=%B "${SHA_N}^2" 2>/dev/null || g log -1 --format=%B "${SHA_N}")
printf '%s' "$N_MSG" | grep -q '^Repli-Vers: ' && REPLI_DU_REPLI=1
[ "$REPLI_DU_REPLI" = 0 ] || echo "REPLI_DU_REPLI : restaure #${NUM_N1}, l'état d'avant le repli #${NUM_N} ; si l'apply de #${NUM_N} a été REFUSÉ, le remède est le rejeu du webhook de #${NUM_N} (A2), pas ce repli"
{
  printf 'provision(%s): repli de %s vers l'"'"'état de la PR #%s (%s)\n\n%s\n\n' "$REQ_ENV" "$REQ_APP" "$NUM_N1" "$(printf '%s' "$SHA_N1" | cut -c1-7)" "$REQ_REASON"
  printf 'Repli-De: %s (PR #%s)\nRepli-Vers: %s (PR #%s)\nRepli-Motif: %s\nRepli-Par: %s\nRepli-Digest: %s\n' "$SHA_N" "$NUM_N" "$SHA_N1" "$NUM_N1" "$REQ_REASON" "$REQ_CALLER" "$D_EXPECT"
  [ -z "$REQ_CHANGE_REF" ] || printf 'Change-Ref: %s\n' "$REQ_CHANGE_REF"
} > "$WORK/msg"
g commit -q -F "$WORK/msg" || refus PUSH_ECHEC "commit impossible dans le clone"
etape push
if ! g push -q "--force-with-lease=refs/heads/${BRANCH}:${TIP}" origin "HEAD:refs/heads/${BRANCH}" 2>"$WORK/push.err"; then
  refus PUSH_ECHEC "push de ${BRANCH} refusé (bail perdu ou droits) : $(grep -v -F -- "$(cat "$PUSH_TF")" "$WORK/push.err" | grep -v -F -- "$FORGE_SECRET" | head -c 200 | tr '\n' ' ')"
fi
etape pr
PR_TITLE="provision(${REQ_ENV}): ${REQ_APP} — repli vers #${NUM_N1}"
# Le CORPS de la PR : du TEXTE, composé ici (aucun réseau) ; la forge le reçoit
# par `forge pr_open`, dans les champs de SON visage.
F_NUM_N="$NUM_N" F_NUM_N1="$NUM_N1" F_SHA_N="$SHA_N" F_SHA_N1="$SHA_N1" F_DIGEST="$D_EXPECT" F_LINE="$CANDIDATE" F_CERT="$CERT_ACTION" \
  F_REF="$REQ_CHANGE_REF" F_REASON="$REQ_REASON" F_CALLER="$REQ_CALLER" F_APP="$REQ_APP" F_ENV="$REQ_ENV" F_RDR="$REPLI_DU_REPLI" F_PUSH_LOGIN="$PUSH_LOGIN" \
  python3 - > "$WORK/pr-body" <<'PY' || refus PR_ECHEC "composition du corps de la PR en échec — la branche ${BRANCH} est poussée, rejouer la demande (EXIST la reconnaîtra par son contenu)"
import os
e = os.environ
body = ["<!-- app-rollback: de %s vers %s -->" % (e["F_SHA_N"], e["F_SHA_N1"]),
        "Demande de REPLI d une application (A6, ADR-089) — le repli est une PR.", "",
        "- application : %s" % e["F_APP"], "- palier : %s" % e["F_ENV"],
        "- restaure : PR #%s (merge %s)" % (e["F_NUM_N1"], e["F_SHA_N1"]),
        "- remplace : PR #%s (merge %s)" % (e["F_NUM_N"], e["F_SHA_N"]),
        "- ligne restauree : `%s`" % e["F_LINE"],
        "- cert : %s" % e["F_CERT"],
        "- digest attendu apres apply : `%s` (a comparer a la ligne « digest du manifeste effectif » du rapport de provision-apply)" % e["F_DIGEST"],
        "- demandeur du repli : %s" % e["F_CALLER"],
        ("- ouverte par : %s (identite de forge — c est elle que la porte a quatre yeux confronte au mergeur)" % e["F_PUSH_LOGIN"]) if e["F_PUSH_LOGIN"] != "ci" else "- ouverte par : compte de service (une porte a quatre yeux refusera REQUESTER_UNKNOWN)",
        "- motif : %s" % e["F_REASON"]]
if e["F_REF"]: body.append("- change_ref : %s (remplace celui de l etat restaure — un repli porte SON change)" % e["F_REF"])
if e["F_RDR"] == "1": body.append("- REPLI_DU_REPLI : #%s est lui-meme un repli ; si son apply a ete REFUSE, le remede est le rejeu de son webhook (A2), pas ce repli" % e["F_NUM_N"])
body += ["", "Toutes les portes du palier s appliquent (merge, provision-apply, garde du palier, ordre app/API). Rien n est jamais desinscrit : la convergence garde le GUID et la cle de l application."]
print("\n".join(body))
PY
# A7 : la PR est ouverte SOUS le pousseur (l'humain quand il y en a un) — son
# secret passe par FICHIER (FORGE_SECRET_FILE), jamais en argv ; rc 2 = la forge
# a refusé ou est illisible, la cause est au-dessus.
P_NUMBER=""; P_URL=""
FORGE_SECRET_FILE="$PUSH_TF" forge_kv P pr_open "$BRANCH" "$GIT_BASE" "$PR_TITLE" "$WORK/pr-body" 2>"$WORK/pr.err" \
  || { cat "$WORK/pr.err" >&2; refus PR_ECHEC "ouverture de la PR sur ${BRANCH} en échec — la branche est poussée, rejouer la demande (EXIST la reconnaîtra par son contenu) (cause ci-dessus)"; }
PR_NUM="$P_NUMBER"
# Le lien humain : l'URL rendue par la forge, réécrite sur GIT_WEB_HOST en split-horizon.
PR_URL="${P_URL/#"$GIT_HOST"/"$GIT_WEB_HOST"}"
echo "  PR créée: #${PR_NUM}"
echo "PR_URL=${PR_URL}"
echo "REPLI_DE=${SHA_N} REPLI_VERS=${SHA_N1} REPLI_DIGEST=${D_EXPECT}"
[ -n "$ROLLBACK_OUT" ] && printf 'PR_URL=%s\nPR_NUMBER=%s\nREPLI_DE=%s\nREPLI_VERS=%s\nREPLI_DIGEST=%s\nREPLI_DU_REPLI=%s\n' "$PR_URL" "$PR_NUM" "$SHA_N" "$SHA_N1" "$D_EXPECT" "$REPLI_DU_REPLI" > "$ROLLBACK_OUT"
if [ "$PROVISION_PLAN_INLINE" = "true" ]; then
  echo "[plan] plan enchaîné sur la PR #${PR_NUM}"
  if PR_BRANCH="$BRANCH" PR_NUMBER="$PR_NUM" bash "$SELF_DIR/provision-plan.sh"; then echo "  PLAN_INLINE=ok"; else echo "  PLAN_INLINE=fail — la PR est ouverte, la demande de repli reste valide" >&2; fi
fi
echo "OK: repli ${REQ_APP}/${REQ_ENV} → PR #${PR_NUM} (restaure #${NUM_N1}, remplace #${NUM_N})"
