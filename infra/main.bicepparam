using 'main.bicep'

param location = 'eastus2'
param baseName = 'oidcfed'

// Secrets are supplied on the command line by scripts/deploy.ps1; the
// environment-variable fallback lets you deploy the template directly.
param keycloakAdminPassword = readEnvironmentVariable('KC_ADMIN_PASSWORD', '')
param postgresAdminPassword = readEnvironmentVariable('POSTGRES_PASSWORD', '')
