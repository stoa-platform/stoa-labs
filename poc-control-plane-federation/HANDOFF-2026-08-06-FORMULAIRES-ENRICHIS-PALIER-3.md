# Handoff — Palier 3 : formulaires enrichis + chaîne PRODUCTEUR self-service

**Date** : 2026-08-06
**Branche** : `feat/onboarding-equipe-palier-1`, tête `523894b` (45 commits depuis `6706005` = état palier 2 sur gitea main)
**Statut** : 8 tâches livrées + 1 Critical émergent de revue finale fermé + durcissements. Revue finale de branche passée. **Non fusionné, non poussé** (gestes exploitant ci-dessous).

---

## 1. Ce qui est livré

La chaîne **producteur** self-service, complément de la chaîne consommateur du palier 2 :

| # | Brique | Fichier(s) |
|---|--------|-----------|
| T1 | Mesures versions/souscriptions sur la vraie wM 10.15 | `scripts/spike-api-versions-1015.sh` |
| T2 | Mock : multipart `/apis` + sémantique versions + teams | `mocks/webmethods/*` |
| T3 | Générateur de listes déroulantes + re-pose événementielle | `scripts/lib/generate-choices.sh`, `setup-team-onboard-jobs.sh` |
| T4 | `app-request` v2 (listes + identité entrante IP/cert/rotation) | `ci/jenkins/app-request.job.xml`, `provision-request.sh` |
| T5 | `api-request` (porte PRODUCTEUR : PR d'API sur le dépôt d'équipe) | `scripts/api-request.sh`, `ci/jenkins/api-request.job.xml`, `gateways/templates/publish.yml.tmpl` |
| T6 | Rôle publish : create-or-version (nouvelle version native wM) | `ansible/roles/apim_publish_api/*` |
| T7 | `team-publish` (webhook dépôt d'équipe → apply) + extensions `team-apply` | `scripts/team-publish.sh`, `ci/jenkins/team-publish.job.xml`, `team-apply.sh` |
| T8 | Matrice de preuve rejouable (10 points) | `scripts/test-producer-chain.sh` |

**Le flux** : une équipe soumet le formulaire `api-request` → PR `api/<nom>-<version>` sur SON dépôt (ADR-076) portant spec OpenAPI + manifeste `publish.yml` + plan commenté → merge → webhook Gitea → job `team-publish` → **pause nominative** + **garde d'identité** (le merge doit être fait par l'identité qui se connecte à Vault) → apply du manifeste par le rôle `apim_publish_api` contre la gateway. La nouvelle version d'une API existante est gérée nativement (`POST /apis/{id}/versions`, transport des souscriptions selon le comportement **mesuré** sur 10.15).

Faits mesurés qui gouvernent le code (spike T1) : souscriptions transportées **SSI** `retainApplications:true` explicite (mauvaise casse = ignorée en silence) ; policies clonées (ids neufs) ; nouvelle version naît `isActive:false` ; duplication depuis la **dernière** version seulement ; le plus grand semver **n'est pas** la dernière version (mesuré : `1.0.0` minée depuis `1.0.1`) → `VERSION_BASE_AMBIGUE` fail-closed ; ressource supprimée → **401** (pas 404) sur 10.15.

---

## 2. Posture de sécurité (ce que les revues adversariales ont fermé)

Ces défauts n'étaient **pas** visibles aux tests des tâches ; ils ont été trouvés par revue multi-lentilles + vérification adversariale et fermés sous attaque répétée.

- **RCE sur l'agent Jenkins (Critical, T7).** Le champ `contract` d'un manifeste d'API, écrit par une équipe dans son dépôt, était **templé par Ansible** → `{{ lookup('pipe','…') }}` = exécution de code sur l'agent porteur du token Vault. Fermé par `team-publish.sh` §4 (liste blanche exacte sur `contract` + scan Jinja du reste, sur le YAML **chargé** — pas le texte brut). **Prouvé étanche 3× sous attaque** (échappements hex/unicode/fold YAML/ancres, ansible 2.18 et 2.19). Le « second rempart » côté rôle initialement tenté était contournable et cassait un appelant légitime → **retiré**, `team-publish.sh §4` est la frontière unique et honnête.

