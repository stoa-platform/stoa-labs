#!/usr/bin/env bash
# scripts/selfservice-palier-gate.sh — A3 (GOAL cd-applications) : LA GARDE DU
# PALIER de l'apply d'application. La §7.b + §8 de team-promote.sh portées au
# second objet : le credential du palier DÉCIDE — jamais un en-tête
# X-Environment, jamais le credential d'un tenant.
#
#   login nominatif (ci/lib/vault-login.sh → VAULT_TOKEN_FILE)
#     → CE SCRIPT :
#         0. forme, avant tout appel réseau (palier ∈ chaîne, voie connue, les
#            deux gabarits de sous-chemin portent __ENV__) ;
#         1. la voie, par POSITION : terminus ⇒ direct, et sa base doit être
#            DÉCLARÉE (APIM_TERMINUS_BASE, sans défaut — dire sa cible est
#            volontaire, G7) ; sinon direct/proxy selon ADMIN_VIA ;
#         2. l'équipe, décidée par le TOKEN (policies deploy-<x> de lookup-self)
#            — APIM_TEAM et le manifeste ne peuvent que CONCORDER ;
#         3. les capacités, en UN appel, avant de lire quoi que ce soit : le
#            ticket doit être NON inscriptible (un ticket qu'on peut s'écrire
#            n'est pas un ticket) ; en mode internal, le vault_sub du palier
#            doit être inscriptible (échouer ici, pas après la gateway) ;
#         4. LE TICKET : GET envs/<env>/wm-admin ⇒ 200, sinon PALIER_FERME ;
#         5. la sortie PALIER_OUT, forme contrôlée.
#     → préflight → converge → verify (ci/Jenkinsfile.selfservice)
#
# NE TOUCHE JAMAIS LA GATEWAY. Refus : rc 1, `REFUS: <TAG> : …` sur stdout,
# PALIER_OUT jamais écrit (et celui d'un build précédent retiré en tête). Le
# token part par FICHIER d'en-tête (jamais argv). Le corps du ticket EST le
# credential d'admin du palier : -o /dev/null, jamais lu, jamais écrit.
#
# CHARGÉ PAR LE JENKINSFILE DEPUIS origin/main (jamais l'arbre pinné au
# MERGE_SHA) dans un répertoire qui conserve l'arborescence scripts/lib +
# clients/_example : la lib se résout par BASH_SOURCE, la chaîne par la lib.
#
# Défauts : APIM_KV_PREFIX est VIDE (le miroir exact de `${APIM_KV_PREFIX:-}`
# que le Jenkinsfile passe au rôle — Jenkins n'exporte pas une variable vide ;
# `stoa` n'est porté que par le bloc environment{} du Jenkinsfile).
set -uo pipefail
set +x
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/env-chain.sh
. "$SELF_DIR/lib/env-chain.sh" || { echo "REFUS: CABLAGE_INCOMPLET : scripts/lib/env-chain.sh introuvable à côté de la garde"; exit 1; }

