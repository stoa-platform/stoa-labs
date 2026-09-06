---
title: "ADR-095 — HTTPS : l'API refuse elle-même l'appel en clair (protocole d'entrée par API, posé par le pipeline avant l'activation) ; le listener est un objet d'ENVIRONNEMENT qui ne protège personne."
sidebar_label: "ADR-095 : le protocole d'entrée par API (P5)"
status: "Acté et prouvé le 2026-09-06 — `go test ./...` **561 ✅ / 0 ❌** sur labctl (4 neuves), `go vet` propre ; matrice P5 **54 ✅ / 0 ❌** dont la porte BOUT EN BOUT sur la webMethods 10.15 RÉELLE (HTTP 500 en clair, 200 en HTTPS, sur la MÊME API, avec témoin) et **6 mutations sur 6 rouges** ; spike P5 **34 ✅ / 0 ❌** (8 verdicts, rejoué) + 2 sondes de surface (S9/S10) ; P2 rejoué 67/0, P3 rejoué 24/0, P4 **rejoué 38/0 après portage de sa mesure sur le canal TLS** ; `make lint-ci` vert."
maturite_technique: "✅ Le pipeline pose `entryProtocolPolicy = [https]` sur le stage `transport` de la policy SERVICE de l'API, AVANT l'activation, avec relecture fail-closed à égalité STRICTE (`HTTPS_ONLY_UNCONFIRMED`). La valeur arrive FINIE de `labctl posture` (`entry_protocol`), dérivée de la moitié PER-API du bouquet. Le listener HTTPS est un play autonome d'environnement (`ansible/is-https-listener.yml`) qui ne touche à aucune API et le dit. ⚠ `clientAuth` n'est PAS éditable après création du port (PUT à 200 sans persistance, mesuré) : le rôle refuse en le nommant."
date: 2026-09-06
adr_number: 95
note: "Jalon P5 du GOAL posture-par-exposition. Le fait central est contre-intuitif et a été mesuré deux fois : la topologie des ports ne protège AUCUNE API. Ajouter un listener HTTPS ne change rien au protocole qu'une API accepte, et promouvoir ce listener en primaire ne ferme pas le HTTP. Le seul levier qui refuse l'appel en clair est per-API — d'où la répartition de cet ADR."
lié: "[[adr-094-policies-communes-global-policy-par-cellule]], [[adr-093-tag-de-posture-pose-par-la-plateforme]], [[adr-092-posture-dans-la-chaine-du-producteur]], [[adr-091-taxonomie-exposition-table-de-verite]], [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-075-wm-admin-proxy-multienv]]"
---

# ADR-095 — Le protocole d'entrée par API, le listener par environnement (P5)

**Statut :** Acté et prouvé le 2026-09-06. Hors ligne : `go test ./...` **561 ✅ / 0 ❌**, `go vet` propre, `make lint-ci` vert. Live : `scripts/test-p5-https.sh` **54 ✅ / 0 ❌** sur la wM 10.15 réelle (`poc-webmethods-real`), dont **6 mutations rouges**. Spike préalable : `scripts/spike-p5-https.py` **34 ✅ / 0 ❌**, huit verdicts, rejoué à l'identique.

## Contexte

P1 a fait de `https-only` un **plancher de toutes les cases** de la table de vérité et l'a rendu vérifiable au read-back (`verifyHTTPSOnly`, sur le `transportProtocol` de l'API). P4 a mesuré qu'il serait **portable** par la global policy d'une cellule, et l'a laissé per-API **exprès** : déplacer l'application vers un objet partagé pendant que la vérification continue de lire l'API est la façon dont un contrôle cesse discrètement d'être vérifié.

Restait donc, pour P5, un travail nommé : **poser** le réglage depuis le rôle Ansible — il n'existait que comme spécification Go (`transport.go`) — et **mesurer live** que l'appel en clair est réellement refusé. Plus la seconde moitié de l'axe : le listener HTTPS, objet d'environnement.

Le GOAL annonçait deux pièges et une demi-mesure. Le spike a levé les trois, et en a trouvé deux autres que personne n'avait vus.

