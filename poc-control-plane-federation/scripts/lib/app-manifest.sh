#!/usr/bin/env bash
# scripts/lib/app-manifest.sh — le manifeste d'application MULTI-PALIER (A1,
# GOAL-cd-applications-2026-09-02) : lecture, contrat figé, fusion d'un palier.
#
# POURQUOI CE FICHIER EXISTE : jusqu'au 2026-09-02, provision-request.sh
# RÉÉCRIVAIT le manifeste `<app>.ansible.yml` en entier à chaque demande. Une
# demande `rec` effaçait donc ce que la demande `dev` avait posé, et le
# `client_id` d'une app `idp` vivait à la racine — trans-palier de fait, alors
# que l'identité d'une application est PAR PALIER (client_id `<app>-<env>`,
# certificat, plage IP, clé backend). Le rôle Ansible, lui, sait depuis ADR-078
# fusionner racine ⊕ per_env[env] (tasks/resolve-env.yml) et lire `claim.value`
# sous per_env (tasks/consumer-auth.yml:61). Le manque était dans le script de
# demande, pas dans le rôle.
#
# QUATRE FONCTIONS, chacune un `python3 - <<'PY'` (PyYAML est présent dans le
# conteneur Jenkins comme sur le poste — env-chain.sh en dépend déjà) :
#
#   app_manifest_read <fichier>
#       Imprime, une par ligne : MAN_API=… MAN_API_VER=… MAN_AUDIENCE=…
#       MAN_MODE=… MAN_TEAM=… MAN_ENVS=<paliers déclarés, ordre du fichier>.
#       rc 2 + `REFUS: MANIFESTE_LEGACY …` pour la forme d'avant A1 (claim.value
#       à la racine d'une app idp) — on ne DEVINE pas le palier d'une valeur ;
#       rc 2 + `REFUS: MANIFESTE_INVALIDE …` si le YAML est illisible ou sans
#       `apim_ss_app`.
#
#   app_manifest_check_contract <fichier> <name> <api> <api_version> <audience> <mode> <team>
#       Les champs TRANS-PALIERS sont figés à la première demande : TOUTE
#       divergence est listée (pas seulement la première), rc 2 +
#       `REFUS: CONTRAT_DIVERGENT : <champ> : manifeste='…' demande='…' ; …`.
#       Changer d'API consommée est une NOUVELLE application, pas une promotion
#       (spike S1-T4 : `PUT …/apis` REMPLACE la liste — « une application = une
#       API » est ce qui empêche une convergence de désinscrire en silence).
#       `team` : '' des deux côtés = égal ; l'HÉRITAGE d'une team absente de la
#       demande est l'affaire de l'appelant (provision-request.sh), pas de la lib.
#
#   app_manifest_merge_env <fichier> <env> '<mapping YAML flow, accolades incluses>'
#       Réécrit le fichier EN PLACE en ne touchant QUE la ligne `    <env>: …`
#       du bloc `  per_env:` (plus, au besoin, le newline final manquant du
#       fichier) : remplacée si elle existe, insérée en fin de bloc sinon ;
#       `per_env: {}` converti en bloc ; bloc créé en fin du mapping
#       `apim_ss_app` s'il est absent. FUSION TEXTUELLE,
#       jamais une re-sérialisation YAML : un `yaml.dump` perdrait commentaires,
#       ordre, guillemets et style flow — la contre-épreuve « aucun octet hors
#       de per_env.<env> » serait violée par construction.
#       AUTO-VÉRIFICATION fail-closed : le résultat est rechargé et
#       `apim_ss_app.per_env[<env>]` doit être ÉGAL au mapping demandé — sinon
#       rc 2 + MANIFESTE_INVALIDE et le fichier n'est PAS écrit (c'est aussi ce
#       qui refuse un palier écrit en style block à la main : le remplacer par
#       une ligne flow laisserait ses sous-lignes orphelines).
#
#   app_manifest_digest_env <fichier> <env>                         (A2)
#       Imprime `sha256:<hex>` du JSON canonique du MANIFESTE EFFECTIF du palier
#       (racine ⊕ per_env.<env>, la fusion du rôle) — la référence « qu'est-ce
#       qui tourne en <env> » que provision-apply pose sur la PR à côté du SHA
#       mergé. Détail et refus en tête de la fonction.
#
# CONVENTIONS : les fonctions ÉCRIVENT leur refus sur stderr et RENDENT 2
# (jamais `exit` : la lib est sourcée). L'appelant tourne sans `set -e`
# (délibéré dans provision-request.sh) : il DOIT tester le code de retour
# explicitement — `app_manifest_… || fail …` — et ne jamais appeler ces
# fonctions dans un `$( )` dont il ignorerait le rc.
#
# CHARGEUR YAML SANS TYPAGE IMPLICITE (`yaml.BaseLoader`), partout. Mesuré à
# la critique de la spec (2026-09-02) : avec `safe_load`, un manifeste édité à
# la main portant `api_version: 1.10` NON quoté se relit `1.1` (float) — la
# comparaison au contrat (`1.10` fourni) refusait alors une demande exacte
# (CONTRAT_DIVERGENT mensonger). BaseLoader rend chaque scalaire tel qu'écrit
# (`1.10` reste `1.10`, `true` reste `true`) : c'est ce qu'il faut pour
# comparer des identifiants et pour vérifier qu'une ligne relue est bien celle
# qu'on a écrite. Contrepartie assumée : pas de typage du tout — la lib ne
# consomme que des chaînes et des mappings.
#
# Compatible bash 3.2 (macOS, où tournent les suites) : pas de tableau
# associatif, pas de `${var,,}`.

