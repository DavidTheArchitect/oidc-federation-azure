<#
.SYNOPSIS
    Convenience wrapper around the Bicep deployment of the self-hosted OIDC
    provider (Keycloak + Caddy on Azure Container Apps) federated with a
    user-assigned managed identity.

.DESCRIPTION
    The Bicep template (infra/main.bicep) is self-sufficient: an embedded
    deploymentScripts resource bootstraps Keycloak (realm, client, audience
    mapper), uploads the demo blob, re-enables the admin lockdown, and the
    federated identity credential is created from its output. Deploying the
    template through the Bicep extension GUI does everything this script does,
    minus the conveniences this wrapper adds:

      1. Preflight: az login check, subscription selection, provider registration.
      2. Crypto-random secrets, reused from .env on re-runs.
      3. The deployment itself (az deployment sub create).
      4. Writes resolved values to ../.env for the samples and test script.
      5. Runs the end-to-end federation test (test-federation.ps1).

    Re-runnable: secrets are reused from an existing .env and the in-template
    bootstrap is idempotent, so a partial failure can be retried by running
    it again.

.EXAMPLE
    ./deploy.ps1 -Location westeurope -BaseName myoidc
#>
[CmdletBinding()]
param(
    [string]$Location = 'eastus2',
    [ValidatePattern('^[a-z][a-z0-9]{2,15}$')]
    [string]$BaseName = 'oidcfed',
    [string]$Realm = 'azure',
    [string]$KeycloakClientId = 'azure-federation',
    [string]$SubscriptionId,
    [switch]$SkipTest
)

$ErrorActionPreference = 'Stop'
$envFile = Join-Path $PSScriptRoot '..' '.env'

function New-RandomPassword {
    param([int]$Length = 32)
    # Unambiguous alphanumerics; satisfies PostgreSQL complexity (3 categories).
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    -join (1..$Length | ForEach-Object {
        $chars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($chars.Length)]
    })
}

function Read-EnvFile {
    param([string]$Path)
    $map = @{}
    if (Test-Path $Path) {
        foreach ($line in Get-Content $Path) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
                $map[$Matches[1]] = $Matches[2].Trim('"')
            }
        }
    }
    $map
}

# --- 1. Preflight ------------------------------------------------------------
Write-Host '== Preflight =='
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not logged in. Run 'az login' first." }
if ($SubscriptionId -and $account.id -ne $SubscriptionId) {
    az account set --subscription $SubscriptionId
    $account = az account show | ConvertFrom-Json
}
Write-Host "Subscription: $($account.name) ($($account.id))"

# Microsoft.ContainerInstance backs the in-template deploymentScripts resource.
$providers = 'Microsoft.App', 'Microsoft.OperationalInsights',
             'Microsoft.DBforPostgreSQL', 'Microsoft.ManagedIdentity',
             'Microsoft.Storage', 'Microsoft.ContainerInstance'
foreach ($ns in $providers) {
    $state = az provider show --namespace $ns --query registrationState --output tsv 2>$null
    if ($state -ne 'Registered') {
        Write-Host "Registering resource provider $ns ..."
        az provider register --namespace $ns --wait --output none
    }
}

# Reuse secrets from a previous run: the Keycloak admin password only takes
# effect on first boot (it lives in the database afterwards), so regenerating
# it on a re-run would lock the in-template bootstrap out.
$existingEnv = Read-EnvFile $envFile
$kcAdminPassword = if ($existingEnv['KC_ADMIN_PASSWORD']) { $existingEnv['KC_ADMIN_PASSWORD'] } else { New-RandomPassword }
$pgPassword      = if ($existingEnv['POSTGRES_PASSWORD']) { $existingEnv['POSTGRES_PASSWORD'] } else { New-RandomPassword }
$clientSecret    = if ($existingEnv['KEYCLOAK_CLIENT_SECRET']) { $existingEnv['KEYCLOAK_CLIENT_SECRET'] } else { New-RandomPassword }
$testUserPassword = if ($existingEnv['KEYCLOAK_TEST_USER_PASSWORD']) { $existingEnv['KEYCLOAK_TEST_USER_PASSWORD'] } else { New-RandomPassword }
$testUsername    = if ($existingEnv['KEYCLOAK_TEST_USERNAME']) { $existingEnv['KEYCLOAK_TEST_USERNAME'] } else { 'testuser' }

# --- 2. Bicep deployment (includes the in-Azure Keycloak bootstrap) -----------
Write-Host "`n== Bicep deployment (first run takes ~15-20 minutes, including the in-Azure bootstrap) =="
$deploymentName = "oidc-federation-$(Get-Date -Format 'yyyyMMddHHmmss')"
$templateFile = Join-Path $PSScriptRoot '..' 'infra' 'main.bicep'
$deployment = az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters location=$Location baseName=$BaseName `
                 keycloakRealm=$Realm keycloakClientId=$KeycloakClientId `
                 keycloakTestUsername=$testUsername `
                 keycloakAdminPassword=$kcAdminPassword `
                 postgresAdminPassword=$pgPassword `
                 keycloakClientSecret=$clientSecret `
                 keycloakTestUserPassword=$testUserPassword `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $deployment) { throw 'Bicep deployment failed.' }

$outputs = $deployment.properties.outputs
Write-Host "Keycloak issuer: $($outputs.issuer.value)"
Write-Host "Federation subject (service account): $($outputs.federationSubject.value)"
Write-Host "Federation subject (test user): $($outputs.federationUserSubject.value)"

# --- 3. Persist resolved configuration -----------------------------------------
@"
# Generated by deploy.ps1 on $(Get-Date -Format o). Do not commit (gitignored).
AZURE_TENANT_ID=$($outputs.tenantId.value)
AZURE_SUBSCRIPTION_ID=$($account.id)
AZURE_RESOURCE_GROUP=$($outputs.resourceGroupName.value)
AZURE_UAMI_CLIENT_ID=$($outputs.identityClientId.value)
KEYCLOAK_URL=https://$($outputs.keycloakFqdn.value)
KEYCLOAK_REALM=$Realm
KEYCLOAK_CLIENT_ID=$KeycloakClientId
KEYCLOAK_CLIENT_SECRET=$clientSecret
KEYCLOAK_TEST_USERNAME=$testUsername
KEYCLOAK_TEST_USER_PASSWORD=$testUserPassword
KC_ADMIN_PASSWORD=$kcAdminPassword
POSTGRES_PASSWORD=$pgPassword
DEMO_STORAGE_ACCOUNT=$($outputs.storageAccountName.value)
DEMO_BLOB_CONTAINER=demo
DEMO_BLOB_NAME=hello.txt
"@ | Set-Content -Path $envFile
Write-Host "`nConfiguration written to $envFile"

# --- 4. End-to-end verification -------------------------------------------------
if (-not $SkipTest) {
    Write-Host "`n== Running end-to-end federation test =="
    & (Join-Path $PSScriptRoot 'test-federation.ps1') -EnvFile $envFile
}

Write-Host "`nDone. Issuer: $($outputs.issuer.value)"
