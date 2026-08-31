#!/usr/bin/env bash
#
# One-time setup: let GitHub Actions deploy to Azure without storing a secret.
#
# What this creates
#   1. An Entra ID app registration + service principal for CI.
#   2. Federated credentials binding that identity to specific GitHub repos and
#      refs. Azure will only accept a token that GitHub minted for exactly those
#      repos -- not for any other repo, not for a fork, not for a pull request
#      from someone else's branch.
#   3. An Owner role assignment scoped to the single resource group.
#
# Why OIDC rather than `az ad sp create-for-rbac --sdk-auth` in a repo secret:
# there is no long-lived credential anywhere. Nothing to rotate, nothing to
# leak in a log, and nothing that still works if someone copies it out.
#
# Why Owner and not Contributor: infra/modules/service.bicep creates role
# assignments (AcrPull, Key Vault Secrets User), and writing role assignments
# needs RBAC-write, which Contributor does not have. Scoped to one resource
# group this is proportionate; at subscription scope it would not be.
#
# Usage:
#   ./scripts/bootstrap_oidc.sh                    # uses the defaults below
#   GITHUB_OWNER=YourUser ./scripts/bootstrap_oidc.sh
#
# Re-running is safe: every step is idempotent.

set -euo pipefail

GITHUB_OWNER="${GITHUB_OWNER:-SelenaG4}"
APP_NAME="${APP_NAME:-smart-factory-platform-ci}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-smart-factory}"
LOCATION="${LOCATION:-switzerlandnorth}"

# Every repo that is allowed to deploy. Adding a service to the platform means
# adding its repo here so CI can authenticate.
REPOS=(
  "smart-factory-platform"
  "manufacturing-maintenance-rag"
  "surface-defect-inspector"
)

echo "==> Checking Azure login"
if ! az account show >/dev/null 2>&1; then
  echo "Not logged in. Run: az login" >&2
  exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "    Subscription: ${SUBSCRIPTION_ID}"
echo "    Tenant:       ${TENANT_ID}"

echo "==> Ensuring resource group ${RESOURCE_GROUP} exists"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

echo "==> Ensuring app registration ${APP_NAME} exists"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  echo "    Created app ${APP_ID}"
else
  echo "    Reusing app ${APP_ID}"
fi

echo "==> Ensuring service principal exists"
if ! az ad sp show --id "$APP_ID" >/dev/null 2>&1; then
  az ad sp create --id "$APP_ID" --output none
  # Entra needs a moment before the new principal is assignable.
  sleep 15
fi
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
echo "    Service principal object id: ${SP_OBJECT_ID}"

echo "==> Creating federated credentials"
add_credential() {
  local name="$1" subject="$2"
  if az ad app federated-credential list --id "$APP_ID" \
       --query "[?name=='${name}'] | [0].name" -o tsv | grep -q .; then
    echo "    exists:  ${name}"
    return
  fi
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"${name}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${subject}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none
  echo "    created: ${name}"
}

for repo in "${REPOS[@]}"; do
  # Pushes to main.
  add_credential "${repo}-main" "repo:${GITHUB_OWNER}/${repo}:ref:refs/heads/main"
  # Runs targeting the protected `production` environment, which is what the
  # reusable deploy workflow requests and where the approval gate lives.
  add_credential "${repo}-prod" "repo:${GITHUB_OWNER}/${repo}:environment:production"
done

echo "==> Granting Owner on the resource group (scoped, not subscription-wide)"
SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"
if az role assignment list --assignee "$SP_OBJECT_ID" --scope "$SCOPE" \
     --query "[?roleDefinitionName=='Owner'] | [0].id" -o tsv | grep -q .; then
  echo "    Already assigned."
else
  az role assignment create \
    --assignee-object-id "$SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role Owner \
    --scope "$SCOPE" \
    --output none
  echo "    Granted."
fi

cat <<EOF

========================================================================
Done. Add these three values as repository SECRETS in EACH repo:

  ${REPOS[*]}

  AZURE_CLIENT_ID        ${APP_ID}
  AZURE_TENANT_ID        ${TENANT_ID}
  AZURE_SUBSCRIPTION_ID  ${SUBSCRIPTION_ID}

These are identifiers, not credentials -- they are useless without a token
GitHub mints for one of the federated subjects above. They still belong in
repository secrets rather than in the workflow file.

Then, in each repo: Settings -> Environments -> New environment -> name it
exactly "production" and add yourself as a required reviewer. That is what
makes a deploy pause for approval instead of shipping straight through.

  gh secret set AZURE_CLIENT_ID --body "${APP_ID}"
  gh secret set AZURE_TENANT_ID --body "${TENANT_ID}"
  gh secret set AZURE_SUBSCRIPTION_ID --body "${SUBSCRIPTION_ID}"
========================================================================
EOF
