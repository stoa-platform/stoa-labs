# Lot 1 bis — Rendre le linter digne de confiance

> **Pour les agents :** SOUS-SKILL REQUIS — utiliser `superpowers:subagent-driven-development`
> (recommandé) ou `superpowers:executing-plans` pour dérouler ce plan tâche par tâche.
> Les étapes sont en cases à cocher (`- [ ]`).

**But :** fermer les faux négatifs résiduels de `ci/lint-contrat-proxy.py`, et surtout
les **figer dans un banc d'essai** pour qu'ils ne se rouvrent pas.

**Architecture :** le linter est le seul garde-fou du lot 1 — il décide si la chaîne CI
peut basculer sur le proxy sans tomber en 404. Trois faux négatifs y ont déjà été trouvés,
**chacun par une expérience manuelle** qui n'est enregistrée nulle part. Ce lot commence
donc par un banc d'essai qui rejoue ces expériences automatiquement, puis corrige ce qui
reste, chaque correctif étant précédé d'un cas de test qui échoue.

**Pile :** Python 3.11 + PyYAML 6, `sh` POSIX, OpenAPI 3.0.3, Ansible.

## Contraintes globales

- **Dépôt PUBLIC.** Aucun nom, adresse ou secret client. Aucun secret en clair, jamais en
  `argv`.
- **Le banc d'essai ne mute JAMAIS un fichier suivi par git.** Il travaille sur des copies
  jetables. Toutes les revues du lot 1 ont dû muter puis restaurer des fichiers du dépôt à
  la main — c'est précisément ce que ce lot supprime. `git status` doit rester propre
  pendant *et* après une exécution du banc.
- **Fail-closed, et distinction des échecs.** Code `0` = vérifié et conforme ; `1` =
  violation constatée ; `2` = je ne peux rien conclure (inventaire absent ou amputé,
  environnement cassé). Ne jamais rendre `0` faute d'avoir regardé.
- **Invariants d'ADR-075 :** allow-list de chemins, hors contrat → 404, **aucun DELETE**,
  entrée OAuth2 scopée.
- **Un correctif non accompagné d'un cas de test qui échoue avant lui n'est pas un
  correctif** — c'est la leçon des trois faux négatifs précédents.
- **Commits fréquents**, un par tâche, message en français, `Co-Authored-By` conservé.

## Périmètre, tranché avant écriture

- Le linter apprend à reconnaître la base d'admin **quelle que soit son écriture Jinja**, et
  à **rougir sur le suspect** plutôt qu'à ignorer en silence. Il couvre aussi `get_url` et
  les `command:`/`shell:` contenant `curl`.
- **Hors périmètre :** l'analyse des sources Go de `labctl`, qui attaque les mêmes endpoints.
  C'est un second analyseur sur un autre langage. Conséquence à assumer et à écrire : la
  revendication « toute action CI » reste partiellement non vérifiée.
- **Hors périmètre :** déplacer la barrière en amont de la fusion. Le job vise `*/main`, donc
  les vérifications ne s'opposent qu'**après** fusion. Limite connue, à consigner.

## Structure des fichiers

| Fichier | Responsabilité |
| --- | --- |
| `poc-control-plane-federation/ci/test-lint-contrat-proxy.py` | **créé** — banc d'essai du linter, sur copies jetables. |
| `poc-control-plane-federation/ci/lint-contrat-proxy.py` | **modifié** — chemins surchargeables, faux négatifs fermés, diagnostic. |
| `poc-control-plane-federation/ci/test-proxy-base-et-preflight.sh` | **modifié** — point de comparaison dérivable, non figé sur un SHA. |
| `poc-control-plane-federation/ci/Jenkinsfile.publish-api` | **modifié** — robustesse des variables de préflight. |
| `poc-control-plane-federation/ci/jenkins/*.job.xml` | **modifiés** — `trim` et sensibilité à la casse. |
| `poc-control-plane-federation/adr/adr-075-wm-admin-proxy-multienv.md` | **modifié** — allow-list énumérée à jour. |
| `docs/superpowers/specs/2026-07-31-allowlist-port-https-convergence-design.md` | **modifié** — trois affirmations devenues fausses. |
| `docs/superpowers/plans/2026-08-02-lot1-proxification-complete.md` | **modifié** — tableau des fichiers inexact. |

