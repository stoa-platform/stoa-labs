# HANDOFF — Carto : miroir Confluence, secrets Vault, et un job qui était cassé

**Session du 2026-08-07.** Branche `provision/probe-dev`, deux commits :
`7af077f` (correctif) et `caa776e` (le lot). Rien n'est poussé sur `origin` ni
sur `gitea`. 269 tests au vert.

---

## À LIRE EN PREMIER — ton job carto était cassé, il ne l'est plus

Le `Jenkinsfile.carto` de `HEAD` **ne compilait plus** depuis le correctif de
mesure du 2026-08-07. Le build planifié (`H 3 * * *`) serait tombé chaque nuit,
à la compilation, **sans rien collecter et sans message compréhensible**.

Cause : `r"=(\w+)"` vit dans une chaîne Groovy à triple apostrophe, où les
échappements sont interprétés ; `\w` n'en est pas un valide. Le fichier
appliquait déjà la bonne convention plus haut (`\\n`), ces lignes l'ont manquée.

Corrigé (`7af077f`), et **vérifié en compilant le fichier dans le Groovy du
conteneur Jenkins**, pas à l'œil :

```
docker cp poc-control-plane-federation/ci/Jenkinsfile.carto poc-jenkins:/tmp/J.carto
CK=$(mktemp); C=$(curl -sS -c "$CK" 'http://localhost:18080/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,":",//crumb)')
curl -sS -b "$CK" -H "${C%%:*}: ${C#*:}" \
  --data-urlencode 'script=try { new GroovyShell().parse(new File("/tmp/J.carto")); println "OK" } catch (Throwable e) { println e.getMessage() }' \
  http://localhost:18080/scriptText
```

**Leçon à porter** : rien dans la chaîne ne compile les Jenkinsfiles. Un défaut
de syntaxe n'est découvert que par un build. La commande ci-dessus devrait
devenir une porte de CI — c'est le premier point ouvert de la liste.

---

## Ce qui est livré et prouvé

### Le miroir Confluence

Troisième voie de publication, à côté de l'archive de build et du dépôt git.
**Le dépôt git reste la source de vérité** : son `git diff` répond à « qu'est-ce
qui a bougé » de façon greppable et scriptable, là où l'historique Confluence
compare deux pages *rendues*. Confluence sert la population qui ne va pas dans
une forge.

| Fichier | Rôle |
|---|---|
| `carto/render/confluence.py` | conversion Markdown → format de stockage. Pure, stdlib, testable hors ligne |
| `carto/scripts/publier-confluence.py` | client REST v1 **et** v2, idempotent |
| `carto/scripts/confluence.env.example` | gabarit d'identifiants (sans secret) |
| `carto/tests/test_confluence.py` | 32 tests |
| `ci/Jenkinsfile.carto` | stage `Miroir Confluence` |

**Prouvé en réel** sur Confluence Cloud : trois publications successives → v1,
v2, v3 **sur les mêmes pages** (idempotence : l'URL ne bouge pas, les pièces
jointes sont mises à jour et non dupliquées). Relecture serveur : **0 lien
mort**, macros `info` rendues, 7 tableaux, 3 pièces jointes sur la racine.

Page racine du labo :
`https://stoa-platform.atlassian.net/wiki/spaces/~712020418e2b1739244b8d9b1bf5d23a295609/pages/491521/Carto+API`
Les données publiées sont **fictives** (le jeu de test de `test_markdown.py`),
choisi parce qu'il exerce toutes les constructions Markdown. Rien ne vient de la
gateway.

### Trois décisions de conception à ne pas défaire

1. **On convertit le Markdown, on ne rend pas une seconde fois depuis
   `carto.json`.** Un second rendu dupliquerait toute la prose des quatre pages,
   et deux copies d'un même texte divergent au premier correctif. Même argument
   que `publier-markdown.sh` pour la logique de commit.
2. **Le bandeau de fraîcheur est une macro `info`, pas une citation.** Une
   citation Confluence est un filet gris qu'on ne voit pas ; ce bandeau porte la
   seule phrase qui distingue une page vivante d'une page périmée.
