# G5 — Le verbe : import d'archive à GUID stables, porté par les deux moteurs

**Date** : 2026-08-27. **GOAL** : `GOAL-cd-promotion-5-envs-2026-08-26.md`, jalon G5.
**Amont** : G1 (chaîne 5 paliers), G3 (marqueurs `deploy.<env>.yaml`, résolveur de pin,
formulaire de promotion), G4 (rétention de credential par palier, ADR-082).
**Mode** : session autonome — les décisions ci-dessous sont des arbitrages du contrôleur,
consignés comme tels (précédent G3/G4), pas des consensus.

**Porte du GOAL** : promotion `dev → rec` d'une API **active** : GUID identique des deux
côtés, **zéro 5xx en vol sous charge** — **par chacun des deux moteurs**.
**Contre-épreuves du GOAL** : la garde `UPDATE_FORBIDDEN` d'`apim_publish_api` refuse un
`deactivate` hors env d'authoring ; une porte refusée ⇒ **le play n'est jamais lancé**.
**Note d'honnêteté du GOAL** : aucun appui éditeur externe n'a survécu — ce jalon s'appuie
sur ADR-079 et nos mesures, rien d'autre.

---

## §1 — Ce que le relevé a mesuré (2026-08-27)

**Ce qui existe et n'attend que le câblage :**

