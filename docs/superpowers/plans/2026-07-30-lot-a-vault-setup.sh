#!/bin/sh
# Lot A — configuration de Vault pour la voie A. À exécuter DANS vault-0, PAR
# L'EXPLOITANT. AUCUN argument positionnel : les six valeurs ci-dessous
# arrivent sur STDIN, UNE PAR LIGNE, DANS CET ORDRE — jamais en argv, qui
# resterait visible dans /proc/<pid>/cmdline pendant toute l'exécution, sur
# worker-1 (le kubectl exec) comme dans le pod (le sh qui exécute ce script),
# lisible par tout utilisateur du nœud. Mesuré le 2026-07-30 : ni rsyslog ni
# auth.log ne sont en cause sur ce cluster (rsyslog inactif, sudo journalise
# dans journald sans les arguments du script appelé) — c'est bien la table des
# processus, et seulement elle, qui motive ce choix :
#   1. clé de descellement 1/2 (quorum 2/3)
#   2. clé de descellement 2/2
#   3. mot de passe de bind de l'annuaire (Secret openldap-admin)
#   4. mot de passe de démonstration d'alice
#   5. mot de passe de démonstration de carol
#   6. mot de passe de démonstration d'oscar
# Les valeurs 4-6 sont lues par l'opérateur sur le fichier root-only
# /root/stoa-lab-secrets/lab-vault-users.env du nœud (tâche 3 /
# seed-ldap-cluster.sh) ; CE script ne le lit ni ne l'écrit lui-même — il
# tourne dans vault-0, ce fichier vit sur worker-1.
#
# Active auth/userpass et auth/ldap, écrit les policies deploy-<tenant> et
# operator-deploy, configure le mount ldap, le mapping groupe -> policy, et
# charge les mots de passe de démonstration dans secret/ci/lab-users/*.
# IDEMPOTENT : rejouable sans effet de bord.
#
# Jeton racine ÉPHÉMÈRE par quorum. Il N'A PAS DE TTL — il n'expire JAMAIS
# seul. Le `trap` de révocation est posé AVANT le premier `generate-root` (pas
# après le décodage) : actif même si un Ctrl-C ou un échec survient pendant la
# cérémonie elle-même.
#
# PRINCIPE STRUCTURANT DE LA RÉVOCATION, à ne pas affaiblir :
#   la révocation se prouve PAR L'ACCESSOR DE L'OBJET, jamais en lisant le
#   texte d'un message d'erreur.
# Vault répond « permission denied » / « invalid token » pour TOUT jeton qu'il
# ne connaît pas — y compris un jeton qui n'a JAMAIS été valide (décodage
# corrompu), y compris quand aucun jeton n'a été envoyé. Trois rondes de
# correction ont conclu « révoqué » sur cet échec-là pendant que le jeton du
# quorum était vivant (mesuré : accessors 1 → 2). D'où le protocole appliqué
# plus bas, dans cet ordre :
#   1. l'accessor du jeton est CAPTURÉ pendant qu'il est encore valide
#      (`vault token lookup -format=json`) — un accessor non vide vaut donc
#      certificat que Vault a ACCEPTÉ ce jeton au moins une fois ;
#   2. un jeton de CONTRÔLE indépendant (orphelin, TTL court) est créé AVANT
#      la révocation, sans quoi le script perd toute identité en révoquant et
#      ne peut plus rien observer ;
#   3. après révocation, avec ce jeton de contrôle, UNE SEULE lecture :
#      `vault list auth/token/accessors`. Sa réussite établit d'un coup que
#      Vault répond, qu'on est authentifié avec le privilège requis, et si
#      l'accessor cible y figure encore. Absence d'objet dans une énumération
#      qui a abouti — pas exégèse de chaîne, et pas non plus deux observations
#      dont il faudrait recoller les modes de panne (voir le commentaire
#      détaillé au point de vérification : c'est le NOMBRE de lectures, autant
#      que leur ordre, qui décide si la preuve est fail-open ou fail-closed).
# Sans accessor capturé, le script n'affirme JAMAIS une révocation : il crie.
#
# `trap … INT TERM` termine EXPLICITEMENT le script (`exit 130`) : un trap qui se contente d'exécuter une
# action, sans `exit`, laisse le script REPRENDRE après le signal — vérifié le
# 2026-07-30 dans l'ash de hashicorp/vault:1.18 (process de premier plan d'un
# conteneur, signal envoyé de l'extérieur) : sans `exit`, la boucle interrompue
# continue et le script sort en code 0 ; avec `exit 130`, il s'arrête net.
# Motif renforcé de 2026-07-29-f4-vault-role-toggle.sh.
#
# Amendement du 2026-07-30 (A.2) : secret/ci/lab-users/* n'est PAS lu par
# alice/carol/oscar pour se connecter À Vault — ce serait circulaire. Il est lu
# par le HARNAIS de la tâche 5, authentifié par identité de pod (A.3), sous un
# préfixe déjà couvert par sa policy jenkins-agent — voir le commentaire de
# l'étape 7/7 ci-dessous pour le pourquoi de "ci/" et non "lab/". Le fichier
# /root/stoa-lab-secrets/lab-vault-users.env n'est PAS effacé par ce script et
# ne doit pas l'être : {SSHA} rend l'annuaire irréversible (tâche 3, A.1), donc
# ce fichier reste l'unique copie humainement lisible de secours si Vault est
# scellé. Un shred a été envisagé puis retiré par décision de l'exploitant —
# ne pas le réintroduire ici.
#
# Usage (poste opérateur, racine stoa-labs) :
#   scp docs/superpowers/plans/2026-07-30-lot-a-vault-setup.sh worker-1:/tmp/la.sh
#   ssh -t worker-1 'BP=$(sudo cat /root/stoa-lab-secrets/openldap-admin); \
#     AP=$(sudo grep ^LAB_ALICE_PASS= /root/stoa-lab-secrets/lab-vault-users.env | cut -d= -f2-); \
#     CP=$(sudo grep ^LAB_CAROL_PASS= /root/stoa-lab-secrets/lab-vault-users.env | cut -d= -f2-); \
#     OP=$(sudo grep ^LAB_OSCAR_PASS= /root/stoa-lab-secrets/lab-vault-users.env | cut -d= -f2-); \
#     [ -n "$BP" ] && [ -n "$AP" ] && [ -n "$CP" ] && [ -n "$OP" ] || { echo "secrets du noeud illisibles ou vides" >&2; exit 1; }; \
#     sudo k3s kubectl -n ci exec -i vault-0 -- sh -c "cat > /tmp/la.sh && chmod 700 /tmp/la.sh" < /tmp/la.sh \
#       || { echo "copie du script dans vault-0 echouee — rien saisi, rien execute" >&2; exit 1; }; \
#     read -r -s -p "Cle de descellement 1/2 : " K1; echo; \
#     read -r -s -p "Cle de descellement 2/2 : " K2; echo; \
#     printf "%s\n%s\n%s\n%s\n%s\n%s\n" "$K1" "$K2" "$BP" "$AP" "$CP" "$OP" \
#       | sudo k3s kubectl -n ci exec -i vault-0 -- sh /tmp/la.sh; \
#     RC=$?; \
#     unset K1 K2 BP AP CP OP; \
#     sudo k3s kubectl -n ci exec vault-0 -- rm -f /tmp/la.sh; rm -f /tmp/la.sh; \
#     exit $RC'
#
# RATTRAPAGE SI L'EXECUTION EST INTERROMPUE — À LIRE AVANT DE COMMENCER :
# le `kubectl exec -i` ci-dessus n'alloue PAS de pty (pas de `-t`). Un Ctrl-C
# sur le terminal `ssh -t worker-1` frappe le groupe de processus de PREMIER
# PLAN SUR worker-1 (le client kubectl), PAS le `sh` qui tourne DANS le pod.
# Le client kubectl meurt, la connexion se coupe, et le kubelet termine le
# process distant par un SIGKILL — un signal qui ne se piège PAS : le `trap`
# de ce script ne s'exécute JAMAIS dans ce cas précis, même si les deux clés
# de descellement ont déjà été acceptées et qu'un jeton racine sans TTL est
# donc vivant côté serveur. Ce script ne peut pas se protéger seul contre ça
# (mesuré le 2026-07-30 : l'ancien `trap … INT` corrigé plus bas ne couvre
# QUE le cas où le signal atteint réellement le process du pod).
# Si l'exécution est interrompue (Ctrl-C, perte de session SSH, etc.) APRÈS
# avoir saisi les deux clés de descellement, considérer qu'un jeton racine
# éphémère est VIVANT jusqu'à preuve du contraire, et le révoquer à la main
# DEPUIS vault-0, avec un jeton root valide (au besoin via une nouvelle
# cérémonie de quorum). NE JAMAIS révoquer un accessor à l'aveugle — un
# mauvais choix casse un jeton légitime (démontré en ronde 3) : IDENTIFIER
# d'abord CHAQUE accessor suspect avant de le révoquer.
#
#   *** DANGER — LIRE EN ENTIER AVANT DE TAPER LA MOINDRE COMMANDE ***
#   policies=["root"] ET ttl=0 NE SUFFISENT PAS à identifier le jeton fuité.
#   Le jeton racine PERMANENT du Vault (celui d'`operator init`, présent en
#   permanence, celui qui est déjà là avant toute cérémonie) satisfait
#   EXACTEMENT les deux mêmes critères. Mesuré le 2026-07-30 sur un Vault
#   1.18.5 : après une cérémonie, `vault list auth/token/accessors` rend DEUX
#   accessors STRICTEMENT INDISCERNABLES sur ces deux champs.
#   SEUL `creation_time` les sépare : celui à révoquer est le PLUS RÉCENT, et
#   il est POSTÉRIEUR au début de la cérémonie interrompue.
#   Se tromper détruit le jeton racine permanent du Vault, DE FAÇON
#   IRRÉVERSIBLE — il ne se régénère que par une NOUVELLE cérémonie de quorum,
#   avec les clés irremplaçables. Dans le doute : NE RIEN RÉVOQUER, relever
#   les `creation_time` des deux, et les comparer à l'heure de l'incident.
#
#   Si le script a eu le temps d'AFFICHER un accessor (tous ses avertissements
#   le font dès qu'il en connaît un), utiliser CELUI-LÀ et rien d'autre : il
#   désigne l'objet sans ambiguïté et dispense de toute cette gymnastique.
#
#   vault list auth/token/accessors
#   vault token lookup -format=json -accessor <id>
#   #   NB : tout autre drapeau (-format=json…) doit passer AVANT <id>, sinon
#   #        « Too many arguments with -accessor » (mesure, Vault 1.18.5).
#   #   -> comparer les creation_time AVANT de choisir (voir le DANGER
#   #      ci-dessus). Un accessor dont ttl est NON NUL n'est de toute façon
#   #      pas lui : ce peut être le jeton de CONTRÔLE créé par ce script
#   #      (orphelin, policies=["root"], TTL 5 min) s'il a survécu à un arrêt
#   #      brutal — celui-là expire seul, ne pas s'en occuper.
#   vault token revoke -accessor <id>
#
# NB — deux flux STDIN distincts, à ne JAMAIS fusionner en un seul exec :
#   1) celui qui copie le CORPS de ce script dans le pod (`cat > /tmp/la.sh`,
#      un exec à part) ;
#   2) celui, plus bas dans ce bloc, qui alimente les SIX valeurs à
#      `sh /tmp/la.sh` UNE FOIS lancé (un second exec, séparé).
# Les mélanger ferait lire au script son propre code source comme un secret —
# piège déjà rencontré à la tâche 3 (un `head`/`read` mal placé qui affamait le
# flux suivant).
set -eu

