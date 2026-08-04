---
title: "Palier 2 — deux formulaires Jenkins : onboarder une équipe, créer une application. La saisie est humaine, la décision reste le merge (spécification)"
type: spec
status: "Cadré le 2026-08-04 (trois questions tranchées par l'utilisateur : deux formulaires séparés ; coexistence formulaire/OIG-CLI2 sur le même aval ; token Gitea dédié exercé au merge). À valider avant plan d'implémentation. Un prérequis Vault bloquant est identifié au §8."
date: 2026-08-04
lié: [2026-08-03-onboarding-equipe-design, adr-076-gitops-api-lifecycle-repo-per-project, adr-078-livrable-self-service-app-wm1015, adr-081-ou-vit-la-decision-humaine, HANDOFF-2026-08-04-ONBOARDING-EQUIPE, HANDOFF-PROVISIONING-CHAIN]
---

# Palier 2 — formulaires Jenkins (spécification)

## En une phrase

Le palier 1 a donné le moteur (rôle `apim_team_onboard`, `providers.<env>.yml`,
chaîne de provisioning applicative prouvée) ; ce palier lui donne ses deux portes
d'entrée humaines — un formulaire « onboarder une équipe » qui initialise aussi le
dépôt Git, un formulaire « créer une application » — sans déplacer d'un millimètre
le point de décision, qui reste le merge (ADR-081).

---

## 1. Terrain — ce qui existe, mesuré le 2026-08-04

- **La chaîne applicative est complète mais sans porte humaine.** Quatre jobs
  (`provisioning-request`, `provision-plan`, `provision-apply`, `carto`), dont un
  seul paramétré (`carto`, hors sujet). La création d'application se déclenche par
  un appel OIG/CLI2 sur l'API `provisioning` de la gateway — jamais par une saisie.
- **`provision-request.sh` ne crée jamais de dépôt.** Il clone un dépôt EXISTANT
  (défaut `ci/stoa-labs`), pose une branche `provision/<app>-<env>`, commite le
  manifeste, ouvre la PR. « Initialiser le git » est un manque réel.
- **Le token Gitea actuel ne le pourrait pas** : user de service `ci`, scopes
  `write:repository` + `write:issue` — pas de création de dépôt sous une
  organisation. Arbitrage explicitement reporté au palier 2 par le spec du
  palier 1.
- **Les chaînes se séparent par préfixe de branche, par construction.**
  `provision-plan.sh:44` et le job apply ignorent tout ce qui n'est pas
  `provision/*`. Un espace `onboard/*` cohabite sans collision ni modification de
  l'existant.
- **ADR-081 fixe la forme** : « le demandeur remplit le formulaire ; le même build
  crée la PR et affiche le plan ». La PR est la pièce d'audit ; le CI n'autorise
  pas, il exécute ce que Git a décidé. La garde d'identité du valideur
  (`assert-merge-identity.sh`, 14/14) est déjà câblée dans `provision-apply`.

## 2. Décisions de cadrage (tranchées par l'utilisateur, 2026-08-04)

| Décision | Retenu |
|---|---|
| Forme | **Deux formulaires séparés** — « onboarder une équipe » et « créer une application » |
| Articulation avec OIG/CLI2 | **Coexistence, même aval** : deux portes (humaine, machine) convergent vers le même `provision-request.sh` — une seule chaîne à maintenir et auditer |
| Privilège de création de dépôt | **Token org-admin dédié, stocké dans Vault, lu par le seul job post-merge.** Le formulaire n'ouvre qu'une PR ; le dépôt naît après la décision humaine. Le job exposé à la saisie ne porte pas le privilège |

Architecture retenue (option A) : **miroir de la chaîne prouvée, espace de noms
parallèle**. Le motif demande→PR→plan→merge→apply est dupliqué sous `onboard/*`
au lieu d'être modifié. Chaque job porte exactement une autorité. Rejeté : un job
unique à paramètre TYPE (deux autorités dans un même job, audit trouble) ;
replier la création de dépôt dans `provision-apply` (élargirait les privilèges du
job atteint par la porte gateway — contredit la décision « token dédié »).

---

## 3. Formulaire 1 — `team-request` (onboarder une équipe)

| Champ | Type | Validation à la saisie |
|---|---|---|
| `TEAM` | texte | regex du rôle : `^[a-z0-9][a-z0-9-]{1,30}\Z` — refus AVANT tout geste Git, message `TEAM_NAME_INVALID` identique à `resolve.yml` |
| `DESCRIPTION` | texte | libre |
| `APPROVERS` | texte | matricules séparés par virgules ; **vide accepté** (cas `payments-team` : la projection ne fera rien, comportement voulu) |
| `REPO` | texte | full-name `org/nom` ; défaut dérivé `<team>/apis`, surchargeable |
| `ENV` | choix | `dev` seul actif au palier 2 ; `rec/int/prod` listés mais gardés |

Ce que le build fait, dans l'ordre :

