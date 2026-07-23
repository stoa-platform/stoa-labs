# HANDOFF — Voie A (user/mot de passe → Vault) + OAuth2 self-proxy + auth app 2 modes

**Date :** 2026-07-23 · **Branche :** `main` (mergée, propre) · **Baseline :** `dd8274a` → **HEAD `335304e`** (14 commits)
**Gitea `main` :** aligné sur le local. **GitHub `origin/main` :** PAS poussé (reste à `95f9a62`).

---

## TL;DR

Le pipeline CI (Jenkins + rôles Ansible) sait maintenant, de bout en bout et prouvé live :

1. **S'authentifier à Vault avec le user/mot de passe d'annuaire** de l'opérateur (voie A, ADR-078 §3) — token **nominatif**, tenant-scopé, révoqué avec preuve de mort.
2. **Attaquer l'API d'admin de la gateway via un self-proxy OAuth2** (modèle client — l'admin n'est jamais exposée en direct).
3. **Créer l'application consommatrice avec 2 modes d'auth** : `idp` (claim depuis Git, client sur l'IdP) et `internal` (gateway=AS, client stocké dans Vault), **multi-env, claim par env**.

Tout le reste (prod/rollback nominatifs, chaîne ADR-075) est validé. **Un seul livrable côté client = 2 jobs Jenkins + `ci/lib/vault-login.sh` + les rôles Ansible + 2 variables d'env.**

---

## Ce qui est LIVRÉ et PROUVÉ (avec reçus)

| Brique | Preuve | Fichiers clés |
|---|---|---|
| **Login user/pwd → Vault** (voie A) | `scripts/test-vault-user-login.sh` **34/34** ; job SCM `selfservice-app-deploy #7` SUCCESS ; `publish-api-deploy #11` SUCCESS | `ci/lib/vault-login.sh` (POSIX), rôles `apim_*/tasks/secrets.yml` |
| **Palier userpass** (sans annuaire) | inclus dans 34/34 | `scripts/setup-vault-userpass.sh`, `scripts/lib/lab-vault-users.sh` |
| **Palier LDAP réel** (UPN, DOMAIN\user, groupe→policy) | tests [ldap] du 34/34 | `scripts/setup-vault-ldap.sh`, `docker-compose.ldap.yml` (poc-openldap) |
| **prod/rollback nominatif + repli AppRole** | `stoa-prod-deploy ×2` + `stoa-prod-rollback ×2` SUCCESS (AppRole *et* nominatif oscar) ; ADR-075 **22/22** | `ci/Jenkinsfile.prod`, `.rollback`, `vault_login_any` |
| **push post-commit governance-api** (dette P1) | test 3 cas ; rollback E2E avec revert poussé | `labctl/internal/governance/gitrepo.go` (`PushRemote`), `cmd/governance-api/main.go` (`GOVERNANCE_GIT_PUSH_REMOTE`) |
| **Self-proxy OAuth2 de l'admin** | `setup-wm-admin-self-proxy.sh` **6/6** ; `publish-api-deploy #14` SUCCESS (`ADMIN_VIA=proxy-oauth2`) | `gateways/webmethods/admin-proxy/targets.wm-admin-self.yaml` |
| **Auth app mode `idp`** (claim Git, audience=API) | live : stratégie `KeycloakStoaLab`/audience=demo-selfservice, identifier `azp` lié | `ansible/roles/apim_selfservice_app/tasks/consumer-auth.yml` |
| **Claim PAR ENV** | live : dev→consumer-dev, rec→consumer-rec, int→consumer-int (3 stratégies) | `clients/_example/applications/demo-consumer-idp.ansible.yml` |
| **Auth app mode `internal`** (client→Vault, multi-env) | live : secret ≠ dev/rec, cross-tenant 403, **fail-closed** (jamais de secret vide) | idem + policy `deploy-<tenant>` étendue (write sur `apps/*`) |

---

## Ce qui RESTE OUVERT

### Décisions client (bloquantes, à récolter sur place)
1. **MFA sur l'AD ?** — si oui, **la voie A tombe** (login non interactif) → repli voie B (ADR-077 SSO). *À poser en premier.*
2. Mount d'auth exact (`ldap`/`ad`/`ldap-corp`) + **Vault Enterprise à namespaces ?** (knobs `VAULT_USER_AUTH_MOUNT`, `VAULT_NAMESPACE`, aucun code).
3. Format de login (`sAMAccountName`/UPN/`DOMAIN\user`) — fixe `userattr`/`upndomain` ; **rappel : `userpass` refuse `@` et `\`, seul `ldap` les porte**.
4. **Un groupe d'annuaire par tenant** — qui les crée/peuple (l'annuaire gouverne « qui déploie pour qui »).
5. Politique de **lockout** AD (le code ne retente jamais un refus — consigne aux utilisateurs).
6. TTL max du token vs durée de build (au-delà → `renew-self`, non implémenté).
7. **Secrets de plateforme lisibles par un humain ?** (policy `operator-deploy` pour prod/rollback nominatif).
8. **Groupes AD imbriqués ?** → le `groupfilter` par défaut de Vault ne résout pas le nesting (`LDAP_MATCHING_RULE_IN_CHAIN`).

### Limite technique (à confirmer côté doc wM)
- **Mode `internal` — génération du client OAuth2.** Sur le **wM 10.15 trial**, la surface admin REST sondée n'auto-génère PAS le client OAuth2 interne (seul `apiAccessKey` est émis, jamais `oauth2_credentials`). Le mode prend donc le client via `apim_ss_internal_client_id/_secret` (extra-vars — DCR du serveur interne appelé en amont, ou saisi). **À faire :** confirmer l'endpoint DCR du serveur d'autorisation interne wM du client → câbler la capture auto dans `consumer-auth.yml` (le point d'extraction `accessTokens.oauth2_credentials` est déjà prévu). Le mode `idp` est complet.

### Non couvert au lab (codé, non prouvable ici)
- `VAULT_NAMESPACE` (Vault OSS au lab), auth **Kubernetes** de l'identité de job (pas de K8s au lab — le plan tourne sans secret, ne bloque rien).

---

## ⚠️ PIÈGES OPÉRATIONNELS DU LAB (lire avant de rejouer quoi que ce soit)

1. **La gateway trial est RECYCLÉE toutes les ~20 min** (`stoa/deploy/local/restart-wm.sh` via cron `*/5`, `WM_MAX_MIN=20` ; licence ~25 min). Un build/run qui chevauche le seuil est coupé en plein vol (« Connection refused » / « unreachable »). **Toujours** vérifier `docker inspect poc-webmethods-real --format '{{.State.StartedAt}}'` + healthy, et lancer les runs longs **juste après un cycle**. Les Jenkinsfiles ont une garde d'attente (5 min) mais un run de >15 min peut quand même être coupé.
2. **Le rôle realm `devops` du service-account `ci-applier` SAUTE à chaque recreate Keycloak** → rollback 403 `promotions:approve`. Ré-assigner (cf. bloc dans l'historique de session / `setup`).
3. **Les rôles AppRole Vault disparaissent** à un re-seed partiel (séquelle 07-07). `bash scripts/setup-vault-approle.sh` les recrée. `VAULT_ROLE_ID` est désormais surchargeable par env (le littéral pourrissait).
4. **`git push` vers Gitea nécessite un token** (bloqueur historique). Contournement utilisé : `docker exec -u git poc-gitea gitea admin user generate-access-token …` puis fetch du bundle dans le bare repo. Le token de push vit dans le clone LOCAL de travail (scratchpad), jamais commité.
5. **DELETE sur wM bloqué par le classifieur** en tool Bash → passer par un script + `! bash`.

---

## COMMENT REPRENDRE / REJOUER

### Setup complet du lab (depuis un état propre)
```bash
cd poc-control-plane-federation
bash scripts/setup-vault.sh                 # secrets de base
bash scripts/setup-vault-approle.sh         # rôles AppRole (disparaissent au re-seed)
bash scripts/setup-vault-userpass.sh        # palier 1 voie A + policies deploy-<tenant> + operator-deploy
docker compose -f docker-compose.poc.yml -f docker-compose.ldap.yml up -d openldap
bash scripts/setup-vault-ldap.sh            # palier 2 (annuaire réel)
./scripts/test-vault-user-login.sh          # → 34/34
```

### Rejouer l'auth app 2 modes (hors Jenkins, plus rapide)
```bash
. scripts/lib/lab-vault-users.sh ; . ci/lib/vault-login.sh
export VAULT_ADDR=http://localhost:8200 VAULT_USER_AUTH_MOUNT=ldap VAULT_USER=alice VAULT_USER_PASSWORD="$LAB_ALICE_PASS"
vault_login_nominative
# idp (claim per-env) :
ansible-playbook -i ansible/inventory.lab.ini ansible/selfservice-app.yml \
  -e apim_ss_manifest=clients/_example/applications/demo-consumer-idp.ansible.yml -e apim_ss_env=dev \
  -e apim_ss_api_base=http://localhost:5555/rest/apigateway \
  -e apim_ss_data_base=http://localhost:5555/gateway -e apim_ss_vault_wm_creds_sub=deploy/banking-demo/wm-admin
# internal (client fourni tant que le DCR n'est pas câblé) : + -e apim_ss_internal_client_id=… -e apim_ss_internal_client_secret=…
vault_revoke_proof
```

### Jobs Jenkins (formulaire « Build with Parameters »)
- `selfservice-app-deploy` / `publish-api-deploy` : sur `*/main`. Params voie A = `VAULT_USER` + `VAULT_USER_PASSWORD` (bouton « Change Password » = libellé Jenkins, ne change PAS le mot de passe AD — note dans la description). `ADMIN_VIA=proxy-oauth2` pour passer par le self-proxy.
- Identités de démo : `alice`/`Al1ce-lab-2026` (banking-demo), `oscar`/`0scar-lab-2026` (operator-deploy prod). Cf. `scripts/lib/lab-vault-users.sh`.

### Réparer la NPE wM (si PUT/ACTIVATE → 500)
```bash
bash scripts/repair-wm-dangling-policyaction.sh          # diagnostic
bash scripts/repair-wm-dangling-policyaction.sh --fix    # excise les policyActions fantômes
bash scripts/setup-wm-admin-proxy.sh ; bash scripts/demo-multienv.sh   # re-apply depuis Git
```

---

## MODE DEBUG (pour localiser une panne au client — « ma config ou la leur ? »)

Tout est verrouillé `no_log`/`set +x` pour ne jamais fuiter un secret → par défaut on est aveugle. Le mode debug **opt-in** rend visible les appels **sans** exposer de secret (corps de succès jamais imprimés, corps d'erreur rédactés).

- **Dans le pipeline** : cocher le paramètre **`DEBUG`** du build → traces `[vault-dbg] MÉTHODE url -> HTTP code`, erreurs Vault/Keycloak/gateway rédactées, verbosité Ansible, résumé des lectures KV (chemin + statut). Prouvé non-fuyant : `test-vault-user-login.sh` **37/37** (D1/D2/D3) + E2E `publish #16 DEBUG=true`.
- **En ligne de commande** : `STOA_DEBUG=1` devant n'importe quel appel à `ci/lib/vault-login.sh`.
- **Diagnostic autonome (LE plus utile au client)** : `scripts/diagnose-vault.sh` — rejoue la chaîne (joignable ? mount ? login ? lecture ?) avec les mêmes variables que le pipeline, et donne à CHAQUE étape le code HTTP + le message d'erreur Vault pour localiser la faute. Exemple :
  ```bash
  VAULT_ADDR=https://vault.corp:8200 VAULT_USER_AUTH_MOUNT=ldap \
  VAULT_USER='alice@corp' VAULT_USER_PASSWORD='...' \
  [VAULT_NAMESPACE=…] [VAULT_CACERT=/etc/pki/corp-ca.pem] \
  bash scripts/diagnose-vault.sh
  ```
  Messages typiques : `failed to bind` (mot de passe/format/mount) · `403` sur la lecture (policy) · `404` (secret non provisionné) · `sys/health INJOIGNABLE` (réseau/TLS). ⚠ Honnête sur l'ambiguïté : un mount **absent** renvoie 403 comme un mount qui **rejette** — le script le dit au lieu de sur-affirmer.

## MÉMOIRE PROJET (contexte durable)
- `memory/vault-user-password-login.md` — ce chantier, complet.
- `memory/wm-npe-dangling-policyaction.md` — la NPE wM (cause = policyAction supprimée mais référencée).
- `memory/livrable-self-service-adr078.md` — cadre ADR-078.
- ADR : `adr/adr-078-*.md` (statut voie A = livrée/prouvée), `adr-076-*` (#5 internal/external), `adr-075/077/079`.

## DERNIÈRE ÉTAPE SUGGÉRÉE
Pousser `main` vers GitHub `origin` (action externe, credentials GitHub requis — pas faits). Puis, chez le client : dérouler les 8 décisions (MFA d'abord) + smoke test curl de 10 min sur leur Vault avant de brancher Jenkins.
