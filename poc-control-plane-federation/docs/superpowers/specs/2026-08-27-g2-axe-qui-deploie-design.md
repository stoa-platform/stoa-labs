# G2 — L'axe manquant : « qui déploie » à côté de « qui approuve »

**Date** : 2026-08-27. **GOAL** : `GOAL-cd-promotion-5-envs-2026-08-26.md`, jalon G2.
**Porte du GOAL** : un membre du groupe du palier déclenche la promotion vers ce palier ;
un membre de l'équipe demandeuse ne le peut pas, **même en connaissant l'URL du job**.
**Contre-épreuves du GOAL** : jeton sans le groupe ⇒ refus ; le demandeur qui approuve
son propre saut ⇒ refus 4-yeux, **rejoué sur les trois nouveaux paliers** (le motif
n'était prouvé qu'en prod).

Modèle copié : GitLab protected environments — `deploy_access_levels` et
`approval_rules` sont deux tableaux **structurellement indépendants** (GOAL §recherche,
3-0). `ApproverGroup` dit qui valide ; rien ne dit qui **porte** le déploiement.

---

## §1 — Ce que le relevé a mesuré (2026-08-27, 7 lecteurs + vérification directe)

1. **Le modèle n'a aucun axe « qui déploie ».** `Gate` = 7 champs
   (`labctl/internal/governance/envchain.go:19-37`, tags json = clés YAML via
   sigs.k8s.io/yaml). `ApproverGroup` n'est évalué qu'à l'**approbation**
   (`handlers_promotions.go:236`, claim `groups` du JWT KC vérifié, refus 403
   `GATE_GROUP_REQUIRED`). Le **dispatch** ne vérifie aucune identité :
   `preflightDispatchGate` (dispatchgate.go:88-140) ne consomme que
   `gate.ITSMCheck` + `deploy.ChangeRef`.

2. **Sur la chaîne self-service (G5), le déployeur est DÉJÀ identifié — mais rien ne
   le compare à une déclaration.** team-promote.sh lie mécaniquement les trois
   identités : le mergeur (réconcilié Gitea authentifié, §2) **doit être** l'identité
   Vault nominative de la pause (`MERGER_MISMATCH`, inconditionnel même sous
   `--allow-self-approval`), et le palier ne s'ouvre que si le token nominatif lit
   `envs/<env>/wm-admin` (`PALIER_FERME`, §7, rétention G4). Ce qui manque : la
   chaîne ne DÉCLARE pas qui peut déployer, et aucun refus nommé ne dit « tu n'es
   pas du groupe déployeur » — le refus effectif est un 403 Vault de capacité,
   illisible comme politique.

3. **`approverGroup` n'est enforced NULLE PART sur la chaîne team-promote** :
   team-promote.sh:364-366 jette le 3ᵉ champ de `env_chain_gate` ;
   api-promote-request.sh:280 l'écrit : « attendu, **pas vérifié** ». Sur cette
   chaîne, l'approbation EST le merge (ADR-081) et son contrôle EST la protection
   de branche (G4) — pas un groupe KC.

4. **Deux annuaires disjoints, déjà documentés dans le gabarit** (environments.yaml:95-105) :
   la claim `groups` KC (approbation, `int-team`/`release-team`) et LDAP→policies
   Vault (secrets/déploiement). G4 a posé le plan par palier
   (`setup-vault-paliers.sh`) : policy `apply-<env>` + AppRole `apply-<env>` pour
   chaque palier **non terminal** (le terminus est exclu par STRUCTURE), et le
   mapping LDAP `apim-apply-<env>` → `apply-<env>` — **inerte : le groupe LDAP
   n'existe pas dans l'annuaire, aucun membre**. Le terminus vit sur le groupe LDAP
   **existant** `apim-operator-prod` → policy `operator-deploy` (membre : oscar).

5. **Qui porte l'apply aujourd'hui, chaîne par chaîne** :
   - team-promote (rec/int/homol) : l'humain de la pause `input` (V_USER == mergeur),
     token Vault nominatif ;
   - gouvernance hors-prod (ci/Jenkinsfile) : AppRole **ci-pipeline** (machine,
     token éphémère, ci/Jenkinsfile:120-127) — le CI n'autorise pas, il exécute ce
     que Git a décidé (ADR-081) ;
   - prod (Jenkinsfile.prod) : identité nominative `VAULT_USER` (mesuré G5 :
     oscar, token_policies=[operator-deploy]) avec repli AppRole « acte non
     imputable » ;
   - `labctl dispatch-gate` standalone (stage de Jenkinsfile.prod) tourne AVANT le
     login Vault : il n'a aucune identité de déployeur à vérifier.

