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

## Extension 2026-09-02 (A4, GOAL cd-applications) — le second objet, et la porte entière

L'axe déployeur de cet ADR ne servait que la promotion d'API (`team-promote.sh` §7.a, preflight d'`apply-uac`). L'apply d'**application** (`provision-apply` → `selfservice-app-deploy`) ne lisait `environments.yaml` **nulle part** : ni `deployerGroup`, ni `fourEyes` (la garde d'identité exigeait toujours les quatre yeux — inertes, la PR étant ouverte par le compte de service `ci`), ni les références, ni l'ITSM. A4 branche la porte entière sur le second objet, sans mécanisme neuf :

- **La porte est un script joué DEUX fois par l'amont** (`scripts/provision-apply-gate.sh`, la §6/§6bis/§6ter de `team-promote.sh`) : **avant la pause** (un refus ne réveille personne) et **au dispatch**, après la réponse humaine (« approuvé hier n'est pas approuvé maintenant », ADR-075 — c'est ce passage qui nourrit la garde d'identité et le rapport). Elle ne parle qu'à la chaîne (chemin **épinglé** sur le clone par la ligne d'appel : une globale `STOA_ENV_CHAIN_FILE` ne redirige plus la politique) et, si la porte le déclare, à l'ITSM. Ordre = la propriété : forme → **`env_chain_validate`** (`CHAINE_INVALIDE` — une porte `to: itn` ou une clé mal orthographiée ne relâche rien en silence ; lecteur additif de la lib, plus strict que le parseur Go sur les clés inconnues, écart enregistré) → porte (`DEPLOYER_GROUP_UNSUPPORTED` hors famille **ou** `apim-apply-<x>` qui ne nomme pas le palier de sa porte) → références relues sur le manifeste **mergé** (`GATE_REFS_REQUIRED`, `REF_INVALIDE`) → quatre yeux **fail-closed sur un demandeur de service** (`REQUESTER_UNKNOWN` : la forge ne nomme aucun humain — une porte à quatre yeux qu'on ne peut pas vérifier refuse ; `FOUR_EYES_VIOLATION` par la garde existante, même normalisation) → ITSM (`ITSM_NOT_CONFIGURED` / `ITSM_NOT_APPROVED` / `ITSM_UNAVAILABLE`) → **terminus par position** (`TERMINUS_SANS_VOIE` avant la pause : personne n'est réveillé pour un apply sans voie).
- **`deployerGroup` est vérifié à l'aval, sur le token de la pause** — le seul site qui le tient (l'amont n'a aucun token ; retrait ≠ révocation impose le token du geste) : `scripts/selfservice-palier-gate.sh` gagne une **§2bis** entre l'équipe (§2) et les capacités (§3), **avant le ticket** (la parité de §7.a < §7.b) : mêmes trois codes, ligne de console identique (`déclaration déployeur : '<user>' porte '<policy>' (groupe '<groupe>')`). Le tag de refus remonte jusqu'à la PR (`REFUS_OUT` → `post{always}` de stage → `buildVariables`, fait Jenkins 11 mesuré).
- **`approverGroup` reste matérialisé, vérifié par personne** — sur la console, dans `GATE_OUT`, sur la PR, avec la mention « non vérifié : aucun mécanisme ne le tient sur cette chaîne » (la protection de branche du lab ne borne que le push direct). **Et sur les deux chaînes Gitea, approuver = porter** : `MERGER_MISMATCH` impose que l'identité de la pause soit le mergeur, §2bis/§7.a exigent que ce token porte la policy du déployeur — le mergeur d'`int` doit être membre d'`apim-apply-int`. La séparation approbation/mise en œuvre y est tenue par **demandeur ≠ mergeur** (les quatre yeux, désormais fail-closed), pas par deux groupes ; « deux personnes distinctes chez un client » ne vaut que pour la chaîne governance-api. Un modèle à trois identités est une décision d'ADR sur la pause.

**Conséquences dites** : sur les voies livrées (PR ouvertes par `ci`), `int` refuse `REQUESTER_UNKNOWN` tant que la PR n'est pas ouverte sous une identité humaine de forge (A7) — la porte inerte devient fermée ; `rec` est **relâché** au sens où la porte le déclare (`selfApproval`) ; `homol` refuse `GATE_REFS_REQUIRED` tant que la demande ne porte pas `pv_ref` ; le terminus est refusé par position **après** l'ITSM (« ITSM au terminus » mesurable avant A7). Sur le lab mono-gateway, appliquer `int` **écrase** l'état `rec` du même objet (un objet par nom).

**Preuves** : hors ligne `scripts/test-provision-apply-a4.sh` (fixtures git, stub ITSM canari, enregistreur, shim git, fragment de la garde EXÉCUTÉ, mutations — `make lint-ci` [13/13]) et les cas additifs de `test-selfservice-palier-a3.sh` (§2bis, `REFUS_OUT`, mutation d'ordre mesurée au journal) ; live `scripts/test-a4-live.sh` (builds réels — voir le GOAL). Spec : `docs/superpowers/specs/2026-09-02-a4-portes-de-la-chaine-au-dispatch-design.md`.

## Extension 2026-09-03 (A7, ADR-090) — sous une déclaration de déployeur, l'équipe vient de Git

Le déployeur nommé par la porte n'est pas un tenant (bob, carol, oscar : équipes release, opérateur de prod). Lui exiger la policy `deploy-<tenant>` refuserait tout déploiement par une équipe release, ou donnerait à l'opérateur de prod la policy d'ÉCRITURE de chaque tenant. La garde du palier (`selfservice-palier-gate.sh`) enchaîne donc : la porte lue → **la déclaration prouvée** (§2bis, inchangée : `DEPLOYER_GROUP_REQUIRED` avant toute décision) → **l'équipe** (§2ter) : sous une déclaration prouvée, `team:` du manifeste mergé (figée à la première demande, A1), `TEAM_INDETERMINEE` si absente (jamais le tenant du déployeur du moment), `TEAM_DIVERGENTE` si `APIM_TEAM` discorde, `TEAM_NON_ATTESTEE` si aucun palier sans déclaration n'est déclaré ; les tenants du porteur sont journalisés. Sans déclaration, A3 tient (le token décide). La décision client n°4 (« qui porte `apply-prod` pour les applications ? ») devient un pur choix d'annuaire. Prouvé hors ligne (`test-selfservice-palier-a3.sh` A.46-A.53, A.M9/A.M10) et par builds (`test-a7-live.sh` : bob porte `int`, carol `homol`, oscar `prod` d'une application `banking-demo`).
