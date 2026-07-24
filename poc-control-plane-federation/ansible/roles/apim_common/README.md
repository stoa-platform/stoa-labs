# apim_common — auth admin gateway partagée (Vault, fallback PoC)

Brique COMMUNE des rôles `apim_publish_api`, `apim_promote_api` et
`apim_selfservice_app` : résolution de l'authentification de l'API d'admin
(directe PoC ou proxifiée client) + défauts de connexion partagés
(namespace `apim_ss_*`). Remplace les 3 copies de `tasks/secrets.yml`
(« rôles autonomes ») — l'unité de livraison est désormais le **jeu de
rôles** : une brique = son rôle + `apim_common`, zéro dépendance externe.

## Consommation

Dans les rôles (main/verify) — même position qu'avant, l'ordre
resolve-env → secrets est conservé :

```yaml
- name: "Secrets : auth admin (Vault, fallback PoC)"
  ansible.builtin.import_role:
    name: apim_common
    tasks_from: secrets.yml
```

`import_role` (statique) expose les defaults d'`apim_common` au play entier ;
les résultats sont des **facts d'hôte**, visibles par toutes les tâches
suivantes :

| Fact | Contenu |
|------|---------|
| `apim_ss_uri_defaults` | dict pour `module_defaults: ansible.builtin.uri` (headers, body_format, basic auth le cas échéant, ca_path) |
| `apim_ss_headers` | Accept + `X-Environment` (si `apim_ss_env`) + Bearer (si oauth2) |
| `apim_ss_vault_token` | token Vault effectif (statique > K8s > user/password > AppRole) |

## Deux modes d'auth admin (`apim_ss_auth_mode`)

- `basic` : user/password — lus dans Vault KV v2
  (`<prefix>/<apim_ss_vault_wm_creds_sub>`), fallback `apim_ss_wm_user/_password`.
- `oauth2` : bearer `client_credentials` (proxy client) — creds depuis Vault
  (`<prefix>/<apim_ss_vault_oauth_sub>`), fallback vars `apim_ss_oauth_*`.

## Sans accès Vault (poste client, PoC)

Toutes les tâches Vault sont gardées par `VAULT_ADDR` : **sans `VAULT_ADDR`
dans l'environnement, aucun appel Vault n'est tenté** et les creds viennent
des vars ci-dessus (defaults, inventaire ou `-e`). Le mode oauth2 appelle
quand même l'IdP (token_url) pour obtenir le bearer.

## Avec Vault : ordre de résolution du token

Statique (`VAULT_TOKEN_FILE` > `VAULT_TOKEN`) > Kubernetes (`VAULT_K8S_ROLE`,
SA du pod agent) > user/password (`VAULT_USER`/`VAULT_USER_PASS_FILE`, mount
`VAULT_USER_AUTH_MOUNT` — `auth/ldap` client, `auth/userpass` lab) > AppRole
(`VAULT_ROLE_ID`/`VAULT_SECRET_ID_FILE`). Sous Jenkins, le login nominatif est
fait UNE fois par `ci/lib/vault-login.sh` qui passe `VAULT_TOKEN_FILE` — le
rôle ne refait alors aucun login (ADR-078 §2). `VAULT_NAMESPACE` (Enterprise)
est propagé sur tous les appels.

L'organisation du Vault client n'a pas besoin de ressembler au lab : mount,
préfixe et sous-chemins sont des knobs (`apim_ss_vault_kv_mount`,
`apim_ss_vault_prefix`, `apim_ss_vault_wm_creds_sub`, `apim_ss_vault_oauth_sub`).

Debug non-fuyant : `-e stoa_debug=true` trace voie d'auth, chemins KV et codes
HTTP — jamais une valeur de secret.