6. **Le 4-yeux est prouvé en prod, pas ailleurs.** Mécanisme KC
   (`SELF_APPROVAL_BLOCKED`) actif sur toute porte `fourEyes` mais la preuve ne
   couvre que prod ; côté pipeline, `promoted_by` vaut `ci` (build-user-vars
   absent) — inertie documentée, aucun faux refus. Le harnais wiring éprouve déjà
   la porte int (cas ⑮).

7. **Le lookup manquant est petit** : `labctl/internal/vault` sait token-file /
   AppRole / ReadKV ; il n'expose pas `lookup-self`. Côté shell, team-promote.sh a
   déjà le header-file Vault (`$TMP/vhdr`) et python3 inline.

---

## §2 — Décisions

**D1 — `deployerGroup` est un champ de `Gate`, annuaire n°2 (LDAP→Vault), et son
enforcement est la policy projetée du token Vault du porteur.**
`approverGroup` reste l'axe KC (« qui valide », vérifié par governance-api sur JWT).
`deployerGroup` est l'axe LDAP→Vault (« qui porte l'apply », vérifié au dispatch sur
le token Vault via `lookup-self`). Deux axes, deux annuaires, **chaque champ épinglé
à son annuaire** — le piège documenté « mauvais annuaire = porte qui ne matche
jamais » devient une conception : on ne peut pas se tromper d'annuaire, chaque champ
n'en connaît qu'un. Raison de fond : au moment du dispatch, la seule identité
vérifiée disponible sur TOUTES les chaînes est le token Vault (nominatif ou
AppRole) ; un jeton KC n'existe pas sur la chaîne team-promote et n'y est pas
fabricable (Dex ≠ creds Vault). On ne crée pas de troisième canal d'identité : on
déclare celui qui existe (ADR-082) et on le rend refusable par NOM.

**D2 — La projection groupe→policy est une table à DEUX familles, fail-closed
au-delà.**
- `apim-apply-<x>` → policy `apply-<x>` (la famille posée par setup-vault-paliers.sh,
  paliers non terminaux) ;
- `apim-operator-<x>` → policy `operator-deploy` (la famille existante du terminus,
  setup-vault-ldap.sh:156) ;
- tout autre nom ⇒ refus `DEPLOYER_GROUP_UNSUPPORTED` — **bruyant**, contrairement à
  `approverGroup` dont le mauvais nom ne matche jamais en silence.
La table vit DEUX fois (Go : `internal/governance` ; shell : `scripts/lib/env-chain.sh`)
— même régime que les deux moteurs (ADR-083), chaque implémentation testée, écart =
bug. Le check accepte la policy dans l'union `policies` + `identity_policies` du
lookup-self : un humain la tient par son groupe LDAP, une machine par ses
`token_policies` — **accorder la policy à un AppRole EST le geste qui déclare la
machine déployeuse** (ADR-082 : ouvrir = un geste de credential, jamais un edit).

**D3 — Trois codes de refus, IDENTIQUES dans les deux moteurs** (symétrie avec
`GATE_GROUP_REQUIRED`) :
- `DEPLOYER_GROUP_REQUIRED` — la porte déclare un groupe, le token n'en porte pas la
  policy projetée ;
- `DEPLOYER_GROUP_UNSUPPORTED` — nom de groupe hors des deux familles (déclaration
  invérifiable par construction) ;
- `DEPLOYER_GROUP_UNVERIFIABLE` — porte déclarée mais identité invérifiable
  (VAULT_ADDR absent, lookup-self en échec) — fail-closed : on ne déploie pas ce
  qu'on ne sait pas vérifier.

**D4 — Sites d'enforcement : les DEUX chemins de dispatch, mécaniquement antérieurs
au verbe** (corollaire ADR-083 : un refus de porte est antérieur au play).
- `team-promote.sh` : nouveau contrôle en tête de §7 (déclaration AVANT rétention :
  d'abord « la chaîne dit qui » via lookup-self, ensuite « ton ticket ouvre-t-il »
  via PALIER_FERME) — avant l'unique site moteur, comme tout le reste.
