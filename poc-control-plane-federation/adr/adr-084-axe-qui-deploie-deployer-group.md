---
title: "ADR-084 — L'axe « qui déploie » : deployerGroup, l'annuaire n°2, et un refus nommé au DISPATCH. La porte d'un palier déclare désormais QUI PORTE l'apply (deployerGroup, famille LDAP→policy Vault) à côté de QUI APPROUVE (approverGroup, claim Keycloak) ; l'enforcement vit aux deux sites de dispatch — jamais à l'approbation — parce qu'au moment du geste, la seule identité vérifiée disponible sur toutes les chaînes est le token Vault du porteur, et parce que le retrait d'un groupe ne révoque pas les tokens déjà émis."
sidebar_label: "ADR-084 : l'axe qui déploie (deployerGroup)"
status: "Acté et prouvé par les portes. Hors-ligne : test-env-chain.sh 6/6 (gabarit épinglé + 2 sabotages) ; go test governance/governance-api/labctl/vault tout vert (7 cas d'approbation par palier, 7+3 cas de preflight déployeur dont la voie --env any à deux familles, lookup-self fail-closed corps vide compris) ; test-team-promote-wiring.sh 137/0 (ordre des gardes par mutation, stub lookup-self, anti-dérive ldap). Live : test-deployer-gate-live.sh 21/0 (bob porte apply-int, alice ne porte rien, le grant SUIT l'annuaire — retrait ⇒ le token suivant ne porte plus la policy), make lint-ci 8/8. Restent nommés : /token-policies (--grant-ci) non prouvé live, un seul palier mesuré en positif live, fenêtre TTL non chiffrée, 4-yeux pipeline inerte (build-user-vars), parité des moteurs = G8."
maturite_technique: "✅ Mécanisme prouvé aux deux sites de dispatch avec les MÊMES codes de refus, et l'ordre « toutes les gardes avant le moteur » prouvé par MUTATION (suppression du bloc ET inversion 7.a/7.b). La mesure la plus précieuse est live : un token émis AVANT le retrait du groupe porte la policy jusqu'à son TTL (retrait ≠ révocation) — c'est l'argument mesuré qui JUSTIFIE le site d'enforcement (au dispatch, sur le token du geste, jamais un droit constaté plus tôt). Limite assumée : cette assertion épingle un comportement de Vault, pas notre code."
date: 2026-08-27
adr_number: 84
note: "Consomme ADR-082 (la rétention par palier : le groupe LDAP apim-apply-<env> → policy apply-<env> posé par G4, inerte jusqu'ici, devient l'annuaire de l'axe) et ADR-083 (le corollaire « un refus de porte est mécaniquement antérieur au play » s'applique au nouveau refus). Précise ADR-081 : l'APPROBATION reste le merge sous protection de branche ; ce que G2 ajoute est l'autre axe — le PORTEUR du geste. Répond à la décision n°3 du GOAL (sur Gitea, tout l'axe repose sur notre moteur ; sur GitLab, deploy_access_levels en serait la redondance native)."
lié: "[[adr-082-ouverture-palier-retention-credential]], [[adr-083-verbe-archive-deux-moteurs]], [[adr-081-ou-vit-la-decision-humaine]], [[adr-077-user-identity-to-vault-token-exchange]], [[adr-074-vault-secrets]]"
---

# ADR-084 — L'axe « qui déploie » : deployerGroup, l'annuaire n°2, un refus nommé au dispatch

**Statut :** Acté, prouvé par les portes (hors-ligne et live). **Maturité :** ✅ voir l'en-tête.

**Lié à :** [[adr-082-ouverture-palier-retention-credential]], [[adr-083-verbe-archive-deux-moteurs]], [[adr-081-ou-vit-la-decision-humaine]].

---

## Contexte

Le modèle `Gate` savait dire QUI APPROUVE (`approverGroup`, comparé à la claim
`groups` du jeton Keycloak vérifié) et PAS LUI (`fourEyes`) — jamais QUI PORTE
le geste d'apply. « À partir de l'int, cela doit être fait par une autre
équipe » n'était pas exprimable : le modèle GitLab (deploy_access_levels et
approval_rules, deux tableaux structurellement indépendants) n'avait pas
d'équivalent. Le contrôle effectif existait pourtant — la rétention de
credential d'ADR-082 (lire `envs/<env>/wm-admin` = le ticket d'entrée) — mais
sans DÉCLARATION : rien dans la chaîne ne disait qui devait porter l'apply, et
le refus effectif était un 403 Vault de capacité, illisible comme politique.

