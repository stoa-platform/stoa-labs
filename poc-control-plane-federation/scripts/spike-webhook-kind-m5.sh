#!/usr/bin/env bash
# scripts/spike-webhook-kind-m5.sh — M5 (spec 2026-09-11 §9.1) : installer le
# SECOND récepteur de webhooks (gitlab-plugin) sur le Jenkins du lab, et prouver
# que le premier (generic-webhook-trigger) et les 59 autres plugins survivent.
# Sans ce pas, aucune preuve live du visage `gitlab` n'est possible — et le lab
# doit porter les DEUX récepteurs pour que la preuve soit rejouable.
#
# ⚠ REDÉMARRE le conteneur Jenkins (un plugin déposé n'est chargé qu'au boot).
#   Le script REFUSE de le faire si un build tourne ou si la file n'est pas vide.
#   Le redémarrage règle aussi le cache de parse Declarative (10 min) : la JVM
#   neuve ne porte aucun verdict périmé.
#
#   JENKINS_UI=http://localhost:18080 bash scripts/spike-webhook-kind-m5.sh
#
# Directives shellcheck : SC2015 `A && say … || say …` est un si-alors-sinon
# valide ici (say finit par printf, rc 0).
# shellcheck disable=SC2015
set -uo pipefail
J="${JENKINS_UI:-http://localhost:18080}"
C="${JENKINS_CONTAINER:-poc-jenkins}"
PLUGIN="${PLUGIN:-gitlab-plugin}"
OUT="${OUT:-/tmp}"
say(){ printf '%s\n' "$*"; }
# curl -g : sans lui les [] d'un `tree=` sont pris pour un glob d'URL (rc 3).
jget(){ curl -sg --max-time 30 "$@"; }
# python < 3.12 refuse un backslash dans l'expression d'une f-string : on
# formate en %-style, jamais en f"" imbriquée dans des quotes shell.
plugins(){ jget "$J/pluginManager/api/json?tree=plugins[shortName,version,active]" |
  python3 -c 'import sys,json;print("\n".join(sorted("%s %s %s" % (p["shortName"], p["version"], "true" if p["active"] else "false") for p in json.load(sys.stdin)["plugins"])))'; }

# ── 0. le lab est-il au repos ? un restart tuerait un build en vol ───────────
BUSY=$(jget "$J/api/json?tree=jobs[name,lastBuild[building]]" |
  python3 -c 'import sys,json;d=json.load(sys.stdin);print(" ".join(j["name"] for j in d["jobs"] if (j.get("lastBuild") or {}).get("building")))' 2>/dev/null || echo '?')
QUEUE=$(jget "$J/queue/api/json?tree=items[task[name]]" |
  python3 -c 'import sys,json;print(" ".join(i["task"]["name"] for i in json.load(sys.stdin)["items"]))' 2>/dev/null || echo '?')
[ -z "$BUSY" ] && [ -z "$QUEUE" ] || { say "!! REFUS: le lab travaille — builds en cours : [${BUSY:-aucun}], file : [${QUEUE:-vide}]. Un redémarrage les tuerait ; réessayer au repos."; exit 2; }
say "0. aucun build en cours, file vide — le redémarrage ne coupe rien"

# La photo d'AVANT est la référence de la non-régression : on ne l'écrit QUE si
# l'installation va avoir lieu. Sinon un second passage l'écraserait par l'état
# d'après, et la comparaison d'un run ultérieur serait VACANTE (vu le 2026-09-11).
plugins > "$OUT/spk-m5-etat.txt" || { say "!! /pluginManager illisible"; exit 2; }
N_AV=$(wc -l < "$OUT/spk-m5-etat.txt" | tr -d ' ')
grep -q "^$PLUGIN " "$OUT/spk-m5-etat.txt" && { say "1. '$PLUGIN' est DÉJÀ installé ($(grep "^$PLUGIN " "$OUT/spk-m5-etat.txt")) — rien à faire, la photo d'avant ($OUT/spk-m5-before.txt) est CONSERVÉE"; exit 0; }
mv "$OUT/spk-m5-etat.txt" "$OUT/spk-m5-before.txt"
say "1. avant : $N_AV plugins, '$PLUGIN' absent"

