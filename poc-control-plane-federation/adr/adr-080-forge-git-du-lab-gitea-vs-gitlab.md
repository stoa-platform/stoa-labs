---
title: "ADR-080 — Forge Git du lab : Gitea retenu, GitLab écarté — le forge est une commodité à 4 interfaces, le moteur CI (Jenkins) est la pièce qui transfère chez le client"
sidebar_label: "ADR-080 : forge Git du lab (Gitea vs GitLab)"
status: "Acté — décision de lab, ne requiert pas le Council (aucun engagement client, aucun impact produit)"
maturite_technique: "✅ Livré & prouvé — Gitea 1.22 déployé en ns `ci`, porte F1 verte (push → build sans action humaine, statut vert/rouge sur le commit) le 2026-07-29. La table de correspondance Gitea↔GitLab de la §5 est `[INFÉR]` — conçue sur documentation, jamais exécutée."
date: 2026-07-29
adr_number: 80
note: "S'appuie sur ADR-076 (repo-par-projet), ADR-074 (secrets Vault). Une version assainie (principe seul : « le forge est une commodité, le moteur CI est le livrable ») serait portable dans stoa-docs ; celle-ci ne l'est pas."
---

# ADR-080 — Forge Git du lab : Gitea retenu, GitLab écarté

**Statut :** Acté (2026-07-29). Décision de lab : elle n'engage rien chez le client et ne touche pas le produit.
**Maturité technique :** ✅ Gitea 1.22 déployé (ns `ci`, StatefulSet + PVC `local-path`), registre d'images intégré activé, webhook interne restreint par `GITEA__webhook__ALLOWED_HOST_LIST`. Porte F1 verte et contre-épreuve rouge (builds 7/8/9, SHA S2/S3/S4) — commit `2ed00b1`.
**Contexte technique :** **GitLab** est le forge d'entreprise ; **Jenkins** exécute les pipelines. Le lab tourne sur Gitea.
**Lié à :** [[adr-076-gitops-api-lifecycle-repo-per-project]], [[adr-074-vault-secrets]], [[adr-072-control-plane-mediation]].

---

## Décision (test « archi 40 ans / 30 secondes »)

> Le lab garde **Gitea**. Le forge n'est pas ce que le POC démontre : il expose **quatre interfaces** — clone git, émission de webhook, API de statut de commit, registre d'images — que GitLab implémente aussi. Ce qui doit transférer chez le client, c'est la chaîne **Jenkins → Vault par identité de pod, sans secret statique** ; elle est indifférente au forge, et le client exécute déjà ses pipelines avec Jenkins. Héberger GitLab CE dans ce cluster dépenserait la ressource la plus rare (`fsync`) pour ne rien prouver de plus.
> **Test** : *si on remplaçait le forge demain, quelle affirmation du POC tomberait ?* Si la réponse est « aucune », alors le forge est une commodité et son choix se règle au coût d'exploitation, pas à la ressemblance avec le client.

---

## Contexte et problème

Le lot 1 du socle CI est debout et la porte F1 est soldée : un `git push` déclenche un build sans action humaine, le pipeline s'authentifie auprès de Vault **par l'identité de son pod** (SA `jenkins-agent`, méthode k8s), lit son secret, et repose un statut vert — ou rouge sur Jenkinsfile cassé — sur le commit.

La question posée après coup : **le client est sur GitLab, pas sur Gitea — s'est-on trompé de forge ?** Elle est légitime : un POC qu'on montre à une équipe plateforme se juge aussi sur sa proximité avec l'outillage réel de cette équipe.

Elle se scinde en deux, et la deuxième est la seule qui compte :

1. Le forge du lab ressemble-t-il à celui du client ? **Non.**
2. Le **moteur de pipeline** du lab ressemble-t-il à celui du client ? **Oui — Jenkins des deux côtés** (confirmé 2026-07-29).

Le décalage porte donc sur la pièce commodité, pas sur la pièce livrable. Si le client avait été sur GitLab CI, le verdict de cet ADR serait inversé — et le composant à changer aurait été **Jenkins**, pas Gitea.

## Contrainte d'entrée : la ressource rare est le `fsync`, pas la RAM

`RAPPORT-cluster-k3s-contabo-2026-07-27.md:638-642`, textuellement :

> « le budget n'est pas de 70 Go de RAM, il est de **~300 IOPS synchrones** — et il n'a pas été mesuré sous charge »

