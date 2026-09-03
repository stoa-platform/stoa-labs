---
title: "ADR-090 — Ouvrir le terminus aux applications : déclarer, accorder, porter — et la demande sous identité de forge. Sous une déclaration de déployeur, l'équipe de cloisonnement vient de Git ; la demande porte les références de la porte et admet la chaîne entière ; une PR ouverte n'appartient qu'à son auteur."
sidebar_label: "ADR-090 : le terminus et l'identité de forge (A7)"
status: "Acté et prouvé le 2026-09-03 — hors ligne make lint-ci [16/16] (test-app-request-a7.sh 50/50 : stub forge à journal, shim git argv+env, 6 mutations ; test-selfservice-palier-a3.sh 191/191 dont la porte du GOAL hors ligne A.50 ; test-app-rollback-a6.sh 92/92 ; test-provision-apply-a4.sh 138/138 ; test-pr-comment.sh 47/47 ; test-a0-wiring.sh 183/183 ; test-palier-retention.sh 137/0 ; go test du mock) ; par builds réels scripts/test-a7-live.sh — chiffres dans le GOAL."
maturite_technique: "✅ Aucun mécanisme neuf en aval : la voie du terminus (par position), le ticket (operator-deploy lit envs/prod/wm-admin depuis G7) et la porte (apim-operator-prod) existaient — A7 les DÉCLARE, les ACCORDE, les MESURE. Neuf : la lib d'identité de forge (scripts/lib/forge-identity.sh), la décision d'équipe §2ter de la garde A3, le contrat figé relu au dispatch (porte A4 §2ter), les trois identités sur la PR, le poseur du terminus, le mock fidèle. Limites structurelles : token de forge personnel (pas de SSO de forge joué), attestation partielle de l'équipe (déclaré ≠ appliqué), mono-gateway hors terminus."
date: 2026-09-03
adr_number: 90
note: "Ferme le jalon A7 — et le GOAL cd-applications (2026-09-02) : A0..A7 livrés. Consomme ADR-082 (le palier est un credential), ADR-084 (deployerGroup — étendu : sous déclaration, l'équipe vient de Git), ADR-086 (G7 : le terminus des APIs, les trois identités), ADR-088 (A5 tient au terminus : API_NOT_PROMOTED/API_INACTIVE lus sur la gateway du terminus), ADR-089 (le repli au terminus par le même formulaire). Mesures fondatrices : Gitea 1.22.6 authentifie le PORTEUR du token (login d'URL ignoré), GET /user exige read:user, read:user+write:repository suffisent à pousser et ouvrir une PR ; Jenkins `build job:` VALIDE la valeur d'un `choice` (hypothèse A3 « barrière non garantie » réfutée) ; l'archive de la 10.15 s'importe dans le mock GUID et isActive conservés (sens réel→mock ; mock→réel reste la limite G7)."
lié: "[[adr-084-axe-qui-deploie-deployer-group]], [[adr-086-parcours-demandeur-pr-tableau-de-bord]], [[adr-088-ordre-app-api]], [[adr-089-repli-des-applications-par-pr]], [[adr-082-ouverture-palier-retention-credential]], [[adr-078-livrable-self-service-app-wm1015]]"
---

# ADR-090 — Ouvrir le terminus aux applications : déclarer, accorder, porter — et la demande sous identité de forge (A7)

**Statut :** Acté, prouvé hors ligne (`make lint-ci` [16/16]) et par builds réels sur le lab (`scripts/test-a7-live.sh` — chiffres, numéros de PR et de builds dans `GOAL-cd-applications-2026-09-02.md` §A7).

## Contexte

Le GOAL des applications (2026-09-02) posait le terminus comme le dernier trou : « ouvrir `prod` aux applications est un geste de credential, jamais un edit ». A3 avait rendu ce geste **possible par position** (`TERMINUS_SANS_VOIE` tant qu'aucune voie n'est déclarée, puis le ticket `envs/<terminus>/wm-admin`), A4 l'avait **gardé** (ITSM re-vérifié au dispatch, déclaration `apim-operator-prod`), G7 avait **accordé** le ticket à `operator-deploy`. Le relevé du 2026-09-03 a mesuré que le terminus n'était pas ce qui manquait pour parcourir les cinq paliers :

