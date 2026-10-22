# Variable declarations only. You should not need to edit this file.
# Set values in terraform.tfvars (copy terraform.tfvars.example).
# Variables WITHOUT a default are required.

# =====================================================================
# REQUIRED
# =====================================================================

variable "subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
}

variable "admin_password" {
  description = "Password for the VM admin user (also the appliance sign-in). Terraform prompts for it if not set (or set TF_VAR_admin_password). When using Key Vault (keyvault.tfvars) this is set to \"\" and ignored."
  type        = string
  sensitive   = true

  validation {
    condition     = var.admin_password == "" || (length(var.admin_password) >= 12 && length(var.admin_password) <= 72)
    error_message = "Azure requires a password of 12 to 72 characters (with 3 of: lower, upper, digit, symbol)."
  }
}

variable "allowed_source_cidrs" {
  description = "CIDRs allowed to reach SSH (22) and HTTPS (443), e.g. [\"203.0.113.0/24\"]."
  type        = list(string)

  validation {
    condition     = length(var.allowed_source_cidrs) > 0
    error_message = "Provide at least one CIDR. Terraform will not open the VM to the whole internet by default."
  }
}

variable "storage_account_name" {
  description = "Existing storage account holding the install script and Veeam packages."
  type        = string
}

variable "storage_account_resource_group" {
  description = "Resource group of that storage account."
  type        = string
}

variable "container_name" {
  description = "Container in that storage account holding the files."
  type        = string
}

variable "package_blob_names" {
  description = "Blob names of the Veeam .deb files to download alongside the script (sentry-srl, sentry, updater, FLR, product)."
  type        = list(string)
}

# =====================================================================
# OPTIONAL (defaults are fine for a standard deployment)
# =====================================================================

# ---- Network: leave existing_vnet_name empty to create a new VNet/subnet ----

variable "existing_vnet_name" {
  description = "Name of an existing VNet to deploy into. Empty = create a new VNet and subnet."
  type        = string
  default     = ""
}

variable "existing_vnet_resource_group" {
  description = "Resource group of the existing VNet (required if existing_vnet_name is set)."
  type        = string
  default     = ""
}

variable "existing_subnet_name" {
  description = "Name of the existing subnet (required if existing_vnet_name is set)."
  type        = string
  default     = ""
}

variable "vnet_address_space" {
  description = "Address space for the NEW VNet (ignored when using an existing VNet)."
  type        = list(string)
  default     = ["10.60.0.0/24"]
}

variable "subnet_address_prefixes" {
  description = "Prefixes for the NEW subnet (ignored when using an existing VNet)."
  type        = list(string)
  default     = ["10.60.0.0/26"]
}

# ---- Password from Azure Key Vault (alternative to admin_password) ----

variable "key_vault_name" {
  description = "Key Vault holding the admin password secret. Empty = use admin_password instead."
  type        = string
  default     = ""
}

variable "key_vault_resource_group" {
  description = "Resource group of that Key Vault (required if key_vault_name is set)."
  type        = string
  default     = ""
}

variable "key_vault_secret_name" {
  description = "Name of the secret containing the admin password."
  type        = string
  default     = "vbazure-admin-password"
}

variable "location" {
  description = "Azure region. Ignored when using an existing VNet (the VNet's region is used)."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group to create for the VM and networking."
  type        = string
  default     = "rg-vbazure"
}

variable "vm_name" {
  type    = string
  default = "vbazure01"
}

variable "vm_size" {
  description = "Check Veeam sizing guidance for your environment."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "os_disk_size_gb" {
  type    = number
  default = 128
}

variable "admin_username" {
  description = "First user created on the VM (UID 1000). The install script adds it to the Veeam admin groups."
  type        = string
  default     = "veeamadmin"
}

variable "assign_public_ip" {
  description = "Online mode needs outbound internet. A public IP provides it; set false if you have NAT Gateway/firewall egress."
  type        = bool
  default     = true
}

variable "script_blob_name" {
  description = "Blob name of the (unmodified) Veeam install script."
  type        = string
  default     = "Install-Veeam.Azure.Service.sh"
}

variable "script_args" {
  description = "Arguments for the install script: \"\" (online), \"-o\" (offline), \"-o -u\" (offline update)."
  type        = string
  default     = ""
}

variable "pre_install_command" {
  description = <<-EOT
    Shell snippet run BEFORE the install script so its dependencies exist.
    veeam-updater depends on veeam-sentry (and veeam-sentry-srl), which the script never installs
    and which are not in any configured apt source. All matching .debs are installed in one apt
    call so apt can resolve them against each other. Must end with "&& " (or be empty).
  EOT
  type        = string
  default     = "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold ./veeam-sentry*.deb && "
}

variable "post_install_command" {
  description = <<-EOT
    Shell snippet run AFTER the install script. The extension runs as root; root-owned files under
    /home/veeamazure make Veeam.Azure.Service crash at startup (.NET cannot create its named-mutex
    directory). This restores ownership, restarts the service, and fails the extension if the
    service is not active. Must start with ";" (or be empty to disable).
  EOT
  type        = string
  default     = "; rc=$?; id veeamazure >/dev/null 2>&1 && chown -R veeamazure: /home/veeamazure; systemctl reset-failed veeamazurebackup; systemctl restart veeamazurebackup; sleep 15; systemctl is-active --quiet veeamazurebackup && exit $rc"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
