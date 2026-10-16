# Backup repository drift check (detection only)

Checks the backup repositories on the Veeam Backup for Microsoft Azure appliance, including Veeam Data Cloud Vault repositories, against files in `repositories/`. It **only reads** from the appliance. It never creates, changes or removes repositories, and there is no apply pipeline.

> Status: written but not yet run. The repository list format (`GET /repositories`) follows the v8.1 REST reference, but confirm it on the first run.

## Files

```
scripts/Get-VbaRepositoryBaseline.ps1   run LOCALLY to collect the baseline (read-only)
scripts/Test-VbaRepositoryDrift.ps1     the drift check
scripts/VbaRepoCommon.ps1               helpers for both (VbaCommon.ps1 is unchanged)
repositories/*.json                     one file per repository (desired state)
azure-pipelines/drift-check-repositories.yml   weekly pipeline
```

## Step 1. Collect the baseline locally

On your PC, from the repo folder (PowerShell 7):

```powershell
.\scripts\Get-VbaRepositoryBaseline.ps1 -Appliance <VBA-IP-ADDRESS>
```

You are asked for the VBA user and password. It then:

1. Prints a review table with name, type, status, tier, immutability, encryption, storage account/container/folder, region and whether another owner is reported.
2. Saves everything the API returned to `repositories-raw.json` (for your reference only; it is git-ignored).
3. Writes one file per repository into `repositories/`. It never overwrites an existing file unless you add `-Force`.

It only reads from the appliance. Nothing is changed.

## Step 2. Review the files

The baseline records **what exists today**, not necessarily what should exist. For each file check:

- `immutabilityEnabled` and `enableEncryption` are what you intend.
- `storageTier`, `repositoryType` and the storage account/container/folder are correct.
- Delete the file of any repository you don't want managed.
- Remove any setting you don't want enforced. `status` is the most likely one: it flags a repository that goes `ReadOnly` or `Failed`, which is useful, but you may not want it during planned work.

Example of a file:

```json
{
  "id": "…",
  "name": "vault-prod",
  "repositoryType": "VeeamVault",
  "status": "Ready",
  "storageTier": "Cool",
  "immutabilityEnabled": true,
  "enableEncryption": true,
  "concurrencyLimit": 4,
  "azureStorageAccountName": "…",
  "azureStorageContainer": { "name": "…", "ImmutabilityPolicyState": "…" },
  "azureStorageFolder": { "name": "…" }
}
```

No passwords or keys are stored. The API doesn't return encryption passwords, so they can't be checked.

## Step 3. Test the check by hand

```powershell
.\scripts\Test-VbaRepositoryDrift.ps1 -Appliance <VBA-IP-ADDRESS> -FailOnUnmanaged
```

Every repository should show `OK`. Fix any difference by editing the file if the file is wrong, or by changing the repository on the appliance if the appliance is wrong.

## Step 4. Add the pipeline

1. Commit `repositories/`, the three new scripts and `azure-pipelines/drift-check-repositories.yml` to `main`. Don't commit `repositories-raw.json`; add it to `.gitignore`.
2. Edit the `variables:` block in `drift-check-repositories.yml` to match your other pipelines.
3. In Azure DevOps: **Pipelines > New pipeline > Existing Azure Pipelines YAML file**, path `/azure-pipelines/drift-check-repositories.yml`, name it `vba-repository-drift-check`. Select **Permit** for the service connection on the first run, as before.

## What is reported

| Result | Meaning |
|---|---|
| OK | The repository exists and matches its file |
| DRIFT | A listed setting differs. Immutability, encryption, tier and type differences are marked **PROTECTION** in red and raised as pipeline errors |
| ID changed | The file's ID no longer exists but a repository with the same name does. The repository was probably removed and added again |
| MISSING | A file exists but the repository doesn't |
| Unmanaged | A repository exists with no file. Raised as a pipeline warning and fails the run (`-FailOnUnmanaged`) |
| Rename hint | A missing repository plus an unmanaged one in the same storage account and container may be a rename |
| NOTE: another owner | The appliance reports the repository belongs to a different appliance |

Exit codes: 0 clean, 1 drift or unmanaged, 2 missing or check failed.

## Test it

1. Run the pipeline. It should be green.
2. Change a harmless setting on a test repository (for example its description or concurrency limit) and run again. It should go red and show the difference.
3. Add a new repository by hand and confirm it is reported as unmanaged.
4. Put everything back and confirm it returns to green.

## Limits

- Detection only. Fix a difference in the portal, or edit the file through a reviewed pull request.
- The repo is the source of truth. If someone changes both a repository and its file, the check reports OK. Protect `main` with required reviewers.
- The check sees the settings the API returns for a repository. It can't see encryption keys or passwords.
- Veeam Data Cloud Vault itself (registration and the list of vaults) is checked separately by `Test-VbaVaults.ps1`.
