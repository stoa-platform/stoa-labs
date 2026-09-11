#!/usr/bin/env bash
# test-debug-knob-wiring.sh — preuve X/X du CÂBLAGE de la case DEBUG (L4).
# Analyse statique : ni Jenkins, ni forge, aucun effet de bord.
#
# ── POURQUOI CE FICHIER EXISTE ───────────────────────────────────────────────
# Le mode debug sans fuite (L2, ci/lib/dbg.sh) ne parle que si STOA_DEBUG est
# posée. Deux formulaires la posaient déjà par une case DEBUG (publish-api,
# selfservice, commit 33d8f36) ; les autres restaient aveugles. L4 pose la MÊME
# case, au MÊME rang, avec le MÊME libellé et le MÊME pont sur les huit
# formulaires de lancement restants, et la globale STOA_DEBUG comme plancher.
#
# Ce que cette suite épingle, et pourquoi :
#   - la case est déclarée LÀ où le formulaire vit (bloc parameters{} déclaratif,
#     parameters([...]) d'un properties() scripté, ou XML seul pour api-request
#     dont le Jenkinsfile refuse tout parameters{}) — jamais des deux côtés
#     sauf quand le XML est un MIROIR (et là, au même rang : le XML GAGNE) ;
#   - le rang : juste AVANT le premier paramètre d'identité (VAULT_USER,
#     FORGE_TOKEN…), en dernier sinon — le gabarit de publish-api:36 ;
#   - le pont `if [ "${DEBUG:-false}" = "true" ]; then export STOA_DEBUG=1; fi`
#     dans CHAQUE bloc sh qui appelle un script sourçant dbg.sh, APRÈS `set +x`
#     quand il existe, en `if/fi` : la forme du plan SANS défaut (`[ "$DEBUG" =
#     true ] && export`) meurt sous `set -u` dès que DEBUG n'est pas
#     matérialisée (premier build d'un job properties()), et une liste `&&`
#     qui TERMINE un bloc rend 1 sous sh -e (mesuré 2026-09-11) ;
#   - le pont n'ÉTEINT jamais : décocher la case ne retire pas la globale ;
#   - DEBUG ne traverse aucun withEnv (le canal natif suffit, en déclaratif
#     comme en properties()) ;
#   - les exclusions sont EXPLICITES (pauses input{}, webhook-only, carto) ;
#   - la globale est CONNUE et OPTIONNELLE dans setup-jenkins-globals.sh ;
#   - les quatre scripts moteur qui appellent ansible-playbook relaient
#     `-e stoa_debug="$(dbg_bool)"` (le pipeline route, le moteur parle).
# Chaque prédicat est rejoué sur un MUTANT (§6) : une porte qui ne rougit pas
# sur la faute qu'elle prétend attraper ne mesure rien.
#
#   ./scripts/test-debug-knob-wiring.sh
# shellcheck disable=SC2015,SC2016
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 2
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Total ATTENDU, ÉCRIT EN DUR (même régime que les autres suites de câblage).
EXPECTED_CHECKS=69

BRIDGE='if [ "${DEBUG:-false}" = "true" ]; then export STOA_DEBUG=1; fi'
DESC_FR='Trace détaillée (appels, codes HTTP, erreurs redactées) — aucun secret exposé.'
GLOBALS=scripts/setup-jenkins-globals.sh

# ── LA TABLE : job | régime | paramètre qui SUIT la case (END = dernière) | ancres des blocs sh porteurs du pont
TABLE="api-promote-export|declarative|VAULT_USER|bash scripts/api-promote-export.sh
api-promote-request|declarative|END|bash scripts/api-promote-request.sh
api-request|xml-only|END|bash scripts/api-request.sh
app-request|properties|FORGE_TOKEN|bash scripts/app-request-choices.sh;bash scripts/provision-request.sh
app-rollback|properties|FORGE_TOKEN|bash scripts/app-rollback-request.sh
team-request|declarative|END|bash scripts/team-request.sh
prod|declarative|VAULT_USER|. ci/lib/vault-login.sh
rollback|declarative|VAULT_USER|. ci/lib/vault-login.sh"

