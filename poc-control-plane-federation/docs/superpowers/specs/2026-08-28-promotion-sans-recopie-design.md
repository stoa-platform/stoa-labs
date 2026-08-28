# Promotion sans recopie — solder la dette du formulaire de promotion

**Date** : 2026-08-28 · **Suite de** : G3/G5/G7 (`GOAL-cd-promotion-5-envs-2026-08-26.md`, soldé)
**Ancrages** : ADR-081 (la décision est le merge), ADR-079/083 (verbe archive,
deux moteurs), ADR-082 (rétention par palier — env scellé). Pas de nouvel ADR :
on solde une dette À L'INTÉRIEUR de ces décisions, sans en changer aucune.

## La dette (mesurée, trois textes la nomment)

1. **Le job du formulaire de promotion n'existe pas.** `ci/Jenkinsfile.api-promote-request`
   est livré (G3) mais aucun `job.xml` ne le pose : absent de la liste `JOBS` de
   `setup-team-onboard-jobs.sh`, absent du Jenkins du lab. L'en-tête
   d'`api-promote-export.job.xml` l'acte : « job jamais câblé — dette
   silencieuse, pas un choix déclaré ». Sa seule preuve d'existence est
   `test-deploy-pin.sh` ⑲ (présence du Jenkinsfile, pas d'un job posé).
2. **`apis/<api>.promote.yml` s'écrit à la main.** `api-request` rend le
   `publish.yml` (« jamais édité à la main » y est la doctrine) — mais aucun
   formulaire ne rend le `promote.yml`. Le demandeur doit ouvrir une PR
   manuelle, en connaissant les pièges (champ vide ≠ absence, T10).
3. **guid et sha256 transitent par recopie humaine.** La description du job
   d'export l'assume : « guid/sha256 … **à recopier** dans apis/<api>.promote.yml
   et dans le formulaire api-promote-request ». C'est exactement le genre de
   couture manuelle que la chaîne interdit partout ailleurs.

Constat opérateur (rejeu du 2026-08-28, t7-e2e-api) : publier = 2 formulaires
et 1 merge ; promouvoir = 2 PRs manuelles + 2 recopies + 1 script lancé en
local. « Ça casse la dynamique. »

## Décisions (arbitrées avec le demandeur, 2026-08-28)

| # | Question | Décision | Écarté |
|---|---|---|---|
| D1 | Qui rend le `promote.yml` ? | **L'export rend tout** : `api-promote-export` rend le manifeste s'il est absent, exporte, puis ouvre UNE PR portant manifeste + guid + sha épinglés | Un 3ᵉ formulaire « déclarer l'API promouvable » (un merge de plus, dynamique encore lourde) ; le statu quo manuel |
| D2 | D'où vient `ARCHIVE_SHA256` au formulaire de promotion ? | **Épinglé dans le dépôt d'équipe** par la PR d'export (`apim_promote.archive_sha256`) ; le champ devient facultatif depuis dev — vide ⇒ lu sur main, renseigné ⇒ il gagne (désignation explicite) | Recopie manuelle conservée ; « dernier du registre » (désignation faible, un ré-export concurrent changerait les octets désignés) |
| D3 | Type de job ? | **Pipeline from SCM, inchangé** — la doctrine du dépôt et le format client (confirmé par le demandeur). Le `job.xml` n'est que le payload de création REST, sans logique | Freestyle (perdrait la relecture du pipeline dans Git) |

## Faits qui rendent D1/D2 sûrs (mesurés)

- **Le registre est adressé par le contenu** (`scripts/lib/archive-store.sh:4-5`) :
  la version du package Gitea EST le sha256 de l'archive sanitizée. Un sha
  commité désigne donc les octets sans ambiguïté — pas de « latest » à deviner.
- **Les deux moteurs tolèrent la clé nouvelle.** Ansible : clé supplémentaire
  dans le dict `apim_promote`, ignorée par les rôles. labctl : `promote.go`
  décode via `sigs.k8s.io/yaml.Unmarshal` puis `json.Unmarshal` **non stricts**
  (pas de `DisallowUnknownFields` sur ce chemin) — `archive_sha256` ne casse
  aucun parse. (Contre-exemple qui impose la prudence : un champ *connu mais
  vide* refuse côté labctl — piège T10, scope_mapping — d'où « omis, pas
  vides » partout dans le gabarit.)
- **`apis/<api>.publish.yml` sur main porte name/version courants d'authoring**
  (réécrit par chaque PR d'api-request) : le rendu du `promote.yml` en dérive
  ses champs sans nouveau champ de formulaire.

## Le parcours cible

```
formulaire api-request         → PR api/<name>-<ver>              → merge (4-yeux)
   pause team-publish (nominatif) → publié en dev                     [inchangé]
formulaire api-promote-export  → PR chore/promote-manifest-<name> → merge
   (rend le manifeste si absent, exporte, épingle guid + archive_sha256)
formulaire api-promote-request → PR promote/<name>-<env>          → merge (2nd humain)
   (ARCHIVE_SHA256 facultatif : lu sur main)
   pause team-promote (nominatif) → promu                            [inchangé]
```

Deux formulaires côté promotion, deux merges, zéro fichier édité à la main,
zéro recopie. Invariants intacts : la décision reste le merge (ADR-081), la
désignation des octets reste un contenu commité relu au dispatch, l'environnement
reste scellé côté export (ADR-082, `DEPLOY_PIN_AUTHORING_ENV`), la porte du
palier reste jouée au dispatch (G3 D1) et la garde d'identité à la pause.

## Design par composant

### 1. Gabarit `gateways/templates/promote.yml.tmpl` (nouveau)

Forme reprise de `clients/_example/apis/accounts-read.promote.yml`, réduite au
noyau que le rendu peut affirmer :

- `name`/`version` : dérivés d'`apis/<api>.publish.yml` lu sur main ;
- `guid: ""` et `archive_sha256: ""` : épinglés par l'export après
  `EXPORT_CONFIRMED` (jamais laissés vides dans la PR ouverte) ;
- `archive` : chemin `dist/` conventionnel (usage hors-CI, le CI épingle via
  `apim_ss_archive_pin`) ; `overwrite: "apis,policies,policyactions"` ;
  `smoke_path: ""` ;
- **PAS** de `backend_alias`/`cred_alias`/`scope_mapping`/`per_env` : omis, pas
  vides (piège T10). Un commentaire du gabarit dit que les ajouter À LA MAIN
  reste l'authoring légitime pour une API à backend aliasé — cette édition-là
  est du contenu métier, pas de la plomberie.

### 2. `scripts/api-promote-export.sh` — rendre et épingler

- Manifeste absent sur main ⇒ **rendu** depuis le gabarit. `publish.yml` absent
  aussi ⇒ refus nommé `PUBLISH_MANIFEST_ABSENT` (l'API n'est pas publiée en
  authoring, rien à exporter). Le manifeste rendu sert à l'export du run
  courant (pas d'aller-retour « merge d'abord, relance ensuite »).
- Après `EXPORT_CONFIRMED` ⇒ écrire `guid:` et `archive_sha256:` dans le
  manifeste (rendu ou existant), pousser la branche
  `chore/promote-manifest-<api>` et ouvrir la PR sur le dépôt d'équipe.
  Le préfixe `chore/` ne réveille AUCUN webhook-job (`api/*` ⇒ team-publish,
  `promote/*` ⇒ team-promote — vérifié dans les deux Jenkinsfile).
- **Idempotence** : main porte déjà guid+sha identiques ⇒ pas de PR, dire
  pourquoi (`PIN_DEJA_A_JOUR`). Branche/PR déjà ouverte ⇒ la branche est
  re-poussée (force) et la PR existante mise à jour — jamais d'empilement
  (ferme au passage le piège G5 « ré-export ⇒ PR neuve »).
- Sortie `EXPORT_CONFIRMED_SUMMARY` enrichie : URL de la PR + « mergez, puis
  formulaire api-promote-request (ARCHIVE_SHA256 facultatif) ».

### 3. `scripts/api-promote-request.sh` — le sha sans recopie

- Depuis dev : `ARCHIVE_SHA256` vide ⇒ lu depuis `apim_promote.archive_sha256`
  du manifeste sur main (le clone du dépôt d'équipe existe déjà dans le
  script) ; ni formulaire ni manifeste ⇒ `DIGEST_ABSENT` inchangé
  (fail-closed conservé). La validation de forme (64 hex minuscules)
  s'applique à la valeur retenue, quelle qu'en soit la source.
- Renseigné ⇒ il gagne (désignation explicite, D2). S'il contredit le
  manifeste : avertissement bruyant (sortie + corps de PR), pas de refus — le
  marqueur mergé porte le sha, et c'est le merge qui l'approuve. Cas légitime :
  re-promouvoir une archive antérieure au dernier export.
- Hors dev : rien ne change — digest hérité du palier source, incontestable
  (`DIGEST_CONTREDIT_SOURCE`).

### 4. Poser le job, corriger les textes qui mentent

- `ci/jenkins/api-promote-request.job.xml` (nouveau) : calqué sur
  `api-promote-export.job.xml` — pipeline from SCM, ZÉRO Groovy inline, bloc
  `<parameterDefinitions>` **miroir exact** du `parameters{}` du Jenkinsfile
  (piège DeclarativeJobPropertyTrackerAction : le XML gagne, une divergence
  serait silencieuse), pas de marqueur CHOICES. Description d'`ARCHIVE_SHA256`
  réécrite : facultatif depuis dev, lu sur main sinon.
- `ci/Jenkinsfile.api-promote-request` : la description du paramètre
  `ARCHIVE_SHA256` suit (miroir), le reste est déjà bon.
- `scripts/setup-team-onboard-jobs.sh` : `api-promote-request` rejoint la
  liste `JOBS` ; l'en-tête qui documentait la dette est réécrit (soldée, daté).
- `ci/jenkins/api-promote-export.job.xml` : description sans « à recopier » ;
  l'avertissement d'en-tête sur le « frère jamais câblé » est mis à jour.
- Doc du parcours opérateur : le cycle promotion passe de « éditer
  promote.yml, recopier guid/sha » à « deux formulaires, deux merges ».

### 5. Épreuves (la porte de ce chantier)

Suite hors-ligne `scripts/test-promote-sans-recopie.sh` (motif des
wiring-tests), **chemin nominal inclus** (leçon app-request v3 : une suite
faite uniquement de refus ne teste jamais le chemin qui sert) :

1. rendu du gabarit : name/version repris de publish.yml, clés interdites
   absentes (pas de backend_alias/scope_mapping/per_env vides) ;
2. `PUBLISH_MANIFEST_ABSENT` si l'API n'est pas publiée ;
3. épinglage : guid+sha écrits, manifeste relu par les DEUX moteurs —
   `python3 -c yaml.safe_load` (chemin ansible) ET un chargement labctl du
   manifeste épinglé (le parse non strict est mesuré, l'épreuve le fige :
   elle échoue si labctl refuse la clé) ;
4. idempotence : second export même contenu ⇒ `PIN_DEJA_A_JOUR`, pas de PR ;
5. request : vide⇒manifeste (nominal), explicite⇒gagne (avertissement émis),
   rien⇒`DIGEST_ABSENT`, forme invalide⇒`DIGEST_MALFORMED` ;
6. miroir job.xml ↔ Jenkinsfile (params, ordre, types) — même comparaison que
   `test-team-publish-wiring.sh` §3 ;
7. `make lint-ci` vert (le 12ᵉ Jenkinsfile entre dans la compilation).

E2E sur le lab (builds réels, pas de simulation) : rejeu
`t7-e2e-api@1.0.1` dev→rec entièrement par formulaires — export (PR
manifeste+pins, merge), request (champ sha laissé vide, PR promote, merge par
le 2nd humain), pause team-promote nominatif, apply vert, commentaires sur les
deux PRs. Contre-épreuve : formulaire request AVANT le merge de la PR
manifeste ⇒ `DIGEST_ABSENT`.

## Fichiers touchés

| Fichier | Geste |
|---|---|
| `gateways/templates/promote.yml.tmpl` | nouveau — gabarit rendu par l'export |
| `scripts/api-promote-export.sh` | rendu si absent + épinglage guid/sha + PR idempotente |
| `scripts/api-promote-request.sh` | `ARCHIVE_SHA256` facultatif depuis dev (manifeste sur main) |
| `ci/jenkins/api-promote-request.job.xml` | nouveau — pose du job (pipeline from SCM) |
| `ci/Jenkinsfile.api-promote-request` | description du paramètre (miroir) |
| `ci/jenkins/api-promote-export.job.xml` | description + en-tête (dette soldée) |
| `scripts/setup-team-onboard-jobs.sh` | JOBS += api-promote-request ; en-tête |
| `scripts/test-promote-sans-recopie.sh` | nouveau — la suite d'épreuves |
| doc parcours opérateur | cycle promotion mis à jour |

## Hors périmètre

- Rendre `per_env`/backends par formulaire (authoring métier, reste en Git).
- La chaîne governance (`labctl dispatch-gate`) et les portes ITSM : intactes.
- Le trou n°3 de G7 (corps de PR menteur) : déjà traité par G7 — vérifier au
  plan, ne pas refaire.
- Toute conversion freestyle (D3) : geste d'adaptation client trivial si un
  jour requis, la logique vivant dans `scripts/`.