- **Capture cross-équipe d'une API plateforme (Critical émergent, revue finale).** Une équipe onboardée pouvait s'approprier une API plateforme (owner + équipe) via `api-request ACTION=create API_NAME=provisioning API_VERSION=<sa version>` self-mergé : la porte ne scannait que `clients/` (l'API `provisioning` vit sous `gateways/`), et le rôle, trouvant l'API par name+version **exact**, sautait toutes ses gardes d'appartenance. Fermé par **`API_OWNER_MISMATCH`** : dès que l'id est trouvé, avant tout geste d'écriture, la chaîne confirme que **toute la lignée du nom** appartient à l'équipe demandeuse (profils système `Administrators`/`Default` **exclus** — ils ne valent pas appartenance, mesuré) ; sinon refus fail-closed. Le sweep de la porte balaie désormais aussi `gateways/`. **Prouvé fermé sous attaque** (update:true, version différente, filename≠name, API hors Git, profils système, co-propriété) — et le knob de désarmement **n'est pas contrôlable** depuis le dépôt d'une équipe (whitelist du manifeste), seulement par la config opérateur.

- **Segregation tenant sur les trois chemins d'écriture** (mint / reprise / exact-match) : même confirmation d'appartenance, `VERSION_BASE_FOREIGN` / `VERSION_RESUME_FOREIGN` / `API_OWNER_MISMATCH` / `TEAM_IS_SYSTEM_PROFILE`.

- **Anti-forge du webhook** : `team-publish.sh` réconcilie le payload avec Gitea (`GET pulls/<n>` → assert `merged` + `merge_commit_sha` + `head.ref` + `base.ref==main`) — un payload forgé/rejoué est rejeté. Plus `merge-base --is-ancestor`, validation de forme avant argv, dérivation d'autorité `team = repository.full_name × providers` (`REPO_NON_DECLARE`/`REPO_AMBIGU`).

---

## 3. GESTES D'EXPLOITATION requis (à faire par un humain)

1. **Fusion & push.** La branche n'est ni fusionnée ni poussée. Le push `gitea main` et la fusion sont des gestes utilisateur (l'agent en est délibérément empêché).

2. **Lever le gate Gitea (bloquant pour le vrai pipeline).** Le palier 3 n'est **pas** sur `ci/stoa-labs@main` — les jobs Jenkins clonent `main`, qui porte encore le palier 2. Tant que le palier 3 n'y est pas, un job `team-publish` posé échouerait « fichier absent ». **Ce qui reste STRICTEMENT non prouvé en conditions réelles** : le job `team-publish` exécuté comme **vrai pipeline Jenkins** (pause + identité oscar + finally) — prouvé jusqu'ici par miroir de `team-apply` + wiring + exécution directe des scripts + substitution de dépôt jetable (2 lignes XML). Après le merge sur `ci/stoa-labs@main`, rejouer `test-producer-chain.sh` **sans** la substitution est le contrôle restant.

3. **Migration : assigner les APIs `Default` à une équipe.** Conséquence directe de la fermeture de la capture : sur la gateway, **toute API en `Default`** (les 12 APIs du lab, `provisioning` comprise) devient **non ré-appliquable par une équipe** tant qu'un admin ne lui a pas assigné une équipe réelle (`POST /assets/team`). `Default` ne vaut pas appartenance — c'est la fermeture même. À prévoir avant que les équipes ne publient sur une gateway existante.

4. **Enregistrer le webhook serveur de `team-publish`** sur chaque dépôt d'équipe (fait à l'onboarding par `team-apply` étendu, idempotent) ; vérifier qu'il pointe l'alias in-cluster.

5. **Créditer Jenkins pour la re-pose (si Jenkins authentifié en prod).** La re-pose des listes tourne en best-effort et **crie** un ⚠ sur la PR si Jenkins refuse ; au lab l'instance est ouverte. En prod authentifié, câbler un credential Jenkins pour `setup-team-onboard-jobs.sh`, sinon les listes se figent (dégradation **visible**, pas silencieuse).

