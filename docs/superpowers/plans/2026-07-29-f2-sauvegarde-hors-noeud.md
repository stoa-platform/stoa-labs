# F2 — Sauvegarde réellement hors-nœud : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** les trois PVC du socle CI archivés sur worker-2 (hôte distinct du nœud porteur worker-5), avec staging local, garde à chaud pour Vault, fenêtre de sync Argo, quarantaine, rotation — et la contre-épreuve de restauration exercée.

**Architecture :** extension du rôle `cluster_backup` (lot 1). L'offsite global passe à worker-2 ; les PVC sont archivés localement sur leur nœud pendant une quiescence courte (Vault exclu, garde par empreinte sha256 avant/après), puis transférés hors fenêtre via le poste de contrôle. Un playbook de drill restaure la dernière archive gitea sur worker-2 et y retrouve l'utilisateur `ci`.

**Tech stack :** Ansible (exécuté du poste de contrôle, inventaire `ansible/inventory.contabo.ini`), k3s kubectl, tar/gzip/sha256sum/sqlite3 sur les nœuds. Spécification : `docs/superpowers/specs/2026-07-29-f2-sauvegarde-hors-noeud-design.md`.

## Global Constraints

- Aucune valeur secrète ne sort des nœuds ni ne s'affiche (leçon F1) — seuls comptages, empreintes et messages de progression passent en sortie.
- Vault ne doit **jamais** sortir scellé d'une sauvegarde : échec d'entrée s'il est scellé, assert final `Sealed=false`.
- Fail-closed partout : toute garde qui rougit met les archives du run en quarantaine `.suspect` et fait échouer le play.
- `backup_mode: "0600"`, répertoires `0700` root, comme au lot 1.
- Style du dépôt : YAML Ansible commenté en français, commentaires expliquant le POURQUOI.

---

### Task 1 : defaults du rôle + en-tête de backup.yml

**Files:**
- Modify: `ansible/roles/cluster_backup/defaults/main.yml`
- Modify: `ansible/backup.yml`

**Interfaces:**
- Produces : variables `backup_offsite_host: worker-2`, `backup_pvc_staging_dir`, `backup_hot_workloads`, `backup_sync_window_apps`, `backup_argocd_namespace` — consommées par la Task 2.

- [ ] **Step 1 : remplacer le bloc offsite des defaults**

Dans `defaults/main.yml`, remplacer le commentaire + les deux variables offsite par :

```yaml
# Copie hors-nœud. Une sauvegarde qui ne survit pas à la perte de la machine
# qu'elle sauvegarde ne sert à rien. Cible : worker-2 — HORS cluster (isolation
# L2 Contabo w1↔w2), donc il survit à la perte de n'importe quel nœud du
# cluster. Joignabilité et espace (361 Go) mesurés le 2026-07-29. Le transfert
# relaie par le poste de contrôle : les workers ne se font toujours pas
# confiance en SSH entre eux.
backup_offsite_host: "worker-2"
backup_offsite_dir: "/var/lib/k3s-backups/offsite"

# Staging local des archives PVC sur leur nœud porteur : la fenêtre de
# quiescence dure le temps d'un tar sur disque local (secondes), pas le temps
# d'un transfert WAN via le poste de contrôle (minutes).
backup_pvc_staging_dir: "/var/lib/k3s-backups/pvc"
```

- [ ] **Step 2 : ajouter les variables de fenêtre de sync et de charges à chaud**

À la fin de `defaults/main.yml` :

```yaml
# Charges NON quiescées pendant la sauvegarde (format kind/name, en minuscules).
# Vault y est tant que la détention des parts de descellement n'est pas prouvée
# (handoff F1) : un Vault redémarré revient SCELLÉ, et sans parts le socle est
# mort. Son PVC est archivé à chaud sous garde d'empreinte (voir pvc.yml).
# Quand l'exploitant aura prouvé la détention (procédure non destructive du
# handoff F1), vider cette liste restitue la quiescence pleine.
backup_hot_workloads:
  - statefulset/vault

# Applications Argo CD dont l'auto-sync est suspendu pendant la fenêtre de
# sauvegarde : selfHeal revert la mise à zéro des répliques en ~5 s (mesuré au
# lot 1) — la fenêtre de synchronisation est la vraie réponse, la garde
# post-archive n'est plus qu'une défense en profondeur.
backup_sync_window_apps:
  - ci-gitea
  - ci-jenkins
  - ci-vault
backup_argocd_namespace: "argocd"
```

- [ ] **Step 3 : compléter l'en-tête de `ansible/backup.yml`**

Après la ligne « À automatiser (cron / timer systemd)… », ajouter :

```yaml
# Contre-épreuve F2 (à exercer après toute évolution du rôle) :
#   ansible-playbook -i inventory.contabo.ini backup-restore-drill.yml
# restaure la dernière archive gitea SUR worker-2 et y retrouve l'utilisateur
# `ci` — une sauvegarde jamais restaurée n'est qu'une hypothèse.
```

