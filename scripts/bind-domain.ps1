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
if ($LASTEXITCODE -ne 0 -or -not $verificationId) {
    throw 'Could not determine the custom-domain verification ID.'
}

$cname = Resolve-DnsName -Name $state.domain -Type CNAME -ErrorAction SilentlyContinue |
    Where-Object { $_.NameHost } |
    Select-Object -First 1
if (-not $cname -or $cname.NameHost.TrimEnd('.') -ine $fqdn.TrimEnd('.')) {
    throw "DNS for $($state.domain) does not yet point to $fqdn. Add the CNAME and TXT records from scripts/show-domain-records.ps1, wait for propagation, and retry."
}

$txtRecordName = "asuid.$($state.domain)"
$txtValues = Resolve-DnsName -Name $txtRecordName -Type TXT -ErrorAction SilentlyContinue |
    Where-Object { $_.Strings } |
    ForEach-Object { $_.Strings -join '' }
if ($txtValues -notcontains $verificationId) {
    throw "The TXT record '$txtRecordName' is missing or does not match the Azure verification ID. Check scripts/show-domain-records.ps1 and retry after DNS propagation."
}

$existingHostname = (& az containerapp hostname list --name $state.containerAppName --resource-group $state.resourceGroupName --query "[?name=='$($state.domain)'].name | [0]" --output tsv).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Azure could not list the registered hostnames.'
}
if ($existingHostname -ine $state.domain) {
    & az containerapp hostname add --name $state.containerAppName --resource-group $state.resourceGroupName --hostname $state.domain --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure could not add the custom hostname.'
    }
}

& az containerapp hostname bind --name $state.containerAppName --resource-group $state.resourceGroupName --environment $state.environmentName --hostname $state.domain --validation-method CNAME --only-show-errors --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Azure could not bind the managed certificate. Verify the CNAME and TXT records and retry.'
}

Write-Host "Custom hostname and managed certificate requested for https://$($state.domain). Certificate provisioning can take several minutes."