# REFUS_OUT (A4, optionnel) : sur refus, le TAG y est écrit — une ligne — pour
# que le post{always} de l'aval le relaie à l'amont (buildVariables, fait 11) et
# que la PR le nomme. Lu ${REFUS_OUT:-} AVANT refus() : sous set -u une lecture
# nue tuerait toute exécution sans la variable SANS ligne `REFUS:` (critique
# adverse A4) ; purgé en tête comme PALIER_OUT (un tag périmé serait relayé).
REFUS_OUT="${REFUS_OUT:-}"
# A5 : la PHRASE du refus, à côté du tag (REFUS_DETAIL_OUT, optionnel, une ligne
# bornée à 300) — même relais jusqu'à la PR, qui nomme désormais la CAUSE.
REFUS_DETAIL_OUT="${REFUS_DETAIL_OUT:-}"
refus(){ printf 'REFUS: %s : %s\n' "$1" "$2"; [ -n "$REFUS_OUT" ] && printf '%s\n' "$1" > "$REFUS_OUT"; [ -n "$REFUS_DETAIL_OUT" ] && printf '%.300s\n' "$2" | tr -d '\r' > "$REFUS_DETAIL_OUT"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; umask 077

PALIER_OUT="${PALIER_OUT:-}"; [ -n "$PALIER_OUT" ] || refus CABLAGE_INCOMPLET "PALIER_OUT absent (le Jenkinsfile doit nommer le fichier de sortie)"
rm -f "$PALIER_OUT"
[ -n "$REFUS_OUT" ] && rm -f "$REFUS_OUT"
[ -n "$REFUS_DETAIL_OUT" ] && rm -f "$REFUS_DETAIL_OUT"
VAULT_ADDR="${VAULT_ADDR:-}"; [ -n "$VAULT_ADDR" ] || refus CABLAGE_INCOMPLET "VAULT_ADDR absent"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-}"; [ -n "$VAULT_TOKEN_FILE" ] || refus CABLAGE_INCOMPLET "VAULT_TOKEN_FILE absent (login nominatif non fait ?)"
MANIFEST="${MANIFEST:-}"; [ -n "$MANIFEST" ] || refus CABLAGE_INCOMPLET "MANIFEST absent"
ENVIRONMENT="${ENVIRONMENT:-}"
# 2026-09-03 : plus de repli. Le pipeline pose 'proxy-oauth2', cette garde posait
# 'direct' — une valeur vide (withEnv(["ADMIN_VIA="]) RETIRE la variable) faisait
# donc basculer la voie d'admin du proxy OAuth2 vers le Basic direct, sans un mot.
# Vide, le `case` plus bas rend VIA_INCONNU, relayé en tag jusqu'à la PR.
ADMIN_VIA="${ADMIN_VIA:-}"
APIM_KV_MOUNT="${APIM_KV_MOUNT:-secret}"
APIM_KV_PREFIX="${APIM_KV_PREFIX:-}"
APIM_WM_CREDS_SUB_TPL="${APIM_WM_CREDS_SUB_TPL:-envs/__ENV__/wm-admin}"
APIM_OAUTH_SUB_TPL="${APIM_OAUTH_SUB_TPL:-envs/__ENV__/admin-oauth}"
APIM_API_BASE="${APIM_API_BASE:-}"        # aucun repli de lab : APIM_BASE_INVALIDE tranche
APIM_TERMINUS_BASE="${APIM_TERMINUS_BASE:-}"
APIM_PROXY_HOST="${APIM_PROXY_HOST:-}"    # idem
APIM_PROXY_API="${APIM_PROXY_API:-}"      # idem, plus le contrôle de non-vacuité ci-dessous
APIM_PROXY_VER="${APIM_PROXY_VER:-1.0}"
APIM_PROXY_PATH="${APIM_PROXY_PATH:-/rest/apigateway}"
APIM_PROXY_BASE="${APIM_PROXY_BASE:-}"
APIM_TEAM="${APIM_TEAM:-}"

