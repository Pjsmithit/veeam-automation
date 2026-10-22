terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# ---------- Existing storage account ----------

data "azurerm_storage_account" "pkg" {
  name                = var.storage_account_name
  resource_group_name = var.storage_account_resource_group
}

locals {
  blob_base = "${trimsuffix(data.azurerm_storage_account.pkg.primary_blob_endpoint, "/")}/${var.container_name}"

  file_uris = [
    for b in concat([var.script_blob_name], var.package_blob_names) :
    "${local.blob_base}/${b}"
  ]

  use_existing_network = var.existing_vnet_name != ""
  use_key_vault        = var.key_vault_name != ""
}

# ---------- Admin password: from tfvars/env, or from Key Vault ----------

data "azurerm_key_vault" "kv" {
  count               = local.use_key_vault ? 1 : 0
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group
}

data "azurerm_key_vault_secret" "admin_password" {
  count        = local.use_key_vault ? 1 : 0
  name         = var.key_vault_secret_name
  key_vault_id = data.azurerm_key_vault.kv[0].id
}

locals {
  admin_password = local.use_key_vault ? data.azurerm_key_vault_secret.admin_password[0].value : var.admin_password
}

# ---------- Networking: use an existing VNet/subnet, or create one ----------

data "azurerm_virtual_network" "existing" {
  count               = local.use_existing_network ? 1 : 0
  name                = var.existing_vnet_name
  resource_group_name = var.existing_vnet_resource_group
}

data "azurerm_subnet" "existing" {
  count                = local.use_existing_network ? 1 : 0
  name                 = var.existing_subnet_name
  virtual_network_name = var.existing_vnet_name
  resource_group_name  = var.existing_vnet_resource_group
}

locals {
  # An existing VNet dictates the region (NIC and VM must be in the same region as the subnet).
  location  = local.use_existing_network ? data.azurerm_virtual_network.existing[0].location : var.location
  subnet_id = local.use_existing_network ? data.azurerm_subnet.existing[0].id : azurerm_subnet.subnet[0].id
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = local.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "vnet" {
  count               = local.use_existing_network ? 0 : 1
  name                = "${var.vm_name}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "subnet" {
  count                = local.use_existing_network ? 0 : 1
  name                 = "default"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet[0].name
  address_prefixes     = var.subnet_address_prefixes
}

# NSG is attached to the NIC (not the subnet), so an existing subnet's own NSG is left untouched.
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.vm_name}-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags

  security_rule {
    name                       = "allow-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefixes    = var.allowed_source_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-ssh"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.allowed_source_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "pip" {
  count               = var.assign_public_ip ? 1 : 0
  name                = "${var.vm_name}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "nic" {
  name                = "${var.vm_name}-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.assign_public_ip ? azurerm_public_ip.pip[0].id : null
  }

  lifecycle {
    precondition {
      condition     = !local.use_existing_network || (var.existing_subnet_name != "" && var.existing_vnet_resource_group != "")
      error_message = "When existing_vnet_name is set, existing_subnet_name and existing_vnet_resource_group must also be set."
    }
  }
}

resource "azurerm_network_interface_security_group_association" "nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# ---------- VM (username + password) ----------

resource "azurerm_linux_virtual_machine" "vm" {
  name                            = var.vm_name
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = local.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.nic.id]
  tags                            = var.tags

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  # The script hardcodes the Ubuntu 22.04 (jammy) Microsoft repo, so pin this image.
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  lifecycle {
    precondition {
      condition     = local.use_key_vault ? var.admin_password == "" : var.admin_password != ""
      error_message = "Use exactly one password source: either admin_password (prompt / TF_VAR_admin_password), or Key Vault via -var-file=keyvault.tfvars (which sets admin_password to \"\")."
    }
  }
}

# ---------- Let the VM read the blobs via managed identity ----------

resource "azurerm_role_assignment" "blob_reader" {
  scope                = "${data.azurerm_storage_account.pkg.id}/blobServices/default/containers/${var.container_name}"
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_linux_virtual_machine.vm.identity[0].principal_id
}

# RBAC can take a couple of minutes to propagate; without this the download can 403.
resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.blob_reader]
  create_duration = "120s"
}

# ---------- Run the install script ----------

resource "azurerm_virtual_machine_extension" "install" {
  name                 = "install-vbazure"
  virtual_machine_id   = azurerm_linux_virtual_machine.vm.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"
  tags                 = var.tags

  protected_settings = jsonencode({
    fileUris         = local.file_uris
    managedIdentity  = {}
    commandToExecute = "${var.pre_install_command}bash ./${var.script_blob_name} ${var.script_args}${var.post_install_command}"
  })

  timeouts {
    create = "60m"
  }

  depends_on = [time_sleep.rbac_propagation]
}
