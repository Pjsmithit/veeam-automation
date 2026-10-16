# Veeam Backup for Microsoft Azure: configuration as code with drift detection (example)

> ## Important: example code only, not supported by Veeam
>
> **Everything in this repository is example code, shared for learning and inspiration only.**
>
> - It is **not an official Veeam product, tool, or reference implementation**.
> - It is **not supported, maintained, reviewed or endorsed by Veeam Software.** Do not open Veeam support cases about it, and do not expect Veeam to fix, update or answer questions about it.
> - It is provided **"as is", with no warranty of any kind**, express or implied. You use it entirely **at your own risk**.
> - It can **create, change and (in some scripts) delete** backup policies and repositories on a backup appliance. A mistake can disrupt your backups or data protection.
> - It was written against the published REST API of Veeam Backup for Microsoft Azure **v8.1** and tested only in a lab. Other versions may behave differently. The API may change without notice and break these scripts.
> - **Always test in a non-production lab first**, review every script before running it, and keep your own backups of your configuration.
>
> "Veeam" and related names are trademarks of Veeam Software. They are used here only to describe what the examples work with, and no affiliation or endorsement is implied. The views and code here are those of the author and do not represent Veeam.

---

## What this is

An example of managing a Veeam Backup for Microsoft Azure (VBA) appliance as code through its REST API:

1. You describe how the appliance **should** look in JSON files kept in Git.
2. Scheduled pipelines **detect drift**: they compare the live appliance with the files and fail (go red) when something differs.
3. Manual, approval-gated pipelines can **apply** the desired state: create what is missing and put drifted settings back.

The examples run as Azure DevOps pipelines, with the appliance credentials held in Azure Key Vault, and can also be run by hand from PowerShell 7.

## What it covers

| Area | Detect drift | Apply or fix |
|---|---|---|
| Backup policies (Azure VM, tag-based) | Yes | Create, update drifted settings, recreate deleted ones, adopt or delete unmanaged ones (local scripts) |
| Users and roles | Yes | **No.** Detection only, by design |
| Backup repositories, including Veeam Data Cloud Vault | Yes | Update editable settings, create missing ones |
| Veeam Data Cloud Vault connection | Check only (registration, vault list) | No |

## How it works, in short

```
Desired state in Git ──► pipeline (weekly or manual) ──► PowerShell script ──► VBA REST API
                              │
                              ├─ credentials from Azure Key Vault
                              └─ state.json in Azure Blob Storage
```

- One JSON file per policy, user or repository. Only the settings you list are compared.
- Policies are matched to the live appliance by ID (kept in a state file), so a rename in the portal is detected rather than looking like a new policy.
- Drift checks never change anything. Applying changes needs explicit switches, defaults to a dry run in the pipelines, and is gated by an approval.
- Each run exits non-zero on a problem, which turns the pipeline step red, and publishes a JSON report.

A full explanation of every file and flow is in [PROJECT-OVERVIEW.md](PROJECT-OVERVIEW.md).

## Repository layout

```
azure-devops/                 the Azure DevOps version (copy its CONTENTS to the root of your own repo)
  azure-pipelines/            drift checks (weekly, read-only) and apply pipelines (manual, approval-gated)
  scripts/                    the PowerShell scripts
  policies/                   example desired policy
  users/                      example desired user (example-user.json)
  SETUP-GUIDE.md              step-by-step setup for beginners
  README.md, USERS-DRIFT.md, REPOSITORIES-DRIFT.md, REPOSITORIES-APPLY.md
lab/                          the earlier local-only versions of the policy scripts
PROJECT-OVERVIEW.md           what every file does and how the process works
```

The `repositories/` folder is not included. You create it for your own appliance with `scripts/Get-VbaRepositoryBaseline.ps1`.

## Before you use it

1. **Read the code.** Understand what each script does before you run it, especially anything that applies changes.
2. **Use a lab.** Do not point it at a production appliance until you have tested it end to end.
3. **Replace every placeholder.** The pipeline files, guides and example files contain `<PLACEHOLDER>` values that you must replace with your own. They are listed in the next section, and the pipelines will not work until they are replaced.
4. **Know that TLS certificate validation is skipped.** `scripts/VbaCommon.ps1` sends every request with `-SkipCertificateCheck` so the examples work with the appliance's default self-signed certificate. That is acceptable in a lab only. For anything else, install a trusted certificate on the appliance and remove `-SkipCertificateCheck` from that file.
5. **Never commit real data.** Do not put credentials, tokens, `state.json`, raw API output or baselines from a real appliance in a public repository. See "Security notes" below.

## Placeholders you must replace

Nothing in this repository contains a real address, account name or secret. Wherever a value is specific to your environment, a placeholder in angle brackets stands in for it.

