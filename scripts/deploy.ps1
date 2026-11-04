[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-navidrome-onedrive',
    [string]$Location = 'eastus2',
    [switch]$ConfirmDeployment
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $repoRoot '.deployment.local.json'
$imageConfig = Get-Content (Join-Path $repoRoot 'infra\images.json') -Raw | ConvertFrom-Json

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed with exit code $LASTEXITCODE."
    }

    return $result
}

function Get-AzValue {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = Invoke-Az -Arguments $Arguments
    return (($result | Out-String).Trim())
}

function Test-AzResource {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & az @Arguments 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Deactivate-ActiveRevisions {
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    $output = & az containerapp revision list `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --query '[?properties.active].name' `
        --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not list active Container Apps revisions.'
    }

    $revisionText = ($output -join "`n").Trim()
    $revisionNames = $revisionText -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($revisionName in $revisionNames) {
        Write-Host "Deactivating $revisionName to avoid overlapping SQLite writers on Azure Files."
        Invoke-Az -Arguments @(
            'containerapp', 'revision', 'deactivate',
            '--name', $AppName,
            '--resource-group', $ResourceGroupName,
            '--revision', $revisionName,
            '--only-show-errors',
            '--output', 'none'
        ) | Out-Null
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it from https://learn.microsoft.com/cli/azure/install-azure-cli.'
}

$subscriptionName = & az account show --query name --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or -not $subscriptionName) {
    throw 'Azure CLI is not signed in. Run az login and select the intended subscription.'
}
$subscriptionName = "$subscriptionName".Trim()

if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    if ($state.resourceGroupName -ne $ResourceGroupName -or $state.location -ne $Location) {
        throw "Existing deployment state targets '$($state.resourceGroupName)' in '$($state.location)'. Use those values or remove the local state file after verifying the Azure resources."
    }
}
else {
    $storageAccountName = $null
    do {
        $candidate = "ndmusic$((Get-Random -Minimum 10000 -Maximum 99999))"
        $available = Get-AzValue -Arguments @('storage', 'account', 'check-name', '--name', $candidate, '--query', 'nameAvailable', '--output', 'tsv')
        if ($available -eq 'true') {
            $storageAccountName = $candidate
        }
    } while (-not $storageAccountName)

    $state = [pscustomobject]@{
        resourceGroupName  = $ResourceGroupName
        location           = $Location
        environmentName    = 'cae-navidrome'
        containerAppName   = 'navidrome-music'
        syncJobName        = 'onedrive-sync'
        storageAccountName = $storageAccountName
        musicShareName     = 'music'
        dataShareName      = 'navidrome-data'
        configShareName    = 'rclone-config'
        domain             = 'music.mikerichter.app'
    }
    $state | ConvertTo-Json | Set-Content -Path $statePath -Encoding utf8
}

Write-Host "Azure subscription: $subscriptionName"
Write-Host "Resource group: $($state.resourceGroupName)"
Write-Host "Location: $($state.location)"
Write-Host "Storage account: $($state.storageAccountName)"
Write-Host 'This creates Azure resources and storage charges. The Container App scales to zero when idle; music storage is billed separately.'

if (-not $ConfirmDeployment) {
    $confirmation = Read-Host "Type DEPLOY to continue in subscription '$subscriptionName'"
    if ($confirmation -cne 'DEPLOY') {
        throw 'Deployment cancelled.'
    }
}

Invoke-Az -Arguments @('extension', 'add', '--name', 'containerapp', '--upgrade', '--only-show-errors', '--output', 'none') | Out-Null
foreach ($provider in @('Microsoft.App', 'Microsoft.Storage')) {
    Invoke-Az -Arguments @('provider', 'register', '--namespace', $provider, '--wait', '--only-show-errors') | Out-Null
}

$groupExists = Test-AzResource -Arguments @('group', 'show', '--name', $state.resourceGroupName, '--query', 'name', '--output', 'tsv')
if ($groupExists) {
    $projectTag = Get-AzValue -Arguments @('group', 'show', '--name', $state.resourceGroupName, '--query', 'tags.project', '--output', 'tsv')
    if ($projectTag -ne 'navidrome-onedrive') {
        throw "Resource group '$($state.resourceGroupName)' already exists and is not tagged for this deployment. Choose a new ResourceGroupName."
    }
}
else {
    Deactivate-ActiveRevisions -AppName $state.containerAppName -ResourceGroupName $state.resourceGroupName
    Invoke-Az -Arguments @(
        'group', 'create',
        '--name', $state.resourceGroupName,
        '--location', $state.location,
        '--tags', 'project=navidrome-onedrive',
        '--output', 'none'
    ) | Out-Null
}

$storageExists = Test-AzResource -Arguments @('storage', 'account', 'show', '--resource-group', $state.resourceGroupName, '--name', $state.storageAccountName, '--query', 'name', '--output', 'tsv')
if (-not $storageExists) {
    Invoke-Az -Arguments @(
        'storage', 'account', 'create',
        '--resource-group', $state.resourceGroupName,
        '--name', $state.storageAccountName,
        '--location', $state.location,
        '--kind', 'StorageV2',
        '--sku', 'Standard_LRS',
        '--https-only', 'true',
        '--allow-blob-public-access', 'false',
        '--min-tls-version', 'TLS1_2',
        '--enable-large-file-share',
        '--enable-smb-oauth', 'true',
        '--output', 'none'
    ) | Out-Null
}

