using 'main.bicep'

param location = 'eastus2'
param baseName = 'oidcfed'

// The three secrets (keycloakAdminPassword, postgresAdminPassword,
// keycloakClientSecret) are intentionally NOT set here: the Bicep deployment
// GUI and the CLI prompt for missing secure parameters, and
// scripts/deploy.ps1 passes generated values on the command line. Pick
// 16+ character values; the PostgreSQL password additionally needs characters
// from at least three categories (upper/lower/digits qualify).