# ── la sonde (python) : vue CODE du Jenkinsfile, formulaire, XML, blocs sh ──
cat > "$TMP/probe.py" <<'PY'
import re, sys, xml.etree.ElementTree as T
BRIDGE = 'if [ "${DEBUG:-false}" = "true" ]; then export STOA_DEBUG=1; fi'
def code(path):
    # commentaires PLEINE LIGNE seulement (comme nc_groovy des suites soeurs)
    out = []
    for l in open(path, encoding='utf-8'):
        s = l.rstrip('\n')
        if re.match(r'^\s*(//|#)', s): s = ''
        out.append(s)
    return out
def jf_params(lines):
    """[(name, type, desc)] du formulaire de niveau job, dans l'ordre. None si aucun."""
    start = None; mode = None
    for i, l in enumerate(lines):
        if re.match(r'^\s*parameters\s*\{\s*$', l): start, mode = i, 'decl'; break
        if 'properties([parameters([' in l: start, mode = i, 'props'; break
    if start is None: return None
    indent = len(lines[start]) - len(lines[start].lstrip())
    res = []; i = start + 1
    while i < len(lines):
        l = lines[i]
        if mode == 'decl' and re.match(r'^\s*\}\s*$', l) and (len(l) - len(l.lstrip())) == indent: break
        if mode == 'props' and re.match(r'^\s*\]\)\]\)', l): break
        m = re.match(r"^\s*(string|choice|booleanParam|password|text)\(name: '([A-Z_0-9]+)'", l)
        if m:
            desc = ''; dflt = ''
            for j in range(i, min(i + 4, len(lines))):
                d = re.search(r'description: "([^"]*)"', lines[j])
                if d and not desc: desc = d.group(1)
                f = re.search(r'defaultValue:\s*(true|false)\b', lines[j])
                if f and not dflt: dflt = f.group(1)
                if desc and (dflt or m.group(1) != 'booleanParam'): break
            res.append((m.group(2), m.group(1), desc, dflt))
        i += 1
    return res
def xml_params(path):
    r = T.parse(path).getroot()
    res = []
    for p in r.iter():
        if p.tag.startswith('hudson.model.') and p.tag.endswith('ParameterDefinition'):
            res.append((p.findtext('name') or '', p.tag.split('.')[-1].replace('ParameterDefinition', ''),
                        (p.findtext('description') or ''), (p.findtext('defaultValue') or '')))
    return res
def sh_blocks(lines):
    """[(start, end)] des blocs sh (''' multi-lignes ou une ligne), indices 0-based inclusifs."""
    blocks = []; i = 0
    while i < len(lines):
        l = lines[i]
        if re.match(r"^\s*sh(\s+label:[^,]+,)?\s*'''", l):
            j = i + 1
            while j < len(lines) and "'''" not in lines[j]: j += 1
            blocks.append((i, j)); i = j + 1; continue
        if re.match(r"^\s*sh(\s+label:[^,]+,)?\s*'", l):
            blocks.append((i, i))
        i += 1
    return blocks
def bridge_verdict(lines, anchors):
    """OK ou KO: … — chaque bloc sh portant une ancre porte le pont, après set +x, avant l'ancre ; aucun pont ailleurs."""
    blocks = sh_blocks(lines); need = []; problems = []
    for (a, b) in blocks:
        body = lines[a:b + 1]
        if any(anc in l for l in body for anc in anchors): need.append((a, b))
    if not need: return 'KO: aucun bloc sh ne porte une ancre (%s)' % ', '.join(anchors)
    total_bridges = sum(l.count(BRIDGE) for l in lines)
    if total_bridges != len(need):
        problems.append('%d pont(s) dans le fichier pour %d bloc(s) porteur(s)' % (total_bridges, len(need)))
    for (a, b) in need:
        body = lines[a:b + 1]
        def pos(pred):
            for k, l in enumerate(body):
                idx = l.find(pred)
                if idx >= 0: return (k, idx)
            return None
        pb = pos(BRIDGE); px = pos('set +x')
        pa = None
        for anc in anchors:
            p = pos(anc)
            if p and (pa is None or p < pa): pa = p
        if pb is None: problems.append('bloc l.%d sans pont' % (a + 1)); continue
        if px is not None and not (px < pb): problems.append('bloc l.%d : pont AVANT set +x' % (a + 1))
        if pa is not None and not (pb < pa): problems.append('bloc l.%d : pont APRÈS le script' % (a + 1))
    return 'OK' if not problems else 'KO: ' + ' ; '.join(problems)
