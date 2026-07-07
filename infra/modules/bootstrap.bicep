// In-deployment bootstrap: a deploymentScripts resource runs
// infra/scripts/bootstrap.sh inside Azure after the container app is up, so
// a plain Bicep deployment (CLI or the Bicep extension GUI) configures
// Keycloak, uploads the demo blob, and re-enables the admin lockdown without
// any local scripting. Outputs the service-account UUID for the federated
// identity credential.
param location string
param baseName string
param keycloakUrl string
param realm string
param clientId string
@secure()
param keycloakAdminPassword string
@secure()
param keycloakClientSecret string
param testUsername string
@secure()
param testUserPassword string
param storageAccountName string
param containerAppName string
// Changes on every deployment so the (idempotent) script always re-runs -
// each template deploy resets the lockdown to false, and this re-enables it.
param forceUpdateTag string = utcNow()

var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// Dedicated deployer identity: the script needs to update the container app
// (lockdown flip), which the federation identity deliberately cannot do.
resource deployerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${baseName}-deployer'
  location: location
}

resource deployerContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deployerIdentity.id, contributorRoleId)
  scope: resourceGroup()
  properties: {
    principalId: deployerIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource bootstrap 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'bootstrap-keycloak'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deployerIdentity.id}': {}
    }
  }
  dependsOn: [
    deployerContributor
  ]
  properties: {
    azCliVersion: '2.69.0'
    forceUpdateTag: forceUpdateTag
    timeout: 'PT45M'
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
    scriptContent: loadTextContent('../scripts/bootstrap.sh')
    environmentVariables: [
      {
        name: 'KEYCLOAK_URL'
        value: keycloakUrl
      }
      {
        name: 'REALM'
        value: realm
      }
      {
        name: 'CLIENT_ID'
        value: clientId
      }
      {
        name: 'KC_ADMIN_PASSWORD'
        secureValue: keycloakAdminPassword
      }
      {
        name: 'KC_CLIENT_SECRET'
        secureValue: keycloakClientSecret
      }
      {
        name: 'TEST_USERNAME'
        value: testUsername
      }
      {
        name: 'TEST_USER_PASSWORD'
        secureValue: testUserPassword
      }
      {
        name: 'STORAGE_ACCOUNT'
        value: storageAccountName
      }
      {
        name: 'STORAGE_KEY'
        secureValue: storage.listKeys().keys[0].value
      }
      {
        name: 'CONTAINER_APP'
        value: containerAppName
      }
      {
        name: 'RESOURCE_GROUP'
        value: resourceGroup().name
      }
    ]
  }
}

// The `sub` claims that become the two FIC subjects: the service-account
// UUID (client_credentials) and the test user's UUID (password grant).
output subject string = bootstrap.properties.outputs.subject
output userSubject string = bootstrap.properties.outputs.userSubject