---

## 4. Réserves & dettes (triées à la revue finale — aucune n'est un trou de sécurité)

- **HMAC webhook enregistré mais non vérifié côté Jenkins** (limite plugin GWT 2.4.2). La réconciliation Gitea (`GET pulls`) rejette seule tout payload forgé → **OK handoff** (un rejeu ne peut que ré-appliquer un état déjà approuvé et idempotent).
- **`provision-request.sh` : token Gitea dans l'URL de push (argv, visible `ps`)** — **préexistant** (sur `main`, non introduit par le palier 3). Remède connu : migrer vers `GIT_CONFIG_COUNT/KEY_0=http.extraheader` comme `team-publish.sh`/`api-request.sh`.
- **Raffinement ∀-lignée → per-version.** `API_OWNER_MISMATCH` exige que **toute** la lignée du nom appartienne à l'équipe. Sur une lignée à propriété **mixte** (une version possédée, une sœur en `Default`), ré-appliquer sa **propre** version est refusé. **Non atteignable par la chaîne** (les lignées sont team-homogènes par construction : le mint hérite des teams de la base + `VERSION_BASE_FOREIGN` interdit le mint cross-équipe) — exige un split de propriété créé manuellement par un admin. Direction sûre (fail-closed). Raffinement possible : vérifier l'appartenance de la version **demandée** seulement — mais c'est un narrowing du garde de sécurité qui exige sa **propre re-vérification adversariale**, à ne pas faire à la légère.
- **Divers, tous divulgués** : job `team-publish` unique sérialise les équipes (DisableConcurrentBuilds) ; pause nominative **sans timeout** (une demande jamais approuvée reste en file — abandon manuel) ; « 4-yeux » inerte quand les PR sont ouvertes par un compte de service ; `urlopen` de la réconciliation sans timeout (fail-closed, motif préexistant) ; 2 tokens Gitea éphémères non révoqués (limite CLI 1.22) ; `test-producer-chain.sh` §9 red-team étroit (rc littéral, pas besoin) ; nit cosmétique K7 (`grep … /dev/null` mort dans le test, pas le garde).
- **Enforce (T4)** : la gouvernance de `enforce` (propriété de l'API, risque cross-consommateur) est renvoyée au merge — le formulaire ne la décide plus, la PR porte l'avertissement. Question plateforme ouverte.

---

## 5. Preuves rejouables

- `scripts/test-producer-chain.sh` — matrice PRODUCTEUR **10/10** (non-régression palier 2 en preuve 0 ; E2E create/new-version ; `ps` avec contrôle positif ; teardown symétrique ; le harnais sait rougir). Le drain des pauses ne cible que les builds que le run prouve siens.
- `scripts/test-publish-version.sh` — rôle create-or-version **65/65** (dont la capture `provisioning` vue rouge puis fermée, K0-K7).
- `scripts/test-api-request.sh` 28/28 ; `test-team-publish-wiring.sh` 86/86 ; `test-generate-choices.sh` 47/47 ; `test-app-request-v2.sh` 18/18 ; `go test ./...` (mock) 46.
- gitleaks : 9 hits, tous `-u Administrator:manage` (admin par défaut du mock, motif établi dans 7 scripts antérieurs) — pas un secret réel ; le garde du dépôt est `check-no-plaintext-secrets.sh`.

---

## 6. Prochaine étape actée : `app-request` v3 (« identité entrante enrichie »)

Retour utilisateur 2026-08-06 sur le formulaire app v2 — incrément séparé, son propre spec/plan, **après** ce scellement. Décisions verrouillées : (1) IP allowlist **multiple** (form-only, le manifeste accepte déjà la liste) ; (2) **sélection d'app existante** pour un replace (générateur de liste + `ChoiceParameter`) ; (3) token = **clé backend** (`backend_key_ref` déjà supporté par le rôle, à exposer au formulaire ; ce n'est PAS une identité entrante) ; (4) **nom de claim** au manifeste (défaut `azp` ; load-bearing sur la gateway/IdP du client, **décoratif** sur le lab wM 10.15 où la stratégie est `azp==clientId`).
