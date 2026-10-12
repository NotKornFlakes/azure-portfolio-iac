#!/usr/bin/env bash
# One-time setup for GitHub Actions deploys. Run locally after `az login`.
#
# Creates:
#   1. A hardened storage account that holds Terraform state (Entra ID auth
#      only, shared keys disabled, versioning + 30-day soft delete).
#   2. An Entra ID app registration that GitHub Actions signs in as through
#      OIDC federation. There is no client secret, so nothing can leak.
#   3. Least-privilege role assignments for that identity.
#   4. backend.hcl, which tells Terraform where the state lives.
#
# Safe to re-run: every step checks whether its resource already exists.
set -euo pipefail

# GitHub OIDC subject uses immutable owner@id/repo@id
REPO="NotKornFlakes@173021356/azure-portfolio-iac@1414812331"
LOCATION="eastus"
SITE_RG="rg-portfolio-dev"
STATE_RG="rg-portfolio-tfstate"
STATE_CONTAINER="tfstate"
APP_NAME="gh-azure-portfolio-iac"
ISSUER="https://token.actions.githubusercontent.com"

SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
# Deterministic, globally unique name, so re-runs reuse the same account
STATE_SA="sttfstate$(printf '%s' "$SUB_ID" | sha256sum | cut -c1-8)"

echo "==> Terraform state storage: $STATE_SA"
az group create --name "$STATE_RG" --location "$LOCATION" --tags managed_by=bootstrap purpose=tfstate -o none
if ! az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" -o none 2>/dev/null; then
  az storage account create \
    --name "$STATE_SA" --resource-group "$STATE_RG" --location "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --https-only true \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    -o none
fi
az storage account blob-service-properties update \
  --account-name "$STATE_SA" --resource-group "$STATE_RG" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 \
  -o none
if ! az storage container-rm show --storage-account "$STATE_SA" --resource-group "$STATE_RG" --name "$STATE_CONTAINER" -o none 2>/dev/null; then
  az storage container-rm create --storage-account "$STATE_SA" --resource-group "$STATE_RG" --name "$STATE_CONTAINER" -o none
fi
STATE_SA_ID=$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --query id -o tsv)
SITE_RG_ID=$(az group show --name "$SITE_RG" --query id -o tsv)
# The site's storage account (created by Terraform, so it may not exist on a first run)
SITE_SA_ID=$(az storage account list --resource-group "$SITE_RG" --query "[?starts_with(name, 'stportfolio')].id | [0]" -o tsv)

assign_role() { # $1=object id, $2=principal type, $3=role, $4=scope
  local existing
  existing=$(az role assignment list --assignee "$1" --role "$3" --scope "$4" --query "length(@)" -o tsv)
  if [ "$existing" = "0" ]; then
    az role assignment create --assignee-object-id "$1" --assignee-principal-type "$2" \
      --role "$3" --scope "$4" -o none
  fi
}

echo "==> Granting you access to the state container (needed to migrate state)"
ME=$(az ad signed-in-user show --query id -o tsv)
assign_role "$ME" User "Storage Blob Data Contributor" "$STATE_SA_ID"
if [ -n "$SITE_SA_ID" ]; then
  # Lets local terraform runs upload site files with Entra ID instead of account keys
  assign_role "$ME" User "Storage Blob Data Contributor" "$SITE_SA_ID"
fi

echo "==> GitHub Actions identity: $APP_NAME"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
fi
SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)
if [ -z "$SP_ID" ]; then
  SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
fi

add_federation() { # $1=credential name, $2=subject
  if [ -z "$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='$1'].name" -o tsv)" ]; then
    az ad app federated-credential create --id "$APP_ID" -o none --parameters \
      "{\"name\":\"$1\",\"issuer\":\"$ISSUER\",\"subject\":\"$2\",\"audiences\":[\"api://AzureADTokenExchange\"]}"
  fi
}
# Only these two GitHub contexts can sign in as this identity:
add_federation "github-pull-request" "repo:${REPO}:pull_request"
add_federation "github-env-production" "repo:${REPO}:environment:production"

echo "==> Least-privilege roles for GitHub Actions"
# Manage the site's resource group only (not the whole subscription)
assign_role "$SP_ID" ServicePrincipal "Contributor" "$SITE_RG_ID"
# Read and write Terraform state, nothing else in that account
assign_role "$SP_ID" ServicePrincipal "Storage Blob Data Contributor" "$STATE_SA_ID"
# Upload site files with Entra ID (storage account keys are disabled)
if [ -n "$SITE_SA_ID" ]; then
  assign_role "$SP_ID" ServicePrincipal "Storage Blob Data Contributor" "$SITE_SA_ID"
else
  echo "    Site storage account not found yet: run terraform apply, then re-run this script."
fi

cat > backend.hcl << HCL
resource_group_name  = "$STATE_RG"
storage_account_name = "$STATE_SA"
container_name       = "$STATE_CONTAINER"
key                  = "portfolio.tfstate"
use_azuread_auth     = true
HCL

cat << MSG

Done. backend.hcl was written.

Add these as GitHub repository secrets
(repo -> Settings -> Secrets and variables -> Actions -> New repository secret):

  AZURE_CLIENT_ID        $APP_ID
  AZURE_TENANT_ID        $TENANT_ID
  AZURE_SUBSCRIPTION_ID  (your subscription ID; run: az account show --query id -o tsv)
  CLOUDFLARE_ZONE_ID     (from terraform.tfvars)
  CLOUDFLARE_API_TOKEN   (from terraform.tfvars)

Role assignments can take a few minutes to take effect before you migrate state.
MSG
