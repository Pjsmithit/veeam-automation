# Deploy Veeam Backup for Microsoft Azure with Terraform

> **Disclaimer: sample code only, not supported by Veeam.**
> These scripts are provided as an example. They are **not** an official Veeam product or deliverable
> and are **not supported by Veeam** in any way. They are provided "as is", without warranty of any kind.
> **Use is entirely at your own risk.** Before using them, you should read and **fully understand all of the
> code**, test it in a non-production environment, and make sure it meets your own security, compliance and
> operational requirements. You are responsible for any costs, changes or impact on your Azure environment.

Creates an Ubuntu 22.04 VM and installs the appliance by running the Veeam install script
(via the Azure CustomScript extension), pulling the script and packages from your storage account.

## Prerequisite: upload the Veeam files from your V13 VBR server (manual step)

> **This deployment cannot work without this step.** The install script and the Veeam packages are
> **not** downloaded from the internet. They ship with Veeam Backup & Replication v13 and must be
> copied from the VBR server to an Azure storage account **before** you run Terraform.

### Files to upload

| What | Location on a Windows VBR server |
|---|---|
| Install script (upload **unmodified**) | `C:\Program Files\Veeam\Plugins\Microsoft Azure\Service\Packages\Deployment\Install-Veeam.Azure.Service.sh` |
| Veeam `.deb` packages | `C:\Program Files\Veeam\Plugins\Microsoft Azure\Service\Packages\Deployment\dependencies\` |
| Linux VBR server (Veeam Software Appliance) | _TODO: Linux file locations to be added_ |

From the `dependencies` folder you need the packages that match the entries in `package_blob_names`
(`veeam-sentry-srl`, `veeam-sentry`, `veeam-updater`, `veeamflr-azure`, `veeamazurebackup`).
The folder can contain other files (for example the `.bndl` updater plugin); they are not needed.

### How to upload
1. Create (or pick) a storage account and a blob container.
2. Upload the script and the required `.deb` files **directly into the container root**, with no subfolders.
   Blob names must match `script_blob_name` and `package_blob_names` in `terraform.tfvars` exactly
   (names are case-sensitive and include the version numbers).
3. Example using the Azure CLI from the VBR server (PowerShell):
   ```powershell
   $src = "C:\Program Files\Veeam\Plugins\Microsoft Azure\Service\Packages\Deployment"

   az storage blob upload --account-name <storage-account> --container-name <container> `
     --auth-mode login --file "$src\Install-Veeam.Azure.Service.sh" --name Install-Veeam.Azure.Service.sh

   az storage blob upload-batch --account-name <storage-account> --destination <container> `
     --auth-mode login --source "$src\dependencies" --pattern "*.deb"
   ```
   You need a role that allows blob writes (for example **Storage Blob Data Contributor**).
   You can also upload with Azure Storage Explorer or the portal.
4. Verify:
   ```
   az storage blob list --account-name <storage-account> --container-name <container> --auth-mode login --query "[].name" -o tsv
   ```
   Copy these exact names into `package_blob_names`.

## Other prerequisites
- Terraform 1.5+ and the Azure CLI, signed in with `az login`.
- The storage account and container from the step above must already exist.

## Deploy
1. Confirm the prerequisite upload above is done. Copy `terraform.tfvars.example` to `terraform.tfvars`
   and fill in the **REQUIRED** section.
2. Provide the admin password in **one** of two ways:
   - Prompt (default): Terraform asks for the password when you run `terraform apply`. To avoid the
     prompt, set an environment variable first:
     - PowerShell: `$env:TF_VAR_admin_password = '<password>'`
     - Bash: `export TF_VAR_admin_password='<password>'`
   - Azure Key Vault: copy `keyvault.tfvars.example` to `keyvault.tfvars`, fill it in, and add
     `-var-file=keyvault.tfvars` to the `terraform apply` command below.
3. (Optional) To use an existing VNet/subnet, set `existing_vnet_name`, `existing_vnet_resource_group`
   and `existing_subnet_name` in `terraform.tfvars`. Leave them empty to create a new network.
4. Run:
   ```
   terraform init
   terraform apply                              # password from environment variable
   terraform apply -var-file=keyvault.tfvars    # password from Key Vault
   ```
5. When it finishes, open the `web_ui_url` output and sign in with the admin username and password.

## Notes
- The VM needs outbound internet (online mode). `assign_public_ip = true` provides it.
- Only `allowed_source_cidrs` can reach SSH and HTTPS.
- If the install fails, the error shows the last lines of the script output. Fix the cause, then
  `terraform destroy` and `terraform apply` (or `terraform taint azurerm_virtual_machine_extension.install`).
- The admin password is stored in Terraform state. Use a remote backend with restricted access.
- `veeamazurebackup-updater-plugin_*.bndl` is not installed by the script and is not needed here.
