---
title: "ADR-078 — Livrable self-service « création d'application » sur webMethods API Gateway 10.15, piloté par Jenkins : repo produit séparé, frontière secrets Vault/Jenkins, modèle plan/apply, identifiers app opposés (API key + certificat + plage IP)"
sidebar_label: "ADR-078 : livrable self-service application (wM 10.15)"
status: "Proposé — cadre la V1 du livrable client à partir du PoC ; décisions client en attente (§ Décisions à trancher)"
maturite_technique: "◐ Partiellement prouvé — identifiers cert/IP/API-key opposés live sur la 10.15 réelle (spike 2026-07-14, 8/8, gateway restaurée) ; DEUX fail-open natifs découverts (ipAllowlist décoratif, TTL de clé global) ; frontière secrets et modèle plan/apply étayés par doc éditeur (recherche 2026-07-14, 21 claims vérifiés 3-votes) ; repo produit NON encore extrait"
date: 2026-07-15
adr_number: 78
visibility: private
note: "Privé (stoa-labs). Répond au GOAL-self-service-api-app-2026-07-09 (volet CONSOMMATEUR, feeds_adr: 78). S'appuie sur ADR-071 (onboarding-as-code), ADR-074 (Vault), ADR-075 (multi-env), ADR-076 (GitOps lifecycle), ADR-077 (identité user→Vault). Contexte client bancaire on-premise — ne pas porter dans stoa-docs (public)."
---

# ADR-078 — Livrable self-service « création d'application » (wM 10.15, Jenkins)

**Statut :** Proposé — cadre la V1 du livrable ; décisions identité (LDAP) et agents (K8s éphémères) **actées le 2026-07-15** ; **voie A (user/mot de passe → Vault) LIVRÉE ET PROUVÉE le 2026-07-22 (34/34 + E2E Jenkins)** ; restent la localisation de l'API key backend et 6 questions ouvertes par la mise en œuvre (§ Décisions client).
**Maturité technique :** ◐ Partiellement prouvé.
- ✅ **Prouvé live** (spike 2026-07-14, `apigateway-trial:10.15` réelle, API + app jetables créées puis supprimées, gateway restaurée 8 APIs / 3 apps intactes) : les trois identifiers d'application (**API key**, **certificat x509**, **plage IP**) sont **opposables** — refus effectif d'une IP hors plage (403), d'un appel sans/mauvaise API key (401), et binding cert au truststore (ADR-071).
- 🔴 **Deux fail-open natifs découverts** au même spike (voir § Écarts) : l'identifier IP **ne filtre RIEN sans règle d'identification IAM** (que `labctl` ne pose pas aujourd'hui → `ipAllowlist` **décoratif**) ; l'expiration de l'API key est un réglage **global de la gateway**, pas par application (poser un TTL par app renvoie 200 mais n'est pas persisté).
- ✅ **Étayé doc éditeur** (recherche 2026-07-14, 103 agents, 21 claims vérifiés en 3-votes adversariaux) : frontière secrets Vault/Jenkins, impossibilité d'un token Vault nominatif via les plugins Jenkins standards, contrainte mécanique du webhook (ACL.SYSTEM).
- ⚠️ **Non encore fait** : extraction du repo produit ; fermeture des deux fail-open ; endpoint de régénération de clé (contrat non trouvé).

**Contexte client (anonymisé) :** banque on-premise. Le PoC de fédération multi-gateway doit devenir un **livrable évolutif** installable et maintenable chez un client, **sans perdre le lab** (bac à sable 4 gateways pour d'autres use cases). La V1 cible **uniquement webMethods API Gateway 10.15**, un seul use case : le **self-service de création d'application consommatrice** via Jenkins, avec **certificat**, **filtrage IP** et **API key** comme identité applicative. **Vault est disponible et gouverné** chez le client. L'**identité de l'utilisateur** (login user/mot de passe dans Jenkins) sert **uniquement** à obtenir un **token Vault nominatif** ; les appels vers webMethods se font avec un **compte de service** dont les credentials sont lus dans Vault — **l'identité user n'est jamais propagée à la gateway**.

**Lié à :** [[adr-071-partner-onboarding-as-code]], [[adr-074-vault-secrets]], [[adr-075-wm-admin-proxy-multienv]], [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-077-user-identity-to-vault-token-exchange]].

> ⚠️ **Confidentialité.** Architecture de livraison et modèle secrets d'une banque. Vit dans `stoa-labs` (privé), **pas** dans `stoa-docs`.

---

## Décision (test « archi 40 ans / 30 secondes »)

