<#
.SYNOPSIS
  DETECTION ONLY. Compares the users and roles on a Veeam Backup for Microsoft Azure appliance with the desired
  state in .\users\*.json and reports differences. It never creates, changes or deletes anything on the appliance
  (it only signs in, reads the user list, and signs out).

  Reports: role drift, MFA drift, other setting drift, missing users, and unmanaged users (accounts that exist on
  the appliance but have no file in the repo).

.NOTES
  Needs VbaCommon.ps1 in the same folder (unchanged, shared with the policy scripts).
  Exit codes: 0 = no differences, 1 = drift (or unmanaged users with -FailOnUnmanaged), 2 = a listed user is missing / check failed.

  -ExportTo <folder> writes one JSON file per CURRENT appliance user, to give you a starting baseline. It only writes
  local files (never to the appliance) and never overwrites an existing file. Review the files before committing them.

.EXAMPLE
  .\Test-VbaUserDrift.ps1 -Appliance <VBA-IP-ADDRESS> -ExportTo ./users      # one-off: capture today's users as a baseline
  .\Test-VbaUserDrift.ps1 -Appliance <VBA-IP-ADDRESS> -FailOnUnmanaged       # the drift check
#>
param(
  [Parameter(Mandatory)] [string] $Appliance,
  [string] $ApiVersion = 'v8.1',
  [string] $UserDir    = './users',
  [string] $ReportPath = './user-drift-report.json',
  [string] $ExportTo,
  [switch] $FailOnUnmanaged,
  [pscredential] $Credential
)
. "$PSScriptRoot/VbaCommon.ps1"
if (-not $Credential) { $Credential = Get-VbaCredential }

# Fields that matter most for security; drift on these is labelled SECURITY
$securityPaths = @('role', 'mfaEnabled', 'type')