cmd = sys.argv[1]
if cmd == 'jf-params':
    p = jf_params(code(sys.argv[2]))
    print('NONE' if p is None else '\n'.join('%s|%s|%s|%s' % t for t in p))
elif cmd == 'xml-params':
    print('\n'.join('%s|%s|%s|%s' % t for t in xml_params(sys.argv[2])))
elif cmd == 'bridge':
    print(bridge_verdict(code(sys.argv[2]), sys.argv[3].split(';')))
elif cmd == 'count-bridge':
    print(sum(l.count(BRIDGE) for l in code(sys.argv[2])))
elif cmd == 'form':
    lines = code(sys.argv[2]); problems = []
    # (a) toute ligne de CODE qui touche STOA_DEBUG est exactement le pont : pas
    #     d'extinction (STOA_DEBUG= vide/0/false, unset), pas de second canal
    #     (environment{}, env.STOA_DEBUG, withEnv), pas de forme `&& export`.
    #     Compté par OCCURRENCE, pas par ligne : `…; fi; export STOA_DEBUG=false`
    #     sur la ligne du pont est une extinction, la ligne contient pourtant le pont.
    for i, l in enumerate(lines):
        if l.count('STOA_DEBUG') != l.count(BRIDGE):
            problems.append('l.%d touche STOA_DEBUG hors du pont : %s' % (i + 1, l.strip()[:80]))
    # (b) aucun withEnv([...]) — sur toutes ses lignes jusqu'au `])` — ne porte (STOA_)DEBUG=
    i = 0
    while i < len(lines):
        if 'withEnv(' in lines[i]:
            j = i
            while j < len(lines) and '])' not in lines[j] and ']' not in lines[j].split('withEnv(')[-1][1:]: j += 1
            blk = ' '.join(lines[i:j + 1])
            if re.search(r'"(STOA_)?DEBUG=', blk): problems.append('withEnv l.%d porte DEBUG — le canal natif suffit' % (i + 1))
            i = j
        i += 1
    print('OK' if not problems else 'KO: ' + ' ; '.join(problems))
PY
probe(){ python3 "$TMP/probe.py" "$@"; }

