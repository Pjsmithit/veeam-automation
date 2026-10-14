# Helpers shared by Get-VbaRepositoryBaseline.ps1 and Test-VbaRepositoryDrift.ps1 (dot-sourced; not run directly).
# Read-only: only ever reads the repository list.

function Get-VbaRepositories($ctx) {
  $c = $ctx.Common
  $resp = Invoke-RestMethod @c -Headers $ctx.Headers -Uri "$($ctx.Api)/repositories?Limit=1000"
  $names = $resp.PSObject.Properties.Name
  $list  = @(if ($names -contains 'results') { $resp.results } else { $resp })
  if ($names -contains 'totalCount' -and $resp.totalCount -gt $list.Count) {
    Write-Host "WARNING: appliance reports $($resp.totalCount) repositories but only $($list.Count) were returned (paging). Results may be incomplete." -ForegroundColor Yellow
  }
  $list
}

# Adds computed settings that the API does not report as a single value, so that "off" can be baselined and detected.
# storageConsumptionLimitEnabled = true when a limit with a value above 0 is set. Without this, a repository that had NO limit
# at baseline time would have nothing in its file to compare, and a limit switched on later would go unnoticed.
function Add-RepoDerived($r) {
  $lim = $r.storageConsumptionLimit
  $enabled = [bool]($lim -and $null -ne $lim.limitValue -and "$($lim.limitValue)" -ne '' -and [double]$lim.limitValue -gt 0)
  $r | Add-Member -NotePropertyName storageConsumptionLimitEnabled -NotePropertyValue $enabled -Force
  $r
}

# Differences between a desired repository document and a live repository: rows of { Path, Desired, Live }.
# Only settings present in the desired document are compared (same rule as Test-VbaRepositoryDrift.ps1).
function Get-RepoDrift($Desired, $Live) {
  $Live = Add-RepoDerived $Live
  $dm = ConvertTo-FlatMap $Desired
  $lm = ConvertTo-FlatMap $Live
  @(foreach ($k in $dm.Keys) {
    if (-not $lm.Contains($k))   { [pscustomobject]@{ Path = $k; Desired = $dm[$k]; Live = '(absent)' } }
    elseif ($lm[$k] -ne $dm[$k]) { [pscustomobject]@{ Path = $k; Desired = $dm[$k]; Live = $lm[$k] } }
  })
}

# Turn a live repository into a desired-state document. Only meaningful, stable settings are kept; links, hints,
# ownership details and empty values are left out. No secrets are involved (the API never returns encryption passwords).
function ConvertTo-RepoBaseline($r) {
  $r = Add-RepoDerived $r
  $doc = [ordered]@{}
  foreach ($p in 'id','name','description','repositoryType','status','storageTier','immutabilityEnabled','enableEncryption',
                 'concurrencyLimit','storageConsumptionLimitEnabled','azureAccountId','azureStorageAccountId','azureStorageAccountName','regionName') {
    if ($null -ne $r.$p -and "$($r.$p)" -ne '') { $doc[$p] = $r.$p }
  }
  if ($r.repositoryType -eq 'VeeamVault' -and $null -ne $r.veeamVaultId) { $doc['veeamVaultId'] = $r.veeamVaultId }
  foreach ($obj in 'azureStorageContainer', 'azureStorageFolder') {
    if ($r.$obj) {
      $o = [ordered]@{}
      if ($r.$obj.name) { $o['name'] = $r.$obj.name }
      if ($null -ne $r.$obj.ImmutabilityPolicyState -and "$($r.$obj.ImmutabilityPolicyState)" -ne '') { $o['ImmutabilityPolicyState'] = $r.$obj.ImmutabilityPolicyState }
      if ($o.Count) { $doc[$obj] = $o }
    }
  }
  if ($r.storageConsumptionLimit -and $null -ne $r.storageConsumptionLimit.limitValue) {
    $doc['storageConsumptionLimit'] = [ordered]@{ limitValue = $r.storageConsumptionLimit.limitValue; limitType = $r.storageConsumptionLimit.limitType }
  }
  [pscustomobject]$doc
}
