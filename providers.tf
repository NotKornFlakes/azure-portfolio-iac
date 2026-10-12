terraform {
  required_version = ">= 1.6.0"

  # Remote state in Azure Storage. Settings live in backend.hcl (written by
  # scripts/bootstrap-oidc.sh): terraform init -backend-config=backend.hcl
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.52"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id

  # GitHub Actions only has rights on this project's resource group, not the
  # whole subscription, so skip subscription-wide provider registration.
  resource_provider_registrations = "none"

  # Upload and read blobs with Entra ID (RBAC) instead of storage account keys
  storage_use_azuread = true
}

# Scoped API token (DNS, Zone Settings, Cloud Connector on this one zone only)
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
