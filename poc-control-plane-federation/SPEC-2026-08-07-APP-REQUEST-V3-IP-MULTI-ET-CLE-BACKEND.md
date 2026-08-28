# SPEC — app-request v3 : IP multiples et clé backend (identifier `token`)

**Date** : 2026-08-07
**Périmètre** : items 1 et 3 de l'incrément `app-request v3` (« identité entrante enrichie »).
**Base** : `deliver/gitea-main` (= `gitea/main`, HEAD `6f5ae46`).
**Statut** : **LIVRÉ** — `scripts/test-app-request-v3.sh` **34/34**,
`scripts/test-app-request-v2.sh` **19/19** (non-régression).

---

## 1. Le manque, mesuré

Retour utilisateur du 2026-08-07 sur le formulaire **app-request v2** (livré au
palier 3) : deux dimensions que le formulaire ne sait pas exprimer, alors que
**le moteur en aval les supporte déjà**.

### 1.1 Une seule IP là où le manifeste accepte une liste

| Couche | État vérifié |
|---|---|
| Formulaire — `ci/jenkins/app-request.job.xml:96` | `IP_ALLOWLIST` est un `StringParameterDefinition` : **une ligne, une valeur** |
| Script — `scripts/provision-request.sh:231` | emballe **une** valeur : `ip_allowlist: [\"${REQ_IP_ALLOWLIST}\"]` |
| Script — `scripts/provision-request.sh:114-123` | la garde refuse tout caractère hors `[0-9A-Za-z.-]` — **le retour-ligne et la virgule sont donc refusés aujourd'hui** |
| Rôle — `ansible/roles/apim_selfservice_app/defaults/main.yml:50` | `ip_allowlist: []` — **liste, déjà** (`["192.168.65.1", "10.0.0.1-10.0.0.5"]`) |
| Manifestes d'exemple — `clients/_example/applications/*.ansible.yml` | `ip_allowlist: [...]` par env, déjà des listes |

Le manque est donc **exclusivement** dans le formulaire et dans l'emballage du
script. Rien à changer dans le rôle.

### 1.2 La clé backend n'est pas exposée du tout

Le rôle sait poser l'identifier **`token`** (singulier — l'énumération wM 10.15
rejette `tokens` en 400) depuis un secret Vault, et cette voie est **prouvée
27/27** (`scripts/test-backend-key.sh`) :

| Champ du manifeste | Rôle |
|---|---|
| `per_env.<env>.backend_key_ref` | sous-chemin **KV v2** de la clé — **Git ne porte jamais la valeur**, elle est lue à l'apply (`tasks/backend-key.yml:72`) |
| `backend_key_field` | champ à lire **dans** l'entrée KV, défaut `api_key` (`tasks/backend-key.yml:85`) |

Le formulaire n'expose **ni l'un ni l'autre**. Un demandeur ne peut donc pas
obtenir de clé backend par la porte humaine — seulement par une édition
manuelle du manifeste, ce que son propre en-tête interdit (« Ne PAS éditer à la
main »).

### 1.3 Décisions verrouillées avant conception

- **Le formulaire prend le CHEMIN Vault, jamais la valeur.** Un secret ne
  transite pas par un champ Jenkins (console, paramètres de build persistés).
  Conséquence assumée : la clé doit **déjà** être dans Vault au moment de la
  demande — sinon l'apply échoue `BACKEND_KEY_MISSING` et **rien n'est posé**
  sur la gateway (fail-closed du rôle, pas une régression à introduire ici).
- **Une demande = un env.** `REQ_ENV` pilote déjà le nom de branche
  `provision/<app>-<env>`, l'env du manifeste et le plan enchaîné. « Plusieurs
  listes d'IP » signifie **plusieurs entrées dans la liste de l'env demandé**,
  pas plusieurs envs en une PR — ce dernier serait un chantier structurel, hors
  de cet incrément.

---

## 2. Principe directeur : la substance reste dans le script

Toute la logique ajoutée vit dans **`scripts/provision-request.sh`**, aucune
dans `ci/Jenkinsfile.app-request`.

C'est la doctrine écrite en tête des deux fichiers (« le job est MINCE — il
ROUTE des valeurs de formulaire vers `scripts/provision-request.sh`, qui porte
TOUTE la substance … Aucune logique métier n'a migré ici, et aucune ne doit y
migrer »). Le corollaire est un gain concret : la **voie machine** (OIG/CLI2),
qui appelle le script directement, hérite du multi-IP et de la clé backend
**sans nouveau contrat d'appel**. Découper en Groovy dans le Jenkinsfile
laisserait au contraire la voie machine mono-IP, et ferait diverger deux portes
dont tout le design (ADR-078/081) exige qu'elles aient le même aval.