- [ ] **Step 4 : vérifier la syntaxe**

Run : `cd ansible && ansible-playbook -i inventory.contabo.ini backup.yml --syntax-check`
Attendu : `playbook: backup.yml`

- [ ] **Step 5 : commit**

```bash
git add ansible/roles/cluster_backup/defaults/main.yml ansible/backup.yml
git commit -m "feat(backup): F2 — cible hors-nœud worker-2, staging local, variables fenêtre de sync"
```

---

### Task 2 : réécriture de `roles/cluster_backup/tasks/pvc.yml`

**Files:**
- Modify: `ansible/roles/cluster_backup/tasks/pvc.yml` (remplacement de la section quiescence/archive/read-back ; la sélection des PV en tête est conservée telle quelle, commentaires de déviation compris)

**Interfaces:**
- Consumes : `backup_stamp` (posé par main.yml), variables de la Task 1, `backup_keep`, `backup_mode`.
- Produces : archives `pvc-<ns>-<name>-<stamp>.tar.gz` dans `{{ backup_pvc_staging_dir }}` (nœud porteur) et `{{ backup_offsite_dir }}` (worker-2).

- [ ] **Step 1 : conserver la tête du fichier** (listing des PV, sélection `backup_pvcs`, assert « au moins un PVC ») — inchangée, y compris les deux commentaires de déviation du lot 1.

- [ ] **Step 2 : insérer, après l'assert « au moins un PVC », la porte F2 et le partitionnement**

```yaml
# --- Porte F2 : la cible n'est JAMAIS le nœud porteur --------------------------
# Encodée dans le rôle : si un PVC migre un jour sur l'hôte de sauvegarde, la
# sauvegarde échoue fermée au lieu de redevenir silencieusement co-localisée.
- name: "Assert : l'hôte de sauvegarde est distinct du nœud porteur de chaque PV"
  ansible.builtin.assert:
    that:
      - backup_offsite_host != item.node
    fail_msg: >-
      {{ item.ns }}/{{ item.name }} vit sur {{ item.node }}, qui est aussi
      l'hôte de sauvegarde. Une copie co-localisée ne protège de rien —
      sauvegarde REFUSÉE (porte F2).
  loop: "{{ backup_pvcs }}"
  loop_control:
    label: "{{ item.ns }}/{{ item.name }}@{{ item.node }}"

# --- Charges à chaud : exclues de la quiescence -------------------------------
- name: "Noms courts des charges à chaud"
  ansible.builtin.set_fact:
    backup_hot_names: "{{ backup_hot_workloads | map('regex_replace', '^.*/', '') | list }}"

# Les PVC des charges à chaud sont repérés par leur claim (vault-data-vault-0
# contient « vault ») : suffisant pour ce périmètre, et un faux positif serait
# bénin (une garde d'empreinte en plus, jamais en moins).
- name: "Partitionner les PVC : à chaud vs quiescés"
  ansible.builtin.set_fact:
    backup_pvcs_hot: "{{ (backup_hot_names | length > 0) | ternary(
      backup_pvcs | selectattr('name', 'search', '(' ~ (backup_hot_names | join('|')) ~ ')') | list,
      []) }}"

- name: "Regex des pods à chaud (tolérés pendant la quiescence)"
  ansible.builtin.set_fact:
    backup_hot_pod_re: "^pod/({{ backup_hot_names | join('|') }})-"
```

- [ ] **Step 3 : garde d'entrée Vault** (juste après)

```yaml
# --- Vault ne doit JAMAIS sortir scellé d'une sauvegarde ----------------------
# La détention des parts de descellement n'est pas prouvée (handoff F1) : on ne
# part pas d'un socle déjà dégradé, et on vérifiera en sortie qu'on ne l'a pas
# dégradé nous-mêmes.
- name: "Vault : état avant sauvegarde"
  ansible.builtin.command:
    cmd: k3s kubectl -n ci exec vault-0 -- vault status -format=json
  become: true
  register: backup_vault_before
  changed_when: false
  failed_when: false
  when: "'statefulset/vault' in backup_hot_workloads"

- name: "Assert : Vault est descellé avant de commencer"
  ansible.builtin.assert:
    that:
      - backup_vault_before.stdout | length > 0
      - not ((backup_vault_before.stdout | from_json).sealed)
    fail_msg: >-
      Vault est scellé ou injoignable. Tant que la détention des parts n'est
      pas prouvée (handoff F1, § « Le point à lever »), aucune sauvegarde ne
      doit partir d'un socle dégradé — la lever d'abord.
  when: "'statefulset/vault' in backup_hot_workloads"
```

- [ ] **Step 4 : conserver « Mémoriser le nombre de répliques courant »** (inchangé), puis ajouter la capture des politiques de sync