# Classe sûre d'une clé de palier — la MÊME que celle que provision-request.sh
# impose à REQ_ENV (`[A-Za-z0-9._-]`) : la lib ne fait pas confiance à
# l'appelant pour ça, une clé contenant `:` ou une espace écrirait une ligne
# YAML qui n'est plus la sienne.
_app_manifest_env_ok() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*) return 1;;
  esac
  return 0
}

app_manifest_read() {
  local f="${1:?app_manifest_read <fichier>}"
  [ -r "$f" ] || { echo "REFUS: MANIFESTE_INVALIDE : $f illisible" >&2; return 2; }
  python3 - "$f" <<'PY'
import sys, yaml
path = sys.argv[1]
def refuse(tag, msg):
    sys.stderr.write("REFUS: %s : %s\n" % (tag, msg)); sys.exit(2)
try:
    doc = yaml.load(open(path, encoding="utf-8"), Loader=yaml.BaseLoader)
except Exception as e:  # YAML cassé = manifeste inexploitable, on ne devine rien
    refuse("MANIFESTE_INVALIDE", "%s : YAML illisible (%s)" % (path, str(e).splitlines()[0] if str(e) else e.__class__.__name__))
app = (doc or {}).get("apim_ss_app") if isinstance(doc, dict) else None
if not isinstance(app, dict):
    refuse("MANIFESTE_INVALIDE", "%s : clé racine apim_ss_app absente ou non-mapping" % path)
auth = app.get("auth") if isinstance(app.get("auth"), dict) else {}
mode = str(auth.get("mode") or "idp")
FROZEN_ROOT = ("name", "api", "api_version", "team", "description", "enforce", "contact_emails")
FROZEN_AUTH = ("mode", "audience", "server_alias")
def _per_env_frozen_keys(entry):
    bad = [k for k in FROZEN_ROOT if k in entry]
    a = entry.get("auth") if isinstance(entry.get("auth"), dict) else {}
    bad += ["auth." + k for k in FROZEN_AUTH if k in a]
    return bad
claim = auth.get("claim") if isinstance(auth.get("claim"), dict) else {}
per_env = app.get("per_env") if isinstance(app.get("per_env"), dict) else {}
# Forme d'avant A1 : la VALEUR de la claim à la racine (trans-palier de fait).
# On refuse plutôt que de deviner à quel palier elle appartient.
if mode == "idp" and "value" in claim:
    refuse("MANIFESTE_LEGACY",
           "%s : auth.claim.value à la racine (forme mono-palier d'avant A1) — "
           "migrer la valeur sous per_env.<palier>.auth.claim.value (une clé par palier), "
           "puis ne garder à la racine que claim: { name: \"%s\" }" % (path, claim.get("name", "azp")))
def s(v):
    return "" if v is None else str(v)
# BORNES sur tout ce qui est HÉRITÉ ou interpolé ensuite (mesuré à la critique :
# une `team: ".*"` posée à la main était héritée SANS la garde de format du
# script — qui ne voit que la valeur fournie — puis interpolée en regex dans la
# garde providers, et contournait TEAM_NOT_DECLARED). Mêmes classes que les
# gardes d'entrée de provision-request.sh ; hors classe = manifeste inexploitable.
import re
bounds = [
    ("api",          s(app.get("api")),         r"^[A-Za-z0-9._-]+$"),
    ("api_version",  s(app.get("api_version")), r"^[A-Za-z0-9._-]+$"),
    ("auth.audience", s(auth.get("audience")),  r"^[A-Za-z0-9._:/-]*$"),
    ("auth.mode",    mode,                      r"^(idp|internal)$"),
    ("team",         s(app.get("team")),        r"^([a-z0-9][a-z0-9-]{1,30})?$"),
]
for k, v, rx in bounds:
    if not re.match(rx, v):
        refuse("MANIFESTE_INVALIDE", "%s : %s='%s' hors de la classe attendue %s" % (path, k, v, rx))
for k, v in per_env.items():
    if not re.match(r"^[A-Za-z0-9._-]+$", str(k)):
        refuse("MANIFESTE_INVALIDE", "%s : clé per_env '%s' hors de [A-Za-z0-9._-]" % (path, k))
    if not isinstance(v, dict):
        refuse("MANIFESTE_INVALIDE", "%s : per_env.%s n'est pas un mapping" % (path, k))
    # L'identité du palier est OBLIGATOIRE dans sa clé : sans claim.value, le
    # rôle poserait une stratégie avec clientId = nom de l'app AVANT son propre
    # fail-closed (consumer-auth.yml:352 puis :461) ; sans vault_sub, il n'y a
    # pas de chemin de secret pour ce palier.
    # Le rôle fusionne per_env[env] RÉCURSIVEMENT sur la racine : une clé
    # trans-palier posée dans une ligne de palier SURCHARGERAIT le contrat figé
    # sans que la comparaison de la racine ne voie rien (mesuré à la revue :
    # `rec: { …, api: "payments-initiation", team: "autre" }` ⇒ contrat
    # « identique », api/team effectifs changés sur rec). Refus nommé.
    bad = _per_env_frozen_keys(v)
    if bad:
        refuse("MANIFESTE_INVALIDE", "%s : per_env.%s surcharge un champ trans-palier (%s) — figé à la racine, jamais par palier" % (path, k, ", ".join(bad)))
    a = v.get("auth") if isinstance(v.get("auth"), dict) else {}
    if mode == "idp":
        c = a.get("claim") if isinstance(a.get("claim"), dict) else {}
        if not s(c.get("value")).strip():
            refuse("MANIFESTE_INVALIDE", "%s : per_env.%s.auth.claim.value absent ou vide (mode idp : le client_id du palier est obligatoire)" % (path, k))
    else:
        if not s(a.get("vault_sub")).strip():
            refuse("MANIFESTE_INVALIDE", "%s : per_env.%s.auth.vault_sub absent ou vide (mode internal : le chemin Vault du palier est obligatoire)" % (path, k))
print("MAN_API=%s" % s(app.get("api")))
print("MAN_API_VER=%s" % s(app.get("api_version")))
print("MAN_AUDIENCE=%s" % s(auth.get("audience")))
print("MAN_MODE=%s" % mode)
print("MAN_TEAM=%s" % s(app.get("team")))
print("MAN_ENVS=%s" % " ".join(str(k) for k in per_env.keys()))
PY
}