foreach ($shareName in @($state.musicShareName, $state.dataShareName, $state.configShareName)) {
    $shareExists = Test-AzResource -Arguments @('storage', 'share-rm', 'show', '--resource-group', $state.resourceGroupName, '--storage-account', $state.storageAccountName, '--name', $shareName, '--query', 'name', '--output', 'tsv')
    if (-not $shareExists) {
        Invoke-Az -Arguments @(
            'storage', 'share-rm', 'create',
            '--resource-group', $state.resourceGroupName,
            '--storage-account', $state.storageAccountName,
            '--name', $shareName,
            '--quota', '5120',
            '--enabled-protocols', 'SMB',
            '--output', 'none'
        ) | Out-Null
    }
}

$environmentExists = Test-AzResource -Arguments @('containerapp', 'env', 'show', '--name', $state.environmentName, '--resource-group', $state.resourceGroupName, '--query', 'name', '--output', 'tsv')
if (-not $environmentExists) {
    Invoke-Az -Arguments @(
        'containerapp', 'env', 'create',
        '--name', $state.environmentName,
        '--resource-group', $state.resourceGroupName,
        '--location', $state.location,
        '--logs-destination', 'none',
        '--mi-system-assigned',
        '--only-show-errors',
        '--output', 'none'
    ) | Out-Null
}

$storageAccountId = Get-AzValue -Arguments @('storage', 'account', 'show', '--resource-group', $state.resourceGroupName, '--name', $state.storageAccountName, '--query', 'id', '--output', 'tsv')
$environmentPrincipalId = Get-AzValue -Arguments @('containerapp', 'env', 'show', '--name', $state.environmentName, '--resource-group', $state.resourceGroupName, '--query', 'identity.principalId', '--output', 'tsv')
$existingRole = Get-AzValue -Arguments @(
    'role', 'assignment', 'list',
    '--scope', $storageAccountId,
    '--assignee-object-id', $environmentPrincipalId,
    '--query', "[?roleDefinitionName=='Storage File Data SMB MI Admin'].id | [0]",
    '--output', 'tsv'
) 2>$null
if (-not $existingRole) {
    Invoke-Az -Arguments @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $environmentPrincipalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', 'Storage File Data SMB MI Admin',
        '--scope', $storageAccountId,
        '--output', 'none'
    ) | Out-Null
    Start-Sleep -Seconds 20
}

foreach ($mount in @(
    @{ Name = 'music-readonly'; Share = $state.musicShareName; Mode = 'ReadOnly' },
    @{ Name = 'music-readwrite'; Share = $state.musicShareName; Mode = 'ReadWrite' },
    @{ Name = 'navidrome-data'; Share = $state.dataShareName; Mode = 'ReadWrite' },
    @{ Name = 'rclone-config'; Share = $state.configShareName; Mode = 'ReadOnly' }
)) {
    Invoke-Az -Arguments @(
        'containerapp', 'env', 'storage', 'set',
        '--name', $state.environmentName,
        '--resource-group', $state.resourceGroupName,
        '--storage-name', $mount.Name,
        '--azure-file-account-name', $state.storageAccountName,
        '--azure-file-share-name', $mount.Share,
        '--azure-file-identity', 'system',
        '--access-mode', $mount.Mode,
        '--only-show-errors',
        '--output', 'none'
    ) | Out-Null
}

$appManifest = Get-Content (Join-Path $repoRoot 'infra\navidrome.yaml') -Raw
$navidromeImage = "$($imageConfig.imageRepository):navidrome-$($imageConfig.navidromeVersion)"
$environmentId = Get-AzValue -Arguments @('containerapp', 'env', 'show', '--name', $state.environmentName, '--resource-group', $state.resourceGroupName, '--query', 'id', '--output', 'tsv')
$appManifest = $appManifest.Replace('__ENVIRONMENT_ID__', $environmentId)
$appManifest = $appManifest.Replace('__NAVIDROME_IMAGE__', $navidromeImage)
$manifestPath = Join-Path $env:TEMP 'navidrome-containerapp.yaml'
try {
    Set-Content -Path $manifestPath -Value $appManifest -Encoding utf8
    $appExists = Test-AzResource -Arguments @('containerapp', 'show', '--name', $state.containerAppName, '--resource-group', $state.resourceGroupName, '--query', 'name', '--output', 'tsv')
    if (-not $appExists) {
        Invoke-Az -Arguments @(
            'containerapp', 'create',
            '--name', $state.containerAppName,
            '--resource-group', $state.resourceGroupName,
            '--environment', $state.environmentName,
            '--yaml', $manifestPath,
            '--only-show-errors',
            '--output', 'none'
        ) | Out-Null
    }
    else {
        Deactivate-ActiveRevisions -AppName $state.containerAppName -ResourceGroupName $state.resourceGroupName
        Invoke-Az -Arguments @(
            'containerapp', 'update',
            '--name', $state.containerAppName,
            '--resource-group', $state.resourceGroupName,
            '--yaml', $manifestPath,
            '--only-show-errors',
            '--output', 'none'
        ) | Out-Null
    }
}
finally {
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
}

$fqdn = Get-AzValue -Arguments @('containerapp', 'show', '--name', $state.containerAppName, '--resource-group', $state.resourceGroupName, '--query', 'properties.configuration.ingress.fqdn', '--output', 'tsv')
Write-Host ''
Write-Host "Navidrome is deployed at https://$fqdn"
Write-Host "Next: run .\scripts\connect-onedrive.ps1 to authorize OneDrive and start the audio sync."
Write-Host 'For the custom domain, run .\scripts\show-domain-records.ps1 and add the displayed records in Namecheap DNS.'