```yaml
# --- Fenêtre de synchronisation Argo CD ---------------------------------------
# Capture AVANT le bloc : si le play meurt avant le patch, rien n'est à
# restaurer ; si le patch a eu lieu, `always` restaure depuis cette capture.
- name: "Capturer les Applications (politique de synchronisation)"
  ansible.builtin.command:
    cmd: k3s kubectl -n {{ backup_argocd_namespace }} get application {{ item }} -o json
  become: true
  register: backup_apps_json
  changed_when: false
  loop: "{{ backup_sync_window_apps }}"

- name: "Retenir la politique automated de chaque Application"
  ansible.builtin.set_fact:
    backup_sync_automated: "{{ backup_sync_automated | default({}) | combine({
      item.item: ((item.stdout | from_json).spec.syncPolicy | default({})).automated | default('') }) }}"
  loop: "{{ backup_apps_json.results }}"
  loop_control:
    label: "{{ item.item }}"
```

- [ ] **Step 5 : remplacer le bloc « Quiescer, archiver, redémarrer »** par :

```yaml
# `block`/`always` : si l'archivage échoue, les charges ne doivent pas rester à
# zéro ni les Applications sans auto-sync. GARANTIE HONNÊTE inchangée du lot 1 :
# `always` ne s'exécute PAS si l'hôte de contrôle devient UNREACHABLE en cours
# de bloc. Remède manuel : `k3s kubectl -n ci scale deploy,statefulset --all
# --replicas=1` puis re-patcher `spec.syncPolicy.automated` des Applications
# {{ backup_sync_window_apps }} (valeurs dans Git côté stoa).
- name: "Fenêtre fermée : quiescer, archiver localement, redémarrer"
  block:
    - name: "Ouvrir la fenêtre : suspendre l'auto-sync des Applications"
      ansible.builtin.command:
        cmd: >-
          k3s kubectl -n {{ backup_argocd_namespace }} patch application {{ item }}
          --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
      become: true
      loop: "{{ backup_sync_window_apps }}"
      when: backup_sync_automated[item] != ''
      changed_when: true

    - name: "Quiescer les charges (sauf celles à chaud)"
      ansible.builtin.command:
        cmd: >-
          k3s kubectl -n {{ item.0.item }} scale {{ item.1.split('=')[0] }}
          --replicas=0
      become: true
      loop: "{{ backup_replicas.results | subelements('stdout_lines') }}"
      loop_control:
        label: "{{ item.0.item }} {{ item.1 }}"
      when:
        - item.1 | length > 0
        - (item.1.split('=')[0] | lower) not in (backup_hot_workloads | map('lower') | list)
      changed_when: true

    # kubectl est exécuté dans $( ) sous `set -e` : son échec fait échouer la
    # tâche au lieu de produire un faux « aucun pod » (fail-closed). Le
    # `grep -v '^$'` évite qu'une sortie vide compte pour une ligne.
    - name: "Attendre l'arrêt des pods quiescés (les charges à chaud restent)"
      ansible.builtin.shell:
        cmd: |
          set -eu
          out=$(k3s kubectl -n {{ item }} get pods -o name)
          echo "$out" | grep -Ev '{{ backup_hot_pod_re }}' | grep -v '^$' || true
        executable: /bin/bash
      become: true
      loop: "{{ backup_pvc_namespaces }}"
      register: backup_pods_waiting
      until: backup_pods_waiting.stdout == ""
      retries: 36
      delay: 5
      changed_when: false

    - name: "Créer le répertoire de staging sur chaque nœud porteur"
      ansible.builtin.file:
        path: "{{ backup_pvc_staging_dir }}"
        state: directory
        owner: root
        group: root
        mode: "0700"
      become: true
      delegate_to: "{{ item }}"
      loop: "{{ backup_pvcs | map(attribute='node') | unique | list }}"

    # Garde à chaud, temps 1 : empreinte du contenu AVANT archivage. Flux tar
    # NON compressé — gzip horodate ses en-têtes, comparer le compressé
    # mentirait.
    - name: "Empreinte des PVC à chaud, avant archivage"
      ansible.builtin.shell:
        cmd: set -o pipefail; tar cf - -C {{ item.path }} . | sha256sum
        executable: /bin/bash
      become: true
      delegate_to: "{{ item.node }}"
      loop: "{{ backup_pvcs_hot }}"
      loop_control:
        label: "{{ item.ns }}/{{ item.name }}"
      register: backup_hot_before
      changed_when: false

    # Archive LOCALE sur le nœud porteur : la fenêtre de quiescence dure le
    # temps d'un tar sur disque local, le WAN attend la fin du bloc.
    - name: "Archiver chaque PVC localement sur son nœud"
      ansible.builtin.shell:
        cmd: |
          set -euo pipefail
          f={{ backup_pvc_staging_dir }}/pvc-{{ item.ns }}-{{ item.name }}-{{ backup_stamp }}.tar.gz
          tar czf "$f" -C {{ item.path }} .
          chmod {{ backup_mode }} "$f"
        executable: /bin/bash
      become: true
      delegate_to: "{{ item.node }}"
      loop: "{{ backup_pvcs }}"
      loop_control:
        label: "{{ item.ns }}/{{ item.name }}"
      changed_when: true

    - name: "Empreinte des PVC à chaud, après archivage"
      ansible.builtin.shell:
        cmd: set -o pipefail; tar cf - -C {{ item.path }} . | sha256sum
        executable: /bin/bash
      become: true
      delegate_to: "{{ item.node }}"
      loop: "{{ backup_pvcs_hot }}"
      loop_control:
        label: "{{ item.ns }}/{{ item.name }}"
      register: backup_hot_after
      changed_when: false

    # Empreintes identiques ⇒ rien n'a écrit pendant la fenêtre ⇒ l'archive à
    # chaud égale le contenu au repos. Sinon : quarantaine PUIS échec — une
    # archive suspecte qui ressemble à une saine rassure à tort.
    - name: "Quarantaine des archives à chaud dont l'empreinte a bougé"
      ansible.builtin.command:
        cmd: >-
          mv {{ backup_pvc_staging_dir }}/pvc-{{ item.0.item.ns }}-{{ item.0.item.name }}-{{ backup_stamp }}.tar.gz
          {{ backup_pvc_staging_dir }}/pvc-{{ item.0.item.ns }}-{{ item.0.item.name }}-{{ backup_stamp }}.tar.gz.suspect
      become: true
      delegate_to: "{{ item.0.item.node }}"
      loop: "{{ backup_hot_before.results | zip(backup_hot_after.results) | list }}"
      loop_control:
        label: "{{ item.0.item.ns }}/{{ item.0.item.name }}"
      when: item.0.stdout != item.1.stdout
      changed_when: true

    - name: "Assert : aucune écriture pendant l'archivage à chaud"
      ansible.builtin.assert:
        that:
          - item.0.stdout == item.1.stdout
        fail_msg: >-
          Le contenu de {{ item.0.item.ns }}/{{ item.0.item.name }} a changé
          pendant l'archivage à chaud — archive en QUARANTAINE (.suspect),
          sauvegarde REJETÉE plutôt que de rassurer à tort.
      loop: "{{ backup_hot_before.results | zip(backup_hot_after.results) | list }}"
      loop_control:
        label: "{{ item.0.item.ns }}/{{ item.0.item.name }}"

    # Défense en profondeur : avec la fenêtre de sync fermée, plus AUCUN pod
    # quiescé ne doit réapparaître. Si ça arrive, quarantaine générale du run.
    - name: "Lister les pods quiescés réapparus pendant l'archivage"
      ansible.builtin.shell:
        cmd: |
          set -eu
          out=$(k3s kubectl -n {{ item }} get pods -o name)
          echo "$out" | grep -Ev '{{ backup_hot_pod_re }}' | grep -v '^$' || true
        executable: /bin/bash
      become: true
      loop: "{{ backup_pvc_namespaces }}"
      loop_control:
        label: "{{ item }}"
      register: backup_pods_post_archive
      changed_when: false

    - name: "Quarantaine générale si un pod quiescé est réapparu"
      ansible.builtin.shell:
        cmd: |
          set -eu
          for f in {{ backup_pvc_staging_dir }}/pvc-*-{{ backup_stamp }}.tar.gz; do
            [ -e "$f" ] && mv "$f" "$f.suspect" || true
          done
        executable: /bin/bash
      become: true
      delegate_to: "{{ item }}"
      loop: "{{ backup_pvcs | map(attribute='node') | unique | list }}"
      when: backup_pods_post_archive.results | map(attribute='stdout') | select('ne', '') | list | length > 0
      changed_when: true

    - name: "Assert : aucun pod quiescé n'est réapparu pendant l'archivage"
      ansible.builtin.assert:
        that:
          - item.stdout == ""
        fail_msg: >-
          Pod(s) réapparu(s) dans {{ item.item }} pendant l'archivage :
          {{ item.stdout_lines | join(', ') }} — la fenêtre de sync était
          pourtant fermée. Archives en QUARANTAINE, sauvegarde REJETÉE.
      loop: "{{ backup_pods_post_archive.results }}"
      loop_control:
        label: "{{ item.item }}"

  always:
    - name: "Redémarrer les charges, y compris après échec"
      ansible.builtin.command:
        # `item.0` est le résultat de la tâche « Mémoriser » ; le namespace
        # interrogé est dans `item.0.item`. Re-scaler une charge à chaud vers
        # sa valeur d'origine est un no-op (le pod n'est pas touché).
        cmd: >-
          k3s kubectl -n {{ item.0.item }} scale {{ item.1.split('=')[0] }}
          --replicas={{ item.1.split('=')[1] }}
      become: true
      loop: "{{ backup_replicas.results | subelements('stdout_lines') }}"
      loop_control:
        label: "{{ item.0.item }} {{ item.1 }}"
      when: item.1 | length > 0
      changed_when: true

    - name: "Refermer la fenêtre : restaurer l'auto-sync des Applications"
      ansible.builtin.command:
        cmd: >-
          k3s kubectl -n {{ backup_argocd_namespace }} patch application {{ item }}
          --type=merge -p '{"spec":{"syncPolicy":{"automated":{{ backup_sync_automated[item] | to_json }}}}}'
      become: true
      loop: "{{ backup_sync_window_apps }}"
      when: backup_sync_automated[item] != ''
      changed_when: true
