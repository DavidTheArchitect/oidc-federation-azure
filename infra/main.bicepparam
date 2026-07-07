using 'main.bicep'

param location = 'eastus2'
param baseName = 'oidcfed'

// The four secrets (keycloakAdminPassword, postgresAdminPassword,
// keycloakClientSecret, keycloakTestUserPassword) are intentionally NOT set
// here: the Bicep deployment GUI and the CLI prompt for missing secure
// parameters, and scripts/deploy.ps1 passes generated values on the command
// line. Pick 16+ character values (12+ for the test-user password); the
// PostgreSQL password additionally needs characters from at least three
// categories (upper/lower/digits qualify).
//
// To provision a different test username, also set:
//   param keycloakTestUsername = 'myuser'
