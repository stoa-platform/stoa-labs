---
title: "ADR-085 — Le repli, comme composant du déploiement. Le rollback d'une promotion n'est ni prod-only ni un DELETE : c'est un re-apply Git sur le PALIER DE LA PROMOTION (jamais saisi), qui restaure l'état désiré N-1 verbatim — pin compris — par le même verbe et le même preflight déployeur que l'aller."
sidebar_label: "ADR-085 : le rollback des paliers (G6)"
status: "Acté et prouvé hors-ligne + par script live. Offline : 3 tests nouveaux sur `handlers_rollback_test.go` (dont un qui rougit sur le code d'avant G6 — le trou de symétrie change_ref/itsmCheck) + 6 tests préexistants de fidélité `labctl Publish` réparés (T3a, défaut découvert : PUT inconditionnel sur une API ACTIVE, que le produit refuse — ADR-079). Live : `scripts/test-rollback-paliers.sh` 22/0 ×2 + rejeu contrôleur (22/0) — chaîne 5 paliers sur un repo scratch, rollback homol réel contre le wM du lab via `wm-admin-homol`, deploy.homol.yaml == N-1 verbatim au retour, re-apply idempotent, smoke catalogue à la version N-1, contre-épreuves prod (400 sans change_ref, 409 double rollback, 409 sans état antérieur). Builds Jenkins : en vol au moment de cet ADR — non référencés ici tant que non joués."
maturite_technique: "✅ Mécanisme prouvé hors-ligne (les deux gardes du trou de symétrie testées par mutation) et par script live sur homol (le seul palier intermédiaire porté par la porte du GOAL). Résiduel nommé : la fidélité du mock wM sur PUT-refusé-si-actif n'est pas re-mesurée contre le wM réel dans CE jalon (héritée d'ADR-078/079) ; les builds Jenkins de la porte n'étaient pas encore joués à l'écriture."
date: 2026-08-27
adr_number: 85
note: "Consomme ADR-075 (l'invariant « aucun DELETE » de l'allowlist proxy — le rollback en est la preuve par l'usage : jamais une suppression, toujours un revert + re-apply) et ADR-084 (le re-apply d'un rollback est un apply comme un autre : il passe par le MÊME preflight déployeur, aux mêmes deux sites de dispatch). Précise ADR-079 (le verbe reste apply-uac, pas l'import d'archive — la conversion du pipeline governance reste la tension parquée nommément dans ADR-083, ouverte pour G8)."
lié: "[[adr-084-axe-qui-deploie-deployer-group]], [[adr-083-verbe-archive-deux-moteurs]], [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-075-wm-admin-proxy-multienv]]"
---

# ADR-085 — Le repli, comme composant du déploiement

**Statut :** Acté, prouvé hors-ligne et par script live. **Maturité :** ✅ voir l'en-tête.

**Lié à :** [[adr-084-axe-qui-deploie-deployer-group]], [[adr-083-verbe-archive-deux-moteurs]], [[adr-079-deploiement-promotion-multienv-import-archive]], [[adr-075-wm-admin-proxy-multienv]].

---

## Contexte

`ci/Jenkinsfile.rollback` existait déjà, mais par TROIS ancrages prod-only :
`apply-uac --env prod` en dur, le smoke data-plane prod (401 sans token), et le
chemin de credential (ci-applier + Vault admin DIRECT — le régime du terminus).
Le moteur qu'il pilote, lui, n'a jamais connu de nom de palier : `handlers_rollback.go`
revert `deploy.{promo.To}.yaml` au contenu N-1 **verbatim** (pin `commit` compris),
marque la promotion `rolled_back`, commite sur main avec trailers + evidence, et
répond `restored: {environment, version, commit}` — quel que soit le palier. Ce
qui manquait était la couche Jenkins au-dessus, et une garde de symétrie côté
handler.

**La qualification à ne pas dépasser.** L'art. 17(1)(e) du règlement délégué
(UE) 2024/1774 (RTS DORA) rend obligatoire *« the identification of fall-back
procedures and responsibilities, including procedures and responsibilities for
aborting changes or recovering from changes not successfully implemented »* —
**identifier**, pas tester. Le repli est un composant du déploiement : c'est
l'argument qui justifie de le documenter et de l'outiller. Mais l'obligation de
le **tester** ne vient pas de (e) — elle s'adosse à (c) *controlled testing*, ou
au niveau 1 de DORA. On ne prétend jamais que « on l'a exercé sur homol » est
une exigence de (e) : c'est une exigence de rigueur d'ingénierie, que (c)
recouvre par ailleurs. Ce jalon **identifie** (l'ADR, le gabarit, le parcours
opérateur) **et** teste (offline + live) — les deux se disent, sans confondre
leurs fondements réglementaires respectifs.

