---
title: "GOAL — La chaîne CD manquante : promouvoir APIs et applications de dev jusqu'en prod sur cinq paliers, par une référence pinnée et des portes dont l'autorité vit hors du pipeline"
type: goal
status: "Cadré sur relevé du dépôt (2026-08-26) + deep-research (105 agents, 11 claims vérifiés en 3-votes, 4 claims réglementaires RÉFUTÉS). Huit jalons G1..G8. Décision n°6 TRANCHÉE le 2026-08-26 (deux moteurs iso-sémantiques ⇒ G8 ; DELIVERY-PROCESS.md corrigé le même jour) ; cinq décisions client restent ouvertes, dont une qui touche le besoin tel qu'exprimé. À valider avant spécification."
date: 2026-08-26
lié: [GOAL-self-service-api-app-2026-07-09, GOAL-socle-vers-gateway-2026-07-28, adr-075-wm-admin-proxy-multienv, adr-076-gitops-api-lifecycle-repo-per-project, adr-078-livrable-self-service-app-wm1015, adr-079-deploiement-promotion-multienv-import-archive, adr-081-ou-vit-la-decision-humaine]
note: "Le besoin remonté était « il manque un workflow git ». Le relevé montre autre chose : le moteur de promotion N-paliers avec portes par saut EST écrit et testé — il n'est simplement jamais configuré, jamais relié au self-service, et son verbe de déploiement n'est pas celui qu'ADR-079 a tranché."
---

# GOAL — La chaîne CD des cinq paliers

**Origine.** Le self-service produit des APIs et des applications, mais **rien ne les déplace**. Le diagnostic exact n'est pas « il manque un workflow git » : il manque **quatre pièces distinctes**, et l'une d'elles est déjà construite à 80 %.

---

## Décision (test « archi 40 ans / 30 secondes »)

> **On ne construit pas une chaîne CD : on branche celle qui existe.** Le moteur de promotion à N paliers, avec une porte par saut (`Gate{ApproverGroup, FourEyes, RequireChangeRef, RequirePVRef, ITSMCheck}`, `labctl/internal/governance/envchain.go:18-37`), le pinning de commit (`deploy.<env>.yaml` → `labctl/internal/uac/pinned.go:19`), le rollback audité et la garde ITSM anti-TOCTOU sont **écrits, testés, livrés**. Ils tournent aujourd'hui sur leur chaîne par défaut `dev → staging → production` parce qu'**aucun `environments.yaml` n'existe dans le dépôt**.
>
> **La référence de déploiement n'est pas une branche d'environnement.** C'est un **SHA pinné** dans un `deploy.<env>.yaml` mergé, plus le **digest de l'archive** promue. Une branche `rec` que des humains éditent est le motif que la littérature GitOps recommande d'éviter ; la forme retenue est celle que le dépôt implémente déjà — une source unique, un fichier de déploiement par palier, un rendu par environnement jamais manipulé à la main.
>
> **L'autorité ne vit pas dans le pipeline.** Le verrou actuel (`[ "$ENVN" = dev ] || fail ENV_NOT_OPEN`, `scripts/team-apply.sh:53`) est un fichier du dépôt, éditable par exactement la population qu'il contraint, exécuté par un build Jenkins qui tourne en `SYSTEM`. Le remplacer par un autre `if` in-repo ne gagne **rien**. Le contrôle migre vers deux mécanismes qui, eux, ne peuvent pas se lever eux-mêmes : la **rétention du credential** (le job d'un palier n'a aucune policy Vault au-delà de son palier) et la **définition de pipeline hors du périmètre d'écriture du demandeur**.
>
> **Le verbe de déploiement est l'import d'archive à GUID stables** (ADR-079, 22/22, 0-coupure ×3), pas le re-`POST` qui reconstruit l'API. `apply-uac` reste le verbe de **dev** — le seul palier où le blip de première création est toléré. Ce verbe est porté par **deux moteurs maintenus iso-sémantiques** (`apim_promote_api` côté client, `labctl promote` côté lab/gouvernance, un seul `.promote.yml`) : c'est un choix assumé, dont **la parité prouvée est le prix** (G8) — sans quoi ce ne sont pas deux moteurs, mais deux comportements dont on espère qu'ils coïncident.
>
> **Test :** *un producteur peut-il faire passer une API de dev à la prod en cinq sauts, chaque saut étant un merge que sa propre équipe ne peut pas approuver au-delà de rec, chaque palier recevant exactement l'archive approuvée et pas « le dernier main », sans qu'aucun credential de palier supérieur n'ait jamais été atteignable depuis le job du palier inférieur, et avec un chemin de repli identifié pour chaque saut ?* Si l'une de ces réponses n'est pas « oui, mécaniquement », on a construit une convention, pas un contrôle.

---

## Ce que le relevé a mesuré (2026-08-26)

**Ce qui existe et n'est pas utilisé :**

