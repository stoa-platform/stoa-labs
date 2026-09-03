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
# main) à l'objet dont « la PR est le fichier de déploiement ».
#
# ORDRE = LA PROPRIÉTÉ (rien n'est poussé avant le dernier refus ; chaque étape
# imprime `ETAPE <nom>`) : forme → chaîne (épinglée par l'appelant) → porte
# (GATE_REFS_REQUIRED AVANT tout clone, AVANT tout appel de forge) → clone avec
# historique → manifeste + naissance (BIRTH) → lignée (forge = la vérité sur
# les PR, Git = la vérité sur main, bornée à la vie courante du manifeste) →
# cohérence → ligne candidate en mémoire (N-1 ⊕ change_ref) → ETAT_IDENTIQUE →
# restauration → auto-vérification → PR en cours / EXIST strict → tête
# distante en bail → commit (trailers) + push --force-with-lease + POST /pulls
# + plan enchaîné.
#
# Entrées (env) : REQ_APP REQ_ENV REQ_REASON (requis), REQ_CHANGE_REF,
#   REQ_CALLER (défaut unknown), GITEA_TOKEN (requis), GIT_HOST GIT_REPO
#   GIT_BASE GIT_SUBDIR GIT_CLONE_URL GITEA_SERVICE_LOGINS STOA_ENV_CHAIN_FILE
#   PROVISION_PLAN_INLINE ROLLBACK_OUT.
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

# Même règle que provision-request.sh : un champ obligatoire vide se NOMME
# (CHAMP_REQUIS + le champ du formulaire), jamais un `${VAR:?}` de bash.
requis(){ case "${2//[[:space:]]/}" in "") echo "REFUS: CHAMP_REQUIS : $1 est vide — obligatoire ($3). Rien n'a été tenté." >&2; exit 2;; esac; }
REQ_APP="${REQ_APP:-}"; requis REQ_APP "$REQ_APP" "formulaire app-rollback : champ « APP », l'application à replier"
REQ_ENV="${REQ_ENV:-}"; requis REQ_ENV "$REQ_ENV" "formulaire app-rollback : champ « ENV », le palier à replier"
REQ_REASON="${REQ_REASON:-}"; requis REQ_REASON "$REQ_REASON" "formulaire app-rollback : champ « REASON », le motif du repli"
REQ_CHANGE_REF="${REQ_CHANGE_REF:-}"
REQ_CALLER="${REQ_CALLER:-unknown}"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}"; export GITEA_TOKEN
GIT_HOST="${GIT_HOST:?GIT_HOST requis (base de la forge, ex. https://forge.client) — aucun repli}"
GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"   # l'adresse HUMAINE, si elle diffère de celle vue par le CI
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
GIT_BASE="${GIT_BASE:-main}"
GIT_SUBDIR="${GIT_SUBDIR-poc-control-plane-federation}"
# schéma conservé (cf. provision-request.sh) : « http:// » forcé cassait toute forge TLS
case "$GIT_HOST" in http://*|https://*|file://*) GIT_BASE_URL="${GIT_HOST%/}";; *) GIT_BASE_URL="http://${GIT_HOST%/}";; esac
GIT_CLONE_URL="${GIT_CLONE_URL:-${GIT_BASE_URL}/${GIT_REPO}.git}"
GITEA_SERVICE_LOGINS="${GITEA_SERVICE_LOGINS:-ci}"
PROVISION_PLAN_INLINE="${PROVISION_PLAN_INLINE:-true}"
ROLLBACK_OUT="${ROLLBACK_OUT:-}"
API="${GIT_HOST}/api/v1"
MAN_PATH="${GIT_SUBDIR:+$GIT_SUBDIR/}clients/provisioned/applications/${REQ_APP}.ansible.yml"
CERT_PATH="${GIT_SUBDIR:+$GIT_SUBDIR/}clients/provisioned/certs/${REQ_APP}-${REQ_ENV}.crt"
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
CI_TF="$WORK/ci-token"; printf '%s' "$GITEA_TOKEN" > "$CI_TF"
# Défauts = le compte de service ; l'identité (§3bis) les remplace quand un token humain existe.
FORGE_LOGIN="(service)"; PUSH_LOGIN=ci; PUSH_TF="$CI_TF"

