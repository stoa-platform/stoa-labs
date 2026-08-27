# Cartographie des environnements — local, labs, plateforme STOA

_Relevé du 2026-08-04. Ce qui est marqué **mesuré** a été vérifié à cette date ;
le reste est signalé comme tel. Un document de cartographie qui ne distingue pas
les deux fait perdre plus de temps qu'il n'en fait gagner._

## Pourquoi ce document

Trois environnements portent des noms proches et parfois les **mêmes jobs**, ce
qui les rend faciles à confondre. Le 2026-08-04, une mise à jour de configuration
Jenkins demandée « sur le labs » a été appliquée **en local** : les deux
instances portaient les trois mêmes jobs (`provision-apply`, `provision-plan`,
`provisioning-request`), et rien dans la réponse HTTP ne les distingue une fois
le portail franchi. La confusion n'était pas évitable à l'œil — d'où ce relevé.

---

## 1. LOCAL — Docker sur le poste

L'environnement de développement et de preuve. **C'est ici que tournent les jobs
de la chaîne de provisioning et le Gitea qu'ils clonent.**

| Composant | Conteneur | Port hôte |
|---|---|---|
| **Jenkins** (chaîne CI) | `poc-jenkins` | **18080** |
| **Gitea** (forge des PR) | `poc-gitea` | **13000** |
| webMethods API Gateway 10.15 | `poc-webmethods-real` | 5555 |
| Vault | `poc-vault` | 8200 |
| Keycloak | `poc-keycloak` | 8480 |
| WSO2 API Manager | `poc-wso2am` | 8243 |
| APISIX (+ dashboard) | `poc-apisix`, `poc-apisix-dashboard` | 9080, 9000 |
| OpenSearch + Dashboards | `poc-analytics-*` | 9201, 5601 |
| Grafana / OTel LGTM | `poc-otel-lgtm` | 3000 |
| Microcks, Dex, ITSM mock | `poc-microcks`, `poc-dex`, `poc-itsm-mock` | 8585, 5556, 8788 |
| Mocks webMethods par env | `poc-wm-mock-{dev,rec,int}` | (réseau interne) |

**Point clé — les jobs clonent Gitea, pas GitHub.** Leur `git url` est
`http://gitea:3000/ci/stoa-labs.git` (nom de service Docker). Un correctif poussé
sur GitHub n'atteint **jamais** ces jobs tant qu'il n'est pas aussi sur Gitea.

**Deux dépôts, deux historiques SANS ancêtre commun** (mesuré) :

| Remote | URL | Rôle |
|---|---|---|
| `origin` | github.com/stoa-platform/stoa-labs | historique de référence |
| `gitea` | localhost:13000/ci/stoa-labs | **ce que le CI exécute** |

Les faire converger par `merge` est impossible (racines différentes). Tout report
d'un côté à l'autre est un **transplant de contenu**, fichier par fichier.

---

## 2. LABS — `*.labs.gostoa.dev`

Environnement hébergé, **derrière Cloudflare Access**. Mesuré : les trois hôtes
répondent `302` vers `stoa-platform.cloudflareaccess.com`.

| Hôte | Réponse | Portail |
|---|---|---|
| `jenkins.labs.gostoa.dev` | 302 | Cloudflare Access |
| `wm.labs.gostoa.dev` | 302 | Cloudflare Access |
| `wm-api.labs.gostoa.dev` | 302 | Cloudflare Access |

D'après les HANDOFF du dépôt (non re-vérifié ici) : `wm.labs` sert la **console
d'admin** webMethods et `wm-api.labs` le **data-plane**.

### Le cluster derrière : k3s sur Contabo

**Atteignable sans le portail** (mesuré) : `~/.kube/k3s-contabo.yaml` pointe sur
`https://127.0.0.1:16443` via un tunnel déjà en place. 4 nœuds
(`worker-1` control-plane, `worker-3/4/5`).

Le Jenkins du labs est le Service `jenkins` du namespace `ci` (ClusterIP
`10.43.103.207:8080`), pod sur **worker-5** (144.91.73.37). Le même namespace
porte `gitea-0`, `vault-0` et `openldap`. Le plan de contrôle est sur worker-1.

**Aucun Ingress, aucun port ouvert.** Le seul chemin depuis l'extérieur est le
tunnel **cloudflared sortant** : `jenkins.labs.gostoa.dev` →
`http://jenkins.ci.svc.cluster.local:8080`, avec Cloudflare Access devant.

Trois façons d'y accéder pour l'administrer, selon d'où l'on part :

| Depuis | Comment |
|---|---|
| le poste | `kubectl -n ci port-forward svc/jenkins 18099:8080` |
| un pod du cluster (`gitea-0`) ou worker-1 | `curl http://10.43.103.207:8080/…` |
| un navigateur | `https://jenkins.labs.gostoa.dev` + Cloudflare Access |

