---
title: "Spike — deux répliques wM 10.15 à redémarrages décalés sur un ES partagé (Ignite)"
type: spike
status: "EXÉCUTÉ et CONCLUANT le 2026-07-30 pour le DATA-PLANE : 99,1 % mesuré contre ~85 % en mono-réplique, par la rotation décalée SEULE — le clustering Ignite n'a jamais été activé. Deux réserves ajoutées le 2026-07-31 : la mesure ne dit rien du rééquilibrage Ignite, et la rotation rend la CONSOLE inutilisable (session non partagée)."
date: 2026-07-30
révisé: 2026-07-31
lié: [GOAL-socle-vers-gateway-2026-07-28, 2026-07-30-f5-bascule-decommission-design]
---

# Spike — répliques décalées, mécanisme Ignite

## Le problème qu'il prétend résoudre

F5 a mesuré, côté public et sur deux cycles, une coupure de **120 à 235 s par
cycle de 20 min** — soit ~85 % de disponibilité. Cause : la licence trial expire
vers 25-30 min, d'où un redémarrage piloté toutes les 20 min, et webMethods met
120-235 s à redevenir invocable (le `/health` remonte ~85 s plus tôt que
l'API — c'est le client qui compte, pas la sonde).

**L'idée :** deux répliques, redémarrées en alternance (A à :00/:20/:40,
B à :10/:30/:50), pour qu'il y en ait toujours une servie.

## Ce qui est ÉTABLI (mesuré le 2026-07-30, pas supposé)

| Fait | Comment |
|---|---|
| **Ignite est bien le mécanisme de clustering** en 10.15 | `config/resources/cluster/pg-cluster.xml` configure un `CacheFactoryProvider` avec `igniteFailureDetectionTimeout`, `igniteSocketTimeout`, `igniteAckTimeout`, `igniteMetricsLogFrequency`. Terracotta n'apparaît nulle part. |
| **Le clustering est actuellement DÉSACTIVÉ** | `configurations/dataspace` → `listener={nodeName=<uuid>, host=null, port=-1}`. Nœud unique. |
| **La configuration est pilotable par l'ADMIN REST** | `GET /rest/apigateway/configurations/dataspace` → **200**. Donc automatisable par la chaîne F4 (`labctl`, identité de pod, Vault) — **aucune étape console obligatoire**. C'est ce qui rend ce spike compatible avec la doctrine du dépôt. |
| **La valeur est une map SÉRIALISÉE EN CHAÎNE, pas du JSON** | `{"listener.active":"{listener={nodeName=…, host=null, port=-1}, insecureTrustManager=false}"}` — la valeur est une *string*. Même classe de piège que les shapes Teams du spike F4 (`assetType` obligatoire, UUID exigés) : écrire du JSON imbriqué rendrait probablement 200 **sans effet**. À vérifier par relecture, jamais au code de retour. |
| Endpoint `/clusterConfigurations` | **404** — n'existe pas. La configuration passe par `configurations/dataspace`. |

## Deux inconnues LEVÉES par un test antérieur de l'exploitant

Rapporté le 2026-07-30 : un cluster monté **via le scaling Kubernetes**, deux
pods fixes plus des nœuds dynamiques ajoutés par la montée en charge.

### 1. ~~La licence trial tolère-t-elle deux instances ?~~ → **OUI**

Plusieurs instances ont tourné simultanément. Ce qui pouvait clore le spike ne
le clôt pas.

### 2. ~~La découverte Ignite fonctionne-t-elle de pod à pod dans k3s ?~~ → **OUI**

Et mieux que supposé : **les nouveaux pods s'intègrent au cluster**, y compris
ceux créés dynamiquement par la montée en charge. La découverte encaisse donc
des IP changeantes.

**Correction d'une spéculation de cette note.** Une version antérieure avançait
qu'il faudrait « probablement passer de `Deployment` à `StatefulSet` » pour
obtenir des noms stables. La mesure de l'exploitant dit le contraire : des pods
éphémères rejoignent le cluster. Le `Deployment` peut donc suffire — hypothèse
écartée par une mesure, pas par un raisonnement.

