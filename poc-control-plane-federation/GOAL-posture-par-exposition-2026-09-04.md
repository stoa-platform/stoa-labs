---
title: "GOAL — La posture de sécurité dérivée de l'exposition : un port HTTPS en deny-by-default, des policies communes portées par une global policy, et un tag que le demandeur ne choisit pas"
type: goal
status: "SOLDÉ le 2026-09-06 — HUIT jalons P0..P7, TOUS LIVRÉS. **P0 et P1 LIVRÉS le 2026-09-04 ; P2 et P3 LIVRÉS le 2026-09-05 ; P4, P5, P6 et P7 LIVRÉS le 2026-09-06.** P7 (ADR-097) tient la porte de bout en bout par BUILDS RÉELS et la contre-épreuve dans ses deux sens ; il a par ailleurs trouvé que la chaîne appliquait QUATRE dimensions du bouquet sur six en se taisant sur le reste, ce que `tasks/coverage.yml` ferme — au prix de rendre les cellules `VH` et `internet` non publiables par la chaîne producteur, et de nommer le fait qu'une API publiée en mode `jwt` est FERMÉE À TOUS. P6 (ADR-096, matrice 48/0 dès le premier passage dont la porte au PLAN DE DONNÉES — 403 hors plage / 200 dans la plage sur la MÊME API et le MÊME appelant, contre-épreuve à plage inchangée — 4/4 mutations, spike 49/0 en 9 verdicts) a été RÉÉCRIT : sa prémisse était tombée (le mode d'accès d'un port garde `/invoke`, pas le dispatch), et la surface qui garde vraiment les APIs a révélé pire que le jalon manquant — l'`ip-allowlist` que P1 exige d'`external` n'était opposée par RIEN, le drapeau qui pose la règle n'étant positionné nulle part ; le jalon pose l'identification sur le stage IAM de l'API avant l'activation, remplace le verdict de complaisance par un `missing`, et NOMME le fait produit qui explique le NPE connu (détacher une action la DÉTRUIT, les autres policies gardant un UUID mort qui casse leur réactivation) ; P5 (ADR-095, matrice 54/0 sur la 10.15 RÉELLE dont la porte au PLAN DE DONNÉES — même API, HTTP 500 « Transport protocol not supported » en clair et 200 en HTTPS, avec témoin en clair — 6/6 mutations, spike 34/0 en 8 verdicts + 2 sondes de surface) fait REFUSER l'appel en clair par l'API elle-même (`entryProtocolPolicy=[https]` posé AVANT l'activation, relecture à égalité STRICTE) et livre le listener comme objet d'ENVIRONNEMENT qui ne protège personne et le DIT ; la valeur est dérivée de la moitié PER-API du bouquet, ce qui rend MÉCANIQUE le couplage application/vérification que P4 avait demandé ; restent P6..P7. P4 (ADR-094, matrice 38/0 sur la 10.15 RÉELLE dont la porte mesurée au PLAN DE DONNÉES — même rafale, 429 sur vh-internet et 200 sur m-internet — 6/6 mutations, spike 35/0 en 7 verdicts) donne à chaque cellule NOMMÉE son objet unique (`posture-<bouquet>`) portant audit-log + rate-limit AVEC LE QUOTA GOUVERNÉ de la cellule ; l'objet est posé au jour 0 sous identifiant Administrateur, le pipeline n'y inscrit que des noms d'API (GET+PUT, jamais de suppression) et quitte les autres cellules ; l'arbitrage P4/P5 sur https-only est TRANCHÉ (mesuré portable, laissé per-API : P5 possède l'axe) ; restent P5..P7. P3 (ADR-093, matrice 24/0 dont la porte BOUT EN BOUT sur la webMethods 10.15 RÉELLE, 5/5 mutations) pose sur l'objet API le tag de la posture GOUVERNÉE, écrase tout tag de posture écrit par le contrat du producteur sans détruire ses tags métier, et le relit deux fois — sans coupure du data-plane (mesuré), donc hors contrainte ADR-079 ; restent P4..P7. P2 (ADR-092, matrice 67/0 dont le bout en bout sur le Gitea du lab, 4/4 mutations) branche la chaîne du producteur sur le registre central par UNE autorité appelée (`labctl posture`) plutôt que par une recopie de la table de vérité — restent P4..P7. P1 (ADR-091, `go test ./...` 524 ✅ / 0 ❌ sur labctl, 5/5 mutations rouges) tranche les trois décisions client de la taxonomie, corrige une erreur du GOAL lui-même (`external` n'a jamais été SORTANT) et fait de `render` la seule autorité du vocabulaire — restent P2..P7. **P0 LIVRÉ le 2026-09-04** (`scripts/spike-p0-posture.py`, 45/0 sur la 10.15 réelle, rejoué ; verdicts dans `HANDOFF-2026-09-04-P0-QUATRE-SPIKES-DE-POSTURE.md`) : DEUX verdicts négatifs déplacent le GOAL — le **ciblage par tag est RÉFUTÉ** (P4 bascule sur son repli) et **le deny-by-default d'un port ne garde pas les APIs** (la prémisse de P6 tombe). ADR-078 §8 corrigé. Restent P1..P7."
date: 2026-09-04
lié: [adr-076-gitops-api-lifecycle-repo-per-project, adr-078-livrable-self-service-app-wm1015, adr-079-deploiement-promotion-multienv-import-archive, adr-070-opensearch-txn-analytics, adr-075-wm-admin-proxy-multienv, GOAL-cd-promotion-5-envs-2026-08-26, GOAL-cd-applications-2026-09-02]
note: "Le besoin remonté est une liste de quatre réglages (port en HTTPS, port en deny, global policy par tag, information portée par le provider ou la catégorie). Le relevé montre que ce sont les quatre faces d'UNE seule question : quelle donnée décide de la posture d'une API, et qui a le droit de l'écrire. La recherche a rendu un verdict qui déplace deux jalons : le deny-by-default EST une sous-ressource REST (notre ADR-078 dit le contraire), et le champ qui porterait la classification n'est protégé en écriture par RIEN côté gateway."
---

# GOAL — La posture dérivée de l'exposition

**Origine.** Le self-service publie des APIs. Il ne décide **rien** de leur posture de sécurité : le formulaire du producteur collecte huit champs, et **aucun** ne dit ce qu'est l'API — ni son niveau d'intégrité, ni son exposition, ni son fournisseur. La posture est donc soit absente, soit décidée ailleurs, par une chaîne qui ne parle pas à celle-ci.

Le besoin exprimé est une liste de quatre réglages. Le relevé montre qu'ils ne sont pas quatre : ils dépendent tous de la **même donnée manquante**, et deux d'entre eux sont déjà à moitié construits, dans des endroits que personne n'appelle.

---

## Décision (test « archi 40 ans / 30 secondes »)

