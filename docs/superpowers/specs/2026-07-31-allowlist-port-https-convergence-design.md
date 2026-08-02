---
title: "Allow list du port HTTPS — convergence multi-nœuds (spécification)"
type: spec
status: "M1, M2 et M4 mesurees sur le lab le 2026-07-31 ; D4 revisee — la durabilite est une propriete du produit, seul le trou de propagation a chaud subsiste"
date: 2026-07-31
lié: [adr-075-wm-admin-proxy-multienv, adr-078-livrable-self-service-app-wm1015, 2026-07-29-f4-chaine-publication-design, 2026-07-29-f3-webmethods-cluster-design]
---

# Allow list du port HTTPS — convergence multi-nœuds (spécification)

## Objectif et porte de preuve

Le port HTTPS de la gateway est en **deny-by-default** : une API n'y est
joignable que si elle figure dans l'allow list du listener. Depuis le CI, la
gateway n'est atteignable que par une **VIP** : aucun nœud n'est adressable
individuellement.

La mesure a corrigé la prémisse de départ. Cette allow list **n'est pas** une
configuration de nœud perdue à chaque reconstruction : elle est persistée hors
du nœud et réappliquée au démarrage, ce que le lab a confirmé deux fois (M4).
Le fichier local n'en est qu'une projection.

**Le défaut réel est ailleurs, et il est étroit : rien ne propage l'allow list
vers les nœuds déjà en marche.** Une réplique en fonctionnement au moment de la
publication ne voit la nouvelle API qu'à son prochain redémarrage — jamais, sur
une installation stable où l'on ne redémarre pas une gateway pour publier.

Le lot comble ce trou, et complète la proxification de l'API d'administration
pour que toute action CI sur les API et les applications passe par un point
d'entrée unique et contractualisé.

**Porte :** une API publiée par le CI est joignable **sur tous les nœuds** en
HTTPS à la fin du build, sans qu'aucun composant du CI n'ait connu ni adressé
un nœud individuellement.

**Contre-épreuves :**

1. **Propagation à chaud.** Un nœud **déjà en marche** au moment de la
   publication porte l'API dans son allow list, sans avoir redémarré. C'est
   l'épreuve centrale : c'est exactement ce qui échoue aujourd'hui.
2. **Fail-closed.** Un nœud est empêché de converger. Le build **rougit** et
   **nomme** ce nœud. Il ne rougit pas indéfiniment pour un nœud retiré du
   parc.
3. **Mode opposable.** Sur un listener resté en `include`, le lot **refuse
   d'écrire** et le signale, au lieu d'interdire l'API en croyant l'autoriser.
4. **Deny-by-default opposable.** Une API sans le marqueur d'exposition n'est
   pas dans l'allow list, sur aucun nœud.
5. **Configuration opposable.** Changer le marqueur dans la configuration
   d'environnement suffit à faire converger tous les nœuds sur le nouveau,
   sans reconstruire d'image ni redéployer quoi que ce soit.

*Retirée après M4 :* la durabilité (un nœud recréé retrouve seul son allow
list) et l'élasticité (un nœud ajouté converge). Mesurées comme **propriétés du
produit**, elles restent bonnes à rejouer en garde-fou mais ne sont plus à
construire.

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

Ce tableau transcrit le **Swagger livré**. Une seconde signature de l'écriture
est rapportée en usage (`POST /ports/accessMode`, `listenerKey` dans le corps) :
voir M2. Ce qui est acquis, et suffit au design, c'est que la surface est du
REST JSON et que l'allow list s'écrit **en entier** sous forme de tableau.

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

### Stockage réel de l'allow list, et sémantique du mode (mesuré en séance)

Fichier : `packages/WmRoot/config/listeners.cnf`, bloc `<record name="access">`,
une entrée par listener :

```xml
<record name="HTTPSListener@5543">
  <value name="default">include</value>          <!-- le mode -->
  <record name="nodes" javaclass="com.wm.util.StringSet">
    <list name="elements"><value>carto-probe-api</value></list>
  </record>
</record>
```

Le conteneur s'appelle `nodes` — le même mot que les actions `addNode` /
`deleteNode` du formulaire WmRoot déjà employées dans `port-access.yml`.

