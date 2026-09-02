#!/usr/bin/env bash
# test-provision-apply-a4.sh — porte HORS LIGNE d'A4 (GOAL cd-applications) :
# les portes de la chaîne et l'axe déployeur au dispatch de provision-apply.
#
#   A. la PORTE AMONT (scripts/provision-apply-gate.sh) contre des FIXTURES :
#      une arborescence jetable (script + lib + ENREGISTREUR à la place du
#      rapport de PR), un dépôt git local (manifeste multi-palier à un SHA +
#      variantes), une chaîne = copie du gabarit livrable, un STUB ITSM piloté
#      (journal des chemins bruts, touché au démarrage — canari), un SHIM git
#      qui journalise ses invocations. Refus nommés, GATE_OUT, mutations.
#   B. le CÂBLAGE de ci/Jenkinsfile.provision-apply (vue code, ordre par lignes,
#      fragment de la garde EXÉCUTÉ, mutations d'ordre) — T2.
#   C. le CÂBLAGE de ci/Jenkinsfile.selfservice (REFUS_OUT, purges, post) — T3.
#   D. le RAPPORT (provision-apply-comment.sh : REFUSAL_KIND=porte, GATE_*).
#   E. DEUX PORTES, UNE SOURCE : une chaîne sans `int` ⇒ le formulaire ne le
#      propose plus, la demande le refuse, les deux portes le refusent — T4.
#
# ── CE QUE LES ASSERTIONS D'ABSENCE EXIGENT ──────────────────────────────────
# « aucun appel ITSM », « aucun git show » sont vraies aussi quand le témoin
# est mort : le stub ITSM est TOUCHÉ au démarrage et son journal relu ; le shim
# git est exercé par la fixture elle-même. Sans contrôle positif, la suite
# refuse de courir.
#
# Discipline héritée des suites A2/A3 : toute sortie est CAPTURÉE dans un
# fichier avant grep (jamais un pipe sous pipefail) ; mutations = copie, `cmp`
# anti-no-op, `bash -n`, le scénario visé PASSE sur le mutant et l'ORIGINAL
# refuse toujours. Total attendu ÉCRIT EN DUR (une section sautée ferait
# baisser le total sans rougir).
# `A && ok || bad` (SC2015) est l'idiome des scripts de preuve du repo.
# shellcheck disable=SC2015
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; umask 077
IPID=""
cleanup(){ [ -n "$IPID" ] && kill "$IPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
EXPECTED_CHECKS=83   # sections 0 + A + D (B, C, E s'ajoutent en T2/T3/T4)

GATE_SRC="scripts/provision-apply-gate.sh"
CMT_SRC="scripts/provision-apply-comment.sh"

# ── l'arborescence jetable : script + lib + ENREGISTREUR (jamais la forge) ────
TREE="$TMP/tree"; mkdir -p "$TREE/scripts/lib" "$TREE/clients/_example"
cp scripts/lib/env-chain.sh scripts/lib/assert-merge-identity.sh "$TREE/scripts/lib/"
cp clients/_example/environments.yaml "$TREE/clients/_example/"
[ -f "$GATE_SRC" ] && cp "$GATE_SRC" "$TREE/scripts/provision-apply-gate.sh"
COMMENT_LOG="$TMP/comment.log"; : > "$COMMENT_LOG"
cat > "$TREE/scripts/provision-apply-comment.sh" <<'REC'
#!/usr/bin/env bash
# ENREGISTREUR (suite A4) : journalise ses variables, ne poste rien.
{
  printf 'APPLY_RESULT=%s\n' "${APPLY_RESULT:-}"; printf 'REFUSAL=%s\n' "${REFUSAL:-}"
  printf 'REFUSAL_KIND=%s\n' "${REFUSAL_KIND:-}"; printf 'REFUSAL_DETAIL=%s\n' "${REFUSAL_DETAIL:-}"
  printf 'PR_NUMBER=%s\n' "${PR_NUMBER:-}"; printf 'APP_NAME=%s\n' "${APP_NAME:-}"; printf 'ENV_NAME=%s\n' "${ENV_NAME:-}"
  echo '---'
} >> "${COMMENT_LOG:?}"
REC
chmod +x "$TREE/scripts/provision-apply-comment.sh"
# une seconde arborescence où la garde d'identité rend rc 2 (argument inconnu)
TREE2="$TMP/tree2"; cp -R "$TREE" "$TREE2"
printf '#!/bin/sh\necho "argument inconnu : stub" >&2; exit 2\n' > "$TREE2/scripts/lib/assert-merge-identity.sh"

# ── le shim git : journalise, puis délègue au vrai git ───────────────────────
REAL_GIT="$(command -v git)"; mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "${GIT_LOG:-/dev/null}"
exec "${REAL_GIT:?}" "$@"
SHIM
chmod +x "$TMP/bin/git"
git_shows(){ grep -c ' show ' "$TMP/git.log" || true; }

# ── le dépôt git : un manifeste multi-palier à c1, des variantes en commits frères ──
ORIGIN="$TMP/origin.git"; WORK="$TMP/work"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$WORK" && git -C "$WORK" checkout -q -b main
gitc(){ git -C "$WORK" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$WORK/clients/provisioned/applications"
MANP="$WORK/clients/provisioned/applications/appa.ansible.yml"
write_man(){ # <fichier> <bloc per_env déjà indenté>
  { printf -- '---\napim_ss_app:\n  name: "appa"\n  api: "demo-selfservice"\n  api_version: "1.0.0"\n  auth:\n    mode: "idp"\n    claim: { name: "azp" }\n  per_env:\n'; printf '%s\n' "$2"; } > "$1"
}
pe_with(){ # <ligne homol> <ligne prod>
  printf '%s\n%s\n%s\n%s' '    rec: { auth: { claim: { value: "appa-rec" } }, ip_allowlist: ["10.42.0.1"] }' \
    '    int: { auth: { claim: { value: "appa-int" } }, ip_allowlist: ["10.42.0.3"] }' "$1" "$2"
}
H0='    homol: { auth: { claim: { value: "appa-homol" } } }'
P0='    prod: { auth: { claim: { value: "appa-prod" } }, change_ref: "CHG-1", pv_ref: "PV-1" }'
write_man "$MANP" "$(pe_with "$H0" "$P0")"; gitc add -A; gitc commit -qm c1; C1=$(gitc rev-parse HEAD)
variant(){ # <nom> <bloc> → SHA du commit (chaque variante REMPLACE le manifeste)
  write_man "$MANP" "$2"; gitc add -A; gitc commit -qm "$1" >/dev/null; gitc rev-parse HEAD
}
C_HPV=$(variant homol-pv "$(pe_with '    homol: { auth: { claim: { value: "appa-homol" } }, pv_ref: "PV-2" }' "$P0")")
C_HNULL=$(variant homol-null "$(pe_with '    homol: { auth: { claim: { value: "appa-homol" } }, pv_ref: null }' "$P0")")
C_DOTDOT=$(variant prod-dotdot "$(pe_with "$H0" '    prod: { auth: { claim: { value: "appa-prod" } }, change_ref: "..", pv_ref: "PV-1" }')")
C_DOTX=$(variant prod-dotx "$(pe_with "$H0" '    prod: { auth: { claim: { value: "appa-prod" } }, change_ref: ".x", pv_ref: "PV-1" }')")
C_SEMI=$(variant prod-semi "$(pe_with "$H0" '    prod: { auth: { claim: { value: "appa-prod" } }, change_ref: "CHG;1", pv_ref: "PV-1" }')")
C_NL=$(variant prod-nl "$(pe_with "$H0" '    prod: { auth: { claim: { value: "appa-prod" } }, change_ref: "CHG\n1", pv_ref: "PV-1" }')")
gitc remote add origin "$ORIGIN"; gitc push -q origin main
[ "$(gitc show "$C_NL:./clients/provisioned/applications/appa.ansible.yml" | grep -c 'CHG\\n1')" = 1 ] || { echo "!! fixture : la variante saut-de-ligne n'est pas écrite"; exit 2; }

# ── le stub ITSM : GET /changes/<id> piloté, journal des chemins BRUTS ───────
ITSM_CTL="$TMP/itsm.json"; ITSM_LOG="$TMP/itsm.log"; : > "$ITSM_LOG"; printf '{}' > "$ITSM_CTL"
cat > "$TMP/itsm.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
CTL, LOG = sys.argv[1], sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(LOG, "a") as f: f.write(self.path + "\n")
        try: c = json.load(open(CTL))
        except Exception: c = {}
        key = self.path[len("/changes/"):] if self.path.startswith("/changes/") else None
        ent = c.get(key) if key else None
        if ent is None:
            code, b = 404, json.dumps({"message": "stub itsm: change inconnu"}).encode()
        else:
            code = int(ent.get("code", 200))
            if ent.get("raw") is not None: b = ent["raw"].encode()
            elif code == 200: b = json.dumps({"id": key, "status": ent.get("status", "")}).encode()
            else: b = json.dumps({"message": "stub itsm: indisponible"}).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = HTTPServer(("127.0.0.1", 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
PY
python3 "$TMP/itsm.py" "$ITSM_CTL" "$ITSM_LOG" > "$TMP/itsm.port" 2>"$TMP/itsm.err" &
IPID=$!
for _ in $(seq 1 60); do [ -s "$TMP/itsm.port" ] && break; sleep 0.1; done
IPORT="$(head -n1 "$TMP/itsm.port" 2>/dev/null)"
case "$IPORT" in ''|*[!0-9]*) echo "!! stub ITSM non démarré : $(cat "$TMP/itsm.err")"; exit 2;; esac
curl -s -m 5 -o /dev/null "http://127.0.0.1:$IPORT/changes/selftest"
grep -q '^/changes/selftest$' "$ITSM_LOG" || { echo "!! le stub ITSM ne journalise pas — les assertions d'absence seraient vacantes"; exit 2; }
set_itsm(){ printf '%s' "$1" > "$ITSM_CTL"; : > "$ITSM_LOG"; }
itsm_calls(){ grep -c '^/changes/' "$ITSM_LOG" || true; }
ITSM_OK='{"CHG-1":{"code":200,"status":"approved"}}'

# ── helpers ──────────────────────────────────────────────────────────────────
OUTF="$TMP/gate.env"
# run_gate <env> <mergeur> <demandeur> [VAR=val | UNSET:VAR …] → $TMP/g.out, $TMP/g.rc
run_gate(){
  local e="$1" m="$2" r="$3"; shift 3
  local -a DEFS=(ENV_NAME="$e" APP_NAME=appa MANIFEST=clients/provisioned/applications/appa.ansible.yml MERGE_SHA="$C1"
    GITEA_MERGED_BY="$m" GITEA_REQUESTER="$r" PR_NUMBER=42 GITEA_TOKEN=stub GATE_OUT="$OUTF" GIT_WORKTREE="$WORK"
    STOA_ENV_CHAIN_FILE="$TREE/clients/_example/environments.yaml" ITSM_URL="http://127.0.0.1:$IPORT"
    PATH="$TMP/bin:$PATH" GIT_LOG="$TMP/git.log" REAL_GIT="$REAL_GIT" GATE_STAGE=pre COMMENT_LOG="$COMMENT_LOG")
  local -a ENVV=() UNS=(); local a d skip
  for a in "$@"; do case "$a" in UNSET:*) UNS+=(-u "${a#UNSET:}");; esac; done
  for d in "${DEFS[@]}"; do skip=0; for a in "$@"; do [ "$a" = "UNSET:${d%%=*}" ] && skip=1; done; [ "$skip" -eq 0 ] && ENVV+=("$d"); done
  for a in "$@"; do case "$a" in UNSET:*) ;; *) ENVV+=("$a");; esac; done
  [ "${KEEP_OUT:-0}" = 1 ] || rm -f "$OUTF"; : > "$TMP/git.log"; : > "$COMMENT_LOG"; : > "$ITSM_LOG"
  env ${UNS[@]+"${UNS[@]}"} "${ENVV[@]}" bash "${GATE_BIN:-$TREE/scripts/provision-apply-gate.sh}" > "$TMP/g.out" 2>&1; echo $? > "$TMP/g.rc"
}
grc(){ cat "$TMP/g.rc"; }
gout(){ cat "$TMP/g.out"; }
out_val(){ sed -n "s/^$1=//p" "$OUTF" 2>/dev/null; }
refus(){ [ "$(grc)" = 1 ] && grep -q "^REFUS: $1 :" "$TMP/g.out"; }
cmt_val(){ sed -n "s/^$1=//p" "$COMMENT_LOG" | tail -1; }
cmt_n(){ grep -c '^---$' "$COMMENT_LOG" || true; }
chain_variant(){ # <nom> <sed-expr> → chemin ; refuse un no-op
  sed -E "$2" "$TREE/clients/_example/environments.yaml" > "$TMP/chain-$1.yaml"
  cmp -s "$TREE/clients/_example/environments.yaml" "$TMP/chain-$1.yaml" && { echo "!! chaîne variante $1 NO-OP"; exit 2; }
  printf '%s' "$TMP/chain-$1.yaml"
}