---

### Tâche 1 : Rendre le linter testable, et poser le banc d'essai

Sans chemins surchargeables, le linter n'est vérifiable que contre le dépôt réel — ce qui a
obligé chaque revue du lot 1 à muter des fichiers suivis puis à les restaurer à la main.

**Fichiers :**
- Modifier : `poc-control-plane-federation/ci/lint-contrat-proxy.py`
- Créer : `poc-control-plane-federation/ci/test-lint-contrat-proxy.py`

**Interfaces :**
- Produit : `STOA_LINT_CONTRAT` et `STOA_LINT_ROLES`, deux variables d'environnement qui
  surchargent les chemins ; défauts inchangés. Et un banc d'essai exécutable rendant `0`
  si tous les cas passent.

- [ ] **Étape 1 : rendre les chemins surchargeables**

```python
# Chemins surchargeables : sans cela le linter n'est testable que contre le vrai
# depot, ce qui a oblige chaque revue a muter des fichiers suivis puis a les
# restaurer a la main. Les defauts restent le depot reel.
CONTRAT = os.environ.get("STOA_LINT_CONTRAT") or os.path.join(
    RACINE, "gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml")
ROLES = os.environ.get("STOA_LINT_ROLES") or os.path.join(RACINE, "ansible/roles")
```

- [ ] **Étape 2 : corriger l'ancrage du chemin de rôle — piège vérifié**

La clé de dérogation porte le chemin du fichier de rôle, calculé par
`os.path.relpath(fichier, RACINE)`. Dès que `ROLES` est surchargé, `RACINE` n'est plus la
bonne racine et le chemin devient un `../../../..` absurde : **la dérogation ne matche
plus, et le linter rougit à tort**. Mesuré en préparant ce plan.

Ancre le chemin sur la racine des rôles, et non sur `RACINE` — la clé de dérogation doit
être écrite dans la même convention. Vérifie que le linter rend le même verdict en mode
défaut et en mode surchargé pointant sur le même dépôt : c'est le premier cas du banc.

- [ ] **Étape 3 : écrire le banc d'essai**

Il construit, pour chaque cas, une **copie jetable** du contrat et de l'arbre de rôles dans
un répertoire temporaire, y applique une mutation, lance le linter avec les deux variables
d'environnement, et compare le code de retour et un motif attendu dans la sortie.

Les cas ci-dessous sont les **expériences réellement exécutées** pendant les revues du lot 1 ;
chacune a déjà démasqué ou confirmé un défaut. Le banc doit les rejouer toutes :

| # | Mutation | Attendu |
| --- | --- | --- |
| 1 | aucune (contrôle) | code `0`, dérogation imprimée |
| 2 | surcharge pointant le même dépôt | verdict **identique** au mode défaut |
| 3 | retirer `PUT /rest/apigateway/policyActions/{id}` du contrat | code `1`, l'appel signalé |
| 4 | retirer `PUT /rest/apigateway/strategies/{id}` (chemin de la dérogation) | code `1` — une dérogation ne couvre que son couple exact |
| 5 | ajouter un `delete:` sur un chemin quelconque du contrat | code `1` |
| 6 | poser un `DELETE {{ apim_ss_api_base }}/strategies/{{ x }}` dans un rôle **autre** que celui nommé au motif | code `1` |
| 7 | fichier YAML de rôle non parsable | code `1`, fichier nommé |
| 8 | `ROLES` sur un répertoire absent | code `2` |
| 9 | `ROLES` sur un arbre amputé (19 fichiers) | code `2` |

- [ ] **Étape 4 : le banc doit être VERT sur le code d'aujourd'hui**

```bash
cd poc-control-plane-federation && python3 ci/test-lint-contrat-proxy.py
```

Attendu : tous les cas passent. Ils décrivent l'état **déjà atteint** par le lot 1 — le banc
est ici un filet, pas un moteur de changement. Les tâches 2 à 4 y ajouteront des cas qui
échouent d'abord.

- [ ] **Étape 5 : vérifier que le banc ne salit rien**

```bash
python3 ci/test-lint-contrat-proxy.py && git status --porcelain
```

