# Handoff Fable 5 — État du labs STOA & plan séquencé (durcir → graduer)

> Analyse : stoa-labs (PoC control-plane-federation, accounts-team, payments-team,
> console-light, stoa-platform-ci, adr) en profondeur ; monorepo `stoa` lu pour les
> points de raccordement. Créé 2026-07-03 ; **rafraîchi 2026-07-10** (A'0 clos ET
> **POUSSÉ sur GitHub** ; incident remote réparé ; GOAL self-service wM cadré en
> session parallèle ; précédents : É0 levé 18/18 §0.quinquies, Phase A §0.quater).
>
> ✅ **A'0 / G14 CLOS (07-09) + POUSSÉ** : l'ex-« périmètre non-committé » (chaîne
> ADR-077 du 05/07 + grappe de preuves ADR-072/073/074 + token-provider wM) est en Git,
> découpé en **9 commits thématiques** `be70302..fe351a4` (governance-api / identité /
> console / docs ADR+EVIDENCE / preuves / token-provider / observabilité / docs ; +
> purge d'un binaire governance-api 10 Mo stagé par accident, désormais gitignoré).
> Build + `go test -race` verts post-commit. **GitHub = HEAD local** (vérifié
> ls-remote). `git status` : seul reste `GOAL-self-service-api-app-2026-07-09.md`
> (untracked, cadrage session parallèle, cf. §0.sexies).
>
> ⚠️ **Gotcha durement gagné (incident 07-09, réparé)** : TOUJOURS vérifier
> `git remote -v` AVANT un push. Une commande `git remote set-url` de la checklist
> gitlinks a été exécutée depuis le MAUVAIS répertoire (racine stoa-labs au lieu de
> `stoa-platform-ci/`) → l'origin de stoa-labs pointait le Gitea local → un push a
> envoyé tout l'historique stoa-labs en branche étrangère sur `ci/stoa-platform-ci`.
> Réparé le jour même : origin restauré GitHub, branche étrangère supprimée du Gitea,
> vrai push vérifié. Les checklists multi-repos doivent porter `git -C <chemin>`.

---

## 0. Verdict en une phrase

Le labs a **prouvé sa thèse** — un control plane sur briques OSS fédère 3 gateways
hétérogènes (WSO2, APISIX, webMethods **réel** 10.15) sous identité Oracle-master, avec
une discipline de preuve rare. **La Phase A (durcir) est désormais livrée en entier** :
« sécurité = f(intégrité) » est **enforced** ET **anti-spoof**, l'observabilité et
l'analytics sont **3/3 runtimes**, et la **finition A4/A6/A7 est close** (auth outbound
wM as-code, re-check ITSM au dispatch, console→webhook réel→déploiement + 4-yeux exercé
E2E). L'**environnement de démo est entièrement fonctionnel** (08/07) : déploiement
9/9, multi-env 22/22, identité 3/3, analytics 3/3. La piste CLIENT est ouverte : **É0
(bloqueurs transverses du livrable) est LEVÉ** le 07-09 (18/18 — proxy/CA/auth Git/
`make release`), prochaine marche É1-É4 (rolification Ansible). **A'0 est clos** (la
chaîne ADR-077 et toutes les preuves sont en Git, arbre propre). Ce qui reste : un peu
d'entretien (A'1-A'3), et surtout **(B) faire atterrir les briques prouvées dans la
plateforme `stoa`**, où deux d'entre elles (APISIX, WSO2) n'ont **aucune** existence.

---

## 0.bis Livré cette session (2026-07-03/04)

| Goal | Résultat | Preuve | Commits |
|---|---|---|---|
| **A8** — hygiène doc & statut ADR | ✅ | `HARD-CRITERIA-MAP` réconcilié ; ADR 070-076 statut à 2 axes (business vs maturité technique) | `630b1b0` |
| **A1** — enforcer « sécurité = f(intégrité) » | ✅ | gate `labctl apply` : pré-check `[INTEGRITY_UNFULFILLED]` + read-back gateway `[ENFORCEMENT_UNCONFIRMED]` ; `test-integrity-enforce.sh` **31/31 live** (contre-épreuve sabotage) | `e03cfee`, `6fac8b8`, `1925946` |
| **A2** — WSO2 OTel → traces 3/3 | ✅ | cause au bytecode (`url` seul + `properties` obligatoire) ; Tempo `['apisix','webmethods-mock','wso2']` | `558d435` |
| **A3** — analytics par fournisseur 3/3 | ✅ | `wso2-otel-tap` (spans OTel, pas les logs fichier) ; `test-txn-wso2.sh` **12/12**, pivot trace_id Tempo↔OpenSearch | `1a4442b`, `e3ab434` |
| **A5** — classification centrale anti-spoof + poly-repo | ✅ | registre central owner-keyé (`test-classification-central.sh` **11/11**) ; 2e repo pilote `payments-team` (H, bundle ≠ VH) | `3dc3766`, `5b4607a`, `58dddab` |
| **A4** — auth outbound wM as-code (idempotent) | ✅ | `ensureCredentialAlias` **write-always** (ré-émet le password base64) + refus d'une 2e action outbound (fail-closed) ; `test-outbound-auth.sh` **19/19 live** | `cef6b2d` |
| **A6** — re-check ITSM **LIVE au dispatch** (anti-TOCTOU) | ✅ | `preflightDispatchGate` fail-closed AVANT tout écrit gateway ; `change_ref` ancré dans `deploy.{env}.yaml` ; `dispatchgate_test.go` **7/7** + `demo-multienv.sh §③b` (révoqué→409, injoignable→503) + sous-commande `labctl dispatch-gate` (même vérité en stage Jenkins) | `daf9245` |
| **A7** — console-light : **webhook réel** + 4-yeux exercé E2E | ✅ | spec Playwright `50-four-eyes-denial` + `prove-a7-four-eyes.sh` **7/7** (`denials.jsonl` peuplé, 403 `SELF_APPROVAL_BLOCKED`, contre-épreuve identité bob≠dave) ; webhook réel Console→Gitea `ci/governance`→Jenkins `stoa-governance`→`apply-uac` (build live, cause webhook, APISIX 3/3) ; fix bug réel `rolled_back` (StatusBadge crashait) ; `GET /environments` | `b8e7f8d`, `39591d8` |