echo "═══ 0. Préconditions ═══"
[ -f "$GATE_SRC" ] && ok "0.1 $GATE_SRC existe" || bad "0.1 $GATE_SRC absent"
[ -f "$GATE_SRC" ] && bash -n "$GATE_SRC" 2>/dev/null && ok "0.2 $GATE_SRC parse" || bad "0.2 $GATE_SRC ne parse pas"
if command -v shellcheck >/dev/null 2>&1; then
  [ -f "$GATE_SRC" ] && shellcheck -x "$GATE_SRC" >"$TMP/sc.log" 2>&1 && ok "0.3 shellcheck propre" || bad "0.3 shellcheck : $(head -3 "$TMP/sc.log" 2>/dev/null)"
else bad "0.3 shellcheck absent (brew install shellcheck) — la porte ne se saute pas en silence"; fi
ok "0.4 stub ITSM sur 127.0.0.1:$IPORT (canari journalisé), shim git en tête de PATH, dépôt de fixture c1=$(printf '%s' "$C1" | cut -c1-7)"

echo
echo "═══ A. la porte amont contre les fixtures ═══"
set_itsm "$ITSM_OK"
echo "── A.1–A.2 rec : la porte n'exige pas les quatre yeux ──"
run_gate rec alice alice
[ "$(grc)" = 0 ] && [ "$(out_val GATE_ALLOW_SELF)" = 1 ] && [ "$(out_val GATE_ENV)" = rec ] && [ "$(out_val GATE_STAGE)" = pre ] \
  && ok "A.1 rec, mergeur == demandeur humain ⇒ rc 0, GATE_ALLOW_SELF=1, GATE_ENV=rec" || bad "A.1 rc $(grc) : $(gout | tail -2 | tr '\n' ' ')"
