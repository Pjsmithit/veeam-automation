<#
.SYNOPSIS
  Drift check for every policy defined in .\policies\*.json against the live VBA appliance.
  Only fields present in each file are compared; server-managed fields (status, links, next run...) are ignored.
  Also lists policies on the appliance that have no desired-state file (unmanaged / orphans).

.NOTES
  Exit codes: 0 = no drift, 1 = drift (or orphans with -FailOnOrphans), 2 = a managed policy is missing / check failed.

.EXAMPLE
  .\Test-VbaPolicyDrift.ps1 -Appliance <VBA-IP-ADDRESS> -FailOnOrphans
#>
param(
  [Parameter(Mandatory)] [string] $Appliance,
  [string] $ApiVersion = 'v8.1',
  [string] $PolicyDir  = '.\policies',
  [string] $StatePath  = '.\state.json',
  [string] $ReportPath = '.\drift-report.json',
  [switch] $FailOnOrphans,
  [pscredential] $Credential = (Get-Credential -Message 'VBA appliance user')
)
. "$PSScriptRoot\VbaCommon.ps1"

$ignore  = @('regions', 'selectedItems')               # compared separately / response shape differs from request
$desired = Get-DesiredPolicies $PolicyDir
$state   = Read-VbaState $StatePath
$ctx = Connect-Vba -Appliance $Appliance -ApiVersion $ApiVersion -Credential $Credential
$c = $ctx.Common; $h = $ctx.Headers; $api = $ctx.Api
$exit = 0; $results = @(); $orphans = @(); $matchedIds = @()

try {
  $live = @(Get-VbaPolicyList $ctx)

  foreach ($d in $desired) {
    $name = $d.Policy.name
    $r = [ordered]@{ key = $d.Key; name = $name; status = 'OK'; drift = @(); pendingChange = $false }
    try {
      # Match by the ID in state first (survives UI renames), then by name
      $id = $state.policies[$d.Key].policyId
      if (-not $id -or -not ($live | Where-Object id -eq $id)) { $id = ($live | Where-Object name -eq $name | Select-Object -First 1).id }
      if ($id) { $matchedIds += $id }
      if (-not $id -or -not ($live | Where-Object id -eq $id)) { $r.status = 'MISSING'; $results += [pscustomobject]$r; $exit = 2; continue }

      $drift = Get-PolicyDrift $ctx $d $id

      $stored = $state.policies[$d.Key].desiredHash
      $r.pendingChange = [bool]($stored -and $stored -ne $d.Hash)   # file edited since last apply: pending change, not drift
      if ($drift.Count) { $r.status = 'DRIFT'; $r.drift = $drift; if ($exit -lt 1) { $exit = 1 } }
    }
    catch { $r.status = 'ERROR'; $r.error = "$($_.Exception.Message)"; $exit = 2 }
    $results += [pscustomobject]$r
  }

  # Policies on the appliance with no desired-state file
  $orphans = @($live | Where-Object { $matchedIds -notcontains $_.id } | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name } })
  if ($orphans -and $FailOnOrphans -and $exit -lt 1) { $exit = 1 }

  # Console summary
  foreach ($r in $results) {
    $color = if ($r.status -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}: " -f $r.key, $r.name) -NoNewline
    Write-Host $r.status -NoNewline -ForegroundColor $color
    if ($r.pendingChange) { Write-Host '  (file changed since last apply)' -NoNewline -ForegroundColor Yellow }
    Write-Host ''
    if ($r.drift.Count) { Write-DriftTable $r.drift }
    if ($r.error) { Write-Host "  $($r.error)" -ForegroundColor Red }
  }
  if ($orphans) {
    Write-Host "Unmanaged policies on appliance (no file in $PolicyDir):" -ForegroundColor Yellow
    $orphans | ForEach-Object { Write-Host "  $($_.name)  ($($_.id))" -ForegroundColor Yellow }
  }

  [ordered]@{ checkedUtc = (Get-Date).ToUniversalTime().ToString('o'); appliance = $Appliance
              summary = [ordered]@{ ok = @($results | ? status -eq 'OK').Count; drift = @($results | ? status -eq 'DRIFT').Count
                                    missing = @($results | ? status -eq 'MISSING').Count; error = @($results | ? status -eq 'ERROR').Count
                                    orphans = $orphans.Count }
              policies = $results; orphans = $orphans } | ConvertTo-Json -Depth 10 | Set-Content $ReportPath -Encoding utf8
  Write-Host "Report: $ReportPath  (exit code $exit)"
}
finally { Disconnect-Vba $ctx }
exit $exit
