/*
  The Container Apps managed environment -- the shared compute fabric.

  Every service runs as a Container App inside this one environment. That is
  what makes this a platform rather than two independently deployed apps: they
  share a network boundary, a log destination, and a scaling substrate, and a
  new service costs one module call rather than a new stack.

  Consumption workload profile = scale to zero, pay per request. On an Azure
  free credit this is the difference between a few francs a month and burning
  the whole $200 on idle compute.
*/

@description('Azure region for the environment.')
param location string

@description('Name prefix shared by all platform resources.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Resource ID of the shared Log Analytics workspace.')
param logAnalyticsWorkspaceId string

@description('Customer (workspace) ID of the shared Log Analytics workspace.')
param logAnalyticsCustomerId string

// The environment needs the workspace shared key to ship container stdout/stderr.
// Referenced via listKeys at deploy time rather than passed as a parameter, so
// the key never appears in a parameter file or a deployment history entry.
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${namePrefix}-env'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
}

output environmentId string = environment.id
output environmentName string = environment.name
output defaultDomain string = environment.properties.defaultDomain
