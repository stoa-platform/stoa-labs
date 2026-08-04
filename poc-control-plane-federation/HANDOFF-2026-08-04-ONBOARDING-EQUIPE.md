# HANDOFF — 2026-08-04 : onboarding d'équipe, et le bouton qui ne commandait rien

_Branche `feat/onboarding-equipe-palier-1`, 26 commits depuis `9ead53b`. Non poussée._

## En une phrase

Créer une équipe passe d'un script de spike à deux tenants en dur à un rôle Ansible
piloté par un fichier déclaratif — et, chemin faisant, la variable censée désactiver
le cloisonnement, qui ne désactivait rien, a été réparée.

---

## 1. Le défaut d'origine, celui qui a lancé la passe

Constat du 2026-08-03 : `apim_ss_require_team=false` posé, et le rôle appelait
malgré tout `GET /accessProfiles`, échouant sur une gateway dont la feature Teams
est éteinte.

La cause n'était pas un bug mais un **écart entre le nom d'une variable et sa
portée** : `apim_ss_require_team` ne commandait que deux `assert` ; le travail réel
était commandé par la présence d'un nom d'équipe — que le job Jenkins pose
toujours, dérivé du chemin Vault des credentials (`cut -d/ -f2` sur
`APIM_WM_CREDS_SUB`). Le seul contournement possible exigeait d'éditer le dépôt de
l'équipe, c'est-à-dire l'endroit dont E1 a établi qu'il ne doit avoir aucune
autorité, et faisait reposer la désactivation sur une **absence** : rien dans Git
n'aurait jamais dit « ici le cloisonnement est volontairement désactivé, depuis
telle date, pour telle raison ».

**Ce qui remplace ça** : deux notions distinctes au lieu d'une.

| Variable | Nature | Qui la pose |
|---|---|---|
| `apim_ss_teams_feature` | état de la plateforme (`auto` \| `off`) | inventaire de l'environnement, dépôt plateforme |
| `apim_ss_require_team` / `apim_pub_require_team` | politique, par rôle | inventaire de l'environnement |
| `apim_teams_required` | paramètre lu par la sonde, dérivé par l'appelant | jamais posé à la main |
| `apim_teams_assert` | demander l'état SANS la politique | `apim_team_onboard` seulement |

La sonde (`roles/apim_common/tasks/teams-feature.yml`) lit
`GET /configurations/extended`, pose `apim_teams_enabled`, et applique une table de
vérité à quatre lignes. **La quatrième est la raison d'être du dispositif** :
feature ACTIVE + dérogation posée → refus `TEAMS_DEROGATION_STALE`. Ta dérogation
meurt donc d'elle-même le jour où ton correctif passe en production, sans que
personne ait à s'en souvenir.

Et le bouton commande désormais le **travail**, pas seulement les assertions.

---

## 2. Ce qui est livré

| Brique | Où |
|---|---|
| Rôle d'onboarding d'équipe | `ansible/roles/apim_team_onboard/` (resolve, vault, gateway, verify) |
| Playbook | `ansible/onboard-team.yml` |
| Source déclarative | `ansible/providers.dev.yml` |
| Sonde Teams partagée | `ansible/roles/apim_common/tasks/teams-feature.yml` |
| Projection des approbateurs | `ansible/roles/apim_publish_api/tasks/approvers.yml` |
| Script de preuve | `scripts/test-onboard-team.sh` |
| Suites hors ligne | `ansible/test-onboard-guards.yml`, `ansible/test-onboard-guards-live.yml` |
| Surfaces Teams du mock | `mocks/webmethods/admin_teams.go` |

Une équipe = une ligne dans `providers.dev.yml`. Tout le reste est **dérivé** de
gabarits déclarés une fois — user `svc-<team>`, groupe `<team>-devs`, chemin KV
`deploy/<team>/wm-admin`, policy `deploy-<team>` — **les mêmes que ceux dont le CI
dérive la team à l'exécution**. C'est ce qui garantit que ce que l'onboarding pose
et ce que le runtime dérive ne peuvent pas diverger.

