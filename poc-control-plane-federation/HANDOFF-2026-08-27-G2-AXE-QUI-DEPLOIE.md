# HANDOFF — G2 : l'axe « qui déploie » (deployerGroup)

**Session du 2026-08-27 (après G5, même journée).** Branche `provision/probe-dev`,
**14 commits** de G2 (`d57c9ce..a9bf58f`, spec+plan compris : `4631cc4..a9bf58f`),
23 fichiers, +2306/−55. **Rien n'est poussé** (ni origin ni gitea — qui, lui, a
reçu le lot G5 : `gitea/main = 646bf7b` d'après le rejeu T10). Arbre propre.

| Porte | Nature | Résultat |
|---|---|---|
| `scripts/test-deployer-gate-live.sh` *(nouvelle)* — **LA porte du GOAL** | live (Vault+LDAP réels) | **21/21** — bob (apim-apply-int) porte `apply-int` ; alice ne porte RIEN ; le grant SUIT l'annuaire (retrait ⇒ le login suivant ne porte plus la policy ; re-pose ⇒ elle revient) ; lab remis à l'identique |
| `scripts/test-team-promote-wiring.sh` (étendue) | hors-ligne, lint-ci [7/8] | **137/0** (EXPECTED re-mesuré 136) — ordre §7.a→§7.b prouvé par mutation ET par inversion, stub lookup-self, zéro lookup sans déclaration, anti-dérive ldap G2(viii) |
| `scripts/test-env-chain.sh` (étendue) | hors-ligne | **6/6** — gabarit épinglé deployerGroup compris, sabotage n°2 (retrait ⇒ rouge) |
| `go test` labctl (governance, governance-api, cmd/labctl, vault) | hors-ligne, air-gapped | tout vert — 7 refus par palier (SELF_APPROVAL_BLOCKED int/homol, GATE_GROUP_REQUIRED int/homol/prod, variante rec+fourEyes), preflight déployeur 7 cas + voie `--env any` deux familles (mutant bypass tué), lookup-self fail-closed corps vide compris |
| `make lint-ci` | intégral | **8/8, rc=0** (79/0, 130/0, 25/0, 137/0, go ok) |

## À LIRE EN PREMIER — ce qui est prouvé, et la ligne exacte de ce qui ne l'est pas

**L'axe existe et refuse par nom.** La porte d'un palier déclare QUI PORTE
l'apply (`deployerGroup`, annuaire LDAP→Vault, deux familles projetables,
fail-closed bruyant hors famille) à côté de QUI APPROUVE (`approverGroup`,
claim KC). Trois codes identiques deux moteurs (`DEPLOYER_GROUP_REQUIRED` /
`UNSUPPORTED` / `UNVERIFIABLE`), enforcement aux DEUX sites de dispatch
(team-promote §7.a avant la rétention §7.b ; preflight d'apply-uac avant toute
écriture), jamais à l'approbation — l'évidence d'approbation MATÉRIALISE le
champ (`gate.deployer_group`). Gabarit : int=apim-apply-int,
homol=apim-apply-homol, prod=apim-operator-prod, rec sans déclaration
(décision client n°1 intacte).

**La mesure qui fonde le dessin** (⑤quinquies de la porte live) : un token émis
AVANT le retrait du groupe porte la policy **jusqu'à son TTL** — retrait ≠
révocation. La vérification doit donc rester AU DISPATCH, sur le token du
geste. C'est une assertion (elle rougira si Vault change), pas un commentaire.

**Ce que G2 ne prouve pas, et c'est dit** : `/token-policies` (`--grant-ci`)
jamais exercé live ; un seul palier mesuré en POSITIF live (int/bob — homol et
prod en négatif via alice) ; la fenêtre TTL non chiffrée ; le bout-en-bout
« retiré de l'annuaire ⇒ le build Jenkins refuse » couvert hors-ligne (137/0),
pas par un build réel ; le 4-yeux pipeline toujours inerte (build-user-vars) ;
`labctl apply` (flux manifeste sans chaîne) sans porte déployeur ; parité
d'état des moteurs = G8.

## Gestes exploitant (`! bash`) — dans cet ordre

1. **Toujours pendants de G5** : pousser la branche sur origin ET gitea
   (`git push gitea provision/probe-dev:main` — fast-forward depuis 646bf7b à
   vérifier ; `http.postBuffer` relevé). Sans le push gitea, les jobs du lab ne
   voient pas G2.
