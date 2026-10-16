<#
.SYNOPSIS
  DETECTION ONLY. Compares the backup repositories on a Veeam Backup for Microsoft Azure appliance (including
  Veeam Data Cloud Vault repositories) with the desired state in .\repositories\*.json and reports differences.
  It never creates, changes or deletes anything on the appliance: it signs in, reads the repository list, signs out.

  Reports: drift in protection settings (immutability, encryption, storage tier, type), other drift (name, status,
  limits, storage location), missing repositories, and unmanaged repositories (no file in the repo).

.NOTES
  Needs VbaCommon.ps1 and VbaRepoCommon.ps1 in the same folder.
  Matching: by repository ID if the file has one, otherwise by name. If the ID in the file no longer exists but a
  repository with the same name does, an 'id' difference is reported (the repository was probably deleted and re-added).
  Exit codes: 0 = no differences, 1 = drift (or unmanaged repositories with -FailOnUnmanaged), 2 = a listed repository is missing / check failed.

  To create the repositories\ files in the first place, run Get-VbaRepositoryBaseline.ps1 locally.

.EXAMPLE
  .\Test-VbaRepositoryDrift.ps1 -Appliance <VBA-IP-ADDRESS> -FailOnUnmanaged
#>
param(
  [Parameter(Mandatory)] [string] $Appliance,
  [string] $ApiVersion = 'v8.1',
  [string] $RepoDir    = './repositories',
  [string] $ReportPath = './repository-drift-report.json',
  [switch] $FailOnUnmanaged,
  [pscredential] $Credential
)
. "$PSScriptRoot/VbaCommon.ps1"
. "$PSScriptRoot/VbaRepoCommon.ps1"
if (-not $Credential) { $Credential = Get-VbaCredential }

# Settings that protect the backup data; drift here is labelled PROTECTION
$protectionPaths = @('immutabilityEnabled', 'enableEncryption', 'storageTier', 'repositoryType', 'azureStorageContainer.ImmutabilityPolicyState')

$files = Get-ChildItem -Path $RepoDir -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $files) { throw "No repository files found in $RepoDir (run Get-VbaRepositoryBaseline.ps1 locally to create a baseline)" }
$desired = foreach ($f in $files) { [pscustomobject]@{ Key = $f.BaseName; Repo = (Get-Content -Raw $f.FullName | ConvertFrom-Json) } }
$dupes = $desired | Group-Object { $_.Repo.name } | Where-Object Count -gt 1
if ($dupes) { throw "Duplicate repository names in $RepoDir`: $($dupes.Name -join ', ')" }

