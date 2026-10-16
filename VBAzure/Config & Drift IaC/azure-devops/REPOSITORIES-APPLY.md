# Applying repository settings

`apply-repositories.yml` brings the **editable** settings of **existing** backup repositories back to the desired state in `repositories/*.json`. Use `drift-check-repositories.yml` first to see what differs.

> Status: written but not yet run. The request body for `PUT /repositories/{id}` could not be confirmed in the reference, so the first runs need care (see below).

## What it can and can't do

| It changes | It never touches |
|---|---|
| Name | Deleting repositories |
| Description | Immutability |
| Concurrency limit | Encryption |
| Storage consumption limit: on/off, value and unit | Storage tier, repository type, storage account/container/folder |

If a file differs from the appliance in something it never touches, the run prints it in red as **NOT FIXABLE HERE** and exits 1. Change those in the portal, or update the file after review.

If a repository in a file doesn't exist on the appliance, it's reported as **MISSING** (exit 2) unless you turn on **Create missing repositories** (see below). It never deletes repositories.

## Creating missing repositories (opt-in)

Off by default. Turn on the pipeline's **createMissing** option (or `-CreateMissing` in the script) to create repositories that are in a file but not on the appliance. It handles two kinds: repositories on **customer-owned Azure storage** (type `Backup`) and **Veeam Data Cloud Vault** repositories (type `VeeamVault`, see below).

Each file to be created must contain `azureAccountId`, `azureStorageAccountId`, `azureStorageContainer.name` and `azureStorageFolder.name`. The baseline script now records them, so re-collect a baseline and copy them into your file:

```powershell
.\scripts\Get-VbaRepositoryBaseline.ps1 -Appliance <VBA-IP-ADDRESS> -OutDir ./tmp-baseline
```

What it sends: name, description, storage tier, concurrency limit, the storage consumption limit if one is set, and encryption on/off. It doesn't send immutability, because the appliance takes that from the Azure container's own policy. The drift check shows whether it matches afterwards.

- **Encryption password:** if the file says encryption is on, the password must be supplied. In the pipeline, store it in Key Vault as the secret `<REPO-PASSWORD-SECRET-NAME>`. The pipeline reads it only when createMissing is on and passes it as `VBA_REPO_PASSWORD`. It is never in the file. If encryption is on and no password is supplied, the repository is not created. Repositories encrypted with a Key Vault key aren't supported by this script.
- **Re-adding a repository whose folder already holds backups:** turn on **importExistingBackups** (`-ImportIfFolderHasBackup`) to import them. If it's off, the appliance may refuse because the folder isn't empty.
- **Waiting:** creation runs in the background. The script waits up to 10 minutes (`-CreateWaitSeconds`) for the repository to appear and reach `Ready`, and fails if it doesn't.
- **New ID:** a created repository gets a new ID. The drift check will report the difference from the file's old `id`. Update the `id` line in the file (the run prints the new ID) and commit it.

Always run a dry run first. It prints the storage location, tier, encryption and import choices it would use, and sends nothing.

### Veeam Data Cloud Vault repositories

For a file with `"repositoryType": "VeeamVault"` the script:

1. Checks the appliance is **registered** with Veeam Data Cloud Vault (`GET /veeamVaults/registration`). Registration is a one-time interactive step in the portal; the script never does it. If it isn't registered, the run stops with a clear message.
2. Finds the vault in `GET /veeamVaults`, by `veeamVaultId` in the file or, failing that, by storage account and container name. It stops if the vault isn't found or is **read-only**.
3. **Imports** the vault with `POST /veeamVaults/importAccount`. This writes to the appliance's configuration database, so it is skipped in a dry run. The response gives the account ID, storage account ID and container name.
4. Adds the repository with `POST /repositories` using those values, the folder from your file, and `enableEncryption: true`. Vault repositories must be encrypted, so the password (`<REPO-PASSWORD-SECRET-NAME>` in Key Vault) is always needed.

The file needs `azureStorageFolder.name` (the folder to create in the vault). The baseline records `veeamVaultId` and the folder for existing Vault repositories.

Not confirmed: the response body of the import call is taken from the reference's example, and the import may answer `202` (accepted); the script repeats the call up to six times, 10 seconds apart, until the storage account details come back. The create call may then reject something, and its error names the field.

## Files

```
scripts/Invoke-VbaRepositories.ps1        the apply script
scripts/VbaRepoCommon.ps1                 shared helpers (one function added: Get-RepoDrift)
azure-pipelines/apply-repositories.yml    manual pipeline, approval-gated, dry run on by default
```

## Create the pipeline

1. Commit the files above to `main`, and edit the `variables:` block in `apply-repositories.yml` to match your other pipelines. Use the same `environmentName` so the same approvers apply.
2. **Pipelines > New pipeline > Existing Azure Pipelines YAML file**, path `/azure-pipelines/apply-repositories.yml`, name it `vba-repository-apply`.
3. On the first run, select **Permit** for the service connection and the environment.

## Use it safely

1. Run the drift check and read what differs.
2. Run `vba-repository-apply` with **Dry run on** (the default). Approve it. The log shows, per repository, a table of **DISCOVERED**, **DESIRED** and **REMEDIATED** values. Nothing is changed.
3. Run it again with **Dry run off**. Approve it.
4. For each change the script reads the repository back from the appliance (up to 60 seconds) and then shows `CHANGED` or `NOT CHANGED`. The run goes red if anything didn't take effect.
5. Run the drift check again. It should be green.

Start with a test repository, and change one setting at a time (for example the description) for the first real run.

## Things that are not confirmed

- **Request body.** The script reads the repository's current values, overlays the desired ones and sends `name`, `description`, `concurrencyLimit` and `storageConsumptionLimit`. If the appliance returns a 400, the message names the field to adjust.
- **Switching a limit off** is sent as `storageConsumptionLimit = null`. If the appliance doesn't accept that, the read-back shows `NOT CHANGED`.
- **Units.** The appliance reports the limit in MB even when the portal shows TB. The file holds the MB value and unit the API returns, and that's what is sent back.
- **Repository changes can be slow.** The script waits up to 60 seconds for the read-back, which you can change with `-WaitSeconds`.

## Limits

- The repo is the source of truth. A reviewed pull request is what protects against an unwanted change in a file. Protect `main` with required reviewers.
- There is no state file for repositories. They're matched by ID if the file has one, otherwise by name.
- The approval comes from the environment, not the YAML. Keep the environment's approvers restricted.