# ── prédicats (rejoués sur mutant au §6) ────────────────────────────────────
# rank_verdict <liste "NOM|TYPE|DESC" (une par ligne)> <suivant>
rank_verdict(){
  local list="$1" nxt="$2" names after
  names=$(printf '%s\n' "$list" | cut -d'|' -f1 | tr '\n' ' ')
  case " $names " in *" DEBUG "*) ;; *) echo "KO: DEBUG absent du formulaire ($names)"; return 0;; esac
  [ "$(printf '%s\n' "$list" | grep -c '^DEBUG|')" = 1 ] || { echo "KO: DEBUG déclaré plusieurs fois"; return 0; }
  # getline rend 0 en fin de liste : DEBUG en dernier ⇒ END (un getline nu laisserait $0 = "DEBUG")
  after=$(printf '%s\n' "$list" | cut -d'|' -f1 | awk '$0=="DEBUG"{ if ((getline nxt) > 0) print nxt; else print "END"; exit }')
  [ "$after" = "$nxt" ] && echo "OK" || echo "KO: DEBUG est suivi de '$after' (attendu '$nxt') — rang : $names"
}
# desc_verdict <liste> : le libellé du gabarit, mot pour mot
desc_verdict(){
  local d; d=$(printf '%s\n' "$1" | awk -F'|' '$1=="DEBUG"{print $3; exit}')
  [ "$d" = "$DESC_FR" ] && echo "OK" || echo "KO: libellé '$d'"
}
# mirror_verdict <régime> <jf-liste|NONE> <xml-liste|NOXML>
mirror_verdict(){
  local regime="$1" jf="$2" xml="$3" jn xn dbg
  case "$regime" in
    declarative)
      [ "$xml" = NOXML ] && { echo "OK"; return 0; }              # prod / rollback : pas de XML, rien à refléter
      jn=$(printf '%s\n' "$jf" | cut -d'|' -f1 | tr '\n' ' '); xn=$(printf '%s\n' "$xml" | cut -d'|' -f1 | tr '\n' ' ')
      [ "$jn" = "$xn" ] || { echo "KO: XML [$xn] ≠ Jenkinsfile [$jn] (le XML gagne, la divergence serait silencieuse)"; return 0; }
      dbg=$(printf '%s\n' "$xml" | awk -F'|' '$1=="DEBUG"{print $2":"$4":"$3; exit}')
      case "$dbg" in "Boolean:false:$DESC_FR") echo "OK";; *) echo "KO: DEBUG dans le XML = '$dbg' (attendu Boolean, défaut false, libellé du gabarit)";; esac ;;
    xml-only)
      [ "$jf" = NONE ] || { echo "KO: le Jenkinsfile porte un formulaire alors que le XML seul doit le décrire"; return 0; }
      dbg=$(printf '%s\n' "$xml" | awk -F'|' '$1=="DEBUG"{print $2":"$4":"$3; exit}')
      case "$dbg" in "Boolean:false:$DESC_FR") echo "OK";; *) echo "KO: DEBUG dans le XML = '$dbg'";; esac ;;
    properties)
      [ -z "$xml" ] || [ "$xml" = NOXML ] && echo "OK" || echo "KO: le XML déclare des paramètres [$xml] — en properties() le XML doit rester VIDE (fait 6)" ;;
  esac
}
# form_verdict <jenkinsfile> : sur la vue CODE, toute ligne qui touche STOA_DEBUG est LE pont
# (donc ni extinction, ni `&& export`, ni environment{}/env.), et aucun withEnv ne porte DEBUG.
form_verdict(){ probe form "$1"; }
# decl_verdict <liste> : la case est déclarée UNE fois, booléenne, défaut false (l'opt-in)
decl_verdict(){
  local n; n=$(printf '%s\n' "$1" | grep -c '^DEBUG|')
  [ "$n" = 1 ] || { echo "KO: DEBUG déclaré ×$n"; return 0; }
  printf '%s\n' "$1" | grep -qE '^DEBUG\|(booleanParam|Boolean)\|[^|]*\|false$' && echo "OK" || echo "KO: DEBUG n'est pas un booléen à défaut false ($(printf '%s\n' "$1" | grep '^DEBUG|'))"
}

echo "== 1. les huit formulaires : case, libellé, rang, miroir, pont, forme =="
while IFS='|' read -r JOB REGIME NEXT ANCHORS; do
  JF="ci/Jenkinsfile.$JOB"; XMLF="ci/jenkins/$JOB.job.xml"
  [ -f "$JF" ] || { for _ in 1 2 3 4 5 6; do ko "$JOB : Jenkinsfile absent"; done; continue; }
  JFP=$(probe jf-params "$JF")
  if [ -f "$XMLF" ]; then XMLP=$(probe xml-params "$XMLF"); else XMLP=NOXML; fi
  # 1.1 la case, là où le formulaire vit
  case "$REGIME" in
    xml-only) N_JF=$(grep -cE "booleanParam\(name: 'DEBUG'" "$JF"); V=$(decl_verdict "$XMLP")
      [ "$N_JF" = 0 ] && [ "$V" = OK ] && ok "$JOB : la case vit dans le XML seul (BooleanParameterDefinition DEBUG ×1, défaut false, Jenkinsfile sans parameters{})" || ko "$JOB : case DEBUG — Jenkinsfile ×$N_JF, XML : $V" ;;
    *) V=$(decl_verdict "$JFP")
      [ "$V" = OK ] && ok "$JOB : booleanParam DEBUG déclaré une fois, défaut false (opt-in), dans le formulaire ($REGIME)" || ko "$JOB : $V ($REGIME)" ;;
  esac
  # 1.2 libellé
  if [ "$REGIME" = xml-only ]; then V=$(desc_verdict "$XMLP"); else V=$(desc_verdict "$JFP"); fi
  [ "$V" = OK ] && ok "$JOB : libellé du gabarit, mot pour mot" || ko "$JOB : $V"
  # 1.3 rang
  if [ "$REGIME" = xml-only ]; then V=$(rank_verdict "$XMLP" "$NEXT"); else V=$(rank_verdict "$JFP" "$NEXT"); fi
  [ "$V" = OK ] && ok "$JOB : DEBUG juste avant ${NEXT/END/la fin du formulaire}" || ko "$JOB : $V"
  # 1.4 miroir
  V=$(mirror_verdict "$REGIME" "$JFP" "$XMLP")
  [ "$V" = OK ] && ok "$JOB : miroir XML cohérent ($REGIME)" || ko "$JOB : $V"
  # 1.5 pont
  V=$(probe bridge "$JF" "$ANCHORS")
  [ "$V" = OK ] && ok "$JOB : le pont \`$BRIDGE\` est dans chaque bloc sh porteur (${ANCHORS//;/, }), après set +x, avant le script, et nulle part ailleurs" || ko "$JOB : $V"
  # 1.6 forme
  V=$(form_verdict "$JF")
  [ "$V" = OK ] && ok "$JOB : forme if/fi, jamais d'extinction, DEBUG hors de tout withEnv" || ko "$JOB : $V"