1. **la forge ne nommait aucun demandeur humain** — `provision-request.sh` poussait et ouvrait la PR sous le compte de service `ci` ; A4 refusait donc `REQUESTER_UNKNOWN` dès `int` (fourEyes), à raison ;
2. **la garde du palier ne savait pas sous quelle équipe un déployeur non-tenant applique** — A3 décide l'équipe sur le token (`deploy-<tenant>`) ; bob (`apim-apply-int`), carol (`apim-apply-homol`) et oscar (`apim-operator-prod`) ne portent aucun tenant : `TEAM_NON_PORTEE` / `TEAM_INDETERMINEE` sur toute application au-delà des paliers autonomes ;
3. **la demande ne transportait ni `change_ref` ni `pv_ref`** — `GATE_REFS_REQUIRED` dès `homol` ; le harnais A4 les avait fusionnés par la lib, hors du flux ;
4. **les deux formulaires excluaient le terminus par structure** (`env_chain_nonprod`), et **`build job:` valide la valeur d'un `choice`** (mesuré sur un job jetable : « Invalid parameter value ») — le dispatch de prod par `provision-apply` serait mort après la pause ;
5. **le lab** n'avait ni onboarding par palier (`providers.<env>.yml` pour `dev` seul), ni terminus équipé pour les applications (ticket Vault sur les creds de la 10.15, mock sans Teams, sans alias, `POST /assets/team` no-op pour les applications — mesuré par le rôle réel : `TEAM_UNCONFIRMED` après la porte A5 passée).

## Décision

### 1. Ouvrir le terminus = déclarer, accorder, porter — aucun `if`, aucune ligne dans la chaîne

- **Déclarer** : `APIM_TERMINUS_BASE` (globale Jenkins), lue telle quelle par les deux sites (`provision-apply-gate.sh` §6 avant la pause, `selfservice-palier-gate.sh` §1 à l'aval). Sur le lab : `http://wm-mock-prod:8080/rest/apigateway`, posée par le harnais et **restaurée en tête de trap** (le lab au repos garde le terminus fermé : A4/A6 live l'assertent ; `KEEP_TERMINUS=1` la laisse).
- **Accorder** : `envs/<terminus>/wm-admin` = l'admin de la gateway du terminus, posé par `scripts/setup-terminus-apps.sh` (valeurs **requises**, jamais un défaut) — la policy `operator-deploy` le lit depuis G7.
- **Porter** : `deployerGroup: apim-operator-prod` (oscar), l'ITSM re-vérifié au dispatch, puis la garde : `PALIER_FERME` pour qui ne lit pas le ticket, `DEPLOYER_GROUP_REQUIRED` pour qui ne porte pas `operator-deploy`.

### 2. Sous une déclaration de déployeur, l'équipe de cloisonnement vient de Git (garde A3 §2ter)

L'ordre de la garde devient : lookup-self (une fois) → **la porte lue** (`deployerGroup`) → **§2bis la déclaration prouvée** (inchangée) → **§2ter l'équipe** → capacités → ticket. Sous une déclaration **prouvée** : `TEAM = team:` du manifeste mergé (figée à la première demande, A1 ; approuvée au merge par la porte) ; absente ⇒ **`TEAM_INDETERMINEE`** (jamais le tenant du déployeur du moment : bob mettrait l'application sous `payments-team`, et une application née sans équipe ne peut plus en recevoir — `CONTRAT_DIVERGENT`) ; `APIM_TEAM` ne peut que concorder ⇒ **`TEAM_DIVERGENTE`** ; un palier **sans** déclaration doit déjà être déclaré dans `per_env` ⇒ **`TEAM_NON_ATTESTEE`** sinon (une application ne naît pas à `int` — attestation partielle : « déclaré » n'est pas « appliqué par un tenant ») ; les tenants du porteur sont journalisés. Sans déclaration : A3 mot pour mot (`TEAM_NON_PORTEE`). Rien n'est décidé sur un porteur non prouvé (`DEPLOYER_GROUP_REQUIRED` précède toute ligne d'équipe). En mode `internal`, `auth.vault_sub` doit être sous `deploy/<TEAM>/` ⇒ **`VAULT_SUB_HORS_TENANT`**. C'est la décision client n°4 réduite à un choix d'annuaire : « le même `operator-deploy` que les APIs » ou « un groupe distinct » marchent sans une ligne de code.

