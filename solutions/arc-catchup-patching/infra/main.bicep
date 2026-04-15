// ---------------------------------------------------------------------------
// main.bicep — Arc Catch-Up Patching Solution
//
// Orchestrates deployment of all modules:
//   1. Function App (+ Storage, App Insights, Consumption Plan)
//   2. Action Group (webhook to Function App)
//   3. Activity Log Alert Rule (Resource Health: Arc machine online)
//   4. RBAC Role Assignments (Managed Identity permissions)
// ---------------------------------------------------------------------------

targetScope = 'resourceGroup'

// --- Parameters ---

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Base name for all resources (e.g., "arc-catchup-patching").')
param baseName string = 'arc-catchup-patching'

@description('Offline threshold in hours. Machines offline for less than this duration are ignored (brief blips).')
@minValue(1)
@maxValue(720)
param offlineThresholdHours int = 2

@description('Delay in minutes before the post-install compliance reassessment runs. Should exceed expected patch installation time.')
@minValue(10)
@maxValue(240)
param reassessmentDelayMinutes int = 60

@description('Subscription ID to scope the Resource Health alert. Defaults to current subscription.')
param targetSubscriptionId string = subscription().subscriptionId

@description('Resource tags applied to all resources.')
param tags object = {
  solution: 'arc-catchup-patching'
  managedBy: 'bicep'
}

// --- Modules ---

module functionApp 'modules/function-app.bicep' = {
  name: 'deploy-function-app'
  params: {
    location: location
    baseName: baseName
    offlineThresholdHours: offlineThresholdHours
    reassessmentDelayMinutes: reassessmentDelayMinutes
    tags: tags
  }
}

module actionGroup 'modules/action-group.bicep' = {
  name: 'deploy-action-group'
  params: {
    baseName: baseName
    functionAppName: functionApp.outputs.functionAppName
    functionAppId: functionApp.outputs.functionAppId
    tags: tags
  }
}

module alertRule 'modules/alert-rule.bicep' = {
  name: 'deploy-alert-rule'
  params: {
    baseName: baseName
    actionGroupId: actionGroup.outputs.actionGroupId
    targetSubscriptionId: targetSubscriptionId
    tags: tags
  }
}

module roleAssignments 'modules/role-assignments.bicep' = {
  name: 'deploy-role-assignments'
  params: {
    principalId: functionApp.outputs.principalId
  }
}

// --- Outputs ---

output functionAppName string = functionApp.outputs.functionAppName
output functionAppHostname string = functionApp.outputs.functionAppDefaultHostname
output actionGroupId string = actionGroup.outputs.actionGroupId
output alertRuleId string = alertRule.outputs.alertRuleId
