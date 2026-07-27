# ansible/ — rôles au niveau FLOTTE (hôtes Contabo)

Distinct de [`poc-control-plane-federation/ansible/`](../poc-control-plane-federation/ansible/),
qui est scopé **APIM / webMethods** (couche IS-admin, ADR-075/076). Ici : ce qui
concerne les **machines** elles-mêmes.

| Rôle | Objet |
|------|-------|
| `fleet_disk_bench` | Latence d'écriture synchrone (`fsync`) — le chiffre qui décide de la topologie du control-plane |

## Pourquoi ce rôle existe

Un bench lancé à la main installe un paquet hors gestion de configuration : c'est
exactement la dérive out-of-band qui a produit, sur le cluster k3s, un namespace
orphelin en CrashLoopBackOff pendant 119 jours et un `ghcr-creds` expiré jamais
recréé. Le rôle **déclare** l'état (fio présent, test exécuté, résultat archivé),
donc le relancer converge au lieu de dériver.

## Lancer

```bash
cd ansible
ansible-playbook -i inventory.contabo.ini disk-bench.yml            # nœuds au repos
ansible-playbook -i inventory.contabo.ini disk-bench.yml -e target=worker-5
```

Le JSON fio brut est rapatrié dans `artifacts/<hôte>-fio-wal.json` (preuve
rejouable, ignoré par Git).

## Ce que le rôle refuse de faire

Fail-closed sur trois points, par conception :

1. **Hôte chargé** — refus au-dessus de `disk_bench_max_loadavg` (1.0). Un bench
   sur hôte chargé mesure la contention, pas le disque, et perturbe la charge en
   place. `worker-3` et `worker-5` portent des services vivants.
2. **Espace insuffisant** — refus sous `disk_bench_min_free_mb` (2 Go).
3. **Métrique absente** — si `fio` ne produit pas de latence `fsync` exploitable,
   le play échoue. Une latence manquante ne doit jamais être lue comme un disque
   rapide.

Contournement explicite : `-e disk_bench_force=true`. Jamais par défaut.

## Porte de preuve

Le rôle échoue si le **p99 `fsync` dépasse 10 ms**
(`etcd_disk_wal_fsync_duration_seconds`, recommandation etcd). C'est la porte qui
tranche la topologie :

- **p99 ≤ 10 ms** → un control-plane HA à 3 nœuds avec etcd embarqué est jouable.
- **p99 > 10 ms** → contre-indiqué : le consensus Raft synchronise chaque écriture
  sur chaque membre, et l'amplification produit des élections de leader sous
  charge. Rester mono-CP **SQLite/kine** (défaut k3s, sans consensus donc sans
  amplification), ou passer par un datastore externe.

**Mesure préalable en `dd` (2026-07-27), moyennes seulement :** 2,67 ms/op sur
`worker-1` au repos, 6,53 ms/op sur `worker-5` (control-plane). Une moyenne à
6,5 ms rend un p99 sous 10 ms peu probable — d'où ce rôle, `dd` ne donnant pas de
percentile.

## Contre-épreuve

La porte doit **échouer** quand le disque est inapte. Pour la vérifier sans
attendre un disque lent, abaisser le seuil sous la valeur mesurée :

```bash
ansible-playbook -i inventory.contabo.ini disk-bench.yml \
  -e disk_bench_wal_p99_max_ms=0.001
# attendu : "SEUIL DÉPASSÉ ... p99 X ms > 0.001 ms" → play en échec
```

Un play qui reste vert dans ces conditions signale une porte inopérante.

## Variables

Voir [`roles/fleet_disk_bench/defaults/main.yml`](./roles/fleet_disk_bench/defaults/main.yml)
— chaque variable y est commentée avec la raison de son défaut.
