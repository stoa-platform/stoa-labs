# Makefile — build & release des binaires Go du PoC (É0, DELIVERY-PROCESS.md §4).
#
#   make build     binaire labctl natif dans labctl/bin/ (confort dev, untracked)
#   make test      suite Go complète, air-gapped (GOPROXY=off, -mod=vendor)
#   make release   dist/<version>/ : binaires MULTI-ARCH versionnés (ldflags -X)
#                  + SHA256SUMS + SBOM SPDX — le tout SANS réseau (vendor/).
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

.PHONY: build test release clean images-save images-restore images-check

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