> **La posture se DÉRIVE, elle ne se DÉCLARE pas.** Le moteur qui transforme un niveau d'intégrité en bouquet de policies existe et est testé (`labctl/internal/render/render.go:85`) : `VH → oauth2+mtls`, `H → oauth2`, `M → oauth2`, `external → liste d'IP obligatoire`, et à tous les niveaux `rate-limit` + `audit-log`. Le travail n'est pas d'écrire ce moteur. Il est de le **brancher sur la chaîne du producteur**, où il est aujourd'hui totalement absent.
>
> **Le demandeur déclare, la plateforme décide — et la recherche vient d'en faire une obligation, pas une préférence.** Aucun attribut d'API en 10.15 ne contraint son vocabulaire ni ne protège son écriture : `apiTags` est un tableau de chaînes libres, `maturityState` est une chaîne libre **sans énumération**, il n'existe **aucun** champ `categories` et **aucun** `customFields` sur une API. Les deux seuls champs non écrivables, `owner` et `provider`, sont en lecture seule — donc le pipeline ne peut pas les poser. La classification est donc **purement déclarative au niveau de la gateway**. Elle ne peut pas y être ancrée. Elle doit vivre dans le registre central clé-par-propriétaire déjà prouvé (`scripts/test-classification-central.sh:12`), la gateway n'en étant que le **miroir**, jamais la source.
>
> **Un port n'est pas un objet d'API, c'est un objet d'environnement.** Créer un listener HTTPS, ou basculer son mode d'accès en deny, change le sort de **toutes** les APIs déjà servies. Ce que le pipeline fait sur un port, c'est **une seule chose** : y inscrire son API, idempotente, avec relecture fail-closed. Et ce qu'il fait sur son API, c'est **restreindre son protocole d'entrée** — le seul levier « HTTPS » qui soit par-API.
>
> **« Port HTTPS par défaut » ne ferme pas le HTTP.** Fait mesuré par la recherche, et il change l'énoncé du besoin : les APIs sont servies sur **tous** les ports activés, et le port primaire n'est pas exclusif. Promouvoir un listener HTTPS en primaire ne coupe pas le trafic en clair. Fermer le HTTP est un **second geste**, distinct, et il porte un redémarrage.
>
> **Rien de ce qui n'est pas prouvé n'est promis.** ADR-076 a placé la global policy filtrée par tag derrière un spike : *« ne jamais claim le natif avant preuve »* (`adr/adr-076-…:159`). La recherche n'a pas levé ce spike — elle l'a **précisé**, en trouvant une contradiction interne dans le contrat de l'éditeur. Ce GOAL commence donc par des spikes, pas par du code.
>
> **Test :** *une API publiée par le self-service peut-elle être joignable UNIQUEMENT en HTTPS, sur un listener qui refuse tout ce qui n'y est pas inscrit, en portant les policies communes de son niveau sans que personne ne les ait recopiées, et le producteur peut-il, en éditant SON dépôt, se faire attribuer un niveau plus faible que celui que la plateforme lui connaît ?* Tant que la dernière réponse n'est pas « non, mécaniquement, et la contre-épreuve le montre », on a écrit une convention de nommage.

---

## Ce que le relevé a mesuré (2026-09-04)

### Ce qui existe déjà, et que personne n'appelle

| Pièce | Où | État mesuré |
|---|---|---|
| Moteur de dérivation posture = f(intégrité, exposition, tags) | `labctl/internal/render/render.go:85` | Écrit, testé. Connaît `VH/H/M` et `internal/external`. **Jamais appelé par la chaîne producteur.** |
| Garde anti-spoof de classification (registre central clé-par-propriétaire) | `scripts/test-classification-central.sh` | Prouvée. La valeur déclarée par le projet est **ignorée** si la source plateforme existe. |
| Pré-check d'enforcement par policy et par moteur | `labctl/internal/enforce/enforce.go:90-112` | Écrit. Exige `transportProtocol == "https"` dès que `mtls` est requis. |
| Inscription d'une API dans l'allow-list d'un port en deny | `ansible/roles/apim_publish_api/tasks/port-access.yml` | Écrite, **prouvée live le 2026-07-15** — mais par le formulaire de l'Integration Server, sur la foi d'une hypothèse que la recherche réfute (voir plus bas). |
| Play autonome « allow-list de port » pour la création d'env | `ansible/is-port-access.yml` | Écrit. |
| Restriction du protocole d'entrée par API | `labctl/internal/adapter/webmethods/transport.go:89` | Écrite. Converge l'action `entryProtocolPolicy` du stage `transport` via `GET`+`PUT /policyActions/{id}`. |
| Lecture et modification d'un listener | `ansible/is-mtls-setup.yml:148` et `:171` | Prouvées live sur `/rest/apigateway/ports`, listener HTTPS `:5543`. **Ce listener est notre échantillon pour le spike de payload.** |

### Les six trous

1. **Le formulaire du producteur ne collecte aucune donnée de posture.** Ses huit champs sont `ACTION`, `TEAM`, `API_NAME`, `API_VERSION`, `API_BASE`, `NEW_VERSION`, `OPENAPI_SPEC`, `INBOUND_MODE` (`ci/Jenkinsfile.api-request`, en-tête). Ni classification, ni exposition, ni fournisseur. Le moteur de dérivation n'a **aucune entrée** de ce côté.

2. **Le rôle de publication ne pose aucun tag.** Une API publiée par le self-service naît **sans aucun tag** — donc invisible à toute global policy filtrée par tag, quelle qu'elle soit.

3. **La global policy est créable par REST côté produit ; c'est NOTRE allow-list qui est fermée.** Le contrat du proxy d'administration (ADR-075) expose `/rest/apigateway/policies/{id}` en **GET et PUT seulement** (`gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml:169`) : pas de `POST /policies`. Le produit, lui, l'expose. La restriction est donc **nôtre**, et c'est une décision de sécurité à assumer telle quelle, pas une limite du produit à contourner.

4. **L'allow-list du port : notre mesure et le contrat de l'éditeur ne disent pas la même chose.** Détaillé à la section suivante — c'est le point qui déplace le plus de travail.

5. **Le mécanisme d'inscription au port est opt-in et personne ne l'active.** `apim_ss_port_manage: false` (`ansible/roles/apim_publish_api/defaults/main.yml:20`), et hors du rôle, la variable n'apparaît que dans un ADR et un play autonome. Aucun `Jenkinsfile` ne la pose à `true`. Le code est écrit, prouvé, et **mort**.

6. ~~**L'exposition ne connaît que deux valeurs.**~~ **FERMÉ par P1 (ADR-091), et l'énoncé de ce trou était à moitié faux.** Le constat tenait : `render.go` rejetait tout ce qui n'était ni `internal` ni `external`. Mais la suite — *« `external` décrit une exposition sortante »* — est **réfutée par nos propres artefacts**, deux fois : le schéma UAC dit du champ `exposure` *« Selects the trust anchor / IdP (internal vs partner) »*, et l'ADR-076 §108 dit *« `external` ⇒ IdP partenaire + IP allowlist »*. Une ancre de confiance est celle de **l'appelant** : `external` a toujours été **entrant**, et a toujours voulu dire **partenaire**. Les trois valeurs se rangent donc sur **un seul axe** (l'inventaire OWASP API9, sans en emprunter le vocabulaire), et P1 a livré la troisième avec sa règle propre.

---

## Ce que la recherche a tranché — et ce qu'elle n'a pas tranché

Campagne du 2026-09-04, sur les contrats machine publiés par l'éditeur (**branche 10.15**, pas `master`) et la documentation produit. **Aucune vérification sur instance vivante** : c'est la limite qui commande tout le reste, d'autant que ce projet a déjà mesuré que ces contrats **sous-décrivent** les charges utiles réelles (corps enveloppés, enveloppe `preferredSettings`, `POST /apis` JSON cassé).

### Trois résultats qui changent la conception

**(A) Le deny-by-default d'un port EST une sous-ressource REST — notre ADR-078 affirme le contraire.** `/rest/apigateway/ports/{listenerKey}/accessMode` existe en 10.15, avec trois opérations : `GET`, `POST` qui **porte le mode** (corps `{accessMode}`), `PUT` qui **porte la liste** (corps `{services: [...]}`). Notre ADR-078 énonce que *« le REST `/ports` ne l'expose pas »* et le rôle a donc été construit sur le formulaire `security-ports-editaccess.dsp` de l'Integration Server. **Cette phrase de l'ADR est fausse au regard du contrat de l'éditeur.** Deux surfaces existent, et il faut choisir en connaissance de cause.

Trois faits arbitrent ce choix, et ils ne pointent pas tous dans le même sens :

- **Le REST n'a AUCUNE opération additive.** Ajouter une API impose un lire-modifier-réécrire de la **liste entière** — donc deux publications simultanées s'écrasent. Le formulaire de l'Integration Server, lui, est **additif** (`addNode`). Notre chemin « moins noble » est le seul qui soit naturellement sûr en concurrence.
- **Sur le contenu de la liste, notre mesure et la doc divergent.** Nous avons mesuré que le port **rejette les URL du plan de données** et que l'entrée est un service `folder:service`. La documentation produit dit que l'intitulé est *« Add APIs and services to Allow List »* et donne pour exemple un **chemin d'API**. L'énoncé « la liste ne porte que des services ESB » a d'ailleurs été **réfuté 0-3**. Les deux peuvent être vrais si les deux surfaces ne pilotent pas la même liste. **C'est exactement ce que le spike doit établir.**
- **Piège d'exploitation documenté :** ne jamais se connecter *par* le port qu'on bascule en deny — verrouillage immédiat. Notre règle « le rôle ne flippe jamais le mode » reste juste, et pour la bonne raison.

**(B) « HTTPS par défaut » se décompose en trois gestes, dont un porte un redémarrage.** La gestion des ports est intégralement pilotable par REST : `POST /ports`, `PUT /ports/enable`, `PUT /ports/primary`, `PUT /ports/disable`, `DELETE`. Mais :

- Le port primaire est **immuable** : on ne peut ni le désactiver, ni le supprimer, ni **modifier ses détails** tant qu'il est primaire. La séquence imposée est créer → activer → promouvoir primaire → **redémarrer** → traiter l'ancien.
- **Restreindre n'est pas modifier** : poser un `accessMode` en deny sur `5555` n'exige **pas** de le dé-primariser. Voilà qui découple proprement l'axe 2 de l'axe 1.
- Et surtout : **promouvoir un port HTTPS ne ferme pas le HTTP**, puisque les APIs sont servies sur tous les ports activés. Le besoin « port par défaut en HTTPS et non HTTP » demande donc explicitement s'il faut *ajouter* du HTTPS ou *retirer* du HTTP. Ce ne sont pas les mêmes risques.

**(C) La forme du payload d'un port HTTPS n'est pas documentée.** La définition `Port` est **entièrement en chaînes** et ne contient **aucun** `keystoreAlias`, `keyAlias`, `truststoreAlias`, `clientAuthentication` ni `backlog` — seulement `accessMode`, `clientAuth`, `ssl` (une chaîne), `jsseEnabledProtocols`, `listenerType`, `protocol`, `portAlias`, les fils d'exécution. Les collections officielles de l'éditeur sont **muettes** sur les ports. Méthode retenue : lire un port HTTPS existant et recopier la forme réelle. **Nous en avons un** — le listener `:5543` du lab.

### Ce qui est établi et directement exploitable

| Fait | Conséquence pour le pipeline |
|---|---|
| Global policy créable par `POST /policies`, discriminée par `global:true` + `policyScope:GLOBAL` | La création est possible côté produit ; reste la décision sur notre allow-list |
| Cycle en **deux temps** : créer inactive, puis `PUT /policies/{id}/activate` | Deux transitions à traiter, chacune pouvant échouer |
| L'activation **échoue s'il existe des conflits**, à résoudre à la main | Un pipeline qui ne traite pas ce cas produira des policies inertes |
| Les actions de policy sont créées **d'abord** sur `/policyActions`, puis référencées par UUID dans `policyEnforcements[].stageKey` | Aucune forme en ligne : séquence obligatoire en deux temps |
| Créer ou modifier une policy **globale** exige le rôle **API Gateway Administrator** | Un identifiant de niveau *provider* ne suffit pas. Décision d'habilitation, pas de plomberie |
| `GET /apis/{apiId}/globalPolicies` liste les policies **actives** qui frappent une API (noms seuls) | La sonde de contrôle a posteriori du pipeline. La sonde inverse `GET /policies/{id}/apis?active=true` est plus riche |
| L'étage `transport` accepte `entryProtocolPolicy` (`protocol` ∈ http, https) **y compris dans une global policy** | Le « HTTPS obligatoire » peut être global, pas seulement par-API. Mais il contraint le **protocole accepté**, jamais le **port d'écoute** |
| `PUT /apis/{apiId}` porte un paramètre `overwriteTags` (défaut **false**) et un `PUT` JSON remplace la définition | Le tag de sensibilité doit être **re-posé et re-vérifié après chaque mise à jour**. Piège opt-in, pas écrasement automatique |

### Le point dur : le ciblage par tag n'est PAS levé

Le ciblage d'une global policy passe par un objet `scope {applicableAPITypes[], logicalConnector, scopeConditions[]}`. Une liste de conditions **vide** signifie « toutes les APIs des types listés ». Le ciblage par **nom** est établi : `filterType=API` + `attributeName=API_NAME` + `operation=EQUALS`.

Le ciblage par **tag** bute sur une **contradiction interne au contrat de l'éditeur** :

- l'énumération `filterType` en 10.15 ne vaut que `[API, HTTP_METHOD]` ;
- la **description de ce même champ** dit *« The allowed values are apis, httpMethod, tags … If tag type is specified we can specify the field tags in API to filter api using tags »* ;
- et `attributeName` expose bel et bien `API_TAG`, `RESOURCE_OPERATION_TAG`, `METHOD_TAG`.

Ni la spécification ni les collections de l'éditeur ne montrent **un seul exemple** de scope par tag. La voie plausible est `filterType=API` + `attributeName=API_TAG`. **À prouver sur l'instance avant de concevoir quoi que ce soit sur des tags.** Repli identifié si le spike est négatif : `API_NAME` plus convention de nommage, ou N global policies à scope explicite — c'est-à-dire le fan-out déjà prouvé, sous un autre nom.

> **LEVÉ le 2026-09-04, par la négative** (spike A). La voie plausible est **acceptée par le modèle et n'a aucun effet** : `filterType=API` + `attributeName=API_TAG` + `operation=EQUALS` se crée, s'active, se relit — et ne sélectionne aucune API, tag présent compris. Deux précisions que la recherche ne pouvait pas avoir : le modèle réel imbrique les attributs (`ScopeCondition.attributes[]`), et **une condition `API` ne sélectionne rien sans une condition `HTTP_METHOD` à côté** — c'est ce qui faisait échouer aussi le ciblage par nom, pourtant réputé établi. Correctement combiné, **le ciblage par nom mord jusqu'au plan de données** : c'est le repli, et il est prouvé.

### Ce que la recherche a réfuté

Neuf énoncés sont tombés 0-3. Trois méritent d'être retenus, parce qu'ils auraient orienté la conception dans le mur :

- *« Les collections de l'éditeur ne contiennent aucun endpoint de ports, donc les axes 1 et 2 exigent l'interface »* — **faux** : le contrat `PortManagement` existe ; seules les collections sont muettes.
- *« Un port ne peut pas être modifié tant qu'il est actif »* — **faux** : la mise à jour d'un port activé implique seulement qu'il soit désactivé puis réactivé.
- *« L'allow-list d'un port porte sur les services et dossiers de l'Integration Server, pas sur des APIs »* — **réfuté**, ce qui met notre mesure du 15 juillet en tension avec la documentation et fonde le spike B.

### Ce que la recherche n'a PAS établi — un résultat, pas un silence

- **Aucune couverture des patrons comparables.** Le budget de recherche a été épuisé avant Apigee, Kong, WSO2 et AWS. Rien de vérifié sur l'attachement de policy par étiquette, le listener en refus par défaut, ou le mTLS par classification chez ces éditeurs. **Ne rien affirmer sur « ce que font les autres » dans un livrable client.**
- **Aucune source sur NIST SP 800-204 ni sur les standards bancaires**, et **aucune** sur l'anti-usurpation d'une métadonnée auto-déclarée en self-service. Notre garde anti-spoof reste une **bonne pratique interne défendable**, pas une exigence sourcée.
- **OWASP API9:2023 dit moins que ce qu'on aimerait lui faire dire.** Il prescrit d'**inventorier et documenter** l'axe d'exposition — *« who should have network access to the host (e.g. public, internal, partners) »* — et rien de plus. Trois réserves à porter telles quelles : son unité est l'**hôte** d'API, pas le proxy ; son vocabulaire est **public / internal / partners**, et non *interne / externe / internet* — ne pas présenter le vocabulaire français comme un vocabulaire OWASP ; et il ne dit **rien** sur le fait d'en dériver des contrôles à l'exécution.

---

## Jalons — chacun avec sa porte de preuve et sa contre-épreuve

### P0 — Les quatre spikes qui décident de la conception

**Rien ne se construit avant.** La recherche a réduit le champ ; elle n'a pas remplacé la mesure.

- **Spike A — le ciblage par tag.** Poser sur la gateway du lab une global policy dont le scope vaut `filterType=API` + `attributeName=API_TAG`, puis publier deux APIs dont une seule porte le tag. Mesurer côté plan de données que la policy mord sur l'une et pas sur l'autre. Vérifier par `GET /apis/{apiId}/globalPolicies` **et** par la sonde inverse.
- **Spike B — quelle liste garde vraiment le port.** Les deux surfaces sur le même listener : `PUT /ports/{listenerKey}/accessMode` et le formulaire de l'Integration Server. Pour chacune, essayer un chemin d'API et un `folder:service`. Établir **laquelle des deux pilote la liste que le plan de données consulte**, et si elles pilotent la même. C'est ce spike qui décide si notre code prouvé du 15 juillet est le bon chemin ou une impasse coûteuse.
- **Spike C — la forme réelle d'un port HTTPS.** `GET /rest/apigateway/ports` sur le listener `:5543` du lab, recopier la forme, la rejouer en création sur un port jetable. Sans cette forme, l'axe 1 n'est pas automatisable.
- **Spike D — le tag survit-il à la promotion ?** Poser un tag, promouvoir par import d'archive (ADR-079), relire. Un attribut qui ne survit pas à la promotion ne peut pas porter une décision de sécurité sur cinq paliers. Vérifier au passage le comportement du `PUT` JSON de mise à jour.

**Porte :** quatre verdicts écrits, chacun avec la commande et la sortie qui l'établissent.
**Contre-épreuve :** pour A, retirer le tag et mesurer que la policy cesse de mordre — sans quoi on n'a pas prouvé le filtre, on a prouvé que la policy s'applique partout.

> ### ✅ P0 LIVRÉ — 2026-09-04 (`scripts/spike-p0-posture.py`, **45 ✅ / 0 ❌**, rejoué)
>
> Verdicts détaillés, avec commandes et sorties : **`HANDOFF-2026-09-04-P0-QUATRE-SPIKES-DE-POSTURE.md`**.
>
> - **A — ciblage par tag : RÉFUTÉ.** `API_TAG` est bien dans l'énumération réelle et se persiste dans la policy, mais ne sélectionne **rien** — ni sur un tag posé par nous, ni sur un tag préexistant, ni en `CONTAINS`. Deux découvertes qui n'étaient dans aucune source : (1) le modèle réel est `ScopeCondition{filterType, logicalConnector, attributes[]}` et `Attribute{attributeName, operation, value}` — pas `attributeName` à plat ; (2) **une condition `filterType: API` ne sélectionne rien seule** : elle n'agit que combinée à une condition `HTTP_METHOD`. Ainsi combiné, le ciblage par **`API_NAME` mord jusqu'au plan de données** (401 sur la ciblée, 200 sur l'autre, contre-épreuve au retrait). **Et la cause est en amont : `apiTags` est un champ MORT** — inécrivable par toutes les surfaces essayées, dont un `PUT` qui rend 200 sans rien écrire. Le seul tag réel est `apiDefinition.tags`, alimenté par **la spec du producteur**, et c'est lui qu'indexe `GET /tags`.
> - **B — le deny d'un port ne garde PAS les APIs.** `/ports/{key}/accessMode` existe (ADR-078 §8 corrigé) ; les deux surfaces pilotent **la même liste** (vérifié dans les deux sens), le REST la **réécrit en bloc** et le formulaire est **additif**. Mais, port en `deny` : `/invoke/<non listé>` → **403**, `/invoke/<listé>` → 200, **`/gateway/<api>` → 200**. Cette ACL garde l'Integration Server, pas le dispatch de l'API Gateway.
> - **C — forme du port HTTPS relevée et REJOUÉE.** 24 champs absents du contrat publié, keystore **par alias** ; `POST /ports` + `PUT /ports/enable` recréent le listener. Fait décisif : l'API **est servie** sur le listener HTTPS mais **refusée par son propre `entryProtocolPolicy=http`** — ajouter du HTTPS ne change rien au protocole accepté.
> - **D — le tag survit à l'archive, et meurt au premier update.** Présent dans les octets, survit à `POST /archive?overwrite=apis` à GUID iso ; mais un `PUT /apis/{id}` sans `tags` l'**efface**, et `overwriteTags=false` ne l'en protège pas.
>
> **Fait produit découvert en route, de premier ordre pour P4 :** supprimer une global policy **supprime en cascade les policyActions qu'elle référence** — y compris une action **système** partagée. L'incident a mis toute activation d'API en NPE jusqu'au redémarrage. Un pipeline qui crée et supprime des global policies peut briquer l'activation de toute la gateway.

### P1 — La taxonomie d'exposition : trois valeurs, une seule autorité

Trancher le sens des trois valeurs, et le rapport entre exposition et niveau d'intégrité — **deux axes orthogonaux**, pas une échelle. Étendre `render.go` à la troisième valeur avec sa règle propre. Décider ce que `internet` impose que `external` n'impose pas.

**Porte :** la table de vérité complète exposition × classification, chaque case produisant un bouquet nommé, et le refus fail-closed de toute combinaison non prévue.
**Contre-épreuve :** une valeur d'exposition inconnue doit être **refusée**, jamais ramenée au défaut `internal`.

> ### ✅ P1 LIVRÉ — 2026-09-04 (ADR-091, `go test ./...` **524 ✅ / 0 ❌** sur labctl, `go vet` propre, **5/5 mutations rouges**)
>
> Détail : **`adr/adr-091-taxonomie-exposition-table-de-verite.md`**. Rejeu : `cd labctl && go test ./...` ; la table cellule par cellule : `go test ./internal/render/ -v`.
>
> - **La prémisse de la décision client n°1 était fausse, et le GOAL le dit au lieu de la maquiller.** `external` n'a jamais décrit une exposition sortante (schéma UAC + ADR-076 §108). Les trois valeurs sont **toutes entrantes**, sur l'axe « qui peut appeler ». Ferme au passage la question ouverte n°5 de l'ADR-076.
> - **Trois décisions client tranchées le 2026-09-04.** (a) `internet` **REMPLACE** l'ip-allowlist par `threat-protection` — un appelant public n'est pas énumérable, et une liste `0.0.0.0/0` satisferait la porte en ne protégeant rien, exactement le piège que P0 vient de mesurer sur le deny-by-default. (b) **`VH × internet` est gouvernée, pas interdite** : le certificat est distribuable à un appelant public quand son IP ne l'est pas (modèle eIDAS/QWAC). (c) **`https-only` est un plancher à toutes les cases** — levier `entryProtocolPolicy` **par API**, sans redémarrage, donc sans croiser ADR-079 ; coût assumé : toute API qui n'épingle pas `transportProtocol: https` devient rouge au pré-check, à tous les niveaux.
> - **L'exposition n'est PAS une échelle, et `Weaker()` cesse de faire semblant.** Entre `external` et `internet`, **les deux sens** perdent un contrôle obligatoire — aucun rang ne peut l'exprimer. L'intégrité garde son rang (M contre H reste un affaiblissement même à bouquet identique) ; l'exposition passe à la **contenance de bouquet**, dérivée mécaniquement.
> - **Une case sans nom est un refus.** Les 9 cellules + `m-internal-apikey` sont **nommées** ; le nom remonte jusqu'à `labctl render` et jusqu'à `EnforcementRequirement.Bundle`. La garde est prouvée **par mutation** (cellule retirée à chaud), sans quoi ce serait une branche qu'aucune entrée n'atteint.
> - **Une seule autorité, enfin.** L'énumération était recopiée **quatre fois** (render, `governance.ValidateUAC`, `govsource`, le schéma UAC). Les trois sites Go demandent désormais le vocabulaire à `render` ; le schéma JSON, qui ne peut pas importer du Go, est **épinglé par une épreuve de dérive** fail-closed.
> - **⛔ Écart #1, assumé et bruyant.** `threat-protection` n'a **aucune surface mesurée** sur wM 10.15 ni ouverte dans l'allow-list ADR-075 : avertissement au pré-check, `unverifiable` au read-back — **ce que la porte REFUSE**. Donc **une API `exposure=internet` est structurellement rouge à l'apply** jusqu'à ce que ce leg soit mesuré. C'est l'état honnête, pas un oubli ; et cela donne à P5/P7 un travail nommé.

### P2 — L'exposition entre dans la chaîne du producteur

Le formulaire collecte l'exposition et la classification. Le manifeste les porte. Le rôle les lit. Et le registre central **gagne** contre le manifeste, par le mécanisme déjà prouvé pour la classification. La recherche a rendu ce point non négociable : la gateway ne protège **aucun** de ses champs en écriture.

**Porte :** une demande de bout en bout où la valeur retenue est celle du registre, visible dans le journal du build.
**Contre-épreuve :** une demande qui déclare une exposition **plus faible** que celle du registre est refusée avec un code nommé, relayé jusqu'à la PR — `Weaker()` (`render.go:68`) existe déjà pour cela.

> ### ✅ P2 LIVRÉ — 2026-09-05 (ADR-092, `go test ./...` **545 ✅ / 0 ❌**, matrice P2 **67 ✅ / 0 ❌** dont le bout en bout sur le Gitea du lab, **4/4 mutations rouges**, `make lint-ci` vert sans dette ajoutée)
>
> Détail : **`adr/adr-092-posture-dans-la-chaine-du-producteur.md`** et **`HANDOFF-2026-09-05-P2-POSTURE-CHAINE-PRODUCTEUR.md`**. Rejeu : `bash scripts/test-p2-posture-producteur.sh` (A→H), `cd labctl && go test ./...`.
>
> - **Le sujet n'était pas de transporter deux champs, c'était de décider QUI tranche.** La chaîne producteur est en bash et en Ansible, la table de vérité est en Go — réécrire la comparaison en Jinja aurait été la **cinquième recopie** que P1 venait de supprimer, sur l'axe qui n'est justement pas une échelle. D'où **`labctl posture`** : la commande qui expose au shell la fonction que `labctl apply` exécute déjà (`resolveCentralClassification`), avec les mêmes codes. Trois appelants — garde d'entrée, plan de la PR, rôle — **une** implémentation.
> - **La porte est tenue sur des dépôts RÉELS.** Demande conforme ⇒ `posture … source=central` dans le journal, manifeste committé portant la posture, et le bouquet nommé sur la PR. Contre-épreuve ⇒ PR ouverte, `❌ PLAN EN ÉCHEC — NE PAS MERGER : [CLASSIFICATION_SPOOFED]`, relayé **dans le commentaire**. Le refus arrive donc là où l'équipe regarde.
> - **Où le refus tombe n'est pas arbitraire.** Défaut de la DEMANDE (champ vide, valeur inconnue) ⇒ avant tout geste Git. Panne d'INFRASTRUCTURE (registre injoignable, autorité absente) ⇒ avant tout geste Git aussi : ouvrir une PR pour y coller un ❌ ferait porter le chapeau au demandeur. Désaccord avec la GOUVERNANCE ⇒ PR ouverte, refus dans son commentaire — c'est une conversation, elle a besoin d'un lieu.
> - **Deux défauts trouvés par la matrice, pas par relecture.** (a) Une valeur hors vocabulaire était annoncée comme un *downgrade* (`Weaker` est fail-closed) — le vocabulaire est désormais vérifié AVANT la comparaison et le refus cite la valeur fautive. (b) Le tenant : le manifeste producteur n'en déclare pas, et le contrôle d'`apply` aurait refusé chaque appel ; rendu **explicite** (`tenantClaimed`) plutôt qu'affaibli — un `api.yaml` qui supprime `tenant_id` reste un spoof, épreuve neuve à l'appui.
> - **Le formulaire est le second miroir épinglé.** Le XML ne peut pas importer du Go non plus : ses deux listes sont pinnées à `render` par `TestProducerFormVocabularyDoesNotDrift`, exactement comme le schéma JSON en P1. Rien d'autre ne lit ce fichier.
> - **⚠ Conséquence à annoncer :** une API absente du registre ne peut plus être publiée (`CLASSIFICATION_UNGOVERNED`). C'est le comportement gouverné voulu, mais il fait de la **PR gouvernance un préalable à la première demande**.
> - **Reste, et c'est un geste humain :** servir gitea/origin. Tant que le dépôt plateforme n'est pas servi, le job du lab checkoute l'ancien script et le **build Jenkins** ne peut pas rejouer la porte (le lab n'a pas été muté : son `labctl` ne connaît pas encore `posture`).

### P3 — Le tag posé sur l'API par la plateforme, jamais par le demandeur

À la création, le rôle pose le tag dérivé puis le relit. Le tag n'est **jamais** repris du manifeste. Et il est **re-posé après chaque mise à jour**.

> **Corrigé par P0.** Le champ n'est **pas** `apiTags` : celui-là est **mort** (inécrivable, `PUT` à 200 sans effet). Le tag se pose dans **`apiDefinition.tags`** par `PUT /apis/{id}` (objet nu). Deux conséquences dures : (1) ce champ est aussi celui que remplit **la spec du producteur** — la plateforme et le demandeur écrivent au même endroit, donc P3 doit **écraser**, pas compléter ; (2) le piège n'est pas `overwriteTags` mais le `PUT` lui-même — **toute** mise à jour de définition sans `tags` efface le tag, `overwriteTags=false` compris.

**Porte :** relecture fail-closed, code `TAG_UNCONFIRMED`, sur le modèle de `PORT_ALLOWLIST_UNCONFIRMED`.
**Contre-épreuve :** un manifeste — ou une spec OpenAPI — qui tente d'écrire son propre tag voit sa valeur écrasée. Et une mise à jour de définition ne doit pas faire disparaître le tag : mesuré comme réel par le spike D, donc à traiter, pas à surveiller.

> ### ✅ P3 LIVRÉ — 2026-09-05 (ADR-093, `go test ./...` **551 ✅ / 0 ❌** sur labctl, matrice P3 **24 ✅ / 0 ❌** sur la wM 10.15 RÉELLE, **5/5 mutations rouges**, P2 rejoué 67/0)
>
> Détail : **`adr/adr-093-tag-de-posture-pose-par-la-plateforme.md`**. Rejeu : `bash scripts/test-p3-tag-plateforme.sh` (A→D), `cd labctl && go test ./...`.
>
> - **Le fait qui change la portée du jalon : poser le tag ne coupe rien.** Le `PUT /apis/{id}` de l'objet **NU** est ACCEPTÉ sur une API **ACTIVE** — l'API reste active et le data-plane répond pendant toute l'opération. Le refus 400 bien connu porte sur le `PUT` **multipart** de ré-import de contrat, pas sur celui-ci : confondre les deux aurait fait croire P3 impossible hors dev. La pose ne croise donc pas ADR-079 et vaut à tous les paliers.
> - **La propriété du tag ne peut pas se fonder sur l'ordre d'écriture, alors elle se fonde sur un ESPACE DE NOMS.** Le champ est partagé avec le producteur (c'est le seul écrivable) ; `posture:` appartient à la plateforme, qui retire TOUS les tags qui le portent avant de poser exactement celui qu'elle a dérivé. Un contrat qui embarque `posture:m-internal` le PERD, il n'en gagne aucun.
> - **Le GOAL est amendé sur un point, et le dit.** Il demandait d'« écraser, pas compléter » ; écraser la LISTE ENTIÈRE aurait détruit les tags métier du producteur, que ses opérations OpenAPI RÉFÉRENCENT par nom (`operation.tags`) — le contrat `apis/accounts-read.openapi.yaml` de ce dépôt en est l'exemple vivant. L'écrasement porte donc sur l'espace de noms : strictement plus fort qu'un ajout, strictement moins destructeur qu'un effacement. Les deux moitiés ont chacune leur assertion et leur mutation.
> - **Le rôle ne compose rien.** `labctl posture` rend `tag` et `tag_prefix` FINIS, dérivés par `render.PostureTag` à côté de la fonction qui dérive le bouquet. La mutation « le rôle reprend le tag écrit par le producteur » vire au rouge : c'est la règle de P2 (*la chaîne demande, elle ne re-décide pas*) appliquée à une chaîne de caractères.
> - **Deux passes, deux rôles différents.** Pose AVANT l'activation (une API non tagable n'est jamais mise en service) ; relecture en DERNIER mot du rôle. Épreuve de la seconde passe : on INJECTE une écriture postérieure qui rétablit le tag du contrat — avec la relecture, le rôle **re-converge** et le prouve ; sans elle, il passe vert en laissant le tag du PRODUCTEUR.
> - **Sans gouvernance, rien n'est posé** (`TAG_NON_ARBITRE`) : poser le tag de la posture DÉCLARÉE laisserait le demandeur choisir son propre tag, c'est-à-dire ce que ce jalon interdit.
> - **⚠ Trouvé en chemin, NON corrigé (c'est la décision client n°2) :** `approvers.yml` est cassé sur le produit réel — son `PUT` ENVELOPPÉ rend 400, et même en objet nu **`owner` n'est pas écrit** (lecture seule). La tâche avait été prouvée contre le MOCK (:8090). Le harnais P3 la contourne **explicitement et par écrit** (équipe sans approbateurs ⇒ `APPROVERS_EMPTY`) plutôt que de la faire taire.

### P4 — Les policies communes portées par la global policy

Deux temps imposés par le produit : créer les actions sur `/policyActions`, puis la policy qui les référence, puis l'activer. La policy est posée **avec un identifiant Administrateur**, donc hors du pipeline de publication ordinaire.

> **Le spike A est négatif : ce jalon bascule sur son repli, et le GOAL le dit au lieu de le maquiller.** Le ciblage par tag n'existe pas en pratique. Deux voies restent, toutes deux mesurées : **(a)** global policy scopée `HTTP_METHOD` **+** `API_NAME` — prouvée jusqu'au plan de données, au prix d'une convention de nommage et d'une policy par API ou par famille de noms ; **(b)** le **fan-out par le plan de contrôle**, déjà prouvé ailleurs. La condition `HTTP_METHOD` n'est pas optionnelle : sans elle, une condition `API` ne sélectionne rien.
>
> **Deux contraintes supplémentaires mesurées par P0**, à porter dans la conception : la suppression d'une global policy **cascade sur ses policyActions**, action **système** comprise — une suppression légitime a mis toute activation d'API en NPE. Et un scope large avec un étage `IAM` frappe **toutes** les APIs : à ne jamais poser sans borne.

**Porte :** deux APIs de niveaux différents, deux bouquets communs différents, mesurés côté plan de données.
**Contre-épreuve :** retirer le ciblage et mesurer que l'appel repasse — déjà tenue une fois au spike A (401 → 200 à la désactivation).

> ### ✅ P4 LIVRÉ — 2026-09-06 (ADR-094, `go test ./...` **557 ✅ / 0 ❌**, matrice P4 **38 ✅ / 0 ❌** sur la wM 10.15 RÉELLE dont **6/6 mutations rouges**, rejouée ; spike P4 **35 ✅ / 0 ❌** en 7 verdicts ; P2 rejoué 67/0, P3 rejoué 24/0 ; `make lint-ci` vert)
>
> Détail : **`adr/adr-094-policies-communes-global-policy-par-cellule.md`**. Rejeu : `bash scripts/test-p4-global-policy.sh` (A→D), `python3 scripts/spike-p4-global-policy.py all`, `ansible-playbook -i ansible/inventory.lab.ini ansible/apim-global-posture-setup.yml`.
>
> - **LA PORTE, tenue littéralement.** Deux APIs, la **même rafale de 35 appels** : 429 sur celle de `vh-internet` (quota gouverné 30/min), 200 partout sur celle de `m-internet` (120/min). Contre-épreuve : cellule désactivée, l'appel repasse en 200.
> - **Le repli du spike A est devenu la conception, et il tient à une condition.** Un objet par cellule NOMMÉE (`posture-<bouquet>`, dix), scopé par une **liste** de `API_NAME` en `OR` — mesuré : une seule condition `API` porte plusieurs noms, donc **une policy par CELLULE et non par API**. Elle n'est sélective que combinée à une condition `HTTP_METHOD` : sans elle l'objet est parfaitement configuré et ne frappe rien, et le rôle REFUSE d'y inscrire quoi que ce soit (`POLICY_COMMUNE_INERTE`, mutation jouée **sur la gateway**).
> - **Le quota devient une colonne de la table de vérité, et c'était nécessaire.** L'ENSEMBLE des policies communes est le même dans les dix cellules (plancher de P1) : la seule chose qui puisse distinguer deux bouquets communs est le nombre. Un `rate-limit` sans nombre gouverné aurait laissé le débit à qui écrit l'objet. Même discipline que P1 : **une cellule sans quota est un refus** (prouvé par mutation). Les valeurs sont des défauts raisonnés — **décision client**.
> - **L'arbitrage P4/P5 que ce GOAL laissait ouvert est TRANCHÉ, et pas dans le sens de la commodité.** `https-only` est **mesurée portable** en global policy (spike S5) et reste **per-API** : P1 la vérifie déjà au read-back sur le `transportProtocol` de l'API, et déplacer l'application sans déplacer la vérification est la façon dont un contrôle cesse d'être vérifié. P5 possède l'axe HTTPS, listener compris.
> - **Trois faits produits découverts en chemin, chacun a changé la conception :** (1) une condition de scope `API` **sans attribut** ne sélectionne pas « rien » mais **TOUTES les APIs** ⇒ sentinelle obligatoire, au jour 0 comme au retrait du dernier membre ; (2) **une `policyAction` n'a aucune identité qu'on puisse écrire** — `POST` accepte un `names`, rend 201, et l'objet relu porte le nom par défaut de son template (le premier rôle, qui les indexait par nom, en a laissé 120 orphelines) ⇒ **la policy est l'ancre**, ses actions ne se retrouvent que par elle ; (3) le stage `threatProtection` **existe** dans le produit mais `/policies` le REFUSE (400 NPE, deux filtres, deux portées) et sa seule surface est **gateway-wide** ⇒ **l'écart #1 d'ADR-091 est PRÉCISÉ, pas levé**.
> - **La frontière des verbes est la réponse à la décision client n°4, par le bas.** Créer / activer / converger le contenu = play d'amorçage sous identifiant **Administrateur**, hors pipeline. Le pipeline n'a que `GET` + `PUT /policies/{id}` — c'est-à-dire exactement ce que l'allow-list ADR-075 expose déjà — et il ne **supprime jamais** : les trois verbes retirés sont les trois qui portent la cascade mesurée au P0.
> - **⚠ Deux LECTURES manquent au proxy d'administration** pour que ce jalon passe par lui : `GET /policies` et `GET /apis/{id}/globalPolicies`. Aucune écriture nouvelle ; sans la seconde, la porte serait un vert vacant.
> - **Vert vacant évité, dans le spike lui-même :** le premier passage mesurait le refus HTTPS sur une API que le spike venait de mettre sous quota — le 429 se lisait comme un refus de protocole. Corrigé par une API dédiée, et la contre-épreuve rejouée.

### P5 — HTTPS : le protocole d'entrée par API, le listener par environnement

Trois gestes, et ils restent distincts.

- **Par API, dans le pipeline :** poser `entryProtocolPolicy = https` sur l'étage `transport`, mécanisme de `transport.go:89` porté dans le rôle. Joignable par le proxy d'administration. **P1 a déjà fait la moitié du chemin** : `https-only` est un **plancher de toutes les cases** (ADR-091), pré-vérifié sur `transportProtocol` et **vérifié au read-back** par `verifyHTTPSOnly` (bascule en clair hors bande = `missing`, prouvé par mutation). Il reste à le **porter côté rôle Ansible** et à mesurer live le refus de l'appel en clair.
- ~~**Éventuellement en global policy :** la recherche établit que l'étage `transport` est portable par une policy globale. À arbitrer avec P4 — un seul objet plutôt que N.~~ **ARBITRÉ par P4 le 2026-09-06 (ADR-094), et pas au vu du seul confort.** Le spike S5 a **mesuré** que ça marche : une global policy au stage `transport` avec `entryProtocolPolicy=https` fait refuser l'appel en clair sur la seule API ciblée, l'API hors scope répondant toujours. Le jalon a néanmoins laissé `https-only` **per-API**, parce que P1 le vérifie déjà au read-back sur le `transportProtocol` de l'API (`verifyHTTPSOnly`) : déplacer l'APPLICATION vers un objet partagé pendant que la VÉRIFICATION continue de lire l'API, c'est ainsi qu'un contrôle cesse discrètement d'être vérifié. **P5 possède l'axe HTTPS, listener compris — un axe, un propriétaire.** P5 reste libre de réunir les deux moitiés ; s'il le fait, il déplace la vérification avec, et une épreuve Go l'y oblige (`TestCommonHalfIsExactlyWhatTheGatewayWasMeasuredToCarry`).
- **Par environnement, hors pipeline :** le listener, son keystore, son mode d'authentification client, et la promotion en primaire **avec son redémarrage**. Play autonome, sur le modèle de `is-mtls-setup.yml`.

> **À moitié mesuré par P0 (spike C).** Une API servie sur un listener HTTPS neuf est **reconnue par le dispatch** puis **refusée** — « Transport protocol not supported » — parce que son propre `entryProtocolPolicy` vaut `http`. Le levier par API fonctionne donc déjà, en sens inverse de celui qu'on veut : il reste à le poser sur `https` et à mesurer le refus de l'appel en clair. Et la forme d'un listener HTTPS est relevée et rejouable (`POST /ports` + `PUT /ports/enable`, keystore **par alias**).

**Porte :** une API publiée répond en HTTPS et **refuse** l'appel en clair.
**Contre-épreuve :** retirer la restriction et mesurer que l'appel en clair repasse — sans quoi c'est le listener qui refusait, pas la policy de l'API.
**Deux pièges déjà nommés :** certains builds renvoient 500 sur une modification de port (`ansible/is-mtls-setup.yml:184`) ; et promouvoir un port HTTPS **ne ferme pas** le HTTP.

> ### ✅ P5 LIVRÉ — 2026-09-06 (ADR-095, `go test ./...` **561 ✅ / 0 ❌** sur labctl, matrice P5 **54 ✅ / 0 ❌** sur la wM 10.15 RÉELLE, **6/6 mutations rouges**, rejouée ; spike P5 **34 ✅ / 0 ❌** en 8 verdicts + 2 sondes ; P2 rejoué 67/0, P3 rejoué 24/0, P4 rejoué 38/0 ; `make lint-ci` 17/17)
>
> Détail : **`adr/adr-095-https-protocole-par-api-listener-par-environnement.md`** et **`HANDOFF-2026-09-06-P5-HTTPS-PAR-API-ET-LISTENER.md`**. Rejeu : `bash scripts/test-p5-https.sh` (A→D), `python3 scripts/spike-p5-https.py all`, `ansible-playbook -i ansible/inventory.lab.ini ansible/is-https-listener.yml`.
>
> - **LA PORTE, tenue littéralement, et la contre-épreuve avec elle.** La MÊME API publiée par la chaîne répond **HTTP 500 « Transport protocol not supported » en clair** et **200 en HTTPS**, pendant qu'une API témoin — publiée sans registre central — répond **200 en clair**. Le réglage retiré à la main, le clair **repasse** : c'était donc bien la policy et non le port. Le rôle rejoué le **re-converge**, un troisième passage n'écrit rien.
> - **Le GOAL disait « la topologie des ports ne protège rien » ; ce jalon le rend impossible à oublier.** Le fait avait été mesuré deux fois (un listener HTTPS neuf ne change pas le protocole accepté, spike C de P0 ; `enabled` et `primary` sont indépendants donc promouvoir ne ferme pas le HTTP, S6). Il est désormais PORTÉ par le livrable : le play de listener ne touche à aucune API, et son **dernier mot énumère les ports en clair restés ouverts** en rappelant où vit le contrôle. Un play de transport qui se termine en vert laissait croire que le clair était traité.
> - **L'arbitrage P4/P5 n'est pas seulement respecté, il est rendu MÉCANIQUE.** `entry_protocol` est dérivé de `PerAPIPolicies`, pas du bouquet : le jour où quelqu'un déplace `https-only` dans `commonCarriable`, la valeur devient vide et le rôle cesse de poser — au lieu de laisser l'application partir vers l'objet partagé pendant que `verifyHTTPSOnly` continue de relire l'API. L'épreuve que P4 réclamait existe, et sa mutation vire au rouge.
> - **L'égalité du read-back est STRICTE, et c'est le cœur du jalon.** Le paramètre est mesuré EXCLUSIF (S5) : une liste `['http','https']` *contient* la valeur visée et laisse pourtant passer le clair. Un `in` produirait une API portant le tag d'une posture gouvernée tout en servant en clair — le vert vacant le plus coûteux que ce GOAL pouvait encore produire. Mutation jouée.
> - **La position est mesurée, pas souhaitée.** Le réglage se pose et se relit sur une API **INACTIVE** et survit à l'activation (S8) : la tâche va donc avant l'activation, et une API gouvernée ne sert **jamais un seul appel en clair, pas même pendant sa publication**. Le fait jumeau avait dû être mesuré en P4 pour `GET /apis/{id}/globalPolicies`.
> - **Trois faits produits découverts en chemin :** (1) l'action `entryProtocolPolicy` est **PROPRE à chaque API** — contrairement au throttle LMT, mesuré partagé en P4 : sans cette vérification, poser le protocole par API aurait pu frapper toutes les autres ; (2) le réglage **survit au ré-import de contrat**, contrairement au tag de P3 — pas de seconde passe nécessaire ; (3) **⚠ `clientAuth` n'est pas éditable et le produit ment** : `PUT /ports/{listenerKey}` comme `PUT /ports/{alias}` rendent **200** sans persister, et `alias` vaut « ssos » sur TOUS les listeners HTTPS donc cette seconde URL ne désigne même pas un port. Le « quirk 500 » qu'annonçait `is-mtls-setup.yml` est un **200 menteur**, ce qui est pire. Le rôle pose le mode à la naissance et **refuse** en le nommant sur un port déjà là.
> - **Le proxy d'administration n'a RIEN à gagner**, contrairement à P4 qui laissait deux lectures manquantes : tout ce que ce jalon appelle est déjà dans l'allow-list ADR-075.
> - **⚠ CONSÉQUENCE À ANNONCER AU CLIENT, et elle n'est pas technique.** Une API gouvernée n'est plus joignable en clair : pour un appelant qui y était, **c'est une rupture**. Ce n'est pas la plateforme qui coupe (l'API reste active, rien au sens d'ADR-079), c'est le contrôle qui s'applique — mais sur un environnement où des consommateurs appellent en clair, la première publication gouvernée les casse. Et le listener HTTPS devient un **préalable d'environnement** : sans lui, une API gouvernée n'est joignable par aucun canal.
> - **⚠ Effet de bord sur les épreuves, corrigé :** tout harnais qui mesurait le plan de données EN CLAIR mesurait autre chose depuis ce jalon — celui de P4 lisait le refus de PROTOCOLE là où il attendait un 429. Porté sur `scripts/lib/wm-dataplane.sh` (canal accepté par l'API, via le conteneur) ; P4 rejoué **38/0**.
> - **L'écart #1 (`threat-protection`) n'est PAS levé par ce jalon, et le GOAL le lui assignait.** Il ne le pouvait pas : P4 a mesuré que le contrôle EXISTE côté produit mais que `/policies` refuse son stage, sa seule surface étant gateway-wide — ce n'est donc pas un travail d'implémentation, c'est la question client « chez vous, `threat-protection` désigne-t-il ce réglage gateway-wide, ou un WAF en amont ? ». Une API `exposure=internet` reste **structurellement rouge à l'apply**. Reste à P7 de le porter tel quel dans la matrice de bout en bout, pas de le résoudre.
> - **⚠ Trouvé en chemin, NON corrigé :** `is-mtls-setup.yml` converge `clientAuth` par un chemin qui ne peut pas réussir sur ce build. Son read-back fail-closed le rattrape — il échoue bruyamment plutôt que de mentir — mais la tâche est inopérante. Hors périmètre P5 (ADR-076 en est propriétaire) ; nommé plutôt que tu.

### P6 — Deny-by-default : RÉÉCRIT sur la surface qui garde vraiment le dispatch

> ### ⛔ Prémisse TOMBÉE — jalon RÉÉCRIT le 2026-09-06 (voir le bloc ✅ en fin de section)
>
> La contre-épreuve de ce jalon a été jouée **en premier**, et elle est négative : sur un listener en `deny`, dont la liste ne contient aucune entrée relative à la gateway, **`/gateway/<api>/<version>/<ressource>` répond 200, réponse du backend incluse** — pendant que `/invoke/<service non listé>` est bien refusé en 403. Le mode d'accès d'un port de l'Integration Server garde `/invoke`, **pas le dispatch de l'API Gateway**.
>
> Donc : inscrire une API publiée dans l'allow-list du port ne la protège de rien, et l'en retirer ne la ferme pas. Le code de `tasks/port-access.yml` n'est pas seulement **mort**, il est **braqué sur la mauvaise surface** pour l'objectif annoncé. Le réveiller ne produirait qu'une garantie de papier — le pire résultat possible pour un contrôle de sécurité.
>
> Ce qui reste vrai et utile du spike B : les **deux surfaces pilotent la même liste** (vérifié dans les deux sens), le **REST réécrit en bloc** (donc concurrence réelle) et le **formulaire est additif**. À garder pour le jour où il s'agira vraiment de restreindre `/invoke`.
>
> **Reste à trancher avec le client** : ce que « port en deny-by-default » désigne chez lui. Si c'est bien l'Access Mode de l'Integration Server, alors ce contrôle ne protège pas ses APIs et il faut le lui dire. Si c'est un dispositif en amont (reverse proxy, pare-feu, WAF), il est hors de cette chaîne et P6 devient sans objet.

Le code existe pour une des deux surfaces. Il faut l'activer, avec la bonne entrée, et régler la concurrence. **Si le REST l'emporte**, le lire-modifier-réécrire de la liste entière impose une sérialisation explicite — deux publications simultanées s'écrasent. **Si le formulaire l'emporte**, l'ajout est additif et le problème disparaît, au prix d'une seconde surface d'authentification.

**Le rôle continue de ne JAMAIS basculer le mode du port.** Cette règle ne bouge pas, et le verrouillage documenté par l'éditeur la confirme.

**Porte :** une API publiée est joignable ; la même API, retirée de la liste, ne l'est plus.
**Contre-épreuve :** une API **non** inscrite sur un port en deny est injoignable — seule mesure qui prouve que le port garde vraiment. *(Jouée le 2026-09-04 : elle échoue. Voir l'encadré.)*

> ### ✅ P6 LIVRÉ — 2026-09-06 (ADR-096, `go test ./...` **568 ✅ / 0 ❌** sur labctl, matrice P6 **48 ✅ / 0 ❌** dès le PREMIER passage et REJOUÉE, sur la wM 10.15 RÉELLE dont la porte au PLAN DE DONNÉES et sa contre-épreuve, **4 mutations sur 4 visibles** ; spike P6 **49 ✅ / 0 ❌** en 9 verdicts ; P2 rejoué 67/0, P3 24/0, P4 38/0, P5 54/0 ; `make lint-ci` vert)
>
> Détail : **`adr/adr-096-identite-appelant-refus-par-defaut.md`** et **`HANDOFF-2026-09-06-P6-IDENTITE-DE-L-APPELANT.md`**. Rejeu : `bash scripts/test-p6-deny-by-default.sh`, `python3 scripts/spike-p6-deny-by-default.py all`, `ansible-playbook -i ansible/inventory.lab.ini ansible/is-iam-action-split.yml`.
>
> - **Le jalon a été RÉÉCRIT, pas fermé — et ce qui a tranché n'est pas une préférence d'architecture.** En cherchant la surface qui garde réellement le dispatch, on a trouvé pire que le jalon manquant : **P1 fait de l'`ip-allowlist` la règle propre d'`external`, et le drapeau qui POSE la règle (`EnforceInboundIdentifiers`) n'était positionné NULLE PART** — ni CLI, ni manifeste, ni pipeline. La primitive Go existait, testée, morte, exactement comme `port-access.yml`. Chaque cellule `external` publiée portait donc un contrôle que rien n'opposait, pendant qu'un verdict de read-back affirmait « enforced au consommateur ». Fermer P6 aurait laissé cet état tel quel.
> - **LA PORTE, tenue littéralement, et la contre-épreuve avec elle.** MÊME API, MÊME appelant : **403** quand l'allow-list de l'application l'exclut, **200** quand elle l'inclut, **403** de nouveau quand on la remet hors de portée — puis, **la règle retirée à plage inchangée, 200**. Sans cette dernière mesure, les trois premières n'étaient attribuables à rien. Le rôle rejoué **re-pose** la règle ; un troisième passage n'écrit rien.
> - **⚠ LE FAIT PRODUIT DU JALON, et il explique une panne connue depuis juillet.** **Détacher une action d'une policy DÉTRUIT l'objet action.** Toute autre policy qui la référençait garde un UUID mort : son plan de données **continue de refuser** (403 — pas de fail-open), mais **sa prochaine activation échoue en 500** « Policy action does not exist ». C'est le mécanisme du NPE que ce projet documentait comme « action supprimée mais référencée » : **personne ne l'avait supprimée, il avait suffi de la détacher ailleurs**. D'où la forme du livrable — **un objet par API** — et un refus nommé (`ACTION_IAM_PARTAGEE`) plutôt qu'une casse silencieuse chez les voisines, avec le play de conversion `ansible/is-iam-action-split.yml` sur le modèle du jour-0 de P4.
> - **Trois autres faits mesurés qui contredisent l'intuition :** une API publiée a un stage IAM **vide** et sert n'importe qui anonymement (il n'y avait pas de refus par défaut à réveiller, il y en avait un à poser) ; **un joker `0.0.0.0-255.255.255.255` n'identifie PERSONNE** (403), donc on ne peut pas neutraliser le contrôle en élargissant la plage ; et la gateway **refuse une seconde action au stage IAM** (409), donc les dimensions se FUSIONNENT dans un objet unique au lieu de s'empiler.
> - **Le repli `sys:defaultApplication` ne rouvre pas la porte** : une seconde application souscrite SANS identifier ne résout pas l'appelant hors plage. Le piège nommé par la mémoire `oracle-idp-gateway-sync` a été joué, il est écarté.
> - **La position est mesurée, pas souhaitée** (S8) : la règle se pose sur une API INACTIVE et survit à l'activation, donc la tâche va avant l'activation et une API gouvernée ne sert **jamais** un appel non identifié, pas même pendant sa publication. Même exigence, même méthode qu'en P4 et P5. Et elle **survit au ré-import de contrat** (contrairement au tag de P3) : une seule passe suffit.
> - **Un axe, un propriétaire — appliqué à la lettre.** La création de l'action et son attachement ont QUITTÉ `inbound.yml` pour `caller-identity.yml` : la gateway n'acceptant qu'une action au stage, deux fichiers qui l'écrivent, c'est le second qui gagne et le contrôle perdu ne se voit nulle part. Le couplage application/vérification est rendu MÉCANIQUE comme en P5 (`CallerIdentityFor` lit la moitié per-API ; déplacer `ip-allowlist` dans `commonCarriable` fait tomber une épreuve au lieu de dériver en silence).
> - **Le verdict de complaisance a disparu.** `verifyIPAllowlist` lit l'action IAM et rend **`missing`** — plus `degraded` — quand la règle n'y est pas ; et le **pré-check d'apply** refuse en amont une cible `external` qui ne déclare pas `inboundAuth.ipAllowlist`. Les deux mutations sont écrites.
> - **⚠ CONSÉQUENCE À ANNONCER AU CLIENT.** Une API `external` gouvernée n'est plus joignable depuis une IP non déclarée : **le recensement des IP partenaires devient un préalable**, contrepartie exacte du choix d'ADR-091 (`external` = partenaire énumérable). Et une conversion jour-0 est à jouer sur tout environnement où des APIs partagent une action d'identification.
> - **NON tenu, et dit :** le play de conversion a été joué en mode AUDIT (lecture seule) et trouve une situation réelle sur le lab — *« 15 APIs, 26 policies, 3 actions IAM référencées, dont 1 PARTAGÉE »* — mais **la conversion elle-même n'a pas été lancée** : elle réécrit les policies de plusieurs APIs et c'est un geste d'exploitation, à faire à un moment choisi. Et le côté Go conserve sa stratégie d'objet PARTAGÉ, qui porte le même risque : nommée dans l'ADR, pas corrigée à la sauvette.

### P7 — La porte de bout en bout, par builds réels

La matrice complète : formulaire → PR → merge → publication, pour au moins trois combinaisons d'exposition × classification, chacune produisant une API dont le protocole, le tag, l'inscription au port et les policies effectives sont **mesurés**.

**Contre-épreuve de tout le GOAL :** un producteur qui édite son manifeste pour se déclarer moins exposé et moins critique qu'il ne l'est obtient **exactement la même posture**. Sinon, les six jalons précédents ont produit de la documentation.

> **LIVRÉ le 2026-09-06 — ADR-097, `HANDOFF-2026-09-06-P7-BOUT-EN-BOUT-ET-COUVERTURE.md`.** La porte est tenue par des **builds Jenkins réels** sur les dépôts réels et la 10.15 réelle, et la contre-épreuve l'est **dans ses deux sens** : se déclarer plus faible est **refusé et nommé** (`CLASSIFICATION_SPOOFED`, rien créé sur la gateway) ; se déclarer plus fort donne une **empreinte de posture identique** à celle d'une déclaration honnête sur la même ligne de registre. *Le manifeste ne décide pas.*
>
> **Mais le jalon a trouvé plus que ce qu'il devait vérifier**, et c'est le fond de son ADR : **la chaîne appliquait quatre dimensions du bouquet sur six et se taisait sur le reste**. Une API `M/internal` recevait le tag et la cellule qui affirment `oauth2` sans que rien ne l'exige d'elle — le défaut de P6 (`EnforceInboundIdentifiers` posé nulle part), une couche plus haut. `tasks/coverage.yml` rend la couverture explicite : **opposée**, **dégradée** (l'axe est gardé plus faiblement, la PR le dit), **refusée** (l'axe n'est gardé par rien) ; et une dimension exigée absente des deux tables fait REFUSER (`POSTURE_NON_OPPOSEE`) — l'anti-dérive.
>
> **⚠ Trois conséquences à annoncer, toutes de gouvernance :**
> 1. **`VH` et `internet` ne sont plus publiables par la chaîne producteur** (`mtls` non déclinable par API — mesure P5 ; `threat-protection` non portable par une policy — mesure P4). Elles se publiaient avant, en affichant une posture qu'elles n'avaient pas.
> 2. **Une API publiée par le formulaire est FERMÉE À TOUS** : le mode `jwt` pose une identification par `jwtClaims` qu'aucun identifiant d'application ne résout — mesuré avec un jeton RÉEL de l'IdP et une application souscrite portant l'identifiant de claim correspondant (401 dans les quatre variantes). C'est fail-closed, donc sans risque ; c'est inutilisable en l'état, et **l'entrée `oauth2` au formulaire est le prochain travail utile**.
> 3. **La projection des approbateurs devient opt-in** : `owner` n'est pas écrivable sur la 10.15 (mesuré), et la garde fail-closed du rôle faisait échouer toute publication d'une équipe qui en déclare. La liste reste autoritative dans `providers.<env>.yml`.
>
> **Deux défauts de plomberie corrigés au passage**, invisibles jusqu'ici parce que la chaîne n'avait jamais été jouée en entier contre le PRODUIT : le `PUT /apis/{id}` d'`approvers.yml` était enveloppé (400), et le préflight d'égalité des vues créait son témoin par `POST /apis` en JSON nu (cassé sur ce produit).

---

## Décisions client bloquantes

1. ~~**Que signifie `internet` ?**~~ **TRANCHÉE le 2026-09-04 (P1 / ADR-091).** La prémisse tombait d'elle-même : `external` n'était pas sortant, il voulait dire **partenaire**. Les trois valeurs sont entrantes et recouvrent l'inventaire OWASP (public / internal / partners) **sans en emprunter le vocabulaire** — la réserve de P0 est tenue, on ne présente jamais le mot français comme un mot OWASP. Ce que `internet` impose et que `external` n'impose pas : `threat-protection` **à la place** de l'ip-allowlist (l'appelant public n'est pas énumérable). Et `VH × internet` reste gouvernée (eIDAS/QWAC). **Reste ouvert, en revanche : `threat-protection` désigne-t-il chez vous un dispositif de la gateway ou un WAF en amont ?** De la réponse dépend l'écart #1 — leg à mesurer sur wM, ou déclaration d'amont à exiger dans le manifeste.
2. **Le fournisseur ou la catégorie ?** Tranché à moitié par la recherche : `provider` et `owner` sont en **lecture seule** sur la gateway. Le pipeline ne peut pas les poser. Si l'information doit être portée par le fournisseur, elle vit dans l'annuaire et le registre central, jamais dans l'objet API.
3. **Ajouter du HTTPS, ou retirer du HTTP ?** Ce ne sont pas le même geste ni le même risque. Le second impose un redémarrage et croise la contrainte de zéro-coupure d'ADR-079 — donc probablement une fenêtre de changement, hors self-service.
4bis. **⚠ NOUVELLE, née de P4 : le quota de chaque cellule.** P4 a dû donner un nombre à `rate-limit`, sans quoi ce n'était pas un contrôle mais un mot — et le nombre serait revenu à qui écrit l'objet, c'est-à-dire au demandeur. Les dix valeurs actuelles sont des **défauts raisonnés** (le quota se resserre quand la population d'appelants s'élargit, et à exposition égale quand l'enjeu d'intégrité monte) : `VH` 120/60/30, `H` 300/150/60, `M` 600/300/120 par minute, `internal`/`external`/`internet`. **Ce sont vos nombres à fixer** ; le mécanisme, lui, est livré et prouvé au plan de données.

4ter. **⚠ NOUVELLE, née de P4 : deux LECTURES à ouvrir sur le proxy d'administration.** `GET /rest/apigateway/policies` (résoudre la cellule par son nom) et `GET /rest/apigateway/apis/{id}/globalPolicies` (la relecture qui prouve que la gateway SÉLECTIONNE bien l'API). **Aucune écriture nouvelle** — et sans la seconde, la porte du jalon serait un vert vacant : on saurait que la liste est juste, jamais que l'objet frappe.

4. **Élargit-on l'allow-list du proxy d'administration à `POST /policies` ?** *(Répondu par le bas au 2026-09-06 : **non, et ce n'est plus nécessaire**. P4 a placé la création, l'activation et la convergence du contenu dans un play d'amorçage sous identifiant Administrateur, hors pipeline ; le pipeline se contente du `GET`+`PUT` déjà exposé. La question reste ouverte si vous vouliez, un jour, que le pipeline crée lui-même des cellules — ce que ce jalon déconseille explicitement.)* Ce serait donner au pipeline le droit de modifier la posture de **toutes** les APIs. À quoi s'ajoute le fait, désormais établi, que cette opération exige un identifiant **Administrateur** et non *provider*. **Et un fait mesuré par P0 qui alourdit la décision : supprimer une global policy supprime en cascade les policyActions qu'elle référence — action SYSTÈME comprise, ce qui met toute activation d'API en NPE jusqu'au redémarrage.** La question n'est donc pas seulement « qui peut changer la posture de toutes les APIs » mais « qui peut casser l'activation de toutes les APIs ». Décision de sécurité, à prendre pour elle-même.
5. ~~**Que fait-on des APIs déjà publiées sans tag ?**~~ **Sans objet depuis P0** : aucune global policy ne cible par tag. La question devient celle du **repli retenu** — convention de nommage (`API_NAME`) ou fan-out —, et donc du sort des APIs dont le nom ne suit pas la convention.
6. ~~**Quelle surface pilote le deny-by-default ?**~~ **Question remplacée par P0** : les deux surfaces pilotent la même liste, et cette liste ne garde pas les APIs. La vraie question est désormais : **qu'appelez-vous « le port data-plane en deny-by-default » ?** Si c'est l'Access Mode de l'Integration Server, il ne protège pas vos APIs — mesuré. Si c'est un dispositif en amont, il est hors de cette chaîne.

---

## Risques et limites assumés

- **Le tag devient un contrôle de sécurité**, et la gateway ne le protège pas. Le durcissement de P2 et P3 était la contrepartie obligatoire de la conception : **les deux sont livrés**. Ce que la chaîne garantit, c'est qu'à chaque passage du rôle l'espace de noms est repris ; ce qu'elle ne peut pas garantir, c'est ce qu'un administrateur écrit hors chaîne — et une API publiée hors chaîne ne porte donc rien de fiable (dit à voix haute par `TAG_NON_ARBITRE`).
- ~~**Notre ADR-078 porte une affirmation fausse**~~ **CORRIGÉ le 2026-09-04** (ADR-078 §8) : la phrase sur l'absence de surface REST est barrée et remplacée par un encadré qui porte les deux corrections — la surface existe, et l'allow-list ne garde pas les APIs.
- **Un pipeline qui manipule des global policies peut briquer la gateway.** Mesuré : la suppression d'une global policy cascade sur ses policyActions, action système comprise ⇒ activation d'API en NPE jusqu'au redémarrage. Toute conception de P4 doit vider les enforcements avant suppression et ne jamais référencer une action du produit.
- ~~**La classification est écrite par le producteur lui-même.**~~ **TRAITÉ le 2026-09-05 (P3 / ADR-093), avec un amendement.** Le seul champ écrivable reste `apiDefinition.tags`, partagé avec la spec du producteur — mais la propriété ne se fonde pas sur l'ordre d'écriture, elle se fonde sur un **espace de noms réservé** (`posture:`) que le rôle reprend à chaque passage. L'écrasement porte donc sur cet espace, **pas sur la liste entière** : détruire les tags métier casserait les `operation.tags` du producteur sans rien apporter à la sécurité. Écrasement + relecture survivent à chaque `PUT` de définition, par une seconde passe en fin de rôle (prouvée par injection d'un effacement postérieur).
- **Une valeur d'exposition peut être dérivable et refusée à l'apply.** Depuis P1, `exposure=internet` produit un bouquet valide dont une policy — `threat-protection` — n'est vérifiable par aucun leg mesuré (écart ADR-091 #1). L'API est donc **structurellement rouge à la porte**. C'est voulu : attester en silence un contrôle que personne n'a observé serait la garantie de papier que P0 a démontée. Mais cela veut dire que `internet` n'est **pas utilisable de bout en bout** avant que ce leg existe — à porter dans P5/P7, et à dire tel quel au client.
  > **PRÉCISÉ par P4 le 2026-09-06 — et c'est pire que « pas encore mesuré », c'est « pas déclinable ».** Le contrôle EXISTE côté produit : le stage `threatProtection` est déclaré dans le `stages.json` de la 10.15 avec ses filtres (`jsonThreatProtectionFilter`, `MsgSizeLimitFilter`, `sqlInjectionFilter`, `ipdos`, `globalipdos`), et les actions correspondantes **se créent** par `POST /policyActions`. Mais **`/policies` refuse de les porter** : HTTP 400 `NullPointerException`, pour deux filtres différents et pour les deux portées (scopée par nom comme sans condition). La seule surface qui les configure est `/administration/threatprotection`, qui est **gateway-wide** — donc incapable de différer d'une cellule à l'autre. `threat-protection` ne peut pas être une policy de bouquet sur ce produit ; il ne peut être qu'une **exigence d'environnement**. C'est une question client, pas une dette technique : chez vous, `threat-protection` désigne-t-il ce réglage gateway-wide, ou un WAF en amont ?
- **Toute la recherche repose sur des contrats publiés, non sur une instance.** Ce projet a déjà mesuré que ces contrats sous-décrivent la réalité. Chaque énoncé repris ici doit être rejoué avant d'entrer dans un livrable.
- **Quatre surfaces d'administration, quatre jeux d'identifiants et deux niveaux d'habilitation.** Chacune est un point de défaillance et un point d'audit.
- **`labctl` reste parqué.** Les mécanismes empruntés à `transport.go` et `render.go` sont des **spécifications vérifiées**, à porter côté rôle Ansible, comme cela a déjà été fait pour la publication.
- **Quatre jalons dépendent d'un spike.** Un verdict négatif ne bloque pas le GOAL : il change le jalon, et le GOAL doit le dire tel quel.

---

## Ce que ce GOAL ne fait pas

- Il ne touche pas à la chaîne de promotion entre paliers, soldée par le GOAL des cinq paliers.
- Il ne traite pas les applications, côté consommateur, soldées par le GOAL des applications.
- Il n'élargit pas l'allow-list du proxy d'administration — il constate ce qu'elle permet et conçoit dedans, sauf décision client n°4.
- Il n'affirme rien sur les pratiques d'Apigee, Kong, WSO2 ou AWS : la recherche n'a pas pu les couvrir, et l'absence de source est consignée comme telle.
- Il n'écrit aucun code avant que P0 ait rendu ses quatre verdicts. *(Tenu : P0 rendu le 2026-09-04, P1 écrit ensuite.)*
