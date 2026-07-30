# Carto des API et des consommateurs — plan d'implémentation

> **Document historique — ne pas recopier tel quel.** Ce plan a été écrit avant
> le relevé du terrain, et l'implémentation s'en est écartée sur des points
> mesurés. Deux écarts feraient régresser le produit si l'on recopiait le code
> ci-dessous :
>
> - **`--days` et `carto_window_days` ont été supprimés.** Tels qu'écrits ici,
>   ils ne paramètrent que le calcul de profondeur couverte, pas les
>   agrégations : le document annoncerait une fenêtre qu'il ne respecte pas. Et
>   une profondeur réglable ferait cohabiter dans la même série de
>   `history.json` des totaux à 30 et à 90 jours. La fenêtre longue est figée.
> - **Les constantes de `gateway.py`, d'`analytics.py` et le motif d'index sont
>   des placeholders faux.** Les valeurs qui font foi sont dans
>   `carto/TERRAIN.md`, mesurées sur une vraie gateway. Le motif d'index
>   Elasticsearch ne porte **pas** de tiret avant l'étoile.
>
> L'état réel du produit est le code de `carto/`, pas ce document.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** produire une carto toujours à jour des APIs et des consommateurs d'un
API Gateway webMethods de production, exposée en site statique, qui répond à
« qui consomme quoi », « qui dois-je prévenir » et « comment ma plateforme
évolue ».

**Architecture:** un job planifié en lecture seule collecte l'inventaire
(API d'administration) et le trafic (agrégation sur l'API Data Store), et écrit
**un contrat de données** `carto.json` + `history.json`. Un site statique
autonome lit ces fichiers et ne touche jamais la production. La séparation
collecte/rendu est la décision centrale (spec D1) : elle rend tout le produit
testable sur fixtures, sans accès prod.

**Tech Stack:** Python 3 **stdlib uniquement** (`urllib.request`, `json`,
`datetime`, `unittest`) ; HTML/CSS/JS vanilla en un fichier autonome ; Ansible
pour le déploiement et la planification.

**Spec :** `docs/superpowers/specs/2026-07-30-carto-api-consommateurs-design.md`

## Global Constraints

- **Zéro dépendance externe Python.** Stdlib seule. Aucun `requirements.txt`,
  aucun `pip install`. Le dépôt n'en a aucun, et le job doit tourner sur un
  serveur client sans négocier d'installation.
- **Tests en `unittest`** (stdlib), lancés par `python3 -m unittest discover`.
  Pas de pytest.
- **Zéro dépendance externe au rendu.** Aucun CDN, aucune police distante,
  aucun `import` réseau : l'intranet client est supposé sans accès internet.
  Tout JS et tout CSS sont en ligne dans `index.html`.
- **Lecture seule sur la production.** Aucune requête `POST`/`PUT`/`DELETE`
  vers le Gateway, jamais, y compris en test.
- **Aucun secret dans le dépôt ni sur stdout.** Identifiants par variables
  d'environnement uniquement.
- **Ne jamais écraser une bonne carto par une mauvaise** (spec D8) : écriture
  dans un temporaire, validation, puis bascule atomique.
- **Ne jamais afficher une profondeur qu'on n'a pas** (spec D4) : la fenêtre
  affichée est la fenêtre réellement couverte.
- **Langue de l'interface et des messages : français.**
- `schemaVersion` du contrat : **1**.

## Structure des fichiers

```
carto/
  README.md                      exploitation : lancer, planifier, diagnostiquer
  TERRAIN.md                     produit par T0 : réponses mesurées à V1–V6
  collect/
    __init__.py
    model.py                     contrat + validateur (aucune I/O)
    gateway.py                   normalisation inventaire + client HTTP
    analytics.py                 requête d'agrégation + parsing + fenêtre
    build.py                     jointure déclaré × observé -> carto.json
    history.py                   compteurs + append idempotent
    publish.py                   écriture atomique validée
    __main__.py                  CLI (--dry-run, --from-fixtures, --out)
  render/
    index.html                   site autonome, 6 vues
  tests/
    fixtures/                    réponses réelles capturées par T0
    test_model.py
    test_gateway.py
    test_analytics.py
    test_build.py
    test_history.py
    test_publish.py
  ansible/roles/carto_collect/   déploiement + planification + alerte
```

`carto/` est un répertoire **autonome au niveau racine**, et non un sous-dossier
de `poc-control-plane-federation/` : c'est un livrable transportable qui sera
déposé tel quel sur un serveur client, sans le reste du dépôt.

**Découpage :** chaque module a une responsabilité et **aucune I/O sauf
`gateway.Gateway`, `publish` et `__main__`**. C'est ce qui permet de tester la
totalité de la logique métier sur fixtures, sans réseau.

## Ordre d'exécution et dépendance au terrain

**T0 est bloquant.** Les tâches T2 et T3 dépendent de noms de champs réels que
personne ne connaît aujourd'hui (spec V1–V5). Le principe du dépôt est de lire
les shapes dans le Swagger livré dans le conteneur, jamais de les deviner : T0
les mesure et les fige en fixtures, et tout le reste est construit contre ces
fixtures.

T1 et T5 ne dépendent pas du terrain et peuvent être faites en parallèle de T0.

---

### Task 0: Reconnaissance du terrain client

**Files:**
- Create: `carto/TERRAIN.md`
- Create: `carto/tests/fixtures/apis.json`
- Create: `carto/tests/fixtures/applications.json`
- Create: `carto/tests/fixtures/aggregation-d90.json`
- Create: `carto/tests/fixtures/oldest-event.json`
- Create: `carto/scripts/capture-fixtures.sh`

**Interfaces:**
- Consumes: rien.
- Produces: les fixtures ci-dessus et, dans `TERRAIN.md`, les constantes
  littérales que T2 et T3 recopient : `API_FIELDS`, `APP_FIELDS`,
  `DECLARED_PATH`, `ES_INDEX`, `ES_API_FIELD`, `ES_APP_FIELD`,
  `ES_TIME_FIELD`, `ES_STATUS_FIELD`.

- [ ] **Step 1: Lire le Swagger d'administration livré dans le conteneur**

Ne pas deviner les chemins REST. Les lire à la source :

```bash
# depuis le conteneur API Gateway
ls /opt/softwareag/IntegrationServer/instances/default/packages/WmAPIGateway/resources/apigatewayservices/*.json
```

Relever les chemins exacts pour : liste des APIs, liste des Applications, et la
manière dont une Application porte ses APIs autorisées (le lien **déclaré**).

- [ ] **Step 2: Capturer les réponses réelles en fixtures**

```bash
cat > carto/scripts/capture-fixtures.sh <<'EOF'
#!/usr/bin/env bash
# Capture des réponses réelles du Gateway en fixtures de test. LECTURE SEULE.
# Usage : WM_ADMIN_URL=... WM_USER=... WM_PASS=... ./capture-fixtures.sh <destdir>
set -euo pipefail
DEST="${1:?destdir requis}"; mkdir -p "$DEST"
get() { curl -sS -u "$WM_USER:$WM_PASS" -H 'Accept: application/json' "$WM_ADMIN_URL$1"; }
get /apis         > "$DEST/apis.json"
get /applications > "$DEST/applications.json"
echo "capturé dans $DEST — RELIRE ces fichiers et retirer toute donnée sensible"
EOF
chmod +x carto/scripts/capture-fixtures.sh
```

Adapter les deux chemins `/apis` et `/applications` à ce qu'a montré l'étape 1.

**Relire les fixtures avant de les commiter** et retirer contacts nominatifs,
certificats et toute valeur sensible : elles entrent dans le dépôt.

- [ ] **Step 3: Capturer une agrégation de trafic et le plus vieil événement**

Requête d'agrégation sur l'API Data Store, terms imbriqués (portable ES 6+) —
enregistrer la réponse dans `aggregation-d90.json` :

```json
{ "size": 0,
  "query": { "range": { "<ES_TIME_FIELD>": { "gte": "now-90d" } } },
  "aggs": { "api": { "terms": { "field": "<ES_API_FIELD>", "size": 1000 },
    "aggs": { "consumer": { "terms": { "field": "<ES_APP_FIELD>", "size": 1000 },
      "aggs": { "last":   { "max": { "field": "<ES_TIME_FIELD>" } },
                "errors": { "filter": { "range": { "<ES_STATUS_FIELD>": { "gte": 400 } } } } } } } } } }
```

Et le plus vieil événement disponible, dans `oldest-event.json` :

```json
{ "size": 0, "aggs": { "oldest": { "min": { "field": "<ES_TIME_FIELD>" } } } }
```

- [ ] **Step 4: Écrire `carto/TERRAIN.md` — les réponses mesurées à V1–V6**

Le fichier doit contenir, pour chaque point, la **valeur mesurée** et la
commande qui l'a produite. Pas de « probablement ».

```markdown
# Terrain client mesuré — <date>

## V1 — date de création des APIs et Applications
Champ API         : <nom exact, ou ABSENT>
Champ Application : <nom exact, ou ABSENT>
Conséquence si ABSENT : la série rétro-calculée (spec D7) est abandonnée ;
la vue Évolution démarre au premier snapshot. Prévenir avant T9.

## V2 — rétention réelle des index d'analytics
Plus vieil événement : <date>  → profondeur réelle : <N> jours
Conséquence : la fenêtre affichable est plafonnée à <N> jours.

## V3 — chemins d'administration et shape de l'agrégation
Liste des APIs         : <chemin>
Liste des Applications : <chemin>
Lien déclaré           : <où et sous quelle forme>
ES_INDEX / ES_API_FIELD / ES_APP_FIELD / ES_TIME_FIELD / ES_STATUS_FIELD : <valeurs>

## V4 — contact exploitable sur les Applications
<champ, ou : source externe nécessaire — laquelle>

## V5 — identification de l'appelant dans les événements
Le champ <ES_APP_FIELD> est-il toujours renseigné ? <oui/non>
Part d'événements sans appelant identifié : <N %>
Conséquence : ces appels apparaissent sous un consommateur « (non identifié) ».

## V6 — cible de publication
Serveur / chemin / mécanisme de dépôt : <...>

## Constantes à recopier dans le code
API_FIELDS = {...}
APP_FIELDS = {...}
DECLARED_PATH = "..."
ES_INDEX = "..."
```

- [ ] **Step 5: Commit**

```bash
git add carto/TERRAIN.md carto/tests/fixtures carto/scripts/capture-fixtures.sh
git commit -m "feat(carto): terrain client mesuré et fixtures capturées"
```

---

### Task 1: Contrat de données et validateur

**Files:**
- Create: `carto/collect/__init__.py` (vide)
- Create: `carto/collect/model.py`
- Test: `carto/tests/test_model.py`

**Interfaces:**
- Consumes: rien.
- Produces: `SCHEMA_VERSION: int`, `validate_carto(doc: dict) -> list[str]`
  (liste de messages d'erreur, vide si valide), `validate_history(rows: list)
  -> list[str]`.

- [ ] **Step 1: Écrire les tests qui échouent**

```python
# carto/tests/test_model.py
import unittest
from carto.collect.model import SCHEMA_VERSION, validate_carto, validate_history

def doc(**over):
    d = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": "2026-07-30T02:11:00Z",
        "window": {"requestedDays": 90, "coveredDays": 34,
                   "oldestEvent": "2026-06-26T00:00:00Z"},
        "apis": [{"id": "a1", "name": "orders", "version": "1.0",
                  "owner": "team-x", "active": True, "createdAt": None}],
        "consumers": [{"id": "c1", "name": "crm", "owner": "team-y",
                       "contact": "crm@ex.invalid", "createdAt": None}],
        "edges": [{"apiId": "a1", "consumerId": "c1", "declared": True,
                   "calls": {"d7": 1, "d30": 2, "d90": 3},
                   "lastCall": "2026-07-29T18:02:00Z", "errorRate": 0.0}],
    }
    d.update(over)
    return d

