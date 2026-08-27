# G7 — Le parcours du demandeur : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prouver la promotion complète `dev → rec → int → homol → prod` sur la
chaîne d'équipe, chaque saut visible sur sa PR, chaque apply commenté avec son
résultat et l'identité qui l'a porté — et fermer les quatre trous mesurés qui
l'empêchent (terminus inatteignable, itsmCheck non re-vérifié au dispatch,
tableau de bord périmé, porteur non nommé).

**Architecture:** La voie du terminus se dérive de la POSITION (dernier palier
de la chaîne ⇒ voie directe Basic via `envs/<terminus>/wm-admin`, moteur
ansible seul) — miroir du dessin G6. L'ITSM est re-vérifié au seul site de
dispatch de la chaîne d'équipe (`team-promote.sh` §6ter), fail-closed. Le corps
de PR et le commentaire d'apply disent la vérité (flux réel, porteur nommé).

**Tech Stack:** bash 3.2-compatible (macOS), python3+PyYAML dans les heredocs,
harnais hors-ligne existants (`test-env-chain.sh`, `test-team-promote-wiring.sh`
avec stub HTTP smart-git), Jenkins + Gitea + Vault + wM du lab pour le live.

**Spec:** `docs/superpowers/specs/2026-08-27-g7-parcours-du-demandeur-design.md`

## Global Constraints

- bash 3.2 : jamais `mapfile`, jamais d'indice négatif de tableau ; apostrophes
  françaises INTERDITES dans `${VAR:?message}` (piège G1 n°3).
- Jamais de secret en argv ni en env exporté au-delà du besoin ; tokens par
  FICHIER (`VAULT_TOKEN_FILE`, header-file curl).
- Refus NOMMÉS (`JETON : explication`), fail-closed partout ; toute garde
  nouvelle est ANTÉRIEURE au site moteur unique `run_engine` et prouvée par
  mutation dans `test-team-promote-wiring.sh`.
