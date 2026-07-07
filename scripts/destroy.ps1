<#
.SYNOPSIS
    Deletes everything the deployment created (a single resource group).

.DESCRIPTION
    The federated identity credential is a child of the user-assigned managed
    identity inside the resource group, so one group delete removes the entire
    trust relationship along with the infrastructure. The local .env is
    removed too so a future deploy generates fresh credentials.
#>
[CmdletBinding()]
param(
    [string]$BaseName = 'oidcfed',
    [string]$ResourceGroup,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $ResourceGroup) { $ResourceGroup = "rg-$BaseName" }

$exists = az group exists --name $ResourceGroup | ConvertFrom-Json
if (-not $exists) {
    Write-Host "Resource group '$ResourceGroup' does not exist - nothing to delete."
    return
}

if (-not $Force) {
    $answer = Read-Host "Delete resource group '$ResourceGroup' and ALL resources in it? (y/N)"
    if ($answer -notin 'y', 'Y', 'yes') {
        Write-Host 'Aborted.'
        return
    }
}

Write-Host "Deleting '$ResourceGroup' (runs in the background) ..."
az group delete --name $ResourceGroup --yes --no-wait
if ($LASTEXITCODE -ne 0) { throw 'az group delete failed.' }

$envFile = Join-Path $PSScriptRoot '..' '.env'
if (Test-Path $envFile) {
    Remove-Item $envFile -Force
    Write-Host 'Removed local .env.'
}
Write-Host "Deletion started. Check status with: az group show --name $ResourceGroup"
