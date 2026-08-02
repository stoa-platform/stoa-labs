# Lot 1 — Proxification complète de l'API d'administration

> **Pour les agents :** SOUS-SKILL REQUIS — utiliser `superpowers:subagent-driven-development`
> (recommandé) ou `superpowers:executing-plans` pour dérouler ce plan tâche par tâche.
> Les étapes sont en cases à cocher (`- [ ]`).

**But :** rendre la chaîne CI capable de passer **intégralement** par le proxy OAuth2 de
l'API d'administration — aujourd'hui elle tomberait en 404 sur quatre endpoints qu'elle
utilise sans les avoir déclarés, et le proxy n'est posé que sur le banc docker-compose.

**Architecture :** le proxy est une API de la gateway wM elle-même (ADR-075), portant un
contrat OpenAPI en **allow-list** : tout chemin hors contrat rend 404. Le lot élargit ce
contrat à l'usage réel, le rend opposable par un linter qui n'a besoin d'aucune gateway,
puis pose le proxy sur le cluster et y bascule les jobs.

**Pile :** OpenAPI 3.0.3, Ansible (rôles `apim_*`), Jenkins declarative pipeline, `labctl`
(Go), Vault, Python 3.11 + PyYAML 6 pour l'outillage de vérification.

## Contraintes globales

- **Dépôt PUBLIC.** Aucun nom, adresse ou secret client. Aucun secret en clair, jamais
  en `argv`, jamais dans une trace : les valeurs sensibles se lisent depuis un fichier
  root-only du nœud ou depuis Vault.
- **Invariants d'ADR-075, non négociables sans décision explicite :** allow-list de
  chemins, hors contrat → 404, **aucun DELETE**, entrée OAuth2 scopée.
- **Fail-closed.** Toute écriture d'administration se relit. Ne jamais conclure sur le
  code de retour : wM 10.15 rend des `200` qui ne font rien quand un champ requis manque.
- **Réplique unique pour les écritures.** Toute écriture et toute relecture visent le
  Service d'administration épinglé (`wm-apigateway-admin`), jamais le Service réparti :
  les deux répliques ne synchronisent pas leur cache et un `401` y est un faux négatif.
- **Ansible implémente, Newman sonde.** Pas d'orchestration en Newman.
- **Commits fréquents**, un par tâche, message en français, `Co-Authored-By` conservé.

## Structure des fichiers

| Fichier | Responsabilité |
| --- | --- |
| `poc-control-plane-federation/ci/lint-contrat-proxy.py` | **créé** — confronte le contrat du proxy aux appels réels des rôles. Aucune gateway requise. |
| `poc-control-plane-federation/gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml` | **modifié** — contrat d'allow-list : endpoints manquants, corps multipart. |
| `poc-control-plane-federation/ci/sonde-multipart-proxy.sh` | **créé** — prouve qu'un multipart traverse réellement le proxy. |
| `poc-control-plane-federation/scripts/setup-wm-admin-self-proxy.sh` | **modifié** — valeurs docker-compose devenues paramètres. |
| `poc-control-plane-federation/ci/jenkins/*.job.xml` | **modifiés** — paramètres OAuth2 du mode proxy. |
| `poc-control-plane-federation/adr/adr-075-wm-admin-proxy-multienv.md` | **modifié** — trace de la décision sur le DELETE. |

---

### Tâche 1 : Rendre l'écart contrat↔usage opposable

Le défaut est aujourd'hui **invisible** : en `ADMIN_VIA=direct` tout marche, et le 404
n'apparaîtrait qu'au moment de basculer. Ce linter le fait apparaître sans gateway.

**Fichiers :**
- Créer : `poc-control-plane-federation/ci/lint-contrat-proxy.py`

**Interfaces :**
- Produit : un exécutable qui rend `0` si le contrat couvre tous les appels, `1` sinon.
  `--liste` imprime l'inventaire. Consommé par les tâches 2, 3 et 4 comme test de
  non-régression.

- [ ] **Étape 1 : écrire le linter**

Il fait trois choses : lire les opérations déclarées par le contrat ; parcourir les rôles
en YAML pour relever chaque tâche `uri` visant `{{ apim_ss_api_base }}` ; confronter.

Trois pièges du terrain, tous rencontrés à l'écriture, qui expliquent la forme du code :
une expression Jinja peut s'étendre **sur plusieurs lignes** (d'où `flags=re.S`) ; la
**méthode elle-même** peut être un conditionnel Jinja (`{{ 'PUT' if … else 'POST' }}`) ;
et un `{{ … }}` **collé** à un segment désigne un segment optionnel, donc deux chemins
possibles.