## Décision

1. **`deployerGroup` est un champ de `Gate`** (clé YAML `deployerGroup`),
   déclaré par palier dans `environments.yaml`. Le gabarit livré déclare
   `apim-apply-int` (int), `apim-apply-homol` (homol), `apim-operator-prod`
   (prod) ; `rec` ne déclare rien (autonomie du demandeur, décision client
   n°1 — la rétention ADR-082 y reste le seul « qui »).

2. **Le champ vit dans l'ANNUAIRE N°2** — LDAP → policy Vault — jamais la
   claim Keycloak. Deux axes, deux annuaires, chaque champ épinglé au sien :
   au moment du dispatch, la seule identité vérifiée disponible sur TOUTES les
   chaînes est le token Vault du porteur (nominatif sur la chaîne
   self-service, AppRole sur la chaîne machine) ; un jeton Keycloak n'existe
   pas sur la chaîne team-promote et n'y est pas fabricable. On ne crée pas de
   troisième canal d'identité : on déclare celui qui existe et on le rend
   refusable PAR NOM.

3. **La projection groupe→policy est une table à DEUX familles, fail-closed
   au-delà** : `apim-apply-<x>` → `apply-<x>` (la famille par palier posée par
   setup-vault-paliers.sh) ; `apim-operator-<x>` → `operator-deploy` (la
   famille du terminus, setup-vault-ldap.sh). Tout autre nom ⇒
   `DEPLOYER_GROUP_UNSUPPORTED` — BRUYANT, contrairement au piège silencieux
   d'`approverGroup` (mauvais annuaire = porte qui ne matche jamais). La table
   vit deux fois (Go : `Gate.DeployerPolicy()` ; shell :
   `deployer_group_policy`) — régime deux moteurs (ADR-083), chaque
   implémentation testée, écart = bug (l'épreuve G2(viii) du harnais wiring
   garde en plus la convention de bind des deux poseurs).

4. **Trois codes de refus, identiques dans les deux moteurs** :
   `DEPLOYER_GROUP_REQUIRED` (le token du porteur ne porte pas la policy
   projetée), `DEPLOYER_GROUP_UNSUPPORTED` (déclaration hors famille),
   `DEPLOYER_GROUP_UNVERIFIABLE` (porte déclarée mais identité invérifiable —
   VAULT_ADDR absent, lookup-self en échec, corps vide : fail-closed, on ne
   déploie pas ce qu'on ne sait pas vérifier).

5. **L'enforcement vit aux DEUX sites de dispatch, mécaniquement antérieur au
   verbe** (corollaire ADR-083) : `team-promote.sh` §7.a (la déclaration AVANT
   la rétention §7.b, toutes deux avant l'unique site moteur) et le preflight
   de `labctl apply-uac` (avant toute écriture gateway, même dérivation
   gated+enabled que l'anti-TOCTOU ITSM — la porte ne se contourne pas en
   omettant `--env`). Une porte sans déclaration ne coûte AUCUN appel Vault.

6. **governance-api n'évalue JAMAIS deployerGroup à l'approbation** — déployer
   est un acte de dispatch, pas d'approbation (c'est LE point du modèle
   GitLab). Il parse, sert (`GET /environments`) et MATÉRIALISE le champ dans
   l'évidence d'approbation (`gate.deployer_group`) pour que la PR et l'audit
   disent qui devait porter. `labctl dispatch-gate` (stage autonome de
   Jenkinsfile.prod) reste ITSM-only : son stage tourne avant le login Vault,
   il n'a pas d'identité de porteur à vérifier — le refus vit dans apply-uac,
   au moment où l'identité existe.

## La mesure qui fonde le site d'enforcement

La porte live a mesuré ce qu'aucune épreuve hors-ligne ne peut voir : **un
token émis AVANT le retrait du groupe porte la policy jusqu'à son TTL**
(retrait ≠ révocation — le motif « cache fantôme » déjà rencontré sur la
gateway, ADR de synchro IdP). La vérification DOIT donc se faire **au
dispatch, sur le token du geste** — jamais « à l'approbation » sur un droit
constaté plus tôt. C'est une assertion de la porte (elle rougirait si Vault
révoquait à chaud un jour), pas un commentaire. Corollaire non chiffré : la
fenêtre pendant laquelle un porteur écarté reste capable de déployer est
bornée par le TTL/max_ttl du token (un token renouvelé vit jusqu'à son
max_ttl) — courte dans le lab, à chiffrer chez un client.