die() { echo "ECHEC : $1" >&2; exit 1; }

# Lecture des six valeurs sur STDIN (voir le bloc Usage ci-dessus).
# `IFS= read -r VAR || [ -n "$VAR" ] || die …` : `read` rend un code non nul
# dès que le flux se termine sans saut de ligne final APRÈS la valeur lue —
# cas nominal pour la DERNIÈRE ligne, rien n'oblige l'émetteur distant à
# ajouter un `\n` terminal. La valeur est néanmoins bien assignée dans ce cas ;
# seule une valeur VIDE signale un flux réellement tronqué. Vérifié le
# 2026-07-30 dans l'ash de hashicorp/vault:1.18 : `read` laisse la variable
# assignée (vide ou non) même en sortie EOF, y compris sous `set -u`.
IFS= read -r K1         || [ -n "$K1"         ] || die "cle de descellement 1 absente (stdin tronque)"
IFS= read -r K2         || [ -n "$K2"         ] || die "cle de descellement 2 absente (stdin tronque)"
IFS= read -r BIND_PW    || [ -n "$BIND_PW"    ] || die "mot de passe de bind absent (stdin tronque)"
IFS= read -r ALICE_PASS || [ -n "$ALICE_PASS" ] || die "mot de passe alice absent (stdin tronque)"
IFS= read -r CAROL_PASS || [ -n "$CAROL_PASS" ] || die "mot de passe carol absent (stdin tronque)"
IFS= read -r OSCAR_PASS || [ -n "$OSCAR_PASS" ] || die "mot de passe oscar absent (stdin tronque)"