```python
#!/usr/bin/env python3
"""Le contrat d'allow-list du proxy d'admin couvre-t-il ce que les roles appellent ?

Hors contrat -> 404 (ADR-075). Un appel non declare ne casse donc QU'EN mode
proxy-oauth2, jamais en direct : le defaut est invisible tant qu'on teste en
direct. Ce linter le rend opposable sans gateway.

Sans argument : verifie. `--liste` : imprime l'inventaire des appels.
"""
import os
import re
import sys

import yaml

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRAT = os.path.join(RACINE, "gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml")
ROLES = os.path.join(RACINE, "ansible/roles")
PREFIXE = "/rest/apigateway"
BASE = "{{ apim_ss_api_base }}"


def operations_declarees():
    doc = yaml.safe_load(open(CONTRAT, encoding="utf-8"))
    ops = set()
    for chemin, corps in (doc.get("paths") or {}).items():
        for verbe in corps:
            if verbe.lower() in ("get", "put", "post", "delete", "patch"):
                ops.add((verbe.upper(), chemin))
    return ops, doc


def variantes(url):
    """Normalise une URL de tache en un ou plusieurs chemins de contrat.

    - la query string ne fait pas partie du chemin OpenAPI ;
    - `{{ x }}` colle a un segment => segment OPTIONNEL (Jinja conditionnel :
      `/policyActions{{ ('/' ~ id) if id else '' }}` rend les DEUX formes).
    """
    chemin = url[len(BASE):].split("?", 1)[0]
    colle = re.search(r"[^/]\{\{", chemin)
    formes = {re.sub(r"\{\{.*?\}\}", "{id}", chemin, flags=re.S)}
    if colle:
        formes.add(re.sub(r"\{\{.*?\}\}", "", chemin, flags=re.S))
    return {PREFIXE + f.rstrip("/") if f != "/" else PREFIXE for f in formes}


def taches_uri(noeud, fichier, sortie):
    """Descend recursivement : les taches vivent sous des block/rescue/always."""
    if isinstance(noeud, list):
        for n in noeud:
            taches_uri(n, fichier, sortie)
    elif isinstance(noeud, dict):
        for cle, val in noeud.items():
            if cle in ("ansible.builtin.uri", "uri") and isinstance(val, dict):
                url = val.get("url", "")
                if isinstance(url, str) and url.startswith(BASE):
                    brut = str(val.get("method", "GET"))
                    methodes = ([m.upper() for m in re.findall(r"'(\w+)'", brut)]
                                if "{{" in brut else [brut.upper()])
                    sortie.append({
                        "methodes": methodes,
                        "url": url,
                        "multipart": val.get("body_format") == "form-multipart",
                        "ou": f"{os.path.relpath(fichier, RACINE)}",
                        "nom": noeud.get("name", "?"),
                    })
            else:
                taches_uri(val, fichier, sortie)


def appels():
    trouves = []
    for dossier, _, fichiers in os.walk(ROLES):
        for f in fichiers:
            if not f.endswith((".yml", ".yaml")):
                continue
            p = os.path.join(dossier, f)
            try:
                doc = yaml.safe_load(open(p, encoding="utf-8"))
            except yaml.YAMLError:
                continue
            taches_uri(doc, p, trouves)
    return trouves


def main():
    declarees, doc = operations_declarees()
    trouves = appels()

    if "--liste" in sys.argv:
        for a in sorted(trouves, key=lambda x: (x["url"], x["methodes"])):
            mp = " [multipart]" if a["multipart"] else ""
            print(f'{"/".join(a["methodes"]):6} {a["url"]}{mp}\n       {a["ou"]} — {a["nom"]}')
        return 0

    manquants, sans_multipart = [], []
    for a in trouves:
        formes = variantes(a["url"])
        if not any((m, f) in declarees for f in formes for m in a["methodes"]):
            manquants.append(("/".join(a["methodes"]), sorted(formes)[0], a["ou"], a["nom"]))
            continue
        if a["multipart"]:
            forme, meth = next((f, m) for f in formes for m in a["methodes"] if (m, f) in declarees)
            op = doc["paths"][forme][meth.lower()]
            rb = op.get("requestBody", {})
            ref = rb.get("$ref", "")
            if ref.startswith("#/"):
                cible = doc
                for seg in ref[2:].split("/"):
                    cible = cible.get(seg, {})
                rb = cible
            if "multipart/form-data" not in (rb.get("content") or {}):
                sans_multipart.append((meth, forme, a["ou"], a["nom"]))

    ko = 0
    if manquants:
        ko = 1
        print(f"✗ {len(manquants)} appel(s) NON DECLARE(S) — 404 a travers le proxy :")
        for m, c, ou, nom in sorted(set(manquants)):
            print(f"    {m:6} {c}\n           {ou} — {nom}")
    if sans_multipart:
        ko = 1
        print(f"✗ {len(sans_multipart)} appel(s) en form-multipart sans requestBody multipart declare :")
        for m, c, ou, nom in sorted(set(sans_multipart)):
            print(f"    {m:6} {c}\n           {ou} — {nom}")
    if not ko:
        print(f"✓ les {len(trouves)} appels des roles sont couverts par le contrat "
              f"({len(declarees)} operations declarees)")
    return ko


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Étape 2 : le faire tourner et constater qu'il est ROUGE**

```bash
cd poc-control-plane-federation && chmod +x ci/lint-contrat-proxy.py && python3 ci/lint-contrat-proxy.py
```

Attendu : code retour **1**, et exactement cette liste — 7 appels non déclarés portant sur
4 endpoints distincts, plus 2 appels multipart non couverts :

```
✗ 7 appel(s) NON DECLARE(S) — 404 a travers le proxy :
    DELETE /rest/apigateway/strategies/{id}      (apim_selfservice_app/tasks/rotate-strategy.yml)
    GET    /rest/apigateway/accessProfiles       (apim_publish_api + apim_selfservice_app /tasks/team.yml)
    GET    /rest/apigateway/archive              (apim_promote_api/tasks/export.yml)
    POST   /rest/apigateway/archive              (apim_promote_api/tasks/import.yml)
    POST   /rest/apigateway/assets/team          (apim_publish_api + apim_selfservice_app /tasks/team.yml)