Le fichier déclare **qui existe** ; le credential prouve **qui parle**. Une table
de correspondance consultée au runtime aurait remplacé une propriété enforcée par
Vault par une simple affirmation.

---

## 3. Ce que les mesures ont établi

Toutes faites sur `poc-webmethods-real` (10.15 réelle), pas supposées.

- **`enableTeamWork` est bien exposé** par `GET /configurations/extended`, en
  **chaîne** `"false"`, parmi 109 clés. Le configId est `extended`.
- **L'hypothèse ouverte du spec est CONFIRMÉE** : feature éteinte, `POST /groups`
  → 201, `POST /accessProfiles` → 201, relecture présente avec `groupIds` portant
  l'UUID, `DELETE` 204/204 sans résidu. **Ton bug ne bloque pas l'onboarding** :
  les objets se posent, leur effet de cloisonnement reste dormant jusqu'à
  réactivation. Rien à rejouer le moment venu.
- **Les identifiants n'ont pas une forme unique** : objets SYSTÈME `id == name`
  (`API-Gateway-Providers`, `Everybody`…), objets CUSTOM créés par POST → UUID.
  Aucun code ne présume la forme : il relit l'identifiant depuis la réponse.
- **`owner` vit en `apiResponse.api.owner`**, au niveau `api` et non `apiResponse`
  (contrairement à `teams`), c'est une **chaîne**, absente de la liste et présente
  en GET unitaire, et elle porte aujourd'hui le login du créateur — que la
  projection écrase, selon ta convention.
- **`ansible.builtin.uri` rend TOUJOURS `changed=false`** quand il n'écrit pas de
  fichier local (`uri.py:746`). Conséquence développée au §6.

---

## 4. Les défauts trouvés — dont sept dans le plan lui-même

Le mécanisme a rattrapé plus de défauts de conception que d'erreurs d'exécution.
Ceux qui valent d'être connus :

**Le paramètre de politique deviné.** La sonde lisait `apim_ss_require_team` en dur,
alors que `apim_publish_api` utilise `apim_pub_require_team`. Une variable absente
retombe sur son défaut sans qu'Ansible proteste : le bouton aurait été inopérant
sur la moitié du périmètre, silencieusement. La politique est devenue un
**paramètre** fourni par l'appelant, avec un test qui verrouille la régression.

**L'onboarding cassait au retour de la feature.** Le rôle passait
`apim_teams_required: false` en pensant dire « je ne dépends pas de la feature ».
Mais ce paramètre exprime une **dérogation**, que la quatrième ligne de la table tue
quand la feature revient. L'onboarding aurait donc échoué **exactement le jour où
ton correctif arrive**. D'où `apim_teams_assert`, qui sépare l'état de la politique.

**Le script d'amorçage Vault exigeait la gateway.** En réparant « le runbook laisse
les policies manquantes », le playbook d'onboarding complet a été appelé — volet
gateway compris. Ton runbook ne démarre jamais webMethods et la gateway trial est
recyclée toutes les ~20 min : le remède aurait supprimé **toutes** les identités
userpass au lieu d'un 34/34 dégradé. D'où le mode `apim_onb_gateway=false`.

**Une correction qui ouvrait une brèche.** Dériver le périmètre de la policy du
gabarit KV était juste sur la configuration par défaut, mais sur un gabarit « à
plat » — que le dépôt documente comme un cas client réel — il désignait le
sous-arbre **partagé** : la policy d'une équipe aurait accordé la lecture des
secrets de toutes les autres, et dans le cas sans séparateur, de `stoa/*` entier,
credentials d'admin de la gateway compris. L'ancien code était trop étroit (403
bruyant, fail-closed) ; le nouveau était trop large et silencieux. Fermé par la
garde `TENANT_ROOT_UNSAFE`, qui refuse le gabarit avant toute écriture.

