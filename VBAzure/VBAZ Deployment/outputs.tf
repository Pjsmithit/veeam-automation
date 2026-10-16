output "vm_private_ip" {
  value = azurerm_network_interface.nic.private_ip_address
}

output "vm_public_ip" {
  value = var.assign_public_ip ? azurerm_public_ip.pip[0].ip_address : null
}

output "web_ui_url" {
  value = "https://${var.assign_public_ip ? azurerm_public_ip.pip[0].ip_address : azurerm_network_interface.nic.private_ip_address}"
}
