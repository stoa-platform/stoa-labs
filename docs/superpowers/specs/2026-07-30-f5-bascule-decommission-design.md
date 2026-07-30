---
title: "F5 — Bascule et décommission (spécification)"
type: spec
status: "Tranché sur les mesures du 2026-07-29/30 ; à valider par la porte et les contre-épreuves"
date: 2026-07-30
lié: [GOAL-socle-vers-gateway-2026-07-28, 2026-07-29-f4-chaine-publication-design, 2026-07-29-f3-webmethods-cluster-design, 2026-07-29-f2-sauvegarde-hors-noeud-design]
---

# F5 — Bascule et décommission (spécification)

## Objectif et porte de preuve

**Porte du GOAL :** « le trafic public est servi par la gateway cluster ; worker-3
ne porte plus que Caddy. »
**Contre-épreuve du GOAL :** « rollback = une ligne de Caddyfile, exercé une fois
avant la décommission définitive. »

La mesure du 2026-07-29/30 requalifie cette porte sur trois points, et cette
spécification les acte plutôt que de les contourner :

1. **Il n'y a pas de « trafic public » à basculer.** L'index
   `gateway_default_analytics_transactionalevents_*` de worker-3 compte **0
   document** : aucune API n'a jamais été invoquée en data-plane. Les seuls
   accès externes tracés sont **29 événements d'admin depuis 3 IP grand public**
   (les sessions console de l'exploitant). Une porte formulée « le trafic est
   servi » serait donc tenue par une gateway qui ne sert rien.
2. **La « migration des ~109 Mo d'ES » n'est pas un sujet.** 91,8 Mo sur 100,1 Mo
   (92 %) sont des logs d'audit dominés par le bruit du cycle de redémarrage
   (`ALIAS_MANAGEMENT UPDATE local`, réécrit à chaque boot). La configuration
   utile tient dans ~8 Mo, dont **7 APIs** (61 ko) qui sont des artefacts de
   spike sans consommateur.
3. **« Rollback = une ligne » devient faux** dès lors que la surface publique
   change de forme (§ D4). Le retour arrière reste **un geste**, mais c'est la
   restauration d'une sauvegarde horodatée, pas une substitution de jeton.

**Porte F5 retenue** — trois affirmations, chacune mesurable :

| # | Affirmation | Mesure |
|---|---|---|
| **P-a** | Le nom public sert une **invocation data-plane réelle** portée par la gateway du cluster | `GET https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts` → **200 + corps JSON du backend** |
| **P-b** | La surface d'admin **cesse** d'être publique | `/rest/apigateway/apis` → **404** (401 aujourd'hui) ; console → 404 ; les mêmes appels depuis un pod du cluster → inchangés |
| **P-c** | worker-3 ne porte plus que Caddy | aucun conteneur `wm-dev-*`, volumes retirés, crons `*/20` et `*/25` déposés |

P-a est la **première invocation data-plane de toute la plateforme**. Elle solde
la dette que F4 avait documentée honnêtement (« nom honnête, aucun backend réel
derrière »).

---

## Terrain (mesuré le 2026-07-29 soir et le 2026-07-30, avant toute écriture)

| Fait | Valeur mesurée | Conséquence |
|---|---|---|
| ClusterIP gateway joignable **depuis l'hôte** worker-3 | `10.43.227.71:5555/rest/apigateway/health` → **200 en 18,7 ms** | **Voie 1 du GOAL acquise** (§ D1) |
| Console via ClusterIP depuis l'hôte | `:9072/apigatewayui/` → 302 | joignable ; sera fermée publiquement (§ D3) |
| ES cluster depuis l'hôte | `10.43.210.198:9200` → **000** (échec de connexion) | NetworkPolicy `wm-elasticsearch-ingress` présente ; indice fort qu'elle mord (§ D10) |
| Forme du chemin data-plane | `/gateway/<apiName>/<version>` (relevé dans `reversemaps`, 7 entrées) | cible des règles Caddy (§ D3) |
| Data-plane cluster déjà routé | `/gateway/accounts-read/1.0.0/accounts` → **500** ; `/ws/accounts-read` → 400 | la route existe, seul le backend manque (§ D5) |
| Surface publique **actuelle** | `/` → 200 · `/rest/apigateway/health` → 200 · `/rest/apigateway/apis` → **401** · `/apigatewayui/` → 302 · `dev-wm-ui` → 302 | l'admin REST wM est **sur l'Internet ouvert** derrière un basic auth |
| ES worker-3 | 106 shards, **100,1 Mo** ; audit 91,8 Mo / 19 413 docs ; `apis` 7 docs / 61 ko ; `lifecycleevents` 11 647 ; **`transactionalevents` 0** | § objectif, points 1 et 2 |
| Les 7 APIs de worker-3 | `stoa-IA---Chat-Completions--GPT-4o-`, `stoa-demo-api2` (inactive), `stoa-fapi-banking`, `stoa-chat-completions-gpt4o`, `stoa-manual-test-1777312098`, `stoa-petstore`, `stoa-demo-petstore` | artefacts de spike (§ D6) |
| APIs du cluster | **`accounts-read` 1.0.0 seule**, `isActive: true`, backend `http://backend-dev.wm.svc.cluster.local:8080/accounts`, chemins `/accounts` et `/accounts/{id}` | § D5 |
| Service `wm-apigateway` | **aucun `clusterIP` dans le manifeste** (`deploy/bootstrap/wm/apigateway/service.yaml`, `origin/main` `fd2f356f`) ; adresse courante allouée dynamiquement | § D2 — risque de casse silencieuse |
| PVC du ns `wm` | `es-data-wm-elasticsearch-0`, 10 Gi, `local-path`, sur worker-4 | § D7 |
| Couverture de la sauvegarde F2 | `backup_pvc_namespaces: [ci]` — le ns `wm` **n'est pas sauvegardé** | § D7 |
| Joignabilité worker-3 → worker-2 | **TCP/22 OK** | chemin d'archive froide direct (§ D8) |
| Coupure du cycle trial (cluster) | **07:20:23 → 07:22:54 = 150 s** par cycle de 20 min → **87,5 % de disponibilité** | le manifeste annonçait « ~15 min de service » : **surestimation d'un facteur 2** (§ D9) |
| Durée des jobs `wm-restarter` | 4 s, 6 s, 9 s | le redémarrage est instantané ; les 150 s sont le **démarrage de wM** |
| Placement | gateway sur worker-5, ES sur worker-4, `wm-restarter` sur worker-3 | anti-affinité worker-3 tenue pour les charges portantes |
| Egress du pod gateway | `https://petstore.swagger.io/v2/store/inventory` → 200 | capacité réelle, **non retenue comme porte** (§ D5) |

**Réserve honnête sur la mesure du cycle trial :** un seul cycle observé (sonde
à 5 s depuis l'hôte worker-3, 25 min). Le plan la rejouera sur au moins deux
cycles avant de graver le chiffre.

---

## Décisions (avec alternatives écartées)

### D1 — Point d'amont : ClusterIP épinglée

Caddy (worker-3) → `<clusterIP wm-apigateway>:5555`. La mesure exigée par le GOAL
(« `curl <clusterIP>:5555/rest/apigateway/health` **depuis l'hôte** worker-3 —
pas depuis un pod ») rend **200 en 18,7 ms**. worker-3 est un nœud du cluster ;
le chemin hôte → ClusterIP est déjà prouvé en service (c'est celui du shim
`registry_config` pour le realm OCI).

**Écartés :**
- **Ingress dans `wm`** — casserait frontalement la contre-épreuve F3 (« aucun
  Ingress dans `wm` », 6/6 refus mesurés). Inutile puisque la voie 1 répond.
- **NodePort sur 5555** — exigerait d'ouvrir 5555 dans ufw sur les IP publiques
  de **tous** les nœuds, c'est-à-dire publier un admin REST webMethods sur
  l'Internet ouvert : exactement le défaut n8n que le rapport cluster dénonce.

### D2 — La ClusterIP est épinglée en Git, sinon la bascule casse en silence

Le Service `wm-apigateway` **ne déclare pas** `clusterIP`. Toute recréation du
Service (suppression/re-sync Argo, changement de ports, renommage) réattribue une
adresse — et le Caddyfile continuerait de pointer l'ancienne : **404/502 publics
sans qu'aucune alerte ne se déclenche**, car rien ne relie les deux artefacts.

**Décision :** PR sur `stoa` posant `clusterIP:` dans
`deploy/bootstrap/wm/apigateway/service.yaml`, avec le commentaire qui dit
*pourquoi* (motif identique à la ClusterIP gitea `10.43.60.211` épinglée au lot 1).
La valeur est **`10.43.227.71` au 2026-07-30**, mais elle est **relue au moment de
la PR** : si le Service a été recréé entre-temps, l'adresse a changé — et épingler
une valeur périmée provoquerait exactement la panne que D2 prévient.
**Prérequis bloquant de la bascule** : pas de bascule avant merge et re-sync.

Ces adresses appartiennent au CIDR de service du cluster (`10.43.0.0/16`), non
routable : les écrire ici ne contrevient pas à la règle « aucune IP en Git », qui
vise les adresses publiques de la flotte (cf. en-tête de `inventory.contabo.ini`,
et la ClusterIP gitea déjà écrite dans le GOAL).

**Écarté :** un nom DNS interne dans le Caddyfile — Caddy tourne au niveau hôte
et ignore CoreDNS, exactement comme containerd. Le shim `/etc/hosts` serait une
seconde liaison mutable à entretenir pour rien.

### D3 — Surface publique : data-plane seul, la porte est l'invocation elle-même

Aujourd'hui `dev-wm.gostoa.dev` publie l'admin REST wM (401) et la console (302).
La contre-épreuve F3 avait mesuré **6/6 refus** pour la gateway du cluster :
basculer Caddy à l'identique **re-publierait** cette surface et annulerait
silencieusement la doctrine §4.1.

**Décision :** publiquement, **`/gateway/*` uniquement**. Tout le reste rend 404.
`dev-wm-ui.gostoa.dev` est fermé explicitement (404), pas supprimé — un bloc
présent qui refuse est mesurable, un bloc absent est ambigu.

**Corollaire :** `/rest/apigateway/health` **n'est pas** publié. La porte de
preuve automatisée porte donc sur **l'invocation data-plane réelle** — ce qui
prouve strictement plus qu'un `/health`. L'accès d'admin humain passe par le
tunnel SSH / `kubectl port-forward` déjà en service.

**Écartés :** garder la console publique (elle est elle-même une porte d'admin :
durcissement en trompe-l'œil) ; la parité avec aujourd'hui (reporterait un défaut
mesuré en le sachant).

### D4 — La bascule est structurelle : le rollback est une restauration, pas une ligne

Le rôle `caddy_cutover` existant fait un `replace` d'un seul jeton
(`localhost:30080` → IP du nouveau cluster). **F5 ne peut pas être cela** : passer
à « data-plane seul » change la *forme* du bloc (des `handle` par chemin, un
fallback 404), pas une valeur.

**Décision :** réutiliser le **pattern** du rôle, pas son `replace` :
sauvegarde horodatée avant écriture · `caddy validate` **avant** rechargement ·
porte vérifiée **depuis le poste de contrôle** (chemin réel d'un client, pas une
boucle locale) · restauration automatique + échec bruyant si la porte rougit.
La forme cible :

```caddyfile
dev-wm.gostoa.dev {
    handle /gateway/* {
        reverse_proxy 10.43.227.71:5555   # valeur épinglée par D2, relue au run
    }
    handle {
        respond 404
    }
    handle_errors {
        respond "gateway en cycle de renouvellement" 503
    }
}

dev-wm-ui.gostoa.dev {
    respond 404
}
```

**Acté par écrit :** la contre-épreuve du GOAL « rollback = une ligne de
Caddyfile » est **corrigée** en « rollback = restauration de la sauvegarde
horodatée, un geste, déjà implémenté ». La propriété qui compte (retour arrière
immédiat et vérifié) est conservée ; la formulation était inexacte.

**Deux portes distinctes, une par sens** — parce qu'un même chemin n'est pas
valide dans les deux configurations :
- **Bascule** : `https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts` → 200.
- **Rollback** : `https://dev-wm.gostoa.dev/rest/apigateway/health` → 200 (la
  configuration d'origine reproxyfie tout vers `localhost:5555`).

Confondre les deux ferait rougir une restauration réussie.

### D5 — Le backend réel est **en cluster** : faire exister `backend-dev`

F4 a publié `accounts-read` avec le backend
`http://backend-dev.wm.svc.cluster.local:8080/accounts` — un nom honnête sans rien
derrière. La route data-plane fonctionne déjà (**500** mesuré : elle passe, le
backend manque).

**Décision :** poser dans le ns `wm` un Deployment + Service `backend-dev`
minimal servant du JSON, ce qui rend `accounts-read` **réellement invocable sans
renommer quoi que ce soit** et ferme mot pour mot la dette documentée de F4.

Contraintes :
- **Aucune image nouvelle depuis Docker Hub.** Réutiliser une image **déjà dans
  le registre Gitea, par digest** (doctrine F3) — `jenkins-go:v1` embarque
  python3 et convient ; le script vit dans un ConfigMap.
- **Le backend répond 200 sur n'importe quel chemin, et journalise le chemin
  reçu.** Raison : wM concatène la ressource à l'URI de l'endpoint, et l'endpoint
  se termine déjà par `/accounts` — le backend pourrait donc recevoir
  `/accounts/accounts`. Plutôt que de deviner, le backend est agnostique et **le
  chemin réellement reçu devient une preuve** consignée.

**Écartés :**
- **`petstore.swagger.io` comme porte** — l'egress est prouvé (200), mais une
  porte qui dépend d'un tiers instable peut rougir pour une raison qui ne dit
  rien de la plateforme. Retenu seulement comme **preuve d'appoint optionnelle**,
  jamais bloquante.
- **Détourner `accounts-read` vers un backend externe** — nom malhonnête (une
  API « accounts » servant des animaleries).

### D6 — Aucune restauration d'état ES : on archive, on ne migre pas

Les 7 APIs de worker-3 sont des artefacts de spike sans consommateur ; 92 % de
l'ES est du bruit d'audit ; aucune transaction n'a jamais eu lieu.

**Décision :** archive froide **conservatoire** (§ D8), et **aucune restauration**
vers le cluster. Restaurer un état ES contournerait précisément la chaîne GitOps
qu'on vient de prouver (ADR-076 : l'état de la gateway se dérive d'un dépôt, pas
d'un `tar`). Si une de ces 7 APIs redevient utile un jour, elle se **republie par
la chaîne F4** — c'est l'intérêt de l'avoir construite.

**Écarté :** snapshot/restore ES worker-3 → cluster (le « travail » attendu par le
GOAL). Il coûterait cher, produirait deux sources de vérité, et livrerait une
configuration dont personne ne peut dire comment elle a été obtenue.

### D7 — Le ns `wm` est sauvegardé **avant** la bascule

`backup_pvc_namespaces` ne couvre que `ci` : le PVC ES du ns `wm` n'a **aucune**
sauvegarde. Or la bascule fait de ce PVC la seule source de vérité de la gateway.

**Décision :** étendre `cluster_backup` (`backup_pvc_namespaces: [ci, wm]`,
fenêtre de synchronisation Argo pour `wm-elasticsearch`), et **jouer un run vert
vers worker-2 avant de toucher Caddy**.

**ES est quiescé pour de bon**, contrairement à Vault : il ne revient pas scellé,
et le pod gateway est de toute façon interrompu toutes les 20 min — la fenêtre ne
coûte aucune indisponibilité qui n'existe pas déjà. `backup_hot_workloads` reste
donc à `statefulset/vault` seul.

### D8 — Décommission complète dans la passe ; l'archive relue est une porte dure

Décision de l'exploitant : `stop` **et** `rm` dans la même passe, worker-3 ne
portant plus que Caddy à la fin.

**Conséquence assumée :** le recouvrement « en secondes » (`docker start`)
disparaît. L'archive froide devient **l'unique filet**, donc :

1. Tar froid des ~100 Mo d'ES Docker (conteneurs arrêtés) → **worker-2 en direct**
   (TCP/22 mesuré OK), empreinte avant/après.
2. **Relecture effective sur worker-2** — l'archive s'ouvre et l'index `apis` y
   est lisible. Une empreinte qui concorde prouve un transfert, pas une archive
   exploitable (leçon F2).
3. **Rien n'est retiré avant que 2 soit vert.** Le `rm` des conteneurs et des
   volumes, puis la dépose du cron root `*/20` et du keepalive hegemon `*/25`,
   viennent après.

**Ordre non négociable :** le **rollback est exercé avant le retrait**. Après
`docker rm`, il n'y a plus de cible vers laquelle revenir — une contre-épreuve
jouée après le retrait serait une fiction.

### D9 — Le cycle trial est assumé, chiffré, et la haute dispo part en spike séparé

**Mesuré : 150 s d'indisponibilité par cycle de 20 min** (87,5 %). Le commentaire
du CronJob (`deploy/bootstrap/wm/apigateway/cronjob.yaml`) annonce « ~15 min de
service par cycle de 20 min » : c'est **faux d'un facteur 2**, et il est corrigé
dans la même PR que D2.

**Décision :** assumer. Caddy rend un **503 explicite** pendant la fenêtre
(`handle_errors`) au lieu d'un 502 brut : la face publique dit ce qui se passe.

**Dette ouverte, hors F5 :** mesurer si deux répliques wM 10.15 à redémarrages
décalés (A à :00/:20/:40, B à :10/:30/:50) tiennent sur un ES partagé, ce qui
donnerait une disponibilité continue. **Rien n'est tenté ici** : le partage d'ES
par deux instances wM exige un vrai clustering (Terracotta/Ignite) non instruit,
et l'improviser juste avant de détruire l'unique autre copie serait exactement la
faute que ce dépôt évite. Spike à part entière.

### D10 — Dettes du GOAL touchées par F5

| Dette | Traitement en F5 |
|---|---|
| Sauvegarde du ns `wm` avant F5 (handoff F4, point 5) | **soldée** — § D7, prérequis bloquant |
| « Le point d'amont de F5 » (3 voies à trancher) | **soldé par la mesure** — § D1, voie 1 |
| Backend fictif d'`accounts-read` (F4, assumé) | **soldée** — § D5 |
| Chiffre faux du cycle trial dans le manifeste | **corrigé** — § D9 |
| Keepalive hegemon `*/25` en doublon (~5 min/h perdues) | **déposé** avec les conteneurs — § D8 |
| Contre-épreuve NetworkPolicy ES écrite sur `wm-elasticsearch.wm.svc` (nom inexistant) | **hors périmètre F5**, mais la mesure apporte un indice : ES est injoignable depuis l'hôte **par IP directe** (donc sans DNS — c'est un refus réseau, pas un NXDOMAIN), alors que la gateway répond depuis le même hôte. La contre-épreuve propre reste à jouer depuis un pod `ci` avec le nom **`elasticsearch.wm.svc:9200`**. |
| `/root/vault-init-ci.txt` sur worker-1 | **hors périmètre** — geste exploitant, inchangé |
| Image `hashicorp/vault:1.18` des pods agents non épinglée | **hors périmètre** |

---

## Preuves à jouer (dans l'ordre)

1. **P1** — PR `stoa` : `clusterIP` épinglée + commentaire du CronJob corrigé.
   Mergée, re-syncée, ClusterIP **inchangée** après re-sync (relecture).
2. **P2** — `cluster_backup` étendu au ns `wm` ; un run vert ; archive du PVC ES
   **lisible sur worker-2**.
3. **P3** — `backend-dev` posé (PR `stoa`) ; depuis un pod : `curl backend-dev.wm.svc:8080/accounts` → 200 ; **chemin reçu consigné**.
4. **P4** — invocation data-plane **interne** :
   `/gateway/accounts-read/1.0.0/accounts` sur la ClusterIP → **200 + JSON**
   (avant de toucher Caddy — on ne débogue pas deux choses à la fois).
5. **P5** — archive froide worker-3 → worker-2, **relue** (§ D8, étapes 1-2).
6. **P6** — **bascule** : porte P-a (invocation via `https://dev-wm.gostoa.dev`)
   et porte P-b (`/rest/apigateway/apis` → 404, console → 404, et les mêmes
   appels depuis un pod → inchangés).
7. **P7** — **contre-épreuve rollback** : restauration → `/rest/apigateway/health`
   public → 200 (Docker sert de nouveau) → re-bascule → P-a de nouveau verte.
8. **P8** — **contre-épreuve de sabotage** : Caddy pointé sur une ClusterIP
   fausse → la porte **rougit** et la restauration automatique joue. Une porte
   qui ne rougit jamais ne prouve rien (leçon F1).
9. **P9** — **décommission** : `stop && rm` conteneurs + volumes, dépose du cron
   root `*/20` et du keepalive `*/25` → porte P-c (`docker ps` sans `wm-dev-*`).
10. **P10** — re-mesure du cycle trial sur **au moins deux cycles** à travers le
    nom public, et relecture de P-a après un redémarrage (la donnée est portée
    par ES, elle doit survivre).

**Garde permanente :** Caddy termine le TLS de **toute la flotte**. À chaque
phase, vérifier qu'un nom non concerné (`dev-gw-k3s.gostoa.dev`) répond comme
avant. Un durcissement de `dev-wm` qui casserait un autre nom serait une
régression, pas une livraison.

---

## Ce que F5 ne fait pas (exclusions explicites)

- **Aucun enregistrement DNS.** Comme F1–F4 : les noms existent déjà et résolvent
  vers worker-3. Le jeton Cloudflare reste enfermé dans l'Infisical mort ; F5 n'en
  a pas besoin.
- **Aucun Ingress, aucun NodePort, aucune règle ufw nouvelle.**
- **Aucune haute disponibilité wM** (§ D9).
- **Aucune restauration d'état ES** (§ D6).
- **Ni `rec-gw` / `rec-kong` / `rec-wm` ni `vps-wm`** — sans enregistrement DNS,
  ils relèvent du jalon G0 du rapport cluster, hors jalons F.
- **Les quatre noms `*-k3s.gostoa.dev`** restent sur `localhost:30080`, intouchés.

---

## Risques

- **Cible Caddy et Service désynchronisés.** Mitigé par D2 (épinglage en Git),
  mais le lien reste conventionnel : rien n'empêche mécaniquement quelqu'un de
  changer l'un sans l'autre. Le commentaire dans les deux fichiers est la seule
  garde ; à assumer.
- **Le 404 public casse un consommateur inconnu.** Mitigé par la mesure : 0
  transaction data-plane, 3 IP d'admin appartenant à l'exploitant. Le risque
  résiduel est un outil non tracé par l'audit ; le rollback y répond.
- **La fenêtre de 150 s peut faire rougir une porte par malchance.** Le plan
  attend explicitement la disponibilité avant chaque assertion (motif F4, étage
  « Attendre la gateway »), au lieu de réessayer à l'aveugle.
- **`rm` sans recouvrement rapide** (choix exploitant). Mitigé par l'archive
  relue comme porte dure, et par le rollback exercé **avant** le retrait.
- **Un seul cycle trial observé.** P10 le rejoue ; si la dispersion est forte, le
  chiffre gravé sera un intervalle, pas un point.

---

*Socle empirique : mesures du 2026-07-29 soir et 2026-07-30 (sonde de
disponibilité à 5 s sur 25 min depuis l'hôte worker-3 ; inventaire ES des deux
gateways ; joignabilité w3→w2 ; surface publique relevée nom par nom), preuves
F1–F4 (`docs/superpowers/plans/2026-07-{28,29}-f*.md`), et `origin/main` de
`stoa` à `fd2f356f`.*
