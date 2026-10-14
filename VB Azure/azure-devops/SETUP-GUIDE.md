# Beginner's guide: automating Veeam Backup for Microsoft Azure policies with Azure DevOps

This guide assumes you have never used Azure DevOps, Key Vault or pipelines before. Follow the parts in order. Each step says what you are doing, why, the exact thing to do, and how to check it worked.

> **Status and honesty note.** The scripts and pipeline files in this folder have not yet been run end to end. Azure and Azure DevOps change their menus now and then, so a button may be named slightly differently from what is written here. If something does not match, the purpose of the step is always stated so you can find the equivalent. Where the guide is unsure, it says so.

---

## Part 0. What you are building

Today you run PowerShell scripts by hand and type a password each time. You are going to move that into Azure DevOps so that it runs by itself, safely.

```
 You edit a policy file in a Git repository
            |
            v
 Azure DevOps pipeline runs (weekly, or when you start it)
            |
   reads the VBA password from  --> Azure Key Vault   (a locked safe for secrets)
   reads/writes state.json      --> Azure Blob Storage (a cloud folder)
            |
            v
 PowerShell scripts call the REST API of your Veeam Backup for Microsoft Azure appliance
```

Two pipelines are provided:

| Pipeline | What it does | Changes the appliance? |
|---|---|---|
| **vba-drift-check** | Runs every Monday. Compares the appliance with your policy files and fails (goes red) if anything differs. | No, read-only |
| **vba-apply** | You start it by hand. Creates missing policies and, if you choose, fixes drift. Needs an approval click first. | Yes, only after approval |

### Words you will meet

| Term | Plain meaning |
|---|---|
| **Policy** | A Veeam Backup for Azure backup policy (what the UI sometimes calls a job). |
| **Desired state** | What you want the policy to look like. It is written in a JSON file in the repo. |
| **Drift** | The live policy no longer matches the desired state, for example someone renamed it in the UI. |
| **Dry run** | A rehearsal. Shows what would change and changes nothing. |
| **Remediate** | Fix drift by pushing the desired state back to the appliance. |
| **State file** (`state.json`) | A small file that remembers which policy file is which live policy (by ID), so renames are detected. |
| **Repository (repo)** | A folder tracked by Git, kept in Azure DevOps. It holds the scripts, the pipeline files and your policy files. |
| **Pipeline** | A set of steps Azure DevOps runs for you on a machine called an agent. |
| **Agent** | The computer that actually runs your pipeline steps. |
| **Key Vault** | Azure's secure store for passwords and keys. |
| **Service connection** | The permission slip that lets a pipeline sign in to your Azure subscription. |
| **Workload identity federation** | A way for the pipeline to sign in to Azure without any stored password. |
| **Environment** | An Azure DevOps object that can force a person to approve before a pipeline runs. |

---

## Part 1. What you need before you start

### Accounts and permissions

1. **An Azure subscription** where you can create resources and assign roles. In practice you need the **Owner** role on the subscription (or on a resource group you will create), because you must grant roles to the pipeline's identity.
2. **An Azure DevOps organization and project.** If you do not have one, Part 3 shows how to create one. To create the service connection you need to be a project administrator, and your Microsoft Entra ID account must be allowed to create app registrations (otherwise ask your Azure administrator to do Part 8 for you).
3. **A Veeam Backup for Microsoft Azure appliance** that you can reach over HTTPS (port 443) at its public IP or name, and an administrator account on it.
4. **The existing lab scripts** (`Invoke-VbaPolicies.ps1`, `Test-VbaPolicyDrift.ps1`, `VbaCommon.ps1`) working against your appliance. Do not start this guide until they work by hand.

### Software on your own PC (Windows)

Open **Windows Terminal** or **PowerShell** and install these three tools. Each command downloads and installs one.

```powershell
winget install --id Microsoft.PowerShell -e        # PowerShell 7 (the scripts need version 7 or later)
winget install --id Microsoft.AzureCLI -e          # Azure CLI ("az" command)
winget install --id Git.Git -e                     # Git
```

Close and reopen the terminal, then **start PowerShell 7** (search the Start menu for "PowerShell 7", the window title says `pwsh`). Check everything:

```powershell
$PSVersionTable.PSVersion     # should show 7.x
az version                    # should print JSON with an azure-cli version
git --version                 # should print a version
```

