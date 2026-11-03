[CmdletBinding()]
param(
    [string]$NavidromeImage,
    [string]$RcloneImage
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $repoRoot '.deployment.local.json'
$imageConfig = Get-Content (Join-Path $repoRoot 'infra\images.json') -Raw | ConvertFrom-Json

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path $statePath)) {
    throw 'Deployment state was not found. Run scripts/deploy.ps1 first.'
}

$state = Get-Content $statePath -Raw | ConvertFrom-Json
if (-not $NavidromeImage) {
    $NavidromeImage = "$($imageConfig.imageRepository):navidrome-$($imageConfig.navidromeVersion)"
}
if (-not $RcloneImage) {
    $RcloneImage = "$($imageConfig.imageRepository):rclone-$($imageConfig.rcloneVersion)"
}

Invoke-Az -Arguments @(
    'containerapp', 'update',
    '--name', $state.containerAppName,
    '--resource-group', $state.resourceGroupName,
    '--image', $NavidromeImage,
    '--only-show-errors',
    '--output', 'none'
)

$jobExists = & az containerapp job show --name $state.syncJobName --resource-group $state.resourceGroupName --query name --output tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $jobExists) {
    Invoke-Az -Arguments @(
        'containerapp', 'job', 'update',
        '--name', $state.syncJobName,
        '--resource-group', $state.resourceGroupName,
        '--image', $RcloneImage,
        '--only-show-errors',
        '--output', 'none'
    )
}

Write-Host "Updated Navidrome to $NavidromeImage."
if ($jobExists) {
    Write-Host "Updated the sync job to $RcloneImage."
}
