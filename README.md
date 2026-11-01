# Portfolio Site on Cloudflare — Infrastructure as Code

![Terraform CI](https://github.com/NotKornFlakes/portfolio-iac/actions/workflows/terraform-ci.yml/badge.svg)
![Terraform Deploy](https://github.com/NotKornFlakes/portfolio-iac/actions/workflows/terraform-deploy.yml/badge.svg)

A static portfolio website served by **Cloudflare Workers static assets**, provisioned entirely with **Terraform** (`cloudflare` provider) and deployed by **GitHub Actions**. Terraform state lives in **Cloudflare R2**. There is no origin server.

**Live site:** https://timfletcher.tech

## Architecture

```
 Browser ──HTTPS──▶ Cloudflare edge (timfletcher.tech, www)
                     • TLS certificate, HTTP → HTTPS, HSTS
                     • Transform Rule: CSP and other security headers
                     • Worker static assets: the files in site/
                                   ▲
                                   │ terraform apply (cloudflare provider)
 Developer ──git push──▶ GitHub Actions
                         • CI: fmt → validate → Checkov scan
                         • PR: terraform plan
                         • main: terraform apply (production environment)
                                   │
                                   ▼
                         Terraform state in Cloudflare R2
                         (bucket-scoped token, lock file)
```

**Why Workers?** The site first ran on Azure Storage behind Cloudflare (see [History](#history)). That needed a Cloud Connector rule to rewrite the Host header, and the Azure endpoint stayed reachable directly, skipping Cloudflare's security headers. Workers static assets serve the files from Cloudflare's edge, so there's no origin to rewrite to or bypass, and one Terraform provider manages everything. Requests to static assets are free and unlimited, and no Worker code runs.

| Resource | Purpose |
|---|---|
| `cloudflare_workers_script` | A Worker with static assets and no code. Uploads every file in `site/`; the provider hashes the folder at plan time, so any changed file shows up in `terraform plan`. Unknown paths get `404.html` with a 404 status, and the versioned font files are cached by browsers for a year |
| `cloudflare_workers_custom_domain` (apex + www) | Routes both hostnames to the Worker; Cloudflare creates their DNS records and TLS certificate |
| `cloudflare_workers_script_subdomain` | Turns off the `*.workers.dev` URL and preview URLs, so the site is only reachable through the zone and its security settings |
| `cloudflare_dns_record` (MX, SPF, DMARC, DKIM) | Null MX, `v=spf1 -all`, DMARC `p=reject` and an empty DKIM key, so nobody can send email pretending to be this domain |
| `cloudflare_zone_setting` (×5) | Full (strict) TLS, always HTTPS, TLS 1.2 minimum, automatic HTTPS rewrites, HSTS (1 year) with `nosniff` |
| `cloudflare_ruleset` (response headers) | Content-Security-Policy, `X-Frame-Options: DENY`, Referrer-Policy, Permissions-Policy and the Cross-Origin-Opener/Resource policies on every response |
| `cloudflare_zone_dnssec` | Signs DNS answers so forged records are detected; `prevent_destroy` stops Terraform from turning it off while the registry still has the DS record |

The email, TLS, header and DNSSEC resources existed before state moved to R2, so [`imports.tf`](imports.tf) adopts them with `import` blocks instead of recreating them. Once a resource is in state its import block does nothing, so the blocks stay as a record of the IDs and can rebuild the state if it's ever lost.

## CI/CD

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform-ci.yml` | Every push and PR | `fmt`, `validate`, Checkov scan of the Terraform and the workflows, zizmor scan of the workflows; fails on any unaddressed finding |
| `terraform-deploy.yml` | Pull request | `terraform plan`, a preview of what would change |
| `terraform-deploy.yml` | Merge to `main` | `terraform apply` in the `production` environment, then [`verify-live.sh`](scripts/verify-live.sh) checks the live site from outside |
| `drift-check.yml` | Mondays, or by hand | `terraform plan -detailed-exitcode` to catch changes made outside Terraform, and `verify-live.sh` to catch controls that stopped working |

There's no cache purge step: each deploy uploads a new asset manifest, and Workers serves the new files without one. I tested this from outside: a file Cloudflare had cached was replaced on the first request after `terraform apply` finished.

**Credentials:** the pipeline uses two Cloudflare tokens, both stored as GitHub Actions secrets:

- An **API token** for Terraform: **Account → Workers Scripts → Edit**, plus **DNS**, **Zone Settings** and **Transform Rules** edit rights on this one zone.
- An **R2 token** for the state: **Object Read & Write** on the state bucket only. It can't read or touch any other bucket.

A concurrency group stops two Terraform runs from overlapping, and the state is locked during each run with a `.tflock` object. R2 checks `If-None-Match` on writes atomically, so only one run can create the lock.

**Terraform state** lives in the R2 bucket `timfletcher-tfstate`, never in the repo. The account endpoint and R2 keys come from environment variables (`AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), so nothing account-specific is committed.

## Checking it from the outside

A green `terraform apply` only proves Cloudflare's API accepted the config. [`scripts/verify-live.sh`](scripts/verify-live.sh) checks what a visitor actually gets, using only public requests:

| Area | Checks |
|---|---|
| HTTPS | HTTP redirects to HTTPS; apex and `www` both serve the site |
| Headers | HSTS (1 year, subdomains), `nosniff`, `X-Frame-Options`, Referrer-Policy, Permissions-Policy, COOP, CORP |
| CSP | Blocks scripts, framing, `<base>` and form targets; allows no `unsafe-*`, no wildcards and no third-party origins |
| Other responses | Unknown paths return 404 *with* a CSP; the résumé is a PDF that can't be framed; fonts are cached for a year |
| security.txt | Served, and fails 30 days before `Expires` so it gets renewed in time |
| DNS | DNSSEC validates (AD flag from Google's resolver, not Cloudflare's); null MX, SPF `-all`, DMARC `p=reject` |

It runs after every deploy and every Monday, and writes a pass/fail table to the run's summary page. The Monday run also does a `terraform plan -detailed-exitcode`: `main` is always applied, so any planned change means someone or something changed the live config outside Terraform (drift). A failed run sends me a GitHub notification (by email, with default settings). GitHub pauses scheduled workflows after 60 days without a commit, so a quiet repo needs the workflow re-enabled now and then.

The script was tested against a local mock of the site in both directions: everything passes against the correct config, and removing a header, loosening the CSP, breaking the redirect, dropping DNSSEC or letting security.txt near its expiry each fails the right check.

Run it yourself on Linux or WSL:

```bash
bash scripts/verify-live.sh
```

## Security scanning

Every push runs [Checkov](https://www.checkov.io/) on the Terraform and the GitHub Actions workflows, and [zizmor](https://docs.zizmor.sh/) on the workflows, and the pipeline **fails** on any unaddressed finding. Checkov has no Cloudflare policies yet, so today the workflow checks do most of the work: no write-all permissions, no shell injection, no secrets passed to `curl`. zizmor goes deeper on GitHub Actions specifically: template injection, credentials left in the checkout, impostor commits behind a pinned hash, and Dependabot settings.

**Hardening applied:**
- **No origin server:** the files are served from Cloudflare's edge, and the `workers.dev` and preview URLs are off, so every request goes through the zone's TLS settings and security headers.
- **Cloudflare TLS:** Full (strict) SSL, automatic HTTP → HTTPS redirects, TLS 1.2 minimum.
- **Security headers:** a Cloudflare Transform Rule adds them to every response. The Content-Security-Policy blocks all scripts (the site has none) and all inline styles (CSS lives in `site/styles.css`), blocks framing, and only allows styles, fonts and images from the site itself. `Cross-Origin-Opener-Policy` and `Cross-Origin-Resource-Policy` (both `same-origin`) stop other sites from scripting a window they opened to this one or loading its files.
- **No third parties:** the fonts are self-hosted in `site/fonts/` instead of loaded from Google Fonts, so a visit sends nothing to anyone but Cloudflare, and there's no outside server that could change what the page loads. The CSP enforces this: it has no allowed domain other than `'self'`. Graded **A+** by securityheaders.com, Mozilla HTTP Observatory (115/100) and SSL Labs. HSTS keeps browsers on HTTPS.
- **Vulnerability disclosure:** [`/.well-known/security.txt`](https://timfletcher.tech/.well-known/security.txt) (RFC 9116) points researchers to GitHub private vulnerability reporting, so reports reach me without publishing an email address.
- **DNSSEC:** DNS answers are signed, so resolvers can detect forged records for the domain.
- **Email anti-spoofing:** the domain sends no email, and its DNS says so (null MX, SPF `-all`, DMARC `p=reject`, empty DKIM), so mail servers reject phishing that claims to come from it.
- **Least-privilege credentials:** the API token can only edit Workers scripts on the account and DNS, zone settings and transform rules on one zone. The R2 token only reaches the state bucket. The GitHub Actions token is read-only (`permissions: contents: read`).
- **No secrets in Git:** locally, the account ID, zone ID and API token live only in the git-ignored `terraform.tfvars`; in CI they're GitHub Actions secrets, masked in public logs.

**Supply chain:** every GitHub Action is pinned to a full commit hash instead of a version tag, so a compromised or moved tag can't change what runs in the pipeline. Dependabot opens a weekly PR when a new version is released, but only once that version is a week old, so a malicious release is likely to be caught by someone else first. The Cloudflare provider is pinned in `.terraform.lock.hcl` with its checksums, and every job uses the same pinned Terraform version. Checkouts don't keep the GitHub token in `.git/config` (`persist-credentials: false`), and every job has a timeout so a hung run can't hold the state lock.

**Accepted risk – long-lived Cloudflare tokens.** The Azure version signed in through OIDC, so no Azure secret existed anywhere. The Cloudflare API token and R2 token are stored secrets instead. They're scoped as narrowly as Cloudflare allows, `apply` only runs after approval in the `production` environment, and both tokens should have an expiry date so they get rotated.

**Accepted risk – no state history.** R2 doesn't support object versioning, so unlike the old Azure state account, earlier versions of the state can't be restored. The state holds no long-lived secrets, and the `import` blocks plus `terraform plan` can rebuild it from the live resources.

**Accepted risk – legacy TLS 1.2 cipher suites at the edge.** Cloudflare's Free plan offers some older CBC-mode TLS 1.2 ciphers for compatibility, which internet.nl flags as "phase out" (SSL Labs still grades A+, and modern browsers negotiate TLS 1.3). Choosing cipher suites requires Cloudflare's paid Advanced Certificate Manager, and requiring TLS 1.3 only would block some older corporate proxies, so recruiters on locked-down networks might not reach the site. Revisit if the site ever handles logins or personal data.

## Prerequisites

- A Cloudflare account with the domain added as a zone (Free plan) and R2 enabled
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.10+
- A Cloudflare API token with **Account → Workers Scripts → Edit**, **Zone → DNS → Edit**, **Zone → Zone Settings → Edit** and **Zone → Transform Rules → Edit**, limited to this account and zone

## Deploy

**Day to day:** open a pull request to see the `terraform plan`, then merge to `main`. GitHub Actions runs `terraform apply`.

**One-time setup:**

1. In the Cloudflare dashboard, create the R2 bucket `timfletcher-tfstate`. Then, under **R2 → Manage API tokens**, create a token with **Object Read & Write** applied to that bucket only, and note its Access Key ID and Secret Access Key.
2. Create the API token from the prerequisites. Give both tokens an expiry date.
3. Run Terraform locally:

   ```bash
   cp terraform.tfvars.example terraform.tfvars   # account ID, zone ID, API token
   cat > r2.env << 'EOF'                          # git-ignored, like terraform.tfvars
   export AWS_ACCESS_KEY_ID=...                   # R2 token
   export AWS_SECRET_ACCESS_KEY=...
   export AWS_ENDPOINT_URL_S3=https://<account-id>.r2.cloudflarestorage.com
   EOF
   source r2.env
   terraform init
   terraform plan
   ```

4. Add these repository secrets in GitHub (**Settings → Secrets and variables → Actions**): `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_API_TOKEN`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`. Also create an environment named `production`.

## Tear down

DNSSEC is protected by `prevent_destroy`, so `terraform destroy` refuses to run while it's managed. Disable DNSSEC in the Cloudflare dashboard first and wait for the DS record to clear at the registry. Then remove the `lifecycle` block in `dns.tf` and run:

```bash
terraform destroy
```

## History

- **Azure + Cloudflare (October 2026).** The first version served `site/` from an Azure Storage static website behind Cloudflare. A Cloud Connector rule rewrote the Host header, GitHub Actions signed in to Azure through OIDC with no client secret, blob uploads used Entra ID auth with storage account keys disabled, Terraform state lived in a versioned Azure Storage account, and a $5/month Azure budget alerted on spend.
- **Cloudflare only (October 2026).** Hosting moved to Workers static assets and Terraform state moved to R2, on version 5 of the Cloudflare provider. The email, DNSSEC, TLS and security-header configuration was imported into the new state rather than recreated. All Azure resources and the OIDC bootstrap script were removed.

## What I learned

The site first ran on Azure Storage behind Cloudflare (see [History](#history)), so most of these lessons come from building and running that version.

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
- [x] Azure version: remote state in Azure Storage, OIDC deploys, Entra ID blob uploads, budget alert
- [x] Security review fixes: email anti-spoofing, security headers (A+), DNSSEC, pinned actions, branch protection
- [x] Move hosting to Workers static assets and state to R2; remove Azure
- [x] Self-hosted fonts (first-party-only CSP), COOP/CORP, long cache for fonts
- [x] zizmor workflow scanning, Dependabot cooldown, no persisted checkout credentials
- [x] Live control checks after every deploy, plus weekly drift detection
- [ ] Visitor counter (Workers + D1)
