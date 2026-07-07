<#
.SYNOPSIS
    End-to-end proof of the federation: Keycloak token -> Entra access token
    -> ARM control plane -> Blob data plane. Prints PASS/FAIL per step.

.DESCRIPTION
    Parameters default from ../.env (written by deploy.ps1). Entra-side steps
    retry for a few minutes because federated credentials and RBAC role
    assignments can take a short while to propagate after creation.
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..' '.env'),
    [string]$KeycloakUrl,
    [string]$Realm,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$TenantId,
    [string]$UamiClientId,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$StorageAccount,
    [string]$TestUsername,
    [string]$TestUserPassword,
    [string]$BlobContainer = 'demo',
    [string]$BlobName = 'hello.txt',
    [int]$MaxAttempts = 12,
    [int]$RetryDelaySeconds = 20
)

$ErrorActionPreference = 'Stop'

# Fill unset parameters from .env
if (Test-Path $EnvFile) {
    $envMap = @{}
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $envMap[$Matches[1]] = $Matches[2].Trim('"')
        }
    }
    if (-not $KeycloakUrl)    { $KeycloakUrl    = $envMap['KEYCLOAK_URL'] }
    if (-not $Realm)          { $Realm          = $envMap['KEYCLOAK_REALM'] }
    if (-not $ClientId)       { $ClientId       = $envMap['KEYCLOAK_CLIENT_ID'] }
    if (-not $ClientSecret)   { $ClientSecret   = $envMap['KEYCLOAK_CLIENT_SECRET'] }
    if (-not $TenantId)       { $TenantId       = $envMap['AZURE_TENANT_ID'] }
    if (-not $UamiClientId)   { $UamiClientId   = $envMap['AZURE_UAMI_CLIENT_ID'] }
    if (-not $SubscriptionId) { $SubscriptionId = $envMap['AZURE_SUBSCRIPTION_ID'] }
    if (-not $ResourceGroup)  { $ResourceGroup  = $envMap['AZURE_RESOURCE_GROUP'] }
    if (-not $StorageAccount) { $StorageAccount = $envMap['DEMO_STORAGE_ACCOUNT'] }
    if (-not $TestUsername)     { $TestUsername     = $envMap['KEYCLOAK_TEST_USERNAME'] }
    if (-not $TestUserPassword) { $TestUserPassword = $envMap['KEYCLOAK_TEST_USER_PASSWORD'] }
}
foreach ($required in 'KeycloakUrl', 'Realm', 'ClientId', 'ClientSecret', 'TenantId',
                      'UamiClientId', 'SubscriptionId', 'ResourceGroup', 'StorageAccount') {
    if (-not (Get-Variable $required -ValueOnly)) {
        throw "Missing value for -$required (pass it or run deploy.ps1 to produce .env)."
    }
}
$KeycloakUrl = $KeycloakUrl.TrimEnd('/')