Attendu : sortie de `git status` **vide**. Si le banc mute un fichier suivi, corrige-le
maintenant — c'est une contrainte globale du lot.

- [ ] **Étape 6 : commit**

```bash
git add poc-control-plane-federation/ci/lint-contrat-proxy.py \
        poc-control-plane-federation/ci/test-lint-contrat-proxy.py
git commit -m "test(ci): banc d'essai du linter, et chemins surchargeables

Les trois faux negatifs du linter ont ete trouves par des experiences manuelles
qui n'etaient enregistrees nulle part. Le banc les rejoue. Les chemins
deviennent surchargeables pour qu'il travaille sur copies : plus aucune revue
n'aura a muter puis restaurer un fichier suivi.

Piege ferme au passage : la cle de derogation portait un chemin ancre sur
RACINE, qui devenait absurde des que ROLES etait surcharge.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 2 : Fermer l'exemption DELETE côté contrat

`deletes_au_contrat()` construit ses tolérances par `{(m, c) for (m, c, _) in DEROGATIONS}` —
il **jette le fichier de rôle**. Ajouter un `delete:` au contrat **sous le chemin déjà
dérogé** passe donc au vert, et le linter imprime « aucun DELETE » : une affirmation fausse,
sur précisément le couple dont le motif dit qu'il doit rester hors du proxy.

**Fichiers :**
- Modifier : `poc-control-plane-federation/ci/lint-contrat-proxy.py`
- Modifier : `poc-control-plane-federation/ci/test-lint-contrat-proxy.py`

- [ ] **Étape 1 : ajouter le cas qui échoue**

Cas 10 : ajouter au contrat un `delete:` sous `/rest/apigateway/strategies/{id}` — le chemin
exact de la dérogation. Attendu : code `1`.

- [ ] **Étape 2 : lancer le banc, constater l'échec**

Attendu : le cas 10 échoue — le linter rend `0` et imprime « aucun DELETE ».

- [ ] **Étape 3 : retirer l'exemption**

La dérogation porte sur un **appel de rôle qui contourne le proxy**, pas sur une déclaration
au contrat. Les deux sens n'ont rien à voir : le motif dit « accès direct, hors chaîne CI »,
donc ce couple n'a **aucune** raison de figurer au contrat. `deletes_au_contrat()` ne doit
tolérer aucun `delete:`.

Corrige aussi le message : ne jamais imprimer « aucun DELETE » quand un DELETE est déclaré.

- [ ] **Étape 4 : banc vert, et non-régression**

Le banc passe, et sur le dépôt réel le linter rend toujours `0` avec sa dérogation imprimée.

- [ ] **Étape 5 : commit**

```bash
git add poc-control-plane-federation/ci/lint-contrat-proxy.py \
        poc-control-plane-federation/ci/test-lint-contrat-proxy.py
git commit -m "fix(ci): une derogation d'appel n'exempte pas une declaration au contrat

deletes_au_contrat() jetait le fichier de role de la cle, si bien qu'un delete:
ajoute au contrat sous le chemin deroge passait au vert — en imprimant « aucun
DELETE ». Les deux sens sont distincts : la derogation couvre un appel de role
qui contourne le proxy, jamais une declaration.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 3 : Fermer l'anti-diagonale

La double couverture — chaque forme couverte par au moins une méthode, et chaque méthode par
au moins une forme — est satisfaite par l'**anti-diagonale**. Pour l'appel réel de
`apim_selfservice_app/tasks/backend.yml`, dont la méthode et le chemin sont pilotés par le
**même** conditionnel Jinja :

| Contrat déclaré | Réalité à l'exécution | Verdict actuel |
| --- | --- | --- |
| `(POST,/policyActions)` + `(PUT,/policyActions/{id})` | correct | COUVERT ✔ |
| `(PUT,/policyActions)` + `(POST,/policyActions/{id})` | **les deux branches 404** | COUVERT ✘ |

Le linter décorrèle ce que le Jinja corrèle. C'est le même défaut de fond que les deux tours
précédents, au troisième degré.

**Fichiers :**
- Modifier : `poc-control-plane-federation/ci/lint-contrat-proxy.py`
- Modifier : `poc-control-plane-federation/ci/test-lint-contrat-proxy.py`

- [ ] **Étape 1 : ajouter le cas qui échoue**