done <<< "$TABLE"

echo
echo "== 2. les exclusions sont explicites =="
OFF=""; for J in team-apply team-publish team-promote provision-apply provision-plan provisioning-request; do grep -qE "booleanParam\(name: 'DEBUG'" "ci/Jenkinsfile.$J" && OFF="$OFF $J"; done
grep -qE "booleanParam\(name: 'DEBUG'" ci/Jenkinsfile && OFF="$OFF stoa-ci"
[ -z "$OFF" ] && ok "aucune case DEBUG sur les pauses input{} ni les jobs webhook-only : la globale seule les couvre" || ko "case DEBUG posée hors périmètre :$OFF"
grep -qE "booleanParam\(name: 'DEBUG'" ci/Jenkinsfile.carto && ko "carto porte une case DEBUG — régime XML porteur + properties() jamais mesuré, aucun script carto ne parle : dette nommée, pas une case" \
  || ok "carto sans case DEBUG (exclusion nommée : régime non mesuré, aucun consommateur de STOA_DEBUG)"

echo
echo "== 3. la globale STOA_DEBUG est CONNUE et OPTIONNELLE =="
CONNUES=$(awk '/^CONNUES="/{f=1;next} f&&/^"/{exit} f' "$GLOBALS" | tr '\n' ' ')
case " $CONNUES " in *" STOA_DEBUG "*) ok "STOA_DEBUG dans CONNUES (--from-env la prend)";; *) ko "STOA_DEBUG absente de CONNUES";; esac
OPT=$(grep -E '^OPTIONNELLES=' "$GLOBALS" | sed 's/^OPTIONNELLES="//;s/"$//')
case " $OPT " in *" STOA_DEBUG "*) ok "STOA_DEBUG dans OPTIONNELLES (absente = état normal, la chaîne se tait)";; *) ko "STOA_DEBUG absente d'OPTIONNELLES";; esac
awk '/^set -euo pipefail/{exit} {print}' "$GLOBALS" | grep -q 'STOA_DEBUG' && ok "l'en-tête documente STOA_DEBUG (comme GIT_BASE et WEBHOOK_KIND)" || ko "l'en-tête ne documente pas STOA_DEBUG"
bash "$GLOBALS" --help 2>&1 | grep -q 'STOA_DEBUG' && ok "--help nomme STOA_DEBUG (le seul endroit qu'un intégrateur lit avant de poser)" || ko "--help ne nomme pas STOA_DEBUG"