| Placeholder | What to put there | Where it appears |
|---|---|---|
| `<VBA-IP-ADDRESS>` | Public IP address or FQDN of your Veeam Backup for Microsoft Azure appliance | `vbaAppliance` in every pipeline file, and the examples in the guides and script help |
| `<VBA-USERNAME>` | The appliance account the automation signs in with (use a dedicated account) | Guides, and the example user file `azure-devops/users/example-user.json` |
| `<VBA-PASSWORD>` | The password of that account. It goes only into Key Vault, never into a file | Guides |
| `<USERNAME-SECRET-NAME>` | Name you choose for the Key Vault secret that holds the VBA user name | `keyVaultUsernameSecretName` in every pipeline file |
| `<PASSWORD-SECRET-NAME>` | Name you choose for the Key Vault secret that holds the VBA password | `keyVaultPasswordSecretName` in every pipeline file |
| `<REPO-PASSWORD-SECRET-NAME>` | Name you choose for the Key Vault secret that holds the repository encryption password | `keyVaultRepoPasswordSecretName` in `apply-repositories.yml` |
| `<KEY-VAULT-NAME>` | Name of your Azure Key Vault | `keyVaultName` in every pipeline file |
| `<SERVICE-CONNECTION-NAME>` | Name of your Azure DevOps service connection to Azure | `azureServiceConnection` in every pipeline file |
| `<STORAGE-ACCOUNT-NAME>` | Azure storage account that holds `state.json` | `stateStorageAccount` in `drift-check.yml` and `apply.yml` |
| `<STATE-CONTAINER-NAME>` | Blob container in that storage account | `stateContainer` in `drift-check.yml` and `apply.yml` |
| `<ENVIRONMENT-NAME>` | Azure DevOps environment that has an approval check | `environmentName` in the apply pipelines |
| `<RESOURCE-GROUP-NAME>` | Azure resource group for the Key Vault and storage account | The setup guides |
| `<AZURE-TENANT-ID>`, `<SERVICE-ACCOUNT-UUID>`, `<REGION-ID ...>`, `<REPOSITORY-ID>` | IDs from your own environment (`Invoke-VbaPolicies.ps1 -ListIds` prints them) | `azure-devops/policies/tag-gold-vms.json` |

The five files in `azure-devops/azure-pipelines/` each start with a `variables:` block. Edit the block in **every** pipeline file you use.

## Quick start (local, PowerShell 7)

Requires PowerShell 7 or later and network access to the appliance's HTTPS port. From the `azure-devops` folder:

```powershell
# Find the IDs you need for a policy file (service accounts, regions, repositories)
./scripts/Invoke-VbaPolicies.ps1 -Appliance <VBA-IP-ADDRESS> -ListIds

# Preview what would happen, changing nothing
./scripts/Invoke-VbaPolicies.ps1 -Appliance <VBA-IP-ADDRESS> -DryRun

# Check for drift (read-only)
./scripts/Test-VbaPolicyDrift.ps1 -Appliance <VBA-IP-ADDRESS>
./scripts/Test-VbaUserDrift.ps1 -Appliance <VBA-IP-ADDRESS>

# Collect a baseline of the current repositories, then check them (read-only)
./scripts/Get-VbaRepositoryBaseline.ps1 -Appliance <VBA-IP-ADDRESS>
./scripts/Test-VbaRepositoryDrift.ps1 -Appliance <VBA-IP-ADDRESS>
```

You are prompted for the appliance user name and password. Other scripts and options (remediation, repository apply and create, unmanaged handling) are described in the guides.

## Running it from Azure DevOps

Follow [azure-devops/SETUP-GUIDE.md](azure-devops/SETUP-GUIDE.md). It covers the Azure resources, Key Vault, the service connection, agents, the approval environment, the pipelines and a test sequence. Copy the **contents** of `azure-devops/` to the root of your own Azure DevOps repository, because the pipelines expect `scripts/`, `policies/` and `azure-pipelines/` at the root.

## Security notes

- **Credentials** are read from the `VBA_USERNAME` and `VBA_PASSWORD` environment variables (filled from Key Vault in the pipelines), or prompted for interactively. No secret is stored in this repository.
- **The repository encryption password** is only read from `VBA_REPO_PASSWORD` when creating an encrypted repository, and is never written to a file.
- **TLS:** the scripts skip certificate validation so they work with the appliance's default self-signed certificate. Install a trusted certificate and remove `-SkipCertificateCheck` from `scripts/VbaCommon.ps1` for anything beyond a lab.
- **The repo is the source of truth.** If someone changes both the appliance and the matching file, the check reports OK. Protect your main branch with required reviewers and limit who can edit the desired-state files, the scripts and the pipelines.
- **Use a dedicated appliance account** with the minimum role needed, and restrict where it can sign in from.
- **Do not commit** `state.json`, `repositories-raw.json`, the drift reports, or baselines taken from a real appliance. The included `.gitignore` excludes the generated files.

## Known limitations

- Tested only on Veeam Backup for Microsoft Azure v8.1, in a lab.
- Only tag-based Azure VM policies are modelled. Other policy types are not covered.
- Users are matched by name. Passwords and MFA secrets are not managed.
- Lists are limited to 1,000 items per call. A warning appears if more exist, but additional pages are not followed.
- Not every path has been tested. Notably: creating a repository on customer-owned Azure storage, switching a storage limit off, and re-adding a repository over a folder that already contains backups.
- Request bodies for some update calls were worked out by trial against a lab appliance, because the reference does not document them fully.

## Contributing and questions

This is shared as a starting point, not a supported project. Issues and pull requests may or may not be answered. If you adapt it, you are responsible for testing and maintaining your own version.

## License

Released under the [MIT License](LICENSE). The license covers the code only. It does not grant any rights to Veeam trademarks, and it does not make this a Veeam-supported project. See the notice at the top of this file.
