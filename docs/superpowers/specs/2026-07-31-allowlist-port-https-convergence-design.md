---
title: "Allow list du port HTTPS — convergence multi-nœuds (spécification)"
type: spec
status: "Cadré et mesuré sur le contrat livré ; une mesure bloquante ouverte (M1) avant implémentation"
date: 2026-07-31
lié: [adr-075-wm-admin-proxy-multienv, adr-078-livrable-self-service-app-wm1015, 2026-07-29-f4-chaine-publication-design, 2026-07-29-f3-webmethods-cluster-design]
---

# Allow list du port HTTPS — convergence multi-nœuds (spécification)

## Objectif et porte de preuve

Le port HTTPS de la gateway est en **deny-by-default** : une API n'y est
joignable que si elle figure dans l'allow list du listener. Cette allow list
est de la **configuration de nœud**, pas de l'état partagé — donc à poser sur
chacun des N nœuds, et perdue à chaque reconstruction de nœud. Depuis le CI, la
gateway n'est atteignable que par une **VIP** : aucun nœud n'est adressable
individuellement.

Le lot livre la convergence de cette allow list, et complète la proxification
de l'API d'administration pour que toute action CI sur les API et les
applications passe par un point d'entrée unique et contractualisé.

**Porte :** une API publiée par le CI est joignable **sur tous les nœuds** en
HTTPS à la fin du build, sans qu'aucun composant du CI n'ait connu ni adressé
un nœud individuellement.

**Contre-épreuves :**

1. **Durabilité.** Un nœud est détruit et recréé. Sans nouvelle publication,
   il retrouve seul l'allow list complète. (Sur le lab, la rotation `*/20`
   fournit cette épreuve gratuitement et en continu.)
2. **Élasticité.** Un nœud est ajouté. Il converge sans que le CI, la VIP ou
   un inventaire aient été modifiés.
3. **Fail-closed.** Un nœud est empêché de converger. Le build **rougit** et
   **nomme** ce nœud. Il ne rougit pas indéfiniment pour un nœud retiré du
   parc.
4. **Deny-by-default opposable.** Une API sans le marqueur d'exposition n'est
   pas dans l'allow list, sur aucun nœud.
5. **Configuration opposable.** Changer le marqueur dans la configuration
   d'environnement suffit à faire converger tous les nœuds sur le nouveau,
   sans reconstruire d'image ni redéployer quoi que ce soit.

## Terrain (mesuré le 2026-07-31, sauf indication)

### Le contrat d'administration des ports est du REST JSON

Lu dans le Swagger livré **dans le conteneur** (motif : lire l'endpoint plutôt
que le deviner), `WmAPIGateway/resources/apigatewayservices/APIGatewayPortManagement.json`,
`swagger: 2.0`, `basePath: /rest/apigateway` :

| Opération | Corps |
| --- | --- |
| `GET`/`PUT /ports/{listenerKey}/accessMode` | `AccessMode { accessMode: string, services: [string] }` |
| `GET`/`PUT /ports/{listenerKey}/ipAccessMode` | `IPAccessMode { ipAccessType: string, hostsList: [string] }` |
| `GET`/`POST`/`PUT`/`DELETE /ports` | `Port` (39 champs, dont `accessMode`, `hasAccessList`, `portAlias`, `listenerType`, `ssl`) |
| `PUT /ports/enable`, `/ports/disable`, `GET`/`PUT /ports/primary` | `PortReference { listenerKey, pkg }` |

`listenerKey` est documenté comme identifiant « within the WmRoot package ».

**Correction d'un fait admis.** ADR-078 (§8) affirme que « le REST `/ports`
n'expose pas l'allow-list d'accès du listener », ce qui a motivé le recours au
formulaire WmRoot `security-ports-editaccess.dsp` dans
`ansible/roles/apim_publish_api/tasks/port-access.yml`. **C'est faux pour cette
surface** : `/ports/{listenerKey}/accessMode` existe et est livré. Conséquence
directe : plus de HTML à lire par regex, plus de `form-urlencoded`, plus de
risque CSRF, et le geste devient contractualisable dans un OpenAPI — donc
proxifiable.

