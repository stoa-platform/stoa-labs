#!/usr/bin/env bash
# scripts/provision-apply-gate.sh — A4 (GOAL cd-applications) : LA PORTE DE LA
# CHAÎNE au dispatch de provision-apply. environments.yaml DÉCIDE — fourEyes,
# références (change_ref / pv_ref) et ITSM, terminus par POSITION, déclaration
# déployeur — la §6 / §6bis / §6ter de team-promote.sh portée au second objet.
#
#   webhook (PR provision/<app>-<env> mergée)
#     → réconciliation (provision-apply-reconcile.sh : la forge et main font foi)
#     → CE SCRIPT, GATE_STAGE=pre    — AVANT la pause : un refus ne réveille personne
#     → pause nominative (input)
#     → CE SCRIPT, GATE_STAGE=dispatch — AU GESTE : c'est CE passage qui fait foi
#        (« approuvé hier n'est pas approuvé maintenant », ADR-075), qui nourrit
#        la garde d'identité (GATE_ALLOW_SELF) et le rapport de PR (GATE_*)
#     → garde d'identité (assert-merge-identity.sh, --allow-self-approval si la
#        porte l'admet) → build de l'aval (selfservice-app-deploy, qui vérifie
#        deployerGroup sur le TOKEN de la pause — le seul site qui le tient).
#
# NE PARLE QU'À LA CHAÎNE (fichier, par la lib, chemin ÉPINGLÉ par l'appelant sur
# la ligne d'appel : STOA_ENV_CHAIN_FILE) et, si la porte le déclare, à l'ITSM.
# Jamais Vault (aucun token à l'amont), jamais la gateway.
#
# ORDRE = LA PROPRIÉTÉ (chaque refus : rc 1, `REFUS: <TAG> : …` sur stdout,
# GATE_OUT jamais écrit — celui d'un build précédent retiré en tête —, commentaire
# de PR sous le marqueur des REFUS avec REFUSAL_KIND=porte, best-effort) :
#   0. forme (MERGE_SHA, MANIFEST, ENV_NAME) puis la CHAÎNE : env_chain_validate
#      (CHAINE_INVALIDE — une porte `to: itn` ou une clé mal orthographiée ne
#      relâche RIEN en silence), palier ∈ chaîne entière (ENV_INVALIDE) ;
#   1. la porte, un lecteur par champ (PARSE_GATE) ; déclaration déployeur hors
#      famille OU apim-apply-<x> qui ne nomme pas le palier ⇒ DEPLOYER_GROUP_UNSUPPORTED ;
#   2. les références, relues sur le manifeste MERGÉ (git show au MERGE_SHA :
#      MANIFESTE_ABSENT / MANIFESTE_ILLISIBLE / REF_INVALIDE / GATE_REFS_REQUIRED) ;
#   3. les quatre yeux, par la garde existante, FAIL-CLOSED sur un demandeur de
#      service (REQUESTER_UNKNOWN : une porte à quatre yeux qu'on ne peut pas
#      vérifier refuse, elle ne passe pas) ; FOUR_EYES_VIOLATION relayé ;
#   4. le groupe d'approbation : MATÉRIALISÉ, vérifié par personne sur cette chaîne ;
#   5. l'ITSM (ITSM_NOT_CONFIGURED / ITSM_NOT_APPROVED / ITSM_UNAVAILABLE) ;
#   6. la voie du terminus, par position (TERMINUS_SANS_VOIE) — APRÈS l'ITSM ;
#   7. GATE_OUT (forme contrôlée) + PORTE_OK(<stage>).
#
# Entrées (env — toutes lues ${X:-} : Jenkins n'exporte pas une variable vide) :
#   ENV_NAME APP_NAME MANIFEST MERGE_SHA GITEA_MERGED_BY GITEA_REQUESTER (réconciliés)
#   PR_NUMBER GITEA_TOKEN   (le refus est commenté si les deux sont posés)
#   GATE_OUT                (req) fichier de sortie KEY=VALUE
#   GATE_STAGE              pre | dispatch (libellé de journal ; les deux font tout)
#   STOA_ENV_CHAIN_FILE     la chaîne — posée par l'appelant, imprimée (`chaîne : …`)
#   ITSM_URL, ITSM_CACERT   requis seulement si la porte déclare itsmCheck
#   APIM_TERMINUS_BASE      la voie du terminus (sans défaut — même nom qu'à l'aval)
#   GITEA_SERVICE_LOGINS    comptes de service de la forge (défaut `ci`)
#   GIT_WORKTREE (.) MANIFEST_DIR (clients/provisioned/applications) GIT_REPO GIT_HOST GIT_WEB_HOST
# Sortie (GATE_OUT) : GATE_ENV GATE_STAGE GATE_ALLOW_SELF GATE_FOUR_EYES
#   GATE_APPROVER_GROUP GATE_DEPLOYER_GROUP GATE_DEPLOYER_POLICY GATE_CHANGE_REF
#   GATE_PV_REF GATE_ITSM — classe [A-Za-z0-9_.@:+-], vides admis sauf les trois premières.
set -uo pipefail
set +x
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SELF_DIR/.." || exit 1
# shellcheck source=scripts/lib/env-chain.sh
. "$SELF_DIR/lib/env-chain.sh" || { echo "REFUS: CABLAGE_INCOMPLET : $SELF_DIR/lib/env-chain.sh introuvable"; exit 1; }

