# HANDOFF — P4 : le bouquet commun porté par une global policy par cellule

**2026-09-06 · GOAL `posture-par-exposition` · ADR-094 · branche `provision/probe-dev` · NON COMMITTÉ**

---

## Ce qui est livré, et ce qui le prouve

| Épreuve | Résultat |
|---|---|
| `cd labctl && go test ./... && go vet ./...` | **557 ✅ / 0 ❌** (10 assertions neuves), vet propre |
| `bash scripts/test-p4-global-policy.sh` | **38 ✅ / 0 ❌** (A→D), **rejoué à l'identique** |
| `python3 scripts/spike-p4-global-policy.py all` | **35 ✅ / 0 ❌**, 7 verdicts, rejoué |
| `bash scripts/test-p3-tag-plateforme.sh` (non-régression) | 24 ✅ / 0 ❌ |
| `bash scripts/test-p2-posture-producteur.sh` (non-régression) | 67 ✅ / 0 ❌ |
| `make lint-ci` | vert, **sans ligne ajoutée à la dette** |

**La porte du jalon, littéralement :** deux APIs de niveaux différents, **la même rafale de 35 appels** — 429 sur celle de `vh-internet` (quota gouverné 30/min), 200 partout sur celle de `m-internet` (120/min). Contre-épreuve : cellule désactivée, l'appel repasse en 200.

## Fichiers

**Neufs**
- `scripts/spike-p4-global-policy.py` — les 7 spikes (S1→S7), actifs jetables, nettoyage en sortie
- `ansible/roles/apim_global_posture/{defaults,tasks}/…` + `ansible/apim-global-posture-setup.yml` — le play d'amorçage (jour 0, identifiant **Administrateur**)
- `ansible/roles/apim_publish_api/tasks/global-policy.yml` — l'appartenance, côté pipeline
- `labctl/internal/render/posture_common_test.go` — les gardes de la coupure et du quota
- `scripts/test-p4-global-policy.sh` — la matrice
- `adr/adr-094-policies-communes-global-policy-par-cellule.md`

**Modifiés**
- `labctl/internal/render/render.go` — `Quota`, `bundleQuotas`, `commonCarriable`, `Cells()`, `QuotaFor()`, `PosturePolicyName()`, `PostureMemberSentinel`, la coupure dans `Derive`
- `labctl/cmd/labctl/posture.go` — `common_policies` / `per_api_policies` / `quota` / `global_policy` / `policy_prefix` / `member_sentinel`, et le drapeau **`--cells`**
- `ansible/roles/apim_publish_api/tasks/main.yml` — import en **1c**, après le tag, avant l'activation
- `GOAL-posture-par-exposition-2026-09-04.md` — encadré ✅ P4, arbitrage de P5, écart #1 précisé, deux décisions client neuves

## Les trois faits produits qui ont changé la conception en cours de route

1. **Une condition de scope `filterType: API` SANS attribut sélectionne TOUTES les APIs de la gateway.** Pas « aucune » : toutes. Une cellule créée vide au jour 0 aurait appliqué son quota à tout le trafic. D'où la **sentinelle** `__posture_aucune_api__`, posée à la naissance et remise si elle disparaît — mesurée, elle, comme ne sélectionnant rien.

2. **Une `policyAction` n'a AUCUNE identité qu'on puisse écrire.** `POST /policyActions` accepte un `names`, rend 201 — et l'objet relu porte le **nom par défaut de son template** (« Log Invocation », « Traffic Optimization ») ; `descriptions` reste vide. Le premier rôle, qui les indexait par nom, en a laissé **120 orphelines en quatre passages** (nettoyées). D'où : **la policy est l'ancre**, ses actions ne se retrouvent que par `policyEnforcements`, et l'amorçage traite **une cellule à la fois, de bout en bout**.

3. **Le stage `threatProtection` existe côté produit mais `/policies` le REFUSE** (400 `NullPointerException`, deux filtres, deux portées). Sa seule surface est `/administration/threatprotection`, **gateway-wide**. ⇒ l'écart #1 d'ADR-091 est **précisé, pas levé** : le contrôle existe, il n'est pas déclinable par cellule.

## Deux pièges de mesure payés

- **Vert vacant dans le spike lui-même.** Le premier passage de S5 mesurait le refus HTTPS sur l'API que S3 venait de mettre sous quota : le **429 du quota** se lisait comme le refus de protocole. Corrigé par une API dédiée + une base de référence (« l'API répond 200 en clair AVANT toute policy »).
- **Propagation.** Après l'inscription, la première rafale peut passer entièrement : le scope met quelques secondes à mordre. Le harnais attend que la policy morde AVANT de mesurer, sans quoi il conclurait que le quota ne mord pas.

## Ce qu'il faut savoir pour la suite

- **`make lint-ci` et `go test` sont hors ligne** ; les sections C/D-live du harnais exigent `poc-webmethods-real` (:5555) et se **sautent en le disant** si elle est absente. Le lab recycle wM ~23 min : une exécution coupée se rejoue telle quelle.
- **Le play d'amorçage est un préalable d'environnement.** Sans lui, toute publication échoue en `POLICY_COMMUNE_ABSENTE`. Il est idempotent (vérifié : aucune action orpheline au second passage).
- **⚠ La liste des membres n'est pas ramassée.** Supprimer une API ne retire pas son nom du scope de sa cellule (les harnais P3/P4 y ont laissé des noms d'APIs disparues). Inoffensif — un nom sans API ne sélectionne rien, comme la sentinelle — mais c'est une dérive d'INVENTAIRE : la liste finit par ne plus dire qui la cellule protège. Réponse possible : un ramasse-miettes dans le play d'amorçage, qui ne doit **jamais** vider une liste. Non fait, non caché (ADR-094 § Conséquences).
- **Rien n'est committé ni poussé.** Comme après P2 et P3 : le `labctl` du conteneur `poc-jenkins` date du 2026-07-02 et ne connaît ni `posture`, ni `--cells` — un build Jenkins ne peut pas rejouer cette porte tant que gitea n'est pas servi.
- **Deux lectures manquent au proxy d'administration** (`GET /policies`, `GET /apis/{id}/globalPolicies`) pour que le jalon passe par lui chez un client. Aucune écriture nouvelle.

## Restent P5, P6, P7

- **P5** hérite d'un travail **nommé** : l'axe HTTPS lui appartient entièrement (par-API + listener), et il peut réunir application et vérification s'il le veut — une épreuve Go l'oblige à déplacer les deux ensemble.
- **P6** garde sa prémisse tombée (P0, spike B).
- **P7** traversera `approvers.yml`, toujours cassé sur le produit réel (décision client n°2).
