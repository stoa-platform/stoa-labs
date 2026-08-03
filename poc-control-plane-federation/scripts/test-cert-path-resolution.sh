#!/usr/bin/env bash
# test-cert-path-resolution.sh — preuve X/X de la résolution de `public_cert_ref`
# (rôle apim_selfservice_app). HORS LIGNE : ni gateway, ni Vault, ni secret.
#
# CE QU'ON PROUVE. Un chemin RELATIF est cherché dans deux bases, dans l'ordre :
# la racine du dépôt (comme apim_ss_manifest), PUIS le dossier du manifeste. La
# seconde base est le correctif du 2026-08-03 : un ops qui pose le .crt À CÔTÉ de
# la définition de son application — ce que font le moteur Go (targets/load.go)
# et l'ADR-071 — se prenait un CERT_NOT_FOUND. La première base est conservée
# EN PREMIER : les manifestes existants (tous en repo-relatif) doivent résoudre
# exactement comme avant, ce que le cas 7 mesure sur un manifeste RÉEL du dépôt.
#
#   ./scripts/test-cert-path-resolution.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/certpath.XXXXXX)"
AMBIG="$REPO/probe-ambiguous.crt"          # base n°1 (racine du dépôt), jetable
trap 'rm -rf "$TMP" "$AMBIG"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

command -v ansible-playbook >/dev/null || { echo "ansible-playbook absent"; exit 2; }

echo "== certificats jetables =="
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -days 365 \
  -subj "/CN=probe-cert-path-A" -out "$TMP/probe-client.crt" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -days 365 \
  -subj "/CN=probe-cert-path-B-different" -out "$TMP/probe-ambiguous.crt" 2>/dev/null
echo "  A=$TMP/probe-client.crt  B=$TMP/probe-ambiguous.crt"

# Manifeste mono-env minimal : seule l'identité du certificat nous intéresse.
mkmanifest(){ # $1=fichier de sortie  $2=public_cert_ref
cat > "$1" <<EOF
apim_ss_app:
  name: "probe-cert-path"
  api: "probe"
  api_version: "1.0.0"
  description: "sonde hors ligne — résolution de public_cert_ref"
  contact_emails: []
  team: "banking-demo"
  enforce: ["httpsCertificate"]
  backend: { header: "", value_template: "" }
  public_cert_ref: "$2"
EOF
}

# Lance la sonde ; sortie complète dans $OUT, code retour dans $RC.
probe(){ # $1=apim_ss_manifest  [$2=apim_ss_env]
  OUT="$(cd "$REPO" && ansible-playbook -i localhost, ansible/test-cert-path.yml \
        -e "apim_ss_manifest=$1" ${2:+-e "apim_ss_env=$2"} 2>&1)"
  RC=$?
}

echo
echo "== 1. chemin RELATIF résolu depuis la RACINE DU DÉPÔT (comportement historique) =="
mkmanifest "$TMP/m-repo.yml" "clients/_example/applications/demo-client.crt"
probe "$TMP/m-repo.yml"
[ $RC -eq 0 ] && grep -q "PROBE_OK" <<<"$OUT" \
  && ok "résolu et ré-encodé" || ko "échec inattendu (rc=$RC)"
grep -q "base = racine du dépôt" <<<"$OUT" \
  && ok "base annoncée : racine du dépôt" || ko "base non annoncée / mauvaise base"

echo
echo "== 2. chemin RELATIF résolu depuis le DOSSIER DU MANIFESTE (le correctif) =="
mkmanifest "$TMP/m-side.yml" "probe-client.crt"
probe "$TMP/m-side.yml"
[ $RC -eq 0 ] && grep -q "PROBE_OK" <<<"$OUT" \
  && ok "cert posé à côté du manifeste : trouvé" || ko "CERT_NOT_FOUND — correctif absent (rc=$RC)"
grep -q "base = dossier du manifeste" <<<"$OUT" \
  && ok "base annoncée : dossier du manifeste" || ko "base non annoncée / mauvaise base"

