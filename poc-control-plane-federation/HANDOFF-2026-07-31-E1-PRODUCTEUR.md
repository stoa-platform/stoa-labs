# HANDOFF — 2026-07-31/08-02 : E1, le producteur — ce que le produit ne garantit pas

_Dépôt `stoa-labs`, branche `docs/e1-producteur-gitops-spec`. Session `/goal E1`,
méthode habituelle : brainstorm → spec → plan → exécution avec portes de preuve._

## En une phrase

La porte de preuve que le GOAL donnait à E1 était **fausse** — le produit
n'oppose aucun refus cross-team à l'identité que la chaîne porte — et le
cloisonnement des APIs est donc une propriété **de la chaîne**, désormais
construite, prouvée par cinq portes et trois sabotages.

---

## 1. Ce que la mesure a renversé

Le GOAL attendait de E1 : *publication cross-team **refusée 400** « User cannot
assign the specified team to API »*, d'après le spike #1 du 2026-07-09 (lab
Docker). Rejoué sur la gateway du cluster, ce refus **n'existe pas**.

| Geste | Identité | Observé |
|---|---|---|
| `POST /assets/team` — **sa propre** API, **sa propre** team | `svc-banking-demo` | **401** « not authorized to perform: POST on the resource: assets » |
| idem, team d'une autre équipe | `svc-banking-demo` | **401**, message identique |
| `GET /apis/{id}` d'une autre équipe | `svc-insurance-demo` | **401** « User doesn't have permission to manage this API » |
| Déplacer une API de `banking-demo` vers `insurance-demo` | **admin** | **200** — **aucun refus** |
| `POST /apis` multipart | `svc-banking-demo` | **201** — l'équipe **peut** publier |
| Team de l'API ainsi créée | — | **`Default`** ; une équipe tierce la lit **200** |
| Témoin : `GET` de sa propre API | `svc-banking-demo` | **200** |

Le produit ne refuse pas *le cross-team* : il refuse la ressource `assets` à
**tout non-admin**. Or assigner une team est précisément ce qu'il faut faire pour
cloisonner — donc la chaîne tourne en admin, et à l'admin rien n'est opposé.
**C'est le même nœud que la garde 3 de E3** : celui qui peut cloisonner est celui
à qui rien n'est refusé.

**Découverte non prévue** : une équipe publie hors chaîne, en `Default`, lisible
par toutes. E3 parlait pour les applications d'« un geste qu'on peut oublier » ;
ici l'équipe **ne peut pas** faire le geste.

---

## 2. L'écart entre les deux moteurs, que personne n'avait relevé

`apim_selfservice_app` (consommateur) a été durci le 2026-07-31.
`apim_publish_api` (producteur) ne l'avait pas été — il portait son propre
avertissement, « ⚠ NON TESTÉ LIVE », depuis l'origine.

| | Producteur, avant | Consommateur |
|---|---|---|
| `assetType` dans le POST | **absent** → 200 no-op silencieux | présent |
| Relecture fail-closed | **aucune** | `TEAM_CONFIRMED` |
| Origine de l'équipe | le manifeste **que l'équipe écrit** | pipeline > manifeste |
| Assignation obligatoire | **non** | fail-closed |
| `verify` contrôle la team | **non** | oui |

Les cinq sont corrigés, plus un ajout propre au producteur : **`TEAM_FORBIDDEN`**
— une divergence du manifeste **échoue** au lieu d'être ignorée. Ignorer une
demande cross-team la rendrait indétectable des deux côtés ; la faire rougir la
porte au statut de commit.

---

## 3. Les portes, le 2026-08-02

Depuis un pod agent portant le SA `jenkins-agent` — pas depuis le contrôleur
Jenkins, qui reçoit **403** au login Vault. Ce refus est la **mécanique G-c qui
marche** : mesurer depuis le contrôleur aurait mesuré autre chose que la chaîne.

