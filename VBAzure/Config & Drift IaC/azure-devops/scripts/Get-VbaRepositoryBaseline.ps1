<#
.SYNOPSIS
  Run this LOCALLY to collect a baseline of the backup repositories currently on the appliance.
  Writes one JSON file per repository into ./repositories (the desired-state files for Test-VbaRepositoryDrift.ps1),
  prints a review table, and saves a raw copy of everything the API returned for your reference.

  READ-ONLY on the appliance: it signs in, reads the repository list, and signs out. It only writes local files.
  It never overwrites an existing file unless you pass -Force.

.EXAMPLE
  .\scripts\Get-VbaRepositoryBaseline.ps1 -Appliance <VBA-IP-ADDRESS>
  .\scripts\Get-VbaRepositoryBaseline.ps1 -Appliance <VBA-IP-ADDRESS> -OutDir ./repositories -Force
#>
param(
  [Parameter(Mandatory)] [string] $Appliance,
  [string] $ApiVersion = 'v8.1',
  [string] $OutDir     = './repositories',
  [string] $RawPath    = './repositories-raw.json',     # full API output, for reference only (git-ignored; do not commit)
  [switch] $Force,                                      # overwrite existing baseline files
  [pscredential] $Credential
)
. "$PSScriptRoot/VbaCommon.ps1"
. "$PSScriptRoot/VbaRepoCommon.ps1"
if (-not $Credential) { $Credential = Get-VbaCredential }

$ctx = Connect-Vba -Appliance $Appliance -ApiVersion $ApiVersion -Credential $Credential
try {
  $repos = Get-VbaRepositories $ctx
  if (-not $repos) { Write-Host 'No repositories found on the appliance.' -ForegroundColor Yellow; return }

  # Review table: everything worth checking before you accept this as the standard
  Write-Host "`nRepositories found: $($repos.Count)`n"
  $repos | ForEach-Object {
    [pscustomobject]@{
      Name       = $_.name
      Type       = $_.repositoryType
      Status     = $_.status
      Tier       = $_.storageTier
      Immutable  = $_.immutabilityEnabled
      Encrypted  = $_.enableEncryption
      Account    = $_.azureStorageAccountName
      Container  = $_.azureStorageContainer.name
      Folder     = $_.azureStorageFolder.name
      Region     = $_.regionName
      OtherOwner = $_.repositoryOwnership.hasAnotherOwner
    }
  } | Format-Table -AutoSize | Out-String | Write-Host

  # Raw copy of the API response
  $repos | ConvertTo-Json -Depth 20 | Set-Content -Path $RawPath -Encoding utf8
  Write-Host "Raw API output saved to $RawPath (reference only, do not commit)."

  # One desired-state file per repository
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  foreach ($r in $repos) {
    $key  = ($r.name -replace '[^A-Za-z0-9._-]', '-').ToLower()
    $file = Join-Path $OutDir "$key.json"
    if ((Test-Path $file) -and -not $Force) { Write-Host "skipped (exists, use -Force to overwrite): $file" -ForegroundColor Yellow; continue }
    ConvertTo-RepoBaseline $r | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding utf8
    Write-Host "wrote $file" -ForegroundColor Green
  }

  Write-Host @"

Next:
  1. Open the files in $OutDir and check each setting is what it SHOULD be (this records what exists today).
  2. Delete the file of any repository you do not want managed.
  3. Remove settings you do not want enforced (for example 'status' if it is often transient).
  4. Run  .\scripts\Test-VbaRepositoryDrift.ps1 -Appliance $Appliance  and confirm every repository shows OK.
  5. Commit $OutDir to the repo (do NOT commit $RawPath).
"@
}
finally { Disconnect-Vba $ctx }
