# Deploy Veeam Backup & Replication from the Azure Marketplace with Terraform

This example deploys a Veeam Backup & Replication (VBR) server on a Windows VM in Azure using a Marketplace image.

It creates:

- Resource group, virtual network and subnet
- Network security group allowing RDP (3389) from a single address range you define
- Static public IP and network interface
- Marketplace terms acceptance for the image
- Windows VM from the Veeam Marketplace image

> **Example code, provided as-is.** Review it and harden it (for example, use Azure Bastion or a VPN instead of a public IP) before using it in production.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or later
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), signed in with `az login`
- An Azure subscription where you can create resources and accept Marketplace terms (Owner, or Contributor plus permission to accept terms)
- Optional: an Azure Key Vault holding the VM admin password as a secret

## Files

| File | Purpose |
|---|---|
| `main.tf` | All resources. You should not need to edit it. |
| `keyvault.tfvars.example` | Variables, password read from Key Vault |
| `manual.tfvars.example` | Variables, password supplied through an environment variable |

Every resource name and setting is a variable, so all customization happens in your tfvars file.

## Choose the image version

The Marketplace **plan** (`image_plan`) selects the Veeam version. `image_version = "latest"` only picks the newest build *within* that plan, so a v12 plan always deploys v12. To deploy a newer release, set the plan for that release.

The example tfvars files default to the v13 plan:

```
image_publisher = "veeam"
image_offer     = "veeam-backup-replication"
image_plan      = "veeam-backup-replication-v13"
image_version   = "latest"
```

To use a different release, list what is published:

```
az vm image list --publisher veeam --all -o table
```

Check the terms for the plan you choose:

```
az vm image terms show --publisher veeam --offer veeam-backup-replication --plan <IMAGE_PLAN>
```

Then set `image_plan` in your tfvars file to match. Marketplace listings can change, so confirm the plan is still available before deploying.

## Usage

1. Copy the example that matches your password method and remove `.example`:

   ```
   cp keyvault.tfvars.example keyvault.tfvars
   ```

2. Replace every `<LABEL>` with your own value.

3. Provide the admin password.

   **Key Vault** (`use_key_vault = true`): create the secret first, and make sure the identity running Terraform can read secrets (`Key Vault Secrets User` role, or `Get` in an access policy).

   ```
   az keyvault secret set --vault-name <KEY_VAULT_NAME> --name <KEY_VAULT_SECRET_NAME> --value '<ADMIN_PASSWORD>'
   ```

   **Manual** (`use_key_vault = false`): set the password as an environment variable, not in a file.

   ```
   # PowerShell
   $env:TF_VAR_admin_password = "<ADMIN_PASSWORD>"
   # Bash
   export TF_VAR_admin_password='<ADMIN_PASSWORD>'
   ```

   The password must meet Azure Windows VM complexity requirements.

4. Deploy:

   ```
   terraform init
   terraform plan  -var-file=keyvault.tfvars
   terraform apply -var-file=keyvault.tfvars
   ```

5. Connect with RDP to the `public_ip` output, using `admin_username` and your password.

To remove everything: `terraform destroy -var-file=keyvault.tfvars`.

## Variables

| Variable | Description |
|---|---|
| `subscription_id`, `location` | Target subscription and region |
| `resource_group_name`, `vnet_name`, `subnet_name`, `nsg_name`, `nsg_rule_name`, `public_ip_name`, `nic_name`, `ip_configuration_name`, `vm_name`, `computer_name` | Resource names. `computer_name` is the Windows hostname (max 15 characters). |
| `vnet_address_space`, `subnet_address_prefixes` | Address ranges |
| `allowed_rdp_cidr` | Only source allowed to reach RDP. Use your own IP as `/32`, never `0.0.0.0/0`. |
| `vm_size`, `os_disk_size_gb`, `os_disk_type`, `admin_username` | VM settings. Check Veeam's system requirements when sizing. |
| `image_publisher`, `image_offer`, `image_plan`, `image_version` | Marketplace image (see above) |
| `use_key_vault` | `true` reads the password from Key Vault, `false` uses `TF_VAR_admin_password` |
| `key_vault_name`, `key_vault_rg`, `admin_password_secret_name` | Key Vault mode only |

## Security notes

- **State contains the password.** Terraform writes the admin password, including one read from Key Vault, to the state file in plain text. Use an encrypted remote backend (for example, an Azure Storage account with RBAC and no public access) and restrict who can read it.
- **Never commit** `*.tfvars` or state files.
- **Restrict RDP.** Keep `allowed_rdp_cidr` to your own address, or remove the public IP and NSG rule and use Bastion or a VPN.
- **Marketplace agreement.** If your subscription already accepted the terms for this plan, import the existing agreement first, or apply will fail:

  ```
  terraform import azurerm_marketplace_agreement.veeam /subscriptions/<AZURE_SUBSCRIPTION_ID>/providers/Microsoft.MarketplaceOrdering/agreements/veeam/offers/veeam-backup-replication/plans/veeam-backup-replication-v13
  ```

## Next steps

After deployment, configure VBR (repositories, licensing, backup jobs) following the [Veeam Backup & Replication documentation](https://helpcenter.veeam.com/docs/vbr/userguide/overview.html).
