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

## Résiduel

- **Le lien entre le Jenkins local et celui du labs n'est pas établi.** Ce sont
  peut-être deux instances distinctes, peut-être la même exposée deux fois : rien
  ne permet de trancher tant que le portail masque l'instance publique.
- `mcp.gostoa.dev` (404) et `status.gostoa.dev` (injoignable) sont cités comme
  actifs — l'un dans CLAUDE.md, l'autre dans le dépôt.
- Les hôtes `dev-wm` / `rec-wm` / `vps-wm.gostoa.dev` cités dans le dépôt ne
  répondent pas (404 ou injoignables) : vestiges de topologies antérieures.
