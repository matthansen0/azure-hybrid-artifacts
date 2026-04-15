// ---------------------------------------------------------------------------
// Module: function-app.bicep
// Deploys: Storage Account, App Service Plan (Consumption Y1), Function App
//          (PowerShell 7.4), Application Insights, Log Analytics workspace
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string

@description('Base name used to derive resource names.')
param baseName string

@description('Configurable offline threshold in hours before catch-up patching triggers.')
param offlineThresholdHours int

@description('Delay in minutes before the post-install reassessment runs (queue visibility timeout).')
param reassessmentDelayMinutes int

@description('Resource tags.')
param tags object = {}

// --- Naming ---
var uniqueSuffix = uniqueString(resourceGroup().id, baseName)
var storageAccountName = toLower('st${replace(baseName, '-', '')}${take(uniqueSuffix, 6)}')
var appServicePlanName = 'asp-${baseName}'
var functionAppName = 'func-${baseName}'
var appInsightsName = 'appi-${baseName}'
var logAnalyticsName = 'log-${baseName}'

// --- Log Analytics Workspace (required by App Insights) ---
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// --- Application Insights ---
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// --- Storage Account (Function App runtime + reassessment queue) ---
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// --- Storage Queue for delayed re-assessment ---
resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource reassessmentQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'catchup-reassessment'
}

// --- App Service Plan (Consumption Y1) ---
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: false
  }
}

// --- Function App (PowerShell 7.4) ---
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      netFrameworkVersion: 'v8.0'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'OFFLINE_THRESHOLD_HOURS'
          value: string(offlineThresholdHours)
        }
        {
          name: 'REASSESSMENT_DELAY_MINUTES'
          value: string(reassessmentDelayMinutes)
        }
      ]
    }
  }
}

// --- Outputs ---
output functionAppId string = functionApp.id
output functionAppName string = functionApp.name
output functionAppDefaultHostname string = functionApp.properties.defaultHostName
output principalId string = functionApp.identity.principalId