Répartition inchangée, et rappelée ici parce qu'elle contraint la suite :
**le XML fait autorité sur les PARAMÈTRES, le Jenkinsfile sur le PIPELINE.**
Declarative ne remplace que les propriétés qu'il a lui-même posées
(`DeclarativeJobPropertyTrackerAction`) : des `<parameterDefinitions>` venus du
`config.xml` sont préservés indéfiniment et **gagnent** (mesuré sur le lab le
2026-08-06). Déclarer les nouveaux paramètres dans le Jenkinsfile produirait une
divergence **silencieuse**.

---

## 3. Item 1 — IP multi-valeurs

### 3.1 Formulaire

`IP_ALLOWLIST` passe de `StringParameterDefinition` à
**`TextParameterDefinition`** (zone multiligne), **une entrée par ligne**.

Le précédent existe dans le même fichier : `CERT_PEM` est déjà un
`TextParameterDefinition` multiligne dont la valeur traverse
`withEnv([...]) → sh` sans dommage (prouvé au palier 3). Le piège Jenkins connu
— les paramètres de build subissent `EnvVars.resolve`, d'où l'obligation de
passer par `withEnv([params…])` — est donc déjà couvert par le motif en place,
et le multiligne y a déjà fait ses preuves.

Description mise à jour : une IP (`10.0.0.1`) ou une plage `A-B`
(`10.0.0.1-10.0.0.5`) **par ligne** ; le CIDR reste refusé ; la validation
s'applique **entrée par entrée**.

### 3.2 Script — l'ordre des gardes s'inverse

Aujourd'hui la garde s'applique à la saisie **entière**, ce qui interdit
mécaniquement tout séparateur. Le nouvel ordre :

1. **découper** sur les retours-ligne (et les virgules, tolérées : un opérateur
   qui colle `a, b` ne doit pas être puni pour ça) ;
2. **trimmer** chaque entrée, **ignorer** les lignes vides ;
3. appliquer à **chaque entrée** les gardes existantes, **inchangées** :
   - `*/*` → `IP_CIDR_REFUSE` (la gateway drop le CIDR **en silence** — refus
     bruyant ici),
   - caractère hors `[0-9A-Za-z.-]` → `IP_ALLOWLIST_INVALID` ;