- `set -uo pipefail` sans `-e` dans team-promote.sh (les gardes explicites
  portent l'échec) ; ne pas changer ce régime.
- Fonctions de lib env-chain : SŒURS, jamais un 4e champ de `env_chain_gate`
  (motif documenté dans la lib).
- Commits `type(scope): description` en français, un commit par tâche.
- `make lint-ci` doit rester vert à chaque tâche (shellcheck compris).

---

### Task 1 : lib env-chain — `env_chain_terminus` + `env_chain_gate_itsm_check`

**Files:**
- Modify: `scripts/lib/env-chain.sh` (ajouter deux fonctions sœurs, après
  `env_chain_gate_deployer_group`)
- Test: `scripts/test-env-chain.sh` (nouvelle section ⑦)

**Interfaces:**
- Produces: `env_chain_terminus` → stdout `prod` (dernier palier de la chaîne,
  rc=1 + message stderr si source illisible/vide). `env_chain_gate_itsm_check
  <env>` → stdout `ITSMCHECK=0|1` (rc=1 si source illisible). Consommées par
  les tâches 2, 3, 4, 5.

- [ ] **Step 1: Ajouter les deux fonctions à `scripts/lib/env-chain.sh`**

```bash
# env_chain_terminus — le DERNIER palier de la chaîne. C'est la POSITION qui
# fait le terminus, jamais le nom « prod » (même règle que env_chain_nonprod,
# qui retire ce même dernier élément) : un client qui nomme son terminus
# autrement ne casse rien. FONCTION SŒUR (jamais un champ de env_chain_gate).
env_chain_terminus() {
  local all; all="$(env_chain)" || return 1
  # shellcheck disable=SC2206
  local a=($all)
  [ "${#a[@]}" -ge 1 ] || { echo "env-chain: chaîne vide" >&2; return 1; }
  printf '%s' "${a[$((${#a[@]}-1))]}"
}

# env_chain_gate_itsm_check <env> — la porte d'arrivée déclare-t-elle la
# re-vérification ITSM au dispatch ? Rend ITSMCHECK=0|1. FONCTION SŒUR, même
# motif que env_chain_gate_four_eyes (un 4e champ positionnel de
# env_chain_gate relâcherait la porte EN SILENCE chez ses appelants).
env_chain_gate_itsm_check() {
  local f; f="$(_env_chain_file)"
  [ -r "$f" ] || { echo "env-chain: source illisible : $f" >&2; return 1; }
  python3 - "$f" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
g = next((x for x in (d.get("gates") or []) if x.get("to") == sys.argv[2]), {}) or {}
print("ITSMCHECK=%s" % ("1" if g.get("itsmCheck") else "0"))
PY
}
```

- [ ] **Step 2: Étendre `scripts/test-env-chain.sh` (section ⑦, avant le bilan)**

Le harnais existant fait `ok()`/`bad()` + compteurs. Ajouter :

```bash
echo "⑦ lecteurs G7 — terminus par position, itsmCheck par porte"
# shellcheck source=scripts/lib/env-chain.sh
. "$ROOT/scripts/lib/env-chain.sh"
T="$(env_chain_terminus)"
[ "$T" = prod ] && ok "env_chain_terminus rend le DERNIER palier (prod)" \
                || bad "env_chain_terminus rend '$T' (attendu prod)"
I="$(env_chain_gate_itsm_check prod)"
[ "$I" = "ITSMCHECK=1" ] && ok "la porte prod déclare itsmCheck (lu par la lib)" \
                         || bad "itsmCheck prod non lu ($I)"
I="$(env_chain_gate_itsm_check rec)"
[ "$I" = "ITSMCHECK=0" ] && ok "la porte rec ne déclare PAS itsmCheck" \
                         || bad "itsmCheck rec inattendu ($I)"
# CONTRE-ÉPREUVE : source cassée ⇒ refus FERMÉ des deux lecteurs (jamais une
# valeur devinée). On pointe un fichier ABSENT via STOA_ENV_CHAIN_FILE.
if OUT=$(STOA_ENV_CHAIN_FILE="$ROOT/nexiste.pas.yaml" env_chain_terminus 2>&1); then
  bad "env_chain_terminus a rendu '$OUT' sur source absente (fail-open)"
else
  ok "env_chain_terminus refuse FERMÉ sur source absente"
fi
if OUT=$(STOA_ENV_CHAIN_FILE="$ROOT/nexiste.pas.yaml" env_chain_gate_itsm_check prod 2>&1); then
  bad "env_chain_gate_itsm_check a rendu '$OUT' sur source absente (fail-open)"
else
  ok "env_chain_gate_itsm_check refuse FERMÉ sur source absente"
fi
```

⚠ Le sourcing de la lib doit se faire APRÈS les sections ①-⑥ existantes (elles
n'en dépendent pas) et le `trap` de restauration existant reste inchangé.

- [ ] **Step 3: Jouer la porte** — `bash scripts/test-env-chain.sh` ⇒ toutes
  sections PASS, 0 FAIL. Puis `shellcheck scripts/lib/env-chain.sh
  scripts/test-env-chain.sh`.

- [ ] **Step 4: Commit** — `feat(g7): env-chain apprend le terminus (position) et itsmCheck (porte) — deux lecteurs sœurs fail-closed`

---

### Task 2 : team-promote.sh — la voie du terminus, par position

**Files:**
- Modify: `scripts/team-promote.sh` (§1bis nouveau après le bloc §1 ; §8 :
  `EFFECTIVE_VIA` remplace les deux tests `[ "$ADMIN_VIA" = direct ]`)
- Modify: `ci/Jenkinsfile.team-promote` (bloc `environment{}` : défaut
  `APIM_DIRECT_BASE_TPL`)
- Test: `scripts/test-team-promote-wiring.sh`

**Interfaces:**
- Consumes: `env_chain_terminus` (Task 1).
- Produces: refus `TERMINUS_SANS_VOIE` et second site
  `COMBINAISON_NON_SUPPORTEE` ; variable interne `EFFECTIVE_VIA`
  (`direct` si `TO_ENV` == terminus, sinon `$ADMIN_VIA`). La tâche 8 (live)
  s'appuie sur le défaut Jenkinsfile.

- [ ] **Step 1: §1bis dans team-promote.sh** — insérer juste après le refus
  `ENV_INVALIDE … authoring` (fin du §1 actuel) :

```bash
# ── 1bis. LA VOIE DU TERMINUS — dérivée de la POSITION, jamais du nom ────────
# Aucun proxy wm-admin-<env> n'existe devant le DERNIER palier : l'exclusion
# est STRUCTURELLE (G4 — env_chain_nonprod partout, ci-horsprod sans le
# terminus). La voie y est donc DIRECTE (Basic, creds lus dans Vault par le
# rôle), quelle que soit la valeur du knob ADMIN_VIA — qui ne pilote QUE les
# paliers intermédiaires. Même dessin que ci/Jenkinsfile.rollback (G6) :
# terminus par position, deux voies.
TERMINUS="$(env_chain_terminus)" || fail "CHAINE_ILLISIBLE : terminus indéterminable (environments.yaml)"
if [ "$TO_ENV" = "$TERMINUS" ]; then
  [ -n "$APIM_DIRECT_BASE_TPL" ] \
    || fail "TERMINUS_SANS_VOIE : '$TO_ENV' est le terminus de la chaîne — pas de proxy wm-admin-<env> devant lui (exclusion structurelle G4) ; la voie directe exige APIM_DIRECT_BASE_TPL, et dire sa cible est volontaire"
  [ "$PROMOTE_ENGINE" != labctl ] \
    || fail "COMBINAISON_NON_SUPPORTEE : PROMOTE_ENGINE=labctl vers le terminus '$TO_ENV' — pas de proxy OAuth2 devant le terminus, et le moteur labctl ne s'authentifie que par bearer ; utiliser le moteur ansible (voie directe, creds lus dans Vault par le rôle, jamais écrits sur disque)"
  EFFECTIVE_VIA=direct
else
  EFFECTIVE_VIA="$ADMIN_VIA"
fi
```

- [ ] **Step 2: §8 — consommer `EFFECTIVE_VIA`** : remplacer les DEUX
  occurrences `if [ "$ADMIN_VIA" = direct ]; then` du §8 (choix de
  `APIM_BASE` ; choix de `ENGINE_AUTH_ARGS`) par
  `if [ "$EFFECTIVE_VIA" = direct ]; then`. Ne PAS toucher au §0bis (les
  knobs `ADMIN_VIA=direct` globaux gardent leurs exigences propres).

- [ ] **Step 3: Jenkinsfile — le défaut du gabarit direct** : dans
  `environment{}` de `ci/Jenkinsfile.team-promote`, sous `APIM_API_BASE_TPL`,
  ajouter :

```groovy
    // Voie DIRECTE du terminus (G7) : la gateway réelle elle-même, sans proxy
    // (__ENV__ absent du gabarit est licite — la substitution est un no-op).
    APIM_DIRECT_BASE_TPL = "${env.APIM_DIRECT_BASE_TPL ?: 'http://webmethods-real:5555/rest/apigateway'}"
```

- [ ] **Step 4: Étendre le harnais wiring** (`scripts/test-team-promote-wiring.sh`) :
  - `ORDRE_TOKENS` : insérer `TERMINUS_SANS_VOIE` entre
    `BRANCH_FORMAT_INVALIDE` et `PAYLOAD_PERIME` (le §1bis est entre §1 et §2).
  - `run_promote` : ajouter `APIM_DIRECT_BASE_TPL` à l'env, pilotable — 6e
    argument positionnel `direct_tpl` avec défaut :

```bash
  local out="$1" branch="$2" engine="${3:-ansible}" repo="${4:-$TEAM_REPO}" chain="${5:-}" \
        direct_tpl="${6-http://webmethods-real:5555/rest/apigateway}" rc
```

  puis `APIM_DIRECT_BASE_TPL="$direct_tpl" \` dans le bloc `env`.
  ⚠ `${6-défaut}` (sans `:`) : passer explicitement `""` doit donner la
  chaîne VIDE (cas refus), l'omettre doit donner le défaut.
  - Nouveaux cas volet B (après les cas G2, avant le bilan). Le marqueur prod
    exige change_ref+pv_ref (porte prod), et le lookup doit porter
    `operator-deploy` (deployerGroup `apim-operator-prod`) ; l'ITSM du stub
    n'existe pas encore (Task 3) — pour CETTE tâche, jouer les cas terminus
    sur une CHAÎNE VARIANTE sans `itsmCheck` (5e arg de `run_promote`),
    fabriquée dans le cas :

```bash
echo
echo "== G7-a nominal TERMINUS : voie DIRECTE, moteur basic, jamais oauth2 =="
CHAIN_G7="$TMP/chain-g7.yaml"
python3 - "$ROOT/clients/_example/environments.yaml" "$CHAIN_G7" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for g in d["gates"]:
    if g.get("to") == "prod":
        g.pop("itsmCheck", None)   # l'ITSM au dispatch est éprouvé en Task 3
yaml.safe_dump(d, open(sys.argv[2], "w"), sort_keys=False)
PY
D="$TMP/tg7a"; mk_team "$D"
write_marker "$D" prod "$PIN_C1" "1.0.0" "$ARCH_SHA" "CHG-0001" "PV-1" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-prod" oscar ci 200 200 default,operator-deploy
run_promote "$TMP/og7a" "promote/accounts-read-prod" ansible "$TEAM_REPO" "$CHAIN_G7"; RC=$?
[ "$RC" -eq 0 ] && ok "G7-a rc=0 (nominal terminus)" \
                || bad "G7-a rc=$RC : $(tail -3 "$TMP/og7a" | tr '\n' ' ')"
[ "$(wc -l < "$STUB_LOG" 2>/dev/null | tr -d ' ')" = 1 ] \
  && ok "G7-a moteur invoqué EXACTEMENT une fois" \
  || bad "G7-a invocations moteur : $(cat "$STUB_LOG" 2>/dev/null)"
grep -q 'apim_ss_auth_mode=basic' "$STUB_LOG" \
  && grep -q 'apim_ss_vault_wm_creds_sub=envs/prod/wm-admin' "$STUB_LOG" \
  && ok "G7-a voie directe : basic + creds du palier lus dans Vault par le rôle" \
  || bad "G7-a extra-vars inattendues : $(cat "$STUB_LOG")"
grep -q 'apim_ss_auth_mode=oauth2' "$STUB_LOG" \
  && bad "G7-a la voie oauth2 a fuité vers le terminus" \
  || ok "G7-a jamais oauth2 vers le terminus"
grep -q 'apim_ss_api_base=http://webmethods-real:5555/rest/apigateway' "$STUB_LOG" \
  && ok "G7-a base d'admin = le gabarit DIRECT (pas le proxy)" \
  || bad "G7-a base d'admin inattendue : $(cat "$STUB_LOG")"

echo "== G7-b terminus SANS gabarit direct : refus nommé, moteur jamais lancé =="
set_ctl true "$MERGE_SHA" "promote/accounts-read-prod" oscar ci 200 200 default,operator-deploy
run_promote "$TMP/og7b" "promote/accounts-read-prod" ansible "$TEAM_REPO" "$CHAIN_G7" ""; RC=$?
refus_attendu "G7-b" "APIM_DIRECT_BASE_TPL vide + terminus" TERMINUS_SANS_VOIE "$TMP/og7b" "$RC"

echo "== G7-c labctl vers le terminus : COMBINAISON_NON_SUPPORTEE =="
run_promote "$TMP/og7c" "promote/accounts-read-prod" labctl "$TEAM_REPO" "$CHAIN_G7"; RC=$?
refus_attendu "G7-c" "labctl + terminus" COMBINAISON_NON_SUPPORTEE "$TMP/og7c" "$RC"

echo "== G7-d un palier INTERMÉDIAIRE n'emprunte JAMAIS la voie directe =="
D="$TMP/tg7d"; mk_team "$D"
write_marker "$D" int "$PIN_C1" "1.0.0" "$ARCH_SHA" "" "" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-int" oscar ci 200 200 default,apply-int
run_promote "$TMP/og7d" "promote/accounts-read-int"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'apim_ss_auth_mode=oauth2' "$STUB_LOG" \
  && ok "G7-d int reste en proxy-oauth2 (EFFECTIVE_VIA ne déborde pas)" \
  || bad "G7-d rc=$RC, extra-vars : $(cat "$STUB_LOG" 2>/dev/null)"
```

- [ ] **Step 5: Jouer** — `bash scripts/test-team-promote-wiring.sh` ⇒ 0 FAIL
  (les volets A/B existants restent verts — l'insertion de
  `TERMINUS_SANS_VOIE` dans `ORDRE_TOKENS` prouve la position du §1bis).
  `bash ci/lint-jenkinsfiles.sh` (ou `make lint-ci`) vert.

- [ ] **Step 6: Commit** — `feat(g7): la voie du terminus se dérive de la position — directe, moteur ansible seul, refus nommés avant tout réseau`

---

### Task 3 : team-promote.sh — §6ter, l'ITSM re-vérifié au dispatch

**Files:**
- Modify: `scripts/team-promote.sh` (garde de forme sur `MK_CHANGE` au §6 ;
  §6ter nouveau entre §6bis et §7 ; knob `ITSM_URL` déclaré avec les autres,
  près de `PROMOTE_ENGINE`)
- Modify: `ci/Jenkinsfile.team-promote` (`ITSM_URL` dans `environment{}`)
- Test: `scripts/test-team-promote-wiring.sh` (route ITSM du stub + cas)

**Interfaces:**
- Consumes: `env_chain_gate_itsm_check` (Task 1), `MK_CHANGE` (§6 existant).
- Produces: refus `ITSM_NOT_CONFIGURED`, `ITSM_UNAVAILABLE`,
  `ITSM_NOT_APPROVED` — dans CET ordre dans le fichier, tous avant §7.

- [ ] **Step 1: knob** — sous `PROMOTE_ENGINE=`/`ADMIN_VIA=` en tête de
  team-promote.sh :

```bash
ITSM_URL="${ITSM_URL:-}"   # requis SEULEMENT si la porte d'arrivée déclare itsmCheck (§6ter)
```

- [ ] **Step 2: garde de forme sur la valeur MERGÉE** — au §6, juste après
  l'extraction de `MK_CHANGE` (ligne `MK_CHANGE=$(…)`) :

```bash
# Le change_ref MERGÉ devient un segment d'URL ITSM (§6ter) : la classe exigée
# à la demande (REF_INVALIDE, api-promote-request.sh) est RE-vérifiée sur ce
# qui a été mergé — l'anti-TOCTOU vaut pour la FORME aussi.
case "$MK_CHANGE" in
  *[!A-Za-z0-9._-]*) fail "REF_INVALIDE : change_ref du marqueur MERGÉ contient un caractère hors de [A-Za-z0-9._-] — il deviendrait un segment d'URL ITSM, refus" ;;
esac
```

- [ ] **Step 3: §6ter** — insérer APRÈS le bloc §6bis (après l'appel
  `assert-merge-identity.sh … || fail "IDENTITE_REFUSEE…"`), AVANT §7 :

```bash
# ── 6ter. L'ITSM, RE-VÉRIFIÉ AU DISPATCH (A6/ADR-075 — miroir de labctl
# dispatch-gate, au seul site de dispatch de la chaîne d'équipe) ─────────────
# Sur cette chaîne, l'« approbation » est le MERGE : rien n'a interrogé l'ITSM
# depuis la demande. Un change approuvé PUIS révoqué passerait — exactement la
# fenêtre TOCTOU qu'A6 a fermée côté governance. Fail-closed, refus nommés,
# et les trois causes restent distinctes (forensics ADR-070) : un ITSM muet
# n'est pas une révocation, une URL absente n'est pas un ITSM en panne.
ITSMC=$(env_chain_gate_itsm_check "$TO_ENV") || fail "PARSE_GATE : itsmCheck"
case "$ITSMC" in
  ITSMCHECK=0) ;;
  ITSMCHECK=1)
    [ -n "$ITSM_URL" ] \
      || fail "ITSM_NOT_CONFIGURED : la porte vers '$TO_ENV' déclare itsmCheck mais ITSM_URL n'est pas posée — le contrôle déclaré doit pouvoir s'exécuter, refus fail-closed"
    ITSM_CODE=$(curl -sS -o "$TMP/itsm.json" -w '%{http_code}' --max-time 20 \
      "${ITSM_URL%/}/changes/${MK_CHANGE}") || ITSM_CODE=000
    case "$ITSM_CODE" in
      200) ITSM_STATUS=$(SRC="$TMP/itsm.json" python3 -c 'import json,os;print(str((json.load(open(os.environ["SRC"])) or {}).get("status") or ""))') \
             || fail "ITSM_UNAVAILABLE : réponse ITSM illisible pour '${MK_CHANGE}'"
           [ "$ITSM_STATUS" = approved ] \
             || fail "ITSM_NOT_APPROVED : le change '${MK_CHANGE}' est '${ITSM_STATUS:-<sans statut>}' dans l'ITSM au moment du dispatch — approuvé hier n'est pas approuvé maintenant (anti-TOCTOU)" ;;
      404) fail "ITSM_NOT_APPROVED : le change '${MK_CHANGE}' est INCONNU de l'ITSM (404) — un change inconnu n'est pas un change approuvé" ;;
      *)   fail "ITSM_UNAVAILABLE : GET /changes/${MK_CHANGE} → HTTP ${ITSM_CODE} — statut invérifiable, refus fail-closed" ;;
    esac
    echo "itsm : change '${MK_CHANGE}' approved au moment du dispatch"
    ;;
  *) fail "PARSE_GATE : sortie inattendue ($ITSMC)" ;;