| Pièce | Où | État |
|---|---|---|
| Moteur de portes par saut | `labctl/internal/governance/envchain.go:18-37` | Écrit, testé — `ApproverGroup`, `FourEyes`, `RequireChangeRef`, `RequirePVRef`, `ITSMCheck` |
| Pinning de version | `labctl/internal/uac/pinned.go:19` | Écrit, testé (`TestRunApplyUAC_ConcreteEnvProjectsPinnedVersion`) |
| Chaîne hors-prod dev→rec→int | `ci/Jenkinsfile` | Livrée, gate Git (`deploy.<env>.yaml` absent ⇒ palier skippé) |
| Porte prod Git-native | `ci/Jenkinsfile.prod` | Livrée — `status=approved`, 4-yeux, `change_ref`, `pv_ref`, commit pinné, `error()` avant tout dispatch |
| Rollback audité | `ci/Jenkinsfile.rollback`, `handlers_rollback.go` | Livré, **prod uniquement** |
| Promotion par archive | `ansible/roles/apim_promote_api` | Livrée E2E, prouvée 22/22 (ADR-079) |

**Les quatre trous :**

1. **`environments.yaml` n'existe comme LIVRABLE nulle part.** ~~(`find` → 0 résultat)~~ **Précisé à l'exécution (2026-08-26) :** un `environments.yaml` existe bel et bien — mais en **heredoc dans `scripts/demo-multienv.sh:63-73`**, écrit dans un dépôt **jetable** (`mktemp -d`), à **quatre** paliers (`[dev, rec, int, prod]`), avec des portes sur `int` et `prod` seulement. La chaîne est donc **prouvée** (la démo tourne), mais sa configuration vit dans un script de démo au lieu d'être un artefact versionné : hors de la démo, le moteur retombe sur son défaut `dev → staging → production` (`labctl/internal/uac/uac.go:43`), des noms qui ne sont ni ceux du lab ni les tiens. C'est une nuance qui compte — le travail n'est pas « écrire un moteur de chaîne », c'est **sortir une config d'un script de démo**.
2. **`homol` n'existe que dans la prose d'ADR-079.** Aucun code, aucun répertoire, aucun choix de formulaire ne le connaît. **Mesuré à l'exécution : le trou est SIX listes de trois environnements écrites en dur**, chacune répétant la chaîne que `environments.yaml` est censé porter — `scripts/setup-wm-admin-proxy.sh:32` (`ENVS=(dev rec int)`), `scripts/setup-ci-horsprod.sh:31` (`SCOPES=(deploy:dev deploy:rec deploy:int)`), `scripts/setup-vault-envs.sh:35-42` (un bloc de vars par env), `docker-compose.envs.yml` (un service `wm-mock-<env>` par env), `ci/Jenkinsfile:160` (`for E in dev rec int`), `ci/Jenkinsfile.selfservice:34` (`['dev','rec','int','prod']`). **Ajouter `homol` en éditant ces six listes reproduirait exactement le problème** : la chaîne doit se DÉRIVER de `environments.yaml`, pas s'y ajouter une septième fois.
3. **Le self-service est dev-only par verrou explicite** : `scripts/team-apply.sh:53` (`ENV_NOT_OPEN`), `scripts/team-publish.sh:75` (`ENVN="${ENVN:-dev}"`, avec le commentaire ligne 73 — *« `api/<name>-<version>` ne porte aucun axe d'environnement »*), un seul `ansible/providers.dev.yml`.
4. **Deux mondes qui ne se parlent pas.** La chaîne gouvernance (ADR-072/075, dépôt `governance`) et la chaîne self-service (ADR-076/078/081, dépôts d'équipe) partagent zéro objet. Le formulaire ouvre une PR d'équipe ; il **n'émet aucune promotion**.

---

## Ce que la recherche a tranché — et ce qu'elle n'a pas tranché

**Deux résultats qui changent la conception :**

**(A) La garde in-repo est structurellement faible — confirmé 3-0, deux mécanismes cumulatifs.** OWASP CICD-SEC-04 (*Poisoned Pipeline Execution*) : un acteur n'ayant **que** le droit d'écriture sur le dépôt, sans aucun accès à l'environnement de build, exécute des commandes arbitraires sur le nœud en éditant la définition de pipeline versionnée. Et Jenkins, page sécurité canonique : *« By default, builds run as the internal SYSTEM user that has full permissions »*. Notre `ENV_NOT_OPEN` coche les deux cases. Le remède prescrit par OWASP est la **séparation de la définition de pipeline du contenu qu'elle déploie** — branche distante distincte et protégée. ⚠ **Plafond honnête, énoncé par OWASP lui-même** : cela ferme le PPE **direct**, pas l'**indirect**, qui survit par *« scripts referenced from within the pipeline configuration file »* — c'est-à-dire exactement nos `scripts/*.sh` et `ansible/roles/*`. Les protéger fait partie du travail, pas d'un second temps.

**(B) L'indépendance approbateur / demandeur est du droit européen directement applicable, sans gradation par environnement.** Règlement délégué (UE) 2024/1774 (RTS DORA), art. 17(1)(b), applicable depuis le 17 janvier 2025, vérifié mot pour mot sur deux rendus indépendants : le chapeau vise *« all changes to software, hardware, firmware components, systems, or security parameters »*, puis exige *« mechanisms to ensure the independence of the functions that approve changes and the functions responsible for requesting and implementing those changes »*. Le texte est **technologiquement neutre** — il exige des mécanismes, pas un mécanisme précis — et la proportionnalité (art. 4 DORA) module leur **conception**, pas leur **existence**. Et l'art. 17(1)(e) rend obligatoire *« the identification of fall-back procedures and responsibilities, including procedures and responsibilities for aborting changes or recovering from changes not successfully implemented »* : le repli est un **composant du déploiement**.

> **Conséquence directe sur le besoin tel qu'exprimé.** « dev et rec peuvent se faire de manière autonome par celui qui remplit le formulaire » entre en tension avec l'art. 17(1)(b), qui ne connaît pas de palier exempté. Ce n'est pas un motif d'arrêt — c'est une **décision client** (n°1 ci-dessous), à prendre les yeux ouverts plutôt qu'à découvrir en audit. La suite du GOAL est construite pour que les deux options soient un réglage de `environments.yaml`, pas une réécriture.

**Deux patrons de plateforme à copier, avec leurs trous :**

- **La rétention du credential** (GitHub environments, 3-0) : *« a job cannot access environment secrets until one of the required reviewers approves it »*. C'est le seul contrôle qu'un pipeline ne peut pas se retirer à lui-même. **Portée limite déterminante** : ne protège que les secrets scopés à l'environnement — d'où l'exigence que les creds gateway vivent réellement par palier. Le dépôt a déjà la forme (`secret/stoa/envs/{env}/wm-admin`, scopes `deploy:{env}`, `ci-horsprod` **sans** `deploy:prod`).
- **La séparation déployer / approuver** (GitLab protected environments, 3-0, confirmée par le modèle de données de l'API : `deploy_access_levels` et `approval_rules` sont deux tableaux **structurellement indépendants**). C'est mot pour mot ton besoin — int déclenché par une autre équipe, homol/prod par une troisième. Notre `Gate` porte `ApproverGroup` mais **aucun axe « qui déploie »**.
- **Trous des deux plateformes, à ne pas hériter** : chez GitHub le bypass administrateur est actif **par défaut**, la liste de reviewers plafonne à six et **une seule** approbation suffit (1-de-N, donc « homol exige équipe A **et** équipe B » n'est pas exprimable) ; chez GitLab comme chez GitHub, l'interdit d'auto-approbation vise le **déclencheur du pipeline**, pas l'**auteur du changement** (issue GitLab #381418 toujours ouverte). **Notre `FourEyes` compare `requested_by` à `approved_by`** — il vise le demandeur de la promotion, donc il est déjà **plus strict** que les deux. C'est un acquis à préserver, pas à aligner par le bas.

**Ce que la recherche n'a PAS établi — à traiter comme un résultat, pas comme un silence :**

- **Zéro claim survivant sur webMethods 10.15** (Promotion Management API vs archive, GUID, alias stage-scoped, blue-green). La seule base fiable reste **interne** : ADR-079 et la campagne du 2026-07-17. Ne pas aller chercher un appui éditeur qu'on n'a pas.
- **Zéro claim survivant** sur « build once, deploy many », release train, et promotion en réseaux segmentés.
- **Quatre justifications réglementaires attendues ont été RÉFUTÉES 0-3** : l'art. 8(2)(b)(v)-(vi) du même règlement et le §72 des orientations EBA **ne fondent pas** la topologie « gateways séparées par environnement, flux inter-env fermés ». ⚠ **Ce pilier de la conception cible n'a donc aucun ancrage de conformité vérifié** — il reste justifié par la contrainte d'exploitation du client, et l'argument « c'est une exigence réglementaire » doit être **retiré de tout livrable client** tant qu'il n'est pas re-sourcé.
- Rien de vérifié ne relie l'approbation de promotion à un ticket ITSM du point de vue PCI DSS, ITIL ou SOX. Notre porte ITSM reste une **politique interne** défendable, pas une obligation sourcée.

---

## Jalons — chacun avec sa porte de preuve et sa contre-épreuve

### G1 — Déclarer la chaîne : `environments.yaml` à cinq paliers

Écrire le fichier que le moteur attend depuis toujours, et créer `envs/homol/`.

~~Auditer les appelants **non chain-aware**~~ — **AUDIT FAIT le 2026-08-26, sans objet : le code Go est DÉJÀ entièrement chain-aware.** `uac.ValidEnv` et `uac.EnabledEnvs` n'ont **aucun appelant de production** (seulement eux-mêmes, comme enveloppes de commodité) ; tous les chemins réels passent déjà par les variantes `…In(chain)` et chargent la chaîne — `applyuac.go:92` (`LoadEnvChain`) et `:162`, `dispatchgate.go:173` (`loadGovChain`), et `Store.EnvChain` côté governance-api, qui la relit **sur `main` à chaque requête, sans état hors de Git**. Le durcissement à faire n'est donc pas dans le Go : il est dans les **six listes en dur** côté shell / compose / Jenkinsfile (cf. trou n°2).

**ÉTAT AU 2026-08-26 — livré et prouvé :**
- `clients/_example/environments.yaml` — la chaîne à cinq paliers et ses portes, à l'emplacement que `DELIVERY-PROCESS.md` §3 prévoyait (couche CONFIG CLIENT) et qui était resté vide. Groupes suivant la convention **existante** `apim-operator-<env>` (`apim-operator-prod` existe déjà, `scripts/setup-vault-ldap.sh:156`).
- `labctl/internal/governance/envchain_shipped_test.go` — deux tests qui épinglent l'ordre de la chaîne et **le jeu de contrôles de chaque saut**, plus une propriété qui interdit qu'un palier ajouté plus tard passe en douce sans porte.
- `envs/homol/targets.yaml` + `targets.cluster.yaml` — chargés par `labctl plan` **exactement comme** `rec` et `int` (vérifié côté loader ; `labctl validate` ne convient pas, il valide le contrat OpenAPI et échoue identiquement sur `envs/rec` existant).
- `scripts/test-env-chain.sh` — **4/4, contre-épreuve comprise**.

**PIÈGE MESURÉ, et c'est pourquoi le script shell existe :** `go test ./internal/governance/` rend **`ok (cached)` après un relâchement de porte**. Le cache de test Go ne piste pas `clients/_example/environments.yaml`, qui vit **hors du module** `labctl/` — le sabotage passe donc au vert sur un run mis en cache, et n'est rattrapé que par `-count=1`. Une garde qui ne rougit que si l'on pense au bon flag n'est pas une garde : `test-env-chain.sh` force `-count=1` et **joue le sabotage** (retrait d'`itsmCheck` de la porte prod) avec restauration inconditionnelle par `trap`.

**CORRECTION du 2026-08-26, après inspection du lab :** le dépôt governance **portait déjà** un `environments.yaml` — à **quatre** paliers `[dev, rec, int, prod]`. La chaîne n'était donc pas « absente », elle était **incomplète, et deux de ses portes étaient trouées** :
- `int` n'avait que `approverGroup: int-team`, **sans `fourEyes`** : un demandeur membre d'int-team pouvait approuver sa propre promotion rec→int. Le groupe dit QUI, il ne dit pas PAS LUI.
- `prod` n'avait **aucun `approverGroup`** : tout détenteur de `promotions:approve` autre que le demandeur pouvait approuver une mise en production. Les quatre yeux disaient PAS LUI sans jamais dire QUI.

Les deux sont fermées dans la chaîne à cinq paliers, et `homol`/`prod` pointent le **même** groupe `release-team` — le besoin dit « l'homol et la prod toujours par une autre équipe, mais avec un process plus strict » : c'est le PROCESS qui durcit (PV en homol ; + change + re-vérification ITSM en prod), pas l'équipe.

**ERREUR CORRIGÉE dans le premier jet :** les groupes avaient été nommés `apim-operator-<env>`. C'était **le mauvais annuaire**. `approverGroup` est comparé à la claim `groups` du **jeton Keycloak** (convention `<env>-team`, `int-team` existe) ; `apim-operator-*` est un groupe **LDAP mappé sur une policy Vault**, qui gouverne l'accès aux **secrets**. Un nom de la mauvaise famille ne produit aucune erreur — juste une porte qui ne matche **jamais**, donc un saut inapprouvable : fail-closed, mais pour la mauvaise raison.

**Plomberie `homol` — les six listes en dur, traitées :**
| Emplacement | Traitement |
|---|---|
| `scripts/setup-wm-admin-proxy.sh` | **dérivé** (`env_chain_nonprod`) |
| `scripts/setup-ci-horsprod.sh` | **dérivé** — la barrière « pas `deploy:prod` » devient **structurelle** (le terminus est exclu, plus un nom codé en dur) |
| `scripts/setup-vault-envs.sh` | **dérivé** (boucle par palier ; surcharges `WM_<ENV>_USER/PASS` historiques préservées à l'identique) |
| `docker-compose.envs.yml` | service `wm-mock-homol` ajouté, **forme identique** à `wm-mock-int` (réseau `nonprod`, healthcheck) — vérifié par comparaison de dict |
| `ci/Jenkinsfile:160` | **dérivé de `governance/environments.yaml`** — la source dont apply-uac et governance-api tirent déjà leurs portes |
| `ci/Jenkinsfile.selfservice:34` | `homol` ajouté **en dur, et documenté comme tel** : un bloc `parameters {}` déclaratif est évalué à la POSE du job, hors workspace — il n'a aucun accès au clone governance. C'est la seule liste qui reste à tenir à la main. |

Nouveau : `scripts/lib/env-chain.sh` (`env_chain`, `env_chain_nonprod`, `env_chain_approver_group`), fail-closed sur source absente/vide/cassée.

**Livré en plus, hors périmètre initial mais dû :** `scripts/test-jenkinsfile-lint.sh` — **12/12**, contre-épreuve comprise. C'est la porte qui manquait quand `Jenkinsfile.carto` a cessé de compiler le 2026-08-07 ; elle rejoue l'échappement `\w` exact qui l'avait cassé. Les 11 Jenkinsfile parsent.

**Trois pièges mesurés pendant l'exécution, tous corrigés :**
1. **`BASH_SOURCE` résolu à l'appel** dans `env-chain.sh` : le chemin est relatif tel que l'appelant l'a écrit, or tous les scripts font un `cd` après le source → la fonction renvoyait une chaîne **vide** au lieu d'échouer. Racine désormais capturée **au source**.
2. **`mapfile` n'existe pas en bash 3.2** (macOS) : le lint rendait « 1 PASS / 0 FAIL » et sortait **0** alors qu'il n'avait linté **aucun** fichier — un vert vacant dans la porte elle-même. Remplacé, + garde-fou « zéro fichier linté = ÉCHEC » et « verdicts rendus == fichiers attendus ».
3. **Apostrophe française dans `${VAR:?message}`** : bash y voit une ouverture de quote ; le script entier devient un `unexpected EOF` signalé à la **dernière** ligne, très loin de la faute. Aucun autre script du dépôt ne porte ce motif (vérifié).

**Reste à faire sur G1 — deux gestes, bloqués par le classifieur, à lancer par l'exploitant (`! bash`)** — dans **cet ordre**, car la chaîne nomme un groupe qui doit exister avant qu'un saut soit approuvable :
```
bash scripts/setup-release-team.sh          # groupe KC release-team + carol/dave
GITEA_TOKEN=<write:repository> bash scripts/seed-governance-chain.sh
```
Le second **dérive du gabarit** (`clients/_example/environments.yaml`) plutôt que de dupliquer : une source, une instance. Il refuse de pousser si `test-env-chain.sh` est rouge, et relit depuis Gitea — pas depuis le clone local — ce que le CI **lira** sur `main`.

⚠️ **Fenêtre assumée** entre les deux gestes : la porte `prod` nomme désormais `release-team`. Tant que le groupe n'existe pas, une promotion vers prod est **inapprouvable**. C'est fail-closed, donc sans danger — mais bloquant, et il faut le savoir avant de le découvrir.

```yaml
environments: [dev, rec, int, homol, prod]
gates:
  - { to: rec,   selfApproval: <décision n°1> }
  - { to: int,   approverGroup: <groupe int>,   fourEyes: true }
  - { to: homol, approverGroup: <groupe homol>, fourEyes: true, requirePVRef: true }
  - { to: prod,  approverGroup: <groupe prod>,  fourEyes: true, requireChangeRef: true, requirePVRef: true, itsmCheck: true }
```

**Porte G1 :** `apply-uac --env homol` est accepté ; une promotion `dev → prod` en un saut est **refusée** (saut de palier).
**Contre-épreuve :** `environments.yaml` syntaxiquement cassé ⇒ refus **fermé** (`ParseEnvChain` est déjà fail-closed — le rejouer, pas le supposer) ; un palier retiré du fichier ⇒ tout `apply` sur ce palier refusé.

### G2 — L'axe manquant : « qui déploie » à côté de « qui approuve »

Ajouter `DeployerGroup` au `Gate`, sur le modèle des deux tableaux indépendants de GitLab. Sans lui, ton besoin « à partir de l'int, cela doit être fait par une autre équipe » n'est **pas exprimable** : `ApproverGroup` dit qui valide, jamais qui déclenche.

**Porte G2 :** un membre du groupe int déclenche la promotion vers int ; un membre de l'équipe demandeuse ne le peut pas, **même en connaissant l'URL du job**.
**Contre-épreuve :** jeton sans le groupe ⇒ refus ; le demandeur qui approuve son propre saut ⇒ refus 4-yeux, rejoué sur les **trois** nouveaux paliers (le motif est prouvé en prod, pas ailleurs).

> **LIVRÉ le 2026-08-27** — ADR-084, spec `docs/superpowers/specs/2026-08-27-g2-axe-qui-deploie-design.md`.
> `deployerGroup` vit dans l'**annuaire n°2** (LDAP→policy Vault, table de
> projection à deux familles, fail-closed BRUYANT hors famille) — jamais la
> claim KC : au dispatch, la seule identité vérifiée sur toutes les chaînes est
> le token Vault du porteur. Trois codes identiques deux moteurs
> (`DEPLOYER_GROUP_REQUIRED`/`UNSUPPORTED`/`UNVERIFIABLE`), enforcement aux
> deux sites de dispatch (team-promote §7.a AVANT la rétention §7.b ; preflight
> d'apply-uac avant toute écriture), jamais à l'approbation (l'évidence
> MATÉRIALISE le champ, `gate.deployer_group`).
> **Portes réelles** : test-env-chain.sh 6/6 ; go test (governance : 7 refus
> par palier dont SELF_APPROVAL_BLOCKED int/homol et la variante rec+fourEyes
> « une ligne qui mord » ; labctl : preflight 7 cas + voie `--env any` à deux
> familles pinnée par mutation ; vault : lookup-self fail-closed corps vide
> compris) ; wiring **137/0** (ordre prouvé par mutation ET par inversion
> 7.a/7.b, stub lookup-self, zéro lookup sans déclaration, anti-dérive ldap) ;
> **live 21/0** (bob porte apply-int ; alice rien ; le grant SUIT l'annuaire —
> et la mesure clé : un token émis AVANT le retrait porte la policy jusqu'à son
> TTL, retrait ≠ révocation ⇒ la vérification DOIT rester au dispatch) ;
> make lint-ci 8/8. Deux bugs RÉELS attrapés par la porte live seulement
> (printf mangeait le terminateur LDIF de la convergence ; user-lockout Vault
> rendait le diagnostic de la porte menteur).
> **La contre-épreuve 4-yeux sur rec** est prouvée sur variante de fixture
> (rec du gabarit reste `selfApproval` — décision client n°1, inchangée).
> **Restes nommés** (ADR-084 §Limites) : 4-yeux pipeline inerte
> (build-user-vars), approverGroup toujours pas enforced au merge (= protection
> de branche, ADR-081), `labctl apply` (flux manifeste) sans porte déployeur,
> `/token-policies` (--grant-ci) non prouvé live, parité des moteurs = G8.

### G3 — La référence de déploiement, portée jusqu'aux dépôts d'équipe

`deploy.<env>.yaml` avec commit pinné existe pour le dépôt governance. Le porter au modèle repo-par-projet (ADR-076) : promouvoir une API d'équipe = merger un `deploy.<env>.yaml` dans **son** dépôt, pinnant le SHA de `apis/<name>.publish.yml` **et** le digest de l'archive.

**Décision de forme, tranchée :** pas de branche d'environnement. La référence est un **SHA + un digest**, immuables. Une branche est un pointeur mouvant — elle ne peut pas répondre à « qu'est-ce qui tourne exactement en homol ? ».

**Porte G3 :** `deploy.rec.yaml` pinne un SHA ; l'apply en rec projette **ce** contrat, pas le dernier `main`.
**Contre-épreuve :** pousser un nouveau commit sur `main` du dépôt d'équipe ⇒ rec **reste** au SHA pinné. Pas de dérive silencieuse.

### G4 — Lever le verrou dev-only, et le remplacer par un contrôle qui ne se lève pas lui-même

> **LIVRÉ 2026-08-26** — ADR-082, `HANDOFF-2026-08-26-G4-RETENTION-CREDENTIAL.md` ; portes hors-ligne `test-palier-retention.sh` **126/0** + live Vault `test-palier-retention-live.sh` **24/24** + live Gitea `test-repo-protections-live.sh` **13/13**. Le verrou ne se « lève » pas, il se **scelle** : ouvrir un palier est un geste de credential (mint AppRole `apply-<env>` / grant humain), jamais un edit de code.

`ENV_NOT_OPEN` et `ENVN="${ENVN:-dev}"` tombent. Ils sont remplacés par **trois** mécanismes, pas par un autre `if` :

1. **Rétention du credential.** Chemins Vault, policies et AppRole **distincts par palier**, homol inclus. Le job de la voie self-service n'a **aucune policy** au-delà de dev. C'est l'analogue direct des environment secrets, et le seul contrôle qu'un pipeline compromis ne peut pas contourner.
2. **Définition de pipeline hors du périmètre d'écriture du demandeur.** Les `Jenkinsfile` de promotion int/homol/prod ne sont pas éditables par l'équipe qui demande la promotion (branche protégée distincte, per OWASP).
3. **`scripts/` et `ansible/roles/` sous protection de chemin.** Sans quoi le PPE **indirect** rouvre exactement ce que (2) vient de fermer — c'est OWASP qui nomme ce trou, pas nous.

**Porte G4 :** un membre de l'équipe demandeuse édite un fichier de la chaîne et pousse ⇒ le pipeline de promotion ne bouge pas.
**Contre-épreuve :** révoquer la policy Vault du palier ⇒ l'apply échoue **fermé**, gateway **inchangée**. Le motif est déjà prouvé (F4 : rôle révoqué → FAILURE, aucune mutation) — le rejouer par palier.

### G5 — Le verbe : import d'archive à GUID stables — **porté par les deux moteurs**

Brancher le verbe archive sur les sauts rec et au-delà. `dev` garde le `POST` (env d'authoring, seul où le blip est toléré, ADR-079).

**Régime tranché (décision n°6, option (c)) : les deux moteurs sont maintenus, iso-sémantiques.** `apim_promote_api` porte le chemin client, `labctl promote` le chemin lab/gouvernance, tous deux pilotés par **le même** `.promote.yml`. Ce n'est pas un statu quo : c'est un engagement dont la contrepartie est G8, et sans lequel on n'a pas deux moteurs mais deux comportements dont on espère qu'ils coïncident. État de départ, mesuré :

| | `ansible/roles/apim_promote_api` | `labctl promote` (`cmd/labctl/promote.go`) |
|---|---|---|
| Appelé par | rien encore, mais la famille `apim_*` porte tout le self-service | **rien du tout** — aucun pipeline, aucun script |
| Preuve | run `ansible-playbook` réel E2E (`EXPORT_CONFIRMED` + `PROMOTE_CONFIRMED`, `failed=0`) | 2 tests unitaires, **sur le chargement du manifeste seulement** |
| Statut déclaré | « the roles are the client deliverable » (`promote.go:1-3`) | « keeps the lab engine iso-semantic » (même commentaire) |

Deux doctrines coexistaient, écrites et contradictoires : `DELIVERY-PROCESS.md:144-145` posait **« Ansible = orchestrateur / labctl = moteur gateway unique (aucun `uri` de mutation wM dans les plays) »**, tandis que `promote.go` pose *« one manifest, two engines »*. **La première était démentie par la mesure** — 53 mutations REST wM dans les rôles — et a été **corrigée le 2026-08-26** au profit du régime à deux moteurs. La ligne 95 (*« Ansible peut rester bête ; le binaire porte la politique »*) est **conservée et précisée** : elle parle de la **décision**, jamais du **verbe**.

Corollaire à tenir sous ce régime, puisque les portes (4-yeux, ITSM, pin) vivent dans `labctl`/`governance-api` alors que le geste peut partir d'Ansible : **un refus de porte doit être mécaniquement antérieur au play** — jamais un simple ordre de stages dans un Jenkinsfile.

**Porte G5 :** promotion `dev → rec` d'une API **active** : GUID identique des deux côtés, **zéro 5xx en vol** sous charge — **par chacun des deux moteurs**.
**Contre-épreuve :** la garde `UPDATE_FORBIDDEN` de `apim_publish_api` refuse un `deactivate` hors env d'authoring ; et une porte refusée ⇒ **le play n'est jamais lancé** (pas « lancé puis échoué »).
**Note d'honnêteté :** aucun appui éditeur externe n'a survécu à la vérification. Ce jalon s'appuie sur ADR-079 et sur nos propres mesures, rien d'autre.

### G8 — La parité des deux moteurs, prouvée — la contrepartie de la décision n°6

Choisir (c) sans ce jalon, c'est maintenir deux chemins de déploiement dont rien ne garantit qu'ils font la même chose. Ce que G8 livre :

1. **`labctl promote` cesse d'être mort.** Il n'est appelé par aucun pipeline ni aucun script, et ses deux seuls tests (`TestLoadPromoteManifest_*`) portent sur le chargement du manifeste — jamais sur l'export/import réel. Il doit tourner contre une gateway, au moins dans la chaîne lab.
2. **Un test de parité X/X**, sur le modèle des autres preuves du dépôt : **même `.promote.yml`**, même API source, deux exécutions — une par moteur — et comparaison de l'**état résultant** de la gateway (GUID, `isActive`, policies, routing `${alias}`, scope-mapping), pas des logs. Le seul verdict qui compte est l'état, parce que c'est le seul que le client observera.
3. **Un registre des écarts assumés.** L'iso-sémantique totale n'est probablement pas atteignable ni souhaitable ; un écart documenté est acceptable, un écart inconnu ne l'est pas.

**Porte G8 :** les deux moteurs, sur le même manifeste, produisent un état de gateway **identique** sur les champs du registre — rejouable en `--tags verify`.
**Contre-épreuve :** introduire volontairement une divergence dans un moteur ⇒ le test de parité **rougit**. Une parité qui ne rougit jamais ne prouve rien (le motif F1 du GOAL socle).
**Tant que G8 n'est pas fermé, le régime à deux moteurs est une dette ouverte, pas un acquis** — et c'est écrit comme tel dans `DELIVERY-PROCESS.md`.

### G6 — Le repli, comme composant du déploiement

Art. 17(1)(e) : les procédures de repli et les **responsabilités** associées doivent être identifiées. Aujourd'hui `Jenkinsfile.rollback` ne couvre que la prod. L'étendre à rec, int, homol : rollback = ré-import de l'archive du `deploy.<env>.yaml` N-1 **avec son pin** (le motif existe, `handlers_rollback.go`).

**Porte G6 :** rollback exercé sur homol — retour au SHA N-1, smoke vert, trace Git de l'acte.
**Contre-épreuve :** rollback sans référence de changement sur un palier qui l'exige ⇒ refus.
**Qualification à ne pas dépasser :** (e) exige d'**identifier** les procédures, pas de les tester. L'obligation de tester le repli s'argumente depuis (c) *« controlled testing »* ou depuis DORA niveau 1, **pas** depuis (e) seul. On teste parce que c'est sérieux, pas en citant le mauvais article.

> **FAIT le 2026-08-27** — ADR-085, `ENVIRONNEMENTS.md` § « Revenir en
> arrière (G6) ». Porte tenue à trois étages : **offline** (3 tests nouveaux
> `handlers_rollback_test.go`, dont un qui rougissait sur l'ancien code) ;
> **live** `scripts/test-rollback-paliers.sh` **22/0 ×2 + rejeu contrôleur
> (22/0)** ; et par **builds Jenkins réels** — `stoa-prod-rollback` **#6
> SUCCESS** (rollback homol `pr-aa26f598` — palier **DÉRIVÉ** de la
> promotion, terminus:no, `restored` homol@1.0.1, commit gouverné `a87ebc4` +
> evidence, SMOKE catalogue N-1 via `wm-admin-homol`, `deploy.homol.yaml`
> verbatim pin compris).
> **Contre-épreuve tenue** : build **#5 FAILURE attendue** — `CHANGE_REF`
> vide sur une promotion prod approuvée ⇒ HTTP 400 `GATE_REFS_REQUIRED` de
> l'API (même job, même champ vide, verdict **opposé** selon le palier : la
> porte décide, jamais le formulaire).
> **Deux défauts découverts et fermés en route** : `apply-uac` non idempotent
> sur une API wM **ACTIVE** (PUT refusé par le produit — le PUT de
> définition est désormais **sauté** quand l'API est active ; la dérive de
> définition sur une API active reste au verbe archive, G8 ; 6 tests
> préexistants n'étaient verts que par infidélité du harnais, réparés) ; un
> paramètre de build Jenkins **VIDE** est **retiré** de l'environnement
> (`${CHANGE_REF:-}` sous `set -u`, mesuré par le build #4).

### G7 — Le parcours du demandeur : une PR, un tableau de bord

ADR-081 tient : la décision est le **merge**, la PR est le tableau de bord. Le demandeur ne « lance pas un job de déploiement en rec » — il ouvre une **PR de promotion** portant `deploy.rec.yaml`, et le statut de l'apply y remonte. Le formulaire Jenkins reste une porte d'entrée ; il ne porte **aucune autorité**.

**Porte G7 :** une promotion complète `dev → rec → int → homol → prod`, chaque saut visible sur sa PR, chaque apply commenté avec son résultat et l'identité qui l'a porté.
**Contre-épreuve :** déclencher le job de promotion **sans** la PR mergée ⇒ refus (le gate Git est déjà celui-là : palier sans `deploy.<env>.yaml` mergé ⇒ skippé).

> **FAIT le 2026-08-27** — ADR-086, spec
> `docs/superpowers/specs/2026-08-27-g7-parcours-du-demandeur-design.md`.
> **Porte tenue par BUILDS Jenkins réels** : quatre PRs de promotion
> (`banking-demo/accounts-api` #22-25), builds `team-promote` #18 (rec, bob) /
> #19 (int, bob — « bob porte apply-int » lisible au build) / #20 (homol,
> carol, PV) / #24 (prod, oscar — itsm `approved` re-vérifié AU DISPATCH,
> `operator-deploy`, VOIE DIRECTE) ; GUID `14c2529e-…003` actif et identique
> sur les QUATRE paliers ; chaque PR porte plan / résultat (**demandée par /
> mergée par / portée par**) / statut build.
> **Contre-épreuves par builds** : #25 FAILURE `PAYLOAD_PERIME` (webhook forgé
> sur une PR JAMAIS mergée — la réconciliation Gitea fait foi, moteur jamais
> lancé, catalogue inchangé) ; #26 FAILURE `ITSM_NOT_APPROVED` (la MÊME PR
> verte en #24 refuse dès que le change repasse `draft`).
> **Hors-ligne** : wiring 160/0 (G7-a..g, ordre par mutation), env-chain 11/0,
> `make lint-ci` 8/8.
> **Livré en plus** : la voie du TERMINUS par POSITION (`TERMINUS_SANS_VOIE`,
> labctl refusé, `EFFECTIVE_VIA`) ; §6ter ITSM au dispatch de la chaîne
> d'équipe (trois refus distincts, fail-closed) ; ouverture du terminus =
> geste de credential (seed dérivé + `operator-deploy` étendu) ; le corps du
> refus produit remonte sur la PR (`return_content`).
> **LIMITE MESURÉE (builds #21/#23)** : l'importeur du PRODUIT réel refuse une
> archive fabriquée par le mock (« No assets found in the ACDL import file ») —
> le terminus du LAB est donc `wm-mock-prod` (homogène, direct) et le verbe
> réel→réel reste prouvé par ADR-079 ; chez un client tout-réel la question ne
> se pose pas. Restes nommés : approverGroup au merge (ADR-081), 4-yeux
> pipeline inerte sans build-user-vars, parité des moteurs = G8.

---

## Décisions client bloquantes

1. **dev et rec en autonomie du demandeur — à arbitrer contre l'art. 17(1)(b) du RTS DORA.** Le texte vise « tous les changements », sans palier exempté. Trois options : **(a)** `selfApproval` en dev seulement, rec exige un pair de l'équipe ; **(b)** dev **et** rec en autonomie, assumé et documenté comme risque accepté au titre de la proportionnalité (art. 4 DORA) ; **(c)** autonomie pour la **demande**, jamais pour l'**approbation**. C'est un réglage d'une ligne de `environments.yaml` — mais c'est une décision de conformité, pas une décision technique.
2. **Quels groupes annuaire** pour int, homol, prod — et faut-il du **N-de-N** (« homol exige équipe A **et** équipe B ») ? Ni GitHub ni GitLab ne l'expriment nativement ; notre `Gate` le peut, mais c'est du code à écrire.
3. **Forge cible.** Si le client est sur GitLab, `deploy_access_levels` / `approval_rules` portent G2 nativement et notre `DeployerGroup` devient une redondance de défense en profondeur. Sur Gitea, tout G2 repose sur notre moteur. Voir ADR-080.
4. **`homol` est-il un palier de promotion** (l'archive y transite, chaîne strictement linéaire) **ou un palier terminal parallèle à int** ? Le moteur actuel ne connaît que le linéaire.
5. **Sur quels paliers exiger la référence ITSM ?** Aujourd'hui prod seulement. Rien de vérifié ne l'impose ailleurs — c'est une politique interne à assumer comme telle.
6. ~~**Quel moteur gateway porte la chaîne CD — Ansible ou `labctl` ?**~~ **TRANCHÉ le 2026-08-26 : option (c), les deux, iso-sémantiques.** `ansible/roles/apim_*` reste le chemin **client** (celui qui a tourné E2E, celui dont dépend tout le self-service) ; `labctl` reste le chemin **lab/gouvernance** (celui des pipelines `Jenkinsfile`/`.prod`/`.rollback`, le seul qui porte les gates). **Le prix est payé, pas éludé** : le test de parité devient un livrable obligatoire — c'est G8. `DELIVERY-PROCESS.md` a été **corrigé le même jour** : la clause « Ansible = orchestrateur / labctl = moteur gateway unique (aucun `uri` de mutation wM dans les plays) » était fausse à l'écriture et démentie par 53 mutations REST mesurées ; elle est remplacée par le régime à deux moteurs et sa contrainte de parité, avec la mention explicite que « le binaire porte la politique » parle de la **décision**, jamais du **verbe**.

---

## Ce que ce GOAL ne fait pas

Il ne modifie rien. C'est le plan d'objectif ; l'implémentation suivra la méthode habituelle — spécification → plan → exécution par sous-agents avec portes de preuve et contre-épreuves. Et il ne propose **aucun** argument de conformité pour la topologie des gateways segmentées : cet argument a été cherché et **réfuté**, il ne doit pas réapparaître dans un livrable client sans nouvelle source.
