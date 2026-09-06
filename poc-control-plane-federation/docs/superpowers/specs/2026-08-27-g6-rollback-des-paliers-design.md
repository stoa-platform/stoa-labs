# G6 — Le repli, comme composant du déploiement

**Date** : 2026-08-27. **GOAL** : `GOAL-cd-promotion-5-envs-2026-08-26.md`, jalon G6.
**Porte du GOAL** : rollback exercé sur **homol** — retour au SHA N-1, smoke vert,
trace Git de l'acte.
**Contre-épreuve du GOAL** : rollback **sans référence de changement** sur un palier
qui l'exige ⇒ refus.
**Qualification à ne pas dépasser** (écrite dans le GOAL, à reproduire dans l'ADR) :
l'art. 17(1)(e) du RTS DORA (règlement délégué (UE) 2024/1774) exige d'**identifier**
les procédures de repli et leurs responsabilités, pas de les tester. On teste parce
que c'est sérieux — l'argument « tester » s'adosse à (c) *controlled testing* ou à
DORA niveau 1, jamais à (e) seul.

---

## §1 — Ce que le relevé a mesuré (2026-08-27)

1. **Le moteur de rollback est DÉJÀ générique par environnement.**
   `handlers_rollback.go:17-157` ne connaît aucun nom de palier : il revert
   `deploy.{promo.To}.yaml` au contenu N-1 **VERBATIM — pin `commit` compris**
   (`ReadFile(prevSHA, deployPath)`, jamais re-synthétisé), marque la promotion
   `rolled_back`, commite sur main avec trailers + evidence pack, et répond
   `restored: {environment, version, commit}`. Le « motif » que le GOAL nomme
   existe donc pour TOUS les paliers ; ce qui est prod-only, c'est la couche
   Jenkins au-dessus.

2. **L'asymétrie de gardes entre la demande et le rollback.** À la demande
   (`handlers_promotions.go:81-90`), le change_ref est exigé si
   `gate.RequireChangeRef || gate.ITSMCheck` et le pv_ref si `gate.RequirePVRef`.
   Au rollback (`handlers_rollback.go:53-58`), seul `gate.RequireChangeRef` est
   testé. Sur la chaîne du gabarit (prod porte les deux) l'écart est invisible ;
   sur une chaîne où un palier ne porterait que `itsmCheck`, un rollback y
   passerait sans change_ref alors que la demande l'exige — un trou de symétrie.

3. **`ci/Jenkinsfile.rollback` est prod-only par TROIS ancrages**, tous dans les
   stages aval du POST : `apply-uac --env prod -f envs/prod/targets.cluster.yaml`
   (l.144-145), le smoke data-plane `gateway/accounts-read/1.0.0/accounts` attendu
   401 (l.156-160), et le chemin de credential (ci-applier + Vault, admin DIRECT —
   le régime du terminus). Le stage `Rollback governance` lui-même est déjà
   env-agnostique : `PROMOTION_ID` détermine le palier, et la réponse du POST
   **contient** `restored.environment`.

4. **Le pipeline amont a déjà le régime deux-voies que le rollback doit refléter.**
   `ci/Jenkinsfile` (hors-prod) dérive la chaîne de `governance/environments.yaml`
   **privée de son terminus** (`e[:-1]` — barrière STRUCTURELLE, pas nominale) et
   applique chaque palier via son proxy admin `wm-admin-<env>` avec le Bearer
   `ci-horsprod` (scope `deploy:<env>`, jamais celui du terminus) ; `Jenkinsfile.prod`
   sert le terminus en admin direct avec les secrets Vault. Le re-apply d'un
   rollback est un apply comme un autre : il doit emprunter la même voie que son
   palier.

5. **G2 s'applique au re-apply du rollback.** Le preflight déployeur d'apply-uac
   vérifie au dispatch la policy `apply-<env>` (int, homol : `deployerGroup:
   apim-apply-<env>`) ou `operator-deploy` (prod). Conséquences mesurables : le
   re-apply machine vers int/homol exige `setup-vault-paliers.sh --grant-ci`
   (déclaration « le CI est porteur hors-prod », handoff G2 geste 2), et le repli
   AppRole du rollback prod est désormais refusé `DEPLOYER_GROUP_REQUIRED` — même
   conséquence assumée que pour `Jenkinsfile.prod` (gabarit environments.yaml,
   bloc prod).

6. **Le verbe reste apply-uac, et c'est un choix déjà tranché ailleurs.** La
   conversion du pipeline governance au verbe archive est une tension **parquée
   nommément** dans ADR-083 (« sa conversion se conçoit avec la parité G8, pas en
   silence »). G6 n'y touche pas : le rollback re-applique l'état désiré N-1 par
   le même verbe que le pipeline aller de sa chaîne. La limite 0-coupure de ce
   verbe sur une API active est celle du pipeline aller — elle appartient à G8.

7. **Couverture de preuve existante** : 3 tests offline
   (`handlers_rollback_test.go` : restauration verbatim + evidence, NO_PREVIOUS_STATE,
   NOT_APPROVED) sur la chaîne fixture 4 paliers `[dev,rec,int,prod]`. **Aucun test
   du refus `GATE_REFS_REQUIRED` au rollback**, aucun test sur un palier de type
   homol (pv-only), aucun exercice live d'un rollback hors-prod. Le job Jenkins
   rollback est un job Pipeline-from-SCM posé à la main (runbook `ci/README.md`),
   sans `job.xml` — le paramétrage vit entièrement dans le Jenkinsfile.

8. **Plomberie homol** : posée par G5 (proxy `wm-admin-homol` créé, matrice 20/0 ;
   policies `apply-<env>` étendues ; secret `envs/homol/wm-admin`). L'en-tête de
   `envs/homol/targets.cluster.yaml` (« plomberie non posée ») date de la création
   G1 et est périmé — à corriger au passage. Points à re-vérifier live en début
   d'exécution : scope `deploy:homol` du client `ci-horsprod` (dérivé de la chaîne
   par `setup-ci-horsprod.sh` depuis G1), groupe KC `release-team`
   (`setup-release-team.sh`, geste G1 dont l'exécution n'est pas confirmée), état
   du seed `seed-governance-chain.sh` sur le dépôt governance du lab.