# ── 0. FORME, avant tout appel réseau ────────────────────────────────────────
[ -n "$ENVIRONMENT" ] || refus ENV_INVALIDE "ENVIRONMENT vide — un apply vise un palier"
case "$ENVIRONMENT" in *[!a-z0-9]*) refus ENV_INVALIDE "'${ENVIRONMENT}' hors de ^[a-z0-9]+\$";; esac
# A4 (D0) : la chaîne est VALIDÉE avant d'être lue — une porte `to: itn` ou une
# clé mal orthographiée ne relâche rien en silence — et sa source est imprimée
# (épinglée par le Jenkinsfile sur l'extraction de origin/main).
echo "chaîne : $(_env_chain_file)"
env_chain_validate 2>"$TMP/validate.err" || refus CHAINE_INVALIDE "$(tail -1 "$TMP/validate.err" | tr -d '\r')"
CHAIN="$(env_chain)" || refus ENV_INVALIDE "chaîne d'environnements illisible"
case " $CHAIN " in *" $ENVIRONMENT "*) ;; *) refus ENV_INVALIDE "'${ENVIRONMENT}' hors de la chaîne ($CHAIN)";; esac
case "$ADMIN_VIA" in direct|proxy-oauth2) ;; *) refus VIA_INCONNU "'${ADMIN_VIA}' — attendu direct ou proxy-oauth2";; esac
case "$APIM_WM_CREDS_SUB_TPL" in *__ENV__*) ;; *) refus CREDS_SUB_SANS_PALIER "APIM_WM_CREDS_SUB_TPL='${APIM_WM_CREDS_SUB_TPL}' ne porte pas __ENV__ — un credential qui ne varie pas par palier ne décide d'aucun palier";; esac
case "$APIM_OAUTH_SUB_TPL"    in *__ENV__*) ;; *) refus CREDS_SUB_SANS_PALIER "APIM_OAUTH_SUB_TPL='${APIM_OAUTH_SUB_TPL}' ne porte pas __ENV__";; esac
sub_env(){ printf '%s' "$1" | sed "s/__ENV__/${ENVIRONMENT}/g"; }
WM_SUB="$(sub_env "$APIM_WM_CREDS_SUB_TPL")"; OAUTH_SUB="$(sub_env "$APIM_OAUTH_SUB_TPL")"
# Le chemin KV effectif est composé EXACTEMENT comme le rôle
# (apim_common/tasks/secrets.yml : `[prefix, sub] | select | join('/')` — les
# segments vides sont élidés).
kv_data_path(){ local p="${APIM_KV_MOUNT}/data"; [ -n "$APIM_KV_PREFIX" ] && p="${p}/${APIM_KV_PREFIX}"; printf '%s/%s' "$p" "$1"; }
TICKET_PATH="$(kv_data_path "$WM_SUB")"

# ── 1. LA VOIE, par POSITION ─────────────────────────────────────────────────
TERMINUS="$(env_chain_terminus)" || refus ENV_INVALIDE "terminus indéterminable"
if [ "$ENVIRONMENT" = "$TERMINUS" ]; then
  [ -n "$APIM_TERMINUS_BASE" ] || refus TERMINUS_SANS_VOIE "'${ENVIRONMENT}' est le terminus de la chaîne — pas de proxy wm-admin-<env> devant lui (exclusion structurelle G4) ; la voie directe exige APIM_TERMINUS_BASE, et dire sa cible est volontaire"
  EFFECTIVE_VIA=direct; BASE="$(sub_env "$APIM_TERMINUS_BASE")"
elif [ "$ADMIN_VIA" = direct ]; then
  EFFECTIVE_VIA=direct; BASE="$(sub_env "$APIM_API_BASE")"
else
  EFFECTIVE_VIA=proxy-oauth2
  if [ -n "$APIM_PROXY_BASE" ]; then BASE="$(sub_env "$APIM_PROXY_BASE")"
  else BASE="$(sub_env "${APIM_PROXY_HOST}/gateway/${APIM_PROXY_API}/${APIM_PROXY_VER}${APIM_PROXY_PATH}")"; fi
fi
# Un composant VIDE produit une URL syntaxiquement valide (« …/gateway//1.0/… ») que
# le contrôle de forme ci-dessous laisse passer : on le refuse AVANT, nommément.
if [ "$EFFECTIVE_VIA" = proxy-oauth2 ] && [ -z "$APIM_PROXY_BASE" ]; then
  for _c in APIM_PROXY_HOST:"$APIM_PROXY_HOST" APIM_PROXY_API:"$APIM_PROXY_API" APIM_PROXY_VER:"$APIM_PROXY_VER" APIM_PROXY_PATH:"$APIM_PROXY_PATH"; do
    [ -n "${_c#*:}" ] || refus APIM_BASE_INVALIDE "${_c%%:*} est vide — le gabarit d'URL admin ne peut pas etre compose (poser la variable, ou fournir APIM_PROXY_BASE)"
  done