etape(){ echo "ETAPE $*"; }
refus(){ echo "REFUS: $1 : $2" >&2; exit 2; }
shown(){ printf '%q' "$(printf '%s' "${1:-}" | head -c 80)"; }
# Un appel de forge : token PAR ENV, jamais en argv ; rc ≠ 0 = illisible.
forge(){ # <script python> — les variables d'entrée sont dans l'environnement
  F_API="$API" F_REPO="$GIT_REPO" F_TOKEN="$GITEA_TOKEN" F_BRANCH="$BRANCH" F_BASE="$GIT_BASE" F_PR_TOKEN_FILE="${PUSH_TF:-$CI_TF}" F_PUSH_LOGIN="${PUSH_LOGIN:-ci}" python3 -c "$1"
}
PY_FORGE_COMMON='
import json, os, sys, urllib.request, urllib.error
api, repo, tok, BRANCH, base = os.environ["F_API"], os.environ["F_REPO"], os.environ["F_TOKEN"], os.environ["F_BRANCH"], os.environ["F_BASE"]
def refuse(tag, msg): print("REFUS %s %s" % (tag, msg)); sys.exit(0)
def get(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": "token " + tok}), timeout=30) as r: return json.load(r)
    except urllib.error.HTTPError as e: refuse("FORGE_ILLISIBLE", "forge HTTP %d sur %s" % (e.code, url.split("?")[0]))
    except Exception as e: refuse("FORGE_ILLISIBLE", "forge injoignable ou illisible (%s)" % type(e).__name__)
def pulls(state):
    page = 1
    while True:
        l = get("%s/repos/%s/pulls?state=%s&limit=50&page=%d" % (api, repo, state, page))
        if not isinstance(l, list): refuse("FORGE_ILLISIBLE", "la liste des PR (%s) n est pas une liste" % state)
        if not l: return
        for pr in l:
            if not isinstance(pr, dict): refuse("FORGE_ILLISIBLE", "entree de PR non-objet")
            yield pr
        page += 1
def clean(v):
    v = "" if v is None else str(v)
    if "\n" in v or "\r" in v: refuse("FORGE_ILLISIBLE", "valeur de la forge avec retour-ligne")
    return v
'

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
# ici, au plus tôt, aucune PR ouverte. Avec un token : GET /user (read:user).
FOUREYES="$(env_chain_gate_four_eyes "$REQ_ENV")" || refus CHAINE_INVALIDE "fourEyes de '$REQ_ENV' illisible"
FOUREYES="${FOUREYES#FOUREYES=}"
if [ -n "$FORGE_TF" ]; then
  etape identite
  FORGE_LOGIN="$(forge_login "$API" "$FORGE_TF")" || { rc=$?; [ "$rc" = 2 ] && exit 2; exit 1; }
  forge_is_service "$FORGE_LOGIN" "$GITEA_SERVICE_LOGINS" && FORGE_LOGIN="(service)"
fi
[ "$FOUREYES" != 1 ] || [ "$FORGE_LOGIN" != "(service)" ] \
  || refus REQUESTER_UNKNOWN "la porte vers '$REQ_ENV' exige les quatre yeux ; une PR de repli ouverte par un compte de service (${GITEA_SERVICE_LOGINS}) serait refusée REQUESTER_UNKNOWN à l'apply — fournir FORGE_TOKEN (votre token de forge, scopes read:user + write:repository) ; aucune PR ouverte"
PUSH_LOGIN="$FORGE_LOGIN"; [ "$PUSH_LOGIN" = "(service)" ] && PUSH_LOGIN=ci
PUSH_TF="${FORGE_TF:-$CI_TF}"

# ── 4. CLONE avec historique (jamais --depth, jamais --filter : la lignée se lit sur main ; un clone partiel boucle en fetchs paresseux contre une origine shallow — mesuré) ─────
etape clone "$GIT_BASE"
# A7 : l'askpass rend le login du POUSSEUR et le token lu dans son fichier (humain
# s'il y en a un, service sinon) — jamais en argv, jamais dans une URL.
ASKPASS="$(forge_askpass "$WORK" "$PUSH_LOGIN" "$PUSH_TF")" || refus CABLAGE_INCOMPLET "askpass"
export GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0
R="$WORK/repo"
git clone -q --single-branch --branch "$GIT_BASE" "$GIT_CLONE_URL" "$R" 2>"$WORK/clone.err" \
  || refus CLONE_ECHEC "clone de ${GIT_REPO} (${GIT_BASE}) impossible : $(grep -v -F -- "$(cat "$PUSH_TF")" "$WORK/clone.err" | grep -v -F -- "$GITEA_TOKEN" | head -c 200 | tr '\n' ' ')"
[ "$(git -C "$R" rev-parse --is-shallow-repository)" = false ] \
  || refus LIGNEE_TRONQUEE "le clone de ${GIT_BASE} est shallow — un historique tronqué ne peut pas prouver l'absence d'un état précédent"
g(){ git -C "$R" "$@"; }
g config user.email "${CI_COMMIT_EMAIL:-ci@bc.example}"; g config user.name "${CI_COMMIT_NAME:-provisioning (service ci)}"

# ── 5. MANIFESTE sur main, palier déclaré, naissance courante ─────────────────
etape manifeste
[ -f "$R/$MAN_PATH" ] || refus MANIFESTE_ABSENT "${MAN_PATH} absent de ${GIT_BASE} — rien à replier (application retirée ?)"
app_manifest_read "$R/$MAN_PATH" >/dev/null 2>"$WORK/read.err" || refus MANIFESTE_INVALIDE "$(head -c 200 "$WORK/read.err" | tr '\n' ' ')"
D_MAIN=$(app_manifest_digest_env "$R/$MAN_PATH" "$REQ_ENV" 2>"$WORK/dg.err") \
  || refus PALIER_ABSENT "${GIT_BASE} ne déclare pas per_env.${REQ_ENV} pour ${REQ_APP} : $(head -c 200 "$WORK/dg.err" | tr '\n' ' ')"
BIRTH=$(g log --first-parent --diff-filter=A --format=%H -1 -- "$MAN_PATH")
[ -n "$BIRTH" ] || refus MANIFESTE_INVALIDE "naissance de ${MAN_PATH} introuvable sur la première parenté de ${GIT_BASE}"

# ── 6. LIGNÉE : forge (PR mergées de la branche) ordonnée par Git, bornée à BIRTH ──
etape lignee
g rev-list --first-parent "$GIT_BASE" > "$WORK/firstparent"
F_FP="$WORK/firstparent" forge "$PY_FORGE_COMMON"'
fp = [l.strip() for l in open(os.environ["F_FP"]) if l.strip()]
pos = {sha: i for i, sha in enumerate(fp)}
seen = set()
for pr in pulls("closed"):
    head = pr.get("head") or {}; base_ = pr.get("base") or {}
    head_ref = clean(head.get("ref"))
    if not pr.get("merged") or head_ref != BRANCH or clean(base_.get("ref")) != base: continue
    if clean((head.get("repo") or {}).get("full_name")) != repo:
        refuse("LIGNEE_AMBIGUE", "la PR #%s mergee sur %s vient d un fork (%s) — une lignee que personne n a voulue, refus" % (pr.get("number"), BRANCH, clean((head.get("repo") or {}).get("full_name"))))
    sha = clean(pr.get("merge_commit_sha")); n = clean(pr.get("number"))
    if len(sha) != 40 or any(c not in "0123456789abcdef" for c in sha) or not n.isdigit():
        refuse("FORGE_ILLISIBLE", "PR #%s : merge_commit_sha ou numero illisible" % n)
    if sha not in pos:
        refuse("FORGE_INCOHERENTE", "la PR #%s (mergee, %s) a un merge_commit_sha %s absent de la premiere parente de %s — historique reecrit ou base changee, refus" % (n, BRANCH, sha[:7], base))
    if sha in seen: continue
    seen.add(sha); print("CAND %d %s %s" % (pos[sha], sha, n))
' > "$WORK/lineage" || refus FORGE_ILLISIBLE "lecture des PR en échec"
REF_LINE=$(grep '^REFUS ' "$WORK/lineage" | head -1)
[ -z "$REF_LINE" ] || refus "$(printf '%s' "$REF_LINE" | cut -d' ' -f2)" "$(printf '%s' "$REF_LINE" | cut -d' ' -f3-)"
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

# ── 7. COHÉRENCE : main == #N pour ce palier ; racine(N-1) == racine(N) ──────
etape coherence
g show "${SHA_N}:${MAN_PATH}" > "$WORK/n.yml" 2>/dev/null || refus MANIFESTE_INVALIDE "${MAN_PATH} absent au merge #${NUM_N}"
g show "${SHA_N1}:${MAN_PATH}" > "$WORK/n1.yml" 2>/dev/null || refus MANIFESTE_INVALIDE "${MAN_PATH} absent au merge #${NUM_N1}"
D_N=$(app_manifest_digest_env "$WORK/n.yml" "$REQ_ENV" 2>/dev/null) || refus PALIER_ABSENT "per_env.${REQ_ENV} absent au merge #${NUM_N}"
[ "$D_MAIN" = "$D_N" ] \
  || refus REFERENCE_DIVERGENTE "${GIT_BASE} porte pour ${REQ_APP}/${REQ_ENV} un état qu'aucune PR ne porte (digest main ${D_MAIN} ≠ #${NUM_N} ${D_N}) — écriture hors flux ; corriger ${GIT_BASE} par une demande avant de replier"
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
if [ "$D_EXPECT" = "$D_MAIN" ] && [ "$CERT_SAME" = 1 ]; then
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
forge "$PY_FORGE_COMMON"'
for pr in pulls("open"):
    head = pr.get("head") or {}
    head_ref = clean(head.get("ref"))
    if head_ref == BRANCH and clean((head.get("repo") or {}).get("full_name")) == repo:
        print("OPEN %s %s %s %s" % (clean(pr.get("number")), clean((pr.get("user") or {}).get("login")) or "-", clean(head.get("sha")) or "-", clean(pr.get("html_url")) or "-")); sys.exit(0)
print("NONE")
' > "$WORK/open" || refus FORGE_ILLISIBLE "lecture des PR ouvertes en échec"
OPEN_LINE=$(head -1 "$WORK/open")
case "$OPEN_LINE" in
  REFUS*) refus "$(printf '%s' "$OPEN_LINE" | cut -d' ' -f2)" "$(printf '%s' "$OPEN_LINE" | cut -d' ' -f3-)" ;;
  NONE) ;;
  OPEN*)
    O_NUM=$(printf '%s' "$OPEN_LINE" | cut -d' ' -f2); O_LOGIN=$(printf '%s' "$OPEN_LINE" | cut -d' ' -f3); O_URL=$(printf '%s' "$OPEN_LINE" | cut -d' ' -f5)
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
      [ "$O_URL" != "-" ] || O_URL="${GIT_WEB_HOST}/${GIT_REPO}/pulls/${O_NUM}"
      echo "EXIST : la PR #${O_NUM} (${O_LOGIN}) porte déjà exactement cette restauration — rien à pousser"
      echo "PR_URL=${O_URL}"; echo "REPLI_DE=${SHA_N} REPLI_VERS=${SHA_N1} REPLI_DIGEST=${D_EXPECT}"
      [ -n "$ROLLBACK_OUT" ] && printf 'PR_URL=%s\nPR_NUMBER=%s\nREPLI_DE=%s\nREPLI_VERS=%s\nREPLI_DIGEST=%s\nREPLI_DU_REPLI=%s\n' "$O_URL" "$O_NUM" "$SHA_N" "$SHA_N1" "$D_EXPECT" "0" > "$ROLLBACK_OUT"
      exit 0
    fi
    refus PR_EN_COURS "une PR est ouverte sur ${BRANCH} (#${O_NUM}, par ${O_LOGIN}) : la fermer ou la merger avant de replier — un repli ne réécrit jamais une PR ouverte" ;;
  *) refus FORGE_ILLISIBLE "réponse inattendue ($(shown "$OPEN_LINE"))" ;;
