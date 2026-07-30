#!/bin/sh
# test-voie-a-cluster.sh — PORTE A et ses SIX contre-épreuves, exécuté DANS un
# pod du cluster (seul endroit où DNS, réseau et policies sont éprouvés en
# conditions réelles), avec l'identité de service jenkins-agent.
#
# Un login qui réussit ne prouve rien seul : ce sont les REFUS attendus qui
# font la preuve. Six contre-épreuves : mauvais mot de passe, cross-tenant,
# authentifié sans policy, jeton révoqué, formats de login (le piège userpass
# vs ldap), et le hachage de l'annuaire (amendement A.1).
#
# ── Deux modes, choisis SEULS par la présence de kubectl ────────────────────
#   MODE ORCHESTRATEUR (kubectl + KUBECONFIG disponibles — poste opérateur ou
#   agent Jenkins) : lance un pod éphémère --serviceaccount=jenkins-agent qui
#   exécute CE MÊME FICHIER (kubectl absent dans ce pod, donc il retombe
#   directement en mode pod, sans variable de bascule à maintenir) ; plie ses
#   compteurs PASS/FAIL/SKIP dans les siens ; puis fait lui-même la
#   contre-épreuve du hachage par `kubectl exec … slapcat`, qui n'est PAS un
#   outil réseau et ne peut donc pas tourner dans le pod curl-only.
#
#   MODE POD (curl+python3 seulement, kubectl absent) : sys/health, PORTE A,
#   et les cinq contre-épreuves réseau/Vault. Obtient les mots de passe de
#   démonstration d'alice et de carol depuis Vault PAR IDENTITÉ DE POD
#   (amendement A.3 — POST /v1/auth/kubernetes/login, role=jenkins-agent) :
#   plus aucun mot de passe n'est injecté par variable d'environnement depuis
#   le fichier root-only du nœud. Le jeton de service qui a servi à les lire
#   est révoqué aussitôt après (moindre privilège).
#
# Usage :
#   export KUBECONFIG=~/.kube/k3s-contabo.yaml
#   sh poc-control-plane-federation/scripts/test-voie-a-cluster.sh
#
# Le `VAULT_ADDR` de VOTRE poste est IGNORÉ en mode orchestrateur (voir plus
# bas) : aucune variable d'environnement du poste ne décide où le pod enverra
# des identifiants. Rien à désexporter avant de lancer.
#
# INTERDICTION ABSOLUE (rappel) : ce script n'imprime JAMAIS un mot de passe
# ni une empreinte complète. L'existence d'une valeur se prouve par sa
# LONGUEUR, jamais par son contenu — y compris pour le hachage LDAP, où la
# seule chose imprimée est le compte d'entrées {SSHA} vs non conformes.
set -u
# `A && ok || bad` (SC2015) est l'idiome des scripts de preuve du repo (cf.
# test-vault-user-login.sh) ; le mot de passe à métacaractères de bob part
# volontairement en littéral SC2016 (single-quoted, PAS d'expansion voulue).
# shellcheck disable=SC2015,SC2016

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗ %s\033[0m\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33m- %s (sauté)\033[0m\n' "$1"; SKIP=$((SKIP+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ADRESSE DE VAULT — la seule qui ait un sens DANS le cluster.
#
# ⚠ EN MODE ORCHESTRATEUR, LE `VAULT_ADDR` DU POSTE EST DÉLIBÉRÉMENT IGNORÉ.
# Défaut mesuré le 2026-07-30 : le poste de l'exploitant exporte
# `VAULT_ADDR=https://hcvault.<domaine-public>` depuis son ~/.zshrc ; l'ancien
# `V="${VAULT_ADDR:-…}"` héritait de cette valeur et la réinjectait dans le pod
# par `--env=VAULT_ADDR=$V`. Résultat : `auth/ldap/login` (donc le mot de passe
# d'alice, de bob et de carol), les lectures `secret/data/deploy/*` et le
# `auth/token/revoke-self` partaient vers un serveur TIERS. Aujourd'hui ça
# échoue fermé — le pod n'a pas d'egress vers cette adresse, d'où le 1/3/5
# observé au lieu de 17/0/0 — mais l'échec fermé est un accident de topologie,
# pas une propriété : le jour où cet egress existe, ce sont des identifiants qui
# partent, et le message d'échec accuse la tâche 4 au lieu de dire la vérité.
#
# CHOIX RETENU : ignorer, plutôt que valider un suffixe `.svc.cluster.local`.
#   1. Ce n'est pas une configuration, c'est une erreur de catégorie. Le
#      `VAULT_ADDR` d'un poste décrit ce que CE POSTE peut joindre ; le pod vit
#      sur un autre réseau. Aucune valeur héritée n'y est jamais correcte.
#   2. La validation par suffixe est un piège à elle seule : elle doit porter
#      sur l'HÔTE, pas sur l'URL. `http://vault.ci.svc.cluster.local:8200` ne
#      SE TERMINE PAS par `.svc.cluster.local` (il se termine par `:8200`), et
#      `https://x.example/#.svc.cluster.local`, lui, s'y termine. Il faudrait
#      donc parser l'URL — écrire un parseur d'URL en shell à l'endroit exact
#      où se tromper envoie des identifiants hors cluster est un mauvais
#      marché pour une souplesse dont personne n'a l'usage ici.
#   3. Le fichier a déjà sa convention pour ce qui doit rester réglable :
#      des noms DÉDIÉS (`LDAP_NS`, `LDAP_DEPLOY`, `VOIE_A_POD_NS`) qu'aucun
#      ~/.zshrc n'exporte par accident. Si un jour ce lab doit viser un autre
#      Vault EN CLUSTER, il faut ajouter une variable de ce genre — surtout
#      pas ressusciter l'héritage de `VAULT_ADDR`.
# Le MODE POD, lui, continue de la lire : c'est par elle que l'orchestrateur la
# lui transmet, et c'est aussi son seul moyen de la connaître.
VAULT_ADDR_IN_CLUSTER='http://vault.ci.svc.cluster.local:8200'
NS="${LDAP_NS:-ci}"
LDAP_DEPLOY="${LDAP_DEPLOY:-deploy/openldap}"
POD_NS="${VOIE_A_POD_NS:-ci}"

if command -v kubectl >/dev/null 2>&1; then
  # ═══════════════════════ MODE ORCHESTRATEUR ═══════════════════════════════
  # Adresse EN DUR, jamais héritée de l'environnement — cf. le bloc ⚠ ci-dessus.
  V="$VAULT_ADDR_IN_CLUSTER"
  sec "0. Lancement du pod de preuve (identité de service jenkins-agent, ns $POD_NS)"
  if [ -n "${VAULT_ADDR:-}" ] && [ "$VAULT_ADDR" != "$V" ]; then
    # Dit, pas tu : l'exploitant doit savoir que sa variable n'a pas servi,
    # sinon il croira avoir testé le Vault qu'il visait. L'adresse du poste
    # n'est PAS imprimée : elle n'est pas un secret, mais la règle du lot est
    # que ce harnais n'imprime jamais rien qui vienne de l'environnement.
    printf '  \033[33mnote : le VAULT_ADDR de ce poste est ignoré ; le pod vise %s\033[0m\n' "$V"
  fi
  POD="voie-a-probe-$$"
  OUT=$(mktemp)
  # Le fichier entier ($0) part en stdin du pod : kubectl y est absent (image
  # python:3.12-alpine + curl), donc le test `command -v kubectl` ci-dessus y
  # échoue et l'exécution tombe directement dans la section MODE POD plus bas
  # — pas besoin d'extraire un sous-ensemble du fichier ni de variable de
  # bascule. C'est aussi CE pod qui répond à l'étape 3 du brief (« lancer
  # depuis un agent Jenkins, pas seulement un pod quelconque ») : il porte
  # l'identité jenkins-agent du premier au dernier appel Vault, pas seulement
  # pour sys/health.
  if kubectl -n "$POD_NS" run "$POD" --rm -i --restart=Never \
        --image=python:3.12-alpine \
        --overrides='{"spec":{"serviceAccountName":"jenkins-agent"}}' \
        --env="VAULT_ADDR=$V" \
        --command -- sh -c 'apk add --no-cache curl >/dev/null 2>&1; cat > /tmp/t.sh && sh /tmp/t.sh' \
        < "$0" > "$OUT" 2>&1
  then :; fi
  cat "$OUT"
  PODLINE=$(grep '^__POD_RESULT__' "$OUT" | tail -1)
  rm -f "$OUT"
  if [ -n "$PODLINE" ]; then
    P=$(printf '%s' "$PODLINE" | awk '{print $2}')
    F=$(printf '%s' "$PODLINE" | awk '{print $3}')
    S=$(printf '%s' "$PODLINE" | awk '{print $4}')
    PASS=$((PASS+P)); FAIL=$((FAIL+F)); SKIP=$((SKIP+S))
  else
    bad "le pod de preuve n'a produit aucun résultat exploitable (kubectl run a-t-il échoué ?)"
  fi

  sec "7. CONTRE-ÉPREUVE — hachage (amendement A.1) : aucun {CLEARTEXT} dans l'annuaire"
  # PIÈGE MESURÉ : slapcat (et ldapsearch) rendent TOUJOURS userPassword en
  # base64 dans le LDIF, quel que soit le schéma stocké derrière — un
  # `grep '{CLEARTEXT}'` sur la sortie brute rend 0 même si tout est en clair.
  # La seule preuve valable est de décoder CHAQUE valeur et de lire son
  # PRÉFIXE réel. slapcat exige un exec DANS le conteneur openldap (ce n'est
  # pas un outil réseau) : c'est pourquoi cette contre-épreuve vit ici, en
  # mode orchestrateur, et pas dans le pod curl-only ci-dessus.
  HASHCHECK=$(kubectl -n "$NS" exec "$LDAP_DEPLOY" -- slapcat -o ldif-wrap=no 2>/dev/null \
    | python3 -c '
import sys, base64
total = 0; ssha = 0; bad = 0
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.startswith("userPassword:"):
        continue
    total += 1
    val = line.split(":", 1)[1].strip()
    if val.startswith(":"):        # "userPassword:: <b64>" — attribut LDIF encodé
        val = val[1:].strip()
    try:
        decoded = base64.b64decode(val)
    except Exception:
        bad += 1
        continue
    # décodage tronqué : les premiers octets suffisent pour lire le schéma,
    # jamais imprimé -- seul le VERDICT (conforme ou non) est retourné.
    if decoded[:6] == b"{SSHA}":
        ssha += 1
    else:
        bad += 1
print("%d %d %d" % (total, ssha, bad))
')
  T=$(printf '%s' "$HASHCHECK" | awk '{print $1}')
  OKN=$(printf '%s' "$HASHCHECK" | awk '{print $2}')
  BADN=$(printf '%s' "$HASHCHECK" | awk '{print $3}')
  if [ -z "$T" ] || [ "$T" -eq 0 ]; then
    bad "aucune entrée userPassword lue dans l'annuaire — slapcat a-t-il échoué (kubectl exec -n $NS $LDAP_DEPLOY) ?"
  elif [ "$BADN" -eq 0 ] && [ "$OKN" -eq "$T" ]; then
    ok "annuaire haché : $T entrée(s) userPassword, $OKN en {SSHA}, 0 en clair (préfixe décodé, pas grep sur le brut)"
  else
    bad "annuaire NON entièrement haché : $T entrée(s), $OKN en {SSHA}, $BADN non conforme(s) (préfixe réel décodé)"
  fi

  printf '\n\033[1mRÉSULTAT GLOBAL : %d réussis, %d échoués, %d sautés\033[0m\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# ════════════════════════════ MODE POD ═════════════════════════════════════
# (curl + python3 seulement, kubectl absent : soit ce fichier a été injecté
# directement dans un pod, soit il a été piped ici par le mode orchestrateur
# ci-dessus — les deux chemins produisent la même exécution.)
#
# Ici, et ici SEULEMENT, `VAULT_ADDR` est lu : dans un pod, c'est bien
# l'environnement qui porte l'adresse (posée par `--env` de l'orchestrateur, ou
# par le manifeste si ce fichier est injecté à la main). Le repli sur la valeur
# en dur couvre le cas d'une injection manuelle sans variable.
V="${VAULT_ADDR:-$VAULT_ADDR_IN_CLUSTER}"

# login <mount> <user> <password> -> imprime le jeton, ou rien ; code de retour = HTTP
login() {
  _m="$1"; _u="$2"; _p="$3"
  _body=$(python3 -c 'import json,sys; print(json.dumps({"password": sys.argv[1]}))' "$_p")
  _u_enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$_u")
  _out=$(printf '%s' "$_body" | curl -s -o /tmp/l.json -w '%{http_code}' -m 15 \
           -X POST --data-binary @- "$V/v1/auth/$_m/login/$_u_enc")
  if [ "$_out" = "200" ]; then
    python3 -c 'import json;print(json.load(open("/tmp/l.json"))["auth"]["client_token"])'
  fi
  rm -f /tmp/l.json
  echo "$_out" >/tmp/l.code
  [ "$_out" = "200" ]
}
lastcode() { cat /tmp/l.code 2>/dev/null; }

# vread <jeton> <chemin> -> code HTTP
vread() {
  curl -s -o /dev/null -w '%{http_code}' -m 15 -H "X-Vault-Token: $1" "$V/v1/$2"
}

sec "0. Vault joignable depuis ce pod"
C=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$V/v1/sys/health")
case "$C" in 200|429|472|473) ok "sys/health -> $C" ;; *) bad "sys/health -> $C (Vault injoignable)"; ;; esac

sec "0bis. Authentification par IDENTITÉ DE POD (amendement A.3) et lecture des mots de passe de démonstration"
# Casse la circularité : un mot de passe qui SERT à s'authentifier à Vault ne
# peut pas y être rangé pour son propre porteur ; mais un lecteur qui emprunte
# un AUTRE chemin d'authentification (ici : l'identité de compte de service du
# pod, via auth/kubernetes) peut l'y lire. alice et carol sont des personnes,
# sans identité de pod ; ce harnais en a une.
LAB_ALICE_PASS=""
LAB_CAROL_PASS=""
SA_JWT_FILE=/var/run/secrets/kubernetes.io/serviceaccount/token
if [ ! -r "$SA_JWT_FILE" ]; then
  bad "jeton de compte de service absent — ce pod a-t-il été lancé avec l'identité jenkins-agent ?"
else
  JWT=$(cat "$SA_JWT_FILE")
  KBODY=$(python3 -c 'import json,sys; print(json.dumps({"role": "jenkins-agent", "jwt": sys.argv[1]}))' "$JWT")
  KCODE=$(printf '%s' "$KBODY" | curl -s -o /tmp/k.json -w '%{http_code}' -m 15 \
            -X POST --data-binary @- "$V/v1/auth/kubernetes/login")
  if [ "$KCODE" = "200" ]; then
    ok "auth/kubernetes/login (jenkins-agent) -> 200 — chemin F1 (D1)"
    KTOK=$(python3 -c 'import json;print(json.load(open("/tmp/k.json"))["auth"]["client_token"])')
    rm -f /tmp/k.json
    ACODE=$(curl -s -o /tmp/a.json -w '%{http_code}' -m 15 -H "X-Vault-Token: $KTOK" "$V/v1/secret/data/ci/lab-users/alice")
    if [ "$ACODE" = "200" ]; then
      LAB_ALICE_PASS=$(python3 -c 'import json;print(json.load(open("/tmp/a.json"))["data"]["data"].get("password",""))')
      [ -n "$LAB_ALICE_PASS" ] && ok "mot de passe d'alice lu (secret/ci/lab-users/alice, ${#LAB_ALICE_PASS} caractères)" \
                               || bad "champ password absent de secret/ci/lab-users/alice"
    else
      bad "lecture secret/ci/lab-users/alice -> $ACODE"
    fi
    rm -f /tmp/a.json
    CCODE=$(curl -s -o /tmp/c.json -w '%{http_code}' -m 15 -H "X-Vault-Token: $KTOK" "$V/v1/secret/data/ci/lab-users/carol")
    if [ "$CCODE" = "200" ]; then
      LAB_CAROL_PASS=$(python3 -c 'import json;print(json.load(open("/tmp/c.json"))["data"]["data"].get("password",""))')
      [ -n "$LAB_CAROL_PASS" ] && ok "mot de passe de carol lu (secret/ci/lab-users/carol, ${#LAB_CAROL_PASS} caractères)" \
                               || bad "champ password absent de secret/ci/lab-users/carol"
    else
      bad "lecture secret/ci/lab-users/carol -> $CCODE"
    fi
    rm -f /tmp/c.json
    # Moindre privilège : ce jeton n'a servi qu'à lire deux mots de passe.
    curl -s -o /dev/null -m 15 -H "X-Vault-Token: $KTOK" -X POST "$V/v1/auth/token/revoke-self"
  else
    bad "auth/kubernetes/login (jenkins-agent) -> $KCODE — le rôle/la config kubernetes de Vault sont-ils en place (tâche 4) ?"
  fi
fi

sec "1. PORTE A — login nominatif par ldap, puis lecture d'un secret"
if [ -z "$LAB_ALICE_PASS" ]; then
  skip "alice — mot de passe introuvable via Vault (identité de pod)"
else
  TOK=$(login ldap alice "$LAB_ALICE_PASS") && ok "login ldap/alice -> 200" \
    || bad "login ldap/alice -> $(lastcode)"
  if [ -n "${TOK:-}" ]; then
    C=$(vread "$TOK" "secret/data/deploy/banking-demo/wm-admin")
    [ "$C" = "200" ] && ok "lecture wm-admin de banking-demo -> 200" \
                     || bad "lecture wm-admin -> $C (policy absente ?)"
  fi
fi

sec "2. CONTRE-ÉPREUVE — mauvais mot de passe : échec FERMÉ"
if [ -z "$LAB_ALICE_PASS" ]; then
  skip "mauvais mot de passe — mot de passe de référence d'alice indisponible"
elif login ldap alice "ceci-nest-pas-le-mot-de-passe"; then
  bad "un mauvais mot de passe a été ACCEPTÉ"
else
  C=$(lastcode)
  case "$C" in 400|401|403) ok "mauvais mot de passe -> $C, aucun jeton émis" ;;
               *) bad "mauvais mot de passe -> $C (attendu 400/401/403)" ;; esac