BASE_DN="dc=corp,dc=example"
LDAP_URL="ldap://openldap.ci.svc.cluster.local:389"

# --- revocation du jeton racine ephemere : posee AVANT le premier
# generate-root, verifiee par relecture, jamais juste "affirmee". ---
#
# QUORUM_OK/QUORUM_MAYBE distinguent trois mondes que VAULT_TOKEN seul ne
# distingue PAS :
#   - rien n'existe encore cote serveur (rien a revoquer) ;
#   - "peut-etre" : la 2e cle a ete SOUMISE mais on ne sait pas encore si le
#     serveur l'a acceptee avant qu'une erreur ou un signal n'interrompe la
#     commande CLI — Vault peut avoir deja cree le jeton meme si LA COMMANDE,
#     elle, semble avoir echoue (reponse perdue en route, ou signal recu
#     pendant l'appel) ;
#   - "confirme" : la commande a rendu la main avec succes, le quorum a
#     REUSSI a coup sur.
# Dans les deux derniers cas Vault a (ou peut avoir) DEJA cree un jeton racine
# sans TTL, vivant, meme si ce script echoue ou est interrompu avant de le
# decoder. Trouve par les rondes de relecture 2/5 et 3/5, chacune sur des
# chemins distincts reproduits contre un Vault reel : extraction de jeton
# encode ratee, decodage rate, SIGINT/SIGHUP entre la soumission de la 2e cle
# et l'assignation de VAULT_TOKEN, erreur CLI sur cette meme soumission APRES
# acceptation serveur — zero appel a token revoke, zero avertissement, le
# tout en silence, a chaque fois que le garde ne couvrait pas EXACTEMENT la
# bonne fenetre.
# AUCUNE de ces variables n'est jamais `unset` par la suite — seulement
# reaffectee a "". Sous `set -u`, la premiere lecture d'une variable UNSET par
# le trap tue le trap A SA PREMIERE LIGNE UTILE, en silence : la revocation
# n'a jamais lieu et l'avertissement promis par le die() qui precede n'est
# JAMAIS affiche (mesure : "line 161: STEP2: parameter not set", accessors
# 1 -> 2, deux fois de suite). Une variable vide se lit sans erreur ; une
# variable detruite, non. REGLE : tout ce que revoke_root_token() lit se
# neutralise par VAR="", jamais par `unset`.
REVOKE_DONE=0
REVOKE_RUNNING=0
VAULT_TOKEN=""
QUORUM_OK=0
QUORUM_MAYBE=0
STEP2=""
ENC=""
OTP=""
ACCESSOR=""
LOOKUP_ERR=""

# Renseigne ACCESSOR *uniquement* si `vault token lookup` REUSSIT avec le
# jeton porte par VAULT_TOKEN. C'est tout l'interet : un ACCESSOR non vide est
# la preuve que Vault a ACCEPTE ce jeton (donc qu'il existe reellement cote
# serveur) ET l'identifiant de l'objet a revoquer. Un jeton non vide mais
# jamais valide (decodage corrompu) ne produit AUCUN accessor — et c'est
# exactement ce qui empeche desormais le script de le declarer "revoque".
capture_accessor() {
  ACCESSOR=""
  [ -n "$VAULT_TOKEN" ] || { LOOKUP_ERR="aucun jeton en main"; return 1; }
  if _lk=$(vault token lookup -format=json 2>&1); then
    ACCESSOR=$(printf '%s' "$_lk" | tr -d '\n' \
      | sed -n 's/.*"accessor": *"\([^"]*\)".*/\1/p')
    if [ -n "$ACCESSOR" ]; then
      return 0
    fi
    LOOKUP_ERR="lookup accepte mais champ accessor absent de la reponse"
    return 1
  fi
  LOOKUP_ERR="$_lk"
  return 1
}