All commands in this guide are for PowerShell 7 unless stated otherwise. Lines ending in a backtick (`` ` ``) continue on the next line.

---

## Part 2. Fill in this worksheet

Keep a text file open and fill this in as you go. You will need every value later.

| Item | Your value | Where it comes from |
|---|---|---|
| Azure subscription ID | | Part 3, step 3.1 |
| Entra tenant ID | | Part 3, step 3.1 |
| Azure region (for example `westeurope`) | | you choose |
| Resource group name | | you choose |
| Key Vault name (globally unique) | | you choose |
| Storage account name (3 to 24 lowercase letters/numbers, unique) | | you choose |
| Azure DevOps organization / project / repo | | Part 4 |
| VBA appliance address | | your appliance |
| VBA automation user name | | Part 7 |
| Key Vault secret name for the VBA user name | | you choose (Part 7) |
| Key Vault secret name for the VBA password | | you choose (Part 7) |
| Key Vault secret name for the repository encryption password (only if you create encrypted repositories) | | you choose |
| VBA service account ID (`accountId`) | | Part 5 |
| VBA region ID, repository ID | | Part 5 |
| Service connection name | | Part 8 |
| Service principal client ID | | Part 8 |

---

## Part 3. Sign in to Azure and look around

### 3.1 Sign in

```powershell
az login
```

A browser opens; sign in with your Azure account. Then see which subscriptions you have:

```powershell
az account list --output table
```

Pick the one to use and select it (replace the text in angle brackets):

```powershell
az account set --subscription "<subscription name or ID>"
az account show --query "{subscription:id, tenant:tenantId, user:user.name}" --output table
```

Write the `subscription` and `tenant` values in the worksheet.

### 3.2 Register the Azure services you will use

New subscriptions sometimes have these switched off. Registering is harmless if they are already on.

```powershell
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.Storage
```

---

## Part 4. Azure DevOps: project, repository and code

### 4.1 Create or open your organization and project

1. Go to <https://dev.azure.com> and sign in with the same Microsoft account.
2. If you have no organization, follow the prompts to create one.
3. Choose **New project**. Name it, for example, `vba-automation`. Leave visibility **Private**. Select **Create**.

### 4.2 Free pipeline capacity (new organizations only)

New organizations often are not allowed to run pipelines on Microsoft's machines until they request free capacity. If your first run later says *"No hosted parallelism has been purchased or granted"*, request it at <https://aka.ms/azpipelines-parallelism-request> (it can take a couple of working days), or use a self-hosted agent (Part 9, option B), which avoids the wait.

### 4.3 Get the repository URL

1. In your project, open **Repos** in the left menu. A new project already has an empty repo named after the project.
2. Select **Clone** (top right) and copy the HTTPS URL. It looks like `https://dev.azure.com/<org>/<project>/_git/<repo>`.
3. In the same dialog select **Generate Git Credentials** if you are asked for a password later. Git for Windows normally opens a browser to sign in, so you often will not need it.

### 4.4 Put the code in the repo

The pipeline files expect this layout **at the root of the repo**:

```
azure-pipelines/drift-check.yml
azure-pipelines/apply.yml
scripts/VbaCommon.ps1
scripts/Invoke-VbaPolicies.ps1
scripts/Test-VbaPolicyDrift.ps1
policies/tag-gold-vms.json
.gitignore
README.md
SETUP-GUIDE.md
```

That means you copy the **contents** of the `azure-devops` folder (not the folder itself) into the repo.

```powershell
cd C:\Work                                              # any folder you like
git clone https://dev.azure.com/<org>/<project>/_git/<repo> vba-automation
cd vba-automation

# Copy everything from the azure-devops folder into this repo folder.
# Replace the path below with where you saved the azure-devops folder.
Copy-Item -Path "C:\path\to\azure-devops\*" -Destination . -Recurse -Force

git add .
git commit -m "Add VBA policy automation"
git push origin HEAD:main
```

If Git complains about your identity, run these once and repeat the commit:

```powershell
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

**Check:** in Azure DevOps open **Repos > Files**. You should see the folders above. If the branch is called `master` instead of `main`, either rename it in **Repos > Branches** or change `main` in `drift-check.yml` (the `branches:` line) to match.

---

## Part 5. Prepare your policy files

Policy files are the "desired state". One file per policy. The **file name** (without `.json`) is the policy's permanent key, so choose it carefully and do not rename it later.

### 5.1 Find the IDs you need (using the lab scripts on your PC)

On your PC, in the folder with your working lab scripts:

```powershell
.\Invoke-VbaPolicies.ps1 -Appliance <VBA-IP-ADDRESS> -ListIds
```

Enter your VBA admin user when prompted. It prints three lists. Copy these into the worksheet:

- **Service accounts**: use the value in the `accountId` column.
- **Regions**: use the ID of the Azure region your VMs live in.
- **Repositories**: use the ID of the repository the backups should go to.

Your Entra **tenant ID** is the `tenant` value from step 3.1.

### 5.2 Edit the policy file

Open `policies/tag-gold-vms.json` in Notepad or VS Code. This is what each part means:

| Field | What to put | Notes |
|---|---|---|
| `name` | The policy name shown in VBA | Must be unique. |
| `description` | Free text | Optional. |
| `isEnabled` | `true` or `false` | |
| `tenantId` | Your Entra tenant ID | |
| `serviceAccountId` | The `accountId` from 5.1 | |
| `backupType` | `SelectedItems` | Back up only what you pick (tags here). |
| `regions` | One entry per region: `{ "regionId": "<ID>" }` | |
| `selectedItems.tags` | One entry per tag: `{ "name": "Backup", "value": "Gold" }` | VMs carrying that tag are protected. Spelling and capital letters must match Azure exactly. |
| `snapshotSettings` | Snapshot options | Leave as the example unless you know you need to change it. |
| `retrySettings.retryCount` | How many times to retry | |
| `dailySchedule` | When to run and how long to keep | `hours` are hours of the day (0 to 23). The repository ID goes in `targetRepositoryId`. |

If the appliance later rejects your schedule with a message about `hours`, create the same schedule once in the VBA portal and compare. The REST API checks rules that the portal hides.

### 5.3 Check the JSON is valid

A missing comma or quote is the most common beginner mistake.

```powershell
Get-Content .\policies\tag-gold-vms.json -Raw | ConvertFrom-Json | Out-Null
```

No output means the file is valid. An error message shows the line to fix.

### 5.4 Rehearse on your PC first

Before involving Azure DevOps, prove the policy file works with the lab scripts:

```powershell
.\Invoke-VbaPolicies.ps1 -Appliance <VBA-IP-ADDRESS> -Remediate -DryRun
```

It should say it would create the policy (or show no drift if it already exists). If this does not work here, the pipeline will not work either.

### 5.5 Commit the change

```powershell
cd C:\Work\vba-automation
git add policies
git commit -m "Set real policy values"
git push origin HEAD:main
```

---

## Part 6. Create the Azure resources

You will create a resource group (a folder for Azure resources), a Key Vault for the VBA password, and a storage account to keep `state.json`.

### 6.1 Set your names once

Edit the values, then paste the block into PowerShell 7. The Key Vault and storage names must be **unique across all of Azure**, so add something of your own (initials plus numbers is fine). Storage names allow only lowercase letters and digits.

```powershell
$loc = "westeurope"                  # your region
$rg  = "<RESOURCE-GROUP-NAME>"
$kv  = "<KEY-VAULT-NAME>"               # 3-24 chars, letters, digits, hyphens
$sa  = "<STORAGE-ACCOUNT-NAME>"                 # 3-24 chars, lowercase letters and digits only
$container = "<STATE-CONTAINER-NAME>"
```

### 6.2 Create the resource group

```powershell
az group create --name $rg --location $loc --output table
```

### 6.3 Create the Key Vault

```powershell
az keyvault create --name $kv --resource-group $rg --location $loc `
  --enable-rbac-authorization true --output table
```

`--enable-rbac-authorization true` means access is controlled by Azure roles, which is what the rest of this guide uses.

### 6.4 Create the storage account and enable versioning

```powershell
az storage account create --name $sa --resource-group $rg --location $loc `
  --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false --min-tls-version TLS1_2 --output table

az storage account blob-service-properties update --account-name $sa --resource-group $rg `
  --enable-versioning true --output table
```

Versioning keeps old copies of `state.json`, so you can roll back if a run ever damages it.

### 6.5 Give yourself access (a step beginners miss)

Even as Owner, you cannot read or write secrets or blobs until you hold a data role. Grant yourself two:

```powershell
$me   = az ad signed-in-user show --query id -o tsv
$kvId = az keyvault show --name $kv --query id -o tsv
$saId = az storage account show --name $sa --resource-group $rg --query id -o tsv

az role assignment create --assignee-object-id $me --assignee-principal-type User `
  --role "Key Vault Secrets Officer" --scope $kvId --output none
az role assignment create --assignee-object-id $me --assignee-principal-type User `
  --role "Storage Blob Data Contributor" --scope $saId --output none
```

Wait about two minutes for the roles to take effect.

### 6.6 Create the container for the state file

```powershell
az storage container create --account-name $sa --name $container --auth-mode login --output table
```

**Check:** the output shows `Created True`. If it says you are not authorized, wait a couple more minutes and try again.

---

## Part 7. Create the VBA automation user and store its credentials

### 7.1 Create a dedicated user on the appliance

Do not reuse your personal admin account. In the VBA web portal, create a user used only by automation (for example `<VBA-USERNAME>`) with the **least role that can manage backup policies**, a long random password, and **no MFA** (the scripts sign in with a username and password only). If the portal lets you limit where the user can sign in from, allow only the agent's IP address. The exact menus depend on your VBA version, so use the Veeam Backup for Microsoft Azure user guide section on users and roles.

**Check it works** with your lab scripts, signing in as this new user:

```powershell
.\Invoke-VbaPolicies.ps1 -Appliance <VBA-IP-ADDRESS> -ListIds
```

If you get an authorization error, the role is too small; if you get 401, the password or MFA is wrong.

### 7.2 Put the credentials in Key Vault

Run these in PowerShell 7 (the variables from 6.1 must still be set). The password is typed hidden, so it does not appear on screen or in your command history.

```powershell
az keyvault secret set --vault-name $kv --name <USERNAME-SECRET-NAME> --value "<VBA-USERNAME>" --output none

$p     = Read-Host -AsSecureString "VBA automation password"
$plain = [System.Net.NetworkCredential]::new("", $p).Password
az keyvault secret set --vault-name $kv --name <PASSWORD-SECRET-NAME> --value $plain --output none
Remove-Variable plain, p
```

You choose the secret names, but they must match the values you set for `keyVaultUsernameSecretName` and `keyVaultPasswordSecretName` in the pipeline files (Part 11).

**Check:**

```powershell
az keyvault secret list --vault-name $kv --query "[].name" -o tsv
```

It should list both names. (Do not print the values.)

---

## Part 8. Let the pipeline sign in to Azure (service connection)

### 8.1 Create the service connection

1. In Azure DevOps open your project, then **Project settings** (bottom left) > **Service connections**.
2. Select **Create service connection** (or **New service connection**) > **Azure Resource Manager** > **Next**.
3. Choose **Workload identity federation (automatic)** (or "App registration (automatic)" with the federation option) > **Next**.
4. Scope level: **Subscription**. Pick your subscription and the resource group `<RESOURCE-GROUP-NAME>`.
5. Service connection name: `<SERVICE-CONNECTION-NAME>`.
6. Leave **Grant access permission to all pipelines** unchecked (you will approve the two pipelines on their first run).
7. Select **Save**.

If it fails with a permission error, your account is not allowed to create app registrations in Entra ID. Ask your Azure administrator to create the connection, or to make you an *Application Developer*.

### 8.2 Find the connection's identity

1. Open the service connection you just made.
2. Select **Manage App registration** (or **Manage service principal**). The Azure portal opens.
3. Copy the **Application (client) ID**. Put it in the worksheet.

### 8.3 Give that identity only two roles

```powershell
$appId = "<application client ID from 8.2>"

az role assignment create --assignee $appId --role "Key Vault Secrets User" --scope $kvId --output none
az role assignment create --assignee $appId --role "Storage Blob Data Contributor" --scope $saId --output none
```

- **Key Vault Secrets User** lets the pipeline read the password.
- **Storage Blob Data Contributor** lets it read and write `state.json`.

If `az` says the principal cannot be found, wait a minute and retry, or use the object ID instead.

**Check:**

```powershell
az role assignment list --assignee $appId --all --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

Both roles should appear.

---

## Part 9. Choose where the pipeline runs

The pipeline runs on an **agent**. Your VBA appliance has a public address, and its firewall must let the agent in.

### Option A. Microsoft-hosted agent (easiest, good for a first test)

Nothing to build. The pipeline files already say `vmImage: ubuntu-latest`. The catch is that the source IP address changes from run to run, so the only way to let it through the appliance firewall is a wide range of addresses, which is weak security. Use this only in a lab, and consider opening the appliance temporarily for the test.

### Option B. Self-hosted agent (recommended for real use)

You run a small Linux machine, with a fixed public IP, that Azure DevOps sends jobs to. The appliance firewall then allows only that one IP.

1. Create a small Ubuntu virtual machine (for example in Azure, 2 vCPU). Give it a **static public IP** and note it. Allow that IP on the appliance firewall for port 443.
2. Sign in to the machine and install PowerShell 7 by following Microsoft's instructions for your Ubuntu version: <https://learn.microsoft.com/powershell/scripting/install/install-ubuntu>.
3. In Azure DevOps: **Project settings > Agent pools > Add pool**. Choose **Self-hosted**, name it `vba-agents`, tick *Grant access permission to all pipelines*, and save.
4. Open the pool, select **New agent**, choose **Linux**, and follow the commands it shows (download, extract, then `./config.sh`, then `sudo ./svc.sh install` and `sudo ./svc.sh start`). When `config.sh` asks for authentication, use a **Personal Access Token** (PAT). Create one under your profile icon > **Personal access tokens** with the scope **Agent Pools (Read & manage)**, and delete it afterwards.
5. In both pipeline files replace

   ```yaml
   pool:
     vmImage: ubuntu-latest
   ```

   with

   ```yaml
   pool:
     name: vba-agents
   ```

**Check:** the agent shows as **Online** in the pool.

---

## Part 10. Create the environment that asks for approval

1. In Azure DevOps open **Pipelines > Environments**.
2. Select **New environment**. Name: `<ENVIRONMENT-NAME>`. Resource: **None**. Select **Create**.
3. Open the environment, select the **⋮** menu > **Approvals and checks** > **+** > **Approvals**.
4. Add yourself (or a team) as approvers. Select **Create**.

Every run of the apply pipeline will now pause until an approver clicks **Approve**.

---

## Part 11. Tell the pipelines about your environment

Every file in `azure-pipelines/` starts with a `variables:` block full of `<PLACEHOLDER>` values. **Replace every placeholder with your own value, in every pipeline file, before you run anything.** For example, in `drift-check.yml` and `apply.yml`:

```yaml
variables:
  azureServiceConnection:     '<SERVICE-CONNECTION-NAME>'   # the service connection from Part 8
  keyVaultName:               '<KEY-VAULT-NAME>'            # your Key Vault name ($kv)
  keyVaultUsernameSecretName: '<USERNAME-SECRET-NAME>'      # name of the Key Vault secret holding the VBA user name
  keyVaultPasswordSecretName: '<PASSWORD-SECRET-NAME>'      # name of the Key Vault secret holding the VBA password
  stateStorageAccount:        '<STORAGE-ACCOUNT-NAME>'      # your storage account name ($sa)
  stateContainer:             '<STATE-CONTAINER-NAME>'      # the container from Part 6.6
  vbaAppliance:               '<VBA-IP-ADDRESS>'            # public IP address or FQDN of the VBA appliance
  environmentName:            '<ENVIRONMENT-NAME>'          # apply pipelines only: the environment from Part 10
```

The other pipelines use a subset of these. `apply-repositories.yml` also has `keyVaultRepoPasswordSecretName`, the secret that holds the repository encryption password (used only when creating encrypted repositories).

Edit in VS Code or directly in **Repos > Files** (select the file, then **Edit**). Commit the change to `main`.

---

## Part 12. Create the two pipelines

Do this twice, once per file.

1. **Pipelines > Pipelines > New pipeline** (or **Create Pipeline**).
2. Where is your code? **Azure Repos Git**. Select your repository.
3. Configure: **Existing Azure Pipelines YAML file**.
4. Branch `main`. Path: `/azure-pipelines/drift-check.yml` (first time) or `/azure-pipelines/apply.yml` (second time). Select **Continue**.
5. Select the arrow next to **Run** and choose **Save** (do not run yet).
6. Rename it: on the pipeline page choose **⋮ > Rename/move**. Use `vba-drift-check` and `vba-apply`.

---

## Part 13. Test it, one step at a time

Do not move on until a step behaves as described.

### Test 1. Can the pipeline reach everything? (drift check)

1. Open **vba-drift-check** and select **Run pipeline > Run**.
2. On the first run a banner says **This pipeline needs permission to access resources**. Select **View > Permit** (for the service connection) and confirm. The run continues.
3. Watch the steps:
   - *Read VBA credentials from Key Vault*: green means Key Vault access works.
   - *Download state.json*: green, and the log says there is no state yet.
   - *Check policies for drift*: signs in and compares.

**Expected result right now:** the policy does not exist yet (you have not applied), so the drift check reports it as `MISSING` and the run is **red**. That is correct. What matters is that it reached the appliance and got that far. If a step failed earlier, use the troubleshooting table in Part 14.

### Test 2. Dry run of the apply pipeline

1. Open **vba-apply**, select **Run pipeline**.
2. Leave the defaults: *Remediate* off, *Dry run* on, *Unmanaged* Ignore. Select **Run**.
3. Permit access again if asked (service connection and environment).
4. The run waits at **Review/Approve**. Open it and select **Approve**.
5. Open the *Apply policies* step log. You should read lines like `DRY RUN - new policy, would create`.

Nothing was created and no `state.json` was uploaded.

### Test 3. Create the policy for real

1. Run **vba-apply** again, this time untick **Dry run** (leave Remediate off). Approve it.
2. The log should say `created  id=...`.
3. In the VBA portal confirm the policy exists with the right schedule and tags.
4. Confirm `state.json` was saved: in the Azure portal open your storage account > **Containers > <STATE-CONTAINER-NAME>**, or run:

   ```powershell
   az storage blob list --account-name $sa --container-name $container --auth-mode login --query "[].name" -o tsv
   ```

### Test 4. A clean drift check

Run **vba-drift-check** again. This time it should finish **green** and the log says the policy `matches desired state`. Open the run's **Artifacts** to find `drift-report`.

### Test 5. Create drift on purpose

1. In the VBA portal, change the policy: rename it, or change the retention.
2. Run **vba-drift-check**. It should go **red**, and the log lists each difference with the desired value in green and the live value in red. A rename shows up as a difference in `name`.

### Test 6. Preview the fix (remediate, dry run)

1. Run **vba-apply** with **Remediate** ticked and **Dry run** ticked. Approve.
2. The log shows a table with three columns: **DISCOVERED (live)**, **DESIRED** and **REMEDIATED**. In a dry run the last column says what it *would* become. Nothing changes.

### Test 7. Fix it for real

1. Run **vba-apply** with **Remediate** ticked and **Dry run** unticked. Approve.
2. The table now shows `<- CHANGED` for each setting that was put right, and a result line says the policy matches the desired state.
3. Check the policy in the portal, then run **vba-drift-check**. It should be green again.

### Test 8. Deleted and unmanaged policies

- **Deleted:** delete the policy in the portal. Run the drift check; it reports `MISSING`. Run **vba-apply** with *Remediate* ticked to recreate it. A run *without* Remediate only reports it.
- **Unmanaged:** create a different policy by hand in the portal. Run **vba-apply** with *Remediate* ticked and Unmanaged = *Ignore*; it lists the extra policy in yellow. Choose Unmanaged = *Adopt* to turn it into a policy file: afterwards open the run's **Artifacts**, download `policies`, check the new file and commit it to the repo. Deleting an unmanaged policy is deliberately not possible from the pipeline.

### Test 9. The schedule

1. Open the **vba-drift-check** pipeline > **⋮ > Scheduled runs**. It should show a Monday 06:00 UTC run.
2. Scheduled runs only start from `main`, so make sure the YAML is on `main`.

---

## Part 14. Troubleshooting

| What you see | Most likely cause and fix |
|---|---|
| *No hosted parallelism has been purchased or granted* | New organization. Request free capacity (Part 4.2) or use a self-hosted agent. |
| Run is stuck at *Waiting for approval* | Open the run and select **Review > Approve** (apply pipeline only). |
| *There was a resource authorization issue* / *needs permission* | On the run page select **View > Permit** for the service connection, environment or pool. |
| Key Vault step: *Forbidden* / *not authorized to perform action* | Missing **Key Vault Secrets User** role for the service principal (Part 8.3), or the role is still propagating (wait 5 minutes), or the vault has a firewall that blocks the agent. |
| Key Vault step: secret not found | The secret names in Key Vault don't match `keyVaultUsernameSecretName` / `keyVaultPasswordSecretName` in the pipeline file (Parts 7.2 and 11). |
| Blob step: `AuthorizationPermissionMismatch` | Missing **Storage Blob Data Contributor** role on the storage account (Part 8.3). |
| Service connection step fails to sign in | The service connection was edited or the app registration deleted. Recreate it (Part 8.1). |
| Timeout or *connection refused* to the appliance | The appliance firewall does not allow the agent's IP, or `vbaAppliance` is wrong, or the appliance is not listening on 443. |
| 401 Unauthorized from the appliance | Wrong password in Key Vault, user disabled, or the user requires MFA. Re-run Part 7. |
| Certificate error | The scripts skip certificate checks by default, which is fine for a self-signed lab certificate. For production install a trusted certificate on the appliance and remove `SkipCertificateCheck` from `scripts/VbaCommon.ps1`. |
| `MISSING` but the policy exists in the portal | `state.json` has an old ID **and** the live name differs from the file. Run apply with Remediate; it re-points state. |
| *Tag(s) not visible to this service account* | The tag name or value is mistyped (it is case sensitive) or the VBA service account cannot see those VMs. The log lists the first tags VBA does see. |
| *400 ... dailySchedule.backupSchedule.hours* | The schedule values are rejected by the API. Build the same schedule in the portal and copy its values. |
| Pipeline says `Invoke-VbaPolicies.ps1` not found | The repo layout is wrong. `scripts/` must be at the root of the repo (Part 4.4). |
| YAML error on `main` branch | Check indentation. YAML needs spaces, never tabs, and `variables:` values must be inside quotes. |

---

## Part 15. Day-to-day use

- **Change a policy.** Edit the JSON file in the repo (best through a pull request), merge to `main`, then run **vba-apply** with Remediate ticked. Always do a dry run first.
- **Add a policy.** Add a new JSON file in `policies/`, merge, run **vba-apply** (Remediate not needed to create a brand-new policy).
- **Read the weekly result.** A red `vba-drift-check` means something differs. Open the run log or the `drift-report` artifact. Set up a notification: in Azure DevOps open your profile icon > **Notifications** or **Project settings > Notifications**, and subscribe to failed builds.
- **Rotate the VBA password.** Change it in the VBA portal, then update the Key Vault secret with the Part 7.2 commands. Nothing in the pipeline changes.
- **If something looks wrong with `state.json`.** Open the storage account > container > `state.json` > **Versions** to restore an earlier version.

---

## Part 16. Security checklist

- The VBA password lives only in Key Vault, never in the repo, a pipeline variable or a chat message.
- The pipeline uses workload identity federation, so there is no Azure password or secret to leak or rotate.
- The service principal has exactly two roles, both scoped to one Key Vault and one storage account.
- Apply needs a human approval. Consider requiring approval from someone other than the person who ran it.
- Deleting policies is not available in the pipeline.
- Prefer a self-hosted agent with a fixed IP and allow only that IP through the appliance firewall.
- Turn on Key Vault **soft delete and purge protection** (soft delete is on by default; purge protection is optional):

  ```powershell
  az keyvault update --name $kv --resource-group $rg --enable-purge-protection true
  ```

---

## Part 17. Removing everything (clean-up)

To delete all Azure resources created here:

```powershell
az group delete --name $rg --yes --no-wait
```

This deletes the Key Vault and storage account (and `state.json` with it). Then in Azure DevOps delete the two pipelines, the environment, the service connection and the agent pool. Remove the `<VBA-USERNAME>` user from the VBA appliance.

---

## Appendix A. Quick command reference

```powershell
az login                                              # sign in
az account show                                       # which subscription am I using?
az keyvault secret list --vault-name $kv -o table     # secrets in the vault (names only)
az storage blob list --account-name $sa --container-name $container --auth-mode login -o table
git status                                            # what changed in my repo folder
git add . ; git commit -m "message" ; git push origin HEAD:main
```

## Appendix B. Exit codes (what red or green means)

| Script | Exit code | Meaning |
|---|---|---|
| Drift check | 0 | Everything matches |
| Drift check | 1 | Drift found (or unmanaged policies, because the pipeline passes `-FailOnOrphans`) |
| Drift check | 2 | A managed policy is missing or the check failed |
| Apply | 0 | Finished without problems |
| Apply | 1 | At least one policy failed, is missing and was not remediated, or still differs after remediation |

## Appendix C. What the scripts do and do not do

- They create policies, detect drift, and update drifted policies back to the desired state.
- They match each policy file to the live policy by **ID** (kept in `state.json`), so a rename in the portal is detected and can be fixed.
- They never delete a policy from the pipeline.
- They manage policies only. Repositories and Veeam Data Cloud Vault are not managed by this pipeline yet.