**Insights réutilisables (durement gagnés)** :
- **A1** : le read-back attrape ce que le projecteur ne corrige pas — l'action IAM AND
  wM est réutilisée telle quelle, un sabotage `allowAnonymous` n'est vu QUE par le gate.
- **A2** : « OTLP natif cassé » = config incomplète, pas une instabilité produit (vérité
  bytecode). Ne jamais présumer un bug produit sans lire le bytecode/la source.
- **A3** : les logs fichier WSO2 n'ont **pas** de trace_id → « Fluent Bit sidecar » (plan
  initial) = impasse. La seule source avec trace_id = les spans OTel. WSO2 exporte en
  **gzip** (codec serveur gRPC à enregistrer).
- **A5** : ne **jamais** keyer un lookup anti-spoof sur des champs projet-éditables. L'ancre
  doit être une identité injectée par le pipeline (`PROJECT_NAME`), pas l'`api.yaml`.
- **Méthode** : chaque goal a suivi comprendre → **review adversariale du design** →
  implémenter → prouver live → **review adversariale du diff** → docs. Les reviews de
  *design* ont attrapé des trous (A1 : faux négatif VH ; A5 : trou B1 de clé projet-éditable)
  AVANT d'écrire une ligne — c'est là que le gain est maximal.

~~⚠️ État du trial wM : chaîne accounts-read corrompue~~ → **RÉPARÉ le 04-07/07-07**
(rebuild-from-Git exécuté, cf. §0.quater). Reste vrai : le trial **flappe** ~25 min —
`wm-keepalive.sh` le recycle proactivement (uptime ≥ 23 min ; données dans l'ES externe,
un restart ne perd rien). Pattern opératoire pour un provisioning long :
`docker restart poc-webmethods-real` (fenêtre fraîche, boot ~2 min) →
`touch /tmp/wm-keepalive.pause` → travailler → `rm -f /tmp/wm-keepalive.pause`.

---

## 0.ter Livré 2026-07-05 — chaîne A : identité UTILISATEUR jusqu'à Vault (ADR-077)

Contrainte IT client : « un **utilisateur** se connecte au Vault, pas une application »,
avec des jobs Jenkins non interactifs. Livré et prouvé : **token exchange standard
RFC 8693** (Keycloak **bumpé 26.1.4 → 26.3.4**, l'exchange standard est GA depuis 26.2) →
JWT court `aud=vault` `sub=utilisateur` `tenant=<tenant>` → job Jenkins
`stoa-user-deploy` **sans aucun credential propre** → `auth/jwt/login` → token Vault
**nominatif et TENANT-scopé** (policy templatée : cross-tenant → 403 ; revoke fin de
build **prouvé** par lookup-self 403). `scripts/test-user-vault-jwt.sh` **24/24 live**
après durcissement post-review adversariale (bound azp, jetons hors argv, webhook sans
jeton → build rouge, audit scopé au run). **Wiring console BRANCHÉ le même jour** :
au `promote-approve`, la governance-api échange le Bearer de l'APPROBATEUR et
déclenche le job (`userdeploy.go`, opt-in `USER_DEPLOY_WEBHOOK_URL` +
`VAULT_EXCHANGE_SECRET[_FILE]` fail-fast, async, champ additif `user_deploy`,
URL webhook redactée dans les logs, arrêt gracieux) —
`scripts/test-console-user-deploy.sh` **12/12 live** (identité de bob, pas de dave ;
build corrélé à la promotion ; zéro jeton loggé, JWT et token GWT) + 7 tests
unitaires Go sous `-race`. Détail + runbook post-recreate KC :
`adr/adr-077-user-identity-to-vault-token-exchange.md`.

**Gotchas durement gagnés (2026-07-05)** :
- **Usernames fédérés = `<user>@bc.example`** (confirmé : le seeding console-light
  utilisait les prénoms nus et ne matchait RIEN — corrigé dans
  `console-light/scripts/setup-identity.sh`).
- **Recreate poc-keycloak = realm à re-seeder** — runbook complet ADR-077 §Restauration,
  **validé par une passe de non-régression** (A7 était retombé à 6/7, phase3 ne mintait
  plus) puis re-vert : A7 7/7, chaîne A 21/21 (script d'alors ; 24 checks après le
  durcissement post-review), mints CI 3/3. Les 3 pertes non couvertes
  par les seeds standards : (a) **`unmanagedAttributePolicy=DISABLED`** (défaut KC ≥ 24)
  fait ignorer EN SILENCE le PUT de l'attribut `tenant` (rôles OK, tenant absent → 403
  tenant à l'approve ; le seed console-light l'active désormais lui-même) ; (b) les
  **mappers `demo-tenant-attr`/`demo-groups` de stoa-portal** + groupe `int-team`
  (recréés par le bloc identité idempotent de `demo-multienv.sh`) ; (c) le **client
  runtime `accounts-read-consumer`** (créé par `labctl subscribe`) — recréé avec le même
  secret que `labctl-credentials.txt`.