---

## §2 — Décisions de conception

**D1 — Le palier du rollback n'est JAMAIS saisi par l'opérateur : il est celui de
la promotion.** Le job ne gagne aucun paramètre `TARGET_ENV`. La réponse du POST
rollback porte `restored.environment` ; le Jenkinsfile la capture et la propage aux
stages aval (fichier de workspace). Toute saisie d'environnement recréerait une
classe d'erreurs (rollback de la promo X « au nom » du palier Y) que la source de
vérité rend impossible. Fail-closed : `restored.environment` absent ou hors de la
chaîne lue dans le clone governance post-revert ⇒ le build échoue AVANT tout apply.

**D2 — Terminus par POSITION, pas par nom.** Le re-apply choisit sa voie en
comparant le palier restauré au DERNIER élément de la chaîne dérivée
(`environments.yaml` du clone post-revert) — le même motif structurel que
`env_chain_nonprod` et que `e[:-1]` de `ci/Jenkinsfile` :
- **terminus** → voie existante inchangée : ci-applier + secrets Vault, admin
  direct, `envs/<terminus>/targets.cluster.yaml` ;
- **palier intermédiaire** (rec, int, homol) → la voie du pipeline aller hors-prod :
  Bearer `ci-horsprod` scope `deploy:<env>` via le proxy `wm-admin-<env>`,
  `envs/<env>/targets.cluster.yaml`.
Le premier palier de la chaîne (authoring, dev) n'est pas un cas : structurellement,
aucune promotion n'a `To == chain[0]` (`NextOf` ne rend jamais le premier élément) —
le Jenkinsfile le refuse quand même par assertion (défense en profondeur, message
`ROLLBACK_ENV_INELIGIBLE`).

**D3 — Alignement des gardes de référence au rollback sur celles de la demande,
pour le change_ref seulement.** `handlers_rollback.go` passe de
`gate.RequireChangeRef` à `gate.RequireChangeRef || gate.ITSMCheck` (même condition,
même code `GATE_REFS_REQUIRED`, même « fail at the earliest » que la demande).
Le **pv_ref n'est PAS exigé au rollback**, et c'est une décision documentée : le PV
atteste la recette de l'état qu'on QUITTE ; l'état qu'on RESTAURE a déjà porté le
sien quand il a été promu. La motivation du rollback vit dans `reason`
(obligatoire, inchangé) et le change_ref quand le palier l'exige. À écrire dans
l'ADR et le gabarit `environments.yaml`.