$ctx = Connect-Vba -Appliance $Appliance -ApiVersion $ApiVersion -Credential $Credential
$exit = 0
try {
  $live = @(Get-VbaRepositories $ctx)       # the only appliance call besides sign-in/out

  $results = @(); $matched = @()
  foreach ($d in $desired) {
    $r = [ordered]@{ key = $d.Key; name = $d.Repo.name; status = 'OK'; drift = @() }
    $u = $null
    if ($d.Repo.id) { $u = $live | Where-Object { $_.id -eq $d.Repo.id } | Select-Object -First 1 }
    if (-not $u)    { $u = $live | Where-Object { $_.name -eq $d.Repo.name } | Select-Object -First 1 }
    if (-not $u) { $r.status = 'MISSING'; if ($exit -lt 2) { $exit = 2 }; $results += [pscustomobject]$r; continue }
    $matched += $u.id
    $u = Add-RepoDerived $u          # adds storageConsumptionLimitEnabled so an off/on change can be compared

    $dm = ConvertTo-FlatMap $d.Repo
    $lm = ConvertTo-FlatMap $u
    $drift = @(foreach ($k in $dm.Keys) {
      $prot = $protectionPaths -contains $k
      if (-not $lm.Contains($k))   { [pscustomobject]@{ Path = $k; Desired = $dm[$k]; Live = '(absent)'; Security = $prot } }
      elseif ($lm[$k] -ne $dm[$k]) { [pscustomobject]@{ Path = $k; Desired = $dm[$k]; Live = $lm[$k];   Security = $prot } }
    })
    if ($drift.Count) { $r.status = 'DRIFT'; $r.drift = $drift; if ($exit -lt 1) { $exit = 1 } }
    $r.otherOwner = [bool]$u.repositoryOwnership.hasAnotherOwner
    $results += [pscustomobject]$r
  }

  $unmanaged = @($live | Where-Object { $matched -notcontains $_.id } | ForEach-Object {
    [pscustomobject]@{ id = $_.id; name = $_.name; type = $_.repositoryType; tier = $_.storageTier; immutable = $_.immutabilityEnabled
                       account = $_.azureStorageAccountName; container = $_.azureStorageContainer.name; folder = $_.azureStorageFolder.name }
  })
  if ($unmanaged -and $FailOnUnmanaged -and $exit -lt 1) { $exit = 1 }

  # ---- output ----
  foreach ($r in $results) {
    $color = if ($r.status -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}: " -f $r.key, $r.name) -NoNewline
    Write-Host $r.status -ForegroundColor $color
    if ($r.status -eq 'MISSING') { Write-Host '  repository is listed in the repo but does not exist on the appliance' -ForegroundColor Red }
    if ($r.otherOwner) { Write-Host '  NOTE: this repository reports another owner (it may be in use by a different appliance)' -ForegroundColor Yellow }
    if ($r.drift.Count) {
      Write-DriftTable $r.drift
      foreach ($x in ($r.drift | Where-Object Security)) {
        Write-Host "  PROTECTION: '$($x.Path)' differs for repository '$($r.name)' (desired '$($x.Desired)', live '$($x.Live)')" -ForegroundColor Red
        if ($env:TF_BUILD) { Write-Host "##vso[task.logissue type=error]PROTECTION drift: repository '$($r.name)' $($x.Path) desired '$($x.Desired)' live '$($x.Live)'" }
      }
      if ($r.drift | Where-Object { $_.Path -eq 'id' }) {
        Write-Host '  NOTE: the repository ID changed. The repository was probably removed and added again.' -ForegroundColor Yellow
      }
    }
  }
  if ($unmanaged) {
    Write-Host "`nUnmanaged repositories on the appliance (no file in $RepoDir):" -ForegroundColor Yellow
    foreach ($x in $unmanaged) {
      Write-Host ("  {0}   type={1}  tier={2}  immutable={3}  {4}/{5}/{6}" -f $x.name, $x.type, $x.tier, $x.immutable, $x.account, $x.container, $x.folder) -ForegroundColor Yellow
      if ($env:TF_BUILD) { Write-Host "##vso[task.logissue type=warning]Unmanaged VBA repository '$($x.name)' (type $($x.type))" }
    }
    # a missing repository plus an unmanaged one in the same storage account and container is often a rename in the UI
    foreach ($m in ($results | Where-Object status -eq 'MISSING')) {
      $want = ($desired | Where-Object Key -eq $m.key).Repo
      $cand = @($unmanaged | Where-Object { $want.azureStorageAccountName -and $_.account -eq $want.azureStorageAccountName -and $_.container -eq $want.azureStorageContainer.name })
      if ($cand.Count -eq 1) { Write-Host "  HINT: '$($m.name)' may have been renamed to '$($cand[0].name)'" -ForegroundColor Yellow }
    }
  }

  [ordered]@{
    checkedUtc = (Get-Date).ToUniversalTime().ToString('o'); appliance = $Appliance; mode = 'detect-only'
    summary = [ordered]@{ ok = @($results | Where-Object status -eq 'OK').Count; drift = @($results | Where-Object status -eq 'DRIFT').Count
                          missing = @($results | Where-Object status -eq 'MISSING').Count; unmanaged = $unmanaged.Count }
    repositories = $results; unmanaged = $unmanaged
  } | ConvertTo-Json -Depth 10 | Set-Content $ReportPath -Encoding utf8
  Write-Host "`nReport: $ReportPath  (exit code $exit)"
}
finally { Disconnect-Vba $ctx }
exit $exit
