---
title: "ADR-074 — Secrets depuis Vault : creds plateforme hors-Git, lus à l'exécution, rotables sans rebuild (concrétise le gap (d) d'ADR-072)"
sidebar_label: "ADR-074 : Secrets depuis Vault"
status: "Proposé — en attente Council 8/10 (GO/NO-GO)"
maturite_technique: "✅ Livré & prouvé — Vault as-code + AppRole + rotation"
date: 2026-06-12
adr_number: 74
note: "S'appuie sur ADR-072 (médiation control-plane, gap (d))."
---

# ADR-074 — Secrets depuis Vault

**Statut :** Proposé — en attente validation Council 8/10 (GO/NO-GO). *(axe gouvernance/business — distinct de la maturité technique ci-dessous)*
**Maturité technique :** ✅ Livré & prouvé — `labctl/internal/vault` (KV v2 stdlib), AppRole least-privilege (403 croisés labctl↔ci), rotation live (`test-vault-rotation.sh`).
**Date :** 2026-06-12.
**Contexte technique :** gateways mutualisées, secrets gérés en coffre.
**Lié à :** [[adr-072-control-plane-mediation]] (gap (d)).

---

## Décision (test « archi 40 ans / 30 secondes »)

> Les secrets de la plateforme (**creds admin gateway**, secret du compte de service CI `ci-applier`, mot de passe d'écriture d'audit OpenSearch, admin Keycloak) ne vivent plus en **placeholders `targets.yaml` / variables d'env / credentials Jenkins**. Ils vivent dans **Vault** et sont **lus à l'exécution** : `labctl` résout les creds gateway depuis Vault avant chaque apply ; `onboarding-api` y prend son mot de passe OpenSearch ; le stage CI ne détient plus **qu'un** token Vault et fetch le reste au runtime. **Rotables sans rebuild** : changer une valeur dans Vault change le comportement du prochain run, sans recompiler ni redéployer.
> **Fallback total** : `VAULT_ADDR` non défini → comportement actuel inchangé (littéraux `targets.yaml`), donc aucun test ni la CI existante ne casse.
> **Test** : *si on rote un secret dans le coffre, le prochain `apply` l'utilise-t-il sans qu'on recompile/redéploie quoi que ce soit ?* Si non, les secrets sont figés dans l'artefact et la rotation est un mythe.

---

## Contexte et problème

ADR-072 a acté le **gap (d)** : l'admin API d'une gateway est tout-puissant, aucune des 3 gateways ne sait scoper un credential par tenant, donc **le control plane EST la couche de scoping**. Mais les creds eux-mêmes restaient en **placeholders dans Git** (`admin/admin`, `poc-apisix-admin-key`, `Administrator/manage`), les secrets CI dans des **credentials Jenkins**, le pass OpenSearch en **env**. Sur une cible bancaire, c'est l'anti-pattern : secrets dispersés, non rotés, baked dans les manifestes/artefacts. Il faut **centraliser** (un coffre), **lire à l'exécution**, **roter sans rebuild** — et que **dev/CI ne portent pas** les secrets applicatifs (au pire un token de coffre).

---

## Décision détaillée

| Surface | Avant | Après (Vault autoritaire si `VAULT_ADDR` set) |
|---|---|---|
| **labctl** (apply/subscribe/plan/apply-uac) | creds dans `targets.yaml` `credentials{}` | `loadResolvedTargets` lit `secret/stoa/gateways/{target}` + `secret/stoa/keycloak` et **override** ; fallback littéral si Vault absent |
| **onboarding-api** | `OPENSEARCH_PASSWORD` en env | si vide + Vault → `secret/stoa/opensearch#adminPassword` |
| **CI (Jenkins)** | 2 credentials Jenkins (`ci-applier-secret`, `opensearch-password`) | **1** credential `vault-token` ; le shell fetch les 2 secrets + labctl résout les creds gateway depuis Vault (`VAULT_ADDR` set) |