fi
case "$BASE" in http://*|https://*) ;; *) refus APIM_BASE_INVALIDE "'${BASE}' — le gabarit d'URL admin doit produire une URL http(s)";; esac
if [ "$EFFECTIVE_VIA" = direct ]; then AUTH_MODE=basic; else AUTH_MODE=oauth2; fi

# ── le manifeste : la DONNÉE (name, team, auth.mode, auth.vault_sub EFFECTIF) ─
# Lu TOLÉRANT (BaseLoader) : la sévérité de forme appartient à la demande
# (app-manifest.sh), pas au ticket. Le vault_sub effectif = racine ⊕
# per_env[env], la fusion que fait le rôle (resolve-env.yml).
[ -r "$MANIFEST" ] || refus MANIFESTE_ILLISIBLE "'${MANIFEST}' absent ou illisible"
MAN="$(MAN_FILE="$MANIFEST" MAN_ENV="$ENVIRONMENT" python3 - 2>"$TMP/man.err" <<'PY'
import os, sys, yaml
try:
    d = yaml.load(open(os.environ["MAN_FILE"], encoding="utf-8"), Loader=yaml.BaseLoader) or {}
except Exception as e:
    sys.exit("YAML illisible : %s" % type(e).__name__)
app = d.get("apim_ss_app") if isinstance(d, dict) else None
if not isinstance(app, dict) or not str(app.get("name") or ""):
    sys.exit("apim_ss_app.name absent")
auth = app.get("auth") if isinstance(app.get("auth"), dict) else {}
over = ((app.get("per_env") or {}).get(os.environ["MAN_ENV"]) or {}) if isinstance(app.get("per_env"), dict) else {}
oauth = over.get("auth") if isinstance(over, dict) and isinstance(over.get("auth"), dict) else {}
mode = str(oauth.get("mode") or auth.get("mode") or "idp")
vsub = str(oauth.get("vault_sub") or auth.get("vault_sub") or "")
pe = app.get("per_env") if isinstance(app.get("per_env"), dict) else {}
vals = {"NAME": str(app.get("name")), "TEAM": str(app.get("team") or ""), "MODE": mode, "VSUB": vsub,
        "ENVS": " ".join(str(k) for k in pe.keys())}
for k, v in vals.items():
    if "\n" in v or "\r" in v:
        sys.exit("le champ %s contient un saut de ligne" % k)
for k, v in vals.items():
    print("%s=%s" % (k, v))
PY
)" || refus MANIFESTE_ILLISIBLE "${MANIFEST} — $(tail -1 "$TMP/man.err")"
MAN_TEAM="$(printf '%s\n' "$MAN" | sed -n 's/^TEAM=//p')"
MAN_MODE="$(printf '%s\n' "$MAN" | sed -n 's/^MODE=//p')"
MAN_VSUB="$(printf '%s\n' "$MAN" | sed -n 's/^VSUB=//p')"
MAN_ENVS="$(printf '%s\n' "$MAN" | sed -n 's/^ENVS=//p')"

# ── le token : fichier d'en-tête, jamais argv ────────────────────────────────
[ -s "$VAULT_TOKEN_FILE" ] || refus VAULT_TOKEN_ILLISIBLE "${VAULT_TOKEN_FILE} vide ou absent"
{ printf 'X-Vault-Token: '; tr -d '\r\n' < "$VAULT_TOKEN_FILE"; printf '\n'; } > "$TMP/vhdr" || refus VAULT_TOKEN_ILLISIBLE "$VAULT_TOKEN_FILE"
[ -n "${VAULT_NAMESPACE:-}" ] && printf 'X-Vault-Namespace: %s\n' "$VAULT_NAMESPACE" >> "$TMP/vhdr"
CA_ARGS=(); CA="${VAULT_CACERT:-${LABCTL_CA_FILE:-}}"; [ -n "$CA" ] && [ -f "$CA" ] && CA_ARGS=(--cacert "$CA")
# `${CA_ARGS[@]+"${CA_ARGS[@]}"}` : un tableau VIDE sous `set -u` en bash 3.2 est « unbound ».
vcurl(){ curl -sS --max-time 20 -H @"$TMP/vhdr" ${CA_ARGS[@]+"${CA_ARGS[@]}"} "$@"; }