app_manifest_check_contract() {
  local f="${1:?app_manifest_check_contract <fichier> <name> <api> <api_version> <audience> <mode> <team>}"
  [ "$#" -eq 7 ] || { echo "REFUS: MANIFESTE_INVALIDE : app_manifest_check_contract attend 7 arguments, reçu $#" >&2; return 2; }
  [ -r "$f" ] || { echo "REFUS: MANIFESTE_INVALIDE : $f illisible" >&2; return 2; }
  python3 - "$@" <<'PY'
import sys, yaml
path, name, api, ver, aud, mode, team = sys.argv[1:8]
def refuse(tag, msg):
    sys.stderr.write("REFUS: %s : %s\n" % (tag, msg)); sys.exit(2)
try:
    doc = yaml.load(open(path, encoding="utf-8"), Loader=yaml.BaseLoader)
except Exception as e:
    refuse("MANIFESTE_INVALIDE", "%s : YAML illisible (%s)" % (path, str(e).splitlines()[0] if str(e) else e.__class__.__name__))
app = (doc or {}).get("apim_ss_app") if isinstance(doc, dict) else None
if not isinstance(app, dict):
    refuse("MANIFESTE_INVALIDE", "%s : clé racine apim_ss_app absente ou non-mapping" % path)
auth = app.get("auth") if isinstance(app.get("auth"), dict) else {}
def s(v):
    return "" if v is None else str(v)
# Les champs TRANS-PALIERS du GOAL (A1) — ni plus, ni moins. `mode` vient de
# l'APPELANT (anti-spoof) : un appelant d'un autre mode diverge, c'est voulu.
frozen = [
    ("name",        s(app.get("name")),        name),
    ("api",         s(app.get("api")),         api),
    ("api_version", s(app.get("api_version")), ver),
    ("audience",    s(auth.get("audience")),   aud),
    ("mode",        s(auth.get("mode") or "idp"), mode),
    ("team",        s(app.get("team")),        team),
]
diverg = ["%s : manifeste='%s' demande='%s'" % (k, m, d) for k, m, d in frozen if m != d]
if diverg:
    refuse("CONTRAT_DIVERGENT", " ; ".join(diverg)
           + " — les champs trans-paliers sont figés à la première demande ; changer d'API consommée est une NOUVELLE application, pas une promotion")
PY
}

