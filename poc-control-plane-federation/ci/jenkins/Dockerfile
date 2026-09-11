# Jenkins + Go pour builder labctl EN AIR-GAPPED (deps vendorées, GOPROXY=off).
# Le build de CETTE image a besoin d'internet (one-shot, hors zone, par toi) ;
# le pipeline qui tourne dedans, lui, ne sort jamais (vendor/ + GOPROXY=off).
FROM jenkins/jenkins:lts-jdk17
USER root
ARG GO_VERSION=1.26.0
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz \
 && /usr/local/go/bin/go version
# Ansible (chemin PR/apply fidèle client, ADR-076) : les jobs projet lancent
# `ansible-playbook` (pur, modules builtin assert/uri/include_vars). ansible-core
# suffit (pas la distribution complète). One-shot au build, hors zone.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ansible-core \
 && rm -rf /var/lib/apt/lists/* \
 && ansible-playbook --version | head -1
# GOPROXY=off + -mod=vendor par défaut : TOUT build est offline dans cette image.
ENV PATH="${PATH}:/usr/local/go/bin" GOPROXY=off GOFLAGS=-mod=vendor GOSUMDB=off
# labctl : le binaire qui porte la DÉCISION (portes, 4-yeux, ITSM, pin, posture)
# — DELIVERY-PROCESS.md §D3, « Ansible peut rester bête ; le binaire porte la
# politique ». ⚠ Ce commentaire disait « LE moteur gateway UNIQUE (ADR-076 /
# POSITIONING §7.6) » : doctrine TUÉE le 2026-08-26 (les rôles apim_* portent 53
# mutations REST contre webMethods, toute la chaîne self-service repose dessus),
# et citation fausse — le §7.6 est une section de l'ÉTUDE CLIENT, pas de
# POSITIONING.md. Le geste de mutation part de l'un ou l'autre moteur ; seule la
# décision est obligatoirement ici. Compilé À LA
# CONSTRUCTION de l'image, air-gapped (vendor/ + GOPROXY=off), sur l'arch NATIVE
# de l'image -> zéro cross-compile. Les jobs projet n'ont plus à re-dériver les
# quirks wM : ils ORCHESTRENT `labctl apply` (Model 2). Source = repo plateforme
# (contexte de build = racine du repo, cf. docker-compose.ci.yml + .dockerignore).
COPY labctl/ /usr/local/src/labctl/
RUN cd /usr/local/src/labctl \
 && go build -trimpath -o /usr/local/bin/labctl . \
 && chmod 0755 /usr/local/bin/labctl \
 && labctl version
USER jenkins
# Plugins requis par le scaffold (« Pipeline script from SCM » + checkout Git) —
# l'image de base n'en embarque AUCUN. Install au build (one-shot, hors zone).
RUN jenkins-plugin-cli --plugins "git workflow-aggregator generic-webhook-trigger gitlab-plugin pipeline-stage-view kubernetes"
# gitlab-plugin (L6, 2026-09-11) : le SECOND récepteur de webhooks
# (WEBHOOK_KIND=gitlab), pour qu'un lab reconstruit puisse rejouer
# scripts/test-webhook-kind-gitlab-live.sh. Installé le 2026-09-11 sur le lab en
# place par scripts/spike-webhook-kind-m5.sh (1.2148, 14 dépendances, GWT
# intact, aucun plugin préexistant modifié).
# pipeline-stage-view : dessine la Stage View (visualisation des stages sur la page
# du job) — workflow-aggregator ne l'embarque PAS. Sans lui les stages s'exécutent
# mais ne s'affichent pas (trouvé au build #1 accounts-team).
# generic-webhook-trigger : endpoint /generic-webhook-trigger/invoke?token=…
# exempt de crumb CSRF — le POST /job/…/build?token= est refusé (403 crumb)
# par les Jenkins modernes, même non sécurisés. Validé au premier run Phase 0.
# kubernetes : agents éphémères en pods (podTemplate) — la porte de preuve
# G-c (pipeline exécutée par un pod jetable, pas par le contrôleur Jenkins
# lui-même) en dépend ; absent de l'image de base et jamais tiré comme
# dépendance transitive des trois plugins ci-dessus.
