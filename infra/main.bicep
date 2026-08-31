/*
  Smart-Factory AI Platform -- the whole thing, in one deployable unit.

  Shared substrate (one of each, provisioned once):
    monitoring   Log Analytics workspace + workspace-based Application Insights
    registry     Azure Container Registry, identity-auth only
    keyvault     RBAC Key Vault; secret VALUES are added by hand, never here
    environment  Container Apps managed environment (Consumption, scale to zero)

  Services (one module call each, sharing all of the above):
    rag          manufacturing-maintenance-rag
    defect       surface-defect-inspector

  Adding a third service is one more `module` block. That is the point.

  Scope is the resource group, not the subscription: an Azure free account is
  Owner on its own subscription, but resource-group scope means the whole
  platform is torn down with a single `az group delete` -- which matters when
  the deadline is a $200 credit rather than a budget.
*/

targetScope = 'resourceGroup'

@description('Azure region. Switzerland North keeps data in-country, which is the right default for a Swiss employer; westeurope is cheaper and has wider feature coverage.')
@allowed([
  'switzerlandnorth'
  'westeurope'
  'northeurope'
])
param location string = 'switzerlandnorth'

@description('Prefix for every resource name. Lowercase letters and hyphens only.')
@minLength(3)
@maxLength(16)
param namePrefix string = 'smartfactory'

@description('Environment label. Drives tagging and is appended to nothing -- staging and prod are separate resource groups, not separate name schemes.')
@allowed([
  'staging'
  'prod'
])
param environmentName string = 'staging'

@description('Image for the RAG service. Left as the placeholder until CD has pushed a real one.')
param ragImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Image for the defect-inspection service.')
param defectImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Minimum replicas per service. 0 scales to zero when idle (cheapest, cold start on first hit). Set 1 before a demo or an interview.')
@minValue(0)
@maxValue(3)
param minReplicas int = 0

@description('Bind the RAG service to an Azure OpenAI key held in Key Vault. Leave false to run the offline-extractive path, which needs no key at all.')
param enableOpenAiSecret bool = false

@description('Name of the Azure OpenAI key secret in Key Vault. Only read when enableOpenAiSecret is true.')
param openAiSecretName string = 'azure-openai-api-key'

var tags = {
  platform: 'smart-factory'
  environment: environmentName
  managedBy: 'bicep'
  repo: 'smart-factory-platform'
}

// The RAG service reads AZURE_OPENAI_API_KEY and falls back to the offline
// extractive path when it is absent, so the binding is genuinely optional.
var ragSecrets = enableOpenAiSecret ? [
  {
    name: 'azure-openai-api-key'
    secretName: openAiSecretName
    envVar: 'AZURE_OPENAI_API_KEY'
  }
] : []

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
  }
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
  }
}

module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
  }
}

module environment 'modules/environment.bicep' = {
  name: 'environment'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    logAnalyticsCustomerId: monitoring.outputs.workspaceCustomerId
  }
}

module ragService 'modules/service.bicep' = {
  name: 'service-rag'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    serviceName: 'rag'
    environmentId: environment.outputs.environmentId
    registryName: registry.outputs.registryName
    registryLoginServer: registry.outputs.loginServer
    keyVaultName: keyvault.outputs.vaultName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    image: ragImage
    minReplicas: minReplicas
    keyVaultSecrets: ragSecrets
  }
}

module defectService 'modules/service.bicep' = {
  name: 'service-defect'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    serviceName: 'defect'
    environmentId: environment.outputs.environmentId
    registryName: registry.outputs.registryName
    registryLoginServer: registry.outputs.loginServer
    keyVaultName: keyvault.outputs.vaultName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    image: defectImage
    // The ONNX model and the LBP+SVM baseline both load into memory at startup;
    // this one wants more headroom than the RAG index does.
    cpu: '0.75'
    memory: '1.5Gi'
    minReplicas: minReplicas
    keyVaultSecrets: []
  }
}

@description('Registry the CD pipeline pushes to.')
output registryLoginServer string = registry.outputs.loginServer

@description('Registry name, used by `az acr build`.')
output registryName string = registry.outputs.registryName

@description('Key Vault to put the Azure OpenAI key in, if you want the LLM path live.')
output keyVaultName string = keyvault.outputs.vaultName

@description('Application Insights resource, for the KQL queries in docs/RUNBOOK.md.')
output appInsightsName string = monitoring.outputs.appInsightsName

output ragUrl string = ragService.outputs.url
output defectUrl string = defectService.outputs.url
output ragAppName string = ragService.outputs.appName
output defectAppName string = defectService.outputs.appName
