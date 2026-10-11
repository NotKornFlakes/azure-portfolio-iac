variable "subscription_id" {
  description = "Azure subscription ID to deploy into (find it with: az account show --query id -o tsv)"
  type        = string
}

variable "project_name" {
  description = "Short name used to build resource names (lowercase letters and numbers only)"
  type        = string
  default     = "portfolio"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.project_name))
    error_message = "project_name must be 3-12 lowercase letters or numbers."
  }
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default = {
    managed_by = "terraform"
    purpose    = "portfolio"
  }
}