- `labctl apply-uac` : le preflight de dispatch vérifie `deployerGroup` pour chaque
  env gated+enabled effectivement dispatché (même dérivation que l'ITSM anti-TOCTOU),
  AVANT toute écriture gateway. `labctl dispatch-gate` standalone reste ITSM-only
  (documenté : son stage tourne avant le login Vault, il n'a pas d'identité à
  vérifier — c'est apply-uac qui porte le refus, au moment où l'identité existe).
- governance-api : **ne l'évalue PAS à l'approve** (déployer est un acte de
  dispatch, pas d'approbation — c'est LE point du modèle GitLab) ; il parse, sert
  (`GET /environments`) et matérialise le champ dans l'évidence d'approbation
  (`gate.deployer_group`), pour que la PR/l'audit disent qui devait porter.

**D5 — Le gabarit déclare l'axe sur int, homol, prod ; rec reste sans déclaration.**
```yaml
- to: int,   deployerGroup: apim-apply-int      # + approverGroup int-team, fourEyes
- to: homol, deployerGroup: apim-apply-homol    # + release-team, fourEyes, requirePVRef
- to: prod,  deployerGroup: apim-operator-prod  # + régime complet
```
rec = autonomie du demandeur (décision client n°1, inchangée) : pas de déclaration,
la rétention §7 (PALIER_FERME) reste inconditionnelle. Un palier sans `deployerGroup`
n'est pas sans contrôle — c'est un palier où la rétention de credential est le seul
« qui », comme aujourd'hui. Écrit dans le gabarit à côté du fail-open existant.

**Conséquence assumée et NOMMÉE** : avec `deployerGroup` déclaré sur prod, le repli
AppRole de Jenkinsfile.prod (« acte non imputable ») devient refusé fail-closed
(`DEPLOYER_GROUP_REQUIRED` — l'AppRole du pipeline ne porte pas `operator-deploy`).
La déclaration force l'imputabilité au terminus : déployer prod exige désormais un
humain du groupe, ou un grant explicite de la policy à un AppRole dédié (geste
exploitant, jamais un défaut). À écrire dans le Jenkinsfile.prod (commentaire) et
dans l'ADR.

**D6 — Le lab matérialise les groupes, avec les personas existantes.**
Nouveau `scripts/setup-deployer-groups.sh` (ldif idempotent, dérivé de la chaîne) :
`apim-apply-int` = {bob}, `apim-apply-homol` = {carol}, `apim-apply-rec` = {} (grant
à la demande), membres surchargeables. `apim-operator-prod` existe (oscar). alice
n'est membre de rien : c'est la persona de contre-épreuve (« membre de l'équipe
demandeuse »). Le mapping Vault, lui, est déjà posé (G4) — le script ne touche pas
Vault. Geste exploitant supplémentaire pour la chaîne gouvernance hors-prod : granter
à l'AppRole `ci-pipeline` les policies `apply-<env>` hors-prod (dérivé, jamais le
terminus) — c'est la déclaration explicite « la machine du CI gouvernance est le
déployeur hors-prod » ; sans ce grant, le pipeline hors-prod refuse fail-closed sur
les paliers déclarés (`DEPLOYER_GROUP_REQUIRED`), et c'est le comportement voulu
d'une déclaration qui vient d'apparaître. Posé par un nouveau volet de
setup-vault-paliers.sh (`--grant-ci`), même style que `--mint`.

**D7 — Le 4-yeux « rejoué sur les trois nouveaux paliers » se prouve au niveau du
MÉCANISME, pas en réécrivant la décision client n°1.**
- governance-api : tests par palier sur la chaîne livrée (int, homol : refus
  `SELF_APPROVAL_BLOCKED` ; jeton sans le groupe : refus `GATE_GROUP_REQUIRED`) +
  variante rec-avec-fourEyes (chaîne de fixture) prouvant que fermer la décision n°1
  est bien « une ligne » qui MORD.
- harnais wiring : le cas int (⑮) existe ; ajouter homol. rec reste selfApproval
  dans le gabarit — documenté, pas maquillé.

**D8 — Ce que G2 ne touche PAS** : la pose du plugin build-user-vars (l'inertie de
`promoted_by` reste documentée telle quelle) ; l'audience non pinnée du
governance-api ; l'enforcement d'`approverGroup` au merge côté forge (le contrôle du
merge reste la protection de branche, ADR-081/G4) ; `DefaultEnvChain` (inchangé) ;
la sous-commande `labctl promote` (G8) ; les frères du C1 (identités webhook de
team-publish/team-apply, hors périmètre nommé au handoff G5).

---

## §3 — Flux cible (chaîne self-service, palier int)

1. bob (groupe LDAP `apim-apply-int`) merge la PR `promote/<api>-int` — ou un membre
   de l'équipe demandeuse la merge, peu importe : le webhook n'est pas une autorité.
2. Build `team-promote` : gardes §0→§6bis inchangées (réconciliation Gitea,
   anti-TOCTOU, marqueur, 4-yeux conditionnel à la porte, **V_USER == mergeur**).
3. **Nouveau §7.a — LA DÉCLARATION** : `env_chain_gate_deployer_group int` →
   `apim-apply-int` → projection `apply-int` → `GET /v1/auth/token/lookup-self` avec
   le token nominatif → `apply-int` ∈ policies ∪ identity_policies ?
   - bob : oui (groupe LDAP → policy au login) → on continue ;
   - alice (même mergeuse, même URL de job, même pause répondue) :
     `DEPLOYER_GROUP_REQUIRED`, commenté sur la PR, **moteur jamais invoqué** ;
   - lookup-self KO : `DEPLOYER_GROUP_UNVERIFIABLE` ; groupe hors famille :
     `DEPLOYER_GROUP_UNSUPPORTED`.
4. §7.b — LA RÉTENTION (inchangée) : lecture `envs/int/wm-admin` sinon `PALIER_FERME`.
5. §8 — le moteur, un seul site, les deux engines.

Chaîne gouvernance : apply-uac relit la chaîne, et pour chaque env gated+enabled
dispatché dont la porte déclare `deployerGroup`, vérifie la policy projetée du token
`VAULT_TOKEN_FILE` avant toute écriture — machine (ci-pipeline granté) ou humain
(oscar en prod), même règle, même refus.

---

## §4 — Preuve et contre-épreuves

### Portes hors-ligne (branchées `make lint-ci`)

1. **`go test ./internal/governance/ -count=1`** (via test-env-chain.sh) :
   - `ParseEnvChain` accepte `deployerGroup` et le restitue ;
   - la table de projection : les deux familles, et le refus hors-famille ;
   - `TestShippedExampleChain` épingle le gabarit AVEC `deployerGroup` par palier
     (structs `want` mises à jour — le champ nouveau fait diverger toute dérive) ;
   - approve par palier : `SELF_APPROVAL_BLOCKED` sur int et homol (chaîne livrée),
     `GATE_GROUP_REQUIRED` (jeton sans le groupe) sur int/homol/prod, et la variante
     rec+fourEyes qui prouve la décision n°1 « une ligne qui mord ».
2. **Tests Go labctl (dispatch)** : preflight déployeur — porte déclarée + token
   sans policy ⇒ `DEPLOYER_GROUP_REQUIRED` avant toute écriture ; Vault muet ⇒
   `DEPLOYER_GROUP_UNVERIFIABLE` ; nom hors famille ⇒ `DEPLOYER_GROUP_UNSUPPORTED` ;
   porte sans déclaration ⇒ aucun appel lookup (httptest, motif vault_test.go).
3. **`scripts/test-env-chain.sh`** : sabotage n°2 — retirer `deployerGroup` de la
   porte int ⇒ le test Go ROUGIT (sinon vert vacant), restauration par trap,
   `-count=1` (le cache Go ne piste pas le YAML hors module).
4. **`scripts/test-team-promote-wiring.sh`** : nouveaux jetons dans ORDRE_TOKENS
   (avant PALIER_FERME), mutations volet A (retrait du contrôle ⇒ verdict KO,
   anti-no-op cmp), volet B : stub lookup-self piloté par ctl.json — cas
   « policies sans apply-int ⇒ DEPLOYER_GROUP_REQUIRED + $STUB_LOG absent », cas
   « groupe hors famille (chaîne variante via STOA_ENV_CHAIN_FILE) ⇒
   UNSUPPORTED », cas homol 4-yeux (⑮ rejoué), chemin nominal rec inchangé
   (aucun lookup si pas de déclaration — prouvé par l'absence d'appel dans le
   stub). `EXPECTED_ASSERTIONS` RE-MESURÉ, jamais déduit.
5. **`make lint-ci`** : shellcheck des nouveaux livrables + toutes les étapes.

### Portes live (lab requis, rejouables)

6. **`scripts/test-deployer-gate-live.sh`** : contre le Vault/LDAP réels —
   pose des groupes (setup-deployer-groups.sh), login LDAP bob ⇒ lookup-self porte
   `apply-int` ; login alice ⇒ ne la porte pas ; le contrôle shell rend REQUIRED
   pour alice et passe pour bob ; contre-épreuve : retirer bob du groupe (ldif)
   ⇒ REQUIRED (le grant est vivant, pas un one-shot), restauration.
7. **E2E chaîne (checklist type T10)** : merge PR promote vers int par bob ⇒ API
   promue ; rejeu à l'identique avec alice à la pause ⇒ refus nommé sur la PR,
   gateway inchangée. (Précondition : gestes exploitant du handoff G5 — push
   gitea + credential — sinon rejouer script-par-script comme G5, en le disant.)

### §4.1 — Ce que G2 ne prouve PAS, et c'est voulu

- Le 4-yeux pipeline reste inerte tant que build-user-vars manque (`promoted_by=ci`)
  — la contre-épreuve 4-yeux des paliers est prouvée sur le mécanisme governance-api
  et sur le harnais (marqueur forgé), pas sur un humain Jenkins réel.
- L'iso des deux moteurs sur ce nouveau refus est du câblage partagé (le contrôle
  vit dans team-promote.sh, AVANT le choix du moteur) — la parité d'ÉTAT reste G8.
