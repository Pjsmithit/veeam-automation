terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# ---------- Variables (all values are set in the tfvars file) ----------
variable "subscription_id" { type = string }
variable "location" { type = string }

# Resource names
variable "resource_group_name" { type = string }
variable "vnet_name" { type = string }
variable "subnet_name" { type = string }
variable "nsg_name" { type = string }
variable "nsg_rule_name" { type = string }
variable "public_ip_name" { type = string }
variable "nic_name" { type = string }
variable "ip_configuration_name" { type = string }
variable "vm_name" { type = string }
variable "computer_name" { type = string } # Windows hostname, max 15 chars

# Network
variable "vnet_address_space" { type = list(string) }
variable "subnet_address_prefixes" { type = list(string) }
variable "allowed_rdp_cidr" { type = string } # your public IP in CIDR form, e.g. "<YOUR_PUBLIC_IP>/32"

# VM
variable "vm_size" { type = string }
variable "os_disk_size_gb" { type = number }
variable "os_disk_type" { type = string }
variable "admin_username" { type = string }

# Password source: Key Vault or manual (quick testing)
variable "use_key_vault" { type = bool }

variable "admin_password" { # manual mode only; prefer TF_VAR_admin_password
  type      = string
  sensitive = true
  default   = null
}

variable "key_vault_name" { # Key Vault mode only
  type    = string
  default = null
}
variable "key_vault_rg" { # Key Vault mode only
  type    = string
  default = null
}
variable "admin_password_secret_name" { # Key Vault mode only
  type    = string
  default = null
}

# Marketplace image. The PLAN (sku) is what selects the Veeam version, e.g. a
# v12 plan always deploys v12. "latest" only picks the newest build inside that plan.
variable "image_publisher" { type = string }
variable "image_offer" { type = string }
variable "image_plan" { type = string }
variable "image_version" { type = string } # use "latest" unless pinning a build

# ---------- Password ----------
data "azurerm_key_vault" "kv" {
  count               = var.use_key_vault ? 1 : 0
  name                = var.key_vault_name
  resource_group_name = var.key_vault_rg
}

data "azurerm_key_vault_secret" "admin_password" {
  count        = var.use_key_vault ? 1 : 0
  name         = var.admin_password_secret_name
  key_vault_id = data.azurerm_key_vault.kv[0].id
}

locals {
  admin_password = var.use_key_vault ? data.azurerm_key_vault_secret.admin_password[0].value : var.admin_password
}

# ---------- Network ----------
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  address_space       = var.vnet_address_space
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.subnet_address_prefixes
}

resource "azurerm_network_security_group" "nsg" {
  name                = var.nsg_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = var.nsg_rule_name
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.allowed_rdp_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "assoc" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_public_ip" "pip" {
  name                = var.public_ip_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "nic" {
  name                = var.nic_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = var.ip_configuration_name
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

# ---------- Marketplace terms ----------
resource "azurerm_marketplace_agreement" "veeam" {
  publisher = var.image_publisher
  offer     = var.image_offer
  plan      = var.image_plan
}

# ---------- VM ----------
resource "azurerm_windows_virtual_machine" "vbr" {
  name                  = var.vm_name
  computer_name         = var.computer_name
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = local.admin_password
  network_interface_ids = [azurerm_network_interface.nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_plan
    version   = var.image_version
  }

  plan {
    publisher = var.image_publisher
    product   = var.image_offer
    name      = var.image_plan
  }

  depends_on = [azurerm_marketplace_agreement.veeam]
}

# ---------- Outputs ----------
output "public_ip" {
  value = azurerm_public_ip.pip.ip_address
}
