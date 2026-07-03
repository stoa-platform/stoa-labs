# ansible/ — pré-requis mTLS « couche IS-admin » (ADR-076)

`labctl apply` projette tout ce qui a une API REST apigateway propre : la barrière
IAM `OAuth2 AND httpsCertificate` (`inboundAuth.mtls: true`), l'auth OAuth2, le
throttle, le routing… **Deux réglages n'ont PAS d'API apigateway propre** et vivent
donc ici, en Ansible (fidèle au standard client) :

| # | Réglage IS-admin | Pourquoi hors labctl |
|---|------------------|----------------------|
| 1 | Listener HTTPS **`clientAuth = request`** | config du listener IS (pas une policy d'API) |
| 2 | **CA cliente** dans le truststore `platform_truststore.jks` | keystore hors allowlist ADR-075 ; rechargé au **boot** IS |

Modèle retenu (ADR-076) : **port `request`** (le cert est accepté mais optionnel au
transport, toutes les APIs restent joignables) + **enforcement mTLS par-API au stage
IAM**. Un no-cert sur une API VH est rejeté **401 à l'IAM**, pas au transport.

## Fichiers

```
ansible/
  is-mtls-setup.yml                     # le play (2 étapes, idempotent, read-backs fail-closed)
  inventory.example.ini                 # cibles PoC (docker) et client (SSH)
```

> **Rien de sensible en Git.** La **CA cliente** ET le **storepass** du truststore
> sont lus depuis **Vault** au runtime (ADR-074, KV v2 mount `secret`, prefix `stoa` :
> `client_ca_pem`, `truststore_pass`). Aucun `.pem` n'est committé (`*.pem` est
> d'ailleurs gitignoré). **Fallback PoC sans Vault** : si `VAULT_ADDR` est absent,
> le play lit la CA d'un fichier local `ansible/files/<alias>.pem` (gitignoré) —
> exportable de la démo par :
> ```bash
> keytool -exportcert -rfc -alias accounts-team-client-ca \
>   -keystore /opt/softwareag/common/conf/platform_truststore.jks -storepass manage \
>   > ansible/files/accounts-team-client-ca.pem
> ```
> Alimenter Vault en client :
> ```bash
> vault kv put secret/stoa/webmethods/mtls client_ca_pem=@partner-ca.pem truststore_pass=****
> ```

## Pré-requis

Le play n'utilise que `ansible.builtin` (uri + command keytool) — **aucune collection
requise pour la logique**. `keytool` doit être présent sur l'hôte IS (fourni par le
JVM SAG : `keytool_bin`, défaut `/opt/softwareag/jvm/jvm/bin/keytool`).

```bash
# Uniquement pour la connexion docker de l'inventaire PoC :
ansible-galaxy collection install community.docker
```

## Lancer

```bash
cp inventory.example.ini inventory.ini            # adapter à la cible
ansible-playbook -i inventory.ini is-mtls-setup.yml
```

Surcharger une variable au besoin :

```bash
# repasser le port en require, ou pointer un autre truststore :
ansible-playbook -i inventory.ini is-mtls-setup.yml -e client_auth=require
```

## Ce que fait le play (idempotent)

1. **Ports** — lit `/rest/apigateway/ports`, isole le listener HTTPS (`:5543`), PUT
   `clientAuth=request` **uniquement s'il diffère**, puis **read-back fail-closed**
   (le play échoue si la valeur n'a pas pris).
   > ⚠️ Sur certains builds trial, `PUT /ports` peut renvoyer 500 (quirk de mise à
   > jour de port). Fallback manuel : API Gateway UI → *Administration > Ports*, ou
   > IS Admin `:5555/WmRoot` → *Security > Ports*. Le read-back le détectera.
2. **Truststore** — lit la **CA + le storepass depuis Vault** (`vault kv get`,
   ADR-074 ; fallback fichier local sans `VAULT_ADDR`), fail-closed si aucune CA,
   écrit le PEM en `0600`, l'importe dans le JKS via `keytool` **uniquement si
   l'alias est absent**, puis **purge le PEM**. **Si la CA est importée**, un handler
   **redémarre l'IS** (le truststore n'est relu qu'au démarrage — prouvé live) puis
   **attend `health=200`**. `no_log` sur les tâches portant le storepass.

## Secrets & auth Vault (ADR-074)

**Rien de secret dans l'inventaire ni en Git.** Les 3 secrets — admin password wM,
storepass du truststore, CA cliente — sont lus de **Vault** au runtime (KV v2 :
`secret/stoa/gateways/webmethods#password`, `secret/stoa/webmethods/mtls#{truststore_pass,client_ca_pem}`),
`no_log`. Fallback total sans `VAULT_ADDR` (défauts trial + fichier local) = parité
avec le moteur `internal/vault`.

**Auth Vault = AppRole** (même chaîne que `internal/vault`, donc que labctl en CI) :

1. token **statique** : `VAULT_TOKEN_FILE` (0600, préféré) → `VAULT_TOKEN` ;
2. sinon **login AppRole** : `VAULT_ROLE_ID` + `VAULT_SECRET_ID_FILE` (→ `VAULT_SECRET_ID`)
   → `POST /v1/auth/approle/login` → token **éphémère** scopé à la policy du rôle.

En CI (Jenkins, cf. `ci/Jenkinsfile.prod`) : `VAULT_ROLE_ID` en env (public, non-secret),
`VAULT_SECRET_ID` depuis le **credential store Jenkins** (`withCredentials`), jamais en
Git ni dans un log. Le play consomme les mêmes variables — soit le token que le CI a
déjà obtenu (`VAULT_TOKEN_FILE`), soit il fait le login AppRole lui-même.

```bash
# CI (le pipeline injecte VAULT_SECRET_ID depuis le credential store) :
export VAULT_ADDR=https://vault.banque.example VAULT_ROLE_ID=<public> VAULT_SECRET_ID_FILE=/run/secrets/sid
ansible-playbook -i inventory.ini is-mtls-setup.yml
```

## Portée / prod

En production ce rôle vit dans **stoa-infra/ansible** (règle cross-repo : l'infra
Ansible n'est jamais dans le repo applicatif). Ici, en PoC, il est co-localisé avec
la plateforme pour rester exécutable de bout en bout.

## Chaîne complète mTLS (rappel ADR-076)

```
[IS-admin / CE PLAY]  clientAuth=request  +  CA dans le truststore   (une fois par gateway)
        │
[labctl apply]        inboundAuth.mtls: true  ->  action IAM  OAuth2 AND httpsCertificate
[labctl subscribe]    publicCertRef          ->  cert client mappé au consumer (identifier httpsCertificate)
        │
   no-cert -> 401 IAM   |   cert sans token -> 401 IAM   |   cert + token -> 200
```