esac
```

⚠ ORDRE DES REFUS DANS LE FICHIER : `ITSM_NOT_CONFIGURED` puis (dans le
`case`) `ITSM_UNAVAILABLE` (branche 200-illisible) puis `ITSM_NOT_APPROVED`…
— pour `ORDRE_TOKENS` (qui prend la PREMIÈRE occurrence de chaque jeton),
insérer après `IDENTITE_REFUSEE` : `ITSM_NOT_CONFIGURED ITSM_UNAVAILABLE
ITSM_NOT_APPROVED` et vérifier que la première occurrence textuelle de chacun
respecte cet ordre relatif (sinon ajuster la liste au fichier réel).

- [ ] **Step 4: Jenkinsfile** — dans `environment{}` :

```groovy
    // ITSM (G7 §6ter) : re-vérification du change au dispatch quand la porte
    // du palier cible déclare itsmCheck. Même mock que la chaîne governance.
    ITSM_URL = "${env.ITSM_URL ?: 'http://itsm-mock:8788'}"
```

- [ ] **Step 5: le stub apprend l'ITSM** — dans le heredoc `stub.py` de
  `test-team-promote-wiring.sh`, ajouter la route AVANT `if ".git/" in path:` :

```python
        # ITSM (G7 §6ter). DÉFAUT STRICT : sans clé "itsm" au ctl, 404 (change
        # inconnu) — la valeur qui refuse le plus. Un cas nominal itsm doit le
        # DIRE (set_itsm 200 approved), jamais en hériter.
        m = re.match(r"^/changes/([A-Za-z0-9._-]+)$", path)
        if m:
            it = c.get("itsm")
            if it is None:
                self._send(404, json.dumps({"message": "stub itsm: change inconnu"}))
                return
            code = int(it.get("code", 200))
            if code != 200:
                self._send(code, json.dumps({"message": "stub itsm: indisponible"}))
                return
            self._send(200, json.dumps({"id": m.group(1), "status": it.get("status", "")}))
            return
