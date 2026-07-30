#!/usr/bin/env bash
# scripts/lib/lab-vault-users.sh — identités de DÉMONSTRATION de la voie A
# (user/mot de passe → Vault, ADR-078 §3). À SOURCER par les scripts de setup et
# par les harnais de preuve : source unique de vérité pour les NOMS, les FORMATS
# de login et les TENANTS — aucune dérive possible entre provisioning et preuve.
#
# ⚠ UN SEUL MOT DE PASSE ICI, ET IL EST PUBLIC EXPRÈS — celui de bob
# (`LAB_BOB_PASS_METACHARS`, plus bas). Ce n'est pas une fuite tolérée, c'est un
# choix : voir le bloc qui accompagne la variable pour le raisonnement complet et
# les bornes du risque. Le dépôt est PUBLIC depuis le 2026-07-30 ; l'écrire ici
# noir sur blanc vaut mieux que de laisser croire le contraire.
#
# ⚠ AUCUN AUTRE MOT DE PASSE ICI. Ceux d'alice, carol et oscar sont générés au
# setup et déposés dans un fichier root-only du nœud (cf.
# docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh). Un mot de passe qui
# sert à s'authentifier À Vault ne peut pas être rangé DANS Vault : c'est circulaire.
#
# HISTORIQUE DE CETTE LIGNE — elle a menti. Jusqu'au 2026-07-30 ce fichier
# annonçait « AUCUN MOT DE PASSE ICI » alors que `LAB_BOB_PASS_METACHARS` était
# déjà le mot de passe LDAP réel de bob (`seed-ldap-cluster.sh` le lui pose, et
# `login ldap/bob` rend 200). Deux autres écrits reprenaient l'affirmation, dont
# l'exemption de `check-no-plaintext-secrets.sh` — une garde de dépôt public
# dont l'exemption reposait sur une phrase fausse. Corrigé en disant la vérité,
# pas en changeant la valeur (cf. l'arbitrage, plus bas).
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

# ⚠⚠ CECI EST LE MOT DE PASSE LDAP RÉEL DU COMPTE `bob`, ET IL EST PUBLIC ⚠⚠
#
# Pas « un vecteur qui n'est le mot de passe d'aucun compte » : `seed-ldap-cluster.sh`
# pose exactement cette valeur comme `userPassword` de `uid=bob,ou=People,…`
# (`B_PW="$LAB_BOB_PASS_METACHARS"`), et `POST auth/ldap/login/bob` avec elle
# rend 200. Quiconque lit ce dépôt peut se connecter comme bob.
#
# C'EST ASSUMÉ, et voici pourquoi le risque est borné (arbitrage de l'exploitant,
# 2026-07-30) :
#   · l'annuaire et Vault sont en ClusterIP — pas d'exposition hors du cluster ;
#     se connecter comme bob suppose déjà de tenir un pod dans le cluster ;
#   · bob ne lit qu'UNE chose : `secret/deploy/payments-team/wm-admin`, dont la
#     valeur (`Administrator` / `manage`) est déjà publique à des dizaines
#     d'endroits du dépôt. Il n'y a rien à voler que ce dépôt ne donne déjà ;
#   · bob est REFUSÉ partout ailleurs, et ce refus est lui-même une preuve du
#     lot A (contre-épreuve cross-tenant : bob sur banking-demo -> 403).
# Ce que coûterait l'alternative : générer un mot de passe pour bob obligerait à
# le ranger dans Vault, donc à rouvrir une cérémonie de quorum avec des parts de
# descellement IRREMPLAÇABLES. Sans commune mesure avec un risque déjà borné.
#
# CE QUI SERAIT UNE VRAIE FUITE, en revanche : mettre ici le mot de passe
# d'alice, de carol ou d'oscar. Ceux-là ouvrent des périmètres réels et sont
# régénérés à chaque `seed-ldap-cluster.sh` ; ils vivent dans le fichier
# root-only du nœud et dans `secret/ci/lab-users/*`, jamais dans ce fichier.
#
# Sa RAISON D'ÊTRE reste le test d'INJECTION. Métacaractères VOLONTAIRES :
# guillemet, antislash, dollar, apostrophe, point-virgule, esperluette,
# accolades. Un corps JSON forgé à la main en shell (`-d "{\"password\":\"$P\"}"`)
# casse ou s'injecte là-dessus ; c'est la raison d'être du json.dumps dans
# ci/lib/vault-login.sh. Que ce soit AUSSI le mot de passe de bob est ce qui rend
# le test réel : c'est un vrai login qui doit passer, pas un appel bouchonné.
# $'…' = quoting ANSI-C : \\ -> \ , \' -> ' , et $dollar reste LITTÉRAL.
LAB_BOB_PASS_METACHARS=$'B0b "q" \\back $dollar \'sq\' ;semi &amp {brace}'

# Alias explicite — RÉTABLI le 2026-07-30. Il avait été supprimé en même temps
# que les quatre mots de passe brûlés, mais sans lui donner de remplaçant, alors
# que sa valeur, elle, n'a jamais quitté le fichier (juste au-dessus). Deux
# scripts en sont morts sans le dire :
#   · setup-vault-ldap.sh:~111  — sa garde `[ -z "$LAB_BOB_PASS" ]` était
#     TOUJOURS vraie, quels que soient les trois autres mots de passe : branche
#     « non semé », groupes jamais créés, `exit 2` systématique. Le monde compose
#     n'était plus reprovisionnable du tout ;
#   · test-vault-user-login.sh:~47 — même garde, d'où `0 passed, 0 failed,
#     1 skipped` et un `exit 0` VERT quoi qu'il arrive. Un test qui ne peut ni
#     passer ni échouer et qui rend vert est pire qu'un test absent.
# Le RHS est une pure indirection : aucun littéral n'apparaît sur cette ligne, et
# la garde check-no-plaintext-secrets.sh la laisse passer à ce titre (exemption
# « RHS de pure indirection », pas une exemption de nom).
LAB_BOB_PASS="$LAB_BOB_PASS_METACHARS"
