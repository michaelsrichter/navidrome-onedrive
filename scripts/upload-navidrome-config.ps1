[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$StorageAccountName,
    [Parameter(Mandatory)][string]$ShareName
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repoRoot 'infra\navidrome.toml'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Navidrome configuration file was not found: $configPath"
}

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed with exit code $LASTEXITCODE."
    }
}

$userObjectId = & az ad signed-in-user show --query id --output tsv
if ($LASTEXITCODE -ne 0 -or -not $userObjectId) {
    throw 'Azure CLI is not signed in as a user who can upload the Navidrome configuration.'
}

$storageAccountId = & az storage account show `
    --resource-group $ResourceGroupName `
    --name $StorageAccountName `
    --query id `
    --output tsv
if ($LASTEXITCODE -ne 0 -or -not $storageAccountId) {
    throw "Could not resolve storage account '$StorageAccountName'."
}

$shareScope = "$storageAccountId/fileServices/default/fileshares/$ShareName"
$query = "[?scope=='$shareScope' && roleDefinitionName=='Storage File Data Privileged Contributor'].id"
$existingRoleIds = @(
    & az role assignment list `
        --scope $shareScope `
        --assignee-object-id $userObjectId `
        --query $query `
        --output tsv
)
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect file-data access on share '$ShareName'."
}
$existingRoleIds = @($existingRoleIds | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
if ($existingRoleIds.Count -gt 1) {
    throw "Multiple direct file-data role assignments were found on share '$ShareName'; none were changed."
}

$createdRoleId = $null
if ($existingRoleIds.Count -eq 0) {
    $createdRoleId = & az role assignment create `
        --assignee-object-id $userObjectId `
        --assignee-principal-type User `
        --role 'Storage File Data Privileged Contributor' `
        --scope $shareScope `
        --query id `
        --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $createdRoleId) {
        throw "Could not grant temporary file-data access to share '$ShareName'."
    }
    Start-Sleep -Seconds 45
}

try {
    Invoke-Az -Arguments @(
        'storage', 'file', 'upload',
        '--account-name', $StorageAccountName,
        '--auth-mode', 'login',
        '--share-name', $ShareName,
        '--source', $configPath,
        '--path', 'navidrome.toml',
        '--backup-intent',
        '--output', 'none'
    )
    Write-Host "Uploaded the version-controlled Navidrome configuration to '$ShareName'."
}
finally {
    if ($createdRoleId) {
        Invoke-Az -Arguments @(
            'role', 'assignment', 'delete',
            '--ids', $createdRoleId,
            '--output', 'none'
        )
    }
}
