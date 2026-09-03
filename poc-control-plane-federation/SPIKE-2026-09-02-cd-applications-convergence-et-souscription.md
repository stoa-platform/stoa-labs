---
title: "SPIKE — Convergence d'application en vol, et souscription à une API absente ou inactive (wM 10.15 réelle)"
type: spike
date: 2026-09-02
lié: [GOAL-cd-applications-2026-09-02, adr-078-livrable-self-service-app-wm1015, adr-079-deploiement-promotion-multienv-import-archive, oracle-idp-gateway-sync]
statut: "JOUÉ — scripts/spike-cd-applications.py, 34/0 sur apigateway-trial 10.15 réelle (poc-webmethods-real), assets jetables spikecd-* nettoyés par trap ; quatre passes + cinq sondes manuelles pour caractériser le seul comportement surprenant (désinscription irréversible)."
---

# SPIKE — les deux trous « PAS tranchés » du GOAL CD des applications

**Question 1 (trou n°3 du GOAL).** Que fait la 10.15 pendant qu'on *converge* une application active — `PUT /applications/{id}` (identifiers), `PUT /policyActions/{iam}`, `PUT /policies/{id}` — sous trafic identifié par cette application ? Et que valent les deux gestes de *retrait* (suspension, désinscription) : fenêtre fantôme au retrait, latence à la restauration ?

**Question 2 (trou n°2 du GOAL).** Que fait la gateway quand une application souscrit à une API **absente** (UUID inexistant) ou **inactive** ? Et que fait le moteur de convergence (`scripts/apply-selfservice-application.py`) dans les deux cas ?

**Méthode.** Une API jetable `spikecd-api` (backend `poc-token-echo`, activée), une application jetable `spikecd-app` identifiée par clé API via une règle IAM `AND(apiKey)` strict posée **exactement comme le moteur le fait** (mêmes corps que `apply-selfservice-application.py` §3/§5). Trafic : 4 fils en boucle, chaque requête horodatée avec son code. Chaque geste admin est chronométré ; les codes sont ventilés **avant / pendant / après** le geste. Baselines vérifiées avant chaque mesure : avec clé 200, sans clé 401.

---

## Résultats — question 1 (convergence en vol, retrait, restauration)

| Mesure | Résultat | Verdict |
|---|---|---|
| Convergence complète sous trafic (PUT app ×2, PUT IAM, PUT policy) | **4822 requêtes, 0 non-200** ; passes précédentes 278/0, 3679/0, 1869/0 | **0-coupure.** GUID d'application et clé identiques au read-back. |
| Fenêtre du `PUT /applications` n°1 | 616 ms admin, 685 req dans la fenêtre, 0 non-200 (une passe a mesuré 6 à 7 s d'admin — toujours 0 non-200) | Le temps admin varie, jamais l'effet en vol. |
| Suspension `isSuspended: true` sous trafic | 200 en 675 ms ; **3338 req après, 0 fantôme 200**, tout en 403 | **Retrait immédiat.** |
| Levée de suspension sous trafic | 200 ; **1245 req après, 0 refus tardif** ; même GUID, même clé | **Restauration immédiate, réversible.** |
| Désinscription `DELETE /applications/{id}/apis?apiIDs=` sous trafic | **204** (pas 200) en 2,3 s ; 1316 req après, 0 fantôme, tout en 401 | **Retrait immédiat.** |
| Ré-inscription `PUT …/apis` après cette désinscription | **500 `{"errorDetails": null}` ×12 sur 21 s** | Voir la caractérisation ci-dessous. |
| `PUT …/apis {"apiIDs": []}` | **500** | Ce n'est pas une primitive de retrait. |
| `PUT …/apis [autre API]` sur une app déjà inscrite à une première API | 200 ; relecture = **[autre API] seule** | **`PUT …/apis` REMPLACE la liste, il n'ajoute pas.** |

### Caractérisation de la ré-inscription refusée (cinq sondes manuelles)

| Sonde | Séquence | Résultat |
|---|---|---|
| P1 | inscription → **aucun trafic** → DELETE → PUT | 200 après 2 s |
| P4c | idem, PUT immédiat | **200 immédiat** |
| P3 | inscription → 20 requêtes servies → DELETE → PUT toutes les 5 s | **500 pendant 150 s, jamais 200** |
| P3b / P3c | idem + création d'une API étrangère entre-temps ; idem + PUT de remplacement vers une autre API (200) puis retour | 500 / 500 — le remplacement vers l'autre API passe, le retour vers la première est refusé |
| P4 | idem + 60 requêtes **refusées** (401) avec la clé entre les PUT | 500 |
| P4b | la même API avec une **nouvelle** application ; la même application avec une **nouvelle** API | 200 / 200 — ni l'API ni l'application ne sont brûlées, **la paire** l'est |
| S1-T4 (passe 4) | ~45 s et ~1300 requêtes refusées après le DELETE, puis PUT [autre] 200, puis PUT [première] | **200** — une seule réussite, non reproduite |

Log gateway au moment du 500 : `[YAI.0003.0016E] Unable to process the PUT request for application. Error occurred while processing the payload. Error Message:` — **message vide**. Aucune trace côté produit de la cause.

**Verdict opérationnel.** Une paire application/API qui a **servi du trafic** puis a été **désinscrite** ne se ré-inscrit plus de façon prévisible : refus 500 sans message, sans délai mesurable, une réussite sur six essais. C'est le motif « retrait ≠ révocation » de `oracle-idp-gateway-sync`, vu de l'autre côté : le cache d'identification de la paire survit à la désinscription et bloque la ré-inscription. **La chaîne CD ne doit jamais désinscrire.** Le retrait d'une application est une **suspension** — immédiate, réversible, 0 fantôme. Un redémarrage de la gateway n'a pas été mesuré comme remède (le recyclage keepalive de ~20 min n'a pas été attendu).

