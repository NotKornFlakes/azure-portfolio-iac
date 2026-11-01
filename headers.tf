# Security headers. Cloudflare adds them at the edge with a Transform Rule,
# so they apply to every response on the zone, whatever serves it.
# HSTS and X-Content-Type-Options are set in tls.tf (zone settings).

locals {
  # The site has no JavaScript, so scripts are blocked entirely. Styles and
  # fonts only load from the site itself (site/styles.css, site/fonts/), so
  # no third party is allowed anywhere and inline styles are blocked.
  content_security_policy = join("; ", [
    "default-src 'none'",
    "script-src 'none'",
    "style-src 'self'",
    "font-src 'self'",
    "img-src 'self'",
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

  rules = [
    {
      description = "Security headers on every response"
      enabled     = true
      expression  = "true"
      action      = "rewrite"

      action_parameters = {
        headers = {
          # Pages opened from another site get their own browsing context,
          # so the other window can't script or navigate this one
          "Cross-Origin-Opener-Policy" = {
            operation = "set"
            value     = "same-origin"
          }
          # Other sites can't load these files as images, scripts or
          # embeds (blocks hotlinking and cross-origin data leaks)
          "Cross-Origin-Resource-Policy" = {
            operation = "set"
            value     = "same-origin"
          }
          # Turn off browser features the site never uses
          "Permissions-Policy" = {
            operation = "set"
            value     = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
          }
          # Send only the origin, never full URLs, to other sites
          "Referrer-Policy" = {
            operation = "set"
            value     = "strict-origin-when-cross-origin"
          }
          # Nobody can embed the site in a frame (clickjacking)
          "X-Frame-Options" = {
            operation = "set"
            value     = "DENY"
          }
        }
      }
    },
    # Skipped for PDFs: a strict policy can stop the browser's built-in PDF
    # viewer from rendering resume.pdf.
    {
      description = "Content-Security-Policy on HTML pages"
      enabled     = true
      expression  = "not (http.request.uri.path contains \".pdf\")"
      action      = "rewrite"

      action_parameters = {
        headers = {
          "Content-Security-Policy" = {
            operation = "set"
            value     = local.content_security_policy
          }
        }
      }
    },
  ]
}