✗ 2 appel(s) en form-multipart sans requestBody multipart declare :
    POST   /rest/apigateway/apis                 (apim_publish_api/tasks/main.yml)
    PUT    /rest/apigateway/apis/{id}            (apim_publish_api/tasks/main.yml)
```

Si la liste diffère, **ne pas continuer** : soit les rôles ont bougé, soit le linter a un
défaut de normalisation. Relancer avec `--liste` pour voir l'inventaire brut.

- [ ] **Étape 3 : vérifier l'inventaire**

```bash
python3 ci/lint-contrat-proxy.py --liste | wc -l
```

Attendu : deux lignes par appel relevé. Contrôle de bon sens que le parcours des rôles
n'a rien laissé de côté.

- [ ] **Étape 4 : commit**

```bash
git add poc-control-plane-federation/ci/lint-contrat-proxy.py
git commit -m "test(ci): rendre opposable l'ecart entre le contrat du proxy et l'usage reel

Hors contrat -> 404 (ADR-075), mais le defaut est INVISIBLE en ADMIN_VIA=direct :
il n'apparaitrait qu'a la bascule. Ce linter le montre sans gateway. Rouge a
l'ecriture : 7 appels non declares sur 4 endpoints, 2 multipart non couverts.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 2 : Déclarer le corps multipart

La création d'API **doit** être en multipart : le JSON from-scratch est cassé sur 10.15
(commentaire de `apim_publish_api/tasks/main.yml`). Or `labctl` appelle ces mêmes chemins
en JSON. Les deux types de contenu sont donc légitimes sur `/apis` et `/apis/{id}`.

**Fichiers :**
- Modifier : `poc-control-plane-federation/gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml`

**Interfaces :**
- Consomme : le linter de la tâche 1.
- Produit : le composant `#/components/requestBodies/passthroughJsonOrMultipart`, réutilisé
  par la tâche 3 pour `POST /archive`.

- [ ] **Étape 1 : ajouter le composant**

Dans `components.requestBodies`, à la suite de `passthrough` :

```yaml
    # Certains gestes d'admin 10.15 n'acceptent QUE le multipart (l'import d'API
    # from-scratch en JSON est casse sur cette version), tandis que labctl attaque
    # les memes chemins en JSON. Les deux sont donc legitimes — et un contrat qui
    # ne declare que le JSON fait tomber la chaine Ansible a travers le proxy.
    passthroughJsonOrMultipart:
      required: true
      content:
        application/json:
          schema:
            type: object
            additionalProperties: true
        multipart/form-data:
          schema:
            type: object
            additionalProperties: true
```

- [ ] **Étape 2 : basculer les deux opérations concernées**

Sur `/rest/apigateway/apis` (verbe `post`) et `/rest/apigateway/apis/{id}` (verbe `put`),
remplacer :

```yaml
      requestBody: { $ref: "#/components/requestBodies/passthrough" }
```

par :

```yaml
      requestBody: { $ref: "#/components/requestBodies/passthroughJsonOrMultipart" }
```

- [ ] **Étape 3 : le linter ne doit plus signaler de multipart**

```bash
python3 ci/lint-contrat-proxy.py
```