---

## Résultats — question 2 (API absente ou inactive)

| Mesure | Résultat | Verdict |
|---|---|---|
| `PUT …/apis` avec un UUID inexistant | **400** `One (or) more API(s) doesn't exist` ; relecture : aucun fantôme | **Refus propre.** La gateway garde cette porte. |
| `PUT …/apis` vers une API créée **non activée** | **200**, souscription présente en relecture | **Acceptée.** La gateway ne garde PAS cette porte. |
| Trafic vers l'API inactive avec la clé | 404 | Une API inactive ne sert rien. |
| Activation de l'API ensuite | trafic 200 ; souscription toujours présente | La souscription posée sur l'inactive **survit et sert**. |
| Moteur, API **absente** (`api: spikecd-nope`) | **rc 1**, `[✗] API 'spikecd-nope' publiée résolue` | Fermé — mais c'est un échec de résolution, pas une porte nommée. |
| Moteur, API **inactive** (`api: spikecd-inactive`) | **rc 0**, application, IAM et injection posées | **Le moteur pose tout sur une API qui ne sert pas.** |
| Moteur, résolution (lecture du code) | `get("apiName") == api_name` — **ni version, ni `isActive`** ; avec deux versions publiées il prend la première rencontrée | La porte A5 n'existe nulle part. |

**Verdict.** La gateway refuse l'inexistant et accepte l'inactif ; le moteur fait pareil, et ne connaît pas la version. La porte A5 (« l'API est au palier, dans cette version, active ») est **entièrement à écrire côté chaîne**, et elle doit être **antérieure** au `PUT …/apis` : une souscription posée puis retirée brûle la paire (question 1).

---

## Ce que ce spike change dans le GOAL

1. **A6 est fondé** : la convergence est 0-coupure, GUID et clé stables — le rollback par re-convergence est un apply comme un autre. Mais **deux règles** s'ajoutent : jamais de désinscription ; le retrait est une suspension.
2. **A5 est plus large qu'écrit** : `name + version + isActive`, avant tout PUT, refus nommé (`API_NOT_PROMOTED`, `API_INACTIVE`, `API_VERSION_MISMATCH`).
3. **A1 porte une contrainte mesurée** : `PUT …/apis` remplace la liste ; « une application = une API » n'est pas une simplification, c'est ce qui empêche une convergence de désinscrire en silence.
4. **Le moteur a une dette nommée** : résolution par nom seul (`apply-selfservice-application.py:110-113`), `PUT …/apis` mono-API (`:125`). À corriger dans le prototype ou au fold-in `labctl apply-consumer`, pas dans la chaîne.

## Ce que ce spike n'a pas mesuré

- L'effet en vol d'une convergence identifiée par **claim `azp` / JWT** (la voie réelle des apps `idp`) : le trafic du spike est identifié par clé API. Le mécanisme sous PUT est le même objet application ; la stratégie OAuth2 a son propre cache (`oracle-idp-gateway-sync`) — à rejouer en JWT avant A7.
- Si un redémarrage de la gateway débloque la ré-inscription d'une paire brûlée.
- Le comportement du **mock** `wm-mock-*` sur ces mêmes primitives (le terminus du lab est un mock, G7) : à vérifier au moment d'A7.

**Rejouer :** `python3 scripts/spike-cd-applications.py` (gateway réelle sur `localhost:5555`, `Administrator/manage` par défaut, ~4 min, nettoyage par `finally`).