class TestValidateCarto(unittest.TestCase):
    def test_document_complet_est_valide(self):
        self.assertEqual(validate_carto(doc()), [])

    def test_refuse_une_liste_apis_vide(self):
        # garde-fou D8 : une carto vide ne doit jamais écraser une bonne carto
        errs = validate_carto(doc(apis=[]))
        self.assertTrue(any("apis" in e for e in errs), errs)

    def test_refuse_une_arete_vers_une_api_inconnue(self):
        d = doc()
        d["edges"][0]["apiId"] = "fantome"
        errs = validate_carto(d)
        self.assertTrue(any("apiId" in e for e in errs), errs)

    def test_refuse_une_arete_vers_un_consommateur_inconnu(self):
        d = doc()
        d["edges"][0]["consumerId"] = "fantome"
        errs = validate_carto(d)
        self.assertTrue(any("consumerId" in e for e in errs), errs)

    def test_refuse_une_mauvaise_version_de_schema(self):
        errs = validate_carto(doc(schemaVersion=99))
        self.assertTrue(any("schemaVersion" in e for e in errs), errs)

    def test_refuse_un_compteur_manquant(self):
        d = doc()
        del d["edges"][0]["calls"]["d30"]
        errs = validate_carto(d)
        self.assertTrue(any("d30" in e for e in errs), errs)

    def test_accepte_une_arete_declaree_sans_trafic(self):
        # le consommateur onboardé qui n'a pas encore appelé : cas central
        d = doc()
        d["edges"][0].update(calls={"d7": 0, "d30": 0, "d90": 0},
                             lastCall=None, errorRate=0.0)
        self.assertEqual(validate_carto(d), [])

class TestValidateHistory(unittest.TestCase):
    def test_ligne_complete_est_valide(self):
        rows = [{"date": "2026-07-30", "apis": 128, "consumersRegistered": 96,
                 "consumersActive": 71, "calls": 18402113}]
        self.assertEqual(validate_history(rows), [])

    def test_refuse_une_date_mal_formee(self):
        rows = [{"date": "30/07/2026", "apis": 1, "consumersRegistered": 1,
                 "consumersActive": 1, "calls": 0}]
        self.assertTrue(validate_history(rows))
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `cd /Users/potomitan/stoa-platform/stoa-labs && python3 -m unittest carto.tests.test_model -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'carto.collect.model'`

- [ ] **Step 3: Écrire l'implémentation minimale**

```python
# carto/collect/model.py
"""model.py — contrat de données de la carto et sa validation.

Aucune I/O. Le validateur est écrit à la main (stdlib seule) : le dépôt
n'embarque aucune dépendance Python, et le job doit tourner sur un serveur
client sans installation.

Rôle central (spec D8) : ce validateur est la garde qui empêche une collecte
dégradée d'écraser une bonne carto. Il doit donc refuser le vide, pas seulement
le mal formé.
"""
import re

SCHEMA_VERSION = 1
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_WINDOWS = ("d7", "d30", "d90")


def _need(errors, cond, msg):
    if not cond:
        errors.append(msg)


def validate_carto(doc):
    """Retourne la liste des erreurs. Liste vide == document publiable."""
    e = []
    if not isinstance(doc, dict):
        return ["racine : objet attendu"]

    _need(e, doc.get("schemaVersion") == SCHEMA_VERSION,
          f"schemaVersion : {SCHEMA_VERSION} attendu, {doc.get('schemaVersion')!r} reçu")
    _need(e, isinstance(doc.get("generatedAt"), str) and doc.get("generatedAt"),
          "generatedAt : horodatage ISO attendu")

    w = doc.get("window")
    if not isinstance(w, dict):
        e.append("window : objet attendu")
    else:
        _need(e, isinstance(w.get("requestedDays"), int), "window.requestedDays : entier attendu")
        _need(e, isinstance(w.get("coveredDays"), int), "window.coveredDays : entier attendu")

    apis, cons, edges = doc.get("apis"), doc.get("consumers"), doc.get("edges")
    _need(e, isinstance(apis, list) and len(apis) > 0,
          "apis : liste non vide attendue (une carto sans API est une collecte ratée)")
    _need(e, isinstance(cons, list), "consumers : liste attendue")
    _need(e, isinstance(edges, list), "edges : liste attendue")
    if e:
        return e

    for i, a in enumerate(apis):
        _need(e, isinstance(a.get("id"), str) and a.get("id"), f"apis[{i}].id : identifiant manquant")
        _need(e, isinstance(a.get("name"), str) and a.get("name"), f"apis[{i}].name : nom manquant")
    for i, c in enumerate(cons):
        _need(e, isinstance(c.get("id"), str) and c.get("id"), f"consumers[{i}].id : identifiant manquant")
        _need(e, isinstance(c.get("name"), str) and c.get("name"), f"consumers[{i}].name : nom manquant")

    api_ids = {a.get("id") for a in apis}
    con_ids = {c.get("id") for c in cons}
    for i, ed in enumerate(edges):
        _need(e, ed.get("apiId") in api_ids, f"edges[{i}] : apiId inconnu {ed.get('apiId')!r}")
        _need(e, ed.get("consumerId") in con_ids, f"edges[{i}] : consumerId inconnu {ed.get('consumerId')!r}")
        _need(e, isinstance(ed.get("declared"), bool), f"edges[{i}].declared : booléen attendu")
        calls = ed.get("calls")
        if not isinstance(calls, dict):
            e.append(f"edges[{i}].calls : objet attendu")
            continue
        for k in _WINDOWS:
            _need(e, isinstance(calls.get(k), int), f"edges[{i}].calls.{k} : entier attendu")
    return e


def validate_history(rows):
    """Retourne la liste des erreurs sur le journal d'évolution."""
    e = []
    if not isinstance(rows, list):
        return ["history : liste attendue"]
    for i, r in enumerate(rows):
        if not isinstance(r, dict):
            e.append(f"history[{i}] : objet attendu")
            continue
        _need(e, isinstance(r.get("date"), str) and _DATE.match(r.get("date") or ""),
              f"history[{i}].date : format AAAA-MM-JJ attendu")
        for k in ("apis", "consumersRegistered", "consumersActive", "calls"):
            _need(e, isinstance(r.get(k), int), f"history[{i}].{k} : entier attendu")
    return e
```

Créer aussi les fichiers vides `carto/__init__.py`, `carto/collect/__init__.py`
et `carto/tests/__init__.py` — les trois. Sans eux, `python3 -m unittest
carto.tests.test_model` ne résout pas les imports depuis la racine du dépôt.

- [ ] **Step 4: Lancer les tests pour vérifier qu'ils passent**

Run: `python3 -m unittest carto.tests.test_model -v`
Expected: PASS — 9 tests

- [ ] **Step 5: Commit**

```bash
git add carto/__init__.py carto/collect/__init__.py carto/collect/model.py \
        carto/tests/__init__.py carto/tests/test_model.py
git commit -m "feat(carto): contrat de donnees et validateur, garde anti-carto-vide"
```

---

### Task 2: Normalisation de l'inventaire

**Files:**
- Create: `carto/collect/gateway.py`
- Test: `carto/tests/test_gateway.py`

**Interfaces:**
- Consumes: `carto/tests/fixtures/apis.json`, `applications.json` et les
  constantes de `carto/TERRAIN.md` (T0).
- Produces: `normalize_apis(raw) -> list[dict]` (clés `id, name, version,
  owner, active, createdAt`), `normalize_consumers(raw) -> list[dict]`
  (clés `id, name, owner, contact, createdAt`), `declared_edges(raw_apps) ->
  set[tuple[str, str]]` de couples `(apiId, consumerId)`.

- [ ] **Step 1: Relever les noms de champs réels**

Ouvrir `carto/TERRAIN.md` (T0) et recopier les valeurs mesurées dans les
constantes `API_FIELDS`, `APP_FIELDS` et `DECLARED_PATH` de l'étape 3. Ne pas
inventer de nom de champ : si un champ n'existe pas côté Gateway, le mettre à
`None` dans le mapping et la valeur normalisée sera `None`.

- [ ] **Step 2: Écrire les tests qui échouent**

```python
# carto/tests/test_gateway.py
import json, pathlib, unittest
from carto.collect.gateway import normalize_apis, normalize_consumers, declared_edges

FIX = pathlib.Path(__file__).parent / "fixtures"

def load(name):
    return json.loads((FIX / name).read_text())

class TestNormalisation(unittest.TestCase):
    def test_chaque_api_a_un_id_et_un_nom(self):
        apis = normalize_apis(load("apis.json"))
        self.assertTrue(apis, "la fixture ne doit pas etre vide")
        for a in apis:
            self.assertTrue(a["id"], a)
            self.assertTrue(a["name"], a)
            self.assertIn("active", a)
            self.assertIn("createdAt", a)

    def test_chaque_consommateur_a_un_id_et_un_nom(self):
        cons = normalize_consumers(load("applications.json"))
        self.assertTrue(cons)
        for c in cons:
            self.assertTrue(c["id"], c)
            self.assertTrue(c["name"], c)
            self.assertIn("contact", c)

    def test_les_identifiants_sont_uniques(self):
        apis = normalize_apis(load("apis.json"))
        ids = [a["id"] for a in apis]
        self.assertEqual(len(ids), len(set(ids)))

    def test_les_aretes_declarees_referencent_des_objets_connus(self):
        apis = {a["id"] for a in normalize_apis(load("apis.json"))}
        cons = {c["id"] for c in normalize_consumers(load("applications.json"))}
        for api_id, con_id in declared_edges(load("applications.json")):
            self.assertIn(con_id, cons)
            # une autorisation peut pointer une API supprimee : on l'accepte ici,
            # build.py fabriquera un noeud "(inconnu)" plutot que de la perdre
            self.assertIsInstance(api_id, str)

    def test_normalisation_tolere_un_champ_absent(self):
        apis = normalize_apis({"apis": [{"id": "x", "apiName": "y"}]})
        self.assertEqual(apis[0]["id"], "x")
        self.assertIsNone(apis[0]["createdAt"])
```

Si la clé racine des fixtures n'est pas `apis` / `applications`, adapter
`test_normalisation_tolere_un_champ_absent` à la clé réelle relevée en T0.

- [ ] **Step 3: Lancer les tests pour vérifier qu'ils échouent**

Run: `python3 -m unittest carto.tests.test_gateway -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'carto.collect.gateway'`

- [ ] **Step 4: Écrire l'implémentation**

