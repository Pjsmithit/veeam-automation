# VBA Infrastructure-as-Code and Drift Control: Project Overview

Veeam Backup for Microsoft Azure (VBA) managed as code through its REST API, with weekly drift detection and approval-gated remediation, run from Azure DevOps.

This document explains what each file does, how the process works end to end, and what has and hasn't been tested.

---

## 1. What this project does

You describe how your VBA appliance should look in JSON files kept in Git. Pipelines then:

1. **Detect drift** every week: compare the live appliance with the files and go red if anything differs.
2. **Apply and remediate** on demand, behind an approval: create what's missing and put drifted settings back.

Four areas are covered:

| Area | Detect drift | Apply / fix |
|---|---|---|
| Backup policies (Azure VM, tag-based) | Yes | Create, update drifted settings, recreate deleted ones, adopt or delete unmanaged ones (local scripts) |
| Users and roles | Yes | **No, detection only by design** |
| Backup repositories (including Veeam Data Cloud Vault) | Yes | Update editable settings, create missing ones (Azure storage and Vault) |
| Veeam Data Cloud Vault connection | Check only (registration, vault list) | No |

Everything talks to the appliance's REST API (`/api/v8.1/...`) over HTTPS. Credentials come from Azure Key Vault. Nothing is stored in the repo except desired state.

> **Example code only.** These scripts are examples built on the documented REST API. They are not a Veeam product, and they are not supported, maintained or endorsed by Veeam. They are provided as is, with no warranty. Test everything in a non-production lab first. See the main README for the full disclaimer.

---

## 2. Testing status

Tested in a lab against Veeam Backup for Microsoft Azure v8.1, locally and from Azure DevOps:

- Policy create, drift check, remediate with dry run and the discovered / desired / remediated table, missing-policy handling, unmanaged-policy flagging, rename detection by ID, and the pending-change warning.
- Users and roles drift check, including the baseline export.
- Repository baseline collector, repository drift check, and detection of the storage consumption limit on/off and value.
- Repository apply for existing repositories (editable settings).
- The Azure DevOps pipelines: weekly drift checks, approval-gated apply, Key Vault credentials, and the state file in Blob Storage.
- Veeam Data Cloud Vault: registration check, vault list, vault import, and creating a new Vault repository in a new, empty folder with a new encryption password.

Written but **not yet confirmed against a real appliance**:

- Creating a repository on customer-owned Azure storage (the container "system ID" is assumed to be the container name).
- Switching a storage limit **off** through the update call (sent as `null`).
- Re-adding a Vault repository over a folder that already holds backups (`importIfFolderHasBackup`). This needs the original encryption password; a mismatch is rejected with "Invalid password".
- `Test-VbaVaults.ps1` as a standalone check.

---

## 3. How the process works

```
   You (pull request)                        Azure DevOps
   edit JSON files in Git  ───────────────►  repo (main branch, protected)
                                                   │
                         weekly schedule          │       manual run, approval required
                     ┌────────────────────────────┴───────────────┐
                     ▼                                             ▼
          drift-check pipelines (read-only)             apply pipelines (change things)
                     │                                             │
        1. checkout repo                                  1. checkout repo
        2. read VBA user/password  ◄── Azure Key Vault ──►  2. read VBA user/password
        3. download state.json     ◄── Blob Storage ─────►  3. download state.json, upload after
        4. run PowerShell script                          4. run PowerShell script (dry run by default)
                     │                                             │
                     └──────────────► VBA appliance REST API ◄─────┘
                                      (HTTPS 443)
                     │
        5. exit code: 0 green, non-zero red
        6. drift report published as an artifact
```

### Core ideas

- **Desired state files.** One JSON file per policy, user or repository. The file name (without `.json`) is its key.
- **Subset comparison.** Only settings that appear in a file are compared. Leave a setting out and it is ignored. Server-managed fields (status, links, next run) are never compared.
- **Match by ID, fall back to name.** A policy's live ID is remembered in `state.json`, so a rename in the portal is detected and fixed instead of looking like a missing policy plus an unmanaged one. Repositories use an `id` in the file; users are matched by name.
- **State file (`state.json`).** Only policies use it. It records, per policy file, the live ID, a hash of the file when last applied, the apply time, and a snapshot. It is created and updated only by the apply pipeline when not in dry run. It holds no secrets.
- **Detect, then fix.** The drift scripts never change anything. The apply scripts change things only with explicit switches. Dry run is the default in the pipelines.
- **Exit codes drive the pipeline.** Non-zero turns the step red, which is what notifies you. The reports are always published.
- **Approval lives on the Environment**, not in the YAML. The apply pipelines target an Environment (`<ENVIRONMENT-NAME>`) that has an approval check.

