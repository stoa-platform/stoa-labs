# Makefile — build & release des binaires Go du PoC (É0, DELIVERY-PROCESS.md §4).
#
#   make build     binaire labctl natif dans labctl/bin/ (confort dev, untracked)
#   make test      suite Go complète, air-gapped (GOPROXY=off, -mod=vendor)
#   make release   dist/<version>/ : binaires MULTI-ARCH versionnés (ldflags -X)
#                  + SHA256SUMS + SBOM SPDX — le tout SANS réseau (vendor/).
#   make lint-ci   les portes de la chaîne CI : compilation des Jenkinsfile,
#                  shellcheck des bibliothèques, épreuves de carto-secrets, du
#                  résolveur de pin et du préflight de joignabilité.
#
# Principe livrable (DELIVERY-PROCESS §4) : la release se construit HORS ZONE ;
# l'agent Jenkins du client reçoit CES binaires + checksums + SBOM, jamais le
# toolchain Go. linux/amd64 est le minimum contractuel ; la matrice est un knob.

VERSION         ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.1.0-poc)
# Binaires livrables : labctl (moteur gateway) + les deux APIs de gouvernance.
# (itsm-mock reste un mock de démo, jamais livré.)
BINARIES        ?= labctl governance-api onboarding-api
RELEASE_TARGETS ?= linux/amd64 linux/arm64 darwin/arm64
DIST            := dist/$(VERSION)
GOENV           := CGO_ENABLED=0 GOPROXY=off GOFLAGS=-mod=vendor GOSUMDB=off
# -X : la version injectée est visible via `labctl version` (cmd/labctl.Version) ;
# l'entrée est ignorée silencieusement par les binaires qui ne lient pas ce paquet.
LDFLAGS         := -s -w -X github.com/stoa-platform/stoa-labs/poc/labctl/cmd/labctl.Version=$(VERSION)

# ── Images trial webMethods : sauvegarde HORS store Docker ───────────────────
# Ces images ne sont PAS reconstructibles : les trial `softwareag/*` de Docker
# Hub peuvent disparaître (rachat IBM) et les `ibmwebmethods.azurecr.io/*`
# exigent un token ACR valide. Docker n'a AUCUN mécanisme de pin/lock : un
# `docker system prune -a` ou un "Purge data" de Docker Desktop les efface.
# D'où ces tarballs, seule garantie réelle.
#
# NB : `docker logout` n'y touche PAS — il ne vide que le Keychain. Les images
# du store local sont indépendantes des credentials.
#
# Destination HORS de tout dépôt git, volontairement (~8 Go : jamais dans Git).
IMAGES_BACKUP ?= $(HOME)/wm-trial-images
TRIAL_IMAGES  ?= ibmwebmethods.azurecr.io/apigateway:11.1 \
                 ibmwebmethods.azurecr.io/devportal:11.1 \
                 softwareag/apigateway-trial:10.15 \
                 softwareag/devportal:10.15

.PHONY: build test release clean lint-ci images-save images-restore images-check

build:
	cd labctl && $(GOENV) go build -trimpath -ldflags "$(LDFLAGS)" -o bin/labctl .

test:
	cd labctl && $(GOENV) go test ./...

release:
	@rm -rf "$(DIST)" && mkdir -p "$(DIST)"
	@set -e; cd labctl; \
	for tgt in $(RELEASE_TARGETS); do \
	  os=$${tgt%/*}; arch=$${tgt#*/}; \
	  for bin in $(BINARIES); do \
	    case "$$bin" in labctl) pkg=. ;; *) pkg=./cmd/$$bin ;; esac; \
	    out="../$(DIST)/$${bin}_$(VERSION)_$${os}_$${arch}"; \
	    echo ">> build $$out"; \
	    $(GOENV) GOOS=$$os GOARCH=$$arch go build -trimpath -ldflags "$(LDFLAGS)" -o "$$out" "$$pkg"; \
	  done; \
	done
	@./scripts/release-sbom.sh "$(VERSION)" "$(DIST)/stoa-poc-binaries-$(VERSION).spdx.json"
	@# Checksums (binaires + SBOM), vérifiables côté client par `sha256sum -c`.
	@# NB : la redirection crée SHA256SUMS AVANT l'expansion du glob — il faut
	@# donc l'exclure explicitement, sinon il se référence lui-même et -c échoue.
	@cd "$(DIST)" && ls | grep -v '^SHA256SUMS$$' \
	  | xargs $$(command -v sha256sum >/dev/null && echo sha256sum || echo 'shasum -a 256') > SHA256SUMS
	@echo "== release $(VERSION) -> $(DIST)"; ls -1 "$(DIST)"