revoke_root_token() {
  [ "$REVOKE_DONE" = 1 ] && return 0
  # Garde d'anti-recursion : un `exit` DEPUIS cette fonction redeclenche le
  # trap EXIT. Distinct de REVOKE_DONE, qui ne vaut 1 qu'une fois la
  # revocation PROUVEE (voir plus bas) — c'est ce qui rend la revocation
  # reprenable au lieu de la court-circuiter.
  [ "$REVOKE_RUNNING" = 1 ] && return 0
  REVOKE_RUNNING=1

  # LA REVOCATION EST INDIVISIBLE. Sans cette ligne, un signal frappant le
  # GROUPE DE PROCESSUS (eviction de pod, `kubectl delete pod`, drain de noeud)
  # pendant `vault token revoke` tuait l'appel, le trap se rearmait, retombait
  # sur le drapeau deja pose et rendait 0 : la verification ne tournait jamais
  # et le jeton survivait, derniere ligne affichee "Revocation du jeton racine
  # ephemere..." puis plus rien (mesure : accessors 1 -> 2). Ignorer ces
  # signaux ici les fait aussi ignorer par le `vault` fils (une disposition
  # SIG_IGN est heritee), donc l'appel de revocation va jusqu'au bout. Seul
  # SIGKILL passe encore — il ne se piege pas, voir le bloc RATTRAPAGE.
  trap '' INT TERM HUP QUIT

  _quorum_maybe_or_ok=0
  [ "$QUORUM_OK" = 1 ] && _quorum_maybe_or_ok=1
  [ "$QUORUM_MAYBE" = 1 ] && _quorum_maybe_or_ok=1

  if [ -z "$VAULT_TOKEN" ] && [ "$_quorum_maybe_or_ok" = 1 ] && [ -z "$ENC" ] && [ -n "$STEP2" ]; then
    # La 2e cle a ete SOUMISE (QUORUM_MAYBE) mais le corps du script n'a pas
    # extrait ENC (ex : la commande a rendu une erreur cote CLI). La sortie
    # STANDARD du `vault` reel est neanmoins CAPTUREE par `STEP2=$(...)`
    # independamment de son code de retour — si le serveur a bien repondu
    # avec le jeton encode avant que l'erreur ne survienne (reponse perdue en
    # aval, par exemple), STEP2 le contient deja. Tenter de l'y extraire ICI
    # avant d'abandonner.
    ENC=$(echo "$STEP2" | sed -n 's/.*"encoded_token": *"\([^"]*\)".*/\1/p')
    [ -n "$ENC" ] || ENC=$(echo "$STEP2" | sed -n 's/.*"encoded_root_token": *"\([^"]*\)".*/\1/p')
  fi

  # Un jeton en main mais pas encore CERTIFIE : le faire valider par Vault
  # maintenant. Un lookup qui reussit rend l'accessor ; un lookup qui echoue
  # laisse ACCESSOR vide — et c'est ce VIDE, jamais le texte de l'erreur, qui
  # interdira plus bas toute affirmation de revocation.
  if [ -n "$VAULT_TOKEN" ] && [ -z "$ACCESSOR" ]; then
    capture_accessor || true
  fi

  if [ -z "$ACCESSOR" ] && [ "$_quorum_maybe_or_ok" = 1 ] && [ -n "$ENC" ] && [ -n "$OTP" ]; then
    # Dernier recours, sur DEUX chemins a la fois : aucun jeton en main, ou un
    # jeton en main que Vault vient de refuser (donc issu d'un decodage rate).
    # `-decode` appelle GET /v1/sys/generate-root/attempt — PAS un calcul
    # purement local malgre ce qu'affirmait un commentaire anterieur (corrige
    # en ronde 3 : mesure, cet appel echoue bien si le serveur est
    # injoignable). Ce qui reste vrai et fait l'interet du retry : il NE
    # CONSOMME AUCUN NONCE (verifie en le rejouant, y compris pendant une
    # nouvelle ceremonie), donc le retenter ici est sans danger cote Vault —
    # seulement inutile si le serveur est hors service.
    _dec=$(vault operator generate-root -decode="$ENC" -otp="$OTP" -format=json 2>/dev/null) \
      || _dec=$(vault operator generate-root -decode="$ENC" -otp="$OTP" 2>/dev/null) || _dec=""
    _root=$(printf '%s' "$_dec" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
    [ -n "$_root" ] || _root=$(printf '%s' "$_dec" | tr -d '[:space:]')
    # EXPORT indispensable : sans lui, les appels `vault` plus bas ne voient
    # PAS ce jeton (VAULT_TOKEN reste une simple variable de shell, pas une
    # variable d'environnement) et partent sans authentification — 403 avale
    # par le `|| true`, PUIS le lookup echoue A SON TOUR faute de jeton, et
    # l'ancien code lisait CET echec comme une preuve de revocation : le
    # script annoncait "revoque" pendant que le vrai jeton restait vivant
    # (mesure : accessors 1 -> 2). Pire, mesure aussi : s'il existe un
    # ~/.vault-token ambiant dans le pod, `revoke -self` SANS jeton explicite
    # revoque CELUI-LA a la place — un jeton totalement different, sans lien
    # avec la fuite reelle.
    if [ -n "$_root" ]; then
      VAULT_TOKEN="$_root"; export VAULT_TOKEN
      capture_accessor || true
    fi
  fi

  # SANS ACCESSOR, RIEN N'EST PROUVABLE — donc rien n'est affirme.
  if [ -z "$ACCESSOR" ]; then
    if [ "$_quorum_maybe_or_ok" = 0 ]; then
      # Aucune cle n'a jamais ete soumise : Vault n'a rien cree, il n'y a rien
      # a revoquer. SEUL chemin ou se taire est correct.
      REVOKE_DONE=1
      REVOKE_RUNNING=0
      return 0
    fi
    echo "AVERTISSEMENT CRITIQUE : le quorum a peut-etre ete ATTEINT (2e cle" >&2
    echo "soumise) — Vault a peut-etre CREE un jeton racine que ce script n'a" >&2
    echo "pas pu IDENTIFIER (aucun accessor obtenu : aucun lookup n'a jamais" >&2
    echo "reussi avec ce jeton), donc pas pu revoquer. AUCUNE REVOCATION N'A" >&2
    echo "EU LIEU. S'il existe, ce jeton n'a PAS de TTL : il n'expirera JAMAIS" >&2
    echo "seul, et sa valeur n'a jamais ete affichee." >&2
    echo "Derniere erreur de lookup : ${LOOKUP_ERR:-<aucun lookup tente>}" >&2
    echo "Recours : vault list auth/token/accessors, puis, sur CHACUN," >&2
    echo "vault token lookup -format=json -accessor <id>." >&2
    echo "DANGER : policies=[\"root\"] ET ttl=0 sont satisfaits AUSSI par le" >&2
    echo "jeton racine PERMANENT du Vault — les deux sont indiscernables sur" >&2
    echo "ces champs. SEUL creation_time les separe (le plus RECENT est celui" >&2
    echo "a revoquer). Se tromper detruit le jeton racine permanent de facon" >&2
    echo "IRREVERSIBLE. Lire le bloc RATTRAPAGE en tete de ce script avant de" >&2
    echo "revoquer quoi que ce soit." >&2
    exit 1
  fi

  # --- A partir d'ici l'accessor est connu : le jeton EXISTE cote serveur (un
  # lookup a REUSSI avec lui) et on sait exactement lequel c'est. Revocation,
  # puis PREUVE PAR L'OBJET. ---
  #
  # Le jeton de CONTROLE est cree AVANT la revocation, et c'est le coeur du
  # correctif : une fois la revocation faite, le script n'a plus AUCUNE
  # identite — tout `vault token lookup -accessor` echouerait alors faute
  # d'authentification, que la cible soit revoquee ou non, et lire ce seul
  # echec comme une preuve est exactement l'erreur qui a survecu a trois
  # rondes.
  #   -orphan      : INDISPENSABLE — un enfant du jeton racine serait revoque
  #                  en cascade avec lui et ne pourrait plus rien observer.
  #   -policy=root : les chemins utilises ici (revocation par accessor, puis
  #                  ENUMERATION des accessors) sont sudo-proteges. DETTE
  #                  consignee, a trancher par l'exploitant : root n'est pas
  #                  strictement necessaire, une policy dediee suffirait — mais
  #                  il lui faudrait "update"+"sudo" sur
  #                  auth/token/{revoke-accessor,lookup-accessor} ET "list"
  #                  +"sudo" sur auth/token/accessors, ce dernier a cause de
  #                  l'enumeration ci-dessous. Contrepartie : cela cree un
  #                  objet policy DURABLE dans Vault, la ou -policy=root
  #                  n'existe que le temps du jeton. Ne pas confondre "sudo"
  #                  et "root" : c'est le privilege sudo qui est requis, pas
  #                  la policy root elle-meme.
  #   -ttl         : il MEURT SEUL. Mesure sur Vault 1.18.5 : ttl=119 a la
  #                  creation d'un -ttl=120s, donc il ne se confond JAMAIS
  #                  avec le jeton du quorum (ttl=0) dans une chasse aux
  #                  accessors, et sa fuite eventuelle est bornee dans le
  #                  temps — contrairement a ce qu'il sert a prouver.
  CHECK_TOKEN=$(vault token create -orphan -policy=root -ttl=300s -field=token 2>/dev/null) \
    || CHECK_TOKEN=""

  if [ -z "$CHECK_TOKEN" ]; then
    # Repli : sans jeton de controle on peut encore REVOQUER, mais plus
    # PROUVER. On ne conclut donc pas — et on donne l'accessor a l'operateur,
    # ce qui rend son rattrapage sans ambiguite (aucun creation_time a
    # comparer, aucun risque de detruire le jeton racine permanent).
    vault token revoke -self >/dev/null 2>&1 || true
    echo "AVERTISSEMENT : revocation TENTEE mais NON PROUVEE — le jeton de" >&2
    echo "controle n'a pas pu etre cree (Vault scelle, injoignable, ou jeton" >&2
    echo "sans droit sudo). Sans lui, aucune lecture post-revocation n'a de" >&2
    echo "valeur probante : elle echouerait de toute facon, faute d'identite." >&2
    echo "Verifier A LA MAIN, des que Vault est joignable, que CET accessor et" >&2
    echo "aucun autre a bien disparu :" >&2
    echo "  vault token lookup -format=json -accessor $ACCESSOR" >&2
    echo "  vault token revoke -accessor $ACCESSOR   # s'il repond encore" >&2
    exit 1
  fi

  VAULT_TOKEN="$CHECK_TOKEN"; export VAULT_TOKEN
  vault token revoke -accessor "$ACCESSOR" >/dev/null 2>&1 || true

  # UNE SEULE LECTURE, QUI PORTE LES DEUX FAITS A LA FOIS. Ne pas la scinder.
  #
  # `vault list auth/token/accessors` ENUMERE les accessors existants. Sa
  # REUSSITE etablit d'un seul coup que Vault repond, qu'on est authentifie
  # avec le privilege requis (ce chemin est sudo-protege) ET l'etat de la
  # cible : l'accessor figure dans la reponse, ou il n'y figure pas.
  #
  # Pourquoi une seule et pas deux. Toute version a DEUX observations —
  # « la cible ne repond pas » puis « le controle repond » — assimile un code
  # de retour non nul de la lecture cible a « l'objet a disparu ». Le controle
  # qui suit n'elimine que les causes qui cassent AUSSI le controle ; une
  # erreur transitoire propre au seul appel cible passe alors pour une
  # absence. Mesure sur la version precedente, Vault restant joignable et le
  # controle repondant : exit 0, banniere "Configuration terminee",
  # "PROUVE PAR L'OBJET" — et root+ttl0 1 -> 2, un jeton racine sans TTL
  # VIVANT. Ce n'etait plus un probleme d'ORDRE (il etait correct) mais de
  # NOMBRE : deux observations, donc une fenetre et deux modes de panne a
  # reconcilier. Avec une seule reponse il n'y a plus rien a reconcilier, et
  # TOUT echec de cet appel tombe dans INCONCLUANTE — la direction sure.
  #
  # NB : cette enumeration ne peut pas etre vide au moment ou on la lit — le
  # jeton de controle qui l'execute y figure lui-meme. Un `vault list` qui
  # echoue est donc toujours une vraie panne, jamais un "aucun resultat".
  if ! _acc_list=$(vault list -format=json auth/token/accessors 2>&1); then
    echo "AVERTISSEMENT : verification de revocation INCONCLUANTE — l'enumeration" >&2
    echo "des accessors a echoue (Vault scelle ou injoignable ? jeton de controle" >&2
    echo "expire ?), donc l'etat du jeton racine ephemere est INCONNU : ni prouve" >&2
    echo "revoque, ni prouve vivant. Sortie brute :" >&2
    printf '%s\n' "$_acc_list" >&2
    echo "Verifier A LA MAIN, des que Vault est joignable, que CET accessor et" >&2
    echo "aucun autre a bien disparu :" >&2
    echo "  vault token lookup -format=json -accessor $ACCESSOR" >&2
    echo "  vault token revoke -accessor $ACCESSOR   # s'il repond encore" >&2
    exit 1
  fi

  case "$_acc_list" in
    *"\"$ACCESSOR\""*)
      echo "AVERTISSEMENT CRITIQUE : le jeton racine ephemere EXISTE ENCORE apres" >&2
      echo "tentative de revocation — son accessor figure toujours dans" >&2
      echo "l'enumeration. Il n'a PAS de TTL : il n'expirera JAMAIS seul, et sa" >&2
      echo "valeur n'a jamais ete affichee." >&2
      echo "Le revoquer a la main, par CET accessor et aucun autre :" >&2
      echo "  vault token revoke -accessor $ACCESSOR" >&2
      vault token revoke -self >/dev/null 2>&1 || true
      exit 1
      ;;
  esac

  echo "  jeton racine ephemere revoque — PROUVE PAR L'OBJET : l'accessor"
  echo "  $ACCESSOR ne figure plus dans l'enumeration des accessors, laquelle"
  echo "  vient d'aboutir (Vault joignable, session authentifiee)."
  vault token revoke -self >/dev/null 2>&1 || true
  # REVOKE_DONE n'est pose qu'ICI, apres la PREUVE — pas a l'entree de la
  # fonction. Pose trop tot, il faisait return 0 a toute reentree du trap et
  # la verification ne tournait jamais.
  REVOKE_DONE=1
  REVOKE_RUNNING=0
  return 0
}
trap 'revoke_root_token' EXIT
trap 'revoke_root_token; exit 130' INT TERM HUP QUIT

