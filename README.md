# Azure Portfolio Site — Infrastructure as Code

![Terraform CI](https://github.com/YOUR_GITHUB_USERNAME/azure-portfolio-iac/actions/workflows/terraform-ci.yml/badge.svg)

A static portfolio website hosted on **Azure Storage**, provisioned entirely with **Terraform** and validated by **GitHub Actions** on every push.

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
| `azurerm_storage_account` | StorageV2, LRS, TLS 1.2+, HTTPS only |
| `azurerm_storage_account_static_website` | Enables static site hosting |
| `azurerm_storage_blob` | Uploads every file in `site/` with the right content type |

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

- [ ] Azure Front Door / CDN with custom domain and HTTPS cert
- [ ] Remote state in an Azure Storage backend
- [ ] Visitor counter (Azure Functions + Cosmos DB)
- [ ] Deploy from GitHub Actions using OIDC (no stored secrets)
