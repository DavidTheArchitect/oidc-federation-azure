<#
.SYNOPSIS
    Creates (or updates) the federated identity credential on the
    user-assigned managed identity, establishing trust in the Keycloak issuer.

.DESCRIPTION
    The FIC's issuer/subject/audience must exactly, case-sensitively match the
    iss/sub/aud claims of the Keycloak token being exchanged. A mismatch does
    not error at creation time - the token exchange simply fails later - so
    always pass the values reported by bootstrap-keycloak.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IdentityName,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Issuer,
    [Parameter(Mandatory)][string]$Subject,
    [string]$Name = 'keycloak-federation',
    [string]$Audience = 'api://AzureADTokenExchange'
)

$ErrorActionPreference = 'Stop'

$existing = az identity federated-credential list `
    --identity-name $IdentityName --resource-group $ResourceGroup | ConvertFrom-Json

if ($existing | Where-Object { $_.name -eq $Name }) {
    Write-Host "Federated credential '$Name' exists - updating."
    az identity federated-credential update `
        --name $Name `
        --identity-name $IdentityName `
        --resource-group $ResourceGroup `
        --issuer $Issuer `
        --subject $Subject `
        --audiences $Audience --output none
} else {
    Write-Host "Creating federated credential '$Name' on '$IdentityName' ..."
    az identity federated-credential create `
        --name $Name `
        --identity-name $IdentityName `
        --resource-group $ResourceGroup `
        --issuer $Issuer `
        --subject $Subject `
        --audiences $Audience --output none
}
if ($LASTEXITCODE -ne 0) { throw 'az identity federated-credential failed.' }

Write-Host "Trust established: $Issuer (sub=$Subject) -> $IdentityName"
