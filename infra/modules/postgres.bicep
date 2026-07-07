// Azure Database for PostgreSQL Flexible Server for Keycloak persistence.
// Lab-appropriate: public access with the "allow Azure services" firewall
// rule. Hardening path: VNet-integrate the Container Apps environment and the
// server, then remove the firewall rule (see README).
param location string
param baseName string
param administratorLogin string = 'keycloak'
@secure()
param administratorPassword string

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: 'psql-${baseName}-${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    storage: {
      storageSizeGB: 32
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: server
  name: 'keycloak'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// 0.0.0.0-0.0.0.0 is the special "allow access from Azure services" rule.
resource allowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: server
  name: 'AllowAllAzureServicesAndResources'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

output serverFqdn string = server.properties.fullyQualifiedDomainName
output administratorLogin string = administratorLogin
