[CmdletBinding()]
param(
    [string]$RemoteName = 'onedrive',
    [string]$OneDrivePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $repoRoot '.deployment.local.json'

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed with exit code $LASTEXITCODE. No credentials were printed."
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

if (-not (Test-Path $statePath)) {
    throw 'Deployment state was not found. Run scripts/deploy.ps1 first.'
}
if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    throw 'rclone is required on this Windows machine for the OAuth setup. Install it from https://rclone.org/downloads/ and rerun this script.'
}

$state = Get-Content $statePath -Raw | ConvertFrom-Json
$remoteRef = "${RemoteName}:"
$configuredRemotes = @(& rclone listremotes)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read rclone remotes.'
}
if ($configuredRemotes -notcontains $remoteRef) {
    Write-Host "Create the '$RemoteName' OneDrive remote in rclone. The browser sign-in will authorize access directly with Microsoft."
    Write-Host 'Do not paste a password, OAuth token, or rclone.conf into chat or GitHub.'
    & rclone config
    if ($LASTEXITCODE -ne 0) {
        throw 'rclone configuration did not complete.'
    }
}

$configuredRemotes = @(& rclone listremotes)
if ($LASTEXITCODE -ne 0 -or $configuredRemotes -notcontains $remoteRef) {
    throw "The rclone remote '$RemoteName' was not found. Run rclone config and create a OneDrive remote with that exact name."
}

$configOutput = @(& rclone config file)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to locate the local rclone configuration file.'
}
$configPath = $configOutput | ForEach-Object { "$_".Trim() } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Last 1
if (-not $configPath) {
    throw 'The rclone configuration file could not be found.'
}

Write-Host 'Top-level OneDrive folders (shown only in this local PowerShell window):'
& rclone lsd $remoteRef
if ($LASTEXITCODE -ne 0) {
    throw 'Could not list OneDrive. Check the rclone OAuth sign-in and remote.'
}

if (-not $OneDrivePath) {
    $OneDrivePath = Read-Host 'OneDrive folder path containing your music (for example Music)'
}
$OneDrivePath = ($OneDrivePath.Trim().Trim('/') -replace '\\', '/')
if (-not $OneDrivePath) {
    throw 'A specific OneDrive folder path is required; syncing the entire drive is not enabled.'
}

$remotePath = "${RemoteName}:$OneDrivePath"
$null = & rclone lsf $remotePath --max-depth 1
if ($LASTEXITCODE -ne 0) {
    throw "The OneDrive folder '$OneDrivePath' could not be opened. Check the path and try again."
}

$confirmation = Read-Host "Sync audio and companion files from '$remotePath' to Azure Files? This does not write to OneDrive, but removed source files are removed from the Azure copy. Type SYNC to continue"
if ($confirmation -cne 'SYNC') {
    throw 'OneDrive sync cancelled.'
}

$userObjectId = Get-AzValue -Arguments @('ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv')
$storageAccountId = Get-AzValue -Arguments @(
    'storage', 'account', 'show',
    '--resource-group', $state.resourceGroupName,
    '--account-name', $state.storageAccountName,
    '--query', 'id',
    '--output', 'tsv'
)
$configShareScope = "$storageAccountId/fileServices/default/fileshares/$($state.configShareName)"
$existingUploadRole = Get-AzValue -Arguments @(
    'role', 'assignment', 'list',
    '--scope', $configShareScope,
    '--assignee-object-id', $userObjectId,
    '--query', "[?roleDefinitionName=='Storage File Data Privileged Contributor'].id | [0]",
    '--output', 'tsv'
) 2>$null
if (-not $existingUploadRole) {
    Invoke-Az -Arguments @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $userObjectId,
        '--assignee-principal-type', 'User',
        '--role', 'Storage File Data Privileged Contributor',
        '--scope', $configShareScope,
        '--output', 'none'
    ) | Out-Null
    Start-Sleep -Seconds 20
}

Invoke-Az -Arguments @(
    'storage', 'file', 'upload',
    '--account-name', $state.storageAccountName,
    '--auth-mode', 'login',
    '--share-name', $state.configShareName,
    '--source', $configPath,
    '--path', 'rclone.conf',
    '--backup-intent',
    '--output', 'none'
) | Out-Null

$images = Get-Content (Join-Path $repoRoot 'infra\images.json') -Raw | ConvertFrom-Json
$rcloneImage = "$($images.imageRepository):rclone-$($images.rcloneVersion)"
$environmentId = Get-AzValue -Arguments @('containerapp', 'env', 'show', '--name', $state.environmentName, '--resource-group', $state.resourceGroupName, '--query', 'id', '--output', 'tsv')
$remoteJson = ConvertTo-Json -InputObject $RemoteName -Compress
$pathJson = ConvertTo-Json -InputObject $OneDrivePath -Compress
$jobManifest = Get-Content (Join-Path $repoRoot 'infra\onedrive-sync-job.yaml') -Raw
$jobManifest = $jobManifest.Replace('__ENVIRONMENT_ID__', $environmentId)
$jobManifest = $jobManifest.Replace('__RCLONE_IMAGE__', $rcloneImage)
$jobManifest = $jobManifest.Replace('__RCLONE_REMOTE__', $remoteJson)
$jobManifest = $jobManifest.Replace('__RCLONE_PATH_JSON__', $pathJson)
$jobManifestPath = Join-Path $env:TEMP 'navidrome-onedrive-job.yaml'

try {
    Set-Content -Path $jobManifestPath -Value $jobManifest -Encoding utf8
    $jobExists = Test-AzResource -Arguments @('containerapp', 'job', 'show', '--name', $state.syncJobName, '--resource-group', $state.resourceGroupName, '--query', 'name', '--output', 'tsv')
    if ($jobExists) {
        Invoke-Az -Arguments @(
            'containerapp', 'job', 'update',
            '--name', $state.syncJobName,
            '--resource-group', $state.resourceGroupName,
            '--yaml', $jobManifestPath,
            '--only-show-errors',
            '--output', 'none'
        ) | Out-Null
    }
    else {
        Invoke-Az -Arguments @(
            'containerapp', 'job', 'create',
            '--name', $state.syncJobName,
            '--resource-group', $state.resourceGroupName,
            '--environment', $state.environmentName,
            '--yaml', $jobManifestPath,
            '--only-show-errors',
            '--output', 'none'
        ) | Out-Null
    }
}
finally {
    Remove-Item -LiteralPath $jobManifestPath -Force -ErrorAction SilentlyContinue
}

Invoke-Az -Arguments @('containerapp', 'job', 'start', '--name', $state.syncJobName, '--resource-group', $state.resourceGroupName, '--only-show-errors', '--output', 'none') | Out-Null
Write-Host "The initial sync has started for '$OneDrivePath'. The job will repeat every six hours (UTC)."
Write-Host "Check status with: az containerapp job execution list --name $($state.syncJobName) --resource-group $($state.resourceGroupName) --output table"
