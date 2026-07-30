# Console Light — IHM de gouvernance (RBAC sur Git)

> Cadrage : `CADRAGE.md` · Contrat d'API : `API-CONTRACT.md` · Journal : `SESSION-LOG.md`

Chaque action validée dans l'IHM = **commit Git signé + évidence**. L'exécution vers les gateways passe par la CI (webhook → Jenkins → labctl), jamais par la console.

## Démarrage (dev)

```bash
# 1. Identité (Keycloak + Dex du PoC — recreate pour réimporter le realm si déjà créé)
cd ../poc-control-plane-federation
docker compose -f docker-compose.poc.yml up -d --force-recreate dex keycloak

# 2. Repo de gouvernance (git local + signature SSH + seed banking-demo)
cd ../console-light
bash scripts/seed-governance-repo.sh

# 3. BFF gouvernance (Go, stdlib only — module labctl)
cd ../poc-control-plane-federation/labctl
GOVERNANCE_REPO="$(cd ../../console-light/var/governance-repo && pwd)" \
  go run ./cmd/governance-api

# 4. UI (Vite, port 5173)
cd ../../console-light/ui
npm install && npm run dev

# 5. Premier login des 4 personas (crée les users fédérés), puis rôles :
bash ../scripts/setup-identity.sh   # re-jouer après le premier login de chaque persona

# 6. Tests navigateur + captures
cd ui && npx playwright test
```

Personas (mot de passe Dex : `password`) : alice (fournisseur, tenant-admin) · bob (approbateur, devops) · carol (auditrice, viewer) · dave (admin plateforme, cpi-admin).

## Arborescence

```
console-light/
├── CADRAGE.md / API-CONTRACT.md / SESSION-LOG.md
├── schema/uac_contract_v1_schema.json   # schéma canonique (copie carrière)
├── scripts/                             # seed repo + provisioning identité
├── ui/                                  # React + Vite + @stoa/shared vendorisé
├── var/governance-repo                  # source de vérité Git (généré, non versionné)
└── var/signing                          # clé SSH de signature (générée)
```

Le BFF vit dans le module Go labctl : `../poc-control-plane-federation/labctl/cmd/governance-api/`.
