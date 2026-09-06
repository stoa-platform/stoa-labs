---
title: "ADR-096 — Le refus par défaut n'est pas un port : c'est l'identification de l'appelant par l'API. L'ip-allowlist d'une cellule `external` devient un contrôle opposé, et non plus un mot."
sidebar_label: "ADR-096 : l'identité de l'appelant (P6)"
status: "Acté et prouvé le 2026-09-06 — `go test ./...` **568 ✅ / 0 ❌** sur labctl (7 neuves), `go vet` propre ; matrice P6 **48 ✅ / 0 ❌** dès le premier passage, **rejouée à l'identique**, dont la porte au PLAN DE DONNÉES (403 hors plage / 200 dans la plage sur la MÊME API et le MÊME appelant), la contre-épreuve (règle retirée à plage inchangée → 200) et **4 mutations sur 4 visibles** ; spike P6 **49 ✅ / 0 ❌** en neuf verdicts."
maturite_technique: "✅ Le pipeline pose sur le stage `IAM` de la policy SERVICE UNE action `evaluatePolicy` — `allowAnonymous=false`, une `IdentificationRule` par dimension exigée — AVANT l'activation, avec relecture fail-closed à égalité STRICTE des DEUX côtés (`IDENTITE_NON_ATTACHEE`, `IDENTITE_NON_CONFIRMEE`). La dimension arrive FINIE de `labctl posture` (`caller_identity`), dérivée de la moitié PER-API du bouquet. Le pré-check d'apply et le read-back Go refusent désormais une cellule `external` dont la restriction réseau n'est opposée par rien. ⚠ Détacher une action la DÉTRUIT : le rôle refuse de toucher un objet PARTAGÉ (`ACTION_IAM_PARTAGEE`) et renvoie au play de conversion `ansible/is-iam-action-split.yml`."
date: 2026-09-06
adr_number: 96
note: "Jalon P6 du GOAL posture-par-exposition, dont la prémisse d'origine était TOMBÉE. Le mode d'accès d'un port de l'Integration Server garde `/invoke`, pas le dispatch `/gateway` : le jalon a été réécrit sur la surface qui garde réellement les APIs. Ce faisant il ferme un fail-open que le projet avait NOMMÉ en juillet (ADR-078) et laissé ouvert — la primitive Go existait, testée, et n'était appelée par personne."
lié: "[[adr-095-https-protocole-par-api-listener-par-environnement]], [[adr-094-policies-communes-global-policy-par-cellule]], [[adr-093-tag-de-posture-pose-par-la-plateforme]], [[adr-092-posture-dans-la-chaine-du-producteur]], [[adr-091-taxonomie-exposition-table-de-verite]], [[adr-078-livrable-self-service-app-wm1015]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-071-onboarding-partenaire]]"
---

# ADR-096 — L'identité de l'appelant, exigée par l'API (P6)

**Statut :** Acté et prouvé le 2026-09-06. Hors ligne : `go test ./...` **568 ✅ / 0 ❌**, `go vet` propre. Live : `scripts/test-p6-deny-by-default.sh` **48 ✅ / 0 ❌** sur la wM 10.15 réelle (`poc-webmethods-real`), dès le premier passage et rejouée à l'identique. Spike préalable : `scripts/spike-p6-deny-by-default.py` **49 ✅ / 0 ❌**, neuf verdicts.

## Contexte : une prémisse tombée, et un fail-open resté ouvert

Le GOAL confiait à P6 le « deny-by-default », et le plaçait sur le **mode d'accès d'un port**. Le spike B de P0 avait déjà réfuté cette prémisse : sur un listener en `deny` dont la liste ne mentionne pas l'API, `/invoke/<service non listé>` est bien refusé en **403**, mais **`/gateway/<api>/<version>/<ressource>` répond 200, réponse du backend comprise**. L'Access Mode de l'Integration Server garde les **services**, pas le **dispatch** de l'API Gateway. Le code de `tasks/port-access.yml` n'était donc pas seulement mort : il était **braqué sur la mauvaise surface**.

Le jalon avait deux issues, « réécrire ou fermer ». Ce qui a tranché n'est pas une préférence d'architecture, c'est un état des lieux :

> **P1 (ADR-091) fait de l'`ip-allowlist` la règle propre de l'exposition `external`. Le read-back rendait pour elle un verdict `degraded — enforced au consommateur`. Et le drapeau qui POSE réellement la règle (`EnforceInboundIdentifiers`, `consumer.go`) n'était positionné NULLE PART : ni CLI, ni manifeste, ni pipeline.** La primitive Go existait, elle était testée, et elle était morte — exactement comme `port-access.yml`.

Autrement dit, **chaque API `external` publiée par la chaîne portait un contrôle que rien n'opposait**, pendant qu'un verdict affirmait qu'il était appliqué ailleurs. ADR-078 avait nommé ce fail-open en juillet (« `ipAllowlist` décoratif ») et annoncé sa fermeture ; la moitié qui manquait est celle-ci.

