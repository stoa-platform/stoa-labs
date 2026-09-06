---
title: "P7 — la porte de bout en bout par builds réels, et ce qu'elle a trouvé : la chaîne appliquait quatre dimensions du bouquet sur six, et se taisait sur le reste"
type: handoff
jalon: P7
goal: GOAL-posture-par-exposition-2026-09-04.md
adr: adr/adr-097-couverture-du-bouquet-et-porte-de-bout-en-bout.md
date: 2026-09-06
status: "LIVRÉ — chiffres de preuve en fin de document."
---

# P7 — ce qu'il faut savoir en trente secondes

Le jalon devait vérifier que les six précédents n'avaient pas produit de la documentation. Il a fait mieux que vérifier : en mesurant, sur la gateway réelle, **tout** ce qu'une API publiée par le formulaire porte vraiment, il a trouvé **quatre défauts que six jalons de conception n'avaient pas vus** — parce qu'aucun d'eux n'était allé jusqu'au bout de la chaîne contre le produit réel.

> **La chaîne appliquait quatre dimensions du bouquet et ignorait les autres en silence.** Une API `M/internal` recevait le tag `posture:m-internal` et la cellule `posture-m-internal`, qui **affirment** `oauth2` — et rien ne l'exigeait d'elle.

C'est le défaut de P6 (`EnforceInboundIdentifiers` posé nulle part) une couche plus haut. La réponse ne pouvait pas être « poser la règle manquante » : `mtls` et `threat-protection` ne sont pas déclinables sur ce produit, et les deux mesures qui l'établissent viennent de ce GOAL même. La réponse est de rendre la **couverture** explicite, et de refuser ce qui sort du connu.

---

## Les quatre défauts trouvés par la porte, et ce qui a été fait

### 1. La couverture du bouquet était tacite — `tasks/coverage.yml`

Trois issues, jamais le silence : **opposée** (une tâche l'écrit ET la relit), **dégradée** (l'axe reste gardé plus faiblement — la PR le dit), **refusée** (l'axe n'est gardé par rien). Une dimension exigée absente des **deux** tables fait **REFUSER** (`POSTURE_NON_OPPOSEE`) : ajouter demain une dimension à la table de vérité de `labctl` sans apprendre à la chaîne à l'opposer **casse la publication** au lieu de publier une posture décorative.

*« Un rôle ne peut pas garantir qu'il oppose tout ; il peut garantir qu'il ne se tait sur rien. »*

**Conséquence à annoncer :** les cellules **`VH`** (mtls) et **`internet`** (threat-protection) **ne sont plus publiables par la chaîne producteur**. Avant ce jalon, elles se publiaient — en affichant une posture qu'elles n'avaient pas.

### 2. `approvers.yml` envoyait un corps que le produit refuse — HTTP 400

`PUT /apis/{id}` avec l'enveloppe `{"apiResponse": {"api": …}}` rend **400 « Both content stream and apiDefinition are empty »**. `tag.yml` (P3) avait déjà mesuré que ce champ veut l'**objet nu** ; `approvers.yml` était resté sur l'enveloppe. Personne ne l'avait vu parce que la tâche ne s'exécute **que si l'équipe déclare des approbateurs** : les harnais de P3..P6 publient sous un `providers.<env>.yml` à liste **vide**, et le seul bout-en-bout qui déclarait des approbateurs visait le **mock**, qui accepte les deux formes.

### 3. …et le champ n'est de toute façon pas écrivable — `owner` reste `Administrator`

Le corps corrigé passe (200), mais la relecture rend toujours `owner = "Administrator"`. La garde fail-closed faisait alors échouer **toute** publication d'une équipe déclarant des approbateurs. La recherche du GOAL l'avait établi (décision client n°2 : `owner` et `provider` sont en **lecture seule**) ; il restait à en tirer les conséquences dans le rôle.

La projection devient **opt-in** (`apim_pub_approvers_project`, défaut `false`) et le rôle **dit** ce qu'il ne fait pas : `APPROVERS_NON_PROJETABLE`. La liste reste autoritative là où elle est revue par PR — `providers.<env>.yml` —, et le développement qui la consomme doit la lire là, jamais sur l'objet API. Le chemin complet, read-back fail-closed compris, reste intact sous le drapeau pour une gateway qui accepterait le champ.

### 4. Une API publiée par le formulaire est FERMÉE À TOUS — et c'était invisible

Le mode `jwt` (seule valeur offerte par le formulaire) pose une identification par **`jwtClaims`**. Mesuré au plan de données, avec un **jeton réel** de l'IdP du lab et une **application souscrite portant un identifiant de claim** qui matche ce jeton (`azp`, puis `iss`, puis `sub`, en `jwtClaims` puis en `openIdClaims`) : **401 « Unauthorized application request » dans les quatre cas.**

Deux explications restent ouvertes — l'identifiant de claim est décoratif (l'identité runtime de la 10.15 vient de la **stratégie OAuth2**, `azp == clientId`, que seul le mode `oauth2` configure), ou l'alias d'auth-server n'est **lié** à l'API que par cette même stratégie, si bien que la gateway ne peut pas valider le jeton. **Ce qui est établi est le résultat, pas la cause** : la discrimination n'a pas été faite, et ce handoff ne la présente pas comme faite.

