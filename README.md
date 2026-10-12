# Azure Portfolio Site — Infrastructure as Code

![Terraform CI](https://github.com/NotKornFlakes/azure-portfolio-iac/actions/workflows/terraform-ci.yml/badge.svg)
![Terraform Deploy](https://github.com/NotKornFlakes/azure-portfolio-iac/actions/workflows/terraform-deploy.yml/badge.svg)

A static portfolio website hosted on **Azure Storage** behind **Cloudflare**, provisioned entirely with **Terraform** (two providers: `azurerm` and `cloudflare`) and deployed by **GitHub Actions** through **OIDC**: no passwords or keys for Azure are stored anywhere.

**Live site:** https://timfletcher.tech

## Architecture

```
 Browser ──HTTPS──▶ Cloudflare ──HTTPS──▶ Azure Storage Account
 (timfletcher.tech)  • TLS certificate    (Static Website, $web container)
                     • HTTP → HTTPS             ▲
                     • CDN cache                │
                     • Host header rewrite      │ terraform apply
                                                │ (azurerm + cloudflare providers)
 Developer ──git push──▶ GitHub Actions ────────┘
                         • CI: fmt → validate → Checkov scan
                         • PR: terraform plan
                         • main: terraform apply (production environment)
                                 │ OIDC sign-in, no stored secret
                                 ▼
                         Entra ID app ──▶ Terraform state in Azure Storage
                                          (Entra ID auth only, versioned, locked)
```

**Why Cloudflare?** Azure Storage can't serve HTTPS on a custom domain by itself, can't map an apex domain (`timfletcher.tech` without `www`), and only answers requests addressed to its own web endpoint. Cloudflare provides the certificate, flattens the apex CNAME, and a Cloud Connector rule rewrites the Host header so Azure accepts the traffic. Azure Front Door does the same job but costs about $35/month; this setup is free apart from the domain.

| Resource | Purpose |
|---|---|
| `azurerm_resource_group` | Container for all project resources |
| `azurerm_storage_account` | StorageV2, LRS, TLS 1.2+, HTTPS only, account keys disabled, 7-day soft delete, SAS expiry policy |
| `azurerm_storage_account_static_website` | Enables static site hosting |
| `azurerm_storage_blob` | Uploads every file in `site/` with the right content type; `content_md5` re-uploads a file whenever its contents change |
| `azurerm_consumption_budget_resource_group` | $5/month budget on the site's resource group; emails an alert at 85% of actual spend |
| `cloudflare_record` (apex + www) | Proxied CNAMEs pointing the custom domain at the Azure web endpoint |
| `cloudflare_record` (MX, SPF, DMARC, DKIM) | Null MX, `v=spf1 -all`, DMARC `p=reject` and an empty DKIM key, so nobody can send email pretending to be this domain |
| `cloudflare_cloud_connector_rules` | Rewrites the Host header so Azure Storage serves the custom domain |
| `cloudflare_zone_settings_override` | Full (strict) TLS to the origin, always HTTPS, TLS 1.2 minimum, HSTS (1 year), `nosniff` |
| `cloudflare_ruleset` (response headers) | Content-Security-Policy, `X-Frame-Options: DENY`, Referrer-Policy and Permissions-Policy on every response |
| `cloudflare_zone_dnssec` | Signs DNS answers so forged records are detected |

## CI/CD

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform-ci.yml` | Every push and PR | `fmt`, `validate`, Checkov scan; fails on any unaddressed finding |
| `terraform-deploy.yml` | Pull request | `terraform plan`, a preview of what would change |
| `terraform-deploy.yml` | Merge to `main` | `terraform apply` in the `production` environment, then purges the Cloudflare cache so visitors get the new files immediately |

**How GitHub signs in to Azure:** GitHub issues a short-lived OIDC token for each run, and Entra ID exchanges it for an Azure token. The Entra ID app only trusts two subjects: pull requests and the `production` environment of this repo, identified by GitHub's immutable owner and repo IDs, so a renamed or recreated repo can't impersonate it. There is no client secret to leak or rotate.

**Least privilege:** the deploy identity has **Contributor on the site's resource group only** (not the subscription) and **Storage Blob Data Contributor on the state account only**. A concurrency group stops two Terraform runs from overlapping, and the state blob is locked during each run.

**Terraform state** lives in a separate storage account created by [`scripts/bootstrap-oidc.sh`](scripts/bootstrap-oidc.sh): shared keys disabled (Entra ID auth only), TLS 1.2+, no public access, blob versioning and 30-day soft delete so any state version can be recovered.

## Security scanning

Every push runs [Checkov](https://www.checkov.io/), and the pipeline **fails** on any unaddressed finding.

**Hardening applied:**
- **Azure:** TLS 1.2 minimum, HTTPS only, no anonymous blob access, local users disabled, 7-day soft delete for blobs and containers, 1-day SAS token expiry policy.
- **No storage account keys:** Shared Key access is disabled on both storage accounts. Terraform uploads site files with Entra ID (`storage_use_azuread = true`) using the **Storage Blob Data Contributor** role, so there's no account key that could leak or need rotating.
- **Cloudflare:** Full (strict) SSL, so Cloudflare validates Azure's certificate; automatic HTTP → HTTPS redirects; TLS 1.2 minimum.
- **Security headers:** Azure static sites can't send custom headers, so a Cloudflare Transform Rule adds them. The Content-Security-Policy blocks all scripts (the site has none), blocks framing, and only allows fonts from Google Fonts. HSTS keeps browsers on HTTPS.
- **DNSSEC:** DNS answers are signed, so resolvers can detect forged records for the domain.
- **Email anti-spoofing:** the domain sends no email, and its DNS says so (null MX, SPF `-all`, DMARC `p=reject`, empty DKIM), so mail servers reject phishing that claims to come from it.
- **Least-privilege credentials:** the Cloudflare API token is scoped to one zone with only DNS, Zone Settings, Cloud Connector and Cache Purge rights. The GitHub Actions token is read-only (`permissions: contents: read`).
- **No secrets in Git:** locally, the subscription ID and API token live only in the git-ignored `terraform.tfvars`; in CI they're GitHub Actions secrets, masked in public logs. Terraform state lives in Azure, never in the repo.
- **No stored Azure credentials:** GitHub Actions signs in with OIDC federation, so there's no client secret anywhere.

**Supply chain:** every GitHub Action is pinned to a full commit hash instead of a version tag, so a compromised or moved tag can't change what runs in the pipeline. Dependabot opens a weekly PR when a new version is released.

**Accepted risks:** some checks don't fit a public website. Each one is suppressed in `main.tf` with a written reason:

| Check | Why it's skipped |
|---|---|
| CKV_AZURE_59 – disallow public access | A public website has to be reachable from the internet |
| CKV2_AZURE_33 – private endpoint | Would block public visitors |
| CKV_AZURE_206 – geo-replication | Dev site; the repo is the source of truth, so LRS keeps cost minimal |
| CKV2_AZURE_1 – customer-managed keys | No sensitive data; Microsoft-managed keys are sufficient |
| CKV_AZURE_33 – queue logging | Queue service isn't used |

**Accepted risk outside Checkov – the Azure endpoint bypasses Cloudflare.** The site is also reachable directly at its Azure web endpoint (`*.z13.web.core.windows.net`), which skips Cloudflare's cache, headers and DDoS protection. Restricting the storage firewall to Cloudflare's IP ranges would also block GitHub Actions from uploading files, because the Azure data plane would reject the runners' IPs. The risk is low: the endpoint only serves the same public static files, has no secrets or write access, and the $5 budget alert catches any unusual bandwidth cost. A future fix is moving uploads to a self-hosted runner or Azure Front Door with Private Link.

## Prerequisites

- An Azure account (free tier works)
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.6+
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- A domain added to Cloudflare (Free plan), plus a Cloudflare API token scoped to that zone with **Zone → DNS → Edit**, **Zone → Zone Settings → Edit**, **Zone → Cloud Connector → Edit**, **Zone → Cache Purge → Purge** and **Zone → Transform Rules → Edit**

## Deploy

**Day to day:** open a pull request to see the `terraform plan`, then merge to `main`. GitHub Actions runs `terraform apply`.

**One-time setup:**

```bash
az login
./scripts/bootstrap-oidc.sh                     # state storage, Entra ID app, roles, backend.hcl
cp terraform.tfvars.example terraform.tfvars    # for local runs: subscription ID, zone ID, API token
terraform init -backend-config=backend.hcl
```

Then add these repository secrets in GitHub (**Settings → Secrets and variables → Actions**): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_API_TOKEN`, `BUDGET_ALERT_EMAIL`. Also create an environment named `production`.

Terraform prints `custom_domain_url` (the Cloudflare address) and `website_url` (the raw Azure endpoint) after each apply.

## Tear down

```bash
terraform destroy
```

## What I learned

- **AI speeds up the build, but I own the review.** With clear prompts and structure, AI drafted most of the Terraform and caught security issues. My job was quality control: reading every `terraform plan` before applying, checking what would change, and catching anything wrong before it reached production.
- **Secrets have a home, and it's never Git.** Connecting Azure and Cloudflare needs a subscription ID and an API token. Locally they live in a git-ignored `terraform.tfvars`, and the repo only has a `terraform.tfvars.example` with placeholders. For the pipeline, I stored them as **GitHub Actions secrets**, which are encrypted, passed to Terraform as `TF_VAR_` environment variables, and masked as `***` in the public Actions logs. I also checked the full Git history to confirm nothing had ever leaked.
- **Scope every credential to the job.** The Cloudflare API token only works on one zone (`timfletcher.tech`) with only the permissions Terraform uses: DNS, Zone Settings and Cloud Connector. When the pipeline later needed to purge the cache, I added that one permission instead of switching to a broader token. The same idea applies on the Azure side: the deploy identity can only touch this project's resource group.
- **Why the Cloudflare rule exists.** Azure Storage only answers requests addressed to its own `*.web.core.windows.net` hostname and can't serve HTTPS on a custom domain. A Cloudflare Cloud Connector rule rewrites the Host header so Azure accepts traffic for `timfletcher.tech`, while Cloudflare handles the certificate, the apex domain and HTTP → HTTPS redirects.
- **A CDN means two copies of every file.** After updating my résumé, the deploy succeeded but the site still showed the old version. Checking the Azure endpoint directly showed the new file, so the stale copy was Cloudflare's edge cache. I purged it by hand once, then added a step to the deploy workflow that purges the cache after every `terraform apply`.
- **Pushing isn't deploying.** `git add`, `commit` and `push` update the repo, and GitHub Actions checks the code. The live site only changes when `terraform apply` runs, which is needed for changes to `site/` or the `.tf` files but not for README edits. I automated that step: merging to `main` now runs `terraform apply` in GitHub Actions through OIDC, and pull requests show a `terraform plan` first.
- **Read the auth error closely.** My first OIDC deploy failed with `AADSTS700213: No matching federated identity record found`. The error showed that GitHub's token identifies the repo by its immutable IDs (`owner@id/repo@id`), not just its name. Updating the federated credential to match fixed it, and it's more secure, because a renamed or recreated repo can't impersonate mine.
- **Roll out risky changes in stages.** Turning off storage account keys could have locked Terraform out. I split it into two pull requests: first switch Terraform to Entra ID auth while keys still worked and confirm `terraform plan` showed no changes, then disable the keys.
- **Cheap to build, but costs add up.** The Azure side costs very little, but the domain renews at about $45/year after a ~$10 first year. I manage a $5/month Azure budget in Terraform that emails me at 85% of actual spend, so cost controls are versioned and reviewed like the rest of the infrastructure.

## Roadmap

- [x] Security scanning with enforced Checkov policy
- [x] Custom domain with HTTPS via Cloudflare (managed in Terraform)
- [x] Read-only GitHub Actions token
- [x] Remote state in an Azure Storage backend
- [x] Deploy from GitHub Actions using OIDC (no stored secrets)
- [x] Blob uploads with Entra ID auth; Shared Key disabled
- [x] Azure budget alert managed in Terraform
- [ ] Visitor counter (Azure Functions + Cosmos DB)