Fermer P6 aurait laissé cet état tel quel. Le jalon a donc été **réécrit sur la surface qui garde vraiment le dispatch** : la règle d'identification de l'API.

## Ce que le spike a mesuré (2026-09-06, wM 10.15 réelle, 49/0)

| # | Question | Verdict |
|---|---|---|
| S1 | Une API fraîchement publiée refuse-t-elle quelque chose ? | **Non.** Son stage `IAM` est **vide** et elle sert n'importe quel appelant, **anonymement** (200). Il n'y a pas de refus par défaut à réveiller : il y en a un à **poser**. |
| S2 | L'identifier `ipAddressRange` posé sur l'application suffit-il ? | **Non — 200.** Application souscrite, allow-list écrite et relue, appelant HORS plage : **servi**. C'est le fail-open d'ADR-078, re-mesuré. |
| S3 | **LA PORTE** — la règle posée, l'appelant hors plage est-il refusé ? | **Oui : 403** hors plage, **200** dans la plage, sur la MÊME API et le MÊME appelant, et **403** depuis une AUTRE origine. Et un joker `0.0.0.0-255.255.255.255` **n'identifie personne** (403) : on ne peut pas « ouvrir » une allow-list. |
| S4 | **LA CONTRE-ÉPREUVE** — la règle retirée à plage inchangée ? | **200.** C'est donc bien la règle qui refusait, et non le port, le protocole ou l'association. |
| S5 | Le repli `sys:defaultApplication` rouvre-t-il la porte ? | **Non.** Une seconde application souscrite **sans** identifier ne résout pas l'appelant hors plage : le refus tient. |
| S6 | Partager une action entre APIs : économie, ou piège ? | **Piège, et le fait est dur.** Détacher l'action d'UNE API **la DÉTRUIT** (`GET` → 404) ; les autres policies gardent un **UUID mort**. Voir ci-dessous. |
| S7 | Peut-on empiler deux actions au stage IAM ? | **Non — HTTP 409.** Les dimensions se **fusionnent** dans un objet unique ; elles ne s'additionnent pas. |
| S8 | La règle est-elle posable sur une API **INACTIVE**, et survit-elle à l'activation ? | **Oui aux deux** — ce qui autorise la position choisie, et donc la promesse « une API gouvernée ne sert jamais un appel non identifié, pas même pendant sa publication ». |
| S9 | Survit-elle au ré-import de contrat ? | **Oui** (contrairement au tag de P3, qui s'efface) : une seule passe suffit, pas de relecture finale. |

### Le fait qui a commandé la forme : un détachement DÉTRUIT

C'est la découverte la plus lourde du jalon, et elle explique rétroactivement une panne connue.

`PUT /policies/{id}` en retirant une action du stage **supprime l'objet action**. La suite a été mesurée pas à pas :

- toute autre policy qui référençait cet objet garde son **UUID mort** ;
- son **plan de données continue de refuser** (403 mesuré) — donc **pas de fail-open** ;
- mais **sa prochaine activation échoue en HTTP 500** *« Policy action with ID … does not exist »* ;
- et un `PUT` de cette policy **citant une action VALIDE** est accepté (200) : c'est la sortie de secours.

C'est le mécanisme, jusqu'ici non identifié, du NPE que ce projet documentait depuis juillet comme « action supprimée mais référencée ». Personne ne l'avait supprimée : **il a suffi de la détacher ailleurs**.

Conséquence directe sur la conception : **une action d'identification ne doit être référencée que par UNE policy**. Le rôle donne donc à chaque API son objet propre, nommé d'après elle. Et comme la chaîne partageait jusqu'ici un objet par empreinte de règles, la conversion est un geste explicite : `ansible/is-iam-action-split.yml`, joué une fois par environnement.

## Décision

**1. Le refus par défaut vit sur le stage `IAM` de l'API, et nulle part ailleurs.** Une action `evaluatePolicy` avec `logicalConnector=AND`, `allowAnonymous=false`, et une `IdentificationRule` par dimension exigée. Un appelant qu'aucune dimension ne résout est refusé **par l'API**, quel que soit le port qui a porté l'appel.

**2. La dimension est DÉRIVÉE, jamais déclarée.** `labctl posture` rend `caller_identity` fini, dans le vocabulaire du produit, dérivé de la **moitié per-API** du bouquet (`render.CallerIdentityFor`). Le rôle l'écrit verbatim : il ne nomme aucune exposition, ne connaît aucune table de vérité, et une épreuve interdit qu'il en recopie une.

**3. Le couplage application/vérification est MÉCANIQUE.** Le jour où `ip-allowlist` passerait dans `commonCarriable`, `caller_identity` devient vide, le rôle cesse de poser — au lieu de laisser l'application partir vers un objet partagé pendant que `verifyIPAllowlist` continue de relire l'action IAM de l'API. `TestCallerIdentityFollowsTheHalfThatOwnsIt` l'épingle, sur le modèle exact de ce que P4 avait exigé de P5.

**4. La position est AVANT l'activation.** Mesuré posable sur une API inactive et survivant à l'activation (S8). Poser après ouvrirait une fenêtre — courte, réelle, invisible chez le client — pendant laquelle une API gouvernée servirait un appelant que personne n'a identifié.

**5. Un seul fichier écrit le stage IAM.** La création de l'action et son attachement ont quitté `inbound.yml` pour `caller-identity.yml`. Ce n'est pas du rangement : la gateway n'accepte qu'une action au stage (409, S7), donc deux fichiers qui l'écrivent, c'est le second qui gagne — et le contrôle perdu ne se voit nulle part. `inbound.yml` garde l'alias, la strategy OAUTH2 et le scope mapping, c'est-à-dire ce dont l'IAM a besoin pour mordre.

**6. Un objet PAR API, et un refus plutôt qu'une casse.** Le rôle ne détache jamais une action partagée : il refuse en la nommant (`ACTION_IAM_PARTAGEE`) et renvoie au play de conversion. Casser silencieusement la réactivation des APIs voisines pour publier la sienne n'est pas un compromis acceptable.

**7. Le verdict de complaisance disparaît.** `verifyIPAllowlist` lit l'action IAM et exige `allowAnonymous=false` **et** une règle `(strict, ipAddressRange)`. Absente, le verdict est **`missing`**, pas `degraded` : la gate refuse la publication. Et le **pré-check d'apply** refuse en amont une cible `external` qui ne déclare pas `inboundAuth.ipAllowlist`, plutôt que d'attester une barrière que personne n'a posée.

## Ce que ça change pour le client — à annoncer

- **Une API `external` gouvernée n'est plus joignable par un appelant dont l'IP n'est pas déclarée.** Comme pour le HTTPS de P5, ce n'est pas la plateforme qui coupe : c'est le contrôle qui s'applique. Mais sur un environnement où des consommateurs appellent depuis des adresses non recensées, **la première publication gouvernée les casse**. Le recensement des IP partenaires devient un préalable, et il est la contrepartie exacte du choix d'ADR-091 (`external` = partenaire énumérable).
- **`internet` n'exige AUCUNE allow-list, et c'est délibéré.** L'appelant public n'est pas énumérable ; la table de vérité y substitue `threat-protection`, dont l'écart #1 reste ouvert (question client : dispositif de la gateway, ou WAF en amont ?).
- **Un joker ne sauve rien.** `0.0.0.0-255.255.255.255` est mesuré non identifiant (403). On ne peut donc pas « désactiver » le contrôle en élargissant la plage — il faut retirer l'exposition `external`, ce qui passe par le registre central.
- **La conversion `is-iam-action-split.yml` est à jouer une fois par environnement**, avant la première publication gouvernée, sur le modèle du play d'amorçage des global policies de P4.

## Conséquences

- **Positif.** Le contrôle le plus structurant d'ADR-091 cesse d'être un mot. Le fail-open nommé par ADR-078 est fermé **dans la chaîne**, pas seulement dans une primitive. Le mécanisme du NPE `policyAction` est identifié, ce qui rend enfin la panne évitable au lieu de réparable. Et le stage IAM a désormais **un seul propriétaire**.
- **Négatif / coûts.** Un objet d'identification par API (prolifération bornée, assumée contre le risque de destruction croisée). Une conversion à jouer sur les environnements existants. Une rupture pour les appelants non recensés. Et le côté Go conserve, hors périmètre de ce jalon, sa stratégie d'objet **partagé** (`ensureMtlsIdentifyAction`, `ensureSelfServiceIdentifyAction`) : elle porte le même risque, elle est **nommée ici** plutôt que corrigée à la sauvette.
- **Non traité.** `tasks/port-access.yml` et `ansible/is-port-access.yml` restent en place : ils décrivent correctement une restriction de `/invoke`, qui est un durcissement d'environnement légitime — simplement sans rapport avec la posture des APIs. Ils ne sont plus présentés comme un contrôle d'API.

## Preuves

| Preuve | Commande | Résultat |
|---|---|---|
| Spike produit (9 verdicts) | `python3 scripts/spike-p6-deny-by-default.py all` | **49 ✅ / 0 ❌** |
| Matrice du jalon (A→D) | `bash scripts/test-p6-deny-by-default.sh` | **48 ✅ / 0 ❌** ×2, 4 mutations |
| Autorité + pré-check + read-back | `cd labctl && go test ./...` | **568 ✅ / 0 ❌** |
| Conversion des actions partagées, mode AUDIT | `ansible-playbook … ansible/is-iam-action-split.yml -e apim_split_converge=false` | s'exécute ; **1 action partagée trouvée** sur le lab (15 APIs, 26 policies, 3 actions IAM). La conversion elle-même est un geste d'exploitation, non joué ici. |
