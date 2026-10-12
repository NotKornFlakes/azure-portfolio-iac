# Custom domain: Cloudflare sits in front of the Azure static website.
#
#   Browser --HTTPS--> Cloudflare (TLS cert, CDN, HTTP->HTTPS redirect)
#                          --HTTPS--> Azure Storage static website
#
# Azure Storage can't serve HTTPS on a custom domain by itself, and it only
# answers requests whose Host header is its own web endpoint. A Cloud Connector
# rule rewrites the Host header so Azure accepts traffic for the custom domain.

locals {
  web_host = azurerm_storage_account.site.primary_web_host
}

# Apex record (Cloudflare flattens a CNAME at the root automatically).
# ttl = 1 means "automatic", which proxied records require.
resource "cloudflare_record" "apex" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  type    = "CNAME"
  content = local.web_host
  proxied = true
  ttl     = 1
  comment = "Portfolio site on Azure Storage (managed by Terraform)"
}

resource "cloudflare_record" "www" {
  zone_id = var.cloudflare_zone_id
  name    = "www"
  type    = "CNAME"
  content = local.web_host
  proxied = true
  ttl     = 1
  comment = "Portfolio site on Azure Storage (managed by Terraform)"
}

# Rewrite the Host header so Azure Storage accepts requests for the custom domain
resource "cloudflare_cloud_connector_rules" "azure_site" {
  zone_id = var.cloudflare_zone_id

  rules {
    description = "Serve ${var.domain_name} from the Azure static website"
    enabled     = true
    expression  = "(http.host in {\"${var.domain_name}\" \"www.${var.domain_name}\"})"
    provider    = "azure_storage"
    parameters {
      host = local.web_host
    }
  }
}

# TLS settings for the zone
resource "cloudflare_zone_settings_override" "tls" {
  zone_id = var.cloudflare_zone_id

  # Full (strict): Cloudflare validates Azure's certificate on every request.
  # always_use_https redirects http:// to https://.
  settings {
    ssl                      = "strict"
    always_use_https         = "on"
    min_tls_version          = "1.2"
    automatic_https_rewrites = "on"

    # HSTS: browsers only ever connect over HTTPS for the next year.
    # nosniff sends X-Content-Type-Options: nosniff.
    security_header {
      enabled            = true
      max_age            = 31536000
      include_subdomains = true
      preload            = false
      nosniff            = true
    }
  }
}