avec un p99 `fsync` déjà à **10 ms à vide**, sur un plan de contrôle k3s + kine/SQLite et du stockage `local-path`. C'est ce raisonnement — pas un arbitrage de RAM — qui a fait **différer vcluster** (`RAPPORT:139`, `:238`) au motif que « sur une flotte limitée par `fsync`, l'isolation se paie exactement dans la ressource la plus rare ».

Or les deux forges ne se comparent pas sur cet axe :

| | Gitea 1.22 | GitLab CE self-managed |
|---|---|---|
| Processus | 1 binaire Go + SQLite | Puma + Sidekiq + Gitaly + **PostgreSQL** + Redis (+ registry, + Prometheus) |
| Empreinte | ~centaines de Mo | **≥ 4 vCPU / 4 Go** (plancher éditeur), 8 Go en pratique `[INFÉR : docs GitLab, non mesuré ici]` |
| Profil disque | faible | **journalisation synchrone permanente** (WAL Postgres + Redis AOF + Gitaly) |

Poser GitLab CE ici, ce serait ajouter le composant le plus `fsync`-intensif de toute la pile sur le disque qui est **déjà** la contrainte dure — après avoir écarté vcluster pour exactement ce motif. Incohérence assumée nulle part ailleurs dans le dossier ; on ne l'introduit pas ici.

> ⚠️ **Honnêteté sur les chiffres.** L'empreinte GitLab ci-dessus vient de la documentation éditeur, **pas d'une mesure sur ce cluster**. Le raisonnement ne dépend pas de sa précision : il tient dès lors que GitLab est d'un ordre de grandeur au-dessus de Gitea sur le `fsync`, ce qui n'est pas contesté.

## Options considérées

1. **Statu quo — Gitea.** Coût nul, F1 déjà prouvé. Décalage cosmétique avec le client. **★ Retenu.**
2. **Migrer vers GitLab CE self-managed dans le cluster.** Ressemblance maximale ; paie la ressource la plus rare, et jette la preuve F1 pour la rejouer à l'identique. **Rejeté** (cf. §contrainte).
3. **Adosser un projet GitLab.com (SaaS) en miroir.** Zéro empreinte cluster, preuve contre un vrai GitLab. Mais un webhook GitLab.com doit **entrer** dans le cluster, ce qui heurte frontalement `2026-07-28-socle-ci-cluster-design.md:99-110` (« ni Gitea, ni Jenkins, ni Vault ne reçoivent d'Ingress » — décision motivée par le défaut n8n dénoncé au rapport). **Rejeté day-1**, gardé comme option si le client exige une preuve sur son forge : elle exigerait alors une **exception explicite** au §4.1, pas un contournement silencieux.
4. **Abstraire le forge derrière une couche interne.** Rejeté : sur-ingénierie pour un basculement qui restera de l'ordre de la journée (§5) et qui n'arrivera peut-être jamais. On documente le point de substitution ; on ne construit pas l'indirection avant d'en avoir besoin.

## 5. Surface de couplage — nommée, mesurée, et sa traduction GitLab

C'est la contrepartie de la décision : **si on ne construit pas l'abstraction, on doit savoir exactement où elle irait.** Mesure au 2026-07-29 : **55 occurrences de `gitea` dans 9 fichiers** (`ci/Jenkinsfile{,.prod,.rollback}`, `scripts/provision-{request,plan}.sh`, `scripts/setup-*-job.sh`, `scripts/demo-multienv.sh`, `docker-compose.ci.yml`).

| # | Interface | Ce que le lab appelle | Équivalent GitLab `[INFÉR]` | Coût |
|---|---|---|---|---|
| 1 | **Clone** | `http://gitea.ci.svc:3000/…` | URL de projet | **Nul** — protocole standard |
| 2 | **Déclenchement** | webhook push → `POST /generic-webhook-trigger/invoke?token=…` (GWT 2.4.2) | GitLab émet aussi un POST JSON ; **GWT est générique par construction** | **Faible** — re-mapper les JSONPath : `$.after` → `$.checkout_sha`, `$.repository.clone_url` → `$.project.git_http_url`. Le réglage `ALLOWED_HOST_LIST` (spécifique Gitea) devient une allowlist webhook côté admin GitLab. |
| 3 | **Statut de commit** | `POST /api/v1/repos/{owner}/{repo}/statuses/{sha}` | `POST /api/v4/projects/{id}/statuses/{sha}` | **Moyen** — sémantique identique, chemin et vocabulaire d'états différents ; projet désigné par **ID ou chemin url-encodé**, pas par `{owner}/{repo}` |
| 4 | **PR / commentaires** (`provision-request.sh:176-192`, `provision-plan.sh:98-104`) | `/repos/{repo}/pulls`, `/issues/{n}/comments` | `/projects/{id}/merge_requests`, `/merge_requests/{iid}/notes` | **Moyen** — même racine : Gitea copie délibérément l'API GitHub, GitLab a son propre modèle |
| 5 | **Registre d'images** | registre intégré Gitea (un composant en moins) | Container Registry = composant **séparé** | **À ne pas traduire** — chez le client c'est un registre d'entreprise (Harbor / Artifactory / Nexus), pas celui du forge |

**Estimation du basculement : de l'ordre de la journée**, localisé, sans effet sur le schéma de gouvernance ni sur la chaîne Vault. `[INFÉR]` — conçu sur documentation, **jamais exécuté**. Ce n'est pas une dette qui grossit : les points 3 et 4 sont les seuls à croître, et seulement si les scripts de provisioning s'étoffent.

## Conséquences

**Positives.** Aucun travail engagé, F1 reste prouvé et opposable. Le budget `fsync` reste disponible pour ce qui en a besoin (lot 2, gateway, labs). La surface de couplage est désormais **nommée** : en démo, l'objection « vous n'êtes pas sur notre forge » se répond par le tableau §5 — ce qui déplace la conversation de « votre POC ne nous ressemble pas » vers « voici exactement ce qui change, et ce n'est pas ce que le POC démontre ».

**Limites / risques assumés.**
- **Risque de crédibilité, pas technique.** Il se traite en démo, pas en migration — mais il faut *effectivement* le traiter : un tableau §5 non montré ne protège de rien.
- La correspondance §5 est **non testée**. Si le client demande la preuve sur GitLab, ne pas annoncer « c'est une journée » comme un fait mesuré.
- Le **registre intégré** est le seul endroit où Gitea a fait économiser un composant : c'est aussi le seul point où la ressemblance client est franchement fausse (le client a un registre d'entreprise). À dire, pas à masquer.
- La version et la topologie GitLab du client (SaaS / self-managed, `/api/v4` disponible, politique de webhook sortant) **ne sont pas documentées**. Toute promesse de basculement les suppose.
- Si le client **migre vers GitLab CI**, cet ADR est caduc et le composant à revoir est Jenkins — pas Gitea.