ENV_NAME="${ENV_NAME:-}"; APP_NAME="${APP_NAME:-}"; MANIFEST="${MANIFEST:-}"; MERGE_SHA="${MERGE_SHA:-}"
GITEA_MERGED_BY="${GITEA_MERGED_BY:-}"; GITEA_REQUESTER="${GITEA_REQUESTER:-}"
PR_NUMBER="${PR_NUMBER:-}"; GITEA_TOKEN="${GITEA_TOKEN:-}"
GATE_OUT="${GATE_OUT:-}"; GATE_STAGE="${GATE_STAGE:-pre}"
ITSM_URL="${ITSM_URL:-}"; ITSM_CACERT="${ITSM_CACERT:-}"
APIM_TERMINUS_BASE="${APIM_TERMINUS_BASE:-}"
GITEA_SERVICE_LOGINS="${GITEA_SERVICE_LOGINS:-ci}"
GIT_WORKTREE="${GIT_WORKTREE:-.}"; MANIFEST_DIR="${MANIFEST_DIR:-clients/provisioned/applications}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"; GIT_HOST="${GIT_HOST:-http://gitea:3000}"; GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"
case "$GATE_STAGE" in pre|dispatch) ;; *) GATE_STAGE=pre ;; esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; umask 077
[ -n "$GATE_OUT" ] || { echo "REFUS: CABLAGE_INCOMPLET : GATE_OUT absent (le Jenkinsfile doit nommer le fichier de sortie)"; exit 1; }
rm -f "$GATE_OUT"

# Valeur externe montrée dans le JOURNAL seulement : tronquée, échappée.
shown(){ printf '%q' "$(printf '%s' "${1:-}" | head -c 80)"; }
# refus <TAG> <journal> [<détail pour la PR — borné, jamais une valeur brute>]
# Le commentaire part sous le marqueur des REFUS (provision-apply-refus) : le
# script tourne après RECONCILE_OK, la forge a confirmé une PR provision/*.
refus(){
  local tag="$1" logmsg="$2" prmsg="${3:-}"
  printf 'REFUS: %s : %s\n' "$tag" "$logmsg"
  if [ -n "$PR_NUMBER" ] && [ -n "$GITEA_TOKEN" ]; then
    PR_NUMBER="$PR_NUMBER" APPLY_RESULT=REFUSED REFUSAL="$tag" REFUSAL_KIND=porte REFUSAL_DETAIL="$prmsg" \
      APP_NAME="${APP_NAME:-(inconnue)}" ENV_NAME="${ENV_NAME:-(inconnu)}" \
      GIT_REPO="$GIT_REPO" GIT_HOST="$GIT_HOST" GIT_WEB_HOST="$GIT_WEB_HOST" GITEA_TOKEN="$GITEA_TOKEN" BUILD_URL="${BUILD_URL:-}" \
      bash "$SELF_DIR/provision-apply-comment.sh" >/dev/null 2>&1 || true
  fi
  exit 1
}

