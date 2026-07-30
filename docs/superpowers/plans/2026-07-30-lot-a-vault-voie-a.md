# Lot A — Vault du cluster en voie A : plan d'implémentation

> **Pour les agents :** SOUS-COMPÉTENCE REQUISE — utiliser `superpowers:subagent-driven-development` (recommandé) ou `superpowers:executing-plans` pour dérouler ce plan tâche par tâche. Les étapes sont en cases à cocher (`- [ ]`).

**Objectif :** dans le cluster k3s Contabo, un pod agent Jenkins obtient un jeton Vault **nominatif** par `auth/ldap` avec les identifiants d'annuaire d'un opérateur, lit un secret, et le jeton meurt à la sortie — avec les contre-épreuves qui rendent la preuve non triviale.

**Architecture :** un OpenLDAP jetable en ns `ci`, versionné dans `stoa-labs` et synchronisé par ArgoCD sur le projet `default`. La configuration de Vault (mounts `userpass` et `ldap`, policies, mapping groupe→policy) est faite par un script que **l'exploitant** exécute dans `vault-0` avec un jeton racine éphémère obtenu par quorum 2/3. Le code d'authentification existe déjà et n'est pas modifié : `ci/lib/vault-login.sh` et les rôles `apim_*` portent déjà les deux mounts.

**Pile technique :** Vault 1.18 (OSS), `osixia/openldap:1.5.0`, Kubernetes 1.34 / k3s, Kustomize, ArgoCD, shell POSIX, Python 3 pour la fabrication des corps JSON.

**Spécification :** `docs/superpowers/specs/2026-07-30-lot-a-vault-voie-a-design.md`

## Contraintes globales

Elles s'appliquent à **toutes** les tâches. Une tâche qui les viole est à rejeter même si son test passe.

- **Le dépôt `stoa-labs` est PUBLIC.** Aucun mot de passe, jeton, clé ou empreinte de secret ne doit y entrer. Aucune IP de la flotte non plus (règle en vigueur, cf. `ansible/inventory.contabo.ini`).
- **Les clés de descellement de Vault sont hors ligne.** Aucun agent ne configure Vault. Tout passe par un script exécuté par l'exploitant, sur le modèle de `docs/superpowers/plans/2026-07-29-f4-vault-role-toggle.sh` : quorum 2/3, jeton racine éphémère, révoqué en sortie, clés jamais affichées.
- **Toute sortie sensible va dans un fichier root-only du nœud, jamais sur stdout.**
- **Ne pas toucher au dépôt `stoa`.** Les composants du lab vivent dans `stoa-labs` avec leur propre Application Argo sur le projet `default`.
- **Images épinglées par digest**, jamais par tag seul.
- **Un `200` ne prouve rien.** Chaque assertion se vérifie par relecture de l'état. Précédent : le 2026-07-29, un `PUT` de la gateway a renvoyé 200 sans appliquer la modification demandée.
- **Pas de réécriture de l'historique Git.**
- **Aucun ConfigMap écrit en dur** s'il porte de la configuration consommée par un pod : utiliser `configMapGenerator` pour que l'empreinte force le redéploiement. Piège rencontré et corrigé sur `cloudflared` le 2026-07-30.
- **Anti-affinité `worker-3`** sur tout nouveau composant : ce nœud est prévu pour extinction en F5.
- **Valeurs de l'annuaire, identiques au POC compose** pour que les deux mondes restent comparables : base DN `dc=corp,dc=example`, domaine `corp.example`, bind `cn=admin,dc=corp,dc=example`, utilisateurs sous `ou=People`, groupes sous `ou=Groups`, `userattr=uid`.

## Structure des fichiers

| Chemin | Responsabilité |
|---|---|
| `poc-control-plane-federation/scripts/lib/lab-vault-users.sh` | **modifié** — noms d'utilisateur, formats de login, tenants. Plus aucune valeur de mot de passe |
| `poc-control-plane-federation/scripts/check-no-plaintext-secrets.sh` | **créé** — garde : échoue si une affectation de mot de passe littéral réapparaît |
| `deploy/bootstrap/ci/openldap/deployment.yaml` | **créé** — Deployment OpenLDAP, sans volume |
| `deploy/bootstrap/ci/openldap/service.yaml` | **créé** — Service ClusterIP `openldap:389` |
| `deploy/bootstrap/ci/openldap/kustomization.yaml` | **créé** — assemble les deux, namespace `ci` |
| `deploy/bootstrap/argocd/app-ci-openldap.yaml` | **créé** — Application Argo, projet `default`, source `stoa-labs` |
| `poc-control-plane-federation/scripts/seed-ldap-cluster.sh` | **créé** — peuple l'annuaire du cluster (OU, utilisateurs, groupes). Idempotent |
| `docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh` | **créé** — script exploitant : mounts, policies, identités, mapping. Quorum 2/3 |
| `poc-control-plane-federation/scripts/test-voie-a-cluster.sh` | **créé** — harnais de preuve, exécuté depuis un pod du cluster |

Découpage par responsabilité : le déploiement de l'annuaire (Argo), son peuplement (script à chaud), la configuration de Vault (exploitant, privilégié) et la preuve (harnais) sont quatre choses qui changent pour des raisons différentes et à des rythmes différents.

---

### Tâche 1 : purger les mots de passe publics et poser une garde

**Fichiers :**
- Modifier : `poc-control-plane-federation/scripts/lib/lab-vault-users.sh`
- Créer : `poc-control-plane-federation/scripts/check-no-plaintext-secrets.sh`

**Interfaces :**
- Produit : les variables `LAB_ALICE_USER`, `LAB_BOB_USER`, `LAB_CAROL_USER`, `LAB_OSCAR_USER`, `LAB_ALICE_DOMAIN_USER`, `LAB_ALICE_UPN_USER`, `LAB_TENANT_ALICE`, `LAB_TENANT_BOB`, `LAB_BOB_PASS_METACHARS`. **Ne produit plus** `LAB_ALICE_PASS`, `LAB_CAROL_PASS`, `LAB_BOB_PASS`, `LAB_BOB_PASS_DEFAULT`, `LAB_OSCAR_PASS`.
- Consommé par : tâches 3, 4 et 5.

Les appelants historiques (`setup-vault-userpass.sh`, `test-vault-user-login.sh`) lisaient les mots de passe depuis ce fichier. Ils liront désormais le fichier root-only produit par la tâche 4. Le POC compose continue de fonctionner tant que ce fichier existe sur le poste ; sans lui, ses tests `[userpass]`/`[ldap]` se **sautent** au lieu d'échouer — comportement déjà porté par `skip()` dans le harnais.

`LAB_BOB_PASS_METACHARS` **reste en Git** : ce n'est pas un secret mais un vecteur de test d'injection, et il ne doit être le mot de passe d'aucun compte réel. Le renommage (`_PASS` → `_PASS_METACHARS`) est délibéré : il empêche la garde de le confondre avec un mot de passe et dit ce que la variable est.

- [ ] **Étape 1 : écrire la garde qui échoue**

Créer `poc-control-plane-federation/scripts/check-no-plaintext-secrets.sh` :