fi

sec "3. CONTRE-ÉPREUVE — cross-tenant : login OK, lecture 403"
# bob est un compte de DÉMONSTRATION dont le mot de passe est SCIEMMENT PUBLIC
# (il est en clair dans lab-vault-users.sh, dépôt public — c'est bien le mot de
# passe LDAP réel de bob, et c'est un choix, pas un oubli : risque borné, cf. le
# raisonnement complet au-dessus de LAB_BOB_PASS_METACHARS). D'où la valeur
# recopiée deux lignes plus bas, sans contradiction.
# Ce test prouve AUSSI que le corps JSON résiste aux guillemets, antislashs et
# dollars — et il le prouve sur un VRAI login qui doit rendre 200.
BOB_PW='B0b "q" \back $dollar '"'"'sq'"'"' ;semi &amp {brace}'
TOKB=$(login ldap bob "$BOB_PW") && ok "login ldap/bob -> 200 (mot de passe à métacaractères)" \
  || bad "login ldap/bob -> $(lastcode) — le corps JSON casse sur les métacaractères ?"
if [ -n "${TOKB:-}" ]; then
  C=$(vread "$TOKB" "secret/data/deploy/banking-demo/wm-admin")
  [ "$C" = "403" ] && ok "bob sur banking-demo -> 403 (ségrégation par policy)" \
                   || bad "bob sur banking-demo -> $C (ATTENDU 403 — fuite inter-tenant)"
  C=$(vread "$TOKB" "secret/data/deploy/payments-team/wm-admin")
  [ "$C" = "200" ] && ok "bob sur son propre tenant -> 200" \
                   || bad "bob sur payments-team -> $C"