```

- [ ] **Step 6 : remplacer le read-back final (glob) par read-back local, transfert, read-back hors-nœud, rotation, assert Vault**

```yaml
# --- Read-back local, puis transfert hors-nœud (hors fenêtre) -----------------
- name: "Read-back local : archives stagées lisibles et non vides"
  ansible.builtin.shell:
    cmd: |
      set -euo pipefail
      f={{ backup_pvc_staging_dir }}/pvc-{{ item.ns }}-{{ item.name }}-{{ backup_stamp }}.tar.gz
      [ -e "$f" ] || { echo "archive absente : $f"; exit 1; }
      entries=$(tar tzf "$f" | wc -l)
      [ "$entries" -gt 1 ] || { echo "archive vide ou quasi vide : $f"; exit 1; }
      echo "$f : $entries entrées"
    executable: /bin/bash
  become: true
  delegate_to: "{{ item.node }}"
  loop: "{{ backup_pvcs }}"
  loop_control:
    label: "{{ item.ns }}/{{ item.name }}"
  changed_when: false

# Même motif que le transfert k3s : relais par le poste de contrôle, en flux,
# `pipefail` obligatoire (sans lui un cat échoué serait masqué par le tee).
- name: "Transférer vers l'hôte de sauvegarde, en flux, via le poste de contrôle"
  ansible.builtin.shell:
    cmd: |
      set -euo pipefail
      f=pvc-{{ item.ns }}-{{ item.name }}-{{ backup_stamp }}.tar.gz
      ssh -o BatchMode=yes {{ item.node }} \
        "sudo cat {{ backup_pvc_staging_dir }}/$f" \
      | ssh -o BatchMode=yes {{ backup_offsite_host }} \
        "sudo install -d -m 0700 {{ backup_offsite_dir }} && \
         sudo tee {{ backup_offsite_dir }}/$f >/dev/null && \
         sudo chmod {{ backup_mode }} {{ backup_offsite_dir }}/$f"
    executable: /bin/bash
  delegate_to: localhost
  become: false
  loop: "{{ backup_pvcs }}"
  loop_control:
    label: "{{ item.ns }}/{{ item.name }}"
  changed_when: true

