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

## Résiduel

- **Le lien entre le Jenkins local et celui du labs n'est pas établi.** Ce sont
  peut-être deux instances distinctes, peut-être la même exposée deux fois : rien
  ne permet de trancher tant que le portail masque l'instance publique.
- `mcp.gostoa.dev` (404) et `status.gostoa.dev` (injoignable) sont cités comme
  actifs — l'un dans CLAUDE.md, l'autre dans le dépôt.
- Les hôtes `dev-wm` / `rec-wm` / `vps-wm.gostoa.dev` cités dans le dépôt ne
  répondent pas (404 ou injoignables) : vestiges de topologies antérieures.