### The drift check, step by step

1. The pipeline checks out the repo, reads the VBA credentials from Key Vault, and (for policies) downloads `state.json`.
2. The script loads every desired-state file in its folder and stops if two files share a name.
3. It signs in with `POST /api/oauth2/token` (password grant) and lists the live objects.
4. For each file it finds the live object: by ID from state or file first, then by name. No match means `MISSING`.
5. It flattens both the file and the live object to path/value strings and checks that every setting in the file equals the live value. Each difference becomes a row of Path, Desired, Live.
6. Extra checks per area: policy tags against the policy's selected items; security-relevant settings labelled (`SECURITY` for user role, MFA and type; `PROTECTION` for repository immutability, encryption, tier and type).
7. It notes when a policy file has changed since it was last applied (a pending change, shown as a yellow warning).
8. Live objects with no matching file are reported as **unmanaged**.
9. It prints a colour-coded summary, writes a JSON report, signs out, and exits 0 (clean), 1 (drift or unmanaged) or 2 (missing or failed).

### The apply / remediate flow (policies)

1. Same load and match steps as above.
2. A file with no live policy and no state entry is a **new policy** and is created.
3. A file whose policy is in state but not live is **missing (deleted)**. It's only recreated with `-Remediate`.
4. A policy that exists with drift is only updated with `-Remediate`: `PUT /policies/virtualMachines/{id}`, then it is read back and shown in a **discovered / desired / remediated** table so you can see what actually changed.
5. `-DryRun` shows all of this and changes nothing.
6. `-Unmanaged Adopt` writes a file for a hand-made policy; `-Unmanaged Delete` removes it (typed confirmation or `-Force`). The pipeline offers Adopt only.

### The repository flow

1. **Baseline (run locally once):** `Get-VbaRepositoryBaseline.ps1` reads the live repositories and writes one file each. You review and commit them.
2. **Drift check** compares the files with the live repositories (see above).
3. **Apply (`Invoke-VbaRepositories.ps1`)** can change only name, description, concurrency limit and the storage consumption limit on existing repositories. Anything else that differs is reported in red as "not fixable here". With `-CreateMissing` it can also create repositories:
   - **Customer Azure storage:** needs the account and storage IDs in the file; `POST /repositories`.
   - **Veeam Data Cloud Vault:** checks the appliance is registered, finds the vault, calls `POST /veeamVaults/importAccount` (it runs in the background; the script follows `/operations/{id}`), then adds the repository with the returned account, storage account and container, a folder from your file, and encryption always on.
4. Creating over a folder that already has backups needs `-ImportIfFolderHasBackup` **and the original encryption password**.

---

## 4. Repository layout

```
azure-devops/                        <- the repo root when published to Azure DevOps
├─ azure-pipelines/
│   ├─ drift-check.yml               weekly policy drift check
│   ├─ drift-check-users.yml         weekly user and role drift check
│   ├─ drift-check-repositories.yml  weekly repository drift check
│   ├─ apply.yml                     manual, approval-gated policy apply
│   └─ apply-repositories.yml        manual, approval-gated repository apply and create
├─ scripts/
│   ├─ VbaCommon.ps1                 shared helpers (sign-in, lists, compare, display)
│   ├─ VbaRepoCommon.ps1             repository helpers
│   ├─ Invoke-VbaPolicies.ps1        policy apply / remediate
│   ├─ Test-VbaPolicyDrift.ps1       policy drift check
│   ├─ Test-VbaUserDrift.ps1         user and role drift check
│   ├─ Get-VbaRepositoryBaseline.ps1 collect a repository baseline (run locally)
│   ├─ Test-VbaRepositoryDrift.ps1   repository drift check
│   ├─ Invoke-VbaRepositories.ps1    repository apply and create
│   └─ Test-VbaVaults.ps1            Vault registration and vault list check
├─ policies/      *.json             desired policies (one per file)
├─ users/         *.json             desired users and roles
├─ repositories/  *.json             desired repositories (created by the baseline script)
├─ README.md, SETUP-GUIDE.md, USERS-DRIFT.md, REPOSITORIES-DRIFT.md, REPOSITORIES-APPLY.md
└─ .gitignore                        keeps state and reports out of Git

lab/                                  <- the original local versions (see section 6)
```

---

## 5. File by file

### 5.1 Shared libraries (dot-sourced, never run on their own)