echo "etape 1/7 : jeton racine ephemere par quorum…"
vault operator generate-root -cancel >/dev/null 2>&1 || true
INIT=$(vault operator generate-root -init -format=json) || die "etape 1 : generate-root -init a echoue (Vault scelle/injoignable ?)"
NONCE=$(echo "$INIT" | sed -n 's/.*"nonce": *"\([^"]*\)".*/\1/p')
OTP=$(echo "$INIT" | sed -n 's/.*"otp": *"\([^"]*\)".*/\1/p')
[ -n "$NONCE" ] && [ -n "$OTP" ] || die "etape 1 : nonce/otp non obtenus"
vault operator generate-root -nonce="$NONCE" -format=json "$K1" >/dev/null \
  || die "etape 1 : cle 1 refusee"
# Drapeau PESSIMISTE pose AVANT la soumission, pas apres son retour : si la
# commande echoue (reseau, timeout) ou si un signal survient PENDANT cet
# appel, le serveur peut deja avoir accepte la cle et cree le jeton — c'est
# precisement le moment ou l'operateur, qui vient de saisir sa 2e part et
# attend, est le plus susceptible d'interrompre. Sans ce drapeau AVANT
# l'appel, revoke_root_token() ne peut pas distinguer "rien ne s'est passe"
# de "le serveur a peut-etre deja cree un jeton" (trouve en ronde 3, mesure
# par comptage d'accessors sur les deux chemins : erreur CLI et signal
# pendant cet appel precis).
QUORUM_MAYBE=1
STEP2=$(vault operator generate-root -nonce="$NONCE" -format=json "$K2") \
  || die "etape 1 : cle 2 refusee (le serveur peut l'avoir ACCEPTEE avant l'erreur — voir l'avertissement de revocation qui suit)"