## L'UNIQUE question qui reste

### 3. La rotation de topologie coûte-t-elle plus que le trou qu'elle supprime ?

C'est désormais le seul sujet — et c'est celui que le test antérieur **n'a pas
couvert**, l'exploitant l'ayant explicitement noté : son cluster avait des
nœuds qui *rejoignaient* (montée en charge), jamais un nœud qui **part et
revient toutes les 10 minutes**.

La différence n'est pas de degré. Un ajout de nœud est un événement ponctuel
que le cluster absorbe ; une rotation permanente signifie qu'à tout instant un
nœud est en train de partir, d'être détecté absent
(`igniteFailureDetectionTimeout: 30000`, soit ~30 s), ou de rejoindre — avec le
rééquilibrage de cache que cela implique.

> Il reste parfaitement possible que deux nœuds en rotation permanente servent
> **moins bien** qu'un nœud seul avec son trou de 120-235 s toutes les 20 min.

C'est l'hypothèse à réfuter, pas à espérer.

**Ce qui rend la mesure peu coûteuse :** les deux prérequis étant levés, il ne
reste qu'à porter les répliques à 2, décaler les redémarrages (A à :00/:20/:40,
B à :10/:30/:50) et rejouer la sonde publique de F5. Aucune inconnue
d'infrastructure ne s'interpose.

## RÉSULTAT — mesuré le 2026-07-30, 20:07→21:11 UTC

**99,1 % de disponibilité sur 63 min**, contre **~85 %** en mono-réplique.

| | Mono-réplique | Rotation décalée |
|---|---|---|
| Coupure par cycle | **120–235 s** | **≤ 5 s** |
| Disponibilité | ~85 % | **99,1 %** |
| Total non-200 | ~355 s sur 36 min | **35 s sur 63 min** |
| Codes | 503 (340 s) · 500 (10 s) · 000 (5 s) | **500 seulement** |

Sept rotations observées, une toutes les 10 min, alternant A et B :
20:10 · 20:20 · 20:30 · 20:40 · 20:50 · 21:00 · 21:10. **Chacune coûte un
seul échantillon** — la coupure réelle est donc sous la résolution de la
sonde (5 s), et non pas « 5 s » exactement.

**L'hypothèse à réfuter ne l'a pas été** : deux nœuds en rotation permanente
servent nettement mieux qu'un nœud seul.

> **Correction du 2026-07-31 — ce que cette mesure ne dit PAS.** Une version
> antérieure de ce paragraphe concluait « le rééquilibrage Ignite que je
> redoutais ne se manifeste pas à cette échelle ». **Cette phrase affirmait plus
> que la mesure ne permet.** Le clustering était désactivé pendant toute la
> mesure — et l'est toujours ; relu sur l'admin REST le 2026-07-31 :
>
> ```
> listener.active = {listener={nodeName=23a5db7f-…, host=null, port=-1}, …}
> ```
>
> `host=null, port=-1` : nœud unique. Aucun cluster ne tournait, il n'y avait
> donc rien à rééquilibrer. **Les 99,1 % mesurent le gain de la ROTATION
> DÉCALÉE seule, pas celui d'Ignite.** La question du § 3 — « la rotation de
> topologie coûte-t-elle plus que le trou qu'elle supprime ? » — reste donc
> ouverte pour un cluster réellement activé : elle n'a pas été tranchée, elle
> a été contournée. Ce qui est acquis, et c'est déjà beaucoup, c'est qu'on n'a
> **pas besoin** d'Ignite pour le data-plane.

Authenticité de la mesure vérifiée : les deux pods portent des âges
différents (4 min et 14 min), les Jobs alternent bien `b, a, b, a, b, a`, et
le Service expose deux endpoints. Ce n'est pas une réplique morte dont
l'autre ne tournerait jamais.

### Ce qui change de nature, et qu'il faut savoir