# ── 2. L'IDENTITÉ (lookup-self, une fois) et LA PORTE (lecture de fichier) ─────
# team-name.yml : « l'appelant l'écrit — il ne doit pas pouvoir choisir sous
# quelle équipe son application est cloisonnée ». La chaîne le tenait par le
# chemin du credential du tenant, qu'A3 retire : repris SUR LE TOKEN.
LC="$(vcurl -o "$TMP/lookup.json" -w '%{http_code}' "${VAULT_ADDR}/v1/auth/token/lookup-self")" || LC=000
[ "$LC" = 200 ] || refus IDENTITE_INVERIFIABLE "lookup-self HTTP ${LC} — les policies du porteur sont invérifiables"
S="$(SRC="$TMP/lookup.json" python3 -c 'import json,os
d=(json.load(open(os.environ["SRC"])) or {}).get("data") or {}
p=set((d.get("policies") or [])+(d.get("identity_policies") or []))
print("\n".join(sorted(x[len("deploy-"):] for x in p if x.startswith("deploy-") and len(x)>len("deploy-"))))')" || refus IDENTITE_INVERIFIABLE "lookup-self illisible"
# A7 (ADR-090) : la porte est lue ICI (fichier), la déclaration est PROUVÉE en
# §2bis, et l'équipe se décide en §2ter — celle de Git sous une déclaration
# prouvée, celle du token sinon (A3). Rien n'est décidé sur un porteur non prouvé.
DEPLOYER_GROUP="$(env_chain_gate_deployer_group "$ENVIRONMENT")" || refus PARSE_GATE "deployerGroup de la porte '${ENVIRONMENT}'"
DEPLOYER_DECLARED=0

# ── 2bis. LA DÉCLARATION : QUI DÉPLOIE CE PALIER ? (A4 — ADR-084, la §7.a de team-promote) ──
# La porte peut nommer un groupe déployeur (annuaire n°2, LDAP→policy Vault —
# jamais la claim KC) : le token de la pause doit porter la policy projetée.
# Vérifié ICI, sur le token du geste (retrait ≠ révocation, mesuré G2), AVANT
# les capacités et le ticket : « d'abord la chaîne dit QUI, ensuite ton ticket
# ouvre-t-il » — le refus est DÉCLARATIF (DEPLOYER_GROUP_REQUIRED, le nom de la
# politique), jamais le 403 de capacité. Le lookup-self de §2 est réutilisé
# (aucun second appel). Pas de déclaration ⇒ rien (rec : autonomie du
# demandeur, décision client n°1). Famille apim-apply-<x> : <x> DOIT être le
# palier de la porte — sinon la déclaration « passerait » puis retomberait sur
# PALIER_FERME, et le refus déclaratif mentirait.
if [ -n "$DEPLOYER_GROUP" ]; then
  DEPLOYER_POLICY="$(deployer_group_policy "$DEPLOYER_GROUP")" \
    || refus DEPLOYER_GROUP_UNSUPPORTED "'${DEPLOYER_GROUP}' est hors des deux familles vérifiables (apim-apply-<x> | apim-operator-<x>) — déclaration invérifiable, refus fail-closed"
  case "$DEPLOYER_GROUP" in
    apim-apply-*) [ "${DEPLOYER_GROUP#apim-apply-}" = "$ENVIRONMENT" ] \
      || refus DEPLOYER_GROUP_UNSUPPORTED "'${DEPLOYER_GROUP}' déclaré sur la porte '${ENVIRONMENT}' — la famille apim-apply-<x> doit nommer le palier de sa porte (apim-apply-${ENVIRONMENT})" ;;
  esac
  DEPPOL="$(SRC="$TMP/lookup.json" POL="$DEPLOYER_POLICY" python3 -c 'import json,os