1. clone du dépôt plateforme ; **ajout** de l'entrée dans `providers.<env>.yml` —
   équipe déjà déclarée → échec `TEAM_ALREADY_DECLARED`, jamais d'écrasement
   silencieux ;
2. branche `onboard/<team>-<env>`, commit par l'identité de service `ci`, push,
   PR ;
3. **le « plan » (ADR-081, corollaire 1)** : le build joue les gardes hors ligne
   existantes contre le fichier modifié — garde du nom, `TENANT_ROOT_UNSAFE`,
   dérivations — et commente sur la PR : ✅/❌, les quatre noms dérivés
   (`svc-<team>`, `<team>-devs`, `deploy/<team>/wm-admin`, `deploy-<team>`), le
   dépôt qui sera créé, les objets qui seront posés.

Le demandeur voit tout au même endroit. La décision reste le merge, protégé par
la branche (4-yeux).

## 4. Formulaire 2 — `app-request` (créer une application)

Zéro script nouveau : le job mappe ses champs sur les variables que
`provision-request.sh` attend déjà, et toute la chaîne aval (plan sur PR
`provision/*`, merge, apply nominatif) est réutilisée sans une ligne.

| Champ | → variable |
|---|---|
| `APP` | `REQ_APP` |
| `ENV` (choix) | `REQ_ENV` |
| `API` / `API_VER` | `REQ_API` / `REQ_API_VER` |
| `CLIENT_ID` (optionnel) | `REQ_CLIENT_ID` |
| `MODE` (choix `idp` \| `internal`) | remplace la dérivation depuis `REQ_CALLER` |
| — | `REQ_CALLER=jenkins-form:<userId>` — traçabilité : l'identité Jenkins du demandeur remplace `oig-provisioner`/`cli2-provisioner` |

**Point à vérifier à l'implémentation, pas à supposer** : `REQ_CLIENT_ID` est
requis par le script (azp de l'appelant machine). Pour une saisie humaine en mode
`internal`, il n'y a pas de client appelant — proposition : optionnel au
formulaire, valeur convention (`none-form`) quand vide, à condition de vérifier
que le script la tolère en mode internal. Si le script exige plus, l'assouplir se
fait dans le script, pas en inventant un faux client. Même classe pour `MODE` :
aujourd'hui le script dérive le mode du `REQ_CALLER` (`oig→idp`, `cli2→internal`) ;
un `REQ_MODE` explicite, prioritaire quand présent, est à ajouter au script — une
variable de plus, la dérivation existante restant le repli pour la voie machine.

## 5. `team-apply` — le job post-merge

Miroir exact du motif de `provision-apply` : webhook GWT filtré `closed|merged`,
garde de branche `onboard/*` (symétrique du `hors provision/* — rien à
appliquer`). Deux gardes avant tout geste :

1. **identité du valideur** : `assert-merge-identity.sh` réutilisé tel quel — le
   `merged_by` doit être un humain, pas le compte de service ; défense en
   profondeur, la protection de branche restant le contrôle principal ;
2. **anti-TOCTOU** : le job ne lit PAS le payload du webhook. Il checkout `main`
   au SHA du merge et lit `providers.<env>.yml` TEL QUE MERGÉ. Ce qui a été décidé
   dans Git est ce qui est appliqué.

Puis, dans l'ordre :

1. **création du dépôt Gitea** depuis le squelette ADR-076 (`clients/_example/` :
   `apis/`, `applications/`) — token org-admin lu dans Vault (chemin dédié,
   jamais dans les credentials Jenkins, jamais en argv : motif header-file).
   **Idempotent** : dépôt existant → étape sautée avec mention dans le
   commentaire, pas un échec ;
2. **`onboard-team.yml -e apim_onb_team=<team>`** — le rôle est idempotent et
   prouvé (palier 1) ;
3. **commentaire sur la PR** avec le statut réel : dépôt créé/existant,
   `ONBOARD_OK` ou l'étape fautive. La PR est le tableau de bord (ADR-081,
   corollaire 2) — succès ET échec y remontent.

Ordre dépôt-puis-rôle : les deux étapes sont individuellement idempotentes ; un
dépôt sans équipe comme une équipe sans dépôt sont des états inoffensifs qu'un
re-run résorbe.

**Identité Vault de l'onboarding — voir prérequis bloquant au §8.** Le motif
retenu est celui de `provision-apply` : build en `PAUSED_PENDING_INPUT`, identité
nominative de l'opérateur plateforme.

## 6. Gestion d'erreur — la règle unique

Tout échec est **bruyant, nommé, et visible depuis la PR**. Aucune étape n'avale
une erreur pour continuer.