⚠️ Le `port-forward` **ne contourne pas le réseau** : il transite par l'**API
server**, que le tunnel expose en `127.0.0.1:16443`. C'est pour ça qu'il marche
depuis le poste là où un `curl` direct sur le ClusterIP échoue — un ClusterIP
n'est routable que depuis le cluster. Il contourne le PORTAIL, pas la
segmentation.

Le pod Jenkins **n'a pas `curl`** : les scripts qui le pilotent depuis
l'intérieur partent donc de `gitea-0` ou de worker-1.

### C'est une instance DISTINCTE de la locale (tranché le 2026-08-04)

La question restait ouverte faute de pouvoir comparer. Elle ne l'est plus :

| | Jenkins LOCAL | Jenkins LABS |
|---|---|---|
| jobs | 13, dont **provision-apply / provision-plan / provisioning-request** | 5 : `carto`, `probe`, `publish-accounts`, `publish-api-deploy`, `selfservice-app-deploy` |
| chaîne de provisioning | **oui** | **absente** |
| SCM des jobs | Gitea local (`gitea:3000`) | GitHub, sauf `carto` |

**La chaîne de provisioning self-service n'existe QUE en local.** Le labs porte
la publication d'API et le self-service applicatif, qui clonent GitHub.

⚠️ **Parenté, pas identité.** Le Jenkins docker-compose du PoC
(`docker-compose.ci.yml`, conteneur `poc-jenkins`) est l'**ancêtre local** de
celui du cluster. Les deux partagent des jobs de même nom — c'est ce qui rend la
confusion si facile — mais ce n'est pas la même instance : `poc-jenkins` ne porte
ni `publish-accounts`, ni ce que sert `labs.gostoa.dev`.

Et `carto` y vise un **troisième dépôt** : `gitea.ci.svc.cluster.local:3000` —
un Gitea interne au cluster, distinct du Gitea local et de GitHub.

### Y accéder depuis un script

Un token d'API Jenkins **ne suffit pas** : le portail est *devant* et intercepte
avant que Jenkins ne voie la requête. Il faut, au choix, un **service token**
Access (`CF-Access-Client-Id` / `CF-Access-Client-Secret`), une session
navigateur, ou WARP.

⚠️ **Un service token est présent dans l'environnement du poste et n'est PAS
autorisé sur cette application** (mesuré) : Cloudflare répond
`service_token_status: false`. Il faut une policy « Service Auth » incluant ce
token sur l'application Jenkins — ou un autre token.

`scripts/setup-provision-jobs.sh` sait envoyer ces en-têtes et **nomme le portail**
dans son diagnostic quand ils manquent.

---

## 3. PLATEFORME STOA — `*.gostoa.dev`

Le produit, public. Mesuré le 2026-08-04 :

| Hôte | Réponse | Rôle (CLAUDE.md) |
|---|---|---|
| `gostoa.dev` | 200 | landing |
| `console.gostoa.dev` | 200 | console |
| `portal.gostoa.dev` | 200 | portail |
| `api.gostoa.dev` | 200 | API du control plane |
| `docs.gostoa.dev` | 200 | documentation |
| `auth.gostoa.dev` | 302 | authentification (redirection normale) |
| `mcp.gostoa.dev` | **404** | MCP Gateway — documenté, ne répond pas |
| `status.gostoa.dev` | **injoignable** | cité dans le dépôt, ne résout pas |

Ces hôtes sont **publics** : aucun portail Access devant eux, contrairement au
labs.

---

---

## ⚠️ Les XML de `ci/jenkins/` ne visent pas tous la même instance

Piège mesuré le 2026-08-04, en voulant « mettre à jour tous les jobs en local ».
Deux familles cohabitent dans le même dossier, sans que rien dans le nom de
fichier ne les distingue :

| XML | SCM déclaré | Cible |
|---|---|---|
| `provision-apply`, `provision-plan`, `provisioning-request` | `http://gitea:3000/…` | **local** |
| `selfservice-app-deploy`, `publish-api-deploy` | `https://github.com/…` | **cluster** (leur description le dit : « sur le Jenkins du cluster ») |
| `carto` | — | absent du Jenkins local |

**Pousser les XML « cluster » sur l'instance locale casserait les jobs** — ce
n'est pas une dérive de configuration à réaligner, c'est une autre cible.
Mesuré sur `selfservice-app-deploy` et `publish-api-deploy` :

- le SCM passerait de `gitea:3000` (ce que la chaîne locale clone) à GitHub,
  dépôt à l'historique **indépendant** ;