| Porte | Mesure |
|---|---|
| **P-1** | `TEAM_CONFIRMED`, teams `['Administrators','banking-demo']`, `Default` retirée ; témoin **200** / tiers **401** ; catalogues divergents |
| **P-2** | `TEAM_FORBIDDEN`, **et `e1-cross-api` absente du catalogue** |
| **P-3** | `assetType` retiré → POST **200**, teams **inchangées**, `TEAM_UNCONFIRMED` |
| **P-4** | `TEAM_UNDEFINED` |
| **P-5** | `MANIFEST_KEYS_FORBIDDEN` sur `apim_ss_api_base` |
| contre-épreuve | `verify` à qui on ment sur la team → `PUBLISH_UNCONFIRMED` |

P-4 et P-5 joués avec la base d'admin sur un **port mort** : aucune socket
ouverte. Les gardes précèdent le réseau, donc un refus ne laisse rien derrière
lui. Nettoyage : `e1-gate-api` désactivée (200) puis supprimée (204), catalogue
rendu à son état d'avant.

**P-3 est la porte qui mérite d'être retenue** : la gateway répond 200 et ne fait
rien. Un pipeline qui se fie au code de retour publie une API non cloisonnée en
croyant l'avoir cloisonnée.

---

## 4. Deux erreurs de la passe

- **J'ai écrit un plan sur une prémisse fausse.** `ci/Jenkinsfile.publish-api`
  **existait déjà** — le pendant producteur de `Jenkinsfile.selfservice`, qui
  lançait déjà le rôle Ansible. Mon exploration ne l'avait pas vu, et le plan
  demandait de le *créer*. J'ai failli l'écraser ; seule la garde « lire avant
  d'écrire » l'a empêché. Conséquence de fond : D1 était déjà à moitié acquis, et
  il y a **deux** chaînes productrices, pas une.
- **J'y ai introduit une régression.** Ce pipeline ne passait pas
  `apim_ss_team` ; en rendant l'équipe obligatoire, tout apply aurait échoué sur
  `TEAM_UNDEFINED`. Corrigé en y portant la dérivation du chemin consommateur.
  Une garde fail-closed casse les appelants qu'on n'a pas inventoriés — les
  chercher fait partie de l'écriture de la garde, pas du service après-vente.

---

## 5. Ce qui te revient (gestes exploitant)

**1. Reposer le job GitOps en `CpsFlowDefinition` — c'est le vrai reste-à-faire
de E1.** Le job actuel (`docs/superpowers/plans/2026-07-29-f4-jenkins-publish-job.xml:36-53`)
est un `CpsScmFlowDefinition` de `scriptPath: Jenkinsfile` **pris dans le dépôt
de l'équipe**. Tant qu'il en est là, l'équipe écrit son propre `TEAM` **et** le
`serviceAccount` de son podTemplate — donc l'identité qui ouvre Vault. Les
gardes sont réelles, leur **autorité** ne l'est pas.

Trois choses à poser, dans cet ordre :

- un dépôt **plateforme** dans Gitea (`stoa/platform`) portant
  `poc-control-plane-federation/` — le job y prend le rôle Ansible ;
- le job en `CpsFlowDefinition`, script **inline**, `TEAM` en dur (une valeur
  par équipe, cf. E5) — le contenu à coller est
  `ci/Jenkinsfile.publish-api` § « copie de reconstruction » ;
- **retirer le `Jenkinsfile` du dépôt `banking-demo/accounts-api`**, sans quoi
  il reste une porte d'entrée.

Contre-épreuve à jouer derrière : pousser dans le dépôt d'équipe un manifeste
avec `team: insurance-demo` → le build doit rougir sur `TEAM_FORBIDDEN` et le
commit porter un statut rouge. Si le build passe, l'autorité n'est pas où on
croit.