[ "$(out_val GATE_FOUR_EYES)" = 0 ] && [ -z "$(out_val GATE_DEPLOYER_GROUP)" ] && [ "$(out_val GATE_ITSM)" = none ] \
  && ok "A.1b GATE_FOUR_EYES=0, GATE_DEPLOYER_GROUP vide (rec sans déclaration), GATE_ITSM=none" || bad "A.1b fourEyes=$(out_val GATE_FOUR_EYES) deployer='$(out_val GATE_DEPLOYER_GROUP)' itsm=$(out_val GATE_ITSM)"
[ "$(itsm_calls)" = 0 ] && ok "A.1c aucun appel ITSM (la porte rec ne le déclare pas)" || bad "A.1c $(itsm_calls) appel(s) ITSM"
grep -q '^PORTE_OK(pre) : palier rec ' "$TMP/g.out" && ok "A.1d console : PORTE_OK(pre) : palier rec …" || bad "A.1d PORTE_OK absent"
grep -q "^chaîne : $TREE/clients/_example/environments.yaml$" "$TMP/g.out" && ok "A.1e console : « chaîne : <chemin posé> »" || bad "A.1e chemin de chaîne absent/divergent : $(grep '^chaîne' "$TMP/g.out")"
[ "$(cmt_n)" = 0 ] && ok "A.1f aucun commentaire de PR sur un succès" || bad "A.1f $(cmt_n) commentaire(s)"
grep -q 'auto-approbation admise par la porte' "$TMP/g.out" && ok "A.1g le journal DIT que rien n'est comparé (selfApproval)" || bad "A.1g journal muet sur l'auto-approbation"
run_gate rec alice ci
[ "$(grc)" = 0 ] && [ "$(out_val GATE_ALLOW_SELF)" = 1 ] && ok "A.2 rec, demandeur ci ⇒ rc 0 (rien à vérifier)" || bad "A.2 rc $(grc)"