## Conséquences

- **Prod force l'imputabilité.** Avec `deployerGroup: apim-operator-prod`
  déclaré, le repli AppRole de Jenkinsfile.prod (« acte non imputable ») est
  refusé fail-closed : déployer prod exige un humain du groupe, ou un grant
  EXPLICITE de la policy à un AppRole dédié (geste exploitant, jamais un
  défaut).
- **La machine se déclare, elle ne s'hérite pas.** `setup-vault-paliers.sh
  --grant-ci` accorde les policies `apply-<palier>` hors-prod à l'AppRole
  `ci-pipeline` — c'est la déclaration explicite que le CI gouvernance est un
  porteur hors-prod. Conséquence dite dans l'en-tête du script : sur int et
  homol, ce grant fait de la machine un chemin déployeur ALTERNATIF au groupe
  humain ; l'exclusivité humaine n'existe qu'au terminus (jamais granté,
  structurel). L'écriture passe par le sous-chemin `/token-policies`
  (read-modify-write + garde TTL_CLOBBER) — le POST racine du rôle aurait
  silencieusement réinitialisé les TTL éphémères d'ADR-074.
- **L'annuaire du lab se pose par un geste nommé.** `setup-deployer-groups.sh`
  pose les groupes dérivés de la chaîne (bob→int, carol→homol, surchargeables),
  vérifie l'existence de chaque uid déclaré (`MEMBRE_FANTOME` refusé — un typo
  rendrait un run vert sur un palier réellement fermé), distingue « uid
  absent » (rc 32) d'« annuaire injoignable » (`ANNUAIRE_INJOIGNABLE` — un
  diagnostic de porte ne ment pas), et joue la contre-épreuve alice (la
  demandeuse n'est déployeuse de rien, terminus compris).
- **Sans Vault, un palier déclaré refuse.** Tout pipeline qui atteint un
  palier à `deployerGroup` déclaré sans `VAULT_ADDR` passe de vert à
  `DEPLOYER_GROUP_UNVERIFIABLE` — c'est voulu, et c'est un changement de
  comportement à connaître avant de rejouer la chaîne gouvernance
  (geste : `--grant-ci` d'abord).

## Limites nommées (rien d'autre ne le dira)

- **Le 4-yeux pipeline reste inerte** tant que le plugin Jenkins
  build-user-vars manque (`promoted_by` vaut `ci`) — inchangé depuis G5,
  aucun faux refus.
- **`approverGroup` n'est toujours pas enforced au merge côté forge** : le
  contrôle du merge reste la protection de branche (ADR-081/G4). Le champ
  reste « attendu, pas vérifié » sur la chaîne self-service — c'est l'axe
  APPROBATION, hors G2.
- **`labctl apply` (flux manifeste OpenAPI, sans chaîne d'environnements)**
  reste un chemin d'écriture SANS porte déployeur — légitimement hors G2,
  mais c'est un chemin d'écriture à nommer.
- **La parité d'état des deux moteurs est G8** ; `/token-policies` n'est pas
  prouvé live ; un seul palier (int/bob) est mesuré en POSITIF live (homol et
  prod le sont en négatif via alice) ; le bout-en-bout « retiré de l'annuaire
  ⇒ le job Jenkins refuse » est couvert hors-ligne (137/0), pas par un build.
- **La projection est sensible à la casse** (un `apim-apply-Beta` projetterait
  `apply-Beta`, qui ne matchera jamais une policy Vault en minuscules —
  fail-closed mais déroutant) ; les annuaires du lab sont en minuscules.
