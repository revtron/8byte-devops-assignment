<#
.SYNOPSIS
  Installs the 8byte SSH config block into ~/.ssh/config and the
  management / backend / mon functions into $PROFILE. Safe to re-run: the
  managed "# BEGIN 8byte" .. "# END 8byte" blocks are replaced, not duplicated.

.EXAMPLE
  PS> .\scripts\setup-ssh.ps1       (from the repo root, after terraform apply)
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Begin = '# BEGIN 8byte'
$End = '# END 8byte'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TerraformDir = Join-Path $RepoRoot 'terraform'
$SshDir = Join-Path $HOME '.ssh'
$SshConfig = Join-Path $SshDir 'config'

function Set-ManagedBlock {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Content
    )
    $lines = @()
    if (Test-Path $Path) {
        $lines = @(Get-Content -Path $Path -ErrorAction Stop)
    }
    $kept = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        if ($line -eq $Begin) { $skip = $true; continue }
        if ($line -eq $End) { $skip = $false; continue }
        if (-not $skip) { $kept.Add($line) }
    }
    # Trim trailing blank lines, then separate the block with one blank line.
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
        $kept.RemoveAt($kept.Count - 1)
    }
    if ($kept.Count -gt 0) { $kept.Add('') }
    $kept.Add($Begin)
    foreach ($l in ($Content -split "`r?`n")) { $kept.Add($l) }
    $kept.Add($End)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # UTF-8 without BOM and LF endings: ssh and pwsh both read it fine.
    $text = ($kept -join "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "Reading ssh_config output from $TerraformDir ..."
Push-Location $TerraformDir
try {
    $sshBlock = (& terraform output -raw ssh_config) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'terraform output failed' }
}
finally {
    Pop-Location
}
if ([string]::IsNullOrWhiteSpace($sshBlock)) { throw 'terraform output ssh_config is empty' }

Set-ManagedBlock -Path $SshConfig -Content $sshBlock
Write-Host "Updated $SshConfig"

$functions = @'
function management { ssh management @args }
function backend { ssh backend @args }
function mon { ssh mon @args }
'@
Set-ManagedBlock -Path $PROFILE -Content $functions
Write-Host "Updated $PROFILE (functions: management, backend, mon)"

if (-not (Test-Path (Join-Path $SshDir '8byte'))) {
    Write-Warning "Private key $SshDir\8byte not found; put the key matching admin_public_key there."
}
Write-Host "Done. Open a new PowerShell (or '. `$PROFILE') and run: management"
