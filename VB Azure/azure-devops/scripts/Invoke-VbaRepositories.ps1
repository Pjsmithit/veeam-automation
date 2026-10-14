<#
.SYNOPSIS
  Brings the EDITABLE settings of EXISTING backup repositories back to the desired state in .\repositories\*.json.

  What it changes (only these): name, description, concurrency limit, and the storage consumption limit
  (on/off, value and unit).
  What it never does: delete repositories, or change immutability, encryption, storage tier, repository type
  or storage location of an existing repository. Differences in those are reported in red as "change manually".

  With -CreateMissing it also CREATES repositories that are in a file but not on the appliance.
    Customer-owned Azure storage (type Backup): the file needs azureAccountId, azureStorageAccountId,
      azureStorageContainer.name and azureStorageFolder.name (the baseline script records them).
    Veeam Data Cloud Vault (type VeeamVault): the appliance must already be registered with Vault (one-time, in the
      portal). The vault is found by veeamVaultId (or storage account + container), imported with
      POST /veeamVaults/importAccount, and the returned account/container details are used to add the repository.
      The file needs azureStorageFolder.name (the folder to create in the vault). Vault repositories are always encrypted.
  If encryption applies, the repository password must be supplied in the environment variable VBA_REPO_PASSWORD
  (from Key Vault in the pipeline), never in the file.

  Always preview first with -DryRun. Each change is re-read from the appliance afterwards and shown in a
  DISCOVERED / DESIRED / REMEDIATED table, so you can see whether it really took effect.

.NOTES
  Needs VbaCommon.ps1 and VbaRepoCommon.ps1 in the same folder.
  Exit codes: 0 = nothing to do or everything fixed, 1 = a change failed or non-editable differences remain,
              2 = a listed repository does not exist on the appliance.

  UNCONFIRMED: the exact PUT /repositories/{id} request body. The script reads the current values, overlays the
  desired ones and sends name, description, concurrencyLimit and storageConsumptionLimit. A 400 response names the
  field to adjust. A limit switched OFF is sent as storageConsumptionLimit = null (also unconfirmed); the re-read
  check will show NOT CHANGED if the appliance does not accept it.

.EXAMPLE
  .\Invoke-VbaRepositories.ps1 -Appliance <VBA-IP-ADDRESS> -DryRun
  .\Invoke-VbaRepositories.ps1 -Appliance <VBA-IP-ADDRESS>
#>
param(
  [Parameter(Mandatory)] [string] $Appliance,
  [string] $ApiVersion = 'v8.1',
  [string] $RepoDir    = './repositories',
  [string] $ReportPath = './repository-apply-report.json',
  [int]    $WaitSeconds = 60,
  [switch] $CreateMissing,                 # also CREATE repositories that are in a file but not on the appliance (customer-owned Azure storage only)
  [switch] $ImportIfFolderHasBackup,       # with -CreateMissing: import backups already in the target folder (use when re-adding a repository)
  [int]    $CreateWaitSeconds = 600,
  [switch] $DryRun,
  [pscredential] $Credential
)
. "$PSScriptRoot/VbaCommon.ps1"
. "$PSScriptRoot/VbaRepoCommon.ps1"
if (-not $Credential) { $Credential = Get-VbaCredential }

# Settings this script is allowed to change
$editable = '^(name|description|concurrencyLimit|storageConsumptionLimitEnabled|storageConsumptionLimit\..+)$'

$files = Get-ChildItem -Path $RepoDir -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $files) { throw "No repository files found in $RepoDir" }
$desired = foreach ($f in $files) { [pscustomobject]@{ Key = $f.BaseName; Repo = (Get-Content -Raw $f.FullName | ConvertFrom-Json) } }
$dupes = $desired | Group-Object { $_.Repo.name } | Where-Object Count -gt 1
if ($dupes) { throw "Duplicate repository names in $RepoDir`: $($dupes.Name -join ', ')" }

