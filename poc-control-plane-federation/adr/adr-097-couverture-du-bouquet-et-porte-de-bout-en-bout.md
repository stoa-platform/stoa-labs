---
title: "ADR-097 — Une chaîne ne peut pas garantir qu'elle oppose tout ; elle peut garantir qu'elle ne se tait sur rien. La couverture du bouquet devient explicite, et la porte de bout en bout la mesure par des builds réels."
sidebar_label: "ADR-097 : la couverture du bouquet (P7)"
status: "Acté et prouvé le 2026-09-06 — voir le tableau de preuves en fin de document."
maturite_technique: "✅ `tasks/coverage.yml` partage le bouquet rendu par `labctl posture` en trois : ce que la chaîne SAIT opposer (`apim_pub_posture_opposed_by`, chaque entrée adossée à la tâche qui l'écrit ET la relit), ce qu'elle DÉGRADE (`mode: degrade` — l'axe reste gardé plus faiblement, la PR le dit), ce qu'elle REFUSE (`mode: refuse` — l'axe n'est gardé par rien). Une dimension exigée absente des deux tables fait REFUSER (`POSTURE_NON_OPPOSEE`). ⚠ CONSÉQUENCE : les cellules `VH` (mtls) et `internet` (threat-protection) ne sont plus publiables par la chaîne producteur."
date: 2026-09-06
adr_number: 97
note: "Jalon P7 du GOAL posture-par-exposition, et sa clôture. La porte de bout en bout devait vérifier que les six jalons précédents n'avaient pas produit de la documentation ; elle a trouvé que la chaîne appliquait quatre dimensions du bouquet sur six et se taisait sur le reste. Le jalon livre donc la porte ET ce qu'elle a trouvé."
lié: "[[adr-096-identite-appelant-refus-par-defaut]], [[adr-095-https-protocole-par-api-listener-par-environnement]], [[adr-094-policies-communes-global-policy-par-cellule]], [[adr-093-tag-de-posture-pose-par-la-plateforme]], [[adr-092-posture-dans-la-chaine-du-producteur]], [[adr-091-taxonomie-exposition-table-de-verite]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-079-deploiement-promotion-multienv-import-archive]]"
---

# ADR-097 — La couverture du bouquet, et la porte de bout en bout (P7)

## Contexte : ce qu'une porte de bout en bout est censée trouver

Le GOAL confiait à P7 une seule chose, et il l'avait écrite comme une menace :

> **Contre-épreuve de tout le GOAL :** un producteur qui édite son manifeste pour se déclarer moins exposé et moins critique qu'il ne l'est obtient **exactement la même posture**. Sinon, les six jalons précédents ont produit de la documentation.

Cette contre-épreuve-là passe (§4). Mais une porte de bout en bout qui se contente de vérifier ce qu'on lui a demandé de vérifier n'est pas une porte : c'est une récitation. En mesurant, sur la gateway réelle, **tout** ce qu'une API publiée par la chaîne porte réellement, on trouve autre chose.

## La prise du jalon : quatre dimensions appliquées, deux ignorées, zéro mot

`labctl posture` rend un bouquet **fini**. Pour la cellule `m-internal`, il vaut :

```
required_policies = [audit-log, https-only, oauth2, rate-limit]
```

Le rôle producteur en appliquait **quatre morceaux** — le tag (P3), la cellule commune qui porte `audit-log` et `rate-limit` (P4), le protocole d'entrée `https-only` (P5), l'identification de l'appelant (P6) — et **ignorait le reste en silence**. Une API `M/internal` recevait donc :

- le tag `posture:m-internal`, qui **affirme** le bouquet ;
- la cellule `posture-m-internal`, qui **affirme** le bouquet ;
- et **rien** qui exige d'elle un jeton OAuth2 validé sur audience, scope et client_id.

C'est mot pour mot le défaut que P6 avait trouvé une couche plus bas — un contrôle nommé dans la table de vérité, affiché au journal, et opposé par personne — sauf qu'ici il ne s'agit pas d'une primitive oubliée : **`mtls` et `threat-protection` ne sont PAS déclinables sur ce produit**, et les deux mesures qui l'établissent viennent de ce GOAL même.

La réponse ne pouvait donc pas être « poser la règle manquante ». Elle ne pouvait pas non plus être « publier quand même » : c'est la garantie de papier que le spike P0 a démontée. Elle est de **rendre la couverture explicite**.

## La décision

`ansible/roles/apim_publish_api/tasks/coverage.yml` s'exécute **immédiatement après `posture.yml`**, donc avant les secrets et avant le premier appel à la gateway — un refus de couverture ne doit rien laisser derrière lui. Pour chaque policy du bouquet, **une** de trois issues, jamais le silence :