- name: "Read-back hors-nœud : lisible, non vide, empreinte égale au staging"
  ansible.builtin.shell:
    cmd: |
      set -euo pipefail
      f=pvc-{{ item.ns }}-{{ item.name }}-{{ backup_stamp }}.tar.gz
      a=$(ssh -o BatchMode=yes {{ item.node }} "sudo sha256sum {{ backup_pvc_staging_dir }}/$f" | awk '{print $1}')
      b=$(ssh -o BatchMode=yes {{ backup_offsite_host }} "sudo sha256sum {{ backup_offsite_dir }}/$f" | awk '{print $1}')
      [ "$a" = "$b" ] || { echo "empreintes divergentes pour $f"; exit 1; }
      entries=$(ssh -o BatchMode=yes {{ backup_offsite_host }} "sudo tar tzf {{ backup_offsite_dir }}/$f | wc -l")
      [ "$entries" -gt 1 ] || { echo "archive hors-nœud vide : $f"; exit 1; }
      echo "$f : $entries entrées sur {{ backup_offsite_host }}, empreinte vérifiée"
    executable: /bin/bash
  delegate_to: localhost
  become: false
  loop: "{{ backup_pvcs }}"
  loop_control:
    label: "{{ item.ns }}/{{ item.name }}"
  changed_when: false

# --- Rotation par claim, des deux côtés ---------------------------------------
# Le motif `*.tar.gz` ne matche pas `*.tar.gz.suspect` : les archives en
# quarantaine échappent à la rotation et attendent une décision humaine.
- name: "Rotation des archives PVC stagées (par claim)"
  ansible.builtin.shell:
    cmd: >-
      ls -1t {{ backup_pvc_staging_dir }}/pvc-{{ item.ns }}-{{ item.name }}-*.tar.gz 2>/dev/null
      | tail -n +{{ backup_keep + 1 }} | xargs -r rm -f
  become: true
  delegate_to: "{{ item.node }}"
  loop: "{{ backup_pvcs }}"
  loop_control:
    label: "{{ item.ns }}/{{ item.name }}"
  changed_when: true