## Décision

**D1 — Le palier du rollback n'est JAMAIS saisi par l'opérateur : il est celui
de la promotion.** Le job `ci/Jenkinsfile.rollback` ne gagne aucun paramètre
`TARGET_ENV`. La réponse du POST rollback porte `restored.environment` ; le
Jenkinsfile la capture dans un fichier de workspace et la propage à tous les
stages aval. Toute saisie d'environnement recréerait une classe d'erreurs
(rollback de la promotion X « au nom » du palier Y) que la source de vérité
rend impossible par construction. Fail-closed : `restored.environment` ou
`promotion.slug` absents de la réponse ⇒ le build échoue avant tout apply
(`sys.exit` explicite côté script Python embarqué).

**D2 — Terminus par POSITION, pas par nom.** Le re-apply choisit sa voie en
comparant le palier restauré au DERNIER élément de la chaîne dérivée du clone
`governance/environments.yaml` **post-revert** — le même motif structurel que
`e[:-1]` de `ci/Jenkinsfile` et que `env_chain_nonprod`. Terminus → voie
inchangée (ci-applier + secrets Vault, admin direct,
`envs/<terminus>/targets.cluster.yaml`). Palier intermédiaire (rec, int,
homol) → la voie du pipeline aller hors-prod : Bearer `ci-horsprod` scope
`deploy:<env>` via le proxy `wm-admin-<env>`. Un palier hors chaîne ⇒
`ROLLBACK_ENV_INCONNU` ; le palier d'authoring (premier de la chaîne) ⇒
`ROLLBACK_ENV_INELIGIBLE` — défense en profondeur, puisque structurellement
aucune promotion n'a `To == chain[0]` (`NextOf` ne rend jamais le premier
élément).