```sh
#!/bin/sh
# check-no-plaintext-secrets.sh — garde de dépôt PUBLIC.
#
# Échoue si une affectation de mot de passe littéral réapparaît dans les scripts.
# Le dépôt est public depuis le 2026-07-30 : quatre mots de passe de lab y ont
# déjà fuité (commits 83964e1, 9ef7eb6) et sont considérés brûlés. Cette garde
# empêche la récidive, elle ne répare pas le passé.
#
# EXEMPTION ASSUMÉE : *_PASS_METACHARS est un vecteur de test d'injection
# (guillemets, antislash, dollar) et non le mot de passe d'un compte.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RC=0

# Affectations shell d'un mot de passe à une valeur littérale non vide.
HITS=$(grep -rnE "^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*(PASS|PASSWORD|SECRET|TOKEN)[A-Za-z0-9_]*=['\"]?[^'\"[:space:]\$]" \
         --include='*.sh' "$ROOT/scripts" "$ROOT/ci" 2>/dev/null \
       | grep -vE "_PASS_METACHARS=" \
       | grep -vE "=['\"]?\\\$" || true)

if [ -n "$HITS" ]; then
  echo "ÉCHEC — affectation(s) de secret littéral dans un dépôt public :"
  echo "$HITS" | sed 's/=.*/=<REDACTÉ PAR LA GARDE>/'
  RC=1
else
  echo "OK — aucune affectation de secret littéral"
fi

exit $RC
```

- [ ] **Étape 2 : la lancer et vérifier qu'elle échoue**

```bash
chmod +x poc-control-plane-federation/scripts/check-no-plaintext-secrets.sh
poc-control-plane-federation/scripts/check-no-plaintext-secrets.sh
```

Attendu : **ÉCHEC**, avec `lab-vault-users.sh` cité quatre fois (`LAB_ALICE_PASS`, `LAB_CAROL_PASS`, `LAB_BOB_PASS`, `LAB_OSCAR_PASS`). Les valeurs doivent apparaître **rédigées** — si la garde imprime un mot de passe en clair, elle est elle-même le problème : corriger le `sed` avant de continuer.

- [ ] **Étape 3 : réécrire `lab-vault-users.sh`**

Remplacer intégralement le contenu par :

```bash
#!/usr/bin/env bash
# scripts/lib/lab-vault-users.sh — identités de DÉMONSTRATION de la voie A
# (user/mot de passe → Vault, ADR-078 §3). À SOURCER par les scripts de setup et
# par les harnais de preuve : source unique de vérité pour les NOMS, les FORMATS
# de login et les TENANTS — aucune dérive possible entre provisioning et preuve.
#
# ⚠ AUCUN MOT DE PASSE ICI. Le dépôt est PUBLIC depuis le 2026-07-30. Les mots de
# passe sont générés au setup et déposés dans un fichier root-only du nœud (cf.
# docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh). Un mot de passe qui
# sert à s'authentifier À Vault ne peut pas être rangé DANS Vault : c'est circulaire.
#
# Les quatre valeurs qui vivaient ici (commits 83964e1, 9ef7eb6) sont PUBLIQUES et
# donc BRÛLÉES. Ne jamais les réutiliser. Pas de réécriture d'historique : elle
# casserait tous les clones pour un bénéfice illusoire sur un dépôt déjà copiable.
#
# Chaque identité porte UN invariant de la preuve :
#   alice               banking-demo   cas nominal
#   bob                 payments-team  cross-tenant (doit se voir REFUSER banking-demo)
#                                      + mot de passe à MÉTACARACTÈRES
#   carol               (aucune)       authentifiée mais sans policy de déploiement
#   CORP\alice          banking-demo   URL-encodage du path (%5C — format DOMAIN\user)
#   alice@corp.example  banking-demo   URL-encodage du path (%40 — format UPN)
# shellcheck disable=SC2034  # fichier SOURCÉ : les variables sont consommées par l'appelant.

LAB_ALICE_USER='alice'
LAB_BOB_USER='bob'
LAB_CAROL_USER='carol'

# Alias d'alice : mêmes droits, mêmes identifiants — seul le FORMAT du login change.
#
# ⚠ RÉSERVÉS AU PALIER LDAP — trouvaille live (Vault 1.17.6, 2026-07-22) :
#   * `auth/userpass` REFUSE `@` et `\` dans un username. Son pattern de path est
#     GenericNameRegex (\w, `-`, `.`) : `users/alice@corp.example` -> 404
#     « unsupported path », et `login/CORP\alice` -> 500 « failed to determine
#     alias name from login request ».
#   * `auth/ldap` les ACCEPTE (pattern `.+`) : les deux formats atteignent la
#     phase de connexion à l'annuaire — c'est le cas client, et il fonctionne.
# Conséquence pour le client : si son équipe Vault monte un `userpass` de secours
# (compte break-glass local), les comptes en UPN ou DOMAIN\user y sont IMPOSSIBLES.
# Le format de login contraint donc le choix du backend d'auth. D'où la question #3
# du runbook client.
LAB_ALICE_DOMAIN_USER='CORP\alice'
LAB_ALICE_UPN_USER='alice@corp.example'

# oscar — OPÉRATEUR DE MISE EN PROD. Périmètre DIFFÉRENT des déployeurs de tenant :
# Jenkinsfile.prod/.rollback lisent des secrets de PLATEFORME (stoa/ci,
# stoa/opensearch, stoa/gateways/*), hors de toute policy deploy-<tenant>. D'où une
# policy distincte, `operator-deploy`. Qu'un HUMAIN ait le droit de lire ces secrets
# est une DÉCISION CLIENT (ADR-078 § Décisions n°9) : ici c'est un choix de lab,
# volontairement porté par un compte et un groupe SÉPARÉS pour que la question reste
# visible plutôt que diluée dans le périmètre des déployeurs.
LAB_OSCAR_USER='oscar'

LAB_TENANT_ALICE='banking-demo'
LAB_TENANT_BOB='payments-team'

# Vecteur de test d'INJECTION, pas un secret — et le mot de passe d'aucun compte.
# Métacaractères VOLONTAIRES : guillemet, antislash, dollar, apostrophe,
# point-virgule, esperluette, accolades. Un corps JSON forgé à la main en shell
# (`-d "{\"password\":\"$P\"}"`) casse ou s'injecte là-dessus ; c'est la raison
# d'être du json.dumps dans ci/lib/vault-login.sh.
# $'…' = quoting ANSI-C : \\ -> \ , \' -> ' , et $dollar reste LITTÉRAL.
LAB_BOB_PASS_METACHARS=$'B0b "q" \\back $dollar \'sq\' ;semi &amp {brace}'
```

Le bloc `oscar` était **dupliqué à l'identique** dans la version précédente (commentaire de six lignes et affectations, deux fois). Cette réécriture le dédoublonne.

- [ ] **Étape 4 : relancer la garde et vérifier qu'elle passe**

```bash
poc-control-plane-federation/scripts/check-no-plaintext-secrets.sh
```

Attendu : `OK — aucune affectation de secret littéral`.

Puis vérifier que le fichier reste sourçable et que la variable de test survit :

```bash
bash -c '. poc-control-plane-federation/scripts/lib/lab-vault-users.sh
         printf "users: %s %s %s %s\n" "$LAB_ALICE_USER" "$LAB_BOB_USER" "$LAB_CAROL_USER" "$LAB_OSCAR_USER"
         printf "formats: %s | %s\n" "$LAB_ALICE_DOMAIN_USER" "$LAB_ALICE_UPN_USER"
         printf "tenants: %s %s\n" "$LAB_TENANT_ALICE" "$LAB_TENANT_BOB"
         printf "metachars long: %s\n" "${#LAB_BOB_PASS_METACHARS}"'
```

Attendu : les quatre noms, les deux formats, les deux tenants, et `metachars long: 47`.

- [ ] **Étape 5 : vérifier qu'aucun appelant ne casse en silence**

```bash
grep -rn "LAB_ALICE_PASS\|LAB_BOB_PASS\b\|LAB_CAROL_PASS\|LAB_OSCAR_PASS\|LAB_BOB_PASS_DEFAULT" \
  --include="*.sh" --include="*.yml" --include="*.md" . | grep -v check-no-plaintext-secrets
```

