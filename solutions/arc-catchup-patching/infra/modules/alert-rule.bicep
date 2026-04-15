// ---------------------------------------------------------------------------
// Module: alert-rule.bicep
// Deploys: Activity Log alert rule for Resource Health events on Arc machines
//          Fires when an Arc machine transitions from Disconnected → Available
// ---------------------------------------------------------------------------

@description('Base name used to derive resource names.')
param baseName string

@description('Resource ID of the Action Group to trigger.')
param actionGroupId string

@description('Subscription ID to scope the alert to. Defaults to current subscription.')
param targetSubscriptionId string = subscription().subscriptionId

@description('Resource tags.')
param tags object = {}

var alertRuleName = 'alert-${baseName}'

resource alertRule 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: alertRuleName
  location: 'Global'
  tags: tags
  properties: {
    description: 'Fires when an Azure Arc-enabled machine comes back online (Resource Health: Unavailable → Available). Triggers catch-up patching via Azure Function.'
    enabled: true
    scopes: [
      '/subscriptions/${targetSubscriptionId}'
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ResourceHealth'
        }
        {
          field: 'resourceType'
          equals: 'Microsoft.HybridCompute/machines'
        }
        {
          // Current health status is Available (machine came back online)
          field: 'properties.currentHealthStatus'
          equals: 'Available'
        }
        {
          // Previous health status was Unavailable (machine was offline)
          field: 'properties.previousHealthStatus'
          equals: 'Unavailable'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}

output alertRuleId string = alertRule.id
