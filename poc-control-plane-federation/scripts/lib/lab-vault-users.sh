#!/usr/bin/env bash
# scripts/lib/lab-vault-users.sh — identités de DÉMONSTRATION de la voie A
# (user/mot de passe → Vault, ADR-078 §3). À SOURCER par setup-vault-userpass.sh
# (qui les crée) et par test-vault-user-login.sh (qui les rejoue) : source unique
# de vérité, aucune dérive possible entre le provisioning et la preuve.
#
# ⚠ Mots de passe LAB, jetables, volontairement en clair : c'est un annuaire de
# démonstration. Chez le client, RIEN de tout ceci n'existe — l'identité vient de
# l'AD et le mot de passe est saisi au build (paramètre `password`), jamais stocké.
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
LAB_ALICE_PASS="${ALICE_PASS:-Al1ce-lab-2026}"

LAB_CAROL_USER='carol'
LAB_CAROL_PASS="${CAROL_PASS:-C4rol-lab-2026}"

# Métacaractères VOLONTAIRES — guillemet, antislash, dollar, apostrophe,
# point-virgule, esperluette, accolades. Un corps JSON forgé à la main en shell
# (`-d "{\"password\":\"$P\"}"`) casse ou s'injecte là-dessus ; c'est la raison
# d'être du json.dumps dans ci/lib/vault-login.sh.
# $'…' = quoting ANSI-C : \\ -> \ , \' -> ' , et $dollar reste LITTÉRAL. Il doit
# être un mot À PART ENTIÈRE : bash ne l'interprète PAS à l'intérieur d'un
# "${VAR:-…}" (et les accolades y casseraient l'appariement) — d'où les 2 étapes.
LAB_BOB_USER='bob'
LAB_BOB_PASS_DEFAULT=$'B0b "q" \\back $dollar \'sq\' ;semi &amp {brace}'
LAB_BOB_PASS="${BOB_PASS:-$LAB_BOB_PASS_DEFAULT}"

# Alias d'alice : mêmes droits, mêmes creds — seul le FORMAT du login change.
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
# Le format de login n'est donc pas un détail de confort : il contraint le choix
# du backend d'auth. D'où la question #3 du runbook.
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
LAB_OSCAR_PASS="${OSCAR_PASS:-0scar-lab-2026}"

# oscar — OPÉRATEUR DE MISE EN PROD. Périmètre DIFFÉRENT des déployeurs de tenant :
# Jenkinsfile.prod/.rollback lisent des secrets de PLATEFORME (stoa/ci,
# stoa/opensearch, stoa/gateways/*), hors de toute policy deploy-<tenant>. D'où une
# policy distincte, `operator-deploy`. Qu'un HUMAIN ait le droit de lire ces secrets
# est une DÉCISION CLIENT (ADR-078 § Décisions n°9) : ici c'est un choix de lab,
# volontairement porté par un compte et un groupe SÉPARÉS pour que la question reste
# visible plutôt que diluée dans le périmètre des déployeurs.
LAB_OSCAR_USER='oscar'
LAB_OSCAR_PASS="${OSCAR_PASS:-0scar-lab-2026}"

LAB_TENANT_ALICE='banking-demo'
LAB_TENANT_BOB='payments-team'