```

  Et le helper (après `set_ctl`) :

```bash
set_itsm() { # <code http> <status> — fusionne la clé "itsm" au ctl COURANT
  python3 - "$STUB_CTL" "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["itsm"] = {"code": int(sys.argv[2]), "status": sys.argv[3]}
json.dump(d, open(sys.argv[1], "w"))
PY
}
```

  Et `run_promote` gagne `ITSM_URL="$GIT_HOST"` dans son bloc `env` (pilotable
  par un 7e argument positionnel `itsm_url` : `itsm_url="${7-$GIT_HOST}"`).

- [ ] **Step 6: cas volet B** (à la suite des cas G7-a..d ; ceux-ci utilisent
  la chaîne LIVRÉE — la porte prod y déclare itsmCheck) :

```bash
echo "== G7-e ITSM approved au dispatch : le terminus passe (chaîne LIVRÉE) =="
D="$TMP/tg7e"; mk_team "$D"
write_marker "$D" prod "$PIN_C1" "1.0.0" "$ARCH_SHA" "CHG-0001" "PV-1" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-prod" oscar ci 200 200 default,operator-deploy
set_itsm 200 approved
run_promote "$TMP/og7e" "promote/accounts-read-prod"; RC=$?
[ "$RC" -eq 0 ] && grep -q "itsm : change 'CHG-0001' approved" "$TMP/og7e" \
  && ok "G7-e itsmCheck déclaré + approved ⇒ dispatch" \
  || bad "G7-e rc=$RC : $(tail -3 "$TMP/og7e" | tr '\n' ' ')"

