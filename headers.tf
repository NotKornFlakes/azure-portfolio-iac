# Security headers. Azure Storage static websites can't set custom response
# headers, so Cloudflare adds them at the edge with a Transform Rule.
# HSTS and X-Content-Type-Options are set in dns.tf (zone settings).

locals {
  # The site has no JavaScript, so scripts are blocked entirely. Styles only
  # load from site/styles.css and Google Fonts; inline styles are blocked.
  content_security_policy = join("; ", [
    "default-src 'none'",
    "script-src 'none'",
    "style-src 'self' https://fonts.googleapis.com",
    "font-src https://fonts.gstatic.com",
    "img-src 'self' data:",
    "frame-ancestors 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "upgrade-insecure-requests",
  ])
}

resource "cloudflare_ruleset" "security_headers" {
  zone_id     = var.cloudflare_zone_id
  name        = "Security headers"
  description = "Adds security response headers (managed by Terraform)"
  kind        = "zone"
  phase       = "http_response_headers_transform"

  rules {
    description = "Security headers on every response"
    enabled     = true
    expression  = "true"
    action      = "rewrite"

    # Keep headers in alphabetical order by name: Cloudflare returns them
    # sorted, and the provider reports an error if the order differs.
    action_parameters {
      # Turn off browser features the site never uses
      headers {
        name      = "Permissions-Policy"
        operation = "set"
        value     = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
      }
      # Send only the origin, never full URLs, to other sites
      headers {
        name      = "Referrer-Policy"
        operation = "set"
        value     = "strict-origin-when-cross-origin"
      }
      # Nobody can embed the site in a frame (clickjacking)
      headers {
        name      = "X-Frame-Options"
        operation = "set"
        value     = "DENY"
      }
    }
  }

  # Skipped for PDFs: a strict policy can stop the browser's built-in PDF
  # viewer from rendering resume.pdf.
  rules {
    description = "Content-Security-Policy on HTML pages"
    enabled     = true
    expression  = "not (http.request.uri.path contains \".pdf\")"
    action      = "rewrite"

    action_parameters {
      headers {
        name      = "Content-Security-Policy"
        operation = "set"
        value     = local.content_security_policy
      }
    }
  }
}

# DNSSEC signs DNS answers so resolvers can detect forged records. Cloudflare
# is also the registrar, so it publishes the DS record at the .tech registry.
# Never remove this resource while the DS record exists, or the domain stops
# resolving; disable DNSSEC in the dashboard first and wait for the DS to clear.
resource "cloudflare_zone_dnssec" "site" {
  zone_id = var.cloudflare_zone_id
}