# ── 0. FORME, puis LA CHAÎNE — avant tout appel réseau ───────────────────────
printf '%s' "$MERGE_SHA" | grep -Eq '^[0-9a-f]{40}$' \
  || refus MERGE_SHA_INVALIDE "MERGE_SHA hors de ^[0-9a-f]{40}\$ (valeur : $(shown "$MERGE_SHA"))" "référence de merge invalide"
case "$MANIFEST" in
  "${MANIFEST_DIR}/"*.ansible.yml) ;;
  *) refus MANIFESTE_INVALIDE "MANIFEST hors de ${MANIFEST_DIR}/<app>.ansible.yml (valeur : $(shown "$MANIFEST"))" "chemin de manifeste hors du dossier attendu" ;;
esac
MAN_BASE="${MANIFEST#"${MANIFEST_DIR}/"}"; MAN_BASE="${MAN_BASE%.ansible.yml}"
printf '%s' "$MAN_BASE" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
  || refus MANIFESTE_INVALIDE "nom d'application hors de ^[a-z0-9][a-z0-9-]*\$ dans MANIFEST (valeur : $(shown "$MAN_BASE"))" "nom d'application invalide"
[ -n "$ENV_NAME" ] || refus ENV_INVALIDE "ENV_NAME vide — une porte se lit pour un palier" "palier vide"
case "$ENV_NAME" in *[!a-z0-9]*) refus ENV_INVALIDE "ENV_NAME hors de ^[a-z0-9]+\$ (valeur : $(shown "$ENV_NAME"))" "palier hors forme" ;; esac
CHAIN_FILE="$(_env_chain_file)"
echo "chaîne : ${CHAIN_FILE}"
[ -r "$CHAIN_FILE" ] || refus CHAINE_ILLISIBLE "environments.yaml absent ou illisible : ${CHAIN_FILE}" "la chaîne d'environnements est illisible"
env_chain_validate 2>"$TMP/validate.err" \
  || refus CHAINE_INVALIDE "$(tail -1 "$TMP/validate.err" | tr -d '\r')" "la chaîne d'environnements est INVALIDE (une porte mal déclarée ne relâche rien en silence) — voir le journal du build"
CHAIN="$(env_chain)" || refus CHAINE_ILLISIBLE "environments.yaml vide ou cassé" "la chaîne d'environnements est illisible"
case " $CHAIN " in
  *" $ENV_NAME "*) ;;
  *) refus ENV_INVALIDE "'${ENV_NAME}' hors de la chaîne ($CHAIN)" "le palier '${ENV_NAME}' n'est pas dans la chaîne d'environnements" ;;
esac

