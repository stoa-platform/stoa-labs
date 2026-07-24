# HANDOFF — Chaîne de provisioning self-service (OIG/CLI2 → app)

_Session 2026-07-24. Poussé sur origin (GitHub) + gitea. Branche `main`, tête `41adc8a`._

## En une phrase

Un appel authentifié d'OIG ou CLI2 sur une **API `provisioning`** de la gateway
webMethods déclenche, de bout en bout et sans nouveau composant hébergé :
**manifeste + Merge Request → plan automatique commenté sur la PR → (validation
humaine) → demande en attente Jenkins → apply nominatif**. Tout est en scripts +
Ansible + jobs Jenkins ; **labctl est un raccourci de lab, PAS le livrable client**.

## Le flux complet (tout prouvé E2E, sauf mention)

```
OIG/CLI2 (application gateway, Bearer aud=provisioning + scope=provision)
  │ POST /gateway/provisioning/1.0/applications {app,env,clientId,api,caller}
  ▼
[wM Gateway]  IAM strict/oAuth2Token + BARRIÈRE SCOPE   → anonyme/tiers = 401
  │ routing → jenkins GWT invoke?token=stoa-provision-request
  ▼
[Jenkins provisioning-request]  provision-request.sh
  │ rend le manifeste apim_ss_app (mode=f(caller) : OIG→idp, CLI2→internal)
  │ branche provision/<app>-<env> · commit (service ci) · push · PR (API Gitea)
  ▼
[Gitea]  PR ouverte ── webhook pull_request ──▶
  ▼
[Jenkins provision-plan]  provision-plan.sh
  │ checkout branche · PLAN lecture seule (name/api + ansible --syntax-check)
  │ commentaire ✅/❌ IDEMPOTENT sur la PR (lien manifeste = GIT_WEB_HOST)
  ▼
  ===>  TU valides + merges la PR dans Gitea  <===
  ▼
[Jenkins provision-apply]  webhook (closed∧merged)
  │ build PAUSED_PENDING_INPUT « apply <app>/<env> » = LA DEMANDE EN ATTENTE
  │ → demande TON identité Vault → apply nominatif délégué à selfservice-app-deploy
  ▼
[apply]  converge + verify (proxy-oauth2) — PROUVÉ SUCCESS (#22, identité alice)
```

## Ce qui est prouvé

- **Barrière d'accès** (4 voix, `setup-provisioning-api.sh` 10/10) : anonyme 401,
  OIG/CLI2 (scope provision) 200, tiers (token valide d'une autre API, sans le
  scope) 401. **La barrière = le SCOPE** (l'audience est fail-open sur le trial :
  introspection inerte, cf. `targets.yaml`). Posée par `apim_publish_api` (scope
  mapping `/scopes`), PAS par labctl — pas de gap Ansible.
- **Identité runtime wM 10.15 = la STRATÉGIE** (azp==clientId), l'identifier de
  claim est décoratif, un nom de claim custom n'est jamais évalué (spike
  `spike-claim-runtime.sh` 11/11). Rotation 0-coupure = 2 stratégies
  (`ansible/strategy-rotation.yml`). Retrait ≠ révocation (cache runtime).
- **Maillon 1 + boucle + apply** : PR créée (idp ET internal), plan auto commenté,
  merge → demande en attente → apply nominatif SUCCESS.
- **Ségrégation à l'apply** : oscar (`operator-deploy`, plateforme) → 403 sur le KV
  tenant ; alice (`deploy-banking-demo`) → 200. L'apply exige l'identité du BON
  tenant — douve dans la **policy Vault**, pas le pipeline.

## Fichiers livrés (versionnés)

