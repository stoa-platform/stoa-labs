# Jenkins + Go pour builder labctl EN AIR-GAPPED (deps vendorées, GOPROXY=off).
# Le build de CETTE image a besoin d'internet (one-shot, hors zone, par toi) ;
# le pipeline qui tourne dedans, lui, ne sort jamais (vendor/ + GOPROXY=off).
FROM jenkins/jenkins:lts-jdk17
USER root
ARG GO_VERSION=1.26.0
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz \
 && /usr/local/go/bin/go version
# GOPROXY=off + -mod=vendor par défaut : TOUT build est offline dans cette image.
ENV PATH="${PATH}:/usr/local/go/bin" GOPROXY=off GOFLAGS=-mod=vendor GOSUMDB=off
USER jenkins
# Plugins requis par le scaffold (« Pipeline script from SCM » + checkout Git) —
# l'image de base n'en embarque AUCUN. Install au build (one-shot, hors zone).
RUN jenkins-plugin-cli --plugins "git workflow-aggregator generic-webhook-trigger"
# generic-webhook-trigger : endpoint /generic-webhook-trigger/invoke?token=…
# exempt de crumb CSRF — le POST /job/…/build?token= est refusé (403 crumb)
# par les Jenkins modernes, même non sécurisés. Validé au premier run Phase 0.
