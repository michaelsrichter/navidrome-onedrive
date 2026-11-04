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

function Deactivate-ActiveRevisions {
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    $output = & az containerapp revision list `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --query '[].name' `
        --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not list Container Apps revisions.'
    }

    $revisionText = ($output -join "`n").Trim()
    $revisionNames = $revisionText -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($revisionName in $revisionNames) {
        $stateJson = & az containerapp revision show `
            --name $AppName `
            --resource-group $ResourceGroupName `
            --revision $revisionName `
            --query '{active:properties.active,replicas:properties.replicas,runningState:properties.runningState}' `
            --output json
        if ($LASTEXITCODE -ne 0) {
            throw "Could not inspect revision '$revisionName' before updating."
        }

        $revisionState = $stateJson | ConvertFrom-Json
        if ($revisionState.active) {
            Write-Host "Deactivating $revisionName to avoid overlapping SQLite writers on Azure Files."
            Invoke-Az -Arguments @(
                'containerapp', 'revision', 'deactivate',
                '--name', $AppName,
                '--resource-group', $ResourceGroupName,
                '--revision', $revisionName,
                '--only-show-errors',
                '--output', 'none'
            )
        }

        $replicaCount = if ($null -eq $revisionState.replicas) { 0 } else { [int]$revisionState.replicas }
        if (-not $revisionState.active -and $replicaCount -eq 0 -and $revisionState.runningState -eq 'Stopped') {
            continue
        }

        Write-Host "Waiting for $revisionName to stop before starting another SQLite writer."
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        do {
            $stateJson = & az containerapp revision show `
                --name $AppName `
                --resource-group $ResourceGroupName `
                --revision $revisionName `
                --query '{active:properties.active,replicas:properties.replicas,runningState:properties.runningState}' `
                --output json
            if ($LASTEXITCODE -ne 0) {
                throw "Could not verify that revision '$revisionName' has stopped."
            }

            $revisionState = $stateJson | ConvertFrom-Json
            $replicaCount = if ($null -eq $revisionState.replicas) { 0 } else { [int]$revisionState.replicas }
            if (-not $revisionState.active -and $replicaCount -eq 0 -and $revisionState.runningState -eq 'Stopped') {
                break
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Timed out waiting for revision '$revisionName' to stop; refusing to start another SQLite writer."
            }
            Start-Sleep -Seconds 5
        } while ($true)
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
$revisionSuffix = "upd-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 6))"

& (Join-Path $PSScriptRoot 'upload-navidrome-config.ps1') `
    -ResourceGroupName $state.resourceGroupName `
    -StorageAccountName $state.storageAccountName `
    -ShareName $state.dataShareName

Deactivate-ActiveRevisions -AppName $state.containerAppName -ResourceGroupName $state.resourceGroupName

Invoke-Az -Arguments @(
    'containerapp', 'update',
    '--name', $state.containerAppName,
    '--resource-group', $state.resourceGroupName,
    '--image', $NavidromeImage,
    '--revision-suffix', $revisionSuffix,
    '--remove-env-vars', 'ND_DBPATH',
    '--set-env-vars',
    'ND_PLUGINS_ENABLED=true',
    'ND_PLUGINS_FOLDER=/plugins',
    'ND_PLUGINS_AUTORELOAD=true',
    'ND_CONFIGFILE=/data/navidrome.toml',
    'ND_AGENTS=deezer,lastfm,listenbrainz,coverartarchive',
    'ND_LYRICSPRIORITY=embedded,.lrc,.txt,nd-lyrics',
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
