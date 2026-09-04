#!/usr/bin/env bash
# ci/lint-config-knobs.sh — la porte des VALEURS PAR DÉFAUT.
#
# CE QU'ELLE EMPÊCHE. Cette chaîne a été écrite pour un laboratoire, et ses
# valeurs de lab s'étaient installées comme valeurs par défaut dans le code :
#     GIT_HOST = "${env.GIT_HOST ?: 'http://gitea:3000'}"
#     TENANT="${TENANT:-banking-demo}"
# Chez un client, une variable non transmise n'est alors JAMAIS signalée : elle
# est remplacée en silence par la valeur du lab, et la panne sort plus loin, sous
# un tout autre nom. Trois défauts mesurés en 2026-09-03 rendaient même des refus
# fail-closed INATTEIGNABLES, parce que le pipeline posait une valeur en amont.
#
# LA RÈGLE, en une phrase : un défaut est acceptable si et seulement si cette
# porte peut le vérifier SANS SORTIR DU DÉPÔT.
#
#   T1  le défaut désigne quelque chose HORS du dépôt (URL, hôte:port)   REFUSÉ
#   T2  le défaut est un IDENTIFIANT de site (tenant, login, compte, mount) REFUSÉ
#   T3  le défaut est un CHEMIN dans le dépôt                            ADMIS si le chemin résout
#   T4  le défaut désigne un fichier de DÉMONSTRATION                     REFUSÉ
#
# UNE exception nommée : *_CREDENTIALS_ID. Un identifiant de credential faux
# échoue BRUYAMMENT au withCredentials, avant toute écriture, en nommant l'objet
# manquant : c'est le seul identifiant qui se dénonce tout seul.
#
# LA BASE D'EXEMPTIONS (ci/lint-config-knobs.exempt) porte les violations
# CONNUES au moment de la pose de cette porte — la voie API, non encore traitée.
# Elle n'est pas une liste de pardons : elle est la dette, datée et comptée.
# ON N'Y AJOUTE JAMAIS DE LIGNE. On en retire.
#
# PÉRIMÈTRE : ci/Jenkinsfile*, scripts/*.sh, scripts/lib/*.sh, ci/lib/*.sh.
# Les harnais (scripts/test-*.sh) sont HORS périmètre : un défaut de lab y est
# légitime, ils posent leurs valeurs eux-mêmes.
set -eu

cd "$(dirname "$0")/.." || { echo "REFUS: racine du depot introuvable" >&2; exit 2; }
EXEMPT="ci/lint-config-knobs.exempt"

python3 - "$EXEMPT" <<'PY'
import os, re, sys, glob

exempt_path = sys.argv[1]
exempt = set()
if os.path.exists(exempt_path):
    for l in open(exempt_path, encoding="utf-8"):
        l = l.split("#", 1)[0].strip()   # un commentaire de fin de ligne porte le motif
        if l:
            exempt.add(l)

# ── ce qui compte comme « hors du dépôt » ou « identifiant de site » ─────────
HORS_DEPOT = re.compile(r"^(https?|ftp)://|^[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{2,5}(/|$)")
NOM_IDENTITE = re.compile(
    r"(TENANT|OWNER|_LOGINS?$|_LOGIN$|ROLE_ID|_USER$|_USERNAME$|EMAIL|_MOUNT$|WHITELIST|_TEAM$|_JOB$|_REPO$)")
DEMO = re.compile(r"clients/_example/|/demo-|\.lab\.|inventory\.lab")
# valeurs neutres : un mot-clé de protocole, un mode, un nom de champ standard
NEUTRE = re.compile(r"^(true|false|0|1|main|master|direct|post|basic|oauth2|replace|overlap|"
                    r"client_id|client_secret|secret|json|yaml|\.|\./|[0-9.]+)$")

def classe(nom, val):
    """rend (verdict, motif) — verdict dans {'ok','T1','T2','T3','T4'}"""
    if not val:
        return "ok", "vide (pas de defaut)"
    if "__ENV__" in val and not HORS_DEPOT.match(val):
        return "T2", "gabarit d'identifiant de site"
    if DEMO.search(val):
        return "T4", "fichier de demonstration"
    if HORS_DEPOT.match(val):
        return "T1", "adresse hors du depot"
    if nom.endswith("CREDENTIALS_ID"):
        return "ok", "identifiant de credential (echoue bruyamment, exception nommee)"
    if NEUTRE.match(val):
        return "ok", "valeur neutre"
    if NOM_IDENTITE.search(nom):
        return "T2", "identifiant de site"
    if "/" in val or val.endswith((".yml", ".yaml", ".ini", ".sh", ".xml")):
        # T3 : un chemin — admis SEULEMENT s'il resout depuis la racine du depot
        cible = val.split("__ENV__")[0].rstrip("/")
        if os.path.exists(cible) or os.path.isdir(cible):
            return "ok", f"chemin du depot, resolu ({cible})"
        return "T3", f"chemin du depot qui NE RESOUT PAS ({cible})"
    return "ok", "valeur neutre"

# ── les deux formes de défaut ────────────────────────────────────────────────
GROOVY = re.compile(r"([A-Z][A-Z0-9_]*)\s*=\s*\"\$\{env\.[A-Z_]+\s*\?:\s*'([^']*)'\}\"")
SHELL  = re.compile(r"\b([A-Z][A-Z0-9_]*)=\"?\$\{\1:-([^}\"]*)\}\"?")

fichiers = sorted(glob.glob("ci/Jenkinsfile*")) + sorted(glob.glob("ci/lib/*.sh")) \
         + [f for f in sorted(glob.glob("scripts/*.sh")) if "/test-" not in f] \
         + sorted(glob.glob("scripts/lib/*.sh"))

violations, exemptees, examinees = [], 0, 0
for f in fichiers:
    for i, l in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
        if l.lstrip().startswith(("#", "//")):
            continue
        for rx in (GROOVY, SHELL):
            m = rx.search(l)
            if not m:
                continue
            nom, val = m.group(1), m.group(2)
            examinees += 1
            v, motif = classe(nom, val)
            if v == "ok":
                continue
            cle = f"{f}:{nom}"
            if cle in exempt:
                exemptees += 1
            else:
                violations.append((f, i, nom, val, v, motif))
            break

print(f"== defauts examines : {examinees} · exemptes (dette connue) : {exemptees} ==")
if violations:
    print("")
    for f, i, nom, val, v, motif in violations:
        print(f"  {v}  {f}:{i}  {nom} = '{val}'")
        print(f"      {motif} — poser la valeur en variable globale du controleur,")
        print(f"      et laisser le script REFUSER quand elle manque (${{{nom}:?…}}).")
    print("")
    print(f"PORTE ROUGE : {len(violations)} defaut(s) de site dans du code livrable.")
    sys.exit(1)

# la dette ne doit que decroitre : une ligne d'exemption qui ne correspond plus
# a une violation reelle est du bruit, on demande son retrait.
mortes = []
if exempt:
    reels = set()
    for f in fichiers:
        for l in open(f, encoding="utf-8", errors="replace"):
            for rx in (GROOVY, SHELL):
                m = rx.search(l)
                if m:
                    reels.add(f"{f}:{m.group(1)}")
    mortes = sorted(e for e in exempt if e not in reels)
if mortes:
    print("")
    print("  exemptions DEVENUES INUTILES (le defaut n'existe plus) — a retirer du fichier :")
    for e in mortes:
        print(f"    {e}")

print("PORTE VERTE : aucun defaut de site hors de la dette declaree.")
PY