**Trois pièges Jinja/Ansible**, tous silencieux : une clé de dictionnaire YAML n'est
pas templée (`"{{ var }}": valeur` poste le nom de la variable comme nom de champ) ;
`map(attribute='x')` sans `default=[]` lève **dans** le filtre, un `| default([])`
en aval ne rattrape pas ; et comparer une empreinte de réponse Vault entière échoue
toujours, l'identifiant de requête changeant à chaque lecture.

---

## 5. Ce qui te revient (gestes exploitant)

**1. Trancher `payments-team`.** Déclaré dans `providers.dev.yml` avec `repo: ""` et
`approvers: []`, volontairement vides. Les valeurs inventées ont été refusées : les
matricules sont projetés dans `owner`, que ton développement custom lit pour
notifier les approbateurs — des matricules fictifs désigneraient des approbateurs
**inexistants** sur une API réelle, et personne ne s'en apercevrait avant qu'une
approbation n'arrive jamais. Tant qu'ils sont vides, la projection ne fait rien pour
cette équipe : comportement voulu, pas panne.

**2. Rebaser avant de fusionner.** La branche part de `9ead53b`, antérieur à
`86b3a7e` qui introduit `scripts/secrets-baseline.txt`. `check-no-plaintext-secrets.sh`
échoue donc avec 23 signalements, **tous préexistants, aucun de ce travail** —
vérifié. Ça se résout au rebase. Aucun des trois commits d'`origin/main` ne touche
`ansible/` ni `mocks/`.

**3. Décider du sort du chemin d'assignation.** `apim_selfservice_app/tasks/team.yml`
et `api-visibility.yml` ne s'exécutent désormais que feature ACTIVE. Ils étaient
prouvés avant cette passe contre ta gateway feature active ; ils ne l'ont pas été
**depuis** le câblage. Ce n'est pas une régression démontrée, c'est une preuve non
rejouée. Deux façons de fermer : combler `POST /assets/team` dans le mock, ou
rejouer la preuve quand tu rallumes la feature — nécessaire de toute façon.

**4. Confirmer la forme d'écriture d'`owner` avant mise en service client.** Seule
la **lecture** a été mesurée en live ; l'enveloppe d'écriture a été retenue par
symétrie. Le risque est mitigé par construction : l'assertion de relecture est
fail-closed et nomme le piège d'enveloppe, donc une forme fausse ferait échouer le
premier publish bruyamment. À confirmer quand même.

**5. Rien à merger côté `stoa`** — cette passe n'a touché que `stoa-labs`.

---

## 6. La fragilité à connaître : une preuve tient à une ligne

`ansible.builtin.uri` ne signale jamais de changement quand il n'écrit pas de
fichier local. Un `changed=0` au second run ne prouve donc **rien** par lui-même :
il serait vrai même si le rôle réécrivait tout à chaque passage.

Ce qui rend la preuve d'idempotence signifiante, c'est le `changed=1` du **premier**
run, produit par l'**unique** `changed_when` véridique du rôle
(`gateway.yml`, tâche « poser le membre du groupe »). Le script de preuve exige donc
les deux, et traite un `changed=0` au premier run comme un **échec** — avec le
message qui l'explique.

Si quelqu'un retire ou casse ce `changed_when` un jour, cette exigence est le seul
garde-fou : sans elle, la preuve resterait verte en ne prouvant plus rien.

---

## 7. Comment rejouer la preuve

Les gardes **hors ligne** ne demandent ni gateway, ni Vault, ni identité :

```bash
cd poc-control-plane-federation
ansible-playbook -i ansible/inventory.lab.ini ansible/test-onboard-guards.yml
# attendu : failed=0 — table de vérité, garde du nom d'équipe, dérivations
```

