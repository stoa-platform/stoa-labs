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
