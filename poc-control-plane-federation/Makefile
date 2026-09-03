# Makefile — build & release des binaires Go du PoC (É0, DELIVERY-PROCESS.md §4).
#
#   make build     binaire labctl natif dans labctl/bin/ (confort dev, untracked)
#   make test      suite Go complète, air-gapped (GOPROXY=off, -mod=vendor)
#   make release   dist/<version>/ : binaires MULTI-ARCH versionnés (ldflags -X)
#                  + SHA256SUMS + SBOM SPDX — le tout SANS réseau (vendor/).
#   make lint-ci   les portes de la chaîne CI : compilation des Jenkinsfile,
#                  shellcheck des bibliothèques, épreuves de carto-secrets et
#                  du résolveur de pin.
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
	@echo "== [1/16] compilation des Jenkinsfile"
	@ci/lint-jenkinsfiles.sh
	@# La porte LIVE du grant déployeur (G2) est SHELLCHECKÉE ici mais jamais
	@# EXÉCUTÉE par lint-ci : elle exige le lab (annuaire + Vault) et mute
	@# l'annuaire. Même régime que les autres `-live` — son verdict se rend à la
	@# main, sa syntaxe se relit à chaque passage.
	@echo "== [2/16] shellcheck des bibliothèques shell (ci/lib + livrables G2..G8, A1, A2, A3, A4, A5, A6, A7)"
	@command -v shellcheck >/dev/null || { echo "!! shellcheck absent — \`brew install shellcheck\`"; exit 2; }
	@shellcheck -x ci/lib/*.sh scripts/lib/deploy-pin.sh scripts/lib/env-chain.sh \
	  scripts/lib/repo-protection.sh scripts/lib/archive-store.sh \
	  scripts/lib/promote-manifest.sh scripts/test-promote-sans-recopie.sh \
	  scripts/lib/assert-merge-identity.sh scripts/lib/app-manifest.sh \
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
	  scripts/lib/forge-identity.sh scripts/test-app-request-a7.sh \
	  && echo "  ✓ ci/lib + livrables shell G2..G8 + A1 + A2 + A0 + A3 + A4 + A5 + A6 + A7 propres"
	@echo "== [3/16] épreuves de ci/lib/carto-secrets.sh"
	@ci/test-carto-secrets.sh
	@echo "== [4/16] épreuves du résolveur de pin (G3)"
	@bash scripts/test-deploy-pin.sh
	@echo "== [5/16] épreuves de la rétention par palier (G4)"
	@bash scripts/test-palier-retention.sh
	@echo "== [6/16] épreuves du transport d'archives adressé par le contenu (G5)"
	@bash scripts/test-archive-store.sh
	@# LA porte du jalon G5 : « porte refusée ⇒ moteur jamais lancé ». Comme
	@# test-deploy-pin (précédent endossé en G4), ce harnais est EXÉCUTÉ, pas
	@# shellchecké — c'est son verdict qui compte, pas son style.
	@echo "== [7/16] épreuves du câblage de promotion — porte refusée ⇒ moteur jamais lancé (G5)"
	@bash scripts/test-team-promote-wiring.sh
	@# mocks/webmethods n'est PAS vendored (dépend du module cache Go, comme
	@# labctl NE l'est PAS ici) : pas de GOPROXY=off. Spec §4.3 promettait
	@# cette porte hors-ligne branchée dans lint-ci — restée débranchée jusqu'ici.
	@echo "== [8/16] go test du mock webMethods (fidélité + archive, G5)"
	@cd mocks/webmethods && go test ./... -count=1
	@# A1 (CD des applications) : la fusion multi-palier du manifeste et le
	@# contrat figé, HORS LIGNE (sections A/B) — la section C, contre le Gitea
	@# du lab, se rend à la main comme les autres suites `-v2/-v3`.
	@echo "== [9/16] épreuves du manifeste multi-palier — lib seule + gardes hors ligne (A1)"
	@A1_OFFLINE=1 bash scripts/test-app-request-a1.sh
	@# A2 (CD des applications) : la référence est le SHA mergé — digest du
	@# palier (lib), réconciliation Gitea contre un stub (le payload ne fait pas
	@# foi), rapport de PR, mutations ; puis le CÂBLAGE du job provision-apply
	@# (Jenkinsfile déclaratif + coquille XML miroir + aval). La preuve par
	@# builds réels (test-provision-apply-a2-live.sh) se rend à la main.
	@echo "== [10/16] épreuves de la référence SHA mergé — lib, réconciliation, rapport, câblage (A2)"
	@bash scripts/test-provision-apply-a2.sh
	@# A0 (CD des applications) : plus un seul job.xml porteur de logique —
	@# coquilles from SCM, miroir des triggers par la lib (mutations comprises),
	@# formulaire app-request posé par son Jenkinsfile depuis les listes du dépôt
	@# (script fonctionnel hors ligne), amorçage câblé dans la pose. La preuve par
	@# builds réels (test-a0-live.sh) se rend à la main.
	@echo "== [11/16] épreuves « tout en Jenkinsfile » — coquilles, miroir, formulaire posé, pose (A0)"
	@bash scripts/test-a0-wiring.sh
	@bash scripts/test-provision-apply-wiring.sh
	@# A3 (CD des applications) : le credential du seul palier — la garde
	@# (scripts/selfservice-palier-gate.sh) contre un stub Vault et un canari
	@# (refus nommés, ticket non inscriptible, équipe décidée par le token,
	@# mutations), le câblage de Jenkinsfile.selfservice (ordre par lignes,
	@# mutation d'ordre), les deux poseurs de lab en --print, vault_token_ttl.
	@# Les preuves live (test-palier-retention-live.sh ⑦, test-a3-live.sh) se
	@# rendent à la main.
	@echo "== [12/16] épreuves du credential du seul palier — garde, câblage, poseurs (A3)"
	@bash scripts/test-selfservice-palier-a3.sh
	@# A4 (CD des applications) : les portes de la chaîne au dispatch — la porte
	@# amont (scripts/provision-apply-gate.sh) contre des fixtures (dépôt git,
	@# stub ITSM canari, enregistreur, shim git, mutations), le câblage des deux
	@# Jenkinsfile (fragment de la garde EXÉCUTÉ, mutations d'ordre), le rapport
	@# (REFUSAL_KIND=porte, ligne « porte du palier »), « deux portes, une source ».
	@# La preuve par builds réels (test-a4-live.sh) se rend à la main.
	@echo "== [13/16] épreuves des portes de la chaîne au dispatch — porte amont, câblages, rapport, deux portes une source (A4)"
	@bash scripts/test-provision-apply-a4.sh
	@# A5 (CD des applications) : l'ordre app/API — la porte du rôle contre un
	@# stub (journal, quatre refus AVANT la première écriture, 3 mutations),
	@# verify contre le mock Go, le câblage du relais tag+phrase, le rapport,
	@# le prototype. La preuve par builds réels (test-a5-live.sh) se rend à la main.
	@echo "== [14/16] épreuves de l'ordre app/API — porte du rôle, verify, relais, rapport, prototype (A5)"
	@bash scripts/test-selfservice-api-gate-a5.sh
	@# A6 (CD des applications) : le repli est une PR — le script de demande contre
	@# une fixture git + un stub forge à journal + un shim git (5 mutations), la
	@# garde symétrique de provision-request.sh, REPLI_PERIME au réconciliateur,
	@# le câblage du formulaire. La preuve par builds réels (test-a6-live.sh) se rend à la main.
	@echo "== [15/16] épreuves du repli d'application par PR — demande, lignée, gardes de fenêtre, câblage (A6)"
	@bash scripts/test-app-rollback-a6.sh
	@# A7 (CD des applications) : la demande sous identité de forge — la lib et
	@# provision-request.sh contre un stub forge à journal (GET /user par token,
	@# POST /pulls avec l'Authorization journalisé), un dépôt nu, un shim git qui
	@# journalise argv ET env (le token humain n'atteint aucun enfant), 6 mutations.
	@# La preuve par builds réels (test-a7-live.sh) se rend à la main.
	@echo "== [16/16] épreuves de la demande sous identité de forge — lib, refus à la demande, PR d'autrui, refs, chaîne entière (A7)"
	@bash scripts/test-app-request-a7.sh

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