| Fichier | Rôle |
|---|---|
| `apis/provisioning.openapi.yaml` | contrat de l'API provisioning |
| `gateways/webmethods/provisioning/targets.provisioning.yaml` | manifeste labctl (LAB) |
| `scripts/setup-provisioning-api.sh` | pose l'API + barrière + preuve 4 voix (LAB, labctl) |
| `scripts/provision-request.sh` | demande → manifeste (idp/internal) + push + PR |
| `scripts/provision-plan.sh` | PR → plan lecture seule → commentaire idempotent |
| `scripts/setup-provision-request-job.sh` | token Gitea + credential Jenkins + job |
| `ci/jenkins/provisioning-request.job.xml` | job GWT (gateway → demande) |
| `ci/jenkins/provision-plan.job.xml` | job webhook Gitea (PR → plan) |
| `ci/jenkins/provision-apply.job.xml` | job webhook Gitea (merge → demande en attente → apply) |
| `gateways/webmethods/provisioning/provisioning.publish.yml` | publish PUR ANSIBLE (barrière scope) |

## Frontière lab vs client (IMPORTANT)

- **labctl = LAB uniquement** (le client n'installe pas le binaire Go). L'équivalent
  client est **100 % Ansible** : `apim_publish_api` (API + barrière scope) +
  `apim_selfservice_app` (consommateur). Prouvé pur-Ansible (scope mapping recréé,
  4 voix vertes).
- **IdP** : l'octroi du scope `provision` aux SEULS appelants (OIG/CLI2) est côté
  IdP (OAM pour OIG, AS local wM pour CLI2), pas dans la gateway.

## Pièges rencontrés (ne pas re-découvrir)

- **wM trial recycle ~25 min** → `Connection reset` / 404 en plein run ; les proxies
  `wm-admin-*` se DÉSACTIVENT (activate 500 après corruption). `ADMIN_VIA=direct`
  (Basic) contourne pour l'apply. Chez le client (pas de trial), inexistant.
- **Conteneur Jenkins : python3 + ansible, PAS jq** → tout le JSON/HTTP en python3.
- **GWT injecte en variables d'ENV, pas binding Groovy** → `env.PR_BRANCH`.
- **Gitea émet opened+synchronized à la création** → `disableConcurrentBuilds` +
  commentaire idempotent (marqueur `<!-- provision-plan -->` → PATCH).
- **Split-horizon Gitea** : jenkins→`gitea:3000`, navigateur→`localhost:13000`
  (knob `GIT_WEB_HOST` pour les liens ; chez le client, une seule URL entreprise).
- **Les jobs checkoutent gitea `ci/stoa-labs` main** → `git push gitea main` AVANT
  de tester, sinon on rejoue l'ancien code.
- **Token Gitea** : `docker exec -u git poc-gitea gitea admin user generate-access-token`.
- **Input submit API** : `POST /job/X/N/wfapi/inputSubmit?inputId=<Id>` `json={"parameter":[...]}`.

## État du lab au handoff

- PR #15 (`provision/paiements-sepa-dev`) OUVERTE — demande de démo à valider/merger
  par l'humain (commentaire de plan ✅ avec lien manifeste cliblable).
- Apps gateway persistantes : `oig-provisioner`, `cli2-provisioner` (souscrites,
  scope provision). Assets de test purgés.
- Jobs Jenkins : `provisioning-request`, `provision-plan`, `provision-apply`
  (+ `provisioning-webhook` job de preuve), `selfservice-app-deploy` (apply).
- Webhooks Gitea sur `ci/stoa-labs` : #4 (PR→plan), #5 (merge→apply).

## Suites possibles (non faites)

- Re-setup propre des proxies `wm-admin-*` (`setup-wm-admin-self-proxy.sh`) pour
  l'apply via proxy-oauth2 (aujourd'hui contourné en direct).
- Décision de gouvernance : identité qui porte l'apply en int/prod (nominatif au
  gate = recommandé, prouvé ; ou compte de service = moins tracé).
- Promotion multi-env (dev→rec→int→prod) branchée sur la même entrée : existant
  ADR-075/076/079, à raccorder.

## Mémoires liées

`oracle-idp-gateway-sync`, `livrable-self-service-adr078`, `client-rollout-modular`,
`wm-1015-rest-shapes`, `wm-zero-downtime-deploy-constraint`.
