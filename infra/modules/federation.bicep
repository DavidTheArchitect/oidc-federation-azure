// Federated identity credentials on the user-assigned managed identity.
// Lives in its own module because the subjects (Keycloak's service-account
// UUID and the test user's UUID) only exist after the bootstrap
// deploymentScript has run.
//
// Both subjects federate to the SAME managed identity: whichever principal
// obtains a Keycloak token (the service account via client_credentials, or
// the test user via password grant) can act as that identity within its RBAC
// grants. The issuer/audience are identical; only the subject differs, and
// the issuer+subject pair must be unique per credential.
param identityName string
param issuer string
param subject string
param userSubject string
param name string = 'keycloak-federation'
param userName string = 'keycloak-federation-testuser'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource serviceAccountFic 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
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

resource testUserFic 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: userName
  // Two federated credentials cannot be written to the same identity
  // concurrently (409); serialize the second after the first.
  dependsOn: [
    serviceAccountFic
  ]
  properties: {
    issuer: issuer
    subject: userSubject
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}