Chaque occurrence trouvée est un appelant à traiter. Attendu : les références dans `setup-vault-userpass.sh` et `test-vault-user-login.sh`. Pour chacune, remplacer la lecture directe par une lecture avec repli qui **saute** au lieu d'échouer :

```sh
# Avant : LAB_ALICE_PASS provenait de lab-vault-users.sh
# Après : il provient du fichier root-only, absent sur un poste de développement.
: "${LAB_ALICE_PASS:=}"
if [ -z "$LAB_ALICE_PASS" ]; then
  skip "alice — mot de passe absent (fichier root-only non monté)"
else
  # … assertions inchangées …
fi
```

Ne pas modifier la logique des assertions : seule leur garde d'entrée change.

- [ ] **Étape 6 : commit**

```bash
git add poc-control-plane-federation/scripts/lib/lab-vault-users.sh \
        poc-control-plane-federation/scripts/check-no-plaintext-secrets.sh \
        poc-control-plane-federation/scripts/setup-vault-userpass.sh \
        poc-control-plane-federation/scripts/test-vault-user-login.sh
git commit -m "fix(vault): purge les mots de passe de lab-vault-users.sh — dépôt public

Les quatre valeurs (LAB_ALICE/BOB/CAROL/OSCAR_PASS) sont publiques depuis le
passage du dépôt en public et donc brûlées. Elles sortent du fichier, qui ne garde
que les noms, les formats de login et les tenants. Pas de réécriture d'historique :
elle casse tous les clones pour un bénéfice illusoire sur un dépôt déjà copiable —
la mesure qui protège est de ne jamais réutiliser ces valeurs.

LAB_BOB_PASS renommé LAB_BOB_PASS_METACHARS et CONSERVÉ : c'est un vecteur de test
d'injection (guillemet, antislash, dollar), pas le mot de passe d'un compte.

Ajoute check-no-plaintext-secrets.sh, garde qui échoue si une affectation de secret
littéral réapparaît, et qui rédige les valeurs qu'elle signale.

Dédoublonne le bloc oscar, présent deux fois à l'identique.

Les appelants sautent (skip) au lieu d'échouer quand le mot de passe est absent :
sur un poste sans le fichier root-only, les tests ne mentent pas, ils s'abstiennent."
```

---

### Tâche 2 : OpenLDAP dans le cluster

**Fichiers :**
- Créer : `deploy/bootstrap/ci/openldap/deployment.yaml`
- Créer : `deploy/bootstrap/ci/openldap/service.yaml`
- Créer : `deploy/bootstrap/ci/openldap/kustomization.yaml`
- Créer : `deploy/bootstrap/argocd/app-ci-openldap.yaml`

**Interfaces :**
- Produit : un Service `openldap.ci.svc.cluster.local:389`, et un `Secret/openldap-admin` (clé `password`) créé **hors Git**.
- Consommé par : tâche 3 (peuplement) et tâche 4 (configuration du mount Vault, qui a besoin du bind).

Pas de PVC, délibérément : l'annuaire est reconstruit par la tâche 3, sa donnée n'a aucune valeur à préserver. Un redémarrage le vide, le script le repeuple. C'est ce qui permet de le traiter comme jetable et de ne jamais sauvegarder un annuaire de démonstration.

- [ ] **Étape 1 : écrire le Deployment**

Créer `deploy/bootstrap/ci/openldap/deployment.yaml` :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openldap
  labels:
    app.kubernetes.io/name: openldap
    app.kubernetes.io/part-of: stoa-lab
spec:
  # Un seul réplica : sans volume partagé, deux réplicas serviraient deux annuaires
  # divergents. L'annuaire est jetable, sa disponibilité n'est pas un enjeu.
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: openldap
  template:
    metadata:
      labels:
        app.kubernetes.io/name: openldap
        app.kubernetes.io/part-of: stoa-lab
    spec:
      affinity:
        nodeAffinity:
          # worker-3 est prévu pour extinction en F5 : rien de nouveau ne s'y pose.
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: NotIn
                    values: ["worker-3"]
      containers:
        - name: openldap
          # osixia/openldap:1.5.0 — épinglée par digest (un tag est mutable).
          image: osixia/openldap@sha256:18742e9c449c9c1afe129d3f2f3ee15fb34cc43e5f940a20f3399728f41d7c28
          # --copy-service : sans lui, l'image n'applique pas son arbre de travail
          # correctement. Repris tel quel du docker-compose.ldap.yml éprouvé.
          args: ["--copy-service", "--loglevel", "warning"]
          env:
            - name: LDAP_ORGANISATION
              value: "Banque Demo"
            - name: LDAP_DOMAIN
              value: "corp.example"
            - name: LDAP_BASE_DN
              value: "dc=corp,dc=example"
            # TLS désactivé : annuaire de démonstration interne au cluster, en
            # ClusterIP, jamais publié. Chez le client c'est un AD en LDAPS, et
            # rien de ce manifeste n'est livré.
            - name: LDAP_TLS
              value: "false"
            - name: LDAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  # HORS GIT — créé à part. Voir l'étape 4 de cette tâche.
                  name: openldap-admin
                  key: password
          ports:
            - name: ldap
              containerPort: 389
          readinessProbe:
            tcpSocket:
              port: ldap
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: ldap
            initialDelaySeconds: 30
            periodSeconds: 30
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
```

La sonde est un `tcpSocket` et non un `ldapsearch` : le healthcheck du compose passait le mot de passe d'admin en argument de commande, visible dans la table des processus. Ici le mot de passe vient d'un Secret et ne doit pas ressortir dans une sonde.

- [ ] **Étape 2 : écrire le Service et la kustomization**

Créer `deploy/bootstrap/ci/openldap/service.yaml` :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: openldap
  labels:
    app.kubernetes.io/name: openldap
    app.kubernetes.io/part-of: stoa-lab
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: openldap
  ports:
    - name: ldap
      port: 389
      targetPort: ldap
```

Créer `deploy/bootstrap/ci/openldap/kustomization.yaml` :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Le namespace `ci` existe déjà (gitea, jenkins, vault) : on ne le crée pas ici.
namespace: ci

resources:
  - deployment.yaml
  - service.yaml
```

- [ ] **Étape 3 : écrire l'Application Argo et vérifier la construction**

Créer `deploy/bootstrap/argocd/app-ci-openldap.yaml` :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ci-openldap
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  # Projet `default` et non `stoa` : l'AppProject `stoa` restreint ses sources au
  # dépôt stoa. Montage validé le 2026-07-30 avec edge/cloudflared.
  project: default
  source:
    # HTTPS anonyme : stoa-labs est public, Argo n'a aucun identifiant de dépôt.
    repoURL: https://github.com/stoa-platform/stoa-labs.git
    targetRevision: main
    path: deploy/bootstrap/ci/openldap
  destination:
    server: https://kubernetes.default.svc
    namespace: ci
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        maxDuration: 3m
        factor: 2
```

Vérifier la construction avant tout déploiement :

```bash
kubectl kustomize "$(pwd)/deploy/bootstrap/ci/openldap" | \
  python3 -c "
import sys,yaml
for d in yaml.safe_load_all(sys.stdin):
    if d: print(d['kind'], d['metadata']['name'], 'ns=' + d['metadata'].get('namespace','(aucun)'))
"
```

Attendu exactement :

```
Deployment openldap ns=ci
Service openldap ns=ci
```

Si un namespace vaut `(aucun)`, la ligne `namespace: ci` de la kustomization manque — corriger avant de continuer.

