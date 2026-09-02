#!/usr/bin/env bash
# scripts/lib/gwt-mirror.sh — LE MIROIR XML / Jenkinsfile d'un déclencheur
# GenericTrigger (plugin generic-webhook-trigger). À SOURCER, jamais exécuté seul.
#
# POURQUOI CETTE LIB EXISTE. Sur un job « Pipeline from SCM », le bloc
# `triggers { GenericTrigger(...) }` du Jenkinsfile et le bloc <triggers> du
# config.xml décrivent le MÊME déclencheur — et c'est le XML qui GAGNE :
# Declarative ne remplace que les déclencheurs qu'il a lui-même posés
# (DeclarativeJobPropertyTrackerAction), un déclencheur venu d'un config.xml
# est préservé tel quel, indéfiniment (mesuré sur le lab le 2026-08-06, re-mesuré
# le 2026-09-02 : un `properties()` scripté le préserve aussi). Une divergence
# entre les deux fichiers est donc SILENCIEUSE : le Jenkinsfile dit une chose,
# le job en fait une autre. Jusqu'à A0, chaque test de câblage re-écrivait sa
# propre comparaison (test-team-publish-wiring.sh §3, test-provision-apply-
# wiring.sh §2) par des greps de présence. Ici : UNE comparaison STRUCTURÉE,
# champ à champ, réutilisable par tous les jobs à webhook.
#
# gwt_mirror_diff <job.xml> <Jenkinsfile>
#   Extrait du XML (ElementTree) le premier GenericTrigger : token,
#   regexpFilterText, regexpFilterExpression, printPostContent,
#   printContributedVariables, et l'ENSEMBLE des couples (key, value).
#   Extrait du Jenkinsfile — VUE CODE, lignes `//` blanchies — le bloc
#   `GenericTrigger( … )` (parenthèses équilibrées) et les mêmes champs
#   (chaînes Groovy en quotes simples, `\\` et `\'` dés-échappés ; booléens nus).
#   stdout, une ligne par verdict :
#     MIROIR_OK token=<t> vars=<n>          rc 0 — miroir exact
#     AUCUN_TRIGGER                          rc 0 — ni l'un ni l'autre n'en déclare
#     DIVERGENCE trigger xml=… jenkinsfile=… rc 2 — un seul des deux en a un
#     DIVERGENCE <champ> xml=… jenkinsfile=… rc 1 — (une ligne par champ divergent)
#   rc 2 aussi si un fichier est illisible (message sur stderr).
#
# Ce qu'elle NE compare PAS, délibérément : <spec> (cron, toujours vide ici),
# silentResponse/overrideQuietPeriod/shouldNotFlattern/allowSeveralTriggersPerBuild
# (défauts du plugin, jamais surchargés dans ce dépôt). Les ajouter le jour où
# un Jenkinsfile les pose.

gwt_mirror_diff(){
  local xml="$1" jf="$2"
  [ -r "$xml" ] || { echo "GWT_MIRROR: XML illisible : $xml" >&2; return 2; }
  [ -r "$jf" ]  || { echo "GWT_MIRROR: Jenkinsfile illisible : $jf" >&2; return 2; }
  python3 - "$xml" "$jf" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

xml_path, jf_path = sys.argv[1], sys.argv[2]
FIELDS = ('token', 'regexpFilterText', 'regexpFilterExpression',
          'printPostContent', 'printContributedVariables')

# ── côté XML ────────────────────────────────────────────────────────────────
root = ET.parse(xml_path).getroot()
gt = next((el for el in root.iter() if el.tag.endswith('GenericTrigger')), None)
xml_side = None
if gt is not None:
    xml_side = {f: (gt.findtext(f) or '') for f in FIELDS}
    # Les booléens absents du XML valent false chez le plugin.
    for b in ('printPostContent', 'printContributedVariables'):
        xml_side[b] = xml_side[b] or 'false'
    gv = gt.find('genericVariables')
    xml_side['vars'] = set()
    if gv is not None:
        for v in gv:
            xml_side['vars'].add((v.findtext('key') or '', v.findtext('value') or ''))

# ── côté Jenkinsfile : vue CODE (un `//` en tête de ligne blanchit la ligne) ─
code = ''.join('\n' if ln.lstrip().startswith('//') else ln
               for ln in open(jf_path, encoding='utf-8'))
jf_side = None
m = re.search(r'GenericTrigger\s*\(', code)
if m:
    i, depth = m.end(), 1
    while i < len(code) and depth:
        depth += {'(': 1, ')': -1}.get(code[i], 0)
        i += 1
    body = code[m.end():i - 1]

    def unq(s):  # chaîne Groovy en quotes SIMPLES : \\ -> \ , \' -> '
        return s.replace("\\\\", "\\").replace("\\'", "'")

    def opt(name, default=''):
        mm = re.search(r"\b%s\s*:\s*(?:'((?:[^'\\]|\\.)*)'|(true|false))" % name, body)
        if not mm:
            return default
        return mm.group(2) if mm.group(2) is not None else unq(mm.group(1))

    jf_side = {f: opt(f) for f in ('token', 'regexpFilterText', 'regexpFilterExpression')}
    jf_side['printPostContent'] = opt('printPostContent', 'false')
    jf_side['printContributedVariables'] = opt('printContributedVariables', 'false')
    jf_side['vars'] = set()
    for kv in re.finditer(r"\[\s*key\s*:\s*'((?:[^'\\]|\\.)*)'\s*,\s*value\s*:\s*'((?:[^'\\]|\\.)*)'\s*\]", body):
        jf_side['vars'].add((unq(kv.group(1)), unq(kv.group(2))))

# ── verdict ─────────────────────────────────────────────────────────────────
if xml_side is None and jf_side is None:
    print("AUCUN_TRIGGER"); sys.exit(0)
if (xml_side is None) != (jf_side is None):
    print("DIVERGENCE trigger xml=%s jenkinsfile=%s" % (
        'present' if xml_side else 'absent', 'present' if jf_side else 'absent'))
    sys.exit(2)
rc = 0
for f in FIELDS:
    if xml_side[f] != jf_side[f]:
        print("DIVERGENCE %s xml=%r jenkinsfile=%r" % (f, xml_side[f], jf_side[f])); rc = 1
only_xml = sorted(xml_side['vars'] - jf_side['vars'])
only_jf = sorted(jf_side['vars'] - xml_side['vars'])
if only_xml or only_jf:
    print("DIVERGENCE vars xml_seulement=%r jenkinsfile_seulement=%r" % (only_xml, only_jf)); rc = 1
if rc == 0:
    print("MIROIR_OK token=%s vars=%d" % (xml_side['token'], len(xml_side['vars'])))
sys.exit(rc)
PY
}