La table de vérité **feature ACTIVE** (le cas que le lab n'a jamais eu) se rejoue
contre le mock, avec bascule et restauration automatiques :

```bash
cd poc-control-plane-federation/mocks/webmethods && go run . &   # relève le port
ansible-playbook -i ansible/inventory.lab.ini ansible/test-onboard-guards-live.yml
# attendu : TEAMS_DEROGATION_STALE réellement EXÉCUTÉE, pas seulement relue
```

Les **sept preuves**, sur une équipe jetable. La cible est obligatoire et sans
défaut — c'est délibéré, `localhost:5555` est ta gateway en service :

```bash
export VAULT_TOKEN=…            # jamais écrit dans le script
WM_GATEWAY_URL=http://<ta-cible> ./scripts/test-onboard-team.sh
# attendu : 7 PASS / 0 FAIL, exit 0
```

La preuve n°3 est la seule qui compte vraiment : les autres vérifient que des objets
existent, celle-là vérifie que **l'isolation tient** — un token portant la policy de
l'équipe lit son propre KV en 200 et se voit refuser celui d'une autre en 403. Sans
elle, on aurait onboardé une équipe sans savoir si elle est cloisonnée.

---

## 8. Ce qui n'est prouvé par rien

Dit franchement — une lacune connue vaut mieux qu'une confiance mal placée.

1. **Aucun test automatisé n'exerce les cinq points de câblage feature ACTIVE.**
   Toutes les contre-épreuves ont observé un *saut de tâche*, jamais une *exécution*.
   Rien ne prouve que le travail **reprend** quand la feature revient — seulement
   qu'il s'arrête correctement quand elle est éteinte.
2. **Le correctif `apim_teams_assert` n'a de test que manuel.** Sa contre-épreuve est
   sérieuse mais n'est dans aucun playbook : la protection contre la régression du
   défaut le plus grave de la passe repose sur un geste à la main. Dix lignes dans
   `test-onboard-guards-live.yml` suffiraient — la mécanique de bascule y est déjà.
3. **`onboard-team.yml` n'a jamais tourné contre la vraie gateway 10.15.** Les shapes
   ont été mesurées à la main, le rôle a tourné contre le mock. Défendable vu le
   recyclage 20 min, mais il faut le dire tel quel.
4. **La policy n'est éprouvée par ses capacités réelles que sur les chemins par
   défaut.** La garde `TENANT_ROOT_UNSAFE` ferme le cas dangereux, mais aucun test ne
   joue la douve avec un gabarit surchargé légitime.
5. **Deux gaps préexistants du mock** : pas de `POST /apis` multipart (donc pas de
   bout-en-bout du rôle de publication), pas de `DELETE` sur users/groupes/
   accessProfiles (la preuve 7 échoue contre le mock ; elle est acquise contre la
   vraie gateway).

---

## 9. Ce qu'il faut garder de cette passe

**Un garde-fou qu'on n'a jamais vu échouer n'est pas un garde-fou.** Cinq défauts de
cette classe ont été trouvés : un bouton qui ne commandait rien, un message qui
orientait vers un levier inopérant, un avertissement qui conseillait le mauvais
script, un en-tête promettant une indépendance que le code n'avait pas, et une
preuve d'idempotence qui serait restée verte quoi qu'il arrive. Aucun n'a été trouvé
en relisant du code : tous en cassant volontairement la garde pour voir si elle
rougissait.

**Le plus instructif** est la vérification qui passait au vert **à tort** : en
substituant un compte leurre réellement membre des groupes, l'ancienne assertion
constatait une appartenance vraie — pour le mauvais compte. Elle ne mentait pas,
elle vérifiait la mauvaise chose. Aucune relecture ne l'aurait montré.

**Et la leçon la plus chère** : une correction peut être pire que le défaut. Dériver
le périmètre d'une policy d'un gabarit était juste sur la configuration testée et
transformait un échec bruyant en accès silencieux sur les autres. La contre-épreuve
avait produit le cas et l'avait lu comme un succès — elle vérifiait que la valeur
changeait comme prévu, pas ce qu'elle **autorisait**.