# ── 1. LA PORTE, un lecteur par champ ────────────────────────────────────────
GATE=$(env_chain_gate "$ENV_NAME") || refus PARSE_GATE "lecture de la porte vers '$ENV_NAME'" "porte illisible"
case "$GATE" in GATE=*) GATE="${GATE#GATE=}" ;; *) refus PARSE_GATE "sortie inattendue ($(shown "$GATE"))" "porte illisible" ;; esac
NEED_CHANGE="${GATE%%|*}"; GATE="${GATE#*|}"; NEED_PV="${GATE%%|*}"; APPROVER_GROUP="${GATE#*|}"
FE=$(env_chain_gate_four_eyes "$ENV_NAME") || refus PARSE_GATE "fourEyes" "porte illisible"
case "$FE" in FOUREYES=1) FOUREYES=1 ;; FOUREYES=0) FOUREYES=0 ;; *) refus PARSE_GATE "sortie inattendue ($(shown "$FE"))" "porte illisible" ;; esac
ITSMC=$(env_chain_gate_itsm_check "$ENV_NAME") || refus PARSE_GATE "itsmCheck" "porte illisible"
case "$ITSMC" in ITSMCHECK=1) ITSMCHECK=1 ;; ITSMCHECK=0) ITSMCHECK=0 ;; *) refus PARSE_GATE "sortie inattendue ($(shown "$ITSMC"))" "porte illisible" ;; esac
DEPLOYER_GROUP=$(env_chain_gate_deployer_group "$ENV_NAME") || refus PARSE_GATE "deployerGroup" "porte illisible"
DEPLOYER_POLICY=""
if [ -n "$DEPLOYER_GROUP" ]; then
  # Hors famille ⇒ déclaration invérifiable : on ne réveille personne pour un
  # YAML faux (l'aval le redirait avec le token). Famille apim-apply-<x> : <x>
  # DOIT être le palier de la porte — sinon la déclaration « passerait » puis
  # retomberait sur le 403 de capacité, le refus déclaratif mentirait.
  DEPLOYER_POLICY=$(deployer_group_policy "$DEPLOYER_GROUP") \
    || refus DEPLOYER_GROUP_UNSUPPORTED "'$DEPLOYER_GROUP' est hors des deux familles vérifiables (apim-apply-<x> | apim-operator-<x>) — déclaration invérifiable, refus fail-closed" "deployerGroup hors famille dans environments.yaml (porte ${ENV_NAME})"
  case "$DEPLOYER_GROUP" in
    apim-apply-*)
      [ "${DEPLOYER_GROUP#apim-apply-}" = "$ENV_NAME" ] \
        || refus DEPLOYER_GROUP_UNSUPPORTED "'$DEPLOYER_GROUP' déclaré sur la porte '$ENV_NAME' — la famille apim-apply-<x> doit nommer le palier de sa porte (apim-apply-$ENV_NAME) : la policy projetée '$DEPLOYER_POLICY' n'ouvre pas ce palier" "deployerGroup ne nomme pas le palier de sa porte (environments.yaml, porte ${ENV_NAME})" ;;
  esac
fi

# ── 2. LES RÉFÉRENCES, relues sur le manifeste MERGÉ (anti-TOCTOU) ───────────
# La DONNÉE vient de la référence (git show au MERGE_SHA) ; la GARDE (ce script,
# la chaîne) vient de la lignée de main. safe_load + `or ""` : `null`/`~` sont
# vides (BaseLoader rendrait le texte 'null'). Un saut de ligne fabriquerait un
# champ : refusé (rc 3 → REF_INVALIDE).
git -C "$GIT_WORKTREE" show "${MERGE_SHA}:./${MANIFEST}" > "$TMP/merged.yml" 2>"$TMP/show.err" \
  || refus MANIFESTE_ABSENT "${MANIFEST} absent de l'arbre au SHA mergé ${MERGE_SHA} ($(head -c 120 "$TMP/show.err" | tr '\n' ' '))" "le manifeste de l'application est absent au SHA mergé"
REFS_RC=0
REFS=$(MAN_FILE="$TMP/merged.yml" MAN_ENV="$ENV_NAME" python3 - 2>"$TMP/refs.err" <<'PY'
import os, sys, yaml
try:
    d = yaml.safe_load(open(os.environ["MAN_FILE"], encoding="utf-8")) or {}
except Exception as e:
    sys.exit("YAML illisible : %s" % type(e).__name__)
app = d.get("apim_ss_app") if isinstance(d, dict) else None
if not isinstance(app, dict):
    sys.exit("apim_ss_app absent")
pe = app.get("per_env") if isinstance(app.get("per_env"), dict) else {}
blk = pe.get(os.environ["MAN_ENV"])
blk = blk if isinstance(blk, dict) else {}
out = []
for key in ("change_ref", "pv_ref"):
    v = str(blk.get(key) or "")
    if "\n" in v or "\r" in v:
        sys.stderr.write("le champ %s contient un saut de ligne (il fabriquerait un champ)\n" % key)
        sys.exit(3)
    out.append(v)
sys.stdout.write("CR=%s\nPV=%s\n" % (out[0], out[1]))
PY
) || REFS_RC=$?
case "$REFS_RC" in
  0) ;;
  3) refus REF_INVALIDE "$(tail -1 "$TMP/refs.err") — per_env.${ENV_NAME} du manifeste mergé" "une référence de per_env.${ENV_NAME} contient un saut de ligne" ;;
  *) refus MANIFESTE_ILLISIBLE "relecture des références de ${MANIFEST} au SHA mergé — $(tail -1 "$TMP/refs.err")" "le manifeste au SHA mergé est illisible" ;;
