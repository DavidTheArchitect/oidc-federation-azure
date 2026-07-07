<#
.SYNOPSIS
    Configures Keycloak for Azure workload identity federation (idempotent).

.DESCRIPTION
    Uses the Keycloak Admin REST API to:
      1. Create the realm (short access-token lifetime).
      2. Create a confidential client with only the service-account
         (client_credentials) flow enabled.
      3. Add a hardcoded-audience protocol mapper so access tokens carry
         aud=api://AzureADTokenExchange (required by the federated credential).
      4. Read the service-account user's UUID - this is the token's `sub`
         claim and must be used verbatim as the federated credential subject.

    Outputs a PSCustomObject: Issuer, ClientId, ClientSecret, Subject.

.EXAMPLE
    ./bootstrap-keycloak.ps1 -KeycloakUrl https://keycloak-oidcfed.<region>.azurecontainerapps.io -AdminPassword $pwd
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KeycloakUrl,
    [string]$AdminUser = 'admin',
    [Parameter(Mandatory)][string]$AdminPassword,
    [string]$Realm = 'azure',
    [string]$ClientId = 'azure-federation',
    [string]$Audience = 'api://AzureADTokenExchange'
)

$ErrorActionPreference = 'Stop'
$KeycloakUrl = $KeycloakUrl.TrimEnd('/')

Write-Host "Requesting Keycloak admin token from $KeycloakUrl ..."
$token = Invoke-RestMethod -Method Post `
    -Uri "$KeycloakUrl/realms/master/protocol/openid-connect/token" `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body @{
        grant_type = 'password'
        client_id  = 'admin-cli'
        username   = $AdminUser
        password   = $AdminPassword
    }
$headers = @{ Authorization = "Bearer $($token.access_token)" }
$adminBase = "$KeycloakUrl/admin/realms"

function Test-KcResource {
    param([string]$Uri)
    try {
        Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers | Out-Null
        return $true
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $false }
        throw
    }
}

# 1. Realm
if (Test-KcResource "$adminBase/$Realm") {
    Write-Host "Realm '$Realm' already exists."
} else {
    Write-Host "Creating realm '$Realm' ..."
    Invoke-RestMethod -Method Post -Uri $adminBase -Headers $headers `
        -ContentType 'application/json' -Body (@{
            realm               = $Realm
            enabled             = $true
            accessTokenLifespan = 300   # short-lived assertions for Entra
        } | ConvertTo-Json) | Out-Null
}

# 2. Client (confidential, service accounts only)
# (the trailing Write-Output enumerates the response, so an empty JSON array
# really becomes an empty PowerShell array instead of one wrapped [] element)
$clients = @(Invoke-RestMethod -Method Get -Headers $headers `
    -Uri "$adminBase/$Realm/clients?clientId=$ClientId" | Write-Output)
if ($clients.Count -eq 0) {
    Write-Host "Creating client '$ClientId' ..."
    Invoke-RestMethod -Method Post -Uri "$adminBase/$Realm/clients" -Headers $headers `
        -ContentType 'application/json' -Body (@{
            clientId                  = $ClientId
            protocol                  = 'openid-connect'
            publicClient              = $false
            serviceAccountsEnabled    = $true
            standardFlowEnabled       = $false
            implicitFlowEnabled       = $false
            directAccessGrantsEnabled = $false
        } | ConvertTo-Json) | Out-Null
    $clients = @(Invoke-RestMethod -Method Get -Headers $headers `
        -Uri "$adminBase/$Realm/clients?clientId=$ClientId" | Write-Output)
} else {
    Write-Host "Client '$ClientId' already exists."
}
$clientUuid = $clients[0].id

# Client secret (generate if the client has none yet)
$secret = $null
try {
    $secret = (Invoke-RestMethod -Method Get -Headers $headers `
        -Uri "$adminBase/$Realm/clients/$clientUuid/client-secret").value
} catch { }
if (-not $secret) {
    $secret = (Invoke-RestMethod -Method Post -Headers $headers `
        -Uri "$adminBase/$Realm/clients/$clientUuid/client-secret").value
}

# 3. Hardcoded audience mapper -> aud: api://AzureADTokenExchange
$mapperName = 'azure-token-exchange-audience'
$mappers = @(Invoke-RestMethod -Method Get -Headers $headers `
    -Uri "$adminBase/$Realm/clients/$clientUuid/protocol-mappers/models" | Write-Output)
if ($mappers | Where-Object { $_.name -eq $mapperName }) {
    Write-Host "Audience mapper already present."
} else {
    Write-Host "Adding audience mapper ($Audience) ..."
    Invoke-RestMethod -Method Post -Headers $headers `
        -Uri "$adminBase/$Realm/clients/$clientUuid/protocol-mappers/models" `
        -ContentType 'application/json' -Body (@{
            name           = $mapperName
            protocol       = 'openid-connect'
            protocolMapper = 'oidc-audience-mapper'
            config         = @{
                'included.custom.audience' = $Audience
                'access.token.claim'       = 'true'
                'id.token.claim'           = 'false'
            }
        } | ConvertTo-Json) | Out-Null
}

# 4. The service-account user's UUID is the `sub` claim of client_credentials
#    tokens and must exactly (case-sensitively) match the FIC subject.
$serviceAccountUser = Invoke-RestMethod -Method Get -Headers $headers `
    -Uri "$adminBase/$Realm/clients/$clientUuid/service-account-user"

$result = [PSCustomObject]@{
    Issuer       = "$KeycloakUrl/realms/$Realm"
    ClientId     = $ClientId
    ClientSecret = $secret
    Subject      = $serviceAccountUser.id
}
Write-Host "Keycloak bootstrap complete. Issuer: $($result.Issuer)  Subject: $($result.Subject)"
$result