| Pièce | Où | État |
|---|---|---|
| Moteur client (export sanitizé / import 0-coupure) | `ansible/roles/apim_promote_api` | Livré, prouvé E2E (ADR-079) ; **appelé par rien** |
| Moteur lab | `labctl/cmd/labctl/promote.go` | Écrit ; 2 tests sur le chargement du manifeste ; **jamais exécuté contre une gateway** |
| Manifeste commun | `clients/_example/apis/accounts-read.promote.yml` | Un seul exemplaire, format Jinja pour `archive:` |
| Marqueur + résolveur | `scripts/lib/deploy-pin.sh` (`resolve_deploy_pin` 6e arg = archive, digest vérifié) | Livré G3, **le chemin hors-dev n'a jamais tourné** |
| Formulaire de promotion | `scripts/api-promote-request.sh` + `ci/Jenkinsfile.api-promote-request` | Livré G3 — ouvre la PR `promote/<api>-<env>`, **le merge ne déclenche rien** (`team-publish.sh:142` sort sur « hors api/* ») |
| Credential par palier | `scripts/setup-vault-paliers.sh` (policies+AppRoles `apply-<env>`, jamais mintés) | Livré G4 — **aucun consommateur** |
| Preuve du verbe produit | `scripts/test-archive-promotion.sh` | X/X sur wM réel (`localhost:5555`) |
| Garde 0-coupure côté publication | `apim_publish_api` (UPDATE_FORBIDDEN) | Livrée (ADR-079) |

**Les quatre trous que G5 ferme :**

1. **Le merge d'une PR de promotion est un vert vacant.** `ci/Jenkinsfile.team-publish`
   filtre `api/*` ; une branche `promote/*` fait un build vert qui ne fait rien —
   documenté noir sur blanc dans `ci/Jenkinsfile.api-promote-request:4-11`.
2. **Le transport des octets n'existe pas.** Aucun dépôt d'artefacts ; le digest du
   marqueur pinne des octets que personne ne sait retrouver. (G3 : « le transport des
   octets d'un palier à l'autre n'existe pas — G5 ».)
3. **Le verbe n'a aucune cible exerçable en pipeline.** Les gateways de palier du lab
   sont les mocks `wm-mock-<env>` (réseau interne, atteints par les seuls proxies
   `wm-admin-<env>` du wM réel, ADR-075) — et le mock **ne connaît pas `/archive`**
   (`mocks/webmethods/server.go:59-98` : aucune route archive). L'allowlist des proxies
   non plus (`gateways/webmethods/admin-proxy/wm-admin-proxy.openapi.yaml`).
4. **`labctl promote` est mort** — aucun pipeline, aucun script, jamais un run réel.

**Deux faits d'environnement qui gouvernent la conception :**

- Le proxy `wm-admin-<env>` porte **lui-même** le Basic sortant (credential alias posé
  depuis `secret/stoa/envs/<env>/wm-admin`) et exige **OAuth2 scope `deploy:<env>`**
  en entrée (`scripts/setup-wm-admin-proxy.sh:14-19`).
- Gitea du lab = **1.22.6** (mesuré) : le registre de packages **génériques** existe
  (`PUT/GET /api/packages/{owner}/generic/{name}/{version}/{file}`), refuse le
  doublon — exactement la forme « artefact de build tagué, PAS Git » d'ADR-079 C3.

---

## §2 — Décisions

**D1 — Le consommateur du merge est un job dédié `team-promote`, déclenché par le MÊME
webhook que `team-publish`.** Le plugin Generic Webhook Trigger déclenche **tous** les
jobs portant le token présenté : `Jenkinsfile.team-promote` reprend
`token: 'stoa-team-publish'` et filtre `promote/*` là où team-publish filtre `api/*`.
Zéro geste sur les dépôts d'équipe existants (pas de second webhook à poser ni à
rattraper). *Repli nommé si la mesure live contredit le multi-job-par-token : un second
webhook posé par `team-apply.sh` (le motif idempotent existe, `team-apply.sh:252-300`).*

**D2 — Le transport est le registre de packages génériques Gitea, adressé par le
contenu.** `owner` = l'organisation du dépôt plateforme (`ci`), package
`promote--<team>--<api>`, **version = le sha256 complet de l'archive sanitizée**,
fichier `<api>-<version-api>.zip`. Le marqueur G3 porte déjà `archive_sha256` : l'URL de
téléchargement se **dérive** du marqueur, aucun champ nouveau. Poussée idempotente
(digest déjà présent ⇒ OK sans PUT) ; téléchargement re-haché et confronté au digest
attendu (fail-closed). Bibliothèque `scripts/lib/archive-store.sh`
(`archive_store_push` / `archive_store_fetch`), token via header-file, jamais en argv.

**D3 — L'export est un job de formulaire (`api-promote-export`).** Entrées `TEAM`,
`API_NAME` ; le script clone le dépôt d'équipe (main), lit `apis/<api>.promote.yml`,
joue le moteur en `action=export` contre la **gateway d'authoring**, pousse l'archive au
registre et imprime `EXPORT_CONFIRMED` (guid, sha256, package). Le **pinning du guid**
dans `promote.yml` reste un geste Git de l'équipe (PR) — documenté, pas automatisé
(parking §8). Sans guid pinné, l'import refuse (`IMPORT_REFUSED`, garde existante) :
fail-closed, pas un trou.

**D4 — `team-promote.sh` reprend la discipline de `team-publish.sh`, et toutes les
portes sont mécaniquement antérieures au moteur.** Ordre imposé : validation de forme
des variables webhook → réconciliation Gitea (PR réellement mergée, même SHA/branche) →
filtre `promote/*` + extraction `<api>`/`<env>` (l'env est le dernier segment, validé
contre la chaîne) → ancrage `merge-base --is-ancestor` → récupération de l'archive au
registre **par le digest du marqueur** → `resolve_deploy_pin` (marqueur au SHA mergé,
pin, ancêtreté, version, digest — G3, premier branchement réel hors-dev) → exigences de
la porte d'arrivée relues **sur le marqueur mergé** (`env_chain_gate` : change_ref/pv_ref
présents) → garde d'identité (`assert-merge-identity.sh` ; le 4-yeux devient
**conditionnel à la porte** : nouveau drapeau `--allow-self-approval`, posé uniquement si
la porte d'arrivée ne porte pas `fourEyes` — décision client n°1 reste un réglage
d'`environments.yaml`) → login Vault nominatif → **lecture du secret de palier**
`envs/<env>/wm-admin` (LA porte de rétention G4 : palier non ouvert ⇒ 403 ⇒ refus nommé
`PALIER_FERME`, moteur jamais lancé) → **un seul site d'appel moteur**, après tout.

**D5 — L'accès admin au palier suit le motif `ADMIN_VIA` de `Jenkinsfile.publish-api`.**
`direct` (client : l'API d'admin du palier, Basic depuis le secret de palier) |
`proxy-oauth2` (lab : `wm-admin-<env>` sur le wM réel, Bearer client_credentials).
Câblage lab : `apim_ss_auth_mode=oauth2`, `apim_ss_vault_oauth_sub=envs/<env>/admin-oauth`
— un sub **par palier**, seedé par extension de `setup-vault-envs.sh`, lu par une
extension de la policy `apply-<env>` (`setup-vault-paliers.sh` : + read
`envs/<env>/admin-oauth`). Le client OAuth du sub est `ci-horsprod` (acquis ADR-075,
scopes hors-prod) — **limite nommée** : la valeur partagée entre paliers affaiblit la
rétention au plan réseau ; le client par palier est un parking (§8), la rétention
mécanique de G5 reste la lecture Vault par palier + le scope du proxy.

**D6 — Les deux moteurs, un site d'appel, un knob hors du périmètre du demandeur.**
`PROMOTE_ENGINE` ∈ {`ansible` (défaut, chemin client), `labctl`} vit dans
l'`environment{}` du Jenkinsfile (définition de pipeline protégée, G4 D7) — jamais un
paramètre de build. Chemin `ansible` : `ansible-playbook ansible/promote-api.yml` (play
nouveau, calqué sur `publish-api.yml`) avec `-e apim_promote_manifest=$DEPLOY_PIN_PROMOTE
-e apim_ss_env=$TO_ENV -e apim_ss_archive_sha256=$DEPLOY_PIN_SHA256` et **l'env
d'authoring scellé** `-e apim_ss_authoring_env=$DEPLOY_PIN_AUTHORING_ENV` (l'arbitrage
G3/G4 : dès qu'un tiers déclenche, le default surchargeable ne suffit plus — c'est CE
câblage qui le scelle). Chemin `labctl` : `labctl promote --manifest --env --action
import` sur un `targets.yaml` généré pointant le proxy (`bearerTokenFile`), même
manifeste, mêmes extra-contrôles en amont. L'iso-sémantique fine (état résultant) reste
**G8** — ici les deux moteurs sont **branchés et vivants**, pas encore confrontés.

**D7 — Le mock apprend `/archive`, et la preuve de fidélité est le harnais ADR-079
lui-même.** `mocks/webmethods` gagne `GET /rest/apigateway/archive?apis=<id>` (zip :
`APIGatewayAssets.acdl` + `API/API.<id>/API.<id>` + policies/actions + **Alias embarqué
quand l'API route `${alias}`** — le piège est un fait à reproduire) et
`POST /rest/apigateway/archive?overwrite=<types>` multipart (sans overwrite : conflit ⇒
`Failed`/`Asset already exists`, jamais de doublon ; types pluriels minuscules ; Alias
non couvert **skippé** `overwritten:false`, couvert **clobbé** — fidèle ; `isActive`
de l'archive **appliqué**, y compris la désactivation — le piège ; GUID de l'archive
préservé ; `ArchiveResult` = lignes `{<Type>:{…,status,overwritten}}`). **Porte de
fidélité : `scripts/test-archive-promotion.sh` passe INCHANGÉ contre le mock** (même
X/X que contre le wM réel) — toute sémantique que le harnais épingle est due, rien de
plus. Tests Go pour ce que le harnais n'atteint pas hors réseau.

**D8 — L'allowlist des proxies admin gagne `/rest/apigateway/archive` (GET+POST).**
Toujours **aucun DELETE**. Le contrat est partagé par les paliers
(`wm-admin-proxy.openapi.yaml`) : un ajout, tous les proxies re-posés
(`setup-wm-admin-proxy.sh`, dérivé de la chaîne — geste de re-pose à l'exploitation).

**D9 — `dev` garde le `POST`.** Rien ne change sur `team-publish` (authoring). Le
pipeline governance hors-prod (`ci/Jenkinsfile`, apply-uac dev→rec→int sur les contrats
UAC) **n'est pas converti** dans ce jalon : son objet est le contrat de gouvernance, pas
l'API d'équipe qui voyage par archive ; sa conversion exigerait d'archiver la projection
UAC entière et se traite avec G8 (parking §8, avec la tension GOAL nommée).

---

## §3 — Flux cible (chemin client, moteur ansible)

```
dev (authoring)      : team-publish (POST, inchangé)
export               : job api-promote-export → rôle export (sanitize+digest)
                       → registre Gitea (content-addressed) → EXPORT_CONFIRMED
                       → l'équipe pinne guid dans promote.yml (PR)
demande dev→rec      : job api-promote-request (G3, inchangé) → PR promote/<api>-rec
décision             : merge de la PR (ADR-081) — protections G4
apply                : webhook → team-promote (pause nominative, 4-yeux selon porte)
                       → gardes §2-D4 (TOUTES avant moteur)
                       → fetch archive par digest → resolve_deploy_pin
                       → lecture palier envs/rec/wm-admin (rétention G4)
                       → moteur (ansible|labctl) : alias-first → import overwrite
                         0-coupure → read-back GUID iso + ACTIVE → scope-mapping
                       → commentaire PR (succès comme échec, marqueur idempotent)
rec→int, int→homol…  : même mécanique ; pin et digest HÉRITÉS du palier source (G3)
```

## §4 — Preuve et contre-épreuves

### Portes hors-ligne (branchées `make lint-ci`)

1. **`scripts/test-team-promote-wiring.sh`** *(nouvelle)* — sur dépôt Git jetable +
   stubs moteurs dans le PATH (un stub `ansible-playbook`/`labctl` qui ENREGISTRE son
   invocation) :
   - chemin nominal simulé : gardes vertes dans l'ordre, stub moteur invoqué UNE fois ;
   - **contre-épreuve du GOAL — chaque refus ⇒ moteur jamais lancé** : pour CHAQUE garde
     (forme, réconciliation, branche, ancêtreté, archive absente/digest faux, pin,
     références de porte manquantes sur le marqueur, identité, palier fermé 403),
     mutation → refus nommé + **le fichier d'enregistrement du stub n'existe pas** ;
   - mutations sur le script lui-même (retirer une garde ⇒ rouge) — leçon G3/G4 :
     ancrage sur code décommenté, capture en fichier, jamais de pipe sous pipefail ;
   - scellement : `apim_ss_authoring_env` passé en extra-var sèche (mutation : le
     retirer ⇒ rouge) ; `PROMOTE_ENGINE` absent des `parameters{}` des deux fichiers
     de job (Jenkinsfile ET job.xml — le XML gagne).
2. **`scripts/test-archive-store.sh`** *(nouvelle)* — la lib contre un stub HTTP local :
   push idempotent, fetch re-haché, digest faux ⇒ refus, token jamais en argv/URL,
   HTTP non-2xx ⇒ refus nommé (jamais un zip d'erreur HTML pris pour une archive).
3. **`go test ./mocks/webmethods/`** — sémantique archive (unit, `-count=1` via le
   harnais shell qui l'invoque : le cache Go ment, piège G1).
4. Jenkinsfiles : `test-jenkinsfile-lint.sh` passe de 11 à 13 fichiers (team-promote,
   api-promote-export).

### Portes live (lab requis, rejouables)

5. **Fidélité du mock** : `test-archive-promotion.sh` contre `wm-mock-dev` (ou le mock
   du socle) — même X/X que contre le wM réel, script inchangé.
6. **LA porte du GOAL** : `scripts/test-promote-verb-live.sh` *(nouvelle)* contre le wM
   réel (`localhost:5555`) — pour **chacun des deux moteurs** : API jetable active
   routée `${alias}` → export sanitizé (digest) → env cible simulé vierge (teardown
   T9) → import → **GUID iso** + **ACTIVE** ; puis ré-import overwrite **sous charge
   4 voies** → **0 réponse non-200** ; contre-épreuve `UPDATE_FORBIDDEN` (le chemin
   publication refuse le deactivate hors authoring) ; nettoyage par trap.
7. **E2E chaîne** : sur le lab — export réel (job), PR de promotion, merge, pause
   nominative, apply vers `wm-mock-rec` **via le proxy** `wm-admin-rec`, commentaire de
   PR ✅, et la contre-épreuve de rétention : palier `rec` refermé (policy/grant
   révoqué) ⇒ `PALIER_FERME`, gateway inchangée (motif F4).

### §4.1 — Ce que G5 ne prouve PAS, et c'est voulu

- **La parité d'état des deux moteurs** (même manifeste ⇒ même état de gateway, registre
  des écarts) est **G8**. Ici : deux moteurs branchés, chacun prouvé vivant.
- **`DeployerGroup` (« qui déclenche »)** est **G2** — la pause nominative + 4-yeux
  conditionnel ne vérifie PAS l'appartenance au `approverGroup` de la porte.
- **Le rollback des paliers intermédiaires** est **G6**.
- **La conversion du pipeline governance** (apply-uac rec+ → archive) : parking §8.

## §5 — Inventaire des livrables

| Livrable | Nature |
|---|---|
| `mocks/webmethods` : routes archive + store | code Go + tests |
| `scripts/lib/archive-store.sh` | lib shell (push/fetch content-addressed) |
| `scripts/api-promote-export.sh` + `ci/Jenkinsfile.api-promote-export` + job XML + pose (`setup-team-onboard-jobs.sh`) | chemin export |
| `scripts/team-promote.sh` + `ci/Jenkinsfile.team-promote` + job XML + pose | chemin apply |
| `ansible/promote-api.yml` (play) | moteur client appelable CI |
| glue `labctl promote` (targets générés, bearerTokenFile) | moteur lab appelable CI |
| `scripts/lib/assert-merge-identity.sh` : `--allow-self-approval` | 4-yeux conditionnel à la porte |
| `wm-admin-proxy.openapi.yaml` : + `/archive` GET+POST | allowlist |
| `setup-vault-envs.sh`/`setup-vault-paliers.sh` : sub `envs/<env>/admin-oauth` + policy | credential par palier (G4 étendu) |
| `test-team-promote-wiring.sh`, `test-archive-store.sh`, `test-promote-verb-live.sh` | portes |
| `make lint-ci` étendu ; `test-jenkinsfile-lint.sh` 13 fichiers | portes CI |
| ADR-083 (verbe + transport + deux moteurs) ; `ENVIRONNEMENTS.md` §promotion ; handoff | docs |

## §6 — Parkings, avec rulings

1. **Pinner le guid automatiquement** (le job d'export ouvre la PR sur `promote.yml`) —
   réel, non bloquant : le refus `IMPORT_REFUSED` est fail-closed et le geste PR est
   celui que l'équipe fait déjà. Réouverture : friction constatée à l'usage.
2. **Client OAuth par palier** (`apply-<env>` KC, scope `deploy:<env>` seul) — la valeur
   de `envs/<env>/admin-oauth` est aujourd'hui partagée (ci-horsprod). La rétention
   mécanique tient par Vault (chemin par palier) + scope proxy ; le client par palier
   durcirait le plan réseau. Réouverture : G2, ou exigence client.
3. **Conversion du pipeline governance hors-prod au verbe archive** — le GOAL dit « le
   verbe de déploiement est l'import d'archive… `apply-uac` reste le verbe de dev », et
   `ci/Jenkinsfile` re-POSTe aujourd'hui rec/int. Tension NOMMÉE, non résolue ici :
   la projection UAC n'est pas un artefact exporté d'une gateway, et sa conversion se
   conçoit avec la parité G8. À trancher là-bas, pas en silence.
4. **Second webhook si le multi-job-par-token GWT ne tient pas la mesure live** (D1).
5. **`homol` sans mock d'AS / backend seedé** : la chaîne complète dev→…→prod par
   archive n'est exercée que jusqu'où le lab porte des cibles ; la porte du GOAL vise
   `dev → rec`, tenue. Réouverture : G6/G7 (parcours complet).