```python
# carto/collect/gateway.py
"""gateway.py — inventaire depuis l'API d'administration.

Deux parties nettement separees :
  - des fonctions PURES de normalisation, testees sur les fixtures capturees
    en T0 : c'est la que vit toute la logique ;
  - une coquille HTTP mince (classe Gateway), la seule I/O du module.

Les noms de champs viennent de carto/TERRAIN.md, mesures sur le Gateway du
client. Ils ne sont jamais devines : un shape suppose est un bug silencieux.

LECTURE SEULE : ce module n'emet que des GET.
"""
import base64
import json
import urllib.request
import urllib.error

# --- constantes mesurees en T0 (carto/TERRAIN.md) -------------------------
# Mettre None quand le champ n'existe pas cote Gateway.
API_ROOT_KEY = "apis"
API_FIELDS = {"id": "id", "name": "apiName", "version": "apiVersion",
              "owner": "owner", "active": "isActive", "createdAt": "creationDate"}

APP_ROOT_KEY = "applications"
APP_FIELDS = {"id": "id", "name": "name", "owner": "owner",
              "contact": "contactEmails", "createdAt": "creationDate"}

# Chemin, dans un objet Application, vers la liste des APIs autorisees.
DECLARED_PATH = ("apis",)
# --------------------------------------------------------------------------


def _pick(obj, field):
    return obj.get(field) if field else None


def _rows(raw, root_key):
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict):
        return raw.get(root_key) or []
    return []


def _first(value):
    """Un contact peut arriver en liste (contactEmails) ou en scalaire."""
    if isinstance(value, list):
        return value[0] if value else None
    return value


def normalize_apis(raw):
    out = []
    for a in _rows(raw, API_ROOT_KEY):
        out.append({
            "id": _pick(a, API_FIELDS["id"]),
            "name": _pick(a, API_FIELDS["name"]),
            "version": _pick(a, API_FIELDS["version"]),
            "owner": _pick(a, API_FIELDS["owner"]),
            "active": bool(_pick(a, API_FIELDS["active"])),
            "createdAt": _pick(a, API_FIELDS["createdAt"]),
        })
    return out


def normalize_consumers(raw):
    out = []
    for c in _rows(raw, APP_ROOT_KEY):
        out.append({
            "id": _pick(c, APP_FIELDS["id"]),
            "name": _pick(c, APP_FIELDS["name"]),
            "owner": _pick(c, APP_FIELDS["owner"]),
            "contact": _first(_pick(c, APP_FIELDS["contact"])),
            "createdAt": _pick(c, APP_FIELDS["createdAt"]),
        })
    return out


def declared_edges(raw_apps):
    """Couples (apiId, consumerId) autorises par configuration."""
    edges = set()
    for c in _rows(raw_apps, APP_ROOT_KEY):
        con_id = _pick(c, APP_FIELDS["id"])
        node = c
        for key in DECLARED_PATH:
            node = (node or {}).get(key) if isinstance(node, dict) else None
        for item in node or []:
            api_id = item.get("apiId") or item.get("id") if isinstance(item, dict) else item
            if api_id and con_id:
                edges.add((api_id, con_id))
    return edges


class Gateway:
    """Coquille HTTP en lecture seule sur l'API d'administration."""

    def __init__(self, base_url, user, password, timeout=30):
        self.base = base_url.rstrip("/")
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        self.timeout = timeout

    def get(self, path):
        req = urllib.request.Request(self.base + path, method="GET")
        req.add_header("Accept", "application/json")
        req.add_header("Authorization", self.auth)
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            return json.loads(r.read().decode())

    def apis(self):
        return self.get("/apis")

    def applications(self):
        return self.get("/applications")
```

Adapter `API_ROOT_KEY`, `API_FIELDS`, `APP_ROOT_KEY`, `APP_FIELDS`,
`DECLARED_PATH` et les deux chemins de `Gateway.apis()` /
`Gateway.applications()` aux valeurs de `TERRAIN.md`.

- [ ] **Step 5: Lancer les tests pour vérifier qu'ils passent**

Run: `python3 -m unittest carto.tests.test_gateway -v`
Expected: PASS — 5 tests

- [ ] **Step 6: Commit**

```bash
git add carto/collect/gateway.py carto/tests/test_gateway.py
git commit -m "feat(carto): normalisation de l'inventaire et aretes declarees"
```

---

### Task 3: Agrégation du trafic et fenêtre réellement couverte

**Files:**
- Create: `carto/collect/analytics.py`
- Test: `carto/tests/test_analytics.py`

**Interfaces:**
- Consumes: `carto/tests/fixtures/aggregation-d90.json`, `oldest-event.json`,
  constantes ES de `carto/TERRAIN.md`.
- Produces: `aggregation_query(days: int) -> dict`,
  `oldest_query() -> dict`,
  `parse_aggregation(raw) -> list[dict]` (clés `apiId, consumerId, calls,
  lastCall, errors`), `covered_window(raw_oldest, requested_days, now) ->
  dict` (clés `requestedDays, coveredDays, oldestEvent`),
  `class TruncatedAggregation(Exception)`.

- [ ] **Step 1: Écrire les tests qui échouent**

```python
# carto/tests/test_analytics.py
import datetime as dt, json, pathlib, unittest
from carto.collect.analytics import (aggregation_query, oldest_query,
                                     parse_aggregation, covered_window,
                                     TruncatedAggregation)

FIX = pathlib.Path(__file__).parent / "fixtures"
UTC = dt.timezone.utc

def agg(other_api=0, other_con=0):
    return {"aggregations": {"api": {
        "sum_other_doc_count": other_api,
        "buckets": [{"key": "a1", "doc_count": 12, "consumer": {
            "sum_other_doc_count": other_con,
            "buckets": [{"key": "c1", "doc_count": 10,
                         "last": {"value_as_string": "2026-07-29T18:02:00Z"},
                         "errors": {"doc_count": 1}}]}}]}}}

class TestRequetes(unittest.TestCase):
    def test_la_requete_ne_remonte_aucun_evenement_brut(self):
        q = aggregation_query(90)
        self.assertEqual(q["size"], 0)

    def test_la_requete_porte_la_fenetre_demandee(self):
        self.assertIn("now-30d", json.dumps(aggregation_query(30)))

    def test_la_requete_du_plus_vieil_evenement_est_une_agregation_min(self):
        self.assertIn("min", json.dumps(oldest_query()))

class TestParsing(unittest.TestCase):
    def test_extrait_un_couple_api_consommateur(self):
        rows = parse_aggregation(agg())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["apiId"], "a1")
        self.assertEqual(rows[0]["consumerId"], "c1")
        self.assertEqual(rows[0]["calls"], 10)
        self.assertEqual(rows[0]["errors"], 1)
        self.assertEqual(rows[0]["lastCall"], "2026-07-29T18:02:00Z")

    def test_echoue_bruyamment_si_les_buckets_apis_sont_tronques(self):
        # une agregation tronquee produit une carto FAUSSE et non incomplete :
        # des consommateurs reels y apparaitraient comme inexistants
        with self.assertRaises(TruncatedAggregation):
            parse_aggregation(agg(other_api=7))

    def test_echoue_bruyamment_si_les_buckets_consommateurs_sont_tronques(self):
        with self.assertRaises(TruncatedAggregation):
            parse_aggregation(agg(other_con=3))

    def test_parse_la_fixture_reelle(self):
        rows = parse_aggregation(json.loads((FIX / "aggregation-d90.json").read_text()))
        for r in rows:
            self.assertIsInstance(r["calls"], int)
            self.assertIsInstance(r["apiId"], str)

class TestFenetre(unittest.TestCase):
    def test_la_fenetre_couverte_est_plafonnee_par_la_retention(self):
        raw = {"aggregations": {"oldest": {"value_as_string": "2026-06-26T00:00:00Z"}}}
        w = covered_window(raw, 90, dt.datetime(2026, 7, 30, tzinfo=UTC))
        self.assertEqual(w["requestedDays"], 90)
        self.assertEqual(w["coveredDays"], 34)

    def test_la_fenetre_couverte_ne_depasse_jamais_la_demande(self):
        raw = {"aggregations": {"oldest": {"value_as_string": "2020-01-01T00:00:00Z"}}}
        w = covered_window(raw, 90, dt.datetime(2026, 7, 30, tzinfo=UTC))
        self.assertEqual(w["coveredDays"], 90)

    def test_index_vide_donne_une_couverture_nulle(self):
        raw = {"aggregations": {"oldest": {"value": None}}}
        w = covered_window(raw, 90, dt.datetime(2026, 7, 30, tzinfo=UTC))
        self.assertEqual(w["coveredDays"], 0)
        self.assertIsNone(w["oldestEvent"])
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `python3 -m unittest carto.tests.test_analytics -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'carto.collect.analytics'`

- [ ] **Step 3: Écrire l'implémentation**

```python
# carto/collect/analytics.py
"""analytics.py — le trafic reellement observe, par agregation.

Principe (spec D3) : UNE agregation cote serveur, aucun evenement unitaire
rapatrie. C'est ce qui rend le job quasi gratuit pour la production et
independant du volume de trafic.

Terms imbriques plutot que multi_terms : portable jusqu'a Elasticsearch 6.

Piege traite ici : un bucket `terms` tronque ne produit pas une carto
incomplete mais une carto FAUSSE — des consommateurs reels y apparaitraient
comme inexistants, et une API vivante comme morte. On echoue donc bruyamment
plutot que de publier ca.
"""
import datetime as dt

# constantes mesurees en T0 (carto/TERRAIN.md)
ES_API_FIELD = "apiId"
ES_APP_FIELD = "applicationId"
ES_TIME_FIELD = "creationDate"
ES_STATUS_FIELD = "responseCode"

BUCKET_SIZE = 5000


class TruncatedAggregation(Exception):
    """Les buckets ont ete tronques : le resultat serait faux, pas partiel."""


def aggregation_query(days):
    return {
        "size": 0,
        "query": {"range": {ES_TIME_FIELD: {"gte": f"now-{days}d"}}},
        "aggs": {"api": {
            "terms": {"field": ES_API_FIELD, "size": BUCKET_SIZE},
            "aggs": {"consumer": {
                "terms": {"field": ES_APP_FIELD, "size": BUCKET_SIZE},
                "aggs": {
                    "last": {"max": {"field": ES_TIME_FIELD}},
                    "errors": {"filter": {"range": {ES_STATUS_FIELD: {"gte": 400}}}},
                }}}}},
    }


def oldest_query():
    return {"size": 0, "aggs": {"oldest": {"min": {"field": ES_TIME_FIELD}}}}


def parse_aggregation(raw):
    api_agg = (raw.get("aggregations") or {}).get("api") or {}
    truncated = []
    if api_agg.get("sum_other_doc_count", 0) > 0:
        truncated.append(f"apis (+{api_agg['sum_other_doc_count']} hors buckets)")

    rows = []
    for b in api_agg.get("buckets", []):
        con_agg = b.get("consumer") or {}
        if con_agg.get("sum_other_doc_count", 0) > 0:
            truncated.append(f"consommateurs de {b.get('key')!r}")
        for cb in con_agg.get("buckets", []):
            rows.append({
                "apiId": b.get("key"),
                "consumerId": cb.get("key"),
                "calls": cb.get("doc_count", 0),
                "lastCall": (cb.get("last") or {}).get("value_as_string"),
                "errors": (cb.get("errors") or {}).get("doc_count", 0),
            })

    if truncated:
        raise TruncatedAggregation(
            "agregation tronquee, resultat non publiable : "
            + " ; ".join(truncated)
            + f" — augmenter BUCKET_SIZE (actuellement {BUCKET_SIZE})")
    return rows


def covered_window(raw_oldest, requested_days, now):
    """La profondeur REELLEMENT disponible, jamais celle qu'on a demandee."""
    oldest_agg = (raw_oldest.get("aggregations") or {}).get("oldest") or {}
    oldest = oldest_agg.get("value_as_string")
    if not oldest:
        return {"requestedDays": requested_days, "coveredDays": 0, "oldestEvent": None}
    parsed = dt.datetime.fromisoformat(oldest.replace("Z", "+00:00"))
    covered = max(0, min(requested_days, (now - parsed).days))
    return {"requestedDays": requested_days, "coveredDays": covered, "oldestEvent": oldest}
```

- [ ] **Step 4: Lancer les tests pour vérifier qu'ils passent**

Run: `python3 -m unittest carto.tests.test_analytics -v`
Expected: PASS — 9 tests

- [ ] **Step 5: Commit**

```bash
git add carto/collect/analytics.py carto/tests/test_analytics.py
git commit -m "feat(carto): agregation du trafic, echec bruyant si buckets tronques"
```

---

### Task 4: Jointure du déclaré et de l'observé

**Files:**
- Create: `carto/collect/build.py`
- Test: `carto/tests/test_build.py`

**Interfaces:**
- Consumes: `model.SCHEMA_VERSION`, les sorties de `gateway` et `analytics`.
- Produces: `build_carto(apis, consumers, declared, observed_by_window,
  window, generated_at) -> dict` où `observed_by_window` vaut
  `{"d7": rows, "d30": rows, "d90": rows}`.

- [ ] **Step 1: Écrire les tests qui échouent — la matrice 2×2 de la spec**

```python
# carto/tests/test_build.py
import unittest
from carto.collect.build import build_carto
from carto.collect.model import SCHEMA_VERSION, validate_carto

APIS = [{"id": "a1", "name": "orders", "version": "1", "owner": "t",
         "active": True, "createdAt": None}]
CONS = [{"id": "c1", "name": "crm", "owner": "t", "contact": None, "createdAt": None},
        {"id": "c2", "name": "erp", "owner": "t", "contact": None, "createdAt": None}]
WIN = {"requestedDays": 90, "coveredDays": 90, "oldestEvent": "2026-05-01T00:00:00Z"}