### 3. La demande sous identité de forge (`FORGE_TOKEN`)

`scripts/lib/forge-identity.sh` : `forge_login` (`GET /api/v1/user`, token par fichier ; 401 ⇒ `FORGE_TOKEN_INVALIDE`, 403 ⇒ `FORGE_SCOPE_INSUFFISANT` — read:user —, login hors classe ⇒ `FORGE_LOGIN_INVALIDE`, réseau ⇒ erreur), `forge_is_service`, `forge_askpass`. `provision-request.sh` et `app-rollback-request.sh` : le token humain (`FORGE_TOKEN` du formulaire ou `FORGE_TOKEN_FILE`) est copié dans un fichier 0600 puis **retiré de l'environnement** avant tout processus enfant ; il pousse (par `GIT_ASKPASS`, jamais une URL ni un argv, l'erreur de push filtrée des deux tokens) et ouvre la PR (**l'auteur est l'humain** — c'est lui que la porte à quatre yeux confronte au mergeur) ; le token de service reste celui des lectures et du plan enchaîné. **Sans token humain, il n'y a pas d'humain** : aucun appel, `(service)` ; sous `fourEyes` la demande refuse **`REQUESTER_UNKNOWN`** au plus tôt (la porte A4 reste l'autorité). Le formulaire porte le token en `password` (canal natif, fait 9 d'A0), altération détectée (`TOKEN_ALTERE`), héritage d'une globale refusé (`TOKEN_GLOBAL_REFUSE`) ; la voie machine vide `FORGE_TOKEN` (décision client n°3 : elle ne demande pas au-delà des paliers autonomes). **Une PR ouverte n'appartient qu'à son auteur** : `EXIST` ne réutilise une PR ouverte que si son auteur est l'identité qui pousse ; sinon **`PR_D_AUTRUI`** (un force-push réécrirait sous le nom d'autrui ce qu'un tiers approuvera) ; `REPLI_EN_COURS` (A6) devient inconditionnel à l'auteur. Le commit porte `Demande-Par:` (informatif), la PR « ouverte par : … ».

### 4. Les références à la demande, la chaîne entière, le contrat au dispatch, les trois identités

- `CHANGE_REF` / `PV_REF` (formulaire) ⇒ `per_env.<env>.change_ref` / `pv_ref` (quotés, seulement si fournis — octet pour octet sinon) ; classe de la porte A4 (`REF_INVALIDE`) ; `GATE_REFS_REQUIRED` à la demande quand la porte l'exige.
- **La chaîne ENTIÈRE** aux deux formulaires (`app-request`, `selfservice-app-deploy`) et au poseur de l'aval — le terminus n'est plus exclu par structure, il est gardé par ses portes (mesuré : `build job:` valide les `choice`).
- **Le contrat figé relu au dispatch** (porte A4 §2ter) : la racine du manifeste mergé doit égaler celle du parent du merge, sinon **`CONTRAT_DIVERGENT`** (un commit manuel sur `provision/*` passait `PR_HORS_PERIMETRE`, qui ne regarde que les fichiers).
- Le commentaire d'apply porte **les trois identités** : demandée par · mergée par · portée par (jamais sur `REFUSED`).

### 5. Le lab : onboarding par palier, terminus équipé, mock fidèle

`ansible/providers.{rec,int,homol,prod}.yml` (config du lab : A1 exige que le palier visé déclare l'équipe) ; `scripts/setup-terminus-apps.sh` (ticket Vault, Teams, `accessProfile`, alias auth-server **depuis des valeurs locales — jamais copié** d'une autre gateway, login prouvé, mot de passe faux ⇒ 401, `--print`) ; le mock : `POST /assets/team` assigne les **applications** (teams `[{id,name,source}]`, `Default` retirée), une application neuve est en `[Administrators, Default]`, `PUT` préserve `teams`. **L'API au terminus est un geste producteur** (export de la source, import au terminus — les deux appels d'ADR-079, sens réel→mock, GUID et `isActive` conservés), joué par le harnais comme remède d'`API_NOT_PROMOTED`.