**D4 — Pas de re-vérification ITSM au POST rollback.** Inchangé : la couche
dispatch-gate d'apply-uac relit l'ITSM au re-apply (A6), et le commentaire existant
du Jenkinsfile (un ITSM réel passerait le change N-1 à 'implemented' → un rollback
d'urgence porte SON change_ref) reste le durcissement documenté. G6 ne déplace pas
cette frontière.

**D5 — Le smoke est par palier, et il mesure l'ÉTAT restauré, pas un ping.**
Pour tout palier : `labctl get apis -f envs/<env>/targets.cluster.yaml` (catalogue
via le proxy admin du palier — la seule voie que Jenkins atteint) doit montrer
l'API du deploy restauré, et la version affichée doit être **celle du N-1**
(`restored.version` de la réponse du POST). Pour le terminus s'ajoute le smoke
data-plane existant (401 sans token). Le retour « au SHA N-1 » de la porte du GOAL
se prouve sur Git : `deploy.<env>.yaml` sur main == contenu au SHA N-1 verbatim
(pin compris) — c'est la partie « trace Git de l'acte », avec le commit de rollback
(trailers + evidence).

**D6 — La preuve est en trois couches, comme les jalons précédents.**
- **Offline (go)** : les trous de couverture du relevé §1.7 — refus
  `GATE_REFS_REQUIRED` au rollback (chaîne à `requireChangeRef`), refus aussi sur
  une chaîne à `itsmCheck` seul (le trou de symétrie D3, test qui rougit sur
  l'ancien code), rollback OK sans aucune ref sur un palier pv-only (chaîne 5
  paliers avec homol), restauration verbatim du pin sur homol.
- **Script live** (`scripts/test-rollback-paliers.sh`) : governance-api éphémère
  sur un repo scratch portant le gabarit 5 paliers (motif `demo-multienv.sh`),
  chaîne promue jusqu'à homol DEUX fois (deux versions → deux commits de
  `deploy.homol.yaml`), puis : rollback homol → 200, deploy.homol.yaml == N-1
  verbatim, marker `rolled_back`, evidence commitée, re-apply `--env homol` contre
  le wM réel via `wm-admin-homol`, catalogue à la version N-1. Contre-épreuves
  live : rollback prod sans change_ref ⇒ 400 `GATE_REFS_REQUIRED` ; double
  rollback ⇒ 409 ; état unique ⇒ 409 `NO_PREVIOUS_STATE`. Lab remis à l'identique.
- **Builds Jenkins** (la porte du GOAL au sens G5 : par les jobs réels) : le job
  rollback, `PROMOTION_ID` d'une promotion homol réelle du dépôt governance du
  lab, build vert = re-apply homol + smoke ; un build rouge attendu pour la
  contre-épreuve (change_ref vide sur une promo prod). Conditionné aux gestes
  exploitant (push gitea, `--grant-ci`) — si bloqué en session, la couche script
  reste la porte, et le handoff porte les gestes (précédent G2 : bout-en-bout
  Jenkins couvert hors-ligne, dit tel quel).

**D7 — Hors périmètre, dit noir sur blanc.** Le rollback de la chaîne
self-service (team-promote) n'est pas ce jalon : sur cette chaîne, revenir en
arrière = re-pinner le digest N-1 par une PR de promotion neuve (le marqueur ne se
recycle pas, dette G5) — c'est le parcours G7 qui le mettra en scène. La
conversion du verbe = G8 (§1.6). Le N-de-N de la décision client n°2 = code non
écrit, hors G6.

---

## §3 — Livrables

| Fichier | Geste |
|---|---|
| `labctl/cmd/governance-api/handlers_rollback.go` | D3 : condition change_ref alignée (`\|\| ITSMCheck`) |
| `labctl/cmd/governance-api/handlers_rollback_test.go` | D6 offline : 4 tests nouveaux (GATE_REFS_REQUIRED ×2, pv-only OK, homol verbatim+pin) |
| `ci/Jenkinsfile.rollback` | D1+D2+D5 : env capturé de la réponse, chaîne dérivée du clone, deux voies de re-apply, smoke par palier |
| `scripts/test-rollback-paliers.sh` | D6 script live, contre-épreuves comprises |
| `envs/homol/targets.cluster.yaml` (+ `targets.yaml`) | §1.8 : en-tête « plomberie non posée » périmé, corrigé |
| `adr/adr-085-rollback-des-paliers.md` | la décision, D1-D7, la qualification 17(1)(e) |
| `clients/_example/environments.yaml` | note D3 : ce que chaque gate exige AU ROLLBACK (change_ref oui, pv_ref non — pourquoi) |
| `ENVIRONNEMENTS.md` | § « Revenir en arrière (G6) » : parcours opérateur |
| `ci/README.md` | ligne Rollback du tableau : plus « re-apply prod » mais « re-apply du palier de la promotion » |
| `GOAL-cd-promotion-5-envs-2026-08-26.md` | G6 coché avec les chiffres |

## §4 — Correspondance aux portes du GOAL

- **Porte** « rollback exercé sur homol — retour au SHA N-1, smoke vert, trace Git » :
  script live (rollback homol réel contre le wM du lab, assertion verbatim sur Git,
  catalogue N-1) + build Jenkins vert quand les gestes exploitant sont passés.
- **Contre-épreuve** « sans référence de changement sur un palier qui l'exige ⇒
  refus » : offline (2 tests, dont celui qui rougit sur l'ancien code) + live
  (rollback prod sans change_ref, 400 nommé) + build rouge attendu côté Jenkins.