esac

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
  refus PUSH_ECHEC "push de ${BRANCH} refusé (bail perdu ou droits) : $(grep -v -F -- "$(cat "$PUSH_TF")" "$WORK/push.err" | grep -v -F -- "$GITEA_TOKEN" | head -c 200 | tr '\n' ' ')"
fi
etape pr
PR_OUT=$(F_NUM_N="$NUM_N" F_NUM_N1="$NUM_N1" F_SHA_N="$SHA_N" F_SHA_N1="$SHA_N1" F_DIGEST="$D_EXPECT" F_LINE="$CANDIDATE" F_CERT="$CERT_ACTION" \
  F_REF="$REQ_CHANGE_REF" F_REASON="$REQ_REASON" F_CALLER="$REQ_CALLER" F_APP="$REQ_APP" F_ENV="$REQ_ENV" F_RDR="$REPLI_DU_REPLI" F_HOST="$GIT_HOST" \
  forge "$PY_FORGE_COMMON"'
e = os.environ
title = "provision(%s): %s — repli vers #%s" % (e["F_ENV"], e["F_APP"], e["F_NUM_N1"])
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
data = json.dumps({"title": title, "head": BRANCH, "base": base, "body": "\n".join(body)}, ensure_ascii=False).encode("utf-8")
ptok = open(e["F_PR_TOKEN_FILE"]).read().strip()   # A7 : la PR est ouverte SOUS le pousseur (l humain quand il y en a un)
r = urllib.request.Request("%s/repos/%s/pulls" % (api, repo), data=data, method="POST", headers={"Authorization": "token " + ptok, "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(r, timeout=30) as resp: pr = json.load(resp)
except urllib.error.HTTPError as ex: refuse("PR_ECHEC", "POST /pulls HTTP %d — la branche %s est poussee, rejouer la demande (EXIST la reconnaitra par son contenu)" % (ex.code, BRANCH))
except Exception as ex: refuse("PR_ECHEC", "POST /pulls injoignable (%s)" % type(ex).__name__)
print("CREATED %s %s" % (clean(pr.get("number")), clean(pr.get("html_url")) or ("%s/%s/pulls/%s" % (e["F_HOST"], repo, pr.get("number")))))
') || refus PR_ECHEC "ouverture de la PR en échec"
case "$PR_OUT" in
  CREATED*) PR_NUM=$(printf '%s' "$PR_OUT" | cut -d' ' -f2); PR_URL=$(printf '%s' "$PR_OUT" | cut -d' ' -f3) ;;
  REFUS*) refus "$(printf '%s' "$PR_OUT" | cut -d' ' -f2)" "$(printf '%s' "$PR_OUT" | cut -d' ' -f3-)" ;;
  *) refus PR_ECHEC "réponse inattendue ($(shown "$PR_OUT"))" ;;