Attendu : la section « appel(s) en form-multipart sans requestBody multipart declare »
**a disparu**. La section des 7 non déclarés est toujours là — c'est la tâche 3.

- [ ] **Étape 4 : le contrat reste un OpenAPI valide**

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml')); print('paths:',len(d['paths']),'| requestBodies:',sorted(d['components']['requestBodies']))"
```

Attendu : `requestBodies: ['passthrough', 'passthroughJsonOrMultipart']`.

- [ ] **Étape 5 : commit**

```bash
git add poc-control-plane-federation/gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml
git commit -m "fix(proxy): declarer le multipart sur l'import et la mise a jour d'API

Le contrat ne declarait que du application/json alors que la creation d'API est
en form-multipart — le JSON from-scratch est casse sur 10.15. labctl attaquant
les memes chemins en JSON, les deux types sont declares.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 3 : Déclarer les trois endpoints manquants non litigieux

`accessProfiles` et `assets/team` portent le **cloisonnement d'équipe** : sans eux, une
publication à travers le proxy laisse l'API hors de sa team. `archive` porte la
**promotion inter-environnements** (ADR-079).

**Fichiers :**
- Modifier : `poc-control-plane-federation/gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml`

**Interfaces :**
- Consomme : `passthroughJsonOrMultipart` (tâche 2), `#/components/responses/proxied`.

- [ ] **Étape 1 : ajouter les trois chemins**

À la fin de la section `paths:`, en conservant le style du fichier (une phrase de
`summary`, réponses par `$ref`) :

```yaml
  /rest/apigateway/accessProfiles:
    get:
      summary: >-
        List access profiles — une team EST un accessProfile sur 10.15. Lecture
        prealable obligatoire : /assets/team n'accepte que des UUID, jamais un nom.
      responses:
        "200": { $ref: "#/components/responses/proxied" }
  /rest/apigateway/assets/team:
    post:
      summary: >-
        Cloisonner un asset (API ou Application) sur une ou plusieurs teams.
        assetType est OBLIGATOIRE : sans lui la 10.15 rend 200 SANS RIEN FAIRE.
      requestBody: { $ref: "#/components/requestBodies/passthrough" }
      responses:
        "200": { $ref: "#/components/responses/proxied" }
  /rest/apigateway/archive:
    get:
      summary: Exporter des APIs en archive (promotion inter-env, ADR-079)
      parameters:
        - name: apis
          in: query
          required: true
          description: GUID de l'API a exporter
          schema: { type: string }
      responses:
        "200": { $ref: "#/components/responses/proxied" }
    post:
      summary: Importer une archive (promotion 0-coupure) — envoi en multipart
      parameters:
        - name: overwrite
          in: query
          required: false
          description: Types d'assets a ecraser a l'import
          schema: { type: string }
      requestBody: { $ref: "#/components/requestBodies/passthroughJsonOrMultipart" }
      responses:
        "200": { $ref: "#/components/responses/proxied" }
```

- [ ] **Étape 2 : le linter ne doit plus signaler que le DELETE**

```bash
python3 ci/lint-contrat-proxy.py
```

Attendu : code retour **1**, mais une seule ligne restante —
`DELETE /rest/apigateway/strategies/{id}`. C'est la tâche 4.

- [ ] **Étape 3 : commit**

