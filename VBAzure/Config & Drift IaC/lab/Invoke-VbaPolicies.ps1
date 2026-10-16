<#
.SYNOPSIS
  Create every Azure VM schedule-based backup policy defined in .\policies\*.json that does not exist yet,
  and record each one in state.json. Existing policies are left alone unless -Remediate is given, which updates
  drifted policies back to the desired state (preview first with -Remediate -DryRun).
  With -Remediate -Unmanaged Adopt|Delete it also handles policies that exist on the appliance with no policy file:
    Adopt  writes policies\<name>.json from the live policy and records it in state.json
    Delete removes the policy from the appliance (typed confirmation, or -Force)

.EXAMPLE
  .\Invoke-VbaPolicies.ps1 -Appliance <VBA-IP-ADDRESS> -Remediate -Unmanaged Adopt -DryRun
  .\Invoke-VbaPolicies.ps1 -Appliance <VBA-IP-ADDRESS> -Remediate -Unmanaged Delete

.EXAMPLE
  .\Invoke-VbaPolicies.ps1 -Appliance <VBA-IP-ADDRESS>
  .\Invoke-VbaPolicies.ps1 -Appliance <VBA-IP-ADDRESS> -ListIds
#>
param(
  [Parameter(Mandatory)] [string] $Appliance,
  [string] $ApiVersion = 'v8.1',
  [string] $PolicyDir  = '.\policies',
  [string] $StatePath  = '.\state.json',
  [int]    $RescanTimeoutSec = 300,
  [switch] $Remediate,                                 # also update existing policies that have drifted (PUT)
  [ValidateSet('Ignore','Adopt','Delete')] [string] $Unmanaged = 'Ignore',  # with -Remediate: what to do with policies that have no file/state
  [switch] $Force,                                     # with -Unmanaged Delete: skip the typed confirmation (needed in pipelines)
  [switch] $DryRun,                                   # with -Remediate: show what would change, change nothing
  [switch] $SkipRescan,
  [switch] $ListIds,                                   # print service accounts / regions / repositories and exit
  [pscredential] $Credential = (Get-Credential -Message 'VBA appliance user')
)
. "$PSScriptRoot\VbaCommon.ps1"