# A PARTIR D'ICI le quorum est REUSSI A COUP SUR : Vault a cree un jeton
# racine cote serveur, qu'il faudra revoquer quoi qu'il arrive dans la suite
# du script — meme si l'extraction ou le decodage qui suivent echouent.
QUORUM_OK=1
K1=""; K2=""
ENC=$(echo "$STEP2" | sed -n 's/.*"encoded_token": *"\([^"]*\)".*/\1/p')
[ -n "$ENC" ] || ENC=$(echo "$STEP2" | sed -n 's/.*"encoded_root_token": *"\([^"]*\)".*/\1/p')
# STEP2 est NEUTRALISE APRES le die() qui suit, jamais avant, et par
# affectation, jamais par `unset` : le trap le LIT (retry d'extraction d'ENC),
# et sous `set -u` une variable DETRUITE tue le trap a sa premiere ligne utile
# — le die() ci-dessous promettait alors un avertissement qui n'arrivait
# jamais, sans aucune revocation (mesure : accessors 1 -> 2, deux fois).
[ -n "$ENC" ] || die "etape 1 : le QUORUM A REUSSI mais le jeton encode n'a pas ete extrait de la reponse — voir l'avertissement de revocation qui suit"
STEP2=""; INIT=""; NONCE=""
DEC=$(vault operator generate-root -decode="$ENC" -otp="$OTP" -format=json 2>/dev/null) \
  || DEC=$(vault operator generate-root -decode="$ENC" -otp="$OTP") \
  || DEC=""
