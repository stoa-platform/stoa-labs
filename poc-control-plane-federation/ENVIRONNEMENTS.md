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
  refléter les listes (choices, triggers, paramètres) : pour un bloc
  **déclaratif**, le XML gagne sur le Jenkinsfile — un scellement présent dans le
  Jenkinsfile mais absent du config.xml posé ne prend pas effet. ⚠ Ce n'est PLUS
  vrai de `provision-plan`, `provision-apply`, `selfservice-app-deploy`,
  `team-apply`, `team-publish` ni `team-promote` : depuis L6 leur XML ne porte
  AUCUNE propriété et c'est leur
  **premier build** qui pose déclencheur et verrou (voir « Le récepteur de
  webhooks »). `setup-provision-jobs.sh` le DÉDUIT du XML (`<properties/>` vide
  ⇒ amorçage imposé **et** attendu) : il n'y a pas de liste à tenir à jour.

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
qu'une coquille — pointeur SCM et, depuis L6, **aucune propriété** : le
déclencheur est posé par le Jenkinsfile au premier build (voir « Le récepteur de
webhooks »).

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

**Knobs du préflight de joignabilité** (globales de site, déclarées dans
`scripts/setup-jenkins-globals.sh` — `--help` les décrit) — une seule
implémentation, `ci/lib/preflight.sh`, appelée par `selfservice` **et** par
`publish-api`, avec **le palier en 2ᵉ argument** :

| knob | ce qu'il fait |
|---|---|
| `APIM_PREFLIGHT=off` | ne sonde pas du tout (**insensible à la casse** : `Off`, `OFF` aussi). Le build l'écrit : `préflight de joignabilité : DÉSACTIVÉ` — **le même marqueur** que le chemin actif, jamais un silence (les preuves live s'ancrent dessus). |
| `APIM_PREFLIGHT_URL` | vise **une autre sonde de vie** que `<base>/health`. ⚠ **C'est un GABARIT par palier, pas une URL plate** : `__ENV__` y est substitué par le palier du build, comme dans `APIM_PROXY_API` (`wm-admin-__ENV__`) et dans `envs/__ENV__/wm-admin`. Ex. `https://apim-__ENV__.corp/ping`. Une URL **plate** reste acceptée (une seule gateway pour tous les paliers) mais la trace le **dit** : « sonde de SITE, la même pour TOUS les paliers ». Un gabarit **sans palier nommé** est **refusé**, jamais sondé littéralement. ⚠ **La substitution vaut pour CE knob, et pour lui seul** : la base d'admin par défaut est reçue **telle quelle** de l'appelant (cf. l'encadré ci-dessous). |
| `APIM_PREFLIGHT_CODES` | codes qui valent preuve de vie (défaut « 200 401 ») — un **401 sans jeton EST** la preuve de vie d'un proxy dont l'OAuth2 est déjà enforce. |
| `APIM_PREFLIGHT_TRIES` | nombre d'essais (défaut 60, **borné à 3600**). ⚠ **Un essai coûte jusqu'à 10 s, pas 5** : le timeout du `curl -m 5`, consommé **entier** quand l'hôte ne répond pas (le cas visé), **puis** l'attente de 5 s. Le défaut vaut donc **jusqu'à ~10 minutes**, pas 5 — l'ancien chiffre sous-estimait d'un facteur 2. |

Leur absence est un état normal : le défaut est conservé.
⚠ **Pourquoi le gabarit n'est pas un détail.** Une globale de contrôleur porte
UNE valeur pour TOUS les builds, alors que la base réellement sondée est **par
palier**. Une `APIM_PREFLIGHT_URL` plate posée en globale — ce que cette page
prescrivait — faisait sonder **le même palier depuis les quatre autres** : cinq
environnements lus vivants parce qu'un seul l'était, et l'argument que
l'appelant prend la peine de résoudre ignoré en silence.
⚠ **La substitution n'appartient QU'à `APIM_PREFLIGHT_URL`.** Le premier jet
l'appliquait aussi à la branche par défaut `<base de l'appelant>/health` : la
lib **réparait** alors en silence une base que personne n'avait résolue —
`APIM_API_BASE` / `APIM_PROXY_BASE` de `publish-api` sont des globales de
**SITE**, que rien ne résout par palier. Une base portant `__ENV__` est donc
désormais **refusée**, jamais réparée, et le refus **nomme laquelle des deux
origines** est en cause : accuser `APIM_PREFLIGHT_URL` quand l'exploitant ne
l'a jamais posée l'envoie chercher un knob qui n'existe pas. Résoudre le palier
reste le travail de **l'appelant** — c'est ce que fait
`scripts/selfservice-palier-gate.sh` avant d'émettre `APIM_API_BASE`.
⚠ Chez un client dont l'API d'admin est **proxifiée SUR la gateway** et dont
`/health` est filtré en amont (hors VIP), sans ces knobs le build attend
**~10 minutes** puis échoue **pour une raison étrangère au travail demandé** —
mode de panne rencontré le 2026-09-07. `publish-api` sondait alors `/health`
**en dur** et n'en portait aucun : le merge `5d34299` lui avait rendu une
version antérieure du bloc, pendant que `selfservice` gardait la bonne. La
porte qui l'aurait vu — les assertions de câblage de
`ci/test-proxy-base-et-preflight.sh` — existait mais **rien ne l'appelait** ;
elle est branchée depuis le 2026-09-07 sous `make lint-ci` (dernière étape,
`STOA_PREFLIGHT_ONLY=1`).

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

**Preuves** : hors ligne `scripts/test-app-rollback-a6.sh` 82/82 (`make lint-ci` [15/15]) ; par builds réels `scripts/test-a6-live.sh` **49/49** au 4e passage (repli #16 → PR #511 → provision-apply #156 → aval #102 SUCCESS, gateway lue à l'état N-1 : même GUID, même clé, IP et cert de N-1 ; chiffres complets dans le GOAL). Pose du job : `GIT_HOST=http://localhost:13000 GIT_REPO=ci/stoa-labs JOBS=app-rollback BOOTSTRAP_JOBS=app-rollback scripts/setup-provision-jobs.sh` (depuis L3 le poseur exige `GIT_BASE`, ou `GIT_HOST` **et** `GIT_REPO` — cf. « La branche par défaut »).

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
# Depuis L3 les XML portent __GIT_BASE__ : poser GIT_BASE, ou GIT_HOST ET
# GIT_REPO pour que la HEAD du dépôt plateforme soit découverte (sinon
# REFUS: BRANCHE_PAR_DEFAUT_INDECIDABLE, aucun job posé).
export GIT_HOST=http://localhost:13000 GIT_REPO=ci/stoa-labs
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

**Deux URL, et elles ne se valent pas** (L3, corrigé le 2026-09-10) : le
`<url>` écrit dans le XML est `GIT_URL`, le dépôt vu **depuis l'agent** Jenkins
(`http://gitea:3000/...`) ; la **découverte** de la branche, elle, part **de ce
poste**, où « gitea » ne résout pas. D'où les mêmes knobs que chez les poseurs
frères : `GIT_HOST` + `GIT_REPO` composent le dépôt joignable d'ici. Sans eux,
la découverte retombe sur `GIT_URL` (le cas du lab, agent et poseur sur le même
réseau) ; l'un des deux seulement ⇒ `REFUS:
BRANCHE_PAR_DEFAUT_INDECIDABLE`, aucun job posé.

```bash
git push gitea HEAD:main
bash scripts/setup-selfservice-job.sh          # RE-POSE (XML sans paramètre) + amorçage + relecture
bash scripts/setup-selfservice-job.sh --print  # le XML rendu, zéro réseau SI GIT_BASE ou BRANCH est posée
# Sans knob, `--print` DÉCOUVRE la branche (un ls-remote) avant de rendre le
# XML : ce n'est plus un geste hors ligne.
# DEPUIS UN POSTE D'EXPLOITANT — le dépôt vu D'ICI, le <url> reste celui de l'agent :
GIT_HOST=http://localhost:13000 GIT_REPO=ci/stoa-labs \
  bash scripts/setup-selfservice-job.sh --print
GIT_BASE=master bash scripts/setup-selfservice-job.sh --print   # rendu strictement hors ligne
```

**Rollout sur un Jenkins existant — l'ordre est une contrainte :**

```bash
git push gitea HEAD:main                                   # le CI lit gitea
GIT_HOST=http://localhost:13000 GIT_REPO=ci/stoa-labs \
  bash scripts/setup-selfservice-job.sh                    # l'AVAL d'abord : déclare MERGE_SHA + build d'amorçage
                                                           # (GIT_HOST/GIT_REPO = le dépôt vu D'ICI, pour la seule découverte de la branche)
# vérifier : selfservice-app-deploy déclare MERGE_SHA (sinon un `build job:` le
# retirerait EN SILENCE — SECURITY-170 — ; l'aval refuserait MERGE_SHA_REQUIS)
curl -s "$JENKINS/job/selfservice-app-deploy/api/json?tree=property[parameterDefinitions[name]]"
GIT_HOST=http://localhost:13000 GIT_REPO=ci/stoa-labs \
  JOBS=provision-apply bash scripts/setup-provision-jobs.sh # puis l'AMONT : la coquille from SCM (historique conservé)
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

## Le visage de la forge (L5 — 2026-09-09)

Le 2026-09-09, chez un client sur **GitLab**, `ci-app-request` mourait
`REFUS: FORGE_ILLISIBLE` sur un corps vide : la chaîne parlait l'API de Gitea
(`/api/v1/…`, `Authorization: token`) et GitLab répond à `/api/v1` par un
**302 vers /users/sign_in** — une page HTML que `json.load` ne sait pas lire.
Depuis, **une seule autorité** parle à la forge : `scripts/lib/forge-api.sh`
(enveloppe) + `scripts/lib/forge-api.py` (visage, base d'API, en-tête d'auth,
garde de réponse, formes normalisées). La porte `ci/lint-forge-literals.sh`
(`make lint-ci`) interdit `/api/v1`, `/api/v4`, `Authorization: token`,
`PRIVATE-TOKEN`, `json.load(` et `urlopen(` hors de cette autorité.

**Knobs** (globals Jenkins, `setup-jenkins-globals.sh --help`) :

| Knob | Valeurs | Défaut | Rôle |
|------|---------|--------|------|
| `GITEA_CREDENTIALS_ID` | identifiant de credential Jenkins | `gitea-provision-token` | le credential qui porte le secret de la forge — le secret lui-même reste dans le gestionnaire de credentials, jamais en globale |
| `FORGE_CRED_KIND` | `secret-text` \| `username-password` | `secret-text` | le TYPE de ce credential, tel que Jenkins le lie : jeton (« Secret text ») ou couple (« Username with password », variante Vault comprise). **Fail-closed** depuis le 2026-09-10 : toute autre valeur ⇒ `REFUS: FORGE_CRED_KIND_INVALIDE` avant tout binding, et la console dit « credential de la forge : '<id>' lie en <type> ». Sans lui, un couple mourait par « is of type Vault Username-Password Credential where StringCredentials was expected », message qui accuse le credential et pas le knob |
| `FORGE_KIND` | `gitea` \| `gitlab` | **aucun repli** (2026-09-12) | le VISAGE : chemins (`/api/v1/repos/o/r` vs `/api/v4/projects/o%2Fr`), formes (`number`/`iid`, `login`/`username`, `open`/`opened`, `head.ref`/`source_branch`, `comments`/`notes`) |
| `FORGE_API_AUTH` | `token` \| `private-token` \| `bearer` \| `basic` | dérivé du visage (`token` Gitea, `private-token` GitLab) | l'en-tête d'auth ; `basic` exige `FORGE_USER` |
| `FORGE_API_BASE` | URL | vide | la base d'API **si** un reverse-proxy la déplace ; sinon dérivée de `GIT_HOST` |
| `GIT_HOST` / `GIT_REPO` | URL / `groupe/projet` | **aucun repli** | `REFUS: GIT_HOST_REQUIS` / `GIT_REPO_REQUIS` plutôt qu'un `http://gitea:3000` de lab chez le client |
| `FORGE_PREPARE_WAIT` | secondes | `30` | GitLab seulement : attente bornée de `prepared_at` avant de lire les fichiers d'une MR (voir ci-dessous) |

