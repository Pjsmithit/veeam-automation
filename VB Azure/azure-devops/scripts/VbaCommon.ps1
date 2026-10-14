# Shared helpers for Invoke-VbaPolicies.ps1 and Test-VbaPolicyDrift.ps1 (dot-sourced; not run directly).

# Credentials for non-interactive use: the pipeline maps Key Vault secrets to VBA_USERNAME / VBA_PASSWORD.
# Falls back to an interactive prompt when run by hand.
function Get-VbaCredential {
  if ($env:VBA_USERNAME -and $env:VBA_PASSWORD) {
    return [pscredential]::new($env:VBA_USERNAME, (ConvertTo-SecureString $env:VBA_PASSWORD -AsPlainText -Force))
  }
  Get-Credential -Message 'VBA appliance user'
}

function Connect-Vba {
  param([string]$Appliance, [string]$ApiVersion, [pscredential]$Credential)
  if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Use PowerShell 7+ (needs -SkipCertificateCheck).' }
  $base   = "https://$Appliance"
  $common = @{ SkipCertificateCheck = $true; ErrorAction = 'Stop' }   # remove SkipCertificateCheck once the appliance has a trusted cert
  $tok = Invoke-RestMethod @common -Method Post -Uri "$base/api/oauth2/token" -ContentType 'application/x-www-form-urlencoded' `
    -Body @{ grant_type = 'password'; username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password }
  [pscustomobject]@{
    Base = $base; Api = "$base/api/$ApiVersion"; Common = $common
    Headers = @{ Authorization = "Bearer $($tok.access_token)"; 'x-api-version' = $ApiVersion.TrimStart('v') }
    TagCache = @{}
  }
}

function Disconnect-Vba($ctx) {
  $c = $ctx.Common
  try { Invoke-RestMethod @c -Headers $ctx.Headers -Method Post -Uri "$($ctx.Base)/api/oauth2/logout" | Out-Null } catch {}
}

function Get-VbaPolicyList($ctx) {
  $c = $ctx.Common
  (Invoke-RestMethod @c -Headers $ctx.Headers -Uri "$($ctx.Api)/policies/virtualMachines?Limit=1000").results
}

# Desired-state files: one JSON per policy. The file name (without .json) is the stable key.
function Get-DesiredPolicies([string]$Dir) {
  $files = Get-ChildItem -Path $Dir -Filter *.json -File | Sort-Object Name
  if (-not $files) { throw "No policy files found in $Dir" }
  $list = foreach ($f in $files) {
    [pscustomobject]@{ Key = $f.BaseName; File = $f.FullName; Raw = (Get-Content -Raw $f.FullName)
                       Policy = (Get-Content -Raw $f.FullName | ConvertFrom-Json)
                       Hash = (Get-FileHash -Algorithm SHA256 $f.FullName).Hash }
  }
  $dupes = $list | Group-Object { $_.Policy.name } | Where-Object Count -gt 1
  if ($dupes) { throw "Duplicate policy names in $Dir`: $($dupes.Name -join ', ')" }
  $list
}

# State file: { appliance, policies: { <key>: { policyId, policyName, appliedUtc, desiredHash, liveAtApply } } }
function Read-VbaState([string]$Path) {
  if (Test-Path $Path) { Get-Content -Raw $Path | ConvertFrom-Json -AsHashtable }
  else { @{ policies = @{} } }
}
function Write-VbaState([string]$Path, $State) {
  $State | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding utf8
}

