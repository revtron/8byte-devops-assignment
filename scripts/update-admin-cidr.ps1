# PowerShell twin of update-admin-cidr.sh: point the bastion's SSH rule at
# your current public IP after it changes. Nothing is rebuilt.
#
# Usage: .\scripts\update-admin-cidr.ps1 [-Cidr 1.2.3.4/32]
param([string]$Cidr)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$tfvars = Join-Path $repoRoot 'terraform\envs\dev.tfvars'
if (-not (Test-Path $tfvars)) { throw "$tfvars not found" }

if (-not $Cidr) { $Cidr = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com').Trim() }
if ($Cidr -notmatch '/') { $Cidr = "$Cidr/32" }
if ($Cidr -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') { throw "not an IPv4 CIDR: $Cidr" }

$content = Get-Content $tfvars -Raw
$current = [regex]::Match($content, '(?m)^admin_cidr\s*=\s*"([^"]*)"').Groups[1].Value
if ($current -eq $Cidr) { Write-Host "admin_cidr is already $Cidr; nothing to do"; exit 0 }

$content = [regex]::Replace($content, '(?m)^admin_cidr\s*=.*$', "admin_cidr       = `"$Cidr`"")
[System.IO.File]::WriteAllText($tfvars, $content, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "admin_cidr: $current -> $Cidr"

Push-Location (Join-Path $repoRoot 'terraform')
try {
  terraform apply -input=false -auto-approve -var-file=$tfvars `
    -target=module.security.aws_vpc_security_group_ingress_rule.management_ssh
  if ($LASTEXITCODE -ne 0) { throw "terraform apply failed" }
} finally { Pop-Location }
Write-Host "done - 'ssh management' should work again"