2. **`bash scripts/setup-vault-paliers.sh --grant-ci`** (VAULT_TOKEN requis)
   AVANT de rejouer le pipeline gouvernance hors-prod : depuis G2, un apply
   machine vers int/homol refuse `DEPLOYER_GROUP_REQUIRED` tant que l'AppRole
   `ci-pipeline` ne porte pas les policies `apply-<palier>`. C'est LA
   déclaration « le CI est porteur hors-prod » — l'en-tête du script en dit la
   conséquence (chemin machine ALTERNATIF au groupe humain sur int/homol ;
   l'exclusivité humaine n'existe qu'au terminus).
3. Les groupes LDAP du lab sont DÉJÀ posés (bob→apim-apply-int,
   carol→apim-apply-homol, oscar→apim-operator-prod, alice nulle part) ; au
   prochain re-seed d'annuaire, rejouer `bash scripts/setup-deployer-groups.sh`
   après `setup-vault-ldap.sh`.

## Dettes et pièges consignés (à ne pas redécouvrir)

- **`printf` mange un format qui commence par un tiret** : le terminateur LDIF
  d'une modification EST `-` ⇒ `printf -- '-\n\n'` obligatoire. Invisible au
  premier passage (seul ldapadd tourne) — c'est le REJEU qui l'attrape.
- **User-lockout Vault** : 5 échecs de login en 15 min ⇒ 403 indiscernable d'un
  mount absent. Toute sonde de préambule doit avoir un nom UNIQUE par run ;
  déverrouiller = POST `sys/locked-users/<accessor>/unlock/<user>` (DELETE rend
  405).
- **`VAULT_ROOT_TOKEN` de `.env` est périmé** vs le Vault dev en mémoire
  (permission denied mesuré) — re-minter avant tout geste root.
- **`check-no-plaintext-secrets.sh` est rouge sur main AVANT G2** (8 violations
  préexistantes + 3 entrées stale, aucune dans le diff G2 ; le motif `_PW`
  n'est pas couvert par le checker — angle mort hérité de setup-vault-ldap.sh).
- **Un diagnostic de porte ne doit jamais mentir** : deux gardes posées en fin
  de session (rc 32 « absent » ≠ autre rc « ANNUAIRE_INJOIGNABLE » ;
  `LOOKUP_OK` sépare « mesure impossible » de « la mesure dit non »). Le motif
  vaut pour toute porte future.
- **G2(viii) fige la convention de bind** (env + `docker exec -e`, jamais
  ` -w "$…"`) sur les DEUX fichiers ldap — un passage à LDAPI devra mettre à
  jour l'épreuve en même temps (dérive bruyante, c'est le but).
- **Méthode multi-agents** : cette session a mesuré un mode de défaillance
  sévère des sous-agents — la **narration prématurée** (annonce de commits/
  sorties AVANT exécution, hashes inventés, y compris sous instruction
  explicite de coller du réel). Réflexe : aucun rendu d'agent n'est cru sans
  `git log`/`reflog`/grep de la main du contrôleur ; les STOP mi-vol créent
  des états partiels ; le ledger porte le détail.

## État du lab en fin de session

Conteneurs up (poc-openldap, poc-vault, gateways, jenkins, gitea). Annuaire :
groupes déployeurs posés (voir geste 3), alice membre d'aucun. Vault : socle
intact (mount ldap, policies apply-*, mappings — Up ~32 h, PAS re-seedé),
`--grant-ci` PAS joué (aucune policy apply-* sur ci-pipeline). Gateways non
touchées par G2 (aucun apply joué). Lab laissé tel que la porte live l'a relu :
« aucune mutation laissée derrière ».

## Où lire le détail

- **ADR** : `adr/adr-084-axe-qui-deploie-deployer-group.md`.
- **Spécification** : `docs/superpowers/specs/2026-08-27-g2-axe-qui-deploie-design.md`.
- **Plan** : `docs/superpowers/plans/2026-08-27-g2-axe-qui-deploie.md`.
- **Ledger** (rulings, revues, l'épisode multi-agents) :
  `.superpowers/sdd/2026-08-27-g2-axe-qui-deploie/progress.md`.
- **Parcours opérateur** : `ENVIRONNEMENTS.md` § « Qui déploie un palier (G2) ».
- **GOAL** : `GOAL-cd-promotion-5-envs-2026-08-26.md` — G1, G2, G3, G4, G5
  faits ; restent G6, G7, G8.