| issue | table | ce qui se passe |
|---|---|---|
| **opposée** | `apim_pub_posture_opposed_by` | la chaîne l'écrit ET la relit ; la valeur de la table NOMME la tâche et son marqueur de relecture |
| **dégradée** | `apim_pub_posture_unopposed`, `mode: degrade` | l'axe reste gardé par un contrôle plus faible ; la publication passe, le journal ET le commentaire de PR portent `POSTURE_DEGRADEE` |
| **refusée** | `apim_pub_posture_unopposed`, `mode: refuse` | l'axe n'est gardé par rien ; publication **REFUSÉE**, nommée `POSTURE_NON_DECLINABLE`, avant toute écriture |

### La ligne de partage, et pourquoi ce n'est pas un arbitrage de confort

La question n'est pas « qu'est-ce qui nous arrange ». C'est : **l'axe est-il gardé par quelque chose, oui ou non**.

- `oauth2` **dégrade** : l'appelant est quand même identifié — par `jwtClaims`, signature seule, fusionnée dans la règle du stage IAM par P6. Le contrôle est plus faible que le bouquet ne l'exige ; il n'est pas absent.
- `mtls` **refuse** : aucune mesure ne l'oppose. Le `clientAuth` du listener n'est pas éditable sur la 10.15 (P5 : `PUT` 200 sans persistance, alias `ssos` partout), et poser une identification par certificat que le listener ne réclame jamais **recréerait exactement le contrôle décoratif que P6 vient de supprimer**.
- `threat-protection` **refuse** : `/policies` refuse de porter les actions correspondantes (HTTP 400 `NullPointerException`, deux filtres, deux portées — mesuré en P4) ; la seule surface qui les configure, `/administration/threatprotection`, est **gateway-wide** et ne peut donc pas différer d'une cellule à l'autre.

### L'anti-dérive, qui est la vraie valeur du jalon

Une policy exigée par un bouquet et absente des **deux** tables fait **REFUSER** (`POSTURE_NON_OPPOSEE`). Autrement dit : ajouter demain une dimension à la table de vérité de `labctl` sans apprendre à la chaîne à l'opposer **casse la publication** au lieu de la laisser publier une posture décorative.

C'est la seule forme d'exhaustivité qu'un rôle puisse honnêtement tenir : *il ne peut pas garantir qu'il oppose tout ; il peut garantir qu'il ne se tait sur rien.*