```bash
git add poc-control-plane-federation/gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml
git commit -m "fix(proxy): declarer accessProfiles, assets/team et archive

Trois endpoints que les roles appellent depuis toujours sans qu'ils figurent au
contrat : le cloisonnement d'equipe (accessProfiles + assets/team) et la
promotion par archive. A travers le proxy ils rendaient 404, donc une chaine
complete en proxy-oauth2 tombait sur le scoping team et sur la promotion.

Les query strings d'/archive sont declarees : un parametre non declare peut
etre filtre par la gateway.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 4 : Trancher le DELETE — décision de gouvernance

**Ceci n'est pas une correction mécanique.** ADR-075 pose « **AUCUN DELETE** : le rollback
est un re-apply depuis Git — JAMAIS une suppression via le proxy ». Or
`apim_selfservice_app/tasks/rotate-strategy.yml` supprime les objets stratégie détachés
lors d'une rotation d'identifiants.

Les deux ne peuvent pas être vrais en même temps. **Demander l'arbitrage avant d'écrire.**

**Fichiers :**
- Modifier : `poc-control-plane-federation/adr/adr-075-wm-admin-proxy-multienv.md`
- Modifier selon l'issue : le contrat, ou `ci/lint-contrat-proxy.py`

- [ ] **Étape 1 : présenter les deux issues et obtenir la décision**

*Issue A — la rotation ne passe pas par le proxy (recommandée).* L'invariant tient. La
rotation d'identifiants reste un geste d'exploitation en accès direct, hors chaîne CI. On
inscrit la limite dans l'ADR et on l'oppose dans le linter par une dérogation nommée. Coût :
la rotation n'est pas self-service.

*Issue B — le contrat admet ce DELETE et lui seul.* La rotation devient self-service. Coût :
l'invariant « aucun DELETE » devient « aucun DELETE sauf … », et cette exception devra être
défendue à chaque revue. Un `DELETE /strategies/{id}` mal ciblé casse l'authentification
des consommateurs.

- [ ] **Étape 2a — SI issue A : ajouter la dérogation au linter**

Dans `lint-contrat-proxy.py`, juste après la constante `BASE` :

```python
# Derogations ASSUMEES : appels que le contrat n'autorisera JAMAIS. Chaque entree
# porte son motif — une derogation sans motif est un oubli deguise.
DEROGATIONS = {
    ("DELETE", "/rest/apigateway/strategies/{id}"):
        "ADR-075 interdit tout DELETE via le proxy. La rotation d'identifiants "
        "(apim_selfservice_app/tasks/rotate-strategy.yml) reste un geste "
        "d'exploitation en acces direct, hors chaine CI.",
}
```

puis, dans `main()`, remplacer la ligne d'ajout aux manquants par :

```python
        if not any((m, f) in declarees for f in formes for m in a["methodes"]):
            couvert = any((m, f) in DEROGATIONS for f in formes for m in a["methodes"])
            if not couvert:
                manquants.append(("/".join(a["methodes"]), sorted(formes)[0], a["ou"], a["nom"]))
            continue
```

et, avant le bilan final, rendre les dérogations visibles plutôt que silencieuses :

```python
    if DEROGATIONS:
        print(f"ℹ {len(DEROGATIONS)} derogation(s) assumee(s) :")
        for (m, c), motif in sorted(DEROGATIONS.items()):
            print(f"    {m:6} {c}\n           {motif}")
```

- [ ] **Étape 2b — SI issue B : déclarer le DELETE au contrat**

```yaml
  /rest/apigateway/strategies/{id}:
    delete:
      summary: >-
        EXCEPTION a l'invariant "aucun DELETE" d'ADR-075 — supprime un objet
        strategie DETACHE lors d'une rotation d'identifiants consommateur.
      responses:
        "200": { $ref: "#/components/responses/proxied" }
```

Le `parameters` de `{id}` existe déjà sur ce chemin s'il est déjà déclaré ; sinon ajouter
`parameters: [{ $ref: "#/components/parameters/id" }]` au niveau du chemin.

- [ ] **Étape 3 : le linter passe au VERT**

```bash
python3 ci/lint-contrat-proxy.py
```

Attendu : code retour **0**, et — la chaîne des tâches 2 à 4 ayant été rejouée à
l'écriture de ce plan sur une copie du dépôt — exactement :

```
ℹ 1 derogation(s) assumee(s) :
    DELETE /rest/apigateway/strategies/{id}
           ADR-075 interdit tout DELETE via le proxy. …
✓ les 97 appels des roles sont couverts par le contrat (35 operations declarees)
```

Sur l'issue B, pas de ligne de dérogation et **36** opérations déclarées.

- [ ] **Étape 4 : inscrire la décision dans l'ADR**

Ajouter une section datée à `adr-075-wm-admin-proxy-multienv.md` qui dit **quelle** issue
a été retenue, **pourquoi**, et ce qu'elle coûte. Une décision non écrite se re-litige.

- [ ] **Étape 5 : commit**

```bash
git add poc-control-plane-federation/ci/lint-contrat-proxy.py \
        poc-control-plane-federation/gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml \
        poc-control-plane-federation/adr/adr-075-wm-admin-proxy-multienv.md
git commit -m "docs(adr-075): trancher le DELETE de la rotation d'identifiants

rotate-strategy.yml supprime les objets strategie detaches, ce que l'invariant
'aucun DELETE' d'ADR-075 interdit. Les deux ne pouvaient pas tenir ensemble.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 5 : Prouver qu'un multipart traverse réellement le proxy

Le contrat le **déclare** depuis la tâche 2 ; rien ne prouve que wM 10.15 relaie le corps
sans le réencoder. Les matrices de preuve des scripts de pose ne testent que des `GET` et
un `DELETE` : **aucun multipart n'a jamais traversé un proxy dans ce dépôt.** C'est le
risque technique numéro un du lot.

**Fichiers :**
- Créer : `poc-control-plane-federation/ci/sonde-multipart-proxy.sh`

