# Self-service « création d'application » (ADR-078) — livrable démontrable

Chaîne **plan / apply** qui crée une Application consommatrice sur webMethods API
Gateway 10.15, avec identité **entrante** opposée (certificat client dans l'asset
+ plage IP) et injection **sortante** de la clé backend cachée du consommateur
(P-callout, TokenProvider ← Vault). Voir `adr/adr-078-livrable-self-service-app-wm1015.md`.

## Pièces

| Fichier | Rôle |
|---|---|
| `ci/Jenkinsfile.selfservice` | Pipeline **plan** (webhook, identité de job, lecture seule) / **apply** (build humain, identité nominative → Vault → gateway). Depuis A2 : paramètre **`MERGE_SHA`** (la référence, posée par `provision-apply`) — stage « Référence » : `fetch main` → `merge-base --is-ancestor` → `checkout` du SHA mergé AVANT le plan, puis `APPLIED_SHA` / `APPLIED_DIGEST` annoncés (relus par l'amont, `SHA_NON_CONFIRME` sinon). Vide = HEAD (voie humaine directe). |
| `ci/Jenkinsfile.provision-apply` | **Apply post-merge d'une demande** (A2) : réconciliation Gitea avant la pause (`PAYLOAD_PERIME`), pause nominative, garde d'identité nourrie par la forge, `build selfservice-app-deploy` au `MERGE_SHA`, confrontation, rapport de PR (SHA + digest). Coquille : `ci/jenkins/provision-apply.job.xml`. |
| `scripts/apply-selfservice-application.py` | **Apply engine** (prototype → cible `labctl apply-consumer`). Crée/converge l'app depuis un manifeste. Idempotent. |
| `clients/_example/applications/demo-consumer.json` | Manifeste de **demande** (name, api, ipAllowlist, publicCertRef, backend). |

## Ce qui est PROUVÉ live (sur la 10.15 réelle)

```
$ python3 scripts/apply-selfservice-application.py \
    clients/_example/applications/demo-consumer.json --verify-ip
   [✓] certificat client = identifier httpsCertificate DANS L'ASSET (read-back)
   [✓] plage IP = identifier ipAddressRange dans l'asset (read-back)
   [✓] règle IAM AND(httpsCertificate+ipAddressRange) strict (converge)
   [✓] injection clé backend customHttpHeaders 'apikey=${backend_apikey}' (P-callout)
   [✓] policy convergée (IAM strict + injection backend attachés)
   [✓] IP autorisée → 200
   [✓] IP hors plage → 403   ← FAIL-OPEN FERMÉ
   RÉSULTAT : 9/9 PASS
```

- **Identité entrante opposée** : le certificat est bien un identifier
  `httpsCertificate` **dans l'asset de l'application** (pas un alias) ; l'IP est
  **réellement filtrée** (403 hors plage) — ce que le PoC ne faisait PAS
  (identifier écrit mais non opposé = fail-open, désormais fermé).
- **Idempotent** : re-apply converge (mêmes objets, pas de doublon ; clé sur les
  actions attachées à la policy, pas sur leur nom).

## Ce qui reste un RÉSIDU (documenté, non simulé)

- **Résolution Vault de la clé backend** : le header `apikey=${backend_apikey}`
  est **posé** ; sa valeur est résolue au runtime par le **package IS
  TokenProvider** (déploiement Designer + `jcode.sh` = résidu manuel incompressible,
  cf. `DELIVERY-PROCESS.md`). La clé n'est jamais sur la gateway ni chez le
  consommateur (P-callout, choix client).
- **Handshake mTLS complet** `AND(cert, IP)` : la branche IP est prouvée en
  isolation (403). Le certificat exige le **listener HTTPS client-auth** pour être
  testé de bout en bout — étape suivante (la règle `AND` est déjà posée).
- **Certificat client de l'app — 100 % REST, pas de résidu UI.** L'API REST de
  l'identifier `httpsCertificate` refuse le binaire brut et l'hex (400) et
  n'accepte que `base64(DER)` ou le PEM complet (stockés verbatim). Ce n'est PAS
  une limite : l'UI de la gateway n'envoie **pas** de binaire non plus — elle
  base64-encode le `.cer` en JS avant le même PUT JSON. Trace réseau + octets
  stockés comparés (spike 2026-07-17, ADR-078 écart n°5) : **même sha256** par
  l'UI et par labctl ⇒ « exporter en `.cer` binaire et passer par l'UI » ne
  contourne aucun bug de hash (les deux voies déposent les mêmes octets, un tel
  bug les toucherait toutes les deux). Cert, plage IP et clé backend : 100 % REST.

## Ce que le stage PLAN refuse (hors ligne, sans secret)

Le PLAN tourne en identité de JOB, sans Vault et sans toucher la gateway. Outre
la validation du manifeste et le `--syntax-check`, il résout **le certificat**
via `ansible/test-cert-path.yml` — une sonde qui rejoue exactement les tâches du
rôle (`resolve-env` + `cert-der`) sans aucun appel réseau :

| Refusé au PLAN | Cas |
|---|---|
| `CERT_NOT_FOUND` | `public_cert_ref` introuvable — le message affiche **les deux chemins essayés** (racine du dépôt, puis dossier du manifeste) |
| `CERT_PATH_AMBIGUOUS` | même nom de fichier dans les deux bases avec des contenus **différents** |
| `CERT_INVALID` | pas de bloc `CERTIFICATE`, ou `base64(DER)` mal formé |
| clé privée | `publicCertRef` porte une `PRIVATE KEY` (ADR-071) |

Une demande **sans** certificat (identité par IP seule) rend `PROBE_SKIP` et
passe — c'est le cas du manifeste par défaut du pipeline. Ces erreurs échouaient
auparavant à l'**apply**, donc après authentification nominative et après les
premières écritures sur la gateway (application créée, cloisonnée, associée à
l'API). Requiert `openssl` sur l'agent — déjà une dépendance de l'apply.

**Preuve** : `./scripts/test-cert-path-resolution.sh` → **16/16**, hors ligne.

## Identité nominative — voie A (user/mot de passe), livrée et prouvée

L'apply demande **votre identité d'annuaire**, jamais un credential du job :

| Paramètre de build | Rôle |
|---|---|
| `VAULT_USER` | votre login annuaire — `sAMAccountName`, UPN `user@domaine`, ou `DOMAIN\user` |
| `VAULT_USER_PASSWORD` (type `password`) | saisi **à chaque apply**, jamais persisté hors du build |
| `USER_VAULT_JWT` | voie B (SSO Keycloak, ADR-077) — **prioritaire** si fournie |

Aucune des deux → le build s'arrête **vert en PLAN-only** : un build webhook tourne
en `ACL.SYSTEM` et ne porte aucun humain, il ne peut donc pas appliquer.

Tout le login vit dans **`ci/lib/vault-login.sh`**, partagé par les pipelines. Le
mount d'auth est un knob, `VAULT_USER_AUTH_MOUNT` : `ldap` chez le client (ou `ad`,
`ldap-corp`…), `userpass` en lab — **la requête REST est identique**, il n'y a
aucun bloc à « swapper ».

**Preuve** : `./scripts/test-vault-user-login.sh` → **34/34** (2026-07-22), plus un
build Jenkins E2E vert (mot de passe en paramètre → token `ldap-alice` → rôle
Ansible `ok=49 failed=0` + verify `ok=32 failed=0` → révocation prouvée, mot de
passe absent du log).

Mise en place du lab :

```bash
bash scripts/setup-vault-userpass.sh          # palier 1 : sans annuaire (onboarde aussi banking-demo/payments-team via ansible/onboard-team.yml)
docker compose -f docker-compose.poc.yml -f docker-compose.ldap.yml up -d openldap
bash scripts/setup-vault-ldap.sh              # palier 2 : annuaire réel
./scripts/test-vault-user-login.sh
```

### Ce qui reste à trancher chez le client

1. **MFA sur l'annuaire ?** Si oui, **la voie A tombe** — un login non interactif ne
   passe pas de MFA. Repli : voie B (ADR-077). *À poser en premier : c'est la seule
   question qui peut invalider tout le montage.*
2. **Mount exact** (`ldap`, `ad`, `ldap-corp`…) et **Vault Enterprise à namespaces ?**
   (`VAULT_USER_AUTH_MOUNT`, `VAULT_NAMESPACE` — les deux sont des knobs, aucun code.)
3. **Format de login** attendu : `sAMAccountName`, UPN, ou `DOMAIN\user` ? Il fixe
   `userattr`/`upndomain` — **et il contraint le backend** : `auth/userpass` refuse
   `@` et `\` dans un username (regex de path), seul `auth/ldap` les accepte.
4. **Un groupe d'annuaire par tenant** — qui les crée, qui les peuple ? En LDAP il
   n'y a pas de claim `tenant` (contrairement au JWT d'ADR-077) : la policy est
   attachée au **groupe**, donc c'est l'annuaire qui gouverne « qui déploie pour qui ».
5. **Politique de lockout** : un pipeline qui rejoue un mot de passe refusé verrouille
   le compte nominatif. Le code échoue une fois, sans réessai — la consigne doit être
   portée aux utilisateurs.
6. **TTL max du token** vs durée de build : si le build dépasse le TTL, il faut
   ajouter un `renew-self` (non implémenté — le TTL du lab est de 600 s).

## Rejouer la démo

```bash
# 1) publier l'API de démo (backend = token-echo)
./labctl/bin/labctl apply -f targets.demo.yaml

# 2) créer l'application + preuve du fail-open fermé
python3 scripts/apply-selfservice-application.py \
    clients/_example/applications/demo-consumer.json --verify-ip
```

Inspection UI : `http://localhost:19072` (Administrator/manage) → Applications →
`demo-consumer` (identifiers `httpsCertificate` + `ipAddressRange`) ; APIs →
`demo-selfservice` → policies (règle IAM strict + Custom HTTP Header).

## Cible produit

L'apply engine Python est un **prototype** : sa logique (identifiers cert/IP,
règle IAM `AND` dérivée de la classification, injection P-callout) doit être
repliée dans `labctl apply-consumer` (Go) — les shapes REST sont épinglées dans
la mémoire projet `wm-1015-rest-shapes`.
