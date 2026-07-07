// Self-hosted OIDC provider (Keycloak + Caddy sidecar) on Azure Container
// Apps, federated with a user-assigned managed identity.
//
// This template is self-sufficient: a deploymentScripts resource performs the
// Keycloak bootstrap in Azure and the federated identity credential is created
// from its output, so deploying main.bicep alone - via the Bicep extension
// GUI, `az deployment sub create`, or scripts/deploy.ps1 - produces a fully
// working federation. You only supply four secrets of your choosing.
targetScope = 'subscription'

param location string = 'eastus2'
@minLength(3)
@maxLength(16)
param baseName string = 'oidcfed'
param resourceGroupName string = 'rg-${baseName}'
@secure()
@minLength(16)
param keycloakAdminPassword string
@secure()
@minLength(16)
param postgresAdminPassword string
// Secret for the Keycloak client external workloads authenticate with. It is
// an input (not Keycloak-generated) so it never appears in deployment outputs.
@secure()
@minLength(16)
param keycloakClientSecret string
param keycloakRealm string = 'azure'
param keycloakClientId string = 'azure-federation'
// A test user provisioned in the realm; its token (password grant) federates
// to the same managed identity via a second federated identity credential.
param keycloakTestUsername string = 'testuser'
@secure()
@minLength(12)
param keycloakTestUserPassword string
param keycloakImage string = 'quay.io/keycloak/keycloak:26.3'
// The app always deploys unlocked so the in-deployment bootstrap script can
// reach the admin REST API; the same script re-enables the lockdown as its
// final step.
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

module bootstrap 'modules/bootstrap.bicep' = {
  name: 'bootstrap'
  scope: rg
  params: {
    location: location
    baseName: baseName
    keycloakUrl: 'https://${keycloakApp.outputs.fqdn}'
    realm: keycloakRealm
    clientId: keycloakClientId
    keycloakAdminPassword: keycloakAdminPassword
    keycloakClientSecret: keycloakClientSecret
    testUsername: keycloakTestUsername
    testUserPassword: keycloakTestUserPassword
    storageAccountName: storageDemo.outputs.storageAccountName
    containerAppName: 'keycloak-${baseName}'
  }
}

module federation 'modules/federation.bicep' = {
  name: 'federation'
  scope: rg
  params: {
    identityName: identity.outputs.identityName
    issuer: 'https://${keycloakApp.outputs.fqdn}/realms/${keycloakRealm}'
    subject: bootstrap.outputs.subject
    userSubject: bootstrap.outputs.userSubject
  }
}

output resourceGroupName string = rg.name
output keycloakFqdn string = keycloakApp.outputs.fqdn
output containerAppName string = 'keycloak-${baseName}'
output issuer string = 'https://${keycloakApp.outputs.fqdn}/realms/${keycloakRealm}'
output keycloakRealm string = keycloakRealm
output keycloakClientId string = keycloakClientId
output keycloakTestUsername string = keycloakTestUsername
output federationSubject string = bootstrap.outputs.subject
output federationUserSubject string = bootstrap.outputs.userSubject
output identityName string = identity.outputs.identityName
output identityClientId string = identity.outputs.clientId
output identityPrincipalId string = identity.outputs.principalId
output storageAccountName string = storageDemo.outputs.storageAccountName
output blobEndpoint string = storageDemo.outputs.blobEndpoint
output tenantId string = tenant().tenantId