| Échec | Comportement |
|---|---|
| Nom d'équipe invalide au formulaire | refus AVANT tout geste Git — aucune branche, aucune PR ; `TEAM_NAME_INVALID` |
| Équipe déjà déclarée | `TEAM_ALREADY_DECLARED`, build rouge, rien de poussé |
| Gardes hors ligne rouges au « plan » | PR ouverte AVEC le ❌ commenté — le valideur voit le refus motivé et ne merge pas ; rien d'appliqué |
| Merge par le compte de service | `team-apply` refuse (`assert-merge-identity.sh`) |
| Création du dépôt échoue | commentaire ❌ nommant l'étape, build rouge, le rôle n'est PAS joué |
| Onboarding échoue | commentaire ❌ avec le message fail-closed du rôle ; re-run possible, tout est idempotent |
| Vault/gateway injoignable | l'échec du rôle remonte tel quel — pas de retry silencieux |

## 7. Preuves — matrice X/X, format maison

`scripts/test-team-onboarding-chain.sh` sur le modèle des scripts existants
(compteurs PASS/FAIL, exit non nul), contre le **vrai Gitea du lab** (org
jetable), le **vrai Vault**, et le mock gateway :

| # | Ce qui est prouvé |
|---|---|
| 1 | Formulaire avec nom `../evil` → refus avant tout geste, **aucune branche créée** (vérifié par listing) |
| 2 | Équipe déjà déclarée → `TEAM_ALREADY_DECLARED`, aucune PR |
| 3 | Nominal → PR ouverte, plan commenté avec les quatre noms dérivés |
| 4 | Merge par le compte de service → refus d'identité, **rien d'appliqué** |
| 5 | Merge humain → dépôt créé depuis le squelette, `ONBOARD_OK`, statut sur la PR |
| 6 | **Re-run de `team-apply` → converge** : dépôt existant sauté, rôle `changed=0` |
| 7 | Formulaire application → même PR `provision/*` que la voie OIG (on prouve la porte, l'aval est déjà prouvé) |
| 8 | Token org-admin jamais en argv (sondage `ps`) ni dans les logs |
| 9 | Suppression symétrique de l'org et de l'équipe jetables — rien d'orphelin |

La preuve 6 est l'équivalente de la douve du palier 1 : elle distingue « le job a
tourné » de « le job converge ».

Leçons du palier 1 applicables d'office : contre-épreuve pour chaque garde (la
voir rougir avant de la croire) ; aucun littéral de secret dans les `.sh` (la
garde du dépôt scanne, clé = (fichier, variable)) ; toute cible réseau explicite,
sans valeur par défaut pointant sur un système en service ; un `changed=0` ne
prouve rien sans le `changed=1` qui le précède.

## 8. Prérequis bloquants et hors périmètre

**Prérequis bloquant n°1 — l'identité Vault de l'onboarding.** Le rôle écrit
`sys/policies/acl/deploy-<team>` et l'entrée KV ; toutes les preuves du palier 1
ont utilisé le token root du lab, ce qui n'est pas livrable. Requis : une policy
plateforme `team-onboarder` (écriture sur `sys/policies/acl/deploy-*` et sur
`secret/data/stoa/deploy/+/wm-admin`) accordée à l'identité nominative de
l'opérateur, posée par un script d'amorçage versionné — pas cachée dans un job.

**Prérequis bloquant n°2 — le token org-admin Gitea.** À minter (user de service
dédié ou token d'org), à stocker dans Vault sous un chemin plateforme, lisible
par la seule policy du job `team-apply`.

**Hors périmètre, explicitement** : les environnements `rec/int/prod` du
formulaire équipe (listés mais gardés) ; le remplacement du développement custom
de notification des approbateurs ; la surface d'approbation runtime (spec dédié à
venir, cf. palier 1 §6) ; toute modification de la chaîne applicative existante.

## 9. Décisions actées

| Décision | Pourquoi |
|---|---|
| Deux formulaires séparés | Choix utilisateur ; chaque job porte une autorité et un audit lisibles |
| Coexistence formulaire/OIG-CLI2 sur le même aval | Une seule chaîne à maintenir ; la porte machine du scénario cible reste intacte |
| Token org-admin dédié, exercé au merge seulement | Rien d'irréversible avant la décision humaine ; le job exposé à la saisie ne porte pas le privilège |
| Espace de noms `onboard/*` parallèle à `provision/*` | Les chaînes s'ignorent par construction (garde de branche existante) — zéro modification de l'existant |
| Le « plan » d'équipe = les gardes hors ligne du rôle | Réel et gratuit : ce sont les gardes qui protégeront l'apply, montrées au valideur avant le merge |
| Anti-TOCTOU : lire `main` au SHA du merge, pas le payload | Ce qui a été décidé dans Git est ce qui est appliqué |
| Dépôt créé AVANT le rôle | Deux étapes idempotentes ; états intermédiaires inoffensifs, re-run convergent |
| `REQ_CALLER=jenkins-form:<userId>` | La traçabilité de l'appelant survit au changement de porte d'entrée |
| Identité nominative pour l'apply équipe (pause) | Miroir du motif prouvé de `provision-apply` ; le prérequis Vault est déclaré, pas caché |
