# VBA policy automation for Azure DevOps

> New to Azure DevOps? Follow **[SETUP-GUIDE.md](SETUP-GUIDE.md)**, a complete beginner-level walkthrough. This README is the short version.

Runs the Veeam Backup for Microsoft Azure policy scripts from Azure DevOps pipelines. Credentials come from Azure Key Vault, state lives in Azure Blob Storage, and a weekly pipeline checks for drift.

This folder is separate from the lab scripts. The only differences from the lab versions:

- Default paths use `/` so they work on Linux agents.
- With no `-Credential`, the scripts read `VBA_USERNAME` / `VBA_PASSWORD` from the environment (and still prompt if those are not set).

> Status: written but not yet run. Azure DevOps portal labels change from time to time, so treat menu names as a guide.

## What's in here

```
scripts/                 VbaCommon.ps1, Invoke-VbaPolicies.ps1, Test-VbaPolicyDrift.ps1
policies/                one JSON file per policy (desired state)
azure-pipelines/
  drift-check.yml        weekly, read-only, fails on drift
  apply.yml              manual, approval-gated apply / remediate
```

## How it fits together

```
Azure DevOps pipeline --(OIDC, no stored secret)--> Azure
   |-- Key Vault:      <USERNAME-SECRET-NAME>, <PASSWORD-SECRET-NAME>  --> env vars for the scripts
   |-- Blob Storage:   state.json (download before, upload after)
   `-- pwsh scripts -----------------------------> VBA appliance REST API (HTTPS 443)
