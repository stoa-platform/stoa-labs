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

## Qui déploie un palier (G2 — ADR-084)

Depuis G2, ouvrir un palier a **deux moitiés**, et les deux se disent :

1. **La rétention (G4, inchangée)** : mint AppRole / grant de la policy
   `apply-<env>` — sans elle, `PALIER_FERME`.
2. **La déclaration (G2, nouvelle)** : la porte du palier peut nommer un
   `deployerGroup` dans `environments.yaml` — un groupe de l'**annuaire LDAP**
   (familles `apim-apply-<x>` → policy `apply-<x>`, `apim-operator-<x>` →
   `operator-deploy`, rien d'autre). Le porteur de l'apply — sur la chaîne
   self-service : l'identité nominative de la pause, qui DOIT être le mergeur ;
   sur la chaîne gouvernance : l'AppRole granté (`--grant-ci`) ou l'opérateur
   prod — doit alors porter la policy projetée dans son token Vault
   (`lookup-self`), sinon **`DEPLOYER_GROUP_REQUIRED`**, avant tout moteur,
   gateway intouchée.

**Les refus et leur remède** :

| Refus | Cause | Remède |
|---|---|---|
| `DEPLOYER_GROUP_REQUIRED` | le porteur n'est pas du groupe déclaré | grant humain : l'ajouter au groupe LDAP (`setup-deployer-groups.sh`, knob `DEPLOYERS_<PALIER>`) — le droit suit l'ANNUAIRE ; machine : `setup-vault-paliers.sh --grant-ci` (déclare le CI porteur hors-prod) |
| `DEPLOYER_GROUP_UNSUPPORTED` | `deployerGroup` hors des deux familles vérifiables | corriger la déclaration dans `environments.yaml` (un nom KC comme `int-team` n'est PAS un groupe déployeur) |
| `DEPLOYER_GROUP_UNVERIFIABLE` | VAULT_ADDR absent, lookup-self en échec | rétablir Vault pour ce job — on ne déploie pas ce qu'on ne sait pas vérifier |

Gestes et pièges :

- **Poser l'annuaire du lab** : `bash scripts/setup-deployer-groups.sh`
  (bob→int, carol→homol par défaut ; contre-épreuve alice incluse). Un uid
  déclaré inexistant refuse le groupe entier (`MEMBRE_FANTOME`) ; un annuaire
  muet refuse SANS déclarer d'uid fantôme (`ANNUAIRE_INJOIGNABLE`).
- **Prod force l'imputabilité** : la porte déclare `apim-operator-prod` — le
  repli AppRole de Jenkinsfile.prod est désormais REFUSÉ (le token machine ne
  porte pas `operator-deploy`). Un humain du groupe (oscar), ou un grant
  explicite à un AppRole dédié.
- **Retrait ≠ révocation** (mesuré live) : un token émis AVANT le retrait du
  groupe garde la policy jusqu'à son TTL. Le retrait d'un déployeur prend
  effet au PROCHAIN login, pas sur les gestes en vol.
- **Porte de preuve live rejouable** : `bash scripts/test-deployer-gate-live.sh`
  (21/0, pose/mute/restaure l'annuaire lui-même — lab requis).

## Promouvoir une API (G5)

Depuis G5 (ADR-083), promouvoir une API publiée d'un palier au suivant n'est
**jamais** un re-POST du contrat : c'est un **import d'archive à GUID stable**
(ADR-079), transporté par le registre de packages génériques de Gitea,
adressé par le contenu (la version du package **est** le sha256 de
l'archive). Le palier cible doit être **ouvert** au sens de G4 — voir
« Ouvrir un palier (G4) » ci-dessus, ce geste n'est pas répété ici.

**Statut E2E.** La couche Jenkins (webhook → build → pause d'approbation) a
tourné **verte** sur ce lab (T10, 2026-08-27, après le push exploitant
`gitea/main = 646bf7b`). Le parcours ci-dessous est celui des builds réels :
`api-promote-export #1` pour l'export, puis `team-promote #13` (moteur
`ansible`, le défaut) et `#14` (moteur `labctl`) — **pause nominative
comprise**. Les deux contre-épreuves sont passées par des builds elles aussi :
`#15` refuse en `PALIER_FERME`, `#16` en `ARCHIVE_INTROUVABLE`, moteur jamais
lancé, catalogue du palier inchangé. La première preuve fut script-par-script
contre le même lab — c'est là qu'ont été isolés les écarts, dont la fidélité
base64 du mock (`0a1ac86`).

⚠ **Deux pièges d'exploitation mesurés pendant ce rejeu**, à connaître avant de
relancer une promotion :

- **La fenêtre keepalive du wM réel** (`restart-wm.sh`, cron `*/5`,
  `WM_MAX_MIN=20`) coupe les builds en vol : `team-promote #12` a passé toutes
  les gardes puis rendu `Connection refused` sur `webmethods-real:5555`, le
  conteneur ayant redémarré 2 minutes plus tôt. Le rejeu immédiat est vert.
  **Lancer les promotions juste après un cycle** — `docker inspect
  poc-webmethods-real` → `StartedAt` récent et `healthy`.
- **Gitea ferme la PR si sa branche est supprimée puis recréée trop vite**
  (course mesurée : `pull_push` puis `close`, alors qu'aucun script du dépôt ne
  ferme de PR). Le merge rend alors un `404 The target couldn't be found`
  opaque. Remède : relire l'état de la PR, `PATCH {"state":"open"}` (→ 201),
  puis merger. Et **ne jamais rejouer le webhook d'une PR dont la branche est
  supprimée** : `head.ref` devient `refs/pull/N/head`, le build répond
  `hors promote/* — rien à promouvoir` et sort **rc=0** — un no-op silencieux
  qui ressemble à une réussite.

Le parcours opérateur, pas à pas :

1. **Exporter** — job `api-promote-export` (TEAM, API_NAME, identité Vault
   nominative). Le job REND `apis/<api>.promote.yml` s'il est absent (gabarit
   `gateways/templates/promote.yml.tmpl`), exporte l'archive vers le registre
   (adressé par le contenu), puis ouvre la PR d'épinglage guid/sha256/version
   sur le dépôt d'équipe. Aucune recopie.
2. **Merger la PR d'épinglage** — c'est elle qui fixe l'id-map (guid) et les
   octets (sha256) que la promotion désignera (ADR-081 : la décision est le
   merge). Ré-export ⇒ la même PR est mise à jour, jamais empilée.
3. **Demander la promotion** — job `api-promote-request` (posé depuis le
   2026-08-28). `ARCHIVE_SHA256` FACULTATIF : vide, il est lu sur main
   (manifeste épinglé) depuis dev, hérité du palier source au-delà. Ouvre la
   PR `promote/<api>-<env>`.
4. **Merger la PR** — sous protection de branche (ADR-081/ADR-082) : c'est
   la décision humaine. Le merge déclenche `team-promote` via le **même**
   webhook que `team-publish` (aucun geste supplémentaire sur le dépôt
   d'équipe).
5. **Répondre à la pause** — le job `team-promote` demande une identité
   d'annuaire nominative. Elle **doit être celle qui a fusionné la PR** ; si
   la porte du palier cible exige les quatre yeux, elle sera comparée au
   demandeur (`promoted_by` du marqueur mergé).
6. **Vérifier** — le commentaire posé sur la PR (succès ou échec) porte le
   pin, la version, le sha256, le moteur utilisé, et les deux identités
   (demandeur, mergeur).

**Repli si l'archive n'a jamais été poussée.** Un refus
`ARCHIVE_INTROUVABLE` au moment du merge signifie que l'export (étape 1) n'a
jamais été rejoué depuis, ou a été rejoué avec un digest différent de celui
épinglé — **rejouer l'export** (étape 1), reprendre le `sha256` produit, et
soit corriger `ARCHIVE_SHA256` dans une nouvelle demande, soit republier au
même contenu si le digest attendu est simplement absent du registre.

Deux moteurs jouent ce verbe derrière le même manifeste — le rôle Ansible
(défaut, chemin client) et `labctl` (moteur du lab) — sélectionnés par un
knob de pipeline (`PROMOTE_ENGINE`), jamais par un paramètre de build. Le
détail du mécanisme, l'ordre des gardes et les limites nommées (dont le
4-yeux inerte tant qu'un plugin Jenkins manque, et le fail-open par palier
sans porte déclarée) sont dans **ADR-083 — Le verbe archive et son
transport**.

## Revenir en arrière (G6)

Depuis G6 (ADR-085), annuler une promotion approuvée n'est **jamais** prod-only
et **jamais** une suppression sur la gateway : c'est un revert Git de
`deploy.<env>.yaml` à son contenu N-1 **verbatim** (pin `commit` compris),
suivi d'un re-apply idempotent de l'état restauré. Aucun DELETE (ADR-075) — le
rollback restaure l'état désiré, il ne supprime pas la version N de la
gateway.

**Le palier n'est jamais saisi : c'est celui de la promotion.** Le job
`stoa-prod-rollback` ne demande pas d'environnement — la réponse du POST
gouvernance (`restored.environment`) le porte, et le Jenkinsfile la propage
lui-même à tous les stages aval. Saisir un palier recréerait une classe
d'erreurs (rollback de la promotion X « au nom » du palier Y) que la source
de vérité rend structurellement impossible.

Paramètres du job :

| Paramètre | Rôle |
|---|---|
| `PROMOTION_ID` | l'ID de la promotion à annuler (`obligatoire`) |
| `REASON` | le motif du rollback, audité (`obligatoire`) |
| `CHANGE_REF` | référence de changement ITSM — REQUISE seulement si le gate du palier de la promotion l'exige (`requireChangeRef` ou `itsmCheck`) ; sinon vide, sans effet |
| `VAULT_USER` / `VAULT_USER_PASSWORD` | identité NOMINATIVE de l'opérateur (voie A, ADR-078 §3) — pour l'acte imputable ; vides ⇒ repli AppRole (acte non imputable, refusé au terminus si `deployerGroup` y est déclaré, ADR-084) |

**Ce que fait chaque stage** :

1. **Rollback governance** — `POST .../promotions/{id}/rollback` en identité
   de service (`ci-applier`) : le corps porte `reason` et `change_ref`. Un
   palier qui exige une référence de changement (`requireChangeRef` ou
   `itsmCheck`) et n'en reçoit pas est refusé `GATE_REFS_REQUIRED` — **le job
   ne devine jamais** si une référence est requise, c'est governance-api qui
   le sait et refuse au plus tôt, avant toute lecture d'historique. La
   réponse (`restored.environment`, `restored.version`, `promotion.slug`) est
   capturée dans le workspace ; son absence est un échec fail-closed avant
   tout apply.
2. **Checkout governance (post-revert)** — re-clone COMPLET du dépôt
   governance : l'état à appliquer est l'état Git **après** le revert, jamais
   l'état lu avant l'appel.
3. **Palier du rollback** — la chaîne est dérivée du `environments.yaml` de
   CE clone (jamais une liste en dur, même motif que le pipeline aller) ; le
   palier restauré doit y figurer (`ROLLBACK_ENV_INCONNU` sinon) et ne peut
   pas être le palier d'authoring (`ROLLBACK_ENV_INELIGIBLE`, défense en
   profondeur). Le palier est déclaré **terminus** ou **intermédiaire** par sa
   POSITION dans la chaîne (dernier élément), pas par son nom.
4. **Re-apply** — deux voies, exactement celles du pipeline aller : le
   terminus re-applique en admin direct (ci-applier + secrets Vault) ; un
   palier intermédiaire re-applique via SON proxy `wm-admin-<env>` (Bearer
   `ci-horsprod`, scope `deploy:<env>`). Les deux voies passent par le MÊME
   preflight déployeur que l'aller (G2, ADR-084) : un re-apply machine vers
   int/homol exige `--grant-ci` ; un repli AppRole au terminus est refusé
   `DEPLOYER_GROUP_REQUIRED` si la porte y déclare `deployerGroup`.
5. **Smoke** — mesure l'ÉTAT restauré, pas un ping : le catalogue du palier
   (lu via son proxy admin) doit porter l'API restaurée **à la version N-1**
   (`restored.version`). Au terminus s'ajoute le smoke data-plane existant
   (401 sans token).

**Preuve.** Offline : 3 tests nouveaux sur `handlers_rollback_test.go` (dont
un qui rougit sur le code d'avant G6 — le trou de symétrie change_ref /
itsmCheck) ; 6 tests préexistants de fidélité `labctl Publish` réparés (défaut
découvert en cours de route : PUT inconditionnel sur une API active, que le
produit refuse — corrigé en sautant le PUT de définition quand l'API trouvée
est déjà active). Live : `scripts/test-rollback-paliers.sh`, 22/0 ×2 + rejeu
contrôleur (22/0) — rollback homol réel contre le wM du
lab, `deploy.homol.yaml` restauré verbatim, re-apply idempotent, smoke
catalogue à la version N-1, contre-épreuves prod (400 `GATE_REFS_REQUIRED`
sans change_ref, 409 double rollback, 409 `NO_PREVIOUS_STATE`). Détail complet
et décisions D1-D7 : **ADR-085 — Le repli, comme composant du déploiement**.

## Le parcours du demandeur (G7)

Depuis G7 (ADR-086), un producteur fait passer une API de dev à la prod en
**quatre PRs de promotion** — une par saut, chacune dans SON dépôt d'équipe,
chacune tableau de bord de son saut (ADR-081 : la décision est le merge ; le
formulaire Jenkins reste une porte d'entrée, il ne porte **aucune** autorité).

Le pas-à-pas, saut par saut :

1. **dev** (authoring) : publier via `team-publish`, exporter l'archive
   (`api-promote-export` ⇒ `EXPORT_CONFIRMED_SUMMARY guid=… sha256=…`),
   épingler le guid dans `apis/<api>.promote.yml` — inchangé depuis G5.
2. **dev → rec** : formulaire `api-promote-request` ⇒ PR `promote/<api>-rec`.
   Porte `selfApproval` (décision client n°1) : le demandeur merge lui-même,
   répond à la pause avec SA propre identité — qui doit porter `apply-rec`
   (palier ouvert au sens G4).
3. **rec → int** : PR `promote/<api>-int`. Porte `int-team` + 4-yeux + groupe
   déployeur `apim-apply-int` — au lab : **bob** merge, bob répond à la pause
   (le mergeur est le seul login que la pause accepte, `MERGER_MISMATCH`).
4. **int → homol** : PR `promote/<api>-homol`, `PV_REF` exigé À LA DEMANDE.
   Porte `release-team` + 4-yeux + `apim-apply-homol` — au lab : **carol**.
5. **homol → prod** : PR `promote/<api>-prod`, `CHANGE_REF` + `PV_REF` exigés.
   Porte `release-team` + 4-yeux + `itsmCheck` + `apim-operator-prod` — au
   lab : **oscar**. Deux différences PROPRES au terminus :
   - **la voie est DIRECTE** (pas de proxy `wm-admin-prod` — il n'existe pas,
     par structure) : le moteur ansible attaque la gateway du terminus en
     Basic, creds `envs/prod/wm-admin` lus dans Vault par le rôle. Le moteur
     labctl est refusé vers le terminus (`COMBINAISON_NON_SUPPORTEE`).
     ⚠ **Au LAB, le terminus est `wm-mock-prod`** (seul mock joignable de
     Jenkins — le contrat du terminus), pas la gateway réelle : l'importeur du
     PRODUIT refuse une archive fabriquée par le mock d'authoring (« No assets
     found in the ACDL import file », mesuré builds #21/#23) — la chaîne
     d'équipe du lab est homogène mock→mock, et le verbe réel→réel reste
     prouvé par ADR-079 sur la gateway réelle. Chez un client (tout-réel), le
     gabarit `APIM_DIRECT_BASE_TPL` par défaut vise la gateway réelle ;
   - **l'ITSM est re-vérifié au dispatch** (§6ter) : le change du marqueur
     MERGÉ doit être `approved` À CE MOMENT-LÀ — `ITSM_NOT_APPROVED` sinon,
     `ITSM_UNAVAILABLE` si l'ITSM ne répond pas, fail-closed dans tous les cas
     (anti-TOCTOU A6, porté à la chaîne d'équipe).

**Ce que chaque PR porte** (le tableau de bord) : le corps de la demande (pin,
digest, groupes attendus/vérifiés, et — quand la porte le déclare — l'annonce
de la re-vérification ITSM), puis le commentaire d'apply (pin, version,
sha256, moteur, et les **trois identités : demandée par / mergée par / portée
par**), puis le statut du build (succès, échec, ou pause abandonnée).

**Refuser est un commentaire, pas un silence.** Tirer le webhook sur une PR
NON mergée refuse `PAYLOAD_PERIME` (la réconciliation Gitea fait foi, jamais
le payload) ; un palier sans marqueur mergé refuse `PIN_ABSENT` ; un moteur
jamais lancé sur refus est la propriété prouvée garde par garde
(`test-team-promote-wiring.sh`, 160/0).

**Preuve (2026-08-27, builds Jenkins réels).** Parcours complet sur
`banking-demo/accounts-api`, API `t10-promote-api` : export `api-promote-export
#2` (guid stable, digest frais), puis PRs #22/#23/#24/#25 mergées par
bob/bob/carol/oscar, builds `team-promote` **#18/#19/#20/#24 SUCCESS** —
GUID `14c2529e-…003` **actif et identique sur les quatre paliers**, chaque PR
portant ses trois couches (plan / résultat avec les trois identités / statut
build). Contre-épreuves par builds : **#25 FAILURE `PAYLOAD_PERIME`** (webhook
forgé sur la PR #26 jamais mergée — moteur jamais lancé, catalogue inchangé) et
**#26 FAILURE `ITSM_NOT_APPROVED`** (la même PR verte en #24 refuse dès que le
change repasse `draft` — anti-TOCTOU au dispatch). Les builds #21/#23 sont la
MESURE de la limite mock→réel citée plus haut.

Détail des décisions et des refus nommés : **ADR-086 — Le parcours du
demandeur : une PR, un tableau de bord**.

## La parité des deux moteurs (G8)

Le verbe archive est porté par **deux moteurs** (`apim_promote_api` côté
client, `labctl promote` côté lab — ADR-083, décision n°6 du GOAL). Depuis G8
(ADR-087), leur iso-sémantique n'est plus une promesse : c'est une **porte
rejouable**, dont la définition exacte vit dans un registre versionné.

**Rejouer la porte** (gateway réelle + Vault du lab requis, ~6 min) :

```bash
./scripts/test-parity-moteurs.sh          # 29/0 attendu
```

Le harnais exporte la même API par les deux moteurs (artefacts comparés entrée
par entrée), importe la **même archive** par chacun sur un palier remis à
vierge entre les deux, et **diffe les états** (API par GUID, graphe de
politiques, aliases per-env — cred Vault compris —, scope-mapping, sonde
data-plane). Il attend ensuite le ROUGE sur deux mutations volontaires (un
moteur qui saute le scope-mapping doit se voir), et rejoue la porte en lecture
seule par les deux moteurs :

```bash
# côté rôle (le --tags verify) :
ansible-playbook ansible/promote-api-verify.yml -e apim_ss_env=rec \
  -e apim_promote_manifest=<...>.promote.yml
# côté lab :
labctl promote --manifest <...>.promote.yml --env rec --action verify -f targets.yaml
```

**Le registre des écarts assumés** : `scripts/testdata/parity-ecarts.txt` —
consommé PAR le harnais (lignes `state` = chemins exclus du diff, `artifact` =
motifs normalisés, TAB-séparés, raison obligatoire). Un écart qui n'y est pas
**rougit**. Registre humain complet (avec les mesures et les écarts de moteur
hors état — digest rôle/CI seulement, terminus ansible-only, auth admin) :
ADR-087.

**Quand la parité rougit** : mesurer l'écart. Volatil et sans effet runtime ⇒
il entre au registre AVEC sa raison. Sémantique ⇒ on répare le moteur fautif —
la porte a attrapé `passSecurityHeaders` divergent à sa première exécution,
c'est son travail. Jamais d'exclusion de confort.

**Réflexe** : avant de toucher `ansible/roles/apim_promote_api/` ou
`labctl/cmd/labctl/promote.go` (et ses primitives d'`archive.go`), rejouer la
porte ; après, aussi.

## La référence d'une application (A2 — GOAL cd-applications)

Pour une **API**, la référence de déploiement est le pin `deploy.<env>.yaml`
(G3). Pour une **application**, il n'y a ni archive ni pin : la PR
`provision/<app>-<env>` **est** le fichier de déploiement du palier, et son
**SHA de merge** est la référence. Depuis A2 (2026-09-02), `provision-apply`
ne projette plus « le dernier `main` » :

1. **Réconciliation, AVANT la pause** (`scripts/provision-apply-reconcile.sh`)
   — le webhook (token GWT partagé, HMAC non vérifié) ne fait pas foi. La PR
   est relue sur la **forge** : `merged` / `merge_commit_sha` / `head.ref` /
   `base.ref == main` doivent concorder, sinon **`PAYLOAD_PERIME`** ; la PR ne
   doit toucher QUE son manifeste et son certificat de palier, sinon
   **`PR_HORS_PERIMETRE`** (l'aval checkoute l'arbre entier au SHA mergé). Puis
   `main` est relu par **git** : le SHA est un ancêtre de `main`
   (`MERGE_SHA_NON_ANCETRE`) et le manifeste effectif du palier au SHA mergé est
   encore celui que `main` porte pour ce palier, sinon **`PALIER_SUPPLANTE`** —
   le rejeu (« Redeliver ») d'une PR ancienne ne re-projette jamais un état
   dépassé. Personne n'est réveillé pour un refus. Les identités
   mergeur/demandeur viennent de la forge, jamais du payload : la garde
   d'identité (`MERGER_MISMATCH`, `FOUR_EYES_VIOLATION`) ne peut plus être passée
   par un tir manuel qui « s'annonce » mergeur. Un refus n'est commenté que si
   la forge a confirmé une PR `provision/*`, sous le marqueur
   `<!-- provision-apply-refus -->` — distinct de celui du résultat d'apply : un
   webhook forgé ne peut pas réécrire l'enregistrement SHA/digest d'un apply réel.
2. **La pause nominative** (V_USER / V_PASS), sans exécuteur réservé.
3. **L'apply au SHA mergé** : `selfservice-app-deploy` reçoit `MERGE_SHA` ;
   appelé par un job amont SANS référence, il refuse **`MERGE_SHA_REQUIS`**
   (paramètre non matérialisé, appelant d'avant A2) ; sinon `git fetch origin
   main` → `merge-base --is-ancestor` (`MERGE_SHA_NON_ANCETRE`) → lignée
   first-parent (`MERGE_SHA_HORS_LIGNEE`) → `git checkout` — le PLAN et l'APPLY
   lisent le manifeste **dans cet arbre** — puis, **après converge + verify**,
   annonce `APPLIED_MODE=pinned` / `APPLIED_SHA` (= `git rev-parse HEAD`) /
   `APPLIED_DIGEST`. L'amont **confronte** l'annonce à sa demande, hors de tout
   nœud (aucun exécuteur tenu pendant l'aval) : un aval vert qui n'a pas projeté
   `MERGE_SHA` en mode `pinned` est un échec nommé **`SHA_NON_CONFIRME`**, et le
   commentaire dit alors ce qui a été projeté (jamais « pas déployé »).
4. **La PR comme tableau de bord** : le commentaire d'apply porte l'identité,
   le **SHA appliqué** (lien cliquable) et le **digest du manifeste effectif
   du palier** (racine ⊕ `per_env.<env>`, la fusion du rôle) à ce SHA — la
   réponse à « qu'est-ce qui tourne en rec ? ». Le digest est le SHA-256 du
   JSON canonique (`app_manifest_digest_env`, lib `scripts/lib/app-manifest.sh`) :
   insensible à la forme, sensible au fond (palier ET racine), un autre palier
   n'y entre pas. Trois marqueurs cohabitent sur la PR : `provision-apply`
   (résultat d'un apply réel), `provision-apply-refus` (refus avant la pause),
   `provision-apply-build` (statut build, posé seulement si la forge a confirmé
   une PR `provision/*`).

Le job `provision-apply` est désormais un **Jenkinsfile déclaratif from SCM**
(`ci/Jenkinsfile.provision-apply`) ; `ci/jenkins/provision-apply.job.xml` n'est
qu'une coquille (pointeur SCM + miroir du bloc `<triggers>`, qui gagne).

## Le credential du seul palier (A3 — GOAL cd-applications, 2026-09-02)

**Ce qui a changé.** `selfservice-app-deploy` ne lit plus
`deploy/<tenant>/wm-admin` avec un en-tête `X-Environment` qui « choisissait »
le palier : il lit **`envs/<env>/wm-admin`** (voie directe, Basic) ou
**`envs/<env>/admin-oauth`** (voie proxy, Bearer via `wm-admin-<env>`) avec le
token nominatif de la pause — et **la lecture d'`envs/<env>/wm-admin` EST le
ticket d'entrée** (ADR-082, le même qu'en `team-promote` §7.b). Une identité
qui ne porte pas `apply-<env>` est refusée `PALIER_FERME` **avant** tout
contact avec la gateway ; l'équipe de cloisonnement est **décidée par le
token** (policies `deploy-<tenant>`), le manifeste et `APIM_TEAM` ne peuvent
que concorder (`TEAM_NON_PORTEE` sinon). Spec :
`docs/superpowers/specs/2026-09-02-a3-credential-du-seul-palier-design.md`.

**Le dessin de l'Apply** (ordre = la propriété) : `MOT_DE_PASSE_ALTERE` → login
nominatif → **la garde** `scripts/selfservice-palier-gate.sh`, extraite de
`origin/main` (`git show`, jamais l'arbre pinné au `MERGE_SHA` — le levier A6
pinnerait la garde avec) → préflight de joignabilité **annoncé** (`préflight de
joignabilité :`) → `TTL_INSUFFISANT` (le mount ldap tune les tokens à 600 s, le
préflight peut durer autant) → converge → verify → annonce A2. La garde ne
parle qu'à Vault : forme (`ENV_INVALIDE`, `VIA_INCONNU`,
`CREDS_SUB_SANS_PALIER`), voie par POSITION (`TERMINUS_SANS_VOIE`), équipe par
le token (`TEAM_INDETERMINEE` / `TEAM_AMBIGUE` / `TEAM_NON_PORTEE` /
`IDENTITE_INVERIFIABLE`), capacités en un appel (`TICKET_INSCRIPTIBLE` — un
ticket qu'on peut s'écrire n'est pas un ticket ; `TENANT_NON_PORTE` en mode
`internal` sur le `vault_sub` du palier ; `CAPACITES_INVERIFIABLES`), puis le
ticket (`PALIER_FERME`), puis `PALIER_OUT` (forme contrôlée, relue par le shell
sans `eval`).

**Knobs (bloc `environment{}` du Jenkinsfile, surchargeables par variable
globale)** : `APIM_WM_CREDS_SUB_TPL` (`envs/__ENV__/wm-admin`) et
`APIM_OAUTH_SUB_TPL` (`envs/__ENV__/admin-oauth`) — `__ENV__` **obligatoire** ;
`APIM_API_BASE` (voie directe hors terminus, `__ENV__` optionnel — une gateway
par palier chez un client, une seule sur ce lab) ; `APIM_PROXY_API`
(`wm-admin-__ENV__`) ; **`APIM_TERMINUS_BASE`, sans défaut** — tant qu'elle
n'est pas déclarée, le terminus n'a pas de voie (par position, pas par son
nom) ; `APIM_TEAM` (borné par le token) ; `APIM_TOKEN_TTL_MIN` (180 s). ⚠ Ne
PAS réutiliser `APIM_DIRECT_BASE_TPL` (chaîne des APIs) pour les applications :
sur ce lab elle vise `wm-mock-prod`.

**Rollout sur ce lab (l'ordre compte)** — joué le 2026-09-02 :

```bash
git push gitea HEAD:main                                  # la garde est extraite de gitea main
VAULT_TOKEN=… GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=… \
  bash scripts/setup-wm-palier-admins.sh                  # wm-<env>-admin sur la gateway réelle (12/0 ; perdus au re-seed)
DEPLOYERS_DEV=alice DEPLOYERS_REC=alice bash scripts/setup-deployer-groups.sh   # le grant nominatif (15/0)
VAULT_TOKEN=… bash scripts/test-palier-retention-live.sh  # la porte du GOAL : ⑦ la voie application (37/0)
bash scripts/test-a3-live.sh                              # par builds réels (voir la spec, D7)
```

Le grant `DEPLOYERS_DEV/REC=alice` est un **geste explicite** (les défauts du
poseur restent fermés pour dev/rec) : c'est la décision client n°1 (dev et rec
autonomes pour qui remplit le formulaire) appliquée à l'identité qui demande
sur ce lab — et il ouvre `rec` **aux deux objets** (le même ticket sert la
promotion d'API vers rec : le credential est par palier, pas par objet).

**Limites, mesurées** : sur ce lab **mono-gateway**, les quatre comptes
`wm-<env>-admin` sont tous `API-Gateway-Administrators` de la même 10.15 —
détenir `apply-dev` administre les objets de tous les paliers ; la porte A3
mesure la rétention côté Vault (Vault refuse), pas le cloisonnement au plan de
données (celui-ci est topologique : une gateway par palier chez un client).
`X-Environment` est toujours émis par le rôle (transport redondant). Le
terminus n'est fermé ni par un `if` ni par un nom : `TERMINUS_SANS_VOIE` tant
qu'aucune voie n'est déclarée, puis le credential ; A4 (la porte de la chaîne :
groupe déployeur, quatre yeux, refs/ITSM — section suivante) et A7 (ouverture — FAIT le 2026-09-03, section « Le terminus et le parcours complet »)
posent le reste. `USER_VAULT_JWT` (voie B) reste un
paramètre `string` sur le canal `withEnv` (état A0, nommé).

## Les portes de la chaîne au dispatch (A4 — GOAL cd-applications, 2026-09-02)

**Ce qui a changé.** `provision-apply` lit désormais `environments.yaml` par la
même lib que `team-promote` (`scripts/lib/env-chain.sh`), et la porte du
palier **décide** : quatre yeux, références (`change_ref`/`pv_ref`) et ITSM,
terminus par position, déclaration déployeur. Aucun mécanisme neuf : la §6 /
§6bis / §6ter / §7.a de `team-promote.sh` portées au second objet. Spec :
`docs/superpowers/specs/2026-09-02-a4-portes-de-la-chaine-au-dispatch-design.md` ;
ADR-084 étendu (« Extension 2026-09-02 (A4) »).

**Le dessin** (ordre = la propriété) :

1. **La porte de l'amont** (`scripts/provision-apply-gate.sh`) est jouée
   **deux fois** par `ci/Jenkinsfile.provision-apply` : `GATE_STAGE=pre` après
   la réconciliation et **avant la pause** (un refus ne réveille personne),
   puis `GATE_STAGE=dispatch` sous le nœud post-pause, **avant la garde
   d'identité** — c'est ce passage qui fait foi (anti-TOCTOU, ADR-075), qui
   donne `--allow-self-approval` à `assert-merge-identity.sh` quand la porte le
   déclare (`GATE_ALLOW_SELF`, sentinelle `GATE_ENV` : `PORTE_INCOHERENTE`
   sinon) et qui nourrit la ligne « porte du palier » du rapport de PR. La
   chaîne est **épinglée** sur le clone par la ligne d'appel
   (`STOA_ENV_CHAIN_FILE="$PWD/clients/_example/environments.yaml"`) et son
   chemin est imprimé (`chaîne : …`) : une variable globale Jenkins ne peut
   plus rediriger la politique. Refus, dans l'ordre : `CHAINE_INVALIDE`
   (`env_chain_validate` — une porte `to: itn` ou une clé mal orthographiée ne
   relâche rien en silence), `ENV_INVALIDE`, `PARSE_GATE`,
   `DEPLOYER_GROUP_UNSUPPORTED` (hors famille, ou `apim-apply-<x>` qui ne nomme
   pas le palier de sa porte), `MANIFESTE_ABSENT`/`MANIFESTE_ILLISIBLE`,
   `REF_INVALIDE`, `GATE_REFS_REQUIRED`, `REQUESTER_UNKNOWN` (la porte exige
   les quatre yeux mais la PR a été ouverte par un compte de service — la forge
   ne nomme aucun demandeur humain : refus, jamais un silence),
   `FOUR_EYES_VIOLATION`, `ITSM_NOT_CONFIGURED`/`ITSM_NOT_APPROVED`/`ITSM_UNAVAILABLE`,
   `TERMINUS_SANS_VOIE` (par position, **après** l'ITSM). Le refus est commenté
   sur la PR (`REFUSAL_KIND=porte`, marqueur `provision-apply-refus`).
2. **La déclaration déployeur est vérifiée à l'aval, sur le token de la
   pause** — le seul site qui le tient : `scripts/selfservice-palier-gate.sh`
   §2bis, entre l'équipe (§2) et les capacités (§3), **avant le ticket** —
   `DEPLOYER_GROUP_REQUIRED` (le nom de la politique), jamais le 403 de
   capacité. Console : `déclaration déployeur : 'alice' porte 'apply-int'
   (groupe 'apim-apply-int')`. Le tag du refus remonte jusqu'à la PR
   (`REFUS_OUT="$WORKSPACE/.a3-refus"` → `post{always}` du stage Apply →
   `buildVariables.APPLIED_REFUSAL`, fait Jenkins 11 mesuré) ; la garde valide
   la chaîne (`CHAINE_INVALIDE`) et l'aval l'épingle sur son extraction de
   `origin/main`.
3. **`approverGroup` est matérialisé, vérifié par personne** — console,
   `GATE_OUT`, PR : « approbation attendue `int-team` — non vérifiée (aucun
   mécanisme ne la tient sur cette chaîne) ». La protection de branche du lab
   ne borne que le push direct. **Et approuver = porter** sur les deux chaînes
   Gitea : le mergeur d'`int` doit être membre d'`apim-apply-int`.

**Knobs (bloc `environment{}` de `Jenkinsfile.provision-apply`, surchargeables
par variable globale)** : `ITSM_URL` (défaut `http://itsm-mock:8788`, le
défaut de `team-promote` — un client sans la globale obtient `ITSM_UNAVAILABLE`),
`ITSM_CACERT`, `APIM_TERMINUS_BASE` (**sans défaut**, le nom de l'aval — tant
qu'elle n'est pas déclarée, le terminus est refusé avant la pause),
`GITEA_SERVICE_LOGINS` (défaut `ci` : les comptes de service de la forge).
Les listes des formulaires (`app-request`, `selfservice-app-deploy`) dérivent
toujours de la chaîne (A0) ; `app-request-choices.sh` refuse désormais une
chaîne invalide (`CHAINE_INVALIDE`) — « deux portes, une source » est prouvé
hors ligne (retirer `int` de la chaîne ⇒ le formulaire ne le propose plus, la
demande, la porte amont et la garde aval le refusent `ENV_INVALIDE`).

**Rollout sur ce lab** — `git push gitea HEAD:main` et rien d'autre : l'amont
est from SCM, l'aval extrait sa garde et la lib de `origin/main` ; aucune
re-pose (aucun paramètre nouveau), l'annuaire et les comptes gateway sont ceux
d'A3. `bash scripts/test-a4-live.sh` joue et restaure lui-même la seule
mutation d'annuaire de la preuve (alice ↔ `apim-apply-int`) et crée le compte
de forge humain `carol` s'il manque.

**Limites, mesurées** :

- **Sur les voies livrées, `int` refuse `REQUESTER_UNKNOWN`** : `app-request`
  et `provisioning-request` ouvrent la PR sous `ci`, la forge ne nomme aucun
  demandeur humain — la porte à quatre yeux, inerte avant A4 (`ci ≠ alice`
  passait toujours), est **fermée**. A7 ouvre la PR sous l'identité humaine (FAIT : `FORGE_TOKEN`, ADR-090).
  Un `requested_by` dans le manifeste n'est pas une réponse (forgeable dans
  la PR par son auteur).
- **`rec` est relâché au sens de la porte** (`selfApproval: true`, décision
  client n°1) : avant A4 les quatre yeux y étaient exigés (inertes). La
  fermeture est une ligne (`fourEyes: true`) — et rend alors `rec`
  `REQUESTER_UNKNOWN` sur les voies livrées jusqu'à A7.
- **`homol` refuse `GATE_REFS_REQUIRED`** tant que la demande ne porte pas
  `per_env.<env>.pv_ref` (A7 ajoute le champ — FAIT : `PV_REF` au formulaire) ; avant A4, `homol` s'appliquait
  sans aucune porte.
- **« Même équipe » n'est pas vérifié** : un autre humain de l'équipe (carol)
  qui merge la PR d'alice passe la porte — mesuré ; c'est l'axe `approverGroup`.
- **Le terminus est refusé avant la pause, par position, après l'ITSM** ; A7
  déclare `APIM_TERMINUS_BASE` aux deux sites.
- **Mono-gateway** : appliquer `int` **écrase** l'état `rec` du même objet
  (un objet par nom sur la 10.15 unique) — chez un client, un objet par
  gateway de palier.
- Seuls les refus de la GARDE de l'aval portent un tag jusqu'à la PR
  (`TTL_INSUFFISANT`, login refusé, `GATE_ABSENTE`… restent « EN ÉCHEC — voir
  la console ») ; `--map` n'est pas supporté par l'appel pré-pause ; le
  parseur Go accepte les clés inconnues d'`environments.yaml`, le shell les
  refuse (écart enregistré).

## L'ordre app/API (A5 — GOAL cd-applications, 2026-09-03)

Depuis A5 (ADR-088), **une application ne précède jamais son API au palier**.
Avant sa première écriture, l'apply d'application (le rôle
`apim_selfservice_app`, §1) relit la liste des APIs de la gateway du palier
et refuse, nommément, si l'API du manifeste n'y est pas **dans cette version,
active** :

| Ce que la gateway du palier présente | Refus | Le remède, nommé sur la PR |
|---|---|---|
| aucune API de ce nom | `API_NOT_PROMOTED` | promouvoir l'API vers le palier par la chaîne des APIs (`api-promote-request` → PR `promote/<api>-<env>` → merge → `team-promote`, G5) |
| le nom, mais pas cette version | `API_VERSION_MISMATCH` (les versions présentes sont citées) | promouvoir cette version, ou corriger la demande — `api_version` est figé (A1) : une autre version est une NOUVELLE application |
| plus d'une entrée nom+version | `API_AMBIGUE` | un état de gateway à corriger à la main (la 10.15 ne devrait pas le produire) |
| présente mais **inactive** (`isActive` faux, absent ou non booléen) | `API_INACTIVE` (valeur vue et id cités) | activer l'API au palier — geste producteur |

Puis **rejouer le webhook** de la PR mergée (`generic-webhook-trigger`, token
`stoa-provision-apply`, le payload de fusion) : rien n'a été écrit sur la
gateway, la PR reste la référence, inutile de rouvrir une demande. Le
commentaire de PR porte le tag, **la phrase** (« aval selfservice-app-deploy
#n : … ») et le paragraphe « L'ordre app/API ». Depuis A5, les refus de la
garde A3 (`PALIER_FERME`, `DEPLOYER_GROUP_REQUIRED`…) arrivent eux aussi avec
leur phrase.

**Ce que la console de l'aval montre** : `palier ouvert : envs/<env>/wm-admin`
< `préflight de joignabilité :` < `PLAY [Self-service application — converge`
< `REFUS: API_INACTIVE : …` (aucune tâche « App : créer », aucun verify) ; sur
le chemin nominal `API_AT_PALIER : '<api>' v<ver> active au palier '<env>'
(id=<uuid>)`, puis au verify `API_AT_PALIER_CONFIRMED` et
`SUBSCRIPTION_CONFIRMED : '<app>' souscrite à '<api>' v<ver> (id=<uuid>)` —
le GUID promu, relu. Un verify rejoué après une désactivation rougit
(`API_AT_PALIER_UNCONFIRMED`), une souscription remplacée aussi
(`SUBSCRIPTION_UNCONFIRMED`) : le rapport dit alors « la convergence a eu
lieu », jamais « rien n'a été écrit ».

**Pourquoi avant l'écriture, et pas « poser puis défaire »** : le spike du
2026-09-02 a mesuré qu'une paire application/API qui a servi du trafic ne se
ré-inscrit plus après désinscription (500 irréversible). La porte est donc la
dernière lecture avant `POST /applications`, et les preuves hors ligne le
tiennent par mutation (porte déplacée après la création ⇒ une écriture part
avant le refus ⇒ rouge).

**Limites, mesurées** : sur ce lab **mono-gateway**, « promouvoir vers rec »
n'est pas jouable (dev/rec/int = la même 10.15) — la porte est prouvée sur les
trois situations que la gateway du palier peut présenter, et le « rejeu après
promotion » est le rejeu après **réactivation** du même objet, GUID identique
relu. Le plan (`provision-plan`) ne sait pas : lecture seule, sans credential
gateway — le demandeur apprend le refus à l'apply, sur la PR. La porte suit la
**lignée du rôle**, épinglée au SHA appliqué (A2) : un repli vers un SHA
antérieur à A5 rejouerait le rôle d'alors, sans porte (artefact du lab — A6 le
dira). Le formulaire `app-request` propose les APIs de `publish.yml`
(authoring), pas celles du palier : ergonomie, pas autorité.

**Rollout sur ce lab** : `git push gitea HEAD:main` suffit — le rôle appliqué
est celui de l'arbre pinné au `MERGE_SHA` (une PR mergée après le push porte
A5), la garde A3 est extraite de `origin/main`, aucun job re-posé, aucune
globale. Preuve : `bash scripts/test-a5-live.sh` (≈ 25 min ; désactive puis
réactive `demo-selfservice`, trap inconditionnel).

## Revenir en arrière — applications (A6 — GOAL cd-applications, 2026-09-03)

**Le repli d'une application est une PR** (ADR-089). Le formulaire Jenkins `app-rollback` (APP, ENV, REASON, CHANGE_REF) ouvre une PR `provision/<app>-<env>` dont la ligne `per_env.<env>` et le certificat `certs/<app>-<env>.crt` redeviennent, **à l'octet**, ceux du merge **précédent** (N-1) de cette même branche ; puis la chaîne de tous les jours l'applique — merge, `provision-apply` (portes A4 deux fois, pause nominative), `selfservice-app-deploy` (garde A3, rôle avec porte A5, verify). Le verbe est la convergence : **même GUID, même clé** (spike S1). C'est le port de G6 (ADR-085 : N-1 verbatim dans un commit neuf, puis re-apply) à l'objet dont la PR est le fichier de déploiement.

**Parcours opérateur.**
1. `app-rollback` → Build with Parameters : `APP`, `ENV` (la chaîne entière — terminus compris —, ce sont les portes qui décident), `REASON`, `CHANGE_REF` (exigé si la porte du palier porte `requireChangeRef` ou `itsmCheck` : `GATE_REFS_REQUIRED` sinon, **aucune PR ouverte**, aucun clone).
2. Le build imprime `ETAPE …` (forme → chaîne → porte → clone → manifeste → lignée → cohérence → candidate → identique → restauration → vérification → pr-en-cours → tête distante → commit → push → pr), `LIGNEE : #N (…) #N-1 (…)`, puis `PR_URL=…` et `REPLI_DE=<sha N> REPLI_VERS=<sha N-1> REPLI_DIGEST=<sha256:…>`. La description du build porte la PR.
3. **La PR de repli** montre la lignée (#N remplacé, #N-1 restauré), **la ligne restaurée**, le cert (restauré / supprimé / inchangé), le **digest attendu** — à comparer à la ligne « digest du manifeste effectif » du rapport de `provision-apply` après l'apply —, le `change_ref` s'il y en a un, et `REPLI_DU_REPLI` si #N est lui-même un repli. Le commit de branche porte les trailers `Repli-De`, `Repli-Vers`, `Repli-Motif`, `Repli-Par`, `Repli-Digest`, `Change-Ref`.
4. **Merger** (les portes du palier : en `rec` le demandeur peut merger lui-même ; en `int`+ quatre-yeux, `deployerGroup`, refs, ITSM ; jusqu'à A7 une PR ouverte par `ci` refuse `REQUESTER_UNKNOWN` sur `int`+) → `provision-apply` : `RECONCILE_OK`, **`REPLI_OK`** (main n'a pas bougé pour ce palier entre la demande de repli et le merge — sinon **`REPLI_PERIME`**, rejouer la demande), `PORTE_OK(pre)`, pause → identité → `PORTE_OK(dispatch)` → aval.
5. **La lecture qui prouve** : `GET /applications/{id}` — même `id`, même `apiAccessKey`, mêmes `consumingAPIs`, identifiers (IP `X-X`, cert `name`/`value`, claims) == ceux de l'état N-1 ; verify : `API_AT_PALIER_CONFIRMED`, `SUBSCRIPTION_CONFIRMED (id=…)`, `CERT_NAME_CONFIRMED` ; Git : la ligne `per_env.<env>` de `main` == celle du merge N-1 ; PR : ✅ et le digest annoncé.

**Les refus de la demande, et leurs remèdes** : `GATE_REFS_REQUIRED` (fournir `CHANGE_REF`) ; `AUCUNE_LIGNEE` (aucune PR `provision/<app>-<env>` mergée depuis la création du manifeste) ; `AUCUN_ETAT_PRECEDENT` (un seul état : le retrait est une **suspension**, pas un repli) ; `REFERENCE_DIVERGENTE` (main écrit hors flux : corriger par une demande) ; `RACINE_DIVERGENTE` ; `ETAT_IDENTIQUE` (rien à replier — une dérive de la gateway se corrige en rejouant le webhook de #N, A2) ; `PR_EN_COURS` (une PR est ouverte sur la branche : la merger ou la fermer) ; `BRANCHE_NON_MERGEE` (des commits poussés à la main sans PR) ; `FORGE_INCOHERENTE` / `LIGNEE_AMBIGUE` / `FORGE_ILLISIBLE` ; `LIGNEE_TRONQUEE` ; `LIGNE_AMBIGUE` / `REF_DUPLIQUEE` ; `PUSH_ECHEC` (bail perdu : rejouer). Une demande émise pendant qu'une PR de repli est ouverte est refusée `REPLI_EN_COURS` par `provision-request.sh` (rien poussé).

**Le repli du repli** restaure N (profondeur 1, jamais N-2) — la demande l'annonce (`REPLI_DU_REPLI`) ; si l'apply de #N a été refusé, le remède est le rejeu de son webhook, pas un repli de plus. **Le levier direct** (un `MERGE_SHA` de la lignée saisi sur l'aval) n'est **pas** le repli : c'est un rejeu hors chaîne, borné par A3, sans les portes A4.

**Limites écrites** : l'état restauré est l'état **déclaré** (Git), pas l'état servi (un N-1 mergé puis refusé à l'apply est restauré tel que déclaré et repasse les portes) ; un repli vers « sans cert » retire le fichier de Git mais **laisse le cert de N sur la gateway** (le rôle préserve les dimensions absentes du manifeste — dette du rôle) ; mono-gateway sur le lab ; la suspension (verbe de retrait) n'est pas écrite.

**Preuves** : hors ligne `scripts/test-app-rollback-a6.sh` 82/82 (`make lint-ci` [15/15]) ; par builds réels `scripts/test-a6-live.sh` **49/49** au 4e passage (repli #16 → PR #511 → provision-apply #156 → aval #102 SUCCESS, gateway lue à l'état N-1 : même GUID, même clé, IP et cert de N-1 ; chiffres complets dans le GOAL). Pose du job : `JOBS=app-rollback BOOTSTRAP_JOBS=app-rollback scripts/setup-provision-jobs.sh`.

## Le terminus et le parcours complet — applications (A7 — GOAL cd-applications, 2026-09-03)

**Ouvrir `prod` aux applications n'est pas un edit** (ADR-090) : c'est **déclarer**
la voie (`APIM_TERMINUS_BASE`, globale Jenkins lue par les deux sites — sur ce lab
`http://wm-mock-prod:8080/rest/apigateway`, posée par le harnais et restaurée
après le passage), **accorder** le credential (`envs/<terminus>/wm-admin` = l'admin
de la gateway du terminus, posé par `scripts/setup-terminus-apps.sh`, lu par
`operator-deploy` depuis G7) et laisser la **porte** décider (`deployerGroup:
apim-operator-prod` — oscar —, ITSM re-vérifié au dispatch). Ce qui manquait pour
parcourir les cinq paliers était ailleurs, et A7 le ferme :

- **la demande sous identité de forge** : le formulaire `app-request` (et
  `app-rollback`) porte `FORGE_TOKEN` — votre token d'accès personnel de la forge,
  scopes **`read:user + write:repository`**, token dédié, à révoquer après. La PR
  est ouverte **sous votre identité** (c'est elle que la porte à quatre yeux
  confronte au mergeur) ; le compte de service reste celui des lectures et du
  plan. Sans token, vers un palier à `fourEyes` : `REQUESTER_UNKNOWN` **à la
  demande**, aucune PR. `TOKEN_ALTERE` (un `$` dans le token, résolu par Jenkins)
  et `TOKEN_GLOBAL_REFUSE` (champ vide, globale posée) ferment les deux pièges du
  canal ; la voie machine (`provisioning-request`) vide `FORGE_TOKEN` — elle ne
  demande pas au-delà des paliers autonomes (décision client n°3) ;
- **l'équipe sous une déclaration de déployeur vient de Git** : bob, carol et
  oscar ne sont pas tenants ; la garde du palier (`selfservice-palier-gate.sh`
  §2ter) lit `team:` du manifeste mergé quand la porte nomme un déployeur
  **prouvé** (§2bis d'abord), et refuse `TEAM_INDETERMINEE` si le manifeste n'en
  nomme aucune (nommer l'équipe **dès la première demande** : une application sans
  équipe est confinée aux paliers autonomes), `TEAM_DIVERGENTE` si `APIM_TEAM`
  discorde, `TEAM_NON_ATTESTEE` si aucun palier autonome n'est déclaré ; en mode
  `internal`, `VAULT_SUB_HORS_TENANT` lie le chemin au tenant ;
- **les références de la porte** : `CHANGE_REF` / `PV_REF` au formulaire ⇒
  `per_env.<env>.change_ref` / `pv_ref` ; `GATE_REFS_REQUIRED` à la demande quand
  la porte l'exige ;
- **la chaîne entière** aux deux formulaires (mesuré : `build job:` valide la
  valeur d'un `choice` — le terminus doit être listé, les portes décident) ;
- **une PR ouverte n'appartient qu'à son auteur** : `PR_D_AUTRUI` sinon ;
  `REPLI_EN_COURS` quel que soit l'auteur ;
- **le contrat figé relu au dispatch** : `CONTRAT_DIVERGENT` si un merge change la
  racine du manifeste ; **les trois identités** sur la PR (demandée · mergée ·
  portée).

**Le pas-à-pas des cinq paliers** (qui demande, qui merge, qui répond à la pause) :

1. **dev** : alice demande (`FORGE_TOKEN`), alice merge, alice répond — palier
   sans porte ; l'équipe est décidée par le token (A3).
2. **rec** : alice / alice / alice (`selfApproval`, décision client n°1).
3. **int** : alice demande, **bob** merge (quatre yeux : alice ≠ bob), **bob**
   répond à la pause (`apim-apply-int` → `apply-int`) ; l'aval imprime « équipe :
   'banking-demo' — celle du manifeste mergé … ; tenants du porteur :
   payments-team » puis « déclaration déployeur : 'bob' porte 'apply-int' ».
4. **homol** : alice demande **avec `PV_REF`**, **carol** merge et répond
   (`apim-apply-homol`).
5. **prod** : alice demande avec `CHANGE_REF` + `PV_REF`, **oscar** merge et
   répond (`apim-operator-prod` → `operator-deploy`) ; l'ITSM est re-vérifié au
   dispatch ; la voie est **directe** sur la gateway du terminus, ticket
   `envs/prod/wm-admin` ; **l'API doit y être** (A5 au terminus : `API_NOT_PROMOTED`
   / `API_INACTIVE` lus sur la gateway du terminus, rien écrit) — la promouvoir par
   archive (`api-promote-request` → `team-promote` ; sur ce lab, l'export de la
   10.15 importé dans `wm-mock-prod` conserve GUID et `isActive`), puis **rejouer
   le webhook** de la PR mergée.

**Gestes du lab (l'ordre compte)** :

```bash
git push gitea HEAD:main                                   # le CI lit gitea
docker build -t stoa-labs/webmethods-mock:dev mocks/webmethods && (recréer poc-wm-mock-prod)   # mock fidèle (assets/team Application)
VAULT_TOKEN=… TERMINUS_ADMIN=http://wm-mock-prod:8080/rest/apigateway TERMINUS_CURL="docker exec -i poc-jenkins curl" \
  TERMINUS_WM_USER=… TERMINUS_WM_PASS=… TERMINUS_ISSUER=http://localhost:8480/realms/stoa-lab \
  TERMINUS_JWKS=http://keycloak:8080/realms/stoa-lab/protocol/openid-connect/certs \
  bash scripts/setup-terminus-apps.sh                      # ticket, Teams, accessProfile, alias (valeurs locales), login prouvé
# amorçage des trois formulaires (un paramètre posé par properties() n'existe qu'après un build — SECURITY-170)
set -a; . ./.env.lab-users; set +a
JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 \
GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage \
  bash scripts/test-a7-live.sh                             # pose APIM_TERMINUS_BASE, joue le parcours, la restaure
```

**Knobs** : `APIM_TERMINUS_BASE` (sans défaut — la déclaration) ; `FORGE_TOKEN` /
`CHANGE_REF` / `PV_REF` (formulaires) ; `GITEA_SERVICE_LOGINS` (défaut `ci`) ;
`APIM_TEAM` (ne peut que concorder sous déclaration) ; `KEEP_TERMINUS=1` (harnais).

**Limites écrites** : une application sans `team:` reste aux paliers autonomes ;
l'attestation de l'équipe est partielle (« déclaré » ≠ « appliqué par un tenant » —
l'approbateur, ou une organisation de forge, la tiendrait) ; mode `internal`
au-delà des paliers autonomes ⇒ `TENANT_NON_PORTE` ; un PAT Gitea n'expire pas
(token dédié, révoqué après ; la pause nominative est la barrière) ; les globales
choisissent les hôtes ; `pv_ref` n'est vérifié par personne ; le mock ne mint
aucune clé (« clé de la 10.15 jamais transportée », pas « une clé par gateway ») ;
mono-gateway hors terminus ; `APIM_TERMINUS_BASE` restaurée après le passage.

**Preuves** : hors ligne `make lint-ci` [16/16] (`test-app-request-a7.sh` 50/50,
`test-selfservice-palier-a3.sh` 191/191, `test-app-rollback-a6.sh` 92/92,
`test-provision-apply-a4.sh` 138/138, `test-pr-comment.sh` 47/47,
`test-a0-wiring.sh` 183/183, `test-palier-retention.sh` 137/0, `go test` du mock) ;
par builds réels `scripts/test-a7-live.sh` **99/99 au 5e passage** (2026-09-03 : cinq
paliers #176→#119, #177→#120, #178→#121 bob, #179→#122 carol, #182→#125 oscar après
`ITSM_NOT_APPROVED` #180, `PAYLOAD_PERIME` #181, `API_NOT_PROMOTED` #123 et
`API_INACTIVE` #124 au terminus ; formulaires #43-#46 ; repli #23 `ETAT_IDENTIQUE`) —
détail dans le GOAL, §A7. **Fait mesuré au passage** : la 10.15 masque l'`apiAccessKey`
(32 astérisques) à tout lecteur qui n'est pas le propriétaire de l'application,
Administrator compris — toute preuve de clé se lit en propriétaire (ADR-090).

## Tout en Jenkinsfile (A0 — GOAL cd-applications, 2026-09-02)

Depuis A0, **plus un seul `job.xml` de l'aval applicatif ne porte de logique** :
`provision-plan` et `provisioning-request` ont rejoint `provision-apply` en
Jenkinsfile déclaratif from SCM (`ci/Jenkinsfile.provision-plan`,
`ci/Jenkinsfile.provisioning-request`, parité stricte avec le Groovy d'origine :
le pipeline route trois ou sept clés de webhook vers le script, rien d'autre).
Le miroir `<triggers>` XML/Jenkinsfile est vérifié **champ à champ** par la lib
`scripts/lib/gwt-mirror.sh` (token, filtres, `printPostContent`, l'ensemble des
couples clé/valeur) sur les trois jobs, mutations comprises (`test-a0-wiring.sh`,
porte `make lint-ci` [11/11]).

**Le formulaire `app-request` est posé par son Jenkinsfile.** Ses onze
paramètres ne sont plus dans le XML : un pas scripté
`properties([parameters([…])])` les pose au premier stage, depuis des listes
calculées **dans le build** par `scripts/app-request-choices.sh` — paliers =
`env_chain_nonprod` (la source de `provision-request.sh`, terminus exclu par
structure), équipes = `providers.<env d'authoring>.yml` relu sur Gitea main,
APIs = les `publish.yml` (plateforme + dépôts d'équipe déclarés), fail-closed.
Cinq faits mesurés sur ce lab le 2026-09-02 fondent le mécanisme :
`properties()` pose des paramètres sur un job dont le XML n'en a aucun et les
builds suivants les conservent ; il **préserve** les propriétés venues du XML
(triggers, `disableConcurrentBuilds`) ; **re-poser le XML les efface** ⇒ un
build d'amorçage suit chaque pose (`setup-provision-jobs.sh`, knob
`BOOTSTRAP_JOBS`, passé par `setup-team-onboard-jobs.sh`) ; un build sur un job
sans définition lie **zéro** paramètre (`params.size()==0`, le signal
d'amorçage, capturé AVANT `properties()`) ; les valeurs posées ainsi subissent
toujours `EnvVars.resolve()` (le `withEnv([params…])` reste obligatoire).
Limite écrite d'avance : le formulaire montre les listes du build **précédent**
— acceptable parce que les listes sont de l'ergonomie, l'autorité est dans les
gardes du script (`ENV_INVALIDE`, `TEAM_NOT_DECLARED`, `REQ_API` requis).
`api-request` (chaîne des APIs, hors périmètre) garde ses marqueurs substitués à
la pose : deux mécanismes coexistent, délibérément.

**Rollout A0 sur un Jenkins existant :**

```bash
git push gitea HEAD:main                                          # le CI lit gitea
JOBS="provision-plan provisioning-request" bash scripts/setup-provision-jobs.sh   # coquilles (historique conservé)
JOBS=app-request bash scripts/setup-team-onboard-jobs.sh          # coquille + build d'AMORÇAGE (sans token Gitea)
curl -sg "$JENKINS/job/app-request/api/json?tree=property[parameterDefinitions[name]]"   # 11 paramètres après l'amorçage
```

Sur un job `app-request` posé sans amorçage, le bouton « Build » (sans
paramètre) **est** l'amorçage : le formulaire apparaît au build suivant.

### Les deux dettes d'A0, fermées le 2026-09-02

**Dette 1 — la forge est relue AVANT le verdict du plan, et la PR n'est jamais
muette.** Le payload d'un webhook est une affirmation : `provision-plan.sh`
clonait la branche `PR_BRANCH` et commentait la PR `PR_NUMBER` telles que
nommées — un payload forgé (branche réelle de la PR A, numéro de la PR B)
faisait poser un *verdict* du compte de service sur une PR étrangère
(constat bloquant de la critique adverse). Désormais
`scripts/lib/gitea-pr-confirm.sh` relit la PR sur la forge **avant le clone**
(`state=open`, `head.ref == PR_BRANCH` sous `provision/*`, `base.ref == main`),
sinon refus nommé **`FORGE_NON_CONFIRMEE`**, rc 1, aucun commentaire, aucun
clone ; le clone checkoute le **SHA de tête relu** (une branche
`provision/<app>-<env>` réutilisée après merge ne fait jamais commenter la PR
mergée) ; un clone ou un checkout raté est un refus (`CLONE_ECHEC`,
`BRANCHE_INTROUVABLE` — avant, vert par « IGNORE ») ; une PR depuis un fork ou
un `head.sha` non hexadécimal sont refusés par la lib. Le bloc de plan est un
**sous-shell** (une PR qui supprime un manifeste rend un ❌ commenté, plus un
rc 1 muet), le verdict cite la tête relue et lie `src/commit/<sha>`. Le script
écrit ses **faits** (`PLAN_FACTS` : numéro de PR, tête relue,
`PLAN_VERDICT=ok|fail|ignore|refus`, raison — initialisés à `SCRIPT_INTERROMPU`
dès le prologue, purgés par le Jenkinsfile avant l'appel : jamais les faits du
build précédent) ; le `post{always}` de stage les charge dans l'environnement, et le
`post{always}` de pipeline pose le **statut de build** sous le marqueur
distinct `<!-- provision-plan-build -->` (`scripts/provision-plan-status.sh`) :
`ABORTED` ⇒ « abandonné, aucun verdict » ; `FAILURE` ⇒ « verdict négatif » /
« refus avant le verdict : raison » / « échec avant le plan » ; `SUCCESS` +
`ignore` ⇒ « demande IGNORÉE (raison) : aucun verdict » ; `SUCCESS` + `ok` ⇒
**rien de neuf** (le verdict ✅ suffit ; un statut rouge périmé est seulement
effacé — `COMMENT_ONLY_IF_EXISTS`). Sans faits (le stage n'a pas tourné), le
statut relit la forge par la même lib ; non confirmée ⇒ silence. Les gardes bon
marché (`provision/*`, `PR_NUMBER` numérique) sont en Groovy **avant** tout
`node` — le hook Gitea tire sur toutes les PR du dépôt, `agent none` existe
pour qu'une PR étrangère n'alloue aucun exécuteur (même correctif sur
`provision-apply`). `provisioning-request` n'a **pas** de statut : la PR naît en
toute fin du script, le plan enchaîné n'est pas fatal ; une demande machine
refusée est un build rouge dont la seule trace est le log (le 200 aveugle rendu
au caller OIG est la dette d'APIsation, distincte).

**Dette 2 — `selfservice-app-deploy` pose son formulaire depuis son
Jenkinsfile.** Le bloc `parameters{}` déclaratif et sa liste `ENVIRONMENT` en
dur ont disparu : un premier stage « Formulaire » dérive les paliers de
`env_chain_nonprod` (clone du build) et pose les huit paramètres par
`properties([parameters([…])])` ; les trois stages lisent les valeurs brutes
par `withEnv([params…])`. Deux faits mesurés (jobs jetables) gouvernent le
rollout :

- **Fait 6** — si le XML du job porte déjà une `ParametersDefinitionProperty`,
  `properties()` en **ajoute une seconde** et le job casse
  (`buildWithParameters` ⇒ 500). **La conversion passe par une re-pose, jamais
  par un simple push** : un push seul sur un XML paramétré produit le doublon.
- **Fait 10** — sur un job **re-posé** (déjà amorcé une fois), le premier build
  **perd** les `options{}`/`triggers{}` déclaratifs dès qu'un `properties()`
  scripté s'y ajoute (webhook 404 jusqu'au build suivant — mesuré sur
  `selfservice-app-deploy` #34 et #36) ; sur un job neuf ils survivent. Tout
  dans `properties()` avec un XML qui porte déjà le trigger ⇒ doublon sur un
  job neuf. D'où le design : **le Jenkinsfile pose les trois propriétés**
  (`disableConcurrentBuilds()`, `pipelineTriggers([GenericTrigger…])`,
  `parameters([…])`) et **le XML posé n'en porte aucune**. Le webhook PLAN
  n'existe qu'après l'amorçage, que le poseur enchaîne et attend.
  `setup-selfservice-job.sh` : `XML_PARAMS=auto` (`no` pour
  `Jenkinsfile.selfservice` ⇒ `<properties/>` ; `yes` pour `publish-api-deploy`
  qui garde son bloc déclaratif — trigger, option et paramètres dans le XML,
  liste dérivée à la pose), amorçage `POST /build`, `BOOTSTRAP_WAIT` (360 s :
  le préflight gateway peut durer 300 s), relecture « une propriété, un
  trigger, une option, `ENVIRONMENT == env_chain_nonprod` ».
- **Fait 7** — `EnvVars.resolve()` frappe aussi un paramètre `password` : un
  mot de passe annuaire portant `$$` ou `${` arrivait **altéré** à Vault
  (lockout au second essai). Les sept paramètres non secrets passent par
  `withEnv([params…])` ; une valeur vide retire la variable (PLAN-only inchangé).
- **Fait 9** (revue adverse du commit livré) — un secret interpolé dans un
  argument de step (`withEnv`) est **persisté en clair** dans
  `flowNodeStore.xml` dès qu'il diffère de la valeur résolue — précisément les
  mots de passe que le fait 7 vise — et Jenkins l'écrit dans la console (« A
  secret was passed to withEnv using Groovy String interpolation, which is
  insecure »). Le mot de passe reste donc sur le canal natif, et l'Apply ouvre
  par une **garde fermée** : `"${params.VAULT_USER_PASSWORD}"` (brut, `params`
  rend un `hudson.util.Secret`) ≠ `env.VAULT_USER_PASSWORD` (résolu) ⇒
  `REFUS: MOT_DE_PASSE_ALTERE` **avant tout appel à Vault** (aucun lockout),
  issue : voie B (JWT) ou un mot de passe sans `$`. Aucun step ne reçoit le
  secret.

Hors périmètre, nommé : `ci/Jenkinsfile.publish-api:24` garde sa liste
littérale avec le terminus (formulaire producteur, chaîne des APIs) — sur ce
job le XML n'a pas autorité (fusion par nom), la décision est à prendre là-bas.
Résiduel : `setup-selfservice-job.sh` n'a ni auth Jenkins ni portail (parité
avec `setup-provision-jobs.sh` le jour du rollout client).

```bash
git push gitea HEAD:main
bash scripts/setup-selfservice-job.sh          # RE-POSE (XML sans paramètre) + amorçage + relecture
bash scripts/setup-selfservice-job.sh --print  # le XML rendu, zéro réseau (épreuves)
```

**Rollout sur un Jenkins existant — l'ordre est une contrainte :**

```bash
git push gitea HEAD:main                                   # le CI lit gitea
bash scripts/setup-selfservice-job.sh                      # l'AVAL d'abord : déclare MERGE_SHA + build d'amorçage
# vérifier : selfservice-app-deploy déclare MERGE_SHA (sinon un `build job:` le
# retirerait EN SILENCE — SECURITY-170 — ; l'aval refuserait MERGE_SHA_REQUIS)
curl -s "$JENKINS/job/selfservice-app-deploy/api/json?tree=property[parameterDefinitions[name]]"
JOBS=provision-apply bash scripts/setup-provision-jobs.sh  # puis l'AMONT : la coquille from SCM (historique conservé)
```

**Knob de lab `APPLY_ADMIN_VIA`** : le défaut du Jenkinsfile est
`proxy-oauth2` (le modèle client, celui que le Groovy codait en dur). Sur le
lab local, `wm-admin-self` est inactif et `deploy/banking-demo/admin-oauth`
n'est pas seedé : la voie qui aboutit est `direct`. Variable d'environnement
**globale** Jenkins, posée par la console de script (même geste
qu'`APIM_DIRECT_BASE_TPL`) :

```groovy
import jenkins.model.Jenkins; import hudson.slaves.EnvironmentVariablesNodeProperty
def j = Jenkins.instance; def p = j.globalNodeProperties.get(EnvironmentVariablesNodeProperty)
if (p == null) { p = new EnvironmentVariablesNodeProperty(); j.globalNodeProperties.add(p) }
p.envVars.put('APPLY_ADMIN_VIA', 'direct'); j.save()
```

**Identités** : la garde exige mergeur == répondant de la pause, et l'aval lit
les creds du tenant dans Vault avec l'identité de la pause. Sur ce lab, c'est
**alice** (Vault `deploy-banking-demo`, ldap et userpass) — créée dans Gitea et
collaboratrice `write` de `ci/stoa-labs` par la suite live si absente. `oscar`
merge mais porte `operator-deploy` (403 sur le tenant) : un 403 KV avec un token
vivant = mauvais user pour le job, pas un bug.

**Rejouer la porte et la contre-épreuve par builds réels** (Gitea + Jenkins +
Vault + 10.15 réelle ; écrit deux PR jetables, merge la première sur `main` et
retire son manifeste à la fin) :

```bash
set -a; . ./.env.lab-users; set +a
JENKINS_UI=http://localhost:18080 GITEA_URL=http://localhost:13000 \
GW_ADMIN=http://localhost:5555/rest/apigateway WM_USER=Administrator WM_PASS=manage \
  bash scripts/test-provision-apply-a2-live.sh
```

La suite live joue aussi la **seconde contre-épreuve** : le rejeu du webhook
réel de la porte après que `main` a dépassé le palier ⇒ `PALIER_SUPPLANTE`,
gateway inchangée, le ✅ de l'apply réel intact sur la PR.

Hors ligne (`make lint-ci` `[10/10]`) : `scripts/test-provision-apply-a2.sh`
(digest, réconciliation contre un stub Gitea ET un dépôt git local, rapport de
PR, mutations) et `scripts/test-provision-apply-wiring.sh` (câblage
amont/coquille/aval, sur une vue code sans commentaires).

**Limites écrites d'avance** : en `rec`, l'apply atteint la même 10.15 que
`dev` (la 10.15 unique du lab ; depuis A3 le palier est un CREDENTIAL,
`envs/rec/wm-admin`, plus un en-tête — voir la section A3 ci-dessous) ; le quatre-yeux
du maillon 2 compare le mergeur au compte de service `ci` (auteur de toute PR
de provisioning) — le demandeur humain n'est que dans le corps de la PR, le
contrôle réel est le merge par un tiers (protection de branche, G4) ; la garde
de périmètre vit dans le dépôt que la PR modifie et n'est fermée que par la
protection de `ci/stoa-labs@main` (`setup-repo-protections.sh`) ; un
`MERGE_SHA` saisi à la main sur l'aval est accepté s'il est sur la lignée de
`main` — ce n'est PAS le repli (A6 : le repli est une PR, section « Revenir en
arrière — applications (A6) » ci-dessous), c'est un rejeu hors chaîne borné par
l'identité nominative et Vault comme aujourd'hui.

## Résiduel

- **Le lien entre le Jenkins local et celui du labs n'est pas établi.** Ce sont
  peut-être deux instances distinctes, peut-être la même exposée deux fois : rien
  ne permet de trancher tant que le portail masque l'instance publique.
- `mcp.gostoa.dev` (404) et `status.gostoa.dev` (injoignable) sont cités comme
  actifs — l'un dans CLAUDE.md, l'autre dans le dépôt.
- Les hôtes `dev-wm` / `rec-wm` / `vps-wm.gostoa.dev` cités dans le dépôt ne
  répondent pas (404 ou injoignables) : vestiges de topologies antérieures.