- [ ] **Étape 4 : créer le Secret hors Git, puis brancher Argo**

Le Secret doit exister **avant** la première synchronisation, sinon le pod démarre en échec. Générer le mot de passe sans jamais l'afficher, et le déposer aussi dans un fichier root-only du nœud pour pouvoir le relire plus tard :

```bash
export KUBECONFIG=~/.kube/k3s-contabo.yaml
P="$(openssl rand -base64 24 | tr -d '\n')"
printf '%s' "$P" | kubectl -n ci create secret generic openldap-admin --from-file=password=/dev/stdin
ssh worker-1 "sudo install -d -m 700 /root/stoa-lab-secrets && \
  sudo tee /root/stoa-lab-secrets/openldap-admin >/dev/null && \
  sudo chmod 600 /root/stoa-lab-secrets/openldap-admin" <<< "$P"
unset P
kubectl -n ci get secret openldap-admin -o go-template='clés : {{range $k,$v := .data}}{{$k}} {{end}}{{"\n"}}'
```

Attendu : `clés : password`. Le mot de passe n'apparaît à aucun moment sur stdout.

Committer et pousser les manifestes, puis appliquer l'Application une fois :

```bash
git add deploy/bootstrap/ci/openldap deploy/bootstrap/argocd/app-ci-openldap.yaml
git commit -m "feat(lab): OpenLDAP jetable en ns ci pour éprouver la voie A

Annuaire de démonstration, image épinglée par digest, sans PVC : sa donnée est
reconstruite par seed-ldap-cluster.sh, elle n'a aucune valeur à préserver. Un seul
réplica — sans volume partagé, deux réplicas serviraient deux annuaires divergents.

Valeurs identiques au docker-compose.ldap.yml éprouvé (dc=corp,dc=example,
corp.example, userattr=uid) pour que les deux mondes restent comparables.

Sonde tcpSocket et non ldapsearch : le healthcheck du compose passait le mot de
passe d'admin en argument de commande, donc visible dans la table des processus.

Le Secret openldap-admin est créé hors Git. Anti-affinité worker-3 (extinction F5)."
git push origin main
kubectl apply -f deploy/bootstrap/argocd/app-ci-openldap.yaml
```

- [ ] **Étape 5 : vérifier que l'annuaire répond, par relecture**

```bash
export KUBECONFIG=~/.kube/k3s-contabo.yaml
for i in $(seq 1 18); do
  s=$(kubectl -n argocd get application ci-openldap -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  p=$(kubectl -n ci get pods -l app.kubernetes.io/name=openldap --no-headers 2>/dev/null | awk '{print $2, $3}')
  echo "t+$((i*10))s  argo=$s  pod=$p"
  [ "$s" = "Synced/Healthy" ] && echo "$p" | grep -q "1/1 Running" && break
  sleep 10
done
kubectl -n ci get pods -l app.kubernetes.io/name=openldap -o wide
```

Attendu : `Synced/Healthy`, pod `1/1 Running`, et **pas sur worker-3**.

Puis prouver que l'annuaire sert vraiment son arbre — un pod `Running` ne le prouve pas :

```bash
kubectl -n ci exec deploy/openldap -- sh -c '
  ldapsearch -x -H ldap://localhost:389 -b "dc=corp,dc=example" -s base -LLL dn'
```

Attendu : `dn: dc=corp,dc=example`. Cet appel est anonyme et ne demande donc aucun mot de passe.

- [ ] **Étape 6 : commit du constat**

Rien à committer si les étapes précédentes l'ont déjà été. Consigner le résultat dans le message de la tâche suivante plutôt que de créer un commit vide.

---

### Tâche 3 : peupler l'annuaire du cluster

**Fichiers :**
- Créer : `poc-control-plane-federation/scripts/seed-ldap-cluster.sh`

**Interfaces :**
- Consomme : `scripts/lib/lab-vault-users.sh` (tâche 1) pour les noms, formats et tenants ; le Service `openldap.ci` et le Secret `openldap-admin` (tâche 2).
- Produit : dans l'annuaire, `ou=People` et `ou=Groups`, les utilisateurs `alice`, `bob`, `carol`, `oscar`, et les groupes `banking-demo`, `payments-team`, `operators`. Écrit les mots de passe générés dans `/root/stoa-lab-secrets/lab-vault-users.env` sur worker-1.

Les mots de passe sont **générés ici**, pas dans la tâche 4 : c'est l'annuaire qui les détient, Vault ne fait que les vérifier par bind. La tâche 4 n'a besoin d'aucun mot de passe utilisateur.

- [ ] **Étape 1 : écrire le script**

Créer `poc-control-plane-federation/scripts/seed-ldap-cluster.sh` :

