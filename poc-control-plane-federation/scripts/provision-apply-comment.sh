#!/usr/bin/env bash
# provision-apply-comment.sh — remonter le RÉSULTAT DE L'APPLY sur la PR
# (ADR-081, corollaire 2).
#
# POURQUOI. Le plan commente déjà la PR ; l'apply, lui, ne laissait aucune trace
# ailleurs que dans un log de build. Le demandeur devait aller la chercher dans
# un troisième endroit, et l'auditeur ne trouvait dans la PR que la moitié de
# l'histoire : ce qui allait être fait, jamais ce qui a été fait.
#
# En commentant ici, la PR devient le TABLEAU DE BORD de la demande — le plan, la
# décision (le merge) et le résultat au même endroit, pour le demandeur, le
# valideur et l'auditeur. C'est ce qui traite le besoin d'ergonomie SANS déplacer
# la décision hors de Git (ADR-081).
#
# A2 (GOAL cd-applications) : le tableau de bord dit aussi QUELLE RÉFÉRENCE a
# été projetée — le SHA de merge appliqué et le digest du manifeste effectif du
# palier — et nomme un refus (réconciliation avant la pause, SHA non confirmé
# par l'aval). C'est la réponse à « qu'est-ce qui tourne en rec ? ».
#
# DEUX MARQUEURS, PAS UN (critique de la spec, 2026-09-02) :
#   `<!-- provision-apply -->`       le RÉSULTAT d'un apply réel (SUCCESS/FAILURE/
#                                    ABORTED, SHA_NON_CONFIRME) — il a suivi une
#                                    identité nominative ;
#   `<!-- provision-apply-refus -->` un refus AVANT la pause (APPLY_RESULT=REFUSED :
#                                    PAYLOAD_PERIME, PALIER_SUPPLANTE, …) — posé
#                                    sans humain, donc atteignable par un webhook
#                                    forgé : il ne doit JAMAIS pouvoir PATCHer
#                                    l'enregistrement SHA/digest d'un apply réel.
#
# LE DÉTAIL D'UN REFUS EST ASSAINI avant d'atteindre la PR (suppression des
# sauts de ligne, neutralisation de la syntaxe markdown active, troncature,
# code span) : il peut porter des fragments relus sur la forge, jamais une
# valeur brute du payload (règle de provision-apply-reconcile.sh), et le puits
# se défend quand même.
#
# CE SCRIPT NE DÉCIDE RIEN et ne doit JAMAIS faire échouer un apply réussi : il
# rapporte. L'appelant l'invoque en fin de build, succès comme échec, et ignore
# son code retour (cf. le job) — un commentaire qui ne part pas ne doit pas
# transformer un apply vert en build rouge.
#
# Entrées (env) :
#   PR_NUMBER      (req) numéro de la PR fusionnée
#   APPLY_RESULT   (req) SUCCESS | FAILURE | ABORTED | REFUSED — résultat du build aval,
#                        ou REFUSED = refus AVANT tout apply (réconciliation), aucune identité consommée
#   APP_NAME       (req) application appliquée
#   ENV_NAME       (req) environnement cible
#   VALIDATOR      (req sauf REFUSED) identité NOMINATIVE qui a validé et appliqué
#   APPLIED_SHA    (opt) SHA de merge réellement projeté par l'aval (A2)
#   APPLIED_DIGEST (opt) digest du manifeste effectif du palier à ce SHA (app_manifest_digest_env)
#   EXPECTED_SHA   (opt) la référence DEMANDÉE (MERGE_SHA) — écrite quand elle diffère de APPLIED_SHA
#   REFUSAL        (opt) tag d'un refus (PAYLOAD_PERIME, SHA_NON_CONFIRME, …) ;
#   REFUSAL_DETAIL (opt) sa phrase — assainie ici
#   REFUSAL_KIND   (opt) `porte` = refus de LA PORTE DE LA CHAÎNE (A4 : fourEyes, refs/ITSM,
#                        terminus, déclaration déployeur) avant ou au dispatch — la phrase du
#                        refus le dit ; absent = refus de réconciliation (A2), texte inchangé
#   GATE_ENV, GATE_FOUR_EYES, GATE_APPROVER_GROUP, GATE_DEPLOYER_GROUP, GATE_DEPLOYER_POLICY, GATE_ITSM
#                  (opt, A4) la porte relue AU DISPATCH — rendue en une ligne « porte du palier »
#                        SEULEMENT si GATE_ENV est posé (la sentinelle « la porte a tourné ») ;
#                        l'approbation attendue y est dite NON vérifiée (aucun mécanisme ne la
#                        tient sur cette chaîne — ADR-084)
#   BUILD_URL      (opt) lien du build (Jenkins le fournit)
#   GIT_WEB_HOST   (opt) base Gitea vue de l'HUMAIN : rend le SHA cliquable
#   GIT_REPO / GITEA_TOKEN / GIT_HOST — cf. lib/gitea-pr-comment.sh
set -uo pipefail
set +x