- name: "Rotation des archives PVC hors-nœud (par claim)"
  ansible.builtin.shell:
    cmd: >-
      ls -1t {{ backup_offsite_dir }}/pvc-{{ item.ns }}-{{ item.name }}-*.tar.gz 2>/dev/null
      | tail -n +{{ backup_keep + 1 }} | xargs -r rm -f
  become: true
  delegate_to: "{{ backup_offsite_host }}"
  loop: "{{ backup_pvcs }}"
  loop_control:
    label: "{{ item.ns }}/{{ item.name }}"
  changed_when: true

# --- La sauvegarde n'a pas dégradé ce qu'elle protège -------------------------
- name: "Vault : état après sauvegarde"
  ansible.builtin.command:
    cmd: k3s kubectl -n ci exec vault-0 -- vault status -format=json
  become: true
  register: backup_vault_after
  changed_when: false
  failed_when: false
  when: "'statefulset/vault' in backup_hot_workloads"

- name: "Assert : Vault est toujours descellé après la sauvegarde"
  ansible.builtin.assert:
    that:
      - backup_vault_after.stdout | length > 0
      - not ((backup_vault_after.stdout | from_json).sealed)
    fail_msg: >-
      Vault est scellé APRÈS la sauvegarde : le run a dégradé le socle qu'il
      protège — intervention humaine requise (parts de descellement).
    success_msg: "Vault descellé, socle intact."
  when: "'statefulset/vault' in backup_hot_workloads"
```

- [ ] **Step 7 : mettre à jour le commentaire d'en-tête de pvc.yml** (référence à la spec F2, disparition du transfert-pendant-quiescence)

- [ ] **Step 8 : vérifier la syntaxe**

Run : `cd ansible && ansible-playbook -i inventory.contabo.ini backup.yml --syntax-check`
Attendu : `playbook: backup.yml`

- [ ] **Step 9 : commit**

```bash
git add ansible/roles/cluster_backup/tasks/pvc.yml
git commit -m "feat(backup): F2 — staging local, garde à chaud Vault, fenêtre de sync Argo, quarantaine, rotation PVC"
```

---

### Task 3 : playbook de contre-épreuve `backup-restore-drill.yml`

**Files:**
- Create: `ansible/backup-restore-drill.yml`

**Interfaces:**
- Consumes : archives `pvc-ci-gitea-data-gitea-0-*.tar.gz` dans `/var/lib/k3s-backups/offsite` sur worker-2 (Task 2).

- [ ] **Step 1 : écrire le playbook**

```yaml
---
# backup-restore-drill.yml — contre-épreuve F2 : une sauvegarde jamais
# restaurée n'est qu'une hypothèse. Depuis l'hôte de sauvegarde (worker-2,
# DISTINCT du nœud porteur des données), restaurer la dernière archive gitea
# et prouver que l'utilisateur `ci` s'y trouve — le même exercice qu'au lot 1,
# rejoué depuis le bon côté du sinistre.
#
# Usage :
#   ansible-playbook -i inventory.contabo.ini backup-restore-drill.yml
#
# Rien de sensible ne s'affiche : la base restaurée reste sur le nœud, seuls
# un chemin et un comptage sortent. Le répertoire de travail est root-only et
# détruit en fin d'exercice, succès ou échec.

- name: "Contre-épreuve F2 : restauration depuis l'hôte de sauvegarde"
  hosts: "{{ drill_host | default('worker-2') }}"
  gather_facts: false
  become: true
  vars:
    drill_offsite_dir: /var/lib/k3s-backups/offsite
    drill_claim_prefix: pvc-ci-gitea-data-gitea-0
  tasks:
    - name: "Trouver la dernière archive gitea"
      ansible.builtin.shell:
        cmd: ls -1t {{ drill_offsite_dir }}/{{ drill_claim_prefix }}-*.tar.gz 2>/dev/null | head -1
      register: drill_archive
      changed_when: false
      failed_when: false

    - name: "Assert : une archive existe sur cet hôte"
      ansible.builtin.assert:
        that:
          - drill_archive.stdout | length > 0
        fail_msg: >-
          Aucune archive {{ drill_claim_prefix }}-*.tar.gz dans
          {{ drill_offsite_dir }} : rien à restaurer, la porte F2 n'est pas
          franchie sur cet hôte.

    - name: "Créer le répertoire de travail root-only"
      ansible.builtin.command:
        cmd: mktemp -d /root/f2-drill.XXXXXX
      register: drill_tmp
      changed_when: true

    - name: "Restaurer, localiser la base, prouver l'utilisateur"
      block:
        - name: "Extraire l'archive"
          ansible.builtin.command:
            cmd: tar xzf {{ drill_archive.stdout }} -C {{ drill_tmp.stdout }}
          changed_when: true

        - name: "Localiser gitea.db dans l'arborescence restaurée"
          ansible.builtin.shell:
            cmd: find {{ drill_tmp.stdout }} -name gitea.db | head -1
          register: drill_db
          changed_when: false

        - name: "Assert : la base est dans l'archive"
          ansible.builtin.assert:
            that:
              - drill_db.stdout | length > 0
            fail_msg: >-
              gitea.db absent de l'archive restaurée — elle ne restaure pas ce
              qu'elle promet.

        - name: "Compter l'utilisateur ci dans la base restaurée"
          ansible.builtin.command:
            cmd: sqlite3 {{ drill_db.stdout }} "select count(*) from user where name='ci'"
          register: drill_user
          changed_when: false

        - name: "Assert : l'utilisateur ci est retrouvé (contre-épreuve F2)"
          ansible.builtin.assert:
            that:
              - drill_user.stdout | trim == '1'
            fail_msg: >-
              Utilisateur ci introuvable dans le gitea.db restauré (comptage =
              « {{ drill_user.stdout | trim }} ») : la sauvegarde ne protège
              pas ce qu'elle prétend.
            success_msg: >-
              Contre-épreuve F2 verte : utilisateur ci présent dans la base
              restaurée sur {{ inventory_hostname }}.
      always:
        - name: "Détruire le répertoire de travail, succès ou échec"
          ansible.builtin.file:
            path: "{{ drill_tmp.stdout }}"
            state: absent