**`scripts/VbaCommon.ps1`**: the shared toolbox used by every other script.

| Function | What it does |
|---|---|
| `Get-VbaCredential` | Reads `VBA_USERNAME` / `VBA_PASSWORD` from the environment (set from Key Vault in the pipeline). Falls back to an interactive prompt when run by hand. |
| `Connect-Vba` / `Disconnect-Vba` | Signs in with the password grant at `/api/oauth2/token`, builds the request headers and base URL (with `-SkipCertificateCheck` for the appliance's self-signed certificate), and signs out at the end. |
| `Get-VbaPolicyList` | Lists the VM backup policies. |
| `Get-DesiredPolicies` | Loads every `*.json` in a folder, adds a key (the file name) and a SHA-256 hash, and stops if two files use the same policy name. |
| `Read-VbaState` / `Write-VbaState` | Reads and writes `state.json`. |
| `Get-VbaTags` | Forces an Azure rescan (`GET /cloudInfrastructure/tags?Sync=true`) **once**, then polls without `Sync` until it gets HTTP 200, and caches the tag list. Needed because the appliance caches tags and a policy that selects a new tag fails otherwise. |
| `Get-MissingTags` | Checks that each requested tag exists with the exact name and value. |
| `Get-PolicyDrift` | Compares one policy file with the live policy and its selected items, returning Path / Desired / Live rows. |
| `ConvertTo-DesiredFromLive` | Builds a policy file from a live policy (used by Adopt). |
| `Write-RemediationTable` | Prints the DISCOVERED / DESIRED / REMEDIATED table with colours. |
| `Write-DriftTable` | Prints the simple Path / Desired / Live table (desired green, live red). |
| `ConvertTo-FlatMap` | Flattens nested objects and arrays into `path.to[0].value = "text"` pairs; every value becomes a string so numbers, booleans and enums compare consistently. This is the engine of the subset comparison. |

**`scripts/VbaRepoCommon.ps1`**: repository helpers.

| Function | What it does |
|---|---|
| `Get-VbaRepositories` | Lists repositories (`GET /repositories?Limit=1000`) and warns if the appliance reports more than it returned. |
| `Add-RepoDerived` | Adds `storageConsumptionLimitEnabled`. The API reports the limit as a value, so an "off" limit left nothing to compare, and turning one on went unnoticed. This computed flag fixes that. |
| `Get-RepoDrift` | Compares a repository file with a live repository. |
| `ConvertTo-RepoBaseline` | Turns a live repository into a clean desired-state file: keeps stable settings (id, name, type, status, tier, immutability, encryption, concurrency, limit, storage account and container/folder, account IDs, Vault ID) and drops links, hints and ownership details. |

### 5.2 Policy scripts

**`scripts/Test-VbaPolicyDrift.ps1`**: detect-only. Loads policy files and `state.json`, matches by state ID then name, compares settings and tags, notes pending file changes in yellow (and raises an Azure DevOps warning), finds unmanaged policies, writes `drift-report.json`. Exit 0/1/2. Flag `-FailOnOrphans` makes unmanaged policies fail the run.

**`scripts/Invoke-VbaPolicies.ps1`**: apply and remediate.
- `-Remediate`, `-DryRun`, `-Unmanaged Ignore|Adopt|Delete`, `-Force`, `-ListIds`, `-SkipRescan`, `-RescanTimeoutSec`.
- Creates new policies (after verifying the tags exist), recreates deleted ones only with `-Remediate`, rewrites drifted ones with `-Remediate`, reports renames, flags unmanaged policies, and updates `state.json`.
- `-ListIds` prints service accounts (`accountId`), regions and repositories so you can fill in the files.

### 5.3 Users and roles

**`scripts/Test-VbaUserDrift.ps1`**: detection only (makes only `GET /users` plus sign-in and sign-out).
- Compares `users/*.json` with the live users by name.
- Labels role, MFA and type differences **SECURITY** and raises them as pipeline errors.
- Reports missing users, unmanaged users (fails the run with `-FailOnUnmanaged`), and a **rename hint** when one user is missing and one unmanaged user has the same role.
- `-ExportTo ./users` writes a baseline of current users (local files only, never overwrites).

### 5.4 Repositories

**`scripts/Get-VbaRepositoryBaseline.ps1`**: run **locally**. Reads the live repositories, prints a review table, saves the full raw API output to `repositories-raw.json` (reference only, git-ignored) and writes one desired-state file per repository. Never overwrites unless `-Force`.

**`scripts/Test-VbaRepositoryDrift.ps1`**: detection only. Matches by `id`, then name. Labels immutability, encryption, tier and type differences **PROTECTION**. Reports a changed `id` (repository removed and re-added), missing and unmanaged repositories, rename hints, and a note when a repository reports another owner.

**`scripts/Invoke-VbaRepositories.ps1`**: apply.
- Updates only editable settings: name, description, concurrency limit and the storage consumption limit (on/off, value, unit). Reads the repository, overlays the desired values, sends them with `PUT /repositories/{id}`, then re-reads for up to 60 seconds and shows what changed.
- Sends `enableEncryption` unchanged, because the update validates the whole repository and a missing value defaults to false, which Vault rejects.
- Never deletes. Reports differences it can't fix as "not fixable here".
- `-CreateMissing`: creates repositories on customer Azure storage or Veeam Data Cloud Vault (flow in section 3). `-ImportIfFolderHasBackup`, `-CreateWaitSeconds`, `-DryRun`.

**`scripts/Test-VbaVaults.ps1`**: read-only check of the Vault connection: registered or not, which vaults are connected, whether each is read-only, and whether each has a repository. Not wired into a pipeline yet.

### 5.5 Pipelines (`azure-pipelines/`)

All use `ubuntu-latest` (change to a self-hosted pool for a fixed IP), read secrets with the `AzureKeyVault@2` task using an Azure service connection (workload identity federation), and run the script with `pwsh`. Edit the `variables:` block at the top of each file.

| File | Trigger | Changes the appliance? | Notes |
|---|---|---|---|
| `drift-check.yml` | Mondays 06:00 UTC | No | Downloads `state.json`; fails on drift; publishes `drift-report`. |
| `drift-check-users.yml` | Mondays 06:30 UTC | No | Publishes `user-drift-report`. |
| `drift-check-repositories.yml` | Mondays 07:00 UTC | No | Publishes `repository-drift-report`. Staggered because the free tier runs one job at a time. |
| `apply.yml` | Manual | Yes, after approval | Parameters: remediate, dry run (default on), unmanaged (Ignore or Adopt). Uploads `state.json` only when not a dry run. Publishes adopted policy files as an artifact. |
| `apply-repositories.yml` | Manual | Yes, after approval | Parameters: dry run (default on), createMissing, importExistingBackups. Reads `<REPO-PASSWORD-SECRET-NAME>` only when createMissing is on. |

### 5.6 Data and support files

| File / folder | Purpose |
|---|---|
| `policies/*.json` | Desired policies. Example shows a tag-based daily policy. |
| `users/*.json` | Desired users, e.g. name, description, role, type, mfaEnabled. |
| `repositories/*.json` | Desired repositories. Create it with the baseline script. |
| `.gitignore` | Keeps `state.json`, `drift-report.json`, `user-drift-report.json`, `repository-drift-report.json` and `repositories-raw.json` out of Git. |
| `README.md` | Short overview and layout. |
| `SETUP-GUIDE.md` | Full beginner walkthrough: Azure resources, Key Vault, service connection, agents, environment, pipelines, nine tests, troubleshooting. |
| `USERS-DRIFT.md`, `REPOSITORIES-DRIFT.md`, `REPOSITORIES-APPLY.md` | Setup and behaviour for each area. |

---

## 6. `lab/` versus `azure-devops/`

`lab/` holds the original local versions of the policy scripts (`Invoke-VbaPolicies.ps1`, `Test-VbaPolicyDrift.ps1`, `VbaCommon.ps1`, `Test-VbaVaults.ps1`) and the example policy. The `azure-devops` copies differ in three ways: paths use `/` so they run on Linux agents; they read credentials from environment variables; and the drift check there also raises Azure DevOps warnings. The newer repository and user scripts exist only in `azure-devops/` but also run locally with PowerShell 7 (they prompt for credentials).

---

## 7. REST endpoints used (VBA v8.1)

| Purpose | Call |
|---|---|
| Sign in / out | `POST /api/oauth2/token` (password grant), `POST /api/oauth2/logout` |
| Policies | `GET`/`POST /policies/virtualMachines`, `GET`/`PUT /policies/virtualMachines/{id}`, `GET .../{id}/selectedItems` |
| Azure tags and rescan | `GET /cloudInfrastructure/tags?Sync=true` (202 while scanning, then 200) |
| IDs for the files | `GET /accounts/azure/service`, `GET /cloudInfrastructure/regions`, `GET /repositories` |
| Users | `GET /users` |
| Repositories | `GET /repositories`, `GET`/`PUT /repositories/{id}`, `POST /repositories` |
| Veeam Data Cloud Vault | `GET /veeamVaults/registration`, `GET /veeamVaults`, `POST /veeamVaults/importAccount` |
| Background operations | `GET /operations/{operationId}` |

---

## 8. Security design (and why)

- **Credentials only in Key Vault.** The pipeline signs in to Azure with workload identity federation, so there is no stored Azure secret either. The identity has two roles only: Key Vault Secrets User and Storage Blob Data Contributor.
- **Detection and fixing are separate pipelines.** Drift checks can't change anything; apply needs an approval.
- **Users are detection only.** Changing roles by automation is high risk, so the pipelines only report.
- **No delete in the pipelines.** Policy delete exists only in the local script behind a typed confirmation. Repositories are never deleted.
- **Repository password handling.** The encryption password is read from Key Vault only when creating, never from a file, and never returned by the API (so it can't be drift-checked).
- **The repo is the source of truth.** If someone edits both the appliance and the file, the check reports OK. Protect `main` with required reviewers, restrict who can edit `policies/`, `users/`, `repositories/`, `scripts/` and `azure-pipelines/`, and limit who can administer the Environment.
- **State file.** A pending-change warning shows when a policy file changed without an approved apply. The suggestion not yet built: make that warning fail the run, and refresh the stored hash when apply finds no drift.
- **Network.** The appliance has a public IP. Use a self-hosted agent with a fixed IP and allow only it, and replace the certificate bypass with a trusted certificate.
- **Log masking.** Azure DevOps masks any text matching a secret, so the VBA user name shows as `***` in logs wherever it appears. Keep the user name as a normal variable instead of a secret if that makes logs hard to read.

---

## 9. Lessons learned

1. **The API validates whole objects.** Updating a repository without `enableEncryption` is read as `false`, which Vault rejects. Send unchanged settings back.
2. **Optional settings need an "enabled" flag.** If a setting is empty at baseline time, nothing is compared. A computed `...Enabled` value fixes it.
3. **`Sync=true` starts a new scan on every call.** Send it once, then poll without it.
4. **PowerShell splatting:** an array of `'-Name','value'` is positional. Use a hashtable.
5. **Nested arrays.** `Invoke-RestMethod` may return a list inside a list; flatten it before matching.
6. **Match by ID, not name**, or a portal rename looks like one missing and one unmanaged object.
7. **Git credentials on Windows.** Git Credential Manager can fail with personal Microsoft accounts. A PAT sent as an `http.extraheader` (`--config-env`) clones reliably.
8. **Azure DevOps basics that bite beginners:** free hosted parallelism must be requested for new organisations; new pipelines need "Permit" for the service connection and environment; hosted agent IPs change; the approval comes from the Environment.
9. **The portal shows TB, the API reports MB** for storage limits.
10. **Existing encrypted backup folders need the original password** when re-adding a repository.
11. **Reference pages omit things.** Request bodies, async behaviour and field names often had to be discovered by running the call and reading the 400 message.

---

## 10. Known limitations and open questions

- Policy updates assume the PUT body matches the create body (it worked in lab testing).
- Repository updates assume the PUT body contains name, description, concurrency limit, storage limit and `enableEncryption` (it worked in lab testing).
- Switching a storage limit off is untested.
- Re-adding a Vault repository over a folder that already holds backups (`importIfFolderHasBackup`) is untested to completion: it needs the original encryption password.
- For customer-owned storage, the container "system ID" is assumed to be the container name.
- Users are matched by name only; passwords and MFA secrets are not managed.
- Only tag-based selection is modelled for policies. Other selection types, SLA-based policies, SQL, Cosmos DB and file share policies are not covered.
- Only `v8.1` was used. Property names may differ in other versions.
- Paging is warned about but not followed (limit 1000).
- The scripts skip TLS validation for the appliance's certificate; replace this for production.

---

## 11. Possible next steps

1. Test creating a repository on customer-owned storage.
2. Test switching a storage limit off through the update call.
3. Test re-adding a Vault repository over an existing folder (needs the original password).
4. Wire `Test-VbaVaults.ps1` into a weekly pipeline.
5. Make a pending policy-file change fail the drift check instead of only warning, and refresh the stored hash when apply finds no drift.
6. Add notifications (email or Teams) for failed runs.
7. Protect the main branch with branch policies and required reviewers.
8. Use a self-hosted agent with a fixed IP, and a trusted certificate on the appliance.