```sh
#!/bin/sh
# seed-ldap-cluster.sh — peuple l'annuaire de démonstration DU CLUSTER (ns ci).
#
# Pendant cluster de setup-vault-ldap.sh, qui visait le conteneur compose. Même
# arbre, mêmes noms, mêmes tenants : les deux mondes restent comparables.
#
# IDEMPOTENT : ldapadd renvoie 68 (« Already exists ») en re-run, ce qui est le cas
# NOMINAL et non une erreur. `-c` (continue) ajoute les entrées nouvelles et ignore
# les existantes.
#
# Les mots de passe sont GÉNÉRÉS ici et déposés dans un fichier root-only du nœud.
# Ils ne passent jamais par argv (visible dans ps) ni par stdout.
#
# Usage : depuis la racine de poc-control-plane-federation, kubeconfig du cluster.
#   KUBECONFIG=~/.kube/k3s-contabo.yaml sh scripts/seed-ldap-cluster.sh
set -eu

NS="${LDAP_NS:-ci}"
DEPLOY="${LDAP_DEPLOY:-deploy/openldap}"
BASE_DN="${LDAP_BASE_DN:-dc=corp,dc=example}"
BIND_DN="${LDAP_BIND_DN:-cn=admin,$BASE_DN}"
SECRETS_HOST="${SECRETS_HOST:-worker-1}"
SECRETS_DIR="${SECRETS_DIR:-/root/stoa-lab-secrets}"

. "$(dirname "$0")/lib/lab-vault-users.sh"

say() { printf '  %s\n' "$1"; }
die() { printf 'ÉCHEC : %s\n' "$1" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl absent"
kubectl -n "$NS" get "$DEPLOY" >/dev/null 2>&1 || die "$DEPLOY absent dans $NS (tâche 2 non faite ?)"

# Le mot de passe de bind est lu depuis le Secret et gardé en variable, jamais en argv.
BIND_PW="$(kubectl -n "$NS" get secret openldap-admin -o go-template='{{index .data "password" | base64decode}}')"
[ -n "$BIND_PW" ] || die "Secret openldap-admin illisible ou vide"

# ldap_apply <ldif> — envoie le LDIF par STDIN ; le mot de passe part par STDIN de
# ldapadd via -y /dev/stdin ? Non : osixia n'expose pas -y de façon fiable. On passe
# donc par un fichier temporaire DANS le conteneur, en mode 600, supprimé aussitôt.
ldap_apply() {
  kubectl -n "$NS" exec -i "$DEPLOY" -- sh -c '
    umask 077
    PWF=$(mktemp)
    head -n 1 > "$PWF"          # 1re ligne de stdin = mot de passe de bind
    cat > /tmp/seed.ldif        # le reste = LDIF
    ldapadd -x -D "'"$BIND_DN"'" -y "$PWF" -c -f /tmp/seed.ldif 2>&1
    RC=$?
    rm -f "$PWF" /tmp/seed.ldif
    exit $RC
  ' 2>&1 || true                # 68 « Already exists » est nominal, on filtre ensuite
}

# Génère un mot de passe robuste sans métacaractères de shell (les métacaractères
# sont testés séparément, par LAB_BOB_PASS_METACHARS).
genpw() { openssl rand -base64 27 | tr -d '\n=+/' | cut -c1-24; }

A_PW="$(genpw)"; C_PW="$(genpw)"; O_PW="$(genpw)"
# bob porte VOLONTAIREMENT le vecteur à métacaractères : c'est son invariant.
B_PW="$LAB_BOB_PASS_METACHARS"

printf 'peuplement de %s dans %s/%s\n' "$BASE_DN" "$NS" "$DEPLOY"

{
  printf '%s\n' "$BIND_PW"
  cat <<LDIF
dn: ou=People,$BASE_DN
objectClass: organizationalUnit
ou: People

dn: ou=Groups,$BASE_DN
objectClass: organizationalUnit
ou: Groups

dn: uid=$LAB_ALICE_USER,ou=People,$BASE_DN
objectClass: inetOrgPerson
uid: $LAB_ALICE_USER
cn: $LAB_ALICE_USER
sn: $LAB_ALICE_USER
userPassword: $A_PW

dn: uid=$LAB_BOB_USER,ou=People,$BASE_DN
objectClass: inetOrgPerson
uid: $LAB_BOB_USER
cn: $LAB_BOB_USER
sn: $LAB_BOB_USER
userPassword: $B_PW

dn: uid=$LAB_CAROL_USER,ou=People,$BASE_DN
objectClass: inetOrgPerson
uid: $LAB_CAROL_USER
cn: $LAB_CAROL_USER
sn: $LAB_CAROL_USER
userPassword: $C_PW

dn: uid=$LAB_OSCAR_USER,ou=People,$BASE_DN
objectClass: inetOrgPerson
uid: $LAB_OSCAR_USER
cn: $LAB_OSCAR_USER
sn: $LAB_OSCAR_USER
userPassword: $O_PW

dn: cn=$LAB_TENANT_ALICE,ou=Groups,$BASE_DN
objectClass: groupOfNames
cn: $LAB_TENANT_ALICE
member: uid=$LAB_ALICE_USER,ou=People,$BASE_DN

dn: cn=$LAB_TENANT_BOB,ou=Groups,$BASE_DN
objectClass: groupOfNames
cn: $LAB_TENANT_BOB
member: uid=$LAB_BOB_USER,ou=People,$BASE_DN

dn: cn=operators,ou=Groups,$BASE_DN
objectClass: groupOfNames
cn: operators
member: uid=$LAB_OSCAR_USER,ou=People,$BASE_DN
LDIF
} | ldap_apply | grep -viE "already exists|adding new entry" || true

# Dépôt des mots de passe dans le fichier root-only du nœud. Jamais sur stdout.
{
  printf '# lab-vault-users — mots de passe générés le %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# Régénérés à chaque passe de seed-ldap-cluster.sh. Ne pas versionner.\n'
  printf "LAB_ALICE_PASS=%s\n" "$A_PW"
  printf "LAB_CAROL_PASS=%s\n" "$C_PW"
  printf "LAB_OSCAR_PASS=%s\n" "$O_PW"
  printf '# bob porte le vecteur à métacaractères de lab-vault-users.sh (public, non secret).\n'
} | ssh "$SECRETS_HOST" "sudo install -d -m 700 $SECRETS_DIR && \
      sudo tee $SECRETS_DIR/lab-vault-users.env >/dev/null && \
      sudo chmod 600 $SECRETS_DIR/lab-vault-users.env"

unset A_PW C_PW O_PW B_PW BIND_PW

say "utilisateurs et groupes poussés"
say "mots de passe dans $SECRETS_HOST:$SECRETS_DIR/lab-vault-users.env (root, 600)"
```

- [ ] **Étape 2 : lancer le script et vérifier par relecture**

```bash
chmod +x poc-control-plane-federation/scripts/seed-ldap-cluster.sh
export KUBECONFIG=~/.kube/k3s-contabo.yaml
cd poc-control-plane-federation && sh scripts/seed-ldap-cluster.sh; cd ..
```

Vérifier ensuite l'arbre, sans faire confiance au code de retour :

```bash
kubectl -n ci exec deploy/openldap -- sh -c '
  ldapsearch -x -H ldap://localhost:389 -b "dc=corp,dc=example" -LLL "(objectClass=inetOrgPerson)" uid'
```

Attendu : `uid: alice`, `uid: bob`, `uid: carol`, `uid: oscar` — quatre entrées.

```bash
kubectl -n ci exec deploy/openldap -- sh -c '
  ldapsearch -x -H ldap://localhost:389 -b "ou=Groups,dc=corp,dc=example" -LLL "(objectClass=groupOfNames)" cn member'
```

Attendu : trois groupes, `banking-demo` contenant `alice`, `payments-team` contenant `bob`, `operators` contenant `oscar`.

- [ ] **Étape 3 : prouver l'idempotence**

Relancer le script à l'identique :

```bash
cd poc-control-plane-federation && sh scripts/seed-ldap-cluster.sh; cd ..
```

Attendu : aucune erreur, sortie identique. Puis recompter les utilisateurs :

```bash
kubectl -n ci exec deploy/openldap -- sh -c '
  ldapsearch -x -H ldap://localhost:389 -b "dc=corp,dc=example" -LLL "(objectClass=inetOrgPerson)" uid' | grep -c "^uid:"
```

Attendu : `4`. Un nombre supérieur signalerait des doublons, donc une non-idempotence.

- [ ] **Étape 4 : vérifier qu'un bind utilisateur fonctionne**

C'est le préalable de tout le lot : si le bind échoue, Vault ne pourra pas authentifier.

```bash
ssh worker-1 "sudo cat /root/stoa-lab-secrets/lab-vault-users.env" | \
  grep '^LAB_ALICE_PASS=' | cut -d= -f2- | \
  kubectl -n ci exec -i deploy/openldap -- sh -c '
    umask 077; PWF=$(mktemp); cat > "$PWF"
    ldapwhoami -x -H ldap://localhost:389 -D "uid=alice,ou=People,dc=corp,dc=example" -y "$PWF"
    RC=$?; rm -f "$PWF"; exit $RC'
```

Attendu : `dn:uid=alice,ou=people,dc=corp,dc=example`. Le mot de passe transite par STDIN, jamais par argv.

- [ ] **Étape 5 : commit**

```bash
git add poc-control-plane-federation/scripts/seed-ldap-cluster.sh
git commit -m "feat(vault): peuplement de l'annuaire du cluster, idempotent

Pendant cluster de setup-vault-ldap.sh : mêmes noms, mêmes tenants, même arbre que
le POC compose, pour que les deux mondes restent comparables.

Les mots de passe sont GÉNÉRÉS ici — c'est l'annuaire qui les détient, Vault ne fait
que les vérifier par bind — et déposés dans un fichier root-only de worker-1. Ils ne
passent ni par argv (visible dans ps) ni par stdout.

bob porte volontairement le vecteur à métacaractères : c'est son invariant de preuve.

Idempotence prouvée par recomptage après second passage (4 utilisateurs, pas 8) :
ldapadd renvoie 68 « Already exists », qui est le cas nominal et non une erreur.

Bind utilisateur vérifié par ldapwhoami — sans lui, rien du lot A ne peut marcher."
```

---

### Tâche 4 : configurer Vault (script exploitant, quorum 2/3)

**Fichiers :**
- Créer : `docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh`