echo
echo "== 4. le moteur relaie -e stoa_debug depuis dbg_bool =="
# dbg_bool (ci/lib/dbg.sh) rend le mot que lit Ansible : true si dbg_on, false sinon.
DB=$( ( . ci/lib/dbg.sh 2>/dev/null; printf '%s/%s/%s/%s' "$(STOA_DEBUG=1 dbg_bool)" "$(STOA_DEBUG=true dbg_bool)" "$(STOA_DEBUG='' dbg_bool)" "$(STOA_DEBUG=0 dbg_bool)" ) 2>/dev/null )
[ "$DB" = "true/true/false/false" ] && ok "dbg_bool rend true/true/false/false pour STOA_DEBUG=1/true/vide/0 (le mot qu'Ansible lit dans stoa_debug)" || ko "dbg_bool : '$DB' (attendu true/true/false/false)"
for S in api-promote-export team-apply team-publish team-promote; do
  F="scripts/$S.sh"; NA=$(grep -cE '^\s*\(?\s*ansible-playbook ' "$F"); NR=$(grep -cF -- '-e stoa_debug="$(dbg_bool)"' "$F")
  [ "$NA" -ge 1 ] && [ "$NA" = "$NR" ] && ok "$S.sh : $NA appel(s) ansible-playbook, $NR relais -e stoa_debug=\"\$(dbg_bool)\"" || ko "$S.sh : ansible-playbook ×$NA, relais ×$NR"
done
MISS=""; for S in api-promote-export team-apply team-publish team-promote; do grep -qE '^\s*\.\s.*lib/git-base\.sh|^\s*\.\s.*ci/lib/dbg\.sh|^\s*\. "\$_[A-Z_]+"' "scripts/$S.sh" || MISS="$MISS $S"; done
DB_TYPE=$( ( . scripts/lib/git-base.sh >/dev/null 2>&1; type dbg_bool 2>/dev/null | head -1 ) )
case "$DB_TYPE" in *"dbg_bool is a"*function*) [ -z "$MISS" ] && ok "dbg_bool est disponible dans les quatre : sourcer git-base.sh définit dbg_bool (mesuré : $DB_TYPE)" || ko "un script ne source pas git-base.sh :$MISS";; *) ko "sourcer git-base.sh ne définit pas dbg_bool ($DB_TYPE)";; esac

echo
echo "== 5. lint-ci joue cette suite et les trois suites de câblage orphelines =="
grep -qE '^\s*@?bash scripts/test-debug-knob-wiring\.sh' Makefile && ok "make lint-ci joue test-debug-knob-wiring.sh" || ko "test-debug-knob-wiring.sh absent de lint-ci — une suite hors porte ne mesure rien"
MISSM=""; for S in test-app-request-wiring test-api-request-wiring test-team-apply-wiring; do grep -qE "^\s*@?bash scripts/$S\.sh" Makefile || MISSM="$MISSM $S"; done
[ -z "$MISSM" ] && ok "les trois suites de câblage orphelines sont sous lint-ci (L4 réécrit leurs ancres)" || ko "hors lint-ci :$MISSM"

echo
echo "== 6. mutants : chaque prédicat rougit sur la faute qu'il nomme =="
JF0=ci/Jenkinsfile.api-promote-export
# M1 pont en && : form_verdict doit KO
sed 's/if \[ "${DEBUG:-false}" = "true" \]; then export STOA_DEBUG=1; fi/[ "${DEBUG:-false}" = "true" ] \&\& export STOA_DEBUG=1/' "$JF0" > "$TMP/m1"
[ "$(form_verdict "$TMP/m1")" != OK ] && [ "$(probe count-bridge "$TMP/m1")" = 0 ] && ok "M1 pont réécrit en '&& export' ⇒ forme KO et pont non reconnu" || ko "M1 le mutant '&&' passe"
# M2 pont AVANT set +x : bridge_verdict doit KO
python3 - "$JF0" "$TMP/m2" <<'PY'
import sys
B='if [ "${DEBUG:-false}" = "true" ]; then export STOA_DEBUG=1; fi'
L=open(sys.argv[1],encoding='utf-8').read().split('\n'); out=[]
for l in L:
    if B in l: continue
    if l.strip()=='set +x' and not any(B in x for x in out):
        out.append(l.replace('set +x', B)); out.append(l); continue
    out.append(l)