PR_NUMBER="${PR_NUMBER:?PR_NUMBER requis}"
APPLY_RESULT="${APPLY_RESULT:?APPLY_RESULT requis}"
APP_NAME="${APP_NAME:?APP_NAME requis}"
ENV_NAME="${ENV_NAME:?ENV_NAME requis}"
RES_UC="$(printf '%s' "$APPLY_RESULT" | tr '[:lower:]' '[:upper:]')"
case "$RES_UC" in
  REFUSED) VALIDATOR="${VALIDATOR:-}"; MARKER='<!-- provision-apply-refus -->' ;;
  *)       VALIDATOR="${VALIDATOR:?VALIDATOR requis}"; MARKER='<!-- provision-apply -->' ;;
esac
BUILD_URL="${BUILD_URL:-}"
GIT_REPO="${GIT_REPO:-ci/stoa-labs}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/applycmt.XXXXXX)"; trap 'rm -rf "$WORK"' EXIT

APPLY_RESULT="$RES_UC" APP_NAME="$APP_NAME" ENV_NAME="$ENV_NAME" \
VALIDATOR="$VALIDATOR" BUILD_URL="$BUILD_URL" BODY_OUT="$WORK/comment.md" \
APPLIED_SHA="${APPLIED_SHA:-}" APPLIED_DIGEST="${APPLIED_DIGEST:-}" EXPECTED_SHA="${EXPECTED_SHA:-}" \
REFUSAL="${REFUSAL:-}" REFUSAL_DETAIL="${REFUSAL_DETAIL:-}" REFUSAL_KIND="${REFUSAL_KIND:-}" \
GATE_ENV="${GATE_ENV:-}" GATE_FOUR_EYES="${GATE_FOUR_EYES:-}" GATE_APPROVER_GROUP="${GATE_APPROVER_GROUP:-}" \
GATE_DEPLOYER_GROUP="${GATE_DEPLOYER_GROUP:-}" GATE_DEPLOYER_POLICY="${GATE_DEPLOYER_POLICY:-}" GATE_ITSM="${GATE_ITSM:-}" \
GIT_WEB_HOST="${GIT_WEB_HOST:-}" GIT_REPO="$GIT_REPO" python3 - <<'PY'
import os, re
res = os.environ["APPLY_RESULT"]
def tag_ok(s):      # un tag de refus : classe stricte, sinon rien
    return s if re.fullmatch(r"[A-Z][A-Z0-9_]{2,40}", s or "") else ""
def sha_ok(s):
    return s if re.fullmatch(r"[0-9a-f]{40}", s or "") else ""
def digest_ok(s):
    return s if re.fullmatch(r"sha256:[0-9a-f]{64}", s or "") else ""
def clean(s, n=300):  # détail : une ligne, sans syntaxe markdown active, borné, en code span
    s = re.sub(r"[\r\n\t]+", " ", s or "")
    s = re.sub(r"[\[\]()<>*_~`!|\\]", " ", s)
    s = re.sub(r" {2,}", " ", s).strip()
    return s[:n]