esac
MK_CHANGE=$(printf '%s\n' "$REFS" | sed -n 's/^CR=//p'); MK_PV=$(printf '%s\n' "$REFS" | sed -n 's/^PV=//p')
# Classe ^[A-Za-z0-9][A-Za-z0-9._-]*$ : jamais `.`, `..` ni `.x` — un segment
# d'URL ITSM ; curl --path-as-is en plus, ceinture et bretelles.
ref_ok(){ [ -z "$1" ] && return 0; printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }
ref_ok "$MK_CHANGE" || refus REF_INVALIDE "change_ref du manifeste MERGÉ hors de ^[A-Za-z0-9][A-Za-z0-9._-]*\$ (valeur : $(shown "$MK_CHANGE")) — il deviendrait un segment d'URL ITSM, refus" "change_ref invalide dans per_env.${ENV_NAME}"
ref_ok "$MK_PV" || refus REF_INVALIDE "pv_ref du manifeste MERGÉ hors de ^[A-Za-z0-9][A-Za-z0-9._-]*\$ (valeur : $(shown "$MK_PV"))" "pv_ref invalide dans per_env.${ENV_NAME}"
[ "$NEED_CHANGE" = 0 ] || [ -n "$MK_CHANGE" ] \
  || refus GATE_REFS_REQUIRED "la porte vers '$ENV_NAME' exige change_ref — absent de per_env.${ENV_NAME} du manifeste mergé" "la porte vers ${ENV_NAME} exige une référence de changement (per_env.${ENV_NAME}.change_ref) — absente du manifeste mergé"
[ "$NEED_PV" = 0 ] || [ -n "$MK_PV" ] \
  || refus GATE_REFS_REQUIRED "la porte vers '$ENV_NAME' exige pv_ref — absent de per_env.${ENV_NAME} du manifeste mergé" "la porte vers ${ENV_NAME} exige une référence de PV de validation (per_env.${ENV_NAME}.pv_ref) — absente du manifeste mergé"