**`FORGE_KIND` n'a plus de défaut, et c'est une décision du 2026-09-12.** Elle
valait `gitea`, et ce défaut vivait à DEUX endroits : dans `forge_api_init`
(`${FORGE_KIND:-gitea}`) et dans le `?: 'gitea'` des Jenkinsfile. Conséquence
mesurée : un client GitLab qui ne posait pas la globale voyait la chaîne parler
l'API de Gitea à son GitLab — 302 vers `/users/sign_in`, corps HTML,
`FORGE_ILLISIBLE` — et **aucune porte ne pouvait le dire**, parce qu'une porte
ne lit que les Jenkinsfile du dépôt, jamais la copie éditée chez le client (la
forme exacte de l'incident du 2026-09-10). Or la règle écrite de
`ci/lint-config-knobs.sh` est : *un défaut est acceptable si et seulement si
cette porte peut le vérifier sans sortir du dépôt*. Ce défaut-là la violait.

Donc : **globale REQUISE**, les **douze** Jenkinsfile porteurs déclarent
`FORGE_KIND = "${env.FORGE_KIND ?: ''}"`, et l'autorité refuse
`FORGE_KIND_REQUIS` sur une valeur vide. Retirer le repli des Jenkinsfile
n'était pas cosmétique : sans ça le refus était **inatteignable**, puisque le
pipeline fournissait toujours une valeur.

Le refus est **identique que `FORGE_KIND` soit absente ou vide** —
`forge_api_init` teste `[ -n "${FORGE_KIND:-}" ]`, qui ne distingue pas les deux
— et c'est le **premier** test de l'init, avant `FORGE_KIND_INCONNU`,
`GIT_HOST_REQUIS`, `GIT_REPO_REQUIS`, et donc avant tout appel réseau : l'ordre
des refus est stable (visage, puis hôte, puis dépôt).

⚠ **L'ORDRE DE POSE COMPTE, une fois de plus** : poser la globale
(`setup-jenkins-globals.sh`) AVANT de rejouer les jobs. Une globale absente ne
fait plus « parler Gitea », elle fait **refuser** — c'est le but, et ça vaut
aussi pour le lab.

La porte qui tient la propriété est `ci/lint-forge-knobs.sh`, à **portée
dérivée** : elle LIT la liste `ROUTES` de `ci/lint-forge-literals.sh` (les
scripts routés sur l'autorité de forge), trouve les Jenkinsfile qui les
invoquent, et exige les trois knobs dans leur `environment{}` — plus l'absence
de défaut de site sur `FORGE_KIND`. Elle a trouvé, le jour de sa pose, un
douzième Jenkinsfile que deux relevés faits à la main avaient manqué :
`provisioning-request`, la voie MACHINE (OIG/CLI2).

Un GitLab avec `FORGE_KIND=gitea` refuse en **nommant la cause** :
« la forge REDIRIGE (302) vers …/users/sign_in — GIT_HOST doit être l'URL finale
… ou cette forge ne parle pas ce visage ». Le secret ne passe **jamais** en argv
ni en préfixe de commande (tracé sous `set -x`) : here-doc sur le descripteur 3,
et toute cause est expurgée des secrets connus.

**Prérequis côté client GitLab** (à obtenir AVANT de rejouer la chaîne) :

- `/api/v4` joignable **depuis l'agent Jenkins** (pas seulement depuis le poste) ;
- un **PAT de service** avec les scopes `api`, `read_user`, `write_repository`
  (le couple user/mot de passe suffit à `git`, pas à `/api/v4`) ;
- méthode de merge du projet = **merge commit** : en fast-forward ou squash,
  `merge_commit_sha` est nul et la réconciliation (A2) comme le repli (A6)
  refusent (`PAYLOAD_PERIME`, `FORGE_ILLISIBLE : merge_commit_sha illisible`) —
  la chaîne exige un commit de merge (`MERGE_SHA^2`, trailers `Repli-De`) ;
- les webhooks vers Jenkins autorisés (« Allow requests to the local network »
  si Jenkins est une adresse privée) ; les deux payloads (Gitea `pull_request`,
  GitLab `merge_request`) sont lus par les mêmes jobs, sans knob ;
- la branche par défaut (**`master`** chez ce client, pas `main`) : voir
  « La branche par défaut » ci-dessous — plus rien ne la devine ;
- CE suffit pour la chaîne app-request ; la protection de branche par
  utilisateurs/patterns est Premium (ADR-081, dette nommée) ;
- **GitLab calcule le diff d'une MR en asynchrone** (mesuré 17.11 : `prepared_at`
  nul et `detailed_merge_status=preparing` pendant 3-4 s après la création,
  `/diffs` rend `[]` entre-temps — et le webhook « open » arrive AVANT).
  `pr_files` attend `prepared_at` (borné par `FORGE_PREPARE_WAIT`, refus nommé
  « encore en PRÉPARATION » au-delà) : sans cela, provision-plan lirait « aucun
  fichier » et la porte de périmètre refuserait à tort ;
- `git config http.postBuffer 524288000` sur l'agent qui POUSSE : un push
  > 1 Mio part en `Transfer-Encoding: chunked` et le GitLab du lab le refuse
  en **500** (gitaly « waiting for receive-pack: exit status 128 », 53 ms —
  mesuré le 2026-09-09 sur un push de 11 Mio ; le même buffé passe). Même
  leçon qu'avec Gitea (mémoire « push gitea > 1 Mo exige http.postBuffer »).

### Les verbes de forge

`scripts/lib/forge-api.py` expose **onze** verbes, et rien d'autre. Le shell ne
voit **jamais** un chemin, un en-tête ni un nom de champ de forge : il reçoit des
lignes `CLÉ=VALEUR` normalisées, identiques sur les deux visages. `rc 0` = produit
sur stdout ; `rc 2` = la CAUSE en **une** ligne sur stderr et **rien** sur stdout
— c'est l'APPELANT qui nomme le tag (`FORGE_ILLISIBLE`, `FORGE_NON_CONFIRMEE`…),
de sorte que les contrats de refus existants ne bougent pas.

| Verbe | Arguments | Sortie | Gitea | GitLab |
|---|---|---|---|---|
| `probe` | — | `KIND_DETECTED=gitea\|gitlab\|inconnu` `PROBE=` | `/version` en `/api/v1` | `/version` en `/api/v4` (401 accepté) — **sans secret** |
| `whoami` | — | `LOGIN=` | `user` → `login` | `user` → `username` |
| `pr_find_open` | `<tête>` | `NUMBER= LOGIN= URL=` — **vides** si aucune, `rc 0` | `pulls?state=open`, filtre rejoué côté client | `merge_requests?state=opened&source_branch=` |
| `pr_list_merged` | `<tête>` | **une ligne par PR** : `NUMBER= MERGE_SHA= BASE_REF= SAME_REPO= HEAD_REPO=` | `pulls?state=closed`, mergées seules | `merge_requests?state=merged&source_branch=` ; `HEAD_REPO=project:<id>` |
| `pr_get` | `<n>` | `NUMBER= STATE= STATE_RAW= HEAD_REF= HEAD_SHA= BASE_REF= SAME_REPO= MERGED= MERGE_SHA= MERGED_BY= LOGIN= URL=` | `pulls/<n>` | `merge_requests/<iid>` |
| `pr_open` | `<tête> <base> <titre> <fichier-corps>` | `NUMBER= URL=` | `POST pulls` (`head`/`base`/`body`) | `POST merge_requests` (`source_branch`/`target_branch`/`description`) |
| `pr_files` | `<n>` | **un chemin par ligne** | `pulls/<n>/files` → `filename` | `merge_requests/<iid>/diffs` → `new_path`, après l'attente de `prepared_at` |
| `comment_find` | `<n> <marqueur>` | `ID=` — **vide** si aucun commentaire ne porte le marqueur, `rc 0` | `issues/<n>/comments` | `merge_requests/<iid>/notes` |
| `comment_upsert` | `<n> <marqueur> <fichier>` | `ID= ACTION=created\|updated` | idem, `PATCH` | idem, `PUT` |
| `raw` | `<chemin> [ref]` | le contenu **brut** sur stdout | `raw/<chemin>` | `repository/files/<chemin encodé>/raw` (sans `ref` : la HEAD du projet, GitLab ≥ 13.12) |
| `repo_get` | — | `EXISTS= EMPTY= DEFAULT_BRANCH= URL=` — **un 404 est une réponse** (`EXISTS=0`, `rc 0`) | champ `empty`, `html_url` | champ `empty_repo`, `web_url` |

Trois helpers d'enveloppe, dans `scripts/lib/forge-api.sh` :

- **`forge_kv <préfixe> <verbe> [args…]`** — joue le verbe et pose
  `<préfixe>_<CLÉ>` pour chaque ligne rendue, **sans `eval`** : la valeur est
  prise après le premier `=`, telle quelle. C'est la voie à prendre dès qu'une
  valeur peut porter n'importe quoi (un titre de PR, une URL) ;
- **`forge_web_url <url>`** — l'URL rendue par un verbe, vue **du poste** :
  `GIT_WEB_HOST` remplace le préfixe `GIT_HOST` quand les deux diffèrent
  (`http://gitea:3000` vu du conteneur, `localhost:13000` vu du poste). Une URL
  qui ne commence pas par `GIT_HOST` est rendue telle quelle ;
- **`forge_web_file_url <sha> <chemin>`** — le lien **humain** d'un fichier à un
  commit, à la forme du visage (`src/commit` / `-/blob`). Plus aucun script ne
  compose `/pulls/N` ni `/src/commit/` à la main : la porte
  `ci/lint-forge-literals.sh` les interdit hors de l'autorité.

Le contrat de `pr_get` est **figé** : ses clés sont consommées par
`scripts/forge-merge-identity.sh` (`forge_kv PRG pr_get`, puis `PRG_MERGED_BY`
et `PRG_LOGIN`), que **deux** Jenkinsfile invoquent — `ci/Jenkinsfile.team-apply`
et `ci/Jenkinsfile.team-publish`, qui **délèguent** et ne lisent jamais les clés
eux-mêmes. Toute évolution passe par une annonce croisée. Dans les scripts,
`PR_*` est l'espace du **payload** du webhook ; la relecture de la forge vit
sous `FPR_*` (`team-publish`, `team-promote`), pour que les deux ne se
confondent jamais.

⚠ **Un bloc `sh` de Jenkins est du `dash`** : ne **jamais** faire
`. scripts/lib/forge-api.sh` dans un bloc `sh` (la lib est du bash :
`${BASH_SOURCE[0]}`, `printf -v`, here-string). Toujours `bash scripts/<x>.sh`,
un process à soi, son shebang. La porte est dans `ci/lint-jenkinsfiles.sh`.

### La branche par défaut (`GIT_BASE`) — L3, 2026-09-10

La chaîne écrivait `main` en dur à 46 endroits exécutés et dans 155 messages.
Chez ce client la branche est `master` : deux jours perdus à lire des refus qui
nommaient une branche inexistante. Une **seule autorité** en décide désormais,
`scripts/lib/git-base.sh`, et son contrat tient en trois lignes :

1. **`GIT_BASE` posée** (et ≠ `auto`) : elle **gagne**. Aucune HEAD n'est
   consultée — zéro appel réseau — et si le dépôt en annonce une autre, c'est le
   knob qui l'emporte. Le knob doit avoir la forme d'un nom de branche, sinon
   c'est un refus (pas un `clone -b -x` en aval).
2. **`GIT_BASE` absente, vide ou `auto`** : la branche est **découverte** —
   `git ls-remote --symref <url> HEAD`, motif prouvé sur Gitea, GitLab, GitHub
   et un dépôt nu local. `auto` existe parce que Jenkins n'exporte pas au shell
   une variable de valeur **vide** : « découvrir » doit pouvoir se dire avec un
   mot.
3. **Rien de découvrable** — dépôt injoignable, dépôt **vide** (aucun commit),
   HEAD sans forme de nom de branche : **`REFUS: BRANCHE_PAR_DEFAUT_INCONNUE`**,
   rc 2. `main` n'est **jamais** deviné en silence.

`GIT_BASE` est donc **OPTIONNELLE** dans `setup-jenkins-globals.sh` : ne la poser
que pour **sortir** de la HEAD du dépôt. Elle vaut pour le dépôt **plateforme** ;
la gouvernance et les dépôts d'équipe se voient demander **leur** branche, dépôt
par dépôt (`git_base_of`) — trois familles, trois HEAD, et la base d'une PR est
celle du dépôt **cible**.

**Les XML des jobs ne nomment plus aucune branche.** Les treize
`ci/jenkins/*.job.xml` portent `<name>*/__GIT_BASE__</name>` ; le **poseur**
(`setup-provision-jobs.sh` et ses appelants, `setup-carto-job.sh`) substitue à la
pose, et **refuse** (`XML_PLACEHOLDER_RESTANT`) si le placeholder survit — sinon
Jenkins chercherait une branche de ce nom. Même règle pour
`setup-selfservice-job.sh` (knob local `BRANCH`) et `setup-repo-protections.sh`
(knob local `PROTECT_BRANCH`) : le knob local gagne, sans lui l'autorité décide,
et il n'existe **aucun défaut de site**.

**Le dépôt interrogé n'est pas celui qu'on écrit** (corrigé le 2026-09-10). Tous
ces poseurs écrivent dans le job une URL vue **depuis l'agent** Jenkins et
interrogent, pour la seule découverte, une URL vue **depuis le poste** :
`GIT_HOST` + `GIT_REPO`. C'est vrai de `setup-provision-jobs.sh`, de
`setup-carto-job.sh` — et désormais aussi de `setup-selfservice-job.sh`, dont le
`GIT_URL` par défaut (`http://gitea:3000/...`) ne résout pas hors du réseau
docker : sans ces knobs, un exploitant n'avait d'autre issue que de nommer la
branche à la main, ce que L3 existe pour retirer. Les trois nomment leurs knobs
dans un refus (`BRANCHE_PAR_DEFAUT_INDECIDABLE`) plutôt que d'interroger en
silence un dépôt qu'ils ne peuvent pas joindre.

**Prérequis GitLab** : la HEAD d'un projet GitLab est sa **Default branch**
(Settings → Repository) — c'est elle qu'annonce `ls-remote --symref`. Un projet
dont la default branch n'est pas celle qu'on veut voir déployer doit être
corrigé **là**, ou nommer `GIT_BASE`.

**La porte** : `ci/lint-branch-literals.sh` (sous l'étape 2 de `make lint-ci`)
refuse tout nom de branche écrit en dur dans les fichiers livrés — le littéral
exécuté (`-b main`, `origin/main`, `*/main`…) **et** le mot `main` nu dans un
message, qui est ce qui a coûté les deux jours. Exemptés nommément : les harnais
de test (leurs fixtures NOMMENT des branches, c'est leur discriminant), les
outils de lab, et l'autorité elle-même.

**Les dettes nommées, hors périmètre L3** (recomptées le 2026-09-10) :

- `labctl/` (Go) porte encore 46 occurrences de `main` hors tests (`package
  main` et `func main` exclus) — surtout dans `governance-api`, qui lit son
  registre git sur une branche écrite en dur. Le moteur ne parle pas à la forge
  du client, mais ces valeurs par défaut n'ont pas été relues ; la porte de lint
  ne couvre pas le Go ;
- `ci/Jenkinsfile.carto` garde `CARTO_PAGES_BRANCH` avec un défaut `'main'` :
  c'est la branche **Pages** du dépôt carto, un paramètre documenté du job, sans
  rapport avec la branche de la chaîne. Exempté **nommément** par la porte ;
- **le périmètre de la porte est plus étroit que la surface livrée.**
  `ci/lint-branch-literals.sh` ne lit que `scripts/*.sh`, `scripts/lib/*.sh`,
  `ci/Jenkinsfile*`, `ci/jenkins/*.job.xml` et `ansible/roles/*/tasks/*.yml`.
  N'y entrent donc **pas** : `ci/lib/*.sh` (quatre scripts livrés),
  `scripts/lib/*.py` — dont `forge-api.py`, qui **compose le corps des PR** et
  dont la `base` est aujourd'hui un **argument**, jamais un littéral —,
  `ansible/roles/*/defaults|vars/*.yml`, `ansible/playbooks/*.yml`, et le Go
  ci-dessus. Balayage manuel du 2026-09-10 : **zéro littéral exécuté** dans ces
  familles. C'est de la prévention manquante, pas une fuite ouverte ;
- `scripts/seed-governance-chain.sh:88` pousse encore `HEAD:main` sur le dépôt
  de **gouvernance**, et relit `raw/branch/main`. C'est un **outil de lab**,
  exempté nommément par la porte, et le lab EST sur `main` — mais il ne
  tournera pas tel quel chez un client sur `master`. Même famille : les
  prérequis des harnais `test-a{0,3,4,5,6,7}-live.sh` et
  `test-selfservice-form-live.sh` ;
- `ci/lint-config-knobs.sh:84` extrait les défauts shell avec
  `\b([A-Z][A-Z0-9_]*)="?\$\{\1:-([^}"]*)\}"?`. La classe `[^}"]*` exclut le
  guillemet : un défaut de la forme `${VAR:-$(cmd "x")}` **ne matche pas du
  tout**, donc n'est jamais classé T1…T4. Aucun défaut de ce genre aujourd'hui,
  mais la porte ne le verrait pas passer.

**Au lab** : `docker compose -f docker-compose.gitlab.yml up -d gitlab` (seul,
3-5 min au premier boot), `bash scripts/setup-gitlab-lab.sh` → `.env.gitlab-lab`
(PAT 0600, hors Git), puis `FORGES=gitlab bash scripts/test-forge-api-live.sh`
(les verbes contre le GitLab RÉEL, discriminant J.1) et
`bash scripts/test-app-request-gitlab-live.sh` (la demande de bout en bout :
MR ouverte, rejeu idempotent, puis la panne du client reproduite et nommée).
Cette dernière **n'épingle plus `GIT_BASE`** (corrigé le 2026-09-10 : le knob
gagnait, donc la suite ne prouvait rien de la découverte, et sa MR visait `main`
sur un projet dont la *Default branch* est `master`) : elle lit la branche que
le projet **annonce** (`ls-remote --symref HEAD`), y pousse notre tronc, et
compare le `target_branch` de la MR à cette valeur. Elle est donc verte sur un
projet en `main` **comme** sur un projet en `master` ; sur un projet **vide**
(HEAD non née) elle **refuse**, elle ne devine pas.

## Le mode debug sans fuite (L2 — 2026-09-10)

Quand la chaîne casse chez un client, le log ne dit ni l'URL composée, ni le
chemin lu, ni la branche retenue, ni le statut HTTP que la forge a rendu : il
faut solliciter l'auteur. Le réflexe `set -x` est **interdit** — tous les
scripts font `set +x` — parce qu'un log Jenkins est **archivé** : un secret qui
y passe une fois y reste. Et le mode verbeux qui existait côté shell, celui de
`ci/lib/vault-login.sh`, était **fail-open** : son `_vault_redact … || cat`
sortait le corps d'erreur **en clair** dès que `python3` manquait — à l'inverse
de son commentaire.

**La décision** : une sortie **curatée** sur stderr, et chaque ligne passe par
une rédaction **fail-closed** avant d'y arriver — `ci/lib/dbg.sh` (POSIX, à
sourcer ; contrat en tête du fichier, preuve `scripts/test-dbg-redaction.sh`
108/108). Côté shell, rien d'autre ne sort en mode debug : `dbg <msg>`,
`dbg_kv <clé> <valeur>`, `dbg_http <méthode> <url> <code> [octets]`, `redact`
(le filtre stdin→stdout), et `dbg_on` / `dbg_init`. Toujours stderr, jamais
stdout ; le `$?` reçu est rendu tel quel (un `dbg` qui rendrait 0 effacerait le
verdict d'un `cmd || refus`) ; jamais d'ANSI ; jamais un secret en argv ni en
préfixe de commande — le canal vers python est un here-doc sur le descripteur
3, que `sh -x` ne trace pas.

**Le knob** : `STOA_DEBUG` — actif sauf vide, `0`, `false`, `off`, `no`
(`dbg_init` le normalise en `1` ou vide et l'**exporte**, pour que les enfants —
`forge-api.py`, le plan enchaîné, `gitea-pr-comment.sh` — parlent avec la même
valeur). **Dix formulaires** portent une case `DEBUG` qui exporte
`STOA_DEBUG=1` (les deux d'origine, `publish-api` et `selfservice`, plus les
huit de L4), et la globale Jenkins `STOA_DEBUG` (`setup-jenkins-globals.sh`)
est le **plancher** — voir « La case DEBUG et la globale (L4) » ci-dessous.

| Knob | Valeurs | Défaut | Rôle |
|------|---------|--------|------|
| `STOA_DEBUG` | tout sauf vide / `0` / `false` / `off` / `no` | vide (muet) | la **seule** autorité du mode debug — l'ancien `VAULT_DEBUG` n'existe plus ; relue à chaque appel, normalisée et exportée par `dbg_init` |
| `DBG_NAME` | un nom | le nom du script (`$0`) | ce qui s'écrit entre crochets : `[dbg <nom>]`. Aucun script de la chaîne ne le pose, et aucun Jenkinsfile non plus après L4 (le nom du script suffit) ; réservé au bloc `sh` d'un Jenkinsfile, où `$0` n'est pas un nom parlant (L4) |
| `DBG_SECRET_FILES` | chemins, un par ligne | vide | des **fichiers** de secret de plus à masquer, par leur contenu. `provision-request.sh` et `app-rollback-request.sh` y nomment le fichier du token **humain** — retiré de l'environnement par A7, la rédaction ne le connaît que par là ; variable de shell **non exportée** : un chemin n'est pas un secret, mais les enfants n'ont pas à le connaître |

### La case DEBUG et la globale (L4 — 2026-09-11)

**Deux knobs, une sémantique.** La globale Jenkins `STOA_DEBUG` (posée par
`scripts/setup-jenkins-globals.sh`, CONNUE et OPTIONNELLE comme `WEBHOOK_KIND`)
est le **plancher** : posée à `1` ou `true`, tout build du contrôleur parle —
formulaires, webhooks, pauses. La case `DEBUG` d'un formulaire **allume** le
mode pour ce build ; **décochée, elle n'éteint pas la globale** — le pont ne
fait qu'exporter, jamais vider. Absente (le défaut), la globale laisse la chaîne
muette : un rapport de `setup-jenkins-globals.sh` ne l'annonce pas « manquante »,
ce serait inviter à poser un debug permanent. Retirer la globale = la vider
(`STOA_DEBUG=` en argument du script) : `dbg_on` lit vide, `0`, `false`, `off`,
`no` comme éteint.

**Où vit la case** — au rang « juste avant le premier paramètre d'identité,
sinon en dernier » (le gabarit de `publish-api:36`), même libellé partout,
déclarée **là où le formulaire vit** :

| Job | Le formulaire vit dans | Case DEBUG | Re-pose |
|-----|------------------------|-----------|---------|
| `app-request`, `app-rollback` | `properties([parameters([…])])` du Jenkinsfile, XML `<properties/>` | dans le `parameters([...])` existant, avant `FORGE_TOKEN` | un build d'amorçage (`POST /job/<j>/build`) — le XML ne bouge pas |
| `team-request`, `api-promote-export`, `api-promote-request` | `parameters{}` déclaratif **et** XML miroir (le XML gagne à nom égal) | des deux côtés, **au même rang** (`BooleanParameterDefinition`, `defaultValue` false) | `JOBS="team-request api-promote-export api-promote-request" bash scripts/setup-team-onboard-jobs.sh` — visible dès le POST du XML |
| `api-request` | le XML seul (`Jenkinsfile.api-request` refuse tout `parameters{}`) | dans `ci/jenkins/api-request.job.xml`, en dernier | `JOBS=api-request bash scripts/setup-team-onboard-jobs.sh` (marqueurs CHOICES ⇒ `FORGE_SECRET` et forge joignable) |
| `prod`, `rollback` (`stoa-prod-deploy`, `stoa-prod-rollback`) | `parameters{}` déclaratif, sans XML ni poseur (jobs créés à la main, `ci/README.md`) | avant `VAULT_USER` | le premier build ré-enregistre le formulaire |
| `publish-api`, `selfservice` | déjà équipés (commit `33d8f36`) | inchangés | — |

**Exclus, et pourquoi** : les trois pauses `input{}` (`team-apply`,
`team-publish`, `team-promote`) et l'`input()` de `provision-apply` n'exposent
que l'identité (V_USER/V_PASS) et une suite épingle cette liste exacte — une
case de pause ne couvrirait de toute façon jamais la réconciliation qui précède
la pause ; les jobs webhook-only (`provision-plan`, `provisioning-request`,
`stoa-ci`) n'ont pas de formulaire ; **`carto`** garde un XML porteur de
paramètres **et** un `properties()` scripté (régime jamais mesuré, fait 6) et
aucun de ses scripts ne source `dbg.sh` : une case y serait un knob sans sortie
— dette nommée, pas une case. Tous reçoivent la globale.

**Le pont**, une seule forme, dans chaque bloc `sh` qui appelle un script
sourçant `dbg.sh`, juste après `set +x` quand il existe (sinon en tête) :

```sh
if [ "${DEBUG:-false}" = "true" ]; then export STOA_DEBUG=1; fi
```

En `if/fi`, jamais `[ … ] && export` : mesuré le 2026-09-11, la forme du plan
sans défaut (`[ "$DEBUG" = true ]`) abat le step sous `set -u` dès que `DEBUG`
n'est pas matérialisée (premier build d'un job `properties()`), et la liste
`&&` rend 1 si elle termine un bloc. `DEBUG` ne traverse **aucun** `withEnv` :
Jenkins expose nativement les paramètres de build au `sh`, en déclaratif comme
en `properties()` (le même canal que `selfservice` réserve à son mot de passe,
fait 9). Rien ne bouge dans les listes `withEnv` épinglées par les suites.

**Le moteur parle aussi** : les quatre scripts qui appellent `ansible-playbook`
(`api-promote-export.sh`, `team-apply.sh`, `team-publish.sh`, `team-promote.sh`
— branche `ansible` seulement) relaient `-e stoa_debug="$(dbg_bool)"`
(`dbg_bool`, `ci/lib/dbg.sh` : `true` si `dbg_on`, `false` sinon). Aucun
`ansible-playbook` n'existe dans ces Jenkinsfile, et six suites l'interdisent
(le pipeline route, le moteur reste dans `scripts/` et `ansible/roles/`). Effet
réel : les deux tâches `debug` gardées par `stoa_debug` dans
`apim_common/tasks/secrets.yml` — `no_log` n'est jamais levé.

**Preuves** : hors ligne `scripts/test-debug-knob-wiring.sh` 70/70 (`make
lint-ci` [11/20]) — une table des huit jobs (case à défaut `false`, libellé,
rang, miroir, pont, forme lue sur la vue CODE : toute occurrence de
`STOA_DEBUG` est le pont, aucun `withEnv` ne porte DEBUG), exclusions
explicites, globale dans les deux listes et dans `--help`, relais du moteur,
`lint-ci` qui joue la suite, et sept mutants qui rougissent (pont en `&&`, pont
avant `set +x`, rang déplacé, XML amputé, DEBUG glissé dans un `withEnv`,
`export STOA_DEBUG=false` après le pont, `defaultValue: true`) ;
`test-dbg-redaction.sh` 109/109 avec le cas A.7 de `dbg_bool` ; les suites
voisines re-comptent (team-request 5 paramètres, `test-palier-retention` ⑰bis,
`test-promote-sans-recopie` §13, `test-api-request-wiring` :302,
`test-app-rollback-a6` D.2/D.6). Les trois suites de câblage orphelines
(`app-request`, `api-request`, `team-apply`) entrent sous `lint-ci` et sous
shellcheck le même jour : L4 réécrivait leurs ancres, une suite hors porte ne
mesure plus rien.

**Preuve live** (2026-09-11, `scripts/test-debug-knob-live.sh` **22/22**, lab
sur gitea `c45f456`) : les huit formulaires réels relus par l'API portent
`DEBUG` au rang attendu après la re-pose (XML par `setup-team-onboard-jobs.sh`
pour team-request/api-promote-*/api-request — ce dernier avec un jeton de forge
jetable en lecture seule, minté puis révoqué —, amorçage d'app-request et
d'app-rollback, un build à vide refusé par leur porte pour `stoa-prod-deploy`
#5 et `stoa-prod-rollback` #7). Témoin `api-promote-export`, identité
nominative inexistante, mot de passe sentinelle : build **#5** case cochée ⇒
`FAILURE` au login refusé **avec** cinq lignes `[dbg` (« voie A (user/pwd) :
mount=auth/ldap user=l4-nobody », « POST …/auth/ldap/login/l4-nobody -> HTTP
400 »), sentinelle absente de la console, aucune trace `+` du mot de passe ;
build **#6** case décochée ⇒ même refus, **zéro** ligne `[dbg` ; build **#7**
case décochée, globale `STOA_DEBUG=1` ⇒ le build parle (le plancher tient) ;
globale restaurée à vide par le trap. Deux faits à retenir : le préfixe des
lignes est **`[dbg script.sh.copy]`** — le `$0` du step Jenkins, jamais le nom
de la lib sourcée — d'où un oracle par CONTENU dans la suite ; et un job
webhook-only lancé à vide (`provisioning-request` #20) refuse **avant**
d'atteindre un script qui parle : la globale atteint tout build, mais elle ne
fait parler que ce qui s'exécute.

**Qui parle** (sous `STOA_DEBUG`, une ligne par décision, juste après elle) :

- `scripts/lib/forge-api.py` — **une ligne par requête**, `[dbg forge-api.py]
  METHOD url -> HTTP code (n octets)` (ou `-> ERREUR URLError` quand rien n'a
  répondu), écrite **avant** toute cause de refus, 3xx et 5xx compris — c'est
  la ligne `-> HTTP 302` que le client GitLab du 2026-09-09 devait lire.
  Process python : il écrit lui-même, masqué par son `_mask` (l'autorité de ses
  causes depuis L1 ; même liste de valeurs que `dbg_on`). `forge_api_init`
  (`forge-api.sh`) dit `FORGE_KIND=`, `FORGE_API_AUTH=`, `GIT_HOST=`,
  `GIT_REPO=`, `FORGE_API_BASE=` (vide ⇒ `<vide>`) ;
- `scripts/lib/git-base.sh` — `git ls-remote --symref <url masquée> HEAD -> rc
  N (n octets)` **avant** tout refus, puis `GIT_BASE=` et
  `GIT_BASE_ORIGINE=knob|decouverte` ; `GIT_BASE_OF <url masquée>=<branche>`
  par dépôt ;
- les quatre scripts de la chaîne app-request — `provision-request.sh`,
  `provision-plan.sh`, `provision-apply-reconcile.sh`, `app-rollback-request.sh`
  — disent ce qu'**eux** décident, sans redire les autorités : la disposition
  (`SUB_PFX` — vide ⇒ `<vide>`, c'est le diagnostic d'un IGNORE chez un client
  dont la forge préfixe —, `MANIFEST_DIR`, `REL_PATH` / `MANIFEST_PATH` /
  `MAN_PATH` / `MANIFEST`, `PROV_FILE=… existe=oui|non`), l'identité
  (`FORGE_LOGIN`, `PUSH_LOGIN`, `MODE`, `BRANCH`, `TENANT`), les URL
  **composées** (`CLONE_URL`, `PUSH_URL`, `GIT_CLONE_URL`, `CLONE_BASE` — c'est
  elles qu'on diagnostique, un userinfo y est masqué), la PR relue — `PR #n
  relue : state=… head=… sha=… base=… same_repo=… (attendu head=… base=…)`,
  écrite par `gitea-pr-confirm.sh`, la ligne qu'on lit quand
  `FORGE_NON_CONFIRMEE` tombe, et sa jumelle de la réconciliation avec
  `merged=… merge_sha=… merged_by=…` —, les digests, la lignée et les bornes du
  repli (`MERGED_DIGEST`, `BASE_DIGEST`, `REPLI_DE`, `BIRTH`, `D_BASE`,
  `D_EXPECT`, `TIP`, `NUM_N`/`SHA_N`, `NUM_N1`/`SHA_N1`), et **chaque geste git**
  avec son **vrai** rc — `git clone --depth 1 -b <branche> <url> -> rc 0`,
  `git fetch … -> rc 128` (le premier passage, jadis jeté à `/dev/null`),
  `git push --force-with-lease=… -> rc 0` — suivi, s'il a parlé, d'une ligne
  `  git: …` : son stderr **masqué en entier, puis mis sur une ligne, puis
  coupé** à 400 octets, jamais dans l'autre ordre. Les lignes HTTP de
  `forge-api.py` qu'une capture de stderr perdait sur succès sont relayées
  (`pr_get`, `pr_files`, `pr_find_open`) — dont celle du `whoami` réussi, que
  `forge_login` (`forge-identity.sh`) lisait, effaçait et perdait ;
- `gitea-pr-comment.sh` — `PR_NUMBER=`, `COMMENT_MARKER=`,
  `COMMENT_ONLY_IF_EXISTS=`, `CF_ID=` (vide ⇒ la raison du SKIPPED),
  `CU_ACTION=`, `CU_ID=` ;
- `ci/lib/vault-login.sh` — chaque appel Vault par `dbg_http`, le contexte du
  login (`VAULT_ADDR`, namespace, CA, voie A/B, mount, user), l'**empreinte** du
  mot de passe — sa longueur en caractères et en octets, les blancs parasites,
  et **deux** hex de son SHA-256 (`sha256=d3…` : 8 bits, « même valeur ou pas »,
  une chance sur 256 de coïncidence, rien qu'un dictionnaire hors ligne puisse
  confirmer ; les 16 hex d'avant, 64 bits non salés, étaient un **oracle** sur
  le mot de passe LDAP/AD d'un compte humain — relecture finale, I-2) — et,
  sur un statut ≥ 400 seulement, le corps d'erreur `↳ erreur: …` rédigé **puis**
  coupé à 400 caractères ; un corps 2xx (token de login, valeur KV) n'est
  **jamais** imprimé.

**Ce qui est masqué** — par **littéral** connu du process : les valeurs de
`FORGE_SECRET`, `GITEA_TOKEN`, `FORGE_TOKEN`, `PUSH_TOKEN`, `VAULT_TOKEN`,
`VAULT_USER_PASSWORD`, `WM_PASSWORD` / `WM_PASS` / `WM_BEARER`,
`LDAP_ADMIN_PASSWORD`, le **contenu** des fichiers `CI_TOKEN_FILE`,
`PR_TOKEN_FILE`, `VAULT_TOKEN_FILE`, `FORGE_TOKEN_FILE`, de ceux de
`DBG_SECRET_FILES` et de ceux passés en argument à `redact` — sous toutes leurs
formes (`%XX` d'URL, `+` d'un corps de formulaire, échappements JSON, base64 de
`user:secret`) et par **morceaux** (chaque segment de 4 caractères ou plus,
coupé à `/` et aux blancs : ssh écrit « Could not resolve hostname
git:MORCEAU ») ; par **forme**, sans littéral connu : `Authorization: <schéma>
<valeur>` (le schéma reste — il dit si l'en-tête est celui de Gitea ou de
GitLab), l'userinfo d'une URL `://…@` (l'hôte reste), `hvs.` / `hvb.`, un JWT
`eyJ…`, une valeur derrière une clé `password` / `secret` / `token` / `api_key`…
(ce qui couvre `PRIVATE-TOKEN:` et `X-Vault-Token:`). Le masque est un
**atome** : une valeur déjà masquée en partie est remasquée en entier. Sans
`python3` : la ligne unique `<rédaction indisponible>` et **rien d'autre** —
mieux vaut aucun debug qu'un debug qui fuit.

**Ce qui n'est jamais écrit** : un corps de réponse 2xx ; un secret en argv —
le `grep -v "$(cat "$PUSH_TF")" | grep -v "$FORGE_SECRET"` qui mettait **deux**
secrets dans l'argv d'un process (`ps` les voit) et **jetait** la ligne a
disparu de ses trois sites (`provision-request.sh`, `app-rollback-request.sh`
×2, clone et push), remplacé par `redact "$PUSH_TF"` : un chemin en argument, la
ligne masquée et gardée ; une ligne sur **stdout** — les scripts y rendent leur
produit (`PR_URL=`, `RECONCILE_OK`, `OK:`), une ligne de debug égarée y
deviendrait une valeur. Et sans `STOA_DEBUG`, **rien ne change à l'octet** :
chaque suite compare le produit (stdout, faits) à une référence prise sans
debug.

**Comment lire un log** : `grep '^\[dbg '` — le préfixe est en tête de ligne,
sans ANSI, et nomme qui parle (`[dbg provision-request.sh]`,
`[dbg forge-api.py]`). La ligne HTTP **précède** la cause, qui précède le
`REFUS: TAG` : un log se lit de haut en bas. `<vide>` derrière une clé veut
dire « la variable est vide ou absente » — Jenkins retire une variable vide de
l'environnement, c'est un diagnostic, pas un masque. Sur un refus de
`provision-plan.sh`, les lignes `[dbg` sont **séparées** de la cause par leur
préfixe avant qu'elle n'entre dans `PLAN_REASON`, donc dans le commentaire de
statut de la PR — sans debug, le refus est octet pour octet celui d'avant. À ne
pas confondre : `git-base: GIT_BASE=<b> découvert — HEAD annoncée par <url>
(ls-remote --symref)` (et sa sœur `retenu (knob explicite)`) est la ligne
d'**audit** d'une pose, venue de L3, **inconditionnelle** et sans préfixe
`[dbg` : elle sort sans `STOA_DEBUG`, une fois par build, et dit d'où vient la
branche ; les lignes `[dbg …] GIT_BASE=` / `GIT_BASE_ORIGINE=` qui la suivent
sous debug sont le mode debug, rédigé.

**Les preuves** (comptes de la branche livrée, rebasée sur la branche par
défaut du dépôt) : `test-dbg-redaction.sh` 108/108 (la lib, figée) ;
`test-forge-api.sh` 103/103 ; `test-git-base.sh` 111/111 ;
`test-vault-login-offline.sh` 72/72 (stub Vault, mot de passe sentinelle, sous
dash, sh et bash, `python3` retiré ⇒ `<rédaction indisponible>`) ;
`test-app-request-a7.sh` 120/120 ; `test-provision-apply-a2.sh` 232/232 ;
`test-app-rollback-a6.sh` 159/159 ; `test-pr-comment.sh` 62/62 ;
`test-a0-wiring.sh` 245/245. Chaque absence (« le secret n'y est pas ») est
doublée d'une présence (« la ligne HTTP attendue y est »), et l'**ordre**
masque-puis-coupe a son épreuve à discriminant : un secret recopié **à cheval**
sur l'octet de coupe, qu'un mutant « coupe puis masque » laisse fuir. La même
famille de défaut a été trouvée trois fois en phase A dans le code
(`git-base.sh` coupait le stderr de git à 300 octets avant de masquer,
`vault-login.sh` le corps d'erreur à 400, `forge-api.py` ignorait la forme
`%XX`), trois fois en phase B dans les épreuves (l'ordre était juste, aucune
épreuve ne l'épinglait — a7, a2, a6), une fois de plus dans le code, héritée
d'avant L2 (le refus `GITEA_RECONCILE_ECHEC` de la réconciliation relayait
200 octets **bruts** du stderr de `git fetch` — masqué avant coupe désormais),
et **deux fois encore par la relecture finale** : `_debut` de `forge-api.py`
coupait à 120 octets **avant** de masquer le début de corps qu'une cause cite
(chemin inconditionnel, jusque dans `PLAN_REASON` : un PAT à cheval sur
l'octet 120 sortait à 20 caractères — `test-forge-api` P.11, mutant P.11c), et
la ligne « PR relue » de la réconciliation passait ses valeurs par `shown`
(coupe à 80 puis `%q`) **avant** `dbg` — le `%q` défait un littéral qui porte
un espace (`test-provision-apply-a2` E.9, mutants E.9e/f) ; valeurs brutes
désormais, comme sa jumelle de `gitea-pr-confirm.sh`.

**Le défaut de site de la voie du plan est tombé** : `provision-plan.sh` et
`provision-plan-status.sh` gardaient un `GIT_HOST` par défaut de lab
(`http://gitea:3000`), exempté comme « dette connue » dans
`ci/lint-config-knobs.exempt`. Retiré, exemptions retirées : un client dont le
pipeline ne transmet pas la variable lit `GIT_HOST requis` en tête, il ne
découvre plus la panne sous `BRANCHE_PAR_DEFAUT_INCONNUE`. Ce n'est **pas** le
dernier défaut de site du dépôt — treize `GIT_HOST` par défaut restent hors de
la voie du plan (ci-dessous, « Dettes hors périmètre »).

**Limites nommées** :

- la ligne d'**appel** (`+ dbg …`, `+ dbg_kv CLONE_URL …`) est tracée par un
  appelant sous `sh -x` **avant** d'entrer dans la lib — la lib n'y ajoute
  aucune ligne, mais ne retire pas celle-là. Un bloc Jenkins doit faire
  `set +x` avant le pont `DEBUG ⇒ STOA_DEBUG` — c'est la forme posée par L4 sur
  les dix formulaires, épinglée par `scripts/test-debug-knob-wiring.sh` ;
- `provision-apply-comment.sh`, appelé par le `fail()` de la réconciliation
  avec sa sortie jetée (`>/dev/null 2>&1`), n'est pas instrumenté : la ligne
  HTTP du commentaire de refus ne se lit pas ;
- les tokens Vault d'avant 1.10 (`s.…`, `b.…`) ne sont **plus une forme
  masquée** (l'ancien `_vault_redact` les prenait) ; le **littéral**
  `VAULT_TOKEN` et le contenu de `VAULT_TOKEN_FILE` le sont, `hvs.` / `hvb.`
  restent une forme ;
- `provision-plan-status.sh` n'est pas instrumenté (seul son défaut de site est
  tombé) ; `forge-identity.sh` relaie la ligne de `forge-api.py`, elle ne parle
  pas elle-même.

**Dettes hors périmètre, relevées par les relectures** (antérieures à L2, hors
du canal debug) :

- le lien humain du commentaire `[4/4]` de `provision-plan.sh` porte
  l'userinfo d'un `GIT_HOST` de la forme `http://user:jeton@…` quand
  `GIT_WEB_HOST` est absent (repli `GIT_WEB_HOST="${GIT_WEB_HOST:-$GIT_HOST}"`)
  — visible du demandeur, indépendant de `STOA_DEBUG` ; un client passe
  `GIT_WEB_HOST`, mais rien ne l'y oblige ;
- **treize `GIT_HOST` par défaut restent** dans du code livrable (mesuré :
  `grep -rn 'GIT_HOST:-' scripts/*.sh scripts/lib/*.sh` hors `test-*`) — onze
  `http://gitea:3000` (`api-request.sh`, `api-promote-request.sh`,
  `api-promote-export.sh`, `team-request.sh`, `team-apply.sh`,
  `team-promote.sh`, `team-publish.sh`, `provision-apply-gate.sh:70`,
  `provision-apply-comment.sh:209`, `lib/archive-store.sh:44`,
  `lib/generate-choices.sh:580`) et deux `http://localhost:13000`
  (`seed-governance-chain.sh`, `setup-repo-protections.sh`). **Deux sont sur la
  voie apply de la même chaîne app-request** : `provision-apply-gate.sh:70`
  (appelée deux fois par `ci/Jenkinsfile.provision-apply`) et
  `provision-apply-comment.sh:209` (appelée par le `fail()` de la
  réconciliation). Les retirer (`${GIT_HOST:?…}`, exemptions retirées, présence
  dans a4/a0) est le lot suivant : `test-provision-apply-a4.sh` joue la porte
  58 fois (`run_gate`) **sans** `GIT_HOST` (mesuré : `grep -vE '^\s*#'
  scripts/test-provision-apply-a4.sh | grep -cE '(^|[^a-z_])run_gate '`), ses
  fixtures sont à reprendre ;
- `ci/lint-config-knobs.sh` n'examine qu'**un défaut par ligne** (le premier
  qui correspond, puis `break`) — deux victimes connues : le `GIT_REPO` de
  `provision-plan-status.sh`, caché derrière `GIT_HOST` sur la même ligne et
  apparu au retrait de celui-ci (d'où une exemption **ajoutée**, datée, à un
  fichier qui dit qu'on n'en ajoute jamais), et le `GIT_HOST` de
  `provision-apply-gate.sh:70`, caché derrière `GIT_REPO` sur la même ligne :
  **non exempté, jamais vu** par la porte. Elle ne compte pas non plus une
  exemption **orpheline** — `provision-apply-reconcile.sh:GIT_HOST` ne
  couvrait plus rien depuis L5 (`GIT_HOST="${GIT_HOST:-}"`, classé « vide ») et
  la porte disait 186 exemptées avec comme sans elle ; retirée (relecture
  finale, I-4). Remède connu : un défaut par **correspondance** (`finditer`),
  et le décompte des exemptions que rien ne consomme ;
- dette L3 : `generate-choices.sh` (`_gc_base_of`) capture le stderr de
  `git_base_of` et ne le ressort, expurgé, que sur échec — sur succès la ligne
  d'audit de git-base **et** les lignes `[dbg` sont avalées ; et
  `ci/Jenkinsfile.selfservice` découvre la HEAD **inline** (`git ls-remote
  --symref origin HEAD | sed …`, deux stages) sans passer par la lib, donc sans
  ligne du tout. Remède connu : le relais de la grammaire (le fichier capturé
  est relu sur stderr, succès compris) pour l'un, la lib pour l'autre ;
- mineurs consignés : `(n octets)` de git-base compte des caractères sous une
  locale UTF-8 ; un `@` nu dans un mot de passe d'URL est coupé différemment
  par `_mask` (`[^/@\s]`) et par `redact` (`[^/\s]`) ; `_dbg_on` de
  `forge-api.py` nettoie et met en minuscules là où `dbg_on` compare tel quel
  (` 0`, `fAlSe`) — sans effet dès que `dbg_init` a normalisé ; stderr fermé +
  `STOA_DEBUG=1` fait rendre rc 1 à `forge-api.py` au lieu de son verdict
  (`_dbg` n'est pas gardé).

## Le récepteur de webhooks (L6 — 2026-09-11)

Le 2026-09-11, chez le client GitLab, `provision-plan` mourait **avant son
premier stage** : `Invalid trigger type "GenericTrigger"`. Le plugin
**generic-webhook-trigger** ne peut pas être installé sur son Jenkins, et un
symbole de déclencheur nommé dans un bloc Declarative `triggers { }` est résolu
**à la compilation** — le job est donc refusé, pas dégradé.
`selfservice-app-deploy` mourait de la même cause, à l'invocation
(`No such DSL method 'GenericTrigger'`), alors que son hook n'est même pas un
hook de forge : c'est la gateway wM qui le sonne. Ce Jenkins a, lui, le **GitLab
Plugin**.

**Une seule autorité, et elle est dans le Jenkinsfile.** Chaque pipeline de
l'aval applicatif pose son déclencheur ET son verrou de concurrence par un
`properties()` **scripté**, au premier stage, selon la globale `WEBHOOK_KIND` —
un `if` non pris n'invoque pas le symbole, donc n'exige pas le plugin. Toute
autre valeur est refusée par nom, **avant** que rien ne soit posé
(`WEBHOOK_KIND_INVALIDE`). Les `job.xml` de `provision-plan` et
`provision-apply` ne portent plus **aucune** propriété : un XML porteur du même
déclencheur donne un **doublon** au premier build, puis l'exemplaire du XML est
**perdu** au second (mesuré). Conséquence directe : le déclencheur n'existe
qu'après le premier build — l'**amorçage**, que `setup-provision-jobs.sh`
déclenche, **attend** et **relit** (`AMORCAGE_INCOMPLET` sinon).

**Knobs** (globales Jenkins, `setup-jenkins-globals.sh --help`) :

| Knob | Valeurs | Défaut | Rôle |
|------|---------|--------|------|
| `WEBHOOK_KIND` | `gwt` \| `gitlab` | `gwt` | le **récepteur** de ce Jenkins, pas le visage de la forge (`FORGE_KIND`) : un même GitLab se sert par l'un ou l'autre. `gwt` : `/generic-webhook-trigger/invoke?token=<token du job>`, les deux formes de payload (Gitea, GitLab) lues sans knob. `gitlab` : `/project/<job>` + `X-Gitlab-Token` ; `provision-plan` écoute ouverture / réouverture / push / titre, `provision-apply` la **fusion seulement** ; `selfservice-app-deploy` n'a **aucun** hook direct |
| `BOOTSTRAP_JOBS` | liste \| `none` | `provision-apply provision-plan` | les jobs amorcés après la pose (`setup-provision-jobs.sh`). Le mot `none` débranche — une valeur vide n'atteint pas le shell depuis Jenkins |
| `BOOTSTRAP_AWAIT_JOBS` | liste \| `none` | idem | ceux dont l'amorçage est **attendu puis relu** ; `none` rend le geste fire-and-forget d'avant |
| `BOOTSTRAP_WAIT` | secondes | `360` | la borne de cette attente |

**Prérequis côté client GitLab** (à obtenir AVANT de brancher les webhooks) :

- **GitLab Plugin ≥ 1.7.13** : c'est la version qui expose
  `gitlabMergeCommitSha`, donc la référence A2. Sans elle, l'apply n'a aucun SHA
  à projeter ;
- **deux webhooks de projet**, événements **« Merge request » seulement**
  (jamais push), vers `https://<jenkins>/project/provision-plan` et
  `https://<jenkins>/project/provision-apply`, champ **Secret Token** =
  `stoa-provision-plan` / `stoa-provision-apply`. Ce mot est une **sonnette**,
  pas une autorité : la réconciliation relit la forge (`FORGE_NON_CONFIRMEE`,
  `PAYLOAD_PERIME`). Sans token, l'endpoint authentifié du plugin — actif par
  défaut — répond 401/403 ;
- **méthode de merge = merge commit** : en fast-forward ou squash, GitLab ne
  remplit pas `merge_commit_sha` et l'apply refuse `MERGE_SHA_INVALIDE` ;
- **jobs créés à la main** (sans le poseur) : type **Pipeline**, « Pipeline
  script from SCM », `Lightweight checkout` **décoché** (le workspace doit porter
  `scripts/`, `ansible/`, `ci/lib/`), **aucun** déclencheur coché, puis **« Build
  Now » une fois** : le build sort vert (« hors provision/* ») sans exécuteur et
  pose le déclencheur ;
- ce que le plugin ne dit pas : il **n'expose pas l'action** de la MR
  (`gitlabActionType` vaut `MERGE` même sur une ouverture) et un état hors de
  son énumération devient un **joker** dans ses règles. Le pipeline relit donc
  l'**état** : `opened` pour le plan, `merged` pour l'apply — hors de là, le
  build sort vert et ne fait rien ;
- un **bon** token sur un corps forgé fait **500** dans le handler du plugin
  (aucun build) : à savoir en lisant les journaux, rien à corriger ;
- ⚠ **sur un GitLab privé, posez `GIT_BASE` explicitement.** La découverte de la
  branche par défaut (L3, `git ls-remote --symref … HEAD`) tourne **hors** de
  l'enveloppe d'authentification du clone : sur un dépôt qui exige des droits en
  lecture, elle meurt `fatal: could not read Username … terminal prompts
  disabled` et le plan refuse `BRANCHE_PAR_DEFAUT_INCONNUE` (mesuré le
  2026-09-11 sur le GitLab du lab). Le refus nomme lui-même la voie. **Dette
  L3** : faire passer cette sonde par la même enveloppe que le clone ;
- le **credential de la forge** est un jeton de **forge** : un jeton Gitea dans
  `GITEA_CREDENTIALS_ID` fait échouer la réconciliation en **401** sur l'API
  GitLab, APRÈS le déclenchement — le webhook a l'air bon, la chaîne meurt plus
  loin. Un site GitLab pose un PAT GitLab (`api`, `read_user`,
  `write_repository`) ;
- ⛔ **LA FORGE PRIVÉE : quatre gestes anonymes, tous fermés le 2026-09-11.** Ce
  qui suit était le récit du bloquant ; il est désormais résolu, et la
  description reste parce qu'elle dit *comment la panne se présentait* — chacun
  des quatre accusait autre chose que sa vraie cause :
  | # | Le geste | Comment la panne se présentait | Fermé par |
  |---|---|---|---|
  | 1 | `provision-plan.sh` clonait la plateforme **sans enveloppe** et ignorait `GIT_CLONE_URL` — seul de la chaîne | `CLONE_ECHEC`, puis l'apply sur `MERGE_SHA_NON_ANCETRE` (il avait lu un autre dépôt) | `ec6ebfd` |
  | 2 | la **découverte** de la branche par défaut, même script | `BRANCHE_PAR_DEFAUT_INCONNUE` : « could not read Username … terminal prompts disabled » | `ec6ebfd` |
  | 3 | la découverte **puis** le `git fetch` de `provision-apply-reconcile.sh` | `GITEA_RECONCILE_ECHEC` — et le défaut RECULAIT d'un cran à chaque correctif partiel | `eb95760`, `2d9a997` |
  | 4 | le `<scm>` des treize `job.xml` ne porte **aucun** `credentialsId` : le checkout que **Jenkins** fait du Jenkinsfile est anonyme | `Authentication failed`, **avant** d'exécuter une ligne de pipeline | knob `GIT_CREDENTIALS_ID` du poseur (`eb95760`) |

  **Pourquoi personne ne l'avait vu** : le Gitea du lab sert `info/refs` en
  **lecture anonyme** (200) là où un projet GitLab privé rend **401**. Les quatre
  gestes fonctionnaient par accident.

  **Ce qu'un site sur forge privée doit poser** :
  - `GIT_CREDENTIALS_ID` au poseur (`setup-provision-jobs.sh`), qui l'injecte
    dans le `userRemoteConfig` des jobs — ⚠ **ce credential doit être un COUPLE
    username/password** (ou une clé SSH) : le Git SCM de Jenkins ne sait pas se
    servir d'un « Secret text », et le build meurt sans autre explication. Un
    site pose donc **deux** credentials pour le même jeton — celui de la chaîne
    (`GITEA_CREDENTIALS_ID`, les deux types via `FORGE_CRED_KIND`) et celui du
    `<scm>` ;
  - rien d'autre : le clone, les deux découvertes et le fetch s'authentifient
    seuls à partir du secret de la chaîne.

  **La porte** : `scripts/test-git-base.sh` « H bis » mesure, **geste par geste**
  (pas fichier par fichier — un script avait sa découverte enveloppée et son
  fetch nu), que tout `clone`/`push`/`fetch`/`ls-remote` d'un script **exécuté
  par un pipeline** porte un mécanisme ; le périmètre est dérivé des Jenkinsfile,
  les poseurs `setup-*` sont exemptés nommément (ils ne clonent jamais, et leur
  refus nomme `GIT_BASE`). Le login vient d'une **autorité unique**,
  `git_base_basic_login` : `FORGE_USER` s'il est posé, sinon `oauth2` hors Gitea,
  sinon `x` — « x » convient à Gitea, **jamais** à GitLab ni Bitbucket.

  **Dette datée du 2026-09-11, à cliquet** : huit gestes nus subsistent dans la
  chaîne API/producteur (`api-request.sh` 287, 339, 420, 448 ;
  `api-promote-request.sh` 263, 374 ; `team-apply.sh` 136 ; `team-request.sh`
  166). La porte refuse tout geste nu **neuf**, et refuse aussi une ligne de
  dette qui ne correspond plus — réparer **oblige** à la retirer.

  **Preuve** : `scripts/test-webhook-kind-gitlab-live.sh` **28/28** contre un
  GitLab **privé** (le dépôt doit rendre 401 en anonyme, sans quoi la suite
  refuse de tourner : elle ne prouverait rien), `GIT_BASE` laissée absente.

**Pas d'écart de comportement entre les deux visages** sur les événements d'une
MR : le plugin reconstruit le plan sur un changement de titre comme sur un push,
exactement comme le generic-webhook-trigger. La « garde déjà construit » que ses
sources laissaient craindre ne s'applique pas — mesuré par builds réels.

**La porte** : `test-a0-wiring.sh` §3bis (structurel : l'ordre refus →
`properties()` → fait unifié, la table des cases du plugin, un seul symbole de
chaque en vue code) et §8bis (neuf mutations qui doivent rougir) ;
`test-setup-provision-jobs.sh` §16 (l'amorçage attendu et relu, six refus) ;
sous `make lint-ci` [11/20] et [1/20]. **Angle mort assumé** : aucune suite
statique ne voit un `if` dont la condition ment — le miroir lit le premier
symbole qu'il trouve. Seule la preuve live le couvre, et la porte le dit.

**⚠ L'ORDRE DE POSE COMPTE : les globales AVANT les jobs** (mesuré le
2026-09-12). L'amorçage d'un job dont le XML est vide n'est plus une option — le
poseur s'impose et relit (`AMORCAGE_INCOMPLET` sinon). Or un build d'amorçage
traverse le `post { always { … } }` du pipeline, qui prend un nœud et appelle
`forgeCreds()` : sans la globale `FORGE_CRED_KIND`, ce dernier refuse
(`FORGE_CRED_KIND_INVALIDE`), le build d'amorçage échoue, et la **pose entière**
échoue. C'est fail-closed et le message nomme le knob manquant — mais un
exploitant qui pose ses jobs avant ses globales verra un refus qui parle d'un
credential là où il lui manque une variable. Poser les globales
(`setup-jenkins-globals.sh`) d'abord, les jobs ensuite.

**Les identités ne viennent pas du payload** (L6 phase 2). La garde des quatre
yeux de `team-apply` était nourrie de `$.pull_request.merged_by.login` et
`$.pull_request.user.login` : le GitLab Plugin n'expose **aucun** des deux, et le
seul palliatif apparent (`gitlabMergedByUser`) est l'**acteur** de l'événement,
muet sur le demandeur. Le job **relit donc la forge** (`forge pr_get`, qui parle
les deux visages) et le payload redevient ce qu'il est — une affirmation, gardée
pour le journal. Corollaire durci le même jour : un demandeur inconnu est un
refus (`REQUESTER_UNKNOWN`), là où un champ vide faisait auparavant **sauter** le
contrôle au lieu de le faire échouer. Seul `--allow-self-approval` dit que les
quatre yeux ne sont pas exigés.

**Un bloc `sh` de Jenkins est du DASH — donc ce qu'il source aussi.** La
relecture ci-dessus a d'abord été écrite *inline* dans le `sh` du Jenkinsfile,
et elle ne pouvait pas s'exécuter : `scripts/lib/forge-api.sh` est du **bash**
(`${BASH_SOURCE[0]}`, `printf -v`, here-string), et `dash -n` la refuse
(« 111: Syntax error: redirection unexpected »). Le step mourait sur deux
messages de dash qui ne nomment **aucun** refus du dépôt, après avoir réveillé
un humain et encaissé son mot de passe d'annuaire — sur les deux visages, Gitea
comprise. La règle, sans exception : **une lib `scripts/lib/*.sh` ne se source
que depuis du bash**, et le Jenkinsfile appelle `bash scripts/<script>.sh` (un
process à soi, son shebang). D'où `scripts/forge-merge-identity.sh`. La porte est
dans `ci/lint-jenkinsfiles.sh`, portée **dérivée** : toute ligne de
`ci/Jenkinsfile*` qui source une lib doit passer `dash -n`.

**Le payload et l'objet appliqué doivent être LE MÊME.** Relire `pr_get
$PR_NUMBER` pour n'en prendre que les identités ne suffit pas : `PR_NUMBER` est
un fait du payload, tandis que l'objet appliqué vient de `PR_BRANCH`/`MERGE_SHA`
(`git checkout "$MERGE_SHA"`). Qui poste **son** merge avec le **numéro** d'une
PR d'autrui fait valider les quatre yeux par une PR étrangère, en vert.
`forge-merge-identity.sh` confronte donc les trois faits que la forge rend —
`merged`, `merge_commit_sha`, `head.ref` — et refuse `PAYLOAD_PERIME`, comme le
fait déjà la réconciliation de `provision-apply`.

**La chaîne PRODUCTEUR a ses deux visages (phase 2, 2026-09-12).** `team-apply`,
`team-publish` et `team-promote` ont perdu leurs blocs déclaratifs, leurs XML
sont à `<properties/>`, et leur `post{always}` est gardé AVANT le nœud — ce
dernier point n'est pas cosmétique : l'amorçage leur étant désormais **imposé et
jugé** par le poseur (qui le déduit du XML), un `post` sans `timeout` qui attend
un exécuteur occupé fait déclarer la POSE en échec sur un job dont le déclencheur
EST posé.

**Sous le visage `gitlab`, chaque dépôt d'ÉQUIPE porte DEUX webhooks** —
`/project/team-publish` et `/project/team-promote` — et c'est plus **serré** que
le visage `gwt`, pas équivalent : sous `gwt`, ces deux jobs partagent un token,
donc un seul appel réveille les DEUX et le tri se fait plus tard, dans le `when`
de chacun ; sous le plugin, la clé de routage est l'URL et `sourceBranchRegex`
trie **dans le récepteur** (`api/.*` / `promote/.*`). `team-promote` ne construit
donc plus jamais sur une fusion `api/*`. À ne pas lire comme une divergence.

**Le `Secret token` est posé PAR LE JOB**, pas par le hook : le hook doit envoyer
la valeur que le job attend. Défauts : `stoa-team-publish` et `stoa-team-promote`,
surchargeables par les globales `TEAM_PUBLISH_WEBHOOK_SECRET` et
`TEAM_PROMOTE_WEBHOOK_SECRET` (promote retombe sur publish, puis sur son
littéral) — un site qui pose UN seul secret sur ses deux hooks fonctionne donc
sans knob supplémentaire. ⚠ Ce n'est pas encore un secret (littéral en Git,
globale lisible dans l'UI) : dette nommée. Et **le mode de panne est muet côté
Jenkins** : si les deux valeurs divergent, GitLab prend un 401 que seul
l'historique de livraison du webhook montre — aucun build, aucun log. Même
famille que le silence mesuré au spike M4 (`POST /project/<job>` sur un job sans
déclencheur ⇒ 200, aucun build) : sous ce visage, l'absence de build ne se
diagnostique jamais depuis Jenkins.

**Les identités de `team-publish` ne viennent plus du payload** : comme
`team-apply`, il relit la forge (`scripts/forge-merge-identity.sh`, préfixé
`GIT_REPO="$WEBHOOK_REPO"` — la PR vit dans le dépôt de l'équipe). Dette nommée :
`team-publish.sh` relit DÉJÀ la forge pour sa propre réconciliation, donc il y a
deux relectures par build ; le geste qui les ramène à une seule est de déplacer
la garde DANS le script, ce qui relève du CORPS du job (L5 phase 2). Refuser dans
le pipeline garde en attendant un avantage réel : le refus tombe **avant** le
login Vault nominatif, donc sans émettre de jeton.

**Au lab** : `scripts/test-webhook-kind-gitlab-live.sh` (la chaîne entière par le
GitLab Plugin : plan sur ouverture et sur push, apply sur la fusion avec
`MERGE_SHA` égal à l'API, close muet, token exigé, retour à `gwt` vérifié) ;
non-régression `gwt` par `test-a6-live.sh` et `test-a7-live.sh` inchangés ;
`gitlab-plugin` ajouté à `ci/jenkins/Dockerfile` pour qu'un lab reconstruit
porte les deux récepteurs.

**Dettes** : **deux** Jenkinsfile de la chaîne API (`publish-api`,
`provisioning-request`) portent encore un bloc déclaratif — même motif à rejouer
avant tout client GitLab sur la chaîne producteur. (`team-apply` en est sorti le
2026-09-12 : plus de `triggers {}` ni d'`options {}`, XML à `<properties/>`,
identités relues sur la forge ; `team-publish` et `team-promote` en sont sortis
de même — phase 2 + L6 phase 2 —, vérifié le 2026-09-12 : `triggers {}` et
`options {}` absents des deux, tout passe par `properties()`.) ; un vrai secret par site pour le Secret Token (credential +
`withCredentials` avant le `properties()`) ; `FORGE_CRED_KIND` classé optionnel
mais refusé si vide par onze pipelines.

## La chaîne producteur à deux visages (L5 phase 2 — 2026-09-12)

L5 phase 1 avait routé la chaîne **app-request** sur l'autorité de forge. La
chaîne **producteur** — celle qui onboarde une équipe, publie une API et la
promeut de palier en palier — parlait encore Gitea en dur. Phase 2 la route
entièrement, et tranche au passage une question qui n'était pas technique :
**qui crée le dépôt d'équipe, son webhook et sa protection de branche ?**
Réponse, décision utilisateur du 2026-09-12 (« D10 profond », ADR-099) : **le
client**. La chaîne LIT la forge, ouvre des PR/MR et commente — elle ne crée ni
organisation, ni dépôt, ni hook, ni protection, sur **aucun** visage.

La liste `EN_ROUTAGE` de `ci/lint-forge-literals.sh` est désormais **VIDE** : la
porte le dit en toutes lettres, « aucun fichier en routage : **la phase 2 est
close** ».

### Prérequis côté client — la liste unique, deux visages

Trois blocs de prérequis existent, et il faut les lire dans cet ordre : l'accès
à l'**API de la forge** (§ « Le visage de la forge » ci-dessus), le **récepteur**
de webhooks de ce Jenkins (§ « Le récepteur de webhooks » ci-dessus), et
ci-dessous ce qu'il faut **par dépôt d'équipe**. Ce dernier bloc est celui que
D10 a déplacé de la chaîne vers le client.

Pour **chaque** dépôt d'équipe, avant tout onboarding :

1. **Le dépôt, créé VIDE par le client.**
   - Gitea : l'organisation, puis le dépôt.
   - GitLab : le projet du groupe, **privé**, **`merge_method=merge`**. En
     fast-forward ou squash, `merge_commit_sha` est nul et l'apply post-merge
     n'a aucun SHA à checkouter.
2. **Le ou les webhooks vers les récepteurs.**
   - `WEBHOOK_KIND=gwt` : **UN** hook, URL au token partagé.
   - `WEBHOOK_KIND=gitlab` : **DEUX** hooks — `/project/team-publish` et
     `/project/team-promote` —, événements **« Merge request » seulement**. Le
     GitLab Plugin expose une URL **par job** : il faut donc un hook **par
     récepteur**. C'est plus **SERRÉ** que le `gwt`, qui réveillait les deux
     jobs sur toute PR fusionnée et triait plus tard — un gain, **pas** une
     divergence entre visages.
   - Le champ *Secret token* du hook doit porter **la valeur que le JOB attend**
     — globales `TEAM_PUBLISH_WEBHOOK_SECRET` et `TEAM_PROMOTE_WEBHOOK_SECRET`,
     défauts `stoa-team-publish` / `stoa-team-promote`, promote retombant
     d'abord sur le knob publish puis sur son littéral. **Ne JAMAIS poser la
     chaîne vide.** Ce n'est pas encore un secret (littéral en Git, globale
     lisible dans l'UI) : dette ADR-098.
   - ⚠ **Panne MUETTE.** Si la valeur du hook diverge de celle du job, GitLab
     prend un **401** : aucun build, aucun log côté Jenkins. Diagnostic :
     **lire l'historique de livraison du hook côté forge AVANT de suspecter le
     job**. Et le token **authentifie l'appelant**, il n'atteste **pas** le
     payload : l'intégrité reste la confrontation du dépôt réclamé à
     `providers.<env>.yml` (`REPO_AMBIGU`).
3. **La protection de la branche par défaut.**
   - Gitea : **nominative** (push whitelist, patterns de fichiers — ADR-082 §3),
     posée par `scripts/setup-repo-protections.sh`.
   - GitLab **CE** : **par RÔLE** (`push_access_level` / `merge_access_level`
     = 40) — la protection nominative est Premium. Corollaire :
     **le porteur de `FORGE_SECRET` doit être Maintainer** sur le projet pour
     pouvoir y pousser le squelette.
   - Les quatre yeux d'ADR-081 restent portés par cette protection, sous la
     forme que la forge du client sait tenir.

### L'onboarding : la conduite de `team-apply`

`team-apply` lit le dépôt d'équipe par l'autorité de forge (`forge repo_get`) et
se conduit selon **trois états**, plus une garde. Il ne crée plus rien, et il
n'y a plus de jeton `gitea-org-admin` dans Vault.

| État lu | Conduite | Ce que la PR dit |
|---|---|---|
| `repo: ""` dans `providers.<env>.yml` | étape **sautée** — une équipe sans dépôt produit n'est pas un échec (cas réel `payments-team`) | « repo vide dans providers — étape sautée » |
| dépôt **absent** (`EXISTS=0`) | **`REFUS: DEPOT_ABSENT`**, `rc 2`, **rien n'est poussé** | le refus nommé, avec le geste à faire |
| dépôt **vide** (`EMPTY=1`) | squelette ADR-076 poussé sur la **HEAD annoncée par la forge** (`DEFAULT_BRANCH`), à défaut `GIT_BASE` : `clients/_example/` copié tel quel (`apis/`, `applications/`, **`environments.yaml`** — que `seed-governance-chain.sh` relit) plus un `README.md` **généré** | ✅ « vide, squelette poussé sur `<branche>` » |
| dépôt **non vide** | « déjà initialisé, étape sautée » — l'idempotence est **dite** | ✅, avec le lien du dépôt à la forme du visage |

**Un seul commentaire par échec**, sous le marqueur `<!-- team-apply -->`
(`comment_upsert`) : jamais une pile. Sur GitLab, un 404 vaut aussi
« **invisible pour ce jeton** » — le refus le dit lui-même. Et `team-apply` ne
**vérifie pas** la présence du webhook : lister les hooks d'un projet exige
Maintainer, donc le hook est un prérequis **écrit**, pas **contrôlé**.

### Les outils de poste (lab)

Ce que la chaîne ne fait plus, le lab le pose avec des outils **hors chaîne**,
exemptés nommément par `ci/lint-forge-literals.sh` (ils parlent aux API de
création). **Deux d'entre eux** — `setup-team-repos.sh` et
`setup-repo-protections.sh` — gardent un défaut de visage `gitea` et échouent
**BRUYAMMENT** sur le mauvais visage : ils sont joués devant un terminal, pas
par un pipeline. Le troisième, `seed-governance-chain.sh`, **n'en a pas** : son
read-back passe par `forge_api_init`, donc `FORGE_KIND_REQUIS`.

- **`scripts/setup-team-repos.sh <owner>/<repo> [--print] [--no-hook] [--no-protect]`**
  — pré-crée le dépôt d'équipe VIDE, son ou ses webhooks et sa protection, sur
  les **deux** visages, idempotent.
  Knobs : `FORGE_KIND` `GIT_HOST` `FORGE_SECRET` `WEBHOOK_KIND`
  `WEBHOOK_SSL_VERIFY` `GIT_BASE`
  `TEAM_PUBLISH_WEBHOOK_URL` `TEAM_PROMOTE_WEBHOOK_URL`
  `TEAM_PUBLISH_WEBHOOK_SECRET` `TEAM_PROMOTE_WEBHOOK_SECRET`
  `PROTECT_PUSH_WHITELIST`. **`GIT_BASE` ABSENT** signifie « laisser la forge
  attribuer sa propre branche par défaut au dépôt créé » — elle l'annonce dans
  sa réponse, et c'est cette valeur-là qui est relue, jamais un littéral deviné.
  **`WEBHOOK_SSL_VERIFY`** (défaut `true`) porte l'`enable_ssl_verification` du
  hook GitLab : il était **en dur à `false`**, donc désarmé chez tout client
  sans que rien ne le dise (revue finale, 2026-09-12). `--print` l'affiche sur
  la ligne du hook sous le visage `gitlab`.
  Refus nommés : `REPO_REQUIS` `REPO_INVALIDE` `BRANCHE_INVALIDE`
  `BRANCHE_PAR_DEFAUT_INDECIDABLE` `SECRET_FORGE_REQUIS` `FORGE_KIND_INCONNU`
  `WEBHOOK_SSL_VERIFY_INVALIDE`
  `ARGUMENT_INCONNU` `CREATION_ECHEC` `REPO_GET` `HOOK_ECHEC`
  `PROTECTION_ECHEC`. `REPO_INVALIDE` est validé **avant `--print` et avant tout
  réseau** : le nom finit interpolé dans six corps JSON, et un nom forgé y
  injecterait des clés arbitraires sans rien casser de visible. Les corps JSON
  sont construits par `json.dumps`, convention du dépôt — et **tout corps qui
  porte un secret** (les hooks) est ÉCRIT dans un fichier 0600 puis passé par
  `-d @fichier` : `-d "$(…)"` mettait le JSON fini, secret compris, dans l'argv
  de `curl`, que `ps -Aww` lit (revue finale, 2026-09-12).
  **Sur Gitea, un dépôt VIDE ne reçoit pas sa protection tout de suite** : la
  branche par défaut n'existe pas encore, l'outil le DIT (« protection <base> :
  différée (branche absente — dépôt vide) : repasser après le squelette ») et
  **sort 0**. Repasser l'outil après que `team-apply` a poussé le squelette — le
  `OK` final ne promet donc pas « protection posée » dans ce cas-là.
  Le secret requis : Gitea `write:organization,write:repository` ; GitLab un PAT
  `api`, **Owner du groupe** (le groupe lui-même est un prérequis, posé par
  `setup-gitlab-lab.sh`).
- **`scripts/setup-repo-protections.sh`** — la protection **nominative**, Gitea
  **seulement**. Sur un autre visage il refuse `PROTECTION_GITEA_SEULEMENT` et
  renvoie à `setup-team-repos.sh` : il ne pose jamais une protection dégradée
  qui aurait l'air posée.
- **`scripts/seed-governance-chain.sh`** — **exige** `FORGE_KIND`, sans défaut :
  son read-back passe par l'autorité de forge (`forge_api_init` puis
  `forge raw environments.yaml`), qui refuse `FORGE_KIND_REQUIS` sur une valeur
  absente et `FORGE_KIND_INCONNU` sur autre chose que `gitea|gitlab`.

### Le registre des archives, à deux échelles

Le registre générique de la forge — le transport des octets d'une archive de
promotion, `scripts/lib/archive-store.sh` — n'a pas la même **échelle** selon le
visage :

| Visage | Échelle | Knob | Absent ⇒ |
|---|---|---|---|
| Gitea | par **PROPRIÉTAIRE** | `ARCHIVE_STORE_OWNER`, défaut `ci` | — |
| GitLab | par **PROJET** | `ARCHIVE_STORE_PROJECT=<groupe>/<projet>` (au lab `ci/archives`) | **`REFUS: ARCHIVE_STORE_PROJECT_REQUIS`**, avant tout réseau |

`GIT_HOST` y est **requis, sans repli**. `ARCHIVE_STORE_PROJECT` est connue du
poseur (`setup-jenkins-globals.sh`, liste OPTIONNELLES) : absente sous Gitea
c'est l'état normal, absente sous GitLab c'est un refus nommé — jamais un défaut
silencieux. Cette lib porte son **propre** refus `FORGE_KIND_REQUIS` : elle ne
source pas `forge-api.sh` (transport binaire, jamais l'init JSON), et sans ce
refus son `case` aurait été le **dernier** défaut de visage silencieux de toute
la chaîne.

**Registre servi par un object storage : géré, ce n'est plus une limite** (revue
finale, 2026-09-12). Avec `proxy_download=false` — le défaut de GitLab.com et
des installations HA — le `GET` du paquet rend **302** vers une URL **présignée**
au lieu des octets. La lib refusait alors `STORE_HTTP_302 : l'archive pinnée
n'est pas au registre (export jamais poussé ?)` : une panne dure **avec un faux
diagnostic**, sur un registre parfaitement sain. Elle suit désormais **UNE**
redirection et re-lit la `Location` **SANS l'en-tête d'authentification** —
`curl -L` nu aurait livré le jeton de forge à l'hôte de stockage. La sonde
d'existence du `push` emprunte le même chemin, donc « présent derrière un 302 »
reste le no-op idempotent. Au-delà d'une redirection, ou sans `Location`, le
code `3xx` ressort tel quel et le refus le **nomme**. Preuves ⑮/⑯ de
`scripts/test-archive-store.sh`, la seconde requête étant mesurée **sans**
`PRIVATE-TOKEN` ni `Authorization` dans le journal du stub.

### Preuves

| Preuve | Commande | Résultat |
|---|---|---|
| Les verbes, deux visages, mutations champ par champ | `bash scripts/test-forge-api.sh` | **134/134** |
| Les mêmes verbes contre les forges RÉELLES du lab | `bash scripts/test-forge-api-live.sh` | **43/43** (GitLab CE **et** Gitea) |
| Le registre à deux échelles, et la `Location` présignée relue sans auth (⑮/⑯) | `bash scripts/test-archive-store.sh` | **31 PASS / 0** |
| **Le registre générique GitLab, EN DIRECT** (niveau lib, Task 13) | `archive_store_push` / `archive_store_fetch` contre `ci/archives` (GitLab 17.11) | push + rejeu **no-op nommé** + `fetch` aux **octets identiques**, les deux refus joués |
| L'outil de poste, deux visages, et **aucun secret de hook en argv** (faux `curl`) | `bash scripts/test-setup-team-repos.sh` | **14/14** |
| La conduite D10 (⑭), les mutants, les knobs de site | `bash scripts/test-palier-retention.sh` | **141 PASS / 0** |
| Le câblage de `team-apply` | `bash scripts/test-team-apply-wiring.sh` | **108/108** |
| **La chaîne producteur EN DIRECT sur le GitLab CE du lab** | `bash scripts/test-producer-chain-gitlab.sh` | **20/20 sur deux runs consécutifs** du fichier commité `c88353d`, `rc 0`, **8 preuves SKIP** avec leur cause |
| Portes | `ci/lint-forge-literals.sh` · `ci/lint-branch-literals.sh` · `ci/lint-forge-knobs.sh` · `ci/lint-config-knobs.sh` | **10/10** · **11/11** · **5 contrôles** · verte |

**Ce que la matrice GitLab prouve** : le dépôt plateforme est **privé**
(`info/refs` anonyme ⇒ 401 — le vrai cas client) ; `team-request` ouvre une MR
et y commente son plan ; `team-apply` refuse `DEPOT_ABSENT` sur un dépôt non
créé, 404 exact derrière, **rien** de créé ; le même `team-apply` pousse le
squelette dans un projet pré-créé **VIDE** ; `api-request` ouvre une MR sur le
dépôt d'**équipe** et y commente ; le **discriminant** de visage
(`FORGE_KIND=gitea` contre ce GitLab) refuse par nom sur **deux voies** — en
lecture (« la forge REDIRIGE vers …/users/sign_in ») et en écriture (le chemin
`/api/v1` cité) — et n'ouvre **aucune** MR ; un sondage `ps -Aww` sur toute la
fenêtre ne voit **aucun** secret en argv, contrôle positif tenu ; le teardown
est **symétrique** côté forge et côté Vault (404 exacts sur les projets du run,
branches retirées, aucun paquet au registre, KV et policies de l'équipe en 404,
tokens éphémères révoqués, bascule de gateway rendue).
⚠ **Une réserve, et la suite l'imprime** : les objets de **gateway** ne sont
**PAS** supprimés — le mock webMethods n'expose aucune route `DELETE` (**405**,
mesuré au palier 3) et son état est en mémoire, donc **une API `demo-l5gl*`
reste par run**.

Le registre générique de GitLab a donc **une preuve verte en direct**, mais **au
niveau de la lib** : `archive_store_push`/`fetch` de l'arbre contre le vrai
`ci/archives` (Task 13) — le paquet est retrouvé dans le registre du projet, le
rejeu est un no-op nommé, le `fetch` rend des octets identiques, et les deux
refus tombent. Ce qui reste **SKIP**, et c'est la preuve 5.1 de la matrice,
c'est le push d'archive **depuis la CHAÎNE** (`api-promote-export` sous GitLab)
— il dépend de la publication, donc de la limite du mock. La lib est prouvée
contre le vrai registre ; le maillon qui l'appelle ne l'est pas encore.

⚠ **LA LIMITE, écrite en clair : c'est la moitié FORGE qui est prouvée en
direct sur GitLab, pas la moitié GATEWAY.** Les **8 SKIP** sont la publication
(2), l'export (3) et la promotion (3), et leur cause est une **limite du lab**,
pas un défaut de la chaîne : le mock webMethods ne re-sérialise pas
`apiDefinition` (`mocks/webmethods/store.go`, champ `Definition` en `json:"-"`),
donc la relecture **fail-closed** du tag de posture (P3, ADR-093) lit `tags=[]`
et refuse `TAG_UNCONFIRMED`. La publication s'arrête **avant** l'activation ;
sans API active, l'export refuse `EXPORT_REFUSED` (piège `isActive`, ADR-079) et
la promotion `DIGEST_ABSENT`. Ce qui est **quand même** établi : l'API **est**
créée sur la gateway (n=1). La moitié gateway reste prouvée **hors ligne** et
par l'historique du Gitea du lab. Le jour où le mock rend ce champ, les six
preuves se jouent d'elles-mêmes, sans toucher au fichier.

⚠ **Deuxième limite** : la preuve « **deux hooks + Secret Token + fusion réelle
par builds Jenkins** sous le visage `gitlab` » n'est **pas** faite. La matrice
joue les scripts en direct, sur des projets pré-créés avec `--no-hook` : rien
ici ne dit que les récepteurs GitLab de `team-publish` et `team-promote` se
déclenchent réellement. C'est le lot voisin (§ « Le récepteur de webhooks »).

⚠ **Sérialisation** : `test-producer-chain-gitlab.sh` et
`test-app-request-gitlab-live.sh` poussent toutes deux la branche par défaut du
dépôt plateforme du lab. **Ne jamais les lancer en parallèle** — même règle que
les suites `-live` du Gitea. La suite se protège elle-même d'un voisin d'un
autre genre : elle **refuse de jouer** si le dépôt plateforme porte le moindre
webhook (relu sur la forge, **avant** le semis donc avant toute écriture, et
**relu après le teardown**) — sans quoi un merge du run réveillerait le job
`team-apply` du Jenkins du lab en parallèle des scripts, et doublerait les
verdicts.

### Dettes datées du 2026-09-12

- **`team-publish` relit la forge DEUX fois par build** : la garde
  `forge-merge-identity.sh` dans le pipeline, plus la réconciliation §2 du
  script. Geste connu : porter la garde **dans** le script, nourrie de
  `FPR_MERGED_BY` / `FPR_LOGIN`.
- **Le refus arrive APRÈS la pause nominative — deuxième instance.** Sur
  `ci/Jenkinsfile.team-publish`, le `when` passe sur `api/*`, l'`input`
  nominatif s'ouvre, l'humain saisit son mot de passe d'annuaire, et
  `REPO_NON_DECLARE` (`scripts/team-publish.sh:285`) ne refuse **qu'ensuite** —
  même dette que `team-apply`, déjà nommée dans **ADR-098 § Dettes**. Geste
  connu, à arbitrer (il touche le récepteur ET le corps du job) : un stage
  `agent any` de réconciliation dépôt → équipe **avant** l'`input`, motif de
  `provision-apply`.
- **29 knobs de site sont déclarés dans des `environment{}` que le poseur ne
  connaît pas** (`setup-jenkins-globals.sh`) : arbitrage à rendre — les déclarer
  ou les exempter nommément.
- **`scripts/test-p2-posture-producteur.sh` reste hors `lint-ci`** (sa section G
  est live) et porte **une quarantaine** de constats `shellcheck` non traités
  (**42** mesurés le 2026-09-12, `shellcheck -x -f gcc`) — un chiffre qui dérive
  à chaque édition, d'où la date.
- **Les défauts de visage qui subsistent sont tous APRÈS un `forge_api_init`
  réussi, ou dans un outil de poste** (inventaire refait le 2026-09-12 : dire
  « `_forge_auth_mode` est le dernier » était faux). Ce sont
  `_forge_auth_mode` (`scripts/lib/forge-identity.sh`), `forge_web_file_url`
  (`scripts/lib/forge-api.sh`, atteinte après l'init) et `kind()` de
  `scripts/lib/forge-api.py` (`or "gitea"`, atteinte après l'init) — plus les
  deux outils exemptés nommément (Ruling 22). Aucun n'est atteignable **avant**
  le refus `FORGE_KIND_REQUIS` de l'autorité ; tous restent datés.
- **`scripts/api-request.sh` initialise la forge AVANT ses `CHAMP_REQUIS`** :
  l'ordre ne coûte **qu'un message** — `forge_api_init` ne fait **aucun** appel
  réseau (rectifié le 2026-09-12 : « un aller-retour réseau » était faux). Sur
  un job mal configuré, l'opérateur lit `FORGE_KIND_REQUIS` là où il attendait
  `CHAMP_REQUIS`.
- **`scripts/seed-governance-chain.sh:82` met le jeton de forge dans l'argv de
  `git`** (`-c http.extraHeader="$AUTH"`), sous un commentaire qui affirme le
  contraire, et ne refuse `FORGE_KIND` qu'**après** le clone et le push (§④).
  Outil de poste **exempt**, et l'enveloppe L3 `git_base_avec_basic` existe déjà :
  ticket séparé (revue finale, 2026-09-12).
- **`scripts/setup-team-onboard-prereqs.sh:102` minte et stocke encore
  `gitea-org-admin` dans Vault** (et accorde sa policy de lecture) alors que
  ADR-099 dit que plus personne ne le lit. Outil de prérequis du lab, consommé
  par des suites **live** non rejouables ce soir : à retirer **avec sa preuve**
  (revue finale, 2026-09-12).
- **`ci/lint-forge-knobs.sh:89` ne reconnaît que `bash scripts/x.sh` et
  `sh scripts/x.sh`** : une invocation `./scripts/x.sh` ou
  `"$WORKSPACE/scripts/x.sh"` compterait **zéro** couple, en silence. Signalé à
  la session du lot voisin (L6), 2026-09-12.
- **Deux oracles d'ABSENCE seuls** — B.7b de `scripts/test-app-request-a1.sh` et
  la 15e assertion D de `scripts/test-p2-posture-producteur.sh` : verts « pour la
  bonne raison » aujourd'hui, mais un oracle positif manque à chacun (revue
  finale, 2026-09-12).
- **Fragilité S.5 de `scripts/test-forge-api.sh`** : le tag est greppé sur le
  fichier **entier**, commentaires compris — une mention en prose suffirait à le
  verdir (revue finale, 2026-09-12).
- **`setup-team-repos.sh` peut afficher « HEAD annoncée : ? »** juste avant de
  refuser `BRANCHE_PAR_DEFAUT_INDECIDABLE` — le message précède le refus, il ne
  le contredit pas, mais il se lit mal.
- **Le stub de `scripts/test-team-promote-wiring.sh` ne rend pas `html_url`** :
  hors ligne, le lien du commentaire ✅ sort vide. Défaut de harnais, pas de
  livrable.

## Résiduel

- **Le lien entre le Jenkins local et celui du labs n'est pas établi.** Ce sont
  peut-être deux instances distinctes, peut-être la même exposée deux fois : rien
  ne permet de trancher tant que le portail masque l'instance publique.
- `mcp.gostoa.dev` (404) et `status.gostoa.dev` (injoignable) sont cités comme
  actifs — l'un dans CLAUDE.md, l'autre dans le dépôt.
- Les hôtes `dev-wm` / `rec-wm` / `vps-wm.gostoa.dev` cités dans le dépôt ne
  répondent pas (404 ou injoignables) : vestiges de topologies antérieures.
