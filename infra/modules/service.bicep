/*
  One service on the platform.

  Everything a service needs and nothing it doesn't: its own user-assigned
  managed identity, exactly two role assignments (pull images, read its own
  secrets), and a Container App wired to the shared environment. Adding a third
  service to the platform is one more module call in main.bicep -- no new
  registry, no new workspace, no new pipeline.

  Identity model: the app authenticates to ACR and Key Vault as itself. There is
  no registry password and no connection string in an env var. Revoking a
  service's access is deleting a role assignment.
*/

@description('Azure region.')
param location string

@description('Short service name, e.g. "rag" or "defect". Used in resource names and as the app hostname label.')
@minLength(2)
@maxLength(20)
param serviceName string

@description('Name prefix shared by all platform resources.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Resource ID of the shared Container Apps environment.')
param environmentId string

@description('Name of the shared container registry (same resource group).')
param registryName string

@description('Login server of the shared container registry.')
param registryLoginServer string

@description('Name of the shared Key Vault (same resource group).')
param keyVaultName string

@description('Application Insights connection string, injected as an env var for the OTel exporter.')
@secure()
param appInsightsConnectionString string

@description('''Full image reference to deploy. On the very first infra deploy the service image does not exist in the registry yet, so this defaults to a public placeholder; the CD pipeline replaces it with the real image on first deployment.''')
param image string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Container port the app listens on.')
param targetPort int = 8000

@description('CPU cores per replica. Consumption profile requires cpu/memory in fixed pairs (0.25/0.5Gi, 0.5/1Gi, 0.75/1.5Gi, 1/2Gi ...).')
param cpu string = '0.5'

@description('Memory per replica, paired with cpu.')
param memory string = '1Gi'

@description('Minimum replicas. 0 = scale to zero when idle (cheapest; adds a cold start).')
@minValue(0)
@maxValue(5)
param minReplicas int = 0

@description('Maximum replicas. Caps the blast radius of a traffic spike on the Azure credit.')
@minValue(1)
@maxValue(10)
param maxReplicas int = 2

@description('''Key Vault secrets to expose to the container, as a list of
{ name: <container secret name>, secretName: <name in Key Vault>, envVar: <env var to bind it to> }.
Empty by default -- the services run fully offline without any keys.''')
param keyVaultSecrets array = []

@description('Plain (non-secret) environment variables as a list of { name, value }.')
param extraEnv array = []

// Role definition IDs are stable GUIDs across all of Azure.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: registryName
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-${serviceName}-id'
  location: location
  tags: tags
}

// Pull images from the shared registry. Without this the app cannot start.
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, acrPullRoleId)
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: identity.properties.principalId
    // Required: the identity may not have replicated through AAD yet, and
    // without this ARM rejects the assignment with a PrincipalNotFound race.
    principalType: 'ServicePrincipal'
  }
}

// Read secrets from the shared vault. Granted at vault scope: on a small
// platform this is proportionate, but per-secret scoping is the tighter option
// once services stop trusting each other.
resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, identity.id, keyVaultSecretsUserRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// The vault URI has to be built from the name rather than read off
// `vault.properties.vaultUri`: a loop body must be resolvable at the start of
// the deployment, and that property is only known once the vault exists.
// environment().suffixes.keyvaultDns supplies the leading-dot suffix and keeps
// this correct in sovereign clouds instead of hardcoding .vault.azure.net.
var vaultUri = 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/'

// Container App secrets sourced from Key Vault, resolved by the app's own identity.
var secretDefinitions = [for s in keyVaultSecrets: {
  name: s.name
  keyVaultUrl: '${vaultUri}secrets/${s.secretName}'
  identity: identity.id
}]

// Bind each Key Vault secret to the env var the application actually reads.
var secretEnv = [for s in keyVaultSecrets: {
  name: s.envVar
  secretRef: s.name
}]

var telemetryEnv = [
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsightsConnectionString
  }
  {
    name: 'OTEL_SERVICE_NAME'
    value: serviceName
  }
]

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${namePrefix}-${serviceName}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: registryLoginServer
          identity: identity.id
        }
      ]
      secrets: secretDefinitions
    }
    template: {
      containers: [
        {
          name: serviceName
          image: image
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: concat(telemetryEnv, secretEnv, extraEnv)
          probes: [
            {
              type: 'Readiness'
              httpGet: {
                path: '/health'
                port: targetPort
              }
              // Both services load a model/index at startup; don't take traffic
              // until that has actually happened.
              initialDelaySeconds: 5
              periodSeconds: 10
              failureThreshold: 6
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: targetPort
              }
              initialDelaySeconds: 20
              periodSeconds: 30
              failureThreshold: 3
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-concurrency'
            http: {
              metadata: {
                concurrentRequests: '20'
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [
    // The app cannot pull its image until the role assignment exists. Bicep
    // cannot infer this: nothing in the app body references the assignment.
    acrPull
    keyVaultSecretsUser
  ]
}

output appName string = app.name
output fqdn string = app.properties.configuration.ingress.fqdn
output url string = 'https://${app.properties.configuration.ingress.fqdn}'
output identityId string = identity.id
output identityPrincipalId string = identity.properties.principalId