# Le `|| DEC=""` final n'est PAS de la ceinture-bretelles gratuite : sans lui,
# si les DEUX tentatives echouent, `set -e` abandonne le script sur ce point
# AVANT le test `[ -z "$ROOT" ]` plus bas, avec le message d'erreur brut de
# `vault` au lieu du die() voulu (et donc sans mention explicite que le
# quorum, lui, a reussi). Trouve en testant precisement ce double-echec.
ROOT=$(echo "$DEC" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
[ -n "$ROOT" ] || ROOT=$(echo "$DEC" | tr -d '[:space:]')
if [ -z "$ROOT" ]; then
  die "etape 1 : le QUORUM A REUSSI mais le decodage du jeton a echoue — voir l'avertissement de revocation qui suit"
fi
VAULT_TOKEN="$ROOT"; export VAULT_TOKEN
DEC=""; ROOT=""
# CAPTURE DE L'ACCESSOR PENDANT QUE LE JETON EST ENCORE VALIDE. Ce n'est pas
# un simple controle de sante : c'est la seule chose qui permettra, plus tard,
# de PROUVER la revocation par l'objet plutot que par le texte d'une erreur.
# Un jeton non vide n'est PAS un bon jeton — Vault repond "permission denied"
# aussi bien a un jeton revoque qu'a un jeton qui n'a JAMAIS existe (decodage
# corrompu). Seul un lookup REUSSI distingue les deux, et il ne peut avoir
# lieu qu'ICI, tant que le jeton vit.
capture_accessor \
  || die "etape 1 : jeton ephemere invalide ou non identifiable (${LOOKUP_ERR}) — voir l'avertissement de revocation qui suit"
echo "  jeton racine ephemere obtenu (accessor $ACCESSOR)"
# ENC/OTP restent vivants JUSQU'ICI (le trap s'en sert pour redecoder si le
# jeton en main s'avere faux) et sont neutralises par affectation, jamais par
# `unset` : ils sont LUS par le trap, et sous `set -u` un `unset` les y rend
# fatals. Le danger etait latent ici, inatteignable seulement par chance.
ENC=""; OTP=""

echo "etape 2/7 : mounts d'authentification…"
enable_auth() {
  # $1 = methode (userpass|ldap). Vault refuse avec "already in use" si le
  # mount existe deja (cas nominal, idempotence) ; toute AUTRE erreur (Vault
  # scelle, ACL insuffisante...) doit arreter le script — la confondre avec
  # "deja actif" masquerait un vrai probleme.
  _out=$(vault auth enable "$1" 2>&1) && { echo "  $1 active"; return 0; }
  case "$_out" in
    *"already in use"*) echo "  $1 deja actif" ;;
    *) printf '%s\n' "$_out" >&2; die "activation de auth/$1 refusee (voir ci-dessus)" ;;
  esac
}
enable_auth userpass
enable_auth ldap

echo "etape 3/7 : policies…"
# NB : ce heredoc n'est PAS quote (<<POL, pas <<'POL'>) — voulu, $T doit
# s'interpoler pour chaque tenant. Consequence : tout $ ou ` ajoute plus tard
# dans CE commentaire (ou dans le corps de la policy) sera EXPANSE/EXECUTE par
# le shell avant d'atteindre `vault policy write`, pas transmis tel quel a
# Vault. Echapper (\$, \`) tout caractere qui doit rester litteral — un
# backtick non echappe ici a deja mange un fragment de commentaire (corrige,
# ronde 1 de relecture).
for T in banking-demo payments-team; do
  vault policy write "deploy-$T" - <<POL
# Déployeur du tenant $T. Lecture des identifiants de la gateway et des
# paramètres OAuth2 ; écriture sur apps/* pour le mode \`internal\` (le client
# OAuth2 généré y est rangé).
path "secret/data/deploy/$T/*"     { capabilities = ["read"] }
path "secret/metadata/deploy/$T/*" { capabilities = ["read", "list"] }
path "secret/data/apps/$T/*"       { capabilities = ["create", "update", "read"] }
path "secret/metadata/apps/$T/*"   { capabilities = ["read", "list"] }
POL
  echo "  deploy-$T"
done

vault policy write operator-deploy - <<'POL'
# Opérateur de mise en production. Périmètre DIFFÉRENT des déployeurs de tenant :
# lit des secrets de PLATEFORME, hors de toute policy deploy-<tenant>. Qu'un HUMAIN
# ait ce droit est une DÉCISION CLIENT (ADR-078 § Décisions n°9) ; ici c'est un choix
# de lab, porté par un compte et un groupe séparés pour que la question reste visible.
path "secret/data/stoa/*"     { capabilities = ["read"] }
path "secret/metadata/stoa/*" { capabilities = ["read", "list"] }
POL
echo "  operator-deploy"

echo "etape 4/7 : configuration du mount ldap…"
# binddn/bindpass : le compte de service qui a le droit de CHERCHER dans l'annuaire.
# userdn/userattr : où et sous quel attribut trouver l'utilisateur. Chez le client
#   (AD) ce sera userattr=sAMAccountName, ou upndomain=corp.example pour un UPN.
# groupfilter par défaut : recherche inverse (quels groupes ont ce membre). Il ne
#   résout PAS les groupes imbriqués — dette notée dans la spéc.
# insecure_tls VOLONTAIREMENT absent : LDAP_URL est en ldap:// (pas ldaps://),
# donc aucune négociation TLS n'a lieu — ce champ n'aurait aucun effet ici et
# se lirait mal dans un audit client (laisserait croire à du TLS assoupli
# plutôt qu'à une absence totale de TLS, qui est la vraie situation de ce lab).
vault write auth/ldap/config \
  url="$LDAP_URL" \
  binddn="cn=admin,$BASE_DN" \
  bindpass="$BIND_PW" \
  userdn="ou=People,$BASE_DN" \
  userattr="uid" \
  groupdn="ou=Groups,$BASE_DN" \
  groupattr="cn" \
  starttls=false >/dev/null
BIND_PW=""
echo "  url=$LDAP_URL userdn=ou=People,$BASE_DN userattr=uid"

echo "etape 5/7 : mapping groupe -> policy…"
vault write auth/ldap/groups/banking-demo  policies=deploy-banking-demo  >/dev/null
vault write auth/ldap/groups/payments-team policies=deploy-payments-team >/dev/null
vault write auth/ldap/groups/operators     policies=operator-deploy      >/dev/null
echo "  banking-demo, payments-team, operators"

echo "etape 6/7 : secrets KV lus par les pipelines…"
# Valeurs de LAB : la gateway du cluster est en ClusterIP, non publiée. Déjà
# publiques dans tout le dépôt — acceptées en connaissance de cause, ne pas
# les faire disparaître au passage (hors périmètre de cette ronde).
vault kv put secret/deploy/banking-demo/wm-admin \
  username=Administrator password=manage >/dev/null
