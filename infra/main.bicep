// Self-hosted OIDC provider (Keycloak + Caddy sidecar) on Azure Container
// Apps, federated with a user-assigned managed identity.
//
// Deploy (normally via scripts/deploy.ps1):
//   az deployment sub create --location <location> --template-file main.bicep \
//     --parameters keycloakAdminPassword=... postgresAdminPassword=...
targetScope = 'subscription'

param location string = 'eastus2'
@minLength(3)
@maxLength(16)
param baseName string = 'oidcfed'
param resourceGroupName string = 'rg-${baseName}'
@secure()
param keycloakAdminPassword string
@secure()
param postgresAdminPassword string
param keycloakImage string = 'quay.io/keycloak/keycloak:26.3'
// false on first deploy so the bootstrap script can reach the admin API;
// deploy.ps1 flips it to true afterwards.
param adminLockdown bool = false

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module networkLogs 'modules/network-logs.bicep' = {
  name: 'network-logs'
  scope: rg
  params: {
    location: location
    baseName: baseName
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  scope: rg
  params: {
    location: location
    baseName: baseName
    administratorPassword: postgresAdminPassword
  }
}

module storageDemo 'modules/storage-demo.bicep' = {
  name: 'storage-demo'
  scope: rg
  params: {
    location: location
    baseName: baseName
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  scope: rg
  params: {
    location: location
    baseName: baseName
    storageAccountName: storageDemo.outputs.storageAccountName
  }
}

module keycloakApp 'modules/keycloak-app.bicep' = {
  name: 'keycloak-app'
  scope: rg
  params: {
    location: location
    appName: 'keycloak-${baseName}'
    environmentId: networkLogs.outputs.environmentId
    environmentDefaultDomain: networkLogs.outputs.defaultDomain
    keycloakImage: keycloakImage
    postgresFqdn: postgres.outputs.serverFqdn
    postgresLogin: postgres.outputs.administratorLogin
    postgresPassword: postgresAdminPassword
    keycloakAdminPassword: keycloakAdminPassword
    adminLockdown: adminLockdown
  }
}

output resourceGroupName string = rg.name
output keycloakFqdn string = keycloakApp.outputs.fqdn
output containerAppName string = 'keycloak-${baseName}'
output identityName string = identity.outputs.identityName
output identityClientId string = identity.outputs.clientId
output identityPrincipalId string = identity.outputs.principalId
output storageAccountName string = storageDemo.outputs.storageAccountName
output blobEndpoint string = storageDemo.outputs.blobEndpoint
output tenantId string = tenant().tenantId
