#!/usr/bin/env bash
# test-cert-format.sh — preuve X/X : le rôle accepte le certificat en PEM ET en
# DER BINAIRE, et les deux formats donnent la MÊME identité sur la gateway.
#
# POURQUOI. Les exports Windows proposent « Base-64 encoded X.509 » et « DER
# encoded binary X.509 ». Le second — souvent le défaut, et l'extension `.cer`
# usuelle chez le client — n'est pas du texte et n'a pas de bloc BEGIN
# CERTIFICATE : le rôle le refusait en CERT_INVALID alors que c'est un
# certificat public valide.
#
# Ne pas confondre avec l'encodage de TRANSPORT : ce que la gateway stocke reste
# le base64 du DER dans les deux cas. C'est le FICHIER SOURCE qui peut être
# binaire. Le cas 3 le prouve en comparant les empreintes.
#
# HORS LIGNE : réutilise la sonde ansible/test-cert-path.yml (resolve-env +
# cert-der), sans gateway, sans Vault, sans secret.
#
#   ./scripts/test-cert-format.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/certfmt.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
ko(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

command -v ansible-playbook >/dev/null || { echo "ansible-playbook absent"; exit 2; }

echo "== jeu de fichiers (même certificat, formats différents) =="
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -days 365 \
  -subj "/CN=probe-cert-format" -out "$TMP/cert.pem" 2>/dev/null
openssl x509 -in "$TMP/cert.pem" -outform DER -out "$TMP/cert.cer" 2>/dev/null   # DER binaire
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -days 365 \
  -subj "/CN=probe-intermediate" -out "$TMP/inter.pem" 2>/dev/null
cat "$TMP/cert.pem" "$TMP/inter.pem" > "$TMP/chain.pem"                          # PEM en CHAÎNE
{ printf 'Bag Attributes\n    friendlyName: probe\nsubject=/CN=probe-cert-format\n';
  cat "$TMP/cert.pem"; } > "$TMP/bagattr.pem"                                    # en-tête texte
cat "$TMP/cert.pem" "$TMP/key.pem" > "$TMP/withkey.pem"                          # cert + CLÉ PRIVÉE
head -c 200 "$TMP/cert.cer" > "$TMP/truncated.cer"                               # DER tronqué
printf 'ceci nest pas un certificat\n' > "$TMP/garbage.pem"
file "$TMP/cert.cer" | sed 's/^/  /'

mkmanifest(){ cat > "$TMP/m.yml" <<EOF
apim_ss_app:
  name: "probe-cert-format"
  api: "probe"
  api_version: "1.0.0"
  description: "sonde format de certificat"
  contact_emails: []
  team: "banking-demo"
  enforce: ["httpsCertificate"]
  backend: { header: "", value_template: "" }
  public_cert_ref: "$1"
EOF
}

probe(){ mkmanifest "$1"
  OUT="$(cd "$REPO" && ansible-playbook -i localhost, ansible/test-cert-path.yml \
        -e "apim_ss_manifest=$TMP/m.yml" 2>&1)"; RC=$?
  SHA="$(grep -o 'der_sha=[0-9a-f]*' <<<"$OUT" | head -1 | cut -d= -f2)"
}

echo
echo "== 1. PEM classique (non-régression) =="
probe "$TMP/cert.pem"
[ $RC -eq 0 ] && ok "accepté" || ko "PEM refusé (rc=$RC)"
grep -q "inform=PEM" <<<"$OUT" && ok "format détecté : PEM" || ko "mauvaise détection"
SHA_PEM="$SHA"

echo
echo "== 2. DER BINAIRE (.cer export Windows) — le correctif =="
probe "$TMP/cert.cer"
[ $RC -eq 0 ] && ok "accepté" || ko "DER binaire refusé (rc=$RC) — correctif absent"
grep -q "inform=DER" <<<"$OUT" && ok "format détecté : DER" || ko "mauvaise détection"
SHA_DER="$SHA"

echo
echo "== 3. Les deux formats posent la MÊME valeur sur la gateway =="
[ -n "$SHA_PEM" ] && [ "$SHA_PEM" = "$SHA_DER" ] \
  && ok "empreintes identiques ($SHA_PEM)" \
  || ko "identités différentes : PEM=$SHA_PEM DER=$SHA_DER"

echo
echo "== 4. PEM en CHAÎNE : seul le leaf est posé (non-régression) =="
probe "$TMP/chain.pem"
[ $RC -eq 0 ] && [ "$SHA" = "$SHA_PEM" ] \
  && ok "leaf seul, valeur inchangée" || ko "chaîne concaténée ou refusée (rc=$RC)"

echo
echo "== 5. PEM à en-tête texte (Bag Attributes) : ignoré (non-régression) =="
probe "$TMP/bagattr.pem"
[ $RC -eq 0 ] && [ "$SHA" = "$SHA_PEM" ] \
  && ok "en-tête ignoré, valeur inchangée" || ko "en-tête happé ou fichier refusé (rc=$RC)"

echo
echo "== 6. CLÉ PRIVÉE dans le PEM : refusée (ADR-071) =="
probe "$TMP/withkey.pem"
[ $RC -ne 0 ] && ok "refusé" || ko "clé privée acceptée — ADR-071 violé"
# On matche le TEXTE DU REFUS, pas « clé privée » : ce fragment apparaît aussi
# dans le NOM de la tâche, y compris quand elle est SAUTÉE. Le premier jet du
# test passait ainsi au vert alors que la garde ne s'exécutait pas du tout.
grep -q "publicCertRef porte une clé privée" <<<"$OUT" \
  && ok "refus explicite (garde réellement exécutée)" || ko "la garde ADR-071 n'a pas parlé"

echo
echo "== 7. DER TRONQUÉ : refusé avec un diagnostic lisible =="
probe "$TMP/truncated.cer"
[ $RC -ne 0 ] && ok "refusé" || ko "DER corrompu accepté"
grep -q "CERT_INVALID" <<<"$OUT" && ok "CERT_INVALID (pas l'erreur brute d'openssl)" || ko "diagnostic illisible"

echo
echo "== 8. Fichier quelconque : refusé =="
probe "$TMP/garbage.pem"
[ $RC -ne 0 ] && grep -q "CERT_INVALID" <<<"$OUT" \
  && ok "CERT_INVALID" || ko "fichier non-certificat accepté"

echo
echo "======================================================================"
printf 'RÉSULTAT : %d/%d\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || { echo "--- dernière sortie ansible ---"; echo "$OUT"; exit 1; }
