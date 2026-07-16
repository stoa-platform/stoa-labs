#!/usr/bin/env bash
# Console Light — seed du repo de gouvernance (source de vérité Git).
#
# Crée var/governance-repo (git local), configure la SIGNATURE SSH des commits
# (clé dédiée + allowed_signers → `git log --format=%G?` rend "G"), et seed le
# contenu démo : tenant banking-demo, 3 contrats UAC v1 (dont payments-initiation
# avec endpoint destructive ⇒ requires_human_approval), desired-state par env,
# souscriptions (2 pending pour la file d'approbation).
#
# Idempotent : re-jouable (détruit et recrée si --force).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${GOVERNANCE_REPO:-$HERE/var/governance-repo}"
SIGN_DIR="$HERE/var/signing"

say() { printf '\033[1;32m[seed]\033[0m %s\n' "$*"; }

if [ -d "$REPO/.git" ]; then
  if [ "${1:-}" = "--force" ]; then
    say "--force : suppression de $REPO"
    rm -rf "$REPO"
  else
    say "Repo déjà présent ($REPO). Utiliser --force pour recréer."
    exit 0
  fi
fi

mkdir -p "$REPO" "$SIGN_DIR"

# --- clé de signature SSH (dédiée au repo de gouvernance) --------------------
if [ ! -f "$SIGN_DIR/governance_signing" ]; then
  ssh-keygen -t ed25519 -N "" -C "governance-bot@stoa.local" -f "$SIGN_DIR/governance_signing" >/dev/null
  say "Clé de signature SSH générée."
fi
printf 'governance-bot@stoa.local %s\n' "$(cut -d' ' -f1-2 "$SIGN_DIR/governance_signing.pub")" > "$SIGN_DIR/allowed_signers"

cd "$REPO"
git init -q -b main
git config user.name  "governance-bot"
git config user.email "governance-bot@stoa.local"
git config gpg.format ssh
git config user.signingkey "$SIGN_DIR/governance_signing"
git config commit.gpgsign true
git config gpg.ssh.allowedSignersFile "$SIGN_DIR/allowed_signers"

# --- arborescence -------------------------------------------------------------
mkdir -p tenants/banking-demo/apis/{customer-referential,accounts-read,payments-initiation} \
         subscriptions/banking-demo promotions/banking-demo \
         evidence/banking-demo evidence/denials \
         environments/{dev,staging,production}

cat > tenants/banking-demo/tenant.yaml <<'EOF'
apiVersion: stoa.io/v1
kind: Tenant
metadata:
  name: banking-demo
  displayName: "Banking Demo (EU regulated)"
  tier: enterprise
spec:
  status: active
  compliance: [dora, gdpr, iso_27001]
  contacts:
    owner: alice@bc.example
EOF

# --- contrat 1 : référentiel client (lecture, H, publié) ----------------------
cat > tenants/banking-demo/apis/customer-referential/api.yaml <<'EOF'
name: customer-referential
version: 1.2.0
tenant_id: banking-demo
display_name: "Référentiel Client"
description: "Consultation du référentiel client (lecture seule)."
classification: H
status: published
required_policies: [oauth2, rate-limit-standard]
endpoints:
  - path: /customers/{id}
    methods: [GET]
    backend_url: http://microcks:8080/rest/customer-referential/1.2.0
    operation_id: getCustomer
    llm:
      summary: "Lire la fiche d'un client"
      intent: "Consulter les informations d'un client par identifiant"
      tool_name: customer_get
      side_effects: read
      safe_for_agents: true
      requires_human_approval: false
      examples:
        - input: { id: "C-1001" }
  - path: /customers
    methods: [GET]
    backend_url: http://microcks:8080/rest/customer-referential/1.2.0
    operation_id: listCustomers
EOF

# --- contrat 2 : comptes (lecture, H, publié — l'API du PoC fédération) -------
cat > tenants/banking-demo/apis/accounts-read/api.yaml <<'EOF'
name: accounts-read
version: 1.0.0
tenant_id: banking-demo
display_name: "Comptes — consultation"
description: "Consultation des comptes et soldes. Contrat fédéré sur WSO2 / APISIX / webMethods (PoC)."
classification: H
status: published
required_policies: [oauth2, rate-limit-standard]
endpoints:
  - path: /accounts
    methods: [GET]
    backend_url: http://microcks:8080/rest/accounts-read/1.0.0
    operation_id: listAccounts
  - path: /accounts/{iban}/balance
    methods: [GET]
    backend_url: http://microcks:8080/rest/accounts-read/1.0.0
    operation_id: getBalance
    llm:
      summary: "Lire le solde d'un compte"
      intent: "Obtenir le solde courant d'un compte par IBAN"
      tool_name: account_balance
      side_effects: read
      safe_for_agents: true
      requires_human_approval: false
      examples:
        - input: { iban: "FR7630001007941234567890185" }