function ConvertFrom-JwtPayload {
    param([string]$Jwt)
    $payload = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function Invoke-WithRetry {
    param([string]$Label, [scriptblock]$Action)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Action
        } catch {
            if ($attempt -eq $MaxAttempts) { throw }
            Write-Host "  $Label failed (attempt $attempt/$MaxAttempts): $($_.Exception.Message)"
            Write-Host "  Retrying in $RetryDelaySeconds s (FIC/RBAC propagation can take a few minutes) ..."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

$failed = $false
function Report {
    param([string]$Step, [bool]$Ok, [string]$Detail = '')
    $mark = if ($Ok) { 'PASS' } else { 'FAIL'; $script:failed = $true }
    Write-Host ("[{0}] {1} {2}" -f $mark, $Step, $Detail)
}

# --- Step 1: mint a Keycloak token (client_credentials) ---------------------
$kcToken = $null
try {
    $kcResponse = Invoke-RestMethod -Method Post `
        -Uri "$KeycloakUrl/realms/$Realm/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            grant_type    = 'client_credentials'
            client_id     = $ClientId
            client_secret = $ClientSecret
        }
    $kcToken = $kcResponse.access_token
    $claims = ConvertFrom-JwtPayload $kcToken
    Report 'Keycloak token minted' $true "(iss=$($claims.iss) sub=$($claims.sub) aud=$($claims.aud))"
} catch {
    Report 'Keycloak token minted' $false $_.Exception.Message
    exit 1
}

# --- Step 2/3: exchange for Entra tokens (ARM + Storage scopes) -------------
function Get-EntraToken {
    param([string]$Scope, [string]$Assertion = $kcToken)
    (Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            grant_type            = 'client_credentials'
            client_id             = $UamiClientId
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion      = $Assertion
            scope                 = $Scope
        }).access_token
}

$armToken = $null
try {
    $armToken = Invoke-WithRetry 'Entra token exchange (ARM)' {
        Get-EntraToken 'https://management.azure.com/.default'
    }
    Report 'Entra token exchange (control plane scope)' $true
} catch {
    Report 'Entra token exchange (control plane scope)' $false $_.Exception.Message
}

# --- Step 4: control plane - read the resource group via ARM ----------------
if ($armToken) {
    try {
        $rg = Invoke-WithRetry 'ARM GET resource group' {
            Invoke-RestMethod -Method Get `
                -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$($ResourceGroup)?api-version=2021-04-01" `
                -Headers @{ Authorization = "Bearer $armToken" }
        }
        Report 'Control plane: ARM GET resource group' $true "($($rg.id))"
    } catch {
        Report 'Control plane: ARM GET resource group' $false $_.Exception.Message
    }
}

# --- Step 5: data plane - read the demo blob ---------------------------------
try {
    # The Keycloak assertion is single-audience but multi-use within its
    # lifetime; mint a second Entra token for the storage resource.
    $storageToken = Invoke-WithRetry 'Entra token exchange (Storage)' {
        Get-EntraToken 'https://storage.azure.com/.default'
    }
    $blob = Invoke-WithRetry 'Blob read' {
        Invoke-RestMethod -Method Get `
            -Uri "https://$StorageAccount.blob.core.windows.net/$BlobContainer/$BlobName" `
            -Headers @{
                Authorization  = "Bearer $storageToken"
                'x-ms-version' = '2021-08-06'
            }
    }
    Report 'Data plane: blob content read' $true "($blob)"
} catch {
    Report 'Data plane: blob content read' $false $_.Exception.Message
}

# --- Step 6/7: test-user flow (password grant -> Entra -> control plane) -----
# Proves the second federated credential (subject = test user's UUID). Skipped
# only if no test-user credentials are configured.
if ($TestUsername -and $TestUserPassword) {
    $userToken = $null
    try {
        $userResponse = Invoke-RestMethod -Method Post `
            -Uri "$KeycloakUrl/realms/$Realm/protocol/openid-connect/token" `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{
                grant_type    = 'password'
                client_id     = $ClientId
                client_secret = $ClientSecret
                username      = $TestUsername
                password      = $TestUserPassword
                scope         = 'openid'
            }
        $userToken = $userResponse.access_token
        $userClaims = ConvertFrom-JwtPayload $userToken
        Report 'Keycloak test-user token minted' $true "(sub=$($userClaims.sub) preferred_username=$($userClaims.preferred_username))"
    } catch {
        Report 'Keycloak test-user token minted' $false $_.Exception.Message
    }

    if ($userToken) {
        try {
            $userArmToken = Invoke-WithRetry 'Entra token exchange (test user)' {
                Get-EntraToken 'https://management.azure.com/.default' $userToken
            }
            $rg = Invoke-WithRetry 'ARM GET (test user)' {
                Invoke-RestMethod -Method Get `
                    -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$($ResourceGroup)?api-version=2021-04-01" `
                    -Headers @{ Authorization = "Bearer $userArmToken" }
            }
            Report 'Test user: exchange + control plane ARM GET' $true "($($rg.id))"
        } catch {
            Report 'Test user: exchange + control plane ARM GET' $false $_.Exception.Message
        }
    }
} else {
    Write-Host '[SKIP] test-user flow (no KEYCLOAK_TEST_USERNAME/PASSWORD configured)'
}

if ($failed) {
    Write-Host "`nOne or more federation checks FAILED."
    exit 1
}
Write-Host "`nAll federation checks passed: your Keycloak issuer can act as the managed identity."
