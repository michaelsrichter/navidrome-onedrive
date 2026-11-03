$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $repoRoot '.deployment.local.json'

if (-not (Test-Path $statePath)) {
    throw 'Deployment state was not found. Run scripts/deploy.ps1 first.'
}

$state = Get-Content $statePath -Raw | ConvertFrom-Json
$fqdn = (& az containerapp show --name $state.containerAppName --resource-group $state.resourceGroupName --query properties.configuration.ingress.fqdn --output tsv).Trim()
if ($LASTEXITCODE -ne 0 -or -not $fqdn) {
    throw 'Could not determine the Container App hostname.'
}

$verificationId = (& az containerapp show --name $state.containerAppName --resource-group $state.resourceGroupName --query properties.customDomainVerificationId --output tsv).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Could not determine the custom-domain verification ID.'
}

Write-Host "In Namecheap > Domain List > mikerichter.app > Advanced DNS, add:"
Write-Host ''
Write-Host "Type: CNAME   Host: music        Value: $fqdn"
Write-Host "Type: TXT     Host: asuid.music  Value: $verificationId"
Write-Host ''
Write-Host 'After both records resolve publicly, run scripts/bind-domain.ps1.'
