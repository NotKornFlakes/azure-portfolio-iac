output "website_url" {
  description = "Public URL of the deployed portfolio site"
  value       = azurerm_storage_account.site.primary_web_endpoint
}

output "resource_group_name" {
  description = "Resource group holding all resources"
  value       = azurerm_resource_group.main.name
}

output "storage_account_name" {
  description = "Storage account hosting the site"
  value       = azurerm_storage_account.site.name
}