EOF

# --- contrat 3 : initiation de paiement (VH, draft, endpoint destructif) ------
cat > tenants/banking-demo/apis/payments-initiation/api.yaml <<'EOF'
name: payments-initiation
version: 0.3.0
tenant_id: banking-demo
display_name: "Initiation de paiement"
description: "Initiation et annulation d'ordres de paiement. Classification VH (sommet de l'échelle client) — endpoint destructif sous approbation humaine."
classification: VH
status: draft
required_policies: [oauth2, mtls, rate-limit-strict, audit-full]
endpoints:
  - path: /payments
    methods: [POST]
    backend_url: http://microcks:8080/rest/payments/0.3.0
    operation_id: initiatePayment
    llm:
      summary: "Initier un ordre de paiement"
      intent: "Créer un ordre de paiement SEPA"
      tool_name: payment_initiate
      side_effects: write
      safe_for_agents: false
      requires_human_approval: true
      examples:
        - input: { iban_debtor: "FR76…", iban_creditor: "DE89…", amount: 125.00, currency: EUR }
  - path: /payments/{id}
    methods: [DELETE]
    backend_url: http://microcks:8080/rest/payments/0.3.0
    operation_id: cancelPayment
    llm:
      summary: "Annuler un ordre de paiement"
      intent: "Annuler un ordre de paiement avant exécution"
      tool_name: payment_cancel
      side_effects: destructive
      safe_for_agents: false
      requires_human_approval: true
      examples:
        - input: { id: "PAY-2026-00042" }
EOF

# --- desired state par environnement ------------------------------------------
cat > tenants/banking-demo/apis/customer-referential/deploy.dev.yaml <<'EOF'
version: 1.2.0
enabled: true
promoted_by: alice
message: "Mise à disposition initiale en dev"
EOF
cat > tenants/banking-demo/apis/accounts-read/deploy.dev.yaml <<'EOF'
version: 1.0.0
enabled: true
promoted_by: alice
message: "Dev — contrat fédéré PoC"
EOF
cat > tenants/banking-demo/apis/accounts-read/deploy.staging.yaml <<'EOF'
version: 1.0.0
enabled: true
promoted_by: bob
message: "Promotion staging validée (chaîne dev→staging)"
EOF

for env in dev staging production; do
  cat > environments/$env/config.yaml <<EOF
name: $env
write_mode: $( [ "$env" = "dev" ] && echo direct || echo pull_request )
approvers_required: $( [ "$env" = "production" ] && echo 1 || echo 0 )
EOF
done

# --- souscriptions (file d'approbation) ---------------------------------------
cat > subscriptions/banking-demo/sub-001.yaml <<'EOF'
id: sub-001
tenant: banking-demo
api: accounts-read
consumer: treasury-app
requested_by: carol@bc.example
status: pending
created_at: "2026-06-09T14:12:00Z"
EOF
cat > subscriptions/banking-demo/sub-002.yaml <<'EOF'
id: sub-002
tenant: banking-demo
api: customer-referential
consumer: crm-sync
requested_by: alice@bc.example
status: active
created_at: "2026-06-02T09:30:00Z"
EOF
cat > subscriptions/banking-demo/sub-003.yaml <<'EOF'
id: sub-003
tenant: banking-demo
api: customer-referential
consumer: partner-onboarding
requested_by: carol@bc.example
status: pending
created_at: "2026-06-10T08:05:00Z"
EOF

touch evidence/banking-demo/.keep promotions/banking-demo/.keep
printf '' > evidence/denials/denials.jsonl

cat > README.md <<'EOF'
# Repo de gouvernance (démo Console Light)
Source de vérité : contrats UAC, desired-state par environnement, souscriptions, évidence.
Écritures EXCLUSIVEMENT via la Console Light / labctl (commits signés). Push direct interdit.
EOF

git add -A
git commit -q -S -m "gov(banking-demo): seed initial du repo de gouvernance

Action: seed
Resource: banking-demo/*
Actor: governance-bot
Roles: system
Evidence: —"

say "Repo de gouvernance seedé : $REPO"
git log --format='  %h %G? %s' | head -5