Cas 11 : dans une copie du contrat, remplacer les deux déclarations réelles par
l'anti-diagonale — `PUT /policyActions` et `POST /policyActions/{id}`. Attendu : code `1`,
puisque les deux branches réelles de l'appel tomberaient en 404.

- [ ] **Étape 2 : lancer le banc, constater l'échec**

Attendu : le cas 11 échoue — le linter rend `0`.

- [ ] **Étape 3 : corriger**

Quand **la méthode et le chemin d'un même appel** sont tous deux conditionnels, exige le
produit croisé complet. C'est le seul choix fail-closed : le linter ne peut pas savoir quelle
branche du Jinja va avec quelle autre, donc il doit exiger que toutes soient déclarées.

Attention : ce durcissement peut faire apparaître des exigences absurdes si un appel
combine plusieurs Jinja. Vérifie le verdict sur le dépôt réel — s'il rougit, ce n'est **pas**
forcément un faux positif, c'est peut-être un vrai trou que l'anti-diagonale masquait. Ne le
neutralise pas sans l'avoir instruit : remonte-le.

- [ ] **Étape 4 : banc vert, non-régression instruite**

- [ ] **Étape 5 : commit**

```bash
git add poc-control-plane-federation/ci/lint-contrat-proxy.py \
        poc-control-plane-federation/ci/test-lint-contrat-proxy.py
git commit -m "fix(ci): exiger le produit croisé quand methode ET chemin sont conditionnels

La double couverture etait satisfaite par l'anti-diagonale : declarer
(PUT,/policyActions) et (POST,/policyActions/{id}) passait au vert alors que
les DEUX branches reelles de l'appel tombent en 404. Le linter decorrelait ce
que le Jinja corrèle.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 4 : Voir les appels qu'il ne voyait pas

La base d'admin est reconnue par comparaison textuelle littérale : `url.startswith("{{ apim_ss_api_base }}")`.
Conséquence mesurée : `{{apim_ss_api_base}}` sans espaces — Jinja parfaitement valide — et
`{{ apim_ss_api_base | default(x) }}` sont **silencieusement ignorés**, pas signalés. Un rôle
écrit dans ce style ajoute un endpoint non déclaré, le linter reste vert, et la chaîne tombe
en 404 à la bascule.

**Fichiers :**
- Modifier : `poc-control-plane-federation/ci/lint-contrat-proxy.py`
- Modifier : `poc-control-plane-federation/ci/test-lint-contrat-proxy.py`

- [ ] **Étape 1 : ajouter les cas qui échouent**

- Cas 12 : un rôle appelant `{{apim_ss_api_base}}/nouveau` (sans espaces) → code `1`.
- Cas 13 : un rôle appelant `{{ apim_ss_api_base | default('x') }}/nouveau` → code `1`.
- Cas 14 : un rôle utilisant `ansible.builtin.get_url` sur la base → code `1`.
- Cas 15 : un rôle utilisant `ansible.builtin.command` avec `curl` sur la base → code `1`.

- [ ] **Étape 2 : lancer le banc, constater les quatre échecs**

- [ ] **Étape 3 : corriger, en deux temps**

D'abord **normaliser** la reconnaissance de la base : accepter les variations d'espacement
autour du nom de variable.

Ensuite, et c'est le point qui compte : **rougir sur le suspect**. Toute tâche dont l'URL
contient `apim_ss_api_base` sans que la normalisation ne la reconnaisse doit être **signalée**,
avec son fichier et son nom — jamais ignorée. Même règle pour `get_url` et pour un
`command:`/`shell:` contenant `curl` et la base. Le linter ne doit jamais préférer le silence
au doute.

- [ ] **Étape 4 : banc vert, non-régression sur le dépôt réel**

- [ ] **Étape 5 : commit**

```bash
git add poc-control-plane-federation/ci/lint-contrat-proxy.py \
        poc-control-plane-federation/ci/test-lint-contrat-proxy.py
git commit -m "fix(ci): ne plus ignorer en silence un appel a la base d'admin

La base etait reconnue par comparaison litterale : {{apim_ss_api_base}} sans
espaces, ou avec un filtre, passait sous le radar sans le moindre signalement.
Desormais la reconnaissance est normalisee, et toute URL mentionnant la base
sans etre reconnue est SIGNALEE. get_url et les command:/shell: contenant curl
sont couverts.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 5 : Diagnostic et robustesse