**Interfaces :**
- Consomme : le Service `openldap.ci.svc.cluster.local:389`, le Secret `openldap-admin` (tâche 2), l'arbre peuplé (tâche 3).
- Produit : les mounts `auth/userpass` et `auth/ldap`, les policies `deploy-banking-demo`, `deploy-payments-team`, `operator-deploy`, le mapping groupe→policy, et les secrets KV lus par les pipelines.

**Ce script n'est pas exécuté par un agent.** Il exige deux clés de descellement, détenues hors ligne par l'exploitant. La tâche consiste à l'écrire, à le faire relire, puis à demander son exécution.

- [ ] **Étape 1 : écrire le script**

Créer `docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh` :

```sh
#!/bin/sh
# Lot A — configuration de Vault pour la voie A. À exécuter DANS vault-0, PAR
# L'EXPLOITANT :
#   $1, $2 = deux clés de descellement (quorum 2/3) — jamais affichées ;
#   $3     = mot de passe de bind de l'annuaire (Secret openldap-admin).
#
# Active auth/userpass et auth/ldap, écrit les policies deploy-<tenant> et
# operator-deploy, configure le mount ldap et le mapping groupe -> policy.
# IDEMPOTENT : rejouable sans effet de bord.
#
# Jeton racine ÉPHÉMÈRE par quorum, révoqué en sortie — même motif que
# 2026-07-29-f4-vault-role-toggle.sh.
#
# Usage (poste opérateur, racine stoa-labs) :
#   scp docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh worker-1:/tmp/la.sh
#   ssh -t worker-1 'BP=$(sudo cat /root/stoa-lab-secrets/openldap-admin); \
#     sudo k3s kubectl -n ci exec -i vault-0 -- sh -c "cat > /tmp/la.sh && chmod 700 /tmp/la.sh" < /tmp/la.sh; \
#     read -r -s -p "Cle de descellement 1/2 : " K1; echo; \
#     read -r -s -p "Cle de descellement 2/2 : " K2; echo; \
#     sudo k3s kubectl -n ci exec vault-0 -- sh /tmp/la.sh "$K1" "$K2" "$BP"; \
#     unset K1 K2 BP; \
#     sudo k3s kubectl -n ci exec vault-0 -- rm -f /tmp/la.sh; rm -f /tmp/la.sh'
set -eu
K1="$1"; K2="$2"; BIND_PW="$3"

BASE_DN="dc=corp,dc=example"
LDAP_URL="ldap://openldap.ci.svc.cluster.local:389"

echo "etape 1/6 : jeton racine ephemere par quorum…"
vault operator generate-root -cancel >/dev/null 2>&1 || true
INIT=$(vault operator generate-root -init -format=json)
NONCE=$(echo "$INIT" | sed -n 's/.*"nonce": *"\([^"]*\)".*/\1/p')
OTP=$(echo "$INIT" | sed -n 's/.*"otp": *"\([^"]*\)".*/\1/p')
vault operator generate-root -nonce="$NONCE" "$K1" >/dev/null
ENC=$(vault operator generate-root -nonce="$NONCE" "$K2" -format=json \
      | sed -n 's/.*"encoded_token": *"\([^"]*\)".*/\1/p')
VAULT_TOKEN=$(vault operator generate-root -decode="$ENC" -otp="$OTP")
export VAULT_TOKEN
unset K1 K2 INIT NONCE OTP ENC
trap 'vault token revoke -self >/dev/null 2>&1 || true' EXIT INT TERM

echo "etape 2/6 : mounts d'authentification…"
vault auth enable userpass 2>/dev/null || echo "  userpass deja actif"
vault auth enable ldap     2>/dev/null || echo "  ldap deja actif"

echo "etape 3/6 : policies…"
for T in banking-demo payments-team; do
  vault policy write "deploy-$T" - <<POL
# Déployeur du tenant $T. Lecture des identifiants de la gateway et des
# paramètres OAuth2 ; écriture sur apps/* pour le mode `internal` (le client
# OAuth2 généré y est rangé).
path "secret/data/deploy/$T/*"     { capabilities = ["read"] }
path "secret/metadata/deploy/$T/*" { capabilities = ["read", "list"] }
path "secret/data/apps/$T/*"       { capabilities = ["create", "update", "read"] }
path "secret/metadata/apps/$T/*"   { capabilities = ["read", "list"] }
POL
  echo "  deploy-$T"
done

vault policy write operator-deploy - <<'POL'
# Opérateur de mise en production. Périmètre DIFFÉRENT des déployeurs de tenant :
# lit des secrets de PLATEFORME, hors de toute policy deploy-<tenant>. Qu'un HUMAIN
# ait ce droit est une DÉCISION CLIENT (ADR-078 § Décisions n°9) ; ici c'est un choix
# de lab, porté par un compte et un groupe séparés pour que la question reste visible.
path "secret/data/stoa/*"     { capabilities = ["read"] }
path "secret/metadata/stoa/*" { capabilities = ["read", "list"] }
POL
echo "  operator-deploy"

echo "etape 4/6 : configuration du mount ldap…"
# binddn/bindpass : le compte de service qui a le droit de CHERCHER dans l'annuaire.
# userdn/userattr : où et sous quel attribut trouver l'utilisateur. Chez le client
#   (AD) ce sera userattr=sAMAccountName, ou upndomain=corp.example pour un UPN.
# groupfilter par défaut : recherche inverse (quels groupes ont ce membre). Il ne
#   résout PAS les groupes imbriqués — dette notée dans la spéc.
vault write auth/ldap/config \
  url="$LDAP_URL" \
  binddn="cn=admin,$BASE_DN" \
  bindpass="$BIND_PW" \
  userdn="ou=People,$BASE_DN" \
  userattr="uid" \
  groupdn="ou=Groups,$BASE_DN" \
  groupattr="cn" \
  insecure_tls=true \
  starttls=false >/dev/null
unset BIND_PW
echo "  url=$LDAP_URL userdn=ou=People,$BASE_DN userattr=uid"

echo "etape 5/6 : mapping groupe -> policy…"
vault write auth/ldap/groups/banking-demo  policies=deploy-banking-demo  >/dev/null
vault write auth/ldap/groups/payments-team policies=deploy-payments-team >/dev/null
vault write auth/ldap/groups/operators     policies=operator-deploy      >/dev/null
echo "  banking-demo, payments-team, operators"

echo "etape 6/6 : secrets KV lus par les pipelines…"
# Valeurs de LAB : la gateway du cluster est en ClusterIP, non publiée.
vault kv put secret/deploy/banking-demo/wm-admin \
  username=Administrator password=manage >/dev/null
vault kv put secret/deploy/payments-team/wm-admin \
  username=Administrator password=manage >/dev/null
echo "  secret/deploy/<tenant>/wm-admin"

echo
echo "RELECTURE (ce qui suit est l'etat REEL, pas un code de retour) :"
vault auth list -format=json | sed -n 's/.*"\(userpass\|ldap\)\/".*/  mount actif : \1/p'
echo "  policies : $(vault policy list | tr '\n' ' ')"
echo "  groupes  : $(vault list -format=json auth/ldap/groups | tr -d '[]" ,\n')"
echo
echo "Termine. Le jeton racine ephemere est revoque a la sortie."
```

- [ ] **Étape 2 : vérifier la syntaxe sans exécuter**

```bash
sh -n docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh && echo "syntaxe OK"
command -v shellcheck >/dev/null && shellcheck -s sh docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh || echo "(shellcheck absent, contrôle sauté)"
```

Attendu : `syntaxe OK`. Ne pas exécuter le script : il exige les clés de descellement.

- [ ] **Étape 3 : commit, puis demander l'exécution à l'exploitant**