echo "── A.3–A.9 int : les quatre yeux, fail-closed sur un demandeur de service ──"
run_gate int alice alice
refus FOUR_EYES_VIOLATION && ok "A.3 int, mergeur == demandeur ⇒ FOUR_EYES_VIOLATION" || bad "A.3 rc $(grc) : $(gout | tail -1)"
[ ! -f "$OUTF" ] && ok "A.3b GATE_OUT jamais écrit sur refus" || bad "A.3b GATE_OUT écrit malgré le refus"
[ "$(cmt_val APPLY_RESULT)" = REFUSED ] && [ "$(cmt_val REFUSAL)" = FOUR_EYES_VIOLATION ] && [ "$(cmt_val REFUSAL_KIND)" = porte ] && [ "$(cmt_val ENV_NAME)" = int ] && [ "$(cmt_val PR_NUMBER)" = 42 ] \
  && ok "A.3c le refus est commenté : APPLY_RESULT=REFUSED REFUSAL=FOUR_EYES_VIOLATION REFUSAL_KIND=porte" || bad "A.3c enregistreur : $(tr '\n' ' ' < "$COMMENT_LOG")"
run_gate int alice ci
refus REQUESTER_UNKNOWN && ok "A.4 int, PR ouverte par ci ⇒ REQUESTER_UNKNOWN (un demandeur de service n'est pas un demandeur)" || bad "A.4 rc $(grc) : $(gout | tail -1)"
run_gate int alice svc-bot 'GITEA_SERVICE_LOGINS=ci svc-bot'
refus REQUESTER_UNKNOWN && ok "A.5 GITEA_SERVICE_LOGINS='ci svc-bot' ⇒ svc-bot est un compte de service ⇒ REQUESTER_UNKNOWN" || bad "A.5 rc $(grc) : $(gout | tail -1)"
run_gate int alice svc-bot
[ "$(grc)" = 0 ] && ok "A.5b sans le knob, svc-bot est un humain ⇒ rc 0 (le knob décide)" || bad "A.5b rc $(grc) : $(gout | tail -1)"
run_gate int alice ''
refus REQUESTER_UNKNOWN && ok "A.6 demandeur vide ⇒ REQUESTER_UNKNOWN" || bad "A.6 rc $(grc) : $(gout | tail -1)"
run_gate int alice x UNSET:GITEA_REQUESTER
refus REQUESTER_UNKNOWN && ok "A.6b demandeur ABSENT de l'environnement ⇒ REQUESTER_UNKNOWN" || bad "A.6b rc $(grc) : $(gout | tail -1)"
run_gate int alice carol
[ "$(grc)" = 0 ] && [ "$(out_val GATE_ALLOW_SELF)" = 0 ] && [ "$(out_val GATE_FOUR_EYES)" = 1 ] \
  && ok "A.7 int, carol demande, alice merge ⇒ rc 0, GATE_ALLOW_SELF=0, GATE_FOUR_EYES=1" || bad "A.7 rc $(grc) : $(gout | tail -1)"
[ "$(out_val GATE_DEPLOYER_GROUP)" = apim-apply-int ] && [ "$(out_val GATE_DEPLOYER_POLICY)" = apply-int ] \
  && ok "A.7b GATE_DEPLOYER_GROUP=apim-apply-int → GATE_DEPLOYER_POLICY=apply-int" || bad "A.7b deployer=$(out_val GATE_DEPLOYER_GROUP)/$(out_val GATE_DEPLOYER_POLICY)"
grep -q '^porte(pre) : mergeur' "$TMP/g.out" && ! grep -q 'MERGE_IDENTITY_OK' "$TMP/g.out" \
  && ok "A.7c console : « porte(pre) : mergeur ≠ demandeur … » et JAMAIS MERGE_IDENTITY_OK (tautologique ici)" || bad "A.7c console : $(grep -E 'porte\(|MERGE_IDENTITY' "$TMP/g.out" | tr '\n' ' ')"
[ "$(out_val GATE_APPROVER_GROUP)" = int-team ] && grep -q 'approverGroup=int-team (attendu — NON vérifié' "$TMP/g.out" \
  && ok "A.7d approverGroup matérialisé (int-team) et dit NON vérifié" || bad "A.7d approver=$(out_val GATE_APPROVER_GROUP) : $(grep PORTE_OK "$TMP/g.out")"
grep -Eq '^GATE_[A-Z_]+=[A-Za-z0-9_.@:+-]*$' "$OUTF" && [ "$(grep -c '^GATE_' "$OUTF")" = 10 ] && ! grep -Evq '^GATE_[A-Z_]+=[A-Za-z0-9_.@:+-]*$' "$OUTF" \
  && ok "A.7e GATE_OUT : 10 clés, toutes dans la classe [A-Za-z0-9_.@:+-]" || bad "A.7e GATE_OUT : $(cat "$OUTF" | tr '\n' ' ')"
run_gate int Alice alice
refus FOUR_EYES_VIOLATION && ok "A.8 casse : Alice merge la PR d'alice ⇒ FOUR_EYES_VIOLATION (la normalisation de la lib)" || bad "A.8 rc $(grc) : $(gout | tail -1)"
GATE_BIN="$TREE2/scripts/provision-apply-gate.sh" run_gate int alice carol
refus CABLAGE_INCOMPLET && ok "A.9 la garde d'identité rend rc 2 ⇒ CABLAGE_INCOMPLET (jamais pris pour une violation)" || bad "A.9 rc $(grc) : $(gout | tail -1)"