def obs(rows):
    return {"d7": [], "d30": [], "d90": rows}

def edge(doc, api_id, con_id):
    return next(e for e in doc["edges"] if e["apiId"] == api_id and e["consumerId"] == con_id)

class TestMatriceDeclareObserve(unittest.TestCase):
    def test_declare_et_observe_donne_un_consommateur_actif(self):
        d = build_carto(APIS, CONS, {("a1", "c1")},
                        obs([{"apiId": "a1", "consumerId": "c1", "calls": 10,
                              "lastCall": "2026-07-29T00:00:00Z", "errors": 1}]),
                        WIN, "2026-07-30T00:00:00Z")
        e = edge(d, "a1", "c1")
        self.assertTrue(e["declared"])
        self.assertEqual(e["calls"]["d90"], 10)
        self.assertAlmostEqual(e["errorRate"], 0.1)

    def test_declare_sans_trafic_reste_visible(self):
        # le consommateur onboarde qui n'a pas encore appele : c'est LUI
        # qu'il faut prevenir lors d'une depreciation. Il ne doit jamais
        # disparaitre de la carto.
        d = build_carto(APIS, CONS, {("a1", "c2")}, obs([]), WIN, "2026-07-30T00:00:00Z")
        e = edge(d, "a1", "c2")
        self.assertTrue(e["declared"])
        self.assertEqual(e["calls"], {"d7": 0, "d30": 0, "d90": 0})
        self.assertIsNone(e["lastCall"])

    def test_observe_sans_declaration_est_conserve_et_marque(self):
        d = build_carto(APIS, CONS, set(),
                        obs([{"apiId": "a1", "consumerId": "c1", "calls": 5,
                              "lastCall": "2026-07-29T00:00:00Z", "errors": 0}]),
                        WIN, "2026-07-30T00:00:00Z")
        self.assertFalse(edge(d, "a1", "c1")["declared"])

class TestObjetsDisparus(unittest.TestCase):
    def test_du_trafic_vers_une_api_supprimee_fabrique_un_noeud_inconnu(self):
        # ne pas perdre l'information : du trafic vers un objet disparu est
        # un signal, pas un dechet
        d = build_carto(APIS, CONS, set(),
                        obs([{"apiId": "zz", "consumerId": "c1", "calls": 3,
                              "lastCall": "2026-07-29T00:00:00Z", "errors": 0}]),
                        WIN, "2026-07-30T00:00:00Z")
        ghost = next(a for a in d["apis"] if a["id"] == "zz")
        self.assertFalse(ghost["active"])
        self.assertIn("inconnu", ghost["name"])
        self.assertEqual(validate_carto(d), [])