```bash
git add docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh
git commit -m "feat(vault): script exploitant — mounts, policies et mapping pour la voie A

Active auth/userpass et auth/ldap, écrit deploy-<tenant> et operator-deploy,
configure le mount ldap sur openldap.ci et lie groupe -> policy. Idempotent.

Jeton racine éphémère par quorum 2/3, révoqué par trap en sortie, clés jamais
affichées — même motif que 2026-07-29-f4-vault-role-toggle.sh. Aucun agent ne peut
l'exécuter : les clés sont hors ligne, c'est délibéré.

Se termine par une RELECTURE de l'état (mounts, policies, groupes) plutôt que par
un code de retour : sur ce projet, un 200 a déjà menti (gateway, champ owner,
2026-07-29)."
git push origin main
```

Puis **arrêter et demander à l'exploitant** de dérouler le bloc `Usage` en tête du script. Ne pas passer à la tâche 5 avant d'avoir vu la relecture finale afficher les deux mounts, les trois policies et les trois groupes.

---

### Tâche 5 : harnais de preuve depuis un pod, avec contre-épreuves

**Fichiers :**
- Créer : `poc-control-plane-federation/scripts/test-voie-a-cluster.sh`

**Interfaces :**
- Consomme : `scripts/lib/lab-vault-users.sh` (tâche 1) ; le fichier root-only `lab-vault-users.env` (tâche 3) ; les mounts, policies et secrets KV (tâche 4).
- Produit : la preuve de la porte A et de ses cinq contre-épreuves.

Le harnais reprend les conventions de `test-vault-user-login.sh` : `ok()`, `bad()`, `skip()`, `sec()`, compteurs `PASS`/`FAIL`/`SKIP`. Il s'exécute **dans un pod du cluster**, seul endroit où la résolution DNS, le réseau et les policies sont éprouvés en conditions réelles.

- [ ] **Étape 1 : écrire le harnais**

Créer `poc-control-plane-federation/scripts/test-voie-a-cluster.sh` :

```sh
#!/bin/sh
# test-voie-a-cluster.sh — PORTE A et ses contre-épreuves, exécuté DANS un pod.
#
# Un login qui réussit ne prouve rien seul : ce sont les REFUS attendus qui font la
# preuve. Cinq contre-épreuves : mauvais mot de passe, cross-tenant, jeton révoqué,
# formats de login, et le piège userpass vs ldap.
#
# Usage : injecté dans un pod par le script appelant (voir l'étape 2). Attend en
# variables d'environnement : VAULT_ADDR, LAB_ALICE_PASS, LAB_CAROL_PASS.
set -u

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗ %s\033[0m\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33m- %s (sauté)\033[0m\n' "$1"; SKIP=$((SKIP+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

V="${VAULT_ADDR:-http://vault.ci.svc.cluster.local:8200}"

# login <mount> <user> <password> -> imprime le jeton, ou rien ; code de retour = HTTP
login() {
  _m="$1"; _u="$2"; _p="$3"
  _body=$(python3 -c 'import json,sys; print(json.dumps({"password": sys.argv[1]}))' "$_p")
  _u_enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$_u")
  _out=$(printf '%s' "$_body" | curl -s -o /tmp/l.json -w '%{http_code}' -m 15 \
           -X POST --data-binary @- "$V/v1/auth/$_m/login/$_u_enc")
  if [ "$_out" = "200" ]; then
    python3 -c 'import json;print(json.load(open("/tmp/l.json"))["auth"]["client_token"])'
  fi
  rm -f /tmp/l.json
  echo "$_out" >/tmp/l.code
  [ "$_out" = "200" ]
}
lastcode() { cat /tmp/l.code 2>/dev/null; }

# vread <jeton> <chemin> -> code HTTP
vread() {
  curl -s -o /dev/null -w '%{http_code}' -m 15 -H "X-Vault-Token: $1" "$V/v1/$2"
}

sec "0. Vault joignable depuis ce pod"
C=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$V/v1/sys/health")
case "$C" in 200|429|472|473) ok "sys/health -> $C" ;; *) bad "sys/health -> $C (Vault injoignable)"; ;; esac

sec "1. PORTE A — login nominatif par ldap, puis lecture d'un secret"
if [ -z "${LAB_ALICE_PASS:-}" ]; then
  skip "alice — mot de passe absent de l'environnement"
else
  TOK=$(login ldap alice "$LAB_ALICE_PASS") && ok "login ldap/alice -> 200" \
    || bad "login ldap/alice -> $(lastcode)"
  if [ -n "${TOK:-}" ]; then
    C=$(vread "$TOK" "secret/data/deploy/banking-demo/wm-admin")
    [ "$C" = "200" ] && ok "lecture wm-admin de banking-demo -> 200" \
                     || bad "lecture wm-admin -> $C (policy absente ?)"
  fi
fi

sec "2. CONTRE-ÉPREUVE — mauvais mot de passe : échec FERMÉ"
if login ldap alice "ceci-nest-pas-le-mot-de-passe"; then
  bad "un mauvais mot de passe a été ACCEPTÉ"
else
  C=$(lastcode)
  case "$C" in 400|401|403) ok "mauvais mot de passe -> $C, aucun jeton émis" ;;
               *) bad "mauvais mot de passe -> $C (attendu 400/401/403)" ;; esac
fi

sec "3. CONTRE-ÉPREUVE — cross-tenant : login OK, lecture 403"
# bob porte le vecteur à métacaractères : ce test prouve AUSSI que le corps JSON
# résiste aux guillemets, antislashs et dollars.
BOB_PW='B0b "q" \back $dollar '"'"'sq'"'"' ;semi &amp {brace}'
TOKB=$(login ldap bob "$BOB_PW") && ok "login ldap/bob -> 200 (mot de passe à métacaractères)" \
  || bad "login ldap/bob -> $(lastcode) — le corps JSON casse sur les métacaractères ?"
if [ -n "${TOKB:-}" ]; then
  C=$(vread "$TOKB" "secret/data/deploy/banking-demo/wm-admin")
  [ "$C" = "403" ] && ok "bob sur banking-demo -> 403 (ségrégation par policy)" \
                   || bad "bob sur banking-demo -> $C (ATTENDU 403 — fuite inter-tenant)"
  C=$(vread "$TOKB" "secret/data/deploy/payments-team/wm-admin")
  [ "$C" = "200" ] && ok "bob sur son propre tenant -> 200" \
                   || bad "bob sur payments-team -> $C"
fi

sec "4. CONTRE-ÉPREUVE — authentifié sans policy de déploiement"
if [ -z "${LAB_CAROL_PASS:-}" ]; then
  skip "carol — mot de passe absent de l'environnement"
else
  TOKC=$(login ldap carol "$LAB_CAROL_PASS") && ok "login ldap/carol -> 200" \
    || bad "login ldap/carol -> $(lastcode)"
  if [ -n "${TOKC:-}" ]; then
    C=$(vread "$TOKC" "secret/data/deploy/banking-demo/wm-admin")
    [ "$C" = "403" ] && ok "carol -> 403 (authentifiée n'est pas autorisée)" \
                     || bad "carol -> $C (ATTENDU 403)"
  fi
fi

sec "5. CONTRE-ÉPREUVE — jeton révoqué : la lecture cesse"
if [ -n "${TOK:-}" ]; then
  curl -s -o /dev/null -m 15 -H "X-Vault-Token: $TOK" -X POST "$V/v1/auth/token/revoke-self"
  C=$(vread "$TOK" "secret/data/deploy/banking-demo/wm-admin")
  [ "$C" = "403" ] && ok "jeton révoqué -> 403 (preuve de mort)" \
                   || bad "jeton révoqué -> $C (ATTENDU 403 — la révocation est cosmétique)"
else
  skip "révocation — pas de jeton d'alice"
fi

sec "6. CONTRE-ÉPREUVE — formats de login, et le piège userpass"
if [ -z "${LAB_ALICE_PASS:-}" ]; then
  skip "formats — mot de passe d'alice absent"
else
  for U in 'CORP\alice' 'alice@corp.example'; do
    if login ldap "$U" "$LAB_ALICE_PASS" >/dev/null; then
      ok "ldap accepte le format $U"
    else
      C=$(lastcode)
      case "$C" in 400|401|403) ok "ldap atteint le bind pour $U (-> $C, l'annuaire ne connaît pas cet alias)" ;;
                   *) bad "ldap sur $U -> $C (attendu : la phase de bind est atteinte)" ;; esac
    fi
  done
  # Le piège : userpass REFUSE @ et \ au niveau du PATH, avant tout bind.
  login userpass 'alice@corp.example' "$LAB_ALICE_PASS" >/dev/null || true
  C=$(lastcode)
  case "$C" in 404|500) ok "userpass refuse l'UPN -> $C (le format contraint le backend)" ;;
               *) bad "userpass sur UPN -> $C (attendu 404/500)" ;; esac
fi

printf '\n\033[1mRÉSULTAT : %d réussis, %d échoués, %d sautés\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
```

