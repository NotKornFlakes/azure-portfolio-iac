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

variable "domain_name" {
  description = "Custom domain for the site (must already be a zone in Cloudflare)"
  type        = string
  default     = "timfletcher.tech"
}

variable "cloudflare_zone_id" {
  description = "Zone ID from the Cloudflare dashboard (Overview page, right sidebar)"
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token scoped to this zone"
  type        = string
  sensitive   = true
}

variable "monthly_budget" {
  description = "Monthly budget for the site's resource group, in your billing currency"
  type        = number
  default     = 5
}

variable "budget_alert_threshold" {
  description = "Percent of the monthly budget at which Azure sends an alert email"
  type        = number
  default     = 85

  validation {
    condition     = var.budget_alert_threshold > 0 && var.budget_alert_threshold <= 1000
    error_message = "budget_alert_threshold must be between 1 and 1000 (percent)."
  }
}

variable "budget_alert_email" {
  description = "Email address that receives budget alerts (kept out of Git)"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address."
  }
}