d=(json.load(open(os.environ["SRC"])) or {}).get("data") or {}
p=set((d.get("policies") or [])+(d.get("identity_policies") or []))
print("OK" if os.environ["POL"] in p else "KO")' 2>/dev/null)" \
    || refus DEPLOYER_GROUP_UNVERIFIABLE "lookup-self illisible — l'identité du porteur est invérifiable, refus fail-closed"
  WHO="${VAULT_USER:-}"
  [ -n "$WHO" ] || WHO="$(SRC="$TMP/lookup.json" python3 -c 'import json,os;print(str(((json.load(open(os.environ["SRC"])) or {}).get("data") or {}).get("display_name") or "(identite)"))' 2>/dev/null || echo "(identite)")"
  [ "$DEPPOL" = OK ] \
    || refus DEPLOYER_GROUP_REQUIRED "la porte vers '${ENVIRONMENT}' déclare le groupe déployeur '${DEPLOYER_GROUP}' (policy projetée '${DEPLOYER_POLICY}') — le token de l'identité '${WHO}' ne la porte pas, refus"
  echo "déclaration déployeur : '${WHO}' porte '${DEPLOYER_POLICY}' (groupe '${DEPLOYER_GROUP}')"
  DEPLOYER_DECLARED=1
fi


# ── 2ter. L'ÉQUIPE : celle de Git sous une déclaration PROUVÉE, celle du token sinon (A7, ADR-090) ──
# Sous une déclaration de déployeur, le porteur n'est pas un tenant (bob, carol,
# oscar : équipes release, opérateur de prod) : lui exiger deploy-<tenant>
# refuserait tout déploiement par une équipe release, ou donnerait à l'opérateur
# la policy d'ÉCRITURE de chaque tenant. L'équipe est alors celle du manifeste
# MERGÉ (team:, figée à la première demande — A1 —, approuvée au merge par la
# porte) ; absente ⇒ refus (jamais le tenant du déployeur du moment) ; APIM_TEAM
# ne peut que concorder ; et un palier SANS déclaration doit déjà être déclaré
# (une application ne naît pas à int — attestation partielle, dite dans l'ADR).
if [ "$DEPLOYER_DECLARED" = 1 ]; then
  TEAM="$MAN_TEAM"
  [ -n "$TEAM" ] || refus TEAM_INDETERMINEE "la porte vers '${ENVIRONMENT}' nomme le déployeur '${DEPLOYER_GROUP}', qui n'est pas l'équipe : l'équipe vient du manifeste mergé, et il n'en nomme aucune — nommer team: à la demande (une application sans équipe est confinée aux paliers autonomes)"
  [ -z "$APIM_TEAM" ] || [ "$APIM_TEAM" = "$TEAM" ] || refus TEAM_DIVERGENTE "APIM_TEAM='${APIM_TEAM}' ≠ team du manifeste '${TEAM}' — sous une déclaration de déployeur, le knob ne peut que concorder, jamais choisir"
  case "$TEAM" in *[!a-z0-9-]*) refus TEAM_INVALIDE "'${TEAM}' hors de la classe [a-z0-9-] — un nom d'équipe entre dans un chemin Vault qui porte une décision de tenant : refusé, jamais assaini";; esac
  ATTESTED=0
  for e in $CHAIN; do
    g="$(env_chain_gate_deployer_group "$e")" || refus PARSE_GATE "deployerGroup de la porte '${e}'"
    if [ -z "$g" ]; then case " $MAN_ENVS " in *" $e "*) ATTESTED=1;; esac; fi
  done
  [ "$ATTESTED" = 1 ] || refus TEAM_NON_ATTESTEE "aucun palier sans déclaration de déployeur n'est déclaré dans per_env (${MAN_ENVS:-aucun}) — une application ne naît pas à '${ENVIRONMENT}' : l'équipe '${TEAM}' n'a été attestée par aucun tenant"
  TENANTS="$(printf '%s' "$S" | tr '\n' ' ' | sed 's/ $//')"; [ -n "$TENANTS" ] || TENANTS=aucun
  echo "équipe : '${TEAM}' — celle du manifeste mergé (la porte vers ${ENVIRONMENT} nomme le déployeur '${DEPLOYER_GROUP}') ; tenants du porteur : ${TENANTS}"
