# Azure Portfolio Site — Infrastructure as Code

![Terraform CI](https://github.com/NotKornFlakes/azure-portfolio-iac/actions/workflows/terraform-ci.yml/badge.svg)

A static portfolio website hosted on **Azure Storage** behind **Cloudflare**, provisioned entirely with **Terraform** (two providers: `azurerm` and `cloudflare`) and validated by **GitHub Actions** on every push.

**Live site:** https://timfletcher.tech

## Architecture

```
 Browser ──HTTPS──▶ Cloudflare ──HTTPS──▶ Azure Storage Account
 (timfletcher.tech)  • TLS certificate    (Static Website, $web container)
                     • HTTP → HTTPS             ▲
                     • CDN cache                │
                     • Host header rewrite      │ terraform apply
                                                │ (azurerm + cloudflare providers)
                               Developer (VS Code)
                                                     GitHub Actions: fmt → validate → Checkov scan
```

**Why Cloudflare?** Azure Storage can't serve HTTPS on a custom domain by itself, can't map an apex domain (`timfletcher.tech` without `www`), and only answers requests addressed to its own web endpoint. Cloudflare provides the certificate, flattens the apex CNAME, and a Cloud Connector rule rewrites the Host header so Azure accepts the traffic. Azure Front Door does the same job but costs about $35/month; this setup is free apart from the domain.

| Resource | Purpose |
|---|---|
| `azurerm_resource_group` | Container for all project resources |
| `azurerm_storage_account` | StorageV2, LRS, TLS 1.2+, HTTPS only, 7-day soft delete, SAS expiry policy |
| `azurerm_storage_account_static_website` | Enables static site hosting |
| `azurerm_storage_blob` | Uploads every file in `site/` with the right content type; `content_md5` re-uploads a file whenever its contents change |
| `cloudflare_record` (apex + www) | Proxied CNAMEs pointing the custom domain at the Azure web endpoint |
| `cloudflare_cloud_connector_rules` | Rewrites the Host header so Azure Storage serves the custom domain |
| `cloudflare_zone_settings_override` | Full (strict) TLS to the origin, always HTTPS, TLS 1.2 minimum |

## Security scanning

Every push runs [Checkov](https://www.checkov.io/), and the pipeline **fails** on any unaddressed finding.

**Hardening applied:**
- **Azure:** TLS 1.2 minimum, HTTPS only, no anonymous blob access, local users disabled, 7-day soft delete for blobs and containers, 1-day SAS token expiry policy.
- **Cloudflare:** Full (strict) SSL, so Cloudflare validates Azure's certificate; automatic HTTP → HTTPS redirects; TLS 1.2 minimum.
- **Least-privilege credentials:** the Cloudflare API token is scoped to one zone with only DNS, Zone Settings and Cloud Connector edit rights. The GitHub Actions token is read-only (`permissions: contents: read`).
- **No secrets in Git:** the subscription ID and API token live only in the git-ignored `terraform.tfvars`, and Terraform state is never committed.

**Accepted risks:** some checks don't fit a public website. Each one is suppressed in `main.tf` with a written reason:

| Check | Why it's skipped |
|---|---|
| CKV_AZURE_59 – disallow public access | A public website has to be reachable from the internet |
| CKV2_AZURE_33 – private endpoint | Would block public visitors |
| CKV_AZURE_206 – geo-replication | Dev site; the repo is the source of truth, so LRS keeps cost minimal |
| CKV2_AZURE_1 – customer-managed keys | No sensitive data; Microsoft-managed keys are sufficient |
| CKV_AZURE_33 – queue logging | Queue service isn't used |
| CKV2_AZURE_40 – disable Shared Key | Terraform uses it to upload files; moving to Entra ID auth is on the roadmap |

## Prerequisites

- An Azure account (free tier works)
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.6+
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- A domain added to Cloudflare (Free plan), plus a Cloudflare API token scoped to that zone with **Zone → DNS → Edit**, **Zone → Zone Settings → Edit** and **Zone → Cloud Connector → Edit**

## Deploy

```bash
az login
cp terraform.tfvars.example terraform.tfvars   # add subscription ID, zone ID and API token
terraform init
terraform plan
terraform apply
```

Terraform prints `custom_domain_url` (the Cloudflare address) and `website_url` (the raw Azure endpoint) when it finishes.

## Tear down

```bash
terraform destroy
```

## What I learned

- **AI speeds up the build, but I own the review.** With clear prompts and structure, AI drafted most of the Terraform and caught security issues. My job was quality control: reading every `terraform plan` before applying, checking what would change, and catching anything wrong before it reached production.
- **Secrets never go in Git.** Connecting Azure and Cloudflare needs a subscription ID and an API token, and neither belongs in a public repo. I keep them in a git-ignored `terraform.tfvars`, commit only a `terraform.tfvars.example` with placeholders, and checked the full Git history to confirm nothing leaked. The Cloudflare token is scoped to one zone with only the permissions Terraform needs.
- **Pushing isn't deploying.** `git add`, `commit` and `push` update the repo, and GitHub Actions checks the code. The live site only changes when I run `terraform apply`, which is needed for changes to `site/` or the `.tf` files but not for README or workflow edits. Automating that step with OIDC is next on the roadmap.
- **Cheap to build, but costs add up.** The Azure side costs very little, but the domain renews at about $45/year after a ~$10 first year. I set an Azure budget alert so I'm notified before spending gets close to my monthly limit.

## Roadmap

- [x] Security scanning with enforced Checkov policy
- [ ] Switch blob uploads to Entra ID auth and disable Shared Key
- [x] Custom domain with HTTPS via Cloudflare (managed in Terraform)
- [x] Read-only GitHub Actions token
- [ ] Remote state in an Azure Storage backend
- [ ] Visitor counter (Azure Functions + Cosmos DB)
- [ ] Deploy from GitHub Actions using OIDC (no stored secrets)
