# HANDOFF — Sessions 2026-07-30/31 : F5 fermé, lot 2 terminé, et les suites

_Dépôt `stoa-labs`, branche `main`. Session `/goal F5` puis travaux enchaînés à
la demande. Merges de PR et écritures dans le Caddyfile portés par l'exploitant
— refusés à l'agent, à raison._

**Ce handoff remplace `HANDOFF-2026-07-30-F5-BASCULE.md`**, qui reste valable
pour le détail de F5 lui-même. Celui-ci ajoute tout ce qui a suivi.

## En une phrase

Le nom public est servi par la gateway du cluster, l'admin REST a quitté
l'Internet ouvert, worker-3 ne porte plus que Caddy — et la disponibilité est
passée de **~85 % à 99,1 %** par une rotation de répliques mesurée, pas espérée.

---

## 1. F5 — les trois portes

| Porte | Mesure |
|---|---|
| **P-a** | `https://dev-wm.gostoa.dev/gateway/accounts-read/1.0.0/accounts` → **200** + corps de `backend-dev`. Première invocation data-plane de la plateforme. |
| **P-b** | Les cinq chemins d'admin → **404** (contre `401`/`200`/`302`/`200`/`302`). Et **200 depuis un pod** : retiré du public, pas supprimé. |
| **P-c** | worker-3 : **Caddy et son agent k3s seuls**. |
| Garde flotte | Les **quatre** noms `*-k3s.gostoa.dev/health` → 200, avant et après. |

Relues **après** la décommission : la question n'était pas « a-t-on retiré »
mais « le public dépendait-il de ce qu'on a détruit ».

**Trois sabotages** joués, et le rollback exercé **dans les deux sens**
(automatique après porte rouge, et explicite) **avant** tout retrait — après
`docker rm`, il n'y aurait plus eu de cible.

Détail complet : `docs/superpowers/plans/2026-07-30-f5-bascule-decommission.md`.

---

## 2. Le spike des répliques décalées — CONCLUANT

**99,1 % contre ~85 %**, mesuré sur 63 min (sonde publique à 5 s, invocation
data-plane réelle).

| | Mono-réplique | Rotation décalée |
|---|---|---|
| Coupure par cycle | 120–235 s / 20 min | **< 5 s / 10 min** |
| Disponibilité | ~85 % | **99,1 %** |

Sept rotations observées, chacune coûtant **un seul échantillon** — la coupure
réelle est donc **sous la résolution de la sonde**.

**L'hypothèse posée pour être réfutée ne l'a pas été.** Je craignais que le
rééquilibrage Ignite coûte plus que le trou supprimé ; il ne se manifeste pas à
cette échelle.

**À savoir — le code d'erreur passe de 503 à 500.** Un client malchanceux voit
une **erreur applicative brève** au lieu d'une indisponibilité franche et
longue. Un client qui réessaie réussit ; un client qui ne réessaie pas voit
autre chose qu'avant. Comptera si un consommateur réel arrive.

**Forme retenue** : deux Deployments d'**une** réplique (labels `rotation: a|b`)
et non un Deployment de deux — le CronJob doit cibler UNE réplique, or les noms
de pods sont aléatoires. Chaque `labelSelector` est **scopé** ; sans cela les
deux répliques mourraient ensemble, défaut qui serait passé inaperçu puisque le
service resterait « à peu près » disponible.

Deux prérequis avaient été levés par un **test antérieur de l'exploitant** :
la licence trial accepte plusieurs instances, et des pods **dynamiques**
s'intègrent au cluster Ignite. Cela a démenti ma spéculation qu'un
`StatefulSet` serait nécessaire.

Détail : `SPIKE-wm-repliques-decalees-ignite.md`.

---

## 3. Sécurité — 115 → 28 alertes, zéro critique

Les 8 critiques étaient **toutes des contournements d'authentification** :
`x/crypto` 0.48→0.52 (7 alertes : bypass SSH, contraintes de clés et d'agent,
présence FIDO contournable) et le **fail-open** de `kin-openapi`.

**Piège du bump** : `x/crypto` 0.52 exige Go 1.25, ce qui a relevé la directive
du module — or `hegemon-deploy.yml` épinglait `1.24`. Corrigé en
`go-version-file`, pas en dupliquant la version.