echo "== G7-f ITSM : draft / inconnu / en panne / non configuré ⇒ refus, moteur jamais lancé =="
set_itsm 200 draft
run_promote "$TMP/og7f1" "promote/accounts-read-prod"; RC=$?
refus_attendu "G7-f(i)" "change draft au dispatch" ITSM_NOT_APPROVED "$TMP/og7f1" "$RC"
python3 - "$STUB_CTL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d.pop("itsm", None); json.dump(d, open(sys.argv[1], "w"))
PY
run_promote "$TMP/og7f2" "promote/accounts-read-prod"; RC=$?
refus_attendu "G7-f(ii)" "change INCONNU (404, défaut strict du stub)" ITSM_NOT_APPROVED "$TMP/og7f2" "$RC"
set_itsm 503 x
run_promote "$TMP/og7f3" "promote/accounts-read-prod"; RC=$?
refus_attendu "G7-f(iii)" "ITSM en panne (503)" ITSM_UNAVAILABLE "$TMP/og7f3" "$RC"
set_itsm 200 approved
run_promote "$TMP/og7f4" "promote/accounts-read-prod" ansible "$TEAM_REPO" "" \
  "http://webmethods-real:5555/rest/apigateway" ""; RC=$?
refus_attendu "G7-f(iv)" "ITSM_URL absente + porte itsmCheck" ITSM_NOT_CONFIGURED "$TMP/og7f4" "$RC"

