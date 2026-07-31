#!/bin/bash
# E1 / D2 — LECTURE SEULE. De quoi est fait le privilege des accessProfiles ?
# Le bitmask des teams de demo a ete COPIE de API-Gateway-Providers sans etre
# decompose (cf. f4-teams-bootstrap.sh). On ne peut pas retirer « creation d'API »
# a une equipe sans savoir quel bit la porte, ni ce que le meme bit porte d'autre.
set -eu
umask 077
# Mot de passe d'administration : fichier root-only du noeud, jamais dans ce
# depot (public) ni en argv (curl -K - : la config passe par stdin).
. /root/f4-teams.env
ADMPW="${WM_ADMIN_PW:-}"
[ -n "$ADMPW" ] || { echo "!! WM_ADMIN_PW absent de /root/f4-teams.env — l'y ajouter (fichier 0600, root)"; exit 1; }
KX="k3s kubectl -n ci exec -i deploy/jenkins --"
B="http://wm-apigateway-admin.wm.svc:5555/rest/apigateway"

get() {
  {
    printf 'url = "%s%s"\n' "$B" "$1"
    printf 'user = "Administrator:%s"\n' "$ADMPW"
    printf 'header = "Accept: application/json"\n'
    printf 'silent\n'
  } | $KX curl -K - 2>/dev/null
}

echo "=== accessProfiles : nom / longueur du bitmask / bitmask ==="
get "/accessProfiles" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ps=d.get("accessProfiles") or d.get("accessProfile") or []
if isinstance(ps,dict): ps=[ps]
rows=[]
for p in ps:
    rows.append((p.get("name"), p.get("privilege") or "", p.get("id")))
for n,pr,i in rows:
    print("%-28s len=%-4s %s" % (n, len(str(pr)), pr))
print()
# comparaison bit a bit entre les profils de demo et le profil systeme
byname={n:str(pr) for n,pr,_ in rows}
sysname=None
for cand in ("API-Gateway-Providers","API Gateway Providers","APIGatewayProviders"):
    if cand in byname: sysname=cand; break
if sysname:
    ref=byname[sysname]
    for n,pr,_ in rows:
        pr=str(pr)
        if n==sysname or not pr: continue
        if len(pr)!=len(ref):
            print("%-28s longueur differente de %s (%d vs %d)" % (n,sysname,len(pr),len(ref)))
            continue
        diff=[k for k,(a,b) in enumerate(zip(pr,ref)) if a!=b]
        print("%-28s bits differents de %s : %s" % (n,sysname,diff or "AUCUN (copie exacte)"))
else:
    print("(profil systeme API-Gateway-Providers introuvable dans la liste)")
'

echo
echo "=== y a-t-il un endpoint qui NOMME les privileges ? ==="
for p in /accessProfiles/privileges /privileges /permissions /accessProfiles/permissions; do
  {
    printf 'url = "%s%s"\n' "$B" "$p"
    printf 'user = "Administrator:%s"\n' "$ADMPW"
    printf 'header = "Accept: application/json"\n'
    printf 'silent\n'
    printf 'output = /dev/null\n'
    printf 'write-out = "%s -> %%{http_code}\\n"\n' "$p"
  } | $KX curl -K - 2>/dev/null
done

echo
echo "=== si l'un repond 200, son contenu (tronque) ==="
for p in /accessProfiles/privileges /privileges /permissions; do
  out=$(get "$p" 2>/dev/null || true)
  case "$out" in
    '{"'*|'['*) echo "--- $p ---"; printf '%s' "$out" | head -c 1200; echo ;;
  esac
done
