/*
  Observability backbone for the platform.

  One Log Analytics workspace is shared by everything: the Container Apps
  environment ships its console + system logs here, and Application Insights is
  workspace-based (the classic standalone mode is retired), so traces, requests
  and dependencies land in the same store. That means a single KQL query can
  join an HTTP request to the container log line it produced -- which is the
  whole reason to centralise it rather than give each service its own workspace.
*/

@description('Azure region for the workspace.')
param location string

@description('Name prefix shared by all platform resources.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object

@description('Log retention in days. 30 is the free-tier floor; raising it costs money.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Daily ingestion cap in GB. Guards the Azure credit against a log storm. -1 disables the cap.')
param dailyQuotaGb int = 1

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      // A runaway container logging in a loop is a real way to burn a trial
      // credit overnight. Cap ingestion rather than trusting good behaviour.
      dailyQuotaGb: dailyQuotaGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-appi'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    // Workspace-based: required for new components, and what lets traces and
    // container logs share a single queryable store.
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name

@description('Connection string for the OTLP/Azure Monitor exporter. Passed to each service as an env var.')
output appInsightsConnectionString string = appInsights.properties.ConnectionString