else
  TEAM="$APIM_TEAM"; [ -n "$TEAM" ] || TEAM="$MAN_TEAM"
  if [ -z "$TEAM" ]; then
    N="$(printf '%s\n' "$S" | grep -c .)"
    [ "$N" -ge 1 ] || refus TEAM_INDETERMINEE "le token ne porte aucune policy deploy-<tenant> et ni APIM_TEAM ni le manifeste ne nomment d'équipe"
    [ "$N" -eq 1 ] || refus TEAM_AMBIGUE "le token porte plusieurs tenants ($(printf '%s' "$S" | tr '\n' ' ' | sed 's/ $//')) — nommer l'équipe (APIM_TEAM ou team: du manifeste)"
    TEAM="$S"
  fi
  case "$TEAM" in *[!a-z0-9-]*) refus TEAM_INVALIDE "'${TEAM}' hors de la classe [a-z0-9-] — un nom d'équipe entre dans un chemin Vault qui porte une décision de tenant : refusé, jamais assaini";; esac
  printf '%s\n' "$S" | grep -qx -- "$TEAM" \
    || refus TEAM_NON_PORTEE "l'équipe '${TEAM}' n'est pas parmi les tenants que le token porte ($(printf '%s' "$S" | tr '\n' ' ' | sed 's/ $//')) — l'appelant ne choisit pas sous quelle équipe son application est cloisonnée"
fi

# ── 3. LES CAPACITÉS, en un appel, AVANT de lire quoi que ce soit ────────────
VSUB_PATH=""
if [ "$MAN_MODE" = internal ]; then
  [ -n "$MAN_VSUB" ] || refus TENANT_NON_PORTE "mode internal sans auth.vault_sub (racine ou per_env.${ENVIRONMENT}) — le rôle ne saurait pas où écrire le client généré"
  # Le vault_sub vient du manifeste (le demandeur) et entre dans le chemin sondé
  # ET dans celui que le rôle écrira : forme contrôlée, refus nommé, jamais un
  # assainissement silencieux qui découplerait le chemin prouvé du chemin écrit.
  case "$MAN_VSUB" in *[!A-Za-z0-9_./-]*|*..*) refus VAULT_SUB_INVALIDE "auth.vault_sub='${MAN_VSUB}' hors de la classe [A-Za-z0-9_./-] (ou porte '..') — refusé";; esac
  # A7 : le chemin du client généré est LIÉ au tenant — sans ce lien, un vault_sub
  # édité à la main sous un autre tenant serait inscriptible par un déployeur de
  # cet autre tenant (critique sécurité A7 n°4).
  case "$MAN_VSUB" in "deploy/${TEAM}/"*) ;; *) refus VAULT_SUB_HORS_TENANT "auth.vault_sub='${MAN_VSUB}' n'est pas sous deploy/${TEAM}/ — le client généré d'une application de '${TEAM}' ne s'écrit que sous son tenant";; esac
  VSUB_PATH="$(kv_data_path "$MAN_VSUB")"