**Les 28 restantes** sont documentées : react-router (14, **non atteignable** —
les apps sont en `<BrowserRouter>`, ni RSC ni SSR), outillage `dev` transitif
amont (vite, js-yaml, babel, esbuild), deux Go apparus au re-scan.

`opentelemetry_sdk` : **non atteignable** (aucun usage de Baggage) et migration
réelle (`shutdown_tracer_provider` supprimé, `runtime` passé en
`experimental_async_runtime`). **Analyse actée dans le `Cargo.toml`**, à faire
avec une chaîne Rust locale.

---

## 4. Six garde-fous qui ne pouvaient pas rougir

C'est le motif structurant de ces sessions. **Aucun n'a été trouvé par une
alerte — tous par diagnostic.**

| Garde | Défaut |
|---|---|
| `wm-elasticsearch` Argo | `OutOfSync` **permanent** (champ immuable) → alerte allumée en continu |
| CI portal / control-plane-ui | `self-hosted` sans runner → **jamais exécutées** |
| E2E | idem — la suite ne tournait plus |
| CI Rust gateway | idem, **plus** un commentaire affirmant que clippy bloquait les merges (faux) |
| `mcp-sdk-smoke` | entrée **requise** omise → mort au setup, alors qu'il annonce attraper 3 incidents nommés |
| CI Python opérateur | `self-hosted` — 6ᵉ occurrence, trouvée par l'audit |

**`CAB-2114` avait vu le motif une fois et corrigé une fois, sans généraliser.**
D'où cinq récidives. L'audit (#2839) donne enfin une **réponse bornée** sur
quatre questions ; deux d'entre elles sont propres.

> Une garantie écrite mais fausse coûte plus cher que son absence, parce
> qu'elle dispense de vérifier.

---

## 5. Reste ouvert

1. **Ajouter le CI Rust aux required checks** — décision de politique de merge,
   qui appartient aux mainteneurs. Le fichier ne ment plus, mais rien ne garde
   clippy aujourd'hui.
2. **`opentelemetry_sdk`** — migration 0.27→0.32 avec chaîne Rust locale.
3. **`e2e-cross-validation.yml`** reste sur `self-hosted` — **légitimement**
   (hors PR gate, exige des services vivants). Ne pas le « corriger » par
   automatisme.
4. **Archive froide de worker-3** sur worker-2 (17 Mo, conservation indéfinie
   décidée) — vérifiable par `ansible/archive-verify.yml`, joué vert **et**
   saboté.
5. **Consommateur réel** : si un client arrive, peser le passage 503 → 500.

---

## 6. Ce que ces sessions ont appris, y compris sur mes erreurs

Le fil n'était pas technique : **mesurer avant d'affirmer**.

Ce qui a marché venait toujours du même geste — exécuter le script avant de le
déployer (`ThreadingHTTPServer` : une connexion tenue faisait expirer 3 appels
sur 3), lire la source plutôt que la signature (`httpx2`, et « only manage
client lifecycle if we created it »), énumérer plutôt que réagir (4 accès
camelCase trouvés d'un coup après 4 tours de CI perdus).

Mes erreurs viennent toutes de l'inverse, et méritent d'être listées :

- un `volumeMode` **annoncé suffisant** sans re-mesurer — il ne l'était pas ;
- un « embouteillage CI » qui était une **impasse structurelle** (0 runner) —
  38 min d'attente sur une prémisse fausse ;
- un `exit 0` lu sur un `| tail` : c'était le code de `tail`, les builds
  échouaient — le piège `pipefail` que j'avais documenté une heure plus tôt ;
- un `git add -A` qui a ramassé un fichier de l'exploitant, parce que j'avais
  supposé être sur `main` ;
- une **IP publique** écrite dans un dépôt qui les interdit, alors que j'avais
  cité cette règle le matin même ;
- une spéculation sur le `StatefulSet`, démentie par une mesure de l'exploitant ;
- 9 **faux positifs** produits par mon propre audit au `grep`, inversés en
  rejouant l'analyse en YAML — une mesure fausse est pire qu'une absence de
  mesure, y compris quand c'est l'audit qui la produit.

_Socle empirique : plan F5 § T0→T8, spike § Résultat, 14 PR mergées sur `stoa`
(#2825 → #2844), et les sondes de disponibilité à 5 s des 2026-07-30 et 31._