echo "== G7-g anti-TOCTOU de FORME : change_ref mergé hors classe ⇒ REF_INVALIDE =="
D="$TMP/tg7g"; mk_team "$D"
write_marker "$D" prod "$PIN_C1" "1.0.0" "$ARCH_SHA" 'CHG-1/../admin' "PV-1" alice
seal_team "$D"
set_ctl true "$MERGE_SHA" "promote/accounts-read-prod" oscar ci 200 200 default,operator-deploy
set_itsm 200 approved
run_promote "$TMP/og7g" "promote/accounts-read-prod"; RC=$?
refus_attendu "G7-g" "change_ref mergé portant '/'" REF_INVALIDE "$TMP/og7g" "$RC"
```

- [ ] **Step 7: Jouer** — `bash scripts/test-team-promote-wiring.sh` 0 FAIL
  (⚠ les cas prod PRÉEXISTANTS du harnais — ⑩, ⑭ notamment — refusent AVANT
  §6ter ; vérifier qu'ils restent verts tels quels) ; `make lint-ci` vert.

- [ ] **Step 8: Commit** — `feat(g7): l'itsm est re-vérifié au dispatch de la chaîne d'équipe — trois refus distincts, fail-closed, ordre prouvé par mutation`

---

### Task 4 : ouvrir le terminus — seed + policy, dérivés de la chaîne

**Files:**
- Modify: `scripts/setup-vault-envs.sh` (seed `envs/<terminus>/wm-admin` après
  la boucle hors-prod ; JAMAIS de `admin-oauth` terminus)
- Modify: `scripts/setup-vault-userpass.sh` (policy `operator-deploy` : + read
  du secret d'admin du terminus, terminus dérivé)

**Interfaces:**
- Consumes: `env_chain_terminus` (Task 1).
- Produces: secret `secret/stoa/envs/<terminus>/wm-admin`
  (`{username,password}`, défauts `Administrator`/`manage` = les knobs
  `WM_USER`/`WM_PASS` de `setup-vault.sh`) ; policy `operator-deploy` étendue.
  La tâche 8 (live) en dépend.

- [ ] **Step 1: seed terminus dans `setup-vault-envs.sh`** — après la boucle
  `for E in "${HP_ENVS[@]}"` (le script source déjà `lib/env-chain.sh` pour
  `env_chain_nonprod` ; sinon l'ajouter sur le même motif) :

```bash
# ── LE TERMINUS (G7) : son secret d'admin — JAMAIS de admin-oauth ────────────
# La gateway du terminus est la gateway RÉELLE, attaquée en DIRECT (pas de
# proxy wm-admin-<env> devant elle, exclusion structurelle G4). Défauts alignés
# sur setup-vault.sh (WM_USER/WM_PASS), surchargeables par WM_<TERMINUS>_*.
# On ne seed PAS envs/<terminus>/admin-oauth : il n'existe aucune voie OAuth2
# vers le terminus, et en seeder une laisserait croire le contraire.
TERMINUS="$(env_chain_terminus)" || { echo "✗ CHAINE_ILLISIBLE : terminus indéterminable" >&2; exit 1; }
TU="WM_$(printf %s "$TERMINUS" | tr '[:lower:]' '[:upper:]')_USER"
TP="WM_$(printf %s "$TERMINUS" | tr '[:lower:]' '[:upper:]')_PASS"
U="${!TU:-${WM_USER:-Administrator}}"; P="${!TP:-${WM_PASS:-manage}}"
put "envs/$TERMINUS/wm-admin" "{\"username\":\"$U\",\"password\":\"$P\"}"
```

- [ ] **Step 2: policy operator-deploy dans `setup-vault-userpass.sh`** —
  sourcer la lib en tête (motif de `setup-vault-paliers.sh:31-35`, avec repli
  cwd), calculer `OPERATOR_TERMINUS="$(env_chain_terminus)"` (fail bruyant
  sinon), puis dans le heredoc python de la policy, remplacer la construction
  de `hcl` par :

```python
import json, os, sys
term = os.environ["OPERATOR_TERMINUS"]
hcl = (
    "# Perimetre PLATEFORME de l'operateur de mise en prod - READ SEULE.\n"
    "# /!\\ Donne a un HUMAIN la lecture des secrets de service (jeton du compte\n"
    "# applicatif, mot de passe OpenSearch, creds admin des gateways). L'octroi de\n"
    "# cette policy est une decision de securite du client, pas un defaut technique.\n"
    'path "secret/data/stoa/ci"             { capabilities = ["read"] }\n'
    'path "secret/data/stoa/opensearch"     { capabilities = ["read"] }\n'
    'path "secret/data/stoa/gateways/*"     { capabilities = ["read"] }\n'
    'path "secret/metadata/stoa/gateways/*" { capabilities = ["read", "list"] }\n'
    "# G7 : le secret d'admin du TERMINUS de la chaine (derive de\n"
    "# environments.yaml, jamais un nom en dur) - c'est le ticket d'entree du\n"
    "# palier au sens ADR-082, lu par team-promote.sh §7.b et consomme par le\n"
    "# role Ansible en voie directe.\n"
    'path "secret/data/stoa/envs/%s/wm-admin"     { capabilities = ["read"] }\n' % term
    + 'path "secret/metadata/stoa/envs/%s/wm-admin" { capabilities = ["read"] }\n' % term
)
json.dump({"policy": hcl}, sys.stdout)
```

  (exporter `OPERATOR_TERMINUS` dans l'appel du heredoc :
  `OPERATOR_TERMINUS="$OPERATOR_TERMINUS" python3 - > "$TMP/pol.json" <<'POLICY'`.)

- [ ] **Step 3: shellcheck des deux scripts** + `bash scripts/test-env-chain.sh`
  (aucune régression) — la preuve d'EFFET est live (Task 8 : oscar lit le
  secret du terminus, alice non).

- [ ] **Step 4: Commit** — `feat(g7): ouvrir le terminus est un geste de credential — seed du secret d'admin (dérivé de la chaîne) + read dans operator-deploy, jamais de voie oauth2`

---

### Task 5 : le tableau de bord dit la vérité

**Files:**
- Modify: `scripts/api-promote-request.sh` (corps de PR : flux réel + annonce
  itsmCheck ; lire `env_chain_gate_itsm_check` à la Garde 2)
- Modify: `scripts/team-promote.sh` (§9 : le PORTEUR nommé dans le commentaire
  de succès)
- Test: `scripts/test-team-promote-wiring.sh` (le stub CAPTURE les corps de
  commentaires ; assertion sur le nominal)

**Interfaces:**
- Consumes: `env_chain_gate_itsm_check` (Task 1), `VAULT_IDENTITY_USER`
  (déjà validé §0bis).
- Produces: commentaire de succès portant `demandée par … , mergée par … ,
  portée par …`.

- [ ] **Step 1: §9 de team-promote.sh** — dans le `comment` de SUCCÈS,
  remplacer `— demandée par \`${MK_PROMOTED_BY:-<non nommé>}\`, mergée par
  \`${GITEA_MERGED_BY}\` —` par :

