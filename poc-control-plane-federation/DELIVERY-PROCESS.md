# DELIVERY-PROCESS — Transformation du PoC en livrable client (Ansible-first, modulaire)

> **Objet.** Process step-by-step pour transformer ce PoC en **livrable transposable d'un client à
> l'autre** : Ansible comme véhicule d'installation, une **couche de configuration** explicite
> (endpoints & co), des **degrés d'automatisation** progressifs, et une modularité brique par brique
> (SOCLE, B1..B9 — cf. mémoire rollout + ADR-070..077).
> Établi 2026-07-09 sur inventaire exhaustif : 59 knobs de config, 37 scripts, patterns Ansible
> existants (`ansible/is-mtls-setup.yml`, `stoa-platform-ci/deploy/*.yml`), critique de transposabilité.

---

## 1. Principe : le livrable a TROIS couches

| Couche | Contenu | Règle |
|---|---|---|
| **MOTEUR** (invariant) | `labctl` (sources + `vendor/`), Jenkinsfiles, playbooks/rôles Ansible, contrat allowlist `wm-admin-proxy.openapi.yaml`, governance-api/onboarding-api, token-provider (src Java), dashboards Grafana, index-templates OpenSearch, ADR-070..077 | Part chez TOUT client **tel quel**. Zéro édition sur site. Toute politique de sécurité (gates fail-closed) vit ICI, dans le binaire — jamais dans l'orchestrateur. |
| **CONFIG CLIENT** (la transposabilité) | `targets*.yaml`, `envs/{env}/targets*.yaml`, `environments.yaml`, `classifications.yaml`, realm Keycloak, profils token-provider, `inventory.ini` + `group_vars/`, variables pipeline | UN répertoire par client (§3). C'est la SEULE chose qu'on instancie. Un nouveau client = copier le profil exemple, remplir, jouer les playbooks. |
| **PREUVE** (recette) | `scripts/test-*.sh` convertis en `--tags verify` par rôle | Chaque brique livrée = sa preuve X/X rejouée CHEZ le client comme critère d'acceptation contractuel. |

**Ne part JAMAIS** (démo-only) : `mocks/webmethods/`, `cmd/itsm-mock`, Dex (`identity/dex/`), Microcks,
`docker-compose.{poc,envs,wm,ci}.yml`, `scripts/demo-*.sh`, `up/down/teardown.sh`, `wm-keepalive.sh`,
`labctl-credentials.txt`, `console-light/var/`, `evidence/`, secrets placeholder du realm
(`vault-exchange-secret-poc`, `poc-gateways-secret` — à régénérer), instances pilotes
`accounts-team`/`payments-team` (seul le **gabarit** part), docs internes (EVIDENCE, HANDOFF, PLAN,
POSITIONING, HARD-CRITERIA-MAP).

---

## 2. La couche de configuration — les fichiers qui rendent le projet transposable

Par ordre d'importance :

1. **`targets.yaml` / `targets.cluster.yaml`** — LE fichier client. Par gateway : `adminUrl`,
   `gatewayUrl`, `credentials` (→ Vault), `inboundAuth` (issuer/jwks/audience/introspection),
   `backendUrl` ; blocs `keycloak`, `backstage` (owner = tenant canonique). La dualité host/cluster
   matérialise les **deux horizons réseau** — chez chaque client, re-cartographier : d'où labctl
   parle-t-il au control-plane ? d'où la gateway joint-elle JWKS et backend ?
2. **`envs/{dev,rec,int,prod}/targets*.yaml`** — la matière PAR ENV (ADR-075) : URL du proxy
   `wm-admin-{env}` (prod = admin direct), `routing.endpointAlias` (backend de CET env),
   `credentialAlias`, `bearerTokenFile`. *Tout ce qui diffère par env vit ici, jamais dans le contrat.*
3. **`environments.yaml`** (repo gouvernance) — la chaîne d'envs + gates par saut (`itsmCheck`,
   `fourEyes`, `requireChangeRef`, `approverGroup`). C'est le fichier qui ENCODE le process de
   promotion du client — chaque client a le sien.
4. **`governance/classifications.yaml`** (repo plateforme) — registre central (owner, tenant, api) →
   classification VH/H/M. Seed par client, propriété de sa data-governance.