# Force one Azure rescan per (service account, tenant) and return the tag list. Sync=true must be sent only on the first
# call (each call with it starts a new rescan); later polls read the result until it returns 200 instead of 202.
function Get-VbaTags($ctx, [string]$ServiceAccountId, [string]$TenantId, [int]$TimeoutSec = 300) {
  $cacheKey = "$ServiceAccountId|$TenantId"
  if ($ctx.TagCache.ContainsKey($cacheKey)) { return $ctx.TagCache[$cacheKey] }
  $c = $ctx.Common
  $q = "ServiceAccountId=$ServiceAccountId&TenantId=$TenantId&Limit=1000"
  $sync = '&Sync=true'; $deadline = (Get-Date).AddSeconds($TimeoutSec); $tags = $null
  do {
    $r = Invoke-WebRequest @c -Headers $ctx.Headers -Uri "$($ctx.Api)/cloudInfrastructure/tags?$q$sync"
    $sync = ''
    if ($r.StatusCode -eq 200) { $tags = @(($r.Content | ConvertFrom-Json).results); break }
    Write-Host "  Azure rescan in progress (HTTP $($r.StatusCode))..."
    Start-Sleep -Seconds 10
  } while ((Get-Date) -lt $deadline)
  if ($null -eq $tags) { throw "Azure rescan did not finish within $TimeoutSec seconds." }
  $ctx.TagCache[$cacheKey] = $tags
  Write-Host "  Rescan complete: $($tags.Count) tags known to VBA."
  $tags
}

function Get-MissingTags($Tags, $Wanted) {
  @($Wanted | Where-Object { $t = $_; -not ($Tags | Where-Object { $_.name -eq $t.name -and $_.value -eq $t.value }) })
}

# Compare one desired policy against the live policy with the given ID. Returns an array of { Path, Desired, Live }.
# regions/selectedItems are not compared field by field (response shape differs from the request); tags are checked separately.
function Get-PolicyDrift($ctx, $d, [string]$Id) {
  $c = $ctx.Common
  $cur = Invoke-RestMethod @c -Headers $ctx.Headers -Uri "$($ctx.Api)/policies/virtualMachines/$Id"
  $dm  = ConvertTo-FlatMap ($d.Policy | Select-Object * -ExcludeProperty regions, selectedItems)
  $lm  = ConvertTo-FlatMap $cur
  $drift = @(foreach ($k in $dm.Keys) {
    if (-not $lm.Contains($k))   { [pscustomobject]@{ Path = $k; Desired = $dm[$k]; Live = '(absent)' } }
    elseif ($lm[$k] -ne $dm[$k]) { [pscustomobject]@{ Path = $k; Desired = $dm[$k]; Live = $lm[$k] } }
  })
  if ($d.Policy.selectedItems.tags) {
    $selJson = Invoke-RestMethod @c -Headers $ctx.Headers -Uri "$($ctx.Api)/policies/virtualMachines/$Id/selectedItems" | ConvertTo-Json -Depth 20 -Compress
    $drift += @(foreach ($t in $d.Policy.selectedItems.tags) {
      if ($selJson -notlike "*$($t.name)*" -or $selJson -notlike "*$($t.value)*") {
        [pscustomobject]@{ Path = 'selectedItems.tags'; Desired = "$($t.name)=$($t.value)"; Live = '(not selected)' }
      }
    })
  }
  @($drift | Where-Object { $_ })
}

# Build a desired-state document (create-body shape) from an existing live policy, for adopting an unmanaged policy.
# regions/selectedItems come straight from the policy's GET endpoints, so REVIEW the generated file before relying on it.
function ConvertTo-DesiredFromLive($ctx, [string]$Id) {
  $c = $ctx.Common; $u = "$($ctx.Api)/policies/virtualMachines/$Id"
  $cur = Invoke-RestMethod @c -Headers $ctx.Headers -Uri $u
  $doc = [ordered]@{}
  foreach ($p in 'name','description','isEnabled','tenantId','serviceAccountId','backupType','snapshotSettings','retrySettings',
                 'policyNotificationSettings','dailySchedule','weeklySchedule','monthlySchedule','yearlySchedule','healthCheckSchedule') {
    if ($null -ne $cur.$p) { $doc[$p] = $cur.$p }
  }
  $regions = Invoke-RestMethod @c -Headers $ctx.Headers -Uri "$u/regions"
  $doc['regions'] = if ($regions.results) { @($regions.results) } else { $regions }
  if ($cur.backupType -eq 'SelectedItems') { $doc['selectedItems'] = Invoke-RestMethod @c -Headers $ctx.Headers -Uri "$u/selectedItems" }
  [pscustomobject]$doc
}

