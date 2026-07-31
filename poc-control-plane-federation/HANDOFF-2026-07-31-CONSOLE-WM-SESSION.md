# HANDOFF — 2026-07-31 : la console wM était inconnectable, et pourquoi le cluster n'est pas la réponse

_Dépôt `stoa-labs`, branche `main`. Session ouverte sur un symptôme d'exploitant
(« je n'arrive pas à me connecter à la console »), close sur un correctif
déployé et deux réserves écrites au spike._

**Ce handoff complète `HANDOFF-2026-07-31-F5-ET-SUITES.md`, il ne le remplace
pas.** Il en corrige en revanche une affirmation de la § 2 (voir § 5 ci-dessous).

## En une phrase

La rotation de répliques qui a porté le data-plane de 85 % à 99,1 % rendait la
**console** inconnectable — deux JVM, une session serveur non partagée — et la
mesure des 99,1 % ne dit rien d'Ignite, qui n'a jamais été activé.

---

## 1. Le symptôme et sa cause

`https://wm.labs.gostoa.dev/apigatewayui/#/login` : la page s'affiche, le login
ne « prend » jamais, l'UI rebondit indéfiniment sur l'écran de connexion.

La chaîne, mesurée et non supposée :

| Maillon | Constat |
|---|---|
| Tunnel | `deploy/bootstrap/edge/cloudflared/config.yaml` routait `wm.labs` vers `wm-apigateway:9072` |
| Service | sélecteur `app=wm-apigateway` → **les deux** pods, `sessionAffinity: None` |
| Session | cookie `API_GW_JSESSIONID`, module d'auth `form` ; logs : `SSO configuration is null or SSO is not enabled` → **rien de partagé entre les deux JVM** |
| **Preuve** | `/proc/net/tcp6` des deux pods : cloudflared (`10.42.2.58`) a des connexions **sur le port 9072 vers les deux répliques** — pod A 3, pod B 1 établie + 6 |
| Effet | logs gateway, en rafale : `Invalid Session. Redirecting the user to /apigatewayui/login` |

Les XHR de la SPA tombaient donc une fois sur deux sur la JVM qui ignorait la
session. **Même famille de cause que les 401 trompeurs du chemin d'écriture**,
déjà traités par le Service `wm-apigateway-admin` (commit `8a7b5cf`) — le
problème avait été résolu pour les pipelines, jamais pour la console.

**Aggravant** : les CronJobs suppriment une réplique toutes les 10 min. Temps de
redémarrage **mesuré deux fois** : 10:30:03 → Ready 10:33:03, et 10:40:0x →
Ready 10:43:40. Soit ~3 à 3,5 min. Une session survivrait au mieux 20 min.

---

## 2. Le correctif — déployé et vérifié

`wm.labs.gostoa.dev` vise désormais `wm-apigateway-admin:9072`, le Service à
réplique unique (`rotation: a`), **qui exposait déjà ce port sous le nom
`console-ui`** : il avait été conçu pour ça, le tunnel ne l'utilisait pas.

Vérifié après synchronisation : ArgoCD `edge-cloudflared` sur la révision
`5155730`, ConfigMap régénéré `cloudflared-config-gm8fthfg89` monté par le
Deployment, deux pods cloudflared remplacés, règle chargée en cluster conforme,
Service admin à **un seul** endpoint Ready.

`wm-api.labs.gostoa.dev` **reste sur le Service réparti** — le data-plane veut
la disponibilité, la console veut la cohérence de session ; les deux usages ont
des besoins opposés et méritent deux cibles.

**Contrepartie assumée, écrite dans le fichier** : la console suit le
redémarrage de `rotation: a` (`:00/:20/:40`) — injoignable ~3,5 min toutes les
20 min (~82 % de disponibilité), session perdue à chaque rotation.

**Déblocage sans le tunnel**, si besoin :
`kubectl port-forward -n wm svc/wm-apigateway-admin 9072:9072` (testé).

---

## 3. Ce que la licence impose vraiment

Le dépôt disait « trial expirée, ~25-30 min ». La mesure précise le mécanisme :
**l'Integration Server s'arrête de lui-même environ 30 min après son
démarrage**, et l'annonce dans son journal dès le boot.

**Les CronJobs ne renouvellent donc rien : ils devancent cette extinction.**
C'est la borne dure qui explique le motif de rotation, et pourquoi un nœud
supplémentaire ne l'allégerait pas — chaque nœud porte le même compte à rebours.

Le détail du fichier de licence n'est pas reproduit ici : il n'apporte rien
d'opérationnel et ce dépôt est public (cf. § 8).

---

## 4. Le cluster — pourquoi non, et ce que j'ai eu tort d'avancer

L'exploitant a proposé un 3ᵉ nœud en cluster avec redémarrages décalés. Position
retenue : **non pour l'instant**, confirmée par lui.

**Ce qui tient** : le compte à rebours de 30 min s'applique à **chaque** nœud.
Un 3ᵉ nœud ne lève pas la contrainte, il l'ajoute une fois de plus. Sans clé
valide, on empile des perfusions.

**Ce que j'ai eu tort de dire** : j'ai présenté le clustering comme une piste
inexplorée et risquée, en objectant un « rééquilibrage Ignite permanent ». C'est
une objection de **raisonnement**, opposée à un spike qui avait déjà levé **par
la mesure** les deux prérequis d'infrastructure : la licence trial tolère
plusieurs instances simultanées, et la découverte Ignite fonctionne de pod à pod
dans k3s, y compris pour des pods créés dynamiquement. L'intuition de
l'exploitant était mieux fondée que je ne l'ai créditée.

**Options écartées, pour mémoire** — étirer le cycle 20 → 25 min (gain réel mais
marginal : ~82 % → ~86 %) ; un proxy à affinité par cookie sur
`API_GW_JSESSIONID` dans le ns `edge` (console joignable en continu, mais une
pièce mobile de plus, et le cookie devrait survivre à Cloudflare Access).

---

## 5. Corrections portées aux documents

Deux textes affirmaient plus que leurs mesures ne permettent :

1. **`SPIKE-wm-repliques-decalees-ignite.md`** — « le rééquilibrage Ignite que je
   redoutais ne se manifeste pas à cette échelle ». Le clustering était
   **désactivé** pendant toute la mesure, et l'est encore ; relu sur l'admin
   REST le 2026-07-31 : `listener={nodeName=…, host=null, port=-1}`. Aucun
   cluster ne tournait, il n'y avait rien à rééquilibrer. Les 99,1 % mesurent la
   **rotation décalée seule**. Le spike gagne aussi une section sur l'inconnue
   « session console », qui n'y figurait nulle part.
2. **`HANDOFF-2026-07-31-F5-ET-SUITES.md` § 2** — même phrase, même correction.

Le fond du spike ne change pas : la rotation décalée bat nettement la
mono-réplique sur le data-plane. Ce qui change, c'est ce qu'on a le droit d'en
conclure sur Ignite — rien.

---

## 6. Reste ouvert

1. **Le login n'a pas été validé de bout en bout par l'agent.** Cloudflare
   Access arrête les requêtes à la périphérie (302 vers
   `stoa-platform.cloudflareaccess.com`) et l'extension navigateur n'était pas
   connectée. La chaîne technique est vérifiée jusqu'à la porte, pas au-delà —
   **à confirmer par l'exploitant**.
2. **L'inconnue qui décide de tout le reste** : le clustering d'API Gateway
   réplique-t-il la **session HTTP de la console** entre les nœuds, ou seulement
   le datastore et les caches ? **Non instruite.** S'il ne la réplique pas,
   activer Ignite ne rendrait pas la console utilisable sur le Service réparti,
   et la parade à réplique unique resterait nécessaire. À vérifier par relecture
   du comportement — se connecter, puis forcer les requêtes suivantes sur
   l'autre nœud — jamais par un code de retour ni par la documentation.
3. **Disponibilité de la console à ~82 %**, acceptée. À rouvrir si plusieurs
   personnes l'utilisent quotidiennement.
4. **La clé de licence** reste le seul vrai verrou. Avec une clé valide : les
   CronJobs disparaissent, les deux répliques tiennent, et la question du
   clustering se pose enfin dans les bons termes.

---

## 7. Mes erreurs de méthode, et ce qu'elles coûtent

Le fil de la session : **je disposais de la bonne intuition très tôt et j'ai
failli la valider avec de mauvaises mesures.**

- **Deux mesures fausses sur `/proc/net/tcp`** alors que le listener wM écoute en
  IPv6 IPv4-mapped : la table était vide, j'ai lu « zéro connexion » et conclu
  que le trafic ne se répartissait pas. C'est en tcp6 que la preuve était.
- **Un discriminant par comptage de logs, sans test de contrôle.** 20 requêtes,
  13 vues sur le pod A, 0 sur le pod B — j'allais en conclure que le Service ne
  répartissait pas. Le contrôle a montré que **le pod B ne journalise pas ce
  motif du tout** : le discriminant était invalide, pas le trafic. Un comptage
  sans contre-épreuve produit une certitude fausse.
- **Des micro-mesures gardées trop longtemps** : un échantillonnage qui rendait
  des connexions du pod B sur le Service admin — impossible par construction,
  puisque ce Service ne sélectionne que `rotation: a`. Résultat écarté, mais
  après y avoir passé du temps.
- **Une objection de raisonnement opposée à une mesure existante** (§ 4).
- **Une question posée à l'exploitant sur la licence** alors que le dépôt portait
  déjà la décision « TRANCHÉ le 2026-07-29 : pas de licence ». J'ai lancé la
  recherche documentaire **en parallèle** de la question au lieu de la lire
  d'abord.

> Une mesure fausse coûte plus cher qu'une absence de mesure : elle clôt
> l'enquête. Les trois premières auraient toutes conclu « le Service ne
> répartit pas », c'est-à-dire l'exact contraire de la réalité.

Ce qui a fini par trancher n'est pas une sonde synthétique mais l'observation du
**vrai client** — les connexions de cloudflared, là où elles étaient.

---

## 8. Ce que ce handoff ne dit PAS, volontairement

Ce dépôt est **public**. Une première version de la § 3 reproduisait les champs
du fichier de licence et les messages d'application de la licence relevés au
démarrage. **Retiré avant publication** : ce niveau de détail n'apporte rien à
l'exploitation, et documenter finement le mécanisme d'application d'un produit
commercial n'a pas sa place dans un dépôt ouvert.

Ce qui reste est la **borne opérationnelle** — extinction ~30 min après
démarrage — parce que sans elle le motif de rotation est incompréhensible.

Rien de ce qui identifie l'installation (numéro de série, identifiant de
runtime) n'a été écrit, ici ni ailleurs dans le dépôt : vérifié le 2026-07-31.

> **Point ouvert pour l'exploitant, hors périmètre de ce handoff.** L'état de
> licence et son contournement sont déjà décrits ailleurs dans le dépôt public
> — `GOAL-socle-vers-gateway-2026-07-28.md` (§ lot 1), les commentaires du
> CronJob côté `stoa`, et une balise d'expiration dans
> `docker-compose.devportal.yml`. Les retirer déborde ce handoff, touche deux
> dépôts et l'historique. **Décision d'exploitant, pas d'agent.**

---

_Socle empirique : `/proc/net/tcp6` des deux pods `wm-apigateway`, logs des
gateways, admin REST `configurations/dataspace`, et l'état ArgoCD après
synchronisation. Commits `5155730` (correctif) et `94d8c52` (réserves au
spike)._