Six défauts sans conséquence aujourd'hui, mais qui dégradent le diagnostic au moment où il
compte — quand le linter rougit.

**Fichiers :**
- Modifier : `poc-control-plane-federation/ci/lint-contrat-proxy.py`
- Modifier : `poc-control-plane-federation/ci/test-lint-contrat-proxy.py`

- [ ] **Étape 1 : les traiter, chacun avec son cas de test**

1. **Un module absent rend `1`**, le même code qu'une violation de politique. Or un
   environnement cassé, c'est « je ne peux rien conclure » : code `2`.
2. **`MIN_APPELS = 60` est inatteignable** — `MIN_FICHIERS_ROLES` se déclenche toujours en
   premier. Soit le seuil est calibré pour mordre, soit il est retiré : un garde-fou qui ne
   peut pas se déclencher est décoratif.
3. **L'ordre du diagnostic** : `inventaire_suspect` rend `2` avant que la liste « fichier YAML
   non parsable » ne s'imprime. L'utilisateur perd la cause au profit du symptôme.
4. **`nom` retombe sur `"?"`** pour les tâches `uri` en forme compacte — 15 appels sur 95.
   Gênant précisément quand le linter passe au rouge.
5. **Le contrat est lu par `safe_load` nu** : un doublon de clé écrase silencieusement la
   première déclaration. Direction fail-closed, mais muette — et reproduit accidentellement
   pendant une revue du lot 1. Refuse les clés dupliquées et dis-le.
6. **Méthode en Jinja à guillemets doubles** (`{{ "PUT" if x else "POST" }}`) → `methodes=[]`.
   Fail-closed, mais la colonne méthode est vide dans le rapport.

- [ ] **Étape 2 : banc vert, non-régression**

- [ ] **Étape 3 : commit**