$ctx = Connect-Vba -Appliance $Appliance -ApiVersion $ApiVersion -Credential $Credential
$c = $ctx.Common; $h = $ctx.Headers; $api = $ctx.Api
$failed = 0
try {
  if ($ListIds) {
    'Service accounts:'; (Invoke-RestMethod @c -Headers $h -Uri "$api/accounts/azure/service").results | Format-Table accountId, name, tenantId
    'Regions:';          (Invoke-RestMethod @c -Headers $h -Uri "$api/cloudInfrastructure/regions").results  | Format-List *
    'Repositories:';     (Invoke-RestMethod @c -Headers $h -Uri "$api/repositories").results                | Format-List *
    return
  }

  $desired = Get-DesiredPolicies $PolicyDir
  $state   = Read-VbaState $StatePath
  $state.appliance = $Appliance
  $live    = @(Get-VbaPolicyList $ctx)

  $managedIds = @()
  foreach ($d in $desired) {
    $name = $d.Policy.name
    Write-Host "[$($d.Key)] $name"
    try {
      # Identify the live policy by the ID recorded in state (survives renames in the UI); fall back to the name.
      $stateId  = $state.policies[$d.Key].policyId
      $existing = $null
      if ($stateId) { $existing = $live | Where-Object { $_.id -eq $stateId } | Select-Object -First 1 }
      if (-not $existing) { $existing = $live | Where-Object { $_.name -eq $name } | Select-Object -First 1 }
      if ($existing) {
        $managedIds += $existing.id
        if ($existing.name -ne $name) {
          Write-Host "  RENAMED: live name is '$($existing.name)', desired name is '$name'" -ForegroundColor Red
          if (-not $Remediate) { Write-Host '  rerun with -Remediate to rename it back' -ForegroundColor Yellow }
        }
        if ($stateId -and $stateId -ne $existing.id) { $state.policies[$d.Key].policyId = $existing.id }   # same name, new ID: re-point state
      }
      $ensureTags = {
        if (-not $SkipRescan -and $d.Policy.selectedItems.tags) {
          $tags    = Get-VbaTags $ctx $d.Policy.serviceAccountId $d.Policy.tenantId $RescanTimeoutSec
          $missing = Get-MissingTags $tags $d.Policy.selectedItems.tags
          if ($missing) {
            $sample = ($tags | Select-Object -First 15 | ForEach-Object { "$($_.name)=$($_.value)" }) -join ', '
            throw "Tag(s) not visible to this service account: $(($missing | ForEach-Object { "$($_.name)=$($_.value)" }) -join ', '). VBA sees (first 15): $sample"
          }
        }
      }

      if ($existing) {
        if (-not $Remediate) {
          if (-not $state.policies.ContainsKey($d.Key)) {
            $state.policies[$d.Key] = @{ policyId = $existing.id; policyName = $name; adoptedUtc = (Get-Date).ToUniversalTime().ToString('o'); desiredHash = $d.Hash }
            Write-Host '  already exists - recorded in state (run Test-VbaPolicyDrift.ps1 to check it)'
          } else { Write-Host '  already exists - skipped' }
          continue
        }
        # -Remediate: bring the existing policy back to the desired state
        $drift = Get-PolicyDrift $ctx $d $existing.id
        if (-not $drift) { Write-Host '  no drift'; continue }
        if ($DryRun) { Write-RemediationTable $drift $null -DryRun; Write-Host '  DRY RUN - nothing changed' -ForegroundColor Yellow; continue }
        & $ensureTags
        Invoke-RestMethod @c -Headers $h -Method Put -Uri "$api/policies/virtualMachines/$($existing.id)" -ContentType 'application/json' -Body $d.Raw | Out-Null
        $after = Get-PolicyDrift $ctx $d $existing.id
        $snap  = Invoke-RestMethod @c -Headers $h -Uri "$api/policies/virtualMachines/$($existing.id)"
        $state.policies[$d.Key] = @{ policyId = $existing.id; policyName = $name; appliedUtc = (Get-Date).ToUniversalTime().ToString('o'); desiredHash = $d.Hash; liveAtApply = $snap }
        Write-VbaState $StatePath $state
        Write-RemediationTable $drift $after
        if ($after) { Write-Host "  RESULT: updated, but $($after.Count) setting(s) still differ from desired state" -ForegroundColor Red; $failed++ }
        else { Write-Host "  RESULT: $($drift.Count) setting(s) changed - policy now matches desired state" -ForegroundColor Green }
        continue
      }

      # Not on the appliance. If state says we created it before, it has been deleted: report it, and only recreate with -Remediate.
      if ($state.policies.ContainsKey($d.Key)) {
        Write-Host "  MISSING: policy was previously created (id $($state.policies[$d.Key].policyId)) but no longer exists on the appliance" -ForegroundColor Red
        if (-not $Remediate) { Write-Host '  not recreated - rerun with -Remediate to recreate it' -ForegroundColor Yellow; $failed++; continue }
        if ($DryRun)         { Write-Host '  DRY RUN - would recreate this policy' -ForegroundColor Yellow; continue }
      }
      elseif ($DryRun) { Write-Host '  DRY RUN - new policy, would create' -ForegroundColor Yellow; continue }

      & $ensureTags
      $res  = Invoke-RestMethod @c -Headers $h -Method Post -Uri "$api/policies/virtualMachines" -ContentType 'application/json' -Body $d.Raw
      $snap = Invoke-RestMethod @c -Headers $h -Uri "$api/policies/virtualMachines/$($res.id)"
      $managedIds += $res.id
      $state.policies[$d.Key] = @{ policyId = $res.id; policyName = $name; appliedUtc = (Get-Date).ToUniversalTime().ToString('o')
                                   desiredHash = $d.Hash; liveAtApply = $snap }
      Write-VbaState $StatePath $state                  # persist after every create so a later failure doesn't lose it
      Write-Host "  created  id=$($res.id)"
    }
    catch {
      $failed++
      Write-Host "  FAILED: $($_.Exception.Message) $($_.ErrorDetails.Message)" -ForegroundColor Red
    }
  }
  # Unmanaged policies: on the appliance but with no file in $PolicyDir (and so no state). Only handled with -Remediate -Unmanaged.
  # A plain -Remediate always flags them; -Unmanaged Adopt|Delete decides what to do about them.
  if ($Remediate) {
    $orphans = @(Get-VbaPolicyList $ctx | Where-Object { $managedIds -notcontains $_.id })   # by ID, so a renamed managed policy is not "unmanaged"
    foreach ($o in $orphans) {
      Write-Host "[unmanaged] $($o.name)  ($($o.id))" -ForegroundColor Yellow
      if ($Unmanaged -eq 'Ignore') { Write-Host '  no policy file or state - rerun with -Unmanaged Adopt or -Unmanaged Delete to resolve' -ForegroundColor Yellow; continue }
      try {
        if ($Unmanaged -eq 'Adopt') {
          $key  = ($o.name -replace '[^A-Za-z0-9._-]', '-').ToLower()
          $file = Join-Path $PolicyDir "$key.json"
          if (Test-Path $file) { Write-Host "  $file already exists - skipped" -ForegroundColor Red; $failed++; continue }
          if ($DryRun) { Write-Host "  DRY RUN - would write $file and add it to state"; continue }
          ConvertTo-DesiredFromLive $ctx $o.id | ConvertTo-Json -Depth 20 | Set-Content -Path $file -Encoding utf8
          $state.policies[$key] = @{ policyId = $o.id; policyName = $o.name; adoptedUtc = (Get-Date).ToUniversalTime().ToString('o')
                                     desiredHash = (Get-FileHash -Algorithm SHA256 $file).Hash }
          Write-Host "  adopted: wrote $file and recorded state - REVIEW the file, then commit it" -ForegroundColor Green
        }
        else {   # Delete
          if ($DryRun) { Write-Host '  DRY RUN - would DELETE this policy'; continue }
          if (-not $Force) {
            if (-not [Environment]::UserInteractive) { Write-Host '  not interactive and no -Force - skipped' -ForegroundColor Red; continue }
            if ((Read-Host "  Type DELETE to remove '$($o.name)'") -cne 'DELETE') { Write-Host '  skipped'; continue }
          }
          Invoke-RestMethod @c -Headers $h -Method Delete -Uri "$api/policies/virtualMachines/$($o.id)" | Out-Null
          Write-Host '  deleted' -ForegroundColor Green
        }
      }
      catch { $failed++; Write-Host "  FAILED: $($_.Exception.Message) $($_.ErrorDetails.Message)" -ForegroundColor Red }
    }
  }

  Write-VbaState $StatePath $state
  Write-Host "`nDone. $($desired.Count) policy file(s), $failed failed."
}
finally { Disconnect-Vba $ctx }
if ($failed) { exit 1 }