refusal = tag_ok(os.environ.get("REFUSAL", "").strip())
detail = clean(os.environ.get("REFUSAL_DETAIL", ""))
head = {
    "SUCCESS": "✅ **Apply nominatif RÉUSSI**",
    "FAILURE": "❌ **Apply nominatif EN ÉCHEC**",
    "ABORTED": "⚠️ **Apply INTERROMPU**",
    "REFUSED": "❌ **Apply REFUSÉ avant la pause**",
}.get(res, f"⚠️ **Apply — résultat `{clean(res, 40)}`**")
if refusal:
    head += f" — `{refusal}`"
# L'identité est NOMINATIVE et c'est le point : elle relie l'acte à un humain,
# pas au compte de service du CI. C'est ce que l'auditeur vient chercher.
lines = [
    f"{head}\n",
    f"- application : `{clean(os.environ['APP_NAME'], 80)}`",
    f"- environnement : `{clean(os.environ['ENV_NAME'], 40)}`",
]
validator = clean(os.environ.get("VALIDATOR", ""), 80)
if validator:
    lines.append(f"- appliqué sous l'identité de : **{validator}**")
elif res == "REFUSED":
    lines.append("- identité : aucune consommée (refus avant la demande en attente)")
# A2 — la RÉFÉRENCE projetée : ce qui répond à « qu'est-ce qui tourne ici ? ».
sha = sha_ok(os.environ.get("APPLIED_SHA", "").strip())
expected = sha_ok(os.environ.get("EXPECTED_SHA", "").strip())
web = os.environ.get("GIT_WEB_HOST", "").rstrip("/")
def link(s):
    return f" ({web}/{os.environ['GIT_REPO']}/commit/{s})" if web else ""
if sha:
    lines.append(f"- référence appliquée (SHA de merge) : `{sha}`{link(sha)}")
if expected and expected != sha:
    lines.append(f"- référence DEMANDÉE (SHA de merge de la PR) : `{expected}`{link(expected)}")
digest = digest_ok(os.environ.get("APPLIED_DIGEST", "").strip())
if digest:
    lines.append(f"- digest du manifeste effectif `per_env.{clean(os.environ['ENV_NAME'], 40)}` à ce SHA : `{digest}`")
if os.environ.get("BUILD_URL"):
    lines.append(f"- build : {clean(os.environ['BUILD_URL'], 200)}")
# A4 — LA PORTE DU PALIER, relue au dispatch : ce qui a été EXIGÉ, à côté de ce
# qui a été fait. Rendue seulement si GATE_ENV est posé (la porte a tourné) et de
# forme sûre ; l'approbation attendue est dite NON vérifiée — aucun mécanisme ne
# la tient sur cette chaîne (ADR-084, limite nommée) ; le porteur, lui, est
# vérifié au dispatch de l'aval sur le token de la pause (§2bis).
gate_env = os.environ.get("GATE_ENV", "").strip()
if re.fullmatch(r"[a-z0-9]+", gate_env):
    def g(k, n=60):
        v = os.environ.get(k, "").strip()
        return clean(v, n) if re.fullmatch(r"[A-Za-z0-9_.@:+-]*", v) else ""
    oui = lambda k: "oui" if g(k) == "1" else "non"
    approver = g("GATE_APPROVER_GROUP"); deployer = g("GATE_DEPLOYER_GROUP"); policy = g("GATE_DEPLOYER_POLICY")
    lines.append(f"- porte du palier `{gate_env}` (relue au dispatch) : quatre yeux : {oui('GATE_FOUR_EYES')}"
                 + (f" · approbation attendue `{approver}` — **non vérifiée** (aucun mécanisme ne la tient sur cette chaîne)" if approver else " · approbation : aucun groupe déclaré")
                 + (f" · porteur attendu `{deployer}` → `{policy}` (vérifié au dispatch sur le token)" if deployer else " · porteur : aucune déclaration (la rétention du credential décide)")
                 + f" · ITSM re-vérifié au dispatch : {'oui' if g('GATE_ITSM') == 'checked' else 'non'}")