fi
CAPS_BODY="$(T="$TICKET_PATH" V="$VSUB_PATH" python3 -c 'import json,os;ps=[os.environ["T"]]
if os.environ["V"]: ps.append(os.environ["V"])
print(json.dumps({"paths":ps}))')"
CC="$(vcurl -o "$TMP/caps.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "$CAPS_BODY" "${VAULT_ADDR}/v1/sys/capabilities-self")" || CC=000
[ "$CC" = 200 ] || refus CAPACITES_INVERIFIABLES "sys/capabilities-self HTTP ${CC} — le token ne peut pas interroger ses propres capacités (policy default absente ?)"
CV="$(SRC="$TMP/caps.json" T="$TICKET_PATH" V="$VSUB_PATH" python3 - <<'PY'
import json, os
d = json.load(open(os.environ["SRC"])) or {}
caps = d.get("data") if isinstance(d.get("data"), dict) else d
t = set(caps.get(os.environ["T"]) or [])
if t & {"create", "update", "delete", "patch"}: print("TICKET_INSCRIPTIBLE"); raise SystemExit
v = os.environ["V"]
if v and not (set(caps.get(v) or []) & {"create", "update"}): print("TENANT_NON_PORTE"); raise SystemExit
print("OK")
PY
)" || refus CAPACITES_INVERIFIABLES "réponse capabilities-self illisible"
case "$CV" in
  OK) ;;
  TICKET_INSCRIPTIBLE) refus TICKET_INSCRIPTIBLE "le chemin du ticket ${TICKET_PATH} est INSCRIPTIBLE par cette identité — un ticket qu'on peut s'écrire n'est pas un ticket (le gabarit vise-t-il le sous-arbre du tenant ?)" ;;
  TENANT_NON_PORTE) refus TENANT_NON_PORTE "mode internal : le token ne peut pas écrire ${VSUB_PATH} (client généré du palier ${ENVIRONMENT}) — le tenant '${TEAM}' n'est pas onboardé pour ce palier, ou l'identité n'en est pas" ;;
  *) refus CAPACITES_INVERIFIABLES "verdict inattendu ($CV)" ;;
esac

# ── 4. LE TICKET — le contrôle d'accès est la porte ; le corps n'est jamais lu ─
TC="$(vcurl -o /dev/null -w '%{http_code}' "${VAULT_ADDR}/v1/${TICKET_PATH}")" || TC=000
[ "$TC" = 200 ] || refus PALIER_FERME "lecture de ${WM_SUB} refusée (HTTP ${TC}) — le palier '${ENVIRONMENT}' n'est pas ouvert pour cette identité (ADR-082 : l'ouverture est un geste de credential, pas un edit de code)"

# ── 5. SORTIE (forme contrôlée à l'écriture ; le shell re-contrôle à la lecture)
OUT="$PALIER_OUT" python3 - "$ENVIRONMENT" "$EFFECTIVE_VIA" "$BASE" "$AUTH_MODE" "$WM_SUB" "$OAUTH_SUB" "$TEAM" "$TICKET_PATH" <<'PY' || refus SORTIE_INVALIDE "une valeur de sortie est hors de la classe [A-Za-z0-9_./:@+-]"
import os, re, sys
keys = ["PALIER_ENV", "PALIER_VIA", "APIM_API_BASE", "APIM_AUTH_MODE", "APIM_WM_CREDS_SUB", "APIM_OAUTH_SUB", "PALIER_TEAM", "PALIER_TICKET"]
vals = sys.argv[1:]
for k, v in zip(keys, vals):
    if not v or not re.fullmatch(r"[A-Za-z0-9_./:@+-]+", v):
        sys.exit("%s=%r" % (k, v))
fd = os.open(os.environ["OUT"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    for k, v in zip(keys, vals):
        f.write("%s=%s\n" % (k, v))
PY
echo "palier ouvert : ${WM_SUB} lisible par l'identité du build"
echo "PALIER_CREDS=${WM_SUB}"
echo "PALIER_TEAM=${TEAM}"
echo "PALIER_BASE=${BASE}"
echo "PALIER_VIA=${EFFECTIVE_VIA}"