**Sémantique du champ `default`, établie par comparaison sur les trois
listeners du lab :**

| Listener | `default` | Entrées | Lecture |
| --- | --- | --- | --- |
| `HTTPListener@5555` | `include` | 0 | ouvert, rien de refusé |
| `HTTPSListener@5543` | `include` | 1 | ouvert, `nodes` = liste de **refus** |
| `HTTPListener@9999` | `exclude` | 595 | fermé, `nodes` = liste d'**autorisation** |

Le port 9999 est le port de diagnostic, livré en deny-by-default avec ses 595
services d'administration autorisés. `include` = *allow by default*,
`exclude` = *deny by default*.

**Piège majeur, à opposer dans l'implémentation.** L'écriture est *la même*
dans les deux modes, mais l'effet est **inverse** : ajouter une API à `nodes`
sur un port en `include` la **refuse**. Un réconciliateur qui écrirait sans
vérifier le mode produirait exactement le contraire de son intention, sans
aucune erreur.

**Un listener HTTPS existe.** `HTTPSListener@5543`, `protocol: HTTPS`,
`enabled: true`, `portAlias: DefaultSecure`, `clientAuth: request`, keystore
`DEFAULT_IS_KEYSTORE`. Il est absent des ports du conteneur et du Service
Kubernetes — il existe donc côté Integration Server sans être **publié** par le
déploiement. C'est une question de plomberie k8s, pas une absence de port.
`listenerKey` = `HTTPSListener@5543` : **M2 est répondue**.

### Ce que devient l'allow list à la reconstruction d'un nœud

La configuration d'un listener vit dans le package **WmRoot**, sur le système
de fichiers de l'Integration Server. Les Deployments du cluster n'ont **aucun
volume**, `strategy: Recreate`, et deux CronJobs décalés suppriment chacun sa
réplique toutes les 20 minutes. Le dépôt avait relevé le même motif pour les
`watt.*` : « ils survivent au restart mais pas au recreate — c'est de la
configuration de NŒUD, hors ES » (adr-073).

**Cette analogie est démentie par la mesure — c'est le résultat central du
cadrage.** L'allow list est **persistée hors du nœud et réappliquée au
démarrage**. Deux répliques neuves l'ont retrouvée seules, sans intervention
(voir M4). La configuration de port n'est donc pas un fichier de nœud comme les
`watt.*` : le fichier n'en est qu'une projection locale, reconstruite au boot.
Cela explique aussi pourquoi elle dispose de sa propre ressource REST `/ports`.

**La durabilité est donc assurée par le produit.** Le lot n'a pas à la
construire.

Ce qui reste, et qui est établi tout aussi nettement : **il n'y a aucune
propagation à chaud**. Une réplique en fonctionnement depuis avant l'écriture
ne l'a jamais reçue — vingt minutes durant, jusqu'à son redémarrage. C'est le
seul trou réel, et c'est celui que le lot doit combler.

**Levier local disponible.** L'Integration Server expose des services
`wm.server.portAccess:*` — `addNodes`, `deleteNode`, `getPort`, `portList`,
`resetPort`, `setType` — relevés dans la liste d'autorisation du port de
diagnostic. Un nœud dispose donc d'une prise locale sur son propre accessMode,
sans passer par le réseau.

Observé aussi : un pod identifié pour une lecture avait disparu dix minutes
plus tard, remplacé par un pod de nom différent — un `exec` sur l'ancien nom
rend `NotFound`. Un pod recréé reçoit une nouvelle identité et une nouvelle
adresse. **Toute liste de nœuds figée est donc fausse en permanence sur le
lab**, ce qui disqualifie tout mécanisme reposant sur un inventaire statique.

### Topologie et chemin CI

- Deux Deployments d'une réplique, `wm-apigateway-{a,b}`, labels
  `app=wm-apigateway` + `rotation=a|b`, anti-affinité stricte, worker-3 exclu.
- Image `localhost:30300/ci/apigateway-trial:10.15` par digest — **un registre
  interne au cluster existe**, aucun initContainer, aucun volume.