Un garde-fou complète la dégradation : `oauth2` ne dégrade que si **quelque chose** identifie encore l'appelant. Un manifeste sans volet inbound sur une cellule qui exige `oauth2` laisserait l'axe entièrement ouvert (P6 S1 : stage IAM vide = sert n'importe qui) — la dégradation deviendrait une absence, et une absence ne se tolère pas : `POSTURE_AUTHN_ABSENTE`.

## Conséquence à annoncer, et elle est lourde

> **Les cellules `VH` (toutes expositions) et `internet` (toutes classifications) ne sont plus publiables par la chaîne producteur.**

Avant ce jalon, elles se publiaient — en affichant une posture qu'elles n'avaient pas. C'est la même forme de conséquence que P5 (« l'API refuse le clair ») et P6 (« l'API refuse une IP non déclarée »), et elle appelle la même lecture : **ce n'est pas la plateforme qui casse, c'est le contrôle qui s'applique**. Trois issues, toutes de gouvernance, aucune technique :

1. **fournir le dispositif d'environnement** — un mTLS terminé en amont, un WAF pour `threat-protection` — et le déclarer, auquel cas la dimension quitte `apim_pub_posture_unopposed` pour rejoindre `apim_pub_posture_opposed_by` avec la tâche qui la vérifie ;
2. **choisir une autre cellule** pour l'API concernée, ce qui est une décision de classification, prise au registre central, par la gouvernance de la donnée ;
3. **assumer explicitement** la dégradation en basculant l'entrée en `mode: degrade` — geste visible, versionné, revu, et qu'une mutation de la matrice P7 surveille (§5).

La troisième existe parce qu'un client peut avoir raison contre nous ; elle est écrite pour qu'on ne puisse pas la prendre sans le dire.

## 4. La porte de bout en bout, et la contre-épreuve du GOAL

`scripts/test-p7-bout-en-bout.sh` joue la chaîne **entière**, par **builds Jenkins réels**, sur les dépôts réels et la webMethods 10.15 réelle :

```
formulaire api-request → PR sur le dépôt d'ÉQUIPE → merge par un SECOND humain
   → webhook Gitea → job team-publish → pause nominative (annuaire)
   → rôle apim_publish_api → API sur la gateway
```

Trois combinaisons d'exposition × classification (`M/internal`, `M/external`, `H/external`), et pour chacune, **mesuré** :

| dimension | mesure |
|---|---|
| **tag** | `apiDefinition.tags` porte `posture:<bouquet>`, **un seul** tag de l'espace réservé, et le tag **métier** du producteur survit |
| **cellule** | `GET /apis/{id}/globalPolicies` — ce que la **gateway** sélectionne, pas ce qu'on a écrit — vaut exactement `posture-<bouquet>` |
| **protocole** | `entryProtocolPolicy=[https]` relu **hors du rôle**, puis au plan de données : appel en clair refusé par le message du produit, appel HTTPS servi |
| **identité** | les dimensions du stage IAM relues hors du rôle, puis la porte différentielle ci-dessous |
| **inscription au port** | l'API est **servie** par le listener HTTPS d'environnement ; un témoin non gouverné répond 200 **en clair sur le même port**, ce qui dit exactement ce que le port vaut comme protection : rien |

### La porte différentielle : c'est la CELLULE qui décide, pas l'application

La mesure qui compte est celle-ci. **Une seule** application, souscrite aux deux APIs, portant **le même** identifiant `ipAddressRange` = l'IP réelle de l'appelant (donnée par `docker inspect`, jamais devinée) :

- l'API de la cellule **`external`** est **servie (200)** — sa règle accepte l'identification par plage ;
- l'API de la cellule **`internal`** **refuse le même appelant** — sa règle ne comporte pas cette dimension.

Même appelant, même identifiant, deux verdicts. La posture n'est donc pas une étiquette : elle décide au plan de données, et c'est la cellule gouvernée qui la fixe.

### La contre-épreuve du GOAL, dans ses deux sens

Le GOAL demandait « se déclarer moins exposé et moins critique donne exactement la même posture ». La chaîne, depuis ADR-092, a choisi de **refuser** plutôt que de corriger en silence — un désaccord avec la gouvernance doit être visible. La contre-épreuve se joue donc dans les deux sens, et les deux sont mesurés :

- **vers le bas** — ligne de registre `H/external`, formulaire `M/internal` : la publication est **refusée**, nommée `CLASSIFICATION_SPOOFED`, relayée sur la PR, et **rien n'est créé sur la gateway** (le refus précède la première écriture) ;
- **vers le haut** — deux APIs sur la **même** ligne de registre `M/internal`, l'une déclarée honnêtement, l'autre déclarée `VH/internal` : leurs **empreintes de posture** (tag ⊕ cellule ⊕ protocole ⊕ dimensions d'identification), relues sur la gateway, sont **identiques**. La sur-déclaration est acceptée, signalée, et **sans effet**.

Réunies : *le manifeste ne décide pas*. Mentir vers le bas est refusé ; mentir vers le haut ne donne rien de plus. C'est la formulation exacte que le GOAL cherchait, et elle est plus forte que celle qu'il avait écrite.

## 5. Ce que la matrice sait attraper (les mutations)

| sabotage | ce qui tombe |
|---|---|
| une dimension `refuse` passe en `degrade` | la cellule `VH` redevient publiable **en silence** — c'est la pente que ce jalon existe pour interdire |
| `https-only` retirée de ce que la chaîne déclare opposer | l'anti-dérive n'attrape plus rien : la publication passe au lieu de refuser `POSTURE_NON_OPPOSEE` |
| la garde du refus structurel neutralisée dans la tâche | `POSTURE_NON_DECLINABLE` disparaît |
| le relais de couverture retiré de `team-publish.sh` | la PR redevient muette sur ce que la chaîne n'oppose pas |

Chaque témoin est exigé **vert avant** le sabotage — sinon son rouge d'après prouverait sa propre panne, pas la garde (leçon payée en P2) — et chaque fichier est restauré **à l'octet près** (`cmp`).

## Ce que ce jalon ne fait pas

- Il **n'implémente pas** `oauth2` de bout en bout dans la chaîne producteur : la machinerie existe (`tasks/inbound.yml`, branche oauth2), c'est l'entrée de formulaire qui manque (audience, scope, client_id). La dégradation est donc **nommée**, pas résorbée.
- Il **ne rend pas** `mtls` ou `threat-protection` déclinables : les deux mesures qui l'interdisent sont dans P4 et P5, et aucune ligne de rôle ne les contredira.
- Il **ne touche pas** au chemin GitOps `labctl apply`, qui garde sa propre couverture et sa propre stratégie d'objet partagé (nommée dans ADR-096, toujours pas corrigée).

## Preuves

| Preuve | Commande | Résultat |
|---|---|---|
| Matrice P7 (builds réels) | `bash scripts/test-p7-bout-en-bout.sh` | *(voir le handoff du jour)* |
| Garde de couverture hors ligne | `ansible-playbook -i ansible/inventory.lab.ini ansible/test-coverage-guards.yml …` | jouée dans la matrice, sections D2/E |
| Porte de lint | `make lint-ci` | verte |
| Non-régressions P2..P6 | `scripts/test-p2…p6*.sh` | *(voir le handoff du jour)* |