echo
echo "== 3. chemin ABSOLU pris tel quel =="
mkmanifest "$TMP/m-abs.yml" "$TMP/probe-client.crt"
probe "$TMP/m-abs.yml"
[ $RC -eq 0 ] && grep -q "base = chemin absolu" <<<"$OUT" \
  && ok "absolu inchangé" || ko "absolu cassé (rc=$RC)"

echo
echo "== 4. FAIL-CLOSED : introuvable, et le message NOMME LES DEUX bases =="
mkmanifest "$TMP/m-nope.yml" "il-nexiste-pas.crt"
probe "$TMP/m-nope.yml"
[ $RC -ne 0 ] && ok "échec (fail-closed)" || ko "a convergé sur un certificat absent"
grep -q "CERT_NOT_FOUND" <<<"$OUT" && ok "CERT_NOT_FOUND" || ko "code d'erreur absent"
grep -q "il-nexiste-pas.crt |.*il-nexiste-pas.crt" <<<"$OUT" \
  && ok "les DEUX chemins essayés sont affichés" || ko "message n'affiche pas les deux bases"

echo
echo "== 5. FAIL-CLOSED : même nom dans les deux bases, contenus DIFFÉRENTS =="
cp "$TMP/probe-ambiguous.crt" "$AMBIG"          # racine du dépôt : cert B
cp "$TMP/probe-client.crt" "$TMP/probe-ambiguous.crt"   # dossier manifeste : cert A
mkmanifest "$TMP/m-ambig.yml" "probe-ambiguous.crt"
probe "$TMP/m-ambig.yml"
[ $RC -ne 0 ] && ok "échec (fail-closed)" || ko "a choisi en silence entre deux identités"
grep -q "CERT_PATH_AMBIGUOUS" <<<"$OUT" && ok "CERT_PATH_AMBIGUOUS" || ko "code d'erreur absent"

echo
echo "== 6. même nom dans les deux bases mais MÊME contenu : pas une ambiguïté =="
cp "$TMP/probe-client.crt" "$AMBIG"
probe "$TMP/m-ambig.yml"
[ $RC -eq 0 ] && grep -q "PROBE_OK" <<<"$OUT" \
  && ok "converge (empreintes identiques)" || ko "refus abusif (rc=$RC)"
rm -f "$AMBIG"

echo
echo "== 7. NON-RÉGRESSION : manifeste RÉEL du dépôt (per_env, repo-relatif) =="
probe "clients/_example/applications/demo-consumer-cert.ansible.yml" "dev"
[ $RC -eq 0 ] && grep -q "PROBE_OK" <<<"$OUT" \
  && ok "demo-consumer-cert (env dev) résout" || ko "RÉGRESSION sur un manifeste existant (rc=$RC)"
grep -q "base = racine du dépôt" <<<"$OUT" \
  && ok "toujours résolu depuis la racine (base inchangée)" || ko "la base a changé pour un manifeste existant"

echo
echo "== 8. manifeste SANS certificat : la sonde passe (identité par IP seule) =="
# Le stage PLAN du Jenkinsfile lance la sonde sur TOUTE demande, y compris celles
# qui n'opposent qu'une plage IP. Sans ce comportement, le PLAN refuserait des
# demandes valides — le manifeste par défaut du pipeline (demo-consumer) en est une.
mkmanifest "$TMP/m-nocert.yml" ""
probe "$TMP/m-nocert.yml"
[ $RC -eq 0 ] && ok "rc=0 (pas d'échec sur une demande sans cert)" || ko "la sonde échoue sans certificat (rc=$RC)"
grep -q "PROBE_SKIP" <<<"$OUT" && ok "PROBE_SKIP annoncé" || ko "sortie muette sur le cas sans certificat"

echo
echo "== 9. le manifeste PAR DÉFAUT du pipeline passe le PLAN =="
probe "clients/_example/applications/demo-consumer.ansible.yml" "dev"
[ $RC -eq 0 ] && ok "demo-consumer (défaut du Jenkinsfile) : PLAN vert" || ko "le PLAN refuserait le manifeste par défaut (rc=$RC)"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || { echo "--- dernière sortie ansible ---"; echo "$OUT"; exit 1; }