echo "── A.10–A.11 homol : les références de la porte, relues sur le manifeste MERGÉ ──"
run_gate homol alice carol
refus GATE_REFS_REQUIRED && grep -q 'pv_ref' "$TMP/g.out" && ok "A.10 homol sans pv_ref ⇒ GATE_REFS_REQUIRED (pv_ref)" || bad "A.10 rc $(grc) : $(gout | tail -1)"
run_gate homol alice carol "MERGE_SHA=$C_HNULL"
refus GATE_REFS_REQUIRED && ok "A.10b pv_ref: null ⇒ GATE_REFS_REQUIRED (safe_load : null est vide, pas le texte 'null')" || bad "A.10b rc $(grc) : $(gout | tail -1)"
run_gate homol alice carol "MERGE_SHA=$C_HPV"
[ "$(grc)" = 0 ] && [ "$(out_val GATE_PV_REF)" = PV-2 ] && [ "$(out_val GATE_DEPLOYER_GROUP)" = apim-apply-homol ] \
  && ok "A.11 homol avec pv_ref ⇒ rc 0, GATE_PV_REF=PV-2, déclaration apim-apply-homol" || bad "A.11 rc $(grc) pv=$(out_val GATE_PV_REF) : $(gout | tail -1)"

echo "── A.12–A.22 prod : l'ITSM au terminus, AVANT la voie ──"
run_gate prod alice carol APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway
[ "$(grc)" = 0 ] && [ "$(out_val GATE_ITSM)" = checked ] && [ "$(out_val GATE_CHANGE_REF)" = CHG-1 ] && [ "$(out_val GATE_PV_REF)" = PV-1 ] \
  && ok "A.12 prod, refs + ITSM approved + voie déclarée ⇒ rc 0, GATE_ITSM=checked" || bad "A.12 rc $(grc) itsm=$(out_val GATE_ITSM) : $(gout | tail -1)"
[ "$(itsm_calls)" = 1 ] && grep -qx '/changes/CHG-1' "$ITSM_LOG" && ok "A.12b un seul GET /changes/CHG-1 (chemin brut exact)" || bad "A.12b journal ITSM : $(tr '\n' ' ' < "$ITSM_LOG")"
grep -q "^itsm : change 'CHG-1' approved" "$TMP/g.out" && ok "A.12c console : « itsm : change 'CHG-1' approved … »" || bad "A.12c ligne itsm absente"
[ "$(out_val GATE_DEPLOYER_GROUP)" = apim-operator-prod ] && [ "$(out_val GATE_DEPLOYER_POLICY)" = operator-deploy ] \
  && ok "A.12d déclaration du terminus lue : apim-operator-prod → operator-deploy" || bad "A.12d deployer=$(out_val GATE_DEPLOYER_GROUP)/$(out_val GATE_DEPLOYER_POLICY)"
run_gate prod alice carol
refus TERMINUS_SANS_VOIE && [ "$(itsm_calls)" = 1 ] && ok "A.13 prod sans APIM_TERMINUS_BASE ⇒ TERMINUS_SANS_VOIE, APRÈS l'appel ITSM (journal : 1)" || bad "A.13 rc $(grc) itsm_calls=$(itsm_calls) : $(gout | tail -1)"
set_itsm '{"CHG-1":{"code":200,"status":"draft"}}'
run_gate prod alice carol APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway
refus ITSM_NOT_APPROVED && grep -q "'draft'" "$TMP/g.out" && ok "A.14 change draft ⇒ ITSM_NOT_APPROVED (statut cité)" || bad "A.14 rc $(grc) : $(gout | tail -1)"
[ "$(cmt_val REFUSAL)" = ITSM_NOT_APPROVED ] && [ "$(cmt_val REFUSAL_KIND)" = porte ] && ok "A.14b refus commenté ITSM_NOT_APPROVED / porte" || bad "A.14b enregistreur : $(tr '\n' ' ' < "$COMMENT_LOG")"
set_itsm '{}'
run_gate prod alice carol APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway
refus ITSM_NOT_APPROVED && grep -q 'INCONNU' "$TMP/g.out" && ok "A.15 change inconnu (404) ⇒ ITSM_NOT_APPROVED" || bad "A.15 rc $(grc) : $(gout | tail -1)"
set_itsm '{"CHG-1":{"code":500}}'
run_gate prod alice carol APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway
refus ITSM_UNAVAILABLE && ok "A.16 ITSM 500 ⇒ ITSM_UNAVAILABLE" || bad "A.16 rc $(grc) : $(gout | tail -1)"
set_itsm "$ITSM_OK"
run_gate prod alice carol APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway ITSM_URL=http://127.0.0.1:1
refus ITSM_UNAVAILABLE && ok "A.17 ITSM muet (port fermé) ⇒ ITSM_UNAVAILABLE" || bad "A.17 rc $(grc) : $(gout | tail -1)"
run_gate prod alice carol APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway ITSM_URL=
refus ITSM_NOT_CONFIGURED && [ "$(itsm_calls)" = 0 ] && ok "A.18 ITSM_URL vide ⇒ ITSM_NOT_CONFIGURED, sans appel" || bad "A.18 rc $(grc) itsm_calls=$(itsm_calls) : $(gout | tail -1)"
set_itsm '{"CHG-1":{"code":200,"raw":"<html>not json</html>"}}'
run_gate prod alice carol APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway
refus ITSM_UNAVAILABLE && ok "A.18b 200 non-JSON ⇒ ITSM_UNAVAILABLE (réponse illisible)" || bad "A.18b rc $(grc) : $(gout | tail -1)"
set_itsm "$ITSM_OK"
for V in "$C_DOTDOT:..(segment parent)" "$C_DOTX:.x(segment caché)" "$C_SEMI:CHG;1(injection)" "$C_NL:saut de ligne"; do
  SHA="${V%%:*}"; LBL="${V#*:}"
  run_gate prod alice carol APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway "MERGE_SHA=$SHA"
  refus REF_INVALIDE && [ "$(itsm_calls)" = 0 ] && ok "A.19 change_ref $LBL ⇒ REF_INVALIDE, AVANT tout appel ITSM" || bad "A.19 $LBL : rc $(grc) itsm_calls=$(itsm_calls) : $(gout | tail -1)"
