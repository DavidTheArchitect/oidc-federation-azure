// Federated identity credential on the user-assigned managed identity.
// Lives in its own module because the subject (Keycloak's service-account
// UUID) only exists after the bootstrap deploymentScript has run.
param identityName string
param issuer string
param subject string
param name string = 'keycloak-federation'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource fic 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: name
  properties: {
    issuer: issuer
    subject: subject
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}