**D3 — Alignement des gardes de référence au rollback sur celles de la
demande, pour le change_ref seulement.** `handlers_rollback.go` exige
`change_ref` dès que `gate.RequireChangeRef || gate.ITSMCheck` — même
condition, même code `GATE_REFS_REQUIRED`, même refus « au plus tôt » (avant
toute lecture d'historique Git) que la demande. Avant G6, seul
`RequireChangeRef` était testé au rollback : sur la chaîne du gabarit (prod
porte les deux) l'écart était invisible ; sur une chaîne où un palier ne
porterait que `itsmCheck`, un rollback y passait sans change_ref alors que la
demande l'exigeait — un trou de symétrie, fermé.

Le **`pv_ref` n'est PAS exigé au rollback**, et ce n'est pas un oubli : le PV
de validation atteste la recette de l'état qu'on **QUITTE** ; l'état qu'on
**RESTAURE** a déjà porté le sien au moment où il a été promu — l'exiger de
nouveau serait re-demander la preuve d'une chose déjà prouvée. La motivation
du rollback vit dans `reason` (obligatoire, inchangé) et dans `change_ref`
quand le palier l'exige. C'est pour ça qu'un rollback homol (pv-only,
`requirePVRef: true` et rien d'autre) passe avec la seule `reason` — prouvé
(`TestRollbackHomolPVOnlyRestoresVerbatimPin`, et en live sur le lab).

**D4 — Pas de re-vérification ITSM au POST rollback.** Inchangé : la couche
dispatch-gate d'apply-uac relit l'ITSM au re-apply (A6, mécanisme déjà en
place pour l'aller). Le commentaire du Jenkinsfile documente le durcissement
qui en découle : un ITSM réel passerait le change de l'état N-1 à
`implemented` après sa mise en production initiale — un rollback d'urgence
doit donc porter **son propre** `change_ref` (le paramètre `CHANGE_REF` du
job), pas celui, périmé, du N-1. G6 ne déplace pas cette frontière ; il la
documente pour qu'elle ne surprenne pas au premier rollback réel.

**D5 — Le smoke est par palier, et il mesure l'ÉTAT restauré, pas un ping.**
Pour tout palier : `labctl get apis -f envs/<env>/targets.cluster.yaml` (via
le proxy admin du palier — la seule voie que Jenkins atteint) doit montrer
l'API du deploy restauré, à la version **N-1** (`restored.version` de la
réponse du POST) — la version est exigée dans l'assertion quand
`restored.version` est renseignée (toujours le cas pour un deploy bien
formé), la couche Git-verbatim portant le reste. Pour le terminus s'ajoute le
smoke data-plane existant (401 sans token). Le retour « au SHA N-1 » se
prouve sur Git :
`deploy.<env>.yaml` sur main == contenu au SHA N-1 verbatim, pin compris —
c'est la trace Git de l'acte, portée par le commit de rollback (trailers +
evidence pack).

**D6 — La preuve est en trois couches, comme les jalons précédents.**
- **Offline (go)** : les refus `GATE_REFS_REQUIRED` au rollback (chaîne à
  `requireChangeRef`, et — c'est le trou de symétrie D3 — chaîne à
  `itsmCheck` seul, test qui rougit sur le code d'avant G6), le rollback OK
  sans aucune référence sur un palier pv-only (chaîne 5 paliers avec homol),
  et la restauration verbatim du pin sur ce même palier. 3 tests nouveaux sur
  `handlers_rollback_test.go`.
- **Script live** (`scripts/test-rollback-paliers.sh`) : governance-api
  éphémère sur un repo scratch portant le gabarit 5 paliers, chaîne promue
  jusqu'à homol deux fois (deux commits de `deploy.homol.yaml`), puis :
  rollback homol → 200, `deploy.homol.yaml` == N-1 verbatim, marqueur
  `rolled_back`, evidence commitée, re-apply `--env homol` contre le wM réel
  du lab via `wm-admin-homol`, catalogue à la version N-1. Contre-épreuves
  live : rollback prod sans change_ref ⇒ 400 `GATE_REFS_REQUIRED` ; double
  rollback ⇒ 409 `NOT_APPROVED` ; état unique ⇒ 409 `NO_PREVIOUS_STATE`. 22/0
  ×2 + rejeu contrôleur (22/0). Lab remis à l'identique.
- **Builds Jenkins** (la porte du GOAL au sens G5 : par les jobs réels) : le
  job rollback, `PROMOTION_ID` d'une promotion homol réelle du dépôt
  governance du lab, build vert attendu = re-apply homol + smoke ; un build
  rouge attendu pour la contre-épreuve (change_ref vide sur une promo prod).
  En vol à l'écriture de cet ADR — si non joués en session, la couche script
  reste la porte, et le handoff porte les gestes restants (précédent G2 :
  bout-en-bout Jenkins couvert hors-ligne, dit tel quel).

**D7 — Hors périmètre, dit noir sur blanc.** Le rollback de la chaîne
self-service (team-promote) n'est pas ce jalon : sur cette chaîne, revenir en
arrière signifie re-pinner le digest N-1 par une PR de promotion **neuve** (le
marqueur `rolled_back` ne se recycle pas — dette laissée par G5) ; c'est le
parcours G7 qui le mettra en scène. La conversion du verbe de la chaîne de
gouvernance (§ ci-dessous) est G8. Le N-de-N de la décision client n°2 (portes
au-delà d'une chaîne linéaire) reste du code non écrit, hors G6.

## Le rollback restaure, il ne supprime pas

Le rollback restaure l'état désiré ; il ne supprime pas la version N de la
gateway. **Aucun DELETE** — l'invariant d'ADR-075 (l'allowlist des proxies
`wm-admin-<env>` ne porte aucun verbe DELETE ; le rollback est un revert Git +
re-apply, jamais une suppression). Le smoke d'un palier intermédiaire tolère
la présence résiduelle de l'ancienne version N au catalogue : l'assertion est
la **présence** de la version N-1 restaurée, pas l'**absence** de N — c'est
une conséquence directe de l'invariant, pas une faiblesse du smoke.

## Le re-apply du rollback n'est pas un apply à part

Le re-apply d'un rollback est un apply comme un autre : il passe par **le
même preflight déployeur** que l'aller (G2, ADR-084), aux mêmes deux sites de
dispatch. Conséquence mesurable et assumée, symétrique à celle d'ADR-084 pour
`Jenkinsfile.prod` : le re-apply machine vers un palier intermédiaire
(int/homol) exige `setup-vault-paliers.sh --grant-ci` (la déclaration « le CI
est porteur hors-prod », geste G2), et le repli AppRole du rollback prod est
refusé `DEPLOYER_GROUP_REQUIRED` si l'AppRole ne porte pas `operator-deploy` —
un rollback prod n'est pas un chemin de contournement de l'axe qui déploie. Le
job `Jenkinsfile.rollback` porte les deux voies de login (nominatif si
`VAULT_USER` est renseigné, repli AppRole sinon) exactement comme
`Jenkinsfile.prod` : aucune exception de gate n'est introduite pour le
rollback.

## Le verbe reste apply-uac

Le rollback re-applique l'état désiré N-1 par le **même verbe** que le
pipeline aller de sa chaîne — `apply-uac`, pas l'import d'archive à GUID
stable d'ADR-079/ADR-083. La conversion du pipeline de gouvernance au verbe
archive est une tension **parquée nommément** dans ADR-083 (« sa conversion se
conçoit avec la parité G8, pas en silence ») : G6 n'y touche pas. La limite
« zéro-coupure sur une API active » de ce verbe (`apply-uac` ne converge pas
la définition d'une API active — la dérive appartient au verbe archive, G8)
est celle du pipeline aller — elle appartient à G8, pas à ce jalon.

## Le défaut découvert en cours de route (T3a) : idempotence de `Publish`

En faisant du mock une réplique fidèle du refus produit (« un PUT sur une API
**active** est refusé », ADR-079/UPDATE_FORBIDDEN), la suite a démasqué un
défaut réel dans `labctl` : `webMethods.Publish` faisait un PUT
**inconditionnel** de la définition sur `/apis/{id}`, y compris quand l'API
trouvée était déjà active — un re-apply répété (exactement ce que fait un
rollback re-appliqué, ou tout simplement un `apply-uac` rejoué) échouait donc
là où l'idempotence était supposée. Correctif : le PUT de définition est
**sauté** quand l'API trouvée est active (chemin nominal et fallback 409
compris) ; l'activation, l'auth entrante et le routage continuent de
converger normalement. La dérive de définition sur une API active reste,
volontairement, le travail du verbe archive — G8.

Rendre le mock fidèle a fait rougir **6 tests préexistants** qui n'étaient
verts que par une infidélité du harnais (le mock acceptait un PUT que le
produit refuse) — ils ont été réparés pour refléter le comportement réel, pas
contournés.

**Résiduel à assumer.** La stricte du mock (refuser un PUT sur une API
active) est traitée comme fidèle au comportement de wM 10.15 — c'est un
correctif de fidélité déjà établi par ADR-078/ADR-079 (le garde-fou
`UPDATE_FORBIDDEN`) — mais elle n'est **pas re-mesurée contre la gateway
réelle dans ce jalon** ; le script live de G6 exerce le re-apply idempotent
(la voie corrigée), pas une nouvelle mesure de fidélité du mock lui-même.

## Conséquences

- **Un rollback n'est plus prod-only.** Les trois ancrages historiques
  (`--env prod` en dur, smoke prod, credential admin direct) sont remplacés
  par une dérivation par POSITION à partir de la réponse gouvernance et du
  clone `environments.yaml` — un rollback sur rec, int ou homol emprunte
  désormais la même charpente que le rollback prod, sans code dupliqué par
  palier.
- **Un rollback machine hors-prod exige le même geste exploitant que l'apply
  machine hors-prod** (`--grant-ci`) — pas de raccourci parce que c'est un
  rollback.
- **Le re-apply d'un rollback prod sans porteur imputable est refusé comme
  n'importe quel apply prod** — `DEPLOYER_GROUP_REQUIRED` couvre le rollback
  au même titre que l'aller, sans exception codée.
- **Le smoke d'un rollback intermédiaire lit le catalogue via le proxy admin
  du palier** — la seule voie que Jenkins atteint hors-prod (contre-épreuve
  topologique héritée d'ADR-075) ; il n'y a pas de smoke data-plane hors du
  terminus, exactement comme pour l'aller.

## Limites nommées (rien d'autre ne le dira)

- **Les builds Jenkins de la porte du GOAL n'étaient pas joués à l'écriture de
  cet ADR** — la preuve de ce jalon repose sur les couches offline et script
  live ; le handoff porte les gestes restants s'ils n'ont pas été joués en
  session (push gitea, promotion homol réelle sur le dépôt du lab).
- **La fidélité du mock sur le refus PUT-sur-actif n'est pas re-mesurée
  contre le wM réel dans ce jalon** — elle est héritée d'ADR-078/ADR-079, pas
  reprouvée ici.
- **Le rollback de la chaîne self-service reste hors périmètre** (D7) — le
  marqueur `rolled_back` n'y est pas recyclable, dette explicite pour G7.
- **La conversion du verbe de la chaîne de gouvernance reste parquée** —
  aucune limite de zéro-coupure de `apply-uac` sur une API active n'est levée
  par ce jalon ; c'est G8.