```

## Setup

### 1. Put the code in a repo

Create a repo (Azure Repos or GitHub) and commit this folder's contents to `main`. `state.json` and `drift-report.json` are git-ignored on purpose.

Before the first run, edit `policies/*.json` with your real tenant ID, service account ID, region, repository ID and tags.

### 2. Create the Azure resources

```bash
az group create -n <RESOURCE-GROUP-NAME> -l westeurope

# Key Vault (RBAC mode)
az keyvault create -n <KEY-VAULT-NAME> -g <RESOURCE-GROUP-NAME> --enable-rbac-authorization true

# Storage for state.json, with versioning so you can roll back
az storage account create -n <STORAGE-ACCOUNT-NAME> -g <RESOURCE-GROUP-NAME> --sku Standard_LRS \
  --allow-blob-public-access false --min-tls-version TLS1_2
az storage account blob-service-properties update --account-name <STORAGE-ACCOUNT-NAME> -g <RESOURCE-GROUP-NAME> \
  --enable-versioning true
az storage container create --account-name <STORAGE-ACCOUNT-NAME> -n <STATE-CONTAINER-NAME> --auth-mode login
```

Use globally unique names for the vault and storage account. **Every file in `azure-pipelines/` has a `variables:` block full of `<PLACEHOLDER>` values. Replace every placeholder with your own values in every pipeline file before running anything.**

### 3. Create a dedicated VBA service user

In the VBA appliance, create a user just for automation with the minimum role that can manage backup policies. Use a long random password, no MFA (the scripts use the password grant), and restrict where it can sign in from if you can.

### 4. Store the credentials in Key Vault

```bash
az keyvault secret set --vault-name <KEY-VAULT-NAME> -n <USERNAME-SECRET-NAME> --value '<VBA-USERNAME>'
az keyvault secret set --vault-name <KEY-VAULT-NAME> -n <PASSWORD-SECRET-NAME> --value '<VBA-PASSWORD>'
```

Don't paste these into pipeline variables or the repo.

### 5. Create the Azure service connection (no secret)

In Azure DevOps: **Project settings > Service connections > New > Azure Resource Manager > Workload identity federation (automatic)**. Scope it to `<RESOURCE-GROUP-NAME>` and name it `<SERVICE-CONNECTION-NAME>`.

Then give its identity just two roles. Open **Manage service principal** on the connection to find its application (client) ID:

```bash
APP_ID=<application-id>
az role assignment create --assignee $APP_ID --role "Key Vault Secrets User" \
  --scope $(az keyvault show -n <KEY-VAULT-NAME> --query id -o tsv)
az role assignment create --assignee $APP_ID --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -n <STORAGE-ACCOUNT-NAME> --query id -o tsv)
```

Role assignments can take a few minutes to take effect.

### 6. Decide where the agent runs

The appliance has a public IP, so its firewall must allow the agent.

- **Microsoft-hosted (`ubuntu-latest`)**: simplest, but the source IPs vary. You would have to allow broad ranges, which weakens the firewall. Fine for a lab.
- **Self-hosted agent**: a small VM with a fixed public IP (or in a network with a NAT gateway). Allow only that IP to reach the appliance on 443. Recommended for production. Set `pool: name: <your pool>` in both YAMLs.

The agent needs PowerShell 7 (`pwsh`). Hosted Ubuntu agents already have it.

### 7. Create the environment with an approval

**Pipelines > Environments > New > `<ENVIRONMENT-NAME>` > Approvals and checks > Approvals**. Add yourself or your team. This pauses the apply pipeline until someone approves.

### 8. Create the two pipelines

**Pipelines > New pipeline > (your repo) > Existing Azure Pipelines YAML file**, once for each file:

| Pipeline name | YAML file |
|---|---|
| `vba-drift-check` | `azure-pipelines/drift-check.yml` |
| `vba-apply` | `azure-pipelines/apply.yml` |

The first time each runs, Azure DevOps asks you to permit access to the service connection and environment. Approve it.

## Test, in this order

Do the checks one at a time and don't move on until each behaves as described.

1. **Connectivity and credentials.** Run `vba-drift-check` manually. Pass means the agent reached the appliance, Key Vault worked and the sign-in succeeded. A policy that doesn't exist yet shows as `MISSING` and the run fails; that's expected if you haven't applied yet.
2. **Dry run.** Run `vba-apply` with the defaults (Remediate off, Dry run on). Approve it. It should print what it *would* do and change nothing. No `state.json` is uploaded.
3. **Create.** Run `vba-apply` with Dry run **off** and Remediate **off**. New policies are created and `state.json` appears in the blob container. Check the policy in the VBA portal.
4. **Clean drift check.** Run `vba-drift-check` again. It should pass.
5. **Cause drift.** In the VBA portal, change something on the policy (rename it, change retention, disable it). Run `vba-drift-check`. It should fail and show the differences in the log and in the `drift-report` artifact.
6. **Preview the fix.** Run `vba-apply` with Remediate on and Dry run on. The table shows discovered, desired and remediated values, with nothing changed.
7. **Fix it.** Run `vba-apply` with Remediate on and Dry run off. Then run the drift check again; it should pass.
8. **Missing and unmanaged.** Delete a policy in the portal and confirm the drift check reports it missing and only a remediate run recreates it. Create a policy by hand and confirm it shows as unmanaged.
9. **Schedule.** The weekly schedule in `drift-check.yml` only runs from the `main` branch. Confirm the next scheduled run appears under the pipeline's **Scheduled runs**.

## Everyday use

- **Change a policy**: edit the JSON in a pull request, merge, then run `vba-apply` with Remediate on.
- **Adopt a hand-made policy**: run `vba-apply` with Remediate on and Unmanaged = Adopt. Download the `policies` artifact, review the generated file, commit it.
- **Delete an unmanaged policy**: do it by hand in the portal or from the lab scripts. The pipeline intentionally can't delete.
- **Rotate the VBA password**: change it in VBA and then in Key Vault (`az keyvault secret set`). No pipeline changes needed.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Key Vault step: access denied / forbidden | Missing `Key Vault Secrets User` role, role not propagated yet, or the vault's firewall blocks the agent |
| Blob step: `AuthorizationPermissionMismatch` | Missing `Storage Blob Data Contributor` role on the storage account |
| Timeout or connection refused to the appliance | Appliance firewall doesn't allow the agent's IP, or the wrong address in `vbaAppliance` |
| 401 from the appliance | Wrong or expired VBA password in Key Vault, or the user needs MFA |
| Certificate error | The scripts skip certificate validation by default. Install a trusted certificate on the appliance and remove `SkipCertificateCheck` in `VbaCommon.ps1` |
| `MISSING` for a policy that exists | `state.json` holds an old ID and the policy name differs. Run apply with Remediate to re-point it |
| Two runs at once overwrite `state.json` | Blob versioning lets you roll back. Avoid running apply and drift at the same time |

## Hardening ideas

- Move the VBA appliance behind a private network and use a self-hosted agent in that network.
- Turn on Key Vault soft delete and purge protection, and enable alerts on secret reads.
- Make `vba-apply` need approval from a different person than the one who triggered it.
- Send a notification (email, Teams) when `vba-drift-check` fails.