**Prérequis :** une gateway joignable portant le proxy, et un jeton OAuth2 valide. Sur le
lab, le tunnel SSH doit être rétabli (`~/.kube/k3s-contabo.yaml`).

- [ ] **Étape 1 : écrire la sonde**

```bash
#!/bin/bash
# Un import d'API en form-multipart traverse-t-il le proxy d'admin sans etre
# reencode ? Le contrat le DECLARE ; personne ne l'a jamais mesure.
#
# Principe : le MEME contrat OpenAPI est importe deux fois, sous deux noms
# jetables — une fois en direct, une fois a travers le proxy. Le direct est le
# TEMOIN : sans lui, un echec ne distingue pas "le proxy casse le multipart" de
# "ma requete est mauvaise" ou "la gateway est en vrac".
#
# Aucun secret en argv. BASIC et BEARER se lisent dans l'environnement, pose par
# l'appelant depuis un fichier root-only ou depuis Vault.
set -eu
umask 077

: "${WM_DIRECT:?base d'admin en direct, ex. http://.../rest/apigateway}"
: "${WM_PROXY:?base d'admin a travers le proxy}"
: "${BASIC:?identifiants d'admin pour l'appel direct, forme utilisateur:motdepasse}"
: "${BEARER:?jeton OAuth2 pour l'appel proxifie}"

CONTRAT="${CONTRAT:-clients/_example/apis/accounts-read.openapi.yaml}"
[ -f "$CONTRAT" ] || { echo "!! contrat introuvable : $CONTRAT"; exit 1; }
SUFFIXE="$(date +%s)"
KO=0

importer() {  # $1=libelle  $2=base  $3=nom d'API  $4=en-tete d'auth
  CODE="$(curl -s -o /tmp/sonde-$1.json -w '%{http_code}' -X POST "$2/apis" \
    -H "$4" \
    -F "file=@$CONTRAT;type=application/x-yaml" \
    -F "type=openapi" -F "apiName=$3" -F "apiVersion=1.0" || echo 000)"
  echo "  $1 : HTTP $CODE"
  # Un 2xx ne prouve rien sur cette version : elle rend des 200 qui ne font rien.
  # Seule la RELECTURE fait preuve.
  VU="$(curl -s "$2/apis" -H "$4" | grep -c "\"$3\"" || true)"
  echo "  $1 : relecture -> $VU occurrence(s) du nom"
  [ "$VU" -ge 1 ] || KO=1
}

echo "== TEMOIN — import direct"
importer direct "$WM_DIRECT" "sonde-mp-direct-$SUFFIXE" "Authorization: Basic $(printf '%s' "$BASIC" | base64)"

echo "== MESURE — import a travers le proxy"
importer proxy "$WM_PROXY" "sonde-mp-proxy-$SUFFIXE" "Authorization: Bearer $BEARER"

echo
if [ "$KO" -eq 0 ]; then
  echo "✓ le multipart TRAVERSE le proxy (temoin direct OK, proxifie OK)"
else
  echo "✗ ECHEC — comparer les deux corps dans /tmp/sonde-*.json."
  echo "  Si le temoin direct passe et que le proxifie echoue, wM reencode le"
  echo "  corps : le lot 1 doit alors router l'import HORS du proxy et le dire."
fi
echo "!! penser a supprimer les APIs jetables sonde-mp-*-$SUFFIXE"
exit "$KO"
```

- [ ] **Étape 2 : la faire tourner**

```bash
cd poc-control-plane-federation
WM_DIRECT=... WM_PROXY=... BASIC=... BEARER=... bash ci/sonde-multipart-proxy.sh
```

Attendu : `✓ le multipart TRAVERSE le proxy`.

**Si le témoin direct échoue**, la sonde ne mesure rien : corriger l'appel ou la gateway
avant de conclure quoi que ce soit sur le proxy.

**Si le témoin passe et que le proxifié échoue**, c'est le résultat le plus important du
lot : l'import d'API ne peut pas passer par le proxy. Ne pas contourner en silence —
remonter le fait, et rouvrir le périmètre du lot.

- [ ] **Étape 3 : supprimer les APIs jetables**

Elles portent le suffixe horodaté imprimé par la sonde. Les laisser pollue les mesures
suivantes et le résultat de la carto.

- [ ] **Étape 4 : commit**