done
run_gate rec alice carol
[ "$(grc)" = 0 ] && [ "$(itsm_calls)" = 0 ] && ok "A.22 rec avec ITSM_URL posé ⇒ zéro appel ITSM" || bad "A.22 rc $(grc) itsm_calls=$(itsm_calls)"

echo "── A.23–A.26 la chaîne : déclarations et validation ──"
CH_TEAM="$(chain_variant kc 's/^    deployerGroup: apim-apply-int$/    deployerGroup: int-team/')"
run_gate int alice carol "STOA_ENV_CHAIN_FILE=$CH_TEAM"
refus DEPLOYER_GROUP_UNSUPPORTED && ok "A.23 deployerGroup: int-team (nom KC) ⇒ DEPLOYER_GROUP_UNSUPPORTED à l'amont déjà" || bad "A.23 rc $(grc) : $(gout | tail -1)"
CH_REC="$(chain_variant rec 's/^    deployerGroup: apim-apply-int$/    deployerGroup: apim-apply-rec/')"
run_gate int alice carol "STOA_ENV_CHAIN_FILE=$CH_REC"
refus DEPLOYER_GROUP_UNSUPPORTED && ok "A.24 int: deployerGroup: apim-apply-rec ⇒ DEPLOYER_GROUP_UNSUPPORTED (la famille apim-apply-<x> nomme le palier de sa porte)" || bad "A.24 rc $(grc) : $(gout | tail -1)"
CH_ITN="$(chain_variant itn 's/^  - to: int$/  - to: itn/')"
run_gate int alice carol "STOA_ENV_CHAIN_FILE=$CH_ITN"
refus CHAINE_INVALIDE && ok "A.25 to: itn ⇒ CHAINE_INVALIDE (aucune porte relâchée en silence)" || bad "A.25 rc $(grc) : $(gout | tail -1)"
CH_KEY="$(chain_variant key 's/^    fourEyes: true$/    foureyes: true/')"
run_gate int alice alice "STOA_ENV_CHAIN_FILE=$CH_KEY"
refus CHAINE_INVALIDE && ok "A.26 clé foureyes (mal orthographiée) ⇒ CHAINE_INVALIDE — sans D0, int aurait laissé passer l'auto-approbation" || bad "A.26 rc $(grc) : $(gout | tail -1)"

echo "── A.27–A.37 la forme, avant tout réseau ──"
run_gate zz alice carol
refus ENV_INVALIDE && [ "$(itsm_calls)" = 0 ] && ok "A.27 palier hors chaîne ⇒ ENV_INVALIDE" || bad "A.27 rc $(grc) : $(gout | tail -1)"
run_gate 'int;rm' alice carol
refus ENV_INVALIDE && [ "$(git_shows)" = 0 ] && ok "A.28 ENV_NAME='int;rm' ⇒ ENV_INVALIDE, aucun git show (shim)" || bad "A.28 rc $(grc) shows=$(git_shows) : $(gout | tail -1)"
run_gate int alice carol "STOA_ENV_CHAIN_FILE=$TMP/nexiste.pas.yaml"
refus CHAINE_ILLISIBLE && ok "A.29 chaîne absente ⇒ CHAINE_ILLISIBLE" || bad "A.29 rc $(grc) : $(gout | tail -1)"
run_gate int alice carol MERGE_SHA=0000000000000000000000000000000000000000
refus MANIFESTE_ABSENT && ok "A.30 MERGE_SHA inconnu du dépôt ⇒ MANIFESTE_ABSENT" || bad "A.30 rc $(grc) : $(gout | tail -1)"
run_gate int alice carol MERGE_SHA=abc
refus MERGE_SHA_INVALIDE && ok "A.30b MERGE_SHA hors forme ⇒ MERGE_SHA_INVALIDE" || bad "A.30b rc $(grc) : $(gout | tail -1)"
run_gate int alice carol MANIFEST=autre/appa.ansible.yml
refus MANIFESTE_INVALIDE && ok "A.31 MANIFEST hors de MANIFEST_DIR ⇒ MANIFESTE_INVALIDE" || bad "A.31 rc $(grc) : $(gout | tail -1)"
run_gate int alice carol MANIFEST=autre/appa.ansible.yml MANIFEST_DIR=autre
refus MANIFESTE_ABSENT && ok "A.31b MANIFEST_DIR=autre honoré (la forme passe, git show échoue : MANIFESTE_ABSENT)" || bad "A.31b rc $(grc) : $(gout | tail -1)"
printf 'GATE_ENV=perime\n' > "$OUTF"
KEEP_OUT=1 run_gate int alice alice
[ ! -f "$OUTF" ] && ok "A.32 GATE_OUT périmé retiré en tête, jamais réécrit sur refus" || bad "A.32 GATE_OUT périmé survit : $(cat "$OUTF")"
run_gate int alice carol GATE_STAGE=dispatch
[ "$(grc)" = 0 ] && [ "$(out_val GATE_STAGE)" = dispatch ] && grep -q '^PORTE_OK(dispatch) : palier int ' "$TMP/g.out" \
  && ok "A.33 GATE_STAGE=dispatch ⇒ PORTE_OK(dispatch), GATE_STAGE=dispatch dans GATE_OUT" || bad "A.33 rc $(grc) : $(gout | tail -1)"
