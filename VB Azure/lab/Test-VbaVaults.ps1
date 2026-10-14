<#
.SYNOPSIS
  Read-only check of the Veeam Data Cloud Vault connection on a Veeam Backup for Microsoft Azure appliance:
    1. Is the appliance registered with Veeam Data Cloud Vault?
    2. Which storage vaults are connected?
    3. Has each vault been added as a backup repository (type VeeamVault)?

.NOTES
  Makes GET requests only. Needs VbaCommon.ps1 in the same folder.
  Exit codes: 0 = registered and all vaults usable, 1 = warnings (no vaults, read-only vault, vault not added as repository),
              2 = appliance not registered.

.EXAMPLE
  .\Test-VbaVaults.ps1 -Appliance <VBA-IP-ADDRESS>
#>
param(
  [Parameter(Mandatory)] [string] $Appliance,
  [string] $ApiVersion = 'v8.1',
  [pscredential] $Credential = (Get-Credential -Message 'VBA appliance user')
)
. "$PSScriptRoot\VbaCommon.ps1"

$ctx = Connect-Vba -Appliance $Appliance -ApiVersion $ApiVersion -Credential $Credential
$c = $ctx.Common; $h = $ctx.Headers; $api = $ctx.Api
$exit = 0
try {
  # 1. Registration
  $reg = Invoke-RestMethod @c -Headers $h -Uri "$api/veeamVaults/registration"
  if ($reg.instanceRegistered) {
    Write-Host 'Registration: REGISTERED with Veeam Data Cloud Vault' -ForegroundColor Green
    if ($reg.vdcManageLink) { Write-Host "  Manage link: $($reg.vdcManageLink)" }
  } else {
    Write-Host 'Registration: NOT REGISTERED with Veeam Data Cloud Vault' -ForegroundColor Red
    Write-Host '  Register once via the VBA portal (Repositories > Veeam Data Cloud Vault) or the veeamVaults/oauth2 + registration endpoints.'
    $exit = 2; return
  }

  # 2. Storage vaults connected to this appliance
  $vaults = @(Invoke-RestMethod @c -Headers $h -Uri "$api/veeamVaults")
  if (-not $vaults) { Write-Host 'Vaults: none connected' -ForegroundColor Yellow; $exit = 1; return }

  # 3. Repositories of type VeeamVault already added on the appliance
  $repos = @((Invoke-RestMethod @c -Headers $h -Uri "$api/repositories?Type=VeeamVault&Limit=1000").results)

  Write-Host "`nVaults ($($vaults.Count)):"
  foreach ($v in $vaults) {
    $repo = $repos | Where-Object { "$($_.veeamVaultId)" -eq "$($v.id)" } | Select-Object -First 1
    Write-Host ("  [{0}] {1}  storage account={2}  container={3}" -f $v.id, $v.name, $v.storageAccountName, $v.storageContainerName)
    if ($v.isReadOnly) {
      Write-Host "      READ-ONLY: $($v.readOnlyReason)" -ForegroundColor Red; if ($exit -lt 1) { $exit = 1 }
    }
    if ($repo) { Write-Host "      Repository: $($repo.name) (id $($repo.id))" -ForegroundColor Green }
    else       { Write-Host '      Repository: not added yet (import the vault, then add it as a repository)' -ForegroundColor Yellow; if ($exit -lt 1) { $exit = 1 } }
  }
}
finally { Disconnect-Vba $ctx }
exit $exit
