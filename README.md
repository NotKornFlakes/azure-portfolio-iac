# Azure Portfolio Site — Infrastructure as Code

![Terraform CI](https://github.com/NotKornFlakes/azure-portfolio-iac/actions/workflows/terraform-ci.yml/badge.svg)

A static portfolio website hosted on **Azure Storage**, provisioned entirely with **Terraform** and validated by **GitHub Actions** on every push.

**Live site:** https://stportfoliodev5b2u3i.z13.web.core.windows.net/

## Architecture

```
 Browser ──HTTPS──▶ Azure Storage Account (Static Website, $web container)
                         ▲
                         │ terraform apply
 Developer (VS Code) ────┘        GitHub Actions: fmt → validate → Checkov scan
```

| Resource | Purpose |
|---|---|
| `azurerm_resource_group` | Container for all project resources |
| `azurerm_storage_account` | StorageV2, LRS, TLS 1.2+, HTTPS only, 7-day soft delete, SAS expiry policy |
| `azurerm_storage_account_static_website` | Enables static site hosting |
| `azurerm_storage_blob` | Uploads every file in `site/` with the right content type |

## Security scanning

Every push runs [Checkov](https://www.checkov.io/), and the pipeline **fails** on any unaddressed finding.

**Hardening applied:** TLS 1.2 minimum, HTTPS only, no anonymous blob access, local users disabled, 7-day soft delete for blobs and containers, 1-day SAS token expiry policy.

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

## Deploy

```bash
az login
cp terraform.tfvars.example terraform.tfvars   # then add your subscription ID
terraform init
terraform plan
terraform apply
```

Terraform prints `website_url` when it finishes.

## Tear down

```bash
terraform destroy
```

## What I learned

- _Fill this in — reviewers love this section._

## Roadmap

- [x] Security scanning with enforced Checkov policy
- [ ] Switch blob uploads to Entra ID auth and disable Shared Key
- [ ] Azure Front Door / CDN with custom domain and HTTPS cert
- [ ] Remote state in an Azure Storage backend
- [ ] Visitor counter (Azure Functions + Cosmos DB)
- [ ] Deploy from GitHub Actions using OIDC (no stored secrets)