Le code d'erreur passe de **503** à **500**. En mono-réplique, Caddy rendait
son `handle_errors` pendant 2-4 min ; désormais un client malchanceux reçoit
un **500 de webMethods** relayé par Caddy, pendant moins de 5 s. C'est
l'exact comportement anticipé au § 3 — une requête atteint la réplique qui
s'en va. La différence est qu'elle dure des secondes, pas des minutes.

Un client qui réessaie réussit. Mais un client qui ne réessaie pas voit une
erreur applicative, là où il voyait une indisponibilité franche. À garder en
tête si un consommateur réel arrive.

## L'inconnue que ce spike n'a pas vue : la CONSOLE

_Ajouté le 2026-07-31, après une panne de connexion à la console._

Ce spike ne mesure que le **data-plane** — l'invocation d'API. Il ne dit rien
du **control-plane humain**, et la rotation décalée y a un effet inverse de
celui qu'elle a sur le trafic.

**Constaté le 2026-07-31.** La console garde sa session **côté serveur**
(cookie `API_GW_JSESSIONID`, module d'auth `form`, SSO désactivé) : rien n'est
partagé entre les deux JVM. Or cloudflared ouvrait des connexions vers **les
deux** répliques — mesuré sur `/proc/net/tcp6` des deux pods, connexions venant
du pod cloudflared. Les XHR de la SPA tombaient donc une fois sur deux sur la
JVM qui ignorait la session ; le serveur répondait `Invalid Session.
Redirecting the user to /apigatewayui/login` et l'UI rebondissait sans fin sur
`#/login`. **La connexion à la console était impossible.**

Pour le trafic, deux répliques valent mieux qu'une (99,1 % contre 85 %). Pour
la console, deux répliques **sans session partagée** valent moins qu'une : elles
la rendent inutilisable. Les deux usages ont des besoins opposés, comme pour le
chemin d'écriture et son Service `wm-apigateway-admin`.

**Parade appliquée** (contournement, pas correctif) : `wm.labs.gostoa.dev` est
routé vers `wm-apigateway-admin:9072`, réplique unique — voir
`deploy/bootstrap/edge/cloudflared/config.yaml`. Contrepartie assumée : la
console suit le redémarrage de `rotation: a`, ~3,5 min d'indisponibilité toutes
les 20 min, et la session est perdue à chaque redémarrage.

### La question à poser AVANT d'activer le clustering

> **Le clustering d'API Gateway réplique-t-il la session HTTP de la console
> entre les nœuds, ou seulement le datastore et les caches ?**

**Non instruite.** C'est pourtant elle qui décide si le clustering règle le
problème de la console ou seulement celui du cache. S'il ne réplique pas la
session HTTP, activer Ignite **ne rendrait pas** la console utilisable sur le
Service réparti, et la parade à réplique unique resterait nécessaire.

À traiter comme les shapes Teams de F4 : vérifier **par relecture du
comportement** — se connecter, puis forcer les requêtes suivantes sur l'autre
nœud — jamais par un code de retour ni par la documentation.

## Critère d'arrêt proposé

Le spike se juge sur **une seule mesure** : la sonde publique de F5 rejouée
(à 5 s, sur ≥ 2 cycles, sur l'invocation data-plane réelle). Si la
disponibilité mesurée ne dépasse pas franchement les ~85 % actuels, on
abandonne et on documente — l'état actuel est simple, compris et mesuré.

## Ce que ce spike ne doit PAS faire

- **Pas d'improvisation sur la doctrine** : aucun Ingress, aucun NodePort ; les
  ports Ignite restent internes au cluster, et la NetworkPolicy du ns `wm`
  devra être étendue **explicitement**, pas contournée.
- **Pas de bascule publique** tant que la mesure ne montre pas un gain : le nom
  public sert aujourd'hui correctement, à 85 %.
- **Pas de configuration par la console** : tout doit passer par l'admin REST,
  sinon l'état de la gateway cesse de se dériver de Git (ADR-076).

_Socle empirique : inspection du pod `wm-apigateway` en service le 2026-07-30
(arborescence du package, `pg-cluster.xml`, index `configurations` d'ES,
admin REST), et mesures de disponibilité du plan F5, § T8._
