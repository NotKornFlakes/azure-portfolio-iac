# timfletcher.tech never sends or receives email. These records tell every
# mail server to reject messages that claim to come from this domain, so it
# can't be used for phishing or spoofing.

# Null MX (RFC 7505): this domain accepts no mail
resource "cloudflare_record" "null_mx" {
  zone_id  = var.cloudflare_zone_id
  name     = "@"
  type     = "MX"
  content  = "."
  priority = 0
  ttl      = 1
  comment  = "Null MX: domain does not receive email (managed by Terraform)"
}

# SPF: no server is allowed to send mail as this domain
resource "cloudflare_record" "spf" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  type    = "TXT"
  content = "v=spf1 -all"
  ttl     = 1
  comment = "SPF: domain sends no email (managed by Terraform)"
}

# DMARC: reject anything that fails SPF/DKIM, including subdomains
resource "cloudflare_record" "dmarc" {
  zone_id = var.cloudflare_zone_id
  name    = "_dmarc"
  type    = "TXT"
  content = "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s"
  ttl     = 1
  comment = "DMARC: reject spoofed mail (managed by Terraform)"
}

# Empty DKIM key: no signature from this domain is ever valid
resource "cloudflare_record" "dkim_null" {
  zone_id = var.cloudflare_zone_id
  name    = "*._domainkey"
  type    = "TXT"
  content = "v=DKIM1; p="
  ttl     = 1
  comment = "DKIM: no valid signing keys (managed by Terraform)"
}