vault kv put secret/deploy/payments-team/wm-admin \
  username=Administrator password=manage >/dev/null
echo "  secret/deploy/<tenant>/wm-admin"

echo "etape 7/7 : mots de passe de demonstration (annuaire) dans Vault…"
# Chemin sous secret/ci/... et NON secret/lab/... : la SEULE policy qui touche
# ce mount est jenkins-agent (2026-07-28-vault-bootstrap.sh, étape 5/7) —
# path "secret/data/ci/*" { capabilities = ["read"] }. Le harnais de la tâche
# 5, authentifié par identité de pod avec CETTE policy, se prendrait un 403 sur
# tout prefixe secret/lab/*. On range donc sous le prefixe DÉJÀ autorisé
# plutôt que d'étendre le droit depuis ce script : une policy a une seule
# source de vérité, et `vault policy write` REMPLACE — une erreur de
# transcription ici retirerait au pipeline son accès à secret/ci/* en
# production. Corriger ce chemin après coup exigerait une seconde cérémonie de
# quorum avec les clés irremplaçables — d'où l'importance de le faire juste
# maintenant, pas après.
vault kv put secret/ci/lab-users/alice password="$ALICE_PASS" >/dev/null
vault kv put secret/ci/lab-users/carol password="$CAROL_PASS" >/dev/null
vault kv put secret/ci/lab-users/oscar password="$OSCAR_PASS" >/dev/null
ALICE_PASS=""; CAROL_PASS=""; OSCAR_PASS=""
echo "  secret/ci/lab-users/{alice,carol,oscar}"

echo
echo "RELECTURE (assertions explicites qui font die() sinon — pas un code de retour) :"

vault auth list -format=json | grep -q '"userpass/"' || die "relecture : auth/userpass absent"
echo "  mount actif : userpass"
vault auth list -format=json | grep -q '"ldap/"' || die "relecture : auth/ldap absent"
echo "  mount actif : ldap"

check_policy_path() {
  # $1 = policy, $2 = fragment de chemin qui DOIT apparaitre dans son contenu
  # REEL — vault policy list ne prouve que le NOM, pas le contenu (c'est
  # exactement ce que le bug de heredoc corrige en ronde 1 aurait pu cacher).
  vault policy read "$1" 2>/dev/null | grep -qF "$2" \
    || die "relecture : policy $1 ne contient pas '$2' (absente, vide, ou tronquee)"
  echo "  policy $1 : $2"
}
check_policy_path deploy-banking-demo  'path "secret/data/deploy/banking-demo/*"'
check_policy_path deploy-payments-team 'path "secret/data/deploy/payments-team/*"'
check_policy_path operator-deploy      'path "secret/data/stoa/*"'

vault read auth/ldap/config >/dev/null 2>&1 || die "relecture : auth/ldap/config illisible"
_url_seen=$(vault read -field=url auth/ldap/config 2>/dev/null) \
  || die "relecture : champ url de auth/ldap/config illisible"
[ "$_url_seen" = "$LDAP_URL" ] \
  || die "relecture : url de auth/ldap/config = '$_url_seen', attendu '$LDAP_URL'"
echo "  auth/ldap/config : url=$_url_seen (bindpass jamais renvoye par Vault en lecture)"

check_group_policy() {
  # $1 = groupe, $2 = policy attendue — verifie la VALEUR lue depuis Vault, pas
  # seulement que le groupe apparait dans `vault list`.
  _p=$(vault read -field=policies "auth/ldap/groups/$1" 2>/dev/null) \
    || die "relecture : auth/ldap/groups/$1 illisible"
  # `-field=policies` rend un format liste HCL brut, PAS une valeur nue :
  # "[deploy-banking-demo]" pour une seule policy, "[a b]" (espaces) pour
  # plusieurs — mesure a l'od -c contre un Vault 1.18.5 reel. Sans cette
  # normalisation, aucune correspondance n'est possible et une configuration
  # PARFAITEMENT correcte fait echouer la relecture (regression trouvee ronde
  # de relecture 2/5).
  _p=$(printf '%s' "$_p" | tr -d '[]' | tr ' ' ',')
  case ",$_p," in
    *",$2,"*) ;;
    *) die "relecture : groupe $1 -> policies='$_p', attendu '$2'" ;;
  esac
  echo "  groupe $1 -> $2"
}
check_group_policy banking-demo  deploy-banking-demo
check_group_policy payments-team deploy-payments-team
check_group_policy operators     operator-deploy

check_kv_field() {
  # $1 = chemin kv, $2 = champ attendu, present et NON VIDE — lit le CONTENU
  # reel, pas juste la presence du nom dans `vault kv list`.
  _v=$(vault kv get -field="$2" "$1" 2>/dev/null) || die "relecture : $1 illisible (champ $2)"
  [ -n "$_v" ] || die "relecture : $1 champ $2 present mais vide"
}
check_kv_field secret/deploy/banking-demo/wm-admin  username
check_kv_field secret/deploy/payments-team/wm-admin username
echo "  secret/deploy/<tenant>/wm-admin : lisible"
check_kv_field secret/ci/lab-users/alice password
check_kv_field secret/ci/lab-users/carol password
check_kv_field secret/ci/lab-users/oscar password
echo "  secret/ci/lab-users/{alice,carol,oscar} : lisible"
echo "  (liste, informatif) : $(vault kv list -format=json secret/ci/lab-users 2>/dev/null | tr -d '[]"\n' | tr ',' ' ' | tr -s ' ')"

echo
echo "Le fichier /root/stoa-lab-secrets/lab-vault-users.env du noeud n'a PAS ete"
echo "touche par ce script (conserve en 600 root — copie de secours, A.2)."
echo "Configuration terminee — chaque assertion de la relecture a reussi (die() sinon)."
echo "Revocation du jeton racine ephemere…"