class TestFenetres(unittest.TestCase):
    def test_les_trois_fenetres_sont_reportees(self):
        d = build_carto(APIS, CONS, set(),
                        {"d7": [{"apiId": "a1", "consumerId": "c1", "calls": 1,
                                 "lastCall": "x", "errors": 0}],
                         "d30": [{"apiId": "a1", "consumerId": "c1", "calls": 4,
                                  "lastCall": "x", "errors": 0}],
                         "d90": [{"apiId": "a1", "consumerId": "c1", "calls": 9,
                                  "lastCall": "2026-07-29T00:00:00Z", "errors": 0}]},
                        WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(edge(d, "a1", "c1")["calls"], {"d7": 1, "d30": 4, "d90": 9})

class TestDocument(unittest.TestCase):
    def test_le_document_produit_est_valide(self):
        d = build_carto(APIS, CONS, {("a1", "c1")}, obs([]), WIN, "2026-07-30T00:00:00Z")
        self.assertEqual(validate_carto(d), [])
        self.assertEqual(d["schemaVersion"], SCHEMA_VERSION)

    def test_tous_les_consommateurs_enregistres_sont_presents(self):
        # meme celui qui n'a ni declaration ni trafic : la carto est aussi
        # l'annuaire complet (besoin de communication du client)
        d = build_carto(APIS, CONS, set(), obs([]), WIN, "2026-07-30T00:00:00Z")
        self.assertEqual({c["id"] for c in d["consumers"]}, {"c1", "c2"})
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `python3 -m unittest carto.tests.test_build -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'carto.collect.build'`

- [ ] **Step 3: Écrire l'implémentation**

```python
# carto/collect/build.py
"""build.py — jointure du declare et de l'observe (spec D2).

Le coeur du produit tient dans cette matrice :

                    | trafic observe      | aucun trafic
  declare / autorise| consommateur actif  | onboarde ou en sommeil -> A PREVENIR
  non declare       | ecart de gouvernance| -

Les deux cases non triviales sont invisibles pour l'une ou l'autre source prise
seule. C'est pourquoi les aretes sont l'UNION des deux, jamais l'intersection.

Aucune I/O. Fonction pure : entrees normalisees -> document carto.json.
"""
from .model import SCHEMA_VERSION

_ZERO = {"d7": 0, "d30": 0, "d90": 0}


def _index_observed(observed_by_window):
    """(apiId, consumerId) -> {"calls": {...}, "lastCall": ..., "errors": n}"""
    idx = {}
    for window, rows in observed_by_window.items():
        for r in rows:
            key = (r["apiId"], r["consumerId"])
            slot = idx.setdefault(key, {"calls": dict(_ZERO), "lastCall": None, "errors": 0})
            slot["calls"][window] = r.get("calls", 0)
            if window == "d90":
                slot["lastCall"] = r.get("lastCall")
                slot["errors"] = r.get("errors", 0)
    return idx


def _ghost_api(api_id):
    return {"id": api_id, "name": f"(inconnu) {api_id}", "version": None,
            "owner": None, "active": False, "createdAt": None}


def _ghost_consumer(con_id):
    return {"id": con_id, "name": f"(inconnu) {con_id}", "owner": None,
            "contact": None, "createdAt": None}


def build_carto(apis, consumers, declared, observed_by_window, window, generated_at):
    apis = list(apis)
    consumers = list(consumers)
    observed = _index_observed(observed_by_window)

    api_ids = {a["id"] for a in apis}
    con_ids = {c["id"] for c in consumers}

    # Du trafic ou une autorisation vers un objet supprime est un SIGNAL.
    # On fabrique un noeud "(inconnu)" plutot que de jeter l'arete.
    for api_id, con_id in set(observed) | set(declared):
        if api_id not in api_ids:
            apis.append(_ghost_api(api_id))
            api_ids.add(api_id)
        if con_id not in con_ids:
            consumers.append(_ghost_consumer(con_id))
            con_ids.add(con_id)

    edges = []
    for key in sorted(set(observed) | set(declared)):
        api_id, con_id = key
        seen = observed.get(key)
        calls = dict(seen["calls"]) if seen else dict(_ZERO)
        errors = seen["errors"] if seen else 0
        total = calls["d90"]
        edges.append({
            "apiId": api_id,
            "consumerId": con_id,
            "declared": key in declared,
            "calls": calls,
            "lastCall": seen["lastCall"] if seen else None,
            "errorRate": round(errors / total, 4) if total else 0.0,
        })

    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": generated_at,
        "window": window,
        "apis": sorted(apis, key=lambda a: (a["name"] or "").lower()),
        "consumers": sorted(consumers, key=lambda c: (c["name"] or "").lower()),
        "edges": edges,
    }
```

- [ ] **Step 4: Lancer les tests pour vérifier qu'ils passent**

Run: `python3 -m unittest carto.tests.test_build -v`
Expected: PASS — 8 tests

- [ ] **Step 5: Commit**

```bash
git add carto/collect/build.py carto/tests/test_build.py
git commit -m "feat(carto): jointure declare x observe, noeuds fantomes conserves"
```

---

### Task 5: Journal d'évolution

**Files:**
- Create: `carto/collect/history.py`
- Test: `carto/tests/test_history.py`

**Interfaces:**
- Consumes: un document carto (sortie de `build_carto`).
- Produces: `counters(carto) -> dict` (clés `date, apis, consumersRegistered,
  consumersActive, calls`), `append_history(rows, row) -> list`.

- [ ] **Step 1: Écrire les tests qui échouent**

```python
# carto/tests/test_history.py
import unittest
from carto.collect.history import counters, append_history

def carto(edges):
    return {"generatedAt": "2026-07-30T02:11:00Z",
            "apis": [{"id": "a1"}, {"id": "a2"}],
            "consumers": [{"id": "c1"}, {"id": "c2"}, {"id": "c3"}],
            "edges": edges}

def e(api, con, d90):
    return {"apiId": api, "consumerId": con, "declared": True,
            "calls": {"d7": 0, "d30": 0, "d90": d90}, "lastCall": None, "errorRate": 0.0}

class TestCompteurs(unittest.TestCase):
    def test_compte_tous_les_consommateurs_enregistres(self):
        c = counters(carto([e("a1", "c1", 5)]))
        self.assertEqual(c["consumersRegistered"], 3)

    def test_ne_compte_actifs_que_ceux_qui_ont_appele(self):
        c = counters(carto([e("a1", "c1", 5), e("a1", "c2", 0)]))
        self.assertEqual(c["consumersActive"], 1)

    def test_somme_les_appels_de_la_fenetre(self):
        c = counters(carto([e("a1", "c1", 5), e("a2", "c2", 7)]))
        self.assertEqual(c["calls"], 12)

    def test_la_date_est_celle_de_la_collecte_sans_heure(self):
        self.assertEqual(counters(carto([]))["date"], "2026-07-30")

class TestAppend(unittest.TestCase):
    def test_ajoute_une_ligne(self):
        rows = append_history([], {"date": "2026-07-30", "apis": 1,
                                   "consumersRegistered": 1, "consumersActive": 1, "calls": 0})
        self.assertEqual(len(rows), 1)

    def test_rejouer_le_meme_jour_remplace_au_lieu_de_dupliquer(self):
        # un job relance apres echec ne doit pas creer deux points le meme jour
        base = [{"date": "2026-07-30", "apis": 1, "consumersRegistered": 1,
                 "consumersActive": 1, "calls": 0}]
        rows = append_history(base, {"date": "2026-07-30", "apis": 9,
                                     "consumersRegistered": 9, "consumersActive": 9, "calls": 9})
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["apis"], 9)

    def test_les_lignes_restent_triees_par_date(self):
        rows = append_history([{"date": "2026-07-30", "apis": 1, "consumersRegistered": 1,
                                "consumersActive": 1, "calls": 0}],
                              {"date": "2026-07-29", "apis": 2, "consumersRegistered": 2,
                               "consumersActive": 2, "calls": 0})
        self.assertEqual([r["date"] for r in rows], ["2026-07-29", "2026-07-30"])
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `python3 -m unittest carto.tests.test_history -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'carto.collect.history'`

- [ ] **Step 3: Écrire l'implémentation**

```python
# carto/collect/history.py
"""history.py — le journal d'evolution de la plateforme (spec D6).

Une ligne compacte par passage, quelques centaines d'octets. L'agregation
hebdomadaire est faite a l'AFFICHAGE, pas ici : history.json garde la verite
brute quotidienne, le rendu la lisse.

Toutes les grandeurs sont des STOCKS mesures a une date (y compris `calls`,
qui est le total sur la fenetre glissante a cette date). Consequence pour le
rendu : une semaine se resume par sa DERNIERE valeur, jamais par une somme.
"""


def counters(carto):
    active = {e["consumerId"] for e in carto["edges"] if e["calls"]["d90"] > 0}
    return {
        "date": carto["generatedAt"][:10],
        "apis": len(carto["apis"]),
        "consumersRegistered": len(carto["consumers"]),
        "consumersActive": len(active),
        "calls": sum(e["calls"]["d90"] for e in carto["edges"]),
    }


def append_history(rows, row):
    """Idempotent sur la date : un job rejoue ne duplique pas son point."""
    kept = [r for r in rows if r.get("date") != row["date"]]
    kept.append(row)
    return sorted(kept, key=lambda r: r["date"])
```

- [ ] **Step 4: Lancer les tests pour vérifier qu'ils passent**

Run: `python3 -m unittest carto.tests.test_history -v`
Expected: PASS — 7 tests

- [ ] **Step 5: Commit**

```bash
git add carto/collect/history.py carto/tests/test_history.py
git commit -m "feat(carto): journal d'evolution, idempotent par date"
```

---

### Task 6: Publication atomique et CLI

**Files:**
- Create: `carto/collect/publish.py`
- Create: `carto/collect/__main__.py`
- Test: `carto/tests/test_publish.py`

**Interfaces:**
- Consumes: tous les modules précédents.
- Produces: `publish(dest_dir, carto, history) -> None`,
  `class RefusedPublication(Exception)` ; et la CLI
  `python3 -m carto.collect --out DIR [--dry-run] [--from-fixtures DIR] [--days 90]`.

- [ ] **Step 1: Écrire les tests qui échouent**

```python
# carto/tests/test_publish.py
import json, pathlib, tempfile, unittest
from carto.collect.publish import publish, RefusedPublication

GOOD = {"schemaVersion": 1, "generatedAt": "2026-07-30T00:00:00Z",
        "window": {"requestedDays": 90, "coveredDays": 90, "oldestEvent": None},
        "apis": [{"id": "a1", "name": "orders"}],
        "consumers": [{"id": "c1", "name": "crm"}],
        "edges": [{"apiId": "a1", "consumerId": "c1", "declared": True,
                   "calls": {"d7": 0, "d30": 0, "d90": 0},
                   "lastCall": None, "errorRate": 0.0}]}
HIST = [{"date": "2026-07-30", "apis": 1, "consumersRegistered": 1,
         "consumersActive": 0, "calls": 0}]

class TestPublication(unittest.TestCase):
    def test_ecrit_les_deux_fichiers(self):
        with tempfile.TemporaryDirectory() as d:
            publish(d, GOOD, HIST)
            self.assertTrue((pathlib.Path(d) / "carto.json").exists())
            self.assertTrue((pathlib.Path(d) / "history.json").exists())

    def test_refuse_un_document_invalide(self):
        bad = dict(GOOD, apis=[])
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(RefusedPublication):
                publish(d, bad, HIST)

    def test_une_publication_refusee_laisse_la_carto_precedente_intacte(self):
        # regle D8 : ne jamais ecraser une bonne carto par une mauvaise
        with tempfile.TemporaryDirectory() as d:
            publish(d, GOOD, HIST)
            before = (pathlib.Path(d) / "carto.json").read_text()
            with self.assertRaises(RefusedPublication):
                publish(d, dict(GOOD, apis=[]), HIST)
            self.assertEqual((pathlib.Path(d) / "carto.json").read_text(), before)

    def test_ne_laisse_aucun_fichier_temporaire(self):
        with tempfile.TemporaryDirectory() as d:
            publish(d, GOOD, HIST)
            self.assertEqual(sorted(p.name for p in pathlib.Path(d).iterdir()),
                             ["carto.json", "history.json"])

    def test_le_json_ecrit_est_relisible(self):
        with tempfile.TemporaryDirectory() as d:
            publish(d, GOOD, HIST)
            self.assertEqual(json.loads((pathlib.Path(d) / "carto.json").read_text())["schemaVersion"], 1)
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `python3 -m unittest carto.tests.test_publish -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'carto.collect.publish'`

- [ ] **Step 3: Écrire `publish.py`**

```python
# carto/collect/publish.py
"""publish.py — ecriture atomique et validee (spec D8).

Regle unique de ce module : NE JAMAIS ECRASER UNE BONNE CARTO PAR UNE MAUVAISE.
Une montee de version du Gateway qui casse un champ doit laisser en place la
derniere carto valide, pas publier du vide qui aura l'air frais.

Sequence : valider -> ecrire un temporaire -> os.replace (atomique sur POSIX).
"""
import json
import os
import pathlib

from .model import validate_carto, validate_history


class RefusedPublication(Exception):
    """La collecte est degradee : on garde la publication precedente."""


def _write_atomic(path, payload):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def publish(dest_dir, carto, history):
    errs = validate_carto(carto) + validate_history(history)
    if errs:
        raise RefusedPublication(
            "publication refusee, la carto precedente est conservee :\n  - "
            + "\n  - ".join(errs))
    dest = pathlib.Path(dest_dir)
    dest.mkdir(parents=True, exist_ok=True)
    _write_atomic(dest / "carto.json", carto)
    _write_atomic(dest / "history.json", history)
```

- [ ] **Step 4: Lancer les tests pour vérifier qu'ils passent**

Run: `python3 -m unittest carto.tests.test_publish -v`
Expected: PASS — 5 tests

- [ ] **Step 5: Écrire la CLI**

```python
# carto/collect/__main__.py
"""Collecteur de la carto. LECTURE SEULE sur la production.

Config (env) :
  WM_ADMIN_URL   base admin REST du Gateway
  WM_USER/WM_PASS  compte technique LECTURE SEULE
  WM_ES_URL      base de l'API Data Store
  WM_ES_INDEX    index des evenements transactionnels

Usage :
  python3 -m carto.collect --out /var/www/carto
  python3 -m carto.collect --out /tmp/x --dry-run
  python3 -m carto.collect --out /tmp/x --from-fixtures carto/tests/fixtures
"""
import argparse
import datetime as dt
import json
import os
import pathlib
import sys
import urllib.request

from . import analytics, build, gateway, history, publish

WINDOWS = {"d7": 7, "d30": 30, "d90": 90}


def _es_search(base, index, body):
    req = urllib.request.Request(f"{base.rstrip('/')}/{index}/_search",
                                 data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode())


def _from_fixtures(d):
    d = pathlib.Path(d)
    raw = json.loads((d / "aggregation-d90.json").read_text())
    return (json.loads((d / "apis.json").read_text()),
            json.loads((d / "applications.json").read_text()),
            {w: raw for w in WINDOWS},
            json.loads((d / "oldest-event.json").read_text()))


def _from_gateway(env):
    gw = gateway.Gateway(env["WM_ADMIN_URL"], env["WM_USER"], env["WM_PASS"])
    observed = {w: _es_search(env["WM_ES_URL"], env["WM_ES_INDEX"],
                             analytics.aggregation_query(days))
                for w, days in WINDOWS.items()}
    oldest = _es_search(env["WM_ES_URL"], env["WM_ES_INDEX"], analytics.oldest_query())
    return gw.apis(), gw.applications(), observed, oldest


def main(argv=None):
    p = argparse.ArgumentParser(description="Collecte de la carto API / consommateurs")
    p.add_argument("--out", required=True, help="repertoire de publication")
    p.add_argument("--dry-run", action="store_true", help="ne publie rien, rapporte les compteurs")
    p.add_argument("--from-fixtures", help="lit des fixtures au lieu de la production")
    p.add_argument("--days", type=int, default=90, help="fenetre demandee (defaut 90)")
    args = p.parse_args(argv)

    if args.from_fixtures:
        raw_apis, raw_apps, raw_obs, raw_oldest = _from_fixtures(args.from_fixtures)
    else:
        need = ("WM_ADMIN_URL", "WM_USER", "WM_PASS", "WM_ES_URL", "WM_ES_INDEX")
        missing = [k for k in need if not os.environ.get(k)]
        if missing:
            print("variables d'environnement manquantes : " + ", ".join(missing), file=sys.stderr)
            return 2
        raw_apis, raw_apps, raw_obs, raw_oldest = _from_gateway(os.environ)

    now = dt.datetime.now(dt.timezone.utc)
    doc = build.build_carto(
        gateway.normalize_apis(raw_apis),
        gateway.normalize_consumers(raw_apps),
        gateway.declared_edges(raw_apps),
        {w: analytics.parse_aggregation(raw) for w, raw in raw_obs.items()},
        analytics.covered_window(raw_oldest, args.days, now),
        now.isoformat().replace("+00:00", "Z"),
    )
    row = history.counters(doc)

    print(f"apis={row['apis']} consommateurs={row['consumersRegistered']} "
          f"actifs={row['consumersActive']} aretes={len(doc['edges'])} "
          f"fenetre_couverte={doc['window']['coveredDays']}j")

    if args.dry_run:
        print("dry-run : rien n'a ete publie")
        return 0

    hist_path = pathlib.Path(args.out) / "history.json"
    rows = json.loads(hist_path.read_text()) if hist_path.exists() else []
    publish.publish(args.out, doc, history.append_history(rows, row))
    print(f"publie dans {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 6: Vérifier la chaîne complète sur fixtures, hors production**

```bash
python3 -m carto.collect --out /tmp/carto-check --from-fixtures carto/tests/fixtures
python3 -m unittest discover -s carto/tests -t . -v
```
Expected: la commande affiche les compteurs et « publie dans /tmp/carto-check » ;
`/tmp/carto-check/carto.json` existe et est valide ; tous les tests passent.

- [ ] **Step 7: Commit**

```bash
git add carto/collect/publish.py carto/collect/__main__.py carto/tests/test_publish.py
git commit -m "feat(carto): publication atomique validee et CLI avec dry-run"
```

---

### Task 7: Rendu — socle, bandeau de fraîcheur et table à double entrée

**Files:**
- Create: `carto/render/index.html`

**Interfaces:**
- Consumes: `carto.json`, `history.json` servis depuis le même répertoire.
- Produces: les fonctions JS globales `boot()`, `index(carto)` (retourne
  `{api, con, byApi, byCon}` — quatre `Map`), `esc(s)`, `fmt(n)`,
  `viewTable()`, montées dans `window.CARTO` pour les tâches T8 et T9.

- [ ] **Step 1: Écrire le socle**

```html
<!doctype html>
<meta charset="utf-8">
<title>Carto API et consommateurs</title>
<style>
  :root { --bg:#fff; --fg:#1a1a1a; --mut:#666; --line:#e3e3e3; --acc:#0b5fff;
          --warn:#b23c00; --ok:#0a7a3d; }
  body { margin:0; font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
         color:var(--fg); background:var(--bg); }
  header { padding:12px 20px; border-bottom:1px solid var(--line); }
  h1 { font-size:16px; margin:0 0 8px; }
  nav button { font:inherit; border:1px solid var(--line); background:#fff;
               padding:6px 12px; margin-right:4px; cursor:pointer; border-radius:4px; }
  nav button[aria-current="true"] { background:var(--acc); color:#fff; border-color:var(--acc); }
  #banner { padding:8px 20px; font-size:13px; background:#f4f7ff; border-bottom:1px solid var(--line); }
  #banner.stale { background:#fff1e8; color:var(--warn); font-weight:600; }
  main { padding:16px 20px; }
  .bar { display:flex; gap:8px; align-items:center; margin-bottom:12px; flex-wrap:wrap; }
  input[type=search], select { font:inherit; padding:6px 8px; border:1px solid var(--line); border-radius:4px; }
  table { border-collapse:collapse; width:100%; font-size:13px; }
  th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); }
  th { cursor:pointer; user-select:none; white-space:nowrap; }
  td.num { text-align:right; font-variant-numeric:tabular-nums; }
  .tag { font-size:11px; padding:1px 6px; border-radius:10px; border:1px solid var(--line); }
  .tag.declared { color:var(--ok); border-color:var(--ok); }
  .tag.undeclared { color:var(--warn); border-color:var(--warn); font-weight:600; }
  .tag.idle { color:var(--mut); }
  .muted { color:var(--mut); }
  a { color:var(--acc); cursor:pointer; }
</style>

<header>
  <h1>Carto des API et des consommateurs</h1>
  <nav id="nav"></nav>
</header>
<div id="banner">chargement…</div>
<main id="view"></main>

<script>
"use strict";
const S = { carto:null, history:[], idx:null, view:"table" };

const esc = s => String(s ?? "").replace(/[&<>"]/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;" }[c]));
const fmt = n => (n ?? 0).toLocaleString("fr-FR");
const day = iso => iso ? iso.slice(0,10) : "—";

function push(map, k, v) { (map.get(k) || map.set(k, []).get(k)).push(v); }