**2. Décider de D6 (retirer la création d'API aux comptes `svc-<team>`).** Non
fait, et pas faisable à l'aveugle : le bitmask est **opaque en REST**
(`/accessProfiles/privileges`, `/privileges`, `/permissions`,
`/accessProfiles/permissions` → **404** les quatre) et les deux équipes de
démonstration ont **exactement** le bitmask du profil système
`API-Gateway-Providers`, sans un bit d'écart — elles n'ont jamais été
restreintes. Protocole : lire les noms dans la console (joignable depuis ton
correctif du 2026-07-31), **puis** prouver par bit-flip sur un profil **jetable**
(10 bits à 1 : positions 0-3, 6, 8-9, 11-12, 20). Ne rien écrire sur
`banking-demo`/`insurance-demo` avant que le nom lu et l'effet mesuré
concordent, et capturer le bitmask d'avant comme rollback.

**Garde-fou de ce changement** : après retrait, trois conditions, pas une.
`POST /apis` par l'équipe → 401 (la brèche est fermée) ; `GET /apis` scopé →
**toujours vert** ; l'identité sortante de E2 → intacte. Si l'une des deux
dernières rougit, remettre le bitmask et consigner la brèche comme dette :
casser une preuve acquise pour fermer une brèche de lab serait un mauvais
échange, d'autant que le modèle cible la ferme en ne donnant aucun compte
gateway aux équipes produit.

**3. Rien à merger côté `stoa`** — cette passe n'a touché que `stoa-labs`.

## 6. Comment rejouer la preuve

Tout est rejouable, secrets hors dépôt (`/root/f4-teams.env`, 0600, root — il
porte désormais aussi `WM_ADMIN_PW`).

```bash
# La matrice de refus par identité (ce qui a renversé la porte du GOAL)
ssh worker-1 'sudo /root/e1-matrice-refus.sh'      # docs/superpowers/plans/2026-07-31-e1-matrice-refus.sh
# Les bitmasks des accessProfiles (lecture seule)
ssh worker-1 'sudo /root/e1p.sh'                   # …/2026-07-31-e1-privileges.sh
# Le volet lecture des portes (nécessite qu'une API de porte existe)
ssh worker-1 'sudo /root/e1-portes.sh'             # …/2026-07-31-e1-portes.sh
```

Les gardes **hors ligne** se rejouent sans cluster ni secret, en quelques
secondes — c'est la boucle rapide :

```bash
cd poc-control-plane-federation
ansible-playbook -i ansible/inventory.lab.ini ansible/test-publish-guards.yml \
  -e apim_ss_manifest=ansible/tests/e1/manifest-crossteam.yml -e apim_ss_team=banking-demo
# attendu : MANIFEST_KEYS_OK puis échec TEAM_FORBIDDEN
```

Le volet **écriture** exige un pod portant le SA `jenkins-agent` (le contrôleur
Jenkins reçoit **403** au login Vault — c'est la mécanique G-c qui marche, pas
une panne) : recette complète au § « Preuve d'exécution » du plan.

## 7. Deux choses à savoir sur l'état du dépôt

- **La branche `docs/e1-producteur-gitops-spec` porte aussi deux de tes
  commits** (`88c032b`, `55feba0`, sur la spec allowlist) — tu travaillais
  dessus en parallèle. Rien n'a été écrasé, mais la branche n'est pas
  mono-sujet : à savoir avant d'ouvrir la PR.
- **Les deux chaînes productrices ne convergent pas**, et c'est assumé :
  fidèle-client = identité nominative + team dérivée du chemin KV tenant-scopé
  (infalsifiable par la policy Vault) ; GitOps cluster = identité de pod + team
  du job. Les unifier demanderait un SA k8s, un rôle Vault et un chemin KV par
  équipe — c'est E5, pas E1.

---

## 8. Ce qu'il faut garder de cette passe

**Une porte de preuve peut être fausse sans que rien ne le signale.** Celle de E1
était écrite depuis le 2026-07-09, citée dans deux GOAL et une spec, et elle
décrivait un refus que la plateforme n'oppose pas. Elle n'a pas été démentie par
une alerte : elle l'a été parce qu'on est allé la rejouer avant de coder contre
elle. C'est le même motif que les six garde-fous du handoff F5 — aucun trouvé par
une alerte, tous par diagnostic.

_Socle empirique : `docs/superpowers/plans/2026-07-31-e1-matrice-refus.sh` et
`…-e1-privileges.sh` et `…-e1-portes.sh` (rejouables, secrets hors dépôt) ;
§ « Preuve d'exécution » de `docs/superpowers/plans/2026-07-31-e1-producteur-gitops.md` ;
spec `docs/superpowers/specs/2026-07-31-e1-producteur-gitops-design.md`._
