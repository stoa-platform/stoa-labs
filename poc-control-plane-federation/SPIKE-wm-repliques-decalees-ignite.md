---
title: "Spike — deux répliques wM 10.15 à redémarrages décalés sur un ES partagé (Ignite)"
type: spike
status: "Cadré sur mesures du 2026-07-30 ; NON exécuté. Trois inconnues nommées, dont une qui peut le clore."
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

## Ce qui reste INCONNU — et l'ordre dans lequel le mesurer

L'ordre compte : la première inconnue peut clore le spike sans écrire une ligne.

### 1. La licence trial tolère-t-elle DEUX instances ? *(bloquant potentiel)*

Non déterminé — aucun `licenseKey.xml` lisible aux emplacements usuels ; la
trial paraît embarquée. Si elle est limitée à un nœud, **le spike s'arrête ici**
et la seule sortie devient une vraie licence.
**À mesurer en premier**, avant tout travail de manifeste.

### 2. La découverte Ignite fonctionne-t-elle de pod à pod dans k3s ?

Ignite utilise par défaut **47500** (découverte) et **47100** (communication),
et son `TcpDiscoveryVmIpFinder` attend une liste d'adresses — or les IP de pods
changent à chaque redémarrage. Deux voies :
- adresses statiques → incompatible avec des pods éphémères ;
- un Service *headless* + noms stables (StatefulSet) → le motif habituel en k8s.

Conséquence de conception : les répliques devraient probablement passer de
`Deployment` à **StatefulSet**, ce qui change aussi le CronJob de redémarrage
(cibler un pod nommé, pas un label).

### 3. LE VRAI RISQUE — la rotation de topologie coûte-t-elle plus que le trou ?

Un nœud Ignite qui **quitte et rejoint le cluster toutes les 10 minutes**
provoque des rééquilibrages de cache. Avec
`igniteFailureDetectionTimeout: 30000`, chaque départ est détecté en ~30 s.

> Il est parfaitement possible que deux nœuds en rotation permanente servent
> **moins bien** qu'un nœud seul avec un trou de 120-235 s toutes les 20 min.

C'est l'hypothèse à réfuter en priorité, pas à espérer. Un spike qui conclut
« ne pas faire » est un spike réussi.

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