## Refus nommés (nouveaux ou étendus)

`REQUESTER_UNKNOWN` et `GATE_REFS_REQUIRED` **à la demande** (les deux demandes), `REF_INVALIDE` (demande), `PR_D_AUTRUI`, `FORGE_ILLISIBLE`, `REPLI_EN_COURS` (quel que soit l'auteur), `FORGE_TOKEN_INVALIDE` / `FORGE_SCOPE_INSUFFISANT` / `FORGE_LOGIN_INVALIDE`, `TOKEN_ALTERE` / `TOKEN_GLOBAL_REFUSE` (formulaires), `TEAM_INDETERMINEE` (sous déclaration : remède « nommer team: »), `TEAM_DIVERGENTE`, `TEAM_NON_ATTESTEE`, `VAULT_SUB_HORS_TENANT` (garde A3), `CONTRAT_DIVERGENT` (porte A4).

## Conséquences et limites, écrites d'avance

- **Une application sans `team:` est confinée aux paliers autonomes** (et `team` ne s'ajoute plus après coup : A1). Nommer l'équipe dès la première demande.
- **L'attestation de l'équipe est partielle** : « déclaré » ≠ « appliqué par un tenant » ; l'attestation forte est l'approbateur (`approverGroup`, non vérifié — A4) ou un annuaire de forge (l'organisation Gitea `banking-demo` existe ; `GET /orgs/<team>/members/<login>` la tiendrait — option client, hors A7).
- **Mode `internal` au-delà des paliers autonomes** : `TENANT_NON_PORTE` sous un déployeur non-tenant (un déployeur aussi tenant, ou un AppRole dédié : décision client).
- **Un PAT Gitea n'expire pas** et couvre tous les dépôts du porteur : token dédié, scopes minimaux (`read:user + write:repository`), révoqué après ; contre un token volé, la chaîne oppose le merge par un tiers (fourEyes) et la **pause nominative** (mot de passe d'annuaire du mergeur). Le `Sudo` de forge et l'identité Jenkins (anonyme sur ce lab) sont refusés comme preuve ; un SSO de forge n'est pas joué.
- **`GITEA_SERVICE_LOGINS` est une liste négative** (un compte de service hors liste passe pour humain) ; un contrôle positif (`is_admin`) est nommé, non joué.
- **Les globales Jenkins choisissent les hôtes** (`APIM_TERMINUS_BASE`, `APIM_API_BASE`, `GIT_HOST`) — le remède est que le credential nomme son hôte (`base_url` dans `envs/<env>/wm-admin`, lu par le rôle) : client.
- **`pv_ref` n'est vérifié par personne** ; `change_ref` l'est par l'ITSM. **`main` porte à prod un état mergé jamais appliqué** après la contre-épreuve ITSM (le repli le mesure : `ETAT_IDENTIQUE`).
- **Le mock** ne mint aucune `apiAccessKey` : ce lab prouve « la clé de la 10.15 n'est jamais transportée », pas « une clé distincte par gateway » ; l'archive mock→réel reste refusée par le produit (G7) ; `operator-deploy` lit `gateways/*` (l'admin de la 10.15) — la segmentation hors-prod du lab est topologique.
- **`APIM_DATA_BASE` sans variante terminus** (la sonde data-plane est éteinte) ; **le formulaire ne propose que les APIs des `publish.yml`** (une API d'`inbound.yml` se demande par le script) ; `APIM_TERMINUS_BASE` restaurée après le passage ; mono-gateway hors terminus.
