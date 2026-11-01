locals {
  site_dir  = "${path.module}/site"
  hostnames = toset([var.domain_name, "www.${var.domain_name}"])
}

# The site is a Worker with static assets and no script. Cloudflare serves
# every file in ./site from its edge with the right content type. The
# provider hashes the directory at plan time, so any changed file shows up in
# terraform plan and is uploaded on apply.
resource "cloudflare_workers_script" "site" {
  account_id         = var.cloudflare_account_id
  script_name        = var.project_name
  compatibility_date = "2026-10-01"

  assets = {
    directory = local.site_dir
    config = {
      # /about.html is served at /about; unknown paths get 404.html with a 404
      html_handling      = "auto-trailing-slash"
      not_found_handling = "404-page"

      # Same format as a _headers file. Other files keep the Workers default
      # (revalidate on every visit) so edits show up right away. Font files
      # never change under the same name (the version is in the file name),
      # so browsers may keep them for a year.
      headers = <<-EOT
        /fonts/*
          Cache-Control: public, max-age=31536000, immutable
      EOT
    }
  }
}

# Serve the Worker on the apex and www. Cloudflare creates the DNS records and
# the TLS certificate for each hostname itself, so there are no CNAMEs here.
resource "cloudflare_workers_custom_domain" "site" {
  for_each = local.hostnames

  account_id = var.cloudflare_account_id
  zone_id    = var.cloudflare_zone_id
  hostname   = each.value
  service    = cloudflare_workers_script.site.script_name
}

# Turn off the public *.workers.dev URL and preview URLs. Without this the
# site would also be reachable outside the zone, skipping its security
# headers and TLS settings.
resource "cloudflare_workers_script_subdomain" "site" {
  account_id       = var.cloudflare_account_id
  script_name      = cloudflare_workers_script.site.script_name
  enabled          = false
  previews_enabled = false
}