# ── 2ter. LE CONTRAT FIGÉ, relu au dispatch (A7 D4bis) ─────────────────────────
# A1 fige la racine du manifeste à la demande (CONTRAT_DIVERGENT dans
# provision-request.sh) — mais un commit manuel sur provision/* passe
# PR_HORS_PERIMETRE, qui ne regarde que la liste des fichiers. Ici la garde de
# la demande devient une porte : la racine (name api api_version team
# description enforce contact_emails, auth.{mode,audience,server_alias}) du
# manifeste MERGÉ doit égaler celle du PARENT du merge (MERGE_SHA^1) ; un
# manifeste NEUF (absent du parent) n'a rien à comparer. Changer d'API ou
# d'équipe est une NOUVELLE application, jamais une promotion.
if git -C "$GIT_WORKTREE" show "${MERGE_SHA}^1:./${MANIFEST}" > "$TMP/parent.yml" 2>/dev/null; then
  DIVERG=$(A="$TMP/parent.yml" B="$TMP/merged.yml" python3 - 2>"$TMP/contrat.err" <<'PY'
import json, os, sys, yaml
ROOT = ("name", "api", "api_version", "team", "description", "enforce", "contact_emails")
AUTH = ("mode", "audience", "server_alias")
def load(p):
    try:
        d = yaml.safe_load(open(p, encoding="utf-8")) or {}
    except Exception as e:
        sys.exit("YAML illisible (%s) : %s" % (p, type(e).__name__))
    app = d.get("apim_ss_app") if isinstance(d, dict) else None
    if not isinstance(app, dict):
        sys.exit("apim_ss_app absent (%s)" % p)
    auth = app.get("auth") if isinstance(app.get("auth"), dict) else {}
    def norm(v):
        return json.dumps(v, sort_keys=True, ensure_ascii=False) if isinstance(v, (list, dict)) else ("" if v is None else str(v))
    out = {k: norm(app.get(k)) for k in ROOT}
    out.update({"auth." + k: norm(auth.get(k)) for k in AUTH})
    return out
a, b = load(os.environ["A"]), load(os.environ["B"])
print(" ".join(k for k in a if a[k] != b[k]))
PY
) || refus MANIFESTE_ILLISIBLE "contrat figé : $(tail -1 "$TMP/contrat.err")" "le manifeste (parent ou mergé) est illisible pour la relecture du contrat"
  [ -z "$DIVERG" ] \
    || refus CONTRAT_DIVERGENT "le merge ${MERGE_SHA} change la racine figée du manifeste (${DIVERG}) — une PR provision/* ne fusionne qu'un palier (A1) ; changer d'API ou d'équipe est une NOUVELLE application, jamais une promotion" \
             "la racine figée du manifeste a changé au merge (${DIVERG}) — une PR provision/* ne fusionne qu'un palier"
  echo "contrat figé : racine du manifeste identique à celle du parent du merge"
else
  echo "contrat figé : manifeste créé par ce merge (rien à comparer)"
fi

# ── 3. LES QUATRE YEUX — par la garde existante, FAIL-CLOSED sur un demandeur de service ──
# Le demandeur est l'AUTEUR DE LA PR relu sur la forge : la seule identité de
# demandeur que la forge garantit (un champ du manifeste serait forgeable dans
# la PR par son auteur). Ouverte par un compte de service (ci), la PR ne nomme
# aucun humain : une porte à quatre yeux qu'on ne peut pas vérifier REFUSE.
# La garde est appelée avec le mergeur pour identité (MERGER_MISMATCH est alors
# tautologique — voulu : avant la pause, la seule chose vérifiable est
# « le mergeur est-il le demandeur ? », avec LA MÊME normalisation que la garde
# post-pause) ; sa sortie est capturée : son MERGE_IDENTITY_OK ne prouve rien ici.
GATE_ALLOW_SELF=0
if [ "$FOUREYES" = 1 ]; then
  [ -n "$GITEA_MERGED_BY" ] || refus MERGER_UNKNOWN "la forge ne nomme aucun mergeur" "aucun mergeur relu sur la forge"
  REQ_IS_SERVICE=0
  for s in $GITEA_SERVICE_LOGINS; do [ "$s" = "$GITEA_REQUESTER" ] && REQ_IS_SERVICE=1; done
  if [ -z "$GITEA_REQUESTER" ] || [ "$REQ_IS_SERVICE" = 1 ]; then
    refus REQUESTER_UNKNOWN "la porte vers '$ENV_NAME' exige les quatre yeux, mais la PR a été ouverte par '${GITEA_REQUESTER:-(auteur vide)}' — la forge ne nomme aucun demandeur humain (comptes de service : $GITEA_SERVICE_LOGINS) ; une porte à quatre yeux qu'on ne peut pas vérifier refuse, elle ne passe pas" \
      "la porte vers ${ENV_NAME} exige les quatre yeux mais la PR a été ouverte par un compte de service (${GITEA_REQUESTER:-auteur vide}) : aucun demandeur humain à confronter au mergeur — ouvrir la demande sous une identité humaine de forge"
  fi
  AMI_RC=0
  sh "$SELF_DIR/lib/assert-merge-identity.sh" --merged-by "$GITEA_MERGED_BY" --requester "$GITEA_REQUESTER" --vault-user "$GITEA_MERGED_BY" \
    >"$TMP/ami.out" 2>"$TMP/ami.err" || AMI_RC=$?
  case "$AMI_RC" in
    0) echo "porte(${GATE_STAGE}) : mergeur '${GITEA_MERGED_BY}' ≠ demandeur '${GITEA_REQUESTER}' — identité non prouvée à ce stade (la garde post-pause la prouve)" ;;
    1) AMI_TAG=$(head -1 "$TMP/ami.err" | grep -oE '^[A-Z][A-Z0-9_]+' || true)
       refus "${AMI_TAG:-IDENTITE_REFUSEE}" "$(head -1 "$TMP/ami.err" | tr -d '\r')" \
         "quatre yeux : ${AMI_TAG:-refus de la garde} — demandeur '${GITEA_REQUESTER}', mergeur '${GITEA_MERGED_BY}' (la porte vers ${ENV_NAME} interdit au demandeur d'approuver sa propre demande)" ;;
    *) refus CABLAGE_INCOMPLET "assert-merge-identity.sh rc ${AMI_RC} : $(head -1 "$TMP/ami.err" | tr -d '\r')" "garde d'identité mal câblée (voir le journal du build)" ;;
  esac
