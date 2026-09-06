# HANDOFF 2026-08-04 — `SCOPE_INCONNU` sur un scope qui existe, et réalignement de gitea

Deux sujets se sont enchaînés dans la session. Le premier est un bug livrable, corrigé
et prouvé. Le second est une dette d'infrastructure que le premier a mise au jour.

---

## 1. Le bug : `SCOPE_INCONNU` sur un scope pourtant publié par l'AS

### Symptôme

Chez le client, l'apply self-service refusait la création d'application :

```
SCOPE_INCONNU : auth.scopes=ScopeASLocal — l'AS 'local' ne publie que
['2cac311a-…', 'Admin', 'controlplane.read', …, 'ScopeASLocal', …, 'apps.write'].
```

Le scope refusé **figure dans la liste affichée juste à côté**. Le message accuse l'AS
alors que l'AS est irréprochable — le pire diagnostic possible, celui qui envoie chercher
la panne du côté de l'alias, des droits ou de la gateway.

### Cause racine

Le manifeste déclarait le scope en **scalaire** :

```yaml
auth:
  scopes: ScopeASLocal          # chaîne, pas liste
```

`difference` appliqué à une chaîne itère ses **caractères**. La garde comparait donc les
lettres du nom aux scopes publiés :

```
eff=ScopeASLocal  type=AnsibleUnicode
diff=['L','l','c','S','p','A','e','o','a']   → length != 0 → assert KO
```

**Le tell était dans le message lui-même** : `auth.scopes=ScopeASLocal` s'affiche sans
crochets ni quotes, là où une liste aurait rendu `['ScopeASLocal']`. À retenir pour la
prochaine fois : dans une sortie Ansible, un rendu nu = un scalaire.

### Le piège qui a fait échouer le PREMIER correctif

Le correctif initial normalisait à l'entrée (`resolve-env.yml`, `set_fact`). Insuffisant :

| | précédence |
|---|---|
| `set_fact` | 19 |
| **extra-vars `-e`** | **22 — gagnent toujours** |

Un `-e apim_ss_auth_scopes=ScopeASLocal` passé par le CI **court-circuite la normalisation
en silence**. Le `set_fact` s'exécute sans erreur ; c'est la *lecture* qui retourne
l'extra-var. Rien dans la sortie ne désigne la précédence comme coupable.

Ce n'est pas théorique : `ci/Jenkinsfile.selfservice` passe toute sa configuration en `-e`
(lignes 313-324).

### Correctif retenu

Normalisation `[x] | flatten` à **deux** endroits :

| Fichier | Rôle |
|---|---|
| `ansible/roles/apim_selfservice_app/tasks/resolve-env.yml` | entrée — couvre le manifeste ; `scopes`, `grant_types`, `redirect_uris` |
| `ansible/roles/apim_selfservice_app/tasks/consumer-auth.yml` | **point de consommation** (`apim_ss_auth_scopes_eff`, nom interne que personne ne passe en `-e`) — couvre TOUTE provenance |

Le fail-closed n'est pas affaibli : un scalaire est sans ambiguïté un élément unique ; ce
qui reste ambigu (`"a,b"`) devient un nom unique inconnu de l'AS et se fait refuser par les
mêmes asserts. **On ne devine aucun séparateur.**

### Preuve

`scripts/test-internal-dcr.sh` — **45/45**, hors ligne (mock Go + faux Vault). Cas 12
ajouté, avec un AS **volontairement multi-scopes** pour que seul le manifeste puisse
trancher : sinon on tomberait sur `SCOPE_AMBIGU`, ce qui rendrait le test vacant.

Non-vacuité vérifiée en retirant chaque correctif séparément :

| Correctif retiré | Cas manifeste | Cas extra-var |
|---|---|---|
| `resolve-env.yml` | ❌ échoue | — |
| `consumer-auth.yml` | ✅ passe | ❌ échoue (`SCOPE_INCONNU`) |

La seconde ligne est la démonstration que le premier commit **seul** n'aurait pas débloqué
le client.

### Commits

| | |
|---|---|
| `8d56d08` | normalisation à l'entrée |
| `bdf2654` | normalisation au point de consommation |

Sur `origin/main` (cherry-pick), et sur les branches `fix/selfservice-wm-dcr` des deux
remotes sous les sha `dfea1ad` / `baa4f66`.

---

## 2. La fusion dans `main` n'était pas celle qu'on croyait

`git merge fix/selfservice-wm-dcr` a produit **7 conflits**, dont des `add/add` sur des
scripts CI sans rapport.

**Raison** : les commits antérieurs de la branche étaient **déjà dans main, en version
squashée** par les PR #8 et #9. Le squash casse l'ascendance, git ne les reconnaît pas.
Pire, main avait continué d'évoluer : fusionner aurait **supprimé** du travail plus récent
(`ENVIRONNEMENTS.md`, `secrets-baseline.txt`, `test-secrets-baseline.sh`, refonte de
`setup-provision-jobs.sh` — 836 lignes).

**Réflexe à garder** : avant de fusionner une branche dans `main` sur ce dépôt, vérifier

```bash
git diff --stat main <base-de-la-branche>
```