- **`clientScopes` dans un realm import supprime les scopes built-in** → le scope
  `vault-aud` est provisionné par script, PAS dans `realm-stoa-lab.json`.
- **Groovy triple-quoted : `\"` est consommé par Groovy, pas par le shell** (le JSON
  partait sans guillemets → « error parsing JSON » Vault). Zéro backslash dans les
  blocs `sh` inline ; body construit par `printf` single-quoted.
- **Jenkins `config.xml` POST exige `charset=utf-8`** (sinon 500 « invalid XML
  character 0x80 » sur les accents) — et TOUJOURS vérifier le code HTTP : la mise à
  jour échouait en silence.
- **`docker exec … | grep -q` sous `pipefail` = SIGPIPE 141** dès que la sortie dépasse
  le buffer de pipe → faux FAIL. Variable + here-string.
- ~~⚠️ WSO2 trial : KM Keycloak absent, leg WSO2 phase3 dégradé~~ → **RÉSOLU le 07-07**
  (KM restauré + souscription rejouée via `demo.sh`, `phase3-identity-demo.sh` **3/3**,
  cf. §0.quater).

## 0.quater Livré 2026-07-04→07 — enum console, réparation gateways, remise en état

| Chantier | Résultat | Preuve | Commits |
|---|---|---|---|
| **Migration enum console-light `VVH`→`VH/H/M`** | ✅ | la migration ADR-076 déc. #1 n'avait couvert QUE labctl/BFF ; console-light (schéma ajv, types, 3 pages, seed) + le contrat VIVANT `payments-initiation=VVH` → **422 à chaque édition**. Migré (mapping criticité H→M, VH→H, VVH→VH) + seed commité sur `main` du repo governance (le BFF lit `ReadFile(ref "main")`, PAS le worktree). PUT draft 200 (était 422) ; **Playwright 18/18** | `f5b6d6a`, `7563427`, seed `031535a` |
| **Réparation gateways → apply-uac 9/9** (user a autorisé) | ✅ | wM : force-delete des 6 objets corrompus (`?forceDelete=true` → 204) ; WSO2 : registry corrompu (create/delete/delete-api TOUS 500 en REST, irréparable par l'API) + conteneur SANS volume → `up --force-recreate` = registry propre en ~30 s. apply-uac recrée frais (adapters create-if-absent) → **build webhook #58 SUCCESS 9/9, job `stoa-governance` bleu** | (ops live, pas de code) |
| **Analytics WSO2 re-câblée post-recreate** | ✅ | la config OTel in-container est PERDUE au recreate → rejouer `WSO2_OTLP_TARGET=wso2-otel-tap:4317 scripts/setup-wso2-otel.sh` (les APIs publiées survivent au restart) ; `test-txn-wso2.sh` **12/12**, parité 3/3 | — |
| **Remise en état multi-env + identité (07-07)** | ✅ | (1) **Vault dev-mode en seed PARTIEL** (`envs/*`, `keycloak`, `ci`, `deploy/*` perdus ; symptôme `{"errors":[]}` 404 KV) → rejouer LA CHAÎNE complète setup-vault{,-envs,-approle}.sh + setup-ci-{horsprod,applier}.sh ; (2) **wm-admin-{dev,rec,int} corrompus** (même signature PUT 500 « null ») → force-delete + `setup-wm-admin-proxy.sh` → matrice **15/15** ; (3) `demo-multienv.sh` **22/22** (19 d'origine + contre-épreuves A6 ③b) ; (4) `phase3-identity-demo.sh` **3/3** (WSO2 200 + APISIX 200 + wM 200 avec UN token Oracle-fédéré, 401×3 sans) | (ops live) |

**🐛 Bug labctl trouvé et tracké (non corrigé)** : `consumer.go` associe l'application
consommatrice au **premier match de nom** (`findByName`) — avec 2 versions actives du
même nom sur wM (accounts-read v1.0.0 + v1.0.1, héritage du cycle promotion/rollback
ADR-075), subscribe n'associe QU'UNE version → **401 sur l'autre** (`applicationLookup=
strict`). Vécu live au leg wM de phase3 ; fix manuel `PUT /applications/{id}/apis` avec
les 2 apiIDs. Fix propre : associer la version du manifeste (`findByNameVersion`) ou
toutes les versions actives.

**Gotchas d'environnement (à connaître avant toute session)** :
- **WSO2 recreate ≠ restart** : le recreate perd OTel + KM + consumers (conteneur stock
  sans volume) ; le restart ne perd rien. Runbook post-recreate : apply-uac (APIs) →
  `setup-wso2-otel.sh` (traces/analytics) → `setup-identity.sh` (KM, garde l'existant) →
  `demo.sh` (souscription consumer).
- **Vault dev-mode = in-memory** : après un restart du conteneur, TOUT re-seeder (la
  chaîne complète, pas un sous-ensemble — l'état partiel est vicieux : l'AppRole login
  marche mais les lectures 404).
- **apply-uac local** : penser `ITSM_URL=http://localhost:8788` sinon le gate A6
  refuse `→prod` fail-closed (`503 ITSM_NOT_CONFIGURED` — comportement voulu).

---

## 0.quinquies Livré 2026-07-06→09 — piste CLIENT : rollout modulaire, purge, process livrable

> Changement d'axe : plus rien à prouver en labs — cette piste prépare **l'intégration chez
> le client** (webMethods 10.15, Jenkins existant, ITSM, IdP d'entreprise).

| Chantier | Résultat | Où |
|---|---|---|
| **Rollout client modulaire** | ✅ Procédure « socle minimal + 9 briques à interrupteur » — chaque brique a son toggle VÉRIFIÉ dans le code (`VAULT_ADDR` absent = no-op `vault.go:47` ; `ITSM_URL` vide + `itsmCheck` = 503 fail-closed ; gate intégrité armé par la présence d'`api.yaml` ; wiring console opt-in `USER_DEPLOY_WEBHOOK_URL`), son état OFF, sa marche arrière, sa preuve X/X = critère d'acceptation. Ordre P0 Jenkins→P6 si le client ne choisit pas | mémoire `client-rollout-modular`, séquence détaillée en conversation 07-06 |
| **Audit purge secrets (07-07)** | ✅ gitleaks sur les 5 repos + l'historique GitHub (64 commits) : **rien à purger, pas de réécriture**. Tout le sensible réel est untracked+gitignoré (`labctl-credentials.txt`, `console-light/var/` — dont clé SSH `governance_signing` —, `.claude/`) ; les 7 hits historiques = valeurs démo publiques (`Administrator:manage`, `poc-apisix-admin-key`, fixtures). La « purge » devient une **checklist de livraison** : `git archive` (exclut l'untracked), remplacer les placeholders (`stoa-root-token`, `vault-exchange-secret-poc`, `Stoa!Passw0rd2026`), régénérer le nominal (clé signing, secrets clients OAuth2) | mémoire `client-rollout-modular` (bloc audit) |
| **Process PoC → livrable (07-09)** | ✅ **`DELIVERY-PROCESS.md`** (**committé** `652d122`) : livrable en 3 couches (MOTEUR invariant / CONFIG client `clients/<x>/` / PREUVE `--tags verify`) ; 4 degrés d'automatisation D0-D3 (D1 ≠ `ansible --check` — pattern `reconcile` ; D3 sans risque car la politique vit dans labctl) ; migration Ansible É1→É9 (une brique = un rôle = un tag = un verify, commencer par rolifier `is-mtls-setup.yml` + `deploy/reconcile` existants) ; fondé sur inventaire multi-agents : **59 knobs**, mapping rôles, critique adversariale | `DELIVERY-PROCESS.md`, mémoire `poc-to-deliverable` |
| **É0 — bloqueurs transverses LEVÉS (07-09)** | ✅ les 4 chantiers implémentés + prouvés **`test-e0-blockers.sh` → 18/18** (dont preuves au niveau du BINAIRE livré, exécutable hors zone) : (1) proxy `http.ProxyFromEnvironment` sur les 2 transports labctl ; (2) CA `LABCTL_CA_FILE`/`VAULT_CACERT` (RootCAs étendus, **fail-closed** si bundle illisible) + `-k` purgé des 3 provision OpenSearch (`OPENSEARCH_CA_FILE`/`OPENSEARCH_INSECURE`) ; (3) auth Git `GOVERNANCE_GIT_URL`/`PROJECT_REPO` + `GIT_CREDENTIALS_ID` optionnel via `GIT_ASKPASS` dans les 4 Jenkinsfiles (secret jamais URL/argv/log) ; (4) **`make release`** : 3 binaires × 3 archs versionnés (ldflags → `labctl version`) + SHA256SUMS + **SBOM SPDX-2.3** (`release-sbom.sh` depuis vendor/modules.txt), air-gapped | commits **`652d122`** (stoa-labs) + **`079f2d9`** (stoa-platform-ci) ; EVIDENCE.md §É0, DELIVERY-PROCESS §4 statut LEVÉ |

**É0 : ~~bloqueurs~~ → LEVÉ 07-09** (détail ligne « É0 » du tableau ci-dessus ; preuve
`test-e0-blockers.sh` 18/18). **Reste la dette P1** (non-É0, backlog `DELIVERY-PROCESS.md`
§7) : **governance-api sans remote Git** (`gitrepo.go` commit/merge locaux, zéro push →
split-brain console↔pipeline chez un client), `host.docker.internal` dans
`Jenkinsfile.rollback`, `/tmp/stoa-wm-admin-token` partagé (course inter-builds),
`VAULT_ROLE_ID`+`APPLY_TENANT` littéraux dans les 4 Jenkinsfiles, issuer KC **compilé**
dans la console (`ui/src/config.ts`), aucun packaging hors-compose (systemd/TLS) pour
governance-api/onboarding-api.

**✅ Gitlinks imbriqués : RÉSOLU 07-09** (commit `4e02330`) : `accounts-team`,
`payments-team` **et `stoa-platform-ci`** étaient stagés à la racine de `stoa-labs` en
gitlinks 160000 SANS `.gitmodules` (répertoires vides pour tout cloneur). Purgés de
l'index (`git rm --cached -f`, contenu disque et repos autonomes intacts) + **ignorés
dans le `.gitignore` racine** pour empêcher un futur `git add .` de les recréer. Si un
jour leur contenu doit vivre dans stoa-labs : submodules (remote public requis) ou
dé-nesting — un choix explicite, plus jamais un accident de staging.

**Décision en suspens (posée 07-07, non tranchée)** : nom du binaire chez le client —
`labctl` reste le nom LAB (auto-descriptif « jetable », protège la condition C1) ; à la
frontière de packaging : `stoactl` (pilote produit STOA) vs nom neutre/client-brandé
(angle « couche souveraine possédée », le principe reuse-first). Un seul nom chez le client.

---

## 0.sexies Session parallèle 07-09 — self-service wM 10.15 (spikes prouvés, GOAL cadré → ADR-078)

Deux spikes live sur le trial wM 10.15 (détail : mémoire `wm-1015-teams-scoping`) :
- **Spike #1 Teams scoping** : l'isolation par équipe est ENFORCÉE sur l'admin API REST
  pour les **APIs** (3/3 sceptiques) ; les **applications ne sont PAS cloisonnées**
  (brèche prouvée : delete cross-team 204, register API invisible 201).
- **Spike #2 self-service OAuth2** : PROUVÉ en 2 variantes — N-proxies à alias statique
  + mono-proxy à mapper dynamique **fail-closed** (anti-spoof 3/3). Pièges : alias
  `${}` obligatoire, `aud` JWT en tableau, callout au stage transport.

**`GOAL-self-service-api-app-2026-07-09.md`** (racine PoC, **untracked** — à commiter
avec l'implémentation) : cadrage « prêt à exécuter », feeds **ADR-078**. Décision :
(P) producteur = GitOps ADR-076 tel quel (Teams natif suffit) ; (C) consommateur =
proxy admin OAuth2 par équipe (spike #2) + **2 gardes applicatives** (`owner` +
`register`) fermant la brèche applications du spike #1 ; (I) credentials = Keycloak
Client Registration + Initial Access Tokens scopés. Le Developer Portal natif n'est
PAS le point de départ (headless mais lourd, même limite que Teams sur les apps).

---

## 1. Ce qui marche vraiment (labs) — à jour

| Chantier | Statut | Preuve concrète |
|---|---|---|
| Fédération 3 runtimes + Define Once/Expose Everywhere (ADR-071/072) | ✅ PROUVÉ live | `labctl apply` 3/3 gw depuis 1 OpenAPI ; `demo.sh`, `EVIDENCE.md` Preuves 1-4 |
| Identité Oracle-master (Dex→Keycloak→3 gw) | ✅ PROUVÉ live | `phase3-identity-demo.sh` : 1 token → 200×3 / 401×3 |
| Médiation control-plane (ADR-072) | ✅ PROUVÉ | `test-onboarding-matrix` 8/8, `test-apply-scope` 11/11, `test-apply-audit` 13/13, `demo-mediation` 11/11 |
| Secrets Vault as-code + rotation (ADR-074) | ✅ PROUVÉ | `internal/vault`, AppRole least-privilege (403 croisés), `test-vault-rotation.sh` |
| CI multi-env sans gateway de promotion (ADR-075) | ✅ PROUVÉ | `demo-multienv.sh` **22/22** (07-07, inclut anti-TOCTOU A6) ; **vrai Jenkins** ; ITSM gate + 4-yeux + pin SHA |
| **Observabilité OTel fédérée** | ✅ **3/3** (A2) | Tempo : APISIX + webMethods + **WSO2** ; `setup-wso2-otel.sh` |
| **Analytics txn par fournisseur (ADR-070)** | ✅ **3/3** (A3) | data-stream + RBAC/FLS + redaction 1-point + pivot trace_id ; `wso2-otel-tap` ; `test-txn-wso2.sh` 12/12 |
| Traces wM réel → Tempo (ADR-073) | ✅ PROUVÉ | `wm-trace-bridge` |
| **GitOps cycle de vie API (ADR-076)** | ✅ **enforced + anti-spoof** (A1+A5) | gate apply fail-closed (31/31) + classification centrale owner-keyée (11/11) ; enum VH/H/M |
| console-light (IHM gouvernance) | ✅ Démo-able E2E, **désormais trackée dans Git** | `tsc` clean, **Playwright 18/18**, enum `VH/H/M` aligné BFF, UI→commit→webhook→Jenkins→**9/9 gateways** (build #58) |
| accounts-team + **payments-team** (repos-clients GitOps) | ✅ Fonctionnels | 2 pilotes poly-repo, bundles différents dérivés du central |
| **Identité utilisateur → Vault, token exchange (ADR-077)** | ✅ PROUVÉ live | `test-user-vault-jwt.sh` **24/24** ; KC 26.3.4, job Jenkins **zéro credential**, token Vault nominatif **tenant-scopé** + audit |

---

## 2. Les gaps réels restants (TOUS les gaps Phase A — G1-G8 — sont fermés)

| # | Gap | Nature | Goal |
|---|---|---|---|
| ~~G4~~ | ~~TokenProvider wM outbound à la main~~ → **fermé (A4**, 19/19) | — | ✅ |
| ~~G6~~ | ~~TOCTOU ITSM prod~~ → **fermé (A6**, dispatch-gate + 22/22) | — | ✅ |
| ~~G7~~ | ~~webhook démo / 4-yeux non exercé~~ → **fermé (A7**, denials.jsonl + 9/9) | — | ✅ |
| G9 | **audience wM non opposable** (trial 10.15) ; **dev/rec/int = mocks wM** ; **SSO OIDC OpenSearch** déféré ; **streaming >500 Mo** hors scope | Limites assumées | — (documentées) |
| G10 | **read-back enforcement APISIX/WSO2** absent : tout target non-wM sous gate A1 = structurellement rouge (`unverifiable`) | Fail-closed assumé | **B1** (adaptateurs plateforme) |
| G11 | **`labctl subscribe` multi-version wM** : association app→API au premier match de nom → 401 sur les autres versions actives | Bug tracké (07-07) | entretien |
| G12 | **Config WSO2 non déclarative** : un recreate perd OTel/KM/consumers (runbook manuel §0.quater) | Dette infra | entretien |
| G13 | **Secrets de démo en clair dans Git** (admin/admin, Administrator/manage, tokens webhook) — Vault est déjà câblé (ADR-074) | Blocker rollout client | entretien |
| ~~G14~~ | ~~Chaîne ADR-077 non commitée~~ → **fermé (A'0**, 07-09, 9 commits `be70302..fe351a4`) | — | ✅ |

---

## 3. Carte de graduation labs → `stoa` (points de raccordement)

| Brique labs | Point de greffe `stoa` | Verdict |
|---|---|---|
| Fédération control-plane | `control-plane-api/src/routers/federation.py` (master/sub-account **MCP**) | ⚠️ **Collision conceptuelle** (MCP vs cross-runtime) — décider extend vs namespace |
| GitOps cycle de vie API | `routers/{api_lifecycle,git,reconciliation}.py` + `tenants/*/apis/*.yaml` | ✅ À réutiliser (drift/sync déjà là) |
| Moteur dérivation intégrité→sécurité + **classification centrale** | `services/uac_validator.py`, `api_lifecycle.py` | Greenfield — porter `internal/render` + `internal/govsource` + `cmd/labctl/enforce.go` |
| Gateway mTLS/OAuth2 | `stoa-gateway/src/auth/{mtls,oidc,jwt,dpop}.rs` | ✅ Mature — **réutiliser, ne pas réimplémenter** |
| **APISIX** / **WSO2** | — | 🔴 **GREENFIELD — aucune trace**. Moule = `adapters/template/` + enum `gatewayType` CRD + doc sidecar |
| webMethods / Kong | `adapters/webmethods/`, `adapters/kong/` | ✅ Prod-ready — réutiliser |
| CLI stoactl | `cli/` (dans le monorepo) | ⚠️ Code source **non tracké** (sparse-checkout ?), **aucune CI** — clarifier |
| Secrets/Vault | `control-plane-api/src/services/vault_client.py` | ✅ Étendre (chemins KV) |
| CI multi-env | `.github/workflows/reusable-gitops-deploy.yml`, `promote-to-prod.yml` + `stoa-infra` (ArgoCD) | ✅ Réutiliser — **mapper** les gates (Jenkins+Ansible → GH Actions+ArgoCD) |
| RBAC / tenants / mTLS par tenant | `auth/rbac.py`, `routers/tenants.py`, `routers/tenant_ca.py` | ✅ Réutiliser |
| CRDs déclaratives | `charts/stoa-platform/crds/` + `stoa-operator` **vs** `tenants/*/apis/*.yaml` | ⚠️ **Deux mécanismes concurrents non unifiés** — trancher |

**3 pièges à signaler avant toute graduation :** collision « fédération » (MCP vs
cross-runtime) ; double source-de-vérité déclarative ; anomalie git `cli/src`.

---

## 4. PLAN — /goal restants pour Fable 5

> Chaque goal est auto-contenu (contexte + DoD + fichiers). Effort : S (<0.5j) · M (1-2j)
> · L (3j+). Racine labs = `/Users/torpedo/hlfh-repos/stoa-labs`.

### PHASE A — finition du labs : ✅ LIVRÉE EN ENTIER (A1-A8, cf. §0.bis)

### PHASE A' — entretien (petits goals autonomes, aucun ne bloque B)

---
**/goal A'0 — Commiter la chaîne ADR-077 (G14) : ✅ CLOS 07-09**
- Fait : 9 commits thématiques `be70302..fe351a4` (bandeau en tête). Arbre propre,
  build + tests -race verts post-commit.

---
**/goal A'1 — Fix subscribe multi-version wM (G11)**
- `consumer.go` : associer la version du manifeste (`findByNameVersion`) ou toutes les
  versions actives ; test unitaire 2-versions + re-preuve phase3. **Effort : S.**

---
**/goal A'2 — Config WSO2 déclarative (G12)**
- Bind-mount `deployment.toml` (OTel baked-in) + script bootstrap post-recreate unique
  et idempotent (apply-uac → otel → identity → subscribe), documenté dans le compose.
  **Effort : S-M.**

---
**/goal A'3 — Purge des secrets démo (G13, blocker rollout)**
- Remplacer les creds en clair des fichiers trackés par lecture Vault/env (le câblage
  ADR-074 existe) ; gitleaks en CI pour verrouiller. **Effort : M.**

---

### PHASE B — Graduer vers la plateforme `stoa` (le gros du reste-à-faire)

> Racine plateforme = `/Users/torpedo/hlfh-repos/stoa`. **B0 à trancher AVANT tout code.**

---
**/goal B0 — Décisions d'architecture bloquantes (à trancher avec l'équipe stoa)**
- **Objectif** : trancher 3 collisions. (1) **Fédération** : le cross-runtime du labs étend-il
  `routers/federation.py` (MCP) ou un namespace distinct ? (2) **Source de vérité déclarative** :
  étendre `tenants/*/apis/*.yaml` + `reconciliation.py` OU de vraies CRD K8s (`stoa-operator`) ?
  (3) **CLI** : pourquoi `cli/src` n'est pas tracké, où vit la source canonique ?
- **Critères** : un mini-ADR de graduation dans `stoa-docs` actant les 3 choix ; réf. par B1-B6.
- **Effort** : S (décision) / **bloque** B1-B6. **Priorité** : 🔴 première.

---
**/goal B1 — Adaptateurs APISIX + WSO2 dans control-plane-api (greenfield)**
- **Contexte** : les 2 gateways OSS que le labs prouve n'ont **aucune** existence dans le
  monorepo. webMethods/Kong/Gravitee/Apigee/AWS/Azure y sont déjà.
- **Objectif** : créer les adaptateurs APISIX et WSO2 sur le moule `adapters/template/`, en
  portant la logique prouvée dans `labctl/internal/adapter/{apisix,wso2}/` (publish,
  inboundAuth openid-connect, kafka-logger APISIX ; Key Manager + **le fix OTel A2** WSO2).
- **Critères** : `adapters/{apisix,wso2}/` conformes à `gateway_adapter_interface.py` ; `apisix`
  et `wso2` ajoutés à l'enum `gatewayType` du CRD ; docs sidecar façon webMethods.
- **Fichiers** : `stoa/control-plane-api/src/adapters/{apisix,wso2}/`,
  `charts/stoa-platform/crds/gatewayinstances.gostoa.dev.yaml` ; réf. labs `labctl/internal/adapter/`.
- **Effort** : L. **Priorité** : 🔴 (débloque toute réutilisation labs côté plateforme).

---
**/goal B2 — Porter dérivation intégrité→sécurité + classification centrale dans control-plane-api**
- **Contexte** : la logique « sécurité = f(intégrité) » (A1) + le gate anti-spoof (A5) vivent en
  Go (`internal/render`, `internal/govsource`, `cmd/labctl/enforce.go`). La plateforme valide
  l'UAC via `services/uac_validator.py`.
- **Objectif** : porter la dérivation + le gate fail-closed + le registre central owner-keyé dans
  `uac_validator.py`/`api_lifecycle.py`, mêmes codes (`INTEGRITY_INCONSISTENT`,
  `INTEGRITY_UNFULFILLED`, `ENFORCEMENT_UNCONFIRMED`, `CLASSIFICATION_SPOOFED/UNGOVERNED`).
- **Critères** : `POST .../validate` refuse VH sans bundle ; une PR qui downgrade sa
  classification → refusée côté plateforme ; parité avec les cas de test du labs.
- **Fichiers** : `stoa/control-plane-api/src/services/uac_validator.py`, `routers/api_lifecycle.py` ;
  réf. labs `internal/{render,govsource}/`, `cmd/labctl/enforce.go`.
- **Effort** : M-L. **Dépend de** A1+A5+B0. **Priorité** : 🟠.

---
**/goal B3 — Étendre vault_client.py avec les patterns Vault prouvés au labs**
- **Contexte** : `vault_client.py` (hvac, KV v2, dégradation gracieuse) gère les creds MCP. Le
  labs a prouvé AppRole least-privilège + rotation + fallback fail-closed + write scopé par projet.
- **Objectif** : étendre (pas recréer) `VaultClient` avec les chemins du labs (`secret/stoa/gateways/*`,
  `secret/stoa/projects/<team>/*`) et le modèle AppRole scopé (labctl≠ci≠projet).
- **Critères** : lecture des creds gateway tierce via `VaultClient` ; scopes croisés 403 reproduits ;
  aucune nouvelle classe client.
- **Fichiers** : `stoa/control-plane-api/src/services/vault_client.py` ; réf. labs
  `labctl/internal/vault/vault.go`, `scripts/setup-vault*.sh`.
- **Effort** : M. **Priorité** : 🟠.

---
**/goal B4 — Mapper le modèle de gates CI multi-env sur GitHub Actions + ArgoCD**
- **Contexte** : le labs prouve ITSM gate + 4-yeux + pin SHA + rollback git-revert en
  **Jenkins+Ansible**. La plateforme est **GH Actions + ArgoCD**.
- **Objectif** : mapper (pas recopier) chaque gate : ITSM → gate d'environnement + check, 4-yeux →
  required reviewers, pin SHA → « build once, promote », rollback → revert image N-1.
- **Critères** : tableau de correspondance gate-par-gate ; ITSM + 4-yeux fonctionnels sur un
  workflow de démo.
- **Fichiers** : `stoa/.github/workflows/{reusable-gitops-deploy,promote-to-prod}.yml` ; réf. labs
  `ci/Jenkinsfile{,.prod,.rollback}`, ADR-075.
- **Effort** : L. **Priorité** : 🟡.

---
**/goal B5 — Finaliser & étendre le CLI stoactl**
- **Contexte** : `stoa/cli/` a son code source **non tracké** et **aucune CI**. Le labs a des verbes
  prouvés (`apply`, `get apis`, `subscribe`, `plan`, `validate`, onboarding).
- **Objectif** : (1) résoudre l'anomalie de tracking (B0.3) ; (2) créer `cli-ci.yml` ; (3) porter les
  verbes labs (`onboard`, `federation`, `secrets`) sur le pattern `commands/{login,apply,get,status}`.
- **Critères** : `cli/src` tracké et buildable en CI ; nouveaux verbes alignés sur control-plane-api.
- **Fichiers** : `stoa/cli/`, `.github/workflows/` ; réf. labs `labctl/cmd/`.
- **Effort** : M. **Priorité** : 🟡.

---
**/goal B6 — Réconcilier le concept de « fédération » (anti-collision)**
- **Contexte** : `routers/federation.py` existe déjà (MCP multi-account) — sémantique différente de
  la fédération cross-runtime du labs.
- **Objectif** : selon B0.1, généraliser `federation_service.py` OU introduire un namespace distinct.
- **Critères** : un seul modèle nommé sans ambiguïté ; doc dans `stoa-docs` ; pas de duplication.
- **Fichiers** : `stoa/control-plane-api/src/routers/federation.py`, `services/federation_service.py`.
- **Effort** : M-L. **Dépend de** B0. **Priorité** : 🟡.

---

## 5. Ordonnancement recommandé

```
Phase A  : ✅ LIVRÉE (A1-A8)
Phase A' : A'0 ✅ CLOS 07-09 (chaîne ADR-077 committée) · A'1-A'3 (entretien, indépendants)
Phase B  : B0 (décisions, bloquant) → B1 (APISIX/WSO2, débloque tout)
           → B2, B3 → B4, B5, B6
Phase C  : piste CLIENT (§0.quinquies, indépendante de B) —
           C0 = É0 bloqueurs transverses : ✅ LEVÉ 07-09 (18/18, commits 652d122+079f2d9)
           → C1 = É1-É4 squelette Ansible + stoa_vault + stoa_socle (1er palier vendable)
             ← PROCHAINE étape de la piste client
           → C2+ = suivre DELIVERY-PROCESS.md §5 (É5-É9)
Piste D  : self-service wM 10.15 (§0.sexies, indépendante) — GOAL cadré prêt à
           exécuter → ADR-078 + gardes owner/register + Keycloak CRS (spikes prouvés)
```

- **B0 avant tout B** : les 3 collisions (fédération, double source-de-vérité, cli/src) doivent
  être tranchées sinon B1-B6 partent dans le mur.
- **B1 débloque la graduation** : tant qu'APISIX/WSO2 ne sont pas dans la plateforme, rien du labs
  OSS n'y atterrit — et le read-back enforcement (A1) y reste rouge (G10).
- **B2 capitalise A1+A5** : porter le gate enforced+anti-spoof dans la plateforme est ce qui
  transforme le différenciateur prouvé au labs en contrôle produit.