else
  GATE_ALLOW_SELF=1
  echo "porte(${GATE_STAGE}) : auto-approbation admise par la porte vers '${ENV_NAME}' (selfApproval) — rien à comparer ; l'identité du répondant reste vérifiée après la pause"
fi

# ── 4. LE GROUPE D'APPROBATION : matérialisé, vérifié par personne ici ───────
# (claim Keycloak, un annuaire que la forge ne consulte pas — ADR-084, limite
# nommée ; dit tel quel sur la console et sur la PR.)

# ── 5. L'ITSM, re-vérifié — AVANT la voie du terminus ────────────────────────
GATE_ITSM=none
if [ "$ITSMCHECK" = 1 ]; then
  [ -n "$ITSM_URL" ] || refus ITSM_NOT_CONFIGURED "la porte vers '$ENV_NAME' déclare itsmCheck mais ITSM_URL n'est pas posée — le contrôle déclaré doit pouvoir s'exécuter, refus fail-closed" "itsmCheck déclaré mais aucun ITSM configuré (ITSM_URL)"
  [ -n "$MK_CHANGE" ] || refus GATE_REFS_REQUIRED "itsmCheck sans change_ref" "itsmCheck sans référence de changement"
  CA_ARGS=(); [ -n "$ITSM_CACERT" ] && [ -f "$ITSM_CACERT" ] && CA_ARGS=(--cacert "$ITSM_CACERT")
  ITSM_CODE=$(curl -sS --path-as-is ${CA_ARGS[@]+"${CA_ARGS[@]}"} -o "$TMP/itsm.json" -w '%{http_code}' --max-time 20 \
    "${ITSM_URL%/}/changes/${MK_CHANGE}" 2>"$TMP/itsm.err") || ITSM_CODE=000
  case "$ITSM_CODE" in
    200) ITSM_STATUS=$(SRC="$TMP/itsm.json" python3 -c 'import json,os;print(str((json.load(open(os.environ["SRC"])) or {}).get("status") or ""))' 2>/dev/null) \
           || refus ITSM_UNAVAILABLE "réponse ITSM illisible pour '${MK_CHANGE}' (200 sans JSON)" "réponse ITSM illisible"
         [ "$ITSM_STATUS" = approved ] \
           || refus ITSM_NOT_APPROVED "le change '${MK_CHANGE}' est '${ITSM_STATUS:-<sans statut>}' dans l'ITSM au moment du dispatch — approuvé hier n'est pas approuvé maintenant (anti-TOCTOU)" "le change ${MK_CHANGE} n'est pas approuvé dans l'ITSM (statut : ${ITSM_STATUS:-sans statut})" ;;
    404) refus ITSM_NOT_APPROVED "le change '${MK_CHANGE}' est INCONNU de l'ITSM (404) — un change inconnu n'est pas un change approuvé" "le change ${MK_CHANGE} est inconnu de l'ITSM" ;;
    *)   refus ITSM_UNAVAILABLE "GET /changes/${MK_CHANGE} → HTTP ${ITSM_CODE} — statut invérifiable, refus fail-closed" "ITSM injoignable ou en erreur (HTTP ${ITSM_CODE})" ;;
  esac
  echo "itsm : change '${MK_CHANGE}' approved au moment du dispatch (${GATE_STAGE})"
  GATE_ITSM=checked
