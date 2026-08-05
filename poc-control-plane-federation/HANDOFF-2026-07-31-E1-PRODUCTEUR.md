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

## 5. D2 — l'autorité, FAITE et prouvée par push

**Le vrai reste-à-faire de E1 est fermé le 2026-08-02.** Le job de publication
était un `CpsScmFlowDefinition` pointant `scriptPath: Jenkinsfile` **dans le
dépôt de l'équipe** : elle écrivait donc son propre `TEAM` et le
`serviceAccount` de son podTemplate. Les gardes étaient réelles, leur autorité
ne l'était pas.

Trois gestes, chacun relu :

- **dépôt plateforme** : le rôle Ansible est poussé dans `ci/stoa-labs`
  (1220 fichiers). Le job y prend son moteur ;
- **job en `CpsFlowDefinition` inline** : seul l'élément `<definition>` est
  remplacé, le reste du `config.xml` est conservé tel quel — réécrire tout
  aurait perdu le **jeton de webhook**, qu'on ne connaît pas ;
- **`Jenkinsfile` retiré** du dépôt d'équipe. Il ne reste que `README.md`,
  `apis/` et un manifeste Ansible qui **ne dit pas** sous quelle équipe publier.

**La contre-épreuve, par push réel dans le dépôt de l'équipe :**

| Build | Ce qui est poussé | Résultat | Statut de commit Gitea |
|---|---|---|---|
| **#12** | manifeste légitime | **SUCCESS** — `TEAM_CONFIRMED` puis `PUBLISH_CONFIRMED` sur `accounts-read` | `success` |
| **#13** | manifeste réclamant `team: insurance-demo` | **FAILURE** — `TEAM_FORBIDDEN` | **`failure`** |
| **#14** | remise en état | **SUCCESS** | `success` |

C'est la seule mesure qui dit où est l'autorité : l'équipe a écrit la demande
cross-team **dans son propre dépôt**, et le build a rougi. Le signal remonte
jusqu'au commit — elle le voit sans qu'on ait à le lui dire.

**Trois pièges de l'API Jenkins, payés et consignés dans les scripts :**

- **le crumb est lié à la SESSION.** Demander `/crumbIssuer` puis POSTer sans
  reporter le cookie donne « No valid crumb was included in the request » — un
  403 qui parle du crumb alors que le crumb est bon.
- **sans `charset` déclaré, Jenkins décode le corps en latin-1.** Le
  `config.xml` revient avec un `0x80` et le parseur rend un **500 « invalid XML
  character »**. Ce qui l'a démontré, c'est d'avoir reposté le config
  **inchangé** : il échouait aussi. Le contenu était bon, l'en-tête ne l'était pas.
- **le pod Jenkins n'a pas `curl`** — les appels passent par le pod `gitea`, ou
  par worker-1, qui atteint les ClusterIP directement.

**2. D6 — FAIT le 2026-08-02, et il a fallu trois tentatives.** La brèche
« une équipe publie hors chaîne, en `Default`, lisible par toutes » est
**fermée sur le labo**.

| Condition | Attendu | Mesuré |
|---|---|---|
| `POST /apis` par l'équipe | 401 | **401** — la brèche est fermée |
| `GET /apis` scopé | 200 + ses APIs | **200** `['accounts-read','carto-probe-api']` |
| isolation : insurance → `accounts-read` | 401 | **401** |
| `GET /applications` (E2 en dépend) | 200 | **200** |
| **P-1 rejouée après D6** | `TEAM_CONFIRMED` | **`TEAM_CONFIRMED`** — la chaîne n'est pas cassée |

**Le levier, c'est les deux ensemble** : bitmask restreint
`000000101101100000001` (bits 0-5 retirés) **et** retrait du compte d'équipe du
groupe système `API-Gateway-Providers`. Rollback dans
`/root/e1-d6-rollback.txt` et `/root/e1-d6-rollback-groupe.txt` (root, 0600).

**Le chemin pour y arriver vaut d'être lu, parce qu'il corrige trois croyances :**

- Le dépôt tenait que « un user d'équipe doit AUSSI être membre de
  `API-Gateway-Providers`, sinon 403 ». **Pas nécessaire** : un user membre du
  seul groupe d'un profil jetable crée quand même. Le 403 de F4 venait d'un user
  **sans profil**.
- **Mais pas suffisant pour conclure.** J'ai écrit « ce n'est donc pas ce qui
  gouverne » — j'affirmais plus que la mesure ne permettait. Il n'est pas
  nécessaire, il reste **suffisant** : les privilèges **s'unionnent** sur tous
  les profils de l'utilisateur. La première application l'a montré, en rougissant.
- **Retirer un bit ne retire rien** : les neuf bits testables, ôtés un par un,
  laissent `POST /apis` à 201. La création est portée par un **OU de bits en
  positions 0-3**. Et la position 20 n'a pas pu être écrite — `PUT` 200, mais
  relu sur **13 caractères au lieu de 21** : **les zéros de fin sont tronqués au
  stockage**.

**Ce qui a sauvé la manœuvre, c'est la garde, pas la perspicacité.** La première
application posait le bon bitmask, le relisait conforme, et laissait pourtant
`POST /apis` à 201. Sans les quatre contre-épreuves et le rollback automatique,
D6 aurait été déclaré fait sur une lecture qui disait vrai — le bitmask *était*
écrit — mais qui ne mesurait pas ce qui compte.

⚠ **Ce que D6 ne ferme pas** : `GET /apis` reste **200 quel que soit le
bitmask**, vide compris. La lecture n'est pas gouvernée par ce champ ; c'est
l'assignation de team qui la scope. D6 ferme l'écriture, pas la visibilité.

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