fi

sec "4. CONTRE-ÉPREUVE — authentifié sans policy de déploiement"
if [ -z "$LAB_CAROL_PASS" ]; then
  skip "carol — mot de passe introuvable via Vault (identité de pod)"
else
  TOKC=$(login ldap carol "$LAB_CAROL_PASS") && ok "login ldap/carol -> 200" \
    || bad "login ldap/carol -> $(lastcode)"
  if [ -n "${TOKC:-}" ]; then
    C=$(vread "$TOKC" "secret/data/deploy/banking-demo/wm-admin")
    [ "$C" = "403" ] && ok "carol -> 403 (authentifiée n'est pas autorisée)" \
                     || bad "carol -> $C (ATTENDU 403)"
  fi
fi

sec "5. CONTRE-ÉPREUVE — jeton révoqué : la lecture cesse"
if [ -n "${TOK:-}" ]; then
  curl -s -o /dev/null -m 15 -H "X-Vault-Token: $TOK" -X POST "$V/v1/auth/token/revoke-self"
  C=$(vread "$TOK" "secret/data/deploy/banking-demo/wm-admin")
  [ "$C" = "403" ] && ok "jeton révoqué -> 403 (preuve de mort)" \
                   || bad "jeton révoqué -> $C (ATTENDU 403 — la révocation est cosmétique)"