## Ce que le spike a mesuré (2026-09-06, wM 10.15 réelle)

| # | Question | Verdict |
|---|---|---|
| S1 | Une API fraîchement importée a-t-elle un stage `transport` avec `entryProtocolPolicy` ? | **Oui, nativement**, à `["http"]`. Le rôle **ÉDITE** un objet existant — il n'en crée aucun, et l'absence est une anomalie de plateforme. |
| S2 | Cette action est-elle **partagée** entre APIs, comme le throttle du stage LMT (mesuré partagé en P4) ? | **Non** — ids distincts, et poser `https` sur A ne change rien à B (relu). Sans cette mesure, l'écriture par API aurait été un effet de bord silencieux. |
| S3 | La pose sur une API **active** coupe-t-elle ? faut-il redémarrer ? | **Non et non.** Le `PUT` est accepté, l'API reste `isActive`, et le plan de données HTTPS répond aussitôt. **Hors contrainte ADR-079**, comme la pose du tag en P3. |
| S4 | **LA PORTE** — l'appel en clair est-il refusé ? | **Oui : HTTP 500 « Transport protocol not supported »** en clair, **200 en HTTPS**, sur la MÊME API, pendant que l'API témoin répond 200 en clair. |
| S5 | **LA CONTRE-ÉPREUVE** — le réglage retiré, le clair repasse-t-il ? | **Oui, 200.** Donc c'était bien la policy, pas le port. Corollaire dur : le paramètre est **EXCLUSIF** — `["http"]` ferme le TLS aussi sûrement que `["https"]` ferme le clair. |
| S6 | Le listener : forme rejouable ? `primary` ferme-t-il le clair ? | Un port HTTPS se crée en **recopiant un record relu** (keystore par **alias** ; le contrat publié sous-décrit l'objet). **`enabled` et `primary` sont indépendants** : promouvoir un HTTPS en primaire **ne ferme pas** le HTTP. |
| S7 | Le réglage survit-il à un ré-import de contrat (`PUT` multipart) ? | **Oui.** La pose n'a donc pas besoin d'être rejouée après chaque écriture de définition — contrairement au tag de P3, qui, lui, s'efface (spike D de P0). |
| S8 | Le réglage est-il posable sur une API **INACTIVE**, et survit-il à l'activation ? | **Oui aux deux.** C'est ce qui autorise la position choisie — et donc la promesse « une API gouvernée ne sert jamais un seul appel en clair, pas même pendant sa publication ». |

**Deux sondes de surface, jouées sans rien basculer :**

- **S9 — la promotion en primaire.** `PUT /ports/primary {listenerKey}` répond **200** ; `PUT /ports/{key}/primary` répond 400. Sondé en **NO-OP** (on promeut le port *déjà* primaire) : livrer un appel dont la forme n'a pas été mesurée est ce que ce projet s'interdit, et basculer le port par défaut d'un serveur entier n'est pas quelque chose qu'on mesure dans un lab dont tout dépend.
- **S10 — `clientAuth`.** **Il est honoré à la CRÉATION du port et ne s'édite pas.** `PUT /ports/{listenerKey}` **et** `PUT /ports/{alias}` rendent **200** et la relecture ne bouge pas. Et le champ `alias` vaut « ssos » sur **tous** les listeners HTTPS : `/ports/{alias}` ne désigne même pas un port. Le « quirk 500 sur une modification de port » annoncé par `is-mtls-setup.yml` est en réalité un **200 menteur**, ce qui est pire.

## Décision

### 1. Le refus vit sur l'API, jamais sur la topologie

C'est le point que ce jalon doit faire entrer dans le livrable, parce qu'il est contre-intuitif et qu'il a été mesuré **deux fois** : ajouter un listener HTTPS ne change rien au protocole qu'une API accepte (spike C de P0), et le promouvoir en primaire ne ferme pas le clair (S6). **Un environnement peut avoir un listener HTTPS impeccable et servir toutes ses APIs en clair.** Le seul levier qui refuse l'appel en clair est `entryProtocolPolicy`, et il est **par API**.

### 2. La valeur arrive FINIE de l'autorité — et elle est dérivée de la moitié qui la possède

`labctl posture` rend `entry_protocol`, exactement comme il rend `tag` (P3) et `global_policy` (P4) : le rôle Ansible l'écrit verbatim et ne compose rien. Mais la nouveauté de P5 est **d'où** la valeur est dérivée : de `PerAPIPolicies`, pas du bouquet en général.

```go
func EntryProtocolFor(perAPI []string) string   // "https" ssi https-only ∈ perAPI
```

C'est l'épreuve que P4 avait explicitement demandé d'écrire, rendue **mécanique**. Le jour où quelqu'un déplace `https-only` dans `commonCarriable`, `entry_protocol` devient vide et le rôle cesse de poser — au lieu de laisser l'application partir vers l'objet partagé pendant que `verifyHTTPSOnly` continue de relire l'API. `TestEntryProtocolFollowsTheHalfThatOwnsIt` épingle l'équivalence dans les deux sens ; la mutation correspondante vire au rouge.

### 3. La pose est AVANT l'activation, et la position n'est pas un détail de style

Troisième et dernier geste que la plateforme impose avant de mettre en service, après le tag (P3) et l'appartenance à la cellule (P4). Poser après l'activation ouvrirait une fenêtre — courte, réelle, invisible chez le client — pendant laquelle une API gouvernée `https-only` servirait en clair. La position est **tenable parce que mesurée** (S8), pas parce qu'elle est souhaitable.

L'ordre interne (appartenance **puis** protocole) est lui aussi choisi : le refus le plus probable des deux est `POLICY_COMMUNE_ABSENTE` — une cellule dont le play d'amorçage n'a pas été joué — et il vaut mieux qu'il tombe avant qu'on ait touché à la policy SERVICE de l'API.

### 4. La relecture exige l'ÉGALITÉ STRICTE, jamais l'appartenance

Le paramètre est mesuré **exclusif** (S5). Une liste `['http','https']` **contient** la valeur visée et laisse pourtant passer le clair : un `in` au read-back produirait un vert parfaitement vacant — une API portant le tag d'une posture gouvernée tout en servant en clair. Le refus s'appelle `HTTPS_ONLY_UNCONFIRMED`, et le harnais le mute pour le prouver.

Rappel du piège du produit, le même qu'au P4 : `PUT /policyActions/{id}` exige le corps **enveloppé** `{"policyAction": …}` ; un corps nu rend 200 sans persister.

### 5. Le listener est un play autonome — et il DIT ce qu'il ne fait pas

`ansible/is-https-listener.yml` (rôle `apim_https_listener`) crée le port en **recopiant un record relu**, l'active, relit, et s'arrête là par défaut. Deux gestes de topologie sont derrière des knobs **éteints** : la promotion en primaire (`apim_hl_promote_primary`) et la fermeture d'un port en clair (`apim_hl_close_plaintext_port`) — le seul des trois qui ferme réellement le clair, et qui le ferme pour **tout** ce qui passait par ce port, `/invoke` compris.

Le play ne touche à **aucune** API (vérifié par le harnais) et ne supprime **jamais** un port. Son dernier mot énumère les listeners en clair **restés ouverts** et rappelle où vit le contrôle : sans cela, un play vert laisserait croire que le clair est traité.

### 6. `clientAuth` : le rôle REFUSE au lieu d'écrire

Mesuré non éditable (S10). Écrire puis relire donnerait le même refus, une écriture inutile plus tard ; écrire **sans** relire donnerait un play vert sur un port dont le mode n'a pas bougé. Le rôle pose donc le mode à la **naissance** du port, et sur un port déjà là il refuse en le nommant — `CLIENT_AUTH_NON_CONVERGEABLE` — en énumérant les trois gestes possibles (recréer le port, l'IS Admin, ou viser un autre port).