- rec sans fourEyes ni deployerGroup est la décision client n°1, pas un oubli.

---

## §5 — Inventaire des livrables

| Livrable | Nature |
|---|---|
| `labctl/internal/governance/envchain.go` | champ `DeployerGroup` + `DeployerPolicy()` (table 2 familles, fail-closed) |
| `labctl/internal/governance/envchain_test.go`, `envchain_shipped_test.go` | parse + projection + gabarit épinglé |
| `labctl/cmd/governance-api/handlers_promotions.go` | évidence `gate.deployer_group` (aucun nouveau refus à l'approve) + tests par palier |
| `labctl/internal/vault/vault.go` | `TokenPolicies(ctx)` (lookup-self, union policies+identity_policies) |
| `labctl/cmd/labctl/dispatchgate.go` (ou fichier frère) + `applyuac.go` | preflight déployeur avant écriture, 3 codes typés + raisons d'audit |
| `scripts/lib/env-chain.sh` | `env_chain_gate_deployer_group` (fonction SŒUR, jamais un 4ᵉ champ positionnel) + `deployer_group_policy` (table shell) |
| `scripts/team-promote.sh` | contrôle §7.a (déclaration) avant PALIER_FERME, 3 refus nommés, commentés sur la PR |
| `clients/_example/environments.yaml` | `deployerGroup` sur int/homol/prod + bloc « trois axes, deux annuaires » réécrit |
| `scripts/setup-deployer-groups.sh` | groupes LDAP dérivés de la chaîne, membres lab par défaut, idempotent |
| `scripts/setup-vault-paliers.sh` | volet `--grant-ci` (policies apply-* hors-prod sur l'AppRole ci-pipeline, terminus exclu par structure) |
| `scripts/seed-governance-chain.sh` | read-back étendu au deployerGroup |
| `scripts/api-promote-request.sh` | corps de PR : le groupe déployeur déclaré (et « approbation = merge, protégé par la branche ») |
| `scripts/test-env-chain.sh`, `scripts/test-team-promote-wiring.sh` | portes étendues (sabotage n°2, nouveaux cas, compte re-mesuré) |
| `scripts/test-deployer-gate-live.sh` | porte live |
| `Makefile` | lint-ci : nouveaux shells shellcheckés |
| `adr/adr-084-axe-qui-deploie-deployer-group.md` | la décision, les deux annuaires, la table, les refus |
| `ENVIRONNEMENTS.md`, `GOAL-…-2026-08-26.md`, handoff | doc opérateur, jalon coché, handoff de session |

## §6 — Parkings, avec rulings

1. **`approverGroup` enforced au merge (forge)** — parqué : le contrôle du merge est
   la protection de branche (ADR-081/G4) ; un miroir Gitea-teams serait un 3ᵉ
   mécanisme d'identité sans nouveau pouvoir. Réouverture si le client exige que le
   groupe d'approbation KC gouverne AUSSI le droit de merge.
2. **N-de-N (« homol exige équipe A ET équipe B »)** — décision client n°2, hors G2.
3. **`labctl dispatch-gate` standalone sans identité** — assumé, documenté dans le
   fichier : le refus déployeur vit dans apply-uac, au moment où le token existe.
4. **Un client OAuth par palier** (limite héritée G5/D5) — inchangé.
5. **Frères du C1** (identités webhook des jobs frères) — hors périmètre, nommé au
   handoff G5, inchangé.
