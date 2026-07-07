// Small storage account used only to prove data-plane access with the
// federated token (test-federation.ps1 reads a blob from it).
param location string
param baseName string

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: take('st${replace(baseName, '-', '')}${uniqueString(resourceGroup().id)}', 24)
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource demoContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'demo'
  properties: {
    publicAccess: 'None'
  }
}

output storageAccountName string = storage.name
output blobEndpoint string = storage.properties.primaryEndpoints.blob