- [ ] **Étape 2 : le lancer depuis un pod et vérifier qu'il échoue avant la tâche 4**

Si la tâche 4 n'a pas encore été exécutée par l'exploitant, ce lancement **doit** échouer — c'est ce qui prouve que le harnais teste bien quelque chose :

```bash
export KUBECONFIG=~/.kube/k3s-contabo.yaml
A_PW=$(ssh worker-1 "sudo grep '^LAB_ALICE_PASS=' /root/stoa-lab-secrets/lab-vault-users.env" | cut -d= -f2-)
C_PW=$(ssh worker-1 "sudo grep '^LAB_CAROL_PASS=' /root/stoa-lab-secrets/lab-vault-users.env" | cut -d= -f2-)

kubectl -n ci run voie-a-probe --rm -i --restart=Never \
  --image=python:3.12-alpine \
  --env="VAULT_ADDR=http://vault.ci.svc.cluster.local:8200" \
  --env="LAB_ALICE_PASS=$A_PW" --env="LAB_CAROL_PASS=$C_PW" \
  --command -- sh -c 'apk add --no-cache curl >/dev/null 2>&1; cat > /tmp/t.sh; sh /tmp/t.sh' \
  < poc-control-plane-federation/scripts/test-voie-a-cluster.sh
unset A_PW C_PW
```

Attendu **avant** la tâche 4 : le login échoue, plusieurs `✗`, code de sortie non nul. Attendu **après** : `RÉSULTAT : 12 réussis, 0 échoués, 0 sautés`.

Le pod est éphémère (`--rm`), les mots de passe passent par variables d'environnement du pod et non par argv de `kubectl`.

- [ ] **Étape 3 : lancer depuis un agent Jenkins, pas seulement un pod quelconque**

La porte exige le chemin réel du pipeline. Vérifier que le compte de service `jenkins-agent` atteint Vault :

```bash
kubectl -n ci get sa jenkins-agent -o name
kubectl -n ci run voie-a-agent --rm -i --restart=Never \
  --image=python:3.12-alpine --serviceaccount=jenkins-agent \
  --env="VAULT_ADDR=http://vault.ci.svc.cluster.local:8200" \
  --command -- sh -c 'apk add --no-cache curl >/dev/null 2>&1;
    curl -s -o /dev/null -w "sys/health depuis jenkins-agent -> %{http_code}\n" \
      -m 10 http://vault.ci.svc.cluster.local:8200/v1/sys/health'
```

Attendu : `sys/health depuis jenkins-agent -> 200`. Si ce compte de service ne joint pas Vault, la porte ne peut pas être franchie et le problème est réseau, pas Vault.

- [ ] **Étape 4 : commit**

```bash
git add poc-control-plane-federation/scripts/test-voie-a-cluster.sh
git commit -m "test(vault): porte A et ses cinq contre-épreuves, depuis un pod

Un login qui réussit ne prouve rien seul : ce sont les refus attendus qui font la
preuve. Cinq contre-épreuves — mauvais mot de passe (échec fermé), cross-tenant
(login OK mais lecture 403), authentifié sans policy (carol), jeton révoqué
(preuve de mort), formats de login avec le piège userpass qui refuse @ et \\.

Le test de bob sert double : ségrégation par tenant ET résistance du corps JSON aux
métacaractères (guillemet, antislash, dollar), qui est la raison d'être du json.dumps
de ci/lib/vault-login.sh.

Exécuté DANS un pod, seul endroit où DNS, réseau et policies sont éprouvés en
conditions réelles ; puis avec le compte de service jenkins-agent, qui est le chemin
réel du pipeline. Mots de passe par variables d'environnement du pod, jamais dans
argv de kubectl."
```

- [ ] **Étape 5 : consigner la preuve dans la spéc**

Ajouter à `docs/superpowers/specs/2026-07-30-lot-a-vault-voie-a-design.md`, avant la section « Dettes assumées », une section « Preuve d'exécution » portant : la date, le nombre de tests réussis, le nœud d'exécution du pod, et le résultat de chaque contre-épreuve. Committer avec le message `docs(spec): lot A — preuve d'exécution`.

Ne pas écrire cette section avant d'avoir les résultats réels. Une preuve rédigée d'avance n'est pas une preuve.

---

## Auto-relecture du plan

**Couverture de la spéc.** D1 (les deux chemins) — aucune tâche : `vault_login_any` existe déjà et la tâche 4 n'enlève pas le mount kubernetes, donc rien à faire, c'est conforme. D2 (script exploitant, quorum) — tâche 4. D3 (mots de passe générés, fichier root-only) — tâches 2 étape 4 et 3 étape 1. D4 (identités mortes, pas de réécriture d'historique) — tâche 1. D5 (OpenLDAP ns `ci`, sans PVC, compose conservé) — tâche 2 ; `docker-compose.ldap.yml` n'est touché par aucune tâche, donc conservé. D6 (trois formats éprouvés) — tâche 5 section 6. D7 (realm Jenkins hors périmètre) — aucune tâche, conforme à la spéc. Porte et cinq contre-épreuves — tâche 5. La contrainte des 4-5 appels Vault n'ajoute pas de tâche : le plan n'introduit aucun appel supplémentaire.

**Placeholders.** Aucun `TBD`, `TODO` ni « à compléter ». Chaque étape de code porte le code réel. La seule étape sans code est la 5 de la tâche 5, qui décrit un contenu impossible à écrire d'avance sans mentir sur des résultats non obtenus.

**Cohérence des noms.** `LAB_BOB_PASS_METACHARS` est défini en tâche 1 et consommé en tâche 3 ; la tâche 5 le réécrit littéralement plutôt que de sourcer le fichier, parce qu'elle s'exécute dans un pod qui n'a pas le dépôt — la valeur est identique aux deux endroits. `openldap-admin` (Secret), `openldap.ci.svc.cluster.local:389` (Service), `deploy/openldap` (Deployment), `secret/deploy/<tenant>/wm-admin` (chemin KV) et `lab-vault-users.env` (fichier root-only) portent le même nom dans toutes les tâches qui les citent.

**Périmètre.** Cinq tâches, chacune avec un livrable testable seul : le fichier purgé et sa garde, l'annuaire qui répond, l'arbre peuplé, Vault configuré, la porte franchie. La tâche 4 est la seule non exécutable par un agent, et c'est structurel.