- le **token de déclenchement disparaîtrait** (`stoa-selfservice-plan`,
  `stoa-publish-api-plan` existent LIVE, absents des XML) : les jobs ne seraient
  plus déclenchables par webhook.

**Avant de pousser une config de job, comparer les éléments FONCTIONNELS** — SCM,
token de trigger, paramètres — et pas seulement le nombre de lignes de diff. Un
écart de 160 lignes peut n'être que de la métadonnée Jenkins (`DeclarativeJobAction`,
versions de plugins épinglées, régénérées à chaque sauvegarde) ; c'est le SCM et
le token qui décident si l'écrasement est bénin ou destructeur.

## Ce qui distingue les trois, en une phrase chacun

- **local** : tout est joignable sans authentification de portail, et c'est la
  seule instance que les scripts du dépôt atteignent aujourd'hui ;
- **labs** : même topologie applicative, mais **derrière Cloudflare Access** —
  inatteignable par un script sans service token autorisé ;
- **plateforme** : le produit public, sans rapport avec la chaîne de provisioning
  du PoC.

## Comment savoir où l'on écrit

Avant toute écriture, vérifier la cible plutôt que la déduire :

```bash
# local  -> 200 sans portail
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' http://localhost:18080/crumbIssuer/api/json
# labs   -> 302 vers cloudflareaccess.com
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://jenkins.labs.gostoa.dev/crumbIssuer/api/json
```

Et pour le CI, la question qui compte n'est pas seulement « quel Jenkins » mais
**« quel dépôt ce Jenkins clone-t-il »** : une config à jour qui exécute du code
périmé donne un vert trompeur.

## Ouvrir un palier (G4)

Depuis G4 (ADR-082), **aucun edit de code n'ouvre un palier**. Les chemins
d'authoring sont scellés sur `dev` par une constante de bibliothèque non
surchargeable ; le seul palier qui existe au-delà vit sur la chaîne de
promotion, et son autorité est un **credential Vault**, pas un `if`.

Ouvrir `rec` (ou un autre palier non terminal) à un humain est un **geste
d'exploitant**, en deux temps :

```bash
# 1. minter le secret-id de l'AppRole du palier (le poseur ne le fait JAMAIS par défaut)
bash scripts/setup-vault-paliers.sh --mint apply-rec

# 2. accorder la policy apply-rec à l'humain — VOIE RECOMMANDÉE, additive :
#    setup-vault-paliers.sh a déjà posé le mapping auth/ldap/groups/apim-apply-rec -> policy apply-rec.
#    Il suffit d'ajouter l'utilisateur au GROUPE annuaire apim-apply-rec (côté OpenLDAP) ;
#    le mapping accorde la policy SANS toucher aux policies déjà attachées à l'utilisateur.
```

⚠️ **Ne PAS ouvrir un palier par `vault write auth/userpass/users/<login>
token_policies=apply-rec`.** `vault write` **remplace** `token_policies` — il
n'existe pas de syntaxe d'append `+…` — donc cette forme **efface** les policies
déjà attachées à l'utilisateur (`default`, etc.). Si l'annuaire LDAP n'est pas
la voie et qu'il faut passer par userpass, réécrire la liste **complète** : lire
l'existant, puis tout réécrire en y ajoutant `apply-rec`.

```bash
# lire les policies existantes en JSON (le champ brut rend la représentation Go
# du slice « [default extra1] », crochets et espaces compris — inutilisable tel quel) :
existing=$(vault read -format=json auth/userpass/users/<login> | jq -r '.data.token_policies | join(",")')
vault write auth/userpass/users/<login> token_policies="${existing},apply-rec"
```

L'état sorti de `setup-vault-paliers.sh` sans `--mint` est « tout fermé » : les
policies et AppRoles `apply-<env>` existent, mais aucun secret-id ne circule.
Un pipeline compromis ne peut pas s'accorder ce grant — il n'a pas la main sur
Vault.

**Geste de déploiement à ne pas oublier.** Après tout changement des listes de
protection ou des paramètres de job :