```

- [ ] **Step 2 : vérifier la syntaxe**

Run : `cd ansible && ansible-playbook -i inventory.contabo.ini backup-restore-drill.yml --syntax-check`
Attendu : `playbook: backup-restore-drill.yml`

- [ ] **Step 3 : commit**

```bash
git add ansible/backup-restore-drill.yml
git commit -m "feat(backup): F2 — contre-épreuve de restauration depuis l'hôte de sauvegarde"
```

---

### Task 4 : sabotage D6 — le rôle refuse une cible co-localisée

- [ ] **Step 1 : run avec la cible volontairement fausse**

Run : `cd ansible && ansible-playbook -i inventory.contabo.ini backup.yml -e backup_offsite_host=worker-5`
Attendu : la partie plan de contrôle passe (worker-5 reste hors-nœud pour worker-1), puis la partie PVC **échoue fermée** sur « sauvegarde REFUSÉE (porte F2) » **avant toute quiescence** — aucun pod ne bouge, aucune archive `pvc-*-<stamp>` produite.

- [ ] **Step 2 : vérifier l'innocuité du sabotage**

Run : `ssh worker-1 'sudo k3s kubectl -n ci get pods'`
Attendu : gitea-0, jenkins-*, vault-0 tous Running, âges inchangés (pas de redémarrage).

---

### Task 5 : run réel — porte F2

- [ ] **Step 1 : run nominal**

Run : `cd ansible && ansible-playbook -i inventory.contabo.ini backup.yml`
Attendu : `failed=0` sur tous les hôtes ; les asserts « empreinte vérifiée », « Vault descellé, socle intact » verts.

- [ ] **Step 2 : porte F2 — les trois archives sur worker-2**

Run : `ssh worker-2 'sudo ls -la /var/lib/k3s-backups/offsite/ | grep pvc-ci'`
Attendu : trois archives `pvc-ci-{gitea-data-gitea-0,jenkins-home,vault-data-vault-0}-<stamp>.tar.gz` non vides, mode 0600, aucun `.suspect`.

- [ ] **Step 3 : le socle est revenu entier**

Run : `ssh worker-1 'sudo k3s kubectl -n ci get pods; sudo k3s kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,AUTO:.spec.syncPolicy.automated'`
Attendu : pods ci Running ; `ci-gitea`, `ci-jenkins`, `ci-vault` ont retrouvé `map[allowEmpty:false prune:true selfHeal:true]`.

- [ ] **Step 4 : second run (récurrence + rotation)**

Run : `cd ansible && ansible-playbook -i inventory.contabo.ini backup.yml` puis `ssh worker-2 'sudo ls -1 /var/lib/k3s-backups/offsite/pvc-ci-* | sort'`
Attendu : `failed=0` de nouveau ; deux horodatages par claim (≤ `backup_keep`), preuve que la rotation par claim n'a rien supprimé à tort.

---

### Task 6 : contre-épreuve — restauration depuis worker-2

- [ ] **Step 1 : run du drill**

Run : `cd ansible && ansible-playbook -i inventory.contabo.ini backup-restore-drill.yml`
Attendu : « Contre-épreuve F2 verte : utilisateur ci présent dans la base restaurée sur worker-2 », répertoire de travail détruit.

---

### Task 7 : preuves et documentation

**Files:**
- Modify: `docs/superpowers/plans/2026-07-29-f2-sauvegarde-hors-noeud.md` (section « Preuve d'exécution »)
- Modify: `poc-control-plane-federation/GOAL-socle-vers-gateway-2026-07-28.md` (état F2, table de dette)
- Create: `poc-control-plane-federation/HANDOFF-F2-SAUVEGARDE-HORS-NOEUD.md`
- Modify: mémoire agent (`socle-ci-lot1-deploye.md` + `MEMORY.md`)

- [ ] **Step 1 : appendre la « Preuve d'exécution »** au présent plan (horodatages, sorties clés des Tasks 4-6, limites résiduelles).
- [ ] **Step 2 : GOAL** — passer F2 à « FERMÉ le 2026-07-29 » avec le résumé porte + contre-épreuve, solder la ligne de dette « Sauvegardes co-localisées », noter la déviation D3 (Vault à chaud tant que le point parts n'est pas levé).
- [ ] **Step 3 : handoff F2** sur le modèle du handoff F1 (flux, preuves, ce qui vit où, dette restante — dont le point Vault toujours ouvert et la ligne `.suspect`).
- [ ] **Step 4 : mémoire** — mettre à jour le fichier mémoire lot 1 (F2 soldé, offsite = worker-2, Vault non quiescé).
- [ ] **Step 5 : commit final**

```bash
git add docs/superpowers/plans/2026-07-29-f2-sauvegarde-hors-noeud.md poc-control-plane-federation/
git commit -m "docs(f2): preuve F2 — archives des 3 PVC sur worker-2, restauration exercée, handoff"
```

---

## Preuve d'exécution (2026-07-29, mesures contre le cluster vivant)

**Sabotage D6** (`-e backup_offsite_host=worker-5`) : échec fermé sur les trois
PVC — « … vit sur worker-5, qui est aussi l'hôte de sauvegarde … sauvegarde
REFUSÉE (porte F2) » — **avant toute quiescence** ; pods `ci` intacts après
coup (âges 21 h / 18 h / 85 min, zéro redémarrage).

**Run réel n°1** (stamp `20260729T121715`) : `failed=0` (49 ok, 2 skipped).
Fenêtre de sync ouverte puis refermée sur `ci-gitea`, `ci-jenkins`,
`ci-vault` ; quiescence de `Deployment/jenkins` et `StatefulSet/gitea`
seulement ; empreintes Vault avant/après identiques (« aucune écriture pendant
l'archivage à chaud ») ; aucun pod réapparu pendant l'archivage (la fenêtre de
sync fait son travail — au lot 1, selfHeal revertait en ~5 s).

**Porte F2 franchie** — sur worker-2, `/var/lib/k3s-backups/offsite/` :

```
pvc-ci-gitea-data-gitea-0-20260729T121715.tar.gz   (496 Mo)
pvc-ci-jenkins-home-20260729T121715.tar.gz         (273 Mo)
pvc-ci-vault-data-vault-0-20260729T121715.tar.gz   (19 Ko)
```

lisibles (read-back + comptage d'entrées), empreintes sha256 égales au staging,
mode 0600, aucun `.suspect`. worker-2 ≠ worker-5 prouvé par l'assert D6 du
même run.

**Récurrence + rotation** — run n°2 (stamp `20260729T122215`) : `failed=0` de
nouveau ; deux horodatages par claim des deux côtés (staging worker-5 et
offsite worker-2), ≤ `backup_keep`, rien supprimé à tort.

**Contre-épreuve F2 verte** — `backup-restore-drill.yml` sur worker-2 :
archive extraite dans un répertoire root-only, `gitea.db` localisé,
`select count(*) from user where name='ci'` = 1 → « utilisateur ci présent
dans la base restaurée sur worker-2 », répertoire détruit ensuite.

**Le socle n'a pas été dégradé** : après les deux runs, gitea et jenkins
Running (redémarrés proprement par `always`), `vault-0` **jamais redémarré**
(âge 96 min, antérieur au premier run), `Sealed=false` avant et après chaque
run (asserts du rôle), politiques `automated {prune, selfHeal}` restaurées à
l'identique sur les trois Applications.

**Limites résiduelles, assumées :**
- La rotation n'a pas encore été observée en train de supprimer (il faudrait
  8 runs) ; le chemin de code s'exécute à chaque run et le comptage reste ≤ 7.
- Les chemins de quarantaine (`.suspect`) n'ont pas été déclenchés en réel :
  les provoquer exigerait d'écrire dans un PVC pendant la fenêtre. Ils sont
  couverts par relecture de code seulement.
- Le point Vault du handoff F1 (détention des parts) reste **ouvert** — F2 a
  été conçu pour ne pas en dépendre (Vault jamais redémarré), mais `backup.yml`
  ne restitue la quiescence pleine de Vault qu'une fois ce point levé
  (`backup_hot_workloads` à vider alors).
- L'ancien répertoire offsite de worker-5 garde les archives k3s d'avant F2
  (historique) ; les nouvelles vont sur worker-2.