Une garde symétrique empêche le play de se couper la branche : `PORT_DE_PILOTAGE` refuse de fermer le port par lequel le play parle à la gateway, faute de quoi la relecture qui doit constater la fermeture n'aurait plus de canal.

### 7. Le proxy d'administration n'a RIEN à gagner

Contrairement à P4, qui laissait deux lectures manquantes, ce jalon n'ajoute **aucune** entrée à l'allow-list ADR-075 : `GET /apis/{id}`, `GET /policies/{id}`, `GET`/`PUT /policyActions/{id}` y sont déjà. Le play de **listener**, lui, parle à `/ports`, qui n'y est pas — c'est cohérent : il tourne sous identifiant IS-admin, hors du pipeline, comme le play d'amorçage de P4.

## Conséquences

- **Une API gouvernée n'est plus joignable en clair, et c'est une rupture pour ses appelants.** Ce n'est pas la plateforme qui coupe — l'API reste active, le data-plane HTTPS répond, rien au sens d'ADR-079 — c'est le contrôle qui s'applique. La distinction appartient à la conduite du changement : sur un environnement où des consommateurs appellent en clair, la première publication gouvernée les casse. À dire au client avant, pas après.
- **Tout harnais qui mesurait le plan de données en clair mesurait autre chose depuis ce jalon.** Celui de P4 lisait le refus de PROTOCOLE là où il attendait un 429 : sa contre-épreuve virait au rouge sans rien dire de la cellule. Corrigé — il passe désormais par `scripts/lib/wm-dataplane.sh`, qui appelle sur le canal que l'API **accepte** (et par le conteneur, le listener HTTPS du lab n'étant pas publié). P4 rejoué **38/0**.
- **Le listener HTTPS devient un préalable d'environnement.** Sans lui, une API gouvernée n'est joignable par **aucun** canal. Le play est là pour ça, et son refus `HTTPS_LISTENER_SANS_GABARIT` renvoie à l'IS Admin quand aucun port HTTPS n'existe encore : la forme d'un port n'est pas inventable, le contrat publié ne décrit ni `keyStore` ni `trustStore`.
- **`is-mtls-setup.yml` porte un chemin d'écriture douteux**, découvert ici : il converge `clientAuth` par `PUT /ports/{alias}` alors que `alias` n'est pas discriminant et que le `PUT` ne persiste pas. Son read-back fail-closed le rattrape — il échoue bruyamment plutôt que de mentir — mais la tâche ne peut pas réussir sur ce build. Non corrigé par ce jalon (hors périmètre P5, et ADR-076 en est propriétaire) ; nommé plutôt que tu.