### Le point d'extension du fan-out existe

`WmAPIGateway/config/resources/policy-store/policyActionParameters/` livre
`invokeISService/template.json` (`isArray: true`, paramètres `serviceName`,
`runAsUser`, `complyToISSpec`), `customExtensionRequestProcessing`,
`customExtensionResponseProcessing`, `invokeESBParam`, `esbServices`. Une API
de la gateway peut donc invoquer un ou plusieurs services IS custom.

### L'allow list ne survit pas à la reconstruction d'un nœud

La configuration d'un listener vit dans le package **WmRoot**, sur le système
de fichiers de l'Integration Server. Les Deployments du cluster n'ont **aucun
volume** (« l'état vit dans ES »), `strategy: Recreate`, et deux CronJobs
décalés suppriment chacun sa réplique toutes les 20 minutes. Le dépôt avait
déjà relevé le même motif pour les `watt.*` : « ils survivent au restart mais
pas au recreate — c'est de la configuration de NŒUD, hors ES » (adr-073).

Observé en séance : un pod identifié pour une lecture avait disparu dix minutes
plus tard, remplacé par un pod de nom différent — un `exec` sur l'ancien nom
rend `NotFound`. Un pod recréé reçoit une nouvelle identité et une nouvelle
adresse. **Toute liste de nœuds figée est donc fausse en permanence sur le
lab**, ce qui disqualifie tout mécanisme reposant sur un inventaire statique.

### Topologie et chemin CI

- Deux Deployments d'une réplique, `wm-apigateway-{a,b}`, labels
  `app=wm-apigateway` + `rotation=a|b`, anti-affinité stricte, worker-3 exclu.
- Image `localhost:30300/ci/apigateway-trial:10.15` par digest — **un registre
  interne au cluster existe**, aucun initContainer, aucun volume.
- Ports conteneur déclarés : **5555 et 9072 seulement**. Aucun listener HTTPS
  n'existe côté cluster.
- Service `wm-apigateway` (ClusterIP épinglée, `sessionAffinity: None`) répartit
  sur les deux répliques : c'est la « VIP » du chemin CI.
- Service `wm-apigateway-admin` (sélecteur `rotation: a`) épingle les écritures
  sur une réplique unique. Son propre manifeste le qualifie : « ce Service ne
  résout pas l'incohérence — il l'évite. »
- Ignite est **désactivé** (`listener={nodeName=…, host=null, port=-1}`,
  relu le 2026-07-31) : rien n'est répliqué entre JVM hors Elasticsearch.

### État de la proxification (ADR-075)

Livrée en docker-compose : trois APIs sœurs `wm-admin-{dev,rec,int}` et un
self-proxy `wm-admin-self`, contrat OpenAPI en allow-list, aucun `DELETE`, hors
contrat → 404, entrée OAuth2 scopée. Le contrat couvre déjà le cycle de vie des
API (`POST /apis`, `PUT /apis/{id}`, `activate`, `deactivate`, `versions`) et
des applications (`GET`/`POST /applications`, `PUT /applications/{id}/apis`).

**Trois trous mesurés :**

1. Les rôles Ansible appellent `GET /accessProfiles`, `POST /assets/team`
   (scoping d'équipe) et `GET /archive` — **absents du contrat**, donc 404 à
   travers le proxy. Une chaîne complète passée par le proxy tombe aujourd'hui.
2. La création d'API réelle est en **form-multipart** ; le contrat ne déclare
   que du `application/json`. Aucune preuve qu'un multipart traverse le proxy.
3. Le proxy n'est **pas posé sur le cluster** : les job XML y sont en
   `ADMIN_VIA=direct`, et aucun ne définit `APIM_PROXY_BASE` — choisir
   `proxy-oauth2` y viserait `webmethods-real:5555`, qui n'existe pas dans le
   cluster.

### L'existant côté allow list n'a jamais tourné

`tasks/port-access.yml` (lecture → `addNode` idempotent → relecture fail-closed
`PORT_ALLOWLIST_CONFIRMED`) est branché après l'`activate`, mais en opt-in
`apim_ss_port_manage: false`. Grep exhaustif sur les Jenkinsfile, job XML,
scripts et manifestes : **zéro activation**. Son défaut vise `HTTPListener@5555`
(HTTP). Il n'y a donc rien à migrer, seulement à remplacer.

## Décisions (avec alternatives écartées)

### D1 — Surface : `accessMode` en REST, pas le formulaire WmRoot

Le geste passe par `GET`/`PUT /rest/apigateway/ports/{listenerKey}/accessMode`.
`tasks/port-access.yml` devient caduc et sera retiré.

*Écarté :* conserver le formulaire WmRoot. Il impose du parsing HTML par regex,
casse au moindre changement de gabarit, exige une extension CSRF non écrite, et
n'est pas contractualisable dans un OpenAPI — donc non proxifiable.

### D2 — Le lot ne touche que l'allow list

Créer, activer, désactiver, supprimer un port et **poser le mode
deny-by-default** relèvent de la CI d'infrastructure, à la création de
l'environnement. Le certificat serveur n'est pas un prérequis dur de ce lot.
Le listener visé n'est pas figé : il est désigné par la configuration
d'environnement de D3.1, au même titre que le tag.

Le proxy n'expose **aucune écriture** sur la surface ports : ni `DELETE /ports`,
ni `PUT /ports/disable`, ni `PUT /ports/{key}/accessMode`. Le seul écrivain de
l'allow list est le réconciliateur local de chaque nœud (D4) ; le CI n'écrit
jamais un port, il pose un tag et attend la convergence. Cette retenue prolonge
une doctrine déjà écrite : « ce task ne FLIPPE JAMAIS le mode du port (risque de
lockout du data-plane) ».

*Écarté :* créer le listener HTTPS dans ce lot. Cela mêlerait un geste
d'infrastructure à un geste de déploiement d'API, et imposerait un certificat
et une modification des manifestes de deux dépôts.

**Dépendance assumée :** le cluster n'ayant aujourd'hui aucun listener HTTPS,
la preuve de bout en bout du lot est conditionnée à sa fourniture par la chaîne
d'infrastructure. Le mécanisme est indépendant de l'alias visé.

### D3 — L'intention est un tag sur l'API

Le CI pose un tag sur l'API à la création. L'allow list attendue est la
projection des API portant ce tag.

La source de vérité reste donc dans **Elasticsearch** : partagée entre nœuds,
durable à la reconstruction, et lisible par chaque nœud sur son propre
`localhost`. Aucun magasin d'intention supplémentaire n'est introduit.

**Le nom du tag n'est pas figé dans le code.** Il est porté par une
configuration d'environnement, aux côtés du listener visé — les deux répondent
à la même question, « quelles API sur quel port », et le réconciliateur a besoin
des deux. La configuration est une **liste de règles** `{ listenerKey, tag }`,
évaluées indépendamment : le cas courant est une règle unique, mais un
environnement exposant un port interne et un port externe avec des marqueurs
distincts est couvert par la même boucle, sans re-découpage ultérieur.

*Écarté :* « toute API active est autorisée » — plus simple, mais une API
activée hors CI s'auto-autoriserait, ce qui vide le deny-by-default de son sens.
*Écarté :* déclaration dans le dépôt GitOps (ADR-076) — auditable par revue,
mais met un clone Git, des identifiants et un réseau sortant dans un service
Integration Server. *Écarté :* liste explicite portée par le CI à chaque
publish — l'intention ne survivrait pas entre deux builds, et la réconciliation
n'aurait aucune source à relire.

#### D3.1 — Une seule source pour cette configuration, lue par les deux côtés

Deux composants ont besoin du nom du tag : le CI, qui le **pose**, et le
réconciliateur de chaque nœud, qui le **cherche**. S'ils le tiennent de deux
endroits distincts, un écart entre les deux produit une convergence
silencieusement vide — le CI tague, personne ne lit, l'API reste injoignable et
rien ne le signale.

La configuration vit donc en **un seul endroit, adossé à Elasticsearch** —
partagé entre nœuds et durable à la reconstruction, pour les raisons mêmes qui
fondent D3. Le réconciliateur la lit sur son `localhost` ; le CI la lit à
travers le proxy, dont le contrat couvre déjà cette lecture. Un paramètre de job
Jenkins reste possible, mais comme **surcharge de la configuration partagée**,
pas comme valeur parallèle : le CI n'invente jamais un tag que les nœuds
ignorent.

*Écarté :* un réglage étendu de l'Integration Server (`watt.*`). Il vit dans
`server.cnf`, sur le disque du nœud — donc perdu à la reconstruction, exactement
le piège que ce lot existe pour traiter, et déjà relevé dans adr-073. *Écarté :*
un fichier livré dans le package : changer le tag imposerait de reconstruire et
redéployer une image.

**Comportement si la configuration est absente ou illisible :** le
réconciliateur **ne touche pas** à l'allow list et publie une erreur explicite
dans le registre de convergence (D5). Le build rougit en nommant la cause. Ni
purge silencieuse, ni repli sur une valeur codée en dur.

### D4 — Convergence par réconciliation locale, pas par fan-out

Un service IS `stoa.ports:reconcile`, livré dans un package custom, tourne sur
**chaque nœud par construction**. À chaque passage il lit la configuration
(D3.1), puis, pour chaque règle, les API portant le tag qu'elle désigne — le
tout via l'admin REST **local**. Il calcule l'allow list attendue du listener
visé, la compare à l'`accessMode` local et applique l'écart. Il s'exécute **au
démarrage du package** et périodiquement.

Le déclenchement au démarrage n'est pas un raffinement : sans lui, un nœud
recréé sert du trafic en refusant tout jusqu'au premier tick. Sur le lab, la
période doit être nettement inférieure aux 20 minutes de rotation.

La période gouverne directement l'attente du build (D5) : ordre de grandeur
retenu, la minute — à calibrer au plan contre le coût des lectures
d'administration répétées sur chaque nœud.

*Écarté :* le fan-out actif, où un service IS appelle chaque nœud pour y écrire
et relire. Il exige trois choses qui n'existent nulle part : un inventaire de
nœuds à jour (impossible sur le lab, où les IP changent tous les cycles), des
identifiants d'administration utilisables de nœud à nœud, et l'ouverture de
flux inter-nœuds — que la VIP est précisément censée masquer.

### D5 — La preuve du build est un registre de convergence partagé

À la fin de chaque passage, `reconcile` publie son verdict — identité du nœud,
horodatage, liste appliquée — dans un registre **adossé à Elasticsearch**, donc
lisible depuis n'importe quel nœud. Le CI l'interroge **à travers la VIP** et
exige que tous les nœuds enregistrés soient à jour et portent l'API attendue.

Le même registre sert d'**inventaire**, alimenté par auto-enregistrement : un
nœud ajouté s'y déclare seul, un nœud retiré en sort par péremption. Cette
péremption est ce qui empêche un nœud décommissionné de faire rougir tous les
builds à perpétuité.

Le build **attend** donc la convergence au lieu de la provoquer. C'est le prix
assumé de l'absence d'appels inter-nœuds ; il est borné par la période de
réconciliation.

*Écarté :* interroger l'`accessMode` à travers la VIP en répétant les appels
pour « échantillonner » les nœuds. La répartition est sans affinité : c'est une
statistique, pas une preuve.

### D6 — Le proxy est complété, pas dupliqué

Le contrat existant (`wm-admin-proxy.openapi.yaml`) est étendu, en conservant
ses invariants : allow-list de chemins, aucun `DELETE`, hors contrat → 404,
entrée OAuth2 scopée.

Ajouts : `GET /ports`, `GET /ports/{key}`, `GET /ports/{key}/accessMode`
(observabilité), la lecture du registre de convergence, et les trois endpoints
que la chaîne utilise déjà sans les avoir déclarés — `GET /accessProfiles`,
`POST /assets/team`, `GET /archive`.

*Écarté :* un proxy distinct pour la surface ports. Deux contrats à maintenir
et deux barrières d'entrée à prouver, sans bénéfice — la surface est du REST
JSON de même nature.

### D7 — Livraison par image dérivée

Le package `StoaPorts` est embarqué dans une image dérivée poussée sur le
registre interne `localhost:30300`. C'est aussi le modèle en cible : un package
se déploie avec l'installation, donc il est présent sur tout nœud par
construction — ce qui est exactement la propriété dont dépend D4.

## Découpage

Le lot porte deux livrables distincts. Ils sont séquencés, non parallèles :

- **Lot 1 — proxification complète.** Étendre le contrat (D6), prouver que le
  multipart traverse, poser le proxy sur le cluster et basculer les jobs de
  `direct` vers `proxy-oauth2`. Utile seul : il ferme un résidu déjà identifié
  dans `HANDOFF-PROVISIONING-CHAIN.md` (« re-setup propre des proxies
  `wm-admin-*` … aujourd'hui contourné en direct »).
- **Lot 2 — convergence de l'allow list.** Le package `StoaPorts`, la
  réconciliation, le registre, le tag, l'image dérivée, l'étape CI d'attente.

Chacun mérite son propre plan d'implémentation.

## Mesures ouvertes

**M1 — bloquante.** Que contient réellement le champ `services` de
`AccessMode` quand une API est ajoutée à l'allow list depuis la console API
Gateway ? Le schéma nomme le champ `services`, et `listenerKey` est décrit
« within the WmRoot package » ; par ailleurs `port-access.yml` a mesuré, sur la
surface WmRoot, que « le port REJETTE les URLs data-plane (testé) » et n'accepte
que des références `folder:service`.

Deux issues, et elles ne conduisent pas au même lot :

- le champ accepte des identifiants d'API → la spec tient telle quelle ;
- le champ n'accepte que des services IS → l'allow list par API n'existe pas
  sur cette surface. Si l'entrée est commune à toutes les API, il n'y a rien à
  faire à chaque création, seulement à la création de l'environnement, et le
  lot se réduit à sa part infrastructure.

*Protocole :* sur un environnement disposant d'un listener en deny-by-default,
ajouter une API à l'allow list par la console, puis lire
`GET /rest/apigateway/ports/{listenerKey}/accessMode` et consigner le contenu
exact de `services`. **À faire avant d'écrire la moindre ligne.** Requiert un
jeton Vault nominatif (`secret/deploy/{tenant}/wm-admin`).

**M2.** Format exact de `listenerKey` — à relever par `GET /ports` sur un
environnement pourvu d'un listener HTTPS.

**M3.** Porteur, dans Elasticsearch, du registre de convergence (D5) **et** de
la configuration d'environnement (D3.1) : index dédié écrit par le service IS,
ou alias API Gateway. Même arbitrage pour les deux, et il n'est pas neutre —
l'alias est déjà couvert par le contrat du proxy (`GET /alias`), donc lisible
par le CI sans nouvel endpoint, mais il n'est pas conçu pour des écritures
répétées comme celles du registre. Les deux porteurs peuvent différer.

## Tests

- `mocks/webmethods/admin.go` n'implémente ni `/ports` ni `accessMode` : à
  étendre, sans quoi la chaîne CI n'est pas testable sans gateway.
- Newman en sonde de contrat sur le proxy — 401 sans jeton, 404 hors contrat,
  200 sur la lecture du registre — conformément à l'usage du dépôt (Newman
  sonde, Ansible implémente).
- Configuration absente ou illisible : vérifier que l'allow list existante est
  **laissée intacte** et que le registre porte l'erreur. C'est le cas où une
  purge silencieuse rendrait toutes les API injoignables d'un coup.
- Les cinq contre-épreuves de la porte sont rejouables : la rotation `*/20`
  du lab fournit la contre-épreuve de durabilité en continu, sans mise en
  scène.