run_gate int alice carol UNSET:GATE_OUT
[ "$(grc)" = 1 ] && grep -q '^REFUS: CABLAGE_INCOMPLET : GATE_OUT' "$TMP/g.out" && ok "A.34 GATE_OUT absent ⇒ CABLAGE_INCOMPLET" || bad "A.34 rc $(grc) : $(gout | tail -1)"
run_gate int alice alice UNSET:PR_NUMBER
refus FOUR_EYES_VIOLATION && [ "$(cmt_n)" = 0 ] && ok "A.35 sans PR_NUMBER, le refus n'est pas commenté (journal seul)" || bad "A.35 rc $(grc) cmt=$(cmt_n)"
grep -q 'REFUSAL_DETAIL=' "$COMMENT_LOG" 2>/dev/null; run_gate int alice alice
D="$(cmt_val REFUSAL_DETAIL)"; [ -n "$D" ] && [ "${#D}" -le 400 ] && ok "A.36 le détail commenté est borné (${#D} car.)" || bad "A.36 détail : '${D}'"
grep -qE 'X-Vault-Token|/v1/' "$TREE/scripts/provision-apply-gate.sh" && bad "A.37 la porte amont parle à Vault (elle n'a pas de token)" || ok "A.37 la porte amont ne contient aucun appel Vault"

echo "── A.M mutations : chaque contrôle porte une épreuve ──"
mutant(){ # <sed-expr> <nom> → $TMP/mut-<nom>/… ; rc 0 si le mutant diffère et parse
  local d="$TMP/mut-$2"; rm -rf "$d"; cp -R "$TREE" "$d"
  sed -E "$1" "$TREE/scripts/provision-apply-gate.sh" > "$d/scripts/provision-apply-gate.sh"
  if cmp -s "$TREE/scripts/provision-apply-gate.sh" "$d/scripts/provision-apply-gate.sh"; then bad "A.M mutation $2 NO-OP (l'ancre a bougé)"; return 1; fi
  bash -n "$d/scripts/provision-apply-gate.sh" 2>/dev/null || { bad "A.M mutant $2 ne parse pas"; return 1; }
  return 0
}
set_itsm "$ITSM_OK"
if mutant 's@^if \[ "\$FOUREYES" = 1 \]; then$@if false; then@' fe; then
  GATE_BIN="$TMP/mut-fe/scripts/provision-apply-gate.sh" run_gate int alice alice
  [ "$(grc)" = 0 ] && ok "A.M1 quatre-yeux retiré ⇒ int même identité PASSE sur le mutant (le détecteur A.3 verrait rouge)" || bad "A.M1 le mutant refuse encore : $(gout | tail -1)"
  run_gate int alice alice; refus FOUR_EYES_VIOLATION && ok "A.M1' l'original refuse toujours" || bad "A.M1' l'original a dérivé"
fi
if mutant 's@^  for s in \$GITEA_SERVICE_LOGINS; do@  for s in; do@' svc; then
  GATE_BIN="$TMP/mut-svc/scripts/provision-apply-gate.sh" run_gate int alice ci
  [ "$(grc)" = 0 ] && ok "A.M2 test des comptes de service retiré ⇒ int par ci PASSE sur le mutant" || bad "A.M2 le mutant refuse encore : $(gout | tail -1)"
  run_gate int alice ci; refus REQUESTER_UNKNOWN && ok "A.M2' l'original refuse toujours" || bad "A.M2' l'original a dérivé"
fi
if mutant 's@^\[ "\$NEED_PV" = 0 \] \|\| \[ -n "\$MK_PV" \] \\$@true \\@' pv; then
  GATE_BIN="$TMP/mut-pv/scripts/provision-apply-gate.sh" run_gate homol alice carol
  [ "$(grc)" = 0 ] && ok "A.M3 contrôle pv_ref retiré ⇒ homol sans PV passe sur le mutant" || bad "A.M3 le mutant refuse encore : $(gout | tail -1)"
  run_gate homol alice carol; refus GATE_REFS_REQUIRED && ok "A.M3' l'original refuse toujours" || bad "A.M3' l'original a dérivé"
fi
if mutant 's@^if \[ "\$ITSMCHECK" = 1 \]; then$@if false; then@' itsm; then
  set_itsm '{"CHG-1":{"code":200,"status":"draft"}}'
  GATE_BIN="$TMP/mut-itsm/scripts/provision-apply-gate.sh" run_gate prod alice carol APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway
  [ "$(grc)" = 0 ] && ok "A.M4 ITSM retiré ⇒ un change draft passe sur le mutant" || bad "A.M4 le mutant refuse encore : $(gout | tail -1)"
  run_gate prod alice carol APIM_TERMINUS_BASE=http://prod-gw/rest/apigateway; refus ITSM_NOT_APPROVED && ok "A.M4' l'original refuse toujours" || bad "A.M4' l'original a dérivé"
  set_itsm "$ITSM_OK"
fi
if mutant 's@^  DEPLOYER_POLICY=\$\(deployer_group_policy "\$DEPLOYER_GROUP"\) \\$@  DEPLOYER_POLICY=apply-x \\@' dep; then
  GATE_BIN="$TMP/mut-dep/scripts/provision-apply-gate.sh" run_gate int alice carol "STOA_ENV_CHAIN_FILE=$CH_TEAM"
  [ "$(grc)" = 0 ] && ok "A.M5 projection court-circuitée ⇒ int-team passe sur le mutant" || bad "A.M5 le mutant refuse encore : $(gout | tail -1)"
  run_gate int alice carol "STOA_ENV_CHAIN_FILE=$CH_TEAM"; refus DEPLOYER_GROUP_UNSUPPORTED && ok "A.M5' l'original refuse toujours" || bad "A.M5' l'original a dérivé"
fi
if mutant 's@^env_chain_validate 2>@true 2>@' val; then
  GATE_BIN="$TMP/mut-val/scripts/provision-apply-gate.sh" run_gate int alice alice "STOA_ENV_CHAIN_FILE=$CH_KEY"
  [ "$(grc)" = 0 ] && [ "$(out_val GATE_FOUR_EYES)" = 0 ] && ok "A.M6 validation retirée ⇒ la clé mal orthographiée passe ET int n'a plus de porte (GATE_FOUR_EYES=0) : le vert vacant que D0 ferme" || bad "A.M6 mutant : rc $(grc) fourEyes=$(out_val GATE_FOUR_EYES) : $(gout | tail -1)"
  run_gate int alice alice "STOA_ENV_CHAIN_FILE=$CH_KEY"; refus CHAINE_INVALIDE && ok "A.M6' l'original refuse toujours" || bad "A.M6' l'original a dérivé"