Conséquence : la dégradation `oauth2` **ne relâche rien, elle ferme**. Sans risque de sécurité (fail-closed), et inutilisable en l'état. C'est écrit tel quel dans la raison de la table, et la PR le porte.

---

## La porte, littéralement

`scripts/test-p7-bout-en-bout.sh` joue la chaîne entière par **builds Jenkins réels**, sur les dépôts réels et la webMethods 10.15 réelle :

```
formulaire api-request → PR sur le dépôt d'ÉQUIPE → merge par un SECOND humain
   → webhook Gitea → job team-publish → pause nominative (annuaire)
   → rôle apim_publish_api → API sur la gateway
```

Trois combinaisons d'exposition × classification, et pour chacune : le **tag**, la **cellule** telle que la *gateway* la sélectionne, le **protocole** relu hors du rôle, les **dimensions d'identification**, et l'**inscription au port**.

### Ce que l'attribution exige, et qui a coûté une réécriture

Le premier passage attendait qu'une API `external` **serve** un appelant dont l'IP est déclarée. Elle rend 401 — et pour deux raisons cumulées, aucune n'étant un défaut :

- la règle de P6 a le connecteur **`AND`** : `external` exige `ipAddressRange` **en plus** de la dimension inbound, elle ne la remplace pas ;
- et la dimension inbound, en mode `jwt`, n'est résolue par personne (défaut n°4).

La porte a donc été refondée sur ce qui est vrai **et attribuable** : un **témoin** publié par le rôle *sans* gouvernance et *sans* volet inbound répond **200 sur les deux canaux, sur le même listener, depuis le même appelant*. Sans lui, le 500 en clair et le 401 en HTTPS ne prouveraient rien de plus que l'existence d'un pare-feu quelque part.

Et le différentiel de cellule est mesuré **là où il est observable** — sur la règle elle-même : `external` exige la dimension réseau, `internal` ne l'exige pas. L'affirmer au plan de données, où les deux refusent pour la raison ci-dessus, aurait été un vert vacant.

### La contre-épreuve du GOAL, dans ses deux sens

- **vers le bas** — registre `H/external`, formulaire `M/internal` : refus **`CLASSIFICATION_SPOOFED`**, relayé sur la PR, **rien créé sur la gateway** ;
- **vers le haut** — deux APIs sur la **même** ligne `M/internal`, l'une déclarée honnêtement, l'autre `VH/internal` : **empreintes de posture identiques** (tag ⊕ cellule ⊕ protocole ⊕ dimensions d'identification), relues sur la gateway.

Réunies : *le manifeste ne décide pas*. Mentir vers le bas est refusé ; mentir vers le haut ne donne rien de plus.

---

## Pièges de harnais rencontrés (et payés)

- **`POST /apis` en JSON nu est cassé sur la 10.15** : le préflight d'égalité des vues (« l'agent et le harnais voient-ils la MÊME gateway ? ») créait son objet témoin par cette route et échouait — un refus juste, pour une raison qui n'était pas celle qu'il mesure. Le témoin est désormais une **application**.
- **La fenêtre keepalive est de ~24 min, pas 20** : le cron `*/5` ne recycle qu'au premier tick où l'uptime atteint le seuil. Un seuil d'attente à 11 min faisait attendre le harnais **13 minutes** pour rien ; il est passé à 15.
- **`set -o pipefail` + `play | grep -q` sur un play qui REFUSE** rend le code du **play**, jamais celui de grep : les témoins de mutation seraient rouges en permanence, donc muets. On capture, puis on greppe (piège déjà payé en P2 et A4 — il revient dès qu'on observe un refus).
- **Le commentaire de PR est posé par le bloc `post{}`**, donc APRÈS le `FINISHED` de `wfapi` : lire la PR sans attendre `building=false` (puis un court délai) rend un commentaire de la passe précédente.
- **`printf` et les séparateurs** : la spec OpenAPI est multi-lignes ; tout séparateur textuel (retour à la ligne, `\0` via `printf`) finit par couper une valeur en paires bancales dont Jenkins fait des paramètres vides. Le corps du formulaire se compose depuis l'**environnement**, pas depuis un flux séparé.

---

## Ce qui reste

- **`oauth2` au formulaire** — l'entrée manquante (audience, scope, client_id) est ce qui sépare une API publiée d'une API joignable. C'est le prochain travail utile de la chaîne producteur, et il est maintenant **nommé** au lieu d'être invisible.
- **Discriminer la cause du défaut n°4** — identifiant de claim décoratif, ou alias non lié ? Un spike d'une heure, et il ne change pas la conduite à tenir.
- **Les cellules `VH` et `internet`** restent indéployables par la chaîne : décision de gouvernance, pas dette technique.
- **Le chemin GitOps `labctl apply`** garde sa propre couverture et sa stratégie d'objet partagé (nommée en ADR-096, toujours pas corrigée).

---

## Preuves

*(complété à la fin du passage — voir la section « Preuves » de l'ADR-097)*