5. **`identity/keycloak/realm-stoa-lab.json`** — squelette de realm à instancier (renommer,
   régénérer TOUS les secrets ; le scope `vault-aud` reste créé par script, JAMAIS dans le JSON).
6. **Profils token-provider** (`gateways/webmethods/token-provider/config/profiles/*.example.json`
   + `vault.json.example`) — un profil par backend legacy du client.
7. **`ansible/inventory.example.ini` + `group_vars/`** — l'inventaire (hôtes IS réels, SSH,
   `is_restart_host`/`is_restart_cmd`) + toutes les variables `${VAR:-défaut}` des scripts promues
   en vars Ansible.
8. **Variables pipeline** (blocs `environment{}` des Jenkinsfiles → à paramétrer) : `KEYCLOAK_URL`,
   `VAULT_ADDR`, `ITSM_URL`, `LABCTL_CLASSIFICATION_SOURCE`, `APPLY_TENANT`, `GOVERNANCE_GIT_URL`.

### Le profil client (structure cible)

```
clients/
  _example/                      # gabarit livré, seul répertoire versionné dans le moteur
    inventory.ini                # hôtes IS/WSO2/APISIX, is_restart_cmd, connexion SSH
    group_vars/
      all.yml                    # ~40 knobs à défauts raisonnables (ports, realm, tenants…)
      endpoints.yml              # les ~20 knobs OBLIGATOIRES : URLs admin/data des gateways,
                                 #   KC issuer (UNE seule variable, propagée partout), VAULT_ADDR,
                                 #   ITSM_URL, GOVERNANCE_GIT_URL, backend par env
      vault.yml                  # refs Vault (chemins KV) — jamais de secret en clair
    targets/                     # targets.yaml.j2 + envs/{env}/targets.yaml.j2 instanciés
    environments.yaml            # chaîne + gates du client
    classifications.yaml         # seed du registre central
  <client-x>/                    # instancié par engagement, hors du repo moteur
```