$ctx = Connect-Vba -Appliance $Appliance -ApiVersion $ApiVersion -Credential $Credential
$c = $ctx.Common; $h = $ctx.Headers
$exit = 0
try {
  # --- the only appliance call besides sign-in/out: read the user list ---
  $resp = Invoke-RestMethod @c -Headers $h -Uri "$($ctx.Api)/users"
  $live = @(if ($resp.PSObject.Properties.Name -contains 'results') { $resp.results } else { $resp })
  if ($resp.PSObject.Properties.Name -contains 'totalCount' -and $resp.totalCount -gt $live.Count) {
    Write-Host "WARNING: appliance reports $($resp.totalCount) users but only $($live.Count) were returned (paging). Results may be incomplete." -ForegroundColor Yellow
  }

  # --- optional: export the current users as a starting baseline (local files only) ---
  if ($ExportTo) {
    New-Item -ItemType Directory -Force -Path $ExportTo | Out-Null
    foreach ($u in $live) {
      $key  = ($u.name -replace '[^A-Za-z0-9._-]', '-').ToLower()
      $file = Join-Path $ExportTo "$key.json"
      if (Test-Path $file) { Write-Host "skipped (exists): $file" -ForegroundColor Yellow; continue }
      $doc = [ordered]@{ name = $u.name; description = $u.description; role = $u.role; type = $u.type; mfaEnabled = $u.mfaEnabled }
      $doc | ConvertTo-Json | Set-Content -Path $file -Encoding utf8
      Write-Host "wrote $file" -ForegroundColor Green
    }
    Write-Host 'Review the files, remove any user you do not want managed, then commit them.'
    return
  }

  # --- load desired users ---
  $files = Get-ChildItem -Path $UserDir -Filter *.json -File | Sort-Object Name
  if (-not $files) { throw "No user files found in $UserDir (run with -ExportTo $UserDir to create a baseline)" }
  $desired = foreach ($f in $files) { [pscustomobject]@{ Key = $f.BaseName; User = (Get-Content -Raw $f.FullName | ConvertFrom-Json) } }
  $dupes = $desired | Group-Object { $_.User.name } | Where-Object Count -gt 1
  if ($dupes) { throw "Duplicate user names in $UserDir`: $($dupes.Name -join ', ')" }

  # --- compare ---
  $results = @(); $matched = @()
  foreach ($d in $desired) {
    $r = [ordered]@{ key = $d.Key; name = $d.User.name; status = 'OK'; drift = @() }
    $u = $live | Where-Object { $_.name -eq $d.User.name } | Select-Object -First 1
    if (-not $u) { $r.status = 'MISSING'; if ($exit -lt 2) { $exit = 2 }; $results += [pscustomobject]$r; continue }
    $matched += $u.id
    $dm = ConvertTo-FlatMap $d.User
    $lm = ConvertTo-FlatMap $u
    $drift = @(foreach ($k in $dm.Keys) {
      if (-not $lm.Contains($k))   { [pscustomobject]@{ Path = $k; Desired = $dm[$k]; Live = '(absent)'; Security = ($securityPaths -contains $k) } }
      elseif ($lm[$k] -ne $dm[$k]) { [pscustomobject]@{ Path = $k; Desired = $dm[$k]; Live = $lm[$k];   Security = ($securityPaths -contains $k) } }
    })
    if ($drift.Count) { $r.status = 'DRIFT'; $r.drift = $drift; if ($exit -lt 1) { $exit = 1 } }
    $results += [pscustomobject]$r
  }

  # users on the appliance with no file
  $unmanaged = @($live | Where-Object { $matched -notcontains $_.id } | ForEach-Object {
    [pscustomobject]@{ id = $_.id; name = $_.name; role = $_.role; type = $_.type; mfaEnabled = $_.mfaEnabled }
  })
  if ($unmanaged -and $FailOnUnmanaged -and $exit -lt 1) { $exit = 1 }

  # --- output ---
  foreach ($r in $results) {
    $color = if ($r.status -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}: " -f $r.key, $r.name) -NoNewline
    Write-Host $r.status -ForegroundColor $color
    if ($r.status -eq 'MISSING') { Write-Host '  user is listed in the repo but does not exist on the appliance' -ForegroundColor Red }
    if ($r.drift.Count) {
      Write-DriftTable $r.drift
      foreach ($x in ($r.drift | Where-Object Security)) {
        Write-Host "  SECURITY: '$($x.Path)' differs for user '$($r.name)' (desired '$($x.Desired)', live '$($x.Live)')" -ForegroundColor Red
        if ($env:TF_BUILD) { Write-Host "##vso[task.logissue type=error]SECURITY drift: user '$($r.name)' $($x.Path) desired '$($x.Desired)' live '$($x.Live)'" }
      }
    }
  }
  if ($unmanaged) {
    Write-Host "`nUnmanaged users on the appliance (no file in $UserDir):" -ForegroundColor Yellow
    foreach ($x in $unmanaged) {
      Write-Host ("  {0}   role={1}  type={2}  mfa={3}" -f $x.name, $x.role, $x.type, $x.mfaEnabled) -ForegroundColor Yellow
      if ($env:TF_BUILD) { Write-Host "##vso[task.logissue type=warning]Unmanaged VBA user '$($x.name)' (role $($x.role))" }
    }
    # a missing user plus an unmanaged user with the same role is often a rename in the UI
    foreach ($m in ($results | Where-Object status -eq 'MISSING')) {
      $role = ($desired | Where-Object Key -eq $m.key).User.role
      $cand = @($unmanaged | Where-Object { $_.role -eq $role })
      if ($cand.Count -eq 1) { Write-Host "  HINT: '$($m.name)' may have been renamed to '$($cand[0].name)'" -ForegroundColor Yellow }
    }
  }

  [ordered]@{
    checkedUtc = (Get-Date).ToUniversalTime().ToString('o'); appliance = $Appliance; mode = 'detect-only'
    summary = [ordered]@{ ok = @($results | Where-Object status -eq 'OK').Count; drift = @($results | Where-Object status -eq 'DRIFT').Count
                          missing = @($results | Where-Object status -eq 'MISSING').Count; unmanaged = $unmanaged.Count }
    users = $results; unmanaged = $unmanaged
  } | ConvertTo-Json -Depth 10 | Set-Content $ReportPath -Encoding utf8
  Write-Host "`nReport: $ReportPath  (exit code $exit)"
}
finally { Disconnect-Vba $ctx }
exit $exit