## Alternatives écartées

- **GitLab CE dans le cluster** — rejeté : dépense la ressource explicitement identifiée comme rare, pour prouver ce que le forge ne prouve pas, en détruisant la preuve F1 existante.
- **GitLab.com en miroir day-1** — rejeté : exige un flux entrant, contre une décision de sécurité motivée (§4.1 du design lot 1). Réactivable **sous exception explicite** si le client l'exige.
- **Couche d'abstraction forge** — rejeté : indirection construite avant le besoin, pour un basculement à l'ordre de la journée.
- **Migrer le GitOps plateforme (Argo CD) vers le forge du lab** — hors sujet ici, et déjà exclu au lot 1 (`2026-07-28-socle-ci-cluster-design.md:50-52`) : Argo CD lit GitHub, Gitea n'héberge que les dépôts *projet*. Deux rôles disjoints, aucun problème d'amorçage.

## Definition of Done de cet ADR

- [x] Décision actée et motivée par la contrainte mesurée (`fsync`), pas par une préférence.
- [x] Surface de couplage mesurée (55 occurrences / 9 fichiers) et traduite interface par interface.
- [ ] Le tableau §5 est **effectivement présenté** en démo au moment où le forge est visible à l'écran.
- [ ] Confirmer la topologie GitLab du client (SaaS vs self-managed, `/api/v4`, politique webhook) avant toute promesse de basculement.
- [ ] Revoir cet ADR si le client annonce une migration Jenkins → GitLab CI : le verdict s'inverse et la pièce à changer devient le moteur CI.

## Références

- `docs/superpowers/specs/2026-07-28-socle-ci-cluster-design.md` — §4.1 (aucune exposition publique), §5.1 (Gitea), §2 (Gitea ≠ GitOps plateforme).
- `docs/superpowers/plans/2026-07-28-f1-webhook-statut.md` — preuve F1, endpoints `statuses/{sha}` et `commits/{sha}/status`.
- `RAPPORT-cluster-k3s-contabo-2026-07-27.md:638-642` (budget en IOPS synchrones), `:139` / `:238` (vcluster différé pour le même motif).
- [[adr-076-gitops-api-lifecycle-repo-per-project]] (repo-par-projet), [[adr-074-vault-secrets]] (secrets hors-Git).