**Règle d'or issue de l'inventaire :** l'issuer Keycloak (`KC_HOSTNAME`) se propage aujourd'hui EN DUR
dans targets.yaml, envs/*, Jenkinsfiles, scripts ET la console (compile-time `ui/src/config.ts`).
Sa variabilisation doit être **atomique** sur toutes ces surfaces (sinon `iss` mismatch → JWT rejetés).
Une seule variable `stoa_kc_issuer` dans `endpoints.yml`, tout le reste en dérive.

---

## 3. Les 4 degrés d'automatisation (par brique, au choix du client)

| Degré | Nom | Ce que c'est | Outillage |
|---|---|---|---|
| **D0** | Runbook guidé | L'opérateur exécute les scripts/étapes documentés, pas d'orchestrateur | scripts `setup-*.sh` + runbook par brique |
| **D1** | Audit sans mutation | État requis vs enforced, AUCUNE écriture | `labctl plan/validate/render/get` + `dispatch-gate` + `reconcile{,-one}.yml` + `--tags verify` |
| **D2** | Converge par brique | `ansible-playbook site.yml --tags <brique>` idempotent, re-run = no-op | rôles §5, read-back fail-closed après chaque mutation |
| **D3** | Pipeline gated | Jenkins orchestre Ansible ; webhook → converge ; promotion → gates | Jenkinsfiles + jobs seedés |

Notes d'architecture (vérifiées) :
- **D1 n'est PAS `ansible --check`** : les plays sont bâtis sur `uri`/`command` (skippés en check
  mode → asserts faussés). Le degré audit se livre comme le pattern `reconcile` existant : tasks
  read-only `changed_when: false` + verdict calculé. À généraliser en `tasks/verify.yml` par rôle.
- **D3 n'ajoute AUCUN risque de contournement** : les gates (`INTEGRITY_UNFULFILLED`,
  `CLASSIFICATION_SPOOFED/UNGOVERNED`, ITSM au dispatch, 4-yeux) vivent dans `labctl`/governance-api,
  pas dans l'orchestrateur. Ansible peut rester bête ; le binaire porte la politique. **C'est
  l'argument de vente du D3.**
- **Rollback** : la promotion prod a le sien (revert Git + re-apply, jamais de DELETE). Pour les
  mutations de config (KC, Vault, WSO2, jobs), le rollback réaliste = **re-run du setup idempotent
  vers l'état voulu** — à documenter comme tel, pas à promettre autrement.
- **Résidu manuel incompressible** (à afficher « guidé », jamais « zero-touch ») : token-provider wM
  (3 services Java dans Designer + `jcode.sh` sur l'IS), restart WSO2 après création du Key Manager,
  import du realm sur un KC client existant, fédération IdP réelle (Dex = mock), contrat de l'API
  ITSM réelle (le mock ne prouve que le knob `ITSM_URL`).

---

## 4. Étape 0 — lever les 3 bloqueurs transverses (AVANT toute rolification)

> **STATUT : LEVÉ (2026-07-09)** — les 4 chantiers ci-dessous sont implémentés et prouvés par
> `./scripts/test-e0-blockers.sh` → **18/18 PASS** (preuves au niveau du binaire livré, s'exécute
> hors zone sans le compose). Détail dans EVIDENCE.md § « É0 : levée des 4 bloqueurs transverses ».

Ces trois-là gataient TOUTES les briques dès qu'on quitte le poste du lab (critique 2026-07-09) :

1. **Proxy sortant d'entreprise** : `labctl/internal/httpx/client.go` construisait ses
   `http.Transport` SANS `Proxy: http.ProxyFromEnvironment` → derrière un egress proxy bancaire,
   tout appel admin timeout. **Fait** : httpx + `targetshealth.go` (la sonde passe par httpx).
2. **CA d'entreprise** : le seul knob TLS était `Insecure` par gateway / `VAULT_INSECURE`
   (binaire : trust système OU rien). **Fait** : `LABCTL_CA_FILE` / `VAULT_CACERT` (bundle PEM
   ajouté à `RootCAs`, fail-closed si illisible), `curl -k` purgé des 3 provision OpenSearch
   (knobs `OPENSEARCH_CA_FILE` / `OPENSEARCH_INSECURE`, défaut PoC true).
3. **Auth Git** : les clones étaient anonymes (`git clone` sans `credentialsId`,
   `http://gitea:3000/ci/governance.git` en dur). **Fait** : `GOVERNANCE_GIT_URL` (resp.
   `PROJECT_REPO`) + convention `GIT_CREDENTIALS_ID` optionnelle (helper `GIT_ASKPASS`, secret
   jamais URL/argv/log) dans les 4 Jenkinsfiles.

Et un chantier de **release** : les binaires étaient untracked, arch native only, rebuild par les
scripts de preuve. **Fait** : `make release` → labctl + governance-api + onboarding-api multi-arch
(linux/amd64 + linux/arm64 + darwin/arm64) versionnés (ldflags, `labctl version` traçable au
commit) + `SHA256SUMS` + SBOM SPDX-2.3 (`scripts/release-sbom.sh`, depuis `vendor/modules.txt`),
buildés hors zone (`GOPROXY=off -mod=vendor`). L'agent Jenkins client n'a PAS Go : il reçoit le
binaire, jamais le toolchain.

---

## 5. Étapes 1..8 — migration Ansible progressive (une brique = un rôle = un tag = un verify)

> Principe : commencer par ce qui est **déjà Ansible et prouvé**, puis la brique la plus transverse
> (Vault), puis suivre l'ordre du rollout client (P0→P6) pour que **chaque étape de migration
> produise un palier livrable** avec sa preuve convertie. Conventions à prolonger (elles existent
> déjà dans `is-mtls-setup.yml` et `deploy/*.yml`) : read-modify-write idempotent, read-back
> fail-closed après chaque mutation, asserts pédagogiques en tête de play, secrets Vault en pur
> `uri` + `no_log`, fallback total sans `VAULT_ADDR`, `ansible.builtin` uniquement, **Ansible =
> orchestrateur / labctl = moteur gateway unique** (aucun `uri` de mutation wM dans les plays).

| Ét. | Rôle | Brique | Absorbe (bash → Ansible) | Verify (`--tags verify`) | Effort |
|---|---|---|---|---|---|
| **1** | *squelette* | — | Rolifier l'EXISTANT sans logique nouvelle : `is-mtls-setup.yml` → `stoa_integrity_gate/tasks/is-mtls.yml` ; `deploy-{dev,one}.yml`, `reconcile{,-one}.yml` → tasks du futur `stoa_socle`. Fixe le squelette `defaults/ tasks/ handlers/ verify.yml` | — | 1-2 j |
| **2** | `stoa_vault` (tasks/auth.yml) | transverse | Extraire la section Secrets de `is-mtls-setup.yml` (chaîne `VAULT_TOKEN_FILE > VAULT_TOKEN > AppRole`, no_log, fallback) — dépendance de TOUS les rôles, à ne jamais dupliquer | — | 0.5 j |
| **3** | `stoa_vault` | B3 | `setup-vault.sh`, `setup-vault-approle.sh`, `jenkins-refresh-vault-secret.sh` (KV v2 upsert = converge, traduction `uri` mécanique) | `test-vault-rotation.sh` | 1-2 j |
| **4** | `stoa_socle` | SOCLE | `setup-ci-applier.sh` (client KC cp-applier, GET-puis-POST), paramétrage des plays deploy rolifiés en 1, seed du job Jenkins, install binaire labctl sur l'agent | `test-apply-scope.sh` (11/11) + `test-apply-audit.sh` (13/13) + `reconcile` en continu | 2-3 j |
| **5** | `stoa_multienv` + `stoa_itsm_gate` | B1+B2 | `setup-wm-admin-proxy.sh`, `setup-ci-horsprod.sh`, `setup-vault-envs.sh` ; ITSM = rôle mince (pose/valide `ITSM_URL`, le check vit dans labctl) | asserts de `demo-multienv.sh` (19/19) découpés en verify | 2-3 j |
| **6** | `stoa_integrity_gate` | B4 | quasi clos après 1 : reste `LABCTL_CLASSIFICATION_SOURCE`/`LABCTL_PROJECT` + `client_ca_alias` par projet | `test-integrity-enforce.sh` (31/31) + `test-classification-central.sh` (11/11) | 1 j |
| **7** | `stoa_gitops_project` + `stoa_onboarding` | B5+B6 | scaffolding plateforme (`stoa-platform-ci`) + gabarit repo projet (templating pur) + job Jenkins par projet ; `setup-onboarding-rbac.sh` + déploiement onboarding-api | `test-classification-central.sh` ; `test-onboarding-matrix.sh` (8/8) + ratelimit | 2-3 j |
| **8** | `stoa_user_identity`, `stoa_console`, `stoa_analytics` | B7+B8+B9 | `setup-user-vault-jwt.sh` (+ **assert fail-closed KC ≥ 26.2**, absent aujourd'hui), `setup-user-deploy-job.sh` ; build/run console + governance-api ; `wm-otel-setup.sh`, `setup-wso2-otel.sh` (porter avec leurs commentaires — quirks durement gagnés) | `test-user-vault-jwt.sh` (24/24), `test-console-user-deploy.sh` (12/12), `test-otlp-traces.sh`, `test-txn-wso2.sh` (12/12) | 4-6 j |

`site.yml` final : `ansible-playbook -i clients/<x>/inventory.ini site.yml --tags socle,vault,multienv…`
— chaque tag activable/désactivable indépendamment, chaque rôle porte son `verify`.

---

## 6. Étape 9 — convertir les preuves X/X en contrôle continu client

Les `test-*.sh` sont le meilleur actif du livrable, MAIS deux chantiers avant qu'ils tournent
ailleurs que sur le poste du lab :

1. **Dé-dockeriser les observations** : 12 scripts font `docker exec` (audit Vault lu DANS le
   conteneur `poc-vault`, `docker restart poc-wso2am`…). Remplacer par API distante
   (`sys/audit` Vault ou syslog) et `is_restart_cmd` d'inventaire.
2. **Extraire les littéraux enfouis** (pas des `${VAR:-}`) : heredocs de `test-integrity-enforce.sh`
   (`issuer: http://localhost:8480`, `adminUrl: http://localhost:9180`), `sed` du littéral
   `http://localhost:5555` dans `test-classification-central.sh` (même fragilité que le `replace`
   de `deploy-one.yml` — préférer un vrai templating), `GOV="http://localhost:…"` de
   `demo-multienv.sh`.

Tant que ce n'est pas fait : preuve de lab, pas contrôle continu. Après : `--tags verify` = la
recette contractuelle rejouable à chaque change.

---

## 7. Dette de transposabilité à résorber (backlog priorisé)

**P1 — casse la transposition (à faire pendant les étapes 0-4) :**
- `host.docker.internal` dans `ci/Jenkinsfile.rollback:42` (Docker-Desktop-only — le rollback prod ne marche sur aucun Linux).
- `/tmp/stoa-wm-admin-token` chemin FIXE partagé Jenkinsfile ↔ `envs/*/targets*.yaml` : course entre builds concurrents → chemin par-build injecté au rendu du manifeste.
- `VAULT_ROLE_ID` littéral dans les 4 Jenkinsfiles (casse à chaque re-init Vault) → credential/param Jenkins.
- `APPLY_TENANT='banking-demo'` + chemins `tenants/banking-demo/` en dur dans les 3 Jenkinsfiles → param de job.
- **governance-api sans remote Git** (`gitrepo.go` : commit/merge locaux, zéro push) alors que les pipelines clonent `governance.git` → split-brain console↔pipeline. Ajouter `GOVERNANCE_GIT_URL` + push-après-merge (ou acter le montage partagé).
- Packaging hors-compose des services maison : AUCUN systemd/Dockerfile/chart pour governance-api et onboarding-api ; HTTP clair only (`ListenAndServe`) → unit systemd + reverse-proxy TLS d'entreprise devant, à livrer dans `stoa_console`/`stoa_onboarding`.

**P2 — friction (étapes 5-8) :**
- `admin_key` APISIX dupliqué 3 fois (config.yaml / targets.yaml / scripts) → une source templatisée.
- Password OpenSearch en clair à 6+ endroits (compose, `data-prepper/pipelines.yaml`) → Vault/vars.
- Redpanda `advertise EXTERNAL://localhost:18092` → inutilisable multi-hôte ; prévoir le branchement sur le Kafka du client (déplace la conformité redaction — à cadrer).
- Console UI : issuer KC **compilé** (`ui/src/config.ts`) → config runtime (env injectée) ou rebuild par client assumé + **miroir npm offline** (le build UI n'est pas air-gapped, contrairement à Go).
- Webhook tokens en dur (`stoa-ci`, `stoa-user-deploy`) → à régénérer par client ; revalider generic-webhook-trigger contre la politique SSO/CSRF du Jenkins client (maillon le plus dépendant de la politique locale).
- Setup KC via password grant `admin/admin` sur `master` (scripts + governance-api runtime) → compte de service à permissions fines (fine-grained admin) chez le client.
- Ports BFF divergents entre scripts (8787/8791/8797/8799) → harmoniser.
- Signature Git de la governance (clé ed25519 seedée, `allowed_signers` locaux) → identité Git d'entreprise, sinon le 4-yeux perd sa valeur probante.

---

## 8. Process de livraison par client (une fois le livrable constitué)

1. **Cadrage** (2-4 j) : note de positionnement (scaffold vs produit), mapping critères durs sur le
   référentiel du client, choix des briques + degré d'automatisation par brique, checklist prérequis
   (versions wM/KC — **KC ≥ 26.2 pour B7**, plugins Jenkins `git`/`workflow-aggregator`/
   `generic-webhook-trigger`, flux réseau, comptes de service, CA/proxy).
2. **Profil client** (1-2 j) : copier `clients/_example/` → remplir `endpoints.yml` (les ~20 knobs
   obligatoires), `inventory.ini`, `environments.yaml`, seed `classifications.yaml`.
3. **Release** : binaires signés + checksums + SBOM buildés hors zone ; `git archive` du moteur
   (exclut mécaniquement tout l'untracked démo).
4. **Installation par briques** : `site.yml --tags <brique>` dans l'ordre choisi (SOCLE d'abord),
   **recette = `--tags verify` X/X après chaque brique**, signée comme critère d'acceptation.
5. **Réversibilité** : chaque brique a son OFF documenté (retirer `VAULT_ADDR`, retirer `itsmCheck`,
   retirer `deploy.{env}.yaml`, couper la console…) — l'argument comité : activer une brique
   n'engage pas la suivante.

---

*Réfs : ADR-070..077 · `ansible/README.md` (règle « en prod ce rôle vit dans stoa-infra/ansible » —
le livrable doit rester extractible du repo PoC sans réécriture) · mémoire `client-rollout-modular`.*