# Remediation view: one row per setting that differed, with the discovered (live) value, the desired value and the value
# after remediation. $Before = drift found before the update, $After = drift still present afterwards (re-read from VBA).
function Write-RemediationTable($Before, $After, [switch]$DryRun) {
  $rows = foreach ($b in @($Before)) {
    $still = @($After) | Where-Object { $_.Path -eq $b.Path } | Select-Object -First 1
    $res, $ok = if ($DryRun) { "(dry run) would become $($b.Desired)", $null }
                elseif ($still) { "$($still.Live)  <- NOT CHANGED", $false }
                else { "$($b.Desired)  <- CHANGED", $true }
    [pscustomobject]@{ Setting = $b.Path; Discovered = $b.Live; Desired = $b.Desired; Remediated = $res; Ok = $ok }
  }
  $w = @{ S = 7; D = 10; T = 7 }
  foreach ($r in $rows) {
    $w.S = [Math]::Max($w.S, $r.Setting.Length); $w.D = [Math]::Max($w.D, $r.Discovered.Length); $w.T = [Math]::Max($w.T, $r.Desired.Length)
  }
  Write-Host ("  {0}  {1}  {2}  {3}" -f 'SETTING'.PadRight($w.S), 'DISCOVERED (live)'.PadRight([Math]::Max($w.D, 17)), 'DESIRED'.PadRight($w.T), 'REMEDIATED')
  foreach ($r in $rows) {
    Write-Host ("  {0}  " -f $r.Setting.PadRight($w.S)) -NoNewline -ForegroundColor Yellow
    Write-Host ("{0}  " -f $r.Discovered.PadRight([Math]::Max($w.D, 17))) -NoNewline -ForegroundColor Red
    Write-Host ("{0}  " -f $r.Desired.PadRight($w.T)) -NoNewline -ForegroundColor Green
    $col = if ($null -eq $r.Ok) { 'Yellow' } elseif ($r.Ok) { 'Green' } else { 'Red' }
    Write-Host $r.Remediated -ForegroundColor $col
  }
}

# Print drift as an aligned table: path in yellow, desired value in green, live (wrong) value in red.
function Write-DriftTable($Drift) {
  $rows = @($Drift)
  if (-not $rows) { return }
  $w1 = [Math]::Max(4, ($rows.Path    | Measure-Object Length -Maximum).Maximum)
  $w2 = [Math]::Max(7, ($rows.Desired | Measure-Object Length -Maximum).Maximum)
  Write-Host ("  {0}  {1}  {2}" -f 'Path'.PadRight($w1), 'Desired'.PadRight($w2), 'Live')
  foreach ($r in $rows) {
    Write-Host ("  {0}  " -f $r.Path.PadRight($w1))   -NoNewline -ForegroundColor Yellow
    Write-Host ("{0}  "   -f $r.Desired.PadRight($w2)) -NoNewline -ForegroundColor Green
    Write-Host $r.Live -ForegroundColor Red
  }
}

# Flatten an object into { 'a.b[0].c' = 'value' } with every value as a string, for subset comparison.
function ConvertTo-FlatMap($o, [string]$p = '', $map = $null) {
  if ($null -eq $map) { $map = [ordered]@{} }
  if ($o -is [System.Collections.IList]) {
    for ($i = 0; $i -lt $o.Count; $i++) { ConvertTo-FlatMap $o[$i] "$p[$i]" $map | Out-Null }
  } elseif ($o -is [pscustomobject]) {
    foreach ($prop in $o.PSObject.Properties) {
      $path = if ($p) { "$p.$($prop.Name)" } else { $prop.Name }
      ConvertTo-FlatMap $prop.Value $path $map | Out-Null
    }
  } elseif ($null -ne $o) { $map[$p] = "$o" }
  return $map
}