Vide → le travail est déjà là, cherry-picker les seuls commits neufs. Non vide → regarder
dans quel sens ça diverge AVANT de résoudre quoi que ce soit.

---

## 3. Réalignement de gitea — le dépôt que lit vraiment le CI du lab

### Ce qu'on a découvert

`ci/jenkins/*.job.xml` pointent `gitea.ci.svc.cluster.local:3000/ci/stoa-labs.git`,
branche `*/main`. **C'est gitea que lit le CI du lab, pas GitHub.**

Or `git merge-base gitea/main origin/main` était **vide** : aucune ancêtre commun. Deux
lignées totalement indépendantes. Et gitea était antérieur à tout le mode `internal`/DCR :

```
consumer-auth.yml        449 lignes de MOINS
dcrConfig                0 occurrence
apim_ss_auth_scopes      0 occurrence
scripts/test-internal-dcr.sh   ABSENT
```

Le cherry-pick y était **impossible** : les lignes à corriger n'existaient pas.

### Ce qui a été fait

Commit de contenu en **fast-forward** — aucun historique réécrit, aucun commit supprimé,
réversible par un simple `git revert`.

```
gitea/main  f1094ac..d264408      278 fichiers, +41983 -609
```

**6 fichiers propres à gitea préservés**, vérifiés un par un, et l'écart résiduel avec
`origin/main` se réduit *exactement* à eux :

```
adr/README.md
adr/adr-067-reuse-first-owned-portable-layer.md
adr/adr-068-stoa-off-the-transaction-path.md
adr/adr-069-retention-moat-governance-source-of-truth.md
poc-control-plane-federation/POSITIONING.md
poc-control-plane-federation/clients/provisioned/applications/paiements-sepa.ansible.yml
```

Le dernier est un **artefact produit par la chaîne de provisioning** : un état du CI, pas
du code. L'écraser aurait effacé une trace d'exécution.

Les 17 sujets de commit exclusifs à gitea ont été revus : le seul substantiel côté CI
(support du portail Cloudflare Access dans `setup-provision-jobs.sh`) est présent des deux
côtés, 20 occurrences chacun. **Aucun travail exclusif perdu.**

Vérifications après push : `dcrConfig` ×18, `SCOPE_INCONNU` ×1, `flatten` ×4 dans
`resolve-env.yml` et ×2 dans `consumer-auth.yml`. Sonde **45/45** rejouée sur l'arbre
aligné **avant** le push.

Branche `align/gitea-main-2026-08-04` laissée sur gitea au même commit — point de retour
nommé.

### Piège de push sur gitea

Un push > 1 Mo **échoue silencieusement**. git bascule en `Transfer-Encoding: chunked`,
gitea répond `HTTP 200 Content-Length: 0`, son `git-receive-pack` meurt (`exit 128`), et le
client affiche `the remote end hung up` **puis** `Everything up-to-date` — épilogue
mensonger : la ref n'est pas passée.

**Toujours vérifier par `git ls-remote`, jamais se fier au dernier mot de git.**

Réglé en config locale, ciblée par URL (GitHub non touché) :

```bash
git config --local http.http://localhost:13000/.postBuffer 524288000
```

---

## 4. Ce qui reste ouvert

### a. Le client n'est pas débloqué par les points 2 et 3

Son Jenkins lit un **troisième dépôt** : `spid_message/ci-apim-application`, qui embarque
`apim-control-plane-federation/ansible/roles/…`. Jamais inspecté ; son mode d'alimentation
(submodule ? clone d'une ref ? copie manuelle ?) est **inconnu**.

Déblocage immédiat, sans attendre aucun code :

```yaml
auth:
  scopes: ["ScopeASLocal"]      # liste, pas scalaire
```

et **retirer le `-e apim_ss_auth_scopes` du Jenkinsfile**.

> Le scope appartient au **manifeste**, pas au CI. Trois raisons : il est *par app* (le
> Jenkinsfile est global et l'appliquerait à toutes) ; un scope, ce sont des **droits**, ils
> doivent passer en revue de PR ; et le manifeste gère déjà le `per_env`, ce que le
> Jenkinsfile ne sait pas exprimer.
>
> `defaults/main.yml` ne convient pas : précédence 2, et le `set_fact` de `resolve-env.yml`
> l'écraserait systématiquement — ce serait du code mort.
>
> Si le passage par le CI est imposé, la forme JSON préserve le type :
> `-e '{"apim_ss_auth_scopes": ["ScopeASLocal"]}'`

### b. `grant_types` et `redirect_uris` gardent la même exposition

Normalisés dans `resolve-env.yml`, mais **sans variable `_eff` au point de consommation**.
Un `-e apim_ss_auth_grant_types=client_credentials` scalaire produirait un
`GRANT_TYPES_INVALIDES` tout aussi mensonger, sur un grant pourtant valide.

Fermer le trou = introduire deux `_eff` et reprendre leurs 6 usages
(`consumer-auth.yml` lignes 201, 211-216, 317, 321, 654, 676). **Sciemment non fait.**

### c. Le prochain build du lab tourne sur 278 fichiers changés

Surface large. En cas de casse : `git revert d264408` sur gitea remet l'état d'avant à
l'identique.
