# E1 — Self-service producteur par GitOps : plan d'implémentation

> **Pour les exécutants agentiques :** SOUS-COMPÉTENCE REQUISE — `superpowers:executing-plans`
> pour dérouler ce plan tâche par tâche. Les étapes sont en cases à cocher (`- [ ]`).

**But :** faire que la chaîne de publication — et non le produit — garantisse
qu'une équipe publie une API **dans sa propre équipe**, puis le prouver sur la
gateway du cluster par cinq portes et quatre sabotages.

**Architecture :** le rôle Ansible `apim_publish_api` devient le moteur unique
du producteur (D1) et reçoit les durcissements du chemin consommateur ; la
définition du pipeline quitte le dépôt de l'équipe pour le job Jenkins (D2), qui
devient la seule autorité sur le nom d'équipe ; les gardes purement logiques
(liste blanche du manifeste, cohérence d'équipe) s'exécutent **avant** tout
appel à la gateway, donc se testent hors ligne.

**Pile :** Ansible core (déjà dans l'image `ci/jenkins-go`), API d'admin
webMethods 10.15 en REST, Vault (auth Kubernetes par identité de pod), Jenkins,
Gitea.

## Contraintes globales

Elles s'appliquent à **toutes** les tâches, sans être répétées :

- **Toute** requête vers la gateway vise `wm-apigateway-admin.wm.svc:5555`
  (réplique unique). À travers `wm-apigateway`, un `401` ne distingue pas un
  refus d'un cache froid — piège mesuré le 2026-07-30.
- **Aucun secret** dans le dépôt (il est public), aucun en argv, aucun affiché.
  `curl -K -` lit sa configuration sur stdin ; les mots de passe viennent de
  `/root/f4-teams.env` (0600, root) sur worker-1.
- **Aucune adresse IP publique** écrite dans un fichier du dépôt.
- Le refus natif de wM est **401**, jamais 403. Ne pas écrire d'assertion sur 403.
- `POST /assets/team` **exige `assetType`** ; sans lui il rend 200 et ne fait
  rien. Un code 2xx ne prouve donc jamais une assignation — **seule la relecture
  le fait**.
- La team relue d'une API vit dans **`apiResponse.teams[]`** ; `api.teams` est
  vide (piège relevé en F4).
- `accounts-read` sert le trafic public : aucune tâche ne modifie son
  assignation d'équipe. Les mesures créent leurs propres APIs jetables et les
  suppriment (désactiver **avant** de supprimer).
- La gateway redémarre par réplique toutes les 20 min (cycle trial). Toute étape
  attend `GET /health` → 200 avant de consommer une identité.
- Commits en français, sur la branche `docs/e1-producteur-gitops-spec`, un
  commit par tâche.

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `ansible/roles/apim_publish_api/tasks/manifest-guard.yml` | **Créer.** Liste blanche des clés du manifeste, lue *avant* `include_vars`. Aucun appel réseau. |
| `ansible/roles/apim_publish_api/tasks/team-name.yml` | **Créer.** Quelle équipe, et d'où. `TEAM_FORBIDDEN` / `TEAM_UNDEFINED`. Aucun appel réseau. |
| `ansible/roles/apim_publish_api/tasks/team.yml` | **Modifier.** `assetType: "API"` + relecture fail-closed. |
| `ansible/roles/apim_publish_api/tasks/resolve-env.yml` | **Modifier.** Importer la garde du manifeste en tête. |
| `ansible/roles/apim_publish_api/tasks/main.yml` | **Modifier.** Gardes avant l'import ; assignation inconditionnelle. |
| `ansible/roles/apim_publish_api/tasks/verify.yml` | **Modifier.** Contrôler la team et l'absence de `Default`. |
| `ansible/roles/apim_publish_api/defaults/main.yml` | **Modifier.** `apim_pub_require_team`, `apim_pub_manifest_allowed`. |
| `ansible/test-publish-guards.yml` | **Créer.** Playbook de test **hors ligne** des deux gardes. |
| `ansible/tests/e1/*.yml` | **Créer.** Manifestes-fixtures : légitime, cross-team, injection, sans équipe. |
| `ci/Jenkinsfile.publish-api` | **Créer.** Copie de reconstruction du script **inline** du job (D2). |
| `docs/superpowers/plans/2026-07-31-e1-portes.sh` | **Créer.** Les cinq portes et les quatre sabotages, rejouables. |

---

## Tâche 1 — Relevé T0 : ce qu'on pourra restaurer

**Fichiers :** aucun code. Produit `/root/e1-t0.txt` (root, 0600) sur worker-1.

Un rollback qu'on n'a pas capturé n'existe pas. Cette tâche ne modifie rien.

- [ ] **Étape 1 : capturer l'état des APIs, des teams et des privilèges**

```bash
ssh worker-1 'sudo sh -c "cat > /root/e1-t0.sh" <<'"'"'EOF'"'"'
#!/bin/bash
set -eu; umask 077
. /root/f4-teams.env
KX="k3s kubectl -n ci exec -i deploy/jenkins --"
B="http://wm-apigateway-admin.wm.svc:5555/rest/apigateway"
g() { { printf "url = \"%s%s\"\nuser = \"Administrator:%s\"\nheader = \"Accept: application/json\"\nsilent\n" "$B" "$1" "$WM_ADMIN_PW"; } | $KX curl -K - 2>/dev/null; }
{ echo "=== T0 $(date -u +%FT%TZ) ==="
  echo "--- apis (nom/version/id/actif) ---"; g /apis | python3 -c "
import json,sys
for it in json.load(sys.stdin).get(\"apiResponse\") or []:
    a=it.get(\"api\",it); print(a.get(\"apiName\"),a.get(\"apiVersion\"),a.get(\"id\"),a.get(\"isActive\"))"
  echo "--- accessProfiles (nom/id/bitmask) ---"; g /accessProfiles | python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in (d.get(\"accessProfiles\") or d.get(\"accessProfile\") or []):
    print(p.get(\"name\"),p.get(\"id\"),p.get(\"privilege\"))"
} > /root/e1-t0.txt
chmod 600 /root/e1-t0.txt; wc -l /root/e1-t0.txt
EOF
sudo chmod 700 /root/e1-t0.sh && sudo /root/e1-t0.sh'
```

Attendu : un décompte de lignes non nul, et `sudo head -5 /root/e1-t0.txt` montre
les APIs. **Le bitmask de chaque accessProfile est la valeur de rollback de la
tâche 8** — sans ce relevé, elle ne doit pas démarrer.

- [ ] **Étape 2 : vérifier que la valeur de rollback est bien là**

```bash
ssh worker-1 'sudo grep -c . /root/e1-t0.txt && sudo grep -A3 "accessProfiles" /root/e1-t0.txt | head -8'
```

Attendu : les cinq profils (`Administrators`, `API-Gateway-Providers`,
`banking-demo`, `Default`, `insurance-demo`) avec leur bitmask.

---

## Tâche 2 — Garde du manifeste (liste blanche) — D5, porte P-5

**Fichiers :**
- Créer : `ansible/roles/apim_publish_api/tasks/manifest-guard.yml`
- Créer : `ansible/tests/e1/manifest-legit.yml`, `ansible/tests/e1/manifest-injection.yml`
- Créer : `ansible/test-publish-guards.yml`
- Modifier : `ansible/roles/apim_publish_api/defaults/main.yml`
- Modifier : `ansible/roles/apim_publish_api/tasks/resolve-env.yml`

**Interfaces :**
- Produit : le fait `pub_manifest_path` (chemin absolu du manifeste, consommé par
  `include_vars` dans `resolve-env.yml`) et `pub_manifest_keys` (liste des clés
  top-level lues).
- Consomme : `apim_ss_manifest` (extra-var du pipeline), `apim_pub_manifest_allowed`
  (défaut du rôle).

- [ ] **Étape 1 : écrire les fixtures (le test avant le code)**

`ansible/tests/e1/manifest-legit.yml` :

```yaml
---
# Fixture E1 : manifeste conforme — une seule clé top-level.
apim_api:
  name: "e1-fixture"
  version: "1.0.0"
  contract: "/dev/null"
  team: ""
```

`ansible/tests/e1/manifest-injection.yml` :

```yaml
---
# Fixture E1 : manifeste qui tente de détourner la base d'admin et le chemin KV.
# include_vars charge le top-level à la précédence 18 : sans garde, ces deux
# clés deviennent des variables du rôle.
apim_api:
  name: "e1-fixture"
  version: "1.0.0"
  contract: "/dev/null"
  team: ""
apim_ss_api_base: "http://ailleurs.invalid/rest/apigateway"
apim_ss_vault_wm_creds_sub: "gateways/celui-des-autres"
```

- [ ] **Étape 2 : écrire le playbook de test hors ligne**

`ansible/test-publish-guards.yml` :

```yaml
---
# E1 — gardes HORS LIGNE : aucun appel à la gateway, aucun secret.
# Ces deux gardes s'exécutent avant tout accès réseau ; elles doivent donc se
# tester sans gateway, sans Vault et sans identité. C'est la boucle rapide.
- name: "E1 — gardes du producteur (hors ligne)"
  hosts: webmethods
  gather_facts: false
  tasks:
    - name: "Garde 1 : liste blanche des clés du manifeste"
      ansible.builtin.import_role:
        name: apim_publish_api
        tasks_from: manifest-guard.yml

    - name: "Charger le manifeste (comme le fait resolve-env)"
      ansible.builtin.include_vars: "{{ pub_manifest_path }}"

    - name: "Garde 2 : quelle équipe, et d'où"
      ansible.builtin.import_role:
        name: apim_publish_api
        tasks_from: team-name.yml
```

- [ ] **Étape 3 : lancer le test — il doit échouer faute de fichier**

```bash
cd poc-control-plane-federation && ansible-playbook -i ansible/inventory.lab.ini \
  ansible/test-publish-guards.yml -e apim_ss_manifest=ansible/tests/e1/manifest-legit.yml
```

Attendu : **ÉCHEC** — `Could not find or access 'manifest-guard.yml'`. C'est le
test rouge avant le code.

- [ ] **Étape 4 : écrire la garde**

`ansible/roles/apim_publish_api/tasks/manifest-guard.yml` :

```yaml
---
# roles/apim_publish_api/tasks/manifest-guard.yml — ce que le manifeste a le
# droit de déclarer (E1, D5).
#
# POURQUOI CETTE GARDE EXISTE. resolve-env.yml charge le manifeste par
# include_vars : TOUT top-level du fichier devient une variable Ansible, à la
# précédence 18. Or le manifeste vit dans le dépôt de l'ÉQUIPE — elle l'écrit.
# Les extra-vars du pipeline (précédence 22) gagnent sur ce qu'elles couvrent,
# mais une variable que le pipeline ne passe PAS est à la merci du manifeste :
# apim_ss_api_base (où l'on écrit), apim_ss_vault_wm_creds_sub (quelles creds on
# lit), apim_ss_auth_mode… Un manifeste pourrait donc rediriger la chaîne.
#
# La liste blanche est EXACTEMENT `apim_api`. L'élargir exige une ligne de
# spécification qui dit laquelle et pourquoi : une liste qui s'étend par
# commodité ne garde plus rien.
#
# Cette garde ne fait AUCUN appel réseau et tourne AVANT include_vars — donc
# avant que quoi que ce soit du manifeste ait pu prendre effet.

- name: "Manifeste : garde de liste blanche"
  when: "(apim_ss_manifest | default('')) | length > 0"
  block:

    - name: "Manifeste : chemin absolu résolu"
      ansible.builtin.set_fact:
        pub_manifest_path: >-
          {{ apim_ss_manifest if apim_ss_manifest.startswith('/')
             else (playbook_dir ~ '/../' ~ apim_ss_manifest) }}

    # Lecture BRUTE du fichier : on inspecte les clés SANS les instancier. Un
    # include_vars ici aurait déjà posé les variables qu'on veut refuser.
    - name: "Manifeste : clés déclarées au top-level"
      ansible.builtin.set_fact:
        pub_manifest_keys: >-
          {{ (lookup('file', pub_manifest_path) | from_yaml | default({}, true)).keys() | list }}

    - name: "Manifeste : FAIL-CLOSED — aucune clé hors liste blanche"
      ansible.builtin.assert:
        that: "(pub_manifest_keys | difference(apim_pub_manifest_allowed)) | length == 0"
        fail_msg: >-
          MANIFEST_KEYS_FORBIDDEN : le manifeste '{{ apim_ss_manifest }}' déclare
          {{ pub_manifest_keys | difference(apim_pub_manifest_allowed) }}, hors de la
          liste blanche {{ apim_pub_manifest_allowed }}. Ces clés deviendraient des
          variables du rôle (include_vars, précédence 18) et pourraient détourner la
          base d'admin, le chemin des identifiants ou le mode d'authentification.
          Un manifeste ne déclare que l'API à publier.
        success_msg: >-
          MANIFEST_KEYS_OK : '{{ apim_ss_manifest }}' ne déclare que
          {{ pub_manifest_keys }}.
```

- [ ] **Étape 5 : déclarer les défauts**

Dans `ansible/roles/apim_publish_api/defaults/main.yml`, ajouter **avant** le
bloc `apim_api:` :

```yaml
# --- E1 : ce que le manifeste de l'équipe a le droit de déclarer (D5) --------
# include_vars charge le top-level du manifeste à la précédence 18 : toute clé
# non listée ici deviendrait une variable du rôle. Élargir cette liste est une
# décision d'architecture, pas un réglage.
apim_pub_manifest_allowed: ["apim_api"]

# --- E1 : une API sans équipe n'est cloisonnée pour personne (D3) ------------
# Mesuré le 2026-07-31 : une API laissée en team `Default` est lue (200) par
# n'importe quelle équipe. false = lab sans feature Teams, JAMAIS chez un client.
apim_pub_require_team: true
```

- [ ] **Étape 6 : brancher la garde en tête de `resolve-env.yml`**

Remplacer les lignes 16-20 de `ansible/roles/apim_publish_api/tasks/resolve-env.yml` par :

```yaml
- name: "Env : GARDE — le manifeste ne déclare que ce qu'il a le droit de déclarer"
  ansible.builtin.import_tasks: manifest-guard.yml

- name: "Env : charger le manifeste (chemin) — include_vars, pas extra-var"
  ansible.builtin.include_vars: "{{ pub_manifest_path }}"
  when: "(apim_ss_manifest | default('')) | length > 0"
```

- [ ] **Étape 7 : le manifeste légitime passe, l'injection échoue**

```bash
cd poc-control-plane-federation
ansible-playbook -i ansible/inventory.lab.ini ansible/test-publish-guards.yml \
  -e apim_ss_manifest=ansible/tests/e1/manifest-legit.yml -e apim_ss_team=banking-demo
echo "--- attendu ci-dessus : MANIFEST_KEYS_OK ---"
ansible-playbook -i ansible/inventory.lab.ini ansible/test-publish-guards.yml \
  -e apim_ss_manifest=ansible/tests/e1/manifest-injection.yml -e apim_ss_team=banking-demo
echo "--- attendu ci-dessus : ÉCHEC MANIFEST_KEYS_FORBIDDEN ---"
```

Attendu : le premier **passe** (`MANIFEST_KEYS_OK`) ; le second **échoue** avec
`MANIFEST_KEYS_FORBIDDEN` citant `apim_ss_api_base` et
`apim_ss_vault_wm_creds_sub`. La tâche 3 fournira `team-name.yml` ; jusque-là le
premier lancement s'arrête sur son absence **après** avoir affiché
`MANIFEST_KEYS_OK` — c'est le résultat attendu à cette étape.

- [ ] **Étape 8 : commit**

```bash
git add ansible/roles/apim_publish_api/tasks/manifest-guard.yml \
        ansible/roles/apim_publish_api/tasks/resolve-env.yml \
        ansible/roles/apim_publish_api/defaults/main.yml \
        ansible/test-publish-guards.yml ansible/tests/e1/
git commit -m "feat(E1): le manifeste de l'équipe ne peut plus poser n'importe quelle variable

include_vars charge son top-level à la précédence 18 : sans garde, une clé
apim_ss_api_base ou apim_ss_vault_wm_creds_sub dans le manifeste détournerait
la base d'admin ou le chemin des identifiants. Liste blanche stricte, lue AVANT
include_vars, donc avant que quoi que ce soit ait pris effet.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Tâche 3 — Quelle équipe, et d'où — D3, portes P-2 et P-4

**Fichiers :**
- Créer : `ansible/roles/apim_publish_api/tasks/team-name.yml`
- Créer : `ansible/tests/e1/manifest-crossteam.yml`, `ansible/tests/e1/manifest-noteam.yml`

**Interfaces :**
- Produit : le fait `pub_team_name` (nom d'équipe retenu), consommé par
  `team.yml` (tâche 4) et `verify.yml` (tâche 6).
- Consomme : `apim_ss_team` (extra-var du pipeline), `apim_api.team` (manifeste),
  `apim_pub_require_team`.

- [ ] **Étape 1 : écrire les deux fixtures manquantes**

`ansible/tests/e1/manifest-crossteam.yml` :

```yaml
---
# Fixture E1 : le manifeste réclame une équipe qui n'est pas celle du pipeline.
apim_api:
  name: "e1-fixture"
  version: "1.0.0"
  contract: "/dev/null"
  team: "insurance-demo"
```

`ansible/tests/e1/manifest-noteam.yml` :

```yaml
---
# Fixture E1 : aucune équipe nulle part.
apim_api:
  name: "e1-fixture"
  version: "1.0.0"
  contract: "/dev/null"
  team: ""
```

- [ ] **Étape 2 : lancer le test cross-team — il doit échouer faute de fichier**

```bash
cd poc-control-plane-federation && ansible-playbook -i ansible/inventory.lab.ini \
  ansible/test-publish-guards.yml \
  -e apim_ss_manifest=ansible/tests/e1/manifest-crossteam.yml -e apim_ss_team=banking-demo
```

Attendu : **ÉCHEC** — `Could not find or access 'team-name.yml'`, après un
`MANIFEST_KEYS_OK` vert.

- [ ] **Étape 3 : écrire la résolution d'équipe**

`ansible/roles/apim_publish_api/tasks/team-name.yml` :

```yaml
---
# roles/apim_publish_api/tasks/team-name.yml — quelle équipe, et d'où ? (E1, D3)
#
# CE QUE CETTE TÂCHE DÉCIDE, ET POURQUOI ELLE EST ISOLÉE. Deux choses en
# dépendent : le cloisonnement de l'API (team.yml) et le message porté au statut
# de commit quand la demande est refusée. Elle ne fait AUCUN appel réseau, donc
# elle tourne AVANT l'import — un refus ne doit rien laisser derrière lui.
#
# LE FOND DU PROBLÈME (mesuré le 2026-07-31 sur la gateway du cluster) :
#   - assigner une team est réservé à l'ADMIN — un utilisateur d'équipe reçoit
#     401 « not authorized to perform: POST on the resource: assets », même pour
#     SA PROPRE équipe. La chaîne tourne donc nécessairement en admin.
#   - et à l'admin, le produit n'oppose AUCUN refus cross-team : déplacer une API
#     de banking-demo vers insurance-demo rend 200.
# Le cloisonnement par équipe n'est donc PAS une propriété du produit. C'est une
# propriété de la chaîne, et elle se joue ici.
#
# D'OÙ VIENT L'AUTORITÉ. `apim_ss_team` est posée en extra-var par le JOB
# Jenkins, qui appartient à la plateforme (D2) — pas par le Jenkinsfile, qui
# appartiendrait à l'équipe. C'est la seule raison pour laquelle cette valeur
# est digne de confiance ; une garde qui lirait le dépôt de l'équipe raisonnerait
# sur une donnée que l'équipe écrit.
#
# POURQUOI UNE DIVERGENCE ÉCHOUE AU LIEU D'ÊTRE IGNORÉE. Le chemin consommateur
# (apim_selfservice_app/team-name.yml) laisse l'extra-var l'emporter en silence.
# Ici on refuse : ignorer une demande cross-team la rend indétectable — ni
# l'équipe qui l'a écrite ni la plateforme ne l'apprennent. La faire rougir la
# trace dans le statut de commit, où les deux la lisent.

- name: "Team : nom retenu (pipeline > manifeste)"
  ansible.builtin.set_fact:
    pub_team_name: >-
      {{ (apim_ss_team | default('') | trim)
         if ((apim_ss_team | default('') | trim) | length > 0)
         else (apim_api.team | default('') | trim) }}
    pub_team_claimed: "{{ apim_api.team | default('') | trim }}"

- name: "Team : FAIL-CLOSED — le manifeste ne peut pas désigner une AUTRE équipe"
  ansible.builtin.assert:
    that: "pub_team_claimed | length == 0 or pub_team_claimed == pub_team_name"
    fail_msg: >-
      TEAM_FORBIDDEN : le manifeste réclame la team '{{ pub_team_claimed }}' alors
      que la chaîne publie au nom de '{{ pub_team_name }}'. Publier dans l'équipe
      d'un tiers rendrait l'API invisible à son auteur et visible à cette équipe —
      et le produit ne l'interdit pas (l'assignation est une opération d'admin, à
      laquelle aucun refus cross-team n'est opposé, mesuré le 2026-07-31). Rien
      n'a été créé. Corriger `team:` dans le manifeste, ou la retirer : la chaîne
      la connaît déjà.
    success_msg: >-
      TEAM_REQUESTED : API '{{ apim_api.name }}' -> team '{{ pub_team_name }}'
      {{ '(demandée par le manifeste, concordante)' if pub_team_claimed | length > 0
         else '(posée par la chaîne)' }}.
  when: "apim_pub_require_team | default(true) | bool"

- name: "Team : FAIL-CLOSED — une API sans équipe n'est cloisonnée pour personne"
  ansible.builtin.assert:
    that: "pub_team_name | length > 0"
    fail_msg: >-
      TEAM_UNDEFINED : aucune équipe pour l'API '{{ apim_api.name }}' (ni
      -e apim_ss_team=<team>, ni `team:` dans le manifeste). Une API non assignée
      reste en team Default : mesuré le 2026-07-31, elle est alors LUE (200) par
      n'importe quelle équipe. Poser l'équipe, ou assumer explicitement le
      contraire avec -e apim_pub_require_team=false (lab sans feature Teams).
  when: "apim_pub_require_team | default(true) | bool"

- name: "Team : AVERTISSEMENT — cloisonnement désactivé"
  ansible.builtin.debug:
    msg: >-
      ⚠ TEAM_SKIPPED : apim_pub_require_team=false et aucune équipe résolue.
      L'API '{{ apim_api.name }}' restera en team Default — lisible par toutes les
      équipes. Acceptable en lab sans feature Teams, JAMAIS chez un client.
  when: "pub_team_name | length == 0"
```

- [ ] **Étape 4 : les quatre cas passent comme attendu**

```bash
cd poc-control-plane-federation
I=ansible/inventory.lab.ini; P=ansible/test-publish-guards.yml
echo "=== 1. légitime + équipe du pipeline -> TEAM_REQUESTED ==="
ansible-playbook -i $I $P -e apim_ss_manifest=ansible/tests/e1/manifest-legit.yml -e apim_ss_team=banking-demo
echo "=== 2. cross-team -> TEAM_FORBIDDEN (échec) ==="
ansible-playbook -i $I $P -e apim_ss_manifest=ansible/tests/e1/manifest-crossteam.yml -e apim_ss_team=banking-demo; echo "rc=$?"
echo "=== 3. sans équipe nulle part -> TEAM_UNDEFINED (échec) ==="
ansible-playbook -i $I $P -e apim_ss_manifest=ansible/tests/e1/manifest-noteam.yml; echo "rc=$?"
echo "=== 4. manifeste concordant (team = celle du pipeline) -> TEAM_REQUESTED ==="
ansible-playbook -i $I $P -e apim_ss_manifest=ansible/tests/e1/manifest-crossteam.yml -e apim_ss_team=insurance-demo
```

Attendu : 1 et 4 **verts** ; 2 échoue sur `TEAM_FORBIDDEN` (`rc=2`) ; 3 échoue
sur `TEAM_UNDEFINED` (`rc=2`).

- [ ] **Étape 5 : commit**

```bash
git add ansible/roles/apim_publish_api/tasks/team-name.yml ansible/tests/e1/
git commit -m "feat(E1): l'équipe vient de la chaîne, et une divergence du manifeste ÉCHOUE

Mesuré le 2026-07-31 : assigner une team est réservé à l'admin (401 pour un
membre d'équipe, même sur sa propre équipe), et à l'admin le produit n'oppose
aucun refus cross-team (200 pour déplacer une API vers l'équipe d'un tiers). Le
cloisonnement n'est donc pas une propriété du produit mais de la chaîne.

TEAM_FORBIDDEN plutôt qu'un silence : ignorer une demande cross-team la rendrait
indétectable des deux côtés. La faire rougir la porte au statut de commit.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Tâche 4 — L'assignation devient prouvée — porte P-3

**Fichiers :** Modifier `ansible/roles/apim_publish_api/tasks/team.yml`

**Interfaces :**
- Consomme : `pub_team_name` (tâche 3), `apim_api_id` (posé par `main.yml`).
- Produit : le fait `pub_team_names_after` (teams relues), consommé par le
  message d'assertion uniquement.

- [ ] **Étape 1 : remplacer intégralement le fichier**

`ansible/roles/apim_publish_api/tasks/team.yml` :

```yaml
---
# roles/apim_publish_api/tasks/team.yml — cloisonnement de l'API par assignation
# de team (E1 ; pendant producteur de apim_selfservice_app/tasks/team.yml).
#
# CE FICHIER PORTAIT « ⚠ NON TESTÉ LIVE » ET TROIS DÉFAUTS. Corrigés ici :
#   1. `assetType` manquait. Sans lui, POST /assets/team rend 200 et NE FAIT
#      RIEN — no-op silencieux. C'est le piège central de cet appel : un code de
#      retour vert n'y prouve strictement rien.
#   2. Aucune relecture. Le 200 était pris pour la preuve. La preuve, c'est la
#      relecture, et elle exige les DEUX moitiés du résultat : la team demandée
#      présente ET `Default` partie — tant que Default est là, l'API reste
#      lisible par toutes les équipes (mesuré le 2026-07-31 : 200 par un tiers).
#   3. L'assignation était optionnelle. Une API sans team tombe en Default. La
#      condition a disparu de main.yml ; l'obligation se règle en amont, par
#      apim_pub_require_team (team-name.yml).
#
# SHAPES (spike Teams F4) : une « team » EST un accessProfile ; `newTeams` attend
# son UUID (les NOMS rendent 400). La team relue vit au niveau `apiResponse` —
# `api.teams` est vide, et viser le mauvais niveau donne un « aucune team »
# silencieux.
#
# ⚠ RELECTURE : viser le Service d'administration (réplique unique). À travers
# `wm-apigateway` (deux répliques sans cluster, caches mémoire non synchronisés)
# une relecture peut tomber sur la réplique qui ignore encore l'écriture et
# rendre un 401 qui PARLE D'AUTORISATION alors qu'il s'agit d'un cache froid.

- name: "Team : cloisonner l'API sur '{{ pub_team_name }}'"
  when: "pub_team_name | length > 0"
  block:

    - name: "Team : lister les accessProfiles (une team EST un accessProfile)"
      ansible.builtin.uri:
        url: "{{ apim_ss_api_base }}/accessProfiles"
      register: pub_team_aps
      changed_when: false

    - name: "Team : UUID de l'accessProfile (ou vide)"
      ansible.builtin.set_fact:
        pub_team_uuid: >-
          {{ (pub_team_aps.json.accessProfiles | default(pub_team_aps.json.accessProfile) | default([])
              | selectattr('name', 'equalto', pub_team_name) | map(attribute='id') | list | first) | default('') }}

    - name: "Team : fail-closed si l'accessProfile d'équipe est absent"
      ansible.builtin.assert:
        that: "pub_team_uuid | length > 0"
        fail_msg: >-
          TEAM_UNKNOWN : accessProfile '{{ pub_team_name }}' absent de la gateway.
          Feature Teams activée (PUT /configurations/extended {"enableTeamWork":"true"},
          configId `extended` et non `extendedSettings`) ? Équipe créée
          (POST /accessProfiles + groupe, membres du groupe système
          API-Gateway-Providers) — cf. GOAL E5 ?

    # assetType OBLIGATOIRE : sans lui, 200 et rien ne se passe.
    - name: "Team : POST /assets/team (assetType API, newTeams = UUID)"
      ansible.builtin.uri:
        url: "{{ apim_ss_api_base }}/assets/team"
        method: POST
        body:
          assetIds: ["{{ apim_api_id }}"]
          assetType: "API"
          newTeams: ["{{ pub_team_uuid }}"]
        status_code: [200, 201]
      register: pub_team_assign

    # LA porte de preuve.
    - name: "Team : relire l'API (Service d'administration, réplique unique)"
      ansible.builtin.uri:
        url: "{{ apim_ss_api_base }}/apis/{{ apim_api_id }}"
      register: pub_team_after
      changed_when: false

    - name: "Team : teams[] relues (niveau apiResponse — api.teams est vide)"
      ansible.builtin.set_fact:
        pub_team_names_after: >-
          {{ (pub_team_after.json.apiResponse | default({})).teams | default([])
             | map(attribute='name') | list }}

    - name: "Team : FAIL-CLOSED — l'assignation a RÉELLEMENT eu lieu"
      ansible.builtin.assert:
        that:
          - "pub_team_name in pub_team_names_after"
          - "'Default' not in pub_team_names_after"
        fail_msg: >-
          TEAM_UNCONFIRMED : après POST /assets/team (HTTP
          {{ pub_team_assign.status }}), l'API '{{ apim_api.name }}' porte
          teams={{ pub_team_names_after }} — attendu : '{{ pub_team_name }}'
          présente et 'Default' absente. Un 200 sans effet est le comportement
          connu de cet appel quand assetType manque ou ne correspond pas.
        success_msg: >-
          TEAM_CONFIRMED : '{{ apim_api.name }}' cloisonnée sur
          '{{ pub_team_name }}' (teams={{ pub_team_names_after }}, Default retirée).
```

- [ ] **Étape 2 : contrôle de syntaxe**

```bash
cd poc-control-plane-federation && ansible-playbook -i ansible/inventory.lab.ini \
  ansible/publish-api.yml --syntax-check
```

Attendu : `playbook: ansible/publish-api.yml`, aucune erreur. (La preuve live
est la tâche 7 — ce fichier ne peut pas se tester hors ligne, il parle à la
gateway.)

- [ ] **Étape 3 : commit**

```bash
git add ansible/roles/apim_publish_api/tasks/team.yml
git commit -m "feat(E1): l'assignation d'équipe de l'API est prouvée par relecture, plus par un 200

Le fichier portait « NON TESTÉ LIVE » et trois défauts : assetType absent (donc
200 no-op silencieux), aucune relecture, assignation optionnelle. Mêmes gardes
que le chemin application depuis E3 — team demandée présente ET Default partie,
car tant que Default est là l'API reste lisible par toutes les équipes.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Tâche 5 — L'ordre est une propriété — D4

**Fichiers :** Modifier `ansible/roles/apim_publish_api/tasks/main.yml`

Un refus cross-team qui laisse une API créée derrière lui a produit exactement
le défaut qu'il prétendait empêcher : une API non assignée, donc en `Default`,
donc lisible par toutes. Les gardes passent avant l'import.

- [ ] **Étape 1 : insérer la résolution d'équipe avant les secrets**

Après la tâche `"Env : résoudre l'API effective…"` et **avant**
`"Secrets : auth admin…"`, insérer :

```yaml
- name: "Team : quelle équipe, et d'où (AVANT tout appel — un refus ne crée rien)"
  ansible.builtin.import_tasks: team-name.yml
```

- [ ] **Étape 2 : rendre l'assignation inconditionnelle**

Remplacer le bloc « 4. Scoping équipe » de `main.yml` par :

```yaml
    # ===== 4. Cloisonnement par équipe (E1 — plus optionnel) =================
    # L'obligation se règle en amont (team-name.yml / apim_pub_require_team) :
    # ici on assigne, toujours, dès qu'une équipe est résolue. Le `when` d'antan
    # (`apim_api.team | length > 0`) faisait dépendre la protection d'une clé
    # que l'appelant pouvait simplement omettre.
    - name: "Team : cloisonnement par équipe"
      ansible.builtin.import_tasks: team.yml
```

- [ ] **Étape 3 : vérifier l'ordre effectif**

```bash
cd poc-control-plane-federation && grep -n "import_tasks\|import_role" ansible/roles/apim_publish_api/tasks/main.yml
```

Attendu, dans cet ordre : `resolve-env.yml`, `team-name.yml`, `apim_common`
(secrets), puis, dans le bloc, `port-access.yml`, `team.yml`, `inbound.yml`.

- [ ] **Étape 4 : le refus cross-team ne fait aucun appel réseau**

```bash
cd poc-control-plane-federation && ansible-playbook -i ansible/inventory.lab.ini \
  ansible/publish-api.yml -e apim_ss_manifest=ansible/tests/e1/manifest-crossteam.yml \
  -e apim_ss_team=banking-demo -e apim_ss_api_base=http://127.0.0.1:1/rest/apigateway 2>&1 | tail -20
```

Attendu : échec sur `TEAM_FORBIDDEN`, **et jamais** d'erreur de connexion — la
base d'admin pointe volontairement un port mort. Si une erreur de connexion
apparaît, une tâche réseau s'exécute avant la garde : l'ordre est faux.

- [ ] **Étape 5 : commit**

```bash
git add ansible/roles/apim_publish_api/tasks/main.yml
git commit -m "feat(E1): les gardes jouent avant l'import — un refus ne laisse rien derrière lui

Un refus cross-team survenant après POST /apis laisserait une API créée et non
assignée, donc en Default, donc lisible par toutes : exactement le défaut qu'il
prétend empêcher. Prouvé par une base d'admin pointée sur un port mort — la
garde rougit sans qu'aucune connexion soit tentée.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Tâche 6 — `verify` cesse d'attester ce qu'il ne contrôle pas — D7

**Fichiers :** Modifier `ansible/roles/apim_publish_api/tasks/verify.yml`

- [ ] **Étape 1 : ajouter la résolution d'équipe en tête**

Après l'import de `resolve-env.yml`, avant l'import de `apim_common` :

```yaml
- name: "Team : quelle équipe, et d'où (même résolution que la convergence)"
  ansible.builtin.import_tasks: team-name.yml
```

- [ ] **Étape 2 : étendre l'assertion de publication**

Remplacer la tâche `"Verify : FAIL-CLOSED — l'API est publiée ET ACTIVE"` par :

```yaml
    - name: "Verify : teams relues (niveau apiResponse — api.teams est vide)"
      ansible.builtin.uri:
        url: "{{ apim_ss_api_base }}/apis/{{ v_api.id }}"
      register: v_api_get
      changed_when: false
      when: "v_api.id is defined"

    - name: "Verify : teams[] de l'API"
      ansible.builtin.set_fact:
        v_team_names: >-
          {{ (v_api_get.json.apiResponse | default({})).teams | default([])
             | map(attribute='name') | list }}
      when: "v_api.id is defined"

    - name: "Verify : FAIL-CLOSED — l'API est publiée, ACTIVE et CLOISONNÉE"
      ansible.builtin.assert:
        that:
          - "v_api.id is defined"
          - "v_api.isActive | default(false)"
          - "pub_team_name | length == 0 or pub_team_name in (v_team_names | default([]))"
          - "pub_team_name | length == 0 or 'Default' not in (v_team_names | default([]))"
        fail_msg: >-
          PUBLISH_UNCONFIRMED : API {{ apim_api.name }} v{{ apim_api.version }} —
          absente, inactive, ou non cloisonnée (teams={{ v_team_names | default('n/a') }},
          attendu '{{ pub_team_name }}' présente et 'Default' absente). Une API en
          Default est lue par n'importe quelle équipe : attester « publiée » sans
          contrôler la team, c'est certifier une propriété qu'on ne vérifie pas.
        success_msg: >-
          PUBLISH_CONFIRMED : {{ apim_api.name }} v{{ apim_api.version }} publiée,
          active et cloisonnée sur '{{ pub_team_name }}'
          (teams={{ v_team_names | default([]) }}, id={{ v_api.id | default('?') }}).
```

- [ ] **Étape 3 : contrôle de syntaxe**

```bash
cd poc-control-plane-federation && ansible-playbook -i ansible/inventory.lab.ini \
  ansible/publish-api-verify.yml --syntax-check
```

Attendu : aucune erreur.

- [ ] **Étape 4 : commit**

```bash
git add ansible/roles/apim_publish_api/tasks/verify.yml
git commit -m "feat(E1): verify contrôle la team — il attestait une propriété qu'il ne vérifiait pas

PUBLISH_CONFIRMED verdissait sur une API en Default, c'est-à-dire lisible par
toutes les équipes. Une garantie écrite mais fausse coûte plus cher que son
absence : elle dispense de vérifier.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Tâche 7 — Les portes, sur la gateway du cluster — P-1 à P-5 et quatre sabotages

**Fichiers :** Créer `docs/superpowers/plans/2026-07-31-e1-portes.sh`

Le rôle tourne **dans le pod Jenkins** (l'image `jenkins-go` porte
`ansible-core`), seul endroit d'où la gateway est joignable et où l'identité de
pod ouvre Vault. Le dépôt y est copié par `kubectl cp`.

**Interfaces :**
- Consomme : le rôle des tâches 2 à 6 ; le secret Vault `secret/ci/gateways/wm-cluster`
  (clés `username`/`password`), lisible par le rôle Vault k8s `jenkins-agent`.
- Produit : la trace des cinq portes, à recopier dans la § Preuve d'exécution.

- [ ] **Étape 1 : copier le dépôt dans le pod et vérifier l'outillage**

```bash
export KUBECONFIG=~/.kube/k3s-contabo.yaml
kubectl -n ci exec deploy/jenkins -- rm -rf /tmp/e1 && kubectl -n ci exec deploy/jenkins -- mkdir -p /tmp/e1
kubectl -n ci cp poc-control-plane-federation ci/$(kubectl -n ci get pod -l app=jenkins -o jsonpath='{.items[0].metadata.name}'):/tmp/e1/pcf
kubectl -n ci exec deploy/jenkins -- sh -c 'ansible-playbook --version | head -1 && ls /tmp/e1/pcf/ansible/publish-api.yml'
```

Attendu : la version d'ansible-core et le chemin du playbook.

- [ ] **Étape 2 : créer le manifeste et le contrat de la porte**

```bash
kubectl -n ci exec -i deploy/jenkins -- sh -c 'mkdir -p /tmp/e1/pcf/clients/e1 && cat > /tmp/e1/pcf/clients/e1/e1-gate.openapi.yaml' <<'YAML'
openapi: "3.0.0"
info: { title: "e1-gate-api", version: "1.0.0" }
servers: [ { url: "http://backend-dev.wm.svc.cluster.local:8080" } ]
paths:
  /ping:
    get:
      responses: { "200": { description: ok } }
YAML
kubectl -n ci exec -i deploy/jenkins -- sh -c 'cat > /tmp/e1/pcf/clients/e1/e1-gate.publish.yml' <<'YAML'
---
apim_api:
  name: "e1-gate-api"
  version: "1.0.0"
  contract: "/tmp/e1/pcf/clients/e1/e1-gate.openapi.yaml"
  team: ""
YAML
echo "manifeste + contrat posés"
```

- [ ] **Étape 3 : P-1 — publier et cloisonner par la chaîne**

```bash
kubectl -n ci exec deploy/jenkins -- sh -c 'cd /tmp/e1/pcf && \
  VAULT_ADDR=http://vault.ci.svc.cluster.local:8200 VAULT_K8S_ROLE=jenkins-agent \
  ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e apim_ss_manifest=/tmp/e1/pcf/clients/e1/e1-gate.publish.yml \
    -e apim_ss_team=banking-demo \
    -e apim_ss_api_base=http://wm-apigateway-admin.wm.svc:5555/rest/apigateway \
    -e apim_ss_vault_kv_mount=secret -e apim_ss_vault_prefix=ci \
    -e apim_ss_vault_wm_creds_sub=gateways/wm-cluster \
    -e apim_ss_auth_mode=basic' 2>&1 | tail -30
```

Attendu : `MANIFEST_KEYS_OK`, `TEAM_REQUESTED`, puis
`TEAM_CONFIRMED : 'e1-gate-api' cloisonnée sur 'banking-demo' (teams=['Administrators', 'banking-demo'], Default retirée)`.

- [ ] **Étape 4 : P-1 (suite) — l'autre équipe ne la voit pas**

```bash
ssh worker-1 'sudo sh -c ". /root/f4-teams.env; K=\"k3s kubectl -n ci exec -i deploy/jenkins --\"; B=http://wm-apigateway-admin.wm.svc:5555/rest/apigateway; \
ID=\$(printf \"url = \\\"%s/apis\\\"\nuser = \\\"Administrator:%s\\\"\nheader = \\\"Accept: application/json\\\"\nsilent\n\" \"\$B\" \"\$WM_ADMIN_PW\" | \$K curl -K - | python3 -c \"
import json,sys
for it in json.load(sys.stdin).get(\\\"apiResponse\\\") or []:
    a=it.get(\\\"api\\\",it)
    if a.get(\\\"apiName\\\")==\\\"e1-gate-api\\\": print(a[\\\"id\\\"])\"); \
printf \"url = \\\"%s/apis/%s\\\"\nuser = \\\"svc-insurance-demo:%s\\\"\nheader = \\\"Accept: application/json\\\"\nsilent\noutput = /dev/null\nwrite-out = \\\"insurance -> %%{http_code}\\\\n\\\"\n\" \"\$B\" \"\$ID\" \"\$P_insurance_demo\" | \$K curl -K -"'
```

Attendu : `insurance -> 401`. C'est P-1 fermée.

- [ ] **Étape 5 : P-2 — le refus cross-team, par la chaîne réelle**

```bash
kubectl -n ci exec -i deploy/jenkins -- sh -c 'cat > /tmp/e1/pcf/clients/e1/e1-cross.publish.yml' <<'YAML'
---
apim_api:
  name: "e1-cross-api"
  version: "1.0.0"
  contract: "/tmp/e1/pcf/clients/e1/e1-gate.openapi.yaml"
  team: "insurance-demo"
YAML
kubectl -n ci exec deploy/jenkins -- sh -c 'cd /tmp/e1/pcf && \
  VAULT_ADDR=http://vault.ci.svc.cluster.local:8200 VAULT_K8S_ROLE=jenkins-agent \
  ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e apim_ss_manifest=/tmp/e1/pcf/clients/e1/e1-cross.publish.yml \
    -e apim_ss_team=banking-demo \
    -e apim_ss_api_base=http://wm-apigateway-admin.wm.svc:5555/rest/apigateway \
    -e apim_ss_vault_kv_mount=secret -e apim_ss_vault_prefix=ci \
    -e apim_ss_vault_wm_creds_sub=gateways/wm-cluster -e apim_ss_auth_mode=basic' 2>&1 | tail -20; echo "rc=$?"
```

Attendu : échec sur `TEAM_FORBIDDEN`.

- [ ] **Étape 6 : P-2 (contre-épreuve) — RIEN n'a été créé**

```bash
ssh worker-1 'sudo sh -c ". /root/f4-teams.env; printf \"url = \\\"http://wm-apigateway-admin.wm.svc:5555/rest/apigateway/apis\\\"\nuser = \\\"Administrator:%s\\\"\nheader = \\\"Accept: application/json\\\"\nsilent\n\" \"\$WM_ADMIN_PW\" | k3s kubectl -n ci exec -i deploy/jenkins -- curl -K - | grep -c e1-cross-api || echo 0"'
```

Attendu : **`0`**. Un refus qui aurait laissé l'API derrière lui aurait produit
le défaut qu'il prétend empêcher.

- [ ] **Étape 7 : P-4 et P-5 — fail-closed sans équipe, et injection**

```bash
kubectl -n ci exec deploy/jenkins -- sh -c 'cd /tmp/e1/pcf && \
  ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e apim_ss_manifest=/tmp/e1/pcf/clients/e1/e1-gate.publish.yml \
    -e apim_ss_api_base=http://127.0.0.1:1/rest/apigateway' 2>&1 | tail -8; echo "P-4 rc=$?"
kubectl -n ci exec -i deploy/jenkins -- sh -c 'cat > /tmp/e1/pcf/clients/e1/e1-inject.publish.yml' <<'YAML'
---
apim_api:
  name: "e1-gate-api"
  version: "1.0.0"
  contract: "/tmp/e1/pcf/clients/e1/e1-gate.openapi.yaml"
  team: ""
apim_ss_api_base: "http://ailleurs.invalid/rest/apigateway"
YAML
kubectl -n ci exec deploy/jenkins -- sh -c 'cd /tmp/e1/pcf && \
  ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e apim_ss_manifest=/tmp/e1/pcf/clients/e1/e1-inject.publish.yml -e apim_ss_team=banking-demo \
    -e apim_ss_api_base=http://127.0.0.1:1/rest/apigateway' 2>&1 | tail -8; echo "P-5 rc=$?"
```

Attendu : P-4 échoue sur `TEAM_UNDEFINED` ; P-5 échoue sur
`MANIFEST_KEYS_FORBIDDEN` citant `apim_ss_api_base`. Aucune erreur de connexion
dans les deux cas — les gardes précèdent le réseau.

- [ ] **Étape 8 : P-3 — le sabotage de l'`assetType`**

```bash
kubectl -n ci exec deploy/jenkins -- sh -c \
  'sed -i "/assetType: \"API\"/d" /tmp/e1/pcf/ansible/roles/apim_publish_api/tasks/team.yml && \
   grep -c assetType /tmp/e1/pcf/ansible/roles/apim_publish_api/tasks/team.yml'
kubectl -n ci exec deploy/jenkins -- sh -c 'cd /tmp/e1/pcf && \
  VAULT_ADDR=http://vault.ci.svc.cluster.local:8200 VAULT_K8S_ROLE=jenkins-agent \
  ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \
    -e apim_ss_manifest=/tmp/e1/pcf/clients/e1/e1-gate.publish.yml -e apim_ss_team=insurance-demo \
    -e apim_ss_api_base=http://wm-apigateway-admin.wm.svc:5555/rest/apigateway \
    -e apim_ss_vault_kv_mount=secret -e apim_ss_vault_prefix=ci \
    -e apim_ss_vault_wm_creds_sub=gateways/wm-cluster -e apim_ss_auth_mode=basic' 2>&1 | tail -12; echo "P-3 rc=$?"
```

Attendu : le POST rend **200** et l'assertion rougit sur `TEAM_UNCONFIRMED` —
teams inchangées (`['Administrators','banking-demo']`). C'est la démonstration
que le code HTTP ne prouve rien et que la relecture, elle, mord. Restaurer
ensuite : `kubectl -n ci cp` du fichier sain, puis rejouer l'étape 3 pour
revenir au vert.

- [ ] **Étape 9 : nettoyage — supprimer les APIs de porte**

```bash
ssh worker-1 'sudo sh -c ". /root/f4-teams.env; K=\"k3s kubectl -n ci exec -i deploy/jenkins --\"; B=http://wm-apigateway-admin.wm.svc:5555/rest/apigateway; \
for N in e1-gate-api e1-cross-api; do \
  ID=\$(printf \"url = \\\"%s/apis\\\"\nuser = \\\"Administrator:%s\\\"\nheader = \\\"Accept: application/json\\\"\nsilent\n\" \"\$B\" \"\$WM_ADMIN_PW\" | \$K curl -K - | python3 -c \"
import json,sys,os
for it in json.load(sys.stdin).get(\\\"apiResponse\\\") or []:
    a=it.get(\\\"api\\\",it)
    if a.get(\\\"apiName\\\")==os.environ[\\\"N\\\"]: print(a[\\\"id\\\"])\" N=\$N 2>/dev/null); \
  [ -n \"\$ID\" ] || continue; \
  printf \"url = \\\"%s/apis/%s/deactivate\\\"\nuser = \\\"Administrator:%s\\\"\nrequest = \\\"PUT\\\"\nsilent\noutput = /dev/null\n\" \"\$B\" \"\$ID\" \"\$WM_ADMIN_PW\" | \$K curl -K -; \
  printf \"url = \\\"%s/apis/%s\\\"\nuser = \\\"Administrator:%s\\\"\nrequest = \\\"DELETE\\\"\nsilent\noutput = /dev/null\nwrite-out = \\\"delete \$N -> %%{http_code}\\\\n\\\"\n\" \"\$B\" \"\$ID\" \"\$WM_ADMIN_PW\" | \$K curl -K -; \
done"'
```

Attendu : `delete e1-gate-api -> 204` (et `e1-cross-api` absente, donc rien).
Désactiver **avant** de supprimer : l'ordre inverse échoue.

- [ ] **Étape 10 : consigner la preuve et commiter**

Ajouter au plan une section `## Preuve d'exécution` avec les **sorties réelles
horodatées** des étapes 3 à 8. Puis :

```bash
git add docs/superpowers/plans/2026-07-31-e1-producteur-gitops.md
git commit -m "test(E1): les cinq portes et le sabotage de l'assetType, sur la gateway du cluster

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Tâche 8 — Le pipeline quitte le dépôt de l'équipe — D2

> **CORRECTION du 2026-08-02 : la prémisse de cette tâche était fausse.**
> `ci/Jenkinsfile.publish-api` **existait déjà** — c'est le pendant producteur de
> `Jenkinsfile.selfservice` (modèle PLAN/APPLY, identité nominative), et il
> lançait **déjà** le rôle Ansible. Je ne l'avais pas vu en explorant, et j'ai
> failli l'écraser. Deux conséquences :
>
> 1. **D1 était déjà à moitié acquis** : sur le chemin fidèle-client, le moteur
>    est le rôle Ansible depuis le départ. Ce que E1 y change, c'est la team.
> 2. **J'y ai introduit une régression** : ce pipeline ne passait pas
>    `apim_ss_team`, or `team-name.yml` rend l'équipe obligatoire — tout apply
>    aurait échoué sur `TEAM_UNDEFINED`. Corrigé en y portant la dérivation du
>    chemin consommateur : `TEAM="${APIM_TEAM:-$(… cut -d/ -f2)}"` sur
>    `APIM_WM_CREDS_SUB` (`deploy/<tenant>/wm-admin`), passée en `-e` aux deux
>    invocations (converge et verify).
>
> **Il y a donc DEUX chaînes productrices, et deux autorités différentes** —
> c'est à retenir, pas à uniformiser de force :
>
> | Chaîne | Identité | D'où vient la team | Est-elle infalsifiable ? |
> |---|---|---|---|
> | Fidèle-client (`Jenkinsfile.publish-api`) | nominative (voie A/B) | chemin KV tenant-scopé | **Oui** — la policy Vault du token nominatif ne lit que son tenant |
> | GitOps cluster (job F4) | identité de pod | `TEAM` du Jenkinsfile | **Non** — le Jenkinsfile vit dans le dépôt de l'équipe |
>
> La suite de cette tâche ne concerne donc **que la seconde**.

**Fichiers :** Modifier `ci/Jenkinsfile.publish-api` (dérivation de la team) ;
le job GitOps du cluster reste à reposer en `CpsFlowDefinition`.

Tant que le pipeline vient du dépôt de l'équipe, `TEAM` est une valeur que
l'équipe écrit — et toute garde en aval raisonne sur une donnée falsifiée.

- [ ] **Étape 1 : écrire le script du job**

`ci/Jenkinsfile.publish-api` :

```groovy
// ci/Jenkinsfile.publish-api — E1 : publication d'API par GitOps.
//
// ⚠ CE FICHIER N'EST PAS UN Jenkinsfile DE DÉPÔT D'ÉQUIPE. C'est la COPIE DE
// RECONSTRUCTION du script INLINE du job Jenkins (CpsFlowDefinition). Le job
// appartient à la PLATEFORME ; le dépôt de l'équipe ne porte plus que son
// contrat OpenAPI et son manifeste.
//
// POURQUOI. Mesuré le 2026-07-31 : assigner une team est réservé à l'admin, et
// à l'admin le produit n'oppose aucun refus cross-team. Le cloisonnement est
// donc une propriété de la CHAÎNE. Or, tant que le pipeline vient du dépôt de
// l'équipe (CpsScmFlowDefinition -> scriptPath: Jenkinsfile), l'équipe écrit
// elle-même le TEAM ci-dessous — et aussi le serviceAccount du podTemplate,
// donc l'identité qui ouvre Vault. Aucune dérivation logée dans un fichier que
// l'équipe contrôle n'est infalsifiable, si ingénieuse soit-elle.
//
// DETTE ASSUMÉE : un script inline n'est pas VERSIONNÉ tant que JCasC n'est pas
// posé. Ce fichier le rend RECONSTRUCTIBLE, ce qui n'est pas la même chose —
// et il faut le dire plutôt que se payer de mots.
//
// UNE VALEUR PAR ÉQUIPE : TEAM et GIT_URL sont posés à l'onboarding de l'équipe
// (GOAL E5). Un job par équipe.
def TEAM    = 'banking-demo'
def GIT_URL = 'http://gitea.ci.svc.cluster.local:3000/banking-demo/accounts-api.git'
def MANIFEST = 'stoa-publish.ansible.yml'

def postStatus(String sha, String state, String buildUrl) {
  sh """
    set -e
    set +x
    VT=\$(vault write -address=\$VAULT_ADDR -field=token \\
      auth/kubernetes/login role=jenkins-agent \\
      jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
    GT=\$(VAULT_TOKEN=\$VT vault kv get -address=\$VAULT_ADDR -field=token secret/ci/probe-status)
    wget -q -O /dev/null \\
      --header "Authorization: token \$GT" \\
      --header 'Content-Type: application/json' \\
      --post-data "{\\"state\\":\\"${state}\\",\\"context\\":\\"jenkins/publish\\",\\"target_url\\":\\"${buildUrl}\\",\\"description\\":\\"publish ${state}\\"}" \\
      "http://gitea.ci.svc.cluster.local:3000/api/v1/repos/banking-demo/accounts-api/statuses/${sha}"
  """
}

properties([buildDiscarder(logRotator(numToKeepStr: '25')), disableConcurrentBuilds()])

podTemplate(serviceAccount: 'jenkins-agent', containers: [
  containerTemplate(name: 'vault', image: 'hashicorp/vault:1.18', command: 'sleep', args: '9999',
    envVars: [envVar(key: 'VAULT_ADDR', value: 'http://vault.ci.svc.cluster.local:8200')]),
  containerTemplate(name: 'ansible',
    image: 'localhost:30300/ci/jenkins-go:v1@sha256:00ad5591be6f1c7b4eccfd7e498abe5e947dc07f01e4d7a247005b65ef0c565b',
    command: 'sleep', args: '9999',
    envVars: [envVar(key: 'VAULT_ADDR', value: 'http://vault.ci.svc.cluster.local:8200'),
              envVar(key: 'VAULT_K8S_ROLE', value: 'jenkins-agent')])
]) {
  node(POD_LABEL) {
    timeout(time: 18, unit: 'MINUTES') {
      // Le dépôt de l'ÉQUIPE fournit les DONNÉES (contrat + manifeste).
      def scmVars = checkout([$class: 'GitSCM',
        branches: [[name: '*/main']],
        userRemoteConfigs: [[url: GIT_URL]]])
      def sha = env.GWT_AFTER ?: scmVars.GIT_COMMIT
      // Le dépôt PLATEFORME fournit le MOTEUR (rôle Ansible).
      dir('platform') {
        checkout([$class: 'GitSCM', branches: [[name: '*/main']],
          userRemoteConfigs: [[url: 'http://gitea.ci.svc.cluster.local:3000/stoa/platform.git']]])
      }
      container('vault') { postStatus(sha, 'pending', env.BUILD_URL) }
      try {
        container('ansible') {
          stage('Attendre la gateway (cycle trial)') {
            sh '''
              set -e
              set +x
              for i in $(seq 1 60); do
                code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' \
                  "http://wm-apigateway-admin.wm.svc:5555/rest/apigateway/health" || true)
                [ "$code" = "200" ] && { echo "gateway prete (essai $i)"; exit 0; }
                sleep 10
              done
              echo "gateway indisponible apres 10 min"; exit 1
            '''
          }
          // TOUTE variable de sécurité passe en -e (précédence 22) : ce que le
          // pipeline ne passe pas, le manifeste de l'équipe peut le poser
          // (include_vars, précédence 18). La liste blanche du rôle est la
          // seconde barrière — les deux, parce qu'un -e oublié échoue en OUVRANT.
          stage('Publier (rôle Ansible, identité de pod -> Vault)') {
            sh """
              set -e
              set +x
              cd platform/poc-control-plane-federation
              ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api.yml \\
                -e apim_ss_manifest="\$WORKSPACE/${MANIFEST}" \\
                -e apim_ss_team=${TEAM} \\
                -e apim_ss_api_base=http://wm-apigateway-admin.wm.svc:5555/rest/apigateway \\
                -e apim_ss_data_base=http://wm-apigateway.wm.svc:5555/gateway \\
                -e apim_ss_auth_mode=basic \\
                -e apim_ss_vault_kv_mount=secret \\
                -e apim_ss_vault_prefix=ci \\
                -e apim_ss_vault_wm_creds_sub=gateways/wm-cluster
            """
          }
          stage('Verify fail-closed (même garde, rejouée en lecture seule)') {
            sh """
              set -e
              set +x
              cd platform/poc-control-plane-federation
              ansible-playbook -i ansible/inventory.lab.ini ansible/publish-api-verify.yml \\
                -e apim_ss_manifest="\$WORKSPACE/${MANIFEST}" \\
                -e apim_ss_team=${TEAM} \\
                -e apim_ss_api_base=http://wm-apigateway-admin.wm.svc:5555/rest/apigateway \\
                -e apim_ss_auth_mode=basic \\
                -e apim_ss_vault_kv_mount=secret \\
                -e apim_ss_vault_prefix=ci \\
                -e apim_ss_vault_wm_creds_sub=gateways/wm-cluster
            """
          }
        }
        container('vault') { postStatus(sha, 'success', env.BUILD_URL) }
      } catch (e) {
        container('vault') { postStatus(sha, 'failure', env.BUILD_URL) }
        throw e
      }
    }
  }
}
```

- [ ] **Étape 2 : consigner la dépendance au dépôt plateforme**

Le script clone `stoa/platform.git` pour le rôle. Vérifier qu'un tel dépôt
existe dans Gitea, ou l'y créer à partir de ce dépôt :

```bash
export KUBECONFIG=~/.kube/k3s-contabo.yaml
kubectl -n ci exec deploy/gitea -- sh -c 'ls /data/git/repositories/' 2>/dev/null || \
  kubectl -n ci exec gitea-0 -- sh -c 'ls /data/git/repositories/'
```

Attendu : la liste des organisations. Si `stoa` n'y est pas, le créer et y
pousser `poc-control-plane-federation/` **avant** de poser le job. Sans le
moteur, le job échoue au premier build — et un job qui n'a jamais tourné ne
prouve rien.

- [ ] **Étape 3 : commit**

```bash
git add ci/Jenkinsfile.publish-api
git commit -m "feat(E1): la définition du pipeline quitte le dépôt de l'équipe

Tant que le Jenkinsfile vient du dépôt de l'équipe, elle écrit elle-même le TEAM
— et le serviceAccount du podTemplate, donc l'identité qui ouvre Vault. Aucune
dérivation logée dans ce fichier n'est infalsifiable. Le job devient un
CpsFlowDefinition inline possédé par la plateforme ; le dépôt d'équipe ne porte
plus que son contrat et son manifeste. Copie de reconstruction versionnée —
reconstructible, pas versionné : JCasC reste la dette.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Tâche 9 — Le privilège de création d'API — D6

**Fichiers :** aucun code du dépôt. Écrit sur la gateway, avec rollback capturé
en tâche 1.

Une équipe peut publier hors chaîne, et son API atterrit en `Default` — lue par
toutes. Cette tâche ferme la brèche **sur le lab**, ou constate qu'on ne peut pas
la fermer sans casser P-1, et le consigne.

- [ ] **Étape 1 : identifier le bit, sur un profil JETABLE**

Créer `e1-probe-profile` (copie du bitmask de `banking-demo`) et
`svc-e1-probe`, puis, bit à bit sur les dix positions à 1 (0-3, 6, 8-9, 11-12,
20), mettre **un** bit à 0 et rejouer `POST /apis` **et** `GET /apis`. Le bit
recherché est celui dont le retrait fait passer `POST /apis` de 201 à 401 **sans**
casser `GET /apis`.

```bash
ssh worker-1 'sudo /root/e1-bitflip.sh' # script écrit à l'étape 2
```

- [ ] **Étape 2 : écrire le script de bisection**

Le script crée le profil jetable, boucle sur les dix positions, et rapporte pour
chacune `POST /apis` et `GET /apis`. Il ne touche **jamais** `banking-demo` ni
`insurance-demo`. Modèle : `docs/superpowers/plans/2026-07-31-e1-matrice-refus.sh`
(mêmes fonctions `req`, `id_pw`, `wait_health`), avec en plus :

```bash
# flip <bitmask> <position> -> bitmask avec la position mise a 0
flip() { printf '%s' "$1" | python3 -c "
import sys,os
b=list(sys.stdin.read().strip()); b[int(os.environ['POS'])]='0'; print(''.join(b))"; }
```

et, pour chaque position, un `PUT /accessProfiles/{id}` du profil jetable suivi
d'une **relecture** (le no-op silencieux n'est pas propre à `/assets/team` — ne
jamais croire un 200).

- [ ] **Étape 3 : appliquer, puis re-mesurer les trois conditions**

Après identification, appliquer le bit sur `banking-demo` et `insurance-demo`,
puis vérifier **les trois** :

| Condition | Attendu |
|---|---|
| `POST /apis` par `svc-banking-demo` | **401** — la brèche est fermée |
| `GET /apis` scopé par `svc-banking-demo` | **200 et scopé** — sinon P-1 tombe |
| `GET /apis/{id}` d'une autre équipe | **401** — l'isolation tient |

- [ ] **Étape 4 : rollback si l'une des deux dernières rougit**

```bash
ssh worker-1 'sudo grep accessProfiles -A6 /root/e1-t0.txt'
# puis PUT /accessProfiles/{id} avec le bitmask relevé en tâche 1, et relecture.
```

Si `GET /apis` ou l'isolation casse : **remettre le bitmask** et consigner la
brèche comme dette assumée. Casser une preuve acquise pour fermer une brèche de
lab serait un mauvais échange — le modèle cible la ferme de toute façon en ne
donnant aucun compte gateway aux équipes produit.

- [ ] **Étape 5 : commit du constat**

```bash
git add docs/superpowers/plans/2026-07-31-e1-producteur-gitops.md
git commit -m "test(E1): quel privilège porte la création d'API — décomposé par bit-flip mesuré

Aucun endpoint REST ne nomme les privilèges (4 candidats -> 404) et les deux
équipes de démonstration avaient exactement le bitmask du profil système. La
correspondance est donc établie par retrait d'un bit sur un profil jetable, pas
par lecture.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Tâche 10 — Les documents disent ce que la mesure a montré — D8

**Fichiers :**
- Modifier : `poc-control-plane-federation/GOAL-self-service-api-app-2026-07-09.md`
- Modifier : `poc-control-plane-federation/GOAL-socle-vers-gateway-2026-07-28.md`
- Créer : `poc-control-plane-federation/HANDOFF-2026-07-31-E1-PRODUCTEUR.md`

- [ ] **Étape 1 : remplacer la porte E1 du GOAL parent**

Dans la section `### E1`, remplacer la ligne `**Preuve E1 :**` par les cinq
portes, en disant que la précédente était **fausse** :

```markdown
**Preuve E1 — RÉÉCRITE le 2026-07-31, l'énoncé précédent était faux.**
~~publication cross-team (assigner une team dont on n'est pas membre) refusée
400 « User cannot assign the specified team to API »~~ — **ce refus n'existe
pas sur la gateway du cluster.** Mesuré : un membre d'équipe reçoit **401 sur
la ressource `assets`**, même pour SA PROPRE équipe (assigner une team est une
opération d'admin) ; et à l'admin — l'identité que la chaîne porte — le produit
n'oppose **aucun** refus cross-team (déplacer une API vers l'équipe d'un tiers :
**200**). Le refus fin observé au spike #1 (2026-07-09, lab Docker) tenait à une
configuration de privilèges, pas à une propriété de la 10.15. Le cloisonnement
est donc une propriété **de la chaîne**, à construire et à prouver : voir
`docs/superpowers/specs/2026-07-31-e1-producteur-gitops-design.md`, portes P-1
à P-5.

**Découverte non prévue** : une équipe peut publier **hors chaîne**
(`POST /apis` → 201) et son API atterrit en `Default`, **lue 200 par une équipe
tierce**. Sur les applications, E3 parlait d'« un geste qu'on peut oublier » ;
sur les APIs, l'équipe **ne peut pas** faire le geste.
```

- [ ] **Étape 2 : retirer la dette labctl du GOAL socle, avec sa raison**

Dans le tableau de dette de `GOAL-socle-vers-gateway-2026-07-28.md`, ligne
`team: natif dans labctl` :

```markdown
| ~~`team:` natif dans labctl (moteur unique ADR-076)~~ | spéc F4 § D1 | **SANS OBJET depuis le 2026-07-31** — E1 (D1) fait passer la chaîne cluster au rôle Ansible `apim_publish_api`, qui porte désormais tout le durcissement (assetType, relecture fail-closed, équipe du pipeline, liste blanche du manifeste). Renverse la décision F4 §D1, et il faut le dire ainsi : maintenir deux moteurs, c'était corriger deux fois les mêmes quirks wM et n'en prouver qu'un. `labctl` reste la spec vérifiée parquée. |
```

- [ ] **Étape 3 : écrire le handoff**

`HANDOFF-2026-07-31-E1-PRODUCTEUR.md`, sur le modèle des précédents : « En une
phrase », ce qui a été livré, la porte en clair, **ce que la mesure a corrigé**,
ce qui reste ouvert (gestes exploitant), et une section honnête sur les erreurs
de la passe.

- [ ] **Étape 4 : commit final**

```bash
git add poc-control-plane-federation/
git commit -m "docs(E1): la porte du GOAL est remplacée, pas rayée — elle ne mesurait rien

Retirer une porte sans dire qu'elle était fausse laisserait croire qu'on l'a
passée. Même traitement que le keepalive */25 du handoff F4.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Preuve d'exécution — 2026-08-02, gateway du cluster

Les cinq portes et les trois sabotages joués sont **verts**. Toutes les
requêtes visent le Service d'administration (réplique unique).

### Le décor, et une correction de la méthode

Le rôle tourne dans un **pod agent portant le SA `jenkins-agent`**, pas dans le
pod du contrôleur Jenkins. Premier essai depuis le contrôleur :

```
Login Vault Kubernetes REFUSÉ (HTTP 403) sur auth/kubernetes/login
(role=jenkins-agent, namespace=<aucun>)
```

C'est **la mécanique G-c qui fonctionne**, pas une panne : le rôle Vault est lié
au ServiceAccount de l'agent, et le contrôleur ne l'a pas. Mesurer depuis le
contrôleur aurait mesuré autre chose que la chaîne. D'où un pod jetable
`e1-runner` (`serviceAccountName: jenkins-agent`, image `jenkins-go` par digest),
supprimé en fin de passe.

Le rôle fait son propre login Vault (`VAULT_K8S_ROLE=jenkins-agent`,
`apim_common/secrets.yml`) : le pipeline n'a plus à faire transiter de token
entre conteneurs, contrairement au montage F4.

### Les portes

| Porte | Sortie réelle |
|---|---|
| **P-1a** publication cloisonnée | `TEAM_CONFIRMED : 'e1-gate-api' cloisonnée sur 'banking-demo' (teams=['Administrators', 'banking-demo'], Default retirée).` — `ok=37 failed=0` |
| **P-1b** l'autre équipe ne la voit pas | témoin `svc-banking-demo GET /apis/{id}` → **200** ; `svc-insurance-demo` → **401**. Catalogues : banking-demo `['accounts-read','carto-probe-api','e1-gate-api']`, insurance-demo `['carto-probe-api']` |
| **P-2** refus cross-team | `TEAM_FORBIDDEN : le manifeste réclame la team 'insurance-demo' alors que la chaîne publie au nom de 'banking-demo'` — `failed=1` |
| **P-2b** le refus n'a rien créé | `e1-cross-api ABSENTE du catalogue` |
| **P-3** le 200 ne prouve rien | `TEAM_UNCONFIRMED : après POST /assets/team (HTTP 200), l'API 'e1-gate-api' porte teams=['Administrators', 'banking-demo'] — attendu : 'insurance-demo' présente` |
| **P-4** fail-closed sans équipe | `TEAM_UNDEFINED : aucune équipe pour l'API 'e1-gate-api'` |
| **P-5** injection par le manifeste | `MANIFEST_KEYS_FORBIDDEN : … déclare ['apim_ss_api_base'], hors de la liste blanche ['apim_api']` |
| **verify** | `PUBLISH_CONFIRMED : e1-gate-api v1.0.0 publiée, active et cloisonnée sur 'banking-demo'` |
| **verify (contre-épreuve)** | attendu `insurance-demo` sur une API de `banking-demo` → `PUBLISH_UNCONFIRMED`. Un verify qui ne rougit jamais ne prouve rien. |

### Ce que P-3 démontre exactement

`assetType: "API"` retiré du corps du POST **dans le pod**, puis demande de
déplacer `e1-gate-api` vers `insurance-demo` : la gateway répond **HTTP 200** et
les teams restent `['Administrators','banking-demo']`. Le code de retour est
vert, l'effet est nul. **C'est la relecture, et elle seule, qui l'attrape.**
Rôle sain restauré ensuite, chaîne repassée au vert (`TEAM_CONFIRMED`).

### P-4 et P-5 : les gardes précèdent le réseau

Les deux ont été joués avec `apim_ss_api_base` pointé sur un **port mort**
(`127.0.0.1:1`). Aucun `Connection refused` n'apparaît : les gardes rougissent
avant qu'une socket soit ouverte. C'est la preuve de D4 — un refus ne laisse
rien derrière lui parce qu'il survient avant la première écriture.

### Nettoyage

`e1-gate-api` désactivée (`200`) puis supprimée (`204`) ; `e1-cross-api` jamais
créée ; pod `e1-runner` supprimé. Catalogue final :
`['accounts-read', 'carto-probe-api']` — l'état d'avant la passe.

### Ce qui n'est PAS fait

- **Tâche 8** (le pipeline quitte le dépôt d'équipe) : l'artefact
  `ci/Jenkinsfile.publish-api` est livré, mais **poser le job et créer le dépôt
  plateforme dans Gitea sont des gestes exploitant**. Tant qu'ils ne sont pas
  faits, `TEAM` reste écrit dans le dépôt de l'équipe : les gardes sont réelles,
  leur **autorité** ne l'est pas encore.
- **Tâche 9** (D6, retrait du privilège de création d'API) : non exécutée.

---

## Auto-revue du plan

**Couverture de la spec :** D1 → tâches 7 et 8 ; D2 → tâche 8 ; D3 → tâche 3 ;
D4 → tâche 5 ; D5 → tâche 2 ; D6 → tâche 9 ; D7 → tâche 6 ; D8 → tâche 10.
P-1 → tâche 7 étapes 3-4 ; P-2 → étapes 5-6 ; P-3 → étape 8 ; P-4 et P-5 →
étape 7. Sabotages : `assetType` (7.8), cross-team (7.5), team inconnue
(`TEAM_UNKNOWN`, couvert par l'assertion de la tâche 4 — non joué isolément,
**écart assumé et noté**), injection (7.7).

**Cohérence des noms :** `pub_team_name` est posé en tâche 3 et consommé en
tâches 4, 5 et 6 ; `pub_manifest_path` posé en tâche 2 et consommé par
`resolve-env.yml` ; `apim_pub_manifest_allowed` et `apim_pub_require_team`
déclarés en tâche 2 étape 5, consommés en tâches 2 et 3.

**Écart connu :** le préfixe des faits du rôle producteur est `pub_*`, celui du
rôle consommateur `ss_*`. Volontaire — deux rôles peuvent tourner dans le même
play (pipeline combiné) et un préfixe partagé les ferait se marcher dessus.