esac
echo "  PR créée: #${PR_NUM}"
echo "PR_URL=${PR_URL}"
echo "REPLI_DE=${SHA_N} REPLI_VERS=${SHA_N1} REPLI_DIGEST=${D_EXPECT}"
[ -n "$ROLLBACK_OUT" ] && printf 'PR_URL=%s\nPR_NUMBER=%s\nREPLI_DE=%s\nREPLI_VERS=%s\nREPLI_DIGEST=%s\nREPLI_DU_REPLI=%s\n' "$PR_URL" "$PR_NUM" "$SHA_N" "$SHA_N1" "$D_EXPECT" "$REPLI_DU_REPLI" > "$ROLLBACK_OUT"
if [ "$PROVISION_PLAN_INLINE" = "true" ]; then
  echo "[plan] plan enchaîné sur la PR #${PR_NUM}"
  if PR_BRANCH="$BRANCH" PR_NUMBER="$PR_NUM" bash "$SELF_DIR/provision-plan.sh"; then echo "  PLAN_INLINE=ok"; else echo "  PLAN_INLINE=fail — la PR est ouverte, la demande de repli reste valide" >&2; fi
fi
echo "OK: repli ${REQ_APP}/${REQ_ENV} → PR #${PR_NUM} (restaure #${NUM_N1}, remplace #${NUM_N})"