open(sys.argv[2],'w',encoding='utf-8').write('\n'.join(out))
PY
[ "$(probe bridge "$TMP/m2" 'bash scripts/api-promote-export.sh')" != OK ] && ok "M2 pont déplacé AVANT set +x ⇒ KO" || ko "M2 le mutant 'pont avant set +x' passe"
# M3 DEBUG déplacé APRÈS VAULT_USER : rank_verdict doit KO
python3 - "$JF0" "$TMP/m3" <<'PY'
import sys,re
L=open(sys.argv[1],encoding='utf-8').read().split('\n')
i=[k for k,l in enumerate(L) if "booleanParam(name: 'DEBUG'" in l]
if i:
    i=i[0]; blk=L[i:i+2]; del L[i:i+2]
    j=[k for k,l in enumerate(L) if "name: 'VAULT_USER'" in l][0]
    k=j+1
    while not re.search(r'description: "', L[k]): k+=1
    L[k+1:k+1]=blk
open(sys.argv[2],'w',encoding='utf-8').write('\n'.join(L))
PY
[ "$(rank_verdict "$(probe jf-params "$TMP/m3")" VAULT_USER)" != OK ] && ok "M3 DEBUG déplacé après VAULT_USER ⇒ rang KO" || ko "M3 le mutant de rang passe"
# M4 XML miroir sans DEBUG : mirror_verdict doit KO
sed '/<hudson.model.BooleanParameterDefinition>/,/<\/hudson.model.BooleanParameterDefinition>/d' ci/jenkins/team-request.job.xml > "$TMP/m4.xml"
[ "$(mirror_verdict declarative "$(probe jf-params ci/Jenkinsfile.team-request)" "$(probe xml-params "$TMP/m4.xml")")" != OK ] && ok "M4 XML miroir amputé de DEBUG ⇒ miroir KO (le XML gagne, la case disparaîtrait en silence)" || ko "M4 le mutant de miroir passe"
# M5 DEBUG glissé dans le withEnv de team-request : form_verdict doit KO
sed 's/withEnv(\["TEAM=${params.TEAM}", /withEnv(["DEBUG=${params.DEBUG ?: false}", "TEAM=${params.TEAM}", /' ci/Jenkinsfile.team-request > "$TMP/m5"
grep -q '"DEBUG=${params.DEBUG' "$TMP/m5" && [ "$(form_verdict "$TMP/m5")" != OK ] && ok "M5 DEBUG glissé dans un withEnv ⇒ forme KO (second canal)" || ko "M5 le mutant withEnv passe (ou n'a pas pris)"
# M6 extinction après le pont : form_verdict doit KO
sed 's/then export STOA_DEBUG=1; fi$/then export STOA_DEBUG=1; fi; export STOA_DEBUG=false/' "$JF0" > "$TMP/m6"
grep -q 'export STOA_DEBUG=false' "$TMP/m6" && [ "$(form_verdict "$TMP/m6")" != OK ] && ok "M6 'export STOA_DEBUG=false' après le pont ⇒ forme KO (extinction : la globale serait retirée)" || ko "M6 le mutant d'extinction passe"
# M7 defaultValue: true sur prod : decl_verdict doit KO (l'opt-in)
sed "s/booleanParam(name: 'DEBUG', defaultValue: false,/booleanParam(name: 'DEBUG', defaultValue: true,/" ci/Jenkinsfile.prod > "$TMP/m7"
grep -q "defaultValue: true," "$TMP/m7" && [ "$(decl_verdict "$(probe jf-params "$TMP/m7")")" != OK ] && ok "M7 defaultValue: true ⇒ déclaration KO (la case doit rester un opt-in)" || ko "M7 le mutant de défaut passe"

echo
echo "== 7. total attendu =="
TOTAL=$((PASS+FAIL))
[ "$TOTAL" -eq "$EXPECTED_CHECKS" ] && ok "nombre de contrôles exécutés = $EXPECTED_CHECKS (aucune section sautée en silence)" || ko "nombre de contrôles exécutés = $TOTAL, attendu $EXPECTED_CHECKS — une section a été ajoutée/retirée sans mettre le total à jour"
echo
echo "RÉSULTAT : $PASS/$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