$ctx = Connect-Vba -Appliance $Appliance -ApiVersion $ApiVersion -Credential $Credential
$c = $ctx.Common; $h = $ctx.Headers; $api = $ctx.Api
$exit = 0; $report = @(); $matched = @()
if ($DryRun) { Write-Host 'DRY RUN: nothing will be changed.' -ForegroundColor Yellow }
try {
  $live = @(Get-VbaRepositories $ctx)

  foreach ($d in $desired) {
    $name = $d.Repo.name
    Write-Host "[$($d.Key)] $name"
    $entry = [ordered]@{ key = $d.Key; name = $name; result = 'no change'; changed = @(); manual = @() }
    try {
      $u = $null
      if ($d.Repo.id) { $u = $live | Where-Object { $_.id -eq $d.Repo.id } | Select-Object -First 1 }
      if (-not $u)    { $u = $live | Where-Object { $_.name -eq $name } | Select-Object -First 1 }
      if (-not $u) {
        if (-not $CreateMissing) {
          Write-Host '  MISSING: repository does not exist on the appliance. Rerun with -CreateMissing to create it.' -ForegroundColor Red
          $entry.result = 'missing'; if ($exit -lt 2) { $exit = 2 }; $report += [pscustomobject]$entry; continue
        }

        # ---------- create the missing repository (customer-owned Azure storage only) ----------
        $r = $d.Repo
        $isVault   = ($r.repositoryType -eq 'VeeamVault')
        $acctId    = $r.azureAccountId; $saId = $r.azureStorageAccountId
        $container = $r.azureStorageContainer.name; $folder = $r.azureStorageFolder.name

        if ($isVault) {
          # Veeam Data Cloud Vault: the appliance must be registered, and the vault must exist and be writable.
          # The account and container details come from importing the vault (done below, after the dry-run check).
          $reg = Invoke-RestMethod @c -Headers $h -Uri "$api/veeamVaults/registration"
          if (-not $reg.instanceRegistered) {
            Write-Host '  CANNOT CREATE: the appliance is not registered with Veeam Data Cloud Vault (a one-time step in the portal).' -ForegroundColor Red
            $entry.result = 'cannot create'; if ($exit -lt 1) { $exit = 1 }; $report += [pscustomobject]$entry; continue
          }
          # The vault list can arrive as an array nested inside an array; flatten it so each item is one vault
          $vaults = @(@(Invoke-RestMethod @c -Headers $h -Uri "$api/veeamVaults") | ForEach-Object { $_ })
          $vault = $null
          if ($null -ne $r.veeamVaultId) { $vault = $vaults | Where-Object { "$($_.id)" -eq "$($r.veeamVaultId)" } | Select-Object -First 1 }
          if (-not $vault -and $r.azureStorageAccountName) {
            $vault = $vaults | Where-Object { $_.storageAccountName -eq $r.azureStorageAccountName -and $_.storageContainerName -eq $container } | Select-Object -First 1
          }
          $vault = @($vault)[0]      # exactly one vault from here on
          if (-not $vault) {
            Write-Host '  CANNOT CREATE: the vault was not found among the vaults connected to this appliance (Test-VbaVaults.ps1 lists them).' -ForegroundColor Red
            $entry.result = 'cannot create'; if ($exit -lt 1) { $exit = 1 }; $report += [pscustomobject]$entry; continue
          }
          if ($vault.isReadOnly) {
            Write-Host "  CANNOT CREATE: vault '$($vault.name)' is read-only: $($vault.readOnlyReason)" -ForegroundColor Red
            $entry.result = 'cannot create'; if ($exit -lt 1) { $exit = 1 }; $report += [pscustomobject]$entry; continue
          }
          if (-not $folder) {
            Write-Host '  CANNOT CREATE: the file has no azureStorageFolder.name (the folder to create in the vault).' -ForegroundColor Red
            $entry.result = 'cannot create'; if ($exit -lt 1) { $exit = 1 }; $report += [pscustomobject]$entry; continue
          }
        }
        else {
          $need = [ordered]@{
            azureAccountId = $acctId; azureStorageAccountId = $saId
            'azureStorageContainer.name' = $container; 'azureStorageFolder.name' = $folder
          }
          $lack = @($need.Keys | Where-Object { -not $need[$_] })
          if ($lack) {
            Write-Host "  CANNOT CREATE: the file is missing: $($lack -join ', '). Re-collect the baseline (it now records these) and copy them in." -ForegroundColor Red
            $entry.result = 'cannot create'; if ($exit -lt 1) { $exit = 1 }; $report += [pscustomobject]$entry; continue
          }
        }
        $pw = $null
        if ($r.enableEncryption -or $isVault) {   # Veeam Data Cloud Vault does not allow unencrypted repositories
          $pw = $env:VBA_REPO_PASSWORD
          if (-not $pw -or $pw -like '$(*') {
            Write-Host '  CANNOT CREATE: the file says encryption is on, but no repository password was supplied (environment variable VBA_REPO_PASSWORD).' -ForegroundColor Red
            $entry.result = 'cannot create'; if ($exit -lt 1) { $exit = 1 }; $report += [pscustomobject]$entry; continue
          }
        }

        $where = if ($isVault) { "Veeam Data Cloud Vault '$($vault.name)', folder '$folder'" } else { "$($r.azureStorageAccountName)/$container/$folder" }
        if ($DryRun) {
          $imp1 = if ($isVault) { 'would import the vault first, then ' } else { '' }
          Write-Host "  DRY RUN - ${imp1}would CREATE repository '$name' at $where (tier $($r.storageTier), encryption $([bool]($r.enableEncryption -or $isVault)), import existing backups $([bool]$ImportIfFolderHasBackup))" -ForegroundColor Yellow
          $entry.result = 'dry run (create)'; $report += [pscustomobject]$entry; continue
        }

        if ($isVault) {
          # Import the vault's data into the appliance (this writes to its configuration database). The reference says it answers
          # 200 (details in the body) or 202 (accepted: runs in the background). For 202 the details are expected in the result of
          # the asynchronous operation, GET /operations/{operationId}, so look for an operation ID in the body or Location header.
          $resp = Invoke-WebRequest @c -Headers $h -Method Post -Uri "$api/veeamVaults/importAccount" -ContentType 'application/json' -Body (@{ veeamVaultId = [int64]$vault.id } | ConvertTo-Json)
          $code = [int]$resp.StatusCode
          $imp = $null
          try { if ($resp.Content) { $imp = $resp.Content | ConvertFrom-Json } } catch {}
          $loc = @($resp.Headers['Location'])[0]
          $diag = "HTTP $code; Location: '$loc'; body: '$("$($resp.Content)".Substring(0, [Math]::Min(500, "$($resp.Content)".Length)))'"
          $op = $null

          if (-not $imp.storageAccount.id) {
            $opId = $null
            foreach ($cand in @($imp.operationId, $imp.id)) { if ("$cand" -match '^[0-9a-fA-F-]{36}$') { $opId = "$cand"; break } }
            if (-not $opId -and $loc -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $opId = $Matches[1] }
            if ($opId) {
              Write-Host "  vault import started in the background (operation $opId), waiting..."
              $deadline = (Get-Date).AddSeconds(180)
              do {
                Start-Sleep -Seconds 5
                $op = Invoke-RestMethod @c -Headers $h -Uri "$api/operations/$opId"
              } while ("$($op.status)" -notmatch 'Succe|Complet|Fail|Cancel|Error' -and (Get-Date) -lt $deadline)
              if ("$($op.status)" -match 'Fail|Cancel|Error') { throw "Vault import operation $($op.status): $($op.error.detail) $($op.error.title)" }
              if ($op.result.storageAccount.id) { $imp = $op.result }
              $diag += "; operation: $(($op | ConvertTo-Json -Depth 6 -Compress))"
            }
          }
          if (-not $imp.storageAccount.id) { throw "Importing the vault did not return storage account details. Details for diagnosis: $diag" }
          $acctId = $imp.azureAccountId; $saId = $imp.storageAccount.id; $container = $imp.storageAccountContainer
          Write-Host "  vault imported: storage account '$($imp.storageAccount.name)', container '$container'"
        }

        $body = [ordered]@{
          name = $name; azureAccountId = $acctId; azureStorageAccountId = $saId
          azureStorageContainer = $container; azureStorageFolder = $folder
          enableEncryption = [bool]($r.enableEncryption -or $isVault); importIfFolderHasBackup = [bool]$ImportIfFolderHasBackup; autoCreateTiers = $false
        }
        if ($r.description)                                    { $body['description']      = $r.description }
        if ($r.storageTier -and $r.storageTier -ne 'Unknown')  { $body['storageTier']      = $r.storageTier }
        if ($r.concurrencyLimit)                               { $body['concurrencyLimit'] = $r.concurrencyLimit }
        if ($pw)                                               { $body['password']         = $pw }
        if ($r.storageConsumptionLimitEnabled -and $r.storageConsumptionLimit) {
          $body['storageConsumptionLimit'] = [ordered]@{ limitValue = $r.storageConsumptionLimit.limitValue; limitType = $r.storageConsumptionLimit.limitType }
        }

        Invoke-RestMethod @c -Headers $h -Method Post -Uri "$api/repositories" -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5) | Out-Null   # 202 Accepted: created in the background
        Write-Host "  creating repository at $where ..."
        $deadline = (Get-Date).AddSeconds($CreateWaitSeconds)
        do {
          Start-Sleep -Seconds 10
          $new = @(Get-VbaRepositories $ctx) | Where-Object { $_.name -eq $name } | Select-Object -First 1
        } while ((-not $new -or $new.status -in 'Creating', 'Importing') -and (Get-Date) -lt $deadline)

        if (-not $new) { throw "Repository '$name' did not appear within $CreateWaitSeconds seconds." }
        if ($new.status -ne 'Ready') { throw "Repository '$name' was created but its status is '$($new.status)'." }
        $matched += $new.id
        Write-Host "  RESULT: created, status Ready, new id $($new.id)" -ForegroundColor Green
        $left = @(Get-RepoDrift $d.Repo $new)
        if ($left) {
          Write-Host '  Settings in the file that still differ from the new repository (the id is expected to; update it in the file):' -ForegroundColor Yellow
          Write-DriftTable $left
        }
        $entry.result = 'created'; $entry.newId = $new.id; $report += [pscustomobject]$entry; continue
      }
      $matched += $u.id

      $drift   = Get-RepoDrift $d.Repo $u
      $fixable = @($drift | Where-Object { $_.Path -match $editable })
      $manual  = @($drift | Where-Object { $_.Path -notmatch $editable })

      if ($manual) {
        Write-Host '  NOT FIXABLE HERE (change in the portal, or update the file after review):' -ForegroundColor Red
        Write-DriftTable $manual
        $entry.manual = $manual; if ($exit -lt 1) { $exit = 1 }
      }
      if (-not $fixable) { if (-not $manual) { Write-Host '  no drift' -ForegroundColor Green }; $report += [pscustomobject]$entry; continue }

      if ($DryRun) {
        Write-RemediationTable $fixable $null -DryRun
        $entry.result = 'dry run'; $entry.changed = $fixable; $report += [pscustomobject]$entry; continue
      }

      # Read-modify-write: start from the current values, overlay the desired ones, send only the editable settings
      $cur  = Add-RepoDerived (Invoke-RestMethod @c -Headers $h -Uri "$api/repositories/$($u.id)")
      $have = $d.Repo.PSObject.Properties.Name
      $body = [ordered]@{}
      foreach ($p in 'name', 'description', 'concurrencyLimit') {
        $v = if ($have -contains $p) { $d.Repo.$p } else { $cur.$p }
        if ($null -ne $v) { $body[$p] = $v }
      }
      # The update validates the whole repository, so settings we are NOT changing must be sent as they are today.
      # Leaving enableEncryption out makes it default to false, which Veeam Data Cloud Vault rejects (HTTP 400).
      if ($null -ne $cur.enableEncryption) { $body['enableEncryption'] = [bool]$cur.enableEncryption }
      $wantLimit = if ($have -contains 'storageConsumptionLimitEnabled') { [bool]$d.Repo.storageConsumptionLimitEnabled } else { [bool]$cur.storageConsumptionLimitEnabled }
      if ($wantLimit) {
        $lim = if ($d.Repo.storageConsumptionLimit) { $d.Repo.storageConsumptionLimit } else { $cur.storageConsumptionLimit }
        $body['storageConsumptionLimit'] = [ordered]@{ limitValue = $lim.limitValue; limitType = $lim.limitType }
      } else { $body['storageConsumptionLimit'] = $null }

      Invoke-RestMethod @c -Headers $h -Method Put -Uri "$api/repositories/$($u.id)" -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5) | Out-Null

      # The change may be applied asynchronously: re-read until the editable settings match, or time out
      $deadline = (Get-Date).AddSeconds($WaitSeconds)
      do {
        Start-Sleep -Seconds 4
        $now   = Invoke-RestMethod @c -Headers $h -Uri "$api/repositories/$($u.id)"
        $after = @(Get-RepoDrift $d.Repo $now | Where-Object { $_.Path -match $editable })
      } while ($after.Count -gt 0 -and (Get-Date) -lt $deadline)

      Write-RemediationTable $fixable $after
      $entry.changed = $fixable; $entry.remaining = $after
      if ($after) { Write-Host "  RESULT: updated, but $($after.Count) setting(s) still differ from the desired state" -ForegroundColor Red; $entry.result = 'incomplete'; if ($exit -lt 1) { $exit = 1 } }
      else        { Write-Host "  RESULT: $($fixable.Count) setting(s) changed - repository now matches the desired state" -ForegroundColor Green; $entry.result = 'fixed' }
    }
    catch {
      Write-Host "  FAILED: $($_.Exception.Message) $($_.ErrorDetails.Message)" -ForegroundColor Red
      $entry.result = 'error'; $entry.error = "$($_.Exception.Message) $($_.ErrorDetails.Message)"; if ($exit -lt 1) { $exit = 1 }
    }
    $report += [pscustomobject]$entry
  }

  $unmanaged = @($live | Where-Object { $matched -notcontains $_.id })
  if ($unmanaged) {
    Write-Host "`nRepositories on the appliance with no file in $RepoDir (left alone):" -ForegroundColor Yellow
    $unmanaged | ForEach-Object { Write-Host "  $($_.name)  type=$($_.repositoryType)" -ForegroundColor Yellow }
  }

  [ordered]@{ ranUtc = (Get-Date).ToUniversalTime().ToString('o'); appliance = $Appliance; dryRun = [bool]$DryRun
              repositories = $report; unmanaged = @($unmanaged | ForEach-Object { $_.name }) } |
    ConvertTo-Json -Depth 10 | Set-Content $ReportPath -Encoding utf8
  Write-Host "`nReport: $ReportPath  (exit code $exit)"
}
finally { Disconnect-Vba $ctx }
exit $exit