- **re-passer `bash scripts/setup-repo-protections.sh`** — la baseline de
  branche Gitea (`ci/stoa-labs@main`, `ci/governance@main`, dépôts d'équipe) est
  idempotente ; le PATCH 1.22 fusionne, donc le re-passage est non destructif.
  Garder `PROTECT_PUSH_WHITELIST` aligné sur `GITEA_ADMIN_USER` (l'admin de site
  n'est PAS exempté du push_whitelist).
- **re-poser le job `selfservice`/`team-request`** si le `config.xml` doit
  refléter les listes (choices, triggers, paramètres) : **le XML gagne sur le
  Jenkinsfile** — un scellement présent dans le Jenkinsfile mais absent du
  config.xml posé ne prend pas effet.

## Promouvoir une API (G5)

Depuis G5 (ADR-083), promouvoir une API publiée d'un palier au suivant n'est
**jamais** un re-POST du contrat : c'est un **import d'archive à GUID stable**
(ADR-079), transporté par le registre de packages génériques de Gitea,
adressé par le contenu (la version du package **est** le sha256 de
l'archive). Le palier cible doit être **ouvert** au sens de G4 — voir
« Ouvrir un palier (G4) » ci-dessus, ce geste n'est pas répété ici.

**Statut E2E.** La couche Jenkins (webhook → build → pause d'approbation)
n'a jamais tourné verte sur ce lab — le gitea date d'avant G3 et le push
exploitant qui y rebrancherait le webhook reste à faire. Chaque script du
parcours ci-dessous a été rejoué directement contre le lab vivant (T10) :
pour le moteur `labctl`, en chaîne script-par-script ; le moteur Ansible
vers un palier mocké n'est rejouable que depuis le correctif de fidélité
base64 (`0a1ac86`). Le rejeu du geste Jenkins lui-même est à la charge de
l'exploitant, suivant la checklist du rapport T10.

Le parcours opérateur, pas à pas :

1. **Publier en authoring** (`dev`) — inchangé, via `team-publish` (§ ce
   qui précède). L'API doit être active et déclarée dans un
   `apis/<api>.promote.yml` du dépôt d'équipe.
2. **Exporter l'archive** — lancer le job `api-promote-export` (paramètres
   `TEAM`, `API_NAME`, identité nominative). Il joue l'export contre la
   gateway d'authoring, pousse l'archive sanitisée au registre et imprime :

   ```
   EXPORT_CONFIRMED_SUMMARY guid=<guid> sha256=<sha256> package=<url>
   ```

3. **Épingler le guid** — recopier `guid=` dans `apis/<api>.promote.yml`
   (champ `apim_promote.guid`) et pousser une PR sur le dépôt d'équipe.
   Sans guid pinné, l'import se refuse (`IMPORT_REFUSED`) : fail-closed, ce
   n'est pas un oubli à contourner.
4. **Demander la promotion** — lancer le job `api-promote-request` (G3,
   inchangé) avec `ARCHIVE_SHA256=<sha256>` de l'étape 2. Il ouvre une PR
   `promote/<api>-<env>` sur le dépôt d'équipe.
5. **Merger la PR** — sous protection de branche (ADR-081/ADR-082) : c'est
   la décision humaine. Le merge déclenche `team-promote` via le **même**
   webhook que `team-publish` (aucun geste supplémentaire sur le dépôt
   d'équipe).
6. **Répondre à la pause** — le job `team-promote` demande une identité
   d'annuaire nominative. Elle **doit être celle qui a fusionné la PR** ; si
   la porte du palier cible exige les quatre yeux, elle sera comparée au
   demandeur (`promoted_by` du marqueur mergé).
7. **Vérifier** — le commentaire posé sur la PR (succès ou échec) porte le
   pin, la version, le sha256, le moteur utilisé, et les deux identités
   (demandeur, mergeur).

**Repli si l'archive n'a jamais été poussée.** Un refus
`ARCHIVE_INTROUVABLE` au moment du merge signifie que l'export (étape 2) n'a
jamais été rejoué depuis, ou a été rejoué avec un digest différent de celui
épinglé — **rejouer l'export** (étape 2), reprendre le `sha256` produit, et
soit corriger `ARCHIVE_SHA256` dans une nouvelle demande, soit republier au
même contenu si le digest attendu est simplement absent du registre.

Deux moteurs jouent ce verbe derrière le même manifeste — le rôle Ansible
(défaut, chemin client) et `labctl` (moteur du lab) — sélectionnés par un
knob de pipeline (`PROMOTE_ENGINE`), jamais par un paramètre de build. Le
détail du mécanisme, l'ordre des gardes et les limites nommées (dont le
4-yeux inerte tant qu'un plugin Jenkins manque, et le fail-open par palier
sans porte déclarée) sont dans **ADR-083 — Le verbe archive et son
transport**.

## Résiduel

- **Le lien entre le Jenkins local et celui du labs n'est pas établi.** Ce sont
  peut-être deux instances distinctes, peut-être la même exposée deux fois : rien
  ne permet de trancher tant que le portail masque l'instance publique.
- `mcp.gostoa.dev` (404) et `status.gostoa.dev` (injoignable) sont cités comme
  actifs — l'un dans CLAUDE.md, l'autre dans le dépôt.
- Les hôtes `dev-wm` / `rec-wm` / `vps-wm.gostoa.dev` cités dans le dépôt ne
  répondent pas (404 ou injoignables) : vestiges de topologies antérieures.