app_manifest_merge_env() {
  local f="${1:?app_manifest_merge_env <fichier> <env> '<mapping flow>'}"
  local env="${2:?app_manifest_merge_env <fichier> <env> '<mapping flow>'}"
  local inline="${3:?app_manifest_merge_env <fichier> <env> '<mapping flow>'}"
  [ -r "$f" ] || { echo "REFUS: MANIFESTE_INVALIDE : $f illisible" >&2; return 2; }
  _app_manifest_env_ok "$env" || { echo "REFUS: MANIFESTE_INVALIDE : palier '$env' hors de [A-Za-z0-9._-] — refus d'écrire une ligne per_env avec cette clé" >&2; return 2; }
  # Le mapping est passé par l'ENVIRONNEMENT, pas en argv : un `}` ou un
  # guillemet n'a pas à survivre à un shell de plus.
  APP_MANIFEST_INLINE="$inline" python3 - "$f" "$env" <<'PY'
import sys, os, re, io, yaml
path, env = sys.argv[1:3]
inline = os.environ["APP_MANIFEST_INLINE"].strip()
def refuse(tag, msg):
    sys.stderr.write("REFUS: %s : %s\n" % (tag, msg)); sys.exit(2)
# 1) le mapping demandé doit être un mapping YAML flow lisible — AVANT de toucher au fichier
if "\n" in inline or "\r" in inline:
    refuse("MANIFESTE_INVALIDE", "per_env.%s : le mapping doit tenir sur UNE ligne (style flow)" % env)
try:
    want = yaml.load(io.StringIO(inline), Loader=yaml.BaseLoader)
except Exception as e:
    refuse("MANIFESTE_INVALIDE", "per_env.%s : mapping inline illisible (%s)" % (env, str(e).splitlines()[0] if str(e) else e.__class__.__name__))
if not isinstance(want, dict) or not want:
    refuse("MANIFESTE_INVALIDE", "per_env.%s : le contenu demandé n'est pas un mapping non vide (%r)" % (env, inline[:80]))
FROZEN_ROOT = ("name", "api", "api_version", "team", "description", "enforce", "contact_emails")
FROZEN_AUTH = ("mode", "audience", "server_alias")
bad = [k for k in FROZEN_ROOT if k in want] + ["auth." + k for k in FROZEN_AUTH if k in (want.get("auth") if isinstance(want.get("auth"), dict) else {})]
if bad:
    refuse("MANIFESTE_INVALIDE", "per_env.%s : le mapping demandé porte un champ trans-palier (%s) — figé à la racine, jamais par palier" % (env, ", ".join(bad)))
# 2) fusion ligne à ligne — le fichier n'est JAMAIS re-sérialisé
text = open(path, encoding="utf-8").read()
if text and not text.endswith("\n"):
    text += "\n"
lines = text.splitlines(True)
new_line = "    %s: %s\n" % (env, inline)
# La tête du bloc : `  per_env:` nu, ou suivi d'un commentaire, ou d'un mapping
# flow VIDE (`per_env: {}` — forme que le rôle accepte) qui devient un bloc.
# Un mapping flow NON vide sur la même ligne (`per_env: { dev: … }`) n'est pas
# fusionnable ligne à ligne : refus nommé, jamais une clé dupliquée en silence
# (PyYAML garde la dernière sans rien dire).
head_re  = re.compile(r"^  per_env:\s*(#.*)?$")
empty_re = re.compile(r"^  per_env:\s*\{\s*\}\s*(#.*)?$")
heads = [i for i, l in enumerate(lines) if head_re.match(l.rstrip("\r\n")) or empty_re.match(l.rstrip("\r\n"))]
inline_heads = [i for i, l in enumerate(lines) if l.startswith("  per_env:") and i not in heads]
if inline_heads:
    refuse("MANIFESTE_INVALIDE", "%s : `per_env` est écrit en mapping flow non vide sur une ligne (l.%d) — forme non fusionnable, à réécrire en bloc (une ligne par palier)" % (path, inline_heads[0] + 1))
if len(heads) > 1:
    refuse("MANIFESTE_INVALIDE", "%s : plusieurs blocs `  per_env:`" % path)
if heads and empty_re.match(lines[heads[0]].rstrip("\r\n")):
    lines[heads[0]] = "  per_env:\n"
if heads:
    start = heads[0] + 1
    end = start
    # le bloc = les lignes suivantes indentées d'au moins 4 espaces (sous-clés
    # incluses) ; une ligne vide ou moins indentée le termine.
    while end < len(lines) and lines[end].startswith("    "):
        end += 1
    # Clé nue OU citée (`"dev":`, `'dev':`) : une clé citée non reconnue
    # laisserait insérer un doublon que PyYAML avale (dernier gagne).
    key_re = re.compile(r"^    ([\"']?)%s\1:(\s|$)" % re.escape(env))
    hits = [i for i in range(start, end) if key_re.match(lines[i])]
    if len(hits) > 1:
        refuse("MANIFESTE_INVALIDE", "%s : per_env.%s déclaré %d fois" % (path, env, len(hits)))
    # Aucune clé de palier en double dans le bloc, quelle qu'elle soit : PyYAML
    # ne le signale pas, on le compte nous-mêmes.
    any_key = re.compile(r"^    ([\"']?)([^\"'#:][^\"':]*)\1:(\s|$)")
    seen = {}
    for i in range(start, end):
        m = any_key.match(lines[i])
        if m:
            seen[m.group(2)] = seen.get(m.group(2), 0) + 1
    dups = sorted(k for k, n in seen.items() if n > 1)
    if dups:
        refuse("MANIFESTE_INVALIDE", "%s : clé(s) per_env dupliquée(s) : %s — le rôle garderait la dernière en silence" % (path, ", ".join(dups)))
    if hits:
        lines[hits[0]] = new_line
    else:
        lines.insert(end, new_line)
else:
    # Bloc absent : il se crée EN FIN DU MAPPING `apim_ss_app` — pas en fin de
    # fichier, qui pourrait appartenir à une autre clé racine (une clé de plus
    # écrite à la main après le bloc) ; l'auto-vérification le verrait, mais
    # autant écrire juste.
    roots = [i for i, l in enumerate(lines) if l.rstrip("\r\n") == "apim_ss_app:"]
    if len(roots) != 1:
        refuse("MANIFESTE_INVALIDE", "%s : clé racine `apim_ss_app:` absente ou multiple (bloc per_env impossible à placer)" % path)
    at = len(lines)
    for i in range(roots[0] + 1, len(lines)):
        l = lines[i].rstrip("\r\n")
        if l and not l.startswith(" ") and not l.startswith("#"):
            at = i
            break
    lines[at:at] = ["  per_env:\n", new_line]
out = "".join(lines)
# 3) AUTO-VÉRIFICATION : ce qu'on relit est exactement ce qu'on a demandé
try:
    got = yaml.load(io.StringIO(out), Loader=yaml.BaseLoader)["apim_ss_app"]["per_env"][env]
except Exception as e:
    refuse("MANIFESTE_INVALIDE", "%s : après fusion de per_env.%s le YAML ne se relit plus (%s) — rien n'est écrit (palier écrit en style block à la main ?)"
           % (path, env, str(e).splitlines()[0] if str(e) else e.__class__.__name__))
if got != want:
    refuse("MANIFESTE_INVALIDE", "%s : per_env.%s relu (%r) ≠ demandé (%r) — rien n'est écrit" % (path, env, got, want))
# Écriture ATOMIQUE : un fichier temporaire à côté, puis os.replace — jamais un
# manifeste tronqué si le processus meurt entre l'ouverture et la fin d'écriture.
tmp = path + ".a1tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(out)
os.replace(tmp, path)
PY
}