- Ports conteneur déclarés : **5555 et 9072 seulement**. Le listener HTTPS
  `HTTPSListener@5543` existe pourtant côté Integration Server (voir plus
  haut) : il est simplement **non publié** par le Deployment et le Service.
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

**Quatre trous mesurés :**

1. Les rôles Ansible appellent `GET /accessProfiles`, `POST /assets/team`
   (scoping d'équipe) et `GET /archive` — **absents du contrat**, donc 404 à
   travers le proxy. Une chaîne complète passée par le proxy tombe aujourd'hui.
2. `POST /archive` (import d'archive, promotion 0-coupure) est **également
   absent du contrat** — et c'est un envoi en **multipart** : le trou le plus
   risqué des quatre, puisqu'il cumule l'absence de déclaration et la surface
   la moins éprouvée du proxy.
3. La création d'API réelle est en **form-multipart** ; le contrat ne déclare
   que du `application/json`. Aucune preuve qu'un multipart traverse le proxy.
4. Le proxy n'est **pas posé sur le cluster** : les job XML y restent en
   `ADMIN_VIA=direct` par défaut. `APIM_PROXY_HOST`/`API`/`BASE` y sont bien
   **définis** en paramètres depuis le commit `91d54e1` de cette même branche —
   mais leur défaut désigne encore `webmethods-real:5555`, hôte docker-compose
   absent du cluster, volontairement laissé ainsi tant que le proxy n'y est pas
   posé : choisir `proxy-oauth2` sans le surcharger y viserait donc toujours un
   hôte inexistant.

**Le contrat croise aussi un conflit d'invariant, pas un trou de couverture.**
`apim_selfservice_app/tasks/rotate-strategy.yml` appelle un `DELETE
/strategies/{id}` que l'invariant « aucun DELETE » de cet ADR interdit au
proxy — devenu l'arbitrage central du lot 1 (ADR-075, § Décision datée —
2026-08-02). Issue retenue : la rotation reste hors proxy, en accès direct ;
l'appel est couvert par une dérogation nommée et motivée dans
`ci/lint-contrat-proxy.py`, jamais par une déclaration au contrat.

### L'existant côté allow list n'a jamais tourné

`tasks/port-access.yml` (lecture → `addNode` idempotent → relecture fail-closed
`PORT_ALLOWLIST_CONFIRMED`) est branché après l'`activate`, mais en opt-in
`apim_ss_port_manage: false`. Grep exhaustif sur les Jenkinsfile, job XML,
scripts et manifestes : **zéro activation**. Son défaut vise `HTTPListener@5555`
(HTTP). Il n'y a donc rien à migrer, seulement à remplacer.

## Décisions (avec alternatives écartées)

### D1 — Surface : `accessMode` en REST, pas le formulaire WmRoot

Le geste passe par la ressource `accessMode` de l'admin REST — sa signature
exacte est l'objet de M2, et n'engage que l'implémentation du réconciliateur.
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
ni `PUT /ports/disable`, ni l'écriture de l'`accessMode` quelle que soit sa
signature (M2). Le seul écrivain de
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

### D4 — Rafraîchissement local périodique, pour la seule propagation à chaud

*Révisée après M4.* Le motif d'origine — la durabilité — est tombé : le produit
réapplique la configuration au démarrage. Ce qui reste est plus étroit, et la
décision se réduit en conséquence.

Un service IS `stoa.ports:refresh`, livré dans un package custom, tourne sur
**chaque nœud par construction**. À chaque passage il lit la configuration
(D3.1), puis, pour chaque règle, les API portant le tag qu'elle désigne — le
tout via l'admin REST **local** — calcule l'allow list attendue du listener
visé, la compare à l'`accessMode` local et applique l'écart, en s'appuyant sur
les services `wm.server.portAccess:*` déjà présents.

**Ce qu'il ne fait plus.** Pas d'exécution au démarrage : l'initialisation du
nœud s'en charge déjà, et mieux. Le service ne comble que l'intervalle entre
une publication et le prochain redémarrage — intervalle pendant lequel un nœud
en marche sert du trafic sans connaître la nouvelle API.

**Garde-fou tenant à la sémantique du mode.** Le service **vérifie que le
listener visé est en `exclude`** avant toute écriture, et s'abstient sinon en
publiant une erreur dans le registre (D5). Sur un port en `include`, la même
écriture *refuserait* l'API au lieu de l'autoriser : c'est un fail-open
silencieux, et c'est le défaut le plus dangereux de tout le lot.

La période gouverne directement l'attente du build (D5) : ordre de grandeur
retenu, la minute — à calibrer au plan contre le coût des lectures
d'administration répétées sur chaque nœud.

*Écarté :* ne rien faire et laisser le redémarrage propager. C'est ce qui se
passe aujourd'hui, et c'est intenable : la fenêtre d'incohérence dure jusqu'au
prochain redémarrage du nœud — indéfiniment sur une installation stable, où
l'on ne redémarre pas une gateway pour publier une API.

#### D4.1 — Projection totale, jamais d'ajout incrémental

`AccessMode` porte `services[]` **en entier** : l'écriture est un
read-modify-write, motif que le dépôt pratique déjà dans `is-mtls-setup.yml`
pour `clientAuth` (lecture, modification, réécriture du record complet,
relecture fail-closed).

Un ajout incrémental — lire la liste, y insérer l'API du build, réécrire le
tout — est sujet aux **mises à jour perdues** : deux publications concurrentes
lisent le même état, chacune ajoute la sienne, la seconde écriture efface la
première sans que rien ne le signale. Le défaut est silencieux, et il se
multiplie par le nombre de nœuds.

Le réconciliateur ne complète donc jamais une liste lue : il **calcule la liste
entière attendue** depuis la requête par tag, qui fait autorité, et écrit cet
état complet. L'écriture est idempotente, et une mise à jour perdue par une
écriture concurrente est réparée au passage suivant sans intervention.

Corollaire opposable : le réconciliateur n'écrit **jamais** une liste dérivée
d'une lecture incomplète. Toute erreur pendant le calcul interrompt le passage
et laisse l'état en place (D3.1) — sans quoi un incident de lecture purgerait
l'allow list et rendrait toutes les API injoignables d'un coup.

*Écarté :* le fan-out actif, où un service IS appelle chaque nœud pour y écrire
et relire. Il exige trois choses qui n'existent nulle part : un inventaire de
nœuds à jour (impossible sur le lab, où les IP changent tous les cycles), des
identifiants d'administration utilisables de nœud à nœud, et l'ouverture de
flux inter-nœuds — que la VIP est précisément censée masquer.

*Écarté :* l'URL interne du nœud passée **en paramètre** de l'API proxifiée, le
CI appelant le proxy une fois par nœud. C'est la variante la plus directe, et
elle a été proposée. Elle ouvre cependant une relayabilité vers une URL
arbitraire, empruntant les identifiants sortants de la gateway, sur la surface
la plus sensible du système : la forme même d'une SSRF, à contre-emploi de
l'invariant d'allow-list stricte d'ADR-075. Elle laisse par ailleurs la
durabilité entière — un nœud recréé repart vide. Si elle devait malgré tout
être retenue, la cible ne devrait jamais être une URL libre mais un
**identifiant de nœud** résolu côté serveur contre le registre de D5.

**Note de convergence entre les deux voies.** Une variante « push » demanderait
au stage de *request processing* (`customExtensionRequestProcessing`, livré dans
le package) de résoudre dynamiquement la liste des nœuds — et la seule source
possible de cette liste est le registre d'auto-enregistrement de D5. Le registre
est donc requis dans les deux architectures : il n'engage pas le choix
push/pull, et peut être construit avant que ce choix soit tranché.

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
- **Lot 2 — propagation à chaud de l'allow list.** Le package `StoaPorts`, le
  rafraîchissement local, le registre, le tag, l'image dérivée, l'étape CI
  d'attente.

Chacun mérite son propre plan d'implémentation.

**Premier geste du lot 2, avant toute construction :** activer le clustering
Ignite avec découverte Kubernetes (M5) et mesurer s'il propage l'allow list aux
nœuds en marche. Le lot 2 tel que décrit ci-dessus n'a de raison d'être que si
cette mesure est négative.

**Le lot 2 a nettement rétréci après M4.** La durabilité et l'élasticité
sortent du périmètre — le produit les assure. Ne reste que la fenêtre entre une
publication et le prochain redémarrage de chaque nœud. Avant d'écrire le plan
du lot 2, il vaut donc la peine de vérifier s'il existe déjà, côté produit, un
geste de rechargement de la configuration de port sur un nœud en marche : le
lot se réduirait alors à l'appeler partout et à en prouver l'effet, sans
package custom ni image dérivée.

## Mesures

### M1 — RÉPONDUE le 2026-07-31 : l'entrée est un nom d'API

Une API ajoutée à l'allow list du port HTTPS depuis la console apparaît dans
`listeners.cnf` sous la forme d'un **nom d'API nu** :

```xml
<record name="HTTPSListener@5543">
  <record name="nodes"><list name="elements">
    <value>carto-probe-api</value>
```

à comparer aux entrées du port de diagnostic 9999, qui sont des services IS
(`wm.server.query:getServerPaths`). **Les deux formes coexistent dans la même
structure**, selon la nature du port : services IS pour un listener
d'administration, noms d'API pour un port API Gateway.

**Conséquences.** L'allow list par API existe bel et bien sur cette surface :
le lot 2 garde tout son périmètre. Et l'affirmation d'ADR-078 selon laquelle
« le port REJETTE les URLs data-plane, l'entrée est un `folder:service` » ne
vaut **que** pour la surface WmRoot d'administration : elle a été indûment
généralisée. Il n'y a aucun mapping API → service IS à construire.

### M2 — RÉPONDUE : `listenerKey = HTTPSListener@5543`

Relevé dans `listeners.cnf`. Le listener HTTPS existe, activé, avec keystore.

Reste ouvert le seul point de forme, sans effet sur le design puisque
l'écriture est interne au réconciliateur — deux signatures candidates, chacune
cohérente en elle-même :

| | Chemin | Verbe | Corps |
| --- | --- | --- | --- |
| **A** — Swagger livré | `/ports/{listenerKey}/accessMode` | `PUT` | `{ accessMode, services[] }` |
| **B** — usage rapporté | `/ports/accessMode` | `POST` | `{ listenerKey, services[] }` |

Elles ne se contredisent pas : dans B le chemin ne porte aucun segment
`listenerKey`, il est donc normal qu'il figure dans le corps. wM 10.15 diverge
de son propre Swagger assez souvent pour qu'on ne tranche pas sur lecture seule,
et les deux formes peuvent coexister selon le niveau de fix pack.

*Méthode retenue pour trancher, si le besoin s'en fait sentir :* observer la
requête émise par la console dans l'onglet réseau. Aucun jeton Vault n'est
requis, la session de console porte l'appel.

### M4 — RÉPONDUE le 2026-07-31 : oui, restaurée au démarrage

Écriture unique par la console vers 15:18 sur la réplique `a`, puis **plus
aucune intervention** — confirmé par l'opérateur. Observation passive des deux
rotations suivantes :

| Réplique | Pod recréé | Entrée au démarrage | Entrée ensuite |
| --- | --- | --- | --- |
| `b` | 15:30:04 | absente | **présente** ~2 min après |
| `a` | 15:40:03 | absente | **présente** ~4 min après |

Deux pods neufs, dont un (`b`) qui **n'avait jamais porté l'entrée**, la
retrouvent seuls. La conclusion ne souffre pas d'alternative : la configuration
est persistée hors du nœud et réappliquée à l'initialisation, avec un délai qui
suit le temps de démarrage de l'Integration Server.

**Ce que cela retire au lot.** D4 perd sa justification par la durabilité : le
produit l'assure déjà. Un réconciliateur planifié n'est plus nécessaire *pour
qu'un nœud reconstruit ou ajouté converge* — il converge tout seul.

**Ce que cela laisse.** La propagation à chaud, et elle seule. La réplique `b`
est restée vingt minutes sans l'entrée alors qu'elle tournait, jusqu'à son
redémarrage. Aucun rafraîchissement périodique n'a été observé — la rotation du
lab empêche d'observer au-delà de vingt minutes, ce qui borne l'affirmation.

**Conséquence sur la porte de preuve.** La contre-épreuve 1 (durabilité) n'est
plus une exigence du lot mais une **propriété du produit** : elle reste bonne à
rejouer en garde-fou, pas à construire.

**Conduite à tenir quelle que soit l'issue :** ne jamais conclure sur le code de
retour. Ce produit rend des **200 qui ne font rien** quand un champ requis
manque — le dépôt en a déjà fait les frais sur d'autres ressources. Seule la
**relecture** de l'`accessMode` fait preuve, conformément au fail-closed déjà
en vigueur.

### M5 — le produit sait-il recharger à chaud ? Sondé le 2026-07-31

**Il n'existe aucun endpoint générique de rechargement.** Sur l'ensemble des
dix-neuf Swaggers livrés, la recherche des chemins contenant
`refresh|reload|sync|restore|apply|cluster` ne rend que deux résultats :
`/strategies/{strategyId}/refreshCredentials` (sans rapport) et **`/is/cluster`**.

**Mais le produit sait se mettre en cluster, et il sait le faire dans
Kubernetes.** `GET`/`PUT /is/cluster` portent un `ClusterInfo` :

```json
{ "clusterAware": true, "clusterName": "…", "pendingRestart": false,
  "actionOnStartupError": "standalone",
  "Ignite": { "discoveryPort": "10100", "communicationPort": "10200",
              "hostnames": "…", "portRange": 0,
              "k8sNamespace": null, "k8sServiceName": null } }
```

`k8sNamespace` et `k8sServiceName` sont décrits comme « the Kubernetes
namespace / service name if the API Gateway cluster is deployed to a Kubernetes
cluster ». La topologie du lab est exactement celle-là, et le Service
`wm-apigateway` (sélecteur `app: wm-apigateway`, donc les deux répliques) est
le `k8sServiceName` naturel. `pendingRestart` indique que le réglage prend
effet au redémarrage — ce que la rotation `*/20` fournit gratuitement.

**Prérequis mesurés, tous identifiés :**

1. Les pods wM tournent sous la ServiceAccount **`default`**. Vérifié par
   `kubectl auth can-i` : elle n'a **aucun droit** sur `endpoints`, `pods` ni
   `services` dans le namespace `wm`. La découverte Ignite par Kubernetes lit
   les endpoints d'un Service : il faut donc une SA dédiée, un Role et un
   binding.
2. Le seul Role du namespace est `wm-restarter` (`pods: list,
   deletecollection`), qui sert les CronJobs — sans rapport.
3. `serviceAccountName` doit être posé sur les deux Deployments, **qui vivent
   dans le dépôt `stoa`**, pas ici.
4. Les ports de découverte et de communication ne sont pas déclarés
   (le conteneur n'expose que 5555 et 9072). Aucune NetworkPolicy ne restreint
   les pods de la gateway, mais l'absence d'interdiction n'est pas une mesure.

**L'inconnue qui décide de tout.** Le clustering Ignite partage les caches et
la session. **Rien n'établit qu'il propage la configuration de port** — celle-ci
est appliquée par API Gateway à l'Integration Server, ce qui est une autre
couche. Cela se mesure après activation, et pas avant.

**Deux risques à porter au dossier.** Le cache distribué paraît être une
fonction sous licence (`wm.server.query:isDistributedCacheLicensed` figure
parmi les services de l'IS) : sur un trial, c'est un verrou plausible, et le
dépôt notait déjà la licence comme « le seul vrai verrou ». Par ailleurs la
rotation décalée ferait entrer et sortir un membre toutes les dix minutes ; le
coût du rééquilibrage Ignite est explicitement noté comme non instruit dans
`SPIKE-wm-repliques-decalees-ignite.md`.

**Conséquence pour le lot.** Avant de construire quoi que ce soit, activer le
clustering et mesurer s'il ferme le trou de propagation à chaud. Si oui, le lot
2 devient un réglage plus une preuve — sans package custom, sans image dérivée,
sans registre. Si non, D4 reprend sa place, et l'on saura pourquoi.

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
