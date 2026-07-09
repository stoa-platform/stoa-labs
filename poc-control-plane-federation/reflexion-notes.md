# Reflexion notes — diagnostic des sessions Claude Code (poc-control-plane-federation)

Analyse du 2026-07-03 sur 14 transcripts (~35 MB, 10 juin → 3 juil 2026) dans
`~/.claude/projects/-Users-torpedo-hlfh-repos-stoa-labs-poc-control-plane-federation/`.
(Le chemin `C--User--Chase` du prompt n'existe pas — substitution assumée par le répertoire du projet courant.)

Sessions citées par préfixe court : `ffe1` (11-12/06, analytics+onboarding+Vault), `46e4` (01-03/07, ADR-076 GitOps+mTLS),
`68fe` (12-19/06, CI multi-env ADR-075), `2ead` (12/06, OTel/Tempo wM), `0821` (12/06, TokenProvider Vault wM),
`c1dc` (12/06, stoa-gateway Rust), `9d15` (09/06, deep review), `8bfa` (09-12/06, ADR reuse-first), `a649` (02/07, SAML SLO OAM),
`e7cc` (02/07, registry wM), `4985` (13/06, cron keepalive), `259a`/`0b6c` (triviales).

Diagnostic uniquement — rien n'a été construit ni modifié. Classement par levier décroissant.

---

## 1. FIX — Créer un `CLAUDE.md` projet (carte d'environnement + discipline de preuve)

**Verdict : fix, coût quasi nul, levier maximal.** Le repo n'a **aucun** CLAUDE.md, aucun skill, aucun hook.

**Évidence — friction n°1 toutes sessions confondues : « je ne vois pas ta preuve ».**
- `ffe1` : 8+ demandes de preuve (« je veux bien voir ton test », « je ne vois pas les index », « je vois rien dans git ni dans osearch », « teste vraiment avant de crier victoire », « tu as tout testé de bout en bout ? »).
- `46e4` : 3 défis explicites (« je ne vois pas les jobs jenkins qui ont tourné pour tes tests », « pkoi je ne vois pas les stages », « je ne vois pas d'api sur le port https, comment tu as fait le test ? »).
- `2ead` : 2 corrections consécutives (« j'ai aucune trace », « je n'ai qu'un span ? »).
- `0821` : « tout doit être debugable via la gateway sans intervenir sur l'IS ».

**Évidence — faits d'environnement réappris à chaque session :**
- Confusion port 5555 (admin IS) vs 9073/19072 (gateway UI) corrigée par l'utilisateur (`ffe1`) ; port 5543 HTTPS déjà existant → doublon 5544 créé puis signalé par l'utilisateur (`46e4`).
- Boilerplate re-répété : `A='-u Administrator:manage'` (`46e4`), parser INI awk `get()` ×5 verbatim (`ffe1`), `cd` de préfixe ×120+ (`46e4`), ×30 (`68fe`), ×17 vers stoa-docs (`8bfa`) — « Shell cwd was reset » ×17.
- Identité git inline `git -c user.name -c user.email` sur ~15 commits / 59 usages (`46e4`).
- Relances manuelles identiques après workflows background : « Reprends le workflow X — synthétise » ×3 (`46e4`), ×2 (`c1dc`), re-collages (`0821`).

**Contenu proposé :** carte des ports/URLs/credentials-lab (5555 admin, 19072 UI, 5543 mTLS, 9180 APISIX, 18080 Jenkins, 9201 OpenSearch, 8200 Vault, 13000 Gitea), inventaire `scripts/`, règle « toute affirmation de succès s'accompagne d'un artefact vérifiable par l'utilisateur (URL de build, commande curl rejouable, capture, lien dashboard) », « synthétiser spontanément les workflows background terminés », chemins absolus plutôt que `cd`, identité git, wm-keepalive/pause knob.

---

## 2. SKILL — `wm-admin` : administration webMethods 10.15 par REST (+ script compagnon)

**Verdict : skill projet. Récurrence massive (5 sessions), coût moyen.** Seul candidat qui justifie vraiment un skill.

**Évidence :**
- `2ead` : 52 curls `:5555`, ~25 CRUD policyActions, schémas découverts à l'aveugle (« unknown parameter: customDestinationName » ×2, « Required parameter missing: endpointUri » ×2), fallback en automation navigateur (24 clicks) quand le REST refuse (`customDestinations` access denied).
- `0821` : ≥10 itérations du rituel PUT policyAction → deactivate/activate → invoke → fouille server.log ; gateway wedged ×2 (health=000 ×6).
- `68fe` : ~103 curls dont policyActions ×10, probe alias ×12, rondes GET→mutate→re-GET.
- `46e4` : 39 hits endpoints (`ports` ×17…), 37 `docker exec` de spéléologie dans /opt/softwareag, matrice de tests mTLS rejouée à chaque flip de port.
- `ffe1` : 15 curls admin + boucle PolicyViolation ×10.
- La mémoire `wm-1015-rest-shapes.md` capitalise déjà une partie des shapes — un skill la rendrait opérationnelle (recettes curl prêtes, JSON policyActions valides, rituel activate/deactivate, pièges trial).
- Hygiène : `Administrator:manage` en clair sur des centaines de lignes de commande (l'utilisateur a déjà repéré des tokens en clair dans les logs Jenkins, `ffe1`).

**Contenu proposé :** SKILL.md avec endpoints + shapes JSON validés (policyActions, applications, aliases, ports), le cycle policy-edit→activate→test, les pièges 10.15 (settings perdus au recreate, restart requis pour clientAuth) + un `scripts/wm-admin.sh` (creds via env/Vault, sous-commandes list/get/put/activate/invoke).

---

## 3. AUTOMATION — `scripts/jenkins-build-and-wait.sh`

**Verdict : automation, coût très faible, ~30 boucles artisanales économisées.**

**Évidence :**
- `46e4` : ~120 commandes liées à Jenkins ; 11 déclenchements ; danse crumb+cookie-jar ×4 ; poll `lastBuild/api/json` + consoleText ×11 ; 29 mentions FAILURE avant convergence ; 2 restarts avec readiness `for i in $(seq 1 40)`.
- `68fe` : rituel webhook `/generic-webhook-trigger/invoke` → `until … sleep 10` → grep consoleText répété ~15×.
- `ffe1` : ≥7 trigger+wait (inline + background).

**Contenu proposé :** trigger (webhook ou POST+crumb) → poll → sortie = résultat + URL du build + queue des stages + extrait console. La sortie « URL de build » répond aussi directement à la friction n°1 (preuve visible).

---

## 4. FIX — TTL du secret_id AppRole Vault (tuer le rituel de re-provisioning)

**Verdict : fix de config lab, pas de nouvel outillage.**

**Évidence :**
- `68fe` : `vault approle login failed` ×13 (TTL secret_id ~10 min) ; `jenkins-refresh-vault-secret` mentionné ×18 ; contournement institutionnalisé « lancer le refresh avant chaque session de build ».
- `ffe1` : `setup-vault-approle.sh` relancé ×8 (itéré jusqu'à idempotence).
- `46e4` : setup-vault.sh + setup-vault-approle.sh ×9 cumulés après chaque changement de policy.

**Proposé :** pour le lab, allonger `secret_id_ttl`/`secret_id_num_uses` (ou wrapper le refresh dans l'init Jenkins), et rendre les scripts setup idempotents par défaut. Trancher une fois, documenter dans CLAUDE.md.

---

## 5. FIX — Rationaliser l'allowlist de permissions (via le skill intégré `fewer-permission-prompts`)

**Verdict : fix, coût quasi nul (skill existant à exécuter).**

**Évidence :**
- `.claude/settings.local.json` : 73 entrées allow, presque toutes des commandes littérales one-shot (URLs complètes, one-liners python figés) — inutilisables comme patterns.
- Frictions récurrentes : « directory denied by permission settings » ×3 (`ffe1`), deny `.env` forçant un contournement hardcodé + édition manuelle par l'utilisateur (`9d15`), `mv` refusé (`46e4`).
- Cibles évidentes de patterns : `curl localhost:{5555,9180,18080,9201,8200,13000}`, `./scripts/*.sh`, `docker exec poc-*`, `go build/test` vendored.

---

## 6. FIX (micro) — Défauts de session : `/effort ultracode` et identité git

**Évidence :**
- `/effort ultracode` (+/model) tapé en ouverture dans 6+ sessions (`68fe`, `9d15`, `a649`, `4985`, `0b6c`, `259a`, + les 3 du 12/06).
- Identité git inline ×59 (`46e4`) : un `git config` (ou includeIf sur ~/hlfh-repos) dans les clones accounts-team/Gitea.

**Verdict : deux réglages one-shot ; à faire, mais gain unitaire faible.**

---

## 7. AUTOMATION (mineure) — `scripts/gitea-sync.sh`

**Évidence :** `ffe1` uniquement, mais bloc clone→copy→commit→push répété ×5-7 et la staleness du miroir a **causé** la régression APISIX openid-connect (route écrasée, 3 Monitors, 3 refus d'auto-heal). Une session seulement → script simple, pas de skill.

---

## 8. RIEN À CONSTRUIRE (constats assumés)

- **Keepalive wM trial** : déjà résolu (`4985` : cron uptime-anchored + `restart-wm.sh` + pause knob). Juste à documenter dans CLAUDE.md.
- **SAML/OAM en environnement client verrouillé** (`a649`) : friction sévère mais one-off, externe au setup (pas d'install, pas d'internet, exfil mail bloquée). Rien d'automatisable ici.
- **Registry webMethods UNAUTHORIZED ×7** (`e7cc`) : blocage d'entitlement produit, externe.
- **Consommation quota** (`0821` : pause 2h10 mi-tâche après ~5M tokens de subagents le matin ; `ffe1` : « lance-le dans 2:10 ») : choix d'usage (workflows massifs), pas un défaut de setup — au plus, réserver ultracode aux sessions qui le justifient.
- **`sleep N && cmd` bloqué par la sandbox** ×3 (`2ead`, `0821`, `c1dc`) : friction harness, le modèle bascule déjà sur Monitor/background ; rien à construire.

---

*Prochaine étape suggérée (hors de ce diagnostic) : items 1+5+6 en une passe (~30 min), puis 3 (script Jenkins), puis 2 (skill wm-admin), puis 4 (Vault TTL).*
