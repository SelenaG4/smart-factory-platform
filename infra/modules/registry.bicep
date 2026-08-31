/*
  Azure Container Registry -- one registry, many services.

  Admin user is deliberately DISABLED. Image pulls happen through each service's
  managed identity holding the AcrPull role (see service.bicep), and CI pushes
  authenticate with the OIDC federated credential. No registry password exists
  anywhere, so there is none to leak or rotate.
*/

@description('Azure region for the registry.')
param location string

@description('Name prefix shared by all platform resources.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Registry SKU. Basic is sufficient for a portfolio platform; Premium adds geo-replication and private link.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param sku string = 'Basic'

@description('Days after which untagged manifests are purged. Basic SKU ignores this; kept for when the SKU is raised.')
param untaggedRetentionDays int = 7

// ACR names are globally unique, alphanumeric only, and lowercase. The prefix
// carries hyphens for every other resource type, so strip them here and add a
// subscription-derived suffix to avoid collisions with someone else's registry.
var registryName = toLower('${replace(namePrefix, '-', '')}${uniqueString(resourceGroup().id)}')

resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    // No admin account: identity-based auth only.
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    anonymousPullEnabled: false
    policies: {
      retentionPolicy: {
        status: sku == 'Premium' ? 'enabled' : 'disabled'
        days: untaggedRetentionDays
      }
    }
  }
}

output registryId string = registry.id
output registryName string = registry.name
output loginServer string = registry.properties.loginServer