```bash
git add poc-control-plane-federation/ci/sonde-multipart-proxy.sh
git commit -m "test(proxy): sonde de traversee du multipart, avec temoin direct

Le contrat declare le multipart depuis la tache 2 ; rien ne prouvait que wM
10.15 relaie le corps sans le reencoder — aucune matrice de preuve du depot ne
testait autre chose que des GET. Le temoin direct est indispensable : sans lui,
un echec ne distingue pas le proxy d'une requete mal formee.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 6 : Porter la pose du proxy sur le cluster

`setup-wm-admin-self-proxy.sh` est taillé pour le banc docker-compose. Il faut d'abord
**mesurer** ce que le cluster offre — l'autorité OAuth2 notamment — puis paramétrer.

**Fichiers :**
- Créer : `poc-control-plane-federation/ci/mesure-prerequis-proxy-cluster.sh`
- Modifier : `poc-control-plane-federation/scripts/setup-wm-admin-self-proxy.sh`

- [ ] **Étape 1 : rétablir l'accès au cluster**

Le tunnel SSH tombe (mesuré : `127.0.0.1:16443` refusé après quelques heures). Le
rétablir, puis vérifier :

```bash
export KUBECONFIG=~/.kube/k3s-contabo.yaml && kubectl get pods -n wm
```

- [ ] **Étape 2 : écrire et exécuter la mesure des prérequis**

```bash
#!/bin/bash
# De quoi dispose le cluster pour porter le proxy d'admin OAuth2 ?
# Lecture seule. Aucun secret affiche.
set -eu
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k3s-contabo.yaml}"

echo "== 1. Autorite OAuth2 dans le cluster"
kubectl get svc -A 2>/dev/null | grep -iE "keycloak|oauth|oidc|dex|hydra" \
  || echo "   AUCUNE — le jeton devra venir d'ailleurs (voir 2)"

echo "== 2. La gateway porte-t-elle son propre serveur d'autorisation ?"
echo "   (les pipelines evoquent pub.apigateway.oauth2/getAccessToken)"
kubectl get svc -n wm

echo "== 3. Vault du cluster"
kubectl get svc -n ci 2>/dev/null | grep -i vault || echo "   pas de Service vault dans ci"

echo "== 4. Le secret OAuth2 attendu par le pipeline existe-t-il ?"
echo "   chemin attendu : secret/deploy/<tenant>/admin-oauth"
echo "   champs : token_url, client_id, client_secret, scope"
echo "   ATTENTION : APIM_KV_PREFIX est VIDE sur les jobs du cluster."
echo "   -> a verifier avec un token Vault nominatif, hors de ce script."

