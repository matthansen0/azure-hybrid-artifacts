// ---------------------------------------------------------------------------
// Module: action-group.bicep
// Deploys: Action Group with Azure Function receiver (webhook)
// ---------------------------------------------------------------------------

@description('Base name used to derive resource names.')
param baseName string

@description('Name of the Function App to target.')
param functionAppName string

@description('Resource ID of the Function App.')
param functionAppId string

@description('Resource tags.')
param tags object = {}

var actionGroupName = 'ag-${baseName}'

resource actionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' = {
  name: actionGroupName
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: take(replace(baseName, '-', ''), 12)
    enabled: true
    azureFunctionReceivers: [
      {
        name: 'CatchUpPatchingTrigger'
        functionAppResourceId: functionAppId
        functionName: 'CatchUpPatchingTrigger'
        httpTriggerUrl: 'https://${functionAppName}.azurewebsites.net/api/CatchUpPatchingTrigger'
        useCommonAlertSchema: true
      }
    ]
  }
}

output actionGroupId string = actionGroup.id