> On **extrait un repo produit** distinct du lab (flux **unidirectionnel lab → produit**, jamais l'inverse), parce que l'historique Git du PoC est **structurellement inéligible** à une livraison bancaire (secrets de démo, binaire purgé) — un `git archive` ne répare pas un historique. Le produit reçoit le **moteur** (`labctl` cœur + adapter wM + rôles Ansible + `clients/_example`), son propre SemVer, sa branch protection, ses releases signées (`make release` existe déjà, É0 levé 18/18).
> La **frontière secrets** suit la doctrine HashiCorp. Les **agents Jenkins étant K8s éphémères** (décidé), l'identité de job passe par **Vault Kubernetes auth** (token de ServiceAccount du pod) : **aucun secret d'amorçage Vault dans Jenkins**. Vault détient le compte de service gateway, les clés privées, l'API key du backend. On **n'adopte pas** le plugin Vault (6 advisories) — appel REST direct.
> Le **webhook ne peut pas porter d'identité humaine** (contrainte mécanique : un build déclenché sans humain tourne en `ACL.SYSTEM` et ne résout aucun credential user-scoped). D'où le modèle **plan/apply** : webhook → **plan** lecture seule sous identité de **job** (K8s auth) ; **apply** (écriture wM, secrets lus dans Vault sous **token LDAP nominatif** — voie A) déclenché par un **humain** (build paramétré), seul moment où l'identité nominative existe.
> Le **self-service applicatif** sépare **deux plans** : (a) **identité ENTRANTE** du consommateur — `httpsCertificate` + `ipAddressRange` **opposés** via une action IAM `AND`=f(classification) (un identifier seul ne filtre rien : il faut la règle d'identification) ; (b) **API key du BACKEND** portée par l'identifier `token` de l'app et **injectée en header sortant** par le TokenProvider Vault-backed (la « clé » du client est celle de l'amont, jamais une identité entrante).
>
> **Test** : *un demandeur peut-il obtenir une application dont le consommateur est identifié (cert+IP, réellement opposés) et dont les appels portent l'API key du backend injectée depuis Vault, par un pipeline Jenkins, sans qu'aucun secret réutilisable ne traîne, sans qu'un déploiement non déclenché par un humain identifié n'écrive sur la gateway, et sans qu'un contrôle annoncé (« filtrage IP ») soit en réalité inopposé ?* Si l'une de ces réponses n'est pas « non, mécaniquement », le livrable **promet plus qu'il n'enforce**.

---

## Contexte et problème

Le PoC prouve la faisabilité ; il n'est **pas** un livrable. Quatre écarts le séparent d'un produit bancaire, chacun tranché ci-dessous :

1. **Où vit le produit ?** Le repo `stoa-labs` mêle 4 gateways, des mocks, des secrets de démo et un historique déjà pollué (binaire governance-api de 10 Mo purgé le 2026-07-09). On ne remet pas cet historique à une banque.
2. **Où vivent les secrets ?** Le PoC lit déjà Vault en `curl` REST direct (ADR-074) mais garde un SecretID AppRole **long-lived** dans Jenkins et un RoleID **en dur** dans 4 Jenkinsfiles — l'anti-pattern que HashiCorp nomme explicitement.
3. **Qui déclenche, sous quelle identité ?** La contrainte « identité user → Vault seulement » (ADR-077) entre en collision frontale avec le déclenchement par webhook : *personne* ne s'authentifie sur un push.
4. **Que sait vraiment faire la 10.15 ?** Les identifiers API key / cert / IP existent dans l'enum de la gateway, mais leur **opposabilité réelle** (filtrent-ils, ou identifient-ils ?) n'était pas prouvée — et le spike a révélé qu'`ipAllowlist` était jusqu'ici **écrit sans être opposé**.

---

## Options considérées — stratégie de repo

> ⚠️ La recherche web n'a produit **aucun** retour d'expérience vérifié sur la productisation d'un PoC interne (aucune source n'a survécu à la vérification 3-votes). Ce qui suit est un **jugement d'ingénierie**, pas un fait sourcé — signalé comme tel.

| Option | Description | Verdict |
|---|---|---|
| **A. Monorepo, dossiers `product/` + `lab/`** | Une seule base, deux racines | ✘ L'historique reste partagé — la pollution démo voyage avec le produit ; branch protection et SemVer indistincts |
| **B. Fork bidirectionnel** | Produit = fork du lab, cherry-pick dans les deux sens | ✘✘ **Le piège** : le drift devient ingérable dès que les deux évoluent ; à proscrire |
| **C. ★ Repo produit séparé, flux `lab → produit` unidirectionnel** | Le lab reste le bac à sable ; le produit reçoit le moteur par **extraction** (jamais de retour) | ✅ Historique propre, SemVer propre, gouvernance propre ; coût = discipline d'extraction |
| **D. Extraction en librairie Go partagée** | Le cœur `labctl` devient un module importé par lab ET produit | ◐ Idéal à terme (zéro double maintenance) ; **prématuré** en V1 (le cœur n'est pas encore stabilisé) — cible, pas point de départ |

**Retenu : C, avec D en cible.** L'argument décisif n'est ni le SemVer ni le monorepo-vs-polyrepo : c'est que **l'historique du PoC est inéligible** à une livraison bancaire, et qu'un `git archive` (ce que prévoyait `DELIVERY-PROCESS.md`) copie l'arbre mais **pas** l'historique — or la branch protection, le 4-yeux et l'audit d'un livrable bancaire vivent *dans* l'historique. Corollaire de calendrier : le **coût d'extraction est minimal maintenant** (V1 mono-gateway, mono-fonction) ; il croît à chaque mois d'intrication.

---

## Décision retenue

### 1. Repo produit — extraction unidirectionnelle

Nouveau repo (nom proposé : `stoa-apim-delivery`), reçoit **le moteur** au sens `DELIVERY-PROCESS.md` :
`labctl` cœur + `internal/adapter/webmethods` + rôles Ansible + contrat allowlist `wm-admin-proxy.openapi.yaml` + gabarit `clients/_example` + ADR pertinents. **Ne reçoit jamais** : `mocks/`, `docker-compose.{poc,envs,wm,ci}.yml`, Dex/Microcks, `labctl-credentials.txt`, instances pilotes, docs internes (liste « ne part JAMAIS » de `DELIVERY-PROCESS.md`).

- **Sens unique** : le lab peut piocher dans le produit ; le produit ne réimporte jamais depuis le lab (pas de cherry-pick retour). Une amélioration du cœur validée au lab est **portée** vers le produit par un commit d'extraction, tracé.
- **SemVer produit** propre, indépendant du lab. Releases signées + `SHA256SUMS` + SBOM SPDX (`make release`, déjà livré, multi-arch, hors zone).
- **Branch protection + commits signés** dès l'init (le 4-yeux perd sa valeur probante sans identité Git d'entreprise — dette P2 connue).

### 2. Frontière des secrets — Jenkins amorce, Vault détient

**Décidé (2026-07-15) : agents Jenkins = Kubernetes, éphémères** — un pod jetable par build. Ça change l'identité **de job** : on passe de l'AppRole (« Moderate » dans le classement HashiCorp, et qui exige un broker de SecretID en response wrapping) à **Vault Kubernetes auth** (« Highest for in-cluster ») — le pod s'authentifie à Vault avec **son propre token de ServiceAccount K8s**, projeté par le kubelet, jamais stocké. **Conséquence forte : plus AUCUN secret d'amorçage Vault dans le Jenkins Credentials Store** (ni RoleID, ni SecretID, ni broker). Le problème « secret zero » disparaît pour le chemin de job.