function index(c) {
  const api = new Map(c.apis.map(a => [a.id, a]));
  const con = new Map(c.consumers.map(x => [x.id, x]));
  const byApi = new Map(), byCon = new Map();
  for (const e of c.edges) { push(byApi, e.apiId, e); push(byCon, e.consumerId, e); }
  return { api, con, byApi, byCon };
}

function ageDays(iso) {
  return Math.floor((Date.now() - Date.parse(iso)) / 86400000);
}

function banner() {
  const b = document.getElementById("banner");
  const w = S.carto.window, age = ageDays(S.carto.generatedAt);
  const stale = age > 2;
  b.className = stale ? "stale" : "";
  b.innerHTML = (stale ? "⚠ " : "")
    + `Données du ${esc(day(S.carto.generatedAt))}`
    + (stale ? ` — <b>périmées de ${age} jours, la collecte a échoué</b>` : ` (il y a ${age} j)`)
    + ` · fenêtre réellement couverte : <b>${w.coveredDays} jours</b>`
    + (w.coveredDays < w.requestedDays
        ? ` <span class="muted">(${w.requestedDays} demandés — rétention de l'index plus courte)</span>` : "");
}

const VIEWS = [
  ["table",    "Qui consomme quoi"],
  ["annuaire", "Annuaire des consommateurs"],
  ["signaux",  "Signaux"],
  ["evolution","Évolution"],
];

function nav() {
  document.getElementById("nav").innerHTML = VIEWS.map(([k, label]) =>
    `<button data-v="${k}" aria-current="${S.view === k}">${esc(label)}</button>`).join("");
}

function render() {
  nav();
  const host = document.getElementById("view");
  if (S.view === "table")     host.innerHTML = viewTable();
  if (S.view === "annuaire")  host.innerHTML = viewAnnuaire();
  if (S.view === "signaux")   host.innerHTML = viewSignaux();
  if (S.view === "evolution") host.innerHTML = viewEvolution();
  if (S.view === "fiche")     host.innerHTML = viewFiche(S.focus);
  if (S.view === "evolution") drawEvolution();
}

document.addEventListener("click", ev => {
  const b = ev.target.closest("button[data-v]");
  if (b) { S.view = b.dataset.v; render(); return; }
  const f = ev.target.closest("a[data-focus]");
  if (f) { S.focus = f.dataset.focus; S.view = "fiche"; render(); }
});

document.addEventListener("input", ev => {
  if (ev.target.matches("[data-filter]")) { S.filter = ev.target.value.toLowerCase(); render(); }
});

async function boot() {
  try {
    S.carto = await (await fetch("carto.json", { cache:"no-store" })).json();
    try { S.history = await (await fetch("history.json", { cache:"no-store" })).json(); }
    catch (_) { S.history = []; }
  } catch (err) {
    document.getElementById("banner").className = "stale";
    document.getElementById("banner").textContent =
      "⚠ carto.json introuvable ou illisible — ouvrir cette page via le serveur web, pas en file://";
    return;
  }
  S.idx = index(S.carto);
  banner();
  render();
}

// --- vue : qui consomme quoi -------------------------------------------
function rowsTable() {
  const f = S.filter || "";
  return S.carto.edges.map(e => ({
    e,
    api: S.idx.api.get(e.apiId),
    con: S.idx.con.get(e.consumerId),
  })).filter(r =>
    !f || (r.api.name + " " + r.con.name).toLowerCase().includes(f));
}

function statut(e) {
  if (!e.declared) return '<span class="tag undeclared">non déclaré</span>';
  if (e.calls.d90 === 0) return '<span class="tag idle">déclaré, inactif</span>';
  return '<span class="tag declared">actif</span>';
}

function viewTable() {
  const rows = rowsTable().sort((a, b) => b.e.calls.d90 - a.e.calls.d90);
  return `
  <div class="bar">
    <input type="search" data-filter placeholder="filtrer par API ou consommateur…" size="34">
    <span class="muted">${fmt(rows.length)} lien(s)</span>
    <button onclick="exportCsv()">Exporter en CSV</button>
  </div>
  <table><thead><tr>
    <th>API</th><th>Consommateur</th><th>Statut</th>
    <th class="num">7 j</th><th class="num">30 j</th><th class="num">90 j</th>
    <th>Dernier appel</th><th class="num">Erreurs</th>
  </tr></thead><tbody>
  ${rows.map(r => `<tr>
    <td><a data-focus="api:${esc(r.e.apiId)}">${esc(r.api.name)}</a>
        <span class="muted">${esc(r.api.version || "")}</span></td>
    <td><a data-focus="con:${esc(r.e.consumerId)}">${esc(r.con.name)}</a></td>
    <td>${statut(r.e)}</td>
    <td class="num">${fmt(r.e.calls.d7)}</td>
    <td class="num">${fmt(r.e.calls.d30)}</td>
    <td class="num">${fmt(r.e.calls.d90)}</td>
    <td>${esc(day(r.e.lastCall))}</td>
    <td class="num">${(r.e.errorRate * 100).toFixed(1)} %</td>
  </tr>`).join("")}
  </tbody></table>`;
}