**Implémentation** : nouveau paquet **`internal/vault`** (KV v2 sur l'API REST, **stdlib `internal/httpx`, zéro dépendance vendorée** — air-gapped, le principe reuse-first) ; wrapper **`cmd/labctl/loadResolvedTargets`** (garde `internal/targets` pur). Vault **dev-mode** dans `docker-compose.poc.yml` (KV v2 sous `secret/`, root token PoC jetable), secrets provisionnés idempotemment par `scripts/setup-vault.sh`.

**Sémantique** : `VAULT_ADDR` set → Vault **autoritaire** (override) ; un secret **absent** (404) → on **garde le littéral** (override où Vault a la valeur, pas aveuglément) ; Vault **injoignable/403** → **erreur** (fail-closed : un coffre configuré-mais-cassé ne doit pas retomber silencieusement sur les littéraux). Aucun secret n'est **jamais loggé** (cf. fix token CI : `set +x`, jamais en argv).

---

## Conséquences

**Positives.** Secrets **centralisés** + **hors des manifestes/artefacts** ; **rotables sans rebuild** (prouvé) ; **dev** ne porte aucun secret applicatif (Git PR / token OAuth) ; **CI** ne porte qu'un token Vault ; **rétro-compat totale** (sans Vault, rien ne change). Zéro nouvelle dépendance Go.

**Frontières / suites notées.**
- **Secrets restants** : `poc-gateways-secret` (introspection), `onboarding-dev-secret`, dex broker — extensibles sous le même `secret/stoa/…`.
- Les **valeurs** provisionnées par `setup-vault.sh` sont PoC-jetables (identiques aux placeholders) ; en prod, émises/rotées par Vault, jamais dans un script.
- **Dev-mode** : Vault non scellé. Prod = Vault scellé + audit device + secrets dynamiques là où possible.

---

## Addendum 2026-06-12 — Identités éphémères (AppRole + policies least-privilege)

Le root token statique du premier jet était le maillon faible (tout-puissant, `ttl:0`, valeur
fixe). Remplacé par des **identités éphémères AppRole, least-privilege** — le « management du
token Vault » prod :

- **Policies par chemin** (`scripts/setup-vault-approle.sh`) : `stoa-labctl` = LECTURE
  `secret/stoa/gateways/*` + `…/keycloak` ; `stoa-ci` = LECTURE `secret/stoa/ci` + `…/opensearch`.
  Un token ne lit QUE son périmètre — **prouvé live** : token labctl → gateways 200 / ci **403** ;
  token ci → ci 200 / gateways **403** ; **aucun n'est root**.
- **Tokens éphémères** : `role_id` (identité non-secrète, comme un username) + `secret_id` (court,
  `secret_id_ttl` ~10min, rotable, `num_uses` limitable en prod) → `POST auth/approle/login` →
  **token TTL 3min** portant la seule policy du rôle. Il expire ; un token volé ne survit pas.
- **labctl** (`internal/vault`) : login AppRole **paresseux** (`VAULT_ROLE_ID` + `VAULT_SECRET_ID`/
  `_FILE`), ou token statique via **`VAULT_TOKEN_FILE` (0600, préféré à l'env)** — le token ne
  traîne ni en env ni en argv. `labctl apply` via AppRole → 3/3, et ce token ne lit pas `…/ci` (403).
- **CI** : le job ne détient plus qu'**un secret court** (`secret_id`, credential Jenkins
  `vault-ci-secret-id`) + l'identité `VAULT_ROLE_ID` (non-secrète, config Jenkins). Rôle
  **`ci-pipeline`** (policies `stoa-ci`+`stoa-labctl`) : un seul login → un token éphémère scopé
  EXACTEMENT aux 4 chemins du pipeline (rien d'autre), réutilisé par les lectures de secrets ET par
  labctl (`VAULT_TOKEN_FILE`). **Plus aucun root token.**

**Prod** : `secret_id` livré *just-in-time* (Vault Agent / response-wrapping), `num_uses=1`,
rotation auto ; le bootstrap des policies/roles est un **opérateur Vault**, pas la CI.

---

## Preuves (LIVE)

| Test | Prouve | Résultat |
|---|---|---|
| `scripts/setup-vault.sh` | 6 secrets écrits + relus (KV v2) | OK |
| `labctl apply` avec `VAULT_ADDR` | creds gateway depuis Vault → **3/3** ; mauvaise clé Vault → APISIX 401 (lecture live) ; **sans** Vault → 3/3 (fallback) | OK |
| onboarding-api **sans** `OPENSEARCH_PASSWORD` + Vault | POST 201 + **doc audit écrit** (pass depuis Vault), 0 `sink_error` | OK |
| stage CI in-agent (`vault:8200`) | secrets fetchés depuis Vault, **9/9** publications, **0 secret en clair** | OK |
| `scripts/test-vault-rotation.sh` | rotation live : mauvaise valeur ⇒ échec, restaurée ⇒ succès, **même binaire** | OK |
| `scripts/setup-vault-approle.sh` + login | least-privilege : token labctl→gateways 200/ci **403** ; token ci→ci 200/gateways **403** ; aucun root | OK |
| `labctl apply` via AppRole (`VAULT_ROLE_ID`+`VAULT_SECRET_ID_FILE`) | login → token éphémère → creds gateway → **3/3** ; ce token ne lit pas `…/ci` (**403**) | OK |
| stage CI in-agent via AppRole (`ci-pipeline`) | un seul secret_id → login → **9/9**, **0 fuite** (secret_id/ci-secret/pass/JWT) | OK |

---

## Alternatives écartées

- **Vendoring du SDK Vault Go** — rejeté : KV v2 = REST JSON, `internal/httpx` suffit ; éviter une dépendance supply-chain (le principe reuse-first, air-gapped).
- **Injection des secrets à `up` (env du conteneur)** — rejeté : ça les fige au démarrage (pas de rotation sans restart) et les expose dans l'inspect du conteneur.
- **Garder les credentials Jenkins** — rejeté : multiplie les copies de secrets hors coffre ; un seul token Vault centralise.