## Ce que ce jalon ne fait pas

- **Il ne bascule pas le port primaire.** La forme de l'appel est mesurée ; la bascule ne l'est pas, et le knob est éteint. Elle ne protège d'ailleurs rien (S6).
- **Il ne ferme pas le clair au niveau du serveur** par défaut. Le knob existe, mesuré (`PUT /ports/disable`), éteint.
- **Il ne touche pas au truststore ni aux CA.** Le JKS n'est relu qu'au démarrage de l'IS : y importer une CA exige un redémarrage, ce que fait `is-mtls-setup.yml` et que ce rôle ne fait pas.
- **Il ne lève pas l'écart #1 d'ADR-091** (`threat-protection`), que P4 a précisé : le contrôle existe côté produit mais n'est pas déclinable par cellule. Une API `exposure=internet` reste structurellement rouge à l'apply.

## Épreuves

| Épreuve | Ce qu'elle tient |
|---|---|
| `python3 scripts/spike-p5-https.py all` | **34 ✅ / 0 ❌**, 8 verdicts, rejoué — les faits produits, actifs jetables nettoyés |
| `python3 scripts/spike-p5-https.py S9` / `S10` | les deux sondes de surface (promotion en no-op, `clientAuth`) |
| `bash scripts/test-p5-https.sh` | **54 ✅ / 0 ❌** — A autorité, B rôles hors ligne, C bout en bout live, D 6/6 mutations |
| `cd labctl && go test ./... && go vet ./...` | **561 ✅ / 0 ❌**, vet propre |
| `bash scripts/test-p4-global-policy.sh` | non-régression **38/0** (après portage de la mesure sur le canal TLS) |
| `bash scripts/test-p3-tag-plateforme.sh` | non-régression **24/0** |
| `bash scripts/test-p2-posture-producteur.sh` | non-régression **67/0** |
| `make lint-ci` | vert, sans ligne ajoutée à la dette |