```bash
git add poc-control-plane-federation/ci/
git commit -m "fix(ci): distinguer l'environnement casse de la violation, et soigner le diagnostic

Un module absent rendait 1 comme une violation, alors que le code 2 existe pour
« je ne peux rien conclure ». Le seuil MIN_APPELS ne pouvait pas se declencher.
Le doublon de cle du contrat passait en silence. Et le rapport perdait le nom
de 15 taches sur 95, precisement quand il rougit.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Tâche 6 : Robustesse de la chaîne CI

**Fichiers :**
- Modifier : `poc-control-plane-federation/ci/Jenkinsfile.publish-api`
- Modifier : `poc-control-plane-federation/ci/Jenkinsfile.selfservice`
- Modifier : `poc-control-plane-federation/ci/jenkins/publish-api-deploy.job.xml`
- Modifier : `poc-control-plane-federation/ci/jenkins/selfservice-app-deploy.job.xml`
- Modifier : `poc-control-plane-federation/ci/test-proxy-base-et-preflight.sh`

- [ ] **Étape 1 : `APIM_PREFLIGHT_TRIES` non numérique boucle à l'infini**

`[ "$i" -ge "abc" ]` rend 2 sous `sh`, donc la branche de sortie n'est **jamais** prise et la
boucle tourne sans fin. Valide la valeur, et retombe sur le défaut avec un avertissement si
elle n'est pas un entier positif.

- [ ] **Étape 2 : `APIM_PREFLIGHT` est sensible à la casse**

`Off` ne désactive rien. Compare en minuscules.

- [ ] **Étape 3 : `APIM_PROXY_BASE` est le seul paramètre en `trim=false`**

C'est l'échappatoire — donc celle qui ne rogne pas un espace collé, et produit une URL
invalide difficile à voir. Aligne-le sur les autres.

- [ ] **Étape 4 : le point de comparaison du test ne doit pas être un SHA figé**

`test-proxy-base-et-preflight.sh` dérive son `ANCIEN_DEFAUT` de `git show 92b846f:…`. Or
l'historique de ce dépôt **a déjà été purgé une fois**. Une seconde réécriture ferait
disparaître ce SHA et rendrait l'étape PLAN rouge pour une raison étrangère au changement
examiné. L'échec est franc (code `2`), jamais un faux vert — mais il est trompeur.

Rends le point de comparaison **dérivable** : `STOA_BASE_REF` existe déjà en échappatoire ;
fais-en le mécanisme normal, avec une valeur par défaut qui ne dépende pas d'un SHA
particulier (par exemple le point de divergence avec la branche par défaut), et un message
qui explique quoi faire si la référence est introuvable.

- [ ] **Étape 5 : vérifier, puis commit**

Le test rend `0`, et redevient rouge si l'on sabote un défaut dans l'un ou l'autre
Jenkinsfile.

---

### Tâche 7 : Remettre les documents en accord avec le code

Un document qui décrit un état révolu est un piège pour le prochain lecteur — et ce lot en a
déjà produit trois.

**Fichiers :**
- Modifier : `poc-control-plane-federation/adr/adr-075-wm-admin-proxy-multienv.md`
- Modifier : `docs/superpowers/specs/2026-07-31-allowlist-port-https-convergence-design.md`
- Modifier : `docs/superpowers/plans/2026-08-02-lot1-proxification-complete.md`

- [ ] **Étape 1 : ADR-075 — l'allow-list énumérée est incomplète**

Elle ne mentionne ni `/accessProfiles`, ni `/assets/team`, ni `/archive`, que le lot 1 a
pourtant ajoutés au contrat. Le document qui **gouverne** l'allow-list la sous-décrit.

- [ ] **Étape 2 : la spec — trois affirmations devenues fausses**

1. Elle annonce **trois** trous et n'en nomme que trois, alors que le linter en a trouvé
   **quatre** : `POST /archive` manque, et c'est l'import multipart, donc le plus risqué.
2. Elle ne mentionne **nulle part** le conflit du `DELETE`, qui est pourtant devenu
   l'arbitrage central du lot 1.
3. Elle affirme qu'aucun job XML ne définit `APIM_PROXY_BASE` — faux depuis le commit
   `91d54e1`, sur cette même branche.

- [ ] **Étape 3 : le plan du lot 1 — tableau des fichiers inexact**

Il ne liste ni les Jenkinsfile ni `test-proxy-base-et-preflight.sh`, et décrit les job XML
par le changement de la tâche 7 — non exécutée — au lieu de celui réellement livré.

- [ ] **Étape 4 : consigner les deux limites connues**

Dans l'ADR, à l'endroit où le linter est présenté comme opposable :

1. **La barrière est post-merge.** Le job vise `*/main` : les vérifications ne s'opposent
   qu'après fusion, pas sur une proposition de changement. Et `Jenkinsfile.selfservice` — celui
   auquel `provision-apply` délègue — ne les joue pas.
2. **`labctl` n'est pas couvert.** Il attaque les mêmes endpoints d'administration depuis du
   Go ; le linter ne lit que les rôles Ansible. La revendication « toute action CI » est donc
   partiellement non vérifiée.

Une limite écrite est une limite ; une limite tue est un piège.

- [ ] **Étape 5 : commit**

```bash
git add poc-control-plane-federation/adr/ docs/superpowers/
git commit -m "docs: remettre l'ADR, la spec et le plan en accord avec le code livre

L'ADR sous-decrivait l'allow-list qu'il gouverne. La spec annoncait trois trous
la ou il y en avait quatre, ne mentionnait pas le conflit du DELETE devenu
l'arbitrage central, et affirmait un fait dementi par un commit de sa propre
branche. Les deux limites connues — barriere post-merge, labctl non couvert —
sont desormais ecrites.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Ce que ce lot ne couvre pas

- **`provision-apply.job.xml`** délègue toujours en `ADMIN_VIA=proxy-oauth2` sans passer aucun
  `APIM_PROXY_*`. La correction de fond appartient à la tâche 7 du lot 1.
- **Le corps de la boucle de préflight** reste une transcription non confrontée à sa source :
  seuls ses défauts le sont. Le fermer demanderait d'extraire le bloc dans un `ci/lib/*.sh`
  sourcé par les deux Jenkinsfile.
- **`PF_CODES="200 401"`** ne distingue pas « gateway vivante » de « proxy déployé ». Le vrai
  correctif appartient à la tâche 6 du lot 1, quand le proxy sera réellement posé.