```
— demandée par \`${MK_PROMOTED_BY:-<non nommé>}\`, mergée par \`${GITEA_MERGED_BY}\`, portée par \`${VAULT_IDENTITY_USER}\` —
```

  (Trois identités, trois statuts : demandé / mergé / porté. Le porteur est
  l'identité Vault de la pause — égale au mergeur par MERGER_MISMATCH, mais
  « égal par une garde » doit se LIRE sur la PR.)

- [ ] **Step 2: api-promote-request.sh** — à la Garde 2, après la lecture de
  `DEPLOYER_GROUP`, lire aussi :

```bash
ITSMC=$(env_chain_gate_itsm_check "$TO_ENV") || fail "PARSE_GATE : itsmCheck vers '$TO_ENV'"
ITSM_LINE=""
[ "$ITSMC" != "ITSMCHECK=1" ] || ITSM_LINE="
⚠ La porte de \`${TO_ENV}\` déclare **itsmCheck** : au dispatch (post-merge), le change \`\${CHANGE_REF}\` sera RE-vérifié \`approved\` auprès de l'ITSM — un change révoqué entre demande et merge refuse (\`ITSM_NOT_APPROVED\`, anti-TOCTOU A6)."
```

  (interpoler `${CHANGE_REF}` réellement — retirer l'échappement `\$` dans
  l'implémentation ; il figure ici pour la lisibilité du plan.)
  Puis remplacer le DERNIER paragraphe du corps de PR (celui qui commence par
  `⚠ **Ce merge n'applique rien aujourd'hui.**` — périmé depuis G5) par :

```
**Ce merge DÉCLENCHE l'apply de promotion** (webhook → job \`team-promote\`) :
une pause nominative demandera l'identité du MERGEUR, puis l'import d'archive
(GUID stable, 0-coupure — ADR-079/083) tournera vers \`${TO_ENV}\` et son
résultat sera commenté ICI : pin, digest, moteur, et les trois identités
(demandeur / mergeur / porteur).${ITSM_LINE}
```

- [ ] **Step 3: le stub capture les commentaires** — dans `stub.py`, route
  `issues/` : au lieu de jeter le corps, l'append-er :

```python
        if re.match(r"^/api/v1/repos/[^/]+/[^/]+/issues/", path):
            body = self._body()
            if method != "GET":
                with open(os.environ.get("STUB_COMMENTS", "/dev/null"), "a") as f:
                    f.write(body.decode("utf-8", "replace") + "\n---\n")
            if method == "GET":
                self._send(200, "[]")
            else:
                self._send(201, json.dumps({"id": 1}))
            return
```

  Exporter `STUB_COMMENTS="$TMP/comments.log"` au lancement du stub, et dans
  le cas nominal G7-a (Task 2), après le run :

```bash
grep -q 'portée par `oscar`' "$TMP/comments.log" \
  && ok "G7-a le commentaire de PR nomme le PORTEUR" \
  || bad "G7-a porteur absent du commentaire : $(tail -5 "$TMP/comments.log" 2>/dev/null | tr '\n' ' ')"
```

  (⚠ vider `comments.log` en tête du cas pour que l'assertion porte sur CE run.)

- [ ] **Step 4: Jouer** — wiring 0 FAIL ; `DRY_RUN=1` de
  `api-promote-request.sh` sur un saut int et un saut prod (gardes OK, la
  ligne ITSM n'apparaît que pour prod) ; shellcheck des deux scripts.

- [ ] **Step 5: Commit** — `fix(g7): le tableau de bord dit la vérité — le corps de PR décrit l'apply réel (périmé depuis G5), le commentaire nomme le porteur, l'itsmCheck s'annonce à la demande`

---

### Task 6 : porte hors-ligne intégrale

- [ ] **Step 1:** `bash scripts/test-env-chain.sh` — 0 FAIL.
- [ ] **Step 2:** `bash scripts/test-team-promote-wiring.sh` — 0 FAIL, compte
  total ≥ ancien compte + ~20 (garde de compte du harnais mise à jour si elle
  existe).
- [ ] **Step 3:** `make lint-ci` — intégral vert (8/8 étapes).
- [ ] **Step 4:** Commit éventuel des ajustements —
  `test(g7): porte hors-ligne intégrale verte`

---

### Task 7 : ADR-086 + parcours opérateur

**Files:**
- Create: `adr/adr-086-parcours-demandeur-pr-tableau-de-bord.md`
- Modify: `ENVIRONNEMENTS.md` (nouveau § « Le parcours du demandeur (G7) »,
  après « Revenir en arrière (G6) »)

- [ ] **Step 1: ADR-086** — structure des ADR du dépôt (contexte / décision /
  conséquences / limites nommées). Contenu : D1-D4 de la spec (terminus par
  position ; §6ter ITSM ; tableau de bord vrai ; ouverture terminus = geste de
  credential humain), les refus nommés nouveaux (`TERMINUS_SANS_VOIE`,
  `COMBINAISON_NON_SUPPORTEE` terminus, `ITSM_NOT_CONFIGURED/UNAVAILABLE/
  NOT_APPROVED`, `REF_INVALIDE` au mergé), et les limites HÉRITÉES maintenues
  (approverGroup non enforced au merge ; 4-yeux inerte sans build-user-vars ;
  parité moteurs = G8 ; client OAuth partagé hors-prod).
- [ ] **Step 2: ENVIRONNEMENTS.md § G7** — le pas-à-pas des cinq paliers :
  qui ouvre la PR (formulaire `api-promote-request`), qui merge quoi
  (rec = demandeur ; int = bob/int-team ; homol = carol/release-team + PV ;
  prod = oscar + change approved + PV), qui répond à quelle pause (le mergeur),
  ce que chaque PR porte (plan / résultat+identités / statut build), et la voie
  du terminus (directe, structurelle). Renvoyer à ADR-086.
- [ ] **Step 3: Commit** — `docs(g7): ADR-086 + parcours opérateur — une PR par saut, le formulaire n'a aucune autorité`

---

### Task 8 : live — remise en état, push gitea, gestes d'ouverture

⚠ Phase LIVE : adapter aux mesures (Vault dev en mémoire ⇒ re-seed complet si
restart ; fenêtre keepalive wM ; jobs Jenkins lisent GITEA, pas le clone local).

- [ ] **Step 1: état du lab** — `docker ps` (vault, gitea, jenkins, keycloak,
  openldap, wm-mock-*, itsm-mock, webmethods-real UP) ; sinon remise en état
  (compose + seeds, séquence du jalon userpass).
- [ ] **Step 2: push gitea** — pousser `provision/probe-dev` → `gitea/main`
  (fast-forward attendu depuis `9651903` ; `http.postBuffer` si >1 Mo). Les
  jobs consomment CE dépôt.
- [ ] **Step 3: seeds** — `bash scripts/setup-vault-envs.sh` (le terminus
  apparaît), `bash scripts/setup-vault-userpass.sh` (policy operator-deploy
  étendue) — ou gestes `! bash` si le classifieur bloque. Vérifier :
  oscar (login userpass) lit `envs/prod/wm-admin` (200) ; alice NON (403).
- [ ] **Step 4: ouverture des paliers du parcours** — groupes déployeurs posés
  (`setup-deployer-groups.sh` : bob=int, carol=homol ; oscar=prod vérifié) ;
  rec ouvert au demandeur (même geste qu'au rejeu G5 — grant `apply-rec` à
  l'identité qui portera rec). Mesurer avec
  `scripts/test-deployer-gate-live.sh` si applicable.
- [ ] **Step 5: jobs re-posés** si le XML a changé (aucun changement de
  déclencheur prévu — vérifier seulement que team-promote tourne la nouvelle
  définition : build sur une PR de sonde ou relecture du workspace).

---

### Task 9 : live — LA porte du GOAL, par builds Jenkins

- [ ] **Step 1: publier + exporter** — API du parcours publiée en dev
  (team-publish ou état existant), export par build `api-promote-export`
  (⇒ `EXPORT_CONFIRMED_SUMMARY guid=… sha256=…`), guid pinné dans
  `apis/<api>.promote.yml` du dépôt d'équipe.
- [ ] **Step 2: saut rec** — build `api-promote-request` (FROM=dev TO=rec,
  ARCHIVE_SHA256) ⇒ PR ; merge ; webhook ; pause répondue par le mergeur ⇒
  build team-promote SUCCESS ; PR : corps VRAI + commentaire résultat
  (pin/digest/moteur + demandeur/mergeur/porteur) + statut build ; catalogue
  rec : API active `id==guid`.
- [ ] **Step 3: saut int** — idem, mergée + portée par bob (`apim-apply-int`).
- [ ] **Step 4: saut homol** — idem, PV_REF exigé, carol (`apim-apply-homol`).
- [ ] **Step 5: saut prod** — change ITSM `approved` (POST /changes du mock si
  besoin), CHANGE_REF+PV_REF, mergée + portée par oscar
  (`apim-operator-prod`) ; VOIE DIRECTE (log du build : `apim_ss_auth_mode=
  basic`, base `webmethods-real:5555/rest/apigateway`) ; catalogue du wM réel :
  API active, GUID iso à celui de l'export.
- [ ] **Step 6: relire les QUATRE PRs** — chacune porte les trois couches de
  commentaires ; consigner les numéros de builds et de PRs (ils vont dans
  l'ADR/handoff).

---

### Task 10 : live — contre-épreuves par builds

- [ ] **Step 1: PAYLOAD_PERIME (LA contre-épreuve du GOAL)** — ouvrir une PR
  de promotion et NE PAS la merger ; tirer le webhook à la main
  (`POST /generic-webhook-trigger/invoke?token=stoa-team-publish` avec un
  payload prétendant `action=closed, merged=true` sur cette PR) ⇒ build
  FAILURE, commentaire `PAYLOAD_PERIME`, moteur jamais lancé
  (`grep -c 'PLAY \[' log` = 0), catalogue du palier INCHANGÉ.
- [ ] **Step 2: ITSM_NOT_APPROVED par build** — repasser le change du saut
  prod à `draft` (PUT /changes/<ref>/status du mock), rejouer une promotion
  prod ⇒ FAILURE `ITSM_NOT_APPROVED`, moteur jamais lancé ; repasser
  `approved` ⇒ vert. (Anti-TOCTOU montré, pas raconté.)
- [ ] **Step 3: remise en état** — branches `promote/*` purgées, PRs de sonde
  fermées proprement (piège : PATCH state=open avant merge si la course
  branche a fermé la PR), Vault : aucun grant jetable laissé.

---

### Task 11 : clôture — GOAL, handoff, mémoire

- [ ] **Step 1:** `GOAL-cd-promotion-5-envs-2026-08-26.md` — G7 marqué FAIT
  (builds cités, contre-épreuves, restes nommés).
- [ ] **Step 2:** `HANDOFF-2026-08-27-G7-PARCOURS-DU-DEMANDEUR.md` — état
  du lab en fin de session, pièges mesurés, gestes restants.
- [ ] **Step 3:** mémoire persistante — `g7-parcours-du-demandeur.md` +
  index MEMORY.md + mise à jour `cd-promotion-5-envs.md` (reste G8).
- [ ] **Step 4:** commits + push gitea du lot final.