clean:
	rm -rf dist labctl/bin

# ── Portes de la chaîne CI ───────────────────────────────────────────────────
# Rien ne compilait les Jenkinsfile jusqu'ici : un fichier qui ne parse plus ne
# se voyait qu'à l'exécution, c'est-à-dire la nuit suivante sur un job planifié.
# C'est arrivé deux fois (2026-08-07 échappement `\w` en chaîne Groovy,
# 2026-08-26 chemin de `source` faux). Les deux portes sont COMPLÉMENTAIRES :
# la première lit la SYNTAXE, la seconde le COMPORTEMENT — la seconde seule
# attrape un chemin faux, qui parse parfaitement.
#
# `shellcheck` est lancé AU DIALECTE DU SHEBANG (jamais `-s sh`) : les libs
# déclarent bash et usent de `local`, que `-s sh` noie sous 14 SC3043. Et avec
# `-x`, qui SUIT les `source` : sans lui, un script qui en source un autre rend
# un SC1091 (info) et la porte échoue sur une non-trouvaille, pas sur un défaut.
#
# ⚠ LE PÉRIMÈTRE N'EST PAS `ci/lib`, C'EST « TOUT LE SHELL QUI PART CHEZ LE
# CLIENT ». Les trois livrables de G3 — résolveur de pin, chaîne
# d'environnements, écrivain de promotion — vivent sous `scripts/` et sont
# restés hors porte jusqu'ici : du shell livré que rien ne relisait.
lint-ci:
	@echo "== [1/20] compilation des Jenkinsfile"
	@ci/lint-jenkinsfiles.sh
	@# La porte LIVE du grant déployeur (G2) est SHELLCHECKÉE ici mais jamais
	@# EXÉCUTÉE par lint-ci : elle exige le lab (annuaire + Vault) et mute
	@# l'annuaire. Même régime que les autres `-live` — son verdict se rend à la
	@# main, sa syntaxe se relit à chaque passage.
	@echo "== [2/20] shellcheck des bibliothèques shell (ci/lib + livrables G2..G8, A1..A7, P2, P5, P6)"
	@command -v shellcheck >/dev/null || { echo "!! shellcheck absent — \`brew install shellcheck\`"; exit 2; }
	@# L3 (2026-09-10) : cinq fichiers de plus dans CETTE liste, aucun rang de
	@# plus. scripts/team-publish.sh est du shell LIVRÉ, lourdement édité par L3,
	@# et rien ne le relisait ; les quatre harnais qui suivent gardent le
	@# comportement neuf des poseurs, et trois d'entre eux sont EXÉCUTÉS plus bas
	@# sous cette même étape. Une suite que la porte ne relit pas dérive en
	@# silence — c'est exactement ce qui vient d'arriver deux fois (revue L3).
	@shellcheck -x ci/lib/*.sh scripts/lib/deploy-pin.sh scripts/lib/env-chain.sh scripts/lib/branch-ref.sh scripts/lib/vault-kv.sh \
	  scripts/lib/repo-protection.sh scripts/lib/archive-store.sh \
	  scripts/lib/promote-manifest.sh scripts/test-promote-sans-recopie.sh \
	  scripts/lib/assert-merge-identity.sh scripts/test-merge-identity.sh scripts/lib/app-manifest.sh \
	  scripts/forge-merge-identity.sh \
	  scripts/provision-apply-reconcile.sh scripts/provision-apply-comment.sh \
	  scripts/setup-repo-protections.sh scripts/setup-deployer-groups.sh \
	  scripts/setup-vault-paliers.sh scripts/setup-user-vault-jwt.sh \
	  scripts/api-promote-request.sh scripts/api-promote-export.sh \
	  scripts/team-promote.sh scripts/test-deployer-gate-live.sh \
	  scripts/test-rollback-paliers.sh scripts/test-parity-moteurs.sh \
	  scripts/lib/gwt-mirror.sh scripts/lib/generate-choices.sh scripts/app-request-choices.sh \
	  scripts/lib/gitea-pr-confirm.sh scripts/provision-plan-status.sh scripts/setup-selfservice-job.sh \
	  scripts/selfservice-palier-gate.sh scripts/setup-wm-palier-admins.sh \
	  scripts/provision-apply-gate.sh scripts/test-a4-live.sh \
	  scripts/test-selfservice-api-gate-a5.sh scripts/test-a5-live.sh \
  scripts/app-rollback-request.sh scripts/test-app-rollback-a6.sh scripts/test-a6-live.sh \
	  scripts/lib/forge-identity.sh scripts/test-app-request-a7.sh scripts/setup-terminus-apps.sh scripts/test-a7-live.sh \
	  scripts/setup-jenkins-globals.sh scripts/setup-provision-jobs.sh scripts/setup-carto-job.sh ci/lint-config-knobs.sh \
	  scripts/setup-provision-request-job.sh scripts/setup-team-onboard-jobs.sh scripts/setup-user-deploy-job.sh \
	  scripts/lib/posture-authority.sh scripts/lib/wm-dataplane.sh scripts/test-p5-https.sh \
	  scripts/test-p6-deny-by-default.sh scripts/test-p7-bout-en-bout.sh \
	  scripts/test-repo-layout-portabilite.sh scripts/lib/providers-teams.sh scripts/test-providers-teams.sh \
	  scripts/lib/forge-api.sh scripts/test-forge-api.sh scripts/test-forge-api-live.sh scripts/setup-gitlab-lab.sh \
	  scripts/lib/git-base.sh scripts/test-git-base.sh scripts/test-dbg-redaction.sh scripts/test-vault-login-offline.sh \
	  ci/lint-forge-literals.sh ci/lint-forge-knobs.sh ci/lint-branch-literals.sh scripts/test-app-request-gitlab-live.sh \
	  scripts/test-porte-clone-frais.sh \
	  scripts/test-team-request-wiring.sh scripts/test-team-publish-wiring.sh \
	  scripts/test-debug-knob-wiring.sh scripts/test-app-request-wiring.sh scripts/test-api-request-wiring.sh scripts/test-team-apply-wiring.sh \
	  scripts/test-producer-chain.sh \
	  scripts/team-publish.sh \
	  scripts/test-setup-provision-jobs.sh scripts/test-generate-choices.sh \
	  scripts/test-app-request-v2.sh scripts/test-app-request-v3.sh \
	  && echo "  ✓ ci/lib + livrables shell G2..G8 + A1 + A2 + A0 + A3 + A4 + A5 + A6 + A7 + P2 + P5 + P6 + P7 + L3 propres"
	@# … et la MÊME étape doit passer sur un CLONE FRAIS. Le shellcheck
	@# ci-dessus s'exécute là où `.env.lab-users` (0600, hors Git) EXISTE ;
	@# absent, il rendait SC1091 et lint-ci mourait ici — chez un client, en
	@# CI, jamais sur le poste. Cette suite relit les six suites `-live` sous
	@# ABSENCE FORCÉE du fichier, et porte sa mutation. Elle vit SOUS l'étape 2
	@# (pas de rang à elle) : elle mesure cette étape-là, pas autre chose.
	@bash scripts/test-porte-clone-frais.sh
	@# … et le livrable doit arriver en LF chez le CLIENT, pas seulement ici.
	@# Sans .gitattributes, c'est `core.autocrlf` du POSTE qui decide : le meme
	@# depot produit deux arbres differents, et un `\r` en fin de ligne fait
	@# echouer bash sur un message qui designe la MAUVAISE cause (« introuvable
	@# ou illisible » pour un fichier present). Mesure le 2026-09-09 sur le CI
	@# client. Sous l'etape 2 (pas de rang a elle) : elle mesure le meme objet.
	@bash ci/lint-eol.sh
	@# L'ADAPTATEUR DE FORGE (2026-09-09). La chaine parlait l'API de Gitea en
	@# dur ; un client GitLab mourait au premier appel (302 vers /users/sign_in).
	@# scripts/lib/forge-api.py rend les MEMES lignes CLE=VALEUR sur les deux
	@# visages ; ce mock a deux visages rend les formes REELLES et ses mutations
	@# (iid→number, username→login…) prouvent que l'adaptateur LIT GitLab au lieu
	@# de le deviner. La preuve vivante (GitLab CE + Gitea du lab) se joue a la
	@# main : bash scripts/test-forge-api-live.sh. Sous l'etape 2, sans rang.
	@python3 -m py_compile scripts/lib/forge-api.py
	@bash scripts/test-forge-api.sh
	@# LA BRANCHE PAR DEFAUT (2026-09-09) : un client GitLab sur `master` a perdu
	@# deux jours sur 46 `main` ecrits en dur. scripts/lib/git-base.sh est l'autorite
	@# unique — knob explicite > decouverte `ls-remote --symref` > refus nomme,
	@# jamais un `main` devine. Sous l'etape 2, sans rang.
	@bash scripts/test-git-base.sh
	@# LE DEBUG SANS FUITE (2026-09-09) : ci/lib/dbg.sh, sortie curatee sur stderr,
	@# redaction fail-closed, secrets vers python par here-doc sur fd 3 — le SEUL
	@# canal muet sous `sh -x` (mesure : printf est trace avec ses arguments dans
	@# bash ET dash). Sa suite joue `bash -xc` et `dash -xc`. Sous l'etape 2, sans rang.
	@bash scripts/test-dbg-redaction.sh
	@# … et son PREMIER CONSOMMATEUR (2026-09-10, L2) : ci/lib/vault-login.sh y a
	@# migre son debug — plus de `_vault_redact … || cat` qui sortait le corps
	@# d'erreur EN CLAIR sans python3. Stub Vault sur port libre, dash/sh/bash,
	@# mutations sur copie. Hors ligne, ~5 s. Sous l'etape 2, sans rang.
	@bash scripts/test-vault-login-offline.sh
	@# UNE SEULE AUTORITE DE FORGE (2026-09-09) : hors de forge-api.py/.sh et de
	@# forge-identity.sh, aucun /api/v1, /api/v4, en-tete d'auth, json.load ni
	@# urlopen dans les fichiers ROUTES. Interdire le litteral, jamais l'exiger.
	@bash ci/lint-forge-literals.sh
	@# ET LE VISAGE ARRIVE-T-IL AU SCRIPT ? (2026-09-12) Un script ROUTE sur
	@# l'autorite ne vaut que si le Jenkinsfile qui l'INVOQUE lui transmet
	@# FORGE_KIND / FORGE_API_AUTH / FORGE_API_BASE — sinon il parle au visage par
	@# DEFAUT : invisible au lab (le defaut EST le bon visage) et faux chez le
	@# client. Portee DERIVEE : cette porte LIT la liste ROUTES de la porte
	@# ci-dessus, jamais une liste a la main — elle a trouve ainsi un douzieme
	@# Jenkinsfile (provisioning-request, voie machine) que deux releves manuels
	@# avaient manque. Elle exige aussi l'ABSENCE de defaut de site sur
	@# FORGE_KIND : un repli 'gitea' rendrait FORGE_KIND_REQUIS inatteignable.
	@bash ci/lint-forge-knobs.sh
	@# AUCUNE BRANCHE ECRITE EN DUR (2026-09-10, L3). Le meme client GitLab :
	@# 46 « main » executes et 155 messages, pour une branche par defaut `master`.
	@# Cette porte interdit le litteral dans les fichiers LIVRES (shell, Jenkinsfile,
	@# coquilles de jobs, taches Ansible) — A1 le litteral execute, A2 le mot « main »
	@# nu dans un message, qui est ce qui a coute deux jours. Exemptes NOMMES dans le
	@# fichier (harnais, outils de lab, l'autorite git-base.sh). Sous l'etape 2, sans rang.
	@bash ci/lint-branch-literals.sh
	@# … et la porte interdit le LITTERAL, elle ne verifie pas le COMPORTEMENT.
	@# Les trois suites qui suivent gardent ce que L3 a reellement change : la
	@# substitution de __GIT_BASE__ a la pose, le refus BRANCHE_PAR_DEFAUT_INDECIDABLE
	@# quand rien ne dit par quoi remplacer, et la decouverte `ls-remote --symref`.
	@# Aucune n'etait jouee par lint-ci : c'est ainsi que deux d'entre elles ont
	@# derive au ROUGE sans que personne le voie (revue L3, 2026-09-10). Elles
	@# vivent SOUS l'etape 2, sans rang a elles — le compte [20/20] ne bouge pas.
	@#
	@# Le poseur des treize jobs : placeholder substitue, refus nomme, knob qui
	@# gagne sur la HEAD. Hors ligne (faux Jenkins + depot nu local), 7 s.
	@bash scripts/test-setup-provision-jobs.sh
	@# Le generateur de listes : c'est lui qui clone la plateforme et les depots
	@# d'equipe, donc lui qui joue git_base_init ET git_base_of. Hors ligne, 33 s.
	@bash scripts/test-generate-choices.sh
	@# La pose d'app-request de bout en bout, fixture DISCRIMINANTE : depot nu
	@# dont la HEAD annoncee est `master`, aucun GIT_BASE dans l'environnement du
	@# poseur — un code qui devinerait `main` rougirait ici. V3_SANS_LAB borne le
	@# harnais a ses sections A/B : ses sections C/D ECRIVENT sur le Gitea du lab
	@# (meme regime que les `-live` : leur verdict se rend a la main). 6 s.
	@V3_SANS_LAB=1 bash scripts/test-app-request-v3.sh
	@echo "== [3/20] épreuves de ci/lib/carto-secrets.sh"
	@ci/test-carto-secrets.sh
	@echo "== [4/20] épreuves du résolveur de pin (G3)"
	@bash scripts/test-deploy-pin.sh
	@echo "== [5/20] épreuves de la rétention par palier (G4)"
	@bash scripts/test-palier-retention.sh
	@echo "== [6/20] épreuves du transport d'archives adressé par le contenu (G5)"
	@bash scripts/test-archive-store.sh
	@# LA porte du jalon G5 : « porte refusée ⇒ moteur jamais lancé ». Comme
	@# test-deploy-pin (précédent endossé en G4), ce harnais est EXÉCUTÉ, pas
	@# shellchecké — c'est son verdict qui compte, pas son style.
	@echo "== [7/20] épreuves du câblage de promotion — porte refusée ⇒ moteur jamais lancé (G5)"
	@bash scripts/test-team-promote-wiring.sh
	@# … et les DEUX AUTRES câblages de la même famille (demande et publication
	@# d'équipe). Ils existaient et RIEN ne les appelait : c'est exactement pour
	@# ça qu'ils avaient dérivé — 65/66 et 118/119 au 2026-09-09, rouges depuis
	@# le renommage du secret de forge (2026-09-04) et depuis l'ajout du clone du
	@# registre de gouvernance. Une suite hors porte ne mesure plus rien : elle
	@# enregistre l'état du jour où on l'a écrite. Ils vivent SOUS l'étape 7,
	@# sans rang à eux — le compte des étapes et D.11 restent inchangés.
	@bash scripts/test-team-request-wiring.sh
	@bash scripts/test-team-publish-wiring.sh
	@# L4 (2026-09-11) : deux câblages de plus de la même famille, verts mais
	@# jamais appelés (72/72 et 55/55 le jour de leur entrée) — L4 réécrit leurs
	@# ancres (case DEBUG, pont), une suite hors porte les aurait laissées dériver.
	@bash scripts/test-team-apply-wiring.sh
	@bash scripts/test-api-request-wiring.sh
	@# mocks/webmethods n'est PAS vendored (dépend du module cache Go, comme
	@# labctl NE l'est PAS ici) : pas de GOPROXY=off. Spec §4.3 promettait
	@# cette porte hors-ligne branchée dans lint-ci — restée débranchée jusqu'ici.
	@echo "== [8/20] go test du mock webMethods (fidélité + archive, G5)"
	@cd mocks/webmethods && go test ./... -count=1
	@# A1 (CD des applications) : la fusion multi-palier du manifeste et le
	@# contrat figé, HORS LIGNE (sections A/B) — la section C, contre le Gitea
	@# du lab, se rend à la main comme les autres suites `-v2/-v3`.
	@echo "== [9/20] épreuves du manifeste multi-palier — lib seule + gardes hors ligne (A1)"
	@A1_OFFLINE=1 bash scripts/test-app-request-a1.sh
	@# A2 (CD des applications) : la référence est le SHA mergé — digest du
	@# palier (lib), réconciliation Gitea contre un stub (le payload ne fait pas
	@# foi), rapport de PR, mutations ; puis le CÂBLAGE du job provision-apply
	@# (Jenkinsfile déclaratif + coquille XML miroir + aval). La preuve par
	@# builds réels (test-provision-apply-a2-live.sh) se rend à la main.
	@# LA GARDE DES QUATRE YEUX, jouée ici (2026-09-12). Sa suite existait mais
	@# n'était NI relue NI exécutée : c'est ainsi qu'un trou par vacuité a vécu
	@# dans assert-merge-identity.sh (un demandeur VIDE faisait SAUTER le
	@# contrôle au lieu de le faire échouer). Une suite hors porte dérive — ce
	@# dépôt l'a déjà payé deux fois.
	@bash scripts/test-merge-identity.sh
	@echo "== [10/20] épreuves de la référence SHA mergé — lib, réconciliation, rapport, câblage (A2)"
	@bash scripts/test-provision-apply-a2.sh
	@# A0 (CD des applications) : plus un seul job.xml porteur de logique —
	@# coquilles from SCM, miroir des triggers par la lib (mutations comprises),
	@# formulaire app-request posé par son Jenkinsfile depuis les listes du dépôt
	@# (script fonctionnel hors ligne), amorçage câblé dans la pose. La preuve par
	@# builds réels (test-a0-live.sh) se rend à la main.
	@echo "== [11/20] épreuves « tout en Jenkinsfile » — coquilles, miroir, formulaire posé, pose (A0)"
	@bash scripts/test-a0-wiring.sh
	@bash scripts/test-provision-apply-wiring.sh
	@# L4 (2026-09-11) : le câblage d'app-request (36/36, orphelin jusqu'ici) et
	@# LA porte de la case DEBUG — une table des huit formulaires : case au bon
	@# rang, miroir XML, pont après set +x en if/fi, exclusions explicites,
	@# globale STOA_DEBUG connue/optionnelle, relais -e stoa_debug du moteur,
	@# mutants qui rougissent. Les preuves par builds réels
	@# (test-debug-knob-live.sh) se rendent à la main.
	@bash scripts/test-app-request-wiring.sh
	@bash scripts/test-debug-knob-wiring.sh
	@# A3 (CD des applications) : le credential du seul palier — la garde
	@# (scripts/selfservice-palier-gate.sh) contre un stub Vault et un canari
	@# (refus nommés, ticket non inscriptible, équipe décidée par le token,
	@# mutations), le câblage de Jenkinsfile.selfservice (ordre par lignes,
	@# mutation d'ordre), les deux poseurs de lab en --print, vault_token_ttl.
	@# Les preuves live (test-palier-retention-live.sh ⑦, test-a3-live.sh) se
	@# rendent à la main.
	@echo "== [12/20] épreuves du credential du seul palier — garde, câblage, poseurs (A3)"
	@bash scripts/test-selfservice-palier-a3.sh
	@# A4 (CD des applications) : les portes de la chaîne au dispatch — la porte
	@# amont (scripts/provision-apply-gate.sh) contre des fixtures (dépôt git,
	@# stub ITSM canari, enregistreur, shim git, mutations), le câblage des deux
	@# Jenkinsfile (fragment de la garde EXÉCUTÉ, mutations d'ordre), le rapport
	@# (REFUSAL_KIND=porte, ligne « porte du palier »), « deux portes, une source ».
	@# La preuve par builds réels (test-a4-live.sh) se rend à la main.
	@echo "== [13/20] épreuves des portes de la chaîne au dispatch — porte amont, câblages, rapport, deux portes une source (A4)"
	@bash scripts/test-provision-apply-a4.sh
	@# A5 (CD des applications) : l'ordre app/API — la porte du rôle contre un
	@# stub (journal, quatre refus AVANT la première écriture, 3 mutations),
	@# verify contre le mock Go, le câblage du relais tag+phrase, le rapport,
	@# le prototype. La preuve par builds réels (test-a5-live.sh) se rend à la main.
	@echo "== [14/20] épreuves de l'ordre app/API — porte du rôle, verify, relais, rapport, prototype (A5)"
	@bash scripts/test-selfservice-api-gate-a5.sh
	@# A6 (CD des applications) : le repli est une PR — le script de demande contre
	@# une fixture git + un stub forge à journal + un shim git (5 mutations), la
	@# garde symétrique de provision-request.sh, REPLI_PERIME au réconciliateur,
	@# le câblage du formulaire. La preuve par builds réels (test-a6-live.sh) se rend à la main.
	@echo "== [15/20] épreuves du repli d'application par PR — demande, lignée, gardes de fenêtre, câblage (A6)"
	@bash scripts/test-app-rollback-a6.sh
	@# A7 (CD des applications) : la demande sous identité de forge — la lib et
	@# provision-request.sh contre un stub forge à journal (GET /user par token,
	@# POST /pulls avec l'Authorization journalisé), un dépôt nu, un shim git qui
	@# journalise argv ET env (le token humain n'atteint aucun enfant), 6 mutations.
	@# La preuve par builds réels (test-a7-live.sh) se rend à la main.
	@echo "== [16/20] épreuves de la demande sous identité de forge — lib, refus à la demande, PR d'autrui, refs, chaîne entière (A7)"
	@bash scripts/test-app-request-a7.sh
	@echo "== [17/20] porte des valeurs par défaut — aucun défaut de SITE dans du code livrable"
	@bash ci/lint-config-knobs.sh
	@# LA PORTE DU PREFIXE (2026-09-08). ci/lint-config-knobs.sh n'examine que les
	@# VALEURS PAR DEFAUT (`${X:-…}`) : un prefixe de lab ecrit en dur dans une
	@# affectation nue lui echappe. Et toutes les fixtures A1..A7 batissent leur
	@# depot AVEC le prefixe du lab — elles ne peuvent structurellement pas voir
	@# un chemin qui ne suit pas GIT_SUBDIR. Cette suite ne joue QUE sous un
	@# prefixe non-defaut : c'est le seul harnais qui tombe sur ce defaut.
	@echo "== [18/20] épreuves de portabilité du préfixe du livrable — la garde providers suit GIT_SUBDIR"
	@bash scripts/test-repo-layout-portabilite.sh
	@# LE PREFLIGHT DE JOIGNABILITE (2026-09-07). Ce harnais existait, et RIEN ne
	@# l'appelait — ni ici, ni un Jenkinsfile : ses six assertions de CABLAGE,
	@# celles qui « auraient attrape 5d34299 » (le merge qui a rendu a
	@# Jenkinsfile.publish-api un preflight sans knob ni garde-fou pendant que
	@# Jenkinsfile.selfservice gardait le bon), ne s'executaient jamais.
	@# STOA_PREFLIGHT_ONLY=1 : on branche la moitie PREFLIGHT + CABLAGE. Le bloc
	@# PROXY du meme fichier reste NON BRANCHE et ROUGE — 5 KO residuels
	@# ETRANGERS au preflight, dont la fermeture exigerait DEUX nouveaux defauts
	@# de site que ci/lint-config-knobs.exempt interdit d'ajouter. Il se joue a
	@# la main : `sh ci/test-proxy-base-et-preflight.sh` (sans le knob).
	@# LA PORTE DE L'APPARTENANCE D'EQUIPE (2026-09-09). Trois scripts decidaient
	@# « cette equipe est-elle declaree ? » par un grep TEXTUEL sur la forme exacte
	@# de la ligne, quand six autres lisaient LE MEME fichier par yaml.safe_load.
	@# Chez un client dont le providers.<env>.yml — YAML valide — indente a quatre
	@# espaces, cite la valeur ou arrive en CRLF, l'equipe DECLAREE etait refusee.
	@echo "== [19/20] épreuves de l'appartenance d'équipe — lue en YAML, jamais reconnue au texte"
	@bash scripts/test-providers-teams.sh
	@echo "== [20/20] épreuves du préflight de joignabilité — lib pilotée, câblage des deux Jenkinsfile, mutations"
	@STOA_PREFLIGHT_ONLY=1 sh ci/test-proxy-base-et-preflight.sh


# Sauvegarde idempotente (ne re-save pas ce qui est déjà là) : `docker save` par
# image → restauration unitaire possible. Pas de gzip : 2.4 To de libre, autant
# garder un `docker load` rapide.
images-save:
	@mkdir -p "$(IMAGES_BACKUP)"
	@set -e; for img in $(TRIAL_IMAGES); do \
	  out="$(IMAGES_BACKUP)/$$(echo "$$img" | tr '/:' '__').tar"; \
	  if [ -s "$$out" ]; then echo "== deja sauve : $$img"; continue; fi; \
	  echo ">> save $$img"; \
	  docker save "$$img" -o "$$out" || { rm -f "$$out"; echo "!! ECHEC (image absente du store ?) : $$img"; exit 1; }; \
	done
	@echo "== $(IMAGES_BACKUP)"; ls -lh "$(IMAGES_BACKUP)"

# À rejouer après un prune / une réinstall de Docker Desktop : recharge les
# images dans le store SANS toucher au registry (aucun login requis).
images-restore:
	@set -e; for tar in "$(IMAGES_BACKUP)"/*.tar; do \
	  [ -e "$$tar" ] || { echo "!! aucun tarball dans $(IMAGES_BACKUP) — lancer 'make images-save' d'abord"; exit 1; }; \
	  echo ">> load $$tar"; docker load -i "$$tar"; \
	done

# Contrôle : chaque image trial est-elle présente dans le store ET sauvegardée ?
images-check:
	@for img in $(TRIAL_IMAGES); do \
	  tar="$(IMAGES_BACKUP)/$$(echo "$$img" | tr '/:' '__').tar"; \
	  s=$$(docker image inspect "$$img" >/dev/null 2>&1 && echo "store:OK  " || echo "store:MANQUE"); \
	  b=$$([ -s "$$tar" ] && echo "backup:OK" || echo "backup:MANQUE"); \
	  printf '%s  %s  %s\n' "$$s" "$$b" "$$img"; \
	done
