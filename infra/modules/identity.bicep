// User-assigned managed identity that external workloads will "become" via
// workload identity federation, plus the minimal RBAC grants used by the
// end-to-end test:
//   - Reader on this resource group        -> control-plane proof (ARM GET)
//   - Storage Blob Data Reader on storage  -> data-plane proof (blob read)
// The federated identity credential itself lives in modules/federation.bicep
// and is created after the bootstrap deploymentScript has run, because the
// FIC subject must exactly match the service-account UUID Keycloak generates.
param location string
param baseName string
param storageAccountName string

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${baseName}-federation'
  location: location
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource readerOnResourceGroup 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identity.id, readerRoleId)
  scope: resourceGroup()
  properties: {
    principalId: identity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource blobReaderOnDemoStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, storageBlobDataReaderRoleId)
  scope: storage
  properties: {
    principalId: identity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    principalType: 'ServicePrincipal'
  }
}

output identityName string = identity.name
output clientId string = identity.properties.clientId
output principalId string = identity.properties.principalId
