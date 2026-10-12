# Monthly cost guardrail for the site's resource group. Azure emails an alert
# when actual spend crosses the threshold. The email address comes from a
# git-ignored tfvars file locally and a GitHub secret in CI, never from the repo.
resource "azurerm_consumption_budget_resource_group" "site" {
  name              = "budget-${local.name_prefix}"
  resource_group_id = azurerm_resource_group.main.id
  amount            = var.monthly_budget
  time_grain        = "Monthly"

  time_period {
    # Must be the first day of a month
    start_date = "2026-10-01T00:00:00Z"
  }

  notification {
    enabled        = true
    threshold      = var.budget_alert_threshold
    threshold_type = "Actual"
    operator       = "GreaterThanOrEqualTo"
    contact_emails = [var.budget_alert_email]
  }
}