fi

echo
echo "═══ D. le rapport de PR (provision-apply-comment.sh) : REFUSAL_KIND=porte, la ligne « porte du palier » ═══"
RPT="$TMP/rpt"; mkdir -p "$RPT/scripts/lib"; cp "$CMT_SRC" "$RPT/scripts/"
BODY="$TMP/body.md"
printf '#!/usr/bin/env bash\ncp "${COMMENT_BODY_FILE:?}" "%s"\n' "$BODY" > "$RPT/scripts/lib/gitea-pr-comment.sh"
run_rpt(){ # [VAR=val …] → $BODY
  rm -f "$BODY"
  env -i PATH="$PATH" HOME="$HOME" GITEA_TOKEN=stub PR_NUMBER=42 APP_NAME=appa ENV_NAME=int GIT_REPO=ci/stoa-labs "$@" bash "$RPT/scripts/provision-apply-comment.sh" >"$TMP/rpt.out" 2>&1; echo $? > "$TMP/rpt.rc"
}
run_rpt APPLY_RESULT=REFUSED REFUSAL=FOUR_EYES_VIOLATION REFUSAL_KIND=porte 'REFUSAL_DETAIL=le demandeur a approuvé sa propre demande'
[ "$(cat "$TMP/rpt.rc")" = 0 ] && grep -q 'porte du palier' "$BODY" && grep -q 'FOUR_EYES_VIOLATION' "$BODY" && ! grep -q 'ne correspondent pas' "$BODY" \
  && ok "D.1 REFUSED + REFUSAL_KIND=porte ⇒ la phrase de la porte, jamais « la PR et main ne correspondent pas »" || bad "D.1 rc $(cat "$TMP/rpt.rc") : $(tr '\n' ' ' < "$BODY" 2>/dev/null | head -c 300)"
run_rpt APPLY_RESULT=REFUSED REFUSAL=PAYLOAD_PERIME 'REFUSAL_DETAIL=x'
grep -q 'ne correspondent pas' "$BODY" && ! grep -q 'porte du palier' "$BODY" && ok "D.2 REFUSED sans kind ⇒ le texte A2 (réconciliation) inchangé" || bad "D.2 texte : $(tr '\n' ' ' < "$BODY" | head -c 300)"
run_rpt APPLY_RESULT=FAILURE VALIDATOR=alice REFUSAL=DEPLOYER_GROUP_REQUIRED 'REFUSAL_DETAIL=refus de l aval selfservice-app-deploy #7'
grep -q 'Refus `DEPLOYER_GROUP_REQUIRED`' "$BODY" && grep -q 'PAS déployée' "$BODY" && ok "D.3 FAILURE + DEPLOYER_GROUP_REQUIRED (relayé de l'aval) ⇒ « L'application n'est PAS déployée. Refus \`DEPLOYER_GROUP_REQUIRED\` »" || bad "D.3 texte : $(tr '\n' ' ' < "$BODY" | head -c 300)"
run_rpt APPLY_RESULT=SUCCESS VALIDATOR=alice GATE_ENV=int GATE_FOUR_EYES=1 GATE_APPROVER_GROUP=int-team GATE_DEPLOYER_GROUP=apim-apply-int GATE_DEPLOYER_POLICY=apply-int GATE_ITSM=none
grep -q 'porte du palier `int`' "$BODY" && grep -q 'non vérifiée' "$BODY" && grep -q 'apim-apply-int' "$BODY" && grep -q 'apply-int' "$BODY" && grep -q 'int-team' "$BODY" \
  && ok "D.4 GATE_* posés ⇒ ligne « porte du palier \`int\` … approbation attendue int-team — non vérifiée … porteur attendu apim-apply-int → apply-int »" || bad "D.4 texte : $(tr '\n' ' ' < "$BODY" | head -c 400)"
grep -q 'quatre yeux : oui' "$BODY" && grep -q 'ITSM re-vérifié au dispatch : non' "$BODY" && ok "D.4b quatre yeux : oui · ITSM re-vérifié au dispatch : non" || bad "D.4b texte : $(grep 'porte du palier' "$BODY")"
run_rpt APPLY_RESULT=SUCCESS VALIDATOR=alice
! grep -q 'porte du palier' "$BODY" && grep -q 'RÉUSSI' "$BODY" && ok "D.5 sans GATE_ENV, aucune ligne « porte du palier » (compatibilité A2)" || bad "D.5 texte : $(tr '\n' ' ' < "$BODY" | head -c 300)"
run_rpt APPLY_RESULT=SUCCESS VALIDATOR=alice 'GATE_ENV=int;rm' GATE_FOUR_EYES=1
! grep -q 'porte du palier' "$BODY" && ok "D.6 GATE_ENV hors classe ⇒ ligne non rendue (le rapport se défend)" || bad "D.6 texte : $(grep 'porte du palier' "$BODY")"

echo
echo "═══ Z. total attendu ═══"
TOTAL=$((PASS+FAIL))
if [ "$EXPECTED_CHECKS" -gt 0 ] && [ "$TOTAL" -eq "$EXPECTED_CHECKS" ]; then
  ok "$TOTAL contrôles exécutés = $EXPECTED_CHECKS attendus (aucune section sautée)"
else
  bad "$TOTAL contrôles exécutés, $EXPECTED_CHECKS attendus — une section a été sautée ou ajoutée sans mettre EXPECTED_CHECKS à jour"
fi
echo
echo "═══════════════════════════════════════════════════"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