| Vit dans **Jenkins Credentials** (amorçage résiduel) | Vit dans **Vault** (lu à l'exécution) |
|---|---|
| **Credentials Git** (`GIT_CREDENTIALS_ID`, déjà en place) | **Credentials du compte de service webMethods** (Basic admin REST) |
| **CA d'entreprise** (`LABCTL_CA_FILE` / `VAULT_CACERT`, déjà en place) | **Clés privées** (certificats mTLS), **API key du backend** (§5) |
| *(voie A, apply)* mot de passe LDAP **saisi au build**, jamais persisté | secrets OpenSearch/ITSM ; tout secret réutilisable |

- **Identité de JOB (plan)** = Vault **Kubernetes auth** (ServiceAccount du pod) → policy en lecture seule.
- **Identité NOMINATIVE (apply)** = Vault **LDAP** (voie A, §3) → policy scopée à l'utilisateur.
- **AppRole devient le *fallback*** pour un client dont les agents ne seraient PAS sur K8s (VM/bare-metal) ; dans ce cas seulement, l'invariant s'applique : le SecretID doit être livré en **response wrapping** (usage unique), *jamais* posé en credential long-lived, et le type de credential « AppRole » du plugin Jenkins le **viole par construction** (il stocke RoleID+SecretID ensemble).

**Décision d'architecture explicite (contre-intuitive, à écrire noir sur blanc) :** on **reste sur `curl` REST direct vers Vault**, on **n'adopte PAS** le plugin HashiCorp Vault. Le plugin cumule 6 advisories dont deux échecs de masquage (CVE-2022-23110 : fuite de credentials Vault dans les logs de build ; CVE-2025-67642 / SECURITY-3045, *sans correctif à publication le 2025-12-10*). L'appel REST direct y échappe. Ce choix **a l'air** d'une régression ; c'en est l'inverse.

**Rappel de modèle de confiance (à porter au comité) :** le Jenkins Credentials Store **n'est pas une frontière de confinement**. Le masquage des logs est « trivialement contournable » (doc credentials-binding, verbatim) et ne couvre que la fuite *accidentelle* ; un binaire custom (`labctl`) appelant Vault ne bénéficie d'**aucun** masquage automatique ; un secret fuit entre builds concurrents du même nœud via `ps e` / `/proc/<pid>/environ`. Ce que Vault apporte n'est donc **pas** du confinement mais : **réduction du blast radius**, **TTL/rotation**, et **audit indépendant de Jenkins**. Les **agents K8s éphémères** ferment aussi la fuite `ps e` (un pod = un build = un UID isolé), ce qui rend la voie A (mot de passe LDAP en param) acceptable.

**Dette résorbée par la décision K8s :** `VAULT_ROLE_ID` littéral dans les 4 Jenkinsfiles et `vault-ci-secret-id` long-lived (dette P1) **disparaissent** — remplacés par l'auth Kubernetes. À reporter sur le fallback AppRole uniquement.

### 3. Identité user → Vault — deux voies, la contrainte « user/pwd Jenkins » tranche

Résultat de recherche **tranchant** (3-0) : un token Vault **nominatif** est **impossible** via les plugins Jenkins standards — le plugin Vault n'a aucun backend d'identité humaine (la PR LDAP a été fermée sans merge), et le plugin OIDC Provider émet un token dont le `sub` est **l'URL du job** (identité de machine + usurpation CVE-2025-47884). La seule voie viable est un **JWT porteur du sujet humain obtenu HORS Jenkins**, présenté à un rôle Vault `role_type=jwt` (`role_type=oidc` exige un navigateur → inutilisable en agent headless).

Deux implémentations, **au choix du client** (§ Décisions à trancher) :

| Voie | Mécanique | Compromis |
|---|---|---|
| **A — Vault LDAP, mot de passe en paramètre de build** | `password parameter` Jenkins → `POST /v1/auth/ldap/login/<user>` en REST → token Vault nominatif → `revoke-self` en fin de build | Colle **littéralement** à « user/pwd dans Jenkins ». Le mot de passe transite par Jenkins (`build.xml`) et fuit entre builds concurrents (`ps e`) → **agents éphémères impératifs** |
| **B — ADR-077 (Console OIDC → exchange RFC 8693 → JWT `aud=vault`)** | **Déjà prouvé 24/24**, zéro credential stocké côté CI, tenant-scopé | Exige Jenkins/Console en **SSO Keycloak** — ce n'est plus « user/pwd dans Jenkins » ; KC ≥ 26.2 |

**Décidé (2026-07-15) : voie A pour la V1** (Vault LDAP, mot de passe saisi au build ; endpoint REST standard, colle à la demande client) ; **B en cible** quand le SSO Keycloak sera en place. **✅ LIVRÉE ET PROUVÉE le 2026-07-22** — `scripts/test-vault-user-login.sh` **34/34** + build Jenkins E2E vert (mot de passe en paramètre → token `ldap-alice` → rôle Ansible `ok=49 failed=0` + verify `ok=32 failed=0` → révocation prouvée). Détails ci-dessous. `revoke-self` **vérifié** en fin de build (`lookup-self` → 403 : la durée de vie du token = le build) — le job `setup-user-deploy-job.sh` le fait déjà. La fuite `ps e` du mot de passe est fermée par les **agents K8s éphémères** (§2, un pod par build).

#### Voie A — ce que la mise en œuvre a appris (2026-07-22)

Le login vit dans **une seule implémentation**, `ci/lib/vault-login.sh`, sourcée par
les pipelines : le shell obtient le token nominatif une fois et exporte
`VAULT_TOKEN_FILE`, que les rôles Ansible et `labctl` consomment déjà en tête de
précédence. Les blocs de login des rôles sont alors *skippés* — une seule surface
d'auth à auditer au lieu de trois. Le mount est un knob (`VAULT_USER_AUTH_MOUNT`),
donc `auth/ldap` chez le client et `auth/userpass` en lab exécutent **le même code**.

Quatre constats non anticipés, tous issus du live :

1. **Le format de login contraint le backend d'auth.** `auth/userpass` **refuse** `@`
   et `\` dans un username — son pattern de path est `GenericNameRegex` (`\w`, `-`,
   `.`) : `users/alice@corp.example` → 404 *unsupported path*, `login/CORP\alice` →
   500 *failed to determine alias name*. `auth/ldap` les accepte (pattern `.+`),
   vérifié contre un annuaire réel pour UPN **et** `DOMAIN\user`. Un `userpass` de
   secours (compte break-glass local) ne peut donc **pas** porter les comptes
   d'entreprise. → question client n°3.

2. **La ségrégation par tenant change de mécanisme.** ADR-077 la fait par policy
   **templatée** sur le claim `tenant` du JWT. En user/mot de passe il n'y a pas de
   claim : la policy est attachée au **groupe d'annuaire**
   (`auth/ldap/groups/apim-deploy-<tenant>` → `deploy-<tenant>`). Conséquence à porter
   au client : il faut **un groupe AD par tenant**, et l'annuaire — plus le pipeline —
   devient la source de vérité de « qui déploie pour qui ». Prouvé : alice hérite
   `deploy-banking-demo` de son groupe, cross-tenant refusé 403 dans les deux sens, un
   groupe non mappé (carol) s'authentifie sans pouvoir lire le moindre périmètre.

3. **Le `revoke` de fin de bloc était structurellement sauté.** Dans les Jenkinsfile
   d'origine, `revoke-self` était la dernière instruction sous `set -e` : dès qu'un
   `ansible-playbook` échouait, l'exécution s'arrêtait avant, et **le token nominatif
   survivait jusqu'à son TTL** — précisément dans le cas où l'on veut le tuer. Le
   revoke est désormais dans un `trap … EXIT` armé *avant* le login, avec preuve de
   mort (`lookup-self` → 403) et préservation du code de sortie. Contre-épreuve au
   test (T20/T21).

4. **Le step `sh` de Jenkins est `/bin/sh`, pas bash** (dash sur Debian, ash sur
   Alpine). La lib est donc POSIX stricte — la première version, en bash avec des
   tableaux, échouait par erreur de syntaxe au premier build réel.

Invariants de secret, chacun avec sa contre-épreuve : le mot de passe et le token ne
passent jamais en argv (`ps` échantillonné pendant le login), le corps JSON est produit
par `json.dumps` et non forgé en shell (prouvé avec un mot de passe contenant
`" \ $ ' ; & {}`), le user part URL-encodé, le token part par fichier d'en-têtes, le
mot de passe est `unset` avant `ansible-playbook` (le process fils ne l'hérite pas),
et l'audit Vault ne contient aucun mot de passe en clair.

**`Jenkinsfile.prod` et `.rollback` — câblés avec repli AppRole (2026-07-22).** Ces
deux pipelines sont *manuels par construction* (« PAS de triggers : prod ne part
JAMAIS d'un webhook »), donc ce sont les meilleurs candidats à l'identité nominative :
un acte de mise en prod devrait être imputable à quelqu'un. Ils utilisent
`vault_login_any` — nominatif si l'opérateur saisit `VAULT_USER` + son mot de passe,
**repli AppRole sinon**, comportement historique inchangé. Le repli **s'annonce** dans
le log (« identité NON NOMINATIVE (AppRole) : cet acte n'est imputable à AUCUN
humain ») : un journal de prod qui ne distingue pas l'acte d'un humain de celui d'une
machine ruine l'imputabilité recherchée.

Leur périmètre de secrets **diffère** de celui des déployeurs de tenant : ils lisent
`stoa/ci`, `stoa/opensearch`, `stoa/gateways/*`, hors de toute policy
`deploy-<tenant>`. D'où une policy **`operator-deploy`** distincte, portée par un
**groupe d'annuaire séparé** (`apim-operator-prod`) — de sorte que les deux périmètres
sont **disjoints dans les deux sens**, ce qui est prouvé (T30-T33) : un opérateur de
prod n'accède pas aux périmètres des tenants, et un déployeur de tenant n'accède pas
aux secrets de plateforme. **Qu'un humain ait le droit de lire les secrets de service
reste une décision client** (§ Décisions n°9) : le lab l'accorde à un compte dédié
pour que la question demeure visible plutôt que diluée.

Deux durcissements au passage, sur du code qui existait déjà : les lectures Vault
passent par `vault_read` (token en fichier d'en-têtes au lieu de
`-H "X-Vault-Token: $TOK"` en argv, et parse JSON au lieu d'un `sed` qui casse dès
qu'un champ contient une quote), et le `client_secret` du compte de service part par
le **corps** de la requête via `form_post_no_argv` au lieu d'un `-d client_secret=…`
visible dans `ps`.

**Re-prouvé le 2026-07-23** : chaîne ADR-075 rejouée **22/22** (`demo-multienv.sh`,
après réparation de la gateway — cf. `scripts/repair-wm-dangling-policyaction.sh` :
NPE de PUT/ACTIVATE causé par une policyAction IAM SUPPRIMÉE mais encore référencée
par 6 policies, réparé par excision REST + re-apply depuis Git, zéro suppression
d'API) ; puis les VRAIS jobs Jenkins sur la branche : `stoa-prod-deploy` **SUCCESS
×2** (repli AppRole annoncé « non imputable », puis NOMINATIF `ldap-oscar` policy
`operator-deploy`) et `stoa-prod-rollback` **SUCCESS ×2** (AppRole puis NOMINATIF,
les deux stages) — revert commité et **poussé** par governance-api
(`GOVERNANCE_GIT_PUSH_REMOTE`, ferme la dette P1 « sans push Git »), re-clone,
re-apply `ACCEPT`, promotion `rolled_back`, mot de passe absent des logs (0
occurrence). Contrainte de lab découverte : le keepalive trial recycle la gateway
toutes les ~20 min (`WM_MAX_MIN=20`, cron `*/5`) — un build qui chevauche le seuil
est coupé ; lancer les jobs longs juste après un cycle.

**Traçabilité réellement obtenue (à documenter honnêtement) :** le `user_claim` du rôle Vault devient le nom de l'entity alias, l'`entity_id` est journalisé → **piste nominative DANS Vault**. Mais les appels gateway partant sous le compte de service, **webMethods ne verra jamais l'humain** : l'imputabilité de bout en bout n'existe **que par corrélation** (audit Vault ↔ log Jenkins ↔ audit gateway). ⇒ **injecter un identifiant de corrélation** dans les trois journaux.

### 4. Déclenchement — modèle plan/apply

Contrainte **mécanique** (3-0, doc CloudBees verbatim) : un build déclenché par webhook/SCM/timer tourne en `ACL.SYSTEM` et **ne peut pas** lire de credential user-scoped (JENKINS-44772 toujours ouvert). Donc :

```
  push / PR ──webhook──▶  PLAN   (identité de JOB : Vault K8s auth du pod ; LECTURE SEULE)
                          lint · validate · render (classification→policies) · dry-run · diff
                                     │
                          humain ────▼──── build paramétré (voie A : mot de passe LDAP)
                                    APPLY  (identité NOMINATIVE ; token Vault LDAP nominatif)
                                    labctl provisionne l'Application wM (compte de service ← Vault)
```

- Le **plan** réutilise `labctl plan` / `validate` / `render` (déjà livrés) — aucun secret d'écriture requis.
- L'**apply** est le **seul** point où un token Vault nominatif existe. La chaîne ADR-077 se place **ICI, jamais sur le webhook**.
- **Piège que le plan/apply ne résout PAS** : quiconque édite le Jenkinsfile pilote aussi bien l'identité de job (K8s auth) que le token nominatif de l'apply. Le contrôle réel = **qui peut merger** (branch protection) + **Jenkinsfile SORTI du repo applicatif** (shared library versionnée, non modifiable par le demandeur d'application). Les gardes existent déjà en esprit dans le repo : `Jenkinsfile.prod` porte `// PAS de triggers {} : prod ne part JAMAIS d'un webhook`.
- L'attribution par auteur de commit est **rejetée** (auto-déclarée, usurpable sans signature vérifiée côté serveur).

### 5. Projection wM — deux plans distincts : identité ENTRANTE (cert + IP) et API key backend SORTANTE

**Clarification client (2026-07-15) — l'« API Key » n'est PAS l'identité entrante du consommateur.** C'est un **secret du backend** (la clé que le service en amont attend). Le modèle est donc à **deux plans**, à ne jamais confondre :

**(a) Plan ENTRANT — identifier le consommateur (opposable).** L'Application wM porte des identifiers ; **un identifier seul ne filtre rien** — l'opposabilité vient de la **règle d'identification** dans l'action IAM (`evaluatePolicy`, `allowAnonymous=false`, `IdentificationRule{applicationLookup=strict, identificationType=<type>}`). La V1 identifie le consommateur par **certificat + plage IP** :

| Identité entrante | Identifier wM | État code | Règle IAM à poser |
|---|---|---|---|
| Certificat x509 / mTLS | `httpsCertificate` (DER base64, truststore d'abord) | ✅ Livré (ADR-071, `identifiers.go`/`mtls.go`) | `strict/httpsCertificate` (déjà en `AND` mTLS) |
| Filtrage IP | `ipAddressRange` (plage `a-b`) | 🔴 Identifier écrit, **règle NON posée** (fail-open) | `strict/ipAddressRange` — **à ajouter** |

Connecteur `AND` (jamais `OR` : *n'importe lequel suffit* = régression inacceptable en banque), dérivé de la classification (VH → `AND` ; M → identifiant unique). Le patron `AND` existe déjà dans `mtls.go` — on le **généralise** (aligné `classification → required_policies` d'ADR-076).

**(b) Plan SORTANT — injecter l'API key du backend.** Une policy de **Request Transformation** (`customHttpHeaders`, stage `routing`) injecte un header vers l'amont. **Prouvé live (spike 2026-07-15, vers `wm-token-echo` qui renvoie les headers reçus)** : `customHttpHeaders` pose bien un header sortant (littéral arrivé au backend).

> 🔴 **Finding décisif du spike — un identifier stocké N'EST PAS lisible par la transformation.** Testé exhaustivement : `${application.identifier.token}`, `${application.id/name}`, `${sys:application_*}`, etc. → **tous droppés/non résolus**. Aucune variable de contexte application n'est exposée à `customHttpHeaders`. Les **seules** formes qui résolvent dans `headerValue` sont : un **littéral**, un **`${alias}`** (statique, par API/env), et **`${request.headers.<X>}`** (recopie d'un header **entrant** — prouvé : `${request.headers.token}` → la valeur présentée par le client arrive au backend). *Il n'existe donc PAS de chemin natif « valeur d'identifier stocké → header sortant ».*

**Conséquence : deux patterns viables, et la « clé stockée comme identifier `token` » n'est PAS un mécanisme natif à elle seule.**

| Pattern | Mécanique | Où vit la clé | Le client la connaît-il ? |
|---|---|---|---|
| **P-recopie** | le client présente la clé en header entrant → `customHttpHeaders` la recopie vers l'amont | présentée par le client (et sur l'app si servant à l'identification) | **Oui** — le consommateur détient la clé backend |
| **P-alias** | clé stockée en `${alias}` gateway, injectée par API | data-store gateway (alias), **1 clé par API/env**, pas par consommateur | Non, mais pas de granularité par app |
| **★ P-callout (TokenProvider)** | callout Invoke-IS (ADR-076 §82) lit la vraie clé **dans Vault** et pose une var de contexte → `customHttpHeaders` l'injecte | **Vault** (par profil/consommateur), invalidé sur 401 | **Non** — clé cachée du client |

**Recommandation : P-callout (TokenProvider Vault-backed)** — seul pattern qui met la clé **par consommateur dans Vault** (cohérent §2), cachée du client, rotée dans Vault. Il **existe déjà** dans le repo (câblé à la main → cible : projeté as-code par `labctl`). L'identifier `token` de l'app sert alors de **handle/profil non-secret** (pas de secret sur la gateway). *P-recopie* n'est acceptable que si le client est **légitimement porteur** de la clé backend (à valider avec la sécurité) ; *P-alias* si une clé unique par API suffit.

> ⚠️ **Correction :** l'entrée « Identité = API Key / `apiAccessKey` / `strict/apiKey` » d'une version antérieure est **abandonnée** (elle décrivait la clé *entrante* gateway, hors périmètre client). Le spike du 2026-07-14 reste conservé comme preuve d'opposabilité si un usage futur en veut une.

### 6. Multi-environnement — identité par env, endpoint d'admin unique

L'IP source, le certificat client et la clé backend **diffèrent par env** ; l'identité de l'app/API (name/api/enforce) est **invariante**. Décision : le manifeste porte l'invariant à la racine + un bloc **`per_env: {dev,rec,int,prod}`** ; chaque rôle calcule le manifeste **effectif = racine ⊕ per_env[env]** (fusion récursive, `tasks/resolve-env.yml`), **fail-closed** si l'env n'est pas déclaré (`ENV_UNDEFINED`). L'API d'admin reste un **endpoint proxy unique** : le header `X-Environment` route (pas de base par env). La clé backend reste `${backend_apikey}` (template invariant), résolue par env par le TokenProvider ← Vault de l'env. **Piège tranché :** le manifeste se charge par **chemin** (`-e apim_ss_manifest` → `include_vars`, précédence 18) et **jamais** `-e @fichier` (extra-var 22 : masquerait le `set_fact` de fusion, surcharge `per_env` perdue en silence). *Prouvé live 2026-07-15 : consommateur dev→prod bascule l'identifier IP, producteur dev matérialise l'issuer sur l'alias, env inconnu refusé.*

### 7. Lifecycle — mise à jour et préservation

**Mise à jour d'une API existante** : create-only par défaut (pas de re-déploiement surprise) ; `apim_api.update: true` ⇒ **deactivate → PUT `/apis/{id}` multipart → activate** (le PUT est **refusé — 400 — sur une API active**, prouvé live ; brève coupure data-plane assumée). *Piège Jinja épinglé : `apim_api['update']` et non `apim_api.update` (collision avec la méthode `update()` du dict → sinon skip silencieux).*

**Mise à jour d'une application** (IP/cert) : read-modify-write **déclaratif**, mais le rôle ne remplace QUE les dimensions **déclarées par le manifeste** — un `httpsCertificate` posé **hors manifeste** (par l'UI, p. ex. par un admin) quand `public_cert_ref` est vide est **préservé** au re-run (prouvé live), au lieu d'être effacé.

**Nommage daté + rotation du certificat (demande client, prouvé live 7/7 — `scripts/test-cert-rotation.sh`).** Le `name` de l'identifier `httpsCertificate` (champ **persisté**, prouvé par la trace UI de l'écart n°5, **sans rôle runtime** — le matching se fait sur la valeur) porte la **date GMT du NotAfter** : `"<app|cert_name_prefix>-exp-YYYYMMDD"` — les scans d'exploitation du client lisent `-exp-[0-9]{8}` pour repérer les certs expirés. **Fail-closed `CERT_EXPIRED`** : un cert expiré (ou sous `apim_ss_cert_min_days_left` jours) est **refusé** (identité morte = fail silencieux garanti au handshake). **Rotation** par `cert_rotation` : `replace` (défaut — la valeur du manifeste remplace la dimension) ou **`overlap`** (fenêtre de chevauchement : le nouveau cert s'**ajoute** aux valeurs existantes **encore valides** — l'identifier porte un **tableau de valeurs**, c'est le multi-certs de l'UI — et les valeurs **expirées/illisibles sont purgées** à chaque run ; nom multi-dates trié `-exp-YYYYMMDD+YYYYMMDD`). L'identité d'un cert = sa **valeur** base64(DER) (dédup par valeur ⇒ **double-run idempotent**) ; le nom est **recalculé** déterministiquement depuis les valeurs retenues. Read-back `CERT_NAME_CONFIRMED` au verify. *(La préservation reste utile — un cert peut légitimement être posé par l'UI —, mais elle n'est plus un palliatif : depuis le spike 2026-07-17, le cert est posable à 100 % en REST. L'UI et le REST déposent les **mêmes octets** `base64(DER)` ; « le binaire n'est possible que par l'UI » était **faux** — cf. écart n°5.)*

### 8. Port en Deny-by-Default — allow-list de l'API (IS-admin)

Chez le client, le **port data-plane est en Deny-by-Default** : chaque API publiée doit être **ajoutée à l'allow-list du port**. C'est l'**Access Mode du listener Integration Server** — surface **différente** de l'API d'admin apigateway (le REST `/ports` ne l'expose pas), pilotée par le form WmRoot `security-ports-editaccess.dsp`. Décision : `tasks/port-access.yml` (opt-in `apim_ss_port_manage`, après l'activate) fait **read → add idempotent → read-back fail-closed** (`PORT_ALLOWLIST_CONFIRMED`) ; play standalone `is-port-access.yml` pour la création d'env. **Le rôle ne FLIPPE JAMAIS le mode** (risque de lockout du data-plane) : le passage en Deny est fait à la création de l'env côté client. *Prouvé live 2026-07-15 : POST addNode/deleteNode + read-back basic-auth sans CSRF.* **Caveats** (§ Écarts) : allow-list par **service IS `folder:service`** (le port rejette les URLs data-plane — testé), mapping API→service = config gateway du client ; **CSRF guard** OFF sur le trial (à gérer si activé côté client).

---

## Preuves de spike (2026-07-14, `apigateway-trial:10.15` réelle)

API + application **jetables**, créées puis **supprimées** ; gateway restaurée (8 APIs, 3 apps, action IAM `labctl` intactes). Détail des shapes REST consigné dans la mémoire projet `wm-1015-rest-shapes`.

**Filtrage IP — 4/4 :**

| Cas | Configuration | Résultat |
|---|---|---|
| A | identifier `ipAddressRange` posé, **aucune policy IAM** | **200** (passe — l'identifier seul n'oppose rien) |
| B | policy `strict/ipAddressRange`, aucune application | **403** (identification exigée) |
| C | application dont la plage **contient** l'IP appelante | **200** |
| D | application dont la plage **exclut** l'IP appelante | **403** ✅ **filtrage prouvé** |

**API Key entrante — opposable (mais HORS périmètre V1) :** sans clé → **401** ; header `x-Gateway-APIKey: <clé>` → **200** ; **clé bidon → 401** ✅. (Header legacy `x-CentraSite-APIKey` **aussi** accepté.) *Conservé comme preuve : la clé entrante gateway est opposable si on en veut un jour ; la V1 ne l'utilise pas — l'API key du client est celle du **backend**, injectée en sortie (§ décision 5b).*

---

## Écarts d'enforcement connus (à combler avant promesse client)

1. **◐ `ipAllowlist` décoratif (fail-open silencieux) — EN COURS DE FERMETURE.** `labctl` écrivait l'identifier `ipAddressRange` sur l'application mais ne posait **jamais** de règle IAM par IP (`wantMode()` ne produit que `oAuth2Token`/`jwtClaims`, + `AND httpsCertificate` en mTLS) : l'`ipAllowlist` était **stocké mais inopposé** — un fail-open. **Landé (2026-07-15, Go, testé)** : la primitive `identifyAndActionBody` (AND de dimensions arbitraires, généralise le patron mTLS) + `normalizeIPRange` (single → `X-X`, CIDR → `first-last` : la gateway jette le CIDR en silence et l'UI n'affiche pas une IP nue — prouvé live). **Reste** : `ensureSelfServiceIdentify` (poser+attacher la règle AND(cert,IP) sur la policy de l'API, idempotent) + le driver, puis la preuve X/X reproduisant la matrice A-D.
   - ⚠️ Détail IP prouvé : une IP **nue** est un match **EXACT** au runtime (`["0.0.0.0"]` refuse une autre IP → 403, donc **pas** un from→∞) ; plusieurs IP = liste (OR) ; `A-B` = range. Le CIDR est **silencieusement ignoré** (PUT no-op) → converti en range par `normalizeIPRange`.

2. **🔴 Rotation de l'API key BACKEND — dans Vault, pas sur la gateway.** L'API key du client étant celle du **backend** (§5b), sa rotation vit **dans Vault** (option b1) : job de rotation + ré-écriture du secret, le TokenProvider relit à l'exécution. **Ne PAS s'appuyer sur le TTL natif de la clé entrante gateway** : le spike a montré que `apiKeyExpirationPeriod` est **global** (extended setting de toute la gateway, `PUT /configurations/settings` + enveloppe `preferredSettings`) et que le bloc `accessTokens` de l'app est **read-only au PUT** (poser un `expirationInterval` par app renvoie 200 mais n'est pas persisté — no-op silencieux). Ce natif ne sert de toute façon **pas** la V1 (clé entrante non utilisée).

3. **⚠️ Régénération de la clé entrante — contrat non trouvé (non bloquant V1).** `POST /applications/{id}/accessTokens` rejette toutes les valeurs de `type` (400) ; `POST /applications/{id}/apiAccessKey` → 404. Sans objet pour la V1 (pas de clé entrante), mais à épingler par trace réseau de l'UI si un use case futur en a besoin.

4. **🔴 `/applications` non cloisonné par team (rappel spike #1).** Delete cross-team → 204, register d'une API invisible → 201. Pour un self-service **multi-équipes bancaire**, c'est bloquant. Les **gardes applicatives** (E3 du GOAL : `owner`/`register`/oracle) ne sont **pas optionnelles** dans le livrable — condition de vendabilité.

5. **✅ Certificat client de l'app = 100 % REST/labctl. L'« upload binaire » de l'UI est un MYTHE — RÉFUTÉ par trace réseau (spike 2026-07-17).** L'hypothèse « il faut passer par l'UI parce que le REST ne prend pas le binaire » supposait que l'UI POSTe des octets bruts. **Elle ne le fait pas.** Trace live capturée sur l'UI **de l'API Gateway** (`apigatewayui`, *pas* le Designer) en uploadant un vrai `.cer` **binaire** (DER, 855 o) via *Client certificates → Browse → Add → Save* :

   ```
   PUT /apigatewayui/apigateway/applications/{id}     Content-Type: application/json
   "identifiers":[{"value":["MIIDUzCCAjugAwIBAgIU..."],"name":"demo-client-binary.cer","key":"httpsCertificate"}]
   ```

   L'UI **lit le fichier binaire en JS et le base64-encode côté client** avant l'envoi. Il n'existe **aucun** chemin binaire : le champ `<input type=file accept=".cer,.der,.pem,.crt">` alimente un PUT JSON ordinaire. **Mesure décisive** — la valeur stockée par la gateway après l'upload UI est **identique au bit près** à `base64(DER)`, soit exactement ce que `labctl` envoie déjà (`identifiers.go`) :

   | Voie | `name` | `sha256(valeur stockée)` |
   |---|---|---|
   | UI (`.cer` binaire, Browse+Add+Save) | `demo-client-binary.cer` | `ff18b2a650aee4e3bdc606835b88274a…` |
   | REST (labctl, `base64(DER)`) | `partner-cert` | `ff18b2a650aee4e3bdc606835b88274a…` |

   Même endpoint derrière (le PUT UI est relu tel quel par `GET :5555/rest/apigateway/applications/{id}`), même matière, même hash. **Conséquence sur le bug de hash de vérification** : il ne peut pas discriminer les deux voies, puisqu'elles déposent les mêmes octets — il les touche **toutes les deux ou aucune**. « Exporter en binaire + passer par l'UI » ne contourne donc **rien** : le contournement supposé n'a jamais existé, seule la *croyance* qu'un `.cer` binaire reste binaire jusqu'à la gateway. Si un bug de hash se manifeste sur une version de fix client, la cause est **ailleurs** (à ré-instruire sur cette version : c'est la matière stockée ou son parsing runtime, pas l'encodage du transport) — **et l'UI n'y échappera pas non plus**. ⇒ **Aucun résidu manuel** : cert, plage IP et clé backend sont **100 % REST/labctl**. *(Faits conservés du spike 2026-07-15 : le REST refuse le binaire brut et l'hex — 400 —, n'accepte que `base64(DER)` ou le PEM complet, stockés verbatim sans parsing. C'est cohérent : l'UI aussi n'envoie que du base64.)*

---

## Matrice classification → projection (échelle client `VH / H / M`)

| Classification | Connecteur IAM | Identité ENTRANTE exigée | API key backend (SORTANT) |
|---|---|---|---|
| **VH** | `AND` | `httpsCertificate` + `ipAddressRange` | résolue Vault (b1), rotation courte |
| **H** | `AND` | `httpsCertificate` **ou** `ipAddressRange` | résolue Vault (b1) |
| **M** | (identifiant unique) | `ipAddressRange` | résolue Vault (b1) |

Colonne ENTRANTE = identification opposable du consommateur (plan a). Colonne SORTANTE = API key du backend injectée par le TokenProvider (plan b). Dérivée par le moteur `classification → required_policies` d'ADR-076 ; enforcée à l'apply (INTEGRITY_UNFULFILLED si l'app livrée n'oppose pas ce que sa classification exige).

---

## Conséquences

- **Positif.** La V1 réutilise ~90 % de briques prouvées (adapter wM, Vault REST, chaîne ADR-077, `make release`). Le repo produit démarre avec un historique propre. Le modèle plan/apply fait de « pas d'humain = pas d'écriture » une **propriété** (aligné 4-yeux/ITSM). Sur le chemin apply nominatif, **Jenkins ne détient aucun credential Vault** — meilleur argument de vente.
- **Négatif / coûts.** Discipline d'extraction unidirectionnelle (un oubli de portage = drift). Deux fail-open à fermer avant toute démo « filtrage IP » / « TTL par clé ». Rotation de clé par consommateur = développement, pas config. Agents éphémères = exigence d'infra (pas une option). Traçabilité de bout en bout **par corrélation seulement** (la gateway ne voit que le compte de service).
- **Réversibilité.** Chaque brique garde son OFF (retirer `VAULT_ADDR` → fallback ADR-074 ; retirer la règle IAM IP → app non filtrée mais fonctionnelle). Le lab reste intact et indépendant.

## Alternatives écartées

- **Propager l'identité user jusqu'à la gateway** (au lieu du compte de service) — hors contrainte client, et wM 10.15 ne l'outille pas simplement.
- **Plugin HashiCorp Vault** — écarté (6 advisories, viole l'invariant RoleID/SecretID) ; REST direct préféré.
- **Plugin OIDC Provider pour l'identité** — `sub` = job, pas humain ; CVE d'usurpation.
- **Webhook portant l'identité humaine** — mécaniquement impossible (`ACL.SYSTEM`).
- **`git archive` du moteur depuis `stoa-labs`** (plan initial `DELIVERY-PROCESS.md`) — copie l'arbre, pas l'historique ; insuffisant pour la gouvernance bancaire.
- **Developer Portal natif 10.15** — lourd, isolation par team incomplète en REST (GOAL § bascule) ; évolution, pas V1.

## Décisions client — tranchées (2026-07-15) et restantes

**Tranchées :**
1. ✅ **Voie identité = A** (Vault LDAP, mot de passe saisi au build). B (SSO) en cible.
2. ✅ **Agents Jenkins = Kubernetes, éphémères** → identité de job en **Vault Kubernetes auth** (plus d'AppRole/SecretID côté Jenkins) ; ferme aussi la fuite `ps e` de la voie A.

**Nouvelles, ouvertes par la mise en œuvre de la voie A (2026-07-22) :**

4. **MFA sur l'annuaire ?** Si l'AD l'impose, **la voie A tombe** : un login non
   interactif ne passe pas de MFA. Repli voie B. *À poser en premier.*
5. **Mount d'auth exact** (`ldap` / `ad` / `ldap-corp`) et **Vault Enterprise à
   namespaces ?** (knobs `VAULT_USER_AUTH_MOUNT`, `VAULT_NAMESPACE` — aucun code.)
6. **Format de login** (`sAMAccountName` / UPN / `DOMAIN\user`) — fixe
   `userattr`/`upndomain` **et** contraint le backend (cf. §3 constat 1).
7. **Un groupe d'annuaire par tenant** : qui les crée, qui les peuple ? (cf. §3 constat 2.)
8. **Politique de lockout** de l'annuaire, et **TTL max** du token vs durée de build
   (au-delà, il faut un `renew-self`, non implémenté).
9. **Les secrets de plateforme sont-ils lisibles par un humain ?** Le câblage
   nominatif de `Jenkinsfile.prod`/`.rollback` est livré et repose sur la policy
   `operator-deploy` ; reste à décider si votre PSSI accorde cette policy à des
   humains — sinon ces deux pipelines restent sur le repli AppRole, avec l'acte
   non imputable que cela implique.

**Restante — à confirmer (faisabilité tranchée par le spike 2026-07-15) :**
3. **Quel pattern d'injection de l'API key backend ?** Le spike a **écarté** le mapping natif « identifier stocké → header » (impossible sur 10.15). Restent trois patterns (§5b) : **★ P-callout (TokenProvider Vault-backed, recommandé** — clé par consommateur dans Vault, cachée du client, déjà dans le repo) ; **P-recopie** (le client présente la clé, la gateway la recopie — acceptable seulement si le consommateur est légitimement porteur) ; **P-alias** (1 clé par API/env). *Le choix dépend d'une réponse sécurité : le consommateur a-t-il le droit de détenir la clé backend, ou doit-elle lui rester cachée ?*

## Definition of Done de cet ADR

- [ ] Repo produit `stoa-apim-delivery` initialisé (historique propre, branch protection, `make release`).
- [ ] **Plan entrant** : action IAM `AND` généralisée — `ipAddressRange` (+ `httpsCertificate`) posés en règle d'identification, connecteur dérivé de la classification. **Preuve X/X** reproduisant la matrice A-D du spike.
- [ ] **Plan sortant** : pattern d'injection choisi (§ Décision 3 ; reco P-callout) ; si P-callout, TokenProvider projeté **as-code** (fin du câblage manuel des 2 policyActions). *(Faisabilité tranchée : `customHttpHeaders` prouvé, mapping natif d'identifier écarté — spike 2026-07-15.)*
- [x] Chemin **apply** en **Vault LDAP** nominatif (voie A), `revoke-self` vérifié **avec preuve de mort et y compris quand le build échoue** — `scripts/test-vault-user-login.sh` 34/34 + E2E Jenkins (2026-07-22). *Reste* : identité de job en **Vault Kubernetes auth** (non prouvable en lab sans cluster), et `Jenkinsfile.prod`/`.rollback` (cf. §3, décision client sur la lecture des secrets de plateforme par un humain).
- [ ] Frontière secrets : plus aucun secret d'amorçage Vault dans Jenkins (K8s auth) ; fallback AppRole documenté (response wrapping) pour un client non-K8s.
- [ ] Gardes applicatives (E3) présentes (owner/register/oracle) — pas de self-service multi-équipes sans elles.

## Références

- Recherche 2026-07-14 (deep-research, 103 agents, 21 claims vérifiés 3-votes) : frontière secrets HashiCorp WAF ; impossibilité token Vault nominatif via plugins Jenkins ; contrainte `ACL.SYSTEM` du webhook (CloudBees).
- Spike live 2026-07-14 : identifiers IP/API-key/cert opposés, deux fail-open — mémoire `wm-1015-rest-shapes`.
- Spike live 2026-07-15 : `customHttpHeaders` injecte un header sortant (prouvé) ; **aucun identifier stocké lisible par la transformation** (mapping natif écarté) ; seules formes résolues = littéral / `${alias}` / `${request.headers.X}` — mémoire `wm-1015-rest-shapes`.
- `GOAL-self-service-api-app-2026-07-09.md` (volet consommateur, jalons E1-E6).
- `DELIVERY-PROCESS.md` (3 couches moteur/config/preuve, liste « ne part JAMAIS »).
- ADR-071 (onboarding-as-code, identifiers app), ADR-074 (Vault), ADR-075 (multi-env), ADR-076 (GitOps lifecycle, classification→policies), ADR-077 (identité user→Vault, chaîne 24/24).
