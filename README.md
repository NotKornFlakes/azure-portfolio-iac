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
- **Security headers:** Azure static sites can't send custom headers, so a Cloudflare Transform Rule adds them. The Content-Security-Policy blocks all scripts (the site has none) and all inline styles (CSS lives in `site/styles.css`), blocks framing, and only allows fonts from Google Fonts. Graded **A+** by securityheaders.com, Mozilla HTTP Observatory (115/100) and SSL Labs. HSTS keeps browsers on HTTPS.
- **Vulnerability disclosure:** [`/.well-known/security.txt`](https://timfletcher.tech/.well-known/security.txt) (RFC 9116) points researchers to GitHub private vulnerability reporting, so reports reach me without publishing an email address.
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

**Accepted risk outside Checkov – legacy TLS 1.2 cipher suites at the edge.** Cloudflare's Free plan offers some older CBC-mode TLS 1.2 ciphers for compatibility, which internet.nl flags as "phase out" (SSL Labs still grades A+, and modern browsers negotiate TLS 1.3). Choosing cipher suites requires Cloudflare's paid Advanced Certificate Manager, and requiring TLS 1.3 only would block some older corporate proxies, so recruiters on locked-down networks might not reach the site. Revisit if the site ever handles logins or personal data.

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

### Building it

- **AI speeds up the build, but I own the review.** With clear prompts and structure, AI drafted most of the Terraform and caught security issues. My job was quality control: reading every `terraform plan` before applying, checking what would change, and catching anything wrong before it reached production.
- **Why the Cloudflare rule exists.** Azure Storage only answers requests addressed to its own `*.web.core.windows.net` hostname and can't serve HTTPS on a custom domain. A Cloudflare Cloud Connector rule rewrites the Host header so Azure accepts traffic for `timfletcher.tech`, while Cloudflare handles the certificate, the apex domain and HTTP → HTTPS redirects.
- **Read the auth error closely.** My first OIDC deploy failed with `AADSTS700213: No matching federated identity record found`. The error showed that GitHub's token identifies the repo by its immutable IDs (`owner@id/repo@id`), not just its name. Updating the federated credential to match fixed it, and it's more secure, because a renamed or recreated repo can't impersonate mine.
- **Roll out risky changes in stages.** Turning off storage account keys could have locked Terraform out. I split it into two pull requests: first switch Terraform to Entra ID auth while keys still worked and confirm `terraform plan` showed no changes, then disable the keys.
- **A clean plan isn't proof.** Adding security headers, the plan looked right, but the apply failed with `Provider produced inconsistent result after apply`. Cloudflare returns headers sorted alphabetically, and the provider expected them in the order I wrote them. The rule had already been created, so Terraform marked it tainted and replaced it on the next run. Ordering the headers alphabetically fixed it, and I now verify every deploy from the outside (`curl -I`, `dig`) instead of trusting a green pipeline alone.

### Securing it

- **Security isn't the default; you have to design it in.** The first version went live working, encrypted and scanned by Checkov, and I went to bed thinking it was done. A self-review the next morning found gaps: no email anti-spoofing records, no security headers, no DNSSEC, and nothing stopping a direct push to `main` from deploying to production. None of these was an open door on a personal site, so I ranked them by impact and fixed them in separate pull requests. The lesson is that "it works and it's encrypted" isn't the same as "it's hardened". These belong on a checklist from day one, not in a review afterwards.
- **Why it matters at scale.** On my site, the worst case is embarrassment. At a company, the same gaps are serious: a domain without SPF/DMARC can be spoofed to phish customers or trick finance teams into wire fraud; missing headers make clickjacking and injected scripts easier against users who are logged in; and if any one developer account can push straight to production, one stolen password is a production breach.
- **Lock down who can change the code, then test the lock.** A GitHub ruleset on `main` now requires a pull request and a passing `validate` check, with no bypass for admins, and every deploy waits for approval in the `production` environment. My first test push still went through because the ruleset wasn't enforcing yet; the second was rejected with `GH013: Repository rule violations`. A control isn't real until you've watched it block something.
- **Security headers, and checking them from the outside.** Azure static sites can't send custom headers, so a Cloudflare Transform Rule adds them: a Content-Security-Policy that blocks all scripts (the site has none), `X-Frame-Options: DENY`, Referrer-Policy, Permissions-Policy, plus HSTS and `nosniff`. [securityheaders.com](https://securityheaders.com) went from no headers to an **A+**. External scanners like it give an objective grade that anyone can reproduce, which is more convincing than "I think it's secure". I left the CSP off the PDF, because a strict policy can break the browser's built-in PDF viewer.
- **Stop domain spoofing with DNS.** The domain sends no email, and its DNS now says so: a null MX record, SPF `-all`, DMARC `p=reject` and an empty DKIM key. Mail servers reject anything claiming to come from it, and DNSSEC signs the DNS answers so they can't be forged.
- **Secrets have a home, and it's never Git.** Locally, the subscription ID and API tokens live in a git-ignored `terraform.tfvars`, and the repo only has a `terraform.tfvars.example` with placeholders. For the pipeline, they're **GitHub Actions secrets**: encrypted, passed to Terraform as `TF_VAR_` environment variables, and masked as `***` in the public logs. I also checked the full Git history to confirm nothing had ever leaked.
- **Scope every credential to the job.** The Cloudflare API token only works on one zone, with only the permissions Terraform uses. Each time the project needed more (cache purge, transform rules), I added that one permission instead of switching to a broader token. On the Azure side, the deploy identity can only touch this project's resource group.
- **Trust commits, not tags.** Every GitHub Action is pinned to a full commit hash, so a hijacked or moved version tag can't change what runs with my secrets. This is the attack used in the 2025 `tj-actions/changed-files` compromise. Dependabot opens a pull request when a new version comes out, so updates still happen, but only after review.

### Running it

- **Pushing isn't deploying.** `git add`, `commit` and `push` update the repo, and GitHub Actions checks the code. The live site only changes when `terraform apply` runs. Merging to `main` now runs it automatically through OIDC, after a `terraform plan` on the pull request.
- **Caches live at every layer.** Several times a change "didn't work" when it had. The culprit was always a cache: the browser (fixed with a hard refresh or private window), my laptop's DNS cache (`resolvectl flush-caches`, or `dig @1.1.1.1` to skip it), a public resolver still remembering that my brand-new domain didn't exist, and Cloudflare's edge cache serving the old résumé after a successful deploy. Checking the Azure endpoint directly proved the new file was there, so I purged Cloudflare by hand, then added a purge step to the deploy workflow. Now, before changing code, I check each layer from origin to browser. Caching helps security by absorbing traffic spikes and keeping load off the origin, but it can also hurt: a security fix doesn't reach visitors until the cache clears, and a misconfigured cache can be poisoned or can leak one user's data to another. Next steps would be `Cache-Control` headers per file type and purging only the files that changed.
- **Cheap to build, but costs add up.** The Azure side costs very little, but the domain renews at about $45/year after a ~$10 first year. A $5/month Azure budget, managed in Terraform, emails me at 85% of actual spend. Budgets only cover their scope, though: my separate subscription-wide budget showed $17 within days, which counts everything in the subscription, not just this site. Knowing what a budget covers matters as much as having one.

## Roadmap

- [x] Security scanning with enforced Checkov policy
- [x] Custom domain with HTTPS via Cloudflare (managed in Terraform)
- [x] Read-only GitHub Actions token
- [x] Remote state in an Azure Storage backend
- [x] Deploy from GitHub Actions using OIDC (no stored secrets)
- [x] Blob uploads with Entra ID auth; Shared Key disabled
- [x] Azure budget alert managed in Terraform
- [x] Security review fixes: email anti-spoofing, security headers (A+), DNSSEC, pinned actions, branch protection
- [ ] Visitor counter (Azure Functions + Cosmos DB)
