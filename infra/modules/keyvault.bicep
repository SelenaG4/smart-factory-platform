/*
  Key Vault -- the only place a real secret lives.

  RBAC authorization is on rather than the legacy access-policy model, so grants
  are role assignments like everything else in the platform (auditable in
  Activity Log, assignable per-identity, revocable without editing the vault).

  Nothing here CREATES a secret. Secret values are put in by hand once, out of
  band, by a human -- deliberately, so that no credential ever passes through a
  template, a parameter file, or a CI log.
*/

@description('Azure region for the vault.')
param location string

@description('Name prefix shared by all platform resources.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Days a soft-deleted vault is recoverable. 7 is the minimum and keeps a trial subscription tidy.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 7

@description('Purge protection blocks permanent deletion for the full retention window. Off for a portfolio subscription so the RG can be torn down cleanly; ON is correct for production.')
param enablePurgeProtection bool = false

// Vault names are globally unique and capped at 24 characters.
var vaultName = take(toLower('${replace(namePrefix, '-', '')}kv${uniqueString(resourceGroup().id)}'), 24)

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    // Role assignments, not access policies.
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    // Left null when false: setting `false` explicitly is rejected by the API,
    // which only accepts true or absent.
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

output vaultId string = vault.id
output vaultName string = vault.name
output vaultUri string = vault.properties.vaultUri