# ── 2. dépôt du plugin, puis redémarrage ─────────────────────────────────────
docker exec "$C" jenkins-plugin-cli --plugins "$PLUGIN" -d /var/jenkins_home/plugins > "$OUT/spk-m5-cli.log" 2>&1 \
  || { say "!! jenkins-plugin-cli en échec : $(tail -3 "$OUT/spk-m5-cli.log" | tr '\n' ' ')"; exit 1; }
say "2. déposé — journal de la CLI ($(awk 'END{print NR}' "$OUT/spk-m5-cli.log") lignes) : $OUT/spk-m5-cli.log"
docker restart "$C" > /dev/null || { say "!! docker restart $C en échec"; exit 1; }
for _ in $(seq 1 120); do jget -f -o /dev/null "$J/api/json" 2>/dev/null && break; sleep 2; done
jget -f -o /dev/null "$J/api/json" 2>/dev/null || { say "!! Jenkins ne répond plus après le redémarrage ($J)"; exit 1; }
say "3. Jenkins est revenu"

# ── 4. les DEUX récepteurs, et rien de cassé ─────────────────────────────────
plugins > "$OUT/spk-m5-after.txt"
RC=0
V=$(awk -v p="$PLUGIN" '$1==p {print $2" "$3}' "$OUT/spk-m5-after.txt")
case "$V" in *" true") say "M5 : '$PLUGIN' ${V% true} ACTIF" ;; *) say "M5 INATTENDU : '$PLUGIN' = [${V:-absent}]"; RC=1 ;; esac
V=$(awk '$1=="generic-webhook-trigger" {print $2" "$3}' "$OUT/spk-m5-after.txt")
case "$V" in *" true") say "M5 : generic-webhook-trigger ${V% true} INTACT (les deux récepteurs cohabitent)" ;; *) say "M5 INATTENDU : GWT = [${V:-absent}]"; RC=1 ;; esac
# Tout plugin déjà là doit être là, même version, toujours actif. Les ARRIVANTS
# (le plugin et ses dépendances) sont listés, jamais comptés comme une casse.
PERDUS=$(comm -23 "$OUT/spk-m5-before.txt" "$OUT/spk-m5-after.txt")
ARRIVES=$(comm -13 "$OUT/spk-m5-before.txt" "$OUT/spk-m5-after.txt" | awk '{print $1}' | tr '\n' ' ')
[ -z "$PERDUS" ] && say "M5 : aucun plugin préexistant modifié, désactivé ou perdu" || { say "M5 INATTENDU : modifiés/perdus →"; printf '   %s\n' "$PERDUS"; RC=1; }
say "M5 : arrivants (plugin + dépendances) : ${ARRIVES:-aucun} — $(wc -l < "$OUT/spk-m5-after.txt" | tr -d ' ') plugins au total"
# L'endpoint /project/<job> du GitLab Plugin exige la permission Item.BUILD
# quand useAuthenticatedEndpoint (global, défaut TRUE) est vrai ; ce lab est
# ouvert (useSecurity false), un client sécurisé aura besoin du secretToken.
CONF=$(docker exec "$C" sh -c 'cat /var/jenkins_home/com.dabsquared.gitlabjenkins.connection.GitLabConnectionConfig.xml 2>/dev/null' | tr -d '\n')
case "$CONF" in
  *useAuthenticatedEndpoint*false*) say "M5 : useAuthenticatedEndpoint = false (endpoint /project ouvert sur ce lab)" ;;
  *useAuthenticatedEndpoint*)       say "M5 : useAuthenticatedEndpoint = true (déclaré) — le secretToken est requis" ;;
  *)                                say "M5 : aucun GitLabConnectionConfig.xml — useAuthenticatedEndpoint au DÉFAUT (true) : le secretToken est requis" ;;
esac
[ "$RC" = 0 ] && say "RÉSULTAT M5 : le lab porte les deux récepteurs" || say "RÉSULTAT M5 : ÉCHEC"
exit "$RC"
