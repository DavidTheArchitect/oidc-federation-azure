<#
.SYNOPSIS
    One-shot deployment of the self-hosted OIDC provider (Keycloak + Caddy on
    Azure Container Apps) federated with a user-assigned managed identity.

.DESCRIPTION
    Orchestrates the full flow:
      1. Preflight: az login check, subscription selection, provider registration.
      2. Bicep deployment (resource group, Container Apps env, PostgreSQL,
         Keycloak+Caddy app, managed identity + RBAC, demo storage).
      3. Wait for Keycloak's OIDC discovery endpoint to come up.
      4. Bootstrap the realm/client/audience mapper (bootstrap-keycloak.ps1).
      5. Create the federated identity credential (create-federation.ps1).
      6. Upload the demo blob and lock down the admin surface.
      7. Run the end-to-end federation test (test-federation.ps1).
      8. Write resolved values to ../.env for the samples and test script.

    Re-runnable: passwords are reused from an existing .env, and every step is
    idempotent, so a partial failure can be retried by running it again.

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

$providers = 'Microsoft.App', 'Microsoft.OperationalInsights',
             'Microsoft.DBforPostgreSQL', 'Microsoft.ManagedIdentity', 'Microsoft.Storage'
foreach ($ns in $providers) {
    $state = az provider show --namespace $ns --query registrationState --output tsv 2>$null
    if ($state -ne 'Registered') {
        Write-Host "Registering resource provider $ns ..."
        az provider register --namespace $ns --wait --output none
    }
}

# Reuse passwords from a previous run: the Keycloak admin password only takes
# effect on first boot (it lives in the database afterwards), so regenerating
# it on a re-run would lock the bootstrap script out.
$existingEnv = Read-EnvFile $envFile
$kcAdminPassword = if ($existingEnv['KC_ADMIN_PASSWORD']) { $existingEnv['KC_ADMIN_PASSWORD'] } else { New-RandomPassword }
$pgPassword      = if ($existingEnv['POSTGRES_PASSWORD']) { $existingEnv['POSTGRES_PASSWORD'] } else { New-RandomPassword }

# --- 2. Bicep deployment ------------------------------------------------------
Write-Host "`n== Bicep deployment (this can take ~10 minutes on first run) =="
$deploymentName = "oidc-federation-$(Get-Date -Format 'yyyyMMddHHmmss')"
$templateFile = Join-Path $PSScriptRoot '..' 'infra' 'main.bicep'
$deployment = az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters location=$Location baseName=$BaseName adminLockdown=false `
                 keycloakAdminPassword=$kcAdminPassword `
                 postgresAdminPassword=$pgPassword `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $deployment) { throw 'Bicep deployment failed.' }

$outputs = $deployment.properties.outputs
$fqdn            = $outputs.keycloakFqdn.value
$resourceGroup   = $outputs.resourceGroupName.value
$containerApp    = $outputs.containerAppName.value
$identityName    = $outputs.identityName.value
$identityClient  = $outputs.identityClientId.value
$storageAccount  = $outputs.storageAccountName.value
$tenantId        = $outputs.tenantId.value
$keycloakUrl     = "https://$fqdn"
Write-Host "Keycloak public URL: $keycloakUrl"

# --- 3. Wait for Keycloak readiness -------------------------------------------
Write-Host "`n== Waiting for Keycloak OIDC discovery endpoint =="
$discoveryUrl = "$keycloakUrl/realms/master/.well-known/openid-configuration"
$deadline = (Get-Date).AddMinutes(15)
while ($true) {
    try {
        Invoke-RestMethod -Method Get -Uri $discoveryUrl -TimeoutSec 10 | Out-Null
        Write-Host 'Keycloak is up.'
        break
    } catch {
        if ((Get-Date) -gt $deadline) {
            throw "Keycloak did not become ready within 15 minutes. Check logs: az containerapp logs show -n $containerApp -g $resourceGroup --container keycloak"
        }
        Write-Host '  ... not ready yet, retrying in 15s'
        Start-Sleep -Seconds 15
    }
}

# --- 4. Bootstrap realm / client / audience mapper ----------------------------
Write-Host "`n== Bootstrapping Keycloak realm '$Realm' =="
$bootstrap = & (Join-Path $PSScriptRoot 'bootstrap-keycloak.ps1') `
    -KeycloakUrl $keycloakUrl `
    -AdminPassword $kcAdminPassword `
    -Realm $Realm `
    -ClientId $KeycloakClientId

# --- 5. Federated identity credential ------------------------------------------
Write-Host "`n== Creating federated identity credential =="
& (Join-Path $PSScriptRoot 'create-federation.ps1') `
    -IdentityName $identityName `
    -ResourceGroup $resourceGroup `
    -Issuer $bootstrap.Issuer `
    -Subject $bootstrap.Subject

# --- 6a. Demo blob for the data-plane test ------------------------------------
Write-Host "`n== Uploading demo blob =="
$blobFile = New-TemporaryFile
Set-Content -Path $blobFile -Value 'Hello from the Azure data plane, via your own OIDC provider!' -NoNewline
az storage blob upload --account-name $storageAccount --container-name demo `
    --name hello.txt --file $blobFile --auth-mode key --overwrite --output none
Remove-Item $blobFile -Force
if ($LASTEXITCODE -ne 0) { throw 'Demo blob upload failed.' }

# --- 6b. Lock down the public admin surface ------------------------------------
Write-Host "`n== Locking down /admin, master realm, and /metrics (Caddy) =="
az containerapp update --name $containerApp --resource-group $resourceGroup `
    --container-name caddy --set-env-vars CADDY_ADMIN_LOCKDOWN=true --output none
if ($LASTEXITCODE -ne 0) { throw 'Failed to enable admin lockdown.' }
Write-Host 'Lockdown enabled. To administer Keycloak later, temporarily disable it with:'
Write-Host "  az containerapp update -n $containerApp -g $resourceGroup --container-name caddy --set-env-vars CADDY_ADMIN_LOCKDOWN=false"

# --- 8. Persist resolved configuration -----------------------------------------
# (written before the test so a failed test run can be retried standalone)
@"
# Generated by deploy.ps1 on $(Get-Date -Format o). Do not commit (gitignored).
AZURE_TENANT_ID=$tenantId
AZURE_SUBSCRIPTION_ID=$($account.id)
AZURE_RESOURCE_GROUP=$resourceGroup
AZURE_UAMI_CLIENT_ID=$identityClient
KEYCLOAK_URL=$keycloakUrl
KEYCLOAK_REALM=$Realm
KEYCLOAK_CLIENT_ID=$KeycloakClientId
KEYCLOAK_CLIENT_SECRET=$($bootstrap.ClientSecret)
KC_ADMIN_PASSWORD=$kcAdminPassword
POSTGRES_PASSWORD=$pgPassword
DEMO_STORAGE_ACCOUNT=$storageAccount
DEMO_BLOB_CONTAINER=demo
DEMO_BLOB_NAME=hello.txt
"@ | Set-Content -Path $envFile
Write-Host "`nConfiguration written to $envFile"

# --- 7. End-to-end verification -------------------------------------------------
if (-not $SkipTest) {
    Write-Host "`n== Running end-to-end federation test =="
    & (Join-Path $PSScriptRoot 'test-federation.ps1') -EnvFile $envFile
}

Write-Host "`nDone. Issuer: $($bootstrap.Issuer)"
