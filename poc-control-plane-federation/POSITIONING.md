# Positionnement — Scaffold PoC jetable vs valeur produit STOA

> **Condition C1 du Council.** À lire avant toute démo. Objectif : empêcher l'auto-balle GTM. Le PoC prouve la faisabilité ; il NE doit PAS laisser croire qu'un control plane de fédération souverain = « 300 lignes de glue OSS » qu'une banque recopie sans nous payer.
>
> Anonymisation : « banque centrale (Eurosystème) » / « BC ».

---

## La phrase qui désamorce tout

> **« Le PoC montre que *brancher* deux gateways est facile un jour donné ; STOA garantit que ça le *reste* — à chaque montée de version, chaque nouvelle gateway, chaque exigence de conformité — sans que vos équipes possèdent et maintiennent N intégrations fragiles contre des admin APIs qui bougent. »**

Réponse en une phrase à *« pourquoi acheter STOA plutôt que recopier ce PoC ? »* :

> **« Recopier le PoC, c'est signer pour le maintenir : STOA vend précisément ce que le PoC ne montre pas — la maintenance des Links, la gouvernance et la conformité, le support et le SLA. »**

---

## Ce que le PoC EST / N'EST PAS

| | Scaffold PoC (`labctl`, ce repo) | Produit STOA |
|---|---|---|
| Nature | Démonstrateur **jetable**, environnement éphémère | Plateforme supportée, versionnée, SLA |
| `labctl` (boucle de *dispatch* ~180 LOC ; l'outil complet + 3 adapters ≈ 3 700 LOC) | Prouve que le *dispatch* « 1 contrat → N gw » est trivial — **mais le volume réel est dans les adapters / auth / HTTP**, soit précisément la « maintenance » que STOA vend | N'est PAS le produit — le produit est tout **autour** du dispatch |
| Adapters | 3 adapters figés contre des admin APIs à un instant T | **STOA Links maintenus** : suivent les montées de version WSO2/APISIX/webMethods, testés en CI, garantis |
| Contrats | OpenAPI publié, point | **Validation + détection de drift** : le contrat reste la source de vérité, alertes si une gw dérive |
| Identité | Token KC consommé par 3 gw | **Fédération credentials/policies multi-runtime** : un changement de policy propagé partout, cohérent |
| Sécurité | Démo, secrets en placeholder | **RBAC, audit trail, délégation des secrets à un PAM/Vault qualifié, management zéro-entrant** (STOA hors du chemin transactionnel — cf. [`../adr/adr-068-stoa-off-the-transaction-path.md`](../adr/adr-068-stoa-off-the-transaction-path.md)) |
| Agents/IA | Hors PoC | **Couche MCP/agent** : exposition gouvernée aux agents (`safe_for_agents`, `requires_human_approval`) |
| Run | `docker compose up` sur un poste | Déploiement HA, observabilité prod, on-call |
| Coût réel pour la BC si « build-it-yourself » | 0 € le jour 1 | Le vrai coût est en **RUN sur 5 ans** : maintien des intégrations, sécurité, conformité, montées de version |

---

## Le piège §7.6 retourné à notre avantage

L'étude (§7.6) déconseille le **« moteur de fédération custom maison »** et flague AMARIS pour « architecture pilotée par l'opportunité plutôt que par le besoin ». 

- **Risque si on présente mal le PoC** : le comité conclut « c'est 300 lignes, on le fait nous-mêmes » → ils construisent exactement le custom maison que §7.6 condamne, et qu'ils devront maintenir.
- **Cadrage correct** : le PoC est la *preuve* que STOA fédère ; le **produit** est le buy-not-build qui les sort du custom maison. STOA n'est pas « leur 300 LOC packagées » — c'est la garantie de maintenance, gouvernance et support qui transforme un script fragile en socle d'entreprise.

> Le PoC prouve la faisabilité. Le **business case** se gagne sur le chiffrage **BUILD/RUN 5 ans** (template BdF, hors scope PoC) : c'est là que « recopier le PoC » révèle son coût caché et que le RUN STOA gagne.

---

## Règles de présentation (à tenir en démo)

1. Dire « **scaffold de démonstration** », jamais « le produit », en parlant de `labctl`.
2. Quand le « ~300 LOC » est mentionné : enchaîner immédiatement sur « *et voilà pourquoi le dur n'est pas là* » → maintenance/gouvernance/support.
3. Pièce maîtresse = corrélation **`trace_id` 3 gateways → Tempo** (tangible), pas le nombre de lignes.
4. Toujours fermer sur la phrase « pourquoi acheter STOA » ci-dessus.