function exportCsv() {
  const head = ["api", "version", "consommateur", "contact", "declare",
                "appels_7j", "appels_30j", "appels_90j", "dernier_appel", "taux_erreur"];
  const lines = [head.join(";")].concat(rowsTable().map(r => [
    r.api.name, r.api.version || "", r.con.name, r.con.contact || "",
    r.e.declared ? "oui" : "non",
    r.e.calls.d7, r.e.calls.d30, r.e.calls.d90, r.e.lastCall || "", r.e.errorRate,
  ].map(v => `"${String(v).replace(/"/g, '""')}"`).join(";")));
  const url = URL.createObjectURL(new Blob(["﻿" + lines.join("\n")],
                                          { type:"text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url; a.download = `carto-${day(S.carto.generatedAt)}.csv`; a.click();
  URL.revokeObjectURL(url);
}

window.CARTO = { S, esc, fmt, day, index, statut };
boot();
</script>
```

Les fonctions `viewAnnuaire`, `viewSignaux`, `viewFiche`, `viewEvolution` et
`drawEvolution` sont ajoutées par T8 et T9. Tant qu'elles manquent, seuls les
onglets correspondants échouent.

- [ ] **Step 2: Vérifier à la main sur les fixtures**

```bash
python3 -m carto.collect --out /tmp/carto-web --from-fixtures carto/tests/fixtures
cp carto/render/index.html /tmp/carto-web/
python3 -m http.server 8099 --directory /tmp/carto-web
```
Ouvrir `http://localhost:8099/`. Attendu : le bandeau affiche la date et la
fenêtre réellement couverte ; la table liste les liens ; le filtre réduit les
lignes ; le bouton CSV télécharge un fichier ouvrable dans un tableur.

**Note :** ouvrir en `file://` ne marche pas — `fetch` y est bloqué. C'est
volontaire : le bandeau affiche alors le message d'erreur prévu.

- [ ] **Step 3: Commit**

```bash
git add carto/render/index.html
git commit -m "feat(carto): rendu autonome, bandeau de fraicheur et table a double entree"
```

---

### Task 8: Rendu — annuaire, fiche et signaux

**Files:**
- Modify: `carto/render/index.html` (ajouter avant `window.CARTO = ...`)

**Interfaces:**
- Consumes: `S`, `S.idx`, `esc`, `fmt`, `day`, `statut` de T7.
- Produces: `viewAnnuaire()`, `viewFiche(focus)`, `viewSignaux()`,
  `exportAnnuaire()`, `contactsFor(apiId)`.

- [ ] **Step 1: Ajouter l'annuaire et son export**

```javascript
// --- vue : annuaire des consommateurs ----------------------------------
// Toutes les Applications enregistrees, y compris celles sans aucun trafic :
// ce sont elles qu'il faut prevenir lors d'une depreciation.
function viewAnnuaire() {
  const f = S.filter || "";
  const rows = S.carto.consumers.map(c => {
    const edges = S.idx.byCon.get(c.id) || [];
    return { c, apis: edges.length, actives: edges.filter(e => e.calls.d90 > 0).length,
             calls: edges.reduce((n, e) => n + e.calls.d90, 0) };
  }).filter(r => !f || (r.c.name + " " + (r.c.owner || "")).toLowerCase().includes(f))
    .sort((a, b) => a.c.name.localeCompare(b.c.name, "fr"));

  return `
  <div class="bar">
    <input type="search" data-filter placeholder="filtrer par nom ou équipe…" size="30">
    <span class="muted">${fmt(rows.length)} consommateur(s) enregistré(s),
      dont ${fmt(rows.filter(r => r.actives === 0).length)} sans aucun appel</span>
    <button onclick="exportAnnuaire()">Exporter en CSV</button>
  </div>
  <table><thead><tr>
    <th>Consommateur</th><th>Équipe</th><th>Contact</th>
    <th class="num">APIs liées</th><th class="num">dont actives</th>
    <th class="num">Appels 90 j</th><th>Enregistré le</th>
  </tr></thead><tbody>
  ${rows.map(r => `<tr>
    <td><a data-focus="con:${esc(r.c.id)}">${esc(r.c.name)}</a></td>
    <td>${esc(r.c.owner || "—")}</td>
    <td>${esc(r.c.contact || "—")}</td>
    <td class="num">${fmt(r.apis)}</td>
    <td class="num">${r.actives === 0 ? '<span class="tag idle">0</span>' : fmt(r.actives)}</td>
    <td class="num">${fmt(r.calls)}</td>
    <td>${esc(day(r.c.createdAt))}</td>
  </tr>`).join("")}
  </tbody></table>`;
}

function exportAnnuaire() {
  const lines = [["consommateur","equipe","contact","apis_liees","apis_actives","appels_90j","enregistre_le"].join(";")];
  for (const c of S.carto.consumers) {
    const edges = S.idx.byCon.get(c.id) || [];
    lines.push([c.name, c.owner || "", c.contact || "", edges.length,
                edges.filter(e => e.calls.d90 > 0).length,
                edges.reduce((n, e) => n + e.calls.d90, 0), c.createdAt || ""]
      .map(v => `"${String(v).replace(/"/g, '""')}"`).join(";"));
  }
  const url = URL.createObjectURL(new Blob(["﻿" + lines.join("\n")],
                                           { type:"text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url; a.download = `annuaire-consommateurs-${day(S.carto.generatedAt)}.csv`; a.click();
  URL.revokeObjectURL(url);
}
```

- [ ] **Step 2: Ajouter la fiche et la liste « qui prévenir »**

```javascript
// --- vue : fiche d'un noeud --------------------------------------------
// La liste "qui prevenir" est l'UNION des declares et des observes : un
// consommateur declare qui n'a pas encore appele doit y figurer.
function contactsFor(apiId) {
  return (S.idx.byApi.get(apiId) || [])
    .map(e => S.idx.con.get(e.consumerId))
    .filter(c => c && c.contact)
    .map(c => c.contact)
    .filter((v, i, a) => a.indexOf(v) === i)
    .sort();
}

function graphSvg(centerLabel, neighbours) {
  const R = 120, cx = 180, cy = 150, n = Math.max(neighbours.length, 1);
  const pts = neighbours.map((lab, i) => {
    const t = (2 * Math.PI * i) / n - Math.PI / 2;
    return { lab, x: cx + R * Math.cos(t), y: cy + R * Math.sin(t) };
  });
  return `<svg width="360" height="300" role="img" aria-label="voisinage">
    ${pts.map(p => `<line x1="${cx}" y1="${cy}" x2="${p.x}" y2="${p.y}" stroke="#ccc"/>`).join("")}
    ${pts.map(p => `<circle cx="${p.x}" cy="${p.y}" r="5" fill="#0b5fff"/>
      <text x="${p.x}" y="${p.y - 9}" font-size="10" text-anchor="middle">${esc(p.lab)}</text>`).join("")}
    <circle cx="${cx}" cy="${cy}" r="8" fill="#1a1a1a"/>
    <text x="${cx}" y="${cy + 22}" font-size="11" text-anchor="middle" font-weight="600">${esc(centerLabel)}</text>
  </svg>`;
}

function viewFiche(focus) {
  const [kind, id] = (focus || "").split(/:(.+)/);
  if (kind === "api") {
    const a = S.idx.api.get(id);
    if (!a) return `<p>API inconnue.</p>`;
    const edges = S.idx.byApi.get(id) || [];
    const mails = contactsFor(id);
    return `
      <h2>${esc(a.name)} <span class="muted">${esc(a.version || "")}</span></h2>
      <p class="muted">Équipe : ${esc(a.owner || "—")} · ${a.active ? "active" : "inactive"}
         · enregistrée le ${esc(day(a.createdAt))}</p>
      ${graphSvg(a.name, edges.slice(0, 14).map(e => (S.idx.con.get(e.consumerId) || {}).name || "?"))}
      <h3>Qui prévenir (${mails.length} adresse(s))</h3>
      <p><textarea rows="3" style="width:100%">${esc(mails.join("; "))}</textarea></p>
      <h3>Consommateurs (${edges.length})</h3>
      <table><thead><tr><th>Consommateur</th><th>Statut</th>
        <th class="num">90 j</th><th>Dernier appel</th></tr></thead><tbody>
      ${edges.sort((x, y) => y.calls.d90 - x.calls.d90).map(e => `<tr>
        <td><a data-focus="con:${esc(e.consumerId)}">${esc((S.idx.con.get(e.consumerId) || {}).name)}</a></td>
        <td>${statut(e)}</td><td class="num">${fmt(e.calls.d90)}</td>
        <td>${esc(day(e.lastCall))}</td></tr>`).join("")}
      </tbody></table>`;
  }
  const c = S.idx.con.get(id);
  if (!c) return `<p>Consommateur inconnu.</p>`;
  const edges = S.idx.byCon.get(id) || [];
  return `
    <h2>${esc(c.name)}</h2>
    <p class="muted">Équipe : ${esc(c.owner || "—")} · contact : ${esc(c.contact || "—")}
       · enregistré le ${esc(day(c.createdAt))}</p>
    ${graphSvg(c.name, edges.slice(0, 14).map(e => (S.idx.api.get(e.apiId) || {}).name || "?"))}
    <h3>APIs (${edges.length})</h3>
    <table><thead><tr><th>API</th><th>Statut</th>
      <th class="num">90 j</th><th>Dernier appel</th></tr></thead><tbody>
    ${edges.sort((x, y) => y.calls.d90 - x.calls.d90).map(e => `<tr>
      <td><a data-focus="api:${esc(e.apiId)}">${esc((S.idx.api.get(e.apiId) || {}).name)}</a></td>
      <td>${statut(e)}</td><td class="num">${fmt(e.calls.d90)}</td>
      <td>${esc(day(e.lastCall))}</td></tr>`).join("")}
    </tbody></table>`;
}
```

- [ ] **Step 3: Ajouter les signaux**

```javascript
// --- vue : signaux ------------------------------------------------------
function viewSignaux() {
  const w = S.carto.window.coveredDays;
  const apisSansTrafic = S.carto.apis.filter(a =>
    !(S.idx.byApi.get(a.id) || []).some(e => e.calls.d90 > 0));
  const declaresInactifs = S.carto.edges.filter(e => e.declared && e.calls.d90 === 0);
  const nonDeclares = S.carto.edges.filter(e => !e.declared && e.calls.d90 > 0);
  const fantomes = S.carto.apis.concat(S.carto.consumers)
    .filter(o => (o.name || "").startsWith("(inconnu)"));
  const erreurs = S.carto.edges.filter(e => e.calls.d90 >= 100 && e.errorRate > 0.05);

  const bloc = (titre, aide, lignes) => `
    <h3>${esc(titre)} <span class="muted">(${lignes.length})</span></h3>
    <p class="muted">${esc(aide)}</p>
    ${lignes.length ? `<ul>${lignes.join("")}</ul>` : `<p class="muted">Rien à signaler.</p>`}`;

  const lienApi = id => `<a data-focus="api:${esc(id)}">${esc((S.idx.api.get(id) || {}).name)}</a>`;
  const lienCon = id => `<a data-focus="con:${esc(id)}">${esc((S.idx.con.get(id) || {}).name)}</a>`;

  return `
    <p class="muted">Signaux calculés sur la fenêtre réellement couverte : <b>${w} jours</b>.</p>
    ${bloc("APIs sans aucun appel",
           "Candidates à la décommission — vérifier d'abord qu'aucun consommateur déclaré n'attend d'y passer.",
           apisSansTrafic.map(a => `<li>${lienApi(a.id)}</li>`))}
    ${bloc("Consommateurs déclarés inactifs",
           "Autorisés mais jamais vus sur la fenêtre : à relancer, pas à supprimer. Ils doivent être prévenus des changements.",
           declaresInactifs.map(e => `<li>${lienCon(e.consumerId)} → ${lienApi(e.apiId)}</li>`))}
    ${bloc("Trafic sans autorisation déclarée",
           "Écart de gouvernance : du trafic observé sans lien déclaré correspondant. À investiguer.",
           nonDeclares.map(e => `<li>${lienCon(e.consumerId)} → ${lienApi(e.apiId)}
             <span class="muted">${fmt(e.calls.d90)} appels</span></li>`))}
    ${bloc("Objets disparus encore appelés",
           "Le trafic référence un identifiant absent de l'inventaire : objet supprimé, ou appelant non identifié.",
           fantomes.map(o => `<li>${esc(o.name)}</li>`))}
    ${bloc("Taux d'erreur anormal",
           "Plus de 5 % d'erreurs sur au moins 100 appels.",
           erreurs.map(e => `<li>${lienCon(e.consumerId)} → ${lienApi(e.apiId)}
             <span class="muted">${(e.errorRate * 100).toFixed(1)} %</span></li>`))}`;
}
```

- [ ] **Step 4: Vérifier à la main**

```bash
python3 -m carto.collect --out /tmp/carto-web --from-fixtures carto/tests/fixtures
cp carto/render/index.html /tmp/carto-web/
python3 -m http.server 8099 --directory /tmp/carto-web
```
Attendu : l'onglet Annuaire liste **tous** les consommateurs, y compris ceux à
zéro appel ; cliquer un nom ouvre sa fiche ; la fiche d'une API affiche une
liste d'adresses sélectionnable ; l'onglet Signaux affiche les cinq blocs.

- [ ] **Step 5: Commit**

```bash
git add carto/render/index.html
git commit -m "feat(carto): annuaire complet, fiche avec liste a prevenir, signaux"
```

---

### Task 9: Rendu — évolution hebdomadaire à deux séries

**Files:**
- Modify: `carto/render/index.html` (ajouter avant `window.CARTO = ...`)

**Interfaces:**
- Consumes: `S.history`, `S.carto.apis[].createdAt`, `S.carto.consumers[].createdAt`.
- Produces: `weekKey(date)`, `weekly(rows)`, `retroSeries()`, `viewEvolution()`,
  `drawEvolution()`.

- [ ] **Step 1: Lire `carto/TERRAIN.md` (V1) avant d'écrire**

Si `createdAt` est **ABSENT** des APIs et des Applications, la série
rétro-calculée est impossible : n'implémenter que la série mesurée, retirer
`retroSeries()` et l'encart de réserve, et le signaler dans le `README.md`.
Ne pas fabriquer de dates de création de substitution.

- [ ] **Step 2: Ajouter l'agrégation hebdomadaire et les séries**

```javascript
// --- vue : evolution ----------------------------------------------------
// Toutes les grandeurs du journal sont des STOCKS mesures a une date : une
// semaine se resume par sa DERNIERE valeur, jamais par une somme.
function weekKey(date) {
  const d = new Date(date + "T00:00:00Z");
  const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  t.setUTCDate(t.getUTCDate() + 4 - (t.getUTCDay() || 7));   // jeudi ISO
  const y0 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
  const w = Math.ceil(((t - y0) / 86400000 + 1) / 7);
  return `${t.getUTCFullYear()}-S${String(w).padStart(2, "0")}`;
}

function weekly(rows) {
  const byWeek = new Map();
  for (const r of [...rows].sort((a, b) => a.date.localeCompare(b.date))) {
    byWeek.set(weekKey(r.date), r);          // la derniere du groupe l'emporte
  }
  return [...byWeek.entries()].map(([k, r]) => ({ ...r, week: k }));
}

// Serie RETRO-CALCULEE a partir des dates d'enregistrement : disponible des le
// premier passage, mais c'est une courbe de SURVIVANTS — elle ne connait que
// les objets existant encore aujourd'hui, donc elle sous-estime le passe et ne
// montre aucune disparition. Elle est tracee en pointilles, jamais melangee
// visuellement avec la serie mesuree.
function retroSeries() {
  const dates = [];
  for (const a of S.carto.apis) if (a.createdAt) dates.push([a.createdAt.slice(0,10), "api"]);
  for (const c of S.carto.consumers) if (c.createdAt) dates.push([c.createdAt.slice(0,10), "con"]);
  if (!dates.length) return [];
  dates.sort((x, y) => x[0].localeCompare(y[0]));
  const out = new Map();
  let apis = 0, cons = 0;
  for (const [d, kind] of dates) {
    if (kind === "api") apis++; else cons++;
    out.set(weekKey(d), { week: weekKey(d), apis, consumersRegistered: cons });
  }
  return [...out.values()];
}
```

- [ ] **Step 3: Ajouter la vue et le tracé**

```javascript
function viewEvolution() {
  const mes = weekly(S.history), retro = retroSeries();
  if (!mes.length && !retro.length) {
    return `<p>Aucun historique pour l'instant. La courbe se construit à partir
            du premier passage du collecteur.</p>`;
  }
  const last = mes[mes.length - 1], prev = mes[mes.length - 5];
  const delta = (k) => prev ? (last[k] - prev[k] >= 0 ? "+" : "") + fmt(last[k] - prev[k]) : "—";
  return `
    <div class="bar">
      ${last ? `<span>Aujourd'hui : <b>${fmt(last.apis)}</b> APIs,
        <b>${fmt(last.consumersRegistered)}</b> consommateurs enregistrés
        dont <b>${fmt(last.consumersActive)}</b> actifs.</span>
        <span class="muted">Sur 4 semaines : ${delta("apis")} APIs,
        ${delta("consumersRegistered")} consommateurs.</span>` : ""}
    </div>
    <canvas id="chart" width="900" height="320" style="max-width:100%"></canvas>
    <p class="muted" style="max-width:70ch">
      <b>Deux séries, deux fiabilités.</b> Le trait plein est <b>mesuré</b> :
      un point par semaine depuis la mise en service du collecteur, il est exact.
      Le pointillé est <b>rétro-calculé</b> à partir des dates d'enregistrement
      des objets existant <i>aujourd'hui</i> : c'est une courbe de survivants,
      elle sous-estime le passé et ne montre aucune disparition. Ne pas en
      déduire que la plateforme n'a jamais perdu de consommateur.
    </p>
    <table><thead><tr><th>Semaine</th><th class="num">APIs</th>
      <th class="num">Consommateurs</th><th class="num">dont actifs</th>
      <th class="num">Appels (fenêtre)</th></tr></thead><tbody>
    ${[...mes].reverse().map(r => `<tr><td>${esc(r.week)}</td>
      <td class="num">${fmt(r.apis)}</td>
      <td class="num">${fmt(r.consumersRegistered)}</td>
      <td class="num">${fmt(r.consumersActive)}</td>
      <td class="num">${fmt(r.calls)}</td></tr>`).join("")}
    </tbody></table>`;
}

function drawEvolution() {
  const cv = document.getElementById("chart");
  if (!cv) return;
  const mes = weekly(S.history), retro = retroSeries();
  const weeks = [...new Set(retro.concat(mes).map(r => r.week))].sort();
  if (!weeks.length) return;
  const x = w => 50 + (weeks.indexOf(w) / Math.max(weeks.length - 1, 1)) * (cv.width - 70);
  const max = Math.max(1, ...mes.map(r => Math.max(r.apis, r.consumersRegistered)),
                          ...retro.map(r => Math.max(r.apis, r.consumersRegistered)));
  const y = v => cv.height - 40 - (v / max) * (cv.height - 60);

  const g = cv.getContext("2d");
  g.clearRect(0, 0, cv.width, cv.height);
  g.strokeStyle = "#e3e3e3"; g.beginPath();
  g.moveTo(50, cv.height - 40); g.lineTo(cv.width - 20, cv.height - 40); g.stroke();

  const line = (rows, key, color, dashed) => {
    const pts = rows.filter(r => r[key] != null);
    if (!pts.length) return;
    g.setLineDash(dashed ? [4, 4] : []);
    g.strokeStyle = color; g.lineWidth = 2; g.beginPath();
    pts.forEach((r, i) => i ? g.lineTo(x(r.week), y(r[key])) : g.moveTo(x(r.week), y(r[key])));
    g.stroke(); g.setLineDash([]);
  };

  line(retro, "apis", "#0b5fff", true);
  line(retro, "consumersRegistered", "#0a7a3d", true);
  line(mes, "apis", "#0b5fff", false);
  line(mes, "consumersRegistered", "#0a7a3d", false);
  line(mes, "consumersActive", "#b23c00", false);

  g.fillStyle = "#666"; g.font = "11px system-ui";
  g.fillText(weeks[0], 50, cv.height - 22);
  g.fillText(weeks[weeks.length - 1], cv.width - 90, cv.height - 22);
  g.fillStyle = "#0b5fff"; g.fillText("APIs", 55, 16);
  g.fillStyle = "#0a7a3d"; g.fillText("consommateurs enregistrés", 100, 16);
  g.fillStyle = "#b23c00"; g.fillText("actifs", 270, 16);
  g.fillStyle = "#666";    g.fillText("pointillé = rétro-calculé (survivants)", 320, 16);
}
```

- [ ] **Step 4: Vérifier à la main avec un historique fabriqué**

```bash
python3 -m carto.collect --out /tmp/carto-web --from-fixtures carto/tests/fixtures
python3 - <<'EOF'
import json, datetime as dt, pathlib
rows = [{"date": (dt.date(2026,7,30) - dt.timedelta(days=7*i)).isoformat(),
         "apis": 120 - i, "consumersRegistered": 96 - 2*i,
         "consumersActive": 71 - i, "calls": 1000000 * (12 - i)} for i in range(12)][::-1]
pathlib.Path("/tmp/carto-web/history.json").write_text(json.dumps(rows))
EOF
cp carto/render/index.html /tmp/carto-web/
python3 -m http.server 8099 --directory /tmp/carto-web
```
Attendu : l'onglet Évolution affiche un graphe à points hebdomadaires, le
pointillé visuellement distinct du trait plein, le delta 4 semaines, le
paragraphe de réserve, et la table des semaines la plus récente en tête.

- [ ] **Step 5: Commit**

```bash
git add carto/render/index.html
git commit -m "feat(carto): evolution hebdomadaire, serie retro-calculee distinguee"
```

---

### Task 10: Déploiement, planification et alerte

**Files:**
- Create: `carto/ansible/roles/carto_collect/defaults/main.yml`
- Create: `carto/ansible/roles/carto_collect/tasks/main.yml`
- Create: `carto/ansible/roles/carto_collect/templates/carto-collect.sh.j2`
- Create: `carto/README.md`

**Interfaces:**
- Consumes: `carto/collect/`, `carto/render/index.html`, `carto/TERRAIN.md` (V6).
- Produces: un job planifié qui publie dans `carto_web_root`, et une alerte en
  cas d'échec.

- [ ] **Step 1: Écrire les valeurs par défaut du rôle**

```yaml
# carto/ansible/roles/carto_collect/defaults/main.yml
# carto_install_dir est le PARENT du paquet : le code vit dans
# {{ carto_install_dir }}/carto/. On invoque donc `python3 -m carto.collect`
# exactement comme depuis le depot — une seule commande a connaitre.
carto_install_dir: /opt/carto-app
# Racine du livrable sur la machine qui joue le playbook (le repertoire carto/).
# `copy` avec un src relatif chercherait dans files/ du role : on passe donc un
# chemin absolu.
carto_source_dir: "{{ playbook_dir }}/../.."
carto_web_root: /var/www/carto          # V6 — cible mesuree chez le client
carto_user: carto
carto_schedule_hour: "2"
carto_schedule_minute: "11"
carto_window_days: 90
carto_alert_command: "logger -t carto -p user.err"   # a remplacer par le canal du client
# Identifiants : jamais dans le depot. Fournis par le coffre a l'execution.
carto_env:
  WM_ADMIN_URL: ""
  WM_USER: ""
  WM_PASS: ""
  WM_ES_URL: ""
  WM_ES_INDEX: ""
```

- [ ] **Step 2: Écrire l'enveloppe d'exécution**

```bash
# carto/ansible/roles/carto_collect/templates/carto-collect.sh.j2
#!/usr/bin/env bash
# Collecte de la carto. LECTURE SEULE sur la production.
# Regle (spec D9) : un echec silencieux produit PIRE que rien — une carto
# perimee qui a l'air fraiche. On alerte donc systematiquement, et on laisse
# en place la derniere carto valide.
set -uo pipefail
export WM_ADMIN_URL={{ carto_env.WM_ADMIN_URL | quote }}
export WM_USER={{ carto_env.WM_USER | quote }}
export WM_PASS={{ carto_env.WM_PASS | quote }}
export WM_ES_URL={{ carto_env.WM_ES_URL | quote }}
export WM_ES_INDEX={{ carto_env.WM_ES_INDEX | quote }}

LOG=$(mktemp)
# La sortie peut contenir des elements d'infrastructure : elle va dans un
# fichier, jamais sur la sortie standard du planificateur.
if python3 -m carto.collect --out {{ carto_web_root }} --days {{ carto_window_days }} >"$LOG" 2>&1
then
  install -m 0644 {{ carto_install_dir }}/carto/render/index.html {{ carto_web_root }}/index.html
  rm -f "$LOG"
  exit 0
fi

{{ carto_alert_command }} "collecte de la carto EN ECHEC — la carto publiee date de la veille ou avant"
cp "$LOG" {{ carto_install_dir }}/last-failure.log
chmod 0600 {{ carto_install_dir }}/last-failure.log
rm -f "$LOG"
exit 1
```

- [ ] **Step 3: Écrire les tâches du rôle**

```yaml
# carto/ansible/roles/carto_collect/tasks/main.yml
- name: Compte de service dédié
  ansible.builtin.user:
    name: "{{ carto_user }}"
    system: true
    shell: /usr/sbin/nologin

- name: Répertoire d'installation
  ansible.builtin.file:
    path: "{{ carto_install_dir }}"
    state: directory
    owner: "{{ carto_user }}"
    mode: "0755"

- name: Dépôt du paquet — collecteur, rendu et marqueur d'import
  ansible.builtin.copy:
    src: "{{ carto_source_dir }}/{{ item }}"
    dest: "{{ carto_install_dir }}/carto/"
    owner: "{{ carto_user }}"
    mode: "0644"
  loop:
    - collect
    - render
    - __init__.py

- name: Racine web de publication
  ansible.builtin.file:
    path: "{{ carto_web_root }}"
    state: directory
    owner: "{{ carto_user }}"
    mode: "0755"

- name: Enveloppe d'exécution
  ansible.builtin.template:
    src: carto-collect.sh.j2
    dest: "{{ carto_install_dir }}/carto-collect.sh"
    owner: "{{ carto_user }}"
    mode: "0700"
  no_log: true          # le gabarit porte les identifiants

- name: Planification quotidienne
  ansible.builtin.cron:
    name: carto-collect
    user: "{{ carto_user }}"
    hour: "{{ carto_schedule_hour }}"
    minute: "{{ carto_schedule_minute }}"
    job: "cd {{ carto_install_dir }} && ./carto-collect.sh"

- name: Vérification — la chaîne tourne en dry-run sans rien publier
  ansible.builtin.command:
    cmd: python3 -m carto.collect --out /tmp/carto-verify --dry-run
    chdir: "{{ carto_install_dir }}"
  environment: "{{ carto_env }}"
  become_user: "{{ carto_user }}"
  changed_when: false
  register: carto_verify

- name: Vérification — la collecte a bien vu des APIs
  ansible.builtin.assert:
    that: "'apis=0' not in carto_verify.stdout"
    fail_msg: "la collecte ne voit aucune API : identifiants ou chemins d'administration à revoir"
```

- [ ] **Step 4: Écrire le README d'exploitation**

```markdown
# Carto des API et des consommateurs

Job planifié en **lecture seule** qui produit `carto.json` + `history.json`, et
un site statique autonome qui les lit. Le rendu ne touche jamais la production.

Spec : `docs/superpowers/specs/2026-07-30-carto-api-consommateurs-design.md`
Terrain mesuré chez le client : `TERRAIN.md`

## Lancer à la main

    python3 -m carto.collect --out /var/www/carto              # publie
    python3 -m carto.collect --out /tmp/x --dry-run            # ne publie rien
    python3 -m carto.collect --out /tmp/x --from-fixtures carto/tests/fixtures

## Tests

    python3 -m unittest discover -s carto/tests -t . -v

Aucune dépendance, aucun accès réseau : tout tourne sur les fixtures.

## Diagnostic

| Symptôme | Cause | Geste |
|---|---|---|
| Bandeau orange « données périmées » | le job échoue depuis N jours | lire `last-failure.log` (root, 0600) |
| `publication refusee` | collecte dégradée, ancienne carto conservée | comparer les compteurs du `--dry-run` |
| `agregation tronquee` | plus d'objets que `BUCKET_SIZE` | augmenter `BUCKET_SIZE` dans `analytics.py` |
| `fenêtre couverte` < demandée | rétention des index plus courte | normal, c'est la vérité (spec D4) |
| Page vide, bandeau d'erreur | page ouverte en `file://` | passer par le serveur web |

## Ce qu'il faut entretenir

- La rotation du compte technique lecture seule.
- La surveillance de l'échec du job : un échec silencieux publierait une carto
  périmée qui a l'air fraîche.
- À chaque montée de version du Gateway : rejouer `capture-fixtures.sh`,
  relancer les tests, mettre à jour `TERRAIN.md` si un champ a bougé.
```

- [ ] **Step 5: Vérifier la syntaxe et la suite complète**

```bash
python3 -m unittest discover -s carto/tests -t . -v
ansible-playbook --syntax-check -i localhost, \
  -e @/dev/null carto/ansible/roles/carto_collect/tasks/main.yml || true
python3 -m py_compile carto/collect/*.py
```
Expected: tous les tests passent ; `py_compile` silencieux.

- [ ] **Step 6: Commit**

```bash
git add carto/ansible carto/README.md
git commit -m "feat(carto): deploiement, planification quotidienne et echec bruyant"
```

---

## Couverture de la spec

| Exigence | Tâche |
|---|---|
| D1 séparation collecte/rendu | T1 (contrat), T6 (CLI), T7 (rendu isolé) |
| D2 déclaré × observé, matrice 2×2 | T2 (déclaré), T3 (observé), T4 (jointure + tests de la matrice) |
| D3 une seule agrégation, aucun événement brut | T3 |
| D4 fenêtre réellement couverte | T3 (`covered_window`), T7 (bandeau) |
| D5 table principale, graphe focalisé | T7 (table), T8 (`graphSvg` en fiche) |
| D6 évolution comme donnée, hebdo | T5 (`history.json`), T9 (`weekly`) |
| D7 rétro-calcul + réserve écrite | T9 (`retroSeries`, paragraphe de réserve) |
| D8 ne jamais écraser une bonne carto | T1 (refus du vide), T6 (`publish`) |
| D9 échec bruyant | T7 (bandeau périmé), T10 (alerte + `last-failure.log`) |
| Vue Annuaire pour la communication | T8 |
| Vue Signaux | T8 |
| Export CSV | T7 (liens), T8 (annuaire) |
| Tests sur fixtures, sans prod | T0 (capture), T1–T6 |
| V1–V6 mesurés avant de coder | T0, relu en T2, T3, T9, T10 |
