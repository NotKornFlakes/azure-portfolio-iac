# Random suffix so the storage account name is globally unique
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  name_prefix          = "${var.project_name}-${var.environment}"
  storage_account_name = "st${var.project_name}${var.environment}${random_string.suffix.result}"
  site_dir             = "${path.module}/site"
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "site" {
  # Security scan exceptions, each one a deliberate trade-off for a public static website:
  #checkov:skip=CKV_AZURE_59:Static website hosting requires public network access
  #checkov:skip=CKV2_AZURE_33:Private endpoints would block public visitors to the site
  #checkov:skip=CKV_AZURE_206:LRS is enough for a dev site whose source of truth is this repo
  #checkov:skip=CKV2_AZURE_1:No sensitive data; Microsoft-managed encryption keys are sufficient
  #checkov:skip=CKV_AZURE_33:Queue service is not used by this project
  #checkov:skip=CKV2_AZURE_40:Shared Key is used by Terraform to upload blobs; switching to Entra ID auth is on the roadmap
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  local_user_enabled              = false
  shared_access_key_enabled       = true

  # Recover accidentally deleted or overwritten files for 7 days
  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  # Any SAS token issued for this account expires after 1 day
  sas_policy {
    expiration_period = "01.00:00:00"
    expiration_action = "Log"
  }

  tags = var.tags
}

# Turns on static website hosting (creates the special $web container)
resource "azurerm_storage_account_static_website" "site" {
  storage_account_id = azurerm_storage_account.site.id
  index_document     = "index.html"
  error_404_document = "404.html"
}

# Upload every file in ./site to the $web container
resource "azurerm_storage_blob" "site_files" {
  for_each = fileset(local.site_dir, "**")

  name                 = each.value
  storage_container_id = "${azurerm_storage_account.site.id}/blobServices/default/containers/$web"
  type                 = "Block"
  source               = "${local.site_dir}/${each.value}"
  content_md5          = filemd5("${local.site_dir}/${each.value}")
  content_type = lookup(
    {
      html = "text/html"
      css  = "text/css"
      js   = "application/javascript"
      png  = "image/png"
      jpg  = "image/jpeg"
      svg  = "image/svg+xml"
    },
    reverse(split(".", each.value))[0],
    "application/octet-stream"
  )

  depends_on = [azurerm_storage_account_static_website.site]
}