else
  skip "révocation — pas de jeton d'alice"
fi

sec "6. CONTRE-ÉPREUVE — formats de login, et le piège userpass"
if [ -z "$LAB_ALICE_PASS" ]; then
  skip "formats — mot de passe d'alice indisponible"
else
  for U in 'CORP\alice' 'alice@corp.example'; do
    if login ldap "$U" "$LAB_ALICE_PASS" >/dev/null; then
      ok "ldap accepte le format $U"
    else
      C=$(lastcode)
      case "$C" in 400|401|403) ok "ldap atteint le bind pour $U (-> $C, l'annuaire ne connaît pas cet alias)" ;;
                   *) bad "ldap sur $U -> $C (attendu : la phase de bind est atteinte)" ;; esac
    fi
  done
  # Le piège : userpass REFUSE @ et \ au niveau du PATH, avant tout bind.
  login userpass 'alice@corp.example' "$LAB_ALICE_PASS" >/dev/null || true
  C=$(lastcode)
  case "$C" in 404|500) ok "userpass refuse l'UPN -> $C (le format contraint le backend)" ;;
               *) bad "userpass sur UPN -> $C (attendu 404/500)" ;; esac
fi

printf '\n\033[1mRÉSULTAT : %d réussis, %d échoués, %d sautés\033[0m\n' "$PASS" "$FAIL" "$SKIP"
printf '__POD_RESULT__ %d %d %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