3. **L'échec du miroir rend le build `UNSTABLE`, jamais `FAILURE`.** Quand il
   échoue, la collecte est faite, les quatre portes passées, l'archive existe et
   git est à jour. Un rouge apprendrait à l'équipe que le rouge de ce job ne
   veut rien dire — et le jour où c'est la *collecte* qui casse, personne ne
   regarderait.

### Deux défauts que seule la conversion du corpus complet a révélés

- un code en ligne à **un** accent grave contenant **trois** (` ```mermaid `
  dans `evolution.md`) — un motif naïf fermait au premier accent ;
- un **italique en ligne** (`*aujourd'hui*`), unique occurrence des quatre pages.

D'où le test principal : convertir les **quatre pages réelles** et refuser
qu'une syntaxe Markdown survive. Une construction non traduite s'affiche en
clair, sans erreur, sans alerte, sans build rouge.

### Les secrets par Vault — livrés, DÉSACTIVÉS PAR DÉFAUT

`ci/lib/carto-secrets.sh`. **`VAULT_ADDR` vide ⇒ comportement strictement
inchangé** (credentials Jenkins). C'est délibéré : ce job tourne toutes les
nuits, une voie d'authentification neuve activée d'office se paierait en nuits
rouges pendant ton absence.

L'arbitrage en tête du Jenkinsfile (« ce job recule sciemment sur Vault ») est
**amendé, pas contredit** : ce qui a été refusé côté client est l'auth par
**identité de pod**, pas Vault. Les pipelines `prod` et `rollback` lisent déjà
leurs secrets par **AppRole**, chemin que le client exécute. Même
`ci/lib/vault-login.sh`, même `vault_login_any`, même credential
`vault-ci-secret-id`.

> **ÉTAT DE PREUVE : compilé et relu, PAS exécuté contre un Vault réel.** Aucun
> chemin KV n'existe pour ce job à ce jour. Ne pas l'annoncer comme prouvé.

**AppRole ne supprime pas le secret zéro, il le déplace.** Jenkins ne détient
plus trois secrets métier à longue vie mais un `secret_id`, dont le pouvoir est
borné par la policy Vault du rôle. Vrai gain, pas une élimination.

---

## Points ouverts, par ordre de valeur

### 1. Aucun lint Groovy dans la chaîne (nouveau, et c'est le plus rentable)
Un Jenkinsfile qui ne compile pas n'est découvert que par un build. La commande
de compilation est ci-dessus ; en faire une porte de CI coûte peu et aurait
attrapé la régression du 2026-08-07 le jour même.

### 2. L'option proxy sur tous les CI — inventaire fait, deux obstacles réels

`ADMIN_VIA: direct | proxy-oauth2` (ADR-075) existe, mais sur 2 des 5 jobs qui
touchent l'API d'admin :

| Job | appels admin | `ADMIN_VIA` |
|---|---|---|
| `publish-api`, `selfservice` | 4 | ✅ |
| `carto`, `team-apply`, `team-publish` | 4 / 1 / 1 | ❌ |

Les jobs de *demande* (`api-request`, `app-request`, `team-request`) et
`prod` / `rollback` n'appellent pas l'admin directement — rien à aligner.

**Obstacle A — le contrat du proxy ne couvre pas ce que la carto appelle.**
`gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml` déclare `/apis` et
`/applications`, mais **ni `/transactionalEvents/_count` ni `/_search`**. En
`proxy-oauth2` ces deux appels prendraient un 404 — et le linter dit lui-même
pourquoi c'est sournois : *« un appel non déclaré ne casse QU'EN mode
proxy-oauth2, jamais en direct : le défaut est invisible tant qu'on teste en
direct »*.

**Obstacle B — le linter ne voit pas la carto.** `ci/lint-contrat-proxy.py` ne
scanne que `ansible/roles` (variable `ROLES`). Les appels de la carto sont en
Python dans `carto/collect/`. Même en ajoutant les chemins au contrat, rien ne
garderait l'invariant ensuite.

**Travail de code** : le collecteur ne sait faire que du **Basic**
(`carto/collect/gateway.py:169`). Le mode proxy demande un `Bearer` obtenu en
`client_credentials`. L'authentification est construite **à un seul endroit**,
donc c'est contenu.

**Séquence proposée** : contrat étendu (2 chemins) → linter étendu à
`carto/collect/` → OAuth2 dans `gateway.py` + tests → `ADMIN_VIA` sur les 3
jobs, calqué sur `selfservice`.

### 3. Mettre Vault en service pour la carto
1. Créer les chemins KV (labo) :
   `secret/stoa/carto/gateway` → champs `user`, `password`
   `secret/stoa/carto/pages` → `user`, `token`
   `secret/stoa/carto/confluence` → `token`
2. Attacher au rôle AppRole du CI une policy **lecture seule** sur ces trois
   chemins, et rien d'autre.
3. Renseigner les paramètres du job : `VAULT_ADDR`, `VAULT_ROLE_ID`, puis
   **un seul** chemin (`CARTO_VAULT_GW_PATH`) pour une première bascule.
   Un chemin vide laisse SON secret sur le credential Jenkins : la bascule est
   graduelle, par construction.
4. Lancer le job à la main et lire le journal : il annonce sa source
   (`Secrets : VAULT` ou `Secrets : CREDENTIALS JENKINS`) et, par secret, le
   chemin lu et la LONGUEUR de la valeur — jamais la valeur.

### 4. Confluence Data Center en local (non commencé)
Les images `atlassian/confluence` sont publiées en **arm64** : ça tournera
nativement sur le Mac. Licence d'évaluation 30 jours à générer sur
`my.atlassian.com`. C'est ce qui éprouvera la voie **v1 + Bearer**, celle du
client — aujourd'hui écrite et relue, mais seulement le Cloud (v2) est prouvé.

### 5. Chez le client : ce qu'il faut demander, et dans quel ordre
Le mot « clé API » recouvre trois obstacles très inégaux :
1. **Un compte.** En Confluence Data Center la licence se compte **par
   utilisateur** : un compte de service consomme un siège. C'est un achat, pas
   une permission — donc un délai.
2. **Le jeton (PAT).** Libre-service depuis Confluence 7.9, **sauf s'ils ont été
   désactivés globalement**. Question à poser tôt, réponse binaire.
3. **Le droit d'écriture sur l'espace.** Le plus facile.

C'est la même classe de demande que le compte de service de la forge : les
demander ensemble. Repli réaliste si le siège est refusé : le PAT d'un compte
technique d'équipe existant ; à défaut celui d'une personne nommée — ça marche,
mais son départ arrête la publication, et il faut le dire comme une dette.

---

## Gestes d'hygiène en attente

- **Révoquer le jeton Confluence** utilisé en session : il a transité par la
  conversation. https://id.atlassian.com/manage-profile/security/api-tokens
- `carto/.env.confluence` existe en local, **gitignoré** (`.env.*`), et contient
  ce jeton. Le mettre à jour après rotation.
- Y ajouter la ligne suivante, sinon il faut exporter la variable à chaque fois
  (le Python de python.org n'a aucun magasin d'autorités configuré) :
  ```
  CONFLUENCE_CA_FILE='/Library/Frameworks/Python.framework/Versions/3.11/lib/python3.11/site-packages/certifi/cacert.pem'
  ```
- L'espace Confluence du labo est **personnel** (`~7120204…`). Un compte de
  service ne peut pas y écrire proprement : créer un espace dédié (clé `CARTO`)
  et changer `CONFLUENCE_SPACE_KEY`.
- Rien n'est poussé. `git push origin provision/probe-dev` et le push `gitea`
  restent à faire.

---

## Idées de pages, pour plus tard

Le concept de page générée tient comme palliatif avant Grafana. Toutes celles-ci
se dérivent de données que le collecteur lit déjà, ou presque :

- **Dette de gouvernance** — les écarts déclaré/observé, avec leur *âge*. Un
  écart de trois mois ne se traite pas comme un écart d'hier.
- **Matrice de dépendances par équipe** — « qui casse si je déprécie cette
  API », la page qu'on ouvre avant d'annoncer une dépréciation.
- **Inventaire des politiques de sécurité par API** — surtout : lesquelles n'en
  ont aucune.
- **Fraîcheur des environnements** — quelle version est où, depuis quand.

Le client n'a validé que la carto. Commencer par elle, sur git, et n'ouvrir
Confluence qu'ensuite — c'est bien l'ordre retenu.