fi

# ── 6. LA VOIE DU TERMINUS, par POSITION — avant la pause ────────────────────
# La règle de l'aval (A3 §1), remontée ici pour ne pas réveiller un humain, ne
# pas consommer son mot de passe ni minter un token pour un refus positionnel
# connu d'avance. Aucun `if` sur un nom ; le knob a le nom de celui de l'aval.
TERMINUS="$(env_chain_terminus)" || refus CHAINE_ILLISIBLE "terminus indéterminable" "la chaîne d'environnements est illisible"
if [ "$ENV_NAME" = "$TERMINUS" ] && [ -z "$APIM_TERMINUS_BASE" ]; then
  refus TERMINUS_SANS_VOIE "'${ENV_NAME}' est le terminus de la chaîne — pas de proxy wm-admin-<env> devant lui (exclusion structurelle G4) ; la voie directe exige APIM_TERMINUS_BASE, et dire sa cible est volontaire — refusé avant la pause : personne n'est réveillé pour un apply sans voie" \
    "le terminus '${ENV_NAME}' n'a pas de voie déclarée (APIM_TERMINUS_BASE) — l'ouvrir est un geste de déclaration + credential + porte (A7), jamais un edit"
fi

# ── 7. SORTIE (forme contrôlée à l'écriture ; le pipeline re-contrôle à la lecture)
OUT="$GATE_OUT" python3 - "$ENV_NAME" "$GATE_STAGE" "$GATE_ALLOW_SELF" "$FOUREYES" "$APPROVER_GROUP" "$DEPLOYER_GROUP" "$DEPLOYER_POLICY" "$MK_CHANGE" "$MK_PV" "$GATE_ITSM" <<'PY' || refus SORTIE_INVALIDE "une valeur de sortie est hors de la classe [A-Za-z0-9_.@:+-] (ou une clé obligatoire est vide)" "sortie de la porte hors forme"
import os, re, sys
keys = ["GATE_ENV", "GATE_STAGE", "GATE_ALLOW_SELF", "GATE_FOUR_EYES", "GATE_APPROVER_GROUP", "GATE_DEPLOYER_GROUP", "GATE_DEPLOYER_POLICY", "GATE_CHANGE_REF", "GATE_PV_REF", "GATE_ITSM"]
vals = sys.argv[1:]
nonempty = ("GATE_ENV", "GATE_STAGE", "GATE_ALLOW_SELF")
for k, v in zip(keys, vals):
    if (k in nonempty and not v) or not re.fullmatch(r"[A-Za-z0-9_.@:+-]*", v):
        sys.exit("%s=%r" % (k, v))
fd = os.open(os.environ["OUT"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    for k, v in zip(keys, vals):
        f.write("%s=%s\n" % (k, v))
PY
FE_TXT=non; [ "$FOUREYES" = 1 ] && FE_TXT=oui
echo "PORTE_OK(${GATE_STAGE}) : palier ${ENV_NAME} — fourEyes=${FE_TXT} approverGroup=${APPROVER_GROUP:-aucun} (attendu — NON vérifié : aucun mécanisme ne le tient sur cette chaîne) deployerGroup=${DEPLOYER_GROUP:-aucun}→${DEPLOYER_POLICY:-—} (vérifié à l'aval sur le token de la pause) refs change=${MK_CHANGE:-—} pv=${MK_PV:-—} itsm=${GATE_ITSM}"