# app_manifest_digest_env <fichier> <env>
#   Imprime `sha256:<hex>` = SHA-256 du JSON CANONIQUE du MANIFESTE EFFECTIF du
#   palier — la racine (sans per_env) fusionnée avec per_env.<env> selon la
#   sémantique EXACTE du rôle (resolve-env.yml : `combine(recursive=True)` —
#   mappings fusionnés récursivement, listes et scalaires REMPLACÉS) — tel que
#   RELU par la lib (BaseLoader : aucun typage), `sort_keys`, séparateurs
#   compacts, UTF-8. Deux manifestes qui ne diffèrent que par l'ordre des clés,
#   les guillemets ou les espaces ⇒ même digest : il répond à « qu'est-ce qui
#   tourne en <env> ? » (A2), pas à « quels octets ? » (ça, c'est le SHA de
#   merge). Il couvre la racine (une édition manuelle d'`enforce`, de la
#   description ou de l'audience change ce qui tourne — critique de la spec
#   2026-09-02) et le SEUL palier demandé (un autre palier ne le change pas).
#   Refus : PALIER_INVALIDE (clé hors classe, avant toute lecture),
#   MANIFESTE_INVALIDE / MANIFESTE_LEGACY (par app_manifest_read : mêmes bornes,
#   même refus de la forme d'avant A1 — le digest ne les contourne pas),
#   PALIER_ABSENT (per_env.<env> n'existe pas ; les paliers déclarés sont nommés).
#   Recalculable sans la lib (contrôle positif dans test-provision-apply-a2.sh A.3).
app_manifest_digest_env() {
  local f="${1:?app_manifest_digest_env <fichier> <env>}" e="${2:?app_manifest_digest_env <fichier> <env>}"
  _app_manifest_env_ok "$e" || { echo "REFUS: PALIER_INVALIDE : '$e' hors de [A-Za-z0-9._-]" >&2; return 2; }
  # La lecture porte les bornes et le refus legacy ; sa sortie KEY=VALUE n'est
  # pas voulue ici (l'appelant capture stdout dans une variable).
  app_manifest_read "$f" >/dev/null || return 2
  python3 - "$f" "$e" <<'PY'
import sys, json, hashlib, yaml
path, env = sys.argv[1], sys.argv[2]
doc = yaml.load(open(path, encoding="utf-8"), Loader=yaml.BaseLoader)
app = doc["apim_ss_app"]
per_env = app.get("per_env") if isinstance(app.get("per_env"), dict) else {}
if env not in per_env:
    sys.stderr.write("REFUS: PALIER_ABSENT : %s : per_env.%s absent (paliers déclarés : %s)\n"
                     % (path, env, ", ".join(str(k) for k in per_env.keys()) or "aucun"))
    sys.exit(2)
def combine(base, over):
    # Ansible combine(recursive=True) : dict⊕dict récursif ; toute autre valeur REMPLACE.
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = combine(out[k], v)
        else:
            out[k] = v
    return out
root = {k: v for k, v in app.items() if k != "per_env"}
effective = combine(root, per_env[env])
canon = json.dumps(effective, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
print("sha256:" + hashlib.sha256(canon).hexdigest())
PY
}
