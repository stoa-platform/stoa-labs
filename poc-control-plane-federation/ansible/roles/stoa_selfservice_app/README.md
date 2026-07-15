# rôle `stoa_selfservice_app` — self-service de création d'application (ADR-078), 100 % Ansible

Crée/converge une **application consommatrice** sur webMethods API Gateway 10.15
et **OPPOSE** son identité entrante (plage IP, + certificat) par une règle
d'identification IAM `AND(strict)` — ce qui **ferme le fail-open** « identifier
écrit mais inerte ». Orchestration ET mutation gateway en Ansible pur (module
`uri`, aucune collection tierce).

## Pourquoi Ansible et pas le binaire Go

Chez ce client, le code **co-développé avec une IA** n'est pas (encore) autorisé
sous forme de **binaire compilé** ; un **playbook Ansible** que l'ops relit et
s'approprie passe sans souci. On inverse donc la doctrine `DELIVERY-PROCESS`
(« Ansible orchestre, labctl mute ») : **ici Ansible fait les deux**. La logique
d'idempotence, les shapes REST et le **read-back fail-closed** sont la SPEC
VÉRIFIÉE côté Go (`labctl/internal/adapter/webmethods`, mémoire projet
`wm-1015-rest-shapes`) — le binaire reste au repo, parqué, réactivable plus tard.

## Ce qui est prouvé live (10.15 réelle)

- App + identifier `ipAddressRange` + règle IAM `AND(ipAddressRange)` posés,
  **idempotents** (re-run = no-op ; find par **empreinte de règles** — la gateway
  force le nom « Identify & Authorize », donc jamais de match par nom).
- **Fail-open fermé** : IP hors plage → **403**, IP autorisée → **200**.
- `verify` **fail-closed** : `ENFORCEMENT_CONFIRMED` (le stage IAM oppose bien
  l'action AND) + preuve data-plane 200 en enforce IP-only.

## Usage

```bash
# converge (défauts dans defaults/main.yml ; surcharger stoa_ss_app par -e / group_vars)
ansible-playbook -i inventory.ini ansible/selfservice-app.yml \
  -e '{"stoa_ss_app":{"name":"svc-toto","api":"accounts-read","api_version":"1.0.0","ip_allowlist":["10.60.30.1-10.60.30.30"],"enforce":["ipAddressRange"]}}'

# preuve fail-closed rejouable (critère d'acceptation)
ansible-playbook -i inventory.ini ansible/selfservice-app-verify.yml -e @vars.yml
```

Chez le client : `stoa_ss_admin_url` = le **proxy `wm-admin-{env}`** (ADR-075) +
bearer OAuth2, pas Basic direct ; les creds admin sont lus dans **Vault**
(`tasks/secrets.yml`, fallback PoC total sans `VAULT_ADDR`).

## Le manifeste `stoa_ss_app`

| Champ | Rôle |
|---|---|
| `name`, `api`, `api_version` | application + API cible (publiée d'abord) |
| `ip_allowlist` | IPs / plages `A-B` — **PAS de CIDR** (la gateway le drop en silence) ; une IP nue est normalisée en `X-X` (match exact + visible UI) |
| `public_cert_ref` | chemin d'un PEM **public** (clé privée refusée) |
| `enforce` | dimensions à OPPOSER, sous-ensemble de `["httpsCertificate","ipAddressRange"]` — **vide = identifiers inertes, à éviter** |
| `backend` | header + template de clé backend (plan sortant, cf. limites) |

## Limites / résidus (assumés, ADR-078)

- **Certificat** : posé en identifier REST *best-effort*. Sur les versions de fix
  touchées par le **bug de hash base64** de la gateway, le cert de l'app se pose
  **manuellement dans l'UI** (export `.cer` binaire) — le REST refuse le binaire
  (400). `AND(cert,IP)` ne se teste pas en clair (cert non présenté → 401) : il
  exige le listener HTTPS client-auth.
- **Plan SORTANT (clé backend, P-callout)** : PAS encore dans ce rôle v1 —
  section `tasks/backend.yml` à ajouter (callout transport + `customHttpHeaders`),
  résolution Vault par le package IS TokenProvider (résidu Designer).
- **CIDR** : rejeté fail-closed (à convertir en range via `ansible.utils.ipaddr`
  en évolution).
