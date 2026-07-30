---
title: "Spike — deux répliques wM 10.15 à redémarrages décalés sur un ES partagé (Ignite)"
type: spike
status: "Cadré le 2026-07-30. DEUX inconnues sur trois levées par un test antérieur de l'exploitant ; il ne reste que le coût de la rotation de topologie."
date: 2026-07-30
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