echo "== 5. labctl est-il disponible dans l'image d'agent Jenkins ?"
kubectl get deploy -n ci -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[*].image}{"\n"}{end}'
```

**Résultat attendu : un choix documenté.** Si aucune autorité OAuth2 n'existe dans le
cluster, deux voies — utiliser le serveur d'autorisation embarqué de la gateway wM, ou
poser un émetteur dédié. Trancher ici, par écrit, avant de paramétrer quoi que ce soit.

- [ ] **Étape 3 : paramétrer le script de pose**

Remplacer chaque valeur docker-compose codée en dur par une variable avec le défaut
actuel — même méthode que celle déjà appliquée aux Jenkinsfile en `91d54e1` : le défaut
conserve le comportement du banc, la surcharge sert le cluster.

Points d'ancrage relevés dans `scripts/setup-wm-admin-self-proxy.sh` :

| Ce qui est codé | Où | Devient |
| --- | --- | --- |
| `WM=${WM_GATEWAY_URL:-http://localhost:5555}` | ligne ~31 | déjà surchargeable — vérifier qu'il porte bien jusqu'aux appels |
| realm et URL Keycloak (`localhost:8480`, `keycloak:8080`) | création du scope client | variable d'émetteur |
| `secret/stoa/deploy/${TENANT}/admin-oauth` | ligne ~138 | préfixe KV variable — **le cluster a `APIM_KV_PREFIX` VIDE**, donc `secret/deploy/…` |
| `BASE="$WM/gateway/wm-admin-self/1.0"` | matrice de preuve, ligne ~171 | composé depuis le nom d'API |

Le nom de l'API proxy doit être **la même variable** que celle lue par les Jenkinsfile
(`APIM_PROXY_API`) : deux sources pour un même nom, c'est une dérive garantie — c'est
exactement le défaut corrigé en D3.1 de la spec pour le tag.

- [ ] **Étape 4 : poser le proxy sur le cluster et rejouer sa matrice de preuve**

Le script porte déjà sa propre matrice : `401` sans jeton, `200` sur `/health` avec jeton,
`200` sur `GET /rest/apigateway/apis`, `404` hors contrat, `405/404` sur un DELETE.
Elle doit passer **en entier** contre le cluster.

**Piège dur :** le proxy est self-referencing vers `localhost:5555`, donc il agit sur **la
réplique qui sert l'appel**. Il faut donc l'atteindre par le Service d'administration
épinglé, jamais par le Service réparti — sans quoi une écriture peut atterrir sur une
réplique et la relecture sur l'autre, qui rend un `401` trompeur. `APIM_PROXY_HOST` porte
déjà ce défaut dans les job XML.

- [ ] **Étape 5 : commit**

```bash
git add poc-control-plane-federation/ci/mesure-prerequis-proxy-cluster.sh \
        poc-control-plane-federation/scripts/setup-wm-admin-self-proxy.sh
git commit -m "feat(proxy): porter la pose du self-proxy sur le cluster

Les valeurs docker-compose deviennent des parametres, defaut inchange. La
mesure des prerequis est versionnee pour etre rejouable.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 7 : Basculer les jobs du cluster en proxy-oauth2

**Fichiers :**
- Modifier : `poc-control-plane-federation/ci/jenkins/publish-api-deploy.job.xml`
- Modifier : `poc-control-plane-federation/ci/jenkins/selfservice-app-deploy.job.xml`

**Interfaces :**
- Consomme : `APIM_PROXY_HOST` / `APIM_PROXY_API` / `APIM_PROXY_BASE` / `APIM_PREFLIGHT`,
  déjà exposés par le commit `91d54e1`.

- [ ] **Étape 1 : compléter les paramètres OAuth2**

Les jobs du cluster ne définissent aujourd'hui **aucun** des paramètres du mode OAuth2 —
`APIM_OAUTH_SUB`, `APIM_OAUTH_TOKEN_URL`, `APIM_OAUTH_CLIENT_AUTH` — donc `proxy-oauth2`
y retomberait sur les défauts docker-compose. Les ajouter, en suivant exactement la forme
des `StringParameterDefinition` existants, avec les valeurs issues de la tâche 6.

- [ ] **Étape 2 : corriger l'incohérence de `provision-apply.job.xml`**

Il délègue avec `ADMIN_VIA='proxy-oauth2'` alors que les défauts du cluster sont
docker-compose. Il vise donc aujourd'hui un hôte inexistant. À traiter dans la même passe,
sans quoi la bascule laisse une chaîne cassée derrière elle.

- [ ] **Étape 3 : basculer, un job d'abord**

Passer `ADMIN_VIA` à `proxy-oauth2` sur le **seul** job de publication d'API. Lancer une
publication de bout en bout. Le `verify` fail-closed du rôle est le juge.

- [ ] **Étape 4 : la contre-épreuve qui compte**

Vérifier que la chaîne franchit bien les endpoints ajoutés en tâche 3 : le cloisonnement
d'équipe doit avoir eu lieu — l'API porte sa team après publication. C'est exactement ce
qui tombait en 404 avant ce lot, et un `verify` qui ne contrôle pas la team ne le verrait
pas.

- [ ] **Étape 5 : basculer le second job, puis commit**

```bash
git add poc-control-plane-federation/ci/jenkins/
git commit -m "feat(ci): basculer les jobs du cluster sur le proxy OAuth2

Les jobs ne definissaient aucun parametre OAuth2 : proxy-oauth2 retombait sur
les defauts docker-compose, inexistants dans le cluster — d'ou le contournement
en ADMIN_VIA=direct note dans HANDOFF-PROVISIONING-CHAIN.md.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

**Retour arrière :** repasser `ADMIN_VIA` à `direct` sur les jobs. C'est un paramètre, pas
un déploiement — le retour est immédiat et ne demande aucune reconstruction. Le vérifier
**avant** de basculer, pas après.

---

## Écart assumé avec D6 de la spec

D6 prévoyait d'ajouter au contrat, en plus des endpoints ci-dessus, la **surface ports en
lecture** (`GET /ports`, `GET /ports/{key}`, `GET /ports/{key}/accessMode`) et la lecture
du **registre de convergence**. Ce plan les **reporte au lot 2**, délibérément : rien ne
les appelle encore, et le principe d'allow-list d'ADR-075 est de ne déclarer que l'usage
réel. Les déclarer maintenant ouvrirait une surface que le linter ne pourrait pas défendre,
faute d'appelant.

Conséquence à tenir : le lot 2 devra ajouter ces chemins **et** leurs appelants dans le
même mouvement, sans quoi le linter ne verra pas la différence.

## Ce que ce plan ne couvre pas

- **La convergence de l'allow list du port HTTPS** — c'est le lot 2, et il doit commencer
  par la mesure M5 de la spec (le clustering Ignite par découverte Kubernetes ferme-t-il
  le trou de propagation à chaud ?), qui peut le réduire à un réglage.
- **La pose du listener HTTPS** — geste d'infrastructure, hors périmètre (D2 de la spec).
- **Le mock webMethods** — il n'implémente ni `/ports` ni `accessMode` ; à étendre pour le
  lot 2, pas pour celui-ci.