lines.append("")
if res == "SUCCESS":
    lines.append("La convergence et le `verify` fail-closed sont passés. "
                 "Cette PR porte désormais l'historique complet : plan, décision (merge), résultat"
                 + (", référence" if sha else "") + ".")
elif res == "REFUSED":
    lines.append(f"**CE webhook n'a rien appliqué.** Refus `{refusal or 'REFUSED'}`"
                 + (f" : `{detail}`" if detail else "") + ".")
    if os.environ.get("REFUSAL_KIND", "").strip() == "porte":
        lines.append("La porte du palier (`environments.yaml` : quatre yeux, références/ITSM, terminus, "
                     "déclaration déployeur) a refusé avant la demande en attente — aucune identité n'a été "
                     "demandée, rien n'a été écrit. Corriger la cause (identité du demandeur, référence de "
                     "changement ou de PV, statut ITSM, déclaration de la porte) puis rejouer le webhook. "
                     "Un apply antérieur de cette PR, s'il existe, reste celui que le commentaire « Apply nominatif » décrit.")
    else:
        lines.append("Le webhook ne fait pas foi : la PR et `main` ont été relus (forge, git) et ne "
                     "correspondent pas — aucune identité n'a été demandée. Un apply antérieur de cette PR, "
                     "s'il existe, reste celui que le commentaire « Apply nominatif » décrit.")
elif refusal == "SHA_NON_CONFIRME":
    lines.append("**L'aval a projeté " + (f"`{sha}`" if sha else "un état non annoncé")
                 + ", PAS la référence demandée" + (f" `{expected}`" if expected else "") + ".** "
                 "État de la gateway à vérifier ; repli (A6) à envisager."
                 + (f" Détail : `{detail}`." if detail else ""))
elif refusal:
    lines.append(f"**L'application n'est PAS déployée.** Refus `{refusal}`"
                 + (f" : `{detail}`" if detail else "") + ".")
    env_name = clean(os.environ["ENV_NAME"], 40)
    # A5 — L'ORDRE APP/API : le remède est nommé (ensemble EXPLICITE de tags, jamais
    # un préfixe), et il n'est pas « rouvrir une demande » : rejouer CE webhook.
    if refusal in ("API_NOT_PROMOTED", "API_VERSION_MISMATCH", "API_INACTIVE", "API_AMBIGUE"):
        lines.append(f"**L'ordre app/API** (A5) : une application ne précède jamais son API au palier. "
                     f"Promouvoir l'API vers `{env_name}` par la chaîne des APIs (`api-promote-request` → PR `promote/<api>-{env_name}` → merge → `team-promote`), "
                     "ou l'activer au palier, puis **rejouer ce webhook** : rien n'a été écrit sur la gateway, cette PR reste la référence — "
                     "inutile de rouvrir une demande.")
    elif refusal in ("API_AT_PALIER_UNCONFIRMED", "SUBSCRIPTION_UNCONFIRMED"):
        lines.append(f"**L'ordre app/API** (A5, au `verify`) : la convergence a eu lieu, mais la relecture ne confirme pas l'API au palier `{env_name}` "
                     "ou la souscription au GUID attendu — l'API a bougé entre l'apply et sa relecture (désactivée, remplacée). "
                     "Rétablir l'API au palier puis **rejouer ce webhook** ; l'état de la gateway est à vérifier avant tout trafic.")
    else:
        lines.append("Le merge a eu lieu, l'apply non — corriger puis relancer l'apply ; inutile de rouvrir une demande.")
else:
    lines.append("**L'application n'est PAS déployée.** Le merge a eu lieu, l'apply non — "
                 "corriger puis relancer l'apply ; inutile de rouvrir une demande.")
open(os.environ["BODY_OUT"], "w").write("\n".join(lines) + "\n")
PY

GIT_REPO="$GIT_REPO" GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN requis}" \
PR_NUMBER="$PR_NUMBER" GIT_HOST="${GIT_HOST:-http://gitea:3000}" \
COMMENT_MARKER="$MARKER" COMMENT_BODY_FILE="$WORK/comment.md" \
  bash "$SELF_DIR/lib/gitea-pr-comment.sh"