4. **dédoublonner** les entrées strictement identiques, en **préservant l'ordre
   de saisie** (deux fois la même dimension sur la gateway n'a pas de sens).

Les deux tags d'échec sont **conservés à l'identique** (ils sont opposés par les
tests existants), mais leur message doit désormais **nommer l'entrée fautive**,
pas la saisie entière : sur cinq lignes collées, « `IP_ALLOWLIST_INVALID :
'10.0.0.1;rm' — …` » est actionnable, « la saisie est invalide » ne l'est pas.

Ces gardes tournent **avant tout geste Git**, comme aujourd'hui.

### 3.3 Emballage

`PER_ENV_ITEMS` (`scripts/provision-request.sh:231`) rend la liste complète :

```yaml
per_env:
  dev: { ip_allowlist: ["10.60.30.1-10.60.30.30", "192.168.65.1", "10.0.0.7"] }
```

**Contrainte de non-régression, octet pour octet** : une entrée unique doit
rendre exactement `ip_allowlist: ["10.0.0.1"]` — même espacement, mêmes
guillemets — et une saisie vide doit continuer à ne produire **aucun** item.
C'est ce que les golden files de la Section C de `scripts/test-app-request-v2.sh`
opposent, et cette garantie est explicitement revendiquée par les commentaires
du script (« pour rester octet pour octet identique quand
`REQ_CERT_PEM`/`REQ_IP_ALLOWLIST` sont absents »).

---

## 4. Item 3 — Clé backend (identifier `token`)

### 4.1 Deux paramètres, tous deux optionnels

| Paramètre | Type | Rôle |
|---|---|---|
| `BACKEND_KEY_REF` | `StringParameterDefinition` | sous-chemin **KV v2** de la clé, ex. `deploy/banking-demo/apps/<app>/dev/backend-key` |
| `BACKEND_KEY_FIELD` | `StringParameterDefinition` | champ à lire **dans** l'entrée ; **vide = défaut du rôle** (`api_key`) |

La description de `BACKEND_KEY_REF` doit dire **explicitement** que ce champ
attend un **chemin**, jamais la valeur de la clé, et que l'entrée doit exister
dans Vault **avant** l'apply.

La description de `BACKEND_KEY_FIELD` doit porter le **piège mesuré** : une
entrée dont la clé s'appelle `api-key` **avec un tiret** est lue vide →
`BACKEND_KEY_MISSING` **alors que l'entrée existe** (le HTTP 200 du message
d'erreur signe justement une entrée trouvée mais un champ absent).

Et une précision qui doit apparaître dans la description, sous peine de
contresens à l'usage : **`token` n'est pas une identité entrante**. C'est une
clé **sortante** app→backend. Le rôle **refuse** `token` dans `enforce`
(`BACKEND_KEY_ENFORCED`).

### 4.2 Gardes ajoutées, avant tout geste Git

- classe de caractères `[A-Za-z0-9._/-]` — le `/` est **autorisé ici**,
  contrairement à l'IP : c'est un chemin KV, pas une plage. Les deux gardes
  restent donc **séparées** ; le refus CIDR ne doit surtout pas être factorisé
  avec celui-ci.
- refus de `..` (traversée), d'un chemin **absolu** (`/…`) et de `//` →
  `BACKEND_KEY_REF_INVALID`.
- `BACKEND_KEY_FIELD` fourni **sans** `BACKEND_KEY_REF` → refus loud
  `BACKEND_KEY_FIELD_ORPHAN`. Sans cette garde on pose un champ inerte : le
  demandeur croit avoir configuré quelque chose, et rien n'est lu.
- **Ajout à l'implémentation, au-delà du spec initial** : `BACKEND_KEY_FIELD`
  reçoit lui aussi une classe de caractères, `[A-Za-z0-9._-]` (pas de `/` : ce
  n'est pas un chemin) → `BACKEND_KEY_FIELD_INVALID`. Le spec initial ne la
  prévoyait que pour `BACKEND_KEY_REF`, mais **les deux** sont interpolés tels
  quels dans le YAML du manifeste : la laisser de côté aurait ouvert sur le
  second champ exactement l'injection que la première ferme sur le premier.

### 4.3 Emplacement dans le manifeste

Les **deux** champs partent dans `PER_ENV_ITEMS`, donc sous
`per_env.<REQ_ENV>` :

```yaml
per_env:
  dev:
    ip_allowlist: ["192.168.65.1"]
    backend_key_ref: "deploy/banking-demo/apps/demo/dev/backend-key"
    backend_key_field: "api_key"
```

`backend_key_ref` **par env** est la convention documentée et la seule correcte :
« un secret d'un environnement n'est jamais celui d'un autre ».

`backend_key_field` par env est en revanche une **déviation assumée** de
l'exemple `clients/_example/applications/demo-consumer-backend-key.ansible.yml`,
qui le place à la racine. Trois raisons, dans cet ordre :

1. **Le rôle le lit à l'identique.** `tasks/resolve-env.yml` fusionne
   `racine ⊕ per_env[env]` en `combine(recursive=True)` **avant** que
   `tasks/backend-key.yml:85` ne lise `apim_ss_app.backend_key_field` : la
   valeur est présente dans les deux cas.
2. **Le coût de la racine est réel.** Une ligne racine oblige à toucher **les
   deux** branches de rendu — le heredoc `internal` *et* la variable `IDP_TAIL`
   du mode `idp` — sur un template qui revendique une identité octet pour
   octet. `PER_ENV_ITEMS`, lui, est **déjà** consommé par les deux branches, à
   un seul point chacune.
3. Les deux champs de la clé backend restent **adjacents** : un relecteur de PR
   les voit ensemble.

Cette déviation est signalée ici **pour être contestable en revue**. Si elle est
refusée, le repli est une variable `BACKEND_KEY_FIELD_LINE` sur le modèle exact
de `TEAM_LINE`/`CERT_ROTATION_LINE`, posée dans les deux branches.

---

## 5. Corps de la PR

La clé backend obtient une **ligne à part**, et surtout **ne déclenche pas**
`enforce_warning`.

Ce n'est pas cosmétique. L'avertissement existant
(`scripts/provision-request.sh:357`) parle des identités **entrantes**
opposables — `ipAddressRange` / `httpsCertificate` — et prévient le valideur que
`enforce` reste `[]`. La clé backend est une clé **sortante** que le rôle
**interdit** dans `enforce`. La faire tomber dans cet avertissement dirait au
valideur l'exact contraire du vrai.

Lignes rendues :

```
- IP allowlist : 10.60.30.1-10.60.30.30, 192.168.65.1, 10.0.0.7
- clé backend (sortante, identifier token) : deploy/…/dev/backend-key — valeur jamais en Git
```

Symétrie conservée avec l'existant : **un champ absent ne produit aucune ligne**.
Le déclencheur de `enforce_warning` reste **inchangé** (IP **ou** certificat).

---

## 6. Jenkinsfile — le strict minimum

`ci/Jenkinsfile.app-request` gagne **deux entrées** dans le `withEnv` existant
(ligne 137-142) et **rien d'autre** :

```groovy
"REQ_BACKEND_KEY_REF=${params.BACKEND_KEY_REF ?: ''}",
"REQ_BACKEND_KEY_FIELD=${params.BACKEND_KEY_FIELD ?: ''}",
```

Aucun bloc `parameters {}` n'apparaît (§2). Aucun découpage Groovy : la valeur
multiligne de `IP_ALLOWLIST` traverse telle quelle, le script découpe.

---

## 7. Preuve — `scripts/test-app-request-v3.sh`

Sur le patron de `test-app-request-v2.sh` (sections, compteur `PASS/FAIL`,
objets jetables nettoyés en fin de run).

**Section A — gardes, HORS LIGNE** (ni Gitea ni Jenkins réels)
- 3 IP valides (single, plage, single) → acceptées ;
- séparateurs : lignes, virgules, lignes vides, espaces en tête/queue ;
- une entrée CIDR **parmi plusieurs valides** → `IP_CIDR_REFUSE`, et le message
  **nomme cette entrée** ;
- une entrée à caractère interdit parmi plusieurs valides → `IP_ALLOWLIST_INVALID`
  nommant l'entrée ;
- doublons exacts → une seule occurrence, ordre de saisie préservé ;
- `BACKEND_KEY_REF` avec `..`, avec `/` initial, avec `//`, avec un caractère
  hors classe → `BACKEND_KEY_REF_INVALID` (4 cas) ;
- `BACKEND_KEY_FIELD` seul → `BACKEND_KEY_FIELD_ORPHAN` ;
- **chaque refus est vérifié comme survenant AVANT toute écriture Git** (aucune
  branche créée).

**Section B — câblage, HORS LIGNE**
- `IP_ALLOWLIST` est bien un `TextParameterDefinition` dans le XML ;
- `BACKEND_KEY_REF` et `BACKEND_KEY_FIELD` sont présents dans le XML ;
- les **trois** sont **absents** de `ci/Jenkinsfile.app-request` en tant que
  paramètres (doctrine §2) et **présents** dans son `withEnv` ;
- les marqueurs `<!--CHOICES:TEAMS-->` / `<!--CHOICES:APIS-->` survivent intacts
  aux modifications du XML (la substitution à la pose ne doit pas casser).

**Section C — non-régression, golden files**
- mono-IP, sans clé backend → manifeste **octet pour octet** identique aux
  golden de `scripts/testdata/app-request-v2/` (modes `idp` **et** `internal`) ;
- aucun champ optionnel → identique aux golden pré-Task 4.

**Section D — nominal enrichi, contre le VRAI Gitea du lab** (poc-gitea, 13000)
- 3 IP + `backend_key_ref` + `backend_key_field`, mode `idp` puis `internal` :
  manifeste attendu, corps de PR attendu ;
- le corps de PR liste les 3 IP **et** la ligne clé backend ;
- `enforce_warning` présent (IP fournie) et **ne mentionnant pas** la clé
  backend ;
- une demande avec **la seule** clé backend (sans IP ni cert) → **pas**
  d'`enforce_warning`, mais bien la ligne clé backend.

Objets jetables préfixés `p3v3-<timestamp>`, branches supprimées en fin de run
(les PR restent : Gitea ne permet pas de les supprimer — inoffensif, même
comportement que la suite existante).

---

## 7 bis. Défaut préexistant trouvé pendant la preuve — clone en échec non fatal

Découvert le 2026-08-07 **par** les contre-épreuves vertes de la Section A, et
corrigé dans la foulée.

`scripts/provision-request.sh` n'a délibérément pas `set -e` (les
`[ -n "$X" ] && …` du rendu retournent faux sans être des erreurs). Le clone
s'écrivait :

```sh
git clone … "$WORK/repo" 2>/dev/null || git clone … "$WORK/repo"
cd "$WORK/repo"
```

Les deux clones échouant, `$WORK/repo` n'existait pas, le `cd` échouait — **et
le script continuait dans le répertoire courant**. Il rendait le manifeste,
faisait `git add` puis `git commit` : **dans le dépôt de travail de
l'appelant**. Constaté en direct — six commits `provision(dev): application
probe` créés dans le dépôt plateforme pendant le premier run de la suite v3,
retirés depuis (`git reset --soft` puis suppression du manifeste parasite).

Pourquoi la suite v2 ne pouvait pas le voir : **toutes** ses épreuves hors ligne
sont des **refus**, qui sortent en `exit 2` avant d'atteindre le clone. Les
contre-épreuves **vertes** de v3 sont les premières à franchir les gardes sans
réseau — c'est-à-dire les premières à emprunter ce chemin.

**Correctif** : les deux clones sont testés dans une condition explicite, un
échec sort en `exit 1` avec un message clair, et le `cd` porte son propre
`|| exit`. **Preuve** : `run_pass` compare le `HEAD` et le `git status
--porcelain` du dépôt avant/après chaque contre-épreuve, et exige que le run
échoue (un `rc=0` sans réseau signerait un clone en échec traité comme un
succès). Six occurrences dans la suite.

Portée : ce défaut touchait **les deux portes** (formulaire et voie machine),
pour toute panne de Gitea. Il est sans rapport avec les items v3 — seulement mis
au jour par eux.

---

## 8. Hors périmètre

Explicitement **non traités** ici, et non impactés :

- **Item 2 de v3** — sélection d'une app existante (`APP` en déroulante générée).
  À noter comme **limite connue préexistante** que cet incrément ne corrige pas :
  chaque demande **réécrit intégralement** le manifeste (`cat > "$REL_PATH"`),
  donc une demande pour `rec` **remplace** le `per_env.dev` d'une demande
  antérieure. Le multi-IP ne change rien à ce comportement, ni en bien ni en mal.
- **Item 4 de v3** — nom de claim configurable (décoratif sur le lab wM 10.15,
  load-bearing chez le client).
- Le bloc **`backend:`** du manifeste (`header` / `value_template` / `inject`),
  qui pilote l'**injection** du header au stage routing — distinct de
  `backend_key_ref`, qui **stocke** la clé sur l'application.
- Le rôle `apim_selfservice_app` : **aucune modification**. Tout ce que cet
  incrément expose y est déjà implémenté et prouvé.

### Dette notée — trois jobs encore en Groovy inline

Constat du 2026-08-07, **sans impact sur cet incrément** mais à traiter :

| Job XML | Forme | Impact v3 |
|---|---|---|
| `ci/jenkins/app-request.job.xml` | ✅ Pipeline from SCM | les 3 champs |
| `ci/jenkins/provisioning-request.job.xml` | ⚠️ `<script>` Groovy inline | **aucun** |
| `ci/jenkins/provision-plan.job.xml` | ⚠️ `<script>` Groovy inline | aucun (en aval de la PR) |
| `ci/jenkins/provision-apply.job.xml` | ⚠️ `<script>` Groovy inline | aucun (en aval du merge) |

Le refactor du 2026-08-06 a converti les **5 jobs self-service** en Jenkinsfile
déclaratifs ; ces trois-là sont restés.

Pourquoi v3 ne les touche pas — et c'est la **validation empirique du §2** :
`provisioning-request` (voie machine OIG/CLI2) se réduit à
`sh 'set +x; bash scripts/provision-request.sh'`, **sans lister les champs** —
les `REQ_*` lui viennent de son payload. Elle hérite donc du multi-IP et de la
clé backend **sans une ligne de changement**. Toute la logique étant dans le
script, la forme du job (Groovy ou déclaratif) n'entre pas en jeu.

La conversion des trois reste un chantier **à risque propre** — `provision-apply`
porte un `input` de validation 4-yeux et l'identité Vault nominative — qu'il
faut mener séparément, sans le mêler à un changement de formulaire dont la
preuve repose sur une identité de rendu octet pour octet.

---

## 9. Critère de complétion

- `scripts/test-app-request-v3.sh` vert, X/X, avec le décompte affiché ;
- `scripts/test-app-request-v2.sh` **toujours vert** (non-régression) ;
- le job re-posé sur le Jenkins du lab affiche les trois champs et une demande
  réelle produit la PR attendue.
